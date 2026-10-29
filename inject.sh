#!/bin/sh
# Launch the streamed application (Steam Big Picture).
# DISPLAY must already be exported by the caller (start-stream.sh).
if [ -z "${DISPLAY:-}" ]; then
    echo "inject.sh: DISPLAY is not set" >&2
    exit 1
fi

# Steam's own output is the ONLY place start failures are explained
# (the "could not be started" dialog says nothing else). Keep a per-user
# log; overwritten on each launch so it always matches the last attempt.
STEAM_LOG="/tmp/steam-$(id -un).log"

# Hardware GL for capsules whose X server cannot provide it — EXPERIMENTAL.
# With the marker file below, Steam runs inside gamescope: its compositor
# initialises EGL directly on the DRM render node (the real GPU), so Steam
# gets hardware GL even when the outer display server renders in software.
#
# VERIFIED LIMITATION (gamescope 3.17): this does NOT work on top of the
# dummy driver. Dummy has no DRI3, so gamescope's Vulkan WSI cannot present
# onto it ("No DRI3 support detected ... Failed to create backend") — and
# DRI3 is impossible without DRM master, which another capsule's X owns.
# That failure also proves Vulkan (incl. Proton/DXVK) cannot present on a
# dummy display at all: games there fall back to software GL regardless.
# The fallback below keeps Steam starting normally when gamescope dies.
#
# Enable per capsule:  mkdir -p /home/<user>/.config/capsule
#                      touch     /home/<user>/.config/capsule/gamescope
# Extra gamescope flags (cursor tuning, e.g. --force-grab-cursor) go in
# CAPSULE_GAMESCOPE_OPTS=... in /etc/capsule/config (exported by
# start-stream.sh and the capsule-import.sh Steam relaunch).
if [ -f "$HOME/.config/capsule/gamescope" ]; then
    if command -v gamescope >/dev/null 2>&1; then
        # -W/-H = parent window size, -w/-h = internal resolution,
        # -f = borderless fullscreen. Works when the parent display has
        # DRI3 (e.g. a GPU-backed X); FAILS on dummy — see header note.
        # shellcheck disable=SC2086  # opts string is meant to word-split
        (
            gamescope -W 1920 -H 1080 -w 1920 -h 1080 -f ${CAPSULE_GAMESCOPE_OPTS:-} \
                -- steam -bigpicture -fulldesktopres \
            || steam -bigpicture -fulldesktopres
        ) >"$STEAM_LOG" 2>&1 &
        echo "Steam starting inside gamescope on display $DISPLAY (log: $STEAM_LOG)" >&2
        exit 0
    fi
    echo "inject.sh: gamescope marker present but binary not found — pacman -S gamescope" >&2
fi

steam -bigpicture -fulldesktopres >"$STEAM_LOG" 2>&1 &
echo "Steam starting on display $DISPLAY (log: $STEAM_LOG)" >&2
