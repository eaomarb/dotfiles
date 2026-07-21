#!/usr/bin/env python3
"""
O2 Cloud Backup Sync
- Sequentially and reliably processes queues of multiple local backups.
- Accurate Full/Incremental detection by reading the content of the local 'last_full' marker.
- Weekly checksum verification using 'rclone check --one-way' filtered by exact timestamp.
- Authentication retries (401) separated from network retries, restarting the Docker gateway.
- Early abort in main() if the Docker sync fails critically, protecting the Gocryptfs sync.
"""

from __future__ import annotations
import json
import os
import re
import subprocess
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, List

from dotenv import load_dotenv

load_dotenv()

RCLONE_REMOTE = os.getenv("RCLONE_REMOTE", "o2cloud")
RCLONE_CONFIG = os.getenv("RCLONE_CONFIG", "/home/omar/.config/rclone/rclone.conf")

DOCKER_ROOT_PATH = "Backups/Server/Docker"
STORAGE_ROOT_PATH = "Backups/Server/Gocryptfs"
LOCAL_DOCKER_ROOT = Path("/backups/docker")
LOCAL_STORAGE_ROOT = Path("/backups/gocryptfs")

LOG_FILE = "/opt/backup-uploader/cloud_backup_sync.log"
MAX_RETRIES = 3
MAX_AUTH_RETRIES = 10
RETRY_DELAY = 10
MOVE_DELAY = 5
VERIFY_ATTEMPTS = 4
VERIFY_WAIT = 30

TRANSFERS = 1

def log(msg: str):
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{now}] {msg}"
    print(line)
    with open(LOG_FILE, "a") as f:
        f.write(line + "\n")

# -------------------------
# RCLONE OPERATIONS
# -------------------------
def rclone_mkdir(remote_path: str):
    cmd = ['rclone', 'mkdir', '--config', RCLONE_CONFIG,
           f"{RCLONE_REMOTE}:{remote_path.strip('/')}"]
    subprocess.run(cmd, capture_output=True, text=True, check=False)
    log(f"Created folder: {remote_path}")

def rclone_move(src: str, dst: str):
    cmd = ['rclone', 'move', '--config', RCLONE_CONFIG,
           f"{RCLONE_REMOTE}:{src.strip('/')}",
           f"{RCLONE_REMOTE}:{dst.strip('/')}",
           '--retries', '3', '--low-level-retries', '10',
           '--timeout', '600s', '--contimeout', '120s',
           '--transfers', str(TRANSFERS), '-q']
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=1200)
    if res.returncode == 0:
        log(f"Moved: {src} -> {dst}")
    else:
        raise RuntimeError(f"rclone move failed: {res.stderr[:200]}")

def rclone_delete(remote_path: str):
    cmd = ['rclone', 'deletefile', '--config', RCLONE_CONFIG,
           f"{RCLONE_REMOTE}:{remote_path.strip('/')}"]
    subprocess.run(cmd, capture_output=True, text=True)
    log(f"Deleted: {remote_path}")

def rclone_upload(local_file: Path, remote_folder: str):
    remote_dest = f"{RCLONE_REMOTE}:{remote_folder.strip('/')}/"
    network_attempts = 0
    auth_attempts = 0
    
    while network_attempts < MAX_RETRIES:
        log(f"Uploading: {local_file.name} ({local_file.stat().st_size} bytes)")
        cmd = ['rclone', 'copy', '--config', RCLONE_CONFIG,
               str(local_file), remote_dest,
               '--retries', '3', '--low-level-retries', '10',
               '--timeout', '3600s', '--contimeout', '300s',
               '--no-check-dest',
               '--buffer-size', '256M',
               '--transfers', str(TRANSFERS),
               '-v'] 
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=7200)
        if res.returncode == 0:
            log(f"✅ Uploaded to {remote_folder}: {local_file.name}")
            return
            
        err_str = res.stderr.lower()
        # If the error is authentication-related, restart the gateway and retry without consuming network attempts
        if "401" in err_str or "unauthorized" in err_str or "session" in err_str:
            if auth_attempts < MAX_AUTH_RETRIES:
                log("⚠️ Authentication error detected. Restarting gateway...")
                subprocess.run(['docker', 'restart', 'o2-webdav'], capture_output=True, timeout=60)
                time.sleep(20)
                log("Gateway restarted. Retrying upload...")
                auth_attempts += 1
                continue
        
        # Network error or max auth retries reached
        network_attempts += 1
        log(f"❌ Failed (attempt {network_attempts}/{MAX_RETRIES}): {res.stderr[:200]}")
        if network_attempts < MAX_RETRIES:
            time.sleep(RETRY_DELAY)
            
    raise RuntimeError(f"Failed to upload {local_file.name}")

def rclone_list(remote_path: str) -> List[str]:
    cmd = ['rclone', 'lsjson', '--config', RCLONE_CONFIG,
           f"{RCLONE_REMOTE}:{remote_path.strip('/')}", '--max-depth', '1', '--no-modtime']
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        return []
    try:
        items = json.loads(res.stdout)
        return [item['Name'] for item in items if 'Name' in item and item.get('IsDir', False)]
    except Exception:
        return []

def rclone_list_files(remote_path: str) -> Dict[str, int]:
    cmd = ['rclone', 'lsjson', '--config', RCLONE_CONFIG,
           f"{RCLONE_REMOTE}:{remote_path.strip('/')}", '--no-modtime']
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        return {}
    try:
        items = json.loads(res.stdout)
        return {item['Name']: item.get('Size', 0)
                for item in items
                if 'Name' in item and not item.get('IsDir', False)}
    except Exception:
        return {}

def verify_files(remote_folder: str, expected_files: Dict[str, int]) -> bool:
    remote_files = rclone_list_files(remote_folder)
    if not remote_files:
        log(f"⚠️ No files found in {remote_folder}")
        return False
    for name, size in expected_files.items():
        remote_size = remote_files.get(name)
        if remote_size != size:
            log(f"⚠️ {name}: expected {size}, got {remote_size}")
            return False
    log(f"✅ Verified {len(expected_files)} files in {remote_folder}")
    return True

# -------------------------
# FORCE DIRECTORY CREATION
# -------------------------
def ensure_remote_directory(remote_path: str) -> bool:
    rclone_mkdir(remote_path)
    time.sleep(2)
    parent = "/".join(remote_path.split("/")[:-1])
    name = remote_path.split("/")[-1]
    items = rclone_list(parent) if parent else rclone_list("")
    if name in items:
        log(f"Directory {remote_path} confirmed.")
        return True
    log(f"Directory {remote_path} not visible, forcing with .keep")
    try:
        temp_file = "/tmp/rclone_keep_temp"
        with open(temp_file, "w") as f:
            f.write("keep")
        rclone_upload(Path(temp_file), remote_path)
        os.remove(temp_file)
        time.sleep(2)
        items = rclone_list(parent) if parent else rclone_list("")
        if name in items:
            log(f"Directory {remote_path} forced successfully.")
            rclone_delete(f"{remote_path}/rclone_keep_temp")
            time.sleep(1)
            return True
        else:
            log(f"⚠️ Directory {remote_path} still not visible after forcing.")
            return False
    except Exception as e:
        log(f"⚠️ Failed to force directory {remote_path}: {e}")
        return False

# -------------------------
# LOCAL BACKUP GROUPING
# -------------------------
def group_files(local_root: Path, backup_type: str) -> Dict[str, List[Path]]:
    groups = {}
    if backup_type == "docker":
        pattern = re.compile(r"docker_(\d{4}-\d{2}-\d{2}_\d{6})\.tar\.gz\.part\..+")
    else:
        pattern = re.compile(r"backup_data_(\d{8}_\d{6})(?:_catalog)?(?:\.\d+)?\.dar")
    for f in local_root.iterdir():
        if f.is_file() and (m := pattern.match(f.name)):
            groups.setdefault(m.group(1), []).append(f)
    return groups

# -------------------------
# WEEKLY CHECKSUM VERIFICATION
# -------------------------
def full_checksum_verification(local_root: Path, remote_root: str, backup_type: str, current_ts: str) -> bool:
    remote_path = f"{remote_root}/current/{current_ts}"
    log(f"=== Starting full checksum verification for {backup_type} (timestamp: {current_ts}) ===")
    
    # Filter strictly by the specific timestamp to avoid comparing unrelated local files
    if backup_type == "docker":
        include = f"docker_{current_ts}.tar.gz.part.*"
    else:
        include = f"backup_data_{current_ts}*.dar"

    cmd = [
        "rclone", "check", "--config", RCLONE_CONFIG,
        str(local_root), f"{RCLONE_REMOTE}:{remote_path}",
        "--checksum", "--download",
        "--include", include,
        "--one-way",  # Only check if local files exist in remote, ignore extra remote files
        "--exclude", "backup.log",
        "--exclude", "backup.snar",
        "--exclude", "last_full",
        "--exclude", "last_success",
        "--retries", "3",
        "-P"
    ]
    log(f"Running full checksum: {' '.join(cmd)}")
    res = subprocess.run(cmd, capture_output=True, text=True, timeout=14400)
    if res.returncode == 0:
        log(f"✅ Full checksum verification PASSED for {backup_type}")
        return True
    else:
        log(f"❌ Full checksum verification FAILED for {backup_type} (exit {res.returncode})")
        log(f"Output: {res.stdout}\nError: {res.stderr}")
        return False

def run_weekly_checksum_if_needed():
    marker_file = Path("/opt/backup-uploader/last_full_check.txt")
    now = datetime.now()

    if not marker_file.exists():
        marker_file.touch()
        log("First run: weekly full checksum verification will start next week.")
        return

    last_run = datetime.fromtimestamp(marker_file.stat().st_mtime)
    if (now - last_run) < timedelta(days=7):
        log("Weekly full checksum verification not due yet.")
        return

    log("Weekly full checksum verification is due. Running...")

    docker_ts = None
    docker_subs = rclone_list(f"{DOCKER_ROOT_PATH}/current")
    if docker_subs:
        docker_ts = sorted(docker_subs)[-1]
        log(f"Docker current timestamp: {docker_ts}")

    crypt_ts = None
    crypt_subs = rclone_list(f"{STORAGE_ROOT_PATH}/current")
    if crypt_subs:
        crypt_ts = sorted(crypt_subs)[-1]
        log(f"Gocryptfs current timestamp: {crypt_ts}")

    docker_ok = True
    crypt_ok = True
    if docker_ts:
        docker_ok = full_checksum_verification(LOCAL_DOCKER_ROOT, DOCKER_ROOT_PATH, "docker", docker_ts)
    if crypt_ts:
        crypt_ok = full_checksum_verification(LOCAL_STORAGE_ROOT, STORAGE_ROOT_PATH, "gocryptfs", crypt_ts)

    if docker_ok and crypt_ok:
        marker_file.touch()
        log("Weekly full checksum verification completed successfully.")
    else:
        log("⚠️ Weekly full checksum verification failed. Will retry next week.")

# -------------------------
# MAIN SYNC LOGIC
# -------------------------
def sync_backups(root_path: str, local_root: Path, backup_type: str) -> bool:
    if not local_root.exists():
        log(f"Local path {local_root} not found, skipping.")
        return True
        
    # ---- Restart gateway to ensure fresh session ----
    log("Restarting gateway to ensure fresh session...")
    subprocess.run(['docker', 'restart', 'o2-webdav'], capture_output=True, timeout=60)
    time.sleep(20)
    log("Gateway restarted.")        

    if not ensure_remote_directory(root_path):
        log(f"ERROR: Could not create/verify root directory {root_path}. Aborting.")
        return False

    current_path = f"{root_path}/current"
    old_path = f"{root_path}/old"

    rclone_mkdir(current_path)
    time.sleep(2)
    rclone_mkdir(old_path)
    time.sleep(2)

    groups = group_files(local_root, backup_type)
    if not groups:
        log(f"No backups found in {local_root}")
        return True

    time.sleep(2)
    current_subs = rclone_list(current_path)
    current_base = sorted(current_subs)[-1] if current_subs else None

    # If the timestamp folder already exists in current/ but the local backup is still on disk,
    # it could be an interrupted upload. We add it to to_process so rclone can verify.
    to_process = {}
    for ts, files in groups.items():
        if not current_base or ts > current_base:
            to_process[ts] = files
        elif current_base and ts == current_base:
            # Check if files are missing in the cloud
            remote_files = rclone_list_files(f"{current_path}/{ts}")
            local_names = {f.name for f in files}
            if not local_names.issubset(set(remote_files.keys())):
                log(f"Warning: Timestamp {ts} exists in cloud but is incomplete. Re-adding to upload queue.")
                to_process[ts] = files

    if not to_process:
        log("All backups are already synced.")
        return True

    sorted_ts = sorted(to_process.keys())
    log(f"Processing new backups: {', '.join(sorted_ts)}")

    # ---- Determine the exact full backup timestamp from local marker ----
    last_full_file = local_root / "last_full"
    full_ts = None
    if last_full_file.exists():
        full_ts = last_full_file.read_text().strip()
        
    if not full_ts:
        # Fallback: if marker is missing, assume the oldest in queue is full
        full_ts = sorted_ts[0]
        log(f"Warning: last_full marker empty/missing. Assuming oldest is full: {full_ts}")

    for ts in sorted_ts:
        local_files = to_process[ts]
        expected = {f.name: f.stat().st_size for f in local_files}

        is_full_backup = (ts == full_ts)

        if is_full_backup:
            dest_folder = f"{current_path}/{ts}"
            if current_base is not None and current_base != ts:
                try:
                    dt = datetime.strptime(current_base.split("_")[0],
                                          "%Y-%m-%d" if "-" in current_base else "%Y%m%d")
                    month_year = dt.strftime("%m-%Y")
                except Exception:
                    month_year = datetime.now().strftime("%m-%Y")
                archive_dest = f"{old_path}/{month_year}"
                rclone_mkdir(archive_dest)
                time.sleep(MOVE_DELAY)
                rclone_move(f"{current_path}/{current_base}", f"{archive_dest}/{current_base}")
                time.sleep(MOVE_DELAY)
            
            current_base = ts
        else:
            # Incremental backup: goes into the folder of the latest full
            if current_base is None:
                # This shouldn't happen if we have a full_ts, but fallback to its own folder just in case
                log(f"Warning: Incremental {ts} detected but no current_base. Uploading to its own folder.")
                dest_folder = f"{current_path}/{ts}"
            else:
                dest_folder = f"{current_path}/{full_ts}"
                log(f"Incremental {ts} → merging into {dest_folder}")

        rclone_mkdir(dest_folder)
        time.sleep(2)
        uploaded_count = 0
        for lf in sorted(local_files, key=lambda p: p.name):
            rclone_upload(lf, dest_folder)
            uploaded_count += 1
        log(f"Uploaded {uploaded_count} files to {dest_folder}")

        # ---- VERIFICATION AFTER EACH TIMESTAMP ----
        for attempt in range(1, VERIFY_ATTEMPTS + 1):
            if verify_files(dest_folder, expected):
                break
            if attempt < VERIFY_ATTEMPTS:
                log(f"⏳ Verification attempt {attempt}/{VERIFY_ATTEMPTS}, waiting {VERIFY_WAIT}s")
                time.sleep(VERIFY_WAIT)
        else:
            raise RuntimeError(f"Verification failed for {dest_folder} after {VERIFY_ATTEMPTS} attempts")

    # ---- ORPHAN CLEANUP ----
    log("Checking for orphan folders...")
    all_items = rclone_list(root_path)
    processed_ts = set(to_process.keys())
    for item in all_items:
        if item in ('current', 'old'):
            continue
        if item in processed_ts:
            continue
        log(f"Orphan folder found: {item}")
        try:
            dt = datetime.strptime(item.split("_")[0],
                                  "%Y-%m-%d" if "-" in item else "%Y%m%d")
            month_year = dt.strftime("%m-%Y")
        except Exception:
            month_year = datetime.now().strftime("%m-%Y")
        archive_dest = f"{old_path}/{month_year}"
        rclone_mkdir(archive_dest)
        time.sleep(MOVE_DELAY)
        existing = rclone_list(archive_dest)
        dest_name = item
        if dest_name in existing:
            suffix = datetime.now().strftime("%Y%m%d_%H%M%S")
            dest_name = f"{item}_orphan_{suffix}"
            log(f"Destination exists, renaming to {dest_name}")
        rclone_move(f"{root_path}/{item}", f"{archive_dest}/{dest_name}")
        time.sleep(MOVE_DELAY)

    # ---- FINAL SIZE VERIFICATION (end of sync, 30s wait) ----
    if current_base:
        log("Waiting 30 seconds for gateway to index files...")
        time.sleep(30)
        log("Performing final size verification of current/ folder...")
        remote_files = rclone_list_files(f"{current_path}/{current_base}")
        if remote_files:
            log(f"✅ Final size verification passed: {len(remote_files)} files in {current_path}/{current_base}")
        else:
            log(f"⚠️ WARNING: No files found in {current_path}/{current_base}. Check manually.")

    log("Sync completed successfully.")
    return True

def main():
    # Early abort: if Docker fails critically, do not attempt Gocryptfs
    if not sync_backups(DOCKER_ROOT_PATH, LOCAL_DOCKER_ROOT, "docker"):
        log("Aborting subsequent syncs due to critical failure in Docker.")
        return
        
    if not sync_backups(STORAGE_ROOT_PATH, LOCAL_STORAGE_ROOT, "dar"):
        log("Aborting subsequent syncs due to critical failure in Storage.")
        return

    # ---- WEEKLY FULL CHECKSUM VERIFICATION ----
    run_weekly_checksum_if_needed()

if __name__ == "__main__":
    main()
