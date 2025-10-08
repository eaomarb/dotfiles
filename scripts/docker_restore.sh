#!/bin/bash
set -euo pipefail

# ----------------------------
# Hardcoded configuration
# ----------------------------
EXPORT_DIR="./backups/docker-tar/nightly-2025-10-06_17-19-35"
RESTORE_DIR="./docker-restore"
RESTIC_PASSWORD_FILE=".restic_pass"

# ----------------------------
# Functions
# ----------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# ----------------------------
# Main
# ----------------------------
log "Restoring backup from $EXPORT_DIR to $RESTORE_DIR..."

mkdir -p "$RESTORE_DIR"

# Decrypt and extract all split parts
cat "$EXPORT_DIR/docker-backup-part-"* \
    | gpg --decrypt --batch --yes --pinentry-mode loopback --passphrase-file "$RESTIC_PASSWORD_FILE" \
    | tar -x -C "$RESTORE_DIR"

log "Restore finished. Files are available at: $RESTORE_DIR"
