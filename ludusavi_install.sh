#!/usr/bin/env bash
# ludusavi-install.sh — Install Ludusavi on Arch Linux via yay
 
set -euo pipefail
 
# ── Install yay if not already present ───────────────────────────────────────
if ! command -v yay &>/dev/null; then
  echo "==> yay not found, installing yay..."
 
  if ! command -v git &>/dev/null; then
    echo "  Installing git via pacman..."
    sudo pacman -S --needed --noconfirm git
  fi
 
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  chown gamer "$TMP_DIR"
 
  sudo -u gamer git clone https://aur.archlinux.org/yay.git "$TMP_DIR/yay"
  (cd "$TMP_DIR/yay" && sudo -u gamer makepkg -si --noconfirm)
  echo "==> yay installed."
fi
 
# ── Install Ludusavi ─────────────────────────────────────────────────────────
echo "==> Installing ludusavi via yay..."
sudo -u gamer yay -S --needed --noconfirm ludusavi
echo "==> Ludusavi installed: $(ludusavi --version)"
 
