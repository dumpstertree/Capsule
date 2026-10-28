#!/bin/bash
# =============================================================================
# Capsule save/metadata sync (runs at stream start).
#
# Bidirectional sync between the local Proton prefix (compatdata/<appid>) and
# the persistent backup location, newest-wins by mtime.
#
# Failure policy: configuration problems abort with an actionable message;
# per-game sync problems only warn, so one bad game never stops the stream.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

###############################################################################
# CONFIG
###############################################################################

USERNAME="$(whoami)"
USER_HOME="$(capsule_user_home "$USERNAME")"

PERSISTENT_DATA_PATH="$(capsule_conf_get PERSISTENT_DATA_PATH)"

if [ -z "$PERSISTENT_DATA_PATH" ]; then
    error "PERSISTENT_DATA_PATH not set in $CAPSULE_CONFIG — re-run open_capsule.sh"
fi

COMPATDATA_DIR="$USER_HOME/.steam/steam/steamapps/compatdata"
METADATA_DIR="$PERSISTENT_DATA_PATH/metadata"
PERSISTENT_BACKUP_DIR="$PERSISTENT_DATA_PATH/backups/$USERNAME"

# Python with stdlib json (venv created by generate-shortcuts.sh, else system)
PYTHON="/opt/capsule-steam-venv/bin/python"
command -v "$PYTHON" >/dev/null 2>&1 || PYTHON="$(command -v python3 || command -v python || true)"
[ -n "$PYTHON" ] || error "No python found for JSON parsing"

###############################################################################
# VALIDATION (skip quietly — fresh capsule is not an error)
###############################################################################

if [ ! -d "$COMPATDATA_DIR" ]; then
    info "No compatdata yet ($COMPATDATA_DIR) — nothing to sync until a game has run once"
    exit 0
fi

if [ ! -d "$METADATA_DIR" ]; then
    info "No metadata yet ($METADATA_DIR) — run generate-shortcuts.sh once games are installed"
    exit 0
fi

if ! mkdir -p "$PERSISTENT_BACKUP_DIR" 2>/dev/null; then
    error "Cannot create backup dir $PERSISTENT_BACKUP_DIR
Fix on the host (UID/GID of $USERNAME: $(id -u "$USERNAME")/$(id -g "$USERNAME")):
    mkdir -p $(dirname "$PERSISTENT_BACKUP_DIR")
    chown $(id -u "$USERNAME"):$(id -g "$USERNAME") $(dirname "$PERSISTENT_BACKUP_DIR")"
fi

###############################################################################
# HELPERS
###############################################################################

get_mtime() {
    local TARGET="$1"
    if [ ! -e "$TARGET" ]; then
        echo "0"
        return
    fi
    find "$TARGET" -type f -printf "%T@\n" 2>/dev/null \
        | sort -n \
        | tail -1 \
        | cut -d '.' -f1
}

sync_bidirectional() {
    local LOCAL_PATH="$1"
    local BACKUP_PATH="$2"
    local GAME_NAME="$3"

    local LOCAL_TIME BACKUP_TIME
    LOCAL_TIME="$(get_mtime "$LOCAL_PATH")"
    BACKUP_TIME="$(get_mtime "$BACKUP_PATH")"

    echo ""
    echo "--------------------------------------------------"
    echo "$GAME_NAME"
    echo "--------------------------------------------------"
    echo "Local Time:   $LOCAL_TIME"
    echo "Backup Time:  $BACKUP_TIME"

    if [ -d "$LOCAL_PATH" ] && [ ! -d "$BACKUP_PATH" ]; then
        echo "Backup missing -> copying local to backup"
        mkdir -p "$BACKUP_PATH" && rsync -a "$LOCAL_PATH/" "$BACKUP_PATH/" || warn "rsync failed for $GAME_NAME"
        return
    fi

    if [ ! -d "$LOCAL_PATH" ] && [ -d "$BACKUP_PATH" ]; then
        echo "Local missing -> restoring from backup"
        mkdir -p "$LOCAL_PATH" && rsync -a "$BACKUP_PATH/" "$LOCAL_PATH/" || warn "rsync failed for $GAME_NAME"
        return
    fi

    if [ ! -d "$LOCAL_PATH" ] && [ ! -d "$BACKUP_PATH" ]; then
        echo "Both missing"
        return
    fi

    LOCAL_TIME="${LOCAL_TIME:-0}"; BACKUP_TIME="${BACKUP_TIME:-0}"

    if [ "$LOCAL_TIME" -gt "$BACKUP_TIME" ] 2>/dev/null; then
        echo "Local newer -> syncing to backup"
        rsync -a --delete "$LOCAL_PATH/" "$BACKUP_PATH/" || warn "rsync failed for $GAME_NAME"
    elif [ "$BACKUP_TIME" -gt "$LOCAL_TIME" ] 2>/dev/null; then
        echo "Backup newer -> restoring to local"
        rsync -a --delete "$BACKUP_PATH/" "$LOCAL_PATH/" || warn "rsync failed for $GAME_NAME"
    else
        echo "Already synced"
    fi
}

read_metadata_field() {
    # read_metadata_field <file> <key>
    "$PYTHON" - "$1" "$2" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.load(f).get(sys.argv[2], ""))
except Exception:
    print("")
PYEOF
}

###############################################################################
# START
###############################################################################

echo ""
echo "=================================================="
echo "Capsule Data Sync"
echo "=================================================="
echo "User:"
echo "  $USERNAME"

failures=0

for METADATA_FILE in "$METADATA_DIR"/*.json; do
    [ -f "$METADATA_FILE" ] || continue

    SHORTCUT_APPID="$(read_metadata_field "$METADATA_FILE" shortcut_appid)"
    GAME_NAME="$(read_metadata_field "$METADATA_FILE" official_name)"
    [ -n "$GAME_NAME" ] || GAME_NAME="Unknown Game"

    if [ -z "$SHORTCUT_APPID" ] || [ "$SHORTCUT_APPID" = "None" ]; then
        continue
    fi

    # appid must be numeric — refuse path traversal from a corrupt metadata file
    case "$SHORTCUT_APPID" in
        ''|*[!0-9]*) warn "Skipping $METADATA_FILE: bad shortcut_appid '$SHORTCUT_APPID'"; continue ;;
    esac

    sync_bidirectional \
        "$COMPATDATA_DIR/$SHORTCUT_APPID" \
        "$PERSISTENT_BACKUP_DIR/$SHORTCUT_APPID" \
        "$GAME_NAME" || failures=$((failures + 1))
done

echo ""
echo "=================================================="
if [ "$failures" -gt 0 ]; then
    echo "Sync Complete with $failures failure(s)"
    exit 1
fi
echo "Sync Complete"
