## CPS Tracing Utilities
##
## Provides observability and debugging tools for CPS tasks and the event loop.
## All functionality is gated behind the compile-time flag `-d:cpsTrace`.
## When the flag is not defined, this module exports nothing, ensuring
## zero overhead in production builds.

when defined(cpsTrace):
  import std/monotimes

  type
    TaskState* = enum
      tsRunning    ## Task is currently executing
      tsSuspended  ## Task is waiting for an external event
      tsFinished   ## Task completed successfully
      tsError      ## Task completed with an error

    TaskInfo* = object
      ## Snapshot of information about a CPS task.
      name*: string
      state*: TaskState
      createdAt*: MonoTime

  var traceTaskCount {.threadvar.}: int
    ## Per-thread count of active tasks (for lightweight tracking).

  proc activeTaskCount*(): int =
    ## Returns the per-thread count of active tasks.
    traceTaskCount

  proc incTaskCount*() =
    ## Increment the active task count (called when a task is spawned).
    inc traceTaskCount

  proc decTaskCount*() =
    ## Decrement the active task count (called when a task finishes).
    dec traceTaskCount

  proc logSlowTick*(durationUs: int64, threshold: int64 = 10_000) =
    ## Log a warning if a tick took longer than the threshold (in microseconds).
    ## Default threshold is 10ms (10,000us).
    if durationUs > threshold:
      debugEcho "[cpsTrace] SLOW TICK: " & $durationUs & "us (threshold: " & $threshold & "us)"
