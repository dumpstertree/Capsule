echo "Installing User"
sh /Capsule/create_user.sh

echo "Installing All Dependencies"
sh /Capsule/install_dependencies2.sh

echo "Setting up Sunshine"
sh /Capsule/preconfig-sunshine.sh

echo "Setting up Audio"
sh /Capsule/preconfig-audio.sh

echo "Setting up XOrg"
sh /Capsule/preconfig-xorg.sh

echo "Setting up Capsule"
sh /Capsule/preconfig-capsule.sh

echo "Rebooting"
reboot
