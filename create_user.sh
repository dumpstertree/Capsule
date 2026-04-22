#!/bin/bash
set -e

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

echo "Creating user: $USERNAME"
useradd -m -s /bin/bash "$USERNAME"

echo "Setting password for $USERNAME"
passwd -d "$USERNAME"

echo "Adding $USERNAME to required groups"
for group in video render input audio; do
    if getent group "$group" > /dev/null; then
        usermod -aG "$group" "$USERNAME"
        echo "  Added to $group"
    else
        echo "  Warning: group '$group' does not exist, skipping"
    fi
done

mkdir -p "$USER_HOME/.config/sunshine"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.config"

echo "Enabling linger for $USERNAME (keeps user session alive without login)"
loginctl enable-linger "$USERNAME"

echo ""
echo "Done. Verify with:"
echo "  id $USERNAME"
