#!/bin/bash
# =============================================================================
# Capsule host service: start one Xorg dummy display per capsule user.
# Run as root (capsule-host.service at boot, or manually for debugging).
#
# Idempotent: displays that are already alive are skipped, so it is safe to
# re-run after adding users or after failures.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

capsule_require_root

XORG_CONFIG="${XORG_CONFIG:-/etc/X11/xorg.conf}"
LOG_DIR=/var/log/capsule
capsule_ensure_dir "$LOG_DIR" root 0755

if [ ! -f "$XORG_CONFIG" ]; then
    error "Missing $XORG_CONFIG — run preconfig-xorg.sh first"
fi

echo "Searching for capsule users..."

started=0
skipped=0
failed=0

for HOME_DIR in /home/*; do
    [ -d "$HOME_DIR" ] || continue

    USERNAME="$(basename "$HOME_DIR")"
    CONFIG_FILE="$HOME_DIR/capsule.config"

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Skipping $USERNAME (no capsule.config)"
        continue
    fi

    if ! INDEX="$(capsule_read_user_index "$CONFIG_FILE")"; then
        warn "Skipping $USERNAME: invalid capsule index in $CONFIG_FILE"
        continue
    fi

    DISPLAY_NUM=":$INDEX"

    if capsule_display_up "$INDEX"; then
        echo "Display $DISPLAY_NUM already running — skipping"
        skipped=$((skipped + 1))
        continue
    fi

    # A stale lock from a crashed Xorg blocks startup; clean it only when no
    # Xorg process actually holds it.
    if [ -f "/tmp/.X$INDEX-lock" ]; then
        LOCK_PID="$(cat "/tmp/.X$INDEX-lock" 2>/dev/null | tr -d ' ')"
        if [ -n "$LOCK_PID" ] && ! kill -0 "$LOCK_PID" 2>/dev/null; then
            warn "Removing stale X lock for display $DISPLAY_NUM (pid $LOCK_PID gone)"
            rm -f "/tmp/.X$INDEX-lock"
        fi
    fi

    echo "Starting Xorg for $USERNAME on display $DISPLAY_NUM"
    # shellcheck disable=SC2024  # log path is per-user, validated index
    Xorg "$DISPLAY_NUM" \
        -config "$XORG_CONFIG" \
        -noreset \
        -novtswitch \
        > "$LOG_DIR/xorg-$USERNAME.log" 2>&1 &

    # Wait up to 10s for the socket to appear.
    for _ in $(seq 1 20); do
        capsule_display_up "$INDEX" && break
        sleep 0.5
    done

    if capsule_display_up "$INDEX"; then
        echo "  display $DISPLAY_NUM is up"
        started=$((started + 1))
    else
        warn "Xorg failed to start for $USERNAME on $DISPLAY_NUM — see $LOG_DIR/xorg-$USERNAME.log and /var/log/Xorg.$INDEX.log"
        failed=$((failed + 1))
    fi
done

echo "Xorg displays started: $started, already running: $skipped, failed: $failed"

# Never fail the whole unit for one bad display: a non-zero exit here would
# make systemd kill the still-healthy Xorg servers in this unit's cgroup.
# Only fail when NOTHING is serving displays.
if [ "$started" -eq 0 ] && [ "$skipped" -eq 0 ]; then
    error "No capsule displays could be started"
fi
[ "$failed" -gt 0 ] && exit 0   # partial success stays "active"
