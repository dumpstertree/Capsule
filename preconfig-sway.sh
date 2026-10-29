#!/bin/bash
# =============================================================================
# Convert an existing capsule user to a SWAY-type game capsule: Steam/games
# streamed from a headless wlroots (Wayland) session composited on the GPU,
# captured by Sunshine's wlr backend. No Xorg for this capsule.
#
# Usage: preconfig-sway.sh <username>
#
# Why: dummy X displays cannot present hardware Vulkan (DRI3 -> KMS -> DRM
# master wall; master is held by the GPU-backed capsule). Wayland's WSI has
# no such wall: games render on the DRM render node and present via dmabuf.
# See README "Sway game capsule" for verification steps and the input-
# isolation caveat (milestone 2).
#
# Revert to the X session:  sed -i '/^TYPE=/d' /home/<user>/capsule.config
#                           ./preconfig-sunshine.sh <user> <index>
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

capsule_require_root

USERNAME="${1:-}"
[ -n "$USERNAME" ] || error "Usage: $0 <username>"
capsule_valid_username "$USERNAME" || error "Invalid username '$USERNAME'"
USER_HOME="$(capsule_user_home "$USERNAME")" || error "User $USERNAME does not exist"
[ -f "$USER_HOME/capsule.config" ] || error "$USER_HOME/capsule.config missing — is $USERNAME a capsule?"
INDEX="$(capsule_read_user_index "$USER_HOME/capsule.config")" \
    || error "Invalid capsule index in $USER_HOME/capsule.config"

RENDER_NODE="$(capsule_conf_get CAPSULE_RENDER_NODE /dev/dri/renderD128)"

log "Installing sway + mesa-utils (mesa-utils = eglinfo for verification)..."
pacman -S --needed --noconfirm sway mesa-utils

if [ ! -e "$RENDER_NODE" ]; then
    warn "Render node $RENDER_NODE not present in this container — add it to the LXC"
    warn "config (see example-lxc.conf) before starting the sway capsule."
fi

# --- Mark TYPE=sway -----------------------------------------------------------
if grep -q '^TYPE=' "$USER_HOME/capsule.config"; then
    sed -i 's/^TYPE=.*/TYPE=sway/' "$USER_HOME/capsule.config"
else
    printf 'TYPE=sway\n' >> "$USER_HOME/capsule.config"
fi
log "$USERNAME is now TYPE=sway (display index $INDEX untouched)"

# --- Sunshine: capture = wlr ----------------------------------------------------
SUN_CONF="$USER_HOME/.config/sunshine/sunshine.conf"
if [ -f "$SUN_CONF" ]; then
    sed -i "s|^capture *=.*|capture = wlr|" "$SUN_CONF"
    log "Sunshine capture backend set to wlr"
else
    log "No sunshine.conf yet — run preconfig-sunshine.sh $USERNAME $INDEX (it will pick wlr automatically)"
fi

# --- Take down the old session cleanly -------------------------------------------
if capsule_run_user "$USERNAME" systemctl --user is-active --quiet "capsule@$USERNAME.service"; then
    log "Stopping the running $USERNAME session..."
    capsule_run_user "$USERNAME" systemctl --user stop "capsule@$USERNAME.service"
fi
if capsule_display_up "$INDEX"; then
    log "Retiring Xorg :$INDEX (owned by capsule-host; start-host now skips sway capsules,"
    log "so it will NOT come back on capsule-host restart)"
    pkill -f "Xorg :$INDEX" || true
    sleep 2
fi

cat <<EOF

$(printf '\033[0;32m[SETUP]\033[0m') $USERNAME converted. Try it:
  capsulectl start $USERNAME
  Moonlight -> same ports as before (UI https://<host>:$(capsule_sunshine_ui_port "$INDEX"))

Verify it is HARDWARE all the way (as root, while running):
  journalctl --user -u capsule@$USERNAME | tail -30     # sway + sunshine startup
  runuser -u $USERNAME -- env XDG_RUNTIME_DIR=/run/user/$(id -u "$USERNAME") \\
      WAYLAND_DISPLAY=wayland-1 eglinfo 2>/dev/null | grep -i 'renderer\|opengl'
      # want: AMD Radeon RX 6800 (radeonsi) — NOT llvmpipe
  runuser -u $USERNAME -- env XDG_RUNTIME_DIR=/run/user/$(id -u "$USERNAME") \\
      WAYLAND_DISPLAY=wayland-1 vulkaninfo --summary 2>/dev/null | grep deviceName
      # want: Radeon RX 6800
Known caveat (milestone 2): sway opens every input device its user may read,
so with several capsules running simultaneously Sunshine's virtual mouse can
appear in more than one session — see README before running two at once.
EOF
