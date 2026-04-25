## RISC-V instruction encoder for the WASM JIT.
##
## The baseline targets are RV32IM and RV64IM. Optional standard and T-Head
## extension encoders are kept explicit so codegen only emits them when a
## target opts in.

type
  RvReg* = distinct uint8

  RvXlen* = enum
    rv32
    rv64

  RvCond* = enum
    rvEq, rvNe, rvLt, rvGe, rvLtu, rvGeu

  RvFeature* = enum
    rvExtE
    rvExtM
    rvExtA
    rvExtF
    rvExtD
    rvExtC
    rvExtP
    rvExtV
    rvExtZicsr
    rvExtZifencei
    rvExtZba
    rvExtZbb
    rvExtZbs
    rvXTheadBa
    rvXTheadBb
    rvXTheadBs
    rvXTheadCmo
    rvXTheadCondMov
    rvXTheadFMemIdx
    rvXTheadFmv
    rvXTheadInt
    rvXTheadMac
    rvXTheadMemIdx
    rvXTheadMemPair
    rvXTheadSync
    rvXTheadVdot
    rvXTheadVector

  Rv64Feature* = RvFeature
  Rv32Feature* = RvFeature

  RvTarget* = object
    xlen*: RvXlen
    features*: set[RvFeature]

  Rv64Target* = RvTarget
  Rv32Target* = RvTarget

  Bl808Core* = enum
    bl808D0
    bl808M0
    bl808LP

  RvAsmBuffer* = object
    code*: seq[uint32]

  Rv64AsmBuffer* = RvAsmBuffer
  Rv32AsmBuffer* = RvAsmBuffer

const
  zero* = RvReg(0)
  ra* = RvReg(1)
  sp* = RvReg(2)
  gp* = RvReg(3)
  tp* = RvReg(4)
  t0* = RvReg(5)
  t1* = RvReg(6)
  t2* = RvReg(7)
  s0* = RvReg(8)
  fp* = RvReg(8)
  s1* = RvReg(9)
  a0* = RvReg(10)
  a1* = RvReg(11)
  a2* = RvReg(12)
  a3* = RvReg(13)
  a4* = RvReg(14)
  a5* = RvReg(15)
  a6* = RvReg(16)
  a7* = RvReg(17)
  s2* = RvReg(18)
  s3* = RvReg(19)
  s4* = RvReg(20)
  s5* = RvReg(21)
  s6* = RvReg(22)
  s7* = RvReg(23)
  s8* = RvReg(24)
  s9* = RvReg(25)
  s10* = RvReg(26)
  s11* = RvReg(27)
  t3* = RvReg(28)
  t4* = RvReg(29)
  t5* = RvReg(30)
  t6* = RvReg(31)

  rv64XTheadBa* = rvXTheadBa
  rv64XTheadBb* = rvXTheadBb
  rv64XTheadBs* = rvXTheadBs
  rv64XTheadCmo* = rvXTheadCmo
  rv64XTheadCondMov* = rvXTheadCondMov
  rv64XTheadFMemIdx* = rvXTheadFMemIdx
  rv64XTheadFmv* = rvXTheadFmv
  rv64XTheadInt* = rvXTheadInt
  rv64XTheadMac* = rvXTheadMac
  rv64XTheadMemIdx* = rvXTheadMemIdx
  rv64XTheadMemPair* = rvXTheadMemPair
  rv64XTheadSync* = rvXTheadSync
  rv64XTheadVdot* = rvXTheadVdot
  rv64XTheadVector* = rvXTheadVector

  rv32XTheadCmo* = rvXTheadCmo
  rv32XTheadInt* = rvXTheadInt

  rvCommonScalarExts = {rvExtM, rvExtA, rvExtF, rvExtD, rvExtC,
                        rvExtZicsr, rvExtZifencei, rvExtZba, rvExtZbb,
                        rvExtZbs}

  rv32GenericTarget* = RvTarget(xlen: rv32, features: {rvExtM})
  rv64GenericTarget* = RvTarget(xlen: rv64, features: {rvExtM})
  rv32CommonTarget* = RvTarget(xlen: rv32, features: rvCommonScalarExts)
  rv64CommonTarget* = RvTarget(xlen: rv64, features: rvCommonScalarExts)
  rv64BL808D0Target* = RvTarget(xlen: rv64, features: {
    rvExtM, rvExtA, rvExtF, rvExtC, rvExtV, rvExtZicsr, rvExtZifencei,
    rvXTheadBa, rvXTheadBb, rvXTheadBs, rvXTheadCmo, rvXTheadCondMov,
    rvXTheadFMemIdx, rvXTheadFmv, rvXTheadInt, rvXTheadMac,
    rvXTheadMemIdx, rvXTheadMemPair, rvXTheadSync, rvXTheadVdot,
    rvXTheadVector
  })
  rv64TheadC906Target* = rv64BL808D0Target
  rv64BL808Target* = rv64BL808D0Target
  rv32BL808M0Target* = RvTarget(xlen: rv32, features: {
    rvExtM, rvExtA, rvExtF, rvExtC, rvExtP, rvExtZicsr, rvExtZifencei,
    rvXTheadCmo, rvXTheadInt
  })
  rv32TheadE907Target* = rv32BL808M0Target
  rv32BL808LPTarget* = RvTarget(xlen: rv32, features: {
    rvExtE, rvExtM, rvExtC, rvExtZicsr, rvExtZifencei
  })
  rv32TheadE902Target* = rv32BL808LPTarget

proc `==`*(a, b: RvReg): bool {.borrow.}

proc hasFeature*(target: RvTarget, feature: RvFeature): bool {.inline.} =
  feature in target.features

proc supportsNativeRv32Jit*(target: RvTarget): bool {.inline.} =
  target.xlen == rv32

proc supportsNativeRv64Jit*(target: RvTarget): bool {.inline.} =
  target.xlen == rv64

proc supportsNativeJit*(target: RvTarget): bool {.inline.} =
  case target.xlen
  of rv32: target.supportsNativeRv32Jit
  of rv64: target.supportsNativeRv64Jit

proc bl808Target*(core: Bl808Core): RvTarget =
  case core
  of bl808D0: rv64BL808D0Target
  of bl808M0: rv32BL808M0Target
  of bl808LP: rv32BL808LPTarget

proc initRv64AsmBuffer*(cap: int = 256): Rv64AsmBuffer =
  result.code = newSeqOfCap[uint32](cap)

proc initRv32AsmBuffer*(cap: int = 256): Rv32AsmBuffer =
  result.code = newSeqOfCap[uint32](cap)

proc emit*(buf: var Rv64AsmBuffer, inst: uint32) {.inline.} =
  buf.code.add(inst)

proc len*(buf: Rv64AsmBuffer): int = buf.code.len
proc pos*(buf: Rv64AsmBuffer): int = buf.code.len

proc patchAt*(buf: var Rv64AsmBuffer, idx: int, inst: uint32) =
  buf.code[idx] = inst

proc r(r: RvReg): uint32 {.inline.} = r.uint8.uint32

proc encR(funct7: uint32, rs2, rs1: RvReg, funct3: uint32, rd: RvReg,
          opcode: uint32): uint32 {.inline.} =
  (funct7 shl 25) or (r(rs2) shl 20) or (r(rs1) shl 15) or
    (funct3 shl 12) or (r(rd) shl 7) or opcode

proc encV(funct6: uint32, vm: bool, vs2, rs1: RvReg, funct3: uint32,
          vd: RvReg): uint32 {.inline.} =
  (funct6 shl 26) or ((if vm: 1'u32 else: 0'u32) shl 25) or
    (r(vs2) shl 20) or (r(rs1) shl 15) or (funct3 shl 12) or
    (r(vd) shl 7) or 0x57'u32

proc encI(imm: int32, rs1: RvReg, funct3: uint32, rd: RvReg,
          opcode: uint32): uint32 {.inline.} =
  ((imm.uint32 and 0xFFF) shl 20) or (r(rs1) shl 15) or
    (funct3 shl 12) or (r(rd) shl 7) or opcode

proc encS(imm: int32, rs2, rs1: RvReg, funct3: uint32,
          opcode: uint32): uint32 {.inline.} =
  let u = imm.uint32 and 0xFFF
  ((u shr 5) shl 25) or (r(rs2) shl 20) or (r(rs1) shl 15) or
    (funct3 shl 12) or ((u and 0x1F) shl 7) or opcode

proc encBBytes(offsetBytes: int32, rs2, rs1: RvReg, funct3: uint32): uint32 =
  let u = offsetBytes.uint32 and 0x1FFF
  ((u shr 12) shl 31) or (((u shr 5) and 0x3F) shl 25) or
    (r(rs2) shl 20) or (r(rs1) shl 15) or (funct3 shl 12) or
    (((u shr 1) and 0xF) shl 8) or (((u shr 11) and 0x1) shl 7) or 0x63'u32

proc encJBytes(offsetBytes: int32, rd: RvReg): uint32 =
  let u = offsetBytes.uint32 and 0x1FFFFF
  ((u shr 20) shl 31) or (((u shr 1) and 0x3FF) shl 21) or
    (((u shr 11) and 0x1) shl 20) or (((u shr 12) and 0xFF) shl 12) or
    (r(rd) shl 7) or 0x6F'u32

proc branchFunct3(cond: RvCond): uint32 =
  case cond
  of rvEq: 0b000'u32
  of rvNe: 0b001'u32
  of rvLt: 0b100'u32
  of rvGe: 0b101'u32
  of rvLtu: 0b110'u32
  of rvGeu: 0b111'u32

proc patchBranchAt*(buf: var Rv64AsmBuffer, idx: int, offsetInsts: int32) =
  let keep = buf.code[idx] and 0x01FFF07F'u32
  let imm = encBBytes(offsetInsts * 4, zero, zero, 0) and not 0x01FFF07F'u32
  buf.code[idx] = keep or imm

proc patchJalAt*(buf: var Rv64AsmBuffer, idx: int, offsetInsts: int32) =
  let keep = buf.code[idx] and 0xFFF'u32
  let imm = encJBytes(offsetInsts * 4, zero) and not 0xFFF'u32
  buf.code[idx] = keep or imm

# ---- Integer and control instructions ----

proc add*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x00, rs2, rs1, 0x0, rd, 0x33))

proc sub*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x20, rs2, rs1, 0x0, rd, 0x33))

proc mul*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x01, rs2, rs1, 0x0, rd, 0x33))

proc mulhu*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x01, rs2, rs1, 0x3, rd, 0x33))

proc divs*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x01, rs2, rs1, 0x4, rd, 0x33))

proc divu*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x01, rs2, rs1, 0x5, rd, 0x33))

proc rems*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x01, rs2, rs1, 0x6, rd, 0x33))

proc remu*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x01, rs2, rs1, 0x7, rd, 0x33))

proc addw*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x00, rs2, rs1, 0x0, rd, 0x3B))

proc subw*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x20, rs2, rs1, 0x0, rd, 0x3B))

proc mulw*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x01, rs2, rs1, 0x0, rd, 0x3B))

proc divw*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x01, rs2, rs1, 0x4, rd, 0x3B))

proc divuw*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x01, rs2, rs1, 0x5, rd, 0x3B))

proc remw*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x01, rs2, rs1, 0x6, rd, 0x3B))

proc remuw*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x01, rs2, rs1, 0x7, rd, 0x3B))

proc andr*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x00, rs2, rs1, 0x7, rd, 0x33))

proc orr*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x00, rs2, rs1, 0x6, rd, 0x33))

proc xorr*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x00, rs2, rs1, 0x4, rd, 0x33))

proc sll*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x00, rs2, rs1, 0x1, rd, 0x33))

proc srl*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x00, rs2, rs1, 0x5, rd, 0x33))

proc sra*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x20, rs2, rs1, 0x5, rd, 0x33))

proc sllw*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x00, rs2, rs1, 0x1, rd, 0x3B))

proc srlw*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x00, rs2, rs1, 0x5, rd, 0x3B))

proc sraw*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x20, rs2, rs1, 0x5, rd, 0x3B))

proc slt*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x00, rs2, rs1, 0x2, rd, 0x33))

proc sltu*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x00, rs2, rs1, 0x3, rd, 0x33))

proc addi*(buf: var Rv64AsmBuffer, rd, rs1: RvReg, imm: int32) =
  buf.emit(encI(imm, rs1, 0x0, rd, 0x13))

proc addiw*(buf: var Rv64AsmBuffer, rd, rs1: RvReg, imm: int32) =
  buf.emit(encI(imm, rs1, 0x0, rd, 0x1B))

proc andi*(buf: var Rv64AsmBuffer, rd, rs1: RvReg, imm: int32) =
  buf.emit(encI(imm, rs1, 0x7, rd, 0x13))

proc ori*(buf: var Rv64AsmBuffer, rd, rs1: RvReg, imm: int32) =
  buf.emit(encI(imm, rs1, 0x6, rd, 0x13))

proc xori*(buf: var Rv64AsmBuffer, rd, rs1: RvReg, imm: int32) =
  buf.emit(encI(imm, rs1, 0x4, rd, 0x13))

proc sltiu*(buf: var Rv64AsmBuffer, rd, rs1: RvReg, imm: int32) =
  buf.emit(encI(imm, rs1, 0x3, rd, 0x13))

proc slli*(buf: var Rv64AsmBuffer, rd, rs1: RvReg, shamt: int) =
  buf.emit(((shamt.uint32 and 0x3F) shl 20) or (r(rs1) shl 15) or
    (0x1'u32 shl 12) or (r(rd) shl 7) or 0x13'u32)

proc srli*(buf: var Rv64AsmBuffer, rd, rs1: RvReg, shamt: int) =
  buf.emit(((shamt.uint32 and 0x3F) shl 20) or (r(rs1) shl 15) or
    (0x5'u32 shl 12) or (r(rd) shl 7) or 0x13'u32)

proc srai*(buf: var Rv64AsmBuffer, rd, rs1: RvReg, shamt: int) =
  buf.emit((0x20'u32 shl 25) or ((shamt.uint32 and 0x3F) shl 20) or
    (r(rs1) shl 15) or (0x5'u32 shl 12) or (r(rd) shl 7) or 0x13'u32)

proc lui*(buf: var Rv64AsmBuffer, rd: RvReg, imm20: uint32) =
  buf.emit((imm20 shl 12) or (r(rd) shl 7) or 0x37'u32)

proc mv*(buf: var Rv64AsmBuffer, rd, rs: RvReg) =
  if rd != rs:
    buf.addi(rd, rs, 0)

proc seqz*(buf: var Rv64AsmBuffer, rd, rs: RvReg) =
  buf.sltiu(rd, rs, 1)

proc snez*(buf: var Rv64AsmBuffer, rd, rs: RvReg) =
  buf.sltu(rd, zero, rs)

proc zextW*(buf: var Rv64AsmBuffer, rd, rs: RvReg) =
  buf.slli(rd, rs, 32)
  buf.srli(rd, rd, 32)

proc sextW*(buf: var Rv64AsmBuffer, rd, rs: RvReg) =
  buf.addiw(rd, rs, 0)

proc loadImm64*(buf: var Rv64AsmBuffer, rd: RvReg, value: uint64) =
  if value == 0:
    buf.addi(rd, zero, 0)
    return
  if value <= 2047'u64:
    buf.addi(rd, zero, value.int32)
    return
  var started = false
  for shift in countdown(56, 0, 8):
    let b = ((value shr shift) and 0xFF).int32
    if not started:
      if b == 0 and shift > 0:
        continue
      buf.addi(rd, zero, b)
      started = true
    else:
      buf.slli(rd, rd, 8)
      if b != 0:
        buf.ori(rd, rd, b)

proc loadImm*(buf: var Rv64AsmBuffer, rd: RvReg, value: int64) =
  buf.loadImm64(rd, cast[uint64](value))

proc loadImm32*(buf: var Rv64AsmBuffer, rd: RvReg, value: int32, zeroExtend = true) =
  buf.loadImm64(rd, cast[uint32](value).uint64)
  if zeroExtend:
    buf.zextW(rd, rd)
  else:
    buf.sextW(rd, rd)

proc loadImm32Native*(buf: var Rv64AsmBuffer, rd: RvReg, value: int32) =
  ## Load a 32-bit bit pattern using only RV32-legal integer instructions.
  buf.loadImm64(rd, cast[uint32](value).uint64)

# ---- Loads and stores ----

proc load*(buf: var Rv64AsmBuffer, rd, base: RvReg, imm: int32, funct3: uint32) =
  buf.emit(encI(imm, base, funct3, rd, 0x03))

proc store*(buf: var Rv64AsmBuffer, rs, base: RvReg, imm: int32, funct3: uint32) =
  buf.emit(encS(imm, rs, base, funct3, 0x23))

proc lb*(buf: var Rv64AsmBuffer, rd, base: RvReg, imm: int32) = buf.load(rd, base, imm, 0x0)
proc lh*(buf: var Rv64AsmBuffer, rd, base: RvReg, imm: int32) = buf.load(rd, base, imm, 0x1)
proc lw*(buf: var Rv64AsmBuffer, rd, base: RvReg, imm: int32) = buf.load(rd, base, imm, 0x2)
proc ld*(buf: var Rv64AsmBuffer, rd, base: RvReg, imm: int32) = buf.load(rd, base, imm, 0x3)
proc lbu*(buf: var Rv64AsmBuffer, rd, base: RvReg, imm: int32) = buf.load(rd, base, imm, 0x4)
proc lhu*(buf: var Rv64AsmBuffer, rd, base: RvReg, imm: int32) = buf.load(rd, base, imm, 0x5)
proc lwu*(buf: var Rv64AsmBuffer, rd, base: RvReg, imm: int32) = buf.load(rd, base, imm, 0x6)
proc sb*(buf: var Rv64AsmBuffer, rs, base: RvReg, imm: int32) = buf.store(rs, base, imm, 0x0)
proc sh*(buf: var Rv64AsmBuffer, rs, base: RvReg, imm: int32) = buf.store(rs, base, imm, 0x1)
proc sw*(buf: var Rv64AsmBuffer, rs, base: RvReg, imm: int32) = buf.store(rs, base, imm, 0x2)
proc sd*(buf: var Rv64AsmBuffer, rs, base: RvReg, imm: int32) = buf.store(rs, base, imm, 0x3)

proc branch*(buf: var Rv64AsmBuffer, cond: RvCond, rs1, rs2: RvReg,
             offsetInsts: int32) =
  buf.emit(encBBytes(offsetInsts * 4, rs2, rs1, branchFunct3(cond)))

proc beq*(buf: var Rv64AsmBuffer, rs1, rs2: RvReg, offsetInsts: int32) =
  buf.branch(rvEq, rs1, rs2, offsetInsts)

proc bne*(buf: var Rv64AsmBuffer, rs1, rs2: RvReg, offsetInsts: int32) =
  buf.branch(rvNe, rs1, rs2, offsetInsts)

proc blt*(buf: var Rv64AsmBuffer, rs1, rs2: RvReg, offsetInsts: int32) =
  buf.branch(rvLt, rs1, rs2, offsetInsts)

proc bge*(buf: var Rv64AsmBuffer, rs1, rs2: RvReg, offsetInsts: int32) =
  buf.branch(rvGe, rs1, rs2, offsetInsts)

proc bltu*(buf: var Rv64AsmBuffer, rs1, rs2: RvReg, offsetInsts: int32) =
  buf.branch(rvLtu, rs1, rs2, offsetInsts)

proc bgeu*(buf: var Rv64AsmBuffer, rs1, rs2: RvReg, offsetInsts: int32) =
  buf.branch(rvGeu, rs1, rs2, offsetInsts)

proc jal*(buf: var Rv64AsmBuffer, rd: RvReg, offsetInsts: int32) =
  buf.emit(encJBytes(offsetInsts * 4, rd))

proc j*(buf: var Rv64AsmBuffer, offsetInsts: int32) =
  buf.jal(zero, offsetInsts)

proc jalr*(buf: var Rv64AsmBuffer, rd, rs1: RvReg, imm: int32 = 0) =
  buf.emit(encI(imm, rs1, 0x0, rd, 0x67))

proc ret*(buf: var Rv64AsmBuffer) =
  buf.jalr(zero, ra, 0)

proc nop*(buf: var Rv64AsmBuffer) =
  buf.addi(zero, zero, 0)

proc ebreak*(buf: var Rv64AsmBuffer) =
  buf.emit(0x00100073'u32)

# ---- Standard bit-manipulation extension encoders (Zba/Zbb/Zbs) ----

proc sh1add*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x10, rs2, rs1, 0x2, rd, 0x33))

proc sh2add*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x10, rs2, rs1, 0x4, rd, 0x33))

proc sh3add*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x10, rs2, rs1, 0x6, rd, 0x33))

proc addUw*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  ## RV64 Zba: rd = rs2 + zeroExtend32(rs1).
  buf.emit(encR(0x04, rs2, rs1, 0x0, rd, 0x3B))

proc sh1addUw*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  ## RV64 Zba: rd = rs2 + (zeroExtend32(rs1) << 1).
  buf.emit(encR(0x10, rs2, rs1, 0x2, rd, 0x3B))

proc sh2addUw*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  ## RV64 Zba: rd = rs2 + (zeroExtend32(rs1) << 2).
  buf.emit(encR(0x10, rs2, rs1, 0x4, rd, 0x3B))

proc sh3addUw*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  ## RV64 Zba: rd = rs2 + (zeroExtend32(rs1) << 3).
  buf.emit(encR(0x10, rs2, rs1, 0x6, rd, 0x3B))

proc slliUw*(buf: var Rv64AsmBuffer, rd, rs1: RvReg, shamt: int) =
  ## RV64 Zba: rd = zeroExtend32(rs1) << shamt.
  buf.emit((0x02'u32 shl 26) or ((shamt.uint32 and 0x3F) shl 20) or
    (r(rs1) shl 15) or (0x1'u32 shl 12) or (r(rd) shl 7) or 0x1B'u32)

proc andn*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x20, rs2, rs1, 0x7, rd, 0x33))

proc orn*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x20, rs2, rs1, 0x6, rd, 0x33))

proc xnor*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x20, rs2, rs1, 0x4, rd, 0x33))

proc clz*(buf: var Rv64AsmBuffer, rd, rs1: RvReg) =
  buf.emit(encI(0x600, rs1, 0x1, rd, 0x13))

proc ctz*(buf: var Rv64AsmBuffer, rd, rs1: RvReg) =
  buf.emit(encI(0x601, rs1, 0x1, rd, 0x13))

proc cpop*(buf: var Rv64AsmBuffer, rd, rs1: RvReg) =
  buf.emit(encI(0x602, rs1, 0x1, rd, 0x13))

proc clzw*(buf: var Rv64AsmBuffer, rd, rs1: RvReg) =
  buf.emit(encI(0x600, rs1, 0x1, rd, 0x1B))

proc ctzw*(buf: var Rv64AsmBuffer, rd, rs1: RvReg) =
  buf.emit(encI(0x601, rs1, 0x1, rd, 0x1B))

proc cpopw*(buf: var Rv64AsmBuffer, rd, rs1: RvReg) =
  buf.emit(encI(0x602, rs1, 0x1, rd, 0x1B))

proc sextB*(buf: var Rv64AsmBuffer, rd, rs1: RvReg) =
  buf.emit(encI(0x604, rs1, 0x1, rd, 0x13))

proc sextH*(buf: var Rv64AsmBuffer, rd, rs1: RvReg) =
  buf.emit(encI(0x605, rs1, 0x1, rd, 0x13))

proc rol*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x30, rs2, rs1, 0x1, rd, 0x33))

proc ror*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x30, rs2, rs1, 0x5, rd, 0x33))

proc rolw*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x30, rs2, rs1, 0x1, rd, 0x3B))

proc rorw*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x30, rs2, rs1, 0x5, rd, 0x3B))

proc maxr*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x05, rs2, rs1, 0x6, rd, 0x33))

proc maxu*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x05, rs2, rs1, 0x7, rd, 0x33))

proc minr*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x05, rs2, rs1, 0x4, rd, 0x33))

proc minu*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x05, rs2, rs1, 0x5, rd, 0x33))

proc bclr*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x24, rs2, rs1, 0x1, rd, 0x33))

proc bext*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x24, rs2, rs1, 0x5, rd, 0x33))

proc binv*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x34, rs2, rs1, 0x1, rd, 0x33))

proc bset*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  buf.emit(encR(0x14, rs2, rs1, 0x1, rd, 0x33))

# ---- Single-precision floating-point instructions ----

proc encFp(funct7: uint32, rs2, rs1: RvReg, rm: uint32, rd: RvReg): uint32 {.inline.} =
  encR(funct7, rs2, rs1, rm, rd, 0x53)

proc encFp4(rs3: RvReg, fmt: uint32, rs2, rs1: RvReg, rm: uint32,
            rd: RvReg, opcode: uint32): uint32 {.inline.} =
  (r(rs3) shl 27) or ((fmt and 0x3) shl 25) or (r(rs2) shl 20) or
    (r(rs1) shl 15) or (rm shl 12) or (r(rd) shl 7) or opcode

proc fmvWX*(buf: var Rv64AsmBuffer, fd, rs1: RvReg) =
  ## fmv.w.x fd, rs1
  buf.emit(encFp(0x78, zero, rs1, 0x0, fd))

proc fmvXW*(buf: var Rv64AsmBuffer, rd, fs1: RvReg) =
  ## fmv.x.w rd, fs1
  buf.emit(encFp(0x70, zero, fs1, 0x0, rd))

proc faddS*(buf: var Rv64AsmBuffer, fd, fs1, fs2: RvReg) =
  buf.emit(encFp(0x00, fs2, fs1, 0x0, fd))

proc fsubS*(buf: var Rv64AsmBuffer, fd, fs1, fs2: RvReg) =
  buf.emit(encFp(0x04, fs2, fs1, 0x0, fd))

proc fmulS*(buf: var Rv64AsmBuffer, fd, fs1, fs2: RvReg) =
  buf.emit(encFp(0x08, fs2, fs1, 0x0, fd))

proc fdivS*(buf: var Rv64AsmBuffer, fd, fs1, fs2: RvReg) =
  buf.emit(encFp(0x0C, fs2, fs1, 0x0, fd))

proc fsqrtS*(buf: var Rv64AsmBuffer, fd, fs1: RvReg) =
  buf.emit(encFp(0x2C, zero, fs1, 0x0, fd))

proc fminS*(buf: var Rv64AsmBuffer, fd, fs1, fs2: RvReg) =
  buf.emit(encFp(0x14, fs2, fs1, 0x0, fd))

proc fmaxS*(buf: var Rv64AsmBuffer, fd, fs1, fs2: RvReg) =
  buf.emit(encFp(0x14, fs2, fs1, 0x1, fd))

proc fmaddS*(buf: var Rv64AsmBuffer, fd, fs1, fs2, fs3: RvReg) =
  buf.emit(encFp4(fs3, 0x0, fs2, fs1, 0x0, fd, 0x43))

proc feqS*(buf: var Rv64AsmBuffer, rd, fs1, fs2: RvReg) =
  buf.emit(encFp(0x50, fs2, fs1, 0x2, rd))

proc fltS*(buf: var Rv64AsmBuffer, rd, fs1, fs2: RvReg) =
  buf.emit(encFp(0x50, fs2, fs1, 0x1, rd))

proc fleS*(buf: var Rv64AsmBuffer, rd, fs1, fs2: RvReg) =
  buf.emit(encFp(0x50, fs2, fs1, 0x0, rd))

proc fcvtSW*(buf: var Rv64AsmBuffer, fd, rs1: RvReg, unsigned = false) =
  buf.emit(encFp(0x68, RvReg(if unsigned: 1 else: 0), rs1, 0x0, fd))

proc fcvtSL*(buf: var Rv64AsmBuffer, fd, rs1: RvReg, unsigned = false) =
  buf.emit(encFp(0x68, RvReg(if unsigned: 3 else: 2), rs1, 0x0, fd))

proc fcvtWS*(buf: var Rv64AsmBuffer, rd, fs1: RvReg, unsigned = false) =
  buf.emit(encFp(0x60, RvReg(if unsigned: 1 else: 0), fs1, 0x1, rd))

proc fcvtLS*(buf: var Rv64AsmBuffer, rd, fs1: RvReg, unsigned = false) =
  buf.emit(encFp(0x60, RvReg(if unsigned: 3 else: 2), fs1, 0x1, rd))

# ---- Double-precision floating-point instructions ----

proc fmvDX*(buf: var Rv64AsmBuffer, fd, rs1: RvReg) =
  ## fmv.d.x fd, rs1
  buf.emit(encFp(0x79, zero, rs1, 0x0, fd))

proc fmvXD*(buf: var Rv64AsmBuffer, rd, fs1: RvReg) =
  ## fmv.x.d rd, fs1
  buf.emit(encFp(0x71, zero, fs1, 0x0, rd))

proc faddD*(buf: var Rv64AsmBuffer, fd, fs1, fs2: RvReg) =
  buf.emit(encFp(0x01, fs2, fs1, 0x0, fd))

proc fsubD*(buf: var Rv64AsmBuffer, fd, fs1, fs2: RvReg) =
  buf.emit(encFp(0x05, fs2, fs1, 0x0, fd))

proc fmulD*(buf: var Rv64AsmBuffer, fd, fs1, fs2: RvReg) =
  buf.emit(encFp(0x09, fs2, fs1, 0x0, fd))

proc fdivD*(buf: var Rv64AsmBuffer, fd, fs1, fs2: RvReg) =
  buf.emit(encFp(0x0D, fs2, fs1, 0x0, fd))

proc fsqrtD*(buf: var Rv64AsmBuffer, fd, fs1: RvReg) =
  buf.emit(encFp(0x2D, zero, fs1, 0x0, fd))

proc fminD*(buf: var Rv64AsmBuffer, fd, fs1, fs2: RvReg) =
  buf.emit(encFp(0x15, fs2, fs1, 0x0, fd))

proc fmaxD*(buf: var Rv64AsmBuffer, fd, fs1, fs2: RvReg) =
  buf.emit(encFp(0x15, fs2, fs1, 0x1, fd))

proc fmaddD*(buf: var Rv64AsmBuffer, fd, fs1, fs2, fs3: RvReg) =
  buf.emit(encFp4(fs3, 0x1, fs2, fs1, 0x0, fd, 0x43))

proc feqD*(buf: var Rv64AsmBuffer, rd, fs1, fs2: RvReg) =
  buf.emit(encFp(0x51, fs2, fs1, 0x2, rd))

proc fltD*(buf: var Rv64AsmBuffer, rd, fs1, fs2: RvReg) =
  buf.emit(encFp(0x51, fs2, fs1, 0x1, rd))

proc fleD*(buf: var Rv64AsmBuffer, rd, fs1, fs2: RvReg) =
  buf.emit(encFp(0x51, fs2, fs1, 0x0, rd))

proc fcvtDW*(buf: var Rv64AsmBuffer, fd, rs1: RvReg, unsigned = false) =
  buf.emit(encFp(0x69, RvReg(if unsigned: 1 else: 0), rs1, 0x0, fd))

proc fcvtDL*(buf: var Rv64AsmBuffer, fd, rs1: RvReg, unsigned = false) =
  buf.emit(encFp(0x69, RvReg(if unsigned: 3 else: 2), rs1, 0x0, fd))

proc fcvtWD*(buf: var Rv64AsmBuffer, rd, fs1: RvReg, unsigned = false) =
  buf.emit(encFp(0x61, RvReg(if unsigned: 1 else: 0), fs1, 0x1, rd))

proc fcvtLD*(buf: var Rv64AsmBuffer, rd, fs1: RvReg, unsigned = false) =
  buf.emit(encFp(0x61, RvReg(if unsigned: 3 else: 2), fs1, 0x1, rd))

proc fcvtSD*(buf: var Rv64AsmBuffer, fd, fs1: RvReg) =
  buf.emit(encFp(0x20, RvReg(1), fs1, 0x0, fd))

proc fcvtDS*(buf: var Rv64AsmBuffer, fd, fs1: RvReg) =
  buf.emit(encFp(0x21, zero, fs1, 0x0, fd))

# ---- RISC-V Vector extension encoders (RVV / T-Head vector cores) ----

proc rvvVtype(sewBits: int): uint32 =
  let vsew = case sewBits
    of 8: 0'u32
    of 16: 1'u32
    of 32: 2'u32
    of 64: 3'u32
    else: 0'u32
  (1'u32 shl 7) or (1'u32 shl 6) or (vsew shl 3) # ta, ma, LMUL=m1

proc vsetvli*(buf: var Rv64AsmBuffer, rd, rs1: RvReg, sewBits: int) =
  buf.emit(((rvvVtype(sewBits) and 0x7FF'u32) shl 20) or
    (r(rs1) shl 15) or (0x7'u32 shl 12) or (r(rd) shl 7) or 0x57'u32)

proc rvv07Vtype(sewBits: int): uint32 =
  let vsew = case sewBits
    of 8: 0'u32
    of 16: 1'u32
    of 32: 2'u32
    of 64: 3'u32
    else: 0'u32
  vsew shl 3 # RVV 0.7/T-Head C906 layout, LMUL=m1

proc vsetvliTHead07*(buf: var Rv64AsmBuffer, rd, rs1: RvReg, sewBits: int) =
  buf.emit(((rvv07Vtype(sewBits) and 0x7FF'u32) shl 20) or
    (r(rs1) shl 15) or (0x7'u32 shl 12) or (r(rd) shl 7) or 0x57'u32)

proc vle8V*(buf: var Rv64AsmBuffer, vd, base: RvReg) =
  buf.emit((1'u32 shl 25) or (r(base) shl 15) or (r(vd) shl 7) or 0x07'u32)

proc vse8V*(buf: var Rv64AsmBuffer, vs3, base: RvReg) =
  buf.emit((1'u32 shl 25) or (r(base) shl 15) or (r(vs3) shl 7) or 0x27'u32)

proc vmvVx*(buf: var Rv64AsmBuffer, vd, rs1: RvReg) =
  ## vmv.v.x vd, rs1
  buf.emit(encV(0x17, true, zero, rs1, 0x4, vd))

proc vmvXs*(buf: var Rv64AsmBuffer, rd, vs2: RvReg) =
  ## vmv.x.s rd, vs2
  buf.emit(encV(0x10, true, vs2, zero, 0x2, rd))

proc vmvSx*(buf: var Rv64AsmBuffer, vd, rs1: RvReg) =
  ## vmv.s.x vd, rs1
  buf.emit(encV(0x10, true, zero, rs1, 0x6, vd))

proc vaddVv*(buf: var Rv64AsmBuffer, vd, vs2, vs1: RvReg) =
  buf.emit(encV(0x00, true, vs2, vs1, 0x0, vd))

proc vsubVv*(buf: var Rv64AsmBuffer, vd, vs2, vs1: RvReg) =
  buf.emit(encV(0x02, true, vs2, vs1, 0x0, vd))

proc vrsubVx*(buf: var Rv64AsmBuffer, vd, vs2, rs1: RvReg) =
  buf.emit(encV(0x03, true, vs2, rs1, 0x4, vd))

proc vmulVv*(buf: var Rv64AsmBuffer, vd, vs2, vs1: RvReg) =
  buf.emit(encV(0x25, true, vs2, vs1, 0x2, vd))

proc vandVv*(buf: var Rv64AsmBuffer, vd, vs2, vs1: RvReg) =
  buf.emit(encV(0x09, true, vs2, vs1, 0x0, vd))

proc vorVv*(buf: var Rv64AsmBuffer, vd, vs2, vs1: RvReg) =
  buf.emit(encV(0x0A, true, vs2, vs1, 0x0, vd))

proc vxorVv*(buf: var Rv64AsmBuffer, vd, vs2, vs1: RvReg) =
  buf.emit(encV(0x0B, true, vs2, vs1, 0x0, vd))

proc vxorVi*(buf: var Rv64AsmBuffer, vd, vs2: RvReg, imm5: int) =
  buf.emit(encV(0x0B, true, vs2, RvReg((imm5 and 0x1F).uint8), 0x3, vd))

proc vminVv*(buf: var Rv64AsmBuffer, vd, vs2, vs1: RvReg) =
  buf.emit(encV(0x05, true, vs2, vs1, 0x0, vd))

proc vminuVv*(buf: var Rv64AsmBuffer, vd, vs2, vs1: RvReg) =
  buf.emit(encV(0x04, true, vs2, vs1, 0x0, vd))

proc vmaxVv*(buf: var Rv64AsmBuffer, vd, vs2, vs1: RvReg) =
  buf.emit(encV(0x07, true, vs2, vs1, 0x0, vd))

proc vmaxuVv*(buf: var Rv64AsmBuffer, vd, vs2, vs1: RvReg) =
  buf.emit(encV(0x06, true, vs2, vs1, 0x0, vd))

proc vsllVx*(buf: var Rv64AsmBuffer, vd, vs2, rs1: RvReg) =
  buf.emit(encV(0x25, true, vs2, rs1, 0x4, vd))

proc vsrlVx*(buf: var Rv64AsmBuffer, vd, vs2, rs1: RvReg) =
  buf.emit(encV(0x28, true, vs2, rs1, 0x4, vd))

proc vsraVx*(buf: var Rv64AsmBuffer, vd, vs2, rs1: RvReg) =
  buf.emit(encV(0x29, true, vs2, rs1, 0x4, vd))

proc vmsltVx*(buf: var Rv64AsmBuffer, vd, vs2, rs1: RvReg) =
  buf.emit(encV(0x1B, true, vs2, rs1, 0x4, vd))

proc vmergeVvm*(buf: var Rv64AsmBuffer, vd, vs2, vs1: RvReg) =
  ## vmerge.vvm uses v0 as the implicit mask and encodes vm=0.
  buf.emit(encV(0x17, false, vs2, vs1, 0x0, vd))

proc vfaddVv*(buf: var Rv64AsmBuffer, vd, vs2, vs1: RvReg) =
  buf.emit(encV(0x00, true, vs2, vs1, 0x1, vd))

proc vfsubVv*(buf: var Rv64AsmBuffer, vd, vs2, vs1: RvReg) =
  buf.emit(encV(0x02, true, vs2, vs1, 0x1, vd))

proc vfmulVv*(buf: var Rv64AsmBuffer, vd, vs2, vs1: RvReg) =
  buf.emit(encV(0x24, true, vs2, vs1, 0x1, vd))

proc vfdivVv*(buf: var Rv64AsmBuffer, vd, vs2, vs1: RvReg) =
  buf.emit(encV(0x20, true, vs2, vs1, 0x1, vd))

proc vfsgnjxVv*(buf: var Rv64AsmBuffer, vd, vs2, vs1: RvReg) =
  buf.emit(encV(0x0A, true, vs2, vs1, 0x1, vd))

proc vfsgnjnVv*(buf: var Rv64AsmBuffer, vd, vs2, vs1: RvReg) =
  buf.emit(encV(0x09, true, vs2, vs1, 0x1, vd))

# ---- T-Head vendor extension encoders ----

proc thAddsl*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg, imm2: uint32) =
  ## th.addsl rd, rs1, rs2, imm2: rd = rs1 + (rs2 << imm2)
  buf.emit(((imm2 and 0x3) shl 25) or (r(rs2) shl 20) or (r(rs1) shl 15) or
    (0x1'u32 shl 12) or (r(rd) shl 7) or 0x0B'u32)

proc thMveqz*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  ## th.mveqz rd, rs1, rs2: if rs2 == 0, rd = rs1
  buf.emit((0x08'u32 shl 27) or (r(rs2) shl 20) or (r(rs1) shl 15) or
    (0x1'u32 shl 12) or (r(rd) shl 7) or 0x0B'u32)

proc thMvnez*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  ## th.mvnez rd, rs1, rs2: if rs2 != 0, rd = rs1
  buf.emit((0x08'u32 shl 27) or (0x1'u32 shl 25) or (r(rs2) shl 20) or
    (r(rs1) shl 15) or (0x1'u32 shl 12) or (r(rd) shl 7) or 0x0B'u32)

proc thMula*(buf: var Rv64AsmBuffer, rd, rs1, rs2: RvReg) =
  ## th.mula rd, rs1, rs2: rd += rs1 * rs2
  buf.emit((0x04'u32 shl 27) or (r(rs2) shl 20) or (r(rs1) shl 15) or
    (0x1'u32 shl 12) or (r(rd) shl 7) or 0x0B'u32)

proc thSdd*(buf: var Rv64AsmBuffer, rd1, rd2, rs1: RvReg, imm2: uint32) =
  ## th.sdd rd1, rd2, (rs1), imm2, 4: store rd1/rd2 at rs1 + imm2<<4
  buf.emit((0x1F'u32 shl 27) or ((imm2 and 0x3) shl 25) or
    (r(rd2) shl 20) or (r(rs1) shl 15) or (0x5'u32 shl 12) or
    (r(rd1) shl 7) or 0x0B'u32)

proc thLdd*(buf: var Rv64AsmBuffer, rd1, rd2, rs1: RvReg, imm2: uint32) =
  ## th.ldd rd1, rd2, (rs1), imm2, 4: load rd1/rd2 from rs1 + imm2<<4
  buf.emit((0x1F'u32 shl 27) or ((imm2 and 0x3) shl 25) or
    (r(rd2) shl 20) or (r(rs1) shl 15) or (0x4'u32 shl 12) or
    (r(rd1) shl 7) or 0x0B'u32)
