# copy the service to systemd folder
cp /Capsule/example-capsule-host.service /etc/systemd/system/capsule-host.service

# enable now and in the future
systemctl enable capsule-host.service
