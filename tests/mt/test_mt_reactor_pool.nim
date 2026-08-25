## Verify sharded reactor startup and cross-thread shutdown.

import cps/reactorpool
import cps/runtime
import std/atomics

var startedMask: Atomic[int]
var localFutureMask: Atomic[int]
startedMask.store(0, moRelaxed)
localFutureMask.store(0, moRelaxed)

proc setupShard(shardId: int) {.gcsafe.} =
  discard startedMask.fetchOr(1 shl shardId, moAcquireRelease)
  if newCpsVoidFuture().isLocalFast():
    discard localFutureMask.fetchOr(1 shl shardId, moAcquireRelease)

let pool = startReactorPool(setupShard, numReactors = 4)

doAssert startedMask.load(moAcquire) == 0b1111,
  "all reactor shards should execute their setup callback"
when defined(cpsSharedFuturesOnly):
  doAssert localFutureMask.load(moAcquire) == 0,
    "shared-futures-only builds should retain shared-safe futures"
else:
  doAssert localFutureMask.load(moAcquire) == 0b1111,
    "isolated reactor shards should default to local-fast futures"
pool.shutdown()
echo "PASS: sharded reactor pool starts and shuts down"
