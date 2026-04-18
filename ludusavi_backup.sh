#!/usr/bin/env bash
# ludusavi-backup.sh — Back up all Linux game save data using Ludusavi

set -euo pipefail

BACKUP_DIR="${LUDUSAVI_BACKUP_DIR:-$HOME/ludusavi-backups}"
LUDUSAVI="${LUDUSAVI_BIN:-ludusavi}"

if ! command -v "$LUDUSAVI" &>/dev/null; then
  echo "ERROR: ludusavi not found. Run ludusavi-install.sh or set LUDUSAVI_BIN." >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"

echo "==> Starting backup → $BACKUP_DIR"
"$LUDUSAVI" backup --path "$BACKUP_DIR"
echo "==> Backup complete."
