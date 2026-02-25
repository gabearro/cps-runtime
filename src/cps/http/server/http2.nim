## HTTP/2 Server Implementation
##
## Server-side HTTP/2 frame processing, stream dispatch, strict request parsing,
## and connection-scoped serialized writes.

import std/[strutils, tables, deques]
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
  OutboundFrameWrite = object
    frame: Http2Frame
    completion: CpsVoidFuture

  Http2ServerStream* = ref object
    id*: uint32
    state*: Http2StreamState
    requestHeaders*: seq[(string, string)]
    requestBody*: seq[byte]
    endStream*: bool
    adapter*: Http2StreamAdapter
    remoteWindowSize*: int
    bodyBytesRead*: int
    headerBlock*: seq[byte]
    headerBlockEndStream*: bool
    headersComplete*: bool
    dispatched*: bool
    windowWaiters*: seq[CpsVoidFuture]
    expectedContentLength*: int64

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
    peerInitialWindowSize*: int
    peerMaxFrameSize*: int
    acceptingNewStreams*: bool
    continuationStreamId*: uint32
    outboundQueue*: Deque[OutboundFrameWrite]
    writerRunning*: bool
    writerWake*: CpsVoidFuture
    writerError*: ref CatchableError
    connectionWindowWaiters*: seq[CpsVoidFuture]
    shutdownFlag*: ptr bool
    goAwaySent*: bool
    remoteAddr*: string
    seenPeerStreams*: Table[uint32, bool]

const
  H2ErrNoError = 0'u32
  H2ErrProtocolError = 1'u32
  H2ErrInternalError = 2'u32
  H2ErrFlowControlError = 3'u32
  H2ErrSettingsTimeout = 4'u32
  H2ErrStreamClosed = 5'u32
  H2ErrFrameSizeError = 6'u32
  H2ErrRefusedStream = 7'u32
  H2ErrCancel = 8'u32
  H2ErrCompressionError = 9'u32
  H2ErrEnhanceYourCalm = 11'u32

proc frameToString(frame: Http2Frame): string =
  let data = serializeFrame(frame)
  result = newString(data.len)
  for i in 0 ..< data.len:
    result[i] = char(data[i])

proc wakeWaiters(waiters: var seq[CpsVoidFuture]) =
  for i in 0 ..< waiters.len:
    let fut = waiters[i]
    if not fut.isNil and not fut.finished:
      fut.complete()
  waiters.setLen(0)

proc failWaiters(waiters: var seq[CpsVoidFuture], err: ref CatchableError) =
  for i in 0 ..< waiters.len:
    let fut = waiters[i]
    if not fut.isNil and not fut.finished:
      fut.fail(err)
  waiters.setLen(0)

proc newHttp2ServerConnection*(s: AsyncStream, config: HttpServerConfig,
                               handler: HttpHandler,
                               shutdownFlag: ptr bool = nil,
                               remoteAddr: string = ""): Http2ServerConnection =
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
    streamGroup: newTaskGroup(epCollectAll),
    peerInitialWindowSize: DefaultWindowSize,
    peerMaxFrameSize: DefaultMaxFrameSize,
    acceptingNewStreams: true,
    continuationStreamId: 0,
    outboundQueue: initDeque[OutboundFrameWrite](),
    writerRunning: false,
    writerWake: nil,
    writerError: nil,
    connectionWindowWaiters: @[],
    shutdownFlag: shutdownFlag,
    goAwaySent: false,
    remoteAddr: remoteAddr,
    seenPeerStreams: initTable[uint32, bool]()
  )

proc failPendingOutbound(conn: Http2ServerConnection, err: ref CatchableError) =
  while conn.outboundQueue.len > 0:
    let pending = conn.outboundQueue.popFirst()
    if not pending.completion.finished:
      pending.completion.fail(err)

proc runWriter(conn: Http2ServerConnection): CpsVoidFuture {.cps.} =
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
      let serialized = frameToString(pending.frame)
      inFlightCompletion = pending.completion
      await conn.stream.write(serialized)
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

proc enqueueFrame(conn: Http2ServerConnection, frame: Http2Frame): CpsVoidFuture =
  let fut = newCpsVoidFuture()
  if not conn.running:
    fut.fail(newException(system.IOError, "HTTP/2 connection is closed"))
    return fut
  if not conn.writerError.isNil:
    fut.fail(conn.writerError)
    return fut

  conn.outboundQueue.addLast(OutboundFrameWrite(frame: frame, completion: fut))

  if not conn.writerRunning:
    conn.writerRunning = true
    conn.streamGroup.spawn(runWriter(conn))
  elif not conn.writerWake.isNil and not conn.writerWake.finished:
    conn.writerWake.complete()

  return fut

proc sendFrame*(conn: Http2ServerConnection, frame: Http2Frame): CpsVoidFuture {.cps.} =
  await enqueueFrame(conn, frame)

proc sendRstStream(conn: Http2ServerConnection, streamId: uint32,
                   errorCode: uint32): CpsVoidFuture {.cps.} =
  let payload = @[
    byte((errorCode shr 24) and 0xFF),
    byte((errorCode shr 16) and 0xFF),
    byte((errorCode shr 8) and 0xFF),
    byte(errorCode and 0xFF)
  ]
  await sendFrame(conn, Http2Frame(
    frameType: FrameRstStream,
    flags: 0,
    streamId: streamId,
    payload: payload
  ))

proc sendGoAway*(conn: Http2ServerConnection, errorCode: uint32,
                 lastStreamId: uint32 = 0'u32): CpsVoidFuture {.cps.} =
  if conn.goAwaySent:
    return
  conn.goAwaySent = true

  let lastId = if lastStreamId == 0'u32: conn.lastStreamId else: lastStreamId
  var payload: seq[byte]
  payload.add byte((lastId shr 24) and 0x7F)
  payload.add byte((lastId shr 16) and 0xFF)
  payload.add byte((lastId shr 8) and 0xFF)
  payload.add byte(lastId and 0xFF)
  payload.add byte((errorCode shr 24) and 0xFF)
  payload.add byte((errorCode shr 16) and 0xFF)
  payload.add byte((errorCode shr 8) and 0xFF)
  payload.add byte(errorCode and 0xFF)

  await sendFrame(conn, Http2Frame(
    frameType: FrameGoAway,
    flags: 0,
    streamId: 0,
    payload: payload
  ))

proc failConnection(conn: Http2ServerConnection, errorCode: uint32): CpsVoidFuture {.cps.} =
  if conn.running and not conn.goAwaySent:
    try:
      await conn.sendGoAway(errorCode)
    except CatchableError:
      discard
  conn.running = false

proc wakeConnectionWaiters(conn: Http2ServerConnection) =
  wakeWaiters(conn.connectionWindowWaiters)

proc failConnectionWaiters(conn: Http2ServerConnection, err: ref CatchableError) =
  failWaiters(conn.connectionWindowWaiters, err)

proc applyPeerInitialWindowSize(conn: Http2ServerConnection,
                                newInitialWindowSize: int): bool =
  let delta = newInitialWindowSize - conn.peerInitialWindowSize

  if delta == 0:
    return true

  for sid, streamRef in conn.streams:
    let newWindow = streamRef.remoteWindowSize + delta
    if newWindow > 0x7FFF_FFFF:
      return false

  conn.peerInitialWindowSize = newInitialWindowSize
  for sid, streamRef in conn.streams:
    streamRef.remoteWindowSize += delta
    wakeWaiters(streamRef.windowWaiters)

  true

proc closeStream(conn: Http2ServerConnection, streamId: uint32,
                 err: ref CatchableError = nil) =
  if streamId notin conn.streams:
    return
  let s = conn.streams[streamId]
  s.state = ssClosed
  if s.adapter != nil:
    s.adapter.feedEof()
  if err.isNil:
    wakeWaiters(s.windowWaiters)
  else:
    failWaiters(s.windowWaiters, err)
  conn.streams.del(streamId)

proc peerStreamWasOpened(conn: Http2ServerConnection,
                         streamId: uint32): bool {.inline.} =
  streamId in conn.seenPeerStreams

proc currentPeerMaxFrameSize(conn: Http2ServerConnection): int {.inline.} =
  if conn.peerMaxFrameSize < DefaultMaxFrameSize:
    return DefaultMaxFrameSize
  conn.peerMaxFrameSize

proc sendServerSettings*(conn: Http2ServerConnection): CpsVoidFuture {.cps.} =
  var payload: seq[byte]
  let maxStreams = conn.maxConcurrentStreams.uint32
  payload.add byte((SettingsMaxConcurrentStreams shr 8) and 0xFF)
  payload.add byte(SettingsMaxConcurrentStreams and 0xFF)
  payload.add byte((maxStreams shr 24) and 0xFF)
  payload.add byte((maxStreams shr 16) and 0xFF)
  payload.add byte((maxStreams shr 8) and 0xFF)
  payload.add byte(maxStreams and 0xFF)

  let winSize = DefaultWindowSize.uint32
  payload.add byte((SettingsInitialWindowSize shr 8) and 0xFF)
  payload.add byte(SettingsInitialWindowSize and 0xFF)
  payload.add byte((winSize shr 24) and 0xFF)
  payload.add byte((winSize shr 16) and 0xFF)
  payload.add byte((winSize shr 8) and 0xFF)
  payload.add byte(winSize and 0xFF)

  let enableConnect = 1'u32
  payload.add byte((SettingsEnableConnectProtocol shr 8) and 0xFF)
  payload.add byte(SettingsEnableConnectProtocol and 0xFF)
  payload.add byte((enableConnect shr 24) and 0xFF)
  payload.add byte((enableConnect shr 16) and 0xFF)
  payload.add byte((enableConnect shr 8) and 0xFF)
  payload.add byte(enableConnect and 0xFF)

  await sendFrame(conn, Http2Frame(
    frameType: FrameSettings,
    flags: 0,
    streamId: 0,
    payload: payload
  ))

proc readConnectionPreface*(conn: Http2ServerConnection): CpsVoidFuture {.cps.} =
  let preface = await conn.reader.readExact(ConnectionPreface.len)
  if preface != ConnectionPreface:
    raise newException(ValueError, "Invalid HTTP/2 connection preface")

proc recvServerFrame*(conn: Http2ServerConnection): CpsFuture[Http2Frame] {.cps.} =
  let headerStr = await conn.reader.readExact(9)
  if headerStr.len < 9:
    raise newException(system.IOError, "Short frame header")

  var headerBytes = newSeq[byte](9)
  for i in 0 ..< 9:
    headerBytes[i] = byte(headerStr[i])

  var frame = parseFrame(headerBytes)
  if frame.length.uint64 > 16_777_215'u64:
    raise newException(ValueError, "Invalid HTTP/2 frame length")
  if int(frame.length) > conn.localWindowSize and frame.frameType == FrameData:
    raise newException(ValueError, "Inbound DATA exceeds local flow-control window")
  if int(frame.length) > DefaultMaxFrameSize:
    raise newException(ValueError, "Inbound frame exceeds default max frame size")

  if frame.length > 0:
    let payloadStr = await conn.reader.readExact(int(frame.length))
    frame.payload = newSeq[byte](payloadStr.len)
    for i in 0 ..< payloadStr.len:
      frame.payload[i] = byte(payloadStr[i])
  else:
    frame.payload = @[]

  return frame

proc isPseudoHeader(name: string): bool {.inline.} =
  name.len > 0 and name[0] == ':'

proc isExtendedConnect(headers: seq[(string, string)]): bool =
  var meth = ""
  var proto = ""
  for i in 0 ..< headers.len:
    if headers[i][0] == ":method":
      meth = headers[i][1]
    elif headers[i][0] == ":protocol":
      proto = headers[i][1]
  meth == "CONNECT" and proto.len > 0

proc isConnectRequest(headers: seq[(string, string)]): bool =
  for i in 0 ..< headers.len:
    if headers[i][0] == ":method":
      return headers[i][1] == "CONNECT"
  false

proc validateH2RequestHeaders(conn: Http2ServerConnection,
                              headers: seq[(string, string)]): bool =
  proc parseContentLength(v: string, parsed: var int64): bool =
    if v.len == 0:
      return false
    for ch in v:
      if ch notin Digits:
        return false
    let n =
      try:
        parseBiggestInt(v)
      except ValueError:
        return false
    if n < 0 or n > int64(high(int)):
      return false
    parsed = int64(n)
    true

  proc isValidSchemeValue(value: string): bool =
    if value.len == 0:
      return false
    if value[0] notin Letters:
      return false
    for i in 1 ..< value.len:
      let c = value[i]
      if c notin (Letters + Digits + {'+', '-', '.'}):
        return false
    true

  proc isValidAuthorityValue(value: string): bool =
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

  proc isValidRequestPathValue(meth: string, value: string): bool =
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

  var sawRegular = false
  var seenPseudo = initTable[string, bool]()
  var headerBytes = 0

  if conn.config.maxHeaderCount > 0 and headers.len > conn.config.maxHeaderCount:
    return false

  var meth = ""
  var path = ""
  var scheme = ""
  var authority = ""
  var proto = ""
  var sawHostHeader = false
  var hostValue = ""
  var sawContentLength = false
  var contentLengthValue: int64 = -1

  for i in 0 ..< headers.len:
    let name = headers[i][0]
    let value = headers[i][1]

    headerBytes += name.len + value.len
    if conn.config.maxHeaderBytes > 0 and headerBytes > conn.config.maxHeaderBytes:
      return false

    if value.len > 0 and not isValidHeaderValue(value):
      return false

    if isPseudoHeader(name):
      if sawRegular:
        return false
      if name notin [":method", ":path", ":scheme", ":authority", ":protocol"]:
        return false
      if name in seenPseudo:
        return false
      seenPseudo[name] = true
      case name
      of ":method": meth = value
      of ":path": path = value
      of ":scheme": scheme = value
      of ":authority": authority = value
      of ":protocol": proto = value
      else: discard
    else:
      sawRegular = true
      if name != name.toLowerAscii:
        return false
      if not isValidHeaderName(name):
        return false
      let lname = name
      if lname in ["connection", "proxy-connection", "keep-alive", "upgrade", "transfer-encoding"]:
        return false
      if lname == "te" and value.toLowerAscii != "trailers":
        return false
      if lname == "host":
        if sawHostHeader:
          return false
        if not isValidAuthorityValue(value):
          return false
        sawHostHeader = true
        hostValue = value
      if lname == "content-length":
        var parsedLen = 0'i64
        if not parseContentLength(value, parsedLen):
          return false
        if sawContentLength and parsedLen != contentLengthValue:
          return false
        sawContentLength = true
        contentLengthValue = parsedLen

  if meth.len == 0:
    return false
  if not isValidHeaderName(meth):
    return false
  if scheme.len > 0 and not isValidSchemeValue(scheme):
    return false
  if authority.len > 0 and not isValidAuthorityValue(authority):
    return false
  if authority.len == 0 and ":authority" in seenPseudo:
    return false
  if proto.len > 0 and not isValidHeaderName(proto):
    return false
  if proto.len == 0 and ":protocol" in seenPseudo:
    return false
  if authority.len > 0 and sawHostHeader and authority.toLowerAscii != hostValue.toLowerAscii:
    return false

  if meth == "CONNECT":
    if proto.len > 0:
      if conn.remoteSettings.getOrDefault(SettingsEnableConnectProtocol, 0'u32) != 1'u32:
        return false
      # RFC 8441 extended CONNECT
      if scheme.len == 0 or path.len == 0 or authority.len == 0:
        return false
      if not isValidRequestPathValue(meth, path):
        return false
    else:
      if ":path" in seenPseudo or ":scheme" in seenPseudo:
        return false
      if authority.len == 0:
        return false
      if path.len > 0 or scheme.len > 0:
        return false
  else:
    if ":protocol" in seenPseudo:
      return false
    if path.len == 0 or scheme.len == 0:
      return false
    if not isValidRequestPathValue(meth, path):
      return false
    if authority.len == 0 and not sawHostHeader:
      return false

  true

proc validateH2TrailerHeaders(conn: Http2ServerConnection,
                              headers: seq[(string, string)]): bool =
  var headerBytes = 0

  if conn.config.maxHeaderCount > 0 and headers.len > conn.config.maxHeaderCount:
    return false

  for i in 0 ..< headers.len:
    let name = headers[i][0]
    let value = headers[i][1]

    if name.len == 0 or isPseudoHeader(name):
      return false
    if name != name.toLowerAscii:
      return false
    if not isValidHeaderName(name):
      return false
    if value.len > 0 and not isValidHeaderValue(value):
      return false

    let lname = name
    if lname in ["connection", "proxy-connection", "keep-alive", "upgrade",
                 "transfer-encoding", "te", "content-length"]:
      return false

    headerBytes += name.len + value.len
    if conn.config.maxHeaderBytes > 0 and headerBytes > conn.config.maxHeaderBytes:
      return false

  true

proc extractExpectedContentLength(headers: seq[(string, string)],
                                  expected: var int64): bool

proc validateH2ResponseHeaders(headers: seq[(string, string)]): bool =
  for i in 0 ..< headers.len:
    let name = headers[i][0]
    let value = headers[i][1]
    if name.len == 0:
      return false
    if name[0] == ':':
      return false

    let lower = name.toLowerAscii
    if not isValidHeaderName(lower):
      return false
    if not isValidHeaderValue(value):
      return false

    if lower in ["connection", "proxy-connection", "keep-alive", "upgrade",
                 "transfer-encoding", "te"]:
      return false
  var expectedLen = -1'i64
  if not extractExpectedContentLength(headers, expectedLen):
    return false
  true

proc extractExpectedContentLength(headers: seq[(string, string)],
                                  expected: var int64): bool =
  var saw = false
  var parsedVal = -1'i64
  for i in 0 ..< headers.len:
    let name = headers[i][0].toLowerAscii
    if name != "content-length":
      continue
    let value = headers[i][1]
    if value.len == 0:
      return false
    for ch in value:
      if ch notin Digits:
        return false
    let n =
      try:
        parseBiggestInt(value)
      except ValueError:
        return false
    if n < 0 or n > int64(high(int)):
      return false
    let contentLen = int64(n)
    if saw and contentLen != parsedVal:
      return false
    saw = true
    parsedVal = contentLen
  if saw:
    expected = parsedVal
  else:
    expected = -1
  true

proc extractHeadersFragment(frame: Http2Frame, fragment: var seq[byte]): bool =
  var idx = 0
  var padLen = 0

  if (frame.flags and FlagPadded) != 0:
    if frame.payload.len < 1:
      return false
    padLen = int(frame.payload[0])
    idx = 1

  if (frame.flags and FlagPriority) != 0:
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
  if frame.frameType != FrameHeaders or (frame.flags and FlagPriority) == 0:
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

proc extractDataPayload(frame: Http2Frame, payload: var seq[byte]): bool =
  if (frame.flags and FlagPadded) == 0:
    payload = frame.payload
    return true

  if frame.payload.len < 1:
    return false

  let padLen = int(frame.payload[0])
  if padLen >= frame.payload.len:
    return false

  let startIdx = 1
  let endIdx = frame.payload.len - padLen
  if endIdx < startIdx:
    return false

  if endIdx == startIdx:
    payload = @[]
  else:
    payload = frame.payload[startIdx ..< endIdx]
  true

proc sendResponseHeaders*(conn: Http2ServerConnection, streamId: uint32,
                          statusCode: int, headers: seq[(string, string)],
                          endStream: bool): CpsVoidFuture {.cps.} =
  if statusCode < 200 or statusCode > 999:
    raise newException(ValueError, "Invalid HTTP/2 response status code")
  if not validateH2ResponseHeaders(headers):
    raise newException(ValueError, "Invalid HTTP/2 response header")

  var allHeaders: seq[(string, string)] = @[(":status", $statusCode)]
  for i in 0 ..< headers.len:
    allHeaders.add (headers[i][0].toLowerAscii, headers[i][1])

  let encoded = conn.encoder.encode(allHeaders)
  let maxFrame = conn.currentPeerMaxFrameSize()
  var offset = 0
  var first = true

  while offset < encoded.len or (first and encoded.len == 0):
    let remaining = encoded.len - offset
    let chunkLen =
      if remaining <= 0: 0
      else: min(maxFrame, remaining)

    let chunk =
      if chunkLen <= 0: @[]
      else: encoded[offset ..< offset + chunkLen]

    var flags: uint8 = 0
    if first and endStream:
      flags = flags or FlagEndStream
    if offset + chunkLen >= encoded.len:
      flags = flags or FlagEndHeaders

    let ftype = if first: FrameHeaders else: FrameContinuation
    await sendFrame(conn, Http2Frame(
      frameType: ftype,
      flags: flags,
      streamId: streamId,
      payload: chunk
    ))

    first = false
    offset += chunkLen
    if encoded.len == 0:
      break

proc waitForSendWindow(conn: Http2ServerConnection,
                       streamId: uint32): CpsVoidFuture {.cps.} =
  while conn.running and streamId in conn.streams:
    let s = conn.streams[streamId]
    if conn.remoteWindowSize > 0 and s.remoteWindowSize > 0:
      return

    let waiter = newCpsVoidFuture()
    if conn.remoteWindowSize <= 0:
      conn.connectionWindowWaiters.add waiter
    if s.remoteWindowSize <= 0:
      s.windowWaiters.add waiter

    try:
      await waiter
    except CatchableError:
      return

proc sendResponseData*(conn: Http2ServerConnection, streamId: uint32,
                       data: seq[byte], endStream: bool): CpsVoidFuture {.cps.} =
  if streamId notin conn.streams:
    return

  if data.len == 0:
    if endStream:
      await sendFrame(conn, Http2Frame(
        frameType: FrameData,
        flags: FlagEndStream,
        streamId: streamId,
        payload: @[]
      ))
    return

  let maxFrame = conn.currentPeerMaxFrameSize()
  var offset = 0

  while offset < data.len and conn.running and streamId in conn.streams:
    await waitForSendWindow(conn, streamId)
    if streamId notin conn.streams or not conn.running:
      return

    let s = conn.streams[streamId]
    let remaining = data.len - offset
    let window = min(conn.remoteWindowSize, s.remoteWindowSize)
    let chunkLen = min(min(maxFrame, remaining), window)
    if chunkLen <= 0:
      continue

    conn.remoteWindowSize -= chunkLen
    s.remoteWindowSize -= chunkLen

    let isLast = (offset + chunkLen >= data.len) and endStream
    let chunk = data[offset ..< offset + chunkLen]

    await sendFrame(conn, Http2Frame(
      frameType: FrameData,
      flags: (if isLast: FlagEndStream else: 0'u8),
      streamId: streamId,
      payload: chunk
    ))
    offset += chunkLen

proc statusProhibitsBody(statusCode: int): bool {.inline.} =
  (statusCode >= 100 and statusCode < 200) or statusCode == 204 or
    statusCode == 205 or statusCode == 304

proc buildHttpRequest(s: Http2ServerStream,
                      conn: Http2ServerConnection): HttpRequest =
  var req = HttpRequest(
    streamId: s.id,
    context: newTable[string, string](),
    remoteAddr: conn.remoteAddr
  )

  for i in 0 ..< s.requestHeaders.len:
    let k = s.requestHeaders[i][0]
    let v = s.requestHeaders[i][1]
    case k
    of ":method": req.meth = v
    of ":path": req.path = v
    of ":authority": req.authority = v
    of ":scheme": req.scheme = v
    of ":protocol": req.headers.add (k, v)
    else: req.headers.add (k, v)

  if req.authority.len == 0:
    for i in 0 ..< req.headers.len:
      if req.headers[i][0].toLowerAscii == "host":
        req.authority = req.headers[i][1]
        break

  req.httpVersion = "HTTP/2"
  if s.requestBody.len > 0:
    req.body = newString(s.requestBody.len)
    for i in 0 ..< s.requestBody.len:
      req.body[i] = char(s.requestBody[i])

  ensureContext(req)
  req.context["remote_addr"] = conn.remoteAddr
  req.context["ws_max_frame_bytes"] = $conn.config.maxWsFrameBytes
  req.context["ws_max_message_bytes"] = $conn.config.maxWsMessageBytes
  if conn.config.trustedForwardedHeaders and
      isTrustedProxyAddress(conn.remoteAddr, conn.config.trustedProxyCidrs):
    req.context["trusted_proxy"] = "1"

  if s.adapter == nil:
    let sendHeadersCb: AdapterSendHeadersProc = proc(streamId: uint32, statusCode: int,
                                                     headers: seq[(string, string)]): CpsVoidFuture {.closure.} =
      sendResponseHeaders(conn, streamId, statusCode, headers, false)

    let sendDataCb: AdapterSendDataProc = proc(streamId: uint32, data: string): CpsVoidFuture {.closure.} =
      var bytes = newSeq[byte](data.len)
      for i in 0 ..< data.len:
        bytes[i] = byte(data[i])
      sendResponseData(conn, streamId, bytes, false)

    s.adapter = newHttp2StreamAdapter(s.id, sendHeadersCb, sendDataCb)
    if s.endStream:
      s.adapter.feedEof()

  req.stream = s.adapter.AsyncStream
  req.reader = newBufferedReader(s.adapter.AsyncStream)
  return req

proc dispatchHttp2Handler*(conn: Http2ServerConnection, streamId: uint32,
                           req: HttpRequest): CpsVoidFuture {.cps.} =
  var resp: HttpResponseBuilder
  try:
    resp = await conn.handler(req)
  except CatchableError:
    resp = newResponse(500, "Internal Server Error")

  if streamId notin conn.streams:
    return

  if resp.control == rcHandled or resp.statusCode == 0:
    let s = conn.streams[streamId]
    if s.adapter != nil and s.adapter.hasSentResponseHeaders():
      await sendResponseData(conn, streamId, @[], true)
    else:
      await sendResponseHeaders(conn, streamId, 204, @[], true)
    conn.closeStream(streamId)
    return

  let streamRef = conn.streams[streamId]
  if streamRef.adapter != nil and streamRef.adapter.hasSentResponseHeaders():
    # The handler already started streaming a response on this stream.
    # Suppress any additional response builder emission to avoid duplicate
    # final HEADERS blocks (:status pseudo-header) on the same stream.
    await sendResponseData(conn, streamId, @[], true)
    conn.closeStream(streamId)
    return

  if resp.statusCode < 200 or resp.statusCode > 999 or
      not validateH2ResponseHeaders(resp.headers):
    resp = newResponse(500, "Internal Server Error")

  var respHeaders: seq[(string, string)]
  for i in 0 ..< resp.headers.len:
    respHeaders.add resp.headers[i]

  let suppressBody = req.meth == "HEAD" or statusProhibitsBody(resp.statusCode)

  var expectedRespLen = -1'i64
  if not extractExpectedContentLength(respHeaders, expectedRespLen) or
      (expectedRespLen >= 0 and not suppressBody and expectedRespLen != int64(resp.body.len)):
    resp = newResponse(500, "Internal Server Error")
    respHeaders.setLen(0)
    for i in 0 ..< resp.headers.len:
      respHeaders.add resp.headers[i]
    expectedRespLen = -1
    discard extractExpectedContentLength(respHeaders, expectedRespLen)

  if expectedRespLen < 0 and resp.body.len > 0 and
      (req.meth == "HEAD" or not statusProhibitsBody(resp.statusCode)):
    respHeaders.add ("content-length", $resp.body.len)

  if suppressBody or resp.body.len == 0:
    await sendResponseHeaders(conn, streamId, resp.statusCode, respHeaders, true)
  else:
    await sendResponseHeaders(conn, streamId, resp.statusCode, respHeaders, false)
    var bodyBytes = newSeq[byte](resp.body.len)
    for i in 0 ..< resp.body.len:
      bodyBytes[i] = byte(resp.body[i])
    await sendResponseData(conn, streamId, bodyBytes, true)

  conn.closeStream(streamId)

proc maybeDispatchStream(conn: Http2ServerConnection,
                         s: Http2ServerStream) =
  if s.dispatched or not s.headersComplete:
    return

  if isConnectRequest(s.requestHeaders) or s.endStream:
    s.dispatched = true
    let req = buildHttpRequest(s, conn)
    conn.streamGroup.spawn(dispatchHttp2Handler(conn, s.id, req))

proc completeHeaderBlock(conn: Http2ServerConnection,
                         streamId: uint32): CpsVoidFuture {.cps.} =
  if streamId notin conn.streams:
    return
  let s = conn.streams[streamId]

  var decoded: seq[(string, string)]
  var decodeFailed = false
  try:
    decoded = conn.decoder.decode(s.headerBlock)
  except CatchableError:
    decodeFailed = true

  if decodeFailed:
    await failConnection(conn, H2ErrCompressionError)
    return

  let isTrailerBlock = s.headersComplete
  if isTrailerBlock:
    if conn.config.maxHeaderCount > 0 and
        s.requestHeaders.len + decoded.len > conn.config.maxHeaderCount:
      await sendRstStream(conn, streamId, H2ErrProtocolError)
      conn.closeStream(streamId)
      return

    if conn.config.maxHeaderBytes > 0:
      var totalHeaderBytes = 0
      for i in 0 ..< s.requestHeaders.len:
        totalHeaderBytes += s.requestHeaders[i][0].len + s.requestHeaders[i][1].len
      for i in 0 ..< decoded.len:
        totalHeaderBytes += decoded[i][0].len + decoded[i][1].len
      if totalHeaderBytes > conn.config.maxHeaderBytes:
        await sendRstStream(conn, streamId, H2ErrProtocolError)
        conn.closeStream(streamId)
        return

    if not validateH2TrailerHeaders(conn, decoded):
      await sendRstStream(conn, streamId, H2ErrProtocolError)
      conn.closeStream(streamId)
      return
    s.requestHeaders.add(decoded)
  else:
    if not validateH2RequestHeaders(conn, decoded):
      await sendRstStream(conn, streamId, H2ErrProtocolError)
      conn.closeStream(streamId)
      return
    s.requestHeaders = decoded
    var expectedLen = -1'i64
    if not extractExpectedContentLength(decoded, expectedLen):
      await sendRstStream(conn, streamId, H2ErrProtocolError)
      conn.closeStream(streamId)
      return
    s.expectedContentLength = expectedLen
    s.headersComplete = true
  s.headerBlock.setLen(0)

  if s.headerBlockEndStream:
    if s.expectedContentLength >= 0 and int64(s.bodyBytesRead) != s.expectedContentLength:
      await sendRstStream(conn, streamId, H2ErrProtocolError)
      conn.closeStream(streamId)
      return
    s.endStream = true
    s.state = ssHalfClosedRemote
    if s.adapter != nil:
      s.adapter.feedEof()

  maybeDispatchStream(conn, s)

proc processHeadersFrame(conn: Http2ServerConnection,
                         frame: Http2Frame): CpsVoidFuture {.cps.} =
  let streamId = frame.streamId
  if streamId == 0 or streamId mod 2 == 0:
    await failConnection(conn, H2ErrProtocolError)
    return

  let streamExists = streamId in conn.streams
  if not streamExists:
    if streamId <= conn.lastStreamId:
      await failConnection(conn, H2ErrProtocolError)
      return
    if not conn.acceptingNewStreams and streamId > conn.lastStreamId:
      conn.seenPeerStreams[streamId] = true
      await sendRstStream(conn, streamId, H2ErrRefusedStream)
      return
    conn.lastStreamId = streamId

  var s: Http2ServerStream
  if streamExists:
    s = conn.streams[streamId]
    if s.headersComplete and s.endStream:
      await sendRstStream(conn, streamId, H2ErrStreamClosed)
      conn.closeStream(streamId)
      return
    if s.headersComplete and (frame.flags and FlagEndStream) == 0:
      await sendRstStream(conn, streamId, H2ErrProtocolError)
      conn.closeStream(streamId)
      return
  else:
    if conn.maxConcurrentStreams > 0 and conn.streams.len >= conn.maxConcurrentStreams:
      conn.seenPeerStreams[streamId] = true
      await sendRstStream(conn, streamId, H2ErrRefusedStream)
      return
    s = Http2ServerStream(
      id: streamId,
      state: ssOpen,
      endStream: false,
      remoteWindowSize: conn.peerInitialWindowSize,
      bodyBytesRead: 0,
      headerBlock: @[],
      headerBlockEndStream: false,
      headersComplete: false,
      dispatched: false,
      windowWaiters: @[],
      expectedContentLength: -1
    )
    conn.streams[streamId] = s
    conn.seenPeerStreams[streamId] = true

  if (frame.flags and FlagPriority) != 0:
    var dependency = 0'u32
    if not extractHeadersPriorityDependency(frame, dependency):
      await failConnection(conn, H2ErrProtocolError)
      return
    if dependency == streamId:
      await sendRstStream(conn, streamId, H2ErrProtocolError)
      conn.closeStream(streamId)
      return

  var fragment: seq[byte]
  if not extractHeadersFragment(frame, fragment):
    await failConnection(conn, H2ErrProtocolError)
    return

  s.headerBlock.add(fragment)
  if (frame.flags and FlagEndStream) != 0:
    s.headerBlockEndStream = true

  if (frame.flags and FlagEndHeaders) == 0:
    conn.continuationStreamId = streamId
  else:
    await completeHeaderBlock(conn, streamId)

proc processContinuationFrame(conn: Http2ServerConnection,
                              frame: Http2Frame): CpsVoidFuture {.cps.} =
  if conn.continuationStreamId == 0 or frame.streamId != conn.continuationStreamId:
    await failConnection(conn, H2ErrProtocolError)
    return

  if frame.streamId notin conn.streams:
    await failConnection(conn, H2ErrProtocolError)
    return

  let s = conn.streams[frame.streamId]
  s.headerBlock.add(frame.payload)

  if (frame.flags and FlagEndHeaders) != 0:
    conn.continuationStreamId = 0
    await completeHeaderBlock(conn, frame.streamId)

proc processServerFrame*(conn: Http2ServerConnection,
                         frame: Http2Frame): CpsVoidFuture {.cps.} =
  if conn.continuationStreamId != 0 and
      (frame.frameType != FrameContinuation or frame.streamId != conn.continuationStreamId):
    await failConnection(conn, H2ErrProtocolError)
    return

  case frame.frameType
  of FrameSettings:
    if frame.streamId != 0:
      await failConnection(conn, H2ErrProtocolError)
      return

    if (frame.flags and FlagAck) != 0:
      if frame.payload.len != 0:
        await failConnection(conn, H2ErrFrameSizeError)
      return

    if frame.payload.len mod 6 != 0:
      await failConnection(conn, H2ErrFrameSizeError)
      return

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
          await failConnection(conn, H2ErrFlowControlError)
          return
        if not applyPeerInitialWindowSize(conn, int(value)):
          await failConnection(conn, H2ErrFlowControlError)
          return
      of SettingsEnablePush:
        if value > 1'u32:
          await failConnection(conn, H2ErrProtocolError)
          return
      of SettingsEnableConnectProtocol:
        if value > 1'u32:
          await failConnection(conn, H2ErrProtocolError)
          return
      of SettingsMaxFrameSize:
        if value < DefaultMaxFrameSize.uint32 or value > 16_777_215'u32:
          await failConnection(conn, H2ErrProtocolError)
          return
        conn.peerMaxFrameSize = int(value)
      else:
        discard

      conn.remoteSettings[id] = value
      offset += 6

    await sendFrame(conn, Http2Frame(
      frameType: FrameSettings,
      flags: FlagAck,
      streamId: 0,
      payload: @[]
    ))

  of FrameHeaders:
    await processHeadersFrame(conn, frame)

  of FrameContinuation:
    await processContinuationFrame(conn, frame)

  of FrameData:
    let streamId = frame.streamId
    if streamId == 0:
      await failConnection(conn, H2ErrProtocolError)
      return

    if streamId notin conn.streams:
      if (streamId mod 2) == 0 or streamId > conn.lastStreamId:
        await failConnection(conn, H2ErrProtocolError)
      elif not conn.peerStreamWasOpened(streamId):
        await failConnection(conn, H2ErrProtocolError)
      else:
        await sendRstStream(conn, streamId, H2ErrStreamClosed)
      return

    let s = conn.streams[streamId]
    if not s.headersComplete:
      await sendRstStream(conn, streamId, H2ErrProtocolError)
      conn.closeStream(streamId)
      return
    if s.endStream:
      await sendRstStream(conn, streamId, H2ErrStreamClosed)
      conn.closeStream(streamId)
      return

    var dataPayload: seq[byte]
    if not extractDataPayload(frame, dataPayload):
      await failConnection(conn, H2ErrProtocolError)
      return

    let flowControlledLen = frame.payload.len
    if flowControlledLen > 0:
      conn.localWindowSize -= frame.payload.len
      await sendFrame(conn, Http2Frame(
        frameType: FrameWindowUpdate,
        flags: 0,
        streamId: 0,
        payload: @[
          byte((uint32(flowControlledLen) shr 24) and 0x7F),
          byte((uint32(flowControlledLen) shr 16) and 0xFF),
          byte((uint32(flowControlledLen) shr 8) and 0xFF),
          byte(uint32(flowControlledLen) and 0xFF)
        ]
      ))
      await sendFrame(conn, Http2Frame(
        frameType: FrameWindowUpdate,
        flags: 0,
        streamId: streamId,
        payload: @[
          byte((uint32(flowControlledLen) shr 24) and 0x7F),
          byte((uint32(flowControlledLen) shr 16) and 0xFF),
          byte((uint32(flowControlledLen) shr 8) and 0xFF),
          byte(uint32(flowControlledLen) and 0xFF)
        ]
      ))
      conn.localWindowSize += flowControlledLen

    if dataPayload.len > 0:
      s.bodyBytesRead += dataPayload.len
      if conn.config.maxRequestBodySize > 0 and
          s.bodyBytesRead > conn.config.maxRequestBodySize:
        await sendRstStream(conn, streamId, H2ErrCancel)
        conn.closeStream(streamId)
        return
      if s.expectedContentLength >= 0 and
          int64(s.bodyBytesRead) > s.expectedContentLength:
        await sendRstStream(conn, streamId, H2ErrProtocolError)
        conn.closeStream(streamId)
        return

    if s.adapter != nil:
      if dataPayload.len > 0:
        var dataStr = newString(dataPayload.len)
        for i in 0 ..< dataPayload.len:
          dataStr[i] = char(dataPayload[i])
        s.adapter.feedData(dataStr)
    else:
      if dataPayload.len > 0:
        s.requestBody.add dataPayload

    if (frame.flags and FlagEndStream) != 0:
      if s.expectedContentLength >= 0 and int64(s.bodyBytesRead) != s.expectedContentLength:
        await sendRstStream(conn, streamId, H2ErrProtocolError)
        conn.closeStream(streamId)
        return
      s.endStream = true
      s.state = ssHalfClosedRemote
      if s.adapter != nil:
        s.adapter.feedEof()
      maybeDispatchStream(conn, s)

  of FrameWindowUpdate:
    if frame.payload.len != 4:
      await failConnection(conn, H2ErrFrameSizeError)
      return

    let increment = (uint32(frame.payload[0] and 0x7F) shl 24) or
                    (uint32(frame.payload[1]) shl 16) or
                    (uint32(frame.payload[2]) shl 8) or
                    uint32(frame.payload[3])
    if increment == 0:
      if frame.streamId == 0:
        await failConnection(conn, H2ErrProtocolError)
      elif frame.streamId in conn.streams:
        await sendRstStream(conn, frame.streamId, H2ErrProtocolError)
        conn.closeStream(frame.streamId)
      elif (frame.streamId mod 2) == 0 or frame.streamId > conn.lastStreamId:
        await failConnection(conn, H2ErrProtocolError)
      elif not conn.peerStreamWasOpened(frame.streamId):
        await failConnection(conn, H2ErrProtocolError)
      return

    if frame.streamId == 0:
      let newWindow = conn.remoteWindowSize + int(increment)
      if newWindow > 0x7FFF_FFFF:
        await failConnection(conn, H2ErrFlowControlError)
        return
      conn.remoteWindowSize = newWindow
      wakeConnectionWaiters(conn)
    elif frame.streamId in conn.streams:
      let s = conn.streams[frame.streamId]
      let newWindow = s.remoteWindowSize + int(increment)
      if newWindow > 0x7FFF_FFFF:
        await sendRstStream(conn, frame.streamId, H2ErrFlowControlError)
        conn.closeStream(frame.streamId)
        return
      s.remoteWindowSize = newWindow
      wakeWaiters(s.windowWaiters)
    elif (frame.streamId mod 2) == 0 or frame.streamId > conn.lastStreamId:
      await failConnection(conn, H2ErrProtocolError)
      return
    elif not conn.peerStreamWasOpened(frame.streamId):
      await failConnection(conn, H2ErrProtocolError)
      return

  of FramePing:
    if frame.streamId != 0:
      await failConnection(conn, H2ErrProtocolError)
      return
    if frame.payload.len != 8:
      await failConnection(conn, H2ErrFrameSizeError)
      return
    if (frame.flags and FlagAck) == 0:
      await sendFrame(conn, Http2Frame(
        frameType: FramePing,
        flags: FlagAck,
        streamId: 0,
        payload: frame.payload
      ))

  of FramePriority:
    if frame.payload.len != 5:
      await failConnection(conn, H2ErrFrameSizeError)
      return
    if frame.streamId == 0:
      await failConnection(conn, H2ErrProtocolError)
      return
    var dependency = 0'u32
    if not extractPriorityDependency(frame, dependency):
      await failConnection(conn, H2ErrProtocolError)
      return
    if dependency == frame.streamId:
      if frame.streamId in conn.streams:
        await sendRstStream(conn, frame.streamId, H2ErrProtocolError)
        conn.closeStream(frame.streamId)
      else:
        await failConnection(conn, H2ErrProtocolError)
      return

  of FrameGoAway:
    if frame.streamId != 0:
      await failConnection(conn, H2ErrProtocolError)
      return
    if frame.payload.len < 8:
      await failConnection(conn, H2ErrFrameSizeError)
      return
    conn.running = false

  of FrameRstStream:
    if frame.payload.len != 4:
      await failConnection(conn, H2ErrFrameSizeError)
      return
    if frame.streamId == 0:
      await failConnection(conn, H2ErrProtocolError)
      return
    if (frame.streamId mod 2) == 0 or frame.streamId > conn.lastStreamId:
      await failConnection(conn, H2ErrProtocolError)
      return
    if frame.streamId notin conn.streams and not conn.peerStreamWasOpened(frame.streamId):
      await failConnection(conn, H2ErrProtocolError)
      return
    conn.closeStream(frame.streamId)

  of FramePushPromise:
    await failConnection(conn, H2ErrProtocolError)

  else:
    discard

proc handleHttp2Connection*(stream: AsyncStream, config: HttpServerConfig,
                            handler: HttpHandler,
                            remoteAddr: string = "",
                            shutdownFlag: ptr bool = nil): CpsVoidFuture {.cps.} =
  let conn = newHttp2ServerConnection(stream, config, handler, shutdownFlag, remoteAddr)
  var sendTerminalGoAway = false
  var terminalGoAwayErr = H2ErrInternalError

  try:
    await readConnectionPreface(conn)
    await sendServerSettings(conn)

    while conn.running:
      let drainRequested = not conn.shutdownFlag.isNil and conn.shutdownFlag[]
      if drainRequested and conn.acceptingNewStreams:
        conn.acceptingNewStreams = false
        await sendGoAway(conn, H2ErrNoError)

      if drainRequested and conn.streams.len == 0:
        break

      let frame = await recvServerFrame(conn)
      await processServerFrame(conn, frame)

      if drainRequested and conn.streams.len == 0:
        break
  except CatchableError:
    if conn.running and not conn.goAwaySent:
      let msg = getCurrentExceptionMsg().toLowerAscii
      var shouldSend = true
      if "short frame header" in msg:
        shouldSend = false
      elif "frame size" in msg or "frame length" in msg:
        terminalGoAwayErr = H2ErrFrameSizeError
      elif "flow-control" in msg:
        terminalGoAwayErr = H2ErrFlowControlError
      elif "preface" in msg:
        terminalGoAwayErr = H2ErrProtocolError
      else:
        terminalGoAwayErr = H2ErrInternalError
      sendTerminalGoAway = shouldSend

  if sendTerminalGoAway and conn.running and not conn.goAwaySent:
    try:
      await sendGoAway(conn, terminalGoAwayErr)
    except CatchableError:
      discard

  conn.running = false
  if not conn.writerWake.isNil and not conn.writerWake.finished:
    conn.writerWake.complete()

  let connErr = newException(system.IOError, "HTTP/2 connection closing")
  conn.failConnectionWaiters(connErr)
  for sid, s in conn.streams:
    if s.adapter != nil:
      s.adapter.feedEof()
    failWaiters(s.windowWaiters, connErr)

  conn.streamGroup.cancelAll()
  try:
    await conn.streamGroup.wait()
  except CatchableError:
    discard

  stream.close()
