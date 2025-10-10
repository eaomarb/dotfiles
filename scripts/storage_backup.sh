#!/bin/bash
set -euo pipefail

# ----------------------------
# Config
# ----------------------------
SRC="/data/storage"                                # Cryptomator vault
EXPORT_CMR="/backups/storage-exports"              # CMR disk (tar-split)
SNAPSHOT_SMR="/data/backups/storage-snapshots"     # SMR snapshots
MONTHLY_EXPORT_CMR="$EXPORT_CMR/monthly"            # SMR monthly export stored on CMR
LATEST_RAW_SMR="/data/backups/latest-raw"          # NEW: raw copy on SMR for change detection
SPLIT_SIZE="3500M"
KEEP_SNAPSHOTS=12
DATE=$(date +'%Y-%m-%d_%H-%M-%S')
IONICE_CLASS=2
IONICE_NICE=7
LOG_FILE="/var/log/storage-backup.log"

export TMPDIR="$EXPORT_CMR/tmp"
mkdir -p "$TMPDIR"

mkdir -p "$(dirname "$LOG_FILE")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# ----------------------------
# Helpers
# ----------------------------
ensure_dirs() {
    mkdir -p "$EXPORT_CMR" "$SNAPSHOT_SMR" "$MONTHLY_EXPORT_CMR" "$LATEST_RAW_SMR"
}

prune_snapshots() {
    local keep=$1
    mapfile -t dirs < <(ls -1d "$SNAPSHOT_SMR"/snapshot-* 2>/dev/null | sort)
    local count=${#dirs[@]}
    (( count <= keep )) && return
    local to_remove=$((count - keep))
    for ((i=0; i<to_remove; i++)); do
        log "Pruning old snapshot: ${dirs[i]}"
        rm -rf "${dirs[i]}"
    done
}

verify_export() {
    local export_dir="$1"
    log "Verifying export integrity: $export_dir"
    if cat "$export_dir"/storage-backup-part-*.tar.gpg | tar -tf - >/dev/null 2>&1; then
        log "Verification OK for $export_dir"
        return 0
    else
        log "Verification FAILED for $export_dir"
        return 1
    fi
}

check_changes() {
    local PREV="$1"
    local SRC="$2"
    [ -z "$PREV" ] && return 1
    local CHANGES
    CHANGES=$(rsync -rcn --delete --out-format="%n" "$SRC"/ "$PREV"/)
    [ -z "$CHANGES" ] && return 1 || return 0
}

# ----------------------------
# Start backup
# ----------------------------
log "===== Storage backup started ====="
ensure_dirs

# ----------------------------
# 1. CMR: backup only if changes since last raw snapshot (on SMR)
# ----------------------------
CHANGED=1
avail=$(df --output=avail -B1 "$EXPORT_CMR" | tail -n1)
src_size=$(du -sb "$SRC" 2>/dev/null | awk '{print $1}')
if (( avail < src_size )); then
    log "Not enough free space on CMR (avail: $(numfmt --to=iec $avail), src: $(numfmt --to=iec $src_size)). Skipping CMR backup."
    CHANGED=0
fi

if [ -d "$LATEST_RAW_SMR" ] && [ "$(ls -A "$LATEST_RAW_SMR")" ]; then
    log "Checking for changes since last SMR raw snapshot..."
    if ! check_changes "$LATEST_RAW_SMR" "$SRC"; then
        log "No changes detected. Skipping CMR backup."
        CHANGED=0
    else
        log "Changes detected. Proceeding with CMR backup."
    fi
fi

if [ "$CHANGED" -eq 1 ]; then
    # Remove old tar-split backup (only keep latest)
    PREV_BACKUP=$(ls -1d "$EXPORT_CMR"/snapshot-* 2>/dev/null | sort | tail -n1 || true)
    [ -n "$PREV_BACKUP" ] && log "Removing old CMR backup: $PREV_BACKUP" && rm -rf "$PREV_BACKUP"

    EXPORT_DIR="$EXPORT_CMR/snapshot-$DATE"
    mkdir -p "$EXPORT_DIR"
    log "Backing up vault to CMR: $EXPORT_DIR"
    ionice -c"$IONICE_CLASS" -n"$IONICE_NICE" tar -C "$(dirname "$SRC")" -cpf - "$(basename "$SRC")" \
        | split -b "$SPLIT_SIZE" - "$EXPORT_DIR/storage-backup-part-" --additional-suffix=".tar.gpg"
    verify_export "$EXPORT_DIR"

    # Update latest-raw snapshot on SMR
    log "Updating SMR latest-raw snapshot for future change detection..."
    rsync -aH --delete --numeric-ids "$SRC"/ "$LATEST_RAW_SMR"/
fi

# ----------------------------
# 2. SMR: monthly incremental snapshot & export
# ----------------------------
DAY_OF_MONTH=$(date +%d)
if [[ "$DAY_OF_MONTH" == "01" ]]; then
    PREV=""
    [ -d "$SNAPSHOT_SMR/latest" ] && PREV="$SNAPSHOT_SMR/latest"

    # Run snapshot if first-ever (no PREV) or changes exist
    if [ -z "$PREV" ] || check_changes "$PREV" "$SRC"; then
        SNAPSHOT_DIR="$SNAPSHOT_SMR/snapshot-$DATE"
        if [ -n "$PREV" ]; then
            log "Creating incremental snapshot from $PREV"
            ionice -c"$IONICE_CLASS" -n"$IONICE_NICE" rsync -aH --delete --numeric-ids --link-dest="$PREV" "$SRC"/ "$SNAPSHOT_DIR"/
        else
            log "Creating initial snapshot"
            ionice -c"$IONICE_CLASS" -n"$IONICE_NICE" rsync -aH --delete --numeric-ids "$SRC"/ "$SNAPSHOT_DIR"/
        fi
        ln -sfn "$SNAPSHOT_DIR" "$SNAPSHOT_SMR/latest"

        # Export snapshot to CMR for redundancy
        MONTHLY_DIR="$MONTHLY_EXPORT_CMR/snapshot-$DATE"
        mkdir -p "$MONTHLY_DIR"
        log "Exporting SMR snapshot to CMR split parts: $MONTHLY_DIR"
        tar -C "$SNAPSHOT_SMR" -cf - "$(basename "$SNAPSHOT_DIR")" \
            | split -b "$SPLIT_SIZE" - "$MONTHLY_DIR/storage-backup-part-" --additional-suffix=".tar.gpg"
        verify_export "$MONTHLY_DIR"

        # Prune old snapshots
        log "Pruning old SMR snapshots (keep $KEEP_SNAPSHOTS)"
        prune_snapshots "$KEEP_SNAPSHOTS"
    else
        log "No changes detected. Skipping SMR snapshot for this month."
    fi
fi

log "===== Storage backup finished ====="
exit 0
