## MT local-fast pinned callback benchmarks
##
## Measures worker-pinned local-fast completion overhead compared to
## same-worker local-fast completion.
##
## Run:
##   nim c -r --mm:atomicArc -d:danger benchmarks/bench_mt_local_pinned.nim

when not defined(gcAtomicArc) and not defined(useMalloc):
  {.error: "bench_mt_local_pinned.nim requires --mm:atomicArc (recommended) or -d:useMalloc.".}

import criterion
import cps/mt
import std/[atomics, os]

var cfg = newDefaultConfig()
let loop = initMtRuntime(numWorkers = 2)
let rt = currentRuntime().runtime

proc waitDone(done: var Atomic[int]) {.inline.} =
  while done.load(moAcquire) == 0:
    sleep(0)

benchmark cfg:
  proc benchLocalFastSameWorker() {.measure.} =
    var done: Atomic[int]
    done.store(0, moRelaxed)

    rt.callbackDispatcher(proc() =
      let fut = newLocalCpsVoidFuture()
      fut.addCallback(proc() =
        done.store(1, moRelease)
      )
      complete(fut)
    )

    waitDone(done)

  proc benchLocalFastPinnedHop() {.measure.} =
    var done: Atomic[int]
    done.store(0, moRelaxed)

    rt.callbackDispatcher(proc() =
      let owner = currentWorkerId
      let fut = newLocalCpsVoidFuture()
      fut.addCallback(proc() =
        done.store(1, moRelease)
      )
      let other = if owner == 0: 1 else: 0
      discard rt.pinnedCallbackDispatcher(other, proc() =
        complete(fut)
      )
    )

    waitDone(done)

loop.shutdownMtRuntime()
