## CPS HTTP server for the Tailwind + WASM test SPA.
##
## Usage:
##   nim c -d:release -o:examples/ui/test_spa_server examples/ui/test_spa_server.nim
##   ./examples/ui/test_spa_server
##
## Env vars:
##   CPS_UI_HOST (default 127.0.0.1)
##   CPS_UI_PORT (default 8080)

import std/[os, strutils]
import cps/eventloop
import cps/transform
import cps/io/tcp
import cps/io/streams

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

proc statusText(status: int): string =
  case status
  of 200: "OK"
  of 302: "Found"
  of 400: "Bad Request"
  of 403: "Forbidden"
  of 404: "Not Found"
  of 405: "Method Not Allowed"
  of 500: "Internal Server Error"
  else: "Error"

proc contentType(path: string): string =
  let ext = splitFile(path).ext.toLowerAscii()
  case ext
  of ".html": "text/html; charset=utf-8"
  of ".css": "text/css; charset=utf-8"
  of ".js", ".mjs": "application/javascript; charset=utf-8"
  of ".json": "application/json; charset=utf-8"
  of ".wasm": "application/wasm"
  of ".svg": "image/svg+xml"
  of ".ico": "image/x-icon"
  else: "application/octet-stream"

proc staticPath(baseDir, routePath, prefix: string): string =
  if routePath.len == 0 or not routePath.startsWith(prefix):
    return ""
  var rel = routePath[prefix.len .. ^1]
  while rel.startsWith("/"):
    rel = rel[1 .. ^1]
  if rel.len == 0 or rel.contains('\0'):
    return ""
  let resolved = normalizedPath(baseDir / rel)
  if not resolved.startsWith(baseDir):
    return ""
  resolved

proc buildHttpResponse(status: int, body: string,
                       headers: seq[(string, string)] = @[],
                       contentLength = -1): string =
  var response = "HTTP/1.1 " & $status & " " & statusText(status) & "\r\n"
  for (k, v) in headers:
    response.add(k & ": " & v & "\r\n")
  let length =
    if contentLength >= 0: contentLength
    else: body.len
  response.add("Content-Length: " & $length & "\r\n")
  response.add("Connection: close\r\n\r\n")
  response.add(body)
  response

proc fileResponse(path: string, reqMethod: string): string =
  try:
    let body = readFile(path)
    if reqMethod == "HEAD":
      return buildHttpResponse(
        200,
        "",
        @[("Content-Type", contentType(path))],
        contentLength = body.len
      )
    buildHttpResponse(200, body, @[("Content-Type", contentType(path))])
  except CatchableError:
    buildHttpResponse(500, "Failed to read file", @[
      ("Content-Type", "text/plain; charset=utf-8")
    ])

proc appResponse(reqMethod, reqPath: string, uiDir: string, srcDir: string, uiIndex: string): string =
  if reqMethod != "GET" and reqMethod != "HEAD":
    return buildHttpResponse(405, "Method Not Allowed", @[
      ("Content-Type", "text/plain; charset=utf-8")
    ])

  let queryIdx = reqPath.find('?')
  let pathOnly =
    if queryIdx >= 0: reqPath[0 ..< queryIdx]
    else: reqPath

  if pathOnly == "/":
    return buildHttpResponse(302, "", @[("Location", "/ui/" & uiIndex)])

  if pathOnly == "/api/health":
    return buildHttpResponse(200, "ok", @[
      ("Content-Type", "text/plain; charset=utf-8")
    ])

  if pathOnly.startsWith("/ui/"):
    let target = staticPath(uiDir, pathOnly, "/ui/")
    if target.len > 0 and fileExists(target):
      return fileResponse(target, reqMethod)
    let fallback = uiDir / uiIndex
    if fileExists(fallback):
      return fileResponse(fallback, reqMethod)
    return buildHttpResponse(404, "Not Found", @[
      ("Content-Type", "text/plain; charset=utf-8")
    ])

  if pathOnly.startsWith("/src/"):
    let target = staticPath(srcDir, pathOnly, "/src/")
    if target.len > 0 and fileExists(target):
      return fileResponse(target, reqMethod)
    return buildHttpResponse(404, "Not Found", @[
      ("Content-Type", "text/plain; charset=utf-8")
    ])

  buildHttpResponse(404, "Not Found", @[
    ("Content-Type", "text/plain; charset=utf-8")
  ])

proc parseRequestBuffer(buffer: string, headerEnd: int): tuple[ok: bool, reqMethod: string, path: string] =
  if headerEnd < 0:
    return (false, "", "")

  let headerBlock =
    if headerEnd > 0: buffer[0 ..< headerEnd]
    else: ""
  let lines = headerBlock.split("\r\n")
  if lines.len == 0:
    return (false, "", "")

  let requestLine = lines[0]
  let parts = requestLine.split(' ')
  if parts.len < 2:
    return (false, "", "")

  (true, parts[0].toUpperAscii(), parts[1])

proc readRequest(stream: AsyncStream): CpsFuture[tuple[ok: bool, reqMethod: string, path: string]] {.cps.} =
  var buffer = ""
  var headerEnd = -1

  while headerEnd < 0 and buffer.len < 64 * 1024:
    let chunk = await stream.read(4096)
    if chunk.len == 0:
      return (false, "", "")
    buffer.add(chunk)
    headerEnd = buffer.find("\r\n\r\n")

  if headerEnd < 0:
    return (false, "", "")

  return parseRequestBuffer(buffer, headerEnd)

proc acceptLoop(listener: TcpListener, uiDir: string, srcDir: string, uiIndex: string): CpsVoidFuture {.cps.} =
  while true:
    var client: TcpStream = nil
    try:
      client = await listener.accept()
      let req = await readRequest(client.AsyncStream)
      let response =
        if req.ok:
          appResponse(req.reqMethod, req.path, uiDir, srcDir, uiIndex)
        else:
          buildHttpResponse(400, "Bad Request", @[
            ("Content-Type", "text/plain; charset=utf-8")
          ])
      await client.AsyncStream.write(response)
    except CatchableError:
      discard
    finally:
      if client != nil:
        client.AsyncStream.close()

when isMainModule:
  let host = getEnv("CPS_UI_HOST", "127.0.0.1")
  let port = parsePort(getEnv("CPS_UI_PORT", "8080"), 8080)
  let uiIndex = getEnv("CPS_UI_INDEX", "workspace.html")

  let uiDir = getAppDir()
  let repoRoot = normalizedPath(uiDir / ".." / "..")
  let srcDir = repoRoot / "src"

  echo "CPS UI SPA server"
  echo "  host: " & host
  echo "  port: " & $port
  echo "  ui:   " & uiDir
  echo "  src:  " & srcDir
  echo "  url:  http://" & host & ":" & $port & "/ui/" & uiIndex

  let listener = tcpListen(host, port)
  echo "Listening on " & host & ":" & $port
  runCps(acceptLoop(listener, uiDir, srcDir, uiIndex))
