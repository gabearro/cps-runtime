import cps/http/server/http3 as server_http3
import cps/http/server/types
import cps/runtime
import cps/transform
import cps/eventloop

proc runLoopUntilFinished[T](f: CpsFuture[T], maxTicks: int = 10_000) =
  let loop = getEventLoop()
  var ticks = 0
  while not f.finished and ticks < maxTicks:
    loop.tick()
    inc ticks
  doAssert f.finished

proc handler(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.cps.} =
  discard req
  return newResponse(200, "ok")

let server = server_http3.newHttp3ServerSession(@[0x01'u8], handler)
server.conn.hasPeerMaxPushId = true
server.conn.maxPushIdReceived = 8'u64

# Create pending request context without sending any HEADERS.
let f = server.handleHttp3RequestFrames(4'u64, @[], streamEnded = false)
runLoopUntilFinished(f)
if f.hasError():
  echo "setup_error=", f.getError().msg
  quit(1)

var accepted = false
try:
  discard server.createPushPromise(
    4'u64,
    1'u64,
    @[
      (":method", "GET"),
      (":scheme", "https"),
      (":authority", "example.com"),
      (":path", "/asset.js")
    ]
  )
  accepted = true
except CatchableError:
  discard

echo "accepted_without_request_headers=", accepted
