## WebSocket Client - Connect
##
## Client-side WebSocket connection establishment over plain TCP and TLS.

import std/[strutils, sysrand, base64]
import ../../runtime
import ../../transform
import ../../io/streams
import ../../io/buffered
import ../../io/tcp
import ../../io/proxy
import ../../tls/client as tls
import ../../tls/fingerprint
import ../shared/ws

export ws

const headerTokenChars = {'!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^',
                          '_', '`', '|', '~'} + Digits + Letters
const wsMaxStatusLineSize = 8 * 1024
const wsMaxHeaderLineSize = 8 * 1024
const wsMaxHeaderBytes = 64 * 1024
const wsMaxHeaderCount = 100

proc headerHasToken(value, token: string): bool =
  let expected = token.toLowerAscii
  for part in value.split(','):
    if part.strip().toLowerAscii == expected:
      return true
  false

proc headersHaveToken(values: openArray[string], token: string): bool =
  for v in values:
    if headerHasToken(v, token):
      return true
  false

proc isSwitchingProtocolsStatus(statusLine: string): bool =
  let parts = statusLine.split(' ', 2)
  parts.len >= 2 and parts[0] == "HTTP/1.1" and parts[1] == "101"

proc isValidHeaderName(name: string): bool =
  if name.len == 0:
    return false
  for c in name:
    if c notin headerTokenChars:
      return false
  true

proc isValidHeaderValue(value: string): bool =
  for c in value:
    if c == '\r' or c == '\n':
      return false
    if c == '\0':
      return false
    if ord(c) < 0x20 and c != '\t':
      return false
    if ord(c) == 0x7F:
      return false
  true

proc validateRequestInputs(host: string, path: string, extraHeaders: seq[(string, string)]) =
  if path.len == 0:
    raise newException(WsError, "Invalid WebSocket request target")
  for c in path:
    if ord(c) < 0x21 or ord(c) == 0x7F:
      raise newException(WsError, "Invalid WebSocket request target")
  let hostVal = host.strip()
  if hostVal.len == 0 or not isValidHeaderValue(hostVal):
    raise newException(WsError, "Invalid WebSocket host value")
  for (k, v) in extraHeaders:
    if not isValidHeaderName(k):
      raise newException(WsError, "Invalid WebSocket request header name")
    if not isValidHeaderValue(v):
      raise newException(WsError, "Invalid WebSocket request header value")

proc hasOnlyPermessageDeflateExtension(header: string): bool =
  var seenPermessageDeflate = false
  for ext in header.split(','):
    let trimmed = ext.strip()
    if trimmed.len == 0:
      return false
    let parts = trimmed.split(';')
    if parts.len == 0:
      return false
    if parts[0].strip().toLowerAscii != "permessage-deflate":
      return false
    if seenPermessageDeflate:
      return false
    seenPermessageDeflate = true
  seenPermessageDeflate

proc hasUnsupportedDeflateParams(header: string): bool =
  for ext in header.split(','):
    let trimmed = ext.strip()
    if trimmed.len == 0:
      continue
    let parts = trimmed.split(';')
    if parts.len == 0:
      continue
    let extName = parts[0].strip().toLowerAscii
    if extName != "permessage-deflate":
      continue
    for i in 1 ..< parts.len:
      let p = parts[i].strip().toLowerAscii
      if p.len == 0:
        continue
      if p == "server_no_context_takeover" or p == "client_no_context_takeover":
        continue
      if p.startsWith("server_max_window_bits"):
        let eq = p.find('=')
        if eq < 0:
          return true
        let rawVal = p[eq + 1 .. ^1].strip()
        if rawVal.len == 0:
          return true
        var parsed = -1
        try:
          parsed = parseInt(rawVal)
        except ValueError:
          return true
        if parsed < 8 or parsed > 15:
          return true
        continue
      if p.startsWith("client_max_window_bits"):
        let eq = p.find('=')
        if eq < 0:
          return true
        let rawVal = p[eq + 1 .. ^1].strip()
        if rawVal.len == 0:
          return true
        var parsed = -1
        try:
          parsed = parseInt(rawVal)
        except ValueError:
          return true
        # Local compressor currently uses a 15-bit window.
        if parsed != 15:
          return true
        continue
      return true
  false

proc readAndValidateUpgradeResponse(reader: BufferedReader, wsKey: string,
                                    enableCompression: bool,
                                    errorPrefix: string):
    CpsFuture[tuple[enabled: bool, serverNoCtx: bool, clientNoCtx: bool]] {.cps.} =
  let statusLine = await reader.readLine(maxLen = wsMaxStatusLineSize + 1)
  if statusLine.len > wsMaxStatusLineSize:
    raise newException(WsError, errorPrefix & "status line too long")
  if not isSwitchingProtocolsStatus(statusLine):
    raise newException(WsError, errorPrefix & statusLine)

  let expectedAccept = computeAcceptKey(wsKey)
  var acceptHeaders: seq[string] = @[]
  var wsExtHeaders: seq[string] = @[]
  var upgradeHeaders: seq[string] = @[]
  var connectionHeaders: seq[string] = @[]
  var headerCount = 0
  var totalHeaderBytes = 0
  while true:
    let line = await reader.readLine(maxLen = wsMaxHeaderLineSize + 1)
    if line.len > wsMaxHeaderLineSize:
      raise newException(WsError, "WebSocket response headers too large")
    if line == "":
      break
    inc headerCount
    totalHeaderBytes += line.len
    if headerCount > wsMaxHeaderCount or totalHeaderBytes > wsMaxHeaderBytes:
      raise newException(WsError, "WebSocket response headers too large")
    if line[0] == ' ' or line[0] == '\t':
      raise newException(WsError, "Invalid WebSocket response header line")
    let colonPos = line.find(':')
    if colonPos <= 0:
      raise newException(WsError, "Invalid WebSocket response header line")
    let hdrKey = line.substr(0, colonPos - 1)
    if hdrKey != hdrKey.strip() or not isValidHeaderName(hdrKey):
      raise newException(WsError, "Invalid WebSocket response header line")
    let hdrVal = line[colonPos + 1 .. ^1].strip()
    if not isValidHeaderValue(hdrVal):
      raise newException(WsError, "Invalid WebSocket response header line")
    let hdrKeyLower = hdrKey.toLowerAscii
    if hdrKeyLower == "sec-websocket-accept":
      acceptHeaders.add(hdrVal)
    elif hdrKeyLower == "sec-websocket-extensions":
      wsExtHeaders.add(hdrVal)
    elif hdrKeyLower == "upgrade":
      upgradeHeaders.add(hdrVal)
    elif hdrKeyLower == "connection":
      connectionHeaders.add(hdrVal)

  if not headersHaveToken(upgradeHeaders, "websocket"):
    raise newException(WsError, "Invalid Upgrade header in WebSocket response")

  if not headersHaveToken(connectionHeaders, "upgrade"):
    raise newException(WsError, "Invalid Connection header in WebSocket response")

  if acceptHeaders.len != 1:
    raise newException(WsError, "Missing or duplicate Sec-WebSocket-Accept header")
  let gotAccept = acceptHeaders[0]
  if gotAccept != expectedAccept:
    raise newException(WsError, "Invalid Sec-WebSocket-Accept: expected " &
                       expectedAccept & ", got " & gotAccept)

  let wsExtResp = wsExtHeaders.join(",")
  if wsExtResp.len == 0:
    return (false, false, false)

  if not enableCompression:
    raise newException(WsError, "Server negotiated permessage-deflate when it was not requested")
  if not hasOnlyPermessageDeflateExtension(wsExtResp):
    raise newException(WsError, "Unsupported WebSocket extensions in response: " & wsExtResp)
  if hasUnsupportedDeflateParams(wsExtResp):
    raise newException(WsError, "Unsupported permessage-deflate parameters in response: " & wsExtResp)
  let extParsed = parseWsExtensions(wsExtResp)
  if not extParsed.enabled:
    raise newException(WsError, "Unsupported WebSocket extensions in response: " & wsExtResp)
  return extParsed

proc wsConnect*(host: string, port: int, path: string = "/",
                extraHeaders: seq[(string, string)] = @[],
                enableCompression: bool = true,
                proxy: seq[ProxyConfig] = @[]): CpsFuture[WebSocket] {.cps.} =
  ## Connect to a WebSocket server (plain TCP, no TLS).
  ## When `proxy` is non-empty, tunnels through the proxy chain first.
  validateRequestInputs(host, path, extraHeaders)
  var tcpStream: AsyncStream
  if proxy.len > 0:
    let ps: ProxyStream = await proxyChainConnect(proxy, host, port)
    tcpStream = ps.AsyncStream
  else:
    let conn: TcpStream = await tcpConnect(host, port)
    tcpStream = conn.AsyncStream

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

  let extParsed = await readAndValidateUpgradeResponse(
    reader, wsKey, enableCompression, "WebSocket upgrade failed: ")

  let ws = WebSocket(
    stream: tcpStream,
    reader: reader,
    isMasked: true,
    requireMaskedIncoming: false,
    maxFrameBytes: 16 * 1024 * 1024,
    maxMessageBytes: 64 * 1024 * 1024,
    compressEnabled: extParsed.enabled,
    serverNoContextTakeover: extParsed.serverNoCtx,
    clientNoContextTakeover: extParsed.clientNoCtx
  )
  ws.initWsMtFields()
  return ws

proc wssConnect*(host: string, port: int, path: string = "/",
                 extraHeaders: seq[(string, string)] = @[],
                 enableCompression: bool = true,
                 tlsFingerprint: TlsFingerprint = nil,
                 proxy: seq[ProxyConfig] = @[]): CpsFuture[WebSocket] {.cps.} =
  ## Connect to a WebSocket server over TLS (WSS).
  ## No ALPN negotiation (WebSocket uses HTTP/1.1 Upgrade).
  ## When `tlsFingerprint` is provided, applies the TLS fingerprint profile.
  ## When `proxy` is non-empty, tunnels through the proxy chain first.
  validateRequestInputs(host, path, extraHeaders)
  var conn: TcpStream
  if proxy.len > 0:
    let ps: ProxyStream = await proxyChainConnect(proxy, host, port)
    conn = ps.getUnderlyingTcpStream()
  else:
    conn = await tcpConnect(host, port)
  let tlsStream: TlsStream = newTlsStream(conn, host, @["http/1.1"], tlsFingerprint)  # WebSocket requires HTTP/1.1
  await tlsConnect(tlsStream)
  let stream: AsyncStream = tlsStream.AsyncStream

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

  let extParsed = await readAndValidateUpgradeResponse(
    reader, wsKey, enableCompression, "WSS upgrade failed: ")

  let ws = WebSocket(
    stream: stream,
    reader: reader,
    isMasked: true,
    requireMaskedIncoming: false,
    maxFrameBytes: 16 * 1024 * 1024,
    maxMessageBytes: 64 * 1024 * 1024,
    compressEnabled: extParsed.enabled,
    serverNoContextTakeover: extParsed.serverNoCtx,
    clientNoContextTakeover: extParsed.clientNoCtx
  )
  ws.initWsMtFields()
  return ws
