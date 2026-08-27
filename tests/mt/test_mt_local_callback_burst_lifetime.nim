## Stress owner-local future callback bursts through the scheduler's local and
## bounded-ring paths under non-atomic ARC/ORC ownership.

when not (compileOption("gc", "atomicArc") or compileOption("gc", "arc") or
          compileOption("gc", "orc")):
  {.error: "test requires --mm:arc, --mm:orc, or --mm:atomicArc".}

import cps/mt
import cps/transform
import std/[atomics, os]

type GateHolder = ref object
  gate: CpsVoidFuture

proc waitAndDrop(holder: GateHolder): CpsVoidFuture {.cps.} =
  await holder.gate
  holder.gate = nil

const
  BatchSize = 128
  Rounds = 10_000

let rt = newMultiThreadRuntime(numWorkers = 1, maxSchedulerQueue = 256,
                               pinWorkers = false)
let finishedRounds = cast[ptr Atomic[int]](allocShared0(sizeof(Atomic[int])))
finishedRounds[].store(0, moRelaxed)

proc scheduleRound(shardId: int) {.gcsafe.}

proc scheduleRound(shardId: int) {.gcsafe.} =
  {.cast(gcsafe).}:
    var holders = newSeq[GateHolder](BatchSize)
    for i in 0 ..< BatchSize:
      holders[i] = GateHolder(gate: newCpsVoidFuture())
      discard waitAndDrop(holders[i])
    for i in 0 ..< BatchSize:
      holders[i].gate.complete()

    discard rt.pinnedCallbackDispatcher(shardId,
      proc() {.closure, gcsafe.} =
        let completed = finishedRounds[].fetchAdd(1, moAcquireRelease) + 1
        if completed < Rounds:
          scheduleRound(shardId)
      )

rt.startMtIoShards(proc(shardId: int) {.gcsafe.} = scheduleRound(shardId))

var spins = 0
while finishedRounds[].load(moAcquire) < Rounds and spins < 10_000_000:
  sleep(0)
  inc spins
doAssert finishedRounds[].load(moAcquire) == Rounds,
  "owner-local callback burst stress did not finish"

rt.shutdownMtRuntime()
deallocShared(finishedRounds)
echo "PASS: owner-local callback bursts preserve future lifetimes"
