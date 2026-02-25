## Cancellation-safety regression tests for async channels.

import std/options
import cps/runtime
import cps/concurrency/channels

block testCanceledReceiverDoesNotDropMessage:
  let ch = newAsyncChannel[int](1)

  let staleRecv = ch.recv()
  assert not staleRecv.finished
  staleRecv.cancel()
  assert staleRecv.isCancelled()

  assert ch.trySend(42), "trySend should succeed after skipping cancelled receiver"
  let got = ch.tryRecv()
  assert got.isSome and got.get() == 42,
    "Message should remain available for live receiver after cancelled receiver"
  echo "PASS: Cancelled receiver does not drop subsequent message"

block testCanceledSenderDoesNotInjectGhostValue:
  let ch = newAsyncChannel[int](1)
  assert ch.trySend(1), "Initial send should fill bounded channel"

  let staleSend = ch.send(99)
  assert not staleSend.finished
  staleSend.cancel()
  assert staleSend.isCancelled()

  let first = ch.tryRecv()
  assert first.isSome and first.get() == 1, "Expected original buffered value"

  let ghost = ch.tryRecv()
  assert ghost.isNone, "Cancelled sender value must not be injected later"
  echo "PASS: Cancelled sender does not inject ghost value"

block testCloseStillFailsLiveWaiters:
  let ch = newAsyncChannel[int](1)
  let liveRecv = ch.recv()
  let cancelledRecv = ch.recv()
  cancelledRecv.cancel()

  ch.close()

  assert liveRecv.finished and liveRecv.hasError() and liveRecv.getError() of ChannelClosed,
    "Live receiver waiter should fail with ChannelClosed"
  echo "PASS: close() keeps failing live waiters while skipping cancelled ones"


echo "All channel cancellation tests passed!"
