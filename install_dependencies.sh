log "Installing base packages..."

BASE_PACKAGES=(
    mesa
    lib32-mesa
    vulkan-radeon
    lib32-vulkan-radeon
    libva-mesa-driver
    lib32-libva-mesa-driver
    gamescope
    pipewire
    lib32-pipewire
    pipewire-alsa
    wireplumber
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
