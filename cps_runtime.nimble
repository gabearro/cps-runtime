version = "2.0.1"
author = "Gabriel Arroyo"
description = "Continuation-passing-style async runtime, event loop, I/O, concurrency, and multi-threaded scheduler for Nim."
license = "MIT"
srcDir = "src"
skipDirs = @["tests", "examples", "benchmarks", ".github", "scripts"]

requires "nim >= 2.0.0"


task checkDocs, "Verify developer documentation coverage":
  exec "python3 scripts/check_dev_docs.py"

task docs, "Generate the HTML API reference":
  exec "python3 scripts/build_docs.py"

task test, "Run the project test suite":
  exec "nim check src/cps.nim"
  exec "nim c -r tests/core/test_cps_core.nim"
  exec "nim c -r tests/core/test_cps_macro.nim"
  exec "nim c -r tests/core/test_event_loop.nim"
  exec "nim c -r tests/core/test_event_loop_timers.nim"
  exec "nim c -r tests/concurrency/test_channels.nim"
  exec "nim c -r tests/concurrency/test_sync.nim"
  exec "nim c -r tests/io/test_io_buffered.nim"

task testReactorMms, "Test isolated reactors under ARC, ORC, and AtomicARC":
  for mm in ["arc", "orc", "atomicArc"]:
    exec "nim c -r --threads:on --mm:" & mm & " tests/core/test_event_loop.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/core/test_event_loop_timers.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_reactor_pool.nim"

task testMtMms, "Test the work-stealing runtime under ARC, ORC, and AtomicARC":
  for mm in ["arc", "orc", "atomicArc"]:
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_basic.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_blocking.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_concurrent.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_continuation_dispatch.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_cancel_completed_await_lifetime.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_cancel_queued_resume.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_io_shards.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_lazy_blocking_pool.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_local_callback_burst_lifetime.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_local_fast_pinned.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_pinned_overflow_deferred.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_scheduler_fairness.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_shutdown_lifetime.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_yield_affinity.nim"

task testMms, "Run the supported memory-manager matrix":
  for mm in ["arc", "orc", "atomicArc"]:
    exec "nim check --threads:on --mm:" & mm & " src/cps.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/core/test_cps_core.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/core/test_cps_macro.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/core/test_event_loop.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/core/test_event_loop_timers.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/concurrency/test_channels.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/concurrency/test_sync.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/io/test_io_buffered.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_reactor_pool.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_basic.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_blocking.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_concurrent.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_continuation_dispatch.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_cancel_completed_await_lifetime.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_cancel_queued_resume.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_io_shards.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_lazy_blocking_pool.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_local_callback_burst_lifetime.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_local_fast_pinned.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_pinned_overflow_deferred.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_scheduler_fairness.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_shutdown_lifetime.nim"
    exec "nim c -r --threads:on --mm:" & mm & " tests/mt/test_mt_yield_affinity.nim"
  # This deliberately races ordinary ref-counted futures from arbitrary raw
  # OS threads, which is specifically the AtomicARC contract.
  exec "nim c -r --threads:on --mm:atomicArc tests/core/test_lockfree.nim"
