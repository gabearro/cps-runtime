## Verify that the blocking pool consumes no threads until blocking work exists.

when not (compileOption("gc", "atomicArc") or compileOption("gc", "arc") or
          compileOption("gc", "orc")):
  {.error: "test requires --mm:arc, --mm:orc, or --mm:atomicArc".}

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
