#!/bin/bash
# Install the host-side services (Xorg per capsule + dashboard hint).
# Idempotent. Run as root.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

capsule_require_root

install -m 0644 "$SCRIPT_DIR/example-capsule-host.service" /etc/systemd/system/capsule-host.service
systemctl daemon-reload
systemctl enable capsule-host.service
systemctl start capsule-host.service || warn "capsule-host.service failed to start — check: journalctl -u capsule-host"

log "capsule-host.service installed and started"
