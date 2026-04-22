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

if [ -z "$1" ]; then
    echo "Error: username argument required" >&2
    echo "Usage: $0 <username>" >&2
    exit 1
fi

USERNAME="$1"
USER_HOME="/home/$USERNAME"

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: must be run as root" >&2
    exit 1
fi


# Create 
mkdir -p /home/gamer/.config/sunshine/

# Copy example conf to directory
cp /Capsule/example-sunshine.conf /home/gamer/.config/sunshine/sunshine.conf

# Give access to newly created folder and files
chown -R gamer $USER_HOME/.config/sunshine/

# Setup the credentials 
runuser -u $USERNAME -- sunshine --creds capsule capsule

# Reload daemon with new entries
systemctl daemon-reload

# Enable for future reloads
systemctl enable avahi-daemon

# Start
#systemctl start avahi-daemon
