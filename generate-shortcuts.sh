#!/bin/bash
# =============================================================================
# Generate Steam shortcuts + artwork for all capsule users.
# Reads GAMES_PATH / PERSISTENT_DATA_PATH / STEAMGRIDDB_API_KEY from
# /etc/capsule/config. Run as root.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

capsule_require_root

VENV_DIR="/opt/capsule-steam-venv"
PYTHON_SCRIPT="$SCRIPT_DIR/generate-shortcuts.py"

GAMES_PATH="$(capsule_conf_require GAMES_PATH)"
PERSISTENT_DATA_PATH="$(capsule_conf_require PERSISTENT_DATA_PATH)"
STEAMGRIDDB_API_KEY="$(capsule_conf_get STEAMGRIDDB_API_KEY "")"

if [ -z "$STEAMGRIDDB_API_KEY" ]; then
    error "STEAMGRIDDB_API_KEY is empty in $CAPSULE_CONFIG — shortcut/artwork generation needs it"
fi

log "Installing python dependencies"
pacman -Sy --noconfirm --needed python python-pip python-virtualenv git >/dev/null

if [ ! -d "$VENV_DIR" ]; then
    log "Creating virtual environment"
    python -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/pip" install -q --upgrade pip vdf requests rapidfuzz pillow

# Stop ONLY capsule users' steam instances (never other users' processes).
log "Stopping Steam for capsule users"
for HOME_DIR in /home/capsule*/; do
    [ -d "$HOME_DIR" ] || continue
    USERNAME="$(basename "$HOME_DIR")"
    id "$USERNAME" >/dev/null 2>&1 || continue
    pkill -u "$USERNAME" steam || true
    pkill -u "$USERNAME" steamwebhelper || true
done
sleep 3

log "Running generator"
"$VENV_DIR/bin/python" "$PYTHON_SCRIPT" \
    "$GAMES_PATH" \
    "$PERSISTENT_DATA_PATH" \
    "$STEAMGRIDDB_API_KEY"

echo ""
echo "Generation Done"
