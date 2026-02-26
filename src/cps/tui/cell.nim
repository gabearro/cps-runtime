## CPS TUI - Cell Buffer
##
## A 2D grid of styled cells representing the terminal screen content.
## Supports double-buffering: render to a back buffer, then diff against
## the front buffer to produce minimal terminal output.

import ./style

type
  Cell* = object
    ## A single character cell on screen.
    ch*: string       ## UTF-8 character (may be multi-byte, or "" for continuation)
    style*: Style     ## Visual style
    width*: int       ## Display width (1 for normal, 2 for wide chars, 0 for continuation)

  CellBuffer* = object
    ## 2D grid of cells representing terminal content.
    width*: int
    height*: int
    cells*: seq[Cell]

const emptyCell* = Cell(ch: " ", style: styleDefault, width: 1)

# ============================================================
# CellBuffer operations
# ============================================================

proc newCellBuffer*(width, height: int): CellBuffer =
  result.width = width
  result.height = height
  result.cells = newSeq[Cell](width * height)
  for i in 0 ..< result.cells.len:
    result.cells[i] = emptyCell

proc idx(buf: CellBuffer, x, y: int): int {.inline.} =
  y * buf.width + x

proc inBounds*(buf: CellBuffer, x, y: int): bool {.inline.} =
  x >= 0 and x < buf.width and y >= 0 and y < buf.height

proc `[]`*(buf: CellBuffer, x, y: int): Cell {.inline.} =
  if buf.inBounds(x, y):
    buf.cells[buf.idx(x, y)]
  else:
    emptyCell

proc `[]=`*(buf: var CellBuffer, x, y: int, cell: Cell) {.inline.} =
  if buf.inBounds(x, y):
    buf.cells[buf.idx(x, y)] = cell

proc setCell*(buf: var CellBuffer, x, y: int, ch: string, s: Style = styleDefault) =
  ## Set a single cell. Empty ch is normalized to " " to prevent cursor
  ## positioning errors in the render output.
  if buf.inBounds(x, y):
    let c = if ch.len == 0: " " else: ch
    buf.cells[buf.idx(x, y)] = Cell(ch: c, style: s, width: 1)

proc clear*(buf: var CellBuffer) =
  for i in 0 ..< buf.cells.len:
    buf.cells[i] = emptyCell

proc clear*(buf: var CellBuffer, s: Style) =
  ## Clear with a specific style (e.g., background color).
  for i in 0 ..< buf.cells.len:
    buf.cells[i] = Cell(ch: " ", style: s, width: 1)

proc resize*(buf: var CellBuffer, newWidth, newHeight: int) =
  ## Resize the buffer, preserving content where possible.
  if newWidth == buf.width and newHeight == buf.height:
    return
  var newBuf = newCellBuffer(newWidth, newHeight)
  let copyW = min(buf.width, newWidth)
  let copyH = min(buf.height, newHeight)
  for y in 0 ..< copyH:
    for x in 0 ..< copyW:
      newBuf[x, y] = buf[x, y]
  buf = newBuf

proc fill*(buf: var CellBuffer, x, y, w, h: int, ch: string = " ", s: Style = styleDefault) =
  ## Fill a rectangular region.
  for row in y ..< min(y + h, buf.height):
    for col in x ..< min(x + w, buf.width):
      buf.setCell(col, row, ch, s)

# ============================================================
# Text writing
# ============================================================

proc runeWidth*(ch: char): int {.inline.} =
  ## Approximate display width. For full Unicode width, a lookup table
  ## is needed; this handles ASCII + common cases.
  if ch.ord < 32: 0
  else: 1

proc writeStr*(buf: var CellBuffer, x, y: int, text: string, s: Style = styleDefault) =
  ## Write a string starting at (x, y), clipping at buffer edges.
  ## Does not wrap. Tabs expand to 4 spaces.
  if y < 0 or y >= buf.height:
    return
  var col = x
  var i = 0
  while i < text.len and col < buf.width:
    if text[i] == '\t':
      # Expand tab to spaces
      let tabStop = 4
      let spaces = tabStop - (col mod tabStop)
      for j in 0 ..< spaces:
        if col < buf.width and col >= 0:
          buf.setCell(col, y, " ", s)
        inc col
      inc i
    elif text[i].ord < 0x80:
      # ASCII
      if col >= 0:
        buf.setCell(col, y, $text[i], s)
      inc col
      inc i
    else:
      # Multi-byte UTF-8: collect the full codepoint
      var runeLen = 1
      if (text[i].ord and 0xE0) == 0xC0: runeLen = 2
      elif (text[i].ord and 0xF0) == 0xE0: runeLen = 3
      elif (text[i].ord and 0xF8) == 0xF0: runeLen = 4
      let rune = text[i ..< min(i + runeLen, text.len)]
      if col >= 0:
        buf.setCell(col, y, rune, s)
      inc col
      i += runeLen

proc writeStrClip*(buf: var CellBuffer, x, y, maxWidth: int, text: string,
                   s: Style = styleDefault) =
  ## Write a string clipped to maxWidth characters.
  if y < 0 or y >= buf.height or maxWidth <= 0:
    return
  var col = x
  let limit = min(x + maxWidth, buf.width)
  var i = 0
  while i < text.len and col < limit:
    if text[i] == '\t':
      let tabStop = 4
      let spaces = tabStop - (col mod tabStop)
      for j in 0 ..< spaces:
        if col < limit and col >= 0:
          buf.setCell(col, y, " ", s)
        inc col
      inc i
    elif text[i].ord < 0x80:
      if col >= 0:
        buf.setCell(col, y, $text[i], s)
      inc col
      inc i
    else:
      var runeLen = 1
      if (text[i].ord and 0xE0) == 0xC0: runeLen = 2
      elif (text[i].ord and 0xF0) == 0xE0: runeLen = 3
      elif (text[i].ord and 0xF8) == 0xF0: runeLen = 4
      let rune = text[i ..< min(i + runeLen, text.len)]
      if col >= 0:
        buf.setCell(col, y, rune, s)
      inc col
      i += runeLen

# ============================================================
# Rendering (double buffering)
# ============================================================

proc render*(buf: CellBuffer): string =
  ## Full render of the buffer (no diffing, used for initial draw).
  ##
  ## Each row starts with moveTo + clearLine to erase any content left
  ## by terminal reflow during resize. After writing the last character
  ## of each row, we send CUB (cursor backward) to cancel the terminal's
  ## "pending wrap" state — without this, if the buffer is wider than the
  ## actual terminal (race during resize), writing at the last column
  ## triggers auto-wrap, which cascades into scroll and shifts all
  ## subsequent absolute moveTo positions, corrupting the bottom rows
  ## (chatbox, help bar). CUB is harmless when no pending wrap exists.
  result = ""
  var lastStyle = styleDefault
  var styleActive = false

  for y in 0 ..< buf.height:
    result.add(moveTo(0, y))
    result.add(clearLine)
    for x in 0 ..< buf.width:
      let c = buf[x, y]
      if c.style != lastStyle or not styleActive:
        result.add(resetAnsi)
        result.add(c.style.toAnsi())
        lastStyle = c.style
        styleActive = true
      result.add(c.ch)
    # Cancel pending wrap after last character to prevent scroll cascade.
    if buf.width > 0:
      result.add("\e[D")

  if styleActive:
    result.add(resetAnsi)

proc diff*(front, back: CellBuffer): string =
  ## Compare two buffers and produce output to update the terminal.
  ## Always uses full sequential render — the diff approach (only updating
  ## changed cells via scattered moveTo sequences) causes terminal desync
  ## when the layout shifts: the terminal's actual display state can diverge
  ## from the front buffer if output isn't processed atomically (no sync
  ## update support, write buffering, SSH latency). Full render is ~3KB/frame
  ## for 80x24, negligible overhead, and always produces correct output.
  assert front.width == back.width and front.height == back.height,
    "Buffers must be same size for diff"

  # Quick check: if buffers are identical, skip entirely
  var identical = true
  let totalCells = back.width * back.height
  for i in 0 ..< totalCells:
    if front.cells[i].ch != back.cells[i].ch or
       front.cells[i].style != back.cells[i].style:
      identical = false
      break

  if identical:
    return ""

  return render(back)
