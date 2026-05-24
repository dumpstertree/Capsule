#!/usr/bin/env python3

from pathlib import Path
import shutil
import zlib
import requests
import vdf

from rapidfuzz import fuzz

###############################################################################
# CONFIG
###############################################################################

GAMES_DIR = Path("/games/Microsoft_Windows")

STEAMGRIDDB_API_KEY = "PUT_API_KEY_HERE"

###############################################################################
# HELPERS
###############################################################################


def normalize(text: str) -> str:
    return (
        text.lower()
        .replace("_", " ")
        .replace("-", " ")
        .replace(".", " ")
    )


def find_best_exe(game_dir: Path):

    exes = list(game_dir.rglob("*.exe"))

    if not exes:
        return None

    game_name = normalize(game_dir.name)

    blacklist = [
        "setup",
        "uninstall",
        "crash",
        "updater",
        "config",
        "launcher",
        "helper",
        "benchmark",
        "redist",
        "redistributable",
        "vc_redist",
        "dxsetup",
    ]

    best_score = -1
    best_exe = None

    for exe in exes:

        exe_name = normalize(exe.stem)

        if any(x in exe_name for x in blacklist):
            continue

        score = fuzz.ratio(game_name, exe_name)

        if score > best_score:
            best_score = score
            best_exe = exe

    if best_exe is None:
        best_exe = exes[0]

    print(f"  EXE: {best_exe.name}")
    print(f"  Match Score: {best_score}")

    return best_exe


def generate_appid(exe_path: str):

    appid = zlib.crc32(exe_path.encode())

    if appid > 0x7FFFFFFF:
        appid -= 0x100000000

    return abs(appid)


###############################################################################
# STEAMGRIDDB
###############################################################################


def sgdb_headers():
    return {
        "Authorization": f"Bearer {STEAMGRIDDB_API_KEY}"
    }


def sgdb_search(game_name):

    try:

        url = (
            "https://www.steamgriddb.com/api/v2/search/autocomplete/"
            + game_name
        )

        r = requests.get(
            url,
            headers=sgdb_headers(),
            timeout=20
        )

        data = r.json()

        if not data.get("success"):
            return None

        items = data.get("data", [])

        if not items:
            return None

        return items[0]

    except Exception as e:
        print(f"  SteamGridDB search failed: {e}")
        return None


def download_image(url: str, output: Path):

    try:

        r = requests.get(url, timeout=30)

        if r.status_code != 200:
            return False

        with open(output, "wb") as f:
            f.write(r.content)

        return True

    except Exception:
        return False


def fetch_artwork(game_name, appid, grid_dir: Path):

    result = sgdb_search(game_name)

    if not result:
        print("  No SteamGridDB match")
        return

    game_id = result["id"]

    print(f"  SteamGridDB Match: {result['name']}")

    endpoints = [
        (
            f"https://www.steamgriddb.com/api/v2/grids/game/{game_id}?dimensions=600x900",
            grid_dir / f"{appid}p.png",
            "portrait"
        ),
        (
            f"https://www.steamgriddb.com/api/v2/grids/game/{game_id}?dimensions=460x215",
            grid_dir / f"{appid}.png",
            "capsule"
        ),
        (
            f"https://www.steamgriddb.com/api/v2/heroes/game/{game_id}",
            grid_dir / f"{appid}_hero.png",
            "hero"
        ),
        (
            f"https://www.steamgriddb.com/api/v2/logos/game/{game_id}",
            grid_dir / f"{appid}_logo.png",
            "logo"
        ),
    ]

    for endpoint, output, kind in endpoints:

        try:

            r = requests.get(
                endpoint,
                headers=sgdb_headers(),
                timeout=20
            )

            data = r.json()

            if not data.get("success"):
                continue

            items = data.get("data", [])

            if not items:
                continue

            image_url = items[0]["url"]

            if download_image(image_url, output):
                print(f"    Downloaded {kind}")

        except Exception as e:
            print(f"    Failed {kind}: {e}")


###############################################################################
# PROCESS USERS
###############################################################################

for home_dir in Path("/home").iterdir():

    if not home_dir.is_dir():
        continue

    username = home_dir.name

    print("")
    print("==================================================")
    print(f"Processing User: {username}")
    print("==================================================")

    steam_userdata = (
        home_dir /
        ".steam/steam/userdata"
    )

    if not steam_userdata.exists():
        print("No Steam userdata")
        continue

    userdata_dirs = [
        p for p in steam_userdata.iterdir()
        if p.is_dir()
    ]

    if not userdata_dirs:
        print("No userdata dirs")
        continue

    latest_user = max(
        userdata_dirs,
        key=lambda p: (
            p / "config"
        ).stat().st_mtime
    )

    config_dir = latest_user / "config"

    shortcuts_file = (
        config_dir /
        "shortcuts.vdf"
    )

    grid_dir = (
        config_dir /
        "grid"
    )

    grid_dir.mkdir(
        parents=True,
        exist_ok=True
    )

    if shortcuts_file.exists():

        backup = shortcuts_file.with_suffix(
            ".vdf.bak"
        )

        shutil.copy2(
            shortcuts_file,
            backup
        )

    entries = {}

    index = 0

    for game_dir in sorted(GAMES_DIR.iterdir()):

        if not game_dir.is_dir():
            continue

        print("")
        print(f"Game: {game_dir.name}")

        exe = find_best_exe(game_dir)

        if exe is None:
            print("  No EXE found")
            continue

        appid = generate_appid(str(exe))

        compat_dir = (
            home_dir /
            ".steam/steam/steamapps/compatdata" /
            str(appid)
        )

        compat_dir.mkdir(
            parents=True,
            exist_ok=True
        )

        launch_options = (
            f'STEAM_COMPAT_DATA_PATH="{compat_dir}" '
            f'STEAM_COMPAT_CLIENT_INSTALL_PATH="{home_dir}/.steam/steam" '
            f'%command%'
        )

        entries[str(index)] = {
            "appname": game_dir.name,
            "exe": f'"{exe}"',
            "StartDir": str(game_dir),
            "icon": "",
            "ShortcutPath": "",
            "LaunchOptions": launch_options,
            "IsHidden": 0,
            "AllowDesktopConfig": 1,
            "AllowOverlay": 1,
            "OpenVR": 0,
            "Devkit": 0,
            "DevkitGameID": "",
            "DevkitOverrideAppID": 0,
            "LastPlayTime": 0,
            "FlatpakAppID": "",
            "tags": {
                "0": "Non-Steam"
            }
        }

        fetch_artwork(
            game_dir.name,
            appid,
            grid_dir
        )

        index += 1

    shortcuts = {
        "shortcuts": entries
    }

    print("")
    print("Writing shortcuts.vdf")

    with open(shortcuts_file, "wb") as f:
        vdf.binary_dump(shortcuts, f)

    print("Validating VDF")

    with open(shortcuts_file, "rb") as f:
        vdf.binary_load(f)

    shutil.chown(
        shortcuts_file,
        username,
        username
    )

    shutil.chown(
        grid_dir,
        username,
        username
    )

    print("Done.")
