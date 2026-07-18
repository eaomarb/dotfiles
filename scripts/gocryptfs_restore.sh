#!/bin/bash
set -euo pipefail

# ==============================
# CONFIGURATION
# ==============================
BACKUP_DIR="/backups/gocryptfs"        # Where slices are stored
RESTORE_DIR="/restore/gocryptfs"       # Default restore destination
OPTS="-v -O -wa"                       # dar restore options (verbose, overwrite all)

# ==============================
# FUNCTIONS
# ==============================
list_full_backups() {
    local fulls=()
    for f in "$BACKUP_DIR"/backup_data_*.1.dar; do
        [ -f "$f" ] || continue
        base=$(basename "$f" .1.dar)
        # Exclude catalog slices
        if [[ "$base" != *_catalog ]]; then
            # Verify it's a real Full by checking for its isolated catalog
            if [ -f "$BACKUP_DIR/${base}_catalog.1.dar" ]; then
                fulls+=("$base")
            fi
        fi
    done
    printf "%s\n" "${fulls[@]}" | sort
}

get_incrementals_after() {
    local full_base="$1"
    local incs=()
    for f in "$BACKUP_DIR"/backup_data_*.1.dar; do
        [ -f "$f" ] || continue
        base=$(basename "$f" .1.dar)
        [[ "$base" == *_catalog ]] && continue
        if [[ "$base" > "$full_base" ]]; then
            incs+=("$base")
        fi
    done
    if [ ${#incs[@]} -gt 0 ]; then
        printf "%s\n" "${incs[@]}" | sort
    fi
}

restore_to_point() {
    local full_base="$1"
    shift
    local inc_bases=("$@")
    local dest="$RESTORE_DIR"

    mkdir -p "$dest"

    echo "Restoring full: $full_base"
    dar -x "$BACKUP_DIR/$full_base" -R "$dest" $OPTS

    for inc in "${inc_bases[@]}"; do
        echo "Applying incremental: $inc"
        dar -x "$BACKUP_DIR/$inc" -R "$dest" $OPTS
    done

    echo "Restore completed to: $dest"
}

# ==============================
# MAIN
# ==============================
echo "========================================="
echo "Gocryptfs Backup Restore"
echo "========================================="

# List available full backups
mapfile -t fulls < <(list_full_backups)

if [ ${#fulls[@]} -eq 0 ]; then
    echo "ERROR: No full backups found in $BACKUP_DIR"
    exit 1
fi

echo "Available full backups:"
for i in "${!fulls[@]}"; do
    date_str=$(echo "${fulls[$i]}" | sed -E 's/backup_data_([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})/\1-\2-\3 \4:\5:\6/')
    echo "  [$((i+1))] $date_str (${fulls[$i]})"
done

echo ""
read -rp "Select full backup to restore [1-${#fulls[@]}]: " selection

if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt "${#fulls[@]}" ]; then
    echo "ERROR: Invalid selection"
    exit 1
fi

selected_full="${fulls[$((selection-1))]}"
echo "Selected full: $selected_full"

# Find incrementals after this full
mapfile -t incs < <(get_incrementals_after "$selected_full")

# Restore mode selection
echo ""
echo "Restore options:"
echo "  [0] Restore ONLY the full backup (no incrementals)"
if [ ${#incs[@]} -gt 0 ]; then
    echo "  [1-${#incs[@]}] Restore full + incrementals up to that point"
    echo ""
    echo "Available incrementals after this full:"
    for i in "${!incs[@]}"; do
        date_str=$(echo "${incs[$i]}" | sed -E 's/backup_data_([0-9]{4})([0-9]{2})([0-9]{2})_([0-9]{2})([0-9]{2})([0-9]{2})/\1-\2-\3 \4:\5:\6/')
        echo "    [$((i+1))] $date_str (${incs[$i]})"
    done
else
    echo "  (No incrementals found after this full)"
fi

echo ""
read -rp "Select option [0-${#incs[@]}] (default 0): " inc_selection
inc_selection="${inc_selection:-0}"

if ! [[ "$inc_selection" =~ ^[0-9]+$ ]] || [ "$inc_selection" -lt 0 ] || [ "$inc_selection" -gt "${#incs[@]}" ]; then
    echo "ERROR: Invalid selection"
    exit 1
fi

if [ "$inc_selection" -eq 0 ]; then
    selected_incs=()
else
    selected_incs=("${incs[@]:0:$inc_selection}")
fi

# Ask for destination
read -rp "Restore destination [$RESTORE_DIR]: " input_dest
RESTORE_DIR="${input_dest:-$RESTORE_DIR}"

# Confirm
echo ""
echo "Full backup: $selected_full"
if [ ${#selected_incs[@]} -gt 0 ]; then
    echo "Incrementals to apply: ${selected_incs[*]}"
else
    echo "No incrementals (full only)"
fi
echo "Destination: $RESTORE_DIR"
read -rp "Proceed? (Y/n): " confirm
if [[ "$confirm" =~ ^[Nn]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Restore
restore_to_point "$selected_full" "${selected_incs[@]}"

echo "Done. Restored to $RESTORE_DIR"