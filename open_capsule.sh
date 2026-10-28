#!/bin/bash
# =============================================================================
# Capsule setup orchestrator — run once per container as root.
# Validates every input before touching the system, creates the shared config
# at /etc/capsule/config (0640 root:capsule) and all persistent directories.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

capsule_require_root

CONFIG_FILE="$CAPSULE_CONFIG"

###############################################################################
# COLLECT INPUTS
###############################################################################

echo "Open how many Capsules? (1-999)"
read -r USER_COUNT
[[ "$USER_COUNT" =~ ^[1-9][0-9]{0,2}$ ]] || error "Invalid count '$USER_COUNT' — enter a number 1-999"

echo "GPU Index? (informational; rendering uses the render node passed into the LXC)"
read -r GPU_INDEX
[[ "$GPU_INDEX" =~ ^[0-9]{1,2}$ ]] || error "GPU index must be a small number"

echo "Windows Games path? (directory of game folders, e.g. /games)"
read -r GAMES_PATH
capsule_valid_abspath "$GAMES_PATH" || error "Games path must be absolute (no '..')"
[ -d "$GAMES_PATH" ] || warn "Games path $GAMES_PATH does not exist yet — create/mount it before generating shortcuts"

echo "Where to save save backups and game metadata? (e.g. /raid/capsule)"
read -r PERSISTENT_DATA_PATH
capsule_valid_abspath "$PERSISTENT_DATA_PATH" || error "Persistent path must be absolute (no '..')"

echo "Allowed Sunshine web UI origins? (comma separated host/IP of machines you browse FROM, e.g. https://192.168.1.50)"
read -r SUNSHINE_ALLOWED_ORIGINS
SUNSHINE_ALLOWED_ORIGINS="$(capsule_normalize_origins "$SUNSHINE_ALLOWED_ORIGINS")"

echo "SteamGridDB API Key? (empty to skip artwork generation)"
read -r STEAMGRIDDB_API_KEY

###############################################################################
# WRITE CONFIG  (key=value, group-readable by capsule users only)
###############################################################################

capsule_ensure_dir "$CAPSULE_DIR" root 0755
getent group capsule >/dev/null || groupadd capsule

umask 077
cat > "$CONFIG_FILE" <<EOF
# Capsule configuration — generated $(date -Iseconds)
GPU_INDEX=$GPU_INDEX
GAMES_PATH=$GAMES_PATH
PERSISTENT_DATA_PATH=$PERSISTENT_DATA_PATH
SUNSHINE_ALLOWED_ORIGINS=$SUNSHINE_ALLOWED_ORIGINS
STEAMGRIDDB_API_KEY=$STEAMGRIDDB_API_KEY
SUNSHINE_BASE_PORT=47989
SUNSHINE_PORT_STEP=1000
CAPSULE_USER_PREFIX=capsule
EOF
chmod 0640 "$CONFIG_FILE"
chown root:capsule "$CONFIG_FILE"
umask 022

# The API key is a secret: keep the config group-only (capsule group members
# need read access for data-sync). Never chmod 777 the repo for convenience.
chmod 0755 "$SCRIPT_DIR"

###############################################################################
# PERSISTENT DIRECTORIES (this is what bit everyone: create + own them here)
###############################################################################

capsule_ensure_dir "$PERSISTENT_DATA_PATH" root 0755
capsule_ensure_dir "$PERSISTENT_DATA_PATH/metadata" root 0755
capsule_ensure_dir "$PERSISTENT_DATA_PATH/assets" root 0755
capsule_ensure_dir "$PERSISTENT_DATA_PATH/backups" root 0755
chmod o+rX "$PERSISTENT_DATA_PATH/metadata" "$PERSISTENT_DATA_PATH/assets"

###############################################################################
# SYSTEM SETUP
###############################################################################

log "Installing all dependencies"
sh "$SCRIPT_DIR/install_dependencies2.sh"

log "Setting up XOrg on Host"
sh "$SCRIPT_DIR/preconfig-xorg.sh"

log "Creating capsule users"
for i in $(seq 0 $(( USER_COUNT - 1 ))); do
    USER_NAME="$(capsule_user_prefix)$i"

    log "User $USER_NAME ($(( USER_COUNT )) total)"
    sh "$SCRIPT_DIR/create_user.sh" "$USER_NAME" "$i"

    # per-user writable backups dir on the shared store
    capsule_ensure_dir "$PERSISTENT_DATA_PATH/backups/$USER_NAME" "$USER_NAME:$USER_NAME" 0755

    sh "$SCRIPT_DIR/preconfig-sunshine.sh" "$USER_NAME" "$i"
    sh "$SCRIPT_DIR/preconfig-audio.sh" "$USER_NAME"
    sh "$SCRIPT_DIR/preconfig-capsule.sh" "$USER_NAME" "$i"
    sh "$SCRIPT_DIR/preconfig-proton.sh" "$USER_NAME"
done

log "Installing host services (Xorg per capsule)"
sh "$SCRIPT_DIR/preconfig-capsule-host.sh"

log "Installing capsulectl"
install -m 0755 "$SCRIPT_DIR/capsulectl" /usr/local/bin/capsulectl

if [ -n "$STEAMGRIDDB_API_KEY" ]; then
    log "Generating shortcuts"
    sh "$SCRIPT_DIR/generate-shortcuts.sh" || warn "Shortcut generation failed — rerun later: sh $SCRIPT_DIR/generate-shortcuts.sh"
fi

###############################################################################
# SUMMARY
###############################################################################

CONTAINER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo ""
echo "=================================================="
echo " Capsules configured:"
for i in $(seq 0 $(( USER_COUNT - 1 ))); do
    UI_PORT=$(( $(capsule_sunshine_base_port) + i * $(capsule_sunshine_port_step) + 1 ))
    CREDS_FILE="$CAPSULE_DIR/sunshine-creds/$(capsule_user_prefix)$i"
    CREDS="?"
    [ -f "$CREDS_FILE" ] && CREDS="$(cat "$CREDS_FILE")"
    echo "  $(capsule_user_prefix)$i  moonlight: ${CONTAINER_IP:-<ip>}:$(( UI_PORT - 1 ))   sunshine UI: https://${CONTAINER_IP:-<ip>}:$UI_PORT   login: $CREDS"
done
echo "=================================================="
echo "Dashboard (optional):  sh $SCRIPT_DIR/dashboard/install-dashboard.sh"
echo "Reboot now to bring everything up? [y/N]"
read -r REPLY
case "$REPLY" in
    [yY]*) reboot ;;
    *) echo "Reboot later, or: systemctl start capsule-host.service; capsulectl start all" ;;
esac
