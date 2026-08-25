## Verify that the MT runtime executes CPS continuations on scheduler workers,
## leaving the reactor thread dedicated to readiness and timer processing.

when not defined(gcAtomicArc) and not defined(useMalloc):
  {.error: "test_mt_continuation_dispatch.nim requires --mm:atomicArc or -d:useMalloc".}

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
