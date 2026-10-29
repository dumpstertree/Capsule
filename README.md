# Capsule

Turn one gaming PC into a multi-seat cloud gaming box: an Arch LXC container
(Proxmox) hosting N headless Steam/Proton "capsules", each streamed via
[Sunshine](https://github.com/LizardByte/Sunshine) to Moonlight, with a web
dashboard for power control and a shared save-sync between capsules.

```
Moonlight ──────────► capsule0 : base+0..21   (Sunshine, Xorg :0)
Moonlight ──────────► capsule1 : base+1000..  (Sunshine, Xorg :1)
Browser  ── :8443 ──► dashboard ──► capsulectl ──► systemctl --user capsule@<user>
```

## Quick install (fresh container)

```bash
pacman-key --init && pacman -Syu --noconfirm curl git && \
bash <(curl -fsSL https://raw.githubusercontent.com/dumpstertree/Capsule/refs/heads/main/install.sh)
```

`open_capsule.sh` asks for: capsule count, GPU index, games path, persistent
data path, allowed Sunshine UI origins (hosts you browse FROM — scheme is added
automatically) and a SteamGridDB key. All answers are validated; persistent
directories are created with correct ownership.

## Repairing / migrating an existing install

```bash
cd /Capsule && git pull && ./capsule-fix.sh            # + --reset-sunshine-creds
```

## Ports (per capsule index N, base = 47989 + N×1000)

| Port range        | Purpose                                            |
|-------------------|----------------------------------------------------|
| `base - 5`        | Sunshine GameStream HTTPS (47984 for capsule 0)    |
| `base .. base+21` | Streaming (RTSP/video/audio/control, Moonlight)    |
| **`base + 1`**    | **Sunshine web UI — HTTPS only** (47990, 48990…)   |
| `8443`            | Capsule dashboard (HTTPS, login)                   |

The web UI is at `https://<container-ip>:<base+1>` — **not** `base` (plain
`base` answers 404; that's Sunshine's GameStream endpoint). Sunshine's
`csrf_allowed_origins` must contain the **UI's own origin**
(`https://<ip>`), not your client's — it's CSRF protection, not access control.
`origin_web_ui_allowed = lan` is what lets other machines open the UI.

Sunshine login is `capsule` / `<random generated at install>`; passwords are
stored at `/etc/capsule/sunshine-creds/<user>` (root-readable).

## Config

`/etc/capsule/config` (0640 `root:capsule`, key=value):

```
GPU_INDEX=1
GAMES_PATH=/games
PERSISTENT_DATA_PATH=/raid/capsule
SUNSHINE_ALLOWED_ORIGINS=https://192.168.1.125
STEAMGRIDDB_API_KEY=...
CAPSULE_GPU_BUSIDS=PCI:18:0:0,PCI:48:0:0
SUNSHINE_BASE_PORT=47989
SUNSHINE_PORT_STEP=1000
CAPSULE_USER_PREFIX=capsule
```

## One GPU, many capsules (dummy displays)

Capsules do NOT run GPU-backed Xorg servers — two X servers can never share a
card because DRM/KMS master is exclusive per card (`device is not DRM master`
in `/var/log/Xorg.N.log`). Instead every capsule runs a **dummy** X display
(RAM framebuffer) and the GPU is shared the way the kernel allows: through its
**render node**, which has no master and unlimited concurrent clients.
Games render on the GPU (Vulkan/Proton via GBM/render nodes), Sunshine
captures the dummy surface (`capture = x11`).

Consequences to plan around:

* **Vulkan is hardware** (Proton, DXVK, and native VK titles — the common
  case). **GLX/OpenGL falls back to llvmpipe** on dummy displays: fine for
  Steam's UI, slow for heavy native-GL games. To give one capsule hardware
  GLX too, set `CAPSULE_GPU_DISPLAYS=0` (plus `CAPSULE_KMSDEV` if the card
  node differs) — that display gets a GPU-backed X server with DRM master.
  Only ONE display per card can do this; the others must stay dummy.
* All capsules share the GPU's compute/VRAM — two heavy AAA titles at once
  contend, as expected.
* **Render node mapping matters:** pass the render node of the GPU you actually
  want used, resolved on the host with
  `ls -l /dev/dri/by-path/ | grep <pci-address>` — **never** derive it
  arithmetically from the card number; probe order does not reliably pair
  `cardN` with `renderD128+N` (on a real two-GPU box the RX 6800 at `12:00.0`
  was `renderD128` while the iGPU at `30:00.0` owned `renderD129`).
* **One VT per display:** when a second X server takes VT ownership the kernel
  SIGTERMs the previous owner, and inside a container (no real VTs) every
  auto-allocated server lands on `/dev/tty7` — so display `:1` kills display
  `:0` ~1s after startup (`Server terminated successfully (0)` in
  `Xorg.0.log`). `start-host.sh` passes the BARE argument `vt(7+index)` to
  each server (`-vt7` is NOT a valid option — Xorg exits at argument
  parsing); `-novtswitch` alone does NOT prevent this.
* **Dummy VideoRam:** the driver defaults to 4 MB of emulated VRAM, under the
  ~8.3 MB a 1920x1080 32bpp framebuffer needs. It must be set as the **bare**
  Device entry `VideoRam 65536` — dummy 0.4.x's option table only knows
  `SWcursor`, so `Option "VideoRam"` is silently ignored (log shows
  `(--) VideoRAM: 4096 kByte` — `(--)` means "default", `(**)` would mean
  "read from config"). Likewise the Monitor needs explicit `HorizSync`/
  `VertRefresh` ranges, or the default 65 MHz pixel-clock cap prunes the
  1080p modeline.

## Input isolation (per-capsule keyboard/mouse)

Sunshine injects input through `/dev/uinput`, which is **global to the
kernel** — out of the box every capsule's Xorg hot-plugs every capsule's
virtual keyboard/mouse and one Moonlight client moves all cursors at once.

How Capsule separates them (Sunshine >= 2026.05 required — check
`sunshine --version`):

1. `start-stream.sh` exports `XDG_SEAT=seat<index+1>`; Sunshine appends
   `(seatN)` to every virtual device name (`Mouse passthrough (seat2)`).
   `index+1` because Sunshine deliberately does not tag seat0.
2. `start-host.sh` generates a per-display Xorg config at
   `/run/capsule/xorg.<index>.conf` = the normal config plus an InputClass
   `Option "Ignore" "true"` for every FOREIGN `(seatN)` tag. X evaluates
   these at hot-plug time, so devices Sunshine creates mid-session are
   filtered too.
3. Verify live: `DISPLAY=:0 xinput list` must show only
   `... (seat1)` passthrough devices (plus XTEST). Anything else = too-old
   Sunshine or Xorg not restarted since the update.

**Gamepad caveat:** virtual gamepads are read straight from evdev by
Steam/SDL, bypassing X — Steam sees every capsule's pads (identifiable by
their `(seatN)` suffix in `ls /sys/class/input/*/device/name`). With
controllers, disable foreign pads in Steam → Settings → Controller, or keep
to one pad-connected capsule at a time.

## LLM capsule (Ollama + Open WebUI) — exclusive-GPU mode

A capsule can be a headless local-LLM host instead of a stream target:
**Ollama** (model runtime + OpenAI-compatible API) with **Open WebUI** (chat
frontend), running **Qwen3-Coder** on the RX 6800 via ROCm. No X display, no
Sunshine, no Moonlight — you reach it from any browser or coding tool on the
LAN. Because a loaded 30B model occupies most of the GPU's 16 GB VRAM, the
LLM capsule and the game capsule(s) take turns via one command:

```bash
capsulectl use llm     # stop game capsule(s) -> start LLM stack
capsulectl use games   # stop LLM (VRAM freed) -> start game capsule(s)
capsulectl list        # shows TYPE column + active mode
```

### Setup (once)

1. **Container needs `/dev/kfd`** (ROCm compute device). Add to
   `/etc/pve/lxc/<CT>.conf` on the PVE host (see `example-lxc.conf`) and
   reboot the container:
   ```
   lxc.cgroup2.devices.allow: c 10:123 rwm
   lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file
   ```
2. Convert a capsule (does NOT need to be re-created — any user works):
   ```bash
   ./preconfig-llm.sh capsule1      # installs, marks TYPE=llm, pulls model (~19 GB)
   ```
   The marker is one line — `TYPE=llm` — in `/home/capsule1/capsule.config`.
   llm capsules are skipped by `start-host.sh` (no X display) and
   `start-stream.sh` routes them to `start-llm.sh` (no Sunshine/Steam).
3. `capsulectl use llm`, browse to `http://<container>:8080`, create the
   **first account — it becomes admin** (then disable signups in Settings →
   General once yours exists; the API is open LAN-wide by design).

### Using it

* **Chat / admin:** `http://<container>:8080`
* **Coding agents** — OpenAI-compatible endpoint `http://<container>:11434/v1`,
  model `qwen3-coder:30b`, any API key. OpenCode example
  (`~/.config/opencode/opencode.json`):
  ```json
  {
    "$schema": "https://opencode.ai/config.json",
    "provider": {
      "capsule": {
        "npm": "@ai-sdk/openai-compatible",
        "name": "Capsule LLM",
        "options": { "baseURL": "http://192.168.1.125:11434/v1" },
        "models": { "qwen3-coder:30b": { "name": "Qwen3-Coder 30B" } }
      }
    }
  }
  ```
* **Models:** change the default with `LLM_MODEL=...` in `/etc/capsule/config`
  (then re-pull via `preconfig-llm.sh <user>` or as the user:
  `runuser -u capsule1 -- env OLLAMA_MODELS=/home/capsule1/.ollama/models ollama pull <model>`).
  For 16 GB VRAM: `qwen3-coder:30b` (Q4, a slice spills to system RAM —
  fine, it's a 3B-active MoE) or a `q3_K_M` variant for 100% GPU load.

### Config keys (`/etc/capsule/config`, all optional)

`LLM_MODEL` (qwen3-coder:30b) · `LLM_API_PORT` (11434) · `LLM_WEB_PORT` (8080)
· `LLM_MODELS_PATH` (~/.ollama/models) · `LLM_CONTEXT_LENGTH` (8192) ·
`LLM_KEEP_ALIVE` (240m — model stays loaded in VRAM) · `LLM_HSA_OVERRIDE`
(10.3.0 = gfx1030/RX 6800) · `LLM_HIP_VISIBLE_DEVICES` (pin ROCm when an iGPU
is also visible — ROCm has been seen preferring it) · `LLM_VULKAN=1` (force
Ollama's Vulkan backend if `/dev/kfd` is unavailable).

### Verifying the GPU is actually used

`ollama ps` (as the capsule user) must show `100% GPU`; the journal shows the
ROCm probe: `journalctl --user -u capsule@capsule1 | grep -iE "gfx|rocm|vram"`.
If it says CPU: check `/dev/kfd` exists in the container and that no
`ollama` **system** service grabbed the GPU first (`systemctl status ollama`
must be masked — preconfig-llm.sh does it).

## Sway game capsule (Wayland, no X) — EXPERIMENTAL

A third capsule role: `TYPE=sway` is a **game capsule with no X server at
all**. Steam and games run inside **sway** (wlroots) with the **headless**
backend — composited on the RX 6800 through its render node — and Sunshine
captures the virtual output with its **wlr** backend
(wlr-screencopy-unstable-v1). Moonlight connects exactly as before, same
ports, same credentials.

Why this exists: dummy X displays can never show hardware-accelerated
content. X's Vulkan swapchain needs DRI3, DRI3 needs KMS, KMS needs DRM
master — one per card, held by the GPU-backed capsule. **Wayland has no
such wall:** apps render on a DRM render node (shared, no master) and
present via dmabuf. A headless compositor needs no display hardware at
all, so N of them can coexist with everything hardware-accelerated. This
is the only known fix for capsule-N game FPS on a single non-SR-IOV GPU
that does not involve buying anything.

```
steam (Xwayland :10) ─┐                       HEADLESS-1 output
native VK games ──────┴─► sway (wlroots)  ──► Sunshine capture=wlr ──► Moonlight
                          composites via
                          /dev/dri/renderD128 (RX 6800)
```

### Convert a capsule

```bash
./preconfig-sway.sh capsule1     # installs sway, TYPE=sway, capture=wlr, retires Xorg :1
capsulectl start capsule1        # Moonlight: same ports as always
capsulectl list                  # TYPE=sway, XORG=n/a, sunshine listening
```

Config knobs (`/etc/capsule/config`): `CAPSULE_RENDER_NODE`
(**must** be the RX 6800's render node — resolve with
`ls -l /dev/dri/by-path/ | grep 12:00.0`), `SWAY_RESOLUTION` (1920x1080),
`SWAY_REFRESH` (60), `SWAY_XDISPLAY` (:10 — Xwayland inside sway, must not
collide with real Xorg display numbers).

Revert: `sed -i '/^TYPE=/d' /home/capsule1/capsule.config &&
./preconfig-sunshine.sh capsule1 1 && systemctl restart capsule-host &&
capsulectl restart capsule1`

### Verify (the whole point of the exercise)

```bash
# sway picked the real GPU, not software:
runuser -u capsule1 -- env XDG_RUNTIME_DIR=/run/user/1001 \
    WAYLAND_DISPLAY=wayland-1 eglinfo | grep -i renderer
#   AMD Radeon RX 6800 (radeonsi, navi21)  ✓   llvmpipe  ✗

# Vulkan sees the card (games will use it — no DRI3 involved):
runuser -u capsule1 -- env XDG_RUNTIME_DIR=/run/user/1001 \
    WAYLAND_DISPLAY=wayland-1 vulkaninfo --summary | grep deviceName

# inside the stream, Steam → Settings → System should name the RX 6800
# (the "generic graphics card" label cannot survive here: there is no X
# GLX for it to misreport)
```

### Known limitations (state: first prototype)

* **Input isolation is milestone 2.** uinput devices are global and
  wlroots has no X-`InputClass` ignore equivalent: sway opens every input
  device its user can read. Sunshine's virtual keyboard/mouse still carry
  the `(seatN)` names (start-sway re-exports `XDG_SEAT` for Sunshine), but
  **sway will not filter foreign ones** — with two capsules streaming at
  once, pointers can leak between them. The fix being scoped: udev rules
  that set each `(seatN)` device's GROUP to that capsule's user, so
  sessions are walled off by file permissions (root's Xorg keeps its
  InputClass rules; permission walls replace them for sway). Until then
  this branch is for A/B testing one capsule at a time.
* Wayland composites cursor plane differently; if the pointer misbehaves,
  tune in `~/.config/sway/capsule.conf` (regenerated at every start —
  change the generator in `start-sway.sh` instead).
* Steam runs under Xwayland (sway starts it automatically, pinned to the
  same render node via `WLR_RENDER_DRM_DEVICE` → `WAYLAND_DEVICE`).
* Native Wayland Steam (`-vg-driver`/`SDL_VIDEODRIVER=wayland`) untested.
* Sunshine needs its wlroots capture backend (Arch package: built in;
  `capture = wlr` was added to Sunshine upstream in 2026 — older builds
  will reject the value).

## Operating

```bash
capsulectl list                 # status of every capsule
capsulectl start capsule0       # or stop/restart/all
systemctl status capsule-host   # Xorg displays
journalctl -u capsule-dashboard # dashboard logs
```

At boot: `capsule-host.service` starts one Xorg display per capsule, and each
user's lingered manager starts `capsule@<user>.service` (Steam Big Picture +
Sunshine). `start-stream.sh` is safe to run manually too — it validates the
environment instead of failing deep inside Steam.

## Game libraries & non-Steam games

Set a **games folder** once (dashboard *Games* dialog, or `GAMES_PATH` in
`/etc/capsule/config`). Every subfolder that contains an `.exe` becomes a
Steam shortcut with full SteamGridDB metadata and artwork (capsule /
portrait / hero / logo / icon) — **automatically at every capsule start**,
before Steam launches. Already-imported games are skipped with zero network
calls; drop a new folder onto the drive and it shows up next start. If Steam
is already running, use the dialog's **Scan & import now** instead (restarts
that capsule's Steam). Logs: `/tmp/capsule-import-<user>.log`.

Same engine, exposed for scripting:

```bash
capsule-import.sh import-dir   capsule0 /mnt/games     # batch (idempotent; --dry-run previews)
capsule-import.sh add-game     capsule0 /path/to/game.exe [--name N] [--sgdb-id ID]
capsule-import.sh list-games   capsule0
capsule-import.sh remove-game  capsule0 "Game Name"

# add a drive to Steam itself (separate from the auto-import folder):
capsule-import.sh add-library  capsule0 /mnt/steamgames
capsule-import.sh list-libraries capsule0
```

Write operations stop only that user's Steam (it rewrites its config on exit
and would clobber the edits), write the entries, fix ownership, and relaunch
Steam if the capsule was streaming. Game metadata is recorded under
`PERSISTENT_DATA_PATH/metadata/` — the same convention `generate-shortcuts.sh`
uses, and both generators preserve entries they don't own.

## Dashboard

```bash
sh /Capsule/dashboard/install-dashboard.sh
```

FastAPI on `https://<container>:8443`: capsule list, live status (Xorg /
Sunshine / Steam), power on/off/restart, direct Sunshine UI links, and a
**Games** button per capsule — set the games folder once (auto-imported at
every capsule start), scan on demand, remove games, add Steam library
drives. All forms, no shell. Single admin account
(scrypt-hashed), HMAC sessions, CSRF-protected POSTs, login rate
limiting, self-signed cert (swap in your own `key.pem`/`cert.pem` under
`/etc/capsule/dashboard/`). Put it behind your reverse proxy or port-forward —
use a long password.

`config.yaml` keys `capsule_dir` (repo holding `capsule-import.sh`) and
`import_venv` point the dashboard at the import engine; the installer
creates the venv so the web actions never touch the package manager.

## Security notes

* Capsule users have locked (passwordless-login-disabled) accounts; use
  `sudo -iu capsule0`.
* `/etc/capsule/config` holds the SteamGridDB key: 0640 root:capsule, never 777.
* Sunshine ports are unauthenticated by design *within* the pairing trust
  boundary — only expose them to networks/clients you control, or use a VPN
  (Tailscale/WireGuard) for anything else.

## Layout

```
lib/common.sh           shared helpers (config, validation, user/systemd plumbing)
capsulectl              root CLI: list/status/start/stop/restart (+ --json)
start-host.sh           start Xorg displays (capsule-host.service)
start-stream.sh         Steam+Sunshine launcher (capsule@.service / manual)
data-sync.sh            bidirectional save sync (compatdata <-> persistent)
capsule-import.{sh,py}  Steam library drives + non-Steam game imports
generate-shortcuts.{sh,py}
dashboard/              FastAPI control panel
capsule-fix.sh          one-shot repair/migration for existing installs
example-*.{conf,service}  templates installed by the scripts above
```
