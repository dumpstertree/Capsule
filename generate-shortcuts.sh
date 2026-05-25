#!/bin/bash
set -e

###############################################################################
# CONFIG
###############################################################################

VENV_DIR="/opt/capsule-steam-venv"
CONFIG_FILE="/Capsule/capsule-host.config"
PYTHON_SCRIPT="/Capsule/generate-shortcuts.py"

###############################################################################
# VALIDATION
###############################################################################

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Must be run as root"
    exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Missing config:"
    echo "  $CONFIG_FILE"
    exit 1
fi

###############################################################################
# READ CONFIG
###############################################################################

GPU_INDEX="$(sed -n '1p' "$CONFIG_FILE" | xargs)"
GAMES_PATH="$(sed -n '2p' "$CONFIG_FILE" | xargs)"
PERSISTENT_DATA_PATH="$(sed -n '3p' "$CONFIG_FILE" | xargs)"
WHITELISTED_SUNSHINE_IPS="$(sed -n '4p' "$CONFIG_FILE" | xargs)"
STEAMGRIDDB_API_KEY="$(sed -n '5p' "$CONFIG_FILE" | xargs)"

###############################################################################
# VALIDATE REQUIRED VALUES
###############################################################################

if [[ -z "$GAMES_PATH" ]]; then
    echo "Games path missing from config"
    exit 1
fi

if [[ -z "$STEAMGRIDDB_API_KEY" ]]; then
    echo "SteamGridDB API key missing from config"
    exit 1
fi

###############################################################################
# INSTALL DEPENDENCIES
###############################################################################

echo "Installing dependencies..."

pacman -Sy --noconfirm \
    python \
    python-pip \
    python-virtualenv \
    git

###############################################################################
# CREATE VENV
###############################################################################

if [[ ! -d "$VENV_DIR" ]]; then
    echo "Creating virtual environment..."
    python -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"

###############################################################################
# INSTALL PYTHON PACKAGES
###############################################################################

echo "Installing Python packages..."

pip install --upgrade pip

pip install \
    vdf \
    requests \
    rapidfuzz \
    pillow

###############################################################################
# STOP STEAM
###############################################################################

echo "Stopping Steam..."

pkill steam || true
pkill steamwebhelper || true

sleep 3

###############################################################################
# RUN GENERATOR
###############################################################################

echo "Running generator..."

"$VENV_DIR/bin/python" \
    "$PYTHON_SCRIPT" \
    "$GAMES_PATH" \
    "$PERSISTENT_DATA_PATH" \
    "$STEAMGRIDDB_API_KEY"

###############################################################################
# DONE
###############################################################################

echo ""
echo "Generation Done"
