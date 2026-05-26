USERNAME="$1"
USER_HOME="/home/$USERNAME"

mkdir -p $USER_HOME/.steam/root/compatibilitytools.d

cd /tmp

LATEST=$(curl -s https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest | grep browser_download_url | grep '\.tar\.gz"' | cut -d '"' -f 4)

wget "$LATEST"

tar -xf GE-Proton*.tar.gz -C $USER_HOME/.steam/root/compatibilitytools.d/
