## Register-allocated IR to AArch64 code generator (Tier 2 backend)
##
## Takes an IrFunc and a RegAllocResult from the graph-coloring register
## allocator and emits AArch64 instructions using physical registers.
## Unlike the baseline compiler (codegen.nim/compiler.nim) which uses a
## value-stack approach (x8=VSP), this backend operates on named SSA values
## that have been assigned to physical registers.
##
## Register convention:
##   intRegs[0..3]  = x12-x15 (scratch, caller-saved)
##   intRegs[4..13] = x19-x28 (callee-saved)
##   x8  = unused in Tier 2 (no value stack)
##   x9  = WASM locals base pointer (for spilled values & locals without a register)
##   x10 = WASM memory base
##   x11 = WASM memory size
##   fp/lr saved on stack
##
## Function ABI (same as baseline):
##   (x0=return area, x1=locals, x2=memBase, x3=memSize) -> ptr uint64
##
## Spill slots are accessed via [SP, #offset] from RegAllocResult.spillSlots.

import ir, regalloc, codegen, memory, compiler, optimize, aotcache

# ---------------------------------------------------------------------------
# Sub-word memory encoding helpers (same as compiler.nim, local to this module)
# ---------------------------------------------------------------------------

proc ldrbImm(buf: var AsmBuffer, dst, base: Reg, offset: int32) =
  ## LDRB Wt, [Xn, #offset] -- unsigned byte load, zero-extends to 32-bit
  let uoff = offset.uint32 and 0xFFF
  buf.emit(0x39400000'u32 or (uoff shl 10) or (base.uint8.uint32 shl 5) or dst.uint8.uint32)

proc ldrhImm(buf: var AsmBuffer, dst, base: Reg, offset: int32) =
  ## LDRH Wt, [Xn, #offset] -- unsigned halfword load, zero-extends to 32-bit
  let uoff = (offset div 2).uint32 and 0xFFF
  buf.emit(0x79400000'u32 or (uoff shl 10) or (base.uint8.uint32 shl 5) or dst.uint8.uint32)

proc ldrsbImm32(buf: var AsmBuffer, dst, base: Reg, offset: int32) =
  ## LDRSB Wt, [Xn, #offset] -- signed byte load, sign-extends to 32-bit
  let uoff = offset.uint32 and 0xFFF
  buf.emit(0x39C00000'u32 or (uoff shl 10) or (base.uint8.uint32 shl 5) or dst.uint8.uint32)

proc ldrshImm32(buf: var AsmBuffer, dst, base: Reg, offset: int32) =
  ## LDRSH Wt, [Xn, #offset] -- signed halfword load, sign-extends to 32-bit
  let uoff = (offset div 2).uint32 and 0xFFF
  buf.emit(0x79C00000'u32 or (uoff shl 10) or (base.uint8.uint32 shl 5) or dst.uint8.uint32)

proc ldrswImm(buf: var AsmBuffer, dst, base: Reg, offset: int32) =
  ## LDRSW Xt, [Xn, #offset] -- signed word load, sign-extends to 64-bit
  let uoff = (offset div 4).uint32 and 0xFFF
  buf.emit(0xB9800000'u32 or (uoff shl 10) or (base.uint8.uint32 shl 5) or dst.uint8.uint32)

proc strbImm(buf: var AsmBuffer, src, base: Reg, offset: int32) =
  ## STRB Wt, [Xn, #offset] -- store byte
  let uoff = offset.uint32 and 0xFFF
  buf.emit(0x39000000'u32 or (uoff shl 10) or (base.uint8.uint32 shl 5) or src.uint8.uint32)

proc strhImm(buf: var AsmBuffer, src, base: Reg, offset: int32) =
  ## STRH Wt, [Xn, #offset] -- store halfword
  let uoff = (offset div 2).uint32 and 0xFFF
  buf.emit(0x79000000'u32 or (uoff shl 10) or (base.uint8.uint32 shl 5) or src.uint8.uint32)

# Store pair (signed offset) -- not in codegen.nim
proc stpImm(buf: var AsmBuffer, rt1, rt2, base: Reg, offset: int32, is64: bool = true) =
  ## STP Rt1, Rt2, [Rn, #offset] (store pair, signed offset)
  let opc = if is64: 2'u32 else: 0'u32
  let scale = if is64: 8 else: 4
  let simm7 = ((offset div scale).uint32 and 0x7F)
  buf.emit((opc shl 30) or 0x29000000'u32 or (simm7 shl 15) or
           (rt2.uint8.uint32 shl 10) or (base.uint8.uint32 shl 5) or rt1.uint8.uint32)

# ---------------------------------------------------------------------------
# Register resolution
# ---------------------------------------------------------------------------

const
  rTmp0 = rScratch0   # x12 -- temporary for spill loads/stores
  rTmp1 = rScratch1   # x13 -- second temporary

proc isSpilled(alloc: RegAllocResult, v: IrValue): bool {.inline.} =
  ## Check whether SSA value `v` is spilled (no physical register)
  v >= 0 and alloc.assignment[v.int].int8 < 0

proc physReg(alloc: RegAllocResult, v: IrValue): Reg =
  ## Get the physical register for an SSA value.
  ## If the value is spilled, returns rTmp0 as a placeholder; caller must
  ## issue explicit spill load/store around uses.
  if v < 0:
    return xzr
  let pr = alloc.assignment[v.int]
  if pr.int8 >= 0 and pr.int8 < intRegs.len.int8:
    intRegs[pr.int8]
  else:
    rTmp0  # fallback for spilled values -- caller handles load

proc spillOffset(alloc: RegAllocResult, v: IrValue): int32 {.inline.} =
  ## Get the spill slot byte offset for a spilled SSA value.
  ## Uses precomputed spillOffsetMap for O(1) lookup.
  if v.int < alloc.spillOffsetMap.len:
    result = alloc.spillOffsetMap[v.int]
  else:
    result = 0  # fallback (shouldn't happen)

proc emitSpillLoad(buf: var AsmBuffer, dst: Reg, alloc: RegAllocResult, v: IrValue) =
  ## Load a spilled value from its stack slot into `dst`
  let off = spillOffset(alloc, v)
  buf.ldrImm(dst, sp, off)

proc emitSpillStore(buf: var AsmBuffer, src: Reg, alloc: RegAllocResult, v: IrValue) =
  ## Store a value to its spill slot on the stack
  let off = spillOffset(alloc, v)
  buf.strImm(src, sp, off)

proc emitRemat(buf: var AsmBuffer, alloc: RegAllocResult, v: IrValue,
               scratch: Reg): Reg =
  ## Emit the rematerialisation code for a constant SSA value.
  ## Returns the scratch register containing the rematerialised value.
  let imm = alloc.rematImm[v.int]
  if imm >= 0 and imm <= int32.high:
    buf.loadImm32(scratch, imm.int32)
  else:
    buf.loadImm64(scratch, cast[uint64](imm))
  scratch

proc loadOperand(buf: var AsmBuffer, alloc: RegAllocResult, v: IrValue,
                 scratch: Reg = rTmp0): Reg =
  ## Get the physical register for an operand, loading from spill slot if needed.
  ## For rematerialisable constants, re-emits the defining instruction (mov reg, imm)
  ## instead of loading from a stack slot — avoids the memory round-trip entirely.
  if v < 0:
    return xzr
  if alloc.isSpilled(v):
    if v.int < alloc.rematKind.len and alloc.rematKind[v.int] == rematConst:
      return buf.emitRemat(alloc, v, scratch)
    buf.emitSpillLoad(scratch, alloc, v)
    return scratch
  return alloc.physReg(v)

proc storeResult(buf: var AsmBuffer, alloc: RegAllocResult, v: IrValue, src: Reg) =
  ## If the result value is spilled, store `src` to its spill slot.
  ## Rematerialisable values are never stored — they are re-emitted at each use.
  ## If register-allocated and src != its register, emit a MOV.
  if v < 0: return
  if alloc.isSpilled(v):
    if v.int < alloc.rematKind.len and alloc.rematKind[v.int] == rematConst:
      return  # remat: definition is free; don't write to a (non-existent) spill slot
    buf.emitSpillStore(src, alloc, v)
  else:
    let dst = alloc.physReg(v)
    if dst != src:
      buf.movReg(dst, src)

# ---------------------------------------------------------------------------
# SIMD (v128 / Q-register) resolution helpers
# ---------------------------------------------------------------------------
# Allocatable SIMD registers: v16-v29 (colors 0-13 → FReg(16+color)).
# v30-v31 are reserved as SIMD codegen scratch (fSimdScratch0/1).
# ---------------------------------------------------------------------------

const
  fSimdScratch0 = FReg(30)   ## SIMD scratch register 0 (v30)
  fSimdScratch1 = FReg(31)   ## SIMD scratch register 1 (v31)

proc physSimdReg(alloc: RegAllocResult, v: IrValue): FReg =
  ## Return the physical Q-register for a SIMD SSA value.
  ## Allocatable range: v16-v29 (colors 0-13). Returns fSimdScratch0 for spilled/invalid.
  if v < 0: return fSimdScratch0
  let pr = alloc.assignment[v.int]
  if pr.int8 >= 0: FReg(16 + pr.int8.int) else: fSimdScratch0

proc emitSimdSpillLoad(buf: var AsmBuffer, dst: FReg, alloc: RegAllocResult, v: IrValue) =
  ## Load a spilled v128 value from its stack slot into `dst`.
  ## Uses rTmp0 as a scratch GP register to compute the address.
  let off = spillOffset(alloc, v)
  if off >= 0 and off <= 4095:
    buf.addImm(rTmp0, sp, off.uint32)
  else:
    buf.loadImm32(rTmp0, off)
    buf.addReg(rTmp0, sp, rTmp0)
  buf.ld1q(dst, rTmp0)

proc emitSimdSpillStore(buf: var AsmBuffer, src: FReg, alloc: RegAllocResult, v: IrValue) =
  ## Store a v128 value to its spill slot on the stack.
  ## Uses rTmp0 as a scratch GP register to compute the address.
  let off = spillOffset(alloc, v)
  if off >= 0 and off <= 4095:
    buf.addImm(rTmp0, sp, off.uint32)
  else:
    buf.loadImm32(rTmp0, off)
    buf.addReg(rTmp0, sp, rTmp0)
  buf.st1q(src, rTmp0)

proc loadSimdOperand(buf: var AsmBuffer, alloc: RegAllocResult, v: IrValue,
                     scratch: FReg = fSimdScratch0): FReg =
  ## Resolve a SIMD operand to a physical Q-register, loading from the spill
  ## slot if necessary. `scratch` is the fallback FReg for spilled values.
  if v < 0: return scratch
  if alloc.isSpilled(v):
    buf.emitSimdSpillLoad(scratch, alloc, v)
    return scratch
  return alloc.physSimdReg(v)

proc storeSimdResult(buf: var AsmBuffer, alloc: RegAllocResult, v: IrValue, src: FReg) =
  ## Store a SIMD result: spill to stack if necessary, else MOV to destination Q-reg.
  if v < 0: return
  if alloc.isSpilled(v):
    buf.emitSimdSpillStore(src, alloc, v)
  else:
    let dst = alloc.physSimdReg(v)
    if dst != src:
      buf.movVec(dst, src)

proc emitV128Const(buf: var AsmBuffer, dst: FReg, bytes: array[16, byte]) =
  ## Materialize a 128-bit constant into a Q register.
  ## Uses 4×(MOVZ/MOVK + INS) to set each 32-bit lane. Clobbers rTmp0.
  for lane in 0 ..< 4:
    let b = lane * 4
    let word = bytes[b].uint32 or (bytes[b+1].uint32 shl 8) or
               (bytes[b+2].uint32 shl 16) or (bytes[b+3].uint32 shl 24)
    buf.loadImm32(rTmp0, cast[int32](word))
    buf.insVec4sFromW(dst, lane, rTmp0)

# ---------------------------------------------------------------------------
# Callee-saved register save/restore helpers
# ---------------------------------------------------------------------------

proc calleeSavedList(alloc: RegAllocResult): seq[Reg] =
  ## Return the list of callee-saved physical registers used, in order.
  ## Callee-saved = intRegs[2..11] (x19-x28, PhysReg indices 2..11)
  for i in 2'i8 .. 11'i8:
    if i in alloc.calleeSaved:
      result.add(intRegs[i])

proc saveCalleeSaved(buf: var AsmBuffer, regs: seq[Reg], baseOffset: int32) =
  ## Save callee-saved registers to [SP, #baseOffset], [SP, #baseOffset+8], ...
  ## Uses STP (store pair) where possible.
  var idx = 0
  var off = baseOffset
  while idx + 1 < regs.len:
    buf.stpImm(regs[idx], regs[idx + 1], sp, off)
    off += 16
    idx += 2
  if idx < regs.len:
    buf.strImm(regs[idx], sp, off)

proc restoreCalleeSaved(buf: var AsmBuffer, regs: seq[Reg], baseOffset: int32) =
  ## Restore callee-saved registers from [SP, #baseOffset], [SP, #baseOffset+8], ...
  var idx = 0
  var off = baseOffset
  while idx + 1 < regs.len:
    buf.ldpImm(regs[idx], regs[idx + 1], sp, off)
    off += 16
    idx += 2
  if idx < regs.len:
    buf.ldrImm(regs[idx], sp, off)

# ---------------------------------------------------------------------------
# Block label tracking
# ---------------------------------------------------------------------------

type
  BlockLabel = object
    offset: int          # instruction index in AsmBuffer where block starts
    patchList: seq[int]  # positions of forward branches to patch

# ---------------------------------------------------------------------------
# Memory bounds check helper
# ---------------------------------------------------------------------------

# boundsCheckedFlag is imported from optimize.nim

proc emitBoundsCheck(buf: var AsmBuffer, addrReg: Reg, accessBytes: int32,
                     imm2: int32 = 0) =
  ## Emit a bounds check: if addrReg + accessBytes > memSize, trap.
  ## When -d:wasmGuardPages is set, the hardware guard pages handle the check
  ## and this becomes a no-op — the SIGSEGV/SIGBUS handler traps instead.
  ## When the BCE flag (boundsCheckedFlag) is set in imm2, a prior check in
  ## the same block already covers this access — skip the check entirely.
  ## Uses rTmp1 as scratch. Modifies flags.
  if (imm2 and boundsCheckedFlag) != 0:
    return  # bounds check eliminated by optimization pass
  when defined(wasmGuardPages):
    discard buf; discard addrReg; discard accessBytes
  else:
    # ADD rTmp1, addrReg, #accessBytes
    buf.addImm(rTmp1, addrReg, accessBytes.uint32)
    # CMP rTmp1, x11 (memSize)
    buf.cmpReg(rTmp1, rMemSize)
    # B.HI trap (unsigned above = carry set AND not zero)
    # Emit conditional branch over a BRK: B.LS +2, BRK
    buf.bCond(condLS, 2)  # skip over BRK if in bounds
    buf.brk(2)            # trap: out of bounds

# ---------------------------------------------------------------------------
# IR instruction emission
# ---------------------------------------------------------------------------

proc emitPhiResolution(buf: var AsmBuffer, f: IrFunc, alloc: RegAllocResult,
                       targetBb: int, sourceBb: int) =
  ## Emit MOV instructions to resolve phi nodes when branching to targetBb.
  ## Handles parallel copy semantics with cycle detection:
  ## - Non-conflicting moves are emitted directly
  ## - Cycles are broken using rTmp1 (x13) as a temporary
  if targetBb >= f.blocks.len:
    return
  let isBackEdge = sourceBb >= targetBb

  # Collect all needed moves as (dstReg, srcReg) pairs
  type RegMove = object
    dst, src: Reg
    dstVal: IrValue  # for spill handling
  var moves: seq[RegMove]

  for phi in f.blocks[targetBb].instrs:
    if phi.op != irPhi or phi.result < 0:
      continue
    let opIdx = if isBackEdge and phi.operands[1] >= 0: 1 else: 0
    let srcVal = phi.operands[opIdx]
    if srcVal < 0 or srcVal == phi.result:
      continue
    let dstReg = alloc.physReg(phi.result)
    let srcReg = alloc.physReg(srcVal)
    # Handle spilled sources: load to rTmp0 first
    if alloc.isSpilled(srcVal):
      let loaded = buf.loadOperand(alloc, srcVal, rTmp0)
      if dstReg != loaded:
        buf.movReg(dstReg, loaded)
      if alloc.isSpilled(phi.result):
        buf.storeResult(alloc, phi.result, dstReg)
      continue
    if dstReg == srcReg:
      continue  # already in the right register
    moves.add(RegMove(dst: dstReg, src: srcReg, dstVal: phi.result))

  if moves.len == 0:
    return

  # Resolve parallel copies with cycle detection.
  # Process moves where dst is NOT a source of another pending move first.
  # Then break remaining cycles with rTmp1 as temporary.
  var done = newSeq[bool](moves.len)
  var progress = true
  while progress:
    progress = false
    for i in 0 ..< moves.len:
      if done[i]: continue
      # Check if this move's dst would clobber a pending move's src
      var conflicts = false
      for j in 0 ..< moves.len:
        if j == i or done[j]: continue
        if moves[j].src == moves[i].dst:
          conflicts = true
          break
      if not conflicts:
        buf.movReg(moves[i].dst, moves[i].src)
        if alloc.isSpilled(moves[i].dstVal):
          buf.storeResult(alloc, moves[i].dstVal, moves[i].dst)
        done[i] = true
        progress = true

  # Handle remaining moves (cycles) using rTmp1 as temporary
  for i in 0 ..< moves.len:
    if done[i]: continue
    # Start of a cycle: save first src to rTmp1
    buf.movReg(rTmp1, moves[i].src)
    var cur = i
    done[cur] = true
    # Follow the chain
    while true:
      # Find the move whose src == moves[cur].dst
      var next = -1
      for j in 0 ..< moves.len:
        if not done[j] and moves[j].src == moves[cur].dst:
          next = j
          break
      if next < 0:
        # End of chain: moves[cur].dst gets its value from rTmp1
        buf.movReg(moves[cur].dst, rTmp1)
        if alloc.isSpilled(moves[cur].dstVal):
          buf.storeResult(alloc, moves[cur].dstVal, moves[cur].dst)
        break
      # Move next's src (which is cur's dst) to next's dst
      buf.movReg(moves[next].dst, moves[next].src)
      if alloc.isSpilled(moves[next].dstVal):
        buf.storeResult(alloc, moves[next].dstVal, moves[next].dst)
      done[next] = true
      cur = next

type ConstVal = tuple[known: bool, val: int64]

proc buildCodegenConstants(f: IrFunc): seq[ConstVal] =
  ## Scan all blocks for constant definitions.
  result = newSeq[ConstVal](f.numValues)
  for bb in f.blocks:
    for instr in bb.instrs:
      if instr.op in {irConst32, irConst64, irConstF32, irConstF64} and instr.result >= 0:
        result[instr.result.int] = (true, instr.imm)

proc emitCmp32(buf: var AsmBuffer, alloc: RegAllocResult, opA, opB: IrValue,
               constants: seq[ConstVal]) =
  ## Emit CMP with immediate form when second operand is a small constant.
  let a = buf.loadOperand(alloc, opA, rTmp0)
  if opB >= 0 and opB.int < constants.len and constants[opB.int].known:
    let c = constants[opB.int].val
    if c >= 0 and c <= 4095:
      buf.cmpImm(a, c.uint32, is64 = false)
      return
  let b = buf.loadOperand(alloc, opB, rTmp1)
  buf.cmpReg(a, b, is64 = false)

proc emitCmp64(buf: var AsmBuffer, alloc: RegAllocResult, opA, opB: IrValue,
               constants: seq[ConstVal]) =
  ## Emit 64-bit CMP with immediate form when second operand is a small constant.
  let a = buf.loadOperand(alloc, opA, rTmp0)
  if opB >= 0 and opB.int < constants.len and constants[opB.int].known:
    let c = constants[opB.int].val
    if c >= 0 and c <= 4095:
      buf.cmpImm(a, c.uint32, is64 = true)
      return
  let b = buf.loadOperand(alloc, opB, rTmp1)
  buf.cmpReg(a, b, is64 = true)

proc emitIrInstr(buf: var AsmBuffer, instr: IrInstr, alloc: RegAllocResult,
                 f: IrFunc, blockLabels: var seq[BlockLabel],
                 epiloguePatchList: var seq[int],
                 selfEntry: int, selfEntryInner: int, selfModuleIdx: int,
                 curBlockIdx: int,
                 constants: seq[ConstVal],
                 callIndirectCaches: seq[ptr CallIndirectCache],
                 callIndirectSiteIdx: var int,
                 funcElems: ptr UncheckedArray[TableElem],
                 numFuncs: int32,
                 relocSites: ptr seq[Relocation] = nil,
                 selfEntryReg: int = -1,
                 paramPhysRegs: seq[Reg] = @[],
                 selfEntryRegBranchList: ptr seq[int] = nil,
                 localsFullyPromoted: bool = false) =
  ## Emit AArch64 code for a single IR instruction using physical registers.
  let res = instr.result

  # Determine the destination register (or a scratch if spilled / no result)
  let dst =
    if res < 0: xzr
    elif alloc.isSpilled(res): rTmp0
    else: alloc.physReg(res)

  case instr.op

  # ---------- Constants ----------
  of irConst32:
    buf.loadImm32(dst, instr.imm.int32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irConst64:
    buf.loadImm64(dst, cast[uint64](instr.imm))
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  # ---------- i32 Arithmetic ----------
  of irAdd32:
    let op1 = instr.operands[1]
    if op1 >= 0 and op1.int < constants.len and constants[op1.int].known:
      let c = constants[op1.int].val
      if c >= 0 and c <= 4095:
        # Use immediate add: ADD Wd, Wn, #imm
        let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
        buf.addImm(dst, a, c.uint32, is64 = false)
        if res >= 0 and alloc.isSpilled(res):
          buf.storeResult(alloc, res, dst)
      else:
        let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
        let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
        buf.addReg(dst, a, b, is64 = false)
        if res >= 0 and alloc.isSpilled(res):
          buf.storeResult(alloc, res, dst)
    else:
      let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
      let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
      buf.addReg(dst, a, b, is64 = false)
      if res >= 0 and alloc.isSpilled(res):
        buf.storeResult(alloc, res, dst)

  of irSub32:
    let op1 = instr.operands[1]
    if op1 >= 0 and op1.int < constants.len and constants[op1.int].known:
      let c = constants[op1.int].val
      if c >= 0 and c <= 4095:
        # Use immediate sub: SUB Wd, Wn, #imm
        let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
        buf.subImm(dst, a, c.uint32, is64 = false)
        if res >= 0 and alloc.isSpilled(res):
          buf.storeResult(alloc, res, dst)
      else:
        let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
        let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
        buf.subReg(dst, a, b, is64 = false)
        if res >= 0 and alloc.isSpilled(res):
          buf.storeResult(alloc, res, dst)
    else:
      let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
      let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
      buf.subReg(dst, a, b, is64 = false)
      if res >= 0 and alloc.isSpilled(res):
        buf.storeResult(alloc, res, dst)

  of irMul32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.mulReg(dst, a, b, is64 = false)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irDiv32S:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.sdivReg(dst, a, b, is64 = false)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irDiv32U:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.udivReg(dst, a, b, is64 = false)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irRem32S:
    # WASM i32.rem_s = a - (a / b) * b  (SDIV + MSUB)
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.sdivReg(dst, a, b, is64 = false)     # dst = a / b
    buf.mulReg(dst, dst, b, is64 = false)     # dst = (a / b) * b
    buf.subReg(dst, a, dst, is64 = false)     # dst = a - (a / b) * b
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irRem32U:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.udivReg(dst, a, b, is64 = false)
    buf.mulReg(dst, dst, b, is64 = false)
    buf.subReg(dst, a, dst, is64 = false)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irAnd32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.andReg(dst, a, b, is64 = false)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irOr32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.orrReg(dst, a, b, is64 = false)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irXor32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.eorReg(dst, a, b, is64 = false)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irShl32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.lslReg(dst, a, b, is64 = false)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irShr32S:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.asrReg(dst, a, b, is64 = false)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irShr32U:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.lsrReg(dst, a, b, is64 = false)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irRotl32:
    # WASM rotl(a, b) = ROR(a, 32 - b) for 32-bit
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    # negate b: NEG Wd, Wb (SUB from zero)
    buf.subReg(rTmp1, xzr, b, is64 = false)
    buf.rorReg(dst, a, rTmp1, is64 = false)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irRotr32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.rorReg(dst, a, b, is64 = false)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irClz32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.clzReg(dst, a, is64 = false)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irCtz32:
    # CTZ via RBIT + CLZ
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.rbitReg(dst, a, is64 = false)
    buf.clzReg(dst, dst, is64 = false)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irPopcnt32:
    # AArch64 has no scalar POPCNT; use the NEON byte-count trick:
    #   FMOV S30, W_src      — move 32-bit integer into the low word of v30
    #   CNT  V30.8B, V30.8B  — count set bits in each of the 8 bytes
    #   ADDV B30, V30.8B     — horizontal add: sum all 8 byte counts
    #   UMOV W_dst, V30.B[0] — extract the scalar result (≤ 32, fits in 32-bit)
    # v30 is the reserved SIMD codegen scratch register.
    let a      = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let vScratch = FReg(30)
    buf.fmovGpToFp(vScratch, a, is64 = false)
    buf.cntVec8b(vScratch, vScratch)
    buf.addvVec8b(vScratch, vScratch)
    buf.umovB16b(dst, vScratch, 0)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irEqz32:
    # Result is 1 if operand == 0, else 0
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.cmpImm(a, 0, is64 = false)
    buf.csel(dst, xzr, xzr, condEQ, is64 = false)
    # csel gives us 0/0; we need 1 on EQ. Use CSINC instead:
    # CSINC Wd, WZR, WZR, NE => 1 if EQ, 0 if NE
    # Encoding: CSINC is sf|0|0|11010100|Rm|cond|0|1|Rn|Rd
    # = sf | 0x1A800400 | rm(Rm) | (cond shl 12) | rn(Rn) | rd(Rd)
    # Using Rm=WZR, Rn=WZR, cond=NE (inverted from the condition we want true)
    let sf = 0'u32  # 32-bit
    buf.code[buf.code.len - 1] = sf or 0x1A9F0400'u32 or
      (condNE.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  # ---------- i64 Arithmetic ----------
  of irAdd64:
    let op1 = instr.operands[1]
    if op1 >= 0 and op1.int < constants.len and constants[op1.int].known:
      let c = constants[op1.int].val
      if c >= 0 and c <= 4095:
        let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
        buf.addImm(dst, a, c.uint32, is64 = true)
        if res >= 0 and alloc.isSpilled(res):
          buf.storeResult(alloc, res, dst)
      else:
        let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
        let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
        buf.addReg(dst, a, b, is64 = true)
        if res >= 0 and alloc.isSpilled(res):
          buf.storeResult(alloc, res, dst)
    else:
      let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
      let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
      buf.addReg(dst, a, b, is64 = true)
      if res >= 0 and alloc.isSpilled(res):
        buf.storeResult(alloc, res, dst)

  of irSub64:
    let op1 = instr.operands[1]
    if op1 >= 0 and op1.int < constants.len and constants[op1.int].known:
      let c = constants[op1.int].val
      if c >= 0 and c <= 4095:
        let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
        buf.subImm(dst, a, c.uint32, is64 = true)
        if res >= 0 and alloc.isSpilled(res):
          buf.storeResult(alloc, res, dst)
      else:
        let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
        let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
        buf.subReg(dst, a, b, is64 = true)
        if res >= 0 and alloc.isSpilled(res):
          buf.storeResult(alloc, res, dst)
    else:
      let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
      let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
      buf.subReg(dst, a, b, is64 = true)
      if res >= 0 and alloc.isSpilled(res):
        buf.storeResult(alloc, res, dst)

  of irMul64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.mulReg(dst, a, b, is64 = true)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irDiv64S:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.sdivReg(dst, a, b, is64 = true)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irDiv64U:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.udivReg(dst, a, b, is64 = true)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irRem64S:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.sdivReg(dst, a, b, is64 = true)
    buf.mulReg(dst, dst, b, is64 = true)
    buf.subReg(dst, a, dst, is64 = true)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irRem64U:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.udivReg(dst, a, b, is64 = true)
    buf.mulReg(dst, dst, b, is64 = true)
    buf.subReg(dst, a, dst, is64 = true)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irAnd64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.andReg(dst, a, b, is64 = true)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irOr64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.orrReg(dst, a, b, is64 = true)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irXor64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.eorReg(dst, a, b, is64 = true)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irShl64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.lslReg(dst, a, b, is64 = true)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irShr64S:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.asrReg(dst, a, b, is64 = true)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irShr64U:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.lsrReg(dst, a, b, is64 = true)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irRotl64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.subReg(rTmp1, xzr, b, is64 = true)
    buf.rorReg(dst, a, rTmp1, is64 = true)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irRotr64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.rorReg(dst, a, b, is64 = true)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irClz64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.clzReg(dst, a, is64 = true)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irCtz64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.rbitReg(dst, a, is64 = true)
    buf.clzReg(dst, dst, is64 = true)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irPopcnt64:
    # Same NEON trick as irPopcnt32 but with FMOV Dn, Xn (64-bit move).
    #   FMOV D30, X_src      — move 64-bit integer into v30 (D-register form)
    #   CNT  V30.8B, V30.8B  — count set bits in each of the 8 bytes
    #   ADDV B30, V30.8B     — sum all 8 byte counts (≤ 64, fits in 8 bits)
    #   UMOV W_dst, V30.B[0] — extract 32-bit scalar result (64-bit i64.popcnt
    #                          spec says result is i64, but value fits in 32 bits)
    let a        = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let vScratch = FReg(30)
    buf.fmovGpToFp(vScratch, a, is64 = true)
    buf.cntVec8b(vScratch, vScratch)
    buf.addvVec8b(vScratch, vScratch)
    buf.umovB16b(dst, vScratch, 0)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irEqz64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.cmpImm(a, 0, is64 = true)
    # CSINC Wd, WZR, WZR, NE => 1 if EQ, 0 if NE (32-bit result)
    buf.emit(0x1A9F0400'u32 or
      (condNE.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  # ---------- i32 Comparisons (result is i32 0/1) ----------
  # All use emitCmp32 which generates CMP Wn, #imm when operand is a small constant
  of irEq32:
    buf.emitCmp32(alloc, instr.operands[0], instr.operands[1], constants)
    buf.emit(0x1A9F0400'u32 or (condNE.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res): buf.storeResult(alloc, res, dst)

  of irNe32:
    buf.emitCmp32(alloc, instr.operands[0], instr.operands[1], constants)
    buf.emit(0x1A9F0400'u32 or (condEQ.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res): buf.storeResult(alloc, res, dst)

  of irLt32S:
    buf.emitCmp32(alloc, instr.operands[0], instr.operands[1], constants)
    buf.emit(0x1A9F0400'u32 or (condGE.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res): buf.storeResult(alloc, res, dst)

  of irLt32U:
    buf.emitCmp32(alloc, instr.operands[0], instr.operands[1], constants)
    buf.emit(0x1A9F0400'u32 or (condCS.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res): buf.storeResult(alloc, res, dst)

  of irGt32S:
    buf.emitCmp32(alloc, instr.operands[0], instr.operands[1], constants)
    buf.emit(0x1A9F0400'u32 or (condLE.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res): buf.storeResult(alloc, res, dst)

  of irGt32U:
    buf.emitCmp32(alloc, instr.operands[0], instr.operands[1], constants)
    buf.emit(0x1A9F0400'u32 or (condLS.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res): buf.storeResult(alloc, res, dst)

  of irLe32S:
    buf.emitCmp32(alloc, instr.operands[0], instr.operands[1], constants)
    buf.emit(0x1A9F0400'u32 or (condGT.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res): buf.storeResult(alloc, res, dst)

  of irLe32U:
    buf.emitCmp32(alloc, instr.operands[0], instr.operands[1], constants)
    buf.emit(0x1A9F0400'u32 or (condHI.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res): buf.storeResult(alloc, res, dst)

  of irGe32S:
    buf.emitCmp32(alloc, instr.operands[0], instr.operands[1], constants)
    buf.emit(0x1A9F0400'u32 or (condLT.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res): buf.storeResult(alloc, res, dst)

  of irGe32U:
    buf.emitCmp32(alloc, instr.operands[0], instr.operands[1], constants)
    buf.emit(0x1A9F0400'u32 or (condCC.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res): buf.storeResult(alloc, res, dst)

  # ---------- i64 Comparisons (result is i32 0/1) ----------
  of irEq64:
    buf.emitCmp64(alloc, instr.operands[0], instr.operands[1], constants)
    buf.emit(0x1A9F0400'u32 or (condNE.uint32 shl 12) or
      (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irNe64:
    buf.emitCmp64(alloc, instr.operands[0], instr.operands[1], constants)
    buf.emit(0x1A9F0400'u32 or (condEQ.uint32 shl 12) or
      (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irLt64S:
    buf.emitCmp64(alloc, instr.operands[0], instr.operands[1], constants)
    buf.emit(0x1A9F0400'u32 or (condGE.uint32 shl 12) or
      (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irLt64U:
    buf.emitCmp64(alloc, instr.operands[0], instr.operands[1], constants)
    buf.emit(0x1A9F0400'u32 or (condCS.uint32 shl 12) or
      (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irGt64S:
    buf.emitCmp64(alloc, instr.operands[0], instr.operands[1], constants)
    buf.emit(0x1A9F0400'u32 or (condLE.uint32 shl 12) or
      (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irGt64U:
    buf.emitCmp64(alloc, instr.operands[0], instr.operands[1], constants)
    buf.emit(0x1A9F0400'u32 or (condLS.uint32 shl 12) or
      (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irLe64S:
    buf.emitCmp64(alloc, instr.operands[0], instr.operands[1], constants)
    buf.emit(0x1A9F0400'u32 or (condGT.uint32 shl 12) or
      (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irLe64U:
    buf.emitCmp64(alloc, instr.operands[0], instr.operands[1], constants)
    buf.emit(0x1A9F0400'u32 or (condHI.uint32 shl 12) or
      (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irGe64S:
    buf.emitCmp64(alloc, instr.operands[0], instr.operands[1], constants)
    buf.emit(0x1A9F0400'u32 or (condLT.uint32 shl 12) or
      (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irGe64U:
    buf.emitCmp64(alloc, instr.operands[0], instr.operands[1], constants)
    buf.emit(0x1A9F0400'u32 or (condCC.uint32 shl 12) or
      (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  # ---------- Conversions ----------
  of irWrapI64:
    # i64 -> i32: just move (upper 32 bits ignored in 32-bit ops)
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.movReg(dst, a, is64 = false)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irExtendI32S:
    # i32 -> i64 sign-extend
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.sxtwReg(dst, a)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irExtendI32U:
    # i32 -> i64 zero-extend: 32-bit MOV zeroes upper 32 bits
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.movReg(dst, a, is64 = false)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irExtend8S32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.sxtbReg(dst, a, is64 = false)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irExtend16S32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.sxthReg(dst, a, is64 = false)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irExtend8S64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.sxtbReg(dst, a, is64 = true)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irExtend16S64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.sxthReg(dst, a, is64 = true)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irExtend32S64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.sxtwReg(dst, a)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  # ---------- Memory loads ----------
  of irLoad32:
    # i32 load: compute effective address = memBase + wasmAddr + offset
    let addrVal = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let memOff = instr.imm2 and (not boundsCheckedFlag)
    # Effective address in rTmp0
    if memOff != 0:
      buf.addImm(rTmp0, addrVal, memOff.uint32)
    elif addrVal != rTmp0:
      buf.movReg(rTmp0, addrVal)
    emitBoundsCheck(buf, rTmp0, 4, instr.imm2)
    buf.addReg(rTmp0, rMemBase, rTmp0)  # absolute address
    buf.ldrImm(dst, rTmp0, 0, is64 = false)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irLoad64:
    let addrVal = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let memOff = instr.imm2 and (not boundsCheckedFlag)
    if memOff != 0:
      buf.addImm(rTmp0, addrVal, memOff.uint32)
    elif addrVal != rTmp0:
      buf.movReg(rTmp0, addrVal)
    emitBoundsCheck(buf, rTmp0, 8, instr.imm2)
    buf.addReg(rTmp0, rMemBase, rTmp0)
    buf.ldrImm(dst, rTmp0, 0, is64 = true)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irLoad8U:
    let addrVal = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let memOff = instr.imm2 and (not boundsCheckedFlag)
    if memOff != 0:
      buf.addImm(rTmp0, addrVal, memOff.uint32)
    elif addrVal != rTmp0:
      buf.movReg(rTmp0, addrVal)
    emitBoundsCheck(buf, rTmp0, 1, instr.imm2)
    buf.addReg(rTmp0, rMemBase, rTmp0)
    buf.ldrbImm(dst, rTmp0, 0)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irLoad8S:
    let addrVal = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let memOff = instr.imm2 and (not boundsCheckedFlag)
    if memOff != 0:
      buf.addImm(rTmp0, addrVal, memOff.uint32)
    elif addrVal != rTmp0:
      buf.movReg(rTmp0, addrVal)
    emitBoundsCheck(buf, rTmp0, 1, instr.imm2)
    buf.addReg(rTmp0, rMemBase, rTmp0)
    buf.ldrsbImm32(dst, rTmp0, 0)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irLoad16U:
    let addrVal = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let memOff = instr.imm2 and (not boundsCheckedFlag)
    if memOff != 0:
      buf.addImm(rTmp0, addrVal, memOff.uint32)
    elif addrVal != rTmp0:
      buf.movReg(rTmp0, addrVal)
    emitBoundsCheck(buf, rTmp0, 2, instr.imm2)
    buf.addReg(rTmp0, rMemBase, rTmp0)
    buf.ldrhImm(dst, rTmp0, 0)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irLoad16S:
    let addrVal = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let memOff = instr.imm2 and (not boundsCheckedFlag)
    if memOff != 0:
      buf.addImm(rTmp0, addrVal, memOff.uint32)
    elif addrVal != rTmp0:
      buf.movReg(rTmp0, addrVal)
    emitBoundsCheck(buf, rTmp0, 2, instr.imm2)
    buf.addReg(rTmp0, rMemBase, rTmp0)
    buf.ldrshImm32(dst, rTmp0, 0)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irLoad32U:
    # i64 <- zero-extended i32 load
    let addrVal = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let memOff = instr.imm2 and (not boundsCheckedFlag)
    if memOff != 0:
      buf.addImm(rTmp0, addrVal, memOff.uint32)
    elif addrVal != rTmp0:
      buf.movReg(rTmp0, addrVal)
    emitBoundsCheck(buf, rTmp0, 4, instr.imm2)
    buf.addReg(rTmp0, rMemBase, rTmp0)
    buf.ldrImm(dst, rTmp0, 0, is64 = false)  # zero-extends to 64-bit
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irLoad32S:
    # i64 <- sign-extended i32 load
    let addrVal = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let memOff = instr.imm2 and (not boundsCheckedFlag)
    if memOff != 0:
      buf.addImm(rTmp0, addrVal, memOff.uint32)
    elif addrVal != rTmp0:
      buf.movReg(rTmp0, addrVal)
    emitBoundsCheck(buf, rTmp0, 4, instr.imm2)
    buf.addReg(rTmp0, rMemBase, rTmp0)
    buf.ldrswImm(dst, rTmp0, 0)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  # ---------- Memory stores ----------
  of irStore32:
    let addrVal = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let val = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    let memOff = instr.imm2 and (not boundsCheckedFlag)
    if memOff != 0:
      buf.addImm(rTmp0, addrVal, memOff.uint32)
    elif addrVal != rTmp0:
      buf.movReg(rTmp0, addrVal)
    emitBoundsCheck(buf, rTmp0, 4, instr.imm2)
    buf.addReg(rTmp0, rMemBase, rTmp0)
    buf.strImm(val, rTmp0, 0, is64 = false)

  of irStore64:
    let addrVal = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let val = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    let memOff = instr.imm2 and (not boundsCheckedFlag)
    if memOff != 0:
      buf.addImm(rTmp0, addrVal, memOff.uint32)
    elif addrVal != rTmp0:
      buf.movReg(rTmp0, addrVal)
    emitBoundsCheck(buf, rTmp0, 8, instr.imm2)
    buf.addReg(rTmp0, rMemBase, rTmp0)
    buf.strImm(val, rTmp0, 0, is64 = true)

  of irStore8:
    let addrVal = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let val = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    let memOff = instr.imm2 and (not boundsCheckedFlag)
    if memOff != 0:
      buf.addImm(rTmp0, addrVal, memOff.uint32)
    elif addrVal != rTmp0:
      buf.movReg(rTmp0, addrVal)
    emitBoundsCheck(buf, rTmp0, 1, instr.imm2)
    buf.addReg(rTmp0, rMemBase, rTmp0)
    buf.strbImm(val, rTmp0, 0)

  of irStore16:
    let addrVal = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let val = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    let memOff = instr.imm2 and (not boundsCheckedFlag)
    if memOff != 0:
      buf.addImm(rTmp0, addrVal, memOff.uint32)
    elif addrVal != rTmp0:
      buf.movReg(rTmp0, addrVal)
    emitBoundsCheck(buf, rTmp0, 2, instr.imm2)
    buf.addReg(rTmp0, rMemBase, rTmp0)
    buf.strhImm(val, rTmp0, 0)

  of irStore32From64:
    # Store lower 32 bits of an i64 value
    let addrVal = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let val = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    let memOff = instr.imm2 and (not boundsCheckedFlag)
    if memOff != 0:
      buf.addImm(rTmp0, addrVal, memOff.uint32)
    elif addrVal != rTmp0:
      buf.movReg(rTmp0, addrVal)
    emitBoundsCheck(buf, rTmp0, 4, instr.imm2)
    buf.addReg(rTmp0, rMemBase, rTmp0)
    buf.strImm(val, rTmp0, 0, is64 = false)

  # ---------- Float constants ----------
  of irConstF32:
    # f32 bit pattern in lower 32 bits of imm
    buf.loadImm32(dst, instr.imm.int32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irConstF64:
    # f64 bit pattern in full 64-bit imm
    buf.loadImm64(dst, cast[uint64](instr.imm))
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  # ---------- Float arithmetic (f32) ----------
  of irAddF32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)  # FMOV S0, Wa
    buf.emit(0x1E270000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)  # FMOV S1, Wb
    buf.emit(0x1E202800'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)  # FADD S2, S0, S1
    buf.emit(0x1E260000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)  # FMOV Wd, S2
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irSubF32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E270000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    buf.emit(0x1E203800'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)
    buf.emit(0x1E260000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irMulF32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E270000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    buf.emit(0x1E200800'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)
    buf.emit(0x1E260000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irDivF32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E270000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    buf.emit(0x1E201800'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)
    buf.emit(0x1E260000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irAbsF32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E20C000'u32 or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)  # FABS S2, S0
    buf.emit(0x1E260000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irNegF32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E214000'u32 or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)  # FNEG S2, S0
    buf.emit(0x1E260000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irSqrtF32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E21C000'u32 or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)  # FSQRT S2, S0
    buf.emit(0x1E260000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irMinF32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E270000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    buf.emit(0x1E205800'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)  # FMIN S2, S0, S1
    buf.emit(0x1E260000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irMaxF32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E270000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    buf.emit(0x1E204800'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)  # FMAX S2, S0, S1
    buf.emit(0x1E260000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irCopysignF32:
    # Copysign: take magnitude from a, sign from b
    # Clear sign bit of a (AND with 0x7FFFFFFF), extract sign bit of b (AND with 0x80000000), OR them
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.loadImm32(dst, 0x7FFFFFFF'i32)
    buf.andReg(dst, a, dst, is64 = false)      # dst = a & 0x7FFFFFFF (magnitude)
    buf.loadImm32(rTmp0, cast[int32](0x80000000'u32))
    buf.andReg(rTmp0, b, rTmp0, is64 = false)  # rTmp0 = b & 0x80000000 (sign)
    buf.orrReg(dst, dst, rTmp0, is64 = false)   # dst = magnitude | sign
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irCeilF32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E24C000'u32 or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)  # FRINTP S2, S0
    buf.emit(0x1E260000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irFloorF32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E254000'u32 or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)  # FRINTM S2, S0
    buf.emit(0x1E260000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irTruncF32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E25C000'u32 or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)  # FRINTZ S2, S0
    buf.emit(0x1E260000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irNearestF32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E244000'u32 or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)  # FRINTN S2, S0
    buf.emit(0x1E260000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  # ---------- Fused multiply-add (f32) ----------
  # AArch64 FMA encoding (single precision):
  #   FMADD  Sd, Sn, Sm, Sa  = Sn*Sm + Sa   : 0x1F000000|(Sm<<16)|(Sa<<10)|(Sn<<5)|Sd
  #   FMSUB  Sd, Sn, Sm, Sa  = Sa - Sn*Sm   : 0x1F008000|(Sm<<16)|(Sa<<10)|(Sn<<5)|Sd
  #   FNMADD Sd, Sn, Sm, Sa  = -(Sn*Sm+Sa)  : 0x1F200000|(Sm<<16)|(Sa<<10)|(Sn<<5)|Sd
  #   FNMSUB Sd, Sn, Sm, Sa  = Sn*Sm-Sa     : 0x1F208000|(Sm<<16)|(Sa<<10)|(Sn<<5)|Sd
  # operands[0]=a(→Sn), operands[1]=b(→Sm), operands[2]=c(→Sa); result in d3
  # We load a→S0, b→S1, then reuse rTmp0 for c→S2 (a already safe in S0).

  of irFmaF32:
    # a*b + c
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)  # FMOV S0, Wa
    buf.emit(0x1E270000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)  # FMOV S1, Wb
    let c = buf.loadOperand(alloc, instr.operands[2], rTmp0)
    buf.emit(0x1E270000'u32 or (c.uint8.uint32 shl 5) or d2.uint8.uint32)  # FMOV S2, Wc
    buf.emit(0x1F000000'u32 or (d1.uint8.uint32 shl 16) or (d2.uint8.uint32 shl 10) or
             (d0.uint8.uint32 shl 5) or d3.uint8.uint32)                   # FMADD S3,S0,S1,S2
    buf.emit(0x1E260000'u32 or (d3.uint8.uint32 shl 5) or dst.uint8.uint32) # FMOV Wd, S3
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irFmsF32:
    # c - a*b
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E270000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    let c = buf.loadOperand(alloc, instr.operands[2], rTmp0)
    buf.emit(0x1E270000'u32 or (c.uint8.uint32 shl 5) or d2.uint8.uint32)
    buf.emit(0x1F008000'u32 or (d1.uint8.uint32 shl 16) or (d2.uint8.uint32 shl 10) or
             (d0.uint8.uint32 shl 5) or d3.uint8.uint32)                   # FMSUB S3,S0,S1,S2
    buf.emit(0x1E260000'u32 or (d3.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irFnmaF32:
    # -(a*b + c)
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E270000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    let c = buf.loadOperand(alloc, instr.operands[2], rTmp0)
    buf.emit(0x1E270000'u32 or (c.uint8.uint32 shl 5) or d2.uint8.uint32)
    buf.emit(0x1F200000'u32 or (d1.uint8.uint32 shl 16) or (d2.uint8.uint32 shl 10) or
             (d0.uint8.uint32 shl 5) or d3.uint8.uint32)                   # FNMADD S3,S0,S1,S2
    buf.emit(0x1E260000'u32 or (d3.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irFnmsF32:
    # a*b - c
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E270000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    let c = buf.loadOperand(alloc, instr.operands[2], rTmp0)
    buf.emit(0x1E270000'u32 or (c.uint8.uint32 shl 5) or d2.uint8.uint32)
    buf.emit(0x1F208000'u32 or (d1.uint8.uint32 shl 16) or (d2.uint8.uint32 shl 10) or
             (d0.uint8.uint32 shl 5) or d3.uint8.uint32)                   # FNMSUB S3,S0,S1,S2
    buf.emit(0x1E260000'u32 or (d3.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  # ---------- Float arithmetic (f64) ----------
  of irAddF64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)  # FMOV D0, Xa
    buf.emit(0x9E670000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)  # FMOV D1, Xb
    buf.emit(0x1E602800'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)  # FADD D2, D0, D1
    buf.emit(0x9E660000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)  # FMOV Xd, D2
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irSubF64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x9E670000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    buf.emit(0x1E603800'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)
    buf.emit(0x9E660000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irMulF64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x9E670000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    buf.emit(0x1E600800'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)
    buf.emit(0x9E660000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irDivF64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x9E670000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    buf.emit(0x1E601800'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)
    buf.emit(0x9E660000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irAbsF64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E60C000'u32 or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)
    buf.emit(0x9E660000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irNegF64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E614000'u32 or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)
    buf.emit(0x9E660000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irSqrtF64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E61C000'u32 or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)
    buf.emit(0x9E660000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irMinF64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x9E670000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    buf.emit(0x1E605800'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)
    buf.emit(0x9E660000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irMaxF64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x9E670000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    buf.emit(0x1E604800'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)
    buf.emit(0x9E660000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irCopysignF64:
    # Copysign: magnitude from a, sign from b (integer bit manipulation)
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    # Load 0x7FFFFFFFFFFFFFFF into dst
    buf.loadImm64(dst, 0x7FFFFFFFFFFFFFFF'u64)
    buf.andReg(dst, a, dst, is64 = true)       # dst = a & 0x7FFF... (magnitude)
    buf.loadImm64(rTmp0, 0x8000000000000000'u64)
    buf.andReg(rTmp0, b, rTmp0, is64 = true)   # rTmp0 = b & 0x8000... (sign)
    buf.orrReg(dst, dst, rTmp0, is64 = true)    # dst = magnitude | sign
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irCeilF64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E64C000'u32 or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)  # FRINTP D2, D0
    buf.emit(0x9E660000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irFloorF64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E654000'u32 or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)  # FRINTM D2, D0
    buf.emit(0x9E660000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irTruncF64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E65C000'u32 or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)  # FRINTZ D2, D0
    buf.emit(0x9E660000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irNearestF64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E644000'u32 or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)  # FRINTN D2, D0
    buf.emit(0x9E660000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  # ---------- Fused multiply-add (f64) ----------
  # AArch64 FMA encoding (double precision, type=01 → +0x00400000 over single):
  #   FMADD  Dd, Dn, Dm, Da  = Dn*Dm + Da   : 0x1F400000|(Dm<<16)|(Da<<10)|(Dn<<5)|Dd
  #   FMSUB  Dd, Dn, Dm, Da  = Da - Dn*Dm   : 0x1F408000|(Dm<<16)|(Da<<10)|(Dn<<5)|Dd
  #   FNMADD Dd, Dn, Dm, Da  = -(Dn*Dm+Da)  : 0x1F600000|(Dm<<16)|(Da<<10)|(Dn<<5)|Dd
  #   FNMSUB Dd, Dn, Dm, Da  = Dn*Dm-Da     : 0x1F608000|(Dm<<16)|(Da<<10)|(Dn<<5)|Dd

  of irFmaF64:
    # a*b + c
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)  # FMOV D0, Xa
    buf.emit(0x9E670000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)  # FMOV D1, Xb
    let c = buf.loadOperand(alloc, instr.operands[2], rTmp0)
    buf.emit(0x9E670000'u32 or (c.uint8.uint32 shl 5) or d2.uint8.uint32)  # FMOV D2, Xc
    buf.emit(0x1F400000'u32 or (d1.uint8.uint32 shl 16) or (d2.uint8.uint32 shl 10) or
             (d0.uint8.uint32 shl 5) or d3.uint8.uint32)                   # FMADD D3,D0,D1,D2
    buf.emit(0x9E660000'u32 or (d3.uint8.uint32 shl 5) or dst.uint8.uint32) # FMOV Xd, D3
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irFmsF64:
    # c - a*b
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x9E670000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    let c = buf.loadOperand(alloc, instr.operands[2], rTmp0)
    buf.emit(0x9E670000'u32 or (c.uint8.uint32 shl 5) or d2.uint8.uint32)
    buf.emit(0x1F408000'u32 or (d1.uint8.uint32 shl 16) or (d2.uint8.uint32 shl 10) or
             (d0.uint8.uint32 shl 5) or d3.uint8.uint32)                   # FMSUB D3,D0,D1,D2
    buf.emit(0x9E660000'u32 or (d3.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irFnmaF64:
    # -(a*b + c)
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x9E670000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    let c = buf.loadOperand(alloc, instr.operands[2], rTmp0)
    buf.emit(0x9E670000'u32 or (c.uint8.uint32 shl 5) or d2.uint8.uint32)
    buf.emit(0x1F600000'u32 or (d1.uint8.uint32 shl 16) or (d2.uint8.uint32 shl 10) or
             (d0.uint8.uint32 shl 5) or d3.uint8.uint32)                   # FNMADD D3,D0,D1,D2
    buf.emit(0x9E660000'u32 or (d3.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irFnmsF64:
    # a*b - c
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x9E670000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    let c = buf.loadOperand(alloc, instr.operands[2], rTmp0)
    buf.emit(0x9E670000'u32 or (c.uint8.uint32 shl 5) or d2.uint8.uint32)
    buf.emit(0x1F608000'u32 or (d1.uint8.uint32 shl 16) or (d2.uint8.uint32 shl 10) or
             (d0.uint8.uint32 shl 5) or d3.uint8.uint32)                   # FNMSUB D3,D0,D1,D2
    buf.emit(0x9E660000'u32 or (d3.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  # ---------- Float comparisons (result is i32 0/1) ----------
  of irEqF32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E270000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    buf.emit(0x1E202000'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5))  # FCMP S0, S1
    buf.emit(0x1A9F0400'u32 or (condNE.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)  # CSINC Wd, WZR, WZR, NE
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irNeF32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E270000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    buf.emit(0x1E202000'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5))
    buf.emit(0x1A9F0400'u32 or (condEQ.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)  # CSINC NE
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irLtF32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E270000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    buf.emit(0x1E202000'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5))
    buf.emit(0x1A9F0400'u32 or (condPL.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)  # CSINC MI
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irGtF32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E270000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    buf.emit(0x1E202000'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5))
    buf.emit(0x1A9F0400'u32 or (condLE.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)  # CSINC GT
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irLeF32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E270000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    buf.emit(0x1E202000'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5))
    buf.emit(0x1A9F0400'u32 or (condHI.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)  # CSINC LS
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irGeF32:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E270000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    buf.emit(0x1E202000'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5))
    buf.emit(0x1A9F0400'u32 or (condLT.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)  # CSINC GE
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irEqF64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x9E670000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    buf.emit(0x1E602000'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5))
    buf.emit(0x1A9F0400'u32 or (condNE.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irNeF64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x9E670000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    buf.emit(0x1E602000'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5))
    buf.emit(0x1A9F0400'u32 or (condEQ.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irLtF64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x9E670000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    buf.emit(0x1E602000'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5))
    buf.emit(0x1A9F0400'u32 or (condPL.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irGtF64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x9E670000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    buf.emit(0x1E602000'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5))
    buf.emit(0x1A9F0400'u32 or (condLE.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irLeF64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x9E670000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    buf.emit(0x1E602000'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5))
    buf.emit(0x1A9F0400'u32 or (condHI.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irGeF64:
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let b = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x9E670000'u32 or (b.uint8.uint32 shl 5) or d1.uint8.uint32)
    buf.emit(0x1E602000'u32 or (d1.uint8.uint32 shl 16) or (d0.uint8.uint32 shl 5))
    buf.emit(0x1A9F0400'u32 or (condLT.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  # ---------- Float conversions ----------
  of irF32ConvertI32S:
    # SCVTF Sd, Wn (i32 -> f32)
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x1E220000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E260000'u32 or (d0.uint8.uint32 shl 5) or dst.uint8.uint32)  # FMOV Wd, S0
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irF32ConvertI32U:
    # UCVTF Sd, Wn (u32 -> f32)
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x1E230000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E260000'u32 or (d0.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irF32ConvertI64S:
    # SCVTF Sd, Xn (i64 -> f32)
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x9E220000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E260000'u32 or (d0.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irF32ConvertI64U:
    # UCVTF Sd, Xn (u64 -> f32)
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x9E230000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E260000'u32 or (d0.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irF64ConvertI32S:
    # SCVTF Dd, Wn (i32 -> f64)
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x1E620000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x9E660000'u32 or (d0.uint8.uint32 shl 5) or dst.uint8.uint32)  # FMOV Xd, D0
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irF64ConvertI32U:
    # UCVTF Dd, Wn (u32 -> f64)
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x1E630000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x9E660000'u32 or (d0.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irF64ConvertI64S:
    # SCVTF Dd, Xn (i64 -> f64)
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x9E620000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x9E660000'u32 or (d0.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irF64ConvertI64U:
    # UCVTF Dd, Xn (u64 -> f64)
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x9E630000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x9E660000'u32 or (d0.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irF32DemoteF64:
    # FCVT Sd, Dn (f64 -> f32): GP->D0, demote to S0, S0->GP
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)   # FMOV D0, Xa
    buf.emit(0x1E624000'u32 or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)  # FCVT S2, D0
    buf.emit(0x1E260000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32) # FMOV Wd, S2
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irF64PromoteF32:
    # FCVT Dd, Sn (f32 -> f64): GP->S0, promote to D0, D0->GP
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)   # FMOV S0, Wa
    buf.emit(0x1E22C000'u32 or (d0.uint8.uint32 shl 5) or d2.uint8.uint32)  # FCVT D2, S0
    buf.emit(0x9E660000'u32 or (d2.uint8.uint32 shl 5) or dst.uint8.uint32) # FMOV Xd, D2
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irI32TruncF32S:
    # FCVTZS Wn, Sd (f32 -> i32 signed)
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E380000'u32 or (d0.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irI32TruncF32U:
    # FCVTZU Wn, Sd (f32 -> u32)
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E390000'u32 or (d0.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irI32TruncF64S:
    # FCVTZS Wn, Dd (f64 -> i32 signed)
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E780000'u32 or (d0.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irI32TruncF64U:
    # FCVTZU Wn, Dd (f64 -> u32)
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x1E790000'u32 or (d0.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irI64TruncF32S:
    # FCVTZS Xn, Sd (f32 -> i64 signed)
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x9E380000'u32 or (d0.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irI64TruncF32U:
    # FCVTZU Xn, Sd (f32 -> u64)
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x1E270000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x9E390000'u32 or (d0.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irI64TruncF64S:
    # FCVTZS Xn, Dd (f64 -> i64 signed)
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x9E780000'u32 or (d0.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irI64TruncF64U:
    # FCVTZU Xn, Dd (f64 -> u64)
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.emit(0x9E670000'u32 or (a.uint8.uint32 shl 5) or d0.uint8.uint32)
    buf.emit(0x9E790000'u32 or (d0.uint8.uint32 shl 5) or dst.uint8.uint32)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irI32ReinterpretF32, irF32ReinterpretI32:
    # NOPs: floats stored as bit patterns in integer registers
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    if dst != a:
      buf.movReg(dst, a, is64 = false)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irI64ReinterpretF64, irF64ReinterpretI64:
    # NOPs: floats stored as bit patterns in integer registers
    let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    if dst != a:
      buf.movReg(dst, a)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  # ---------- Float memory ----------
  of irLoadF32:
    # Load f32 from memory as 32-bit value into GP register
    let addrVal = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let memOff = instr.imm2 and (not boundsCheckedFlag)
    if memOff != 0:
      buf.addImm(rTmp0, addrVal, memOff.uint32)
    elif addrVal != rTmp0:
      buf.movReg(rTmp0, addrVal)
    emitBoundsCheck(buf, rTmp0, 4, instr.imm2)
    buf.addReg(rTmp0, rMemBase, rTmp0)
    buf.ldrImm(dst, rTmp0, 0, is64 = false)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irLoadF64:
    # Load f64 from memory as 64-bit value into GP register
    let addrVal = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let memOff = instr.imm2 and (not boundsCheckedFlag)
    if memOff != 0:
      buf.addImm(rTmp0, addrVal, memOff.uint32)
    elif addrVal != rTmp0:
      buf.movReg(rTmp0, addrVal)
    emitBoundsCheck(buf, rTmp0, 8, instr.imm2)
    buf.addReg(rTmp0, rMemBase, rTmp0)
    buf.ldrImm(dst, rTmp0, 0, is64 = true)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irStoreF32:
    let addrVal = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let val = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    let memOff = instr.imm2 and (not boundsCheckedFlag)
    if memOff != 0:
      buf.addImm(rTmp0, addrVal, memOff.uint32)
    elif addrVal != rTmp0:
      buf.movReg(rTmp0, addrVal)
    emitBoundsCheck(buf, rTmp0, 4, instr.imm2)
    buf.addReg(rTmp0, rMemBase, rTmp0)
    buf.strImm(val, rTmp0, 0, is64 = false)

  of irStoreF64:
    let addrVal = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let val = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    let memOff = instr.imm2 and (not boundsCheckedFlag)
    if memOff != 0:
      buf.addImm(rTmp0, addrVal, memOff.uint32)
    elif addrVal != rTmp0:
      buf.movReg(rTmp0, addrVal)
    emitBoundsCheck(buf, rTmp0, 8, instr.imm2)
    buf.addReg(rTmp0, rMemBase, rTmp0)
    buf.strImm(val, rTmp0, 0, is64 = true)

  # ---------- Variables ----------
  of irParam:
    # Load parameter from locals array: LDR Xdst, [X9, #idx*8]
    let idx = instr.imm.int32
    buf.ldrImm(dst, rLocals, idx * 8)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irLocalGet:
    # Same as param -- locals share the locals array
    let idx = instr.imm.int32
    buf.ldrImm(dst, rLocals, idx * 8)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irLocalSet:
    # Store to locals array: STR Xsrc, [X9, #idx*8]
    let idx = instr.imm.int32
    let val = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    buf.strImm(val, rLocals, idx * 8)

  # ---------- Control flow ----------
  of irBr:
    # Unconditional branch to block `imm`
    let targetBb = instr.imm.int
    # Resolve phi nodes at target before branching
    buf.emitPhiResolution(f, alloc, targetBb, curBlockIdx)
    if targetBb < blockLabels.len and blockLabels[targetBb].offset >= 0:
      let targetOff = blockLabels[targetBb].offset - buf.pos
      buf.b(targetOff.int32)
    else:
      # Forward reference -- emit placeholder, patch later
      if targetBb >= blockLabels.len:
        blockLabels.setLen(targetBb + 1)
      blockLabels[targetBb].patchList.add(buf.pos)
      buf.b(0)  # placeholder

  of irBrIf:
    # Conditional branch: if operands[0] != 0, branch to block `imm`
    # False path branches to block `imm2`
    let cond = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    var targetBb = instr.imm.int

    # Trampoline bypass: if the target block is a BACK-EDGE trampoline
    # (single irBr to a lower-numbered block) and all phi resolution moves
    # would be self-moves (coalesced), redirect the branch directly to the
    # loop header. DON'T bypass preheader pass-throughs (forward edges) —
    # those need phi resolution to set initial values.
    if targetBb >= 0 and targetBb < f.blocks.len and
       f.blocks[targetBb].instrs.len == 1 and
       f.blocks[targetBb].instrs[0].op == irBr and
       f.blocks[targetBb].instrs[0].imm.int <= targetBb:  # back-edge only
      let trampolineTarget = f.blocks[targetBb].instrs[0].imm.int
      # Check if all phi moves would be self-moves
      var allCoalesced = true
      if trampolineTarget >= 0 and trampolineTarget < f.blocks.len:
        for phi in f.blocks[trampolineTarget].instrs:
          if phi.op != irPhi: continue
          if phi.result < 0: continue
          let opIdx = 1  # back-edge
          let srcVal = phi.operands[opIdx]
          if srcVal < 0 or srcVal == phi.result: continue
          let dstReg = alloc.physReg(phi.result)
          let srcReg = alloc.physReg(srcVal)
          if dstReg != srcReg or alloc.isSpilled(phi.result) or alloc.isSpilled(srcVal):
            allCoalesced = false
            break
        if allCoalesced:
          targetBb = trampolineTarget  # bypass trampoline!
    if targetBb < blockLabels.len and blockLabels[targetBb].offset >= 0:
      let targetOff = blockLabels[targetBb].offset - buf.pos
      buf.cbnz(cond, targetOff.int32, is64 = false)
    else:
      if targetBb >= blockLabels.len:
        blockLabels.setLen(targetBb + 1)
      blockLabels[targetBb].patchList.add(buf.pos)
      buf.cbnz(cond, 0, is64 = false)  # placeholder
    # Explicit branch for the false path
    let falseBb = instr.imm2.int
    if falseBb > 0:
      if falseBb < blockLabels.len and blockLabels[falseBb].offset >= 0:
        let falseOff = blockLabels[falseBb].offset - buf.pos
        buf.b(falseOff.int32)
      else:
        if falseBb >= blockLabels.len:
          blockLabels.setLen(falseBb + 1)
        blockLabels[falseBb].patchList.add(buf.pos)
        buf.b(0)  # placeholder

  of irReturn:
    if selfModuleIdx >= 0:
      # Self-recursive function: external wrapper handles STR + MOV x0.
      # irReturn only sets x15 sidecar for self-callers, then branches to epilogue.
      if instr.operands[0] >= 0:
        let val = buf.loadOperand(alloc, instr.operands[0], rTmp0)
        if val != rScratch3:
          buf.movReg(rScratch3, val)  # x15 = return value (sidecar)
    else:
      # Non-recursive function: full ABI (STR to value stack + MOV x0)
      if instr.operands[0] >= 0:
        let val = buf.loadOperand(alloc, instr.operands[0], rTmp0)
        # STR val, [x8], #8 (post-index: store then advance VSP by 8)
        let imm9 = 8'u32 and 0x1FF
        buf.emit(0xF8000400'u32 or (imm9 shl 12) or (rVSP.uint8.uint32 shl 5) or val.uint8.uint32)
        buf.movReg(x0, rVSP)
        if val != rScratch3:
          buf.movReg(rScratch3, val)
      else:
        buf.movReg(x0, rVSP)
    # Branch to epilogue (patched after all blocks are emitted)
    epiloguePatchList.add(buf.pos)
    buf.b(0)  # placeholder — patched to epilogue offset

  of irSelect:
    # select(cond, a, b): if cond != 0 then a else b
    let condVal = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let a = buf.loadOperand(alloc, instr.operands[1], rTmp1)
    # operands[2] needs a register; use rScratch2 if available
    let bScratch = rScratch2  # x14
    let b = buf.loadOperand(alloc, instr.operands[2], bScratch)
    buf.cmpImm(condVal, 0, is64 = false)
    buf.csel(dst, a, b, condNE, is64 = true)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irPhi:
    # Phi resolution happens at branch sites (irBr), not here.
    # The phi itself is a no-op in the generated code.
    discard

  of irNop:
    if instr.operands[0] >= 0 and res >= 0:
      let src = buf.loadOperand(alloc, instr.operands[0], rTmp0)
      if dst != src:
        buf.movReg(dst, src)
      if alloc.isSpilled(res):
        buf.storeResult(alloc, res, dst)
    else:
      buf.nop()

  of irTrap:
    buf.brk(1)

  # ---------- SIMD v128 ----------

  of irLoadV128:
    # v128.load: load 16 bytes from WASM memory at address (operands[0] + imm2)
    let addrVal = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let memOff = instr.imm2 and (not boundsCheckedFlag)
    if memOff != 0:
      buf.addImm(rTmp0, addrVal, memOff.uint32)
    elif addrVal != rTmp0:
      buf.movReg(rTmp0, addrVal)
    buf.emitBoundsCheck(rTmp0, 16, instr.imm2)
    buf.addReg(rTmp0, rMemBase, rTmp0)
    let vdst = if res >= 0 and not alloc.isSpilled(res):
      alloc.physSimdReg(res)
    else:
      fSimdScratch0
    buf.ld1q(vdst, rTmp0)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeSimdResult(alloc, res, vdst)

  of irStoreV128:
    # v128.store: store 16 bytes to WASM memory
    let addrVal = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let memOff = instr.imm2 and (not boundsCheckedFlag)
    if memOff != 0:
      buf.addImm(rTmp0, addrVal, memOff.uint32)
    elif addrVal != rTmp0:
      buf.movReg(rTmp0, addrVal)
    buf.emitBoundsCheck(rTmp0, 16, instr.imm2)
    buf.addReg(rTmp0, rMemBase, rTmp0)
    let vsrc = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch0)
    buf.st1q(vsrc, rTmp0)

  of irConstV128:
    # v128.const: materialize a 128-bit constant
    let vdst = if res >= 0 and not alloc.isSpilled(res):
      alloc.physSimdReg(res)
    else:
      fSimdScratch0
    let idx = instr.imm.int
    if idx < f.v128Consts.len:
      buf.emitV128Const(vdst, f.v128Consts[idx])
    if res >= 0 and alloc.isSpilled(res):
      buf.storeSimdResult(alloc, res, vdst)

  of irI32x4Splat:
    # i32x4.splat: broadcast an i32 to all 4 lanes
    let src = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let vdst = if res >= 0 and not alloc.isSpilled(res):
      alloc.physSimdReg(res)
    else:
      fSimdScratch0
    buf.dupVec4s(vdst, src)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeSimdResult(alloc, res, vdst)

  of irF32x4Splat:
    # f32x4.splat: broadcast an f32 (stored as i32 bits in GP) to all 4 lanes
    let src = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let vdst = if res >= 0 and not alloc.isSpilled(res):
      alloc.physSimdReg(res)
    else:
      fSimdScratch0
    buf.dupVec4s(vdst, src)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeSimdResult(alloc, res, vdst)

  of irI32x4ExtractLane:
    # i32x4.extract_lane: extract lane as i32 (raw 32 bits, zero-extends to 64-bit in GP)
    let vsrc = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let lane = instr.imm.int
    buf.umovW(dst, vsrc, lane)  # UMOV Wd, Vn.S[lane] — zero-extends to 64-bit
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irI32x4ReplaceLane:
    # i32x4.replace_lane: copy vector, insert new value at lane
    let vsrc = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let newVal = buf.loadOperand(alloc, instr.operands[1], rTmp0)
    let lane = instr.imm.int
    let vdst = if res >= 0 and not alloc.isSpilled(res):
      alloc.physSimdReg(res)
    else:
      fSimdScratch1
    if vdst != vsrc:
      buf.movVec(vdst, vsrc)
    buf.insVec4sFromW(vdst, lane, newVal)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeSimdResult(alloc, res, vdst)

  of irF32x4ExtractLane:
    # f32x4.extract_lane: extract lane as f32 bits (into GP register)
    let vsrc = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let lane = instr.imm.int
    buf.umovW(dst, vsrc, lane)  # UMOV Wd, Vn.S[lane]
    if res >= 0 and alloc.isSpilled(res):
      buf.storeResult(alloc, res, dst)

  of irF32x4ReplaceLane:
    # f32x4.replace_lane: copy vector, insert f32 bits at lane
    let vsrc = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let newVal = buf.loadOperand(alloc, instr.operands[1], rTmp0)
    let lane = instr.imm.int
    let vdst = if res >= 0 and not alloc.isSpilled(res):
      alloc.physSimdReg(res)
    else:
      fSimdScratch1
    if vdst != vsrc:
      buf.movVec(vdst, vsrc)
    buf.insVec4sFromW(vdst, lane, newVal)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeSimdResult(alloc, res, vdst)

  of irV128Not:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vdst = if res >= 0 and not alloc.isSpilled(res):
      alloc.physSimdReg(res)
    else:
      fSimdScratch1
    buf.notVec(vdst, va)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeSimdResult(alloc, res, vdst)

  of irV128And:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res):
      alloc.physSimdReg(res)
    else:
      fSimdScratch0
    buf.andVec(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeSimdResult(alloc, res, vdst)

  of irV128Or:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res):
      alloc.physSimdReg(res)
    else:
      fSimdScratch0
    buf.orrVec(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeSimdResult(alloc, res, vdst)

  of irV128Xor:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res):
      alloc.physSimdReg(res)
    else:
      fSimdScratch0
    buf.eorVec(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeSimdResult(alloc, res, vdst)

  of irI32x4Add:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res):
      alloc.physSimdReg(res)
    else:
      fSimdScratch0
    buf.addVec4s(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeSimdResult(alloc, res, vdst)

  of irI32x4Sub:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res):
      alloc.physSimdReg(res)
    else:
      fSimdScratch0
    buf.subVec4s(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeSimdResult(alloc, res, vdst)

  of irI32x4Mul:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res):
      alloc.physSimdReg(res)
    else:
      fSimdScratch0
    buf.mulVec4s(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeSimdResult(alloc, res, vdst)

  of irF32x4Add:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res):
      alloc.physSimdReg(res)
    else:
      fSimdScratch0
    buf.faddVec4s(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeSimdResult(alloc, res, vdst)

  of irF32x4Sub:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res):
      alloc.physSimdReg(res)
    else:
      fSimdScratch0
    buf.fsubVec4s(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeSimdResult(alloc, res, vdst)

  of irF32x4Mul:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res):
      alloc.physSimdReg(res)
    else:
      fSimdScratch0
    buf.fmulVec4s(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeSimdResult(alloc, res, vdst)

  of irF32x4Div:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res):
      alloc.physSimdReg(res)
    else:
      fSimdScratch0
    buf.fdivVec4s(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res):
      buf.storeSimdResult(alloc, res, vdst)

  # ---- Extended SIMD: splats ----

  of irI8x16Splat:
    let src = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.dupVec16b(vdst, src)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irI16x8Splat:
    let src = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.dupVec8h(vdst, src)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irI64x2Splat, irF64x2Splat:
    # Scalar is i64 / f64 bits — use X register (same physical register as GP)
    let src = buf.loadOperand(alloc, instr.operands[0], rTmp0)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.dupVec2d(vdst, src)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  # ---- i8x16 lane ops ----

  of irI8x16ExtractLaneS:
    let vsrc = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let lane = instr.imm.int
    buf.smovX16b(dst, vsrc, lane)  # SMOV Xd, Vn.B[lane] — sign-extend to 64-bit
    if res >= 0 and alloc.isSpilled(res): buf.storeResult(alloc, res, dst)

  of irI8x16ExtractLaneU:
    let vsrc = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let lane = instr.imm.int
    buf.umovB16b(dst, vsrc, lane)  # UMOV Wd, Vn.B[lane] — zero-extend
    if res >= 0 and alloc.isSpilled(res): buf.storeResult(alloc, res, dst)

  of irI8x16ReplaceLane:
    let vsrc = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let newVal = buf.loadOperand(alloc, instr.operands[1], rTmp0)
    let lane = instr.imm.int
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch1
    if vdst != vsrc: buf.movVec(vdst, vsrc)
    buf.insVec16bFromW(vdst, lane, newVal)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  # ---- i16x8 lane ops ----

  of irI16x8ExtractLaneS:
    let vsrc = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let lane = instr.imm.int
    buf.smovX8h(dst, vsrc, lane)  # SMOV Xd, Vn.H[lane] — sign-extend to 64-bit
    if res >= 0 and alloc.isSpilled(res): buf.storeResult(alloc, res, dst)

  of irI16x8ExtractLaneU:
    let vsrc = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let lane = instr.imm.int
    buf.umovH8h(dst, vsrc, lane)  # UMOV Wd, Vn.H[lane] — zero-extend
    if res >= 0 and alloc.isSpilled(res): buf.storeResult(alloc, res, dst)

  of irI16x8ReplaceLane:
    let vsrc = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let newVal = buf.loadOperand(alloc, instr.operands[1], rTmp0)
    let lane = instr.imm.int
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch1
    if vdst != vsrc: buf.movVec(vdst, vsrc)
    buf.insVec8hFromW(vdst, lane, newVal)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  # ---- i64x2 lane ops ----

  of irI64x2ExtractLane, irF64x2ExtractLane:
    let vsrc = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let lane = instr.imm.int
    buf.umovX2d(dst, vsrc, lane)  # UMOV Xd, Vn.D[lane]
    if res >= 0 and alloc.isSpilled(res): buf.storeResult(alloc, res, dst)

  of irI64x2ReplaceLane, irF64x2ReplaceLane:
    let vsrc = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let newVal = buf.loadOperand(alloc, instr.operands[1], rTmp0)
    let lane = instr.imm.int
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch1
    if vdst != vsrc: buf.movVec(vdst, vsrc)
    buf.insVec2dFromX(vdst, lane, newVal)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  # ---- v128 bitwise extensions ----

  of irV128AndNot:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.bicVec(vdst, va, vb)  # BIC: dst = va & ~vb
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  # ---- i8x16 arithmetic ----

  of irI8x16Abs:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch1
    buf.absVec16b(vdst, va)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irI8x16Neg:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch1
    buf.negVec16b(vdst, va)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irI8x16Add:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.addVec16b(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irI8x16Sub:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.subVec16b(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irI8x16MinS:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.sminVec16b(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irI8x16MinU:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.uminVec16b(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irI8x16MaxS:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.smaxVec16b(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irI8x16MaxU:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.umaxVec16b(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  # ---- i16x8 arithmetic ----

  of irI16x8Abs:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch1
    buf.absVec8h(vdst, va)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irI16x8Neg:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch1
    buf.negVec8h(vdst, va)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irI16x8Add:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.addVec8h(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irI16x8Sub:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.subVec8h(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irI16x8Mul:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.mulVec8h(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  # ---- i32x4 extensions ----

  of irI32x4Abs:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch1
    buf.absVec4s(vdst, va)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irI32x4Neg:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch1
    buf.negVec4s(vdst, va)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irI32x4Shl:
    # WASM: shift all 4 lanes left by (scalar & 31)
    # AArch64: mask count, DUP to vec, SSHL (positive=left shift)
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let cnt = buf.loadOperand(alloc, instr.operands[1], rTmp0)
    buf.movz(rTmp1, 31, 0, false)          # rTmp1 = 31
    buf.andReg(rTmp0, cnt, rTmp1, false)   # rTmp0 = cnt & 31 (32-bit)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch1
    buf.dupVec4s(vdst, rTmp0)              # broadcast masked count to 4S
    buf.sshlVec4s(vdst, va, vdst)          # SSHL (positive = left shift)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irI32x4ShrS:
    # WASM: arithmetic right shift by (scalar & 31)
    # AArch64: mask count, negate, SSHL with negative = right arith shift
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let cnt = buf.loadOperand(alloc, instr.operands[1], rTmp0)
    buf.movz(rTmp1, 31, 0, false)
    buf.andReg(rTmp0, cnt, rTmp1, false)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch1
    buf.dupVec4s(vdst, rTmp0)
    buf.negVec4s(vdst, vdst)               # negate → SSHL with negative = right arith shift
    buf.sshlVec4s(vdst, va, vdst)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irI32x4ShrU:
    # WASM: logical right shift by (scalar & 31)
    # AArch64: mask, negate, USHL with negative = right logical shift
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let cnt = buf.loadOperand(alloc, instr.operands[1], rTmp0)
    buf.movz(rTmp1, 31, 0, false)
    buf.andReg(rTmp0, cnt, rTmp1, false)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch1
    buf.dupVec4s(vdst, rTmp0)
    buf.negVec4s(vdst, vdst)               # negate → USHL with negative = right logical shift
    buf.ushlVec4s(vdst, va, vdst)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irI32x4MinS:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.sminVec4s(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irI32x4MinU:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.uminVec4s(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irI32x4MaxS:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.smaxVec4s(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irI32x4MaxU:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.umaxVec4s(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  # ---- i64x2 arithmetic ----

  of irI64x2Add:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.addVec2d(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irI64x2Sub:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.subVec2d(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  # ---- f32x4 unary ----

  of irF32x4Abs:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch1
    buf.fabsVec4s(vdst, va)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irF32x4Neg:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch1
    buf.fnegVec4s(vdst, va)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  # ---- f64x2 arithmetic ----

  of irF64x2Add:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.faddVec2d(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irF64x2Sub:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.fsubVec2d(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irF64x2Mul:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.fmulVec2d(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irF64x2Div:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vb = buf.loadSimdOperand(alloc, instr.operands[1], fSimdScratch1)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch0
    buf.fdivVec2d(vdst, va, vb)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irF64x2Abs:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch1
    buf.fabsVec2d(vdst, va)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irF64x2Neg:
    let va = buf.loadSimdOperand(alloc, instr.operands[0], fSimdScratch0)
    let vdst = if res >= 0 and not alloc.isSpilled(res): alloc.physSimdReg(res)
               else: fSimdScratch1
    buf.fnegVec2d(vdst, va)
    if res >= 0 and alloc.isSpilled(res): buf.storeSimdResult(alloc, res, vdst)

  of irCall:
    let calleeIdx = instr.imm.int
    if calleeIdx == selfModuleIdx and selfEntry >= 0:
      # Self-recursive call — heavily optimized
      let usesMem = f.usesMemory
      # Locals size (must hold ALL locals, not just params)
      let localsBytes = ((f.numLocals * 8 + 15) and (not 15))

      if not usesMem and localsBytes + 16 <= 504:
        # Fast path (non-memory function, small frame).
        if localsFullyPromoted and paramPhysRegs.len > 0:
          # Ultra-fast path: x8 (rVSP) is unused in Tier 2 body, x9 (rLocals)
          # is unused when all locals are register-promoted. The callee (via
          # selfEntryReg) never modifies x8 or x9, so no save/restore is needed.
          # Just set arg registers and BL — zero frame overhead at call site.
          let passRegs = [Reg(4), Reg(5)]
          for i in 0 ..< min(f.numParams, paramPhysRegs.len):
            let opIdx = f.numParams - 1 - i
            if instr.operands[opIdx] >= 0:
              let arg = buf.loadOperand(alloc, instr.operands[opIdx], rTmp0)
              if arg != passRegs[i]:
                buf.movReg(passRegs[i], arg)
          if selfEntryRegBranchList != nil:
            selfEntryRegBranchList[].add(buf.pos)
          buf.bl(0)  # placeholder — patched to selfEntryReg later
          # Result in x15 (sidecar) — no dependent-load chain through rVSP.
          if res >= 0:
            if dst != rScratch3:
              buf.movReg(dst, rScratch3)
            if alloc.isSpilled(res):
              buf.storeResult(alloc, res, dst)
        elif paramPhysRegs.len > 0:
          # Register-based param passing with STP x8,x9 frame.
          # Merge SUB SP + STP x8,x9 into a single STP with a larger pre-index,
          # saving one instruction and one level of SP-chain latency.
          # Frame layout: [SP+0..SP+15] = saved x8,x9 ; [SP+16..] = callee locals.
          let totalAlloc = localsBytes + 16
          buf.stpPreIdx(rVSP, rLocals, sp, -totalAlloc.int32)   # save x8,x9; alloc frame
          # Move args directly to param registers in x4/x5.
          let passRegs = [Reg(4), Reg(5)]
          for i in 0 ..< min(f.numParams, paramPhysRegs.len):
            let opIdx = f.numParams - 1 - i
            if instr.operands[opIdx] >= 0:
              let arg = buf.loadOperand(alloc, instr.operands[opIdx], rTmp0)
              if arg != passRegs[i]:
                buf.movReg(passRegs[i], arg)
          buf.addImm(x1, sp, 16'u32)                        # x1 = SP+16 = callee locals
          if selfEntryRegBranchList != nil:
            selfEntryRegBranchList[].add(buf.pos)
          buf.bl(0)  # placeholder
          buf.ldpPostIdx(rVSP, rLocals, sp, totalAlloc.int32)
          # Result in x15 (sidecar) — no dependent-load chain through rVSP.
          if res >= 0:
            if dst != rScratch3:
              buf.movReg(dst, rScratch3)
            if alloc.isSpilled(res):
              buf.storeResult(alloc, res, dst)
        else:
          # Original path: write args to callee locals on stack, enter at selfEntryInner
          let totalAlloc = localsBytes + 16
          buf.stpPreIdx(rVSP, rLocals, sp, -totalAlloc.int32)   # save x8,x9; alloc frame
          # operands[] is in reverse stack order: local[i] gets operands[numParams-1-i].
          for i in 0 ..< min(f.numParams, 3):
            let opIdx = f.numParams - 1 - i
            if instr.operands[opIdx] >= 0:
              let arg = buf.loadOperand(alloc, instr.operands[opIdx], rTmp0)
              buf.strImm(arg, sp, (16 + i * 8).int32)         # locals above saved regs
          # x8 (rVSP) is unchanged after STP — callee reads it directly at selfEntryInner.
          buf.addImm(x1, sp, 16'u32)                          # x1 = SP+16 = callee locals
          let offset = selfEntryInner - buf.pos
          buf.bl(offset.int32)
          buf.ldpPostIdx(rVSP, rLocals, sp, totalAlloc.int32)
          # Result in x15 (sidecar) — no dependent-load chain through rVSP.
          if res >= 0:
            if dst != rScratch3:
              buf.movReg(dst, rScratch3)
            if alloc.isSpilled(res):
              buf.storeResult(alloc, res, dst)
      else:
        # Fallback: original sequence for memory functions or oversized frames.
        # operands[] is in reverse stack order: local[i] gets operands[numParams-1-i].
        if localsBytes > 0:
          buf.subImm(sp, sp, localsBytes.uint32)
        for i in 0 ..< min(f.numParams, 3):
          let opIdx = f.numParams - 1 - i
          if instr.operands[opIdx] >= 0:
            let arg = buf.loadOperand(alloc, instr.operands[opIdx], rTmp0)
            buf.strImm(arg, sp, (i * 8).int32)
        buf.stpPreIdx(rVSP, rLocals, sp, -16)
        var savedBytes = 16
        if usesMem:
          buf.stpPreIdx(rMemBase, rMemSize, sp, -16)
          savedBytes += 16
        # x8 (rVSP) is unchanged after STP — callee reads it at selfEntryInner.
        buf.addImm(x1, sp, savedBytes.uint32)
        if usesMem:
          buf.movReg(x2, rMemBase)
          buf.movReg(x3, rMemSize)
        let offset = selfEntryInner - buf.pos
        buf.bl(offset.int32)
        if usesMem:
          buf.ldpPostIdx(rMemBase, rMemSize, sp, 16)
        buf.ldpPostIdx(rVSP, rLocals, sp, 16)
        # Result in x15 (sidecar) — no dependent-load chain through rVSP.
        if res >= 0:
          if dst != rScratch3:
            buf.movReg(dst, rScratch3)
          if alloc.isSpilled(res):
            buf.storeResult(alloc, res, dst)
        if localsBytes > 0:
          buf.addImm(sp, sp, localsBytes.uint32)
    else:
      # Non-self direct call — look up callee info from funcElems
      let calleeIdx2 = calleeIdx
      let elem = if funcElems != nil and calleeIdx2 >= 0 and calleeIdx2 < numFuncs.int:
                   addr funcElems[calleeIdx2]
                 else: nil
      if elem == nil or elem.jitAddr == nil:
        buf.brk(4)  # callee not JIT-compiled — trap
      else:
        let calleeLCount = elem.localCount.int
        let calleeUsesMem = f.usesMemory  # conservative: assume callee may use memory
        # 1. Allocate callee locals on native stack (aligned to 16)
        let calleeLocalsBytes = ((calleeLCount * 8 + 15) and (not 15))
        if calleeLocalsBytes > 0:
          buf.subImm(sp, sp, calleeLocalsBytes.uint32)
        # 2. Store arguments (up to 3) into callee locals
        for i in 0 ..< min(calleeLCount, 3):
          if instr.operands[i] >= 0:
            let arg = buf.loadOperand(alloc, instr.operands[i], rTmp0)
            buf.strImm(arg, sp, (i * 8).int32)
        # 3. Save WASM state
        buf.stpPreIdx(rVSP, rLocals, sp, -16)
        var savedBytes2 = 16
        if calleeUsesMem:
          buf.stpPreIdx(rMemBase, rMemSize, sp, -16)
          savedBytes2 += 16
        # 4. Set up ABI args: x0=rVSP, x1=calleeLocals, x2=memBase, x3=memSize
        buf.movReg(x0, rVSP)
        buf.addImm(x1, sp, savedBytes2.uint32)
        if calleeUsesMem:
          buf.movReg(x2, rMemBase)
          buf.movReg(x3, rMemSize)
        # 5. Load callee address into x16 (scratch) and BLR
        buf.loadImm64(Reg(16), cast[uint64](elem.jitAddr))
        buf.blr(Reg(16))
        # 6. Restore WASM state
        if calleeUsesMem:
          buf.ldpPostIdx(rMemBase, rMemSize, sp, 16)
        buf.ldpPostIdx(rVSP, rLocals, sp, 16)
        # 7. Load result from value stack [rVSP+0]
        if res >= 0 and elem.resultCount > 0:
          buf.ldrImm(dst, rVSP, 0)
          if alloc.isSpilled(res):
            buf.storeResult(alloc, res, dst)
        # 8. Deallocate callee locals
        if calleeLocalsBytes > 0:
          buf.addImm(sp, sp, calleeLocalsBytes.uint32)

  of irCallIndirect:
    # call_indirect via tier2CallIndirectDispatch runtime helper.
    # instr.operands[0] = elemIdx SSA value (i32)
    # instr.imm         = paramCount | (resultCount << 16)
    # instr.imm2        = tempBase  (first temp local index)
    # Pre-condition: args already spilled to locals[tempBase..tempBase+N-1] by irLocalSet.
    let resultCount = ((instr.imm shr 16) and 0xFFFF).int
    let tempBase    = instr.imm2.int

    # Retrieve per-site cache; siteIdx was pre-incremented by the caller.
    let cacheIdx = callIndirectSiteIdx - 1
    let cachePtr = if cacheIdx < callIndirectCaches.len:
                     callIndirectCaches[cacheIdx]
                   else:
                     nil

    # ---- Step 1: Set up call arguments while WASM regs are still live ----

    # x1 = elemIdx (int32). Load into x1 directly to avoid clobbering SSA regs.
    # (x0-x7, x16-x17 are not SSA-allocated, so safe to write before saving.)
    let elemSrc = instr.operands[0]
    if elemSrc >= 0:
      if alloc.isSpilled(elemSrc):
        # LDR to x16 (scratch, not SSA-allocated), then MOV to x1
        buf.emitSpillLoad(Reg(16), alloc, elemSrc)
        buf.movReg(x1, Reg(16))
      else:
        buf.movReg(x1, alloc.physReg(elemSrc))
    else:
      buf.movz(x1, 0, 0, is64 = false)

    # x2 = argPtr = rLocals + tempBase*8 (pointer to locals[tempBase])
    let argOff = (tempBase * 8).uint32
    if argOff == 0:
      buf.movReg(x2, rLocals)
    elif argOff <= 4095:
      buf.addImm(x2, rLocals, argOff)
    else:
      buf.loadImm32(Reg(16), argOff.int32)
      buf.addReg(x2, rLocals, Reg(16))

    # x3 = memBase, x4 = memSize
    buf.movReg(x3, rMemBase)
    buf.movReg(x4, rMemSize)

    # ---- Step 2: Save caller-saved WASM state and scratch regs ----
    # These are all clobbered by the C ABI call.
    buf.stpPreIdx(rVSP,   rLocals,  sp, -16)   # push x8, x9
    buf.stpPreIdx(rMemBase, rMemSize, sp, -16)  # push x10, x11
    buf.stpPreIdx(Reg(12), Reg(13), sp, -16)    # push x12, x13
    buf.stpPreIdx(Reg(14), Reg(15), sp, -16)    # push x14, x15

    # ---- Step 3: x0 = cachePtr (64-bit constant) ----
    if cachePtr != nil:
      if relocSites != nil:
        relocSites[].add(Relocation(offset: (buf.pos * 4).uint32,
                                    kind: relocCallCache,
                                    siteIdx: cacheIdx.uint32))
      buf.loadImm64(x0, cast[uint64](cachePtr))
    else:
      buf.movz(x0, 0, 0)  # nil cache — will trap in dispatch

    # ---- Step 4: Load dispatch function address into x16 (IP0 scratch) ----
    if relocSites != nil:
      relocSites[].add(Relocation(offset: (buf.pos * 4).uint32,
                                  kind: relocDispatch,
                                  siteIdx: 0))
    buf.loadImm64(Reg(16), cast[uint64](tier2CallIndirectDispatch))
    buf.blr(Reg(16))

    # ---- Step 5: Check return value. Non-zero = trap. ----
    # CBZ w0, skip; BRK #1; skip:
    buf.emit(0x34000040'u32)  # CBZ w0, #8 (skip 2 instrs forward)
    buf.brk(1)                 # trap

    # ---- Step 6: Restore caller-saved regs ----
    buf.ldpPostIdx(Reg(14), Reg(15), sp, 16)    # pop x14, x15
    buf.ldpPostIdx(Reg(12), Reg(13), sp, 16)    # pop x12, x13
    buf.ldpPostIdx(rMemBase, rMemSize, sp, 16)  # pop x10, x11
    buf.ldpPostIdx(rVSP,   rLocals,  sp, 16)    # pop x8, x9

    # ---- Step 7: Load result from locals[tempBase] ----
    if res >= 0 and resultCount > 0:
      let resultOff = (tempBase * 8).int32
      buf.ldrImm(dst, rLocals, resultOff)
      if alloc.isSpilled(res):
        buf.storeResult(alloc, res, dst)

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

proc emitIrFunc*(pool: var JitMemPool, f: IrFunc, alloc: RegAllocResult,
                 selfModuleIdx: int = -1,
                 tableElems: ptr UncheckedArray[TableElem] = nil,
                 tableLen: int32 = 0,
                 funcElems: ptr UncheckedArray[TableElem] = nil,
                 numFuncs: int32 = 0,
                 relocSites: ptr seq[Relocation] = nil): JitCode =
  ## Emit AArch64 machine code for an entire IR function using register allocation.
  ## Returns a JitCode handle to the executable memory.
  var buf = initAsmBuffer(f.numValues * 4 + 64)
  let constants = buildCodegenConstants(f)

  # ---- Register-based parameter passing eligibility check ----
  # For self-recursive functions, we can pass args directly to param registers via x4/x5
  # (caller-scratch regs) instead of STR-to-stack + LDR-from-stack (store-forward ~4-5 cycles).
  #
  # selfEntryReg stores params to memory AND sets the param registers, then jumps past the
  # irParam LDR instructions in BB0.  This eliminates the store-forward because the STR
  # (in selfEntryReg) has no dependent LDR immediately after — subsequent irLocalGet accesses
  # happen much later with no hazard.
  #
  # Conditions: selfModuleIdx known, 1-2 params, each irParam has a non-spilled register.
  var paramPhysRegs: seq[Reg]  # physReg for irParam(i), indexed by param index
  var selfEntryRegBranchList: seq[int]  # positions of BL selfEntryReg placeholders
  if selfModuleIdx >= 0 and f.numParams in 1..2 and f.blocks.len > 0:
    var tmpRegs: seq[Reg]
    for instr in f.blocks[0].instrs:
      if instr.op == irParam:
        let idx = instr.imm.int
        while tmpRegs.len <= idx: tmpRegs.add(xzr)
        if instr.result >= 0 and not alloc.isSpilled(instr.result):
          tmpRegs[idx] = alloc.physReg(instr.result)
    # All params must have allocated (non-spilled) registers
    var valid = tmpRegs.len == f.numParams
    for r in tmpRegs:
      if r == xzr: valid = false; break
    if valid:
      paramPhysRegs = tmpRegs

  # Pre-allocate one CallIndirectCache per call_indirect site.
  # Each cache is heap-allocated (tied to pool lifetime via pool.sideData).
  var callIndirectCaches = newSeq[ptr CallIndirectCache](f.callIndirectSiteCount)
  for i in 0 ..< f.callIndirectSiteCount:
    let cacheSize = sizeof(CallIndirectCache)
    let p = cast[ptr CallIndirectCache](allocShared0(cacheSize))
    p.cachedElemIdx = -1  # mark IC as empty
    p.tableElems = tableElems
    p.tableLen = tableLen
    # paramCount and resultCount are filled in when irCallIndirect is emitted
    pool.sideData.add(p)
    callIndirectCaches[i] = p

  # Detect whether locals array (rLocals / x9) is ever accessed in the function body
  # after the irParam instructions. If all irLocalGet/irLocalSet are optimized away
  # by localValueForward + promoteLocals, and there are no irCallIndirect sites,
  # we can skip setting up rLocals in the selfEntryReg path and skip computing
  # the locals pointer (ADD x1, SP, #16) at self-call sites.
  var localsFullyPromoted = true
  for bb in f.blocks:
    for instr in bb.instrs:
      if instr.op in {irLocalGet, irLocalSet, irCallIndirect}:
        localsFullyPromoted = false
        break
    if not localsFullyPromoted: break

  # Build use-count map for fused compare-and-branch detection
  var useCount = newSeq[int](f.numValues)
  for bb in f.blocks:
    for instr in bb.instrs:
      for op in instr.operands:
        if op >= 0: inc useCount[op.int]

  let csRegs = calleeSavedList(alloc)
  let spillBytes = alloc.totalSpillBytes
  # Frame: [callee-saved regs] [spill slots] (all below FP)
  # We allocate: 16 (fp/lr) + csRegs.len*8 (rounded up to 16) + spillBytes (rounded up to 16)
  let csBytes = csRegs.len * 8
  let csBytesAligned = (csBytes + 15) and (not 15)
  let spillBytesAligned = (spillBytes + 15) and (not 15)
  let totalFrameExtra = csBytesAligned + spillBytesAligned

  # ---- Prologue ----
  # For self-recursive functions (selfModuleIdx >= 0), selfEntry is an external
  # wrapper that calls selfEntryInner via BL. The wrapper handles the value-stack
  # push (STR + MOV x0) that self-callers don't need, saving 2 instructions per
  # self-recursive call.
  #
  # Layout for self-recursive functions:
  #   selfEntry:      MOV x8,x0; STP fp,lr; BL selfEntryInner; <STR+MOV x0>; LDP fp,lr; RET
  #   selfEntryInner: STP fp,lr; <CS save>; <body>; epilogue: <CS restore>; LDP fp,lr; RET
  #
  # Layout for non-recursive functions (original):
  #   selfEntry:      MOV x8,x0; (fallthrough to selfEntryInner)
  #   selfEntryInner: STP fp,lr; <CS save>; <body>; epilogue with STR+MOV x0
  let useSelfReturnOpt = selfModuleIdx >= 0
  var selfEntryWrapperPatch = -1  # position of BL placeholder in wrapper

  let selfEntry = buf.pos
  buf.movReg(rVSP, x0)        # x8 = VSP from ABI arg (external callers need this)

  if useSelfReturnOpt:
    # External wrapper: save caller's fp/lr, BL to function body, fixup ABI, return
    buf.stpPreIdx(fp, lr, sp, -16)
    selfEntryWrapperPatch = buf.pos
    buf.bl(0)  # placeholder — patched to selfEntryInner after it's emitted
    # After function returns: x15 = result value (or undefined for void)
    if f.numResults > 0:
      # STR x15, [x8], #8 — push result to value stack for external ABI
      let imm9 = 8'u32 and 0x1FF
      buf.emit(0xF8000400'u32 or (imm9 shl 12) or (rVSP.uint8.uint32 shl 5) or rScratch3.uint8.uint32)
    buf.movReg(x0, rVSP)        # x0 = updated VSP (return value for external ABI)
    buf.ldpPostIdx(fp, lr, sp, 16)
    buf.ret()

  let selfEntryInner = buf.pos  # self-callers jump here: x8 already correct, full frame setup follows

  # Patch the wrapper's BL to point to selfEntryInner
  if useSelfReturnOpt and selfEntryWrapperPatch >= 0:
    let offset = selfEntryInner - selfEntryWrapperPatch
    buf.patchAt(selfEntryWrapperPatch, 0x94000000'u32 or (offset.uint32 and 0x03FFFFFF))
  # Save FP/LR and callee-saved registers.
  # Fast path: single SP allocation + parallel-safe offset stores.
  # Instead of N separate STP pre-index (serial SP dependency chain),
  # allocate the full frame with one pre-index STP, then use offset STPs
  # for the rest. This allows M-series dual store ports to issue in parallel.
  #
  # Layout (stack grows down):
  #   SP     → [cs_last_pair]       ← first STP (pre-index, allocates frame)
  #   SP+16  → [cs_prev_pair]       ← offset STP (no SP update)
  #   ...
  #   SP+N*8 → [fp, lr]             ← offset STP (no SP update)
  let usePreIdxCsSave = spillBytesAligned == 0 and csRegs.len > 0 and
                        (csRegs.len and 1) == 0 and csBytesAligned <= 496
  if usePreIdxCsSave:
    let totalAlloc = 16 + csBytesAligned  # fp/lr + CS regs
    # First pair gets the pre-index (allocates entire frame in one shot)
    buf.stpPreIdx(csRegs[csRegs.len - 2], csRegs[csRegs.len - 1], sp, -totalAlloc.int32)
    # Remaining CS pairs use offset STP (no SP update → can issue in parallel)
    var i = csRegs.len - 4
    var off = 16  # offset from SP
    while i >= 0:
      buf.stpImm(csRegs[i], csRegs[i+1], sp, off.int32)
      i -= 2
      off += 16
    # fp/lr at the top of the frame
    buf.stpImm(fp, lr, sp, (totalAlloc - 16).int32)
  else:
    # Slow path: save fp/lr first, then allocate space for CS+spills
    buf.stpPreIdx(fp, lr, sp, -16)
    if totalFrameExtra > 0:
      if totalFrameExtra <= 4095:
        buf.subImm(sp, sp, totalFrameExtra.uint32)
      else:
        buf.loadImm32(rTmp0, totalFrameExtra.int32)
        buf.subReg(sp, sp, rTmp0)
    if csRegs.len > 0:
      buf.saveCalleeSaved(csRegs, spillBytesAligned.int32)

  # Set up remaining WASM state registers from ABI args:
  #   x1 = locals pointer -> x9
  #   x2 = memory base -> x10 (only if function uses memory)
  #   x3 = memory size -> x11 (only if function uses memory)
  buf.movReg(rLocals, x1)     # x9 = locals (needed by irParam even when localsFullyPromoted)
  if f.usesMemory:
    buf.movReg(rMemBase, x2)    # x10 = memBase
    buf.movReg(rMemSize, x3)    # x11 = memSize

  # ---- Emit basic blocks ----
  var blockLabels = newSeq[BlockLabel](f.blocks.len)
  for i in 0 ..< blockLabels.len:
    blockLabels[i].offset = -1
  var epiloguePatchList: seq[int]
  var callIndirectSiteIdx = 0  # incremented before passing to emitIrInstr for each site

  # selfEntrySkipParams: offset just after the last irParam instruction in BB0.
  # Self-callers via selfEntryReg put args in param regs then jump here,
  # skipping the irParam LDR instructions that load from memory.
  var selfEntrySkipParams = -1
  var lastParamInBB0 = -1  # instruction index of the last irParam in BB0
  if paramPhysRegs.len > 0 and f.blocks.len > 0:
    for i in 0 ..< f.blocks[0].instrs.len:
      if f.blocks[0].instrs[i].op == irParam:
        lastParamInBB0 = i
    if lastParamInBB0 < 0:
      paramPhysRegs.setLen(0)  # no irParam found — disable optimization

  for bbIdx in 0 ..< f.blocks.len:
    let bb = f.blocks[bbIdx]

    # Record the block label position
    if bbIdx < blockLabels.len:
      blockLabels[bbIdx].offset = buf.pos

    # Patch any forward branches targeting this block
    if bbIdx < blockLabels.len:
      for patchPos in blockLabels[bbIdx].patchList:
        let patchInstr = buf.code[patchPos]
        let opHigh = patchInstr and 0xFC000000'u32
        let offset = buf.pos - patchPos
        if opHigh == 0x14000000'u32:
          # B instruction: replace with correct offset
          buf.patchAt(patchPos, 0x14000000'u32 or (offset.uint32 and 0x03FFFFFF))
        elif opHigh == 0x34000000'u32 or opHigh == 0xB4000000'u32:
          # CBZ/CBNZ: patch imm19 field
          let base = patchInstr and 0xFF00001F'u32
          buf.patchAt(patchPos, base or ((offset.uint32 and 0x7FFFF) shl 5))
        elif (patchInstr and 0xFF000010'u32) == 0x54000000'u32:
          # B.cond: patch imm19 field (bits [23:5]), preserve cond in bits [3:0]
          let base = patchInstr and 0xFF00001F'u32
          buf.patchAt(patchPos, base or ((offset.uint32 and 0x7FFFF) shl 5))
      blockLabels[bbIdx].patchList.setLen(0)

    # Pre-scan for fused compare-and-branch opportunity:
    # If the block's last instruction is irBrIf, and its condition operand is
    # produced by a comparison that is used ONLY by this irBrIf, we can emit
    # CMP + B.cond instead of CMP + CSINC + CBNZ (saves 1 instruction).
    const cmpOps = {irEq32, irNe32, irLt32S, irLt32U, irGt32S, irGt32U,
                     irLe32S, irLe32U, irGe32S, irGe32U, irEqz32,
                     irEq64, irNe64, irLt64S, irLt64U, irGt64S, irGt64U,
                     irLe64S, irLe64U, irGe64S, irGe64U, irEqz64}
    var fusedCmpResult: IrValue = -1  # SSA value whose CSINC should be skipped
    var fusedBranchCond: Cond = condAL
    var fusedCmpIs64 = false  # true when the fused comparison is 64-bit

    if bb.instrs.len >= 2:
      let lastInstr = bb.instrs[^1]
      let penultInstr = bb.instrs[^2]
      # Only fuse when the comparison is IMMEDIATELY before irBrIf (no instructions
      # between them that could clobber ARM64 condition flags, e.g., bounds checks)
      if lastInstr.op == irBrIf and lastInstr.operands[0] >= 0 and
         penultInstr.op in cmpOps and penultInstr.result == lastInstr.operands[0] and
         penultInstr.result >= 0:
        let condVal = lastInstr.operands[0]
        if condVal.int < useCount.len and useCount[condVal.int] == 1:
          fusedCmpResult = condVal
          fusedBranchCond = case penultInstr.op
            of irEq32, irEq64: condEQ
            of irNe32, irNe64: condNE
            of irLt32S, irLt64S: condLT
            of irLt32U, irLt64U: condCC
            of irGt32S, irGt64S: condGT
            of irGt32U, irGt64U: condHI
            of irLe32S, irLe64S: condLE
            of irLe32U, irLe64U: condLS
            of irGe32S, irGe64S: condGE
            of irGe32U, irGe64U: condCS
            of irEqz32, irEqz64: condEQ
            else: condAL
          fusedCmpIs64 = penultInstr.op in {irEq64, irNe64, irLt64S, irLt64U,
            irGt64S, irGt64U, irLe64S, irLe64U, irGe64S, irGe64U, irEqz64}

    # Emit instructions for this block
    for instrIdx in 0 ..< bb.instrs.len:
      let instr = bb.instrs[instrIdx]

      # If this comparison is fused with the terminal irBrIf, emit only CMP (no CSINC)
      if instr.result == fusedCmpResult and instr.op in cmpOps:
        if instr.op in {irEqz32, irEqz64}:
          let a = buf.loadOperand(alloc, instr.operands[0], rTmp0)
          buf.cmpImm(a, 0, is64 = fusedCmpIs64)
        elif fusedCmpIs64:
          buf.emitCmp64(alloc, instr.operands[0], instr.operands[1], constants)
        else:
          buf.emitCmp32(alloc, instr.operands[0], instr.operands[1], constants)
        continue  # skip CSINC materialization

      # If this is the terminal irBrIf and we have a fused condition, emit B.cond
      if instr.op == irBrIf and fusedCmpResult >= 0:
        let targetBb = instr.imm.int
        buf.emitPhiResolution(f, alloc, targetBb, bbIdx)
        if targetBb < blockLabels.len and blockLabels[targetBb].offset >= 0:
          buf.bCond(fusedBranchCond, (blockLabels[targetBb].offset - buf.pos).int32)
        else:
          if targetBb >= blockLabels.len: blockLabels.setLen(targetBb + 1)
          blockLabels[targetBb].patchList.add(buf.pos)
          buf.bCond(fusedBranchCond, 0)
        let falseBb = instr.imm2.int
        if falseBb > 0:
          if falseBb < blockLabels.len and blockLabels[falseBb].offset >= 0:
            buf.b((blockLabels[falseBb].offset - buf.pos).int32)
          else:
            if falseBb >= blockLabels.len: blockLabels.setLen(falseBb + 1)
            blockLabels[falseBb].patchList.add(buf.pos)
            buf.b(0)
        continue  # skip normal irBrIf emission

      # Pre-increment call_indirect site index so the handler can index callIndirectCaches.
      if instr.op == irCallIndirect:
        # Fill in paramCount/resultCount on the cache before emitting.
        let siteCache = if callIndirectSiteIdx < callIndirectCaches.len:
                          callIndirectCaches[callIndirectSiteIdx]
                        else: nil
        if siteCache != nil:
          siteCache.paramCount  = (instr.imm and 0xFFFF).int32
          siteCache.resultCount = ((instr.imm shr 16) and 0xFFFF).int32
        inc callIndirectSiteIdx

      emitIrInstr(buf, instr, alloc, f, blockLabels, epiloguePatchList,
                  selfEntry, selfEntryInner, selfModuleIdx, bbIdx, constants,
                  callIndirectCaches, callIndirectSiteIdx,
                  funcElems, numFuncs, relocSites,
                  selfEntryReg = -1,   # selfEntryReg not yet known at call sites
                  paramPhysRegs = paramPhysRegs,
                  selfEntryRegBranchList = addr selfEntryRegBranchList,
                  localsFullyPromoted = localsFullyPromoted)

      # Mark selfEntrySkipParams after the last irParam in BB0
      if bbIdx == 0 and selfEntrySkipParams < 0 and paramPhysRegs.len > 0:
        if instrIdx + 1 < bb.instrs.len:
          if bb.instrs[instrIdx + 1].op != irParam:
            if instr.op == irParam:
              selfEntrySkipParams = buf.pos
        elif instr.op == irParam:
          selfEntrySkipParams = buf.pos  # last instr in BB0 was irParam

  # Patch irReturn branches to point to the epilogue
  let epilogueOffset = buf.pos
  for patchPos in epiloguePatchList:
    let offset = epilogueOffset - patchPos
    buf.patchAt(patchPos, 0x14000000'u32 or (offset.uint32 and 0x03FFFFFF))

  # ---- Epilogue ----
  if usePreIdxCsSave:
    # Fast path: parallel-safe offset loads + single SP deallocation.
    # Mirror the prologue layout: CS at bottom, fp/lr at top.
    # Load fp/lr and inner CS pairs with offset LDP (no SP update → parallel).
    # Last LDP uses post-index to deallocate the entire frame in one shot.
    let totalAlloc = 16 + csBytesAligned
    # Restore fp/lr from top of frame (no SP update)
    buf.ldpImm(fp, lr, sp, (totalAlloc - 16).int32)
    # Restore inner CS pairs with offset LDP (no SP update)
    var i = 0
    var off = totalAlloc - 32
    while i < csRegs.len - 2:
      buf.ldpImm(csRegs[i], csRegs[i+1], sp, off.int32)
      i += 2
      off -= 16
    # Last CS pair uses post-index to deallocate entire frame
    buf.ldpPostIdx(csRegs[csRegs.len - 2], csRegs[csRegs.len - 1], sp, totalAlloc.int32)
  else:
    # Slow path: restore callee-saved then deallocate frame
    if csRegs.len > 0:
      buf.restoreCalleeSaved(csRegs, spillBytesAligned.int32)
    if totalFrameExtra > 0:
      if totalFrameExtra <= 4095:
        buf.addImm(sp, sp, totalFrameExtra.uint32)
      else:
        buf.loadImm32(rTmp0, totalFrameExtra.int32)
        buf.addReg(sp, sp, rTmp0)
    # Restore FP/LR and return
    buf.ldpPostIdx(fp, lr, sp, 16)

  buf.ret()

  # Post-codegen peephole
  peepholeAarch64(buf)

  # ---- selfEntryReg: register-based parameter entry for self-callers ----
  # Placed after the epilogue so the normal code path doesn't fall through.
  # Caller ABI: set x4=arg0, [x5=arg1], x1=callee-locals-base, then BL selfEntryReg.
  # We duplicate the fp/lr + callee-saved save, set x9=x1, move params from x4/x5
  # to their allocated physical registers, then branch backward to selfEntrySkipParams
  # (the instruction immediately after the last irParam LDR in BB0).
  if paramPhysRegs.len > 0 and selfEntrySkipParams >= 0 and selfEntryRegBranchList.len > 0:
    let selfEntryRegOffset = buf.pos
    # Duplicate the selfEntryInner prologue: save fp/lr + frame + callee-saved regs.
    # Must use same layout as the main prologue (CS at bottom, fp/lr at top).
    if usePreIdxCsSave:
      let totalAlloc = 16 + csBytesAligned
      buf.stpPreIdx(csRegs[csRegs.len - 2], csRegs[csRegs.len - 1], sp, -totalAlloc.int32)
      var i = csRegs.len - 4
      var off = 16
      while i >= 0:
        buf.stpImm(csRegs[i], csRegs[i+1], sp, off.int32)
        i -= 2
        off += 16
      buf.stpImm(fp, lr, sp, (totalAlloc - 16).int32)
    else:
      buf.stpPreIdx(fp, lr, sp, -16)
      if totalFrameExtra > 0:
        if totalFrameExtra <= 4095:
          buf.subImm(sp, sp, totalFrameExtra.uint32)
        else:
          buf.loadImm32(rTmp0, totalFrameExtra.int32)
          buf.subReg(sp, sp, rTmp0)
      if csRegs.len > 0:
        buf.saveCalleeSaved(csRegs, spillBytesAligned.int32)
    if not localsFullyPromoted:
      buf.movReg(rLocals, x1)          # x9 = callee locals (caller set x1 = SP+16)
    # Store params to the locals array AND set their allocated physical registers.
    # The STR here has no dependent LDR immediately after (we branch past the irParam LDRs),
    # so there is no store-forward hazard.  Subsequent irLocalGet/irLocalSet for param locals
    # (at merge points, loops, etc.) will find correct values in memory.
    let passRegs = [Reg(4), Reg(5)]  # x4, x5 — scratch regs used by self-caller ABI
    for i in 0 ..< paramPhysRegs.len:
      if not localsFullyPromoted:
        buf.strImm(passRegs[i], rLocals, (i * 8).int32)  # STR x4/x5, [x9, i*8]
      buf.movReg(paramPhysRegs[i], passRegs[i])        # MOV paramReg, x4/x5
    # Branch backward to selfEntrySkipParams, skipping the irParam LDR instructions in BB0.
    buf.b((selfEntrySkipParams - buf.pos).int32)
    # Patch all BL selfEntryReg placeholders emitted in the main body.
    for patchPos in selfEntryRegBranchList:
      let offset = selfEntryRegOffset - patchPos
      buf.patchAt(patchPos, 0x94000000'u32 or (offset.uint32 and 0x03FFFFFF))

  # Write to executable memory pool
  result = pool.writeCode(buf.code)
  result.numLocals = f.numLocals
