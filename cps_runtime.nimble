version = "1.1.0"
author = "Gabriel Arroyo"
description = "Continuation-passing-style async runtime, event loop, I/O, concurrency, and multi-threaded scheduler for Nim."
license = "MIT"
srcDir = "src"
skipDirs = @["tests", "examples", "benchmarks", ".github", "scripts"]

requires "nim >= 2.0.0"


task test, "Run the project test suite":
  exec "nim check src/cps.nim"
  exec "nim c -r tests/core/test_cps_core.nim"
  exec "nim c -r tests/core/test_cps_macro.nim"
  exec "nim c -r tests/core/test_event_loop.nim"
  exec "nim c -r tests/core/test_event_loop_timers.nim"
  exec "nim c -r tests/concurrency/test_channels.nim"
  exec "nim c -r tests/concurrency/test_sync.nim"
  exec "nim c -r tests/io/test_io_buffered.nim"
