## Verify that MT scheduler workers own independent event-loop shards.

when not (compileOption("gc", "atomicArc") or compileOption("gc", "arc") or
          compileOption("gc", "orc")):
  {.error: "test requires --mm:arc, --mm:orc, or --mm:atomicArc".}

import std/[atomics, os, monotimes, times]
import cps/mt

const ShardCount = 4

var setupMask: Atomic[int]
var timerMask: Atomic[int]
var affinityFailures: Atomic[int]

proc setupShard(shardId: int) {.gcsafe.} =
  {.cast(gcsafe).}:
    let expectedBit = 1 shl shardId
    if currentIoShardId != shardId or currentWorkerId != shardId or
       not isReactorThread or
       currentEventLoopPtr != cast[pointer](getEventLoop()):
      discard affinityFailures.fetchAdd(1, moAcquireRelease)
    discard setupMask.fetchOr(expectedBit, moAcquireRelease)
    discard getEventLoop().registerTimer(10, proc() =
      if currentIoShardId != shardId or currentWorkerId != shardId:
        discard affinityFailures.fetchAdd(1, moAcquireRelease)
      discard timerMask.fetchOr(expectedBit, moAcquireRelease)
    )

let rt = newMultiThreadRuntime(numWorkers = ShardCount)
setMainRuntime(rt)
setCurrentRuntime(rt)

doAssert rt.ioShardCount() == ShardCount
rt.startMtIoShards(setupShard)
doAssert setupMask.load(moAcquire) == (1 shl ShardCount) - 1

let deadline = getMonoTime() + initDuration(seconds = 3)
while timerMask.load(moAcquire) != (1 shl ShardCount) - 1 and
      getMonoTime() < deadline:
  sleep(1)

doAssert timerMask.load(moAcquire) == (1 shl ShardCount) - 1,
  "every worker-owned reactor should fire its timer"
doAssert affinityFailures.load(moAcquire) == 0,
  "I/O shard callbacks must remain on their owning scheduler workers"

shutdownMtRuntime(rt)
echo "PASS: MT scheduler workers own independent I/O reactor shards"
