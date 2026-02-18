## Tests for CPS async signal handling

import std/posix
import cps/runtime
import cps/eventloop
import cps/concurrency/signals

# ============================================================
# Test 1: SIGUSR1 handler fires when signal sent to self
# ============================================================

block testSignalHandler:
  initSignalHandling()

  var handlerFired = false
  onSignal(SIGUSR1, proc() {.closure, gcsafe.} =
    handlerFired = true
  )

  # Send SIGUSR1 to ourselves
  discard kill(getpid(), SIGUSR1)

  # Drive the event loop to process the signal pipe.
  # The signal handler writes to the pipe; we need the event loop to read it.
  # Use a small timer to ensure we give the event loop a chance to tick.
  let fut = cpsSleep(50)
  runCps(fut)

  assert handlerFired, "SIGUSR1 handler should have fired"
  echo "PASS: SIGUSR1 handler fires"

  removeSignalHandlers(SIGUSR1)
  deinitSignalHandling()

# ============================================================
# Test 2: waitForSignal with SIGUSR1
# ============================================================

block testWaitForSignal:
  initSignalHandling()

  var signalReceived = false

  # Set up: schedule a signal send after a short delay
  let loop = getEventLoop()
  loop.registerTimer(30, proc() =
    discard kill(getpid(), SIGUSR1)
  )

  let sigFut = waitForSignal(SIGUSR1)
  sigFut.addCallback(proc() =
    signalReceived = true
  )

  # Drive the event loop until the signal is received (or timeout)
  let timeoutFut = cpsSleep(500)
  while not sigFut.finished and not timeoutFut.finished:
    loop.tick()

  assert sigFut.finished, "waitForSignal future should have completed"
  assert signalReceived, "Signal callback should have fired"
  echo "PASS: waitForSignal with SIGUSR1"

  removeSignalHandlers(SIGUSR1)
  deinitSignalHandling()

# ============================================================
# Test 3: Multiple handlers for same signal
# ============================================================

block testMultipleHandlers:
  initSignalHandling()

  var count = 0
  onSignal(SIGUSR1, proc() {.closure, gcsafe.} =
    count += 1
  )
  onSignal(SIGUSR1, proc() {.closure, gcsafe.} =
    count += 10
  )

  discard kill(getpid(), SIGUSR1)

  let fut = cpsSleep(50)
  runCps(fut)

  assert count == 11, "Both handlers should have fired, got count=" & $count
  echo "PASS: Multiple handlers for same signal"

  removeSignalHandlers(SIGUSR1)
  deinitSignalHandling()

# ============================================================
# Test 4: removeSignalHandlers
# ============================================================

block testRemoveHandlers:
  initSignalHandling()

  var handlerFired = false
  onSignal(SIGUSR1, proc() {.closure, gcsafe.} =
    handlerFired = true
  )

  # Remove before sending the signal
  removeSignalHandlers(SIGUSR1)

  # Send signal - since we restored SIG_DFL for SIGUSR1 (which terminates),
  # we need to ignore it instead. Re-install SIG_IGN.
  var sa: Sigaction
  sa.sa_handler = SIG_IGN
  discard sigemptyset(sa.sa_mask)
  sa.sa_flags = 0
  discard sigaction(SIGUSR1, sa, nil)

  discard kill(getpid(), SIGUSR1)

  let fut = cpsSleep(50)
  runCps(fut)

  assert not handlerFired, "Handler should not have fired after removal"
  echo "PASS: removeSignalHandlers"

  # Restore default for SIGUSR1
  sa.sa_handler = SIG_DFL
  discard sigaction(SIGUSR1, sa, nil)

  deinitSignalHandling()

# ============================================================
# Test 5: waitForShutdown with SIGTERM sent to self
# ============================================================

block testWaitForShutdown:
  initSignalHandling()

  var shutdownReceived = false

  let loop = getEventLoop()
  loop.registerTimer(30, proc() =
    discard kill(getpid(), SIGTERM)
  )

  let shutFut = waitForShutdown()
  shutFut.addCallback(proc() =
    shutdownReceived = true
  )

  let timeoutFut = cpsSleep(500)
  while not shutFut.finished and not timeoutFut.finished:
    loop.tick()

  assert shutFut.finished, "waitForShutdown future should have completed"
  assert shutdownReceived, "Shutdown callback should have fired"
  echo "PASS: waitForShutdown with SIGTERM"

  removeSignalHandlers(SIGINT)
  removeSignalHandlers(SIGTERM)
  deinitSignalHandling()

echo "All signal tests passed!"
