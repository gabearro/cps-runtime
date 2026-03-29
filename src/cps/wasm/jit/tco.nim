## Automatic tail-call optimization for the Tier 2 JIT
##
## Bytecode-level rewrite: `rewriteTailCalls` scans decoded WASM instructions
## for `opCall self` in tail position and rewrites to `opReturnCall self`.
## The existing lowerer TCO machinery then converts the return_call into a
## loop with phi nodes — no stack frame allocation per iteration.
##
## The -O0 pattern we match:
##   [i]   opCall self          ← self-recursive call, result on stack
##   [i+1] opI32Store off=X    ← spill result to shadow stack
##   ...   opEnd               ← end of block
##   ...   opLoad off=X        ← reload result from shadow stack
##   ...   (stack restore)
##   [j]   opReturn            ← return the reloaded value
##
## The rewrite: change opCall to opReturnCall. The lowerer treats opReturnCall
## as a loop back-edge — the dead epilogue code (store/load/return) becomes
## unreachable and is never lowered.

import ../types
import ir

proc rewriteTailCalls*(code: var seq[Instr], selfFuncIdx: int): int =
  ## Scan WASM bytecode for self-recursive calls in tail position.
  ## Rewrite opCall → opReturnCall in-place. Returns the number of rewrites.
  ##
  ## Safe to call before the lowerer — the lowerer's opReturnCall handler
  ## creates the loop structure. Dead code after the rewritten call (the
  ## shadow-stack epilogue) falls into a dead BB and is never executed.
  result = 0
  for i in 0 ..< code.len:
    if code[i].op != opCall: continue
    if code[i].imm1.int != selfFuncIdx: continue

    # Check: is this call followed by a store (shadow-stack spill)?
    if i + 1 >= code.len: continue
    let storeOp = code[i + 1].op
    var spillOffset: int = -1
    if storeOp in {opI32Store, opI64Store, opF32Store, opF64Store}:
      spillOffset = code[i + 1].imm1.int
    if spillOffset < 0: continue

    # Scan forward: find matching load of same offset → return, with no
    # intervening calls or stores to the same offset.
    var foundReturn = false
    var foundLoad = false
    var hitCall = false
    for j in (i + 2) ..< code.len:
      let op = code[j].op
      if not foundLoad:
        if op in {opI32Load, opI64Load, opF32Load, opF64Load} and
           code[j].imm1.int == spillOffset:
          foundLoad = true
        elif op == opLocalGetI32Load and code[j].imm2.uint32 == spillOffset.uint32:
          foundLoad = true
      if foundLoad and op == opReturn:
        foundReturn = true
        break
      if op in {opCall, opCallIndirect, opReturnCall, opReturnCallIndirect}:
        hitCall = true
        break
      if op in {opI32Store, opI64Store, opF32Store, opF64Store} and
         code[j].imm1.int == spillOffset:
        break

    if foundReturn and foundLoad and not hitCall:
      code[i].op = opReturnCall
      inc result

# IR-level detection (for diagnostics and future use)

proc detectTailCalls*(f: IrFunc, selfFuncIdx: int): seq[tuple[bbIdx, instrIdx: int]] =
  ## Find irCall self where the result reaches irReturn (after optimization).
  ## Used for diagnostics; the actual TCO is done at bytecode level.
  for bi in 0 ..< f.blocks.len:
    let bb = f.blocks[bi]
    for ii in 0 ..< bb.instrs.len:
      let instr = bb.instrs[ii]
      if instr.op != irCall: continue
      if instr.imm != selfFuncIdx.int64: continue
      let callResult = instr.result
      if callResult < 0: continue

      var resultValues: set[int16]
      resultValues.incl(callResult.int16)
      var storedOffset: int64 = -1
      var storedBaseVal: IrValue = -1
      var isTail = false

      for jj in (ii + 1) ..< bb.instrs.len:
        let next = bb.instrs[jj]
        if next.op == irReturn:
          if next.operands[0].int16 in resultValues:
            isTail = true
          break
        if next.op == irNop and next.operands[0].int16 in resultValues:
          if next.result >= 0: resultValues.incl(next.result.int16)
          continue
        if next.op in {irStore32, irStore64} and
           next.operands[1].int16 in resultValues:
          storedOffset = next.imm
          storedBaseVal = next.operands[0]
          continue
        if next.op in {irLoad32, irLoad64} and storedOffset >= 0 and
           next.imm == storedOffset and next.operands[0] == storedBaseVal:
          if next.result >= 0: resultValues.incl(next.result.int16)
          continue
        if next.op in {irLocalSet, irLocalGet, irConst32, irConst64,
                       irAdd32, irSub32, irStore32, irStore64, irLoad32, irLoad64}:
          continue
        if next.op == irBr:
          let targetBb = next.imm.int
          if targetBb >= 0 and targetBb < f.blocks.len:
            for ti in f.blocks[targetBb].instrs:
              if ti.op == irReturn:
                if ti.operands[0].int16 in resultValues: isTail = true
                break
              if ti.op in {irLoad32, irLoad64} and storedOffset >= 0 and
                 ti.imm == storedOffset and ti.operands[0] == storedBaseVal:
                if ti.result >= 0: resultValues.incl(ti.result.int16)
                continue
              if ti.op in {irLocalSet, irLocalGet, irConst32, irConst64,
                           irAdd32, irSub32, irStore32, irStore64, irLoad32, irLoad64, irNop, irTrap}:
                continue
              break
          break
        break

      if isTail:
        result.add((bi, ii))

proc autoTco*(f: var IrFunc, selfFuncIdx: int): int =
  ## Placeholder: IR-level TCO is not yet implemented.
  ## The actual TCO is done at bytecode level via rewriteTailCalls,
  ## which runs in the lowerer before IR construction.
  0
