# enable all audio servicess
#runuser -u gamer -- systemctl --user enable pipewire.service
#runuser -u gamer -- systemctl --user enable wireplumber.service
#runuser -u gamer -- systemctl --user enable pipewire-pulse.service
#systemctl --user enable pipewire-pulse.socket
#systemctl --user enable pipewire.socket
# As root inside the container
mkdir -p /home/gamer/.config/systemd/user/default.target.wants
ln -sf /usr/lib/systemd/user/pipewire.service \
    /home/gamer/.config/systemd/user/default.target.wants/pipewire.service
ln -sf /usr/lib/systemd/user/pipewire-pulse.service \
    /home/gamer/.config/systemd/user/default.target.wants/pipewire-pulse.service
ln -sf /usr/lib/systemd/user/wireplumber.service \
    /home/gamer/.config/systemd/user/default.target.wants/wireplumber.service
chown -R gamer:gamer /home/gamer/.config
