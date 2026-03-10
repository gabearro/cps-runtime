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

when not defined(posix):
  {.error: "Signal handling requires POSIX. Not available on Windows.".}

import std/[posix, os]
import ../runtime
import ../eventloop

type
  SignalHandler* = proc() {.closure, gcsafe.}
    ## A callback invoked when a signal is received.

const MaxSignals = 64

var signalPipeFds: array[2, cint] = [-1.cint, -1.cint]  # [readEnd, writeEnd]
var signalHandlers: array[MaxSignals, seq[SignalHandler]]
var signalInitialized: bool = false
var oneShotHandlers: array[MaxSignals, seq[SignalHandler]]

# ============================================================
# Internal helpers
# ============================================================

proc setNonBlocking(fd: cint) =
  let flags = posix.fcntl(fd, F_GETFL)
  if flags < 0:
    raiseOSError(osLastError())
  if posix.fcntl(fd, F_SETFL, flags or O_NONBLOCK) < 0:
    raiseOSError(osLastError())

proc restoreDefault(sig: cint) =
  var sa: Sigaction
  sa.sa_handler = SIG_DFL
  sa.sa_flags = 0
  discard sigemptyset(sa.sa_mask)
  discard sigaction(sig, sa, nil)

# ============================================================
# POSIX signal trampoline (async-signal-safe)
# ============================================================

proc signalTrampoline(sig: cint) {.noconv.} =
  ## POSIX signal handler. Only uses async-signal-safe write().
  if sig >= 0 and sig < MaxSignals:
    let b = uint8(sig)
    discard posix.write(signalPipeFds[1], unsafeAddr b, 1)

proc installTrampoline(sig: cint) =
  var sa: Sigaction
  sa.sa_handler = signalTrampoline
  sa.sa_flags = SA_RESTART
  discard sigemptyset(sa.sa_mask)
  discard sigaction(sig, sa, nil)

proc hasAnyHandler(sig: cint): bool =
  signalHandlers[sig].len > 0 or oneShotHandlers[sig].len > 0

proc ensureTrampoline(sig: cint) =
  ## Install the POSIX sigaction trampoline if no handler exists yet.
  if not hasAnyHandler(sig):
    installTrampoline(sig)

# ============================================================
# Pipe read callback for the event loop
# ============================================================

proc drainSignalPipe() =
  ## Read all pending signal bytes from the pipe and schedule handlers.
  var buf: array[64, uint8]
  let loop = getEventLoop()
  while true:
    let n = posix.read(signalPipeFds[0], addr buf[0], buf.len.cint)
    if n <= 0:
      break
    for i in 0 ..< n:
      let sig = cint(buf[i])
      if sig < MaxSignals:
        for handler in signalHandlers[sig]:
          let h = handler
          loop.scheduleCallback(h)
        if oneShotHandlers[sig].len > 0:
          let oneShots = move(oneShotHandlers[sig])
          for handler in oneShots:
            let h = handler
            loop.scheduleCallback(h)

# ============================================================
# Init / Deinit
# ============================================================

proc initSignalHandling*() =
  ## Create the self-pipe and register the read end with the event loop.
  ## Must be called before any onSignal/waitForSignal calls.
  if signalInitialized:
    return

  var pipeFds: array[2, cint]
  if posix.pipe(pipeFds) != 0:
    raise newException(OSError, "Failed to create signal pipe")
  signalPipeFds[0] = pipeFds[0]  # read end
  signalPipeFds[1] = pipeFds[1]  # write end

  setNonBlocking(signalPipeFds[0])
  setNonBlocking(signalPipeFds[1])

  let loop = getEventLoop()
  loop.registerRead(signalPipeFds[0].int, proc() {.closure.} =
    drainSignalPipe()
  )

  signalInitialized = true

proc deinitSignalHandling*() =
  ## Clean up: restore default signal handlers, unregister from the
  ## event loop, close the pipe. Completes pending waitForSignal futures.
  if not signalInitialized:
    return

  for sig in 0 ..< MaxSignals:
    # Fire one-shot handlers so pending futures don't dangle
    for handler in oneShotHandlers[sig]:
      handler()
    oneShotHandlers[sig] = @[]

    if signalHandlers[sig].len > 0:
      restoreDefault(sig.cint)
      signalHandlers[sig] = @[]

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
  ## Register a persistent handler for the given signal. Multiple handlers
  ## per signal are supported. The POSIX sigaction is installed on first use.
  assert signalInitialized, "Call initSignalHandling() first"
  assert sig >= 0 and sig < MaxSignals, "Signal number out of range"

  ensureTrampoline(sig)
  signalHandlers[sig].add(handler)

proc removeSignalHandlers*(sig: cint) =
  ## Remove all handlers for the given signal and restore SIG_DFL.
  assert signalInitialized, "Call initSignalHandling() first"
  assert sig >= 0 and sig < MaxSignals, "Signal number out of range"

  signalHandlers[sig] = @[]
  oneShotHandlers[sig] = @[]
  restoreDefault(sig)

# ============================================================
# Future-based signal waiting
# ============================================================

proc waitForSignal*(sig: cint): CpsVoidFuture =
  ## Returns a future that completes when the given signal is received.
  ## One-shot: the handler is removed after the signal fires.
  assert signalInitialized, "Call initSignalHandling() first"
  assert sig >= 0 and sig < MaxSignals, "Signal number out of range"

  let fut = newCpsVoidFuture()

  ensureTrampoline(sig)

  proc handler() {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      if not fut.finished:
        fut.complete()

  oneShotHandlers[sig].add(handler)
  result = fut

proc waitForShutdown*(): CpsVoidFuture =
  ## Returns a future that completes when SIGINT or SIGTERM is received.
  ## One-shot: handlers are removed after the first signal fires.
  assert signalInitialized, "Call initSignalHandling() first"

  let fut = newCpsVoidFuture()

  proc handler() {.closure, gcsafe.} =
    {.cast(gcsafe).}:
      if not fut.finished:
        fut.complete()

  ensureTrampoline(SIGINT)
  oneShotHandlers[SIGINT].add(handler)

  ensureTrampoline(SIGTERM)
  oneShotHandlers[SIGTERM].add(handler)

  result = fut
