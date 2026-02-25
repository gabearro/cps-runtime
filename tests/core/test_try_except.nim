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
import std/strutils

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

# ============================================================
# Test 16: try-expression binding with await in except branch
# ============================================================

block testTryExprBindingAwaitInExceptBranch:
  proc mayFailValue(shouldFail: bool): CpsFuture[int] {.cps.} =
    if shouldFail:
      raise newException(ValueError, "boom")
    return 41

  proc asyncCleanup(): CpsVoidFuture {.cps.} =
    await cpsYield()

  proc main(shouldFail: bool): CpsFuture[int] {.cps.} =
    let value =
      try:
        await mayFailValue(shouldFail)
      except ValueError:
        await asyncCleanup()
        return -1
    return value + 1

  let okResult = runCps(main(false))
  assert okResult == 42, "Expected 42, got: " & $okResult
  let errResult = runCps(main(true))
  assert errResult == -1, "Expected -1, got: " & $errResult
  echo "PASS: try-expression binding with await in except branch"

# ============================================================
# Test 17: While-loop back-edge inside try/except with awaits
# ============================================================

block testWhileBackEdgeInTryExcept:
  proc stepForward(x: int): CpsFuture[int] {.cps.} =
    await cpsYield()
    return x + 1

  proc main(): CpsFuture[int] {.cps.} =
    var i = 0
    try:
      while i < 3:
        let optionalBranch = i < 0
        if optionalBranch:
          await cpsYield()
        let nextVal = await stepForward(i)
        i = nextVal
    except CatchableError:
      return -1
    return i

  let result = runCps(main())
  assert result == 3, "Expected 3 after three loop iterations, got: " & $result
  echo "PASS: while-loop back-edge inside try/except with awaits"

# ============================================================
# Test 18: `except ... as e` after awaited loop in try body
# ============================================================

block testExceptAsAfterAwaitedLoop:
  proc main(): CpsFuture[string] {.cps.} =
    var i = 0
    try:
      while i < 2:
        await cpsYield()
        inc i
      raise newException(IOError, "loop boom")
    except CatchableError as e:
      let msg = e.msg.toLowerAscii
      return msg

  let result = runCps(main())
  assert result == "loop boom", "Expected 'loop boom', got: " & result
  echo "PASS: except-as binding works after awaited loop in try body"

# ============================================================
# Test 19: Sync for-loop locals after await compile and run
# ============================================================

block testSyncForLocalsAfterAwait:
  proc main(): CpsFuture[uint32] {.cps.} =
    await cpsYield()
    let settings = @[
      (1'u16, 11'u32),
      (5'u16, 99'u32)
    ]
    var selected = 0'u32
    for i in 0 ..< settings.len:
      let setting = settings[i]
      let id = setting[0]
      let value = setting[1]
      if id == 5'u16:
        selected = value
    return selected

  let result = runCps(main())
  assert result == 99'u32, "Expected 99, got: " & $result
  echo "PASS: sync for-loop locals after await"

# ============================================================
# Test: Nested if-with-await in try body + await in except handler
# Regression test for a bug where Phase C of splitTryBlock did not
# re-wrap nnkTryStmt nodes inside IfBranchInfo preStmts, causing
# the handler body (with raw 'await') to survive into the output.
# ============================================================

block testNestedIfAwaitInTryWithAwaitHandler:
  proc nestedIfTry(flag: bool): CpsFuture[int] {.cps.} =
    try:
      if flag:
        if true:
          await cpsYield()
        else:
          await cpsYield()
      else:
        await cpsYield()
      return 42
    except CatchableError as e:
      await cpsYield()
      return -1

  let result = runCps(nestedIfTry(true))
  assert result == 42, "Expected 42, got: " & $result
  let result2 = runCps(nestedIfTry(false))
  assert result2 == 42, "Expected 42, got: " & $result2
  echo "PASS: nested if-with-await in try + await in except handler"

block testNestedIfAwaitInTryWithAwaitHandlerError:
  proc nestedIfTryFail(flag: bool): CpsFuture[int] {.cps.} =
    try:
      if flag:
        if true:
          let x = await mayFail(1, true)  # will raise
          return x
        else:
          await cpsYield()
      else:
        let y = await mayFail(2, true)  # will raise
        return y
      return 99
    except CatchableError as e:
      await cpsYield()
      return -1

  let result = runCps(nestedIfTryFail(true))
  assert result == -1, "Expected -1 (handler), got: " & $result
  let result2 = runCps(nestedIfTryFail(false))
  assert result2 == -1, "Expected -1 (handler), got: " & $result2
  echo "PASS: nested if-with-await in try, error routed to await-handler"

echo ""
echo "All try/except tests passed!"
