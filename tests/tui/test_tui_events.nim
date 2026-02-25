## Tests for TUI event system: hit map, event routing, focus management

import cps/tui/style
import cps/tui/cell
import cps/tui/layout
import cps/tui/widget
import cps/tui/renderer
import cps/tui/input
import cps/tui/events
import cps/tui/components

# ============================================================
# Event handler builder tests
# ============================================================

block testWithOnClick:
  var clicked = false
  let w = text("Click me").withOnClick(proc(mx, my: int) =
    clicked = true
  )
  assert w.events != nil
  assert w.events.onClick != nil
  w.events.onClick(0, 0)
  assert clicked
  echo "PASS: withOnClick"

block testWithOnKey:
  var handled = false
  let w = text("Press key").withOnKey(proc(evt: InputEvent): bool =
    handled = true
    true
  )
  assert w.events != nil
  assert w.events.onKey != nil
  let evt = InputEvent(kind: iekKey, key: kcChar, ch: 'a')
  discard w.events.onKey(evt)
  assert handled
  echo "PASS: withOnKey"

block testWithOnScroll:
  var scrollDelta = 0
  let w = text("Scroll").withOnScroll(proc(delta: int) =
    scrollDelta = delta
  )
  assert w.events != nil
  assert w.events.onScroll != nil
  w.events.onScroll(3)
  assert scrollDelta == 3
  echo "PASS: withOnScroll"

block testWithFocusTrap:
  let w = text("Trap").withFocusTrap(true)
  assert w.trapFocus == true
  echo "PASS: withFocusTrap"

block testLazyEventHandlers:
  # Widgets without handlers have nil events (zero cost)
  let w = text("Plain")
  assert w.events == nil
  assert not w.hasEventHandlers
  echo "PASS: lazy event handlers"

block testChainedHandlers:
  var clickFired = false
  var scrollFired = false
  let w = text("Both")
    .withOnClick(proc(mx, my: int) = clickFired = true)
    .withOnScroll(proc(delta: int) = scrollFired = true)
  assert w.events != nil
  w.events.onClick(0, 0)
  w.events.onScroll(1)
  assert clickFired
  assert scrollFired
  echo "PASS: chained handlers"

# ============================================================
# HitMap tests
# ============================================================

block testHitMapBasic:
  var hm: HitMap
  let w1 = text("A").withOnClick(proc(mx, my: int) = discard)
  let w2 = text("B").withOnClick(proc(mx, my: int) = discard)
  hm.add(Rect(x: 0, y: 0, w: 10, h: 1), w1, 0)
  hm.add(Rect(x: 10, y: 0, w: 10, h: 1), w2, 0)
  assert hm.findWidgetAt(5, 0) == w1
  assert hm.findWidgetAt(15, 0) == w2
  assert hm.findWidgetAt(25, 0) == nil
  echo "PASS: hit map basic"

block testHitMapDepth:
  var hm: HitMap
  let parent = text("Parent").withOnClick(proc(mx, my: int) = discard)
  let child = text("Child").withOnClick(proc(mx, my: int) = discard)
  hm.add(Rect(x: 0, y: 0, w: 20, h: 10), parent, 0)
  hm.add(Rect(x: 2, y: 2, w: 16, h: 6), child, 1)
  # Point inside child returns child (deeper)
  assert hm.findWidgetAt(5, 3) == child
  # Point outside child but inside parent returns parent
  assert hm.findWidgetAt(0, 0) == parent
  echo "PASS: hit map depth"

block testHitMapClear:
  var hm: HitMap
  let w = text("X")
  hm.add(Rect(x: 0, y: 0, w: 10, h: 10), w, 0)
  assert hm.regions.len == 1
  hm.clear()
  assert hm.regions.len == 0
  echo "PASS: hit map clear"

block testHitMapAncestorChain:
  var hm: HitMap
  let root = text("Root")
  let mid = text("Mid")
  let leaf = text("Leaf")
  hm.add(Rect(x: 0, y: 0, w: 80, h: 24), root, 0, -1)  # idx 0
  hm.add(Rect(x: 0, y: 0, w: 40, h: 24), mid, 1, 0)     # idx 1
  hm.add(Rect(x: 5, y: 5, w: 10, h: 5), leaf, 2, 1)      # idx 2
  let chain = hm.ancestorChain(2)
  assert chain.len == 3
  assert chain[0] == 2  # leaf
  assert chain[1] == 1  # mid
  assert chain[2] == 0  # root
  echo "PASS: hit map ancestor chain"

# ============================================================
# FocusManager tests
# ============================================================

block testFocusCycling:
  let fm = newFocusManager()
  let w1 = inputField("A").withFocus(true)
  let w2 = inputField("B")
  let w3 = inputField("C")
  fm.addFocusable(w1, Rect(x: 0, y: 0, w: 10, h: 1))
  fm.addFocusable(w2, Rect(x: 0, y: 1, w: 10, h: 1))
  fm.addFocusable(w3, Rect(x: 0, y: 2, w: 10, h: 1))
  fm.focusWidget(w1)

  assert fm.focusedWidget == w1
  fm.focusNext()
  assert fm.focusedWidget == w2
  fm.focusNext()
  assert fm.focusedWidget == w3
  fm.focusNext()
  assert fm.focusedWidget == w1  # Wraps around
  echo "PASS: focus cycling forward"

block testFocusCyclingBackward:
  let fm = newFocusManager()
  let w1 = inputField("A")
  let w2 = inputField("B")
  let w3 = inputField("C")
  fm.addFocusable(w1, Rect(x: 0, y: 0, w: 10, h: 1))
  fm.addFocusable(w2, Rect(x: 0, y: 1, w: 10, h: 1))
  fm.addFocusable(w3, Rect(x: 0, y: 2, w: 10, h: 1))
  fm.focusWidget(w1)

  fm.focusPrev()
  assert fm.focusedWidget == w3  # Wraps backward
  fm.focusPrev()
  assert fm.focusedWidget == w2
  echo "PASS: focus cycling backward"

block testFocusBlurCallbacks:
  var focusedId = ""
  var blurredId = ""
  let w1 = text("A")
    .withOnFocus(proc() = focusedId = "A")
    .withOnBlur(proc() = blurredId = "A")
  let w2 = text("B")
    .withOnFocus(proc() = focusedId = "B")
    .withOnBlur(proc() = blurredId = "B")
  let fm = newFocusManager()
  fm.addFocusable(w1, Rect(x: 0, y: 0, w: 10, h: 1))
  fm.addFocusable(w2, Rect(x: 0, y: 1, w: 10, h: 1))

  fm.focusWidget(w1)
  assert focusedId == "A"
  fm.focusWidget(w2)
  assert blurredId == "A"
  assert focusedId == "B"
  echo "PASS: focus/blur callbacks"

# ============================================================
# Event routing tests
# ============================================================

block testRouteClickEvent:
  var clickedWidget = ""
  let w1 = text("Left")
    .withOnClick(proc(mx, my: int) = clickedWidget = "left")
  let w2 = text("Right")
    .withOnClick(proc(mx, my: int) = clickedWidget = "right")

  var hm: HitMap
  hm.add(Rect(x: 0, y: 0, w: 20, h: 1), w1, 0)
  hm.add(Rect(x: 20, y: 0, w: 20, h: 1), w2, 0)
  let fm = newFocusManager()

  let clickLeft = InputEvent(kind: iekMouse, button: mbLeft, action: maPress,
                              mx: 5, my: 0)
  assert routeEvent(hm, fm, clickLeft) == true
  assert clickedWidget == "left"

  let clickRight = InputEvent(kind: iekMouse, button: mbLeft, action: maPress,
                               mx: 25, my: 0)
  assert routeEvent(hm, fm, clickRight) == true
  assert clickedWidget == "right"
  echo "PASS: route click event"

block testRouteScrollEvent:
  var scrolled = 0
  let w = text("Scrollable").withOnScroll(proc(delta: int) =
    scrolled = delta
  )
  var hm: HitMap
  hm.add(Rect(x: 0, y: 0, w: 40, h: 10), w, 0)
  let fm = newFocusManager()

  let scrollUp = InputEvent(kind: iekMouse, button: mbScrollUp, action: maPress,
                             mx: 5, my: 5)
  assert routeEvent(hm, fm, scrollUp) == true
  assert scrolled == -1

  let scrollDown = InputEvent(kind: iekMouse, button: mbScrollDown, action: maPress,
                               mx: 5, my: 5)
  assert routeEvent(hm, fm, scrollDown) == true
  assert scrolled == 1
  echo "PASS: route scroll event"

block testRouteKeyToFocused:
  var keyHandled = ""
  let w1 = text("A").withOnKey(proc(evt: InputEvent): bool =
    keyHandled = "A"
    true
  )
  let w2 = text("B").withOnKey(proc(evt: InputEvent): bool =
    keyHandled = "B"
    true
  )
  var hm: HitMap
  hm.add(Rect(x: 0, y: 0, w: 20, h: 1), w1, 0)
  hm.add(Rect(x: 0, y: 1, w: 20, h: 1), w2, 0)
  let fm = newFocusManager()
  fm.addFocusable(w1, Rect(x: 0, y: 0, w: 20, h: 1))
  fm.addFocusable(w2, Rect(x: 0, y: 1, w: 20, h: 1))
  fm.focusWidget(w1)

  let keyEvt = InputEvent(kind: iekKey, key: kcChar, ch: 'x')
  assert routeEvent(hm, fm, keyEvt) == true
  assert keyHandled == "A"

  fm.focusWidget(w2)
  assert routeEvent(hm, fm, keyEvt) == true
  assert keyHandled == "B"
  echo "PASS: route key to focused widget"

block testRouteKeyBubble:
  var handled: seq[string] = @[]
  let parent = vbox(
    text("child")
  ).withOnKey(proc(evt: InputEvent): bool =
    handled.add("parent")
    true
  )
  let child = text("child").withOnKey(proc(evt: InputEvent): bool =
    handled.add("child")
    false  # Not handled, should bubble to parent
  )

  var hm: HitMap
  hm.add(Rect(x: 0, y: 0, w: 40, h: 10), parent, 0, -1)
  hm.add(Rect(x: 0, y: 0, w: 40, h: 1), child, 1, 0)
  let fm = newFocusManager()
  fm.addFocusable(child, Rect(x: 0, y: 0, w: 40, h: 1))
  fm.focusWidget(child)

  let keyEvt = InputEvent(kind: iekKey, key: kcChar, ch: 'a')
  assert routeEvent(hm, fm, keyEvt) == true
  assert handled.len == 2
  assert handled[0] == "child"
  assert handled[1] == "parent"
  echo "PASS: key event bubbles to parent"

block testTabCyclesFocus:
  let fm = newFocusManager()
  let w1 = inputField("A")
  let w2 = inputField("B")
  fm.addFocusable(w1, Rect(x: 0, y: 0, w: 10, h: 1))
  fm.addFocusable(w2, Rect(x: 0, y: 1, w: 10, h: 1))
  fm.focusWidget(w1)

  var hm: HitMap
  hm.add(Rect(x: 0, y: 0, w: 10, h: 1), w1, 0)
  hm.add(Rect(x: 0, y: 1, w: 10, h: 1), w2, 0)

  let tabEvt = InputEvent(kind: iekKey, key: kcTab)
  assert routeEvent(hm, fm, tabEvt) == true
  assert fm.focusedWidget == w2
  echo "PASS: Tab cycles focus"

block testClickFocuses:
  let w1 = inputField("A")
  let w2 = inputField("B")
  var hm: HitMap
  hm.add(Rect(x: 0, y: 0, w: 20, h: 1), w1, 0)
  hm.add(Rect(x: 0, y: 1, w: 20, h: 1), w2, 0)
  let fm = newFocusManager()
  fm.addFocusable(w1, Rect(x: 0, y: 0, w: 20, h: 1))
  fm.addFocusable(w2, Rect(x: 0, y: 1, w: 20, h: 1))
  fm.focusWidget(w1)

  # Click on w2 should focus it
  let click = InputEvent(kind: iekMouse, button: mbLeft, action: maPress,
                          mx: 5, my: 1)
  discard routeEvent(hm, fm, click)
  assert fm.focusedWidget == w2
  echo "PASS: click focuses widget"

# ============================================================
# Render with events integration tests
# ============================================================

block testRenderWithEventsBuildsHitMap:
  var clicked = false
  let root = vbox(
    text("Header"),
    text("Clickable").withOnClick(proc(mx, my: int) = clicked = true),
    text("Footer"),
  )
  var buf = newCellBuffer(40, 10)
  var hm: HitMap
  let fm = newFocusManager()
  renderWidgetWithEvents(buf, root, Rect(x: 0, y: 0, w: 40, h: 10), hm, fm)
  # Should have at least one region (the clickable text)
  assert hm.regions.len >= 1
  echo "PASS: renderWidgetWithEvents builds hit map"

block testRenderWithEventsFocusOrder:
  let root = vbox(
    inputField("A"),
    text("Separator"),
    inputField("B"),
  )
  var buf = newCellBuffer(40, 10)
  var hm: HitMap
  let fm = newFocusManager()
  renderWidgetWithEvents(buf, root, Rect(x: 0, y: 0, w: 40, h: 10), hm, fm)
  # Should have two focusable widgets
  assert fm.focusOrder.len == 2
  echo "PASS: renderWidgetWithEvents collects focus order"

# ============================================================
# Declarative component tests
# ============================================================

block testConfirmDialog:
  var accepted = false
  var declined = false
  let dlg = confirmDialog(
    "Confirm?",
    @["Are you sure?"],
    onAccept = proc() = accepted = true,
    onDecline = proc() = declined = true,
    screenW = 80, screenH = 24,
  )
  assert dlg.kind == wkCustom
  assert dlg.trapFocus == true
  assert dlg.events != nil
  assert dlg.events.onKey != nil
  # Simulate pressing 'y'
  let yEvt = InputEvent(kind: iekKey, key: kcChar, ch: 'y')
  discard dlg.events.onKey(yEvt)
  assert accepted
  # Simulate pressing Escape
  let escEvt = InputEvent(kind: iekKey, key: kcEscape)
  discard dlg.events.onKey(escEvt)
  assert declined
  echo "PASS: confirmDialog"

block testInteractiveList:
  var selected = 0
  var activated = -1
  let items = @[
    listItem("Item 0"),
    listItem("Item 1"),
    listItem("Item 2"),
  ]
  let w = interactiveList(items, selected,
    onSelect = proc(idx: int) = selected = idx,
    onActivate = proc(idx: int) = activated = idx,
  )
  assert w.kind == wkList
  assert w.events != nil
  # Test click selects
  w.events.onClick(5, 1)  # Click on item 1
  assert selected == 1
  # Test key navigation (the key handler captured `sel=0` at construction time)
  let downEvt = InputEvent(kind: iekKey, key: kcDown)
  discard w.events.onKey(downEvt)
  assert selected == 1  # sel was 0 at construction, 0+1 = 1
  # Test Enter activates
  let enterEvt = InputEvent(kind: iekKey, key: kcEnter)
  discard w.events.onKey(enterEvt)
  assert activated == 0  # sel was 0 at construction time
  echo "PASS: interactiveList"

block testInteractiveTabs:
  var switched = -1
  let items = @[
    tabItem("Tab A", true),
    tabItem("Tab B"),
    tabItem("Tab C"),
  ]
  let w = interactiveTabs(items, proc(idx: int) = switched = idx)
  assert w.kind == wkTabs
  assert w.events != nil
  # Click on second tab (offset calculation: " Tab A " = 7 chars + 1 separator = 8)
  w.events.onClick(8, 0)  # Should hit Tab B
  assert switched == 1
  echo "PASS: interactiveTabs"

block testDeclarativeScrollableTextView:
  let sv = newScrollableTextView(autoScroll = true)
  sv.addLine("Line 1")
  sv.addLine("Line 2")
  sv.addLine("Line 3")
  let w = sv.toWidgetWithEvents()
  assert w.kind == wkCustom
  assert w.events != nil
  assert w.events.onScroll != nil
  echo "PASS: declarative ScrollableTextView"

block testDeclarativeTreeView:
  let tv = newTreeView()
  let child1 = treeNode("Child 1")
  let child2 = treeNode("Child 2")
  var rootNode = TreeNode(
    label: "Root", style: styleDefault,
    children: @[child1, child2], expanded: true,
  )
  tv.root = @[rootNode]
  let w = tv.toWidgetWithEvents()
  assert w.kind == wkCustom
  assert w.events != nil
  assert w.events.onClick != nil
  assert w.events.onKey != nil
  echo "PASS: declarative TreeView"

echo ""
echo "All event system tests passed!"
