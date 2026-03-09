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

  TimeoutState[T] = ref object
    inner: CpsFuture[T]
    result: CpsFuture[T]
    resolved: ResolvedFlag

  TimeoutVoidState = ref object
    inner: CpsVoidFuture
    result: CpsVoidFuture
    resolved: ResolvedFlag

proc withTimeout*[T](fut: CpsFuture[T], ms: int): CpsFuture[T] =
  ## Race a future against a timer. Returns the future's value if it
  ## completes within `ms` milliseconds, or fails with TimeoutError.
  ## On timeout, the inner future is cancelled via cancel().
  let resultFut = newCpsFuture[T]()
  resultFut.pinFutureRuntime()
  let resolved = ResolvedFlag()
  resolved.value.store(false)
  let state = TimeoutState[T](inner: fut, result: resultFut, resolved: resolved)
  var timerHandle: TimerHandle

  proc makeTimerCb(st: TimeoutState[T]): proc() {.closure.} =
    result = proc() =
      var expected = false
      if st.resolved.value.compareExchange(expected, true):
        let inner = st.inner
        let rf = st.result
        # Release captures immediately so cancelled timer pruning does not need
        # to tear down deep closure graphs on the timer heap path.
        st.inner = nil
        st.result = nil
        if inner != nil:
          inner.cancel()
        if rf != nil:
          rf.fail(newException(TimeoutError, "Operation timed out"))

  proc makeFutCb(st: TimeoutState[T], t: TimerHandle): proc() {.closure.} =
    result = proc() =
      var expected = false
      if st.resolved.value.compareExchange(expected, true):
        t.cancel()
        let inner = st.inner
        let rf = st.result
        st.inner = nil
        st.result = nil
        if inner != nil and rf != nil:
          if inner.hasError():
            rf.fail(inner.getError())
          else:
            rf.complete(inner.read())

  let loop = getEventLoop()
  timerHandle = loop.registerTimer(ms, makeTimerCb(state))
  fut.addCallback(makeFutCb(state, timerHandle))
  result = resultFut

proc withTimeout*(fut: CpsVoidFuture, ms: int): CpsVoidFuture =
  ## Race a void future against a timer. Completes if the future
  ## finishes within `ms` milliseconds, or fails with TimeoutError.
  ## On timeout, the inner future is cancelled via cancel().
  let resultFut = newCpsVoidFuture()
  resultFut.pinFutureRuntime()
  let resolved = ResolvedFlag()
  resolved.value.store(false)
  let state = TimeoutVoidState(inner: fut, result: resultFut, resolved: resolved)
  var timerHandle: TimerHandle

  proc makeTimerCb(st: TimeoutVoidState): proc() {.closure.} =
    result = proc() =
      var expected = false
      if st.resolved.value.compareExchange(expected, true):
        let inner = st.inner
        let rf = st.result
        st.inner = nil
        st.result = nil
        if inner != nil:
          inner.cancel()
        if rf != nil:
          rf.fail(newException(TimeoutError, "Operation timed out"))

  proc makeFutCb(st: TimeoutVoidState, t: TimerHandle): proc() {.closure.} =
    result = proc() =
      var expected = false
      if st.resolved.value.compareExchange(expected, true):
        t.cancel()
        let inner = st.inner
        let rf = st.result
        st.inner = nil
        st.result = nil
        if inner != nil and rf != nil:
          if inner.hasError():
            rf.fail(inner.getError())
          else:
            rf.complete()

  let loop = getEventLoop()
  timerHandle = loop.registerTimer(ms, makeTimerCb(state))
  fut.addCallback(makeFutCb(state, timerHandle))
  result = resultFut
