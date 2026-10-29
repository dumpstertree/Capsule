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
steam -bigpicture -fulldesktopres >"$STEAM_LOG" 2>&1 &
echo "Steam starting on display $DISPLAY (log: $STEAM_LOG)" >&2
