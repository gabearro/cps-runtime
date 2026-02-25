## CPS HTTP server for the UI networking demo.
##
## Usage:
##   bash scripts/build_ui_wasm.sh examples/ui/net_app.nim examples/ui/net_app.wasm
##   nim c --mm:arc -d:release -o:examples/ui/net_demo_server examples/ui/net_demo_server.nim
##   ./examples/ui/net_demo_server
##
## Env vars:
##   CPS_UI_HOST (default 127.0.0.1)
##   CPS_UI_PORT (default 8082)

import std/[os, strutils]
import cps/httpserver
import cps/http/server/dsl

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

when isMainModule:
  let host = getEnv("CPS_UI_HOST", "127.0.0.1")
  let port = parsePort(getEnv("CPS_UI_PORT", "8082"), 8082)

  let uiDir = getAppDir()
  let repoRoot = normalizedPath(uiDir / ".." / "..")
  let srcDir = repoRoot / "src"

  let handler = router:
    get "/":
      redirect "/ui/net_demo.html"

    get "/api/health":
      respond 200, "ok"

    post "/api/net/fetch":
      respond 200, "fetch-ok:POST:" & body()

    ws "/ws/net":
      ## Consume one client frame before replying so the connection closes cleanly
      ## across runtimes that treat unread inbound frames as a socket error.
      let msg = await recvMessage()
      await sendText("echo:" & msg.data)

    sse "/events/net":
      await sendEvent("ready", event = "message", id = "sse-1")

    serveStatic "/ui", uiDir:
      fallback "net_demo.html"

    serveStatic "/src", srcDir

  echo "CPS UI network demo server"
  echo "  host: " & host
  echo "  port: " & $port
  echo "  ui:   " & uiDir
  echo "  src:  " & srcDir
  echo "  url:  http://" & host & ":" & $port & "/ui/net_demo.html"
  serve(handler, port = port, host = host)
