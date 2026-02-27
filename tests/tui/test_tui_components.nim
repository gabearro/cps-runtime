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

# ============================================================
# Overlay tests
# ============================================================

block testOverlay:
  let a = text("Bottom layer")
  let b = text("Top layer")
  let w = overlay(a, b)
  assert w.kind == wkCustom
  assert w.customChildren.len == 2
  assert w.customChildren[0] == a
  assert w.customChildren[1] == b
  echo "PASS: overlay"

block testOverlayRender:
  var buf = newCellBuffer(20, 5)
  let bottom = text("AAAA", style(clRed))
  let top = text("BB", style(clGreen))
  let w = overlay(bottom, top)
  renderWidget(buf, w, Rect(x: 0, y: 0, w: 20, h: 5))
  # Top layer renders last, so "BB" should be at (0,0)
  assert buf[0, 0].ch == "B"
  assert buf[1, 0].ch == "B"
  echo "PASS: overlay render"

block testOverlayCustomChildRects:
  var buf = newCellBuffer(30, 10)
  let a = text("A")
  let b = text("B")
  let w = overlay(a, b)
  renderWidget(buf, w, Rect(x: 5, y: 2, w: 20, h: 8))
  # After render, customChildRects should match the render rect
  assert w.customChildRects.len == 2
  assert w.customChildRects[0] == Rect(x: 5, y: 2, w: 20, h: 8)
  assert w.customChildRects[1] == Rect(x: 5, y: 2, w: 20, h: 8)
  echo "PASS: overlay customChildRects"

block testOverlaySingle:
  let a = text("Only child")
  let w = overlay(a)
  assert w.kind == wkCustom
  assert w.customChildren.len == 1
  echo "PASS: overlay single child"

# ============================================================
# DimOverlay tests
# ============================================================

block testDimOverlay:
  let base = text("Base content")
  let modal = text("Modal content")
  let w = dimOverlay(base, modal, 40, 10)
  assert w.kind == wkCustom
  assert w.customChildren.len == 2
  assert w.customChildren[0] == base
  assert w.customChildren[1] == modal
  echo "PASS: dim overlay"

block testDimOverlayRender:
  var buf = newCellBuffer(20, 5)
  let base = text("Hello", style(clWhite))
  let modal = text("X", style(clRed))
  let w = dimOverlay(base, modal, 20, 5)
  renderWidget(buf, w, Rect(x: 0, y: 0, w: 20, h: 5))
  # Modal renders on top, so "X" is at (0,0)
  assert buf[0, 0].ch == "X"
  echo "PASS: dim overlay render"

# ============================================================
# CenteredPopup tests
# ============================================================

block testCenteredPopup:
  var buf = newCellBuffer(40, 20)
  let body = text("Popup body")
  let w = centeredPopup(body, "Title", 40, 20, 20, 10)
  renderWidget(buf, w, Rect(x: 0, y: 0, w: 40, h: 20))
  # Popup should be centered: dx = (40-20)/2 = 10, dy = (20-10)/2 = 5
  assert buf[10, 5].ch == "╭"  # Top-left border (bsRounded)
  assert buf[29, 5].ch == "╮"  # Top-right border
  assert buf[10, 14].ch == "╰" # Bottom-left border
  assert buf[29, 14].ch == "╯" # Bottom-right border
  echo "PASS: centered popup"

block testCenteredPopupTitle:
  var buf = newCellBuffer(40, 20)
  let body = text("Content")
  let w = centeredPopup(body, "Test", 40, 20, 20, 10)
  renderWidget(buf, w, Rect(x: 0, y: 0, w: 40, h: 20))
  # Title " Test " starts at dx+2 = 12
  assert buf[13, 5].ch == "T"
  assert buf[14, 5].ch == "e"
  assert buf[15, 5].ch == "s"
  assert buf[16, 5].ch == "t"
  echo "PASS: centered popup title"

block testCenteredPopupShadow:
  var buf = newCellBuffer(40, 20)
  let body = text("Content")
  let shadowSt = style(clBrightBlack)
  let w = centeredPopup(body, "Test", 40, 20, 20, 10,
                        shadowStyle = shadowSt)
  renderWidget(buf, w, Rect(x: 0, y: 0, w: 40, h: 20))
  # Shadow is at (dx+1, dy+1) = (11, 6) with style applied
  # The popup background overwrites most of the shadow, but bottom-right corner of shadow should show
  assert buf[30, 15].style.fg == clBrightBlack  # Shadow extends 1 beyond popup
  echo "PASS: centered popup shadow"

# ============================================================
# LabeledField tests
# ============================================================

block testLabeledField:
  let ti = newTextInput("Nickname")
  ti.insertStr("testuser")
  let w = labeledField("Nick:", ti, focused = true)
  assert w.kind == wkContainer  # hbox = container with horizontal dir
  assert w.children.len == 2
  assert w.children[0].kind == wkText
  assert w.children[1].kind == wkInput
  assert ti.focused == true
  echo "PASS: labeled field"

block testLabeledFieldUnfocused:
  let ti = newTextInput()
  let w = labeledField("Label:", ti, focused = false)
  assert w.kind == wkContainer
  assert ti.focused == false
  echo "PASS: labeled field unfocused"

block testLabeledFieldWithIndicator:
  let ti = newTextInput()
  let w = labeledField("Name:", ti, focused = true,
                       indicator = "> ")
  assert w.children[0].text == "> Name:"
  echo "PASS: labeled field with indicator"

block testLabeledFieldWithOnClick:
  var clicked = false
  let ti = newTextInput()
  let handler: ClickHandler = proc(mx, my: int) = clicked = true
  let w = labeledField("Test:", ti, focused = false, onClick = handler)
  assert w.events != nil
  assert w.events.onClick != nil
  w.events.onClick(0, 0)
  assert clicked
  echo "PASS: labeled field with onClick"

block testLabeledFieldRender:
  var buf = newCellBuffer(40, 1)
  let ti = newTextInput()
  ti.insertStr("hello")
  let w = labeledField("Name:", ti, focused = true,
                       indicator = "> ", labelWidth = 10)
  renderWidget(buf, w, Rect(x: 0, y: 0, w: 40, h: 1))
  assert buf[0, 0].ch == ">"
  assert buf[2, 0].ch == "N"
  echo "PASS: labeled field render"

# ============================================================
# Overlay DSL tests
# ============================================================

block testOverlayDsl:
  let w = tui:
    overlay:
      text "Bottom"
      text "Top"
  assert w.kind == wkCustom
  assert w.customChildren.len == 2
  echo "PASS: overlay DSL"

block testOverlayDslNested:
  let w = tui:
    vbox:
      text "Header"
      overlay:
        text "Base"
        text "Modal"
  assert w.kind == wkContainer
  assert w.children.len == 2
  assert w.children[1].kind == wkCustom  # overlay
  assert w.children[1].customChildren.len == 2
  echo "PASS: overlay DSL nested"

# ============================================================
# formFields tests
# ============================================================

block testFormFields:
  let labels = ["Name:", "Host:", "Port:"]
  var fields = [newTextInput(), newTextInput(), newTextInput()]
  fields[0].insertStr("alice")
  fields[1].insertStr("irc.libera.chat")
  fields[2].insertStr("6667")
  let widgets = formFields(labels, fields, focusIdx = 1)
  assert widgets.len == 3
  # Second field should be focused
  assert fields[1].focused == true
  assert fields[0].focused == false
  # Each widget is an hbox with text + input
  for w in widgets:
    assert w.kind == wkContainer
    assert w.children.len == 2
  echo "PASS: formFields"

block testFormFieldsWithClickHandler:
  let labels = ["A:", "B:"]
  var fields = [newTextInput(), newTextInput()]
  var clicked = -1
  let factory = proc(i: int): ClickHandler =
    let idx = i
    result = proc(mx, my: int) = clicked = idx
  let widgets = formFields(labels, fields, focusIdx = 0,
                           clickHandlerFactory = factory)
  assert widgets.len == 2
  # First should have event handler (from click)
  assert widgets[0].hasEventHandlers()
  assert widgets[1].hasEventHandlers()
  echo "PASS: formFields with click handler"

# ============================================================
# cycleFocus tests
# ============================================================

block testCycleFocusTab:
  var idx = 0
  let tabEvt = InputEvent(kind: iekKey, key: kcTab, keyMods: {})
  assert cycleFocus(idx, 3, tabEvt) == true
  assert idx == 1
  assert cycleFocus(idx, 3, tabEvt) == true
  assert idx == 2
  assert cycleFocus(idx, 3, tabEvt) == true
  assert idx == 0  # Wraps around
  echo "PASS: cycleFocus Tab"

block testCycleFocusShiftTab:
  var idx = 0
  let shiftTabEvt = InputEvent(kind: iekKey, key: kcTab, keyMods: {kmShift})
  assert cycleFocus(idx, 3, shiftTabEvt) == true
  assert idx == 2  # Wraps backward
  assert cycleFocus(idx, 3, shiftTabEvt) == true
  assert idx == 1
  echo "PASS: cycleFocus Shift+Tab"

block testCycleFocusUpDown:
  var idx = 1
  let downEvt = InputEvent(kind: iekKey, key: kcDown, keyMods: {})
  let upEvt = InputEvent(kind: iekKey, key: kcUp, keyMods: {})
  assert cycleFocus(idx, 3, downEvt) == true
  assert idx == 2
  assert cycleFocus(idx, 3, upEvt) == true
  assert idx == 1
  echo "PASS: cycleFocus Up/Down"

block testCycleFocusUnhandled:
  var idx = 1
  let enterEvt = InputEvent(kind: iekKey, key: kcEnter, keyMods: {})
  assert cycleFocus(idx, 3, enterEvt) == false
  assert idx == 1  # Unchanged
  echo "PASS: cycleFocus unhandled key"

# ============================================================
# listNavigate tests
# ============================================================

block testListNavigateDown:
  var sel = 0
  let downEvt = InputEvent(kind: iekKey, key: kcDown, keyMods: {})
  assert listNavigate(sel, 5, downEvt) == true
  assert sel == 1
  echo "PASS: listNavigate down"

block testListNavigateUp:
  var sel = 3
  let upEvt = InputEvent(kind: iekKey, key: kcUp, keyMods: {})
  assert listNavigate(sel, 5, upEvt) == true
  assert sel == 2
  echo "PASS: listNavigate up"

block testListNavigateClamp:
  var sel = 4
  let downEvt = InputEvent(kind: iekKey, key: kcDown, keyMods: {})
  assert listNavigate(sel, 5, downEvt) == true
  assert sel == 4  # Clamped at end
  var sel2 = 0
  let upEvt = InputEvent(kind: iekKey, key: kcUp, keyMods: {})
  assert listNavigate(sel2, 5, upEvt) == true
  assert sel2 == 0  # Clamped at start
  echo "PASS: listNavigate clamp"

block testListNavigateWrap:
  var sel = 4
  let downEvt = InputEvent(kind: iekKey, key: kcDown, keyMods: {})
  assert listNavigate(sel, 5, downEvt, wrap = true) == true
  assert sel == 0  # Wrapped to start
  var sel2 = 0
  let upEvt = InputEvent(kind: iekKey, key: kcUp, keyMods: {})
  assert listNavigate(sel2, 5, upEvt, wrap = true) == true
  assert sel2 == 4  # Wrapped to end
  echo "PASS: listNavigate wrap"

block testListNavigateEmpty:
  var sel = 0
  let downEvt = InputEvent(kind: iekKey, key: kcDown, keyMods: {})
  assert listNavigate(sel, 0, downEvt) == false  # No items
  assert sel == 0
  echo "PASS: listNavigate empty"

# ============================================================
# confirmDialog tests
# ============================================================

block testConfirmDialog:
  var choice: ConfirmChoice = ccNo
  let w = confirmDialog("Test", @[text("Confirm?")],
    onChoice = proc(c: ConfirmChoice) = choice = c)
  assert w.kind == wkBorder
  assert w.borderTitle == "Test"
  assert w.trapFocus == true
  assert w.focused == true
  assert w.hasEventHandlers()
  echo "PASS: confirmDialog"

block testConfirmDialogYes:
  var choice: ConfirmChoice = ccNo
  let w = confirmDialog("Test", @[text("Confirm?")],
    onChoice = proc(c: ConfirmChoice) = choice = c)
  let yEvt = InputEvent(kind: iekKey, key: kcChar, ch: 'Y', keyMods: {})
  let handled = w.events.onKey(yEvt)
  assert handled == true
  assert choice == ccYes
  echo "PASS: confirmDialog Y choice"

block testConfirmDialogNo:
  var choice: ConfirmChoice = ccNo
  var called = false
  let w = confirmDialog("Test", @[text("Confirm?")],
    onChoice = proc(c: ConfirmChoice) = called = true; choice = c)
  let nEvt = InputEvent(kind: iekKey, key: kcChar, ch: 'n', keyMods: {})
  let handled = w.events.onKey(nEvt)
  assert handled == true
  assert called == true
  assert choice == ccNo
  echo "PASS: confirmDialog N choice"

block testConfirmDialogEscape:
  var choice: ConfirmChoice = ccYes  # Start with Yes to confirm it changes
  let w = confirmDialog("Test", @[text("Confirm?")],
    onChoice = proc(c: ConfirmChoice) = choice = c)
  let escEvt = InputEvent(kind: iekKey, key: kcEscape, keyMods: {})
  let handled = w.events.onKey(escEvt)
  assert handled == true
  assert choice == ccNo  # Escape = No
  echo "PASS: confirmDialog Escape"

# ============================================================
# modalOverlay tests
# ============================================================

# ============================================================
# centeredForm tests
# ============================================================

block testCenteredForm:
  let body = text("Hello")
  let w = centeredForm(body, "Test Form", screenW = 80)
  # Should be a vbox (no footer) or hbox (just the centered content)
  # With no footer, it returns the hbox directly
  assert w.kind == wkContainer
  assert w.layout.direction == dirHorizontal
  echo "PASS: centeredForm"

block testCenteredFormWithFooter:
  let body = text("Hello")
  let footer = text("Footer")
  let w = centeredForm(body, "Test Form", screenW = 80, footer = footer)
  # With footer, it's a vbox with [hbox, footer]
  assert w.kind == wkContainer
  assert w.layout.direction == dirVertical
  assert w.children.len == 2
  echo "PASS: centeredForm with footer"

# ============================================================
# modalOverlay tests
# ============================================================

block testModalOverlay:
  let base = text("Background")
  let modal = text("Modal content")
  let w = modalOverlay(base, modal)
  assert w.kind == wkCustom
  assert w.trapFocus == true
  assert w.focused == true
  assert w.hasEventHandlers()
  echo "PASS: modalOverlay"

block testModalOverlayDismiss:
  var dismissed = false
  let w = modalOverlay(text("bg"), text("fg"),
    onDismiss = proc() = dismissed = true)
  let escEvt = InputEvent(kind: iekKey, key: kcEscape, keyMods: {})
  let handled = w.events.onKey(escEvt)
  assert handled == true
  assert dismissed == true
  echo "PASS: modalOverlay dismiss"

block testModalOverlayTrapsKeys:
  let w = modalOverlay(text("bg"), text("fg"))
  let charEvt = InputEvent(kind: iekKey, key: kcChar, ch: 'x', keyMods: {})
  let handled = w.events.onKey(charEvt)
  assert handled == true  # All keys trapped
  echo "PASS: modalOverlay traps all keys"

echo ""
echo "All TUI component tests passed!"
