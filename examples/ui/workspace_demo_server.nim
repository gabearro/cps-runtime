## CPS HTTP server for the workspace showcase (HTTP fetch + WebSocket + SSE + SSR).
##
## Usage:
##   bash scripts/build_ui_wasm.sh examples/ui/workspace_app.nim examples/ui/workspace_app.wasm
##   nim c --mm:arc -d:release -o:examples/ui/workspace_demo_server examples/ui/workspace_demo_server.nim
##   ./examples/ui/workspace_demo_server
##
## Pages:
##   /workspace/ssr  -> SSR HTML + hydrate()
##   /workspace/spa  -> client mount (no SSR)
##
## Env vars:
##   CPS_UI_HOST (default 127.0.0.1)
##   CPS_UI_PORT (default 8083)
##   CPS_UI_USE_TLS (default false)
##   CPS_UI_TLS_CERT (required when CPS_UI_USE_TLS=true)
##   CPS_UI_TLS_KEY  (required when CPS_UI_USE_TLS=true)
##   CPS_UI_ENABLE_HTTP2 (default true)

import std/[os, strutils]
import cps/httpserver
import cps/http/server/dsl
import cps/ui/ssr
import workspace_app

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

proc parseBool(raw: string, fallback: bool): bool =
  if raw.len == 0:
    return fallback
  case raw.toLowerAscii()
  of "1", "true", "yes", "on":
    true
  of "0", "false", "no", "off":
    false
  else:
    fallback

proc workspacePage(hydrateMode: bool): string =
  let mode = if hydrateMode: "hydrate" else: "mount"
  let summaryText =
    if hydrateMode:
      "SSR markup rendered on server, then hydrated in the browser."
    else:
      "Client-only mount of the same workspace app."
  let appMarkup = if hydrateMode: renderToString(workspaceRoot) else: ""

  result = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Momentum Workspace Demo</title>
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
  <link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500&family=Outfit:wght@300;400;500;600;700;800;900&family=Space+Grotesk:wght@400;500;600;700&display=swap" rel="stylesheet" />
  <link rel="stylesheet" href="/ui/workspace.tailwind.css" />
</head>
<body>
  <main class="workspace-shell">
    <div class="workspace-frame">
      <div id="app">__APP_HTML__</div>
    </div>
    <div id="modal-root"></div>
  </main>
  <div style="position:fixed;left:16px;bottom:16px;z-index:5;border:1px solid #cbd5e1;background:#ffffffdb;padding:10px 12px;border-radius:10px;font:12px/1.4 'JetBrains Mono',monospace;color:#334155;">
    <div style="font-weight:700;">Workspace demo mode: __MODE__</div>
    <div style="margin-top:4px;">__SUMMARY__</div>
    <div style="margin-top:4px;"><a href="/workspace/ssr">SSR</a> | <a href="/workspace/spa">SPA</a></div>
  </div>
  <script type="module">
    import { loadNimUiWasm } from "/src/cps/ui/js/loader.js";
    if (location.pathname.startsWith("/workspace/")) {
      history.replaceState({}, "", "/");
    }
    await loadNimUiWasm("/ui/workspace_app.wasm?v=workspace-demo-20260219", { selector: "#app", mode: "__MODE__" });
  </script>
</body>
</html>
"""

  result = result.replace("__APP_HTML__", appMarkup)
  result = result.replace("__MODE__", mode)
  result = result.replace("__SUMMARY__", summaryText)

when isMainModule:
  let host = getEnv("CPS_UI_HOST", "127.0.0.1")
  let port = parsePort(getEnv("CPS_UI_PORT", "8083"), 8083)
  let useTls = parseBool(getEnv("CPS_UI_USE_TLS", ""), false)
  let enableHttp2 = parseBool(getEnv("CPS_UI_ENABLE_HTTP2", ""), true)
  let certFile = getEnv("CPS_UI_TLS_CERT", "")
  let keyFile = getEnv("CPS_UI_TLS_KEY", "")
  let scheme = if useTls: "https" else: "http"

  if useTls and (certFile.len == 0 or keyFile.len == 0):
    quit("CPS_UI_USE_TLS=true requires CPS_UI_TLS_CERT and CPS_UI_TLS_KEY", QuitFailure)

  let uiDir = getAppDir()
  let repoRoot = normalizedPath(uiDir / ".." / "..")
  let srcDir = repoRoot / "src"

  let handler = router:
    get "/":
      redirect "/workspace/ssr"

    get "/workspace":
      redirect "/workspace/ssr"

    get "/workspace/ssr":
      html 200, workspacePage(hydrateMode = true)

    get "/workspace/spa":
      html 200, workspacePage(hydrateMode = false)

    get "/api/health":
      respond 200, "ok"

    get "/api/workspace/summary":
      respond 200, "summary:tasks=4;focus=2;status=ok"

    ws "/ws/workspace":
      discard await recvMessage()
      await sendText("workspace-server:connected")
      await sendClose(1000, "done")

    sse "/events/workspace":
      await sendEvent("workspace-sse:ready", event = "message", id = "workspace-1")

    serveStatic "/ui", uiDir:
      fallback "workspace.html"

    serveStatic "/src", srcDir

  echo "CPS UI workspace demo server"
  echo "  host: " & host
  echo "  port: " & $port
  echo "  tls:  " & $useTls
  echo "  h2:   " & $(useTls and enableHttp2)
  echo "  ui:   " & uiDir
  echo "  src:  " & srcDir
  echo "  SSR:  " & scheme & "://" & host & ":" & $port & "/workspace/ssr"
  echo "  SPA:  " & scheme & "://" & host & ":" & $port & "/workspace/spa"
  serve(
    handler,
    port = port,
    host = host,
    useTls = useTls,
    certFile = certFile,
    keyFile = keyFile,
    enableHttp2 = enableHttp2
  )
