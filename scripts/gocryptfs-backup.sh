#!/usr/bin/env bash
set -euo pipefail

# ================= CONFIG =================
SOURCE_DIR="/data/gocryptfs"           # Your encrypted folder
STAGING_DIR="/backups/gocryptfs"
LOG_FILE="/var/log/dar_backup.log"
TIMESTAMP_FILE="$STAGING_DIR/last_success"
FILELIST_PREV="$STAGING_DIR/filelist_prev"

BASENAME="backup_data"
SLICE_SIZE="3500M"                     # 3.5GB bundles
MIN_FREE_GB=20                         # Minimum required space
# =========================================

log() { echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"; }

check_space() {
    local available_gb=$(df --output=avail -BG "$STAGING_DIR" | tail -n1 | tr -d 'G' | xargs)
    echo "$available_gb"
}

# 1. Generate current file list (relative paths, sorted)
mkdir -p "$STAGING_DIR"
current_list=$(mktemp)
trap 'rm -f "$current_list"' EXIT

cd "$SOURCE_DIR" || { log "ERROR: Cannot access $SOURCE_DIR"; exit 1; }
find . -type f -print0 | sort -z > "$current_list"

# 2. Decide if backup is needed by comparing with previous list
if [ -f "$FILELIST_PREV" ]; then
    if ! diff -q "$FILELIST_PREV" "$current_list" >/dev/null 2>&1; then
        log "INFO: File list changed (additions, deletions, or modifications). Starting backup."
    else
        log "INFO: No changes detected. Exiting."
        exit 0
    fi
else
    log "INFO: First backup (no previous file list). Starting FULL backup."
fi

# 3. CHECK SPACE BEFORE
FREE_BEFORE=$(check_space)
if [ "$FREE_BEFORE" -lt "$MIN_FREE_GB" ]; then
    log "ERROR: Not enough space to start. Free: ${FREE_BEFORE}GB, Required: ${MIN_FREE_GB}GB"
    exit 1
fi

# 4. IDENTIFY INCREMENTAL REFERENCE (with integrity check)
LAST_REF=$(find "$STAGING_DIR" -maxdepth 1 -name "${BASENAME}_*.dar" -type f -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2- | sed 's/\.[0-9]\+\.dar$//' || true)

if [ -n "$LAST_REF" ]; then
    if ! dar -t "$LAST_REF" -q 2>/dev/null; then
        log "WARNING: Last backup $LAST_REF is corrupted or incomplete. Forcing FULL backup."
        LAST_REF=""
    fi
fi

CURRENT_NAME="${BASENAME}_$(date +%Y%m%d_%H%M%S)"

# 5. DAR EXECUTION
if [ -z "$LAST_REF" ]; then
    log "Running FULL backup..."
    if ! dar -c "$STAGING_DIR/$CURRENT_NAME" -R "$SOURCE_DIR" -s "$SLICE_SIZE" -at -Q; then
        log "ERROR: DAR full backup command failed"
        exit 1
    fi
else
    log "Running INCREMENTAL backup based on $LAST_REF..."
    if ! dar -c "$STAGING_DIR/$CURRENT_NAME" -R "$SOURCE_DIR" -A "$LAST_REF" -s "$SLICE_SIZE" -at -Q; then
        log "ERROR: DAR incremental backup command failed"
        exit 1
    fi
fi

# 6. FINALIZE: update timestamp and file list
touch "$TIMESTAMP_FILE"
cp "$current_list" "$FILELIST_PREV"
log "SUCCESS: Backup completed successfully."

# 7. CHECK SPACE AFTER
FREE_AFTER=$(check_space)
if [ "$FREE_AFTER" -lt "$MIN_FREE_GB" ]; then
    log "WARNING: Backup completed but free space (${FREE_AFTER}GB) is below the minimum."
fi
