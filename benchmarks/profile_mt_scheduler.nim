## Sustained work-stealing scheduler workload for sampling profilers.
##
## Unlike the latency benchmark, this keeps the hot path busy long enough for
## eBPF/perf sampling without retaining one timestamp per submitted task.
##
## Run with:
##   nim c -r --mm:arc -d:danger benchmarks/profile_mt_scheduler.nim

when not (compileOption("gc", "atomicArc") or compileOption("gc", "arc") or
          compileOption("gc", "orc")):
  {.error: "profile requires --mm:arc, --mm:orc, or --mm:atomicArc".}

import std/[atomics, monotimes, os, times]
import cps/runtime
import cps/mt/scheduler

const
  ProfileWorkers = 4
  ProfileProducers = 6
  DefaultTasksPerProducer =
    when defined(cpsLongProfile): 20_000_000
    else: 3_000_000
  TasksPerProducer {.intdefine: "cpsProfileTasks".} = DefaultTasksPerProducer
  ProfileQueueCapacity = 4096

type
  ProducerArg = object
    scheduler: Scheduler

var completed: Atomic[int]

proc submitter(arg: ProducerArg) {.thread.} =
  for _ in 0 ..< TasksPerProducer:
    arg.scheduler.schedule(proc() {.closure, gcsafe.} =
      discard completed.fetchAdd(1, moRelaxed)
    )

when isMainModule:
  let rt = newCurrentThreadRuntime()
  let sched = newScheduler(rt, ProfileWorkers, ProfileQueueCapacity)
  let expected = ProfileProducers * TasksPerProducer
  var producers: array[ProfileProducers, Thread[ProducerArg]]
  completed.store(0, moRelaxed)

  let started = getMonoTime()
  for i in 0 ..< ProfileProducers:
    createThread(producers[i], submitter, ProducerArg(scheduler: sched))
  for i in 0 ..< ProfileProducers:
    joinThread(producers[i])
  while completed.load(moAcquire) != expected:
    sleep(1)

  let elapsed = (getMonoTime() - started).inMilliseconds.float / 1_000.0
  echo "tasks: ", expected
  echo "throughput: ", expected.float / elapsed, " tasks/sec"
  shutdownScheduler(sched)
