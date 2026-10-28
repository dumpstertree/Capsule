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

## Multiple GPUs / displays

Two GPU-backed Xorg servers can never share one physical GPU — DRM master is
exclusive per card (`device is not DRM master` in `/var/log/Xorg.N.log`). Give
each capsule its own GPU:

1. Pass each GPU's card+render node into the LXC (`dev0: /dev/dri/card1`,
   `dev3: /dev/dri/card2`, plus matching `renderD*`; the
   `/dev/dri/by-path` bind covers naming).
2. Set `CAPSULE_GPU_BUSIDS` in `/etc/capsule/config` — one xorg BusID per
   capsule index, **decimal** bus numbers (`lspci` shows `0000:30:00.0` =
   hex → `PCI:48:0:0`).
3. `preconfig-xorg.sh` then generates `/etc/X11/capsule/xorg.<N>.conf` per
   display and `start-host.sh` uses them automatically.

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

## Dashboard

```bash
sh /Capsule/dashboard/install-dashboard.sh
```

FastAPI on `https://<container>:8443`: capsule list, live status (Xorg /
Sunshine / Steam), power on/off/restart, direct Sunshine UI links. Single admin
account (scrypt-hashed), HMAC sessions, CSRF-protected POSTs, login rate
limiting, self-signed cert (swap in your own `key.pem`/`cert.pem` under
`/etc/capsule/dashboard/`). Put it behind your reverse proxy or port-forward —
use a long password.

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
generate-shortcuts.{sh,py}
dashboard/              FastAPI control panel
capsule-fix.sh          one-shot repair/migration for existing installs
example-*.{conf,service}  templates installed by the scripts above
```
