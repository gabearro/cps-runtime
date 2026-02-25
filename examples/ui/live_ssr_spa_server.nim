## Live SSR SPA server
##
## Demonstrates:
## - SSR + hydration for an SPA shell
## - server-side runtime re-render of a component fragment
## - HTTP fetch + SSE invalidation + WebSocket runtime events
##
## Usage:
##   bash scripts/build_ui_wasm.sh examples/ui/live_ssr_spa_app.nim examples/ui/live_ssr_spa_app.wasm
##   nim c --mm:arc -d:release -o:examples/ui/live_ssr_spa_server examples/ui/live_ssr_spa_server.nim
##   ./examples/ui/live_ssr_spa_server
##
## Env vars:
##   CPS_UI_HOST (default 127.0.0.1)
##   CPS_UI_PORT (default 8084)

import std/[os, strutils, times]
import cps/httpserver
import cps/http/server/dsl
import cps/ui
import live_ssr_spa_app

var serverRenderSeq = 0

proc parsePort(raw: string, fallback: int): int =
  if raw.len == 0:
    return fallback
  try:
    let parsed = parseInt(raw)
    if parsed <= 0 or parsed > 65535:
      return fallback
    parsed
  except ValueError:
    fallback

proc nextServerRenderSeq(): int =
  inc serverRenderSeq
  serverRenderSeq

proc renderRuntimeServerComponent(seq: int): string =
  let stamp = now().format("yyyy-MM-dd HH:mm:ss")
  renderToString(
    proc(): VNode =
      element(
        "article",
        attrs = @[
          attr("class", "rounded-2xl border border-emerald-300 bg-emerald-50 p-4 text-emerald-900 shadow-sm"),
          attr("data-testid", "server-runtime-component"),
          attr("data-seq", $seq)
        ],
        children = @[
          element("p", attrs = @[attr("class", "text-xs font-bold uppercase tracking-[0.14em]")], children = @[text("Runtime Server Render")]),
          element("h2", attrs = @[attr("class", "mt-1 text-xl font-black tracking-tight")], children = @[text("Server Render #" & $seq)]),
          element("p", attrs = @[attr("class", "mt-2 text-sm")], children = @[text("Rendered on server at " & stamp)]),
          element("p", attrs = @[attr("class", "mt-1 text-xs opacity-80")], children = @[text("This fragment was rendered with cps/ui renderToString during runtime.")])
        ]
      )
  )

proc runtimeSummary(): string =
  "runtime-summary seq=" & $serverRenderSeq & " at=" & now().format("yyyy-MM-dd HH:mm:ss")

proc pageHtml(): string =
  let shellHtml = renderToString(liveSsrSpaRoot)
  let initialSeq = nextServerRenderSeq()
  let initialServerFragment = renderRuntimeServerComponent(initialSeq)

  result = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Live SSR SPA Demo</title>
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
  <link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500&family=Outfit:wght@300;400;500;600;700;800;900&display=swap" rel="stylesheet" />
  <style>
    :root { color-scheme: light; }
    body { margin: 0; font-family: Outfit, sans-serif; background: linear-gradient(180deg, #f8fafc 0%, #eef2ff 100%); color: #0f172a; }
    .frame { max-width: 960px; margin: 0 auto; padding: 24px 16px 40px; }
    .stack { display: grid; gap: 16px; }
    .mono { font-family: "JetBrains Mono", monospace; }
    .panel { border: 1px solid #cbd5e1; border-radius: 16px; background: #ffffffcc; padding: 14px; box-shadow: 0 10px 30px rgba(15, 23, 42, 0.06); }
  </style>
</head>
<body>
  <div class="frame stack">
    <div id="app">__SHELL_HTML__</div>
    <section class="panel">
      <p style="margin:0;font-size:11px;font-weight:800;letter-spacing:0.12em;text-transform:uppercase;color:#64748b;">
        Server Runtime Component
      </p>
      <p style="margin:6px 0 10px;font-size:13px;color:#334155;">
        Updated by SSE invalidation events. HTML is re-rendered on server and replaced in-place.
      </p>
      <div id="server-runtime-slot">__SERVER_FRAGMENT__</div>
    </section>
    <section class="panel mono" id="runtime-status" data-testid="runtime-status">status: booting</section>
    <section class="panel mono" data-testid="transport-status">
      <p id="fetch-status" style="margin:0;">fetch: idle</p>
      <p id="sse-status" style="margin:8px 0 0;">sse: idle</p>
      <p id="ws-status" style="margin:8px 0 0;">ws: idle</p>
      <p id="ws-last" style="margin:8px 0 0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">ws-last: -</p>
    </section>
  </div>

  <script type="module">
    import { loadNimUiWasm } from "/src/cps/ui/js/loader.js";

    const statusEl = document.getElementById("runtime-status");
    const slot = document.getElementById("server-runtime-slot");
    const fetchEl = document.getElementById("fetch-status");
    const sseEl = document.getElementById("sse-status");
    const wsEl = document.getElementById("ws-status");
    const wsLastEl = document.getElementById("ws-last");

    function setStatus(text) {
      if (statusEl) statusEl.textContent = "status: " + text;
    }

    function setLine(el, prefix, text) {
      if (el) el.textContent = prefix + text;
    }

    async function refreshServerFragment(reason) {
      const res = await fetch("/ssr/runtime/component?ts=" + Date.now(), { cache: "no-store" });
      if (!res.ok) throw new Error("fragment fetch failed: " + res.status);
      const html = await res.text();
      slot.innerHTML = html;
      const seq = slot.querySelector("[data-seq]")?.getAttribute("data-seq") ?? "?";
      setStatus("rendered fragment seq=" + seq + " (" + reason + ")");
    }

    async function refreshSummary(reason) {
      const res = await fetch("/api/runtime/summary?ts=" + Date.now(), { cache: "no-store" });
      if (!res.ok) throw new Error("summary fetch failed: " + res.status);
      const text = await res.text();
      setLine(fetchEl, "fetch: ", text + " (" + reason + ")");
    }

    await loadNimUiWasm("/ui/live_ssr_spa_app.wasm?v=live-ssr-spa-20260219", { selector: "#app", mode: "hydrate" });
    setStatus("spa hydrated; waiting for server events");
    setLine(sseEl, "sse: ", "connecting");
    setLine(wsEl, "ws: ", "connecting");
    await refreshSummary("boot");

    const stream = new EventSource("/events/ssr/runtime");
    stream.addEventListener("message", async (ev) => {
      try {
        setLine(sseEl, "sse: ", "message " + (ev.data || "-"));
        await refreshServerFragment(ev.data || "sse");
        await refreshSummary("sse");
      } catch (err) {
        setStatus("update error: " + (err?.message || String(err)));
        setLine(sseEl, "sse: ", "error");
      }
    });
    stream.addEventListener("error", () => {
      setStatus("stream reconnecting");
      setLine(sseEl, "sse: ", "reconnecting");
    });

    const wsProto = location.protocol === "https:" ? "wss://" : "ws://";
    const ws = new WebSocket(wsProto + location.host + "/ws/ssr/runtime");
    ws.addEventListener("open", () => {
      setLine(wsEl, "ws: ", "open");
      ws.send("live-ssr-client:ready");
    });
    ws.addEventListener("message", (ev) => {
      setLine(wsLastEl, "ws-last: ", String(ev.data || "-"));
    });
    ws.addEventListener("close", (ev) => {
      setLine(wsEl, "ws: ", "closed:" + ev.code);
    });
    ws.addEventListener("error", () => {
      setLine(wsEl, "ws: ", "error");
    });
  </script>
</body>
</html>
"""

  result = result.replace("__SHELL_HTML__", shellHtml)
  result = result.replace("__SERVER_FRAGMENT__", initialServerFragment)

when isMainModule:
  let host = getEnv("CPS_UI_HOST", "127.0.0.1")
  let port = parsePort(getEnv("CPS_UI_PORT", "8084"), 8084)

  let uiDir = getAppDir()
  let repoRoot = normalizedPath(uiDir / ".." / "..")
  let srcDir = repoRoot / "src"

  let handler = router:
    get "/":
      redirect "/ssr/live"

    get "/ssr/live":
      html 200, pageHtml()

    get "/ssr/runtime/component":
      html 200, renderRuntimeServerComponent(nextServerRenderSeq())

    get "/api/runtime/summary":
      respond 200, runtimeSummary()

    ws "/ws/ssr/runtime":
      await sendText("ws-connected seq=" & $nextServerRenderSeq())
      var seq = nextServerRenderSeq()
      while true:
        await cpsSleep(1600)
        await sendText("ws-tick seq=" & $seq & " at=" & now().format("HH:mm:ss"))
        seq = nextServerRenderSeq()

    sse "/events/ssr/runtime":
      var seq = nextServerRenderSeq()
      while true:
        await sendEvent("invalidate:" & $seq, event = "message", id = $seq)
        await cpsSleep(1200)
        seq = nextServerRenderSeq()

    get "/api/health":
      respond 200, "ok"

    serveStatic "/ui", uiDir
    serveStatic "/src", srcDir

  echo "Live SSR SPA demo server"
  echo "  host: " & host
  echo "  port: " & $port
  echo "  url:  http://" & host & ":" & $port & "/ssr/live"
  serve(handler, port = port, host = host)
