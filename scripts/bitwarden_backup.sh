#!/usr/bin/env zsh
set -euo pipefail

BACKUP_DIR="$HOME/bitwarden_backups"
HASH_FILE="$BACKUP_DIR/.last_vault_hash"
mkdir -p "$BACKUP_DIR"
umask 077

log() {
    echo "[$(date '+%F %T')] $*"
}

log "Starting Bitwarden backup script..."

# Prompt for master password
MASTER_PASS=$(
    {
        echo "SETTITLE Bitwarden Backup"
        echo "SETPROMPT Enter your Bitwarden master password"
        echo "SETDESC This password will be used to backup your Bitwarden vault securely"
        echo "GETPIN"
    } | pinentry-gnome3 2>/dev/null | awk '/^D / {print substr($0,3)}'
) || MASTER_PASS=""

if [[ -z "$MASTER_PASS" ]]; then
    log "ERROR: Master password not entered."
    exit 1
fi

if [[ -z "$MASTER_PASS" ]]; then
    log "ERROR: Master password not entered."
    exit 1
fi

# Unlock Bitwarden
BW_SESSION=$(echo "$MASTER_PASS" | bw unlock --raw)
if [[ -z "$BW_SESSION" ]]; then
    log "ERROR: Unlock failed. Wrong password?"
    MASTER_PASS=''
    exit 1
fi

# Sync with server to get latest changes
bw sync --session "$BW_SESSION"

# Export plain JSON for hashing (temporary)
TMP_PLAIN_JSON="$(mktemp)"
bw --session "$BW_SESSION" export --format json --output "$TMP_PLAIN_JSON"

# Compute hash of the plain vault
NEW_HASH=$(sha256sum "$TMP_PLAIN_JSON" | awk '{print $1}')

# Read old hash
if [[ -f "$HASH_FILE" ]]; then
    OLD_HASH=$(<"$HASH_FILE")
else
    OLD_HASH=""
fi

# Compare hashes
if [[ "$NEW_HASH" == "$OLD_HASH" ]]; then
    log "No changes detected in vault. Backup not needed."
    rm -f "$TMP_PLAIN_JSON"
else
    # Export encrypted JSON for KeePassXC
    EXPORT_FILE="$BACKUP_DIR/bitwarden_encrypted_export_$(date +%F-%H%M%S).json"
    bw --session "$BW_SESSION" export --format encrypted_json --password "$MASTER_PASS" --output "$EXPORT_FILE"
    chmod 600 "$EXPORT_FILE"
    log "Vault backup saved securely to $EXPORT_FILE"

    # Update stored hash
    echo "$NEW_HASH" > "$HASH_FILE"
fi

# Cleanup
rm -f "$TMP_PLAIN_JSON"
MASTER_PASS=''
BW_SESSION=''
bw lock
