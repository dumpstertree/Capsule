#!/bin/bash
set -e

INDEX="$0"

# start dbus session and run everything inside it
dbus-run-session -- bash -c '

export DISPLAY=:$0
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
' "$INDEX"
