#!/bin/sh
# Launch the streamed application (Steam Big Picture).
# DISPLAY must already be exported by the caller (start-stream.sh).
if [ -z "${DISPLAY:-}" ]; then
    echo "inject.sh: DISPLAY is not set" >&2
    exit 1
fi

steam -bigpicture -fulldesktopres >/dev/null 2>&1 &
