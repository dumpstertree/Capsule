echo "Initializing pacman key"
pacman-key --init

echo "Adding sunshine repo to pacman.conf"
cat "[lizardbyte]
SigLevel = Optional
Server = https://github.com/LizardByte/pacman-repo/releases/latest/download" >> /etc/pacman.conf

echo "Installig all dependencies"
pacman -Syu \
    bootd \
    sunshine \
    xf86-video-dummy \
    xf86-input-libinput \
    xorg-server \
    xorg-xinput \
    xorg-xhost \
    dbus
