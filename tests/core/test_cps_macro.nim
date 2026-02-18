## Tests for CPS macro transformation

import cps/runtime
import cps/transform
import cps/eventloop

# Test 1: Simple CPS proc with no awaits
block testSimpleProc:
  proc simpleAdd(a: int, b: int): CpsFuture[int] {.cps.} =
    return a + b

  let fut = simpleAdd(3, 4)
  assert fut.finished
  assert fut.read() == 7
  echo "PASS: Simple CPS proc (no awaits)"

# Test 2: CPS proc that awaits a pre-completed future
block testAwaitCompleted:
  proc makeValue(): CpsFuture[int] =
    let f = newCpsFuture[int]()
    f.complete(42)
    return f

  proc awaitTest(): CpsFuture[int] {.cps.} =
    let x = await makeValue()
    return x

  let fut = awaitTest()
  assert fut.finished, "Future should be finished"
  assert fut.read() == 42
  echo "PASS: Await pre-completed future"

# Test 3: CPS void proc
block testVoidProc:
  var sideEffect = 0

  proc voidProc(): CpsVoidFuture {.cps.} =
    sideEffect = 99

  let fut = voidProc()
  assert fut.finished
  assert sideEffect == 99
  echo "PASS: Void CPS proc"

# Test 4: Multiple sequential awaits
block testSequentialAwaits:
  proc makeInt(x: int): CpsFuture[int] =
    let f = newCpsFuture[int]()
    f.complete(x)
    return f

  proc sequentialTest(): CpsFuture[int] {.cps.} =
    let a = await makeInt(10)
    let b = await makeInt(20)
    return a + b

  let fut = sequentialTest()
  assert fut.finished
  assert fut.read() == 30
  echo "PASS: Sequential awaits"

# Test 5: Await with event loop (deferred completion)
block testDeferredAwait:
  proc delayedValue(): CpsFuture[string] =
    let f = newCpsFuture[string]()
    # Schedule completion on the event loop
    scheduleCallback(proc() =
      f.complete("delayed!")
    )
    return f

  proc deferredTest(): CpsFuture[string] {.cps.} =
    let val = await delayedValue()
    return val

  let fut = deferredTest()
  assert not fut.finished, "Should not be finished yet"
  let result = runCps(fut)
  assert result == "delayed!"
  echo "PASS: Deferred await with event loop"

# Test 6: CPS proc with local variables
block testLocalVars:
  proc localVarTest(x: int): CpsFuture[int] {.cps.} =
    let doubled = x * 2
    let tripled = x * 3
    return doubled + tripled

  let fut = localVarTest(5)
  assert fut.finished
  assert fut.read() == 25  # 10 + 15
  echo "PASS: Local variables in CPS proc"

# Test 7: Lambda captures env variable correctly
block testLambdaCapture:
  proc lambdaTest(): CpsFuture[int] {.cps.} =
    var x = 10
    let cb = proc(): int = x + 5
    await cpsYield()
    return cb()

  let val = runCps(lambdaTest())
  assert val == 15, "Expected 15, got: " & $val
  echo "PASS: Lambda captures env variable"

# Test 8: Lambda parameter shadows env variable
block testLambdaShadow:
  proc shadowTest(): CpsFuture[int] {.cps.} =
    var x = 100
    let cb = proc(x: int): int = x * 2  # param 'x' shadows env 'x'
    await cpsYield()
    return cb(7)  # should be 14, not 200

  let val = runCps(shadowTest())
  assert val == 14, "Expected 14 (param shadow), got: " & $val
  echo "PASS: Lambda parameter shadows env variable"

# Test 9: Lambda with return doesn't confuse CPS return
block testLambdaReturn:
  proc returnTest(): CpsFuture[int] {.cps.} =
    var x = 5
    let cb = proc(): int =
      if true:
        return x + 1
      return 0
    await cpsYield()
    return cb()

  let val = runCps(returnTest())
  assert val == 6, "Expected 6, got: " & $val
  echo "PASS: Lambda return doesn't confuse CPS return"

# Test 10: Nested lambda with local var shadowing
block testLambdaLocalShadow:
  proc localShadowTest(): CpsFuture[int] {.cps.} =
    var x = 50
    let cb = proc(): int =
      var x = 3  # local shadows env var
      return x
    await cpsYield()
    return cb() + x  # should be 3 + 50 = 53

  let val = runCps(localShadowTest())
  assert val == 53, "Expected 53, got: " & $val
  echo "PASS: Lambda local var shadows env variable"

echo "All CPS macro tests passed!"
