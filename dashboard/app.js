const state = {
  hours: 1,
  autoRefresh: false,
  timer: null,
  statusTimer: null,
  refreshMs: 5000,
  tableRows: [],
  page: 0,
  pageSize: 80
};
const charts = {};
const defaults = {
  autoRefreshSeconds: 5,
  defaultHours: 1,
  periods: [
    { label: "15 m", hours: 0.25 },
    { label: "1 h", hours: 1 },
    { label: "6 h", hours: 6 },
    { label: "24 h", hours: 24 }
  ]
};

function $(id) { return document.getElementById(id); }

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

function pct(part, whole) {
  if (!whole) return "–";
  return Math.round((100 * part) / whole) + "%";
}

function fmtTime(iso) {
  try {
    const d = new Date(iso);
    return d.toLocaleString(undefined, { hour12: false });
  } catch {
    return iso || "";
  }
}

function fmtTick(iso) {
  try {
    const d = new Date(iso);
    return d.toLocaleTimeString(undefined, { hour12: false });
  } catch {
    return "";
  }
}

function met(v) {
  return Number(v) ? '<span class="ok">MET</span>' : '<span class="bad">NOT</span>';
}

function actionLabel(name) {
  const key = String(name || "").toLowerCase();
  const map = {
    hibernate: "Hibernate",
    sleep: "Sleep",
    displayoff: "Turn off display",
    lock: "Lock",
    shutdown: "Shut down"
  };
  return map[key] || (name ? String(name) : "–");
}

function lastFiredSample(rows) {
  for (let i = rows.length - 1; i >= 0; i--) {
    if (Number(rows[i].will_proceed)) return rows[i];
  }
  return null;
}

function applyLastAction(row) {
  const el = $("last-action");
  if (!el) return;
  if (!row) {
    el.textContent = "Last fired: none";
    el.classList.remove("on");
    return;
  }
  el.textContent = `Last fired: ${actionLabel(row.action)} · ${fmtTime(row.at)}`;
  el.classList.add("on");
}

function downsample(rows, maxPoints) {
  if (rows.length <= maxPoints) return rows;
  const out = [];
  const step = (rows.length - 1) / (maxPoints - 1);
  for (let i = 0; i < maxPoints; i++) {
    out.push(rows[Math.round(i * step)]);
  }
  return out;
}

const chartDefaults = {
  type: "line",
  options: {
    responsive: true,
    maintainAspectRatio: false,
    animation: false,
    interaction: { mode: "index", intersect: false },
    plugins: {
      legend: {
        labels: { color: "#9aa38c", boxWidth: 12 }
      }
    },
    scales: {
      x: {
        ticks: { color: "#9aa38c", maxRotation: 0, autoSkip: true, maxTicksLimit: 6 },
        grid: { color: "#2c3126" }
      },
      y: {
        beginAtZero: true,
        ticks: { color: "#9aa38c" },
        grid: { color: "#2c3126" }
      }
    }
  }
};

function upsertChart(id, labels, actual, limit, actualLabel, limitLabel) {
  const data = {
    labels,
    datasets: [
      {
        label: actualLabel,
        data: actual,
        borderColor: "#3caf4a",
        backgroundColor: "rgba(60, 175, 74, 0.12)",
        fill: true,
        tension: 0.15,
        pointRadius: 0,
        borderWidth: 2
      },
      {
        label: limitLabel,
        data: limit,
        borderColor: "#7a8f4a",
        borderDash: [5, 4],
        pointRadius: 0,
        borderWidth: 1.5,
        fill: false
      }
    ]
  };
  if (charts[id]) {
    charts[id].data.labels = labels;
    charts[id].data.datasets[0].data = actual;
    charts[id].data.datasets[1].data = limit;
    charts[id].update("none");
    return;
  }
  charts[id] = new Chart($(id), {
    type: chartDefaults.type,
    data,
    options: chartDefaults.options
  });
}

function applyDebugState(on) {
  const el = $("debug-state");
  if (!el) return;
  el.textContent = on ? "Debug mode: on" : "Debug mode: off";
  el.classList.toggle("on", !!on);
  el.classList.toggle("off", !on);
}

function applyDbPath(path) {
  const el = $("db-path");
  if (!el || !path) return;
  el.textContent = path;
  el.title = path;
}

async function refreshStatus() {
  const res = await fetch("/api/status");
  const data = await res.json();
  applyDebugState(!!data.debugMode);
  applyDbPath(data.dbPath);
}

async function load() {
  refreshStatus().catch(() => {});
  const hours = state.hours;
  const [samplesRes, summaryRes] = await Promise.all([
    fetch(`/api/samples?hours=${hours}&limit=20000`),
    fetch(`/api/summary?hours=${hours}`)
  ]);
  const samples = await samplesRes.json();
  const summary = await summaryRes.json();
  applyDbPath(summary.dbPath);
  const rows = Array.isArray(samples) ? samples : [];
  const lastFire = lastFiredSample(rows);
  applyLastAction(lastFire);
  $("kpis").innerHTML = [
    ["Samples", summary.count || 0],
    ["Would fire", pct(summary.proceed, summary.count)],
    ["Last fired", lastFire ? actionLabel(lastFire.action) : "–"],
    ["Idle MET", pct(summary.idleHit, summary.count)],
    ["Quiet MET", pct(summary.quietMet, summary.count)],
    ["Paused", pct(summary.paused, summary.count)]
  ].map(([label, value]) => `<div class="kpi"><b>${value}</b><span>${label}</span></div>`).join("");

  const chartRows = downsample(rows, 400);
  const labels = chartRows.map((r) => fmtTick(r.at));
  upsertChart("chart-idle", labels, chartRows.map((r) => (num(r.idle_ms) || 0) / 1000), chartRows.map((r) => num(r.idle_seconds)), "idle sec", "limit");
  upsertChart("chart-cpu", labels, chartRows.map((r) => num(r.cpu_percent)), chartRows.map((r) => num(r.cpu_limit)), "CPU %", "limit");
  upsertChart("chart-disk", labels, chartRows.map((r) => num(r.disk_percent)), chartRows.map((r) => num(r.disk_limit)), "disk %", "limit");
  upsertChart("chart-net", labels, chartRows.map((r) => num(r.net_kbps)), chartRows.map((r) => num(r.net_limit_kbps)), "KB/s", "limit");

  state.tableRows = rows.slice().reverse();
  const pages = Math.max(1, Math.ceil(state.tableRows.length / state.pageSize));
  if (state.page > pages - 1) state.page = pages - 1;
  if (state.page < 0) state.page = 0;
  renderTable();
}

function resultHtml(r) {
  if (Number(r.will_proceed)) {
    return `<span class="ok">fired · ${actionLabel(r.action)}</span>`;
  }
  if (Number(r.paused)) {
    return '<span class="muted">paused</span>';
  }
  return '<span class="bad">block</span>';
}

function sampleRowHtml(r) {
  const idleSec = num(r.idle_ms) != null ? Math.floor(num(r.idle_ms) / 1000) : "–";
  return `<tr>
      <td>${fmtTime(r.at)}</td>
      <td>${r.chosen_name || ""}</td>
      <td class="num">${idleSec}s ${met(r.idle_hit)}</td>
      <td>${met(r.quiet_met)}</td>
      <td>${met(r.power_met)}</td>
      <td>${met(r.network_met)}</td>
      <td class="num">${num(r.cpu_percent) == null ? "–" : Math.round(num(r.cpu_percent))}</td>
      <td class="num">${num(r.disk_percent) == null ? "–" : Math.round(num(r.disk_percent))}</td>
      <td class="num">${num(r.net_kbps) == null ? "–" : Math.round(num(r.net_kbps))}</td>
      <td>${resultHtml(r)}</td>
    </tr>`;
}

function renderTable() {
  const body = $("rows");
  const older = $("page-older");
  const newer = $("page-newer");
  const rows = state.tableRows;
  if (!rows.length) {
    applyLastAction(null);
    $("table-meta").textContent = "no samples in this range";
    body.innerHTML = `<tr><td class="empty" colspan="10">Debug mode writes samples into SQLite on a flush interval. Leave it on for a bit, then refresh.</td></tr>`;
    if (older) older.disabled = true;
    if (newer) newer.disabled = true;
    return;
  }
  const size = state.pageSize;
  const pages = Math.max(1, Math.ceil(rows.length / size));
  const start = state.page * size;
  const pageRows = rows.slice(start, start + size);
  const from = start + 1;
  const to = start + pageRows.length;
  $("table-meta").textContent = `${from}–${to} of ${rows.length}`;
  body.innerHTML = pageRows.map(sampleRowHtml).join("");
  if (older) older.disabled = state.page >= pages - 1;
  if (newer) newer.disabled = state.page <= 0;
  const scroller = body.closest(".scroll");
  if (scroller) scroller.scrollTop = 0;
}

function setAutoRefresh(on) {
  state.autoRefresh = on;
  $("autorefresh").checked = on;
  try { localStorage.setItem("idlehibernate-autorefresh", on ? "1" : "0"); } catch { }
  if (state.timer) {
    clearInterval(state.timer);
    state.timer = null;
  }
  if (on) {
    state.timer = setInterval(() => load().catch(() => {}), state.refreshMs);
  }
}

function applyPeriods(periods, defaultHours) {
  const host = $("ranges");
  host.innerHTML = "";
  let picked = false;
  for (const period of periods) {
    const hours = Number(period.hours);
    if (!Number.isFinite(hours) || hours <= 0) continue;
    const btn = document.createElement("button");
    btn.dataset.hours = String(hours);
    btn.textContent = period.label || `${hours} h`;
    if (!picked && hours === defaultHours) {
      btn.classList.add("on");
      picked = true;
    }
    host.appendChild(btn);
  }
  if (!picked && host.firstElementChild) {
    host.firstElementChild.classList.add("on");
  }
  const onBtn = host.querySelector("button.on");
  if (onBtn) state.hours = Number(onBtn.dataset.hours);
}

async function loadSettings() {
  let cfg = defaults;
  try {
    const res = await fetch("/settings.json", { cache: "no-store" });
    if (res.ok) {
      const parsed = await res.json();
      cfg = {
        autoRefreshSeconds: Number(parsed.autoRefreshSeconds) || defaults.autoRefreshSeconds,
        defaultHours: Number(parsed.defaultHours) || defaults.defaultHours,
        periods: Array.isArray(parsed.periods) && parsed.periods.length ? parsed.periods : defaults.periods
      };
    }
  } catch { }
  if (cfg.autoRefreshSeconds < 1) cfg.autoRefreshSeconds = 1;
  state.refreshMs = cfg.autoRefreshSeconds * 1000;
  state.hours = cfg.defaultHours;
  applyPeriods(cfg.periods, cfg.defaultHours);
}

$("ranges").addEventListener("click", (e) => {
  const btn = e.target.closest("button[data-hours]");
  if (!btn) return;
  state.hours = Number(btn.dataset.hours);
  state.page = 0;
  for (const b of $("ranges").querySelectorAll("button")) b.classList.toggle("on", b === btn);
  load().catch(console.error);
});

$("page-older").addEventListener("click", () => {
  const pages = Math.max(1, Math.ceil(state.tableRows.length / state.pageSize));
  if (state.page >= pages - 1) return;
  state.page += 1;
  renderTable();
});

$("page-newer").addEventListener("click", () => {
  if (state.page <= 0) return;
  state.page -= 1;
  renderTable();
});

$("autorefresh").addEventListener("change", (e) => {
  setAutoRefresh(e.target.checked);
});

loadSettings().then(() => {
  let saved = "0";
  try { saved = localStorage.getItem("idlehibernate-autorefresh") || "0"; } catch { }
  setAutoRefresh(saved === "1");
  load().catch(console.error);
  if (state.statusTimer) clearInterval(state.statusTimer);
  state.statusTimer = setInterval(() => refreshStatus().catch(() => {}), state.refreshMs);
}).catch(console.error);
