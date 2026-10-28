#!/bin/bash
# =============================================================================
# Install Xorg + xwrapper configs, and generate ONE xorg config per capsule
# display from CAPSULE_GPU_BUSIDS in /etc/capsule/config.
#
#   CAPSULE_GPU_BUSIDS=PCI:18:0:0,PCI:48:0:0
#     -> /etc/X11/capsule/xorg.0.conf  (RX 7600, capsule0)
#     -> /etc/X11/capsule/xorg.1.conf  (iGPU,   capsule1)
#
# BusIDs use DECIMAL pciutils-style numbers — read them from the host:
#   lspci -n -d 1002:      # e.g. 0000:30:00.0 -> PCI:48:0:0 (0x30 = 48)
#
# Each capsule X server then holds DRM master on its OWN GPU; sharing one GPU
# across two GPU-backed Xorg servers is not possible (DRM master is exclusive).
# Empty CAPSULE_GPU_BUSIDS keeps the legacy single /etc/X11/xorg.conf.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

capsule_require_root

TEMPLATE="$SCRIPT_DIR/example-xorg.conf"
[ -f "$TEMPLATE" ] || error "example-xorg.conf missing from repo — re-run install.sh"

install -D -m 0644 "$TEMPLATE" /etc/X11/xorg.conf
install -D -m 0644 "$SCRIPT_DIR/example-Xwrapper.config" /etc/X11/Xwrapper.config

BUSIDS="$(capsule_conf_get CAPSULE_GPU_BUSIDS "")"

if [ -z "$BUSIDS" ]; then
    log "No CAPSULE_GPU_BUSIDS set — using single /etc/X11/xorg.conf for all displays"
    exit 0
fi

capsule_ensure_dir /etc/X11/capsule root 0755

IFS=',' read -ra busids <<< "$BUSIDS"
for i in "${!busids[@]}"; do
    busid="${busids[$i]}"
    # Accept PCI:18:0:0 or pci 18:0:0 forms; validate shape.
    busid="${busid#pci:}"
    [[ "$busid" =~ ^PCI:[0-9]{1,3}:[0-9]{1,3}:[0-9]{1,3}$ ]] \
        || error "Bad CAPSULE_GPU_BUSIDS entry '$busid' — expected PCI:<decimal bus>:<dev>:<func>"

    out="/etc/X11/capsule/xorg.$i.conf"
    sed "s|^    # __BUSID__$|    BusID      \"$busid\"|" "$TEMPLATE" > "$out"
    grep -q "BusID" "$out" || error "BusID substitution failed for $out"
    log "generated $out (BusID $busid)"
done

log "Xorg configs installed ($(IFS=,; echo "${busids[*]}"))"
