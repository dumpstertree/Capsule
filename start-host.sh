#!/bin/bash
set -e

/usr/lib/systemd/systemd-udevd --daemon 2>/dev/null || true
sleep 1

udevadm trigger --subsystem-match=input
udevadm settle

XORG_CONFIG="./xorg.conf"

echo "Searching for capsule users..."

for HOME_DIR in /home/*; do
    if [[ ! -d "$HOME_DIR" ]]; then
        continue
    fi

    USERNAME="$(basename "$HOME_DIR")"
    CONFIG_FILE="$HOME_DIR/capsule.config"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Skipping $USERNAME (no capsule.config)"
        continue
    fi

    INDEX="$(head -n 1 "$CONFIG_FILE" | xargs)"

    if [[ -z "$INDEX" ]]; then
        echo "Skipping $USERNAME (empty display index)"
        continue
    fi

    DISPLAY_NUM=":$INDEX"

    echo "Starting Xorg for $USERNAME on display $DISPLAY_NUM"

    Xorg "$DISPLAY_NUM" \
        -config "$XORG_CONFIG" \
        -noreset \
        -novtswitch \
        > "/tmp/xorg-$USERNAME.log" 2>&1 &

    sleep 2
done

echo "All configured displays started."
