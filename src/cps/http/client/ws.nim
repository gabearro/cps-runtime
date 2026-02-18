## WebSocket Client - Connect
##
## Client-side WebSocket connection establishment over plain TCP and TLS.

import std/[strutils, sysrand, base64]
import ../../runtime
import ../../transform
import ../../io/streams
import ../../io/buffered
import ../../io/tcp
import ../../tls/client as tls
import ../../tls/fingerprint
import ../shared/ws

export ws

proc wsConnect*(host: string, port: int, path: string = "/",
                extraHeaders: seq[(string, string)] = @[],
                enableCompression: bool = true): CpsFuture[WebSocket] {.cps.} =
  ## Connect to a WebSocket server (plain TCP, no TLS).
  let conn = await tcpConnect(host, port)
  let tcpStream = conn.AsyncStream

  # Generate random key
  let randomBytes = urandom(16)
  let wsKey = base64.encode(randomBytes)

  # Build upgrade request
  var reqStr = "GET " & path & " HTTP/1.1\r\n"
  reqStr &= "Host: " & host & ":" & $port & "\r\n"
  reqStr &= "Upgrade: websocket\r\n"
  reqStr &= "Connection: Upgrade\r\n"
  reqStr &= "Sec-WebSocket-Key: " & wsKey & "\r\n"
  reqStr &= "Sec-WebSocket-Version: " & WsVersion & "\r\n"
  if enableCompression:
    reqStr &= "Sec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover; client_no_context_takeover\r\n"
  for (k, v) in extraHeaders:
    reqStr &= k & ": " & v & "\r\n"
  reqStr &= "\r\n"

  await tcpStream.write(reqStr)

  let reader = newBufferedReader(tcpStream)

  # Read response status line
  let statusLine = await reader.readLine()
  if not statusLine.startsWith("HTTP/1.1 101"):
    raise newException(WsError, "WebSocket upgrade failed: " & statusLine)

  # Read response headers
  let expectedAccept = computeAcceptKey(wsKey)
  var gotAccept = ""
  var wsExtResp = ""
  while true:
    let line = await reader.readLine()
    if line == "":
      break
    let colonPos = line.find(':')
    if colonPos > 0:
      let hdrKey = line[0 ..< colonPos].strip()
      let hdrVal = line[colonPos + 1 .. ^1].strip()
      if hdrKey.toLowerAscii == "sec-websocket-accept":
        gotAccept = hdrVal
      elif hdrKey.toLowerAscii == "sec-websocket-extensions":
        wsExtResp = hdrVal

  if gotAccept != expectedAccept:
    raise newException(WsError, "Invalid Sec-WebSocket-Accept: expected " &
                       expectedAccept & ", got " & gotAccept)

  let extParsed = parseWsExtensions(wsExtResp)

  let ws = WebSocket(
    stream: tcpStream,
    reader: reader,
    isMasked: true,
    compressEnabled: extParsed.enabled,
    serverNoContextTakeover: extParsed.serverNoCtx,
    clientNoContextTakeover: extParsed.clientNoCtx
  )
  ws.initWsMtFields()
  return ws

proc wssConnect*(host: string, port: int, path: string = "/",
                 extraHeaders: seq[(string, string)] = @[],
                 enableCompression: bool = true,
                 tlsFingerprint: TlsFingerprint = nil): CpsFuture[WebSocket] {.cps.} =
  ## Connect to a WebSocket server over TLS (WSS).
  ## No ALPN negotiation (WebSocket uses HTTP/1.1 Upgrade).
  ## When `tlsFingerprint` is provided, applies the TLS fingerprint profile.
  let conn = await tcpConnect(host, port)
  let tlsStream = newTlsStream(conn, host, @["http/1.1"], tlsFingerprint)  # WebSocket requires HTTP/1.1
  await tlsConnect(tlsStream)
  let stream = tlsStream.AsyncStream

  # Generate random key
  let randomBytes = urandom(16)
  let wsKey = base64.encode(randomBytes)

  # Build upgrade request
  var reqStr = "GET " & path & " HTTP/1.1\r\n"
  reqStr &= "Host: " & host & ":" & $port & "\r\n"
  reqStr &= "Upgrade: websocket\r\n"
  reqStr &= "Connection: Upgrade\r\n"
  reqStr &= "Sec-WebSocket-Key: " & wsKey & "\r\n"
  reqStr &= "Sec-WebSocket-Version: " & WsVersion & "\r\n"
  if enableCompression:
    reqStr &= "Sec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover; client_no_context_takeover\r\n"
  for (k, v) in extraHeaders:
    reqStr &= k & ": " & v & "\r\n"
  reqStr &= "\r\n"

  await stream.write(reqStr)

  let reader = newBufferedReader(stream)

  # Read response status line
  let statusLine = await reader.readLine()
  if not statusLine.startsWith("HTTP/1.1 101"):
    raise newException(WsError, "WSS upgrade failed: " & statusLine)

  # Read response headers
  let expectedAccept = computeAcceptKey(wsKey)
  var gotAccept = ""
  var wsExtResp = ""
  while true:
    let line = await reader.readLine()
    if line == "":
      break
    let colonPos = line.find(':')
    if colonPos > 0:
      let hdrKey = line[0 ..< colonPos].strip()
      let hdrVal = line[colonPos + 1 .. ^1].strip()
      if hdrKey.toLowerAscii == "sec-websocket-accept":
        gotAccept = hdrVal
      elif hdrKey.toLowerAscii == "sec-websocket-extensions":
        wsExtResp = hdrVal

  if gotAccept != expectedAccept:
    raise newException(WsError, "Invalid Sec-WebSocket-Accept: expected " &
                       expectedAccept & ", got " & gotAccept)

  let extParsed = parseWsExtensions(wsExtResp)

  let ws = WebSocket(
    stream: stream,
    reader: reader,
    isMasked: true,
    compressEnabled: extParsed.enabled,
    serverNoContextTakeover: extParsed.serverNoCtx,
    clientNoContextTakeover: extParsed.clientNoCtx
  )
  ws.initWsMtFields()
  return ws
