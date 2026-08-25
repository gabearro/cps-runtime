## Verify that the blocking pool consumes no threads until blocking work exists.

when not defined(gcAtomicArc) and not defined(useMalloc):
  {.error: "test_mt_lazy_blocking_pool.nim requires --mm:atomicArc or -d:useMalloc".}

import cps/mt

let loop = initMtRuntime(numWorkers = 2, numBlockingThreads = 1)
let rt = currentRuntime().runtime
doAssert rt.blockingPoolPtr == nil,
  "blocking pool should not be allocated during MT runtime initialization"

let fut = spawnBlocking(proc(): int {.gcsafe.} = 42)
while not fut.finished:
  loop.tick()

doAssert fut.read() == 42
doAssert rt.blockingPoolPtr != nil,
  "first blocking submission should initialize the blocking pool"

loop.shutdownMtRuntime()
echo "PASS: MT blocking pool initializes lazily"
