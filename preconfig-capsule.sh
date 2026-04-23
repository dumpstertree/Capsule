# make sure systemd can call any script in the repo
#chmod -R 777 /Capsule

# copy example service into folder
#cp /Capsule/example-capsule.service /etc/systemd/system/capsule.service

# update the daemon list with newly created 
#systemctl daemon-reload

# enable the service for next time
#systemctl enable capsule.service

# start the service now
#systemctl start capsule.service

# create the service target directory
#mkdir -p /home/gamer/.config/systemd/user/default.target.wants
#copy example host service to target
#cp /Capsule/example-capsule-host.service /etc/systemd/system/capsule-host.service

# enable now and in the future
#systemctl enable capsule-host.service

# --- Helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[SETUP]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info()  { echo -e "${BLUE}[INFO]${NC} $1"; }

if [ -z "$1" ]; then
    echo "Error: username argument required" >&2
    echo "Usage: $0 <username>" >&2
    exit 1
fi

USERNAME="$1"
INDEX="$2"
USER_HOME="/home/$USERNAME"

if ! [[ "$INDEX" =~ ^[0-9]+$ ]]; then
    error "Index must be a non-negative integer"
fi

if [ "$(id -u)" -ne 0 ]; then
    error "Must be run as root"
fi

#copy example user service to target
cp /Capsule/example-capsule.service /usr/lib/systemd/user/capsule.service

sed -i "s|ExecStart=.*start-stream3.sh.*|ExecStart=/Capsule/start-stream3.sh $INDEX|" /usr/lib/systemd/user/capsule.service

# enable now and in the future
mkdir -p $USER_HOME/.config/systemd/user/default.target.wants
ln -sf /usr/lib/systemd/user/capsule.service $USER_HOME/.config/systemd/user/default.target.wants/capsule.service
chown -R $USERNAME:$USERNAME $USER_HOME/.config

