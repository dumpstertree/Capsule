#!/bin/bash
set -e

if [ -z "$1" ]; then
    echo "Error: username argument required" >&2
    echo "Usage: $0 <username> <display_index>" >&2
    exit 1
fi

if [ -z "$2" ]; then
    echo "Error: display index argument required" >&2
    echo "Usage: $0 <username> <display_index>" >&2
    exit 1
fi

USERNAME="$1"
INDEX="$2"
USER_HOME="/home/$USERNAME"
CONFIG_FILE="$USER_HOME/capsule.config"

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

echo "Creating capsule config"
echo "$INDEX" > "$CONFIG_FILE"

mkdir -p "$USER_HOME/.config/sunshine"

chown "$USERNAME:$USERNAME" "$CONFIG_FILE"
chown -R "$USERNAME:$USERNAME" "$USER_HOME/.config"

echo "Enabling linger for $USERNAME (keeps user session alive without login)"
loginctl enable-linger "$USERNAME"

echo ""
echo "Done. Verify with:"
echo "  id $USERNAME"
echo "  cat $CONFIG_FILE"
