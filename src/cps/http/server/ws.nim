## WebSocket Server - Accept Handshake
##
## Accepts WebSocket upgrade requests for both HTTP/1.1 (101 Switching Protocols)
## and HTTP/2 (Extended CONNECT, RFC 8441).

import std/[strutils, tables, base64]
import ../../runtime
import ../../io/streams
import ../../io/buffered
import ../shared/ws
import ./types
import ../shared/http2_stream_adapter

export ws

proc parseWsLimit(req: HttpRequest, key: string, fallback: int): int =
  if req.context.isNil:
    return fallback
  let raw = req.context.getOrDefault(key)
  if raw.len == 0:
    return fallback
  try:
    let parsed = raw.parseInt()
    if parsed > 0: parsed else: fallback
  except ValueError:
    fallback

proc headerHasToken(value, token: string): bool =
  let expected = token.toLowerAscii
  for part in value.split(','):
    if part.strip().toLowerAscii == expected:
      return true
  false

proc getHeaderValues(req: HttpRequest, name: string): seq[string] =
  let lower = name.toLowerAscii
  for (k, v) in req.headers:
    if k.toLowerAscii == lower:
      result.add(v)

proc headersHaveToken(values: openArray[string], token: string): bool =
  for v in values:
    if headerHasToken(v, token):
      return true
  false

proc isValidSecWebSocketKey(key: string): bool =
  if key.len == 0:
    return false
  try:
    let decoded = base64.decode(key)
    return decoded.len == 16
  except CatchableError:
    return false

proc wsResponse*(): HttpResponseBuilder =
  ## Sentinel control response. Tells handleHttp1Connection that
  ## the handler already wrote directly to the stream (like SSE).
  handledResponse()

proc acceptWebSocket*(stream: AsyncStream, reader: BufferedReader,
                      req: HttpRequest,
                      extraHeaders: seq[(string, string)] = @[]): CpsFuture[WebSocket] =
  ## Validate the WebSocket upgrade request and send the appropriate response.
  ## Supports both HTTP/1.1 (101 Switching Protocols) and HTTP/2 (Extended CONNECT, RFC 8441).
  let fut = newCpsFuture[WebSocket]()
  let maxFrameBytes = parseWsLimit(req, "ws_max_frame_bytes", 1024 * 1024)
  let maxMessageBytes = parseWsLimit(req, "ws_max_message_bytes", 16 * 1024 * 1024)

  for (k, v) in extraHeaders:
    if not validateHeaderPair(k, v):
      fut.fail(newException(WsError, "Invalid WebSocket response header"))
      return fut

  if stream of Http2StreamAdapter:
    # HTTP/2 Extended CONNECT (RFC 8441)
    let adapter = Http2StreamAdapter(stream)
    # Validate: method should be CONNECT, check sec-websocket-version
    if req.meth != "CONNECT":
      fut.fail(newException(WsError, "Expected CONNECT method for HTTP/2 WebSocket, got: " & req.meth))
      return fut
    let protocolHeader = req.getHeader(":protocol")
    if protocolHeader.toLowerAscii != "websocket":
      fut.fail(newException(WsError, "Expected :protocol=websocket, got: " & protocolHeader))
      return fut
    let wsVersionHeader = req.getHeader("sec-websocket-version")
    if wsVersionHeader != WsVersion:
      fut.fail(newException(WsError, "Unsupported WebSocket version: " & wsVersionHeader))
      return fut
    # Parse permessage-deflate extension
    let wsExtHeader = req.getHeader("sec-websocket-extensions")
    let extParsed = parseWsExtensions(wsExtHeader)

    # Send HEADERS with :status=200
    var h2Headers: seq[(string, string)]
    if extParsed.enabled:
      # Always request no-context-takeover since our implementation is stateless
      var extResp = "permessage-deflate; server_no_context_takeover; client_no_context_takeover"
      h2Headers.add ("sec-websocket-extensions", extResp)
    for (k, v) in extraHeaders:
      h2Headers.add (k.toLowerAscii, v)
    let writeFut = adapter.sendResponseHeaders(200, h2Headers)
    let capturedStream = stream
    let capturedReader = reader
    let capturedExtParsed = extParsed
    writeFut.addCallback(proc() =
      if writeFut.hasError():
        fut.fail(writeFut.getError())
      else:
        let ws = WebSocket(
          stream: capturedStream,
          reader: capturedReader,
          isMasked: false,
          requireMaskedIncoming: true,
          maxFrameBytes: maxFrameBytes,
          maxMessageBytes: maxMessageBytes,
          compressEnabled: capturedExtParsed.enabled,
          serverNoContextTakeover: capturedExtParsed.serverNoCtx,
          clientNoContextTakeover: capturedExtParsed.clientNoCtx
        )
        ws.initWsMtFields()
        fut.complete(ws)
    )
  else:
    # HTTP/1.1 Upgrade
    # Validate required headers
    if req.httpVersion != "HTTP/1.1":
      fut.fail(newException(WsError, "Expected HTTP/1.1 for WebSocket upgrade, got: " & req.httpVersion))
      return fut
    if req.meth.toUpperAscii != "GET":
      fut.fail(newException(WsError, "Expected GET method for WebSocket upgrade, got: " & req.meth))
      return fut

    let upgradeHeaders = getHeaderValues(req, "Upgrade")
    let connectionHeaders = getHeaderValues(req, "Connection")
    let wsVersionHeaders = getHeaderValues(req, "Sec-WebSocket-Version")
    let wsKeyHeaders = getHeaderValues(req, "Sec-WebSocket-Key")

    if not headersHaveToken(upgradeHeaders, "websocket"):
      fut.fail(newException(WsError, "Missing or invalid Upgrade header"))
      return fut

    if not headersHaveToken(connectionHeaders, "upgrade"):
      fut.fail(newException(WsError, "Missing 'upgrade' in Connection header"))
      return fut

    if wsVersionHeaders.len != 1:
      fut.fail(newException(WsError, "Missing or duplicate Sec-WebSocket-Version header"))
      return fut
    let wsVersionHeader = wsVersionHeaders[0]
    if wsVersionHeader != WsVersion:
      fut.fail(newException(WsError, "Unsupported WebSocket version: " & wsVersionHeader))
      return fut

    if wsKeyHeaders.len != 1:
      fut.fail(newException(WsError, "Missing or duplicate Sec-WebSocket-Key header"))
      return fut
    let wsKeyHeader = wsKeyHeaders[0]
    if not isValidSecWebSocketKey(wsKeyHeader):
      fut.fail(newException(WsError, "Missing or invalid Sec-WebSocket-Key header"))
      return fut

    # Compute accept key
    let acceptKey = computeAcceptKey(wsKeyHeader)

    # Parse permessage-deflate extension
    let wsExtHeader = getHeaderValues(req, "Sec-WebSocket-Extensions").join(",")
    let extParsed = parseWsExtensions(wsExtHeader)

    # Build 101 response
    var respStr = "HTTP/1.1 101 Switching Protocols\r\n"
    respStr &= "Upgrade: websocket\r\n"
    respStr &= "Connection: Upgrade\r\n"
    respStr &= "Sec-WebSocket-Accept: " & acceptKey & "\r\n"
    if extParsed.enabled:
      # Always request no-context-takeover since our implementation is stateless
      var extResp = "permessage-deflate; server_no_context_takeover; client_no_context_takeover"
      respStr &= "Sec-WebSocket-Extensions: " & extResp & "\r\n"
    for (k, v) in extraHeaders:
      respStr &= k & ": " & v & "\r\n"
    respStr &= "\r\n"

    let writeFut = stream.write(respStr)
    let capturedStream = stream
    let capturedReader = reader
    let capturedExtParsed = extParsed
    let capturedReqContext = req.context
    writeFut.addCallback(proc() =
      if writeFut.hasError():
        fut.fail(writeFut.getError())
      else:
        if not capturedReqContext.isNil:
          capturedReqContext["ws_upgraded"] = "1"
        let ws = WebSocket(
          stream: capturedStream,
          reader: capturedReader,
          isMasked: false,
          requireMaskedIncoming: true,
          maxFrameBytes: maxFrameBytes,
          maxMessageBytes: maxMessageBytes,
          compressEnabled: capturedExtParsed.enabled,
          serverNoContextTakeover: capturedExtParsed.serverNoCtx,
          clientNoContextTakeover: capturedExtParsed.clientNoCtx
        )
        ws.initWsMtFields()
        fut.complete(ws)
    )
  return fut

proc acceptWebSocket*(req: HttpRequest,
                      extraHeaders: seq[(string, string)] = @[]): CpsFuture[WebSocket] =
  ## Convenience: accept WebSocket upgrade from an HttpRequest.
  acceptWebSocket(req.stream, req.reader, req, extraHeaders)
