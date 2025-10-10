#!/bin/bash
set -euo pipefail

# ----------------------------
# Configuration
# ----------------------------
SRC="/docker"
RESTIC_PASSWORD_FILE="/root/.restic_pass"
LOG_FILE="/var/log/docker-backup.log"
DATE=$(date +'%Y-%m-%d_%H-%M-%S')
SPLIT_SIZE="3500M"

# Repositories
NIGHTLY_REPO="/backups/docker"
BIOWEEKLY_REPO="/data/backups/docker"

# Export directories
EXPORT_BASE="/backups/docker-tar"

# Retention
KEEP_NIGHTLY=2
KEEP_BIOWEEKLY=1
KEEP_MONTHLY=3

export TMPDIR=/backups/tmp
mkdir -p "$TMPDIR"

# ----------------------------
# Functions
# ----------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

stopped_containers=()

stop_all_containers() {
    stopped_containers=($(docker ps -q))
    if [ ${#stopped_containers[@]} -eq 0 ]; then
        log "No running containers."
        return
    fi
    log "Stopping ${#stopped_containers[@]} running containers..."
    docker stop "${stopped_containers[@]}"
}

start_stopped_containers() {
    if [ ${#stopped_containers[@]} -eq 0 ]; then
        log "No containers were stopped."
        return
    fi
    log "Restarting previously stopped containers..."
    docker start "${stopped_containers[@]}"
}

backup_repo() {
    local repo="$1"
    local tag="$2"
    log "Backing up $SRC to $repo (tag: $tag)..."
    mkdir -p "$repo"
    if [ ! -f "$repo/config" ]; then
        restic -r "$repo" --password-file "$RESTIC_PASSWORD_FILE" init
    fi
    restic -r "$repo" --password-file "$RESTIC_PASSWORD_FILE" backup "$SRC" --tag "$tag"
}

prune_repo() {
    local repo="$1"
    local tag="$2"
    local keep="$3"
    log "Pruning snapshots in $repo (tag: $tag, keep last $keep)..."
    restic -r "$repo" --password-file "$RESTIC_PASSWORD_FILE" forget --tag "$tag" --keep-last "$keep" --prune
}

export_split_tar() {
    local repo="$1"
    local tag="$2"
    local export_dir="$EXPORT_BASE/${tag}-${DATE}"
    mkdir -p "$export_dir"
    log "Exporting $SRC to encrypted split tar files at $export_dir..."

    # Create encrypted tar and split
    tar -C "$(dirname "$SRC")" -cf - "$(basename "$SRC")" \
        | gpg --symmetric --cipher-algo AES256 --batch --yes --pinentry-mode loopback --passphrase-file "$RESTIC_PASSWORD_FILE" \
        | split -b "$SPLIT_SIZE" - "$export_dir/docker-backup-part-" --additional-suffix=".tar.gpg"

    log "Encrypted split tar export finished: $export_dir"
}

prune_exports() {
    local tag="$1"
    local keep="$2"
    local dirs
    dirs=($(ls -1d "$EXPORT_BASE/${tag}-"* 2>/dev/null | sort))
    local count=${#dirs[@]}
    if (( count <= keep )); then return; fi
    for ((i=0; i<count-keep; i++)); do
        log "Pruning old export: ${dirs[i]}"
        rm -rf "${dirs[i]}"
    done
}

verify_export() {
    local export_dir="$1"

    log "Verifying export integrity for $export_dir..."

    # Decrypt all split parts and check tar integrity directly from the stream
    if gpg --decrypt --batch --yes --pinentry-mode loopback --passphrase-file "$RESTIC_PASSWORD_FILE" \
        "$export_dir/docker-backup-part-"* | tar -tf - >/dev/null; then
        log "Export integrity check passed for $export_dir"
    else
        log "Export integrity check FAILED for $export_dir"
        exit 1
    fi
}

# ----------------------------
# Main
# ----------------------------
log "===== Docker backup started ====="
stop_all_containers

# Nightly backup (always)
backup_repo "$NIGHTLY_REPO" "nightly"
prune_repo "$NIGHTLY_REPO" "nightly" $KEEP_NIGHTLY
export_split_tar "$NIGHTLY_REPO" "nightly"
verify_export "$EXPORT_BASE/nightly-${DATE}"
prune_exports "nightly" $KEEP_NIGHTLY

# Determine biweekly and monthly
DAY_OF_YEAR=$(date +%j)           # 001..365
DAY_OF_MONTH=$(date +%d)

# Biweekly backup: every 14 days
if (( DAY_OF_YEAR % 14 == 1 )); then
    backup_repo "$BIOWEEKLY_REPO" "biweekly"
    prune_repo "$BIOWEEKLY_REPO" "biweekly" $KEEP_BIOWEEKLY
    export_split_tar "$BIOWEEKLY_REPO" "biweekly"
    verify_export "$EXPORT_BASE/biweekly-${DATE}"
    prune_exports "biweekly" $KEEP_BIOWEEKLY
fi

# Monthly backup: 1st of month
if (( DAY_OF_MONTH == 1 )); then
    backup_repo "$BIOWEEKLY_REPO" "monthly"
    prune_repo "$BIOWEEKLY_REPO" "monthly" $KEEP_MONTHLY
    export_split_tar "$BIOWEEKLY_REPO" "monthly"
    verify_export "$EXPORT_BASE/monthly-${DATE}"
    prune_exports "monthly" $KEEP_MONTHLY
fi

start_stopped_containers
log "===== Docker backup finished ====="
