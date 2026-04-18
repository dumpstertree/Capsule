#!/usr/bin/env bash
# ludusavi-restore.sh — Restore all Linux game save data using Ludusavi

set -euo pipefail

BACKUP_DIR="${LUDUSAVI_BACKUP_DIR:-$HOME/ludusavi-backups}"
LUDUSAVI="${LUDUSAVI_BIN:-ludusavi}"

if ! command -v "$LUDUSAVI" &>/dev/null; then
  echo "ERROR: ludusavi not found. Run ludusavi-install.sh or set LUDUSAVI_BIN." >&2
  exit 1
fi

if [[ ! -d "$BACKUP_DIR" ]]; then
  echo "ERROR: Backup directory not found: $BACKUP_DIR" >&2
  exit 1
fi

echo "==> Restoring all saves from $BACKUP_DIR"
"$LUDUSAVI" restore --path "$BACKUP_DIR" --force
echo "==> Restore complete."
