## CPS I/O Timeouts
##
## Provides a withTimeout combinator that races any future against a timer.
## The first to complete wins; the loser's callback becomes a no-op.
##
## Note: uses Atomic[bool] for resolved flag (MT-safe via compareExchange)
## and closure factories to avoid cyclic references between futures
## and their callbacks (ORC issue).

import std/atomics
import ../runtime
import ../eventloop
import ./streams

type
  ResolvedFlag = ref object
    value: Atomic[bool]

proc withTimeout*[T](fut: CpsFuture[T], ms: int): CpsFuture[T] =
  ## Race a future against a timer. Returns the future's value if it
  ## completes within `ms` milliseconds, or fails with TimeoutError.
  ## On timeout, the inner future is cancelled via cancel().
  let resultFut = newCpsFuture[T]()
  resultFut.pinFutureRuntime()
  let resolved = ResolvedFlag()
  resolved.value.store(false)
  var timerHandle: TimerHandle

  proc makeTimerCb(f: CpsFuture[T], rf: CpsFuture[T], flag: ResolvedFlag): proc() {.closure.} =
    result = proc() =
      var expected = false
      if flag.value.compareExchange(expected, true):
        f.cancel()
        rf.fail(newException(TimeoutError, "Operation timed out"))

  proc makeFutCb(f: CpsFuture[T], rf: CpsFuture[T], flag: ResolvedFlag,
                 t: TimerHandle): proc() {.closure.} =
    result = proc() =
      var expected = false
      if flag.value.compareExchange(expected, true):
        t.cancel()
        if f.hasError():
          rf.fail(f.getError())
        else:
          rf.complete(f.read())

  let loop = getEventLoop()
  timerHandle = loop.registerTimer(ms, makeTimerCb(fut, resultFut, resolved))
  fut.addCallback(makeFutCb(fut, resultFut, resolved, timerHandle))
  result = resultFut

proc withTimeout*(fut: CpsVoidFuture, ms: int): CpsVoidFuture =
  ## Race a void future against a timer. Completes if the future
  ## finishes within `ms` milliseconds, or fails with TimeoutError.
  ## On timeout, the inner future is cancelled via cancel().
  let resultFut = newCpsVoidFuture()
  resultFut.pinFutureRuntime()
  let resolved = ResolvedFlag()
  resolved.value.store(false)
  var timerHandle: TimerHandle

  proc makeTimerCb(f: CpsVoidFuture, rf: CpsVoidFuture, flag: ResolvedFlag): proc() {.closure.} =
    result = proc() =
      var expected = false
      if flag.value.compareExchange(expected, true):
        f.cancel()
        rf.fail(newException(TimeoutError, "Operation timed out"))

  proc makeFutCb(f: CpsVoidFuture, rf: CpsVoidFuture, flag: ResolvedFlag,
                 t: TimerHandle): proc() {.closure.} =
    result = proc() =
      var expected = false
      if flag.value.compareExchange(expected, true):
        t.cancel()
        if f.hasError():
          rf.fail(f.getError())
        else:
          rf.complete()

  let loop = getEventLoop()
  timerHandle = loop.registerTimer(ms, makeTimerCb(fut, resultFut, resolved))
  fut.addCallback(makeFutCb(fut, resultFut, resolved, timerHandle))
  result = resultFut
