## CPS TUI - Layout Engine
##
## Flexbox-inspired layout system for positioning widgets in the terminal.
## Supports horizontal/vertical stacking, fixed/percentage/flex sizing,
## padding, margins, alignment, and min/max constraints.

type
  Direction* = enum
    dirHorizontal
    dirVertical

  Sizing* = enum
    szFixed          ## Fixed number of cells
    szPercent        ## Percentage of parent
    szFlex           ## Flex grow/shrink (like CSS flex)
    szAuto           ## Size to content

  Alignment* = enum
    alStart
    alCenter
    alEnd

  SizeSpec* = object
    case kind*: Sizing
    of szFixed:
      fixed*: int
    of szPercent:
      percent*: float
    of szFlex:
      flex*: float    ## Flex weight (default 1.0)
    of szAuto:
      discard

  Padding* = object
    top*, right*, bottom*, left*: int

  Constraint* = object
    minWidth*, maxWidth*: int     ## 0 = no constraint
    minHeight*, maxHeight*: int

  LayoutProps* = object
    width*: SizeSpec
    height*: SizeSpec
    direction*: Direction
    padding*: Padding
    gap*: int                   ## Space between children
    alignItems*: Alignment      ## Cross-axis alignment
    justifyContent*: Alignment  ## Main-axis alignment
    constraint*: Constraint
    scrollOffsetX*: int
    scrollOffsetY*: int

  Rect* = object
    ## A positioned rectangle on screen.
    x*, y*: int
    w*, h*: int

# ============================================================
# SizeSpec constructors
# ============================================================

proc fixed*(n: int): SizeSpec =
  SizeSpec(kind: szFixed, fixed: n)

proc pct*(p: float): SizeSpec =
  SizeSpec(kind: szPercent, percent: p)

proc flex*(weight: float = 1.0): SizeSpec =
  SizeSpec(kind: szFlex, flex: weight)

proc autoSize*(): SizeSpec =
  SizeSpec(kind: szAuto)

# ============================================================
# Padding helpers
# ============================================================

proc pad*(all: int): Padding =
  Padding(top: all, right: all, bottom: all, left: all)

proc pad*(vertical, horizontal: int): Padding =
  Padding(top: vertical, right: horizontal, bottom: vertical, left: horizontal)

proc pad*(top, right, bottom, left: int): Padding =
  Padding(top: top, right: right, bottom: bottom, left: left)

proc padH*(p: Padding): int {.inline.} = p.left + p.right
proc padV*(p: Padding): int {.inline.} = p.top + p.bottom

# ============================================================
# Default props
# ============================================================

const defaultLayout* = LayoutProps(
  width: SizeSpec(kind: szFlex, flex: 1.0),
  height: SizeSpec(kind: szFlex, flex: 1.0),
  direction: dirVertical,
  padding: Padding(),
  gap: 0,
  alignItems: alStart,
  justifyContent: alStart,
  constraint: Constraint(),
)

# ============================================================
# Layout computation
# ============================================================

proc clampSize(size, minSize, maxSize: int): int {.inline.} =
  result = size
  if minSize > 0 and result < minSize:
    result = minSize
  if maxSize > 0 and result > maxSize:
    result = maxSize

type
  LayoutNode* = object
    ## Input to the layout engine: a node with props and children count.
    props*: LayoutProps
    childCount*: int
    contentWidth*: int    ## Intrinsic content width (for szAuto)
    contentHeight*: int   ## Intrinsic content height (for szAuto)

proc computeLayout*(nodes: openArray[LayoutNode], parentRect: Rect,
                    parentDir: Direction = dirVertical,
                    parentGap: int = 0,
                    parentAlign: Alignment = alStart,
                    parentJustify: Alignment = alStart): seq[Rect] =
  ## Compute layout rectangles for a list of sibling nodes within parentRect.
  ## Returns a Rect for each node.
  result = newSeq[Rect](nodes.len)
  if nodes.len == 0:
    return

  let isHorizontal = parentDir == dirHorizontal
  let mainSize = if isHorizontal: parentRect.w else: parentRect.h
  let crossSize = if isHorizontal: parentRect.h else: parentRect.w

  # First pass: resolve fixed/percent/auto sizes and collect flex total
  var fixedTotal = 0
  var flexTotal = 0.0
  var mainSizes = newSeq[int](nodes.len)

  let totalGap = if nodes.len > 1: parentGap * (nodes.len - 1) else: 0

  for i, node in nodes:
    let spec = if isHorizontal: node.props.width else: node.props.height
    let content = if isHorizontal: node.contentWidth else: node.contentHeight
    case spec.kind
    of szFixed:
      mainSizes[i] = spec.fixed
      fixedTotal += spec.fixed
    of szPercent:
      mainSizes[i] = int(spec.percent / 100.0 * float(mainSize))
      fixedTotal += mainSizes[i]
    of szAuto:
      let pad = if isHorizontal: node.props.padding.padH() else: node.props.padding.padV()
      mainSizes[i] = content + pad
      fixedTotal += mainSizes[i]
    of szFlex:
      flexTotal += spec.flex
      mainSizes[i] = 0  # Will be resolved

  # Second pass: distribute remaining space to flex items
  let remaining = max(0, mainSize - fixedTotal - totalGap)
  if flexTotal > 0:
    var distributed = 0
    var lastFlexIdx = -1
    for i, node in nodes:
      let spec = if isHorizontal: node.props.width else: node.props.height
      if spec.kind == szFlex:
        mainSizes[i] = int(spec.flex / flexTotal * float(remaining))
        distributed += mainSizes[i]
        lastFlexIdx = i
    # Give rounding remainder to last flex item
    if lastFlexIdx >= 0 and distributed < remaining:
      mainSizes[lastFlexIdx] += remaining - distributed

  # Apply constraints
  for i, node in nodes:
    let c = node.props.constraint
    if isHorizontal:
      mainSizes[i] = clampSize(mainSizes[i], c.minWidth, c.maxWidth)
    else:
      mainSizes[i] = clampSize(mainSizes[i], c.minHeight, c.maxHeight)

  # Third pass: resolve cross-axis sizes
  var crossSizes = newSeq[int](nodes.len)
  for i, node in nodes:
    let spec = if isHorizontal: node.props.height else: node.props.width
    let content = if isHorizontal: node.contentHeight else: node.contentWidth
    case spec.kind
    of szFixed: crossSizes[i] = spec.fixed
    of szPercent: crossSizes[i] = int(spec.percent / 100.0 * float(crossSize))
    of szFlex: crossSizes[i] = crossSize  # Flex on cross axis = fill
    of szAuto:
      let pad = if isHorizontal: node.props.padding.padV() else: node.props.padding.padH()
      crossSizes[i] = content + pad

    let c = node.props.constraint
    if isHorizontal:
      crossSizes[i] = clampSize(crossSizes[i], c.minHeight, c.maxHeight)
    else:
      crossSizes[i] = clampSize(crossSizes[i], c.minWidth, c.maxWidth)

  # Fourth pass: position items
  var mainUsed = 0
  for i in 0 ..< nodes.len:
    mainUsed += mainSizes[i]
  mainUsed += totalGap

  # Justify content offset
  var mainOffset = case parentJustify
    of alStart: 0
    of alCenter: max(0, (mainSize - mainUsed) div 2)
    of alEnd: max(0, mainSize - mainUsed)

  for i in 0 ..< nodes.len:
    let mainPos = mainOffset
    let crossPos = case parentAlign
      of alStart: 0
      of alCenter: max(0, (crossSize - crossSizes[i]) div 2)
      of alEnd: max(0, crossSize - crossSizes[i])

    if isHorizontal:
      result[i] = Rect(
        x: parentRect.x + mainPos,
        y: parentRect.y + crossPos,
        w: mainSizes[i],
        h: crossSizes[i],
      )
    else:
      result[i] = Rect(
        x: parentRect.x + crossPos,
        y: parentRect.y + mainPos,
        w: crossSizes[i],
        h: mainSizes[i],
      )

    mainOffset += mainSizes[i] + parentGap
