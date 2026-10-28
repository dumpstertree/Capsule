#!/bin/bash
# Install Xorg + xwrapper configs for all capsule displays.
#
# Capsules use the dummy driver: one shared /etc/X11/xorg.conf serves every
# display; GPU work happens through render nodes (see example-xorg.conf).
# Idempotent. Run as root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

capsule_require_root

TEMPLATE="$SCRIPT_DIR/example-xorg.conf"
[ -f "$TEMPLATE" ] || error "example-xorg.conf missing from repo — re-run install.sh"

if ! lsmod | grep -q "^dummy\b" && [ ! -e /dev/dri ] ; then
    warn "/dev/dri missing — GPU render nodes are not visible in this container"
fi

install -D -m 0644 "$TEMPLATE" /etc/X11/xorg.conf
install -D -m 0644 "$SCRIPT_DIR/example-Xwrapper.config" /etc/X11/Xwrapper.config

log "Xorg (dummy) + Xwrapper configs installed"
