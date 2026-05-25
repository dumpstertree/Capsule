#!/usr/bin/env python3

from pathlib import Path
import json
import os
import shutil
import sys
import zlib

import requests
import vdf

from rapidfuzz import fuzz

###############################################################################
# ARGS
###############################################################################

if len(sys.argv) < 4:

    print("Usage:")
    print("  generate-shortcuts.py <games_path> <persistent_data_path> <steamgriddb_api_key>")

    sys.exit(1)

GAMES_DIR = Path(sys.argv[1])

PERSISTENT_DATA_PATH = Path(sys.argv[2])

STEAMGRIDDB_API_KEY = sys.argv[3]

###############################################################################
# VALIDATION
###############################################################################

if not GAMES_DIR.exists():

    print(f"Games path does not exist:")
    print(f"  {GAMES_DIR}")

    sys.exit(1)

###############################################################################
# PERSISTENT STORAGE
###############################################################################

METADATA_DIR = (
    PERSISTENT_DATA_PATH /
    "metadata"
)

ASSETS_DIR = (
    PERSISTENT_DATA_PATH /
    "assets"
)

METADATA_DIR.mkdir(
    parents=True,
    exist_ok=True
)

ASSETS_DIR.mkdir(
    parents=True,
    exist_ok=True
)

###############################################################################
# HELPERS
###############################################################################


def normalize(text: str):

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

    blacklist = [
        "setup",
        "uninstall",
        "updater",
        "launcher",
        "config",
        "crash",
        "helper",
        "benchmark",
        "redist",
        "redistributable",
        "vc_redist",
        "dxsetup",
    ]

    game_name = normalize(game_dir.name)

    best_score = -1
    best_exe = None

    for exe in exes:

        exe_name = normalize(exe.stem)

        if any(x in exe_name for x in blacklist):
            continue

        score = fuzz.ratio(
            game_name,
            exe_name
        )

        if score > best_score:
            best_score = score
            best_exe = exe

    if best_exe is None:
        best_exe = exes[0]

    print(f"  EXE: {best_exe.name}")
    print(f"  Match Score: {best_score}")

    return best_exe


###############################################################################
# APPID
###############################################################################


def generate_shortcut_appid(appname: str, exe: str):

    key = exe + appname

    crc = zlib.crc32(
        key.encode("utf-8")
    ) | 0x80000000

    if crc > 0x7FFFFFFF:
        crc -= 0x100000000

    return crc


###############################################################################
# METADATA
###############################################################################


def metadata_path(game_name):

    return (
        METADATA_DIR /
        f"{game_name}.json"
    )


def load_existing_metadata(game_name):

    path = metadata_path(game_name)

    if not path.exists():
        return None

    try:

        with open(path, "r") as f:
            return json.load(f)

    except Exception:

        return None


def save_metadata(
    game_folder,
    data
):

    output = metadata_path(game_folder)

    with open(output, "w") as f:

        json.dump(
            data,
            f,
            indent=4
        )


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

        r = requests.get(
            url,
            timeout=30
        )

        if r.status_code != 200:
            return False

        with open(output, "wb") as f:
            f.write(r.content)

        return True

    except Exception:
        return False


def ensure_assets(
    game_name,
    unsigned_appid,
    sgdb_id
):

    asset_dir = (
        ASSETS_DIR /
        str(unsigned_appid)
    )

    asset_dir.mkdir(
        parents=True,
        exist_ok=True
    )

    targets = [
        (
            "capsule",
            f"https://www.steamgriddb.com/api/v2/grids/game/{sgdb_id}?dimensions=460x215",
            asset_dir / "capsule.png"
        ),
        (
            "portrait",
            f"https://www.steamgriddb.com/api/v2/grids/game/{sgdb_id}?dimensions=600x900",
            asset_dir / "portrait.png"
        ),
        (
            "hero",
            f"https://www.steamgriddb.com/api/v2/heroes/game/{sgdb_id}",
            asset_dir / "hero.png"
        ),
        (
            "logo",
            f"https://www.steamgriddb.com/api/v2/logos/game/{sgdb_id}",
            asset_dir / "logo.png"
        ),
    ]

    for label, endpoint, output in targets:

        if output.exists():
            continue

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

                print(f"  Downloaded {label}")

        except Exception as e:

            print(f"  Failed {label}: {e}")

    return asset_dir


###############################################################################
# COPY ARTWORK INTO STEAM GRID
###############################################################################


def apply_artwork_to_grid(
    asset_dir,
    grid_dir,
    unsigned_appid
):

    mappings = [
        (
            asset_dir / "capsule.png",
            grid_dir / f"{unsigned_appid}.png"
        ),
        (
            asset_dir / "portrait.png",
            grid_dir / f"{unsigned_appid}p.png"
        ),
        (
            asset_dir / "hero.png",
            grid_dir / f"{unsigned_appid}_hero.png"
        ),
        (
            asset_dir / "logo.png",
            grid_dir / f"{unsigned_appid}_logo.png"
        ),
    ]

    for src, dst in mappings:

        if src.exists():

            shutil.copy2(
                src,
                dst
            )


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

    ############################################################################
    # PROCESS GAMES
    ############################################################################

    for game_dir in sorted(GAMES_DIR.iterdir()):

        if not game_dir.is_dir():
            continue

        print("")
        print(f"Game: {game_dir.name}")

        exe = find_best_exe(game_dir)

        if exe is None:
            print("  No EXE found")
            continue

        existing_metadata = load_existing_metadata(
            game_dir.name
        )

        if existing_metadata:

            print("  Existing metadata found")

            shortcut_appid = existing_metadata[
                "shortcut_appid"
            ]

            steam_appid = existing_metadata.get(
                "steam_appid"
            )

            official_name = existing_metadata.get(
                "official_name",
                game_dir.name
            )

            sgdb_id = existing_metadata.get(
                "steamgriddb_id"
            )

        else:

            print("  Generating new metadata")

            shortcut_appid = generate_shortcut_appid(
                game_dir.name,
                str(exe)
            )

            steam_appid = None
            official_name = game_dir.name
            sgdb_id = None

            sgdb_result = sgdb_search(
                game_dir.name
            )

            if sgdb_result:

                steam_appid = sgdb_result.get(
                    "steamAppId"
                )

                official_name = sgdb_result.get(
                    "name",
                    game_dir.name
                )

                sgdb_id = sgdb_result.get(
                    "id"
                )

            metadata = {
                "folder_name": game_dir.name,
                "shortcut_appid": shortcut_appid,
                "steam_appid": steam_appid,
                "official_name": official_name,
                "steamgriddb_id": sgdb_id,
                "exe": str(exe)
            }

            save_metadata(
                game_dir.name,
                metadata
            )

        unsigned_appid = (
            shortcut_appid &
            0xFFFFFFFF
        )

        ############################################################################
        # ARTWORK
        ############################################################################

        if sgdb_id:

            asset_dir = ensure_assets(
                game_dir.name,
                unsigned_appid,
                sgdb_id
            )

            apply_artwork_to_grid(
                asset_dir,
                grid_dir,
                unsigned_appid
            )

        ############################################################################
        # SHORTCUT ENTRY
        ############################################################################

        entries[str(index)] = {
            "appid": shortcut_appid,
            "appname": official_name,
            "exe": f'"{exe}"',
            "StartDir": str(game_dir),
            "icon": "",
            "ShortcutPath": "",
            "LaunchOptions": "%command%",
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

        index += 1

    ############################################################################
    # WRITE SHORTCUTS
    ############################################################################

    shortcuts = {
        "shortcuts": entries
    }

    print("")
    print("Writing shortcuts.vdf")

    with open(shortcuts_file, "wb") as f:

        vdf.binary_dump(
            shortcuts,
            f
        )

    print("Validating shortcuts.vdf")

    with open(shortcuts_file, "rb") as f:
        vdf.binary_load(f)

    ############################################################################
    # FIX OWNERSHIP
    ############################################################################

    steam_root = (
        home_dir /
        ".steam"
    )

    for root, dirs, files in os.walk(steam_root):

        try:
            shutil.chown(
                root,
                username,
                username
            )
        except:
            pass

        for d in dirs:

            path = os.path.join(root, d)

            try:
                shutil.chown(
                    path,
                    username,
                    username
                )
            except:
                pass

        for file in files:

            path = os.path.join(root, file)

            try:
                shutil.chown(
                    path,
                    username,
                    username
                )
            except:
                pass

    print("")
    print("Finished.")

print("")
print("==================================================")
print("All Users Processed")
print("==================================================")
