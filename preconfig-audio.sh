#!/bin/bash
# =============================================================================
# Enable pipewire stack for one capsule user (idempotent).
# Usage: preconfig-audio.sh <username>
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

[ -n "${1:-}" ] || { echo "Usage: $0 <username>" >&2; exit 1; }

USERNAME="$1"
capsule_require_root
capsule_valid_username "$USERNAME" || error "Invalid username '$USERNAME'"

USER_HOME="$(capsule_user_home "$USERNAME")"
WANTS="$USER_HOME/.config/systemd/user/default.target.wants"

capsule_ensure_dir "$WANTS" "$USERNAME:$USERNAME" 0755

for unit in pipewire.service pipewire-pulse.service wireplumber.service; do
    if [ -f "/usr/lib/systemd/user/$unit" ]; then
        ln -sf "/usr/lib/systemd/user/$unit" "$WANTS/$unit"
    else
        warn "User unit $unit not installed — skipping"
    fi
done

chown -R "$USERNAME:$USERNAME" "$USER_HOME/.config"
log "Audio units enabled for $USERNAME"
