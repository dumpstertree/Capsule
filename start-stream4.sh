#!/bin/bash
set -e

CONFIG_FILE="$HOME/capsule.config"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Missing config file: $CONFIG_FILE"
    exit 1
fi

# read first line and trim whitespace/newlines
INDEX="$(head -n 1 "$CONFIG_FILE" | xargs)"

if [[ -z "$INDEX" ]]; then
    echo "Display index missing in $CONFIG_FILE"
    exit 1
fi

# start dbus session and run everything inside it
#dbus-run-session -- bash -c '

#export DISPLAY=:$0
export DISPLAY=:$INDEX
export XAUTHORITY=/root/.Xauthority

# allow local access to X (prevents auth issues)
xhost +local: >/dev/null 2>&1

echo "Opening Box"
openbox &
sleep 1

echo "Starting App"
sh /Capsule/inject.sh &
INJECT_PID=$!

sleep 2

echo "Starting Sunshine"
sunshine &
SUNSHINE_PID=$!

# wait for either to exit
wait -n $INJECT_PID $SUNSHINE_PID
#' "$INDEX"
