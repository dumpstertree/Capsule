
#!/usr/bin/env bash
# ludusavi-install.sh — Install Ludusavi by downloading the prebuilt binary from GitHub

set -euo pipefail

INSTALL_DIR="/usr/local/bin"
API_URL="https://api.github.com/repos/mtkennerly/ludusavi/releases/latest"

if ! command -v curl &>/dev/null; then
  echo "ERROR: curl is required. Install it with: pacman -S curl" >&2
  exit 1
fi

echo "==> Fetching latest Ludusavi release info..."
DOWNLOAD_URL=$(curl -fsSL "$API_URL" \
  | grep -o '"browser_download_url": *"[^"]*linux[^"]*\.tar\.gz"' \
  | grep -o 'https://[^"]*')

if [[ -z "$DOWNLOAD_URL" ]]; then
  echo "ERROR: Could not find a Linux release asset." >&2
  exit 1
fi

echo "==> Downloading $DOWNLOAD_URL"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fsSL "$DOWNLOAD_URL" -o "$TMP_DIR/ludusavi.tar.gz"
tar -xzf "$TMP_DIR/ludusavi.tar.gz" -C "$TMP_DIR"

install -m 755 "$TMP_DIR/ludusavi" "$INSTALL_DIR/ludusavi"

echo "==> Ludusavi installed: $(ludusavi --version)"
