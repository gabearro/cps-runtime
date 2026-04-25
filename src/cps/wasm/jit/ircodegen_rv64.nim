## RV64 IR code generator (Tier 2 backend).
##
## This backend targets the same external JIT ABI as the other Tier 2 backends:
##   (a0=VSP, a1=locals, a2=memBase, a3=memSize) -> a0=updated VSP
##
## It currently covers scalar integer/control-flow/local/memory IR. Unsupported
## IR opcodes raise during compilation so the tiered runtime can fall back to
## the interpreter instead of installing partial native code.

import std/math
import ir, regalloc, codegen_rv64, memory, compiler

const
  NumIntRegsRv64* = 5
  CalleeSavedStartRv64* = 5'i8

const rv64AllocRegs: array[NumIntRegsRv64, RvReg] = [t0, t1, t2, t3, t4]

const
  rTmp0 = t5
  rTmp1 = t6
  rTmp2 = a4
  rTmp3 = a5
  rVsp = s1
  rLocals = s2
  rMemBase = s3
  rMemSize = s4
  rv64CallSaveBase = 48'i32
  rv64DirectArgBase = rv64CallSaveBase + NumIntRegsRv64.int32 * 8'i32
  rv64MaxDirectArgs = 3'i32
  rv64MaxDirectArgSlots = rv64MaxDirectArgs * 2'i32
  savedBytes = (rv64DirectArgBase + rv64MaxDirectArgSlots * 8'i32 + 15'i32) and
               (not 15'i32)

const
  vMask = RvReg(0)
  vTmp0 = RvReg(8)
  vTmp1 = RvReg(9)
  vTmp2 = RvReg(10)
  vTmp3 = RvReg(11)

type
  Rv64BlockLabel = object
    offset: int
    patchList: seq[(int, bool)] ## (instruction index, true = conditional branch)

proc unsupportedRv64(op: IrOpKind) =
  raise newException(ValueError, "RV64 JIT backend does not support " & $op)

proc rvJitCeilF32Helper(bits: uint32): uint32 {.cdecl, used.} =
  cast[uint32](ceil(cast[float32](bits)))

proc rvJitFloorF32Helper(bits: uint32): uint32 {.cdecl, used.} =
  cast[uint32](floor(cast[float32](bits)))

proc rvJitTruncF32Helper(bits: uint32): uint32 {.cdecl, used.} =
  cast[uint32](trunc(cast[float32](bits)))

proc rvJitNearestF32Helper(bits: uint32): uint32 {.cdecl, used.} =
  let x = cast[float32](bits)
  if classify(x) in {fcNan, fcInf, fcNegInf, fcZero, fcNegZero}:
    return bits
  if abs(x) >= 8_388_608'f32:
    return bits
  let lo = floor(x)
  let frac = x - lo
  var y =
    if frac < 0.5'f32:
      lo
    elif frac > 0.5'f32:
      lo + 1.0'f32
    else:
      let half = lo * 0.5'f32
      if floor(half) == half: lo else: lo + 1.0'f32
  if y == 0.0'f32 and x < 0.0'f32:
    return 0x8000_0000'u32
  cast[uint32](y)

proc rvJitCeilF64Helper(bits: uint64): uint64 {.cdecl, used.} =
  cast[uint64](ceil(cast[float64](bits)))

proc rvJitFloorF64Helper(bits: uint64): uint64 {.cdecl, used.} =
  cast[uint64](floor(cast[float64](bits)))

proc rvJitTruncF64Helper(bits: uint64): uint64 {.cdecl, used.} =
  cast[uint64](trunc(cast[float64](bits)))

proc rvJitNearestF64Helper(bits: uint64): uint64 {.cdecl, used.} =
  let x = cast[float64](bits)
  if classify(x) in {fcNan, fcInf, fcNegInf, fcZero, fcNegZero}:
    return bits
  if abs(x) >= 4_503_599_627_370_496.0:
    return bits
  let lo = floor(x)
  let frac = x - lo
  var y =
    if frac < 0.5:
      lo
    elif frac > 0.5:
      lo + 1.0
    else:
      let half = lo * 0.5
      if floor(half) == half: lo else: lo + 1.0
  if y == 0.0 and x < 0.0:
    return 0x8000_0000_0000_0000'u64
  cast[uint64](y)

proc fitsSimm12(v: int32): bool {.inline.} =
  v >= -2048 and v <= 2047

proc isSpilledRv64(alloc: RegAllocResult, v: IrValue): bool {.inline.} =
  v >= 0 and alloc.assignment[v.int].int8 < 0

proc physRegRv64(alloc: RegAllocResult, v: IrValue): RvReg {.inline.} =
  if v < 0: return zero
  let pr = alloc.assignment[v.int]
  if pr.int8 >= 0 and pr.int8 < NumIntRegsRv64:
    rv64AllocRegs[pr.int8]
  else:
    rTmp0

proc spillOffsetRv64(alloc: RegAllocResult, v: IrValue): int32 {.inline.} =
  if v.int < alloc.spillOffsetMap.len:
    alloc.spillOffsetMap[v.int]
  else:
    0

proc emitAddImm(buf: var Rv64AsmBuffer, dst, base: RvReg, imm: int32,
                scratch: RvReg = rTmp1) =
  if imm == 0:
    buf.mv(dst, base)
  elif fitsSimm12(imm):
    buf.addi(dst, base, imm)
  else:
    buf.loadImm(scratch, imm.int64)
    buf.add(dst, base, scratch)

proc emitLoadStack(buf: var Rv64AsmBuffer, dst: RvReg, offset: int32) =
  if fitsSimm12(offset):
    buf.ld(dst, sp, offset)
  else:
    buf.emitAddImm(rTmp1, sp, offset)
    buf.ld(dst, rTmp1, 0)

proc emitStoreStack(buf: var Rv64AsmBuffer, src: RvReg, offset: int32) =
  if fitsSimm12(offset):
    buf.sd(src, sp, offset)
  else:
    let scratch = if src == rTmp1: rTmp0 else: rTmp1
    buf.emitAddImm(scratch, sp, offset, if scratch == rTmp1: rTmp0 else: rTmp1)
    buf.sd(src, scratch, 0)

proc emitLoadStackScalar(buf: var Rv64AsmBuffer, dst: RvReg, offset: int32,
                         bytes: int32, signed = false) =
  let base =
    if fitsSimm12(offset):
      sp
    else:
      buf.emitAddImm(rTmp1, sp, offset)
      rTmp1
  let off = if fitsSimm12(offset): offset else: 0'i32
  case bytes
  of 1:
    if signed: buf.lb(dst, base, off) else: buf.lbu(dst, base, off)
  of 2:
    if signed: buf.lh(dst, base, off) else: buf.lhu(dst, base, off)
  of 4:
    if signed: buf.lw(dst, base, off) else: buf.lwu(dst, base, off)
  else:
    buf.ld(dst, base, off)

proc emitStoreStackScalar(buf: var Rv64AsmBuffer, src: RvReg, offset: int32,
                          bytes: int32) =
  let base =
    if fitsSimm12(offset):
      sp
    else:
      let scratch = if src == rTmp1: rTmp0 else: rTmp1
      buf.emitAddImm(scratch, sp, offset, if scratch == rTmp1: rTmp0 else: rTmp1)
      scratch
  let off = if fitsSimm12(offset): offset else: 0'i32
  case bytes
  of 1: buf.sb(src, base, off)
  of 2: buf.sh(src, base, off)
  of 4: buf.sw(src, base, off)
  else: buf.sd(src, base, off)

proc localByteOffsetRv64(f: IrFunc, idx: int): int32 {.inline.} =
  let slot =
    if idx >= 0 and idx < f.localSlotOffsets.len:
      f.localSlotOffsets[idx]
    else:
      idx.int32
  slot * 8'i32

proc isSimdValueRv64(f: IrFunc, v: IrValue): bool {.inline.} =
  v >= 0 and v.int < f.isSimd.len and f.isSimd[v.int]

proc emitLoadLocalSlotRv64(buf: var Rv64AsmBuffer, dst: RvReg, offset: int32) =
  if fitsSimm12(offset):
    buf.ld(dst, rLocals, offset)
  else:
    buf.emitAddImm(rTmp2, rLocals, offset)
    buf.ld(dst, rTmp2, 0)

proc emitStoreLocalSlotRv64(buf: var Rv64AsmBuffer, src: RvReg, offset: int32) =
  if fitsSimm12(offset):
    buf.sd(src, rLocals, offset)
  else:
    let scratch = if src == rTmp2: rTmp1 else: rTmp2
    buf.emitAddImm(scratch, rLocals, offset, if scratch == rTmp1: rTmp2 else: rTmp1)
    buf.sd(src, scratch, 0)

proc emitSpillLoadRv64(buf: var Rv64AsmBuffer, dst: RvReg,
                       alloc: RegAllocResult, v: IrValue, spillBase: int32) =
  buf.emitLoadStack(dst, spillBase + spillOffsetRv64(alloc, v))

proc emitSpillStoreRv64(buf: var Rv64AsmBuffer, src: RvReg,
                        alloc: RegAllocResult, v: IrValue, spillBase: int32) =
  buf.emitStoreStack(src, spillBase + spillOffsetRv64(alloc, v))

proc loadOperandRv64(buf: var Rv64AsmBuffer, alloc: RegAllocResult, v: IrValue,
                     spillBase: int32, scratch: RvReg = rTmp0): RvReg =
  if v < 0: return zero
  if alloc.isSpilledRv64(v):
    if v.int < alloc.rematKind.len and alloc.rematKind[v.int] == rematConst:
      buf.loadImm(scratch, alloc.rematImm[v.int])
      return scratch
    buf.emitSpillLoadRv64(scratch, alloc, v, spillBase)
    return scratch
  alloc.physRegRv64(v)

proc storeResultRv64(buf: var Rv64AsmBuffer, alloc: RegAllocResult, v: IrValue,
                     src: RvReg, spillBase: int32) =
  if v < 0: return
  if alloc.isSpilledRv64(v):
    if v.int < alloc.rematKind.len and alloc.rematKind[v.int] == rematConst:
      return
    buf.emitSpillStoreRv64(src, alloc, v, spillBase)
  else:
    let dst = alloc.physRegRv64(v)
    if dst != src:
      buf.mv(dst, src)

proc emitCopyStack128Rv64(buf: var Rv64AsmBuffer, dstOff, srcOff: int32) =
  if dstOff == srcOff: return
  buf.emitLoadStack(rTmp0, srcOff)
  buf.emitStoreStack(rTmp0, dstOff)
  buf.emitLoadStack(rTmp0, srcOff + 8)
  buf.emitStoreStack(rTmp0, dstOff + 8)

proc emitCopyStack128ToTempRv64(buf: var Rv64AsmBuffer, srcOff: int32) =
  buf.emitCopyStack128Rv64(rv64DirectArgBase, srcOff)

proc emitCopyTempToStack128Rv64(buf: var Rv64AsmBuffer, dstOff: int32) =
  buf.emitCopyStack128Rv64(dstOff, rv64DirectArgBase)

proc ensureLabel(labels: var seq[Rv64BlockLabel], idx: int) =
  if idx < labels.len: return
  let oldLen = labels.len
  labels.setLen(idx + 1)
  for i in oldLen ..< labels.len:
    labels[i].offset = -1

proc emitPhiResolutionRv64(buf: var Rv64AsmBuffer, f: IrFunc, alloc: RegAllocResult,
                           targetBb: int, sourceBb: int, spillBase: int32) =
  if targetBb >= f.blocks.len: return
  let isBackEdge = sourceBb >= targetBb

  type RegMove = object
    dst, src: RvReg
    dstVal: IrValue

  type SimdMove = object
    dstOff, srcOff: int32

  var moves: seq[RegMove]
  var simdMoves: seq[SimdMove]
  for phi in f.blocks[targetBb].instrs:
    if phi.op != irPhi or phi.result < 0: continue
    let opIdx = if isBackEdge and phi.operands[1] >= 0: 1 else: 0
    let srcVal = phi.operands[opIdx]
    if srcVal < 0 or srcVal == phi.result: continue

    if f.isSimdValueRv64(phi.result):
      simdMoves.add(SimdMove(
        dstOff: spillBase + spillOffsetRv64(alloc, phi.result),
        srcOff: spillBase + spillOffsetRv64(alloc, srcVal)))
      continue

    if alloc.isSpilledRv64(srcVal):
      let loaded = buf.loadOperandRv64(alloc, srcVal, spillBase, rTmp0)
      if alloc.isSpilledRv64(phi.result):
        buf.storeResultRv64(alloc, phi.result, loaded, spillBase)
      else:
        let dst = alloc.physRegRv64(phi.result)
        if dst != loaded: buf.mv(dst, loaded)
      continue

    let dstReg = alloc.physRegRv64(phi.result)
    let srcReg = alloc.physRegRv64(srcVal)
    if dstReg == srcReg: continue
    moves.add(RegMove(dst: dstReg, src: srcReg, dstVal: phi.result))

  var simdDone = newSeq[bool](simdMoves.len)
  var simdChanged = true
  while simdChanged:
    simdChanged = false
    for i in 0 ..< simdMoves.len:
      if simdDone[i]: continue
      var blocked = false
      for j in 0 ..< simdMoves.len:
        if not simdDone[j] and j != i and
           simdMoves[j].srcOff == simdMoves[i].dstOff:
          blocked = true
          break
      if not blocked:
        buf.emitCopyStack128Rv64(simdMoves[i].dstOff, simdMoves[i].srcOff)
        simdDone[i] = true
        simdChanged = true

  for i in 0 ..< simdMoves.len:
    if simdDone[i]: continue
    buf.emitCopyStack128ToTempRv64(simdMoves[i].srcOff)
    var curSrc = simdMoves[i].srcOff
    while not simdDone[i]:
      var next = -1
      for j in 0 ..< simdMoves.len:
        if not simdDone[j] and simdMoves[j].dstOff == curSrc:
          next = j
          break
      if next < 0:
        buf.emitCopyTempToStack128Rv64(simdMoves[i].dstOff)
        simdDone[i] = true
      elif next == i:
        buf.emitCopyTempToStack128Rv64(simdMoves[i].dstOff)
        simdDone[i] = true
      else:
        buf.emitCopyStack128Rv64(simdMoves[next].dstOff, simdMoves[next].srcOff)
        simdDone[next] = true
        curSrc = simdMoves[next].srcOff

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
        buf.mv(moves[i].dst, moves[i].src)
        if alloc.isSpilledRv64(moves[i].dstVal):
          buf.storeResultRv64(alloc, moves[i].dstVal, moves[i].dst, spillBase)
        done[i] = true
        changed = true

  for i in 0 ..< moves.len:
    if done[i]: continue
    buf.mv(rTmp1, moves[i].src)
    var cur = i
    while not done[cur]:
      done[cur] = true
      var nxt = -1
      for j in 0 ..< moves.len:
        if not done[j] and moves[j].src == moves[cur].dst:
          nxt = j
          break
      buf.mv(moves[cur].dst, moves[cur].src)
      if alloc.isSpilledRv64(moves[cur].dstVal):
        buf.storeResultRv64(alloc, moves[cur].dstVal, moves[cur].dst, spillBase)
      if nxt < 0: break
      cur = nxt
    buf.mv(moves[i].dst, rTmp1)
    if alloc.isSpilledRv64(moves[i].dstVal):
      buf.storeResultRv64(alloc, moves[i].dstVal, moves[i].dst, spillBase)

proc emitBoundsCheckRv64(buf: var Rv64AsmBuffer, addrReg: RvReg,
                         accessBytes, offset: int32) =
  when defined(wasmGuardPages):
    discard buf; discard addrReg; discard accessBytes; discard offset
  else:
    let limit = accessBytes + offset
    buf.emitAddImm(rTmp1, addrReg, limit)
    buf.bgeu(rMemSize, rTmp1, 2)
    buf.ebreak()

proc emitEffectiveAddr(buf: var Rv64AsmBuffer, dst, addrReg: RvReg) =
  buf.add(dst, rMemBase, addrReg)

proc emitLoadMemRv64(buf: var Rv64AsmBuffer, op: IrOpKind, dst, addrReg: RvReg,
                     offset: int32) =
  buf.emitEffectiveAddr(rTmp1, addrReg)
  if fitsSimm12(offset):
    case op
    of irLoad8U: buf.lbu(dst, rTmp1, offset)
    of irLoad8S: buf.lb(dst, rTmp1, offset)
    of irLoad16U: buf.lhu(dst, rTmp1, offset)
    of irLoad16S: buf.lh(dst, rTmp1, offset)
    of irLoad32, irLoad32U: buf.lwu(dst, rTmp1, offset)
    of irLoad32S: buf.lw(dst, rTmp1, offset)
    of irLoad64: buf.ld(dst, rTmp1, offset)
    else: unsupportedRv64(op)
  else:
    buf.emitAddImm(rTmp1, rTmp1, offset)
    case op
    of irLoad8U: buf.lbu(dst, rTmp1, 0)
    of irLoad8S: buf.lb(dst, rTmp1, 0)
    of irLoad16U: buf.lhu(dst, rTmp1, 0)
    of irLoad16S: buf.lh(dst, rTmp1, 0)
    of irLoad32, irLoad32U: buf.lwu(dst, rTmp1, 0)
    of irLoad32S: buf.lw(dst, rTmp1, 0)
    of irLoad64: buf.ld(dst, rTmp1, 0)
    else: unsupportedRv64(op)

proc emitStoreMemRv64(buf: var Rv64AsmBuffer, op: IrOpKind, src, addrReg: RvReg,
                      offset: int32) =
  buf.emitEffectiveAddr(rTmp1, addrReg)
  if not fitsSimm12(offset):
    buf.emitAddImm(rTmp1, rTmp1, offset)
  let off = if fitsSimm12(offset): offset else: 0
  case op
  of irStore8: buf.sb(src, rTmp1, off)
  of irStore16: buf.sh(src, rTmp1, off)
  of irStore32, irStore32From64: buf.sw(src, rTmp1, off)
  of irStore64: buf.sd(src, rTmp1, off)
  else: unsupportedRv64(op)

proc emitBin32(buf: var Rv64AsmBuffer, instr: IrInstr, alloc: RegAllocResult,
               resReg: RvReg, spillBase: int32, op: IrOpKind,
               target: Rv64Target) =
  let a = buf.loadOperandRv64(alloc, instr.operands[0], spillBase, rTmp0)
  var b = buf.loadOperandRv64(alloc, instr.operands[1], spillBase, rTmp1)
  if resReg == b and resReg != a:
    buf.mv(rTmp1, b)
    b = rTmp1
  let saveOrigA = op in {irRotl32, irRotr32} and
                  rvExtZbb notin target.features and resReg == a
  if saveOrigA:
    buf.mv(rTmp2, a)
  let origA = if saveOrigA: rTmp2 else: a
  if resReg != a: buf.mv(resReg, a)
  case op
  of irAdd32: buf.addw(resReg, resReg, b)
  of irSub32: buf.subw(resReg, resReg, b)
  of irMul32: buf.mulw(resReg, resReg, b)
  of irAnd32: buf.andr(resReg, resReg, b)
  of irOr32:  buf.orr(resReg, resReg, b)
  of irXor32: buf.xorr(resReg, resReg, b)
  of irShl32: buf.sllw(resReg, resReg, b)
  of irShr32U: buf.srlw(resReg, resReg, b)
  of irShr32S: buf.sraw(resReg, resReg, b)
  of irRotl32:
    if rvExtZbb in target.features:
      buf.rolw(resReg, resReg, b)
    else:
      buf.subw(rTmp1, zero, b)
      buf.sllw(resReg, resReg, b)
      buf.srlw(rTmp1, origA, rTmp1)
      buf.orr(resReg, resReg, rTmp1)
  of irRotr32:
    if rvExtZbb in target.features:
      buf.rorw(resReg, resReg, b)
    else:
      buf.subw(rTmp1, zero, b)
      buf.srlw(resReg, resReg, b)
      buf.sllw(rTmp1, origA, rTmp1)
      buf.orr(resReg, resReg, rTmp1)
  else: unsupportedRv64(op)
  buf.zextW(resReg, resReg)

proc emitBin64(buf: var Rv64AsmBuffer, instr: IrInstr, alloc: RegAllocResult,
               resReg: RvReg, spillBase: int32, op: IrOpKind,
               target: Rv64Target) =
  let a = buf.loadOperandRv64(alloc, instr.operands[0], spillBase, rTmp0)
  var b = buf.loadOperandRv64(alloc, instr.operands[1], spillBase, rTmp1)
  if resReg == b and resReg != a:
    buf.mv(rTmp1, b)
    b = rTmp1
  let saveOrigA = op in {irRotl64, irRotr64} and
                  rvExtZbb notin target.features and resReg == a
  if saveOrigA:
    buf.mv(rTmp2, a)
  let origA = if saveOrigA: rTmp2 else: a
  if resReg != a: buf.mv(resReg, a)
  case op
  of irAdd64: buf.add(resReg, resReg, b)
  of irSub64: buf.sub(resReg, resReg, b)
  of irMul64: buf.mul(resReg, resReg, b)
  of irAnd64: buf.andr(resReg, resReg, b)
  of irOr64:  buf.orr(resReg, resReg, b)
  of irXor64: buf.xorr(resReg, resReg, b)
  of irShl64: buf.sll(resReg, resReg, b)
  of irShr64U: buf.srl(resReg, resReg, b)
  of irShr64S: buf.sra(resReg, resReg, b)
  of irRotl64:
    if rvExtZbb in target.features:
      buf.rol(resReg, resReg, b)
    else:
      buf.sub(rTmp1, zero, b)
      buf.sll(resReg, resReg, b)
      buf.srl(rTmp1, origA, rTmp1)
      buf.orr(resReg, resReg, rTmp1)
  of irRotr64:
    if rvExtZbb in target.features:
      buf.ror(resReg, resReg, b)
    else:
      buf.sub(rTmp1, zero, b)
      buf.srl(resReg, resReg, b)
      buf.sll(rTmp1, origA, rTmp1)
      buf.orr(resReg, resReg, rTmp1)
  else: unsupportedRv64(op)

proc patchJalTo(buf: var Rv64AsmBuffer, patchPos, targetPos: int) =
  buf.patchJalAt(patchPos, (targetPos - patchPos).int32)

proc patchBranchTo(buf: var Rv64AsmBuffer, patchPos, targetPos: int) =
  buf.patchBranchAt(patchPos, (targetPos - patchPos).int32)

proc emitClzFallbackRv64(buf: var Rv64AsmBuffer, dst, src: RvReg,
                         width: int) =
  ## Base-ISA fallback used by BL808 D0, which has XTheadBb but not Zbb.
  let x = rTmp1
  let mask = rTmp2
  let tmp = rTmp3
  if src != x: buf.mv(x, src)
  if width == 32: buf.zextW(x, x)

  let zeroPatch = buf.pos
  buf.beq(x, zero, 0)
  buf.addi(dst, zero, 0)
  if width == 64:
    buf.loadImm(mask, cast[int64](0x8000_0000_0000_0000'u64))
  else:
    buf.loadImm32(mask, cast[int32](0x8000_0000'u32))

  let loopPos = buf.pos
  buf.andr(tmp, x, mask)
  let donePatch = buf.pos
  buf.bne(tmp, zero, 0)
  buf.addi(dst, dst, 1)
  buf.srli(mask, mask, 1)
  let backPatch = buf.pos
  buf.j(0)
  buf.patchJalTo(backPatch, loopPos)

  let zeroPos = buf.pos
  buf.patchBranchTo(zeroPatch, zeroPos)
  buf.addi(dst, zero, width.int32)
  let donePos = buf.pos
  buf.patchBranchTo(donePatch, donePos)

proc emitCtzFallbackRv64(buf: var Rv64AsmBuffer, dst, src: RvReg,
                         width: int) =
  let x = rTmp1
  let mask = rTmp2
  let tmp = rTmp3
  if src != x: buf.mv(x, src)
  if width == 32: buf.zextW(x, x)

  let zeroPatch = buf.pos
  buf.beq(x, zero, 0)
  buf.addi(dst, zero, 0)
  buf.addi(mask, zero, 1)

  let loopPos = buf.pos
  buf.andr(tmp, x, mask)
  let donePatch = buf.pos
  buf.bne(tmp, zero, 0)
  buf.addi(dst, dst, 1)
  buf.slli(mask, mask, 1)
  let backPatch = buf.pos
  buf.j(0)
  buf.patchJalTo(backPatch, loopPos)

  let zeroPos = buf.pos
  buf.patchBranchTo(zeroPatch, zeroPos)
  buf.addi(dst, zero, width.int32)
  let donePos = buf.pos
  buf.patchBranchTo(donePatch, donePos)

proc emitPopcntFallbackRv64(buf: var Rv64AsmBuffer, dst, src: RvReg,
                            width: int) =
  let x = rTmp1
  let tmp = rTmp2
  if src != x: buf.mv(x, src)
  if width == 32: buf.zextW(x, x)
  buf.addi(dst, zero, 0)

  let loopPos = buf.pos
  let donePatch = buf.pos
  buf.beq(x, zero, 0)
  buf.addi(dst, dst, 1)
  buf.addi(tmp, x, -1)
  buf.andr(x, x, tmp)
  let backPatch = buf.pos
  buf.j(0)
  buf.patchJalTo(backPatch, loopPos)

  let donePos = buf.pos
  buf.patchBranchTo(donePatch, donePos)

proc emitCmp32(buf: var Rv64AsmBuffer, instr: IrInstr, alloc: RegAllocResult,
               resReg: RvReg, spillBase: int32) =
  let a0 = buf.loadOperandRv64(alloc, instr.operands[0], spillBase, rTmp0)
  let b0 = buf.loadOperandRv64(alloc, instr.operands[1], spillBase, rTmp1)
  let signed = instr.op in {irLt32S, irGt32S, irLe32S, irGe32S}
  let a = if signed: (buf.sextW(rTmp0, a0); rTmp0) else: a0
  let b = if signed: (buf.sextW(rTmp1, b0); rTmp1) else: b0
  case instr.op
  of irEq32:
    buf.xorr(resReg, a, b); buf.seqz(resReg, resReg)
  of irNe32:
    buf.xorr(resReg, a, b); buf.snez(resReg, resReg)
  of irLt32S: buf.slt(resReg, a, b)
  of irLt32U: buf.sltu(resReg, a, b)
  of irGt32S: buf.slt(resReg, b, a)
  of irGt32U: buf.sltu(resReg, b, a)
  of irLe32S:
    buf.slt(resReg, b, a); buf.xori(resReg, resReg, 1)
  of irLe32U:
    buf.sltu(resReg, b, a); buf.xori(resReg, resReg, 1)
  of irGe32S:
    buf.slt(resReg, a, b); buf.xori(resReg, resReg, 1)
  of irGe32U:
    buf.sltu(resReg, a, b); buf.xori(resReg, resReg, 1)
  else: unsupportedRv64(instr.op)

proc emitCmp64(buf: var Rv64AsmBuffer, instr: IrInstr, alloc: RegAllocResult,
               resReg: RvReg, spillBase: int32) =
  let a = buf.loadOperandRv64(alloc, instr.operands[0], spillBase, rTmp0)
  let b = buf.loadOperandRv64(alloc, instr.operands[1], spillBase, rTmp1)
  case instr.op
  of irEq64:
    buf.xorr(resReg, a, b); buf.seqz(resReg, resReg)
  of irNe64:
    buf.xorr(resReg, a, b); buf.snez(resReg, resReg)
  of irLt64S: buf.slt(resReg, a, b)
  of irLt64U: buf.sltu(resReg, a, b)
  of irGt64S: buf.slt(resReg, b, a)
  of irGt64U: buf.sltu(resReg, b, a)
  of irLe64S:
    buf.slt(resReg, b, a); buf.xori(resReg, resReg, 1)
  of irLe64U:
    buf.sltu(resReg, b, a); buf.xori(resReg, resReg, 1)
  of irGe64S:
    buf.slt(resReg, a, b); buf.xori(resReg, resReg, 1)
  of irGe64U:
    buf.sltu(resReg, a, b); buf.xori(resReg, resReg, 1)
  else: unsupportedRv64(instr.op)

proc requireF32Rv64(target: Rv64Target, op: IrOpKind) =
  if rvExtF notin target.features:
    unsupportedRv64(op)

proc requireF64Rv64(target: Rv64Target, op: IrOpKind) =
  if rvExtD notin target.features:
    unsupportedRv64(op)

proc emitF32BinRv64(buf: var Rv64AsmBuffer, instr: IrInstr, alloc: RegAllocResult,
                    resReg: RvReg, spillBase: int32, target: Rv64Target) =
  target.requireF32Rv64(instr.op)
  let a = buf.loadOperandRv64(alloc, instr.operands[0], spillBase, rTmp0)
  let b = buf.loadOperandRv64(alloc, instr.operands[1], spillBase, rTmp1)
  buf.fmvWX(RvReg(0), a)
  buf.fmvWX(RvReg(1), b)
  case instr.op
  of irAddF32: buf.faddS(RvReg(0), RvReg(0), RvReg(1))
  of irSubF32: buf.fsubS(RvReg(0), RvReg(0), RvReg(1))
  of irMulF32: buf.fmulS(RvReg(0), RvReg(0), RvReg(1))
  of irDivF32: buf.fdivS(RvReg(0), RvReg(0), RvReg(1))
  of irMinF32: buf.fminS(RvReg(0), RvReg(0), RvReg(1))
  of irMaxF32: buf.fmaxS(RvReg(0), RvReg(0), RvReg(1))
  else: unsupportedRv64(instr.op)
  buf.fmvXW(resReg, RvReg(0))
  buf.zextW(resReg, resReg)

proc helperAddr64(fn: pointer): int64 =
  cast[int64](cast[uint64](cast[uint](fn)))

proc emitSaveCallerRv64(buf: var Rv64AsmBuffer) =
  for i, reg in rv64AllocRegs:
    buf.sd(reg, sp, rv64CallSaveBase + i.int32 * 8'i32)

proc emitRestoreCallerRv64(buf: var Rv64AsmBuffer) =
  for i, reg in rv64AllocRegs:
    buf.ld(reg, sp, rv64CallSaveBase + i.int32 * 8'i32)

proc emitCallF32UnaryHelperRv64(buf: var Rv64AsmBuffer, instr: IrInstr,
                                alloc: RegAllocResult, resReg: RvReg,
                                spillBase: int32, helper: pointer,
                                target: Rv64Target) =
  target.requireF32Rv64(instr.op)
  let a = buf.loadOperandRv64(alloc, instr.operands[0], spillBase, rTmp0)
  if a != a0: buf.mv(a0, a)
  buf.emitSaveCallerRv64()
  buf.loadImm(rTmp1, helperAddr64(helper))
  buf.jalr(ra, rTmp1, 0)
  buf.emitRestoreCallerRv64()
  if resReg != a0: buf.mv(resReg, a0)
  buf.zextW(resReg, resReg)

proc emitCallF64UnaryHelperRv64(buf: var Rv64AsmBuffer, instr: IrInstr,
                                alloc: RegAllocResult, resReg: RvReg,
                                spillBase: int32, helper: pointer,
                                target: Rv64Target) =
  target.requireF64Rv64(instr.op)
  let a = buf.loadOperandRv64(alloc, instr.operands[0], spillBase, rTmp0)
  if a != a0: buf.mv(a0, a)
  buf.emitSaveCallerRv64()
  buf.loadImm(rTmp1, helperAddr64(helper))
  buf.jalr(ra, rTmp1, 0)
  buf.emitRestoreCallerRv64()
  if resReg != a0: buf.mv(resReg, a0)

proc emitF32FmaRv64(buf: var Rv64AsmBuffer, instr: IrInstr,
                    alloc: RegAllocResult, resReg: RvReg,
                    spillBase: int32, target: Rv64Target) =
  target.requireF32Rv64(instr.op)
  let a = buf.loadOperandRv64(alloc, instr.operands[0], spillBase, rTmp0)
  let b = buf.loadOperandRv64(alloc, instr.operands[1], spillBase, rTmp1)
  let c = buf.loadOperandRv64(alloc, instr.operands[2], spillBase, rTmp2)
  buf.fmvWX(RvReg(0), a)
  buf.fmvWX(RvReg(1), b)
  buf.fmvWX(RvReg(2), c)
  case instr.op
  of irFmaF32:
    buf.fmaddS(RvReg(0), RvReg(0), RvReg(1), RvReg(2))
  of irFmsF32:
    buf.fmulS(RvReg(0), RvReg(0), RvReg(1))
    buf.fsubS(RvReg(0), RvReg(2), RvReg(0))
  of irFnmaF32:
    buf.fmulS(RvReg(0), RvReg(0), RvReg(1))
    buf.faddS(RvReg(0), RvReg(0), RvReg(2))
    buf.fmvXW(resReg, RvReg(0))
    buf.loadImm32(rTmp1, cast[int32](0x8000_0000'u32))
    buf.xorr(resReg, resReg, rTmp1)
    buf.zextW(resReg, resReg)
    return
  of irFnmsF32:
    buf.fmulS(RvReg(0), RvReg(0), RvReg(1))
    buf.fsubS(RvReg(0), RvReg(0), RvReg(2))
  else:
    unsupportedRv64(instr.op)
  buf.fmvXW(resReg, RvReg(0))
  buf.zextW(resReg, resReg)

proc emitF64FmaRv64(buf: var Rv64AsmBuffer, instr: IrInstr,
                    alloc: RegAllocResult, resReg: RvReg,
                    spillBase: int32, target: Rv64Target) =
  target.requireF64Rv64(instr.op)
  let a = buf.loadOperandRv64(alloc, instr.operands[0], spillBase, rTmp0)
  let b = buf.loadOperandRv64(alloc, instr.operands[1], spillBase, rTmp1)
  let c = buf.loadOperandRv64(alloc, instr.operands[2], spillBase, rTmp2)
  buf.fmvDX(RvReg(0), a)
  buf.fmvDX(RvReg(1), b)
  buf.fmvDX(RvReg(2), c)
  case instr.op
  of irFmaF64:
    buf.fmaddD(RvReg(0), RvReg(0), RvReg(1), RvReg(2))
  of irFmsF64:
    buf.fmulD(RvReg(0), RvReg(0), RvReg(1))
    buf.fsubD(RvReg(0), RvReg(2), RvReg(0))
  of irFnmaF64:
    buf.fmulD(RvReg(0), RvReg(0), RvReg(1))
    buf.faddD(RvReg(0), RvReg(0), RvReg(2))
    buf.fmvXD(resReg, RvReg(0))
    buf.loadImm(rTmp1, cast[int64](0x8000_0000_0000_0000'u64))
    buf.xorr(resReg, resReg, rTmp1)
    return
  of irFnmsF64:
    buf.fmulD(RvReg(0), RvReg(0), RvReg(1))
    buf.fsubD(RvReg(0), RvReg(0), RvReg(2))
  else:
    unsupportedRv64(instr.op)
  buf.fmvXD(resReg, RvReg(0))

proc emitF32CmpRv64(buf: var Rv64AsmBuffer, instr: IrInstr, alloc: RegAllocResult,
                    resReg: RvReg, spillBase: int32, target: Rv64Target) =
  target.requireF32Rv64(instr.op)
  let a = buf.loadOperandRv64(alloc, instr.operands[0], spillBase, rTmp0)
  let b = buf.loadOperandRv64(alloc, instr.operands[1], spillBase, rTmp1)
  buf.fmvWX(RvReg(0), a)
  buf.fmvWX(RvReg(1), b)
  case instr.op
  of irEqF32: buf.feqS(resReg, RvReg(0), RvReg(1))
  of irLtF32: buf.fltS(resReg, RvReg(0), RvReg(1))
  of irGtF32: buf.fltS(resReg, RvReg(1), RvReg(0))
  of irLeF32: buf.fleS(resReg, RvReg(0), RvReg(1))
  of irGeF32: buf.fleS(resReg, RvReg(1), RvReg(0))
  of irNeF32:
    buf.feqS(resReg, RvReg(0), RvReg(1))
    buf.xori(resReg, resReg, 1)
  else: unsupportedRv64(instr.op)

proc emitF64BinRv64(buf: var Rv64AsmBuffer, instr: IrInstr, alloc: RegAllocResult,
                    resReg: RvReg, spillBase: int32, target: Rv64Target) =
  target.requireF64Rv64(instr.op)
  let a = buf.loadOperandRv64(alloc, instr.operands[0], spillBase, rTmp0)
  let b = buf.loadOperandRv64(alloc, instr.operands[1], spillBase, rTmp1)
  buf.fmvDX(RvReg(0), a)
  buf.fmvDX(RvReg(1), b)
  case instr.op
  of irAddF64: buf.faddD(RvReg(0), RvReg(0), RvReg(1))
  of irSubF64: buf.fsubD(RvReg(0), RvReg(0), RvReg(1))
  of irMulF64: buf.fmulD(RvReg(0), RvReg(0), RvReg(1))
  of irDivF64: buf.fdivD(RvReg(0), RvReg(0), RvReg(1))
  of irMinF64: buf.fminD(RvReg(0), RvReg(0), RvReg(1))
  of irMaxF64: buf.fmaxD(RvReg(0), RvReg(0), RvReg(1))
  else: unsupportedRv64(instr.op)
  buf.fmvXD(resReg, RvReg(0))

proc emitF64CmpRv64(buf: var Rv64AsmBuffer, instr: IrInstr, alloc: RegAllocResult,
                    resReg: RvReg, spillBase: int32, target: Rv64Target) =
  target.requireF64Rv64(instr.op)
  let a = buf.loadOperandRv64(alloc, instr.operands[0], spillBase, rTmp0)
  let b = buf.loadOperandRv64(alloc, instr.operands[1], spillBase, rTmp1)
  buf.fmvDX(RvReg(0), a)
  buf.fmvDX(RvReg(1), b)
  case instr.op
  of irEqF64: buf.feqD(resReg, RvReg(0), RvReg(1))
  of irLtF64: buf.fltD(resReg, RvReg(0), RvReg(1))
  of irGtF64: buf.fltD(resReg, RvReg(1), RvReg(0))
  of irLeF64: buf.fleD(resReg, RvReg(0), RvReg(1))
  of irGeF64: buf.fleD(resReg, RvReg(1), RvReg(0))
  of irNeF64:
    buf.feqD(resReg, RvReg(0), RvReg(1))
    buf.xori(resReg, resReg, 1)
  else: unsupportedRv64(instr.op)

proc requireVectorRv64(target: Rv64Target, op: IrOpKind) =
  if rvExtV notin target.features and rvXTheadVector notin target.features:
    unsupportedRv64(op)

proc requireF32VectorRv64(target: Rv64Target, op: IrOpKind) =
  target.requireVectorRv64(op)
  if rvExtF notin target.features:
    unsupportedRv64(op)

proc requireF64VectorRv64(target: Rv64Target, op: IrOpKind) =
  target.requireVectorRv64(op)
  if rvExtD notin target.features:
    unsupportedRv64(op)

proc emitVsetRv64(buf: var Rv64AsmBuffer, target: Rv64Target,
                  sewBits, lanes: int) =
  buf.loadImm32(rTmp2, lanes.int32, zeroExtend = false)
  if rvXTheadVector in target.features:
    buf.vsetvliTHead07(zero, rTmp2, sewBits)
  else:
    buf.vsetvli(zero, rTmp2, sewBits)

proc simdStackOffsetRv64(alloc: RegAllocResult, v: IrValue,
                         spillBase: int32): int32 {.inline.} =
  spillBase + spillOffsetRv64(alloc, v)

proc emitLoadSimdFromLocalsRv64(buf: var Rv64AsmBuffer, alloc: RegAllocResult,
                                dst: IrValue, spillBase, localOff: int32) =
  let dstOff = simdStackOffsetRv64(alloc, dst, spillBase)
  buf.emitLoadLocalSlotRv64(rTmp0, localOff)
  buf.emitStoreStack(rTmp0, dstOff)
  buf.emitLoadLocalSlotRv64(rTmp0, localOff + 8)
  buf.emitStoreStack(rTmp0, dstOff + 8)

proc emitStoreSimdToLocalsRv64(buf: var Rv64AsmBuffer, alloc: RegAllocResult,
                               src: IrValue, spillBase, localOff: int32) =
  let srcOff = simdStackOffsetRv64(alloc, src, spillBase)
  buf.emitLoadStack(rTmp0, srcOff)
  buf.emitStoreLocalSlotRv64(rTmp0, localOff)
  buf.emitLoadStack(rTmp0, srcOff + 8)
  buf.emitStoreLocalSlotRv64(rTmp0, localOff + 8)

proc emitLoadSimdRv64(buf: var Rv64AsmBuffer, alloc: RegAllocResult,
                      v: IrValue, spillBase: int32, target: Rv64Target,
                      dst: RvReg = vTmp0) =
  buf.emitVsetRv64(target, 8, 16)
  buf.emitAddImm(rTmp1, sp, simdStackOffsetRv64(alloc, v, spillBase))
  buf.vle8V(dst, rTmp1)

proc emitStoreSimdRv64(buf: var Rv64AsmBuffer, alloc: RegAllocResult,
                       v: IrValue, spillBase: int32, target: Rv64Target,
                       src: RvReg) =
  if v < 0: return
  buf.emitVsetRv64(target, 8, 16)
  buf.emitAddImm(rTmp1, sp, simdStackOffsetRv64(alloc, v, spillBase))
  buf.vse8V(src, rTmp1)

proc emitCopySimdRv64(buf: var Rv64AsmBuffer, alloc: RegAllocResult,
                      dst, src: IrValue, spillBase: int32,
                      target: Rv64Target) =
  buf.emitLoadSimdRv64(alloc, src, spillBase, target, vTmp0)
  buf.emitStoreSimdRv64(alloc, dst, spillBase, target, vTmp0)

proc emitSimdLaneLoadRv64(buf: var Rv64AsmBuffer, alloc: RegAllocResult,
                          vec: IrValue, spillBase: int32, lane: int,
                          laneBytes: int32, dst: RvReg, signed = false) =
  let off = simdStackOffsetRv64(alloc, vec, spillBase) + (lane.int32 * laneBytes)
  buf.emitLoadStackScalar(dst, off, laneBytes, signed)

proc emitSimdLaneStoreRv64(buf: var Rv64AsmBuffer, alloc: RegAllocResult,
                           vec: IrValue, spillBase: int32, lane: int,
                           laneBytes: int32, src: RvReg) =
  let off = simdStackOffsetRv64(alloc, vec, spillBase) + (lane.int32 * laneBytes)
  buf.emitStoreStackScalar(src, off, laneBytes)

proc emitSimdConstRv64(buf: var Rv64AsmBuffer, f: IrFunc, alloc: RegAllocResult,
                       res: IrValue, spillBase: int32, idx: int) =
  var bytes: array[16, byte]
  if idx >= 0 and idx < f.v128Consts.len:
    bytes = f.v128Consts[idx]
  var lo, hi: uint64
  copyMem(addr lo, unsafeAddr bytes[0], 8)
  copyMem(addr hi, unsafeAddr bytes[8], 8)
  let off = simdStackOffsetRv64(alloc, res, spillBase)
  buf.loadImm(rTmp0, cast[int64](lo))
  buf.emitStoreStack(rTmp0, off)
  buf.loadImm(rTmp0, cast[int64](hi))
  buf.emitStoreStack(rTmp0, off + 8)

proc emitSimdSplatRv64(buf: var Rv64AsmBuffer, instr: IrInstr,
                       alloc: RegAllocResult, res: IrValue, spillBase: int32,
                       target: Rv64Target, sewBits, lanes: int) =
  target.requireVectorRv64(instr.op)
  let src = buf.loadOperandRv64(alloc, instr.operands[0], spillBase, rTmp0)
  buf.emitVsetRv64(target, sewBits, lanes)
  buf.vmvVx(vTmp0, src)
  buf.emitStoreSimdRv64(alloc, res, spillBase, target, vTmp0)

proc emitSimdBinaryRv64(buf: var Rv64AsmBuffer, instr: IrInstr,
                        alloc: RegAllocResult, res: IrValue, spillBase: int32,
                        target: Rv64Target, sewBits, lanes: int) =
  target.requireVectorRv64(instr.op)
  buf.emitLoadSimdRv64(alloc, instr.operands[0], spillBase, target, vTmp0)
  buf.emitLoadSimdRv64(alloc, instr.operands[1], spillBase, target, vTmp1)
  buf.emitVsetRv64(target, sewBits, lanes)
  case instr.op
  of irV128And:     buf.vandVv(vTmp2, vTmp0, vTmp1)
  of irV128Or:      buf.vorVv(vTmp2, vTmp0, vTmp1)
  of irV128Xor:     buf.vxorVv(vTmp2, vTmp0, vTmp1)
  of irV128AndNot:
    buf.vxorVi(vTmp3, vTmp1, -1)
    buf.vandVv(vTmp2, vTmp0, vTmp3)
  of irI8x16Add, irI16x8Add, irI32x4Add: buf.vaddVv(vTmp2, vTmp0, vTmp1)
  of irI8x16Sub, irI16x8Sub, irI32x4Sub: buf.vsubVv(vTmp2, vTmp0, vTmp1)
  of irI16x8Mul, irI32x4Mul:             buf.vmulVv(vTmp2, vTmp0, vTmp1)
  of irI8x16MinS, irI32x4MinS:           buf.vminVv(vTmp2, vTmp0, vTmp1)
  of irI8x16MinU, irI32x4MinU:           buf.vminuVv(vTmp2, vTmp0, vTmp1)
  of irI8x16MaxS, irI32x4MaxS:           buf.vmaxVv(vTmp2, vTmp0, vTmp1)
  of irI8x16MaxU, irI32x4MaxU:           buf.vmaxuVv(vTmp2, vTmp0, vTmp1)
  else: unsupportedRv64(instr.op)
  buf.emitStoreSimdRv64(alloc, res, spillBase, target, vTmp2)

proc emitSimdUnaryRv64(buf: var Rv64AsmBuffer, instr: IrInstr,
                       alloc: RegAllocResult, res: IrValue, spillBase: int32,
                       target: Rv64Target, sewBits, lanes: int) =
  target.requireVectorRv64(instr.op)
  buf.emitLoadSimdRv64(alloc, instr.operands[0], spillBase, target, vTmp0)
  buf.emitVsetRv64(target, sewBits, lanes)
  case instr.op
  of irV128Not:
    buf.vxorVi(vTmp1, vTmp0, -1)
  of irI8x16Neg, irI16x8Neg, irI32x4Neg:
    buf.vrsubVx(vTmp1, vTmp0, zero)
  of irI8x16Abs, irI16x8Abs, irI32x4Abs:
    buf.vrsubVx(vTmp2, vTmp0, zero)
    buf.vmsltVx(vMask, vTmp0, zero)
    buf.vmergeVvm(vTmp1, vTmp0, vTmp2)
  else:
    unsupportedRv64(instr.op)
  buf.emitStoreSimdRv64(alloc, res, spillBase, target, vTmp1)

proc emitSimdI32ShiftRv64(buf: var Rv64AsmBuffer, instr: IrInstr,
                          alloc: RegAllocResult, res: IrValue, spillBase: int32,
                          target: Rv64Target) =
  target.requireVectorRv64(instr.op)
  buf.emitLoadSimdRv64(alloc, instr.operands[0], spillBase, target, vTmp0)
  let cnt = buf.loadOperandRv64(alloc, instr.operands[1], spillBase, rTmp0)
  if cnt != rTmp0: buf.mv(rTmp0, cnt)
  buf.andi(rTmp0, rTmp0, 31)
  buf.emitVsetRv64(target, 32, 4)
  case instr.op
  of irI32x4Shl:  buf.vsllVx(vTmp1, vTmp0, rTmp0)
  of irI32x4ShrS: buf.vsraVx(vTmp1, vTmp0, rTmp0)
  of irI32x4ShrU: buf.vsrlVx(vTmp1, vTmp0, rTmp0)
  else: unsupportedRv64(instr.op)
  buf.emitStoreSimdRv64(alloc, res, spillBase, target, vTmp1)

proc emitSimdI64BinaryScalarRv64(buf: var Rv64AsmBuffer, instr: IrInstr,
                                 alloc: RegAllocResult, res: IrValue,
                                 spillBase: int32) =
  let aOff = simdStackOffsetRv64(alloc, instr.operands[0], spillBase)
  let bOff = simdStackOffsetRv64(alloc, instr.operands[1], spillBase)
  let rOff = simdStackOffsetRv64(alloc, res, spillBase)
  for lane in 0 .. 1:
    let off = lane.int32 * 8
    buf.emitLoadStackScalar(rTmp0, aOff + off, 8)
    buf.emitLoadStackScalar(rTmp1, bOff + off, 8)
    case instr.op
    of irI64x2Add: buf.add(rTmp0, rTmp0, rTmp1)
    of irI64x2Sub: buf.sub(rTmp0, rTmp0, rTmp1)
    else: unsupportedRv64(instr.op)
    buf.emitStoreStackScalar(rTmp0, rOff + off, 8)

proc emitSimdF32BinaryRv64(buf: var Rv64AsmBuffer, instr: IrInstr,
                           alloc: RegAllocResult, res: IrValue,
                           spillBase: int32, target: Rv64Target) =
  target.requireF32VectorRv64(instr.op)
  buf.emitLoadSimdRv64(alloc, instr.operands[0], spillBase, target, vTmp0)
  buf.emitLoadSimdRv64(alloc, instr.operands[1], spillBase, target, vTmp1)
  buf.emitVsetRv64(target, 32, 4)
  case instr.op
  of irF32x4Add: buf.vfaddVv(vTmp2, vTmp0, vTmp1)
  of irF32x4Sub: buf.vfsubVv(vTmp2, vTmp0, vTmp1)
  of irF32x4Mul: buf.vfmulVv(vTmp2, vTmp0, vTmp1)
  of irF32x4Div: buf.vfdivVv(vTmp2, vTmp0, vTmp1)
  else: unsupportedRv64(instr.op)
  buf.emitStoreSimdRv64(alloc, res, spillBase, target, vTmp2)

proc emitSimdF32UnaryRv64(buf: var Rv64AsmBuffer, instr: IrInstr,
                          alloc: RegAllocResult, res: IrValue,
                          spillBase: int32, target: Rv64Target) =
  target.requireF32VectorRv64(instr.op)
  buf.emitLoadSimdRv64(alloc, instr.operands[0], spillBase, target, vTmp0)
  buf.emitVsetRv64(target, 32, 4)
  case instr.op
  of irF32x4Abs: buf.vfsgnjxVv(vTmp1, vTmp0, vTmp0)
  of irF32x4Neg: buf.vfsgnjnVv(vTmp1, vTmp0, vTmp0)
  else: unsupportedRv64(instr.op)
  buf.emitStoreSimdRv64(alloc, res, spillBase, target, vTmp1)

proc emitSimdF64BinaryRv64(buf: var Rv64AsmBuffer, instr: IrInstr,
                           alloc: RegAllocResult, res: IrValue,
                           spillBase: int32, target: Rv64Target) =
  target.requireF64VectorRv64(instr.op)
  buf.emitLoadSimdRv64(alloc, instr.operands[0], spillBase, target, vTmp0)
  buf.emitLoadSimdRv64(alloc, instr.operands[1], spillBase, target, vTmp1)
  buf.emitVsetRv64(target, 64, 2)
  case instr.op
  of irF64x2Add: buf.vfaddVv(vTmp2, vTmp0, vTmp1)
  of irF64x2Sub: buf.vfsubVv(vTmp2, vTmp0, vTmp1)
  of irF64x2Mul: buf.vfmulVv(vTmp2, vTmp0, vTmp1)
  of irF64x2Div: buf.vfdivVv(vTmp2, vTmp0, vTmp1)
  else: unsupportedRv64(instr.op)
  buf.emitStoreSimdRv64(alloc, res, spillBase, target, vTmp2)

proc emitTrapIfA0NonZeroRv64(buf: var Rv64AsmBuffer) =
  buf.beq(a0, zero, 2)
  buf.ebreak()

proc emitDirectCallRv64(buf: var Rv64AsmBuffer, instr: IrInstr,
                        alloc: RegAllocResult, resReg: RvReg,
                        spillBase: int32, f: IrFunc,
                        funcElems: ptr UncheckedArray[TableElem],
                        numFuncs: int32) =
  let calleeIdx = instr.imm.int
  let targetPtr =
    if funcElems != nil and calleeIdx >= 0 and calleeIdx < numFuncs.int:
      addr funcElems[calleeIdx]
    else:
      nil
  let paramCount = if targetPtr != nil: targetPtr[].paramCount.int else: 0
  let resultCount = if targetPtr != nil: targetPtr[].resultCount.int else: 0
  if paramCount > rv64MaxDirectArgs.int:
    buf.ebreak()
    return

  var slotIdx = 0
  for i in 0 ..< paramCount:
    let opIdx = paramCount - 1 - i
    let dstOff = rv64DirectArgBase + slotIdx.int32 * 8'i32
    if opIdx >= 0 and opIdx < instr.operands.len and instr.operands[opIdx] >= 0:
      let argVal = instr.operands[opIdx]
      if f.isSimdValueRv64(argVal):
        let srcOff = simdStackOffsetRv64(alloc, argVal, spillBase)
        buf.emitLoadStack(rTmp0, srcOff)
        buf.emitStoreStack(rTmp0, dstOff)
        buf.emitLoadStack(rTmp0, srcOff + 8)
        buf.emitStoreStack(rTmp0, dstOff + 8)
        inc slotIdx, 2
      else:
        let arg = buf.loadOperandRv64(alloc, argVal, spillBase, rTmp0)
        buf.emitStoreStack(arg, dstOff)
        inc slotIdx
    else:
      buf.emitStoreStack(zero, dstOff)
      inc slotIdx

  buf.emitSaveCallerRv64()
  buf.loadImm(a0, cast[int64](cast[uint64](cast[uint](targetPtr))))
  buf.emitAddImm(a1, sp, rv64DirectArgBase)
  if f.usesMemory:
    buf.mv(a2, rMemBase)
    buf.mv(a3, rMemSize)
  else:
    buf.mv(a2, zero)
    buf.mv(a3, zero)
  buf.loadImm(rTmp1, helperAddr64(cast[pointer](tier2DirectDispatch)))
  buf.jalr(ra, rTmp1, 0)
  buf.emitRestoreCallerRv64()
  buf.emitTrapIfA0NonZeroRv64()

  if instr.result >= 0 and resultCount > 0:
    if f.isSimdValueRv64(instr.result):
      let dstOff = simdStackOffsetRv64(alloc, instr.result, spillBase)
      buf.emitLoadStack(rTmp0, rv64DirectArgBase)
      buf.emitStoreStack(rTmp0, dstOff)
      buf.emitLoadStack(rTmp0, rv64DirectArgBase + 8)
      buf.emitStoreStack(rTmp0, dstOff + 8)
    else:
      buf.ld(resReg, sp, rv64DirectArgBase)

proc emitIndirectCallRv64(buf: var Rv64AsmBuffer, instr: IrInstr,
                          alloc: RegAllocResult, resReg: RvReg,
                          spillBase: int32, f: IrFunc,
                          callIndirectCaches: seq[ptr CallIndirectCache],
                          callIndirectSiteIdx: int) =
  let resultCount = ((instr.imm shr 16) and 0xFFFF).int
  let tempBase = instr.imm2.int
  let argOff = f.localByteOffsetRv64(tempBase)
  let cacheIdx = callIndirectSiteIdx - 1
  let cachePtr =
    if cacheIdx >= 0 and cacheIdx < callIndirectCaches.len:
      callIndirectCaches[cacheIdx]
    else:
      nil

  let elem = buf.loadOperandRv64(alloc, instr.operands[0], spillBase, a1)
  if elem != a1: buf.mv(a1, elem)
  buf.emitSaveCallerRv64()
  buf.loadImm(a0, cast[int64](cast[uint64](cast[uint](cachePtr))))
  buf.emitAddImm(a2, rLocals, argOff)
  if f.usesMemory:
    buf.mv(a3, rMemBase)
    buf.mv(a4, rMemSize)
  else:
    buf.mv(a3, zero)
    buf.mv(a4, zero)
  buf.loadImm(rTmp1, helperAddr64(cast[pointer](tier2CallIndirectDispatch)))
  buf.jalr(ra, rTmp1, 0)
  buf.emitRestoreCallerRv64()
  buf.emitTrapIfA0NonZeroRv64()

  if instr.result >= 0 and resultCount > 0:
    if f.isSimdValueRv64(instr.result):
      buf.emitLoadSimdFromLocalsRv64(alloc, instr.result, spillBase, argOff)
    else:
      if fitsSimm12(argOff):
        buf.ld(resReg, rLocals, argOff)
      else:
        buf.emitAddImm(rTmp1, rLocals, argOff)
        buf.ld(resReg, rTmp1, 0)

proc emitIrInstrRv64(buf: var Rv64AsmBuffer, instr: IrInstr, f: IrFunc,
                     alloc: RegAllocResult, spillBase: int32,
                     curBlockIdx: int, blockLabels: var seq[Rv64BlockLabel],
                     epiloguePatchList: var seq[int], target: Rv64Target,
                     callIndirectCaches: seq[ptr CallIndirectCache],
                     callIndirectSiteIdx: int,
                     funcElems: ptr UncheckedArray[TableElem],
                     numFuncs: int32) =
  let res = instr.result
  let resReg = if res >= 0 and not alloc.isSpilledRv64(res): alloc.physRegRv64(res) else: rTmp0

  template loadOp(v: IrValue, s: RvReg): RvReg =
    buf.loadOperandRv64(alloc, v, spillBase, s)

  template storeRes(v: IrValue, src: RvReg) =
    buf.storeResultRv64(alloc, v, src, spillBase)

  case instr.op
  of irConst32:
    buf.loadImm32(resReg, instr.imm.int32)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)
  of irConst64:
    buf.loadImm(resReg, instr.imm)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)
  of irConstF32:
    buf.loadImm32(resReg, instr.imm.int32)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)
  of irConstF64:
    buf.loadImm(resReg, instr.imm)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irParam, irLocalGet:
    let off = f.localByteOffsetRv64(instr.imm.int)
    if f.isSimdValueRv64(res):
      buf.emitLoadSimdFromLocalsRv64(alloc, res, spillBase, off)
    else:
      if fitsSimm12(off):
        buf.ld(resReg, rLocals, off)
      else:
        buf.emitAddImm(rTmp1, rLocals, off)
        buf.ld(resReg, rTmp1, 0)
      if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irLocalSet:
    let off = f.localByteOffsetRv64(instr.imm.int)
    if f.isSimdValueRv64(instr.operands[0]):
      buf.emitStoreSimdToLocalsRv64(alloc, instr.operands[0], spillBase, off)
    else:
      let val = loadOp(instr.operands[0], rTmp0)
      if fitsSimm12(off):
        buf.sd(val, rLocals, off)
      else:
        let scratch = if val == rTmp1: rTmp0 else: rTmp1
        buf.emitAddImm(scratch, rLocals, off, if scratch == rTmp1: rTmp0 else: rTmp1)
        buf.sd(val, scratch, 0)

  of irAdd32, irSub32, irMul32, irAnd32, irOr32, irXor32,
     irShl32, irShr32U, irShr32S, irRotl32, irRotr32:
    buf.emitBin32(instr, alloc, resReg, spillBase, instr.op, target)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irDiv32S, irDiv32U, irRem32S, irRem32U:
    let a0 = loadOp(instr.operands[0], rTmp0)
    let b0 = loadOp(instr.operands[1], rTmp1)
    if instr.op in {irDiv32S, irRem32S}:
      buf.sextW(rTmp0, a0)
      buf.sextW(rTmp1, b0)
    else:
      if a0 != rTmp0: buf.mv(rTmp0, a0)
      if b0 != rTmp1: buf.mv(rTmp1, b0)
    case instr.op
    of irDiv32S: buf.divw(resReg, rTmp0, rTmp1)
    of irDiv32U: buf.divuw(resReg, rTmp0, rTmp1)
    of irRem32S: buf.remw(resReg, rTmp0, rTmp1)
    of irRem32U: buf.remuw(resReg, rTmp0, rTmp1)
    else: discard
    buf.zextW(resReg, resReg)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irClz32, irCtz32, irPopcnt32:
    let a = loadOp(instr.operands[0], rTmp0)
    if rvExtZbb in target.features:
      case instr.op
      of irClz32: buf.clzw(resReg, a)
      of irCtz32: buf.ctzw(resReg, a)
      of irPopcnt32: buf.cpopw(resReg, a)
      else: discard
      buf.zextW(resReg, resReg)
    else:
      case instr.op
      of irClz32: buf.emitClzFallbackRv64(resReg, a, 32)
      of irCtz32: buf.emitCtzFallbackRv64(resReg, a, 32)
      of irPopcnt32: buf.emitPopcntFallbackRv64(resReg, a, 32)
      else: discard
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irAdd64, irSub64, irMul64, irAnd64, irOr64, irXor64,
     irShl64, irShr64U, irShr64S, irRotl64, irRotr64:
    buf.emitBin64(instr, alloc, resReg, spillBase, instr.op, target)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irDiv64S, irDiv64U, irRem64S, irRem64U:
    let a = loadOp(instr.operands[0], rTmp0)
    let b = loadOp(instr.operands[1], rTmp1)
    case instr.op
    of irDiv64S: buf.divs(resReg, a, b)
    of irDiv64U: buf.divu(resReg, a, b)
    of irRem64S: buf.rems(resReg, a, b)
    of irRem64U: buf.remu(resReg, a, b)
    else: discard
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irAddF32, irSubF32, irMulF32, irDivF32, irMinF32, irMaxF32:
    buf.emitF32BinRv64(instr, alloc, resReg, spillBase, target)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irFmaF32, irFmsF32, irFnmaF32, irFnmsF32:
    buf.emitF32FmaRv64(instr, alloc, resReg, spillBase, target)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irAddF64, irSubF64, irMulF64, irDivF64, irMinF64, irMaxF64:
    buf.emitF64BinRv64(instr, alloc, resReg, spillBase, target)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irFmaF64, irFmsF64, irFnmaF64, irFnmsF64:
    buf.emitF64FmaRv64(instr, alloc, resReg, spillBase, target)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irSqrtF32:
    target.requireF32Rv64(instr.op)
    let a = loadOp(instr.operands[0], rTmp0)
    buf.fmvWX(RvReg(0), a)
    buf.fsqrtS(RvReg(0), RvReg(0))
    buf.fmvXW(resReg, RvReg(0))
    buf.zextW(resReg, resReg)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irSqrtF64:
    target.requireF64Rv64(instr.op)
    let a = loadOp(instr.operands[0], rTmp0)
    buf.fmvDX(RvReg(0), a)
    buf.fsqrtD(RvReg(0), RvReg(0))
    buf.fmvXD(resReg, RvReg(0))
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irAbsF32:
    let a = loadOp(instr.operands[0], rTmp0)
    buf.loadImm32(rTmp1, 0x7FFF_FFFF'i32)
    buf.andr(resReg, a, rTmp1)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irNegF32:
    let a = loadOp(instr.operands[0], rTmp0)
    buf.loadImm32(rTmp1, cast[int32](0x8000_0000'u32))
    buf.xorr(resReg, a, rTmp1)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irAbsF64:
    let a = loadOp(instr.operands[0], rTmp0)
    buf.loadImm(rTmp1, cast[int64](0x7FFF_FFFF_FFFF_FFFF'u64))
    buf.andr(resReg, a, rTmp1)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irNegF64:
    let a = loadOp(instr.operands[0], rTmp0)
    buf.loadImm(rTmp1, cast[int64](0x8000_0000_0000_0000'u64))
    buf.xorr(resReg, a, rTmp1)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irCopysignF32:
    let a = loadOp(instr.operands[0], rTmp0)
    let b = loadOp(instr.operands[1], rTmp1)
    buf.loadImm32(rTmp2, 0x7FFF_FFFF'i32)
    buf.andr(resReg, a, rTmp2)
    buf.loadImm32(rTmp2, cast[int32](0x8000_0000'u32))
    buf.andr(rTmp1, b, rTmp2)
    buf.orr(resReg, resReg, rTmp1)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irCopysignF64:
    let a = loadOp(instr.operands[0], rTmp0)
    let b = loadOp(instr.operands[1], rTmp1)
    buf.loadImm(rTmp2, cast[int64](0x7FFF_FFFF_FFFF_FFFF'u64))
    buf.andr(resReg, a, rTmp2)
    buf.loadImm(rTmp2, cast[int64](0x8000_0000_0000_0000'u64))
    buf.andr(rTmp1, b, rTmp2)
    buf.orr(resReg, resReg, rTmp1)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irCeilF32, irFloorF32, irTruncF32, irNearestF32:
    let helper = case instr.op
      of irCeilF32: cast[pointer](rvJitCeilF32Helper)
      of irFloorF32: cast[pointer](rvJitFloorF32Helper)
      of irTruncF32: cast[pointer](rvJitTruncF32Helper)
      of irNearestF32: cast[pointer](rvJitNearestF32Helper)
      else: nil
    buf.emitCallF32UnaryHelperRv64(instr, alloc, resReg, spillBase,
                                   helper, target)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irCeilF64, irFloorF64, irTruncF64, irNearestF64:
    let helper = case instr.op
      of irCeilF64: cast[pointer](rvJitCeilF64Helper)
      of irFloorF64: cast[pointer](rvJitFloorF64Helper)
      of irTruncF64: cast[pointer](rvJitTruncF64Helper)
      of irNearestF64: cast[pointer](rvJitNearestF64Helper)
      else: nil
    buf.emitCallF64UnaryHelperRv64(instr, alloc, resReg, spillBase,
                                   helper, target)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irEqF32, irNeF32, irLtF32, irGtF32, irLeF32, irGeF32:
    buf.emitF32CmpRv64(instr, alloc, resReg, spillBase, target)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irEqF64, irNeF64, irLtF64, irGtF64, irLeF64, irGeF64:
    buf.emitF64CmpRv64(instr, alloc, resReg, spillBase, target)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irF32ConvertI32S, irF32ConvertI32U:
    target.requireF32Rv64(instr.op)
    let a = loadOp(instr.operands[0], rTmp0)
    buf.fcvtsW(RvReg(0), a, unsigned = instr.op == irF32ConvertI32U)
    buf.fmvXW(resReg, RvReg(0))
    buf.zextW(resReg, resReg)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irF32ConvertI64S, irF32ConvertI64U:
    target.requireF32Rv64(instr.op)
    let a = loadOp(instr.operands[0], rTmp0)
    buf.fcvtSL(RvReg(0), a, unsigned = instr.op == irF32ConvertI64U)
    buf.fmvXW(resReg, RvReg(0))
    buf.zextW(resReg, resReg)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irI32TruncF32S, irI32TruncF32U:
    target.requireF32Rv64(instr.op)
    let a = loadOp(instr.operands[0], rTmp0)
    buf.fmvWX(RvReg(0), a)
    buf.fcvtWS(resReg, RvReg(0), unsigned = instr.op == irI32TruncF32U)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irI64TruncF32S, irI64TruncF32U:
    target.requireF32Rv64(instr.op)
    let a = loadOp(instr.operands[0], rTmp0)
    buf.fmvWX(RvReg(0), a)
    buf.fcvtLS(resReg, RvReg(0), unsigned = instr.op == irI64TruncF32U)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irF64ConvertI32S, irF64ConvertI32U:
    target.requireF64Rv64(instr.op)
    let a = loadOp(instr.operands[0], rTmp0)
    buf.fcvtDW(RvReg(0), a, unsigned = instr.op == irF64ConvertI32U)
    buf.fmvXD(resReg, RvReg(0))
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irF64ConvertI64S, irF64ConvertI64U:
    target.requireF64Rv64(instr.op)
    let a = loadOp(instr.operands[0], rTmp0)
    buf.fcvtDL(RvReg(0), a, unsigned = instr.op == irF64ConvertI64U)
    buf.fmvXD(resReg, RvReg(0))
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irI32TruncF64S, irI32TruncF64U:
    target.requireF64Rv64(instr.op)
    let a = loadOp(instr.operands[0], rTmp0)
    buf.fmvDX(RvReg(0), a)
    buf.fcvtWD(resReg, RvReg(0), unsigned = instr.op == irI32TruncF64U)
    buf.zextW(resReg, resReg)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irI64TruncF64S, irI64TruncF64U:
    target.requireF64Rv64(instr.op)
    let a = loadOp(instr.operands[0], rTmp0)
    buf.fmvDX(RvReg(0), a)
    buf.fcvtLD(resReg, RvReg(0), unsigned = instr.op == irI64TruncF64U)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irF32DemoteF64:
    target.requireF64Rv64(instr.op)
    target.requireF32Rv64(instr.op)
    let a = loadOp(instr.operands[0], rTmp0)
    buf.fmvDX(RvReg(0), a)
    buf.fcvtSD(RvReg(0), RvReg(0))
    buf.fmvXW(resReg, RvReg(0))
    buf.zextW(resReg, resReg)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irF64PromoteF32:
    target.requireF64Rv64(instr.op)
    target.requireF32Rv64(instr.op)
    let a = loadOp(instr.operands[0], rTmp0)
    buf.fmvWX(RvReg(0), a)
    buf.fcvtDS(RvReg(0), RvReg(0))
    buf.fmvXD(resReg, RvReg(0))
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irI32ReinterpretF32, irF32ReinterpretI32:
    let a = loadOp(instr.operands[0], rTmp0)
    if resReg != a: buf.mv(resReg, a)
    buf.zextW(resReg, resReg)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irI64ReinterpretF64, irF64ReinterpretI64:
    let a = loadOp(instr.operands[0], rTmp0)
    if resReg != a: buf.mv(resReg, a)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irClz64, irCtz64, irPopcnt64:
    let a = loadOp(instr.operands[0], rTmp0)
    if rvExtZbb in target.features:
      case instr.op
      of irClz64: buf.clz(resReg, a)
      of irCtz64: buf.ctz(resReg, a)
      of irPopcnt64: buf.cpop(resReg, a)
      else: discard
    else:
      case instr.op
      of irClz64: buf.emitClzFallbackRv64(resReg, a, 64)
      of irCtz64: buf.emitCtzFallbackRv64(resReg, a, 64)
      of irPopcnt64: buf.emitPopcntFallbackRv64(resReg, a, 64)
      else: discard
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irEqz32:
    let a = loadOp(instr.operands[0], rTmp0)
    buf.seqz(resReg, a)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)
  of irEqz64:
    let a = loadOp(instr.operands[0], rTmp0)
    buf.seqz(resReg, a)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irEq32, irNe32, irLt32S, irLt32U, irGt32S, irGt32U,
     irLe32S, irLe32U, irGe32S, irGe32U:
    buf.emitCmp32(instr, alloc, resReg, spillBase)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irEq64, irNe64, irLt64S, irLt64U, irGt64S, irGt64U,
     irLe64S, irLe64U, irGe64S, irGe64U:
    buf.emitCmp64(instr, alloc, resReg, spillBase)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irWrapI64:
    let a = loadOp(instr.operands[0], rTmp0)
    buf.zextW(resReg, a)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)
  of irExtendI32S, irExtend32S64:
    let a = loadOp(instr.operands[0], rTmp0)
    buf.sextW(resReg, a)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)
  of irExtendI32U:
    let a = loadOp(instr.operands[0], rTmp0)
    buf.zextW(resReg, a)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)
  of irExtend8S32, irExtend8S64:
    let a = loadOp(instr.operands[0], rTmp0)
    if rvExtZbb in target.features:
      buf.sextB(resReg, a)
    else:
      buf.slli(resReg, a, 56)
      buf.srai(resReg, resReg, 56)
    if instr.op == irExtend8S32: buf.zextW(resReg, resReg)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)
  of irExtend16S32, irExtend16S64:
    let a = loadOp(instr.operands[0], rTmp0)
    if rvExtZbb in target.features:
      buf.sextH(resReg, a)
    else:
      buf.slli(resReg, a, 48)
      buf.srai(resReg, resReg, 48)
    if instr.op == irExtend16S32: buf.zextW(resReg, resReg)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irLoad8U, irLoad8S, irLoad16U, irLoad16S, irLoad32, irLoad32U, irLoad32S, irLoad64:
    let addrReg = loadOp(instr.operands[0], rTmp0)
    let accessBytes = case instr.op
      of irLoad8U, irLoad8S: 1'i32
      of irLoad16U, irLoad16S: 2'i32
      of irLoad32, irLoad32U, irLoad32S: 4'i32
      else: 8'i32
    buf.emitBoundsCheckRv64(addrReg, accessBytes, instr.imm2)
    buf.emitLoadMemRv64(instr.op, resReg, addrReg, instr.imm2)
    if instr.op in {irLoad8U, irLoad8S, irLoad16U, irLoad16S, irLoad32, irLoad32U}:
      buf.zextW(resReg, resReg)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irLoadF32:
    let addrReg = loadOp(instr.operands[0], rTmp0)
    buf.emitBoundsCheckRv64(addrReg, 4, instr.imm2)
    buf.emitLoadMemRv64(irLoad32, resReg, addrReg, instr.imm2)
    buf.zextW(resReg, resReg)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irLoadF64:
    let addrReg = loadOp(instr.operands[0], rTmp0)
    buf.emitBoundsCheckRv64(addrReg, 8, instr.imm2)
    buf.emitLoadMemRv64(irLoad64, resReg, addrReg, instr.imm2)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irStore8, irStore16, irStore32, irStore32From64, irStore64:
    let addrReg = loadOp(instr.operands[0], rTmp0)
    let val = loadOp(instr.operands[1], rTmp2)
    let accessBytes = case instr.op
      of irStore8: 1'i32
      of irStore16: 2'i32
      of irStore32, irStore32From64: 4'i32
      else: 8'i32
    buf.emitBoundsCheckRv64(addrReg, accessBytes, instr.imm2)
    buf.emitStoreMemRv64(instr.op, val, addrReg, instr.imm2)

  of irStoreF32:
    let addrReg = loadOp(instr.operands[0], rTmp0)
    let val = loadOp(instr.operands[1], rTmp2)
    buf.emitBoundsCheckRv64(addrReg, 4, instr.imm2)
    buf.emitStoreMemRv64(irStore32, val, addrReg, instr.imm2)

  of irStoreF64:
    let addrReg = loadOp(instr.operands[0], rTmp0)
    let val = loadOp(instr.operands[1], rTmp2)
    buf.emitBoundsCheckRv64(addrReg, 8, instr.imm2)
    buf.emitStoreMemRv64(irStore64, val, addrReg, instr.imm2)

  # ---- SIMD v128 / RVV ----
  of irLoadV128:
    target.requireVectorRv64(instr.op)
    let addrVal = loadOp(instr.operands[0], rTmp0)
    buf.emitBoundsCheckRv64(addrVal, 16, instr.imm2)
    if instr.imm2 != 0:
      buf.emitAddImm(rTmp0, addrVal, instr.imm2)
    elif addrVal != rTmp0:
      buf.mv(rTmp0, addrVal)
    buf.add(rTmp1, rMemBase, rTmp0)
    buf.emitVsetRv64(target, 8, 16)
    buf.vle8V(vTmp0, rTmp1)
    buf.emitStoreSimdRv64(alloc, res, spillBase, target, vTmp0)

  of irStoreV128:
    target.requireVectorRv64(instr.op)
    let addrVal = loadOp(instr.operands[0], rTmp0)
    buf.emitBoundsCheckRv64(addrVal, 16, instr.imm2)
    if instr.imm2 != 0:
      buf.emitAddImm(rTmp0, addrVal, instr.imm2)
    elif addrVal != rTmp0:
      buf.mv(rTmp0, addrVal)
    buf.add(rTmp1, rMemBase, rTmp0)
    buf.emitLoadSimdRv64(alloc, instr.operands[1], spillBase, target, vTmp0)
    buf.emitVsetRv64(target, 8, 16)
    buf.vse8V(vTmp0, rTmp1)

  of irConstV128:
    buf.emitSimdConstRv64(f, alloc, res, spillBase, instr.imm.int)

  of irI8x16Splat:
    buf.emitSimdSplatRv64(instr, alloc, res, spillBase, target, 8, 16)
  of irI16x8Splat:
    buf.emitSimdSplatRv64(instr, alloc, res, spillBase, target, 16, 8)
  of irI32x4Splat, irF32x4Splat:
    buf.emitSimdSplatRv64(instr, alloc, res, spillBase, target, 32, 4)
  of irI64x2Splat, irF64x2Splat:
    let src = loadOp(instr.operands[0], rTmp0)
    let off = simdStackOffsetRv64(alloc, res, spillBase)
    buf.emitStoreStackScalar(src, off, 8)
    buf.emitStoreStackScalar(src, off + 8, 8)

  of irI8x16ExtractLaneS:
    buf.emitSimdLaneLoadRv64(alloc, instr.operands[0], spillBase,
                             instr.imm.int, 1, resReg, signed = true)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)
  of irI8x16ExtractLaneU:
    buf.emitSimdLaneLoadRv64(alloc, instr.operands[0], spillBase,
                             instr.imm.int, 1, resReg, signed = false)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)
  of irI16x8ExtractLaneS:
    buf.emitSimdLaneLoadRv64(alloc, instr.operands[0], spillBase,
                             instr.imm.int, 2, resReg, signed = true)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)
  of irI16x8ExtractLaneU:
    buf.emitSimdLaneLoadRv64(alloc, instr.operands[0], spillBase,
                             instr.imm.int, 2, resReg, signed = false)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)
  of irI32x4ExtractLane, irF32x4ExtractLane:
    buf.emitSimdLaneLoadRv64(alloc, instr.operands[0], spillBase,
                             instr.imm.int, 4, resReg, signed = false)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)
  of irI64x2ExtractLane, irF64x2ExtractLane:
    buf.emitSimdLaneLoadRv64(alloc, instr.operands[0], spillBase,
                             instr.imm.int, 8, resReg, signed = false)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irI8x16ReplaceLane:
    let val = loadOp(instr.operands[1], rTmp0)
    buf.emitCopySimdRv64(alloc, res, instr.operands[0], spillBase, target)
    buf.emitSimdLaneStoreRv64(alloc, res, spillBase, instr.imm.int, 1, val)
  of irI16x8ReplaceLane:
    let val = loadOp(instr.operands[1], rTmp0)
    buf.emitCopySimdRv64(alloc, res, instr.operands[0], spillBase, target)
    buf.emitSimdLaneStoreRv64(alloc, res, spillBase, instr.imm.int, 2, val)
  of irI32x4ReplaceLane, irF32x4ReplaceLane:
    let val = loadOp(instr.operands[1], rTmp0)
    buf.emitCopySimdRv64(alloc, res, instr.operands[0], spillBase, target)
    buf.emitSimdLaneStoreRv64(alloc, res, spillBase, instr.imm.int, 4, val)
  of irI64x2ReplaceLane, irF64x2ReplaceLane:
    let val = loadOp(instr.operands[1], rTmp0)
    buf.emitCopySimdRv64(alloc, res, instr.operands[0], spillBase, target)
    buf.emitSimdLaneStoreRv64(alloc, res, spillBase, instr.imm.int, 8, val)

  of irV128Not:
    buf.emitSimdUnaryRv64(instr, alloc, res, spillBase, target, 8, 16)
  of irV128And, irV128Or, irV128Xor, irV128AndNot:
    buf.emitSimdBinaryRv64(instr, alloc, res, spillBase, target, 8, 16)

  of irI8x16Abs, irI8x16Neg:
    buf.emitSimdUnaryRv64(instr, alloc, res, spillBase, target, 8, 16)
  of irI8x16Add, irI8x16Sub, irI8x16MinS, irI8x16MinU,
     irI8x16MaxS, irI8x16MaxU:
    buf.emitSimdBinaryRv64(instr, alloc, res, spillBase, target, 8, 16)

  of irI16x8Abs, irI16x8Neg:
    buf.emitSimdUnaryRv64(instr, alloc, res, spillBase, target, 16, 8)
  of irI16x8Add, irI16x8Sub, irI16x8Mul:
    buf.emitSimdBinaryRv64(instr, alloc, res, spillBase, target, 16, 8)

  of irI32x4Abs, irI32x4Neg:
    buf.emitSimdUnaryRv64(instr, alloc, res, spillBase, target, 32, 4)
  of irI32x4Add, irI32x4Sub, irI32x4Mul,
     irI32x4MinS, irI32x4MinU, irI32x4MaxS, irI32x4MaxU:
    buf.emitSimdBinaryRv64(instr, alloc, res, spillBase, target, 32, 4)
  of irI32x4Shl, irI32x4ShrS, irI32x4ShrU:
    buf.emitSimdI32ShiftRv64(instr, alloc, res, spillBase, target)

  of irI64x2Add, irI64x2Sub:
    buf.emitSimdI64BinaryScalarRv64(instr, alloc, res, spillBase)

  of irF32x4Add, irF32x4Sub, irF32x4Mul, irF32x4Div:
    buf.emitSimdF32BinaryRv64(instr, alloc, res, spillBase, target)
  of irF32x4Abs, irF32x4Neg:
    buf.emitSimdF32UnaryRv64(instr, alloc, res, spillBase, target)

  of irF64x2Add, irF64x2Sub, irF64x2Mul, irF64x2Div:
    buf.emitSimdF64BinaryRv64(instr, alloc, res, spillBase, target)
  of irF64x2Abs, irF64x2Neg:
    let mask = if instr.op == irF64x2Abs:
      0x7FFF_FFFF_FFFF_FFFF'u64
    else:
      0x8000_0000_0000_0000'u64
    let srcOff = simdStackOffsetRv64(alloc, instr.operands[0], spillBase)
    let dstOff = simdStackOffsetRv64(alloc, res, spillBase)
    buf.loadImm(rTmp1, cast[int64](mask))
    for lane in 0 .. 1:
      let off = lane.int32 * 8
      buf.emitLoadStackScalar(rTmp0, srcOff + off, 8)
      if instr.op == irF64x2Abs:
        buf.andr(rTmp0, rTmp0, rTmp1)
      else:
        buf.xorr(rTmp0, rTmp0, rTmp1)
      buf.emitStoreStackScalar(rTmp0, dstOff + off, 8)

  of irBr:
    let targetBb = instr.imm.int
    buf.emitPhiResolutionRv64(f, alloc, targetBb, curBlockIdx, spillBase)
    if targetBb < blockLabels.len and blockLabels[targetBb].offset >= 0:
      buf.j((blockLabels[targetBb].offset - buf.pos).int32)
    else:
      blockLabels.ensureLabel(targetBb)
      let p = buf.pos
      buf.j(0)
      blockLabels[targetBb].patchList.add((p, false))

  of irBrIf:
    let cond = loadOp(instr.operands[0], rTmp0)
    let targetBb = instr.imm.int
    buf.emitPhiResolutionRv64(f, alloc, targetBb, curBlockIdx, spillBase)
    if targetBb < blockLabels.len and blockLabels[targetBb].offset >= 0:
      buf.bne(cond, zero, (blockLabels[targetBb].offset - buf.pos).int32)
    else:
      blockLabels.ensureLabel(targetBb)
      let p = buf.pos
      buf.bne(cond, zero, 0)
      blockLabels[targetBb].patchList.add((p, true))
    let falseBb = instr.imm2.int
    if falseBb > 0:
      buf.emitPhiResolutionRv64(f, alloc, falseBb, curBlockIdx, spillBase)
      if falseBb < blockLabels.len and blockLabels[falseBb].offset >= 0:
        buf.j((blockLabels[falseBb].offset - buf.pos).int32)
      else:
        blockLabels.ensureLabel(falseBb)
        let p = buf.pos
        buf.j(0)
        blockLabels[falseBb].patchList.add((p, false))

  of irReturn:
    if instr.operands[0] >= 0:
      if f.isSimdValueRv64(instr.operands[0]):
        let srcOff = simdStackOffsetRv64(alloc, instr.operands[0], spillBase)
        buf.emitLoadStack(rTmp0, srcOff)
        buf.sd(rTmp0, rVsp, 0)
        buf.emitLoadStack(rTmp0, srcOff + 8)
        buf.sd(rTmp0, rVsp, 8)
        buf.addi(rVsp, rVsp, 16)
      else:
        let val = loadOp(instr.operands[0], rTmp0)
        buf.sd(val, rVsp, 0)
        buf.addi(rVsp, rVsp, 8)
    let p = buf.pos
    buf.j(0)
    epiloguePatchList.add(p)

  of irSelect:
    let cond = loadOp(instr.operands[0], rTmp1)
    let a = loadOp(instr.operands[1], rTmp0)
    let b = loadOp(instr.operands[2], rTmp2)
    if rv64XTheadCondMov in target.features:
      if resReg != b: buf.mv(resReg, b)
      buf.thMvnez(resReg, a, cond)
    else:
      if resReg != a: buf.mv(resReg, a)
      buf.bne(cond, zero, 2)
      if resReg != b: buf.mv(resReg, b)
    if alloc.isSpilledRv64(res): storeRes(res, resReg)

  of irCall:
    buf.emitDirectCallRv64(instr, alloc, resReg, spillBase, f,
                           funcElems, numFuncs)
    if instr.result >= 0 and not f.isSimdValueRv64(res) and alloc.isSpilledRv64(res):
      storeRes(res, resReg)

  of irCallIndirect:
    buf.emitIndirectCallRv64(instr, alloc, resReg, spillBase, f,
                             callIndirectCaches, callIndirectSiteIdx)
    if instr.result >= 0 and not f.isSimdValueRv64(res) and alloc.isSpilledRv64(res):
      storeRes(res, resReg)

  of irPhi:
    discard
  of irNop:
    if instr.operands[0] >= 0 and res >= 0:
      if f.isSimdValueRv64(res):
        buf.emitCopySimdRv64(alloc, res, instr.operands[0], spillBase, target)
      else:
        let v = loadOp(instr.operands[0], rTmp0)
        if resReg != v: buf.mv(resReg, v)
        if alloc.isSpilledRv64(res): storeRes(res, resReg)
    else:
      buf.nop()
  of irTrap:
    buf.ebreak()
  else:
    unsupportedRv64(instr.op)

proc emitIrFuncRv64*(pool: var JitMemPool, f: IrFunc, alloc: RegAllocResult,
                     selfModuleIdx: int = -1,
                     tableElems: ptr UncheckedArray[TableElem] = nil,
                     tableLen: int32 = 0,
                     funcElems: ptr UncheckedArray[TableElem] = nil,
                     numFuncs: int32 = 0,
                     target: Rv64Target = rv64GenericTarget): JitCode =
  discard selfModuleIdx

  if target.xlen != rv64:
    raise newException(ValueError, "RV64 JIT backend requires an RV64 target")

  var buf = initRv64AsmBuffer(f.numValues * 6 + 96)

  let spillBytes = alloc.totalSpillBytes
  let frameSize = (savedBytes + spillBytes.int32 + 15'i32) and (not 15'i32)
  let spillBase = savedBytes

  # Prologue.
  if fitsSimm12(-frameSize):
    buf.addi(sp, sp, -frameSize)
  else:
    buf.loadImm(rTmp1, frameSize.int64)
    buf.sub(sp, sp, rTmp1)

  if rv64XTheadMemPair in target.features:
    buf.thSdd(ra, s0, sp, 0)
    buf.thSdd(s1, s2, sp, 1)
    buf.thSdd(s3, s4, sp, 2)
  else:
    buf.sd(ra, sp, 0)
    buf.sd(s0, sp, 8)
    buf.sd(s1, sp, 16)
    buf.sd(s2, sp, 24)
    buf.sd(s3, sp, 32)
    buf.sd(s4, sp, 40)

  buf.mv(rVsp, a0)
  buf.mv(rLocals, a1)
  if f.usesMemory:
    buf.mv(rMemBase, a2)
    buf.mv(rMemSize, a3)

  var callIndirectCaches = newSeq[ptr CallIndirectCache](f.callIndirectSiteCount)
  for i in 0 ..< f.callIndirectSiteCount:
    let p = cast[ptr CallIndirectCache](allocShared0(sizeof(CallIndirectCache)))
    p.cachedElemIdx = -1
    p.tableElems = tableElems
    p.tableLen = tableLen
    pool.sideData.add(p)
    callIndirectCaches[i] = p

  var blockLabels = newSeq[Rv64BlockLabel](f.blocks.len)
  for i in 0 ..< blockLabels.len:
    blockLabels[i].offset = -1
  var epiloguePatchList: seq[int]
  var callIndirectSiteIdx = 0

  for bbIdx in 0 ..< f.blocks.len:
    let bb = f.blocks[bbIdx]
    blockLabels.ensureLabel(bbIdx)
    blockLabels[bbIdx].offset = buf.pos

    for (patchPos, isCond) in blockLabels[bbIdx].patchList:
      let off = (buf.pos - patchPos).int32
      if isCond:
        buf.patchBranchAt(patchPos, off)
      else:
        buf.patchJalAt(patchPos, off)
    blockLabels[bbIdx].patchList.setLen(0)

    for instr in bb.instrs:
      if instr.op == irCallIndirect:
        let siteCache =
          if callIndirectSiteIdx < callIndirectCaches.len:
            callIndirectCaches[callIndirectSiteIdx]
          else:
            nil
        if siteCache != nil:
          siteCache.paramCount = (instr.imm and 0xFFFF).int32
          siteCache.resultCount = ((instr.imm shr 16) and 0xFFFF).int32
          siteCache.paramSlotCount = ((instr.imm shr 32) and 0xFFFF).int32
          siteCache.resultSlotCount = ((instr.imm shr 48) and 0xFFFF).int32
        inc callIndirectSiteIdx
      buf.emitIrInstrRv64(instr, f, alloc, spillBase, bbIdx, blockLabels,
                          epiloguePatchList, target, callIndirectCaches,
                          callIndirectSiteIdx, funcElems, numFuncs)

  let epilogueOffset = buf.pos
  for patchPos in epiloguePatchList:
    buf.patchJalAt(patchPos, (epilogueOffset - patchPos).int32)

  # Epilogue.
  buf.mv(a0, rVsp)
  if rv64XTheadMemPair in target.features:
    buf.thLdd(ra, s0, sp, 0)
    buf.thLdd(s1, s2, sp, 1)
    buf.thLdd(s3, s4, sp, 2)
  else:
    buf.ld(ra, sp, 0)
    buf.ld(s0, sp, 8)
    buf.ld(s1, sp, 16)
    buf.ld(s2, sp, 24)
    buf.ld(s3, sp, 32)
    buf.ld(s4, sp, 40)

  if fitsSimm12(frameSize):
    buf.addi(sp, sp, frameSize)
  else:
    buf.loadImm(rTmp1, frameSize.int64)
    buf.add(sp, sp, rTmp1)
  buf.ret()

  result = pool.writeCode(buf.code)
  result.size = buf.code.len * 4
  result.numLocals = if f.localSlotCount > 0: f.localSlotCount else: f.numLocals
