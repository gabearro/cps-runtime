## CPS TUI - Event System
##
## Hit map construction and event routing through the widget tree.
## The hit map is built during render traversal — each widget with event
## handlers or focusability registers a HitRegion with its screen rect.
## Events are routed from deepest (topmost) to shallowest (bottommost).

import ./widget
import ./input
import ./layout

type
  HitRegion* = object
    rect*: Rect
    widget*: Widget
    depth*: int               ## Nesting depth (deeper = rendered on top)
    parentIdx*: int           ## Index of parent region (-1 for root)

  HitMap* = object
    regions*: seq[HitRegion]  ## Collected during render, leaf-first order

  FocusManager* = ref object
    focusedWidget*: Widget    ## Currently focused widget (nil = none)
    focusOrder*: seq[Widget]  ## Focusable widgets in render traversal order
    focusRects*: seq[Rect]    ## Rects for focusable widgets (parallel to focusOrder)
    focusTrapWidget*: Widget  ## Deepest focus-trapping ancestor (nil = none)
    focusTrapDepth*: int      ## Depth of the focus trap widget
    focusTrapIdx*: int        ## HitMap index of the focus trap widget (-1 = none)

# ============================================================
# HitMap
# ============================================================

proc clear*(hm: var HitMap) =
  hm.regions.setLen(0)

proc add*(hm: var HitMap, rect: Rect, w: Widget, depth: int,
          parentIdx: int = -1) =
  if rect.w > 0 and rect.h > 0:
    hm.regions.add(HitRegion(rect: rect, widget: w, depth: depth,
                              parentIdx: parentIdx))

proc findAt*(hm: HitMap, x, y: int): int =
  ## Find the deepest HitRegion containing (x, y).
  ## Returns index into regions, or -1 if none.
  result = -1
  var bestDepth = -1
  for i in 0 ..< hm.regions.len:
    let r = hm.regions[i]
    if x >= r.rect.x and x < r.rect.x + r.rect.w and
       y >= r.rect.y and y < r.rect.y + r.rect.h and
       r.depth > bestDepth:
      result = i
      bestDepth = r.depth

proc findWidgetAt*(hm: HitMap, x, y: int): Widget =
  ## Find the deepest widget containing (x, y), or nil.
  let idx = hm.findAt(x, y)
  if idx >= 0: hm.regions[idx].widget
  else: nil

proc ancestorChain*(hm: HitMap, idx: int): seq[int] =
  ## Walk parent chain from idx to root, returning indices.
  result = @[idx]
  var cur = idx
  while cur >= 0 and hm.regions[cur].parentIdx >= 0:
    cur = hm.regions[cur].parentIdx
    result.add(cur)

# ============================================================
# FocusManager
# ============================================================

proc newFocusManager*(): FocusManager =
  FocusManager(focusTrapDepth: -1, focusTrapIdx: -1)

proc clear*(fm: FocusManager) =
  fm.focusOrder.setLen(0)
  fm.focusRects.setLen(0)
  fm.focusTrapWidget = nil
  fm.focusTrapDepth = -1
  fm.focusTrapIdx = -1

proc addFocusable*(fm: FocusManager, w: Widget, rect: Rect) =
  fm.focusOrder.add(w)
  fm.focusRects.add(rect)

proc isInsideFocusTrap*(hm: HitMap, fm: FocusManager,
                        widgetIdx: int, parentIdx: int): bool =
  ## Check if a widget (by its hitmap index or parent chain) is inside the
  ## current focus trap's subtree. Returns true if no focus trap is active.
  if fm.focusTrapIdx < 0:
    return true  # No trap — always allowed
  # The focus trap widget itself is inside
  if widgetIdx == fm.focusTrapIdx:
    return true
  # Walk the parent chain from the widget's parent
  var cur = parentIdx
  while cur >= 0:
    if cur == fm.focusTrapIdx:
      return true
    cur = hm.regions[cur].parentIdx
  return false

proc focusedIndex*(fm: FocusManager): int =
  ## Return the index of the currently focused widget in focusOrder, or -1.
  if fm.focusedWidget == nil:
    return -1
  for i, w in fm.focusOrder:
    if w == fm.focusedWidget:
      return i
  return -1

proc effectiveFocusOrder(fm: FocusManager): seq[int] =
  ## Return indices into focusOrder that are within the current focus trap scope.
  result = @[]
  if fm.focusTrapWidget == nil:
    for i in 0 ..< fm.focusOrder.len:
      result.add(i)
  else:
    # Only include widgets whose rect is within the trap widget's rect
    # This is a simplification — ideally we'd check the widget tree ancestry
    let trapRect = block:
      var r = Rect()
      for i, w in fm.focusOrder:
        if w == fm.focusTrapWidget:
          r = fm.focusRects[i]
          break
      r
    for i in 0 ..< fm.focusOrder.len:
      let wr = fm.focusRects[i]
      if wr.x >= trapRect.x and wr.y >= trapRect.y and
         wr.x + wr.w <= trapRect.x + trapRect.w and
         wr.y + wr.h <= trapRect.y + trapRect.h:
        result.add(i)

proc focusNext*(fm: FocusManager) =
  ## Cycle focus to the next focusable widget (Tab).
  let order = fm.effectiveFocusOrder()
  if order.len == 0:
    return
  let curIdx = fm.focusedIndex()
  # Find current in effective order
  var curPos = -1
  for i, idx in order:
    if idx == curIdx:
      curPos = i
      break
  let nextPos = if curPos < 0: 0 else: (curPos + 1) mod order.len
  let oldFocused = fm.focusedWidget
  fm.focusedWidget = fm.focusOrder[order[nextPos]]
  # Fire blur/focus callbacks
  if oldFocused != nil and oldFocused != fm.focusedWidget and
     oldFocused.events != nil and oldFocused.events.onBlur != nil:
    oldFocused.events.onBlur()
  if fm.focusedWidget != nil and fm.focusedWidget != oldFocused and
     fm.focusedWidget.events != nil and fm.focusedWidget.events.onFocus != nil:
    fm.focusedWidget.events.onFocus()

proc focusPrev*(fm: FocusManager) =
  ## Cycle focus to the previous focusable widget (Shift+Tab).
  let order = fm.effectiveFocusOrder()
  if order.len == 0:
    return
  let curIdx = fm.focusedIndex()
  var curPos = -1
  for i, idx in order:
    if idx == curIdx:
      curPos = i
      break
  let prevPos = if curPos < 0: order.len - 1
                elif curPos == 0: order.len - 1
                else: curPos - 1
  let oldFocused = fm.focusedWidget
  fm.focusedWidget = fm.focusOrder[order[prevPos]]
  if oldFocused != nil and oldFocused != fm.focusedWidget and
     oldFocused.events != nil and oldFocused.events.onBlur != nil:
    oldFocused.events.onBlur()
  if fm.focusedWidget != nil and fm.focusedWidget != oldFocused and
     fm.focusedWidget.events != nil and fm.focusedWidget.events.onFocus != nil:
    fm.focusedWidget.events.onFocus()

proc focusWidget*(fm: FocusManager, w: Widget) =
  ## Focus a specific widget (e.g., on mouse click).
  if w == fm.focusedWidget:
    return
  let oldFocused = fm.focusedWidget
  fm.focusedWidget = w
  if oldFocused != nil and oldFocused.events != nil and
     oldFocused.events.onBlur != nil:
    oldFocused.events.onBlur()
  if w != nil and w.events != nil and w.events.onFocus != nil:
    w.events.onFocus()

# ============================================================
# Event Routing
# ============================================================

proc routeMouseEvent*(hm: HitMap, fm: FocusManager, evt: InputEvent): bool =
  ## Route a mouse event through the hit map. Returns true if handled.
  if evt.kind != iekMouse:
    return false

  # Scroll events
  if evt.button == mbScrollUp or evt.button == mbScrollDown:
    let idx = hm.findAt(evt.mx, evt.my)
    if idx >= 0:
      # Walk from deepest to shallowest looking for a scroll handler
      let chain = hm.ancestorChain(idx)
      for ci in chain:
        let w = hm.regions[ci].widget
        if w.events != nil and w.events.onScroll != nil:
          let delta = if evt.button == mbScrollUp: -1 else: 1
          w.events.onScroll(delta)
          return true
    return false

  # Click events (left button press)
  if evt.action == maPress and evt.button == mbLeft:
    let idx = hm.findAt(evt.mx, evt.my)
    if idx >= 0:
      let chain = hm.ancestorChain(idx)
      # Focus the clicked widget if focusable
      for ci in chain:
        let w = hm.regions[ci].widget
        if w.focusable:
          fm.focusWidget(w)
          break
      # Fire onClick on the deepest widget with one
      for ci in chain:
        let w = hm.regions[ci].widget
        let r = hm.regions[ci].rect
        if w.events != nil and w.events.onClick != nil:
          w.events.onClick(evt.mx - r.x, evt.my - r.y)
          return true
      # No onClick handled it — fall through to onMouse so widgets
      # that use onMouse for press events (e.g., drag start) get it.
      for ci in chain:
        let w = hm.regions[ci].widget
        if w.events != nil and w.events.onMouse != nil:
          if w.events.onMouse(evt):
            return true
    return false

  # Generic mouse events (motion, release, non-left press)
  if evt.action == maMotion or evt.action == maRelease or
     (evt.action == maPress and evt.button != mbLeft):
    let idx = hm.findAt(evt.mx, evt.my)
    if idx >= 0:
      let chain = hm.ancestorChain(idx)
      for ci in chain:
        let w = hm.regions[ci].widget
        if w.events != nil and w.events.onMouse != nil:
          if w.events.onMouse(evt):
            return true
    return false

  return false

proc routeKeyEvent*(hm: HitMap, fm: FocusManager, evt: InputEvent): bool =
  ## Route a key event to the focused widget and bubble up. Returns true if handled.
  if evt.kind != iekKey:
    return false

  # Route to focused widget's onKey first, then handle Tab for focus cycling.
  # This allows focus-trapped widgets (e.g., autocomplete, modals) to intercept
  # Tab before the framework uses it for focus cycling.
  if fm.focusedWidget != nil:
    # Find the focused widget in the hit map to get its ancestor chain
    var focusIdx = -1
    for i in 0 ..< hm.regions.len:
      if hm.regions[i].widget == fm.focusedWidget:
        focusIdx = i
        break
    if focusIdx >= 0:
      let chain = hm.ancestorChain(focusIdx)
      for ci in chain:
        let w = hm.regions[ci].widget
        if w.events != nil and w.events.onKey != nil:
          if w.events.onKey(evt):
            return true
    elif fm.focusedWidget.events != nil and
         fm.focusedWidget.events.onKey != nil:
      # Focused widget not in hitmap (edge case), still try its handler
      if fm.focusedWidget.events.onKey(evt):
        return true

  # Tab/Shift+Tab for focus cycling (fallback if no widget consumed it)
  if evt.key == kcTab:
    if kmShift in evt.keyMods:
      fm.focusPrev()
    else:
      fm.focusNext()
    return true

  return false

proc routeEvent*(hm: HitMap, fm: FocusManager, evt: InputEvent): bool =
  ## Route an event through the widget tree. Returns true if handled.
  case evt.kind
  of iekMouse:
    return routeMouseEvent(hm, fm, evt)
  of iekKey:
    return routeKeyEvent(hm, fm, evt)
  else:
    return false
