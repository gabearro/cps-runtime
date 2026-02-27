## CPS TUI - Widget System
##
## A composable widget tree for building terminal UIs.
## Widgets are lightweight value objects that describe what to render.
## The renderer traverses the tree, computes layout, and draws to a CellBuffer.
##
## Design: widgets are declarative descriptions (like VDOM nodes), not stateful
## objects. State lives in the application layer and flows down as props.

import ./style
import ./cell
import ./layout
import ./input
import std/strutils

type
  WidgetKind* = enum
    wkContainer      ## Layout container (flexbox-like)
    wkText           ## Static text label
    wkBorder         ## Border wrapper around a single child
    wkInput          ## Text input field
    wkList           ## Scrollable list
    wkTable          ## Table with columns and rows
    wkSpacer         ## Empty space (fixed or flex)
    wkScrollView     ## Scrollable viewport
    wkProgressBar    ## Progress indicator
    wkTabs           ## Tab bar
    wkCustom         ## User-defined custom rendering

  TextWrap* = enum
    twNone           ## No wrapping, clip at edge
    twWrap           ## Wrap at word boundaries
    twChar           ## Wrap at character boundaries

  TextAlign* = enum
    taLeft
    taCenter
    taRight

  ColumnDef* = object
    title*: string
    width*: SizeSpec
    align*: TextAlign
    style*: Style

  ListItem* = object
    text*: string
    style*: Style
    selected*: bool

  TabItem* = object
    label*: string
    active*: bool

  CustomRenderProc* = proc(buf: var CellBuffer, rect: Rect)

  ClickHandler* = proc(mx, my: int)
  KeyHandler* = proc(evt: InputEvent): bool
  ScrollHandler* = proc(delta: int)
  MouseHandler* = proc(evt: InputEvent): bool
  FocusHandler* = proc()

  EventHandlers* = ref object
    onClick*: ClickHandler
    onKey*: KeyHandler          ## Key events when focused
    onScroll*: ScrollHandler    ## Scroll wheel
    onMouse*: MouseHandler      ## Raw mouse (drag, etc.)
    onFocus*: FocusHandler
    onBlur*: FocusHandler

  Widget* = ref object
    ## A node in the widget tree.
    layout*: LayoutProps
    style*: Style
    focusable*: bool
    focused*: bool
    id*: string           ## Optional identifier for event routing
    events*: EventHandlers ## nil when no handlers (common case)
    trapFocus*: bool       ## If true, all key events stay within this subtree

    case kind*: WidgetKind
    of wkContainer:
      children*: seq[Widget]
    of wkText:
      text*: string
      textWrap*: TextWrap
      textAlign*: TextAlign
    of wkBorder:
      borderStyle*: BorderStyle
      borderTitle*: string
      borderTitleStyle*: Style
      borderChild*: Widget
    of wkInput:
      inputText*: string
      inputCursor*: int
      inputPlaceholder*: string
      inputMask*: char     ## '\0' for no masking, '*' for password, etc.
    of wkList:
      listItems*: seq[ListItem]
      listOffset*: int     ## Scroll offset
      listSelected*: int   ## Selected index
      listHighlightStyle*: Style
    of wkTable:
      tableColumns*: seq[ColumnDef]
      tableRows*: seq[seq[string]]
      tableHeaderStyle*: Style
      tableRowStyle*: Style
      tableAltRowStyle*: Style
      tableOffset*: int
      tableSelected*: int
    of wkSpacer:
      discard
    of wkScrollView:
      scrollChild*: Widget
      scrollX*, scrollY*: int
    of wkProgressBar:
      progress*: float     ## 0.0 to 1.0
      progressStyle*: Style
      progressFillChar*: string
      progressEmptyChar*: string
    of wkTabs:
      tabs*: seq[TabItem]
      tabStyle*: Style
      activeTabStyle*: Style
    of wkCustom:
      customRender*: CustomRenderProc
      customChildren*: seq[Widget]  ## Optional children for event routing
      customChildRects*: seq[Rect]  ## Rects for customChildren (set by customRender)

# ============================================================
# Widget constructors
# ============================================================

proc container*(children: varargs[Widget]): Widget =
  Widget(kind: wkContainer,
         layout: defaultLayout,
         style: styleDefault,
         children: @children)

proc hbox*(children: varargs[Widget]): Widget =
  var w = container(children)
  w.layout.direction = dirHorizontal
  w

proc vbox*(children: varargs[Widget]): Widget =
  var w = container(children)
  w.layout.direction = dirVertical
  w

proc text*(s: string, st: Style = styleDefault): Widget =
  Widget(kind: wkText,
         layout: LayoutProps(
           width: SizeSpec(kind: szFlex, flex: 1.0),
           height: SizeSpec(kind: szAuto),
         ),
         style: st,
         text: s,
         textWrap: twNone,
         textAlign: taLeft)

proc label*(s: string, st: Style = styleDefault): Widget =
  ## Short alias for text with auto sizing.
  Widget(kind: wkText,
         layout: LayoutProps(
           width: SizeSpec(kind: szAuto),
           height: SizeSpec(kind: szFixed, fixed: 1),
         ),
         style: st,
         text: s,
         textWrap: twNone,
         textAlign: taLeft)

proc border*(child: Widget, bs: BorderStyle = bsSingle,
             title: string = "", titleStyle: Style = styleDefault,
             st: Style = styleDefault): Widget =
  Widget(kind: wkBorder,
         layout: defaultLayout,
         style: st,
         borderStyle: bs,
         borderTitle: title,
         borderTitleStyle: titleStyle,
         borderChild: child)

proc inputField*(text: string = "", cursor: int = 0,
                 placeholder: string = "",
                 mask: char = '\0', st: Style = styleDefault): Widget =
  Widget(kind: wkInput,
         layout: LayoutProps(
           width: SizeSpec(kind: szFlex, flex: 1.0),
           height: SizeSpec(kind: szFixed, fixed: 1),
         ),
         style: st,
         focusable: true,
         inputText: text,
         inputCursor: cursor,
         inputPlaceholder: placeholder,
         inputMask: mask)

proc list*(items: seq[ListItem], selected: int = 0,
           offset: int = 0, highlightStyle: Style = style(clBlack, clWhite)): Widget =
  Widget(kind: wkList,
         layout: defaultLayout,
         style: styleDefault,
         focusable: true,
         listItems: items,
         listOffset: offset,
         listSelected: selected,
         listHighlightStyle: highlightStyle)

proc listItem*(text: string, selected: bool = false,
               st: Style = styleDefault): ListItem =
  ListItem(text: text, style: st, selected: selected)

proc table*(columns: seq[ColumnDef], rows: seq[seq[string]],
            selected: int = -1, offset: int = 0): Widget =
  Widget(kind: wkTable,
         layout: defaultLayout,
         style: styleDefault,
         focusable: true,
         tableColumns: columns,
         tableRows: rows,
         tableHeaderStyle: styleBold,
         tableRowStyle: styleDefault,
         tableAltRowStyle: styleDefault,
         tableOffset: offset,
         tableSelected: selected)

proc column*(title: string, width: SizeSpec = flex(),
             align: TextAlign = taLeft, st: Style = styleDefault): ColumnDef =
  ColumnDef(title: title, width: width, align: align, style: st)

proc spacer*(size: int = 0): Widget =
  if size > 0:
    Widget(kind: wkSpacer,
           layout: LayoutProps(
             width: SizeSpec(kind: szFixed, fixed: size),
             height: SizeSpec(kind: szFixed, fixed: size),
           ),
           style: styleDefault)
  else:
    Widget(kind: wkSpacer,
           layout: LayoutProps(
             width: SizeSpec(kind: szFlex, flex: 1.0),
             height: SizeSpec(kind: szFlex, flex: 1.0),
           ),
           style: styleDefault)

proc scrollView*(child: Widget, scrollX: int = 0, scrollY: int = 0): Widget =
  Widget(kind: wkScrollView,
         layout: defaultLayout,
         style: styleDefault,
         scrollChild: child,
         scrollX: scrollX,
         scrollY: scrollY)

proc progressBar*(value: float, fillChar: string = "█",
                  emptyChar: string = "░",
                  st: Style = style(clGreen),
                  bgSt: Style = styleDefault): Widget =
  Widget(kind: wkProgressBar,
         layout: LayoutProps(
           width: SizeSpec(kind: szFlex, flex: 1.0),
           height: SizeSpec(kind: szFixed, fixed: 1),
         ),
         style: bgSt,
         progress: clamp(value, 0.0, 1.0),
         progressStyle: st,
         progressFillChar: fillChar,
         progressEmptyChar: emptyChar)

proc tabBar*(items: seq[TabItem],
             tabSt: Style = styleDefault,
             activeSt: Style = style(clBlack, clWhite).bold()): Widget =
  Widget(kind: wkTabs,
         layout: LayoutProps(
           width: SizeSpec(kind: szFlex, flex: 1.0),
           height: SizeSpec(kind: szFixed, fixed: 1),
         ),
         style: styleDefault,
         tabs: items,
         tabStyle: tabSt,
         activeTabStyle: activeSt)

proc tabItem*(label: string, active: bool = false): TabItem =
  TabItem(label: label, active: active)

proc custom*(render: CustomRenderProc): Widget =
  Widget(kind: wkCustom,
         layout: defaultLayout,
         style: styleDefault,
         customRender: render)

proc containerFromSeq*(children: seq[Widget],
                       dir: Direction = dirVertical): Widget =
  ## Build a container from a seq of children. Used by the DSL `for` loop
  ## transform to wrap dynamically-generated widget lists.
  Widget(kind: wkContainer,
         layout: LayoutProps(
           direction: dir,
           width: SizeSpec(kind: szFlex, flex: 1.0),
           height: SizeSpec(kind: szAuto),
         ),
         style: styleDefault,
         children: children)

# ============================================================
# Widget property modifiers (builder pattern)
# ============================================================

proc withLayout*(w: Widget, l: LayoutProps): Widget =
  result = w
  result.layout = l

proc withWidth*(w: Widget, s: SizeSpec): Widget =
  result = w
  result.layout.width = s

proc withHeight*(w: Widget, s: SizeSpec): Widget =
  result = w
  result.layout.height = s

proc withPadding*(w: Widget, p: Padding): Widget =
  result = w
  result.layout.padding = p

proc withGap*(w: Widget, g: int): Widget =
  result = w
  result.layout.gap = g

proc withStyle*(w: Widget, s: Style): Widget =
  result = w
  result.style = s

proc withId*(w: Widget, id: string): Widget =
  result = w
  result.id = id

proc withFocus*(w: Widget, focused: bool = true): Widget =
  result = w
  result.focused = focused
  result.focusable = true

proc withDirection*(w: Widget, d: Direction): Widget =
  result = w
  result.layout.direction = d

proc withAlign*(w: Widget, align: Alignment): Widget =
  result = w
  result.layout.alignItems = align

proc withJustify*(w: Widget, justify: Alignment): Widget =
  result = w
  result.layout.justifyContent = justify

proc withConstraint*(w: Widget, c: Constraint): Widget =
  result = w
  result.layout.constraint = c

proc withWrap*(w: Widget, wrap: TextWrap): Widget =
  result = w
  if w.kind == wkText:
    result.textWrap = wrap

proc withTextAlign*(w: Widget, align: TextAlign): Widget =
  result = w
  if w.kind == wkText:
    result.textAlign = align

# ============================================================
# Event handler builder methods
# ============================================================

proc ensureEvents(w: Widget): EventHandlers {.inline.} =
  ## Lazily allocate EventHandlers so widgets without handlers pay zero cost.
  if w.events == nil:
    w.events = EventHandlers()
  w.events

proc withOnClick*(w: Widget, h: ClickHandler): Widget =
  result = w
  discard result.ensureEvents()
  result.events.onClick = h

proc withOnKey*(w: Widget, h: KeyHandler): Widget =
  result = w
  discard result.ensureEvents()
  result.events.onKey = h

proc withOnScroll*(w: Widget, h: ScrollHandler): Widget =
  result = w
  discard result.ensureEvents()
  result.events.onScroll = h

proc withOnMouse*(w: Widget, h: MouseHandler): Widget =
  result = w
  discard result.ensureEvents()
  result.events.onMouse = h

proc withOnFocus*(w: Widget, h: FocusHandler): Widget =
  result = w
  result.focusable = true
  discard result.ensureEvents()
  result.events.onFocus = h

proc withOnBlur*(w: Widget, h: FocusHandler): Widget =
  result = w
  discard result.ensureEvents()
  result.events.onBlur = h

proc withFocusTrap*(w: Widget, trap: bool = true): Widget =
  result = w
  result.trapFocus = trap

proc hasEventHandlers*(w: Widget): bool =
  ## Returns true if the widget has any event handlers attached.
  w.events != nil

# ============================================================
# Content size estimation (for auto sizing)
# ============================================================

proc contentWidth*(w: Widget): int =
  case w.kind
  of wkText: w.text.len
  of wkInput: max(w.inputText.len, w.inputPlaceholder.len)
  of wkBorder:
    if w.borderChild != nil:
      w.borderChild.contentWidth + 2  # Border chars
    else: 2
  of wkProgressBar: 10  # Minimum
  of wkTabs:
    var total = 0
    for t in w.tabs:
      total += t.label.len + 3  # " label "
    total
  of wkSpacer: 0
  else: 0

proc contentHeight*(w: Widget): int =
  case w.kind
  of wkText:
    if w.text.len == 0: 1
    else: w.text.count('\n') + 1
  of wkInput: 1
  of wkBorder:
    if w.borderChild != nil:
      w.borderChild.contentHeight + 2
    else: 2
  of wkList: w.listItems.len
  of wkTable: w.tableRows.len + 1  # +1 for header
  of wkProgressBar: 1
  of wkTabs: 1
  of wkSpacer: 0
  else: 0
