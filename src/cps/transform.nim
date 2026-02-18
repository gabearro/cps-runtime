## CPS Transformation Macro
##
## Transforms normal Nim procedures into continuation-passing style.
## The `cps` macro rewrites a proc so that every "suspend point"
## (calls to other CPS procs via `await`) splits the body into a
## chain of continuation steps.
##
## Supports `await` inside try/except blocks: the future's error is
## re-raised inside a matching try/except so Nim handles dispatch.

import std/[macros, sets, tables, sequtils]
import ./runtime

type
  VarInfo = object
    name: string
    typ: NimNode     # explicit type (may be nnkEmpty)
    defVal: NimNode  # default value expression (may be nnkEmpty)

proc isAwaitCall(n: NimNode): bool =
  n.kind in {nnkCall, nnkCommand} and n[0].kind == nnkIdent and $n[0] == "await"

proc hasNestedAwait(n: NimNode): bool =
  ## Check if any descendant node is an await call.
  if n.isAwaitCall: return true
  for child in n:
    if hasNestedAwait(child): return true
  return false

var liftAwaitCounter {.compileTime.}: int = 0

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
      nnkIdentDefs.newTree(tmpName, newEmptyNode(), n.copyNimTree())
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

  # Top-level patterns already handled by splitStmtForAwait — skip them
  if s.isAwaitCall:
    return @[s]
  if s.kind in {nnkLetSection, nnkVarSection} and s[0].kind == nnkIdentDefs and
     s[0][^1].isAwaitCall:
    return @[s]
  if s.kind == nnkDiscardStmt and s[0].isAwaitCall:
    return @[s]
  if s.kind == nnkAsgn and s[1].isAwaitCall:
    return @[s]
  if s.kind == nnkReturnStmt and s[0].isAwaitCall:
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

  # for i in a ..< b  →  var _cpsEnd_i = b; var i = a - 1; while true: inc i; if i >= _cpsEnd_i: break; <body>
  if iterExpr.kind == nnkInfix and $iterExpr[0] == "..<":
    let startVal = iterExpr[1]
    let endVal = iterExpr[2]
    let endVar = ident("_cpsEnd_" & $loopVar)
    result = newStmtList()
    # var _cpsEnd_i = b  (capture end value before the loop)
    result.add nnkVarSection.newTree(
      nnkIdentDefs.newTree(endVar, newEmptyNode(), endVal.copyNimTree()))
    # var i = a - 1
    result.add nnkVarSection.newTree(
      nnkIdentDefs.newTree(loopVar.copyNimTree(), newEmptyNode(),
        nnkInfix.newTree(ident"-", startVal.copyNimTree(), newIntLitNode(1)))
    )
    var whileBody = newStmtList()
    whileBody.add nnkCommand.newTree(ident"inc", loopVar.copyNimTree())
    whileBody.add nnkIfStmt.newTree(
      nnkElifBranch.newTree(
        nnkInfix.newTree(ident">=", loopVar.copyNimTree(), endVar.copyNimTree()),
        newStmtList(nnkBreakStmt.newTree(newEmptyNode()))
      )
    )
    for s in body:
      whileBody.add s.copyNimTree()
    result.add nnkWhileStmt.newTree(ident"true", whileBody)
    return result

  # for i in a .. b  →  var _cpsEnd_i = b; var i = a - 1; while true: inc i; if i > _cpsEnd_i: break; <body>
  if iterExpr.kind == nnkInfix and $iterExpr[0] == "..":
    let startVal = iterExpr[1]
    let endVal = iterExpr[2]
    let endVar = ident("_cpsEnd_" & $loopVar)
    result = newStmtList()
    result.add nnkVarSection.newTree(
      nnkIdentDefs.newTree(endVar, newEmptyNode(), endVal.copyNimTree()))
    result.add nnkVarSection.newTree(
      nnkIdentDefs.newTree(loopVar.copyNimTree(), newEmptyNode(),
        nnkInfix.newTree(ident"-", startVal.copyNimTree(), newIntLitNode(1)))
    )
    var whileBody = newStmtList()
    whileBody.add nnkCommand.newTree(ident"inc", loopVar.copyNimTree())
    whileBody.add nnkIfStmt.newTree(
      nnkElifBranch.newTree(
        nnkInfix.newTree(ident">", loopVar.copyNimTree(), endVar.copyNimTree()),
        newStmtList(nnkBreakStmt.newTree(newEmptyNode()))
      )
    )
    for s in body:
      whileBody.add s.copyNimTree()
    result.add nnkWhileStmt.newTree(ident"true", whileBody)
    return result

  # for i in countdown(b, a)  →  var _cpsEnd_i = a; var i = b + 1; while true: dec i; if i < _cpsEnd_i: break; <body>
  if iterExpr.kind == nnkCall and $iterExpr[0] == "countdown" and iterExpr.len >= 3:
    let startVal = iterExpr[1]  # high value
    let endVal = iterExpr[2]    # low value
    let endVar = ident("_cpsEnd_" & $loopVar)
    result = newStmtList()
    result.add nnkVarSection.newTree(
      nnkIdentDefs.newTree(endVar, newEmptyNode(), endVal.copyNimTree()))
    result.add nnkVarSection.newTree(
      nnkIdentDefs.newTree(loopVar.copyNimTree(), newEmptyNode(),
        nnkInfix.newTree(ident"+", startVal.copyNimTree(), newIntLitNode(1)))
    )
    var whileBody = newStmtList()
    whileBody.add nnkCommand.newTree(ident"dec", loopVar.copyNimTree())
    whileBody.add nnkIfStmt.newTree(
      nnkElifBranch.newTree(
        nnkInfix.newTree(ident"<", loopVar.copyNimTree(), endVar.copyNimTree()),
        newStmtList(nnkBreakStmt.newTree(newEmptyNode()))
      )
    )
    for s in body:
      whileBody.add s.copyNimTree()
    result.add nnkWhileStmt.newTree(ident"true", whileBody)
    return result

  # Fallback: iterable container (seq, array, string)
  let numVars = forStmt.len - 2
  let containerExpr = getContainerExpr(iterExpr)

  if numVars == 1:
    let loopVarName = $forStmt[0]
    let contVar = ident("_cpsCont_" & loopVarName)
    let idxVar = ident("_cpsForIdx_" & loopVarName)
    result = newStmtList()
    result.add nnkVarSection.newTree(
      nnkIdentDefs.newTree(contVar, newEmptyNode(), containerExpr.copyNimTree()))
    result.add nnkVarSection.newTree(
      nnkIdentDefs.newTree(idxVar, newEmptyNode(), newIntLitNode(-1)))
    var whileBody = newStmtList()
    whileBody.add nnkCommand.newTree(ident"inc", idxVar.copyNimTree())
    whileBody.add nnkIfStmt.newTree(
      nnkElifBranch.newTree(
        nnkInfix.newTree(ident">=", idxVar.copyNimTree(),
          nnkCall.newTree(ident"len", contVar.copyNimTree())),
        newStmtList(nnkBreakStmt.newTree(newEmptyNode()))))
    whileBody.add nnkVarSection.newTree(
      nnkIdentDefs.newTree(loopVar.copyNimTree(), newEmptyNode(),
        nnkBracketExpr.newTree(contVar.copyNimTree(), idxVar.copyNimTree())))
    for s in body:
      whileBody.add s.copyNimTree()
    result.add nnkWhileStmt.newTree(ident"true", whileBody)
    return result

  elif numVars == 2:
    let idxLoopVar = forStmt[0]
    let elemLoopVar = forStmt[1]
    let elemName = $elemLoopVar
    let contVar = ident("_cpsCont_" & elemName)
    let idxVar = ident("_cpsForIdx_" & elemName)
    result = newStmtList()
    result.add nnkVarSection.newTree(
      nnkIdentDefs.newTree(contVar, newEmptyNode(), containerExpr.copyNimTree()))
    result.add nnkVarSection.newTree(
      nnkIdentDefs.newTree(idxVar, newEmptyNode(), newIntLitNode(-1)))
    var whileBody = newStmtList()
    whileBody.add nnkCommand.newTree(ident"inc", idxVar.copyNimTree())
    whileBody.add nnkIfStmt.newTree(
      nnkElifBranch.newTree(
        nnkInfix.newTree(ident">=", idxVar.copyNimTree(),
          nnkCall.newTree(ident"len", contVar.copyNimTree())),
        newStmtList(nnkBreakStmt.newTree(newEmptyNode()))))
    # var i = idx
    whileBody.add nnkVarSection.newTree(
      nnkIdentDefs.newTree(idxLoopVar.copyNimTree(), newEmptyNode(),
        idxVar.copyNimTree()))
    # var x = container[idx]
    whileBody.add nnkVarSection.newTree(
      nnkIdentDefs.newTree(elemLoopVar.copyNimTree(), newEmptyNode(),
        nnkBracketExpr.newTree(contVar.copyNimTree(), idxVar.copyNimTree())))
    for s in body:
      whileBody.add s.copyNimTree()
    result.add nnkWhileStmt.newTree(ident"true", whileBody)
    return result

  return nil

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
          for i in 0 ..< def.len - 2:
            # Skip vars that are await results (handled separately),
            # UNLESS they have an explicit type annotation — in that case
            # collect them so the explicit type is used for the env field
            # instead of typeof (which may not work in generic contexts).
            if defVal.isAwaitCall:
              if typ.kind != nnkEmpty:
                vars.add VarInfo(name: $def[i], typ: typ, defVal: newEmptyNode())
              continue
            vars.add VarInfo(name: $def[i], typ: typ, defVal: defVal)
    of nnkForStmt:
      # If the for loop has nested await, it will be desugared to var+while+inc.
      # Collect the loop variable(s) so they get env fields.
      if hasNestedAwait(n):
        let iterExpr = n[^2]
        let numVars = n.len - 2

        if numVars == 1:
          let loopVar = $n[0]
          if iterExpr.kind == nnkInfix and ($iterExpr[0] in ["..<", ".."]):
            let endName = "_cpsEnd_" & loopVar
            vars.add VarInfo(name: endName, typ: newEmptyNode(), defVal: iterExpr[2])
            vars.add VarInfo(name: loopVar, typ: newEmptyNode(), defVal: iterExpr[1])
          elif iterExpr.kind == nnkCall and $iterExpr[0] == "countdown" and iterExpr.len >= 3:
            let endName = "_cpsEnd_" & loopVar
            vars.add VarInfo(name: endName, typ: newEmptyNode(), defVal: iterExpr[2])
            vars.add VarInfo(name: loopVar, typ: newEmptyNode(), defVal: iterExpr[1])
          else:
            # Iterable container: add internal vars + element var
            let container = getContainerExpr(iterExpr)
            let contName = "_cpsCont_" & loopVar
            let idxName = "_cpsForIdx_" & loopVar
            vars.add VarInfo(name: contName, typ: newEmptyNode(), defVal: container.copyNimTree())
            vars.add VarInfo(name: idxName, typ: ident"int", defVal: newEmptyNode())
            # Element type inferred from typeof(container[0])
            vars.add VarInfo(name: loopVar, typ: newEmptyNode(),
                             defVal: nnkBracketExpr.newTree(container.copyNimTree(), newIntLitNode(0)))

        elif numVars == 2:
          let idxVar = $n[0]
          let elemVar = $n[1]
          let container = getContainerExpr(iterExpr)
          let contName = "_cpsCont_" & elemVar
          let internalIdxName = "_cpsForIdx_" & elemVar
          vars.add VarInfo(name: contName, typ: newEmptyNode(), defVal: container.copyNimTree())
          vars.add VarInfo(name: internalIdxName, typ: ident"int", defVal: newEmptyNode())
          vars.add VarInfo(name: idxVar, typ: ident"int", defVal: newEmptyNode())
          vars.add VarInfo(name: elemVar, typ: newEmptyNode(),
                           defVal: nnkBracketExpr.newTree(container.copyNimTree(), newIntLitNode(0)))

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

proc splitStmtForAwait(s: NimNode, segments: var seq[Segment],
                       currentPre: var seq[NimNode],
                       exceptBranches: seq[ExceptBranch] = @[],
                       trySegIndices: var seq[int]): bool =
  ## Try to split a statement at an await point. Returns true if handled.
  # let x = await expr
  if s.kind in {nnkLetSection, nnkVarSection}:
    let def = s[0]
    if def.kind == nnkIdentDefs and def[^1].isAwaitCall:
      addAwaitSegment(segments, currentPre, def[^1][1], $def[0], exceptBranches)
      if exceptBranches.len > 0:
        trySegIndices.add segments.len - 1
      return true

  # bare await expr
  if s.isAwaitCall:
    addAwaitSegment(segments, currentPre, s[1], "", exceptBranches)
    if exceptBranches.len > 0:
      trySegIndices.add segments.len - 1
    return true

  # discard await expr
  if s.kind == nnkDiscardStmt and s[0].isAwaitCall:
    addAwaitSegment(segments, currentPre, s[0][1], "", exceptBranches)
    if exceptBranches.len > 0:
      trySegIndices.add segments.len - 1
    return true

  # x = await expr
  if s.kind == nnkAsgn and s[1].isAwaitCall:
    addAwaitSegment(segments, currentPre, s[1][1], $s[0], exceptBranches)
    if exceptBranches.len > 0:
      trySegIndices.add segments.len - 1
    return true

  return false

macro cps*(prc: untyped): untyped =
  expectKind prc, nnkProcDef

  let procName = prc[0]
  let params = prc[3]
  let body = liftAwaitInBody(prc[6])
  let returnType = params[0]

  # Extract base name without export marker for generating internal identifiers
  let procBaseName = if procName.kind == nnkPostfix: $procName[1] else: $procName

  # Extract generic parameters
  let genericParams = prc[2]  # nnkGenericParams or nnkEmpty
  let isGeneric = genericParams.kind == nnkGenericParams
  var genericIdents: seq[NimNode]
  if isGeneric:
    for param in genericParams:
      for j in 0 ..< param.len - 2:
        genericIdents.add param[j]

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
          let sym = bindSym"completedVoidFuture"
          return nnkReturnStmt.newTree(newCall(sym))
        else:
          let sym = bindSym"completedFuture"
          return nnkReturnStmt.newTree(
            nnkBracketExpr.newTree(sym, innerResultType).newCall(n[0])
          )
      else:
        result = n.copyNimNode()
        for child in n:
          result.add rewriteReturns(child)

    let rewrittenBody = rewriteReturns(body)
    var fastBody = newStmtList()

    if isVoid:
      let compSym = bindSym"completedVoidFuture"
      let failSym = bindSym"failedVoidFuture"
      let e = ident"e"
      fastBody.add quote do:
        try:
          `rewrittenBody`
          return `compSym`()
        except CatchableError as `e`:
          return `failSym`(`e`)
    else:
      let failSym = bindSym"failedFuture"
      let e = ident"e"
      # For typed procs, the body should contain return statements (rewritten above).
      # The try/except catches any raised exceptions and returns a failed future.
      fastBody.add quote do:
        try:
          `rewrittenBody`
        except CatchableError as `e`:
          return `failSym`[`innerResultType`](`e`)

    var wrapperParams: seq[NimNode] = @[returnType]
    for i in 1 ..< params.len:
      wrapperParams.add params[i].copyNimTree()

    let fastProc = newProc(name = procName, params = wrapperParams, body = fastBody)
    fastProc[4] = newEmptyNode()  # no pragmas
    if isGeneric:
      fastProc[2] = genericParams.copyNimTree()

    return newStmtList(fastProc)

  # Collect proc parameters
  var procParams: seq[(string, NimNode)]
  for i in 1 ..< params.len:
    let identDef = params[i]
    let typ = identDef[^2]
    for j in 0 ..< identDef.len - 2:
      procParams.add ($identDef[j], typ)

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
      if not foundAwait and (s.isAwaitCall or
          (s.kind in {nnkLetSection, nnkVarSection} and
           s[0].kind == nnkIdentDefs and s[0][^1].isAwaitCall) or
          (s.kind == nnkDiscardStmt and s[0].isAwaitCall) or
          (s.kind == nnkAsgn and s[1].isAwaitCall) or
          hasNestedAwait(s)):
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
      if not handled and s.kind == nnkTryStmt and hasNestedAwait(s[0]):
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
          let hasDirectAwait = (s.isAwaitCall or
            (s.kind in {nnkLetSection, nnkVarSection} and
             s[0].kind == nnkIdentDefs and s[0][^1].isAwaitCall) or
            (s.kind == nnkDiscardStmt and s[0].isAwaitCall) or
            (s.kind == nnkAsgn and s[1].isAwaitCall))
          if hasDirectAwait:
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
      for idx in segsBefore ..< tryBodyEnd:
        var newPreStmts: seq[NimNode]
        var changed = false
        for s in segments[idx].preStmts:
          if s.kind == nnkTryStmt:
            # Extract sync stmts from the try body and re-wrap with updated branches
            var syncStmts: seq[NimNode]
            for child in s[0]:
              syncStmts.add child
            newPreStmts.add rebuildTryExcept(syncStmts, branches)
            changed = true
          else:
            newPreStmts.add s
        if changed:
          segments[idx].preStmts = newPreStmts

    # afterTryIdx = after ALL segments (including handler continuations)
    let afterIdx = segments.len

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
        segments[lastIdx].overrideNextIdx = afterIdx

  var segments: seq[Segment]
  var currentPre: seq[NimNode]

  splitBody(body, segments, currentPre)

  segments.add newNormalSegment(currentPre)

  # ============================================================
  # Phase 2: Build environment type (with await target fields)
  # ============================================================

  var knownNames: HashSet[string]
  for (name, _) in procParams:
    knownNames.incl name
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
  envFields.add nnkIdentDefs.newTree(ident"fut", futureType, newEmptyNode())

  for (name, typ) in procParams:
    envFields.add nnkIdentDefs.newTree(ident(name), typ, newEmptyNode())

  # Map of name -> type expression for typeof rewriting in field definitions.
  var typeMap: Table[string, NimNode]
  for (name, typ) in procParams:
    typeMap[name] = typ

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
              nnkIdentDefs.newTree(tmpIdent, newEmptyNode(), innerExpr)
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
      let rewritten = rewriteForTypeof(v.defVal, typeMap)
      typeMap[v.name] = nnkCall.newTree(ident"typeof", rewritten)

  proc prePopulateAwaitTargets() =
    for seg in segments:
      if seg.hasAwait and seg.awaitTarget != "":
        if seg.awaitTarget notin seenNames:
          seenNames.incl seg.awaitTarget
          knownNames.incl seg.awaitTarget
          typeMap[seg.awaitTarget] = awaitTargetTypeExpr(seg.awaitExpr)
      if seg.kind == skIfDispatch:
        for branch in seg.ifBranches:
          if branch.hasAwait and branch.awaitTarget != "":
            if branch.awaitTarget notin seenNames:
              seenNames.incl branch.awaitTarget
              knownNames.incl branch.awaitTarget
              typeMap[branch.awaitTarget] = awaitTargetTypeExpr(branch.awaitExpr)
      if seg.kind == skWhileEntry:
        if seg.whileBodyBranch.hasAwait and seg.whileBodyBranch.awaitTarget != "":
          if seg.whileBodyBranch.awaitTarget notin seenNames:
            seenNames.incl seg.whileBodyBranch.awaitTarget
            knownNames.incl seg.whileBodyBranch.awaitTarget
            typeMap[seg.whileBodyBranch.awaitTarget] = awaitTargetTypeExpr(seg.whileBodyBranch.awaitExpr)

  prePopulateAwaitTargets()

  # Iterative fixed-point: keep reprocessing locals and await targets until
  # typeMap stabilizes. This handles transitive typeof chains of any depth
  # (e.g., local → await → local → local → await).
  proc reProcessLocals() =
    for v in localVars:
      if v.typ.kind == nnkEmpty and v.defVal.kind notin {nnkEmpty, nnkLambda, nnkDo}:
        let rewritten = rewriteForTypeof(v.defVal, typeMap)
        typeMap[v.name] = nnkCall.newTree(ident"typeof", rewritten)

  proc reProcessAwaitTargets() =
    for seg in segments:
      if seg.hasAwait and seg.awaitTarget != "":
        typeMap[seg.awaitTarget] = awaitTargetTypeExpr(seg.awaitExpr)
      if seg.kind == skIfDispatch:
        for branch in seg.ifBranches:
          if branch.hasAwait and branch.awaitTarget != "":
            typeMap[branch.awaitTarget] = awaitTargetTypeExpr(branch.awaitExpr)
      if seg.kind == skWhileEntry:
        if seg.whileBodyBranch.hasAwait and seg.whileBodyBranch.awaitTarget != "":
          typeMap[seg.whileBodyBranch.awaitTarget] = awaitTargetTypeExpr(seg.whileBodyBranch.awaitExpr)

  for iteration in 0 ..< 5:
    var prevReprs: seq[string]
    for k, v in typeMap:
      prevReprs.add(k & "=" & v.repr)

    reProcessLocals()
    reProcessAwaitTargets()

    var newReprs: seq[string]
    for k, v in typeMap:
      newReprs.add(k & "=" & v.repr)

    if prevReprs == newReprs:
      break  # Fixed point reached

  # Now create aliases for all typeof entries in typeMap
  for v in localVars:
    if v.name in typeMap:
      let entry = typeMap[v.name]
      if entry.kind == nnkCall and entry.len >= 1 and entry[0].kind == nnkIdent and $entry[0] == "typeof":
        typeMap[v.name] = getOrCreateAlias(entry)
  for seg in segments:
    if seg.hasAwait and seg.awaitTarget != "" and seg.awaitTarget in typeMap:
      let entry = typeMap[seg.awaitTarget]
      if entry.kind == nnkCall and entry.len >= 1 and entry[0].kind == nnkIdent and $entry[0] == "typeof":
        typeMap[seg.awaitTarget] = getOrCreateAlias(entry)
    if seg.kind == skIfDispatch:
      for branch in seg.ifBranches:
        if branch.hasAwait and branch.awaitTarget != "" and branch.awaitTarget in typeMap:
          let entry = typeMap[branch.awaitTarget]
          if entry.kind == nnkCall and entry.len >= 1 and entry[0].kind == nnkIdent and $entry[0] == "typeof":
            typeMap[branch.awaitTarget] = getOrCreateAlias(entry)
    if seg.kind == skWhileEntry:
      if seg.whileBodyBranch.hasAwait and seg.whileBodyBranch.awaitTarget != "" and seg.whileBodyBranch.awaitTarget in typeMap:
        let entry = typeMap[seg.whileBodyBranch.awaitTarget]
        if entry.kind == nnkCall and entry.len >= 1 and entry[0].kind == nnkIdent and $entry[0] == "typeof":
          typeMap[seg.whileBodyBranch.awaitTarget] = getOrCreateAlias(entry)

  # Add local variable fields first (original ordering preserved for env layout)
  for v in localVars:
    if v.typ.kind != nnkEmpty:
      envFields.add nnkIdentDefs.newTree(ident(v.name), v.typ, newEmptyNode())
    elif v.defVal.kind in {nnkLambda, nnkDo}:
      # Lambda values: build explicit proc type with {.closure.} pragma
      # to avoid nimcall/closure mismatch after rewriting captures env
      let lambdaParams = v.defVal[3]
      let closureType = nnkProcTy.newTree(
        lambdaParams.copyNimTree(),
        nnkPragma.newTree(ident"closure")
      )
      envFields.add nnkIdentDefs.newTree(ident(v.name), closureType, newEmptyNode())
    elif v.defVal.kind != nnkEmpty:
      # Type was already aliased in typeMap during pre-population
      let alias = typeMap[v.name]
      envFields.add nnkIdentDefs.newTree(ident(v.name), alias, newEmptyNode())

  # Collect local var names so we can skip duplicates in await target fields
  var localVarNames: HashSet[string]
  for v in localVars:
    localVarNames.incl v.name

  # Add await target fields (after local vars in the env layout)
  var emittedAwaitFields: HashSet[string]
  proc addAwaitTargetField(awaitTarget: string, awaitExpr: NimNode) =
    # Skip if already emitted as a local var field or await field
    if awaitTarget != "" and awaitTarget notin emittedAwaitFields and
       awaitTarget notin localVarNames:
      emittedAwaitFields.incl awaitTarget
      # Type was already pre-populated in typeMap above
      let typeofExpr = typeMap[awaitTarget]
      envFields.add nnkIdentDefs.newTree(
        ident(awaitTarget),
        typeofExpr,
        newEmptyNode()
      )

  for seg in segments:
    if seg.hasAwait and seg.awaitTarget != "":
      addAwaitTargetField(seg.awaitTarget, seg.awaitExpr)
    if seg.kind == skIfDispatch:
      for branch in seg.ifBranches:
        if branch.hasAwait and branch.awaitTarget != "":
          addAwaitTargetField(branch.awaitTarget, branch.awaitExpr)
    if seg.kind == skWhileEntry:
      if seg.whileBodyBranch.hasAwait and seg.whileBodyBranch.awaitTarget != "":
        addAwaitTargetField(seg.whileBodyBranch.awaitTarget, seg.whileBodyBranch.awaitExpr)

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
  let failSym = bindSym"fail"
  let completeSym = bindSym"complete"
  let runSym = bindSym"run"
  let currentRuntimeSym = bindSym"currentRuntime"
  let setFutureRootContinuationSym = bindSym"setFutureRootContinuation"

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
          for j in 0 ..< def.len - 2:
            shadowed.excl $def[j]
      result = n.copyNimNode()
      for def in n:
        if def.kind == nnkIdentDefs:
          var newDef = def.copyNimNode()
          for j in 0 ..< def.len - 2:
            newDef.add def[j].copyNimTree()
          newDef.add def[^2].copyNimTree()  # type
          if def[^1].kind != nnkEmpty:
            newDef.add rewriteLambdaBody(def[^1], knownNames)  # value uses outer scope
          else:
            newDef.add def[^1].copyNimTree()
          result.add newDef
        else:
          result.add def.copyNimTree()
    of nnkProcDef, nnkFuncDef, nnkLambda, nnkDo:
      # Nested proc inside a lambda - exclude its params too
      var innerKnown = knownNames
      let formalParams = n[3]
      if formalParams.kind == nnkFormalParams:
        for i in 1 ..< formalParams.len:
          let identDef = formalParams[i]
          for j in 0 ..< identDef.len - 2:
            innerKnown.excl $identDef[j]
      var innerLocals: seq[VarInfo]
      if n[6].kind != nnkEmpty:
        collectLocals(n[6], innerLocals)
        for v in innerLocals:
          innerKnown.excl v.name
      result = n.copyNimNode()
      for i in 0 ..< n.len:
        if i == 6 and n[6].kind != nnkEmpty:
          result.add rewriteLambdaBody(n[6], innerKnown)
        else:
          result.add n[i].copyNimTree()
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
               continueTarget: NimNode = nil): NimNode =
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
          for j in 0 ..< def.len - 2:
            let varName = $def[j]
            if defVal.kind != nnkEmpty:
              result.add newAssignment(
                newDotExpr(envId, ident(varName)),
                rewrite(defVal, knownNames, breakTarget, continueTarget)
              )
      return result
    of nnkReturnStmt:
      if n[0].kind == nnkEmpty or isVoid:
        return quote do:
          `completeSym`(`envId`.fut)
          `envId`.state = csFinished
          `envId`.fn = nil
          return `envId`
      else:
        let retVal = rewrite(n[0], knownNames, breakTarget, continueTarget)
        return quote do:
          `completeSym`(`envId`.fut, `retVal`)
          `envId`.state = csFinished
          `envId`.fn = nil
          return `envId`
    of nnkRaiseStmt:
      if n[0].kind == nnkEmpty:
        let getCurExc = ident"getCurrentException"
        return quote do:
          `failSym`(`envId`.fut, `getCurExc`())
          `envId`.state = csFinished
          `envId`.fn = nil
          return `envId`
      else:
        let errExpr = rewrite(n[0], knownNames, breakTarget, continueTarget)
        return quote do:
          `failSym`(`envId`.fut, `errExpr`)
          `envId`.state = csFinished
          `envId`.fn = nil
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
    of nnkExprColonExpr, nnkExprEqExpr:
      # Object constructor field or keyword arg: don't rewrite the field name (first child)
      result = n.copyNimNode()
      result.add n[0].copyNimTree()  # field name stays as-is
      result.add rewrite(n[1], knownNames, breakTarget, continueTarget)  # value is rewritten
    of nnkDotExpr:
      # Field access: rewrite the object (left) but not the field name (right)
      result = n.copyNimNode()
      result.add rewrite(n[0], knownNames, breakTarget, continueTarget)
      result.add n[1].copyNimTree()  # field name stays as-is
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
      result.add rewrite(n[^1], exceptKnown, breakTarget, continueTarget)
    of nnkSym:
      return n
    of nnkProcDef, nnkFuncDef, nnkLambda, nnkDo:
      # Nested proc/lambda: exclude its formal parameters from knownNames
      # and don't rewrite return/raise inside the nested body.
      var innerKnown = knownNames
      let formalParams = n[3]  # params node
      if formalParams.kind == nnkFormalParams:
        for i in 1 ..< formalParams.len:
          let identDef = formalParams[i]
          for j in 0 ..< identDef.len - 2:
            innerKnown.excl $identDef[j]
      var innerLocals: seq[VarInfo]
      if n[6].kind != nnkEmpty:
        collectLocals(n[6], innerLocals)
        for v in innerLocals:
          innerKnown.excl v.name
      result = n.copyNimNode()
      for i in 0 ..< n.len:
        if i == 6 and n[6].kind != nnkEmpty:
          result.add rewriteLambdaBody(n[6], innerKnown)
        else:
          result.add n[i].copyNimTree()
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
        result.add rewrite(child, knownNames, breakTarget, continueTarget)
    else:
      result = n.copyNimNode()
      for child in n:
        result.add rewrite(child, knownNames, breakTarget, continueTarget)

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

  # Keep bare idents for proc definitions; make stepNames instantiated for transitions
  var stepBareNames: seq[NimNode]
  for i in 0 ..< numSteps:
    stepBareNames.add stepNames[i]
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
        # Use a local except binding to capture the exception, then store
        # it in the env and transition to the handler's first step.
        let handlerStep = stepNames[branch.handlerContStartIdx]

        if branch.types.len > 0:
          let excLocal = ident"_cpsExcLocal"
          for t in branch.types:
            eb.add nnkInfix.newTree(ident"as", t.copyNimTree(), excLocal)

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
          # Bare except with await
          let excLocal = ident"_cpsExcLocal"
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
    var hasBareExcept = false
    for branch in seg.exceptBranches:
      if branch.types.len == 0:
        hasBareExcept = true
        break
      # CatchableError or Exception already covers everything
      for t in branch.types:
        if $t in ["CatchableError", "Exception"]:
          hasBareExcept = true
          break

    if not hasBareExcept:
      var catchAll = nnkExceptBranch.newTree()
      let catchVar = ident"_cpsUnmatched"
      catchAll.add nnkInfix.newTree(ident"as", ident"CatchableError", catchVar)
      var catchBody = newStmtList()
      catchBody.add quote do:
        `failSym`(`envId`.fut, `catchVar`)
        `envId`.state = csFinished
        `envId`.fn = nil
      catchAll.add catchBody
      tryNode.add catchAll

    return tryNode

  var stepProcs: seq[NimNode]

  # Helper: generate the await handling code for a normal segment.
  proc generateNormalAwaitStep(seg: Segment, i: int, stepBody: var NimNode,
                                envId, envTypeName: NimNode) =
    let futExpr = rewrite(seg.awaitExpr, knownNames)
    let af = ident"awaitFut"

    stepBody.add quote do:
      let `af` = `futExpr`

    let hasTryCtx = seg.exceptBranches.len > 0

    let nextIdx = if seg.overrideNextIdx >= 0: seg.overrideNextIdx else: i + 1
    if nextIdx < numSteps:
      let nextStepName = stepNames[nextIdx]

      if seg.awaitTarget != "":
        let tf = ident(seg.awaitTarget)

        if hasTryCtx:
          let afterStep = stepNames[seg.afterTryIdx]
          let inlineExceptTransition = quote do:
            `envId`.fn = `afterStep`
            return `envId`
          let callbackExceptTransition = quote do:
            `envId`.fn = `afterStep`
            discard `runSym`(`envId`)

          let inlineTry = buildExceptReraise(af, envId, seg, inlineExceptTransition)
          let callbackTry = buildExceptReraise(af, envId, seg, callbackExceptTransition, forCallback = true)

          stepBody.add quote do:
            if `af`.finished:
              if `hasErrorSym`(`af`):
                `inlineTry`
                return `envId`
              `envId`.`tf` = `readSym`(`af`)
              `envId`.fn = `nextStepName`
              return `envId`
            else:
              `addCallbackSym`(`af`, proc() =
                if `hasErrorSym`(`af`):
                  `callbackTry`
                else:
                  `envId`.`tf` = `readSym`(`af`)
                  `envId`.fn = `nextStepName`
                  discard `runSym`(`envId`)
              )
              `envId`.fn = nil
              `envId`.state = csSuspended
              return `envId`
        else:
          stepBody.add quote do:
            if `af`.finished:
              if `hasErrorSym`(`af`):
                `failSym`(`envId`.fut, `getErrorSym`(`af`))
                `envId`.state = csFinished
                `envId`.fn = nil
                return `envId`
              `envId`.`tf` = `readSym`(`af`)
              `envId`.fn = `nextStepName`
              return `envId`
            else:
              `addCallbackSym`(`af`, proc() =
                if `hasErrorSym`(`af`):
                  `failSym`(`envId`.fut, `getErrorSym`(`af`))
                else:
                  `envId`.`tf` = `readSym`(`af`)
                  `envId`.fn = `nextStepName`
                  discard `runSym`(`envId`)
              )
              `envId`.fn = nil
              `envId`.state = csSuspended
              return `envId`
      else:
        # No await target
        if hasTryCtx:
          let afterStep = stepNames[seg.afterTryIdx]
          let inlineExceptTransition = quote do:
            `envId`.fn = `afterStep`
            return `envId`
          let callbackExceptTransition = quote do:
            `envId`.fn = `afterStep`
            discard `runSym`(`envId`)

          let inlineTry = buildExceptReraise(af, envId, seg, inlineExceptTransition)
          let callbackTry = buildExceptReraise(af, envId, seg, callbackExceptTransition, forCallback = true)

          stepBody.add quote do:
            if `af`.finished:
              if `hasErrorSym`(`af`):
                `inlineTry`
                return `envId`
              `envId`.fn = `nextStepName`
              return `envId`
            else:
              `addCallbackSym`(`af`, proc() =
                if `hasErrorSym`(`af`):
                  `callbackTry`
                else:
                  `envId`.fn = `nextStepName`
                  discard `runSym`(`envId`)
              )
              `envId`.fn = nil
              `envId`.state = csSuspended
              return `envId`
        else:
          stepBody.add quote do:
            if `af`.finished:
              if `hasErrorSym`(`af`):
                `failSym`(`envId`.fut, `getErrorSym`(`af`))
                `envId`.state = csFinished
                `envId`.fn = nil
                return `envId`
              `envId`.fn = `nextStepName`
              return `envId`
            else:
              `addCallbackSym`(`af`, proc() =
                if `hasErrorSym`(`af`):
                  `failSym`(`envId`.fut, `getErrorSym`(`af`))
                else:
                  `envId`.fn = `nextStepName`
                  discard `runSym`(`envId`)
              )
              `envId`.fn = nil
              `envId`.state = csSuspended
              return `envId`
    else:
      # Last segment with await
      if seg.awaitTarget != "":
        let tf = ident(seg.awaitTarget)
        if isVoid:
          stepBody.add quote do:
            if `af`.finished:
              `envId`.`tf` = `readSym`(`af`)
              `completeSym`(`envId`.fut)
              `envId`.state = csFinished
              `envId`.fn = nil
              return `envId`
            else:
              `addCallbackSym`(`af`, proc() =
                if `hasErrorSym`(`af`):
                  `failSym`(`envId`.fut, `getErrorSym`(`af`))
                else:
                  `envId`.`tf` = `readSym`(`af`)
                  `completeSym`(`envId`.fut)
              )
              `envId`.fn = nil
              `envId`.state = csSuspended
              return `envId`
        else:
          stepBody.add quote do:
            if `af`.finished:
              `envId`.`tf` = `readSym`(`af`)
              `completeSym`(`envId`.fut, `envId`.`tf`)
              `envId`.state = csFinished
              `envId`.fn = nil
              return `envId`
            else:
              `addCallbackSym`(`af`, proc() =
                if `hasErrorSym`(`af`):
                  `failSym`(`envId`.fut, `getErrorSym`(`af`))
                else:
                  `envId`.`tf` = `readSym`(`af`)
                  `completeSym`(`envId`.fut, `envId`.`tf`)
              )
              `envId`.fn = nil
              `envId`.state = csSuspended
              return `envId`
      else:
        stepBody.add quote do:
          if `af`.finished:
            if `hasErrorSym`(`af`):
              `failSym`(`envId`.fut, `getErrorSym`(`af`))
            else:
              `completeSym`(`envId`.fut)
            `envId`.state = csFinished
            `envId`.fn = nil
            return `envId`
          else:
            `addCallbackSym`(`af`, proc() =
              if `hasErrorSym`(`af`):
                `failSym`(`envId`.fut, `getErrorSym`(`af`))
              else:
                `completeSym`(`envId`.fut)
            )
            `envId`.fn = nil
            `envId`.state = csSuspended
            return `envId`

  # Helper: generate transition to next step (no await).
  proc generateTransition(seg: Segment, i: int, stepBody: var NimNode,
                          envId: NimNode) =
    let nextIdx = if seg.overrideNextIdx >= 0: seg.overrideNextIdx else: i + 1
    if nextIdx < numSteps:
      let nextName = stepNames[nextIdx]
      stepBody.add quote do:
        `envId`.fn = `nextName`
        return `envId`
    else:
      if isVoid:
        stepBody.add quote do:
          `completeSym`(`envId`.fut)
          `envId`.state = csFinished
          `envId`.fn = nil
          return `envId`
      else:
        stepBody.add quote do:
          `envId`.state = csFinished
          `envId`.fn = nil
          return `envId`

  for i in 0 ..< numSteps:
    let seg = segments[i]
    let envId = ident"env"
    let cParam = ident"c"
    var stepBody = newStmtList()

    stepBody.add quote do:
      let `envId` = `envTypeInst`(`cParam`)

    case seg.kind
    of skNormal:
      # Determine break/continue targets for rewrite
      let brTarget = if seg.breakTargetIdx >= 0 and seg.breakTargetIdx < numSteps:
        stepNames[seg.breakTargetIdx]
      else:
        nil
      let ctTarget = if seg.continueTargetIdx >= 0 and seg.continueTargetIdx < numSteps:
        stepNames[seg.continueTargetIdx]
      else:
        nil

      for s in seg.preStmts:
        stepBody.add rewrite(s, knownNames, brTarget, ctTarget)

      if seg.hasAwait:
        generateNormalAwaitStep(seg, i, stepBody, envId, envTypeName)
      else:
        generateTransition(seg, i, stepBody, envId)

    of skIfDispatch:
      # Determine break/continue targets from enclosing loop
      let ifBrTarget = if seg.breakTargetIdx >= 0 and seg.breakTargetIdx < numSteps:
        stepNames[seg.breakTargetIdx]
      else:
        nil
      let ifCtTarget = if seg.continueTargetIdx >= 0 and seg.continueTargetIdx < numSteps:
        stepNames[seg.continueTargetIdx]
      else:
        nil

      # Emit preStmts (code before the if statement)
      for s in seg.preStmts:
        stepBody.add rewrite(s, knownNames, ifBrTarget, ifCtTarget)

      let afterIfStep = if seg.afterIfIdx < numSteps:
        stepNames[seg.afterIfIdx]
      else:
        nil

      # Build the if/elif/else statement
      var ifStmt = nnkIfStmt.newTree()

      for br in seg.ifBranches:
        var branchBody = newStmtList()

        # Emit sync preStmts for this branch
        for s in br.preStmts:
          branchBody.add rewrite(s, knownNames, ifBrTarget, ifCtTarget)

        if br.hasAwait and br.contCount > 0:
          # Branch has await - check if first continuation is a direct await
          let firstCont = segments[br.contStartIdx]
          if firstCont.hasAwait:
            # Inline the await handling directly in the branch
            let futExpr = rewrite(firstCont.awaitExpr, knownNames)
            let af = genSym(nskLet, "awaitFut")

            branchBody.add quote do:
              let `af` = `futExpr`

            let contNextIdx = if firstCont.overrideNextIdx >= 0:
              firstCont.overrideNextIdx
            elif br.contStartIdx + 1 < numSteps:
              br.contStartIdx + 1
            else:
              numSteps  # past end = complete

            if contNextIdx < numSteps:
              let contNextStep = stepNames[contNextIdx]
              if firstCont.awaitTarget != "":
                let tf = ident(firstCont.awaitTarget)
                branchBody.add quote do:
                  if `af`.finished:
                    if `hasErrorSym`(`af`):
                      `failSym`(`envId`.fut, `getErrorSym`(`af`))
                      `envId`.state = csFinished
                      `envId`.fn = nil
                      return `envId`
                    `envId`.`tf` = `readSym`(`af`)
                    `envId`.fn = `contNextStep`
                    return `envId`
                  else:
                    `addCallbackSym`(`af`, proc() =
                      if `hasErrorSym`(`af`):
                        `failSym`(`envId`.fut, `getErrorSym`(`af`))
                      else:
                        `envId`.`tf` = `readSym`(`af`)
                        `envId`.fn = `contNextStep`
                        discard `runSym`(`envId`)
                    )
                    `envId`.fn = nil
                    `envId`.state = csSuspended
                    return `envId`
              else:
                branchBody.add quote do:
                  if `af`.finished:
                    if `hasErrorSym`(`af`):
                      `failSym`(`envId`.fut, `getErrorSym`(`af`))
                      `envId`.state = csFinished
                      `envId`.fn = nil
                      return `envId`
                    `envId`.fn = `contNextStep`
                    return `envId`
                  else:
                    `addCallbackSym`(`af`, proc() =
                      if `hasErrorSym`(`af`):
                        `failSym`(`envId`.fut, `getErrorSym`(`af`))
                      else:
                        `envId`.fn = `contNextStep`
                        discard `runSym`(`envId`)
                    )
                    `envId`.fn = nil
                    `envId`.state = csSuspended
                    return `envId`
            else:
              # Last segment - complete the future
              if firstCont.awaitTarget != "":
                let tf = ident(firstCont.awaitTarget)
                if isVoid:
                  branchBody.add quote do:
                    if `af`.finished:
                      `envId`.`tf` = `readSym`(`af`)
                      `completeSym`(`envId`.fut)
                      `envId`.state = csFinished
                      `envId`.fn = nil
                      return `envId`
                    else:
                      `addCallbackSym`(`af`, proc() =
                        if `hasErrorSym`(`af`):
                          `failSym`(`envId`.fut, `getErrorSym`(`af`))
                        else:
                          `envId`.`tf` = `readSym`(`af`)
                          `completeSym`(`envId`.fut)
                      )
                      `envId`.fn = nil
                      `envId`.state = csSuspended
                      return `envId`
                else:
                  branchBody.add quote do:
                    if `af`.finished:
                      `envId`.`tf` = `readSym`(`af`)
                      `completeSym`(`envId`.fut, `envId`.`tf`)
                      `envId`.state = csFinished
                      `envId`.fn = nil
                      return `envId`
                    else:
                      `addCallbackSym`(`af`, proc() =
                        if `hasErrorSym`(`af`):
                          `failSym`(`envId`.fut, `getErrorSym`(`af`))
                        else:
                          `envId`.`tf` = `readSym`(`af`)
                          `completeSym`(`envId`.fut, `envId`.`tf`)
                      )
                      `envId`.fn = nil
                      `envId`.state = csSuspended
                      return `envId`
              else:
                branchBody.add quote do:
                  if `af`.finished:
                    if `hasErrorSym`(`af`):
                      `failSym`(`envId`.fut, `getErrorSym`(`af`))
                    else:
                      `completeSym`(`envId`.fut)
                    `envId`.state = csFinished
                    `envId`.fn = nil
                    return `envId`
                  else:
                    `addCallbackSym`(`af`, proc() =
                      if `hasErrorSym`(`af`):
                        `failSym`(`envId`.fut, `getErrorSym`(`af`))
                      else:
                        `completeSym`(`envId`.fut)
                    )
                    `envId`.fn = nil
                    `envId`.state = csSuspended
                    return `envId`
          else:
            # First continuation is not a direct await (e.g. nested control flow)
            # Transition to the first continuation segment
            let firstContStep = stepNames[br.contStartIdx]
            branchBody.add quote do:
              `envId`.fn = `firstContStep`
              return `envId`
        else:
          # No await in this branch - execute preStmts and jump to afterIf
          if afterIfStep != nil:
            branchBody.add quote do:
              `envId`.fn = `afterIfStep`
              return `envId`
          else:
            if isVoid:
              branchBody.add quote do:
                `completeSym`(`envId`.fut)
                `envId`.state = csFinished
                `envId`.fn = nil
                return `envId`
            else:
              branchBody.add quote do:
                `envId`.state = csFinished
                `envId`.fn = nil
                return `envId`

        if br.condition.kind == nnkEmpty:
          # else branch
          var elseBranch = nnkElse.newTree(branchBody)
          ifStmt.add elseBranch
        else:
          var elifBranch = nnkElifBranch.newTree(
            rewrite(br.condition, knownNames),
            branchBody
          )
          ifStmt.add elifBranch

      stepBody.add ifStmt

      # Fallthrough (no else, no branch matched): jump to afterIf
      if seg.ifBranches.len > 0 and seg.ifBranches[^1].condition.kind != nnkEmpty:
        # No else branch - add fallthrough
        if afterIfStep != nil:
          stepBody.add quote do:
            `envId`.fn = `afterIfStep`
            return `envId`
        else:
          if isVoid:
            stepBody.add quote do:
              `completeSym`(`envId`.fut)
              `envId`.state = csFinished
              `envId`.fn = nil
              return `envId`
          else:
            stepBody.add quote do:
              `envId`.state = csFinished
              `envId`.fn = nil
              return `envId`

    of skWhileEntry:
      # Break target = afterWhile, continue target = this condition step
      let whBrTarget = if seg.afterWhileIdx < numSteps:
        stepNames[seg.afterWhileIdx]
      else:
        nil
      let whCtTarget = stepNames[seg.whileCondStepIdx]

      # Emit preStmts (shouldn't have any, but just in case)
      for s in seg.preStmts:
        stepBody.add rewrite(s, knownNames, whBrTarget, whCtTarget)

      let afterWhileStep = if seg.afterWhileIdx < numSteps:
        stepNames[seg.afterWhileIdx]
      else:
        nil

      let whileCond = rewrite(seg.whileCond, knownNames, whBrTarget, whCtTarget)
      let br = seg.whileBodyBranch

      var trueBody = newStmtList()

      # Emit sync preStmts for the body
      for s in br.preStmts:
        trueBody.add rewrite(s, knownNames, whBrTarget, whCtTarget)

      if br.hasAwait and br.contCount > 0:
        let firstCont = segments[br.contStartIdx]
        if firstCont.hasAwait:
          # Inline the await handling in the while body
          let futExpr = rewrite(firstCont.awaitExpr, knownNames)
          let af = genSym(nskLet, "awaitFut")

          trueBody.add quote do:
            let `af` = `futExpr`

          let contNextIdx = if firstCont.overrideNextIdx >= 0:
            firstCont.overrideNextIdx
          elif br.contStartIdx + 1 < numSteps:
            br.contStartIdx + 1
          else:
            numSteps

          if contNextIdx < numSteps:
            let contNextStep = stepNames[contNextIdx]
            if firstCont.awaitTarget != "":
              let tf = ident(firstCont.awaitTarget)
              trueBody.add quote do:
                if `af`.finished:
                  if `hasErrorSym`(`af`):
                    `failSym`(`envId`.fut, `getErrorSym`(`af`))
                    `envId`.state = csFinished
                    `envId`.fn = nil
                    return `envId`
                  `envId`.`tf` = `readSym`(`af`)
                  `envId`.fn = `contNextStep`
                  return `envId`
                else:
                  `addCallbackSym`(`af`, proc() =
                    if `hasErrorSym`(`af`):
                      `failSym`(`envId`.fut, `getErrorSym`(`af`))
                    else:
                      `envId`.`tf` = `readSym`(`af`)
                      `envId`.fn = `contNextStep`
                      discard `runSym`(`envId`)
                  )
                  `envId`.fn = nil
                  `envId`.state = csSuspended
                  return `envId`
            else:
              trueBody.add quote do:
                if `af`.finished:
                  if `hasErrorSym`(`af`):
                    `failSym`(`envId`.fut, `getErrorSym`(`af`))
                    `envId`.state = csFinished
                    `envId`.fn = nil
                    return `envId`
                  `envId`.fn = `contNextStep`
                  return `envId`
                else:
                  `addCallbackSym`(`af`, proc() =
                    if `hasErrorSym`(`af`):
                      `failSym`(`envId`.fut, `getErrorSym`(`af`))
                    else:
                      `envId`.fn = `contNextStep`
                      discard `runSym`(`envId`)
                  )
                  `envId`.fn = nil
                  `envId`.state = csSuspended
                  return `envId`
          else:
            # This shouldn't normally happen (while body is last segment)
            let condStep = stepNames[seg.whileCondStepIdx]
            trueBody.add quote do:
              if `af`.finished:
                if `hasErrorSym`(`af`):
                  `failSym`(`envId`.fut, `getErrorSym`(`af`))
                  `envId`.state = csFinished
                  `envId`.fn = nil
                  return `envId`
                `envId`.fn = `condStep`
                return `envId`
              else:
                `addCallbackSym`(`af`, proc() =
                  if `hasErrorSym`(`af`):
                    `failSym`(`envId`.fut, `getErrorSym`(`af`))
                  else:
                    `envId`.fn = `condStep`
                    discard `runSym`(`envId`)
                )
                `envId`.fn = nil
                `envId`.state = csSuspended
                return `envId`
        else:
          # First continuation is not a direct await - transition to it
          let firstContStep = stepNames[br.contStartIdx]
          trueBody.add quote do:
            `envId`.fn = `firstContStep`
            return `envId`
      else:
        # No await in while body (shouldn't happen - we only create skWhileEntry
        # if hasNestedAwait). But handle it: loop back to condition check.
        let condStep = stepNames[seg.whileCondStepIdx]
        trueBody.add quote do:
          `envId`.fn = `condStep`
          return `envId`

      var falseBody = newStmtList()
      if afterWhileStep != nil:
        falseBody.add quote do:
          `envId`.fn = `afterWhileStep`
          return `envId`
      else:
        if isVoid:
          falseBody.add quote do:
            `completeSym`(`envId`.fut)
            `envId`.state = csFinished
            `envId`.fn = nil
            return `envId`
        else:
          falseBody.add quote do:
            `envId`.state = csFinished
            `envId`.fn = nil
            return `envId`

      stepBody.add nnkIfStmt.newTree(
        nnkElifBranch.newTree(whileCond, trueBody),
        nnkElse.newTree(falseBody)
      )

    let stepBareName = stepBareNames[i]
    let stepProc = quote do:
      proc `stepBareName`(`cParam`: sink Continuation): Continuation {.nimcall.} =
        `stepBody`
    if isGeneric:
      stepProc[2] = genericParams.copyNimTree()

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
      `envLocal`.fut = newCpsVoidFuture()
  else:
    wrapperBody.add quote do:
      `envLocal`.fut = newCpsFuture[`innerResultType`]()

  for (name, _) in procParams:
    let nameId = ident(name)
    wrapperBody.add quote do:
      `envLocal`.`nameId` = `nameId`

  wrapperBody.add quote do:
    `setFutureRootContinuationSym`(`envLocal`.fut, `envLocal`)

  wrapperBody.add quote do:
    discard `runSym`(`envLocal`)
    return `envLocal`.fut

  var wrapperParams: seq[NimNode] = @[returnType]
  for i in 1 ..< params.len:
    wrapperParams.add params[i].copyNimTree()

  let wrapperProc = newProc(name = procName, params = wrapperParams, body = wrapperBody)
  wrapperProc[4] = newEmptyNode()
  if isGeneric:
    wrapperProc[2] = genericParams.copyNimTree()

  # Forward declare wrapper proc for recursive self-calls
  var wrapperFwdParams: seq[NimNode] = @[returnType]
  for i in 1 ..< params.len:
    wrapperFwdParams.add params[i].copyNimTree()
  let wrapperFwd = newProc(name = procName, params = wrapperFwdParams, body = newEmptyNode())
  wrapperFwd[4] = newEmptyNode()  # no pragmas
  if isGeneric:
    wrapperFwd[2] = genericParams.copyNimTree()

  # Build forward declarations for step functions
  var forwardDecls: seq[NimNode]
  for i in 0 ..< numSteps:
    let sn = stepBareNames[i]
    let cp = ident"c"
    let fwd = quote do:
      proc `sn`(`cp`: sink Continuation): Continuation {.nimcall.}
    if isGeneric:
      fwd[2] = genericParams.copyNimTree()
    forwardDecls.add fwd

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
