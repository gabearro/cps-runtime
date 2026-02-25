## Tests for TUI core: style, cell buffer, layout, widgets, rendering, DSL

import std/strutils
import cps/tui/style
import cps/tui/cell
import cps/tui/layout
import cps/tui/widget
import cps/tui/renderer
import cps/tui/input
import cps/tui/textinput
import cps/tui/reactive
import cps/tui/dsl

# ============================================================
# Style tests
# ============================================================

block testColors:
  let c1 = clRed
  assert c1.kind == ckBasic
  assert c1.basic == 1
  let c2 = rgb(255, 128, 0)
  assert c2.kind == ckTrueColor
  assert c2.r == 255
  assert c2.g == 128
  assert c2.b == 0
  let c3 = palette(42)
  assert c3.kind == ckPalette
  assert c3.index == 42
  let c4 = hex(0xFF5733)
  assert c4.r == 0xFF
  assert c4.g == 0x57
  assert c4.b == 0x33
  echo "PASS: colors"

block testStyle:
  let s = style(clRed, clBlue, {taBold, taUnderline})
  assert s.fg == clRed
  assert s.bg == clBlue
  assert taBold in s.attrs
  assert taUnderline in s.attrs
  let s2 = styleDefault.bold().fg(clGreen)
  assert taBold in s2.attrs
  assert s2.fg == clGreen
  echo "PASS: style"

block testAnsi:
  let s = style(clRed, clBlue, {taBold})
  let ansi = s.toAnsi()
  assert ansi.len > 0
  assert "\e[1m" in ansi   # bold
  assert "\e[31m" in ansi  # red fg
  assert "\e[44m" in ansi  # blue bg
  let tc = style(rgb(100, 200, 50))
  let tcAnsi = tc.toAnsi()
  assert "38;2;100;200;50" in tcAnsi
  echo "PASS: ansi"

block testBorderChars:
  let bc = borderChars(bsSingle)
  assert bc.topLeft == "┌"
  assert bc.horizontal == "─"
  let rd = borderChars(bsRounded)
  assert rd.topLeft == "╭"
  echo "PASS: border chars"

# ============================================================
# Cell buffer tests
# ============================================================

block testCellBuffer:
  var buf = newCellBuffer(10, 5)
  assert buf.width == 10
  assert buf.height == 5
  assert buf[0, 0].ch == " "  # Initially empty
  buf.setCell(3, 2, "X", style(clRed))
  assert buf[3, 2].ch == "X"
  assert buf[3, 2].style.fg == clRed
  # Out of bounds returns empty
  assert buf[100, 100].ch == " "
  echo "PASS: cell buffer basic"

block testCellBufferWrite:
  var buf = newCellBuffer(20, 3)
  buf.writeStr(0, 0, "Hello, World!", style(clGreen))
  assert buf[0, 0].ch == "H"
  assert buf[4, 0].ch == "o"
  assert buf[12, 0].ch == "!"
  assert buf[0, 0].style.fg == clGreen
  echo "PASS: cell buffer write"

block testCellBufferFill:
  var buf = newCellBuffer(10, 5)
  buf.fill(2, 1, 3, 2, "#", style(clYellow))
  assert buf[2, 1].ch == "#"
  assert buf[4, 2].ch == "#"
  assert buf[1, 1].ch == " "
  assert buf[5, 1].ch == " "
  echo "PASS: cell buffer fill"

block testCellBufferResize:
  var buf = newCellBuffer(5, 3)
  buf.setCell(2, 1, "A")
  buf.resize(10, 6)
  assert buf.width == 10
  assert buf.height == 6
  assert buf[2, 1].ch == "A"  # Preserved
  assert buf[8, 4].ch == " "  # New space
  echo "PASS: cell buffer resize"

block testCellBufferDiff:
  var front = newCellBuffer(5, 3)
  var back = newCellBuffer(5, 3)
  back.setCell(2, 1, "X", style(clRed))
  let output = diff(front, back)
  assert output.len > 0
  assert "X" in output
  echo "PASS: cell buffer diff"

# ============================================================
# Layout tests
# ============================================================

block testLayoutVertical:
  let parent = Rect(x: 0, y: 0, w: 80, h: 24)
  let nodes = @[
    LayoutNode(props: LayoutProps(
      width: SizeSpec(kind: szFlex, flex: 1.0),
      height: SizeSpec(kind: szFixed, fixed: 3),
    )),
    LayoutNode(props: LayoutProps(
      width: SizeSpec(kind: szFlex, flex: 1.0),
      height: SizeSpec(kind: szFlex, flex: 1.0),
    )),
    LayoutNode(props: LayoutProps(
      width: SizeSpec(kind: szFlex, flex: 1.0),
      height: SizeSpec(kind: szFixed, fixed: 1),
    )),
  ]
  let rects = computeLayout(nodes, parent, dirVertical)
  assert rects[0].y == 0
  assert rects[0].h == 3
  assert rects[1].y == 3
  assert rects[1].h == 20  # 24 - 3 - 1 = 20
  assert rects[2].y == 23
  assert rects[2].h == 1
  echo "PASS: layout vertical"

block testLayoutHorizontal:
  let parent = Rect(x: 0, y: 0, w: 80, h: 24)
  let nodes = @[
    LayoutNode(props: LayoutProps(
      width: SizeSpec(kind: szFixed, fixed: 20),
      height: SizeSpec(kind: szFlex, flex: 1.0),
    )),
    LayoutNode(props: LayoutProps(
      width: SizeSpec(kind: szFlex, flex: 1.0),
      height: SizeSpec(kind: szFlex, flex: 1.0),
    )),
    LayoutNode(props: LayoutProps(
      width: SizeSpec(kind: szFixed, fixed: 20),
      height: SizeSpec(kind: szFlex, flex: 1.0),
    )),
  ]
  let rects = computeLayout(nodes, parent, dirHorizontal)
  assert rects[0].x == 0
  assert rects[0].w == 20
  assert rects[1].x == 20
  assert rects[1].w == 40   # 80 - 20 - 20
  assert rects[2].x == 60
  assert rects[2].w == 20
  echo "PASS: layout horizontal"

block testLayoutGap:
  let parent = Rect(x: 0, y: 0, w: 80, h: 10)
  let nodes = @[
    LayoutNode(props: LayoutProps(
      width: SizeSpec(kind: szFlex, flex: 1.0),
      height: SizeSpec(kind: szFlex, flex: 1.0),
    )),
    LayoutNode(props: LayoutProps(
      width: SizeSpec(kind: szFlex, flex: 1.0),
      height: SizeSpec(kind: szFlex, flex: 1.0),
    )),
  ]
  let rects = computeLayout(nodes, parent, dirVertical, parentGap = 2)
  assert rects[0].h == 4  # (10 - 2) / 2 = 4
  assert rects[1].y == 6  # 4 + 2 = 6
  assert rects[1].h == 4
  echo "PASS: layout gap"

block testLayoutPercent:
  let parent = Rect(x: 0, y: 0, w: 100, h: 100)
  let nodes = @[
    LayoutNode(props: LayoutProps(
      width: SizeSpec(kind: szPercent, percent: 30.0),
      height: SizeSpec(kind: szFlex, flex: 1.0),
    )),
    LayoutNode(props: LayoutProps(
      width: SizeSpec(kind: szPercent, percent: 70.0),
      height: SizeSpec(kind: szFlex, flex: 1.0),
    )),
  ]
  let rects = computeLayout(nodes, parent, dirHorizontal)
  assert rects[0].w == 30
  assert rects[1].w == 70
  echo "PASS: layout percent"

# ============================================================
# Widget tests
# ============================================================

block testWidgetConstructors:
  let t = text("Hello", style(clGreen))
  assert t.kind == wkText
  assert t.text == "Hello"
  assert t.style.fg == clGreen

  let b = border(text("Content"), bsRounded, "Title")
  assert b.kind == wkBorder
  assert b.borderStyle == bsRounded
  assert b.borderTitle == "Title"

  let v = vbox(text("A"), text("B"), text("C"))
  assert v.kind == wkContainer
  assert v.children.len == 3
  assert v.layout.direction == dirVertical

  let h = hbox(label("X"), spacer(), label("Y"))
  assert h.kind == wkContainer
  assert h.children.len == 3
  assert h.layout.direction == dirHorizontal

  echo "PASS: widget constructors"

block testWidgetModifiers:
  let w = text("Test")
    .withStyle(style(clRed))
    .withWidth(fixed(20))
    .withHeight(fixed(3))
    .withId("myText")
    .withWrap(twWrap)
  assert w.style.fg == clRed
  assert w.layout.width.kind == szFixed
  assert w.layout.width.fixed == 20
  assert w.id == "myText"
  assert w.textWrap == twWrap
  echo "PASS: widget modifiers"

block testInputField:
  let inp = inputField("hello", cursor = 3, placeholder = "type...")
  assert inp.kind == wkInput
  assert inp.inputText == "hello"
  assert inp.inputCursor == 3
  assert inp.inputPlaceholder == "type..."
  echo "PASS: input field"

block testListWidget:
  let items = @[
    listItem("Item 1"),
    listItem("Item 2", selected = true),
    listItem("Item 3"),
  ]
  let l = list(items, selected = 1)
  assert l.kind == wkList
  assert l.listItems.len == 3
  assert l.listSelected == 1
  echo "PASS: list widget"

block testTableWidget:
  let cols = @[
    column("Name", flex()),
    column("Value", fixed(10), taRight),
  ]
  let rows = @[@["foo", "42"], @["bar", "99"]]
  let t = table(cols, rows)
  assert t.kind == wkTable
  assert t.tableColumns.len == 2
  assert t.tableRows.len == 2
  echo "PASS: table widget"

block testProgressBar:
  let p = progressBar(0.75)
  assert p.kind == wkProgressBar
  assert p.progress == 0.75
  echo "PASS: progress bar"

block testTabBar:
  let t = tabBar(@[tabItem("Tab1", active = true), tabItem("Tab2")])
  assert t.kind == wkTabs
  assert t.tabs.len == 2
  assert t.tabs[0].active == true
  echo "PASS: tab bar"

# ============================================================
# Renderer tests
# ============================================================

block testRenderText:
  var buf = newCellBuffer(20, 3)
  let w = text("Hello", style(clGreen))
  renderWidget(buf, w, Rect(x: 0, y: 0, w: 20, h: 3))
  assert buf[0, 0].ch == "H"
  assert buf[4, 0].ch == "o"
  assert buf[0, 0].style.fg == clGreen
  echo "PASS: render text"

block testRenderBorder:
  var buf = newCellBuffer(20, 5)
  let w = border(text("Content"), bsSingle, "Title")
  renderWidget(buf, w, Rect(x: 0, y: 0, w: 20, h: 5))
  assert buf[0, 0].ch == "┌"
  assert buf[19, 0].ch == "┐"
  assert buf[0, 4].ch == "└"
  assert buf[19, 4].ch == "┘"
  assert buf[0, 2].ch == "│"
  assert buf[1, 0].ch == " "  # Title starts with space
  echo "PASS: render border"

block testRenderVbox:
  var buf = newCellBuffer(20, 4)
  let w = vbox(
    text("Line 1").withHeight(fixed(1)),
    text("Line 2").withHeight(fixed(1)),
    text("Line 3").withHeight(fixed(1)),
  )
  renderWidget(buf, w, Rect(x: 0, y: 0, w: 20, h: 4))
  assert buf[0, 0].ch == "L"
  assert buf[5, 0].ch == "1"
  assert buf[0, 1].ch == "L"
  assert buf[5, 1].ch == "2"
  echo "PASS: render vbox"

block testRenderList:
  var buf = newCellBuffer(20, 5)
  let items = @[listItem("Item A"), listItem("Item B"), listItem("Item C")]
  let w = list(items, selected = 1)
  renderWidget(buf, w, Rect(x: 0, y: 0, w: 20, h: 5))
  assert buf[0, 0].ch == "I"
  assert buf[5, 0].ch == "A"
  # Selected item (index 1) should have highlight style
  assert buf[0, 1].ch == "I"
  echo "PASS: render list"

block testRenderProgressBar:
  var buf = newCellBuffer(10, 1)
  let w = progressBar(0.5)
  renderWidget(buf, w, Rect(x: 0, y: 0, w: 10, h: 1))
  # 50% of 10 = 5 filled cells
  assert buf[0, 0].ch == "█"
  assert buf[4, 0].ch == "█"
  assert buf[5, 0].ch == "░"
  assert buf[9, 0].ch == "░"
  echo "PASS: render progress bar"

# ============================================================
# Input parsing tests
# ============================================================

block testParseChar:
  let events = parseInputEvents("a")
  assert events.len == 1
  assert events[0].kind == iekKey
  assert events[0].key == kcChar
  assert events[0].ch == 'a'
  echo "PASS: parse char"

block testParseCtrl:
  let events = parseInputEvents("\x03")  # Ctrl+C
  assert events.len == 1
  assert events[0].kind == iekKey
  assert events[0].key == kcChar
  assert events[0].ch == 'c'
  assert kmCtrl in events[0].keyMods
  echo "PASS: parse ctrl"

block testParseArrow:
  let events = parseInputEvents("\e[A")  # Up arrow
  assert events.len == 1
  assert events[0].kind == iekKey
  assert events[0].key == kcUp
  echo "PASS: parse arrow"

block testParseMultiple:
  let events = parseInputEvents("abc")
  assert events.len == 3
  assert events[0].ch == 'a'
  assert events[1].ch == 'b'
  assert events[2].ch == 'c'
  echo "PASS: parse multiple"

block testParseSpecialKeys:
  assert parseInputEvents("\r")[0].key == kcEnter
  assert parseInputEvents("\t")[0].key == kcTab
  assert parseInputEvents("\x7f")[0].key == kcBackspace
  assert parseInputEvents("\e")[0].key == kcEscape
  assert parseInputEvents("\e[B")[0].key == kcDown
  assert parseInputEvents("\e[C")[0].key == kcRight
  assert parseInputEvents("\e[D")[0].key == kcLeft
  assert parseInputEvents("\e[H")[0].key == kcHome
  assert parseInputEvents("\e[F")[0].key == kcEnd
  assert parseInputEvents("\e[5~")[0].key == kcPageUp
  assert parseInputEvents("\e[6~")[0].key == kcPageDown
  assert parseInputEvents("\e[3~")[0].key == kcDelete
  echo "PASS: parse special keys"

block testParseFunctionKeys:
  assert parseInputEvents("\eOP")[0].key == kcF1
  assert parseInputEvents("\eOQ")[0].key == kcF2
  assert parseInputEvents("\eOR")[0].key == kcF3
  assert parseInputEvents("\eOS")[0].key == kcF4
  assert parseInputEvents("\e[15~")[0].key == kcF5
  echo "PASS: parse function keys"

block testParseAlt:
  let events = parseInputEvents("\ea")
  assert events.len == 1
  assert events[0].kind == iekKey
  assert events[0].key == kcChar
  assert events[0].ch == 'a'
  assert kmAlt in events[0].keyMods
  echo "PASS: parse alt"

block testParseSgrMouse:
  # SGR mouse: button 0 press at (10, 20)
  let events = parseInputEvents("\e[<0;11;21M")
  assert events.len == 1
  assert events[0].kind == iekMouse
  assert events[0].button == mbLeft
  assert events[0].action == maPress
  assert events[0].mx == 10  # 11 - 1
  assert events[0].my == 20  # 21 - 1
  echo "PASS: parse SGR mouse"

block testParseModifiedArrow:
  # Shift+Up: ESC[1;2A
  let events = parseInputEvents("\e[1;2A")
  assert events.len == 1
  assert events[0].kind == iekKey
  assert events[0].key == kcUp
  assert kmShift in events[0].keyMods
  echo "PASS: parse modified arrow"

# ============================================================
# TextInput tests
# ============================================================

block testTextInputBasic:
  let ti = newTextInput()
  ti.insert('h')
  ti.insert('i')
  assert ti.text == "hi"
  assert ti.cursor == 2
  ti.deleteBack()
  assert ti.text == "h"
  assert ti.cursor == 1
  echo "PASS: text input basic"

block testTextInputMovement:
  let ti = newTextInput()
  ti.insertStr("hello world")
  assert ti.cursor == 11
  ti.moveHome()
  assert ti.cursor == 0
  ti.moveEnd()
  assert ti.cursor == 11
  ti.moveLeft()
  assert ti.cursor == 10
  ti.moveRight()
  assert ti.cursor == 11
  echo "PASS: text input movement"

block testTextInputWordMovement:
  let ti = newTextInput()
  ti.insertStr("hello world test")
  ti.moveWordLeft()
  assert ti.cursor == 12  # Before "test"
  ti.moveWordLeft()
  assert ti.cursor == 6   # Before "world"
  ti.moveWordRight()
  assert ti.cursor == 12  # After "world " (before "test")
  echo "PASS: text input word movement"

block testTextInputDelete:
  let ti = newTextInput()
  ti.insertStr("hello world")
  ti.deleteWordBack()
  assert ti.text == "hello "
  ti.deleteToEnd()
  assert ti.text == "hello "  # Already at end after word delete
  ti.moveHome()
  ti.deleteToEnd()
  assert ti.text == ""
  echo "PASS: text input delete"

block testTextInputHistory:
  let ti = newTextInput()
  ti.insertStr("first")
  ti.pushHistory()
  ti.clear()
  ti.insertStr("second")
  ti.pushHistory()
  ti.clear()
  ti.historyUp()
  assert ti.text == "second"
  ti.historyUp()
  assert ti.text == "first"
  ti.historyDown()
  assert ti.text == "second"
  ti.historyDown()
  assert ti.text == ""  # Back to saved empty text
  echo "PASS: text input history"

block testTextInputSubmit:
  let ti = newTextInput()
  ti.insertStr("test message")
  let msg = ti.submit()
  assert msg == "test message"
  assert ti.text == ""
  assert ti.cursor == 0
  # History should have it
  ti.historyUp()
  assert ti.text == "test message"
  echo "PASS: text input submit"

block testTextInputEventHandler:
  let ti = newTextInput()
  # Type some characters
  discard ti.handleInput(InputEvent(kind: iekKey, key: kcChar, ch: 'h'))
  discard ti.handleInput(InputEvent(kind: iekKey, key: kcChar, ch: 'i'))
  assert ti.text == "hi"
  # Backspace
  discard ti.handleInput(InputEvent(kind: iekKey, key: kcBackspace))
  assert ti.text == "h"
  # Home
  discard ti.handleInput(InputEvent(kind: iekKey, key: kcHome))
  assert ti.cursor == 0
  echo "PASS: text input event handler"

# ============================================================
# Reactive state tests
# ============================================================

block testSignal:
  let ctx = newReactiveContext()
  let count = newSignal(ctx, 0)
  assert count.val == 0
  count.set(5)
  assert count.val == 5
  assert ctx.isDirty
  ctx.clearDirty()
  count.set(5)  # Same value, should not mark dirty
  assert not ctx.isDirty
  count.set(10)
  assert ctx.isDirty
  echo "PASS: signal"

block testSignalSeq:
  let ctx = newReactiveContext()
  let items = newSignal(ctx, newSeq[string]())
  items.append("hello")
  items.append("world")
  assert items.len == 2
  assert items[0] == "hello"
  assert items[1] == "world"
  items.removeAt(0)
  assert items.len == 1
  assert items[0] == "world"
  echo "PASS: signal seq"

block testComputed:
  let ctx = newReactiveContext()
  let count = newSignal(ctx, 3)
  let doubled = newComputed(ctx, proc(): int = count.val * 2)
  assert doubled.val == 6
  count.set(5)
  doubled.invalidate()
  assert doubled.val == 10
  echo "PASS: computed"

block testReactiveCallback:
  let ctx = newReactiveContext()
  var callbackCount = 0
  ctx.afterUpdate = proc() =
    inc callbackCount
  let count = newSignal(ctx, 0)
  count.set(1)
  assert callbackCount == 1
  count.set(2)
  assert callbackCount == 2
  count.set(2)  # Same value
  assert callbackCount == 2  # Not called
  echo "PASS: reactive callback"

# ============================================================
# DSL tests
# ============================================================

block testDslText:
  let w = tui:
    text "Hello"
  assert w.kind == wkText
  assert w.text == "Hello"
  echo "PASS: dsl text"

block testDslVbox:
  let w = tui:
    vbox:
      text "Line 1"
      text "Line 2"
  assert w.kind == wkContainer
  assert w.layout.direction == dirVertical
  assert w.children.len == 2
  echo "PASS: dsl vbox"

block testDslHbox:
  let w = tui:
    hbox:
      label "A"
      spacer()
      label "B"
  assert w.kind == wkContainer
  assert w.layout.direction == dirHorizontal
  assert w.children.len == 3
  echo "PASS: dsl hbox"

block testDslBorder:
  let w = tui:
    border "MyTitle", bsRounded:
      text "Inside"
  assert w.kind == wkBorder
  assert w.borderTitle == "MyTitle"
  assert w.borderStyle == bsRounded
  assert w.borderChild.kind == wkText
  echo "PASS: dsl border"

block testDslNested:
  let w = tui:
    vbox:
      border "Top":
        text "Header"
      hbox:
        text "Left"
        text "Right"
      text "Footer"
  assert w.kind == wkContainer
  assert w.children.len == 3
  assert w.children[0].kind == wkBorder
  assert w.children[1].kind == wkContainer
  assert w.children[1].layout.direction == dirHorizontal
  assert w.children[2].kind == wkText
  echo "PASS: dsl nested"

block testDslInputWithTextInput:
  let ti = newTextInput("type here...")
  ti.insertStr("hello")
  let w = tui:
    input ti
  assert w.kind == wkInput
  assert w.inputText == "hello"
  echo "PASS: dsl input with TextInput"

block testDslProperties:
  let w = tui:
    vbox:
      gap = 2
      text "A"
      text "B"
  assert w.kind == wkContainer
  assert w.layout.gap == 2
  echo "PASS: dsl properties"

# ============================================================
# Integration test: full widget tree render
# ============================================================

block testFullRender:
  var buf = newCellBuffer(60, 20)
  let w = vbox(
    border(
      vbox(
        text("Chat Room", style(clCyan).bold()),
      ),
      bsRounded, "Messages",
    ).withHeight(fixed(15)),
    hbox(
      label("> ", style(clGreen)),
      inputField("hello world", cursor = 11),
    ).withHeight(fixed(1)),
  )
  renderWidget(buf, w, Rect(x: 0, y: 0, w: 60, h: 20))
  # Border corners
  assert buf[0, 0].ch == "╭"
  assert buf[59, 0].ch == "╮"
  # Label
  assert buf[0, 15].ch == ">"
  echo "PASS: full render integration"

echo ""
echo "All TUI tests passed!"
