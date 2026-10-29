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
