#!/bin/bash
set -e

###############################################################################
# CONFIG
###############################################################################

CONFIG_FILE="/capsule-host.config"

###############################################################################
# VALIDATION
###############################################################################

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Missing config:"
    echo "  $CONFIG_FILE"
    exit 1
fi

###############################################################################
# READ CONFIG
###############################################################################

GPU_INDEX="$(sed -n '1p' "$CONFIG_FILE" | xargs)"
GAMES_PATH="$(sed -n '2p' "$CONFIG_FILE" | xargs)"
PERSISTENT_DATA_PATH="$(sed -n '3p' "$CONFIG_FILE" | xargs)"
WHITELISTED_SUNSHINE_IPS="$(sed -n '4p' "$CONFIG_FILE" | xargs)"
STEAMGRIDDB_API_KEY="$(sed -n '5p' "$CONFIG_FILE" | xargs)"

###############################################################################
# PATHS
###############################################################################

USERNAME="$(whoami)"

COMPATDATA_DIR="$HOME/.steam/steam/steamapps/compatdata"

METADATA_DIR="$PERSISTENT_DATA_PATH/metadata"

PERSISTENT_BACKUP_DIR="$PERSISTENT_DATA_PATH/backups/$USERNAME"

###############################################################################
# VALIDATION
###############################################################################

if [[ ! -d "$COMPATDATA_DIR" ]]; then
    echo "Missing compatdata:"
    echo "  $COMPATDATA_DIR"
    exit 0
fi

if [[ ! -d "$METADATA_DIR" ]]; then
    echo "Missing metadata:"
    echo "  $METADATA_DIR"
    exit 0
fi

mkdir -p "$PERSISTENT_BACKUP_DIR"

###############################################################################
# HELPERS
###############################################################################

get_mtime() {

    local TARGET="$1"

    if [[ ! -e "$TARGET" ]]; then
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

    local LOCAL_TIME
    local BACKUP_TIME

    LOCAL_TIME="$(get_mtime "$LOCAL_PATH")"
    BACKUP_TIME="$(get_mtime "$BACKUP_PATH")"

    echo ""
    echo "--------------------------------------------------"
    echo "$GAME_NAME"
    echo "--------------------------------------------------"

    echo "Local Time:   $LOCAL_TIME"
    echo "Backup Time:  $BACKUP_TIME"

    ###########################################################################
    # ONLY LOCAL EXISTS
    ###########################################################################

    if [[ -d "$LOCAL_PATH" && ! -d "$BACKUP_PATH" ]]; then

        echo "Backup missing -> copying local to backup"

        mkdir -p "$BACKUP_PATH"

        rsync -a \
            "$LOCAL_PATH/" \
            "$BACKUP_PATH/"

        return
    fi

    ###########################################################################
    # ONLY BACKUP EXISTS
    ###########################################################################

    if [[ ! -d "$LOCAL_PATH" && -d "$BACKUP_PATH" ]]; then

        echo "Local missing -> restoring from backup"

        mkdir -p "$LOCAL_PATH"

        rsync -a \
            "$BACKUP_PATH/" \
            "$LOCAL_PATH/"

        return
    fi

    ###########################################################################
    # BOTH MISSING
    ###########################################################################

    if [[ ! -d "$LOCAL_PATH" && ! -d "$BACKUP_PATH" ]]; then

        echo "Both missing"

        return
    fi

    ###########################################################################
    # LOCAL NEWER
    ###########################################################################

    if (( LOCAL_TIME > BACKUP_TIME )); then

        echo "Local newer -> syncing to backup"

        rsync -a \
            --delete \
            "$LOCAL_PATH/" \
            "$BACKUP_PATH/"

        return
    fi

    ###########################################################################
    # BACKUP NEWER
    ###########################################################################

    if (( BACKUP_TIME > LOCAL_TIME )); then

        echo "Backup newer -> restoring to local"

        rsync -a \
            --delete \
            "$BACKUP_PATH/" \
            "$LOCAL_PATH/"

        return
    fi

    ###########################################################################
    # SAME
    ###########################################################################

    echo "Already synced"
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

###############################################################################
# PROCESS GAMES
###############################################################################

for METADATA_FILE in "$METADATA_DIR"/*.json; do

    if [[ ! -f "$METADATA_FILE" ]]; then
        continue
    fi

    SHORTCUT_APPID="$(python -c "
import json
with open('$METADATA_FILE') as f:
    data=json.load(f)
print(data.get('shortcut_appid', ''))
")"

    GAME_NAME="$(python -c "
import json
with open('$METADATA_FILE') as f:
    data=json.load(f)
print(data.get('official_name', 'Unknown Game'))
")"

    if [[ -z "$SHORTCUT_APPID" ]]; then
        continue
    fi

    LOCAL_PATH="$COMPATDATA_DIR/$SHORTCUT_APPID"

    BACKUP_PATH="$PERSISTENT_BACKUP_DIR/$SHORTCUT_APPID"

    sync_bidirectional \
        "$LOCAL_PATH" \
        "$BACKUP_PATH" \
        "$GAME_NAME"

done

###############################################################################
# DONE
###############################################################################

echo ""
echo "=================================================="
echo "Sync Complete"
echo "=================================================="
