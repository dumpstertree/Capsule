# enable all audio servicess
#runuser -u gamer -- systemctl --user enable pipewire.service
#runuser -u gamer -- systemctl --user enable wireplumber.service
#runuser -u gamer -- systemctl --user enable pipewire-pulse.service
#systemctl --user enable pipewire-pulse.socket
#systemctl --user enable pipewire.socket
# As root inside the container


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

mkdir -p $USER_HOME/.config/systemd/user/default.target.wants
ln -sf /usr/lib/systemd/user/pipewire.service $USER_HOME/.config/systemd/user/default.target.wants/pipewire.service
ln -sf /usr/lib/systemd/user/pipewire-pulse.service $USER_HOME/.config/systemd/user/default.target.wants/pipewire-pulse.service
ln -sf /usr/lib/systemd/user/wireplumber.service $USER_HOME/.config/systemd/user/default.target.wants/wireplumber.service
chown -R $USERNAME:$USERNAME $USER_HOME/.config
