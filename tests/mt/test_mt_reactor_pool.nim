## Verify sharded reactor startup and cross-thread shutdown.

import cps/reactorpool
import std/atomics

var startedMask: Atomic[int]
startedMask.store(0, moRelaxed)

proc setupShard(shardId: int) {.gcsafe.} =
  discard startedMask.fetchOr(1 shl shardId, moAcquireRelease)

let pool = startReactorPool(setupShard, numReactors = 4)

doAssert startedMask.load(moAcquire) == 0b1111,
  "all reactor shards should execute their setup callback"
pool.shutdown()
echo "PASS: sharded reactor pool starts and shuts down"
