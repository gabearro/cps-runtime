## Comprehensive CPS syntax/semantics tests
##
## Tests ALL idiomatic Nim syntax patterns inside {.cps.} procs.
## Organized by category. Each test is a self-contained block.
## Tests marked with "TODO" are expected to fail until the corresponding
## feature is implemented in transform.nim.

import cps/runtime
import cps/transform
import cps/eventloop
import std/strformat
import std/strutils

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

proc makeFloat(x: float): CpsFuture[float] =
  let f = newCpsFuture[float]()
  scheduleCallback(proc() = f.complete(x))
  return f

proc makeSeq(xs: seq[int]): CpsFuture[seq[int]] =
  let f = newCpsFuture[seq[int]]()
  scheduleCallback(proc() = f.complete(xs))
  return f

proc makeTuple(a: int, b: string): CpsFuture[(int, string)] =
  let f = newCpsFuture[(int, string)]()
  scheduleCallback(proc() = f.complete((a, b)))
  return f

proc makeVoid(): CpsVoidFuture =
  let f = newCpsVoidFuture()
  scheduleCallback(proc() = f.complete())
  return f

proc failWith(msg: string): CpsFuture[int] =
  let f = newCpsFuture[int]()
  scheduleCallback(proc() = f.fail(newException(ValueError, msg)))
  return f

proc failVoid(msg: string): CpsVoidFuture =
  let f = newCpsVoidFuture()
  scheduleCallback(proc() = f.fail(newException(IOError, msg)))
  return f

type
  MyObj = object
    x: int
    y: string

  MyRef = ref object
    x: int
    y: string

  MyEnum = enum
    meA, meB, meC

  MyVariant = object
    case kind: MyEnum
    of meA: aVal: int
    of meB: bVal: string
    of meC: cVal: float

  MyDistinct = distinct int

proc makeObj(x: int, y: string): CpsFuture[MyObj] =
  let f = newCpsFuture[MyObj]()
  scheduleCallback(proc() = f.complete(MyObj(x: x, y: y)))
  return f

proc makeRef(x: int, y: string): CpsFuture[MyRef] =
  let f = newCpsFuture[MyRef]()
  scheduleCallback(proc() = f.complete(MyRef(x: x, y: y)))
  return f

proc makeEnum(e: MyEnum): CpsFuture[MyEnum] =
  let f = newCpsFuture[MyEnum]()
  scheduleCallback(proc() = f.complete(e))
  return f


# ############################################################
# SECTION 1: Await in Constructors (via liftAwaitArgs)
# ############################################################

# Test: Await in seq constructor
block testAwaitInSeqConstructor:
  proc main(): CpsFuture[int] {.cps.} =
    let s = @[await makeInt(1), await makeInt(2), await makeInt(3)]
    return s[0] + s[1] + s[2]

  let val = runCps(main())
  assert val == 6, "Expected 6, got: " & $val
  echo "PASS: Await in seq constructor"

# Test: Await in array constructor
block testAwaitInArrayConstructor:
  proc main(): CpsFuture[int] {.cps.} =
    let a = [await makeInt(10), await makeInt(20)]
    return a[0] + a[1]

  let val = runCps(main())
  assert val == 30, "Expected 30, got: " & $val
  echo "PASS: Await in array constructor"

# Test: Await in tuple constructor
block testAwaitInTupleConstructor:
  proc main(): CpsFuture[int] {.cps.} =
    let t = (await makeInt(5), await makeStr("hello"))
    return t[0] + t[1].len

  let val = runCps(main())
  assert val == 10, "Expected 10, got: " & $val
  echo "PASS: Await in tuple constructor"

# Test: Await in object constructor
block testAwaitInObjConstructor:
  proc main(): CpsFuture[int] {.cps.} =
    let o = MyObj(x: await makeInt(7), y: await makeStr("hi"))
    return o.x + o.y.len

  let val = runCps(main())
  assert val == 9, "Expected 9, got: " & $val
  echo "PASS: Await in object constructor"


# ############################################################
# SECTION 2: Await in Operators and Expressions
# ############################################################

# Test: Await in arithmetic operators
block testAwaitInArithmetic:
  proc main(): CpsFuture[int] {.cps.} =
    return (await makeInt(10)) + (await makeInt(20)) * (await makeInt(3))

  let val = runCps(main())
  assert val == 70, "Expected 70, got: " & $val
  echo "PASS: Await in arithmetic operators"

# Test: Await in comparison operators
block testAwaitInComparison:
  proc main(): CpsFuture[bool] {.cps.} =
    return (await makeInt(10)) > (await makeInt(5))

  let val = runCps(main())
  assert val == true, "Expected true"
  echo "PASS: Await in comparison operators"

# Test: Await in boolean operators
block testAwaitInBoolOps:
  proc main(): CpsFuture[bool] {.cps.} =
    return (await makeBool(true)) and (await makeBool(false))

  let val = runCps(main())
  assert val == false, "Expected false"
  echo "PASS: Await in boolean operators"

# Test: Await in string concatenation
block testAwaitInStringConcat:
  proc main(): CpsFuture[string] {.cps.} =
    return (await makeStr("hello")) & " " & (await makeStr("world"))

  let val = runCps(main())
  assert val == "hello world", "Expected 'hello world', got: " & val
  echo "PASS: Await in string concatenation"

# Test: Await with $ operator
block testAwaitWithDollar:
  proc main(): CpsFuture[string] {.cps.} =
    return $(await makeInt(42))

  let val = runCps(main())
  assert val == "42", "Expected '42', got: " & val
  echo "PASS: Await with $ operator"

# Test: Await in indexing (bracket expression)
block testAwaitInIndexing:
  proc main(): CpsFuture[int] {.cps.} =
    let s = @[10, 20, 30, 40]
    return s[await makeInt(2)]

  let val = runCps(main())
  assert val == 30, "Expected 30, got: " & $val
  echo "PASS: Await in indexing"

# Test: Await in both container and index
block testAwaitInContainerAndIndex:
  proc main(): CpsFuture[int] {.cps.} =
    let idx: int = await makeInt(1)
    let s: seq[int] = await makeSeq(@[100, 200, 300])
    return s[idx]

  let val = runCps(main())
  assert val == 200, "Expected 200, got: " & $val
  echo "PASS: Await in container and index"

# Test: Await in nested call arguments
block testAwaitInNestedCalls:
  proc add3(a, b, c: int): int = a + b + c

  proc main(): CpsFuture[int] {.cps.} =
    return add3(await makeInt(1), await makeInt(2), await makeInt(3))

  let val = runCps(main())
  assert val == 6, "Expected 6, got: " & $val
  echo "PASS: Await in nested call arguments"

# Test: Await in method-call syntax (UFCS)
block testAwaitInUFCS:
  proc double(x: int): int = x * 2

  proc main(): CpsFuture[int] {.cps.} =
    return (await makeInt(21)).double()

  let val = runCps(main())
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: Await in UFCS method call"

# Test: Await in command syntax
block testAwaitCommandSyntax:
  proc main(): CpsFuture[string] {.cps.} =
    let v = await makeInt(42)
    return $v

  let val = runCps(main())
  assert val == "42", "Expected '42', got: " & val
  echo "PASS: Await in command syntax"


# ############################################################
# SECTION 3: If/Case/Block Expressions with Await
# (REQUIRES IMPLEMENTATION: Task #4)
# ############################################################

when true: # if/case/block expressions — Task #4
  # Test: If expression with await in branches
  block testIfExpressionWithAwait:
    proc main(): CpsFuture[int] {.cps.} =
      let cond = true
      let x = if cond: await makeInt(10) else: await makeInt(20)
      return x

    let val = runCps(main())
    assert val == 10, "Expected 10, got: " & $val
    echo "PASS: If expression with await in branches"

  # Test: If expression with await - else branch taken
  block testIfExpressionElseBranch:
    proc main(): CpsFuture[int] {.cps.} =
      let cond = false
      let x = if cond: await makeInt(10) else: await makeInt(20)
      return x

    let val = runCps(main())
    assert val == 20, "Expected 20, got: " & $val
    echo "PASS: If expression - else branch"

  # Test: If expression with await in condition
  block testIfExpressionAwaitCondition:
    proc main(): CpsFuture[int] {.cps.} =
      let x = if await makeBool(true): 100 else: 200
      return x

    let val = runCps(main())
    assert val == 100, "Expected 100, got: " & $val
    echo "PASS: If expression with await in condition"

  # Test: Nested if expression with await
  block testNestedIfExprWithAwait:
    proc main(): CpsFuture[int] {.cps.} =
      let x = if true:
                if await makeBool(true): await makeInt(1) else: await makeInt(2)
              else:
                await makeInt(3)
      return x

    let val = runCps(main())
    assert val == 1, "Expected 1, got: " & $val
    echo "PASS: Nested if expression with await"

  # Test: Case expression with await in branches
  block testCaseExpressionWithAwait:
    proc main(): CpsFuture[int] {.cps.} =
      let v = 2
      let x = case v
              of 1: await makeInt(10)
              of 2: await makeInt(20)
              else: await makeInt(30)
      return x

    let val = runCps(main())
    assert val == 20, "Expected 20, got: " & $val
    echo "PASS: Case expression with await"

  # Test: Block expression with await
  block testBlockExpressionWithAwait:
    proc main(): CpsFuture[int] {.cps.} =
      let x = block:
                let v = await makeInt(42)
                v + 8
      return x

    let val = runCps(main())
    assert val == 50, "Expected 50, got: " & $val
    echo "PASS: Block expression with await"


# ############################################################
# SECTION 4: Const and Type Declarations Inside CPS
# (REQUIRES IMPLEMENTATION: Task #3)
# ############################################################

when true: # const/type inside CPS — Task #3
  # Test: Const declaration inside CPS proc
  block testConstInsideCps:
    proc main(): CpsFuture[int] {.cps.} =
      const multiplier = 10
      let v = await makeInt(5)
      return v * multiplier

    let val = runCps(main())
    assert val == 50, "Expected 50, got: " & $val
    echo "PASS: Const inside CPS proc"

  # Test: Multiple consts inside CPS proc
  block testMultipleConstsInsideCps:
    proc main(): CpsFuture[string] {.cps.} =
      const prefix = "Hello"
      const suffix = "World"
      let mid = await makeStr(", ")
      return prefix & mid & suffix

    let val = runCps(main())
    assert val == "Hello, World", "Expected 'Hello, World', got: " & val
    echo "PASS: Multiple consts inside CPS"

  # Test: Const used in for loop bounds
  block testConstInForBounds:
    proc main(): CpsFuture[int] {.cps.} =
      const n = 5
      var total = 0
      for i in 0 ..< n:
        total += await makeInt(i)
      return total

    let val = runCps(main())
    assert val == 10, "Expected 10, got: " & $val
    echo "PASS: Const in for loop bounds"

  # Test: Type section inside CPS proc
  block testTypeSectionInsideCps:
    proc main(): CpsFuture[int] {.cps.} =
      type LocalPair = tuple[a: int, b: int]
      let v = await makeInt(5)
      let p: LocalPair = (a: v, b: v * 2)
      return p.a + p.b

    let val = runCps(main())
    assert val == 15, "Expected 15, got: " & $val
    echo "PASS: Type section inside CPS"


# ############################################################
# SECTION 5: Multiple var/let Declarations
# ############################################################

# Test: Multiple lets in single section (no await)
block testMultipleLetNoAwait:
  proc main(): CpsFuture[int] {.cps.} =
    let
      a = 1
      b = 2
    let v = await makeInt(a + b)
    return v

  let val = runCps(main())
  assert val == 3, "Expected 3, got: " & $val
  echo "PASS: Multiple let declarations (no await)"

# Test: Multiple vars with await in later one (REQUIRES IMPLEMENTATION: Task #7)
when true: # multi-var — Task #7
  block testMultipleVarWithAwait:
    proc main(): CpsFuture[int] {.cps.} =
      var
        a = 10
        b = await makeInt(20)
      return a + b

    let val = runCps(main())
    assert val == 30, "Expected 30, got: " & $val
    echo "PASS: Multiple var with await in second"

  # Test: Multiple vars with await in first
  block testMultipleVarAwaitFirst:
    proc main(): CpsFuture[int] {.cps.} =
      var
        a = await makeInt(10)
        b = 20
      return a + b

    let val = runCps(main())
    assert val == 30, "Expected 30, got: " & $val
    echo "PASS: Multiple var with await in first"

  # Test: Multiple vars both with await
  block testMultipleVarBothAwait:
    proc main(): CpsFuture[int] {.cps.} =
      var
        a = await makeInt(10)
        b = await makeInt(20)
      return a + b

    let val = runCps(main())
    assert val == 30, "Expected 30, got: " & $val
    echo "PASS: Multiple var both with await"

# Test: Multi-name single type declaration (REQUIRES IMPLEMENTATION: Task #7)
when true: # multi-var — Task #7
  block testMultiNameSingleType:
    proc main(): CpsFuture[int] {.cps.} =
      var x, y: int
      x = await makeInt(5)
      y = await makeInt(10)
      return x + y

    let val = runCps(main())
    assert val == 15, "Expected 15, got: " & $val
    echo "PASS: Multi-name single type var declaration"


# ############################################################
# SECTION 6: Ref Types and Object Variants
# ############################################################

# Test: Ref object creation and access across await
block testRefObjAcrossAwait:
  proc main(): CpsFuture[int] {.cps.} =
    let r = MyRef(x: 10, y: "hello")
    await makeVoid()
    return r.x + r.y.len

  let val = runCps(main())
  assert val == 15, "Expected 15, got: " & $val
  echo "PASS: Ref object across await"

# Test: Ref object modification across await (REQUIRES FIX: dot-expr assignment with await)
when true: # ref field assignment with await — Task #12
  block testRefObjModificationAcrossAwait:
    proc main(): CpsFuture[int] {.cps.} =
      let r = MyRef(x: 0, y: "")
      r.x = await makeInt(42)
      r.y = await makeStr("test")
      return r.x + r.y.len

    let val = runCps(main())
    assert val == 46, "Expected 46, got: " & $val
    echo "PASS: Ref object modification across await"

# Test: Awaited ref object
block testAwaitedRefObj:
  proc main(): CpsFuture[int] {.cps.} =
    let r: MyRef = await makeRef(7, "hi")
    return r.x + r.y.len

  let val = runCps(main())
  assert val == 9, "Expected 9, got: " & $val
  echo "PASS: Awaited ref object"

# Test: Object variants across await
block testObjVariantAcrossAwait:
  proc main(): CpsFuture[int] {.cps.} =
    let v = MyVariant(kind: meA, aVal: 42)
    await makeVoid()
    return v.aVal

  let val = runCps(main())
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: Object variant across await"


# ############################################################
# SECTION 7: Enum Types
# ############################################################

# Test: Enum across await
block testEnumAcrossAwait:
  proc main(): CpsFuture[int] {.cps.} =
    let e: MyEnum = await makeEnum(meB)
    case e
    of meA: return 1
    of meB: return 2
    of meC: return 3

  let val = runCps(main())
  assert val == 2, "Expected 2, got: " & $val
  echo "PASS: Enum across await"

# Test: Enum in case with await in branches
block testEnumCaseAwaitBranches:
  proc main(): CpsFuture[int] {.cps.} =
    let e = meC
    case e
    of meA: return await makeInt(10)
    of meB: return await makeInt(20)
    of meC: return await makeInt(30)

  let val = runCps(main())
  assert val == 30, "Expected 30, got: " & $val
  echo "PASS: Enum case with await in branches"


# ############################################################
# SECTION 8: Distinct Types
# ############################################################

# Test: Distinct type across await
block testDistinctTypeAcrossAwait:
  proc main(): CpsFuture[int] {.cps.} =
    let d = MyDistinct(await makeInt(42))
    await makeVoid()
    return int(d)

  let val = runCps(main())
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: Distinct type across await"


# ############################################################
# SECTION 9: Set Types
# ############################################################

# Test: Set operations across await
block testSetAcrossAwait:
  proc main(): CpsFuture[int] {.cps.} =
    var s = {1, 2, 3}
    await makeVoid()
    s.incl(await makeInt(4))
    return s.card

  let val = runCps(main())
  assert val == 4, "Expected 4, got: " & $val
  echo "PASS: Set operations across await"


# ############################################################
# SECTION 10: String Operations
# ############################################################

# Test: String methods across await
block testStringMethodsAcrossAwait:
  proc main(): CpsFuture[string] {.cps.} =
    var s = await makeStr("hello world")
    await makeVoid()
    return s.toUpperAscii()

  let val = runCps(main())
  assert val == "HELLO WORLD", "Expected 'HELLO WORLD', got: " & val
  echo "PASS: String methods across await"

# Test: String interpolation with $ and concat
block testStringInterpolationManual:
  proc main(): CpsFuture[string] {.cps.} =
    let n = await makeInt(42)
    let s = await makeStr("answer")
    return "The " & s & " is " & $n

  let val = runCps(main())
  assert val == "The answer is 42", "Expected 'The answer is 42', got: " & val
  echo "PASS: String interpolation (manual)"


# ############################################################
# SECTION 11: Seq Operations Across Await
# ############################################################

# Test: Seq add/access across await
block testSeqOpsAcrossAwait:
  proc main(): CpsFuture[int] {.cps.} =
    var s: seq[int] = @[]
    s.add(await makeInt(10))
    s.add(await makeInt(20))
    s.add(await makeInt(30))
    return s[0] + s[1] + s[2]

  let val = runCps(main())
  assert val == 60, "Expected 60, got: " & $val
  echo "PASS: Seq add/access across await"

# Test: Seq len and iteration after await
block testSeqLenIterAfterAwait:
  proc main(): CpsFuture[int] {.cps.} =
    let s: seq[int] = await makeSeq(@[1, 2, 3, 4, 5])
    var total = 0
    for x in s:
      total += x
    return total

  let val = runCps(main())
  assert val == 15, "Expected 15, got: " & $val
  echo "PASS: Seq len and iteration after await"


# ############################################################
# SECTION 12: Do Notation
# ############################################################

# Test: Do notation (callback without await inside)
block testDoNotation:
  proc callWithCb(x: int, cb: proc(v: int): int): int =
    return cb(x)

  proc main(): CpsFuture[int] {.cps.} =
    let v = await makeInt(10)
    let r = callWithCb(v) do (x: int) -> int:
      x * 2
    return r

  let val = runCps(main())
  assert val == 20, "Expected 20, got: " & $val
  echo "PASS: Do notation (no await in callback)"

# Test: Do notation with env capture
block testDoNotationCapture:
  proc applyFn(x: int, fn: proc(v: int): int): int = fn(x)

  proc main(): CpsFuture[int] {.cps.} =
    let multiplier = await makeInt(3)
    let r = applyFn(10) do (v: int) -> int:
      v * multiplier
    return r

  let val = runCps(main())
  assert val == 30, "Expected 30, got: " & $val
  echo "PASS: Do notation capturing CPS env"


# ############################################################
# SECTION 13: Named Blocks and Break/Continue Edge Cases
# ############################################################

# Test: Named block around while with break to label
block testNamedBlockAroundWhile:
  proc main(): CpsFuture[int] {.cps.} =
    var total = 0
    block outer:
      var i = 0
      while true:
        let v = await makeInt(i)
        total += v
        i += 1
        if i >= 5:
          break outer
    return total

  let val = runCps(main())
  assert val == 10, "Expected 10, got: " & $val
  echo "PASS: Named block around while with break to label"

# Test: Nested named blocks with break to outer
block testNestedNamedBlocksBreakOuter:
  proc main(): CpsFuture[int] {.cps.} =
    var result_val = 0
    block outer:
      block inner:
        result_val = await makeInt(42)
        break outer
      result_val = 0  # Should not execute
    return result_val

  let val = runCps(main())
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: Nested named blocks - break to outer"

# Test: Continue in nested for inside while
block testContinueNestedForInWhile:
  proc main(): CpsFuture[int] {.cps.} =
    var total = 0
    var rounds = 0
    while rounds < 2:
      rounds += 1
      for i in 0 ..< 5:
        if i == 2:
          continue
        total += await makeInt(1)
    return total

  let val = runCps(main())
  assert val == 8, "Expected 8, got: " & $val
  echo "PASS: Continue in nested for inside while"

# Test: Break from if inside for loop
block testBreakFromIfInsideFor:
  proc main(): CpsFuture[int] {.cps.} =
    var total = 0
    for i in 0 ..< 10:
      if await makeBool(i >= 3):
        break
      total += await makeInt(i)
    return total

  let val = runCps(main())
  assert val == 3, "Expected 3 (0+1+2), got: " & $val
  echo "PASS: Break from if inside for"

# Test: Multiple named blocks at same level
block testMultipleNamedBlocksSameLevel:
  proc main(): CpsFuture[int] {.cps.} =
    var total = 0
    block first:
      total += await makeInt(10)
    block second:
      total += await makeInt(20)
    block third:
      total += await makeInt(30)
    return total

  let val = runCps(main())
  assert val == 60, "Expected 60, got: " & $val
  echo "PASS: Multiple named blocks at same level"


# ############################################################
# SECTION 14: Exception Handling Edge Cases
# ############################################################

# Test: Bare raise in except handler
block testBareRaise:
  proc main(): CpsFuture[string] {.cps.} =
    try:
      let v = await failWith("test error")
      return "unreachable"
    except ValueError:
      raise  # re-raise current exception

  var caught = ""
  try:
    discard runCps(main())
  except ValueError as e:
    caught = e.msg
  assert caught == "test error", "Expected 'test error', got: " & caught
  echo "PASS: Bare raise in except handler"

# Test: Raise new exception in except handler
block testRaiseNewInExcept:
  proc main(): CpsFuture[int] {.cps.} =
    try:
      let v = await failWith("original")
      return v
    except ValueError:
      raise newException(IOError, "replaced")

  var caught = ""
  try:
    discard runCps(main())
  except IOError as e:
    caught = e.msg
  assert caught == "replaced", "Expected 'replaced', got: " & caught
  echo "PASS: Raise new exception in except handler"

# Test: Multiple exception types in single except
block testMultipleExceptTypes:
  proc main(): CpsFuture[string] {.cps.} =
    try:
      await failVoid("io error")
      return "no error"
    except ValueError, IOError:
      return "caught"

  let val = runCps(main())
  assert val == "caught", "Expected 'caught', got: " & val
  echo "PASS: Multiple exception types in single except"

# Test: Try/except/finally (3-part)
block testTryExceptFinally:
  proc main(): CpsFuture[string] {.cps.} =
    var log = ""
    try:
      log &= "try "
      await makeVoid()
      log &= "ok "
    except CatchableError:
      log &= "except "
    finally:
      log &= "finally"
    return log

  let val = runCps(main())
  assert val == "try ok finally", "Expected 'try ok finally', got: " & val
  echo "PASS: Try/except/finally"

# Test: Try/except/finally with async exception
block testTryExceptFinallyWithException:
  proc main(): CpsFuture[string] {.cps.} =
    var log = ""
    try:
      log &= "try "
      await failVoid("boom")
      log &= "unreachable "
    except IOError:
      log &= "except "
    finally:
      log &= "finally"
    return log

  let val = runCps(main())
  assert val == "try except finally", "Expected 'try except finally', got: " & val
  echo "PASS: Try/except/finally with async exception"

# Test: Nested try/except with different exception types
block testNestedTryExceptDifferentTypes:
  proc main(): CpsFuture[string] {.cps.} =
    var log = ""
    try:
      try:
        await failVoid("inner")
      except IOError:
        log &= "inner_caught "
      log &= "after_inner "
      await failVoid("outer")
    except IOError:
      log &= "outer_caught"
    return log

  let val = runCps(main())
  assert val == "inner_caught after_inner outer_caught", "Got: " & val
  echo "PASS: Nested try/except with async exceptions"


# ############################################################
# SECTION 15: Deeply Nested Control Flow
# ############################################################

# Test: 4 levels deep: block > while > if > for with await
block testDeeplyNested4Levels:
  proc main(): CpsFuture[int] {.cps.} =
    var total = 0
    block:
      var i = 0
      while i < 2:
        if await makeBool(true):
          for j in 0 ..< 3:
            total += await makeInt(1)
        i += 1
    return total

  let val = runCps(main())
  assert val == 6, "Expected 6, got: " & $val
  echo "PASS: 4 levels deep nesting"

# Test: Try inside while inside if inside block
block testTryWhileIfBlock:
  proc main(): CpsFuture[int] {.cps.} =
    var total = 0
    block:
      if true:
        var i = 0
        while i < 3:
          try:
            total += await makeInt(1)
          except CatchableError:
            discard
          i += 1
    return total

  let val = runCps(main())
  assert val == 3, "Expected 3, got: " & $val
  echo "PASS: Try inside while inside if inside block"


# ############################################################
# SECTION 16: Defer Edge Cases
# ############################################################

# Test: Multiple defers with await between them
block testMultipleDefersBetweenAwaits:
  var log: seq[string] = @[]

  proc main(): CpsVoidFuture {.cps.} =
    defer: log.add("defer1")
    await makeVoid()
    defer: log.add("defer2")
    await makeVoid()
    defer: log.add("defer3")
    log.add("body")

  runCps(main())
  assert log == @["body", "defer3", "defer2", "defer1"],
    "Expected reverse order, got: " & $log
  echo "PASS: Multiple defers between awaits"

# Test: Defer with await in scope and exception
block testDeferWithException:
  var log: seq[string] = @[]

  proc main(): CpsVoidFuture {.cps.} =
    defer: log.add("cleanup")
    log.add("before")
    await failVoid("boom")
    log.add("unreachable")

  try:
    runCps(main())
  except IOError:
    discard
  assert "cleanup" in log, "Defer should have run"
  assert "before" in log, "Before should have run"
  assert "unreachable" notin log, "Unreachable should not have run"
  echo "PASS: Defer runs on exception path"


# ############################################################
# SECTION 17: Closure Iterators in For Loops
# (REQUIRES IMPLEMENTATION: Task #2)
# ############################################################

when false: # closure iterators with await — KNOWN LIMITATION
  # Closure iterators with await in the body are NOT supported.
  # Nim's closure iterator instantiation with parameters is compiler magic
  # that cannot be replicated in an untyped macro. Parameterized closure
  # iterators can't be manually desugared to while loops.
  #
  # Workaround: collect iterator values into a seq first, then iterate:
  #   var items: seq[int]
  #   for x in closureIter(args): items.add x
  #   for x in items:
  #     total += await makeInt(x)
  #
  # For-loops with closure iterators WITHOUT await work fine (no desugaring needed).
  discard


# ############################################################
# SECTION 18: For Loop Edge Cases
# ############################################################

# Test: For loop with countdown and await
block testForCountdownAwait:
  proc main(): CpsFuture[seq[int]] {.cps.} =
    var result_seq: seq[int] = @[]
    for i in countdown(4, 0):
      result_seq.add(await makeInt(i))
    return result_seq

  let val = runCps(main())
  assert val == @[4, 3, 2, 1, 0], "Expected [4,3,2,1,0], got: " & $val
  echo "PASS: For countdown with await"

# Test: Nested for loops with await
block testNestedForLoopsAwait:
  proc main(): CpsFuture[int] {.cps.} =
    var total = 0
    for i in 0 ..< 3:
      for j in 0 ..< 3:
        total += await makeInt(1)
    return total

  let val = runCps(main())
  assert val == 9, "Expected 9, got: " & $val
  echo "PASS: Nested for loops with await"

# Test: For loop on string characters
block testForOnString:
  proc main(): CpsFuture[int] {.cps.} =
    let s = "hello"
    var count = 0
    for ch in s:
      if ch == 'l':
        count += await makeInt(1)
    return count

  let val = runCps(main())
  assert val == 2, "Expected 2, got: " & $val
  echo "PASS: For on string characters"

# Test: For loop with pairs on seq
block testForPairsSeq:
  proc main(): CpsFuture[int] {.cps.} =
    let s = @[10, 20, 30]
    var idxSum = 0
    var valSum = 0
    for i, v in s:
      idxSum += await makeInt(i)
      valSum += v
    return idxSum + valSum

  let val = runCps(main())
  assert val == 63, "Expected 63 (0+1+2 + 10+20+30), got: " & $val
  echo "PASS: For with pairs on seq"


# ############################################################
# SECTION 19: While Loop Edge Cases
# ############################################################

# Test: While with compound condition and await
block testWhileCompoundCondition:
  proc main(): CpsFuture[int] {.cps.} =
    var i = 0
    var total = 0
    while i < 10 and await makeBool(true):
      total += await makeInt(1)
      i += 1
      if i >= 5:
        break
    return total

  let val = runCps(main())
  assert val == 5, "Expected 5, got: " & $val
  echo "PASS: While with compound condition and await"

# Test: While with negated await condition
block testWhileNegatedAwaitCondition:
  proc main(): CpsFuture[int] {.cps.} =
    var i = 0
    while not await makeBool(i >= 3):
      i += 1
    return i

  let val = runCps(main())
  assert val == 3, "Expected 3, got: " & $val
  echo "PASS: While with negated await condition"


# ############################################################
# SECTION 20: Return Value Edge Cases
# ############################################################

# Test: Early return from multiple branches
block testEarlyReturnMultipleBranches:
  proc main(x: int): CpsFuture[string] {.cps.} =
    if x < 0:
      return await makeStr("negative")
    if x == 0:
      return await makeStr("zero")
    return await makeStr("positive")

  assert runCps(main(-1)) == "negative"
  assert runCps(main(0)) == "zero"
  assert runCps(main(1)) == "positive"
  echo "PASS: Early return from multiple branches"

# Test: Return from inside while
block testReturnFromWhile:
  proc main(): CpsFuture[int] {.cps.} =
    var i = 0
    while true:
      if await makeBool(i == 5):
        return i
      i += 1
    return -1  # unreachable

  let val = runCps(main())
  assert val == 5, "Expected 5, got: " & $val
  echo "PASS: Return from inside while"

# Test: Return from inside for
block testReturnFromFor:
  proc main(): CpsFuture[int] {.cps.} =
    for i in 0 ..< 100:
      if await makeBool(i == 7):
        return i
    return -1

  let val = runCps(main())
  assert val == 7, "Expected 7, got: " & $val
  echo "PASS: Return from inside for"

# Test: Return from nested try/except
block testReturnFromTryExcept:
  proc main(): CpsFuture[int] {.cps.} =
    try:
      let v = await makeInt(42)
      return v
    except CatchableError:
      return -1

  let val = runCps(main())
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: Return from nested try/except"


# ############################################################
# SECTION 21: Lambda/Closure Captures
# ############################################################

# Test: Lambda capturing var modified by await
block testLambdaCaptureModifiedVar:
  proc main(): CpsFuture[int] {.cps.} =
    var x = 0
    x = await makeInt(10)
    let f = proc(): int = x * 2
    return f()

  let val = runCps(main())
  assert val == 20, "Expected 20, got: " & $val
  echo "PASS: Lambda capturing var modified by await"

# Test: Lambda created before and after await
block testLambdaBeforeAndAfterAwait:
  proc main(): CpsFuture[int] {.cps.} =
    var x = 5
    let before = proc(): int = x
    x = await makeInt(10)
    let after = proc(): int = x
    return before() + after()

  let val = runCps(main())
  # Both capture env.x which is 10 after the await
  assert val == 20, "Expected 20, got: " & $val
  echo "PASS: Lambda before and after await"

# Test: Multiple lambdas capturing different env vars
block testMultipleLambdasDiffVars:
  proc main(): CpsFuture[int] {.cps.} =
    let a = await makeInt(3)
    let b = await makeInt(7)
    let getA = proc(): int = a
    let getB = proc(): int = b
    return getA() + getB()

  let val = runCps(main())
  assert val == 10, "Expected 10, got: " & $val
  echo "PASS: Multiple lambdas capturing different vars"


# ############################################################
# SECTION 22: Void CPS Procs
# ############################################################

# Test: Void CPS with all control flow
block testVoidCpsAllControlFlow:
  var log: seq[string] = @[]

  proc main(): CpsVoidFuture {.cps.} =
    log.add("start")
    if await makeBool(true):
      log.add("if-true")
    var i = 0
    while i < 2:
      log.add("while-" & $i)
      i += 1
    for j in 0 ..< 2:
      log.add("for-" & $j)
    try:
      await makeVoid()
      log.add("try-ok")
    except CatchableError:
      log.add("except")
    block:
      log.add("block")
    log.add("end")

  runCps(main())
  assert log == @["start", "if-true", "while-0", "while-1", "for-0", "for-1", "try-ok", "block", "end"],
    "Got: " & $log
  echo "PASS: Void CPS with all control flow"


# ############################################################
# SECTION 23: Compound Assignments
# ############################################################

# Test: Compound assignments across await
block testCompoundAssignmentsAcrossAwait:
  proc main(): CpsFuture[int] {.cps.} =
    var x = 10
    x += await makeInt(5)
    x -= await makeInt(3)
    x *= await makeInt(2)
    return x

  let val = runCps(main())
  assert val == 24, "Expected 24, got: " & $val
  echo "PASS: Compound assignments across await"


# ############################################################
# SECTION 24: Mixed Sync/Async Expressions
# ############################################################

# Test: Mix of sync and async in complex expression
block testMixedSyncAsync:
  proc main(): CpsFuture[int] {.cps.} =
    let a = 5
    let b = await makeInt(10)
    let c = 3
    let d = await makeInt(7)
    return a * b + c * d  # 50 + 21 = 71

  let val = runCps(main())
  assert val == 71, "Expected 71, got: " & $val
  echo "PASS: Mixed sync/async expressions"

# Test: Sync function with awaited arg and sync args
block testSyncFnWithMixedArgs:
  proc combine(a: int, b: string, c: int): string =
    $a & b & $c

  proc main(): CpsFuture[string] {.cps.} =
    return combine(await makeInt(1), await makeStr("-"), 3)

  let val = runCps(main())
  assert val == "1-3", "Expected '1-3', got: " & val
  echo "PASS: Sync function with mixed args"


# ############################################################
# SECTION 25: When Statements (compile-time if)
# ############################################################

# Test: When with defined()
block testWhenDefined:
  proc main(): CpsFuture[int] {.cps.} =
    when defined(nimvm):
      # This branch won't be taken at runtime
      return 0
    else:
      return await makeInt(42)

  let val = runCps(main())
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: When with defined()"

# Test: When true with await
block testWhenTrueAwait:
  proc main(): CpsFuture[int] {.cps.} =
    when true:
      return await makeInt(100)
    else:
      return 0

  let val = runCps(main())
  assert val == 100, "Expected 100, got: " & $val
  echo "PASS: When true with await"


# ############################################################
# SECTION 26: Chained Awaits and Nested CPS Calls
# ############################################################

# Helpers for chained CPS calls (must be at module scope)
proc cpsDouble(x: int): CpsFuture[int] {.cps.} =
  return await makeInt(x * 2)

proc cpsAddOne(x: int): CpsFuture[int] {.cps.} =
  return await makeInt(x + 1)

proc cpsStep(x: int): CpsFuture[int] {.cps.} =
  return await makeInt(x + 1)

# Test: Chained CPS calls (nested await f(await g()) — Task #11)
block testChainedCpsCalls:
  proc main(): CpsFuture[int] {.cps.} =
    let v = await cpsDouble(await cpsAddOne(await makeInt(5)))
    return v

  let val = runCps(main())
  assert val == 12, "Expected 12, got: " & $val
  echo "PASS: Chained CPS calls (nested await)"

# Test: Sequential CPS calls
block testSequentialCpsCalls:
  proc main(): CpsFuture[int] {.cps.} =
    var v = 0
    v = await cpsStep(v)  # 1
    v = await cpsStep(v)  # 2
    v = await cpsStep(v)  # 3
    v = await cpsStep(v)  # 4
    v = await cpsStep(v)  # 5
    return v

  let val = runCps(main())
  assert val == 5, "Expected 5, got: " & $val
  echo "PASS: Sequential CPS calls"


# ############################################################
# SECTION 27: Edge Cases in Variable Scoping
# ############################################################

# Test: Same-name vars in different scopes
block testSameNameDiffScopes:
  proc main(): CpsFuture[int] {.cps.} =
    var total = 0
    block:
      let x = await makeInt(10)
      total += x
    block:
      let x = await makeInt(20)
      total += x
    return total

  let val = runCps(main())
  assert val == 30, "Expected 30, got: " & $val
  echo "PASS: Same-name vars in different scopes"

# Test: Different variable names in nested scopes (shadowing is NOT supported in CPS — flat env)
block testDiffVarNamesInScopes:
  proc main(): CpsFuture[int] {.cps.} =
    let outer = await makeInt(10)
    if true:
      let inner = await makeInt(20)
      if inner != 20:
        return -1
    return outer  # outer is unaffected

  let val = runCps(main())
  assert val == 10, "Expected 10, got: " & $val
  echo "PASS: Different variable names in nested scopes"


# ############################################################
# SECTION 28: Try Expression Binding (already supported)
# ############################################################

# Test: Let with try expression containing await
block testLetTryExprAwait:
  proc main(): CpsFuture[int] {.cps.} =
    let x = try: await makeInt(42)
             except CatchableError: -1
    return x

  let val = runCps(main())
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: Let with try expression (success)"

# Test: Let with try expression - exception path
block testLetTryExprException:
  proc main(): CpsFuture[int] {.cps.} =
    let x = try: await failWith("boom")
             except ValueError: -1
    return x

  let val = runCps(main())
  assert val == -1, "Expected -1, got: " & $val
  echo "PASS: Let with try expression (exception)"


# ############################################################
# SECTION 29: Discard Patterns
# ############################################################

# Test: Discard await void
block testDiscardAwaitVoid:
  proc main(): CpsFuture[int] {.cps.} =
    discard await makeVoid()
    return 42

  let val = runCps(main())
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: Discard await void"

# Test: Discard await typed value
block testDiscardAwaitTyped:
  proc main(): CpsFuture[int] {.cps.} =
    discard await makeInt(99)
    return 42

  let val = runCps(main())
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: Discard await typed value"

# Test: Discard result of sync call with await arg
block testDiscardSyncCallWithAwaitArg:
  proc sideEffect(x: int): int =
    return x  # Just return it

  proc main(): CpsFuture[int] {.cps.} =
    discard sideEffect(await makeInt(99))
    return 42

  let val = runCps(main())
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: Discard sync call with await arg"


# ############################################################
# SECTION 30: Tuple Unpacking Patterns
# ############################################################

# Test: Tuple unpacking with let
block testTupleUnpackLet:
  proc main(): CpsFuture[int] {.cps.} =
    let (a, b) = await makeTuple(10, "hello")
    return a + b.len

  let val = runCps(main())
  assert val == 15, "Expected 15, got: " & $val
  echo "PASS: Tuple unpacking with let"

# Test: Tuple unpacking with var
block testTupleUnpackVar:
  proc main(): CpsFuture[int] {.cps.} =
    var (a, b) = await makeTuple(5, "hi")
    a += 10
    return a + b.len

  let val = runCps(main())
  assert val == 17, "Expected 17, got: " & $val
  echo "PASS: Tuple unpacking with var"

# Test: Multiple tuple unpackings
block testMultipleTupleUnpackings:
  proc main(): CpsFuture[int] {.cps.} =
    let (a, b) = await makeTuple(1, "x")
    let (c, d) = await makeTuple(2, "yy")
    return a + c + b.len + d.len

  let val = runCps(main())
  assert val == 6, "Expected 6, got: " & $val
  echo "PASS: Multiple tuple unpackings"


# ############################################################
# SECTION 31: String Interpolation (fmt/&) with Await
# ############################################################

block testFmtWithAwait:
  proc main(): CpsFuture[string] {.cps.} =
    let name = await makeStr("world")
    return fmt"hello {name}"

  let val = runCps(main())
  assert val == "hello world", "Got: " & val
  echo "PASS: fmt with await result"

block testAmpWithAwait:
  proc main(): CpsFuture[string] {.cps.} =
    let x = await makeInt(42)
    return &"value is {x}"

  let val = runCps(main())
  assert val == "value is 42", "Got: " & val
  echo "PASS: & with await result"

block testFmtMultipleVars:
  proc main(): CpsFuture[string] {.cps.} =
    let a = await makeStr("hello")
    let b = await makeInt(42)
    return fmt"{a} {b}"

  let val = runCps(main())
  assert val == "hello 42", "Got: " & val
  echo "PASS: fmt with multiple await vars"

block testFmtExpressions:
  proc main(): CpsFuture[string] {.cps.} =
    let x = await makeInt(7)
    let y = await makeInt(6)
    return fmt"{x * y}"

  let val = runCps(main())
  assert val == "42", "Got: " & val
  echo "PASS: fmt with expression using await vars"


# ############################################################
# SECTION 32: Bare Raise, Reraise, and Exception Handling
# ############################################################

# Test: Bare raise (reraise) inside except handler
block testBareRaiseInExcept:
  proc inner(): CpsVoidFuture {.cps.} =
    raise newException(ValueError, "original")

  proc main(): CpsFuture[string] {.cps.} =
    try:
      try:
        await inner()
      except ValueError:
        raise  # bare raise = reraise
    except ValueError as e:
      return e.msg
    return "unreachable"

  let val = runCps(main())
  assert val == "original", "Expected 'original', got: " & val
  echo "PASS: Bare raise (reraise) in except handler"

# Test: Exception type check across await
block testExceptionTypeAcrossAwait:
  proc fail_with_value(): CpsVoidFuture {.cps.} =
    raise newException(ValueError, "val_error")

  proc fail_with_io(): CpsVoidFuture {.cps.} =
    raise newException(IOError, "io_error")

  proc main(): CpsFuture[string] {.cps.} =
    var log = ""
    try:
      await fail_with_value()
    except ValueError:
      log &= "val "
    try:
      await fail_with_io()
    except IOError:
      log &= "io"
    return log

  let val = runCps(main())
  assert val == "val io", "Got: " & val
  echo "PASS: Exception type check across await"


# ############################################################
# SECTION 33: Pragmas on Variables and Misc Edge Cases
# ############################################################

# Test: Using range types across await
block testRangeTypeAcrossAwait:
  proc main(): CpsFuture[int] {.cps.} =
    let x = await makeInt(5)
    var total = 0
    for i in 1 .. x:
      total += i
    return total

  let val = runCps(main())
  assert val == 15, "Expected 15, got: " & $val
  echo "PASS: Range type across await"

# Test: Template usage across await
block testTemplateAcrossAwait:
  template addOne(x: int): int = x + 1

  proc main(): CpsFuture[int] {.cps.} =
    let x = await makeInt(41)
    return addOne(x)

  let val = runCps(main())
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: Template usage across await"

# Test: Converter types (implicit conversion)
block testConverterAcrossAwait:
  type MyInt = distinct int
  proc `+`(a, b: MyInt): MyInt {.borrow.}
  proc `$`(a: MyInt): string {.borrow.}

  proc makeMyInt(x: int): CpsFuture[MyInt] =
    let f = newCpsFuture[MyInt]()
    f.complete(MyInt(x))
    return f

  proc main(): CpsFuture[int] {.cps.} =
    let a: MyInt = await makeMyInt(10)
    let b: MyInt = await makeMyInt(20)
    let c = a + b
    return int(c)

  let val = runCps(main())
  assert val == 30, "Expected 30, got: " & $val
  echo "PASS: Distinct type with borrow across await"

# Test: Nested proc call chains with await results
block testNestedCallChains:
  proc add(a, b: int): int = a + b
  proc mul(a, b: int): int = a * b

  proc main(): CpsFuture[int] {.cps.} =
    let x = await makeInt(3)
    let y = await makeInt(4)
    return add(mul(x, y), await makeInt(5))

  let val = runCps(main())
  assert val == 17, "Expected 17, got: " & $val
  echo "PASS: Nested call chains with await"

# Test: Array operations across await
block testArrayAcrossAwait:
  proc main(): CpsFuture[int] {.cps.} =
    var arr: array[3, int]
    arr[0] = await makeInt(10)
    arr[1] = await makeInt(20)
    arr[2] = await makeInt(30)
    var total = 0
    for x in arr:
      total += x
    return total

  let val = runCps(main())
  assert val == 60, "Expected 60, got: " & $val
  echo "PASS: Array operations across await"


echo ""
echo "All comprehensive CPS syntax tests passed!"
