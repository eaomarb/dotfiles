#!/usr/bin/env bash
set -euo pipefail

# ==============================
# CONFIGURATION
# ==============================
SOURCE_DIR="/data/gocryptfs"
STAGING_DIR="/data2/backups/gocryptfs"
LOG_FILE="/var/log/dar_backup.log"
LOCK_FILE="/var/lock/gocryptfs-backup.lock"

BASENAME="backup_data"
SLICE_SIZE="3500M"
TIMESTAMP_FILE="$STAGING_DIR/last_success"
LAST_FULL_FILE="$STAGING_DIR/last_full"
LAST_SUCCESS="$STAGING_DIR/last_success"

ROTATION_THRESHOLD_GB=15
MIN_FREE_SPACE_MARGIN=$((50 * 1024 * 1024 * 1024))   # 50 GB

VALID_REF=""
SOURCE_SIZE_BYTES=0

# ==============================
# LOGGING
# ==============================
log() {
    echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"
}

rotate_log() {
    if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt 2000 ]; then
        tail -n 2000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

trap 'log "ERROR at line $LINENO (exit code $?)"' ERR

# ==============================
# CHECKS
# ==============================
check_binaries() {
    log "Checking required binaries..."
    for b in dar df du find; do
        if ! command -v "$b" &>/dev/null; then
            log "ERROR: $b not found"
            exit 1
        fi
    done
    log "All binaries present."
}

check_dirs() {
    log "Checking directories..."
    [ -d "$SOURCE_DIR" ] || { log "ERROR: $SOURCE_DIR missing"; exit 1; }
    [ "$(df --output=target "$SOURCE_DIR" | tail -1)" != "/" ] || { log "ERROR: $SOURCE_DIR not mounted"; exit 1; }
    mkdir -p "$STAGING_DIR" || { log "ERROR: Cannot create $STAGING_DIR"; exit 1; }
    [ "$(df --output=target "$STAGING_DIR" | tail -1)" != "/" ] || { log "ERROR: $STAGING_DIR not mounted"; exit 1; }
    mkdir -p "$(dirname "$LOG_FILE")" || { log "ERROR: Cannot create log directory"; exit 1; }
    mkdir -p /var/lock || { log "ERROR: Cannot create /var/lock"; exit 1; }
    log "Directories OK."
}

# ==============================
# SIZE HELPERS
# ==============================
source_size_bytes() {
    if [ "$SOURCE_SIZE_BYTES" -eq 0 ]; then
        local size
        size=$(du -sb "$SOURCE_DIR" 2>/dev/null | awk '{print $1}' | tr -d '\n\r')
        if [ -z "$size" ] || [ "$size" -eq 0 ]; then
            log "ERROR: Source size is 0 or empty. Possible mount failure or I/O error. Aborting to prevent data loss."
            exit 1
        fi
        SOURCE_SIZE_BYTES="$size"
        log "Source size: $SOURCE_SIZE_BYTES bytes ($((SOURCE_SIZE_BYTES/1024/1024/1024)) GB)"
    fi
    echo "$SOURCE_SIZE_BYTES"
}

free_bytes() {
    local free
    free=$(df --output=avail --block-size=1 "$STAGING_DIR" 2>/dev/null | tail -1 | awk '{print $1+0}' | tr -d '\n\r')
    if [ -z "$free" ]; then
        log "WARNING: Failed to determine free space. Will use 0."
        free=0
    fi
    echo "$free"
}

# ==============================
# CALCULATE SIZE OF CHANGED FILES SINCE LAST SUCCESS
# ==============================
get_changes_size() {
    if [ ! -f "$LAST_SUCCESS" ]; then
        echo "0"
        return
    fi
    find "$SOURCE_DIR" -type f -newer "$LAST_SUCCESS" -print0 2>/dev/null |
        du -sb --files0-from=- 2>/dev/null | awk '{sum+=$1} END {print sum+0}'
}

# ==============================
# DYNAMIC SPACE CHECK (only data slices, exclude catalogs)
# ==============================
check_space_for_backup() {
    local backup_type="$1"
    local estimated_size=0
    local source_size=$(source_size_bytes)
    source_size=${source_size:-0}

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
    local avail=$(free_bytes)
    avail=${avail:-0}

    log "Free space in $STAGING_DIR: $avail bytes ($((avail/1024/1024/1024)) GB), required: $required bytes ($((required/1024/1024/1024)) GB)"

    if (( avail >= required )); then
        log "Sufficient free space, proceeding."
        return 0
    fi

    # Calculate size of data slices only (exclude catalog slices)
    local slice_files
    slice_files=$(find "$STAGING_DIR" -maxdepth 1 -type f -name "${BASENAME}_*.[0-9]*.dar" ! -name "*_catalog.*.dar" -print0 2>/dev/null | xargs -0 du -sb 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
    slice_files=${slice_files:-0}
    log "Current data slices occupy: $slice_files bytes ($((slice_files/1024/1024/1024)) GB)"

    if (( avail + slice_files >= required )); then
        log "Freeing all old data slices would provide enough space. Deleting all backups (slices + catalogs) and forcing a full backup."
        rm -f "$STAGING_DIR"/${BASENAME}_*.dar
        rm -f "$TIMESTAMP_FILE"
        rm -f "$LAST_FULL_FILE"
        log "Old backups removed."
        return 0
    else
        log "ERROR: Even after deleting all backups, space would be $((avail+slice_files)) bytes, but need $required bytes."
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
        rm -f "$STAGING_DIR"/${BASENAME}_*.dar
        rm -f "$LAST_FULL_FILE"
    else
        log "last_success exists, removing orphan data slices newer than last_success (excluding catalogs)."
        find "$STAGING_DIR" -maxdepth 1 -type f -name "${BASENAME}_*.[0-9]*.dar" ! -name "*_catalog.*.dar" -newer "$LAST_SUCCESS" -delete 2>/dev/null || true
    fi
    return 0
}

# ==============================
# ROTATION (only data slices, exclude catalogs)
# ==============================
rotate_by_space() {
    if [ ! -f "$LAST_FULL_FILE" ]; then
        log "No last_full marker found. Skipping rotation."
        return 0
    fi

    local find_cmd="find \"$STAGING_DIR\" -maxdepth 1 -type f -name '${BASENAME}_*.[0-9]*.dar' ! -name '*_catalog.*.dar' -newer \"$LAST_FULL_FILE\""
    log "Rotation check: executing $find_cmd"

    local file_list=$(eval "$find_cmd" 2>/dev/null)
    local total=0
    if [ -n "$file_list" ]; then
        total=$(echo "$file_list" | xargs du -sb 2>/dev/null | awk '{sum+=$1} END {print sum+0}' | head -n1 | tr -d '\n\r')
        total=${total:-0}
    fi

    log "Total size of incremental data slices: $total bytes ($((total/1024/1024/1024)) GB)"

    local SAFETY_LIMIT=$((200 * 1024 * 1024 * 1024))
    if (( total > SAFETY_LIMIT )); then
        log "ERROR: Incremental total ($((total/1024/1024/1024)) GB) exceeds safety limit (100 GB). Aborting."
        exit 1
    fi

    local total_gb=$(( total / 1024 / 1024 / 1024 ))
    if (( total_gb >= ROTATION_THRESHOLD_GB )); then
        log "Incrementals total ${total_gb}GB >= ${ROTATION_THRESHOLD_GB}GB → cleaning all"
        rm -f "$STAGING_DIR"/${BASENAME}_*.dar
        rm -f "$TIMESTAMP_FILE"
        rm -f "$LAST_FULL_FILE"
        log "Cleanup done. Next run will force a full backup."
    else
        log "Incrementals total ${total_gb}GB below ${ROTATION_THRESHOLD_GB}GB, no rotation needed."
    fi
    return 0
}

# ==============================
# FIND ISOLATED CATALOG
# ==============================
find_catalog_base() {
    local catalog
    catalog=$(find "$STAGING_DIR" -maxdepth 1 -type f -name "*_catalog.*.dar" -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)
    if [ -n "$catalog" ]; then
        # Remove the .<number>.dar suffix to get the base name
        echo "${catalog%.*.*}"
    else
        echo ""
    fi
}

# ==============================
# CHANGE DETECTION
# ==============================
changes_detected() {
    cd "$STAGING_DIR" || { log "ERROR: Cannot cd to $STAGING_DIR"; exit 1; }
    log "Checking for changes..."

    local ref
    ref=$(find_catalog_base)
    if [ -n "$ref" ]; then
        VALID_REF="$ref"
        log "Found catalog reference: $ref"
    else
        VALID_REF=""
        log "No previous catalog found"
    fi

    if [ ! -f "$LAST_SUCCESS" ]; then
        log "No last_success marker, forcing full backup"
        return 0
    fi

    # Use find -newer to detect changes based on metadata only.
    # This is efficient because it does not read file contents, only timestamps.
    if find "$SOURCE_DIR" -type f -newer "$LAST_SUCCESS" -print -quit 2>/dev/null | grep -q .; then
        log "Changes detected (new or modified files)"
        return 0
    else
        log "No changes detected"
        return 1
    fi
}

# ==============================
# INTEGRITY CHECK ON SUNDAY
# ==============================
check_integrity_on_sunday() {
    if [ "$(date +%u)" -eq 7 ]; then
        cd "$STAGING_DIR" || { log "ERROR: Cannot cd to $STAGING_DIR"; exit 1; }
        log "Sunday: Running integrity check on the latest backup (read-only)"
        local ref
        ref=$(find_catalog_base)
        if [ -n "$ref" ]; then
            if dar -Q -t "$ref" -q 2>/dev/null; then
                log "Integrity check passed for $ref"
            else
                log "WARNING: Integrity check FAILED for $ref. Backup may be corrupted."
            fi
        else
            log "No backup found to check integrity."
        fi
    fi
}

# ==============================
# PROGRESS MONITOR (only data slices)
# ==============================
monitor_progress() {
    local pid=$1
    local total_bytes=$2
    if [ "$total_bytes" -eq 0 ]; then
        log "Warning: Source size is zero, trying to estimate from existing data slices..."
        local slice_files
        slice_files=$(find "$STAGING_DIR" -maxdepth 1 -type f -name "${BASENAME}_*.[0-9]*.dar" ! -name "*_catalog.*.dar" -print0 2>/dev/null | xargs -0 du -sb 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
        slice_files=${slice_files:-0}
        if [ "$slice_files" -gt 0 ]; then
            log "Estimated source size from existing data slices: $slice_files bytes"
            total_bytes=$slice_files
        fi
        if [ "$total_bytes" -eq 0 ]; then
            log "Warning: Cannot estimate source size, progress monitoring disabled."
            return 0
        fi
    fi

    while kill -0 "$pid" 2>/dev/null; do
        sleep 300
        local slice_files
        slice_files=$(find "$STAGING_DIR" -maxdepth 1 -type f -name "${BASENAME}_*.[0-9]*.dar" ! -name "*_catalog.*.dar" -print0 2>/dev/null | xargs -0 du -sb 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
        slice_files=${slice_files:-0}
        local percent=$(awk "BEGIN {printf \"%.2f\", ($slice_files / $total_bytes) * 100}")
        log "Backup progress: ${percent}% (${slice_files} bytes of ${total_bytes})"
    done
}

# ==============================
# ISOLATE CATALOG AFTER FULL BACKUP
# ==============================
isolate_catalog() {
    local name="$1"
    local ref_name="${name}_catalog"
    log "Isolating catalog from $name to $ref_name"

    # -Q: non-interactive mode (required for cron)
    # -s 0: no slicing (single file)
    # -at: copy catalogue only (no data)
    dar -Q -C "$STAGING_DIR/$ref_name" -A "$STAGING_DIR/$name" -s 0 -at 2>>"$LOG_FILE"

    if [ $? -eq 0 ]; then
        log "Catalog isolated successfully: $ref_name"
        # Verify that the catalog file exists (safety check)
        if [ -f "$STAGING_DIR/${ref_name}.1.dar" ]; then
            log "Catalog file verified: $STAGING_DIR/${ref_name}.1.dar"
        else
            log "ERROR: Catalog file $STAGING_DIR/${ref_name}.1.dar not found after isolation"
            exit 1
        fi
    else
        log "ERROR: Failed to isolate catalog"
        exit 1
    fi
}

# ==============================
# BACKUP EXECUTION
# ==============================
perform_backup() {
    cd "$STAGING_DIR" || { log "ERROR: Cannot cd to $STAGING_DIR"; exit 1; }
    log "Performing backup..."

    local ref="${VALID_REF:-}"
    local stamp=$(date +%Y%m%d_%H%M%S)
    local name="${BASENAME}_${stamp}"
    local backup_type="full"

    if [ -n "$ref" ] && [ -f "$LAST_SUCCESS" ] && [ -f "$LAST_FULL_FILE" ]; then
        backup_type="incremental"
        log "Incremental backup (ref: $ref)"
    else
        backup_type="full"
        log "Full backup — cleaning all previous backups"
        rm -f "$STAGING_DIR"/${BASENAME}_*.dar
        rm -f "$TIMESTAMP_FILE"
        rm -f "$LAST_FULL_FILE"
        ref=""
    fi

    check_space_for_backup "$backup_type"

    if [ ! -f "$LAST_FULL_FILE" ] || [ ! -f "$LAST_SUCCESS" ]; then
        backup_type="full"
        ref=""
        log "Backup type changed to full because previous backups were removed"
    fi

    local cmd
    if [ -z "$ref" ]; then
        # -Q: non-interactive mode (required for cron)
        # No compression (-z) because data is already encrypted (gocryptfs),
        # so compression would waste CPU without reducing size.
        cmd="dar -Q -c \"$STAGING_DIR/$name\" -R \"$SOURCE_DIR\" -s \"$SLICE_SIZE\""
    else
        cmd="dar -Q -c \"$STAGING_DIR/$name\" -R \"$SOURCE_DIR\" -A \"$ref\" -s \"$SLICE_SIZE\""
    fi

    source_size_bytes > /dev/null 2>&1
    local total_size=$SOURCE_SIZE_BYTES

    log "Starting backup: $name ($backup_type)"
    eval "$cmd" 2>>"$LOG_FILE" &
    local dar_pid=$!

    monitor_progress "$dar_pid" "$total_size" &
    local monitor_pid=$!

    wait "$dar_pid"
    local exit_code=$?
    
    # Kill the monitor if dar is already finished (avoids the 5 min flock block)
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true

    if [ $exit_code -ne 0 ]; then
        log "ERROR: dar failed with exit code $exit_code"
        exit 1
    fi

    touch "$TIMESTAMP_FILE" && log "Updated success flag: $TIMESTAMP_FILE"
    if [ "$backup_type" = "full" ]; then
        # Store the timestamp in the marker file for reliable full/incremental detection by the sync script
        echo "$stamp" > "$LAST_FULL_FILE" && log "Updated full backup marker: $LAST_FULL_FILE"
        isolate_catalog "$name"
    fi
    log "SUCCESS: $name"
}

# ==============================
# CLEANUP ON EXIT
# ==============================
cleanup() {
    local exit_code=$?
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

    cleanup_orphans
    rotate_by_space

    check_integrity_on_sunday

    if changes_detected; then
        log "All checks passed, proceeding to backup"
        perform_backup
    else
        log "No changes, exiting"
    fi

    log "=================== FINISH ==================="
}

main "$@"
