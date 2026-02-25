## Tests for HTTP/2 PRIORITY flag handling
##
## Verifies that undefined PRIORITY flags are ignored and do not trigger
## connection-level protocol errors.

import std/[strutils, nativesockets]
from std/posix import Sockaddr_in, SockLen
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/io/buffered
import cps/http/server/types
import cps/http/server/http2 as http2_server
import cps/http/shared/http2
import cps/http/shared/hpack

proc getListenerPort(listener: TcpListener): int =
  var localAddr: Sockaddr_in
  var addrLen: SockLen = sizeof(localAddr).SockLen
  let rc = posix.getsockname(listener.fd, cast[ptr SockAddr](addr localAddr), addr addrLen)
  assert rc == 0, "getsockname failed"
  result = ntohs(localAddr.sin_port).int

proc sendH2Frame(s: AsyncStream, frame: Http2Frame): CpsVoidFuture =
  let data = serializeFrame(frame)
  var str = newString(data.len)
  for i, b in data:
    str[i] = char(b)
  s.write(str)

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

proc sendConnectionPreface(s: AsyncStream): CpsVoidFuture {.cps.} =
  await s.write(ConnectionPreface)
  await sendH2Frame(s, Http2Frame(
    frameType: FrameSettings,
    flags: 0,
    streamId: 0,
    payload: @[]
  ))

proc encodeHeaders(headers: seq[(string, string)]): seq[byte] =
  var enc = initHpackEncoder()
  enc.encode(headers)

proc decodeHeaders(payload: seq[byte]): seq[(string, string)] =
  var dec = initHpackDecoder()
  dec.decode(payload)

proc goAwayErrorCode(frame: Http2Frame): uint32 =
  if frame.payload.len < 8:
    return 0'u32
  (uint32(frame.payload[4]) shl 24) or
  (uint32(frame.payload[5]) shl 16) or
  (uint32(frame.payload[6]) shl 8) or
  uint32(frame.payload[7])

block testH2IgnoresUnknownPriorityFlags:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc okHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
    return newResponse(200, "ok-priority-flags")

  proc serverTask(l: TcpListener, cfg: HttpServerConfig): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp2Connection(client.AsyncStream, cfg, okHandler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let s = conn.AsyncStream
    let reader = newBufferedReader(s)
    var goAwayErr = 0'u32
    var statusCode = 0
    var body = ""

    try:
      await sendConnectionPreface(s)
      let serverSettings = await recvH2Frame(reader)
      assert serverSettings.frameType == FrameSettings
      await sendH2Frame(s, Http2Frame(frameType: FrameSettings, flags: FlagAck, streamId: 0, payload: @[]))
      let serverAck = await recvH2Frame(reader)
      assert serverAck.frameType == FrameSettings
      assert (serverAck.flags and FlagAck) != 0

      await sendH2Frame(s, Http2Frame(
        frameType: FramePriority,
        flags: FlagPadded or FlagPriority,
        streamId: 1,
        payload: @[0'u8, 0'u8, 0'u8, 0'u8, 16'u8]
      ))

      let reqHeaders = encodeHeaders(@[
        (":method", "GET"),
        (":path", "/priority-flags"),
        (":scheme", "http"),
        (":authority", "localhost")
      ])
      await sendH2Frame(s, Http2Frame(
        frameType: FrameHeaders,
        flags: FlagEndHeaders or FlagEndStream,
        streamId: 3,
        payload: reqHeaders
      ))

      var attempts = 0
      while attempts < 16:
        var frame: Http2Frame
        try:
          frame = await recvH2Frame(reader)
        except CatchableError:
          break

        if frame.frameType == FrameGoAway:
          goAwayErr = goAwayErrorCode(frame)
          break

        if frame.streamId == 3 and frame.frameType == FrameHeaders:
          let decoded = decodeHeaders(frame.payload)
          for i in 0 ..< decoded.len:
            if decoded[i][0] == ":status":
              statusCode = parseInt(decoded[i][1])
          if (frame.flags and FlagEndStream) != 0:
            break
        elif frame.streamId == 3 and frame.frameType == FrameData:
          for i in 0 ..< frame.payload.len:
            body &= char(frame.payload[i])
          if (frame.flags and FlagEndStream) != 0:
            break
        inc attempts
    except CatchableError:
      discard

    s.close()
    if goAwayErr != 0'u32:
      return "goaway:" & $goAwayErr
    return $statusCode & "|" & body

  let sf = serverTask(listener, config)
  let cf = clientTask(port)
  let loop = getEventLoop()
  var ticks = 0
  while not cf.finished and ticks < 50_000:
    loop.tick()
    inc ticks

  assert cf.finished, "Unknown PRIORITY flags client did not complete"
  var result = ""
  if not cf.hasError():
    result = cf.read()
  assert result == "200|ok-priority-flags",
    "Expected successful response after PRIORITY with unknown flags, got: " & result
  listener.close()
  echo "PASS: HTTP/2 ignores unknown PRIORITY flags"

echo ""
echo "All HTTP/2 PRIORITY-flag tests passed!"
