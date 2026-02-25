## CPS UI DSL
##
## A Karax-like block macro that rewrites nested tag blocks into VDOM builders.

import std/[macros, strutils]
import ./vdom
import ./types
import ./schema/generated/[elements, events, attrs, constraints]

proc coerceChild*(value: VNode): VNode =
  value

proc coerceChild*(value: seq[VNode]): VNode =
  fragmentFromSeq(value)

proc coerceChild*(value: typeof(nil)): VNode =
  nil

proc coerceChild*[T](value: T): VNode =
  text($value)

proc nodeName(n: NimNode): string {.compileTime.} =
  case n.kind
  of nnkIdent, nnkSym:
    $n
  of nnkAccQuoted:
    var combined = ""
    for part in n:
      combined.add nodeName(part)
    combined
  of nnkDotExpr:
    if n.len > 0:
      nodeName(n[^1])
    else:
      ""
  of nnkOpenSymChoice, nnkClosedSymChoice:
    if n.len > 0:
      nodeName(n[0])
    else:
      ""
  of nnkBracketExpr:
    if n.len > 0:
      nodeName(n[0])
    else:
      ""
  else:
    ""

proc isUpperComponentName(name: string): bool {.compileTime.} =
  name.len > 0 and name[0] in {'A'..'Z'}

proc dslError(msg: string, n: NimNode) {.compileTime.} =
  error("UI DSL error: " & msg, n)

proc normalizeAttrName(name: string): string {.compileTime.} =
  if name == "className":
    "class"
  else:
    name

proc isStringLiteralNode(n: NimNode): bool {.compileTime.} =
  n.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}

proc literalAsString(n: NimNode, ok: var bool): string {.compileTime.} =
  ok = true
  case n.kind
  of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
    n.strVal
  of nnkIntLit, nnkInt8Lit, nnkInt16Lit, nnkInt32Lit, nnkInt64Lit,
     nnkUIntLit, nnkUInt8Lit, nnkUInt16Lit, nnkUInt32Lit, nnkUInt64Lit:
    $n.intVal
  of nnkFloatLit, nnkFloat32Lit, nnkFloat64Lit:
    $n.floatVal
  of nnkIdent:
    let name = $n
    if name == "true" or name == "false":
      name
    else:
      ok = false
      ""
  else:
    ok = false
    ""

proc validateAttrNameForTag(tag: string, attrName: string, n: NimNode) {.compileTime.} =
  if attrName == "__nimui_ref":
    return
  let ns = elementNamespace(tag)
  if ns.len == 0:
    return
  if not isAllowedAttrForElement(ns, tag, attrName):
    dslError(
      "attribute '" & attrName & "' is not allowed on <" & tag & "> (" & ns & " namespace)",
      n
    )

proc validateAttrConstraintForTag(tag: string, attrName: string, valueExpr: NimNode, n: NimNode) {.compileTime.} =
  let ns = elementNamespace(tag)
  if ns.len == 0:
    return
  if not hasEnumConstraint(ns, tag, attrName):
    return
  var isLiteral = false
  let literal = literalAsString(valueExpr, isLiteral)
  if not isLiteral:
    return
  if not enumConstraintAllows(ns, tag, attrName, literal):
    dslError(
      "invalid literal value '" & literal & "' for " & tag & "." & attrName &
      "; allowed: " & enumConstraintValues(ns, tag, attrName),
      n
    )

proc ensureKnownTag(head: string, n: NimNode) {.compileTime.} =
  if not isKnownStandardElement(head):
    dslError(
      "unknown standard tag '" & head &
      "'. Use customTag(\"my-widget\", ...) for custom elements.",
      n
    )

proc callLooksLikeComponent(callNode: NimNode, head: string): bool {.compileTime.} =
  discard callNode
  ## Component promotion is explicit: only UpperCamelCase names are treated as
  ## components. Lowercase calls are regular expressions unless wrapped manually.
  isUpperComponentName(head)

proc rewriteUiNode(n: NimNode): NimNode {.compileTime.}
proc isSetupStmt(n: NimNode): bool {.compileTime.}

proc eventBindingCall(eventId: string, handlerExpr: NimNode, capture: bool): NimNode {.compileTime.} =
  if capture:
    let optsExpr = newCall(
      ident("opts"),
      newTree(nnkExprEqExpr, ident("capture"), newLit(true))
    )
    return newCall(ident("on"), ident(eventId), rewriteUiNode(handlerExpr), optsExpr)
  newCall(ident("on"), ident(eventId), rewriteUiNode(handlerExpr))

proc validateCustomTagNameExpr(nameExpr: NimNode, n: NimNode) {.compileTime.} =
  if not isStringLiteralNode(nameExpr):
    return
  let value = nameExpr.strVal
  if value.len == 0 or '-' notin value:
    dslError("customTag name must contain a hyphen, e.g. \"my-widget\"", n)

proc rewriteChildExpr(n: NimNode): NimNode {.compileTime.} =
  newCall(bindSym"coerceChild", rewriteUiNode(n))

proc rewriteStmtListChildren(stmts: NimNode): seq[NimNode] {.compileTime.} =
  if stmts.kind != nnkStmtList:
    result.add rewriteChildExpr(stmts)
    return

  var setupStmts: seq[NimNode] = @[]
  var childStmts: seq[NimNode] = @[]
  for stmt in stmts:
    if isSetupStmt(stmt):
      setupStmts.add stmt
    else:
      childStmts.add stmt

  if setupStmts.len == 0:
    for stmt in childStmts:
      result.add rewriteChildExpr(stmt)
    return

  var blockBody = newStmtList()
  for stmt in setupStmts:
    blockBody.add stmt

  if childStmts.len == 0:
    blockBody.add newNilLit()
  elif childStmts.len == 1:
    blockBody.add rewriteChildExpr(childStmts[0])
  else:
    var fragKids: seq[NimNode] = @[]
    for stmt in childStmts:
      fragKids.add rewriteChildExpr(stmt)
    blockBody.add newCall(ident("fragment"), fragKids)

  result.add newTree(nnkBlockStmt, newEmptyNode(), blockBody)

proc rewriteExprBranch(n: NimNode): NimNode {.compileTime.} =
  if n.kind == nnkStmtList and n.len == 1:
    rewriteUiNode(n[0])
  else:
    rewriteUiNode(n)

proc emptyBracket(): NimNode {.compileTime.} =
  newNimNode(nnkBracket)

proc isSetupStmt(n: NimNode): bool {.compileTime.} =
  n.kind in {nnkLetSection, nnkVarSection, nnkConstSection}

proc buildChildrenNode(children: seq[NimNode]): NimNode {.compileTime.} =
  if children.len == 0:
    return newNilLit()
  if children.len == 1:
    return children[0]
  newCall(ident("fragment"), children)

proc rewriteStmtListAsVNode(n: NimNode): NimNode {.compileTime.} =
  case n.kind
  of nnkStmtList:
    var setupStmts: seq[NimNode] = @[]
    var childNodes: seq[NimNode] = @[]
    for stmt in n:
      if isSetupStmt(stmt):
        setupStmts.add stmt
      else:
        childNodes.add rewriteChildExpr(stmt)

    let childrenNode = buildChildrenNode(childNodes)
    if setupStmts.len == 0:
      return childrenNode

    var blockBody = newStmtList()
    for stmt in setupStmts:
      blockBody.add stmt
    blockBody.add childrenNode
    result = newTree(nnkBlockStmt, newEmptyNode(), blockBody)
  else:
    return rewriteChildExpr(n)

proc collectNodeInto(accSym, nodeExpr: NimNode): NimNode {.compileTime.} =
  let childSym = genSym(nskLet, "uiChild")
  let fragChildSym = genSym(nskForVar, "uiFragChild")
  quote do:
    block:
      let `childSym` = `nodeExpr`
      if `childSym` != nil:
        if `childSym`.kind == vkFragment:
          for `fragChildSym` in `childSym`.children:
            if `fragChildSym` != nil:
              `accSym`.add `fragChildSym`
        else:
          `accSym`.add `childSym`

proc rewriteIfStmt(ifNode: NimNode): NimNode {.compileTime.} =
  var ifExpr = newNimNode(nnkIfExpr)
  var hasElse = false
  for branch in ifNode:
    case branch.kind
    of nnkElifBranch:
      ifExpr.add newTree(
        nnkElifExpr,
        branch[0],
        rewriteStmtListAsVNode(branch[1])
      )
    of nnkElse:
      ifExpr.add newTree(nnkElseExpr, rewriteStmtListAsVNode(branch[0]))
      hasElse = true
    else:
      discard
  if not hasElse:
    ifExpr.add newTree(nnkElseExpr, newNilLit())
  ifExpr

proc rewriteIfExpr(ifNode: NimNode): NimNode {.compileTime.} =
  var ifExpr = newNimNode(nnkIfExpr)
  for branch in ifNode:
    case branch.kind
    of nnkElifExpr:
      ifExpr.add newTree(
        nnkElifExpr,
        branch[0],
        rewriteExprBranch(branch[1])
      )
    of nnkElseExpr:
      ifExpr.add newTree(nnkElseExpr, rewriteExprBranch(branch[0]))
    else:
      discard
  ifExpr

proc rewriteForStmt(forNode: NimNode): NimNode {.compileTime.} =
  let accSym = genSym(nskVar, "uiKids")
  var loopStmt = newNimNode(nnkForStmt)
  for i in 0 ..< forNode.len - 1:
    loopStmt.add forNode[i]
  loopStmt.add collectNodeInto(accSym, rewriteStmtListAsVNode(forNode[^1]))

  quote do:
    block:
      var `accSym`: seq[VNode] = @[]
      `loopStmt`
      fragmentFromSeq(`accSym`)

proc rewriteWhileStmt(whileNode: NimNode): NimNode {.compileTime.} =
  let accSym = genSym(nskVar, "uiKids")
  let loopBody = collectNodeInto(accSym, rewriteStmtListAsVNode(whileNode[1]))
  let loopStmt = newTree(nnkWhileStmt, whileNode[0], loopBody)

  quote do:
    block:
      var `accSym`: seq[VNode] = @[]
      `loopStmt`
      fragmentFromSeq(`accSym`)

proc rewriteCaseStmt(caseNode: NimNode): NimNode {.compileTime.} =
  let outSym = genSym(nskVar, "uiCaseNode")
  var caseStmt = newNimNode(nnkCaseStmt)
  caseStmt.add caseNode[0]

  for i in 1 ..< caseNode.len:
    let branch = caseNode[i]
    case branch.kind
    of nnkOfBranch:
      var ofBranch = newNimNode(nnkOfBranch)
      for j in 0 ..< branch.len - 1:
        ofBranch.add branch[j]
      ofBranch.add newStmtList(
        newTree(nnkAsgn, outSym, rewriteStmtListAsVNode(branch[^1]))
      )
      caseStmt.add ofBranch
    of nnkElse:
      caseStmt.add newTree(
        nnkElse,
        newStmtList(newTree(nnkAsgn, outSym, rewriteStmtListAsVNode(branch[0])))
      )
    else:
      discard

  quote do:
    block:
      var `outSym`: VNode = nil
      `caseStmt`
      `outSym`

proc rewriteWhenStmt(whenNode: NimNode): NimNode {.compileTime.} =
  let outSym = genSym(nskVar, "uiWhenNode")
  var whenStmt = newNimNode(nnkWhenStmt)

  for branch in whenNode:
    case branch.kind
    of nnkElifBranch:
      whenStmt.add newTree(
        nnkElifBranch,
        branch[0],
        newStmtList(newTree(nnkAsgn, outSym, rewriteStmtListAsVNode(branch[1])))
      )
    of nnkElse:
      whenStmt.add newTree(
        nnkElse,
        newStmtList(newTree(nnkAsgn, outSym, rewriteStmtListAsVNode(branch[0])))
      )
    else:
      discard

  quote do:
    block:
      var `outSym`: VNode = nil
      `whenStmt`
      `outSym`

proc rewriteSpecialCall(callNode: NimNode, head: string): NimNode {.compileTime.} =
  case head
  of "text":
    if callNode.len == 2:
      return newCall(ident("text"), rewriteUiNode(callNode[1]))
    return callNode
  of "fragment":
    var args: seq[NimNode] = @[]
    for i in 1 ..< callNode.len:
      let arg = callNode[i]
      if arg.kind == nnkStmtList:
        for childExpr in rewriteStmtListChildren(arg):
          args.add childExpr
      else:
        args.add rewriteChildExpr(arg)
    return newCall(ident("fragment"), args)
  of "portal":
    var selector = newLit("#app")
    var kids: seq[NimNode] = @[]
    for i in 1 ..< callNode.len:
      let arg = callNode[i]
      if arg.kind == nnkStmtList:
        for childExpr in rewriteStmtListChildren(arg):
          kids.add childExpr
      elif selector.kind == nnkStrLit and selector.strVal == "#app":
        selector = rewriteUiNode(arg)
      else:
        kids.add rewriteChildExpr(arg)
    var child: NimNode = newNilLit()
    if kids.len == 1:
      child = kids[0]
    elif kids.len > 1:
      child = newCall(ident("fragment"), kids)
    return newCall(ident("portal"), selector, child)
  of "suspense":
    var fallbackExpr: NimNode = newCall(ident("text"), newLit("Loading..."))
    var keyExpr: NimNode = newLit("")
    var kids: seq[NimNode] = @[]
    var tookFallbackPositional = false
    for i in 1 ..< callNode.len:
      let arg = callNode[i]
      case arg.kind
      of nnkStmtList:
        for childExpr in rewriteStmtListChildren(arg):
          kids.add childExpr
      of nnkExprEqExpr:
        let name = nodeName(arg[0])
        if name == "fallback":
          fallbackExpr = rewriteChildExpr(arg[1])
        elif name == "key":
          keyExpr = newCall(bindSym"$", rewriteUiNode(arg[1]))
        else:
          kids.add rewriteChildExpr(arg)
      else:
        if not tookFallbackPositional:
          fallbackExpr = rewriteChildExpr(arg)
          tookFallbackPositional = true
        else:
          kids.add rewriteChildExpr(arg)
    var childExpr: NimNode = newNilLit()
    if kids.len == 1:
      childExpr = kids[0]
    elif kids.len > 1:
      childExpr = newCall(ident("fragment"), kids)
    return newCall(ident("suspense"), fallbackExpr, childExpr, keyExpr)
  of "customTag":
    var tagExpr = newNilLit()
    var hasTagExpr = false
    var attrs = emptyBracket()
    var events = emptyBracket()
    var children = emptyBracket()
    var keyExpr: NimNode = newLit("")

    for i in 1 ..< callNode.len:
      let arg = callNode[i]
      case arg.kind
      of nnkStmtList:
        for childExpr in rewriteStmtListChildren(arg):
          children.add childExpr
      of nnkExprEqExpr:
        let name = nodeName(arg[0])
        if name == "key":
          keyExpr = newCall(bindSym"$", rewriteUiNode(arg[1]))
        else:
          var eventId = ""
          var capture = false
          if dslEventLookup(name, eventId, capture):
            events.add eventBindingCall(eventId, arg[1], capture)
          elif name.startsWith("on"):
            dslError("unknown event '" & name & "'", arg[0])
          elif name == "ref":
            attrs.add newCall(ident("refProp"), rewriteUiNode(arg[1]))
          else:
            let attrName = normalizeAttrName(name)
            let valueExpr = rewriteUiNode(arg[1])
            if attrName in ["value", "checked", "selected", "disabled"]:
              attrs.add newCall(ident("prop"), newLit(attrName), valueExpr)
            else:
              attrs.add newCall(ident("attr"), newLit(attrName), valueExpr)
      else:
        if arg.kind in {nnkCall, nnkCommand}:
          let helperHead = nodeName(arg[0])
          if helperHead in ["attr", "prop", "styleProp", "boolProp", "refProp"]:
            attrs.add rewriteUiNode(arg)
          elif helperHead == "on":
            events.add rewriteUiNode(arg)
          elif not hasTagExpr:
            tagExpr = rewriteUiNode(arg)
            hasTagExpr = true
            validateCustomTagNameExpr(tagExpr, arg)
          else:
            children.add rewriteChildExpr(arg)
        elif not hasTagExpr:
          tagExpr = rewriteUiNode(arg)
          hasTagExpr = true
          validateCustomTagNameExpr(tagExpr, arg)
        else:
          children.add rewriteChildExpr(arg)

    if not hasTagExpr:
      dslError("customTag requires an explicit tag name argument", callNode)
    return newCall(ident("customTag"), tagExpr, attrs, events, children, keyExpr)
  else:
    callNode

proc rewriteComponentCall(callNode: NimNode, head: string): NimNode {.compileTime.} =
  var keyExpr: NimNode = newLit("")
  var args: seq[NimNode] = @[]
  var children: seq[NimNode] = @[]

  for i in 1 ..< callNode.len:
    let arg = callNode[i]
    case arg.kind
    of nnkStmtList:
      for childExpr in rewriteStmtListChildren(arg):
        children.add childExpr
    of nnkExprEqExpr:
      let name = nodeName(arg[0])
      if name == "key":
        keyExpr = newCall(bindSym"$", rewriteUiNode(arg[1]))
      else:
        args.add newTree(nnkExprEqExpr, arg[0], rewriteUiNode(arg[1]))
    else:
      args.add rewriteUiNode(arg)

  if children.len == 1:
    args.add children[0]
  elif children.len > 1:
    args.add newCall(ident("fragment"), children)

  let renderCall = newCall(callNode[0], args)
  let renderProc = quote do:
    (proc(): VNode =
      `renderCall`
    )

  newCall(ident("component"), renderProc, keyExpr, newLit(head))

proc rewriteTagCall(callNode: NimNode): NimNode {.compileTime.} =
  let headExpr = callNode[0]
  let head = nodeName(headExpr)
  if head.len == 0:
    return callNode

  if head == "text":
    let isTextHelperCall =
      callNode.len == 2 and callNode[1].kind notin {nnkStmtList, nnkExprEqExpr}
    if isTextHelperCall:
      return rewriteSpecialCall(callNode, head)
  elif head in ["fragment", "portal", "suspense", "customTag"]:
    return rewriteSpecialCall(callNode, head)
  elif head in ["attr", "prop", "styleProp", "boolProp", "refProp", "on", "opts"]:
    var rewritten = newCall(callNode[0])
    for i in 1 ..< callNode.len:
      rewritten.add rewriteUiNode(callNode[i])
    return rewritten

  let knownStandardTag = isKnownStandardElement(head)
  let explicitComponentHead =
    headExpr.kind in {nnkDotExpr, nnkOpenSymChoice, nnkClosedSymChoice, nnkBracketExpr}

  if callLooksLikeComponent(callNode, head) and (not knownStandardTag or explicitComponentHead):
    return rewriteComponentCall(callNode, head)

  var looksLikeDslTag = false
  for i in 1 ..< callNode.len:
    if callNode[i].kind in {nnkStmtList, nnkExprEqExpr}:
      looksLikeDslTag = true
      break
    if callNode[i].kind in {nnkCall, nnkCommand}:
      let helperHead = nodeName(callNode[i][0])
      if helperHead in ["attr", "prop", "styleProp", "boolProp", "refProp", "on"]:
        looksLikeDslTag = true
        break
  if not looksLikeDslTag:
    if callNode.len == 1 and knownStandardTag:
      return newCall(
        ident("element"),
        newLit(head),
        emptyBracket(),
        emptyBracket(),
        emptyBracket(),
        newLit("")
      )
    if callNode.len == 1 and head[0] in {'a'..'z'}:
      ensureKnownTag(head, callNode[0])
    var rewritten = newCall(callNode[0])
    for i in 1 ..< callNode.len:
      rewritten.add rewriteUiNode(callNode[i])
    return rewritten

  ensureKnownTag(head, callNode[0])

  var attrs = emptyBracket()
  var events = emptyBracket()
  var children = emptyBracket()
  var keyExpr: NimNode = newLit("")

  for i in 1 ..< callNode.len:
    let arg = callNode[i]
    case arg.kind
    of nnkStmtList:
      for childExpr in rewriteStmtListChildren(arg):
        children.add childExpr
    of nnkExprEqExpr:
      let name = nodeName(arg[0])
      if name == "key":
        keyExpr = newCall(bindSym"$", rewriteUiNode(arg[1]))
      else:
        var eventId = ""
        var capture = false
        if dslEventLookup(name, eventId, capture):
          events.add eventBindingCall(eventId, arg[1], capture)
        elif name.startsWith("on"):
          dslError("unknown event '" & name & "'", arg[0])
        else:
          if name == "ref":
            attrs.add newCall(ident("refProp"), rewriteUiNode(arg[1]))
          else:
            let attrName = normalizeAttrName(name)
            validateAttrNameForTag(head, attrName, arg[0])
            validateAttrConstraintForTag(head, attrName, arg[1], arg[1])
            let valueExpr = rewriteUiNode(arg[1])
            if attrName in ["value", "checked", "selected", "disabled"]:
              attrs.add newCall(ident("prop"), newLit(attrName), valueExpr)
            else:
              attrs.add newCall(ident("attr"), newLit(attrName), valueExpr)
    else:
      if arg.kind in {nnkCall, nnkCommand}:
        let helperHead = nodeName(arg[0])
        if helperHead in ["attr", "prop", "styleProp", "boolProp", "refProp"]:
          let rewrittenHelper = rewriteUiNode(arg)
          if helperHead in ["attr", "prop", "boolProp"] and arg.len >= 3 and isStringLiteralNode(arg[1]):
            let helperAttrName = arg[1].strVal
            validateAttrNameForTag(head, helperAttrName, arg[1])
            if helperHead in ["attr", "prop"]:
              validateAttrConstraintForTag(head, helperAttrName, arg[2], arg[2])
          attrs.add rewrittenHelper
        elif helperHead == "on":
          events.add rewriteUiNode(arg)
        else:
          children.add rewriteChildExpr(arg)
      else:
        children.add rewriteChildExpr(arg)

  newCall(ident("element"), newLit(head), attrs, events, children, keyExpr)

proc rewriteUiNode(n: NimNode): NimNode {.compileTime.} =
  case n.kind
  of nnkStmtList:
    return rewriteStmtListAsVNode(n)
  of nnkCall, nnkCommand:
    return rewriteTagCall(n)
  of nnkIfStmt:
    return rewriteIfStmt(n)
  of nnkIfExpr:
    return rewriteIfExpr(n)
  of nnkForStmt:
    return rewriteForStmt(n)
  of nnkWhileStmt:
    return rewriteWhileStmt(n)
  of nnkCaseStmt:
    return rewriteCaseStmt(n)
  of nnkWhenStmt:
    return rewriteWhenStmt(n)
  else:
    n

macro ui*(body: untyped): untyped =
  rewriteUiNode(body)

export text, fragment, portal, suspense, customTag
