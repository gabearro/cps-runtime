## Tests for CPS async channels
##
## Verifies bounded/unbounded channels, blocking send/recv, non-blocking
## trySend/tryRecv, close semantics, and producer/consumer patterns.

import std/options
import cps/runtime
import cps/eventloop
import cps/transform
import cps/concurrency/channels

# ============================================================
# Test 1: Basic send/recv on bounded channel
# ============================================================

proc testBoundedBasicMain(): CpsFuture[int] {.cps.} =
  let ch = newAsyncChannel[int](10)
  await ch.send(42)
  let val = await ch.recv()
  return val

block testBoundedBasic:
  let result = runCps(testBoundedBasicMain())
  assert result == 42, "Expected 42, got " & $result
  echo "PASS: Basic send/recv on bounded channel"

# ============================================================
# Test 2: Basic send/recv on unbounded channel
# ============================================================

proc testUnboundedBasicMain(): CpsFuture[string] {.cps.} =
  let ch = newAsyncChannel[string]()
  await ch.send("hello")
  let val = await ch.recv()
  return val

block testUnboundedBasic:
  let result = runCps(testUnboundedBasicMain())
  assert result == "hello", "Expected hello, got " & result
  echo "PASS: Basic send/recv on unbounded channel"

# ============================================================
# Test 3: Buffered -- send multiple then recv multiple
# ============================================================

proc testBufferedMain(): CpsFuture[seq[int]] {.cps.} =
  let ch = newAsyncChannel[int](5)
  # Send 5 items (fills buffer)
  await ch.send(10)
  await ch.send(20)
  await ch.send(30)
  await ch.send(40)
  await ch.send(50)
  # Recv all 5
  var results: seq[int]
  let v1 = await ch.recv()
  results.add(v1)
  let v2 = await ch.recv()
  results.add(v2)
  let v3 = await ch.recv()
  results.add(v3)
  let v4 = await ch.recv()
  results.add(v4)
  let v5 = await ch.recv()
  results.add(v5)
  return results

block testBuffered:
  let results = runCps(testBufferedMain())
  assert results == @[10, 20, 30, 40, 50], "Expected [10,20,30,40,50], got " & $results
  echo "PASS: Buffered send multiple then recv multiple"

# ============================================================
# Test 4: Blocking recv on empty channel blocks until send
# ============================================================

proc testBlockingRecvProducer(ch: AsyncChannel[int]): CpsVoidFuture {.cps.} =
  await cpsSleep(20)
  await ch.send(99)

proc testBlockingRecvMain(ch: AsyncChannel[int]): CpsFuture[int] {.cps.} =
  let t = spawn testBlockingRecvProducer(ch)
  # This recv will block until the producer sends
  let val = await ch.recv()
  await t
  return val

block testBlockingRecv:
  let ch = newAsyncChannel[int](10)
  let result = runCps(testBlockingRecvMain(ch))
  assert result == 99, "Expected 99, got " & $result
  echo "PASS: Blocking recv on empty channel blocks until send"

# ============================================================
# Test 5: Blocking send on full bounded channel blocks until recv
# ============================================================

proc testBlockingSendConsumer(ch: AsyncChannel[int], results: ptr seq[int]): CpsVoidFuture {.cps.} =
  await cpsSleep(20)
  let v1 = await ch.recv()
  results[].add(v1)
  let v2 = await ch.recv()
  results[].add(v2)
  let v3 = await ch.recv()
  results[].add(v3)

proc testBlockingSendMain(ch: AsyncChannel[int], results: ptr seq[int]): CpsVoidFuture {.cps.} =
  let t = spawn testBlockingSendConsumer(ch, results)
  # Fill the buffer (capacity 2)
  await ch.send(1)
  await ch.send(2)
  # This third send will block because buffer is full
  await ch.send(3)
  await t

block testBlockingSend:
  let ch = newAsyncChannel[int](2)
  var received: seq[int] = @[]
  runCps(testBlockingSendMain(ch, addr received))
  assert received == @[1, 2, 3], "Expected [1,2,3], got " & $received
  echo "PASS: Blocking send on full bounded channel blocks until recv"

# ============================================================
# Test 6: Close -- recv on closed empty channel gets ChannelClosed
# ============================================================

proc testCloseRecvMain(): CpsFuture[bool] {.cps.} =
  let ch = newAsyncChannel[int](10)
  ch.close()
  var gotError = false
  try:
    discard await ch.recv()
  except ChannelClosed:
    gotError = true
  return gotError

block testCloseRecv:
  let result = runCps(testCloseRecvMain())
  assert result, "Expected ChannelClosed on recv from closed empty channel"
  echo "PASS: Close -- recv on closed empty channel gets ChannelClosed"

# ============================================================
# Test 7: Close -- send on closed channel gets ChannelClosed
# ============================================================

proc testCloseSendMain(): CpsFuture[bool] {.cps.} =
  let ch = newAsyncChannel[int](10)
  ch.close()
  var gotError = false
  try:
    await ch.send(42)
  except ChannelClosed:
    gotError = true
  return gotError

block testCloseSend:
  let result = runCps(testCloseSendMain())
  assert result, "Expected ChannelClosed on send to closed channel"
  echo "PASS: Close -- send on closed channel gets ChannelClosed"

# ============================================================
# Test 8: Close -- drain remaining items after close
# ============================================================

proc testCloseDrainMain(): CpsFuture[seq[int]] {.cps.} =
  let ch = newAsyncChannel[int](10)
  await ch.send(1)
  await ch.send(2)
  await ch.send(3)
  ch.close()
  # Should still be able to recv buffered items
  var results: seq[int]
  let v1 = await ch.recv()
  results.add(v1)
  let v2 = await ch.recv()
  results.add(v2)
  let v3 = await ch.recv()
  results.add(v3)
  return results

block testCloseDrain:
  let results = runCps(testCloseDrainMain())
  assert results == @[1, 2, 3], "Expected [1,2,3], got " & $results
  echo "PASS: Close -- drain remaining items after close"

# ============================================================
# Test 9: trySend/tryRecv non-blocking behavior
# ============================================================

block testTrySendRecv:
  # Bounded channel
  let ch = newAsyncChannel[int](2)

  # tryRecv on empty returns none
  assert ch.tryRecv().isNone, "Expected none on empty channel"

  # trySend succeeds when space available
  assert ch.trySend(10), "trySend should succeed"
  assert ch.trySend(20), "trySend should succeed"

  # trySend fails when full
  assert not ch.trySend(30), "trySend should fail on full channel"

  # tryRecv returns items in order
  let v1 = ch.tryRecv()
  assert v1.isSome and v1.get() == 10, "Expected 10, got " & $v1
  let v2 = ch.tryRecv()
  assert v2.isSome and v2.get() == 20, "Expected 20, got " & $v2

  # tryRecv on empty again
  assert ch.tryRecv().isNone, "Expected none after draining"

  # trySend on closed returns false
  ch.close()
  assert not ch.trySend(99), "trySend should fail on closed channel"

  echo "PASS: trySend/tryRecv non-blocking behavior"

# ============================================================
# Test 9b: trySend/tryRecv on unbounded channel
# ============================================================

block testTrySendRecvUnbounded:
  let ch = newAsyncChannel[int]()

  assert ch.tryRecv().isNone, "Expected none on empty unbounded"

  assert ch.trySend(1)
  assert ch.trySend(2)
  assert ch.trySend(3)

  let v1 = ch.tryRecv()
  assert v1.isSome and v1.get() == 1
  let v2 = ch.tryRecv()
  assert v2.isSome and v2.get() == 2
  let v3 = ch.tryRecv()
  assert v3.isSome and v3.get() == 3
  assert ch.tryRecv().isNone

  echo "PASS: trySend/tryRecv on unbounded channel"

# ============================================================
# Test 10: Multiple producers, single consumer
# ============================================================

proc testMultiProdProducer(ch: AsyncChannel[int], base: int): CpsVoidFuture {.cps.} =
  await ch.send(base + 1)
  await ch.send(base + 2)
  await ch.send(base + 3)

proc testMultiProdMain(ch: AsyncChannel[int]): CpsFuture[int] {.cps.} =
  # Spawn 3 producers
  let t1 = spawn testMultiProdProducer(ch, 0)
  let t2 = spawn testMultiProdProducer(ch, 10)
  let t3 = spawn testMultiProdProducer(ch, 20)

  # Consume all 9 items
  var total = 0
  var i = 0
  while i < 9:
    let val = await ch.recv()
    total = total + val
    i = i + 1

  await t1
  await t2
  await t3
  return total

block testMultipleProducers:
  let ch = newAsyncChannel[int](10)
  let total = runCps(testMultiProdMain(ch))
  # Sum: (1+2+3) + (11+12+13) + (21+22+23) = 6 + 36 + 66 = 108
  assert total == 108, "Expected 108, got " & $total
  echo "PASS: Multiple producers, single consumer"

# ============================================================
# Test 11: Channel with capacity=1 (synchronous handoff)
# ============================================================

proc testCap1Producer(ch: AsyncChannel[int]): CpsVoidFuture {.cps.} =
  await ch.send(100)
  await ch.send(200)
  await ch.send(300)

proc testCap1Main(ch: AsyncChannel[int]): CpsFuture[seq[int]] {.cps.} =
  let t = spawn testCap1Producer(ch)
  # Each recv unblocks the next send
  var received: seq[int]
  let v1 = await ch.recv()
  received.add(v1)
  let v2 = await ch.recv()
  received.add(v2)
  let v3 = await ch.recv()
  received.add(v3)
  await t
  return received

block testCapacity1:
  let ch = newAsyncChannel[int](1)
  let results = runCps(testCap1Main(ch))
  assert results == @[100, 200, 300], "Expected [100,200,300], got " & $results
  echo "PASS: Channel with capacity=1 (synchronous handoff)"

# ============================================================
# Test 12: Close wakes blocked receivers
# ============================================================

proc testCloseWakesRecvReceiver(ch: AsyncChannel[int]): CpsFuture[bool] {.cps.} =
  var gotError = false
  try:
    discard await ch.recv()
  except ChannelClosed:
    gotError = true
  return gotError

proc testCloseWakesRecvMain(ch: AsyncChannel[int]): CpsFuture[bool] {.cps.} =
  let t = spawn testCloseWakesRecvReceiver(ch)
  # Give the receiver time to block
  await cpsSleep(20)
  ch.close()
  let res = await t
  return res

block testCloseWakesReceivers:
  let ch = newAsyncChannel[int](10)
  let result = runCps(testCloseWakesRecvMain(ch))
  assert result, "Expected blocked receiver to get ChannelClosed"
  echo "PASS: Close wakes blocked receivers"

# ============================================================
# Test 13: Close wakes blocked senders
# ============================================================

proc testCloseWakesSendSender(ch: AsyncChannel[int]): CpsFuture[bool] {.cps.} =
  var gotError = false
  await ch.send(1)  # fills buffer
  try:
    await ch.send(2)  # blocks (buffer full)
  except ChannelClosed:
    gotError = true
  return gotError

proc testCloseWakesSendMain(ch: AsyncChannel[int]): CpsFuture[bool] {.cps.} =
  let t = spawn testCloseWakesSendSender(ch)
  await cpsSleep(20)
  ch.close()
  let res = await t
  return res

block testCloseWakesSenders:
  let ch = newAsyncChannel[int](1)
  let result = runCps(testCloseWakesSendMain(ch))
  assert result, "Expected blocked sender to get ChannelClosed"
  echo "PASS: Close wakes blocked senders"

# ============================================================
# Test 14: len and capacity
# ============================================================

block testLenCapacity:
  let ch = newAsyncChannel[int](5)
  assert ch.capacity == 5
  assert ch.len == 0

  discard ch.trySend(1)
  assert ch.len == 1
  discard ch.trySend(2)
  assert ch.len == 2

  discard ch.tryRecv()
  assert ch.len == 1

  let uch = newAsyncChannel[int]()
  assert uch.capacity == 0
  assert uch.len == 0

  discard uch.trySend(1)
  assert uch.len == 1

  echo "PASS: len and capacity"

# ============================================================
# Test 15: tryRecv drains after close
# ============================================================

block testTryRecvAfterClose:
  let ch = newAsyncChannel[int](10)
  discard ch.trySend(10)
  discard ch.trySend(20)
  ch.close()

  # Can still drain buffered items
  let v1 = ch.tryRecv()
  assert v1.isSome and v1.get() == 10
  let v2 = ch.tryRecv()
  assert v2.isSome and v2.get() == 20
  # Empty now
  assert ch.tryRecv().isNone

  echo "PASS: tryRecv drains after close"

# ============================================================
# Test 16: trySend with waiting receiver does direct handoff
# ============================================================

proc testTrySendHandoffReceiver(ch: AsyncChannel[int]): CpsFuture[int] {.cps.} =
  return await ch.recv()

proc testTrySendHandoffMain(ch: AsyncChannel[int]): CpsFuture[int] {.cps.} =
  # Spawn receiver first -- it will block
  let t = spawn testTrySendHandoffReceiver(ch)
  await cpsYield()  # let receiver run and block

  # Now trySend should hand off directly to the blocked receiver
  assert ch.trySend(77)
  let res = await t
  return res

block testTrySendHandoff:
  let ch = newAsyncChannel[int](10)
  let val = runCps(testTrySendHandoffMain(ch))
  assert val == 77, "Expected 77, got " & $val
  echo "PASS: trySend with waiting receiver does direct handoff"

echo ""
echo "All channel tests passed!"
