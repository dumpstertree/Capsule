#!/usr/bin/env python3
"""Capsule Dashboard — HTTPS control panel for Capsule gaming containers.

Run as root inside the capsule container (it shells out to /usr/local/bin/
capsulectl, which needs root). TLS + sessions + a single admin password.

Config: /etc/capsule/dashboard/config.yaml  (see install-dashboard.sh)
"""

from __future__ import annotations

import hashlib
import hmac
import ipaddress
import json
import logging
import os
import re
import secrets
import subprocess
import time
from pathlib import Path

import yaml
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

BASE_DIR = Path(os.environ.get("CAPSULE_DASHBOARD_DIR", "/etc/capsule/dashboard"))
CONFIG_FILE = BASE_DIR / "config.yaml"
CREDENTIALS_FILE = BASE_DIR / "credentials"
SECRET_FILE = BASE_DIR / "secret"
CERT_FILE = BASE_DIR / "cert.pem"
KEY_FILE = BASE_DIR / "key.pem"

CAPSULECTL = os.environ.get("CAPSULE_DASHBOARD_CAPSULECTL", "/usr/local/bin/capsulectl")
SESSION_COOKIE = "capsule_session"
STATIC_DIR = Path(__file__).resolve().parent / "static"

# scrypt parameters (stdlib, no extra deps): N=32768, r=8, p=1 (~128 MiB).
# maxmem must be raised explicitly or OpenSSL's default cap rejects the KDF.
SCRYPT_N, SCRYPT_R, SCRYPT_P, SCRYPT_MAXMEM, SALT_LEN, DK_LEN = 2**15, 8, 1, 256 * 1024 * 1024, 16, 32
LOGIN_WINDOW_SECS = 300
LOGIN_MAX_FAILURES = 8

log = logging.getLogger("capsule-dashboard")

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

class Config:
    bind: str = "0.0.0.0"
    port: int = 8443
    admin_user: str = "admin"
    capsule_host: str = ""  # host used in Sunshine links; empty = request host
    session_hours: int = 12
    capsulectl: str = CAPSULECTL
    capsule_dir: str = "/Capsule"  # repo checkout: capsule-import.sh lives here
    import_venv: str = "/opt/capsule-steam-venv"  # venv for capsule-import.py


def load_config() -> Config:
    cfg = Config()
    if CONFIG_FILE.exists():
        raw = yaml.safe_load(CONFIG_FILE.read_text()) or {}
        for key, value in raw.items():
            if hasattr(cfg, key):
                setattr(cfg, key, value)
    return cfg


CONFIG = load_config()


# ---------------------------------------------------------------------------
# Secrets: password hash, signing key, TLS cert
# ---------------------------------------------------------------------------

def hash_password(password: str) -> str:
    salt = secrets.token_bytes(SALT_LEN)
    dk = hashlib.scrypt(password.encode(), salt=salt, n=SCRYPT_N, r=SCRYPT_R, p=SCRYPT_P, dklen=DK_LEN, maxmem=SCRYPT_MAXMEM)
    return f"scrypt${SCRYPT_N}${SCRYPT_R}${SCRYPT_P}${salt.hex()}${dk.hex()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        scheme, n, r, p, salt_hex, dk_hex = stored.split("$")
        if scheme != "scrypt":
            return False
        dk = hashlib.scrypt(
            password.encode(),
            salt=bytes.fromhex(salt_hex),
            n=int(n), r=int(r), p=int(p), dklen=len(bytes.fromhex(dk_hex)),
            maxmem=SCRYPT_MAXMEM,
        )
        return hmac.compare_digest(dk.hex(), dk_hex)
    except (ValueError, TypeError):
        return False


def signing_secret() -> bytes:
    if not SECRET_FILE.exists():
        SECRET_FILE.parent.mkdir(parents=True, exist_ok=True)
        SECRET_FILE.write_bytes(secrets.token_bytes(32))
        os.chmod(SECRET_FILE, 0o600)
    return SECRET_FILE.read_bytes()


def ensure_tls_cert() -> None:
    if CERT_FILE.exists() and KEY_FILE.exists():
        return
    log.info("Generating self-signed TLS certificate at %s", CERT_FILE)
    # two-step: EC key then CSR->self-signed cert
    subprocess.run(
        ["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(KEY_FILE)],
        check=True, capture_output=True,
    )
    subprocess.run(
        [
            "openssl", "req", "-x509", "-key", str(KEY_FILE), "-sha256", "-days", "3650",
            "-subj", "/CN=capsule-dashboard/O=Capsule",
            "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
            "-out", str(CERT_FILE),
        ],
        check=True, capture_output=True,
    )
    os.chmod(KEY_FILE, 0o600)
    os.chmod(CERT_FILE, 0o644)


# ---------------------------------------------------------------------------
# Sessions (stateless HMAC-signed tokens)
# ---------------------------------------------------------------------------

def make_session_token(username: str) -> str:
    exp = int(time.time()) + CONFIG.session_hours * 3600
    payload = f"{username}.{exp}"
    sig = hmac.new(signing_secret(), payload.encode(), hashlib.sha256).hexdigest()
    return f"{payload}.{sig}"


def check_session_token(token: str) -> str | None:
    try:
        username, exp, sig = token.rsplit(".", 2)
        expected = hmac.new(signing_secret(), f"{username}.{exp}".encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(sig, expected):
            return None
        if int(exp) < time.time():
            return None
        return username
    except (ValueError, TypeError):
        return None


def csrf_for(token: str) -> str:
    return hmac.new(signing_secret(), f"csrf.{token}".encode(), hashlib.sha256).hexdigest()


# ---------------------------------------------------------------------------
# Login rate limiting (in-memory)
# ---------------------------------------------------------------------------

_login_failures: dict[str, list[float]] = {}


def client_ip(request: Request) -> str:
    return request.client.host if request.client else "unknown"


def login_allowed(ip: str) -> bool:
    now = time.time()
    fails = [t for t in _login_failures.get(ip, []) if now - t < LOGIN_WINDOW_SECS]
    _login_failures[ip] = fails
    return len(fails) < LOGIN_MAX_FAILURES


def note_login_failure(ip: str) -> None:
    _login_failures.setdefault(ip, []).append(time.time())


# ---------------------------------------------------------------------------
# capsulectl bridge
# ---------------------------------------------------------------------------

def capsulectl(*args: str, timeout: int = 60) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            [CONFIG.capsulectl, *args],
            capture_output=True, text=True, timeout=timeout,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 125, "", str(exc)


def valid_capsule_name(name: str) -> bool:
    return bool(re.fullmatch(r"[a-z][a-z0-9-]{0,30}", name))


# ---------------------------------------------------------------------------
# capsule-import bridge (Steam library folders + non-Steam games)
# ---------------------------------------------------------------------------

CAPSULE_CONFIG_FILE = Path("/etc/capsule/config")
IMPORT_TIMEOUT = 300  # add-game: Steam stop + SGDB downloads + Steam relaunch


def capsule_conf_value(key: str, default: str = "") -> str:
    try:
        for line in CAPSULE_CONFIG_FILE.read_text().splitlines():
            if line.startswith(f"{key}="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return default


def capsule_import(args: list[str], json_mode: bool = False,
                   timeout: int = IMPORT_TIMEOUT) -> tuple[dict | None, str]:
    """Run capsule-import.sh (handles Steam stop/relaunch + venv + ownership).
    Returns (parsed_or_raw_dict, error_message)."""
    script = Path(CONFIG.capsule_dir) / "capsule-import.sh"
    if not script.is_file():
        return None, f"{script} not found — set capsule_dir in {CONFIG_FILE} and re-run the installer"
    env = os.environ.copy()
    env["CAPSULE_PERSISTENT_DATA_PATH"] = capsule_conf_value("PERSISTENT_DATA_PATH")
    env["CAPSULE_SGDB_KEY"] = capsule_conf_value("STEAMGRIDDB_API_KEY")
    env["CAPSULE_IMPORT_VENV"] = CONFIG.import_venv
    if json_mode:
        env["CAPSULE_IMPORT_JSON"] = "1"
    try:
        proc = subprocess.run(
            ["bash", str(script), *args],
            capture_output=True, text=True, timeout=timeout, env=env,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, str(exc)
    combined = (proc.stdout + "\n" + proc.stderr).strip()
    if not json_mode:
        if proc.returncode != 0:
            return None, combined or "import tool failed"
        return {"ok": True, "output": combined}, ""
    if proc.returncode != 0:
        return None, combined or "import tool failed"
    try:
        return json.loads(proc.stdout), ""
    except json.JSONDecodeError:
        return None, f"bad JSON from import tool: {proc.stdout[:200]}"


def safe_text(value: str, max_len: int = 256) -> bool:
    return bool(value) and len(value) <= max_len and "\x00" not in value \
        and not any(c in value for c in "\r\n")


# ---------------------------------------------------------------------------
# Auth helpers / middleware
# ---------------------------------------------------------------------------

def current_session(request: Request) -> str | None:
    token = request.cookies.get(SESSION_COOKIE)
    if not token:
        return None
    return check_session_token(token)


def require_auth(request: Request) -> str | None:
    """Returns error response if unauthenticated, else None."""
    if not current_session(request):
        return JSONResponse({"detail": "not authenticated"}, status_code=401)
    return None


def require_csrf(request: Request) -> JSONResponse | None:
    token = request.cookies.get(SESSION_COOKIE)
    if not token:
        return JSONResponse({"detail": "not authenticated"}, status_code=401)
    if request.headers.get("x-csrf-token", "") != csrf_for(token):
        return JSONResponse({"detail": "bad CSRF token"}, status_code=403)
    return None


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

class LoginBody(BaseModel):
    username: str
    password: str


class ActionBody(BaseModel):
    action: str


class LibraryBody(BaseModel):
    path: str


class GameBody(BaseModel):
    exe: str
    name: str = ""
    startdir: str = ""
    sgdb_id: int | None = None
    launch_options: str = ""
    no_art: bool = False


class GameRemoveBody(BaseModel):
    target: str


def security_headers(response):
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "same-origin"
    response.headers["Content-Security-Policy"] = (
        "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
        "connect-src 'self'; frame-ancestors 'none'"
    )
    response.headers["Strict-Transport-Security"] = "max-age=31536000"
    return response


@app.get("/login", response_class=HTMLResponse)
def login_page():
    return security_headers(HTMLResponse((STATIC_DIR / "login.html").read_text()))


@app.post("/api/login")
def api_login(body: LoginBody, request: Request):
    ip = client_ip(request)
    if not login_allowed(ip):
        return JSONResponse({"detail": "too many failed attempts, wait a few minutes"}, status_code=429)

    stored = ""
    if CREDENTIALS_FILE.exists():
        stored = CREDENTIALS_FILE.read_text().strip()
    if not stored:
        return JSONResponse({"detail": "dashboard not configured"}, status_code=500)

    admin_user, admin_hash = stored.split(":", 1)
    if body.username != admin_user or not verify_password(body.password, admin_hash):
        note_login_failure(ip)
        log.warning("failed login from %s as %s", ip, body.username)
        return JSONResponse({"detail": "invalid credentials"}, status_code=401)

    token = make_session_token(body.username)
    resp = JSONResponse({"ok": True, "csrf": csrf_for(token)})
    resp.set_cookie(
        SESSION_COOKIE, token,
        secure=True, httponly=True, samesite="strict",
        max_age=CONFIG.session_hours * 3600, path="/",
    )
    log.info("login ok: %s from %s", body.username, ip)
    return security_headers(resp)


@app.post("/api/logout")
def api_logout():
    resp = JSONResponse({"ok": True})
    resp.delete_cookie(SESSION_COOKIE, path="/")
    return security_headers(resp)


@app.get("/api/me")
def api_me(request: Request):
    token = request.cookies.get(SESSION_COOKIE)
    if not token or not check_session_token(token):
        return JSONResponse({"authenticated": False}, status_code=401)
    return security_headers(JSONResponse({"authenticated": True, "csrf": csrf_for(token)}))


@app.get("/api/capsules")
def api_capsules(request: Request):
    if err := require_auth(request):
        return security_headers(err)

    rc, out, err_text = capsulectl("--json", "list")
    if rc != 0:
        return security_headers(JSONResponse(
            {"detail": f"capsulectl failed: {err_text.strip() or out.strip()}"}, status_code=500))
    try:
        capsules = json.loads(out or "[]")
    except json.JSONDecodeError as exc:
        log.error("bad capsulectl JSON: %s | raw=%r", exc, out[:400])
        return security_headers(JSONResponse(
            {"detail": f"bad capsulectl JSON: {exc} | raw: {out[:200]}"}, status_code=500))

    # sunshine links: configured host wins, else request host (no port)
    host = CONFIG.capsule_host
    if not host:
        host = request.headers.get("x-forwarded-host") or request.headers.get("host", "").split(":")[0]
    if host:
        # only allow host literals (IP/hostname) — never attacker-controlled URLs
        try:
            ipaddress.ip_address(host)
        except ValueError:
            if not all(part.isalnum() or part in ".-" for part in host):
                host = ""
    for cap in capsules:
        cap["sunshine_ui_url"] = f"https://{host}:{cap.get('ui_port', 0)}" if host else ""
        cap["moonlight_host"] = host

    return security_headers(JSONResponse({"capsules": capsules}))


# --- library folders & non-Steam games (must be registered before the
# --- generic /api/capsules/{name}/{action} route, which would also match) ---

def check_capsule(request: Request, name: str, csrf: bool = False):
    err = require_auth(request)
    if not err and csrf:
        err = require_csrf(request)
    if not err and not valid_capsule_name(name):
        err = JSONResponse({"detail": "invalid capsule name"}, status_code=400)
    return err


@app.get("/api/capsules/{name}/libraries")
def api_libraries_list(name: str, request: Request):
    if err := check_capsule(request, name):
        return security_headers(err)
    data, err = capsule_import(["list-libraries", name], json_mode=True, timeout=60)
    if err:
        return security_headers(JSONResponse({"detail": err}, status_code=500))
    return security_headers(JSONResponse(data))


@app.post("/api/capsules/{name}/libraries")
def api_libraries_add(name: str, body: LibraryBody, request: Request):
    if err := check_capsule(request, name, csrf=True):
        return security_headers(err)
    if not body.path.startswith("/") or not safe_text(body.path):
        return security_headers(JSONResponse(
            {"detail": "path must be absolute (e.g. /mnt/games)"}, status_code=400))
    data, err = capsule_import(["add-library", name, body.path.rstrip("/") or "/"])
    if err:
        return security_headers(JSONResponse({"detail": err}, status_code=500))
    log.info("capsule %s: added library %s", name, body.path)
    return security_headers(JSONResponse(data))


@app.delete("/api/capsules/{name}/libraries")
def api_libraries_remove(name: str, body: LibraryBody, request: Request):
    if err := check_capsule(request, name, csrf=True):
        return security_headers(err)
    if not body.path.startswith("/") or not safe_text(body.path):
        return security_headers(JSONResponse({"detail": "invalid path"}, status_code=400))
    data, err = capsule_import(["remove-library", name, body.path.rstrip("/") or "/"])
    if err:
        return security_headers(JSONResponse({"detail": err}, status_code=500))
    log.info("capsule %s: removed library %s", name, body.path)
    return security_headers(JSONResponse(data))


@app.get("/api/capsules/{name}/games")
def api_games_list(name: str, request: Request):
    if err := check_capsule(request, name):
        return security_headers(err)
    data, err = capsule_import(["list-games", name], json_mode=True, timeout=60)
    if err:
        return security_headers(JSONResponse({"detail": err}, status_code=500))
    return security_headers(JSONResponse(data))


@app.post("/api/capsules/{name}/games")
def api_games_add(name: str, body: GameBody, request: Request):
    if err := check_capsule(request, name, csrf=True):
        return security_headers(err)
    if not body.exe.startswith("/") or not safe_text(body.exe):
        return security_headers(JSONResponse(
            {"detail": "exe must be an absolute path to the game executable"}, status_code=400))
    for value, label, limit in [
        (body.name, "name", 120),
        (body.startdir, "startdir", 512),
        (body.launch_options, "launch options", 256),
    ]:
        if value and not safe_text(value, limit):
            return security_headers(JSONResponse({"detail": f"invalid {label}"}, status_code=400))
    if body.sgdb_id is not None and not (0 < body.sgdb_id <= 10**9):
        return security_headers(JSONResponse({"detail": "invalid SteamGridDB id"}, status_code=400))

    args = ["add-game", name, body.exe]
    if body.name:
        args += ["--name", body.name]
    if body.startdir:
        args += ["--startdir", body.startdir]
    if body.sgdb_id:
        args += ["--sgdb-id", str(body.sgdb_id)]
    if body.launch_options:
        args += ["--launch-options", body.launch_options]
    if body.no_art:
        args.append("--no-art")

    data, err = capsule_import(args)
    if err:
        return security_headers(JSONResponse({"detail": err}, status_code=500))
    log.info("capsule %s: imported game %s", name, body.exe)
    return security_headers(JSONResponse(data))


@app.delete("/api/capsules/{name}/games")
def api_games_remove(name: str, body: GameRemoveBody, request: Request):
    if err := check_capsule(request, name, csrf=True):
        return security_headers(err)
    if not safe_text(body.target, 200):
        return security_headers(JSONResponse({"detail": "invalid target"}, status_code=400))
    data, err = capsule_import(["remove-game", name, body.target])
    if err:
        return security_headers(JSONResponse({"detail": err}, status_code=500))
    log.info("capsule %s: removed game %s", name, body.target)
    return security_headers(JSONResponse(data))


@app.get("/api/browse")
def api_browse(request: Request, path: str = "/"):
    """Server-side folder picker for the library/game forms (admin-only)."""
    if err := require_auth(request):
        return security_headers(err)
    if not path.startswith("/") or not safe_text(path, 512):
        return security_headers(JSONResponse({"detail": "invalid path"}, status_code=400))
    target = Path(path)
    try:
        if not target.is_dir():
            return security_headers(JSONResponse({"detail": "not a directory"}, status_code=400))
        entries = sorted(target.iterdir(), key=lambda p: p.name.lower())
        dirs = [d for d in entries if not d.name.startswith(".") and d.is_dir()][:300]
        exes = [f for f in entries
                if not f.name.startswith(".") and f.is_file()
                and f.suffix.lower() == ".exe"][:300]
    except PermissionError:
        return security_headers(JSONResponse({"detail": f"permission denied: {path}"}, status_code=403))
    except OSError as exc:
        return security_headers(JSONResponse({"detail": str(exc)}, status_code=500))
    return security_headers(JSONResponse({
        "path": str(target),
        "parent": None if str(target) == "/" else str(target.parent),
        "dirs": [{"name": d.name, "path": str(d)} for d in dirs],
        "exes": [{"name": f.name, "path": str(f)} for f in exes],
    }))


@app.post("/api/capsules/{name}/{action}")
def api_capsule_action(name: str, action: str, body: ActionBody, request: Request):
    if err := require_auth(request):
        return security_headers(err)
    if err := require_csrf(request):
        return security_headers(err)
    if not valid_capsule_name(name):
        return security_headers(JSONResponse({"detail": "invalid capsule name"}, status_code=400))
    if action not in {"start", "stop", "restart"}:
        return security_headers(JSONResponse({"detail": "invalid action"}, status_code=400))

    rc, out, err_text = capsulectl(action, name)
    payload = {"ok": rc == 0, "output": (out + err_text).strip()}
    status = 200 if rc == 0 else 500
    log.info("capsule %s %s -> rc=%s", name, action, rc)
    return security_headers(JSONResponse(payload, status_code=status))


@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    if not current_session(request):
        return security_headers(HTMLResponse(
            "<!doctype html><meta http-equiv='refresh' content='0;url=/login'>", status_code=200))
    return security_headers(HTMLResponse((STATIC_DIR / "index.html").read_text()))


@app.get("/api/meta")
def api_meta(request: Request):
    """Feature flags for the UI (importer present? SteamGridDB key set?)."""
    if err := require_auth(request):
        return security_headers(err)
    script = Path(CONFIG.capsule_dir) / "capsule-import.sh"
    return security_headers(JSONResponse({
        "importer": script.is_file(),
        "sgdb_key": bool(capsule_conf_value("STEAMGRIDDB_API_KEY")),
    }))


@app.get("/healthz")
def healthz():
    return {"ok": True}


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

def main() -> None:
    import uvicorn

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    BASE_DIR.mkdir(parents=True, exist_ok=True)
    ensure_tls_cert()
    log.info("Capsule dashboard on https://%s:%s", CONFIG.bind, CONFIG.port)
    uvicorn.run(
        app,
        host=CONFIG.bind,
        port=int(CONFIG.port),
        ssl_certfile=str(CERT_FILE),
        ssl_keyfile=str(KEY_FILE),
        access_log=False,
        server_header=False,
    )


if __name__ == "__main__":
    main()
