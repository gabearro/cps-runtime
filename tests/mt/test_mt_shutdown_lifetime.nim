## Repeated multithreaded-runtime shutdown ownership regression.
##
## Reactor loops and selector callbacks must be created and destroyed by their
## owning worker under ARC and ORC. Repeating concurrent completion followed by
## immediate shutdown catches allocator corruption that a single run can miss.

when not (compileOption("gc", "atomicArc") or compileOption("gc", "arc") or
          compileOption("gc", "orc")):
  {.error: "test requires --mm:arc, --mm:orc, or --mm:atomicArc".}

import cps/mt
import cps/transform
import std/atomics

const ShutdownRounds = 32

for round in 0 ..< ShutdownRounds:
  let loop = initMtRuntime(numWorkers = 2)
  var callbackHits: Atomic[int]
  callbackHits.store(0, moRelaxed)

  proc exerciseShutdown(): CpsVoidFuture {.cps.} =
    let gate = newCpsVoidFuture()
    gate.ensureShared()
    for callbackIdx in 0 ..< 16:
      gate.addCallback(proc() =
        discard callbackIdx
        discard callbackHits.fetchAdd(1, moAcquireRelease)
      )
    let completer = spawnBlocking(proc() {.gcsafe.} =
      {.cast(gcsafe).}:
        gate.complete()
    )
    await gate
    await completer
    while callbackHits.load(moAcquire) != 16:
      await cpsYield()

  runCps(exerciseShutdown())
  doAssert callbackHits.load(moAcquire) == 16
  loop.shutdownMtRuntime()

echo "PASS: repeated MT runtime shutdown preserves worker-owned lifetimes"
