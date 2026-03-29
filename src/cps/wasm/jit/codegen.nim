## AArch64 instruction encoder
## Encodes ARM64 instructions as uint32 values

type
  Reg* = distinct uint8
  FReg* = distinct uint8  # Floating-point/SIMD register

  Cond* = enum
    condEQ = 0b0000   # Equal (Z=1)
    condNE = 0b0001   # Not equal (Z=0)
    condCS = 0b0010   # Carry set / unsigned >=
    condCC = 0b0011   # Carry clear / unsigned <
    condMI = 0b0100   # Minus / negative
    condPL = 0b0101   # Plus / positive or zero
    condVS = 0b0110   # Overflow
    condVC = 0b0111   # No overflow
    condHI = 0b1000   # Unsigned >
    condLS = 0b1001   # Unsigned <=
    condGE = 0b1010   # Signed >=
    condLT = 0b1011   # Signed <
    condGT = 0b1100   # Signed >
    condLE = 0b1101   # Signed <=
    condAL = 0b1110   # Always

  Shift* = enum
    shLSL = 0b00
    shLSR = 0b01
    shASR = 0b10
    shROR = 0b11

# ---- Register definitions ----
const
  x0* = Reg(0)
  x1* = Reg(1)
  x2* = Reg(2)
  x3* = Reg(3)
  x4* = Reg(4)
  x5* = Reg(5)
  x6* = Reg(6)
  x7* = Reg(7)
  x8* = Reg(8)
  x9* = Reg(9)
  x10* = Reg(10)
  x11* = Reg(11)
  x12* = Reg(12)
  x13* = Reg(13)
  x14* = Reg(14)
  x15* = Reg(15)
  x16* = Reg(16)
  x17* = Reg(17)
  # x18 reserved on macOS
  x19* = Reg(19)
  x20* = Reg(20)
  x21* = Reg(21)
  x22* = Reg(22)
  x23* = Reg(23)
  x24* = Reg(24)
  x25* = Reg(25)
  x26* = Reg(26)
  x27* = Reg(27)
  x28* = Reg(28)
  fp* = Reg(29)   # frame pointer
  lr* = Reg(30)   # link register
  xzr* = Reg(31)  # zero register (when used as source)
  sp* = Reg(31)   # stack pointer (context-dependent with xzr)

  # FP registers
  d0* = FReg(0)
  d1* = FReg(1)
  d2* = FReg(2)
  d3* = FReg(3)

  # WASM register convention
  rVSP* = x8      # Value stack pointer
  rLocals* = x9   # Locals base pointer
  rMemBase* = x10  # Linear memory base
  rMemSize* = x11  # Linear memory size
  rScratch0* = x12
  rScratch1* = x13
  rScratch2* = x14
  rScratch3* = x15

proc `==`*(a, b: Reg): bool {.borrow.}
proc `==`*(a, b: FReg): bool {.borrow.}

# ---- Code buffer ----
type
  AsmBuffer* = object
    code*: seq[uint32]

proc initAsmBuffer*(cap: int = 256): AsmBuffer =
  result.code = newSeqOfCap[uint32](cap)

proc emit*(buf: var AsmBuffer, inst: uint32) {.inline.} =
  buf.code.add(inst)

proc len*(buf: AsmBuffer): int = buf.code.len
proc pos*(buf: AsmBuffer): int = buf.code.len  # current instruction index

proc patchAt*(buf: var AsmBuffer, idx: int, inst: uint32) =
  buf.code[idx] = inst

# ---- Encoding helpers ----
proc rd(r: Reg): uint32 {.inline.} = r.uint8.uint32
proc rn(r: Reg): uint32 {.inline.} = r.uint8.uint32 shl 5
proc rm(r: Reg): uint32 {.inline.} = r.uint8.uint32 shl 16
proc rt(r: Reg): uint32 {.inline.} = r.uint8.uint32  # same as rd

# ---- Data Processing (Register) ----

proc addReg*(buf: var AsmBuffer, dst, a, b: Reg, is64: bool = true) =
  ## ADD Rd, Rn, Rm
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  buf.emit(sf or 0x0B000000'u32 or rm(b) or rn(a) or rd(dst))

proc subReg*(buf: var AsmBuffer, dst, a, b: Reg, is64: bool = true) =
  ## SUB Rd, Rn, Rm
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  buf.emit(sf or 0x4B000000'u32 or rm(b) or rn(a) or rd(dst))

proc subsReg*(buf: var AsmBuffer, dst, a, b: Reg, is64: bool = true) =
  ## SUBS Rd, Rn, Rm (sets flags)
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  buf.emit(sf or 0x6B000000'u32 or rm(b) or rn(a) or rd(dst))

proc mulReg*(buf: var AsmBuffer, dst, a, b: Reg, is64: bool = true) =
  ## MUL Rd, Rn, Rm (alias for MADD Rd, Rn, Rm, XZR)
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  buf.emit(sf or 0x1B000000'u32 or rm(b) or (xzr.uint8.uint32 shl 10) or rn(a) or rd(dst))

proc sdivReg*(buf: var AsmBuffer, dst, a, b: Reg, is64: bool = true) =
  ## SDIV Rd, Rn, Rm
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  buf.emit(sf or 0x1AC00C00'u32 or rm(b) or rn(a) or rd(dst))

proc udivReg*(buf: var AsmBuffer, dst, a, b: Reg, is64: bool = true) =
  ## UDIV Rd, Rn, Rm
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  buf.emit(sf or 0x1AC00800'u32 or rm(b) or rn(a) or rd(dst))

proc andReg*(buf: var AsmBuffer, dst, a, b: Reg, is64: bool = true) =
  ## AND Rd, Rn, Rm
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  buf.emit(sf or 0x0A000000'u32 or rm(b) or rn(a) or rd(dst))

proc orrReg*(buf: var AsmBuffer, dst, a, b: Reg, is64: bool = true) =
  ## ORR Rd, Rn, Rm
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  buf.emit(sf or 0x2A000000'u32 or rm(b) or rn(a) or rd(dst))

proc eorReg*(buf: var AsmBuffer, dst, a, b: Reg, is64: bool = true) =
  ## EOR Rd, Rn, Rm
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  buf.emit(sf or 0x4A000000'u32 or rm(b) or rn(a) or rd(dst))

proc lslReg*(buf: var AsmBuffer, dst, a, b: Reg, is64: bool = true) =
  ## LSL Rd, Rn, Rm (alias for LSLV)
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  buf.emit(sf or 0x1AC02000'u32 or rm(b) or rn(a) or rd(dst))

proc lsrReg*(buf: var AsmBuffer, dst, a, b: Reg, is64: bool = true) =
  ## LSR Rd, Rn, Rm (alias for LSRV)
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  buf.emit(sf or 0x1AC02400'u32 or rm(b) or rn(a) or rd(dst))

proc asrReg*(buf: var AsmBuffer, dst, a, b: Reg, is64: bool = true) =
  ## ASR Rd, Rn, Rm (alias for ASRV)
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  buf.emit(sf or 0x1AC02800'u32 or rm(b) or rn(a) or rd(dst))

proc rorReg*(buf: var AsmBuffer, dst, a, b: Reg, is64: bool = true) =
  ## ROR Rd, Rn, Rm (alias for RORV)
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  buf.emit(sf or 0x1AC02C00'u32 or rm(b) or rn(a) or rd(dst))

proc clzReg*(buf: var AsmBuffer, dst, src: Reg, is64: bool = true) =
  ## CLZ Rd, Rn
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  buf.emit(sf or 0x5AC01000'u32 or rn(src) or rd(dst))

proc rbitReg*(buf: var AsmBuffer, dst, src: Reg, is64: bool = true) =
  ## RBIT Rd, Rn (reverse bits — use for CTZ via RBIT+CLZ)
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  buf.emit(sf or 0x5AC00000'u32 or rn(src) or rd(dst))

# ---- Data Processing (Immediate) ----

proc addImm*(buf: var AsmBuffer, dst, src: Reg, imm12: uint32, is64: bool = true) =
  ## ADD Rd, Rn, #imm12
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  buf.emit(sf or 0x11000000'u32 or (imm12 and 0xFFF) shl 10 or rn(src) or rd(dst))

proc subImm*(buf: var AsmBuffer, dst, src: Reg, imm12: uint32, is64: bool = true) =
  ## SUB Rd, Rn, #imm12
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  buf.emit(sf or 0x51000000'u32 or (imm12 and 0xFFF) shl 10 or rn(src) or rd(dst))

proc subsImm*(buf: var AsmBuffer, dst, src: Reg, imm12: uint32, is64: bool = true) =
  ## SUBS Rd, Rn, #imm12 (sets flags)
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  buf.emit(sf or 0x71000000'u32 or (imm12 and 0xFFF) shl 10 or rn(src) or rd(dst))

proc cmpImm*(buf: var AsmBuffer, src: Reg, imm12: uint32, is64: bool = true) =
  ## CMP Rn, #imm12 (alias for SUBS XZR, Rn, #imm12)
  buf.subsImm(xzr, src, imm12, is64)

proc cmpReg*(buf: var AsmBuffer, a, b: Reg, is64: bool = true) =
  ## CMP Rn, Rm (alias for SUBS XZR, Rn, Rm)
  buf.subsReg(xzr, a, b, is64)

# ---- Move instructions ----

proc movz*(buf: var AsmBuffer, dst: Reg, imm16: uint32, shift: int = 0, is64: bool = true) =
  ## MOVZ Rd, #imm16, LSL #shift (shift = 0, 16, 32, 48)
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  let hw = (shift div 16).uint32
  buf.emit(sf or 0x52800000'u32 or (hw shl 21) or ((imm16 and 0xFFFF) shl 5) or rd(dst))

proc movk*(buf: var AsmBuffer, dst: Reg, imm16: uint32, shift: int = 0, is64: bool = true) =
  ## MOVK Rd, #imm16, LSL #shift (keep other bits)
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  let hw = (shift div 16).uint32
  buf.emit(sf or 0x72800000'u32 or (hw shl 21) or ((imm16 and 0xFFFF) shl 5) or rd(dst))

proc movn*(buf: var AsmBuffer, dst: Reg, imm16: uint32, shift: int = 0, is64: bool = true) =
  ## MOVN Rd, #imm16, LSL #shift (move NOT)
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  let hw = (shift div 16).uint32
  buf.emit(sf or 0x12800000'u32 or (hw shl 21) or ((imm16 and 0xFFFF) shl 5) or rd(dst))

proc movReg*(buf: var AsmBuffer, dst, src: Reg, is64: bool = true) =
  ## MOV Rd, Rm (alias for ORR Rd, XZR, Rm)
  buf.orrReg(dst, xzr, src, is64)

proc loadImm64*(buf: var AsmBuffer, dst: Reg, value: uint64) =
  ## Load a 64-bit immediate into a register using MOVZ + MOVK sequence
  let lo16 = (value and 0xFFFF).uint32
  let hi16 = ((value shr 16) and 0xFFFF).uint32
  let hi32 = ((value shr 32) and 0xFFFF).uint32
  let hi48 = ((value shr 48) and 0xFFFF).uint32

  buf.movz(dst, lo16, 0)
  if hi16 != 0: buf.movk(dst, hi16, 16)
  if hi32 != 0: buf.movk(dst, hi32, 32)
  if hi48 != 0: buf.movk(dst, hi48, 48)

proc loadImm32*(buf: var AsmBuffer, dst: Reg, value: int32) =
  ## Load a 32-bit immediate (may be negative)
  if value >= 0 and value < 65536:
    buf.movz(dst, value.uint32, 0, is64 = false)
  elif value < 0 and value >= -65536:
    buf.movn(dst, (not value).uint32, 0, is64 = false)
  else:
    let uval = cast[uint32](value)
    buf.movz(dst, uval and 0xFFFF, 0, is64 = false)
    if (uval shr 16) != 0:
      buf.movk(dst, (uval shr 16) and 0xFFFF, 16, is64 = false)

# ---- Load/Store ----

proc ldrImm*(buf: var AsmBuffer, dst, base: Reg, offset: int32, is64: bool = true) =
  ## LDR Rt, [Rn, #offset] (unsigned offset, scaled)
  let size = if is64: 3'u32 else: 2'u32  # 8-byte or 4-byte
  let scale = if is64: 8 else: 4
  let scaledOff = (offset div scale).uint32
  buf.emit((size shl 30) or 0x39400000'u32 or (scaledOff and 0xFFF) shl 10 or rn(base) or rt(dst))

proc ldurImm*(buf: var AsmBuffer, dst, base: Reg, offset: int32, is64: bool = true) =
  ## LDUR Rt, [Rn, #offset] (unscaled signed offset, -256..255)
  let size = if is64: 3'u32 else: 2'u32
  let simm9 = offset.uint32 and 0x1FF
  buf.emit((size shl 30) or 0x38400000'u32 or (simm9 shl 12) or rn(base) or rt(dst))

proc strImm*(buf: var AsmBuffer, src, base: Reg, offset: int32, is64: bool = true) =
  ## STR Rt, [Rn, #offset] (unsigned offset, scaled)
  let size = if is64: 3'u32 else: 2'u32
  let scale = if is64: 8 else: 4
  let scaledOff = (offset div scale).uint32
  buf.emit((size shl 30) or 0x39000000'u32 or (scaledOff and 0xFFF) shl 10 or rn(base) or rt(src))

proc ldrReg*(buf: var AsmBuffer, dst, base, offset: Reg, is64: bool = true) =
  ## LDR Rt, [Rn, Rm, LSL #log2(size)]
  ## Encoding: size:2 | 111_00_01_1 | Rm | option(011) | S(1) | 10 | Rn | Rt
  let size = if is64: 3'u32 else: 2'u32
  buf.emit((size shl 30) or 0x38606800'u32 or rm(offset) or rn(base) or rt(dst))

proc strReg*(buf: var AsmBuffer, src, base, offset: Reg, is64: bool = true) =
  ## STR Rt, [Rn, Rm, LSL #log2(size)]
  let size = if is64: 3'u32 else: 2'u32
  buf.emit((size shl 30) or 0x38206800'u32 or rm(offset) or rn(base) or rt(src))

proc ldrPostIdx*(buf: var AsmBuffer, dst, base: Reg, imm9: int32, is64: bool = true) =
  ## LDR Rt, [Rn], #imm9 (post-index: load then add offset)
  let size = if is64: 3'u32 else: 2'u32
  let simm9 = (imm9.uint32 and 0x1FF)
  buf.emit((size shl 30) or 0x38400400'u32 or (simm9 shl 12) or rn(base) or rt(dst))

proc strPreIdx*(buf: var AsmBuffer, src, base: Reg, imm9: int32, is64: bool = true) =
  ## STR Rt, [Rn, #imm9]! (pre-index: add offset then store)
  let size = if is64: 3'u32 else: 2'u32
  let simm9 = (imm9.uint32 and 0x1FF)
  buf.emit((size shl 30) or 0x38000C00'u32 or (simm9 shl 12) or rn(base) or rt(src))

proc ldpImm*(buf: var AsmBuffer, rt1, rt2, base: Reg, offset: int32, is64: bool = true) =
  ## LDP Rt1, Rt2, [Rn, #offset] (load pair, signed offset)
  let opc = if is64: 2'u32 else: 0'u32
  let scale = if is64: 8 else: 4
  let simm7 = ((offset div scale).uint32 and 0x7F)
  buf.emit((opc shl 30) or 0x29400000'u32 or (simm7 shl 15) or (rt2.uint8.uint32 shl 10) or rn(base) or rt(rt1))

proc stpPreIdx*(buf: var AsmBuffer, rt1, rt2, base: Reg, offset: int32, is64: bool = true) =
  ## STP Rt1, Rt2, [Rn, #offset]! (store pair, pre-index)
  let opc = if is64: 2'u32 else: 0'u32
  let scale = if is64: 8 else: 4
  let simm7 = ((offset div scale).uint32 and 0x7F)
  buf.emit((opc shl 30) or 0x29800000'u32 or (simm7 shl 15) or (rt2.uint8.uint32 shl 10) or rn(base) or rt(rt1))

proc ldpPostIdx*(buf: var AsmBuffer, rt1, rt2, base: Reg, offset: int32, is64: bool = true) =
  ## LDP Rt1, Rt2, [Rn], #offset (load pair, post-index)
  let opc = if is64: 2'u32 else: 0'u32
  let scale = if is64: 8 else: 4
  let simm7 = ((offset div scale).uint32 and 0x7F)
  buf.emit((opc shl 30) or 0x28C00000'u32 or (simm7 shl 15) or (rt2.uint8.uint32 shl 10) or rn(base) or rt(rt1))

# ---- Branches ----

proc b*(buf: var AsmBuffer, offset26: int32) =
  ## B #offset (unconditional branch, offset in instructions)
  let imm26 = (offset26.uint32 and 0x03FFFFFF)
  buf.emit(0x14000000'u32 or imm26)

proc bl*(buf: var AsmBuffer, offset26: int32) =
  ## BL #offset (branch with link)
  let imm26 = (offset26.uint32 and 0x03FFFFFF)
  buf.emit(0x94000000'u32 or imm26)

proc br*(buf: var AsmBuffer, target: Reg) =
  ## BR Rn (branch to register)
  buf.emit(0xD61F0000'u32 or rn(target))

proc blr*(buf: var AsmBuffer, target: Reg) =
  ## BLR Rn (branch with link to register)
  buf.emit(0xD63F0000'u32 or rn(target))

proc ret*(buf: var AsmBuffer, target: Reg = lr) =
  ## RET {Rn} (default: x30/lr)
  buf.emit(0xD65F0000'u32 or rn(target))

proc bCond*(buf: var AsmBuffer, cond: Cond, offset19: int32) =
  ## B.cond #offset (conditional branch)
  let imm19 = (offset19.uint32 and 0x7FFFF)
  buf.emit(0x54000000'u32 or (imm19 shl 5) or cond.uint32)

proc cbz*(buf: var AsmBuffer, rt: Reg, offset19: int32, is64: bool = true) =
  ## CBZ Rt, #offset (compare and branch if zero)
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  let imm19 = (offset19.uint32 and 0x7FFFF)
  buf.emit(sf or 0x34000000'u32 or (imm19 shl 5) or rt.uint8.uint32)

proc cbnz*(buf: var AsmBuffer, rt: Reg, offset19: int32, is64: bool = true) =
  ## CBNZ Rt, #offset (compare and branch if not zero)
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  let imm19 = (offset19.uint32 and 0x7FFFF)
  buf.emit(sf or 0x35000000'u32 or (imm19 shl 5) or rt.uint8.uint32)

# ---- Special ----

proc nop*(buf: var AsmBuffer) =
  buf.emit(0xD503201F'u32)

proc brk*(buf: var AsmBuffer, imm16: uint32 = 0) =
  ## BRK #imm16 (breakpoint)
  buf.emit(0xD4200000'u32 or ((imm16 and 0xFFFF) shl 5))

# ---- Sign extension ----

proc sxtwReg*(buf: var AsmBuffer, dst, src: Reg) =
  ## SXTW Rd, Rn (sign-extend word to 64-bit)
  ## Alias for SBFM Xd, Xn, #0, #31
  buf.emit(0x93407C00'u32 or rn(src) or rd(dst))

proc sxthReg*(buf: var AsmBuffer, dst, src: Reg, is64: bool = false) =
  ## SXTH Rd, Rn (sign-extend halfword)
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  let n = if is64: 1'u32 shl 22 else: 0'u32
  buf.emit(sf or n or 0x13003C00'u32 or rn(src) or rd(dst))

proc sxtbReg*(buf: var AsmBuffer, dst, src: Reg, is64: bool = false) =
  ## SXTB Rd, Rn (sign-extend byte)
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  let n = if is64: 1'u32 shl 22 else: 0'u32
  buf.emit(sf or n or 0x13001C00'u32 or rn(src) or rd(dst))

# ---- Conditional select ----

proc invertCond*(c: Cond): Cond =
  ## Invert an AArch64 condition code (flips bit 0).
  Cond(c.ord xor 1)

proc csel*(buf: var AsmBuffer, dst, a, b: Reg, cond: Cond, is64: bool = true) =
  ## CSEL Rd, Rn, Rm, cond (if cond then Rd=Rn else Rd=Rm)
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  buf.emit(sf or 0x1A800000'u32 or rm(b) or (cond.uint32 shl 12) or rn(a) or rd(dst))

proc cset*(buf: var AsmBuffer, dst: Reg, cond: Cond) =
  ## CSET Wd, cond — alias for CSINC Wd, WZR, WZR, invert(cond)
  buf.emit(0x1A800400'u32 or (xzr.uint8.uint32 shl 16) or
           (invertCond(cond).uint32 shl 12) or (xzr.uint8.uint32 shl 5) or
           dst.uint8.uint32)

# ---- Floating point ----

proc frd(r: FReg): uint32 {.inline.} = r.uint8.uint32
proc frn(r: FReg): uint32 {.inline.} = r.uint8.uint32 shl 5
proc frm(r: FReg): uint32 {.inline.} = r.uint8.uint32 shl 16

proc faddScalar*(buf: var AsmBuffer, dst, a, b: FReg, is64: bool = true) =
  ## FADD Dd, Dn, Dm (or Sd, Sn, Sm for 32-bit)
  let ftype = if is64: 1'u32 shl 22 else: 0'u32
  buf.emit(0x1E202800'u32 or ftype or frm(b) or frn(a) or frd(dst))

proc fsubScalar*(buf: var AsmBuffer, dst, a, b: FReg, is64: bool = true) =
  let ftype = if is64: 1'u32 shl 22 else: 0'u32
  buf.emit(0x1E203800'u32 or ftype or frm(b) or frn(a) or frd(dst))

proc fmulScalar*(buf: var AsmBuffer, dst, a, b: FReg, is64: bool = true) =
  let ftype = if is64: 1'u32 shl 22 else: 0'u32
  buf.emit(0x1E200800'u32 or ftype or frm(b) or frn(a) or frd(dst))

proc fdivScalar*(buf: var AsmBuffer, dst, a, b: FReg, is64: bool = true) =
  let ftype = if is64: 1'u32 shl 22 else: 0'u32
  buf.emit(0x1E201800'u32 or ftype or frm(b) or frn(a) or frd(dst))

proc fmovGpToFp*(buf: var AsmBuffer, dst: FReg, src: Reg, is64: bool = true) =
  ## FMOV Dd, Xn (move general register to FP register)
  let ftype = if is64: 1'u32 shl 22 else: 0'u32
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  buf.emit(sf or ftype or 0x1E260000'u32 or rn(src) or frd(dst))

proc fmovFpToGp*(buf: var AsmBuffer, dst: Reg, src: FReg, is64: bool = true) =
  ## FMOV Xn, Dd (move FP register to general register)
  let ftype = if is64: 1'u32 shl 22 else: 0'u32
  let sf = if is64: 1'u32 shl 31 else: 0'u32
  buf.emit(sf or ftype or 0x1E270000'u32 or frn(src) or rd(dst))

# ---- NEON 128-bit vector (Q registers) ----
# Q registers share the FReg type; register number is the Q-register index (0-31).
# We use v16-v31 (indices 16-31) as allocatable SIMD registers.

proc vqn(r: FReg): uint32 {.inline.} = r.uint8.uint32 shl 5
proc vqd(r: FReg): uint32 {.inline.} = r.uint8.uint32
proc vqm(r: FReg): uint32 {.inline.} = r.uint8.uint32 shl 16

proc ld1q*(buf: var AsmBuffer, dst: FReg, base: Reg) =
  ## LD1 {Vt.4S}, [Xn]  — load 128-bit (4×i32 lanes) from memory
  ## Encoding: 0100 1100 0100 0000 0111 00nn nnnn ttttt
  buf.emit(0x4C407000'u32 or (base.uint8.uint32 shl 5) or dst.uint8.uint32)

proc st1q*(buf: var AsmBuffer, src: FReg, base: Reg) =
  ## ST1 {Vt.4S}, [Xn]  — store 128-bit to memory
  buf.emit(0x4C007000'u32 or (base.uint8.uint32 shl 5) or src.uint8.uint32)

proc addVec4s*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## ADD Vd.4S, Vn.4S, Vm.4S  — i32x4 add
  ## size=10 (32-bit), Q=1, opcode=10000 → 0100 1110 1010 0000 1000 01nn nnnn dddd d
  buf.emit(0x4EA08400'u32 or vqm(b) or vqn(a) or vqd(dst))

proc subVec4s*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## SUB Vd.4S, Vn.4S, Vm.4S
  buf.emit(0x6EA08400'u32 or vqm(b) or vqn(a) or vqd(dst))

proc mulVec4s*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## MUL Vd.4S, Vn.4S, Vm.4S
  buf.emit(0x4EA09C00'u32 or vqm(b) or vqn(a) or vqd(dst))

proc andVec*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## AND Vd.16B, Vn.16B, Vm.16B
  buf.emit(0x4E201C00'u32 or vqm(b) or vqn(a) or vqd(dst))

proc orrVec*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## ORR Vd.16B, Vn.16B, Vm.16B
  buf.emit(0x4EA01C00'u32 or vqm(b) or vqn(a) or vqd(dst))

proc eorVec*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## EOR Vd.16B, Vn.16B, Vm.16B
  buf.emit(0x6E201C00'u32 or vqm(b) or vqn(a) or vqd(dst))

proc notVec*(buf: var AsmBuffer, dst, src: FReg) =
  ## NOT Vd.16B, Vn.16B  (alias for MVN)
  buf.emit(0x6E205800'u32 or vqn(src) or vqd(dst))

proc movVec*(buf: var AsmBuffer, dst, src: FReg) =
  ## MOV Vd.16B, Vn.16B  (ORR Vd.16B, Vn.16B, Vn.16B)
  buf.emit(0x4EA01C00'u32 or vqm(src) or vqn(src) or vqd(dst))

proc faddVec4s*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## FADD Vd.4S, Vn.4S, Vm.4S  — f32x4 add
  buf.emit(0x4E20D400'u32 or vqm(b) or vqn(a) or vqd(dst))

proc fsubVec4s*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## FSUB Vd.4S, Vn.4S, Vm.4S
  buf.emit(0x4EA0D400'u32 or vqm(b) or vqn(a) or vqd(dst))

proc fmulVec4s*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## FMUL Vd.4S, Vn.4S, Vm.4S
  buf.emit(0x6E20DC00'u32 or vqm(b) or vqn(a) or vqd(dst))

proc fdivVec4s*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## FDIV Vd.4S, Vn.4S, Vm.4S
  buf.emit(0x6E20FC00'u32 or vqm(b) or vqn(a) or vqd(dst))

proc dupVec4s*(buf: var AsmBuffer, dst: FReg, src: Reg) =
  ## DUP Vd.4S, Wn  — broadcast W register to all 4 i32 lanes
  ## Q=1, op=0, imm5=00100 (size=S/32-bit, index=0), Rn→dst
  buf.emit(0x4E040C00'u32 or (src.uint8.uint32 shl 5) or dst.uint8.uint32)

proc dupVec4sFromFp*(buf: var AsmBuffer, dst, src: FReg) =
  ## DUP Vd.4S, Vn.S[0]  — broadcast lane 0 of scalar S-reg to all 4 lanes
  ## Uses: DUP Vd.4S, Vn.4S[0]: Q=1, op=0, imm5=00100 (S lane 0)
  buf.emit(0x4E040400'u32 or vqn(src) or vqd(dst))

proc umovW*(buf: var AsmBuffer, dst: Reg, src: FReg, lane: int) =
  ## UMOV Wd, Vn.S[lane]  — extract i32 lane to W register (zero-extend to 64-bit)
  ## imm5 = (lane << 3) | 0b100 for 32-bit lanes
  let imm5 = uint32((lane shl 3) or 0x4)
  buf.emit(0x0E003C00'u32 or (imm5 shl 16) or (src.uint8.uint32 shl 5) or dst.uint8.uint32)

proc smovW*(buf: var AsmBuffer, dst: Reg, src: FReg, lane: int) =
  ## SMOV Wd, Vn.S[lane]  — extract i32 lane with sign-extension (same as UMOV for 32-bit)
  ## For i32x4 extract_lane (signed), use SMOV with 64-bit result
  let imm5 = uint32((lane shl 3) or 0x4)
  buf.emit(0x4E002C00'u32 or (imm5 shl 16) or (src.uint8.uint32 shl 5) or dst.uint8.uint32)

proc fmovVecLaneToS*(buf: var AsmBuffer, dst: FReg, src: FReg, lane: int) =
  ## FMOV Sd, Vn.S[lane] — extract f32 lane to scalar S register
  ## For lane=0 this is just FMOV Sd, Sn; for others use INS+FMOV idiom via DUP
  ## Simplest: use DUP to broadcast lane to lane 0, then read as scalar
  if lane == 0:
    # Just copy register (same physical Q register; treat as S-register usage)
    buf.emit(0x0EA01C00'u32 or vqn(src) or vqd(dst))  # MOV Vd.8B, Vn.8B (low 64-bit copy)
  else:
    # DUP to tmp is needed; caller must use dupVec4sFromFp or equivalent
    # For simplicity emit DUP of lane to Vd lane 0
    let imm5 = uint32((lane shl 3) or 0x4)
    buf.emit(0x4E000400'u32 or (imm5 shl 16) or (src.uint8.uint32 shl 5) or dst.uint8.uint32)

proc insVec4sFromW*(buf: var AsmBuffer, dst: FReg, lane: int, src: Reg) =
  ## INS Vd.S[lane], Wn  — insert W register into a specific lane
  ## imm5 = (lane << 3) | 0b100
  let imm5 = uint32((lane shl 3) or 0x4)
  buf.emit(0x4E001C00'u32 or (imm5 shl 16) or (src.uint8.uint32 shl 5) or dst.uint8.uint32)

proc insVec4sFromVec*(buf: var AsmBuffer, dst: FReg, dstLane: int, src: FReg, srcLane: int) =
  ## INS Vd.S[dstLane], Vn.S[srcLane]  — copy lane between vectors
  ## imm5 = (dstLane << 3) | 0b100; imm4 = srcLane << 2
  let imm5 = uint32((dstLane shl 3) or 0x4)
  let imm4 = uint32(srcLane shl 2)
  buf.emit(0x6E000400'u32 or (imm5 shl 16) or (imm4 shl 11) or (src.uint8.uint32 shl 5) or dst.uint8.uint32)

# ---- Extended NEON helpers ----

proc dupVec16b*(buf: var AsmBuffer, dst: FReg, src: Reg) =
  ## DUP Vd.16B, Wn  — broadcast low byte of W to all 16 byte lanes
  ## imm5=00001 (B size, lane-index=0 from Wn)
  buf.emit(0x4E010C00'u32 or (src.uint8.uint32 shl 5) or dst.uint8.uint32)

proc dupVec8h*(buf: var AsmBuffer, dst: FReg, src: Reg) =
  ## DUP Vd.8H, Wn  — broadcast low halfword of W to all 8 halfword lanes
  ## imm5=00010 (H size)
  buf.emit(0x4E020C00'u32 or (src.uint8.uint32 shl 5) or dst.uint8.uint32)

proc dupVec2d*(buf: var AsmBuffer, dst: FReg, src: Reg) =
  ## DUP Vd.2D, Xn  — broadcast 64-bit Xn to both D lanes
  ## imm5=01000 (D size)
  buf.emit(0x4E080C00'u32 or (src.uint8.uint32 shl 5) or dst.uint8.uint32)

# ---- i8x16 lane ops ----

proc smovX16b*(buf: var AsmBuffer, dst: Reg, src: FReg, lane: int) =
  ## SMOV Xd, Vn.B[lane]  — sign-extend byte lane to 64-bit Xd
  ## imm5 = (lane << 1) | 1 (B element); Q=1 for X register
  let imm5 = uint32((lane shl 1) or 1)
  buf.emit(0x4E002C00'u32 or (imm5 shl 16) or (src.uint8.uint32 shl 5) or dst.uint8.uint32)

proc umovB16b*(buf: var AsmBuffer, dst: Reg, src: FReg, lane: int) =
  ## UMOV Wd, Vn.B[lane]  — zero-extend byte lane to 32-bit Wd
  ## imm5 = (lane << 1) | 1; Q=0 for W register
  let imm5 = uint32((lane shl 1) or 1)
  buf.emit(0x0E003C00'u32 or (imm5 shl 16) or (src.uint8.uint32 shl 5) or dst.uint8.uint32)

proc insVec16bFromW*(buf: var AsmBuffer, dst: FReg, lane: int, src: Reg) =
  ## INS Vd.B[lane], Wn  — insert low byte of W into byte lane
  ## imm5 = (lane << 1) | 1
  let imm5 = uint32((lane shl 1) or 1)
  buf.emit(0x4E001C00'u32 or (imm5 shl 16) or (src.uint8.uint32 shl 5) or dst.uint8.uint32)

# ---- i16x8 lane ops ----

proc smovX8h*(buf: var AsmBuffer, dst: Reg, src: FReg, lane: int) =
  ## SMOV Xd, Vn.H[lane]  — sign-extend halfword lane to 64-bit Xd
  ## imm5 = (lane << 2) | 2 (H element)
  let imm5 = uint32((lane shl 2) or 2)
  buf.emit(0x4E002C00'u32 or (imm5 shl 16) or (src.uint8.uint32 shl 5) or dst.uint8.uint32)

proc umovH8h*(buf: var AsmBuffer, dst: Reg, src: FReg, lane: int) =
  ## UMOV Wd, Vn.H[lane]  — zero-extend halfword lane to 32-bit Wd
  ## imm5 = (lane << 2) | 2; Q=0
  let imm5 = uint32((lane shl 2) or 2)
  buf.emit(0x0E003C00'u32 or (imm5 shl 16) or (src.uint8.uint32 shl 5) or dst.uint8.uint32)

proc insVec8hFromW*(buf: var AsmBuffer, dst: FReg, lane: int, src: Reg) =
  ## INS Vd.H[lane], Wn  — insert low halfword of W into H lane
  ## imm5 = (lane << 2) | 2
  let imm5 = uint32((lane shl 2) or 2)
  buf.emit(0x4E001C00'u32 or (imm5 shl 16) or (src.uint8.uint32 shl 5) or dst.uint8.uint32)

# ---- i64x2 / f64x2 lane ops ----

proc umovX2d*(buf: var AsmBuffer, dst: Reg, src: FReg, lane: int) =
  ## UMOV Xd, Vn.D[lane]  — move 64-bit D lane to Xd
  ## imm5 = (lane << 4) | 8 (D element); Q=1 for X register
  let imm5 = uint32((lane shl 4) or 8)
  buf.emit(0x4E003C00'u32 or (imm5 shl 16) or (src.uint8.uint32 shl 5) or dst.uint8.uint32)

proc insVec2dFromX*(buf: var AsmBuffer, dst: FReg, lane: int, src: Reg) =
  ## INS Vd.D[lane], Xn  — insert 64-bit Xn into D lane
  ## imm5 = (lane << 4) | 8
  let imm5 = uint32((lane shl 4) or 8)
  buf.emit(0x4E001C00'u32 or (imm5 shl 16) or (src.uint8.uint32 shl 5) or dst.uint8.uint32)

# ---- v128 bitwise extensions ----

proc bicVec*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## BIC Vd.16B, Vn.16B, Vm.16B  — a AND NOT b
  ## type bits 23-22 = 01 → 0x4E60_1C00
  buf.emit(0x4E601C00'u32 or vqm(b) or vqn(a) or vqd(dst))

proc cntVec8b*(buf: var AsmBuffer, dst, src: FReg) =
  ## CNT Vd.8B, Vn.8B — count set bits in each byte lane (8-byte D-register form)
  ## Encoding: 0_0_0_01110_00_10000_01011_10_Rn_Rd  = 0x0E205800
  buf.emit(0x0E205800'u32 or (src.uint8.uint32 shl 5) or dst.uint8.uint32)

proc addvVec8b*(buf: var AsmBuffer, dst, src: FReg) =
  ## ADDV Bd, Vn.8B — horizontal add: sum all 8 byte lanes into scalar B register
  ## Encoding: 0_0_0_01110_00_11000_1_1011_10_Rn_Rd  = 0x0E31B800
  buf.emit(0x0E31B800'u32 or (src.uint8.uint32 shl 5) or dst.uint8.uint32)

# ---- i8x16 arithmetic ----

proc absVec16b*(buf: var AsmBuffer, dst, src: FReg) =
  ## ABS Vd.16B, Vn.16B  — absolute value (signed bytes)
  buf.emit(0x4E20B800'u32 or vqn(src) or vqd(dst))

proc negVec16b*(buf: var AsmBuffer, dst, src: FReg) =
  ## NEG Vd.16B, Vn.16B  — negate (two's complement)
  buf.emit(0x6E20B800'u32 or vqn(src) or vqd(dst))

proc addVec16b*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## ADD Vd.16B, Vn.16B, Vm.16B
  buf.emit(0x4E208400'u32 or vqm(b) or vqn(a) or vqd(dst))

proc subVec16b*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## SUB Vd.16B, Vn.16B, Vm.16B
  buf.emit(0x6E208400'u32 or vqm(b) or vqn(a) or vqd(dst))

proc sminVec16b*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## SMIN Vd.16B, Vn.16B, Vm.16B  — signed min
  buf.emit(0x4E206C00'u32 or vqm(b) or vqn(a) or vqd(dst))

proc uminVec16b*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## UMIN Vd.16B, Vn.16B, Vm.16B  — unsigned min
  buf.emit(0x6E206C00'u32 or vqm(b) or vqn(a) or vqd(dst))

proc smaxVec16b*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## SMAX Vd.16B, Vn.16B, Vm.16B  — signed max
  buf.emit(0x4E206400'u32 or vqm(b) or vqn(a) or vqd(dst))

proc umaxVec16b*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## UMAX Vd.16B, Vn.16B, Vm.16B  — unsigned max
  buf.emit(0x6E206400'u32 or vqm(b) or vqn(a) or vqd(dst))

# ---- i16x8 arithmetic ----

proc absVec8h*(buf: var AsmBuffer, dst, src: FReg) =
  ## ABS Vd.8H, Vn.8H
  buf.emit(0x4E60B800'u32 or vqn(src) or vqd(dst))

proc negVec8h*(buf: var AsmBuffer, dst, src: FReg) =
  ## NEG Vd.8H, Vn.8H
  buf.emit(0x6E60B800'u32 or vqn(src) or vqd(dst))

proc addVec8h*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## ADD Vd.8H, Vn.8H, Vm.8H
  buf.emit(0x4E608400'u32 or vqm(b) or vqn(a) or vqd(dst))

proc subVec8h*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## SUB Vd.8H, Vn.8H, Vm.8H
  buf.emit(0x6E608400'u32 or vqm(b) or vqn(a) or vqd(dst))

proc mulVec8h*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## MUL Vd.8H, Vn.8H, Vm.8H
  buf.emit(0x4E609C00'u32 or vqm(b) or vqn(a) or vqd(dst))

# ---- i32x4 extensions ----

proc absVec4s*(buf: var AsmBuffer, dst, src: FReg) =
  ## ABS Vd.4S, Vn.4S
  buf.emit(0x4EA0B800'u32 or vqn(src) or vqd(dst))

proc negVec4s*(buf: var AsmBuffer, dst, src: FReg) =
  ## NEG Vd.4S, Vn.4S
  buf.emit(0x6EA0B800'u32 or vqn(src) or vqd(dst))

proc sshlVec4s*(buf: var AsmBuffer, dst, src, shiftVec: FReg) =
  ## SSHL Vd.4S, Vn.4S, Vm.4S  — signed variable shift (pos=left, neg=right/arithmetic)
  buf.emit(0x4EA04400'u32 or vqm(shiftVec) or vqn(src) or vqd(dst))

proc ushlVec4s*(buf: var AsmBuffer, dst, src, shiftVec: FReg) =
  ## USHL Vd.4S, Vn.4S, Vm.4S  — unsigned variable shift (pos=left, neg=right/logical)
  buf.emit(0x6EA04400'u32 or vqm(shiftVec) or vqn(src) or vqd(dst))

proc sminVec4s*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## SMIN Vd.4S, Vn.4S, Vm.4S
  buf.emit(0x4EA06C00'u32 or vqm(b) or vqn(a) or vqd(dst))

proc uminVec4s*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## UMIN Vd.4S, Vn.4S, Vm.4S
  buf.emit(0x6EA06C00'u32 or vqm(b) or vqn(a) or vqd(dst))

proc smaxVec4s*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## SMAX Vd.4S, Vn.4S, Vm.4S
  buf.emit(0x4EA06400'u32 or vqm(b) or vqn(a) or vqd(dst))

proc umaxVec4s*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## UMAX Vd.4S, Vn.4S, Vm.4S
  buf.emit(0x6EA06400'u32 or vqm(b) or vqn(a) or vqd(dst))

# ---- i64x2 arithmetic ----

proc addVec2d*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## ADD Vd.2D, Vn.2D, Vm.2D
  buf.emit(0x4EE08400'u32 or vqm(b) or vqn(a) or vqd(dst))

proc subVec2d*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## SUB Vd.2D, Vn.2D, Vm.2D
  buf.emit(0x6EE08400'u32 or vqm(b) or vqn(a) or vqd(dst))

# ---- f32x4 unary ----

proc fabsVec4s*(buf: var AsmBuffer, dst, src: FReg) =
  ## FABS Vd.4S, Vn.4S
  buf.emit(0x4EA0F800'u32 or vqn(src) or vqd(dst))

proc fnegVec4s*(buf: var AsmBuffer, dst, src: FReg) =
  ## FNEG Vd.4S, Vn.4S
  buf.emit(0x6EA0F800'u32 or vqn(src) or vqd(dst))

# ---- f64x2 arithmetic ----

proc faddVec2d*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## FADD Vd.2D, Vn.2D, Vm.2D
  buf.emit(0x4E60D400'u32 or vqm(b) or vqn(a) or vqd(dst))

proc fsubVec2d*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## FSUB Vd.2D, Vn.2D, Vm.2D
  buf.emit(0x4EE0D400'u32 or vqm(b) or vqn(a) or vqd(dst))

proc fmulVec2d*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## FMUL Vd.2D, Vn.2D, Vm.2D
  buf.emit(0x6E60DC00'u32 or vqm(b) or vqn(a) or vqd(dst))

proc fdivVec2d*(buf: var AsmBuffer, dst, a, b: FReg) =
  ## FDIV Vd.2D, Vn.2D, Vm.2D
  buf.emit(0x6E60FC00'u32 or vqm(b) or vqn(a) or vqd(dst))

proc fabsVec2d*(buf: var AsmBuffer, dst, src: FReg) =
  ## FABS Vd.2D, Vn.2D
  buf.emit(0x4EE0F800'u32 or vqn(src) or vqd(dst))

proc fnegVec2d*(buf: var AsmBuffer, dst, src: FReg) =
  ## FNEG Vd.2D, Vn.2D
  buf.emit(0x6EE0F800'u32 or vqn(src) or vqd(dst))
