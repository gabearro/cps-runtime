## Reactor-local yields must resume on their owning scheduler worker under
## ARC, ORC, and atomicARC.

when not (compileOption("gc", "atomicArc") or compileOption("gc", "arc") or
          compileOption("gc", "orc")):
  {.error: "test requires --mm:arc, --mm:orc, or --mm:atomicArc".}

import cps/mt
import cps/transform
import std/[atomics, os]

const YieldsPerWorker = 10_000

let rt = newMultiThreadRuntime(numWorkers = 4, maxSchedulerQueue = 256,
                               pinWorkers = false)
let completed = cast[ptr Atomic[int]](allocShared0(sizeof(Atomic[int])))
completed[].store(0, moRelaxed)

proc yieldOnOwner(owner: int): CpsVoidFuture {.cps.} =
  for _ in 0 ..< YieldsPerWorker:
    doAssert currentWorkerId == owner,
      "cpsYield resumed a local continuation on a foreign worker"
    await cpsYield()
  discard completed[].fetchAdd(1, moAcquireRelease)

rt.startMtIoShards(proc(shardId: int) {.gcsafe.} =
  {.cast(gcsafe).}:
    discard yieldOnOwner(shardId)
)

var spins = 0
while completed[].load(moAcquire) < rt.ioShardCount and spins < 10_000_000:
  sleep(0)
  inc spins
doAssert completed[].load(moAcquire) == rt.ioShardCount,
  "reactor-local yield stress did not finish"

rt.shutdownMtRuntime()
deallocShared(completed)
echo "PASS: cpsYield preserves reactor-worker affinity"
