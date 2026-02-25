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
import std/[posix, os, monotimes, times]

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
  if data.len > 0:
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

proc setup(app: TuiApp) =
  app.terminal.enterRawMode()
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
  initSeq.add(clearScreen)

  if app.title.len > 0:
    initSeq.add("\e]0;" & app.title & "\a")

  writeOutput(initSeq)

proc teardown(app: TuiApp) =
  var cleanupSeq = ""
  if app.mouseMode:
    cleanupSeq.add(disableMouse)
  cleanupSeq.add(disableBracketedPaste)
  if not app.cursorVisible:
    cleanupSeq.add(showCursor)
  if app.altScreen:
    cleanupSeq.add(leaveAltScreen)
  cleanupSeq.add(resetAnsi)

  writeOutput(cleanupSeq)
  unregisterStdin()
  app.terminal.leaveRawMode()

# ============================================================
# Rendering
# ============================================================

proc doRender(app: TuiApp) =
  if app.onRender == nil:
    return

  let w = app.terminal.width
  let h = app.terminal.height

  # Ensure buffers match terminal size
  if app.backBuf.width != w or app.backBuf.height != h:
    app.backBuf = newCellBuffer(w, h)
    app.frontBuf = newCellBuffer(w, h)
    app.fullRedraw = true
  else:
    app.backBuf.clear()

  # Build widget tree and render
  let root = app.onRender(w, h)
  let rootRect = Rect(x: 0, y: 0, w: w, h: h)
  renderWidget(app.backBuf, root, rootRect)

  # Produce output wrapped in synchronized update to prevent tearing.
  # Terminals that support DEC mode 2026 (iTerm2, Kitty, WezTerm, etc.)
  # buffer all output between begin/end markers and render atomically.
  # Terminals that don't support it simply ignore the escape sequences.
  var output: string
  if app.fullRedraw:
    output = render(app.backBuf)
    app.fullRedraw = false
  else:
    output = diff(app.frontBuf, app.backBuf)

  if output.len > 0:
    writeOutput(beginSyncUpdate & output & endSyncUpdate)

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
  ## This is a CPS proc — call it with runCps(app.run()).
  app.running = true
  app.setup()

  try:
    # Initial render
    app.doRender()

    let frameIntervalMs = 1000 div max(1, app.targetFps)

    while app.running:
      # Read input (non-blocking via event loop)
      let events: seq[InputEvent] = await readInput()

      # Check for terminal resize
      if app.terminal.checkResize():
        app.fullRedraw = true
        app.needsRender = true

      # Process input events
      for evt in events:
        # Built-in quit handler: Ctrl+C
        if evt.isCtrl('c'):
          app.running = false
          break

        if app.onInput != nil:
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

      # Yield to event loop for a frame interval (allows I/O processing)
      if app.running:
        await cpsSleep(frameIntervalMs)
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
