# make sure systemd can call any script in the repo
chmod -R 777 /Capsule

# copy example service into folder
#cp /Capsule/example-capsule.service /etc/systemd/system/capsule.service

# update the daemon list with newly created 
#systemctl daemon-reload

# enable the service for next time
#systemctl enable capsule.service

# start the service now
#systemctl start capsule.service

# create the service target directory
mkdir -p /home/gamer/.config/systemd/user/default.target.wants
chown -R gamer:gamer /home/gamer/.config/systemd

#copy example host service to target
cp /Capsule/example-capsule-host.service /etc/systemd/system/capsule-host.service

# enable now and in the future
systemctl enable capsule-host.service

#copy example user service to target
cp /Capsule/example-capsule.service /usr/lib/systemd/user/capsule.service

# enable now and in the future
runuser -u gamer -- systemctl --user enable capsule.service


