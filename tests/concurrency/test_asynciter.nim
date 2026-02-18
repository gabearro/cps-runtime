## Tests for CPS async iterators
##
## Verifies async iterator creation, consumption, combinators,
## backpressure, early close, and terminal operations.

import std/options
import cps/runtime
import cps/eventloop
import cps/transform
import cps/concurrency/channels
import cps/concurrency/asynciter

# ============================================================
# Test 1: Basic iterator -- produce 1,2,3 -> collect -> @[1,2,3]
# ============================================================

proc basicProducer(s: Sender[int]): CpsVoidFuture {.cps.} =
  await s.emit(1)
  await s.emit(2)
  await s.emit(3)

proc testBasicMain(): CpsFuture[seq[int]] {.cps.} =
  let iter = newAsyncIterator[int](basicProducer)
  return await iter.collect()

block testBasic:
  let result = runCps(testBasicMain())
  assert result == @[1, 2, 3], "Expected @[1,2,3], got " & $result
  echo "PASS: Basic iterator -- produce 1,2,3 -> collect -> @[1,2,3]"

# ============================================================
# Test 2: Empty iterator -- produce nothing -> collect -> @[]
# ============================================================

proc emptyProducer(s: Sender[int]): CpsVoidFuture {.cps.} =
  discard  # produce nothing

proc testEmptyMain(): CpsFuture[seq[int]] {.cps.} =
  let iter = newAsyncIterator[int](emptyProducer)
  return await iter.collect()

block testEmpty:
  let result = runCps(testEmptyMain())
  assert result.len == 0, "Expected empty seq, got " & $result
  echo "PASS: Empty iterator -- produce nothing -> collect -> @[]"

# ============================================================
# Test 3: Large iterator -- produce 1000 items
# ============================================================

proc largeProducer(s: Sender[int]): CpsVoidFuture {.cps.} =
  var i = 0
  while i < 1000:
    await s.emit(i)
    i = i + 1

proc testLargeMain(): CpsFuture[int] {.cps.} =
  let iter = newAsyncIterator[int](largeProducer, bufferSize = 16)
  var count = 0
  var sum = 0
  while true:
    let item = await iter.next()
    if item.isNone:
      break
    sum = sum + item.get()
    count = count + 1
  assert count == 1000
  return sum

block testLarge:
  # Sum of 0..999 = 999*1000/2 = 499500
  let result = runCps(testLargeMain())
  assert result == 499500, "Expected 499500, got " & $result
  echo "PASS: Large iterator -- 1000 items, sum = 499500"

# ============================================================
# Test 4: Backpressure -- bounded buffer, producer blocks
# ============================================================

# With bufferSize=1 (channel capacity=2), the producer can buffer
# at most 2 items before blocking. We verify that values are
# produced and consumed correctly.

var backpressureLog: seq[string]

proc bpProducer(s: Sender[int]): CpsVoidFuture {.cps.} =
  backpressureLog.add("produce:1")
  await s.emit(1)
  backpressureLog.add("produce:2")
  await s.emit(2)
  backpressureLog.add("produce:3")
  await s.emit(3)
  backpressureLog.add("produce:done")

proc testBackpressureMain(): CpsFuture[seq[int]] {.cps.} =
  let iter = newAsyncIterator[int](bpProducer, bufferSize = 1)
  # Yield to let the event loop process any pending work
  await cpsYield()
  var results: seq[int]
  while true:
    let item = await iter.next()
    if item.isNone:
      break
    backpressureLog.add("consume:" & $item.get())
    results.add(item.get())
  return results

block testBackpressure:
  backpressureLog = @[]
  let result = runCps(testBackpressureMain())
  assert result == @[1, 2, 3], "Expected @[1,2,3], got " & $result
  echo "PASS: Backpressure -- bounded buffer, values produced/consumed correctly"

# ============================================================
# Test 5: map combinator -- ints to strings
# ============================================================

proc mapSourceProducer(s: Sender[int]): CpsVoidFuture {.cps.} =
  await s.emit(10)
  await s.emit(20)
  await s.emit(30)

proc testMapMain(): CpsFuture[seq[string]] {.cps.} =
  let source = newAsyncIterator[int](mapSourceProducer)
  let mapped = source.map(proc(x: int): string = "v" & $x)
  return await mapped.collect()

block testMap:
  let result = runCps(testMapMain())
  assert result == @["v10", "v20", "v30"], "Expected [v10,v20,v30], got " & $result
  echo "PASS: map combinator -- ints to strings"

# ============================================================
# Test 6: filter combinator -- produce 1-10, filter evens
# ============================================================

proc filterSourceProducer(s: Sender[int]): CpsVoidFuture {.cps.} =
  var i = 1
  while i <= 10:
    await s.emit(i)
    i = i + 1

proc testFilterMain(): CpsFuture[seq[int]] {.cps.} =
  let source = newAsyncIterator[int](filterSourceProducer)
  let evens = source.filter(proc(x: int): bool = x mod 2 == 0)
  return await evens.collect()

block testFilter:
  let result = runCps(testFilterMain())
  assert result == @[2, 4, 6, 8, 10], "Expected @[2,4,6,8,10], got " & $result
  echo "PASS: filter combinator -- produce 1-10, filter evens"

# ============================================================
# Test 7: take combinator -- produce many, take 5
# ============================================================

proc takeSourceProducer(s: Sender[int]): CpsVoidFuture {.cps.} =
  var i = 1
  while i <= 100:
    await s.emit(i)
    i = i + 1

proc testTakeMain(): CpsFuture[seq[int]] {.cps.} =
  let source = newAsyncIterator[int](takeSourceProducer, bufferSize = 4)
  let first5 = source.take(5)
  return await first5.collect()

block testTake:
  let result = runCps(testTakeMain())
  assert result == @[1, 2, 3, 4, 5], "Expected @[1,2,3,4,5], got " & $result
  echo "PASS: take combinator -- produce many, take 5"

# ============================================================
# Test 8: forEach -- apply action to each value
# ============================================================

var forEachResults: seq[int]

proc forEachAction(x: int): CpsVoidFuture {.cps.} =
  forEachResults.add(x * 10)

proc forEachProducer(s: Sender[int]): CpsVoidFuture {.cps.} =
  await s.emit(1)
  await s.emit(2)
  await s.emit(3)

proc testForEachMain(): CpsVoidFuture {.cps.} =
  let iter = newAsyncIterator[int](forEachProducer)
  await iter.forEach(forEachAction)

block testForEach:
  forEachResults = @[]
  runCps(testForEachMain())
  assert forEachResults == @[10, 20, 30], "Expected @[10,20,30], got " & $forEachResults
  echo "PASS: forEach -- apply action to each value"

# ============================================================
# Test 9: Early close -- close before producer finishes
# ============================================================

proc earlyCloseProducer(s: Sender[int]): CpsVoidFuture {.cps.} =
  var i = 0
  while i < 100:
    await s.emit(i)
    i = i + 1

proc testEarlyCloseMain(): CpsFuture[seq[int]] {.cps.} =
  let iter = newAsyncIterator[int](earlyCloseProducer, bufferSize = 2)
  var results: seq[int]
  # Read only 3 values then close
  let v1 = await iter.next()
  if v1.isSome:
    results.add(v1.get())
  let v2 = await iter.next()
  if v2.isSome:
    results.add(v2.get())
  let v3 = await iter.next()
  if v3.isSome:
    results.add(v3.get())
  iter.close()
  # After close, next() should return none
  let v4 = await iter.next()
  assert v4.isNone, "Expected none after close"
  return results

block testEarlyClose:
  let result = runCps(testEarlyCloseMain())
  assert result == @[0, 1, 2], "Expected @[0,1,2], got " & $result
  echo "PASS: Early close -- close before producer finishes"

# ============================================================
# Test 10: Collect with value types (verify values are correct)
# ============================================================

type TestObj = object
  name: string
  value: int

proc objProducer(s: Sender[TestObj]): CpsVoidFuture {.cps.} =
  await s.emit(TestObj(name: "a", value: 1))
  await s.emit(TestObj(name: "b", value: 2))
  await s.emit(TestObj(name: "c", value: 3))

proc testObjMain(): CpsFuture[seq[TestObj]] {.cps.} =
  let iter = newAsyncIterator[TestObj](objProducer)
  return await iter.collect()

block testObjCollect:
  let result = runCps(testObjMain())
  assert result.len == 3
  assert result[0].name == "a" and result[0].value == 1
  assert result[1].name == "b" and result[1].value == 2
  assert result[2].name == "c" and result[2].value == 3
  echo "PASS: Collect with value types (objects)"

# ============================================================
# Test 11: Chained combinators -- map then filter
# ============================================================

proc chainProducer(s: Sender[int]): CpsVoidFuture {.cps.} =
  var i = 1
  while i <= 10:
    await s.emit(i)
    i = i + 1

proc testChainMain(): CpsFuture[seq[int]] {.cps.} =
  let source = newAsyncIterator[int](chainProducer)
  # Double each value, then keep only those >= 10
  let doubled = source.map(proc(x: int): int = x * 2)
  let filtered = doubled.filter(proc(x: int): bool = x >= 10)
  return await filtered.collect()

block testChained:
  let result = runCps(testChainMain())
  # 1*2=2, 2*2=4, 3*2=6, 4*2=8, 5*2=10, 6*2=12, 7*2=14, 8*2=16, 9*2=18, 10*2=20
  # filter >= 10: 10, 12, 14, 16, 18, 20
  assert result == @[10, 12, 14, 16, 18, 20], "Expected @[10,12,14,16,18,20], got " & $result
  echo "PASS: Chained combinators -- map then filter"

# ============================================================
# Test 12: next() manual iteration
# ============================================================

proc manualProducer(s: Sender[string]): CpsVoidFuture {.cps.} =
  await s.emit("hello")
  await s.emit("world")

proc testManualMain(): CpsFuture[bool] {.cps.} =
  let iter = newAsyncIterator[string](manualProducer)
  let v1 = await iter.next()
  assert v1.isSome and v1.get() == "hello"
  let v2 = await iter.next()
  assert v2.isSome and v2.get() == "world"
  let v3 = await iter.next()
  assert v3.isNone  # end of iteration
  return true

block testManual:
  let result = runCps(testManualMain())
  assert result
  echo "PASS: next() manual iteration"

# ============================================================
# Test 13: isClosed reflects state
# ============================================================

block testIsClosed:
  proc dummyProducer(s: Sender[int]): CpsVoidFuture =
    let f = newCpsVoidFuture()
    f.complete()
    return f
  let iter = newAsyncIterator[int](dummyProducer, bufferSize = 1)
  assert not iter.isClosed
  iter.close()
  assert iter.isClosed
  echo "PASS: isClosed reflects state"

echo ""
echo "All async iterator tests passed!"
