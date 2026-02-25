## CPS HTTPS Server Benchmark
## Minimal "Hello, World!" server with TLS (BoringSSL).
## Compile: nim c -d:danger -d:useBoringSSL benchmarks/bench_https_cps_server.nim

import cps/http/server/dsl
import cps/http/server/server

let handler = router:
  get "/":
    respond 200, "Hello, World!"

serve(handler, port = 8443, host = "127.0.0.1",
      useTls = true,
      certFile = "/tmp/bench_cert.pem",
      keyFile = "/tmp/bench_key.pem")
