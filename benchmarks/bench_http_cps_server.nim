## CPS HTTP Server Benchmark
## Minimal "Hello, World!" server using our CPS HTTP stack.
## Compile: nim c -d:danger benchmarks/bench_http_cps_server.nim

import cps/http/server/dsl
import cps/http/server/server

let handler = router:
  get "/":
    respond 200, "Hello, World!"

serve(handler, port = 8080, host = "127.0.0.1")
