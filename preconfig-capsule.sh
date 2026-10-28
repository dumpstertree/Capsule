#!/bin/bash
# =============================================================================
# Install the capsule@.service user template and enable it for one user.
# Usage: preconfig-capsule.sh <username> <index>
#
# Replaces the old copy-per-user capsule.service + sed-ExecStart approach:
# a single templated unit is installed machine-wide and enabled per user via
# a wants-symlink named capsule@<user>.service.
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

install -m 0644 "$SCRIPT_DIR/capsule@.service" /usr/lib/systemd/user/capsule@.service

WANTS="$USER_HOME/.config/systemd/user/default.target.wants"
capsule_ensure_dir "$WANTS" "$USERNAME:$USERNAME" 0755
ln -sf "/usr/lib/systemd/user/capsule@.service" "$WANTS/capsule@$USERNAME.service"

chown -R "$USERNAME:$USERNAME" "$USER_HOME/.config"
systemctl daemon-reload

log "capsule@$USERNAME.service enabled (display :$INDEX)"
