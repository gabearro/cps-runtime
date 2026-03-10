## CPS I/O Timeouts
##
## Provides a withTimeout combinator that races any future against a timer.
## The first to complete wins; the loser's callback becomes a no-op.
## Uses compareExchange on an atomic flag for MT-safe once semantics.
## Closure factories avoid cyclic references (ORC issue).

import std/atomics
import ../runtime
import ../eventloop
import ./streams

type
  TimeoutState[T] = ref object
    inner: CpsFuture[T]
    result: CpsFuture[T]
    resolved: Atomic[bool]

  TimeoutVoidState = ref object
    inner: CpsVoidFuture
    result: CpsVoidFuture
    resolved: Atomic[bool]

proc withTimeout*[T](fut: CpsFuture[T], ms: int): CpsFuture[T] =
  ## Race a future against a timer. Returns the future's value if it
  ## completes within `ms` milliseconds, or fails with TimeoutError.
  ## On timeout, the inner future is cancelled.
  let resultFut = newCpsFuture[T]()
  resultFut.pinFutureRuntime()
  let st = TimeoutState[T](inner: fut, result: resultFut)

  proc onTimer(st: TimeoutState[T]): proc() {.closure.} =
    result = proc() =
      var expected = false
      if st.resolved.compareExchange(expected, true):
        let inner = st.inner; st.inner = nil
        let rf = st.result; st.result = nil
        inner.cancel()
        rf.fail(newException(TimeoutError, "Operation timed out"))

  proc onComplete(st: TimeoutState[T], timer: TimerHandle): proc() {.closure.} =
    result = proc() =
      var expected = false
      if st.resolved.compareExchange(expected, true):
        timer.cancel()
        let inner = st.inner; st.inner = nil
        let rf = st.result; st.result = nil
        if inner.hasError():
          rf.fail(inner.getError())
        else:
          rf.complete(inner.read())

  let timer = getEventLoop().registerTimer(ms, onTimer(st))
  fut.addCallback(onComplete(st, timer))
  resultFut

proc withTimeout*(fut: CpsVoidFuture, ms: int): CpsVoidFuture =
  ## Race a void future against a timer. Completes if the future
  ## finishes within `ms` milliseconds, or fails with TimeoutError.
  ## On timeout, the inner future is cancelled.
  let resultFut = newCpsVoidFuture()
  resultFut.pinFutureRuntime()
  let st = TimeoutVoidState(inner: fut, result: resultFut)

  proc onTimer(st: TimeoutVoidState): proc() {.closure.} =
    result = proc() =
      var expected = false
      if st.resolved.compareExchange(expected, true):
        let inner = st.inner; st.inner = nil
        let rf = st.result; st.result = nil
        inner.cancel()
        rf.fail(newException(TimeoutError, "Operation timed out"))

  proc onComplete(st: TimeoutVoidState, timer: TimerHandle): proc() {.closure.} =
    result = proc() =
      var expected = false
      if st.resolved.compareExchange(expected, true):
        timer.cancel()
        let inner = st.inner; st.inner = nil
        let rf = st.result; st.result = nil
        if inner.hasError():
          rf.fail(inner.getError())
        else:
          rf.complete()

  let timer = getEventLoop().registerTimer(ms, onTimer(st))
  fut.addCallback(onComplete(st, timer))
  resultFut
