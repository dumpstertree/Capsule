#!/bin/bash
# =============================================================================
# Capsule shared helpers
#
# Source this file from every Capsule script:
#   source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/common.sh"
# (adjust the relative path when sourcing from a subdirectory)
#
# Provides: logging, root checks, /etc/capsule/config accessors, input
# validation, directory creation helpers and per-user systemd helpers.
# =============================================================================

# --- Colors / logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[SETUP]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
info()  { echo -e "${BLUE}[INFO]${NC} $1"; }

capsule_require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "Must be run as root"
    fi
}

# --- Configuration -----------------------------------------------------------
# Key=value config written by open_capsule.sh, read by everything else.
# Format: KEY=value, one per line, '#' comments allowed.
CAPSULE_DIR="${CAPSULE_DIR:-/etc/capsule}"
CAPSULE_CONFIG="${CAPSULE_CONFIG:-$CAPSULE_DIR/config}"

# Keys (defaults in parentheses):
#   GPU_INDEX                  (none, required for xorg)
#   GAMES_PATH                 (none, required)
#   PERSISTENT_DATA_PATH       (none, required)
#   SUNSHINE_ALLOWED_ORIGINS   (none, required)  comma separated https:// origins
#   STEAMGRIDDB_API_KEY        (empty allowed)
#   CAPSULE_GPU_DISPLAYS       (empty allowed) display index (ONE) that runs
#                              a GPU-backed X server (hardware GLX); all other
#                              displays use the dummy driver. Vulkan is
#                              hardware everywhere regardless.
#   CAPSULE_KMSDEV             (/dev/dri/card1) card node for the GPU-backed
#                              display; resolve via /dev/dri/by-path on host.
#   SUNSHINE_BASE_PORT         (47989)
#   SUNSHINE_PORT_STEP         (1000)
#   CAPSULE_USER_PREFIX        (capsule)
#   LLM_MODEL                  (qwen3-coder:30b) default model for llm capsules
#   LLM_API_PORT               (11434)  Ollama / OpenAI-compatible API port
#   LLM_WEB_PORT               (8080)   Open WebUI port
#   LLM_MODELS_PATH            ($HOME/.ollama/models per llm capsule user)
#   LLM_CONTEXT_LENGTH         (8192)   context tokens served per request
#   LLM_KEEP_ALIVE             (240m)   how long the model stays VRAM-resident
#   LLM_HSA_OVERRIDE           (empty)  ROCm gfx target override — leave
#                              EMPTY for gfx1030 (RX 6800, native since ROCm
#                              5.3); setting it confuses Ollama's GPU probe
#   LLM_HIP_VISIBLE_DEVICES    (empty)  pin ROCm to one GPU when several are
#                              visible (e.g. hide an iGPU), ROCm index list
#   LLM_VULKAN                 (empty)  "1" = force Ollama's Vulkan backend
#                              (fallback when /dev/kfd is unavailable)
#   CAPSULE_RENDER_NODE        (/dev/dri/renderD128) render node sway-type
#                              capsules composite on (resolve via
#                              /dev/dri/by-path; must be the RX 6800's)
#   SWAY_RESOLUTION            (1920x1080) virtual output size (sway capsule)
#   SWAY_REFRESH               (60)      virtual output refresh (Hz)
#   SWAY_XDISPLAY              (:10)     Xwayland display inside sway sessions
#                              (must not collide with real Xorg :0..:N)
#
# Port layout per capsule index N (verified against Sunshine source):
#   base      = SUNSHINE_BASE_PORT + N * SUNSHINE_PORT_STEP
#   GameStream HTTPS  = base - 5   (47984 for index 0)
#   GameStream HTTP   = base       (47989)
#   Web UI (HTTPS!)   = base + 1   (47990)  <- the port you browse to
#   RTSP / video etc  = base + 2..+21

capsule_conf_get() {
    # Usage: capsule_conf_get KEY [default]
    local key="$1" default="${2:-}" value=""
    if [ -f "$CAPSULE_CONFIG" ]; then
        value="$(grep -m1 -E "^${key}=" "$CAPSULE_CONFIG" 2>/dev/null | cut -d= -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    fi
    if [ -z "$value" ]; then
        value="$default"
    fi
    printf '%s' "$value"
}

capsule_conf_require() {
    # Usage: capsule_conf_require KEY
    local key="$1" value
    value="$(capsule_conf_get "$key")"
    if [ -z "$value" ]; then
        error "Missing required key '$key' in $CAPSULE_CONFIG — re-run open_capsule.sh"
    fi
    printf '%s' "$value"
}

capsule_sunshine_base_port() { capsule_conf_get SUNSHINE_BASE_PORT 47989; }
capsule_sunshine_port_step() { capsule_conf_get SUNSHINE_PORT_STEP 1000; }
capsule_user_prefix()        { capsule_conf_get CAPSULE_USER_PREFIX capsule; }

capsule_sunshine_ui_port() {
    # Web UI (HTTPS) port for capsule index $1
    local index="$1"
    echo $(( $(capsule_sunshine_base_port) + index * $(capsule_sunshine_port_step) + 1 ))
}

# --- Validation helpers ------------------------------------------------------

capsule_valid_username() {
    # Only lowercase letters, digits, dashes; must start with a letter. Max 31.
    [[ "$1" =~ ^[a-z][a-z0-9-]{0,30}$ ]]
}

capsule_valid_index() {
    [[ "$1" =~ ^[0-9]{1,3}$ ]]
}

capsule_valid_abspath() {
    # Absolute path, no parent traversal.
    local p="$1"
    [[ "$p" == /* ]] && [[ "$p" != *".."* ]]
}

capsule_normalize_origins() {
    # Usage: capsule_normalize_origins "192.168.1.5,https://some.host"
    # Prints a canonical comma-separated list of https:// origins
    # (scheme added when missing, http:// upgraded, invalid entries rejected).
    # Sunshine requires: https:// prefix, no trailing slash, no path.
    local input="${1// /}" out="" entry
    IFS=',' read -ra entries <<< "$input"
    for entry in "${entries[@]}"; do
        [ -z "$entry" ] && continue
        # add scheme when missing
        if [[ "$entry" != *"://"* ]]; then
            entry="https://$entry"
        fi
        # upgrade plain http (Sunshine rejects non-https origins for CSRF)
        if [[ "$entry" == http://* ]]; then
            warn "Upgrading '$entry' to https:// (Sunshine only accepts https origins)"
            entry="https://${entry#http://}"
        fi
        # strip trailing slashes
        entry="${entry%/}"
        if [[ ! "$entry" =~ ^https://[A-Za-z0-9._:-]+$ ]]; then
            error "Invalid origin '$entry' — expected hostname or IP (optionally with :port)"
        fi
        if [ -z "$out" ]; then out="$entry"; else out="$out,$entry"; fi
    done
    [ -z "$out" ] && error "No valid origins supplied"
    printf '%s' "$out"
}

# --- Filesystem helpers ------------------------------------------------------

capsule_ensure_dir() {
    # Usage: capsule_ensure_dir <path> [owner] [mode]
    # owner: "user" or "user:group", empty keeps root:root
    local path="$1" owner="${2:-}" mode="${3:-0755}"
    if [ ! -d "$path" ]; then
        mkdir -p "$path" || return 1
        chmod "$mode" "$path"
        if [ -n "$owner" ]; then
            chown "$owner" "$path"
        fi
    fi
}

capsule_user_home() {
    getent passwd "$1" | cut -d: -f6
}

# --- Per-user systemd helpers -------------------------------------------------

capsule_user_uid() { id -u "$1" 2>/dev/null; }

capsule_ensure_user_manager() {
    # Make sure the systemd user manager (and /run/user/<uid>) exists for $1,
    # so `systemctl --user` works with no interactive login. Requires root.
    local user="$1" uid
    uid="$(capsule_user_uid "$user")" || error "Unknown user: $user"
    if [ ! -d "/run/user/$uid" ]; then
        systemctl start "user@$uid.service" 2>/dev/null || \
            error "Could not start user manager for $user (is linger enabled? loginctl enable-linger $user)"
    fi
}

capsule_run_user() {
    # Usage: capsule_run_user <user> -- <command...>
    # Runs a command as $user with a usable systemd --user environment.
    local user="$1"; shift
    [ "${1:-}" = "--" ] && shift
    local uid home
    uid="$(capsule_user_uid "$user")" || error "Unknown user: $user"
    home="$(capsule_user_home "$user")"
    capsule_ensure_user_manager "$user"
    runuser -u "$user" -- env \
        HOME="$home" \
        USER="$user" \
        LOGNAME="$user" \
        XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        "$@"
}

# --- Runtime state helpers ----------------------------------------------------

capsule_display_up() {
    # Is X display :$1 up?
    [ -S "/tmp/.X11-unix/X$1" ]
}

capsule_tcp_listening() {
    # Is TCP port $1 in LISTEN state?
    ss -Hltn "sport = :$1" 2>/dev/null | grep -q .
}

capsule_read_user_index() {
    # Read the capsule index from ~/.capsule-config style file: $HOME/capsule.config line 1
    local file="$1" index=""
    [ -f "$file" ] || return 1
    index="$(head -n1 "$file" | tr -d '[:space:]')"
    capsule_valid_index "$index" || return 1
    printf '%s' "$index"
}

capsule_read_user_type() {
    # Capsule role from an optional "TYPE=llm" line in $HOME/capsule.config.
    # Line 1 stays the display index; absent/unknown TYPE means "game", so
    # every config written before llm capsules keeps working untouched.
    # Known types: game | llm | sway (sway = Wayland game capsule, no Xorg).
    local file="$1" type=""
    if [ -f "$file" ]; then
        type="$(grep -m1 '^TYPE=' "$file" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')"
    fi
    [ -n "$type" ] || type="game"
    printf '%s' "$type"
}

capsule_game_bootstrap() {
    # Usage: capsule_game_bootstrap <script_dir> <username> <user_home>
    # Everything both session flavors (X and sway) do before the app starts:
    # save sync (best effort) + GAMES_PATH auto-import with SteamGridDB art.
    local script_dir="$1" username="$2" user_home="$3"

    if ! sh "$script_dir/data-sync.sh"; then
        warn "Data sync failed — starting stream anyway (saves may be out of date)"
    fi

    local games_path import_py pdp import_log
    games_path="$(capsule_conf_get GAMES_PATH "")"
    import_py="/opt/capsule-steam-venv/bin/python"
    if [ -n "$games_path" ] && [ -d "$games_path" ] && [ -x "$import_py" ]; then
        import_log="/tmp/capsule-import-$username.log"
        pdp="$(capsule_conf_get PERSISTENT_DATA_PATH "")"
        case "$pdp" in "~"*) pdp="$user_home${pdp:1}" ;; esac   # ~ = capsule user, not root
        CAPSULE_PERSISTENT_DATA_PATH="$pdp" \
        CAPSULE_SGDB_KEY="$(capsule_conf_get STEAMGRIDDB_API_KEY "")" \
            "$import_py" "$script_dir/capsule-import.py" import-dir "$username" "$games_path" \
            >"$import_log" 2>&1 \
            || warn "Game auto-import had problems — see $import_log"
    fi
}
