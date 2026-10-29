#!/bin/bash
# =============================================================================
# Steam library drives + non-Steam game imports for one capsule user.
#
#   capsule-import.sh add-library    <user> <path>
#   capsule-import.sh remove-library <user> <path>
#   capsule-import.sh list-libraries <user>
#   capsule-import.sh add-game       <user> <exe> [--name N] [--startdir D]
#                                    [--sgdb-id ID] [--launch-options S] [--no-art]
#   capsule-import.sh remove-game    <user> <name|appid>
#   capsule-import.sh list-games     <user>
#
# Runs as root. Around every WRITE operation Steam is stopped for that user
# only (Steam rewrites its config files on exit and would clobber our edits)
# and relaunched afterwards when the capsule's stream service was active.
#
# Library paths must exist INSIDE the container (mount the drive into the LXC
# first — Proxmox: bind mount in /etc/pve/lxc/<ct>.conf).
#
# STEAMGRIDDB_API_KEY in /etc/capsule/config enables name matching and
# artwork (capsule/portrait/hero/logo/icon). Empty key = plain imports.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

capsule_require_root

usage() {
    sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-1}"
}

SUBCMD="${1:-}"
USERNAME="${2:-}"

case "$SUBCMD" in
    add-library|remove-library|list-libraries|add-game|remove-game|list-games) ;;
    *) usage ;;
esac
[ -n "$USERNAME" ] || usage
capsule_valid_username "$USERNAME" || error "Invalid username '$USERNAME'"

USER_HOME="$(capsule_user_home "$USERNAME")"

WRITE_OPS=" add-library remove-library add-game remove-game "
WAS_STREAMING=0

if [[ "$WRITE_OPS" == *" $SUBCMD "* ]]; then
    if capsule_run_user "$USERNAME" -- \
            systemctl --user is-active --quiet "capsule@$USERNAME.service"; then
        WAS_STREAMING=1
    fi
    log "Stopping Steam for $USERNAME (Steam rewrites its config on exit)"
    pkill -u "$USERNAME" -x steam || true
    pkill -u "$USERNAME" steamwebhelper || true
    sleep 2
fi

VENV_DIR="${CAPSULE_IMPORT_VENV:-/opt/capsule-steam-venv}"
if [ ! -x "$VENV_DIR/bin/python" ]; then
    log "Creating python virtual environment ($VENV_DIR)"
    pacman -Sy --noconfirm --needed python python-virtualenv >/dev/null
    python -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/python" -c "import vdf, requests" 2>/dev/null || \
    "$VENV_DIR/bin/pip" install -q --upgrade pip vdf requests

CAPSULE_PERSISTENT_DATA_PATH="$(capsule_conf_get PERSISTENT_DATA_PATH "")"
CAPSULE_SGDB_KEY="$(capsule_conf_get STEAMGRIDDB_API_KEY "")"
export CAPSULE_PERSISTENT_DATA_PATH CAPSULE_SGDB_KEY

"$VENV_DIR/bin/python" "$SCRIPT_DIR/capsule-import.py" "$SUBCMD" "$USERNAME" "${@:3}"

if [[ "$WRITE_OPS" == *" $SUBCMD "* ]] && [ "$WAS_STREAMING" -eq 1 ]; then
    INDEX="$(capsule_read_user_index "$USER_HOME/capsule.config" 2>/dev/null || echo "")"
    if [ -n "$INDEX" ]; then
        log "Relaunching Steam for $USERNAME on display :$INDEX"
        capsule_run_user "$USERNAME" -- env DISPLAY=":$INDEX" \
            systemd-run --user --quiet --no-block \
                --unit "capsule-steam-import-$$" \
                steam -bigpicture -fulldesktopres \
            || warn "Steam relaunch failed — capsulectl restart $USERNAME"
    fi
fi
