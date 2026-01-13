#!/usr/bin/env python3
"""
Requirements:
  pip install requests python-dotenv requests-toolbelt
"""
from __future__ import annotations

import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

import requests
from dotenv import load_dotenv
from requests_toolbelt.multipart.encoder import MultipartEncoder

# -------------------------
# config
# -------------------------
load_dotenv()

CLOUD_EMAIL = os.getenv("CLOUD_EMAIL", "").strip()
CLOUD_PASSWORD = os.getenv("CLOUD_PASSWORD", "").strip()
if not CLOUD_EMAIL or not CLOUD_PASSWORD:
    raise SystemExit("CLOUD_EMAIL and CLOUD_PASSWORD must be set")

# cloud folder IDs
DOCKER_FOLDER_ID = 17922957
STORAGE_FOLDER_ID = 17922958

# local backup roots
LOCAL_DOCKER_ROOT = Path("/backups/docker")
LOCAL_STORAGE_ROOT = Path("/backups/gocryptfs")

# logging
LOG_FILE = "/opt/backup-uploader/cloud_backup_sync.log"

MANIFEST_FILE = Path("/opt/backup-uploader/docker_manifest.json")

# endpoints
BASE = "https://cloud.o2online.es"
UPLOAD_BASE = "https://upload.cloud.o2online.es/sapi/upload?action=save&acceptasynchronous=true"
LOGIN_URL = f"{BASE}/sapi/login?action=login"
CREATE_FOLDER_URL = f"{BASE}/sapi/media/folder?action=save"
LIST_FOLDER_URL = f"{BASE}/sapi/media/folder?action=list"

REQUEST_TIMEOUT = (10, 600)
MAX_UPLOAD_RETRIES = 3
RETRY_DELAY = 5

COMMON_HEADERS = {
    "Origin": BASE,
    "Referer": BASE + "/",
    "User-Agent": "backup-sync-script/1.0",
}

# -------------------------
# helpers
# -------------------------
def log(msg: str):
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{now}] {msg}"
    print(line)
    with open(LOG_FILE, "a") as f:
        f.write(line + "\n")

def generate_device_id() -> str:
    import random
    return "web-" + "".join(random.choices("0123456789abcdef", k=32))

def get_latest_cloud_folder(session: requests.Session, validation_key: str, parent_id: int) -> dict | None:
    url = f"{LIST_FOLDER_URL}&parentid={parent_id}&limit=200&validationkey={validation_key}"
    r = session.get(url, headers=COMMON_HEADERS, timeout=REQUEST_TIMEOUT)
    r.raise_for_status()
    folders = r.json().get("data", {}).get("folders", [])
    if not folders:
        return None
    # carpeta más reciente por timestamp cloud
    return max(folders, key=lambda f: f.get("date", 0))

def login(session: requests.Session) -> str:
    r = session.get(BASE + "/", timeout=REQUEST_TIMEOUT)
    r.raise_for_status()
    payload = f"login={quote(CLOUD_EMAIL)}&password={quote(CLOUD_PASSWORD)}&rememberme=true"
    headers = {**COMMON_HEADERS, "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8", "Accept": "*/*", "X-deviceid": generate_device_id()}
    r = session.post(LOGIN_URL, data=payload, headers=headers, timeout=REQUEST_TIMEOUT)
    r.raise_for_status()
    key = r.json().get("data", {}).get("validationkey")
    if not key:
        raise RuntimeError(f"Login failed: {r.json()}")
    return key

def create_cloud_folder(session: requests.Session, validation_key: str, folder_name: str, parent_id: int) -> int:
    url = f"{CREATE_FOLDER_URL}&validationkey={validation_key}"
    payload = {"data": {"magic": False, "offline": False, "name": folder_name, "parentid": parent_id}}
    r = session.post(url, json=payload, headers={**COMMON_HEADERS, "Content-Type": "application/json"}, timeout=REQUEST_TIMEOUT)
    r.raise_for_status()
    folder_id = r.json().get("data", {}).get("folder", {}).get("id") or r.json().get("id")
    if not folder_id:
        raise RuntimeError(f"Failed to create folder: {r.json()}")
    return int(folder_id)

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
            log(f"Upload attempt {attempt} failed for {file_path.name}: {exc}. Retrying in {RETRY_DELAY}s")
            time.sleep(RETRY_DELAY)
        finally:
            if fh:
                fh.close()
    raise RuntimeError(f"Failed uploading {file_path} after {MAX_UPLOAD_RETRIES} attempts: last error: {last_exc}")

def load_manifest(path: Path) -> dict[str, int]:
    if not path.exists():
        return {}
    with open(path, "r") as f:
        return json.load(f)


def save_manifest(path: Path, data: dict[str, int]):
    tmp = path.with_suffix(".tmp")
    with open(tmp, "w") as f:
        json.dump(data, f)
    tmp.replace(path)

def delete_cloud_file(session: requests.Session, validation_key: str, file_id: int):
    url = f"{BASE}/sapi/media/file?action=delete&softdelete=true&validationkey={validation_key}"
    payload = {"data": {"files": [file_id]}}
    headers = {"Content-Type": "application/json", **COMMON_HEADERS, "Accept": "application/json"}
    
    r = session.post(url, json=payload, headers=headers, timeout=REQUEST_TIMEOUT)
    log(f"DELETE RESPONSE for file_id {file_id}: status={r.status_code} body={r.text[:500]}")
    
    r.raise_for_status()
    return True

def get_cloud_folders(session: requests.Session, validation_key: str, parent_id: int) -> list[dict]:
    """Lista todas las subcarpetas de un folder padre en la nube."""
    url = f"{LIST_FOLDER_URL}&parentid={parent_id}&limit=200&validationkey={validation_key}"
    r = session.get(url, headers=COMMON_HEADERS, timeout=REQUEST_TIMEOUT)
    r.raise_for_status()
    return r.json().get("data", {}).get("folders", [])


def get_cloud_files(session: requests.Session, validation_key: str, folder_id: int) -> list[dict]:
    """Lista todos los archivos de una carpeta de la nube."""
    url = f"{BASE}/sapi/media?action=get&folderid={folder_id}&limit=200&validationkey={validation_key}"
    payload = {"data": {"fields": ["name", "modificationdate", "size", "etag"]}}
    r = session.post(url, json=payload, headers={**COMMON_HEADERS, "Content-Type": "application/json"}, timeout=REQUEST_TIMEOUT)
    r.raise_for_status()
    return r.json().get("data", {}).get("media", [])

def sync_local_folder(session: requests.Session, validation_key: str, parent_id: int, local_root: Path, manifest_file: Path):
    if not local_root.exists():
        log(f"{local_root} does not exist, skipping.")
        return
    local_files = {f.name: f for f in local_root.iterdir() if f.is_file()}
    if not local_files:
        log(f"No files in {local_root}, skipping.")
        return

    cloud_folders = get_cloud_folders(session, validation_key, parent_id)
    if cloud_folders:
        cloud_folder = max(cloud_folders, key=lambda f: f.get("date", 0))
        cloud_folder_id = cloud_folder["id"]
        folder_name = cloud_folder["name"]
        log(f"Syncing '{local_root}' -> existing cloud folder '{folder_name}' (id={cloud_folder_id})")
    else:
        last_file = max(local_files.values(), key=lambda f: f.stat().st_mtime)
        folder_name = datetime.fromtimestamp(last_file.stat().st_mtime).strftime("%Y%m%d_%H%M%S")
        cloud_folder_id = create_cloud_folder(session, validation_key, folder_name, parent_id)
        log(f"Created cloud folder '{folder_name}' id={cloud_folder_id}")

    manifest = load_manifest(manifest_file)
    cloud_files = get_cloud_files(session, validation_key, cloud_folder_id)
    cloud_files_map = {f["name"]: f for f in cloud_files}

    for name, f in sorted(local_files.items(), key=lambda x: x[1].stat().st_mtime):
        size = f.stat().st_size
        cloud_f = cloud_files_map.get(name)
        if cloud_f and manifest.get(name) == size and cloud_f["size"] == size:
            log(f"Skip {name} (already uploaded)")
            continue
        try:
            log(f"Uploading {name} ({size} bytes)")
            upload_file(session, validation_key, cloud_folder_id, f)
            manifest[name] = size
            save_manifest(manifest_file, manifest)
            log(f"Uploaded {name}")
        except Exception as e:
            log(f"ERROR uploading {name}: {e}")

    for name, cloud_f in cloud_files_map.items():
        if name not in local_files:
            try:
                log(f"Deleting {name} from cloud (no longer in local)")
                delete_cloud_file(session, validation_key, cloud_f["id"])
                log(f"Deleted {name}")
            except Exception as e:
                log(f"ERROR deleting {name}: {e}")

# -------------------------
# main
# -------------------------
def main():
    with requests.Session() as session:
        vk = login(session)
        log(f"Logged in, validationKey: {vk[:8]}...")

        # docker
        sync_local_folder(session, vk, DOCKER_FOLDER_ID, LOCAL_DOCKER_ROOT, manifest_file=Path("/opt/backup-uploader/docker_manifest.json"))

        # gocryptfs
        sync_local_folder(session, vk, STORAGE_FOLDER_ID, LOCAL_STORAGE_ROOT, manifest_file=Path("/opt/backup-uploader/gocryptfs_manifest.json"))

if __name__ == "__main__":
    main()
