# make sure systemd can call any script in the repo
sudo chmod -R +x /Capsule

# copy example service into folder
cp /Capsule/example-capsule.service /etc/systemd/system/capsule.service

# update the daemon list with newly created 
systemctl daemon-reload

# enable the service for next time
systemctl enable capsule.service

# start the service now
systemctl start capsule.service
