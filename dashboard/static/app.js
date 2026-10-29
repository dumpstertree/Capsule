/* Capsule dashboard frontend — vanilla JS, no build step.
   Serves both the login page and the capsule grid (single file, page-sniffed). */
"use strict";

const $ = (sel) => document.querySelector(sel);

let csrfToken = null;

async function api(path, opts = {}) {
  const headers = { "Content-Type": "application/json" };
  if (csrfToken) headers["X-CSRF-Token"] = csrfToken;
  const resp = await fetch(path, { ...opts, headers, credentials: "same-origin" });
  if (resp.status === 401) {
    window.location.href = "/login";
    throw new Error("unauthenticated");
  }
  return resp;
}

/* ---------- login page ---------- */

function initLogin() {
  $("#login-form").addEventListener("submit", async (ev) => {
    ev.preventDefault();
    const btn = $("#submit");
    const err = $("#error");
    err.textContent = "";
    btn.disabled = true;
    try {
      const resp = await fetch("/api/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        credentials: "same-origin",
        body: JSON.stringify({
          username: $("#username").value.trim(),
          password: $("#password").value,
        }),
      });
      const data = await resp.json().catch(() => ({}));
      if (resp.ok) {
        window.location.href = "/";
      } else {
        err.textContent = data.detail || "login failed";
        btn.disabled = false;
      }
    } catch (e) {
      err.textContent = "network error";
      btn.disabled = false;
    }
  });
}

/* ---------- dashboard page ---------- */

const stateLabel = (c) => {
  if (c.state === "failed") return "failed";
  if (c.state === "active" && c.sunshine_listening) return "running";
  if (c.state === "active") return "starting";
  return "stopped";
};

function renderCapsules(capsules) {
  const grid = $("#capsules");
  if (!capsules.length) {
    grid.innerHTML = '<div class="empty">No capsules found.</div>';
    return;
  }
  grid.innerHTML = "";
  for (const c of capsules) {
    const st = stateLabel(c);
    const card = document.createElement("div");
    card.className = "card";

    const sunUrl = c.sunshine_ui_url || `https://&lt;capsule-host&gt;:${c.ui_port}`;
    card.innerHTML = `
      <h2>${c.user} <span class="badge ${st}">${st}</span></h2>
      <div class="meta">
        display <b>:${c.index}</b> &nbsp; stream <b>:${c.stream_port}</b> &nbsp; web <b>:${c.ui_port}</b><br>
        <span class="dot ${c.xorg_up ? "on" : "off"}"></span>xorg
        &nbsp; <span class="dot ${c.sunshine_listening ? "on" : "off"}"></span>sunshine
        &nbsp; <span class="dot ${c.steam_running ? "on" : "off"}"></span>steam
      </div>
      <div class="actions">
        <button class="start" data-act="start" ${c.state === "active" ? "disabled" : ""}>On</button>
        <button class="stop" data-act="stop" ${c.state !== "active" ? "disabled" : ""}>Off</button>
        <button data-act="restart" ${c.state !== "active" ? "disabled" : ""}>Restart</button>
        <button data-act="manage">Games</button>
        <a href="${sunUrl}" target="_blank" rel="noopener">Sunshine UI ↗</a>
      </div>`;

    card.querySelectorAll("button[data-act]").forEach((btn) => {
      btn.addEventListener("click", async () => {
        if (btn.dataset.act === "manage") {
          openManager(c.user);
          return;
        }
        card.querySelectorAll("button").forEach((b) => (b.disabled = true));
        try {
          await api(`/api/capsules/${c.user}/${btn.dataset.act}`, {
            method: "POST",
            body: JSON.stringify({ action: btn.dataset.act }),
          });
        } finally {
          setTimeout(loadCapsules, 800);
        }
      });
    });
    grid.appendChild(card);
  }
}

function showNotice(text) {
  const n = $("#notice");
  if (!text) {
    n.style.display = "none";
    return;
  }
  n.textContent = text;
  n.style.display = "block";
}

async function loadCapsules() {
  try {
    const resp = await api("/api/capsules");
    const data = await resp.json();
    if (!resp.ok) {
      showNotice(data.detail || "failed to load capsules");
      return;
    }
    showNotice("");
    renderCapsules(data.capsules || []);
  } catch (e) {
    if (String(e.message) !== "unauthenticated") showNotice("connection lost");
  }
}

/* ---------- games & libraries manager ---------- */

const esc = (s) => String(s).replace(/[&<>"']/g, (ch) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
}[ch]));

let managerUser = null;
let browseFor = null;   // input element the picker fills
let browseExes = false; // also list .exe files (game picker mode)
let browsePath = "/";
let meta = null;

const mgr = (id) => document.getElementById(id);

function mgrNotice(text, isError = true) {
  const n = mgr("mgr-notice");
  if (!text) { n.style.display = "none"; return; }
  n.textContent = text;
  n.style.display = "block";
  n.classList.toggle("ok", !isError);
  n.style.background = isError ? "rgba(248,81,73,.08)" : "rgba(63,185,80,.08)";
  n.style.borderColor = isError ? "rgba(248,81,73,.35)" : "rgba(63,185,80,.35)";
  n.style.color = isError ? "var(--red)" : "var(--green)";
}

function renderLibs(libraries) {
  const ul = mgr("mgr-libs");
  if (!libraries.length) {
    ul.innerHTML = '<li class="dim">Only Steam\'s default library so far.</li>';
    return;
  }
  ul.innerHTML = libraries.map((l) => `
    <li>
      <span class="item-path" title="${esc(l.path)}">${esc(l.path)}</span>
      <button class="danger" data-remove-lib="${esc(l.path)}" title="Remove">✕</button>
    </li>`).join("");
  ul.querySelectorAll("[data-remove-lib]").forEach((btn) => {
    btn.addEventListener("click", () => mgrCall(
      "DELETE", "/libraries", { path: btn.dataset.removeLib }, loadLibraries));
  });
}

function renderGames(games) {
  const ul = mgr("mgr-games");
  if (!games.length) {
    ul.innerHTML = '<li class="dim">No non-Steam games imported yet.</li>';
    return;
  }
  ul.innerHTML = games.map((g) => `
    <li>
      <span><b>${esc(g.appname)}</b>
        <span class="item-path" title="${esc(g.exe)}">${esc(g.exe)}</span></span>
      <button class="danger" data-remove-game="${esc(g.appname)}" title="Remove">✕</button>
    </li>`).join("");
  ul.querySelectorAll("[data-remove-game]").forEach((btn) => {
    btn.addEventListener("click", () => mgrCall(
      "DELETE", "/games", { target: btn.dataset.removeGame }, loadGames));
  });
}

async function loadLibraries() {
  try {
    const resp = await api(`/api/capsules/${managerUser}/libraries`);
    const data = await resp.json();
    if (!resp.ok) { mgrNotice(data.detail || "failed to load libraries"); return; }
    renderLibs(data.libraries || []);
  } catch (e) { /* unauthenticated handles redirect */ }
}

async function loadGames() {
  try {
    const resp = await api(`/api/capsules/${managerUser}/games`);
    const data = await resp.json();
    if (!resp.ok) { mgrNotice(data.detail || "failed to load games"); return; }
    renderGames(data.games || []);
  } catch (e) { /* ignore */ }
}

async function mgrCall(method, sub, body, onDone) {
  mgrNotice("");
  const btns = document.querySelectorAll(".modal button");
  btns.forEach((b) => (b.disabled = true));
  try {
    const resp = await api(`/api/capsules/${managerUser}${sub}`, {
      method,
      body: JSON.stringify(body),
    });
    const data = await resp.json().catch(() => ({}));
    if (!resp.ok) {
      mgrNotice(data.detail || `${method} ${sub} failed`);
    } else {
      mgrNotice(data.output || data.detail || "done", false);
      if (onDone) onDone();
    }
  } catch (e) {
    if (String(e.message) !== "unauthenticated") mgrNotice("network error");
  } finally {
    btns.forEach((b) => (b.disabled = false));
  }
}

/* ---------- folder browser ---------- */

async function openBrowser(path) {
  browsePath = path;
  try {
    const resp = await api(`/api/browse?path=${encodeURIComponent(path)}`);
    const data = await resp.json();
    if (!resp.ok) { mgrNotice(data.detail || "cannot list folder"); return; }
    browsePath = data.path;
    mgr("browser-path").textContent = data.path;
    mgr("browser-up").disabled = !data.parent;
    const items = [];
    if (data.parent) {
      items.push(`<div class="browser-item up" data-cd="${esc(data.parent)}">..</div>`);
    }
    for (const d of data.dirs) {
      items.push(`<div class="browser-item" data-cd="${esc(d.path)}">📁 ${esc(d.name)}</div>`);
    }
    if (browseExes) {
      for (const f of data.exes) {
        items.push(`<div class="browser-item exe" data-exe="${esc(f.path)}">🎮 ${esc(f.name)}</div>`);
      }
      if (!data.exes.length && !data.dirs.length) {
        items.push('<div class="browser-item dim">empty folder</div>');
      }
    }
    const box = mgr("browser-dirs");
    box.innerHTML = items.join("");
    box.querySelectorAll("[data-cd]").forEach((el) =>
      el.addEventListener("click", () => openBrowser(el.dataset.cd)));
    box.querySelectorAll("[data-exe]").forEach((el) =>
      el.addEventListener("click", () => {
        browseFor.value = el.dataset.exe;
        closeBrowser();
      }));
  } catch (e) { /* ignore */ }
}

function closeBrowser() {
  mgr("browser").style.display = "none";
  browseFor = null;
}

function showBrowser(inputEl, withExes) {
  browseFor = inputEl;
  browseExes = withExes;
  mgr("browser").style.display = "block";
  mgr("browser-choose").style.display = withExes ? "none" : "";
  openBrowser(inputEl.value.trim() || "/");
}

/* ---------- manager open/close ---------- */

async function openManager(user) {
  managerUser = user;
  mgr("mgr-title").textContent = `${user} — libraries & games`;
  mgr("mgr-notice").style.display = "none";
  mgr("modal").style.display = "flex";
  closeBrowser();
  loadLibraries();
  loadGames();

  if (meta === null) {
    try {
      const resp = await api("/api/meta");
      meta = resp.ok ? await resp.json() : {};
    } catch (e) { meta = {}; }
  }
  const hints = [];
  if (meta && meta.importer === false) hints.push("capsule-import.sh not found on the server (set capsule_dir in its config.yaml).");
  if (meta && meta.sgdb_key === false) hints.push("No STEAMGRIDDB_API_KEY configured — imports work but without artwork/name matching.");
  mgr("mgr-hints").textContent = hints.join(" ");
}

function initManager() {
  mgr("mgr-close").addEventListener("click", () => (mgr("modal").style.display = "none"));
  mgr("modal").addEventListener("click", (ev) => {
    if (ev.target === mgr("modal")) mgr("modal").style.display = "none";
  });

  mgr("lib-add").addEventListener("click", () => {
    const path = mgr("lib-path").value.trim();
    if (!path) { mgrNotice("enter a folder path first"); return; }
    mgrCall("POST", "/libraries", { path }, () => {
      mgr("lib-path").value = "";
      loadLibraries();
    });
  });
  mgr("lib-browse").addEventListener("click", () => showBrowser(mgr("lib-path"), false));

  mgr("game-add").addEventListener("click", () => {
    const exe = mgr("game-exe").value.trim();
    if (!exe) { mgrNotice("pick the game .exe first"); return; }
    const body = {
      exe,
      name: mgr("game-name").value.trim(),
      startdir: "",
      sgdb_id: mgr("game-sgdb").value ? parseInt(mgr("game-sgdb").value, 10) : null,
      launch_options: mgr("game-opts").value.trim(),
      no_art: false,
    };
    mgrNotice("importing — Steam for this capsule will restart…", false);
    mgrCall("POST", "/games", body, () => {
      mgr("game-exe").value = "";
      mgr("game-name").value = "";
      mgr("game-sgdb").value = "";
      mgr("game-opts").value = "";
      loadGames();
    });
  });
  mgr("game-browse").addEventListener("click", () => showBrowser(mgr("game-exe"), true));

  const scan = (dryRun) => {
    const path = mgr("game-dir").value.trim();
    if (!path) { mgrNotice("pick the folder full of games first"); return; }
    mgrNotice(dryRun ? "scanning…" : "importing everything — Steam will restart, artwork downloads take a while…", false);
    mgrCall("POST", "/scan", { path, dry_run: dryRun }, () => {
      if (!dryRun) { mgr("game-dir").value = ""; loadGames(); }
    });
  };
  mgr("dir-scan").addEventListener("click", () => scan(false));
  mgr("dir-preview").addEventListener("click", () => scan(true));
  mgr("dir-browse").addEventListener("click", () => showBrowser(mgr("game-dir"), false));

  mgr("browser-up").addEventListener("click", () => {
    const up = browsePath.replace(/\/+$/, "").replace(/[^/]*$/, "");
    openBrowser(up || "/");
  });
  mgr("browser-choose").addEventListener("click", () => {
    if (browseFor) browseFor.value = browsePath;
    closeBrowser();
  });
  mgr("browser-cancel").addEventListener("click", closeBrowser);
}

async function initDashboard() {
  $("#logout").addEventListener("click", async () => {
    await fetch("/api/logout", { method: "POST", credentials: "same-origin" });
    window.location.href = "/login";
  });
  $("#refresh").addEventListener("click", loadCapsules);

  const me = await fetch("/api/me", { credentials: "same-origin" });
  if (!me.ok) {
    window.location.href = "/login";
    return;
  }
  const data = await me.json();
  csrfToken = data.csrf;

  initManager();
  await loadCapsules();
  setInterval(loadCapsules, 5000);
}

if ($("#login-form")) {
  initLogin();
} else {
  initDashboard();
}
