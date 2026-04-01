#!/bin/bash
set -euo pipefail

# -----------------------------
# CONFIGURATION
# -----------------------------
DOCKER_DIR="/docker"
BACKUP_DIR="/backups/docker"
PASSFILE="/root/.docker_pass"
CONTAINERS_TO_STOP=("telegraf" "prometheus" "qbittorrent")
EXCLUDE_DIRS=("node_modules" "cache" ".cache" "tmp" "logs")
MAX_BUNDLE_SIZE=3670016000        # 3.5 GB in bytes
MIN_FREE_SPACE=$((20 * 1024 * 1024 * 1024))   # 20 GB
MAX_BACKUP_SIZE=$((10 * 1024 * 1024 * 1024))  # 10 GB threshold
LOG_FILE="$BACKUP_DIR/backup.log"

mkdir -p "$BACKUP_DIR"

log() {
    echo "$(date +'%F %T') - $*" | tee -a "$LOG_FILE"
}

check_disk_space() {
    local avail
    avail=$(df --output=avail "$BACKUP_DIR" | tail -1)
    avail=$((avail * 1024))
    if (( avail < MIN_FREE_SPACE )); then
        log "ERROR: Not enough free space. Required: $MIN_FREE_SPACE, Available: $avail"
        exit 1
    fi
}

rotate_by_size() {
    # Sum sizes of all backup parts using find's -printf (avoids xargs pitfalls)
    local total_size
    total_size=$(find "$BACKUP_DIR" -maxdepth 1 -name "docker_*.tar.gz.part.*" -type f -printf '%s\n' 2>/dev/null | awk '{sum+=$1} END {print sum+0}')

    if (( total_size >= MAX_BACKUP_SIZE )); then
        log "Total backup size ($((total_size/1024/1024/1024)) GB) exceeds threshold ($((MAX_BACKUP_SIZE/1024/1024/1024)) GB). Cleaning up to force a fresh full."
        rm -f "$BACKUP_DIR"/docker_*.tar.gz.part.*
        rm -f "$BACKUP_DIR"/backup.snar
        rm -f "$BACKUP_DIR"/last_success
        log "Backup directory cleaned."
    fi
}

stop_containers() {
    for c in "${CONTAINERS_TO_STOP[@]}"; do
        if docker ps -q -f name="$c" &>/dev/null; then
            log "Stopping container $c"
            docker stop "$c"
        fi
    done
}

start_containers() {
    for c in "${CONTAINERS_TO_STOP[@]}"; do
        if docker ps -a -q -f name="$c" &>/dev/null; then
            log "Starting container $c"
            docker start "$c"
        fi
    done
}

perform_backup() {
    local date_stamp snapshot_file backup_type exclude_args
    local success_flag="$BACKUP_DIR/last_success"

    date_stamp=$(date +'%Y-%m-%d_%H%M')
    snapshot_file="$BACKUP_DIR/backup.snar"
    backup_type="incremental"

    # Build exclude args (relative to DOCKER_DIR)
    exclude_args=()
    for d in "${EXCLUDE_DIRS[@]}"; do
        exclude_args+=(--exclude="$d")
    done

    # Decide full or incremental based on snapshot validity
    if [[ -f "$snapshot_file" && -f "$success_flag" && "$success_flag" -nt "$snapshot_file" ]]; then
        log "Using existing snapshot for incremental backup."
    else
        log "No valid snapshot found (or last backup failed). Performing full backup."
        backup_type="full"
        rm -f "$snapshot_file"
    fi

    log "Starting $backup_type backup of $DOCKER_DIR"

    # Streaming backup: tar -> gzip -> gpg -> split
    tar --listed-incremental="$snapshot_file" \
        --create \
        --gzip \
        --atime-preserve=system \
        "${exclude_args[@]}" \
        -C "$DOCKER_DIR" . \
    | gpg --batch --yes --passphrase-file "$PASSFILE" -c \
    | split -b "$MAX_BUNDLE_SIZE" - "$BACKUP_DIR/docker_$date_stamp.tar.gz.part."

    # If we reach here, all commands succeeded
    touch "$success_flag"

    log "$backup_type backup completed: $BACKUP_DIR/docker_$date_stamp.tar.gz.part.*"
}

# -----------------------------
# MAIN SCRIPT
# -----------------------------
log "=================== Backup started ==================="
check_disk_space
rotate_by_size
stop_containers
perform_backup
start_containers
log "=================== Backup finished ==================="
