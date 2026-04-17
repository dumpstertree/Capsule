#!/bin/bash

# kill any old instances (prevents port conflicts)
killall -q sunshine
killall -q Xorg

mount -o remount,rw /sys

# Arch udevd path differs from Debian
/usr/lib/systemd/systemd-udevd --daemon
sleep 1

# Trigger udev to process existing input devices
udevadm trigger --subsystem-match=input
udevadm settle


# start dummy Xorg on :0 this needs to not be hardcoded
Xorg :0 -config ./xorg.conf -noreset -novtswitch &
sleep 2

# start dbus session and run everything inside it
dbus-run-session -- bash -c '

export DISPLAY=:0
export SUNSHINE_CAPTURE=x11

# allow local access to X (prevents auth issues)
xhost +local: >/dev/null 2>&1

# start firefox
firefox &

# small delay to ensure something is rendering
sleep 2

# start sunshine
sunshine
'
