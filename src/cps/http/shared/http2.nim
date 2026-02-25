## HTTP/2 Client Implementation
##
## Implements the HTTP/2 protocol (RFC 7540/9113) over an AsyncStream.
## Supports multiplexed streams, HPACK header compression,
## and flow control. Uses CPS procs with BufferedReader for
## sequential async code.

import std/[strutils, tables, deques]
import ../../runtime
import ../../transform
import ../../eventloop
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
  HeaderTokenChars = {'!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^',
                      '_', '`', '|', '~'} + Digits + Letters

type
  OutboundFrameWrite = object
    frame: Http2Frame
    completion: CpsVoidFuture

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
    headerBlock*: seq[byte]
    responseFuture*: CpsFuture[Http2Response]
    windowSize*: int
    headersDone*: bool
    endStream*: bool
    finalHeadersSeen*: bool
    trailersSeen*: bool
    expectedContentLength*: int64
    headRequest*: bool

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
    goawayLastStreamId*: uint32
    continuationStreamId*: uint32
    outboundQueue*: Deque[OutboundFrameWrite]
    writerRunning*: bool
    writerWake*: CpsVoidFuture
    writerError*: ref CatchableError
    localMaxFrameSize*: int

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
    goawayReceived: false,
    goawayLastStreamId: 0x7FFF_FFFF'u32,
    continuationStreamId: 0,
    outboundQueue: initDeque[OutboundFrameWrite](),
    writerRunning: false,
    writerWake: nil,
    writerError: nil,
    localMaxFrameSize: DefaultMaxFrameSize
  )

proc frameToString(frame: Http2Frame): string =
  let data = serializeFrame(frame)
  result = newString(data.len)
  for i, b in data:
    result[i] = char(b)

proc failPendingOutbound(conn: Http2Connection, err: ref CatchableError) =
  while conn.outboundQueue.len > 0:
    let pending = conn.outboundQueue.popFirst()
    if not pending.completion.finished:
      pending.completion.fail(err)

proc runWriter(conn: Http2Connection): CpsVoidFuture {.cps.} =
  var inFlightCompletion: CpsVoidFuture = nil
  try:
    while conn.running or conn.outboundQueue.len > 0:
      if conn.outboundQueue.len == 0:
        conn.writerWake = newCpsVoidFuture()
        try:
          await conn.writerWake
        except CatchableError:
          discard
        conn.writerWake = nil
        continue

      let pending = conn.outboundQueue.popFirst()
      inFlightCompletion = pending.completion
      await conn.stream.write(frameToString(pending.frame))
      if not pending.completion.finished:
        pending.completion.complete()
      inFlightCompletion = nil
  except CatchableError as e:
    conn.writerError = e
    conn.running = false
    if not inFlightCompletion.isNil and not inFlightCompletion.finished:
      inFlightCompletion.fail(e)
    conn.failPendingOutbound(e)
  finally:
    conn.writerRunning = false

proc enqueueFrame(conn: Http2Connection, frame: Http2Frame): CpsVoidFuture =
  let fut = newCpsVoidFuture()
  if not conn.writerError.isNil:
    fut.fail(conn.writerError)
    return fut

  conn.outboundQueue.addLast(OutboundFrameWrite(frame: frame, completion: fut))

  if not conn.writerRunning:
    conn.writerRunning = true
    discard runWriter(conn)
  elif not conn.writerWake.isNil and not conn.writerWake.finished:
    conn.writerWake.complete()

  return fut

proc sendFrame*(conn: Http2Connection, frame: Http2Frame): CpsVoidFuture =
  enqueueFrame(conn, frame)

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

proc currentPeerMaxFrameSize(conn: Http2Connection): int {.inline.} =
  let value = conn.remoteSettings.getOrDefault(SettingsMaxFrameSize, DefaultMaxFrameSize.uint32)
  if value < DefaultMaxFrameSize.uint32:
    DefaultMaxFrameSize
  else:
    int(value)

proc isValidHeaderName(name: string): bool {.inline.} =
  if name.len == 0:
    return false
  for c in name:
    if c notin HeaderTokenChars:
      return false
  true

proc isValidHeaderValue(value: string): bool {.inline.} =
  for c in value:
    if c == '\r' or c == '\n' or c == '\0':
      return false
    if ord(c) < 0x20 and c != '\t':
      return false
    if ord(c) == 0x7F:
      return false
  true

proc isValidRequestPathValue(meth: string, value: string): bool {.inline.} =
  if value.len == 0:
    return false
  if value == "*":
    return meth == "OPTIONS"
  if value[0] != '/':
    return false
  for c in value:
    if ord(c) < 0x21 or ord(c) == 0x7F:
      return false
    if c == '#':
      return false
  true

proc isValidAuthorityValue(value: string): bool {.inline.} =
  if value.len == 0:
    return false
  for c in value:
    if c == ' ' or c == '\t':
      return false
    if ord(c) < 0x21 or ord(c) == 0x7F:
      return false
    if c in {'/', '?', '#'}:
      return false
  true

proc applyResponseHeaderBlock(stream: Http2Stream,
                              decoded: seq[(string, string)]): void =
  if stream.finalHeadersSeen and stream.trailersSeen:
    raise newException(system.IOError, "Duplicate trailing HEADERS frame")

  var seenRegular = false
  var sawStatus = false
  var statusCode = 0
  var sectionHeaders: seq[(string, string)] = @[]
  var sawContentLength = false
  var contentLengthValue: int64 = -1

  for i in 0 ..< decoded.len:
    let k = decoded[i][0]
    let v = decoded[i][1]

    if k.len > 0 and k[0] == ':':
      if seenRegular:
        raise newException(system.IOError, "Response pseudo-headers must appear before regular headers")
      if stream.finalHeadersSeen:
        raise newException(system.IOError, "Response trailers must not contain pseudo-headers")
      if k != ":status":
        raise newException(system.IOError, "Unsupported response pseudo-header: " & k)
      if sawStatus:
        raise newException(system.IOError, "Duplicate :status pseudo-header")
      if v.len != 3:
        raise newException(system.IOError, "Invalid :status pseudo-header")
      for ch in v:
        if ch notin Digits:
          raise newException(system.IOError, "Invalid :status pseudo-header")
      try:
        statusCode = parseInt(v)
      except ValueError:
        raise newException(system.IOError, "Invalid :status pseudo-header")
      if statusCode < 100 or statusCode > 999:
        raise newException(system.IOError, "Out-of-range :status pseudo-header")
      sawStatus = true
      sectionHeaders.add (k, v)
    else:
      let lower = k.toLowerAscii
      if k != lower:
        raise newException(system.IOError, "Response header names must be lowercase")
      if not isValidHeaderName(lower) or not isValidHeaderValue(v):
        raise newException(system.IOError, "Response contains invalid header field")
      case lower
      of "connection", "proxy-connection", "keep-alive", "upgrade", "transfer-encoding", "te":
        raise newException(system.IOError, "Response contains forbidden connection-specific header: " & lower)
      of "content-length":
        if stream.finalHeadersSeen:
          raise newException(system.IOError, "Response trailers must not contain content-length")
        if v.len == 0:
          raise newException(system.IOError, "Invalid response content-length")
        for ch in v:
          if ch notin Digits:
            raise newException(system.IOError, "Invalid response content-length")
        let parsed =
          try:
            parseBiggestInt(v)
          except ValueError:
            raise newException(system.IOError, "Invalid response content-length")
        if parsed < 0 or parsed > int64(high(int)):
          raise newException(system.IOError, "Invalid response content-length")
        let parsedLen = int64(parsed)
        if sawContentLength and parsedLen != contentLengthValue:
          raise newException(system.IOError, "Conflicting response content-length values")
        sawContentLength = true
        contentLengthValue = parsedLen
      else:
        discard
      seenRegular = true
      sectionHeaders.add (lower, v)

  if not stream.finalHeadersSeen and not sawStatus:
    raise newException(system.IOError, "Response is missing required :status pseudo-header")

  if sawStatus and statusCode >= 100 and statusCode < 200:
    if statusCode == 101:
      raise newException(system.IOError, "HTTP/2 response must not use 101 status")
    if stream.finalHeadersSeen:
      raise newException(system.IOError, "Informational response received after final response headers")
    if stream.endStream:
      raise newException(system.IOError, "Informational response must not close stream")
    return

  if stream.finalHeadersSeen:
    if not stream.endStream:
      raise newException(system.IOError, "Trailing HEADERS must include END_STREAM")
    stream.responseHeaders.add sectionHeaders
    stream.trailersSeen = true
  else:
    stream.responseHeaders = sectionHeaders
    stream.finalHeadersSeen = true
    if sawContentLength:
      stream.expectedContentLength = contentLengthValue
    else:
      stream.expectedContentLength = -1

proc buildRequestHeaders(meth: string,
                         path: string,
                         authority: string,
                         headers: seq[(string, string)],
                         pseudoHeaderOrder: seq[string],
                         bodyLen: int): seq[(string, string)] =
  if meth.len == 0:
    raise newException(ValueError, "HTTP/2 request requires non-empty method")
  if not isValidHeaderName(meth):
    raise newException(ValueError, "HTTP/2 request has invalid :method pseudo-header token")
  if authority.len == 0:
    raise newException(ValueError, "HTTP/2 request requires non-empty authority")

  if meth == "CONNECT":
    if path.len > 0:
      raise newException(
        ValueError,
        "HTTP/2 extended CONNECT requires :protocol pseudo-header and is not supported by this generic request API"
      )
  else:
    if path.len == 0:
      raise newException(ValueError, "HTTP/2 request requires non-empty path")

  if not isValidAuthorityValue(authority):
    raise newException(ValueError, "HTTP/2 request has invalid :authority pseudo-header value")
  if meth != "CONNECT" and not isValidRequestPathValue(meth, path):
    raise newException(ValueError, "HTTP/2 request has invalid :path pseudo-header value")

  let plainConnect = meth == "CONNECT" and path.len == 0
  let requiredPseudo =
    if plainConnect:
      @[
        ":method",
        ":authority"
      ]
    else:
      @[
        ":method",
        ":path",
        ":scheme",
        ":authority"
      ]

  if pseudoHeaderOrder.len > 0:
    var seenPseudo = initTable[string, bool]()
    for i in 0 ..< pseudoHeaderOrder.len:
      let ph = pseudoHeaderOrder[i]
      if ph notin requiredPseudo:
        raise newException(ValueError, "HTTP/2 pseudoHeaderOrder contains unsupported pseudo-header: " & ph)
      if ph in seenPseudo:
        raise newException(ValueError, "HTTP/2 pseudoHeaderOrder contains duplicate pseudo-header: " & ph)
      seenPseudo[ph] = true

      case ph
      of ":method":
        result.add (":method", meth)
      of ":path":
        result.add (":path", path)
      of ":scheme":
        result.add (":scheme", "https")
      of ":authority":
        result.add (":authority", authority)
      else:
        discard

    if seenPseudo.len != requiredPseudo.len:
      raise newException(ValueError, "HTTP/2 pseudoHeaderOrder must contain each required pseudo-header exactly once")
  elif plainConnect:
    result = @[
      (":method", meth),
      (":authority", authority)
    ]
  else:
    result = @[
      (":method", meth),
      (":path", path),
      (":scheme", "https"),
      (":authority", authority)
    ]

  var sawHostHeader = false
  var hostValue = ""
  var sawContentLength = false
  var contentLengthValue = -1'i64
  for i in 0 ..< headers.len:
    let lower = headers[i][0].toLowerAscii
    let value = headers[i][1]
    if lower.len > 0 and lower[0] == ':':
      raise newException(ValueError, "HTTP/2 request headers must not include pseudo-header overrides")
    if not isValidHeaderName(lower) or not isValidHeaderValue(value):
      raise newException(ValueError, "HTTP/2 request contains invalid header field")
    case lower
    of "connection", "proxy-connection", "keep-alive", "upgrade", "transfer-encoding":
      raise newException(ValueError, "HTTP/2 request contains forbidden connection-specific header: " & lower)
    of "te":
      if value.toLowerAscii != "trailers":
        raise newException(ValueError, "HTTP/2 request TE header must be \"trailers\"")
    of "host":
      if sawHostHeader:
        raise newException(ValueError, "HTTP/2 request must not include duplicate host header fields")
      if not isValidAuthorityValue(value):
        raise newException(ValueError, "HTTP/2 request has invalid host header value")
      sawHostHeader = true
      hostValue = value
    of "content-length":
      if value.len == 0:
        raise newException(ValueError, "HTTP/2 request has invalid content-length value")
      for ch in value:
        if ch notin Digits:
          raise newException(ValueError, "HTTP/2 request has invalid content-length value")
      let parsedLen =
        try:
          parseBiggestInt(value)
        except ValueError:
          raise newException(ValueError, "HTTP/2 request has invalid content-length value")
      if parsedLen < 0 or parsedLen > int64(high(int)):
        raise newException(ValueError, "HTTP/2 request has invalid content-length value")
      let parsedContentLength = int64(parsedLen)
      if sawContentLength and parsedContentLength != contentLengthValue:
        raise newException(ValueError, "HTTP/2 request has conflicting content-length values")
      sawContentLength = true
      contentLengthValue = parsedContentLength
    else:
      discard
    result.add (lower, value)

  if sawHostHeader and hostValue.toLowerAscii != authority.toLowerAscii:
    raise newException(ValueError, "HTTP/2 request host header must match :authority pseudo-header")
  if sawContentLength and contentLengthValue != int64(bodyLen):
    raise newException(ValueError, "HTTP/2 request content-length must match request body size")

proc extractHeadersFragment(frame: Http2Frame, fragment: var seq[byte]): bool =
  var idx = 0
  var padLen = 0

  if frame.frameType == FrameHeaders and (frame.flags and FlagPadded) != 0:
    if frame.payload.len < 1:
      return false
    padLen = int(frame.payload[0])
    idx = 1

  if frame.frameType == FrameHeaders and (frame.flags and FlagPriority) != 0:
    if frame.payload.len < idx + 5:
      return false
    idx += 5

  if padLen > frame.payload.len - idx:
    return false

  let endIdx = frame.payload.len - padLen
  if endIdx < idx:
    return false

  if endIdx == idx:
    fragment = @[]
  else:
    fragment = frame.payload[idx ..< endIdx]
  true

proc extractDataFragment(frame: Http2Frame, fragment: var seq[byte]): bool =
  var idx = 0
  var padLen = 0

  if (frame.flags and FlagPadded) != 0:
    if frame.payload.len < 1:
      return false
    padLen = int(frame.payload[0])
    idx = 1

  if padLen > frame.payload.len - idx:
    return false

  let endIdx = frame.payload.len - padLen
  if endIdx < idx:
    return false

  if endIdx == idx:
    fragment = @[]
  else:
    fragment = frame.payload[idx ..< endIdx]
  true

proc extractPriorityDependency(frame: Http2Frame,
                               dependency: var uint32): bool =
  if frame.payload.len != 5:
    return false
  dependency = (uint32(frame.payload[0] and 0x7F) shl 24) or
               (uint32(frame.payload[1]) shl 16) or
               (uint32(frame.payload[2]) shl 8) or
               uint32(frame.payload[3])
  true

proc extractHeadersPriorityDependency(frame: Http2Frame,
                                      dependency: var uint32): bool =
  if frame.frameType != FrameHeaders:
    return false
  if (frame.flags and FlagPriority) == 0:
    return false

  var idx = 0
  var padLen = 0
  if (frame.flags and FlagPadded) != 0:
    if frame.payload.len < 1:
      return false
    padLen = int(frame.payload[0])
    idx = 1

  if frame.payload.len < idx + 5:
    return false
  if padLen > frame.payload.len - (idx + 5):
    return false

  dependency = (uint32(frame.payload[idx] and 0x7F) shl 24) or
               (uint32(frame.payload[idx + 1]) shl 16) or
               (uint32(frame.payload[idx + 2]) shl 8) or
               uint32(frame.payload[idx + 3])
  true

proc advertisedMaxFrameSize(settings: seq[(uint16, uint32)]): int =
  result = DefaultMaxFrameSize
  for i in 0 ..< settings.len:
    let id = settings[i][0]
    let value = settings[i][1]
    if id == SettingsMaxFrameSize:
      if value < DefaultMaxFrameSize.uint32 or value > 16_777_215'u32:
        raise newException(ValueError, "Invalid SETTINGS_MAX_FRAME_SIZE")
      result = int(value)

proc statusMustNotCarryData(statusCode: int): bool {.inline.} =
  (statusCode >= 100 and statusCode < 200) or statusCode == 204 or
    statusCode == 205 or statusCode == 304

proc statusAllowsRepresentationLengthWithoutBody(statusCode: int): bool {.inline.} =
  statusCode == 304

proc tryGetFinalStatusCode(stream: Http2Stream, statusCode: var int): bool =
  for i in countdown(stream.responseHeaders.high, 0):
    if stream.responseHeaders[i][0] == ":status":
      try:
        statusCode = parseInt(stream.responseHeaders[i][1])
        return true
      except ValueError:
        return false
  false

proc completeResponse(conn: Http2Connection, streamId: uint32) =
  if streamId notin conn.streams:
    return
  let stream = conn.streams[streamId]
  stream.state = ssClosed

  var statusCode = 0
  let hasStatus = tryGetFinalStatusCode(stream, statusCode)

  if (not hasStatus) or statusCode < 200 or statusCode > 999:
    if not stream.responseFuture.isNil and not stream.responseFuture.finished:
      stream.responseFuture.fail(newException(system.IOError, "Invalid final :status in HTTP/2 response"))
    conn.streams.del(streamId)
    return

  if stream.expectedContentLength >= 0 and
      not stream.headRequest and
      not statusAllowsRepresentationLengthWithoutBody(statusCode) and
      int64(stream.responseBody.len) != stream.expectedContentLength:
    if not stream.responseFuture.isNil and not stream.responseFuture.finished:
      stream.responseFuture.fail(newException(system.IOError, "HTTP/2 response content-length mismatch"))
    conn.streams.del(streamId)
    return

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
  conn.streams.del(streamId)

proc processFrame*(conn: Http2Connection, frame: Http2Frame): seq[Http2Frame] =
  ## Process a received frame. Returns response frames that need to be sent.
  ## This is synchronous — the caller sends the response frames.

  if conn.continuationStreamId != 0 and
      (frame.frameType != FrameContinuation or frame.streamId != conn.continuationStreamId):
    raise newException(system.IOError, "Expected CONTINUATION frame")

  if frame.frameType == FrameSettings:
    if frame.streamId != 0:
      raise newException(system.IOError, "SETTINGS frame on non-zero stream")
    if (frame.flags and FlagAck) != 0:
      if frame.payload.len != 0:
        raise newException(system.IOError, "SETTINGS ACK with payload")
      conn.settingsAcked = true
    else:
      if frame.payload.len mod 6 != 0:
        raise newException(system.IOError, "Malformed SETTINGS payload")
      var offset = 0
      while offset + 5 < frame.payload.len:
        let id = (uint16(frame.payload[offset]) shl 8) or uint16(frame.payload[offset + 1])
        let value = (uint32(frame.payload[offset + 2]) shl 24) or
                    (uint32(frame.payload[offset + 3]) shl 16) or
                    (uint32(frame.payload[offset + 4]) shl 8) or
                    uint32(frame.payload[offset + 5])

        case id
        of SettingsInitialWindowSize:
          if value > 0x7FFF_FFFF'u32:
            raise newException(system.IOError, "Invalid SETTINGS_INITIAL_WINDOW_SIZE")
          let oldWin = conn.remoteSettings.getOrDefault(SettingsInitialWindowSize, DefaultWindowSize.uint32)
          let delta = int(value) - int(oldWin)
          for sid, st in conn.streams:
            let newWindow = st.windowSize + delta
            if newWindow > 0x7FFF_FFFF:
              raise newException(system.IOError, "Stream flow-control window overflow from SETTINGS")
            st.windowSize = newWindow
        of SettingsEnablePush:
          if value > 1'u32:
            raise newException(system.IOError, "Invalid SETTINGS_ENABLE_PUSH")
        of SettingsEnableConnectProtocol:
          if value > 1'u32:
            raise newException(system.IOError, "Invalid SETTINGS_ENABLE_CONNECT_PROTOCOL")
        of SettingsMaxFrameSize:
          if value < DefaultMaxFrameSize.uint32 or value > 16_777_215'u32:
            raise newException(system.IOError, "Invalid SETTINGS_MAX_FRAME_SIZE")
        else:
          discard

        conn.remoteSettings[id] = value
        offset += 6

      result.add Http2Frame(
        frameType: FrameSettings,
        flags: FlagAck,
        streamId: 0,
        payload: @[]
      )

  elif frame.frameType == FrameHeaders:
    let streamId = frame.streamId
    if streamId == 0:
      raise newException(system.IOError, "HEADERS frame on stream 0")
    if streamId notin conn.streams:
      raise newException(system.IOError, "HEADERS on unknown stream")
    let stream = conn.streams[streamId]
    if stream.headerBlock.len > 0:
      raise newException(system.IOError, "Nested header block on stream")

    if (frame.flags and FlagPriority) != 0:
      var dependency = 0'u32
      if not extractHeadersPriorityDependency(frame, dependency):
        raise newException(system.IOError, "Malformed HEADERS frame")
      if dependency == streamId:
        stream.state = ssClosed
        if not stream.responseFuture.isNil and not stream.responseFuture.finished:
          stream.responseFuture.fail(newException(system.IOError, "HEADERS priority self-dependency"))
        conn.streams.del(streamId)
        result.add Http2Frame(
          frameType: FrameRstStream,
          flags: 0,
          streamId: streamId,
          payload: @[
            0x00'u8, 0x00'u8, 0x00'u8, 0x01'u8
          ]
        )
        return

    var fragment: seq[byte]
    if not extractHeadersFragment(frame, fragment):
      raise newException(system.IOError, "Malformed HEADERS frame")

    stream.headerBlock = @[]
    stream.headerBlock.add(fragment)
    stream.headersDone = false
    if (frame.flags and FlagEndStream) != 0:
      stream.endStream = true

    if (frame.flags and FlagEndHeaders) == 0:
      conn.continuationStreamId = streamId
    else:
      let decoded = conn.decoder.decode(stream.headerBlock)
      applyResponseHeaderBlock(stream, decoded)
      stream.headerBlock.setLen(0)
      stream.headersDone = true
      if stream.endStream and stream.finalHeadersSeen:
        completeResponse(conn, streamId)

  elif frame.frameType == FrameContinuation:
    let streamId = frame.streamId
    if conn.continuationStreamId == 0 or streamId != conn.continuationStreamId:
      raise newException(system.IOError, "CONTINUATION without HEADERS")
    if streamId notin conn.streams:
      raise newException(system.IOError, "CONTINUATION for unknown stream")
    let stream = conn.streams[streamId]
    var fragment: seq[byte]
    if not extractHeadersFragment(frame, fragment):
      raise newException(system.IOError, "Malformed CONTINUATION frame")
    stream.headerBlock.add(fragment)
    if (frame.flags and FlagEndHeaders) != 0:
      conn.continuationStreamId = 0
      let decoded = conn.decoder.decode(stream.headerBlock)
      applyResponseHeaderBlock(stream, decoded)
      stream.headerBlock.setLen(0)
      stream.headersDone = true
      if stream.endStream and stream.finalHeadersSeen:
        completeResponse(conn, streamId)

  elif frame.frameType == FrameData:
    let streamId = frame.streamId
    if streamId == 0:
      raise newException(system.IOError, "DATA frame on stream 0")
    if streamId notin conn.streams:
      raise newException(system.IOError, "DATA on unknown stream")
    let stream = conn.streams[streamId]
    if not stream.headersDone:
      raise newException(system.IOError, "DATA before END_HEADERS")
    if not stream.finalHeadersSeen:
      raise newException(system.IOError, "DATA before final response HEADERS")
    if stream.trailersSeen:
      raise newException(system.IOError, "DATA after trailing HEADERS")
    var dataFragment: seq[byte]
    if not extractDataFragment(frame, dataFragment):
      raise newException(system.IOError, "Malformed DATA frame")
    if stream.headRequest and dataFragment.len > 0:
      raise newException(system.IOError, "HEAD response must not contain DATA")
    if dataFragment.len > 0:
      var statusCode = 0
      if tryGetFinalStatusCode(stream, statusCode) and statusMustNotCarryData(statusCode):
        raise newException(system.IOError, "HTTP/2 no-content response must not contain DATA")
    stream.responseBody.add dataFragment
    if stream.expectedContentLength >= 0 and not stream.headRequest and
        int64(stream.responseBody.len) > stream.expectedContentLength:
      raise newException(system.IOError, "HTTP/2 response body exceeds content-length")
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
      completeResponse(conn, streamId)

  elif frame.frameType == FrameWindowUpdate:
    if frame.payload.len != 4:
      raise newException(system.IOError, "Malformed WINDOW_UPDATE")
    let increment = (uint32(frame.payload[0] and 0x7F) shl 24) or
                    (uint32(frame.payload[1]) shl 16) or
                    (uint32(frame.payload[2]) shl 8) or
                    uint32(frame.payload[3])
    if increment == 0:
      if frame.streamId == 0:
        raise newException(system.IOError, "WINDOW_UPDATE with zero increment")
      elif frame.streamId in conn.streams:
        let stream = conn.streams[frame.streamId]
        stream.state = ssClosed
        if not stream.responseFuture.isNil and not stream.responseFuture.finished:
          stream.responseFuture.fail(newException(system.IOError, "Stream WINDOW_UPDATE with zero increment"))
        conn.streams.del(frame.streamId)
        result.add Http2Frame(
          frameType: FrameRstStream,
          flags: 0,
          streamId: frame.streamId,
          payload: @[
            0x00'u8, 0x00'u8, 0x00'u8, 0x01'u8
          ]
        )
      elif (frame.streamId mod 2) == 0 or frame.streamId >= conn.nextStreamId:
        raise newException(system.IOError, "WINDOW_UPDATE with zero increment")
      return
    if frame.streamId == 0:
      let newWindow = conn.remoteWindowSize + int(increment)
      if newWindow > 0x7FFF_FFFF:
        raise newException(system.IOError, "Connection flow-control window overflow")
      conn.remoteWindowSize = newWindow
    elif frame.streamId in conn.streams:
      let stream = conn.streams[frame.streamId]
      let newWindow = stream.windowSize + int(increment)
      if newWindow > 0x7FFF_FFFF:
        stream.state = ssClosed
        if not stream.responseFuture.isNil and not stream.responseFuture.finished:
          stream.responseFuture.fail(newException(system.IOError, "Stream flow-control window overflow"))
        conn.streams.del(frame.streamId)
      else:
        stream.windowSize = newWindow
    elif (frame.streamId mod 2) == 0 or frame.streamId >= conn.nextStreamId:
      raise newException(system.IOError, "WINDOW_UPDATE on idle stream")

  elif frame.frameType == FrameGoAway:
    if frame.streamId != 0:
      raise newException(system.IOError, "GOAWAY frame on non-zero stream")
    if frame.payload.len < 8:
      raise newException(system.IOError, "Malformed GOAWAY frame")
    let lastStreamId = (uint32(frame.payload[0] and 0x7F) shl 24) or
                       (uint32(frame.payload[1]) shl 16) or
                       (uint32(frame.payload[2]) shl 8) or
                       uint32(frame.payload[3])
    let errorCode = (uint32(frame.payload[4]) shl 24) or
                    (uint32(frame.payload[5]) shl 16) or
                    (uint32(frame.payload[6]) shl 8) or
                    uint32(frame.payload[7])
    conn.goawayReceived = true
    conn.goawayLastStreamId = min(conn.goawayLastStreamId, lastStreamId)

    var toDrop: seq[uint32]
    for sid, stream in conn.streams:
      if sid > conn.goawayLastStreamId:
        if not stream.responseFuture.isNil and not stream.responseFuture.finished:
          stream.responseFuture.fail(
            newException(system.IOError, "Stream rejected by peer GOAWAY"))
        toDrop.add(sid)
      elif errorCode != 0'u32 and
          not stream.responseFuture.isNil and not stream.responseFuture.finished:
        stream.responseFuture.fail(
          newException(system.IOError, "Peer sent GOAWAY error code " & $errorCode))
    for i in 0 ..< toDrop.len:
      conn.streams.del(toDrop[i])

  elif frame.frameType == FramePing:
    if frame.streamId != 0 or frame.payload.len != 8:
      raise newException(system.IOError, "Malformed PING frame")
    if (frame.flags and FlagAck) == 0:
      result.add Http2Frame(
        frameType: FramePing,
        flags: FlagAck,
        streamId: 0,
        payload: frame.payload
      )

  elif frame.frameType == FramePriority:
    if frame.payload.len != 5:
      raise newException(system.IOError, "Malformed PRIORITY frame")
    if frame.streamId == 0:
      raise newException(system.IOError, "PRIORITY frame on stream 0")
    var dependency = 0'u32
    if not extractPriorityDependency(frame, dependency):
      raise newException(system.IOError, "Malformed PRIORITY frame")
    if dependency == frame.streamId:
      if frame.streamId in conn.streams:
        let stream = conn.streams[frame.streamId]
        stream.state = ssClosed
        if not stream.responseFuture.isNil and not stream.responseFuture.finished:
          stream.responseFuture.fail(newException(system.IOError, "PRIORITY self-dependency"))
        conn.streams.del(frame.streamId)
        result.add Http2Frame(
          frameType: FrameRstStream,
          flags: 0,
          streamId: frame.streamId,
          payload: @[
            0x00'u8, 0x00'u8, 0x00'u8, 0x01'u8
          ]
        )
      elif (frame.streamId mod 2) == 0 or frame.streamId >= conn.nextStreamId:
        raise newException(system.IOError, "PRIORITY self-dependency on idle stream")

  elif frame.frameType == FrameRstStream:
    if frame.streamId == 0 or frame.payload.len != 4:
      raise newException(system.IOError, "Malformed RST_STREAM frame")
    let streamId = frame.streamId
    if streamId in conn.streams:
      let stream = conn.streams[streamId]
      stream.state = ssClosed
      if not stream.responseFuture.isNil and not stream.responseFuture.finished:
        stream.responseFuture.fail(newException(system.IOError, "Stream reset"))
      conn.streams.del(streamId)
    elif (streamId mod 2) == 0 or streamId >= conn.nextStreamId:
      raise newException(system.IOError, "RST_STREAM on idle stream")

  elif frame.frameType == FramePushPromise:
    raise newException(system.IOError, "PUSH_PROMISE is not supported by this client")

  # Unknown frame types are ignored per spec.

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
  if int(frame.length) > conn.localMaxFrameSize:
    raise newException(system.IOError, "Inbound frame exceeds local max frame size")

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
  conn.localMaxFrameSize = DefaultMaxFrameSize
  if h2fp != nil and h2fp.settings.len > 0:
    conn.localMaxFrameSize = advertisedMaxFrameSize(h2fp.settings)
    await sendSettings(conn, h2fp.settings)
  else:
    await sendSettings(conn, @[
      (SettingsEnablePush, 0'u32),
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
    while conn.running:
      let frame = await recvFrame(conn)
      let responses = processFrame(conn, frame)
      for i in 0 ..< responses.len:
        await sendFrame(conn, responses[i])
  except CatchableError as e:
    conn.running = false
    failAllStreams(conn, e)
    conn.failPendingOutbound(e)
  finally:
    conn.running = false
    if not conn.writerWake.isNil and not conn.writerWake.finished:
      conn.writerWake.complete()

proc waitForSendWindow(conn: Http2Connection, streamId: uint32): CpsVoidFuture {.cps.} =
  while conn.running and streamId in conn.streams:
    let stream = conn.streams[streamId]
    if conn.remoteWindowSize > 0 and stream.windowSize > 0:
      return
    await cpsSleep(1)

proc request*(conn: Http2Connection, meth: string, path: string,
              authority: string, headers: seq[(string, string)] = @[],
              body: string = "",
              pseudoHeaderOrder: seq[string] = @[]): CpsFuture[Http2Response] {.cps.} =
  ## Send an HTTP/2 request and wait for the response.
  ## When `pseudoHeaderOrder` is provided, pseudo-headers are emitted in
  ## that order instead of the default :method, :path, :scheme, :authority.
  if not conn.running:
    raise newException(system.IOError, "HTTP/2 connection is not running")
  if conn.goawayReceived:
    raise newException(system.IOError, "GOAWAY received; cannot create new streams")
  if conn.nextStreamId == 0'u32 or conn.nextStreamId > 0x7FFF_FFFF'u32:
    raise newException(system.IOError, "HTTP/2 stream ID space exhausted")

  let reqHeaders = buildRequestHeaders(meth, path, authority, headers, pseudoHeaderOrder, body.len)

  let streamId = conn.nextStreamId
  conn.nextStreamId += 2  # Client streams are odd

  let responseFut = newCpsFuture[Http2Response]()
  let initialWindow = int(conn.remoteSettings.getOrDefault(
    SettingsInitialWindowSize, DefaultWindowSize.uint32))
  let stream = Http2Stream(
    id: streamId,
    state: ssOpen,
    windowSize: initialWindow,
    headerBlock: @[],
    responseFuture: responseFut,
    finalHeadersSeen: false,
    trailersSeen: false,
    expectedContentLength: -1,
    headRequest: meth == "HEAD"
  )
  conn.streams[streamId] = stream

  try:
    # Encode headers with HPACK
    let encodedHeaders = conn.encoder.encode(reqHeaders)

    let maxFrame = conn.currentPeerMaxFrameSize()

    # Send HEADERS/CONTINUATION sequence.
    var hdrOffset = 0
    var firstHdr = true
    while hdrOffset < encodedHeaders.len or (firstHdr and encodedHeaders.len == 0):
      let remaining = encodedHeaders.len - hdrOffset
      let chunkLen =
        if remaining <= 0: 0
        else: min(maxFrame, remaining)
      let chunk =
        if chunkLen <= 0: @[]
        else: encodedHeaders[hdrOffset ..< hdrOffset + chunkLen]

      var flags: uint8 = 0
      if hdrOffset + chunkLen >= encodedHeaders.len:
        flags = flags or FlagEndHeaders
      if firstHdr and body.len == 0:
        flags = flags or FlagEndStream

      let ftype = if firstHdr: FrameHeaders else: FrameContinuation
      await sendFrame(conn, Http2Frame(
        frameType: ftype,
        flags: flags,
        streamId: streamId,
        payload: chunk
      ))

      firstHdr = false
      hdrOffset += chunkLen
      if encodedHeaders.len == 0:
        break

    # Send DATA using frame-size and flow-control constraints.
    if body.len > 0:
      let dataPayload = newSeq[byte](body.len)
      for i in 0 ..< body.len:
        dataPayload[i] = byte(body[i])
      var offset = 0
      while offset < dataPayload.len and conn.running and streamId in conn.streams:
        await waitForSendWindow(conn, streamId)
        if streamId notin conn.streams:
          break

        let s = conn.streams[streamId]
        let remaining = dataPayload.len - offset
        let window = min(conn.remoteWindowSize, s.windowSize)
        let chunkLen = min(min(maxFrame, remaining), window)
        if chunkLen <= 0:
          continue

        conn.remoteWindowSize -= chunkLen
        s.windowSize -= chunkLen

        let lastChunk = (offset + chunkLen) >= dataPayload.len
        await sendFrame(conn, Http2Frame(
          frameType: FrameData,
          flags: (if lastChunk: FlagEndStream else: 0'u8),
          streamId: streamId,
          payload: dataPayload[offset ..< offset + chunkLen]
        ))
        offset += chunkLen
  except CatchableError as e:
    if streamId in conn.streams:
      conn.streams.del(streamId)
    if not responseFut.finished:
      responseFut.fail(e)
    raise

  # Wait for response (completed by runReceiveLoop via processFrame)
  return await responseFut
