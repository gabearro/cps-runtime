## CPS Async Signal Handling
##
## Provides async signal handling using the self-pipe trick.
## A POSIX signal handler writes the signal number to a pipe,
## and the event loop reads it and dispatches to registered handlers.
##
## Usage:
##   initSignalHandling()
##   onSignal(SIGINT, proc() = echo "Got SIGINT")
##   let fut = waitForShutdown()
##   runCps(fut)
##   deinitSignalHandling()

import std/[posix, nativesockets]
import ../runtime
import ../eventloop

type
  SignalHandler* = proc() {.closure, gcsafe.}
    ## A callback invoked when a signal is received.

const MaxSignals = 64

var signalPipeFds: array[2, cint] = [-1.cint, -1.cint]  # [readEnd, writeEnd]
var signalHandlers: array[MaxSignals, seq[SignalHandler]]
var signalInitialized: bool = false

# One-shot handlers registered via waitForSignal. After firing once,
# they are removed to prevent accumulation.
var oneShotHandlers: array[MaxSignals, seq[SignalHandler]]

# ============================================================
# Internal: install/uninstall POSIX sigaction
# ============================================================

proc hasAnyHandler(sig: cint): bool =
  signalHandlers[sig].len > 0 or oneShotHandlers[sig].len > 0

# ============================================================
# POSIX signal trampoline (async-signal-safe)
# ============================================================

proc signalTrampoline(sig: cint) {.noconv.} =
  ## POSIX signal handler. Only uses async-signal-safe write().
  let b = uint8(sig)
  discard posix.write(signalPipeFds[1], unsafeAddr b, 1)

# ============================================================
# Pipe read callback for the event loop
# ============================================================

proc drainSignalPipe() =
  ## Read all pending signal bytes from the pipe and dispatch handlers.
  var buf: array[64, uint8]
  while true:
    let n = posix.read(signalPipeFds[0], addr buf[0], buf.len.cint)
    if n <= 0:
      break
    for i in 0 ..< n:
      let sig = cint(buf[i])
      if sig >= 0 and sig < MaxSignals:
        # Fire persistent handlers
        for handler in signalHandlers[sig]:
          handler()
        # Fire and remove one-shot handlers
        if oneShotHandlers[sig].len > 0:
          let oneShots = oneShotHandlers[sig]
          oneShotHandlers[sig] = @[]
          for handler in oneShots:
            handler()

# ============================================================
# Init / Deinit
# ============================================================

proc initSignalHandling*() =
  ## Create the self-pipe and register the read end with the event loop.
  ## Must be called before any onSignal/waitForSignal calls.
  if signalInitialized:
    return

  # Create the pipe
  var pipeFds: array[2, cint]
  if posix.pipe(pipeFds) != 0:
    raise newException(OSError, "Failed to create signal pipe")
  signalPipeFds[0] = pipeFds[0]  # read end
  signalPipeFds[1] = pipeFds[1]  # write end

  # Set both ends to non-blocking
  let rflags = posix.fcntl(signalPipeFds[0], F_GETFL, 0)
  discard posix.fcntl(signalPipeFds[0], F_SETFL, rflags or O_NONBLOCK)
  let wflags = posix.fcntl(signalPipeFds[1], F_GETFL, 0)
  discard posix.fcntl(signalPipeFds[1], F_SETFL, wflags or O_NONBLOCK)

  # Clear all handler lists
  for i in 0 ..< MaxSignals:
    signalHandlers[i] = @[]
    oneShotHandlers[i] = @[]

  # Register read end with event loop. The selector keeps the registration
  # active (persistent), so the callback fires each time data is available.
  let loop = getEventLoop()
  loop.registerRead(signalPipeFds[0].int, proc() {.closure.} =
    drainSignalPipe()
  )

  signalInitialized = true

proc deinitSignalHandling*() =
  ## Clean up signal handling: restore default signal handlers,
  ## unregister from the event loop, close the pipe.
  ## Completes all pending waitForSignal futures so they don't dangle.
  if not signalInitialized:
    return

  # Complete all pending one-shot futures so they don't dangle.
  # The handler checks `if not fut.finished` so double-complete is safe.
  for sig in 0 ..< MaxSignals:
    for handler in oneShotHandlers[sig]:
      handler()
    oneShotHandlers[sig] = @[]

  # Restore SIG_DFL for any signals we installed handlers for
  for sig in 0 ..< MaxSignals:
    if signalHandlers[sig].len > 0:
      var sa: Sigaction
      sa.sa_handler = SIG_DFL
      discard sigemptyset(sa.sa_mask)
      sa.sa_flags = 0
      discard sigaction(sig.cint, sa, nil)
      signalHandlers[sig] = @[]

  # Unregister from event loop and close pipe fds
  if signalPipeFds[0] >= 0:
    try:
      let loop = getEventLoop()
      loop.unregister(signalPipeFds[0].int)
    except Exception:
      discard
    discard posix.close(signalPipeFds[0])
    discard posix.close(signalPipeFds[1])
    signalPipeFds[0] = -1
    signalPipeFds[1] = -1

  signalInitialized = false

# ============================================================
# Signal registration
# ============================================================

proc onSignal*(sig: cint, handler: SignalHandler) =
  ## Register a handler for the given signal. Multiple handlers per signal
  ## are supported. The POSIX sigaction is installed on the first handler.
  assert signalInitialized, "Call initSignalHandling() first"
  assert sig >= 0 and sig < MaxSignals, "Signal number out of range"

  let isFirst = not hasAnyHandler(sig)
  signalHandlers[sig].add(handler)

  # Install the POSIX signal handler if this is the first handler for this signal
  if isFirst:
    var sa: Sigaction
    sa.sa_handler = signalTrampoline
    sa.sa_flags = SA_RESTART
    discard sigemptyset(sa.sa_mask)
    discard sigaction(sig, sa, nil)

proc removeSignalHandlers*(sig: cint) =
  ## Remove all handlers for the given signal and restore SIG_DFL.
  assert signalInitialized, "Call initSignalHandling() first"
  assert sig >= 0 and sig < MaxSignals, "Signal number out of range"

  signalHandlers[sig] = @[]
  oneShotHandlers[sig] = @[]

  # Restore default signal handling
  var sa: Sigaction
  sa.sa_handler = SIG_DFL
  discard sigemptyset(sa.sa_mask)
  sa.sa_flags = 0
  discard sigaction(sig, sa, nil)

# ============================================================
# Future-based signal waiting
# ============================================================

proc waitForSignal*(sig: cint): CpsVoidFuture =
  ## Returns a future that completes when the given signal is received.
  ## One-shot: the handler is removed after the signal fires.
  let fut = newCpsVoidFuture()

  let isFirst = not hasAnyHandler(sig)

  proc handler() {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      if not fut.finished:
        fut.complete()

  # Register only in oneShotHandlers (not signalHandlers) to avoid double-fire
  oneShotHandlers[sig].add(handler)

  # Install the POSIX signal handler if this is the first handler for this signal
  if isFirst:
    var sa: Sigaction
    sa.sa_handler = signalTrampoline
    sa.sa_flags = SA_RESTART
    discard sigemptyset(sa.sa_mask)
    discard sigaction(sig, sa, nil)

  result = fut

proc waitForShutdown*(): CpsVoidFuture =
  ## Returns a future that completes when SIGINT or SIGTERM is received.
  ## Installs handlers for both signals; the future completes on whichever
  ## fires first.
  let fut = newCpsVoidFuture()

  proc handler() {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      if not fut.finished:
        fut.complete()

  onSignal(SIGINT, handler)
  onSignal(SIGTERM, handler)
  result = fut
