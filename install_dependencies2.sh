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

# --- Adding Sunshine Repo
log "Checking Sunshine repository..."
if ! grep -q "^\[lizardbyte\]" /etc/pacman.conf; then
    log "Enabling lizardbyte..."
    printf "\n[lizardbyte]\nSigLevel = Optional\nServer = https://github.com/LizardByte/pacman-repo/releases/latest/download\n" >> /etc/pacman.conf
fi

# --- Enable multilib ---
log "Checking multilib repository..."
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
    log "Enabling multilib..."
    printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >> /etc/pacman.conf
fi

# --- System update ---
log "Updating system..."
pacman -Syu --noconfirm


# --- All Packages
BASE_PACKAGES=(
    nano
    sunshine
    xf86-video-dummy
    xf86-input-libinput
    xorg-server
    xorg-xinput
    xorg-xhost
    dbus
    pipewire 
    pipewire-alsa 
    pipewire-pulse
    wireplumber
    openbox
    xf86-video-amdgpu 
    mesa 
    vulkan-radeon
    libva-mesa-driver
)

# --- Define Install Fn ---
TO_INSTALL=()
for pkg in "${BASE_PACKAGES[@]}"; do
    if ! pacman -Qi "$pkg" &>/dev/null; then
        TO_INSTALL+=("$pkg")
    fi
done

# --- Install ---
echo "Installing all dependencies"
if [[ ${#TO_INSTALL[@]} -gt 0 ]]; then
    pacman -S --noconfirm "${TO_INSTALL[@]}"
else
    log "All base packages already installed"
fi


#pacman -S --needed xf86-video-amdgpu mesa vulkan-radeon libva-mesa-driver
