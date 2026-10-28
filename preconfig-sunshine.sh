#!/bin/bash
# =============================================================================
# Configure Sunshine for one capsule user.
# Usage: preconfig-sunshine.sh <username> <index>
#
# Port layout (index N):
#   base     = SUNSHINE_BASE_PORT + N * SUNSHINE_PORT_STEP   (default 47989 + N*1000)
#   UI (HTTPS) = base + 1   <- the URL you browse to, e.g. https://host:47990
#   Moonlight/streaming ports = base-5 .. base+21
#
# Credentials: a strong random password is generated per capsule, stored
# (root-readable) in /etc/capsule/sunshine-creds/<user> and printed once.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
    echo "Usage: $0 <username> <index>" >&2
    exit 1
fi

USERNAME="$1"
INDEX="$2"

capsule_require_root
capsule_valid_username "$USERNAME" || error "Invalid username '$USERNAME'"
capsule_valid_index "$INDEX" || error "Index must be a number 0-999"

USER_HOME="$(capsule_user_home "$USERNAME")"
[ -d "$USER_HOME" ] || error "Home $USER_HOME missing — run create_user.sh first"

ORIGINS="$(capsule_normalize_origins "$(capsule_conf_require SUNSHINE_ALLOWED_ORIGINS)")"

BASE_PORT="$(capsule_sunshine_base_port)"
PORT=$(( BASE_PORT + INDEX * $(capsule_sunshine_port_step) ))
UI_PORT=$(( PORT + 1 ))

log "Configuring Sunshine for $USERNAME (index=$INDEX)"
info "streaming base port: $PORT   web UI: https://<host>:$UI_PORT"
info "allowed origins:     $ORIGINS"

CONF_DIR="$USER_HOME/.config/sunshine"
CONF="$CONF_DIR/sunshine.conf"
capsule_ensure_dir "$CONF_DIR" "$USERNAME:$USERNAME" 0755

# Fresh config from the template (port/csrf patched below).
install -m 0644 "$SCRIPT_DIR/example-sunshine.conf" "$CONF"

# Patch base port + CSRF origins (exact-key replacement, scheme-validated).
sed -i "s|^port *=.*|port = $PORT|" "$CONF"
sed -i "s|^csrf_allowed_origins *=.*|csrf_allowed_origins = $ORIGINS|" "$CONF"

chown "$USERNAME:$USERNAME" "$CONF"

# --- Credentials ---------------------------------------------------------------
CREDS_DIR="$CAPSULE_DIR/sunshine-creds"
capsule_ensure_dir "$CREDS_DIR" root 0700
CRED_FILE="$CREDS_DIR/$USERNAME"

if [ -f "$CRED_FILE" ] && [ "${CAPSULE_SUNSHINE_RESET_CREDS:-0}" != "1" ]; then
    log "Keeping existing Sunshine credentials for $USERNAME ($CRED_FILE)"
    SUN_PASS="$(cut -d: -f2 "$CRED_FILE")"
else
    SUN_USER="capsule"
    SUN_PASS="$(openssl rand -base64 15 | tr -d '/+=' | head -c 16)"
    printf '%s:%s\n' "$SUN_USER" "$SUN_PASS" > "$CRED_FILE"
    chmod 0600 "$CRED_FILE"
    runuser -u "$USERNAME" -- sunshine --creds "$SUN_USER" "$SUN_PASS"
    log "Sunshine login for $USERNAME  ->  user: $SUN_USER  password: $SUN_PASS"
    info "saved to $CRED_FILE (cat it later if you missed it)"
fi

systemctl daemon-reload
systemctl enable avahi-daemon >/dev/null 2>&1 || warn "avahi-daemon not present, skipping"

log "Sunshine configured for $USERNAME"
