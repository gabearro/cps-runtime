## HTTP/2 Server Implementation
##
## Server-side HTTP/2 frame processing, stream dispatch, and
## per-stream concurrent handler execution.

import std/[strutils, tables]
import ../../runtime
import ../../transform
import ../../eventloop
import ../../concurrency/taskgroup
import ../../io/streams
import ../../io/buffered
import ../shared/hpack
import ../shared/http2
import ./types
import ../shared/http2_stream_adapter

type
  Http2ServerStream* = ref object
    id*: uint32
    state*: Http2StreamState
    requestHeaders*: seq[(string, string)]
    requestBody*: seq[byte]
    endStream*: bool
    adapter*: Http2StreamAdapter

  Http2ServerConnection* = ref object
    stream*: AsyncStream
    reader*: BufferedReader
    encoder*: HpackEncoder
    decoder*: HpackDecoder
    streams*: Table[uint32, Http2ServerStream]
    localWindowSize*: int
    remoteWindowSize*: int
    remoteSettings*: Table[uint16, uint32]
    config*: HttpServerConfig
    handler*: HttpHandler
    running*: bool
    lastStreamId*: uint32
    maxConcurrentStreams*: int
    streamGroup*: TaskGroup

proc newHttp2ServerConnection*(s: AsyncStream, config: HttpServerConfig,
                                handler: HttpHandler): Http2ServerConnection =
  let reader = newBufferedReader(s)
  Http2ServerConnection(
    stream: s,
    reader: reader,
    encoder: initHpackEncoder(),
    decoder: initHpackDecoder(),
    streams: initTable[uint32, Http2ServerStream](),
    localWindowSize: DefaultWindowSize,
    remoteWindowSize: DefaultWindowSize,
    remoteSettings: initTable[uint16, uint32](),
    config: config,
    handler: handler,
    running: true,
    lastStreamId: 0,
    maxConcurrentStreams: 100,
    streamGroup: newTaskGroup(epCollectAll)
  )

proc readConnectionPreface*(conn: Http2ServerConnection): CpsVoidFuture {.cps.} =
  ## Read and validate the HTTP/2 connection preface (24 bytes).
  let preface = await conn.reader.readExact(ConnectionPreface.len)
  if preface != ConnectionPreface:
    raise newException(ValueError, "Invalid HTTP/2 connection preface")

proc sendServerSettings*(conn: Http2ServerConnection): CpsVoidFuture {.cps.} =
  ## Send the server's SETTINGS frame.
  var payload: seq[byte]
  # MaxConcurrentStreams
  let maxStreams = conn.maxConcurrentStreams.uint32
  payload.add byte((SettingsMaxConcurrentStreams shr 8) and 0xFF)
  payload.add byte(SettingsMaxConcurrentStreams and 0xFF)
  payload.add byte((maxStreams shr 24) and 0xFF)
  payload.add byte((maxStreams shr 16) and 0xFF)
  payload.add byte((maxStreams shr 8) and 0xFF)
  payload.add byte(maxStreams and 0xFF)
  # InitialWindowSize
  let winSize = DefaultWindowSize.uint32
  payload.add byte((SettingsInitialWindowSize shr 8) and 0xFF)
  payload.add byte(SettingsInitialWindowSize and 0xFF)
  payload.add byte((winSize shr 24) and 0xFF)
  payload.add byte((winSize shr 16) and 0xFF)
  payload.add byte((winSize shr 8) and 0xFF)
  payload.add byte(winSize and 0xFF)
  # EnableConnectProtocol (RFC 8441)
  let enableConnect = 1'u32
  payload.add byte((SettingsEnableConnectProtocol shr 8) and 0xFF)
  payload.add byte(SettingsEnableConnectProtocol and 0xFF)
  payload.add byte((enableConnect shr 24) and 0xFF)
  payload.add byte((enableConnect shr 16) and 0xFF)
  payload.add byte((enableConnect shr 8) and 0xFF)
  payload.add byte(enableConnect and 0xFF)

  let frame = Http2Frame(
    frameType: FrameSettings,
    flags: 0,
    streamId: 0,
    payload: payload
  )
  let data = serializeFrame(frame)
  var str = newString(data.len)
  for i, b in data:
    str[i] = char(b)
  await conn.stream.write(str)

proc sendFrame*(conn: Http2ServerConnection, frame: Http2Frame): CpsVoidFuture {.cps.} =
  let data = serializeFrame(frame)
  var str = newString(data.len)
  for i, b in data:
    str[i] = char(b)
  await conn.stream.write(str)

proc recvServerFrame*(conn: Http2ServerConnection): CpsFuture[Http2Frame] {.cps.} =
  ## Receive a single HTTP/2 frame.
  let headerStr = await conn.reader.readExact(9)
  if headerStr.len < 9:
    raise newException(system.IOError, "Short frame header")
  var headerBytes = newSeq[byte](9)
  for i in 0 ..< 9:
    headerBytes[i] = byte(headerStr[i])
  var frame = parseFrame(headerBytes)
  if frame.length > 0:
    let payloadStr = await conn.reader.readExact(int(frame.length))
    frame.payload = newSeq[byte](payloadStr.len)
    for i in 0 ..< payloadStr.len:
      frame.payload[i] = byte(payloadStr[i])
  else:
    frame.payload = @[]
  return frame

proc sendResponseHeaders*(conn: Http2ServerConnection, streamId: uint32,
                           statusCode: int, headers: seq[(string, string)],
                           endStream: bool): CpsVoidFuture {.cps.} =
  ## Send HEADERS frame with response status and headers.
  var allHeaders: seq[(string, string)] = @[
    (":status", $statusCode)
  ]
  for i in 0 ..< headers.len:
    allHeaders.add (headers[i][0].toLowerAscii, headers[i][1])
  let encoded = conn.encoder.encode(allHeaders)
  var flags: uint8 = FlagEndHeaders
  if endStream:
    flags = flags or FlagEndStream
  let frame = Http2Frame(
    frameType: FrameHeaders,
    flags: flags,
    streamId: streamId,
    payload: encoded
  )
  await sendFrame(conn, frame)

proc sendResponseData*(conn: Http2ServerConnection, streamId: uint32,
                        data: seq[byte], endStream: bool): CpsVoidFuture {.cps.} =
  ## Send DATA frame with response body.
  var flags: uint8 = 0
  if endStream:
    flags = FlagEndStream
  let frame = Http2Frame(
    frameType: FrameData,
    flags: flags,
    streamId: streamId,
    payload: data
  )
  await sendFrame(conn, frame)

proc sendGoAway*(conn: Http2ServerConnection, errorCode: uint32): CpsVoidFuture {.cps.} =
  var payload: seq[byte]
  # Last-Stream-ID
  payload.add byte((conn.lastStreamId shr 24) and 0x7F)
  payload.add byte((conn.lastStreamId shr 16) and 0xFF)
  payload.add byte((conn.lastStreamId shr 8) and 0xFF)
  payload.add byte(conn.lastStreamId and 0xFF)
  # Error code
  payload.add byte((errorCode shr 24) and 0xFF)
  payload.add byte((errorCode shr 16) and 0xFF)
  payload.add byte((errorCode shr 8) and 0xFF)
  payload.add byte(errorCode and 0xFF)
  let frame = Http2Frame(
    frameType: FrameGoAway,
    flags: 0,
    streamId: 0,
    payload: payload
  )
  await sendFrame(conn, frame)

proc buildHttpRequest(s: Http2ServerStream,
                       conn: Http2ServerConnection): HttpRequest =
  ## Build an HttpRequest from an HTTP/2 stream's collected headers and body.
  var req = HttpRequest(streamId: s.id, context: newTable[string, string]())
  for (k, v) in s.requestHeaders:
    case k
    of ":method": req.meth = v
    of ":path": req.path = v
    of ":authority": req.authority = v
    of ":scheme": req.scheme = v
    of ":protocol":
      req.headers.add (k, v)
    else:
      req.headers.add (k, v)
  req.httpVersion = "HTTP/2"
  if s.requestBody.len > 0:
    req.body = newString(s.requestBody.len)
    for i, b in s.requestBody:
      req.body[i] = char(b)
  # Create adapter lazily if not already created (e.g., for SSE handlers
  # that need req.stream but aren't Extended CONNECT)
  if s.adapter == nil:
    s.adapter = newHttp2StreamAdapter(conn.stream, addr conn.encoder, s.id)
    if s.endStream:
      s.adapter.feedEof()
  req.stream = s.adapter.AsyncStream
  req.reader = newBufferedReader(s.adapter.AsyncStream)
  return req

proc dispatchHttp2Handler*(conn: Http2ServerConnection, streamId: uint32,
                            req: HttpRequest): CpsVoidFuture {.cps.} =
  ## Call the handler for a single HTTP/2 stream and send the response.
  var resp: HttpResponseBuilder
  try:
    resp = await conn.handler(req)
  except CatchableError:
    resp = newResponse(500, "Internal Server Error")
  # Control response means the handler already streamed the response
  # (SSE or WebSocket via Http2StreamAdapter).
  # Send an empty DATA frame with END_STREAM to close the HTTP/2 stream.
  if resp.control == rcHandled or resp.statusCode == 0:
    await sendResponseData(conn, streamId, @[], true)
    if streamId in conn.streams:
      conn.streams.del(streamId)
    return
  var respHeaders: seq[(string, string)]
  for i in 0 ..< resp.headers.len:
    respHeaders.add resp.headers[i]
  # Add Content-Length if body is present and not already set
  if resp.body.len > 0:
    var hasCL = false
    for (k, v) in respHeaders:
      if k.toLowerAscii == "content-length":
        hasCL = true
        break
    if not hasCL:
      respHeaders.add ("content-length", $resp.body.len)
  if resp.body.len == 0:
    # Headers-only response with END_STREAM
    await sendResponseHeaders(conn, streamId, resp.statusCode, respHeaders, true)
  else:
    # Send headers, then DATA frames split to peer max frame size.
    await sendResponseHeaders(conn, streamId, resp.statusCode, respHeaders, false)
    var bodyBytes = newSeq[byte](resp.body.len)
    for i in 0 ..< resp.body.len:
      bodyBytes[i] = byte(resp.body[i])
    var maxFrameSize = DefaultMaxFrameSize
    if SettingsMaxFrameSize in conn.remoteSettings:
      let peerMax = int(conn.remoteSettings[SettingsMaxFrameSize])
      # RFC 7540: valid SETTINGS_MAX_FRAME_SIZE range is [2^14, 2^24-1].
      if peerMax >= DefaultMaxFrameSize and peerMax <= 16_777_215:
        maxFrameSize = peerMax
    var offset = 0
    while offset < bodyBytes.len:
      let chunkLen = min(maxFrameSize, bodyBytes.len - offset)
      let isLast = offset + chunkLen >= bodyBytes.len
      let chunk = bodyBytes[offset ..< offset + chunkLen]
      await sendResponseData(conn, streamId, chunk, isLast)
      offset += chunkLen
  if streamId in conn.streams:
    conn.streams.del(streamId)

proc processServerFrame*(conn: Http2ServerConnection, frame: Http2Frame): seq[Http2Frame] =
  ## Process a received frame. Returns response frames that need to be sent.
  ## Also triggers handler dispatch for completed streams (side effect via spawn).
  if frame.frameType == FrameSettings:
    if (frame.flags and FlagAck) != 0:
      discard  # Our settings were ACKed
    else:
      # Parse peer settings
      var offset = 0
      while offset + 5 < frame.payload.len:
        let id = (uint16(frame.payload[offset]) shl 8) or uint16(frame.payload[offset + 1])
        let value = (uint32(frame.payload[offset + 2]) shl 24) or
                    (uint32(frame.payload[offset + 3]) shl 16) or
                    (uint32(frame.payload[offset + 4]) shl 8) or
                    uint32(frame.payload[offset + 5])
        conn.remoteSettings[id] = value
        offset += 6
      # ACK their settings
      result.add Http2Frame(
        frameType: FrameSettings,
        flags: FlagAck,
        streamId: 0,
        payload: @[]
      )

  elif frame.frameType == FrameHeaders:
    let streamId = frame.streamId
    # Client streams must be odd
    if streamId mod 2 == 0:
      return  # Protocol error, ignore
    if streamId > conn.lastStreamId:
      conn.lastStreamId = streamId
    var s: Http2ServerStream
    if streamId in conn.streams:
      s = conn.streams[streamId]
    else:
      if conn.maxConcurrentStreams > 0 and conn.streams.len >= conn.maxConcurrentStreams:
        # REFUSED_STREAM (0x7): temporary refusal due to stream capacity.
        result.add Http2Frame(
          frameType: FrameRstStream,
          flags: 0,
          streamId: streamId,
          payload: @[0'u8, 0'u8, 0'u8, 7'u8]
        )
        return
      s = Http2ServerStream(
        id: streamId,
        state: ssOpen,
        endStream: false
      )
      conn.streams[streamId] = s
    let headers = conn.decoder.decode(frame.payload)
    s.requestHeaders.add headers
    # Check for Extended CONNECT (RFC 8441) — dispatch immediately
    var isExtendedConnect = false
    var hasProtocol = false
    for (k, v) in s.requestHeaders:
      if k == ":method" and v == "CONNECT":
        isExtendedConnect = true
      if k == ":protocol":
        hasProtocol = true
    if isExtendedConnect and hasProtocol:
      # Extended CONNECT: create adapter now (stream stays open for data)
      s.adapter = newHttp2StreamAdapter(conn.stream, addr conn.encoder, streamId)
      let req = buildHttpRequest(s, conn)
      conn.streamGroup.spawn(dispatchHttp2Handler(conn, streamId, req))
    elif (frame.flags and FlagEndStream) != 0:
      s.endStream = true
      s.state = ssHalfClosedRemote
      # Dispatch handler — spawned as a concurrent task
      let req = buildHttpRequest(s, conn)
      conn.streamGroup.spawn(dispatchHttp2Handler(conn, streamId, req))

  elif frame.frameType == FrameData:
    let streamId = frame.streamId
    if streamId in conn.streams:
      let s = conn.streams[streamId]
      # Send WINDOW_UPDATE for flow control
      if frame.payload.len > 0:
        result.add Http2Frame(
          frameType: FrameWindowUpdate,
          flags: 0,
          streamId: 0,
          payload: @[
            byte((uint32(frame.payload.len) shr 24) and 0x7F),
            byte((uint32(frame.payload.len) shr 16) and 0xFF),
            byte((uint32(frame.payload.len) shr 8) and 0xFF),
            byte(uint32(frame.payload.len) and 0xFF)
          ]
        )
        result.add Http2Frame(
          frameType: FrameWindowUpdate,
          flags: 0,
          streamId: streamId,
          payload: @[
            byte((uint32(frame.payload.len) shr 24) and 0x7F),
            byte((uint32(frame.payload.len) shr 16) and 0xFF),
            byte((uint32(frame.payload.len) shr 8) and 0xFF),
            byte(uint32(frame.payload.len) and 0xFF)
          ]
        )
      if s.adapter != nil:
        # Feed data to the adapter (SSE/WebSocket handler reads from it)
        if frame.payload.len > 0:
          var dataStr = newString(frame.payload.len)
          for i in 0 ..< frame.payload.len:
            dataStr[i] = char(frame.payload[i])
          s.adapter.feedData(dataStr)
        if (frame.flags and FlagEndStream) != 0:
          s.endStream = true
          s.state = ssHalfClosedRemote
          s.adapter.feedEof()
      else:
        s.requestBody.add frame.payload
        if (frame.flags and FlagEndStream) != 0:
          s.endStream = true
          s.state = ssHalfClosedRemote
          let req = buildHttpRequest(s, conn)
          conn.streamGroup.spawn(dispatchHttp2Handler(conn, streamId, req))

  elif frame.frameType == FrameWindowUpdate:
    if frame.payload.len >= 4:
      let increment = (uint32(frame.payload[0] and 0x7F) shl 24) or
                      (uint32(frame.payload[1]) shl 16) or
                      (uint32(frame.payload[2]) shl 8) or
                      uint32(frame.payload[3])
      if frame.streamId == 0:
        conn.remoteWindowSize += int(increment)

  elif frame.frameType == FramePing:
    if (frame.flags and FlagAck) == 0:
      result.add Http2Frame(
        frameType: FramePing,
        flags: FlagAck,
        streamId: 0,
        payload: frame.payload
      )

  elif frame.frameType == FrameGoAway:
    conn.running = false

  elif frame.frameType == FrameRstStream:
    let streamId = frame.streamId
    if streamId in conn.streams:
      let s = conn.streams[streamId]
      s.state = ssClosed
      if s.adapter != nil:
        s.adapter.feedEof()

  # else: Unknown frame types are ignored per spec

proc handleHttp2Connection*(stream: AsyncStream, config: HttpServerConfig,
                             handler: HttpHandler): CpsVoidFuture {.cps.} =
  ## Handle an HTTP/2 connection: read preface, exchange settings,
  ## then read frames in a loop and dispatch handlers per stream.
  let conn = newHttp2ServerConnection(stream, config, handler)
  try:
    await readConnectionPreface(conn)
    await sendServerSettings(conn)

    while conn.running:
      let frame = await recvServerFrame(conn)
      let responses = processServerFrame(conn, frame)
      for i in 0 ..< responses.len:
        await sendFrame(conn, responses[i])
  except CatchableError:
    discard  # Connection closed or error — clean up
  # Cancel any in-flight stream handlers and wait for cleanup
  conn.streamGroup.cancelAll()
  stream.close()
