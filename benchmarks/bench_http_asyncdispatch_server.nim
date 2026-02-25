## std/asynchttpserver Benchmark
## Minimal "Hello, World!" server using Nim's standard library async HTTP.
## Compile: nim c -d:danger benchmarks/bench_http_asyncdispatch_server.nim

import std/asynchttpserver
import std/asyncdispatch

proc main() {.async.} =
  let server = newAsyncHttpServer()
  proc handler(req: Request) {.async.} =
    await req.respond(Http200, "Hello, World!", newHttpHeaders([("Content-Type", "text/plain")]))
  echo "std/asynchttpserver listening on http://127.0.0.1:8080"
  server.listen(Port(8080), address = "127.0.0.1")
  while true:
    if server.shouldAcceptRequest():
      await server.acceptRequest(handler)
    else:
      await sleepAsync(500)

waitFor main()
