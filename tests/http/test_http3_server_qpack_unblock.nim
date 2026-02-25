## HTTP/3 server request decode should recover from QPACK-blocked request headers
## once peer encoder-stream instructions arrive.

import cps/runtime
import cps/transform
import cps/eventloop
import cps/http/server/types
import cps/http/server/http3 as server_http3
import cps/http/client/http3 as client_http3
import cps/http/shared/http3
import cps/http/shared/http3_connection
import cps/http/shared/qpack
import cps/quic/varint

proc runLoopUntilFinished[T](f: CpsFuture[T], maxTicks: int = 10_000) =
  let loop = getEventLoop()
  var ticks = 0
  while not f.finished and ticks < maxTicks:
    loop.tick()
    inc ticks
  doAssert f.finished, "Timed out waiting for CPS future"

proc appendPlainRfcString(dst: var seq[byte], s: string) =
  doAssert s.len < 128
  dst.add uint8(s.len)
  for c in s:
    dst.add byte(ord(c) and 0xFF)

proc testHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
  discard req
  return newResponse(200, "ok")

block testServerRequestUnblocksAfterQpackEncoderUpdate:
  let server = server_http3.newHttp3ServerSession(@[0x77'u8], testHandler)

  # RFC9204 header block:
  # - Prefix RIC=1/Base=1.
  # - Indexed dynamic field (idx=0) for :method GET, blocked until encoder stream inserts it.
  # - :scheme https (static idx 23), :authority example.com, :path /.
  var headerBlock: seq[byte] = @[
    0x02'u8, # Encoded Required Insert Count for RIC=1 with default maxEntries=128.
    0x00'u8, # Delta Base = 0 (Base=RIC).
    0x80'u8, # Indexed field line, dynamic, relative index 0.
    0xD7'u8, # Indexed field line, static index 23 (:scheme, https).
    0x50'u8  # Literal with name reference, static index 0 (:authority).
  ]
  headerBlock.appendPlainRfcString("example.com")
  headerBlock.add 0xC1'u8 # Indexed field line, static index 1 (:path, /).

  let reqFrames = encodeHttp3Frame(H3FrameHeaders, headerBlock)
  let blockedFut = server.handleHttp3RequestFrames(4'u64, reqFrames, streamEnded = true)
  runLoopUntilFinished(blockedFut)
  doAssert not blockedFut.hasError()
  doAssert blockedFut.read().len == 0
  doAssert server.isQpackBlockedRequestStream(4'u64)

  var encoderStreamBytes: seq[byte] = @[]
  encoderStreamBytes.appendQuicVarInt(H3UniQpackEncoderStream)
  encoderStreamBytes.add encodeEncoderInstruction(QpackEncoderInstruction(
    kind: qeikInsertLiteral,
    name: ":method",
    value: "GET"
  ))
  let uniEvents = server.conn.ingestUniStreamData(6'u64, encoderStreamBytes)
  for ev in uniEvents:
    doAssert ev.kind != h3evProtocolError,
      "Unexpected protocol error while ingesting QPACK encoder stream: " & ev.errorMessage

  let retryFut = server.handleHttp3RequestFrames(4'u64, @[], streamEnded = true)
  runLoopUntilFinished(retryFut)
  doAssert not retryFut.hasError()
  let respFrames = retryFut.read()
  doAssert respFrames.len > 0

  let client = client_http3.newHttp3ClientSession()
  let resp = client.decodeResponseFrames(4'u64, respFrames)
  doAssert resp.statusCode == 200
  doAssert resp.body == "ok"
  echo "PASS: HTTP/3 server recovers blocked request decode after QPACK encoder updates"

echo "All HTTP/3 server QPACK unblock tests passed"
