#!/bin/bash
# =============================================================================
# Capsule — Gaming LXC Setup
# Steam Big Picture + Gamescope + Sunshine (VAAPI)
#
# Usage: sudo bash setup.sh <path-to-config.yaml>
#
# DISK REQUIREMENT: At least 10GB free before running.
#
# HOST REQUIREMENTS (add to /etc/pve/lxc/VMID.conf on Proxmox host):
#
#   lxc.cgroup2.devices.allow: c 226:1 rwm
#   lxc.cgroup2.devices.allow: c 226:129 rwm
#   lxc.mount.entry: /dev/dri/card1 dev/dri/card1 none bind,optional,create=file
#   lxc.mount.entry: /dev/dri/renderD129 dev/dri/renderD129 none bind,optional,create=file
#   lxc.init.cmd: /sbin/init
#
#   Note: Adjust card1/renderD129 to match your GPU index.
#   All containers sharing the same GPU use the same device nodes.
#
# HOST udev rule (run once on Proxmox host):
#
#   cat > /etc/udev/rules.d/99-dri-lxc.rules << EOF
#   SUBSYSTEM=="drm", KERNEL=="card1", MODE="0666"
#   SUBSYSTEM=="drm", KERNEL=="renderD129", MODE="0666"
#   EOF
#   udevadm control --reload-rules && udevadm trigger
# =============================================================================

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

# --- Root check ---
[[ $EUID -ne 0 ]] && error "This script must be run as root"

# --- Config file argument ---
[[ $# -lt 1 ]] && error "Usage: bash setup.sh <path-to-config.yaml>"
CONFIG_FILE="$1"
[[ ! -f "$CONFIG_FILE" ]] && error "Config file not found: $CONFIG_FILE"

# --- Install correct yq (mikefarah Go binary, not the pacman Python wrapper) ---
install_yq() {
    log "Installing yq (mikefarah)..."
    # Remove pacman yq if present — it's a different incompatible tool
    pacman -Rns --noconfirm yq 2>/dev/null || true
    curl -sL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" \
        -o /usr/local/bin/yq
    chmod +x /usr/local/bin/yq
}

if command -v yq &>/dev/null; then
    # Check it's the correct yq by looking for mikefarah in version output
    if ! yq --version 2>&1 | grep -q "mikefarah\|version v4\|version v3"; then
        warn "Wrong yq version detected, replacing with mikefarah yq..."
        install_yq
    else
        log "yq already installed correctly"
    fi
else
    install_yq
fi

# Verify yq works
yq --version &>/dev/null || error "yq installation failed"

# --- Parse config ---
log "Reading config from $CONFIG_FILE..."

cfg() {
    yq e "$1" "$CONFIG_FILE" 2>/dev/null
}

# User
GAMING_USER=$(cfg '.user.name // "gamer"')

# GPU — derive card and render paths from index
GPU_INDEX=$(cfg '.gpu.index // 0')
GPU_CARD="/dev/dri/card${GPU_INDEX}"
GPU_RENDER="/dev/dri/renderD$((128 + GPU_INDEX))"

# Steam
STEAM_OFFLINE=$(cfg '.steam.offline // "false"')

# Display / gamescope
RESOLUTION_W=$(cfg '.display.width // 1920')
RESOLUTION_H=$(cfg '.display.height // 1080')
REFRESH_RATE=$(cfg '.display.refresh_rate // 60')

# Sunshine
SUNSHINE_ENCODER=$(cfg '.sunshine.encoder // "vaapi"')
SUNSHINE_BITRATE=$(cfg '.sunshine.bitrate // 50000')
SUNSHINE_PORT=$(cfg '.sunshine.port // 47990')
SUNSHINE_LOG_LEVEL=$(cfg '.sunshine.log_level // "info"')

# Validate required values parsed correctly
[[ -z "$GAMING_USER" ]]     && error "Failed to parse user.name from config"
[[ -z "$GPU_INDEX" ]]       && error "Failed to parse gpu.index from config"
[[ -z "$RESOLUTION_W" ]]    && error "Failed to parse display.width from config"
[[ -z "$RESOLUTION_H" ]]    && error "Failed to parse display.height from config"
[[ -z "$REFRESH_RATE" ]]    && error "Failed to parse display.refresh_rate from config"
[[ -z "$SUNSHINE_ENCODER" ]] && error "Failed to parse sunshine.encoder from config"
[[ -z "$SUNSHINE_BITRATE" ]] && error "Failed to parse sunshine.bitrate from config"
[[ -z "$SUNSHINE_PORT" ]]   && error "Failed to parse sunshine.port from config"

log "Config loaded:"
info "  User:          $GAMING_USER"
info "  GPU card:      $GPU_CARD"
info "  GPU render:    $GPU_RENDER"
info "  Resolution:    ${RESOLUTION_W}x${RESOLUTION_H} @ ${REFRESH_RATE}fps"
info "  Encoder:       $SUNSHINE_ENCODER"
info "  Bitrate:       $SUNSHINE_BITRATE kbps"
info "  Sunshine port: $SUNSHINE_PORT"
info "  Log level:     $SUNSHINE_LOG_LEVEL"
info "  Steam offline: $STEAM_OFFLINE"

# --- Disk space check ---
FREE_GB=$(df / --output=avail | tail -1 | awk '{print int($1/1024/1024)}')
if [[ $FREE_GB -lt 10 ]]; then
    error "Less than 10GB free (${FREE_GB}GB available). Expand the container disk before running."
fi
log "Disk space check passed (${FREE_GB}GB free)"

# --- GPU path validation ---
log "Validating GPU device paths..."
if [[ ! -e "$GPU_CARD" ]]; then
    error "GPU card device not found: $GPU_CARD
  Ensure the host LXC config has the correct mount entries and the container has been restarted.
  Expected host config:
    lxc.cgroup2.devices.allow: c 226:${GPU_INDEX} rwm
    lxc.mount.entry: $GPU_CARD dev/dri/card${GPU_INDEX} none bind,optional,create=file
  Also ensure the host udev rule sets MODE=0666 for this device."
fi

if [[ ! -e "$GPU_RENDER" ]]; then
    error "GPU render device not found: $GPU_RENDER
  Ensure the host LXC config has the correct mount entries and the container has been restarted.
  Expected host config:
    lxc.cgroup2.devices.allow: c 226:$((128 + GPU_INDEX)) rwm
    lxc.mount.entry: $GPU_RENDER dev/dri/renderD$((128 + GPU_INDEX)) none bind,optional,create=file
  Also ensure the host udev rule sets MODE=0666 for this device."
fi
log "GPU devices found: $GPU_CARD and $GPU_RENDER"

# --- Install systemd if not present ---
if ! command -v systemctl &>/dev/null; then
    log "systemd not found, installing..."
    pacman -S --noconfirm systemd systemd-sysvcompat
    warn "systemd installed. Add the following to your host LXC config and restart:"
    warn "  lxc.init.cmd: /sbin/init"
    warn "Then re-run this script."
    exit 0
fi

PID1=$(cat /proc/1/comm)
if [[ "$PID1" != "systemd" && "$PID1" != "init" ]]; then
    warn "systemd installed but not running as PID 1 (current: $PID1)"
    warn "Add the following to your host LXC config and restart:"
    warn "  lxc.init.cmd: /sbin/init"
    warn "Then re-run this script."
    exit 0
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

# --- Base packages ---
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

if [[ ${#TO_INSTALL[@]} -gt 0 ]]; then
    pacman -S --noconfirm "${TO_INSTALL[@]}"
else
    log "All base packages already installed"
fi

# --- Create gaming user ---
if id "$GAMING_USER" &>/dev/null; then
    log "User '$GAMING_USER' already exists, skipping creation"
else
    log "Creating user '$GAMING_USER'..."
    useradd -m -s /bin/bash "$GAMING_USER"
fi

usermod -aG video,render,audio,input "$GAMING_USER"

SUDOERS_FILE="/etc/sudoers.d/$GAMING_USER"
if [[ ! -f "$SUDOERS_FILE" ]]; then
    echo "$GAMING_USER ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"
fi

GAMING_UID=$(id -u "$GAMING_USER")
GAMING_HOME=$(getent passwd "$GAMING_USER" | cut -d: -f6)

# --- Lingering ---
log "Enabling lingering for '$GAMING_USER'..."
if loginctl enable-linger "$GAMING_USER" 2>/dev/null; then
    log "Lingering enabled"
else
    warn "Could not enable lingering — services may not start on boot without a login session"
fi

# --- Install yay ---
if sudo -u "$GAMING_USER" which yay &>/dev/null; then
    log "yay already installed"
else
    log "Installing yay..."
    sudo -u "$GAMING_USER" bash -c "
        cd /tmp
        rm -rf yay-setup
        mkdir yay-setup && cd yay-setup
        git clone https://aur.archlinux.org/yay.git
        cd yay
        makepkg -si --noconfirm
    "
fi

# --- Install Sunshine via AUR ---
if pacman -Qi sunshine &>/dev/null; then
    log "Sunshine already installed"
else
    log "Installing Sunshine via AUR (this will take 20-40 minutes)..."
    sudo -u "$GAMING_USER" yay -S --noconfirm --answerdiff=None --answerclean=None sunshine
fi

# --- Configure Sunshine ---
log "Configuring Sunshine..."
SUNSHINE_CONF_DIR="$GAMING_HOME/.config/sunshine"
mkdir -p "$SUNSHINE_CONF_DIR"

case "$SUNSHINE_LOG_LEVEL" in
    none)    SUNSHINE_LOG_NUM=0 ;;
    fatal)   SUNSHINE_LOG_NUM=1 ;;
    error)   SUNSHINE_LOG_NUM=2 ;;
    warning) SUNSHINE_LOG_NUM=3 ;;
    info)    SUNSHINE_LOG_NUM=4 ;;
    debug)   SUNSHINE_LOG_NUM=5 ;;
    verbose) SUNSHINE_LOG_NUM=6 ;;
    *)       SUNSHINE_LOG_NUM=4 ;;
esac

cat > "$SUNSHINE_CONF_DIR/sunshine.conf" << EOF
# Sunshine configuration
# Generated by Capsule setup.sh — do not edit manually

encoder = $SUNSHINE_ENCODER
adapter_name = $GPU_RENDER
output_name = 0

resolutions = [${RESOLUTION_W}x${RESOLUTION_H}]
fps = [$REFRESH_RATE]
bitrate = $SUNSHINE_BITRATE
port = $SUNSHINE_PORT
min_log_level = $SUNSHINE_LOG_NUM
EOF

chown -R "$GAMING_USER:$GAMING_USER" "$SUNSHINE_CONF_DIR"

# --- Gamescope + Steam launch script ---
log "Creating gamescope launch script..."
LAUNCH_SCRIPT="$GAMING_HOME/start-gaming.sh"

STEAM_FLAGS="-gamepadui -pipewire-dmabuf"
if [[ "$STEAM_OFFLINE" == "true" ]]; then
    STEAM_FLAGS="$STEAM_FLAGS -offline"
fi

cat > "$LAUNCH_SCRIPT" << EOF
#!/bin/bash
# Wait for GPU render node to be available (up to 60 seconds)
for i in \$(seq 1 60); do
    if [[ -e $GPU_RENDER ]]; then
        break
    fi
    echo "Waiting for $GPU_RENDER... (\$i/60)"
    sleep 1
done

if [[ ! -e $GPU_RENDER ]]; then
    echo "ERROR: $GPU_RENDER never appeared, exiting"
    exit 1
fi

exec gamescope \\
    -W $RESOLUTION_W \\
    -H $RESOLUTION_H \\
    -r $REFRESH_RATE \\
    --backend drm \\
    --xwayland-count 2 \\
    -f \\
    -- steam $STEAM_FLAGS
EOF

chmod +x "$LAUNCH_SCRIPT"
chown "$GAMING_USER:$GAMING_USER" "$LAUNCH_SCRIPT"

# --- Systemd user services ---
log "Creating systemd user services..."
USER_SYSTEMD_DIR="$GAMING_HOME/.config/systemd/user"
mkdir -p "$USER_SYSTEMD_DIR"

cat > "$USER_SYSTEMD_DIR/pipewire.service" << EOF
[Unit]
Description=PipeWire Audio
After=basic.target

[Service]
ExecStart=/usr/bin/pipewire
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

cat > "$USER_SYSTEMD_DIR/wireplumber.service" << EOF
[Unit]
Description=WirePlumber Session Manager
Requires=pipewire.service
After=pipewire.service

[Service]
ExecStart=/usr/bin/wireplumber
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

cat > "$USER_SYSTEMD_DIR/gaming.service" << EOF
[Unit]
Description=Gamescope + Steam Big Picture
After=pipewire.service
Wants=pipewire.service

[Service]
ExecStart=$GAMING_HOME/start-gaming.sh
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

cat > "$USER_SYSTEMD_DIR/sunshine.service" << EOF
[Unit]
Description=Sunshine Game Stream Host
After=gaming.service
Wants=gaming.service

[Service]
ExecStart=/usr/bin/sunshine
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

chown -R "$GAMING_USER:$GAMING_USER" "$USER_SYSTEMD_DIR"

# --- Enable services ---
SYSTEMD_STATE=$(systemctl is-system-running 2>/dev/null || true)
if [[ "$SYSTEMD_STATE" == "running" || "$SYSTEMD_STATE" == "degraded" ]]; then
    log "Enabling user services..."
    sudo -u "$GAMING_USER" \
        XDG_RUNTIME_DIR="/run/user/$GAMING_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$GAMING_UID/bus" \
        systemctl --user daemon-reload

    for svc in pipewire wireplumber gaming sunshine; do
        sudo -u "$GAMING_USER" \
            XDG_RUNTIME_DIR="/run/user/$GAMING_UID" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$GAMING_UID/bus" \
            systemctl --user enable "$svc.service"
    done
else
    warn "Systemd state is '${SYSTEMD_STATE}' — skipping service enable."
    warn "After resolving systemd, run:"
    warn "  sudo -u $GAMING_USER XDG_RUNTIME_DIR=/run/user/$GAMING_UID systemctl --user daemon-reload"
    warn "  sudo -u $GAMING_USER XDG_RUNTIME_DIR=/run/user/$GAMING_UID systemctl --user enable pipewire wireplumber gaming sunshine"
fi

# --- Cleanup ---
log "Cleaning up build artifacts..."
rm -rf "$GAMING_HOME/.cache/yay"
pacman -Rns --noconfirm go 2>/dev/null || true
pacman -Rns --noconfirm base-devel git 2>/dev/null || true
pacman -Sc --noconfirm

FREE_AFTER=$(df / --output=avail | tail -1 | awk '{print int($1/1024/1024)}')
log "Cleanup complete. Disk free: ${FREE_AFTER}GB"

# --- Done ---
log "Setup complete!"
echo ""
echo "============================================================"
echo " Capsule setup complete"
echo "============================================================"
echo " 1. Reboot the container"
echo " 2. Open https://<container-ip>:${SUNSHINE_PORT} for Sunshine UI"
echo " 3. Pair Moonlight with Sunshine"
echo " 4. Log in to Steam when it appears"
echo ""
echo " Check service status after reboot:"
echo "   sudo -u $GAMING_USER XDG_RUNTIME_DIR=/run/user/$GAMING_UID systemctl --user status sunshine"
echo "   sudo -u $GAMING_USER XDG_RUNTIME_DIR=/run/user/$GAMING_UID systemctl --user status gaming"
echo "============================================================"
