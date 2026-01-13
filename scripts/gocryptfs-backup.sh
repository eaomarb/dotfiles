#!/usr/bin/env bash
set -euo pipefail

# ================= CONFIG =================
SOURCE_DIR="/data/gocryptfs"           # Your encrypted folder
STAGING_DIR="/backups/gocryptfs"
LOG_FILE="/var/log/dar_backup.log"
TIMESTAMP_FILE="$STAGING_DIR/last_success"

BASENAME="backup_data"
SLICE_SIZE="3500M"                     # 3.5GB bundles
MIN_FREE_GB=20                         # Minimum required space
RETENTION_DAYS=7
# =========================================

log() { echo "[$(date '+%F %T')] $1" >> "$LOG_FILE"; }

check_space() {
    local available_gb=$(df --output=avail -BG "$STAGING_DIR" | tail -n1 | tr -d 'G' | xargs)
    echo "$available_gb"
}

# 1. CHANGE PRE-CHECK: If there are no changes, exit early (Zero HDD stress)
if [ -f "$TIMESTAMP_FILE" ]; then
    if [ -z "$(find "$SOURCE_DIR" -type f -newer "$TIMESTAMP_FILE" -print -quit)" ]; then
        exit 0
    fi
    log "INFO: Changes detected. Starting process."
else
    log "INFO: First backup. Starting FULL backup."
fi

mkdir -p "$STAGING_DIR"

# 2. CHECK SPACE BEFORE
FREE_BEFORE=$(check_space)
if [ "$FREE_BEFORE" -lt "$MIN_FREE_GB" ]; then
    log "ERROR: Not enough space to start. Free: ${FREE_BEFORE}GB, Required: ${MIN_FREE_GB}GB"
    exit 1
fi

# 3. IDENTIFY INCREMENTAL REFERENCE
LAST_REF=$(ls -t "$STAGING_DIR"/${BASENAME}_*.dar 2>/dev/null | head -n 1 | sed 's/\.[0-9]\+\.dar$//' || true)
CURRENT_NAME="${BASENAME}_$(date +%Y%m%d_%H%M%S)"

# 4. DAR EXECUTION
if [ -z "$LAST_REF" ]; then
    log "Running FULL backup..."
    dar -c "$STAGING_DIR/$CURRENT_NAME" -R "$SOURCE_DIR" -s "$SLICE_SIZE" -at -Q
else
    log "Running INCREMENTAL backup based on $LAST_REF..."
    dar -c "$STAGING_DIR/$CURRENT_NAME" -R "$SOURCE_DIR" -A "$LAST_REF" -s "$SLICE_SIZE" -at -Q
fi

# 5. FINAL VERIFICATION AND CLEANUP
if [ $? -eq 0 ]; then
    touch "$TIMESTAMP_FILE"
    log "SUCCESS: Backup completed successfully."

    # Cleanup old local files before final space check
    find "$STAGING_DIR" -name "${BASENAME}_*.dar" -mtime +$RETENTION_DAYS -delete

    # CHECK SPACE AFTER
    FREE_AFTER=$(check_space)
    if [ "$FREE_AFTER" -lt "$MIN_FREE_GB" ]; then
        log "WARNING: Backup completed but free space (${FREE_AFTER}GB) is below the minimum."
    fi

else
    log "ERROR: The DAR process failed."
    exit 1
fi
