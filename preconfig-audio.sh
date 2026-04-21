# enable all audio servicess
systemctl --user enable pipewire.service
systemctl --user enable wireplumber.service
systemctl --user enable pipewire-pulse.service
#systemctl --user enable pipewire-pulse.socket
#systemctl --user enable pipewire.socket
