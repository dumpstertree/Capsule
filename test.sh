#!/usr/bin/env bash

set -e

DISPLAY_NUM=":1"
XDG_RUNTIME_DIR="/run/user/$(id -u)"
XORG_CONF="/tmp/xorg-dummy.conf"

echo "[+] Running as user: $(whoami)"

# Ensure runtime dir exists
echo "[+] Setting up runtime dir..."
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

export XDG_RUNTIME_DIR
export DISPLAY="$DISPLAY_NUM"

# Start DBus session if not already running
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    echo "[+] Starting DBus session..."
    eval "$(dbus-launch --sh-syntax)"
fi

# Create dummy Xorg config
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

Xorg "$DISPLAY_NUM" \
    -config "$XORG_CONF" \
    -noreset \
    +extension GLX \
    +extension RANDR \
    +extension RENDER &

sleep 3

# Verify X is alive
if ! xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1; then
    echo "[!] Xorg failed to start"
    exit 1
fi

echo "[+] Xorg is running"

# Optional: sanity GPU check
echo "[+] Checking GPU access..."
ls -l /dev/dri || true

# Launch Firefox (test app)
echo "[+] Launching Firefox..."
DISPLAY="$DISPLAY_NUM" firefox &

sleep 5

# Launch Sunshine
echo "[+] Starting Sunshine..."
DISPLAY="$DISPLAY_NUM" sunshine &

echo "[+] Done."
echo "    Display: $DISPLAY_NUM"
echo "    Sunshine UI: https://<container-ip>:47990"

wait
