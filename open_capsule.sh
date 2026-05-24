#!/bin/bash
set -e

CONFIG_FILE="/capsule-host.config"

echo "Open how many Capsules?"
read -r USER_COUNT

if ! [[ "$USER_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: please enter a valid number greater than 0" >&2
    exit 1
fi

# used for setting up our xorg instance
echo "GPU Index?"
read -r GPU_INDEX

# where to read games from - only windows are currently supported
echo "Windows Games path?"
read -r GAMES_PATH

# used to save any data to be reused between instances
echo "Where to save save backups and game metadata"
read -r PERSISTENT_DATA_PATH

# used in sunshine for access to the webui
echo "Whitelisted sunshine IPs"
read -r WHITELISTED_SUNSHINE_IPS

# used for collecting metadata
echo "SteamGridDB API Key?"
read -r STEAMGRIDDB_API_KEY

# create the config file for the host
cat > "$CONFIG_FILE" <<EOF
$GPU_INDEX
$GAMES_PATH
$PERSISTENT_DATA_PATH
$WHITELISTED_SUNSHINE_IPS
$STEAMGRIDDB_API_KEY
EOF

# allow all files access to capsule
chmod -R 777 /Capsule

echo "Installing All Dependencies"
sh /Capsule/install_dependencies2.sh

echo "Setting up XOrg on Host"
sh /Capsule/preconfig-xorg.sh

echo "Setting up Capsule on Host"
sh /Capsule/preconfig-capsule-host.sh
    
echo "Installing Users"
for i in $(seq 0 $(( USER_COUNT - 1 ))); do

    echo "Creating user $i of $USER_COUNT"
    sh /Capsule/create_user.sh "gamer$i" "$i"

    echo "Setting up Sunshine for user $i of $USER_COUNT"
    sh /Capsule/preconfig-sunshine.sh "gamer$i" "$i"

    echo "Setting up Audio for user $i of $USER_COUNT"
    sh /Capsule/preconfig-audio.sh "gamer$i"
    
    echo "Setting up Sunshine for user $i of $USER_COUNT"
    sh /Capsule/preconfig-capsule.sh "gamer$i" "$i"
done

echo "Completed!"
echo "First launch may take a while to appear on Moonlight"
echo "Services will start after reboot"

reboot

