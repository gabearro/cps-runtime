## Tests for CPS broadcast and watch channels
##
## Verifies broadcast (one-to-many) and watch (latest-value) channel
## semantics including subscription, close, buffer overflow, and
## multi-receiver delivery.

import std/options
import cps/runtime
import cps/eventloop
import cps/transform
import cps/concurrency/broadcast

# ============================================================
# Test 1: Broadcast: one sender, one receiver -- basic send/recv
# ============================================================

proc testBcastBasicMain(): CpsFuture[int] {.cps.} =
  let ch = newBroadcast[int]()
  let rx = ch.subscribe()
  ch.send(42)
  let val = await rx.recv()
  return val

block testBcastBasic:
  let result = runCps(testBcastBasicMain())
  assert result == 42, "Expected 42, got " & $result
  echo "PASS: Broadcast: one sender, one receiver -- basic send/recv"

# ============================================================
# Test 2: Broadcast: one sender, two receivers -- both get same messages
# ============================================================

proc testBcastTwoRecvMain(): CpsFuture[seq[int]] {.cps.} =
  let ch = newBroadcast[int]()
  let rx1 = ch.subscribe()
  let rx2 = ch.subscribe()
  ch.send(10)
  ch.send(20)
  let v1a = await rx1.recv()
  let v1b = await rx1.recv()
  let v2a = await rx2.recv()
  let v2b = await rx2.recv()
  var results: seq[int]
  results.add(v1a)
  results.add(v1b)
  results.add(v2a)
  results.add(v2b)
  return results

block testBcastTwoRecv:
  let results = runCps(testBcastTwoRecvMain())
  assert results == @[10, 20, 10, 20], "Expected [10,20,10,20], got " & $results
  echo "PASS: Broadcast: one sender, two receivers -- both get same messages"

# ============================================================
# Test 3: Broadcast: send before subscribe -- subscriber misses old messages
# ============================================================

proc testBcastMissedMain(): CpsFuture[int] {.cps.} =
  let ch = newBroadcast[int]()
  ch.send(1)  # No subscribers yet
  ch.send(2)  # No subscribers yet
  let rx = ch.subscribe()
  ch.send(3)  # This one should arrive
  let val = await rx.recv()
  return val

block testBcastMissed:
  let result = runCps(testBcastMissedMain())
  assert result == 3, "Expected 3, got " & $result
  echo "PASS: Broadcast: send before subscribe -- subscriber misses old messages"

# ============================================================
# Test 4: Broadcast: buffer overflow -- lagging receiver loses oldest
# ============================================================

proc testBcastOverflowMain(): CpsFuture[seq[int]] {.cps.} =
  let ch = newBroadcast[int](capacity = 3)
  let rx = ch.subscribe()
  # Send 5 messages into a buffer of capacity 3
  ch.send(1)
  ch.send(2)
  ch.send(3)
  ch.send(4)  # Drops 1
  ch.send(5)  # Drops 2
  # Should get 3, 4, 5 (oldest dropped)
  var results: seq[int]
  let v1 = await rx.recv()
  results.add(v1)
  let v2 = await rx.recv()
  results.add(v2)
  let v3 = await rx.recv()
  results.add(v3)
  return results

block testBcastOverflow:
  let results = runCps(testBcastOverflowMain())
  assert results == @[3, 4, 5], "Expected [3,4,5], got " & $results
  echo "PASS: Broadcast: buffer overflow -- lagging receiver loses oldest"

# ============================================================
# Test 5: Broadcast: close wakes waiters with BroadcastClosed
# ============================================================

proc testBcastCloseRecv(rx: BroadcastReceiver[int]): CpsFuture[bool] {.cps.} =
  var gotError = false
  try:
    discard await rx.recv()
  except BroadcastClosed:
    gotError = true
  return gotError

proc testBcastCloseMain(): CpsFuture[bool] {.cps.} =
  let ch = newBroadcast[int]()
  let rx = ch.subscribe()
  let t = spawn testBcastCloseRecv(rx)
  await cpsYield()  # Let receiver block
  ch.close()
  let res = await t
  return res

block testBcastClose:
  let result = runCps(testBcastCloseMain())
  assert result, "Expected BroadcastClosed on recv from closed channel"
  echo "PASS: Broadcast: close wakes waiters with BroadcastClosed"

# ============================================================
# Test 6: Broadcast: unsubscribe removes receiver
# ============================================================

proc testBcastUnsubMain(): CpsFuture[int] {.cps.} =
  let ch = newBroadcast[int]()
  let rx1 = ch.subscribe()
  let rx2 = ch.subscribe()
  ch.unsubscribe(rx1)
  ch.send(99)
  # rx2 should get the message, rx1 should not
  let val = await rx2.recv()
  return val

block testBcastUnsub:
  let result = runCps(testBcastUnsubMain())
  assert result == 99, "Expected 99, got " & $result
  echo "PASS: Broadcast: unsubscribe removes receiver"

# ============================================================
# Test 7: Broadcast: tryRecv non-blocking
# ============================================================

block testBcastTryRecv:
  let ch = newBroadcast[int]()
  let rx = ch.subscribe()

  # tryRecv on empty returns none
  assert rx.tryRecv().isNone, "Expected none on empty receiver"

  ch.send(10)
  ch.send(20)

  let v1 = rx.tryRecv()
  assert v1.isSome and v1.get() == 10, "Expected 10, got " & $v1
  let v2 = rx.tryRecv()
  assert v2.isSome and v2.get() == 20, "Expected 20, got " & $v2

  # Empty again
  assert rx.tryRecv().isNone, "Expected none after draining"

  echo "PASS: Broadcast: tryRecv non-blocking"

# ============================================================
# Test 8: Watch: initial value readable via borrow
# ============================================================

block testWatchBorrow:
  let ch = newWatch[string]("hello")
  let rx = ch.subscribe()
  let val = rx.borrow()
  assert val == "hello", "Expected hello, got " & val
  echo "PASS: Watch: initial value readable via borrow"

# ============================================================
# Test 9: Watch: recv blocks until value changes
# ============================================================

proc testWatchRecvSender(ch: WatchChannel[int]): CpsVoidFuture {.cps.} =
  await cpsSleep(20)
  ch.send(42)

proc testWatchRecvMain(): CpsFuture[int] {.cps.} =
  let ch = newWatch[int](0)
  let rx = ch.subscribe()
  # Consume initial value
  let initial = await rx.recv()
  assert initial == 0
  # Now recv should block until value changes
  let t = spawn testWatchRecvSender(ch)
  let val = await rx.recv()
  await t
  return val

block testWatchRecv:
  let result = runCps(testWatchRecvMain())
  assert result == 42, "Expected 42, got " & $result
  echo "PASS: Watch: recv blocks until value changes"

# ============================================================
# Test 10: Watch: multiple receivers all see latest value
# ============================================================

proc testWatchMultiMain(): CpsFuture[seq[int]] {.cps.} =
  let ch = newWatch[int](0)
  let rx1 = ch.subscribe()
  let rx2 = ch.subscribe()
  # Consume initial values
  discard await rx1.recv()
  discard await rx2.recv()
  ch.send(100)
  let v1 = await rx1.recv()
  let v2 = await rx2.recv()
  var results: seq[int]
  results.add(v1)
  results.add(v2)
  return results

block testWatchMulti:
  let results = runCps(testWatchMultiMain())
  assert results == @[100, 100], "Expected [100,100], got " & $results
  echo "PASS: Watch: multiple receivers all see latest value"

# ============================================================
# Test 11: Watch: hasChanged tracks version
# ============================================================

proc testWatchHasChangedMain(): CpsFuture[seq[bool]] {.cps.} =
  let ch = newWatch[int](0)
  let rx = ch.subscribe()
  var results: seq[bool]
  # Initially hasChanged is true (version 1 > lastVersion 0)
  results.add(rx.hasChanged())
  # Consume initial
  discard await rx.recv()
  # After recv, should NOT have changed
  results.add(rx.hasChanged())
  # Send a new value
  ch.send(10)
  # Now should have changed
  results.add(rx.hasChanged())
  # Consume it
  discard await rx.recv()
  # After recv, should NOT have changed
  results.add(rx.hasChanged())
  return results

block testWatchHasChanged:
  let results = runCps(testWatchHasChangedMain())
  assert results == @[true, false, true, false], "Expected [true,false,true,false], got " & $results
  echo "PASS: Watch: hasChanged tracks version"

# ============================================================
# Test 12: Watch: close wakes waiters
# ============================================================

proc testWatchCloseRecv(rx: WatchReceiver[int]): CpsFuture[bool] {.cps.} =
  # Consume initial value first
  discard await rx.recv()
  var gotError = false
  try:
    discard await rx.recv()
  except BroadcastClosed:
    gotError = true
  return gotError

proc testWatchCloseMain(): CpsFuture[bool] {.cps.} =
  let ch = newWatch[int](0)
  let rx = ch.subscribe()
  let t = spawn testWatchCloseRecv(rx)
  await cpsSleep(20)  # Let receiver consume initial and block on second recv
  ch.close()
  let res = await t
  return res

block testWatchClose:
  let result = runCps(testWatchCloseMain())
  assert result, "Expected BroadcastClosed on recv from closed watch channel"
  echo "PASS: Watch: close wakes waiters"

echo ""
echo "All broadcast and watch channel tests passed!"
