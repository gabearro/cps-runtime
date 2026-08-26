## Verify that the MT runtime executes CPS continuations on scheduler workers,
## leaving the reactor thread dedicated to readiness and timer processing.

when not (compileOption("gc", "atomicArc") or compileOption("gc", "arc") or
          compileOption("gc", "orc")):
  {.error: "test requires --mm:arc, --mm:orc, or --mm:atomicArc".}

import cps/mt
import cps/transform
import std/atomics

let reactorThread = getThreadId()
let loop = initMtRuntime(numWorkers = 2, numBlockingThreads = 1)
var continuationThread: Atomic[int]
continuationThread.store(-1, moRelaxed)

proc recordExecutionThread(): CpsVoidFuture {.cps.} =
  await cpsYield()
  continuationThread.store(getThreadId(), moRelease)

let fut = recordExecutionThread()
var spins = 0
while not fut.finished and spins < 10_000:
  loop.tick()
  inc spins

doAssert fut.finished, "worker-dispatched continuation did not finish"
doAssert not fut.hasError(), "worker-dispatched continuation failed"
let workerThread = continuationThread.load(moAcquire)
doAssert workerThread >= 0, "continuation thread was not recorded"
doAssert workerThread != reactorThread,
  "MT continuation unexpectedly executed on the reactor thread"

loop.shutdownMtRuntime()
echo "PASS: MT continuation executes on a scheduler worker"
