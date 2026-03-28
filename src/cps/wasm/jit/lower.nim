## WASM bytecode to SSA IR lowering pass
## Converts WASM's stack machine into SSA form by simulating the value stack
## symbolically. Each WASM value stack slot maps to an IrValue (SSA value ID).
##
## Uses structured SSA construction (simplified Braun et al.) — since WASM has
## structured control flow, we can build SSA without computing dominance frontiers.

import ../types
import ../pgo
import ir
import tco  # rewriteTailCalls for automatic TCO

type
  LowerBlockKind* = enum
    lbkBlock   ## block ... end (branch target is the end)
    lbkLoop    ## loop ... end (branch target is the loop header)
    lbkIf      ## if ... else ... end

  PhiInfo = object
    phiVal: IrValue          ## SSA value produced by the phi
    localIdx: int            ## WASM local index
    instrIdx: int            ## index in loop header BB's instrs

  BlockState = object
    bb: int                  ## BasicBlock index in IrFunc for the merge/continue point
    valStack: seq[IrValue]   ## value stack snapshot at block entry (for restore on branch)
    locals: seq[IrValue]     ## locals snapshot at block entry
    kind: LowerBlockKind
    hasResult: bool          ## whether this block produces a value
    resultType: ValType      ## type of the result (if hasResult)
    resultSlot: int          ## local index for spilling if/else result (-1 if none)
    condBb: int              ## for lbkIf: the BB that contains the irBrIf (-1 if none)
    elseBb: int              ## for lbkIf: the else BasicBlock index (-1 if none yet)
    phis: seq[PhiInfo]       ## for lbkLoop: phi nodes at loop header

  LowerCtx = object
    f: IrFunc
    module: ptr WasmModule
    funcIdx: int
    usePhiLoops: bool        ## true if phi-based loop lowering is safe
    valStack: seq[IrValue]   ## current symbolic value stack
    locals: seq[IrValue]     ## current SSA value for each WASM local
    blockStack: seq[BlockState]
    curBb: int               ## current BasicBlock index
    restartBb: int           ## -1 normally; loop-back BB for self tail call TCO
    restartPhis: seq[PhiInfo] ## phi nodes at restartBb for phi-based TCO (empty = memory-based)
    numOrigLocals: int       ## numParams + body locals (before lowering adds extra slots)
    pgoData: ptr FuncPgoData ## PGO profile for this function (nil = no data)
    instrPc: int             ## current instruction index within body.code.code

# ---------- helpers ----------

proc bb(ctx: var LowerCtx): var BasicBlock =
  ctx.f.blocks[ctx.curBb]

proc push(ctx: var LowerCtx, v: IrValue) =
  ctx.valStack.add(v)

proc pop(ctx: var LowerCtx): IrValue =
  if ctx.valStack.len == 0:
    # Underflow — should not happen in valid WASM; emit a trap placeholder
    return -1.IrValue
  result = ctx.valStack.pop()

proc newBb(ctx: var LowerCtx): int =
  result = ctx.f.blocks.len
  ctx.f.blocks.add(BasicBlock(id: result))

proc switchBb(ctx: var LowerCtx, target: int) =
  ctx.curBb = target

proc addEdge(ctx: var LowerCtx, fromBb, toBb: int) =
  if toBb notin ctx.f.blocks[fromBb].successors:
    ctx.f.blocks[fromBb].successors.add(toBb)
  if fromBb notin ctx.f.blocks[toBb].predecessors:
    ctx.f.blocks[toBb].predecessors.add(fromBb)

proc emitConst32(ctx: var LowerCtx, val: int32): IrValue =
  result = ctx.f.makeConst32(ctx.bb, val)

proc emitConst64(ctx: var LowerCtx, val: int64): IrValue =
  result = ctx.f.makeConst64(ctx.bb, val)

proc emitBinOp(ctx: var LowerCtx, op: IrOpKind) =
  let b = ctx.pop()
  let a = ctx.pop()
  let r = ctx.f.makeBinOp(ctx.bb, op, a, b)
  ctx.push(r)

proc emitUnaryOp(ctx: var LowerCtx, op: IrOpKind) =
  let a = ctx.pop()
  let r = ctx.f.makeUnaryOp(ctx.bb, op, a)
  ctx.push(r)

proc emitTrap(ctx: var LowerCtx) =
  ctx.bb.addInstr(IrInstr(op: irTrap, result: -1.IrValue,
    operands: [-1.IrValue, -1.IrValue, -1.IrValue]))

# ---------- function type resolution ----------

proc funcType(ctx: LowerCtx): FuncType =
  ## Get the FuncType for the function being lowered
  let numImports = block:
    var c = 0
    for imp in ctx.module[].imports:
      if imp.kind == ikFunc:
        inc c
    c
  let localFuncIdx = ctx.funcIdx - numImports
  let typeIdx = ctx.module[].funcTypeIdxs[localFuncIdx]
  ctx.module[].types[typeIdx.int]

proc padToBlockType(pad: uint16): BlockType =
  ## Decode the Instr.pad field back into a BlockType
  if pad == 0:
    BlockType(kind: btkEmpty)
  elif pad >= 0x100:
    BlockType(kind: btkTypeIdx, typeIdx: uint32(pad - 0x100))
  else:
    let vt = case pad
      of 1: vtI32
      of 2: vtI64
      of 3: vtF32
      of 4: vtF64
      of 5: vtV128
      of 6: vtFuncRef
      of 7: vtExternRef
      else: vtI32
    BlockType(kind: btkValType, valType: vt)

proc blockResultType(ctx: LowerCtx, bt: BlockType): (bool, ValType) =
  ## Returns (hasResult, resultType) for a block type
  case bt.kind
  of btkEmpty:
    (false, vtI32)
  of btkValType:
    (true, bt.valType)
  of btkTypeIdx:
    let ft = ctx.module[].types[bt.typeIdx.int]
    if ft.results.len > 0:
      (true, ft.results[0])
    else:
      (false, vtI32)

# ---------- locals counting ----------

proc countLocals(body: FuncBody): int =
  result = 0
  for decl in body.locals:
    result += decl.count.int

# ---------- br_if helper ----------

proc lowerBrIfCond(ctx: var LowerCtx, cond: IrValue, depth: int,
                   branchProb: uint8 = 128) =
  ## Emit a conditional branch: branch to `depth` levels up if cond != 0.
  ## Handles phi loops, memory-spill loops, and block continuations.
  ## `branchProb` is the PGO-derived taken-probability [0=never, 128=50%, 255=always].
  if depth >= ctx.blockStack.len:
    return
  let targetIdx = ctx.blockStack.len - 1 - depth
  let target = ctx.blockStack[targetIdx]
  if target.kind == lbkLoop and target.phis.len > 0:
    let trampolineBb = ctx.newBb()
    let contBb = ctx.newBb()
    ctx.bb.addInstr(IrInstr(op: irBrIf, result: -1.IrValue,
      operands: [cond, -1.IrValue, -1.IrValue],
      imm: trampolineBb.int64, imm2: contBb.int32, branchProb: branchProb))
    ctx.addEdge(ctx.curBb, trampolineBb)
    ctx.addEdge(ctx.curBb, contBb)
    for phi in target.phis:
      if phi.localIdx < ctx.locals.len:
        let srcVal = ctx.locals[phi.localIdx]
        ctx.f.blocks[target.bb].instrs[phi.instrIdx].operands[1] =
          if srcVal != phi.phiVal: srcVal else: phi.phiVal
    ctx.switchBb(trampolineBb)
    ctx.addEdge(ctx.curBb, target.bb)
    ctx.bb.addInstr(IrInstr(op: irBr, result: -1.IrValue,
      operands: [-1.IrValue, -1.IrValue, -1.IrValue],
      imm: target.bb.int64))
    ctx.switchBb(contBb)
  else:
    if target.kind == lbkLoop:
      for i in 0 ..< ctx.locals.len:
        ctx.bb.addInstr(IrInstr(op: irLocalSet, result: -1.IrValue,
          operands: [ctx.locals[i], -1.IrValue, -1.IrValue],
          imm: i.int64))
      let contBb = ctx.newBb()
      ctx.bb.addInstr(IrInstr(op: irBrIf, result: -1.IrValue,
        operands: [cond, -1.IrValue, -1.IrValue],
        imm: target.bb.int64, imm2: contBb.int32, branchProb: branchProb))
      ctx.addEdge(ctx.curBb, target.bb)
      ctx.addEdge(ctx.curBb, contBb)
      ctx.switchBb(contBb)
    else:
      # Branching to a block merge point.  We must spill all locals to memory before
      # jumping so that the merge block's irLocalGet reload sees the current SSA values.
      # This applies whether or not we are inside a phi loop: opLocalSet only updates
      # ctx.locals[i] (not the memory slot), so any local written since function entry
      # is stale in memory until explicitly spilled.  Route through a spill BB so that
      # the stores only execute on the taken path.
      let contBb = ctx.newBb()
      let spillBb = ctx.newBb()
      ctx.bb.addInstr(IrInstr(op: irBrIf, result: -1.IrValue,
        operands: [cond, -1.IrValue, -1.IrValue],
        imm: spillBb.int64, imm2: contBb.int32, branchProb: branchProb))
      ctx.addEdge(ctx.curBb, spillBb)
      ctx.addEdge(ctx.curBb, contBb)
      ctx.switchBb(spillBb)
      ctx.addEdge(ctx.curBb, target.bb)
      for j in 0 ..< ctx.locals.len:
        ctx.bb.addInstr(IrInstr(op: irLocalSet, result: -1.IrValue,
          operands: [ctx.locals[j], -1.IrValue, -1.IrValue],
          imm: j.int64))
      ctx.bb.addInstr(IrInstr(op: irBr, result: -1.IrValue,
        operands: [-1.IrValue, -1.IrValue, -1.IrValue],
        imm: target.bb.int64))
      ctx.switchBb(contBb)

# ---------- main lowering ----------

proc lowerInstr(ctx: var LowerCtx, instr: Instr) =
  case instr.op

  # --- Constants ---
  of opI32Const:
    let v = ctx.emitConst32(cast[int32](instr.imm1))
    ctx.push(v)

  of opI64Const:
    let lo = instr.imm1.uint64
    let hi = instr.imm2.uint64
    let val = cast[int64](lo or (hi shl 32))
    let v = ctx.emitConst64(val)
    ctx.push(v)

  # --- Local access ---
  of opLocalGet:
    let idx = instr.imm1.int
    if idx < ctx.locals.len:
      ctx.push(ctx.locals[idx])
    else:
      # Out of range — push a trap placeholder
      let v = ctx.emitConst32(0)
      ctx.push(v)

  of opLocalSet:
    let idx = instr.imm1.int
    let v = ctx.pop()
    if idx < ctx.locals.len:
      ctx.locals[idx] = v

  of opLocalTee:
    let idx = instr.imm1.int
    let v = ctx.pop()
    if idx < ctx.locals.len:
      ctx.locals[idx] = v
    ctx.push(v)  # tee leaves value on stack

  # --- Global access: mapped to locals at offset numOrigLocals + globalIdx ---
  # Globals are stored after the function's locals in the locals array.
  # The invokeJit/invokeInterp paths copy globals from the store into
  # locals[numOrigLocals..] before calling the JIT function, and copy
  # them back after the call returns.
  of opGlobalGet:
    let globalIdx = instr.imm1.int
    let localIdx = ctx.numOrigLocals + globalIdx
    let v = ctx.f.newValue()
    ctx.bb.addInstr(IrInstr(op: irLocalGet, result: v,
      operands: [-1.IrValue, -1.IrValue, -1.IrValue], imm: localIdx.int64))
    ctx.push(v)
  of opGlobalSet:
    let globalIdx = instr.imm1.int
    let localIdx = ctx.numOrigLocals + globalIdx
    let val = ctx.pop()
    ctx.bb.addInstr(IrInstr(op: irLocalSet, result: -1.IrValue,
      operands: [val, -1.IrValue, -1.IrValue], imm: localIdx.int64))

  # --- Parametric ---
  of opDrop:
    discard ctx.pop()

  of opSelect, opSelectTyped:
    let cond = ctx.pop()
    let b = ctx.pop()
    let a = ctx.pop()
    let r = ctx.f.newValue()
    ctx.bb.addInstr(IrInstr(op: irSelect, result: r,
      operands: [cond, a, b]))
    ctx.push(r)

  of opNop:
    discard

  # --- i32 arithmetic ---
  of opI32Add: ctx.emitBinOp(irAdd32)
  of opI32Sub: ctx.emitBinOp(irSub32)
  of opI32Mul: ctx.emitBinOp(irMul32)
  of opI32DivS: ctx.emitBinOp(irDiv32S)
  of opI32DivU: ctx.emitBinOp(irDiv32U)
  of opI32RemS: ctx.emitBinOp(irRem32S)
  of opI32RemU: ctx.emitBinOp(irRem32U)
  of opI32And: ctx.emitBinOp(irAnd32)
  of opI32Or: ctx.emitBinOp(irOr32)
  of opI32Xor: ctx.emitBinOp(irXor32)
  of opI32Shl: ctx.emitBinOp(irShl32)
  of opI32ShrS: ctx.emitBinOp(irShr32S)
  of opI32ShrU: ctx.emitBinOp(irShr32U)
  of opI32Rotl: ctx.emitBinOp(irRotl32)
  of opI32Rotr: ctx.emitBinOp(irRotr32)
  of opI32Clz: ctx.emitUnaryOp(irClz32)
  of opI32Ctz: ctx.emitUnaryOp(irCtz32)
  of opI32Popcnt: ctx.emitUnaryOp(irPopcnt32)
  of opI32Eqz: ctx.emitUnaryOp(irEqz32)

  # --- i64 arithmetic ---
  of opI64Add: ctx.emitBinOp(irAdd64)
  of opI64Sub: ctx.emitBinOp(irSub64)
  of opI64Mul: ctx.emitBinOp(irMul64)
  of opI64DivS: ctx.emitBinOp(irDiv64S)
  of opI64DivU: ctx.emitBinOp(irDiv64U)
  of opI64RemS: ctx.emitBinOp(irRem64S)
  of opI64RemU: ctx.emitBinOp(irRem64U)
  of opI64And: ctx.emitBinOp(irAnd64)
  of opI64Or: ctx.emitBinOp(irOr64)
  of opI64Xor: ctx.emitBinOp(irXor64)
  of opI64Shl: ctx.emitBinOp(irShl64)
  of opI64ShrS: ctx.emitBinOp(irShr64S)
  of opI64ShrU: ctx.emitBinOp(irShr64U)
  of opI64Rotl: ctx.emitBinOp(irRotl64)
  of opI64Rotr: ctx.emitBinOp(irRotr64)
  of opI64Clz: ctx.emitUnaryOp(irClz64)
  of opI64Ctz: ctx.emitUnaryOp(irCtz64)
  of opI64Popcnt: ctx.emitUnaryOp(irPopcnt64)
  of opI64Eqz: ctx.emitUnaryOp(irEqz64)

  # --- i32 comparisons ---
  of opI32Eq: ctx.emitBinOp(irEq32)
  of opI32Ne: ctx.emitBinOp(irNe32)
  of opI32LtS: ctx.emitBinOp(irLt32S)
  of opI32LtU: ctx.emitBinOp(irLt32U)
  of opI32GtS: ctx.emitBinOp(irGt32S)
  of opI32GtU: ctx.emitBinOp(irGt32U)
  of opI32LeS: ctx.emitBinOp(irLe32S)
  of opI32LeU: ctx.emitBinOp(irLe32U)
  of opI32GeS: ctx.emitBinOp(irGe32S)
  of opI32GeU: ctx.emitBinOp(irGe32U)

  # --- i64 comparisons ---
  of opI64Eq: ctx.emitBinOp(irEq64)
  of opI64Ne: ctx.emitBinOp(irNe64)
  of opI64LtS: ctx.emitBinOp(irLt64S)
  of opI64LtU: ctx.emitBinOp(irLt64U)
  of opI64GtS: ctx.emitBinOp(irGt64S)
  of opI64GtU: ctx.emitBinOp(irGt64U)
  of opI64LeS: ctx.emitBinOp(irLe64S)
  of opI64LeU: ctx.emitBinOp(irLe64U)
  of opI64GeS: ctx.emitBinOp(irGe64S)
  of opI64GeU: ctx.emitBinOp(irGe64U)

  # --- Conversions ---
  of opI32WrapI64: ctx.emitUnaryOp(irWrapI64)
  of opI64ExtendI32S: ctx.emitUnaryOp(irExtendI32S)
  of opI64ExtendI32U: ctx.emitUnaryOp(irExtendI32U)
  of opI32Extend8S: ctx.emitUnaryOp(irExtend8S32)
  of opI32Extend16S: ctx.emitUnaryOp(irExtend16S32)
  of opI64Extend8S: ctx.emitUnaryOp(irExtend8S64)
  of opI64Extend16S: ctx.emitUnaryOp(irExtend16S64)
  of opI64Extend32S: ctx.emitUnaryOp(irExtend32S64)

  # --- Memory loads ---
  of opI32Load:
    let addr0 = ctx.pop()
    let r = ctx.f.makeLoad(ctx.bb, irLoad32, addr0, cast[int32](instr.imm1))
    ctx.push(r)

  of opI64Load:
    let addr0 = ctx.pop()
    let r = ctx.f.makeLoad(ctx.bb, irLoad64, addr0, cast[int32](instr.imm1))
    ctx.push(r)

  of opI32Load8S:
    let addr0 = ctx.pop()
    let r = ctx.f.makeLoad(ctx.bb, irLoad8S, addr0, cast[int32](instr.imm1))
    ctx.push(r)

  of opI32Load8U:
    let addr0 = ctx.pop()
    let r = ctx.f.makeLoad(ctx.bb, irLoad8U, addr0, cast[int32](instr.imm1))
    ctx.push(r)

  of opI32Load16S:
    let addr0 = ctx.pop()
    let r = ctx.f.makeLoad(ctx.bb, irLoad16S, addr0, cast[int32](instr.imm1))
    ctx.push(r)

  of opI32Load16U:
    let addr0 = ctx.pop()
    let r = ctx.f.makeLoad(ctx.bb, irLoad16U, addr0, cast[int32](instr.imm1))
    ctx.push(r)

  of opI64Load8S:
    let addr0 = ctx.pop()
    let r = ctx.f.makeLoad(ctx.bb, irLoad8S, addr0, cast[int32](instr.imm1))
    ctx.push(r)

  of opI64Load8U:
    let addr0 = ctx.pop()
    let r = ctx.f.makeLoad(ctx.bb, irLoad8U, addr0, cast[int32](instr.imm1))
    ctx.push(r)

  of opI64Load16S:
    let addr0 = ctx.pop()
    let r = ctx.f.makeLoad(ctx.bb, irLoad16S, addr0, cast[int32](instr.imm1))
    ctx.push(r)

  of opI64Load16U:
    let addr0 = ctx.pop()
    let r = ctx.f.makeLoad(ctx.bb, irLoad16U, addr0, cast[int32](instr.imm1))
    ctx.push(r)

  of opI64Load32S:
    let addr0 = ctx.pop()
    let r = ctx.f.makeLoad(ctx.bb, irLoad32S, addr0, cast[int32](instr.imm1))
    ctx.push(r)

  of opI64Load32U:
    let addr0 = ctx.pop()
    let r = ctx.f.makeLoad(ctx.bb, irLoad32U, addr0, cast[int32](instr.imm1))
    ctx.push(r)

  # --- Memory stores ---
  of opI32Store:
    let val = ctx.pop()
    let addr0 = ctx.pop()
    ctx.f.makeStore(ctx.bb, irStore32, addr0, val, cast[int32](instr.imm1))

  of opI64Store:
    let val = ctx.pop()
    let addr0 = ctx.pop()
    ctx.f.makeStore(ctx.bb, irStore64, addr0, val, cast[int32](instr.imm1))

  of opI32Store8:
    let val = ctx.pop()
    let addr0 = ctx.pop()
    ctx.f.makeStore(ctx.bb, irStore8, addr0, val, cast[int32](instr.imm1))

  of opI32Store16:
    let val = ctx.pop()
    let addr0 = ctx.pop()
    ctx.f.makeStore(ctx.bb, irStore16, addr0, val, cast[int32](instr.imm1))

  of opI64Store8:
    let val = ctx.pop()
    let addr0 = ctx.pop()
    ctx.f.makeStore(ctx.bb, irStore8, addr0, val, cast[int32](instr.imm1))

  of opI64Store16:
    let val = ctx.pop()
    let addr0 = ctx.pop()
    ctx.f.makeStore(ctx.bb, irStore16, addr0, val, cast[int32](instr.imm1))

  of opI64Store32:
    let val = ctx.pop()
    let addr0 = ctx.pop()
    ctx.f.makeStore(ctx.bb, irStore32From64, addr0, val, cast[int32](instr.imm1))

  # --- Control flow ---
  of opBlock:
    # Create merge block (branch target for `br`)
    let mergeBb = ctx.newBb()
    let bt = padToBlockType(instr.pad)
    let (hasRes, resType) = ctx.blockResultType(bt)
    # Allocate a local slot for the block result (if needed)
    let resSlot = if hasRes: (let s = ctx.f.numLocals; inc ctx.f.numLocals; s) else: -1
    ctx.blockStack.add(BlockState(
      bb: mergeBb,
      valStack: ctx.valStack,
      locals: ctx.locals,
      kind: lbkBlock,
      hasResult: hasRes,
      resultType: resType,
      resultSlot: resSlot,
      elseBb: -1,
    ))

  of opLoop:
    let loopBb = ctx.newBb()
    ctx.addEdge(ctx.curBb, loopBb)
    if ctx.usePhiLoops:
      # Phi-based loop: no memory spill, use phi nodes at loop header
      ctx.bb.addInstr(IrInstr(op: irBr, result: -1.IrValue,
        operands: [-1.IrValue, -1.IrValue, -1.IrValue],
        imm: loopBb.int64))
      let preheaderLocals = ctx.locals
      ctx.switchBb(loopBb)
      var loopPhis: seq[PhiInfo]
      var loopLocals = newSeq[IrValue](ctx.locals.len)
      for i in 0 ..< ctx.locals.len:
        let phiVal = ctx.f.newValue()
        let instrIdx = ctx.bb.instrs.len
        ctx.bb.addInstr(IrInstr(op: irPhi, result: phiVal,
          operands: [preheaderLocals[i], -1.IrValue, -1.IrValue],
          imm: i.int64))
        loopLocals[i] = phiVal
        loopPhis.add(PhiInfo(phiVal: phiVal, localIdx: i, instrIdx: instrIdx))
      ctx.locals = loopLocals
      ctx.blockStack.add(BlockState(
        bb: loopBb, valStack: ctx.valStack, locals: ctx.locals,
        kind: lbkLoop, hasResult: false, resultType: vtI32,
        resultSlot: -1, elseBb: -1, phis: loopPhis))
    else:
      # Memory-spill loop: spill all locals to memory, reload at header
      for i in 0 ..< ctx.locals.len:
        ctx.bb.addInstr(IrInstr(op: irLocalSet, result: -1.IrValue,
          operands: [ctx.locals[i], -1.IrValue, -1.IrValue], imm: i.int64))
      ctx.bb.addInstr(IrInstr(op: irBr, result: -1.IrValue,
        operands: [-1.IrValue, -1.IrValue, -1.IrValue], imm: loopBb.int64))
      ctx.switchBb(loopBb)
      var loopLocals = newSeq[IrValue](ctx.locals.len)
      for i in 0 ..< ctx.locals.len:
        let v = ctx.f.newValue()
        ctx.bb.addInstr(IrInstr(op: irLocalGet, result: v,
          operands: [-1.IrValue, -1.IrValue, -1.IrValue], imm: i.int64))
        loopLocals[i] = v
      ctx.locals = loopLocals
      ctx.blockStack.add(BlockState(
        bb: loopBb, valStack: ctx.valStack, locals: ctx.locals,
        kind: lbkLoop, hasResult: false, resultType: vtI32,
        resultSlot: -1, elseBb: -1))

  of opIf:
    let cond = ctx.pop()
    let condBbIdx = ctx.curBb
    let thenBb = ctx.newBb()
    let mergeBb = ctx.newBb()
    # Spill locals before the branch so both paths have valid locals in memory
    for i in 0 ..< ctx.locals.len:
      ctx.bb.addInstr(IrInstr(op: irLocalSet, result: -1.IrValue,
        operands: [ctx.locals[i], -1.IrValue, -1.IrValue],
        imm: i.int64))
    # Conditional branch: if cond != 0, go to thenBb; else, go to mergeBb (patched to elseBb by opElse)
    ctx.bb.addInstr(IrInstr(op: irBrIf, result: -1.IrValue,
      operands: [cond, -1.IrValue, -1.IrValue],
      imm: thenBb.int64, imm2: mergeBb.int32))
    ctx.addEdge(ctx.curBb, thenBb)
    ctx.addEdge(ctx.curBb, mergeBb)
    ctx.switchBb(thenBb)
    let bt = padToBlockType(instr.pad)
    let (hasRes, resType) = ctx.blockResultType(bt)
    let resSlot = if hasRes: (let s = ctx.f.numLocals; inc ctx.f.numLocals; s) else: -1
    ctx.blockStack.add(BlockState(
      bb: mergeBb,
      valStack: ctx.valStack,
      locals: ctx.locals,
      kind: lbkIf,
      hasResult: hasRes,
      resultType: resType,
      resultSlot: resSlot,
      condBb: condBbIdx,
      elseBb: -1,
    ))

  of opElse:
    # End the then-block, start the else-block
    if ctx.blockStack.len > 0:
      let bsIdx = ctx.blockStack.len - 1
      let mergeBb = ctx.blockStack[bsIdx].bb
      # Spill the then-branch result to the result slot before branching
      if ctx.blockStack[bsIdx].hasResult and ctx.blockStack[bsIdx].resultSlot >= 0:
        let resultVal = ctx.pop()
        ctx.bb.addInstr(IrInstr(op: irLocalSet, result: -1.IrValue,
          operands: [resultVal, -1.IrValue, -1.IrValue],
          imm: ctx.blockStack[bsIdx].resultSlot.int64))
      # Branch from then-block to merge
      ctx.bb.addInstr(IrInstr(op: irBr, result: -1.IrValue,
        operands: [-1.IrValue, -1.IrValue, -1.IrValue],
        imm: mergeBb.int64))
      ctx.addEdge(ctx.curBb, mergeBb)
      # Create new block for else body
      let elseBb = ctx.newBb()
      ctx.blockStack[bsIdx].elseBb = elseBb
      # Patch the irBrIf in the condition block to target elseBb instead of mergeBb
      let condBbIdx = ctx.blockStack[bsIdx].condBb
      if condBbIdx >= 0:
        let instrs = ctx.f.blocks[condBbIdx].instrs.addr
        for k in 0 ..< ctx.f.blocks[condBbIdx].instrs.len:
          if instrs[k].op == irBrIf:
            instrs[k].imm2 = elseBb.int32
            break
      ctx.addEdge(condBbIdx, elseBb)
      ctx.switchBb(elseBb)
      # Restore stack to block entry state
      ctx.valStack = ctx.blockStack[bsIdx].valStack
      ctx.locals = ctx.blockStack[bsIdx].locals

  of opEnd:
    if ctx.blockStack.len > 0:
      let bs = ctx.blockStack.pop()
      if bs.kind != lbkLoop:
        # Spill block result before branching to merge
        if bs.hasResult and bs.resultSlot >= 0 and ctx.valStack.len > bs.valStack.len:
          let resultVal = ctx.pop()
          ctx.bb.addInstr(IrInstr(op: irLocalSet, result: -1.IrValue,
            operands: [resultVal, -1.IrValue, -1.IrValue],
            imm: bs.resultSlot.int64))
        # Spill all locals before branching to merge (so merge can reload them)
        for i in 0 ..< ctx.locals.len:
          ctx.bb.addInstr(IrInstr(op: irLocalSet, result: -1.IrValue,
            operands: [ctx.locals[i], -1.IrValue, -1.IrValue],
            imm: i.int64))
        # Branch from current block to merge block
        ctx.addEdge(ctx.curBb, bs.bb)
        ctx.bb.addInstr(IrInstr(op: irBr, result: -1.IrValue,
          operands: [-1.IrValue, -1.IrValue, -1.IrValue],
          imm: bs.bb.int64))
        ctx.switchBb(bs.bb)
        # Restore value stack to block entry state
        ctx.valStack = bs.valStack
        # Reload all locals at merge point (values may differ per path)
        for i in 0 ..< ctx.locals.len:
          let v = ctx.f.newValue()
          ctx.bb.addInstr(IrInstr(op: irLocalGet, result: v,
            operands: [-1.IrValue, -1.IrValue, -1.IrValue],
            imm: i.int64))
          ctx.locals[i] = v
        # If block has a result, reload from the result slot
        if bs.hasResult and bs.resultSlot >= 0:
          let v = ctx.f.newValue()
          ctx.bb.addInstr(IrInstr(op: irLocalGet, result: v,
            operands: [-1.IrValue, -1.IrValue, -1.IrValue],
            imm: bs.resultSlot.int64))
          ctx.push(v)
      else:
        # Loop: end just closes the loop body; continue in a new block
        # Spill locals before exiting loop
        for i in 0 ..< ctx.locals.len:
          ctx.bb.addInstr(IrInstr(op: irLocalSet, result: -1.IrValue,
            operands: [ctx.locals[i], -1.IrValue, -1.IrValue],
            imm: i.int64))
        let afterBb = ctx.newBb()
        ctx.addEdge(ctx.curBb, afterBb)
        ctx.bb.addInstr(IrInstr(op: irBr, result: -1.IrValue,
          operands: [-1.IrValue, -1.IrValue, -1.IrValue],
          imm: afterBb.int64))
        ctx.switchBb(afterBb)
        ctx.valStack = bs.valStack
        # Reload locals from memory in after-loop block
        for i in 0 ..< ctx.locals.len:
          let v = ctx.f.newValue()
          ctx.bb.addInstr(IrInstr(op: irLocalGet, result: v,
            operands: [-1.IrValue, -1.IrValue, -1.IrValue],
            imm: i.int64))
          ctx.locals[i] = v
    # else: this is the final `end` of the function — handled after the loop

  of opBr:
    let depth = instr.imm1.int
    if depth < ctx.blockStack.len:
      let targetIdx = ctx.blockStack.len - 1 - depth
      let target = ctx.blockStack[targetIdx]
      if target.kind == lbkLoop and target.phis.len > 0:
        # Phi-based back-edge: patch phi operands[1] with current locals
        for phi in target.phis:
          if phi.localIdx < ctx.locals.len:
            ctx.f.blocks[target.bb].instrs[phi.instrIdx].operands[1] = ctx.locals[phi.localIdx]
      elif target.kind == lbkLoop:
        # Fallback: spill to memory
        for i in 0 ..< ctx.locals.len:
          ctx.bb.addInstr(IrInstr(op: irLocalSet, result: -1.IrValue,
            operands: [ctx.locals[i], -1.IrValue, -1.IrValue],
            imm: i.int64))
      else:
        # Branching to a non-loop target (block continuation).
        # If we're inside any phi-based loop, the phi-tracked locals live in
        # SSA values and the memory slots are stale (phi loops do NOT emit
        # irLocalSet on the back-edge).  We must spill them so the target
        # block's irLocalGet reload sees the correct current values.
        for i in targetIdx + 1 ..< ctx.blockStack.len:
          if ctx.blockStack[i].kind == lbkLoop and ctx.blockStack[i].phis.len > 0:
            for j in 0 ..< ctx.locals.len:
              ctx.bb.addInstr(IrInstr(op: irLocalSet, result: -1.IrValue,
                operands: [ctx.locals[j], -1.IrValue, -1.IrValue],
                imm: j.int64))
            break
      ctx.addEdge(ctx.curBb, target.bb)
      ctx.bb.addInstr(IrInstr(op: irBr, result: -1.IrValue,
        operands: [-1.IrValue, -1.IrValue, -1.IrValue],
        imm: target.bb.int64))
      let deadBb = ctx.newBb()
      ctx.switchBb(deadBb)

  of opBrIf:
    let cond = ctx.pop()
    var brProb = 128'u8
    if ctx.pgoData != nil and ctx.instrPc < ctx.pgoData.branchProfiles.len:
      brProb = branchTakenProb(ctx.pgoData.branchProfiles[ctx.instrPc])
    ctx.lowerBrIfCond(cond, instr.imm1.int, brProb)

  of opReturn:
    if ctx.valStack.len > 0:
      let retVal = ctx.pop()
      ctx.bb.addInstr(IrInstr(op: irReturn, result: -1.IrValue,
        operands: [retVal, -1.IrValue, -1.IrValue]))
    else:
      ctx.bb.addInstr(IrInstr(op: irReturn, result: -1.IrValue,
        operands: [-1.IrValue, -1.IrValue, -1.IrValue]))
    # Dead code follows
    let deadBb = ctx.newBb()
    ctx.switchBb(deadBb)

  of opUnreachable:
    ctx.emitTrap()
    let deadBb = ctx.newBb()
    ctx.switchBb(deadBb)

  # --- Calls (emit trap — would need interpreter trampoline) ---
  of opCall:
    # For now, emit a call instruction with the function index, but pop/push
    # based on function signature if available
    let calleeIdx = instr.imm1.int
    # Try to look up the callee type
    let numImportFuncs = block:
      var c = 0
      for imp in ctx.module[].imports:
        if imp.kind == ikFunc:
          inc c
      c
    var calleeFt: FuncType
    var haveType = false
    if calleeIdx < numImportFuncs:
      # Import function
      var importIdx = 0
      for imp in ctx.module[].imports:
        if imp.kind == ikFunc:
          if importIdx == calleeIdx:
            calleeFt = ctx.module[].types[imp.funcTypeIdx.int]
            haveType = true
            break
          inc importIdx
    elif calleeIdx - numImportFuncs < ctx.module[].funcTypeIdxs.len:
      let localIdx = calleeIdx - numImportFuncs
      let typeIdx = ctx.module[].funcTypeIdxs[localIdx]
      calleeFt = ctx.module[].types[typeIdx.int]
      haveType = true

    if haveType:
      # Pop arguments (in reverse order — last arg is on top)
      var args: seq[IrValue]
      for i in 0 ..< calleeFt.params.len:
        args.add(ctx.pop())
      # Emit call (we store the function index in imm)
      let r = ctx.f.newValue()
      var operands: array[3, IrValue] = [-1.IrValue, -1.IrValue, -1.IrValue]
      # Store first 3 args in operands
      for i in 0 ..< min(args.len, 3):
        operands[i] = args[i]
      ctx.bb.addInstr(IrInstr(op: irCall, result: r, operands: operands,
        imm: calleeIdx.int64))
      # Push results
      if calleeFt.results.len > 0:
        ctx.push(r)
    else:
      ctx.emitTrap()

  of opCallIndirect:
    # call_indirect typeIdx tableIdx
    # Stack before: [arg0, arg1, ..., argN-1, elemIdx]  (elemIdx on top)
    let typeIdx = instr.imm1.int
    let elemIdx = ctx.pop()  # table element index (i32)

    if typeIdx >= ctx.module[].types.len:
      # Invalid type index — emit trap
      ctx.emitTrap()
    else:
      let ft = ctx.module[].types[typeIdx]
      let paramCount = ft.params.len
      let resultCount = ft.results.len

      # Pop arguments in stack order (last pushed = first popped = last arg).
      # args[0] = argN-1 (top of stack), args[N-1] = arg0 (deepest).
      var args: seq[IrValue]
      for _ in 0 ..< paramCount:
        args.add(ctx.pop())

      # Allocate synthetic temp locals for arg spilling and result collection.
      # Layout: locals[tempBase+0..tempBase+N-1] = arg0..argN-1 (natural order).
      let tempBase = ctx.f.numLocals
      ctx.f.numLocals += max(paramCount, if resultCount > 0: 1 else: 0)

      # Spill args to temp locals in natural order (arg0 at tempBase+0, argN-1 at tempBase+N-1).
      # args[] is reversed (args[i] = arg_{N-1-i}), so we reverse back.
      for i in 0 ..< paramCount:
        let argVal = args[paramCount - 1 - i]   # args[N-1-i] = arg_i
        ctx.bb.addInstr(IrInstr(op: irLocalSet, result: -1.IrValue,
          operands: [argVal, -1.IrValue, -1.IrValue],
          imm: (tempBase + i).int64))

      # Emit irCallIndirect.
      # imm  = paramCount | (resultCount << 16) — type info from the call-site signature
      # imm2 = tempBase                         — first temp local index
      let res = if resultCount > 0: ctx.f.newValue() else: -1.IrValue
      ctx.bb.addInstr(IrInstr(
        op: irCallIndirect,
        result: res,
        operands: [elemIdx, -1.IrValue, -1.IrValue],
        imm: paramCount.int64 or (resultCount.int64 shl 16),
        imm2: tempBase.int32
      ))

      # Push result onto the symbolic value stack.
      if resultCount > 0:
        ctx.push(res)

      ctx.f.usesMemory = true   # callee may access memory
      inc ctx.f.callIndirectSiteCount

  # --- Memory size/grow ---
  of opMemorySize:
    # Push a trap value (would need runtime memory state)
    ctx.emitTrap()
    let v = ctx.emitConst32(0)
    ctx.push(v)

  of opMemoryGrow:
    discard ctx.pop()
    ctx.emitTrap()
    let v = ctx.emitConst32(-1)
    ctx.push(v)

  # --- Fused superinstructions: decompose to their constituent parts ---
  of opLocalGetLocalGet:
    let idxA = instr.imm1.int
    let idxB = instr.imm2.int
    if idxA < ctx.locals.len:
      ctx.push(ctx.locals[idxA])
    if idxB < ctx.locals.len:
      ctx.push(ctx.locals[idxB])

  of opLocalGetI32Add:
    let idx = instr.imm1.int
    if idx < ctx.locals.len:
      ctx.push(ctx.locals[idx])
    ctx.emitBinOp(irAdd32)

  of opLocalGetI32Sub:
    let idx = instr.imm1.int
    if idx < ctx.locals.len:
      ctx.push(ctx.locals[idx])
    ctx.emitBinOp(irSub32)

  of opI32ConstI32Add:
    let v = ctx.emitConst32(cast[int32](instr.imm1))
    ctx.push(v)
    ctx.emitBinOp(irAdd32)

  of opI32ConstI32Sub:
    let v = ctx.emitConst32(cast[int32](instr.imm1))
    ctx.push(v)
    ctx.emitBinOp(irSub32)

  of opLocalGetLocalGetI32Add:
    let idxA = instr.imm1.int
    let idxB = instr.imm2.int
    if idxA < ctx.locals.len:
      ctx.push(ctx.locals[idxA])
    if idxB < ctx.locals.len:
      ctx.push(ctx.locals[idxB])
    ctx.emitBinOp(irAdd32)

  of opLocalGetLocalGetI32Sub:
    let idxA = instr.imm1.int
    let idxB = instr.imm2.int
    if idxA < ctx.locals.len:
      ctx.push(ctx.locals[idxA])
    if idxB < ctx.locals.len:
      ctx.push(ctx.locals[idxB])
    ctx.emitBinOp(irSub32)

  of opLocalGetI32ConstI32Add:
    let idx = instr.imm1.int
    if idx < ctx.locals.len:
      ctx.push(ctx.locals[idx])
    let c = ctx.emitConst32(cast[int32](instr.imm2))
    ctx.push(c)
    ctx.emitBinOp(irAdd32)

  of opLocalGetI32ConstI32Sub:
    let idx = instr.imm1.int
    if idx < ctx.locals.len:
      ctx.push(ctx.locals[idx])
    let c = ctx.emitConst32(cast[int32](instr.imm2))
    ctx.push(c)
    ctx.emitBinOp(irSub32)

  of opI32AddLocalSet:
    ctx.emitBinOp(irAdd32)
    let idx = instr.imm1.int
    let v = ctx.pop()
    if idx < ctx.locals.len:
      ctx.locals[idx] = v

  of opI32SubLocalSet:
    ctx.emitBinOp(irSub32)
    let idx = instr.imm1.int
    let v = ctx.pop()
    if idx < ctx.locals.len:
      ctx.locals[idx] = v

  of opLocalSetLocalGet:
    let idxSet = instr.imm1.int
    let idxGet = instr.imm2.int
    let v = ctx.pop()
    if idxSet < ctx.locals.len:
      ctx.locals[idxSet] = v
    if idxGet < ctx.locals.len:
      ctx.push(ctx.locals[idxGet])

  of opLocalTeeLocalGet:
    let idxTee = instr.imm1.int
    let idxGet = instr.imm2.int
    let v = ctx.pop()
    if idxTee < ctx.locals.len:
      ctx.locals[idxTee] = v
    ctx.push(v)
    if idxGet < ctx.locals.len:
      ctx.push(ctx.locals[idxGet])

  of opLocalGetI32Const:
    let idx = instr.imm1.int
    if idx < ctx.locals.len:
      ctx.push(ctx.locals[idx])
    let c = ctx.emitConst32(cast[int32](instr.imm2))
    ctx.push(c)

  of opLocalGetI32Store:
    let idx = instr.imm1.int
    if idx < ctx.locals.len:
      ctx.push(ctx.locals[idx])
    let val = ctx.pop()
    let addr0 = ctx.pop()
    ctx.f.makeStore(ctx.bb, irStore32, addr0, val, cast[int32](instr.imm2))

  of opLocalGetLocalTee:
    let idxGet = instr.imm1.int
    let idxTee = instr.imm2.int
    if idxGet < ctx.locals.len:
      ctx.push(ctx.locals[idxGet])
    let v = ctx.pop()
    if idxTee < ctx.locals.len:
      ctx.locals[idxTee] = v
    ctx.push(v)

  of opI32ConstI32GtU:
    let c = ctx.emitConst32(cast[int32](instr.imm1))
    ctx.push(c)
    ctx.emitBinOp(irGt32U)

  of opI32ConstI32LtS:
    let c = ctx.emitConst32(cast[int32](instr.imm1))
    ctx.push(c)
    ctx.emitBinOp(irLt32S)

  of opI32ConstI32GeS:
    let c = ctx.emitConst32(cast[int32](instr.imm1))
    ctx.push(c)
    ctx.emitBinOp(irGe32S)

  of opI32EqzBrIf:
    ctx.emitUnaryOp(irEqz32)
    let cond = ctx.pop()
    ctx.lowerBrIfCond(cond, instr.imm1.int)

  of opLocalGetI32Load:
    # local.get X; i32.load offset
    let idx = instr.imm1.int
    if idx < ctx.locals.len:
      ctx.push(ctx.locals[idx])
    let addr0 = ctx.pop()
    let r = ctx.f.makeLoad(ctx.bb, irLoad32, addr0, cast[int32](instr.imm2))
    ctx.push(r)

  of opI32ConstI32Eq:
    let c = ctx.emitConst32(cast[int32](instr.imm1))
    ctx.push(c)
    ctx.emitBinOp(irEq32)

  of opI32ConstI32Ne:
    let c = ctx.emitConst32(cast[int32](instr.imm1))
    ctx.push(c)
    ctx.emitBinOp(irNe32)

  of opLocalGetI32GtS:
    let idx = instr.imm1.int
    if idx < ctx.locals.len:
      ctx.push(ctx.locals[idx])
    ctx.emitBinOp(irGt32S)

  of opI32ConstI32And:
    let c = ctx.emitConst32(cast[int32](instr.imm1))
    ctx.push(c)
    ctx.emitBinOp(irAnd32)

  of opI32ConstI32Mul:
    let c = ctx.emitConst32(cast[int32](instr.imm1))
    ctx.push(c)
    ctx.emitBinOp(irMul32)

  of opLocalGetI32Mul:
    let idx = instr.imm1.int
    if idx < ctx.locals.len:
      ctx.push(ctx.locals[idx])
    ctx.emitBinOp(irMul32)

  of opLocalGetI32LoadI32Add:
    # local.get X; i32.load offset; i32.add
    let idx = instr.imm1.int
    if idx < ctx.locals.len:
      ctx.push(ctx.locals[idx])
    let addr0 = ctx.pop()
    let r = ctx.f.makeLoad(ctx.bb, irLoad32, addr0, cast[int32](instr.imm2))
    ctx.push(r)
    ctx.emitBinOp(irAdd32)

  # --- New fused: comparison + br_if pairs ---
  of opI32EqBrIf:
    ctx.emitBinOp(irEq32)
    let cond = ctx.pop()
    ctx.lowerBrIfCond(cond, instr.imm1.int)
  of opI32NeBrIf:
    ctx.emitBinOp(irNe32)
    let cond = ctx.pop()
    ctx.lowerBrIfCond(cond, instr.imm1.int)
  of opI32LtSBrIf:
    ctx.emitBinOp(irLt32S)
    let cond = ctx.pop()
    ctx.lowerBrIfCond(cond, instr.imm1.int)
  of opI32GeSBrIf:
    ctx.emitBinOp(irGe32S)
    let cond = ctx.pop()
    ctx.lowerBrIfCond(cond, instr.imm1.int)
  of opI32GtSBrIf:
    ctx.emitBinOp(irGt32S)
    let cond = ctx.pop()
    ctx.lowerBrIfCond(cond, instr.imm1.int)
  of opI32LeSBrIf:
    ctx.emitBinOp(irLe32S)
    let cond = ctx.pop()
    ctx.lowerBrIfCond(cond, instr.imm1.int)
  of opI32LtUBrIf:
    ctx.emitBinOp(irLt32U)
    let cond = ctx.pop()
    ctx.lowerBrIfCond(cond, instr.imm1.int)
  of opI32GeUBrIf:
    ctx.emitBinOp(irGe32U)
    let cond = ctx.pop()
    ctx.lowerBrIfCond(cond, instr.imm1.int)
  of opI32GtUBrIf:
    ctx.emitBinOp(irGt32U)
    let cond = ctx.pop()
    ctx.lowerBrIfCond(cond, instr.imm1.int)
  of opI32LeUBrIf:
    ctx.emitBinOp(irLe32U)
    let cond = ctx.pop()
    ctx.lowerBrIfCond(cond, instr.imm1.int)

  # --- New fused: i32.const C; comparison; br_if L ---
  of opI32ConstI32EqBrIf:
    let c = ctx.emitConst32(cast[int32](instr.imm1)); ctx.push(c)
    ctx.emitBinOp(irEq32)
    let cond = ctx.pop()
    ctx.lowerBrIfCond(cond, instr.imm2.int)
  of opI32ConstI32NeBrIf:
    let c = ctx.emitConst32(cast[int32](instr.imm1)); ctx.push(c)
    ctx.emitBinOp(irNe32)
    let cond = ctx.pop()
    ctx.lowerBrIfCond(cond, instr.imm2.int)
  of opI32ConstI32LtSBrIf:
    let c = ctx.emitConst32(cast[int32](instr.imm1)); ctx.push(c)
    ctx.emitBinOp(irLt32S)
    let cond = ctx.pop()
    ctx.lowerBrIfCond(cond, instr.imm2.int)
  of opI32ConstI32GeSBrIf:
    let c = ctx.emitConst32(cast[int32](instr.imm1)); ctx.push(c)
    ctx.emitBinOp(irGe32S)
    let cond = ctx.pop()
    ctx.lowerBrIfCond(cond, instr.imm2.int)
  of opI32ConstI32GtUBrIf:
    let c = ctx.emitConst32(cast[int32](instr.imm1)); ctx.push(c)
    ctx.emitBinOp(irGt32U)
    let cond = ctx.pop()
    ctx.lowerBrIfCond(cond, instr.imm2.int)
  of opI32ConstI32LeUBrIf:
    let c = ctx.emitConst32(cast[int32](instr.imm1)); ctx.push(c)
    ctx.emitBinOp(irLe32U)
    let cond = ctx.pop()
    ctx.lowerBrIfCond(cond, instr.imm2.int)

  # --- New fused: i64 local.get + arithmetic ---
  of opLocalGetI64Add:
    let idx = instr.imm1.int
    if idx < ctx.locals.len:
      ctx.push(ctx.locals[idx])
    ctx.emitBinOp(irAdd64)
  of opLocalGetI64Sub:
    let idx = instr.imm1.int
    if idx < ctx.locals.len:
      ctx.push(ctx.locals[idx])
    ctx.emitBinOp(irSub64)

  # --- New fused: quad (4-instruction) operations ---
  of opLocalI32AddInPlace:
    # local[X] += C
    let idx = instr.imm1.int
    if idx < ctx.locals.len:
      ctx.push(ctx.locals[idx])
    let c = ctx.emitConst32(cast[int32](instr.imm2))
    ctx.push(c)
    ctx.emitBinOp(irAdd32)
    let v = ctx.pop()
    if idx < ctx.locals.len:
      ctx.locals[idx] = v
  of opLocalI32SubInPlace:
    # local[X] -= C
    let idx = instr.imm1.int
    if idx < ctx.locals.len:
      ctx.push(ctx.locals[idx])
    let c = ctx.emitConst32(cast[int32](instr.imm2))
    ctx.push(c)
    ctx.emitBinOp(irSub32)
    let v = ctx.pop()
    if idx < ctx.locals.len:
      ctx.locals[idx] = v
  of opLocalTeeBrIf:
    # local.tee X; br_if L → tee to local, then conditional branch
    let idx = instr.imm1.int
    let v = ctx.pop()
    if idx < ctx.locals.len:
      ctx.locals[idx] = v
    # Now behave like br_if with the tee'd value as condition
    var brProb = 128'u8
    if ctx.pgoData != nil and ctx.instrPc < ctx.pgoData.branchProfiles.len:
      brProb = branchTakenProb(ctx.pgoData.branchProfiles[ctx.instrPc])
    ctx.lowerBrIfCond(v, instr.imm2.int, brProb)

  of opLocalGetLocalGetI32AddLocalSet:
    # Z = local[X] + local[Y]
    let x = int(instr.imm1 and 0xFFFF'u32)
    let y = int(instr.imm1 shr 16)
    let z = instr.imm2.int
    if x < ctx.locals.len: ctx.push(ctx.locals[x])
    if y < ctx.locals.len: ctx.push(ctx.locals[y])
    ctx.emitBinOp(irAdd32)
    let v = ctx.pop()
    if z < ctx.locals.len:
      ctx.locals[z] = v
  of opLocalGetLocalGetI32SubLocalSet:
    # Z = local[X] - local[Y]
    let x = int(instr.imm1 and 0xFFFF'u32)
    let y = int(instr.imm1 shr 16)
    let z = instr.imm2.int
    if x < ctx.locals.len: ctx.push(ctx.locals[x])
    if y < ctx.locals.len: ctx.push(ctx.locals[y])
    ctx.emitBinOp(irSub32)
    let v = ctx.pop()
    if z < ctx.locals.len:
      ctx.locals[z] = v

  # --- Float constants ---
  of opF32Const:
    let v = ctx.f.makeConstF32(ctx.bb, cast[float32](instr.imm1))
    ctx.push(v)

  of opF64Const:
    let lo = instr.imm1.uint64
    let hi = instr.imm2.uint64
    let v = ctx.f.makeConstF64(ctx.bb, cast[float64](lo or (hi shl 32)))
    ctx.push(v)

  # --- Float memory ---
  of opF32Load:
    let addr0 = ctx.pop()
    let r = ctx.f.makeLoad(ctx.bb, irLoadF32, addr0, cast[int32](instr.imm1))
    ctx.push(r)

  of opF64Load:
    let addr0 = ctx.pop()
    let r = ctx.f.makeLoad(ctx.bb, irLoadF64, addr0, cast[int32](instr.imm1))
    ctx.push(r)

  of opF32Store:
    let val = ctx.pop()
    let addr0 = ctx.pop()
    ctx.f.makeStore(ctx.bb, irStoreF32, addr0, val, cast[int32](instr.imm1))

  of opF64Store:
    let val = ctx.pop()
    let addr0 = ctx.pop()
    ctx.f.makeStore(ctx.bb, irStoreF64, addr0, val, cast[int32](instr.imm1))

  # --- Float comparisons (result is i32 0/1) ---
  of opF32Eq: ctx.emitBinOp(irEqF32)
  of opF32Ne: ctx.emitBinOp(irNeF32)
  of opF32Lt: ctx.emitBinOp(irLtF32)
  of opF32Gt: ctx.emitBinOp(irGtF32)
  of opF32Le: ctx.emitBinOp(irLeF32)
  of opF32Ge: ctx.emitBinOp(irGeF32)
  of opF64Eq: ctx.emitBinOp(irEqF64)
  of opF64Ne: ctx.emitBinOp(irNeF64)
  of opF64Lt: ctx.emitBinOp(irLtF64)
  of opF64Gt: ctx.emitBinOp(irGtF64)
  of opF64Le: ctx.emitBinOp(irLeF64)
  of opF64Ge: ctx.emitBinOp(irGeF64)

  # --- Float unary arithmetic ---
  of opF32Abs:     ctx.emitUnaryOp(irAbsF32)
  of opF32Neg:     ctx.emitUnaryOp(irNegF32)
  of opF32Sqrt:    ctx.emitUnaryOp(irSqrtF32)
  of opF32Ceil:    ctx.emitUnaryOp(irCeilF32)
  of opF32Floor:   ctx.emitUnaryOp(irFloorF32)
  of opF32Trunc:   ctx.emitUnaryOp(irTruncF32)
  of opF32Nearest: ctx.emitUnaryOp(irNearestF32)
  of opF64Abs:     ctx.emitUnaryOp(irAbsF64)
  of opF64Neg:     ctx.emitUnaryOp(irNegF64)
  of opF64Sqrt:    ctx.emitUnaryOp(irSqrtF64)
  of opF64Ceil:    ctx.emitUnaryOp(irCeilF64)
  of opF64Floor:   ctx.emitUnaryOp(irFloorF64)
  of opF64Trunc:   ctx.emitUnaryOp(irTruncF64)
  of opF64Nearest: ctx.emitUnaryOp(irNearestF64)

  # --- Float binary arithmetic ---
  of opF32Add:      ctx.emitBinOp(irAddF32)
  of opF32Sub:      ctx.emitBinOp(irSubF32)
  of opF32Mul:      ctx.emitBinOp(irMulF32)
  of opF32Div:      ctx.emitBinOp(irDivF32)
  of opF32Min:      ctx.emitBinOp(irMinF32)
  of opF32Max:      ctx.emitBinOp(irMaxF32)
  of opF32Copysign: ctx.emitBinOp(irCopysignF32)
  of opF64Add:      ctx.emitBinOp(irAddF64)
  of opF64Sub:      ctx.emitBinOp(irSubF64)
  of opF64Mul:      ctx.emitBinOp(irMulF64)
  of opF64Div:      ctx.emitBinOp(irDivF64)
  of opF64Min:      ctx.emitBinOp(irMinF64)
  of opF64Max:      ctx.emitBinOp(irMaxF64)
  of opF64Copysign: ctx.emitBinOp(irCopysignF64)

  # --- Float conversions ---
  of opF32ConvertI32S:    ctx.emitUnaryOp(irF32ConvertI32S)
  of opF32ConvertI32U:    ctx.emitUnaryOp(irF32ConvertI32U)
  of opF32ConvertI64S:    ctx.emitUnaryOp(irF32ConvertI64S)
  of opF32ConvertI64U:    ctx.emitUnaryOp(irF32ConvertI64U)
  of opF64ConvertI32S:    ctx.emitUnaryOp(irF64ConvertI32S)
  of opF64ConvertI32U:    ctx.emitUnaryOp(irF64ConvertI32U)
  of opF64ConvertI64S:    ctx.emitUnaryOp(irF64ConvertI64S)
  of opF64ConvertI64U:    ctx.emitUnaryOp(irF64ConvertI64U)
  of opF32DemoteF64:      ctx.emitUnaryOp(irF32DemoteF64)
  of opF64PromoteF32:     ctx.emitUnaryOp(irF64PromoteF32)
  of opI32TruncF32S:      ctx.emitUnaryOp(irI32TruncF32S)
  of opI32TruncF32U:      ctx.emitUnaryOp(irI32TruncF32U)
  of opI32TruncF64S:      ctx.emitUnaryOp(irI32TruncF64S)
  of opI32TruncF64U:      ctx.emitUnaryOp(irI32TruncF64U)
  of opI64TruncF32S:      ctx.emitUnaryOp(irI64TruncF32S)
  of opI64TruncF32U:      ctx.emitUnaryOp(irI64TruncF32U)
  of opI64TruncF64S:      ctx.emitUnaryOp(irI64TruncF64S)
  of opI64TruncF64U:      ctx.emitUnaryOp(irI64TruncF64U)
  of opI32ReinterpretF32: ctx.emitUnaryOp(irI32ReinterpretF32)
  of opI64ReinterpretF64: ctx.emitUnaryOp(irI64ReinterpretF64)
  of opF32ReinterpretI32: ctx.emitUnaryOp(irF32ReinterpretI32)
  of opF64ReinterpretI64: ctx.emitUnaryOp(irF64ReinterpretI64)

  of opI32TruncSatF32S, opI32TruncSatF32U, opI32TruncSatF64S,
     opI32TruncSatF64U, opI64TruncSatF32S, opI64TruncSatF32U,
     opI64TruncSatF64S, opI64TruncSatF64U:
    discard ctx.pop()
    ctx.emitTrap()
    let v = ctx.emitConst32(0)
    ctx.push(v)

  of opRefNull:
    let v = ctx.emitConst32(-1)
    ctx.push(v)

  of opRefIsNull:
    discard ctx.pop()
    ctx.emitTrap()
    let v = ctx.emitConst32(0)
    ctx.push(v)

  of opRefFunc:
    let v = ctx.emitConst32(cast[int32](instr.imm1))
    ctx.push(v)

  of opBrTable:
    let idx = ctx.pop()
    ctx.bb.addInstr(IrInstr(op: irTrap, result: -1.IrValue,
      operands: [idx, -1.IrValue, -1.IrValue]))
    let deadBb = ctx.newBb()
    ctx.switchBb(deadBb)

  of opTableGet, opTableSet, opTableInit, opElemDrop, opTableCopy,
     opTableGrow, opTableSize, opTableFill:
    ctx.emitTrap()

  of opMemoryInit, opDataDrop, opMemoryCopy, opMemoryFill:
    ctx.emitTrap()

  # ---- Tail calls: emit as regular call + return ----
  of opReturnCall:
    let calleeIdx = instr.imm1.int

    # Fast path: self-recursive tail call → convert to back-edge loop
    if calleeIdx == ctx.funcIdx and ctx.restartBb >= 0:
      let numParams = ctx.f.numParams
      # Pop args in reverse (top of stack = last param)
      var args: seq[IrValue]
      for i in 0 ..< numParams:
        args.add(ctx.pop())
      if ctx.restartPhis.len > 0:
        # Phi-based TCO: patch phi back-edge operands directly — no memory spill/reload.
        # operands[1] on each phi node gets the new argument value for this iteration.
        for i in 0 ..< numParams:
          let argVal = args[numParams - 1 - i]
          if i < ctx.restartPhis.len:
            ctx.f.blocks[ctx.restartBb].instrs[ctx.restartPhis[i].instrIdx].operands[1] = argVal
        # Non-param locals reset to 0 each iteration (patch their phi back-edges too)
        for i in numParams ..< ctx.numOrigLocals:
          let z = ctx.f.makeConst32(ctx.bb, 0)
          if i < ctx.restartPhis.len:
            ctx.f.blocks[ctx.restartBb].instrs[ctx.restartPhis[i].instrIdx].operands[1] = z
      else:
        # Memory-based TCO fallback: spill new arg values and zeros to memory slots
        for i in 0 ..< numParams:
          ctx.bb.addInstr(IrInstr(op: irLocalSet, result: -1.IrValue,
            operands: [args[numParams - 1 - i], -1.IrValue, -1.IrValue],
            imm: i.int64))
        for i in numParams ..< ctx.numOrigLocals:
          let z = ctx.f.makeConst32(ctx.bb, 0)
          ctx.bb.addInstr(IrInstr(op: irLocalSet, result: -1.IrValue,
            operands: [z, -1.IrValue, -1.IrValue],
            imm: i.int64))
      # Loop back to restart BB
      ctx.addEdge(ctx.curBb, ctx.restartBb)
      ctx.bb.addInstr(IrInstr(op: irBr, result: -1.IrValue,
        operands: [-1.IrValue, -1.IrValue, -1.IrValue],
        imm: ctx.restartBb.int64))
      let deadBbTce = ctx.newBb()
      ctx.switchBb(deadBbTce)
      return

    # Non-self tail call: lower as call + return
    let numImportFuncs2 = block:
      var c = 0
      for imp in ctx.module[].imports:
        if imp.kind == ikFunc:
          inc c
      c
    var calleeFt2: FuncType
    var haveType2 = false
    if calleeIdx < numImportFuncs2:
      var importIdx = 0
      for imp in ctx.module[].imports:
        if imp.kind == ikFunc:
          if importIdx == calleeIdx:
            calleeFt2 = ctx.module[].types[imp.funcTypeIdx.int]
            haveType2 = true
            break
          inc importIdx
    elif calleeIdx - numImportFuncs2 < ctx.module[].funcTypeIdxs.len:
      let localIdx2 = calleeIdx - numImportFuncs2
      let typeIdx2 = ctx.module[].funcTypeIdxs[localIdx2]
      calleeFt2 = ctx.module[].types[typeIdx2.int]
      haveType2 = true
    if haveType2:
      var args: seq[IrValue]
      for i in 0 ..< calleeFt2.params.len:
        args.add(ctx.pop())
      let r = ctx.f.newValue()
      var operands: array[3, IrValue] = [-1.IrValue, -1.IrValue, -1.IrValue]
      for i in 0 ..< min(args.len, 3):
        operands[i] = args[args.len - 1 - i]  # args[] is reversed (top-of-stack = last param)
      ctx.bb.addInstr(IrInstr(op: irCall, result: r, operands: operands,
        imm: calleeIdx.int64))
      inc ctx.f.nonSelfCallSiteCount
      if calleeFt2.results.len > 0:
        ctx.bb.addInstr(IrInstr(op: irReturn, result: -1.IrValue,
          operands: [r, -1.IrValue, -1.IrValue]))
      else:
        ctx.bb.addInstr(IrInstr(op: irReturn, result: -1.IrValue,
          operands: [-1.IrValue, -1.IrValue, -1.IrValue]))
    else:
      ctx.emitTrap()
    let deadBb2 = ctx.newBb()
    ctx.switchBb(deadBb2)

  of opReturnCallIndirect:
    # Lower as call_indirect + irReturn (same as opCallIndirect but tail position).
    let typeIdx3 = instr.imm1.int
    let elemIdx3 = ctx.pop()  # table element index (i32)
    if typeIdx3 >= ctx.module[].types.len:
      ctx.emitTrap()
    else:
      let ft3 = ctx.module[].types[typeIdx3]
      let paramCount3 = ft3.params.len
      let resultCount3 = ft3.results.len
      var args3: seq[IrValue]
      for _ in 0 ..< paramCount3:
        args3.add(ctx.pop())
      let tempBase3 = ctx.f.numLocals
      ctx.f.numLocals += max(paramCount3, if resultCount3 > 0: 1 else: 0)
      for i in 0 ..< paramCount3:
        let argVal3 = args3[paramCount3 - 1 - i]
        ctx.bb.addInstr(IrInstr(op: irLocalSet, result: -1.IrValue,
          operands: [argVal3, -1.IrValue, -1.IrValue],
          imm: (tempBase3 + i).int64))
      let res3 = if resultCount3 > 0: ctx.f.newValue() else: -1.IrValue
      ctx.bb.addInstr(IrInstr(
        op: irCallIndirect,
        result: res3,
        operands: [elemIdx3, -1.IrValue, -1.IrValue],
        imm: paramCount3.int64 or (resultCount3.int64 shl 16),
        imm2: tempBase3.int32))
      ctx.f.usesMemory = true
      inc ctx.f.callIndirectSiteCount
      # Emit irReturn with the call result (tail position)
      ctx.bb.addInstr(IrInstr(op: irReturn, result: -1.IrValue,
        operands: [res3, -1.IrValue, -1.IrValue]))
    let deadBb3 = ctx.newBb()
    ctx.switchBb(deadBb3)

  # ---- Exception handling: emit trap ----
  of opThrow:
    ctx.emitTrap()
    let deadBb4 = ctx.newBb()
    ctx.switchBb(deadBb4)

  of opThrowRef:
    discard ctx.pop()
    ctx.emitTrap()
    let deadBb5 = ctx.newBb()
    ctx.switchBb(deadBb5)

  of opTryTable:
    # Same as block
    let mergeBb = ctx.newBb()
    let bt = padToBlockType(instr.pad)
    let (hasRes, resType) = ctx.blockResultType(bt)
    let resSlot = if hasRes: (let s = ctx.f.numLocals; inc ctx.f.numLocals; s) else: -1
    ctx.blockStack.add(BlockState(
      bb: mergeBb,
      valStack: ctx.valStack,
      locals: ctx.locals,
      kind: lbkBlock,
      hasResult: hasRes,
      resultType: resType,
      resultSlot: resSlot,
      elseBb: -1,
    ))

  # ---- SIMD v128 ----
  of opV128Load:
    let baseAddr = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irLoadV128, result: v,
      operands: [baseAddr, -1.IrValue, -1.IrValue], imm2: int32(instr.imm2)))
    ctx.push(v)
    ctx.f.usesMemory = true

  of opV128Store:
    let val = ctx.pop()
    let baseAddr = ctx.pop()
    ctx.bb.addInstr(IrInstr(op: irStoreV128, result: -1.IrValue,
      operands: [baseAddr, val, -1.IrValue], imm2: int32(instr.imm2)))
    ctx.f.usesMemory = true

  of opV128Const:
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irConstV128, result: v, imm: instr.imm1.int64))
    ctx.push(v)

  of opI32x4Splat:
    let scalar = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI32x4Splat, result: v,
      operands: [scalar, -1.IrValue, -1.IrValue]))
    ctx.push(v)

  of opF32x4Splat:
    let scalar = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irF32x4Splat, result: v,
      operands: [scalar, -1.IrValue, -1.IrValue]))
    ctx.push(v)

  of opI8x16Splat:
    let scalar = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI8x16Splat, result: v,
      operands: [scalar, -1.IrValue, -1.IrValue]))
    ctx.push(v)

  of opI16x8Splat:
    let scalar = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI16x8Splat, result: v,
      operands: [scalar, -1.IrValue, -1.IrValue]))
    ctx.push(v)

  of opI64x2Splat:
    let scalar = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI64x2Splat, result: v,
      operands: [scalar, -1.IrValue, -1.IrValue]))
    ctx.push(v)

  of opF64x2Splat:
    let scalar = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irF64x2Splat, result: v,
      operands: [scalar, -1.IrValue, -1.IrValue]))
    ctx.push(v)

  of opI32x4ExtractLane:
    let vec = ctx.pop()
    let lane = instr.imm1.int
    let v = ctx.f.newValue()
    ctx.bb.addInstr(IrInstr(op: irI32x4ExtractLane, result: v,
      operands: [vec, -1.IrValue, -1.IrValue], imm: lane.int64))
    ctx.push(v)

  of opI32x4ReplaceLane:
    let scalar = ctx.pop()
    let vec = ctx.pop()
    let lane = instr.imm1.int
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI32x4ReplaceLane, result: v,
      operands: [vec, scalar, -1.IrValue], imm: lane.int64))
    ctx.push(v)

  of opF32x4ExtractLane:
    let vec = ctx.pop()
    let lane = instr.imm1.int
    let v = ctx.f.newValue()  # f32 result — scalar float register
    ctx.bb.addInstr(IrInstr(op: irF32x4ExtractLane, result: v,
      operands: [vec, -1.IrValue, -1.IrValue], imm: lane.int64))
    ctx.push(v)

  of opF32x4ReplaceLane:
    let scalar = ctx.pop()
    let vec = ctx.pop()
    let lane = instr.imm1.int
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irF32x4ReplaceLane, result: v,
      operands: [vec, scalar, -1.IrValue], imm: lane.int64))
    ctx.push(v)

  of opV128Not:
    let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irV128Not, result: v,
      operands: [a, -1.IrValue, -1.IrValue]))
    ctx.push(v)

  of opV128And:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irV128And, result: v,
      operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opV128Or:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irV128Or, result: v,
      operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opV128Xor:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irV128Xor, result: v,
      operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opI32x4Add:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI32x4Add, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opI32x4Sub:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI32x4Sub, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opI32x4Mul:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI32x4Mul, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opF32x4Add:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irF32x4Add, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opF32x4Sub:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irF32x4Sub, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opF32x4Mul:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irF32x4Mul, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opF32x4Div:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irF32x4Div, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  # ---- Extended SIMD ----

  of opI8x16ExtractLaneS:
    let vec = ctx.pop()
    let v = ctx.f.newValue()
    ctx.bb.addInstr(IrInstr(op: irI8x16ExtractLaneS, result: v,
      operands: [vec, -1.IrValue, -1.IrValue], imm: instr.imm1.int64))
    ctx.push(v)

  of opI8x16ExtractLaneU:
    let vec = ctx.pop()
    let v = ctx.f.newValue()
    ctx.bb.addInstr(IrInstr(op: irI8x16ExtractLaneU, result: v,
      operands: [vec, -1.IrValue, -1.IrValue], imm: instr.imm1.int64))
    ctx.push(v)

  of opI8x16ReplaceLane:
    let scalar = ctx.pop(); let vec = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI8x16ReplaceLane, result: v,
      operands: [vec, scalar, -1.IrValue], imm: instr.imm1.int64))
    ctx.push(v)

  of opI16x8ExtractLaneS:
    let vec = ctx.pop()
    let v = ctx.f.newValue()
    ctx.bb.addInstr(IrInstr(op: irI16x8ExtractLaneS, result: v,
      operands: [vec, -1.IrValue, -1.IrValue], imm: instr.imm1.int64))
    ctx.push(v)

  of opI16x8ExtractLaneU:
    let vec = ctx.pop()
    let v = ctx.f.newValue()
    ctx.bb.addInstr(IrInstr(op: irI16x8ExtractLaneU, result: v,
      operands: [vec, -1.IrValue, -1.IrValue], imm: instr.imm1.int64))
    ctx.push(v)

  of opI16x8ReplaceLane:
    let scalar = ctx.pop(); let vec = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI16x8ReplaceLane, result: v,
      operands: [vec, scalar, -1.IrValue], imm: instr.imm1.int64))
    ctx.push(v)

  of opI64x2ExtractLane:
    let vec = ctx.pop()
    let v = ctx.f.newValue()
    ctx.bb.addInstr(IrInstr(op: irI64x2ExtractLane, result: v,
      operands: [vec, -1.IrValue, -1.IrValue], imm: instr.imm1.int64))
    ctx.push(v)

  of opI64x2ReplaceLane:
    let scalar = ctx.pop(); let vec = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI64x2ReplaceLane, result: v,
      operands: [vec, scalar, -1.IrValue], imm: instr.imm1.int64))
    ctx.push(v)

  of opF64x2ExtractLane:
    let vec = ctx.pop()
    let v = ctx.f.newValue()
    ctx.bb.addInstr(IrInstr(op: irF64x2ExtractLane, result: v,
      operands: [vec, -1.IrValue, -1.IrValue], imm: instr.imm1.int64))
    ctx.push(v)

  of opF64x2ReplaceLane:
    let scalar = ctx.pop(); let vec = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irF64x2ReplaceLane, result: v,
      operands: [vec, scalar, -1.IrValue], imm: instr.imm1.int64))
    ctx.push(v)

  of opV128AndNot:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irV128AndNot, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opI8x16Abs:
    let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI8x16Abs, result: v, operands: [a, -1.IrValue, -1.IrValue]))
    ctx.push(v)

  of opI8x16Neg:
    let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI8x16Neg, result: v, operands: [a, -1.IrValue, -1.IrValue]))
    ctx.push(v)

  of opI8x16Add:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI8x16Add, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opI8x16Sub:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI8x16Sub, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opI8x16MinS:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI8x16MinS, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opI8x16MinU:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI8x16MinU, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opI8x16MaxS:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI8x16MaxS, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opI8x16MaxU:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI8x16MaxU, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opI16x8Abs:
    let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI16x8Abs, result: v, operands: [a, -1.IrValue, -1.IrValue]))
    ctx.push(v)

  of opI16x8Neg:
    let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI16x8Neg, result: v, operands: [a, -1.IrValue, -1.IrValue]))
    ctx.push(v)

  of opI16x8Add:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI16x8Add, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opI16x8Sub:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI16x8Sub, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opI16x8Mul:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI16x8Mul, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opI32x4Abs:
    let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI32x4Abs, result: v, operands: [a, -1.IrValue, -1.IrValue]))
    ctx.push(v)

  of opI32x4Neg:
    let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI32x4Neg, result: v, operands: [a, -1.IrValue, -1.IrValue]))
    ctx.push(v)

  of opI32x4Shl:
    let shift = ctx.pop(); let vec = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI32x4Shl, result: v, operands: [vec, shift, -1.IrValue]))
    ctx.push(v)

  of opI32x4ShrS:
    let shift = ctx.pop(); let vec = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI32x4ShrS, result: v, operands: [vec, shift, -1.IrValue]))
    ctx.push(v)

  of opI32x4ShrU:
    let shift = ctx.pop(); let vec = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI32x4ShrU, result: v, operands: [vec, shift, -1.IrValue]))
    ctx.push(v)

  of opI32x4MinS:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI32x4MinS, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opI32x4MinU:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI32x4MinU, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opI32x4MaxS:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI32x4MaxS, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opI32x4MaxU:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI32x4MaxU, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opI64x2Add:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI64x2Add, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opI64x2Sub:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irI64x2Sub, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opF32x4Abs:
    let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irF32x4Abs, result: v, operands: [a, -1.IrValue, -1.IrValue]))
    ctx.push(v)

  of opF32x4Neg:
    let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irF32x4Neg, result: v, operands: [a, -1.IrValue, -1.IrValue]))
    ctx.push(v)

  of opF64x2Add:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irF64x2Add, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opF64x2Sub:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irF64x2Sub, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opF64x2Mul:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irF64x2Mul, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opF64x2Div:
    let b = ctx.pop(); let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irF64x2Div, result: v, operands: [a, b, -1.IrValue]))
    ctx.push(v)

  of opF64x2Abs:
    let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irF64x2Abs, result: v, operands: [a, -1.IrValue, -1.IrValue]))
    ctx.push(v)

  of opF64x2Neg:
    let a = ctx.pop()
    let v = ctx.f.newSimdValue()
    ctx.bb.addInstr(IrInstr(op: irF64x2Neg, result: v, operands: [a, -1.IrValue, -1.IrValue]))
    ctx.push(v)


proc lowerFunction*(module: WasmModule, funcIdx: int,
                    pgoData: ptr FuncPgoData = nil): IrFunc =
  ## Convert a WASM function to SSA-form IR
  ##
  ## `funcIdx` is the absolute function index (including imports).
  ## Only non-imported functions can be lowered.

  # Compute offset past imported functions
  var numImportFuncs = 0
  for imp in module.imports:
    if imp.kind == ikFunc:
      inc numImportFuncs

  let localFuncIdx = funcIdx - numImportFuncs
  assert localFuncIdx >= 0 and localFuncIdx < module.codes.len,
    "funcIdx does not refer to a non-imported function"

  let body = module.codes[localFuncIdx]
  let typeIdx = module.funcTypeIdxs[localFuncIdx]
  let funcType = module.types[typeIdx.int]

  let numParams = funcType.params.len
  let numBodyLocals = countLocals(body)
  let totalLocals = numParams + numBodyLocals

  # Pre-scan bytecode to check if function uses memory (needed for phi loop decision)
  var hasMemoryOps = false
  for instr in body.code.code:
    if instr.op in {opI32Load, opI64Load, opF32Load, opF64Load,
                     opI32Load8S, opI32Load8U, opI32Load16S, opI32Load16U,
                     opI64Load8S, opI64Load8U, opI64Load16S, opI64Load16U,
                     opI64Load32S, opI64Load32U,
                     opI32Store, opI64Store, opF32Store, opF64Store,
                     opI32Store8, opI32Store16, opI64Store8, opI64Store16, opI64Store32,
                     opMemorySize, opMemoryGrow}:
      hasMemoryOps = true
      break

  var code = body.code.code

  # Automatic TCO: detect self-recursive calls in tail position in the bytecode
  # and rewrite opCall → opReturnCall. The lowerer's TCO machinery below will
  # then convert them to loop back-edges with phi nodes.
  let autoTcoRewrites = rewriteTailCalls(code, funcIdx)

  # Pre-scan for self-recursive tail calls (enables TCO loop transformation).
  # This now picks up both explicit opReturnCall AND any auto-TCO rewrites.
  var hasSelfTailCall = false
  var selfTailCallCount = 0
  for instr in code:
    if instr.op == opReturnCall and instr.imm1.int == funcIdx:
      hasSelfTailCall = true
      inc selfTailCallCount

  var ctx = LowerCtx(
    funcIdx: funcIdx,
    module: unsafeAddr module,
    usePhiLoops: true,  # phi loops for all functions
    restartBb: -1,
    numOrigLocals: totalLocals,
    pgoData: pgoData,
  )
  # Count module globals — they're mapped to locals after the function's locals.
  # Add them to numLocals so the codegen allocates enough stack frame space
  # for irLocalGet/Set to access global-mapped slots.
  var numModuleGlobals = 0
  for imp in module.imports:
    if imp.kind == ikGlobal: inc numModuleGlobals
  numModuleGlobals += module.globals.len

  ctx.f.numParams = numParams
  ctx.f.numLocals = totalLocals + numModuleGlobals
  ctx.f.numResults = funcType.results.len

  # Create entry basic block
  let entryBb = ctx.newBb()
  ctx.curBb = entryBb

  # Create IrValues for parameters
  ctx.locals = newSeq[IrValue](totalLocals)
  for i in 0 ..< numParams:
    let paramVal = ctx.f.makeParam(ctx.bb, i)
    ctx.locals[i] = paramVal

  # Initialize non-param locals to const 0
  for i in numParams ..< totalLocals:
    let zeroVal = ctx.emitConst32(0)
    ctx.locals[i] = zeroVal

  # TCO: if function has self tail calls, set up a memory-spill restart BB.
  # The entry BB spills all locals to memory slots, branches to restartBb.
  # restartBb reloads them as fresh SSA values and is the actual loop header.
  # Each return_call self-site spills new arg values + zeros non-param locals,
  # then branches back to restartBb — turning recursion into a simple loop.
  if hasSelfTailCall:
    let restartBb = ctx.newBb()
    if selfTailCallCount == 1:
      # Phi-based TCO: keep loop variables in registers, no memory spill/reload.
      # Same pattern as lbkLoop phi loops — phi nodes at the loop header merge:
      #   operands[0] = preheader value (from entry BB)
      #   operands[1] = back-edge value (patched when opReturnCall is lowered)
      let preheaderLocals = ctx.locals
      ctx.addEdge(ctx.curBb, restartBb)
      ctx.bb.addInstr(IrInstr(op: irBr, result: -1.IrValue,
        operands: [-1.IrValue, -1.IrValue, -1.IrValue], imm: restartBb.int64))
      ctx.switchBb(restartBb)
      var restartLocals = newSeq[IrValue](totalLocals)
      for i in 0 ..< totalLocals:
        let phiVal = ctx.f.newValue()
        let instrIdx = ctx.bb.instrs.len
        ctx.bb.addInstr(IrInstr(op: irPhi, result: phiVal,
          operands: [preheaderLocals[i], -1.IrValue, -1.IrValue], imm: i.int64))
        restartLocals[i] = phiVal
        ctx.restartPhis.add(PhiInfo(phiVal: phiVal, localIdx: i, instrIdx: instrIdx))
      ctx.locals = restartLocals
    else:
      # Multiple back-edges: memory-spill fallback (spill to memory before branch, reload at header)
      for i in 0 ..< totalLocals:
        ctx.bb.addInstr(IrInstr(op: irLocalSet, result: -1.IrValue,
          operands: [ctx.locals[i], -1.IrValue, -1.IrValue], imm: i.int64))
      ctx.addEdge(ctx.curBb, restartBb)
      ctx.bb.addInstr(IrInstr(op: irBr, result: -1.IrValue,
        operands: [-1.IrValue, -1.IrValue, -1.IrValue], imm: restartBb.int64))
      ctx.switchBb(restartBb)
      var loopLocals = newSeq[IrValue](totalLocals)
      for i in 0 ..< totalLocals:
        let v = ctx.f.newValue()
        ctx.bb.addInstr(IrInstr(op: irLocalGet, result: v,
          operands: [-1.IrValue, -1.IrValue, -1.IrValue], imm: i.int64))
        loopLocals[i] = v
      ctx.locals = loopLocals
    ctx.restartBb = restartBb

  # Copy v128 constants from WASM expression into IrFunc
  ctx.f.v128Consts = body.code.v128Consts

  # When auto-TCO rewrote opCall→opReturnCall AND the function has a shadow-stack
  # prologue (-O0 pattern: global.get sp; sub frameSize; global.set sp; store params),
  # we need to lower the prologue into the entry BB BEFORE the TCO restart BB.
  # Otherwise the prologue (stack allocation) re-executes on every loop iteration.
  #
  # Strategy: detect prologue end (first opBlock/opLoop/opIf), lower prologue
  # into the current BB (which is either the entry BB if no explicit return_call,
  # or the restartBb if TCO was set up). If in restartBb, move prologue instrs
  # to BB0 by patching the blocks directly.
  var startPc = 0
  if hasSelfTailCall and autoTcoRewrites > 0 and ctx.restartBb >= 0:
    var prologueEnd = 0
    for i in 0 ..< code.len:
      if code[i].op in {opBlock, opLoop, opIf}:
        prologueEnd = i
        break
    if prologueEnd > 0:
      # Save the phi-mapped locals and temporarily restore the original param
      # locals. This ensures the prologue's local.get instructions read the
      # original irParam values (v0, v1) rather than the phi values (v4, v5).
      let phiLocals = ctx.locals  # save phi-mapped locals
      # Reconstruct original param locals from the phi preheader operands
      var origLocals = newSeq[IrValue](ctx.locals.len)
      for i in 0 ..< ctx.locals.len:
        if i < ctx.restartPhis.len:
          # The phi's operands[0] is the preheader (original) value
          origLocals[i] = ctx.f.blocks[ctx.restartBb].instrs[ctx.restartPhis[i].instrIdx].operands[0]
        else:
          origLocals[i] = ctx.locals[i]
      ctx.locals = origLocals

      # Lower prologue into the restartBb (current BB) temporarily
      for instrPc in 0 ..< prologueEnd:
        ctx.instrPc = instrPc
        ctx.lowerInstr(code[instrPc])
      startPc = prologueEnd

      # After lowering the prologue, ctx.locals has been updated with the
      # prologue's computed values (e.g., local[2] = stack pointer after alloc).
      # Patch the phi preheader operands (operands[0]) with these post-prologue values.
      let postPrologueLocals = ctx.locals
      for i in 0 ..< min(postPrologueLocals.len, ctx.restartPhis.len):
        ctx.f.blocks[ctx.restartBb].instrs[ctx.restartPhis[i].instrIdx].operands[0] = postPrologueLocals[i]

      # Restore the phi-mapped locals for the function body
      ctx.locals = phiLocals

      # Move prologue instructions from restartBb to BB0 (entry BB).
      let restartIdx = ctx.restartBb
      let phiCount = ctx.restartPhis.len

      let totalInstrs = ctx.f.blocks[restartIdx].instrs.len
      if totalInstrs > phiCount:
        let prologueInstrs = ctx.f.blocks[restartIdx].instrs[phiCount ..< totalInstrs]
        ctx.f.blocks[restartIdx].instrs.setLen(phiCount)

        let bb0Len = ctx.f.blocks[0].instrs.len
        if bb0Len > 0 and ctx.f.blocks[0].instrs[^1].op == irBr:
          let brInstr = ctx.f.blocks[0].instrs[^1]
          ctx.f.blocks[0].instrs.setLen(bb0Len - 1)
          for pi in prologueInstrs:
            ctx.f.blocks[0].instrs.add(pi)
          ctx.f.blocks[0].instrs.add(brInstr)
        else:
          for pi in prologueInstrs:
            ctx.f.blocks[0].instrs.add(pi)

  # Walk remaining WASM instructions and lower each one.
  for instrPc in startPc ..< code.len:
    ctx.instrPc = instrPc
    ctx.lowerInstr(code[instrPc])

  # Detect if function uses memory (scan IR for memory ops)
  for bb in ctx.f.blocks:
    for instr in bb.instrs:
      if instr.op in {irLoad32, irLoad64, irLoad8U, irLoad8S, irLoad16U, irLoad16S,
                       irLoad32U, irLoad32S, irLoadF32, irLoadF64,
                       irStore32, irStore64, irStore8, irStore16,
                       irStore32From64, irStoreF32, irStoreF64}:
        ctx.f.usesMemory = true
        break
    if ctx.f.usesMemory: break

  # If the function has results and we have values on the stack, emit a return
  if ctx.valStack.len > 0 and funcType.results.len > 0:
    let retVal = ctx.pop()
    ctx.bb.addInstr(IrInstr(op: irReturn, result: -1.IrValue,
      operands: [retVal, -1.IrValue, -1.IrValue]))
  elif funcType.results.len == 0:
    # Void return
    ctx.bb.addInstr(IrInstr(op: irReturn, result: -1.IrValue,
      operands: [-1.IrValue, -1.IrValue, -1.IrValue]))

  result = ctx.f
