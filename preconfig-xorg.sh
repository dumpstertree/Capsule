#!/bin/bash
# Install Xorg + xwrapper configs for all capsule displays.
#
# Default: every capsule uses the shared dummy /etc/X11/xorg.conf; GPU work
# happens through render nodes (see example-xorg.conf). Optionally, ONE
# display can be GPU-backed (hardware GLX) via CAPSULE_GPU_DISPLAYS, which
# generates a per-display override from example-xorg-gpu.conf.
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

# --- Optional GPU-backed displays ------------------------------------------------
# CAPSULE_GPU_DISPLAYS=0      -> display :0 uses the GPU (hardware GLX)
# CAPSULE_KMSDEV=/dev/dri/card1
# start-host.sh picks /etc/X11/capsule/xorg.<N>.conf automatically.
# At most ONE index (DRM master is exclusive per card); others stay dummy.
GPU_DISPLAYS="$(capsule_conf_get CAPSULE_GPU_DISPLAYS "")"
if [ -n "$GPU_DISPLAYS" ]; then
    KMSDEV="$(capsule_conf_get CAPSULE_KMSDEV /dev/dri/card1)"
    GPU_TEMPLATE="$SCRIPT_DIR/example-xorg-gpu.conf"
    [ -f "$GPU_TEMPLATE" ] || error "example-xorg-gpu.conf missing from repo"

    count=0
    capsule_ensure_dir /etc/X11/capsule root 0755
    for idx in $(echo "$GPU_DISPLAYS" | tr ',' ' '); do
        [[ "$idx" =~ ^[0-9]{1,3}$ ]] \
            || error "Bad CAPSULE_GPU_DISPLAYS entry '$idx' — expected display indices like 0 or 0,1"
        out="/etc/X11/capsule/xorg.$idx.conf"
        sed "s|__KMSDEV__|$KMSDEV|" "$GPU_TEMPLATE" > "$out"
        grep -q "$KMSDEV" "$out" || error "kmsdev substitution failed for $out"
        log "generated $out (GPU-backed, kmsdev $KMSDEV)"
        count=$((count + 1))
    done
    [ "$count" -le 1 ] || warn "CAPSULE_GPU_DISPLAYS lists $count displays — only one can hold DRM master; the rest will fail to start"
fi

log "Xorg (dummy + overrides) + Xwrapper configs installed"
