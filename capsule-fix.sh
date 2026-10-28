#!/bin/bash
# =============================================================================
# capsule-fix.sh — repair/migrate an EXISTING Capsule install in one shot.
# Run as root inside the capsule container, from the repo:
#
#     cd /Capsule && git pull && ./capsule-fix.sh
#
# Applies (idempotently):
#   1. /capsule-host.config (old positional format) -> /etc/capsule/config
#   2. world-writable /Capsule (777) -> 755; config readable via 'capsule' group
#   3. sunshine.conf: valid csrf_allowed_origins, origin_web_ui_allowed, drop
#      the bogus ds5 key
#   4. persistent dirs (metadata/assets/backups/<user>) created + owned
#   5. compatdata skeleton per user (kills the "Missing compatdata" abort)
#   6. new capsule@.service template; removes the old copied capsule.service
#   7. capsulectl installed to /usr/local/bin
#
# Options:
#   --reset-sunshine-creds   replace capsule/capsule logins with strong ones
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

capsule_require_root

RESET_CREDS=0
[ "${1:-}" = "--reset-sunshine-creds" ] && RESET_CREDS=1

OLD_CONFIG="/capsule-host.config"

###############################################################################
# 1. config migration
###############################################################################

capsule_ensure_dir "$CAPSULE_DIR" root 0755
getent group capsule >/dev/null || groupadd capsule

if [ ! -f "$CAPSULE_CONFIG" ] && [ -f "$OLD_CONFIG" ]; then
    log "Migrating $OLD_CONFIG -> $CAPSULE_CONFIG"
    GPU_INDEX="$(sed -n '1p' "$OLD_CONFIG" | xargs)"
    GAMES_PATH="$(sed -n '2p' "$OLD_CONFIG" | xargs)"
    PERSISTENT_DATA_PATH="$(sed -n '3p' "$OLD_CONFIG" | xargs)"
    WHITELIST="$(sed -n '4p' "$OLD_CONFIG" | xargs)"
    API_KEY="$(sed -n '5p' "$OLD_CONFIG" | xargs)"
    ORIGINS="$(capsule_normalize_origins "$WHITELIST")"
    umask 077
    cat > "$CAPSULE_CONFIG" <<EOF
# Capsule configuration — migrated by capsule-fix.sh $(date -Iseconds)
GPU_INDEX=$GPU_INDEX
GAMES_PATH=$GAMES_PATH
PERSISTENT_DATA_PATH=$PERSISTENT_DATA_PATH
SUNSHINE_ALLOWED_ORIGINS=$ORIGINS
STEAMGRIDDB_API_KEY=$API_KEY
SUNSHINE_BASE_PORT=47989
SUNSHINE_PORT_STEP=1000
CAPSULE_USER_PREFIX=capsule
EOF
    umask 022
    log "allowed origins normalized to: $ORIGINS"
fi

[ -f "$CAPSULE_CONFIG" ] || error "No config found — run open_capsule.sh first"
chmod 0640 "$CAPSULE_CONFIG"
chown root:capsule "$CAPSULE_CONFIG"
[ -f "$OLD_CONFIG" ] && chmod 0600 "$OLD_CONFIG" && warn "left $OLD_CONFIG in place but locked to 0600 (remove it when comfortable)"

# 2. repo perms: 777 -> 755 (root-owned; scripts never needed world-write)
chmod -R go-w "$SCRIPT_DIR"
chmod 0755 "$SCRIPT_DIR"

PERSISTENT_DATA_PATH="$(capsule_conf_require PERSISTENT_DATA_PATH)"
ORIGINS="$(capsule_normalize_origins "$(capsule_conf_require SUNSHINE_ALLOWED_ORIGINS)")"

###############################################################################
# 4. persistent dirs (before users, so ownership can be applied)
###############################################################################

capsule_ensure_dir "$PERSISTENT_DATA_PATH" root 0755
capsule_ensure_dir "$PERSISTENT_DATA_PATH/metadata" root 0755
capsule_ensure_dir "$PERSISTENT_DATA_PATH/assets" root 0755
capsule_ensure_dir "$PERSISTENT_DATA_PATH/backups" root 0755
chmod o+rX "$PERSISTENT_DATA_PATH/metadata" "$PERSISTENT_DATA_PATH/assets"

###############################################################################
# per-user repairs
###############################################################################

for HOME_DIR in /home/capsule*/; do
    [ -d "$HOME_DIR" ] || continue
    USERNAME="$(basename "$HOME_DIR")"
    USER_HOME="/home/$USERNAME"
    id "$USERNAME" >/dev/null 2>&1 || continue
    capsule_valid_username "$USERNAME" || continue

    log "Repairing $USERNAME"

    usermod -aG capsule "$USERNAME"

    # index file
    if [ ! -s "$USER_HOME/capsule.config" ]; then
        INDEX="${USERNAME#capsule}"
        [[ "$INDEX" =~ ^[0-9]+$ ]] || error "$USER_HOME/capsule.config missing and cannot infer index from '$USERNAME'"
        printf '%s\n' "$INDEX" > "$USER_HOME/capsule.config"
    fi
    chmod 0644 "$USER_HOME/capsule.config"
    INDEX="$(capsule_read_user_index "$USER_HOME/capsule.config")"

    # 3. sunshine config repair
    CONF="$USER_HOME/.config/sunshine/sunshine.conf"
    if [ -f "$CONF" ]; then
        if grep -q '^csrf_allowed_origins *=' "$CONF"; then
            sed -i "s|^csrf_allowed_origins *=.*|csrf_allowed_origins = $ORIGINS|" "$CONF"
        else
            printf 'csrf_allowed_origins = %s\n' "$ORIGINS" >> "$CONF"
        fi
        grep -q '^origin_web_ui_allowed *=' "$CONF" || \
            printf 'origin_web_ui_allowed = lan\n' >> "$CONF"
        sed -i '/^ds5_inputtino_randomize_mac *=/d' "$CONF"
        chown "$USERNAME:$USERNAME" "$CONF"
        log "  sunshine.conf: csrf=$ORIGINS, web UI allowed from lan"
    fi

    if [ "$RESET_CREDS" = 1 ]; then
        CAPSULE_SUNSHINE_RESET_CREDS=1 sh "$SCRIPT_DIR/preconfig-sunshine.sh" "$USERNAME" "$INDEX"
    fi

    # 4/5. dirs + skeleton
    capsule_ensure_dir "$PERSISTENT_DATA_PATH/backups/$USERNAME" "$USERNAME:$USERNAME" 0755
    capsule_ensure_dir "$USER_HOME/.steam/steam/steamapps/compatdata" "$USERNAME:$USERNAME" 0755

    # 6. units: remove legacy per-user copy, install template + wants symlink
    rm -f /usr/lib/systemd/user/capsule.service \
          "$USER_HOME/.config/systemd/user/capsule.service" \
          "$USER_HOME/.config/systemd/user/default.target.wants/capsule.service"
    install -m 0644 "$SCRIPT_DIR/capsule@.service" /usr/lib/systemd/user/capsule@.service
    WANTS="$USER_HOME/.config/systemd/user/default.target.wants"
    capsule_ensure_dir "$WANTS" "$USERNAME:$USERNAME" 0755
    ln -sf "/usr/lib/systemd/user/capsule@.service" "$WANTS/capsule@$USERNAME.service"
    chown -R "$USERNAME:$USERNAME" "$USER_HOME/.config"
    loginctl enable-linger "$USERNAME"
done

###############################################################################
# 7. host unit + capsulectl
###############################################################################

install -m 0644 "$SCRIPT_DIR/example-capsule-host.service" /etc/systemd/system/capsule-host.service
install -m 0755 "$SCRIPT_DIR/capsulectl" /usr/local/bin/capsulectl
systemctl daemon-reload
systemctl restart capsule-host.service || warn "capsule-host.service failed: journalctl -u capsule-host"

# Reload user managers so new unit template is picked up
for HOME_DIR in /home/capsule*/; do
    USERNAME="$(basename "$HOME_DIR")"
    id "$USERNAME" >/dev/null 2>&1 || continue
    capsule_run_user "$USERNAME" systemctl --user daemon-reload || true
done

echo ""
log "Fixes applied. Current state:"
capsulectl list || true
echo ""
info "Next steps:"
echo "  * start capsules:   capsulectl start all"
echo "  * dashboard:        sh $SCRIPT_DIR/dashboard/install-dashboard.sh"
if [ "$RESET_CREDS" = 0 ]; then
    echo "  * sunshine logins are still capsule/capsule — reset with:"
    echo "      ./capsule-fix.sh --reset-sunshine-creds"
fi
