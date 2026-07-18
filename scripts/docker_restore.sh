#!/bin/bash
set -euo pipefail

# ==============================
# CONFIGURATION
# ==============================
BACKUP_DIR="/backups/docker"          # Where backups are stored
RESTORE_DIR="/restore/docker"         # Default restore destination
PASSFILE="/root/.docker_pass"         # GPG passphrase file

# ==============================
# FUNCTIONS
# ==============================
list_backups() {
    local backups=()
    for f in "$BACKUP_DIR"/docker_*.tar.gz.part.*; do
        [ -f "$f" ] || continue
        base=$(basename "$f" | sed -E 's/\.part\.[a-z]+$//')
        backups+=("$base")
    done
    printf "%s\n" "${backups[@]}" | sort -u
}

get_backup_date() {
    echo "$1" | sed -E 's/docker_([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6})/\1/'
}

restore_single_backup() {
    local base="$1"
    local dest="$2"
    local sn="$dest/backup.snar"
    mkdir -p "$dest"

    echo "Restoring ONLY $base (incremental, no base applied)"

    # Build list of parts
    local parts=()
    for part in "$BACKUP_DIR"/"${base}".part.*; do
        [ -f "$part" ] || { echo "ERROR: Missing part $part"; exit 1; }
        parts+=("$part")
    done

    cat "${parts[@]}" \
    | gpg --batch --yes --passphrase-file "$PASSFILE" -d \
    | tar --listed-incremental="$sn" -xzf - -C "$dest"
}

restore_full_chain() {
    local selected_base="$1"
    local dest="$2"
    local sn="$dest/backup.snar"

    # Get all backups sorted by date
    mapfile -t all_backups < <(list_backups)
    if [ ${#all_backups[@]} -eq 0 ]; then
        echo "ERROR: No backups found"
        exit 1
    fi

    # Find the oldest full backup (first in list)
    local full_base="${all_backups[0]}"
    echo "Full base: $full_base"

    # Find all backups from full_base up to selected_base (inclusive)
    local to_restore=()
    local found=0
    for b in "${all_backups[@]}"; do
        to_restore+=("$b")
        if [ "$b" == "$selected_base" ]; then
            found=1
            break
        fi
    done

    if [ $found -eq 0 ]; then
        echo "ERROR: Selected backup not found in chain"
        exit 1
    fi

    echo "Backups to apply:"
    printf "  %s\n" "${to_restore[@]}"

    # Restore full first (no snapshot file yet)
    echo "Restoring full: $full_base"
    local parts=()
    for part in "$BACKUP_DIR"/"${full_base}".part.*; do
        [ -f "$part" ] || { echo "ERROR: Missing part $part"; exit 1; }
        parts+=("$part")
    done

    # Full restore: no snapshot file (tar creates it)
    cat "${parts[@]}" \
    | gpg --batch --yes --passphrase-file "$PASSFILE" -d \
    | tar -xzf - -C "$dest"

    # Apply incrementals (if any) in order
    local inc_count=0
    for ((i=1; i<${#to_restore[@]}; i++)); do
        local inc="${to_restore[$i]}"
        echo "Applying incremental: $inc"
        local inc_parts=()
        for part in "$BACKUP_DIR"/"${inc}".part.*; do
            [ -f "$part" ] || { echo "ERROR: Missing part $part"; exit 1; }
            inc_parts+=("$part")
        done
        cat "${inc_parts[@]}" \
        | gpg --batch --yes --passphrase-file "$PASSFILE" -d \
        | tar --listed-incremental="$sn" -xzf - -C "$dest"
        inc_count=$((inc_count + 1))
    done

    echo "Restored full + $inc_count incrementals to: $dest"
}

# ==============================
# MAIN
# ==============================
echo "========================================="
echo "Docker Backup Restore"
echo "========================================="

# List available backups
mapfile -t available < <(list_backups)

if [ ${#available[@]} -eq 0 ]; then
    echo "ERROR: No backups found in $BACKUP_DIR"
    exit 1
fi

echo "Available backups:"
for i in "${!available[@]}"; do
    date_str=$(get_backup_date "${available[$i]}")
    echo "  [$((i+1))] $date_str (${available[$i]})"
done

echo ""
read -rp "Select backup to restore [1-${#available[@]}]: " selection

if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "${#available[@]}" ]; then
    echo "ERROR: Invalid selection"
    exit 1
fi

selected="${available[$((selection-1))]}"
echo "Selected: $selected"

# Ask for restore mode
echo ""
echo "Restore modes:"
echo "  [1] Full state up to selected backup (default) - applies full + all previous incrementals"
echo "  [2] Only this backup (incremental) - assumes base state already exists"
read -rp "Select mode [1/2] (default 1): " mode
mode="${mode:-1}"

# Ask for destination
read -rp "Restore destination [$RESTORE_DIR]: " input_dest
RESTORE_DIR="${input_dest:-$RESTORE_DIR}"

# Confirm
echo ""
echo "Backup: $selected"
echo "Mode: $([ "$mode" -eq 1 ] && echo "Full chain" || echo "Single backup")"
echo "Destination: $RESTORE_DIR"
read -rp "Proceed? (Y/n): " confirm
if [[ "$confirm" =~ ^[Nn]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Execute restore
if [ "$mode" -eq 1 ]; then
    restore_full_chain "$selected" "$RESTORE_DIR"
else
    restore_single_backup "$selected" "$RESTORE_DIR"
fi

echo "Done."