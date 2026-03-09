## CPS Task Groups - Structured Concurrency
##
## Provides a TaskGroup abstraction that manages a collection of tasks
## with configurable error handling policies. Supports fail-fast (cancel
## siblings on first error) and collect-all (gather all errors) modes.
##
## Thread safety: when mtModeEnabled is true at creation time, group
## state is protected by a CAS-based SpinLock (not pthread_mutex) to ensure
## the reactor thread is never blocked by a syscall. Future completions
## and cancelAll() happen outside the lock to avoid deadlocks.

import std/atomics
import ../runtime
import ../eventloop
import ../private/spinlock

proc runtimeMtEnabled(): bool {.inline.} =
  let rt = currentRuntime().runtime
  rt != nil and rt.flavor == rfMultiThread

type
  TaskGroupError* = object of CatchableError
    ## Raised when multiple tasks fail with epCollectAll policy.
    errors*: seq[ref CatchableError]

  ErrorPolicy* = enum
    epFailFast    ## Cancel siblings on first error
    epCollectAll  ## Wait for all, collect errors

  TaskGroup* = ref object
    cancelProcs: seq[proc() {.closure.}]  ## Cancel closures for each task
    errors: seq[ref CatchableError]
    atomicActive: Atomic[int]      ## Lock-free active task count
    completionWaiters: seq[CpsVoidFuture]
    errorPolicy: ErrorPolicy
    atomicCancelled: Atomic[bool]  ## Lock-free cancelled flag
    atomicTaskCount: Atomic[int]   ## Lock-free total task count
    lock: SpinLock                     ## Protects: errors, cancelProcs, completionWaiters
    mtEnabled: bool

proc newTaskGroup*(errorPolicy: ErrorPolicy = epFailFast): TaskGroup =
  ## Create a new task group with the given error policy.
  result = TaskGroup(
    cancelProcs: @[],
    errors: @[],
    completionWaiters: @[],
    errorPolicy: errorPolicy
  )
  result.atomicActive.store(0, moRelaxed)
  result.atomicCancelled.store(false, moRelaxed)
  result.atomicTaskCount.store(0, moRelaxed)
  if runtimeMtEnabled():
    result.mtEnabled = true
    initSpinLock(result.lock)

proc cancelAll*(group: TaskGroup) =
  ## Cancel all running tasks in the group.
  ## Takes a snapshot (under lock if MT) since cancel() fires callbacks
  ## synchronously, which may re-enter group methods.
  var snapshot: seq[proc() {.closure.}]
  if group.mtEnabled:
    acquire(group.lock)
    snapshot = group.cancelProcs
    release(group.lock)
  else:
    snapshot = group.cancelProcs
  for cancelProc in snapshot:
    cancelProc()

proc len*(group: TaskGroup): int {.inline.} =
  ## Number of tasks (total spawned). Lock-free via atomic load.
  group.atomicTaskCount.load(moAcquire)

proc activeCount*(group: TaskGroup): int {.inline.} =
  ## Number of still-running tasks. Lock-free via atomic load.
  group.atomicActive.load(moAcquire)

proc tryComplete(group: TaskGroup) =
  ## Internal: attempt to complete the group's completion future.
  ## Called when activeCount reaches 0 and there are completion waiters.
  ## Fast-path: atomic check on activeCount avoids lock when not ready.
  ## Caller must NOT hold the lock.
  # Fast-path: if still active, skip lock entirely
  if group.atomicActive.load(moAcquire) != 0:
    return

  var waiters: seq[CpsVoidFuture]
  var errors: seq[ref CatchableError]
  var policy: ErrorPolicy

  if group.mtEnabled:
    acquire(group.lock)
    # Re-check under lock (another thread may have beaten us)
    if group.atomicActive.load(moAcquire) != 0 or group.completionWaiters.len == 0:
      release(group.lock)
      return
    waiters = group.completionWaiters
    group.completionWaiters.setLen(0)
    errors = group.errors
    policy = group.errorPolicy
    release(group.lock)
  else:
    if group.completionWaiters.len == 0:
      return
    waiters = group.completionWaiters
    group.completionWaiters.setLen(0)
    errors = group.errors
    policy = group.errorPolicy

  # Complete/fail outside the lock
  if errors.len > 0:
    if policy == epFailFast:
      for waiter in waiters:
        if not waiter.finished:
          fail(waiter, errors[0])
    else:
      for waiter in waiters:
        if not waiter.finished:
          let groupErr = newException(TaskGroupError,
            $errors.len & " task(s) failed")
          groupErr.errors = errors
          fail(waiter, groupErr)
  else:
    for waiter in waiters:
      if not waiter.finished:
        complete(waiter)

proc spawn*(group: TaskGroup, fut: CpsVoidFuture, name: string = "") =
  ## Add a void task to the group. The task starts running immediately.
  discard group.atomicTaskCount.fetchAdd(1, moRelaxed)
  discard group.atomicActive.fetchAdd(1, moAcquireRelease)
  if group.mtEnabled:
    acquire(group.lock)
    group.cancelProcs.add(proc() = cancel(fut))
    release(group.lock)
  else:
    group.cancelProcs.add(proc() = cancel(fut))

  let cb = proc() =
    var shouldCancel = false
    if fut.hasError():
      let err = fut.getError()
      if not (err of CancellationError):
        if group.mtEnabled:
          acquire(group.lock)
          group.errors.add(err)
          release(group.lock)
        else:
          group.errors.add(err)
        if group.errorPolicy == epFailFast:
          var expected = false
          if group.atomicCancelled.compareExchange(expected, true, moAcquireRelease, moRelaxed):
            shouldCancel = true
    # Atomic decrement — only after error handling to avoid race
    discard group.atomicActive.fetchSub(1, moAcquireRelease)

    if shouldCancel:
      group.cancelAll()
    group.tryComplete()

  addCallback(fut, cb)

proc spawn*[T](group: TaskGroup, fut: CpsFuture[T], name: string = ""): Task[T] =
  ## Add a typed task to the group. Returns the Task[T] for reading the result later.
  ## The real typed future's cancel proc is stored so cancelAll() actually
  ## cancels the running typed task.
  let typedTask = spawn(fut, name)

  discard group.atomicTaskCount.fetchAdd(1, moRelaxed)
  discard group.atomicActive.fetchAdd(1, moAcquireRelease)
  if group.mtEnabled:
    acquire(group.lock)
    group.cancelProcs.add(proc() = cancel(fut))
    release(group.lock)
  else:
    group.cancelProcs.add(proc() = cancel(fut))

  let cb = proc() =
    var shouldCancel = false
    if typedTask.hasError():
      let err = typedTask.getError()
      if not (err of CancellationError):
        if group.mtEnabled:
          acquire(group.lock)
          group.errors.add(err)
          release(group.lock)
        else:
          group.errors.add(err)
        if group.errorPolicy == epFailFast:
          var expected = false
          if group.atomicCancelled.compareExchange(expected, true, moAcquireRelease, moRelaxed):
            shouldCancel = true
    # Atomic decrement — only after error handling to avoid race
    discard group.atomicActive.fetchSub(1, moAcquireRelease)

    if shouldCancel:
      group.cancelAll()
    group.tryComplete()

  typedTask.addCallback(cb)
  result = typedTask

proc wait*(group: TaskGroup): CpsVoidFuture =
  ## Wait for all tasks in the group to complete.
  ## With epFailFast: cancels remaining tasks on first error, raises first error.
  ## With epCollectAll: waits for all, raises TaskGroupError with all errors if any failed.
  if group.mtEnabled:
    acquire(group.lock)
    if group.atomicActive.load(moAcquire) == 0:
      let fut = newCpsVoidFuture()
      let errors = group.errors
      let policy = group.errorPolicy
      release(group.lock)
      if errors.len > 0:
        if policy == epFailFast:
          fail(fut, errors[0])
        else:
          let groupErr = newException(TaskGroupError,
            $errors.len & " task(s) failed")
          groupErr.errors = errors
          fail(fut, groupErr)
      else:
        complete(fut)
      return fut
    let waiter = newCpsVoidFuture()
    group.completionWaiters.add(waiter)
    release(group.lock)
    return waiter
  else:
    if group.atomicActive.load(moAcquire) == 0:
      let fut = newCpsVoidFuture()
      if group.errors.len > 0:
        if group.errorPolicy == epFailFast:
          fail(fut, group.errors[0])
        else:
          let groupErr = newException(TaskGroupError,
            $group.errors.len & " task(s) failed")
          groupErr.errors = group.errors
          fail(fut, groupErr)
      else:
        complete(fut)
      return fut
    let waiter = newCpsVoidFuture()
    group.completionWaiters.add(waiter)
    return waiter

proc waitAll*(group: TaskGroup): CpsFuture[seq[ref CatchableError]] =
  ## Wait for all tasks to complete and return collected errors without raising.
  ## Unlike wait(), this never fails the returned future -- errors are returned
  ## as the future's value.
  let resultFut = newCpsFuture[seq[ref CatchableError]]()
  let waiter = group.wait()
  waiter.addCallback(proc() =
    if group.mtEnabled:
      acquire(group.lock)
      let errors = group.errors
      release(group.lock)
      resultFut.complete(errors)
    else:
      resultFut.complete(group.errors)
  )
  return resultFut
