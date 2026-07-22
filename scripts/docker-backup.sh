#!/bin/bash
set -euo pipefail

# ==============================
# CONFIGURATION
# ==============================
DOCKER_DIR="/docker"
BACKUP_DIR="/backups/docker"
PASSFILE="/root/.docker_pass"
CONTAINERS_TO_STOP=("telegraf" "prometheus" "qbittorrent" "grafana")
EXCLUDE_DIRS=("node_modules" "cache" ".cache" "tmp" "logs")
MAX_BUNDLE_SIZE=3670016000          # 3.5 GB in bytes
MIN_FREE_SPACE_MARGIN=$((15 * 1024 * 1024 * 1024))   # 15 GB
MAX_BACKUP_SIZE=$((3 * 1024 * 1024 * 1024))         # 3 GB rotation threshold for incrementals
LOG_FILE="$BACKUP_DIR/backup.log"
LOCK_FILE="/var/lock/docker-backup.lock"
LAST_FULL_FILE="$BACKUP_DIR/last_full"
LAST_SUCCESS="$BACKUP_DIR/last_success"

mkdir -p "$BACKUP_DIR"
mkdir -p "$(dirname "$LOG_FILE")"
mkdir -p /var/lock

# ==============================
# LOGGING
# ==============================
log() {
    echo "$(date +'%F %T') - $*" | tee -a "$LOG_FILE"
}

rotate_log() {
    if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt 2000 ]; then
        tail -n 2000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

# ==============================
# CHECKS
# ==============================
check_binaries() {
    log "Checking required binaries..."
    for b in docker tar gpg split du find; do
        if ! command -v "$b" &>/dev/null; then
            log "ERROR: $b not found"
            exit 1
        fi
    done
    log "All binaries present."
}

check_dirs() {
    log "Checking directories..."
    [ -d "$DOCKER_DIR" ] || { log "ERROR: $DOCKER_DIR missing"; exit 1; }
    [ -d "$BACKUP_DIR" ] || { log "ERROR: $BACKUP_DIR missing"; exit 1; }
    log "Directories OK."
}

check_passfile() {
    log "Checking passfile..."
    [ -r "$PASSFILE" ] || { log "ERROR: Passfile not readable"; exit 1; }
    log "Passfile OK."
}

# ==============================
# CALCULATE SOURCE SIZE (excluding patterns)
# ==============================
get_source_size() {
    local exclude_args=()
    for d in "${EXCLUDE_DIRS[@]}"; do
        exclude_args+=(--exclude="$d")
    done
    du -sb "${exclude_args[@]}" "$DOCKER_DIR" 2>/dev/null | awk '{print $1}'
}

# ==============================
# CALCULATE SIZE OF CHANGED FILES SINCE LAST SUCCESS
# ==============================
get_changes_size() {
    if [ ! -f "$LAST_SUCCESS" ]; then
        echo "0"
        return
    fi
    local exclude_args=()
    for d in "${EXCLUDE_DIRS[@]}"; do
        exclude_args+=(-path "*/$d" -prune -o)
    done
    find "$DOCKER_DIR" "${exclude_args[@]}" -type f -newer "$LAST_SUCCESS" -print0 2>/dev/null |
        du -sb --files0-from=- 2>/dev/null | awk '{sum+=$1} END {print sum+0}'
}

# ==============================
# DYNAMIC SPACE CHECK
# ==============================
check_space_for_backup() {
    local backup_type="$1"
    local estimated_size=0
    local source_size=$(get_source_size)
    if [ -z "$source_size" ] || [ "$source_size" -eq 0 ]; then
        log "ERROR: Source size is 0 or empty. Possible mount failure or I/O error. Aborting to prevent data loss."
        exit 1
    fi

    if [ "$backup_type" = "full" ]; then
        estimated_size=$source_size
        log "Full backup: estimated size = $estimated_size bytes ($((estimated_size/1024/1024/1024)) GB)"
    else
        estimated_size=$(get_changes_size)
        log "Incremental backup: estimated changes = $estimated_size bytes ($((estimated_size/1024/1024/1024)) GB)"
        if [ "$estimated_size" -eq 0 ]; then
            log "WARNING: No changes detected, but backup_type is incremental. Continuing anyway."
        fi
    fi

    local required=$((estimated_size + MIN_FREE_SPACE_MARGIN))
    local avail=$(df --output=avail --block-size=1 "$BACKUP_DIR" | tail -1 | awk '{print $1}')
    avail=${avail:-0}

    log "Free space in $BACKUP_DIR: $avail bytes ($((avail/1024/1024/1024)) GB), required: $required bytes ($((required/1024/1024/1024)) GB)"

    if (( avail >= required )); then
        log "Sufficient free space, proceeding."
        return 0
    fi

    local backup_files=("$BACKUP_DIR"/docker_*.tar.gz.part.*)
    local freed=0
    if [ -e "${backup_files[0]}" ]; then
        freed=$(du -sb "${backup_files[@]}" 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
        freed=${freed:-0}
    fi
    log "Current backups occupy: $freed bytes ($((freed/1024/1024/1024)) GB)"

    if (( avail + freed >= required )); then
        log "Freeing all old backups would provide enough space. Deleting all backups and forcing a full backup."
        rm -f "$BACKUP_DIR"/docker_*.tar.gz.part.*
        rm -f "$BACKUP_DIR"/backup.snar
        rm -f "$BACKUP_DIR"/last_success
        rm -f "$BACKUP_DIR"/last_full
        log "Old backups removed."
        return 0
    else
        log "ERROR: Even after deleting all old backups, space would be $((avail+freed)) bytes, but need $required bytes."
        log "Aborting to prevent data loss."
        exit 1
    fi
}

# ==============================
# CLEANUP ORPHANS
# ==============================
cleanup_orphans() {
    if [ ! -f "$LAST_SUCCESS" ]; then
        log "No last_success marker found. Cleaning ALL backup files (orphans from failed runs)."
        rm -f "$BACKUP_DIR"/docker_*.tar.gz.part.*
        rm -f "$BACKUP_DIR"/backup.snar
        rm -f "$BACKUP_DIR"/last_full
        return 0
    fi

    local orphans=$(find "$BACKUP_DIR" -maxdepth 1 -name "docker_*.tar.gz.part.*" -type f -newer "$LAST_SUCCESS" 2>/dev/null)
    if [ -n "$orphans" ]; then
        log "Found orphan .part.* files newer than last_success. Cleaning them."
        echo "$orphans" | xargs rm -f
        rm -f "$BACKUP_DIR"/backup.snar
        log "Orphans cleaned."
    else
        log "No orphan .part.* files found."
    fi
    return 0
}

# ==============================
# ROTATION
# ==============================
rotate_by_size() {
    if [ ! -f "$LAST_FULL_FILE" ]; then
        log "No last_full marker found. Skipping rotation."
        return 0
    fi

    local find_cmd="find \"$BACKUP_DIR\" -maxdepth 1 -name 'docker_*.tar.gz.part.*' -type f -newer \"$LAST_FULL_FILE\""
    log "Rotation check: executing $find_cmd"

    local file_list=$(eval "$find_cmd" 2>/dev/null)
    local total=0
    if [ -n "$file_list" ]; then
        total=$(echo "$file_list" | xargs du -sb 2>/dev/null | awk '{sum+=$1} END {print sum}')
        total=${total:-0}
    fi

    log "Total size of incremental part files: $total bytes ($((total/1024/1024/1024)) GB)"

    local SAFETY_LIMIT=$((50 * 1024 * 1024 * 1024))   # 50 GB
    if (( total > SAFETY_LIMIT )); then
        log "ERROR: Incremental total ($((total/1024/1024/1024)) GB) exceeds safety limit (50 GB). Aborting to prevent data loss."
        exit 1
    fi

    if (( total >= MAX_BACKUP_SIZE )); then
        log "Incrementals total ($((total/1024/1024/1024)) GB) >= 10GB → cleaning all"
        rm -f "$BACKUP_DIR"/docker_*.tar.gz.part.*
        rm -f "$BACKUP_DIR"/backup.snar
        rm -f "$BACKUP_DIR"/last_success
        rm -f "$BACKUP_DIR"/last_full
        log "Cleanup done. Next run will force a full backup."
    else
        log "Incrementals total ($((total/1024/1024/1024)) GB) below 10GB, no rotation needed."
    fi
}

# ==============================
# CONTAINER MANAGEMENT
# ==============================
declare -A WAS_RUNNING

stop_containers() {
    for c in "${CONTAINERS_TO_STOP[@]}"; do
        local container_id
        container_id=$(docker ps -a -q --filter "name=^${c}$")
        if [ -n "$container_id" ]; then
            if docker ps -q --filter "name=^${c}$" | grep -q .; then
                WAS_RUNNING["$c"]=1
                log "Stopping $c"
                docker stop "$c" || { log "ERROR: Failed to stop $c, trying kill"; docker kill "$c" || { log "CRITICAL: Cannot stop $c"; exit 1; }; }
            else
                WAS_RUNNING["$c"]=0
            fi
        fi
    done
}

start_containers() {
    for c in "${CONTAINERS_TO_STOP[@]}"; do
        log "Ensuring $c is running..."
        docker start "$c" || log "WARNING: Failed to start $c"
    done
    return 0
}

# ==============================
# BACKUP EXECUTION
# ==============================
perform_backup() {
    local stamp=$(date +'%Y-%m-%d_%H%M%S')
    local snap="$BACKUP_DIR/backup.snar"
    local flag="$BACKUP_DIR/last_success"
    local backup_type="incremental"

    local exclude=()
    for d in "${EXCLUDE_DIRS[@]}"; do exclude+=(--exclude="$d"); done

    if [[ -f "$snap" && -f "$flag" && "$flag" -nt "$snap" ]]; then
        log "Incremental backup"
        backup_type="incremental"
    else
        log "Full backup (no valid snapshot)"
        backup_type="full"
        # Clean old files before full
        rm -f "$BACKUP_DIR"/docker_*.tar.gz.part.*
        rm -f "$BACKUP_DIR"/backup.snar
        rm -f "$BACKUP_DIR"/last_success
        rm -f "$BACKUP_DIR"/last_full
        rm -f "$snap"
    fi

    # Dynamic space check
    check_space_for_backup "$backup_type"

    # Re-evaluate type after space check (if old backups were removed)
    if [ ! -f "$snap" ] || [ ! -f "$flag" ]; then
        backup_type="full"
        log "Forcing full backup because previous backups were removed."
    fi

    set +e
    # --blocking-factor=1024 improves I/O performance on mechanical disks
    # by reducing the number of write operations.
    tar --blocking-factor=1024 --ignore-failed-read --warning=no-file-changed \
        --listed-incremental="$snap" --create --gzip --atime-preserve=system \
        "${exclude[@]}" -C "$DOCKER_DIR" . \
    | gpg --batch --yes --passphrase-file "$PASSFILE" -c \
    | split -b "$MAX_BUNDLE_SIZE" - "$BACKUP_DIR/docker_$stamp.tar.gz.part."
    local pipe_status=("${PIPESTATUS[@]}")
    set -e
    
    local tar_status=${pipe_status[0]}
    local gpg_status=${pipe_status[1]}
    local split_status=${pipe_status[2]}

    # If split or gpg fail, abort ALWAYS
    if [ "$gpg_status" -ne 0 ] || [ "$split_status" -ne 0 ]; then
        log "ERROR: Pipeline failed (gpg: $gpg_status, split: $split_status)."
        exit 1
    fi
    
    # tar returns 1 if files changed (warning). Any other tar exit code is an error.
    if [ "$tar_status" -ne 0 ] && [ "$tar_status" -ne 1 ]; then
        log "ERROR: tar failed with status $tar_status."
        exit 1
    elif [ "$tar_status" -eq 1 ]; then
        log "WARNING: tar reported file changed during backup (exit code 1). Backup is considered successful."
    fi

    touch "$flag" && log "Updated success flag: $flag"
    if [ "$backup_type" = "full" ]; then
        # Store the timestamp in the marker file for reliable full/incremental detection by the sync script
        echo "$stamp" > "$LAST_FULL_FILE" && log "Updated full backup marker: $LAST_FULL_FILE"
    fi
    log "Backup completed"
}

# ==============================
# CLEANUP ON EXIT
# ==============================
cleanup() {
    local exit_code=$?
    start_containers || true
    log "Exiting with code $exit_code" || true
}

# ==============================
# MAIN
# ==============================
main() {
    exec 2>>"$LOG_FILE"

    exec 200>"$LOCK_FILE"
    flock -n 200 || { log "ERROR: Already running"; exit 1; }

    trap cleanup EXIT

    log "=================== START ==================="
    rotate_log
    check_binaries
    check_dirs
    check_passfile

    cleanup_orphans
    rotate_by_size

    stop_containers
    perform_backup

    log "=================== FINISH ==================="
}

main "$@"
