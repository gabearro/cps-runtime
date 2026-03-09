## Swift source emitter for GUI IR.

import std/[os, strutils, tables, sets, sequtils]
import ./types
import ./ast
import ./ir

type
  EmitContext = object
    stateNames: HashSet[string]
    localNames: HashSet[string]
    actionCaseByName: Table[string, string]

proc swiftIdent(name: string): string =
  var text = ""
  for c in name:
    if c.isAlphaNumeric or c == '_':
      text.add c
    else:
      text.add '_'
  if text.len == 0:
    return "value"
  if text[0].isDigit:
    text = "v_" & text
  text

proc lowerCamel(name: string): string =
  let s = swiftIdent(name)
  if s.len == 0:
    return "value"
  toLowerAscii(s[0]) & s[1 .. ^1]

proc swiftTypeName(typ: string): string =
  let t = typ.strip()
  if t.len == 0:
    return "Any"
  if t.endsWith("[]"):
    let base = t[0 ..< t.len - 2]
    return "[" & swiftTypeName(base) & "]"
  if t.endsWith("?"):
    let base = t[0 ..< t.len - 1]
    return swiftTypeName(base) & "?"
  if t.contains('.'):
    return t.split('.').mapIt(swiftIdent(it)).join(".")
  swiftIdent(t)

proc indent(level: int): string {.inline.} =
  "  ".repeat(level)

proc escapeSwiftString(value: string): string =
  value
    .replace("\\", "\\\\")
    .replace("\"", "\\\"")
    .replace("\n", "\\n")
    .replace("\r", "\\r")
    .replace("\t", "\\t")

proc actionRefFromExpr(expr: GuiExpr, actionCaseByName: Table[string, string]): string =
  if expr.isNil:
    return ""

  let path = memberPath(expr)
  if expr.kind == geIdent and expr.ident in actionCaseByName:
    return "." & actionCaseByName[expr.ident]

  if path.len == 1 and path[0] in actionCaseByName:
    return "." & actionCaseByName[path[0]]

  if path.len == 2 and path[0] == "Action" and path[1] in actionCaseByName:
    return "." & actionCaseByName[path[1]]

  if expr.kind == geCall:
    let cpath = memberPath(expr.callee)
    if cpath.len > 0:
      let actionName = cpath[^1]
      if actionName in actionCaseByName:
        var parts: seq[string] = @[]
        if expr.namedArgs.len > 0:
          for arg in expr.namedArgs:
            parts.add swiftIdent(arg.name) & ": " & "/*action-arg*/"
        elif expr.args.len > 0:
          for valueExpr in expr.args:
            parts.add "/*action-arg*/"
        if parts.len == 0:
          return "." & actionCaseByName[actionName]
        return "." & actionCaseByName[actionName] & "(" & parts.join(", ") & ")"

  ""

proc exprLikelyString(expr: GuiExpr): bool =
  if expr.isNil:
    return false
  case expr.kind
  of geStringLit, geInterpolatedString:
    true
  of geBinary:
    expr.op == "+" and (exprLikelyString(expr.left) or exprLikelyString(expr.right))
  else:
    false

proc emitExpr(ctx: EmitContext, expr: GuiExpr, uiContext: bool): string
proc emitBindingExpr(ctx: EmitContext, expr: GuiExpr): string

proc emitExpr(ctx: EmitContext, expr: GuiExpr, uiContext: bool): string =
  if expr.isNil:
    return "nil"

  case expr.kind
  of geStringLit:
    "\"" & escapeSwiftString(expr.strVal) & "\""
  of geIntLit:
    $expr.intVal
  of geFloatLit:
    $expr.floatVal
  of geBoolLit:
    if expr.boolVal: "true" else: "false"
  of geNullLit:
    "nil"
  of geTokenRef:
    "GUITokens." & swiftIdent(expr.tokenGroup & "_" & expr.tokenName)
  of geIdent:
    let id = swiftIdent(expr.ident)
    if uiContext:
      if id in ctx.localNames:
        id
      elif id in ctx.stateNames:
        "store.state." & id
      else:
        id
    else:
      if id in ctx.localNames:
        id
      elif id in ctx.stateNames:
        "state." & id
      else:
        id
  of geMember:
    let leftText = emitExpr(ctx, expr.left, uiContext)
    if expr.isOptional:
      leftText & "?." & swiftIdent(expr.ident)
    else:
      leftText & "." & swiftIdent(expr.ident)
  of geBinary:
    # Unary minus: 0 - x  →  -x
    if expr.op == "-" and expr.left != nil and expr.left.kind == geIntLit and expr.left.intVal == 0:
      let rightExpr = emitExpr(ctx, expr.right, uiContext)
      return "-" & rightExpr
    let leftExpr = emitExpr(ctx, expr.left, uiContext)
    let rightExpr = emitExpr(ctx, expr.right, uiContext)
    if expr.op == "+" and (exprLikelyString(expr.left) or exprLikelyString(expr.right)):
      "(String(describing: " & leftExpr & ") + String(describing: " & rightExpr & "))"
    else:
      "(" & leftExpr & " " & expr.op & " " & rightExpr & ")"
  of geCall:
    # Action constructor support.
    let cpath = memberPath(expr.callee)
    if cpath.len > 0 and cpath[^1] in ctx.actionCaseByName:
      let actionCase = ctx.actionCaseByName[cpath[^1]]
      if expr.namedArgs.len > 0:
        var namedParts: seq[string] = @[]
        for arg in expr.namedArgs:
          namedParts.add swiftIdent(arg.name) & ": " & emitExpr(ctx, arg.value, uiContext)
        return "." & actionCase & "(" & namedParts.join(", ") & ")"
      if expr.args.len > 0:
        let argsText = expr.args.mapIt(emitExpr(ctx, it, uiContext)).join(", ")
        return "." & actionCase & "(" & argsText & ")"
      return "." & actionCase

    # Lightweight conditional helper for UI DSL expressions.
    # select(condition, whenTrue, whenFalse) -> (condition ? whenTrue : whenFalse)
    if cpath.len == 1 and cpath[0] == "select" and expr.args.len == 3:
      return "((" & emitExpr(ctx, expr.args[0], uiContext) & ") ? (" &
        emitExpr(ctx, expr.args[1], uiContext) & ") : (" &
        emitExpr(ctx, expr.args[2], uiContext) & "))"
    if cpath.len == 1 and cpath[0] == "not" and expr.args.len == 1:
      return "(!(" & emitExpr(ctx, expr.args[0], uiContext) & "))"

    var parts: seq[string] = @[]
    for arg in expr.args:
      parts.add emitExpr(ctx, arg, uiContext)
    for arg in expr.namedArgs:
      parts.add swiftIdent(arg.name) & ": " & emitExpr(ctx, arg.value, uiContext)
    emitExpr(ctx, expr.callee, uiContext) & "(" & parts.join(", ") & ")"
  of geArrayLit:
    "[" & expr.items.mapIt(emitExpr(ctx, it, uiContext)).join(", ") & "]"
  of geInterpolatedString:
    # Emit Swift string interpolation: "text \(expr) text \(expr) text"
    var swiftStr = "\""
    for i, part in expr.parts:
      swiftStr.add escapeSwiftString(part)
      if i < expr.expressions.len:
        swiftStr.add "\\(" & emitExpr(ctx, expr.expressions[i], uiContext) & ")"
    swiftStr.add "\""
    swiftStr
  of geEnumValue:
    "." & swiftIdent(expr.ident)
  of geSubscript:
    let leftExpr = emitExpr(ctx, expr.left, uiContext)
    let indexExpr = emitExpr(ctx, expr.right, uiContext)
    leftExpr & "[" & indexExpr & "]"
  of geMapLit:
    var entries: seq[string] = @[]
    for item in expr.entries:
      entries.add "\"" & escapeSwiftString(item.key) & "\": " & emitExpr(ctx, item.value, uiContext)
    "[" & entries.join(", ") & "]"
  of geClosure:
    if expr.closureParams.len > 0:
      "{ " & expr.closureParams.join(", ") & " in " & emitExpr(ctx, expr.closureBody, uiContext) & " }"
    else:
      "{ " & emitExpr(ctx, expr.closureBody, uiContext) & " }"
  of geKeyPath:
    if expr.keyPathRoot.len > 0:
      "\\" & swiftIdent(expr.keyPathRoot) & "." & expr.keyPathMembers.mapIt(swiftIdent(it)).join(".")
    elif expr.keyPathMembers.len > 0:
      "\\." & expr.keyPathMembers.mapIt(swiftIdent(it)).join(".")
    else:
      "\\.self"
  of geTypeCast:
    let leftExpr = emitExpr(ctx, expr.left, uiContext)
    "(" & leftExpr & " " & expr.op & " " & swiftTypeName(expr.ident) & ")"
  of geTypeCheck:
    let leftExpr = emitExpr(ctx, expr.left, uiContext)
    "(" & leftExpr & " is " & swiftTypeName(expr.ident) & ")"
  of geBindingPrefix:
    let id = swiftIdent(expr.ident)
    if uiContext:
      if id in ctx.localNames:
        "$" & id
      elif id in ctx.stateNames:
        "$store.state." & id
      else:
        "$" & id
    else:
      "$" & id
  of geShorthandParam:
    "$" & $expr.intVal
  of geForceUnwrap:
    emitExpr(ctx, expr.left, uiContext) & "!"

proc emitBindingExpr(ctx: EmitContext, expr: GuiExpr): string =
  if expr.isNil:
    return emitExpr(ctx, expr, uiContext = true)

  case expr.kind
  of geIdent:
    let id = swiftIdent(expr.ident)
    if id in ctx.localNames:
      return "$" & id  # @State local var binding
    if id in ctx.stateNames:
      return "$store.state." & id
  of geMember:
    let path = memberPath(expr)
    if path.len == 2 and path[0] == "state":
      return "$store.state." & swiftIdent(path[1])
  of geBoolLit, geIntLit, geFloatLit, geStringLit:
    # Literal values use Binding.constant()
    return ".constant(" & emitExpr(ctx, expr, uiContext = true) & ")"
  else:
    discard

  emitExpr(ctx, expr, uiContext = true)

proc emitActionSendExpr(ctx: EmitContext, expr: GuiExpr): string =
  if expr.isNil:
    return ""

  let actionRef = actionRefFromExpr(expr, ctx.actionCaseByName)
  if actionRef.len > 0 and not actionRef.contains("/*action-arg*/"):
    return actionRef

  let fallback = emitExpr(ctx, expr, uiContext = true)
  if fallback.len == 0 or fallback == "nil":
    return ""
  fallback

proc emitAnyValueExpr(ctx: EmitContext, expr: GuiExpr): string =
  if expr.isNil:
    return ".null"

  let actionRef = actionRefFromExpr(expr, ctx.actionCaseByName)
  if actionRef.len > 0:
    let adjusted =
      if actionRef.contains("/*action-arg*/"):
        # fall back to expression-based conversion for action constructors with payload
        "GUIAnyValue.from(" & emitExpr(ctx, expr, uiContext = false) & ")"
      else:
        ".action(" & actionRef & ")"
    return adjusted

  case expr.kind
  of geStringLit:
    ".string(\"" & escapeSwiftString(expr.strVal) & "\")"
  of geInterpolatedString:
    ".string(" & emitExpr(ctx, expr, uiContext = false) & ")"
  of geIntLit:
    ".int(" & $expr.intVal & ")"
  of geFloatLit:
    ".double(" & $expr.floatVal & ")"
  of geBoolLit:
    if expr.boolVal: ".bool(true)" else: ".bool(false)"
  of geNullLit:
    ".null"
  of geArrayLit:
    ".array([" & expr.items.mapIt(emitAnyValueExpr(ctx, it)).join(", ") & "])"
  of geMapLit:
    var kv: seq[string] = @[]
    for entry in expr.entries:
      kv.add "\"" & escapeSwiftString(entry.key) & "\": " & emitAnyValueExpr(ctx, entry.value)
    ".object([" & kv.join(", ") & "])"
  else:
    "GUIAnyValue.from(" & emitExpr(ctx, expr, uiContext = false) & ")"

proc emitNode(
  ctx: EmitContext,
  node: GuiUiNode,
  level: int,
  componentByName: Table[string, GuiComponentDecl]
): string

proc emitModifierNamedArgExpr(ctx: EmitContext, modName: string, arg: GuiNamedArg): string =
  let key = swiftIdent(arg.name)
  if modName == "searchable" and key == "text":
    return key & ": " & emitBindingExpr(ctx, arg.value)
  key & ": " & emitExpr(ctx, arg.value, uiContext = true)

proc emitModifierCall(
  ctx: EmitContext,
  modDecl: GuiModifierDecl,
  level: int,
  componentByName: Table[string, GuiComponentDecl]
): string =
  let modName = swiftIdent(modDecl.name)

  # Modifiers with isPresented binding + content closure
  if modName in ["sheet", "fullScreenCover", "alert", "confirmationDialog", "popover"]:
    var isPresentedExpr = ""
    var positionalArgs: seq[string] = @[]
    var otherNamedArgs: seq[string] = @[]
    for arg in modDecl.namedArgs:
      let key = swiftIdent(arg.name)
      if key == "isPresented":
        isPresentedExpr = emitBindingExpr(ctx, arg.value)
      elif key == "item":
        otherNamedArgs.add key & ": " & emitBindingExpr(ctx, arg.value)
      else:
        otherNamedArgs.add key & ": " & emitExpr(ctx, arg.value, uiContext = true)
    for arg in modDecl.args:
      if isPresentedExpr.len == 0:
        # First positional arg is isPresented binding
        isPresentedExpr = emitBindingExpr(ctx, arg)
      else:
        positionalArgs.add emitExpr(ctx, arg, uiContext = true)

    # Emit: .alert("Title", isPresented: $binding, otherNamedArgs...)
    var argParts: seq[string] = @[]
    argParts.add positionalArgs
    if isPresentedExpr.len > 0:
      argParts.add "isPresented: " & isPresentedExpr
    argParts.add otherNamedArgs

    if modDecl.children.len > 0:
      result = indent(level) & "." & modName & "(" & argParts.join(", ") & ") {\n"
      for child in modDecl.children:
        result.add emitNode(ctx, child, level + 1, componentByName)
        result.add "\n"
      result.add indent(level) & "}"
      return result
    else:
      return indent(level) & "." & modName & "(" & argParts.join(", ") & ")"

  # onChange modifier: .onChange(of: expr) { oldValue, newValue in ... } or action dispatch
  if modName == "onChange":
    var ofExpr = ""
    var actionExpr: GuiExpr = nil
    var otherArgs: seq[string] = @[]
    for arg in modDecl.namedArgs:
      let key = swiftIdent(arg.name)
      if key == "of":
        ofExpr = emitExpr(ctx, arg.value, uiContext = true)
      elif key in ["perform", "action"]:
        actionExpr = arg.value
      else:
        otherArgs.add key & ": " & emitExpr(ctx, arg.value, uiContext = true)

    if ofExpr.len > 0:
      var parts: seq[string] = @["of: " & ofExpr]
      parts.add otherArgs
      if actionExpr != nil:
        let sendExpr = emitActionSendExpr(ctx, actionExpr)
        if sendExpr.len > 0:
          return indent(level) & "." & modName & "(" & parts.join(", ") & ") { _, _ in store.send(" & sendExpr & ") }"
      if modDecl.children.len > 0:
        result = indent(level) & "." & modName & "(" & parts.join(", ") & ") {\n"
        for child in modDecl.children:
          result.add emitNode(ctx, child, level + 1, componentByName)
          result.add "\n"
        result.add indent(level) & "}"
        return result
      return indent(level) & "." & modName & "(" & parts.join(", ") & ") { _, _ in }"

  # onAppear/onDisappear with action dispatch
  if modName in ["onAppear", "onDisappear"]:
    var actionExpr: GuiExpr = nil
    for arg in modDecl.namedArgs:
      if swiftIdent(arg.name) in ["perform", "action"]:
        actionExpr = arg.value
    if modDecl.args.len > 0 and actionExpr == nil:
      actionExpr = modDecl.args[0]
    if actionExpr != nil:
      let sendExpr = emitActionSendExpr(ctx, actionExpr)
      if sendExpr.len > 0:
        return indent(level) & "." & modName & " { store.send(" & sendExpr & ") }"
    if modDecl.children.len > 0:
      result = indent(level) & "." & modName & " {\n"
      for child in modDecl.children:
        result.add emitNode(ctx, child, level + 1, componentByName)
        result.add "\n"
      result.add indent(level) & "}"
      return result

  # refreshable with action dispatch
  if modName == "refreshable":
    var actionExpr: GuiExpr = nil
    for arg in modDecl.namedArgs:
      if swiftIdent(arg.name) in ["perform", "action"]:
        actionExpr = arg.value
    if modDecl.args.len > 0 and actionExpr == nil:
      actionExpr = modDecl.args[0]
    if actionExpr != nil:
      let sendExpr = emitActionSendExpr(ctx, actionExpr)
      if sendExpr.len > 0:
        return indent(level) & ".refreshable { store.send(" & sendExpr & ") }"

  # onSubmit modifier with action dispatch
  if modName == "onSubmit":
    var actionExpr: GuiExpr = nil
    var triggerArg = ""
    for arg in modDecl.namedArgs:
      let key = swiftIdent(arg.name)
      if key in ["perform", "action"]:
        actionExpr = arg.value
      elif key == "of":
        triggerArg = emitExpr(ctx, arg.value, uiContext = true)
    if modDecl.args.len > 0 and actionExpr == nil:
      actionExpr = modDecl.args[0]

    if actionExpr != nil:
      let sendExpr = emitActionSendExpr(ctx, actionExpr)
      if sendExpr.len > 0:
        if triggerArg.len > 0:
          return indent(level) & ".onSubmit(of: " & triggerArg & ") { store.send(" & sendExpr & ") }"
        return indent(level) & ".onSubmit { store.send(" & sendExpr & ") }"

  # task modifier: .task { await ... }
  if modName == "task":
    if modDecl.children.len > 0:
      result = indent(level) & ".task {\n"
      for child in modDecl.children:
        result.add emitNode(ctx, child, level + 1, componentByName)
        result.add "\n"
      result.add indent(level) & "}"
      return result
    var actionExpr: GuiExpr = nil
    for arg in modDecl.namedArgs:
      if swiftIdent(arg.name) in ["perform", "action"]:
        actionExpr = arg.value
    if modDecl.args.len > 0 and actionExpr == nil:
      actionExpr = modDecl.args[0]
    if actionExpr != nil:
      let sendExpr = emitActionSendExpr(ctx, actionExpr)
      if sendExpr.len > 0:
        return indent(level) & ".task { store.send(" & sendExpr & ") }"
    return indent(level) & ".task { }"

  # swipeActions modifier with edge parameter
  if modName == "swipeActions":
    var edgeArg = ""
    for arg in modDecl.namedArgs:
      if swiftIdent(arg.name) == "edge":
        edgeArg = emitExpr(ctx, arg.value, uiContext = true)
    if modDecl.children.len > 0:
      let head = if edgeArg.len > 0: ".swipeActions(edge: " & edgeArg & ")" else: ".swipeActions"
      result = indent(level) & head & " {\n"
      for child in modDecl.children:
        result.add emitNode(ctx, child, level + 1, componentByName)
        result.add "\n"
      result.add indent(level) & "}"
      return result

  # Gesture action modifiers: onLongPressGesture, onTapGesture, etc.
  if modName in ["onLongPressGesture", "onTapGesture"]:
    var actionExpr: GuiExpr = nil
    var otherArgs: seq[string] = @[]
    for arg in modDecl.namedArgs:
      let key = swiftIdent(arg.name)
      if key in ["perform", "action"]:
        actionExpr = arg.value
      else:
        otherArgs.add key & ": " & emitExpr(ctx, arg.value, uiContext = true)
    if modDecl.args.len > 0 and actionExpr == nil:
      actionExpr = modDecl.args[0]
    if actionExpr != nil:
      let sendExpr = emitActionSendExpr(ctx, actionExpr)
      if sendExpr.len > 0:
        if otherArgs.len > 0:
          return indent(level) & "." & modName & "(" & otherArgs.join(", ") & ") { store.send(" & sendExpr & ") }"
        return indent(level) & "." & modName & " { store.send(" & sendExpr & ") }"

  # focused modifier: .focused($focusVar) — needs binding
  # Optional autoFocus param: .focused(myVar, autoFocus: true) → emits .onAppear { myVar = true }
  if modName == "focused":
    var argsText: seq[string] = @[]
    var autoFocus = false
    var focusVarName = ""
    for arg in modDecl.args:
      let bindExpr = emitBindingExpr(ctx, arg)
      argsText.add bindExpr
      # Extract the variable name (strip leading $)
      if arg.kind == geIdent:
        focusVarName = swiftIdent(arg.ident)
    for arg in modDecl.namedArgs:
      let key = swiftIdent(arg.name)
      if key == "autoFocus":
        # Don't pass autoFocus to Swift — it's our DSL extension
        if arg.value.kind == geBoolLit and arg.value.boolVal:
          autoFocus = true
      else:
        argsText.add key & ": " & emitBindingExpr(ctx, arg.value)
    var focusedLine = indent(level) & ".focused(" & argsText.join(", ") & ")"
    if autoFocus and focusVarName.len > 0:
      focusedLine.add "\n" & indent(level) & ".onAppear { " & focusVarName & " = true }"
    return focusedLine

  # searchable modifier: .searchable(text: $binding, ...) — needs binding for text
  if modName == "searchable":
    var argsText: seq[string] = @[]
    for arg in modDecl.namedArgs:
      let key = swiftIdent(arg.name)
      if key == "text":
        argsText.add key & ": " & emitBindingExpr(ctx, arg.value)
      else:
        argsText.add key & ": " & emitExpr(ctx, arg.value, uiContext = true)
    for arg in modDecl.args:
      argsText.add emitExpr(ctx, arg, uiContext = true)
    if modDecl.children.len > 0:
      result = indent(level) & ".searchable(" & argsText.join(", ") & ")"
      result.add " {\n"
      for child in modDecl.children:
        result.add emitNode(ctx, child, level + 1, componentByName)
        result.add "\n"
      result.add indent(level) & "}"
      return result
    return indent(level) & ".searchable(" & argsText.join(", ") & ")"

  # padding with named edge args → EdgeInsets
  if modName == "padding" and modDecl.namedArgs.len > 0 and modDecl.args.len == 0:
    var top, leading, bottom, trailing: string
    top = "0"
    leading = "0"
    bottom = "0"
    trailing = "0"
    for arg in modDecl.namedArgs:
      let key = swiftIdent(arg.name)
      let val = emitExpr(ctx, arg.value, uiContext = true)
      case key
      of "top": top = val
      of "leading": leading = val
      of "bottom": bottom = val
      of "trailing": trailing = val
      of "horizontal":
        leading = val
        trailing = val
      of "vertical":
        top = val
        bottom = val
      of "all":
        top = val
        leading = val
        bottom = val
        trailing = val
      else: discard
    return indent(level) & ".padding(EdgeInsets(top: " & top & ", leading: " & leading & ", bottom: " & bottom & ", trailing: " & trailing & "))"

  # Default modifier emission
  var argsText: seq[string] = @[]
  for arg in modDecl.args:
    argsText.add emitExpr(ctx, arg, uiContext = true)
  for arg in modDecl.namedArgs:
    argsText.add emitModifierNamedArgExpr(ctx, modDecl.name, arg)

  if modDecl.children.len == 0:
    return indent(level) & "." & modName & "(" & argsText.join(", ") & ")"

  let head =
    if argsText.len > 0:
      "." & modName & "(" & argsText.join(", ") & ")"
    else:
      "." & modName

  result = indent(level) & head & " {\n"
  for child in modDecl.children:
    result.add emitNode(ctx, child, level + 1, componentByName)
    result.add "\n"
  result.add indent(level) & "}"

proc appendRenderedModifiers(
  rendered: var string,
  ctx: EmitContext,
  level: int,
  modifiers: seq[GuiModifierDecl],
  postModifiers: seq[string],
  componentByName: Table[string, GuiComponentDecl]
) =
  for modDecl in modifiers:
    rendered.add "\n" & emitModifierCall(ctx, modDecl, level, componentByName)

  for modText in postModifiers:
    rendered.add "\n" & indent(level) & modText

proc emitConditionalNode(
  ctx: EmitContext,
  node: GuiUiNode,
  level: int,
  componentByName: Table[string, GuiComponentDecl]
): string =
  # Handle if-let binding: if let name = expr { ... } or chained: if let a = x, let b = y { ... }
  if node.isIfLet:
    if node.ifLetClauses.len > 1:
      # Chained if-let: if let a = x, let b = y, condition { ... }
      var parts: seq[string] = @[]
      for clause in node.ifLetClauses:
        if clause.isBinding:
          parts.add "let " & swiftIdent(clause.bindName) & " = " & emitExpr(ctx, clause.bindExpr, uiContext = true)
        else:
          parts.add emitExpr(ctx, clause.bindExpr, uiContext = true)
      result = indent(level) & "if " & parts.join(", ") & " {\n"
    else:
      let letName = swiftIdent(node.letName)
      let letExprStr = emitExpr(ctx, node.letExpr, uiContext = true)
      result = indent(level) & "if let " & letName & " = " & letExprStr & " {\n"
    for child in node.children:
      result.add emitNode(ctx, child, level + 1, componentByName)
      result.add "\n"
    result.add indent(level) & "}"
  else:
    # Emit: if condition { children } else if condition { children } else { children }
    result = indent(level) & "if " & emitExpr(ctx, node.condition, uiContext = true) & " {\n"
    for child in node.children:
      result.add emitNode(ctx, child, level + 1, componentByName)
      result.add "\n"
    result.add indent(level) & "}"

  for elifNode in node.elseIfBranches:
    if elifNode.isIfLet:
      if elifNode.ifLetClauses.len > 1:
        var parts: seq[string] = @[]
        for clause in elifNode.ifLetClauses:
          if clause.isBinding:
            parts.add "let " & swiftIdent(clause.bindName) & " = " & emitExpr(ctx, clause.bindExpr, uiContext = true)
          else:
            parts.add emitExpr(ctx, clause.bindExpr, uiContext = true)
        result.add " else if " & parts.join(", ") & " {\n"
      else:
        let letName = swiftIdent(elifNode.letName)
        let letExprStr = emitExpr(ctx, elifNode.letExpr, uiContext = true)
        result.add " else if let " & letName & " = " & letExprStr & " {\n"
    else:
      result.add " else if " & emitExpr(ctx, elifNode.condition, uiContext = true) & " {\n"
    for child in elifNode.children:
      result.add emitNode(ctx, child, level + 1, componentByName)
      result.add "\n"
    result.add indent(level) & "}"

  if node.elseChildren.len > 0:
    result.add " else {\n"
    for child in node.elseChildren:
      result.add emitNode(ctx, child, level + 1, componentByName)
      result.add "\n"
    result.add indent(level) & "}"

proc emitNode(
  ctx: EmitContext,
  node: GuiUiNode,
  level: int,
  componentByName: Table[string, GuiComponentDecl]
): string =
  if node.isNil:
    return indent(level) & "EmptyView()"

  # Handle platform conditionals (#if os(iOS) { } #else { })
  if node.isPlatformConditional:
    result = indent(level) & "#if " & node.platformCondition & "\n"
    for child in node.children:
      result.add emitNode(ctx, child, level, componentByName)
      result.add "\n"
    if node.platformElseChildren.len > 0:
      result.add indent(level) & "#else\n"
      for child in node.platformElseChildren:
        result.add emitNode(ctx, child, level, componentByName)
        result.add "\n"
    result.add indent(level) & "#endif"
    return

  # Handle conditional nodes (if/else if/else)
  if node.isConditional:
    return emitConditionalNode(ctx, node, level, componentByName)

  # Handle switch/case pattern matching
  if node.isSwitch:
    let switchExprStr = emitExpr(ctx, node.switchExpr, uiContext = true)
    result = indent(level) & "switch " & switchExprStr & " {\n"
    for c in node.cases:
      if c.isDefault:
        result.add indent(level) & "default:\n"
      else:
        var patternStrs: seq[string] = @[]
        for pat in c.patterns:
          patternStrs.add emitExpr(ctx, pat, uiContext = true)
        result.add indent(level) & "case " & patternStrs.join(", ") & ":\n"
      for child in c.body:
        result.add emitNode(ctx, child, level + 1, componentByName)
        result.add "\n"
    result.add indent(level) & "}"
    return result

  let nodeLeaf =
    if node.name.contains('.'):
      node.name.split('.')[^1]
    else:
      node.name

  var callHead = ""
  var constructorParts: seq[string] = @[]
  var postModifiers: seq[string] = @[]

  var named = node.namedArgs

  # Event shorthands on any node.
  var retainedNamed: seq[GuiNamedArg] = @[]
  for arg in named:
    if arg.name in ["onTap", "onPress"]:
      let sendExpr = emitActionSendExpr(ctx, arg.value)
      if sendExpr.len > 0:
        postModifiers.add ".onTapGesture { store.send(" & sendExpr & ") }"
      else:
        retainedNamed.add arg
    elif arg.name == "onDoubleTap":
      let sendExpr = emitActionSendExpr(ctx, arg.value)
      if sendExpr.len > 0:
        postModifiers.add ".onTapGesture(count: 2) { store.send(" & sendExpr & ") }"
      else:
        retainedNamed.add arg
    else:
      retainedNamed.add arg
  named = retainedNamed

  if nodeLeaf in componentByName:
    callHead = "Component_" & swiftIdent(nodeLeaf)
    constructorParts.add "store: store"
    let compDecl = componentByName[nodeLeaf]
    for arg in node.args:
      constructorParts.add emitExpr(ctx, arg, uiContext = true)
    for arg in named:
      # Check if this param is a @Binding param in the target component
      var isBindingParam = false
      for p in compDecl.params:
        if p.name == arg.name and p.isBinding:
          isBindingParam = true
          break
      if isBindingParam:
        constructorParts.add swiftIdent(arg.name) & ": " & emitBindingExpr(ctx, arg.value)
      else:
        constructorParts.add swiftIdent(arg.name) & ": " & emitExpr(ctx, arg.value, uiContext = true)
  elif nodeLeaf == "Button":
    let actionExpr =
      block:
        var found: GuiExpr = nil
        for arg in named:
          if arg.name in ["action", "onTap", "onPress"]:
            found = arg.value
            break
        found

    let sendExpr = emitActionSendExpr(ctx, actionExpr)
    let titleExpr = if node.args.len > 0: emitExpr(ctx, node.args[0], uiContext = true) else: "\"Action\""

    # Collect non-action named args (role, etc.) to pass through
    var extraNamedArgs: seq[string] = @[]
    for arg in named:
      if arg.name notin ["action", "onTap", "onPress"]:
        extraNamedArgs.add swiftIdent(arg.name) & ": " & emitExpr(ctx, arg.value, uiContext = true)

    if node.children.len == 0:
      var btnArgs = @[titleExpr]
      btnArgs.add extraNamedArgs
      var rendered =
        if sendExpr.len > 0:
          indent(level) & "Button(" & btnArgs.join(", ") & ") { store.send(" & sendExpr & ") }"
        else:
          indent(level) & "Button(" & btnArgs.join(", ") & ") { }"
      appendRenderedModifiers(rendered, ctx, level, node.modifiers, postModifiers, componentByName)
      return rendered
    else:
      var actionParts: seq[string] = @[]
      if sendExpr.len > 0:
        actionParts.add "action: { store.send(" & sendExpr & ") }"
      else:
        actionParts.add "action: { }"
      actionParts.add extraNamedArgs
      let header = "Button(" & actionParts.join(", ") & ")"
      var rendered = indent(level) & header & " {\n"
      for child in node.children:
        rendered.add emitNode(ctx, child, level + 1, componentByName)
        rendered.add "\n"
      rendered.add indent(level) & "}"
      appendRenderedModifiers(rendered, ctx, level, node.modifiers, postModifiers, componentByName)
      return rendered
  elif nodeLeaf == "NavigationLink":
    # NavigationLink with value-based navigation or label closure
    var valueExpr = ""
    var destinationNode: GuiUiNode = nil
    for arg in named:
      if arg.name == "value":
        valueExpr = emitExpr(ctx, arg.value, uiContext = true)
      elif arg.name == "destination":
        # Destination as named arg (inline component ref)
        discard

    if node.children.len > 0 and valueExpr.len > 0:
      # NavigationLink(value: expr) { label }
      let titleExpr = if node.args.len > 0: emitExpr(ctx, node.args[0], uiContext = true) else: ""
      var rendered: string
      if titleExpr.len > 0:
        rendered = indent(level) & "NavigationLink(" & titleExpr & ", value: " & valueExpr & ")"
      else:
        rendered = indent(level) & "NavigationLink(value: " & valueExpr & ") {\n"
        for child in node.children:
          rendered.add emitNode(ctx, child, level + 1, componentByName)
          rendered.add "\n"
        rendered.add indent(level) & "}"
      appendRenderedModifiers(rendered, ctx, level, node.modifiers, postModifiers, componentByName)
      return rendered
    elif node.children.len > 0:
      # NavigationLink { destination } label: { label }
      # Or NavigationLink("title") { destination }
      let titleExpr = if node.args.len > 0: emitExpr(ctx, node.args[0], uiContext = true) else: ""
      if titleExpr.len > 0:
        var rendered = indent(level) & "NavigationLink(" & titleExpr & ") {\n"
        for child in node.children:
          rendered.add emitNode(ctx, child, level + 1, componentByName)
          rendered.add "\n"
        rendered.add indent(level) & "}"
        appendRenderedModifiers(rendered, ctx, level, node.modifiers, postModifiers, componentByName)
        return rendered
    # Fall through to generic handling
    callHead = "NavigationLink"
    for arg in node.args:
      constructorParts.add emitExpr(ctx, arg, uiContext = true)
    for arg in named:
      constructorParts.add swiftIdent(arg.name) & ": " & emitExpr(ctx, arg.value, uiContext = true)

  elif nodeLeaf == "GeometryReader":
    # GeometryReader { geo in ... }
    var geoName = "geo"
    for arg in named:
      if arg.name in ["proxy", "geo", "geometry"] and arg.value != nil and arg.value.kind == geIdent:
        geoName = swiftIdent(arg.value.ident)

    var localCtx = ctx
    localCtx.localNames.incl(geoName)

    var rendered = indent(level) & "GeometryReader { " & geoName & " in\n"
    for child in node.children:
      rendered.add emitNode(localCtx, child, level + 1, componentByName)
      rendered.add "\n"
    rendered.add indent(level) & "}"
    appendRenderedModifiers(rendered, ctx, level, node.modifiers, postModifiers, componentByName)
    return rendered

  elif nodeLeaf in ["List", "Section"]:
    # List and Section with optional header/footer
    callHead = nodeLeaf
    for arg in node.args:
      constructorParts.add emitExpr(ctx, arg, uiContext = true)
    let bindingKeys = if nodeLeaf == "List": @["selection"] else: @[]
    for arg in named:
      let key = swiftIdent(arg.name)
      if key in bindingKeys:
        constructorParts.add key & ": " & emitBindingExpr(ctx, arg.value)
      elif key == "header" or key == "footer":
        constructorParts.add key & ": " & emitExpr(ctx, arg.value, uiContext = true)
      else:
        constructorParts.add key & ": " & emitExpr(ctx, arg.value, uiContext = true)

  elif nodeLeaf == "ForEach":
    var itemsExpr: GuiExpr = nil
    var itemName = "item"
    var indexName = "index"
    var idKeyPath = ""
    var hasIndex = false
    var hasItems = false
    var hasId = false

    if node.args.len > 0:
      itemsExpr = node.args[0]
      hasItems = true

    for arg in named:
      case arg.name
      of "items":
        itemsExpr = arg.value
        hasItems = true
      of "item":
        if arg.value != nil and arg.value.kind == geIdent:
          itemName = swiftIdent(arg.value.ident)
      of "index":
        if arg.value != nil and arg.value.kind == geIdent:
          indexName = swiftIdent(arg.value.ident)
          hasIndex = true
      of "id":
        if arg.value != nil:
          if arg.value.kind == geIdent:
            idKeyPath = "\\." & swiftIdent(arg.value.ident)
          elif arg.value.kind == geStringLit:
            idKeyPath = "\\." & arg.value.strVal
          else:
            idKeyPath = "\\.self"
          hasId = true
      else:
        discard

    let itemsText =
      if hasItems and itemsExpr != nil:
        emitExpr(ctx, itemsExpr, uiContext = true)
      else:
        "[]"

    var localCtx = ctx
    localCtx.localNames.incl(itemName)

    if hasId:
      # Identifiable/keyed iteration: ForEach(items, id: \.key) { item in ... }
      var rendered = indent(level) & "ForEach(" & itemsText & ", id: " & idKeyPath & ") { " & itemName & " in\n"
      for child in node.children:
        rendered.add emitNode(localCtx, child, level + 1, componentByName)
        rendered.add "\n"
      rendered.add indent(level) & "}"
      appendRenderedModifiers(rendered, localCtx, level, node.modifiers, postModifiers, componentByName)
      return rendered
    else:
      # Index-based iteration (fallback)
      let indexVar =
        if hasIndex:
          indexName
        else:
          "__idx_" & $level
      localCtx.localNames.incl(indexVar)

      var rendered = indent(level) & "ForEach(Array(" & itemsText & ".indices), id: \\.self) { " & indexVar & " in\n"
      rendered.add indent(level + 1) & "let " & itemName & " = " & itemsText & "[" & indexVar & "]"

      for child in node.children:
        rendered.add "\n"
        rendered.add emitNode(localCtx, child, level + 1, componentByName)
      rendered.add "\n" & indent(level) & "}"
      appendRenderedModifiers(rendered, localCtx, level, node.modifiers, postModifiers, componentByName)
      return rendered
  elif nodeLeaf == "NavigationSplitView":
    callHead = nodeLeaf
    for arg in node.args:
      constructorParts.add emitExpr(ctx, arg, uiContext = true)
    for arg in named:
      constructorParts.add swiftIdent(arg.name) & ": " & emitExpr(ctx, arg.value, uiContext = true)

    if node.children.len in [2, 3]:
      let splitHead =
        if constructorParts.len > 0:
          callHead & "(" & constructorParts.join(", ") & ")"
        else:
          callHead

      var rendered = indent(level) & splitHead & " {\n"
      rendered.add emitNode(ctx, node.children[0], level + 1, componentByName)
      rendered.add "\n"

      if node.children.len == 2:
        rendered.add indent(level) & "} detail: {\n"
        rendered.add emitNode(ctx, node.children[1], level + 1, componentByName)
      else:
        rendered.add indent(level) & "} content: {\n"
        rendered.add emitNode(ctx, node.children[1], level + 1, componentByName)
        rendered.add "\n" & indent(level) & "} detail: {\n"
        rendered.add emitNode(ctx, node.children[2], level + 1, componentByName)

      rendered.add "\n" & indent(level) & "}"
      appendRenderedModifiers(rendered, ctx, level, node.modifiers, postModifiers, componentByName)
      return rendered
  elif nodeLeaf in ["TextField", "SecureField", "Toggle", "Picker",
                     "Slider", "Stepper", "DatePicker", "ColorPicker", "TextEditor"]:
    callHead = nodeLeaf
    for arg in node.args:
      constructorParts.add emitExpr(ctx, arg, uiContext = true)
    # Named args with binding detection per view type
    let bindingKeys =
      case nodeLeaf
      of "TextField", "SecureField", "TextEditor":
        @["text"]
      of "Toggle":
        @["isOn"]
      of "Picker", "DatePicker", "ColorPicker":
        @["selection"]
      of "Slider", "Stepper":
        @["value"]
      else:
        @[]
    for arg in named:
      let key = swiftIdent(arg.name)
      if key in bindingKeys:
        constructorParts.add key & ": " & emitBindingExpr(ctx, arg.value)
      else:
        constructorParts.add key & ": " & emitExpr(ctx, arg.value, uiContext = true)
  elif nodeLeaf == "ContentUnavailableView":
    callHead = nodeLeaf
    for arg in node.args:
      constructorParts.add emitExpr(ctx, arg, uiContext = true)
    for arg in named:
      let key = swiftIdent(arg.name)
      if key == "description":
        # SwiftUI requires Text(...) for the description parameter
        constructorParts.add key & ": Text(" & emitExpr(ctx, arg.value, uiContext = true) & ")"
      else:
        constructorParts.add key & ": " & emitExpr(ctx, arg.value, uiContext = true)

  elif nodeLeaf == "LabeledContent":
    # LabeledContent("Label") { content } or LabeledContent("Label", value: expr)
    callHead = nodeLeaf
    for arg in node.args:
      constructorParts.add emitExpr(ctx, arg, uiContext = true)
    for arg in named:
      let key = swiftIdent(arg.name)
      if key == "value":
        constructorParts.add key & ": " & emitExpr(ctx, arg.value, uiContext = true)
      elif key == "format":
        constructorParts.add key & ": " & emitExpr(ctx, arg.value, uiContext = true)
      else:
        constructorParts.add key & ": " & emitExpr(ctx, arg.value, uiContext = true)

  elif nodeLeaf == "Table":
    # Table with selection binding: Table(items, selection: $selection) { columns }
    callHead = nodeLeaf
    for arg in node.args:
      constructorParts.add emitExpr(ctx, arg, uiContext = true)
    for arg in named:
      let key = swiftIdent(arg.name)
      if key in ["selection", "sortOrder"]:
        constructorParts.add key & ": " & emitBindingExpr(ctx, arg.value)
      else:
        constructorParts.add key & ": " & emitExpr(ctx, arg.value, uiContext = true)

  elif nodeLeaf == "TableColumn":
    # TableColumn("Header", value: \.keyPath) or TableColumn("Header") { row in ... }
    callHead = nodeLeaf
    for arg in node.args:
      constructorParts.add emitExpr(ctx, arg, uiContext = true)
    for arg in named:
      let key = swiftIdent(arg.name)
      if key == "value":
        # Key path support: value: \.fieldName → value: \.fieldName
        constructorParts.add key & ": " & emitExpr(ctx, arg.value, uiContext = true)
      elif key == "sortUsing":
        constructorParts.add key & ": " & emitExpr(ctx, arg.value, uiContext = true)
      else:
        constructorParts.add key & ": " & emitExpr(ctx, arg.value, uiContext = true)

  elif nodeLeaf == "ProgressView":
    # ProgressView(value: binding, total: expr, label: ...)
    callHead = nodeLeaf
    for arg in node.args:
      constructorParts.add emitExpr(ctx, arg, uiContext = true)
    for arg in named:
      let key = swiftIdent(arg.name)
      if key == "value":
        constructorParts.add key & ": " & emitBindingExpr(ctx, arg.value)
      else:
        constructorParts.add key & ": " & emitExpr(ctx, arg.value, uiContext = true)

  else:
    callHead = nodeLeaf
    for arg in node.args:
      constructorParts.add emitExpr(ctx, arg, uiContext = true)
    for arg in named:
      constructorParts.add swiftIdent(arg.name) & ": " & emitExpr(ctx, arg.value, uiContext = true)

  let callText =
    if constructorParts.len > 0:
      callHead & "(" & constructorParts.join(", ") & ")"
    elif node.children.len > 0:
      callHead  # No empty parens when we have a trailing closure
    else:
      callHead & "()"

  var rendered = ""
  if node.children.len > 0:
    rendered = indent(level) & callText & " {\n"
    for child in node.children:
      rendered.add emitNode(ctx, child, level + 1, componentByName)
      rendered.add "\n"
    rendered.add indent(level) & "}"
  else:
    rendered = indent(level) & callText

  appendRenderedModifiers(rendered, ctx, level, node.modifiers, postModifiers, componentByName)

  rendered

proc defaultValueForType(typ: string): string =
  let t = typ.strip()
  if t.endsWith("?"):
    return "nil"
  if t.endsWith("[]"):
    return "[]"
  case t
  of "Int":
    "0"
  of "Double", "CGFloat":
    "0.0"
  of "String":
    "\"\""
  of "Bool":
    "false"
  of "Color":
    "Color.clear"
  of "Date":
    "Date()"
  else:
    swiftTypeName(t) & "()"

proc swiftActionOwnerCase(owner: GuiActionOwner): string =
  case owner
  of gaoNim:
    ".nim"
  of gaoBoth:
    ".both"
  of gaoSwift:
    ".swift"

proc emitReducer(
  ir: GuiIrProgram,
  ctx: EmitContext,
  stateNames: HashSet[string],
  outLines: var seq[string]
) =
  outLines.add "@MainActor"
  outLines.add "func guiReduce(state: inout GUIState, action: GUIAction) -> [GUIEffectCommand] {"
  outLines.add "  var effects: [GUIEffectCommand] = []"
  outLines.add ""
  outLines.add "  switch action {"

  var actionByName: Table[string, GuiActionDecl]
  for action in ir.actions:
    actionByName[action.name] = action

  for reducerCase in ir.reducerCases:
    if reducerCase.actionName notin ctx.actionCaseByName:
      continue

    let caseName = ctx.actionCaseByName[reducerCase.actionName]
    let actionDecl = actionByName.getOrDefault(reducerCase.actionName)
    if actionDecl.owner == gaoNim:
      continue

    var localCtx = ctx
    localCtx.localNames.clear()

    if actionDecl.params.len == 0:
      outLines.add "  case ." & caseName & ":"
    else:
      var bindNames = reducerCase.bindNames
      if bindNames.len == 0:
        for param in actionDecl.params:
          bindNames.add param.name
      var bindSwift: seq[string] = @[]
      for _, bindName in bindNames:
        let b = swiftIdent(bindName)
        bindSwift.add b
        localCtx.localNames.incl b
      outLines.add "  case let ." & caseName & "(" & bindSwift.join(", ") & "):"

    for stmt in reducerCase.statements:
      case stmt.kind
      of grsSet:
        let assignment = "state." & swiftIdent(stmt.fieldName) & " = " & emitExpr(localCtx, stmt.valueExpr, uiContext = false)
        if stmt.animationExpr != nil:
          let animExpr = emitExpr(localCtx, stmt.animationExpr, uiContext = false)
          outLines.add "    withAnimation(" & animExpr & ") { " & assignment & " }"
        else:
          outLines.add "    " & assignment
      of grsEmit:
        var argParts: seq[string] = @[]
        for arg in stmt.commandArgs:
          argParts.add "\"" & escapeSwiftString(arg.name) & "\": " & emitAnyValueExpr(localCtx, arg.value)
        outLines.add "    effects.append(GUIEffectCommand(name: \"" & escapeSwiftString(stmt.commandName) & "\", args: [" & argParts.join(", ") & "]))"

    if reducerCase.statements.len == 0:
      outLines.add "    break"

  outLines.add "  default:"
  outLines.add "    break"
  outLines.add "  }"
  outLines.add ""
  outLines.add "  return effects"
  outLines.add "}"

proc defaultRootComponentName(ir: GuiIrProgram): string =
  for component in ir.components:
    if component.params.len == 0:
      return component.name
  if ir.components.len > 0:
    return ir.components[0].name
  ""

proc formatSwiftDouble(value: float64): string =
  let whole = value.int64.float64
  if whole == value:
    return $value.int64 & ".0"
  $value

proc bridgeWireKind(typ: string): string =
  let t = typ.strip()
  if t == "Int":
    return "int64"
  if t in ["Double", "Float", "CGFloat"]:
    return "double"
  if t == "Bool":
    return "bool"
  if t == "String":
    return "string"
  "json"

proc isBridgeRequestCandidate(name: string): bool =
  let n = swiftIdent(name)
  n in [
    "selectedTorrentId", "detailTab", "showAddTorrent", "addMagnetLink", "addTorrentPath",
    "showSettings", "downloadDir", "listenPort", "maxDownloadRate", "maxUploadRate",
    "maxPeers", "dhtEnabled", "pexEnabled", "lsdEnabled", "utpEnabled", "webSeedEnabled",
    "trackerScrapeEnabled", "holepunchEnabled", "encryptionMode", "actionPriority",
    "showRemoveConfirm", "removeDeleteFiles", "actionTorrentId", "pollActive"
  ]

proc emitBridgeStateHelpers(ir: GuiIrProgram, outLines: var seq[string]) =
  var storageFields: seq[GuiFieldDecl]
  for field in ir.stateFields:
    if not field.isComputed:
      storageFields.add field

  var pollTag = -1
  for i, action in ir.actions:
    if action.name.toLowerAscii == "poll":
      pollTag = i
      break

  outLines.add "let guiBridgePollActionTag: UInt32? = " &
    (if pollTag >= 0: "UInt32(" & $pollTag & ")" else: "nil")
  outLines.add "let guiBridgeValueTypeBool: UInt8 = 1"
  outLines.add "let guiBridgeValueTypeInt64: UInt8 = 2"
  outLines.add "let guiBridgeValueTypeDouble: UInt8 = 3"
  outLines.add "let guiBridgeValueTypeString: UInt8 = 4"
  outLines.add "let guiBridgeValueTypeJSON: UInt8 = 5"
  outLines.add ""
  outLines.add "struct GUIBridgeFieldValue {"
  outLines.add "  var fieldId: UInt16"
  outLines.add "  var valueType: UInt8"
  outLines.add "  var payload: Data"
  outLines.add "}"
  outLines.add ""
  outLines.add "private func guiBridgeEncodeInt64(_ value: Int64) -> Data {"
  outLines.add "  var le = value.littleEndian"
  outLines.add "  return withUnsafeBytes(of: &le) { Data($0) }"
  outLines.add "}"
  outLines.add ""
  outLines.add "private func guiBridgeDecodeInt64(_ payload: Data) -> Int64? {"
  outLines.add "  guard payload.count == 8 else { return nil }"
  outLines.add "  var value: Int64 = 0"
  outLines.add "  _ = withUnsafeMutableBytes(of: &value) { payload.copyBytes(to: $0) }"
  outLines.add "  return Int64(littleEndian: value)"
  outLines.add "}"
  outLines.add ""
  outLines.add "private func guiBridgeEncodeDouble(_ value: Double) -> Data {"
  outLines.add "  var bits = value.bitPattern.littleEndian"
  outLines.add "  return withUnsafeBytes(of: &bits) { Data($0) }"
  outLines.add "}"
  outLines.add ""
  outLines.add "private func guiBridgeDecodeDouble(_ payload: Data) -> Double? {"
  outLines.add "  guard payload.count == 8 else { return nil }"
  outLines.add "  var bits: UInt64 = 0"
  outLines.add "  _ = withUnsafeMutableBytes(of: &bits) { payload.copyBytes(to: $0) }"
  outLines.add "  return Double(bitPattern: UInt64(littleEndian: bits))"
  outLines.add "}"
  outLines.add ""
  outLines.add "private func guiBridgeDecodeBool(_ payload: Data) -> Bool? {"
  outLines.add "  guard payload.count == 1 else { return nil }"
  outLines.add "  return payload[0] != 0"
  outLines.add "}"
  outLines.add ""
  outLines.add "private func guiBridgeEncodeString(_ value: String) -> Data {"
  outLines.add "  value.data(using: .utf8) ?? Data()"
  outLines.add "}"
  outLines.add ""
  outLines.add "private func guiBridgeDecodeString(_ payload: Data) -> String? {"
  outLines.add "  String(data: payload, encoding: .utf8)"
  outLines.add "}"
  outLines.add ""
  outLines.add "func guiBridgeEncodeRequestFields(actionTag: UInt32, state: GUIState?) -> [GUIBridgeFieldValue] {"
  outLines.add "  guard let state else { return [] }"
  outLines.add "  if let pollTag = guiBridgePollActionTag, actionTag == pollTag {"
  outLines.add "    return []"
  outLines.add "  }"
  outLines.add "  var out: [GUIBridgeFieldValue] = []"

  for i, field in storageFields:
    if not isBridgeRequestCandidate(field.name):
      continue
    let fName = swiftIdent(field.name)
    let kind = bridgeWireKind(field.typ)
    let fieldId = i + 1
    case kind
    of "bool":
      outLines.add "  out.append(GUIBridgeFieldValue(fieldId: " & $fieldId &
        ", valueType: guiBridgeValueTypeBool, payload: Data([state." & fName & " ? 1 : 0])))"
    of "int64":
      outLines.add "  out.append(GUIBridgeFieldValue(fieldId: " & $fieldId &
        ", valueType: guiBridgeValueTypeInt64, payload: guiBridgeEncodeInt64(Int64(state." & fName & "))))"
    of "double":
      outLines.add "  out.append(GUIBridgeFieldValue(fieldId: " & $fieldId &
        ", valueType: guiBridgeValueTypeDouble, payload: guiBridgeEncodeDouble(Double(state." & fName & "))))"
    of "string":
      outLines.add "  out.append(GUIBridgeFieldValue(fieldId: " & $fieldId &
        ", valueType: guiBridgeValueTypeString, payload: guiBridgeEncodeString(state." & fName & ")))"
    else:
      discard

  outLines.add "  return out"
  outLines.add "}"
  outLines.add ""
  outLines.add "func guiBridgeApplyPatchField(state: inout GUIState, fieldId: UInt16, valueType: UInt8, payload: Data) -> Bool {"
  outLines.add "  switch fieldId {"

  for i, field in storageFields:
    let fName = swiftIdent(field.name)
    let fType = swiftTypeName(field.typ)
    let kind = bridgeWireKind(field.typ)
    let fieldId = i + 1
    outLines.add "  case " & $fieldId & ":"
    case kind
    of "bool":
      outLines.add "    if valueType == guiBridgeValueTypeBool, let decoded = guiBridgeDecodeBool(payload) {"
      outLines.add "      state." & fName & " = decoded"
      outLines.add "      return true"
      outLines.add "    }"
      outLines.add "    if valueType == guiBridgeValueTypeJSON, let decoded = try? JSONDecoder().decode(Bool.self, from: payload) {"
      outLines.add "      state." & fName & " = decoded"
      outLines.add "      return true"
      outLines.add "    }"
      outLines.add "    return false"
    of "int64":
      outLines.add "    if valueType == guiBridgeValueTypeInt64, let decoded = guiBridgeDecodeInt64(payload) {"
      outLines.add "      state." & fName & " = Int(decoded)"
      outLines.add "      return true"
      outLines.add "    }"
      outLines.add "    if valueType == guiBridgeValueTypeJSON, let decoded = try? JSONDecoder().decode(Int.self, from: payload) {"
      outLines.add "      state." & fName & " = decoded"
      outLines.add "      return true"
      outLines.add "    }"
      outLines.add "    return false"
    of "double":
      outLines.add "    if valueType == guiBridgeValueTypeDouble, let decoded = guiBridgeDecodeDouble(payload) {"
      outLines.add "      state." & fName & " = Double(decoded)"
      outLines.add "      return true"
      outLines.add "    }"
      outLines.add "    if valueType == guiBridgeValueTypeInt64, let decoded = guiBridgeDecodeInt64(payload) {"
      outLines.add "      state." & fName & " = Double(decoded)"
      outLines.add "      return true"
      outLines.add "    }"
      outLines.add "    if valueType == guiBridgeValueTypeJSON, let decoded = try? JSONDecoder().decode(Double.self, from: payload) {"
      outLines.add "      state." & fName & " = decoded"
      outLines.add "      return true"
      outLines.add "    }"
      outLines.add "    return false"
    of "string":
      outLines.add "    if valueType == guiBridgeValueTypeString, let decoded = guiBridgeDecodeString(payload) {"
      outLines.add "      state." & fName & " = decoded"
      outLines.add "      return true"
      outLines.add "    }"
      outLines.add "    if valueType == guiBridgeValueTypeJSON, let decoded = try? JSONDecoder().decode(String.self, from: payload) {"
      outLines.add "      state." & fName & " = decoded"
      outLines.add "      return true"
      outLines.add "    }"
      outLines.add "    return false"
    else:
      outLines.add "    if valueType == guiBridgeValueTypeJSON, let decoded = try? JSONDecoder().decode(" & fType & ".self, from: payload) {"
      outLines.add "      state." & fName & " = decoded"
      outLines.add "      return true"
      outLines.add "    }"
      outLines.add "    if valueType == guiBridgeValueTypeString, let text = guiBridgeDecodeString(payload), let jsonData = text.data(using: .utf8), let decoded = try? JSONDecoder().decode(" & fType & ".self, from: jsonData) {"
      outLines.add "      state." & fName & " = decoded"
      outLines.add "      return true"
      outLines.add "    }"
      outLines.add "    return false"

  outLines.add "  default:"
  outLines.add "    return false"
  outLines.add "  }"
  outLines.add "}"
  outLines.add ""

proc emitGeneratedSwift(ir: GuiIrProgram, appName: string): string =
  var outLines: seq[string] = @[]
  let windowDecl = ir.window
  let hasWindowTitle = windowDecl.hasTitle
  let hasWindowDefaultSize = windowDecl.hasWidth and windowDecl.hasHeight
  let hasWindowConstraints = windowDecl.hasMinWidth or windowDecl.hasMinHeight or windowDecl.hasMaxWidth or windowDecl.hasMaxHeight
  let shouldCloseOnLastWindow = windowDecl.hasClosePolicy and windowDecl.closeAppOnLastWindowClose
  let hasTitleBarPreference = windowDecl.hasShowTitleBar
  let showTitleBar = if hasTitleBarPreference: windowDecl.showTitleBar else: true
  let hasShortcutMonitor = windowDecl.hasSuppressDefaultMenus and windowDecl.suppressDefaultMenus
  let needsAppKit = hasWindowTitle or hasWindowDefaultSize or hasWindowConstraints or shouldCloseOnLastWindow or hasTitleBarPreference or hasShortcutMonitor

  outLines.add "import Foundation"
  outLines.add "import SwiftUI"
  if needsAppKit:
    outLines.add "#if os(macOS)"
    outLines.add "import AppKit"
    outLines.add "#endif"
  outLines.add ""

  # Emit user-defined enums
  for enumDecl in ir.enums:
    var conformances: seq[string] = @[]
    if enumDecl.rawType.len > 0:
      conformances.add swiftTypeName(enumDecl.rawType)
    for proto in enumDecl.protocols:
      conformances.add proto
    # Add default conformances if not explicitly provided
    if "CaseIterable" notin conformances:
      conformances.add "CaseIterable"
    if "Codable" notin conformances:
      conformances.add "Codable"
    if "Equatable" notin conformances:
      conformances.add "Equatable"
    if "Hashable" notin conformances:
      conformances.add "Hashable"
    # If no raw type specified, default to String
    if enumDecl.rawType.len == 0 and "String" notin conformances:
      conformances.insert("String", 0)
    let confStr = conformances.join(", ")
    outLines.add "enum " & swiftIdent(enumDecl.name) & ": " & confStr & " {"
    for caseDecl in enumDecl.cases:
      let caseName = lowerCamel(caseDecl.name)
      if caseDecl.params.len > 0:
        var params: seq[string] = @[]
        for param in caseDecl.params:
          params.add swiftIdent(param.name) & ": " & swiftTypeName(param.typ)
        outLines.add "  case " & caseName & "(" & params.join(", ") & ")"
      elif caseDecl.rawValue != nil:
        let rawVal = emitExpr(EmitContext(), caseDecl.rawValue, uiContext = false)
        outLines.add "  case " & caseName & " = " & rawVal
      else:
        outLines.add "  case " & caseName
    outLines.add "}"
    outLines.add ""

  for model in ir.models:
    let hasPublished = model.fields.anyIt(it.isPublished)
    let isObservable = "Observable" in model.protocols
    var conformances: seq[string] = model.protocols
    if isObservable:
      # @Observable class pattern (iOS 17+) — remove "Observable" from conformances
      conformances = conformances.filterIt(it != "Observable")
      let confStr = if conformances.len > 0: ": " & conformances.join(", ") else: ""
      outLines.add "@Observable"
      outLines.add "class " & swiftIdent(model.name) & confStr & " {"
    elif hasPublished:
      # Models with @Published fields conform to ObservableObject (class, not struct)
      if "ObservableObject" notin conformances:
        conformances.insert("ObservableObject", 0)
      let confStr = if conformances.len > 0: ": " & conformances.join(", ") else: ""
      outLines.add "class " & swiftIdent(model.name) & confStr & " {"
    else:
      if conformances.len == 0:
        conformances.add "Codable"
      let confStr = conformances.join(", ")
      outLines.add "struct " & swiftIdent(model.name) & ": " & confStr & " {"
    for field in model.fields:
      let fName = swiftIdent(field.name)
      let fType = swiftTypeName(field.typ)
      if field.isPublished:
        if field.defaultValue != nil and field.defaultValue.kind != geNullLit:
          let defVal = emitExpr(EmitContext(), field.defaultValue, uiContext = false)
          outLines.add "  @Published var " & fName & ": " & fType & " = " & defVal
        else:
          outLines.add "  @Published var " & fName & ": " & fType & " = " & defaultValueForType(field.typ)
      else:
        if field.defaultValue != nil and field.defaultValue.kind != geNullLit:
          let defVal = emitExpr(EmitContext(), field.defaultValue, uiContext = false)
          outLines.add "  var " & fName & ": " & fType & " = " & defVal
        else:
          # Always emit default values so ModelType() works in #Preview
          outLines.add "  var " & fName & ": " & fType & " = " & defaultValueForType(field.typ)
    outLines.add "}"
    outLines.add ""

  outLines.add "struct GUIState: Codable {"

  var hasComputed = false
  # Use empty context for computed properties — they live inside GUIState, no state. prefix needed
  var stateCtx = EmitContext()

  for field in ir.stateFields:
    let fName = swiftIdent(field.name)
    let fType = swiftTypeName(field.typ)
    if field.isComputed:
      hasComputed = true
      let valueExpr = if field.defaultValue != nil and field.defaultValue.kind != geNullLit:
        emitExpr(stateCtx, field.defaultValue, uiContext = false)
      else:
        defaultValueForType(field.typ)
      outLines.add "  var " & fName & ": " & fType & " { " & valueExpr & " }"
    else:
      let defaultExpr = if field.defaultValue != nil and field.defaultValue.kind != geNullLit:
        emitExpr(EmitContext(), field.defaultValue, uiContext = false)
      else:
        defaultValueForType(field.typ)
      outLines.add "  var " & fName & ": " & fType & " = " & defaultExpr

  # Exclude computed properties from Codable
  if hasComputed:
    var codingKeys: seq[string] = @[]
    for field in ir.stateFields:
      if not field.isComputed:
        codingKeys.add "case " & swiftIdent(field.name)
    outLines.add "  enum CodingKeys: String, CodingKey {"
    for ck in codingKeys:
      outLines.add "    " & ck
    outLines.add "  }"

  outLines.add "}"
  outLines.add ""

  emitBridgeStateHelpers(ir, outLines)

  var ctx = EmitContext()
  for field in ir.stateFields:
    ctx.stateNames.incl swiftIdent(field.name)

  outLines.add "enum GUIAction: Equatable {"
  for action in ir.actions:
    let caseName = lowerCamel(action.name)
    ctx.actionCaseByName[action.name] = caseName

    if action.params.len == 0:
      outLines.add "  case " & caseName
    else:
      var params: seq[string] = @[]
      for param in action.params:
        params.add swiftIdent(param.name) & ": " & swiftTypeName(param.typ)
      outLines.add "  case " & caseName & "(" & params.join(", ") & ")"
  outLines.add "}"
  outLines.add ""

  outLines.add "enum GUIActionOwner {"
  outLines.add "  case swift"
  outLines.add "  case nim"
  outLines.add "  case both"
  outLines.add "}"
  outLines.add ""
  outLines.add "func guiActionOwner(_ action: GUIAction) -> GUIActionOwner {"
  outLines.add "  switch action {"
  for action in ir.actions:
    let caseName = ctx.actionCaseByName[action.name]
    outLines.add "  case ." & caseName & ": return " & swiftActionOwnerCase(action.owner)
  outLines.add "  }"
  outLines.add "}"
  outLines.add ""
  outLines.add "func guiActionTag(_ action: GUIAction) -> UInt32 {"
  outLines.add "  switch action {"
  for i, action in ir.actions:
    let caseName = ctx.actionCaseByName[action.name]
    outLines.add "  case ." & caseName & ": return " & $i
  outLines.add "  }"
  outLines.add "}"
  outLines.add ""
  outLines.add "func guiActionFromTag(_ tag: UInt32) -> GUIAction? {"
  outLines.add "  switch tag {"
  for i, action in ir.actions:
    let caseName = ctx.actionCaseByName[action.name]
    if action.params.len == 0:
      outLines.add "  case " & $i & ": return ." & caseName
    else:
      outLines.add "  case " & $i & ": return nil"
  outLines.add "  default: return nil"
  outLines.add "  }"
  outLines.add "}"
  outLines.add ""
  outLines.add "func guiActionOwnerText(_ owner: GUIActionOwner) -> String {"
  outLines.add "  switch owner {"
  outLines.add "  case .swift: return \"swift\""
  outLines.add "  case .nim: return \"nim\""
  outLines.add "  case .both: return \"both\""
  outLines.add "  }"
  outLines.add "}"
  outLines.add ""

  outLines.add "enum GUITokens {"
  for tokenDecl in ir.tokens:
    let key = tokenKey(tokenDecl)
    let name = swiftIdent(tokenDecl.group & "_" & tokenDecl.name)
    let tokenType = if key in ir.tokenTypeByKey: ir.tokenTypeByKey[key] else: "String"

    var valueExpr = emitExpr(ctx, tokenDecl.value, uiContext = false)
    if tokenType == "Color" and tokenDecl.value != nil and tokenDecl.value.kind == geStringLit:
      valueExpr = "guiColor(\"" & escapeSwiftString(tokenDecl.value.strVal) & "\")"
    elif tokenType == "Double" and tokenDecl.value != nil and tokenDecl.value.kind == geIntLit:
      valueExpr = $tokenDecl.value.intVal & ".0"

    outLines.add "  static let " & name & ": " & swiftTypeName(tokenType) & " = " & valueExpr
  outLines.add "}"
  outLines.add ""

  emitReducer(ir, ctx, ctx.stateNames, outLines)
  outLines.add ""

  outLines.add "@MainActor"
  outLines.add "final class GUIStore: ObservableObject {"
  outLines.add "  @Published var state: GUIState"
  outLines.add "  private lazy var runtime = GUIRuntime(store: self)"
  if windowDecl.hasSuppressDefaultMenus and windowDecl.suppressDefaultMenus:
    outLines.add "#if os(macOS)"
    outLines.add "  let shortcutMonitor = KeyboardShortcutMonitor()"
    outLines.add "#endif"
  outLines.add ""
  outLines.add "  init(initial: GUIState = GUIState()) {"
  outLines.add "    self.state = initial"
  outLines.add "  }"
  outLines.add ""
  outLines.add "  func send(_ action: GUIAction) {"
  outLines.add "    var next = state"
  outLines.add "    let owner = guiActionOwner(action)"
  outLines.add "    var effects: [GUIEffectCommand] = []"
  outLines.add "    if owner != .nim {"
  outLines.add "      effects.append(contentsOf: guiReduce(state: &next, action: action))"
  outLines.add "    }"
  outLines.add "    if owner != .swift {"
  outLines.add "      effects.append(GUIEffectCommand(name: \"bridge.dispatch\", args: ["
  outLines.add "        \"action\": .action(action),"
  outLines.add "        \"actionTag\": .int(Int(guiActionTag(action))),"
  outLines.add "        \"owner\": .string(guiActionOwnerText(owner))"
  outLines.add "      ]))"
  outLines.add "    }"
  outLines.add "    state = next"
  outLines.add "    runtime.enqueue(effects)"
  outLines.add "  }"
  outLines.add ""
  outLines.add "  func shutdown(completion: @escaping () -> Void) {"
  # If the app declares an AppShutdown action, dispatch it to the bridge
  # then wait for the Nim event loop to finish on a background thread.
  # This allows the bridge to send graceful disconnect messages (e.g., IRC QUIT)
  # before the process exits, without blocking the main thread.
  for i, action in ir.actions:
    if action.name == "AppShutdown":
      outLines.add "    runtime.dispatchShutdownAction(actionTag: " & $i & ", state: state)"
      outLines.add "    runtime.awaitShutdownComplete(timeoutMs: 3000, completion: completion)"
      outLines.add "    return"
      break
  outLines.add "    runtime.shutdown()"
  outLines.add "    completion()"
  outLines.add "  }"
  outLines.add "}"
  outLines.add ""

  # Custom ViewModifier declarations
  var componentByName: Table[string, GuiComponentDecl]
  for component in ir.components:
    componentByName[component.name] = component

  for vm in ir.viewModifiers:
    let structName = swiftIdent(vm.name) & "Modifier"
    outLines.add "struct " & structName & ": ViewModifier {"
    outLines.add "  func body(content: Content) -> some View {"
    outLines.add "    content"
    for modDecl in vm.modifiers:
      outLines.add emitModifierCall(ctx, modDecl, 3, componentByName)
    outLines.add "  }"
    outLines.add "}"
    outLines.add ""
    # Extension method for easy application
    let methodName = swiftIdent(vm.name)
    # Lowercase first character for the method name
    var lcName = methodName
    if lcName.len > 0:
      lcName[0] = lcName[0].toLowerAscii()
    outLines.add "extension View {"
    outLines.add "  func " & lcName & "() -> some View {"
    outLines.add "    self.modifier(" & structName & "())"
    outLines.add "  }"
    outLines.add "}"
    outLines.add ""

  for component in ir.components:
    # Build local context for this component
    var localCtx = ctx
    for ls in component.localState:
      localCtx.localNames.incl swiftIdent(ls.name)
    for eb in component.envBindings:
      localCtx.localNames.incl swiftIdent(eb.localName)
    for param in component.params:
      localCtx.localNames.incl swiftIdent(param.name)
    for lb in component.letBindings:
      localCtx.localNames.incl swiftIdent(lb.name)

    outLines.add "struct Component_" & swiftIdent(component.name) & ": View {"
    outLines.add "  @ObservedObject var store: GUIStore"

    # @Binding and regular params
    for param in component.params:
      if param.isBinding:
        outLines.add "  @Binding var " & swiftIdent(param.name) & ": " & swiftTypeName(param.typ)
      else:
        outLines.add "  var " & swiftIdent(param.name) & ": " & swiftTypeName(param.typ)

    # @State / @FocusState local variables
    for ls in component.localState:
      let fName = swiftIdent(ls.name)
      let fType = swiftTypeName(ls.typ)
      # @AppStorage and @SceneStorage have key arguments
      if ls.wrapper == gpwNamespace:
        outLines.add "  @Namespace private var " & fName
        continue
      if ls.wrapper in {gpwAppStorage, gpwSceneStorage}:
        let wrapperName = if ls.wrapper == gpwAppStorage: "@AppStorage" else: "@SceneStorage"
        let keyStr = "\"" & ls.storageKey & "\""
        if ls.defaultValue != nil and ls.defaultValue.kind != geNullLit:
          let defaultExpr = emitExpr(EmitContext(), ls.defaultValue, uiContext = false)
          outLines.add "  " & wrapperName & "(" & keyStr & ") var " & fName & ": " & fType & " = " & defaultExpr
        else:
          outLines.add "  " & wrapperName & "(" & keyStr & ") var " & fName & ": " & fType & " = " & defaultValueForType(ls.typ)
        continue
      let wrapper = case ls.wrapper
        of gpwState: "@State"
        of gpwFocusState: "@FocusState"
        of gpwGestureState: "@GestureState"
        of gpwStateObject: "@StateObject"
        of gpwObservedObject: "@ObservedObject"
        of gpwEnvironmentObject: "@EnvironmentObject"
        of gpwAccessibilityFocusState: "@AccessibilityFocusState"
        of gpwAppStorage, gpwSceneStorage: "@State"  # unreachable, handled above
        of gpwNamespace: "@Namespace"  # unreachable, handled above
      let isPrivate = ls.wrapper in {gpwState, gpwFocusState, gpwGestureState, gpwStateObject, gpwAccessibilityFocusState}
      let privMod = if isPrivate: " private" else: ""
      # @FocusState and @AccessibilityFocusState don't accept initializer values in Swift
      if ls.wrapper in {gpwFocusState, gpwAccessibilityFocusState}:
        outLines.add "  " & wrapper & privMod & " var " & fName & ": " & fType
      elif ls.defaultValue != nil and ls.defaultValue.kind != geNullLit:
        let defaultExpr = emitExpr(EmitContext(), ls.defaultValue, uiContext = false)
        outLines.add "  " & wrapper & privMod & " var " & fName & ": " & fType & " = " & defaultExpr
      else:
        if ls.wrapper in {gpwGestureState, gpwObservedObject, gpwEnvironmentObject}:
          # These wrappers typically have no default
          outLines.add "  " & wrapper & privMod & " var " & fName & ": " & fType
        else:
          outLines.add "  " & wrapper & privMod & " var " & fName & ": " & fType & " = " & defaultValueForType(ls.typ)

    # @Environment bindings
    for eb in component.envBindings:
      outLines.add "  @Environment(\\." & swiftIdent(eb.keyPath) & ") var " & swiftIdent(eb.localName)

    # Emit let bindings with explicit types as private computed properties
    # (reduces body complexity, avoids SwiftUI type-checker timeouts on large components)
    # Bindings without explicit types stay as inline lets inside body.
    var bodyLetBindings: seq[GuiLetBinding]
    for lb in component.letBindings:
      let name = swiftIdent(lb.name)
      let valueExpr = emitExpr(localCtx, lb.value, uiContext = true)
      if lb.typ.len > 0:
        outLines.add "  private var " & name & ": " & swiftTypeName(lb.typ) & " { " & valueExpr & " }"
      else:
        bodyLetBindings.add lb

    outLines.add ""

    # Check if body is complex enough to need splitting into section properties.
    # When a component has a single root container (ScrollView/VStack/etc) whose
    # children each produce many lines, we extract each child as a private
    # @ViewBuilder computed property to keep body simple for the type-checker.
    var didSplitBody = false
    if bodyLetBindings.len == 0 and component.body.len == 1:
      let rootNode = component.body[0]
      # Check if root is a container with multiple children
      if rootNode.children.len > 0:
        # Find the innermost single-child container chain (e.g., ScrollView > VStack)
        var innerNode = rootNode
        while innerNode.children.len == 1 and innerNode.children[0].children.len > 1:
          innerNode = innerNode.children[0]
        # If inner node has 2+ children and total output is large, split
        if innerNode.children.len >= 2:
          var totalLines = 0
          for child in innerNode.children:
            totalLines += emitNode(localCtx, child, 3, componentByName).countLines
          if totalLines > 60:
            # Emit each child as a section property
            for i, child in innerNode.children:
              let sectionName = "_section" & $i
              outLines.add "  @ViewBuilder private var " & sectionName & ": some View {"
              outLines.add emitNode(localCtx, child, 2, componentByName)
              outLines.add "  }"
              outLines.add ""
            # Emit body with section references replacing children
            outLines.add "  var body: some View {"
            # Rebuild container chain with section references
            proc emitContainerChain(node: GuiUiNode, inner: GuiUiNode, ctx: EmitContext, level: int, sectionCount: int, componentByName: Table[string, GuiComponentDecl], outLines: var seq[string]) =
              let nodeLeaf = node.name.split('.')[^1]
              var head = indent(level) & nodeLeaf & "("
              var parts: seq[string]
              for arg in node.args:
                parts.add emitExpr(ctx, arg, uiContext = true)
              for arg in node.namedArgs:
                parts.add swiftIdent(arg.name) & ": " & emitExpr(ctx, arg.value, uiContext = true)
              head.add parts.join(", ")
              head.add ") {"
              outLines.add head
              if node == inner:
                for i in 0 ..< sectionCount:
                  outLines.add indent(level + 1) & "_section" & $i
              else:
                emitContainerChain(node.children[0], inner, ctx, level + 1, sectionCount, componentByName, outLines)
              outLines.add indent(level) & "}"
              # Apply modifiers
              for m in node.modifiers:
                discard  # modifiers are part of emitNode output; we handle them below

            # Simpler approach: emit the root node but replace innerNode's children
            # We can't easily rewrite the tree, so generate by reconstructing manually
            var savedChildren = innerNode.children
            innerNode.children = @[]
            for i in 0 ..< savedChildren.len:
              let placeholder = GuiUiNode(name: "_section" & $i)
              innerNode.children.add placeholder
            # Override emitNode for placeholder nodes — this won't work directly.
            # Instead, just emit the structure manually.
            innerNode.children = savedChildren  # restore

            # Practical approach: emit the nesting manually
            # Find the chain of containers: root -> ... -> innerNode
            var chain: seq[GuiUiNode] = @[]
            var cur = rootNode
            chain.add cur
            while cur != innerNode:
              cur = cur.children[0]
              chain.add cur

            # Emit opening tags
            for depth, node in chain:
              let nodeLeaf = node.name.split('.')[^1]
              var head = indent(2 + depth) & nodeLeaf & "("
              var parts: seq[string]
              for arg in node.args:
                parts.add emitExpr(localCtx, arg, uiContext = true)
              for arg in node.namedArgs:
                parts.add swiftIdent(arg.name) & ": " & emitExpr(localCtx, arg.value, uiContext = true)
              head.add parts.join(", ")
              head.add ") {"
              outLines.add head

            # Emit section references
            let innerDepth = chain.len + 1
            for i in 0 ..< innerNode.children.len:
              outLines.add indent(innerDepth) & "_section" & $i

            # Emit closing tags and modifiers (reverse order)
            for depth in countdown(chain.len - 1, 0):
              let node = chain[depth]
              var closing = indent(2 + depth) & "}"
              for m in node.modifiers:
                closing.add "\n" & emitModifierCall(localCtx, m, 2 + depth, componentByName)
              outLines.add closing

            outLines.add "  }"
            outLines.add "}"
            didSplitBody = true

    if not didSplitBody:
      outLines.add "  var body: some View {"

      # Emit remaining let bindings (no explicit type) as inline lets
      for lb in bodyLetBindings:
        let name = swiftIdent(lb.name)
        let valueExpr = emitExpr(localCtx, lb.value, uiContext = true)
        outLines.add "    let " & name & " = " & valueExpr

      if component.body.len == 0:
        outLines.add "    EmptyView()"
      elif component.body.len == 1:
        outLines.add emitNode(localCtx, component.body[0], 2, componentByName)
      else:
        outLines.add "    Group {"
        for node in component.body:
          outLines.add emitNode(localCtx, node, 3, componentByName)
        outLines.add "    }"

      outLines.add "  }"
      outLines.add "}"
    outLines.add ""

    # Xcode #Preview block for this component
    outLines.add "#Preview {"
    var previewArgs = "store: GUIStore()"
    for param in component.params:
      let pName = swiftIdent(param.name)
      let pType = swiftTypeName(param.typ)
      if param.isBinding:
        previewArgs.add ", " & pName & ": .constant(" & defaultValueForType(param.typ) & ")"
      else:
        previewArgs.add ", " & pName & ": " & defaultValueForType(param.typ)
    outLines.add "  Component_" & swiftIdent(component.name) & "(" & previewArgs & ")"
    outLines.add "}"
    outLines.add ""

  outLines.add "struct GUIRootView: View {"
  outLines.add "  @ObservedObject var store: GUIStore"

  if ir.tabs.len > 0:
    for tabDecl in ir.tabs:
      outLines.add "  @State private var path_" & swiftIdent(tabDecl.id) & ": [String] = []"
  outLines.add ""
  outLines.add "  var body: some View {"

  if ir.tabs.len > 0:
    outLines.add "    TabView {"
    for tabDecl in ir.tabs:
      let rootName = if tabDecl.rootComponent.len > 0: "Component_" & swiftIdent(tabDecl.rootComponent) else: "EmptyView"
      outLines.add "      NavigationStack(path: $path_" & swiftIdent(tabDecl.id) & ") {"
      outLines.add "        " & rootName & "(store: store)"

      if tabDecl.stack.len > 0:
        for stackDecl in ir.stacks:
          if stackDecl.name == tabDecl.stack:
            outLines.add "        .navigationDestination(for: String.self) { route in"
            outLines.add "          switch route {"
            for route in stackDecl.routes:
              outLines.add "          case \"" & escapeSwiftString(route.id) & "\":"
              outLines.add "            Component_" & swiftIdent(route.component) & "(store: store)"
            outLines.add "          default:"
            outLines.add "            EmptyView()"
            outLines.add "          }"
            outLines.add "        }"
            break

      outLines.add "      }"
      outLines.add "      .tabItem {"
      outLines.add "        Text(\"" & escapeSwiftString(tabDecl.id) & "\")"
      outLines.add "      }"
    outLines.add "    }"
  else:
    if ir.components.len > 0:
      outLines.add "    Component_" & swiftIdent(defaultRootComponentName(ir)) & "(store: store)"
    else:
      outLines.add "    Text(\"GUI app has no components\")"

  outLines.add "  }"
  outLines.add "}"
  outLines.add ""

  if shouldCloseOnLastWindow:
    outLines.add "#if os(macOS)"
    outLines.add "@MainActor"
    outLines.add "final class GUILifecycleDelegate: NSObject, NSApplicationDelegate {"
    outLines.add "  static var onShutdown: ((@escaping () -> Void) -> Void)?"
    outLines.add ""
    outLines.add "  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {"
    outLines.add "    true"
    outLines.add "  }"
    outLines.add ""
    outLines.add "  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {"
    outLines.add "    guard let onShutdown = GUILifecycleDelegate.onShutdown else { return .terminateNow }"
    outLines.add "    onShutdown { sender.reply(toApplicationShouldTerminate: true) }"
    outLines.add "    return .terminateLater"
    outLines.add "  }"
    outLines.add "}"
    outLines.add "#endif"
    outLines.add ""

  outLines.add "@main"
  outLines.add "struct " & swiftIdent(appName) & ": App {"
  outLines.add "  @StateObject private var store = GUIStore()"
  if shouldCloseOnLastWindow:
    outLines.add "#if os(macOS)"
    outLines.add "  @NSApplicationDelegateAdaptor(GUILifecycleDelegate.self) private var guiLifecycleDelegate"
    outLines.add "#endif"
  outLines.add ""
  outLines.add "  var body: some Scene {"
  if hasWindowTitle:
    outLines.add "    WindowGroup(\"" & escapeSwiftString(windowDecl.title) & "\") {"
  else:
    outLines.add "    WindowGroup {"
  outLines.add "      GUIRootView(store: store)"
  if shouldCloseOnLastWindow or needsAppKit:
    outLines.add "        .onAppear {"
    if shouldCloseOnLastWindow:
      outLines.add "#if os(macOS)"
      outLines.add "          GUILifecycleDelegate.onShutdown = { completion in store.shutdown(completion: completion) }"
      outLines.add "#endif"
    if needsAppKit:
      outLines.add "#if os(macOS)"
      outLines.add "          if let window = NSApplication.shared.windows.first {"
      if hasWindowTitle:
        outLines.add "            window.title = \"" & escapeSwiftString(windowDecl.title) & "\""
      if hasWindowDefaultSize:
        outLines.add "            window.setContentSize(NSSize(width: " &
          formatSwiftDouble(windowDecl.width) & ", height: " &
          formatSwiftDouble(windowDecl.height) & "))"
      if windowDecl.hasMinWidth or windowDecl.hasMinHeight:
        let minW = if windowDecl.hasMinWidth: formatSwiftDouble(windowDecl.minWidth) else: "window.minSize.width"
        let minH = if windowDecl.hasMinHeight: formatSwiftDouble(windowDecl.minHeight) else: "window.minSize.height"
        outLines.add "            window.minSize = NSSize(width: " & minW & ", height: " & minH & ")"
      if windowDecl.hasMaxWidth or windowDecl.hasMaxHeight:
        let maxW = if windowDecl.hasMaxWidth: formatSwiftDouble(windowDecl.maxWidth) else: "window.maxSize.width"
        let maxH = if windowDecl.hasMaxHeight: formatSwiftDouble(windowDecl.maxHeight) else: "window.maxSize.height"
        outLines.add "            window.maxSize = NSSize(width: " & maxW & ", height: " & maxH & ")"
      if hasTitleBarPreference:
        if showTitleBar:
          outLines.add "            window.titleVisibility = .visible"
          outLines.add "            window.titlebarAppearsTransparent = false"
        else:
          outLines.add "            window.titleVisibility = .hidden"
          outLines.add "            window.titlebarAppearsTransparent = true"
        # Extend content into the titlebar region so split-view sidebars align
        # under the traffic-light/titlebar area.
        outLines.add "            window.styleMask.insert(.fullSizeContentView)"
        outLines.add "            window.toolbarStyle = .unified"
        outLines.add "            window.toolbar?.showsBaselineSeparator = false"
      outLines.add "          }"
      outLines.add "#endif"
    if hasShortcutMonitor:
      outLines.add "#if os(macOS)"
      outLines.add "          store.shortcutMonitor.start(store: store)"
      outLines.add "#endif"
    outLines.add "        }"
  outLines.add "        .onDisappear {"
  if hasShortcutMonitor:
    outLines.add "#if os(macOS)"
    outLines.add "          store.shortcutMonitor.stop()"
    outLines.add "#endif"
  outLines.add "        }"
  if hasShortcutMonitor:
    outLines.add "#if os(macOS)"
    outLines.add "        .onChange(of: store.state.keybinds) { newValue in"
    outLines.add "          store.shortcutMonitor.reloadBindings(from: newValue)"
    outLines.add "        }"
    outLines.add "#endif"
  outLines.add "    }"
  if hasWindowDefaultSize:
    outLines.add "    .defaultSize(width: " & formatSwiftDouble(windowDecl.width) &
      ", height: " & formatSwiftDouble(windowDecl.height) & ")"
  # Suppress default macOS menu items that steal keyboard shortcuts
  if windowDecl.hasSuppressDefaultMenus and windowDecl.suppressDefaultMenus:
    outLines.add "#if os(macOS)"
    outLines.add "    .commands {"
    outLines.add "        CommandGroup(replacing: .newItem) { }"
    outLines.add "        CommandGroup(replacing: .printItem) { }"
    outLines.add "        CommandGroup(replacing: .help) {"
    outLines.add "            Button(\"Keyboard Shortcuts...\") {"
    outLines.add "                store.send(.showKeybindSheet)"
    outLines.add "            }"
    outLines.add "        }"
    outLines.add "    }"
    outLines.add "#endif"
  # Settings scene (macOS)
  if ir.settingsComponent.len > 0:
    outLines.add "#if os(macOS)"
    outLines.add "    Settings {"
    outLines.add "      Component_" & swiftIdent(ir.settingsComponent) & "(store: store)"
    outLines.add "    }"
    outLines.add "#endif"
  outLines.add "  }"
  outLines.add "}"

  outLines.join("\n") & "\n"

proc emitRuntimeSwift(): string =
  """
import Foundation
import SwiftUI
import Security

enum GUIAnyValue {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case action(GUIAction)
  case object([String: GUIAnyValue])
  case array([GUIAnyValue])
  case null

  static func from(_ value: String) -> GUIAnyValue { .string(value) }
  static func from(_ value: Int) -> GUIAnyValue { .int(value) }
  static func from(_ value: Int64) -> GUIAnyValue { .int(Int(value)) }
  static func from(_ value: Double) -> GUIAnyValue { .double(value) }
  static func from(_ value: Float) -> GUIAnyValue { .double(Double(value)) }
  static func from(_ value: Bool) -> GUIAnyValue { .bool(value) }
  static func from(_ value: [String: GUIAnyValue]) -> GUIAnyValue { .object(value) }
  static func from(_ value: [GUIAnyValue]) -> GUIAnyValue { .array(value) }
  static func from(_ value: [String: String]) -> GUIAnyValue {
    var mapped: [String: GUIAnyValue] = [:]
    for (k, v) in value { mapped[k] = .string(v) }
    return .object(mapped)
  }
  static func from<T>(_ value: T?) -> GUIAnyValue {
    guard let value else { return .null }
    if let cast = value as? String { return .string(cast) }
    if let cast = value as? Int { return .int(cast) }
    if let cast = value as? Int64 { return .int(Int(cast)) }
    if let cast = value as? Double { return .double(cast) }
    if let cast = value as? Float { return .double(Double(cast)) }
    if let cast = value as? Bool { return .bool(cast) }
    if let cast = value as? GUIAction { return .action(cast) }
    if let cast = value as? [String: Any] {
      var mapped: [String: GUIAnyValue] = [:]
      for (k, v) in cast { mapped[k] = GUIAnyValue.from(v) }
      return .object(mapped)
    }
    if let cast = value as? [Any] {
      return .array(cast.map { GUIAnyValue.from($0) })
    }
    return .string(String(describing: value))
  }

  var stringValue: String? {
    if case let .string(v) = self { return v }
    return nil
  }

  var intValue: Int? {
    switch self {
    case let .int(v): return v
    case let .double(v): return Int(v)
    case let .string(v): return Int(v)
    default: return nil
    }
  }

  var doubleValue: Double? {
    switch self {
    case let .double(v): return v
    case let .int(v): return Double(v)
    case let .string(v): return Double(v)
    default: return nil
    }
  }

  var boolValue: Bool? {
    switch self {
    case let .bool(v): return v
    case let .string(v):
      switch v.lowercased() {
      case "true", "1", "yes", "on": return true
      case "false", "0", "no", "off": return false
      default: return nil
      }
    default:
      return nil
    }
  }

  var actionValue: GUIAction? {
    if case let .action(v) = self { return v }
    return nil
  }

  var objectValue: [String: GUIAnyValue]? {
    if case let .object(v) = self { return v }
    return nil
  }

  var arrayValue: [GUIAnyValue]? {
    if case let .array(v) = self { return v }
    return nil
  }
}

struct GUIEffectCommand {
  let name: String
  let args: [String: GUIAnyValue]
}

func guiColor(_ hexOrName: String) -> Color {
  let value = hexOrName.trimmingCharacters(in: .whitespacesAndNewlines)
  if value.hasPrefix("#") {
    let hex = String(value.dropFirst())
    let scanner = Scanner(string: hex)
    var rgb: UInt64 = 0
    if scanner.scanHexInt64(&rgb) {
      switch hex.count {
      case 6:
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
      case 8:
        let r = Double((rgb >> 24) & 0xFF) / 255.0
        let g = Double((rgb >> 16) & 0xFF) / 255.0
        let b = Double((rgb >> 8) & 0xFF) / 255.0
        let a = Double(rgb & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b, opacity: a)
      default:
        break
      }
    }
  }
  return Color(value)
}

@MainActor
final class GUIRuntime {
  private unowned let store: GUIStore
  private var timerTasks: [String: Task<Void, Never>] = [:]
  private var streamTasks: [String: Task<Void, Never>] = [:]
  private var websocketTasks: [String: URLSessionWebSocketTask] = [:]
  private let bridgeRuntime = GUIBridgeRuntime()
  private var bridgeTimeoutMs = 250
  private var notifySource: DispatchSourceRead?
  private var notifyStarted = false
  private var dispatchInFlight = false
  private var pollQueued = false

  init(store: GUIStore) {
    self.store = store
  }

  func dispatchShutdownAction(actionTag: UInt32, state: GUIState?) {
    // Dispatch a shutdown action to the bridge without waiting.
    // This gives the Nim event loop thread a chance to send QUIT messages.
    guard let bridgePath = resolveBridgeDylibPath() else { return }
    bridgeRuntime.maybeReload(path: bridgePath)
    if !bridgeRuntime.load(path: bridgePath) { return }
    let payload = makeBridgePayload(actionTag: actionTag, state: state)
    _ = bridgeRuntime.dispatch(payload: payload)
  }

  func awaitShutdownComplete(timeoutMs: Int32, completion: @escaping () -> Void) {
    // Wait for the Nim event loop to finish graceful shutdown on a background
    // thread, then clean up and call completion on the main thread.
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      _ = self?.bridgeRuntime.waitShutdown(timeoutMs: timeoutMs)
      DispatchQueue.main.async {
        self?.shutdown()
        completion()
      }
    }
  }

  private var hasShutDown = false

  func shutdown() {
    guard !hasShutDown else { return }
    hasShutDown = true
    notifySource?.cancel()
    notifySource = nil

    for (_, task) in timerTasks {
      task.cancel()
    }
    timerTasks.removeAll()

    for (_, task) in streamTasks {
      task.cancel()
    }
    streamTasks.removeAll()

    for (_, socket) in websocketTasks {
      socket.cancel(with: .goingAway, reason: nil)
    }
    websocketTasks.removeAll()

    bridgeRuntime.unload()
  }

  private func startBridgeNotifySource() {
    guard !notifyStarted else { return }
    let fd = bridgeRuntime.getNotifyFd()
    guard fd >= 0 else { return }
    notifyStarted = true

    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    source.setEventHandler { [weak self] in
      // Drain all bytes from the pipe
      var buf = [UInt8](repeating: 0, count: 64)
      while Darwin.read(fd, &buf, buf.count) > 0 {}
      // Dispatch on next run loop iteration to avoid re-entrancy
      DispatchQueue.main.async {
        self?.enqueuePollAction()
      }
    }
    notifySource = source
    source.resume()
  }

  private func enqueuePollAction() {
    guard let pollTag = guiBridgePollActionTag,
          let action = guiActionFromTag(pollTag) else { return }
    store.send(action)
  }

  func enqueue(_ commands: [GUIEffectCommand]) {
    for command in commands {
      run(command)
    }
  }

  private func run(_ command: GUIEffectCommand) {
    switch command.name {
    case "timer.once":
      runTimerOnce(command.args)
    case "timer.interval":
      runTimerInterval(command.args)
    case "timer.debounce":
      runTimerDebounce(command.args)
    case "http.request":
      runHttpRequest(command.args)
    case "stream.sse":
      runSse(command.args)
    case "stream.ws":
      runWebSocket(command.args)
    case "stream.httpChunked":
      runHttpChunked(command.args)
    case "persist.defaults":
      runPersistDefaults(command.args)
    case "persist.file":
      runPersistFile(command.args)
    case "keychain.add":
      runKeychainAdd(command.args)
    case "keychain.query":
      runKeychainQuery(command.args)
    case "keychain.update":
      runKeychainUpdate(command.args)
    case "keychain.delete":
      runKeychainDelete(command.args)
    case "bridge.dispatch":
      runBridgeDispatch(command.args)
    default:
      break
    }
  }

  private func sendAction(_ value: GUIAnyValue?) {
    guard let action = value?.actionValue else { return }
    store.send(action)
  }

  private func runTimerOnce(_ args: [String: GUIAnyValue]) {
    let ms = args["ms"]?.intValue ?? 0
    let action = args["action"]
    Task {
      if ms > 0 {
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
      }
      await MainActor.run {
        self.sendAction(action)
      }
    }
  }

  private func runTimerInterval(_ args: [String: GUIAnyValue]) {
    let id = args["id"]?.stringValue ?? UUID().uuidString
    let ms = max(1, args["ms"]?.intValue ?? 1000)
    let action = args["action"]
    timerTasks[id]?.cancel()
    timerTasks[id] = Task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
        await MainActor.run {
          self.sendAction(action)
        }
      }
    }
  }

  private func runTimerDebounce(_ args: [String: GUIAnyValue]) {
    let id = args["id"]?.stringValue ?? "default"
    let ms = max(1, args["ms"]?.intValue ?? 300)
    let action = args["action"]
    timerTasks[id]?.cancel()
    timerTasks[id] = Task {
      try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
      await MainActor.run {
        self.sendAction(action)
      }
    }
  }

  private func runHttpRequest(_ args: [String: GUIAnyValue]) {
    guard let urlText = args["url"]?.stringValue, let url = URL(string: urlText) else {
      sendAction(args["onError"])
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = (args["method"]?.stringValue ?? "GET").uppercased()

    if let headers = args["headers"]?.objectValue {
      for (k, v) in headers {
        if let value = v.stringValue {
          request.setValue(value, forHTTPHeaderField: k)
        }
      }
    }

    if let body = args["body"] {
      request.httpBody = dataFromAnyValue(body)
      if request.value(forHTTPHeaderField: "Content-Type") == nil {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      }
    }

    Task {
      do {
        _ = try await URLSession.shared.data(for: request)
        await MainActor.run {
          self.sendAction(args["onSuccess"])
        }
      } catch {
        await MainActor.run {
          self.sendAction(args["onError"])
        }
      }
    }
  }

  private func runSse(_ args: [String: GUIAnyValue]) {
    guard let urlText = args["url"]?.stringValue, let url = URL(string: urlText) else {
      sendAction(args["onError"])
      return
    }
    let taskId = args["id"]?.stringValue ?? UUID().uuidString

    streamTasks[taskId]?.cancel()
    streamTasks[taskId] = Task {
      var request = URLRequest(url: url)
      request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

      do {
        let (bytes, _) = try await URLSession.shared.bytes(for: request)
        await MainActor.run { self.sendAction(args["onOpen"]) }

        var dataBuffer = ""
        for try await line in bytes.lines {
          if Task.isCancelled { break }
          if line.isEmpty {
            if !dataBuffer.isEmpty {
              await MainActor.run { self.sendAction(args["onEvent"]) }
              dataBuffer = ""
            }
            continue
          }
          if line.hasPrefix("data:") {
            dataBuffer += String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
          }
        }
      } catch {
        await MainActor.run { self.sendAction(args["onError"]) }
      }
    }
  }

  private func runWebSocket(_ args: [String: GUIAnyValue]) {
    guard let urlText = args["url"]?.stringValue, let url = URL(string: urlText) else {
      sendAction(args["onError"])
      return
    }

    let id = args["id"]?.stringValue ?? UUID().uuidString
    websocketTasks[id]?.cancel(with: .goingAway, reason: nil)

    let ws = URLSession.shared.webSocketTask(with: url)
    websocketTasks[id] = ws
    ws.resume()
    sendAction(args["onOpen"])

    func receiveLoop() {
      ws.receive { [weak self] result in
        guard let self else { return }
        switch result {
        case .success:
          Task { @MainActor in
            self.sendAction(args["onMessage"])
          }
          receiveLoop()
        case .failure:
          Task { @MainActor in
            self.sendAction(args["onError"])
            self.sendAction(args["onClose"])
          }
        }
      }
    }

    receiveLoop()
  }

  private func runHttpChunked(_ args: [String: GUIAnyValue]) {
    guard let urlText = args["url"]?.stringValue, let url = URL(string: urlText) else {
      sendAction(args["onError"])
      return
    }

    let taskId = args["id"]?.stringValue ?? UUID().uuidString
    streamTasks[taskId]?.cancel()
    streamTasks[taskId] = Task {
      var request = URLRequest(url: url)
      request.httpMethod = "GET"
      do {
        let (bytes, _) = try await URLSession.shared.bytes(for: request)
        for try await _ in bytes {
          if Task.isCancelled { break }
          await MainActor.run { self.sendAction(args["onChunk"]) }
        }
        await MainActor.run { self.sendAction(args["onComplete"]) }
      } catch {
        await MainActor.run { self.sendAction(args["onError"]) }
      }
    }
  }

  private func runBridgeDispatch(_ args: [String: GUIAnyValue]) {
    guard let action = args["action"]?.actionValue else {
      return
    }

    guard let bridgePath = resolveBridgeDylibPath() else {
      logBridge("warning", "bridge dylib not found; skipping Nim-owned action", code: "GUI_BRIDGE_DYLIB_MISSING")
      return
    }

    let actionTag = UInt32(args["actionTag"]?.intValue ?? Int(guiActionTag(action)))
    let isPollAction = (guiBridgePollActionTag != nil && actionTag == guiBridgePollActionTag!)
    if dispatchInFlight {
      if isPollAction {
        pollQueued = true
      }
      return
    }
    dispatchInFlight = true
    defer {
      dispatchInFlight = false
      if pollQueued {
        pollQueued = false
        DispatchQueue.main.async { [weak self] in
          self?.enqueuePollAction()
        }
      }
    }

    let payload = makeBridgePayload(actionTag: actionTag, state: store.state)
    let correlation = UUID().uuidString

    // Run bridge dispatch synchronously on the main actor to prevent
    // concurrent state mutations that crash SwiftUI during layout.
    bridgeRuntime.maybeReload(path: bridgePath)
    if !bridgeRuntime.load(path: bridgePath) {
      logBridge("error", "failed to load bridge function table", code: "GUI_BRIDGE_ABI_MISMATCH")
    }
    startBridgeNotifySource()

    let started = Date()
    let result = bridgeRuntime.dispatch(payload: payload)
    let elapsedMs = Date().timeIntervalSince(started) * 1000.0
    if elapsedMs > Double(bridgeTimeoutMs) {
      logBridge("warning", "bridge dispatch exceeded timeout (\(Int(elapsedMs))ms)", code: "GUI_BRIDGE_TIMEOUT")
    }

    if !result.diagnostics.isEmpty,
       let text = String(data: result.diagnostics, encoding: .utf8) {
      logBridge("info", "[\(correlation)] " + text, code: "GUI_BRIDGE_DIAGNOSTIC")
    }

    if !result.statePatch.isEmpty {
      applyBridgeStatePatch(result.statePatch)
    }

    let emittedTags = decodeBridgeActionTags(result.emittedActions)
    for tag in emittedTags {
      if let emittedAction = guiActionFromTag(tag) {
        store.send(emittedAction)
      } else {
        logBridge("warning", "bridge emitted unsupported action tag \(tag)", code: "GUI_BRIDGE_EMIT_TAG")
      }
    }
  }

  private func makeBridgePayload(actionTag: UInt32, state: GUIState?) -> Data {
    var payload = Data()
    var tag = actionTag.littleEndian
    withUnsafeBytes(of: &tag) { payload.append(contentsOf: $0) }

    var fields = guiBridgeEncodeRequestFields(actionTag: actionTag, state: state)
    if fields.count > Int(UInt16.max) {
      fields = Array(fields.prefix(Int(UInt16.max)))
    }

    var fieldCount = UInt16(fields.count).littleEndian
    withUnsafeBytes(of: &fieldCount) { payload.append(contentsOf: $0) }
    var reserved: UInt16 = 0
    withUnsafeBytes(of: &reserved) { payload.append(contentsOf: $0) }

    for field in fields {
      var idLE = field.fieldId.littleEndian
      withUnsafeBytes(of: &idLE) { payload.append(contentsOf: $0) }
      payload.append(field.valueType)
      payload.append(0) // reserved
      var lenLE = UInt32(min(field.payload.count, Int(UInt32.max))).littleEndian
      withUnsafeBytes(of: &lenLE) { payload.append(contentsOf: $0) }
      if lenLE > 0 {
        payload.append(field.payload.prefix(Int(lenLE)))
      }
    }
    return payload
  }

  private func decodeBridgeActionTags(_ data: Data) -> [UInt32] {
    if data.isEmpty {
      return []
    }
    guard data.count % 4 == 0 else {
      logBridge("warning", "bridge emitted malformed action-tag payload", code: "GUI_BRIDGE_EMIT_FORMAT")
      return []
    }

    var tags: [UInt32] = []
    tags.reserveCapacity(data.count / 4)
    data.withUnsafeBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      var index = 0
      while index + 3 < bytes.count {
        let value =
          UInt32(bytes[index]) |
          (UInt32(bytes[index + 1]) << 8) |
          (UInt32(bytes[index + 2]) << 16) |
          (UInt32(bytes[index + 3]) << 24)
        tags.append(value)
        index += 4
      }
    }
    return tags
  }

  private func applyBridgeStatePatch(_ patchData: Data) {
    guard !patchData.isEmpty else { return }

    func readU16(_ data: Data, _ offset: Int) -> UInt16? {
      guard offset + 1 < data.count else { return nil }
      return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    func readU32(_ data: Data, _ offset: Int) -> UInt32? {
      guard offset + 3 < data.count else { return nil }
      return UInt32(data[offset]) |
             (UInt32(data[offset + 1]) << 8) |
             (UInt32(data[offset + 2]) << 16) |
             (UInt32(data[offset + 3]) << 24)
    }

    guard patchData.count >= 4,
          let fieldCount = readU16(patchData, 0) else {
      logBridge("warning", "bridge emitted malformed binary state patch", code: "GUI_BRIDGE_STATE_PATCH")
      return
    }

    var offset = 4 // u16 count + u16 reserved
    var nextState = store.state
    var appliedAny = false

    for _ in 0..<fieldCount {
      guard let fieldId = readU16(patchData, offset),
            offset + 7 < patchData.count else {
        logBridge("warning", "bridge emitted truncated binary state patch", code: "GUI_BRIDGE_STATE_PATCH")
        return
      }
      let valueType = patchData[offset + 2]
      guard let valueLen = readU32(patchData, offset + 4) else {
        logBridge("warning", "bridge emitted malformed binary state patch length", code: "GUI_BRIDGE_STATE_PATCH")
        return
      }
      offset += 8
      let end = offset + Int(valueLen)
      guard end <= patchData.count else {
        logBridge("warning", "bridge emitted out-of-bounds binary state patch", code: "GUI_BRIDGE_STATE_PATCH")
        return
      }
      let payload = patchData.subdata(in: offset..<end)
      if guiBridgeApplyPatchField(state: &nextState, fieldId: fieldId, valueType: valueType, payload: payload) {
        appliedAny = true
      }
      offset = end
    }

    if appliedAny {
      store.state = nextState
    }
  }

  private func resolveBridgeDylibPath() -> String? {
    let env = ProcessInfo.processInfo.environment
    if let direct = env["GUI_BRIDGE_DYLIB"], !direct.isEmpty, FileManager.default.fileExists(atPath: direct) {
      return direct
    }

    var candidates: [String] = []
    if let frameworkDir = Bundle.main.privateFrameworksPath {
      candidates.append((frameworkDir as NSString).appendingPathComponent("libgui_bridge_latest.dylib"))
      candidates.append((frameworkDir as NSString).appendingPathComponent("libgui_bridge_latest.so"))
    }

    let bundleURL = URL(fileURLWithPath: Bundle.main.bundlePath)
    candidates.append(bundleURL.appendingPathComponent("Contents/Frameworks/libgui_bridge_latest.dylib").path)
    candidates.append(bundleURL.appendingPathComponent("Contents/Frameworks/libgui_bridge_latest.so").path)

    if let resourceURL = Bundle.main.resourceURL {
      candidates.append(resourceURL.appendingPathComponent("Bridge/Nim/libgui_bridge_latest.dylib").path)
      candidates.append(resourceURL.appendingPathComponent("Bridge/Nim/libgui_bridge_latest.so").path)
    }

    for path in candidates where FileManager.default.fileExists(atPath: path) {
      return path
    }

    if env["GUI_BRIDGE_ALLOW_EXTERNAL"] == "1" {
      var cursor = bundleURL
      for _ in 0..<6 {
        cursor.deleteLastPathComponent()
        candidates.append(cursor.appendingPathComponent("Bridge/Nim/libgui_bridge_latest.dylib").path)
        candidates.append(cursor.appendingPathComponent("Bridge/Nim/libgui_bridge_latest.so").path)
      }
      for path in candidates where FileManager.default.fileExists(atPath: path) {
        return path
      }
    }
    return nil
  }

  private func logBridge(_ level: String, _ message: String, code: String) {
    print("[GUIBridge][\(level)][\(code)] \(message)")
  }

  private func runPersistDefaults(_ args: [String: GUIAnyValue]) {
    guard let key = args["key"]?.stringValue, let value = args["value"] else { return }
    UserDefaults.standard.set(foundationValue(from: value), forKey: key)
  }

  private func runPersistFile(_ args: [String: GUIAnyValue]) {
    guard let key = args["key"]?.stringValue, let value = args["value"] else { return }

    let fileURL: URL
    if let path = args["path"]?.stringValue {
      fileURL = URL(fileURLWithPath: path)
    } else {
      let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
      fileURL = appSupport.appendingPathComponent("gui-persist.json")
    }

    do {
      try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      var payload: [String: Any] = [:]
      if let data = try? Data(contentsOf: fileURL),
         let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        payload = existing
      }
      payload[key] = foundationValue(from: value)
      let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
      try data.write(to: fileURL, options: .atomic)
    } catch {
      // best-effort persistence in v1 runtime
    }
  }

  private func runKeychainAdd(_ args: [String: GUIAnyValue]) {
    guard let query = makeKeychainBaseQuery(args) else { return }
    var final = query
    if let value = args["value"] {
      final[kSecValueData as String] = dataFromAnyValue(value) ?? Data()
    }
    _ = SecItemAdd(final as CFDictionary, nil)
  }

  private func runKeychainQuery(_ args: [String: GUIAnyValue]) {
    guard var query = makeKeychainBaseQuery(args) else { return }
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    if let extra = args["queryAttrs"]?.objectValue {
      mergeKeychainAttributes(into: &query, attrs: extra)
    }

    var out: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &out)
    if status == errSecSuccess {
      sendAction(args["onSuccess"])
    } else {
      sendAction(args["onError"])
    }
  }

  private func runKeychainUpdate(_ args: [String: GUIAnyValue]) {
    guard let query = makeKeychainBaseQuery(args) else { return }
    var updates: [String: Any] = [:]
    if let value = args["value"] {
      updates[kSecValueData as String] = dataFromAnyValue(value) ?? Data()
    }
    if let attrs = args["attrs"]?.objectValue {
      mergeKeychainAttributes(into: &updates, attrs: attrs)
    }
    _ = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
  }

  private func runKeychainDelete(_ args: [String: GUIAnyValue]) {
    guard let query = makeKeychainBaseQuery(args) else { return }
    _ = SecItemDelete(query as CFDictionary)
  }

  private func makeKeychainBaseQuery(_ args: [String: GUIAnyValue]) -> [String: Any]? {
    guard let service = args["service"]?.stringValue,
          let account = args["account"]?.stringValue else {
      return nil
    }

    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account
    ]

    if let attrs = args["attrs"]?.objectValue {
      mergeKeychainAttributes(into: &query, attrs: attrs)
    }

    return query
  }

  private func mergeKeychainAttributes(into query: inout [String: Any], attrs: [String: GUIAnyValue]) {
    for (rawKey, rawValue) in attrs {
      if let known = keychainKnownAttribute(for: rawKey) {
        query[known as String] = foundationValue(from: rawValue)
      } else if rawKey.hasPrefix("kSec") {
        query[rawKey] = foundationValue(from: rawValue)
      }
    }
  }

  private func keychainKnownAttribute(for name: String) -> CFString? {
    switch name {
    case "kSecClass": return kSecClass
    case "kSecAttrAccessible": return kSecAttrAccessible
    case "kSecAttrAccessControl": return kSecAttrAccessControl
    case "kSecAttrAccessGroup": return kSecAttrAccessGroup
    case "kSecAttrSynchronizable": return kSecAttrSynchronizable
    case "kSecAttrService": return kSecAttrService
    case "kSecAttrAccount": return kSecAttrAccount
    case "kSecAttrLabel": return kSecAttrLabel
    case "kSecAttrDescription": return kSecAttrDescription
    case "kSecAttrComment": return kSecAttrComment
    case "kSecAttrGeneric": return kSecAttrGeneric
    case "kSecAttrCreator": return kSecAttrCreator
    case "kSecAttrType": return kSecAttrType
    case "kSecAttrIsInvisible": return kSecAttrIsInvisible
    case "kSecAttrIsNegative": return kSecAttrIsNegative
    case "kSecAttrApplicationTag": return kSecAttrApplicationTag
    case "kSecAttrKeyType": return kSecAttrKeyType
    case "kSecAttrKeySizeInBits": return kSecAttrKeySizeInBits
    case "kSecAttrEffectiveKeySize": return kSecAttrEffectiveKeySize
    case "kSecAttrCanEncrypt": return kSecAttrCanEncrypt
    case "kSecAttrCanDecrypt": return kSecAttrCanDecrypt
    case "kSecAttrCanDerive": return kSecAttrCanDerive
    case "kSecAttrCanSign": return kSecAttrCanSign
    case "kSecAttrCanVerify": return kSecAttrCanVerify
    case "kSecAttrCanWrap": return kSecAttrCanWrap
    case "kSecAttrCanUnwrap": return kSecAttrCanUnwrap
    case "kSecReturnData": return kSecReturnData
    case "kSecReturnAttributes": return kSecReturnAttributes
    case "kSecReturnRef": return kSecReturnRef
    case "kSecReturnPersistentRef": return kSecReturnPersistentRef
    case "kSecMatchLimit": return kSecMatchLimit
    case "kSecMatchItemList": return kSecMatchItemList
    case "kSecMatchSearchList": return kSecMatchSearchList
    case "kSecMatchPolicy": return kSecMatchPolicy
    case "kSecMatchIssuers": return kSecMatchIssuers
    case "kSecMatchEmailAddressIfPresent": return kSecMatchEmailAddressIfPresent
    case "kSecMatchSubjectContains": return kSecMatchSubjectContains
    case "kSecMatchCaseInsensitive": return kSecMatchCaseInsensitive
    case "kSecMatchTrustedOnly": return kSecMatchTrustedOnly
    case "kSecMatchValidOnDate": return kSecMatchValidOnDate
    default: return nil
    }
  }

  private func foundationValue(from value: GUIAnyValue) -> Any {
    switch value {
    case let .string(v): return v
    case let .int(v): return v
    case let .double(v): return v
    case let .bool(v): return v
    case let .object(v):
      var out: [String: Any] = [:]
      for (k, item) in v { out[k] = foundationValue(from: item) }
      return out
    case let .array(v):
      return v.map { foundationValue(from: $0) }
    case .action:
      return "<action>"
    case .null:
      return NSNull()
    }
  }

  private func dataFromAnyValue(_ value: GUIAnyValue) -> Data? {
    switch value {
    case let .string(v):
      return Data(v.utf8)
    case let .int(v):
      return Data(String(v).utf8)
    case let .double(v):
      return Data(String(v).utf8)
    case let .bool(v):
      return Data((v ? "true" : "false").utf8)
    case .action:
      return nil
    case .null:
      return nil
    case let .array(v):
      let payload = v.map { foundationValue(from: $0) }
      return try? JSONSerialization.data(withJSONObject: payload)
    case let .object(v):
      var payload: [String: Any] = [:]
      for (k, item) in v { payload[k] = foundationValue(from: item) }
      return try? JSONSerialization.data(withJSONObject: payload)
    }
  }
}
""".strip() & "\n"

proc copyEscapeFiles(
  ir: GuiIrProgram,
  appDir: string,
  generatedFiles: var seq[string],
  diagnostics: var seq[GuiDiagnostic],
  copiedCustomFiles: var seq[string]
) =
  let customDir = appDir / "App" / "Custom"
  createDir(customDir)

  for esc in ir.escapes:
    let sourceBase = esc.range.start.file.parentDir()
    let sourcePath =
      if esc.swiftFile.isAbsolute:
        esc.swiftFile
      else:
        normalizedPath(sourceBase / esc.swiftFile)

    if not fileExists(sourcePath):
      diagnostics.add mkDiagnostic(
        esc.range,
        gsError,
        "escape swiftFile source does not exist: " & sourcePath,
        "GUI_CODEGEN_ESCAPE"
      )
      continue

    let destPath = customDir / sourcePath.extractFilename()
    if fileExists(destPath):
      # Never overwrite custom files automatically.
      copiedCustomFiles.add destPath
      continue

    copyFile(sourcePath, destPath)
    generatedFiles.add destPath
    copiedCustomFiles.add destPath

proc emitCustomSourcesAggregate(
  customFiles: seq[string],
  diagnostics: var seq[GuiDiagnostic]
): string =
  var buffer = "import Foundation\n\n"
  if customFiles.len == 0:
    buffer.add "// No custom escape sources.\n"
    return buffer

  for path in customFiles:
    if not fileExists(path):
      diagnostics.add mkDiagnostic(path, 1, 1, gsWarning, "custom escape file missing while generating aggregate", "GUI_CODEGEN_CUSTOM")
      continue
    try:
      let content = readFile(path)
      buffer.add "#sourceLocation(file: \"" & escapeSwiftString(path) & "\", line: 1)\n"
      buffer.add content
      if not content.endsWith("\n"):
        buffer.add "\n"
      buffer.add "\n"
    except CatchableError as e:
      diagnostics.add mkDiagnostic(path, 1, 1, gsWarning, "failed to read custom escape source: " & e.msg, "GUI_CODEGEN_CUSTOM")

  buffer.add "#sourceLocation()\n"
  buffer

proc emitBridgeSwiftStub(): string =
  """
import Foundation

struct GUIBridgeDispatchResult {
  var status: Int32
  var statePatch: Data
  var effects: Data
  var emittedActions: Data
  var diagnostics: Data

  static var empty: GUIBridgeDispatchResult {
    GUIBridgeDispatchResult(status: 0, statePatch: Data(), effects: Data(), emittedActions: Data(), diagnostics: Data())
  }
}

final class GUIBridgeRuntime {
  func load(path: String) -> Bool { false }
  func unload() {}
  func maybeReload(path: String) {}
  func dispatch(payload: Data) -> GUIBridgeDispatchResult { .empty }
  func getNotifyFd() -> Int32 { -1 }
  func waitShutdown(timeoutMs: Int32) -> Bool { false }
}
""".strip() & "\n"

proc emitSwiftSources*(
  ir: GuiIrProgram,
  appDir: string,
  generatedFiles: var seq[string],
  diagnostics: var seq[GuiDiagnostic]
) =
  let generatedDir = appDir / "App" / "Generated"
  createDir(generatedDir)

  let appName = if ir.appName.len > 0: ir.appName else: "GuiApp"

  let mainSwift = emitGeneratedSwift(ir, appName)
  let runtimeSwift = emitRuntimeSwift()

  let mainPath = generatedDir / "GUI.generated.swift"
  writeFile(mainPath, mainSwift)
  generatedFiles.add mainPath

  let runtimePath = generatedDir / "GUIRuntime.generated.swift"
  writeFile(runtimePath, runtimeSwift)
  generatedFiles.add runtimePath

  var customFiles: seq[string] = @[]
  copyEscapeFiles(ir, appDir, generatedFiles, diagnostics, customFiles)

  let customAggregatePath = generatedDir / "GUICustomSources.generated.swift"
  writeFile(customAggregatePath, emitCustomSourcesAggregate(customFiles, diagnostics))
  generatedFiles.add customAggregatePath

  let bridgeStubPath = generatedDir / "GUIBridgeSwift.generated.swift"
  if not fileExists(bridgeStubPath):
    writeFile(bridgeStubPath, emitBridgeSwiftStub())
  generatedFiles.add bridgeStubPath
