USERNAME="$1"
USER_HOME="/home/$USERNAME"

mkdir -p "$USER_HOME/.steam/root/compatibilitytools.d"

cd /tmp

LATEST=$(curl -s https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest \
  | grep browser_download_url \
  | grep "$(uname -m).tar.gz\"" \
  | cut -d '"' -f 4)

wget -O proton-ge.tar.gz "$LATEST"

tar -xf proton-ge.tar.gz -C "$USER_HOME/.steam/root/compatibilitytools.d/"
rm -f proton-ge.tar.gz
