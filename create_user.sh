#!/bin/bash
# =============================================================================
# Create one capsule user (idempotent).
# Usage: create_user.sh <username> <display_index>
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

if [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
    echo "Usage: $0 <username> <display_index>" >&2
    exit 1
fi

USERNAME="$1"
INDEX="$2"

capsule_require_root
capsule_valid_username "$USERNAME" || error "Invalid username '$USERNAME'"
capsule_valid_index "$INDEX" || error "Index must be a number 0-999"

USER_HOME="/home/$USERNAME"
PREFIX_GROUP="capsule"

# Shared group so capsule users can read /etc/capsule/config without 777.
getent group "$PREFIX_GROUP" >/dev/null || groupadd "$PREFIX_GROUP"

if id "$USERNAME" >/dev/null 2>&1; then
    log "User $USERNAME already exists — skipping creation"
else
    log "Creating user: $USERNAME"
    useradd -m -G audio,video -s /bin/bash "$USERNAME"
    # NOTE: deliberately NOT calling `passwd -d`. A blank password is a security
    # hole; capsule users are serviced by systemd (linger), never by login.
    # To get a shell: sudo -iu <user>   (root runuser also works)
fi

# GPU / input groups (create-if-missing tolerant).
for group in video render input audio "$PREFIX_GROUP"; do
    if getent group "$group" > /dev/null; then
        usermod -aG "$group" "$USERNAME"
    else
        warn "Group '$group' does not exist, skipping"
    fi
done

log "Capsule index: $INDEX"
printf '%s\n' "$INDEX" > "$USER_HOME/capsule.config"
chmod 0644 "$USER_HOME/capsule.config"

# Steam / Proton skeleton so data-sync and Steam start cleanly on first boot.
capsule_ensure_dir "$USER_HOME/.steam/steam/steamapps/compatdata" "$USERNAME:$USERNAME" 0755
capsule_ensure_dir "$USER_HOME/.config/sunshine" "$USERNAME:$USERNAME" 0755
capsule_ensure_dir "$USER_HOME/.config/systemd/user/default.target.wants" "$USERNAME:$USERNAME" 0755

chown -R "$USERNAME:$USERNAME" "$USER_HOME/.steam" "$USER_HOME/.config"

log "Enabling linger for $USERNAME (user services start without login)"
loginctl enable-linger "$USERNAME"

log "Done: $USERNAME (index $INDEX)"
