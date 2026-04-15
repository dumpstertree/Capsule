
set -uo pipefail

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

BASE_PACKAGES=(
    #mesa
    #lib32-mesa
    vulkan-radeon
    lib32-vulkan-radeon
    #libva-mesa-driver
    #lib32-libva-mesa-driver
    gamescope
    #pipewire
    #lib32-pipewire
    #pipewire-alsa
    #wireplumber
    steam
    curl
    sudo
    git
    base-devel
)

TO_INSTALL=()
for pkg in "${BASE_PACKAGES[@]}"; do
    if ! pacman -Qi "$pkg" &>/dev/null; then
        TO_INSTALL+=("$pkg")
    fi
done

if [[ ${#TO_INSTALL[@]} -gt 0 ]]; then
    pacman -S --noconfirm "${TO_INSTALL[@]}"
else
    log "All base packages already installed"
fi
