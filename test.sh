#!/usr/bin/env bash

set -e

USER_NAME="gamer"
USER_ID=1000
DISPLAY_NUM=":1"
XDG_RUNTIME_DIR="/run/user/$USER_ID"
XORG_CONF="/tmp/xorg-dummy.conf"

echo "[+] Ensuring user exists..."

if ! id "$USER_NAME" >/dev/null 2>&1; then
useradd -m -u $USER_ID -s /bin/bash "$USER_NAME"
echo "[+] Created user: $USER_NAME"
fi

echo "[+] Fixing ownership..."
chown -R $USER_NAME:$USER_NAME /home/$USER_NAME

echo "[+] Setting up runtime dir..."
mkdir -p "$XDG_RUNTIME_DIR"
chown -R $USER_NAME:$USER_NAME "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

echo "[+] Creating Xorg dummy config..."

cat > "$XORG_CONF" <<EOF
Section "Device"
Identifier "DummyDevice"
Driver "dummy"
EndSection

Section "Monitor"
Identifier "DummyMonitor"
HorizSync 28-80
VertRefresh 48-75
Modeline "1920x1080" 173.00 1920 2048 2248 2576 1080 1083 1088 1120
EndSection

Section "Screen"
Identifier "DummyScreen"
Device "DummyDevice"
Monitor "DummyMonitor"
DefaultDepth 24
SubSection "Display"
Depth 24
Modes "1920x1080"
EndSubSection
EndSection

Section "ServerLayout"
Identifier "Layout0"
Screen 0 "DummyScreen"
EndSection
EOF

echo "[+] Starting Xorg on $DISPLAY_NUM..."
rm -f /tmp/.X1-lock || true

Xorg "$DISPLAY_NUM" -config "$XORG_CONF" -noreset +extension GLX +extension RANDR +extension RENDER &
sleep 3
echo "[+] Starting session as gamer..."

export USER=gamer
export HOME=/home/gamer
export LOGNAME=gamer

export XDG_RUNTIME_DIR=/run/user/1000
mkdir -p $XDG_RUNTIME_DIR
chown gamer:gamer $XDG_RUNTIME_DIR
chmod 700 $XDG_RUNTIME_DIR

# Clean root pollution
unset DBUS_SESSION_BUS_ADDRESS
unset XAUTHORITY

# Start DBus as gamer
echo "[+] Starting DBus..."
sudo -u gamer dbus-daemon --session --address=unix:path=$XDG_RUNTIME_DIR/bus --fork

export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus

echo '[+] Starting DBus...'
dbus-daemon --session --address=$DBUS_SESSION_BUS_ADDRESS --fork

echo "[+] Launching Firefox..."
sudo -u gamer DISPLAY=:1 \
  DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS \
  XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR \
  firefox &

sleep 5

echo '[+] Starting Sunshine...'
sunshine --address 0.0.0.0 &

wait
"

echo "[+] Done. Access Sunshine at:"
echo "    https://<container-ip>:47990"

wait
