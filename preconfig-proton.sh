#!/bin/bash
# =============================================================================
# Install Proton-GE for one capsule user.
# Usage: preconfig-proton.sh <username>
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
COMPAT_DIR="$USER_HOME/.steam/root/compatibilitytools.d"
capsule_ensure_dir "$COMPAT_DIR" "$USERNAME:$USERNAME" 0755

if compgen -G "$COMPAT_DIR/proton-ge-*" >/dev/null; then
    log "Proton-GE already installed for $USERNAME — skipping"
    exit 0
fi

ARCH="$(uname -m)"
LATEST="$(curl -fsSL "https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest" \
    | grep browser_download_url | grep "${ARCH}.tar.gz\"" | cut -d '"' -f 4)"

[ -n "$LATEST" ] || error "Could not resolve latest proton-ge release for $ARCH"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "Downloading Proton-GE for $USERNAME"
wget -q -O "$TMP/proton-ge.tar.gz" "$LATEST" || error "Download failed: $LATEST"
tar -xf "$TMP/proton-ge.tar.gz" -C "$COMPAT_DIR/" || error "Extraction failed"

chown -R "$USERNAME:$USERNAME" "$USER_HOME/.steam"
log "Proton-GE installed for $USERNAME"
