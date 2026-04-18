#!/bin/bash
set -e

killall -q sunshine || true
killall -q pipewire || true
killall -q Xorg     || true

# /sys fix - requires lxc.mount.auto = sys:rw (already set)
/usr/lib/systemd/systemd-udevd --daemon 2>/dev/null || true
sleep 1
udevadm trigger --subsystem-match=input
udevadm settle

# start dummy Xorg on :0 this needs to not be hardcoded
Xorg :0 -config ./xorg.conf -noreset -novtswitch &
sleep 2

#xrandr --output DUMMY0 --primary
sleep 2

# start dbus session and run everything inside it
runuser -u gamer -- dbus-run-session -- bash -c '

export DISPLAY=:0
export SUNSHINE_CAPTURE=x11

# allow local access to X (prevents auth issues)
xhost +local: >/dev/null 2>&1

# set primary display
xrandr --newmode "1920x1080" 148.50 1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync
xrandr --addmode DUMMY0 "1920x1080"
xrandr --output DUMMY0 --mode "1920x1080" --primary

# enable audio
pipewire &
wireplumber &
pipewire-pulse &
sleep 2

# start app
sh /Capsule/inject.sh

# small delay to ensure something is rendering
sleep 2

# start sunshine
sunshine
'
