#!/bin/bash
set -euo pipefail

# -----------------------------
# CONFIGURATION
# -----------------------------
BACKUP_DIR="docker"   # Directorio donde están los backups
RESTORE_DIR="restore"          # Directorio donde restaurar
PASSFILE="docker_pass"          # Passphrase para GPG
SNAR_FILE="$RESTORE_DIR/backup.snar"

# -----------------------------
# PREP
# -----------------------------
mkdir -p "$RESTORE_DIR"

# -----------------------------
# MAIN RESTORE
# -----------------------------
# 1. Encontrar backups en orden cronológico por fecha en el nombre
#    asumiendo formato docker_YYYY-MM-DD_HHMM.tar.gz.part.*
backups=$(ls -1 "$BACKUP_DIR"/docker_*.tar.gz.part.* 2>/dev/null | sort)

# 2. Agrupar partes de cada backup
#    Creamos un array con cada backup completo/incremental (todos sus splits)
declare -A grouped
for f in $backups; do
    # Extraemos solo la parte antes del ".part.xx"
    base=$(basename "$f" | sed -E 's/(\.part\.[a-z]+)$//')
    grouped["$base"]+="$f "
done

# 3. Restaurar cada backup en orden
for base in $(printf "%s\n" "${!grouped[@]}" | sort); do
    parts=${grouped[$base]}
    echo "Restoring backup: $base"

    cat $parts \
    | gpg --batch --yes --passphrase-file "$PASSFILE" -d \
    | tar --listed-incremental="$SNAR_FILE" -xzf - -C "$RESTORE_DIR"
done

echo "All backups restored to $RESTORE_DIR"
