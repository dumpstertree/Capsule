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

# Create 
mkdir -p /home/gamer/.config/sunshine/

# Copy example conf to directory
cp /Capsule/example-sunshine.conf /home/gamer/.config/sunshine/sunshine.conf

# Give access to newly created folder and files
chown -R gamer /home/gamer/.config/sunshine/

# Setup the credentials 
runuser -u gamer -- sunshine --creds gamer gamer

# Reload daemon with new entries
systemctl daemon-reload

# Enable for future reloads
systemctl enable avahi-daemon

# Start
#systemctl start avahi-daemon
