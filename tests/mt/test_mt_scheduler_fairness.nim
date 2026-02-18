## Lock-free scheduler fairness test under heavy external submissions.
##
## Validates that all producer threads make forward progress and that
## no producer is starved while the MPSC inject queue is saturated.
##
## Must be compiled with --mm:atomicArc.

when not defined(gcAtomicArc) and not defined(useMalloc):
  {.error: "test_mt_scheduler_fairness.nim requires --mm:atomicArc (recommended) or -d:useMalloc.".}

import std/[atomics, os, monotimes, times]
import cps/runtime
import cps/mt/scheduler

const
  WorkerCount = 4
  ProducerCount = 8
  TasksPerProducer = 4000
  QueueCap = 1024

type
  SubmitArg = object
    scheduler: Scheduler
    producerIdx: int

var producerCompletions: array[ProducerCount, Atomic[int]]
var totalCompletions: Atomic[int]

proc makeCompletionTask(pid: int): SchedulerTask {.inline.} =
  ## Use a closure factory to avoid loop/local capture aliasing across threads.
  result = proc() {.closure, gcsafe.} =
    discard producerCompletions[pid].fetchAdd(1, moRelaxed)
    discard totalCompletions.fetchAdd(1, moRelaxed)

proc submitterThread(arg: SubmitArg) {.thread.} =
  let sched = arg.scheduler
  let idx = arg.producerIdx
  for _ in 0 ..< TasksPerProducer:
    sched.schedule(makeCompletionTask(idx))

proc testExternalSubmitFairness() =
  echo "Testing lock-free scheduler fairness under external load..."
  let rt = newCurrentThreadRuntime()
  let sched = newScheduler(rt, numWorkers = WorkerCount, maxGlobalQueue = QueueCap)

  for i in 0 ..< ProducerCount:
    producerCompletions[i].store(0, moRelaxed)
  totalCompletions.store(0, moRelaxed)

  let expected = ProducerCount * TasksPerProducer

  try:
    var producers: array[ProducerCount, Thread[SubmitArg]]
    for i in 0 ..< ProducerCount:
      createThread(producers[i], submitterThread, SubmitArg(scheduler: sched, producerIdx: i))

    var sampledAt75 = false
    let submitDeadline = getMonoTime() + initDuration(seconds = 20)
    while getMonoTime() < submitDeadline:
      let done = totalCompletions.load(moAcquire)
      if not sampledAt75 and done >= (expected * 3 div 4):
        sampledAt75 = true
        for i in 0 ..< ProducerCount:
          assert producerCompletions[i].load(moAcquire) > 0,
            "Producer " & $i & " appears starved before 75% completion"
      if done >= expected:
        break
      sleep(1)

    for i in 0 ..< ProducerCount:
      joinThread(producers[i])

    let drainDeadline = getMonoTime() + initDuration(seconds = 20)
    while totalCompletions.load(moAcquire) < expected and getMonoTime() < drainDeadline:
      sleep(1)

    let finalDone = totalCompletions.load(moAcquire)
    assert finalDone == expected,
      "Timed out waiting for scheduler drain: expected " & $expected & ", got " & $finalDone

    for i in 0 ..< ProducerCount:
      let c = producerCompletions[i].load(moAcquire)
      assert c == TasksPerProducer,
        "Producer " & $i & " completion mismatch: expected " & $TasksPerProducer & ", got " & $c

    assert sampledAt75, "Did not reach 75% progress before deadline"
    echo "PASS: lock-free scheduler fairness (" & $expected & " tasks)"
  finally:
    shutdownScheduler(sched)


testExternalSubmitFairness()

echo ""
echo "MT scheduler fairness test passed!"
