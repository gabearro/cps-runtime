## HTTP/2 Client Implementation
##
## Implements the HTTP/2 protocol (RFC 7540/9113) over an AsyncStream.
## Supports multiplexed streams, HPACK header compression,
## and flow control. Uses CPS procs with BufferedReader for
## sequential async code.

import std/[strutils, tables]
import ../../runtime
import ../../transform
import ../../io/streams
import ../../io/buffered
import ./hpack
import ../../tls/fingerprint

# ============================================================
# HTTP/2 Frame Types (RFC 7540 section 6)
# ============================================================

const
  FrameData*         = 0x0'u8
  FrameHeaders*      = 0x1'u8
  FramePriority*     = 0x2'u8
  FrameRstStream*    = 0x3'u8
  FrameSettings*     = 0x4'u8
  FramePushPromise*  = 0x5'u8
  FramePing*         = 0x6'u8
  FrameGoAway*       = 0x7'u8
  FrameWindowUpdate* = 0x8'u8
  FrameContinuation* = 0x9'u8

  # Flags
  FlagEndStream*     = 0x1'u8
  FlagEndHeaders*    = 0x4'u8
  FlagPadded*        = 0x8'u8
  FlagPriority*      = 0x20'u8
  FlagAck*           = 0x1'u8

  # Settings identifiers
  SettingsHeaderTableSize*      = 0x1'u16
  SettingsEnablePush*           = 0x2'u16
  SettingsMaxConcurrentStreams* = 0x3'u16
  SettingsInitialWindowSize*    = 0x4'u16
  SettingsMaxFrameSize*         = 0x5'u16
  SettingsMaxHeaderListSize*    = 0x6'u16
  SettingsEnableConnectProtocol* = 0x8'u16

  # Connection preface
  ConnectionPreface* = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  DefaultWindowSize* = 65535
  DefaultMaxFrameSize* = 16384

type
  Http2Frame* = object
    length*: uint32
    frameType*: uint8
    flags*: uint8
    streamId*: uint32
    payload*: seq[byte]

  Http2StreamState* = enum
    ssIdle, ssOpen, ssReservedLocal, ssReservedRemote,
    ssHalfClosedLocal, ssHalfClosedRemote, ssClosed

  Http2Stream* = ref object
    id*: uint32
    state*: Http2StreamState
    responseHeaders*: seq[(string, string)]
    responseBody*: seq[byte]
    responseFuture*: CpsFuture[Http2Response]
    windowSize*: int
    headersDone*: bool
    endStream*: bool

  Http2Response* = object
    statusCode*: int
    headers*: seq[(string, string)]
    body*: string

  Http2Connection* = ref object
    stream*: AsyncStream
    reader*: BufferedReader
    streams*: Table[uint32, Http2Stream]
    nextStreamId*: uint32
    encoder*: HpackEncoder
    decoder*: HpackDecoder
    localWindowSize*: int
    remoteWindowSize*: int
    remoteSettings*: Table[uint16, uint32]
    settingsAcked*: bool
    running*: bool
    goawayReceived*: bool

# ============================================================
# Frame serialization
# ============================================================

proc serializeFrame*(frame: Http2Frame): seq[byte] =
  ## Serialize a frame to bytes (9-byte header + payload).
  let length = frame.payload.len.uint32
  result = newSeq[byte](9 + frame.payload.len)
  # Length (24 bits, big-endian)
  result[0] = byte((length shr 16) and 0xFF)
  result[1] = byte((length shr 8) and 0xFF)
  result[2] = byte(length and 0xFF)
  # Type
  result[3] = frame.frameType
  # Flags
  result[4] = frame.flags
  # Stream ID (31 bits, big-endian, R bit = 0)
  result[5] = byte((frame.streamId shr 24) and 0x7F)
  result[6] = byte((frame.streamId shr 16) and 0xFF)
  result[7] = byte((frame.streamId shr 8) and 0xFF)
  result[8] = byte(frame.streamId and 0xFF)
  # Payload
  for i, b in frame.payload:
    result[9 + i] = b

proc toFrameBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(c)

proc parseFrame*(data: seq[byte]): Http2Frame =
  ## Parse a frame from a 9+ byte buffer.
  assert data.len >= 9
  result.length = (uint32(data[0]) shl 16) or (uint32(data[1]) shl 8) or uint32(data[2])
  result.frameType = data[3]
  result.flags = data[4]
  result.streamId = (uint32(data[5] and 0x7F) shl 24) or
                    (uint32(data[6]) shl 16) or
                    (uint32(data[7]) shl 8) or
                    uint32(data[8])
  if data.len > 9:
    result.payload = data[9 ..< 9 + int(result.length)]

# ============================================================
# HTTP/2 Connection
# ============================================================

proc newHttp2Connection*(stream: AsyncStream): Http2Connection =
  let reader = newBufferedReader(stream)
  Http2Connection(
    stream: stream,
    reader: reader,
    streams: initTable[uint32, Http2Stream](),
    nextStreamId: 1,  # Client streams are odd
    encoder: initHpackEncoder(),
    decoder: initHpackDecoder(),
    localWindowSize: DefaultWindowSize,
    remoteWindowSize: DefaultWindowSize,
    remoteSettings: initTable[uint16, uint32](),
    settingsAcked: false,
    running: false,
    goawayReceived: false
  )

proc sendFrame*(conn: Http2Connection, frame: Http2Frame): CpsVoidFuture =
  let data = serializeFrame(frame)
  var str = newString(data.len)
  for i, b in data:
    str[i] = char(b)
  conn.stream.write(str)

proc sendSettings*(conn: Http2Connection, settings: seq[(uint16, uint32)] = @[]): CpsVoidFuture =
  var payload: seq[byte]
  for (id, value) in settings:
    payload.add byte((id shr 8) and 0xFF)
    payload.add byte(id and 0xFF)
    payload.add byte((value shr 24) and 0xFF)
    payload.add byte((value shr 16) and 0xFF)
    payload.add byte((value shr 8) and 0xFF)
    payload.add byte(value and 0xFF)
  let frame = Http2Frame(
    frameType: FrameSettings,
    flags: 0,
    streamId: 0,
    payload: payload
  )
  sendFrame(conn, frame)

proc sendSettingsAck*(conn: Http2Connection): CpsVoidFuture =
  let frame = Http2Frame(
    frameType: FrameSettings,
    flags: FlagAck,
    streamId: 0,
    payload: @[]
  )
  sendFrame(conn, frame)

proc sendWindowUpdate*(conn: Http2Connection, streamId: uint32, increment: uint32): CpsVoidFuture =
  var payload: seq[byte] = @[
    byte((increment shr 24) and 0x7F),
    byte((increment shr 16) and 0xFF),
    byte((increment shr 8) and 0xFF),
    byte(increment and 0xFF)
  ]
  let frame = Http2Frame(
    frameType: FrameWindowUpdate,
    flags: 0,
    streamId: streamId,
    payload: payload
  )
  sendFrame(conn, frame)

# ============================================================
# Frame processing (synchronous — returns response frames to send)
# ============================================================

proc failAllStreams*(conn: Http2Connection, err: ref CatchableError) =
  ## Fail all pending stream futures. Extracted because Table iteration
  ## can't be done inside CPS procs.
  for id, stream in conn.streams:
    if not stream.responseFuture.isNil and not stream.responseFuture.finished:
      stream.responseFuture.fail(err)

proc processFrame*(conn: Http2Connection, frame: Http2Frame): seq[Http2Frame] =
  ## Process a received frame. Returns response frames that need to be sent.
  ## This is synchronous — the caller sends the response frames.

  if frame.frameType == FrameSettings:
    if (frame.flags and FlagAck) != 0:
      conn.settingsAcked = true
    else:
      # Parse settings
      var offset = 0
      while offset + 5 < frame.payload.len:
        let id = (uint16(frame.payload[offset]) shl 8) or uint16(frame.payload[offset + 1])
        let value = (uint32(frame.payload[offset + 2]) shl 24) or
                    (uint32(frame.payload[offset + 3]) shl 16) or
                    (uint32(frame.payload[offset + 4]) shl 8) or
                    uint32(frame.payload[offset + 5])
        conn.remoteSettings[id] = value
        offset += 6
      # Queue ACK
      result.add Http2Frame(
        frameType: FrameSettings,
        flags: FlagAck,
        streamId: 0,
        payload: @[]
      )

  elif frame.frameType == FrameHeaders:
    let streamId = frame.streamId
    if streamId in conn.streams:
      let stream = conn.streams[streamId]
      let headers = conn.decoder.decode(frame.payload)
      stream.responseHeaders.add headers
      stream.headersDone = (frame.flags and FlagEndHeaders) != 0
      if (frame.flags and FlagEndStream) != 0:
        stream.endStream = true
        stream.state = ssClosed
        var statusCode = 200
        for (k, v) in stream.responseHeaders:
          if k == ":status":
            statusCode = parseInt(v)
        let resp = Http2Response(
          statusCode: statusCode,
          headers: stream.responseHeaders,
          body: cast[string](stream.responseBody)
        )
        if not stream.responseFuture.isNil and not stream.responseFuture.finished:
          stream.responseFuture.complete(resp)

  elif frame.frameType == FrameData:
    let streamId = frame.streamId
    if streamId in conn.streams:
      let stream = conn.streams[streamId]
      stream.responseBody.add frame.payload
      # Queue WINDOW_UPDATE for flow control
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
      if (frame.flags and FlagEndStream) != 0:
        stream.endStream = true
        stream.state = ssClosed
        var statusCode = 200
        for (k, v) in stream.responseHeaders:
          if k == ":status":
            statusCode = parseInt(v)
        var bodyStr = newString(stream.responseBody.len)
        for i, b in stream.responseBody:
          bodyStr[i] = char(b)
        let resp = Http2Response(
          statusCode: statusCode,
          headers: stream.responseHeaders,
          body: bodyStr
        )
        if not stream.responseFuture.isNil and not stream.responseFuture.finished:
          stream.responseFuture.complete(resp)

  elif frame.frameType == FrameWindowUpdate:
    if frame.payload.len >= 4:
      let increment = (uint32(frame.payload[0] and 0x7F) shl 24) or
                      (uint32(frame.payload[1]) shl 16) or
                      (uint32(frame.payload[2]) shl 8) or
                      uint32(frame.payload[3])
      if frame.streamId == 0:
        conn.remoteWindowSize += int(increment)
      elif frame.streamId in conn.streams:
        conn.streams[frame.streamId].windowSize += int(increment)

  elif frame.frameType == FrameGoAway:
    conn.goawayReceived = true

  elif frame.frameType == FramePing:
    if (frame.flags and FlagAck) == 0:
      # Queue PONG
      result.add Http2Frame(
        frameType: FramePing,
        flags: FlagAck,
        streamId: 0,
        payload: frame.payload
      )

  elif frame.frameType == FrameRstStream:
    let streamId = frame.streamId
    if streamId in conn.streams:
      let stream = conn.streams[streamId]
      stream.state = ssClosed
      if not stream.responseFuture.isNil and not stream.responseFuture.finished:
        stream.responseFuture.fail(newException(system.IOError, "Stream reset"))

  # else: Unknown frame types are ignored per spec

# ============================================================
# CPS procs
# ============================================================

proc recvFrame*(conn: Http2Connection): CpsFuture[Http2Frame] {.cps.} =
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

proc initConnection*(conn: Http2Connection,
                     h2fp: Http2Fingerprint = nil): CpsVoidFuture {.cps.} =
  ## Send the HTTP/2 connection preface and initial SETTINGS.
  ## When `h2fp` is provided, uses the fingerprint's SETTINGS and WINDOW_UPDATE.
  await conn.stream.write(ConnectionPreface)
  if h2fp != nil and h2fp.settings.len > 0:
    await sendSettings(conn, h2fp.settings)
  else:
    await sendSettings(conn, @[
      (SettingsMaxConcurrentStreams, 100'u32),
      (SettingsInitialWindowSize, 65535'u32)
    ])
  # Send connection-level WINDOW_UPDATE if fingerprint specifies it
  if h2fp != nil and h2fp.windowUpdateIncrement > 0:
    await sendWindowUpdate(conn, 0, h2fp.windowUpdateIncrement)
  conn.running = true

proc runReceiveLoop*(conn: Http2Connection): CpsVoidFuture {.cps.} =
  ## Read frames in a loop. Call this once after initConnection.
  try:
    while conn.running and not conn.goawayReceived:
      let frame = await recvFrame(conn)
      let responses = processFrame(conn, frame)
      for i in 0 ..< responses.len:
        await sendFrame(conn, responses[i])
  except CatchableError as e:
    conn.running = false
    failAllStreams(conn, e)

proc request*(conn: Http2Connection, meth: string, path: string,
              authority: string, headers: seq[(string, string)] = @[],
              body: string = "",
              pseudoHeaderOrder: seq[string] = @[]): CpsFuture[Http2Response] {.cps.} =
  ## Send an HTTP/2 request and wait for the response.
  ## When `pseudoHeaderOrder` is provided, pseudo-headers are emitted in
  ## that order instead of the default :method, :path, :scheme, :authority.
  let streamId = conn.nextStreamId
  conn.nextStreamId += 2  # Client streams are odd

  let responseFut = newCpsFuture[Http2Response]()
  let stream = Http2Stream(
    id: streamId,
    state: ssOpen,
    windowSize: DefaultWindowSize,
    responseFuture: responseFut
  )
  conn.streams[streamId] = stream

  # Build pseudo-headers in specified or default order
  let pseudoValues = {":method": meth, ":path": path,
                      ":scheme": "https", ":authority": authority}
  var reqHeaders: seq[(string, string)]
  if pseudoHeaderOrder.len > 0:
    for ph in pseudoHeaderOrder:
      for (k, v) in pseudoValues:
        if k == ph:
          reqHeaders.add (k, v)
          break
  else:
    reqHeaders = @[
      (":method", meth),
      (":path", path),
      (":scheme", "https"),
      (":authority", authority)
    ]
  for i in 0 ..< headers.len:
    reqHeaders.add (headers[i][0].toLowerAscii, headers[i][1])

  # Encode headers with HPACK
  let encodedHeaders = conn.encoder.encode(reqHeaders)

  # Send HEADERS frame
  var flags: uint8 = FlagEndHeaders
  if body.len == 0:
    flags = flags or FlagEndStream

  let headersFrame = Http2Frame(
    frameType: FrameHeaders,
    flags: flags,
    streamId: streamId,
    payload: encodedHeaders
  )
  await sendFrame(conn, headersFrame)

  # Send DATA if body present
  if body.len > 0:
    let dataPayload = newSeq[byte](body.len)
    for i in 0 ..< body.len:
      dataPayload[i] = byte(body[i])
    let dataFrame = Http2Frame(
      frameType: FrameData,
      flags: FlagEndStream,
      streamId: streamId,
      payload: dataPayload
    )
    await sendFrame(conn, dataFrame)

  # Wait for response (completed by runReceiveLoop via processFrame)
  return await responseFut
