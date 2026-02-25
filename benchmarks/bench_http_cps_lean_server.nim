## CPS HTTP Lean Server Benchmark
## Uses the full HTTP stack (parsing, routing, response) but with a lean
## accept loop: no TaskGroup, no getPeerAddr, just discard the connection future.
## Compile: nim c -d:danger benchmarks/bench_http_cps_lean_server.nim

import std/[nativesockets, net, os]
from std/posix import TCP_NODELAY
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/tcp
import cps/io/streams
import cps/http/server/dsl
import cps/http/server/http1

let handler = router:
  get "/":
    respond 200, "Hello, World!"

proc acceptLoop(listener: TcpListener, handler: HttpHandler): CpsVoidFuture {.cps.} =
  let config = HttpServerConfig()
  while true:
    let client = await listener.accept()
    client.fd.setSockOptInt(cint(IPPROTO_TCP), TCP_NODELAY, 1)
    discard handleHttp1Connection(client.AsyncStream, config, handler)

proc main() =
  let listener = tcpListen("127.0.0.1", 8080)
  echo "CPS lean HTTP server listening on http://127.0.0.1:8080"
  discard acceptLoop(listener, handler)
  let loop = getEventLoop()
  while true:
    loop.tick()

main()
