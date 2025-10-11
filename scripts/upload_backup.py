#!/usr/bin/env python3
"""
Requirements (inside venv):
  pip install requests requests-toolbelt python-dotenv
"""
from __future__ import annotations

import json
import os
import random
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

import requests
from dotenv import load_dotenv
from requests_toolbelt.multipart.encoder import MultipartEncoder

# -------------------------
# configuration
# -------------------------
load_dotenv()  # load .env into environment

CLOUD_EMAIL = os.getenv("CLOUD_EMAIL", "").strip()
CLOUD_PASSWORD = os.getenv("CLOUD_PASSWORD", "").strip()
if not CLOUD_EMAIL or not CLOUD_PASSWORD:
    raise SystemExit("CLOUD_EMAIL and CLOUD_PASSWORD must be set (in .env or environment)")

# cloud folder ids
DOCKER_PARENT_FOLDER_ID = 17922957       # where nightly/biweekly live (renamed from PARENT_FOLDER_ID)
STORAGE_PARENT_FOLDER_ID = 17922958      # where storage backups go
BITWARDEN_PARENT_FOLDER_ID = 17922956

# local roots
LOCAL_DOCKER_BACKUP_ROOT = "/backups/docker-tar"       # nightly & biweekly (renamed from LOCAL_BACKUP_ROOT)
LOCAL_STORAGE_ROOT = "/backups/storage-exports"        # storage exports (monthly + snapshot)
LOCAL_BITWARDEN_ROOT = "/backups/bitwarden"

# retention / rules
KEEP_NIGHTLY = 2
KEEP_BIWEEKLY = 5
KEEP_MONTHLY = 1
KEEP_SNAPSHOT = 1
KEEP_BITWARDEN = 10

# endpoints
BASE = "https://cloud.o2online.es"
UPLOAD_BASE = "https://upload.cloud.o2online.es/sapi/upload?action=save&acceptasynchronous=true"
LOGIN_URL = f"{BASE}/sapi/login?action=login"
CREATE_FOLDER_URL = f"{BASE}/sapi/media/folder?action=save"
LIST_FOLDER_URL = f"{BASE}/sapi/media/folder?action=list"

# networking / retries
REQUEST_TIMEOUT = (10, 600)  # connect, read (seconds)
MAX_UPLOAD_RETRIES = 3
RETRY_DELAY = 5  # seconds

# common headers used for non-upload requests
COMMON_HEADERS = {
    "Origin": "https://cloud.o2online.es",
    "Referer": "https://cloud.o2online.es/",
    "User-Agent": "upload-backup-script/1.0",
}

# -------------------------
# helpers
# -------------------------
def generate_device_id() -> str:
    return "web-" + "".join(random.choices("0123456789abcdef", k=32))


def get_latest_folder_in(root_dir: str | Path) -> Path | None:
    p = Path(root_dir)
    if not p.exists():
        return None
    folders = [f for f in p.iterdir() if f.is_dir()]
    if not folders:
        return None
    return max(folders, key=lambda d: d.stat().st_mtime)


# -------------------------
# API calls
# -------------------------
def login(session: requests.Session) -> str:
    # initial GET to receive cookies
    r = session.get(BASE + "/", timeout=REQUEST_TIMEOUT)
    r.raise_for_status()

    payload = f"login={quote(CLOUD_EMAIL)}&password={quote(CLOUD_PASSWORD)}&rememberme=true"
    headers = {
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        "X-deviceid": generate_device_id(),
        **COMMON_HEADERS,
        "Accept": "*/*",
    }

    r = session.post(LOGIN_URL, data=payload, headers=headers, timeout=REQUEST_TIMEOUT)
    r.raise_for_status()

    data = r.json()
    validation_key = data.get("data", {}).get("validationkey")
    if not validation_key:
        raise RuntimeError(f"Login failed to return validationKey. Response: {data} Cookies: {session.cookies.get_dict()}")
    return validation_key


def create_cloud_folder(session: requests.Session, validation_key: str, folder_name: str, parent_id: int) -> int:
    url = f"{CREATE_FOLDER_URL}&validationkey={validation_key}"
    payload = {"data": {"magic": False, "offline": False, "name": folder_name, "parentid": parent_id}}
    headers = {"Content-Type": "application/json; charset=UTF-8", "Accept": "application/json, text/javascript, */*; q=0.01", **COMMON_HEADERS}
    r = session.post(url, json=payload, headers=headers, timeout=REQUEST_TIMEOUT)
    r.raise_for_status()
    data = r.json()
    folder_id = data.get("data", {}).get("folder", {}).get("id") or data.get("id")
    if not folder_id:
        raise RuntimeError(f"Failed to create folder. Response: {data}")
    return int(folder_id)


def list_child_folders(session: requests.Session, validation_key: str, parent_id: int) -> list[dict]:
    url = f"{LIST_FOLDER_URL}&parentid={parent_id}&limit=200&validationkey={validation_key}"
    headers = {**COMMON_HEADERS, "Accept": "application/json"}
    r = session.get(url, headers=headers, timeout=REQUEST_TIMEOUT)
    r.raise_for_status()
    return r.json().get("data", {}).get("folders", []) or []


def soft_delete_folder(session: requests.Session, validation_key: str, folder_id: int) -> dict:
    url = f"{BASE}/sapi/media/folder?action=softdelete&validationkey={validation_key}"
    payload = {"data": {"ids": [folder_id]}}
    headers = {"Content-Type": "application/json", **COMMON_HEADERS, "Accept": "application/json, text/javascript, */*; q=0.01"}
    r = session.post(url, json=payload, headers=headers, timeout=REQUEST_TIMEOUT)
    r.raise_for_status()
    return r.json()


def copy_cookies_to_upload_domain(session: requests.Session) -> None:
    cookies = session.cookies.get_dict(domain="cloud.o2online.es")
    for name, value in cookies.items():
        session.cookies.set(name, value, domain="upload.cloud.o2online.es")


def upload_file(session: requests.Session, validation_key: str, folder_id: int, file_path: Path) -> dict:
    url = f"{UPLOAD_BASE}&validationkey={validation_key}"
    stats = file_path.stat()
    data_part = {
        "data": {
            "name": file_path.name,
            "size": stats.st_size,
            "modificationdate": datetime.fromtimestamp(stats.st_mtime, tz=timezone.utc).strftime("%Y%m%dT%H%M%SZ"),
            "contenttype": "application/octet-stream",
            "folderid": folder_id,
        }
    }

    copy_cookies_to_upload_domain(session)

    last_exc = None
    for attempt in range(1, MAX_UPLOAD_RETRIES + 1):
        fh = None
        try:
            fh = open(file_path, "rb")
            m = MultipartEncoder(fields={"data": json.dumps(data_part), "file": (file_path.name, fh, "application/octet-stream")})
            headers = {"Content-Type": m.content_type, "X-deviceid": generate_device_id(), **COMMON_HEADERS, "Accept": "*/*"}
            r = session.post(url, data=m, headers=headers, timeout=REQUEST_TIMEOUT)
            r.raise_for_status()
            return r.json()
        except (requests.exceptions.ChunkedEncodingError, requests.exceptions.ConnectionError, requests.exceptions.Timeout) as exc:
            last_exc = exc
            print(f"Upload attempt {attempt} for {file_path.name} failed: {exc}. Retrying in {RETRY_DELAY}s...")
            time.sleep(RETRY_DELAY)
        except requests.exceptions.HTTPError as http_err:
            text = "<no body>"
            try:
                text = r.text[:1000]
            except Exception:
                pass
            raise RuntimeError(f"HTTP error during upload: {http_err}. Body: {text}")
        finally:
            if fh:
                try:
                    fh.close()
                except Exception:
                    pass

    raise RuntimeError(f"Failed uploading {file_path} after {MAX_UPLOAD_RETRIES} attempts: last error: {last_exc}")


# -------------------------
# retention & cleanup
# -------------------------
def cleanup_two_types(session: requests.Session, validation_key: str, parent_id: int, keep_nightly: int = KEEP_NIGHTLY, keep_biweekly: int = KEEP_BIWEEKLY) -> None:
    folders = list_child_folders(session, validation_key, parent_id)
    nightly = [f for f in folders if f.get("name", "").startswith("nightly-")]
    nightly_sorted = sorted(nightly, key=lambda f: f.get("date", 0))
    for f in nightly_sorted[:-keep_nightly]:
        print(f"Deleting old nightly {f['name']} (id {f['id']})")
        soft_delete_folder(session, validation_key, f["id"])

    biweekly = [f for f in folders if f.get("name", "").startswith("biweekly-")]
    biweekly_sorted = sorted(biweekly, key=lambda f: f.get("date", 0))
    for f in biweekly_sorted[:-keep_biweekly]:
        print(f"Deleting old biweekly {f['name']} (id {f['id']})")
        soft_delete_folder(session, validation_key, f["id"])


def cleanup_storage_types(session: requests.Session, validation_key: str, parent_id: int, keep_monthly: int = KEEP_MONTHLY, keep_snapshot: int = KEEP_SNAPSHOT) -> None:
    folders = list_child_folders(session, validation_key, parent_id)
    monthly = [f for f in folders if f.get("name", "").startswith("monthly-")]
    snapshot = [f for f in folders if f.get("name", "").startswith("snapshot-")]

    monthly_sorted = sorted(monthly, key=lambda f: f.get("date", 0))
    for f in monthly_sorted[:-keep_monthly]:
        print(f"Deleting old monthly {f['name']} (id {f['id']})")
        soft_delete_folder(session, validation_key, f["id"])

    snapshot_sorted = sorted(snapshot, key=lambda f: f.get("date", 0))
    for f in snapshot_sorted[:-keep_snapshot]:
        print(f"Deleting old snapshot {f['name']} (id {f['id']})")
        soft_delete_folder(session, validation_key, f["id"])


def cleanup_bitwarden_backups(session: requests.Session, validation_key: str, parent_id: int, keep: int = KEEP_BITWARDEN) -> None:
    folders = list_child_folders(session, validation_key, parent_id)
    if not folders:
        return
    folder_id = folders[0]["id"]  # assuming one folder per Bitwarden backups
    url = f"{BASE}/sapi/media/folder?action=list&parentid={folder_id}&limit=200&validationkey={validation_key}"
    headers = {"User-Agent": "upload-backup-script/1.0"}
    r = session.get(url, headers=headers, timeout=REQUEST_TIMEOUT)
    r.raise_for_status()
    files = r.json().get("data", {}).get("files", [])
    files_sorted = sorted(files, key=lambda f: f.get("date", 0))
    for f in files_sorted[:-keep]:
        print(f"Deleting old Bitwarden backup {f['name']} (id {f['id']})")
        soft_delete_folder(session, validation_key, f["id"])  # folder API also works for files


# -------------------------
# storage upload logic
# -------------------------
def cloud_has_folder(session: requests.Session, validation_key: str, parent_id: int, local_folder_name: str) -> bool:
    folders = list_child_folders(session, validation_key, parent_id)
    return any(f.get("name") == local_folder_name for f in folders)


def upload_new_storage_backups(session: requests.Session, validation_key: str) -> None:
    root = Path(LOCAL_STORAGE_ROOT)
    if not root.exists():
        print("Storage export folder not present, skipping storage uploads.")
        return

    monthly_dir = root / "monthly"
    latest_monthly = get_latest_folder_in(monthly_dir) if monthly_dir.exists() else None

    snapshot_dirs = [d for d in root.iterdir() if d.is_dir() and d.name.startswith("snapshot-")]
    latest_snapshot = max(snapshot_dirs, key=lambda f: f.stat().st_mtime) if snapshot_dirs else None

    # Upload snapshot if not present on cloud
    if latest_snapshot and not cloud_has_folder(session, validation_key, STORAGE_PARENT_FOLDER_ID, latest_snapshot.name):
        print(f"Uploading new storage snapshot: {latest_snapshot.name}")
        cloud_folder_id = create_cloud_folder(session, validation_key, latest_snapshot.name, STORAGE_PARENT_FOLDER_ID)
        for part in sorted(latest_snapshot.iterdir()):
            if part.is_file():
                print(f"Uploading storage part {part.name} ...")
                upload_file(session, validation_key, cloud_folder_id, part)
        cleanup_storage_types(session, validation_key, STORAGE_PARENT_FOLDER_ID, keep_monthly=KEEP_MONTHLY, keep_snapshot=KEEP_SNAPSHOT)

    # Upload monthly if not present
    if latest_monthly and not cloud_has_folder(session, validation_key, STORAGE_PARENT_FOLDER_ID, latest_monthly.name):
        print(f"Uploading new monthly export: {latest_monthly.name}")
        cloud_folder_id = create_cloud_folder(session, validation_key, latest_monthly.name, STORAGE_PARENT_FOLDER_ID)
        for part in sorted(latest_monthly.iterdir()):
            if part.is_file():
                print(f"Uploading monthly part {part.name} ...")
                upload_file(session, validation_key, cloud_folder_id, part)
        cleanup_storage_types(session, validation_key, STORAGE_PARENT_FOLDER_ID, keep_monthly=KEEP_MONTHLY, keep_snapshot=KEEP_SNAPSHOT)


def upload_bitwarden_backups(session: requests.Session, validation_key: str) -> None:
    root = Path(LOCAL_BITWARDEN_ROOT)
    if not root.exists():
        print("Bitwarden backup folder not found, skipping.")
        return

    cloud_folders = list_child_folders(session, validation_key, BITWARDEN_PARENT_FOLDER_ID)
    if cloud_folders:
        cloud_folder_id = cloud_folders[0]["id"]
    else:
        cloud_folder_id = create_cloud_folder(session, validation_key, "bitwarden-backups", BITWARDEN_PARENT_FOLDER_ID)

    for f in sorted(root.iterdir()):
        if f.is_file() and f.suffix == ".json":
            if not cloud_has_folder(session, validation_key, cloud_folder_id, f.name):
                print(f"Uploading Bitwarden backup {f.name} ...")
                upload_file(session, validation_key, cloud_folder_id, f)

    cleanup_bitwarden_backups(session, validation_key, cloud_folder_id, KEEP_BITWARDEN)


# -------------------------
# main flow
# -------------------------
def main() -> None:
    latest_backup = get_latest_folder_in(LOCAL_DOCKER_BACKUP_ROOT)

    with requests.Session() as session:
        validation_key = login(session)
        print(f"Logged in, validationKey: {validation_key[:8]}...")

        # Docker/nightly/biweekly upload
        if latest_backup:
            print(f"Latest local backup folder: {latest_backup}")
            cloud_folder_id = create_cloud_folder(session, validation_key, latest_backup.name, DOCKER_PARENT_FOLDER_ID)
            print(f"Created cloud folder '{latest_backup.name}' id={cloud_folder_id}")
            for p in sorted(latest_backup.iterdir()):
                if p.is_file():
                    print(f"Uploading {p.name} ...")
                    res = upload_file(session, validation_key, cloud_folder_id, p)
                    print(f"Uploaded {p.name}: {res}")
            cleanup_two_types(session, validation_key, DOCKER_PARENT_FOLDER_ID, keep_nightly=KEEP_NIGHTLY, keep_biweekly=KEEP_BIWEEKLY)

        # Storage backups (monthly / snapshot)
        upload_new_storage_backups(session, validation_key)

        # Bitwarden backups
        upload_bitwarden_backups(session, validation_key)


if __name__ == "__main__":
    main()