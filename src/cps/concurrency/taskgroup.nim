## CPS Task Groups - Structured Concurrency
##
## Provides a TaskGroup abstraction that manages a collection of tasks
## with configurable error handling policies. Supports fail-fast (cancel
## siblings on first error) and collect-all (gather all errors) modes.
##
## Thread safety: when the MT runtime is active at creation time, group
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

template withLock(lock: var SpinLock, mt: bool, body: untyped) =
  ## Execute body with conditional spinlock protection.
  ## When mt is true, acquires the lock and guarantees release via
  ## try/finally (exception-safe). When false, executes body directly.
  if mt:
    withSpinLock(lock):
      body
  else:
    body

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
    lock: SpinLock                 ## Protects: errors, cancelProcs, completionWaiters
    mtEnabled: bool

proc newTaskGroup*(errorPolicy: ErrorPolicy = epFailFast): TaskGroup =
  ## Create a new task group with the given error policy.
  result = TaskGroup(errorPolicy: errorPolicy)
  result.atomicActive.store(0, moRelaxed)
  result.atomicCancelled.store(false, moRelaxed)
  result.atomicTaskCount.store(0, moRelaxed)
  if runtimeMtEnabled():
    result.mtEnabled = true
    initSpinLock(result.lock)

proc cancelAll*(group: TaskGroup) =
  ## Cancel all running tasks in the group.
  ## Takes a snapshot under lock since cancel() fires callbacks
  ## synchronously, which may re-enter group methods.
  var snapshot: seq[proc() {.closure.}]
  withLock(group.lock, group.mtEnabled):
    snapshot = group.cancelProcs
  for cancelProc in snapshot:
    cancelProc()

proc len*(group: TaskGroup): int {.inline.} =
  ## Number of tasks (total spawned). Lock-free via atomic load.
  group.atomicTaskCount.load(moAcquire)

proc activeCount*(group: TaskGroup): int {.inline.} =
  ## Number of still-running tasks. Lock-free via atomic load.
  group.atomicActive.load(moAcquire)

proc resolveWaiter(fut: CpsVoidFuture,
                   errors: seq[ref CatchableError],
                   policy: ErrorPolicy) =
  ## Complete or fail a single waiter based on the group's error state.
  if fut.finished: return
  if errors.len == 0:
    complete(fut)
  elif policy == epFailFast:
    fail(fut, errors[0])
  else:
    let groupErr = newException(TaskGroupError,
      $errors.len & " task(s) failed")
    groupErr.errors = errors
    fail(fut, groupErr)

proc tryComplete(group: TaskGroup) =
  ## Internal: attempt to complete the group's completion waiters.
  ## Called when activeCount reaches 0.
  ## Fast-path: atomic check avoids the lock when not ready.
  if group.atomicActive.load(moAcquire) != 0:
    return

  var waiters: seq[CpsVoidFuture]
  var errors: seq[ref CatchableError]
  var policy: ErrorPolicy

  withLock(group.lock, group.mtEnabled):
    # Re-check under lock (another thread may have beaten us)
    if group.atomicActive.load(moAcquire) != 0 or group.completionWaiters.len == 0:
      return
    waiters = group.completionWaiters
    group.completionWaiters.setLen(0)
    errors = group.errors
    policy = group.errorPolicy

  # Resolve outside the lock — callbacks may re-enter group methods
  if errors.len > 0:
    # Allocate the error once, share across all waiters
    let err =
      if policy == epFailFast: errors[0]
      else:
        let ge = newException(TaskGroupError, $errors.len & " task(s) failed")
        ge.errors = errors
        ge
    for waiter in waiters:
      if not waiter.finished:
        fail(waiter, err)
  else:
    for waiter in waiters:
      if not waiter.finished:
        complete(waiter)

template onTaskComplete(group: TaskGroup, futExpr: untyped) =
  ## Register a completion callback that handles error collection,
  ## fail-fast cancellation, active count tracking, and group completion.
  let tracked = futExpr
  let cb = proc() =
    var shouldCancel = false
    if tracked.hasError():
      let err = tracked.getError()
      if not (err of CancellationError):
        withLock(group.lock, group.mtEnabled):
          group.errors.add(err)
        if group.errorPolicy == epFailFast:
          var expected = false
          if group.atomicCancelled.compareExchange(expected, true,
              moAcquireRelease, moRelaxed):
            shouldCancel = true
    discard group.atomicActive.fetchSub(1, moAcquireRelease)
    if shouldCancel:
      group.cancelAll()
    group.tryComplete()
  tracked.addCallback(cb)

proc spawn*(group: TaskGroup, fut: CpsVoidFuture, name: string = "") =
  ## Add a void task to the group. The task starts running immediately.
  discard group.atomicTaskCount.fetchAdd(1, moRelaxed)
  discard group.atomicActive.fetchAdd(1, moAcquireRelease)
  withLock(group.lock, group.mtEnabled):
    group.cancelProcs.add(proc() = cancel(fut))
  onTaskComplete(group, fut)

proc spawn*[T](group: TaskGroup, fut: CpsFuture[T], name: string = ""): Task[T] =
  ## Add a typed task to the group. Returns the Task[T] for reading the result later.
  result = spawn(fut, name)
  discard group.atomicTaskCount.fetchAdd(1, moRelaxed)
  discard group.atomicActive.fetchAdd(1, moAcquireRelease)
  withLock(group.lock, group.mtEnabled):
    group.cancelProcs.add(proc() = cancel(fut))
  onTaskComplete(group, result)

proc wait*(group: TaskGroup): CpsVoidFuture =
  ## Wait for all tasks in the group to complete.
  ## With epFailFast: cancels remaining on first error, raises first error.
  ## With epCollectAll: waits for all, raises TaskGroupError with all errors.
  var errors: seq[ref CatchableError]
  var policy: ErrorPolicy

  withLock(group.lock, group.mtEnabled):
    if group.atomicActive.load(moAcquire) > 0:
      let waiter = newCpsVoidFuture()
      group.completionWaiters.add(waiter)
      return waiter
    errors = group.errors
    policy = group.errorPolicy

  let fut = newCpsVoidFuture()
  resolveWaiter(fut, errors, policy)
  return fut

proc waitAll*(group: TaskGroup): CpsFuture[seq[ref CatchableError]] =
  ## Wait for all tasks to complete and return collected errors without raising.
  ## Unlike wait(), this never fails the returned future — errors are returned
  ## as the future's value.
  let resultFut = newCpsFuture[seq[ref CatchableError]]()
  let waiter = group.wait()
  waiter.addCallback(proc() =
    var errors: seq[ref CatchableError]
    withLock(group.lock, group.mtEnabled):
      errors = group.errors
    resultFut.complete(errors)
  )
  return resultFut
