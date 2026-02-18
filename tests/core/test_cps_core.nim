## Tests for CPS runtime core

import cps/runtime

# Test basic continuation lifecycle
block testContinuationLifecycle:
  var stepCount = 0

  proc step2(c: sink Continuation): Continuation {.nimcall.} =
    inc stepCount
    return halt(c)

  proc step1(c: sink Continuation): Continuation {.nimcall.} =
    inc stepCount
    c.fn = step2
    return c

  var cont = Continuation()
  cont.fn = step1
  cont.state = csRunning

  discard run(cont)
  assert stepCount == 2, "Expected 2 steps, got " & $stepCount
  echo "PASS: Continuation lifecycle"

# Test future completion
block testFutureCompletion:
  var fut = newCpsFuture[int]()
  assert not fut.finished
  fut.complete(42)
  assert fut.finished
  assert fut.read() == 42
  echo "PASS: Future completion"

# Test future callbacks
block testFutureCallbacks:
  var callbackFired = false
  var fut = newCpsFuture[string]()
  fut.addCallback(proc() =
    callbackFired = true
  )
  assert not callbackFired
  fut.complete("hello")
  assert callbackFired
  echo "PASS: Future callbacks"

# Test void future
block testVoidFuture:
  var fut = newCpsVoidFuture()
  var done = false
  fut.addCallback(proc() =
    done = true
  )
  fut.complete()
  assert done
  echo "PASS: Void future"

# Test future error propagation
block testFutureError:
  var fut = newCpsFuture[int]()
  var gotError = false
  fut.addCallback(proc() =
    gotError = true
  )
  fut.fail(newException(IOError, "test error"))
  assert gotError
  assert fut.finished
  var caught = false
  try:
    discard fut.read()
  except IOError:
    caught = true
  assert caught
  echo "PASS: Future error propagation"

# Test trampoline
block testTrampoline:
  var counter = 0

  proc stepC(c: sink Continuation): Continuation {.nimcall.} =
    inc counter
    return halt(c)

  proc stepB(c: sink Continuation): Continuation {.nimcall.} =
    inc counter
    c.fn = stepC
    return c

  proc stepA(c: sink Continuation): Continuation {.nimcall.} =
    inc counter
    c.fn = stepB
    return c

  var cont = Continuation()
  cont.fn = stepA
  cont.state = csRunning

  var t = initTrampoline(cont)
  var bounces = 0
  while t.bounce():
    inc bounces
  # stepA -> stepB -> stepC -> halt
  # bounces: stepA runs (returns stepB), stepB runs (returns stepC), stepC runs (returns halted)
  assert counter == 3, "Expected 3 steps, got " & $counter
  echo "PASS: Trampoline"

echo "All CPS core tests passed!"
