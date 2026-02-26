## Tests for TUI higher-level components

import cps/tui/style
import cps/tui/cell
import cps/tui/layout
import cps/tui/widget
import cps/tui/renderer
import cps/tui/input
import cps/tui/textinput
import cps/tui/reactive
import cps/tui/components
import cps/tui/dsl

# ============================================================
# SplitView tests
# ============================================================

block testSplitViewCreate:
  let sv = newSplitView(dirHorizontal, 0.3)
  assert sv.direction == dirHorizontal
  assert sv.ratio == 0.3
  echo "PASS: split view create"

block testSplitViewWidget:
  let sv = newSplitView(dirHorizontal, 0.5)
  let left = text("Left pane")
  let right = text("Right pane")
  let w = sv.toWidget(left, right)
  assert w.kind == wkCustom  # toWidget uses custom() for direct pixel rendering
  echo "PASS: split view widget"

block testSplitViewVertical:
  let sv = newSplitView(dirVertical, 0.7)
  let top = text("Top")
  let bottom = text("Bottom")
  let w = sv.toWidget(top, bottom)
  assert w.kind == wkCustom  # toWidget uses custom() for direct pixel rendering
  echo "PASS: split view vertical"

block testSplitViewRender:
  var buf = newCellBuffer(40, 10)
  let sv = newSplitView(dirHorizontal, 0.5)
  let w = sv.toWidget(text("Left"), text("Right"))
  renderWidget(buf, w, Rect(x: 0, y: 0, w: 40, h: 10))
  echo "PASS: split view render"

block testSplitViewAdjust:
  let sv = newSplitView(dirHorizontal, 0.5)
  sv.adjustRatio(-0.1)
  assert sv.ratio >= 0.39 and sv.ratio <= 0.41
  sv.adjustRatio(0.3)
  assert sv.ratio >= 0.69 and sv.ratio <= 0.71
  echo "PASS: split view adjust"

block testSplitViewDragResize:
  # Verify that dragging the divider properly resizes both panels
  let sv = newSplitView(dirHorizontal, 0.3, minFirst = 5, minSecond = 5)
  let rect = Rect(x: 0, y: 0, w: 80, h: 20)

  # Compute initial divider position
  let usable = rect.w - 1  # 79 (minus 1 for divider)
  let initFirstW = int(0.3 * float(usable))  # 23

  # Simulate mouse press on the divider
  let pressEvt = InputEvent(kind: iekMouse, button: mbLeft, action: maPress,
    mx: initFirstW, my: 10, mouseMods: {})
  discard sv.handleMouse(pressEvt, rect)
  assert sv.dragging == true

  # Drag to position 40
  let motionEvt = InputEvent(kind: iekMouse, button: mbLeft, action: maMotion,
    mx: 40, my: 10, mouseMods: {})
  let changed = sv.handleMouse(motionEvt, rect)
  assert changed == true
  # Ratio should be approximately 40/79 ≈ 0.506
  assert sv.ratio > 0.49 and sv.ratio < 0.52

  # Render at new ratio and verify layout fills the full width
  var buf = newCellBuffer(80, 20)
  let w = sv.toWidget(text("Left"), text("Right"))
  renderWidget(buf, w, rect)

  # Verify no gaps: every cell in row 0 should have content
  for x in 0 ..< 80:
    assert buf[x, 0].ch != "", "Gap at x=" & $x

  # Verify divider is in the right position
  let expectedDivX = int(sv.ratio * float(usable))
  assert buf[expectedDivX, 0].ch == "│" or buf[expectedDivX, 5].ch == "│",
    "Divider not at expected position " & $expectedDivX

  # Release
  let releaseEvt = InputEvent(kind: iekMouse, button: mbLeft, action: maRelease,
    mx: 40, my: 10, mouseMods: {})
  discard sv.handleMouse(releaseEvt, rect)
  assert sv.dragging == false
  echo "PASS: split view drag resize"

block testSplitViewDiffRender:
  # Verify that diff rendering produces correct output after layout change
  let sv = newSplitView(dirHorizontal, 0.2, minFirst = 3, minSecond = 3)
  let rect = Rect(x: 0, y: 0, w: 40, h: 5)

  # Render initial layout
  var frontBuf = newCellBuffer(40, 5)
  let w1 = sv.toWidget(
    text("AAA", style(clRed)),
    text("BBB", style(clGreen))
  )
  renderWidget(frontBuf, w1, rect)

  # Change ratio
  sv.ratio = 0.5

  # Render new layout
  var backBuf = newCellBuffer(40, 5)
  let w2 = sv.toWidget(
    text("AAA", style(clRed)),
    text("BBB", style(clGreen))
  )
  renderWidget(backBuf, w2, rect)

  # Compute diff
  let diffOutput = diff(frontBuf, backBuf)

  # Diff should produce non-empty output (layout changed)
  assert diffOutput.len > 0, "Diff should detect layout change"

  # Now apply the diff conceptually: render backBuf fully and verify it matches
  let fullOutput = render(backBuf)
  assert fullOutput.len > 0

  # Verify the back buffer has the divider in the new position
  let usable = 40 - 1  # 39
  let newDivX = sv.computeFirstSize(usable)  # uses round() internally
  var foundDivider = false
  for y in 0 ..< 5:
    if backBuf[newDivX, y].ch == "│":
      foundDivider = true
      break
  assert foundDivider, "Divider should be at x=" & $newDivX
  echo "PASS: split view diff render"

# ============================================================
# ScrollableTextView tests
# ============================================================

block testScrollableTextViewCreate:
  let sv = newScrollableTextView(maxLines = 100)
  assert sv.lines.len == 0
  assert sv.autoScroll == true
  assert sv.maxLines == 100
  echo "PASS: scrollable text view create"

block testScrollableTextViewAddLine:
  let sv = newScrollableTextView()
  sv.addLine("Hello")
  sv.addLine("World", style(clGreen))
  assert sv.lines.len == 2
  assert sv.lines[0].text == "Hello"
  assert sv.lines[1].text == "World"
  assert sv.lines[1].style.fg == clGreen
  echo "PASS: scrollable text view add line"

block testScrollableTextViewMaxLines:
  let sv = newScrollableTextView(maxLines = 3)
  sv.addLine("A")
  sv.addLine("B")
  sv.addLine("C")
  sv.addLine("D")  # Should evict "A"
  assert sv.lines.len == 3
  assert sv.lines[0].text == "B"
  assert sv.lines[2].text == "D"
  echo "PASS: scrollable text view max lines"

block testScrollableTextViewScroll:
  let sv = newScrollableTextView()
  for i in 0 ..< 50:
    sv.addLine("Line " & $i)
  sv.scrollUp(10)
  assert sv.autoScroll == false
  assert sv.scrollOffset < 50
  sv.scrollToBottom()
  echo "PASS: scrollable text view scroll"

block testScrollableTextViewClear:
  let sv = newScrollableTextView()
  sv.addLine("test")
  sv.clear()
  assert sv.lines.len == 0
  echo "PASS: scrollable text view clear"

block testScrollableTextViewRender:
  var buf = newCellBuffer(30, 5)
  let sv = newScrollableTextView()
  sv.addLine("Line A")
  sv.addLine("Line B")
  sv.addLine("Line C")
  let w = sv.toWidget()
  renderWidget(buf, w, Rect(x: 0, y: 0, w: 30, h: 5))
  assert buf[0, 0].ch == "L"
  echo "PASS: scrollable text view render"

# ============================================================
# StatusBar tests
# ============================================================

block testStatusBar:
  let sb = newStatusBar()
  sb.addItem("Mode: Normal", taLeft)
  sb.addItem("Ln 42, Col 7", taRight)
  let w = sb.toWidget()
  assert w.kind == wkCustom
  echo "PASS: status bar"

block testStatusBarRender:
  var buf = newCellBuffer(40, 1)
  let sb = newStatusBar()
  sb.addItem("Left text", taLeft)
  sb.addItem("Right text", taRight)
  let w = sb.toWidget()
  renderWidget(buf, w, Rect(x: 0, y: 0, w: 40, h: 1))
  # Check that left text appears
  assert buf[0, 0].ch == "L"
  echo "PASS: status bar render"

# ============================================================
# Dialog tests
# ============================================================

block testDialog:
  let body = text("Are you sure?")
  let dlg = newDialog("Confirm", body, width = 40, height = 10)
  assert dlg.visible == true
  assert dlg.title == "Confirm"
  dlg.hide()
  assert dlg.visible == false
  dlg.toggle()
  assert dlg.visible == true
  echo "PASS: dialog"

block testDialogRender:
  var buf = newCellBuffer(80, 24)
  let body = text("Hello dialog")
  let dlg = newDialog("Test", body, width = 30, height = 8)
  let w = dlg.toWidget(80, 24)
  renderWidget(buf, w, Rect(x: 0, y: 0, w: 80, h: 24))
  # Dialog should be centered, so check border chars around center
  let dx = (80 - 30) div 2
  let dy = (24 - 8) div 2
  assert buf[dx, dy].ch == "╭"
  assert buf[dx + 29, dy].ch == "╮"
  echo "PASS: dialog render"

# ============================================================
# NotificationArea tests
# ============================================================

block testNotifications:
  let na = newNotificationArea(maxVisible = 3)
  na.notify("Connected to server", nlSuccess)
  na.notify("Warning: lag detected", nlWarning)
  assert na.notifications.len == 2
  let w = na.toWidget()
  assert w.kind == wkCustom  # custom rendering widget
  echo "PASS: notifications"

# ============================================================
# TreeView tests
# ============================================================

block testTreeView:
  let tv = newTreeView()
  tv.root = @[
    treeNode("Root", @[
      treeNode("Child 1"),
      treeNode("Child 2", @[
        treeNode("Grandchild"),
      ]),
    ], expanded = true),
  ]
  let flat = tv.flatItems()
  assert flat.len == 3  # Root + Child 1 + Child 2 (not expanded)
  assert flat[0].node.label == "Root"
  assert flat[1].node.label == "Child 1"
  assert flat[2].node.label == "Child 2"
  echo "PASS: tree view"

block testTreeViewExpand:
  let tv = newTreeView()
  tv.root = @[
    treeNode("Root", @[
      treeNode("A"),
      treeNode("B", @[treeNode("B1"), treeNode("B2")]),
    ], expanded = true),
  ]
  # Select "B" (index 2)
  tv.selectedIdx = 2
  tv.toggleExpand()
  let flat = tv.flatItems()
  assert flat.len == 5  # Root + A + B + B1 + B2
  echo "PASS: tree view expand"

block testTreeViewNavigation:
  let tv = newTreeView()
  tv.root = @[treeNode("A"), treeNode("B"), treeNode("C")]
  assert tv.selectedIdx == 0
  tv.moveDown()
  assert tv.selectedIdx == 1
  tv.moveDown()
  assert tv.selectedIdx == 2
  tv.moveDown()
  assert tv.selectedIdx == 2  # Can't go past end
  tv.moveUp()
  assert tv.selectedIdx == 1
  echo "PASS: tree view navigation"

block testTreeViewRender:
  var buf = newCellBuffer(30, 10)
  let tv = newTreeView()
  tv.root = @[
    treeNode("Root", @[treeNode("Child")], expanded = true),
  ]
  let w = tv.toWidget()
  renderWidget(buf, w, Rect(x: 0, y: 0, w: 30, h: 10))
  echo "PASS: tree view render"

# ============================================================
# InputBox tests
# ============================================================

block testInputBox:
  let ti = newTextInput("Type here...")
  ti.insertStr("hello")
  let w = inputBox("Name:", ti)
  assert w.kind == wkBorder
  echo "PASS: input box"

block testInputBoxRender:
  var buf = newCellBuffer(40, 3)
  let ti = newTextInput("Type here...")
  ti.insertStr("world")
  let w = inputBox("Name:", ti)
  renderWidget(buf, w, Rect(x: 0, y: 0, w: 40, h: 3))
  echo "PASS: input box render"

# ============================================================
# KeyHelpBar tests
# ============================================================

block testKeyHelpBar:
  let w = keyHelpBar([kh("^C", "Quit"), kh("^S", "Send"), kh("Tab", "Next")])
  assert w.kind == wkCustom
  echo "PASS: key help bar"

block testKeyHelpBarRender:
  var buf = newCellBuffer(60, 1)
  let w = keyHelpBar([kh("^C", "Quit"), kh("^S", "Send")])
  renderWidget(buf, w, Rect(x: 0, y: 0, w: 60, h: 1))
  # Should have key text rendered
  assert buf[0, 0].ch == "^"
  echo "PASS: key help bar render"

# ============================================================
# Barrel import test
# ============================================================

block testBarrelImport:
  # This block verifies the barrel module compiles and exports work
  # when importing from cps/tui
  let s = style(clRed).bold()
  let b = newCellBuffer(10, 5)
  let w = tui:
    vbox:
      text "Test"
  assert w.kind == wkContainer
  echo "PASS: barrel import"

# ============================================================
# Integration: IRC-like chat layout
# ============================================================

block testIrcChatLayout:
  var buf = newCellBuffer(80, 24)

  # Build an IRC-like layout
  let chatView = newScrollableTextView()
  chatView.addLine("<alice> Hello!", style(clCyan))
  chatView.addLine("<bob> Hey there", style(clGreen))
  chatView.addLine("<alice> How are you?", style(clCyan))

  let input = newTextInput()
  input.insertStr("/join #nim")

  let statusBar = newStatusBar()
  statusBar.addItem("[#nim]", taLeft, style(clBlack, clCyan))
  statusBar.addItem("3 users", taRight, style(clBlack, clWhite))

  let ui = vbox(
    border(
      chatView.toWidget(),
      bsRounded, "#nim",
    ).withHeight(flex()),
    statusBar.toWidget(),
    hbox(
      label("> ", style(clGreen)).withWidth(fixed(2)),
      input.toWidget(),
    ).withHeight(fixed(1)),
    keyHelpBar([kh("^C", "Quit"), kh("Enter", "Send"), kh("Tab", "Switch")]),
  )
  renderWidget(buf, ui, Rect(x: 0, y: 0, w: 80, h: 24))

  # Verify the layout rendered:
  # Top-left corner of the border
  assert buf[0, 0].ch == "╭"
  echo "PASS: IRC chat layout integration"

# ============================================================
# Mouse click handling tests
# ============================================================

block testScrollableTextViewMouseScroll:
  let sv = newScrollableTextView()
  for i in 0 ..< 50:
    sv.addLine("Line " & $i, style(clWhite))
  # Render to set lastRect
  var buf = newCellBuffer(40, 10)
  let w = sv.toWidget()
  renderWidget(buf, w, Rect(x: 5, y: 2, w: 30, h: 8))
  assert sv.lastRect.x == 5
  assert sv.lastRect.y == 2
  assert sv.lastRect.w == 30
  assert sv.lastRect.h == 8

  # Auto-scroll is on, scrolling up should disable it
  assert sv.autoScroll == true
  let scrollUpEvt = InputEvent(kind: iekMouse, button: mbScrollUp,
                               action: maPress, mx: 15, my: 4)
  assert sv.handleMouse(scrollUpEvt) == true
  assert sv.autoScroll == false

  # Scroll down
  let scrollDownEvt = InputEvent(kind: iekMouse, button: mbScrollDown,
                                 action: maPress, mx: 15, my: 4)
  assert sv.handleMouse(scrollDownEvt) == true

  # Mouse outside the rect should not scroll
  let outsideEvt = InputEvent(kind: iekMouse, button: mbScrollUp,
                              action: maPress, mx: 0, my: 0)
  assert sv.handleMouse(outsideEvt) == false
  echo "PASS: scrollable text view mouse scroll"

block testTreeViewMouseClick:
  let tv = newTreeView()
  tv.root = @[
    treeNode("Root", @[
      treeNode("A"),
      treeNode("B", @[treeNode("B1")]),
    ], expanded = true),
  ]
  # Render to set lastRect
  var buf = newCellBuffer(30, 10)
  let w = tv.toWidget()
  renderWidget(buf, w, Rect(x: 0, y: 0, w: 30, h: 10))
  assert tv.lastRect.x == 0
  assert tv.lastRect.y == 0

  # Click on row 1 ("A") should select it
  assert tv.selectedIdx == 0
  let clickEvt = InputEvent(kind: iekMouse, button: mbLeft,
                            action: maPress, mx: 5, my: 1)
  assert tv.handleMouse(clickEvt) == true
  assert tv.selectedIdx == 1

  # Click on row 2 ("B") on the expand icon area should expand it
  let flat = tv.flatItems()
  assert flat[2].node.label == "B"
  assert flat[2].node.expanded == false
  let iconX = flat[2].depth * tv.indentSize  # depth=1, indentSize=2 → x=2
  let expandEvt = InputEvent(kind: iekMouse, button: mbLeft,
                             action: maPress, mx: iconX, my: 2)
  assert tv.handleMouse(expandEvt) == true
  assert tv.selectedIdx == 2
  assert tv.root[0].children[1].expanded == true
  # Now B1 should be visible
  let flat2 = tv.flatItems()
  assert flat2.len == 4  # Root, A, B, B1

  # Click outside should not change anything
  let outsideEvt = InputEvent(kind: iekMouse, button: mbLeft,
                              action: maPress, mx: 5, my: 9)
  assert tv.handleMouse(outsideEvt) == false
  echo "PASS: tree view mouse click"

block testTextInputMouseClick:
  let ti = newTextInput()
  ti.insertStr("hello world")
  assert ti.cursor == 11  # At end

  # Click at position 5 to move cursor
  let inputRect = Rect(x: 10, y: 5, w: 30, h: 1)
  let clickEvt = InputEvent(kind: iekMouse, button: mbLeft,
                            action: maPress, mx: 15, my: 5)
  assert ti.handleMouse(clickEvt, inputRect) == true
  assert ti.cursor == 5  # 15 - 10 = 5

  # Click at position 0 (start)
  let startEvt = InputEvent(kind: iekMouse, button: mbLeft,
                            action: maPress, mx: 10, my: 5)
  assert ti.handleMouse(startEvt, inputRect) == true
  assert ti.cursor == 0

  # Click past text length should clamp to text length
  let endEvt = InputEvent(kind: iekMouse, button: mbLeft,
                          action: maPress, mx: 35, my: 5)
  assert ti.handleMouse(endEvt, inputRect) == true
  assert ti.cursor == 11  # min(25, 11)

  # Click outside rect should not move cursor
  let outsideEvt = InputEvent(kind: iekMouse, button: mbLeft,
                              action: maPress, mx: 5, my: 5)
  assert ti.handleMouse(outsideEvt, inputRect) == false
  assert ti.cursor == 11
  echo "PASS: text input mouse click"

block testHitTestTabBar:
  let tabs = @[
    tabItem("#nim", active = true),
    tabItem("#help"),
    tabItem("#dev"),
  ]
  let rect = Rect(x: 10, y: 0, w: 40, h: 1)

  # " #nim " starts at x=10, length 6
  assert hitTestTabBar(tabs, 10, 0, rect) == 0  # Start of first tab
  assert hitTestTabBar(tabs, 15, 0, rect) == 0  # End of first tab
  # Separator at x=16
  # " #help " starts at x=17, length 7
  assert hitTestTabBar(tabs, 17, 0, rect) == 1
  assert hitTestTabBar(tabs, 23, 0, rect) == 1

  # Wrong row should miss
  assert hitTestTabBar(tabs, 10, 1, rect) == -1

  # Outside rect should miss
  assert hitTestTabBar(tabs, 5, 0, rect) == -1
  echo "PASS: hit test tab bar"

block testHitTestList:
  let rect = Rect(x: 0, y: 0, w: 20, h: 5)

  assert hitTestList(3, 5, 0, rect) == 0
  assert hitTestList(3, 5, 1, rect) == 1
  assert hitTestList(3, 5, 2, rect) == 2
  assert hitTestList(3, 5, 3, rect) == -1  # Only 3 items

  # With offset
  assert hitTestList(10, 5, 0, rect, offset = 5) == 5
  assert hitTestList(10, 5, 2, rect, offset = 5) == 7

  # Outside rect
  assert hitTestList(3, 25, 0, rect) == -1
  assert hitTestList(3, 5, -1, rect) == -1
  echo "PASS: hit test list"

echo ""
echo "All TUI component tests passed!"
