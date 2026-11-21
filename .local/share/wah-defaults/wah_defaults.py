#!/usr/bin/env python3
"""Personal defaults for Web App Hub 1.3 / Firefox 159 on Linux Flatpak.

Usage: close Firefox, all its web apps, and Web App Hub; then run:
    python3 wah_defaults.py install

Afterwards select 'Firefox Omar (Flatpak)' with isolation enabled in Web App Hub
for NEW apps. Existing isolated Firefox launchers are converted by the installer.

The installer first tests Firefox's configuration API in a disposable profile.
It downloads the three signed extensions directly from Mozilla Add-ons, verifies
their published hashes and IDs, and leaves Firefox to check their signatures.
It installs itself in ~/.local/share/wah-defaults. No third-party Python modules.

Each app is configured once in a headless Firefox session. Later launches only
refresh the requested user.js preferences. Saved session files are preserved
around the headless setup. Normal launches do not enable browser automation.
For a forced reconfiguration: python3 ~/.local/share/wah-defaults/wah_defaults.py repair

Backups cover files changed by the installer, plus each profile's user.js,
prefs.js, xulstore.json and saved session files before its first setup. Firefox
itself installs the extensions and writes permissions; these changes are not
reversed by restoring just the launcher backups.

Diagnostic logs: ~/.var/app/org.mozilla.firefox/data/wah-defaults/logs
Source: Web App Hub upstream v1.3.0; Firefox Marionette / ExtensionStorageIDB;
New Tab Override 19 storage keys: type, url, focus_website.
"""

import argparse
import configparser
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile

REVISION = 1
FF_ID = "org.mozilla.firefox"
WAH_ID = "org.pvermeer.WebAppHub"
BROWSER_NAME = "Firefox Omar"
BROWSER_ID = FF_ID + "_firefox_omar"
HOME = Path.home()
CONFIG = HOME / ".var/app" / WAH_ID / "config/web-app-hub"
FF_DATA = HOME / ".var/app" / FF_ID / "data"
PROFILES = FF_DATA / "web-app-hub/profiles"
STATE = FF_DATA / "wah-defaults"
INSTALLED = HOME / ".local/share/wah-defaults/wah_defaults.py"
APPS = Path(os.environ.get("XDG_DATA_HOME", HOME / ".local/share")) / "applications"
BEGIN = "// BEGIN WAH OMAR DEFAULTS"
END = "// END WAH OMAR DEFAULTS"
TEMP_BEGIN = "// BEGIN WAH TEMPORARY SETUP"
TEMP_END = "// END WAH TEMPORARY SETUP"
ADDONS = {
    "ctrl-number-to-switch-tabs": "{84601290-bec9-494a-b11c-1baa897a9683}",
    "ublock-origin": "uBlock0@raymondhill.net",
    "new-tab-override": "newtaboverride@agenedia.com",
}
PREFS = {
    "browser.tabs.inTitlebar": 1,
    "browser.startup.page": 3,
    "browser.link.open_newwindow": 3,
    "browser.download.useDownloadDir": False,
    "layout.spellcheckDefault": 0,
    "network.trr.mode": 5,
    "sidebar.revamp": True,
    "sidebar.verticalTabs": True,
    "sidebar.visibility": "always-show",
    "sidebar.main.tools": "",
    "media.hardwaremediakeys.enabled": False,
    "general.autoScroll": True,
    "widget.gtk.overlay-scrollbars.enabled": False,
    # Disable the bundled chrome CSS that hides Firefox's controls.
    "toolkit.legacyUserProfileCustomizations.stylesheets": False,
    # Prevent a new profile's welcome page from replacing the app startup.
    "browser.aboutwelcome.enabled": False,
}


def fail(message):
    raise RuntimeError(message)


def atomic_write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    data = value.encode() if isinstance(value, str) else value
    fd, tmp = tempfile.mkstemp(prefix=".wah-write-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(data)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def read_text(path):
    return path.read_text() if path.exists() else ""


def strip_block(text, begin, end):
    pattern = re.escape(begin) + r"\n.*?" + re.escape(end) + r"\n?"
    return re.sub(pattern, "", text, flags=re.S)


def preference_text(prefs):
    return "".join("user_pref(%s, %s);\n" % (json.dumps(k), json.dumps(v))
                   for k, v in prefs.items())


def profile_prefs(profile, url):
    prefs = {**PREFS, "browser.startup.homepage": url}
    path = profile / "user.js"
    text = strip_block(read_text(path), BEGIN, END)
    # Remove all earlier copies of preferences that this script owns. Keep
    # unrelated user.js lines and comments. The managed block is always last.
    for key in prefs:
        text = re.sub(r'^\s*user_pref\(\s*[\"\']' + re.escape(key) +
                      r'[\"\']\s*,[^\n]*\n?', "", text, flags=re.M)
    atomic_write(path, text.rstrip() + "\n" + BEGIN + "\n" +
                 preference_text(prefs) + END + "\n")
    return prefs


def desktop_read(path):
    config = configparser.ConfigParser(interpolation=None, strict=False)
    config.optionxform = str
    config.read_string(path.read_text())
    return dict(config["Desktop Entry"]) if config.has_section("Desktop Entry") else {}


def desktop_change(text, changes):
    lines, in_entry, seen = [], False, set()
    for line in text.splitlines():
        if line.startswith("["):
            if in_entry:
                lines.extend(k + "=" + v for k, v in changes.items() if k not in seen)
            in_entry = line == "[Desktop Entry]"
        key = line.split("=", 1)[0]
        if in_entry and key in changes:
            if key not in seen:
                lines.append(key + "=" + changes[key])
                seen.add(key)
        else:
            lines.append(line)
    if in_entry:
        lines.extend(k + "=" + v for k, v in changes.items() if k not in seen)
    return "\n".join(lines) + "\n"


def desktop_arg(value):
    # Desktop Entry string escaping happens before Exec argument unquoting.
    if any(c in value for c in "\n\r\0"):
        fail("A launcher argument contains a newline or NUL.")
    value = value.replace("%", "%%")
    for c in ("\\", '"', "`", "$"):
        value = value.replace(c, "\\" + c)
    return '"' + value.replace("\\", "\\\\") + '"'


def desktop_exec(app_class, profile):
    argv = ["/usr/bin/python3", str(INSTALLED), "launch", "--", "flatpak",
            "run", FF_ID, "--class=" + app_class, "--name=" + app_class,
            "--profile=" + str(profile), "--no-remote"]
    return " ".join(desktop_arg(x) for x in argv)


def apps():
    result = []
    if not APPS.is_dir():
        return result
    for path in sorted(APPS.glob("*.desktop")):
        try:
            info = desktop_read(path)
        except (configparser.Error, UnicodeError):
            continue
        if info.get("X-WAH", "").lower() != "true":
            continue
        if info.get("X-WAH-BROWSER-ID") not in (FF_ID + "_firefox", BROWSER_ID):
            continue
        if info.get("X-WAH-ISOLATE", "").lower() != "true":
            continue
        profile = Path(info.get("X-WAH-PROFILE", "/missing")).expanduser().resolve()
        if profile.parent != PROFILES.resolve():
            fail("Unexpected profile location in " + str(path))
        url = info.get("X-WAH-URL", "")
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme not in ("https", "http") or not parsed.hostname:
            fail("Expected an HTTP(S) app URL in " + str(path))
        if not info.get("StartupWMClass"):
            fail("Missing StartupWMClass in " + str(path))
        result.append((path, info, profile, url))
    return result


def profile_busy(profile):
    lock = profile / ".parentlock"
    if not lock.exists():
        return False
    with lock.open("r+") as f:
        try:
            fcntl.lockf(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.lockf(f, fcntl.LOCK_UN)
    return False


def require_closed():
    output = subprocess.check_output(["flatpak", "ps", "--columns=application"], text=True)
    running = set(output.splitlines())
    if running & {FF_ID, WAH_ID}:
        fail("Close Firefox, all Firefox web apps, and Web App Hub, then run install again.")


def download(url):
    request = urllib.request.Request(url, headers={"User-Agent": "WAH-Personal-Defaults/1"})
    with urllib.request.urlopen(request, timeout=90) as response:
        return response.read()


def download_addons():
    root = STATE / "addons"
    root.mkdir(parents=True, exist_ok=True)
    manifest = []
    for slug, expected_id in ADDONS.items():
        print("Checking Mozilla Add-ons:", slug, flush=True)
        metadata = json.loads(download("https://addons.mozilla.org/api/v5/addons/addon/" + slug + "/"))
        if metadata["guid"] != expected_id:
            fail("Unexpected add-on ID for " + slug)
        info = metadata["current_version"]["file"]
        algorithm, digest = info["hash"].split(":", 1)
        if algorithm != "sha256":
            fail("Expected a SHA-256 add-on hash for " + slug)
        path = root / (slug + "-" + digest[:16] + ".xpi")
        if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            data = download(info["url"])
            if hashlib.sha256(data).hexdigest() != digest:
                fail("Add-on checksum mismatch: " + slug)
            atomic_write(path, data)
        with zipfile.ZipFile(path) as archive:
            extension_manifest = json.loads(archive.read("manifest.json"))
        gecko = extension_manifest.get("browser_specific_settings", {}).get("gecko", {})
        gecko = gecko or extension_manifest.get("applications", {}).get("gecko", {})
        if gecko.get("id") != expected_id:
            fail("Unexpected ID inside " + slug)
        manifest.append({"id": expected_id, "path": str(path), "sha256": digest,
                         "version": metadata["current_version"]["version"]})
    atomic_write(STATE / "addons.json", json.dumps(manifest, indent=2))


class Marionette:
    def __init__(self, port, process):
        deadline = time.monotonic() + 60
        while True:
            try:
                self.sock = socket.create_connection(("127.0.0.1", port), timeout=1)
                self.sock.settimeout(150)
                break
            except OSError:
                if process.poll() is not None:
                    fail("Headless Firefox exited before its setup connection was ready.")
                if time.monotonic() >= deadline:
                    fail("Timed out connecting to headless Firefox.")
                time.sleep(0.2)
        self.counter = 0
        greeting = self.receive()
        if greeting.get("marionetteProtocol") != 3:
            fail("Unsupported Firefox Marionette protocol: " + repr(greeting))

    def exact(self, length):
        parts = bytearray()
        while len(parts) < length:
            data = self.sock.recv(length - len(parts))
            if not data:
                fail("Firefox closed its setup connection.")
            parts.extend(data)
        return bytes(parts)

    def receive(self):
        prefix = bytearray()
        while True:
            char = self.exact(1)
            if char == b":":
                break
            if not char.isdigit() or len(prefix) > 9:
                fail("Invalid Firefox setup message length.")
            prefix.extend(char)
        return json.loads(self.exact(int(prefix)))

    def call(self, name, parameters=None):
        self.counter += 1
        payload = json.dumps([0, self.counter, name, parameters or {}], ensure_ascii=False).encode()
        self.sock.sendall(str(len(payload)).encode() + b":" + payload)
        while True:
            message = self.receive()
            if message[0] != 1 or message[1] != self.counter:
                fail("Unexpected Firefox setup response.")
            if message[2]:
                fail(name + ": " + json.dumps(message[2]))
            return message[3]

    def script(self, body, args=()):
        script = """const finish = arguments[arguments.length - 1];
        (async () => { BODY })().then(value => finish({ok:true,value}),
          error => finish({ok:false,error:String(error),stack:error.stack}));""".replace("BODY", body)
        result = self.call("WebDriver:ExecuteAsyncScript", {
            "script": script, "args": list(args), "newSandbox": True,
            "sandbox": "system", "scriptTimeout": 120000,
        })["value"]
        if not result.get("ok"):
            fail("Firefox setup script failed: " + json.dumps(result))
        return result.get("value")


CONFIGURE_JS = r"""
const [url, prefs, ids] = arguments;
const { AddonManager } = ChromeUtils.importESModule('resource://gre/modules/AddonManager.sys.mjs');
const { ExtensionPermissions } = ChromeUtils.importESModule('resource://gre/modules/ExtensionPermissions.sys.mjs');
const { ExtensionParent } = ChromeUtils.importESModule('resource://gre/modules/ExtensionParent.sys.mjs');
const { ExtensionStorageIDB } = ChromeUtils.importESModule('resource://gre/modules/ExtensionStorageIDB.sys.mjs');
const { ExtensionStorage } = ChromeUtils.importESModule('resource://gre/modules/ExtensionStorage.sys.mjs');
const { ExtensionSettingsStore } = ChromeUtils.importESModule('resource://gre/modules/ExtensionSettingsStore.sys.mjs');
for (const [key, value] of Object.entries(prefs)) {
  const setter = typeof value === 'boolean' ? 'setBoolPref' :
                 typeof value === 'number' ? 'setIntPref' : 'setStringPref';
  Services.prefs[setter](key, value);
}
const principal = Services.scriptSecurityManager.createContentPrincipal(Services.io.newURI(url), {});
for (const type of ['cookie', 'persistent-storage']) {
  Services.perms.addFromPrincipal(principal, type, Services.perms.ALLOW_ACTION);
}
for (const id of ids) {
  const addon = await AddonManager.getAddonByID(id);
  if (!addon) throw new Error('Missing extension: ' + id);
  if (addon.userDisabled) await addon.enable();
  const permissions = await ExtensionPermissions.get(id);
  if (!permissions.permissions.includes('internal:privateBrowsingAllowed')) {
    const extension = ExtensionParent.GlobalManager.getExtension(id);
    await ExtensionPermissions.add(id, {
      permissions: ['internal:privateBrowsingAllowed'], origins: [], data_collection: []
    }, extension);
    await addon.reload();
  }
}
const id = 'newtaboverride@agenedia.com';
let extension;
for (let i = 0; i < 100; ++i) {
  extension = ExtensionParent.GlobalManager.getExtension(id);
  if (extension) break;
  await new Promise(resolve => setTimeout(resolve, 100));
}
if (!extension) throw new Error('New Tab Override did not start');
const backend = await ExtensionStorageIDB.selectBackend({extension});
const settings = {type: 'custom_url', url, focus_website: true};
let saved;
if (backend.backendEnabled) {
  const principal = backend.storagePrincipal.deserialize(globalThis, true);
  const db = await ExtensionStorageIDB.open(principal, false);
  const changes = await db.set(settings);
  if (changes) ExtensionStorageIDB.notifyListeners(id, changes);
  saved = await db.get(Object.keys(settings));
} else {
  await ExtensionStorage.set(id, settings);
  saved = await ExtensionStorage.get(id, Object.keys(settings));
}
for (const key of Object.keys(settings)) {
  if (saved[key] !== settings[key]) throw new Error('New-tab setting did not persist: ' + key);
}
// The requested new-tab choice is explicit; persist Firefox's confirmation so
// no "keep this change" doorhanger remains for the first normal new tab.
await ExtensionSettingsStore.initialize();
await ExtensionSettingsStore.addSetting(id, 'newTabNotification', id, true, () => false);
const dark = await AddonManager.getAddonByID('firefox-compact-dark@mozilla.org');
if (!dark) throw new Error('The built-in Firefox dark theme is unavailable');
await dark.enable();
const documentURI = 'chrome://browser/content/browser.xhtml';
Services.xulStore.setValue(documentURI, 'toolbar-menubar', 'autohide', 'false');
Services.xulStore.setValue(documentURI, 'nav-bar', 'collapsed', 'false');
const win = Services.wm.getMostRecentWindow('navigator:browser');
if (win) {
  win.document.getElementById('toolbar-menubar')?.setAttribute('autohide', 'false');
  win.document.getElementById('toolbar-menubar')?.removeAttribute('inactive');
  win.document.getElementById('nav-bar')?.setAttribute('collapsed', 'false');
}
Services.prefs.savePrefFile(null);
const checks = {};
for (const [key, value] of Object.entries(prefs)) {
  const getter = typeof value === 'boolean' ? 'getBoolPref' :
                 typeof value === 'number' ? 'getIntPref' : 'getStringPref';
  if (Services.prefs[getter](key) !== value) throw new Error('Preference mismatch: ' + key);
}
for (const id of ids) {
  const addon = await AddonManager.getAddonByID(id);
  const allowed = (await ExtensionPermissions.get(id)).permissions.includes('internal:privateBrowsingAllowed');
  const policy = ExtensionParent.WebExtensionPolicy.getByID(id);
  if (!addon.isActive || !allowed || !policy?.privateBrowsingAllowed)
    throw new Error('Extension not active / private-enabled: ' + id);
  checks[id] = {version:addon.version, active:addon.isActive, private:allowed};
}
for (const type of ['cookie', 'persistent-storage']) {
  if (Services.perms.testExactPermissionFromPrincipal(principal, type) !== Services.perms.ALLOW_ACTION)
    throw new Error('Permission mismatch: ' + type);
}
if (!dark.isActive) throw new Error('Dark theme did not activate');
if (Services.xulStore.getValue(documentURI, 'toolbar-menubar', 'autohide') !== 'false')
  throw new Error('Menu bar visibility did not persist');
return {extensions:checks, newtab:saved, dark:dark.isActive,
        menu:Services.xulStore.getValue(documentURI, 'toolbar-menubar', 'autohide')};
"""


def stamp():
    return datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")


def snapshot_files(profile, destination):
    destination.mkdir(parents=True)
    names = ["user.js", "prefs.js", "xulstore.json", "sessionstore.jsonlz4",
             "sessionstore-backups", "sessionCheckpoints.json"]
    for name in names:
        source = profile / name
        if source.is_dir():
            shutil.copytree(source, destination / name)
        elif source.is_file():
            shutil.copy2(source, destination / name)


def restore_sessions(profile, backup):
    for name in ["sessionstore.jsonlz4", "sessionstore-backups", "sessionCheckpoints.json"]:
        target = profile / name
        if target.is_dir():
            shutil.rmtree(target)
        elif target.exists():
            target.unlink()
        source = backup / name
        if source.is_dir():
            shutil.copytree(source, target)
        elif source.is_file():
            shutil.copy2(source, target)


def configure(profile, url, force=False):
    profile.mkdir(parents=True, exist_ok=True)
    if profile_busy(profile):
        fail("Close this web app before configuring it: " + profile.name)
    pending = profile / "wah-defaults-pending.json"
    if pending.exists():
        # Recover saved tabs if the machine or installer stopped between
        # headless startup and the normal finally block.
        recovery = Path(json.loads(pending.read_text())["backup"]).resolve()
        if recovery.parent != (STATE / "backups").resolve() or not recovery.is_dir():
            fail("Invalid session recovery backup for " + profile.name)
        restore_sessions(profile, recovery)
        path = profile / "user.js"
        atomic_write(path, strip_block(read_text(path), TEMP_BEGIN, TEMP_END))
        pending.unlink()
    marker = profile / "wah-defaults.json"
    expected = {"revision": REVISION, "url": url}
    try:
        complete = json.loads(marker.read_text()).get("configuration") == expected
    except (OSError, ValueError):
        complete = False
    if complete and not force:
        profile_prefs(profile, url)
        return
    addon_files = json.loads((STATE / "addons.json").read_text())
    for addon in addon_files:
        if hashlib.sha256(Path(addon["path"]).read_bytes()).hexdigest() != addon["sha256"]:
            fail("Cached extension changed; rerun install.")
    backup = STATE / "backups" / (stamp() + "-" + profile.name)
    snapshot_files(profile, backup)
    atomic_write(pending, json.dumps({"backup": str(backup)}))
    prefs = profile_prefs(profile, url)
    # Use a separate temporary block; remove it even if setup fails.
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    path = profile / "user.js"
    temporary = {"marionette.port": port, "remote.prefs.recommended": False,
                 "browser.startup.page": 0, "browser.startup.homepage": "about:blank"}
    atomic_write(path, read_text(path) + TEMP_BEGIN + "\n" +
                 preference_text(temporary) + TEMP_END + "\n")
    logs = STATE / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    log_path = logs / (profile.name + "-setup.log")
    process = client = None
    success = False
    print("Setting up profile:", profile.name, flush=True)
    try:
        with log_path.open("w") as log:
            process = subprocess.Popen([
                "flatpak", "run", "--env=MOZ_REMOTE_ALLOW_SYSTEM_ACCESS=1", FF_ID,
                "--headless", "--no-remote", "--marionette", "--profile", str(profile), "about:blank"
            ], stdout=log, stderr=subprocess.STDOUT)
            client = Marionette(port, process)
            # Marionette accepts direct capabilities, unlike geckodriver's HTTP endpoint.
            session = client.call("WebDriver:NewSession", {})
            if Path(session["capabilities"]["moz:profile"]).resolve() != profile.resolve():
                fail("Firefox connected to a different profile; setup stopped.")
            client.call("Marionette:SetContext", {"value": "chrome"})
            client.call("WebDriver:SetTimeouts", {"script": 120000})
            existing = client.script("""
                const {AddonManager} = ChromeUtils.importESModule('resource://gre/modules/AddonManager.sys.mjs');
                const present = [];
                for (const target of arguments[0]) {
                  const addon = await AddonManager.getAddonByID(target.id);
                  if (addon && Services.vc.compare(addon.version, target.version) >= 0) present.push(addon.id);
                }
                return present;
            """, [addon_files])
            for addon in addon_files:
                if addon["id"] not in existing:
                    installed_id = client.call("Addon:Install", {
                        "path": addon["path"], "temporary": False, "allowPrivateBrowsing": True})
                    if installed_id.get("value") != addon["id"]:
                        fail("Firefox returned an unexpected installed extension ID: " + repr(installed_id))
            checks = client.script(CONFIGURE_JS, [url, prefs, list(ADDONS.values())])
            client.call("Marionette:Quit", {"flags": ["eAttemptQuit"]})
            process.wait(timeout=45)
            if process.returncode != 0:
                fail("Headless Firefox exited with status " + str(process.returncode))
            success = True
    except Exception as error:
        raise RuntimeError(str(error) + "\nFirefox log: " + str(log_path) +
                           "\nProfile settings/session backup: " + str(backup)) from error
    finally:
        if process is not None and process.poll() is None:
            # Ask only this owned setup process to quit. Do not kill other Firefox instances.
            if client is not None:
                with contextlib.suppress(Exception):
                    client.call("Marionette:Quit", {"flags": ["eForceQuit"]})
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)
        if client is not None:
            client.sock.close()
        if profile_busy(profile):
            fail("Firefox is still using the setup profile. Close it and rerun this command. "
                 "Saved tabs will be recovered automatically. Backup: " + str(backup))
        atomic_write(path, strip_block(read_text(path), TEMP_BEGIN, TEMP_END))
        profile_prefs(profile, url)
        restore_sessions(profile, backup)
        pending.unlink(missing_ok=True)
    if success:
        atomic_write(marker, json.dumps({"configuration": expected, "checks": checks}, indent=2))


def install():
    require_closed()
    if not (CONFIG / "browsers/firefox.yml").is_file():
        fail("Open Web App Hub once, close it, then rerun install. Firefox's template was not found.")
    entries = apps()
    # Detect unmapped profiles before changing anything. A URL must come from
    # Web App Hub's own launcher metadata, never from a guessed profile name.
    mapped = {entry[2] for entry in entries}
    unmapped = [p.name for p in (PROFILES.iterdir() if PROFILES.exists() else [])
                if p.is_dir() and p.resolve() not in mapped]
    if unmapped:
        fail("No matching isolated Firefox launcher metadata for profiles: " + ", ".join(sorted(unmapped)) +
             ". No launchers changed. Send this message so the URL mapping can be resolved.")
    download_addons()
    preflight = STATE / ("preflight-" + stamp())
    try:
        configure(preflight, "https://example.com/", force=True)
    finally:
        if preflight.exists() and not profile_busy(preflight):
            shutil.rmtree(preflight)
    print("Firefox setup preflight passed.", flush=True)
    # All app setup must succeed before switching any launcher to this script.
    for _, _, profile, url in entries:
        configure(profile, url)
    backup = STATE / "backups" / (stamp() + "-install")
    backup.mkdir(parents=True)
    file_records = []
    def save(path, content):
        target = backup / str(len(file_records))
        existed = path.is_file()
        if existed:
            shutil.copy2(path, target)
        file_records.append({"path": str(path), "existed": existed, "backup": str(target)})
        atomic_write(path, content)
        atomic_write(backup / "files.json", json.dumps(file_records, indent=2))
    save(INSTALLED, Path(__file__).read_bytes())
    save(CONFIG / "browsers/firefox-omar.yml", """name: Firefox Omar
flatpak: org.mozilla.firefox
can_isolate: true
desktop_file_name_prefix: org.mozilla.firefox.firefox
base: firefox
""")
    # URL lookup happens inside the launcher, so encoded URLs never become
    # accidental Desktop Entry field codes in Exec.
    template = """[Desktop Entry]
Version=1.0
Type=Application
Terminal=false
Name=%{name}
Exec=/usr/bin/python3 SCRIPT launch -- %{command} --class=%{app_id} --name=%{app_id} %{is_isolated ? --profile} --no-remote
X-MultipleArgs=false
Icon=%{icon}
StartupWMClass=%{app_id}
""".replace("SCRIPT", desktop_arg(str(INSTALLED)))
    save(CONFIG / "desktop-files/firefox-omar.desktop", template)
    save(CONFIG / "profiles/firefox-omar/user.js", preference_text(PREFS))
    for path, info, profile, _ in entries:
        save(path, desktop_change(path.read_text(), {
            "X-WAH-BROWSER-ID": BROWSER_ID,
            "Exec": desktop_exec(info["StartupWMClass"], profile),
        }))
    print("Installed. Converted", len(entries), "existing isolated Firefox apps.")
    print("For NEW apps select: Firefox Omar (Flatpak), with isolation enabled.")
    print("Installer file backups:", backup)


def launch(argv):
    if argv and argv[0] == "--":
        argv = argv[1:]
    if argv[:3] != ["flatpak", "run", FF_ID]:
        fail("This launcher supports only the Firefox Flatpak.")
    profile_arg = next((x.split("=", 1)[1] for x in argv if x.startswith("--profile=")), None)
    if profile_arg is None and "--profile" in argv:
        profile_arg = argv[argv.index("--profile") + 1]
    if not profile_arg:
        fail("Enable profile isolation for this app in Web App Hub.")
    profile = Path(profile_arg).expanduser().resolve()
    matches = [entry for entry in apps() if entry[2] == profile]
    urls = {entry[3] for entry in matches}
    if len(urls) != 1:
        fail("Cannot find one Web App Hub URL for profile " + str(profile))
    url = urls.pop()
    locks = STATE / "locks"
    locks.mkdir(parents=True, exist_ok=True)
    with (locks / (profile.name + ".lock")).open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not profile_busy(profile):
            configure(profile, url)
        # Session restoration already supplies the tabs on normal reopening.
        if not (profile / "sessionstore.jsonlz4").exists():
            argv.append(url)
        os.execvp(argv[0], argv)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=["install", "launch", "repair"])
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.action == "install":
        install()
    elif args.action == "repair":
        require_closed()
        for _, _, profile, url in apps():
            configure(profile, url, force=True)
    else:
        launch(args.arguments)


if __name__ == "__main__":
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        message = "WAH defaults: " + str(error)
        print(message, file=sys.stderr, flush=True)
        if len(sys.argv) > 1 and sys.argv[1] == "launch":
            logs = STATE / "logs"
            logs.mkdir(parents=True, exist_ok=True)
            atomic_write(logs / "last-launch-error.txt", message + "\n")
            notify = shutil.which("notify-send")
            if notify:
                subprocess.run([notify, "Web app setup failed", message], check=False)
        sys.exit(1)
