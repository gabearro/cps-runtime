## Regression test for cancelling a CPS task after its awaited future completed
## but before the queued resume callback runs.

when not (compileOption("gc", "atomicArc") or compileOption("gc", "arc") or
          compileOption("gc", "orc")):
  {.error: "test requires --mm:arc, --mm:orc, or --mm:atomicArc".}

import cps/mt
import cps/transform
import cps/concurrency/taskgroup
import std/[atomics, os]

type GateHolder = ref object
  gate: CpsVoidFuture

proc waitAndDrop(holder: GateHolder): CpsVoidFuture {.cps.} =
  try:
    await holder.gate
  except CatchableError:
    discard
  holder.gate = nil

const Rounds = 10_000

let rt = newMultiThreadRuntime(numWorkers = 1, maxSchedulerQueue = 64,
                               pinWorkers = false)
let finishedRounds = cast[ptr Atomic[int]](allocShared0(sizeof(Atomic[int])))
finishedRounds[].store(0, moRelaxed)

proc scheduleRound(shardId: int) {.gcsafe.}

proc scheduleRound(shardId: int) {.gcsafe.} =
  {.cast(gcsafe).}:
    let holder = GateHolder(gate: newCpsVoidFuture())
    let group = newTaskGroup(epCollectAll)
    group.spawn(waitAndDrop(holder))

    # Queue the await resume, then cancel its outer CPS future before the
    # owner worker can run that callback. The setup/round closure returns and
    # releases its holder, matching a connection teardown.
    holder.gate.complete()
    group.cancelAll()

    discard rt.pinnedCallbackDispatcher(shardId,
      proc() {.closure, gcsafe.} =
        let completed = finishedRounds[].fetchAdd(1, moAcquireRelease) + 1
        if completed < Rounds:
          scheduleRound(shardId)
      )

rt.startMtIoShards(proc(shardId: int) {.gcsafe.} = scheduleRound(shardId))

var spins = 0
while finishedRounds[].load(moAcquire) < Rounds and spins < 5_000_000:
  sleep(0)
  inc spins
doAssert finishedRounds[].load(moAcquire) == Rounds,
  "cancelled completed-await lifetime stress did not finish"

rt.shutdownMtRuntime()
deallocShared(finishedRounds)
echo "PASS: completed await survives queued-resume cancellation"
