## CPS TUI - Declarative DSL
##
## Macro DSL for building TUI widget trees declaratively.
## Transforms `tui:` blocks into widget constructor calls.
##
## Example:
##   let ui = tui:
##     vbox:
##       border "Chat", bsRounded:
##         text messages.join("\n"), wrap=twWrap
##       hbox:
##         label "> "
##         input myInput
##
## Supports:
## - Widgets: vbox, hbox, border, text, label, input, list, table, spacer,
##   progressBar, tabs, custom, scrollView, container
## - Properties: style=, gap=, width=, height=, id=, onClick=, onKey=, etc.
##   Special: focusable= expands to withFocus + withFocusTrap;
##   width=/height= auto-wraps integer literals in fixed().
## - Control flow: if/elif/else, for, case/of, when
## - Statements: let, var, discard inside widget blocks

import std/macros

# ============================================================
# Dispatch tables
# ============================================================

const PropertyMap* = [
  ("style", "withStyle"), ("gap", "withGap"), ("padding", "withPadding"),
  ("width", "withWidth"), ("height", "withHeight"), ("id", "withId"),
  ("align", "withAlign"), ("justify", "withJustify"), ("wrap", "withWrap"),
  ("textAlign", "withTextAlign"), ("focus", "withFocus"),
  ("direction", "withDirection"), ("constraint", "withConstraint"),
  ("onClick", "withOnClick"), ("onKey", "withOnKey"),
  ("onScroll", "withOnScroll"), ("onMouse", "withOnMouse"),
  ("onFocus", "withOnFocus"), ("onBlur", "withOnBlur"),
  ("focusTrap", "withFocusTrap"),
]

const PassthroughWidgets* = [
  ## DSL name -> constructor proc name for widgets that forward args directly.
  ("spacer", "spacer"), ("progressBar", "progressBar"),
  ("tabs", "tabBar"), ("custom", "custom"),
  ("scrollView", "scrollView"), ("list", "list"), ("table", "table"),
]

proc lookupProperty(name: string): string =
  for (k, v) in PropertyMap:
    if k == name: return v

proc lookupPassthrough(name: string): string =
  for (k, v) in PassthroughWidgets:
    if k == name: return v

proc isWidgetName(name: string): bool =
  name in ["vbox", "hbox", "container", "overlay", "border", "text", "label", "input"] or
  lookupPassthrough(name) != ""

proc isKnownProperty(name: string): bool =
  name == "focusable" or lookupProperty(name) != ""

proc isPropertyShorthand(n: NimNode): bool =
  ## Detect `gap 2` style shorthand: a 2-arg call/command whose name is a
  ## known property but not a widget name.
  n.kind in {nnkCall, nnkCommand} and n.len == 2 and
  n[0].kind == nnkIdent and
  not isWidgetName(n[0].strVal) and
  isKnownProperty(n[0].strVal)

# ============================================================
# NimNode helpers
# ============================================================

proc identDefs(name, typ: string): NimNode =
  ## Shorthand for `nnkIdentDefs(ident name, ident typ, empty)`.
  newTree(nnkIdentDefs, ident(name), ident(typ), newEmptyNode())

proc applyProp(w: NimNode, name: string, val: NimNode): NimNode =
  ## Chain a single property modifier onto a widget expression.
  # focusable = true -> .withFocus(true).withFocusTrap(true)
  if name == "focusable":
    return newCall(ident"withFocusTrap", newCall(ident"withFocus", w, val), val)
  let meth = lookupProperty(name)
  if meth == "":
    error("Unknown TUI property: " & name, val)
  var v = val
  # width=14 / height=3 -> withWidth(fixed(14)) / withHeight(fixed(3))
  if name in ["width", "height"] and val.kind == nnkIntLit:
    v = newCall(ident"fixed", val)
  newCall(ident(meth), w, v)

proc applyProps(w: NimNode, props: openArray[NimNode]): NimNode =
  ## Chain all property assignments onto a widget expression.
  result = w
  for p in props:
    result = applyProp(result, p[0].strVal, p[1])

proc wrapStmts(expr: NimNode, stmts: openArray[NimNode]): NimNode =
  ## Wrap expression in `block: stmts; expr`, or return as-is if no stmts.
  if stmts.len == 0: return expr
  var body = newStmtList()
  for s in stmts: body.add(s)
  body.add(expr)
  newTree(nnkBlockExpr, newEmptyNode(), body)

proc spacerFallback(): NimNode =
  newCall(ident"spacer", newLit(0))

proc wrapChildren(children: openArray[NimNode]): NimNode =
  ## Wrap 0+ children: 0 -> spacer, 1 -> identity, 2+ -> vbox.
  if children.len == 0: return newCall(ident"spacer")
  if children.len == 1: return children[0]
  result = newCall(ident"vbox")
  for c in children: result.add(c)

# ============================================================
# Body parsing
# ============================================================

const StmtKinds = {nnkLetSection, nnkVarSection, nnkDiscardStmt,
                   nnkCommentStmt, nnkPragma, nnkProcDef, nnkFuncDef,
                   nnkTemplateDef, nnkTypeSection}

proc transform(n: NimNode): NimNode  # forward decl

type Body = tuple[props, stmts, children: seq[NimNode]]

proc parseBody(n: NimNode): Body =
  ## Classify body nodes into properties, statements, and widget children.
  for child in n:
    if child.kind in {nnkAsgn, nnkExprEqExpr}:
      result.props.add(child)
    elif child.kind in StmtKinds:
      result.stmts.add(child)
    elif child.isPropertyShorthand:
      result.props.add(newTree(nnkAsgn, child[0], child[1]))
    else:
      result.children.add(transform(child))

# ============================================================
# Widget transforms
# ============================================================

proc buildGeneric(ctor: string, n: NimNode, bodyChildrenAsArgs: bool): NimNode =
  ## Shared transform for containers (vbox/hbox/container) and passthrough
  ## widgets (spacer/list/table/etc.). Parses inline args, body block with
  ## properties/statements/children.
  ## bodyChildrenAsArgs=true: body children become constructor varargs (containers).
  ## bodyChildrenAsArgs=false: positional args go to constructor (passthrough).
  var positional: seq[NimNode]
  var inlineProps: seq[NimNode]
  var body: NimNode
  for i in 1 ..< n.len:
    let a = n[i]
    if a.kind == nnkStmtList:
      body = a
    elif a.kind == nnkExprEqExpr and a[0].kind == nnkIdent and
         isKnownProperty(a[0].strVal):
      inlineProps.add(a)
    else:
      positional.add(a)

  result = newCall(ident(ctor))
  var stmts: seq[NimNode]
  if body != nil:
    let b = parseBody(body)
    stmts = b.stmts
    if bodyChildrenAsArgs:
      for c in b.children: result.add(c)
    else:
      for a in positional: result.add(a)
      # scrollView: body children become the scroll child
      if ctor == "scrollView" and b.children.len > 0:
        result.add(wrapChildren(b.children))
    result = applyProps(result, b.props)
  else:
    for a in positional: result.add(a)
  result = applyProps(result, inlineProps)
  result = wrapStmts(result, stmts)

proc buildBorder(n: NimNode): NimNode =
  ## border [title] [, bsStyle] [, titleStyle=...] [, prop=val]: body
  var title = newLit("")
  var bst = ident"bsSingle"
  var body: NimNode
  var inlineProps: seq[NimNode]
  var ctorArgs: seq[NimNode]  # named args forwarded to border() constructor
  for i in 1 ..< n.len:
    let a = n[i]
    case a.kind
    of nnkStmtList: body = a
    of nnkStrLit: title = a
    of nnkExprEqExpr:
      if a[0].kind == nnkIdent and isKnownProperty(a[0].strVal):
        inlineProps.add(a)
      else:
        ctorArgs.add(a)  # e.g. titleStyle=style(clRed)
    of nnkIdent:
      # Heuristic: idents starting with "bs" are border styles
      if a.strVal.len >= 2 and a.strVal[0] == 'b' and a.strVal[1] == 's':
        bst = a
      else: title = a
    else: title = a

  var stmts: seq[NimNode]
  if body != nil:
    let b = parseBody(body)
    stmts = b.stmts
    var call = newCall(ident"border", wrapChildren(b.children), bst, title)
    for a in ctorArgs: call.add(a)
    result = applyProps(call, b.props)
  else:
    result = newCall(ident"border", newCall(ident"spacer"), bst, title)
    for a in ctorArgs: result.add(a)
  result = applyProps(result, inlineProps)
  result = wrapStmts(result, stmts)

proc buildText(n: NimNode): NimNode =
  ## text/label content [, style] [, prop=val]
  let ctor = n[0].strVal
  var content = newLit("")
  var st = ident"styleDefault"
  var hasContent = false
  var props: seq[NimNode]
  for i in 1 ..< n.len:
    let a = n[i]
    if a.kind == nnkExprEqExpr: props.add(a)
    elif a.kind == nnkStmtList: discard
    elif not hasContent: content = a; hasContent = true
    else: st = a
  applyProps(newCall(ident(ctor), content, st), props)

proc buildInput(n: NimNode): NimNode =
  ## input textInputRef [, prop=val]  OR  input text="...", cursor=0
  if n.len >= 2 and n[1].kind == nnkIdent:
    result = newCall(ident"toWidget", n[1])
    for i in 2 ..< n.len:
      if n[i].kind == nnkExprEqExpr:
        result = applyProp(result, n[i][0].strVal, n[i][1])
  else:
    result = newCall(ident"inputField")
    for i in 1 ..< n.len:
      if n[i].kind == nnkExprEqExpr:
        if n[i][0].strVal in ["text", "cursor", "placeholder", "mask", "st"]:
          result.add(newTree(nnkExprEqExpr, n[i][0], n[i][1]))
        else:
          result = applyProp(result, n[i][0].strVal, n[i][1])
      else:
        result.add(n[i])

# ============================================================
# Control flow transforms
# ============================================================

proc transformConditional(n: NimNode,
    outKind, elifKind, elseKind: NimNodeKind): NimNode =
  ## Shared transform for if/when: iterate branches, transform bodies,
  ## and add a spacer fallback if no else branch is present.
  result = newNimNode(outKind)
  var hasElse = false
  for branch in n:
    case branch.kind
    of nnkElifBranch:
      result.add(newTree(elifKind, branch[0], transform(branch[1])))
    of nnkElse:
      hasElse = true
      result.add(newTree(elseKind, transform(branch[0])))
    else: discard
  if not hasElse:
    result.add(newTree(elseKind, spacerFallback()))

proc transformCase(n: NimNode): NimNode =
  ## Transform case/of/else — has a discriminator and OfBranch labels,
  ## so it can't share the if/when path.
  result = newNimNode(nnkCaseStmt)
  result.add(n[0])  # discriminator
  var hasElse = false
  for i in 1 ..< n.len:
    let branch = n[i]
    case branch.kind
    of nnkOfBranch:
      var ob = newNimNode(nnkOfBranch)
      for j in 0 ..< branch.len - 1: ob.add(branch[j])
      ob.add(transform(branch[^1]))
      result.add(ob)
    of nnkElse:
      hasElse = true
      result.add(newTree(nnkElse, transform(branch[0])))
    of nnkElifBranch:
      result.add(newTree(nnkElifBranch, branch[0], transform(branch[1])))
    else: discard
  if not hasElse:
    result.add(newTree(nnkElse, spacerFallback()))

proc transformFor(n: NimNode): NimNode =
  ## for vars in iterable: body ->
  ##   block: var tmp: seq[Widget]; for ...: tmp.add(body); containerFromSeq(tmp)
  let tmp = genSym(nskVar, "dslFor")
  let iterIdx = n.len - 2
  var loop = newNimNode(nnkForStmt)
  for i in 0 ..< iterIdx: loop.add(n[i])
  loop.add(n[iterIdx])
  loop.add(newStmtList(
    newCall(newDotExpr(tmp, ident"add"), transform(n[^1]))))
  newTree(nnkBlockExpr, newEmptyNode(), newStmtList(
    newTree(nnkVarSection, newTree(nnkIdentDefs,
      tmp, newTree(nnkBracketExpr, ident"seq", ident"Widget"), newEmptyNode())),
    loop,
    newCall(ident"containerFromSeq", tmp)))

# ============================================================
# Main recursive transform
# ============================================================

proc transform(n: NimNode): NimNode =
  case n.kind
  of nnkCall, nnkCommand:
    if n[0].kind == nnkIdent:
      let name = n[0].strVal
      case name
      of "vbox", "hbox", "container", "overlay":
        return buildGeneric(name, n, bodyChildrenAsArgs = true)
      of "border": return buildBorder(n)
      of "text", "label": return buildText(n)
      of "input": return buildInput(n)
      else:
        let ctor = lookupPassthrough(name)
        if ctor != "":
          return buildGeneric(ctor, n, bodyChildrenAsArgs = false)
    n  # unknown call — pass through

  of nnkStmtList:
    if n.len == 1: return transform(n[0])
    # Separate statements from widget children
    var stmts: seq[NimNode]
    var children: seq[NimNode]
    for child in n:
      if child.kind in StmtKinds:
        stmts.add(child)
      else:
        children.add(transform(child))
    let widget = case children.len
      of 0: spacerFallback()
      of 1: children[0]
      else:
        var v = newCall(ident"vbox")
        for c in children: v.add(c)
        v
    wrapStmts(widget, stmts)

  of nnkIfStmt:
    transformConditional(n, nnkIfExpr, nnkElifExpr, nnkElseExpr)
  of nnkWhenStmt:
    transformConditional(n, nnkWhenStmt, nnkElifBranch, nnkElse)
  of nnkCaseStmt:
    transformCase(n)
  of nnkForStmt:
    transformFor(n)
  of nnkStrLit, nnkIntLit, nnkFloatLit:
    newCall(ident"text", n)  # literal -> text widget
  else:
    n  # pass through identifiers, dot exprs, infixes, etc.

# ============================================================
# Public macros
# ============================================================

macro tui*(body: untyped): untyped =
  ## Build a widget tree from a declarative DSL block.
  ##
  ## Example:
  ##   let ui = tui:
  ##     vbox:
  ##       text "Hello"
  ##       if showFooter:
  ##         text "Footer"
  ##       for name in names:
  ##         text name
  transform(body)

macro tuiRender*(body: untyped): untyped =
  ## Create a `proc(width, height: int): Widget` from a DSL block.
  newTree(nnkLambda,
    newEmptyNode(), newEmptyNode(), newEmptyNode(),
    newTree(nnkFormalParams, ident"Widget",
      identDefs("width", "int"), identDefs("height", "int")),
    newEmptyNode(), newEmptyNode(),
    newStmtList(transform(body)))
