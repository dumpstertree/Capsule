#!/bin/bash
# Bootstrap installer: clones/updates /Capsule and runs setup.
#   pacman-key --init && pacman -Syu --noconfirm curl git && \
#   bash <(curl -fsSL https://raw.githubusercontent.com/dumpstertree/Capsule/refs/heads/main/install.sh)
set -euo pipefail

REPO_URL="https://github.com/dumpstertree/Capsule.git"
INSTALL_DIR="/Capsule"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root"
    exit 1
fi

command -v git >/dev/null || pacman -Sy --noconfirm git

if [ -d "$INSTALL_DIR/.git" ]; then
    echo "Updating existing Capsule checkout..."
    git -C "$INSTALL_DIR" pull --ff-only || warn "git pull failed — continuing with existing copy"
elif [ -e "$INSTALL_DIR" ]; then
    error "$INSTALL_DIR exists but is not a git checkout — move it aside first"
else
    echo "Cloning Capsule..."
    git clone "$REPO_URL" "$INSTALL_DIR"
fi

chmod -R a+rX,go-w "$INSTALL_DIR"
chmod -R +x "$INSTALL_DIR"/*.sh "$INSTALL_DIR/lib" "$INSTALL_DIR/capsulectl" 2>/dev/null || true

exec "$INSTALL_DIR/open_capsule.sh"
