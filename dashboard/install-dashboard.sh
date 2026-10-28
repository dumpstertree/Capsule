#!/bin/bash
# =============================================================================
# Install/upgrade the Capsule web dashboard (run inside the capsule container).
#   - venv at /opt/capsule-dashboard
#   - config/secrets at /etc/capsule/dashboard (0700)
#   - systemd unit capsule-dashboard.service on https://<container>:8443
# Idempotent: re-run to upgrade code or change the password.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

capsule_require_root

INSTALL_DIR=/opt/capsule-dashboard
DASH_DIR=/etc/capsule/dashboard
PORT="${CAPSULE_DASHBOARD_PORT:-8443}"

command -v capsulectl >/dev/null || warn "capsulectl not in PATH — install core first (open_capsule.sh or capsule-fix.sh)"

log "System packages"
NEED=()
for p in python python-virtualenv openssl; do
    pacman -Qi "$p" >/dev/null 2>&1 || NEED+=("$p")
done
[ ${#NEED[@]} -gt 0 ] && pacman -S --noconfirm "${NEED[@]}"

log "Installing app to $INSTALL_DIR"
capsule_ensure_dir "$INSTALL_DIR" root 0755
install -m 0644 "$SCRIPT_DIR/server.py" "$INSTALL_DIR/server.py"
cp -r "$SCRIPT_DIR/static" "$INSTALL_DIR/static"
install -m 0644 "$SCRIPT_DIR/requirements.txt" "$INSTALL_DIR/requirements.txt"

if [ ! -x "$INSTALL_DIR/venv/bin/python" ]; then
    log "Creating venv"
    python -m venv "$INSTALL_DIR/venv"
fi
"$INSTALL_DIR/venv/bin/pip" install -q --upgrade -r "$INSTALL_DIR/requirements.txt"

log "Secrets + config in $DASH_DIR"
capsule_ensure_dir "$DASH_DIR" root 0700

if [ ! -f "$DASH_DIR/config.yaml" ]; then
    cat > "$DASH_DIR/config.yaml" <<EOF
# Capsule dashboard configuration
bind: 0.0.0.0
port: $PORT
admin_user: admin
# Host used for Sunshine UI links (e.g. your public hostname or IP).
# Empty = whatever host the browser is talking to.
capsule_host: ""
session_hours: 12
EOF
    chmod 0600 "$DASH_DIR/config.yaml"
    log "wrote $DASH_DIR/config.yaml (edit to taste)"
fi

if [ ! -f "$DASH_DIR/credentials" ]; then
    ADMIN_USER="$(sed -n 's/^admin_user: *//p' "$DASH_DIR/config.yaml")"
    ADMIN_USER="${ADMIN_USER:-admin}"
    info "Choose the dashboard login password (username: $ADMIN_USER)"
    stty -echo 2>/dev/null || true
    printf "password: " && read -r PASS1 && printf "\nconfirm: " && read -r PASS2 && printf "\n"
    stty echo 2>/dev/null || true
    [ "$PASS1" = "$PASS2" ] || error "passwords do not match"
    [ ${#PASS1} -ge 12 ] || error "password too short (min 12 chars) — you are exposing this to the internet"
    "$INSTALL_DIR/venv/bin/python" - "$ADMIN_USER" "$PASS1" >> "$DASH_DIR/credentials" <<'PYEOF'
import hashlib, secrets, sys
n, r, p = 2**15, 8, 1
salt = secrets.token_bytes(16)
dk = hashlib.scrypt(sys.argv[2].encode(), salt=salt, n=n, r=r, p=p, dklen=32, maxmem=256*1024*1024)
print(f"{sys.argv[1]}:scrypt${n}${r}${p}${salt.hex()}${dk.hex()}")
PYEOF
    PASS1=""
    chmod 0600 "$DASH_DIR/credentials"
    log "admin credentials written"
else
    log "keeping existing credentials (delete $DASH_DIR/credentials to reset)"
fi

# Session signing key + TLS cert (unit mounts /etc read-only, so generate here)
"$INSTALL_DIR/venv/bin/python" -c "import secrets,pathlib;pathlib.Path('$DASH_DIR/secret').write_bytes(secrets.token_bytes(32))" 2>/dev/null \
    || true
chmod 0600 "$DASH_DIR/secret" 2>/dev/null || true

if [ ! -f "$DASH_DIR/cert.pem" ] || [ ! -f "$DASH_DIR/key.pem" ]; then
    log "Generating self-signed TLS certificate (10 years)"
    openssl ecparam -name prime256v1 -genkey -noout -out "$DASH_DIR/key.pem"
    openssl req -x509 -key "$DASH_DIR/key.pem" -sha256 -days 3650 \
        -subj "/CN=capsule-dashboard/O=Capsule" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
        -out "$DASH_DIR/cert.pem"
    chmod 0600 "$DASH_DIR/key.pem"
    chmod 0644 "$DASH_DIR/cert.pem"
fi

log "Installing systemd unit"
install -m 0644 "$SCRIPT_DIR/capsule-dashboard.service" /etc/systemd/system/capsule-dashboard.service
systemctl daemon-reload
systemctl enable --now capsule-dashboard.service
systemctl restart capsule-dashboard.service

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo ""
echo "====================================================="
echo " Dashboard:  https://${IP:-<container-ip>}:$PORT"
echo " Login:      admin / <password you just set>"
echo ""
echo " Port forward to port $PORT, or reverse-proxy to it."
echo " Self-signed cert: accept the warning or put your own"
echo " key.pem/cert.pem in $DASH_DIR and restart the service."
echo "====================================================="
