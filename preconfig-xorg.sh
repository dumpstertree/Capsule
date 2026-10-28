#!/bin/bash
# Install Xorg + xwrapper configs. Idempotent. Run as root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

capsule_require_root

if [ ! -f "$SCRIPT_DIR/example-xorg.conf" ]; then
    error "example-xorg.conf missing from repo — repo copy corrupt? Re-run install.sh"
fi

install -D -m 0644 "$SCRIPT_DIR/example-xorg.conf" /etc/X11/xorg.conf
install -D -m 0644 "$SCRIPT_DIR/example-Xwrapper.config" /etc/X11/Xwrapper.config

log "Xorg + Xwrapper configs installed"
