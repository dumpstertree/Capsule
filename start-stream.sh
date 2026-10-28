#!/bin/bash
# =============================================================================
# Capsule stream launcher — started by capsule@<user>.service, also safe to
# run manually from the capsule user's shell.
#
# Replaces the old start-stream{,2,3,4}.sh variants:
#   * no hardcoded XAUTHORITY=/root/.Xauthority (broke manual runs as the
#     capsule user and had an "$0" display bug in the original)
#   * fixes the quoting bug in start-stream3.sh where $INDEX was invisible
#     to the inner `bash -c` shell (never exported)
#   * refuses to double-start sunshine/openbox/steam
#   * save-sync failures warn but never take the stream down
#   * refuses to run when the capsule's Xorg display is not up, with a fix hint
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

USERNAME="$(whoami)"
USER_HOME="$(capsule_user_home "$USERNAME")"

# --- Index from ~/.capsule.config (line 1) ------------------------------------
if ! INDEX="$(capsule_read_user_index "$USER_HOME/capsule.config")"; then
    error "Missing or invalid $USER_HOME/capsule.config (expected capsule index on line 1).
Run as root: echo <index> > $USER_HOME/capsule.config && chown $USERNAME $USER_HOME/capsule.config"
fi

# --- Session environment -------------------------------------------------------
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DISPLAY=":$INDEX"

# A dbus session is required by pipewire/steam. Under the systemd user service
# it is provided by dbus-user-session; for manual runs create one and re-exec.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    if [ ! -S "$XDG_RUNTIME_DIR/bus" ]; then
        error "No dbus session found. Start one (dbus-run-session -- bash) or run inside the capsule service."
    fi
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
fi

# --- Refuse double-start --------------------------------------------------------
if pgrep -U "$(id -u)" -x sunshine >/dev/null 2>&1; then
    echo "Sunshine already running for $USERNAME (pid $(pgrep -U "$(id -u)" -x sunshine | head -1)). Exiting."
    exit 0
fi

# --- Xorg display must already be up (started by capsule-host.service) ---------
if ! capsule_display_up "$INDEX"; then
    error "X display :$INDEX is not running.
Start it as root:  /Capsule/start-host.sh
or restart:         systemctl restart capsule-host.service"
fi

# Allow local connections without shipping root's Xauthority around.
# Best-effort: harmless if auth is already open or handled another way.
xhost "+local:" >/dev/null 2>&1 || true

# --- Save sync (best effort — never block the stream on it) ---------------------
if ! sh "$SCRIPT_DIR/data-sync.sh"; then
    warn "Data sync failed — starting stream anyway (saves may be out of date)"
fi

# --- Window manager -------------------------------------------------------------
if ! pgrep -U "$(id -u)" -x openbox >/dev/null 2>&1; then
    echo "Opening Box"
    openbox &
    sleep 1
fi

# --- Steam (Big Picture) ----------------------------------------------------------
if ! pgrep -U "$(id -u)" -f 'steam.*bigpicture' >/dev/null 2>&1; then
    echo "Starting App"
    sh "$SCRIPT_DIR/inject.sh"
fi

# --- Sunshine in the foreground (systemd tracks/restarts this) ---------------------
echo "Starting Sunshine on display :$INDEX (web UI: https://<this-host>:$(capsule_sunshine_ui_port "$INDEX"))"
exec sunshine
