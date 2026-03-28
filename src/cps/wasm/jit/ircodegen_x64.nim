## x86_64 IR code generator (Tier 2 backend)
##
## Takes an IrFunc and a RegAllocResult (allocated with NumIntRegsX64 / CalleeSavedStartX64)
## and emits x86_64 machine code using physical registers.
##
## Register convention:
##   WASM state:  r12=VSP, r13=locals, r14=memBase, r15=memSize (callee-saved, always preserved)
##   Scratch:     rax=scratch0, rcx=scratch1 (shift count), rdx=scratch2 (div remainder)
##   Allocatable (5 regs, colors 0-4):
##     [0]=r8, [1]=r9, [2]=r10, [3]=r11  (caller-saved)
##     [4]=rbx                            (callee-saved, used for call-live values)
##   Frame pointer: rbp (always saved/restored via standard prologue/epilogue)
##   Reserved: rdi, rsi (call argument setup only — not allocatable)
##
## Function ABI (SysV AMD64):
##   (rdi=VSP, rsi=locals, rdx=memBase, rcx=memSize) -> rax (updated VSP)
##
## Frame layout (rbp-relative, after prologue):
##   [rbp]       = saved rbp
##   sub rsp, N  (N = alignUp16(csSaveBytes + spillBytes))
##   [rbp-8]     = saved r12 (VSP)
##   [rbp-16]    = saved r13 (locals)
##   [rbp-24]    = saved r14 (memBase)
##   [rbp-32]    = saved r15 (memSize)
##   [rbp-40]    = saved rbx (if used)
##   Spill slots: at [rbp + spillSlotBias + slot.offset]  (spillSlotBias = -frameSize)

import ir, regalloc, codegen_x64, memory, compiler, aotcache

# ---------------------------------------------------------------------------
# Register constants
# ---------------------------------------------------------------------------

const
  NumIntRegsX64*       = 5     ## allocatable integer registers for x86_64
  CalleeSavedStartX64* = 4'i8  ## color 4 (rbx) is the first callee-saved allocatable reg

const x64AllocRegs: array[NumIntRegsX64, X64Reg] = [r8, r9, r10, r11, rbx]

const
  rTmpX = rax   ## scratch 0: return value, div quotient
  rTmpY = rcx   ## scratch 1: shift amount (CL), spill load scratch for second operand
  rTmpZ = rdx   ## scratch 2: div remainder, bounds-check scratch
  rWVSP = r12   ## WASM value-stack pointer (callee-saved)
  rWLoc = r13   ## WASM locals base pointer (callee-saved)
  rWMem = r14   ## WASM linear memory base  (callee-saved)
  rWSiz = r15   ## WASM linear memory size  (callee-saved)

# ---------------------------------------------------------------------------
# Register resolution
# ---------------------------------------------------------------------------

proc isSpilledX64(alloc: RegAllocResult, v: IrValue): bool {.inline.} =
  v >= 0 and alloc.assignment[v.int].int8 < 0

proc physRegX64(alloc: RegAllocResult, v: IrValue): X64Reg {.inline.} =
  if v < 0: return rTmpX
  let pr = alloc.assignment[v.int]
  if pr.int8 >= 0 and pr.int8 < NumIntRegsX64:
    x64AllocRegs[pr.int8]
  else:
    rTmpX

proc spillOffsetX64(alloc: RegAllocResult, v: IrValue): int32 {.inline.} =
  ## Get the spill slot byte offset for a spilled SSA value.
  ## Uses precomputed spillOffsetMap for O(1) lookup.
  if v.int < alloc.spillOffsetMap.len:
    result = alloc.spillOffsetMap[v.int]
  else:
    result = 0

# ---------------------------------------------------------------------------
# Frame-based spill helpers (rbp-relative addressing)
# ---------------------------------------------------------------------------

proc emitSpillLoadX64(buf: var X64AsmBuffer, dst: X64Reg, alloc: RegAllocResult,
                      v: IrValue, spillSlotBias: int32) =
  let off = spillOffsetX64(alloc, v)
  buf.movRegMem(dst, rbp, spillSlotBias + off)

proc emitSpillStoreX64(buf: var X64AsmBuffer, src: X64Reg, alloc: RegAllocResult,
                       v: IrValue, spillSlotBias: int32) =
  let off = spillOffsetX64(alloc, v)
  buf.movMemReg(rbp, spillSlotBias + off, src)

proc loadOperandX64(buf: var X64AsmBuffer, alloc: RegAllocResult, v: IrValue,
                    spillSlotBias: int32, scratch: X64Reg = rTmpX): X64Reg =
  if v < 0: return rTmpX
  if alloc.isSpilledX64(v):
    if v.int < alloc.rematKind.len and alloc.rematKind[v.int] == rematConst:
      buf.movImmX64(scratch, alloc.rematImm[v.int])
      return scratch
    buf.emitSpillLoadX64(scratch, alloc, v, spillSlotBias)
    return scratch
  return alloc.physRegX64(v)

proc storeResultX64(buf: var X64AsmBuffer, alloc: RegAllocResult, v: IrValue,
                    src: X64Reg, spillSlotBias: int32) =
  if v < 0: return
  if alloc.isSpilledX64(v):
    if v.int < alloc.rematKind.len and alloc.rematKind[v.int] == rematConst:
      return  # remat: no spill slot exists; nothing to store
    buf.emitSpillStoreX64(src, alloc, v, spillSlotBias)
  else:
    let dst = alloc.physRegX64(v)
    if dst != src:
      buf.movRegReg(dst, src)

# ---------------------------------------------------------------------------
# SIMD v128 helpers for x64
# ---------------------------------------------------------------------------
# All v128 IR values are spilled on x64 (no dedicated SIMD register allocator);
# xmm0-xmm3 are used as scratch registers for SIMD operations.
# The regalloc already creates 16-byte aligned spill slots for rcSimd values.

const
  xSimd0 = xmm0   ## SIMD scratch register 0
  xSimd1 = xmm1   ## SIMD scratch register 1
  xSimd2 = xmm2   ## SIMD scratch register 2

proc emitSimdSpillLoad(buf: var X64AsmBuffer, dst: X64FReg, alloc: RegAllocResult,
                       v: IrValue, spillSlotBias: int32) {.inline.} =
  let off = spillOffsetX64(alloc, v)
  buf.movdquLoad(dst, rbp, spillSlotBias + off)

proc emitSimdSpillStore(buf: var X64AsmBuffer, src: X64FReg, alloc: RegAllocResult,
                        v: IrValue, spillSlotBias: int32) {.inline.} =
  let off = spillOffsetX64(alloc, v)
  buf.movdquStore(rbp, spillSlotBias + off, src)

proc loadSimdX64(buf: var X64AsmBuffer, alloc: RegAllocResult, v: IrValue,
                 spillSlotBias: int32, scratch: X64FReg = xSimd0): X64FReg =
  ## Load a v128 operand into an XMM scratch register. All v128 values are
  ## spilled on x64, so this always emits a movdqu from the stack.
  if v < 0: return scratch
  buf.emitSimdSpillLoad(scratch, alloc, v, spillSlotBias)
  scratch

proc storeSimdX64(buf: var X64AsmBuffer, alloc: RegAllocResult, v: IrValue,
                  src: X64FReg, spillSlotBias: int32) =
  ## Store a v128 result from an XMM register back to its spill slot.
  if v < 0: return
  buf.emitSimdSpillStore(src, alloc, v, spillSlotBias)

proc emitV128ConstX64(buf: var X64AsmBuffer, dst: X64FReg,
                       constData: array[16, byte]) =
  ## Materialise a 128-bit constant into `dst` using two 64-bit GP loads.
  ## Uses rcx (rax is the return register; rcx is free in JIT bodies).
  ## Emits: mov rcx, low64; movq dst, rcx; mov rcx, hi64; pinsrq dst, rcx, 1
  let lo = (cast[uint64](constData[0])       or
            cast[uint64](constData[1]) shl 8  or
            cast[uint64](constData[2]) shl 16 or
            cast[uint64](constData[3]) shl 24 or
            cast[uint64](constData[4]) shl 32 or
            cast[uint64](constData[5]) shl 40 or
            cast[uint64](constData[6]) shl 48 or
            cast[uint64](constData[7]) shl 56)
  let hi = (cast[uint64](constData[8])        or
            cast[uint64](constData[9])  shl 8  or
            cast[uint64](constData[10]) shl 16 or
            cast[uint64](constData[11]) shl 24 or
            cast[uint64](constData[12]) shl 32 or
            cast[uint64](constData[13]) shl 40 or
            cast[uint64](constData[14]) shl 48 or
            cast[uint64](constData[15]) shl 56)
  buf.movImmX64(rcx, cast[int64](lo))
  buf.movqToXmm(dst, rcx)
  buf.movImmX64(rcx, cast[int64](hi))
  buf.pinsrqRR(dst, rcx, 1)

proc emitLoadXmmFromMem(buf: var X64AsmBuffer, dst: X64FReg,
                         addrReg: X64Reg, memBaseReg: X64Reg) =
  ## Emit: dst = *(memBaseReg + addrReg) — 128-bit unaligned load
  ## Uses addrReg as the index — adds memBase then movdqu.
  buf.addRegReg(addrReg, memBaseReg)
  buf.movdquLoad(dst, addrReg, 0)

proc emitStoreXmmToMem(buf: var X64AsmBuffer, src: X64FReg,
                        addrReg: X64Reg, memBaseReg: X64Reg) =
  ## Emit: *(memBaseReg + addrReg) = src — 128-bit unaligned store
  buf.addRegReg(addrReg, memBaseReg)
  buf.movdquStore(addrReg, 0, src)

proc emitI32x4Shift(buf: var X64AsmBuffer, dst, va: X64FReg,
                     scalarReg: X64Reg, shiftXmm: X64FReg,
                     isShr, isSigned: bool) =
  ## Emit i32x4 shift by scalar amount (modulo 32).
  ## dst = va shifted by (scalarReg & 31) in each lane.
  buf.movdqaRR(dst, va)
  # Mask shift amount to 5 bits (modulo 32) and move to XMM count register
  buf.andRegImm32(scalarReg, 31)
  buf.movdToXmm(shiftXmm, scalarReg)
  if isShr and isSigned:
    buf.psradRR(dst, shiftXmm)
  elif isShr:
    buf.psrldRR(dst, shiftXmm)
  else:
    buf.pslldRR(dst, shiftXmm)

# ---------------------------------------------------------------------------
# Block label tracking
# ---------------------------------------------------------------------------

type
  X64BlockLabel = object
    offset: int                 ## byte offset where block starts (-1 = not emitted yet)
    patchList: seq[(int, bool)] ## (instrStartOffset, isJcc) for forward-branch patching

# ---------------------------------------------------------------------------
# Memory bounds check
# ---------------------------------------------------------------------------

proc emitBoundsCheckX64(buf: var X64AsmBuffer, addrReg: X64Reg, accessBytes: int32) =
  ## Emit bounds check: trap (ud2) if addrReg + accessBytes > memSize.
  ## When -d:wasmGuardPages is set, hardware guard pages handle this — no-op.
  ## Uses rTmpZ (rdx) as scratch; does NOT clobber addrReg.
  when defined(wasmGuardPages):
    discard buf; discard addrReg; discard accessBytes
  else:
    buf.movRegReg(rTmpZ, addrReg)
    buf.addImmX64(rTmpZ, accessBytes)
    buf.cmpRegReg(rTmpZ, rWSiz)     # CMP rdx, r15 (rTmpZ - memSize)
    buf.jccRel8(x64condBE, 2)       # JBE +2 (skip ud2 if in-bounds, unsigned <=)
    buf.ud2()

# ---------------------------------------------------------------------------
# Phi resolution (parallel-copy sequencing with cycle breaking)
# ---------------------------------------------------------------------------

proc emitPhiResolutionX64(buf: var X64AsmBuffer, f: IrFunc, alloc: RegAllocResult,
                           targetBb: int, sourceBb: int, spillSlotBias: int32) =
  if targetBb >= f.blocks.len: return
  let isBackEdge = sourceBb >= targetBb

  type RegMove = object
    dst, src: X64Reg
    dstVal: IrValue

  var moves: seq[RegMove]

  for phi in f.blocks[targetBb].instrs:
    if phi.op != irPhi or phi.result < 0: continue
    let opIdx = if isBackEdge and phi.operands[1] >= 0: 1 else: 0
    let srcVal = phi.operands[opIdx]
    if srcVal < 0 or srcVal == phi.result: continue

    # Handle spilled source: load to rTmpX then move to dst
    if alloc.isSpilledX64(srcVal):
      let loaded = buf.loadOperandX64(alloc, srcVal, spillSlotBias, rTmpX)
      let dstReg = alloc.physRegX64(phi.result)
      if dstReg != loaded:
        buf.movRegReg(dstReg, loaded)
      if alloc.isSpilledX64(phi.result):
        buf.storeResultX64(alloc, phi.result, dstReg, spillSlotBias)
      continue

    let dstReg = alloc.physRegX64(phi.result)
    let srcReg = alloc.physRegX64(srcVal)
    if dstReg == srcReg: continue
    moves.add(RegMove(dst: dstReg, src: srcReg, dstVal: phi.result))

  if moves.len == 0: return

  # Resolve parallel copies: repeatedly emit moves whose dst is not someone else's src
  var done = newSeq[bool](moves.len)
  var changed = true
  while changed:
    changed = false
    for i in 0 ..< moves.len:
      if done[i]: continue
      var blocked = false
      for j in 0 ..< moves.len:
        if not done[j] and j != i and moves[j].src == moves[i].dst:
          blocked = true
          break
      if not blocked:
        buf.movRegReg(moves[i].dst, moves[i].src)
        if alloc.isSpilledX64(moves[i].dstVal):
          buf.storeResultX64(alloc, moves[i].dstVal, moves[i].dst, spillSlotBias)
        done[i] = true
        changed = true

  # Break remaining cycles using rTmpX (rax) as temp
  for i in 0 ..< moves.len:
    if done[i]: continue
    buf.movRegReg(rTmpX, moves[i].src)
    var cur = i
    while not done[cur]:
      done[cur] = true
      var nxt = -1
      for j in 0 ..< moves.len:
        if not done[j] and moves[j].src == moves[cur].dst:
          nxt = j
          break
      buf.movRegReg(moves[cur].dst, moves[cur].src)
      if alloc.isSpilledX64(moves[cur].dstVal):
        buf.storeResultX64(alloc, moves[cur].dstVal, moves[cur].dst, spillSlotBias)
      if nxt < 0: break
      cur = nxt
    # Final move in cycle from temp
    buf.movRegReg(moves[i].dst, rTmpX)
    if alloc.isSpilledX64(moves[i].dstVal):
      buf.storeResultX64(alloc, moves[i].dstVal, moves[i].dst, spillSlotBias)

# ---------------------------------------------------------------------------
# Per-instruction emission
# ---------------------------------------------------------------------------

proc emitIrInstrX64(buf: var X64AsmBuffer, instr: IrInstr, f: IrFunc,
                     alloc: RegAllocResult, res: IrValue,
                     spillSlotBias: int32,
                     curBlockIdx: int,
                     blockLabels: var seq[X64BlockLabel],
                     epiloguePatchList: var seq[int],
                     selfModuleIdx: int,
                     selfEntry: int,
                     callIndirectCaches: seq[ptr CallIndirectCache],
                     callIndirectSiteIdx: int,
                     relocSites: var seq[Relocation]) =

  # Helper: determine destination register (physical reg or rTmpX for spilled)
  let resReg: X64Reg =
    if res >= 0 and not alloc.isSpilledX64(res): alloc.physRegX64(res)
    else: rTmpX

  template loadOp(v: IrValue, s: X64Reg): X64Reg =
    buf.loadOperandX64(alloc, v, spillSlotBias, s)

  template storeRes(v: IrValue, src: X64Reg) =
    buf.storeResultX64(alloc, v, src, spillSlotBias)

  # SIMD scratch templates (capture local vars; must be before case statement)
  template loadSimd(v: IrValue, xscratch: X64FReg): X64FReg =
    buf.loadSimdX64(alloc, v, spillSlotBias, xscratch)
  template storeSimd(v: IrValue, xsrc: X64FReg) =
    buf.storeSimdX64(alloc, v, xsrc, spillSlotBias)

  case instr.op

  # ---- Constants ----
  of irConst32:
    buf.movRegImm32(resReg, instr.imm.int32)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irConst64:
    buf.movImmX64(resReg, instr.imm)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  # ---- 32-bit arithmetic ----
  of irAdd32:
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.addRegReg32(resReg, b)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irSub32:
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.subRegReg32(resReg, b)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irMul32:
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.mulRegX6432(resReg, b)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irDiv32S:
    # CDQ + IDIV: dividend in rax, divisor must not be rax/rdx
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)   # use rcx as spill scratch
    if a != rTmpX: buf.movRegReg(rTmpX, a)
    buf.cdqX64()  # sign-extend eax into edx:eax
    # Ensure divisor is not rax or rdx
    let div32 = if b == rTmpX or b == rTmpZ: (buf.movRegReg(rTmpY, b); rTmpY) else: b
    buf.sdivRegX6432(div32)
    if resReg != rTmpX: buf.movRegReg(resReg, rTmpX)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irDiv32U:
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)
    if a != rTmpX: buf.movRegReg(rTmpX, a)
    buf.xorRegReg32(rTmpZ, rTmpZ)  # zero-extend: edx = 0
    let div32 = if b == rTmpX or b == rTmpZ: (buf.movRegReg(rTmpY, b); rTmpY) else: b
    buf.udivRegX6432(div32)
    if resReg != rTmpX: buf.movRegReg(resReg, rTmpX)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irRem32S:
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)
    if a != rTmpX: buf.movRegReg(rTmpX, a)
    buf.cdqX64()
    let div32 = if b == rTmpX or b == rTmpZ: (buf.movRegReg(rTmpY, b); rTmpY) else: b
    buf.sdivRegX6432(div32)
    if resReg != rTmpZ: buf.movRegReg(resReg, rTmpZ)  # remainder in rdx
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irRem32U:
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)
    if a != rTmpX: buf.movRegReg(rTmpX, a)
    buf.xorRegReg32(rTmpZ, rTmpZ)
    let div32 = if b == rTmpX or b == rTmpZ: (buf.movRegReg(rTmpY, b); rTmpY) else: b
    buf.udivRegX6432(div32)
    if resReg != rTmpZ: buf.movRegReg(resReg, rTmpZ)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irAnd32:
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.andRegReg32(resReg, b)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irOr32:
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.orRegReg32(resReg, b)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irXor32:
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.xorRegReg32(resReg, b)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irShl32:
    # SHL r32, CL — shift amount must be in rcx
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)
    if b != rTmpY: buf.movRegReg(rTmpY, b)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.shlRegX6432(resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irShr32U:
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)
    if b != rTmpY: buf.movRegReg(rTmpY, b)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.shrRegX6432(resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irShr32S:
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)
    if b != rTmpY: buf.movRegReg(rTmpY, b)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.sarRegX6432(resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irRotl32:
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)
    if b != rTmpY: buf.movRegReg(rTmpY, b)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.rolRegX6432(resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irRotr32:
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)
    if b != rTmpY: buf.movRegReg(rTmpY, b)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.rorRegX6432(resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irClz32:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.clzX64(resReg, a, rTmpY)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irCtz32:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.ctzX64(resReg, a, rTmpY)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irPopcnt32:
    # Use 64-bit POPCNT — upper 32 bits of i32 values are always 0, so result is identical
    let a = loadOp(instr.operands[0], rTmpX)
    buf.popcntX64(resReg, a)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irEqz32:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.testRegReg(a, a)
    buf.setccX64(x64condE, resReg)
    buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  # ---- 32-bit comparisons (→ 0/1) ----
  of irEq32:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.cmpRegReg32(a, b); buf.setccX64(x64condE, resReg); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irNe32:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.cmpRegReg32(a, b); buf.setccX64(x64condNE, resReg); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irLt32S:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.cmpRegReg32(a, b); buf.setccX64(x64condL, resReg); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irLt32U:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.cmpRegReg32(a, b); buf.setccX64(x64condB, resReg); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irGt32S:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.cmpRegReg32(a, b); buf.setccX64(x64condG, resReg); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irGt32U:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.cmpRegReg32(a, b); buf.setccX64(x64condA, resReg); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irLe32S:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.cmpRegReg32(a, b); buf.setccX64(x64condLE, resReg); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irLe32U:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.cmpRegReg32(a, b); buf.setccX64(x64condBE, resReg); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irGe32S:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.cmpRegReg32(a, b); buf.setccX64(x64condGE, resReg); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irGe32U:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.cmpRegReg32(a, b); buf.setccX64(x64condAE, resReg); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  # ---- 64-bit arithmetic ----
  of irAdd64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.addRegX64(resReg, b)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irSub64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.subRegX64(resReg, b)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irMul64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.mulRegX64(resReg, b)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irDiv64S:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    if a != rTmpX: buf.movRegReg(rTmpX, a)
    buf.cqoX64()
    let div64 = if b == rTmpX or b == rTmpZ: (buf.movRegReg(rTmpY, b); rTmpY) else: b
    buf.sdivRegX64(div64)
    if resReg != rTmpX: buf.movRegReg(resReg, rTmpX)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irDiv64U:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    if a != rTmpX: buf.movRegReg(rTmpX, a)
    buf.xorRegReg32(rTmpZ, rTmpZ)
    let div64 = if b == rTmpX or b == rTmpZ: (buf.movRegReg(rTmpY, b); rTmpY) else: b
    buf.udivRegX64(div64)
    if resReg != rTmpX: buf.movRegReg(resReg, rTmpX)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irRem64S:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    if a != rTmpX: buf.movRegReg(rTmpX, a)
    buf.cqoX64()
    let div64 = if b == rTmpX or b == rTmpZ: (buf.movRegReg(rTmpY, b); rTmpY) else: b
    buf.sdivRegX64(div64)
    if resReg != rTmpZ: buf.movRegReg(resReg, rTmpZ)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irRem64U:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    if a != rTmpX: buf.movRegReg(rTmpX, a)
    buf.xorRegReg32(rTmpZ, rTmpZ)
    let div64 = if b == rTmpX or b == rTmpZ: (buf.movRegReg(rTmpY, b); rTmpY) else: b
    buf.udivRegX64(div64)
    if resReg != rTmpZ: buf.movRegReg(resReg, rTmpZ)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irAnd64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.andRegX64(resReg, b)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irOr64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.orRegX64(resReg, b)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irXor64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.xorRegX64(resReg, b)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irShl64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    if b != rTmpY: buf.movRegReg(rTmpY, b)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.shlRegX64(resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irShr64U:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    if b != rTmpY: buf.movRegReg(rTmpY, b)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.shrRegX64(resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irShr64S:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    if b != rTmpY: buf.movRegReg(rTmpY, b)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.sarRegX64(resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irRotl64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    if b != rTmpY: buf.movRegReg(rTmpY, b)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.rolRegX64(resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irRotr64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    if b != rTmpY: buf.movRegReg(rTmpY, b)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.rorRegX64(resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irClz64:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.clzX64(resReg, a, rTmpY)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irCtz64:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.ctzX64(resReg, a, rTmpY)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irPopcnt64:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.popcntX64(resReg, a)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irEqz64:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.testRegReg(a, a)
    buf.setccX64(x64condE, resReg); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  # ---- 64-bit comparisons ----
  of irEq64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.cmpRegReg(a, b); buf.setccX64(x64condE, resReg); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irNe64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.cmpRegReg(a, b); buf.setccX64(x64condNE, resReg); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irLt64S:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.cmpRegReg(a, b); buf.setccX64(x64condL, resReg); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irLt64U:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.cmpRegReg(a, b); buf.setccX64(x64condB, resReg); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irGt64S:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.cmpRegReg(a, b); buf.setccX64(x64condG, resReg); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irGt64U:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.cmpRegReg(a, b); buf.setccX64(x64condA, resReg); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irLe64S:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.cmpRegReg(a, b); buf.setccX64(x64condLE, resReg); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irLe64U:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.cmpRegReg(a, b); buf.setccX64(x64condBE, resReg); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irGe64S:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.cmpRegReg(a, b); buf.setccX64(x64condGE, resReg); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irGe64U:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.cmpRegReg(a, b); buf.setccX64(x64condAE, resReg); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  # ---- Type conversions ----
  of irWrapI64:
    # i64→i32: just zero the upper 32 bits (move 32-bit form zero-extends to 64)
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movRegReg32(resReg, a)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irExtendI32S:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movsxd(resReg, a)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irExtendI32U:
    # Zero-extend i32→i64: 32-bit MOV clears upper 32 bits automatically
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movRegReg32(resReg, a)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irExtend8S32:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movsxb(resReg, a)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irExtend16S32:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movsxw(resReg, a)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irExtend8S64:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movsxb(resReg, a)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irExtend16S64:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movsxw(resReg, a)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irExtend32S64:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movsxd(resReg, a)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  # ---- Scalar floating-point (SSE2/SSE4.1) ----
  # Float values live in GP registers as bit-patterns. XMM0-XMM2 are
  # ephemeral scratch registers used only within each case arm.

  of irConstF32:
    # imm stores cast[int32](f32val).int64 — load as 32-bit zero-extending
    buf.movRegImm32(resReg, instr.imm.int32)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irConstF64:
    buf.movImmX64(resReg, instr.imm)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  # ---- f32 binary arithmetic ----
  of irAddF32:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movdFromGp32(xmm0, a); buf.movdFromGp32(xmm1, b)
    buf.addss(xmm0, xmm1); buf.movdToGp32(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irSubF32:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movdFromGp32(xmm0, a); buf.movdFromGp32(xmm1, b)
    buf.subss(xmm0, xmm1); buf.movdToGp32(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irMulF32:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movdFromGp32(xmm0, a); buf.movdFromGp32(xmm1, b)
    buf.mulss(xmm0, xmm1); buf.movdToGp32(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irDivF32:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movdFromGp32(xmm0, a); buf.movdFromGp32(xmm1, b)
    buf.divss(xmm0, xmm1); buf.movdToGp32(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irSqrtF32:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movdFromGp32(xmm0, a); buf.sqrtss(xmm0, xmm0); buf.movdToGp32(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irMinF32:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movdFromGp32(xmm0, a); buf.movdFromGp32(xmm1, b)
    buf.minss(xmm0, xmm1); buf.movdToGp32(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irMaxF32:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movdFromGp32(xmm0, a); buf.movdFromGp32(xmm1, b)
    buf.maxss(xmm0, xmm1); buf.movdToGp32(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  # ---- f32 unary ----
  of irAbsF32:
    # Clear sign bit via integer AND with 0x7FFFFFFF
    let a = loadOp(instr.operands[0], rTmpX)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.andRegImm32(resReg, 0x7FFFFFFF'i32)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irNegF32:
    # Flip sign bit via XOR with 0x80000000 (use movabs for zero-extension)
    let a = loadOp(instr.operands[0], rTmpX)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.movRegImm64(rTmpY, 0x80000000'u64)
    buf.xorRegX64(resReg, rTmpY)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irCopysignF32:
    # result = (a & 0x7FFFFFFF) | (b & 0x80000000)
    let aReg = loadOp(instr.operands[0], rTmpX)
    if aReg != rTmpX: buf.movRegReg(rTmpX, aReg)
    let bReg = loadOp(instr.operands[1], rTmpY)
    if bReg != rTmpY: buf.movRegReg(rTmpY, bReg)
    buf.andRegImm32(rTmpX, 0x7FFFFFFF'i32)   # rTmpX = a & ~signBit
    buf.movRegImm64(rTmpZ, 0x80000000'u64)
    buf.andRegX64(rTmpY, rTmpZ)              # rTmpY = b & signBit
    buf.orRegX64(rTmpX, rTmpY)
    if resReg != rTmpX: buf.movRegReg(resReg, rTmpX)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  # ---- f32 rounding (SSE4.1 ROUNDSS) ----
  of irCeilF32:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movdFromGp32(xmm0, a); buf.roundss(xmm0, xmm0, 2); buf.movdToGp32(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irFloorF32:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movdFromGp32(xmm0, a); buf.roundss(xmm0, xmm0, 1); buf.movdToGp32(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irTruncF32:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movdFromGp32(xmm0, a); buf.roundss(xmm0, xmm0, 3); buf.movdToGp32(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irNearestF32:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movdFromGp32(xmm0, a); buf.roundss(xmm0, xmm0, 0); buf.movdToGp32(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  # ---- f32 comparisons ----
  # UCOMISS sets: ZF=1,PF=1,CF=1 if unordered; ZF=1,PF=0 if eq; CF=1,PF=0 if lt; else gt

  of irEqF32:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movdFromGp32(xmm0, a); buf.movdFromGp32(xmm1, b); buf.ucomiss(xmm0, xmm1)
    buf.setccX64(x64condE,  resReg); buf.setccX64(x64condNP, rTmpY)  # ZF=1 AND PF=0
    buf.andRegReg32(resReg, rTmpY); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irNeF32:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movdFromGp32(xmm0, a); buf.movdFromGp32(xmm1, b); buf.ucomiss(xmm0, xmm1)
    buf.setccX64(x64condNE, resReg); buf.setccX64(x64condP, rTmpY)   # ZF=0 OR PF=1
    buf.orRegReg32(resReg, rTmpY); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irLtF32:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movdFromGp32(xmm0, a); buf.movdFromGp32(xmm1, b); buf.ucomiss(xmm0, xmm1)
    buf.setccX64(x64condB,  resReg); buf.setccX64(x64condNP, rTmpY)  # CF=1 AND PF=0
    buf.andRegReg32(resReg, rTmpY); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irGtF32:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movdFromGp32(xmm0, a); buf.movdFromGp32(xmm1, b); buf.ucomiss(xmm0, xmm1)
    buf.setccX64(x64condA,  resReg); buf.setccX64(x64condNP, rTmpY)  # CF=0,ZF=0,PF=0
    buf.andRegReg32(resReg, rTmpY); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irLeF32:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movdFromGp32(xmm0, a); buf.movdFromGp32(xmm1, b); buf.ucomiss(xmm0, xmm1)
    buf.setccX64(x64condBE, resReg); buf.setccX64(x64condNP, rTmpY)  # (CF|ZF)=1 AND PF=0
    buf.andRegReg32(resReg, rTmpY); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irGeF32:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movdFromGp32(xmm0, a); buf.movdFromGp32(xmm1, b); buf.ucomiss(xmm0, xmm1)
    buf.setccX64(x64condAE, resReg); buf.setccX64(x64condNP, rTmpY)  # CF=0 AND PF=0
    buf.andRegReg32(resReg, rTmpY); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  # ---- f64 binary arithmetic ----
  of irAddF64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movqFromGp64(xmm0, a); buf.movqFromGp64(xmm1, b)
    buf.addsd(xmm0, xmm1); buf.movqToGp64(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irSubF64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movqFromGp64(xmm0, a); buf.movqFromGp64(xmm1, b)
    buf.subsd(xmm0, xmm1); buf.movqToGp64(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irMulF64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movqFromGp64(xmm0, a); buf.movqFromGp64(xmm1, b)
    buf.mulsd(xmm0, xmm1); buf.movqToGp64(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irDivF64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movqFromGp64(xmm0, a); buf.movqFromGp64(xmm1, b)
    buf.divsd(xmm0, xmm1); buf.movqToGp64(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irSqrtF64:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movqFromGp64(xmm0, a); buf.sqrtsd(xmm0, xmm0); buf.movqToGp64(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irMinF64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movqFromGp64(xmm0, a); buf.movqFromGp64(xmm1, b)
    buf.minsd(xmm0, xmm1); buf.movqToGp64(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irMaxF64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movqFromGp64(xmm0, a); buf.movqFromGp64(xmm1, b)
    buf.maxsd(xmm0, xmm1); buf.movqToGp64(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  # ---- f64 unary ----
  of irAbsF64:
    let a = loadOp(instr.operands[0], rTmpX)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.movRegImm64(rTmpY, 0x7FFFFFFFFFFFFFFF'u64)
    buf.andRegX64(resReg, rTmpY)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irNegF64:
    let a = loadOp(instr.operands[0], rTmpX)
    if resReg != a: buf.movRegReg(resReg, a)
    buf.movRegImm64(rTmpY, 0x8000000000000000'u64)
    buf.xorRegX64(resReg, rTmpY)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irCopysignF64:
    let aReg = loadOp(instr.operands[0], rTmpX)
    if aReg != rTmpX: buf.movRegReg(rTmpX, aReg)
    let bReg = loadOp(instr.operands[1], rTmpY)
    if bReg != rTmpY: buf.movRegReg(rTmpY, bReg)
    buf.movRegImm64(rTmpZ, 0x7FFFFFFFFFFFFFFF'u64)
    buf.andRegX64(rTmpX, rTmpZ)
    buf.movRegImm64(rTmpZ, 0x8000000000000000'u64)
    buf.andRegX64(rTmpY, rTmpZ)
    buf.orRegX64(rTmpX, rTmpY)
    if resReg != rTmpX: buf.movRegReg(resReg, rTmpX)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  # ---- f64 rounding (SSE4.1 ROUNDSD) ----
  of irCeilF64:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movqFromGp64(xmm0, a); buf.roundsd(xmm0, xmm0, 2); buf.movqToGp64(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irFloorF64:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movqFromGp64(xmm0, a); buf.roundsd(xmm0, xmm0, 1); buf.movqToGp64(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irTruncF64:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movqFromGp64(xmm0, a); buf.roundsd(xmm0, xmm0, 3); buf.movqToGp64(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irNearestF64:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movqFromGp64(xmm0, a); buf.roundsd(xmm0, xmm0, 0); buf.movqToGp64(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  # ---- f64 comparisons ----
  of irEqF64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movqFromGp64(xmm0, a); buf.movqFromGp64(xmm1, b); buf.ucomisd(xmm0, xmm1)
    buf.setccX64(x64condE,  resReg); buf.setccX64(x64condNP, rTmpY)
    buf.andRegReg32(resReg, rTmpY); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irNeF64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movqFromGp64(xmm0, a); buf.movqFromGp64(xmm1, b); buf.ucomisd(xmm0, xmm1)
    buf.setccX64(x64condNE, resReg); buf.setccX64(x64condP, rTmpY)
    buf.orRegReg32(resReg, rTmpY); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irLtF64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movqFromGp64(xmm0, a); buf.movqFromGp64(xmm1, b); buf.ucomisd(xmm0, xmm1)
    buf.setccX64(x64condB,  resReg); buf.setccX64(x64condNP, rTmpY)
    buf.andRegReg32(resReg, rTmpY); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irGtF64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movqFromGp64(xmm0, a); buf.movqFromGp64(xmm1, b); buf.ucomisd(xmm0, xmm1)
    buf.setccX64(x64condA,  resReg); buf.setccX64(x64condNP, rTmpY)
    buf.andRegReg32(resReg, rTmpY); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irLeF64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movqFromGp64(xmm0, a); buf.movqFromGp64(xmm1, b); buf.ucomisd(xmm0, xmm1)
    buf.setccX64(x64condBE, resReg); buf.setccX64(x64condNP, rTmpY)
    buf.andRegReg32(resReg, rTmpY); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irGeF64:
    let a = loadOp(instr.operands[0], rTmpX); let b = loadOp(instr.operands[1], rTmpY)
    buf.movqFromGp64(xmm0, a); buf.movqFromGp64(xmm1, b); buf.ucomisd(xmm0, xmm1)
    buf.setccX64(x64condAE, resReg); buf.setccX64(x64condNP, rTmpY)
    buf.andRegReg32(resReg, rTmpY); buf.movzxb(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  # ---- Int → Float conversions ----

  of irF32ConvertI32S:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.cvtsi2ss32(xmm0, a); buf.movdToGp32(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irF32ConvertI32U:
    # i32 unsigned: stored zero-extended → treat as non-negative i64
    let a = loadOp(instr.operands[0], rTmpX)
    buf.cvtsi2ss64(xmm0, a); buf.movdToGp32(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irF32ConvertI64S:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.cvtsi2ss64(xmm0, a); buf.movdToGp32(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irF32ConvertI64U:
    # i64 unsigned: if sign bit clear, direct; else halve + set LSB, convert, double
    let a = loadOp(instr.operands[0], rTmpX)
    if a != rTmpX: buf.movRegReg(rTmpX, a)
    buf.testRegReg(rTmpX, rTmpX)
    let jccPos = buf.len
    buf.jccRel8(x64condNS, 0)             # patched: jump to direct convert if val < 2^63
    buf.movRegReg(rTmpY, rTmpX)
    buf.shrRegImm(rTmpY, 1)
    buf.andRegImm32(rTmpX, 1)
    buf.orRegX64(rTmpY, rTmpX)
    buf.cvtsi2ss64(xmm0, rTmpY)
    buf.addss(xmm0, xmm0)
    let jmpPos = buf.len
    buf.jmpRel8(0)                         # patched: jump past direct convert
    buf.code[jccPos + 1] = byte(buf.len - (jccPos + 2))  # patch NS jump → here
    buf.cvtsi2ss64(xmm0, rTmpX)           # rTmpX still holds original a (NS path jumped here)
    buf.code[jmpPos + 1] = byte(buf.len - (jmpPos + 2))  # patch jmp → done
    buf.movdToGp32(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irF64ConvertI32S:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.cvtsi2sd32(xmm0, a); buf.movqToGp64(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irF64ConvertI32U:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.cvtsi2sd64(xmm0, a); buf.movqToGp64(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irF64ConvertI64S:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.cvtsi2sd64(xmm0, a); buf.movqToGp64(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irF64ConvertI64U:
    let a = loadOp(instr.operands[0], rTmpX)
    if a != rTmpX: buf.movRegReg(rTmpX, a)
    buf.testRegReg(rTmpX, rTmpX)
    let jccPos64 = buf.len
    buf.jccRel8(x64condNS, 0)
    buf.movRegReg(rTmpY, rTmpX)
    buf.shrRegImm(rTmpY, 1)
    buf.andRegImm32(rTmpX, 1)
    buf.orRegX64(rTmpY, rTmpX)
    buf.cvtsi2sd64(xmm0, rTmpY)
    buf.addsd(xmm0, xmm0)
    let jmpPos64 = buf.len
    buf.jmpRel8(0)
    buf.code[jccPos64 + 1] = byte(buf.len - (jccPos64 + 2))
    buf.cvtsi2sd64(xmm0, rTmpX)
    buf.code[jmpPos64 + 1] = byte(buf.len - (jmpPos64 + 2))
    buf.movqToGp64(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  # ---- Float → Int truncation ----

  of irI32TruncF32S:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movdFromGp32(xmm0, a); buf.cvttss2si32(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irI32TruncF32U:
    # Use 64-bit output so [0, 2^32) maps to non-negative i64, then truncate
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movdFromGp32(xmm0, a); buf.cvttss2si64(resReg, xmm0)
    buf.movRegReg32(resReg, resReg)  # zero-extend to 64 to clear upper bits
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irI32TruncF64S:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movqFromGp64(xmm0, a); buf.cvttsd2si32(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irI32TruncF64U:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movqFromGp64(xmm0, a); buf.cvttsd2si64(resReg, xmm0)
    buf.movRegReg32(resReg, resReg)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irI64TruncF32S:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movdFromGp32(xmm0, a); buf.cvttss2si64(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irI64TruncF32U:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movdFromGp32(xmm0, a); buf.cvttss2si64(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irI64TruncF64S:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movqFromGp64(xmm0, a); buf.cvttsd2si64(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irI64TruncF64U:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movqFromGp64(xmm0, a); buf.cvttsd2si64(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  # ---- Float promotions / demotions ----

  of irF32DemoteF64:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movqFromGp64(xmm0, a); buf.cvtsd2ss(xmm0, xmm0); buf.movdToGp32(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irF64PromoteF32:
    let a = loadOp(instr.operands[0], rTmpX)
    buf.movdFromGp32(xmm0, a); buf.cvtss2sd(xmm0, xmm0); buf.movqToGp64(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  # ---- Reinterpret (bit-identical, no conversion) ----

  of irI32ReinterpretF32, irF32ReinterpretI32:
    let a = loadOp(instr.operands[0], rTmpX)
    if resReg != a: buf.movRegReg(resReg, a)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irI64ReinterpretF64, irF64ReinterpretI64:
    let a = loadOp(instr.operands[0], rTmpX)
    if resReg != a: buf.movRegReg(resReg, a)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  # ---- FMA (emulated: no hardware FMA guarantee, accepts double-rounding) ----

  of irFmaF32:   # a*b + c
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)
    let c = loadOp(instr.operands[2], rTmpZ)
    buf.movdFromGp32(xmm0, a); buf.movdFromGp32(xmm1, b); buf.movdFromGp32(xmm2, c)
    buf.mulss(xmm0, xmm1); buf.addss(xmm0, xmm2); buf.movdToGp32(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irFmsF32:   # a*b - c
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)
    let c = loadOp(instr.operands[2], rTmpZ)
    buf.movdFromGp32(xmm0, a); buf.movdFromGp32(xmm1, b); buf.movdFromGp32(xmm2, c)
    buf.mulss(xmm0, xmm1); buf.subss(xmm0, xmm2); buf.movdToGp32(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irFnmaF32:  # -(a*b) + c  =  c - a*b
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)
    let c = loadOp(instr.operands[2], rTmpZ)
    buf.movdFromGp32(xmm0, a); buf.movdFromGp32(xmm1, b); buf.movdFromGp32(xmm2, c)
    buf.mulss(xmm0, xmm1); buf.subss(xmm2, xmm0); buf.movdToGp32(resReg, xmm2)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irFnmsF32:  # -(a*b) - c  =  -(a*b + c)
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)
    let c = loadOp(instr.operands[2], rTmpZ)
    buf.movdFromGp32(xmm0, a); buf.movdFromGp32(xmm1, b); buf.movdFromGp32(xmm2, c)
    buf.mulss(xmm0, xmm1); buf.addss(xmm0, xmm2)
    # negate: XOR with 0x80000000 via GP
    buf.movdToGp32(resReg, xmm0)
    buf.movRegImm64(rTmpY, 0x80000000'u64); buf.xorRegX64(resReg, rTmpY)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irFmaF64:
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)
    let c = loadOp(instr.operands[2], rTmpZ)
    buf.movqFromGp64(xmm0, a); buf.movqFromGp64(xmm1, b); buf.movqFromGp64(xmm2, c)
    buf.mulsd(xmm0, xmm1); buf.addsd(xmm0, xmm2); buf.movqToGp64(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irFmsF64:
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)
    let c = loadOp(instr.operands[2], rTmpZ)
    buf.movqFromGp64(xmm0, a); buf.movqFromGp64(xmm1, b); buf.movqFromGp64(xmm2, c)
    buf.mulsd(xmm0, xmm1); buf.subsd(xmm0, xmm2); buf.movqToGp64(resReg, xmm0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irFnmaF64:
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)
    let c = loadOp(instr.operands[2], rTmpZ)
    buf.movqFromGp64(xmm0, a); buf.movqFromGp64(xmm1, b); buf.movqFromGp64(xmm2, c)
    buf.mulsd(xmm0, xmm1); buf.subsd(xmm2, xmm0); buf.movqToGp64(resReg, xmm2)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irFnmsF64:
    let a = loadOp(instr.operands[0], rTmpX)
    let b = loadOp(instr.operands[1], rTmpY)
    let c = loadOp(instr.operands[2], rTmpZ)
    buf.movqFromGp64(xmm0, a); buf.movqFromGp64(xmm1, b); buf.movqFromGp64(xmm2, c)
    buf.mulsd(xmm0, xmm1); buf.addsd(xmm0, xmm2)
    buf.movqToGp64(resReg, xmm0)
    buf.movRegImm64(rTmpY, 0x8000000000000000'u64); buf.xorRegX64(resReg, rTmpY)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  # ---- Float memory operations (same layout as int loads/stores) ----

  of irLoadF32:
    let addrVal = loadOp(instr.operands[0], rTmpX)
    let memOff = instr.imm2.int32
    if memOff != 0: buf.movRegReg(rTmpX, addrVal); buf.addImmX64(rTmpX, memOff)
    elif addrVal != rTmpX: buf.movRegReg(rTmpX, addrVal)
    buf.emitBoundsCheckX64(rTmpX, 4)
    buf.addRegReg(rTmpX, rWMem)
    buf.movRegMem32(resReg, rTmpX, 0)   # zero-extends to 64
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irLoadF64:
    let addrVal = loadOp(instr.operands[0], rTmpX)
    let memOff = instr.imm2.int32
    if memOff != 0: buf.movRegReg(rTmpX, addrVal); buf.addImmX64(rTmpX, memOff)
    elif addrVal != rTmpX: buf.movRegReg(rTmpX, addrVal)
    buf.emitBoundsCheckX64(rTmpX, 8)
    buf.addRegReg(rTmpX, rWMem)
    buf.movRegMem(resReg, rTmpX, 0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irStoreF32:
    let addrVal = loadOp(instr.operands[0], rTmpX)
    let valOp   = loadOp(instr.operands[1], rTmpY)
    let memOff = instr.imm2.int32
    if memOff != 0: buf.movRegReg(rTmpX, addrVal); buf.addImmX64(rTmpX, memOff)
    elif addrVal != rTmpX: buf.movRegReg(rTmpX, addrVal)
    buf.emitBoundsCheckX64(rTmpX, 4)
    buf.addRegReg(rTmpX, rWMem)
    buf.movMemReg32(rTmpX, 0, valOp)

  of irStoreF64:
    let addrVal = loadOp(instr.operands[0], rTmpX)
    let valOp   = loadOp(instr.operands[1], rTmpY)
    let memOff = instr.imm2.int32
    if memOff != 0: buf.movRegReg(rTmpX, addrVal); buf.addImmX64(rTmpX, memOff)
    elif addrVal != rTmpX: buf.movRegReg(rTmpX, addrVal)
    buf.emitBoundsCheckX64(rTmpX, 8)
    buf.addRegReg(rTmpX, rWMem)
    buf.movMemReg(rTmpX, 0, valOp)

  # ---- SIMD v128 (SSE2 / SSSE3 / SSE4.1) ----
  # All v128 values are kept in memory (spill slots); xmm0-xmm2 are used as
  # scratch for computations.  Requires SSE4.1 (lane insert/extract), SSSE3
  # (abs, pmullw-like), and SSE2 for the core set.
  of irLoadV128:
    let addrVal = loadOp(instr.operands[0], rTmpX)
    let memOff = instr.imm2.int32
    if memOff != 0: buf.movRegReg(rTmpX, addrVal); buf.addImmX64(rTmpX, memOff)
    elif addrVal != rTmpX: buf.movRegReg(rTmpX, addrVal)
    buf.emitBoundsCheckX64(rTmpX, 16)
    buf.addRegReg(rTmpX, rWMem)
    buf.movdquLoad(xSimd0, rTmpX, 0)
    storeSimd(res, xSimd0)

  of irStoreV128:
    let addrVal = loadOp(instr.operands[0], rTmpX)
    let memOff = instr.imm2.int32
    if memOff != 0: buf.movRegReg(rTmpX, addrVal); buf.addImmX64(rTmpX, memOff)
    elif addrVal != rTmpX: buf.movRegReg(rTmpX, addrVal)
    buf.emitBoundsCheckX64(rTmpX, 16)
    buf.addRegReg(rTmpX, rWMem)
    let vsrc = loadSimd(instr.operands[1], xSimd0)
    buf.movdquStore(rTmpX, 0, vsrc)

  of irConstV128:
    let idx = instr.imm.int
    if idx < f.v128Consts.len:
      buf.emitV128ConstX64(xSimd0, f.v128Consts[idx])
    else:
      buf.pxorRR(xSimd0, xSimd0)  # fallback: zero
    storeSimd(res, xSimd0)

  # ---- Splats ----
  of irI32x4Splat, irF32x4Splat:
    let src = loadOp(instr.operands[0], rTmpX)
    buf.movdToXmm(xSimd0, src)
    buf.pshufdRRI(xSimd0, xSimd0, 0x00)  # broadcast lane 0 to all 4 lanes
    storeSimd(res, xSimd0)

  of irI8x16Splat:
    # Broadcast low byte: MOVD; PUNPCKLBW (interleave with itself); PSHUFD
    let src = loadOp(instr.operands[0], rTmpX)
    buf.movdToXmm(xSimd0, src)
    buf.punpcklbwRR(xSimd0, xSimd0)  # expand bytes → words
    buf.punpcklwdRR(xSimd0, xSimd0)  # expand words → dwords
    buf.pshufdRRI(xSimd0, xSimd0, 0x00)  # broadcast dword 0 to all 4
    storeSimd(res, xSimd0)

  of irI16x8Splat:
    let src = loadOp(instr.operands[0], rTmpX)
    buf.movdToXmm(xSimd0, src)
    buf.punpcklwdRR(xSimd0, xSimd0)  # expand word → dword
    buf.pshufdRRI(xSimd0, xSimd0, 0x00)  # broadcast dword 0 to all 4
    storeSimd(res, xSimd0)

  of irI64x2Splat, irF64x2Splat:
    let src = loadOp(instr.operands[0], rTmpX)
    buf.movqToXmm(xSimd0, src)
    buf.pshufdRRI(xSimd0, xSimd0, 0x44)  # copy low 64-bit to high 64-bit
    storeSimd(res, xSimd0)

  # ---- Lane extract → GP ----
  of irI32x4ExtractLane, irF32x4ExtractLane:
    let vsrc = loadSimd(instr.operands[0], xSimd0)
    buf.pextrdRR(resReg, vsrc, instr.imm.byte)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irI8x16ExtractLaneU:
    let vsrc = loadSimd(instr.operands[0], xSimd0)
    buf.pextrb(resReg, vsrc, instr.imm.byte)
    buf.movzxb(resReg, resReg)  # zero-extend to 64-bit
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irI8x16ExtractLaneS:
    let vsrc = loadSimd(instr.operands[0], xSimd0)
    buf.pextrb(resReg, vsrc, instr.imm.byte)
    buf.movsx32(resReg, resReg)  # sign-extend byte → 32-bit (then 64-bit)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irI16x8ExtractLaneU:
    let vsrc = loadSimd(instr.operands[0], xSimd0)
    buf.pextrw(resReg, vsrc, instr.imm.byte)
    buf.movzxw(resReg, resReg)  # zero-extend word → 64-bit
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irI16x8ExtractLaneS:
    let vsrc = loadSimd(instr.operands[0], xSimd0)
    buf.pextrw(resReg, vsrc, instr.imm.byte)
    buf.movsxw32(resReg, resReg)  # sign-extend word → 32-bit
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irI64x2ExtractLane, irF64x2ExtractLane:
    let vsrc = loadSimd(instr.operands[0], xSimd0)
    buf.pextrqRR(resReg, vsrc, instr.imm.byte)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  # ---- Lane replace (v128, scalar) → v128 ----
  of irI32x4ReplaceLane, irF32x4ReplaceLane:
    let vsrc = loadSimd(instr.operands[0], xSimd0)
    let newVal = loadOp(instr.operands[1], rTmpX)
    buf.movdqaRR(xSimd1, vsrc)
    buf.pinsrdRR(xSimd1, newVal, instr.imm.byte)
    storeSimd(res, xSimd1)

  of irI8x16ReplaceLane:
    let vsrc = loadSimd(instr.operands[0], xSimd0)
    let newVal = loadOp(instr.operands[1], rTmpX)
    buf.movdqaRR(xSimd1, vsrc)
    buf.pinsrb(xSimd1, newVal, instr.imm.byte)
    storeSimd(res, xSimd1)

  of irI16x8ReplaceLane:
    let vsrc = loadSimd(instr.operands[0], xSimd0)
    let newVal = loadOp(instr.operands[1], rTmpX)
    buf.movdqaRR(xSimd1, vsrc)
    buf.pinsrw(xSimd1, newVal, instr.imm.byte)
    storeSimd(res, xSimd1)

  of irI64x2ReplaceLane, irF64x2ReplaceLane:
    let vsrc = loadSimd(instr.operands[0], xSimd0)
    let newVal = loadOp(instr.operands[1], rTmpX)
    buf.movdqaRR(xSimd1, vsrc)
    buf.pinsrqRR(xSimd1, newVal, instr.imm.byte)
    storeSimd(res, xSimd1)

  # ---- v128 bitwise ----
  of irV128Not:
    let va = loadSimd(instr.operands[0], xSimd0)
    buf.movdqaRR(xSimd1, va)
    buf.pcmpeqdRR(xSimd2, xSimd2)  # all-ones
    buf.pxorRR(xSimd1, xSimd2)   # xSimd1 = ~va
    storeSimd(res, xSimd1)

  of irV128And:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va)
    buf.pandRR(xSimd2, vb)
    storeSimd(res, xSimd2)

  of irV128Or:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va)
    buf.porRR(xSimd2, vb)
    storeSimd(res, xSimd2)

  of irV128Xor:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va)
    buf.pxorRR(xSimd2, vb)
    storeSimd(res, xSimd2)

  of irV128AndNot:
    # WASM andnot(a, b) = a & ~b.  PANDN(dst, src) = ~dst & src.
    # So: movdqa xSimd2, b; pandn xSimd2, a → xSimd2 = ~b & a.
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, vb)
    buf.pandnRR(xSimd2, va)
    storeSimd(res, xSimd2)

  # ---- i8x16 arithmetic ----
  of irI8x16Abs:
    let va = loadSimd(instr.operands[0], xSimd0)
    buf.movdqaRR(xSimd1, va); buf.pabsbRR(xSimd1, va)
    storeSimd(res, xSimd1)

  of irI8x16Neg:
    let va = loadSimd(instr.operands[0], xSimd0)
    buf.pxorRR(xSimd1, xSimd1)   # zero
    buf.psubbRR(xSimd1, va)       # xSimd1 = 0 - va
    storeSimd(res, xSimd1)

  of irI8x16Add:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.paddbRR(xSimd2, vb)
    storeSimd(res, xSimd2)

  of irI8x16Sub:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.psubbRR(xSimd2, vb)
    storeSimd(res, xSimd2)

  of irI8x16MinS:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.pminsb(xSimd2, vb)
    storeSimd(res, xSimd2)

  of irI8x16MinU:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.pminubRR(xSimd2, vb)
    storeSimd(res, xSimd2)

  of irI8x16MaxS:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.pmaxsb(xSimd2, vb)
    storeSimd(res, xSimd2)

  of irI8x16MaxU:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.pmaxubRR(xSimd2, vb)
    storeSimd(res, xSimd2)

  # ---- i16x8 arithmetic ----
  of irI16x8Abs:
    let va = loadSimd(instr.operands[0], xSimd0)
    buf.movdqaRR(xSimd1, va); buf.pabswRR(xSimd1, va)
    storeSimd(res, xSimd1)

  of irI16x8Neg:
    let va = loadSimd(instr.operands[0], xSimd0)
    buf.pxorRR(xSimd1, xSimd1); buf.psubwRR(xSimd1, va)
    storeSimd(res, xSimd1)

  of irI16x8Add:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.paddwRR(xSimd2, vb)
    storeSimd(res, xSimd2)

  of irI16x8Sub:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.psubwRR(xSimd2, vb)
    storeSimd(res, xSimd2)

  of irI16x8Mul:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.pmullwRR(xSimd2, vb)
    storeSimd(res, xSimd2)

  # ---- i32x4 arithmetic ----
  of irI32x4Abs:
    let va = loadSimd(instr.operands[0], xSimd0)
    buf.movdqaRR(xSimd1, va); buf.pabsdRR(xSimd1, va)
    storeSimd(res, xSimd1)

  of irI32x4Neg:
    let va = loadSimd(instr.operands[0], xSimd0)
    buf.pxorRR(xSimd1, xSimd1); buf.psubdRR(xSimd1, va)
    storeSimd(res, xSimd1)

  of irI32x4Add:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.padddRR(xSimd2, vb)
    storeSimd(res, xSimd2)

  of irI32x4Sub:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.psubdRR(xSimd2, vb)
    storeSimd(res, xSimd2)

  of irI32x4Mul:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.pmulldRR(xSimd2, vb)  # SSE4.1
    storeSimd(res, xSimd2)

  of irI32x4MinS:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.pminsdRR(xSimd2, vb)  # SSE4.1
    storeSimd(res, xSimd2)

  of irI32x4MinU:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.pminudRR(xSimd2, vb)  # SSE4.1
    storeSimd(res, xSimd2)

  of irI32x4MaxS:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.pmaxsdRR(xSimd2, vb)  # SSE4.1
    storeSimd(res, xSimd2)

  of irI32x4MaxU:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.pmaxudRR(xSimd2, vb)  # SSE4.1
    storeSimd(res, xSimd2)

  of irI32x4Shl:
    # WASM i32x4.shl(vec, count): shift all 4 i32 lanes left by (count & 31)
    let va = loadSimd(instr.operands[0], xSimd0)
    let cnt = loadOp(instr.operands[1], rTmpX)
    if cnt != rTmpX: buf.movRegReg(rTmpX, cnt)
    buf.emitI32x4Shift(xSimd2, va, rTmpX, xSimd1, isShr=false, isSigned=false)
    storeSimd(res, xSimd2)

  of irI32x4ShrS:
    let va = loadSimd(instr.operands[0], xSimd0)
    let cnt = loadOp(instr.operands[1], rTmpX)
    if cnt != rTmpX: buf.movRegReg(rTmpX, cnt)
    buf.emitI32x4Shift(xSimd2, va, rTmpX, xSimd1, isShr=true, isSigned=true)
    storeSimd(res, xSimd2)

  of irI32x4ShrU:
    let va = loadSimd(instr.operands[0], xSimd0)
    let cnt = loadOp(instr.operands[1], rTmpX)
    if cnt != rTmpX: buf.movRegReg(rTmpX, cnt)
    buf.emitI32x4Shift(xSimd2, va, rTmpX, xSimd1, isShr=true, isSigned=false)
    storeSimd(res, xSimd2)

  # ---- i64x2 arithmetic ----
  of irI64x2Add:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.paddqRR(xSimd2, vb)
    storeSimd(res, xSimd2)

  of irI64x2Sub:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.psubqRR(xSimd2, vb)
    storeSimd(res, xSimd2)

  # ---- f32x4 ----
  of irF32x4Add:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.addpsRR(xSimd2, vb)
    storeSimd(res, xSimd2)

  of irF32x4Sub:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.subpsRR(xSimd2, vb)
    storeSimd(res, xSimd2)

  of irF32x4Mul:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.mulpsRR(xSimd2, vb)
    storeSimd(res, xSimd2)

  of irF32x4Div:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.divpsRR(xSimd2, vb)
    storeSimd(res, xSimd2)

  of irF32x4Abs:
    # abs = AND with 0x7FFFFFFF mask in all lanes
    let va = loadSimd(instr.operands[0], xSimd0)
    buf.movImmX64(rTmpX, 0x7FFFFFFF_7FFFFFFF'i64)
    buf.movqToXmm(xSimd1, rTmpX)
    buf.pshufdRRI(xSimd1, xSimd1, 0x44)   # broadcast to both 64-bit halves
    buf.movdqaRR(xSimd2, va)
    buf.pandRR(xSimd2, xSimd1)
    storeSimd(res, xSimd2)

  of irF32x4Neg:
    # neg = XOR with 0x80000000 sign mask in all lanes
    let va = loadSimd(instr.operands[0], xSimd0)
    buf.movImmX64(rTmpX, cast[int64](0x80000000_80000000'u64))
    buf.movqToXmm(xSimd1, rTmpX)
    buf.pshufdRRI(xSimd1, xSimd1, 0x44)
    buf.movdqaRR(xSimd2, va)
    buf.xorpsRR(xSimd2, xSimd1)
    storeSimd(res, xSimd2)

  # ---- f64x2 ----
  of irF64x2Add:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.addpdRR(xSimd2, vb)
    storeSimd(res, xSimd2)

  of irF64x2Sub:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.subpdRR(xSimd2, vb)
    storeSimd(res, xSimd2)

  of irF64x2Mul:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.mulpdRR(xSimd2, vb)
    storeSimd(res, xSimd2)

  of irF64x2Div:
    let va = loadSimd(instr.operands[0], xSimd0)
    let vb = loadSimd(instr.operands[1], xSimd1)
    buf.movdqaRR(xSimd2, va); buf.divpdRR(xSimd2, vb)
    storeSimd(res, xSimd2)

  of irF64x2Abs:
    # abs = AND with 0x7FFFFFFFFFFFFFFF mask in both 64-bit lanes
    let va = loadSimd(instr.operands[0], xSimd0)
    buf.movImmX64(rTmpX, 0x7FFFFFFF_FFFFFFFF'i64)
    buf.movqToXmm(xSimd1, rTmpX)
    buf.pshufdRRI(xSimd1, xSimd1, 0x44)   # copy low 64-bit to high 64-bit
    buf.movdqaRR(xSimd2, va)
    buf.pandRR(xSimd2, xSimd1)
    storeSimd(res, xSimd2)

  of irF64x2Neg:
    # neg = XOR with 0x8000000000000000 sign mask in both 64-bit lanes
    let va = loadSimd(instr.operands[0], xSimd0)
    buf.movImmX64(rTmpX, cast[int64](0x80000000_00000000'u64))
    buf.movqToXmm(xSimd1, rTmpX)
    buf.pshufdRRI(xSimd1, xSimd1, 0x44)
    buf.movdqaRR(xSimd2, va)
    buf.pxorRR(xSimd2, xSimd1)
    storeSimd(res, xSimd2)

  # ---- Memory ----
  of irLoad8U:
    let addrVal = loadOp(instr.operands[0], rTmpX)
    let memOff = instr.imm2.int32
    if memOff != 0: buf.movRegReg(rTmpX, addrVal); buf.addImmX64(rTmpX, memOff)
    elif addrVal != rTmpX: buf.movRegReg(rTmpX, addrVal)
    buf.emitBoundsCheckX64(rTmpX, 1)
    buf.addRegReg(rTmpX, rWMem)
    buf.movzbX64(resReg, rTmpX, 0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irLoad8S:
    let addrVal = loadOp(instr.operands[0], rTmpX)
    let memOff = instr.imm2.int32
    if memOff != 0: buf.movRegReg(rTmpX, addrVal); buf.addImmX64(rTmpX, memOff)
    elif addrVal != rTmpX: buf.movRegReg(rTmpX, addrVal)
    buf.emitBoundsCheckX64(rTmpX, 1)
    buf.addRegReg(rTmpX, rWMem)
    buf.movsbX64(resReg, rTmpX, 0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irLoad16U:
    let addrVal = loadOp(instr.operands[0], rTmpX)
    let memOff = instr.imm2.int32
    if memOff != 0: buf.movRegReg(rTmpX, addrVal); buf.addImmX64(rTmpX, memOff)
    elif addrVal != rTmpX: buf.movRegReg(rTmpX, addrVal)
    buf.emitBoundsCheckX64(rTmpX, 2)
    buf.addRegReg(rTmpX, rWMem)
    buf.movzwX64(resReg, rTmpX, 0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irLoad16S:
    let addrVal = loadOp(instr.operands[0], rTmpX)
    let memOff = instr.imm2.int32
    if memOff != 0: buf.movRegReg(rTmpX, addrVal); buf.addImmX64(rTmpX, memOff)
    elif addrVal != rTmpX: buf.movRegReg(rTmpX, addrVal)
    buf.emitBoundsCheckX64(rTmpX, 2)
    buf.addRegReg(rTmpX, rWMem)
    buf.movswX64(resReg, rTmpX, 0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irLoad32, irLoad32U:
    let addrVal = loadOp(instr.operands[0], rTmpX)
    let memOff = instr.imm2.int32
    if memOff != 0: buf.movRegReg(rTmpX, addrVal); buf.addImmX64(rTmpX, memOff)
    elif addrVal != rTmpX: buf.movRegReg(rTmpX, addrVal)
    buf.emitBoundsCheckX64(rTmpX, 4)
    buf.addRegReg(rTmpX, rWMem)
    buf.movRegMem32(resReg, rTmpX, 0)   # zero-extends to 64
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irLoad32S:
    let addrVal = loadOp(instr.operands[0], rTmpX)
    let memOff = instr.imm2.int32
    if memOff != 0: buf.movRegReg(rTmpX, addrVal); buf.addImmX64(rTmpX, memOff)
    elif addrVal != rTmpX: buf.movRegReg(rTmpX, addrVal)
    buf.emitBoundsCheckX64(rTmpX, 4)
    buf.addRegReg(rTmpX, rWMem)
    buf.movsdX64(resReg, rTmpX, 0)     # sign-extends to 64
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irLoad64:
    let addrVal = loadOp(instr.operands[0], rTmpX)
    let memOff = instr.imm2.int32
    if memOff != 0: buf.movRegReg(rTmpX, addrVal); buf.addImmX64(rTmpX, memOff)
    elif addrVal != rTmpX: buf.movRegReg(rTmpX, addrVal)
    buf.emitBoundsCheckX64(rTmpX, 8)
    buf.addRegReg(rTmpX, rWMem)
    buf.movRegMem(resReg, rTmpX, 0)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irStore8:
    let addrVal = loadOp(instr.operands[0], rTmpX)
    let valOp   = loadOp(instr.operands[1], rTmpY)
    let memOff = instr.imm2.int32
    if memOff != 0: buf.movRegReg(rTmpX, addrVal); buf.addImmX64(rTmpX, memOff)
    elif addrVal != rTmpX: buf.movRegReg(rTmpX, addrVal)
    buf.emitBoundsCheckX64(rTmpX, 1)
    buf.addRegReg(rTmpX, rWMem)
    buf.movMemReg8(rTmpX, 0, valOp)

  of irStore16:
    let addrVal = loadOp(instr.operands[0], rTmpX)
    let valOp   = loadOp(instr.operands[1], rTmpY)
    let memOff = instr.imm2.int32
    if memOff != 0: buf.movRegReg(rTmpX, addrVal); buf.addImmX64(rTmpX, memOff)
    elif addrVal != rTmpX: buf.movRegReg(rTmpX, addrVal)
    buf.emitBoundsCheckX64(rTmpX, 2)
    buf.addRegReg(rTmpX, rWMem)
    buf.movMemReg16(rTmpX, 0, valOp)

  of irStore32, irStore32From64:
    let addrVal = loadOp(instr.operands[0], rTmpX)
    let valOp   = loadOp(instr.operands[1], rTmpY)
    let memOff = instr.imm2.int32
    if memOff != 0: buf.movRegReg(rTmpX, addrVal); buf.addImmX64(rTmpX, memOff)
    elif addrVal != rTmpX: buf.movRegReg(rTmpX, addrVal)
    buf.emitBoundsCheckX64(rTmpX, 4)
    buf.addRegReg(rTmpX, rWMem)
    buf.movMemReg32(rTmpX, 0, valOp)

  of irStore64:
    let addrVal = loadOp(instr.operands[0], rTmpX)
    let valOp   = loadOp(instr.operands[1], rTmpY)
    let memOff = instr.imm2.int32
    if memOff != 0: buf.movRegReg(rTmpX, addrVal); buf.addImmX64(rTmpX, memOff)
    elif addrVal != rTmpX: buf.movRegReg(rTmpX, addrVal)
    buf.emitBoundsCheckX64(rTmpX, 8)
    buf.addRegReg(rTmpX, rWMem)
    buf.movMemReg(rTmpX, 0, valOp)

  # ---- Locals ----
  of irParam, irLocalGet:
    let localOff = instr.imm.int32 * 8
    buf.movRegMem(resReg, rWLoc, localOff)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irLocalSet:
    let localOff = instr.imm.int32 * 8
    let valOp = loadOp(instr.operands[0], rTmpX)
    buf.movMemReg(rWLoc, localOff, valOp)

  # ---- Control flow ----
  of irBr:
    let targetBb = instr.imm.int
    buf.emitPhiResolutionX64(f, alloc, targetBb, curBlockIdx, spillSlotBias)
    if targetBb < blockLabels.len and blockLabels[targetBb].offset >= 0:
      buf.jmpRel32(int32(blockLabels[targetBb].offset - (buf.len + 5)))
    else:
      if targetBb >= blockLabels.len:
        blockLabels.setLen(targetBb + 1)
        blockLabels[^1].offset = -1
      let p = buf.len
      buf.jmpRel32(0)
      blockLabels[targetBb].patchList.add((p, false))

  of irBrIf:
    let condOp = loadOp(instr.operands[0], rTmpX)
    let targetBb = instr.imm.int
    buf.emitPhiResolutionX64(f, alloc, targetBb, curBlockIdx, spillSlotBias)
    buf.testRegReg(condOp, condOp)
    if targetBb < blockLabels.len and blockLabels[targetBb].offset >= 0:
      buf.jccRel32(x64condNE, int32(blockLabels[targetBb].offset - (buf.len + 6)))
    else:
      if targetBb >= blockLabels.len:
        blockLabels.setLen(targetBb + 1)
        blockLabels[^1].offset = -1
      let p = buf.len
      buf.jccRel32(x64condNE, 0)
      blockLabels[targetBb].patchList.add((p, true))
    # False path
    let falseBb = instr.imm2.int
    if falseBb > 0:
      buf.emitPhiResolutionX64(f, alloc, falseBb, curBlockIdx, spillSlotBias)
      if falseBb < blockLabels.len and blockLabels[falseBb].offset >= 0:
        buf.jmpRel32(int32(blockLabels[falseBb].offset - (buf.len + 5)))
      else:
        if falseBb >= blockLabels.len:
          blockLabels.setLen(falseBb + 1)
          blockLabels[^1].offset = -1
        let p = buf.len
        buf.jmpRel32(0)
        blockLabels[falseBb].patchList.add((p, false))

  of irReturn:
    if instr.operands[0] >= 0:
      # Push return value onto WASM value stack at [r12], advance r12 by 8
      let valOp = loadOp(instr.operands[0], rTmpX)
      buf.movMemReg(rWVSP, 0, valOp)
      buf.addImmX64(rWVSP, 8)
    let p = buf.len
    buf.jmpRel32(0)   # placeholder — patched to epilogue
    epiloguePatchList.add(p)

  of irSelect:
    # select(cond, a, b): if cond != 0 then a else b
    let condOp = loadOp(instr.operands[0], rTmpY)
    let aOp    = loadOp(instr.operands[1], rTmpX)
    let bOp    = loadOp(instr.operands[2], rTmpZ)
    if resReg != bOp: buf.movRegReg(resReg, bOp)
    buf.testRegReg(condOp, condOp)
    buf.cmovX64(x64condNE, resReg, aOp)
    if res >= 0 and alloc.isSpilledX64(res): storeRes(res, resReg)

  of irPhi:
    discard  # phi resolution happens at branch sites

  of irNop:
    if instr.operands[0] >= 0 and res >= 0:
      let srcOp = loadOp(instr.operands[0], rTmpX)
      if resReg != srcOp: buf.movRegReg(resReg, srcOp)
      if alloc.isSpilledX64(res): storeRes(res, resReg)
    else:
      buf.nopX64()

  of irTrap:
    buf.ud2()

  of irCall:
    let calleeIdx = instr.imm.int
    if calleeIdx == selfModuleIdx and selfEntry >= 0:
      let usesMem = f.usesMemory
      # 1. Allocate callee locals on native stack (16-byte aligned)
      let localsBytes = int32((f.numLocals * 8 + 15) and (not 15))
      if localsBytes > 0:
        buf.subRegImm32(rsp, localsBytes)
      # 2. Store params into callee locals at [rsp + i*8]
      for i in 0 ..< min(f.numParams, 3):
        if instr.operands[i] >= 0:
          let arg = buf.loadOperandX64(alloc, instr.operands[i], spillSlotBias, rTmpX)
          buf.movMemReg(rsp, int32(i * 8), arg)
      # 3. Save WASM state (r12, r13 + optionally r14, r15)
      let saveBytes: int32 = if usesMem: 32 else: 16
      buf.subRegImm32(rsp, saveBytes)
      buf.movMemReg(rsp, 0, rWVSP)
      buf.movMemReg(rsp, 8, rWLoc)
      if usesMem:
        buf.movMemReg(rsp, 16, rWMem)
        buf.movMemReg(rsp, 24, rWSiz)
      # 4. Set up callee ABI args (SysV: rdi, rsi, rdx, rcx)
      buf.movRegReg(rdi, rWVSP)
      buf.leaRegMem(rsi, rsp, saveBytes)   # locals base = rsp + saveBytes
      if usesMem:
        buf.movRegReg(rdx, rWMem)
        buf.movRegReg(rcx, rWSiz)
      # 5. CALL self entry
      buf.callRel32(int32(selfEntry - (buf.len + 5)))
      # 6. Restore WASM state
      buf.movRegMem(rWVSP, rsp, 0)
      buf.movRegMem(rWLoc, rsp, 8)
      if usesMem:
        buf.movRegMem(rWMem, rsp, 16)
        buf.movRegMem(rWSiz, rsp, 24)
      buf.addImmX64(rsp, saveBytes.int32)
      # 7. Load result from old VSP
      if res >= 0:
        buf.movRegMem(resReg, rWVSP, 0)
        if alloc.isSpilledX64(res): storeRes(res, resReg)
      # 8. Deallocate callee locals
      if localsBytes > 0:
        buf.addImmX64(rsp, localsBytes.int32)
    else:
      buf.ud2()  # non-self calls not implemented

  of irCallIndirect:
    # call_indirect via tier2CallIndirectDispatch on x86-64 (SysV AMD64 ABI).
    # Args layout in locals[tempBase..tempBase+pc-1]; result written back to locals[tempBase].
    # Dispatch signature: (cache, elemIdx, argPtr, memBase, memSize) -> int32
    #   rdi=cache  rsi=elemIdx  rdx=argPtr  rcx=memBase  r8=memSize
    let resultCount = ((instr.imm shr 16) and 0xFFFF).int
    let tempBase    = instr.imm2.int
    let argOff      = (tempBase * 8).int32
    let cacheIdx    = callIndirectSiteIdx - 1

    # ---- Step 1: elemIdx → rsi (2nd arg) — load before any caller-save ----
    let elemSrc = instr.operands[0]
    if elemSrc >= 0:
      if alloc.isSpilledX64(elemSrc):
        buf.emitSpillLoadX64(rsi, alloc, elemSrc, spillSlotBias)
      else:
        let elemReg = alloc.physRegX64(elemSrc)
        if elemReg != rsi:
          buf.movRegReg(rsi, elemReg)
    else:
      buf.movRegImm64(rsi, 0)

    # ---- Step 2: argPtr → rdx (3rd arg) = rWLoc + tempBase*8 ----
    buf.movRegReg(rdx, rWLoc)
    if argOff != 0:
      buf.addImmX64(rdx, argOff)

    # ---- Step 3: Save caller-saved allocatable regs (r8-r11 may hold live SSA values) ----
    buf.pushReg(r8); buf.pushReg(r9); buf.pushReg(r10); buf.pushReg(r11)

    # ---- Step 4: Remaining args (r14/r15 are callee-saved, safe after push) ----
    buf.movRegReg(rcx, rWMem)   # 4th arg = memBase
    buf.movRegReg(r8, rWSiz)    # 5th arg = memSize

    # ---- Step 5: rdi = cachePtr (64-bit constant) ----
    let cachePtr = if cacheIdx >= 0 and cacheIdx < callIndirectCaches.len:
                     callIndirectCaches[cacheIdx]
                   else: nil
    if cachePtr != nil:
      # Record relocation: immediate is 2 bytes into movRegImm64 encoding
      relocSites.add(Relocation(offset: (buf.len + 2).uint32,
                                kind: relocCallCache,
                                siteIdx: cacheIdx.uint32))
      buf.movRegImm64(rdi, cast[uint64](cachePtr))
    else:
      buf.movRegImm64(rdi, 0)  # nil cache → dispatch will trap

    # ---- Step 6: CALL tier2CallIndirectDispatch via rax (scratch0) ----
    # Record relocation for the dispatch function address
    relocSites.add(Relocation(offset: (buf.len + 2).uint32,
                              kind: relocDispatch, siteIdx: 0))
    buf.movRegImm64(rTmpX, cast[uint64](tier2CallIndirectDispatch))
    buf.callReg(rTmpX)

    # ---- Step 7: trap if return value (eax) ≠ 0 ----
    # TEST eax, eax; JZ +2; UD2
    buf.testRegReg(rTmpX, rTmpX)
    buf.jccRel8(x64condE, 2)   # JE (ZF=1) +2 → skip UD2
    buf.ud2()

    # ---- Step 8: Restore caller-saved regs ----
    buf.popReg(r11); buf.popReg(r10); buf.popReg(r9); buf.popReg(r8)

    # ---- Step 9: Load result from locals[tempBase] ----
    if res >= 0 and resultCount > 0:
      buf.movRegMem(resReg, rWLoc, argOff)
      if alloc.isSpilledX64(res):
        storeRes(res, resReg)

# ---------------------------------------------------------------------------
# Post-codegen peephole optimization (x86-64)
# ---------------------------------------------------------------------------

proc peepholeX64(buf: var X64AsmBuffer) =
  ## Scan the emitted byte stream and eliminate obvious redundancies.
  ##
  ## Patterns:
  ##   1. MOV Rd, Rd  (64-bit self-move via 0x89)  → 3-byte NOP
  ##   2. MOV Rd, Rd  (32-bit self-move via 0x89)  → 1 or 2-byte NOP(s)
  ##   3. MOV [rbp+off8], Rn immediately followed by MOV Rd, [rbp+off8]
  ##      (both 4-byte 8-bit-offset forms, base = rbp = reg 5)
  ##      · same register (Rn == Rd): replace load with 4-byte NOP
  ##      · different registers:      replace load with MOV Rd, Rn + NOP
  ##
  ## movRegReg/movRegReg32 already guard against self-moves at emission;
  ## this pass catches any that slip through (phi resolution, etc.) and
  ## eliminates the common spill-store + immediate-reload sequence.
  ##
  ## Multi-byte NOPs used:
  ##   3-byte: 0F 1F 00          (NOP DWORD ptr [rax])
  ##   4-byte: 0F 1F 40 00       (NOP DWORD ptr [rax+0])

  const nop1 = 0x90'u8

  let n = buf.code.len
  var i = 0
  while i < n:

    # ------------------------------------------------------------------
    # Pattern 1: 64-bit self-move  REX.W + 0x89 + ModRM(11, r, r)
    # For a self-move both REX.R and REX.B must be equal:
    #   REX = 0x48 (W, no R/B extension)  → src and dst both in r0-r7
    #   REX = 0x4D (W + R + B)            → src and dst both in r8-r15
    # In both cases ModRM(11, r_low, r_low): (modrm >> 3 & 7) == (modrm & 7)
    # ------------------------------------------------------------------
    if i + 2 < n:
      let b0 = buf.code[i]
      let b1 = buf.code[i + 1]
      let b2 = buf.code[i + 2]
      if (b0 == 0x48 or b0 == 0x4D) and b1 == 0x89 and (b2 shr 6) == 0b11:
        if ((b2 shr 3) and 0x07) == (b2 and 0x07):
          buf.code[i]   = 0x0F
          buf.code[i+1] = 0x1F
          buf.code[i+2] = 0x00
          i += 3
          continue

    # ------------------------------------------------------------------
    # Pattern 2: 32-bit self-move  0x89 + ModRM(11, r, r)  (no REX prefix)
    # Only for r0-r7; extended regs require a REX prefix (handled above
    # or avoided by the movRegReg32 self-move guard).
    # ------------------------------------------------------------------
    if i + 1 < n:
      let b0 = buf.code[i]
      let b1 = buf.code[i + 1]
      if b0 == 0x89 and (b1 shr 6) == 0b11:
        if ((b1 shr 3) and 0x07) == (b1 and 0x07):
          buf.code[i]   = nop1
          buf.code[i+1] = nop1
          i += 2
          continue

    # ------------------------------------------------------------------
    # Pattern 3: spill-store → immediate spill-load of the same slot.
    #
    # Store form (8-bit rbp offset, 4 bytes total):
    #   REX ∈ {0x48, 0x4C} + 0x89 + ModRM(01=0x40, rn_low, 5=rbp) + off8
    #   ModRM = 0x45 | (rn_low << 3);  REX.R set iff rn in r8-r15
    #
    # Load form (same 4-byte layout):
    #   REX ∈ {0x48, 0x4C} + 0x8B + ModRM(01, rd_low, 5) + off8
    #
    # If the store is immediately followed by a load with the same offset:
    #   · rn == rd  →  load is redundant: overwrite with 4-byte NOP
    #   · rn != rd  →  replace load with MOV rd, rn (3 bytes) + 1-byte NOP
    # ------------------------------------------------------------------
    if i + 7 < n:
      let s0 = buf.code[i]      # store REX
      let s1 = buf.code[i + 1]  # 0x89 (store opcode)
      let s2 = buf.code[i + 2]  # store ModRM
      let s3 = buf.code[i + 3]  # 8-bit offset
      let l0 = buf.code[i + 4]  # load REX
      let l1 = buf.code[i + 5]  # 0x8B (load opcode)
      let l2 = buf.code[i + 6]  # load ModRM
      let l3 = buf.code[i + 7]  # 8-bit offset

      # Verify both are rbp-relative 8-bit-displacement forms
      # ModRM mod=01, rm=5 (rbp): modrm & 0xC7 == 0x45
      let isStore = (s0 == 0x48 or s0 == 0x4C) and s1 == 0x89 and
                    (s2 and 0xC7) == 0x45
      let isLoad  = (l0 == 0x48 or l0 == 0x4C) and l1 == 0x8B and
                    (l2 and 0xC7) == 0x45

      if isStore and isLoad and s3 == l3:
        let rnLow  = (s2 shr 3) and 0x07
        let rdLow  = (l2 shr 3) and 0x07
        let rnHigh = if s0 == 0x4C: 1'u8 else: 0'u8  # REX.R extends src
        let rdHigh = if l0 == 0x4C: 1'u8 else: 0'u8  # REX.R extends dst
        let rn = rnLow or (rnHigh shl 3)
        let rd = rdLow or (rdHigh shl 3)

        if rn == rd:
          # Redundant reload: same value already in register → 4-byte NOP
          buf.code[i+4] = 0x0F
          buf.code[i+5] = 0x1F
          buf.code[i+6] = 0x40
          buf.code[i+7] = 0x00
        else:
          # Forward the stored value: replace load with MOV rd, rn
          # Encoding: REX.W + 0x89 + ModRM(11, rn_low, rd_low)
          # REX.R = rnHigh (src/reg field), REX.B = rdHigh (dst/rm field)
          buf.code[i+4] = byte(0x48 or (rnHigh shl 2) or rdHigh)
          buf.code[i+5] = 0x89
          buf.code[i+6] = byte(0xC0 or (rnLow shl 3) or rdLow)
          buf.code[i+7] = nop1

        i += 8
        continue

    inc i

# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

proc emitIrFuncX64*(pool: var JitMemPool, f: IrFunc, alloc: RegAllocResult,
                    selfModuleIdx: int = -1,
                    tableElems: ptr UncheckedArray[TableElem] = nil,
                    tableLen: int32 = 0,
                    relocSites: ptr seq[Relocation] = nil): JitCode =
  ## Emit x86_64 machine code for an IR function using register allocation.
  ## Uses the shared JitMemPool (mmap'd as RWX on macOS/Linux).
  ## If *relocSites* is non-nil, absolute-address patch locations are appended
  ## to it (for persistent cache support).
  var buf = initX64AsmBuffer(f.numValues * 8 + 256)

  # Determine if rbx is used (color 4, the only callee-saved allocatable reg)
  var rbxUsed = false
  for i in 0 ..< f.numValues:
    if alloc.assignment[i].int8 == 4:
      rbxUsed = true
      break

  # Frame sizes
  # r12-r15 always saved at [rbp-8]..[rbp-32] (32 bytes)
  # rbx optionally saved at [rbp-40] (+8 bytes)
  let csSaveBytes  = 32 + (if rbxUsed: 8 else: 0)
  let spillBytes   = alloc.totalSpillBytes
  let frameSize    = (csSaveBytes + spillBytes + 15) and (not 15)  # 16-byte aligned
  let spillSlotBias = -frameSize.int32   # rbp + spillSlotBias + slot.offset

  # ---- Prologue ----
  let selfEntry = buf.len
  buf.pushReg(rbp)
  buf.movRegReg(rbp, rsp)

  if frameSize > 0:
    if frameSize <= 0x7FFF_FFFF:
      buf.subRegImm32(rsp, frameSize.int32)
    else:
      buf.movRegImm64(rTmpX, frameSize.uint64)
      buf.subRegReg(rsp, rTmpX)

  # Save WASM state registers
  buf.movMemReg(rbp, -8,  rWVSP)
  buf.movMemReg(rbp, -16, rWLoc)
  buf.movMemReg(rbp, -24, rWMem)
  buf.movMemReg(rbp, -32, rWSiz)
  if rbxUsed:
    buf.movMemReg(rbp, -40, rbx)

  # Load WASM state from SysV args: rdi=VSP, rsi=locals, rdx=memBase, rcx=memSize
  buf.movRegReg(rWVSP, rdi)
  buf.movRegReg(rWLoc, rsi)
  if f.usesMemory:
    buf.movRegReg(rWMem, rdx)
    buf.movRegReg(rWSiz, rcx)

  # ---- Pre-allocate CallIndirectCache per call_indirect site ----
  var callIndirectCaches = newSeq[ptr CallIndirectCache](f.callIndirectSiteCount)
  for i in 0 ..< f.callIndirectSiteCount:
    let p = cast[ptr CallIndirectCache](allocShared0(sizeof(CallIndirectCache)))
    p.cachedElemIdx = -1
    p.tableElems = tableElems
    p.tableLen = tableLen
    pool.sideData.add(p)
    callIndirectCaches[i] = p

  # ---- Emit basic blocks ----
  var blockLabels = newSeq[X64BlockLabel](f.blocks.len)
  for i in 0 ..< blockLabels.len:
    blockLabels[i].offset = -1
  var epiloguePatchList: seq[int]
  var callIndirectSiteIdx = 0

  for bbIdx in 0 ..< f.blocks.len:
    let bb = f.blocks[bbIdx]

    # Record block start position
    if bbIdx < blockLabels.len:
      blockLabels[bbIdx].offset = buf.len

    # Patch forward branches targeting this block
    if bbIdx < blockLabels.len:
      for (patchPos, isJcc) in blockLabels[bbIdx].patchList:
        if isJcc: buf.patchJccAt(patchPos)
        else:     buf.patchJmpAt(patchPos)
      blockLabels[bbIdx].patchList.setLen(0)

    # Emit instructions
    var localRelocs: seq[Relocation]   # per-instr scratch (populated for irCallIndirect)
    for instrIdx in 0 ..< bb.instrs.len:
      let instr = bb.instrs[instrIdx]
      # Pre-fill cache paramCount/resultCount for call_indirect sites
      if instr.op == irCallIndirect:
        let siteCache = if callIndirectSiteIdx < callIndirectCaches.len:
                          callIndirectCaches[callIndirectSiteIdx]
                        else: nil
        if siteCache != nil:
          siteCache.paramCount  = (instr.imm and 0xFFFF).int32
          siteCache.resultCount = ((instr.imm shr 16) and 0xFFFF).int32
        inc callIndirectSiteIdx
      localRelocs.setLen(0)
      buf.emitIrInstrX64(instr, f, alloc, instr.result, spillSlotBias,
                         bbIdx, blockLabels, epiloguePatchList,
                         selfModuleIdx, selfEntry,
                         callIndirectCaches, callIndirectSiteIdx,
                         localRelocs)
      if relocSites != nil:
        for r in localRelocs: relocSites[].add(r)

  # ---- Epilogue ----
  # Patch all return jumps here
  for patchPos in epiloguePatchList:
    buf.patchJmpAt(patchPos)

  # Return value: rax = updated VSP (save BEFORE restoring r12!)
  buf.movRegReg(rTmpX, rWVSP)   # rax = r12

  # Restore callee-saved registers
  buf.movRegMem(rWVSP, rbp, -8)
  buf.movRegMem(rWLoc, rbp, -16)
  buf.movRegMem(rWMem, rbp, -24)
  buf.movRegMem(rWSiz, rbp, -32)
  if rbxUsed:
    buf.movRegMem(rbx, rbp, -40)

  buf.movRegReg(rsp, rbp)
  buf.popReg(rbp)
  buf.ret()

  # ---- Post-codegen peephole ----
  peepholeX64(buf)

  # ---- Copy into JIT pool ----
  result = pool.alloc(buf.len)
  result.size = buf.len   # actual code bytes (pool.alloc rounds up to 8-byte alignment)
  pool.enableWrite()
  copyMem(result.address, addr buf.code[0], buf.len)
  pool.enableExecute()
