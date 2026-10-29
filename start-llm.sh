#!/bin/bash
# =============================================================================
# Capsule LLM session — started by capsule@<user>.service for capsules whose
# capsule.config contains "TYPE=llm" (start-stream.sh routes here).
#
# Runs a fully headless local-LLM stack as the capsule user:
#   * ollama serve      — model runtime + OpenAI-compatible API
#   * open-webui        — chat/admin web interface
#
# No X display, no Sunshine: the GPU is used purely for compute through
# /dev/kfd (ROCm) or render nodes (Vulkan fallback). Nothing to stream —
# reach it from any browser / any coding tool on the LAN.
#
# Ollama is the service's tracked process: if it dies, the unit restarts and
# Open WebUI goes with it. If Open WebUI dies first, we also exit (systemd
# brings the whole stack back cleanly instead of half-serving).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

USERNAME="$(whoami)"
USER_HOME="$(capsule_user_home "$USERNAME")"
export PATH="$USER_HOME/.local/bin:$PATH"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# --- Configuration ------------------------------------------------------------
MODEL="$(capsule_conf_get LLM_MODEL "qwen3-coder:30b")"
API_PORT="$(capsule_conf_get LLM_API_PORT 11434)"
WEB_PORT="$(capsule_conf_get LLM_WEB_PORT 8080)"
MODELS_PATH="$(capsule_conf_get LLM_MODELS_PATH "$USER_HOME/.ollama/models")"
CONTEXT_LENGTH="$(capsule_conf_get LLM_CONTEXT_LENGTH 8192)"
KEEP_ALIVE="$(capsule_conf_get LLM_KEEP_ALIVE 240m)"
HSA_OVERRIDE="$(capsule_conf_get LLM_HSA_OVERRIDE 10.3.0)"
HIP_VISIBLE="$(capsule_conf_get LLM_HIP_VISIBLE_DEVICES "")"
USE_VULKAN="$(capsule_conf_get LLM_VULKAN "")"

# --- Ollama environment ---------------------------------------------------------
export OLLAMA_HOME="$USER_HOME/.ollama"
export OLLAMA_MODELS="$MODELS_PATH"
export OLLAMA_HOST="0.0.0.0:$API_PORT"
export OLLAMA_CONTEXT_LENGTH="$CONTEXT_LENGTH"
export OLLAMA_KEEP_ALIVE="$KEEP_ALIVE"
# RX 6800 is gfx1030, a first-class ROCm target — this override is a no-op
# safety net for ROCm versions that gate the target behind PRO SKU names.
export HSA_OVERRIDE_GFX_VERSION="$HSA_OVERRIDE"
# ROCm sees EVERY amdgpu visible via /dev/kfd — including an iGPU, which it
# has been observed preferring. Pin when the config says which one to use.
[ -n "$HIP_VISIBLE" ] && export HIP_VISIBLE_DEVICES="$HIP_VISIBLE"
if [ "$USE_VULKAN" = "1" ]; then
    export OLLAMA_VULKAN=1
    info "LLM_VULKAN=1 — using Ollama's Vulkan backend (render node, no /dev/kfd)"
elif [ ! -c /dev/kfd ]; then
    warn "/dev/kfd missing — ROCm impossible, Ollama will fall back to Vulkan/CPU."
    warn "To enable the GPU: add the kfd lines from example-lxc.conf on the PVE"
    warn "host (lxc.cgroup2.devices.allow c 10:123 rwm + /dev/kfd bind mount) and"
    warn "restart the container."
fi

capsule_ensure_dir "$OLLAMA_MODELS" "$USERNAME:$USERNAME" 0755

# --- Refuse double-start ---------------------------------------------------------
if pgrep -U "$(id -u)" -x ollama >/dev/null 2>&1; then
    echo "ollama already running for $USERNAME (pid $(pgrep -U "$(id -u)" -x ollama | head -1)). Exiting."
    exit 0
fi

command -v ollama >/dev/null 2>&1 || \
    error "ollama not found — install with: pacman -S ollama-rocm (then re-run preconfig-llm.sh)"
command -v open-webui >/dev/null 2>&1 || \
    error "open-webui not found for $USERNAME — run as root: preconfig-llm.sh $USERNAME"

# --- Launch -----------------------------------------------------------------------
open-webui serve --host 0.0.0.0 --port "$WEB_PORT" &
WEBUI_PID=$!

ollama serve &
OLLAMA_PID=$!

cleanup() {
    kill "$WEBUI_PID" "$OLLAMA_PID" 2>/dev/null || true
}
trap cleanup EXIT TERM INT

cat <<EOF
Capsule LLM stack up (user: $USERNAME)
  Chat UI   : http://<this-host>:$WEB_PORT   (first account created = admin)
  API       : http://<this-host>:$API_PORT/v1  (OpenAI-compatible)
  Default model: $MODEL   (models dir: $OLLAMA_MODELS)
  GPU       : ROCm gfx1030 (RX 6800) — verify: ollama ps / journalctl --user -u capsule@$USERNAME
EOF

# Service lifetime == ollama's lifetime; Open WebUI follows.
while kill -0 "$OLLAMA_PID" 2>/dev/null && kill -0 "$WEBUI_PID" 2>/dev/null; do
    sleep 5
done
STATUS=0
kill -0 "$OLLAMA_PID" 2>/dev/null || STATUS=1
if [ "$STATUS" = "1" ]; then
    warn "ollama exited — systemd will restart the stack"
fi
exit "$STATUS"
