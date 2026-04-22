#echo "Installing User"
#sh /Capsule/create_user.sh

#echo "Installing All Dependencies"
#sh /Capsule/install_dependencies2.sh

#echo "Setting up Sunshine"
#sh /Capsule/preconfig-sunshine.sh

#echo "Setting up XOrg"
#sh /Capsule/preconfig-xorg.sh

#echo "Setting up Capsule"
#sh /Capsule/preconfig-capsule.sh

#echo "Setting up Audio"
#sh /Capsule/preconfig-audio.sh

#echo "Rebooting"
#reboot

#!/bin/bash
set -e

echo "Open how many Capsules?"
read -r USER_COUNT

if ! [[ "$USER_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: please enter a valid number greater than 0" >&2
    exit 1
fi


echo "Installing All Dependencies"
sh /Capsule/install_dependencies2.sh

echo "Installing Users"
for i in $(seq 1 "$USER_COUNT"); do

    echo "Creating user $i of $USER_COUNT"
    sh /Capsule/create_user.sh "gamer$i"

    echo "Setting up Sunshine for user $i of $USER_COUNT"
    sh /Capsule/preconfig-sunshine.sh
    
    echo "Setting up Sunshine for user $i of $USER_COUNT"
    sh /Capsule/preconfig-capsule.sh
    
    echo "Setting up Audio for user $i of $USER_COUNT"
    sh /Capsule/preconfig-audio.sh

    echo "Setting up XOrg"
    sh /Capsule/preconfig-xorg.sh
done

echo "Rebooting"
reboot

