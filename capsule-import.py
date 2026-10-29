#!/usr/bin/env python3
"""
capsule-import.py — per-capsule Steam library & non-Steam shortcut management.

Normally invoked through capsule-import.sh, which handles the venv, stopping
Steam around write operations, config lookup and Steam relaunch.

Subcommands:
  add-library     USER PATH                 mount a folder/drive as Steam library
  remove-library  USER PATH
  list-libraries  USER
  add-game        USER EXE [--name N] [--startdir D] [--sgdb-id ID]
                           [--launch-options S] [--no-art]
  remove-game     USER NAME_OR_APPID
  list-games      USER

Environment (set by the wrapper):
  CAPSULE_PERSISTENT_DATA_PATH   metadata/ + assets/ live here (optional)
  CAPSULE_SGDB_KEY               SteamGridDB API key; empty = no matching/art
  CAPSULE_HOME_ROOT              (/home) override for testing only
"""

import argparse
import json
import os
import pwd
import shutil
import sys
import zlib
from pathlib import Path

import requests
import vdf

HOME_ROOT = Path(os.environ.get("CAPSULE_HOME_ROOT", "/home"))
PERSISTENT_DATA_PATH = Path(os.environ["CAPSULE_PERSISTENT_DATA_PATH"]) \
    if os.environ.get("CAPSULE_PERSISTENT_DATA_PATH") else None
SGDB_KEY = os.environ.get("CAPSULE_SGDB_KEY", "").strip()
JSON_OUT = bool(os.environ.get("CAPSULE_IMPORT_JSON"))  # list-* emit machine JSON

# everything we create lives under the capsule user's home — collect paths and
# chown them back (the wrapper runs this script as root)
_CHOWN_TARGETS = set()


def fail(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def chown_later(path):
    _CHOWN_TARGETS.add(Path(path))


def chown_all(user):
    try:
        pw = pwd.getpwnam(user)
    except KeyError:
        return
    for target in sorted(_CHOWN_TARGETS):
        for path in ([target] + list(target.rglob("*")) if target.is_dir() else [target]):
            try:
                os.chown(path, pw.pw_uid, pw.pw_gid)
            except OSError:
                pass


###############################################################################
# STEAM LAYOUT
###############################################################################


def steam_root(user):
    steam = HOME_ROOT / user / ".steam/steam"
    if not steam.is_dir():
        fail(f"{steam} not found — start this capsule and log into Steam once")
    return steam


def latest_userdata(steam):
    """Most recently used userdata dir (same heuristic as generate-shortcuts.py)."""
    ud = steam / "userdata"
    dirs = [p for p in ud.iterdir() if p.is_dir()] if ud.is_dir() else []
    if not dirs:
        fail(f"{ud} missing — start Steam once for this user before adding games")
    return max(dirs, key=lambda p: (p / "config").stat().st_mtime)


def config_dir(steam):
    cfg = latest_userdata(steam) / "config"
    cfg.mkdir(parents=True, exist_ok=True)
    return cfg


###############################################################################
# LIBRARY FOLDERS  (steamapps/libraryfolders.vdf — plain text VDF)
###############################################################################


def libraryfolders_path(steam):
    return steam / "steamapps/libraryfolders.vdf"


def load_libraryfolders(path):
    if not path.exists():
        return {"libraryfolders": {}}
    try:
        data = vdf.loads(path.read_text())
    except Exception:
        fail(f"{path} exists but is not readable VDF — refusing to modify it")
    data.setdefault("libraryfolders", {})
    return data


def next_folder_index(folders):
    used = {int(k) for k in folders if str(k).lstrip("-").isdigit()}
    i = 0
    while i in used:
        i += 1
    return str(i)


def save_libraryfolders(path, data):
    # renumber folder keys 0..N so Steam sees a contiguous list
    folders = data["libraryfolders"]
    ordered = sorted(folders.values(), key=lambda v: str(v.get("path", "")))
    data["libraryfolders"] = {
        str(i): v for i, v in enumerate(ordered)
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".vdf.tmp")
    tmp.write_text(vdf.dumps(data, pretty=True))
    # validate before replacing the live file
    vdf.loads(tmp.read_text())
    os.replace(tmp, path)


def cmd_add_library(user, args):
    steam = steam_root(user)
    path = Path(args.path).expanduser().resolve()
    if not path.is_dir():
        fail(f"{path} does not exist — is the drive mounted INSIDE the container?")
    if path == Path.home().resolve() or path == steam.resolve():
        fail(f"{path} is Steam's own install/library — pick the game drive instead")

    lf = libraryfolders_path(steam)
    data = load_libraryfolders(lf)
    folders = data["libraryfolders"]

    for key, entry in folders.items():
        if Path(str(entry.get("path", ""))).resolve() == path:
            print(f"already a library folder (index {key}): {path}")
            return

    # Steam fills in content_id/apps/totalsize itself on next launch after
    # scanning; path+label+apps is the minimal entry it accepts.
    idx = next_folder_index(folders)
    folders[idx] = {"path": str(path), "label": "", "apps": {}}
    save_libraryfolders(lf, data)
    chown_later(lf.parent)
    print(f"added library folder (index {idx}): {path}")
    print("Steam will scan and populate it on next start")


def cmd_remove_library(user, args):
    steam = steam_root(user)
    path = Path(args.path).expanduser().resolve()
    lf = libraryfolders_path(steam)
    data = load_libraryfolders(lf)
    folders = data["libraryfolders"]

    for key, entry in list(folders.items()):
        if Path(str(entry.get("path", ""))).resolve() == path:
            if str(entry.get("path", "")).startswith(
                    str((HOME_ROOT / user).resolve())):
                fail(f"{path} is inside the user's home (Steam's default library) — "
                     "remove it from Steam's settings instead")
            del folders[key]
            save_libraryfolders(lf, data)
            chown_later(lf.parent)
            print(f"removed library folder: {path}")
            return
    fail(f"not a configured library folder: {path}")


def cmd_list_libraries(user, args):
    lf = libraryfolders_path(steam_root(user))
    folders = load_libraryfolders(lf)["libraryfolders"]
    items = [
        {"index": int(k) if str(k).isdigit() else k, "path": str(v.get("path", ""))}
        for k, v in sorted(folders.items(),
                           key=lambda kv: int(kv[0]) if str(kv[0]).isdigit() else 999)
    ]
    if JSON_OUT:
        print(json.dumps({"libraries": items}))
        return
    if not items:
        print("(no library folders yet — Steam creates the default on first run)")
        return
    for item in items:
        print(f"  [{item['index']}] {item['path']}")


###############################################################################
# SHORTCUTS  (userdata/<sid>/config/shortcuts.vdf — BINARY vdf)
###############################################################################


def generate_shortcut_appid(appname, exe):
    """Steam's own scheme: crc32(exe+appname) with the sign bit set."""
    crc = zlib.crc32((exe + appname).encode("utf-8")) | 0x80000000
    if crc > 0x7FFFFFFF:
        crc -= 0x100000000
    return crc


def load_shortcuts(path):
    if not path.exists():
        return {}
    try:
        with open(path, "rb") as f:
            return (vdf.binary_load(f) or {}).get("shortcuts") or {}
    except Exception:
        fail(f"{path} exists but is corrupt — fix or delete it (Steam rebuilds)")


def save_shortcuts(path, entries):
    """entries: list of dicts; index keys are rebuilt contiguously."""
    by_index = {str(i): e for i, e in enumerate(entries)}
    tmp = path.with_suffix(".tmp")
    with open(tmp, "wb") as f:
        vdf.binary_dump({"shortcuts": by_index}, f)
    with open(tmp, "rb") as f:  # never ship a file Steam can't read
        vdf.binary_load(f)
    os.replace(tmp, path)


def shortcut_template(name, exe, startdir, launch_options):
    return {
        "appid": generate_shortcut_appid(name, str(exe)),
        "appname": name,
        "exe": f'"{exe}"',
        "StartDir": str(startdir),
        "icon": "",
        "ShortcutPath": "",
        "LaunchOptions": launch_options or "",
        "IsHidden": 0,
        "AllowDesktopConfig": 1,
        "AllowOverlay": 1,
        "OpenVR": 0,
        "Devkit": 0,
        "DevkitGameID": "",
        "DevkitOverrideAppID": 0,
        "LastPlayTime": 0,
        "FlatpakAppID": "",
        "tags": {"0": "Non-Steam"},
    }


###############################################################################
# STEAMGRIDDB — name matching + artwork
###############################################################################


def sgdb_headers():
    return {"Authorization": f"Bearer {SGDB_KEY}"}


def sgdb_json(url):
    try:
        r = requests.get(url, headers=sgdb_headers(), timeout=20)
        data = r.json()
        return data if data.get("success") else None
    except Exception as e:
        print(f"  steamgriddb request failed: {e}")
        return None


def sgdb_download(url, output):
    try:
        r = requests.get(url, timeout=30)
        if r.status_code != 200:
            return False
        output.write_bytes(r.content)
        return True
    except Exception:
        return False


def fetch_art(sgdb_id, unsigned_appid, cfg, grid_dir):
    """Capsule/portrait/hero/logo into grid/ + icon into shortcuts/ (Steam's
    discovery paths). Cached under PERSISTENT_DATA_PATH/assets when set."""
    cache = (PERSISTENT_DATA_PATH / "assets" / str(unsigned_appid)) \
        if PERSISTENT_DATA_PATH else cfg / "capsule-assets" / str(unsigned_appid)
    cache.mkdir(parents=True, exist_ok=True)
    if PERSISTENT_DATA_PATH:
        chown_later(PERSISTENT_DATA_PATH / "assets")

    targets = [
        ("capsule.png", f"https://www.steamgriddb.com/api/v2/grids/game/{sgdb_id}?dimensions=460x215"),
        ("portrait.png", f"https://www.steamgriddb.com/api/v2/grids/game/{sgdb_id}?dimensions=600x900"),
        ("hero.png", f"https://www.steamgriddb.com/api/v2/heroes/game/{sgdb_id}"),
        ("logo.png", f"https://www.steamgriddb.com/api/v2/logos/game/{sgdb_id}"),
        ("icon.ico", f"https://www.steamgriddb.com/api/v2/icons/game/{sgdb_id}"),
    ]

    for filename, endpoint in targets:
        cached = cache / filename
        if not cached.exists():
            data = sgdb_json(endpoint)
            items = (data or {}).get("data") or []
            if not items:
                continue
            if not sgdb_download(items[0]["url"], cached):
                cached.unlink(missing_ok=True)
                continue
        print(f"  art: {filename}")

        # copy into the places Steam looks, under the unsigned appid
        if filename == "icon.ico":
            dst_dir = cfg / "shortcuts"
            dst_dir.mkdir(exist_ok=True)
            shutil.copy2(cached, dst_dir / f"{unsigned_appid}-icon.ico")
        else:
            suffix = {"capsule.png": "", "portrait.png": "p",
                      "hero.png": "_hero", "logo.png": "_logo"}[filename]
            grid_dir.mkdir(exist_ok=True)
            shutil.copy2(cached, grid_dir / f"{unsigned_appid}{suffix}.png")


def save_metadata(name, data):
    if not PERSISTENT_DATA_PATH:
        return
    meta_dir = PERSISTENT_DATA_PATH / "metadata"
    meta_dir.mkdir(parents=True, exist_ok=True)
    safe_name = name.replace("/", "_")
    (meta_dir / f"{safe_name}.json").write_text(json.dumps(data, indent=4))
    chown_later(meta_dir)


###############################################################################
# GAME COMMANDS
###############################################################################


def cmd_add_game(user, args):
    steam = steam_root(user)
    cfg = config_dir(steam)
    grid_dir = cfg / "grid"
    shortcuts_file = cfg / "shortcuts.vdf"

    exe = Path(args.exe).expanduser().resolve()
    if not exe.is_file():
        fail(f"executable not found: {exe}")
    name = args.name or exe.stem
    startdir = str(Path(args.startdir).expanduser().resolve()) if args.startdir \
        else str(exe.parent)

    print(f"game:    {name}")
    print(f"exe:     {exe}")
    print(f"startdir:{startdir}")

    steam_appid = None
    sgdb_id = args.sgdb_id
    official_name = name

    if SGDB_KEY and not args.no_art:
        if not sgdb_id:
            data = sgdb_json(
                "https://www.steamgriddb.com/api/v2/search/autocomplete/" + name)
            items = (data or {}).get("data") or []
            if items:
                sgdb_id = items[0]["id"]
                official_name = items[0].get("name", name)
                steam_appid = items[0].get("steamAppId")
                print(f"sgdb:    {official_name} (id {sgdb_id})")
            else:
                print("sgdb:    no match — importing without artwork")

    entry = shortcut_template(official_name, exe, startdir, args.launch_options)
    unsigned = entry["appid"] & 0xFFFFFFFF

    if SGDB_KEY and not args.no_art and sgdb_id:
        fetch_art(sgdb_id, unsigned, cfg, grid_dir)
    elif args.no_art:
        print("sgdb:    skipped (--no-art)")
    elif not SGDB_KEY:
        print("sgdb:    no API key set — importing without artwork")

    entries = list(load_shortcuts(shortcuts_file).values())
    replaced = False
    for i, existing in enumerate(entries):
        if existing.get("appid") == entry["appid"] or \
                str(existing.get("appname", "")).lower() == official_name.lower():
            entries[i] = entry  # idempotent re-import: update in place
            replaced = True
    if not replaced:
        entries.append(entry)
    save_shortcuts(shortcuts_file, entries)
    chown_later(cfg)

    save_metadata(official_name, {
        "folder_name": official_name,
        "shortcut_appid": entry["appid"],
        "steam_appid": steam_appid,
        "official_name": official_name,
        "steamgriddb_id": sgdb_id,
        "exe": str(exe),
        "startdir": startdir,
        "source": "capsule-import",
    })

    print(f"{'updated' if replaced else 'added'} shortcut "
          f"(appid {unsigned}) — {official_name}")
    print("visible in Steam's Non-Steam list after Steam (re)starts")


def cmd_remove_game(user, args):
    cfg = config_dir(steam_root(user))
    shortcuts_file = cfg / "shortcuts.vdf"
    entries = list(load_shortcuts(shortcuts_file).values())

    target = args.target
    kept = []
    removed = []
    for e in entries:
        if str(e.get("appname", "")).lower() == target.lower() or \
                str(e.get("appid")) == target or \
                str(e.get("appid") & 0xFFFFFFFF if isinstance(e.get("appid"), int)
                    else "") == target:
            removed.append(e.get("appname", "?"))
        else:
            kept.append(e)

    if not removed:
        fail(f"no shortcut matching: {target}  (list-games shows what's there)")
    save_shortcuts(shortcuts_file, kept)
    chown_later(cfg)
    for name in removed:
        print(f"removed shortcut: {name}")


def cmd_list_games(user, args):
    entries = load_shortcuts(config_dir(steam_root(user)) / "shortcuts.vdf")
    items = [
        {
            "appid": e.get("appid", 0) & 0xFFFFFFFF,
            "appname": e.get("appname", "?"),
            "exe": str(e.get("exe", "")).strip('"'),
            "launch_options": e.get("LaunchOptions", ""),
        }
        for e in entries.values()
    ]
    if JSON_OUT:
        print(json.dumps({"games": items}))
        return
    if not items:
        print("(no non-Steam shortcuts)")
        return
    for item in items:
        print(f"  {item['appid']:>10}  {item['appname']}")


###############################################################################
# MAIN
###############################################################################


def main():
    ap = argparse.ArgumentParser(prog="capsule-import.py")
    sub = ap.add_subparsers(dest="cmd", required=True)

    for cmd, help_ in [
        ("add-library", "add a folder/drive as a Steam library"),
        ("remove-library", "remove a Steam library folder"),
        ("list-libraries", "list Steam library folders"),
    ]:
        p = sub.add_parser(cmd, help=help_)
        p.add_argument("user")
        if "add" in cmd or "remove" in cmd:
            p.add_argument("path")

    p = sub.add_parser("add-game", help="add a non-Steam game shortcut")
    p.add_argument("user")
    p.add_argument("exe")
    p.add_argument("--name", help="display name (default: exe name)")
    p.add_argument("--startdir", help="working directory (default: exe's folder)")
    p.add_argument("--sgdb-id", type=int, help="SteamGridDB game id (skip search)")
    p.add_argument("--launch-options", default="", help="extra command-line args")
    p.add_argument("--no-art", action="store_true", help="skip SteamGridDB entirely")

    p = sub.add_parser("remove-game", help="remove a non-Steam shortcut")
    p.add_argument("user")
    p.add_argument("target", help="game name or appid")

    p = sub.add_parser("list-games", help="list non-Steam shortcuts")
    p.add_argument("user")

    args = ap.parse_args()

    handlers = {
        "add-library": cmd_add_library,
        "remove-library": cmd_remove_library,
        "list-libraries": cmd_list_libraries,
        "add-game": cmd_add_game,
        "remove-game": cmd_remove_game,
        "list-games": cmd_list_games,
    }
    try:
        handlers[args.cmd](args.user, args)
    finally:
        chown_all(args.user)


if __name__ == "__main__":
    main()
