# enable all audio servicess
runuser -u gamer -- systemctl --user enable pipewire.service
runuser -u gamer -- systemctl --user enable wireplumber.service
runuser -u gamer -- systemctl --user enable pipewire-pulse.service
#systemctl --user enable pipewire-pulse.socket
#systemctl --user enable pipewire.socket
