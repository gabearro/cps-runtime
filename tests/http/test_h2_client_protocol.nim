## HTTP/2 client protocol correctness tests.
##
## Focuses on frame-level compliance:
## - response HEADERS + CONTINUATION decoding
## - outbound HEADERS fragmentation
## - outbound DATA fragmentation

import std/[strutils, nativesockets, tables]
from std/posix import Sockaddr_in, SockLen
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/io/buffered
import cps/http/shared/http2
import cps/http/shared/hpack

type
  InterleaveStream = ref object of AsyncStream
    written: string

  StaticReadStream = ref object of AsyncStream
    data: string
    offset: int

proc getListenerPort(listener: TcpListener): int =
  var localAddr: Sockaddr_in
  var addrLen: SockLen = sizeof(localAddr).SockLen
  let rc = posix.getsockname(listener.fd, cast[ptr SockAddr](addr localAddr), addr addrLen)
  doAssert rc == 0, "getsockname failed"
  result = ntohs(localAddr.sin_port).int

proc sendH2Frame(s: AsyncStream, frame: Http2Frame): CpsVoidFuture =
  let data = serializeFrame(frame)
  var str = newString(data.len)
  for i, b in data:
    str[i] = char(b)
  s.write(str)

proc bytesToString(data: seq[byte]): string =
  result = newString(data.len)
  for i, b in data:
    result[i] = char(b)

proc recvH2Frame(reader: BufferedReader): CpsFuture[Http2Frame] {.cps.} =
  let headerStr = await reader.readExact(9)
  var headerBytes = newSeq[byte](9)
  for i in 0 ..< 9:
    headerBytes[i] = byte(headerStr[i])

  var frame = parseFrame(headerBytes)
  if frame.length > 0:
    let payloadStr = await reader.readExact(int(frame.length))
    frame.payload = newSeq[byte](payloadStr.len)
    for i in 0 ..< payloadStr.len:
      frame.payload[i] = byte(payloadStr[i])
  else:
    frame.payload = @[]

  return frame

proc sendServerSettings(s: AsyncStream): CpsVoidFuture {.cps.} =
  await sendH2Frame(s, Http2Frame(
    frameType: FrameSettings,
    flags: 0,
    streamId: 0,
    payload: @[]
  ))

proc encodeHeaders(headers: seq[(string, string)]): seq[byte] =
  var enc = initHpackEncoder()
  enc.encode(headers)

proc sendSimpleResponse(s: AsyncStream, streamId: uint32): CpsVoidFuture {.cps.} =
  let headers = encodeHeaders(@[(":status", "200")])
  await sendH2Frame(s, Http2Frame(
    frameType: FrameHeaders,
    flags: FlagEndHeaders or FlagEndStream,
    streamId: streamId,
    payload: headers
  ))

proc findSetting(payload: seq[byte], targetId: uint16): int =
  var off = 0
  while off + 5 < payload.len:
    let id = (uint16(payload[off]) shl 8) or uint16(payload[off + 1])
    let value = (int(payload[off + 2]) shl 24) or
                (int(payload[off + 3]) shl 16) or
                (int(payload[off + 4]) shl 8) or
                int(payload[off + 5])
    if id == targetId:
      return value
    off += 6
  return -1

proc pushPromisePayload(promisedStreamId: uint32,
                        headers: seq[(string, string)]): seq[byte] =
  result.add byte((promisedStreamId shr 24) and 0x7F)
  result.add byte((promisedStreamId shr 16) and 0xFF)
  result.add byte((promisedStreamId shr 8) and 0xFF)
  result.add byte(promisedStreamId and 0xFF)
  result.add encodeHeaders(headers)

proc goAwayPayload(lastStreamId: uint32, errorCode: uint32): seq[byte] =
  @[
    byte((lastStreamId shr 24) and 0x7F),
    byte((lastStreamId shr 16) and 0xFF),
    byte((lastStreamId shr 8) and 0xFF),
    byte(lastStreamId and 0xFF),
    byte((errorCode shr 24) and 0xFF),
    byte((errorCode shr 16) and 0xFF),
    byte((errorCode shr 8) and 0xFF),
    byte(errorCode and 0xFF)
  ]

proc settingsPayload(entries: seq[(uint16, uint32)]): seq[byte] =
  for (id, value) in entries:
    result.add byte((id shr 8) and 0xFF)
    result.add byte(id and 0xFF)
    result.add byte((value shr 24) and 0xFF)
    result.add byte((value shr 16) and 0xFF)
    result.add byte((value shr 8) and 0xFF)
    result.add byte(value and 0xFF)

proc windowUpdatePayload(increment: uint32): seq[byte] =
  @[
    byte((increment shr 24) and 0x7F),
    byte((increment shr 16) and 0xFF),
    byte((increment shr 8) and 0xFF),
    byte(increment and 0xFF)
  ]

proc interleaveRead(s: AsyncStream, size: int): CpsFuture[string] =
  let fut = newCpsFuture[string]()
  fut.complete("")
  fut

proc interleaveWrite(s: AsyncStream, data: string): CpsVoidFuture {.cps.} =
  let st = InterleaveStream(s)
  if data.len == 0:
    return
  let splitAt = max(1, data.len div 2)
  st.written.add(data[0 ..< splitAt])
  await cpsSleep(1)
  if splitAt < data.len:
    st.written.add(data[splitAt .. ^1])

proc interleaveClose(s: AsyncStream) =
  discard

proc newInterleaveStream(): InterleaveStream =
  result = InterleaveStream(written: "")
  result.readProc = interleaveRead
  result.writeProc = interleaveWrite
  result.closeProc = interleaveClose

proc staticRead(s: AsyncStream, size: int): CpsFuture[string] =
  let st = StaticReadStream(s)
  let fut = newCpsFuture[string]()
  if st.offset >= st.data.len:
    fut.complete("")
    return fut
  let n = min(size, st.data.len - st.offset)
  fut.complete(st.data[st.offset ..< st.offset + n])
  st.offset += n
  fut

proc staticWrite(s: AsyncStream, data: string): CpsVoidFuture =
  let fut = newCpsVoidFuture()
  fut.complete()
  fut

proc staticClose(s: AsyncStream) =
  discard

proc newStaticReadStream(data: string): StaticReadStream =
  result = StaticReadStream(data: data, offset: 0)
  result.readProc = staticRead
  result.writeProc = staticWrite
  result.closeProc = staticClose

# ============================================================
# Test 0: Client serializes concurrent frame writes
# ============================================================
block testClientSerializesConcurrentWrites:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)

  let f1 = Http2Frame(
    frameType: FrameHeaders,
    flags: FlagEndHeaders,
    streamId: 1,
    payload: encodeHeaders(@[
      (":status", "200"),
      ("x-a", 'a'.repeat(64))
    ])
  )
  let f2 = Http2Frame(
    frameType: FrameData,
    flags: FlagEndStream,
    streamId: 3,
    payload: block:
      var p = newSeq[byte](96)
      for i in 0 ..< p.len:
        p[i] = byte('b')
      p
  )

  let expected12 = bytesToString(serializeFrame(f1)) & bytesToString(serializeFrame(f2))
  let expected21 = bytesToString(serializeFrame(f2)) & bytesToString(serializeFrame(f1))

  let w1 = sendFrame(conn, f1)
  let w2 = sendFrame(conn, f2)
  let loop = getEventLoop()
  while not w1.finished or not w2.finished:
    loop.tick()
    if not loop.hasWork:
      break

  doAssert w1.finished and w2.finished, "concurrent frame writes did not complete"
  doAssert outStream.written == expected12 or outStream.written == expected21,
    "concurrent frame writes interleaved and corrupted frame boundaries"
  echo "PASS: HTTP/2 client serializes concurrent frame writes"

# ============================================================
# Test 1: Client disables server push via SETTINGS_ENABLE_PUSH=0
# ============================================================
block testClientDisablesServerPush:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc serverTask(l: TcpListener): CpsFuture[bool] {.cps.} =
    let client = await l.accept()
    let s = client.AsyncStream
    let reader = newBufferedReader(s)

    discard await reader.readExact(ConnectionPreface.len)
    let cSettings = await recvH2Frame(reader)
    doAssert cSettings.frameType == FrameSettings
    let enablePush = findSetting(cSettings.payload, SettingsEnablePush)
    await sendServerSettings(s)
    s.close()
    return enablePush == 0

  proc clientTask(p: int): CpsVoidFuture {.cps.} =
    let tcpConn = await tcpConnect("127.0.0.1", p)
    let conn = newHttp2Connection(tcpConn.AsyncStream)
    await initConnection(conn)
    conn.stream.close()

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not sf.finished or not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  doAssert sf.finished, "server task did not complete"
  doAssert cf.finished, "client task did not complete"
  doAssert sf.read(), "client must advertise SETTINGS_ENABLE_PUSH=0"
  listener.close()
  echo "PASS: HTTP/2 client disables server push in SETTINGS"

# ============================================================
# Test 2: Client decodes response HEADERS split across CONTINUATION
# ============================================================
block testClientHandlesResponseContinuation:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc serverTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let s = client.AsyncStream
    let reader = newBufferedReader(s)

    discard await reader.readExact(ConnectionPreface.len)
    let cSettings = await recvH2Frame(reader)
    doAssert cSettings.frameType == FrameSettings
    await sendServerSettings(s)

    var reqStreamId = 1'u32
    var gotRequest = false
    while not gotRequest:
      let frame = await recvH2Frame(reader)
      case frame.frameType
      of FrameHeaders:
        reqStreamId = frame.streamId
        if (frame.flags and FlagEndHeaders) == 0:
          var done = false
          while not done:
            let cont = await recvH2Frame(reader)
            doAssert cont.frameType == FrameContinuation
            doAssert cont.streamId == reqStreamId
            if (cont.flags and FlagEndHeaders) != 0:
              done = true
        if (frame.flags and FlagEndStream) != 0:
          gotRequest = true
      of FrameData:
        reqStreamId = frame.streamId
        if (frame.flags and FlagEndStream) != 0:
          gotRequest = true
      else:
        discard

    let encoded = encodeHeaders(@[
      (":status", "200"),
      ("x-long", 'z'.repeat(2048))
    ])
    let splitAt = max(1, encoded.len div 2)
    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndStream,
      streamId: reqStreamId,
      payload: encoded[0 ..< splitAt]
    ))
    await sendH2Frame(s, Http2Frame(
      frameType: FrameContinuation,
      flags: FlagEndHeaders,
      streamId: reqStreamId,
      payload: encoded[splitAt .. ^1]
    ))
    s.close()

  proc clientTask(p: int): CpsFuture[int] {.cps.} =
    let tcpConn = await tcpConnect("127.0.0.1", p)
    let conn = newHttp2Connection(tcpConn.AsyncStream)
    await initConnection(conn)
    discard runReceiveLoop(conn)
    let resp = await request(conn, "GET", "/continuation", "localhost")
    return resp.statusCode

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not sf.finished or not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  doAssert sf.finished, "server task did not complete"
  doAssert cf.finished, "client task did not complete"
  doAssert not cf.hasError(), "client request failed on response CONTINUATION"
  doAssert cf.read() == 200, "expected HTTP 200 from CONTINUATION response"
  listener.close()
  echo "PASS: HTTP/2 client decodes response CONTINUATION headers"

# ============================================================
# Test 3: Client fragments large outbound DATA frames
# ============================================================
block testClientFragmentsLargeData:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc serverTask(l: TcpListener): CpsFuture[int] {.cps.} =
    let client = await l.accept()
    let s = client.AsyncStream
    let reader = newBufferedReader(s)
    var maxDataLen = 0
    var reqStreamId = 1'u32

    discard await reader.readExact(ConnectionPreface.len)
    let cSettings = await recvH2Frame(reader)
    doAssert cSettings.frameType == FrameSettings
    await sendServerSettings(s)

    var gotEndStream = false
    while not gotEndStream:
      let frame = await recvH2Frame(reader)
      case frame.frameType
      of FrameHeaders:
        reqStreamId = frame.streamId
        if (frame.flags and FlagEndHeaders) == 0:
          var done = false
          while not done:
            let cont = await recvH2Frame(reader)
            doAssert cont.frameType == FrameContinuation
            doAssert cont.streamId == reqStreamId
            if int(cont.length) > 0:
              discard
            if (cont.flags and FlagEndHeaders) != 0:
              done = true
        if (frame.flags and FlagEndStream) != 0:
          gotEndStream = true
      of FrameData:
        reqStreamId = frame.streamId
        maxDataLen = max(maxDataLen, int(frame.length))
        if (frame.flags and FlagEndStream) != 0:
          gotEndStream = true
      else:
        discard

    await sendSimpleResponse(s, reqStreamId)
    s.close()
    return maxDataLen

  proc clientTask(p: int): CpsFuture[int] {.cps.} =
    let tcpConn = await tcpConnect("127.0.0.1", p)
    let conn = newHttp2Connection(tcpConn.AsyncStream)
    await initConnection(conn)
    discard runReceiveLoop(conn)
    let body = 'd'.repeat(DefaultMaxFrameSize + 4096)
    let resp = await request(conn, "POST", "/upload", "localhost", body = body)
    return resp.statusCode

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not sf.finished or not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  doAssert sf.finished, "server task did not complete"
  doAssert cf.finished, "client task did not complete"
  doAssert not cf.hasError(), "client request failed for large DATA test"
  doAssert cf.read() == 200, "expected HTTP 200 for large DATA test"
  let maxDataLen = sf.read()
  doAssert maxDataLen <= DefaultMaxFrameSize,
    "client emitted oversized DATA frame: " & $maxDataLen
  listener.close()
  echo "PASS: HTTP/2 client fragments large outbound DATA"

# ============================================================
# Test 4: Client fragments large outbound HEADERS blocks
# ============================================================
block testClientFragmentsLargeHeaders:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc serverTask(l: TcpListener): CpsFuture[int] {.cps.} =
    let client = await l.accept()
    let s = client.AsyncStream
    let reader = newBufferedReader(s)
    var maxHeaderFrameLen = 0
    var reqStreamId = 1'u32

    discard await reader.readExact(ConnectionPreface.len)
    let cSettings = await recvH2Frame(reader)
    doAssert cSettings.frameType == FrameSettings
    await sendServerSettings(s)

    var headerBlockDone = false
    while not headerBlockDone:
      let frame = await recvH2Frame(reader)
      case frame.frameType
      of FrameHeaders:
        reqStreamId = frame.streamId
        maxHeaderFrameLen = max(maxHeaderFrameLen, int(frame.length))
        if (frame.flags and FlagEndHeaders) != 0:
          headerBlockDone = true
      of FrameContinuation:
        maxHeaderFrameLen = max(maxHeaderFrameLen, int(frame.length))
        if (frame.flags and FlagEndHeaders) != 0:
          headerBlockDone = true
      else:
        discard

    await sendSimpleResponse(s, reqStreamId)
    s.close()
    return maxHeaderFrameLen

  proc clientTask(p: int): CpsFuture[int] {.cps.} =
    let tcpConn = await tcpConnect("127.0.0.1", p)
    let conn = newHttp2Connection(tcpConn.AsyncStream)
    await initConnection(conn)
    discard runReceiveLoop(conn)
    let hugeHeaders = @[("x-big", 'h'.repeat(DefaultMaxFrameSize * 2))]
    let resp = await request(conn, "GET", "/huge-headers", "localhost", headers = hugeHeaders)
    return resp.statusCode

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not sf.finished or not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  doAssert sf.finished, "server task did not complete"
  doAssert cf.finished, "client task did not complete"
  doAssert not cf.hasError(), "client request failed for large HEADERS test"
  doAssert cf.read() == 200, "expected HTTP 200 for large HEADERS test"
  let maxHeaderFrameLen = sf.read()
  doAssert maxHeaderFrameLen <= DefaultMaxFrameSize,
    "client emitted oversized HEADERS/CONTINUATION frame: " & $maxHeaderFrameLen
  listener.close()
  echo "PASS: HTTP/2 client fragments large outbound HEADERS"

# ============================================================
# Test 5: Client rejects connection window overflow from peer
# ============================================================
block testClientRejectsConnectionWindowOverflow:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc serverTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let s = client.AsyncStream
    let reader = newBufferedReader(s)

    discard await reader.readExact(ConnectionPreface.len)
    let cSettings = await recvH2Frame(reader)
    doAssert cSettings.frameType == FrameSettings
    await sendServerSettings(s)

    var reqStreamId = 1'u32
    var gotRequest = false
    while not gotRequest:
      let frame = await recvH2Frame(reader)
      case frame.frameType
      of FrameHeaders:
        reqStreamId = frame.streamId
        if (frame.flags and FlagEndHeaders) == 0:
          var done = false
          while not done:
            let cont = await recvH2Frame(reader)
            doAssert cont.frameType == FrameContinuation
            doAssert cont.streamId == reqStreamId
            if (cont.flags and FlagEndHeaders) != 0:
              done = true
        if (frame.flags and FlagEndStream) != 0:
          gotRequest = true
      of FrameData:
        reqStreamId = frame.streamId
        if (frame.flags and FlagEndStream) != 0:
          gotRequest = true
      else:
        discard

    await sendH2Frame(s, Http2Frame(
      frameType: FrameWindowUpdate,
      flags: 0,
      streamId: 0,
      payload: @[
        0x7F'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8
      ]
    ))
    await sendSimpleResponse(s, reqStreamId)
    s.close()

  proc clientTask(p: int): CpsFuture[bool] {.cps.} =
    let tcpConn = await tcpConnect("127.0.0.1", p)
    let conn = newHttp2Connection(tcpConn.AsyncStream)
    await initConnection(conn)
    discard runReceiveLoop(conn)

    var failed = false
    try:
      discard await request(conn, "GET", "/overflow", "localhost")
    except CatchableError:
      failed = true
    return failed

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not sf.finished or not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  doAssert sf.finished, "server task did not complete"
  doAssert cf.finished, "client task did not complete"
  doAssert not cf.hasError(), "client task failed unexpectedly"
  doAssert cf.read(), "client must reject peer connection window overflow"
  listener.close()
  echo "PASS: HTTP/2 client rejects connection window overflow"

# ============================================================
# Test 6: Client rejects unsolicited PUSH_PROMISE
# ============================================================
block testClientRejectsPushPromise:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc serverTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let s = client.AsyncStream
    let reader = newBufferedReader(s)

    discard await reader.readExact(ConnectionPreface.len)
    let cSettings = await recvH2Frame(reader)
    doAssert cSettings.frameType == FrameSettings
    await sendServerSettings(s)

    var reqStreamId = 1'u32
    var gotRequest = false
    while not gotRequest:
      let frame = await recvH2Frame(reader)
      case frame.frameType
      of FrameHeaders:
        reqStreamId = frame.streamId
        if (frame.flags and FlagEndHeaders) == 0:
          var done = false
          while not done:
            let cont = await recvH2Frame(reader)
            doAssert cont.frameType == FrameContinuation
            doAssert cont.streamId == reqStreamId
            if (cont.flags and FlagEndHeaders) != 0:
              done = true
        if (frame.flags and FlagEndStream) != 0:
          gotRequest = true
      of FrameData:
        reqStreamId = frame.streamId
        if (frame.flags and FlagEndStream) != 0:
          gotRequest = true
      else:
        discard

    try:
      await sendH2Frame(s, Http2Frame(
        frameType: FramePushPromise,
        flags: FlagEndHeaders,
        streamId: reqStreamId,
        payload: pushPromisePayload(2'u32, @[
          (":method", "GET"),
          (":path", "/pushed"),
          (":scheme", "https"),
          (":authority", "localhost")
        ])
      ))
      await sendSimpleResponse(s, reqStreamId)
    except CatchableError:
      discard
    s.close()

  proc clientTask(p: int): CpsFuture[bool] {.cps.} =
    let tcpConn = await tcpConnect("127.0.0.1", p)
    let conn = newHttp2Connection(tcpConn.AsyncStream)
    await initConnection(conn)
    discard runReceiveLoop(conn)

    var failed = false
    try:
      discard await request(conn, "GET", "/reject-push", "localhost")
    except CatchableError:
      failed = true
    return failed

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not sf.finished or not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  doAssert sf.finished, "server task did not complete"
  doAssert cf.finished, "client task did not complete"
  doAssert not cf.hasError(), "client task failed unexpectedly"
  doAssert cf.read(), "client must reject unsolicited PUSH_PROMISE"
  listener.close()
  echo "PASS: HTTP/2 client rejects unsolicited PUSH_PROMISE"

# ============================================================
# Test 7: Client rejects unexpected HEADERS on unknown stream
# ============================================================
block testClientRejectsUnexpectedHeadersStream:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc serverTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let s = client.AsyncStream
    let reader = newBufferedReader(s)

    discard await reader.readExact(ConnectionPreface.len)
    let cSettings = await recvH2Frame(reader)
    doAssert cSettings.frameType == FrameSettings
    await sendServerSettings(s)

    var reqStreamId = 1'u32
    var gotRequest = false
    while not gotRequest:
      let frame = await recvH2Frame(reader)
      case frame.frameType
      of FrameHeaders:
        reqStreamId = frame.streamId
        if (frame.flags and FlagEndHeaders) == 0:
          var done = false
          while not done:
            let cont = await recvH2Frame(reader)
            doAssert cont.frameType == FrameContinuation
            doAssert cont.streamId == reqStreamId
            if (cont.flags and FlagEndHeaders) != 0:
              done = true
        if (frame.flags and FlagEndStream) != 0:
          gotRequest = true
      of FrameData:
        reqStreamId = frame.streamId
        if (frame.flags and FlagEndStream) != 0:
          gotRequest = true
      else:
        discard

    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: 3,
      payload: encodeHeaders(@[(":status", "200")])
    ))
    await sendSimpleResponse(s, reqStreamId)
    s.close()

  proc clientTask(p: int): CpsFuture[bool] {.cps.} =
    let tcpConn = await tcpConnect("127.0.0.1", p)
    let conn = newHttp2Connection(tcpConn.AsyncStream)
    await initConnection(conn)
    discard runReceiveLoop(conn)

    var failed = false
    try:
      discard await request(conn, "GET", "/unknown-stream-frame", "localhost")
    except CatchableError:
      failed = true
    return failed

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not sf.finished or not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  doAssert sf.finished, "server task did not complete"
  doAssert cf.finished, "client task did not complete"
  doAssert not cf.hasError(), "client task failed unexpectedly"
  doAssert cf.read(), "client must reject unexpected HEADERS on unknown stream"
  listener.close()
  echo "PASS: HTTP/2 client rejects unexpected unknown-stream HEADERS"

# ============================================================
# Test 8: Client continues processing in-flight stream after GOAWAY
# ============================================================
block testClientHandlesInFlightAfterGoAway:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc serverTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let s = client.AsyncStream
    let reader = newBufferedReader(s)

    discard await reader.readExact(ConnectionPreface.len)
    let cSettings = await recvH2Frame(reader)
    doAssert cSettings.frameType == FrameSettings
    await sendServerSettings(s)

    var reqStreamId = 1'u32
    var gotRequest = false
    while not gotRequest:
      let frame = await recvH2Frame(reader)
      case frame.frameType
      of FrameHeaders:
        reqStreamId = frame.streamId
        if (frame.flags and FlagEndHeaders) == 0:
          var done = false
          while not done:
            let cont = await recvH2Frame(reader)
            doAssert cont.frameType == FrameContinuation
            doAssert cont.streamId == reqStreamId
            if (cont.flags and FlagEndHeaders) != 0:
              done = true
        if (frame.flags and FlagEndStream) != 0:
          gotRequest = true
      of FrameData:
        reqStreamId = frame.streamId
        if (frame.flags and FlagEndStream) != 0:
          gotRequest = true
      else:
        discard

    await sendH2Frame(s, Http2Frame(
      frameType: FrameGoAway,
      flags: 0,
      streamId: 0,
      payload: goAwayPayload(reqStreamId, 0'u32)
    ))
    await sendSimpleResponse(s, reqStreamId)
    s.close()

  proc clientTask(p: int): CpsFuture[int] {.cps.} =
    let tcpConn = await tcpConnect("127.0.0.1", p)
    let conn = newHttp2Connection(tcpConn.AsyncStream)
    await initConnection(conn)
    discard runReceiveLoop(conn)
    let resp = await request(conn, "GET", "/goaway-inflight", "localhost")
    return resp.statusCode

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not sf.finished or not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  doAssert sf.finished, "server task did not complete"
  doAssert cf.finished, "client task did not complete"
  doAssert not cf.hasError(), "in-flight request failed after GOAWAY"
  doAssert cf.read() == 200, "expected HTTP 200 for in-flight stream after GOAWAY"
  listener.close()
  echo "PASS: HTTP/2 client handles in-flight stream after GOAWAY"

# ============================================================
# Test 9: Client strips DATA padding bytes from response body
# ============================================================
block testClientStripsDataPadding:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc serverTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let s = client.AsyncStream
    let reader = newBufferedReader(s)

    discard await reader.readExact(ConnectionPreface.len)
    let cSettings = await recvH2Frame(reader)
    doAssert cSettings.frameType == FrameSettings
    await sendServerSettings(s)

    var reqStreamId = 1'u32
    var gotRequest = false
    while not gotRequest:
      let frame = await recvH2Frame(reader)
      case frame.frameType
      of FrameHeaders:
        reqStreamId = frame.streamId
        if (frame.flags and FlagEndHeaders) == 0:
          var done = false
          while not done:
            let cont = await recvH2Frame(reader)
            doAssert cont.frameType == FrameContinuation
            doAssert cont.streamId == reqStreamId
            if (cont.flags and FlagEndHeaders) != 0:
              done = true
        if (frame.flags and FlagEndStream) != 0:
          gotRequest = true
      of FrameData:
        reqStreamId = frame.streamId
        if (frame.flags and FlagEndStream) != 0:
          gotRequest = true
      else:
        discard

    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders,
      streamId: reqStreamId,
      payload: encodeHeaders(@[(":status", "200")])
    ))
    await sendH2Frame(s, Http2Frame(
      frameType: FrameData,
      flags: FlagPadded or FlagEndStream,
      streamId: reqStreamId,
      payload: @[
        3'u8,
        byte('o'),
        byte('k'),
        0'u8,
        0'u8,
        0'u8
      ]
    ))
    s.close()

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let tcpConn = await tcpConnect("127.0.0.1", p)
    let conn = newHttp2Connection(tcpConn.AsyncStream)
    await initConnection(conn)
    discard runReceiveLoop(conn)
    let resp = await request(conn, "GET", "/padded-data", "localhost")
    return resp.body

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not sf.finished or not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  doAssert sf.finished, "server task did not complete"
  doAssert cf.finished, "client task did not complete"
  doAssert not cf.hasError(), "client request failed for padded DATA test"
  doAssert cf.read() == "ok", "client must strip DATA padding bytes from response body"
  listener.close()
  echo "PASS: HTTP/2 client strips DATA padding"

# ============================================================
# Test 10: Client rejects oversized inbound frame payloads
# ============================================================
block testClientRejectsOversizedInboundFrame:
  var hugePayload = newSeq[byte](DefaultMaxFrameSize + 1)
  for i in 0 ..< hugePayload.len:
    hugePayload[i] = byte('x')

  let oversized = Http2Frame(
    frameType: FrameData,
    flags: 0,
    streamId: 1,
    payload: hugePayload
  )
  let raw = bytesToString(serializeFrame(oversized))
  let inStream = newStaticReadStream(raw)
  let conn = newHttp2Connection(inStream.AsyncStream)

  let rf = recvFrame(conn)
  let loop = getEventLoop()
  var spins = 0
  while not rf.finished:
    loop.tick()
    inc spins
    if spins > 10_000:
      break

  doAssert rf.finished, "recvFrame future did not complete"
  var failed = false
  try:
    discard rf.read()
  except CatchableError:
    failed = true
  doAssert failed, "client must reject oversized inbound frame payloads"
  echo "PASS: HTTP/2 client rejects oversized inbound frames"

# ============================================================
# Test 11: Client rejects SETTINGS initial-window overflow
# ============================================================
block testClientRejectsSettingsWindowOverflow:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)

  let streamId = 1'u32
  conn.streams[streamId] = Http2Stream(
    id: streamId,
    state: ssOpen,
    responseHeaders: @[],
    responseBody: @[],
    headerBlock: @[],
    responseFuture: newCpsFuture[Http2Response](),
    windowSize: DefaultWindowSize,
    headersDone: false,
    endStream: false
  )

  let toMaxIncrement = 0x7FFF_FFFF'u32 - DefaultWindowSize.uint32
  discard processFrame(conn, Http2Frame(
    frameType: FrameWindowUpdate,
    flags: 0,
    streamId: streamId,
    payload: windowUpdatePayload(toMaxIncrement)
  ))

  var failed = false
  try:
    discard processFrame(conn, Http2Frame(
      frameType: FrameSettings,
      flags: 0,
      streamId: 0,
      payload: settingsPayload(@[
        (SettingsInitialWindowSize, 0x7FFF_FFFF'u32)
      ])
    ))
  except CatchableError:
    failed = true

  doAssert failed,
    "client must reject SETTINGS_INITIAL_WINDOW_SIZE that overflows active stream window"
  echo "PASS: HTTP/2 client rejects SETTINGS initial-window overflow"

# ============================================================
# Test 12: Client rejects invalid SETTINGS_ENABLE_PUSH value
# ============================================================
block testClientRejectsInvalidEnablePush:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)

  var failed = false
  try:
    discard processFrame(conn, Http2Frame(
      frameType: FrameSettings,
      flags: 0,
      streamId: 0,
      payload: settingsPayload(@[
        (SettingsEnablePush, 2'u32)
      ])
    ))
  except CatchableError:
    failed = true

  doAssert failed, "client must reject invalid SETTINGS_ENABLE_PUSH values"
  echo "PASS: HTTP/2 client rejects invalid SETTINGS_ENABLE_PUSH value"

# ============================================================
# Test 13: Client rejects invalid SETTINGS_ENABLE_CONNECT_PROTOCOL value
# ============================================================
block testClientRejectsInvalidEnableConnectProtocol:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)

  var failed = false
  try:
    discard processFrame(conn, Http2Frame(
      frameType: FrameSettings,
      flags: 0,
      streamId: 0,
      payload: settingsPayload(@[
        (SettingsEnableConnectProtocol, 2'u32)
      ])
    ))
  except CatchableError:
    failed = true

  doAssert failed, "client must reject invalid SETTINGS_ENABLE_CONNECT_PROTOCOL values"
  echo "PASS: HTTP/2 client rejects invalid SETTINGS_ENABLE_CONNECT_PROTOCOL value"

# ============================================================
# Test 14: Client maps stream WINDOW_UPDATE increment 0 to RST_STREAM
# ============================================================
block testClientZeroIncrementWindowUpdateIsStreamError:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)

  let streamId = 1'u32
  conn.streams[streamId] = Http2Stream(
    id: streamId,
    state: ssOpen,
    responseHeaders: @[],
    responseBody: @[],
    headerBlock: @[],
    responseFuture: newCpsFuture[Http2Response](),
    windowSize: DefaultWindowSize,
    headersDone: true,
    endStream: false
  )

  let responses = processFrame(conn, Http2Frame(
    frameType: FrameWindowUpdate,
    flags: 0,
    streamId: streamId,
    payload: windowUpdatePayload(0'u32)
  ))

  doAssert responses.len == 1, "expected one RST_STREAM response for zero-increment stream WINDOW_UPDATE"
  doAssert responses[0].frameType == FrameRstStream, "expected RST_STREAM response"
  doAssert responses[0].streamId == streamId, "RST_STREAM must target offending stream"
  doAssert responses[0].payload.len == 4, "RST_STREAM payload must include error code"
  let errCode = (uint32(responses[0].payload[0]) shl 24) or
                (uint32(responses[0].payload[1]) shl 16) or
                (uint32(responses[0].payload[2]) shl 8) or
                uint32(responses[0].payload[3])
  doAssert errCode == 1'u32, "expected PROTOCOL_ERROR (1) for zero-increment stream WINDOW_UPDATE"
  doAssert streamId notin conn.streams, "offending stream should be closed after stream error"
  echo "PASS: HTTP/2 client maps stream WINDOW_UPDATE increment 0 to RST_STREAM"

# ============================================================
# Test 15: Client returns final status after informational 1xx headers
# ============================================================
block testClientUsesFinalStatusAfterInformationalHeaders:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc serverTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let s = client.AsyncStream
    let reader = newBufferedReader(s)

    discard await reader.readExact(ConnectionPreface.len)
    let cSettings = await recvH2Frame(reader)
    doAssert cSettings.frameType == FrameSettings
    await sendServerSettings(s)

    var reqStreamId = 1'u32
    var gotRequest = false
    while not gotRequest:
      let frame = await recvH2Frame(reader)
      case frame.frameType
      of FrameHeaders:
        reqStreamId = frame.streamId
        if (frame.flags and FlagEndHeaders) == 0:
          var done = false
          while not done:
            let cont = await recvH2Frame(reader)
            doAssert cont.frameType == FrameContinuation
            doAssert cont.streamId == reqStreamId
            if (cont.flags and FlagEndHeaders) != 0:
              done = true
        if (frame.flags and FlagEndStream) != 0:
          gotRequest = true
      of FrameData:
        reqStreamId = frame.streamId
        if (frame.flags and FlagEndStream) != 0:
          gotRequest = true
      else:
        discard

    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders,
      streamId: reqStreamId,
      payload: encodeHeaders(@[
        (":status", "103"),
        ("link", "</style.css>; rel=preload")
      ])
    ))

    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: reqStreamId,
      payload: encodeHeaders(@[
        (":status", "200")
      ])
    ))
    s.close()

  proc clientTask(p: int): CpsFuture[int] {.cps.} =
    let tcpConn = await tcpConnect("127.0.0.1", p)
    let conn = newHttp2Connection(tcpConn.AsyncStream)
    await initConnection(conn)
    discard runReceiveLoop(conn)
    let resp = await request(conn, "GET", "/status-1xx", "localhost")
    return resp.statusCode

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not sf.finished or not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  doAssert sf.finished, "server task did not complete"
  doAssert cf.finished, "client task did not complete"
  doAssert not cf.hasError(), "client request failed for informational-status test"
  doAssert cf.read() == 200, "client must use final :status after informational response headers"
  listener.close()
  echo "PASS: HTTP/2 client returns final status after informational 1xx headers"

# ============================================================
# Test 16: Client rejects final response headers missing :status
# ============================================================
block testClientRejectsResponseWithoutStatus:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc serverTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let s = client.AsyncStream
    let reader = newBufferedReader(s)

    discard await reader.readExact(ConnectionPreface.len)
    let cSettings = await recvH2Frame(reader)
    doAssert cSettings.frameType == FrameSettings
    await sendServerSettings(s)

    var reqStreamId = 1'u32
    var gotRequest = false
    while not gotRequest:
      let frame = await recvH2Frame(reader)
      case frame.frameType
      of FrameHeaders:
        reqStreamId = frame.streamId
        if (frame.flags and FlagEndHeaders) == 0:
          var done = false
          while not done:
            let cont = await recvH2Frame(reader)
            doAssert cont.frameType == FrameContinuation
            doAssert cont.streamId == reqStreamId
            if (cont.flags and FlagEndHeaders) != 0:
              done = true
        if (frame.flags and FlagEndStream) != 0:
          gotRequest = true
      of FrameData:
        reqStreamId = frame.streamId
        if (frame.flags and FlagEndStream) != 0:
          gotRequest = true
      else:
        discard

    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: reqStreamId,
      payload: encodeHeaders(@[
        ("x-no-status", "1")
      ])
    ))
    s.close()

  proc clientTask(p: int): CpsFuture[bool] {.cps.} =
    let tcpConn = await tcpConnect("127.0.0.1", p)
    let conn = newHttp2Connection(tcpConn.AsyncStream)
    await initConnection(conn)
    discard runReceiveLoop(conn)

    var failed = false
    try:
      discard await request(conn, "GET", "/missing-status", "localhost")
    except CatchableError:
      failed = true
    return failed

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not sf.finished or not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  doAssert sf.finished, "server task did not complete"
  doAssert cf.finished, "client task did not complete"
  doAssert not cf.hasError(), "client task failed unexpectedly"
  doAssert cf.read(), "client must reject final response header block without :status"
  listener.close()
  echo "PASS: HTTP/2 client rejects final response headers missing :status"

# ============================================================
# Test 17: Client rejects WINDOW_UPDATE on idle stream
# ============================================================
block testClientRejectsIdleWindowUpdate:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)

  var failed = false
  try:
    discard processFrame(conn, Http2Frame(
      frameType: FrameWindowUpdate,
      flags: 0,
      streamId: 1'u32,
      payload: windowUpdatePayload(1'u32)
    ))
  except CatchableError:
    failed = true

  doAssert failed, "client must reject WINDOW_UPDATE on idle stream"
  echo "PASS: HTTP/2 client rejects WINDOW_UPDATE on idle stream"

# ============================================================
# Test 18: Client ignores unknown CONTINUATION flags
# ============================================================
block testClientIgnoresUnknownContinuationFlags:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)

  let streamId = 1'u32
  conn.streams[streamId] = Http2Stream(
    id: streamId,
    state: ssOpen,
    responseHeaders: @[],
    responseBody: @[],
    headerBlock: @[],
    responseFuture: newCpsFuture[Http2Response](),
    windowSize: DefaultWindowSize,
    headersDone: false,
    endStream: false
  )

  let headerBlock = encodeHeaders(@[
    (":status", "200"),
    ("x-repro", 'q'.repeat(32))
  ])
  let splitAt = max(1, headerBlock.len div 2)

  discard processFrame(conn, Http2Frame(
    frameType: FrameHeaders,
    flags: 0,
    streamId: streamId,
    payload: headerBlock[0 ..< splitAt]
  ))

  var failed = false
  try:
    discard processFrame(conn, Http2Frame(
      frameType: FrameContinuation,
      flags: FlagEndHeaders or FlagPadded,
      streamId: streamId,
      payload: headerBlock[splitAt .. ^1]
    ))
  except CatchableError:
    failed = true

  doAssert not failed, "client must ignore undefined CONTINUATION flags"
  doAssert streamId in conn.streams, "stream should remain open after CONTINUATION"
  let s = conn.streams[streamId]
  doAssert s.headersDone, "response header block should complete"
  doAssert s.finalHeadersSeen, "final response headers should be recorded"
  echo "PASS: HTTP/2 client ignores unknown CONTINUATION flags"

# ============================================================
# Test 18b: Client accepts zero-length initial HEADERS fragment
# ============================================================
block testClientAcceptsZeroLengthInitialHeadersFragment:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)

  let streamId = 1'u32
  let responseFut = newCpsFuture[Http2Response]()
  conn.streams[streamId] = Http2Stream(
    id: streamId,
    state: ssOpen,
    responseHeaders: @[],
    responseBody: @[],
    headerBlock: @[],
    responseFuture: responseFut,
    windowSize: DefaultWindowSize,
    headersDone: false,
    endStream: false,
    finalHeadersSeen: false,
    trailersSeen: false,
    expectedContentLength: -1
  )

  var failed = false
  try:
    discard processFrame(conn, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndStream,
      streamId: streamId,
      payload: @[]
    ))
    discard processFrame(conn, Http2Frame(
      frameType: FrameContinuation,
      flags: FlagEndHeaders,
      streamId: streamId,
      payload: encodeHeaders(@[
        (":status", "200")
      ])
    ))
  except CatchableError:
    failed = true

  doAssert not failed, "client must accept zero-length initial HEADERS fragments before CONTINUATION"
  doAssert responseFut.finished, "response future should complete when END_STREAM was set on initial HEADERS"
  doAssert not responseFut.hasError(), "response must not fail for legal zero-length initial HEADERS fragment"
  doAssert responseFut.read().statusCode == 200, "expected status 200 from continued header block"
  echo "PASS: HTTP/2 client accepts zero-length initial HEADERS fragment"

# ============================================================
# Test 19: Client rejects trailers containing pseudo-headers
# ============================================================
block testClientRejectsPseudoHeadersInTrailers:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)

  let streamId = 1'u32
  conn.streams[streamId] = Http2Stream(
    id: streamId,
    state: ssOpen,
    responseHeaders: @[],
    responseBody: @[],
    headerBlock: @[],
    responseFuture: newCpsFuture[Http2Response](),
    windowSize: DefaultWindowSize,
    headersDone: false,
    endStream: false
  )

  discard processFrame(conn, Http2Frame(
    frameType: FrameHeaders,
    flags: FlagEndHeaders,
    streamId: streamId,
    payload: encodeHeaders(@[
      (":status", "200")
    ])
  ))

  var failed = false
  try:
    discard processFrame(conn, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: streamId,
      payload: encodeHeaders(@[
        (":status", "204")
      ])
    ))
  except CatchableError:
    failed = true

  doAssert failed, "client must reject response trailers containing pseudo-headers"
  echo "PASS: HTTP/2 client rejects trailers containing pseudo-headers"

# ============================================================
# Test 20: Client rejects trailing HEADERS that omit END_STREAM
# ============================================================
block testClientRejectsTrailersWithoutEndStream:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)

  let streamId = 1'u32
  conn.streams[streamId] = Http2Stream(
    id: streamId,
    state: ssOpen,
    responseHeaders: @[],
    responseBody: @[],
    headerBlock: @[],
    responseFuture: newCpsFuture[Http2Response](),
    windowSize: DefaultWindowSize,
    headersDone: false,
    endStream: false
  )

  discard processFrame(conn, Http2Frame(
    frameType: FrameHeaders,
    flags: FlagEndHeaders,
    streamId: streamId,
    payload: encodeHeaders(@[
      (":status", "200")
    ])
  ))

  var failed = false
  try:
    discard processFrame(conn, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders,
      streamId: streamId,
      payload: encodeHeaders(@[
        ("x-trailer", "1")
      ])
    ))
  except CatchableError:
    failed = true

  doAssert failed, "client must reject trailing HEADERS blocks that omit END_STREAM"
  echo "PASS: HTTP/2 client rejects trailing HEADERS that omit END_STREAM"

# ============================================================
# Test 21: Client rejects DATA before final (non-1xx) response headers
# ============================================================
block testClientRejectsDataBeforeFinalHeaders:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)

  let streamId = 1'u32
  conn.streams[streamId] = Http2Stream(
    id: streamId,
    state: ssOpen,
    responseHeaders: @[],
    responseBody: @[],
    headerBlock: @[],
    responseFuture: newCpsFuture[Http2Response](),
    windowSize: DefaultWindowSize,
    headersDone: false,
    endStream: false
  )

  discard processFrame(conn, Http2Frame(
    frameType: FrameHeaders,
    flags: FlagEndHeaders,
    streamId: streamId,
    payload: encodeHeaders(@[
      (":status", "103")
    ])
  ))

  var failed = false
  try:
    discard processFrame(conn, Http2Frame(
      frameType: FrameData,
      flags: FlagEndStream,
      streamId: streamId,
      payload: @[byte('x')]
    ))
  except CatchableError:
    failed = true

  doAssert failed, "client must reject DATA frames that arrive before final response headers"
  echo "PASS: HTTP/2 client rejects DATA before final response headers"

# ============================================================
# Test 22: Client rejects RST_STREAM on idle stream
# ============================================================
block testClientRejectsIdleRstStream:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)

  var failed = false
  try:
    discard processFrame(conn, Http2Frame(
      frameType: FrameRstStream,
      flags: 0,
      streamId: 1'u32,
      payload: @[0'u8, 0'u8, 0'u8, 0'u8]
    ))
  except CatchableError:
    failed = true

  doAssert failed, "client must reject RST_STREAM on idle stream"
  echo "PASS: HTTP/2 client rejects RST_STREAM on idle stream"

# ============================================================
# Test 23: Client rejects GOAWAY on non-zero stream
# ============================================================
block testClientRejectsGoAwayOnNonZeroStream:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)

  var failed = false
  try:
    discard processFrame(conn, Http2Frame(
      frameType: FrameGoAway,
      flags: 0,
      streamId: 1'u32,
      payload: goAwayPayload(0'u32, 0'u32)
    ))
  except CatchableError:
    failed = true

  doAssert failed, "client must reject GOAWAY frames on non-zero stream IDs"
  echo "PASS: HTTP/2 client rejects GOAWAY on non-zero stream"

# ============================================================
# Test 24: Client rejects creating streams after stream ID exhaustion
# ============================================================
block testClientRejectsStreamIdExhaustion:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)
  conn.running = true
  conn.nextStreamId = 0x8000_0001'u32

  var failed = false
  try:
    let rf = request(conn, "GET", "/", "localhost")
    let loop = getEventLoop()
    var ticks = 0
    while not rf.finished and ticks < 10_000:
      loop.tick()
      inc ticks
      if not loop.hasWork and ticks > 100:
        break
    failed = rf.finished and rf.hasError()
  except CatchableError:
    failed = true

  doAssert failed, "request should error when stream IDs are exhausted"
  echo "PASS: HTTP/2 client rejects creating streams after stream ID exhaustion"

# ============================================================
# Test 25: Client rejects pseudo-header overrides in request headers
# ============================================================
block testClientRejectsPseudoHeaderOverrideRequest:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)
  conn.running = true

  var failed = false
  try:
    let rf = request(conn, "GET", "/", "localhost", headers = @[(":path", "/override")])
    let loop = getEventLoop()
    var ticks = 0
    while not rf.finished and ticks < 10_000:
      loop.tick()
      inc ticks
      if not loop.hasWork and ticks > 100:
        break
    failed = rf.finished and rf.hasError()
  except CatchableError:
    failed = true

  doAssert failed, "request should error on pseudo-header override"
  echo "PASS: HTTP/2 client rejects pseudo-header overrides in request headers"

# ============================================================
# Test 26: Client rejects forbidden connection-specific request headers
# ============================================================
block testClientRejectsForbiddenRequestHeader:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)
  conn.running = true

  var failed = false
  try:
    let rf = request(conn, "GET", "/", "localhost", headers = @[("connection", "close")])
    let loop = getEventLoop()
    var ticks = 0
    while not rf.finished and ticks < 10_000:
      loop.tick()
      inc ticks
      if not loop.hasWork and ticks > 100:
        break
    failed = rf.finished and rf.hasError()
  except CatchableError:
    failed = true

  doAssert failed, "request should error on forbidden connection-specific header"
  echo "PASS: HTTP/2 client rejects forbidden connection-specific request headers"

# ============================================================
# Test 27: Client rejects host/:authority mismatch in request headers
# ============================================================
block testClientRejectsHostAuthorityMismatchRequest:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)
  conn.running = true

  var failed = false
  try:
    let rf = request(conn, "GET", "/", "good.example", headers = @[("host", "evil.example")])
    let loop = getEventLoop()
    var ticks = 0
    while not rf.finished and ticks < 10_000:
      loop.tick()
      inc ticks
      if not loop.hasWork and ticks > 100:
        break
    failed = rf.finished and rf.hasError()
  except CatchableError:
    failed = true

  doAssert failed, "request should error on host/:authority mismatch"
  echo "PASS: HTTP/2 client rejects host/:authority mismatch in request headers"

# ============================================================
# Test 28: Client rejects invalid :authority pseudo-header value
# ============================================================
block testClientRejectsInvalidAuthorityPseudoHeaderValue:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)
  conn.running = true

  var failed = false
  try:
    let rf = request(conn, "GET", "/", "bad\r\nauthority")
    let loop = getEventLoop()
    var ticks = 0
    while not rf.finished and ticks < 10_000:
      loop.tick()
      inc ticks
      if not loop.hasWork and ticks > 100:
        break
    failed = rf.finished and rf.hasError()
  except CatchableError:
    failed = true

  doAssert failed, "request should error on invalid :authority value"
  echo "PASS: HTTP/2 client rejects invalid :authority pseudo-header value"

# ============================================================
# Test 28b: Client rejects :authority pseudo-header containing spaces
# ============================================================
block testClientRejectsAuthorityWithSpace:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)
  conn.running = true

  var failed = false
  try:
    let rf = request(conn, "GET", "/", "bad host")
    let loop = getEventLoop()
    var ticks = 0
    while not rf.finished and ticks < 10_000:
      loop.tick()
      inc ticks
      if not loop.hasWork and ticks > 100:
        break
    failed = rf.finished and rf.hasError()
  except CatchableError:
    failed = true

  doAssert failed, "request should error on :authority containing spaces"
  echo "PASS: HTTP/2 client rejects :authority containing spaces"

# ============================================================
# Test 29: Client rejects invalid :path pseudo-header value
# ============================================================
block testClientRejectsInvalidPathPseudoHeaderValue:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)
  conn.running = true

  var failed = false
  try:
    let rf = request(conn, "GET", "/bad\r\npath", "localhost")
    let loop = getEventLoop()
    var ticks = 0
    while not rf.finished and ticks < 10_000:
      loop.tick()
      inc ticks
      if not loop.hasWork and ticks > 100:
        break
    failed = rf.finished and rf.hasError()
  except CatchableError:
    failed = true

  doAssert failed, "request should error on invalid :path value"
  echo "PASS: HTTP/2 client rejects invalid :path pseudo-header value"

# ============================================================
# Test 29b: Client rejects :path pseudo-header containing spaces
# ============================================================
block testClientRejectsPathWithSpace:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)
  conn.running = true

  var failed = false
  try:
    let rf = request(conn, "GET", "/bad path", "localhost")
    let loop = getEventLoop()
    var ticks = 0
    while not rf.finished and ticks < 10_000:
      loop.tick()
      inc ticks
      if not loop.hasWork and ticks > 100:
        break
    failed = rf.finished and rf.hasError()
  except CatchableError:
    failed = true

  doAssert failed, "request should error on :path containing spaces"
  echo "PASS: HTTP/2 client rejects :path containing spaces"

# ============================================================
# Test 29c: Client rejects :path pseudo-header containing fragment
# ============================================================
block testClientRejectsPathWithFragment:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)
  conn.running = true

  var failed = false
  try:
    let rf = request(conn, "GET", "/resource#fragment", "localhost")
    let loop = getEventLoop()
    var ticks = 0
    while not rf.finished and ticks < 10_000:
      loop.tick()
      inc ticks
      if not loop.hasWork and ticks > 100:
        break
    failed = rf.finished and rf.hasError()
  except CatchableError:
    failed = true

  doAssert failed, "request should error on :path containing URI fragment"
  echo "PASS: HTTP/2 client rejects :path containing fragment"

# ============================================================
# Test 30: Client rejects PRIORITY frames on stream 0
# ============================================================
block testClientRejectsPriorityOnStreamZero:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)

  var failed = false
  try:
    discard processFrame(conn, Http2Frame(
      frameType: FramePriority,
      flags: 0,
      streamId: 0'u32,
      payload: @[0'u8, 0'u8, 0'u8, 1'u8, 16'u8]
    ))
  except CatchableError:
    failed = true

  doAssert failed, "client must reject PRIORITY frames on stream 0"
  echo "PASS: HTTP/2 client rejects PRIORITY frames on stream 0"

# ============================================================
# Test 29: Client rejects malformed PRIORITY frame size
# ============================================================
block testClientRejectsMalformedPrioritySize:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)

  var failed = false
  try:
    discard processFrame(conn, Http2Frame(
      frameType: FramePriority,
      flags: 0,
      streamId: 1'u32,
      payload: @[0'u8, 0'u8, 0'u8, 1'u8]
    ))
  except CatchableError:
    failed = true

  doAssert failed, "client must reject malformed PRIORITY frame payload size"
  echo "PASS: HTTP/2 client rejects malformed PRIORITY frame size"

# ============================================================
# Test 30: Client maps PRIORITY self-dependency to RST_STREAM
# ============================================================
block testClientPrioritySelfDependencyIsStreamError:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)

  let streamId = 1'u32
  conn.streams[streamId] = Http2Stream(
    id: streamId,
    state: ssOpen,
    responseHeaders: @[],
    responseBody: @[],
    headerBlock: @[],
    responseFuture: newCpsFuture[Http2Response](),
    windowSize: DefaultWindowSize,
    headersDone: true,
    endStream: false,
    finalHeadersSeen: false,
    trailersSeen: false,
    expectedContentLength: -1
  )

  let responses = processFrame(conn, Http2Frame(
    frameType: FramePriority,
    flags: 0,
    streamId: streamId,
    payload: @[0'u8, 0'u8, 0'u8, byte(streamId and 0xFF), 16'u8]
  ))

  doAssert responses.len == 1, "expected one RST_STREAM response for PRIORITY self-dependency"
  doAssert responses[0].frameType == FrameRstStream, "expected RST_STREAM response"
  doAssert responses[0].streamId == streamId, "RST_STREAM must target offending stream"
  doAssert responses[0].payload.len == 4, "RST_STREAM payload must include error code"
  let errCode = (uint32(responses[0].payload[0]) shl 24) or
                (uint32(responses[0].payload[1]) shl 16) or
                (uint32(responses[0].payload[2]) shl 8) or
                uint32(responses[0].payload[3])
  doAssert errCode == 1'u32, "expected PROTOCOL_ERROR (1) for PRIORITY self-dependency"
  doAssert streamId notin conn.streams, "offending stream should be closed after PRIORITY stream error"
  echo "PASS: HTTP/2 client maps PRIORITY self-dependency to RST_STREAM"

# ============================================================
# Test 31: Client ignores unknown PRIORITY flags
# ============================================================
block testClientIgnoresUnknownPriorityFlags:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)

  let streamId = 1'u32
  conn.streams[streamId] = Http2Stream(
    id: streamId,
    state: ssOpen,
    responseHeaders: @[],
    responseBody: @[],
    headerBlock: @[],
    responseFuture: newCpsFuture[Http2Response](),
    windowSize: DefaultWindowSize,
    headersDone: true,
    endStream: false,
    finalHeadersSeen: false,
    trailersSeen: false,
    expectedContentLength: -1
  )

  var failed = false
  var responses: seq[Http2Frame] = @[]
  try:
    responses = processFrame(conn, Http2Frame(
      frameType: FramePriority,
      flags: FlagPadded or FlagPriority,
      streamId: streamId,
      payload: @[0'u8, 0'u8, 0'u8, 0'u8, 16'u8]
    ))
  except CatchableError:
    failed = true

  doAssert not failed, "client must ignore undefined PRIORITY flags"
  doAssert responses.len == 0, "PRIORITY with unknown flags should not emit control frames"
  doAssert streamId in conn.streams, "stream should remain open after PRIORITY with unknown flags"
  echo "PASS: HTTP/2 client ignores unknown PRIORITY flags"

# ============================================================
# Test 32: Client maps HEADERS priority self-dependency to RST_STREAM
# ============================================================
block testClientHeadersPrioritySelfDependencyIsStreamError:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)

  let streamId = 1'u32
  conn.streams[streamId] = Http2Stream(
    id: streamId,
    state: ssOpen,
    responseHeaders: @[],
    responseBody: @[],
    headerBlock: @[],
    responseFuture: newCpsFuture[Http2Response](),
    windowSize: DefaultWindowSize,
    headersDone: false,
    endStream: false,
    finalHeadersSeen: false,
    trailersSeen: false,
    expectedContentLength: -1
  )

  let encoded = encodeHeaders(@[
    (":status", "200")
  ])
  var payload = @[
    byte((streamId shr 24) and 0x7F),
    byte((streamId shr 16) and 0xFF),
    byte((streamId shr 8) and 0xFF),
    byte(streamId and 0xFF),
    16'u8
  ]
  payload.add(encoded)

  let responses = processFrame(conn, Http2Frame(
    frameType: FrameHeaders,
    flags: FlagPriority or FlagEndHeaders,
    streamId: streamId,
    payload: payload
  ))

  doAssert responses.len == 1, "expected one RST_STREAM response for HEADERS priority self-dependency"
  doAssert responses[0].frameType == FrameRstStream, "expected RST_STREAM response"
  doAssert responses[0].streamId == streamId, "RST_STREAM must target offending stream"
  doAssert responses[0].payload.len == 4, "RST_STREAM payload must include error code"
  let errCode = (uint32(responses[0].payload[0]) shl 24) or
                (uint32(responses[0].payload[1]) shl 16) or
                (uint32(responses[0].payload[2]) shl 8) or
                uint32(responses[0].payload[3])
  doAssert errCode == 1'u32, "expected PROTOCOL_ERROR (1) for HEADERS priority self-dependency"
  doAssert streamId notin conn.streams, "offending stream should be closed after HEADERS priority stream error"
  echo "PASS: HTTP/2 client maps HEADERS priority self-dependency to RST_STREAM"

# ============================================================
# Test 33: Client rejects invalid response content-length value
# ============================================================
block testClientRejectsInvalidResponseContentLength:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)

  let streamId = 1'u32
  conn.streams[streamId] = Http2Stream(
    id: streamId,
    state: ssOpen,
    responseHeaders: @[],
    responseBody: @[],
    headerBlock: @[],
    responseFuture: newCpsFuture[Http2Response](),
    windowSize: DefaultWindowSize,
    headersDone: false,
    endStream: false,
    finalHeadersSeen: false,
    trailersSeen: false,
    expectedContentLength: -1
  )

  var failed = false
  try:
    discard processFrame(conn, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: streamId,
      payload: encodeHeaders(@[
        (":status", "200"),
        ("content-length", "abc")
      ])
    ))
  except CatchableError:
    failed = true

  doAssert failed, "client must reject invalid response content-length values"
  echo "PASS: HTTP/2 client rejects invalid response content-length value"

# ============================================================
# Test 34: Client rejects response body exceeding content-length
# ============================================================
block testClientRejectsResponseBodyExceedingContentLength:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)

  let streamId = 1'u32
  conn.streams[streamId] = Http2Stream(
    id: streamId,
    state: ssOpen,
    responseHeaders: @[],
    responseBody: @[],
    headerBlock: @[],
    responseFuture: newCpsFuture[Http2Response](),
    windowSize: DefaultWindowSize,
    headersDone: false,
    endStream: false,
    finalHeadersSeen: false,
    trailersSeen: false,
    expectedContentLength: -1
  )

  discard processFrame(conn, Http2Frame(
    frameType: FrameHeaders,
    flags: FlagEndHeaders,
    streamId: streamId,
    payload: encodeHeaders(@[
      (":status", "200"),
      ("content-length", "2")
    ])
  ))

  var failed = false
  try:
    discard processFrame(conn, Http2Frame(
      frameType: FrameData,
      flags: FlagEndStream,
      streamId: streamId,
      payload: @[byte('a'), byte('b'), byte('c')]
    ))
  except CatchableError:
    failed = true

  doAssert failed, "client must reject responses whose DATA length exceeds content-length"
  echo "PASS: HTTP/2 client rejects response body exceeding content-length"

# ============================================================
# Test 35: Client rejects invalid request content-length header value
# ============================================================
block testClientRejectsDataOn204Response:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)

  let streamId = 1'u32
  conn.streams[streamId] = Http2Stream(
    id: streamId,
    state: ssOpen,
    responseHeaders: @[],
    responseBody: @[],
    headerBlock: @[],
    responseFuture: newCpsFuture[Http2Response](),
    windowSize: DefaultWindowSize,
    headersDone: false,
    endStream: false,
    finalHeadersSeen: false,
    trailersSeen: false,
    expectedContentLength: -1
  )

  discard processFrame(conn, Http2Frame(
    frameType: FrameHeaders,
    flags: FlagEndHeaders,
    streamId: streamId,
    payload: encodeHeaders(@[
      (":status", "204")
    ])
  ))

  var failed = false
  try:
    discard processFrame(conn, Http2Frame(
      frameType: FrameData,
      flags: FlagEndStream,
      streamId: streamId,
      payload: @[byte('x')]
    ))
  except CatchableError:
    failed = true

  doAssert failed, "client must reject DATA on 204 no-content response"
  echo "PASS: HTTP/2 client rejects DATA on 204 response"

# ============================================================
# Test 35: Client rejects DATA on 205 response
# ============================================================
block testClientRejectsDataOn205Response:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)

  let streamId = 1'u32
  conn.streams[streamId] = Http2Stream(
    id: streamId,
    state: ssOpen,
    responseHeaders: @[],
    responseBody: @[],
    headerBlock: @[],
    responseFuture: newCpsFuture[Http2Response](),
    windowSize: DefaultWindowSize,
    headersDone: false,
    endStream: false,
    finalHeadersSeen: false,
    trailersSeen: false,
    expectedContentLength: -1
  )

  discard processFrame(conn, Http2Frame(
    frameType: FrameHeaders,
    flags: FlagEndHeaders,
    streamId: streamId,
    payload: encodeHeaders(@[
      (":status", "205")
    ])
  ))

  var failed = false
  try:
    discard processFrame(conn, Http2Frame(
      frameType: FrameData,
      flags: FlagEndStream,
      streamId: streamId,
      payload: @[byte('x')]
    ))
  except CatchableError:
    failed = true

  doAssert failed, "client must reject DATA on 205 reset-content response"
  echo "PASS: HTTP/2 client rejects DATA on 205 response"

# ============================================================
# Test 35: Client rejects invalid request content-length header value
# ============================================================
block testClientRejectsInvalidRequestContentLength:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)
  conn.running = true

  var failed = false
  try:
    let rf = request(
      conn,
      "POST",
      "/invalid-cl",
      "localhost",
      headers = @[("content-length", "abc")],
      body = "x"
    )
    let loop = getEventLoop()
    var ticks = 0
    while not rf.finished and ticks < 10_000:
      loop.tick()
      inc ticks
      if not loop.hasWork and ticks > 100:
        break
    failed = rf.finished and rf.hasError()
  except CatchableError:
    failed = true

  doAssert failed, "request should error on invalid content-length value"
  echo "PASS: HTTP/2 client rejects invalid request content-length header value"

# ============================================================
# Test 36: Client rejects mismatched request content-length
# ============================================================
block testClientRejectsMismatchedRequestContentLength:
  let outStream = newInterleaveStream()
  let conn = newHttp2Connection(outStream.AsyncStream)
  conn.running = true

  var failed = false
  try:
    let rf = request(
      conn,
      "POST",
      "/mismatch-cl",
      "localhost",
      headers = @[("content-length", "5")],
      body = "x"
    )
    let loop = getEventLoop()
    var ticks = 0
    while not rf.finished and ticks < 10_000:
      loop.tick()
      inc ticks
      if not loop.hasWork and ticks > 100:
        break
    failed = rf.finished and rf.hasError()
  except CatchableError:
    failed = true

  doAssert failed, "request should error when content-length does not match body size"
  echo "PASS: HTTP/2 client rejects mismatched request content-length"

# ============================================================
# Test 37: Client accepts HEAD response with representation content-length
# ============================================================
block testClientAcceptsHeadResponseWithRepresentationContentLength:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc serverTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let s = client.AsyncStream
    let reader = newBufferedReader(s)

    discard await reader.readExact(ConnectionPreface.len)
    let cSettings = await recvH2Frame(reader)
    doAssert cSettings.frameType == FrameSettings
    await sendServerSettings(s)

    var reqStreamId = 1'u32
    var gotEndStream = false
    while not gotEndStream:
      let frame = await recvH2Frame(reader)
      case frame.frameType
      of FrameHeaders:
        reqStreamId = frame.streamId
        if (frame.flags and FlagEndHeaders) == 0:
          var done = false
          while not done:
            let cont = await recvH2Frame(reader)
            doAssert cont.frameType == FrameContinuation
            doAssert cont.streamId == reqStreamId
            if (cont.flags and FlagEndHeaders) != 0:
              done = true
        if (frame.flags and FlagEndStream) != 0:
          gotEndStream = true
      of FrameData:
        reqStreamId = frame.streamId
        if (frame.flags and FlagEndStream) != 0:
          gotEndStream = true
      else:
        discard

    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: reqStreamId,
      payload: encodeHeaders(@[
        (":status", "200"),
        ("content-length", "5")
      ])
    ))
    s.close()

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let tcpConn = await tcpConnect("127.0.0.1", p)
    let conn = newHttp2Connection(tcpConn.AsyncStream)
    await initConnection(conn)
    discard runReceiveLoop(conn)

    let resp = await request(conn, "HEAD", "/head", "localhost")
    return $resp.statusCode & "|" & $resp.body.len

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not sf.finished or not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  doAssert sf.finished, "server task did not complete"
  doAssert cf.finished, "client task did not complete"
  doAssert not cf.hasError(), "HEAD request with representation content-length should succeed"
  doAssert cf.read() == "200|0", "expected 200 with empty HEAD response body"
  listener.close()
  echo "PASS: HTTP/2 client accepts HEAD response with representation content-length"

# ============================================================
# Test 38: Client accepts 304 response with representation content-length
# ============================================================
block testClientAccepts304ResponseWithRepresentationContentLength:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc serverTask(l: TcpListener): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    let s = client.AsyncStream
    let reader = newBufferedReader(s)

    discard await reader.readExact(ConnectionPreface.len)
    let cSettings = await recvH2Frame(reader)
    doAssert cSettings.frameType == FrameSettings
    await sendServerSettings(s)

    var reqStreamId = 1'u32
    var gotEndStream = false
    while not gotEndStream:
      let frame = await recvH2Frame(reader)
      case frame.frameType
      of FrameHeaders:
        reqStreamId = frame.streamId
        if (frame.flags and FlagEndHeaders) == 0:
          var done = false
          while not done:
            let cont = await recvH2Frame(reader)
            doAssert cont.frameType == FrameContinuation
            doAssert cont.streamId == reqStreamId
            if (cont.flags and FlagEndHeaders) != 0:
              done = true
        if (frame.flags and FlagEndStream) != 0:
          gotEndStream = true
      of FrameData:
        reqStreamId = frame.streamId
        if (frame.flags and FlagEndStream) != 0:
          gotEndStream = true
      else:
        discard

    await sendH2Frame(s, Http2Frame(
      frameType: FrameHeaders,
      flags: FlagEndHeaders or FlagEndStream,
      streamId: reqStreamId,
      payload: encodeHeaders(@[
        (":status", "304"),
        ("content-length", "5")
      ])
    ))
    s.close()

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let tcpConn = await tcpConnect("127.0.0.1", p)
    let conn = newHttp2Connection(tcpConn.AsyncStream)
    await initConnection(conn)
    discard runReceiveLoop(conn)

    let resp = await request(conn, "GET", "/cached", "localhost")
    return $resp.statusCode & "|" & $resp.body.len

  let sf = serverTask(listener)
  let cf = clientTask(port)
  let loop = getEventLoop()
  while not sf.finished or not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break

  doAssert sf.finished, "server task did not complete"
  doAssert cf.finished, "client task did not complete"
  doAssert not cf.hasError(), "304 response with representation content-length should succeed"
  doAssert cf.read() == "304|0", "expected 304 with empty response body"
  listener.close()
  echo "PASS: HTTP/2 client accepts 304 response with representation content-length"

echo ""
echo "All HTTP/2 client protocol tests passed!"
