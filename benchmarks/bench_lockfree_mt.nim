## Lock-free MT runtime benchmarks
##
## Focused coverage for:
## 1) runCps wait/wake path under cross-thread completion
## 2) lock-free scheduler external submission throughput and tail latency
##
## Run with:
##   nim c -r --mm:atomicArc -d:danger benchmarks/bench_lockfree_mt.nim

when not defined(gcAtomicArc) and not defined(useMalloc):
  {.error: "bench_lockfree_mt.nim requires --mm:atomicArc (recommended) or -d:useMalloc.".}

import std/[algorithm, atomics, monotimes, os, times]
import cps/runtime
import cps/eventloop
import cps/mt/scheduler

const
  WaitWakeIters = 1500
  WaitWakeDelayMs = 1

  SchedulerWorkers = 4
  SchedulerProducers = 6
  SchedulerTasksPerProducer = 12000
  SchedulerQueueCap = 2048

type
  CompleteArg = object
    fut: CpsVoidFuture
    delayMs: int

  ProducerArg = object
    scheduler: Scheduler
    tasks: int

var schedulerLatencyIdx: Atomic[int]
var schedulerCompleted: Atomic[int]
var schedulerLatencyBuf: ptr UncheckedArray[int64] = nil
var schedulerLatencyCount: int = 0

proc percentile(sortedNs: openArray[int64], p: float): int64 =
  if sortedNs.len == 0:
    return 0
  let idx = int((sortedNs.len - 1).float * p)
  sortedNs[idx]

proc completeAfterDelay(arg: CompleteArg) {.thread.} =
  sleep(arg.delayMs)
  {.cast(gcsafe).}:
    complete(arg.fut)

proc runWaitWakeBenchmark() =
  echo "[runCps wait/wake]"
  let rt = newCurrentThreadRuntime()
  setCurrentRuntime(rt)

  let start = getMonoTime()
  for _ in 0 ..< WaitWakeIters:
    let fut = newCpsVoidFuture()
    fut.bindFutureRuntime(toHandle(rt))
    var completer: Thread[CompleteArg]
    createThread(completer, completeAfterDelay, CompleteArg(fut: fut, delayMs: WaitWakeDelayMs))
    runCps(fut)
    joinThread(completer)

  let elapsedNs = (getMonoTime() - start).inNanoseconds
  let perIterUs = (elapsedNs.float / WaitWakeIters.float) / 1_000.0
  let opsPerSec = WaitWakeIters.float / (elapsedNs.float / 1_000_000_000.0)

  echo "  iterations: ", WaitWakeIters
  echo "  avg latency: ", perIterUs, " us/op"
  echo "  throughput: ", opsPerSec, " ops/sec"

proc makeLatencyTask(submitAt: MonoTime): SchedulerTask {.inline.} =
  result = proc() {.closure, gcsafe.} =
    let idx = schedulerLatencyIdx.fetchAdd(1, moRelaxed)
    if idx < schedulerLatencyCount and schedulerLatencyBuf != nil:
      let d = (getMonoTime() - submitAt).inNanoseconds
      schedulerLatencyBuf[idx] = d.int64
    discard schedulerCompleted.fetchAdd(1, moRelease)

proc producerMain(arg: ProducerArg) {.thread.} =
  let sched = arg.scheduler
  for _ in 0 ..< arg.tasks:
    let ts = getMonoTime()
    sched.schedule(makeLatencyTask(ts))

proc runSchedulerBenchmark() =
  echo "[scheduler external submit]"

  let rt = newCurrentThreadRuntime()
  let sched = newScheduler(rt, numWorkers = SchedulerWorkers, maxGlobalQueue = SchedulerQueueCap)
  let totalTasks = SchedulerProducers * SchedulerTasksPerProducer

  schedulerLatencyCount = totalTasks
  schedulerLatencyBuf = cast[ptr UncheckedArray[int64]](allocShared0(sizeof(int64) * totalTasks))
  schedulerLatencyIdx.store(0, moRelaxed)
  schedulerCompleted.store(0, moRelaxed)

  try:
    var producers: array[SchedulerProducers, Thread[ProducerArg]]

    let start = getMonoTime()
    for i in 0 ..< SchedulerProducers:
      createThread(producers[i], producerMain, ProducerArg(scheduler: sched, tasks: SchedulerTasksPerProducer))
    for i in 0 ..< SchedulerProducers:
      joinThread(producers[i])

    let drainDeadline = getMonoTime() + initDuration(seconds = 30)
    while schedulerCompleted.load(moAcquire) < totalTasks and getMonoTime() < drainDeadline:
      sleep(1)

    let done = schedulerCompleted.load(moAcquire)
    if done != totalTasks:
      raise newException(ValueError,
        "Scheduler benchmark timeout: expected " & $totalTasks & ", got " & $done)

    let elapsedNs = (getMonoTime() - start).inNanoseconds

    var samples = newSeq[int64](totalTasks)
    for i in 0 ..< totalTasks:
      samples[i] = schedulerLatencyBuf[i]
    sort(samples)

    let throughput = totalTasks.float / (elapsedNs.float / 1_000_000_000.0)
    let p50us = percentile(samples, 0.50).float / 1_000.0
    let p95us = percentile(samples, 0.95).float / 1_000.0
    let p99us = percentile(samples, 0.99).float / 1_000.0

    echo "  tasks: ", totalTasks
    echo "  throughput: ", throughput, " tasks/sec"
    echo "  latency p50: ", p50us, " us"
    echo "  latency p95: ", p95us, " us"
    echo "  latency p99: ", p99us, " us"
  finally:
    if schedulerLatencyBuf != nil:
      deallocShared(schedulerLatencyBuf)
      schedulerLatencyBuf = nil
      schedulerLatencyCount = 0
    shutdownScheduler(sched)


when isMainModule:
  echo "Lock-free MT benchmarks"
  echo "======================="
  runWaitWakeBenchmark()
  runSchedulerBenchmark()
