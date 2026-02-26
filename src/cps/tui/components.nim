## CPS TUI - Higher-Level Components
##
## Pre-built composite widgets for common TUI patterns:
## - Split views (horizontal/vertical with draggable divider)
## - Scrollable text view (chat log, log viewer)
## - Status bar
## - Dialog / modal overlay
## - Notification area
## - Command palette
## - Tree view
## These are built on top of the core widget primitives.

import ./style
import ./cell
import ./layout
import ./widget
import ./renderer
import ./input
import ./textinput
import std/[strutils, times, math]

# ============================================================
# Split View
# ============================================================

type
  SplitView* = ref object
    ## A split view with two panes and a draggable divider.
    direction*: Direction
    ratio*: float          ## 0.0 to 1.0 — fraction for the first pane
    minFirst*: int         ## Minimum size of first pane
    minSecond*: int        ## Minimum size of second pane
    dividerStyle*: Style
    dividerChar*: string   ## Character for the divider line
    dragging*: bool
    lastRect*: Rect        ## Set during render for mouse hit-testing

proc newSplitView*(direction: Direction = dirHorizontal,
                   ratio: float = 0.5,
                   minFirst: int = 5, minSecond: int = 5): SplitView =
  SplitView(
    direction: direction,
    ratio: clamp(ratio, 0.0, 1.0),
    minFirst: minFirst,
    minSecond: minSecond,
    dividerStyle: style(clBrightBlack),
    dividerChar: if direction == dirHorizontal: "│" else: "─",
    dragging: false,
  )

proc computeFirstSize*(sv: SplitView, usable: int): int =
  ## Compute the first pane's size in pixels from the ratio.
  ## Shared between toWidget and handleMouse so they always agree.
  if usable <= 0:
    return 0
  let raw = int(round(sv.ratio * float(usable)))
  clamp(raw, min(sv.minFirst, usable), max(0, usable - sv.minSecond))

proc handleMouse*(sv: SplitView, evt: InputEvent, rect: Rect): bool =
  ## Handle mouse events for divider dragging. Returns true if ratio changed.
  if evt.kind != iekMouse:
    return false
  case sv.direction
  of dirHorizontal:
    let usable = max(0, rect.w - 1)  # Subtract divider column
    let firstW = sv.computeFirstSize(usable)
    let dividerX = rect.x + firstW
    case evt.action
    of maPress:
      if evt.mx >= dividerX - 1 and evt.mx <= dividerX + 1 and
         evt.my >= rect.y and evt.my < rect.y + rect.h:
        sv.dragging = true
        return false
    of maMotion:
      if sv.dragging:
        let newRatio = if usable > 0: float(evt.mx - rect.x) / float(usable)
                       else: 0.5
        let clamped = clamp(newRatio,
          float(sv.minFirst) / float(max(1, usable)),
          1.0 - float(sv.minSecond) / float(max(1, usable)))
        if clamped != sv.ratio:
          sv.ratio = clamped
          return true
    of maRelease:
      sv.dragging = false
  of dirVertical:
    let usable = max(0, rect.h - 1)
    let firstH = sv.computeFirstSize(usable)
    let dividerY = rect.y + firstH
    case evt.action
    of maPress:
      if evt.my >= dividerY - 1 and evt.my <= dividerY + 1 and
         evt.mx >= rect.x and evt.mx < rect.x + rect.w:
        sv.dragging = true
        return false
    of maMotion:
      if sv.dragging:
        let newRatio = if usable > 0: float(evt.my - rect.y) / float(usable)
                       else: 0.5
        let clamped = clamp(newRatio,
          float(sv.minFirst) / float(max(1, usable)),
          1.0 - float(sv.minSecond) / float(max(1, usable)))
        if clamped != sv.ratio:
          sv.ratio = clamped
          return true
    of maRelease:
      sv.dragging = false
  return false

proc adjustRatio*(sv: SplitView, delta: float) =
  sv.ratio = clamp(sv.ratio + delta, 0.1, 0.9)

proc toWidget*(sv: SplitView, first, second: Widget): Widget =
  ## Render the split view with direct pixel computation.
  ## Bypasses flex layout to avoid floating-point truncation mismatch
  ## between handleMouse and the layout engine.
  let svRef = sv
  let firstChild = first
  let secondChild = second
  custom(proc(buf: var CellBuffer, rect: Rect) =
    case svRef.direction
    of dirHorizontal:
      let usable = max(0, rect.w - 1)
      let firstSize = svRef.computeFirstSize(usable)
      let secondSize = usable - firstSize
      # Render first pane
      if firstSize > 0:
        renderWidget(buf, firstChild, Rect(x: rect.x, y: rect.y, w: firstSize, h: rect.h))
      # Draw divider
      let divX = rect.x + firstSize
      for y in rect.y ..< rect.y + rect.h:
        buf.setCell(divX, y, svRef.dividerChar, svRef.dividerStyle)
      # Render second pane
      if secondSize > 0:
        renderWidget(buf, secondChild, Rect(x: divX + 1, y: rect.y, w: secondSize, h: rect.h))
    of dirVertical:
      let usable = max(0, rect.h - 1)
      let firstSize = svRef.computeFirstSize(usable)
      let secondSize = usable - firstSize
      # Render first pane
      if firstSize > 0:
        renderWidget(buf, firstChild, Rect(x: rect.x, y: rect.y, w: rect.w, h: firstSize))
      # Draw divider
      let divY = rect.y + firstSize
      for x in rect.x ..< rect.x + rect.w:
        buf.setCell(x, divY, svRef.dividerChar, svRef.dividerStyle)
      # Render second pane
      if secondSize > 0:
        renderWidget(buf, secondChild, Rect(x: rect.x, y: divY + 1, w: rect.w, h: secondSize))
  )

# ============================================================
# Scrollable Text View (chat log, etc.)
# ============================================================

type
  TextPos* = object
    ## A position in the text view: line index and column offset.
    line*: int
    col*: int

  StyledSpan* = object
    ## A span of text with a specific style (for mIRC colors, URLs, etc.)
    text*: string
    style*: Style

  LineEntry* = object
    text*: string
    style*: Style
    timestamp*: string
    spans*: seq[StyledSpan]  ## Optional: styled spans (overrides `style` when non-empty)

  VisualRow* = object
    ## A single visual (screen) row produced by wrapping a logical line.
    lineIdx*: int           ## Index into lines[]
    spans*: seq[StyledSpan] ## Styled spans for this row
    text*: string           ## Plain text for this row
    style*: Style           ## Fallback style (used when spans is empty)
    isFirstRow*: bool       ## True for the first visual row of a logical line

  ScrollableTextView* = ref object
    ## A scrollable text view — suitable for chat logs, log viewers, etc.
    lines*: seq[LineEntry]
    scrollOffset*: int
    autoScroll*: bool       ## Auto-scroll to bottom on new content
    maxLines*: int          ## Maximum lines to keep (0 = unlimited)
    wrapMode*: TextWrap
    showTimestamps*: bool
    timestampStyle*: Style
    lastRect*: Rect         ## Set during render for mouse hit-testing
    lastTotalVisualRows*: int  ## Total visual rows after wrapping (set during render)
    lastMsgColWidth*: int      ## Cached message column width for mouse mapping
    # Selection state
    selecting*: bool        ## True while dragging a selection
    selAnchor*: TextPos     ## Where the drag started (line index in lines[])
    selCursor*: TextPos     ## Where the drag currently is
    hasSelection*: bool     ## True if a completed selection exists
    tsColWidth: int         ## Cached timestamp column width for coordinate mapping

proc newScrollableTextView*(maxLines: int = 0,
                            autoScroll: bool = true,
                            wrapMode: TextWrap = twNone): ScrollableTextView =
  ScrollableTextView(
    lines: @[],
    scrollOffset: 0,
    autoScroll: autoScroll,
    maxLines: maxLines,
    wrapMode: wrapMode,
    showTimestamps: false,
    timestampStyle: style(clBrightBlack),
  )

proc wrapSpans*(spans: seq[StyledSpan], width: int): seq[seq[StyledSpan]] =
  ## Split styled spans across multiple visual rows at character boundaries.
  ## Each returned row is a list of spans fitting within `width` chars.
  if width <= 0:
    return @[spans]
  var currentRow: seq[StyledSpan] = @[]
  var currentRowLen = 0
  result = @[]
  for span in spans:
    var pos = 0
    while pos < span.text.len:
      let remaining = width - currentRowLen
      if remaining <= 0:
        result.add(currentRow)
        currentRow = @[]
        currentRowLen = 0
        continue
      let chunkLen = min(remaining, span.text.len - pos)
      currentRow.add(StyledSpan(text: span.text[pos ..< pos + chunkLen], style: span.style))
      currentRowLen += chunkLen
      pos += chunkLen
      if currentRowLen >= width and pos < span.text.len:
        result.add(currentRow)
        currentRow = @[]
        currentRowLen = 0
  # Add final row (even if empty — represents at least one visual row)
  result.add(currentRow)

proc wrapPlainText(text: string, width: int, st: Style): seq[VisualRow] =
  ## Wrap plain text into visual rows at character boundaries.
  if width <= 0 or text.len == 0:
    return @[VisualRow(text: "", style: st, isFirstRow: true)]
  result = @[]
  var pos = 0
  var first = true
  while pos < text.len:
    let endPos = min(pos + width, text.len)
    result.add(VisualRow(text: text[pos ..< endPos], style: st, isFirstRow: first))
    first = false
    pos = endPos
  if result.len == 0:
    result.add(VisualRow(text: "", style: st, isFirstRow: true))

proc buildVisualRows*(sv: ScrollableTextView, msgColWidth: int): seq[VisualRow] =
  ## Build a flat list of visual rows from all logical lines, applying wrapping.
  result = @[]
  if msgColWidth <= 0:
    return
  for lineIdx in 0 ..< sv.lines.len:
    let entry = sv.lines[lineIdx]
    if sv.wrapMode == twNone or msgColWidth <= 0:
      # No wrapping: 1 logical line → 1 visual row
      result.add(VisualRow(
        lineIdx: lineIdx, spans: entry.spans, text: entry.text,
        style: entry.style, isFirstRow: true,
      ))
    elif entry.spans.len > 0:
      # Wrap styled spans
      let wrappedRows = wrapSpans(entry.spans, msgColWidth)
      for i, rowSpans in wrappedRows:
        var plainText = ""
        for sp in rowSpans:
          plainText.add(sp.text)
        result.add(VisualRow(
          lineIdx: lineIdx, spans: rowSpans, text: plainText,
          style: entry.style, isFirstRow: (i == 0),
        ))
    else:
      # Wrap plain text
      let rows = wrapPlainText(entry.text, msgColWidth, entry.style)
      for i, row in rows:
        var vr = row
        vr.lineIdx = lineIdx
        vr.isFirstRow = (i == 0)
        result.add(vr)

proc visualRowCount*(entry: LineEntry, msgColWidth: int, wrapMode: TextWrap): int =
  ## Return how many visual rows a line needs.
  if wrapMode == twNone or msgColWidth <= 0:
    return 1
  let textLen = if entry.spans.len > 0:
    var total = 0
    for sp in entry.spans:
      total += sp.text.len
    total
  else:
    entry.text.len
  max(1, (textLen + msgColWidth - 1) div msgColWidth)

proc scrollToBottom*(sv: ScrollableTextView) =
  # Use lastTotalVisualRows if available (post-render), otherwise lines.len
  let total = if sv.lastTotalVisualRows > 0: sv.lastTotalVisualRows
              else: sv.lines.len
  sv.scrollOffset = max(0, total)  # Will be clamped during render

proc addLine*(sv: ScrollableTextView, text: string,
              st: Style = styleDefault, timestamp: string = "",
              spans: seq[StyledSpan] = @[]) =
  sv.lines.add(LineEntry(text: text, style: st, timestamp: timestamp, spans: spans))
  if sv.maxLines > 0 and sv.lines.len > sv.maxLines:
    let excess = sv.lines.len - sv.maxLines
    for i in 0 ..< excess:
      sv.lines.delete(0)
    sv.scrollOffset = max(0, sv.scrollOffset - excess)
  if sv.autoScroll:
    sv.scrollToBottom()

proc addTimestampedLine*(sv: ScrollableTextView, text: string,
                         st: Style = styleDefault) =
  let ts = now().format("HH:mm:ss")
  sv.addLine(text, st, ts)

proc scrollUp*(sv: ScrollableTextView, amount: int = 1) =
  sv.scrollOffset = max(0, sv.scrollOffset - amount)
  sv.autoScroll = false

proc scrollDown*(sv: ScrollableTextView, amount: int = 1, visibleHeight: int = 0) =
  let totalRows = if sv.lastTotalVisualRows > 0: sv.lastTotalVisualRows
                  else: sv.lines.len
  sv.scrollOffset = min(max(0, totalRows - 1), sv.scrollOffset + amount)
  if visibleHeight > 0 and sv.scrollOffset >= totalRows - visibleHeight:
    sv.autoScroll = true

proc pageUp*(sv: ScrollableTextView, pageSize: int) =
  sv.scrollUp(pageSize)

proc pageDown*(sv: ScrollableTextView, pageSize: int) =
  sv.scrollDown(pageSize, pageSize)

proc clear*(sv: ScrollableTextView) =
  sv.lines.setLen(0)
  sv.scrollOffset = 0

proc clearSelection*(sv: ScrollableTextView) =
  sv.selecting = false
  sv.hasSelection = false

proc screenToTextPos(sv: ScrollableTextView, mx, my: int): TextPos =
  ## Convert screen coordinates to a text position (line index, column).
  let r = sv.lastRect
  let row = my - r.y
  let visibleH = r.h
  let msgColWidth = sv.lastMsgColWidth

  if sv.wrapMode != twNone and msgColWidth > 0:
    # With wrapping: build visual rows and map back
    let allVisualRows = sv.buildVisualRows(msgColWidth)
    let totalVR = allVisualRows.len
    var startVR: int
    if sv.autoScroll:
      startVR = max(0, totalVR - visibleH)
    else:
      let maxOffset = max(0, totalVR - visibleH)
      startVR = clamp(sv.scrollOffset, 0, maxOffset)
    let vrIdx = clamp(startVR + row, 0, max(0, totalVR - 1))
    if vrIdx < totalVR:
      let vr = allVisualRows[vrIdx]
      # Compute column offset within the logical line
      var colOffset = 0
      for vi in 0 ..< vrIdx:
        if allVisualRows[vi].lineIdx == vr.lineIdx:
          colOffset += allVisualRows[vi].text.len
        elif allVisualRows[vi].lineIdx > vr.lineIdx:
          break
      let col = max(0, mx - r.x - sv.tsColWidth) + colOffset
      return TextPos(line: vr.lineIdx, col: col)
    return TextPos(line: max(0, sv.lines.len - 1), col: 0)
  else:
    # No wrapping: simple mapping
    var startIdx: int
    if sv.autoScroll:
      startIdx = max(0, sv.lines.len - visibleH)
    else:
      let maxOffset = max(0, sv.lines.len - visibleH)
      startIdx = clamp(sv.scrollOffset, 0, maxOffset)
    let lineIdx = clamp(startIdx + row, 0, max(0, sv.lines.len - 1))
    let col = max(0, mx - r.x - sv.tsColWidth)
    TextPos(line: lineIdx, col: col)

proc selStart*(sv: ScrollableTextView): TextPos =
  ## Return the selection start (earlier position).
  if sv.selAnchor.line < sv.selCursor.line or
     (sv.selAnchor.line == sv.selCursor.line and sv.selAnchor.col <= sv.selCursor.col):
    sv.selAnchor
  else:
    sv.selCursor

proc selEnd*(sv: ScrollableTextView): TextPos =
  ## Return the selection end (later position).
  if sv.selAnchor.line < sv.selCursor.line or
     (sv.selAnchor.line == sv.selCursor.line and sv.selAnchor.col <= sv.selCursor.col):
    sv.selCursor
  else:
    sv.selAnchor

proc getSelectedText*(sv: ScrollableTextView): string =
  ## Extract the selected text as a plain string.
  if not sv.hasSelection:
    return ""
  let s = sv.selStart
  let e = sv.selEnd
  if s.line == e.line:
    # Single line selection
    if s.line < sv.lines.len:
      let text = sv.lines[s.line].text
      let startCol = clamp(s.col, 0, text.len)
      let endCol = clamp(e.col, 0, text.len)
      return text[startCol ..< endCol]
  else:
    # Multi-line selection
    var parts: seq[string] = @[]
    for i in s.line .. min(e.line, sv.lines.len - 1):
      if i >= sv.lines.len: break
      let text = sv.lines[i].text
      if i == s.line:
        parts.add(text[clamp(s.col, 0, text.len) .. ^1])
      elif i == e.line:
        parts.add(text[0 ..< clamp(e.col, 0, text.len)])
      else:
        parts.add(text)
    return parts.join("\n")

proc handleMouse*(sv: ScrollableTextView, evt: InputEvent): bool =
  ## Handle mouse events for the scrollable text view.
  ## Supports scroll wheel up/down and click-drag text selection.
  ## Returns true if the view needs re-rendering.
  if evt.kind != iekMouse:
    return false
  let r = sv.lastRect
  if r.w <= 0 or r.h <= 0:
    return false

  # Scroll wheel works even outside strict bounds (for convenience)
  if evt.button == mbScrollUp:
    if evt.mx >= r.x and evt.mx < r.x + r.w and
       evt.my >= r.y and evt.my < r.y + r.h:
      sv.scrollUp(3)
      return true
  elif evt.button == mbScrollDown:
    if evt.mx >= r.x and evt.mx < r.x + r.w and
       evt.my >= r.y and evt.my < r.y + r.h:
      sv.scrollDown(3, r.h)
      return true

  # Selection: click to start, drag to extend, release to finalize
  if evt.button == mbLeft:
    if evt.action == maPress:
      if evt.mx >= r.x and evt.mx < r.x + r.w and
         evt.my >= r.y and evt.my < r.y + r.h:
        let pos = sv.screenToTextPos(evt.mx, evt.my)
        sv.selecting = true
        sv.hasSelection = false
        sv.selAnchor = pos
        sv.selCursor = pos
        return true
    elif evt.action == maRelease:
      if sv.selecting:
        sv.selecting = false
        if sv.selAnchor != sv.selCursor:
          sv.hasSelection = true
        else:
          sv.hasSelection = false
        return true

  # Motion while selecting (button held)
  if evt.action == maMotion and sv.selecting:
    let pos = sv.screenToTextPos(evt.mx, evt.my)
    if pos != sv.selCursor:
      sv.selCursor = pos
      sv.hasSelection = (sv.selAnchor != sv.selCursor)
      return true

  return false

proc toWidget*(sv: ScrollableTextView, height: int = 0): Widget =
  ## Render the scrollable text view as a custom widget.
  let view = sv
  custom(proc(buf: var CellBuffer, rect: Rect) =
    view.lastRect = rect
    if rect.w <= 0 or rect.h <= 0:
      return
    let visibleH = rect.h

    # Compute timestamp column width (scan all lines for max width)
    var tsColWidth = 0
    if view.showTimestamps:
      for entry in view.lines:
        if entry.timestamp.len > tsColWidth:
          tsColWidth = entry.timestamp.len
      if tsColWidth > 0:
        tsColWidth += 1  # Space after timestamp

    # Clamp timestamp column to available width so it never overflows the rect
    if tsColWidth >= rect.w:
      tsColWidth = max(0, rect.w - 1)
    view.tsColWidth = tsColWidth

    let msgColWidth = max(1, rect.w - tsColWidth)
    view.lastMsgColWidth = msgColWidth

    # Build visual rows (handles wrapping)
    let allVisualRows = view.buildVisualRows(msgColWidth)
    let totalVR = allVisualRows.len
    view.lastTotalVisualRows = totalVR

    # Determine starting visual row index
    var startVR: int
    if view.autoScroll:
      startVR = max(0, totalVR - visibleH)
    else:
      let maxOffset = max(0, totalVR - visibleH)
      startVR = clamp(view.scrollOffset, 0, maxOffset)

    # Selection range (normalized so selS <= selE)
    let hasSel = view.hasSelection or view.selecting
    var selS, selE: TextPos
    if hasSel:
      selS = view.selStart
      selE = view.selEnd

    for row in 0 ..< visibleH:
      let vrIdx = startVR + row
      if vrIdx >= totalVR:
        break
      let vr = allVisualRows[vrIdx]
      let lineIdx = vr.lineIdx
      let entry = view.lines[lineIdx]
      var x = rect.x

      # Draw timestamp column only on the first visual row of a logical line
      if tsColWidth > 0 and view.showTimestamps:
        if vr.isFirstRow:
          let ts = if entry.timestamp.len > 0: entry.timestamp else: ""
          let padded = ts & " ".repeat(max(0, tsColWidth - ts.len))
          buf.writeStrClip(x, rect.y + row, min(tsColWidth, rect.w), padded, view.timestampStyle)
        x += tsColWidth

      # Draw message text — clip to remaining width within the rect
      let remainingW = max(0, (rect.x + rect.w) - x)
      if vr.spans.len > 0:
        # Render styled spans for this visual row
        var sx = x
        for span in vr.spans:
          let available = max(0, (rect.x + rect.w) - sx)
          if available <= 0: break
          buf.writeStrClip(sx, rect.y + row, available, span.text, span.style)
          sx += span.text.len
      else:
        buf.writeStrClip(x, rect.y + row, min(msgColWidth, remainingW), vr.text, vr.style)

      # Apply selection highlight (reverse video) over selected columns
      if hasSel and lineIdx >= selS.line and lineIdx <= selE.line:
        let textLen = entry.text.len
        var colStart = 0
        var colEnd = textLen
        if lineIdx == selS.line:
          colStart = selS.col
        if lineIdx == selE.line:
          colEnd = selE.col
        colStart = clamp(colStart, 0, textLen)
        colEnd = clamp(colEnd, 0, max(textLen, rect.w - tsColWidth))
        # Extend selection to end of line for full-line interior rows
        if lineIdx > selS.line and lineIdx < selE.line:
          colEnd = max(textLen, rect.w - tsColWidth)
        # Also extend the last column of the start line if multi-line
        if lineIdx == selS.line and selE.line > selS.line:
          colEnd = max(textLen, rect.w - tsColWidth)
        # Map selection columns to this visual row's portion
        var vrColOffset = 0
        for vi in startVR ..< vrIdx:
          if allVisualRows[vi].lineIdx == lineIdx:
            vrColOffset += allVisualRows[vi].text.len
        # Also count visual rows before the visible window
        for vi in 0 ..< startVR:
          if allVisualRows[vi].lineIdx == lineIdx:
            vrColOffset += allVisualRows[vi].text.len
        let vrLen = vr.text.len
        let vrColStart = max(0, colStart - vrColOffset)
        let vrColEnd = min(vrLen, colEnd - vrColOffset)
        if vrColEnd > vrColStart:
          for c in vrColStart ..< vrColEnd:
            let sx = x + c
            if sx >= rect.x and sx < rect.x + rect.w:
              let cell = buf[sx, rect.y + row]
              var invSt = cell.style
              invSt.attrs = invSt.attrs + {taReverse}
              buf.setCell(sx, rect.y + row, cell.ch, invSt)
  )

# ============================================================
# Status Bar
# ============================================================

type
  StatusBarItem* = object
    text*: string
    style*: Style
    align*: TextAlign    ## Left, center, or right

  StatusBar* = ref object
    items*: seq[StatusBarItem]
    style*: Style

proc newStatusBar*(st: Style = style(clBlack, clWhite)): StatusBar =
  StatusBar(items: @[], style: st)

proc addItem*(sb: StatusBar, text: string, align: TextAlign = taLeft,
              st: Style = style(clBlack, clWhite)) =
  sb.items.add(StatusBarItem(text: text, style: st, align: align))

proc setItems*(sb: StatusBar, items: varargs[StatusBarItem]) =
  sb.items = @items

proc statusItem*(text: string, align: TextAlign = taLeft,
                 st: Style = style(clBlack, clWhite)): StatusBarItem =
  StatusBarItem(text: text, style: st, align: align)

proc toWidget*(sb: StatusBar): Widget =
  let bar = sb
  custom(proc(buf: var CellBuffer, rect: Rect) =
    if rect.w <= 0 or rect.h <= 0:
      return
    # Fill background
    buf.fill(rect.x, rect.y, rect.w, 1, " ", bar.style)

    # First pass: compute right-aligned items total width
    var rightTotal = 0
    for item in bar.items:
      if item.align == taRight:
        rightTotal += item.text.len

    var leftX = rect.x
    var rightX = rect.x + rect.w
    let leftLimit = rect.x + rect.w - rightTotal  # Don't let left items overlap right items

    for item in bar.items:
      case item.align
      of taLeft:
        let maxW = max(0, min(leftLimit, rightX) - leftX)
        if maxW > 0:
          buf.writeStrClip(leftX, rect.y, maxW, item.text, item.style)
          leftX += min(item.text.len, maxW)
      of taRight:
        let start = max(leftX, rightX - item.text.len)
        let maxW = rightX - start
        if maxW > 0:
          buf.writeStrClip(start, rect.y, maxW, item.text, item.style)
          rightX = start
      of taCenter:
        let start = rect.x + (rect.w - item.text.len) div 2
        let maxW = min(item.text.len, max(0, rightX - start))
        if maxW > 0:
          buf.writeStrClip(max(start, leftX), rect.y, maxW, item.text, item.style)
  ).withHeight(fixed(1))

# ============================================================
# Dialog / Modal
# ============================================================

type
  Dialog* = ref object
    title*: string
    body*: Widget
    width*: int          ## Fixed width (0 = auto 60% of screen)
    height*: int         ## Fixed height (0 = auto 40% of screen)
    borderStyle*: BorderStyle
    titleStyle*: Style
    shadowStyle*: Style
    visible*: bool

proc newDialog*(title: string, body: Widget,
                width: int = 0, height: int = 0): Dialog =
  Dialog(
    title: title,
    body: body,
    width: width,
    height: height,
    borderStyle: bsRounded,
    titleStyle: style(clBrightWhite).bold(),
    shadowStyle: style(clDefault, clBrightBlack),
    visible: true,
  )

proc show*(d: Dialog) = d.visible = true
proc hide*(d: Dialog) = d.visible = false
proc toggle*(d: Dialog) = d.visible = not d.visible

proc toWidget*(d: Dialog, screenW, screenH: int): Widget =
  ## Render the dialog as an overlay widget.
  if not d.visible:
    return spacer(0)

  let dlg = d
  let rawW = if dlg.width > 0: dlg.width else: screenW * 60 div 100
  let rawH = if dlg.height > 0: dlg.height else: screenH * 40 div 100
  let dw = min(rawW, max(screenW - 2, 10))
  let dh = min(rawH, max(screenH - 2, 5))
  let dx = max(0, (screenW - dw) div 2)
  let dy = max(0, (screenH - dh) div 2)

  custom(proc(buf: var CellBuffer, rect: Rect) =
    # Draw shadow
    buf.fill(dx + 1, dy + 1, dw, dh, " ", dlg.shadowStyle)
    # Draw dialog background
    buf.fill(dx, dy, dw, dh, " ", styleDefault)
    # Draw border
    let bc = borderChars(dlg.borderStyle)
    buf.setCell(dx, dy, bc.topLeft, dlg.titleStyle)
    for x in dx + 1 ..< dx + dw - 1:
      buf.setCell(x, dy, bc.horizontal, dlg.titleStyle)
    buf.setCell(dx + dw - 1, dy, bc.topRight, dlg.titleStyle)
    for y in dy + 1 ..< dy + dh - 1:
      buf.setCell(dx, y, bc.vertical, dlg.titleStyle)
      buf.setCell(dx + dw - 1, y, bc.vertical, dlg.titleStyle)
    buf.setCell(dx, dy + dh - 1, bc.bottomLeft, dlg.titleStyle)
    for x in dx + 1 ..< dx + dw - 1:
      buf.setCell(x, dy + dh - 1, bc.horizontal, dlg.titleStyle)
    buf.setCell(dx + dw - 1, dy + dh - 1, bc.bottomRight, dlg.titleStyle)
    # Draw title
    if dlg.title.len > 0:
      let titleStr = " " & dlg.title & " "
      buf.writeStr(dx + 2, dy, titleStr, dlg.titleStyle)
    # Render body inside
    let innerRect = Rect(x: dx + 1, y: dy + 1, w: dw - 2, h: dh - 2)
    renderWidget(buf, dlg.body, innerRect)
  )

# ============================================================
# Notification Area
# ============================================================

type
  NotificationLevel* = enum
    nlInfo
    nlSuccess
    nlWarning
    nlError

  Notification* = object
    message*: string
    level*: NotificationLevel
    expiry*: float        ## Seconds from creation until auto-dismiss
    created*: float       ## MonoTime as float

  NotificationArea* = ref object
    notifications*: seq[Notification]
    maxVisible*: int
    position*: Alignment  ## Where to show (alStart=top, alEnd=bottom)

proc newNotificationArea*(maxVisible: int = 3,
                          position: Alignment = alEnd): NotificationArea =
  NotificationArea(
    notifications: @[],
    maxVisible: maxVisible,
    position: position,
  )

proc notify*(na: NotificationArea, message: string,
             level: NotificationLevel = nlInfo,
             duration: float = 5.0) =
  let now = epochTime()
  na.notifications.add(Notification(
    message: message,
    level: level,
    expiry: duration,
    created: now,
  ))

proc tick*(na: NotificationArea): bool =
  ## Remove expired notifications. Returns true if any were removed.
  let now = epochTime()
  var removed = false
  var i = 0
  while i < na.notifications.len:
    if now - na.notifications[i].created >= na.notifications[i].expiry:
      na.notifications.delete(i)
      removed = true
    else:
      inc i
  removed

proc notifStyle(level: NotificationLevel): Style =
  case level
  of nlInfo: style(clBrightCyan, clDefault)
  of nlSuccess: style(clBrightGreen, clDefault)
  of nlWarning: style(clBrightYellow, clDefault)
  of nlError: style(clBrightRed, clDefault)

proc notifIcon(level: NotificationLevel): string =
  case level
  of nlInfo: "i"
  of nlSuccess: "+"
  of nlWarning: "!"
  of nlError: "x"

proc toWidget*(na: NotificationArea): Widget =
  let area = na
  let visible = min(area.maxVisible, area.notifications.len)
  if visible == 0:
    return spacer(0).withHeight(fixed(0))

  var children: seq[Widget] = @[]
  let startIdx = max(0, area.notifications.len - visible)
  for i in startIdx ..< area.notifications.len:
    let n = area.notifications[i]
    children.add(
      text(" " & notifIcon(n.level) & " " & n.message & " ", notifStyle(n.level))
        .withHeight(fixed(1))
    )
  border(vbox(children), bsRounded, st = style(clBrightBlack, clBlack))
    .withStyle(style(clDefault, clBlack))

# ============================================================
# Tree View
# ============================================================

type
  TreeNode* = ref object
    label*: string
    style*: Style
    children*: seq[TreeNode]
    expanded*: bool
    selected*: bool
    data*: string          ## Optional user data

  TreeView* = ref object
    root*: seq[TreeNode]
    selectedIdx*: int      ## Flat index of selected item
    indentSize*: int
    expandedIcon*: string
    collapsedIcon*: string
    leafIcon*: string
    lastRect*: Rect        ## Set during render for mouse hit-testing

proc newTreeView*(indentSize: int = 2): TreeView =
  TreeView(
    root: @[],
    selectedIdx: 0,
    indentSize: indentSize,
    expandedIcon: "▼ ",
    collapsedIcon: "▶ ",
    leafIcon: "  ",
  )

proc treeNode*(label: string, children: varargs[TreeNode],
               expanded: bool = false, st: Style = styleDefault): TreeNode =
  TreeNode(label: label, style: st, children: @children,
           expanded: expanded)

proc flattenTree(nodes: seq[TreeNode], depth: int,
                 result: var seq[tuple[node: TreeNode, depth: int]]) =
  for node in nodes:
    result.add((node, depth))
    if node.expanded and node.children.len > 0:
      flattenTree(node.children, depth + 1, result)

proc flatItems*(tv: TreeView): seq[tuple[node: TreeNode, depth: int]] =
  result = @[]
  flattenTree(tv.root, 0, result)

proc toggleExpand*(tv: TreeView) =
  let flat = tv.flatItems()
  if tv.selectedIdx >= 0 and tv.selectedIdx < flat.len:
    let node = flat[tv.selectedIdx].node
    if node.children.len > 0:
      node.expanded = not node.expanded

proc moveUp*(tv: TreeView) =
  if tv.selectedIdx > 0:
    dec tv.selectedIdx

proc moveDown*(tv: TreeView) =
  let flat = tv.flatItems()
  if tv.selectedIdx < flat.len - 1:
    inc tv.selectedIdx

proc handleMouse*(tv: TreeView, evt: InputEvent): bool =
  ## Handle mouse events for tree view. Click to select, click expand icon
  ## to toggle. Returns true if selection changed.
  if evt.kind != iekMouse or evt.action != maPress or evt.button != mbLeft:
    return false
  let r = tv.lastRect
  if r.w <= 0 or r.h <= 0:
    return false
  if evt.mx < r.x or evt.mx >= r.x + r.w or
     evt.my < r.y or evt.my >= r.y + r.h:
    return false
  let clickedRow = evt.my - r.y
  let flat = tv.flatItems()
  if clickedRow >= 0 and clickedRow < flat.len:
    tv.selectedIdx = clickedRow
    let (node, depth) = flat[clickedRow]
    # Check if click is on the expand/collapse icon area
    let iconX = r.x + depth * tv.indentSize
    if evt.mx >= iconX and evt.mx < iconX + 2 and node.children.len > 0:
      node.expanded = not node.expanded
    return true
  return false

proc toWidget*(tv: TreeView): Widget =
  let view = tv
  custom(proc(buf: var CellBuffer, rect: Rect) =
    view.lastRect = rect
    let flat = view.flatItems()
    for i in 0 ..< min(flat.len, rect.h):
      let (node, depth) = flat[i]
      let indent = depth * view.indentSize
      let icon = if node.children.len > 0:
        if node.expanded: view.expandedIcon else: view.collapsedIcon
      else:
        view.leafIcon
      let isSelected = i == view.selectedIdx
      let st = if isSelected: style(clBlack, clWhite) else: node.style
      let prefix = " ".repeat(indent) & icon
      buf.writeStrClip(rect.x, rect.y + i, rect.w,
                      prefix & node.label, st)
      # Fill remaining for selection highlight
      if isSelected:
        let textLen = min(prefix.len + node.label.len, rect.w)
        for x in rect.x + textLen ..< rect.x + rect.w:
          buf.setCell(x, rect.y + i, " ", st)
  )

# ============================================================
# Input Box (bordered input with label)
# ============================================================

proc inputBox*(label: string, ti: TextInput,
               bs: BorderStyle = bsSingle,
               labelStyle: Style = style(clBrightCyan),
               inputStyle: Style = styleDefault): Widget =
  ## A labeled, bordered input box. Common TUI pattern.
  border(
    hbox(
      text(label, labelStyle)
        .withWidth(autoSize())
        .withHeight(fixed(1)),
      spacer(1).withWidth(fixed(1)),
      ti.toWidget(inputStyle),
    ),
    bs, "",
  ).withHeight(fixed(3))

# ============================================================
# Key help bar
# ============================================================

type
  KeyHelp* = object
    key*: string
    action*: string

proc keyHelpBar*(items: openArray[KeyHelp],
                 keyStyle: Style = style(clBlack, clWhite),
                 actionStyle: Style = style(clWhite, clBrightBlack)): Widget =
  ## A bottom key help bar like Nano/Midnight Commander.
  let helpItems = @items
  custom(proc(buf: var CellBuffer, rect: Rect) =
    buf.fill(rect.x, rect.y, rect.w, 1, " ", actionStyle)
    var x = rect.x
    for item in helpItems:
      if x >= rect.x + rect.w:
        break
      buf.writeStrClip(x, rect.y, item.key.len, item.key, keyStyle)
      x += item.key.len
      let desc = " " & item.action & "  "
      buf.writeStrClip(x, rect.y, desc.len, desc, actionStyle)
      x += desc.len
  ).withHeight(fixed(1))

proc kh*(key, action: string): KeyHelp =
  KeyHelp(key: key, action: action)

# ============================================================
# Mouse hit-test utilities
# ============================================================

proc hitTestTabBar*(tabs: openArray[TabItem], mx, my: int, rect: Rect): int =
  ## Returns the index of the tab at (mx, my), or -1 if none.
  ## The rect should be the tab bar's render rect.
  if my != rect.y or mx < rect.x or mx >= rect.x + rect.w:
    return -1
  var x = rect.x
  for i, tab in tabs:
    let label = " " & tab.label & " "
    if mx >= x and mx < x + label.len:
      return i
    x += label.len
    if i < tabs.len - 1:
      x += 1  # Tab separator character
  return -1

proc hitTestList*(itemCount: int, mx, my: int, rect: Rect,
                  offset: int = 0): int =
  ## Returns the index of the list item at (mx, my), or -1 if none.
  ## The rect should be the list's render rect (inside any border).
  if mx < rect.x or mx >= rect.x + rect.w or
     my < rect.y or my >= rect.y + rect.h:
    return -1
  let row = my - rect.y
  let idx = offset + row
  if idx >= 0 and idx < itemCount:
    return idx
  return -1

# ============================================================
# Confirm Dialog (declarative, with focus trap)
# ============================================================

proc confirmDialog*(title: string, lines: seq[string],
                    acceptLabel: string = "[Y] Accept",
                    declineLabel: string = "[N] Decline",
                    onAccept: proc(), onDecline: proc(),
                    screenW: int = 80, screenH: int = 24): Widget =
  ## A bordered dialog with focus trap that handles Y/N/Escape keys.
  ## Replaces the imperative PasteConfirm/DccConfirm pattern.
  let acceptCb = onAccept
  let declineCb = onDecline
  let bodyLines = lines
  let aLabel = acceptLabel
  let dLabel = declineLabel

  let dw = min(max(40, screenW * 60 div 100), screenW - 2)
  let lineCount = bodyLines.len + 2  # +2 for spacing and button row
  let dh = min(lineCount + 4, max(screenH - 4, 7))  # +4 for border+padding
  let dx = max(0, (screenW - dw) div 2)
  let dy = max(0, (screenH - dh) div 2)

  custom(proc(buf: var CellBuffer, rect: Rect) =
    # Shadow
    buf.fill(dx + 1, dy + 1, dw, dh, " ", style(clDefault, clBrightBlack))
    # Background
    buf.fill(dx, dy, dw, dh, " ", styleDefault)
    # Border
    let bc = borderChars(bsRounded)
    let titleSt = style(clBrightWhite).bold()
    buf.setCell(dx, dy, bc.topLeft, titleSt)
    for x in dx + 1 ..< dx + dw - 1:
      buf.setCell(x, dy, bc.horizontal, titleSt)
    buf.setCell(dx + dw - 1, dy, bc.topRight, titleSt)
    for y in dy + 1 ..< dy + dh - 1:
      buf.setCell(dx, y, bc.vertical, titleSt)
      buf.setCell(dx + dw - 1, y, bc.vertical, titleSt)
    buf.setCell(dx, dy + dh - 1, bc.bottomLeft, titleSt)
    for x in dx + 1 ..< dx + dw - 1:
      buf.setCell(x, dy + dh - 1, bc.horizontal, titleSt)
    buf.setCell(dx + dw - 1, dy + dh - 1, bc.bottomRight, titleSt)
    # Title
    if title.len > 0:
      buf.writeStr(dx + 2, dy, " " & title & " ", titleSt)
    # Body lines
    let innerW = dw - 4
    for i, line in bodyLines:
      if i < dh - 4:
        buf.writeStrClip(dx + 2, dy + 1 + i, innerW, line, styleDefault)
    # Button row
    let buttonY = dy + dh - 2
    let buttonText = aLabel & "  " & dLabel
    buf.writeStrClip(dx + 2, buttonY, innerW, buttonText, style(clBrightCyan))
  ).withFocusTrap(true).withOnKey(proc(evt: InputEvent): bool =
    if evt.kind == iekKey:
      if evt.key == kcChar and (evt.ch == 'y' or evt.ch == 'Y'):
        acceptCb()
        return true
      elif evt.key == kcChar and (evt.ch == 'n' or evt.ch == 'N'):
        declineCb()
        return true
      elif evt.key == kcEscape:
        declineCb()
        return true
    return true  # Trap all keys
  ).withFocus(true)

# ============================================================
# Interactive List (declarative, with built-in click/key nav)
# ============================================================

proc interactiveList*(items: seq[ListItem], selected: int,
                      onSelect: proc(idx: int),
                      onActivate: proc(idx: int) = nil,
                      offset: int = 0,
                      highlightStyle: Style = style(clBlack, clWhite)): Widget =
  ## A list with built-in click-to-select and keyboard navigation.
  ## `onSelect` fires when selection changes, `onActivate` fires on Enter.
  let listItems = items
  let selectCb = onSelect
  let activateCb = onActivate
  let sel = selected
  let ofs = offset
  let hlStyle = highlightStyle

  list(listItems, sel, ofs, hlStyle)
    .withOnClick(proc(mx, my: int) =
      let idx = ofs + my
      if idx >= 0 and idx < listItems.len:
        selectCb(idx)
    )
    .withOnKey(proc(evt: InputEvent): bool =
      if evt.kind == iekKey:
        case evt.key
        of kcUp:
          if sel > 0:
            selectCb(sel - 1)
          return true
        of kcDown:
          if sel < listItems.len - 1:
            selectCb(sel + 1)
          return true
        of kcEnter:
          if activateCb != nil and sel >= 0 and sel < listItems.len:
            activateCb(sel)
          return true
        else: discard
      return false
    )
    .withFocus(true)

# ============================================================
# Interactive Tabs (declarative, with built-in click switching)
# ============================================================

proc interactiveTabs*(items: seq[TabItem],
                      onSwitch: proc(idx: int),
                      tabSt: Style = styleDefault,
                      activeSt: Style = style(clBlack, clWhite).bold()): Widget =
  ## A tab bar with built-in click-to-switch.
  let tabItems = items
  let switchCb = onSwitch
  tabBar(tabItems, tabSt, activeSt)
    .withOnClick(proc(mx, my: int) =
      # Hit-test the tab positions
      var x = 0
      for i, tab in tabItems:
        let label = " " & tab.label & " "
        if mx >= x and mx < x + label.len:
          switchCb(i)
          return
        x += label.len
        if i < tabItems.len - 1:
          x += 1  # Separator
    )

# ============================================================
# Declarative SplitView (events built-in)
# ============================================================

proc toWidgetWithEvents*(sv: SplitView, first, second: Widget): Widget =
  ## Render the split view with internal mouse event handling for divider drag.
  ## Sets customChildren/customChildRects so the event system can route clicks
  ## to child widgets (channel list, chat area, etc.).
  let svRef = sv
  let firstChild = first
  let secondChild = second
  var w = custom(proc(buf: var CellBuffer, rect: Rect) =
    case svRef.direction
    of dirHorizontal:
      let usable = max(0, rect.w - 1)
      let firstSize = svRef.computeFirstSize(usable)
      let secondSize = usable - firstSize
      if firstSize > 0:
        renderWidget(buf, firstChild, Rect(x: rect.x, y: rect.y, w: firstSize, h: rect.h))
      let divX = rect.x + firstSize
      for y in rect.y ..< rect.y + rect.h:
        buf.setCell(divX, y, svRef.dividerChar, svRef.dividerStyle)
      if secondSize > 0:
        renderWidget(buf, secondChild, Rect(x: divX + 1, y: rect.y, w: secondSize, h: rect.h))
    of dirVertical:
      let usable = max(0, rect.h - 1)
      let firstSize = svRef.computeFirstSize(usable)
      let secondSize = usable - firstSize
      if firstSize > 0:
        renderWidget(buf, firstChild, Rect(x: rect.x, y: rect.y, w: rect.w, h: firstSize))
      let divY = rect.y + firstSize
      for x in rect.x ..< rect.x + rect.w:
        buf.setCell(x, divY, svRef.dividerChar, svRef.dividerStyle)
      if secondSize > 0:
        renderWidget(buf, secondChild, Rect(x: rect.x, y: divY + 1, w: rect.w, h: secondSize))
  )
  # Register children for event routing. The rects are computed lazily
  # during customRender and read by renderWidgetWithEvents afterward.
  w.customChildren = @[firstChild, secondChild]
  # Placeholder rects — will be updated by a wrapper render proc
  w.customChildRects = @[Rect(), Rect()]
  let wRef = w
  let origRender = w.customRender
  w.customRender = proc(buf: var CellBuffer, rect: Rect) =
    svRef.lastRect = rect
    # Compute child rects for event routing before rendering
    case svRef.direction
    of dirHorizontal:
      let usable = max(0, rect.w - 1)
      let firstSize = svRef.computeFirstSize(usable)
      let secondSize = usable - firstSize
      wRef.customChildRects[0] = Rect(x: rect.x, y: rect.y, w: firstSize, h: rect.h)
      wRef.customChildRects[1] = Rect(x: rect.x + firstSize + 1, y: rect.y, w: secondSize, h: rect.h)
    of dirVertical:
      let usable = max(0, rect.h - 1)
      let firstSize = svRef.computeFirstSize(usable)
      let secondSize = usable - firstSize
      wRef.customChildRects[0] = Rect(x: rect.x, y: rect.y, w: rect.w, h: firstSize)
      wRef.customChildRects[1] = Rect(x: rect.x, y: rect.y + firstSize + 1, w: rect.w, h: secondSize)
    origRender(buf, rect)
  w.withOnMouse(proc(evt: InputEvent): bool =
    svRef.handleMouse(evt, svRef.lastRect)
  )

# ============================================================
# Declarative ScrollableTextView (events built-in)
# ============================================================

proc toWidgetWithEvents*(sv: ScrollableTextView, height: int = 0,
                         onSelect: proc(text: string) = nil): Widget =
  ## Render the scrollable text view with built-in scroll and selection handling.
  ## If `onSelect` is provided, it is called when the user completes a text
  ## selection (mouse release after drag). Use this for clipboard copy.
  let view = sv
  let selectCb = onSelect
  sv.toWidget(height)
    .withOnScroll(proc(delta: int) =
      if delta < 0:
        view.scrollUp(3)
      else:
        view.scrollDown(3, view.lastRect.h)
    )
    .withOnMouse(proc(evt: InputEvent): bool =
      let handled = view.handleMouse(evt)
      if handled and evt.action == maRelease and view.hasSelection and
         selectCb != nil:
        let text = view.getSelectedText()
        if text.len > 0:
          selectCb(text)
      handled
    )

# ============================================================
# Declarative TreeView (events built-in)
# ============================================================

proc toWidgetWithEvents*(tv: TreeView): Widget =
  ## Render the tree view with built-in click handling.
  let view = tv
  tv.toWidget()
    .withOnClick(proc(mx, my: int) =
      let flat = view.flatItems()
      if my >= 0 and my < flat.len:
        view.selectedIdx = my
        let (node, depth) = flat[my]
        let iconX = depth * view.indentSize
        if mx >= iconX and mx < iconX + 2 and node.children.len > 0:
          node.expanded = not node.expanded
    )
    .withOnKey(proc(evt: InputEvent): bool =
      if evt.kind == iekKey:
        case evt.key
        of kcUp: view.moveUp(); return true
        of kcDown: view.moveDown(); return true
        of kcEnter: view.toggleExpand(); return true
        else: discard
      return false
    )
