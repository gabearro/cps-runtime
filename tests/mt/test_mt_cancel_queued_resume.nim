## Regression test for cancellation racing an already queued await resume.
##
## A completed inner future queues the suspended continuation on its owner
## worker. Cancelling the outer future before that callback runs must prevent
## the stale continuation from resuming or touching its released task graph.

when not (compileOption("gc", "atomicArc") or compileOption("gc", "arc") or
          compileOption("gc", "orc")):
  {.error: "test requires --mm:arc, --mm:orc, or --mm:atomicArc".}

import cps/mt
import cps/transform
import std/atomics

const Rounds = 10_000

let loop = initMtRuntime(numWorkers = 2)

proc waitAndMark(gate: CpsVoidFuture,
                 resumed: ptr Atomic[int]): CpsVoidFuture {.cps.} =
  await gate
  resumed[].store(1, moRelease)

proc stressQueuedResumeCancellation(): CpsVoidFuture {.cps.} =
  var resumed: Atomic[int]
  for _ in 0 ..< Rounds:
    resumed.store(0, moRelaxed)
    let gate = newCpsVoidFuture()
    let outer = waitAndMark(gate, addr resumed)

    # Both operations occur in one worker turn. Completing gate queues the
    # resume callback; cancelling outer makes that queued callback stale.
    gate.complete()
    outer.cancel()
    await cpsYield()

    doAssert outer.isCancelled()
    doAssert resumed.load(moAcquire) == 0,
      "cancelled CPS continuation resumed after its await callback was queued"

runCps(stressQueuedResumeCancellation())
loop.shutdownMtRuntime()

echo "PASS: queued await callbacks do not resume cancelled CPS futures"
