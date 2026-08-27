## Regression test for owner-pinned callback overflow.
##
## Completing a future must never invoke its await callback inline while the
## future is still draining callbacks. In particular, filling both owner-local
## queues used to make the overflow fallback recurse into the future destructor.

when not (compileOption("gc", "atomicArc") or compileOption("gc", "arc") or
          compileOption("gc", "orc")):
  {.error: "test requires --mm:arc, --mm:orc, or --mm:atomicArc".}

import cps/mt
import cps/transform
import std/[atomics, os]

type GateHolder = ref object
  gate: CpsVoidFuture

proc waitDropAndMark(holder: GateHolder,
                     resumed: ptr Atomic[bool]): CpsVoidFuture {.cps.} =
  await holder.gate
  holder.gate = nil
  resumed[].store(true, moRelease)

let rt = newMultiThreadRuntime(numWorkers = 1, maxSchedulerQueue = 2,
                               pinWorkers = false)
let resumed = cast[ptr Atomic[bool]](allocShared0(sizeof(Atomic[bool])))
resumed[].store(false, moRelaxed)

rt.startMtIoShards(proc(shardId: int) {.gcsafe.} =
  {.cast(gcsafe).}:
    let holder = GateHolder(gate: newCpsVoidFuture())
    discard waitDropAndMark(holder, resumed)

    # Fill the 16-entry owner-local queue and two-entry bounded injection ring.
    # The awaited continuation is therefore forced through the rare overflow.
    for _ in 0 ..< 18:
      doAssert rt.pinnedCallbackDispatcher(shardId,
        proc() {.closure, gcsafe.} = discard)

    holder.gate.complete()
    doAssert holder.gate != nil,
      "pinned overflow resumed an await callback inline during completion"
)

var spins = 0
while not resumed[].load(moAcquire) and spins < 100_000:
  sleep(0)
  inc spins
doAssert resumed[].load(moAcquire), "deferred overflow callback did not run"

rt.shutdownMtRuntime()
deallocShared(resumed)
echo "PASS: owner-pinned overflow remains deferred"
