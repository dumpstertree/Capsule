#!/bin/bash
set -e

# --- Helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
log()   { echo -e "${GREEN}[SETUP]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info()  { echo -e "${BLUE}[INFO]${NC} $1"; }

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Error: username and index arguments required" >&2
    echo "Usage: $0 <username> <index>" >&2
    exit 1
fi

USERNAME="$1"
INDEX="$2"
USER_HOME="/home/$USERNAME"

CONFIG_FILE="/capsule-host.config"
GPU_INDEX="$(sed -n '1p' "$CONFIG_FILE" | xargs)"
GAMES_PATH="$(sed -n '2p' "$CONFIG_FILE" | xargs)"
PERSISTENT_DATA_PATH="$(sed -n '3p' "$CONFIG_FILE" | xargs)"
WHITELISTED_SUNSHINE_IPS="$(sed -n '4p' "$CONFIG_FILE" | xargs)"
STEAMGRIDDB_API_KEY="$(sed -n '5p' "$CONFIG_FILE" | xargs)"


if ! [[ "$INDEX" =~ ^[0-9]+$ ]]; then
    error "Index must be a non-negative integer"
fi

if [ "$(id -u)" -ne 0 ]; then
    error "Must be run as root"
fi

# Sunshine default base ports
BASE_PORT=47989          # HTTP web UI
OFFSET=$(( INDEX * 1000 ))
PORT=$(( BASE_PORT + OFFSET ))


log "Configuring Sunshine for $USERNAME (index=$INDEX, offset=$OFFSET)"
info "port: $PORT"

# Create config dir
mkdir -p "$USER_HOME/.config/sunshine/"

# Copy example conf to directory
cp /Capsule/example-sunshine.conf "$USER_HOME/.config/sunshine/sunshine.conf"

# Patch ports into the config
CONF="$USER_HOME/.config/sunshine/sunshine.conf"

# update the port
sed -i "s/^port\s*=.*/port = $PORT/" "$CONF"

#update the csrf whitelist
sed -i "s|^csrf_allowed_origins\s*=.*|csrf_allowed_origins = $WHITELISTED_SUNSHINE_IPS|" "$CONF"

# Give access to newly created folder and files
chown -R "$USERNAME" "$USER_HOME/.config/sunshine/"

# Setup the credentials
runuser -u "$USERNAME" -- sunshine --creds capsule capsule

# Reload daemon with new entries
systemctl daemon-reload

# Enable for future reloads
systemctl enable avahi-daemon

log "Sunshine configured for $USERNAME on port offset +$OFFSET"
