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

# ---  ---
log "Generating sunshine.conf..."
mkdir /home/gamer/.config/sunshine/
touch /home/gamer/.config/sunshine/sunshine.conf
printf 'origin_web_ui_allowed = wan\naddress_family = both\nupnp = disabled' >> /etc/pacman.conf

# --- Setup Creds ---
log "Setting Sunshine Credentials..."
runuser -u gamer -- sunshine --creds gamer gamer
