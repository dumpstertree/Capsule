#!/bin/bash
# =============================================================================
# Turn an existing capsule user into a headless LLM capsule (Ollama +
# Open WebUI). Run once as root:
#
#     preconfig-llm.sh <username> [--no-pull]
#
# What it does:
#   1. installs ollama-rocm + uv (Arch official packages)
#   2. masks the system ollama service (we run Ollama per-capsule-user)
#   3. installs Open WebUI for that user (uv pulls a Python 3.12 runtime —
#      Open WebUI does not support Arch's system Python)
#   4. marks the capsule TYPE=llm in ~/<user>/capsule.config
#   5. stops a session that is still running (TYPE only takes effect when
#      the session script re-executes; starting an active unit is a no-op)
#   6. pulls the default model (~19 GB — skip with --no-pull) via a
#      throwaway server, because `ollama pull` needs one and the capsule
#      service is what normally provides it
#
# Switch modes afterwards:
#     capsulectl use llm      (stops game capsules, starts this one)
#     capsulectl use games    (stops the LLM, restarts the game capsules)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

capsule_require_root

USERNAME="${1:-}"
PULL=1
[ "${2:-}" = "--no-pull" ] && PULL=0
[ -n "$USERNAME" ] || error "Usage: $0 <username> [--no-pull]"
capsule_valid_username "$USERNAME" || error "Invalid username '$USERNAME'"
USER_HOME="$(capsule_user_home "$USERNAME")" || error "User $USERNAME does not exist"
[ -f "$USER_HOME/capsule.config" ] || error "$USER_HOME/capsule.config missing — is $USERNAME a capsule?"

MODEL="$(capsule_conf_get LLM_MODEL "qwen3-coder:30b")"
MODELS_PATH="$(capsule_conf_get LLM_MODELS_PATH "$USER_HOME/.ollama/models")"
WEB_PORT="$(capsule_conf_get LLM_WEB_PORT 8080)"
API_PORT="$(capsule_conf_get LLM_API_PORT 11434)"

# --- 1. Packages ---------------------------------------------------------------
log "Installing ollama-rocm + uv..."
if ! pacman -S --needed --noconfirm ollama-rocm uv; then
    warn "ollama-rocm unavailable — falling back to 'ollama' (CPU/Vulkan only)."
    warn "GPU via ROCm needs /dev/kfd in the container (see example-lxc.conf)."
    pacman -S --needed --noconfirm ollama uv
fi

# --- 2. System ollama unit must not run (we serve per-user) ---------------------
if systemctl list-unit-files --no-legend 'ollama.*' 2>/dev/null | grep -q .; then
    log "Masking system ollama service (per-capsule-user instances are used)..."
    systemctl disable --now ollama.service ollama.socket 2>/dev/null || true
    systemctl mask ollama.service ollama.socket 2>/dev/null || true
fi

# --- 3. /dev/kfd (ROCm compute node) --------------------------------------------
if [ -c /dev/kfd ]; then
    log "/dev/kfd present — ROCm (GPU compute) available"
else
    warn "/dev/kfd NOT present: Ollama will run CPU/Vulkan only."
    warn "Add to the container config on the PVE host (/etc/pve/lxc/<CT>.conf):"
    warn "  lxc.cgroup2.devices.allow: c 10:123 rwm"
    warn "  lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file"
    warn "...then reboot the container and re-run this script."
fi
usermod -aG render,video "$USERNAME" 2>/dev/null || true

# --- 4. Open WebUI (uv-managed Python 3.12 — system Python is too new) ----------
if [ -x "$USER_HOME/.local/bin/open-webui" ]; then
    log "Open WebUI already installed for $USERNAME"
else
    log "Installing Open WebUI for $USERNAME (uv fetches a 3.12 runtime; a few minutes)..."
    capsule_run_user "$USERNAME" -- uv tool install --python 3.12 open-webui
fi

# --- 5. Mark the capsule as llm type ---------------------------------------------
if grep -q '^TYPE=' "$USER_HOME/capsule.config"; then
    sed -i 's/^TYPE=.*/TYPE=llm/' "$USER_HOME/capsule.config"
else
    printf 'TYPE=llm\n' >> "$USER_HOME/capsule.config"
fi
log "$USERNAME is now TYPE=llm (display index left untouched; X display and"
log "Sunshine are skipped for this capsule from now on)"

# --- 6. Take down a session that may still be running ---------------------------
# TYPE only takes effect when the session script re-executes, and "start" on an
# already-active unit is a no-op. Without this stop, a capsule that streamed
# before the conversion keeps its stale X session forever: capsulectl reports
# "active" while ollama never starts (observed after a mid-conversion reboot).
if capsule_run_user "$USERNAME" systemctl --user is-active --quiet "capsule@$USERNAME.service"; then
    log "Stopping the running $USERNAME session (TYPE=llm applies on next start)..."
    capsule_run_user "$USERNAME" systemctl --user stop "capsule@$USERNAME.service"
fi
if INDEX="$(capsule_read_user_index "$USER_HOME/capsule.config")" && capsule_display_up "$INDEX"; then
    log "Retiring Xorg :$INDEX (start-host skips llm capsules, so it will not come back)"
    pkill -f "Xorg :$INDEX" || true
    sleep 2
fi

# --- 7. Pull the default model ----------------------------------------------------
# `ollama pull` speaks to a RUNNING server, and ours is normally started by the
# capsule service — which is not up at conversion time. Run a throwaway server
# just for the pull; if an llm session happens to be live already, the CLI
# connects to that and the throwaway simply fails to bind (harmless).
if [ "$PULL" = "1" ]; then
    FREE_GB="$(df -BG --output=avail "$(dirname "$MODELS_PATH")" 2>/dev/null | tail -1 | tr -dc '0-9')"
    if [ -n "$FREE_GB" ] && [ "$FREE_GB" -lt 25 ]; then
        error "Only ${FREE_GB}GB free at $MODELS_PATH — $MODEL needs ~20GB. Free space or set LLM_MODELS_PATH in $CAPSULE_CONFIG."
    fi
    log "Pulling $MODEL (~19GB download — this takes a while)..."
    if ! capsule_run_user "$USERNAME" -- env OLLAMA_MODELS="$MODELS_PATH" sh -c '
            ollama serve >"/tmp/ollama-pull-$(id -un).log" 2>&1 &
            srv=$!
            for _ in $(seq 1 30); do
                ollama list >/dev/null 2>&1 && break
                sleep 1
            done
            ollama pull "$1"
            rc=$?
            kill "$srv" 2>/dev/null || true
            exit "$rc"
        ' sh "$MODEL"; then
        warn "Model pull failed (network hiccup?) — everything else is installed."
        warn "After 'capsulectl use llm' brings the server up, finish with:"
        warn "  runuser -u $USERNAME -- ollama pull $MODEL"
    fi
else
    log "Skipping model pull. Later, as root:"
    log "  runuser -u $USERNAME -- env OLLAMA_MODELS=$MODELS_PATH ollama pull $MODEL"
fi

cat <<EOF

$(printf '\033[0;32m[SETUP]\033[0m') $USERNAME is ready. Next steps:
  1. capsulectl use llm          # stops game capsules, starts the LLM stack
  2. Browse to http://$(hostname 2>/dev/null || echo '<container-ip>'):$WEB_PORT
     and create the first account — it becomes the admin.
  3. Coding tools -> OpenAI-compatible endpoint:
     base URL http://<container-ip>:$API_PORT/v1, model "$MODEL", any API key.
  4. GPU check while loaded:     journalctl --user -u capsule@$USERNAME | grep -i gfx
     or: ollama ps (as $USERNAME) shows '100% GPU'
  Switch back to gaming anytime:  capsulectl use games
EOF
