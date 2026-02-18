## Tests for CPS try/except with await support
##
## Verifies that await inside try/except blocks works correctly:
## - Typed exception catching
## - `except Type as e:` with variable binding
## - Multiple awaits inside try
## - Bare except catch-all
## - Code after try/except continues normally
## - Synchronous exceptions inside try body (before await)

import cps/runtime
import cps/eventloop
import cps/transform

# Helper: a CPS proc that always fails
proc failWith(msg: string): CpsVoidFuture {.cps.} =
  raise newException(ValueError, msg)

# Helper: a CPS proc that returns a value or fails
proc mayFail(x: int, shouldFail: bool): CpsFuture[int] {.cps.} =
  await cpsYield()
  if shouldFail:
    raise newException(ValueError, "fail: " & $x)
  return x * 10

# ============================================================
# Test 1: Await inside try/except catches typed exception
# ============================================================

block testTryExceptTyped:
  var caught = ""

  proc main(): CpsVoidFuture {.cps.} =
    try:
      await failWith("boom")
    except ValueError:
      caught = "caught ValueError"

  caught = ""
  runCps(main())
  assert caught == "caught ValueError", "Expected 'caught ValueError', got: " & caught
  echo "PASS: Await inside try/except catches typed exception"

# ============================================================
# Test 2: Except with `as` variable binding
# ============================================================

block testTryExceptAs:
  var errorMsg = ""

  proc main(): CpsVoidFuture {.cps.} =
    try:
      await failWith("details here")
    except ValueError as e:
      errorMsg = e.msg

  errorMsg = ""
  runCps(main())
  assert errorMsg == "details here", "Expected 'details here', got: " & errorMsg
  echo "PASS: Except with 'as' variable binding"

# ============================================================
# Test 3: Successful await inside try - no exception
# ============================================================

block testTryExceptSuccess:
  proc main(): CpsFuture[int] {.cps.} =
    var res = 0
    try:
      let val = await mayFail(5, false)
      res = val
    except ValueError:
      res = -1
    return res

  let val = runCps(main())
  assert val == 50, "Expected 50, got: " & $val
  echo "PASS: Successful await inside try"

# ============================================================
# Test 4: Code after try/except continues normally
# ============================================================

block testAfterTryExcept:
  var log: seq[string]

  proc main(): CpsVoidFuture {.cps.} =
    log.add "before"
    try:
      await failWith("err")
    except ValueError:
      log.add "caught"
    log.add "after"

  log = @[]
  runCps(main())
  assert log == @["before", "caught", "after"],
    "Expected [before, caught, after], got: " & $log
  echo "PASS: Code after try/except continues normally"

# ============================================================
# Test 5: Multiple awaits inside try
# ============================================================

block testMultipleAwaitsInTry:
  proc main(): CpsFuture[int] {.cps.} =
    var res = 0
    try:
      let a = await mayFail(2, false)
      let b = await mayFail(3, false)
      res = a + b
    except ValueError:
      res = -1
    return res

  let val = runCps(main())
  assert val == 50, "Expected 50 (20+30), got: " & $val
  echo "PASS: Multiple awaits inside try"

# ============================================================
# Test 6: Second await fails in try
# ============================================================

block testSecondAwaitFails:
  var caught = ""

  proc main(): CpsVoidFuture {.cps.} =
    try:
      let a = await mayFail(1, false)
      let b = await mayFail(2, true)  # This one fails
      discard a
      discard b
    except ValueError as e:
      caught = e.msg

  caught = ""
  runCps(main())
  assert caught == "fail: 2", "Expected 'fail: 2', got: " & caught
  echo "PASS: Second await fails in try"

# ============================================================
# Test 7: Bare except catch-all
# ============================================================

block testBareExcept:
  var caught = false

  proc main(): CpsVoidFuture {.cps.} =
    try:
      await failWith("something")
    except:
      caught = true

  caught = false
  runCps(main())
  assert caught, "Expected bare except to catch"
  echo "PASS: Bare except catch-all"

# ============================================================
# Test 8: Unmatched exception propagates to future
# ============================================================

block testUnmatchedException:
  proc failWithIO(): CpsVoidFuture {.cps.} =
    raise newException(IOError, "io error")

  proc main(): CpsVoidFuture {.cps.} =
    try:
      await failWithIO()
    except ValueError:
      discard  # Only catches ValueError, not IOError

  let fut = main()
  runCps(fut)
  assert fut.hasError, "Expected future to have error for unmatched exception"
  echo "PASS: Unmatched exception propagates to future"

# ============================================================
# Test 9: Return inside except handler
# ============================================================

block testReturnInsideExcept:
  proc errorHandler(shouldFail: bool): CpsFuture[string] {.cps.} =
    try:
      let val = await mayFail(42, shouldFail)
      return "ok: " & $val
    except ValueError as e:
      return "caught: " & e.msg

  # Test the error path: return inside except
  let errResult = runCps(errorHandler(true))
  assert errResult == "caught: fail: 42", "Expected 'caught: fail: 42', got: " & errResult

  # Test the success path: return inside try
  let okResult = runCps(errorHandler(false))
  assert okResult == "ok: 420", "Expected 'ok: 420', got: " & okResult
  echo "PASS: Return inside except handler"

# ============================================================
# Test 10: Failed future in try/except preserves handler value
# ============================================================

block testFailedFuturePreservesHandler:
  proc failingFuture(): CpsFuture[int] {.cps.} =
    raise newException(ValueError, "future failed")

  proc main(): CpsFuture[string] {.cps.} =
    var msg = "not set"
    try:
      let val = await failingFuture()
      msg = "unexpected: got " & $val
    except ValueError as e:
      msg = "caught: " & e.msg
    return msg

  let result = runCps(main())
  assert result == "caught: future failed",
    "Expected 'caught: future failed', got: " & result
  echo "PASS: Failed future in try/except preserves handler value"

# ============================================================
# Test 11: Await inside except handler body
# ============================================================

block testAwaitInExceptHandler:
  proc formatError(msg: string): CpsFuture[string] {.cps.} =
    return "formatted: " & msg

  proc failingFuture(): CpsFuture[int] {.cps.} =
    raise newException(ValueError, "something broke")

  proc main(): CpsFuture[string] {.cps.} =
    var msg = "not set"
    try:
      let val = await failingFuture()
      msg = "unexpected: got " & $val
    except ValueError as e:
      let formatted = await formatError(e.msg)
      msg = formatted
    return msg

  let result = runCps(main())
  assert result == "formatted: something broke",
    "Expected 'formatted: something broke', got: " & result
  echo "PASS: Await inside except handler body"

# ============================================================
# Test 12: Multiple awaits inside except handler body
# ============================================================

block testMultipleAwaitsInExceptHandler:
  proc asyncPrefix(): CpsFuture[string] {.cps.} =
    return "ERROR"

  proc asyncSuffix(): CpsFuture[string] {.cps.} =
    return "!!!"

  proc failingFuture(): CpsFuture[int] {.cps.} =
    raise newException(ValueError, "fail")

  proc main(): CpsFuture[string] {.cps.} =
    try:
      let val = await failingFuture()
      return "unexpected: " & $val
    except ValueError as e:
      let prefix = await asyncPrefix()
      let suffix = await asyncSuffix()
      return prefix & ": " & e.msg & suffix

  let result = runCps(main())
  assert result == "ERROR: fail!!!",
    "Expected 'ERROR: fail!!!', got: " & result
  echo "PASS: Multiple awaits inside except handler body"

# ============================================================
# Test 13: Await in except handler with bare except (no type)
# ============================================================

block testAwaitInBareExceptHandler:
  proc asyncLog(msg: string): CpsFuture[string] {.cps.} =
    return "logged: " & msg

  proc failingFuture(): CpsFuture[int] {.cps.} =
    raise newException(IOError, "disk error")

  proc main(): CpsFuture[string] {.cps.} =
    try:
      let val = await failingFuture()
      return "unexpected: " & $val
    except CatchableError:
      let msg = await asyncLog("caught something")
      return msg

  let result = runCps(main())
  assert result == "logged: caught something",
    "Expected 'logged: caught something', got: " & result
  echo "PASS: Await in except handler with bare except"

# ============================================================
# Test 14: Await as call argument (auto-extracted)
# ============================================================

block testAwaitAsCallArgument:
  proc getValue(): CpsFuture[int] {.cps.} =
    return 42

  proc main(): CpsFuture[seq[int]] {.cps.} =
    var results: seq[int] = @[]
    results.add(await getValue())
    results.add(await getValue())
    return results

  let result = runCps(main())
  assert result == @[42, 42],
    "Expected @[42, 42], got: " & $result
  echo "PASS: Await as call argument (auto-extracted)"

# ============================================================
# Test 15: Except handler without 'as' variable but with await
# ============================================================

block testExceptNoAsVarWithAwait:
  proc asyncRecover(): CpsFuture[int] {.cps.} =
    return -1

  proc failingFuture(): CpsFuture[int] {.cps.} =
    raise newException(ValueError, "nope")

  proc main(): CpsFuture[int] {.cps.} =
    try:
      return await failingFuture()
    except ValueError:
      let recovered = await asyncRecover()
      return recovered

  let result = runCps(main())
  assert result == -1,
    "Expected -1, got: " & $result
  echo "PASS: Except handler without 'as' variable but with await"

echo ""
echo "All try/except tests passed!"
