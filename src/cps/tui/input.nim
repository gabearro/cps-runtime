## CPS TUI - Terminal Input
##
## Async terminal input reading with raw mode support.
## Parses ANSI escape sequences into structured key/mouse events.
## Integrates with the CPS event loop via selector-based fd monitoring.

import ../runtime
import ../transform
import ../eventloop
import std/[posix, termios, strutils]

var SIGWINCH {.importc, header: "<signal.h>", nodecl.}: cint

type
  KeyCode* = enum
    kcChar           ## Regular character
    kcEnter
    kcTab
    kcBackspace
    kcEscape
    kcUp
    kcDown
    kcLeft
    kcRight
    kcHome
    kcEnd
    kcPageUp
    kcPageDown
    kcInsert
    kcDelete
    kcF1, kcF2, kcF3, kcF4, kcF5, kcF6
    kcF7, kcF8, kcF9, kcF10, kcF11, kcF12

  MouseButton* = enum
    mbLeft
    mbMiddle
    mbRight
    mbScrollUp
    mbScrollDown
    mbNone

  MouseAction* = enum
    maPress
    maRelease
    maMotion

  InputEventKind* = enum
    iekKey
    iekMouse
    iekResize
    iekPaste
    iekUnknown

  KeyMod* = enum
    kmShift
    kmAlt
    kmCtrl
    kmSuper

  InputEvent* = object
    case kind*: InputEventKind
    of iekKey:
      key*: KeyCode
      ch*: char          ## The character (for kcChar)
      keyMods*: set[KeyMod]
    of iekMouse:
      button*: MouseButton
      action*: MouseAction
      mx*, my*: int      ## 0-based coordinates
      mouseMods*: set[KeyMod]
    of iekResize:
      cols*, rows*: int
    of iekPaste:
      pasteText*: string
    of iekUnknown:
      rawBytes*: string

  TerminalMode* = enum
    tmCooked       ## Normal line-buffered mode
    tmRaw          ## Raw mode (character-at-a-time, no echo)

  Terminal* = ref object
    ## Terminal state manager. Handles raw mode, input parsing,
    ## and screen output.
    mode*: TerminalMode
    origTermios: Termios
    savedMode: bool
    width*, height*: int
    mouseEnabled*: bool
    bracketedPaste*: bool

# ============================================================
# Terminal size
# ============================================================

type Winsize = object
  ws_row: cushort
  ws_col: cushort
  ws_xpixel: cushort
  ws_ypixel: cushort

const TIOCGWINSZ = 0x40087468'u  # macOS value; Linux is the same

proc ioctl(fd: cint, request: culong, argp: pointer): cint
  {.importc, header: "<sys/ioctl.h>".}

proc getTerminalSize*(): tuple[cols, rows: int] =
  var ws: Winsize
  if ioctl(STDOUT_FILENO, TIOCGWINSZ.culong, addr ws) == 0:
    result = (ws.ws_col.int, ws.ws_row.int)
  else:
    # Fallback
    result = (80, 24)

# ============================================================
# Raw mode
# ============================================================

proc newTerminal*(): Terminal =
  let (cols, rows) = getTerminalSize()
  Terminal(
    mode: tmCooked,
    savedMode: false,
    width: cols,
    height: rows,
    mouseEnabled: false,
    bracketedPaste: false,
  )

proc enterRawMode*(term: Terminal) =
  ## Switch terminal to raw mode (no echo, character-at-a-time).
  if term.mode == tmRaw:
    return
  discard tcGetAttr(STDIN_FILENO, addr term.origTermios)
  term.savedMode = true
  var raw = term.origTermios
  raw.c_iflag = raw.c_iflag and not (BRKINT or ICRNL or INPCK or ISTRIP or IXON)
  raw.c_oflag = raw.c_oflag and not (OPOST)
  raw.c_cflag = raw.c_cflag or CS8
  raw.c_lflag = raw.c_lflag and not (ECHO or ICANON or IEXTEN or ISIG)
  raw.c_cc[VMIN] = 0.char
  raw.c_cc[VTIME] = 0.char
  discard tcSetAttr(STDIN_FILENO, TCSAFLUSH, addr raw)
  term.mode = tmRaw

proc leaveRawMode*(term: Terminal) =
  ## Restore terminal to its original mode.
  if term.mode == tmCooked:
    return
  if term.savedMode:
    discard tcSetAttr(STDIN_FILENO, TCSAFLUSH, addr term.origTermios)
  term.mode = tmCooked

# ============================================================
# Input parsing
# ============================================================

proc parseCsiSequence(buf: string, pos: var int): InputEvent =
  ## Parse a CSI (Control Sequence Introducer) escape sequence.
  ## buf[pos-1] was '[', pos points to next char.
  var params: seq[int] = @[]
  var currentParam = 0
  var hasParam = false
  var isSgr = false

  # Collect numeric params separated by ';'
  while pos < buf.len:
    let c = buf[pos]
    if c >= '0' and c <= '9':
      currentParam = currentParam * 10 + (c.ord - '0'.ord)
      hasParam = true
      inc pos
    elif c == ';':
      params.add(if hasParam: currentParam else: 0)
      currentParam = 0
      hasParam = false
      inc pos
    elif c == '<':
      # SGR mouse mode prefix
      isSgr = true
      inc pos
    else:
      break

  if hasParam:
    params.add(currentParam)

  if pos >= buf.len:
    return InputEvent(kind: iekUnknown, rawBytes: buf)

  let final = buf[pos]
  inc pos

  # Parse modifiers from param (CSI 1;mod~ or CSI mod A)
  var mods: set[KeyMod] = {}
  var modParam = 0
  if params.len >= 2:
    modParam = params[1] - 1
  elif params.len == 1 and final in {'A'..'D', 'H', 'F'}:
    modParam = params[0] - 1

  if (modParam and 1) != 0: mods.incl(kmShift)
  if (modParam and 2) != 0: mods.incl(kmAlt)
  if (modParam and 4) != 0: mods.incl(kmCtrl)
  if (modParam and 8) != 0: mods.incl(kmSuper)

  # SGR mouse: CSI < button ; x ; y M/m
  if isSgr and params.len >= 3 and final in {'M', 'm'}:
    let btn = params[0]
    let mx = params[1] - 1  # 1-based → 0-based
    let my = params[2] - 1
    var button = mbNone
    var mouseMods: set[KeyMod] = {}
    if (btn and 4) != 0: mouseMods.incl(kmShift)
    if (btn and 8) != 0: mouseMods.incl(kmAlt)
    if (btn and 16) != 0: mouseMods.incl(kmCtrl)
    let btnId = btn and 0x43  # bits 0-1 + bit 6
    case btnId
    of 0: button = mbLeft
    of 1: button = mbMiddle
    of 2: button = mbRight
    of 64: button = mbScrollUp
    of 65: button = mbScrollDown
    else: button = mbNone
    let action = if final == 'M':
      if (btn and 32) != 0: maMotion else: maPress
    else: maRelease
    return InputEvent(kind: iekMouse, button: button, action: action,
                      mx: mx, my: my, mouseMods: mouseMods)

  case final
  of 'A': return InputEvent(kind: iekKey, key: kcUp, keyMods: mods)
  of 'B': return InputEvent(kind: iekKey, key: kcDown, keyMods: mods)
  of 'C': return InputEvent(kind: iekKey, key: kcRight, keyMods: mods)
  of 'D': return InputEvent(kind: iekKey, key: kcLeft, keyMods: mods)
  of 'H': return InputEvent(kind: iekKey, key: kcHome, keyMods: mods)
  of 'F': return InputEvent(kind: iekKey, key: kcEnd, keyMods: mods)
  of 'Z': return InputEvent(kind: iekKey, key: kcTab, keyMods: {kmShift})
  of '~':
    if params.len >= 1:
      case params[0]
      of 1: return InputEvent(kind: iekKey, key: kcHome, keyMods: mods)
      of 2: return InputEvent(kind: iekKey, key: kcInsert, keyMods: mods)
      of 3: return InputEvent(kind: iekKey, key: kcDelete, keyMods: mods)
      of 4: return InputEvent(kind: iekKey, key: kcEnd, keyMods: mods)
      of 5: return InputEvent(kind: iekKey, key: kcPageUp, keyMods: mods)
      of 6: return InputEvent(kind: iekKey, key: kcPageDown, keyMods: mods)
      of 11: return InputEvent(kind: iekKey, key: kcF1, keyMods: mods)
      of 12: return InputEvent(kind: iekKey, key: kcF2, keyMods: mods)
      of 13: return InputEvent(kind: iekKey, key: kcF3, keyMods: mods)
      of 14: return InputEvent(kind: iekKey, key: kcF4, keyMods: mods)
      of 15: return InputEvent(kind: iekKey, key: kcF5, keyMods: mods)
      of 17: return InputEvent(kind: iekKey, key: kcF6, keyMods: mods)
      of 18: return InputEvent(kind: iekKey, key: kcF7, keyMods: mods)
      of 19: return InputEvent(kind: iekKey, key: kcF8, keyMods: mods)
      of 20: return InputEvent(kind: iekKey, key: kcF9, keyMods: mods)
      of 21: return InputEvent(kind: iekKey, key: kcF10, keyMods: mods)
      of 23: return InputEvent(kind: iekKey, key: kcF11, keyMods: mods)
      of 24: return InputEvent(kind: iekKey, key: kcF12, keyMods: mods)
      of 200: return InputEvent(kind: iekPaste, pasteText: "")  # Bracket paste start
      of 201: return InputEvent(kind: iekPaste, pasteText: "")  # Bracket paste end
      else: discard
  else: discard

  return InputEvent(kind: iekUnknown, rawBytes: "\e[" & buf[pos-1 .. pos-1])

proc parseSs3Sequence(buf: string, pos: var int): InputEvent =
  ## Parse SS3 (ESC O) sequence for function/arrow keys.
  if pos >= buf.len:
    return InputEvent(kind: iekUnknown, rawBytes: "\eO")
  let c = buf[pos]
  inc pos
  case c
  of 'A': InputEvent(kind: iekKey, key: kcUp)
  of 'B': InputEvent(kind: iekKey, key: kcDown)
  of 'C': InputEvent(kind: iekKey, key: kcRight)
  of 'D': InputEvent(kind: iekKey, key: kcLeft)
  of 'H': InputEvent(kind: iekKey, key: kcHome)
  of 'F': InputEvent(kind: iekKey, key: kcEnd)
  of 'P': InputEvent(kind: iekKey, key: kcF1)
  of 'Q': InputEvent(kind: iekKey, key: kcF2)
  of 'R': InputEvent(kind: iekKey, key: kcF3)
  of 'S': InputEvent(kind: iekKey, key: kcF4)
  else: InputEvent(kind: iekUnknown, rawBytes: "\eO" & $c)

proc parseInputEvents*(data: string): seq[InputEvent] =
  ## Parse raw terminal input bytes into structured events.
  ## Handles bracketed paste mode: accumulates all bytes between CSI 200~
  ## (paste start) and CSI 201~ (paste end) into a single iekPaste event.
  result = @[]
  var pos = 0
  var inPaste = false
  var pasteAccum = ""
  while pos < data.len:
    let c = data[pos]

    # Check for paste end marker while accumulating paste data
    if inPaste:
      # Look for ESC [ 2 0 1 ~ (the paste-end sequence)
      if c == '\e' and pos + 5 < data.len and
         data[pos+1] == '[' and data[pos+2] == '2' and
         data[pos+3] == '0' and data[pos+4] == '1' and data[pos+5] == '~':
        # End of paste
        result.add(InputEvent(kind: iekPaste, pasteText: pasteAccum))
        pasteAccum = ""
        inPaste = false
        pos += 6
        continue
      # Accumulate paste content
      pasteAccum.add(c)
      inc pos
      continue

    if c == '\e':
      inc pos
      if pos >= data.len:
        result.add(InputEvent(kind: iekKey, key: kcEscape))
        continue

      case data[pos]
      of '[':
        inc pos
        let evt = parseCsiSequence(data, pos)
        # Check if this is a paste-start marker (CSI 200~)
        if evt.kind == iekPaste and not inPaste:
          inPaste = true
          pasteAccum = ""
          continue
        result.add(evt)
      of 'O':
        inc pos
        result.add(parseSs3Sequence(data, pos))
      else:
        # Alt+key (ESC prefix)
        let altCh = data[pos]
        inc pos
        if altCh.ord == 127 or altCh.ord == 8:
          # Alt+Backspace (ESC DEL or ESC BS)
          result.add(InputEvent(kind: iekKey, key: kcBackspace, keyMods: {kmAlt}))
        elif altCh.ord == 13 or altCh.ord == 10:
          # Alt+Enter
          result.add(InputEvent(kind: iekKey, key: kcEnter, keyMods: {kmAlt}))
        elif altCh.ord == 9:
          # Alt+Tab
          result.add(InputEvent(kind: iekKey, key: kcTab, keyMods: {kmAlt}))
        elif altCh.ord < 32:
          # Alt+Ctrl+letter
          let letter = chr(altCh.ord + 64)
          result.add(InputEvent(kind: iekKey, key: kcChar, ch: letter.toLowerAscii,
                                keyMods: {kmAlt, kmCtrl}))
        else:
          result.add(InputEvent(kind: iekKey, key: kcChar, ch: altCh,
                                keyMods: {kmAlt}))

    elif c.ord == 13 or c.ord == 10:
      result.add(InputEvent(kind: iekKey, key: kcEnter))
      inc pos
    elif c.ord == 9:
      result.add(InputEvent(kind: iekKey, key: kcTab))
      inc pos
    elif c.ord == 127 or c.ord == 8:
      result.add(InputEvent(kind: iekKey, key: kcBackspace))
      inc pos
    elif c.ord < 32:
      # Ctrl+letter
      let letter = chr(c.ord + 64)
      result.add(InputEvent(kind: iekKey, key: kcChar, ch: letter.toLowerAscii,
                            keyMods: {kmCtrl}))
      inc pos
    else:
      # Regular character
      result.add(InputEvent(kind: iekKey, key: kcChar, ch: c))
      inc pos

  # If paste started but didn't end (data split across reads), emit what we have
  if inPaste and pasteAccum.len > 0:
    result.add(InputEvent(kind: iekPaste, pasteText: pasteAccum))

# ============================================================
# Async input reader (CPS)
# ============================================================

var stdinRegistered = false
var stdinNonBlocking = false
var stdinOrigFlags: cint = 0
var stdinPendingFut: CpsFuture[string] = nil
var stdinReadSize: int = 256

proc ensureStdinNonBlocking() =
  if not stdinNonBlocking:
    stdinOrigFlags = fcntl(STDIN_FILENO, F_GETFL)
    discard fcntl(STDIN_FILENO, F_SETFL, stdinOrigFlags or O_NONBLOCK)
    stdinNonBlocking = true

proc stdinOnReadable() =
  ## Callback fired when stdin becomes readable via selector.
  if stdinPendingFut == nil:
    return
  var data = newString(stdinReadSize)
  let bytesRead = read(STDIN_FILENO, addr data[0], stdinReadSize.cint)
  if bytesRead > 0:
    data.setLen(bytesRead)
    let f = stdinPendingFut
    stdinPendingFut = nil
    f.complete(data)
  elif bytesRead == 0:
    let f = stdinPendingFut
    stdinPendingFut = nil
    f.complete("")
  # If EAGAIN, leave fut pending — selector will fire again when data arrives

proc readInputRaw*(readSize: int = 256): CpsFuture[string] =
  ## Read raw bytes from stdin asynchronously using the event loop selector.
  let fut = newCpsFuture[string]()
  let loop = getEventLoop()

  ensureStdinNonBlocking()
  stdinReadSize = readSize

  # Try to read immediately (non-blocking)
  var buf = newString(readSize)
  let n = read(STDIN_FILENO, addr buf[0], readSize.cint)
  if n > 0:
    buf.setLen(n)
    fut.complete(buf)
  elif n == 0:
    fut.complete("")
  else:
    let err = errno
    if err == EAGAIN or err == EWOULDBLOCK:
      # No data available; register stdin if needed, set pending future
      stdinPendingFut = fut
      if not stdinRegistered:
        loop.registerRead(STDIN_FILENO.int, stdinOnReadable)
        stdinRegistered = true
      # else: already registered — selector will fire stdinOnReadable when data arrives
    else:
      fut.complete("")
  result = fut

proc unregisterStdin*() =
  ## Unregister stdin from the event loop and restore blocking mode.
  if stdinRegistered:
    try:
      let loop = getEventLoop()
      loop.unregister(STDIN_FILENO.int)
    except Exception:
      discard
    stdinRegistered = false
  if stdinNonBlocking:
    discard fcntl(STDIN_FILENO, F_SETFL, stdinOrigFlags)
    stdinNonBlocking = false

proc readInput*(readSize: int = 256): CpsFuture[seq[InputEvent]] {.cps.} =
  ## Read and parse input events from the terminal asynchronously.
  let raw: string = await readInputRaw(readSize)
  if raw.len == 0:
    return @[]
  return parseInputEvents(raw)

# ============================================================
# SIGWINCH handling
# ============================================================

var sigwinchPending* = false

proc sigwinchHandler(sig: cint) {.noconv.} =
  sigwinchPending = true

proc installSigwinchHandler*() =
  ## Install a signal handler for SIGWINCH (terminal resize).
  var sa: Sigaction
  sa.sa_handler = sigwinchHandler
  discard sigemptyset(sa.sa_mask)
  sa.sa_flags = SA_RESTART
  discard sigaction(SIGWINCH, sa, nil)

proc checkResize*(term: Terminal): bool =
  ## Check if the terminal was resized. Returns true if size changed.
  if sigwinchPending:
    sigwinchPending = false
    let (cols, rows) = getTerminalSize()
    if cols != term.width or rows != term.height:
      term.width = cols
      term.height = rows
      return true
  return false

# ============================================================
# Convenience: key matching
# ============================================================

proc isChar*(evt: InputEvent, c: char): bool =
  evt.kind == iekKey and evt.key == kcChar and evt.ch == c and evt.keyMods == {}

proc isCtrl*(evt: InputEvent, c: char): bool =
  evt.kind == iekKey and evt.key == kcChar and evt.ch == c and kmCtrl in evt.keyMods

proc isKey*(evt: InputEvent, k: KeyCode): bool =
  evt.kind == iekKey and evt.key == k and evt.keyMods == {}

proc isKeyMod*(evt: InputEvent, k: KeyCode, mods: set[KeyMod]): bool =
  evt.kind == iekKey and evt.key == k and evt.keyMods == mods

proc `$`*(evt: InputEvent): string =
  case evt.kind
  of iekKey:
    if evt.key == kcChar:
      var prefix = ""
      if kmSuper in evt.keyMods: prefix.add("Super+")
      if kmCtrl in evt.keyMods: prefix.add("Ctrl+")
      if kmAlt in evt.keyMods: prefix.add("Alt+")
      if kmShift in evt.keyMods: prefix.add("Shift+")
      prefix & $evt.ch
    else:
      var prefix = ""
      if kmSuper in evt.keyMods: prefix.add("Super+")
      if kmCtrl in evt.keyMods: prefix.add("Ctrl+")
      if kmAlt in evt.keyMods: prefix.add("Alt+")
      if kmShift in evt.keyMods: prefix.add("Shift+")
      prefix & $evt.key
  of iekMouse:
    "Mouse(" & $evt.button & " " & $evt.action & " " & $evt.mx & "," & $evt.my & ")"
  of iekResize:
    "Resize(" & $evt.cols & "x" & $evt.rows & ")"
  of iekPaste:
    "Paste(" & $evt.pasteText.len & " chars)"
  of iekUnknown:
    "Unknown(" & $evt.rawBytes.len & " bytes)"
