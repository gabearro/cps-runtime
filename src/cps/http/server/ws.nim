## WebSocket Server - Accept Handshake
##
## Accepts WebSocket upgrade requests for both HTTP/1.1 (101 Switching Protocols)
## and HTTP/2 (Extended CONNECT, RFC 8441).

import std/strutils
import ../../runtime
import ../../io/streams
import ../../io/buffered
import ../shared/ws
import ./types
import ../shared/http2_stream_adapter

export ws

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
    let upgradeHeader = req.getHeader("Upgrade")
    let connectionHeader = req.getHeader("Connection")
    let wsVersionHeader = req.getHeader("Sec-WebSocket-Version")
    let wsKeyHeader = req.getHeader("Sec-WebSocket-Key")

    if upgradeHeader.toLowerAscii != "websocket":
      fut.fail(newException(WsError, "Missing or invalid Upgrade header: " & upgradeHeader))
      return fut

    if "upgrade" notin connectionHeader.toLowerAscii:
      fut.fail(newException(WsError, "Missing 'upgrade' in Connection header: " & connectionHeader))
      return fut

    if wsVersionHeader != WsVersion:
      fut.fail(newException(WsError, "Unsupported WebSocket version: " & wsVersionHeader))
      return fut

    if wsKeyHeader == "":
      fut.fail(newException(WsError, "Missing Sec-WebSocket-Key header"))
      return fut

    # Compute accept key
    let acceptKey = computeAcceptKey(wsKeyHeader)

    # Parse permessage-deflate extension
    let wsExtHeader = req.getHeader("Sec-WebSocket-Extensions")
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
    writeFut.addCallback(proc() =
      if writeFut.hasError():
        fut.fail(writeFut.getError())
      else:
        let ws = WebSocket(
          stream: capturedStream,
          reader: capturedReader,
          isMasked: false,
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
