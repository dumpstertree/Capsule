#!/bin/bash
killall -q sunshine
killall -q Xorg

# === CRITICAL FIX ===
# /sys is read-only in LXC which prevents udevd from starting.
# Without udevd, Xorg never sees Sunshine's virtual input devices.
mount -o remount,rw /sys

# Arch udevd path differs from Debian
/usr/lib/systemd/systemd-udevd --daemon
sleep 1

# Trigger udev to process existing input devices
udevadm trigger --subsystem-match=input
udevadm settle

# Start Xorg with the dummy driver
Xorg :0 -config /etc/X11/xorg-dummy.conf -noreset -novtswitch &
sleep 2

dbus-run-session -- bash -c '
export DISPLAY=:0
export SUNSHINE_CAPTURE=x11
xhost +local: >/dev/null 2>&1
firefox &
sleep 2
sunshine
'
