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

proc scrollToBottom*(sv: ScrollableTextView) =
  sv.scrollOffset = max(0, sv.lines.len)  # Will be clamped during render

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
  sv.scrollOffset = min(max(0, sv.lines.len - 1), sv.scrollOffset + amount)
  if visibleHeight > 0 and sv.scrollOffset >= sv.lines.len - visibleHeight:
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

    # Determine the starting line index
    var startIdx: int
    if view.autoScroll:
      startIdx = max(0, view.lines.len - visibleH)
    else:
      let maxOffset = max(0, view.lines.len - visibleH)
      startIdx = clamp(view.scrollOffset, 0, maxOffset)

    # Compute timestamp column width (fixed across all lines for alignment)
    var tsColWidth = 0
    if view.showTimestamps:
      for i in startIdx ..< min(startIdx + visibleH, view.lines.len):
        if view.lines[i].timestamp.len > tsColWidth:
          tsColWidth = view.lines[i].timestamp.len
      if tsColWidth > 0:
        tsColWidth += 1  # Space after timestamp

    # Clamp timestamp column to available width so it never overflows the rect
    if tsColWidth >= rect.w:
      tsColWidth = max(0, rect.w - 1)
    view.tsColWidth = tsColWidth

    let msgColWidth = max(1, rect.w - tsColWidth)

    # Selection range (normalized so selS <= selE)
    let hasSel = view.hasSelection or view.selecting
    var selS, selE: TextPos
    if hasSel:
      selS = view.selStart
      selE = view.selEnd

    for row in 0 ..< visibleH:
      let lineIdx = startIdx + row
      if lineIdx >= view.lines.len:
        break
      let entry = view.lines[lineIdx]
      var x = rect.x

      # Draw timestamp column (fixed-width, right-padded)
      if tsColWidth > 0 and view.showTimestamps:
        let ts = if entry.timestamp.len > 0: entry.timestamp
                 else: ""
        let padded = ts & " ".repeat(max(0, tsColWidth - ts.len))
        buf.writeStrClip(x, rect.y + row, min(tsColWidth, rect.w), padded, view.timestampStyle)
        x += tsColWidth

      # Draw message text — clip to remaining width within the rect
      let remainingW = max(0, (rect.x + rect.w) - x)
      if entry.spans.len > 0:
        # Render styled spans
        var sx = x
        for span in entry.spans:
          let available = max(0, (rect.x + rect.w) - sx)
          if available <= 0: break
          buf.writeStrClip(sx, rect.y + row, available, span.text, span.style)
          sx += span.text.len
      else:
        buf.writeStrClip(x, rect.y + row, min(msgColWidth, remainingW), entry.text, entry.style)

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
        for c in colStart ..< colEnd:
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
  let now = cpuTime()
  na.notifications.add(Notification(
    message: message,
    level: level,
    expiry: duration,
    created: now,
  ))

proc tick*(na: NotificationArea): bool =
  ## Remove expired notifications. Returns true if any were removed.
  let now = cpuTime()
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
  of nlInfo: style(clBrightCyan)
  of nlSuccess: style(clBrightGreen)
  of nlWarning: style(clBrightYellow)
  of nlError: style(clBrightRed)

proc toWidget*(na: NotificationArea): Widget =
  let area = na
  let visible = min(area.maxVisible, area.notifications.len)
  if visible == 0:
    return spacer(0).withHeight(fixed(0))

  var children: seq[Widget] = @[]
  let startIdx = max(0, area.notifications.len - visible)
  for i in startIdx ..< area.notifications.len:
    let n = area.notifications[i]
    let prefix = case n.level
      of nlInfo: "[i] "
      of nlSuccess: "[+] "
      of nlWarning: "[!] "
      of nlError: "[x] "
    children.add(
      text(prefix & n.message, notifStyle(n.level))
        .withHeight(fixed(1))
    )
  vbox(children).withHeight(fixed(visible))

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
