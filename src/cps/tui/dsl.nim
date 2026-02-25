## CPS TUI - Reactive DSL
##
## A Nim macro DSL for building reactive TUI interfaces declaratively.
## Transforms a block of widget descriptions into a widget tree, with
## automatic re-rendering on state changes.
##
## Example:
##   let ui = tui:
##     vbox:
##       border "Chat", bsRounded:
##         text messages.val.join("\n"), wrap=twWrap
##       hbox:
##         label "> "
##         input myInput
##
## The DSL supports:
## - Widget constructors: vbox, hbox, border, text, label, input, list,
##   table, spacer, progressBar, tabs, custom
## - Property assignments: style=, gap=, padding=, width=, height=, id=,
##   align=, justify=, wrap=, textAlign=, focus=
## - Reactive bindings: expressions referencing Signal[T] are re-evaluated

import std/[macros, strutils]

proc isWidgetIdent(n: NimNode): bool =
  ## Check if an ident is a known widget constructor.
  if n.kind != nnkIdent:
    return false
  let name = n.strVal
  name in ["vbox", "hbox", "border", "text", "label", "input",
           "list", "table", "spacer", "progressBar", "tabs",
           "custom", "scrollView", "container"]

proc transformPropertyAssign(call: NimNode, prop: string, value: NimNode): NimNode =
  ## Generate a property modifier call on the widget.
  case prop
  of "style": return newCall(ident"withStyle", call, value)
  of "gap": return newCall(ident"withGap", call, value)
  of "padding": return newCall(ident"withPadding", call, value)
  of "width": return newCall(ident"withWidth", call, value)
  of "height": return newCall(ident"withHeight", call, value)
  of "id": return newCall(ident"withId", call, value)
  of "align": return newCall(ident"withAlign", call, value)
  of "justify": return newCall(ident"withJustify", call, value)
  of "wrap": return newCall(ident"withWrap", call, value)
  of "textAlign": return newCall(ident"withTextAlign", call, value)
  of "focus": return newCall(ident"withFocus", call, value)
  of "direction": return newCall(ident"withDirection", call, value)
  of "constraint": return newCall(ident"withConstraint", call, value)
  else:
    error("Unknown TUI property: " & prop, value)
    call  # Unreachable but satisfies return type

proc transformDslNode(n: NimNode): NimNode

proc extractBody(n: NimNode): tuple[props: seq[NimNode], children: seq[NimNode]] =
  ## Separate property assignments from child widgets in a body block.
  result.props = @[]
  result.children = @[]
  for child in n:
    if child.kind == nnkAsgn or
       (child.kind == nnkExprEqExpr):
      result.props.add(child)
    elif child.kind == nnkCall and child.len == 2 and
         child[0].kind == nnkIdent and not isWidgetIdent(child[0]):
      # Could be a property assignment like: gap 2
      # But could also be a function call. Heuristic: known props.
      let name = child[0].strVal
      if name in ["style", "gap", "padding", "width", "height", "id",
                   "align", "justify", "wrap", "textAlign", "focus",
                   "direction", "constraint"]:
        result.props.add(newTree(nnkAsgn, child[0], child[1]))
      else:
        result.children.add(transformDslNode(child))
    else:
      result.children.add(transformDslNode(child))

proc transformContainer(name: string, n: NimNode): NimNode =
  ## Transform vbox/hbox/container with optional body.
  let constructorName = case name
    of "vbox": "vbox"
    of "hbox": "hbox"
    else: "container"

  # Find the body (last StmtList child)
  var args: seq[NimNode] = @[]
  var body: NimNode = nil
  for i in 1 ..< n.len:
    if n[i].kind == nnkStmtList:
      body = n[i]
    elif n[i].kind == nnkExprEqExpr:
      args.add(n[i])
    else:
      args.add(n[i])

  var result0: NimNode
  if body != nil:
    let (props, children) = extractBody(body)
    # Build constructor with children as varargs
    result0 = newCall(ident(constructorName))
    for child in children:
      result0.add(child)
    # Apply properties
    for prop in props:
      result0 = transformPropertyAssign(result0, prop[0].strVal, prop[1])
  else:
    result0 = newCall(ident(constructorName))

  # Apply inline property args
  for arg in args:
    if arg.kind == nnkExprEqExpr:
      result0 = transformPropertyAssign(result0, arg[0].strVal, arg[1])

  return result0

proc transformBorder(n: NimNode): NimNode =
  ## Transform border with optional title, style, and child body.
  # border [title] [, borderStyle] : body
  var title = newLit("")
  var borderSt = ident"bsSingle"
  var body: NimNode = nil
  var inlineProps: seq[NimNode] = @[]

  for i in 1 ..< n.len:
    if n[i].kind == nnkStmtList:
      body = n[i]
    elif n[i].kind == nnkStrLit:
      title = n[i]
    elif n[i].kind == nnkExprEqExpr:
      inlineProps.add(n[i])
    elif n[i].kind == nnkIdent and n[i].strVal.startsWith("bs"):
      borderSt = n[i]
    else:
      # Assume it's a title expression
      title = n[i]

  var child: NimNode
  if body != nil:
    let (props, children) = extractBody(body)
    if children.len == 1:
      child = children[0]
    elif children.len > 1:
      # Wrap multiple children in vbox
      child = newCall(ident"vbox")
      for c in children:
        child.add(c)
    else:
      child = newCall(ident"spacer")

    result = newCall(ident"border", child, borderSt, title)
    for prop in props:
      result = transformPropertyAssign(result, prop[0].strVal, prop[1])
  else:
    child = newCall(ident"spacer")
    result = newCall(ident"border", child, borderSt, title)

  for prop in inlineProps:
    result = transformPropertyAssign(result, prop[0].strVal, prop[1])

proc transformText(n: NimNode): NimNode =
  ## Transform text/label widget.
  let constructor = n[0].strVal  # "text" or "label"
  var textExpr: NimNode = newLit("")
  var stylExpr: NimNode = ident"styleDefault"
  var props: seq[NimNode] = @[]

  for i in 1 ..< n.len:
    if n[i].kind == nnkExprEqExpr:
      props.add(n[i])
    elif n[i].kind == nnkStmtList:
      # Should not have body for text, but handle gracefully
      discard
    elif textExpr.kind == nnkStrLit and textExpr.strVal == "":
      textExpr = n[i]
    else:
      stylExpr = n[i]

  result = newCall(ident(constructor), textExpr, stylExpr)
  for prop in props:
    result = transformPropertyAssign(result, prop[0].strVal, prop[1])

proc transformInput(n: NimNode): NimNode =
  ## Transform input widget. Accepts a TextInput ref or inline params.
  # input myTextInput [, style=...]
  # OR input text="...", cursor=0, placeholder="..."
  if n.len >= 2 and n[1].kind == nnkIdent:
    # input myTextInput — call toWidget on the TextInput object
    result = newCall(ident"toWidget", n[1])
    for i in 2 ..< n.len:
      if n[i].kind == nnkExprEqExpr:
        result = transformPropertyAssign(result, n[i][0].strVal, n[i][1])
  else:
    # Inline params
    result = newCall(ident"inputField")
    for i in 1 ..< n.len:
      if n[i].kind == nnkExprEqExpr:
        let pname = n[i][0].strVal
        case pname
        of "text", "cursor", "placeholder", "mask", "st":
          result.add(newTree(nnkExprEqExpr, n[i][0], n[i][1]))
        else:
          # widget property
          result = transformPropertyAssign(result, pname, n[i][1])
      else:
        result.add(n[i])

proc transformDslNode(n: NimNode): NimNode =
  ## Transform a single DSL node into widget constructor calls.
  case n.kind
  of nnkCall, nnkCommand:
    if n[0].kind == nnkIdent:
      let name = n[0].strVal
      case name
      of "vbox", "hbox", "container":
        return transformContainer(name, n)
      of "border":
        return transformBorder(n)
      of "text", "label":
        return transformText(n)
      of "input":
        return transformInput(n)
      of "spacer":
        if n.len > 1:
          return newCall(ident"spacer", n[1])
        else:
          return newCall(ident"spacer")
      of "progressBar":
        result = newCall(ident"progressBar")
        for i in 1 ..< n.len:
          if n[i].kind != nnkStmtList:
            result.add(n[i])
        return result
      of "tabs":
        result = newCall(ident"tabBar")
        for i in 1 ..< n.len:
          if n[i].kind != nnkStmtList:
            result.add(n[i])
        return result
      of "custom":
        if n.len > 1:
          return newCall(ident"custom", n[1])
        return newCall(ident"custom")
      else:
        # Unknown — pass through as a regular call (could be user widget)
        return n
    else:
      return n
  of nnkStmtList:
    # Multiple children — wrap in vbox
    if n.len == 1:
      return transformDslNode(n[0])
    else:
      result = newCall(ident"vbox")
      for child in n:
        result.add(transformDslNode(child))
      return result
  of nnkStrLit, nnkIntLit, nnkFloatLit:
    # Literal text → text widget
    return newCall(ident"text", n)
  of nnkIdent:
    # Bare identifier — could be a widget variable
    return n
  of nnkInfix:
    # Pass through expressions
    return n
  of nnkDotExpr:
    return n
  of nnkAsgn, nnkExprEqExpr:
    return n
  else:
    return n

macro tui*(body: untyped): untyped =
  ## Build a widget tree from a declarative DSL block.
  ##
  ## Example:
  ##   let ui = tui:
  ##     vbox:
  ##       text "Hello"
  ##       hbox gap=1:
  ##         label "Name:"
  ##         input myInput
  result = transformDslNode(body)

macro tuiRender*(body: untyped): untyped =
  ## Create a render proc from a DSL block.
  ## The proc receives (width, height: int) and returns Widget.
  ##
  ## Example:
  ##   app.onRender = tuiRender:
  ##     vbox:
  ##       text "Size: " & $width & "x" & $height
  let widthIdent = ident"width"
  let heightIdent = ident"height"
  let transformed = transformDslNode(body)
  result = newTree(nnkLambda,
    newEmptyNode(),  # name
    newEmptyNode(),  # terms
    newEmptyNode(),  # generic params
    newTree(nnkFormalParams,
      ident"Widget",
      newTree(nnkIdentDefs, widthIdent, ident"int", newEmptyNode()),
      newTree(nnkIdentDefs, heightIdent, ident"int", newEmptyNode()),
    ),
    newEmptyNode(),  # pragmas
    newEmptyNode(),  # reserved
    newStmtList(transformed),
  )
