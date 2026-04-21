/usr/lib/systemd/systemd-udevd --daemon 2>/dev/null || true
sleep 1
udevadm trigger --subsystem-match=input
udevadm settle

# start dummy Xorg on :0 this needs to not be hardcoded
Xorg :0 -config ./xorg.conf -noreset -novtswitch &
sleep 2

