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

if ! [[ "$INDEX" =~ ^[0-9]+$ ]]; then
    error "Index must be a non-negative integer"
fi

if [ "$(id -u)" -ne 0 ]; then
    error "Must be run as root"
fi

# Sunshine default base ports
BASE_PORT=47989          # HTTP web UI
BASE_HTTPS=47984         # HTTPS
BASE_VIDEO=47998         # video stream
BASE_CONTROL=47999       # control stream
BASE_AUDIO=48000         # audio stream
BASE_MIC=48002           # microphone
BASE_RTSP=48010          # RTSP

OFFSET=$(( INDEX * 1000 ))

PORT=$(( BASE_PORT    + OFFSET ))
HTTPS=$(( BASE_HTTPS  + OFFSET ))
VIDEO=$(( BASE_VIDEO  + OFFSET ))
CONTROL=$(( BASE_CONTROL + OFFSET ))
AUDIO=$(( BASE_AUDIO  + OFFSET ))
MIC=$(( BASE_MIC      + OFFSET ))
RTSP=$(( BASE_RTSP    + OFFSET ))

log "Configuring Sunshine for $USERNAME (index=$INDEX, offset=$OFFSET)"
info "port: $PORT"
#info "  HTTPS port: $HTTPS"
#info "  Video port: $VIDEO"
#info "  Control port: $CONTROL"
#info "  Audio port: $AUDIO"
#info "  Mic port: $MIC"
#info "  RTSP port: $RTSP"

# Create config dir
mkdir -p "$USER_HOME/.config/sunshine/"

# Copy example conf to directory
cp /Capsule/example-sunshine.conf "$USER_HOME/.config/sunshine/sunshine.conf"

# Patch ports into the config
CONF="$USER_HOME/.config/sunshine/sunshine.conf"
sed -i "s/^port\s*=.*/port = $PORT/"         "$CONF"
sed -i "s/^https_port\s*=.*/https_port = $HTTPS/" "$CONF"
sed -i "s/^video_port\s*=.*/video_port = $VIDEO/" "$CONF"
sed -i "s/^control_port\s*=.*/control_port = $CONTROL/" "$CONF"
sed -i "s/^audio_port\s*=.*/audio_port = $AUDIO/"   "$CONF"
sed -i "s/^mic_port\s*=.*/mic_port = $MIC/"         "$CONF"
sed -i "s/^rtsp_port\s*=.*/rtsp_port = $RTSP/"      "$CONF"

# Give access to newly created folder and files
chown -R "$USERNAME" "$USER_HOME/.config/sunshine/"

# Setup the credentials
runuser -u "$USERNAME" -- sunshine --creds capsule capsule

# Reload daemon with new entries
systemctl daemon-reload

# Enable for future reloads
systemctl enable avahi-daemon

log "Sunshine configured for $USERNAME on port offset +$OFFSET"
