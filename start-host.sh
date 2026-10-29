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

# Pass 1 — collect every (index, user) pair up front: each capsule's Xorg
# config must ignore the input devices of ALL other capsules (pass 2).
declare -a CAP_IDX=() CAP_USER=()
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

    CAP_IDX+=("$INDEX")
    CAP_USER+=("$USERNAME")
done

started=0
skipped=0
failed=0
RUNTIME_CONFIG_DIR=/run/capsule
capsule_ensure_dir "$RUNTIME_CONFIG_DIR" root 0755

for i in "${!CAP_IDX[@]}"; do
    INDEX="${CAP_IDX[$i]}"
    USERNAME="${CAP_USER[$i]}"
    DISPLAY_NUM=":$INDEX"

    if capsule_display_up "$INDEX"; then
        echo "Display $DISPLAY_NUM already running — skipping"
        skipped=$((skipped + 1))
        continue
    fi

    # Optional per-display config override (advanced); default is the shared
    # dummy /etc/X11/xorg.conf.
    DISPLAY_XORG_CONFIG="/etc/X11/capsule/xorg.$INDEX.conf"
    if [ ! -f "$DISPLAY_XORG_CONFIG" ]; then
        DISPLAY_XORG_CONFIG="$XORG_CONFIG"
    fi

    # Input isolation: Sunshine's uinput devices are kernel-global, but each
    # one carries "(seatN)" in its name (N = index+1, exported as XDG_SEAT by
    # start-stream.sh). Generate a per-server config that ignores every
    # FOREIGN capsule's seat, so this display only ever hot-plugs its own
    # capsule's keyboard/mouse. MatchProduct is a substring match, so the
    # rules also cover devices created later, while Xorg runs.
    RUNTIME_XORG_CONFIG="$RUNTIME_CONFIG_DIR/xorg.$INDEX.conf"
    if cp "$DISPLAY_XORG_CONFIG" "$RUNTIME_XORG_CONFIG"; then
        for j in "${!CAP_IDX[@]}"; do
            [ "$i" = "$j" ] && continue
            FOREIGN_SEAT=$(( CAP_IDX[j] + 1 ))
            cat >> "$RUNTIME_XORG_CONFIG" <<EOF

Section "InputClass"
    Identifier  "ignore-foreign-seat-$FOREIGN_SEAT"
    MatchProduct "(seat$FOREIGN_SEAT)"
    Option      "Ignore" "true"
EndSection
EOF
        done
    else
        warn "Could not write $RUNTIME_XORG_CONFIG — falling back to $DISPLAY_XORG_CONFIG (input isolation OFF)"
        RUNTIME_XORG_CONFIG="$DISPLAY_XORG_CONFIG"
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

    echo "Starting Xorg for $USERNAME on display $DISPLAY_NUM (config: $RUNTIME_XORG_CONFIG)"

    # Each Xorg needs a virtual terminal, but claiming VT OWNERSHIP
    # (VT_SETMODE) makes the kernel SIGTERM the previous owner — fatal for
    # multiple servers, and in a container auto-allocation parks them all on
    # tty7 anyway. -sharevts skips the entire ownership block in
    # xf86OpenConsole (no switch_to/VT_SETMODE/KDSETMODE); input arrives via
    # libinput/udev, not the console fd, so ownership buys us nothing here.
    # Unique "vtN" (BARE arg — parsed via sscanf "vt%2d"; "-vtN" is invalid)
    # keeps log lines per-server and the node self-created if udev skipped it.
    VT_NUM=$((7 + INDEX))
    if [ "$VT_NUM" -gt 63 ]; then
        warn "Index $INDEX exceeds VT range; reusing tty7 for $USERNAME"
        VT_NUM=7
    fi
    if [ ! -c "/dev/tty$VT_NUM" ]; then
        warn "Creating missing /dev/tty$VT_NUM"
        mknod -m 600 "/dev/tty$VT_NUM" c 4 "$VT_NUM" 2>/dev/null || \
            warn "mknod /dev/tty$VT_NUM failed"
    fi

    # shellcheck disable=SC2024  # log path is per-user, validated index
    Xorg "$DISPLAY_NUM" \
        -config "$RUNTIME_XORG_CONFIG" \
        -noreset \
        -novtswitch \
        -sharevts \
        "vt$VT_NUM" \
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
        # Echo the reason into the journal so `journalctl -u capsule-host`
        # alone is actionable.
        tail -n 8 "$LOG_DIR/xorg-$USERNAME.log" 2>/dev/null | sed "s/^/[xorg-$USERNAME] /" >&2
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
# Explicit success: a bare test as the last line leaks its result into the
# script's exit code — the old "[ failed -gt 0 ] && exit 0" line exited 1 on
# fully-successful runs, and the unit's cgroup purge then killed the
# healthy Xorgs.
exit 0
