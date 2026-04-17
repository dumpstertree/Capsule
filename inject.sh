echo "CHECKING DRI HERE"
ls -l /dev/dri
glxinfo | grep renderer

# start app
steam &

# small delay to ensure something is rendering
sleep 2
