## Comprehensive CPS syntax completeness tests
##
## Tests all idiomatic Nim syntax patterns inside {.cps.} procs.
## Each test is a self-contained block that verifies a specific syntax pattern.

import cps/runtime
import cps/transform
import cps/eventloop

# ============================================================
# Helpers
# ============================================================

proc makeInt(x: int): CpsFuture[int] =
  let f = newCpsFuture[int]()
  scheduleCallback(proc() = f.complete(x))
  return f

proc makeBool(x: bool): CpsFuture[bool] =
  let f = newCpsFuture[bool]()
  scheduleCallback(proc() = f.complete(x))
  return f

proc makeStr(s: string): CpsFuture[string] =
  let f = newCpsFuture[string]()
  scheduleCallback(proc() = f.complete(s))
  return f

proc makeTuple(a: int, b: string): CpsFuture[(int, string)] =
  let f = newCpsFuture[(int, string)]()
  scheduleCallback(proc() = f.complete((a, b)))
  return f

proc makeVoid(): CpsVoidFuture =
  let f = newCpsVoidFuture()
  scheduleCallback(proc() = f.complete())
  return f

proc completed(x: int): CpsFuture[int] =
  result = newCpsFuture[int]()
  result.complete(x)

proc completed(s: string): CpsFuture[string] =
  result = newCpsFuture[string]()
  result.complete(s)

proc completedBool(b: bool): CpsFuture[bool] =
  result = newCpsFuture[bool]()
  result.complete(b)

# ============================================================
# SECTION 1: Block Statements
# ============================================================

# Test: Anonymous block with await
block testBlockAnonymousAwait:
  proc main(): CpsFuture[int] {.cps.} =
    var res = 0
    block:
      let v = await makeInt(42)
      res = v
    return res

  let val = runCps(main())
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: Anonymous block with await"

# Test: Anonymous block with multiple awaits
block testBlockMultipleAwaits:
  proc main(): CpsFuture[int] {.cps.} =
    var total = 0
    block:
      let a = await makeInt(10)
      let b = await makeInt(20)
      total = a + b
    return total

  let val = runCps(main())
  assert val == 30, "Expected 30, got: " & $val
  echo "PASS: Anonymous block with multiple awaits"

# Test: Code after anonymous block with await
block testBlockAwaitContinuation:
  proc main(): CpsFuture[int] {.cps.} =
    var res = 0
    block:
      let v = await makeInt(10)
      res = v
    res = res + 5
    return res

  let val = runCps(main())
  assert val == 15, "Expected 15, got: " & $val
  echo "PASS: Code after anonymous block with await"

# Test: Named block with await
block testNamedBlockAwait:
  proc main(): CpsFuture[int] {.cps.} =
    var res = 0
    block myBlock:
      let v = await makeInt(42)
      res = v
    return res

  let val = runCps(main())
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: Named block with await"

# Test: Named block with break
block testNamedBlockBreak:
  proc main(): CpsFuture[int] {.cps.} =
    var res = 0
    block myBlock:
      let v = await makeInt(10)
      res = v
      if res > 5:
        break myBlock
      let v2 = await makeInt(20)
      res = v2
    return res

  let val = runCps(main())
  assert val == 10, "Expected 10, got: " & $val
  echo "PASS: Named block with break (early exit)"

# Test: Named block break skips remaining code
block testNamedBlockBreakSkip:
  proc main(): CpsFuture[int] {.cps.} =
    var res = 0
    block outer:
      res = 1
      let v = await makeInt(5)
      if v < 10:
        break outer
      res = 99  # Should NOT execute
    return res

  let val = runCps(main())
  assert val == 1, "Expected 1, got: " & $val
  echo "PASS: Named block break skips remaining code"

# Test: Nested blocks with await
block testNestedBlocks:
  proc main(): CpsFuture[int] {.cps.} =
    var res = 0
    block:
      let a = await makeInt(10)
      block:
        let b = await makeInt(20)
        res = a + b
    return res

  let val = runCps(main())
  assert val == 30, "Expected 30, got: " & $val
  echo "PASS: Nested blocks with await"

# ============================================================
# SECTION 2: Tuple Unpacking
# ============================================================

# Test: Tuple unpacking with await (let)
block testTupleUnpackLet:
  proc main(): CpsFuture[int] {.cps.} =
    let (a, b) = await makeTuple(42, "hello")
    return a

  let val = runCps(main())
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: Tuple unpacking with await (let)"

# Test: Tuple unpacking with await (var)
block testTupleUnpackVar:
  proc main(): CpsFuture[string] {.cps.} =
    var (a, b) = await makeTuple(1, "world")
    b = b & "!"
    return b

  let val = runCps(main())
  assert val == "world!", "Expected 'world!', got: " & $val
  echo "PASS: Tuple unpacking with await (var)"

# Test: Tuple unpacking across await boundary
block testTupleUnpackAcrossAwait:
  proc getPair(): CpsFuture[(int, int)] =
    let f = newCpsFuture[(int, int)]()
    scheduleCallback(proc() = f.complete((10, 20)))
    return f

  proc main(): CpsFuture[int] {.cps.} =
    let (a, b) = await getPair()
    let c = await makeInt(30)
    return a + b + c

  let val = runCps(main())
  assert val == 60, "Expected 60, got: " & $val
  echo "PASS: Tuple unpacking across await boundary"

# ============================================================
# SECTION 3: Await in Conditions
# ============================================================

# Test: Await in if condition
block testAwaitInIfCondition:
  proc main(): CpsFuture[int] {.cps.} =
    if await makeBool(true):
      return 42
    return 0

  let val = runCps(main())
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: Await in if condition"

# Test: Await in if condition (false path)
block testAwaitInIfConditionFalse:
  proc main(): CpsFuture[int] {.cps.} =
    if await makeBool(false):
      return 42
    return 0

  let val = runCps(main())
  assert val == 0, "Expected 0, got: " & $val
  echo "PASS: Await in if condition (false)"

# Test: Await in elif condition
block testAwaitInElifCondition:
  proc main(x: int): CpsFuture[string] {.cps.} =
    if x == 1:
      return "one"
    elif await makeBool(x == 2):
      return "two"
    else:
      return "other"

  let val = runCps(main(2))
  assert val == "two", "Expected 'two', got: " & $val
  echo "PASS: Await in elif condition"

# Test: Await in while condition
block testAwaitInWhileCondition:
  var counter = 0
  proc shouldContinue(): CpsFuture[bool] =
    counter += 1
    let f = newCpsFuture[bool]()
    let cont = counter < 4
    scheduleCallback(proc() = f.complete(cont))
    return f

  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    while await shouldContinue():
      sum += 1
    return sum

  let val = runCps(main())
  assert val == 3, "Expected 3, got: " & $val
  echo "PASS: Await in while condition"

# Test: Await in case expression
block testAwaitInCaseExpr:
  proc main(): CpsFuture[string] {.cps.} =
    case await makeInt(2):
    of 1:
      return "one"
    of 2:
      return "two"
    else:
      return "other"

  let val = runCps(main())
  assert val == "two", "Expected 'two', got: " & $val
  echo "PASS: Await in case expression"

# Test: Complex condition with await
block testComplexConditionAwait:
  proc main(): CpsFuture[int] {.cps.} =
    let x = await makeInt(5)
    if x > 0 and await makeBool(true):
      return 42
    return 0

  let val = runCps(main())
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: Complex condition with await"

# ============================================================
# SECTION 4: Defer Statements
# ============================================================

# Test: Simple defer with await in scope
block testDeferWithAwait:
  var log: seq[string]

  proc main(): CpsFuture[int] {.cps.} =
    log = @[]
    defer: log.add("deferred")
    log.add("before")
    let v = await makeInt(42)
    log.add("after")
    return v

  let val = runCps(main())
  assert val == 42, "Expected 42, got: " & $val
  assert log == @["before", "after", "deferred"], "Expected [before, after, deferred], got: " & $log
  echo "PASS: Defer with await in scope"

# Test: Multiple defers execute in reverse order
block testMultipleDefers:
  var log: seq[string]

  proc main(): CpsVoidFuture {.cps.} =
    log = @[]
    defer: log.add("first-defer")
    defer: log.add("second-defer")
    let v = await makeInt(1)
    log.add("body:" & $v)

  runCps(main())
  assert log == @["body:1", "second-defer", "first-defer"],
    "Expected [body:1, second-defer, first-defer], got: " & $log
  echo "PASS: Multiple defers in reverse order"

# Test: Defer runs on exception path
block testDeferOnException:
  var log: seq[string]

  proc main(): CpsVoidFuture {.cps.} =
    log = @[]
    defer: log.add("cleanup")
    let v = await makeInt(1)
    log.add("before-raise")
    raise newException(ValueError, "test error")

  let fut = main()
  let loop = getEventLoop()
  while not fut.finished:
    loop.tick()
  assert fut.hasError
  assert log == @["before-raise", "cleanup"],
    "Expected [before-raise, cleanup], got: " & $log
  echo "PASS: Defer runs on exception path"

# ============================================================
# SECTION 5: When Statements
# ============================================================

# Test: When true with await
block testWhenTrueAwait:
  proc main(): CpsFuture[int] {.cps.} =
    var res = 0
    when true:
      let v = await makeInt(42)
      res = v
    return res

  let val = runCps(main())
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: When true with await"

# Test: When compiles() check
block testWhenCompiles:
  proc main(): CpsFuture[int] {.cps.} =
    var res = 0
    when compiles(1 + 1):
      let v = await makeInt(42)
      res = v
    return res

  let val = runCps(main())
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: When compiles() with await"

# Test: When defined()
block testWhenDefined:
  proc main(): CpsFuture[int] {.cps.} =
    var res = 10
    when defined(nimsuggest):
      res = 99  # Should not execute during normal compilation
    else:
      let v = await makeInt(42)
      res = v
    return res

  let val = runCps(main())
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: When defined() with await"

# ============================================================
# SECTION 6: Nested Try/Except
# ============================================================

# Test: Try/except inside try/except, both with await
block testNestedTryExcept:
  proc main(): CpsFuture[string] {.cps.} =
    var res = ""
    try:
      try:
        let v = await makeInt(1)
        raise newException(ValueError, "inner")
      except ValueError:
        res = "caught-inner"
        let v2 = await makeInt(2)
        res = res & ":" & $v2
    except CatchableError:
      res = "caught-outer"
    return res

  let val = runCps(main())
  assert val == "caught-inner:2", "Expected 'caught-inner:2', got: " & $val
  echo "PASS: Nested try/except with await"

# NOTE: Exception propagation from inner try/except to outer try/except
# across await boundaries is a known limitation. The inner try's except
# handlers are in separate step functions and exceptions that escape them
# are not caught by the outer try. This is a complex fix for future work.

# Test: Inner try catches matching exception (common case)
block testNestedTryCatch:
  proc main(): CpsFuture[string] {.cps.} =
    var res = ""
    try:
      try:
        let v = await makeInt(1)
        raise newException(ValueError, "val-err")
      except ValueError as e:
        res = "inner-caught:" & e.msg
    except CatchableError:
      res = "outer-caught"
    return res

  let val = runCps(main())
  assert val == "inner-caught:val-err", "Expected 'inner-caught:val-err', got: " & $val
  echo "PASS: Nested try/except - inner catches matching exception"

# Test: Try/except in except handler with await
block testTryExceptInHandler:
  proc main(): CpsFuture[string] {.cps.} =
    var res = ""
    try:
      raise newException(ValueError, "outer-err")
    except ValueError:
      try:
        let v = await makeInt(42)
        res = "recovered:" & $v
      except CatchableError:
        res = "double-fault"
    return res

  let val = runCps(main())
  assert val == "recovered:42", "Expected 'recovered:42', got: " & $val
  echo "PASS: Try/except in except handler with await"

# ============================================================
# SECTION 7: Mutable Variables Across Await
# ============================================================

# Test: Mutable var modified across await boundaries
block testMutableVarAcrossAwait:
  proc main(): CpsFuture[int] {.cps.} =
    var x = 0
    x = x + 1
    let a = await makeInt(10)
    x = x + a
    let b = await makeInt(20)
    x = x + b
    return x

  let val = runCps(main())
  assert val == 31, "Expected 31, got: " & $val
  echo "PASS: Mutable var across await boundaries"

# Test: Var reassignment across await
block testVarReassignment:
  proc main(): CpsFuture[string] {.cps.} =
    var s = "hello"
    let v = await makeStr(" world")
    s = s & v
    let v2 = await makeStr("!")
    s = s & v2
    return s

  let val = runCps(main())
  assert val == "hello world!", "Expected 'hello world!', got: " & $val
  echo "PASS: Var reassignment across await"

# Test: Seq operations across await
block testSeqAcrossAwait:
  proc main(): CpsFuture[int] {.cps.} =
    var s: seq[int] = @[]
    s.add(1)
    let v = await makeInt(2)
    s.add(v)
    let v2 = await makeInt(3)
    s.add(v2)
    return s.len

  let val = runCps(main())
  assert val == 3, "Expected 3, got: " & $val
  echo "PASS: Seq operations across await"

# ============================================================
# SECTION 8: Multiple Variable Declarations
# ============================================================

# Test: Multiple variables in separate let/var statements across await
block testMultipleVarsAcrossAwait:
  proc main(): CpsFuture[int] {.cps.} =
    let a = 10
    let b = 20
    let c = await makeInt(30)
    return a + b + c

  let val = runCps(main())
  assert val == 60, "Expected 60, got: " & $val
  echo "PASS: Multiple variables across await"

# Test: Var with explicit type across await
block testVarWithType:
  proc main(): CpsFuture[int] {.cps.} =
    var x: int = 5
    let v = await makeInt(10)
    x = x + v
    return x

  let val = runCps(main())
  assert val == 15, "Expected 15, got: " & $val
  echo "PASS: Var with explicit type across await"

# ============================================================
# SECTION 9: Object and Ref Types
# ============================================================

# Test: Object construction across await
block testObjectAcrossAwait:
  type Point = object
    x, y: int

  proc main(): CpsFuture[int] {.cps.} =
    let px = await makeInt(10)
    let py = await makeInt(20)
    let p = Point(x: px, y: py)
    return p.x + p.y

  let val = runCps(main())
  assert val == 30, "Expected 30, got: " & $val
  echo "PASS: Object construction across await"

# Test: Field access across await
block testFieldAccess:
  type Pair = object
    first: int
    second: string

  proc main(): CpsFuture[string] {.cps.} =
    let f = await makeInt(42)
    let p = Pair(first: f, second: "hello")
    let s = await makeStr(" world")
    return p.second & s

  let val = runCps(main())
  assert val == "hello world", "Expected 'hello world', got: " & $val
  echo "PASS: Field access across await"

# ============================================================
# SECTION 10: Discard and Void Operations
# ============================================================

# Test: Discard awaited value
block testDiscardAwait:
  var sideEffect = 0
  proc doWork(): CpsFuture[int] =
    sideEffect += 1
    let f = newCpsFuture[int]()
    scheduleCallback(proc() = f.complete(42))
    return f

  proc main(): CpsFuture[int] {.cps.} =
    discard await doWork()
    discard await doWork()
    return sideEffect

  let val = runCps(main())
  assert val == 2, "Expected 2, got: " & $val
  echo "PASS: Discard awaited value"

# Test: Void await
block testVoidAwait:
  var log: seq[string]

  proc sideEffectTask(): CpsVoidFuture {.cps.} =
    log.add("task-ran")

  proc main(): CpsVoidFuture {.cps.} =
    log = @[]
    await sideEffectTask()
    log.add("after")

  runCps(main())
  assert log == @["task-ran", "after"], "Expected [task-ran, after], got: " & $log
  echo "PASS: Void await"

# ============================================================
# SECTION 11: String Operations with Await
# ============================================================

# Test: String concatenation with awaited values
block testStringConcat:
  proc main(): CpsFuture[string] {.cps.} =
    let a = await makeStr("hello")
    let b = await makeStr(" ")
    let c = await makeStr("world")
    return a & b & c

  let val = runCps(main())
  assert val == "hello world", "Expected 'hello world', got: " & $val
  echo "PASS: String concatenation with await"

# Test: $ operator on awaited value
block testDollarOnAwait:
  proc main(): CpsFuture[string] {.cps.} =
    let v = await makeInt(42)
    return "val=" & $v

  let val = runCps(main())
  assert val == "val=42", "Expected 'val=42', got: " & $val
  echo "PASS: $ operator on awaited value"

# ============================================================
# SECTION 12: Nested Control Flow Combinations
# ============================================================

# Test: If inside block with await
block testIfInsideBlock:
  proc main(): CpsFuture[int] {.cps.} =
    var res = 0
    block:
      let v = await makeInt(5)
      if v > 3:
        res = v * 2
      else:
        res = v
    return res

  let val = runCps(main())
  assert val == 10, "Expected 10, got: " & $val
  echo "PASS: If inside block with await"

# Test: While inside block with await
block testWhileInsideBlock:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    block:
      var i = 0
      while i < 3:
        let v = await makeInt(i)
        sum += v
        i += 1
    return sum

  let val = runCps(main())
  assert val == 3, "Expected 3, got: " & $val
  echo "PASS: While inside block with await"

# Test: Block inside while with await
block testBlockInsideWhile:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    var i = 0
    while i < 3:
      block:
        let v = await makeInt(i * 10)
        sum += v
      i += 1
    return sum

  let val = runCps(main())
  assert val == 30, "Expected 30, got: " & $val
  echo "PASS: Block inside while with await"

# Test: Block inside if with await
block testBlockInsideIf:
  proc main(flag: bool): CpsFuture[int] {.cps.} =
    if flag:
      block:
        let v = await makeInt(42)
        return v
    return 0

  let val = runCps(main(true))
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: Block inside if with await"

# ============================================================
# SECTION 13: For Loop Edge Cases
# ============================================================

# Test: For loop with await accessing loop variable
block testForAwaitLoopVar:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    for i in 0 ..< 5:
      let v = await makeInt(i)
      sum += v
    return sum

  let val = runCps(main())
  assert val == 10, "Expected 10, got: " & $val
  echo "PASS: For loop with await accessing loop var"

# Test: Nested for loops with await
block testNestedForAwait:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    for i in 0 ..< 3:
      for j in 0 ..< 2:
        let v = await makeInt(1)
        sum += v
    return sum

  let val = runCps(main())
  assert val == 6, "Expected 6, got: " & $val
  echo "PASS: Nested for loops with await"

# ============================================================
# SECTION 14: Assignment Patterns
# ============================================================

# Test: Assignment to existing var from await
block testAssignToVar:
  proc main(): CpsFuture[int] {.cps.} =
    var x = 0
    x = await makeInt(42)
    return x

  let val = runCps(main())
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: Assignment to var from await"

# Test: Compound assignment across await
block testCompoundAssignment:
  proc main(): CpsFuture[int] {.cps.} =
    var x = 10
    let v = await makeInt(5)
    x += v
    let v2 = await makeInt(3)
    x -= v2
    return x

  let val = runCps(main())
  assert val == 12, "Expected 12, got: " & $val
  echo "PASS: Compound assignment across await"

# ============================================================
# SECTION 15: Closure/Lambda Edge Cases
# ============================================================

# Test: Lambda created after await captures env correctly
block testLambdaAfterAwait:
  proc main(): CpsFuture[int] {.cps.} =
    let x = await makeInt(10)
    let f = proc(): int = x * 2
    return f()

  let val = runCps(main())
  assert val == 20, "Expected 20, got: " & $val
  echo "PASS: Lambda created after await"

# Test: Lambda using multiple env vars from before and after await
block testLambdaMultipleEnv:
  proc main(): CpsFuture[int] {.cps.} =
    let a = 5
    let b = await makeInt(10)
    let f = proc(): int = a + b
    return f()

  let val = runCps(main())
  assert val == 15, "Expected 15, got: " & $val
  echo "PASS: Lambda using multiple env vars"

# ============================================================
# SECTION 16: Deeply Nested Control Flow
# ============================================================

# Test: Three levels of nesting with await
block testDeepNesting:
  proc main(): CpsFuture[int] {.cps.} =
    var res = 0
    if true:
      var i = 0
      while i < 2:
        for j in 0 ..< 2:
          let v = await makeInt(1)
          res += v
        i += 1
    return res

  let val = runCps(main())
  assert val == 4, "Expected 4, got: " & $val
  echo "PASS: Three levels of nesting with await"

# Test: Try inside while inside if with await
block testTryWhileIf:
  proc main(): CpsFuture[int] {.cps.} =
    var res = 0
    if true:
      var i = 0
      while i < 3:
        try:
          let v = await makeInt(i)
          res += v
        except CatchableError:
          discard
        i += 1
    return res

  let val = runCps(main())
  assert val == 3, "Expected 3, got: " & $val
  echo "PASS: Try inside while inside if with await"

# ============================================================
# SECTION 17: Edge Cases
# ============================================================

# Test: Empty void CPS proc
block testEmptyVoidProc:
  proc main(): CpsVoidFuture {.cps.} =
    discard

  let fut = main()
  assert fut.finished
  echo "PASS: Empty void CPS proc"

# Test: Single return CPS proc
block testSingleReturn:
  proc main(): CpsFuture[int] {.cps.} =
    return 42

  let fut = main()
  assert fut.finished
  assert fut.read() == 42
  echo "PASS: Single return CPS proc"

# Test: Await followed by immediate return
block testAwaitThenReturn:
  proc main(): CpsFuture[int] {.cps.} =
    let v = await makeInt(42)
    return v

  let val = runCps(main())
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: Await then return"

# Test: Boolean negation of awaited value
block testNotAwait:
  proc main(): CpsFuture[bool] {.cps.} =
    let v = await makeBool(false)
    return not v

  let val = runCps(main())
  assert val == true, "Expected true, got: " & $val
  echo "PASS: Boolean negation of awaited value"

# Test: Arithmetic with awaited values
block testArithmeticAwait:
  proc main(): CpsFuture[int] {.cps.} =
    let a = await makeInt(10)
    let b = await makeInt(3)
    return (a * b) + (a - b) - (a div b)

  let val = runCps(main())
  assert val == 34, "Expected 34, got: " & $val
  echo "PASS: Arithmetic with awaited values"

# Test: Early return from if branch
block testEarlyReturn:
  proc main(flag: bool): CpsFuture[int] {.cps.} =
    if flag:
      let v = await makeInt(42)
      return v
    let v = await makeInt(99)
    return v

  let val1 = runCps(main(true))
  assert val1 == 42, "Expected 42, got: " & $val1
  let val2 = runCps(main(false))
  assert val2 == 99, "Expected 99, got: " & $val2
  echo "PASS: Early return from if branch"

# Test: Multiple return paths with await
block testMultipleReturnPaths:
  proc main(x: int): CpsFuture[string] {.cps.} =
    if x > 10:
      let s = await makeStr("big")
      return s
    elif x > 5:
      let s = await makeStr("medium")
      return s
    else:
      let s = await makeStr("small")
      return s

  assert runCps(main(15)) == "big"
  assert runCps(main(7)) == "medium"
  assert runCps(main(2)) == "small"
  echo "PASS: Multiple return paths with await"

echo "\n=== ALL COMPLETENESS TESTS PASSED ==="
