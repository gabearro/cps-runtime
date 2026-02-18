## Tests for CPS case statement support (await inside case branches)

import cps/runtime
import cps/transform
import cps/eventloop

proc makeInt(x: int): CpsFuture[int] =
  let f = newCpsFuture[int]()
  f.complete(x)
  return f

proc makeString(x: string): CpsFuture[string] =
  let f = newCpsFuture[string]()
  f.complete(x)
  return f

# Test 1: Basic case with await in branches
block testBasicCase:
  proc testCase(x: int): CpsFuture[string] {.cps.} =
    case x
    of 1:
      let v = await makeInt(10)
      return "one:" & $v
    of 2:
      let v = await makeInt(20)
      return "two:" & $v
    else:
      let v = await makeInt(0)
      return "other:" & $v

  assert testCase(1).read() == "one:10"
  assert testCase(2).read() == "two:20"
  assert testCase(99).read() == "other:0"
  echo "PASS: Basic case with await"

# Test 2: Case with multiple patterns
block testMultiplePatterns:
  proc testMulti(x: int): CpsFuture[string] {.cps.} =
    case x
    of 1, 2, 3:
      let v = await makeInt(x * 10)
      return "low:" & $v
    of 4, 5:
      let v = await makeInt(x * 100)
      return "mid:" & $v
    else:
      return "high"

  assert testMulti(1).read() == "low:10"
  assert testMulti(2).read() == "low:20"
  assert testMulti(3).read() == "low:30"
  assert testMulti(4).read() == "mid:400"
  assert testMulti(5).read() == "mid:500"
  assert testMulti(99).read() == "high"
  echo "PASS: Case with multiple patterns"

# Test 3: Case with range
block testRange:
  proc testRangeCase(x: int): CpsFuture[string] {.cps.} =
    case x
    of 0..3:
      let v = await makeInt(x)
      return "low:" & $v
    of 4..6:
      let v = await makeInt(x * 2)
      return "mid:" & $v
    of 7..9:
      return "high"
    else:
      return "out"

  assert testRangeCase(0).read() == "low:0"
  assert testRangeCase(3).read() == "low:3"
  assert testRangeCase(5).read() == "mid:10"
  assert testRangeCase(8).read() == "high"
  assert testRangeCase(100).read() == "out"
  echo "PASS: Case with range"

# Test 4: Case on string
block testStringCase:
  proc testStr(s: string): CpsFuture[int] {.cps.} =
    case s
    of "hello":
      let v = await makeInt(1)
      return v
    of "world":
      let v = await makeInt(2)
      return v
    else:
      let v = await makeInt(0)
      return v

  assert testStr("hello").read() == 1
  assert testStr("world").read() == 2
  assert testStr("other").read() == 0
  echo "PASS: Case on string"

# Test 5: Case on enum
block testEnumCase:
  type Color = enum
    red, green, blue

  proc testEnum(c: Color): CpsFuture[string] {.cps.} =
    case c
    of red:
      let v = await makeString("RED")
      return v
    of green:
      let v = await makeString("GREEN")
      return v
    of blue:
      let v = await makeString("BLUE")
      return v

  assert testEnum(red).read() == "RED"
  assert testEnum(green).read() == "GREEN"
  assert testEnum(blue).read() == "BLUE"
  echo "PASS: Case on enum"

# Test 6: Nested case inside while
block testCaseInWhile:
  proc testWhileCase(): CpsFuture[int] {.cps.} =
    var sum = 0
    var i = 0
    while i < 5:
      let v = await makeInt(i)
      case v
      of 0, 1:
        let tmp = await makeInt(1)
        sum += tmp
      of 2:
        i += 1
        continue
      of 3:
        let tmp = await makeInt(10)
        sum += tmp
      else:
        let tmp = await makeInt(100)
        sum += tmp
      i += 1
    return sum

  # i=0: v=0, of 0,1 → sum+=1 → sum=1, i=1
  # i=1: v=1, of 0,1 → sum+=1 → sum=2, i=2
  # i=2: v=2, of 2 → continue (i=3)
  # i=3: v=3, of 3 → sum+=10 → sum=12, i=4
  # i=4: v=4, else → sum+=100 → sum=112, i=5
  assert testWhileCase().read() == 112
  echo "PASS: Nested case inside while"

# Test 7: Case with mixed await/sync branches
block testMixedBranches:
  proc testMixed(x: int): CpsFuture[int] {.cps.} =
    case x
    of 1:
      let v = await makeInt(100)
      return v
    of 2:
      return 200  # sync branch, no await
    of 3:
      let v = await makeInt(300)
      return v
    else:
      return 0  # sync branch

  assert testMixed(1).read() == 100
  assert testMixed(2).read() == 200
  assert testMixed(3).read() == 300
  assert testMixed(0).read() == 0
  echo "PASS: Case with mixed await/sync branches"

echo "All case statement tests passed!"
