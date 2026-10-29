#!/bin/bash
# Bootstrap installer: clones/updates /Capsule and runs setup.
#   pacman-key --init && pacman -Syu --noconfirm curl git && \
#   bash <(curl -fsSL https://raw.githubusercontent.com/dumpstertree/Capsule/refs/heads/main/install.sh)
#
# Testing a feature branch: set CAPSULE_BRANCH (branch of the clone; the
# install.sh you curl may come from any ref — use the same one).
#   CAPSULE_BRANCH=feature/sway-capsule1 bash <(curl -fsSL .../feature/sway-capsule1/install.sh)
set -euo pipefail

REPO_URL="https://github.com/dumpstertree/Capsule.git"
INSTALL_DIR="/Capsule"
CAPSULE_BRANCH="${CAPSULE_BRANCH:-}"

# lib/common.sh is only sourced by open_capsule.sh (at the end) — define the
# two helpers this bootstrap needs locally (they were missing: the error
# paths below used to die with "warn: command not found").
warn()  { echo "[WARN] $1" >&2; }
error() { echo "[ERROR] $1" >&2; exit 1; }

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Run as root"
    exit 1
fi

command -v git >/dev/null || pacman -Sy --noconfirm git

if [ -d "$INSTALL_DIR/.git" ]; then
    echo "Updating existing Capsule checkout..."
    if [ -n "$CAPSULE_BRANCH" ]; then
        git -C "$INSTALL_DIR" fetch origin "$CAPSULE_BRANCH" &&
            git -C "$INSTALL_DIR" checkout "$CAPSULE_BRANCH" &&
            git -C "$INSTALL_DIR" pull --ff-only || warn "branch switch failed — continuing with existing copy"
    else
        git -C "$INSTALL_DIR" pull --ff-only || warn "git pull failed — continuing with existing copy"
    fi
elif [ -e "$INSTALL_DIR" ]; then
    error "$INSTALL_DIR exists but is not a git checkout — move it aside first"
else
    if [ -n "$CAPSULE_BRANCH" ]; then
        echo "Cloning Capsule ($CAPSULE_BRANCH)..."
        git clone --branch "$CAPSULE_BRANCH" "$REPO_URL" "$INSTALL_DIR"
    else
        echo "Cloning Capsule..."
        git clone "$REPO_URL" "$INSTALL_DIR"
    fi
fi

chmod -R a+rX,go-w "$INSTALL_DIR"
chmod -R +x "$INSTALL_DIR"/*.sh "$INSTALL_DIR/lib" "$INSTALL_DIR/capsulectl" 2>/dev/null || true

exec "$INSTALL_DIR/open_capsule.sh"
