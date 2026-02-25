## CPS TUI - Renderer
##
## Traverses the widget tree, computes layout, and draws widgets to a CellBuffer.
## Each widget kind has a specialized draw procedure. The renderer handles
## clipping, scrolling, and focus indicator rendering.

import ./style
import ./cell
import ./layout
import ./widget
import ./events
import std/strutils

# ============================================================
# Text wrapping
# ============================================================

proc wrapText(text: string, maxWidth: int, mode: TextWrap): seq[string] =
  if maxWidth <= 0:
    return @[""]
  case mode
  of twNone:
    # Split by newlines, no wrapping
    result = text.split('\n')
  of twChar:
    result = @[]
    for line in text.split('\n'):
      var pos = 0
      while pos < line.len:
        let endPos = min(pos + maxWidth, line.len)
        result.add(line[pos ..< endPos])
        pos = endPos
      if line.len == 0:
        result.add("")
  of twWrap:
    result = @[]
    for line in text.split('\n'):
      if line.len <= maxWidth:
        result.add(line)
        continue
      var current = ""
      for word in line.split(' '):
        if current.len == 0:
          current = word
        elif current.len + 1 + word.len <= maxWidth:
          current.add(' ')
          current.add(word)
        else:
          result.add(current)
          current = word
      if current.len > 0:
        result.add(current)
      if line.len == 0:
        result.add("")

proc alignLine(line: string, width: int, align: TextAlign): string =
  if line.len >= width:
    return line[0 ..< width]
  case align
  of taLeft:
    line & ' '.repeat(width - line.len)
  of taRight:
    ' '.repeat(width - line.len) & line
  of taCenter:
    let pad = width - line.len
    let left = pad div 2
    let right = pad - left
    ' '.repeat(left) & line & ' '.repeat(right)

# ============================================================
# Widget drawing
# ============================================================

proc drawText(buf: var CellBuffer, rect: Rect, w: Widget) =
  let contentW = rect.w - w.layout.padding.padH()
  let contentH = rect.h - w.layout.padding.padV()
  if contentW <= 0 or contentH <= 0:
    return

  let lines = wrapText(w.text, contentW, w.textWrap)
  let startX = rect.x + w.layout.padding.left
  let startY = rect.y + w.layout.padding.top

  for i, line in lines:
    if i >= contentH:
      break
    let aligned = alignLine(line, contentW, w.textAlign)
    buf.writeStrClip(startX, startY + i, contentW, aligned, w.style)

proc drawBorder(buf: var CellBuffer, rect: Rect, w: Widget) =
  let bc = borderChars(w.borderStyle)
  let s = w.style

  if rect.w < 2 or rect.h < 2:
    return

  # Top border
  buf.setCell(rect.x, rect.y, bc.topLeft, s)
  for x in rect.x + 1 ..< rect.x + rect.w - 1:
    buf.setCell(x, rect.y, bc.horizontal, s)
  buf.setCell(rect.x + rect.w - 1, rect.y, bc.topRight, s)

  # Bottom border
  buf.setCell(rect.x, rect.y + rect.h - 1, bc.bottomLeft, s)
  for x in rect.x + 1 ..< rect.x + rect.w - 1:
    buf.setCell(x, rect.y + rect.h - 1, bc.horizontal, s)
  buf.setCell(rect.x + rect.w - 1, rect.y + rect.h - 1, bc.bottomRight, s)

  # Side borders
  for y in rect.y + 1 ..< rect.y + rect.h - 1:
    buf.setCell(rect.x, y, bc.vertical, s)
    buf.setCell(rect.x + rect.w - 1, y, bc.vertical, s)

  # Title
  if w.borderTitle.len > 0 and rect.w > 4:
    let maxTitleLen = rect.w - 4
    let title = if w.borderTitle.len > maxTitleLen:
      w.borderTitle[0 ..< maxTitleLen]
    else:
      w.borderTitle
    let titleStr = " " & title & " "
    let ts = if w.borderTitleStyle != styleDefault: w.borderTitleStyle else: s
    buf.writeStr(rect.x + 1, rect.y, titleStr, ts)

proc drawInput(buf: var CellBuffer, rect: Rect, w: Widget) =
  if rect.h < 1 or rect.w < 1:
    return

  let displayText = if w.inputText.len > 0:
    if w.inputMask != '\0':
      w.inputMask.repeat(w.inputText.len)
    else:
      w.inputText
  elif w.inputPlaceholder.len > 0:
    w.inputPlaceholder
  else:
    ""

  let st = if w.inputText.len == 0 and w.inputPlaceholder.len > 0:
    style(clBrightBlack)  # Dim placeholder
  else:
    w.style

  let visibleWidth = rect.w

  if rect.h > 1:
    # Multi-line wrapping mode: wrap displayText at character boundaries
    var wrappedRows: seq[string] = @[]
    var pos = 0
    while pos < displayText.len:
      let endPos = min(pos + visibleWidth, displayText.len)
      wrappedRows.add(displayText[pos ..< endPos])
      pos = endPos
    if wrappedRows.len == 0:
      wrappedRows.add("")

    # Determine which row the cursor is on
    let cursorRow = if visibleWidth > 0: w.inputCursor div visibleWidth else: 0
    let cursorCol = if visibleWidth > 0: w.inputCursor mod visibleWidth else: 0

    # Scroll so cursor row is visible
    var scrollRow = 0
    if cursorRow >= rect.h:
      scrollRow = cursorRow - rect.h + 1

    # Render rows
    for row in 0 ..< rect.h:
      let rowIdx = scrollRow + row
      let rowText = if rowIdx < wrappedRows.len: wrappedRows[rowIdx] else: ""
      buf.writeStrClip(rect.x, rect.y + row, visibleWidth, rowText, st)
      # Fill remaining with spaces
      let textLen = rowText.len
      if textLen < visibleWidth:
        for x in rect.x + textLen ..< rect.x + visibleWidth:
          buf.setCell(x, rect.y + row, " ", st)

    # Cursor indicator
    if w.focused:
      let screenRow = cursorRow - scrollRow
      if screenRow >= 0 and screenRow < rect.h:
        let cursorX = rect.x + cursorCol
        if cursorX >= rect.x and cursorX < rect.x + visibleWidth:
          let curCell = buf[cursorX, rect.y + screenRow]
          buf.setCell(cursorX, rect.y + screenRow, curCell.ch, curCell.style.reverse())
  else:
    # Single-line mode: horizontal scroll
    var scrollOffset = 0
    if w.inputCursor > visibleWidth - 1:
      scrollOffset = w.inputCursor - visibleWidth + 1

    let visibleText = if scrollOffset < displayText.len:
      displayText[scrollOffset ..< min(scrollOffset + visibleWidth, displayText.len)]
    else:
      ""

    buf.writeStrClip(rect.x, rect.y, visibleWidth, visibleText, st)

    # Fill remaining with spaces
    let remaining = visibleWidth - visibleText.len
    if remaining > 0:
      for x in rect.x + visibleText.len ..< rect.x + visibleWidth:
        buf.setCell(x, rect.y, " ", st)

    # Cursor indicator
    if w.focused:
      let cursorX = rect.x + w.inputCursor - scrollOffset
      if cursorX >= rect.x and cursorX < rect.x + visibleWidth:
        let curCell = buf[cursorX, rect.y]
        buf.setCell(cursorX, rect.y, curCell.ch, curCell.style.reverse())

proc drawList(buf: var CellBuffer, rect: Rect, w: Widget) =
  if rect.h < 1 or rect.w < 1:
    return

  let visibleCount = rect.h
  let offset = w.listOffset

  for i in 0 ..< visibleCount:
    let idx = offset + i
    if idx >= w.listItems.len:
      break
    let item = w.listItems[idx]
    let isSelected = idx == w.listSelected
    let st = if isSelected: w.listHighlightStyle
             elif item.selected: style(clDefault, clDefault, {taBold})
             else: item.style
    buf.writeStrClip(rect.x, rect.y + i, rect.w, item.text, st)
    # Fill remaining width
    let remaining = rect.w - min(item.text.len, rect.w)
    if remaining > 0 and isSelected:
      for x in rect.x + min(item.text.len, rect.w) ..< rect.x + rect.w:
        buf.setCell(x, rect.y + i, " ", st)

proc drawTable(buf: var CellBuffer, rect: Rect, w: Widget) =
  if rect.h < 2 or rect.w < 1:
    return

  let colCount = w.tableColumns.len
  if colCount == 0:
    return

  # Compute column widths
  var colWidths = newSeq[int](colCount)
  var flexTotal = 0.0
  var fixedUsed = 0

  for i, col in w.tableColumns:
    case col.width.kind
    of szFixed:
      colWidths[i] = col.width.fixed
      fixedUsed += col.width.fixed
    of szPercent:
      colWidths[i] = int(col.width.percent / 100.0 * float(rect.w))
      fixedUsed += colWidths[i]
    of szFlex:
      flexTotal += col.width.flex
    of szAuto:
      colWidths[i] = col.title.len + 2
      fixedUsed += colWidths[i]

  let remaining = max(0, rect.w - fixedUsed - (colCount - 1))  # -1 for separators
  if flexTotal > 0:
    for i, col in w.tableColumns:
      if col.width.kind == szFlex:
        colWidths[i] = int(col.width.flex / flexTotal * float(remaining))

  # Draw header
  var x = rect.x
  for i, col in w.tableColumns:
    let aligned = alignLine(col.title, colWidths[i], col.align)
    buf.writeStrClip(x, rect.y, colWidths[i], aligned, w.tableHeaderStyle)
    x += colWidths[i]
    if i < colCount - 1:
      buf.setCell(x, rect.y, " ", w.tableHeaderStyle)
      inc x

  # Separator line
  if rect.h > 1:
    for cx in rect.x ..< rect.x + rect.w:
      buf.setCell(cx, rect.y + 1, "─", w.tableHeaderStyle)

  # Draw rows
  let dataStartY = rect.y + 2
  let visibleRows = rect.h - 2

  for rowIdx in 0 ..< visibleRows:
    let dataIdx = w.tableOffset + rowIdx
    if dataIdx >= w.tableRows.len:
      break

    let row = w.tableRows[dataIdx]
    let isSelected = dataIdx == w.tableSelected
    let rowSt = if isSelected: style(clBlack, clWhite)
                elif rowIdx mod 2 == 1 and w.tableAltRowStyle != styleDefault:
                  w.tableAltRowStyle
                else: w.tableRowStyle

    x = rect.x
    for colIdx in 0 ..< colCount:
      let cellText = if colIdx < row.len: row[colIdx] else: ""
      let align = w.tableColumns[colIdx].align
      let aligned = alignLine(cellText, colWidths[colIdx], align)
      buf.writeStrClip(x, dataStartY + rowIdx, colWidths[colIdx], aligned, rowSt)
      x += colWidths[colIdx]
      if colIdx < colCount - 1:
        buf.setCell(x, dataStartY + rowIdx, " ", rowSt)
        inc x

    # Fill remaining for selection highlight
    if isSelected:
      for fx in x ..< rect.x + rect.w:
        buf.setCell(fx, dataStartY + rowIdx, " ", rowSt)

proc drawProgressBar(buf: var CellBuffer, rect: Rect, w: Widget) =
  if rect.h < 1 or rect.w < 1:
    return
  let filled = int(w.progress * float(rect.w))
  for x in 0 ..< rect.w:
    if x < filled:
      buf.setCell(rect.x + x, rect.y, w.progressFillChar, w.progressStyle)
    else:
      buf.setCell(rect.x + x, rect.y, w.progressEmptyChar, w.style)

proc drawTabs(buf: var CellBuffer, rect: Rect, w: Widget) =
  if rect.h < 1 or rect.w < 1:
    return
  var x = rect.x
  for i, tab in w.tabs:
    let label = " " & tab.label & " "
    let st = if tab.active: w.activeTabStyle else: w.tabStyle
    buf.writeStrClip(x, rect.y, min(label.len, rect.w - (x - rect.x)), label, st)
    x += label.len
    if i < w.tabs.len - 1 and x < rect.x + rect.w:
      buf.setCell(x, rect.y, "│", w.style)
      inc x
    if x >= rect.x + rect.w:
      break

# ============================================================
# Main render traversal
# ============================================================

proc clipRect(child, parent: Rect): Rect {.inline.} =
  ## Clip a child rect to fit within the parent rect.
  ## Prevents any widget from rendering outside its parent's bounds.
  let x = max(child.x, parent.x)
  let y = max(child.y, parent.y)
  let right = min(child.x + child.w, parent.x + parent.w)
  let bottom = min(child.y + child.h, parent.y + parent.h)
  Rect(x: x, y: y, w: max(0, right - x), h: max(0, bottom - y))

proc renderWidget*(buf: var CellBuffer, w: Widget, rect: Rect) =
  ## Render a widget and its children into the buffer at the given rect.
  if rect.w <= 0 or rect.h <= 0:
    return

  # Fill background if the widget has a bg color
  if w.style.bg.kind != ckNone:
    buf.fill(rect.x, rect.y, rect.w, rect.h, " ", w.style)

  case w.kind
  of wkContainer:
    # Compute child layouts
    let innerRect = Rect(
      x: rect.x + w.layout.padding.left,
      y: rect.y + w.layout.padding.top,
      w: max(0, rect.w - w.layout.padding.padH()),
      h: max(0, rect.h - w.layout.padding.padV()),
    )

    if w.children.len > 0:
      var nodes = newSeq[LayoutNode](w.children.len)
      for i, child in w.children:
        nodes[i] = LayoutNode(
          props: child.layout,
          childCount: 0,
          contentWidth: child.contentWidth,
          contentHeight: child.contentHeight,
        )

      let rects = computeLayout(nodes, innerRect,
                                w.layout.direction,
                                w.layout.gap,
                                w.layout.alignItems,
                                w.layout.justifyContent)

      for i, child in w.children:
        # Clip each child's rect to the parent inner rect to prevent overflow
        let clipped = clipRect(rects[i], innerRect)
        renderWidget(buf, child, clipped)

  of wkText:
    drawText(buf, rect, w)

  of wkBorder:
    drawBorder(buf, rect, w)
    if w.borderChild != nil:
      let innerRect = Rect(
        x: rect.x + 1,
        y: rect.y + 1,
        w: max(0, rect.w - 2),
        h: max(0, rect.h - 2),
      )
      renderWidget(buf, w.borderChild, innerRect)

  of wkInput:
    drawInput(buf, rect, w)

  of wkList:
    drawList(buf, rect, w)

  of wkTable:
    drawTable(buf, rect, w)

  of wkSpacer:
    discard  # Just takes up space

  of wkScrollView:
    if w.scrollChild != nil:
      # Render child with scroll offset applied
      let childRect = Rect(
        x: rect.x - w.scrollX,
        y: rect.y - w.scrollY,
        w: rect.w + w.scrollX,
        h: rect.h + w.scrollY,
      )
      renderWidget(buf, w.scrollChild, childRect)

  of wkProgressBar:
    drawProgressBar(buf, rect, w)

  of wkTabs:
    drawTabs(buf, rect, w)

  of wkCustom:
    if w.customRender != nil:
      w.customRender(buf, rect)

# ============================================================
# Event-only traversal (no drawing)
# ============================================================

proc collectWidgetEvents*(w: Widget, rect: Rect,
                          hitMap: var HitMap, fm: FocusManager,
                          depth: int = 0, parentIdx: int = -1) =
  ## Traverse the widget tree collecting hit regions and focus order,
  ## WITHOUT drawing. Used for custom widget children that were already
  ## rendered by the parent's customRender proc.
  if rect.w <= 0 or rect.h <= 0:
    return

  var myIdx = -1
  if w.hasEventHandlers or w.focusable:
    myIdx = hitMap.regions.len
    hitMap.add(rect, w, depth, parentIdx)

  if w.trapFocus and depth > fm.focusTrapDepth:
    fm.focusTrapWidget = w
    fm.focusTrapDepth = depth

  if w.focusable:
    fm.addFocusable(w, rect)
    w.focused = (w == fm.focusedWidget)

  let effectiveParent = if myIdx >= 0: myIdx else: parentIdx

  case w.kind
  of wkContainer:
    let innerRect = Rect(
      x: rect.x + w.layout.padding.left,
      y: rect.y + w.layout.padding.top,
      w: max(0, rect.w - w.layout.padding.padH()),
      h: max(0, rect.h - w.layout.padding.padV()),
    )
    if w.children.len > 0:
      var nodes = newSeq[LayoutNode](w.children.len)
      for i, child in w.children:
        nodes[i] = LayoutNode(
          props: child.layout,
          childCount: 0,
          contentWidth: child.contentWidth,
          contentHeight: child.contentHeight,
        )
      let rects = computeLayout(nodes, innerRect,
                                w.layout.direction,
                                w.layout.gap,
                                w.layout.alignItems,
                                w.layout.justifyContent)
      for i, child in w.children:
        let clipped = clipRect(rects[i], innerRect)
        collectWidgetEvents(child, clipped, hitMap, fm, depth + 1, effectiveParent)

  of wkBorder:
    if w.borderChild != nil:
      let innerRect = Rect(
        x: rect.x + 1, y: rect.y + 1,
        w: max(0, rect.w - 2), h: max(0, rect.h - 2),
      )
      collectWidgetEvents(w.borderChild, innerRect, hitMap, fm, depth + 1, effectiveParent)

  of wkScrollView:
    if w.scrollChild != nil:
      let childRect = Rect(
        x: rect.x - w.scrollX, y: rect.y - w.scrollY,
        w: rect.w + w.scrollX, h: rect.h + w.scrollY,
      )
      collectWidgetEvents(w.scrollChild, childRect, hitMap, fm, depth + 1, effectiveParent)

  of wkCustom:
    if w.customChildren.len > 0 and w.customChildRects.len == w.customChildren.len:
      for i in 0 ..< w.customChildren.len:
        let childRect = clipRect(w.customChildRects[i], rect)
        if childRect.w > 0 and childRect.h > 0:
          collectWidgetEvents(w.customChildren[i], childRect, hitMap, fm,
                              depth + 1, effectiveParent)

  else:
    discard  # Leaf widgets (text, input, list, table, etc.) — no children to recurse

# ============================================================
# Render with HitMap and FocusManager collection
# ============================================================

proc renderWidgetWithEvents*(buf: var CellBuffer, w: Widget, rect: Rect,
                             hitMap: var HitMap, fm: FocusManager,
                             depth: int = 0, parentIdx: int = -1) =
  ## Render a widget and collect event routing data (hit regions, focus order).
  ## This is the event-aware overload — call this from the app loop to enable
  ## declarative event routing.
  if rect.w <= 0 or rect.h <= 0:
    return

  # Register this widget in the hit map if it has handlers or is focusable
  var myIdx = -1
  if w.hasEventHandlers or w.focusable:
    myIdx = hitMap.regions.len
    hitMap.add(rect, w, depth, parentIdx)

  # Track focus trap (deepest trapFocus widget wins)
  if w.trapFocus and depth > fm.focusTrapDepth:
    fm.focusTrapWidget = w
    fm.focusTrapDepth = depth

  # Collect focusable widgets
  if w.focusable:
    fm.addFocusable(w, rect)

  # Set the focused field on the widget based on FocusManager state
  if w.focusable:
    w.focused = (w == fm.focusedWidget)

  # Fill background
  if w.style.bg.kind != ckNone:
    buf.fill(rect.x, rect.y, rect.w, rect.h, " ", w.style)

  let effectiveParent = if myIdx >= 0: myIdx else: parentIdx

  case w.kind
  of wkContainer:
    let innerRect = Rect(
      x: rect.x + w.layout.padding.left,
      y: rect.y + w.layout.padding.top,
      w: max(0, rect.w - w.layout.padding.padH()),
      h: max(0, rect.h - w.layout.padding.padV()),
    )

    if w.children.len > 0:
      var nodes = newSeq[LayoutNode](w.children.len)
      for i, child in w.children:
        nodes[i] = LayoutNode(
          props: child.layout,
          childCount: 0,
          contentWidth: child.contentWidth,
          contentHeight: child.contentHeight,
        )

      let rects = computeLayout(nodes, innerRect,
                                w.layout.direction,
                                w.layout.gap,
                                w.layout.alignItems,
                                w.layout.justifyContent)

      for i, child in w.children:
        let clipped = clipRect(rects[i], innerRect)
        renderWidgetWithEvents(buf, child, clipped, hitMap, fm,
                               depth + 1, effectiveParent)

  of wkText:
    drawText(buf, rect, w)

  of wkBorder:
    drawBorder(buf, rect, w)
    if w.borderChild != nil:
      let innerRect = Rect(
        x: rect.x + 1,
        y: rect.y + 1,
        w: max(0, rect.w - 2),
        h: max(0, rect.h - 2),
      )
      renderWidgetWithEvents(buf, w.borderChild, innerRect, hitMap, fm,
                             depth + 1, effectiveParent)

  of wkInput:
    drawInput(buf, rect, w)

  of wkList:
    drawList(buf, rect, w)

  of wkTable:
    drawTable(buf, rect, w)

  of wkSpacer:
    discard

  of wkScrollView:
    if w.scrollChild != nil:
      let childRect = Rect(
        x: rect.x - w.scrollX,
        y: rect.y - w.scrollY,
        w: rect.w + w.scrollX,
        h: rect.h + w.scrollY,
      )
      renderWidgetWithEvents(buf, w.scrollChild, childRect, hitMap, fm,
                             depth + 1, effectiveParent)

  of wkProgressBar:
    drawProgressBar(buf, rect, w)

  of wkTabs:
    drawTabs(buf, rect, w)

  of wkCustom:
    if w.customRender != nil:
      w.customRender(buf, rect)
    # After custom rendering, traverse customChildren for event routing only.
    # customRender already drew the pixels; collectWidgetEvents only registers
    # hit regions and focusable widgets without re-drawing.
    if w.customChildren.len > 0 and w.customChildRects.len == w.customChildren.len:
      for i in 0 ..< w.customChildren.len:
        let childRect = clipRect(w.customChildRects[i], rect)
        if childRect.w > 0 and childRect.h > 0:
          collectWidgetEvents(w.customChildren[i], childRect, hitMap, fm,
                              depth + 1, effectiveParent)
