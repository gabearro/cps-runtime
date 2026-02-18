# Package
version       = "0.1.0"
author        = "Gabriel"
description   = "Continuation-Passing Style runtime for async Nim"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 2.0.0"
requires "zippy >= 0.10.0"

task test, "Run tests":
  exec "nim c -r tests/core/test_cps_core.nim"
  exec "nim c -r tests/core/test_cps_macro.nim"
  exec "nim c -r tests/core/test_event_loop.nim"
  exec "nim c -r tests/http/test_https_client.nim"
  exec "nim c -r tests/http/test_compression.nim"
  exec "nim c -r tests/http/test_http_compression.nim"
  exec "nim c -r tests/http/test_ws_compression.nim"
  exec "nim c -r tests/http/test_sse_compression.nim"
