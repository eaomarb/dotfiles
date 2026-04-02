#!/usr/bin/env python3
"""
Requirements:
  pip install requests python-dotenv requests-toolbelt
"""
from __future__ import annotations

import json
import os
import re
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote
from typing import Dict, List, Optional, Tuple

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

# retention in days for cloud folders (set to 0 to disable deletion)
RETENTION_DAYS = 30

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
    "User-Agent": "backup-sync-script/2.0",
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

def get_cloud_folders(session: requests.Session, validation_key: str, parent_id: int) -> List[dict]:
    """List all subfolders under a parent folder."""
    url = f"{LIST_FOLDER_URL}&parentid={parent_id}&limit=200&validationkey={validation_key}"
    r = session.get(url, headers=COMMON_HEADERS, timeout=REQUEST_TIMEOUT)
    r.raise_for_status()
    return r.json().get("data", {}).get("folders", [])

def get_cloud_folder_by_name(session: requests.Session, validation_key: str, parent_id: int, name: str) -> Optional[int]:
    folders = get_cloud_folders(session, validation_key, parent_id)
    for f in folders:
        if f.get("name") == name:
            return f["id"]
    return None

def get_cloud_files(session: requests.Session, validation_key: str, folder_id: int) -> List[dict]:
    """List all files in a cloud folder."""
    url = f"{BASE}/sapi/media?action=get&folderid={folder_id}&limit=200&validationkey={validation_key}"
    payload = {"data": {"fields": ["name", "modificationdate", "size", "etag"]}}
    r = session.post(url, json=payload, headers={**COMMON_HEADERS, "Content-Type": "application/json"}, timeout=REQUEST_TIMEOUT)
    r.raise_for_status()
    return r.json().get("data", {}).get("media", [])

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

def delete_cloud_folder(session: requests.Session, validation_key: str, folder_id: int):
    """Delete a folder (and all its contents) from the cloud."""
    # First, list and delete all files inside the folder (required by the API)
    files = get_cloud_files(session, validation_key, folder_id)
    if files:
        delete_file_url = f"{BASE}/sapi/media/file?action=delete&softdelete=true&validationkey={validation_key}"
        file_ids = [f["id"] for f in files]
        payload = {"data": {"files": file_ids}}
        headers = {"Content-Type": "application/json", **COMMON_HEADERS, "Accept": "application/json"}
        r = session.post(delete_file_url, json=payload, headers=headers, timeout=REQUEST_TIMEOUT)
        r.raise_for_status()
        log(f"Deleted {len(file_ids)} files from folder {folder_id}")

    # Then delete the folder itself
    delete_folder_url = f"{BASE}/sapi/media/folder?action=delete&softdelete=true&validationkey={validation_key}"
    payload = {"data": {"folders": [folder_id]}}
    headers = {"Content-Type": "application/json", **COMMON_HEADERS, "Accept": "application/json"}
    r = session.post(delete_folder_url, json=payload, headers=headers, timeout=REQUEST_TIMEOUT)
    r.raise_for_status()
    log(f"Deleted folder {folder_id}")

def cleanup_old_folders(session: requests.Session, validation_key: str, parent_id: int, retention_days: int):
    """Delete folders older than retention_days (based on their creation date)."""
    if retention_days <= 0:
        return
    cutoff = datetime.now() - timedelta(days=retention_days)
    folders = get_cloud_folders(session, validation_key, parent_id)
    for folder in folders:
        created_ts = folder.get("date")
        if not created_ts:
            continue

        # Safely convert timestamp, skip if invalid (out of range, negative, etc.)
        try:
            created_dt = datetime.fromtimestamp(created_ts)
        except (ValueError, OverflowError, OSError) as e:
            log(f"WARNING: Invalid timestamp {created_ts} for folder '{folder.get('name')}' (id={folder.get('id')}): {e}. Skipping deletion.")
            continue

        # Optional: additional sanity check (year > 2100 is very likely wrong)
        if created_dt.year > 2100:
            log(f"WARNING: Folder '{folder.get('name')}' has year {created_dt.year} which is far in the future (timestamp {created_ts}). Skipping deletion.")
            continue

        if created_dt < cutoff:
            log(f"Deleting old folder '{folder['name']}' (id={folder['id']}) created on {created_dt}")
            delete_cloud_folder(session, validation_key, folder["id"])

# -------------------------
# Backup grouping logic
# -------------------------
def group_files_by_backup(local_root: Path, backup_type: str) -> Dict[str, List[Path]]:
    """
    Group files in local_root by the backup timestamp found in their names.
    Returns a dict {timestamp: list_of_paths}.
    """
    groups = {}
    if backup_type == "docker":
        # Pattern: docker_YYYY-MM-DD_HHMM.tar.gz.part.*
        pattern = re.compile(r"docker_(\d{4}-\d{2}-\d{2}_\d{4})\.tar\.gz\.part\..+")
    elif backup_type == "dar":
        # Pattern: backup_data_YYYYMMDD_HHMMSS.dar or backup_data_YYYYMMDD_HHMMSS.1.dar, etc.
        pattern = re.compile(r"backup_data_(\d{8}_\d{6})(?:\.\d+)?\.dar")
    else:
        raise ValueError("backup_type must be 'docker' or 'dar'")

    for file_path in local_root.iterdir():
        if not file_path.is_file():
            continue
        match = pattern.match(file_path.name)
        if match:
            ts = match.group(1)
            groups.setdefault(ts, []).append(file_path)
    return groups

def upload_backup_set(session: requests.Session, validation_key: str, parent_id: int,
                      folder_name: str, local_files: List[Path]) -> None:
    """
    Upload a set of files (one backup execution) to a cloud folder.
    If the folder does not exist, it is created. Only missing files are uploaded.
    """
    # Find or create the folder
    folder_id = get_cloud_folder_by_name(session, validation_key, parent_id, folder_name)
    if folder_id is None:
        folder_id = create_cloud_folder(session, validation_key, folder_name, parent_id)
        log(f"Created cloud folder '{folder_name}' (id={folder_id})")
    else:
        log(f"Using existing cloud folder '{folder_name}' (id={folder_id})")

    # List existing files in that folder
    existing_files = {f["name"]: f["size"] for f in get_cloud_files(session, validation_key, folder_id)}

    for local_file in sorted(local_files, key=lambda p: p.name):
        if local_file.name in existing_files and existing_files[local_file.name] == local_file.stat().st_size:
            log(f"Skipping {local_file.name} (already uploaded)")
            continue
        log(f"Uploading {local_file.name} ({local_file.stat().st_size} bytes)")
        upload_file(session, validation_key, folder_id, local_file)
        log(f"Uploaded {local_file.name}")

def sync_local_backups(session: requests.Session, validation_key: str, parent_id: int,
                       local_root: Path, backup_type: str, retention_days: int) -> None:
    """Main sync function: group local backups, upload each set, and clean up old folders."""
    if not local_root.exists():
        log(f"{local_root} does not exist, skipping.")
        return

    # Group files by their backup timestamp
    groups = group_files_by_backup(local_root, backup_type)
    if not groups:
        log(f"No valid backup files found in {local_root}")
        return

    log(f"Found {len(groups)} backup sets in {local_root}")

    # Process each backup set (newest first? doesn't matter)
    for ts, files in groups.items():
        # The folder name will be the timestamp itself (or prefixed with type)
        folder_name = ts
        upload_backup_set(session, validation_key, parent_id, folder_name, files)

    # Clean up old folders (based on retention days)
    if retention_days > 0:
        cleanup_old_folders(session, validation_key, parent_id, retention_days)

# -------------------------
# main
# -------------------------
def main():
    with requests.Session() as session:
        vk = login(session)
        log(f"Logged in, validationKey: {vk[:8]}...")

        # Process Docker backups - catch errors so storage backup still runs
        try:
            sync_local_backups(session, vk, DOCKER_FOLDER_ID, LOCAL_DOCKER_ROOT,
                               backup_type="docker", retention_days=RETENTION_DAYS)
        except Exception as e:
            log(f"ERROR while syncing Docker backups: {e}. Continuing with storage backups.")

        # Process DAR (gocryptfs) backups
        try:
            sync_local_backups(session, vk, STORAGE_FOLDER_ID, LOCAL_STORAGE_ROOT,
                               backup_type="dar", retention_days=RETENTION_DAYS)
        except Exception as e:
            log(f"ERROR while syncing storage backups: {e}.")

if __name__ == "__main__":
    main()
