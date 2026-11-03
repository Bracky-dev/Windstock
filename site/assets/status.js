/* Bracky — static status page logic */
(function () {
  // Same-origin on purpose: a cross-origin fetch is blocked without CORS, and
  // /health on this domain belongs to headscale, not the game server.
  var HEALTH_URL = "/api/health";
  var LAST_UPDATED = "2026-08-21T01:00:00.000Z";
  var STORAGE_KEY = "bracky:status-history";
  var WINDOW_MS = 10 * 60 * 60 * 1000;

  var $ = function (id) { return document.getElementById(id); };

  function fmt(iso) {
    try {
      return new Date(iso).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
    } catch (e) { return iso; }
  }

  function loadHistory() {
    try {
      var raw = localStorage.getItem(STORAGE_KEY);
      var parsed = raw ? JSON.parse(raw) : [];
      if (!Array.isArray(parsed)) return [];
      var cutoff = Date.now() - WINDOW_MS;
      return parsed.filter(function (s) { return s && typeof s.t === "number" && s.t >= cutoff; }).slice(-600);
    } catch (e) { return []; }
  }

  var history = loadHistory();

  function pushSample(s) {
    var last = history[history.length - 1];
    if (last && Math.abs(last.t - s.t) < 500) return;
    history.push(s);
    var cutoff = Date.now() - WINDOW_MS;
    history = history.filter(function (x) { return x.t >= cutoff; }).slice(-600);
    try { localStorage.setItem(STORAGE_KEY, JSON.stringify(history)); } catch (e) {}
  }

  function renderChart() {
    var host = $("chart");
    if (!host) return;
    if (history.length < 2) {
      host.innerHTML = '<p class="text-sm text-muted-foreground">Collecting data… the chart appears after a couple of checks.</p>';
      return;
    }
    var width = 640, height = 140, padY = 12;
    var now = Date.now();
    var start = Math.min(history[0].t, now - WINDOW_MS);
    var span = Math.max(now - start, 1);
    var maxMs = 100;
    history.forEach(function (s) { if (s.ms && s.ms > maxMs) maxMs = s.ms; });
    var x = function (t) { return ((t - start) / span) * width; };
    var y = function (ms) { return height - padY - (ms / maxMs) * (height - padY * 2); };

    var parts = [];
    parts.push('<line x1="0" x2="' + width + '" y1="' + (height - padY) + '" y2="' + (height - padY) + '" class="stroke-border" stroke-width="1"/>');
    history.forEach(function (s) {
      if (s.online) return;
      parts.push('<rect x="' + Math.max(0, x(s.t) - 2) + '" y="0" width="4" height="' + height + '" class="fill-destructive/25"/>');
    });
    var pts = history.filter(function (s) { return s.ms !== null && s.ms !== undefined; })
      .map(function (s) { return x(s.t).toFixed(1) + "," + y(s.ms).toFixed(1); });
    if (pts.length > 1) {
      parts.push('<polyline points="' + pts.join(" ") + '" fill="none" class="stroke-primary" stroke-width="2" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke"/>');
    }
    history.forEach(function (s) {
      if (s.ms === null || s.ms === undefined) return;
      parts.push('<circle cx="' + x(s.t) + '" cy="' + y(s.ms) + '" r="2.5" class="' + (s.online ? "fill-primary" : "fill-destructive") + '"/>');
    });

    host.innerHTML =
      '<svg viewBox="0 0 ' + width + " " + height + '" class="h-36 w-full" role="img" aria-label="Response time over the last 10 hours" preserveAspectRatio="none">' +
      parts.join("") + "</svg>" +
      '<div class="mt-2 flex justify-between text-xs text-muted-foreground"><span>10h ago</span><span>peak ' +
      Math.round(maxMs) + " ms</span><span>now</span></div>";
  }

  function renderAlert(data) {
    var host = $("alert");
    if (!host) return;
    if (data.online) { host.innerHTML = ""; return; }
    host.innerHTML =
      '<div role="alert" aria-live="assertive" class="wind-alert mb-10">' +
      '<div class="wind-alert-inner rounded-xl border border-destructive/50 bg-destructive/10 p-5">' +
      '<p class="text-sm font-semibold tracking-tight text-destructive">Health check failed</p>' +
      '<p class="mt-1 text-sm text-muted-foreground">' + esc(data.error || "The health endpoint did not respond as expected.") + "</p>" +
      '<dl class="mt-3 grid gap-1 text-xs text-muted-foreground sm:grid-cols-2">' +
      '<div><dt class="inline uppercase tracking-[0.2em]">HTTP</dt> <dd class="inline font-medium">' +
      (data.httpStatus ? data.httpStatus : "no response") + "</dd></div>" +
      '<div><dt class="inline uppercase tracking-[0.2em]">Checked</dt> <dd class="inline font-medium">' +
      fmt(data.checkedAt) + "</dd></div></dl>" +
      (data.responseBody
        ? '<pre class="mt-3 max-h-40 overflow-auto rounded-lg border border-border/60 bg-card p-3 text-xs whitespace-pre-wrap">' + esc(data.responseBody) + "</pre>"
        : "") +
      "</div></div>";
  }

  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function render(data) {
    $("dot").className = "size-3 rounded-full " + (data.online
      ? "bg-primary shadow-[0_0_0_4px] shadow-primary/20"
      : "bg-destructive shadow-[0_0_0_4px] shadow-destructive/20");
    $("state").textContent = data.online ? "Online" : "Offline";
    $("blurb").textContent = data.online
      ? "The game server is up and accepting trainers. Log in from the game client with any trainer name."
      : "The game server is currently unreachable. It should be back shortly — no action needed on your side.";
    $("updated").textContent = fmt(LAST_UPDATED);
    $("checked").textContent = fmt(data.checkedAt);
    $("rt").textContent = data.responseTimeMs !== null ? data.responseTimeMs + " ms" : "—";
    renderAlert(data);
    renderChart();
  }

  async function check() {
    var online = false, responseTimeMs = null, error = null, httpStatus = null, responseBody = null;
    var started = performance.now();
    try {
      var controller = new AbortController();
      var timer = setTimeout(function () { controller.abort(); }, 6000);
      var res = await fetch(HEALTH_URL, { signal: controller.signal, cache: "no-store" });
      clearTimeout(timer);
      responseTimeMs = Math.round(performance.now() - started);
      httpStatus = res.status;
      var text = await res.text().catch(function () { return ""; });
      responseBody = text ? text.slice(0, 500) : null;
      if (res.ok) {
        var body = null;
        try { body = text ? JSON.parse(text) : null; } catch (e) { body = null; }
        online = !body || !body.status || body.status === "pass" || body.status === "ok";
        if (!online) error = 'Health endpoint reported status "' + body.status + '".';
      } else {
        error = "Health endpoint returned HTTP " + res.status + " " + res.statusText + ".";
      }
    } catch (e) {
      online = false;
      error = (e && e.name ? e.name + ": " : "") + (e && e.message ? e.message : "Unknown network error while contacting the health endpoint.");
    }
    var data = {
      online: online,
      checkedAt: new Date().toISOString(),
      responseTimeMs: responseTimeMs,
      error: error,
      httpStatus: httpStatus,
      responseBody: responseBody,
    };
    pushSample({ t: Date.now(), ms: responseTimeMs, online: online });
    render(data);
  }

  document.addEventListener("DOMContentLoaded", function () {
    var btn = $("checkNow");
    if (btn) {
      btn.addEventListener("click", async function () {
        btn.disabled = true;
        btn.textContent = "Checking…";
        try { await check(); } finally {
          btn.disabled = false;
          btn.textContent = "Check now";
        }
      });
    }
    check();
    setInterval(check, 10000);
  });
})();
