## HTTP/3 server request-body limit enforcement tests.

import cps/runtime
import cps/transform
import cps/eventloop
import std/strutils
import cps/http/server/types
import cps/http/server/http3 as server_http3
import cps/http/client/http3 as client_http3
import cps/http/shared/http3
import cps/http/shared/http3_connection

proc runLoopUntilFinished[T](f: CpsFuture[T], maxTicks: int = 10_000) =
  let loop = getEventLoop()
  var ticks = 0
  while not f.finished and ticks < maxTicks:
    loop.tick()
    inc ticks
  doAssert f.finished, "Timed out waiting for CPS future"

proc echoHandler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
  return newResponse(200, "echo:" & req.body, @[("content-type", "text/plain")])

proc parseStatusFromFrames(payload: seq[byte]): int =
  var st = 0
  let frames = decodeAllHttp3Frames(payload)
  for f in frames:
    if f.frameType == H3FrameHeaders:
      let conn = newHttp3Connection(isClient = true, useRfcQpackWire = true)
      let headers = conn.decodeHeadersFrame(f.payload)
      for (k, v) in headers:
        if k == ":status":
          st = parseInt(v)
          break
  st

block testOversizedBodyReturns413:
  let server = server_http3.newHttp3ServerSession(
    @[0xA1'u8],
    echoHandler,
    maxRequestBodySize = 32
  )
  let client = client_http3.newHttp3ClientSession()
  let oversized = repeat("x", 128)
  let reqFrames = client.encodeRequestFrames("POST", "/upload", "example.com", @[], oversized)
  let fut = server.handleHttp3RequestFrames(4'u64, reqFrames, streamEnded = false)
  runLoopUntilFinished(fut)
  doAssert not fut.hasError()
  let respFrames = fut.read()
  doAssert respFrames.len > 0
  doAssert parseStatusFromFrames(respFrames) == 413
  echo "PASS: HTTP/3 oversized request body returns 413"

block testSmallBodyStillAccepted:
  let server = server_http3.newHttp3ServerSession(
    @[0xA2'u8],
    echoHandler,
    maxRequestBodySize = 1024
  )
  let client = client_http3.newHttp3ClientSession()
  let reqFrames = client.encodeRequestFrames("POST", "/upload", "example.com", @[], "ok")
  let fut = server.handleHttp3RequestFrames(8'u64, reqFrames, streamEnded = true)
  runLoopUntilFinished(fut)
  doAssert not fut.hasError()
  let respFrames = fut.read()
  doAssert respFrames.len > 0
  doAssert parseStatusFromFrames(respFrames) == 200
  echo "PASS: HTTP/3 in-limit request body remains accepted"

block testFragmentedOversizedBufferRejectedEarly:
  let server = server_http3.newHttp3ServerSession(
    @[0xA3'u8],
    echoHandler,
    maxRequestBodySize = 32
  )
  let client = client_http3.newHttp3ClientSession()
  let huge = repeat("y", 131_072)
  let reqFrames = client.encodeRequestFrames("POST", "/upload", "example.com", @[], huge)
  doAssert reqFrames.len > 70_000

  # Send only a large prefix: enough to exceed buffering cap but not enough to
  # complete the DATA frame payload decode.
  let firstChunk = reqFrames[0 ..< 70_000]
  let fut = server.handleHttp3RequestFrames(12'u64, firstChunk, streamEnded = false)
  runLoopUntilFinished(fut)
  doAssert not fut.hasError()
  let respFrames = fut.read()
  doAssert respFrames.len > 0
  doAssert parseStatusFromFrames(respFrames) == 413
  echo "PASS: HTTP/3 fragmented oversized buffering rejected with 413"

echo "All HTTP/3 server body-limit tests passed"
