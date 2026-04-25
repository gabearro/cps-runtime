## RV32 IR code generator (Tier 2 backend).
##
## This backend targets the external JIT ABI on RV32:
##   (a0=VSP, a1=locals, a2=memBase, a3=memSizeLow, a4=memSizeHigh) -> a0
##
## The existing register allocator maps one SSA value to one native register.
## RV32 uses that register/slot for the low 32 bits of i64 values and keeps the
## high 32 bits in a backend-private stack slot for each SSA value.

import std/math
import ../types
import ir, regalloc, codegen_rv64, memory, compiler

const
  NumIntRegsRv32* = 0
  CalleeSavedStartRv32* = 0'i8

const
  rTmp0 = t0
  rTmp1 = t1
  rTmp2 = t2
  rTmp3 = a4
  rTmp4 = a5
  rTmp5 = a0
  rVsp = s1
  rLocals = s0
  rMemBase = a2
  rMemSize = a3
  rv32DirectArgBase = 28'i32
  rv32MaxDirectArgs = 3'i32
  rv32MaxDirectArgSlots = rv32MaxDirectArgs * 2'i32
  savedBytes = (rv32DirectArgBase + rv32MaxDirectArgSlots * 8'i32 + 15'i32) and
               (not 15'i32)
  tmpSlot0 = 12'i32
  tmpSlot1 = 16'i32
  tmpSlot2 = 20'i32
  tmpSlot3 = 24'i32

type
  Rv32ValueKind* = enum
    rv32ValUnknown
    rv32ValI32
    rv32ValI64

  Rv32BlockLabel = object
    offset: int
    patchList: seq[(int, bool)] ## (instruction index, true = conditional branch)

proc unsupportedRv32(op: IrOpKind) {.gcsafe.} =
  raise newException(ValueError, "RV32 JIT backend does not support " & $op)

proc rv32JitDivU64Helper(a, b: uint64): uint64 {.cdecl, used.} =
  if b == 0'u64: uint64.high else: a div b

proc rv32JitRemU64Helper(a, b: uint64): uint64 {.cdecl, used.} =
  if b == 0'u64: a else: a mod b

proc rv32JitDivS64Helper(a, b: uint64): uint64 {.cdecl, used.} =
  let aa = cast[int64](a)
  let bb = cast[int64](b)
  if bb == 0'i64:
    return cast[uint64](-1'i64)
  if aa == int64.low and bb == -1'i64:
    return cast[uint64](aa)
  cast[uint64](aa div bb)

proc rv32JitRemS64Helper(a, b: uint64): uint64 {.cdecl, used.} =
  let aa = cast[int64](a)
  let bb = cast[int64](b)
  if bb == 0'i64:
    return a
  if aa == int64.low and bb == -1'i64:
    return 0'u64
  cast[uint64](aa mod bb)

proc rv32JitCeilF32Helper(bits: uint32): uint32 {.cdecl, used.} =
  cast[uint32](ceil(cast[float32](bits)))

proc rv32JitFloorF32Helper(bits: uint32): uint32 {.cdecl, used.} =
  cast[uint32](floor(cast[float32](bits)))

proc rv32JitTruncF32Helper(bits: uint32): uint32 {.cdecl, used.} =
  cast[uint32](trunc(cast[float32](bits)))

proc rv32JitNearestF32Helper(bits: uint32): uint32 {.cdecl, used.} =
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

proc rv32JitF32ConvertI64SHelper(lo, hi: uint32): uint32 {.cdecl, used.} =
  let u = (hi.uint64 shl 32) or lo.uint64
  cast[uint32](cast[int64](u).float32)

proc rv32JitF32ConvertI64UHelper(lo, hi: uint32): uint32 {.cdecl, used.} =
  let u = (hi.uint64 shl 32) or lo.uint64
  cast[uint32](u.float32)

proc rv32JitI64TruncF32SHelper(bits: uint32): uint64 {.cdecl, used.} =
  cast[uint64](int64(cast[float32](bits)))

proc rv32JitI64TruncF32UHelper(bits: uint32): uint64 {.cdecl, used.} =
  uint64(cast[float32](bits))

proc f64FromParts(lo, hi: uint32): float64 {.inline.} =
  cast[float64]((hi.uint64 shl 32) or lo.uint64)

proc f64Bits(x: float64): uint64 {.inline.} =
  cast[uint64](x)

proc rv32JitAddF64Helper(aLo, aHi, bLo, bHi: uint32): uint64 {.cdecl, used.} =
  f64Bits(f64FromParts(aLo, aHi) + f64FromParts(bLo, bHi))

proc rv32JitSubF64Helper(aLo, aHi, bLo, bHi: uint32): uint64 {.cdecl, used.} =
  f64Bits(f64FromParts(aLo, aHi) - f64FromParts(bLo, bHi))

proc rv32JitMulF64Helper(aLo, aHi, bLo, bHi: uint32): uint64 {.cdecl, used.} =
  f64Bits(f64FromParts(aLo, aHi) * f64FromParts(bLo, bHi))

proc rv32JitDivF64Helper(aLo, aHi, bLo, bHi: uint32): uint64 {.cdecl, used.} =
  f64Bits(f64FromParts(aLo, aHi) / f64FromParts(bLo, bHi))

proc rv32JitMinF64Helper(aLo, aHi, bLo, bHi: uint32): uint64 {.cdecl, used.} =
  f64Bits(min(f64FromParts(aLo, aHi), f64FromParts(bLo, bHi)))

proc rv32JitMaxF64Helper(aLo, aHi, bLo, bHi: uint32): uint64 {.cdecl, used.} =
  f64Bits(max(f64FromParts(aLo, aHi), f64FromParts(bLo, bHi)))

proc rv32JitSqrtF64Helper(aLo, aHi: uint32): uint64 {.cdecl, used.} =
  f64Bits(sqrt(f64FromParts(aLo, aHi)))

proc rv32JitCeilF64Helper(aLo, aHi: uint32): uint64 {.cdecl, used.} =
  f64Bits(ceil(f64FromParts(aLo, aHi)))

proc rv32JitFloorF64Helper(aLo, aHi: uint32): uint64 {.cdecl, used.} =
  f64Bits(floor(f64FromParts(aLo, aHi)))

proc rv32JitTruncF64Helper(aLo, aHi: uint32): uint64 {.cdecl, used.} =
  f64Bits(trunc(f64FromParts(aLo, aHi)))

proc rv32JitNearestF64Helper(aLo, aHi: uint32): uint64 {.cdecl, used.} =
  let bits = (aHi.uint64 shl 32) or aLo.uint64
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
  f64Bits(y)

proc rv32JitFmaF64Helper(aLo, aHi, bLo, bHi, cLo, cHi: uint32): uint64 {.cdecl, used.} =
  f64Bits(f64FromParts(aLo, aHi) * f64FromParts(bLo, bHi) + f64FromParts(cLo, cHi))

proc rv32JitFmsF64Helper(aLo, aHi, bLo, bHi, cLo, cHi: uint32): uint64 {.cdecl, used.} =
  f64Bits(f64FromParts(cLo, cHi) - f64FromParts(aLo, aHi) * f64FromParts(bLo, bHi))

proc rv32JitFnmaF64Helper(aLo, aHi, bLo, bHi, cLo, cHi: uint32): uint64 {.cdecl, used.} =
  f64Bits(-(f64FromParts(aLo, aHi) * f64FromParts(bLo, bHi) + f64FromParts(cLo, cHi)))

proc rv32JitFnmsF64Helper(aLo, aHi, bLo, bHi, cLo, cHi: uint32): uint64 {.cdecl, used.} =
  f64Bits(f64FromParts(aLo, aHi) * f64FromParts(bLo, bHi) - f64FromParts(cLo, cHi))

proc rv32JitEqF64Helper(aLo, aHi, bLo, bHi: uint32): uint32 {.cdecl, used.} =
  if f64FromParts(aLo, aHi) == f64FromParts(bLo, bHi): 1'u32 else: 0'u32

proc rv32JitNeF64Helper(aLo, aHi, bLo, bHi: uint32): uint32 {.cdecl, used.} =
  if f64FromParts(aLo, aHi) != f64FromParts(bLo, bHi): 1'u32 else: 0'u32

proc rv32JitLtF64Helper(aLo, aHi, bLo, bHi: uint32): uint32 {.cdecl, used.} =
  if f64FromParts(aLo, aHi) < f64FromParts(bLo, bHi): 1'u32 else: 0'u32

proc rv32JitGtF64Helper(aLo, aHi, bLo, bHi: uint32): uint32 {.cdecl, used.} =
  if f64FromParts(aLo, aHi) > f64FromParts(bLo, bHi): 1'u32 else: 0'u32

proc rv32JitLeF64Helper(aLo, aHi, bLo, bHi: uint32): uint32 {.cdecl, used.} =
  if f64FromParts(aLo, aHi) <= f64FromParts(bLo, bHi): 1'u32 else: 0'u32

proc rv32JitGeF64Helper(aLo, aHi, bLo, bHi: uint32): uint32 {.cdecl, used.} =
  if f64FromParts(aLo, aHi) >= f64FromParts(bLo, bHi): 1'u32 else: 0'u32

proc rv32JitF64ConvertI32SHelper(a: uint32): uint64 {.cdecl, used.} =
  f64Bits(cast[int32](a).float64)

proc rv32JitF64ConvertI32UHelper(a: uint32): uint64 {.cdecl, used.} =
  f64Bits(a.float64)

proc rv32JitF64ConvertI64SHelper(lo, hi: uint32): uint64 {.cdecl, used.} =
  f64Bits(cast[int64]((hi.uint64 shl 32) or lo.uint64).float64)

proc rv32JitF64ConvertI64UHelper(lo, hi: uint32): uint64 {.cdecl, used.} =
  f64Bits(((hi.uint64 shl 32) or lo.uint64).float64)

proc rv32JitI32TruncF64SHelper(lo, hi: uint32): uint32 {.cdecl, used.} =
  cast[uint32](int32(f64FromParts(lo, hi)))

proc rv32JitI32TruncF64UHelper(lo, hi: uint32): uint32 {.cdecl, used.} =
  uint32(f64FromParts(lo, hi))

proc rv32JitI64TruncF64SHelper(lo, hi: uint32): uint64 {.cdecl, used.} =
  cast[uint64](int64(f64FromParts(lo, hi)))

proc rv32JitI64TruncF64UHelper(lo, hi: uint32): uint64 {.cdecl, used.} =
  uint64(f64FromParts(lo, hi))

proc rv32JitF32DemoteF64Helper(lo, hi: uint32): uint32 {.cdecl, used.} =
  cast[uint32](f64FromParts(lo, hi).float32)

proc rv32JitF64PromoteF32Helper(bits: uint32): uint64 {.cdecl, used.} =
  f64Bits(cast[float32](bits).float64)

proc toRv32Kind(vt: ValType): Rv32ValueKind =
  case vt
  of vtI32, vtF32: rv32ValI32
  of vtI64, vtF64: rv32ValI64
  else: rv32ValUnknown

proc countImportFuncs(module: WasmModule): int =
  for imp in module.imports:
    if imp.kind == ikFunc:
      inc result

proc moduleLocalKinds(module: WasmModule, funcIdx: int, f: IrFunc): seq[Rv32ValueKind] =
  result = newSeq[Rv32ValueKind](f.numLocals)
  let localFuncIdx = funcIdx - module.countImportFuncs()
  let body = module.codes[localFuncIdx]
  let ft = module.types[module.funcTypeIdxs[localFuncIdx].int]

  var idx = 0
  for vt in ft.params:
    if idx < result.len: result[idx] = vt.toRv32Kind
    inc idx
  for ld in body.locals:
    for _ in 0 ..< ld.count.int:
      if idx < result.len: result[idx] = ld.valType.toRv32Kind
      inc idx
  for imp in module.imports:
    if imp.kind == ikGlobal:
      if idx < result.len: result[idx] = imp.globalType.valType.toRv32Kind
      inc idx
  for g in module.globals:
    if idx < result.len: result[idx] = g.globalType.valType.toRv32Kind
    inc idx

proc setKind(kinds: var seq[Rv32ValueKind], v: IrValue, k: Rv32ValueKind): bool =
  if v < 0 or k == rv32ValUnknown: return false
  let i = v.int
  if i < 0 or i >= kinds.len: return false
  if kinds[i] == rv32ValUnknown:
    kinds[i] = k
    return true
  if kinds[i] != k:
    raise newException(ValueError, "RV32 JIT inferred inconsistent value widths")
  false

proc setLocalKind(kinds: var seq[Rv32ValueKind], idx: int, k: Rv32ValueKind): bool =
  if idx < 0 or idx >= kinds.len or k == rv32ValUnknown: return false
  if kinds[idx] == rv32ValUnknown:
    kinds[idx] = k
    return true
  if kinds[idx] != k:
    raise newException(ValueError, "RV32 JIT inferred inconsistent local widths")
  false

proc kindOf(kinds: seq[Rv32ValueKind], v: IrValue): Rv32ValueKind =
  if v >= 0 and v.int < kinds.len: kinds[v.int] else: rv32ValUnknown

proc inferRv32ValueKinds*(module: WasmModule, funcIdx: int, f: IrFunc): seq[Rv32ValueKind] =
  result = newSeq[Rv32ValueKind](f.numValues)
  var locals = module.moduleLocalKinds(funcIdx, f)

  let localFuncIdx = funcIdx - module.countImportFuncs()
  let ft = module.types[module.funcTypeIdxs[localFuncIdx].int]
  let retKind =
    if ft.results.len > 0: ft.results[0].toRv32Kind else: rv32ValUnknown

  var changed = true
  while changed:
    changed = false
    for bb in f.blocks:
      for instr in bb.instrs:
        template res(k: Rv32ValueKind) =
          if result.setKind(instr.result, k): changed = true
        template op(i: int, k: Rv32ValueKind) =
          if result.setKind(instr.operands[i], k): changed = true
        template unify(a, b: IrValue) =
          let ak = result.kindOf(a)
          let bk = result.kindOf(b)
          if ak != rv32ValUnknown:
            if result.setKind(b, ak): changed = true
          if bk != rv32ValUnknown:
            if result.setKind(a, bk): changed = true

        case instr.op
        of irConst32:
          res(rv32ValI32)
        of irConst64:
          res(rv32ValI64)
        of irConstF64:
          res(rv32ValI64)

        of irAdd32, irSub32, irMul32, irDiv32S, irDiv32U,
           irRem32S, irRem32U, irAnd32, irOr32, irXor32,
           irShl32, irShr32S, irShr32U, irRotl32, irRotr32:
          op(0, rv32ValI32); op(1, rv32ValI32); res(rv32ValI32)
        of irClz32, irCtz32, irPopcnt32, irEqz32,
           irExtend8S32, irExtend16S32:
          op(0, rv32ValI32); res(rv32ValI32)
        of irEq32, irNe32, irLt32S, irLt32U, irGt32S, irGt32U,
           irLe32S, irLe32U, irGe32S, irGe32U:
          op(0, rv32ValI32); op(1, rv32ValI32); res(rv32ValI32)

        of irAdd64, irSub64, irMul64, irDiv64S, irDiv64U,
           irRem64S, irRem64U, irAnd64, irOr64, irXor64,
           irShl64, irShr64S, irShr64U, irRotl64, irRotr64:
          op(0, rv32ValI64); op(1, rv32ValI64); res(rv32ValI64)
        of irClz64, irCtz64, irPopcnt64, irEqz64:
          op(0, rv32ValI64); res(rv32ValI32)
        of irEq64, irNe64, irLt64S, irLt64U, irGt64S, irGt64U,
           irLe64S, irLe64U, irGe64S, irGe64U:
          op(0, rv32ValI64); op(1, rv32ValI64); res(rv32ValI32)

        of irWrapI64:
          op(0, rv32ValI64); res(rv32ValI32)
        of irExtendI32S, irExtendI32U:
          op(0, rv32ValI32); res(rv32ValI64)
        of irExtend8S64, irExtend16S64, irExtend32S64:
          op(0, rv32ValI64); res(rv32ValI64)

        of irAddF32, irSubF32, irMulF32, irDivF32,
           irAbsF32, irNegF32, irSqrtF32, irMinF32, irMaxF32,
           irCopysignF32, irCeilF32, irFloorF32, irTruncF32,
           irNearestF32, irEqF32, irNeF32, irLtF32, irGtF32,
           irLeF32, irGeF32, irF32ConvertI32S, irF32ConvertI32U,
           irI32TruncF32S, irI32TruncF32U, irI32ReinterpretF32,
           irF32ReinterpretI32:
          for operand in instr.operands:
            if operand >= 0 and result.setKind(operand, rv32ValI32):
              changed = true
          res(rv32ValI32)
        of irFmaF32, irFmsF32, irFnmaF32, irFnmsF32:
          op(0, rv32ValI32); op(1, rv32ValI32); op(2, rv32ValI32)
          res(rv32ValI32)
        of irF32ConvertI64S, irF32ConvertI64U:
          op(0, rv32ValI64); res(rv32ValI32)
        of irI64TruncF32S, irI64TruncF32U:
          op(0, rv32ValI32); res(rv32ValI64)

        of irAddF64, irSubF64, irMulF64, irDivF64,
           irMinF64, irMaxF64, irCopysignF64:
          op(0, rv32ValI64); op(1, rv32ValI64); res(rv32ValI64)
        of irFmaF64, irFmsF64, irFnmaF64, irFnmsF64:
          op(0, rv32ValI64); op(1, rv32ValI64); op(2, rv32ValI64)
          res(rv32ValI64)
        of irAbsF64, irNegF64, irSqrtF64,
           irCeilF64, irFloorF64, irTruncF64, irNearestF64:
          op(0, rv32ValI64); res(rv32ValI64)
        of irEqF64, irNeF64, irLtF64, irGtF64, irLeF64, irGeF64:
          op(0, rv32ValI64); op(1, rv32ValI64); res(rv32ValI32)
        of irF64ConvertI32S, irF64ConvertI32U:
          op(0, rv32ValI32); res(rv32ValI64)
        of irF64ConvertI64S, irF64ConvertI64U:
          op(0, rv32ValI64); res(rv32ValI64)
        of irI32TruncF64S, irI32TruncF64U, irF32DemoteF64:
          op(0, rv32ValI64); res(rv32ValI32)
        of irI64TruncF64S, irI64TruncF64U:
          op(0, rv32ValI64); res(rv32ValI64)
        of irF64PromoteF32:
          op(0, rv32ValI32); res(rv32ValI64)
        of irI64ReinterpretF64, irF64ReinterpretI64:
          op(0, rv32ValI64); res(rv32ValI64)

        of irLoad32:
          op(0, rv32ValI32); res(rv32ValI32)
        of irLoad64, irLoad32U, irLoad32S, irLoadF64:
          op(0, rv32ValI32); res(rv32ValI64)
        of irLoad8U, irLoad8S, irLoad16U, irLoad16S:
          op(0, rv32ValI32)

        of irStore32:
          op(0, rv32ValI32); op(1, rv32ValI32)
        of irStore64, irStore32From64, irStoreF64:
          op(0, rv32ValI32); op(1, rv32ValI64)
        of irStore8, irStore16:
          op(0, rv32ValI32)

        of irParam, irLocalGet:
          let idx = instr.imm.int
          if idx >= 0 and idx < locals.len:
            res(locals[idx])
            let rk = result.kindOf(instr.result)
            if locals.setLocalKind(idx, rk): changed = true
        of irLocalSet:
          let idx = instr.imm.int
          if idx >= 0 and idx < locals.len:
            let vk = result.kindOf(instr.operands[0])
            if locals.setLocalKind(idx, vk): changed = true
            op(0, locals[idx])

        of irPhi:
          unify(instr.result, instr.operands[0])
          unify(instr.result, instr.operands[1])
        of irSelect:
          op(0, rv32ValI32)
          unify(instr.result, instr.operands[1])
          unify(instr.result, instr.operands[2])
          unify(instr.operands[1], instr.operands[2])
        of irBrIf:
          op(0, rv32ValI32)
        of irReturn:
          op(0, retKind)
        of irI8x16Splat, irI16x8Splat, irI32x4Splat, irF32x4Splat:
          op(0, rv32ValI32)
        of irI64x2Splat, irF64x2Splat:
          op(0, rv32ValI64)
        of irI8x16ExtractLaneS, irI8x16ExtractLaneU,
           irI16x8ExtractLaneS, irI16x8ExtractLaneU,
           irI32x4ExtractLane, irF32x4ExtractLane:
          res(rv32ValI32)
        of irI64x2ExtractLane, irF64x2ExtractLane:
          res(rv32ValI64)
        of irI8x16ReplaceLane, irI16x8ReplaceLane,
           irI32x4ReplaceLane, irF32x4ReplaceLane:
          op(1, rv32ValI32)
        of irI64x2ReplaceLane, irF64x2ReplaceLane:
          op(1, rv32ValI64)
        of irI32x4Shl, irI32x4ShrS, irI32x4ShrU:
          op(1, rv32ValI32)
        of irNop:
          unify(instr.result, instr.operands[0])
        else:
          discard

  for i in 0 ..< result.len:
    if result[i] == rv32ValUnknown:
      result[i] = rv32ValI32

proc fitsSimm12(v: int32): bool {.inline.} =
  v >= -2048 and v <= 2047

proc isSpilledRv32(alloc: RegAllocResult, v: IrValue): bool {.inline.} =
  v >= 0 and alloc.assignment[v.int].int8 < 0

proc physRegRv32(alloc: RegAllocResult, v: IrValue): RvReg {.inline.} =
  discard alloc
  discard v
  rTmp0

proc spillOffsetRv32(alloc: RegAllocResult, v: IrValue): int32 {.inline.} =
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
    buf.loadImm32Native(scratch, imm)
    buf.add(dst, base, scratch)

proc emitLoadStack(buf: var Rv64AsmBuffer, dst: RvReg, offset: int32) =
  if fitsSimm12(offset):
    buf.lw(dst, sp, offset)
  else:
    buf.emitAddImm(rTmp1, sp, offset)
    buf.lw(dst, rTmp1, 0)

proc emitStoreStack(buf: var Rv64AsmBuffer, src: RvReg, offset: int32) =
  if fitsSimm12(offset):
    buf.sw(src, sp, offset)
  else:
    let scratch = if src == rTmp1: rTmp0 else: rTmp1
    buf.emitAddImm(scratch, sp, offset, if scratch == rTmp1: rTmp0 else: rTmp1)
    buf.sw(src, scratch, 0)

proc emitStoreSlot64Low(buf: var Rv64AsmBuffer, src, base: RvReg, offset: int32) =
  if fitsSimm12(offset) and fitsSimm12(offset + 4):
    buf.sw(src, base, offset)
    buf.sw(zero, base, offset + 4)
  else:
    let scratch = if src == rTmp1: rTmp0 else: rTmp1
    buf.emitAddImm(scratch, base, offset, if scratch == rTmp1: rTmp0 else: rTmp1)
    buf.sw(src, scratch, 0)
    buf.sw(zero, scratch, 4)

proc emitStoreSlot64(buf: var Rv64AsmBuffer, lo, hi, base: RvReg, offset: int32) =
  if fitsSimm12(offset) and fitsSimm12(offset + 4):
    buf.sw(lo, base, offset)
    buf.sw(hi, base, offset + 4)
  else:
    let scratch = if lo == rTmp1 or hi == rTmp1: rTmp0 else: rTmp1
    buf.emitAddImm(scratch, base, offset, if scratch == rTmp1: rTmp0 else: rTmp1)
    buf.sw(lo, scratch, 0)
    buf.sw(hi, scratch, 4)

proc localByteOffsetRv32(f: IrFunc, idx: int): int32 {.inline.} =
  let slot =
    if idx >= 0 and idx < f.localSlotOffsets.len:
      f.localSlotOffsets[idx]
    else:
      idx.int32
  slot * 8'i32

proc isSimdValueRv32(f: IrFunc, v: IrValue): bool {.inline.} =
  v >= 0 and v.int < f.isSimd.len and f.isSimd[v.int]

proc emitLoadLocalWordRv32(buf: var Rv64AsmBuffer, dst: RvReg, offset: int32) =
  if fitsSimm12(offset):
    buf.lw(dst, rLocals, offset)
  else:
    buf.emitAddImm(rTmp2, rLocals, offset, rTmp3)
    buf.lw(dst, rTmp2, 0)

proc emitStoreLocalWordRv32(buf: var Rv64AsmBuffer, src: RvReg, offset: int32) =
  if fitsSimm12(offset):
    buf.sw(src, rLocals, offset)
  else:
    let scratch = if src == rTmp2: rTmp1 else: rTmp2
    buf.emitAddImm(scratch, rLocals, offset, if scratch == rTmp1: rTmp2 else: rTmp1)
    buf.sw(src, scratch, 0)

proc hiSlotOffset(hiBase: int32, v: IrValue): int32 {.inline.} =
  hiBase + v.int32 * 4

proc emitLoadHiRv32(buf: var Rv64AsmBuffer, dst: RvReg,
                    alloc: RegAllocResult, v: IrValue, hiBase: int32): RvReg =
  if v < 0:
    return zero
  if v.int < alloc.rematKind.len and alloc.rematKind[v.int] == rematConst:
    let hi = ((cast[uint64](alloc.rematImm[v.int]) shr 32) and 0xFFFF_FFFF'u64).uint32
    buf.loadImm32Native(dst, cast[int32](hi))
    return dst
  buf.emitLoadStack(dst, hiSlotOffset(hiBase, v))
  dst

proc emitStoreHiRv32(buf: var Rv64AsmBuffer, v: IrValue, src: RvReg, hiBase: int32) =
  if v < 0: return
  buf.emitStoreStack(src, hiSlotOffset(hiBase, v))

proc emitSpillLoadRv32(buf: var Rv64AsmBuffer, dst: RvReg,
                       alloc: RegAllocResult, v: IrValue, spillBase: int32) =
  buf.emitLoadStack(dst, spillBase + spillOffsetRv32(alloc, v))

proc emitSpillStoreRv32(buf: var Rv64AsmBuffer, src: RvReg,
                        alloc: RegAllocResult, v: IrValue, spillBase: int32) =
  buf.emitStoreStack(src, spillBase + spillOffsetRv32(alloc, v))

proc loadOperandRv32(buf: var Rv64AsmBuffer, alloc: RegAllocResult, v: IrValue,
                     spillBase: int32, scratch: RvReg = rTmp0): RvReg =
  if v < 0: return zero
  if alloc.isSpilledRv32(v):
    if v.int < alloc.rematKind.len and alloc.rematKind[v.int] == rematConst:
      buf.loadImm32Native(scratch, alloc.rematImm[v.int].int32)
      return scratch
    buf.emitSpillLoadRv32(scratch, alloc, v, spillBase)
    return scratch
  alloc.physRegRv32(v)

proc storeResultRv32(buf: var Rv64AsmBuffer, alloc: RegAllocResult, v: IrValue,
                     src: RvReg, spillBase: int32) =
  if v < 0: return
  if alloc.isSpilledRv32(v):
    if v.int < alloc.rematKind.len and alloc.rematKind[v.int] == rematConst:
      return
    buf.emitSpillStoreRv32(src, alloc, v, spillBase)
  else:
    let dst = alloc.physRegRv32(v)
    if dst != src:
      buf.mv(dst, src)

proc storeResult64Rv32(buf: var Rv64AsmBuffer, alloc: RegAllocResult, v: IrValue,
                       lo, hi: RvReg, spillBase, hiBase: int32) =
  if v < 0: return
  buf.storeResultRv32(alloc, v, lo, spillBase)
  if v.int < alloc.rematKind.len and alloc.rematKind[v.int] == rematConst:
    return
  buf.emitStoreHiRv32(v, hi, hiBase)

proc emitCopyStack128Rv32(buf: var Rv64AsmBuffer, dstOff, srcOff: int32) =
  if dstOff == srcOff: return
  for word in 0 .. 3:
    let off = word.int32 * 4
    buf.emitLoadStack(rTmp0, srcOff + off)
    buf.emitStoreStack(rTmp0, dstOff + off)

proc emitCopyStack128ToTempRv32(buf: var Rv64AsmBuffer, srcOff: int32) =
  buf.emitCopyStack128Rv32(rv32DirectArgBase, srcOff)

proc emitCopyTempToStack128Rv32(buf: var Rv64AsmBuffer, dstOff: int32) =
  buf.emitCopyStack128Rv32(dstOff, rv32DirectArgBase)

proc ensureLabel(labels: var seq[Rv32BlockLabel], idx: int) =
  if idx < labels.len: return
  let oldLen = labels.len
  labels.setLen(idx + 1)
  for i in oldLen ..< labels.len:
    labels[i].offset = -1

proc isI64(valueKinds: openArray[Rv32ValueKind], v: IrValue): bool {.inline.} =
  v >= 0 and v.int < valueKinds.len and valueKinds[v.int] == rv32ValI64

proc emitPhiResolutionRv32(buf: var Rv64AsmBuffer, f: IrFunc, alloc: RegAllocResult,
                           targetBb: int, sourceBb: int, spillBase, hiBase: int32,
                           valueKinds: openArray[Rv32ValueKind]) =
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

    if f.isSimdValueRv32(phi.result):
      simdMoves.add(SimdMove(
        dstOff: spillBase + spillOffsetRv32(alloc, phi.result),
        srcOff: spillBase + spillOffsetRv32(alloc, srcVal)))
      continue

    if valueKinds.isI64(phi.result):
      discard buf.emitLoadHiRv32(rTmp2, alloc, srcVal, hiBase)
      buf.emitStoreHiRv32(phi.result, rTmp2, hiBase)

    if alloc.isSpilledRv32(srcVal):
      let loaded = buf.loadOperandRv32(alloc, srcVal, spillBase, rTmp0)
      if alloc.isSpilledRv32(phi.result):
        buf.storeResultRv32(alloc, phi.result, loaded, spillBase)
      else:
        let dst = alloc.physRegRv32(phi.result)
        if dst != loaded: buf.mv(dst, loaded)
      continue

    let dstReg = alloc.physRegRv32(phi.result)
    let srcReg = alloc.physRegRv32(srcVal)
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
        buf.emitCopyStack128Rv32(simdMoves[i].dstOff, simdMoves[i].srcOff)
        simdDone[i] = true
        simdChanged = true

  for i in 0 ..< simdMoves.len:
    if simdDone[i]: continue
    buf.emitCopyStack128ToTempRv32(simdMoves[i].srcOff)
    var curSrc = simdMoves[i].srcOff
    while not simdDone[i]:
      var next = -1
      for j in 0 ..< simdMoves.len:
        if not simdDone[j] and simdMoves[j].dstOff == curSrc:
          next = j
          break
      if next < 0:
        buf.emitCopyTempToStack128Rv32(simdMoves[i].dstOff)
        simdDone[i] = true
      elif next == i:
        buf.emitCopyTempToStack128Rv32(simdMoves[i].dstOff)
        simdDone[i] = true
      else:
        buf.emitCopyStack128Rv32(simdMoves[next].dstOff, simdMoves[next].srcOff)
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
        if alloc.isSpilledRv32(moves[i].dstVal):
          buf.storeResultRv32(alloc, moves[i].dstVal, moves[i].dst, spillBase)
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
      if alloc.isSpilledRv32(moves[cur].dstVal):
        buf.storeResultRv32(alloc, moves[cur].dstVal, moves[cur].dst, spillBase)
      if nxt < 0: break
      cur = nxt
    buf.mv(moves[i].dst, rTmp1)
    if alloc.isSpilledRv32(moves[i].dstVal):
      buf.storeResultRv32(alloc, moves[i].dstVal, moves[i].dst, spillBase)

proc emitBoundsCheckRv32(buf: var Rv64AsmBuffer, addrReg: RvReg,
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

proc emitLoadMemRv32(buf: var Rv64AsmBuffer, op: IrOpKind, dst, addrReg: RvReg,
                     offset: int32) =
  buf.emitEffectiveAddr(rTmp1, addrReg)
  if not fitsSimm12(offset):
    buf.emitAddImm(rTmp1, rTmp1, offset)
  let off = if fitsSimm12(offset): offset else: 0
  case op
  of irLoad8U: buf.lbu(dst, rTmp1, off)
  of irLoad8S: buf.lb(dst, rTmp1, off)
  of irLoad16U: buf.lhu(dst, rTmp1, off)
  of irLoad16S: buf.lh(dst, rTmp1, off)
  of irLoad32: buf.lw(dst, rTmp1, off)
  else: unsupportedRv32(op)

proc emitStoreMemRv32(buf: var Rv64AsmBuffer, op: IrOpKind, src, addrReg: RvReg,
                      offset: int32) =
  buf.emitEffectiveAddr(rTmp1, addrReg)
  if not fitsSimm12(offset):
    buf.emitAddImm(rTmp1, rTmp1, offset)
  let off = if fitsSimm12(offset): offset else: 0
  case op
  of irStore8: buf.sb(src, rTmp1, off)
  of irStore16: buf.sh(src, rTmp1, off)
  of irStore32: buf.sw(src, rTmp1, off)
  else: unsupportedRv32(op)

proc emitBin32(buf: var Rv64AsmBuffer, instr: IrInstr, alloc: RegAllocResult,
               resReg: RvReg, spillBase: int32, op: IrOpKind,
               target: RvTarget) =
  let a = buf.loadOperandRv32(alloc, instr.operands[0], spillBase, rTmp0)
  var b = buf.loadOperandRv32(alloc, instr.operands[1], spillBase, rTmp1)
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
  of irAdd32: buf.add(resReg, resReg, b)
  of irSub32: buf.sub(resReg, resReg, b)
  of irMul32: buf.mul(resReg, resReg, b)
  of irAnd32: buf.andr(resReg, resReg, b)
  of irOr32:  buf.orr(resReg, resReg, b)
  of irXor32: buf.xorr(resReg, resReg, b)
  of irShl32: buf.sll(resReg, resReg, b)
  of irShr32U: buf.srl(resReg, resReg, b)
  of irShr32S: buf.sra(resReg, resReg, b)
  of irRotl32:
    if rvExtZbb in target.features:
      buf.rol(resReg, resReg, b)
    else:
      buf.sub(rTmp1, zero, b)
      buf.sll(resReg, resReg, b)
      buf.srl(rTmp1, origA, rTmp1)
      buf.orr(resReg, resReg, rTmp1)
  of irRotr32:
    if rvExtZbb in target.features:
      buf.ror(resReg, resReg, b)
    else:
      buf.sub(rTmp1, zero, b)
      buf.srl(resReg, resReg, b)
      buf.sll(rTmp1, origA, rTmp1)
      buf.orr(resReg, resReg, rTmp1)
  else: unsupportedRv32(op)

proc emitCmp32(buf: var Rv64AsmBuffer, instr: IrInstr, alloc: RegAllocResult,
               resReg: RvReg, spillBase: int32) =
  let a = buf.loadOperandRv32(alloc, instr.operands[0], spillBase, rTmp0)
  let b = buf.loadOperandRv32(alloc, instr.operands[1], spillBase, rTmp1)
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
  else: unsupportedRv32(instr.op)

proc loadPairInto(buf: var Rv64AsmBuffer, alloc: RegAllocResult, v: IrValue,
                  spillBase, hiBase: int32, loDst, hiDst: RvReg) =
  let lo = buf.loadOperandRv32(alloc, v, spillBase, loDst)
  if lo != loDst: buf.mv(loDst, lo)
  discard buf.emitLoadHiRv32(hiDst, alloc, v, hiBase)

proc patchJalTo(buf: var Rv64AsmBuffer, patchPos, targetPos: int) =
  buf.patchJalAt(patchPos, (targetPos - patchPos).int32)

proc patchBranchTo(buf: var Rv64AsmBuffer, patchPos, targetPos: int) =
  buf.patchBranchAt(patchPos, (targetPos - patchPos).int32)

proc emitClz32FallbackRv32(buf: var Rv64AsmBuffer, dst, src, x, mask,
                           tmp: RvReg) =
  if src != x: buf.mv(x, src)
  let zeroPatch = buf.pos
  buf.beq(x, zero, 0)
  buf.addi(dst, zero, 0)
  buf.loadImm32Native(mask, cast[int32](0x8000_0000'u32))

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
  buf.addi(dst, zero, 32)
  let donePos = buf.pos
  buf.patchBranchTo(donePatch, donePos)

proc emitCtz32FallbackRv32(buf: var Rv64AsmBuffer, dst, src, x, mask,
                           tmp: RvReg) =
  if src != x: buf.mv(x, src)
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
  buf.addi(dst, zero, 32)
  let donePos = buf.pos
  buf.patchBranchTo(donePatch, donePos)

proc emitPopcnt32FallbackRv32(buf: var Rv64AsmBuffer, dst, src, x,
                              tmp: RvReg) =
  if src != x: buf.mv(x, src)
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

proc requireF32Rv32(target: RvTarget, op: IrOpKind) {.gcsafe.}
proc requireF64Rv32(target: RvTarget, op: IrOpKind) {.gcsafe.}

proc helperAddr32(fn: pointer): int32 =
  cast[int32](cast[uint](fn).uint32)

proc emitCallI64HelperRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                           alloc: RegAllocResult, spillBase, hiBase: int32,
                           helper: pointer) =
  buf.emitStoreStack(rMemBase, tmpSlot0)
  buf.emitStoreStack(rMemSize, tmpSlot1)
  buf.loadPairInto(alloc, instr.operands[0], spillBase, hiBase, a0, a1)
  buf.loadPairInto(alloc, instr.operands[1], spillBase, hiBase, a2, a3)
  buf.loadImm32Native(rTmp4, helperAddr32(helper))
  buf.jalr(ra, rTmp4, 0)
  buf.emitLoadStack(rMemBase, tmpSlot0)
  buf.emitLoadStack(rMemSize, tmpSlot1)
  buf.storeResult64Rv32(alloc, instr.result, a0, a1, spillBase, hiBase)

proc emitCallF32UnaryHelperRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                                alloc: RegAllocResult, resReg: RvReg,
                                spillBase: int32, helper: pointer,
                                target: RvTarget) =
  target.requireF32Rv32(instr.op)
  buf.emitStoreStack(rMemBase, tmpSlot0)
  buf.emitStoreStack(rMemSize, tmpSlot1)
  let a = buf.loadOperandRv32(alloc, instr.operands[0], spillBase, a0)
  if a != a0: buf.mv(a0, a)
  buf.loadImm32Native(rTmp4, helperAddr32(helper))
  buf.jalr(ra, rTmp4, 0)
  buf.emitLoadStack(rMemBase, tmpSlot0)
  buf.emitLoadStack(rMemSize, tmpSlot1)
  if resReg != a0: buf.mv(resReg, a0)

proc emitCallI64ToF32HelperRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                                alloc: RegAllocResult, resReg: RvReg,
                                spillBase, hiBase: int32, helper: pointer,
                                target: RvTarget) =
  target.requireF32Rv32(instr.op)
  buf.emitStoreStack(rMemBase, tmpSlot0)
  buf.emitStoreStack(rMemSize, tmpSlot1)
  buf.loadPairInto(alloc, instr.operands[0], spillBase, hiBase, a0, a1)
  buf.loadImm32Native(rTmp4, helperAddr32(helper))
  buf.jalr(ra, rTmp4, 0)
  buf.emitLoadStack(rMemBase, tmpSlot0)
  buf.emitLoadStack(rMemSize, tmpSlot1)
  if resReg != a0: buf.mv(resReg, a0)

proc emitCallF32ToI64HelperRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                                alloc: RegAllocResult, spillBase,
                                hiBase: int32, helper: pointer,
                                target: RvTarget) =
  target.requireF32Rv32(instr.op)
  buf.emitStoreStack(rMemBase, tmpSlot0)
  buf.emitStoreStack(rMemSize, tmpSlot1)
  let a = buf.loadOperandRv32(alloc, instr.operands[0], spillBase, a0)
  if a != a0: buf.mv(a0, a)
  buf.loadImm32Native(rTmp4, helperAddr32(helper))
  buf.jalr(ra, rTmp4, 0)
  buf.emitLoadStack(rMemBase, tmpSlot0)
  buf.emitLoadStack(rMemSize, tmpSlot1)
  buf.storeResult64Rv32(alloc, instr.result, a0, a1, spillBase, hiBase)

proc emitSaveRuntimeCallRv32(buf: var Rv64AsmBuffer) =
  buf.emitStoreStack(rMemBase, tmpSlot0)
  buf.emitStoreStack(rMemSize, tmpSlot1)

proc emitRestoreRuntimeCallRv32(buf: var Rv64AsmBuffer) =
  buf.emitLoadStack(rMemBase, tmpSlot0)
  buf.emitLoadStack(rMemSize, tmpSlot1)

proc emitCallF64UnaryHelperRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                                alloc: RegAllocResult, spillBase,
                                hiBase: int32, helper: pointer,
                                target: RvTarget) =
  target.requireF64Rv32(instr.op)
  buf.emitSaveRuntimeCallRv32()
  buf.loadPairInto(alloc, instr.operands[0], spillBase, hiBase, a0, a1)
  buf.loadImm32Native(rTmp0, helperAddr32(helper))
  buf.jalr(ra, rTmp0, 0)
  buf.emitRestoreRuntimeCallRv32()
  buf.storeResult64Rv32(alloc, instr.result, a0, a1, spillBase, hiBase)

proc emitCallF64BinaryHelperRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                                 alloc: RegAllocResult, spillBase,
                                 hiBase: int32, helper: pointer,
                                 target: RvTarget) =
  target.requireF64Rv32(instr.op)
  buf.emitSaveRuntimeCallRv32()
  buf.loadPairInto(alloc, instr.operands[0], spillBase, hiBase, a0, a1)
  buf.loadPairInto(alloc, instr.operands[1], spillBase, hiBase, a2, a3)
  buf.loadImm32Native(rTmp0, helperAddr32(helper))
  buf.jalr(ra, rTmp0, 0)
  buf.emitRestoreRuntimeCallRv32()
  buf.storeResult64Rv32(alloc, instr.result, a0, a1, spillBase, hiBase)

proc emitCallF64TernaryHelperRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                                  alloc: RegAllocResult, spillBase,
                                  hiBase: int32, helper: pointer,
                                  target: RvTarget) =
  target.requireF64Rv32(instr.op)
  buf.emitSaveRuntimeCallRv32()
  buf.loadPairInto(alloc, instr.operands[0], spillBase, hiBase, a0, a1)
  buf.loadPairInto(alloc, instr.operands[1], spillBase, hiBase, a2, a3)
  buf.loadPairInto(alloc, instr.operands[2], spillBase, hiBase, a4, a5)
  buf.loadImm32Native(rTmp0, helperAddr32(helper))
  buf.jalr(ra, rTmp0, 0)
  buf.emitRestoreRuntimeCallRv32()
  buf.storeResult64Rv32(alloc, instr.result, a0, a1, spillBase, hiBase)

proc emitCallF64CmpHelperRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                              alloc: RegAllocResult, resReg: RvReg,
                              spillBase, hiBase: int32, helper: pointer,
                              target: RvTarget) =
  target.requireF64Rv32(instr.op)
  buf.emitSaveRuntimeCallRv32()
  buf.loadPairInto(alloc, instr.operands[0], spillBase, hiBase, a0, a1)
  buf.loadPairInto(alloc, instr.operands[1], spillBase, hiBase, a2, a3)
  buf.loadImm32Native(rTmp0, helperAddr32(helper))
  buf.jalr(ra, rTmp0, 0)
  buf.emitRestoreRuntimeCallRv32()
  if resReg != a0: buf.mv(resReg, a0)

proc emitCallI32ToF64HelperRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                                alloc: RegAllocResult, spillBase,
                                hiBase: int32, helper: pointer,
                                target: RvTarget) =
  target.requireF64Rv32(instr.op)
  buf.emitSaveRuntimeCallRv32()
  let a = buf.loadOperandRv32(alloc, instr.operands[0], spillBase, a0)
  if a != a0: buf.mv(a0, a)
  buf.loadImm32Native(rTmp0, helperAddr32(helper))
  buf.jalr(ra, rTmp0, 0)
  buf.emitRestoreRuntimeCallRv32()
  buf.storeResult64Rv32(alloc, instr.result, a0, a1, spillBase, hiBase)

proc emitCallI64ToF64HelperRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                                alloc: RegAllocResult, spillBase,
                                hiBase: int32, helper: pointer,
                                target: RvTarget) =
  target.requireF64Rv32(instr.op)
  buf.emitSaveRuntimeCallRv32()
  buf.loadPairInto(alloc, instr.operands[0], spillBase, hiBase, a0, a1)
  buf.loadImm32Native(rTmp0, helperAddr32(helper))
  buf.jalr(ra, rTmp0, 0)
  buf.emitRestoreRuntimeCallRv32()
  buf.storeResult64Rv32(alloc, instr.result, a0, a1, spillBase, hiBase)

proc emitCallF64ToI32HelperRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                                alloc: RegAllocResult, resReg: RvReg,
                                spillBase, hiBase: int32, helper: pointer,
                                target: RvTarget) =
  target.requireF64Rv32(instr.op)
  buf.emitSaveRuntimeCallRv32()
  buf.loadPairInto(alloc, instr.operands[0], spillBase, hiBase, a0, a1)
  buf.loadImm32Native(rTmp0, helperAddr32(helper))
  buf.jalr(ra, rTmp0, 0)
  buf.emitRestoreRuntimeCallRv32()
  if resReg != a0: buf.mv(resReg, a0)

proc emitCallF64ToI64HelperRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                                alloc: RegAllocResult, spillBase,
                                hiBase: int32, helper: pointer,
                                target: RvTarget) =
  target.requireF64Rv32(instr.op)
  buf.emitSaveRuntimeCallRv32()
  buf.loadPairInto(alloc, instr.operands[0], spillBase, hiBase, a0, a1)
  buf.loadImm32Native(rTmp0, helperAddr32(helper))
  buf.jalr(ra, rTmp0, 0)
  buf.emitRestoreRuntimeCallRv32()
  buf.storeResult64Rv32(alloc, instr.result, a0, a1, spillBase, hiBase)

proc emitCallF64ToF32HelperRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                                alloc: RegAllocResult, resReg: RvReg,
                                spillBase, hiBase: int32, helper: pointer,
                                target: RvTarget) =
  target.requireF32Rv32(instr.op)
  target.requireF64Rv32(instr.op)
  buf.emitSaveRuntimeCallRv32()
  buf.loadPairInto(alloc, instr.operands[0], spillBase, hiBase, a0, a1)
  buf.loadImm32Native(rTmp0, helperAddr32(helper))
  buf.jalr(ra, rTmp0, 0)
  buf.emitRestoreRuntimeCallRv32()
  if resReg != a0: buf.mv(resReg, a0)

proc emitCallF32ToF64HelperRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                                alloc: RegAllocResult, spillBase,
                                hiBase: int32, helper: pointer,
                                target: RvTarget) =
  target.requireF32Rv32(instr.op)
  target.requireF64Rv32(instr.op)
  buf.emitSaveRuntimeCallRv32()
  let a = buf.loadOperandRv32(alloc, instr.operands[0], spillBase, a0)
  if a != a0: buf.mv(a0, a)
  buf.loadImm32Native(rTmp0, helperAddr32(helper))
  buf.jalr(ra, rTmp0, 0)
  buf.emitRestoreRuntimeCallRv32()
  buf.storeResult64Rv32(alloc, instr.result, a0, a1, spillBase, hiBase)

proc emitShiftLeft64(buf: var Rv64AsmBuffer, loDst, hiDst, aLo, aHi, shReg: RvReg) =
  buf.andi(rTmp4, shReg, 63)
  buf.andi(rTmp5, rTmp4, 32)
  let highPatch = buf.pos
  buf.bne(rTmp5, zero, 0)

  let zeroPatch = buf.pos
  buf.beq(rTmp4, zero, 0)
  buf.sub(rTmp5, zero, rTmp4)
  buf.srl(rTmp5, aLo, rTmp5)
  buf.sll(hiDst, aHi, rTmp4)
  buf.orr(hiDst, hiDst, rTmp5)
  buf.sll(loDst, aLo, rTmp4)
  let lowEndPatch = buf.pos
  buf.j(0)

  let zeroPos = buf.pos
  buf.patchBranchTo(zeroPatch, zeroPos)
  buf.mv(loDst, aLo)
  buf.mv(hiDst, aHi)
  let zeroEndPatch = buf.pos
  buf.j(0)

  let highPos = buf.pos
  buf.patchBranchTo(highPatch, highPos)
  buf.andi(rTmp4, rTmp4, 31)
  buf.sll(hiDst, aLo, rTmp4)
  buf.mv(loDst, zero)

  let endPos = buf.pos
  buf.patchJalTo(lowEndPatch, endPos)
  buf.patchJalTo(zeroEndPatch, endPos)

proc emitShiftRight64(buf: var Rv64AsmBuffer, loDst, hiDst, aLo, aHi, shReg: RvReg,
                      signedShift: bool) =
  buf.andi(rTmp4, shReg, 63)
  buf.andi(rTmp5, rTmp4, 32)
  let highPatch = buf.pos
  buf.bne(rTmp5, zero, 0)

  let zeroPatch = buf.pos
  buf.beq(rTmp4, zero, 0)
  buf.sub(rTmp5, zero, rTmp4)
  buf.sll(rTmp5, aHi, rTmp5)
  if signedShift:
    buf.sra(hiDst, aHi, rTmp4)
  else:
    buf.srl(hiDst, aHi, rTmp4)
  buf.srl(loDst, aLo, rTmp4)
  buf.orr(loDst, loDst, rTmp5)
  let lowEndPatch = buf.pos
  buf.j(0)

  let zeroPos = buf.pos
  buf.patchBranchTo(zeroPatch, zeroPos)
  buf.mv(loDst, aLo)
  buf.mv(hiDst, aHi)
  let zeroEndPatch = buf.pos
  buf.j(0)

  let highPos = buf.pos
  buf.patchBranchTo(highPatch, highPos)
  buf.andi(rTmp4, rTmp4, 31)
  if signedShift:
    buf.sra(loDst, aHi, rTmp4)
    buf.srai(hiDst, aHi, 31)
  else:
    buf.srl(loDst, aHi, rTmp4)
    buf.mv(hiDst, zero)

  let endPos = buf.pos
  buf.patchJalTo(lowEndPatch, endPos)
  buf.patchJalTo(zeroEndPatch, endPos)

proc emitRot64Rv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                   alloc: RegAllocResult, spillBase, hiBase: int32,
                   rotateRight: bool) =
  buf.loadPairInto(alloc, instr.operands[0], spillBase, hiBase, rTmp0, rTmp1)
  let cnt = buf.loadOperandRv32(alloc, instr.operands[1], spillBase, rTmp2)
  if cnt != rTmp2: buf.mv(rTmp2, cnt)

  buf.emitStoreStack(rTmp0, tmpSlot0)
  buf.emitStoreStack(rTmp1, tmpSlot1)
  if rotateRight:
    buf.emitShiftRight64(rTmp0, rTmp1, rTmp0, rTmp1, rTmp2, false)
  else:
    buf.emitShiftLeft64(rTmp0, rTmp1, rTmp0, rTmp1, rTmp2)
  buf.emitStoreStack(rTmp0, tmpSlot2)
  buf.emitStoreStack(rTmp1, tmpSlot3)

  buf.emitLoadStack(rTmp0, tmpSlot0)
  buf.emitLoadStack(rTmp1, tmpSlot1)
  buf.sub(rTmp2, zero, rTmp2)
  if rotateRight:
    buf.emitShiftLeft64(rTmp0, rTmp1, rTmp0, rTmp1, rTmp2)
  else:
    buf.emitShiftRight64(rTmp0, rTmp1, rTmp0, rTmp1, rTmp2, false)
  buf.emitLoadStack(rTmp2, tmpSlot2)
  buf.emitLoadStack(rTmp3, tmpSlot3)
  buf.orr(rTmp0, rTmp0, rTmp2)
  buf.orr(rTmp1, rTmp1, rTmp3)
  buf.storeResult64Rv32(alloc, instr.result, rTmp0, rTmp1, spillBase, hiBase)

proc emitBin64(buf: var Rv64AsmBuffer, instr: IrInstr, alloc: RegAllocResult,
               spillBase, hiBase: int32, op: IrOpKind) =
  buf.loadPairInto(alloc, instr.operands[0], spillBase, hiBase, rTmp0, rTmp1)
  buf.loadPairInto(alloc, instr.operands[1], spillBase, hiBase, rTmp2, rTmp3)

  case op
  of irAdd64:
    buf.add(rTmp0, rTmp0, rTmp2)
    buf.sltu(rTmp4, rTmp0, rTmp2)
    buf.add(rTmp1, rTmp1, rTmp3)
    buf.add(rTmp1, rTmp1, rTmp4)
  of irSub64:
    buf.sltu(rTmp4, rTmp0, rTmp2)
    buf.sub(rTmp0, rTmp0, rTmp2)
    buf.sub(rTmp1, rTmp1, rTmp3)
    buf.sub(rTmp1, rTmp1, rTmp4)
  of irMul64:
    buf.mulhu(rTmp4, rTmp0, rTmp2)
    buf.mul(rTmp5, rTmp0, rTmp3)
    buf.add(rTmp4, rTmp4, rTmp5)
    buf.mul(rTmp5, rTmp1, rTmp2)
    buf.add(rTmp1, rTmp4, rTmp5)
    buf.mul(rTmp0, rTmp0, rTmp2)
  of irAnd64:
    buf.andr(rTmp0, rTmp0, rTmp2)
    buf.andr(rTmp1, rTmp1, rTmp3)
  of irOr64:
    buf.orr(rTmp0, rTmp0, rTmp2)
    buf.orr(rTmp1, rTmp1, rTmp3)
  of irXor64:
    buf.xorr(rTmp0, rTmp0, rTmp2)
    buf.xorr(rTmp1, rTmp1, rTmp3)
  of irShl64:
    buf.emitShiftLeft64(rTmp0, rTmp1, rTmp0, rTmp1, rTmp2)
  of irShr64U:
    buf.emitShiftRight64(rTmp0, rTmp1, rTmp0, rTmp1, rTmp2, false)
  of irShr64S:
    buf.emitShiftRight64(rTmp0, rTmp1, rTmp0, rTmp1, rTmp2, true)
  else:
    unsupportedRv32(op)

  buf.storeResult64Rv32(alloc, instr.result, rTmp0, rTmp1, spillBase, hiBase)

proc emitLt64(buf: var Rv64AsmBuffer, resReg, aLo, aHi, bLo, bHi: RvReg,
              signedCmp: bool) =
  if signedCmp:
    buf.slt(resReg, aHi, bHi)
    buf.slt(rTmp4, bHi, aHi)
  else:
    buf.sltu(resReg, aHi, bHi)
    buf.sltu(rTmp4, bHi, aHi)

  let greaterPatch = buf.pos
  buf.bne(rTmp4, zero, 0)
  let lessPatch = buf.pos
  buf.bne(resReg, zero, 0)
  buf.sltu(resReg, aLo, bLo)
  let endPatch = buf.pos
  buf.j(0)

  let greaterPos = buf.pos
  buf.patchBranchTo(greaterPatch, greaterPos)
  buf.mv(resReg, zero)
  let endPos = buf.pos
  buf.patchBranchTo(lessPatch, endPos)
  buf.patchJalTo(endPatch, endPos)

proc emitCmp64(buf: var Rv64AsmBuffer, instr: IrInstr, alloc: RegAllocResult,
               resReg: RvReg, spillBase, hiBase: int32) =
  buf.loadPairInto(alloc, instr.operands[0], spillBase, hiBase, rTmp0, rTmp1)
  buf.loadPairInto(alloc, instr.operands[1], spillBase, hiBase, rTmp2, rTmp3)

  case instr.op
  of irEq64:
    buf.xorr(resReg, rTmp0, rTmp2)
    buf.xorr(rTmp4, rTmp1, rTmp3)
    buf.orr(resReg, resReg, rTmp4)
    buf.seqz(resReg, resReg)
  of irNe64:
    buf.xorr(resReg, rTmp0, rTmp2)
    buf.xorr(rTmp4, rTmp1, rTmp3)
    buf.orr(resReg, resReg, rTmp4)
    buf.snez(resReg, resReg)
  of irLt64S:
    buf.emitLt64(resReg, rTmp0, rTmp1, rTmp2, rTmp3, true)
  of irLt64U:
    buf.emitLt64(resReg, rTmp0, rTmp1, rTmp2, rTmp3, false)
  of irGt64S:
    buf.emitLt64(resReg, rTmp2, rTmp3, rTmp0, rTmp1, true)
  of irGt64U:
    buf.emitLt64(resReg, rTmp2, rTmp3, rTmp0, rTmp1, false)
  of irLe64S:
    buf.emitLt64(resReg, rTmp2, rTmp3, rTmp0, rTmp1, true)
    buf.xori(resReg, resReg, 1)
  of irLe64U:
    buf.emitLt64(resReg, rTmp2, rTmp3, rTmp0, rTmp1, false)
    buf.xori(resReg, resReg, 1)
  of irGe64S:
    buf.emitLt64(resReg, rTmp0, rTmp1, rTmp2, rTmp3, true)
    buf.xori(resReg, resReg, 1)
  of irGe64U:
    buf.emitLt64(resReg, rTmp0, rTmp1, rTmp2, rTmp3, false)
    buf.xori(resReg, resReg, 1)
  else:
    unsupportedRv32(instr.op)

proc requireF32Rv32(target: RvTarget, op: IrOpKind) {.gcsafe.} =
  if rvExtF notin target.features:
    unsupportedRv32(op)

proc requireF64Rv32(target: RvTarget, op: IrOpKind) {.gcsafe.} =
  if rvExtD notin target.features:
    unsupportedRv32(op)

proc emitF32BinRv32(buf: var Rv64AsmBuffer, instr: IrInstr, alloc: RegAllocResult,
                    resReg: RvReg, spillBase: int32, target: RvTarget) =
  target.requireF32Rv32(instr.op)
  let a = buf.loadOperandRv32(alloc, instr.operands[0], spillBase, rTmp0)
  let b = buf.loadOperandRv32(alloc, instr.operands[1], spillBase, rTmp1)
  buf.fmvWX(RvReg(0), a)
  buf.fmvWX(RvReg(1), b)
  case instr.op
  of irAddF32: buf.faddS(RvReg(0), RvReg(0), RvReg(1))
  of irSubF32: buf.fsubS(RvReg(0), RvReg(0), RvReg(1))
  of irMulF32: buf.fmulS(RvReg(0), RvReg(0), RvReg(1))
  of irDivF32: buf.fdivS(RvReg(0), RvReg(0), RvReg(1))
  of irMinF32: buf.fminS(RvReg(0), RvReg(0), RvReg(1))
  of irMaxF32: buf.fmaxS(RvReg(0), RvReg(0), RvReg(1))
  else: unsupportedRv32(instr.op)
  buf.fmvXW(resReg, RvReg(0))

proc emitF32FmaRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                    alloc: RegAllocResult, resReg: RvReg,
                    spillBase: int32, target: RvTarget) =
  target.requireF32Rv32(instr.op)
  let a = buf.loadOperandRv32(alloc, instr.operands[0], spillBase, rTmp0)
  let b = buf.loadOperandRv32(alloc, instr.operands[1], spillBase, rTmp1)
  let c = buf.loadOperandRv32(alloc, instr.operands[2], spillBase, rTmp2)
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
    buf.loadImm32Native(rTmp1, cast[int32](0x8000_0000'u32))
    buf.xorr(resReg, resReg, rTmp1)
    return
  of irFnmsF32:
    buf.fmulS(RvReg(0), RvReg(0), RvReg(1))
    buf.fsubS(RvReg(0), RvReg(0), RvReg(2))
  else:
    unsupportedRv32(instr.op)
  buf.fmvXW(resReg, RvReg(0))

proc emitF32CmpRv32(buf: var Rv64AsmBuffer, instr: IrInstr, alloc: RegAllocResult,
                    resReg: RvReg, spillBase: int32, target: RvTarget) =
  target.requireF32Rv32(instr.op)
  let a = buf.loadOperandRv32(alloc, instr.operands[0], spillBase, rTmp0)
  let b = buf.loadOperandRv32(alloc, instr.operands[1], spillBase, rTmp1)
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
  else: unsupportedRv32(instr.op)

proc simdStackOffsetRv32(alloc: RegAllocResult, v: IrValue,
                         spillBase: int32): int32 {.inline.} =
  spillBase + spillOffsetRv32(alloc, v)

proc emitLoadSimdFromLocalsRv32(buf: var Rv64AsmBuffer, alloc: RegAllocResult,
                                dst: IrValue, spillBase, localOff: int32) =
  let dstOff = simdStackOffsetRv32(alloc, dst, spillBase)
  for word in 0 .. 3:
    let off = word.int32 * 4
    buf.emitLoadLocalWordRv32(rTmp0, localOff + off)
    buf.emitStoreStack(rTmp0, dstOff + off)

proc emitStoreSimdToLocalsRv32(buf: var Rv64AsmBuffer, alloc: RegAllocResult,
                               src: IrValue, spillBase, localOff: int32) =
  let srcOff = simdStackOffsetRv32(alloc, src, spillBase)
  for word in 0 .. 3:
    let off = word.int32 * 4
    buf.emitLoadStack(rTmp0, srcOff + off)
    buf.emitStoreLocalWordRv32(rTmp0, localOff + off)

proc emitLoadStackScalarRv32(buf: var Rv64AsmBuffer, dst: RvReg,
                             offset: int32, laneBytes: int32,
                             signed = false) =
  let base =
    if fitsSimm12(offset):
      sp
    else:
      let scratch = if dst == rTmp1: rTmp2 else: rTmp1
      buf.emitAddImm(scratch, sp, offset, rTmp3)
      scratch
  let off = if fitsSimm12(offset): offset else: 0'i32
  case laneBytes
  of 1:
    if signed: buf.lb(dst, base, off) else: buf.lbu(dst, base, off)
  of 2:
    if signed: buf.lh(dst, base, off) else: buf.lhu(dst, base, off)
  of 4:
    buf.lw(dst, base, off)
  else:
    unsupportedRv32(irLoadV128)

proc emitStoreStackScalarRv32(buf: var Rv64AsmBuffer, src: RvReg,
                              offset: int32, laneBytes: int32) =
  let base =
    if fitsSimm12(offset):
      sp
    else:
      let scratch = if src == rTmp1: rTmp2 else: rTmp1
      buf.emitAddImm(scratch, sp, offset, rTmp3)
      scratch
  let off = if fitsSimm12(offset): offset else: 0'i32
  case laneBytes
  of 1: buf.sb(src, base, off)
  of 2: buf.sh(src, base, off)
  of 4: buf.sw(src, base, off)
  else: unsupportedRv32(irStoreV128)

proc emitCopySimdRv32(buf: var Rv64AsmBuffer, alloc: RegAllocResult,
                      dst, src: IrValue, spillBase: int32) =
  if dst < 0 or src < 0: return
  let srcOff = simdStackOffsetRv32(alloc, src, spillBase)
  let dstOff = simdStackOffsetRv32(alloc, dst, spillBase)
  for word in 0 .. 3:
    let off = word.int32 * 4
    buf.emitLoadStack(rTmp0, srcOff + off)
    buf.emitStoreStack(rTmp0, dstOff + off)

proc emitSimdConstRv32(buf: var Rv64AsmBuffer, f: IrFunc, alloc: RegAllocResult,
                       res: IrValue, spillBase: int32, idx: int) =
  var bytes: array[16, byte]
  if idx >= 0 and idx < f.v128Consts.len:
    bytes = f.v128Consts[idx]
  let off = simdStackOffsetRv32(alloc, res, spillBase)
  for word in 0 .. 3:
    var bits: uint32
    copyMem(addr bits, unsafeAddr bytes[word * 4], 4)
    buf.loadImm32Native(rTmp0, cast[int32](bits))
    buf.emitStoreStack(rTmp0, off + word.int32 * 4)

proc emitSimdLaneLoadRv32(buf: var Rv64AsmBuffer, alloc: RegAllocResult,
                          vec: IrValue, spillBase: int32, lane: int,
                          laneBytes: int32, dst: RvReg, signed = false) =
  let off = simdStackOffsetRv32(alloc, vec, spillBase) + lane.int32 * laneBytes
  buf.emitLoadStackScalarRv32(dst, off, laneBytes, signed)

proc emitSimdLaneStoreRv32(buf: var Rv64AsmBuffer, alloc: RegAllocResult,
                           vec: IrValue, spillBase: int32, lane: int,
                           laneBytes: int32, src: RvReg) =
  let off = simdStackOffsetRv32(alloc, vec, spillBase) + lane.int32 * laneBytes
  buf.emitStoreStackScalarRv32(src, off, laneBytes)

proc emitSimdLaneLoad64Rv32(buf: var Rv64AsmBuffer, alloc: RegAllocResult,
                            vec: IrValue, spillBase: int32, lane: int,
                            loDst, hiDst: RvReg) =
  let off = simdStackOffsetRv32(alloc, vec, spillBase) + lane.int32 * 8
  buf.emitLoadStack(loDst, off)
  buf.emitLoadStack(hiDst, off + 4)

proc emitSimdLaneStore64Rv32(buf: var Rv64AsmBuffer, alloc: RegAllocResult,
                             vec: IrValue, spillBase: int32, lane: int,
                             lo, hi: RvReg) =
  let off = simdStackOffsetRv32(alloc, vec, spillBase) + lane.int32 * 8
  buf.emitStoreStack(lo, off)
  buf.emitStoreStack(hi, off + 4)

proc emitSimdSplat32Rv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                         alloc: RegAllocResult, res: IrValue,
                         spillBase: int32, sewBits: int) =
  let src = buf.loadOperandRv32(alloc, instr.operands[0], spillBase, rTmp0)
  if src != rTmp0: buf.mv(rTmp0, src)
  case sewBits
  of 8:
    buf.andi(rTmp0, rTmp0, 0xFF)
    buf.slli(rTmp1, rTmp0, 8)
    buf.orr(rTmp0, rTmp0, rTmp1)
    buf.slli(rTmp1, rTmp0, 16)
    buf.orr(rTmp0, rTmp0, rTmp1)
  of 16:
    buf.slli(rTmp0, rTmp0, 16)
    buf.srli(rTmp0, rTmp0, 16)
    buf.slli(rTmp1, rTmp0, 16)
    buf.orr(rTmp0, rTmp0, rTmp1)
  of 32:
    discard
  else:
    unsupportedRv32(instr.op)
  let off = simdStackOffsetRv32(alloc, res, spillBase)
  for word in 0 .. 3:
    buf.emitStoreStack(rTmp0, off + word.int32 * 4)

proc emitSimdSplat64Rv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                         alloc: RegAllocResult, res: IrValue,
                         spillBase, hiBase: int32) =
  let lo = buf.loadOperandRv32(alloc, instr.operands[0], spillBase, rTmp0)
  if lo != rTmp0: buf.mv(rTmp0, lo)
  discard buf.emitLoadHiRv32(rTmp1, alloc, instr.operands[0], hiBase)
  let off = simdStackOffsetRv32(alloc, res, spillBase)
  for lane in 0 .. 1:
    let laneOff = off + lane.int32 * 8
    buf.emitStoreStack(rTmp0, laneOff)
    buf.emitStoreStack(rTmp1, laneOff + 4)

proc emitSimdBitwiseRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                         alloc: RegAllocResult, res: IrValue,
                         spillBase: int32) =
  let dstOff = simdStackOffsetRv32(alloc, res, spillBase)
  let aOff = simdStackOffsetRv32(alloc, instr.operands[0], spillBase)
  let hasB = instr.op != irV128Not
  let bOff = if hasB: simdStackOffsetRv32(alloc, instr.operands[1], spillBase) else: 0'i32
  for word in 0 .. 3:
    let off = word.int32 * 4
    buf.emitLoadStack(rTmp0, aOff + off)
    if hasB:
      buf.emitLoadStack(rTmp1, bOff + off)
    case instr.op
    of irV128Not:
      buf.xori(rTmp0, rTmp0, -1)
    of irV128And:
      buf.andr(rTmp0, rTmp0, rTmp1)
    of irV128Or:
      buf.orr(rTmp0, rTmp0, rTmp1)
    of irV128Xor:
      buf.xorr(rTmp0, rTmp0, rTmp1)
    of irV128AndNot:
      buf.xori(rTmp1, rTmp1, -1)
      buf.andr(rTmp0, rTmp0, rTmp1)
    else:
      unsupportedRv32(instr.op)
    buf.emitStoreStack(rTmp0, dstOff + off)

proc emitSelectByFlagRv32(buf: var Rv64AsmBuffer, dst, whenFalse,
                          whenTrue, flag: RvReg) =
  if dst == whenTrue:
    buf.bne(flag, zero, 2)
    if dst != whenFalse: buf.mv(dst, whenFalse)
  else:
    if dst != whenFalse: buf.mv(dst, whenFalse)
    buf.beq(flag, zero, 2)
    if dst != whenTrue: buf.mv(dst, whenTrue)

proc emitSimdIntUnaryRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                          alloc: RegAllocResult, res: IrValue,
                          spillBase: int32, laneBytes: int32) =
  let lanes = 16 div laneBytes.int
  let srcOff = simdStackOffsetRv32(alloc, instr.operands[0], spillBase)
  let dstOff = simdStackOffsetRv32(alloc, res, spillBase)
  for lane in 0 ..< lanes:
    let off = lane.int32 * laneBytes
    buf.emitLoadStackScalarRv32(rTmp0, srcOff + off, laneBytes, signed = true)
    case instr.op
    of irI8x16Neg, irI16x8Neg, irI32x4Neg:
      buf.sub(rTmp0, zero, rTmp0)
    of irI8x16Abs, irI16x8Abs, irI32x4Abs:
      buf.sub(rTmp1, zero, rTmp0)
      buf.slt(rTmp2, rTmp0, zero)
      buf.emitSelectByFlagRv32(rTmp0, rTmp0, rTmp1, rTmp2)
    else:
      unsupportedRv32(instr.op)
    buf.emitStoreStackScalarRv32(rTmp0, dstOff + off, laneBytes)

proc emitSimdIntBinaryRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                           alloc: RegAllocResult, res: IrValue,
                           spillBase: int32, laneBytes: int32) =
  let lanes = 16 div laneBytes.int
  let aOff = simdStackOffsetRv32(alloc, instr.operands[0], spillBase)
  let bOff = simdStackOffsetRv32(alloc, instr.operands[1], spillBase)
  let dstOff = simdStackOffsetRv32(alloc, res, spillBase)
  let signedLoad = instr.op in {irI8x16MinS, irI8x16MaxS,
                                irI32x4MinS, irI32x4MaxS}
  for lane in 0 ..< lanes:
    let off = lane.int32 * laneBytes
    buf.emitLoadStackScalarRv32(rTmp0, aOff + off, laneBytes, signed = signedLoad)
    buf.emitLoadStackScalarRv32(rTmp1, bOff + off, laneBytes, signed = signedLoad)
    case instr.op
    of irI8x16Add, irI16x8Add, irI32x4Add:
      buf.add(rTmp0, rTmp0, rTmp1)
    of irI8x16Sub, irI16x8Sub, irI32x4Sub:
      buf.sub(rTmp0, rTmp0, rTmp1)
    of irI16x8Mul, irI32x4Mul:
      buf.mul(rTmp0, rTmp0, rTmp1)
    of irI8x16MinS, irI32x4MinS:
      buf.slt(rTmp2, rTmp0, rTmp1)
      buf.emitSelectByFlagRv32(rTmp0, rTmp1, rTmp0, rTmp2)
    of irI8x16MinU, irI32x4MinU:
      buf.sltu(rTmp2, rTmp0, rTmp1)
      buf.emitSelectByFlagRv32(rTmp0, rTmp1, rTmp0, rTmp2)
    of irI8x16MaxS, irI32x4MaxS:
      buf.slt(rTmp2, rTmp0, rTmp1)
      buf.emitSelectByFlagRv32(rTmp0, rTmp0, rTmp1, rTmp2)
    of irI8x16MaxU, irI32x4MaxU:
      buf.sltu(rTmp2, rTmp0, rTmp1)
      buf.emitSelectByFlagRv32(rTmp0, rTmp0, rTmp1, rTmp2)
    else:
      unsupportedRv32(instr.op)
    buf.emitStoreStackScalarRv32(rTmp0, dstOff + off, laneBytes)

proc emitSimdI32ShiftRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                          alloc: RegAllocResult, res: IrValue,
                          spillBase: int32) =
  let srcOff = simdStackOffsetRv32(alloc, instr.operands[0], spillBase)
  let dstOff = simdStackOffsetRv32(alloc, res, spillBase)
  let cnt = buf.loadOperandRv32(alloc, instr.operands[1], spillBase, rTmp3)
  if cnt != rTmp3: buf.mv(rTmp3, cnt)
  buf.andi(rTmp3, rTmp3, 31)
  for lane in 0 .. 3:
    let off = lane.int32 * 4
    buf.emitLoadStack(rTmp0, srcOff + off)
    case instr.op
    of irI32x4Shl:  buf.sll(rTmp0, rTmp0, rTmp3)
    of irI32x4ShrS: buf.sra(rTmp0, rTmp0, rTmp3)
    of irI32x4ShrU: buf.srl(rTmp0, rTmp0, rTmp3)
    else: unsupportedRv32(instr.op)
    buf.emitStoreStack(rTmp0, dstOff + off)

proc emitSimdI64BinaryRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                           alloc: RegAllocResult, res: IrValue,
                           spillBase: int32) =
  let dstOff = simdStackOffsetRv32(alloc, res, spillBase)
  for lane in 0 .. 1:
    let off = lane.int32 * 8
    buf.emitSimdLaneLoad64Rv32(alloc, instr.operands[0], spillBase, lane, rTmp0, rTmp1)
    buf.emitSimdLaneLoad64Rv32(alloc, instr.operands[1], spillBase, lane, rTmp2, rTmp3)
    case instr.op
    of irI64x2Add:
      buf.add(rTmp0, rTmp0, rTmp2)
      buf.sltu(rTmp4, rTmp0, rTmp2)
      buf.add(rTmp1, rTmp1, rTmp3)
      buf.add(rTmp1, rTmp1, rTmp4)
    of irI64x2Sub:
      buf.sltu(rTmp4, rTmp0, rTmp2)
      buf.sub(rTmp0, rTmp0, rTmp2)
      buf.sub(rTmp1, rTmp1, rTmp3)
      buf.sub(rTmp1, rTmp1, rTmp4)
    else:
      unsupportedRv32(instr.op)
    buf.emitStoreStack(rTmp0, dstOff + off)
    buf.emitStoreStack(rTmp1, dstOff + off + 4)

proc emitSimdF32BinaryRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                           alloc: RegAllocResult, res: IrValue,
                           spillBase: int32, target: RvTarget) =
  target.requireF32Rv32(instr.op)
  let aOff = simdStackOffsetRv32(alloc, instr.operands[0], spillBase)
  let bOff = simdStackOffsetRv32(alloc, instr.operands[1], spillBase)
  let dstOff = simdStackOffsetRv32(alloc, res, spillBase)
  for lane in 0 .. 3:
    let off = lane.int32 * 4
    buf.emitLoadStack(rTmp0, aOff + off)
    buf.emitLoadStack(rTmp1, bOff + off)
    buf.fmvWX(RvReg(0), rTmp0)
    buf.fmvWX(RvReg(1), rTmp1)
    case instr.op
    of irF32x4Add: buf.faddS(RvReg(0), RvReg(0), RvReg(1))
    of irF32x4Sub: buf.fsubS(RvReg(0), RvReg(0), RvReg(1))
    of irF32x4Mul: buf.fmulS(RvReg(0), RvReg(0), RvReg(1))
    of irF32x4Div: buf.fdivS(RvReg(0), RvReg(0), RvReg(1))
    else: unsupportedRv32(instr.op)
    buf.fmvXW(rTmp0, RvReg(0))
    buf.emitStoreStack(rTmp0, dstOff + off)

proc emitSimdF32UnaryBitsRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                              alloc: RegAllocResult, res: IrValue,
                              spillBase: int32) =
  let srcOff = simdStackOffsetRv32(alloc, instr.operands[0], spillBase)
  let dstOff = simdStackOffsetRv32(alloc, res, spillBase)
  let mask =
    if instr.op == irF32x4Abs: 0x7FFF_FFFF'i32
    else: cast[int32](0x8000_0000'u32)
  buf.loadImm32Native(rTmp1, mask)
  for lane in 0 .. 3:
    let off = lane.int32 * 4
    buf.emitLoadStack(rTmp0, srcOff + off)
    if instr.op == irF32x4Abs:
      buf.andr(rTmp0, rTmp0, rTmp1)
    else:
      buf.xorr(rTmp0, rTmp0, rTmp1)
    buf.emitStoreStack(rTmp0, dstOff + off)

proc emitSimdF64UnaryBitsRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                              alloc: RegAllocResult, res: IrValue,
                              spillBase: int32) =
  let srcOff = simdStackOffsetRv32(alloc, instr.operands[0], spillBase)
  let dstOff = simdStackOffsetRv32(alloc, res, spillBase)
  let mask =
    if instr.op == irF64x2Abs: 0x7FFF_FFFF'i32
    else: cast[int32](0x8000_0000'u32)
  buf.loadImm32Native(rTmp2, mask)
  for lane in 0 .. 1:
    let off = lane.int32 * 8
    buf.emitLoadStack(rTmp0, srcOff + off)
    buf.emitLoadStack(rTmp1, srcOff + off + 4)
    if instr.op == irF64x2Abs:
      buf.andr(rTmp1, rTmp1, rTmp2)
    else:
      buf.xorr(rTmp1, rTmp1, rTmp2)
    buf.emitStoreStack(rTmp0, dstOff + off)
    buf.emitStoreStack(rTmp1, dstOff + off + 4)

proc emitTrapIfA0NonZeroRv32(buf: var Rv64AsmBuffer) =
  buf.beq(a0, zero, 2)
  buf.ebreak()

proc emitStoreDirectArgRv32(buf: var Rv64AsmBuffer, alloc: RegAllocResult,
                            v: IrValue, argIdx: int, spillBase, hiBase: int32,
                            valueKinds: openArray[Rv32ValueKind]) =
  let off = rv32DirectArgBase + argIdx.int32 * 8'i32
  if v >= 0:
    let lo = buf.loadOperandRv32(alloc, v, spillBase, rTmp0)
    if valueKinds.isI64(v):
      let hi = buf.emitLoadHiRv32(rTmp1, alloc, v, hiBase)
      buf.emitStoreSlot64(lo, hi, sp, off)
    else:
      buf.emitStoreSlot64Low(lo, sp, off)
  else:
    buf.emitStoreSlot64Low(zero, sp, off)

proc emitDirectCallRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                        alloc: RegAllocResult, resReg: RvReg,
                        spillBase, hiBase: int32,
                        f: IrFunc,
                        funcElems: ptr UncheckedArray[TableElem],
                        numFuncs: int32,
                        valueKinds: openArray[Rv32ValueKind]) =
  let calleeIdx = instr.imm.int
  let targetPtr =
    if funcElems != nil and calleeIdx >= 0 and calleeIdx < numFuncs.int:
      addr funcElems[calleeIdx]
    else:
      nil
  let paramCount = if targetPtr != nil: targetPtr[].paramCount.int else: 0
  let resultCount = if targetPtr != nil: targetPtr[].resultCount.int else: 0
  if paramCount > rv32MaxDirectArgs.int:
    buf.ebreak()
    return

  var slotIdx = 0
  for i in 0 ..< paramCount:
    let opIdx = paramCount - 1 - i
    let argVal =
      if opIdx >= 0 and opIdx < instr.operands.len: instr.operands[opIdx]
      else: -1.IrValue
    if f.isSimdValueRv32(argVal):
      let srcOff = simdStackOffsetRv32(alloc, argVal, spillBase)
      let dstOff = rv32DirectArgBase + slotIdx.int32 * 8'i32
      for word in 0 .. 3:
        let off = word.int32 * 4
        buf.emitLoadStack(rTmp0, srcOff + off)
        buf.emitStoreStack(rTmp0, dstOff + off)
      inc slotIdx, 2
    else:
      buf.emitStoreDirectArgRv32(alloc, argVal, slotIdx, spillBase, hiBase, valueKinds)
      inc slotIdx

  buf.emitSaveRuntimeCallRv32()
  buf.loadImm32Native(a0, helperAddr32(cast[pointer](targetPtr)))
  buf.emitAddImm(a1, sp, rv32DirectArgBase)
  if f.usesMemory:
    buf.mv(a2, rMemBase)
    buf.mv(a3, rMemSize)
  else:
    buf.mv(a2, zero)
    buf.mv(a3, zero)
  buf.mv(a4, zero)
  buf.loadImm32Native(rTmp0, helperAddr32(cast[pointer](tier2DirectDispatch)))
  buf.jalr(ra, rTmp0, 0)
  buf.emitRestoreRuntimeCallRv32()
  buf.emitTrapIfA0NonZeroRv32()

  if instr.result >= 0 and resultCount > 0:
    if f.isSimdValueRv32(instr.result):
      let dstOff = simdStackOffsetRv32(alloc, instr.result, spillBase)
      for word in 0 .. 3:
        let off = word.int32 * 4
        buf.emitLoadStack(rTmp0, rv32DirectArgBase + off)
        buf.emitStoreStack(rTmp0, dstOff + off)
    elif valueKinds.isI64(instr.result):
      buf.emitLoadStack(resReg, rv32DirectArgBase)
      buf.emitLoadStack(rTmp1, rv32DirectArgBase + 4)
      buf.storeResult64Rv32(alloc, instr.result, resReg, rTmp1, spillBase, hiBase)
    else:
      buf.emitLoadStack(resReg, rv32DirectArgBase)

proc emitIndirectCallRv32(buf: var Rv64AsmBuffer, instr: IrInstr,
                          alloc: RegAllocResult, resReg: RvReg,
                          spillBase, hiBase: int32,
                          f: IrFunc,
                          callIndirectCaches: seq[ptr CallIndirectCache],
                          callIndirectSiteIdx: int,
                          valueKinds: openArray[Rv32ValueKind]) =
  let resultCount = ((instr.imm shr 16) and 0xFFFF).int
  let tempBase = instr.imm2.int
  let argOff = f.localByteOffsetRv32(tempBase)
  let cacheIdx = callIndirectSiteIdx - 1
  let cachePtr =
    if cacheIdx >= 0 and cacheIdx < callIndirectCaches.len:
      callIndirectCaches[cacheIdx]
    else:
      nil

  buf.emitSaveRuntimeCallRv32()
  buf.loadImm32Native(a0, helperAddr32(cast[pointer](cachePtr)))
  let elem = buf.loadOperandRv32(alloc, instr.operands[0], spillBase, a1)
  if elem != a1: buf.mv(a1, elem)
  buf.emitAddImm(a2, rLocals, argOff)
  if f.usesMemory:
    buf.mv(a3, rMemBase)
    buf.mv(a4, rMemSize)
  else:
    buf.mv(a3, zero)
    buf.mv(a4, zero)
  buf.mv(a5, zero)
  buf.loadImm32Native(rTmp0, helperAddr32(cast[pointer](tier2CallIndirectDispatch)))
  buf.jalr(ra, rTmp0, 0)
  buf.emitRestoreRuntimeCallRv32()
  buf.emitTrapIfA0NonZeroRv32()

  if instr.result >= 0 and resultCount > 0:
    if f.isSimdValueRv32(instr.result):
      buf.emitLoadSimdFromLocalsRv32(alloc, instr.result, spillBase, argOff)
    else:
      if fitsSimm12(argOff):
        buf.lw(resReg, rLocals, argOff)
      else:
        buf.emitAddImm(rTmp1, rLocals, argOff)
        buf.lw(resReg, rTmp1, 0)
      if valueKinds.isI64(instr.result):
        if fitsSimm12(argOff + 4):
          buf.lw(rTmp1, rLocals, argOff + 4)
        else:
          buf.emitAddImm(rTmp2, rLocals, argOff + 4)
          buf.lw(rTmp1, rTmp2, 0)
        buf.storeResult64Rv32(alloc, instr.result, resReg, rTmp1, spillBase, hiBase)

proc emitIrInstrRv32(buf: var Rv64AsmBuffer, instr: IrInstr, f: IrFunc,
                     alloc: RegAllocResult, spillBase, hiBase: int32,
                     curBlockIdx: int, blockLabels: var seq[Rv32BlockLabel],
                     epiloguePatchList: var seq[int], target: RvTarget,
                     valueKinds: openArray[Rv32ValueKind],
                     callIndirectCaches: seq[ptr CallIndirectCache],
                     callIndirectSiteIdx: int,
                     funcElems: ptr UncheckedArray[TableElem],
                     numFuncs: int32) =
  let res = instr.result
  let resReg = if res >= 0 and not alloc.isSpilledRv32(res): alloc.physRegRv32(res) else: rTmp0
  let resIsI64 = valueKinds.isI64(res)

  template loadOp(v: IrValue, s: RvReg): RvReg =
    buf.loadOperandRv32(alloc, v, spillBase, s)

  template storeRes(v: IrValue, src: RvReg) =
    buf.storeResultRv32(alloc, v, src, spillBase)

  case instr.op
  of irConst32:
    buf.loadImm32Native(resReg, instr.imm.int32)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)
  of irConst64:
    let u = cast[uint64](instr.imm)
    buf.loadImm32Native(resReg, cast[int32]((u and 0xFFFF_FFFF'u64).uint32))
    if alloc.isSpilledRv32(res): storeRes(res, resReg)
    if not (res.int < alloc.rematKind.len and alloc.rematKind[res.int] == rematConst):
      buf.loadImm32Native(rTmp1, cast[int32](((u shr 32) and 0xFFFF_FFFF'u64).uint32))
      buf.emitStoreHiRv32(res, rTmp1, hiBase)
  of irConstF32:
    buf.loadImm32Native(resReg, instr.imm.int32)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)
  of irConstF64:
    let u = cast[uint64](instr.imm)
    buf.loadImm32Native(resReg, cast[int32]((u and 0xFFFF_FFFF'u64).uint32))
    if alloc.isSpilledRv32(res): storeRes(res, resReg)
    buf.loadImm32Native(rTmp1, cast[int32](((u shr 32) and 0xFFFF_FFFF'u64).uint32))
    buf.emitStoreHiRv32(res, rTmp1, hiBase)

  of irParam, irLocalGet:
    let off = f.localByteOffsetRv32(instr.imm.int)
    if f.isSimdValueRv32(res):
      buf.emitLoadSimdFromLocalsRv32(alloc, res, spillBase, off)
    else:
      if fitsSimm12(off):
        buf.lw(resReg, rLocals, off)
      else:
        buf.emitAddImm(rTmp1, rLocals, off)
        buf.lw(resReg, rTmp1, 0)
      if alloc.isSpilledRv32(res): storeRes(res, resReg)
      if resIsI64:
        if fitsSimm12(off + 4):
          buf.lw(rTmp1, rLocals, off + 4)
        else:
          buf.emitAddImm(rTmp2, rLocals, off + 4)
          buf.lw(rTmp1, rTmp2, 0)
        buf.emitStoreHiRv32(res, rTmp1, hiBase)

  of irLocalSet:
    let off = f.localByteOffsetRv32(instr.imm.int)
    if f.isSimdValueRv32(instr.operands[0]):
      buf.emitStoreSimdToLocalsRv32(alloc, instr.operands[0], spillBase, off)
    else:
      let val = loadOp(instr.operands[0], rTmp0)
      if valueKinds.isI64(instr.operands[0]):
        let hi = buf.emitLoadHiRv32(rTmp1, alloc, instr.operands[0], hiBase)
        buf.emitStoreSlot64(val, hi, rLocals, off)
      else:
        buf.emitStoreSlot64Low(val, rLocals, off)

  of irAdd32, irSub32, irMul32, irAnd32, irOr32, irXor32,
     irShl32, irShr32U, irShr32S, irRotl32, irRotr32:
    buf.emitBin32(instr, alloc, resReg, spillBase, instr.op, target)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irDiv32S, irDiv32U, irRem32S, irRem32U:
    let a = loadOp(instr.operands[0], rTmp0)
    let b = loadOp(instr.operands[1], rTmp1)
    case instr.op
    of irDiv32S: buf.divs(resReg, a, b)
    of irDiv32U: buf.divu(resReg, a, b)
    of irRem32S: buf.rems(resReg, a, b)
    of irRem32U: buf.remu(resReg, a, b)
    else: discard
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irAdd64, irSub64, irMul64, irAnd64, irOr64, irXor64,
     irShl64, irShr64U, irShr64S:
    buf.emitBin64(instr, alloc, spillBase, hiBase, instr.op)

  of irRotl64:
    buf.emitRot64Rv32(instr, alloc, spillBase, hiBase, rotateRight = false)

  of irRotr64:
    buf.emitRot64Rv32(instr, alloc, spillBase, hiBase, rotateRight = true)

  of irDiv64S, irDiv64U, irRem64S, irRem64U:
    let helper = case instr.op
      of irDiv64S: cast[pointer](rv32JitDivS64Helper)
      of irDiv64U: cast[pointer](rv32JitDivU64Helper)
      of irRem64S: cast[pointer](rv32JitRemS64Helper)
      of irRem64U: cast[pointer](rv32JitRemU64Helper)
      else: nil
    buf.emitCallI64HelperRv32(instr, alloc, spillBase, hiBase, helper)

  of irAddF32, irSubF32, irMulF32, irDivF32, irMinF32, irMaxF32:
    buf.emitF32BinRv32(instr, alloc, resReg, spillBase, target)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irFmaF32, irFmsF32, irFnmaF32, irFnmsF32:
    buf.emitF32FmaRv32(instr, alloc, resReg, spillBase, target)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irSqrtF32:
    target.requireF32Rv32(instr.op)
    let a = loadOp(instr.operands[0], rTmp0)
    buf.fmvWX(RvReg(0), a)
    buf.fsqrtS(RvReg(0), RvReg(0))
    buf.fmvXW(resReg, RvReg(0))
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irAbsF32:
    let a = loadOp(instr.operands[0], rTmp0)
    buf.loadImm32Native(rTmp1, 0x7FFF_FFFF'i32)
    buf.andr(resReg, a, rTmp1)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irNegF32:
    let a = loadOp(instr.operands[0], rTmp0)
    buf.loadImm32Native(rTmp1, cast[int32](0x8000_0000'u32))
    buf.xorr(resReg, a, rTmp1)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irCopysignF32:
    let a = loadOp(instr.operands[0], rTmp0)
    let b = loadOp(instr.operands[1], rTmp1)
    buf.loadImm32Native(rTmp2, 0x7FFF_FFFF'i32)
    buf.andr(resReg, a, rTmp2)
    buf.loadImm32Native(rTmp2, cast[int32](0x8000_0000'u32))
    buf.andr(rTmp1, b, rTmp2)
    buf.orr(resReg, resReg, rTmp1)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irCeilF32, irFloorF32, irTruncF32, irNearestF32:
    let helper = case instr.op
      of irCeilF32: cast[pointer](rv32JitCeilF32Helper)
      of irFloorF32: cast[pointer](rv32JitFloorF32Helper)
      of irTruncF32: cast[pointer](rv32JitTruncF32Helper)
      of irNearestF32: cast[pointer](rv32JitNearestF32Helper)
      else: nil
    buf.emitCallF32UnaryHelperRv32(instr, alloc, resReg, spillBase,
                                   helper, target)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irEqF32, irNeF32, irLtF32, irGtF32, irLeF32, irGeF32:
    buf.emitF32CmpRv32(instr, alloc, resReg, spillBase, target)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irF32ConvertI32S, irF32ConvertI32U:
    target.requireF32Rv32(instr.op)
    let a = loadOp(instr.operands[0], rTmp0)
    buf.fcvtSW(RvReg(0), a, unsigned = instr.op == irF32ConvertI32U)
    buf.fmvXW(resReg, RvReg(0))
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irF32ConvertI64S, irF32ConvertI64U:
    let helper =
      if instr.op == irF32ConvertI64S:
        cast[pointer](rv32JitF32ConvertI64SHelper)
      else:
        cast[pointer](rv32JitF32ConvertI64UHelper)
    buf.emitCallI64ToF32HelperRv32(instr, alloc, resReg, spillBase,
                                   hiBase, helper, target)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irI32TruncF32S, irI32TruncF32U:
    target.requireF32Rv32(instr.op)
    let a = loadOp(instr.operands[0], rTmp0)
    buf.fmvWX(RvReg(0), a)
    buf.fcvtWS(resReg, RvReg(0), unsigned = instr.op == irI32TruncF32U)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irI64TruncF32S, irI64TruncF32U:
    let helper =
      if instr.op == irI64TruncF32S:
        cast[pointer](rv32JitI64TruncF32SHelper)
      else:
        cast[pointer](rv32JitI64TruncF32UHelper)
    buf.emitCallF32ToI64HelperRv32(instr, alloc, spillBase, hiBase,
                                   helper, target)

  of irAddF64, irSubF64, irMulF64, irDivF64, irMinF64, irMaxF64:
    let helper = case instr.op
      of irAddF64: cast[pointer](rv32JitAddF64Helper)
      of irSubF64: cast[pointer](rv32JitSubF64Helper)
      of irMulF64: cast[pointer](rv32JitMulF64Helper)
      of irDivF64: cast[pointer](rv32JitDivF64Helper)
      of irMinF64: cast[pointer](rv32JitMinF64Helper)
      of irMaxF64: cast[pointer](rv32JitMaxF64Helper)
      else: nil
    buf.emitCallF64BinaryHelperRv32(instr, alloc, spillBase, hiBase,
                                    helper, target)

  of irFmaF64, irFmsF64, irFnmaF64, irFnmsF64:
    let helper = case instr.op
      of irFmaF64: cast[pointer](rv32JitFmaF64Helper)
      of irFmsF64: cast[pointer](rv32JitFmsF64Helper)
      of irFnmaF64: cast[pointer](rv32JitFnmaF64Helper)
      of irFnmsF64: cast[pointer](rv32JitFnmsF64Helper)
      else: nil
    buf.emitCallF64TernaryHelperRv32(instr, alloc, spillBase, hiBase,
                                     helper, target)

  of irSqrtF64, irCeilF64, irFloorF64, irTruncF64, irNearestF64:
    let helper = case instr.op
      of irSqrtF64: cast[pointer](rv32JitSqrtF64Helper)
      of irCeilF64: cast[pointer](rv32JitCeilF64Helper)
      of irFloorF64: cast[pointer](rv32JitFloorF64Helper)
      of irTruncF64: cast[pointer](rv32JitTruncF64Helper)
      of irNearestF64: cast[pointer](rv32JitNearestF64Helper)
      else: nil
    buf.emitCallF64UnaryHelperRv32(instr, alloc, spillBase, hiBase,
                                   helper, target)

  of irAbsF64:
    buf.loadPairInto(alloc, instr.operands[0], spillBase, hiBase, resReg, rTmp1)
    buf.loadImm32Native(rTmp2, 0x7FFF_FFFF'i32)
    buf.andr(rTmp1, rTmp1, rTmp2)
    buf.storeResult64Rv32(alloc, res, resReg, rTmp1, spillBase, hiBase)

  of irNegF64:
    buf.loadPairInto(alloc, instr.operands[0], spillBase, hiBase, resReg, rTmp1)
    buf.loadImm32Native(rTmp2, cast[int32](0x8000_0000'u32))
    buf.xorr(rTmp1, rTmp1, rTmp2)
    buf.storeResult64Rv32(alloc, res, resReg, rTmp1, spillBase, hiBase)

  of irCopysignF64:
    buf.loadPairInto(alloc, instr.operands[0], spillBase, hiBase, resReg, rTmp1)
    discard buf.emitLoadHiRv32(rTmp2, alloc, instr.operands[1], hiBase)
    buf.loadImm32Native(rTmp3, 0x7FFF_FFFF'i32)
    buf.andr(rTmp1, rTmp1, rTmp3)
    buf.loadImm32Native(rTmp3, cast[int32](0x8000_0000'u32))
    buf.andr(rTmp2, rTmp2, rTmp3)
    buf.orr(rTmp1, rTmp1, rTmp2)
    buf.storeResult64Rv32(alloc, res, resReg, rTmp1, spillBase, hiBase)

  of irEqF64, irNeF64, irLtF64, irGtF64, irLeF64, irGeF64:
    let helper = case instr.op
      of irEqF64: cast[pointer](rv32JitEqF64Helper)
      of irNeF64: cast[pointer](rv32JitNeF64Helper)
      of irLtF64: cast[pointer](rv32JitLtF64Helper)
      of irGtF64: cast[pointer](rv32JitGtF64Helper)
      of irLeF64: cast[pointer](rv32JitLeF64Helper)
      of irGeF64: cast[pointer](rv32JitGeF64Helper)
      else: nil
    buf.emitCallF64CmpHelperRv32(instr, alloc, resReg, spillBase, hiBase,
                                 helper, target)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irF64ConvertI32S, irF64ConvertI32U:
    let helper =
      if instr.op == irF64ConvertI32S:
        cast[pointer](rv32JitF64ConvertI32SHelper)
      else:
        cast[pointer](rv32JitF64ConvertI32UHelper)
    buf.emitCallI32ToF64HelperRv32(instr, alloc, spillBase, hiBase,
                                   helper, target)

  of irF64ConvertI64S, irF64ConvertI64U:
    let helper =
      if instr.op == irF64ConvertI64S:
        cast[pointer](rv32JitF64ConvertI64SHelper)
      else:
        cast[pointer](rv32JitF64ConvertI64UHelper)
    buf.emitCallI64ToF64HelperRv32(instr, alloc, spillBase, hiBase,
                                   helper, target)

  of irI32TruncF64S, irI32TruncF64U:
    let helper =
      if instr.op == irI32TruncF64S:
        cast[pointer](rv32JitI32TruncF64SHelper)
      else:
        cast[pointer](rv32JitI32TruncF64UHelper)
    buf.emitCallF64ToI32HelperRv32(instr, alloc, resReg, spillBase,
                                   hiBase, helper, target)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irI64TruncF64S, irI64TruncF64U:
    let helper =
      if instr.op == irI64TruncF64S:
        cast[pointer](rv32JitI64TruncF64SHelper)
      else:
        cast[pointer](rv32JitI64TruncF64UHelper)
    buf.emitCallF64ToI64HelperRv32(instr, alloc, spillBase, hiBase,
                                   helper, target)

  of irF32DemoteF64:
    buf.emitCallF64ToF32HelperRv32(instr, alloc, resReg, spillBase,
                                   hiBase, cast[pointer](rv32JitF32DemoteF64Helper),
                                   target)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irF64PromoteF32:
    buf.emitCallF32ToF64HelperRv32(instr, alloc, spillBase, hiBase,
                                   cast[pointer](rv32JitF64PromoteF32Helper),
                                   target)

  of irI32ReinterpretF32, irF32ReinterpretI32:
    let a = loadOp(instr.operands[0], rTmp0)
    if resReg != a: buf.mv(resReg, a)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irI64ReinterpretF64, irF64ReinterpretI64:
    let lo = loadOp(instr.operands[0], resReg)
    if lo != resReg: buf.mv(resReg, lo)
    let hi = buf.emitLoadHiRv32(rTmp1, alloc, instr.operands[0], hiBase)
    buf.storeResult64Rv32(alloc, res, resReg, hi, spillBase, hiBase)

  of irClz32, irCtz32, irPopcnt32:
    let a = loadOp(instr.operands[0], rTmp0)
    if rvExtZbb in target.features:
      case instr.op
      of irClz32: buf.clz(resReg, a)
      of irCtz32: buf.ctz(resReg, a)
      of irPopcnt32: buf.cpop(resReg, a)
      else: discard
    else:
      case instr.op
      of irClz32:
        buf.emitClz32FallbackRv32(resReg, a, rTmp1, rTmp2, rTmp3)
      of irCtz32:
        buf.emitCtz32FallbackRv32(resReg, a, rTmp1, rTmp2, rTmp3)
      of irPopcnt32:
        buf.emitPopcnt32FallbackRv32(resReg, a, rTmp1, rTmp2)
      else:
        discard
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irEqz32:
    let a = loadOp(instr.operands[0], rTmp0)
    buf.seqz(resReg, a)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irEq32, irNe32, irLt32S, irLt32U, irGt32S, irGt32U,
     irLe32S, irLe32U, irGe32S, irGe32U:
    buf.emitCmp32(instr, alloc, resReg, spillBase)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irClz64, irCtz64, irPopcnt64:
    buf.loadPairInto(alloc, instr.operands[0], spillBase, hiBase, rTmp0, rTmp1)
    if rvExtZbb in target.features:
      case instr.op
      of irClz64:
        let lowPatch = buf.pos
        buf.beq(rTmp1, zero, 0)
        buf.clz(resReg, rTmp1)
        let endPatch = buf.pos
        buf.j(0)
        let lowPos = buf.pos
        buf.patchBranchTo(lowPatch, lowPos)
        buf.clz(resReg, rTmp0)
        buf.addi(resReg, resReg, 32)
        buf.patchJalTo(endPatch, buf.pos)
      of irCtz64:
        let highPatch = buf.pos
        buf.beq(rTmp0, zero, 0)
        buf.ctz(resReg, rTmp0)
        let endPatch = buf.pos
        buf.j(0)
        let highPos = buf.pos
        buf.patchBranchTo(highPatch, highPos)
        buf.ctz(resReg, rTmp1)
        buf.addi(resReg, resReg, 32)
        buf.patchJalTo(endPatch, buf.pos)
      of irPopcnt64:
        buf.cpop(resReg, rTmp0)
        buf.cpop(rTmp1, rTmp1)
        buf.add(resReg, resReg, rTmp1)
      else:
        discard
    else:
      case instr.op
      of irClz64:
        let lowPatch = buf.pos
        buf.beq(rTmp1, zero, 0)
        buf.emitClz32FallbackRv32(resReg, rTmp1, rTmp2, rTmp3, rTmp4)
        let endPatch = buf.pos
        buf.j(0)
        let lowPos = buf.pos
        buf.patchBranchTo(lowPatch, lowPos)
        buf.emitClz32FallbackRv32(resReg, rTmp0, rTmp2, rTmp3, rTmp4)
        buf.addi(resReg, resReg, 32)
        buf.patchJalTo(endPatch, buf.pos)
      of irCtz64:
        let highPatch = buf.pos
        buf.beq(rTmp0, zero, 0)
        buf.emitCtz32FallbackRv32(resReg, rTmp0, rTmp2, rTmp3, rTmp4)
        let endPatch = buf.pos
        buf.j(0)
        let highPos = buf.pos
        buf.patchBranchTo(highPatch, highPos)
        buf.emitCtz32FallbackRv32(resReg, rTmp1, rTmp2, rTmp3, rTmp4)
        buf.addi(resReg, resReg, 32)
        buf.patchJalTo(endPatch, buf.pos)
      of irPopcnt64:
        buf.emitPopcnt32FallbackRv32(resReg, rTmp0, rTmp2, rTmp3)
        buf.emitPopcnt32FallbackRv32(rTmp2, rTmp1, rTmp3, rTmp4)
        buf.add(resReg, resReg, rTmp2)
      else:
        discard
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irEqz64:
    let lo = loadOp(instr.operands[0], rTmp0)
    let hi = buf.emitLoadHiRv32(rTmp1, alloc, instr.operands[0], hiBase)
    buf.orr(resReg, lo, hi)
    buf.seqz(resReg, resReg)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irEq64, irNe64, irLt64S, irLt64U, irGt64S, irGt64U,
     irLe64S, irLe64U, irGe64S, irGe64U:
    buf.emitCmp64(instr, alloc, resReg, spillBase, hiBase)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irWrapI64:
    let a = loadOp(instr.operands[0], rTmp0)
    if resReg != a: buf.mv(resReg, a)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irExtendI32S, irExtendI32U:
    let a = loadOp(instr.operands[0], rTmp0)
    if resReg != a: buf.mv(resReg, a)
    if instr.op == irExtendI32S:
      buf.srai(rTmp1, a, 31)
    else:
      buf.mv(rTmp1, zero)
    buf.storeResult64Rv32(alloc, res, resReg, rTmp1, spillBase, hiBase)

  of irExtend8S32:
    let a = loadOp(instr.operands[0], rTmp0)
    if rvExtZbb in target.features:
      buf.sextB(resReg, a)
    else:
      buf.slli(resReg, a, 24)
      buf.srai(resReg, resReg, 24)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)
  of irExtend16S32:
    let a = loadOp(instr.operands[0], rTmp0)
    if rvExtZbb in target.features:
      buf.sextH(resReg, a)
    else:
      buf.slli(resReg, a, 16)
      buf.srai(resReg, resReg, 16)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irExtend8S64:
    let a = loadOp(instr.operands[0], rTmp0)
    if rvExtZbb in target.features:
      buf.sextB(rTmp0, a)
    else:
      buf.slli(rTmp0, a, 24)
      buf.srai(rTmp0, rTmp0, 24)
    buf.srai(rTmp1, rTmp0, 31)
    buf.storeResult64Rv32(alloc, res, rTmp0, rTmp1, spillBase, hiBase)
  of irExtend16S64:
    let a = loadOp(instr.operands[0], rTmp0)
    if rvExtZbb in target.features:
      buf.sextH(rTmp0, a)
    else:
      buf.slli(rTmp0, a, 16)
      buf.srai(rTmp0, rTmp0, 16)
    buf.srai(rTmp1, rTmp0, 31)
    buf.storeResult64Rv32(alloc, res, rTmp0, rTmp1, spillBase, hiBase)
  of irExtend32S64:
    let a = loadOp(instr.operands[0], rTmp0)
    if rTmp0 != a: buf.mv(rTmp0, a)
    buf.srai(rTmp1, rTmp0, 31)
    buf.storeResult64Rv32(alloc, res, rTmp0, rTmp1, spillBase, hiBase)

  of irLoad8U, irLoad8S, irLoad16U, irLoad16S, irLoad32, irLoad32U, irLoad32S,
     irLoad64, irLoadF64:
    let addrReg = loadOp(instr.operands[0], rTmp0)
    let accessBytes = case instr.op
      of irLoad8U, irLoad8S: 1'i32
      of irLoad16U, irLoad16S: 2'i32
      of irLoad64, irLoadF64: 8'i32
      else: 4'i32
    buf.emitBoundsCheckRv32(addrReg, accessBytes, instr.imm2)
    if instr.op in {irLoad64, irLoadF64}:
      buf.emitEffectiveAddr(rTmp1, addrReg)
      if not (fitsSimm12(instr.imm2) and fitsSimm12(instr.imm2 + 4)):
        buf.emitAddImm(rTmp1, rTmp1, instr.imm2)
      let off = if fitsSimm12(instr.imm2) and fitsSimm12(instr.imm2 + 4): instr.imm2 else: 0
      buf.lw(resReg, rTmp1, off)
      buf.lw(rTmp2, rTmp1, off + 4)
      buf.storeResult64Rv32(alloc, res, resReg, rTmp2, spillBase, hiBase)
    elif resIsI64:
      buf.emitLoadMemRv32(instr.op, resReg, addrReg, instr.imm2)
      case instr.op
      of irLoad8S, irLoad16S, irLoad32S:
        buf.srai(rTmp1, resReg, 31)
      else:
        buf.mv(rTmp1, zero)
      buf.storeResult64Rv32(alloc, res, resReg, rTmp1, spillBase, hiBase)
    else:
      buf.emitLoadMemRv32(instr.op, resReg, addrReg, instr.imm2)
      if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irLoadF32:
    let addrReg = loadOp(instr.operands[0], rTmp0)
    buf.emitBoundsCheckRv32(addrReg, 4, instr.imm2)
    buf.emitLoadMemRv32(irLoad32, resReg, addrReg, instr.imm2)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)

  of irStore8, irStore16, irStore32, irStore32From64, irStore64, irStoreF64:
    let addrReg = loadOp(instr.operands[0], rTmp0)
    let val = loadOp(instr.operands[1], rTmp2)
    let accessBytes = case instr.op
      of irStore8: 1'i32
      of irStore16: 2'i32
      of irStore64, irStoreF64: 8'i32
      else: 4'i32
    buf.emitBoundsCheckRv32(addrReg, accessBytes, instr.imm2)
    if instr.op in {irStore64, irStoreF64}:
      let hi = buf.emitLoadHiRv32(rTmp3, alloc, instr.operands[1], hiBase)
      buf.emitEffectiveAddr(rTmp1, addrReg)
      if not (fitsSimm12(instr.imm2) and fitsSimm12(instr.imm2 + 4)):
        buf.emitAddImm(rTmp1, rTmp1, instr.imm2)
      let off = if fitsSimm12(instr.imm2) and fitsSimm12(instr.imm2 + 4): instr.imm2 else: 0
      buf.sw(val, rTmp1, off)
      buf.sw(hi, rTmp1, off + 4)
    else:
      buf.emitStoreMemRv32(
        if instr.op == irStore32From64: irStore32 else: instr.op,
        val, addrReg, instr.imm2)

  of irStoreF32:
    let addrReg = loadOp(instr.operands[0], rTmp0)
    let val = loadOp(instr.operands[1], rTmp2)
    buf.emitBoundsCheckRv32(addrReg, 4, instr.imm2)
    buf.emitStoreMemRv32(irStore32, val, addrReg, instr.imm2)

  # ---- SIMD v128, stack-backed on RV32 ----
  of irLoadV128:
    let addrReg = loadOp(instr.operands[0], rTmp0)
    buf.emitBoundsCheckRv32(addrReg, 16, instr.imm2)
    buf.emitEffectiveAddr(rTmp2, addrReg)
    if instr.imm2 != 0:
      buf.emitAddImm(rTmp2, rTmp2, instr.imm2, rTmp1)
    let dstOff = simdStackOffsetRv32(alloc, res, spillBase)
    for word in 0 .. 3:
      let off = word.int32 * 4
      buf.lw(rTmp0, rTmp2, off)
      buf.emitStoreStack(rTmp0, dstOff + off)

  of irStoreV128:
    let addrReg = loadOp(instr.operands[0], rTmp0)
    buf.emitBoundsCheckRv32(addrReg, 16, instr.imm2)
    buf.emitEffectiveAddr(rTmp2, addrReg)
    if instr.imm2 != 0:
      buf.emitAddImm(rTmp2, rTmp2, instr.imm2, rTmp1)
    let srcOff = simdStackOffsetRv32(alloc, instr.operands[1], spillBase)
    for word in 0 .. 3:
      let off = word.int32 * 4
      buf.emitLoadStack(rTmp0, srcOff + off)
      buf.sw(rTmp0, rTmp2, off)

  of irConstV128:
    buf.emitSimdConstRv32(f, alloc, res, spillBase, instr.imm.int)

  of irI8x16Splat:
    buf.emitSimdSplat32Rv32(instr, alloc, res, spillBase, 8)
  of irI16x8Splat:
    buf.emitSimdSplat32Rv32(instr, alloc, res, spillBase, 16)
  of irI32x4Splat, irF32x4Splat:
    buf.emitSimdSplat32Rv32(instr, alloc, res, spillBase, 32)
  of irI64x2Splat, irF64x2Splat:
    buf.emitSimdSplat64Rv32(instr, alloc, res, spillBase, hiBase)

  of irI8x16ExtractLaneS:
    buf.emitSimdLaneLoadRv32(alloc, instr.operands[0], spillBase,
                             instr.imm.int, 1, resReg, signed = true)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)
  of irI8x16ExtractLaneU:
    buf.emitSimdLaneLoadRv32(alloc, instr.operands[0], spillBase,
                             instr.imm.int, 1, resReg, signed = false)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)
  of irI16x8ExtractLaneS:
    buf.emitSimdLaneLoadRv32(alloc, instr.operands[0], spillBase,
                             instr.imm.int, 2, resReg, signed = true)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)
  of irI16x8ExtractLaneU:
    buf.emitSimdLaneLoadRv32(alloc, instr.operands[0], spillBase,
                             instr.imm.int, 2, resReg, signed = false)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)
  of irI32x4ExtractLane, irF32x4ExtractLane:
    buf.emitSimdLaneLoadRv32(alloc, instr.operands[0], spillBase,
                             instr.imm.int, 4, resReg, signed = false)
    if alloc.isSpilledRv32(res): storeRes(res, resReg)
  of irI64x2ExtractLane, irF64x2ExtractLane:
    buf.emitSimdLaneLoad64Rv32(alloc, instr.operands[0], spillBase,
                               instr.imm.int, resReg, rTmp1)
    buf.storeResult64Rv32(alloc, res, resReg, rTmp1, spillBase, hiBase)

  of irI8x16ReplaceLane:
    let val = loadOp(instr.operands[1], rTmp0)
    buf.emitCopySimdRv32(alloc, res, instr.operands[0], spillBase)
    buf.emitSimdLaneStoreRv32(alloc, res, spillBase, instr.imm.int, 1, val)
  of irI16x8ReplaceLane:
    let val = loadOp(instr.operands[1], rTmp0)
    buf.emitCopySimdRv32(alloc, res, instr.operands[0], spillBase)
    buf.emitSimdLaneStoreRv32(alloc, res, spillBase, instr.imm.int, 2, val)
  of irI32x4ReplaceLane, irF32x4ReplaceLane:
    let val = loadOp(instr.operands[1], rTmp0)
    buf.emitCopySimdRv32(alloc, res, instr.operands[0], spillBase)
    buf.emitSimdLaneStoreRv32(alloc, res, spillBase, instr.imm.int, 4, val)
  of irI64x2ReplaceLane, irF64x2ReplaceLane:
    let lo = loadOp(instr.operands[1], rTmp0)
    if lo != rTmp0: buf.mv(rTmp0, lo)
    discard buf.emitLoadHiRv32(rTmp1, alloc, instr.operands[1], hiBase)
    buf.emitCopySimdRv32(alloc, res, instr.operands[0], spillBase)
    buf.emitSimdLaneStore64Rv32(alloc, res, spillBase, instr.imm.int, rTmp0, rTmp1)

  of irV128Not, irV128And, irV128Or, irV128Xor, irV128AndNot:
    buf.emitSimdBitwiseRv32(instr, alloc, res, spillBase)

  of irI8x16Abs, irI8x16Neg:
    buf.emitSimdIntUnaryRv32(instr, alloc, res, spillBase, 1)
  of irI8x16Add, irI8x16Sub, irI8x16MinS, irI8x16MinU,
     irI8x16MaxS, irI8x16MaxU:
    buf.emitSimdIntBinaryRv32(instr, alloc, res, spillBase, 1)

  of irI16x8Abs, irI16x8Neg:
    buf.emitSimdIntUnaryRv32(instr, alloc, res, spillBase, 2)
  of irI16x8Add, irI16x8Sub, irI16x8Mul:
    buf.emitSimdIntBinaryRv32(instr, alloc, res, spillBase, 2)

  of irI32x4Abs, irI32x4Neg:
    buf.emitSimdIntUnaryRv32(instr, alloc, res, spillBase, 4)
  of irI32x4Add, irI32x4Sub, irI32x4Mul,
     irI32x4MinS, irI32x4MinU, irI32x4MaxS, irI32x4MaxU:
    buf.emitSimdIntBinaryRv32(instr, alloc, res, spillBase, 4)
  of irI32x4Shl, irI32x4ShrS, irI32x4ShrU:
    buf.emitSimdI32ShiftRv32(instr, alloc, res, spillBase)

  of irI64x2Add, irI64x2Sub:
    buf.emitSimdI64BinaryRv32(instr, alloc, res, spillBase)

  of irF32x4Add, irF32x4Sub, irF32x4Mul, irF32x4Div:
    buf.emitSimdF32BinaryRv32(instr, alloc, res, spillBase, target)
  of irF32x4Abs, irF32x4Neg:
    buf.emitSimdF32UnaryBitsRv32(instr, alloc, res, spillBase)

  of irF64x2Abs, irF64x2Neg:
    buf.emitSimdF64UnaryBitsRv32(instr, alloc, res, spillBase)
  of irF64x2Add, irF64x2Sub, irF64x2Mul, irF64x2Div:
    unsupportedRv32(instr.op)

  of irBr:
    let targetBb = instr.imm.int
    buf.emitPhiResolutionRv32(f, alloc, targetBb, curBlockIdx, spillBase,
                              hiBase, valueKinds)
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
    buf.emitPhiResolutionRv32(f, alloc, targetBb, curBlockIdx, spillBase,
                              hiBase, valueKinds)
    if targetBb < blockLabels.len and blockLabels[targetBb].offset >= 0:
      buf.bne(cond, zero, (blockLabels[targetBb].offset - buf.pos).int32)
    else:
      blockLabels.ensureLabel(targetBb)
      let p = buf.pos
      buf.bne(cond, zero, 0)
      blockLabels[targetBb].patchList.add((p, true))
    let falseBb = instr.imm2.int
    if falseBb > 0:
      buf.emitPhiResolutionRv32(f, alloc, falseBb, curBlockIdx, spillBase,
                                hiBase, valueKinds)
      if falseBb < blockLabels.len and blockLabels[falseBb].offset >= 0:
        buf.j((blockLabels[falseBb].offset - buf.pos).int32)
      else:
        blockLabels.ensureLabel(falseBb)
        let p = buf.pos
        buf.j(0)
        blockLabels[falseBb].patchList.add((p, false))

  of irReturn:
    if instr.operands[0] >= 0:
      if f.isSimdValueRv32(instr.operands[0]):
        let srcOff = simdStackOffsetRv32(alloc, instr.operands[0], spillBase)
        for word in 0 .. 3:
          let off = word.int32 * 4
          buf.emitLoadStack(rTmp0, srcOff + off)
          buf.sw(rTmp0, rVsp, off)
        buf.addi(rVsp, rVsp, 16)
      else:
        let val = loadOp(instr.operands[0], rTmp0)
        if valueKinds.isI64(instr.operands[0]):
          let hi = buf.emitLoadHiRv32(rTmp1, alloc, instr.operands[0], hiBase)
          buf.emitStoreSlot64(val, hi, rVsp, 0)
        else:
          buf.emitStoreSlot64Low(val, rVsp, 0)
        buf.addi(rVsp, rVsp, 8)
    let p = buf.pos
    buf.j(0)
    epiloguePatchList.add(p)

  of irSelect:
    let cond = loadOp(instr.operands[0], rTmp1)
    let a = loadOp(instr.operands[1], rTmp0)
    let b = loadOp(instr.operands[2], rTmp2)
    if resIsI64:
      discard buf.emitLoadHiRv32(rTmp3, alloc, instr.operands[1], hiBase)
      discard buf.emitLoadHiRv32(rTmp4, alloc, instr.operands[2], hiBase)
    if rvXTheadCondMov in target.features:
      if resReg != b: buf.mv(resReg, b)
      buf.thMvnez(resReg, a, cond)
      if resIsI64:
        buf.mv(rTmp5, rTmp4)
        buf.thMvnez(rTmp5, rTmp3, cond)
    else:
      if resReg != a: buf.mv(resReg, a)
      buf.bne(cond, zero, 2)
      if resReg != b: buf.mv(resReg, b)
      if resIsI64:
        buf.mv(rTmp5, rTmp3)
        buf.bne(cond, zero, 2)
        buf.mv(rTmp5, rTmp4)
    if resIsI64:
      buf.storeResult64Rv32(alloc, res, resReg, rTmp5, spillBase, hiBase)
    elif alloc.isSpilledRv32(res):
      storeRes(res, resReg)

  of irCall:
    buf.emitDirectCallRv32(instr, alloc, resReg, spillBase, hiBase, f,
                           funcElems, numFuncs, valueKinds)
    if instr.result >= 0 and not f.isSimdValueRv32(instr.result) and
       not valueKinds.isI64(instr.result) and
       alloc.isSpilledRv32(res):
      storeRes(res, resReg)

  of irCallIndirect:
    buf.emitIndirectCallRv32(instr, alloc, resReg, spillBase, hiBase, f,
                             callIndirectCaches, callIndirectSiteIdx,
                             valueKinds)
    if instr.result >= 0 and not f.isSimdValueRv32(instr.result) and
       not valueKinds.isI64(instr.result) and
       alloc.isSpilledRv32(res):
      storeRes(res, resReg)

  of irPhi:
    discard
  of irNop:
    if instr.operands[0] >= 0 and res >= 0:
      if f.isSimdValueRv32(res):
        buf.emitCopySimdRv32(alloc, res, instr.operands[0], spillBase)
      else:
        let v = loadOp(instr.operands[0], rTmp0)
        if resReg != v: buf.mv(resReg, v)
        if resIsI64:
          let hi = buf.emitLoadHiRv32(rTmp1, alloc, instr.operands[0], hiBase)
          buf.storeResult64Rv32(alloc, res, resReg, hi, spillBase, hiBase)
        elif alloc.isSpilledRv32(res):
          storeRes(res, resReg)
    else:
      buf.nop()
  of irTrap:
    buf.ebreak()
  else:
    unsupportedRv32(instr.op)

proc emitIrFuncRv32*(pool: var JitMemPool, f: IrFunc, alloc: RegAllocResult,
                     selfModuleIdx: int = -1,
                     tableElems: ptr UncheckedArray[TableElem] = nil,
                     tableLen: int32 = 0,
                     funcElems: ptr UncheckedArray[TableElem] = nil,
                     numFuncs: int32 = 0,
                     valueKinds: openArray[Rv32ValueKind] = [],
                     target: RvTarget = rv32GenericTarget): JitCode =
  discard selfModuleIdx

  if target.xlen != rv32:
    raise newException(ValueError, "RV32 JIT backend requires an RV32 target")

  var buf = initRv32AsmBuffer(f.numValues * 6 + 96)

  let spillBytes = alloc.totalSpillBytes
  let hiBytes = f.numValues.int32 * 4
  let hiBase = savedBytes + spillBytes.int32
  let frameSize = (savedBytes + spillBytes.int32 + hiBytes + 15'i32) and (not 15'i32)
  let spillBase = savedBytes

  # Prologue.
  if fitsSimm12(-frameSize):
    buf.addi(sp, sp, -frameSize)
  else:
    buf.loadImm32Native(rTmp1, frameSize)
    buf.sub(sp, sp, rTmp1)

  buf.sw(ra, sp, 0)
  buf.sw(s0, sp, 4)
  buf.sw(s1, sp, 8)

  buf.mv(rVsp, a0)
  buf.mv(rLocals, a1)

  var callIndirectCaches = newSeq[ptr CallIndirectCache](f.callIndirectSiteCount)
  for i in 0 ..< f.callIndirectSiteCount:
    let p = cast[ptr CallIndirectCache](allocShared0(sizeof(CallIndirectCache)))
    p.cachedElemIdx = -1
    p.tableElems = tableElems
    p.tableLen = tableLen
    pool.sideData.add(p)
    callIndirectCaches[i] = p

  var blockLabels = newSeq[Rv32BlockLabel](f.blocks.len)
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
      buf.emitIrInstrRv32(instr, f, alloc, spillBase, hiBase, bbIdx, blockLabels,
                          epiloguePatchList, target, valueKinds,
                          callIndirectCaches, callIndirectSiteIdx,
                          funcElems, numFuncs)

  let epilogueOffset = buf.pos
  for patchPos in epiloguePatchList:
    buf.patchJalAt(patchPos, (epilogueOffset - patchPos).int32)

  # Epilogue.
  buf.mv(a0, rVsp)
  buf.lw(ra, sp, 0)
  buf.lw(s0, sp, 4)
  buf.lw(s1, sp, 8)

  if fitsSimm12(frameSize):
    buf.addi(sp, sp, frameSize)
  else:
    buf.loadImm32Native(rTmp1, frameSize)
    buf.add(sp, sp, rTmp1)
  buf.ret()

  result = pool.writeCode(buf.code)
  result.size = buf.code.len * 4
  result.numLocals = if f.localSlotCount > 0: f.localSlotCount else: f.numLocals
