echo "Installing User"
sh /Capsule/create_user.sh

echo "Installing All Dependencies"
sh /Capsule/install_dependencies2.sh

echo "Setting up Sunshine"
sh /Capsule/preconfigure-sunshine.sh

echo "Setting up XOrg"
sh /Capsule/preconfigure-xorg.sh

echo "Setting up Capsule"
sh /Capsule/perconfigure-capsule.sh

echo "Start Streaming"
systemctl start capsule.service
