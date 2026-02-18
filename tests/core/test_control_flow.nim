## Tests for CPS control flow: if/elif/else, while, for with await
##
## Verifies that await inside control flow blocks works correctly:
## - if/elif/else branches with await
## - while loops with await, break, continue
## - for loops with await (desugared to while)
## - Nested control flow combinations

import cps/runtime
import cps/eventloop
import cps/transform

# ============================================================
# Helpers
# ============================================================

proc makeInt(x: int): CpsFuture[int] =
  let f = newCpsFuture[int]()
  scheduleCallback(proc() = f.complete(x))
  return f

proc makeStr(s: string): CpsFuture[string] =
  let f = newCpsFuture[string]()
  scheduleCallback(proc() = f.complete(s))
  return f

proc failWith(msg: string): CpsVoidFuture {.cps.} =
  raise newException(ValueError, msg)

# ============================================================
# IF/ELIF/ELSE tests
# ============================================================

# Test 1: Await in if-true branch
block testIfTrue:
  proc main(flag: bool): CpsFuture[int] {.cps.} =
    var res = 0
    if flag:
      let val = await makeInt(42)
      res = val
    return res

  let val = runCps(main(true))
  assert val == 42, "Expected 42, got: " & $val
  echo "PASS: Await in if-true branch"

# Test 2: If-false fallthrough (no else)
block testIfFalseNoElse:
  proc main(flag: bool): CpsFuture[int] {.cps.} =
    var res = 0
    if flag:
      let val = await makeInt(42)
      res = val
    return res

  let val = runCps(main(false))
  assert val == 0, "Expected 0, got: " & $val
  echo "PASS: If-false fallthrough"

# Test 3: Await in else branch
block testAwaitInElse:
  proc main(flag: bool): CpsFuture[int] {.cps.} =
    var res = 0
    if flag:
      res = 1
    else:
      let val = await makeInt(99)
      res = val
    return res

  let val = runCps(main(false))
  assert val == 99, "Expected 99, got: " & $val
  echo "PASS: Await in else branch"

# Test 4: Await in elif branch
block testAwaitInElif:
  proc main(x: int): CpsFuture[string] {.cps.} =
    var res = ""
    if x == 1:
      res = "one"
    elif x == 2:
      let val = await makeStr("two-async")
      res = val
    else:
      res = "other"
    return res

  let val = runCps(main(2))
  assert val == "two-async", "Expected 'two-async', got: " & val
  echo "PASS: Await in elif branch"

# Test 5: Code after if/elif/else continues normally
block testCodeAfterIf:
  proc main(): CpsFuture[int] {.cps.} =
    var res = 0
    if true:
      let val = await makeInt(10)
      res = val
    res = res + 5
    return res

  let val = runCps(main())
  assert val == 15, "Expected 15, got: " & $val
  echo "PASS: Code after if continues normally"

# Test 6: Multiple awaits in one if branch
block testMultipleAwaitsInBranch:
  proc main(): CpsFuture[int] {.cps.} =
    var res = 0
    if true:
      let a = await makeInt(10)
      let b = await makeInt(20)
      res = a + b
    return res

  let val = runCps(main())
  assert val == 30, "Expected 30, got: " & $val
  echo "PASS: Multiple awaits in one if branch"

# Test 7: Await in both if and else branches
block testAwaitBothBranches:
  proc main(flag: bool): CpsFuture[int] {.cps.} =
    var res = 0
    if flag:
      let val = await makeInt(100)
      res = val
    else:
      let val = await makeInt(200)
      res = val
    return res

  let valT = runCps(main(true))
  assert valT == 100, "Expected 100, got: " & $valT
  let valF = runCps(main(false))
  assert valF == 200, "Expected 200, got: " & $valF
  echo "PASS: Await in both if and else"

# ============================================================
# WHILE tests
# ============================================================

# Test 8: While with await in body
block testWhileAwait:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    var i = 0
    while i < 3:
      let val = await makeInt(i * 10)
      sum = sum + val
      i = i + 1
    return sum

  let val = runCps(main())
  assert val == 30, "Expected 30 (0+10+20), got: " & $val
  echo "PASS: While with await in body"

# Test 9: While true + break
block testWhileTrueBreak:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    var i = 0
    while true:
      let val = await makeInt(i * 10)
      sum = sum + val
      i = i + 1
      if i >= 3:
        break
    return sum

  let val = runCps(main())
  assert val == 30, "Expected 30, got: " & $val
  echo "PASS: While true + break"

# Test 10: While with continue
block testWhileContinue:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    var i = 0
    while i < 5:
      i = i + 1
      if i == 3:
        continue
      let val = await makeInt(i)
      sum = sum + val
    return sum

  let val = runCps(main())
  assert val == 12, "Expected 12 (1+2+4+5), got: " & $val
  echo "PASS: While with continue"

# Test 11: Counter-based while (like for loop)
block testCounterWhile:
  proc main(n: int): CpsFuture[int] {.cps.} =
    var sum = 0
    var i = 0
    while i < n:
      let val = await makeInt(1)
      sum = sum + val
      i = i + 1
    return sum

  let val = runCps(main(5))
  assert val == 5, "Expected 5, got: " & $val
  echo "PASS: Counter-based while"

# Test 12: While that doesn't execute (false condition)
block testWhileFalse:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    while false:
      let val = await makeInt(99)
      sum = sum + val
    return sum

  let val = runCps(main())
  assert val == 0, "Expected 0, got: " & $val
  echo "PASS: While with false condition"

# ============================================================
# FOR tests
# ============================================================

# Test 13: for i in 0..<N with await
block testForExclusive:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    for i in 0 ..< 4:
      let val = await makeInt(i * 10)
      sum = sum + val
    return sum

  let val = runCps(main())
  assert val == 60, "Expected 60 (0+10+20+30), got: " & $val
  echo "PASS: for i in 0..<4 with await"

# Test 14: for i in 0..N with await
block testForInclusive:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    for i in 0 .. 3:
      let val = await makeInt(i * 10)
      sum = sum + val
    return sum

  let val = runCps(main())
  assert val == 60, "Expected 60 (0+10+20+30), got: " & $val
  echo "PASS: for i in 0..3 with await"

# Test 15: for countdown with await
block testCountdown:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    for i in countdown(3, 0):
      let val = await makeInt(i * 10)
      sum = sum + val
    return sum

  let val = runCps(main())
  assert val == 60, "Expected 60 (30+20+10+0), got: " & $val
  echo "PASS: countdown with await"

# Test 16: for with break
block testForBreak:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    for i in 0 ..< 10:
      if i >= 3:
        break
      let val = await makeInt(i * 10)
      sum = sum + val
    return sum

  let val = runCps(main())
  assert val == 30, "Expected 30 (0+10+20), got: " & $val
  echo "PASS: for with break"

# Test 17: for with continue
block testForContinue:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    for i in 0 ..< 5:
      if i == 2:
        continue
      let val = await makeInt(i)
      sum = sum + val
    return sum

  let val = runCps(main())
  assert val == 8, "Expected 8 (0+1+3+4), got: " & $val
  echo "PASS: for with continue"

# ============================================================
# NESTED control flow tests
# ============================================================

# Test 18: If-with-await inside while-with-await
block testIfInsideWhile:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    var i = 0
    while i < 4:
      if i mod 2 == 0:
        let val = await makeInt(i * 10)
        sum = sum + val
      else:
        let val = await makeInt(i)
        sum = sum + val
      i = i + 1
    return sum

  let val = runCps(main())
  # i=0: 0, i=1: 1, i=2: 20, i=3: 3 => 24
  assert val == 24, "Expected 24, got: " & $val
  echo "PASS: If-with-await inside while"

# Test 19: Multiple control flow constructs in sequence
block testSequentialControlFlow:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0

    # First: if with await
    if true:
      let val = await makeInt(100)
      sum = sum + val

    # Then: while with await
    var i = 0
    while i < 3:
      let val = await makeInt(1)
      sum = sum + val
      i = i + 1

    # Then: for with await
    for j in 0 ..< 2:
      let val = await makeInt(10)
      sum = sum + val

    return sum

  let val = runCps(main())
  # 100 + 3*1 + 2*10 = 123
  assert val == 123, "Expected 123, got: " & $val
  echo "PASS: Sequential control flow constructs"

# Test 20: While-with-await inside if
block testWhileInsideIf:
  proc main(flag: bool): CpsFuture[int] {.cps.} =
    var sum = 0
    if flag:
      var i = 0
      while i < 3:
        let val = await makeInt(10)
        sum = sum + val
        i = i + 1
    else:
      sum = 999
    return sum

  let val = runCps(main(true))
  assert val == 30, "Expected 30, got: " & $val
  let valF = runCps(main(false))
  assert valF == 999, "Expected 999, got: " & $valF
  echo "PASS: While inside if"

# Test 21: try/except around while-with-await
block testTryAroundWhile:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    var i = 0
    while i < 5:
      let val = await makeInt(i)
      sum = sum + val
      i = i + 1
    return sum

  let val = runCps(main())
  assert val == 10, "Expected 10 (0+1+2+3+4), got: " & $val
  echo "PASS: While loop basic iteration"

# Test 22: Nested for loops
block testNestedFor:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    for i in 0 ..< 3:
      for j in 0 ..< 2:
        let val = await makeInt(i * 10 + j)
        sum = sum + val
    return sum

  let val = runCps(main())
  # i=0: 0+1=1, i=1: 10+11=21, i=2: 20+21=41 => 63
  assert val == 63, "Expected 63, got: " & $val
  echo "PASS: Nested for loops"

# Test 23: Void CPS proc with control flow
block testVoidControlFlow:
  var log: seq[string]

  proc main(): CpsVoidFuture {.cps.} =
    log.add "start"
    if true:
      await cpsYield()
      log.add "if-done"
    var i = 0
    while i < 2:
      await cpsYield()
      log.add "while-" & $i
      i = i + 1
    log.add "end"

  log = @[]
  runCps(main())
  assert log == @["start", "if-done", "while-0", "while-1", "end"],
    "Expected [start, if-done, while-0, while-1, end], got: " & $log
  echo "PASS: Void CPS proc with control flow"

# ============================================================
# FOR on iterable containers tests
# ============================================================

# Test 24: for x in seq literal with await
block testForSeqLiteral:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    for x in @[10, 20, 30]:
      let val = await makeInt(x)
      sum = sum + val
    return sum

  let val = runCps(main())
  assert val == 60, "Expected 60 (10+20+30), got: " & $val
  echo "PASS: for x in seq literal with await"

# Test 25: for x in seq parameter with await
block testForSeqParam:
  proc main(data: seq[int]): CpsFuture[int] {.cps.} =
    var sum = 0
    for x in data:
      let val = await makeInt(x)
      sum = sum + val
    return sum

  let val = runCps(main(@[5, 10, 15]))
  assert val == 30, "Expected 30 (5+10+15), got: " & $val
  echo "PASS: for x in seq parameter with await"

# Test 26: for i, x in seq with await (two-variable)
block testForPairsSeq:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    for i, x in @[100, 200, 300]:
      let val = await makeInt(x + i)
      sum = sum + val
    return sum

  let val = runCps(main())
  # i=0,x=100 => 100; i=1,x=200 => 201; i=2,x=300 => 302 => sum=603
  assert val == 603, "Expected 603, got: " & $val
  echo "PASS: for i, x in seq with await"

# Test 27: for x in items(seq) with await (explicit items wrapper)
block testForItemsWrapper:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    for x in items(@[7, 8, 9]):
      let val = await makeInt(x)
      sum = sum + val
    return sum

  let val = runCps(main())
  assert val == 24, "Expected 24 (7+8+9), got: " & $val
  echo "PASS: for x in items(seq) with await"

# Test 28: for on iterable with break
block testForIterableBreak:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    for x in @[10, 20, 30, 40, 50]:
      if x > 30:
        break
      let val = await makeInt(x)
      sum = sum + val
    return sum

  let val = runCps(main())
  assert val == 60, "Expected 60 (10+20+30), got: " & $val
  echo "PASS: for on iterable with break"

# Test 29: for on iterable with continue
block testForIterableContinue:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    for x in @[1, 2, 3, 4, 5]:
      if x == 3:
        continue
      let val = await makeInt(x)
      sum = sum + val
    return sum

  let val = runCps(main())
  assert val == 12, "Expected 12 (1+2+4+5), got: " & $val
  echo "PASS: for on iterable with continue"

# Test 30: for x in string with await
block testForString:
  proc main(): CpsFuture[string] {.cps.} =
    var res = ""
    for ch in "abc":
      let s = await makeStr($ch)
      res = res & s
    return res

  let val = runCps(main())
  assert val == "abc", "Expected 'abc', got: " & val
  echo "PASS: for x in string with await"

# Test 31: nested for on iterable containers
block testNestedForIterable:
  proc main(): CpsFuture[int] {.cps.} =
    var sum = 0
    for x in @[1, 2]:
      for y in @[10, 20]:
        let val = await makeInt(x * y)
        sum = sum + val
    return sum

  let val = runCps(main())
  # x=1: 10+20=30, x=2: 20+40=60 => 90
  assert val == 90, "Expected 90, got: " & $val
  echo "PASS: nested for on iterable containers"

# Test 32: for on iterable inside if
block testForIterableInsideIf:
  proc main(flag: bool): CpsFuture[int] {.cps.} =
    var sum = 0
    if flag:
      for x in @[10, 20, 30]:
        let val = await makeInt(x)
        sum = sum + val
    else:
      sum = 999
    return sum

  let val = runCps(main(true))
  assert val == 60, "Expected 60, got: " & $val
  let valF = runCps(main(false))
  assert valF == 999, "Expected 999, got: " & $valF
  echo "PASS: for on iterable inside if"

# Test 33: Range-based for loop with awaited end value (..<)
block testRangeForAwaitedEnd:
  proc main(): CpsFuture[int] {.cps.} =
    let n = await makeInt(5)
    var sum = 0
    for i in 0 ..< n:
      sum = sum + i
    return sum

  let val = runCps(main())
  assert val == 10, "Expected 10 (0+1+2+3+4), got: " & $val
  echo "PASS: for i in 0 ..< awaited_value"

# Test 34: Range-based for loop with awaited end value (..)
block testRangeForAwaitedEndInclusive:
  proc main(): CpsFuture[int] {.cps.} =
    let n = await makeInt(4)
    var sum = 0
    for i in 0 .. n:
      sum = sum + i
    return sum

  let val = runCps(main())
  assert val == 10, "Expected 10 (0+1+2+3+4), got: " & $val
  echo "PASS: for i in 0 .. awaited_value"

# Test 35: Range-based for loop with awaited start AND end values
block testRangeForAwaitedBoth:
  proc main(): CpsFuture[int] {.cps.} =
    let a = await makeInt(2)
    let b = await makeInt(5)
    var sum = 0
    for i in a ..< b:
      sum = sum + i
    return sum

  let val = runCps(main())
  assert val == 2 + 3 + 4, "Expected 9 (2+3+4), got: " & $val
  echo "PASS: for i in awaited_start ..< awaited_end"

# Test 36: Countdown with awaited end value
block testCountdownAwaitedEnd:
  proc main(): CpsFuture[string] {.cps.} =
    let n = await makeInt(3)
    var s = ""
    for i in countdown(n, 1):
      let v = await makeInt(i)
      s = s & $v
    return s

  let val = runCps(main())
  assert val == "321", "Expected '321', got: '" & val & "'"
  echo "PASS: for i in countdown(awaited_value, 1)"

# Test 37: Range-based for loop with await inside body + awaited end
block testRangeForAwaitedEndWithAwaitBody:
  proc main(): CpsFuture[int] {.cps.} =
    let n = await makeInt(4)
    var sum = 0
    for i in 0 ..< n:
      let v = await makeInt(i * 10)
      sum = sum + v
    return sum

  let val = runCps(main())
  assert val == 0 + 10 + 20 + 30, "Expected 60, got: " & $val
  echo "PASS: for i in 0 ..< awaited_value with await in body"

# Test 38: Range-based for loop with zero iterations
block testRangeForZeroIterations:
  proc main(): CpsFuture[int] {.cps.} =
    let n = await makeInt(0)
    var sum = 99
    for i in 0 ..< n:
      sum = sum + i
    return sum

  let val = runCps(main())
  assert val == 99, "Expected 99 (no iterations), got: " & $val
  echo "PASS: for i in 0 ..< 0 (zero iterations)"

echo ""
echo "All control flow tests passed!"
