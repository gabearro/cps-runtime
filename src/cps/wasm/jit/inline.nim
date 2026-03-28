## Function inlining pass for the Tier 2 optimizing JIT
##
## Inlines small non-recursive function calls at the IR level.
## Operates on IrFunc after lowering but before optimization.
##
## Design:
##   Single-BB callees: inlined directly into the caller BB (no CF restructuring).
##   Multi-BB callees:  BB splitting + value remapping + continuation BB.
##     The caller's BB is split at the call site:
##       - Pre-call portion stays in the original BB (irBr → callee entry)
##       - Callee BBs are copied with remapped value and BB indices
##       - irReturn in callee → irLocalSet(retSlot) + irBr(continuationBb)
##       - Continuation BB: irLocalGet(callResult) + post-call instructions
##
## Heuristics:
##   - Weighted cost budget: constants are free, mul/div are expensive
##   - Skip callees that themselves contain calls (deep call chains)
##   - Skip recursive self-calls
##   - Multi-BB callees have a slightly higher budget and a BB-count cap
##   - Up to MaxInlinePasses transitive passes (inline into inlined code)

import ../types
import ir, lower, cost

const
  MaxInlineCost* = 40     # weighted instruction cost budget per single-BB callee
  MaxMultiBBInlineCost* = 80   # budget for multi-BB callees (larger since worth unfolding CF)
  MaxInlineBBs* = 8       # max basic blocks a multi-BB callee may have
  MaxInlineExpansion* = 6  # max inline expansions per function per pass
  MaxInlinePasses* = 3    # transitive inlining passes

proc instrCost(op: IrOpKind): int {.inline.} =
  ## Weighted cost for inlining budget. Free ops don't count against the budget.
  case op
  of irConst32, irConst64, irConstF32, irConstF64: 0  # constant-folded away
  of irParam, irNop: 0
  of irMul32, irMul64: 3
  of irDiv32S, irDiv32U, irDiv64S, irDiv64U,
     irRem32S, irRem32U, irRem64S, irRem64U: 6     # expensive
  of irDivF32, irDivF64, irSqrtF32, irSqrtF64: 5   # expensive FP
  of irCall, irCallIndirect, irTrap: 100  # sentinel: reject entire callee
  of irAddF32, irSubF32, irMulF32, irAddF64, irSubF64, irMulF64,
     irFmaF32, irFmsF32, irFnmaF32, irFnmsF32,
     irFmaF64, irFmsF64, irFnmaF64, irFnmsF64: 2   # FP pipeline ops
  else: 1

proc computeCalleeCost(callee: IrFunc): int =
  ## Return total weighted cost of the callee, or MaxInlineCost+1 to reject.
  for bb in callee.blocks:
    for instr in bb.instrs:
      let c = instrCost(instr.op)
      if c >= 100: return MaxInlineCost + 1  # irCall/irTrap rejects
      result += c

proc shouldInline(callee: IrFunc): bool =
  ## Inline iff: single basic block, no calls/traps, cost within budget.
  if callee.blocks.len != 1:
    return false
  computeCalleeCost(callee) <= MaxInlineCost

proc shouldInlineMultiBB(callee: IrFunc): bool =
  ## Inline multi-BB callees that are small, have no nested calls, and few BBs.
  if callee.blocks.len <= 1:
    return false  # handled by single-BB path
  if callee.blocks.len > MaxInlineBBs:
    return false
  computeCalleeCost(callee) <= MaxMultiBBInlineCost

proc inlineMultiBBCallee(caller: var IrFunc, callee: IrFunc,
                          callInstr: IrInstr, callBbIdx: int,
                          callInstrIdx: int) =
  ## Inline a multi-BB callee into `caller` at the call site.
  ##
  ## Splits the original call BB into:
  ##   pre-call BB  (callBbIdx)   : instrs[0..callInstrIdx-1] + irBr → callee entry
  ##   callee BBs   (new)         : remapped callee blocks; irReturn → irBr → contBb
  ##   continuation BB (new)      : irLocalGet(retSlot) + instrs[callInstrIdx+1..end]

  let callResult    = callInstr.result
  let calleeNumBBs  = callee.blocks.len
  let callerBaseBBIdx = caller.blocks.len      # first new callee BB index
  let contBbIdx    = callerBaseBBIdx + calleeNumBBs  # continuation BB

  # Save pre- and post-call instruction slices BEFORE modifying any blocks.
  let preBbInstrs  = caller.blocks[callBbIdx].instrs[0 ..< callInstrIdx]
  let postBbInstrs = caller.blocks[callBbIdx].instrs[callInstrIdx + 1 .. ^1]
  let origSuccessors = caller.blocks[callBbIdx].successors

  # Allocate a temp local for multi-path return value passing.
  var retLocalIdx = -1
  if callResult >= 0:
    retLocalIdx = caller.numLocals
    inc caller.numLocals

  # Reserve fresh SSA value IDs for all callee values.
  let baseValue = caller.numValues
  caller.numValues += callee.numValues
  for i in 0 ..< callee.numValues:
    let simdbit = if i < callee.isSimd.len: callee.isSimd[i] else: false
    caller.isSimd.add(simdbit)

  proc remapVal(v: IrValue): IrValue {.closure.} =
    if v < 0: -1.IrValue else: IrValue(baseValue + v.int)

  proc remapBb(bb: int): int {.closure.} =
    callerBaseBBIdx + bb

  # Build remapped callee BBs and add them to the caller.
  for cbIdx in 0 ..< calleeNumBBs:
    let cb = callee.blocks[cbIdx]
    var newBb = BasicBlock(id: callerBaseBBIdx + cbIdx, loopDepth: cb.loopDepth)

    # Remap successor/predecessor indices.
    for succ in cb.successors:
      newBb.successors.add(remapBb(succ))
    for pred in cb.predecessors:
      newBb.predecessors.add(remapBb(pred))
    # Entry BB is reached from the pre-call BB.
    if cbIdx == 0:
      newBb.predecessors.add(callBbIdx)

    for ci in cb.instrs:
      case ci.op
      of irParam:
        # Bind parameter to the call's corresponding argument value.
        # irCall stores args in POP order: operands[0] = last arg (top of stack),
        # operands[N-1] = first arg (param 0). Map param pIdx → operands[N-1-pIdx].
        let pIdx = ci.imm.int
        let numParams = callee.numParams
        if ci.result >= 0:
          let opIdx = numParams - 1 - pIdx
          let argVal = if opIdx >= 0 and opIdx < 3 and callInstr.operands[opIdx] >= 0:
                         callInstr.operands[opIdx]
                       else:
                         -1.IrValue
          if argVal >= 0:
            newBb.addInstr(IrInstr(op: irNop, result: remapVal(ci.result),
              operands: [argVal, -1.IrValue, -1.IrValue]))
          else:
            # No argument for this param — use zero.
            let zv = IrValue(caller.numValues)
            inc caller.numValues
            caller.isSimd.add(false)
            newBb.addInstr(IrInstr(op: irConst32, result: zv, imm: 0))
            newBb.addInstr(IrInstr(op: irNop, result: remapVal(ci.result),
              operands: [zv, -1.IrValue, -1.IrValue]))
      of irReturn:
        # Replace with: irLocalSet(retSlot, retVal) + irBr(contBb)
        if retLocalIdx >= 0 and ci.operands[0] >= 0:
          newBb.addInstr(IrInstr(op: irLocalSet, result: -1.IrValue,
            operands: [remapVal(ci.operands[0]), -1.IrValue, -1.IrValue],
            imm: retLocalIdx.int64))
        newBb.addInstr(IrInstr(op: irBr, result: -1.IrValue,
          operands: [-1.IrValue, -1.IrValue, -1.IrValue],
          imm: contBbIdx.int64))
        if contBbIdx notin newBb.successors:
          newBb.successors.add(contBbIdx)
      else:
        # Remap value operands and BB indices.
        var ni = ci
        if ni.result >= 0: ni.result = remapVal(ni.result)
        for k in 0..2:
          if ni.operands[k] >= 0: ni.operands[k] = remapVal(ni.operands[k])
        if ni.op == irBr:
          ni.imm = remapBb(ni.imm.int).int64
        elif ni.op == irBrIf:
          ni.imm = remapBb(ni.imm.int).int64
          if ni.imm2 > 0: ni.imm2 = remapBb(ni.imm2.int).int32
        newBb.addInstr(ni)

    caller.blocks.add(newBb)

  # Patch the pre-call BB: trim to pre-call instrs, add irBr to callee entry.
  caller.blocks[callBbIdx].instrs = preBbInstrs
  caller.blocks[callBbIdx].instrs.add(IrInstr(op: irBr, result: -1.IrValue,
    operands: [-1.IrValue, -1.IrValue, -1.IrValue],
    imm: callerBaseBBIdx.int64))
  caller.blocks[callBbIdx].successors = @[callerBaseBBIdx]

  # Update predecessor lists: successors of the original call BB now have
  # contBbIdx as predecessor instead of callBbIdx.
  for succIdx in origSuccessors:
    for bbRef in caller.blocks.mitems:
      if bbRef.id == succIdx:
        for predRef in bbRef.predecessors.mitems:
          if predRef == callBbIdx:
            predRef = contBbIdx
        break

  # Build the continuation BB.
  var contBb = BasicBlock(id: contBbIdx)
  contBb.successors = origSuccessors
  # Predecessors: all callee BBs that have irReturn → irBr(contBbIdx)
  for i in 0 ..< calleeNumBBs:
    for succ in caller.blocks[callerBaseBBIdx + i].successors:
      if succ == contBbIdx:
        contBb.predecessors.add(callerBaseBBIdx + i)
        break

  # Load return value at the start of the continuation BB.
  if retLocalIdx >= 0 and callResult >= 0:
    contBb.addInstr(IrInstr(op: irLocalGet, result: callResult,
      operands: [-1.IrValue, -1.IrValue, -1.IrValue],
      imm: retLocalIdx.int64))
  # Append post-call instructions.
  for pi in postBbInstrs:
    contBb.addInstr(pi)

  caller.blocks.add(contBb)

proc inlineSinglePass(caller: var IrFunc, module: WasmModule,
                      callerFuncIdx: int): bool =
  ## One pass of inlining. Returns true if any inlining was performed.
  ## Handles both single-BB and multi-BB callees.
  var numImportFuncs = 0
  for imp in module.imports:
    if imp.kind == ikFunc:
      inc numImportFuncs

  var totalExpansions = 0
  # Iterate with index because multi-BB inlining may add new blocks.
  # We iterate only over the blocks that existed at the start of this pass
  # (new callee BBs are skipped in this pass but may be processed in the next).
  let originalBlockCount = caller.blocks.len
  var bbIdx = 0
  while bbIdx < originalBlockCount:
    if totalExpansions >= MaxInlineExpansion:
      break

    var instrIdx = 0
    # Also bounded by current block length (multi-BB inline may trim the block).
    while instrIdx < caller.blocks[bbIdx].instrs.len:
      let instr = caller.blocks[bbIdx].instrs[instrIdx]
      if instr.op != irCall:
        inc instrIdx
        continue

      let calleeIdx = instr.imm.int
      # Skip imports, self-recursion, and when budget is exhausted.
      if calleeIdx < numImportFuncs or calleeIdx == callerFuncIdx or
         totalExpansions >= MaxInlineExpansion:
        inc instrIdx
        continue

      let localIdx = calleeIdx - numImportFuncs
      if localIdx < 0 or localIdx >= module.codes.len:
        inc instrIdx
        continue

      # Lower the callee to IR to check inlinability.
      var calleeIr: IrFunc
      try:
        calleeIr = lowerFunction(module, calleeIdx)
      except:
        inc instrIdx
        continue

      # Cost-model-guided inlining decision.
      # Analyze callee cost and ask the cost model whether inlining is worthwhile,
      # factoring in register pressure, code size growth, and loop presence.
      let calleeCostState = analyzeCost(calleeIr)
      let callerCostState = analyzeCost(caller)
      let inlineDecision = computeInlineDecision(
        callerCostState, calleeCostState, bbIdx, totalExpansions)
      if not inlineDecision.shouldInline:
        inc instrIdx
        continue

      let isSingleBB = calleeIr.blocks.len == 1
      let isMultiBB = calleeIr.blocks.len > 1 and calleeIr.blocks.len <= MaxInlineBBs

      if not (isSingleBB or isMultiBB):
        inc instrIdx
        continue

      # Safety: callee must not have more params than we can map via 3 operand slots.
      if calleeIr.numParams > 3:
        inc instrIdx
        continue

      if isSingleBB:
        # --- Single-BB: inline directly into this block ---
        let callResult = instr.result
        let baseValue = caller.numValues
        caller.numValues += calleeIr.numValues
        for i in 0 ..< calleeIr.numValues:
          let simdbit = if i < calleeIr.isSimd.len: calleeIr.isSimd[i] else: false
          caller.isSimd.add(simdbit)

        var valueMap = newSeq[IrValue](calleeIr.numValues)
        for i in 0 ..< calleeIr.numValues:
          valueMap[i] = IrValue(baseValue + i)
        # Map irParam to call arguments.
        # irCall stores args in POP order: operands[0] = last arg, operands[N-1] = param 0.
        let numParams = calleeIr.numParams
        for ci in calleeIr.blocks[0].instrs:
          if ci.op == irParam and ci.result >= 0:
            let pIdx = ci.imm.int
            let opIdx = numParams - 1 - pIdx
            if opIdx >= 0 and opIdx < 3 and instr.operands[opIdx] >= 0:
              valueMap[ci.result.int] = instr.operands[opIdx]

        # Build replacement instructions for this block
        var replacements: seq[IrInstr]
        var returnVal = -1.IrValue
        for ci in calleeIr.blocks[0].instrs:
          case ci.op
          of irParam: continue
          of irReturn:
            if ci.operands[0] >= 0: returnVal = valueMap[ci.operands[0].int]
            continue
          else:
            var ni = ci
            if ni.result >= 0: ni.result = valueMap[ni.result.int]
            for k in 0..2:
              if ni.operands[k] >= 0: ni.operands[k] = valueMap[ni.operands[k].int]
            replacements.add(ni)
        if callResult >= 0 and returnVal >= 0:
          replacements.add(IrInstr(op: irNop, result: callResult,
            operands: [returnVal, -1.IrValue, -1.IrValue]))
        elif callResult >= 0:
          let zv = IrValue(caller.numValues)
          inc caller.numValues
          caller.isSimd.add(false)
          replacements.add(IrInstr(op: irConst32, result: zv, imm: 0))
          replacements.add(IrInstr(op: irNop, result: callResult,
            operands: [zv, -1.IrValue, -1.IrValue]))

        # Splice: remove the irCall, insert replacements at instrIdx
        let before = caller.blocks[bbIdx].instrs[0 ..< instrIdx]
        let after  = caller.blocks[bbIdx].instrs[instrIdx + 1 .. ^1]
        caller.blocks[bbIdx].instrs = before & replacements & after
        # Continue from just after the inlined body (replacements.len positions)
        instrIdx += replacements.len
      else:
        # --- Multi-BB: split this block and insert callee BBs ---
        inlineMultiBBCallee(caller, calleeIr, instr, bbIdx, instrIdx)
        # After splitting, the pre-call BB (bbIdx) now ends with irBr.
        # Stop processing this BB — move to the next original block.
        inc totalExpansions
        result = true
        break  # Break inner loop; instrIdx-based iteration on bbIdx is done

      inc totalExpansions
      result = true
      # Do NOT advance instrIdx — the replacement instructions start at instrIdx.
      # The while loop's instrIdx < len check handles termination.

    inc bbIdx

proc inlineFunctionCalls*(caller: var IrFunc, module: WasmModule,
                           callerFuncIdx: int) =
  ## Inline small single-BB function calls into the caller.
  ## Runs up to MaxInlinePasses times to handle transitive inlining
  ## (e.g., A calls B, B calls C; after one pass A has B's body including
  ## the call to C; the second pass inlines C).
  for _ in 0 ..< MaxInlinePasses:
    if not inlineSinglePass(caller, module, callerFuncIdx):
      break  # no progress — done
