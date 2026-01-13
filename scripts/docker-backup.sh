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
MAX_BUNDLE_SIZE=3670016000  # 3.5 GB in bytes
MIN_FREE_SPACE=$((20 * 1024 * 1024 * 1024))    # 20 GB
LOG_FILE="$BACKUP_DIR/backup.log"

# Ensure backup directory exists before logging
mkdir -p "$BACKUP_DIR"

# -----------------------------
# FUNCTIONS
# -----------------------------
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

get_latest_snapshot() {
    ls -1t "$BACKUP_DIR"/*.snar 2>/dev/null | head -1 || echo ""
}

calculate_backup_size() {
    du -sb "$BACKUP_DIR" | awk '{print $1}'
}

perform_backup() {
    local date_stamp snapshot_file backup_type exclude_args

    date_stamp=$(date +'%Y-%m-%d_%H%M')
    snapshot_file="$BACKUP_DIR/backup.snar"
    backup_type="incremental"

    # Build exclude args (relative to DOCKER_DIR)
    exclude_args=()
    for d in "${EXCLUDE_DIRS[@]}"; do
        exclude_args+=(--exclude="$d")
    done

    # Decide full or incremental
    if [[ ! -f "$snapshot_file" ]]; then
        log "No snapshot found. Performing full backup."
        backup_type="full"
        rm -f "$snapshot_file"
    fi

    log "Starting $backup_type backup of $DOCKER_DIR (metadata only, streaming)"

# Streaming backup: tar -> gzip -> gpg -> split
    tar --listed-incremental="$snapshot_file" \
       --create \
       --gzip \
       --atime-preserve=system \
       --ignore-failed-read \
       "${exclude_args[@]}" \
       -C "$DOCKER_DIR" . \
    | gpg --batch --yes --passphrase-file "$PASSFILE" -c \
    | split -b "$MAX_BUNDLE_SIZE" - "$BACKUP_DIR/docker_$date_stamp.tar.gz.part."


    log "$backup_type backup completed: $BACKUP_DIR/docker_$date_stamp.tar.gz.part.*"
}

rotate_full_if_needed() {
    local total_size
    total_size=$(calculate_backup_size)
    if (( total_size > MAX_BUNDLE_SIZE * 5 )); then
        log "Total backup size $total_size exceeds threshold, rotating full backup"
        rm -rf "$BACKUP_DIR"/*
    fi
}

# -----------------------------
# MAIN SCRIPT
# -----------------------------
log "=================== Backup started ==================="
check_disk_space
stop_containers
perform_backup
start_containers
rotate_full_if_needed
log "=================== Backup finished ==================="
