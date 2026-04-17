#!/bin/bash
set -e

killall -q sunshine || true
killall -q Xorg     || true

# /sys fix - requires lxc.mount.auto = sys:rw (already set)
/usr/lib/systemd/systemd-udevd --daemon 2>/dev/null || true
sleep 1
udevadm trigger --subsystem-match=input
udevadm settle

# Start Xorg as root (needs privilege for VT/device access)
Xorg :0 -config ./xorg.conf -noreset -novtswitch &
sleep 2

# Run everything else as gamer
exec su - gamer -c '
export DISPLAY=:0
export SUNSHINE_CAPTURE=x11

xhost +local: >/dev/null 2>&1
firefox &
sleep 2
sunshine
'
