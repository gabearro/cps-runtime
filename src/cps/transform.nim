## CPS Transformation Macro
##
## Transforms normal Nim procedures into continuation-passing style.
## The `cps` macro rewrites a proc so that every "suspend point"
## (calls to other CPS procs via `await`) splits the body into a
## chain of continuation steps.
##
## Supports `await` inside try/except blocks: the future's error is
## re-raised inside a matching try/except so Nim handles dispatch.

import std/[macros, sets, tables, sequtils, sugar]
import ./runtime

template cpsFutureMode*(mode: untyped) {.pragma.}

type
  CpsFutureCtorMode = enum
    fcmLocal
    fcmShared

type
  VarInfo = object
    name: string
    typ: NimNode     # explicit type (may be nnkEmpty)
    defVal: NimNode  # default value expression (may be nnkEmpty)

# ---- NimNode construction helpers ----

proc newIdentDefs(name: NimNode, typ = newEmptyNode(),
                  defVal = newEmptyNode()): NimNode =
  ## Shorthand for nnkIdentDefs.newTree(name, typ, defVal).
  nnkIdentDefs.newTree(name, typ, defVal)

proc newIdentDefs(name: string, typ = newEmptyNode(),
                  defVal = newEmptyNode()): NimNode =
  newIdentDefs(ident(name), typ, defVal)

proc toStmtList(nodes: NimNode): NimNode =
  ## Copy all children of a NimNode into a fresh StmtList.
  result = newStmtList()
  for child in nodes:
    result.add child.copyNimTree()

iterator identDefNames(def: NimNode): NimNode =
  ## Yield the name nodes of an nnkIdentDefs (skipping type and default value).
  ## In `x, y: int = 0`, yields `x` and `y`.
  for j in 0 ..< def.len - 2:
    yield def[j]

proc newVarDecl(name: NimNode, typ = newEmptyNode(),
                defVal = newEmptyNode()): NimNode =
  ## Shorthand for `var name: typ = defVal` as a statement.
  nnkVarSection.newTree(newIdentDefs(name, typ, defVal))

proc isAwaitCall(n: NimNode): bool =
  n.kind in {nnkCall, nnkCommand} and n[0].kind == nnkIdent and $n[0] == "await"

proc isDirectAwaitStmt(s: NimNode): bool =
  ## Check if a statement is a top-level await pattern (not nested).
  s.isAwaitCall or
    (s.kind in {nnkLetSection, nnkVarSection} and
     s[0].kind == nnkIdentDefs and s[0][^1].isAwaitCall) or
    (s.kind == nnkDiscardStmt and s[0].isAwaitCall) or
    (s.kind == nnkAsgn and s[1].isAwaitCall)

proc hasNestedAwait(n: NimNode): bool =
  ## Check if any descendant node is an await call.
  n.isAwaitCall or n.anyIt(hasNestedAwait(it))

proc liftAwaitInBody(body: NimNode): NimNode
var tryFinallyCounter {.compileTime.}: int = 0

proc findUnsupportedTryFinallyControl(n: NimNode): NimNode =
  ## Find unsupported control transfer inside transformed try/finally code.
  case n.kind
  of nnkProcDef, nnkFuncDef, nnkLambda, nnkDo:
    return nil
  of nnkReturnStmt, nnkBreakStmt, nnkContinueStmt:
    return n
  else:
    for child in n:
      let bad = findUnsupportedTryFinallyControl(child)
      if bad != nil:
        return bad
  return nil

proc findUnsafeTryFinallyProtectedControl(n: NimNode; inLoop = false): NimNode =
  ## Find control transfer that can escape the lowered protected body and
  ## bypass appended finally statements.
  case n.kind
  of nnkProcDef, nnkFuncDef, nnkLambda, nnkDo:
    return nil
  of nnkReturnStmt:
    return n
  of nnkBreakStmt:
    if n.len > 0 and n[0].kind != nnkEmpty:
      return n
    if not inLoop:
      return n
    return nil
  of nnkContinueStmt:
    if not inLoop:
      return n
    return nil
  else:
    let nextInLoop = inLoop or n.kind in {nnkWhileStmt, nnkForStmt}
    for child in n:
      let bad = findUnsafeTryFinallyProtectedControl(child, nextInLoop)
      if bad != nil:
        return bad
  return nil

proc lowerTryFinallyStmt(s: NimNode): NimNode =
  ## Lower try/except/else/finally into CPS-safe try/except + trailing finally body.
  ## This keeps finally execution on both success and exception paths while
  ## preserving await support through existing try/except splitting logic.
  expectKind s, nnkTryStmt

  var finallyBody: NimNode = nil
  var elseBody: NimNode = nil
  let liftedTryBody = liftAwaitInBody(s[0])
  var innerExcepts: seq[NimNode]

  for i in 1 ..< s.len:
    let branch = s[i]
    case branch.kind
    of nnkExceptBranch:
      var newExcept = nnkExceptBranch.newTree()
      for j in 0 ..< branch.len - 1:
        newExcept.add branch[j].copyNimTree()
      newExcept.add liftAwaitInBody(branch[^1])
      innerExcepts.add newExcept
    of nnkElse:
      if elseBody != nil:
        error("Unsupported CPS try/finally: multiple else branches", branch)
      elseBody = liftAwaitInBody(branch[0])
    of nnkFinally:
      if finallyBody != nil:
        error("Unsupported CPS try/finally: multiple finally branches", branch)
      finallyBody = branch[0]
    else:
      error("Unsupported CPS try/finally branch kind: " & $branch.kind, branch)

  var innerTryBody = liftedTryBody.toStmtList()
  var elseFlagSym: NimNode = nil
  if elseBody != nil:
    let elseId = $tryFinallyCounter
    elseFlagSym = ident("_cpsTryElseRan_" & elseId)
    innerTryBody.add newAssignment(elseFlagSym, newLit(true))

  # Build the core body: either raw stmts or wrapped in try/except
  proc buildCoreBody(): NimNode =
    if innerExcepts.len > 0:
      result = nnkTryStmt.newTree(innerTryBody)
      for eb in innerExcepts:
        result.add eb.copyNimTree()
    else:
      result = innerTryBody.toStmtList()

  # Wrap a body node in a StmtList with else-guard var decl + if check.
  # Always returns a StmtList for use as a try body.
  proc wrapWithElseGuard(body: NimNode): NimNode =
    result = newStmtList()
    if elseBody != nil:
      result.add newVarDecl(elseFlagSym.copyNimTree(), ident"bool", newLit(false))
    if body.kind == nnkStmtList:
      for s in body: result.add s
    else:
      result.add body
    if elseBody != nil:
      result.add nnkIfStmt.newTree(
        nnkElifBranch.newTree(elseFlagSym.copyNimTree(), elseBody.copyNimTree()))

  if finallyBody == nil:
    return wrapWithElseGuard(buildCoreBody())

  var protectedBody = wrapWithElseGuard(buildCoreBody())

  let badFinally = findUnsupportedTryFinallyControl(finallyBody)
  if badFinally != nil:
    error("Unsupported CPS try/finally control transfer: return/break/continue inside finally is not supported", badFinally)

  # Return is never safe in lowered protected bodies. break/continue are only
  # safe when they target loops nested inside the protected body.
  let badTryBody = findUnsafeTryFinallyProtectedControl(protectedBody)
  if badTryBody != nil:
    error("Unsupported CPS try/finally control transfer: return or escaping break/continue inside try/except/else body is not supported", badTryBody)

  let liftedFinally = liftAwaitInBody(finallyBody)
  let finallyId = $tryFinallyCounter
  inc tryFinallyCounter
  let hadExcSym = ident("_cpsFinallyHadExc_" & finallyId)
  let excSym = ident("_cpsFinallyExc_" & finallyId)
  let caughtSym = ident("_cpsFinallyCaught_" & finallyId)

  result = newStmtList()
  result.add newVarDecl(hadExcSym, ident"bool", newLit(false))
  result.add newVarDecl(excSym, nnkRefTy.newTree(ident"CatchableError"), newNilLit())

  var tryNode = nnkTryStmt.newTree(protectedBody)

  var catchBody = newStmtList()
  catchBody.add newAssignment(hadExcSym, newLit(true))
  catchBody.add newAssignment(excSym, caughtSym)
  tryNode.add nnkExceptBranch.newTree(
    nnkInfix.newTree(ident"as", ident"CatchableError", caughtSym),
    catchBody
  )
  result.add tryNode

  for fs in liftedFinally:
    result.add fs.copyNimTree()

  result.add nnkIfStmt.newTree(
    nnkElifBranch.newTree(
      hadExcSym.copyNimTree(),
      newStmtList(nnkRaiseStmt.newTree(excSym.copyNimTree()))
    )
  )
  return result

var liftAwaitCounter {.compileTime.}: int = 0

proc isControlTransferStmt(n: NimNode): bool =
  n.kind in {nnkReturnStmt, nnkBreakStmt, nnkContinueStmt, nnkRaiseStmt}

proc desugarAwaitTryExprBinding(s: NimNode): seq[NimNode] =
  ## Rewrites:
  ##   let x = try: ... except: ...
  ## into:
  ##   var _tmp: T
  ##   try: _tmp = ...
  ##   except: ...
  ##   let x = _tmp
  ##
  ## This preserves try/except semantics while making awaits visible to the
  ## CPS splitter as top-level await statements inside a try block.
  if s.kind notin {nnkLetSection, nnkVarSection} or s.len != 1:
    return @[]
  let def = s[0]
  if def.kind != nnkIdentDefs or def.len < 3:
    return @[]
  if def.len != 3:
    error("CPS macro does not support multi-binding let/var with await in try expression; split declarations", s)
  let rhs = def[^1]
  if rhs.kind != nnkTryStmt or not hasNestedAwait(rhs):
    return @[]

  let tryBody = rhs[0]
  if tryBody.kind != nnkStmtList or tryBody.len == 0:
    error("CPS macro requires non-empty try body for await try-expression binding", rhs)

  let tryValue = tryBody[^1]
  var tmpType: NimNode
  if def[1].kind != nnkEmpty:
    tmpType = def[1].copyNimTree()
  else:
    if isControlTransferStmt(tryValue):
      error("CPS macro cannot infer type for await try-expression binding whose try body ends with control transfer; add an explicit type", s)
    if tryValue.isAwaitCall:
      tmpType = nnkCall.newTree(
        ident"typeof",
        nnkCall.newTree(ident"read", tryValue[1].copyNimTree())
      )
    else:
      tmpType = nnkCall.newTree(ident"typeof", tryValue.copyNimTree())

  let tmpName = ident("_cpsTryExprTmp_" & $liftAwaitCounter)
  inc liftAwaitCounter

  proc assignOrKeep(tmp: NimNode, n: NimNode): NimNode =
    if isControlTransferStmt(n):
      n.copyNimTree()
    else:
      nnkAsgn.newTree(tmp.copyNimTree(), n.copyNimTree())

  proc rewriteLastToAssign(body: NimNode): NimNode =
    ## Copy a branch body, replacing the last expression with an assignment to tmpName.
    result = newStmtList()
    if body.kind == nnkStmtList and body.len > 0:
      for j in 0 ..< body.len - 1:
        result.add body[j].copyNimTree()
      result.add assignOrKeep(tmpName, body[^1])
    elif body.kind != nnkStmtList:
      result.add assignOrKeep(tmpName, body)

  var rewrittenTry = nnkTryStmt.newTree(rewriteLastToAssign(tryBody))
  for i in 1 ..< rhs.len:
    let branch = rhs[i]
    case branch.kind
    of nnkExceptBranch:
      var eb = nnkExceptBranch.newTree()
      for j in 0 ..< branch.len - 1:
        eb.add branch[j].copyNimTree()
      eb.add rewriteLastToAssign(branch[^1])
      rewrittenTry.add eb
    of nnkElse:
      rewrittenTry.add nnkElse.newTree(rewriteLastToAssign(branch[0]))
    else:
      rewrittenTry.add branch.copyNimTree()

  let tmpDecl = newVarDecl(tmpName.copyNimTree(),
                           defVal = nnkCall.newTree(ident"default", tmpType.copyNimTree()))
  let bindingKind = if s.kind == nnkLetSection: nnkLetSection else: nnkVarSection
  let finalBinding = bindingKind.newTree(
    newIdentDefs(def[0].copyNimTree(), def[1].copyNimTree(), tmpName.copyNimTree()))

  result = @[tmpDecl, rewrittenTry, finalBinding]

proc liftAwaitArgs(n: NimNode, lifted: var seq[NimNode]): NimNode =
  ## Recursively walk an expression and lift any `await` calls that appear
  ## as arguments to other calls into preceding `let` statements.
  ## Returns the rewritten expression with awaits replaced by temp idents.
  ## Does NOT lift top-level awaits (those are handled by splitStmtForAwait).
  if n.isAwaitCall:
    # This is an await nested inside something else — lift it
    let tmpName = ident("_cpsAwaitArg_" & $liftAwaitCounter)
    inc liftAwaitCounter
    lifted.add nnkLetSection.newTree(
      newIdentDefs(tmpName, defVal = n.copyNimTree())
    )
    return tmpName
  case n.kind
  of nnkProcDef, nnkFuncDef, nnkLambda, nnkDo:
    return n.copyNimTree()  # Don't descend into nested procs
  else:
    result = n.copyNimNode()
    for child in n:
      result.add liftAwaitArgs(child, lifted)

proc liftAwaitInStmt(s: NimNode): seq[NimNode] =
  ## If a statement has await calls nested inside call arguments (not at
  ## the top level), hoist them into preceding let statements.
  ## Returns one or more statements (the lifts + the rewritten original).

  let desugaredTryBinding = desugarAwaitTryExprBinding(s)
  if desugaredTryBinding.len > 0:
    return desugaredTryBinding

  # Top-level patterns already handled by splitStmtForAwait — skip them
  if isDirectAwaitStmt(s) or (s.kind == nnkReturnStmt and s[0].isAwaitCall):
    return @[s]

  # Check if there's a nested await that needs lifting
  if not hasNestedAwait(s):
    return @[s]

  var lifted: seq[NimNode]
  let rewritten = liftAwaitArgs(s, lifted)
  if lifted.len > 0:
    result = lifted
    result.add rewritten
  else:
    result = @[s]

proc liftAwaitInBody(body: NimNode): NimNode =
  ## Pre-process a statement list, lifting nested await-in-argument calls.
  ## Recurses into if/while/for/try bodies.
  result = newStmtList()
  for s in body:
    case s.kind
    of nnkIfStmt:
      var newIf = nnkIfStmt.newTree()
      for branch in s:
        if branch.kind == nnkElifBranch:
          newIf.add nnkElifBranch.newTree(
            branch[0].copyNimTree(),
            liftAwaitInBody(branch[1])
          )
        elif branch.kind == nnkElse:
          newIf.add nnkElse.newTree(liftAwaitInBody(branch[0]))
        else:
          newIf.add branch.copyNimTree()
      result.add newIf
    of nnkWhileStmt:
      result.add nnkWhileStmt.newTree(
        s[0].copyNimTree(),
        liftAwaitInBody(s[1])
      )
    of nnkForStmt:
      var newFor = nnkForStmt.newTree()
      for i in 0 ..< s.len - 1:
        newFor.add s[i].copyNimTree()
      newFor.add liftAwaitInBody(s[^1])
      result.add newFor
    of nnkTryStmt:
      let hasFinally = s.anyIt(it.kind == nnkFinally)
      if hasFinally:
        let loweredTry = lowerTryFinallyStmt(s)
        for loweredStmt in loweredTry:
          result.add loweredStmt
        continue

      var newTry = nnkTryStmt.newTree()
      newTry.add liftAwaitInBody(s[0])
      for i in 1 ..< s.len:
        let branch = s[i]
        if branch.kind == nnkExceptBranch:
          var newExcept = nnkExceptBranch.newTree()
          for j in 0 ..< branch.len - 1:
            newExcept.add branch[j].copyNimTree()
          newExcept.add liftAwaitInBody(branch[^1])
          newTry.add newExcept
        elif branch.kind == nnkElse:
          newTry.add nnkElse.newTree(liftAwaitInBody(branch[0]))
        else:
          newTry.add branch.copyNimTree()
      result.add newTry
    of nnkBlockStmt:
      result.add nnkBlockStmt.newTree(
        s[0].copyNimTree(),
        liftAwaitInBody(s[1])
      )
    of nnkCaseStmt:
      var newCase = nnkCaseStmt.newTree(s[0].copyNimTree())
      for i in 1 ..< s.len:
        let branch = s[i]
        if branch.kind == nnkOfBranch:
          var newOf = nnkOfBranch.newTree()
          for j in 0 ..< branch.len - 1:
            newOf.add branch[j].copyNimTree()
          newOf.add liftAwaitInBody(branch[^1])
          newCase.add newOf
        elif branch.kind == nnkElse:
          newCase.add nnkElse.newTree(liftAwaitInBody(branch[0]))
        elif branch.kind == nnkElifBranch:
          newCase.add nnkElifBranch.newTree(
            branch[0].copyNimTree(),
            liftAwaitInBody(branch[1]))
        else:
          newCase.add branch.copyNimTree()
      result.add newCase
    else:
      let expanded = liftAwaitInStmt(s)
      for e in expanded:
        result.add e

proc getContainerExpr(iterExpr: NimNode): NimNode =
  ## Unwrap items/pairs/mitems/mpairs wrappers to get the underlying container.
  if iterExpr.kind == nnkCall and iterExpr.len == 2:
    if $iterExpr[0] in ["items", "mitems", "pairs", "mpairs"]:
      return iterExpr[1]
  if iterExpr.kind == nnkDotExpr:
    if $iterExpr[1] in ["items", "mitems", "pairs", "mpairs"]:
      return iterExpr[0]
  return iterExpr

proc desugarRangeFor(loopVar, startVal, endVal, body: NimNode,
                     offsetOp, breakCmpOp, stepCmd: string): NimNode =
  ## Common helper for range-based for-loop desugaring.
  ## Generates: var _cpsEnd = endVal; var loopVar = startVal ± 1; while true: step; if cmp: break; <body>
  let endVar = ident("_cpsEnd_" & $loopVar)
  result = newStmtList()
  result.add newVarDecl(endVar, defVal = endVal.copyNimTree())
  result.add newVarDecl(loopVar.copyNimTree(), defVal =
    nnkInfix.newTree(ident(offsetOp), startVal.copyNimTree(), newIntLitNode(1)))
  var whileBody = newStmtList()
  whileBody.add nnkCommand.newTree(ident(stepCmd), loopVar.copyNimTree())
  whileBody.add nnkIfStmt.newTree(
    nnkElifBranch.newTree(
      nnkInfix.newTree(ident(breakCmpOp), loopVar.copyNimTree(), endVar.copyNimTree()),
      newStmtList(nnkBreakStmt.newTree(newEmptyNode()))))
  for s in body:
    whileBody.add s.copyNimTree()
  result.add nnkWhileStmt.newTree(ident"true", whileBody)

proc desugarFor(forStmt: NimNode): NimNode =
  ## Desugar range-based `for` into `var + while true + inc/break` for CPS splitting.
  ## The increment is placed at the TOP of the loop body so that `continue`
  ## does not skip it (classic pre-increment desugaring).
  ##
  ## Supports: for i in a..<b, for i in a..b, for i in countdown(b, a)
  ## Returns a stmtList of the desugared code, or nil if unsupported.
  expectKind forStmt, nnkForStmt
  let loopVar = forStmt[0]
  let iterExpr = forStmt[^2]
  let body = forStmt[^1]

  # for i in a ..< b
  if iterExpr.kind == nnkInfix and $iterExpr[0] == "..<":
    return desugarRangeFor(loopVar, iterExpr[1], iterExpr[2], body, "-", ">=", "inc")

  # for i in a .. b
  if iterExpr.kind == nnkInfix and $iterExpr[0] == "..":
    return desugarRangeFor(loopVar, iterExpr[1], iterExpr[2], body, "-", ">", "inc")

  # for i in countdown(b, a) — startVal is high, endVal is low
  if iterExpr.kind == nnkCall and $iterExpr[0] == "countdown" and iterExpr.len >= 3:
    return desugarRangeFor(loopVar, iterExpr[1], iterExpr[2], body, "+", "<", "dec")

  # Fallback: iterable container (seq, array, string)
  let numVars = forStmt.len - 2
  let containerExpr = getContainerExpr(iterExpr)
  if numVars notin {1, 2}:
    return nil

  # Name used for internal variable naming (element var name)
  let elemName = if numVars == 2: $forStmt[1] else: $forStmt[0]
  let contVar = ident("_cpsCont_" & elemName)
  let idxVar = ident("_cpsForIdx_" & elemName)

  result = newStmtList()
  result.add newVarDecl(contVar, defVal = containerExpr.copyNimTree())
  result.add newVarDecl(idxVar, defVal = newIntLitNode(-1))

  var whileBody = newStmtList()
  whileBody.add nnkCommand.newTree(ident"inc", idxVar.copyNimTree())
  whileBody.add nnkIfStmt.newTree(
    nnkElifBranch.newTree(
      nnkInfix.newTree(ident">=", idxVar.copyNimTree(),
        nnkCall.newTree(ident"len", contVar.copyNimTree())),
      newStmtList(nnkBreakStmt.newTree(newEmptyNode()))))
  if numVars == 2:
    whileBody.add newVarDecl(forStmt[0].copyNimTree(), defVal = idxVar.copyNimTree())
  let elemVar = if numVars == 2: forStmt[1] else: forStmt[0]
  whileBody.add newVarDecl(elemVar.copyNimTree(), defVal =
    nnkBracketExpr.newTree(contVar.copyNimTree(), idxVar.copyNimTree()))
  for s in body:
    whileBody.add s.copyNimTree()
  result.add nnkWhileStmt.newTree(ident"true", whileBody)

type
  ExceptBranch = object
    types: seq[NimNode]  # exception types (empty seq = bare except)
    asVar: string        # "as" variable name (empty = none)
    body: NimNode        # handler body (nnkStmtList)
    hasAwait: bool              # handler body contains await
    handlerContStartIdx: int    # first continuation segment for handler (-1 if no await)
    handlerContCount: int       # number of continuation segments for handler

proc extractExceptBranches(tryStmt: NimNode): seq[ExceptBranch] =
  ## Extract except branches from a nnkTryStmt node.
  for i in 1 ..< tryStmt.len:
    let branch = tryStmt[i]
    if branch.kind == nnkExceptBranch:
      var eb: ExceptBranch
      eb.body = branch[^1]
      for j in 0 ..< branch.len - 1:
        let expr = branch[j]
        if expr.kind == nnkInfix and $expr[0] == "as":
          eb.types.add expr[1]
          eb.asVar = $expr[2]
        else:
          eb.types.add expr
      result.add eb

proc rebuildTryExcept(stmts: seq[NimNode], branches: seq[ExceptBranch]): NimNode =
  ## Wrap statements in a try/except with the given except branches.
  ## Used for synchronous code inside a try body (between/after awaits).
  ## For except handlers with await, generates a _cpsHandlerJump marker
  ## instead of copying the handler body (which contains await calls that
  ## can't be processed in Phase 3).
  if stmts.len == 0: return newStmtList()
  var tryNode = nnkTryStmt.newTree()
  var body = newStmtList()
  for s in stmts: body.add s
  tryNode.add body
  for branch in branches:
    var eb = nnkExceptBranch.newTree()

    if branch.hasAwait and branch.handlerContStartIdx >= 0:
      # Handler has await — generate transition code instead of handler body.
      # Use a local binding to capture the exception, store it in the env via
      # the asVar name (rewrite() will transform it to env.asVar), then use
      # _cpsHandlerJump(stepIdx) as a marker for rewrite() to generate
      # the actual step transition.
      let excLocal = ident"_cpsExcLocal"
      if branch.types.len > 0:
        for t in branch.types:
          eb.add nnkInfix.newTree(ident"as", t.copyNimTree(), excLocal)
      else:
        eb.add nnkInfix.newTree(ident"as", ident"CatchableError", excLocal)

      var handlerBody = newStmtList()
      if branch.asVar != "":
        handlerBody.add newAssignment(ident(branch.asVar), excLocal)
      handlerBody.add nnkCall.newTree(
        ident"_cpsHandlerJump",
        newLit(branch.handlerContStartIdx))
      eb.add handlerBody
    else:
      # Normal handler (no await) — copy the handler body
      if branch.types.len > 0:
        for t in branch.types:
          if branch.asVar != "":
            eb.add nnkInfix.newTree(ident"as", t.copyNimTree(), ident(branch.asVar))
          else:
            eb.add t.copyNimTree()
      eb.add branch.body.copyNimTree()
    tryNode.add eb
  return tryNode

proc collectLocals(body: NimNode, vars: var seq[VarInfo]) =
  for n in body:
    case n.kind
    of nnkVarSection, nnkLetSection:
      for def in n:
        if def.kind == nnkIdentDefs:
          let typ = def[^2]
          let defVal = def[^1]
          for nameNode in def.identDefNames:
            # Skip vars that are await results (handled separately),
            # UNLESS they have an explicit type annotation — in that case
            # collect them so the explicit type is used for the env field
            # instead of typeof (which may not work in generic contexts).
            if defVal.isAwaitCall:
              if typ.kind != nnkEmpty:
                vars.add VarInfo(name: $nameNode, typ: typ, defVal: newEmptyNode())
              continue
            vars.add VarInfo(name: $nameNode, typ: typ, defVal: defVal)
    of nnkForStmt:
      # If the for loop has nested await, it will be desugared to var+while+inc.
      # Collect the loop variable(s) so they get env fields.
      if hasNestedAwait(n):
        let iterExpr = n[^2]
        let numVars = n.len - 2

        let isRange = (iterExpr.kind == nnkInfix and $iterExpr[0] in ["..<", ".."]) or
                      (iterExpr.kind == nnkCall and $iterExpr[0] == "countdown" and iterExpr.len >= 3)

        if isRange and numVars == 1:
          let loopVar = $n[0]
          vars.add VarInfo(name: "_cpsEnd_" & loopVar, typ: newEmptyNode(), defVal: iterExpr[2])
          vars.add VarInfo(name: loopVar, typ: newEmptyNode(), defVal: iterExpr[1])
        elif numVars in {1, 2}:
          # Iterable container: add container capture, internal index, element var
          let elemName = if numVars == 2: $n[1] else: $n[0]
          let container = getContainerExpr(iterExpr)
          vars.add VarInfo(name: "_cpsCont_" & elemName, typ: newEmptyNode(), defVal: container.copyNimTree())
          vars.add VarInfo(name: "_cpsForIdx_" & elemName, typ: ident"int", defVal: newEmptyNode())
          if numVars == 2:
            vars.add VarInfo(name: $n[0], typ: ident"int", defVal: newEmptyNode())
          vars.add VarInfo(name: elemName, typ: newEmptyNode(),
                           defVal: nnkBracketExpr.newTree(container.copyNimTree(), newIntLitNode(0)))

        collectLocals(n[^1], vars)
    of nnkExceptBranch:
      # Locals in except handlers only need env storage when that handler
      # itself crosses an await boundary. Collecting sync-only handlers causes
      # type inference to reference out-of-scope `as` bindings.
      if n.len > 0 and hasNestedAwait(n[^1]):
        collectLocals(n[^1], vars)
    else:
      if n.len > 0:
        collectLocals(n, vars)

type
  SegmentKind = enum
    skNormal        # Existing linear segment
    skIfDispatch    # If/elif/else condition evaluation + dispatch
    skWhileEntry    # While condition check + body first chunk

  IfBranchInfo = object
    condition: NimNode          # nnkEmpty for else
    preStmts: seq[NimNode]      # Sync stmts before first await (or all stmts if no await)
    hasAwait: bool
    awaitExpr: NimNode
    awaitTarget: string
    contStartIdx: int           # First continuation segment index (-1 if no await)
    contCount: int              # Number of continuation segments for this branch
    exceptBranches: seq[ExceptBranch]  # If await is inside try within branch

  Segment = object
    kind: SegmentKind
    # skNormal fields:
    preStmts: seq[NimNode]
    hasAwait: bool
    awaitExpr: NimNode       # the future expression (e.g., makeValue())
    awaitTarget: string      # variable name for result ("" if none)
    exceptBranches: seq[ExceptBranch]  # non-empty = await is inside try/except
    afterTryIdx: int         # step index to jump to from except handler (-1 = N/A)
    overrideNextIdx: int     # -1 = default (i+1), >= 0 = explicit target
    breakTargetIdx: int      # -1 = not in loop, else step for break
    continueTargetIdx: int   # -1 = not in loop, else step for continue
    # skIfDispatch fields:
    ifBranches: seq[IfBranchInfo]
    afterIfIdx: int
    # skWhileEntry fields:
    whileCond: NimNode
    whileBodyBranch: IfBranchInfo   # reuses IfBranchInfo for body
    afterWhileIdx: int
    whileCondStepIdx: int           # self-index for loop-back

proc addAwaitSegment(segments: var seq[Segment], currentPre: var seq[NimNode],
                     awaitExpr: NimNode, awaitTarget: string,
                     exceptBranches: seq[ExceptBranch] = @[],
                     breakTargetIdx: int = -1,
                     continueTargetIdx: int = -1) =
  ## Helper to add an await segment and reset currentPre.
  segments.add Segment(
    kind: skNormal,
    preStmts: currentPre,
    hasAwait: true,
    awaitExpr: awaitExpr,
    awaitTarget: awaitTarget,
    exceptBranches: exceptBranches,
    afterTryIdx: -1,
    overrideNextIdx: -1,
    breakTargetIdx: breakTargetIdx,
    continueTargetIdx: continueTargetIdx,
    afterIfIdx: -1,
    afterWhileIdx: -1
  )
  currentPre = @[]

proc collectAwaitTargets(segments: seq[Segment]): seq[(string, NimNode)] =
  ## Collect all (awaitTarget, awaitExpr) pairs from segments, including
  ## those nested inside if-dispatch branches and while-entry bodies.
  for seg in segments:
    if seg.hasAwait and seg.awaitTarget != "":
      result.add (seg.awaitTarget, seg.awaitExpr)
    if seg.kind == skIfDispatch:
      for branch in seg.ifBranches:
        if branch.hasAwait and branch.awaitTarget != "":
          result.add (branch.awaitTarget, branch.awaitExpr)
    if seg.kind == skWhileEntry:
      if seg.whileBodyBranch.hasAwait and seg.whileBodyBranch.awaitTarget != "":
        result.add (seg.whileBodyBranch.awaitTarget, seg.whileBodyBranch.awaitExpr)

proc splitStmtForAwait(s: NimNode, segments: var seq[Segment],
                       currentPre: var seq[NimNode],
                       exceptBranches: seq[ExceptBranch] = @[],
                       trySegIndices: var seq[int]): bool =
  ## Try to split a statement at an await point. Returns true if handled.
  template emitAwait(futExpr, target: untyped) =
    addAwaitSegment(segments, currentPre, futExpr, target, exceptBranches)
    if exceptBranches.len > 0:
      trySegIndices.add segments.len - 1
    return true

  if s.kind in {nnkLetSection, nnkVarSection}:
    let def = s[0]
    if def.kind == nnkIdentDefs and def[^1].isAwaitCall:
      emitAwait(def[^1][1], $def[0])
  if s.isAwaitCall:
    emitAwait(s[1], "")
  if s.kind == nnkDiscardStmt and s[0].isAwaitCall:
    emitAwait(s[0][1], "")
  if s.kind == nnkAsgn and s[1].isAwaitCall:
    emitAwait(s[1][1], $s[0])
  return false

macro cps*(prc: untyped): untyped =
  expectKind prc, nnkProcDef

  let procName = prc[0]
  let params = prc[3]
  let body = liftAwaitInBody(prc[6])
  let returnType = params[0]
  let procPragmas = prc[4]

  var futureCtorMode =
    when defined(cpsSharedFuturesOnly):
      fcmShared
    else:
      fcmShared

  if procPragmas.kind == nnkPragma:
    for pragma in procPragmas:
      if pragma.kind == nnkExprColonExpr and pragma.len == 2 and
         pragma[0].kind == nnkIdent and $pragma[0] == "cpsFutureMode":
        let modeNode = pragma[1]
        if modeNode.kind != nnkIdent:
          error("cpsFutureMode must be 'local' or 'shared'", modeNode)
        let modeName = $modeNode
        if modeName == "shared":
          futureCtorMode = fcmShared
        elif modeName == "local":
          when defined(cpsSharedFuturesOnly):
            futureCtorMode = fcmShared
          else:
            futureCtorMode = fcmLocal
        else:
          error("cpsFutureMode must be 'local' or 'shared'", modeNode)

  # Extract base name without export marker for generating internal identifiers
  let procBaseName = if procName.kind == nnkPostfix: $procName[1] else: $procName
  let cpsContractErrorSym = ident"CpsContractError"
  let missingReturnMsg = newLit(
    "CPS contract violation: non-void CPS proc '" &
    procBaseName &
    "' reached end without return"
  )

  # Extract generic parameters
  let genericParams = prc[2]  # nnkGenericParams or nnkEmpty
  let isGeneric = genericParams.kind == nnkGenericParams
  let genericIdents = if isGeneric:
    collect:
      for param in genericParams:
        for nameNode in param.identDefNames:
          nameNode
  else:
    newSeq[NimNode]()

  proc makeGenericInst(baseName: NimNode): NimNode =
    if isGeneric:
      var bracket = nnkBracketExpr.newTree(baseName)
      for gi in genericIdents:
        bracket.add gi.copyNimTree()
      return bracket
    else:
      return baseName

  var innerResultType: NimNode
  var isVoid: bool
  var futureType: NimNode
  let newTypedFutureSym =
    if futureCtorMode == fcmShared: bindSym"newCpsFuture"
    else: bindSym"newLocalCpsFuture"
  let newVoidFutureSym =
    if futureCtorMode == fcmShared: bindSym"newCpsVoidFuture"
    else: bindSym"newLocalCpsVoidFuture"
  let completedTypedFutureSym =
    if futureCtorMode == fcmShared: bindSym"completedFuture"
    else: bindSym"completedLocalFuture"
  let completedVoidFutureSym =
    if futureCtorMode == fcmShared: bindSym"completedVoidFuture"
    else: bindSym"completedLocalVoidFuture"
  let failedTypedFutureSym =
    if futureCtorMode == fcmShared: bindSym"failedFuture"
    else: bindSym"failedLocalFuture"
  let failedVoidFutureSym =
    if futureCtorMode == fcmShared: bindSym"failedVoidFuture"
    else: bindSym"failedLocalVoidFuture"

  proc addUnreachableWarningPragma(procNode: NimNode) =
    ## CPS lowering intentionally emits terminal transitions (`return env`) in
    ## many branches; Nim's static analysis can report false positive
    ## `UnreachableCode` warnings at macro expansion sites. Scope suppression to
    ## generated CPS procs only.
    if procNode.kind != nnkProcDef:
      return
    var pragmaNode = procNode[4]
    if pragmaNode.kind == nnkEmpty:
      pragmaNode = nnkPragma.newTree()
    pragmaNode.add nnkExprColonExpr.newTree(
      nnkBracketExpr.newTree(ident"warning", ident"UnreachableCode"),
      bindSym"off"
    )
    pragmaNode.add nnkExprColonExpr.newTree(
      nnkBracketExpr.newTree(ident"hint", ident"XDeclaredButNotUsed"),
      bindSym"off"
    )
    procNode[4] = pragmaNode

  proc buildWrapperParams(): seq[NimNode] =
    result = @[returnType]
    for i in 1 ..< params.len:
      result.add params[i].copyNimTree()  # skip return type (params[0])

  proc applyGenericParams(procNode: NimNode) =
    if isGeneric:
      procNode[2] = genericParams.copyNimTree()

  if returnType.kind == nnkEmpty or
     (returnType.kind == nnkIdent and $returnType == "void"):
    isVoid = true
    futureType = ident"CpsVoidFuture"
    innerResultType = newEmptyNode()
  elif returnType.kind == nnkBracketExpr and $returnType[0] == "CpsFuture":
    isVoid = false
    innerResultType = returnType[1]
    futureType = returnType
  elif returnType.kind == nnkIdent and $returnType == "CpsVoidFuture":
    isVoid = true
    futureType = ident"CpsVoidFuture"
    innerResultType = newEmptyNode()
  else:
    error("CPS proc must return CpsFuture[T] or CpsVoidFuture", prc)

  # Check for `result` usage in the proc body (conflicts with step function return value)
  proc checkForResult(n: NimNode) =
    case n.kind
    of nnkProcDef, nnkFuncDef, nnkLambda, nnkDo:
      discard  # Don't descend into nested procs/lambdas
    of nnkIdent:
      if $n == "result":
        error("CPS procs cannot use 'result' — it conflicts with the step function's return value. Use an explicit variable and 'return' instead.", n)
    else:
      for child in n:
        checkForResult(child)
  checkForResult(body)

  # ============================================================
  # Fast path: No-await CPS procs skip env/step/trampoline entirely
  # ============================================================
  if not hasNestedAwait(body):
    # Rewrite `return expr` → `return completedFuture[T](expr)`
    # Rewrite `return` → `return completedVoidFuture()`
    # Don't descend into nested procs/lambdas.
    proc rewriteReturns(n: NimNode): NimNode =
      case n.kind
      of nnkProcDef, nnkFuncDef, nnkLambda, nnkDo:
        return n  # don't rewrite returns inside nested procs
      of nnkReturnStmt:
        if isVoid or n[0].kind == nnkEmpty:
          return nnkReturnStmt.newTree(newCall(completedVoidFutureSym))
        else:
          return nnkReturnStmt.newTree(
            nnkBracketExpr.newTree(completedTypedFutureSym, innerResultType).newCall(n[0])
          )
      else:
        result = n.copyNimNode()
        for child in n:
          result.add rewriteReturns(child)

    let rewrittenBody = rewriteReturns(body)
    var fastBody = newStmtList()

    if isVoid:
      let e = ident"e"
      fastBody.add quote do:
        try:
          `rewrittenBody`
          return `completedVoidFutureSym`()
        except CatchableError as `e`:
          return `failedVoidFutureSym`(`e`)
    else:
      let e = ident"e"
      # For typed procs, the body should contain return statements (rewritten above).
      # The try/except catches any raised exceptions and returns a failed future.
      fastBody.add quote do:
        try:
          `rewrittenBody`
          return `failedTypedFutureSym`[`innerResultType`](
            newException(`cpsContractErrorSym`, `missingReturnMsg`)
          )
        except CatchableError as `e`:
          return `failedTypedFutureSym`[`innerResultType`](`e`)

    let fastProc = newProc(name = procName, params = buildWrapperParams(), body = fastBody)
    addUnreachableWarningPragma(fastProc)
    applyGenericParams(fastProc)
    return newStmtList(fastProc)

  # Collect proc parameters
  let procParams = collect:
    for i in 1 ..< params.len:
      let identDef = params[i]
      let typ = identDef[^2]
      for nameNode in identDef.identDefNames:
        ($nameNode, typ)

  # Collect local variables with explicit types
  var localVars: seq[VarInfo]
  collectLocals(body, localVars)

  var seenNames: HashSet[string]
  var uniqueVars: seq[VarInfo]
  for v in localVars:
    if v.name notin seenNames:
      seenNames.incl v.name
      uniqueVars.add v
  localVars = uniqueVars

  # ============================================================
  # Phase 1: Split body at await points to find segments
  # ============================================================

  proc newNormalSegment(preStmts: seq[NimNode], hasAwait: bool = false,
                        breakTargetIdx: int = -1,
                        continueTargetIdx: int = -1): Segment =
    Segment(kind: skNormal, preStmts: preStmts, hasAwait: hasAwait,
            afterTryIdx: -1, overrideNextIdx: -1,
            breakTargetIdx: breakTargetIdx, continueTargetIdx: continueTargetIdx,
            afterIfIdx: -1, afterWhileIdx: -1)

  # Forward declarations needed for mutual recursion
  proc splitBody(stmts: NimNode, segments: var seq[Segment],
                 currentPre: var seq[NimNode],
                 loopBreakTarget: int = -1,
                 loopContinueTarget: int = -1,
                 exceptCtx: seq[ExceptBranch] = @[])

  proc splitTryBlock(s: NimNode, segments: var seq[Segment],
                     currentPre: var seq[NimNode],
                     loopBreakTarget: int = -1,
                     loopContinueTarget: int = -1)

  proc splitBranchBody(branchBody: NimNode, segments: var seq[Segment],
                       loopBreakTarget: int = -1,
                       loopContinueTarget: int = -1,
                       exceptCtx: seq[ExceptBranch] = @[]): IfBranchInfo =
    ## Process a branch body (if/elif/else/while body) that may contain awaits.
    ## Returns IfBranchInfo describing the first await and any continuation segments.
    ## The branch body is scanned linearly: statements before the first await go
    ## into preStmts, the first await creates the initial continuation segment,
    ## and remaining statements are recursively split into further continuation segments.
    var pre: seq[NimNode]
    var foundAwait = false
    var remaining: seq[NimNode]

    for i in 0 ..< branchBody.len:
      let s = branchBody[i]
      if not foundAwait and (isDirectAwaitStmt(s) or hasNestedAwait(s)):
        foundAwait = true
        for j in i ..< branchBody.len:
          remaining.add branchBody[j]
        break
      else:
        pre.add s

    if not foundAwait:
      # No await in this branch - all statements are sync
      var wrappedPre = pre
      if exceptCtx.len > 0 and wrappedPre.len > 0:
        wrappedPre = @[rebuildTryExcept(wrappedPre, exceptCtx)]
      return IfBranchInfo(
        preStmts: wrappedPre,
        hasAwait: false,
        contStartIdx: -1,
        contCount: 0
      )

    # There is an await. Split the remaining statements into continuation segments.
    let contStartIdx = segments.len
    var contPre: seq[NimNode]
    # Feed remaining stmts into a temporary stmtList and splitBody it
    var remainingNode = newStmtList()
    for s in remaining:
      remainingNode.add s

    # We need to create continuation segments for these remaining statements.
    # Use splitBody recursively, which appends to segments.
    splitBody(remainingNode, segments, contPre,
              loopBreakTarget, loopContinueTarget, exceptCtx)
    # Flush any trailing non-await stmts as a final continuation segment
    if contPre.len > 0:
      if exceptCtx.len > 0:
        contPre = @[rebuildTryExcept(contPre, exceptCtx)]
      segments.add newNormalSegment(contPre,
                                   breakTargetIdx = loopBreakTarget,
                                   continueTargetIdx = loopContinueTarget)

    let contCount = segments.len - contStartIdx

    # Wrap pre stmts in try/except if in except context
    if exceptCtx.len > 0 and pre.len > 0:
      pre = @[rebuildTryExcept(pre, exceptCtx)]

    # The first continuation segment has the await info we need
    if contCount > 0 and segments[contStartIdx].hasAwait:
      result = IfBranchInfo(
        preStmts: pre,
        hasAwait: true,
        awaitExpr: segments[contStartIdx].awaitExpr,
        awaitTarget: segments[contStartIdx].awaitTarget,
        contStartIdx: contStartIdx,
        contCount: contCount,
        exceptBranches: segments[contStartIdx].exceptBranches
      )
    else:
      # The "remaining" had nested await (e.g. inside try, nested if)
      # but the first stmt wasn't a direct await. The first continuation
      # segment is a passthrough that transitions to the next.
      result = IfBranchInfo(
        preStmts: pre,
        hasAwait: true,
        awaitExpr: newEmptyNode(),
        awaitTarget: "",
        contStartIdx: contStartIdx,
        contCount: contCount
      )

  proc splitBody(stmts: NimNode, segments: var seq[Segment],
                 currentPre: var seq[NimNode],
                 loopBreakTarget: int = -1,
                 loopContinueTarget: int = -1,
                 exceptCtx: seq[ExceptBranch] = @[]) =
    ## Recursively split a statement list at await points.
    var dummyTryIndices: seq[int]
    for stmtIdx in 0 ..< stmts.len:
      var s = stmts[stmtIdx]
      var handled = false

      # Handle try/except containing await
      if not handled and s.kind == nnkTryStmt and hasNestedAwait(s):
        # Flush currentPre as a normal segment before processing try block
        if currentPre.len > 0:
          if exceptCtx.len > 0:
            currentPre = @[rebuildTryExcept(currentPre, exceptCtx)]
          segments.add newNormalSegment(currentPre,
                                       breakTargetIdx = loopBreakTarget,
                                       continueTargetIdx = loopContinueTarget)
          currentPre = @[]
        splitTryBlock(s, segments, currentPre, loopBreakTarget, loopContinueTarget)
        handled = true

      # Handle return await expr → desugar to await + return
      if not handled and s.kind == nnkReturnStmt and s[0].isAwaitCall:
        let tmpName = "_cpsRetAwait_" & $segments.len
        if exceptCtx.len > 0 and currentPre.len > 0:
          let wrapped = rebuildTryExcept(currentPre, exceptCtx)
          currentPre = @[wrapped]
        addAwaitSegment(segments, currentPre, s[0][1], tmpName, exceptCtx,
                        loopBreakTarget, loopContinueTarget)
        # Push return to next segment's pre-statements
        currentPre.add nnkReturnStmt.newTree(ident(tmpName))
        handled = true

      # Handle case containing await → desugar to if/elif/else
      # Inline the case expression directly into conditions (no temp variable).
      # The case expression is typically a simple variable which rewrite()
      # will correctly transform to env.varName.
      if not handled and s.kind == nnkCaseStmt and hasNestedAwait(s):
        let caseExpr = s[0]

        var ifStmt = nnkIfStmt.newTree()
        for branchIdx in 1 ..< s.len:
          let branch = s[branchIdx]
          if branch.kind == nnkOfBranch:
            var cond: NimNode = nil
            for j in 0 ..< branch.len - 1:
              let pattern = branch[j]
              var patternCond: NimNode
              if pattern.kind == nnkRange:
                patternCond = nnkInfix.newTree(ident"and",
                  nnkInfix.newTree(ident">=", caseExpr.copyNimTree(), pattern[0]),
                  nnkInfix.newTree(ident"<=", caseExpr.copyNimTree(), pattern[1]))
              elif pattern.kind == nnkInfix and $pattern[0] == "..":
                patternCond = nnkInfix.newTree(ident"and",
                  nnkInfix.newTree(ident">=", caseExpr.copyNimTree(), pattern[1]),
                  nnkInfix.newTree(ident"<=", caseExpr.copyNimTree(), pattern[2]))
              else:
                patternCond = nnkInfix.newTree(ident"==", caseExpr.copyNimTree(), pattern)
              if cond == nil:
                cond = patternCond
              else:
                cond = nnkInfix.newTree(ident"or", cond, patternCond)
            ifStmt.add nnkElifBranch.newTree(cond, branch[^1])
          elif branch.kind == nnkElse:
            ifStmt.add branch
          elif branch.kind == nnkElifBranch:
            ifStmt.add branch

        s = ifStmt
        # Fall through to nnkIfStmt handler below

      # Handle if/elif/else containing await
      if not handled and s.kind == nnkIfStmt and hasNestedAwait(s):
        # Wrap currentPre in try/except if in except context
        if exceptCtx.len > 0 and currentPre.len > 0:
          currentPre = @[rebuildTryExcept(currentPre, exceptCtx)]
        # Reserve a slot for the dispatch segment FIRST, so it comes before
        # continuation segments in the step function list
        let dispatchIdx = segments.len
        segments.add Segment(
          kind: skIfDispatch,
          preStmts: currentPre,
          afterTryIdx: -1,
          overrideNextIdx: -1,
          breakTargetIdx: loopBreakTarget,
          continueTargetIdx: loopContinueTarget,
          afterIfIdx: -1,
          afterWhileIdx: -1
        )
        currentPre = @[]

        var branches: seq[IfBranchInfo]
        for branchIdx in 0 ..< s.len:
          let branch = s[branchIdx]
          var cond: NimNode
          var branchBodyNode: NimNode
          if branch.kind == nnkElifBranch:
            cond = branch[0]
            branchBodyNode = branch[1]
          elif branch.kind == nnkElse:
            cond = newEmptyNode()
            branchBodyNode = branch[0]
          else:
            continue

          var info = splitBranchBody(branchBodyNode, segments,
                                      loopBreakTarget, loopContinueTarget, exceptCtx)
          info.condition = cond

          # Add a merge-jump segment after each branch with await,
          # similar to how while loops add a loop-back segment.
          # This ensures that even when inner structures (nested if, while)
          # set overrideNextIdx on their own last segments, the merge segment
          # still correctly jumps to the outer if's afterIfIdx.
          if info.hasAwait and info.contCount > 0:
            segments.add newNormalSegment(@[],
                                          breakTargetIdx = loopBreakTarget,
                                          continueTargetIdx = loopContinueTarget)
            info.contCount += 1

          branches.add info

        segments[dispatchIdx].ifBranches = branches

        # Set afterIfIdx = current end of segments (where next code will go)
        let afterIfIdx = segments.len
        segments[dispatchIdx].afterIfIdx = afterIfIdx

        # Set overrideNextIdx on each branch's merge segment to afterIfIdx.
        for br in branches:
          if br.hasAwait and br.contCount > 0:
            let mergeIdx = br.contStartIdx + br.contCount - 1
            segments[mergeIdx].overrideNextIdx = afterIfIdx

        handled = true

      # Handle while containing await
      if not handled and s.kind == nnkWhileStmt and hasNestedAwait(s):
        # Flush currentPre as a normal segment that transitions to condition step
        if currentPre.len > 0:
          if exceptCtx.len > 0:
            currentPre = @[rebuildTryExcept(currentPre, exceptCtx)]
          segments.add newNormalSegment(currentPre,
                                       breakTargetIdx = loopBreakTarget,
                                       continueTargetIdx = loopContinueTarget)
          currentPre = @[]

        # Reserve condition step slot
        let condIdx = segments.len
        segments.add Segment(
          kind: skWhileEntry,
          afterTryIdx: -1,
          overrideNextIdx: -1,
          breakTargetIdx: -1,
          continueTargetIdx: -1,
          afterIfIdx: -1,
          afterWhileIdx: -1,
          whileCond: s[0],
          whileCondStepIdx: condIdx
        )

        # Process while body — break goes to afterWhile, continue goes to condIdx
        let bodyInfo = splitBranchBody(s[1], segments, -1, condIdx, exceptCtx)

        # Always add a loop-back segment that transitions back to condition.
        # This avoids overwriting nested loops' overrideNextIdx.
        # Body segments naturally flow (via i+1) to this loop-back.
        let loopBackIdx = segments.len
        var loopBackSeg = newNormalSegment(@[])
        loopBackSeg.overrideNextIdx = condIdx
        segments.add loopBackSeg

        # afterWhileIdx = where code continues after the while
        let afterWhileIdx = segments.len
        segments[condIdx].afterWhileIdx = afterWhileIdx
        segments[condIdx].whileBodyBranch = bodyInfo

        # Patch break/continue targets in body continuation segments.
        # Only patch segments not already claimed by a nested loop.
        if bodyInfo.hasAwait and bodyInfo.contCount > 0:
          for ci in bodyInfo.contStartIdx ..< bodyInfo.contStartIdx + bodyInfo.contCount:
            if segments[ci].breakTargetIdx < 0:
              segments[ci].breakTargetIdx = afterWhileIdx
            if segments[ci].continueTargetIdx < 0:
              segments[ci].continueTargetIdx = condIdx
        # Also patch the loop-back segment itself
        segments[loopBackIdx].breakTargetIdx = afterWhileIdx
        segments[loopBackIdx].continueTargetIdx = condIdx

        handled = true

      # Handle for loop containing await — desugar to var + while + inc
      if not handled and s.kind == nnkForStmt and hasNestedAwait(s):
        let desugared = desugarFor(s)
        if desugared != nil:
          # Feed the desugared statements back into splitBody
          splitBody(desugared, segments, currentPre,
                    loopBreakTarget, loopContinueTarget, exceptCtx)
          handled = true
        else:
          error("Unsupported for-loop pattern with await. Supported: range-based (a..<b, a..b, countdown) and indexable containers (seq, array, string).", s)

      # Normal (non-try) await patterns
      if not handled:
        if exceptCtx.len > 0 and currentPre.len > 0:
          if isDirectAwaitStmt(s):
            currentPre = @[rebuildTryExcept(currentPre, exceptCtx)]
        handled = splitStmtForAwait(s, segments, currentPre, exceptCtx,
                                    dummyTryIndices)

      if not handled:
        currentPre.add s

  proc splitTryBlock(s: NimNode, segments: var seq[Segment],
                     currentPre: var seq[NimNode],
                     loopBreakTarget: int = -1,
                     loopContinueTarget: int = -1) =
    ## Split a nnkTryStmt containing await(s) into segments.
    ## Delegates to splitBody with the except branches as context,
    ## enabling nested control flow (while/if/for) inside try blocks.
    ## Also handles await inside except handler bodies by creating
    ## continuation segments for each handler with await.
    ##
    ## Processing order: try body first, then handlers. After handlers
    ## are processed, try-body segments containing rebuildTryExcept output
    ## are re-wrapped with updated branches (which now have handlerContStartIdx),
    ## replacing handler bodies with _cpsHandlerJump transition markers.
    var branches = extractExceptBranches(s)
    let tryBody = s[0]
    let segsBefore = segments.len

    # Phase A: Process try body with splitBody. rebuildTryExcept wraps
    # sync code using the original branches (handler bodies copied as-is,
    # including those with await). We'll fix these up after Phase B.
    var tryPre: seq[NimNode]
    splitBody(tryBody, segments, tryPre,
              loopBreakTarget, loopContinueTarget, branches)

    # Flush trailing sync stmts from the try body as a SEPARATE segment
    if tryPre.len > 0:
      segments.add newNormalSegment(
        @[rebuildTryExcept(tryPre, branches)],
        breakTargetIdx = loopBreakTarget,
        continueTargetIdx = loopContinueTarget)

    let tryBodyEnd = segments.len

    # Phase B: Process except handler bodies that contain await.
    for branchIdx in 0 ..< branches.len:
      if hasNestedAwait(branches[branchIdx].body):
        branches[branchIdx].hasAwait = true

        let handlerStart = segments.len
        var handlerPre: seq[NimNode]
        splitBody(branches[branchIdx].body, segments, handlerPre,
                  loopBreakTarget, loopContinueTarget)
        if handlerPre.len > 0:
          segments.add newNormalSegment(handlerPre,
                                       breakTargetIdx = loopBreakTarget,
                                       continueTargetIdx = loopContinueTarget)

        branches[branchIdx].handlerContStartIdx = handlerStart
        branches[branchIdx].handlerContCount = segments.len - handlerStart

    # Phase C: Re-wrap try-body segments that contain rebuildTryExcept output.
    # Now that branches have handlerContStartIdx, rebuildTryExcept will generate
    # _cpsHandlerJump markers for handlers with await instead of copying their
    # bodies (which contain await calls that can't be processed in Phase 3).
    let hasAwaitHandlers = branches.anyIt(it.hasAwait)
    if hasAwaitHandlers:
      proc rewrapPreStmts(preStmts: var seq[NimNode], branches: seq[ExceptBranch]) =
        ## Re-wrap any nnkTryStmt nodes in preStmts with updated branches.
        var newPreStmts: seq[NimNode]
        var changed = false
        for s in preStmts:
          if s.kind == nnkTryStmt:
            var syncStmts: seq[NimNode]
            for child in s[0]:
              syncStmts.add child
            newPreStmts.add rebuildTryExcept(syncStmts, branches)
            changed = true
          else:
            newPreStmts.add s
        if changed:
          preStmts = newPreStmts

      for idx in segsBefore ..< tryBodyEnd:
        rewrapPreStmts(segments[idx].preStmts, branches)

        # Also re-wrap nnkTryStmt in IfBranchInfo preStmts (for sync branches
        # inside if-with-await that were wrapped before Phase B set hasAwait).
        if segments[idx].kind == skIfDispatch:
          for brIdx in 0 ..< segments[idx].ifBranches.len:
            rewrapPreStmts(segments[idx].ifBranches[brIdx].preStmts, branches)

        # Same for while body branch preStmts.
        if segments[idx].kind == skWhileEntry:
          rewrapPreStmts(segments[idx].whileBodyBranch.preStmts, branches)

    # afterTryIdx = after ALL segments (including handler continuations)
    let afterIdx = segments.len

    # Ensure successful completion of the final try-body segment continues
    # after the try/except, not into handler continuation segments.
    #
    # Do not clobber an explicit control-flow override (for example a while
    # loop-back segment that already points to its condition step).
    if tryBodyEnd > segsBefore and segments[tryBodyEnd - 1].overrideNextIdx < 0:
      segments[tryBodyEnd - 1].overrideNextIdx = afterIdx

    # If await handlers appended extra continuation segments, try-body control
    # targets that pointed at the original try-body boundary must be retargeted
    # to the real after-try index.
    if afterIdx > tryBodyEnd:
      for idx in segsBefore ..< tryBodyEnd:
        if segments[idx].overrideNextIdx == tryBodyEnd:
          segments[idx].overrideNextIdx = afterIdx
        if segments[idx].breakTargetIdx == tryBodyEnd:
          segments[idx].breakTargetIdx = afterIdx
        if segments[idx].continueTargetIdx == tryBodyEnd:
          segments[idx].continueTargetIdx = afterIdx
        if segments[idx].kind == skIfDispatch and segments[idx].afterIfIdx == tryBodyEnd:
          segments[idx].afterIfIdx = afterIdx
        elif segments[idx].kind == skWhileEntry and segments[idx].afterWhileIdx == tryBodyEnd:
          segments[idx].afterWhileIdx = afterIdx

    # Update all try-body segments with the updated branches and afterTryIdx.
    for idx in segsBefore ..< tryBodyEnd:
      if segments[idx].exceptBranches.len > 0:
        segments[idx].exceptBranches = branches
        if segments[idx].afterTryIdx < 0:
          segments[idx].afterTryIdx = afterIdx

    # Set the last handler continuation segment to jump to afterTryIdx
    for branch in branches:
      if branch.hasAwait and branch.handlerContCount > 0:
        let lastIdx = branch.handlerContStartIdx + branch.handlerContCount - 1
        if segments[lastIdx].overrideNextIdx < 0:
          segments[lastIdx].overrideNextIdx = afterIdx

  var segments: seq[Segment]
  var currentPre: seq[NimNode]

  splitBody(body, segments, currentPre)

  segments.add newNormalSegment(currentPre)

  # ============================================================
  # Phase 2: Build environment type (with await target fields)
  # ============================================================

  var knownNames = procParams.mapIt(it[0]).toHashSet()
  for v in localVars:
    knownNames.incl v.name

  # Collect 'as' variables from except handler bodies that contain await.
  # These need to be in the env so they persist across await points in the handler.
  for seg in segments:
    if seg.exceptBranches.len > 0:
      for branch in seg.exceptBranches:
        if branch.hasAwait and branch.asVar != "" and branch.asVar notin seenNames:
          let excType = if branch.types.len == 1:
            nnkRefTy.newTree(branch.types[0].copyNimTree())
          else:
            nnkRefTy.newTree(ident"CatchableError")
          localVars.add VarInfo(
            name: branch.asVar,
            typ: excType,
            defVal: newEmptyNode()
          )
          seenNames.incl branch.asVar
          knownNames.incl branch.asVar

  let envTypeName = ident(procBaseName & "Env")
  var envFields = nnkRecList.newTree()
  envFields.add newIdentDefs(ident"fut", futureType)

  for (name, typ) in procParams:
    envFields.add newIdentDefs(name, typ)

  # Map of name -> type expression for typeof rewriting in field definitions.
  var typeMap = procParams.toTable()

  let readSym = ident"read"

  var typeAliases: seq[NimNode]  # type sections to emit before env type
  var aliasIdx = 0

  proc getOrCreateAlias(typeExpr: NimNode): NimNode =
    ## For simple types (ident, bracketExpr), return as-is.
    ## For typeof expressions, create a type alias and return the alias ident.
    ## Wraps typeof(expr) as typeof(block: (let cpsTmp = expr; cpsTmp))
    ## to force proc overload resolution (avoids Nim resolving to iterator
    ## yield types, e.g. split returning string instead of seq[string]).
    if typeExpr.kind in {nnkIdent, nnkBracketExpr, nnkSym}:
      return typeExpr
    if isGeneric:
      # For generic procs, typeof expressions reference generic params and
      # must be evaluated at instantiation time. Skip alias creation and
      # use the raw typeof expression directly in the generic env type fields.
      return typeExpr
    let aliasName = genSym(nskType, "cpsType" & $aliasIdx)
    inc aliasIdx
    var wrappedExpr = typeExpr.copyNimTree()
    # Wrap typeof(expr) → typeof(block: (let cpsTmp = expr; cpsTmp))
    if wrappedExpr.kind == nnkCall and wrappedExpr.len == 2 and
       wrappedExpr[0].kind == nnkIdent and $wrappedExpr[0] == "typeof":
      let innerExpr = wrappedExpr[1]
      let tmpIdent = genSym(nskLet, "cpsTmp")
      wrappedExpr = nnkCall.newTree(
        ident"typeof",
        nnkBlockStmt.newTree(
          newEmptyNode(),
          nnkStmtList.newTree(
            nnkLetSection.newTree(
              newIdentDefs(tmpIdent, defVal = innerExpr)
            ),
            tmpIdent.copyNimTree()
          )
        )
      )
    typeAliases.add nnkTypeSection.newTree(
      nnkTypeDef.newTree(
        aliasName,
        if isGeneric: genericParams.copyNimTree() else: newEmptyNode(),
        wrappedExpr
      )
    )
    return makeGenericInst(aliasName)

  proc rewriteForTypeof(n: NimNode, typeMap: Table[string, NimNode]): NimNode =
    ## Rewrite identifiers to `default(Type)` so typeof() works in type def scope.
    ## For unknown identifiers (local vars not yet in typeMap), substitute with
    ## `default(int)` since they're value arguments that don't affect return types
    ## and we're inside typeof() so the expression is never executed.
    case n.kind
    of nnkIdent:
      let name = $n
      if name in typeMap:
        return nnkCall.newTree(ident"default", typeMap[name].copyNimTree())
      return n.copyNimTree()
    of nnkDotExpr:
      # Only rewrite the object (left), not the field name (right)
      result = n.copyNimNode()
      result.add rewriteForTypeof(n[0], typeMap)
      result.add n[1].copyNimTree()
    of nnkExprColonExpr, nnkExprEqExpr:
      # Only rewrite the value (right), not the field name (left)
      result = n.copyNimNode()
      result.add n[0].copyNimTree()
      result.add rewriteForTypeof(n[1], typeMap)
    of nnkCommand:
      # `addr expr` in untyped context is nnkCommand(ident"addr", operand).
      # Since identifiers get rewritten to default(Type) — rvalues that have
      # no address — `addr rvalue[0]` would fail. Replace with
      # `default(ptr typeof(operand))` which preserves the type correctly.
      if n.len == 2 and n[0].kind == nnkIdent and $n[0] == "addr":
        let operand = rewriteForTypeof(n[1], typeMap)
        return nnkCall.newTree(
          ident"default",
          nnkPtrTy.newTree(nnkCall.newTree(ident"typeof", operand))
        )
      result = n.copyNimNode()
      for child in n:
        result.add rewriteForTypeof(child, typeMap)
    else:
      result = n.copyNimNode()
      for child in n:
        result.add rewriteForTypeof(child, typeMap)

  # Pre-populate typeMap with await target types so both local vars and
  # other await targets can reference them in typeof expressions.
  # This avoids ordering issues where a local var's typeof references an
  # await target that hasn't been added to typeMap yet (or vice versa).
  proc awaitTargetTypeExpr(awaitExpr: NimNode): NimNode =
    let rewrittenFutExpr = rewriteForTypeof(awaitExpr, typeMap)
    nnkCall.newTree(
      ident"typeof",
      nnkCall.newTree(readSym, rewrittenFutExpr)
    )

  # Pre-populate typeMap in three passes to handle cross-references:
  # - Await target `data` may reference local var `chunkSize`
  # - Local var `parts` may reference await target `statusLine`
  # Pass 1: local vars (raw typeof, no aliases — so await targets can reference them)
  # Pass 2: await targets (raw typeof, no aliases — so local vars can reference them)
  # Pass 3: re-process local vars with await targets now available
  # Then: create aliases for all typeof entries
  proc buildTypeofExpr(defVal: NimNode): NimNode =
    ## Build the type expression for a local variable's default value.
    let rewritten = rewriteForTypeof(defVal, typeMap)
    return nnkCall.newTree(ident"typeof", rewritten)

  for v in localVars:
    if v.typ.kind != nnkEmpty:
      typeMap[v.name] = v.typ
    elif v.defVal.kind in {nnkLambda, nnkDo}:
      let lambdaParams = v.defVal[3]
      let closureType = nnkProcTy.newTree(
        lambdaParams.copyNimTree(),
        nnkPragma.newTree(ident"closure")
      )
      typeMap[v.name] = closureType
    elif v.defVal.kind != nnkEmpty:
      typeMap[v.name] = buildTypeofExpr(v.defVal)

  proc prePopulateAwaitTargets() =
    for (target, expr) in collectAwaitTargets(segments):
      if target notin seenNames:
        seenNames.incl target
        knownNames.incl target
        typeMap[target] = awaitTargetTypeExpr(expr)

  prePopulateAwaitTargets()

  # Iterative fixed-point: keep reprocessing locals and await targets until
  # typeMap stabilizes. This handles transitive typeof chains of any depth
  # (e.g., local → await → local → local → await).
  proc reProcessLocals() =
    for v in localVars:
      if v.typ.kind == nnkEmpty and v.defVal.kind notin {nnkEmpty, nnkLambda, nnkDo}:
        typeMap[v.name] = buildTypeofExpr(v.defVal)

  proc reProcessAwaitTargets() =
    for (target, expr) in collectAwaitTargets(segments):
      typeMap[target] = awaitTargetTypeExpr(expr)

  proc typeMapSnapshot(): seq[string] =
    collect:
      for k, v in typeMap: k & "=" & v.repr

  for iteration in 0 ..< 5:
    let prev = typeMapSnapshot()
    reProcessLocals()
    reProcessAwaitTargets()
    if typeMapSnapshot() == prev:
      break  # Fixed point reached

  # Now create aliases for all typeof entries in typeMap
  for v in localVars:
    if v.name in typeMap:
      let entry = typeMap[v.name]
      if entry.kind == nnkCall and entry.len >= 1 and entry[0].kind == nnkIdent and $entry[0] == "typeof":
        typeMap[v.name] = getOrCreateAlias(entry)
  for (target, _) in collectAwaitTargets(segments):
    if target in typeMap:
      let entry = typeMap[target]
      if entry.kind == nnkCall and entry.len >= 1 and entry[0].kind == nnkIdent and $entry[0] == "typeof":
        typeMap[target] = getOrCreateAlias(entry)

  # Add local variable fields first (original ordering preserved for env layout)
  proc hasClosureProcPragma(typeExpr: NimNode): bool =
    if typeExpr.kind != nnkProcTy or typeExpr.len < 2:
      return false
    let pragmaNode = typeExpr[1]
    if pragmaNode.kind != nnkPragma:
      return false
    for p in pragmaNode:
      if p.kind == nnkIdent and $p == "closure":
        return true
      if p.kind == nnkExprColonExpr and p.len == 2 and
         p[0].kind == nnkIdent and $p[0] == "closure":
        return true
    return false

  proc envFieldIdent(name: string, cursorField: bool): NimNode =
    if cursorField:
      return nnkPragmaExpr.newTree(
        ident(name),
        nnkPragma.newTree(ident"cursor")
      )
    ident(name)

  for v in localVars:
    if v.typ.kind != nnkEmpty:
      let useCursor = hasClosureProcPragma(v.typ)
      envFields.add newIdentDefs(envFieldIdent(v.name, useCursor), v.typ)
    elif v.defVal.kind in {nnkLambda, nnkDo}:
      # Lambda values: build explicit proc type with {.closure.} pragma
      # to avoid nimcall/closure mismatch after rewriting captures env.
      # Marking those fields as `.cursor` breaks env->closure->env ARC cycles.
      let closureType = nnkProcTy.newTree(
        v.defVal[3].copyNimTree(), nnkPragma.newTree(ident"closure"))
      envFields.add newIdentDefs(envFieldIdent(v.name, true), closureType)
    elif v.defVal.kind != nnkEmpty:
      envFields.add newIdentDefs(v.name, typeMap[v.name])

  let localVarNames = localVars.mapIt(it.name).toHashSet()

  # Add await target fields (after local vars in the env layout)
  var emittedAwaitFields: HashSet[string]
  proc addAwaitTargetField(awaitTarget: string, awaitExpr: NimNode) =
    # Skip if already emitted as a local var field or await field
    if awaitTarget != "" and awaitTarget notin emittedAwaitFields and
       awaitTarget notin localVarNames:
      emittedAwaitFields.incl awaitTarget
      # Type was already pre-populated in typeMap above
      let typeofExpr = typeMap[awaitTarget]
      envFields.add newIdentDefs(awaitTarget, typeofExpr)

  for (target, expr) in collectAwaitTargets(segments):
    addAwaitTargetField(target, expr)

  let typeSection = nnkTypeSection.newTree(
    nnkTypeDef.newTree(
      envTypeName,
      if isGeneric: genericParams.copyNimTree() else: newEmptyNode(),
      nnkRefTy.newTree(
        nnkObjectTy.newTree(
          newEmptyNode(),
          nnkOfInherit.newTree(ident"Continuation"),
          envFields
        )
      )
    )
  )

  # ============================================================
  # Phase 3: Generate step functions
  # ============================================================

  # Bind runtime identifiers
  let hasErrorSym = ident"hasError"
  let getErrorSym = ident"getError"
  let addCallbackSym = ident"addCallback"
  let finishedSym = ident"finished"
  let failSym = bindSym"fail"
  let completeSym = bindSym"complete"
  let runSym = bindSym"run"
  let currentRuntimeSym = bindSym"currentRuntime"
  let setFutureRootContinuationSym = bindSym"setFutureRootContinuation"

  proc genHalt(envId: NimNode): NimNode =
    ## Generate `env.state = csFinished; env.fn = nil` (marks continuation done).
    quote do:
      `envId`.state = csFinished
      `envId`.fn = nil

  proc excludeProcLocals(known: var HashSet[string], procNode: NimNode) =
    ## Exclude formal parameter names and local variable names from `known`.
    ## Used when descending into nested procs/lambdas to avoid rewriting
    ## shadowed names.
    let formalParams = procNode[3]
    if formalParams.kind == nnkFormalParams:
      for i in 1 ..< formalParams.len:
        for nameNode in formalParams[i].identDefNames:
          known.excl $nameNode
    if procNode[6].kind != nnkEmpty:
      var innerLocals: seq[VarInfo]
      collectLocals(procNode[6], innerLocals)
      for v in innerLocals:
        known.excl v.name

  proc rewriteLambdaBody(n: NimNode, knownNames: HashSet[string]): NimNode =
    ## Rewrite identifiers in a nested proc/lambda body to env.varName,
    ## but do NOT apply CPS-specific transforms (return/raise stay as-is).
    let envId = ident"env"
    case n.kind
    of nnkIdent:
      if $n in knownNames:
        return newDotExpr(envId, ident($n))
      return n
    of nnkLetSection, nnkVarSection:
      # Local vars inside the lambda shadow env vars
      var shadowed = knownNames
      for def in n:
        if def.kind == nnkIdentDefs:
          for nameNode in def.identDefNames:
            shadowed.excl $nameNode
      result = n.copyNimNode()
      for def in n:
        if def.kind == nnkIdentDefs:
          var newDef = def.copyNimNode()
          for nameNode in def.identDefNames:
            newDef.add nameNode.copyNimTree()
          newDef.add def[^2].copyNimTree()  # type
          if def[^1].kind != nnkEmpty:
            newDef.add rewriteLambdaBody(def[^1], knownNames)  # value uses outer scope
          else:
            newDef.add def[^1].copyNimTree()
          result.add newDef
        else:
          result.add def.copyNimTree()
    of nnkProcDef, nnkFuncDef, nnkLambda, nnkDo:
      var innerKnown = knownNames
      excludeProcLocals(innerKnown, n)
      result = n.copyNimNode()
      for i, child in n.pairs:
        if i == 6 and child.kind != nnkEmpty:
          result.add rewriteLambdaBody(child, innerKnown)
        else:
          result.add child.copyNimTree()
    of nnkSym:
      return n
    else:
      result = n.copyNimNode()
      for child in n:
        result.add rewriteLambdaBody(child, knownNames)

  # Forward-declare stepNames so rewrite() can reference it for
  # _cpsHandlerJump resolution. Populated after Phase 1.
  var stepNames: seq[NimNode]

  proc rewrite(n: NimNode, knownNames: HashSet[string],
               breakTarget: NimNode = nil,
               continueTarget: NimNode = nil,
               inTryScope: bool = false): NimNode =
    let envId = ident"env"
    case n.kind
    of nnkIdent:
      if $n in knownNames:
        return newDotExpr(envId, ident($n))
      return n
    of nnkLetSection, nnkVarSection:
      result = newStmtList()
      for def in n:
        if def.kind == nnkIdentDefs:
          let defVal = def[^1]
          var allKnown = true
          for nameNode in def.identDefNames:
            if $nameNode notin knownNames:
              allKnown = false
              break

          if allKnown:
            for nameNode in def.identDefNames:
              if defVal.kind != nnkEmpty:
                result.add newAssignment(
                  newDotExpr(envId, ident($nameNode)),
                  rewrite(defVal, knownNames, breakTarget, continueTarget, inTryScope)
                )
          else:
            var section = n.copyNimNode()
            var defCopy = def.copyNimNode()
            for nameNode in def.identDefNames:
              defCopy.add nameNode.copyNimTree()
            defCopy.add def[^2].copyNimTree()  # type
            if defVal.kind != nnkEmpty:
              defCopy.add rewrite(defVal, knownNames, breakTarget, continueTarget, inTryScope)
            else:
              defCopy.add defVal.copyNimTree()
            section.add defCopy
            result.add section
      return result
    of nnkReturnStmt:
      let halt = genHalt(envId)
      if n[0].kind == nnkEmpty or isVoid:
        return quote do:
          `completeSym`(`envId`.fut)
          `halt`
          return `envId`
      else:
        let retVal = rewrite(n[0], knownNames, breakTarget, continueTarget, inTryScope)
        return quote do:
          `completeSym`(`envId`.fut, `retVal`)
          `halt`
          return `envId`
    of nnkRaiseStmt:
      if inTryScope:
        if n[0].kind == nnkEmpty:
          return n.copyNimTree()
        let errExpr = rewrite(n[0], knownNames, breakTarget, continueTarget, inTryScope)
        return nnkRaiseStmt.newTree(errExpr)
      let halt = genHalt(envId)
      if n[0].kind == nnkEmpty:
        let getCurExc = ident"getCurrentException"
        return quote do:
          `failSym`(`envId`.fut, cast[ref CatchableError](`getCurExc`()))
          `halt`
          return `envId`
      else:
        let errExpr = rewrite(n[0], knownNames, breakTarget, continueTarget, inTryScope)
        return quote do:
          `failSym`(`envId`.fut, `errExpr`)
          `halt`
          return `envId`
    of nnkBreakStmt:
      if breakTarget != nil:
        return quote do:
          `envId`.fn = `breakTarget`
          return `envId`
      return n
    of nnkContinueStmt:
      if continueTarget != nil:
        return quote do:
          `envId`.fn = `continueTarget`
          return `envId`
      return n
    of nnkForStmt:
      # Non-split for loop (no await inside — still in the same step function).
      # Clear break/continue targets so that break/continue inside this loop
      # remain normal Nim break/continue instead of being rewritten as CPS
      # step transitions. Without this, `break` inside a non-split for loop
      # that's nested in a CPS-split while loop gets rewritten to
      # `env.fn = outerBreakTarget; return env`, which bypasses any
      # enclosing try/finally blocks (e.g. withLock's release).
      result = n.copyNimNode()
      for i, child in n.pairs:
        if i == n.len - 1:
          # Loop body: clear break/continue targets
          result.add rewrite(child, knownNames, nil, nil, inTryScope)
        else:
          result.add rewrite(child, knownNames, breakTarget, continueTarget, inTryScope)
    of nnkWhileStmt:
      # Same as nnkForStmt: non-split while loops should use normal
      # break/continue, not CPS step transitions.
      result = n.copyNimNode()
      # Condition
      result.add rewrite(n[0], knownNames, breakTarget, continueTarget, inTryScope)
      # Body: clear break/continue targets
      result.add rewrite(n[1], knownNames, nil, nil, inTryScope)
    of nnkExprColonExpr, nnkExprEqExpr:
      # Object constructor field or keyword arg: don't rewrite the field name (first child)
      result = n.copyNimNode()
      result.add n[0].copyNimTree()  # field name stays as-is
      result.add rewrite(n[1], knownNames, breakTarget, continueTarget, inTryScope)  # value is rewritten
    of nnkDotExpr:
      # Field access: rewrite the object (left) but not the field name (right)
      result = n.copyNimNode()
      result.add rewrite(n[0], knownNames, breakTarget, continueTarget, inTryScope)
      result.add n[1].copyNimTree()  # field name stays as-is
    of nnkTryStmt:
      # Preserve raise semantics within try/except/finally regions so local
      # handlers can intercept before we fail the root future.
      result = n.copyNimNode()
      for child in n:
        result.add rewrite(child, knownNames, breakTarget, continueTarget, true)
    of nnkExceptBranch:
      # Don't rewrite the `as` variable binding in `except Type as e:`.
      # Also exclude the `as` variable from knownNames when rewriting the body.
      result = n.copyNimNode()
      var exceptKnown = knownNames
      for i in 0 ..< n.len - 1:
        let child = n[i]
        if child.kind == nnkInfix and child.len == 3 and $child[0] == "as":
          # except Type as varName — keep the infix node but don't rewrite the binding ident
          let asVarName = $child[2]
          exceptKnown.excl asVarName
          var infixCopy = child.copyNimNode()
          infixCopy.add child[0].copyNimTree()  # "as"
          infixCopy.add child[1].copyNimTree()  # Type
          infixCopy.add child[2].copyNimTree()  # varName (keep as ident)
          result.add infixCopy
        else:
          result.add child.copyNimTree()
      # Rewrite the body (last child) with the as var excluded
      result.add rewrite(n[^1], exceptKnown, breakTarget, continueTarget, inTryScope)
    of nnkSym:
      return n
    of nnkProcDef, nnkFuncDef, nnkLambda, nnkDo:
      var innerKnown = knownNames
      excludeProcLocals(innerKnown, n)
      result = n.copyNimNode()
      for i, child in n.pairs:
        if i == 6 and child.kind != nnkEmpty:
          result.add rewriteLambdaBody(child, innerKnown)
        else:
          result.add child.copyNimTree()
    of nnkCall:
      # Check for _cpsHandlerJump(stepIdx) marker from rebuildTryExcept.
      # These are generated for except handlers with await to transition
      # to the handler's continuation chain.
      if n.len == 2 and n[0].kind == nnkIdent and $n[0] == "_cpsHandlerJump":
        let stepIdx = n[1].intVal.int
        let stepIdent = stepNames[stepIdx]
        return quote do:
          `envId`.fn = `stepIdent`
          return `envId`
      # Normal call — rewrite children
      result = n.copyNimNode()
      for child in n:
        result.add rewrite(child, knownNames, breakTarget, continueTarget, inTryScope)
    else:
      result = n.copyNimNode()
      for child in n:
        result.add rewrite(child, knownNames, breakTarget, continueTarget, inTryScope)

  # Helper: in callback context, `return env` is invalid (callback returns void).
  # Replace `return <expr>` with bare `return`.
  proc fixCallbackReturns(n: NimNode): NimNode =
    if n.kind == nnkReturnStmt and n.len > 0 and n[0].kind != nnkEmpty:
      return nnkReturnStmt.newTree(newEmptyNode())
    result = n.copyNimNode()
    for child in n:
      result.add fixCallbackReturns(child)

  # Populate stepNames (forward-declared before rewrite()) now that Phase 1
  # is complete and we know the segment count.
  let numSteps = segments.len
  for i in 0 ..< numSteps:
    stepNames.add ident(procBaseName & "Step" & $i)

  # Keep bare idents for proc definitions; instantiate stepNames for transitions
  let stepBareNames = stepNames  # snapshot before generic instantiation
  if isGeneric:
    for i in 0 ..< numSteps:
      stepNames[i] = makeGenericInst(stepBareNames[i])
  let envTypeInst = makeGenericInst(envTypeName)

  # Helper: build a try/except that re-raises the await error and catches
  # it with the user's except branches. Used for await-inside-try.
  proc buildExceptReraise(af, envId: NimNode, seg: Segment,
                          transitionBody: NimNode,
                          forCallback: bool = false): NimNode =
    ## Generate:
    ##   try:
    ##     raise getError(af)
    ##   except Type1 as e:
    ##     <rewritten handler>
    ##     <transition to afterTryStep>
    ##   except:
    ##     fail(env.fut, getCurrentException())
    ##     <halt or nothing>
    ##
    ## For except branches with await in their handler bodies:
    ##   except Type1 as _cpsExcLocal:
    ##     env.e = _cpsExcLocal  # store in env for continuation access
    ##     env.fn = handlerStep  # transition to handler continuation chain
    ##     env.state = csRunning
    ##     return env / discard run(env)
    var tryBody = newStmtList()
    tryBody.add nnkRaiseStmt.newTree(nnkCall.newTree(getErrorSym, af))

    var tryNode = nnkTryStmt.newTree(tryBody)

    for branch in seg.exceptBranches:
      var eb = nnkExceptBranch.newTree()

      if branch.hasAwait and branch.handlerContCount > 0:
        # Handler has await — transition to handler continuation segments.
        let handlerStep = stepNames[branch.handlerContStartIdx]
        let excLocal = ident"_cpsExcLocal"

        if branch.types.len > 0:
          for t in branch.types:
            eb.add nnkInfix.newTree(ident"as", t.copyNimTree(), excLocal)
        else:
          eb.add nnkInfix.newTree(ident"as", ident"CatchableError", excLocal)

        var handlerBody = newStmtList()
        if branch.asVar != "":
          let asId = ident(branch.asVar)
          handlerBody.add quote do:
            `envId`.`asId` = `excLocal`
        if forCallback:
          handlerBody.add quote do:
            `envId`.fn = `handlerStep`
            discard `runSym`(`envId`)
        else:
          handlerBody.add quote do:
            `envId`.fn = `handlerStep`
            return `envId`
        eb.add handlerBody
      else:
        # No await in handler — inline as before
        # Add type matchers
        if branch.types.len > 0:
          for t in branch.types:
            if branch.asVar != "":
              eb.add nnkInfix.newTree(ident"as", t.copyNimTree(), ident(branch.asVar))
            else:
              eb.add t.copyNimTree()

        # Handler body: rewrite user code, exclude `as` var from known names
        var handlerBody = newStmtList()
        var handlerKnown = knownNames
        if branch.asVar != "":
          handlerKnown.excl branch.asVar
        for s in branch.body:
          handlerBody.add rewrite(s, handlerKnown)

        # After handler: transition to afterTryStep
        handlerBody.add transitionBody.copyNimTree()
        if forCallback:
          handlerBody = fixCallbackReturns(handlerBody)
        eb.add handlerBody

      tryNode.add eb

    # Catch-all for unmatched exceptions -> fail the future
    proc coversCatchAll(branches: seq[ExceptBranch]): bool =
      for b in branches:
        if b.types.len == 0: return true
        for t in b.types:
          if $t in ["CatchableError", "Exception"]: return true
    let hasBareExcept = coversCatchAll(seg.exceptBranches)

    if not hasBareExcept:
      var catchAll = nnkExceptBranch.newTree()
      let catchVar = ident"_cpsUnmatched"
      catchAll.add nnkInfix.newTree(ident"as", ident"CatchableError", catchVar)
      let halt = genHalt(envId)
      var catchBody = newStmtList()
      catchBody.add quote do:
        `failSym`(`envId`.fut, `catchVar`)
        `halt`
      catchAll.add catchBody
      tryNode.add catchAll

    return tryNode

  var stepProcs: seq[NimNode]

  proc contractFailReturn(envId: NimNode): NimNode =
    let halt = genHalt(envId)
    quote do:
      `failSym`(`envId`.fut, newException(`cpsContractErrorSym`, `missingReturnMsg`))
      `halt`
      return `envId`

  proc contractFailInCallback(envId: NimNode): NimNode =
    let halt = genHalt(envId)
    quote do:
      `failSym`(`envId`.fut, newException(`cpsContractErrorSym`, `missingReturnMsg`))
      `halt`

  # ---- Await code generation helpers ----

  proc buildAfterReadActions(envId: NimNode, nextIdx: int):
      tuple[inline, callback: NimNode] =
    ## Build the transition/complete/contractFail code that runs after
    ## reading the awaited future's value. Returns inline and callback variants.
    if nextIdx < numSteps:
      let nextStep = stepNames[nextIdx]
      result.inline = quote do:
        `envId`.fn = `nextStep`
        return `envId`
      result.callback = quote do:
        `envId`.fn = `nextStep`
        discard `runSym`(`envId`)
    else:
      if isVoid:
        let halt = genHalt(envId)
        result.inline = quote do:
          `completeSym`(`envId`.fut)
          `halt`
          return `envId`
        result.callback = quote do:
          `completeSym`(`envId`.fut)
      else:
        result.inline = contractFailReturn(envId)
        result.callback = contractFailInCallback(envId)

  proc genSimpleAwaitDispatch(envId, af: NimNode,
                              awaitTarget: string,
                              inlineAfterRead: NimNode,
                              callbackAfterRead: NimNode): NimNode =
    ## Generate if-finished/else-callback dispatch for simple (no try-context) awaits.
    ## Checks hasError on both inline and callback paths.
    let halt = genHalt(envId)
    var inlineBody = newStmtList()
    inlineBody.add quote do:
      if `hasErrorSym`(`af`):
        `failSym`(`envId`.fut, `getErrorSym`(`af`))
        `halt`
        return `envId`
    if awaitTarget != "":
      let tf = ident(awaitTarget)
      inlineBody.add quote do:
        `envId`.`tf` = `readSym`(`af`)
    inlineBody.add inlineAfterRead

    var callbackElse = newStmtList()
    if awaitTarget != "":
      let tf = ident(awaitTarget)
      callbackElse.add quote do:
        `envId`.`tf` = `readSym`(`af`)
    callbackElse.add callbackAfterRead

    quote do:
      if `af`.finished:
        `inlineBody`
      else:
        `addCallbackSym`(`af`, proc() =
          if `hasErrorSym`(`af`):
            `failSym`(`envId`.fut, `getErrorSym`(`af`))
          else:
            `callbackElse`
        )
        `envId`.fn = nil
        `envId`.state = csSuspended
        return `envId`

  proc genTryContextAwaitDispatch(envId, af: NimNode,
                                  seg: Segment,
                                  awaitTarget: string,
                                  inlineAfterRead: NimNode,
                                  callbackAfterRead: NimNode): NimNode =
    ## Generate if-finished/else-callback dispatch for awaits inside try/except.
    ## Error handling routes through buildExceptReraise for proper exception dispatch.
    let afterStep = stepNames[seg.afterTryIdx]
    let inlineTransition = quote do:
      `envId`.fn = `afterStep`
      return `envId`
    let callbackTransition = quote do:
      `envId`.fn = `afterStep`
      discard `runSym`(`envId`)
    let inlineTry = buildExceptReraise(af, envId, seg, inlineTransition)
    let callbackTry = buildExceptReraise(af, envId, seg, callbackTransition, forCallback = true)

    var inlineBody = newStmtList()
    inlineBody.add quote do:
      if `hasErrorSym`(`af`):
        `inlineTry`
        return `envId`
    if awaitTarget != "":
      let tf = ident(awaitTarget)
      inlineBody.add quote do:
        `envId`.`tf` = `readSym`(`af`)
    inlineBody.add inlineAfterRead

    var callbackElse = newStmtList()
    if awaitTarget != "":
      let tf = ident(awaitTarget)
      callbackElse.add quote do:
        `envId`.`tf` = `readSym`(`af`)
    callbackElse.add callbackAfterRead

    quote do:
      if `af`.finished:
        `inlineBody`
      else:
        `addCallbackSym`(`af`, proc() =
          if `hasErrorSym`(`af`):
            `callbackTry`
          else:
            `callbackElse`
        )
        `envId`.fn = nil
        `envId`.state = csSuspended
        return `envId`

  proc genStepTransition(envId: NimNode, targetStep: NimNode): NimNode =
    ## Generate a simple step transition (env.fn = step; return env).
    ## If targetStep is nil, generates end-of-proc handling.
    if targetStep != nil:
      quote do:
        `envId`.fn = `targetStep`
        return `envId`
    else:
      let (inl, _) = buildAfterReadActions(envId, numSteps)
      inl

  # Helper: generate transition to next step (no await).
  proc generateTransition(seg: Segment, i: int, stepBody: var NimNode,
                          envId: NimNode) =
    let nextIdx = if seg.overrideNextIdx >= 0: seg.overrideNextIdx else: i + 1
    let targetStep = if nextIdx < numSteps: stepNames[nextIdx] else: nil
    stepBody.add genStepTransition(envId, targetStep)

  # Helper: generate the await handling code for a normal segment.
  proc generateNormalAwaitStep(seg: Segment, i: int, stepBody: var NimNode,
                                envId, envTypeName: NimNode) =
    let futExpr = rewrite(seg.awaitExpr, knownNames)
    let af = ident"awaitFut"
    stepBody.add quote do:
      let `af` = `futExpr`

    let nextIdx = if seg.overrideNextIdx >= 0: seg.overrideNextIdx else: i + 1
    let (inlineAfterRead, callbackAfterRead) = buildAfterReadActions(envId, nextIdx)

    if seg.exceptBranches.len > 0:
      stepBody.add genTryContextAwaitDispatch(envId, af, seg, seg.awaitTarget,
                                              inlineAfterRead, callbackAfterRead)
    else:
      stepBody.add genSimpleAwaitDispatch(envId, af, seg.awaitTarget,
                                          inlineAfterRead, callbackAfterRead)

  proc genBranchAwaitOrTransition(br: IfBranchInfo, body: var NimNode,
                                    envId: NimNode) =
    ## Generate await dispatch or step transition for a branch with continuations.
    ## Used by both skIfDispatch and skWhileEntry code generation.
    let firstCont = segments[br.contStartIdx]
    if firstCont.hasAwait and firstCont.exceptBranches.len == 0:
      let futExpr = rewrite(firstCont.awaitExpr, knownNames)
      let af = genSym(nskLet, "awaitFut")
      body.add quote do:
        let `af` = `futExpr`
      let contNextIdx = if firstCont.overrideNextIdx >= 0:
        firstCont.overrideNextIdx
      elif br.contStartIdx + 1 < numSteps: br.contStartIdx + 1
      else: numSteps
      let (inl, cb) = buildAfterReadActions(envId, contNextIdx)
      body.add genSimpleAwaitDispatch(envId, af, firstCont.awaitTarget, inl, cb)
    else:
      let firstContStep = stepNames[br.contStartIdx]
      body.add quote do:
        `envId`.fn = `firstContStep`
        return `envId`

  for i in 0 ..< numSteps:
    let seg = segments[i]
    let envId = ident"env"
    let cParam = ident"c"
    var stepBody = newStmtList()

    let preambleHalt = genHalt(envId)
    stepBody.add quote do:
      let `envId` = `envTypeInst`(`cParam`)
      if `finishedSym`(`envId`.fut):
        `preambleHalt`
        return `envId`

    # Resolve break/continue targets for this segment
    let brTarget = if seg.breakTargetIdx >= 0 and seg.breakTargetIdx < numSteps:
      stepNames[seg.breakTargetIdx]
    else:
      nil
    let ctTarget = if seg.continueTargetIdx >= 0 and seg.continueTargetIdx < numSteps:
      stepNames[seg.continueTargetIdx]
    else:
      nil

    case seg.kind
    of skNormal:
      for s in seg.preStmts:
        stepBody.add rewrite(s, knownNames, brTarget, ctTarget)

      if seg.hasAwait:
        generateNormalAwaitStep(seg, i, stepBody, envId, envTypeName)
      else:
        generateTransition(seg, i, stepBody, envId)

    of skIfDispatch:
      for s in seg.preStmts:
        stepBody.add rewrite(s, knownNames, brTarget, ctTarget)

      let afterIfStep = if seg.afterIfIdx < numSteps:
        stepNames[seg.afterIfIdx]
      else: nil

      var ifStmt = nnkIfStmt.newTree()

      for br in seg.ifBranches:
        var branchBody = newStmtList()
        for s in br.preStmts:
          branchBody.add rewrite(s, knownNames, brTarget, ctTarget)

        if br.hasAwait and br.contCount > 0:
          genBranchAwaitOrTransition(br, branchBody, envId)
        else:
          branchBody.add genStepTransition(envId, afterIfStep)

        if br.condition.kind == nnkEmpty:
          ifStmt.add nnkElse.newTree(branchBody)
        else:
          ifStmt.add nnkElifBranch.newTree(
            rewrite(br.condition, knownNames), branchBody)

      stepBody.add ifStmt

      # Fallthrough (no else branch matched)
      if seg.ifBranches.len > 0 and seg.ifBranches[^1].condition.kind != nnkEmpty:
        stepBody.add genStepTransition(envId, afterIfStep)

    of skWhileEntry:
      let afterWhileStep = if seg.afterWhileIdx < numSteps:
        stepNames[seg.afterWhileIdx]
      else: nil
      let whCtTarget = stepNames[seg.whileCondStepIdx]

      for s in seg.preStmts:
        stepBody.add rewrite(s, knownNames, afterWhileStep, whCtTarget)

      let whileCond = rewrite(seg.whileCond, knownNames, afterWhileStep, whCtTarget)
      let br = seg.whileBodyBranch

      var trueBody = newStmtList()
      for s in br.preStmts:
        trueBody.add rewrite(s, knownNames, afterWhileStep, whCtTarget)

      if br.hasAwait and br.contCount > 0:
        genBranchAwaitOrTransition(br, trueBody, envId)
      else:
        # No await in while body — loop back to condition
        let condStep = stepNames[seg.whileCondStepIdx]
        trueBody.add quote do:
          `envId`.fn = `condStep`
          return `envId`

      let falseBody = newStmtList(genStepTransition(envId, afterWhileStep))

      stepBody.add nnkIfStmt.newTree(
        nnkElifBranch.newTree(whileCond, trueBody),
        nnkElse.newTree(falseBody)
      )

    let stepBareName = stepBareNames[i]
    let stepProc = quote do:
      proc `stepBareName`(`cParam`: sink Continuation): Continuation {.nimcall.} =
        `stepBody`
    addUnreachableWarningPragma(stepProc)
    applyGenericParams(stepProc)
    stepProcs.add stepProc

  # ============================================================
  # Phase 4: Generate wrapper proc
  # ============================================================

  let firstStep = stepNames[0]
  let envLocal = ident"env"
  var wrapperBody = newStmtList()

  wrapperBody.add quote do:
    var `envLocal` = `envTypeInst`()
    `envLocal`.fn = `firstStep`
    `envLocal`.state = csRunning
    `envLocal`.runtimeOwner = `currentRuntimeSym`().runtime

  if isVoid:
    wrapperBody.add quote do:
      `envLocal`.fut = `newVoidFutureSym`()
  else:
    wrapperBody.add quote do:
      `envLocal`.fut = `newTypedFutureSym`[`innerResultType`]()

  for (name, _) in procParams:
    let nameId = ident(name)
    wrapperBody.add quote do:
      `envLocal`.`nameId` = `nameId`

  wrapperBody.add quote do:
    `setFutureRootContinuationSym`(`envLocal`.fut, `envLocal`)

  wrapperBody.add quote do:
    discard `runSym`(`envLocal`)
    return `envLocal`.fut

  let wrapperProc = newProc(name = procName, params = buildWrapperParams(), body = wrapperBody)
  wrapperProc[4] = newEmptyNode()
  applyGenericParams(wrapperProc)

  # Forward declare wrapper proc for recursive self-calls
  let wrapperFwd = newProc(name = procName, params = buildWrapperParams(), body = newEmptyNode())
  wrapperFwd[4] = newEmptyNode()
  applyGenericParams(wrapperFwd)

  # Build forward declarations for step functions
  let forwardDecls = collect:
    for sn in stepBareNames:
      let cp = ident"c"
      let fwd = quote do:
        proc `sn`(`cp`: sink Continuation): Continuation {.nimcall.}
      applyGenericParams(fwd)
      fwd

  result = newStmtList()
  result.add wrapperFwd  # Before aliases: needed for recursive typeof refs
  for ta in typeAliases:
    result.add ta
  result.add typeSection
  for fd in forwardDecls:
    result.add fd
  for sp in stepProcs:
    result.add sp
  result.add wrapperProc

