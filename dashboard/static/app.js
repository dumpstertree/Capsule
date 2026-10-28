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
        <a href="${sunUrl}" target="_blank" rel="noopener">Sunshine UI ↗</a>
      </div>`;

    card.querySelectorAll("button[data-act]").forEach((btn) => {
      btn.addEventListener("click", async () => {
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

  await loadCapsules();
  setInterval(loadCapsules, 5000);
}

if ($("#login-form")) {
  initLogin();
} else {
  initDashboard();
}
