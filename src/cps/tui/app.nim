## CPS TUI - Application Framework
##
## High-level application loop that integrates the widget system with the
## CPS event loop. Handles the render cycle, input routing, focus management,
## and terminal lifecycle (raw mode, alt screen, cleanup on exit).
##
## Usage:
##   let app = newTuiApp()
##   app.onRender = proc(width, height: int): Widget =
##     vbox(
##       text("Hello, TUI!"),
##       inputField(myText, myCursor).withFocus(true),
##     )
##   app.onInput = proc(evt: InputEvent): bool =
##     # Handle input, return true to re-render
##     ...
##   runCps(app.run())

import ../runtime
import ../transform
import ../eventloop
import ./style
import ./cell
import ./input
import ./layout
import ./widget
import ./renderer
import ./events
when not defined(posix):
  {.error: "TUI requires POSIX terminal support. Not available on Windows.".}
import std/[posix, monotimes]

type
  RenderProc* = proc(width, height: int): Widget
  InputHandler* = proc(evt: InputEvent): bool
  TickHandler* = proc(): bool

  TuiApp* = ref object
    ## The main TUI application object.
    terminal*: Terminal
    running*: bool

    # User callbacks
    onRender*: RenderProc
    onInput*: InputHandler
    onTick*: TickHandler       ## Called every tick (for animations, etc.)

    # Rendering state
    frontBuf: CellBuffer
    backBuf: CellBuffer
    needsRender*: bool
    fullRedraw*: bool

    # Event routing
    hitMap*: HitMap
    focus*: FocusManager
    eventRouting*: bool        ## Enable declarative event routing (default true)

    # Configuration
    altScreen*: bool           ## Use alternate screen buffer (default true)
    mouseMode*: bool           ## Enable mouse tracking (default false)
    cursorVisible*: bool       ## Show cursor (default false)
    targetFps*: int            ## Target render rate (default 30)
    title*: string             ## Terminal title

    # Stats
    frameCount*: int64
    lastFrameTime*: MonoTime

# ============================================================
# Construction
# ============================================================

proc newTuiApp*(): TuiApp =
  let term = newTerminal()
  TuiApp(
    terminal: term,
    running: false,
    frontBuf: newCellBuffer(term.width, term.height),
    backBuf: newCellBuffer(term.width, term.height),
    needsRender: true,
    fullRedraw: true,
    focus: newFocusManager(),
    eventRouting: true,
    altScreen: true,
    mouseMode: false,
    cursorVisible: false,
    targetFps: 30,
  )

# ============================================================
# Terminal setup / teardown
# ============================================================

proc writeOutput(data: string) =
  ## Write directly to stdout (low-level, unbuffered).
  ## Loops to handle partial writes and retries on EINTR.
  ## Also handles EAGAIN/EWOULDBLOCK: STDIN is set to non-blocking mode
  ## for async input, and on Unix terminals STDIN and STDOUT share the
  ## same file description, so STDOUT becomes non-blocking too. When the
  ## PTY write buffer is full, write() returns EAGAIN — we must poll for
  ## writability and retry, otherwise the frame output is truncated
  ## (causing "vertical rip" artifacts on split view resize).
  ##
  ## The tuiWriteInProgress guard tells the SIGWINCH signal handler to
  ## skip its immediate clearScreen if we're mid-write, avoiding
  ## interleaved output.
  if data.len > 0:
    tuiWriteInProgress = true
    var written = 0
    while written < data.len:
      let n = write(STDOUT_FILENO, unsafeAddr data[written], (data.len - written).cint)
      if n > 0:
        written += n
      elif n < 0:
        let err = errno
        if err == EINTR:
          continue  # Interrupted by signal — retry
        if err == EAGAIN or err == EWOULDBLOCK:
          # PTY buffer full — wait until STDOUT is writable, then retry.
          var pfd: TPollfd
          pfd.fd = STDOUT_FILENO
          pfd.events = POLLOUT
          discard poll(addr pfd, 1, 100)  # Wait up to 100ms
          continue
        break  # Truly unrecoverable error
      else:
        break  # Zero bytes written — fd closed
    tuiWriteInProgress = false

proc setup(app: TuiApp) =
  app.terminal.enterRawMode()
  initWakePipe()
  installSigwinchHandler()

  var initSeq = ""
  if app.altScreen:
    initSeq.add(enterAltScreen)
  if not app.cursorVisible:
    initSeq.add(hideCursor)
  if app.mouseMode:
    initSeq.add(enableMouse)
    app.terminal.mouseEnabled = true
  initSeq.add(enableBracketedPaste)
  app.terminal.bracketedPaste = true
  initSeq.add(disableAutoWrap)
  initSeq.add(clearScreen)

  if app.title.len > 0:
    initSeq.add("\e]0;" & app.title & "\a")

  writeOutput(initSeq)

proc teardown(app: TuiApp) =
  var cleanupSeq = ""
  if app.mouseMode:
    cleanupSeq.add(disableMouse)
  cleanupSeq.add(disableBracketedPaste)
  cleanupSeq.add(enableAutoWrap)
  if not app.cursorVisible:
    cleanupSeq.add(showCursor)
  if app.altScreen:
    cleanupSeq.add(leaveAltScreen)
  cleanupSeq.add(resetAnsi)

  writeOutput(cleanupSeq)
  closeWakePipe()
  unregisterStdin()
  app.terminal.leaveRawMode()

# ============================================================
# Rendering
# ============================================================

proc doRender(app: TuiApp) =
  if app.onRender == nil:
    return

  # Re-query terminal size via ioctl for the absolute latest dimensions.
  # During rapid resize (drag), SIGWINCH may have fired with an intermediate
  # size that's already stale by the time we render.
  let (curCols, curRows) = getTerminalSize()
  if curCols != app.terminal.width or curRows != app.terminal.height:
    app.terminal.width = curCols
    app.terminal.height = curRows
    app.fullRedraw = true

  let w = app.terminal.width
  let h = app.terminal.height
  let isResize = app.backBuf.width != w or app.backBuf.height != h

  # Ensure buffers match terminal size
  if isResize:
    app.backBuf = newCellBuffer(w, h)
    app.frontBuf = newCellBuffer(w, h)
    app.fullRedraw = true
  else:
    app.backBuf.clear()

  # Build widget tree and render
  let root = app.onRender(w, h)
  let rootRect = Rect(x: 0, y: 0, w: w, h: h)

  if app.eventRouting:
    # Clear and rebuild hit map + focus order each frame
    app.hitMap.clear()
    app.focus.clear()
    renderWidgetWithEvents(app.backBuf, root, rootRect,
                           app.hitMap, app.focus)
  else:
    renderWidget(app.backBuf, root, rootRect)

  # Produce output wrapped in synchronized update to prevent tearing.
  # Terminals that support DEC mode 2026 (iTerm2, Kitty, WezTerm, etc.)
  # buffer all output between begin/end markers and render atomically.
  # Terminals that don't support it simply ignore the escape sequences.
  var output: string
  if app.fullRedraw:
    # On resize, clear the screen first to prevent stale content from the
    # old dimensions showing at wrong positions during drag resize.
    if isResize:
      output = clearScreen & render(app.backBuf)
    else:
      output = render(app.backBuf)
    app.fullRedraw = false
  else:
    output = diff(app.frontBuf, app.backBuf)

  if output.len > 0:
    # Re-assert DECAWM off every frame — some terminals reset modes on resize.
    writeOutput(beginSyncUpdate & disableAutoWrap & output & endSyncUpdate)

  # Swap buffers
  swap(app.frontBuf, app.backBuf)
  app.needsRender = false
  app.lastFrameTime = getMonoTime()
  inc app.frameCount

proc requestRender*(app: TuiApp) =
  ## Mark the app as needing a re-render on the next frame.
  app.needsRender = true

proc requestFullRedraw*(app: TuiApp) =
  ## Force a complete screen redraw on the next frame.
  ## Use this when the layout changes significantly (e.g., split view drag).
  app.needsRender = true
  app.fullRedraw = true

proc stop*(app: TuiApp) =
  ## Signal the app to stop.
  app.running = false

# ============================================================
# Main event loop (CPS)
# ============================================================

proc run*(app: TuiApp): CpsVoidFuture {.cps.} =
  ## Main application loop. Runs until app.stop() is called.
  ##
  ## Fully event-driven. Each iteration awaits tuiWaitFrame() which
  ## completes instantly when:
  ##   - Stdin has data (user input — zero latency)
  ##   - Wake pipe fires (SIGWINCH / tuiWake — zero latency)
  ##   - Frame timer expires (picks up background state changes)
  ##
  ## While waiting, the event loop's selector monitors ALL fds (TCP
  ## sockets, DNS, timers, etc.), so background CPS tasks make full
  ## progress on every tick.
  ##
  ## This is a CPS proc — call it with runCps(app.run()).
  app.running = true
  app.setup()

  try:
    # Register the wake pipe (for SIGWINCH / tuiWake) and stdin
    # (for instant input response) with the event loop.
    registerWakePipe()
    registerStdinForFrame()

    # Initial render
    app.doRender()

    let frameIntervalMs = 1000 div max(1, app.targetFps)

    while app.running:
      # Wait for the next event: stdin data, wake pipe, or frame timeout.
      # The selector monitors all fds, so background tasks (IRC, DNS, etc.)
      # make progress during this wait.
      await tuiWaitFrame(frameIntervalMs)

      # Non-blocking input check — grab whatever stdin data is available.
      let events: seq[InputEvent] = tryReadInput()

      # Check for terminal resize.
      # The SIGWINCH handler already cleared the screen instantly (to prevent
      # reflow artifacts). Here we just mark for a full redraw.
      if app.terminal.checkResize():
        app.fullRedraw = true
        app.needsRender = true

      # Process input events
      for evt in events:
        # Built-in quit handler: Ctrl+C
        if evt.isCtrl('c'):
          app.running = false
          break

        # Try declarative event routing first
        var handled = false
        if app.eventRouting:
          try:
            handled = routeEvent(app.hitMap, app.focus, evt)
            if handled:
              app.needsRender = true
          except Exception:
            discard  # Don't crash the app on event routing errors

        # Fallback to imperative onInput handler
        if not handled and app.onInput != nil:
          try:
            let needsRedraw = app.onInput(evt)
            if needsRedraw:
              app.needsRender = true
          except Exception:
            discard  # Don't crash the app on input handler errors

      # Tick callback (for animations, timers, etc.)
      if app.onTick != nil:
        try:
          if app.onTick():
            app.needsRender = true
        except Exception:
          discard  # Don't crash the app on tick handler errors

      # Render if needed
      if app.needsRender and app.running:
        try:
          app.doRender()
        except Exception:
          discard  # Don't crash the app on render errors
  finally:
    app.teardown()

# ============================================================
# Simple run helper
# ============================================================

proc runTui*(renderFn: RenderProc, inputFn: InputHandler = nil,
             tickFn: TickHandler = nil,
             altScreen: bool = true, mouseMode: bool = false,
             title: string = "", targetFps: int = 30) =
  ## Convenience proc to create and run a TUI app.
  let app = newTuiApp()
  app.onRender = renderFn
  app.onInput = inputFn
  app.onTick = tickFn
  app.altScreen = altScreen
  app.mouseMode = mouseMode
  app.title = title
  app.targetFps = targetFps
  runCps(app.run())
