## x86_64 instruction encoder
## Provides the same interface as codegen.nim (AArch64) for cross-platform JIT.
## This module is used on x86_64 Linux/macOS/Windows.

when defined(arm64) or defined(aarch64):
  {.warning: "codegen_x64.nim included on ARM64 — use codegen.nim instead".}

type
  X64Reg* = distinct uint8
  X64FReg* = distinct uint8  # XMM register

  X64Cond* = enum
    x64condO  = 0x0   # Overflow
    x64condNO = 0x1   # No overflow
    x64condB  = 0x2   # Below (unsigned <)
    x64condAE = 0x3   # Above or equal (unsigned >=)
    x64condE  = 0x4   # Equal
    x64condNE = 0x5   # Not equal
    x64condBE = 0x6   # Below or equal (unsigned <=)
    x64condA  = 0x7   # Above (unsigned >)
    x64condS  = 0x8   # Sign (negative)
    x64condNS = 0x9   # No sign
    x64condP  = 0xA   # Parity (PF=1, set by UCOMISS/UCOMISD when NaN)
    x64condNP = 0xB   # No parity (PF=0, ordered result)
    x64condL  = 0xC   # Less (signed <)
    x64condGE = 0xD   # Greater or equal (signed >=)
    x64condLE = 0xE   # Less or equal (signed <=)
    x64condG  = 0xF   # Greater (signed >)

# ---- Register definitions ----
const
  rax* = X64Reg(0)
  rcx* = X64Reg(1)
  rdx* = X64Reg(2)
  rbx* = X64Reg(3)
  rsp* = X64Reg(4)
  rbp* = X64Reg(5)
  rsi* = X64Reg(6)
  rdi* = X64Reg(7)
  r8*  = X64Reg(8)
  r9*  = X64Reg(9)
  r10* = X64Reg(10)
  r11* = X64Reg(11)
  r12* = X64Reg(12)
  r13* = X64Reg(13)
  r14* = X64Reg(14)
  r15* = X64Reg(15)

  # XMM registers for floating point
  xmm0* = X64FReg(0)
  xmm1* = X64FReg(1)
  xmm2* = X64FReg(2)
  xmm3* = X64FReg(3)

  # WASM register convention for x86_64
  # SysV ABI: rdi, rsi, rdx, rcx, r8, r9 for args
  x64rVSP*     = r12     # Value stack pointer (callee-saved)
  x64rLocals*  = r13     # Locals base (callee-saved)
  x64rMemBase* = r14     # Memory base (callee-saved)
  x64rMemSize* = r15     # Memory size (callee-saved)
  x64rScratch0* = rax
  x64rScratch1* = rcx
  x64rScratch2* = rdx
  x64rScratch3* = rsi

proc `==`*(a, b: X64Reg): bool {.borrow.}
proc `==`*(a, b: X64FReg): bool {.borrow.}

  # Condition code aliases for readability
const
  x64condEQ* = x64condE
  x64condNEQ* = x64condNE
  x64condLT* = x64condL
  x64condGT* = x64condG

# ---- Code buffer ----
type
  X64AsmBuffer* = object
    code*: seq[byte]  # x86_64 uses variable-length encoding

proc initX64AsmBuffer*(cap: int = 1024): X64AsmBuffer =
  result.code = newSeqOfCap[byte](cap)

proc emit*(buf: var X64AsmBuffer, b: byte) {.inline.} =
  buf.code.add(b)

proc emit*(buf: var X64AsmBuffer, bytes: openArray[byte]) =
  buf.code.add(bytes)

proc len*(buf: X64AsmBuffer): int = buf.code.len
proc pos*(buf: X64AsmBuffer): int = buf.code.len  ## Current byte offset

proc emitImm32*(buf: var X64AsmBuffer, v: int32) =
  let u = cast[uint32](v)
  buf.emit([byte(u and 0xFF), byte((u shr 8) and 0xFF),
            byte((u shr 16) and 0xFF), byte((u shr 24) and 0xFF)])

proc emitImm64*(buf: var X64AsmBuffer, v: uint64) =
  buf.emit([byte(v and 0xFF), byte((v shr 8) and 0xFF),
            byte((v shr 16) and 0xFF), byte((v shr 24) and 0xFF),
            byte((v shr 32) and 0xFF), byte((v shr 40) and 0xFF),
            byte((v shr 48) and 0xFF), byte((v shr 56) and 0xFF)])

# ---- REX prefix ----
proc rex(w: bool = false, r: X64Reg = X64Reg(0), x: X64Reg = X64Reg(0), b: X64Reg = X64Reg(0)): byte =
  var v: byte = 0x40
  if w: v = v or 0x08        # 64-bit operand
  if r.uint8 >= 8: v = v or 0x04  # REX.R
  if x.uint8 >= 8: v = v or 0x02  # REX.X
  if b.uint8 >= 8: v = v or 0x01  # REX.B
  v

proc modRM(mode: byte, reg, rm: byte): byte =
  (mode shl 6) or ((reg and 7) shl 3) or (rm and 7)

proc needsRex(r: X64Reg): bool {.inline.} = r.uint8 >= 8

proc emitModRMMem(buf: var X64AsmBuffer, regField: byte, base: X64Reg, offset: int32) =
  ## Emit ModR/M + SIB + displacement for [base+offset] addressing.
  if offset == 0 and (base.uint8 and 7) != 5:
    buf.emit(modRM(0b00, regField, base.uint8))
    if (base.uint8 and 7) == 4: buf.emit(0x24)
  elif offset >= -128 and offset <= 127:
    buf.emit(modRM(0b01, regField, base.uint8))
    if (base.uint8 and 7) == 4: buf.emit(0x24)
    buf.emit(cast[byte](offset))
  else:
    buf.emit(modRM(0b10, regField, base.uint8))
    if (base.uint8 and 7) == 4: buf.emit(0x24)
    buf.emitImm32(offset)

# ---- Encoding helpers ----

proc pushReg*(buf: var X64AsmBuffer, reg: X64Reg) =
  if reg.uint8 >= 8:
    buf.emit(0x41)
  buf.emit(0x50 + (reg.uint8 and 7))

proc popReg*(buf: var X64AsmBuffer, reg: X64Reg) =
  if reg.uint8 >= 8:
    buf.emit(0x41)
  buf.emit(0x58 + (reg.uint8 and 7))

proc ret*(buf: var X64AsmBuffer) =
  buf.emit(0xC3)

proc nop*(buf: var X64AsmBuffer) =
  buf.emit(0x90)

proc movRegReg*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## MOV dst, src (64-bit). Self-moves are silently dropped.
  if dst == src: return
  buf.emit(rex(w = true, r = src, b = dst))
  buf.emit(0x89)
  buf.emit(modRM(0b11, src.uint8, dst.uint8))

proc movRegImm64*(buf: var X64AsmBuffer, dst: X64Reg, imm: uint64) =
  ## MOV dst, imm64 (movabs)
  buf.emit(rex(w = true, b = dst))
  buf.emit(0xB8 + (dst.uint8 and 7))
  buf.emitImm64(imm)

proc movRegImm32*(buf: var X64AsmBuffer, dst: X64Reg, imm: int32) =
  ## MOV dst, imm32 (sign-extended to 64-bit)
  buf.emit(rex(w = true, b = dst))
  buf.emit(0xC7)
  buf.emit(modRM(0b11, 0, dst.uint8))
  buf.emitImm32(imm)

proc addRegReg*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## ADD dst, src (64-bit)
  buf.emit(rex(w = true, r = src, b = dst))
  buf.emit(0x01)
  buf.emit(modRM(0b11, src.uint8, dst.uint8))

proc subRegReg*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## SUB dst, src (64-bit)
  buf.emit(rex(w = true, r = src, b = dst))
  buf.emit(0x29)
  buf.emit(modRM(0b11, src.uint8, dst.uint8))

proc aluRegImm32(buf: var X64AsmBuffer, dst: X64Reg, imm: int32, regField: byte) {.inline.} =
  ## Generic ALU reg, imm32 (64-bit): ADD/OR/AND/SUB/XOR/CMP selected by regField
  buf.emit(rex(w = true, b = dst))
  if imm >= -128 and imm <= 127:
    buf.emit(0x83)
    buf.emit(modRM(0b11, regField, dst.uint8))
    buf.emit(cast[byte](imm))
  else:
    buf.emit(0x81)
    buf.emit(modRM(0b11, regField, dst.uint8))
    buf.emitImm32(imm)

proc addRegImm32*(buf: var X64AsmBuffer, dst: X64Reg, imm: int32) = buf.aluRegImm32(dst, imm, 0)
proc subRegImm32*(buf: var X64AsmBuffer, dst: X64Reg, imm: int32) = buf.aluRegImm32(dst, imm, 5)

proc cmpRegReg*(buf: var X64AsmBuffer, a, b: X64Reg) =
  ## CMP a, b (64-bit)
  buf.emit(rex(w = true, r = b, b = a))
  buf.emit(0x39)
  buf.emit(modRM(0b11, b.uint8, a.uint8))

proc cmpRegImm32*(buf: var X64AsmBuffer, dst: X64Reg, imm: int32) = buf.aluRegImm32(dst, imm, 7)

proc jmpRel32*(buf: var X64AsmBuffer, offset: int32) =
  ## JMP rel32
  buf.emit(0xE9)
  buf.emitImm32(offset)

proc jccRel32*(buf: var X64AsmBuffer, cond: X64Cond, offset: int32) =
  ## Jcc rel32 (conditional jump)
  buf.emit(0x0F)
  buf.emit(0x80 + cond.byte)
  buf.emitImm32(offset)

proc callRel32*(buf: var X64AsmBuffer, offset: int32) =
  ## CALL rel32
  buf.emit(0xE8)
  buf.emitImm32(offset)

proc callReg*(buf: var X64AsmBuffer, reg: X64Reg) =
  ## CALL reg
  if reg.uint8 >= 8:
    buf.emit(0x41)
  buf.emit(0xFF)
  buf.emit(modRM(0b11, 2, reg.uint8))

# ---- Memory access (64-bit) ----

proc movRegMem*(buf: var X64AsmBuffer, dst, base: X64Reg, offset: int32) =
  ## MOV dst, [base + offset] (64-bit load)
  buf.emit(rex(w = true, r = dst, b = base))
  buf.emit(0x8B)
  buf.emitModRMMem(dst.uint8, base, offset)

proc movMemReg*(buf: var X64AsmBuffer, base: X64Reg, offset: int32, src: X64Reg) =
  ## MOV [base + offset], src (64-bit store)
  buf.emit(rex(w = true, r = src, b = base))
  buf.emit(0x89)
  buf.emitModRMMem(src.uint8, base, offset)

proc movRegReg32*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## MOV dst(32), src(32) — zero-extends to 64-bit (implicit in x86_64).
  ## Self-moves are silently dropped.
  if dst == src: return
  if needsRex(dst) or needsRex(src):
    buf.emit(rex(w = false, r = src, b = dst))
  buf.emit(0x89)
  buf.emit(modRM(0b11, src.uint8, dst.uint8))

# ---- Memory access (32-bit) ----

proc movRegMem32*(buf: var X64AsmBuffer, dst, base: X64Reg, offset: int32) =
  ## MOV dst(32), [base + offset] (32-bit load, zero-extends to 64)
  if needsRex(dst) or needsRex(base):
    buf.emit(rex(w = false, r = dst, b = base))
  buf.emit(0x8B)
  buf.emitModRMMem(dst.uint8, base, offset)

proc movMemReg32*(buf: var X64AsmBuffer, base: X64Reg, offset: int32, src: X64Reg) =
  ## MOV [base + offset], src(32) (32-bit store)
  if needsRex(src) or needsRex(base):
    buf.emit(rex(w = false, r = src, b = base))
  buf.emit(0x89)
  buf.emitModRMMem(src.uint8, base, offset)

# ---- Memory access (16-bit) ----

proc movMemReg16*(buf: var X64AsmBuffer, base: X64Reg, offset: int32, src: X64Reg) =
  ## MOV [base + offset], src(16) (16-bit store)
  buf.emit(0x66)  # operand-size prefix
  if needsRex(src) or needsRex(base):
    buf.emit(rex(w = false, r = src, b = base))
  buf.emit(0x89)
  buf.emitModRMMem(src.uint8, base, offset)

# ---- Memory access (8-bit) ----

proc movMemReg8*(buf: var X64AsmBuffer, base: X64Reg, offset: int32, src: X64Reg) =
  ## MOV [base + offset], src(8) (byte store)
  # REX needed if using SPL/BPL/SIL/DIL (regs 4-7) or R8-R15
  if needsRex(src) or needsRex(base) or src.uint8 in {4'u8, 5, 6, 7}:
    buf.emit(rex(w = false, r = src, b = base))
  buf.emit(0x88)
  buf.emitModRMMem(src.uint8, base, offset)

# ---- Zero/Sign-extending loads ----

proc movzbX64*(buf: var X64AsmBuffer, dst, base: X64Reg, offset: int32) =
  ## MOVZX dst(64), BYTE [base + offset]
  buf.emit(rex(w = true, r = dst, b = base))
  buf.emit(0x0F)
  buf.emit(0xB6)
  buf.emitModRMMem(dst.uint8, base, offset)

proc movzwX64*(buf: var X64AsmBuffer, dst, base: X64Reg, offset: int32) =
  ## MOVZX dst(64), WORD [base + offset]
  buf.emit(rex(w = true, r = dst, b = base))
  buf.emit(0x0F)
  buf.emit(0xB7)
  buf.emitModRMMem(dst.uint8, base, offset)

proc movsbX64*(buf: var X64AsmBuffer, dst, base: X64Reg, offset: int32) =
  ## MOVSX dst(64), BYTE [base + offset]
  buf.emit(rex(w = true, r = dst, b = base))
  buf.emit(0x0F)
  buf.emit(0xBE)
  buf.emitModRMMem(dst.uint8, base, offset)

proc movswX64*(buf: var X64AsmBuffer, dst, base: X64Reg, offset: int32) =
  ## MOVSX dst(64), WORD [base + offset]
  buf.emit(rex(w = true, r = dst, b = base))
  buf.emit(0x0F)
  buf.emit(0xBF)
  buf.emitModRMMem(dst.uint8, base, offset)

proc movsdX64*(buf: var X64AsmBuffer, dst, base: X64Reg, offset: int32) =
  ## MOVSXD dst(64), DWORD [base + offset]
  buf.emit(rex(w = true, r = dst, b = base))
  buf.emit(0x63)
  buf.emitModRMMem(dst.uint8, base, offset)

# ---- Zero/Sign-extending register-to-register ----

proc movzxb*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## MOVZX dst, src(8) — zero-extend byte to 64-bit
  buf.emit(rex(w = true, r = dst, b = src))
  buf.emit(0x0F)
  buf.emit(0xB6)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc movzxw*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## MOVZX dst, src(16) — zero-extend word to 64-bit
  buf.emit(rex(w = true, r = dst, b = src))
  buf.emit(0x0F)
  buf.emit(0xB7)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc movsxb*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## MOVSX dst, src(8) — sign-extend byte to 64-bit
  buf.emit(rex(w = true, r = dst, b = src))
  buf.emit(0x0F)
  buf.emit(0xBE)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc movsxw*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## MOVSX dst, src(16) — sign-extend word to 64-bit
  buf.emit(rex(w = true, r = dst, b = src))
  buf.emit(0x0F)
  buf.emit(0xBF)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc movsxd*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## MOVSXD dst, src(32) — sign-extend dword to 64-bit
  buf.emit(rex(w = true, r = dst, b = src))
  buf.emit(0x63)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc movsx32*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## MOVSX r32, r/m8 — sign-extend byte to 32-bit (zero-extends to 64-bit)
  if dst.uint8 >= 8 or src.uint8 >= 8:
    var v: byte = 0x40
    if dst.uint8 >= 8: v = v or 0x04
    if src.uint8 >= 8: v = v or 0x01
    buf.emit(v)
  buf.emit(0x0F); buf.emit(0xBE)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc movsxw32*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## MOVSX r32, r/m16 — sign-extend word to 32-bit (zero-extends to 64-bit)
  if dst.uint8 >= 8 or src.uint8 >= 8:
    var v: byte = 0x40
    if dst.uint8 >= 8: v = v or 0x04
    if src.uint8 >= 8: v = v or 0x01
    buf.emit(v)
  buf.emit(0x0F); buf.emit(0xBF)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

# ---- Immediate loads (smart) ----

proc movImmX64*(buf: var X64AsmBuffer, dst: X64Reg, imm: int64) =
  ## Load immediate: picks imm32 or imm64 encoding based on value
  if imm >= int32.low.int64 and imm <= int32.high.int64:
    buf.movRegImm32(dst, imm.int32)
  else:
    buf.movRegImm64(dst, cast[uint64](imm))

proc addImmX64*(buf: var X64AsmBuffer, dst: X64Reg, imm: int32) =
  ## ADD dst, imm32
  buf.addRegImm32(dst, imm)

proc andRegImm32*(buf: var X64AsmBuffer, dst: X64Reg, imm: int32) = buf.aluRegImm32(dst, imm, 4)
proc orRegImm32*(buf: var X64AsmBuffer, dst: X64Reg, imm: int32)  = buf.aluRegImm32(dst, imm, 1)
proc xorRegImm32*(buf: var X64AsmBuffer, dst: X64Reg, imm: int32) = buf.aluRegImm32(dst, imm, 6)

# ---- Arithmetic (register-register, 64-bit) ----

proc mulRegX64*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## IMUL dst, src (64-bit, two-operand form: dst *= src)
  buf.emit(rex(w = true, r = dst, b = src))
  buf.emit(0x0F)
  buf.emit(0xAF)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc cqoX64*(buf: var X64AsmBuffer) =
  ## CQO: sign-extend RAX into RDX:RAX (REX.W + 0x99)
  buf.emit(rex(w = true))
  buf.emit(0x99)

proc sdivRegX64*(buf: var X64AsmBuffer, divisor: X64Reg) =
  ## Signed divide RDX:RAX by divisor. Quotient in RAX, remainder in RDX.
  ## Caller must place dividend in RAX and call cqoX64 first.
  buf.emit(rex(w = true, b = divisor))
  buf.emit(0xF7)
  buf.emit(modRM(0b11, 7, divisor.uint8))

proc udivRegX64*(buf: var X64AsmBuffer, divisor: X64Reg) =
  ## Unsigned divide RDX:RAX by divisor. Quotient in RAX, remainder in RDX.
  ## Caller must zero RDX first (xor rdx, rdx).
  buf.emit(rex(w = true, b = divisor))
  buf.emit(0xF7)
  buf.emit(modRM(0b11, 6, divisor.uint8))

proc andRegX64*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## AND dst, src (64-bit)
  buf.emit(rex(w = true, r = src, b = dst))
  buf.emit(0x21)
  buf.emit(modRM(0b11, src.uint8, dst.uint8))

proc orRegX64*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## OR dst, src (64-bit)
  buf.emit(rex(w = true, r = src, b = dst))
  buf.emit(0x09)
  buf.emit(modRM(0b11, src.uint8, dst.uint8))

proc xorRegX64*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## XOR dst, src (64-bit)
  buf.emit(rex(w = true, r = src, b = dst))
  buf.emit(0x31)
  buf.emit(modRM(0b11, src.uint8, dst.uint8))

proc testRegReg*(buf: var X64AsmBuffer, a, b: X64Reg) =
  ## TEST a, b (64-bit, sets flags = a AND b)
  buf.emit(rex(w = true, r = b, b = a))
  buf.emit(0x85)
  buf.emit(modRM(0b11, b.uint8, a.uint8))

proc testRegImm32*(buf: var X64AsmBuffer, reg: X64Reg, imm: int32) =
  ## TEST reg, imm32
  buf.emit(rex(w = true, b = reg))
  if reg == rax:
    buf.emit(0xA9)
  else:
    buf.emit(0xF7)
    buf.emit(modRM(0b11, 0, reg.uint8))
  buf.emitImm32(imm)

# ---- Unary arithmetic ----

proc negRegX64*(buf: var X64AsmBuffer, reg: X64Reg) =
  ## NEG reg (64-bit, reg = -reg)
  buf.emit(rex(w = true, b = reg))
  buf.emit(0xF7)
  buf.emit(modRM(0b11, 3, reg.uint8))

proc notRegX64*(buf: var X64AsmBuffer, reg: X64Reg) =
  ## NOT reg (64-bit, reg = ~reg)
  buf.emit(rex(w = true, b = reg))
  buf.emit(0xF7)
  buf.emit(modRM(0b11, 2, reg.uint8))

proc incReg*(buf: var X64AsmBuffer, reg: X64Reg) =
  ## INC reg (64-bit)
  buf.emit(rex(w = true, b = reg))
  buf.emit(0xFF)
  buf.emit(modRM(0b11, 0, reg.uint8))

proc decReg*(buf: var X64AsmBuffer, reg: X64Reg) =
  ## DEC reg (64-bit)
  buf.emit(rex(w = true, b = reg))
  buf.emit(0xFF)
  buf.emit(modRM(0b11, 1, reg.uint8))

# ---- Shifts (by CL register) ----

proc shlRegX64*(buf: var X64AsmBuffer, dst: X64Reg) =
  ## SHL dst, CL (64-bit, shift left by CL)
  buf.emit(rex(w = true, b = dst))
  buf.emit(0xD3)
  buf.emit(modRM(0b11, 4, dst.uint8))

proc shrRegX64*(buf: var X64AsmBuffer, dst: X64Reg) =
  ## SHR dst, CL (64-bit, logical shift right by CL)
  buf.emit(rex(w = true, b = dst))
  buf.emit(0xD3)
  buf.emit(modRM(0b11, 5, dst.uint8))

proc sarRegX64*(buf: var X64AsmBuffer, dst: X64Reg) =
  ## SAR dst, CL (64-bit, arithmetic shift right by CL)
  buf.emit(rex(w = true, b = dst))
  buf.emit(0xD3)
  buf.emit(modRM(0b11, 7, dst.uint8))

proc rolRegX64*(buf: var X64AsmBuffer, dst: X64Reg) =
  ## ROL dst, CL (64-bit, rotate left by CL)
  buf.emit(rex(w = true, b = dst))
  buf.emit(0xD3)
  buf.emit(modRM(0b11, 0, dst.uint8))

proc rorRegX64*(buf: var X64AsmBuffer, dst: X64Reg) =
  ## ROR dst, CL (64-bit, rotate right by CL)
  buf.emit(rex(w = true, b = dst))
  buf.emit(0xD3)
  buf.emit(modRM(0b11, 1, dst.uint8))

# ---- Shifts (by immediate) ----

proc shiftRegImm(buf: var X64AsmBuffer, dst: X64Reg, imm: byte, regField: byte) {.inline.} =
  ## Generic shift/rotate by immediate: SHL/SHR/SAR/ROL/ROR dst, imm8 (64-bit)
  buf.emit(rex(w = true, b = dst))
  if imm == 1:
    buf.emit(0xD1)
  else:
    buf.emit(0xC1)
  buf.emit(modRM(0b11, regField, dst.uint8))
  if imm != 1: buf.emit(imm)

proc shlRegImm*(buf: var X64AsmBuffer, dst: X64Reg, imm: byte) = buf.shiftRegImm(dst, imm, 4)
proc shrRegImm*(buf: var X64AsmBuffer, dst: X64Reg, imm: byte) = buf.shiftRegImm(dst, imm, 5)
proc sarRegImm*(buf: var X64AsmBuffer, dst: X64Reg, imm: byte) = buf.shiftRegImm(dst, imm, 7)
proc rolRegImm*(buf: var X64AsmBuffer, dst: X64Reg, imm: byte) = buf.shiftRegImm(dst, imm, 0)
proc rorRegImm*(buf: var X64AsmBuffer, dst: X64Reg, imm: byte) = buf.shiftRegImm(dst, imm, 1)

# ---- Comparison ----

proc setccX64*(buf: var X64AsmBuffer, cond: X64Cond, dst: X64Reg) =
  ## SETcc dst(8) — set byte to 1 if condition true, else 0
  if needsRex(dst) or dst.uint8 in {4'u8, 5, 6, 7}:
    buf.emit(rex(w = false, b = dst))
  buf.emit(0x0F)
  buf.emit(0x90 + cond.byte)
  buf.emit(modRM(0b11, 0, dst.uint8))

proc cmovX64*(buf: var X64AsmBuffer, cond: X64Cond, dst, src: X64Reg) =
  ## CMOVcc dst, src (64-bit, conditional move)
  buf.emit(rex(w = true, r = dst, b = src))
  buf.emit(0x0F)
  buf.emit(0x40 + cond.byte)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

# ---- Control flow ----

proc jmpRegX64*(buf: var X64AsmBuffer, reg: X64Reg) =
  ## JMP reg (indirect jump)
  if needsRex(reg):
    buf.emit(0x41)
  buf.emit(0xFF)
  buf.emit(modRM(0b11, 4, reg.uint8))

proc jmpRel8*(buf: var X64AsmBuffer, offset: int8) =
  ## JMP rel8 (short jump)
  buf.emit(0xEB)
  buf.emit(cast[byte](offset))

proc jccRel8*(buf: var X64AsmBuffer, cond: X64Cond, offset: int8) =
  ## Jcc rel8 (short conditional jump)
  buf.emit(0x70 + cond.byte)
  buf.emit(cast[byte](offset))

# ---- Stack ----

proc pushImm32*(buf: var X64AsmBuffer, imm: int32) =
  ## PUSH imm32 (sign-extended to 64-bit)
  if imm >= -128 and imm <= 127:
    buf.emit(0x6A)
    buf.emit(cast[byte](imm))
  else:
    buf.emit(0x68)
    buf.emitImm32(imm)

# ---- Misc ----

proc nopX64*(buf: var X64AsmBuffer) =
  ## NOP — alias for nop
  buf.nop()

proc int3*(buf: var X64AsmBuffer) =
  ## INT3 — breakpoint
  buf.emit(0xCC)

proc ud2*(buf: var X64AsmBuffer) =
  ## UD2 — undefined instruction trap
  buf.emit(0x0F)
  buf.emit(0x0B)

proc leaRegMem*(buf: var X64AsmBuffer, dst, base: X64Reg, offset: int32) =
  ## LEA dst, [base + offset]
  buf.emit(rex(w = true, r = dst, b = base))
  buf.emit(0x8D)
  buf.emitModRMMem(dst.uint8, base, offset)

proc xchgRegReg*(buf: var X64AsmBuffer, a, b: X64Reg) =
  ## XCHG a, b (64-bit)
  buf.emit(rex(w = true, r = b, b = a))
  buf.emit(0x87)
  buf.emit(modRM(0b11, b.uint8, a.uint8))

# ---- Bit operations ----

proc bsrX64*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## BSR dst, src (bit scan reverse — index of highest set bit)
  buf.emit(rex(w = true, r = dst, b = src))
  buf.emit(0x0F)
  buf.emit(0xBD)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc bsfX64*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## BSF dst, src (bit scan forward — index of lowest set bit)
  buf.emit(rex(w = true, r = dst, b = src))
  buf.emit(0x0F)
  buf.emit(0xBC)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc lzcntX64*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## LZCNT dst, src (leading zero count, requires BMI1/ABM)
  buf.emit(0xF3)
  buf.emit(rex(w = true, r = dst, b = src))
  buf.emit(0x0F)
  buf.emit(0xBD)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc tzcntX64*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## TZCNT dst, src (trailing zero count, requires BMI1/ABM)
  buf.emit(0xF3)
  buf.emit(rex(w = true, r = dst, b = src))
  buf.emit(0x0F)
  buf.emit(0xBC)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc popcntX64*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## POPCNT dst, src (population count, requires POPCNT/ABM)
  buf.emit(0xF3)
  buf.emit(rex(w = true, r = dst, b = src))
  buf.emit(0x0F)
  buf.emit(0xB8)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc clzX64*(buf: var X64AsmBuffer, dst, src: X64Reg, scratch: X64Reg) =
  ## CLZ via BSR + XOR (portable, no BMI1 required).
  ## Result in dst. If src==0 result is 64.
  ## Uses scratch for the XOR constant. dst and scratch must not be src.
  ## Sequence: BSR dst, src; XOR dst, 63; CMOV if ZF (src==0) dst = 64
  buf.movRegImm32(scratch, 64)
  buf.bsrX64(dst, src)
  # BSR sets ZF if src==0; if not zero, result is bit index
  buf.cmovX64(x64condE, dst, scratch)  # if ZF, dst=64
  # BSR gives index of highest bit; CLZ = 63 - BSR result
  # Only XOR if src was nonzero (otherwise dst is already 64)
  # We need: if src != 0: dst = 63 - dst
  # Use a conditional approach: XOR then CMOV back
  buf.xorRegImm32(dst, 63)
  # If src was zero, ZF was set by BSR and the CMOV above already set dst=64.
  # But XOR cleared ZF. We need to re-test.
  buf.testRegReg(src, src)
  buf.cmovX64(x64condE, dst, scratch)  # if src==0, dst=64

proc ctzX64*(buf: var X64AsmBuffer, dst, src: X64Reg, scratch: X64Reg) =
  ## CTZ via BSF (portable, no BMI1 required).
  ## Result in dst. If src==0 result is 64.
  buf.movRegImm32(scratch, 64)
  buf.bsfX64(dst, src)
  buf.cmovX64(x64condE, dst, scratch)  # if ZF (src==0), dst=64

# ---- Patching ----

proc patchImm32At*(buf: var X64AsmBuffer, offset: int, v: int32) =
  ## Patch a 32-bit immediate at the given byte offset in the code buffer.
  let u = cast[uint32](v)
  buf.code[offset]     = byte(u and 0xFF)
  buf.code[offset + 1] = byte((u shr 8) and 0xFF)
  buf.code[offset + 2] = byte((u shr 16) and 0xFF)
  buf.code[offset + 3] = byte((u shr 24) and 0xFF)

proc patchAtX64*(buf: var X64AsmBuffer, patchOffset: int) =
  ## Patch a rel32 at patchOffset so the branch targets buf.pos().
  ## The rel32 sits at code[patchOffset..patchOffset+3].
  ## Branch displacement is relative to the instruction *after* the rel32.
  let target = buf.pos
  let rel = int32(target - (patchOffset + 4))
  buf.patchImm32At(patchOffset, rel)

proc patchJmpAt*(buf: var X64AsmBuffer, jmpInstrOffset: int) =
  ## Patch a JMP rel32 whose opcode byte is at jmpInstrOffset.
  ## The rel32 starts at jmpInstrOffset+1.
  buf.patchAtX64(jmpInstrOffset + 1)

proc patchJccAt*(buf: var X64AsmBuffer, jccInstrOffset: int) =
  ## Patch a Jcc rel32 whose 0x0F byte is at jccInstrOffset.
  ## The rel32 starts at jccInstrOffset+2.
  buf.patchAtX64(jccInstrOffset + 2)

proc patchCallAt*(buf: var X64AsmBuffer, callInstrOffset: int) =
  ## Patch a CALL rel32 whose opcode byte is at callInstrOffset.
  buf.patchAtX64(callInstrOffset + 1)

# ---- 32-bit arithmetic variants ----

proc addRegReg32*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## ADD dst(32), src(32)
  if needsRex(dst) or needsRex(src):
    buf.emit(rex(w = false, r = src, b = dst))
  buf.emit(0x01)
  buf.emit(modRM(0b11, src.uint8, dst.uint8))

proc subRegReg32*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## SUB dst(32), src(32)
  if needsRex(dst) or needsRex(src):
    buf.emit(rex(w = false, r = src, b = dst))
  buf.emit(0x29)
  buf.emit(modRM(0b11, src.uint8, dst.uint8))

proc mulRegX6432*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## IMUL dst(32), src(32)
  if needsRex(dst) or needsRex(src):
    buf.emit(rex(w = false, r = dst, b = src))
  buf.emit(0x0F)
  buf.emit(0xAF)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc andRegReg32*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## AND dst(32), src(32)
  if needsRex(dst) or needsRex(src):
    buf.emit(rex(w = false, r = src, b = dst))
  buf.emit(0x21)
  buf.emit(modRM(0b11, src.uint8, dst.uint8))

proc orRegReg32*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## OR dst(32), src(32)
  if needsRex(dst) or needsRex(src):
    buf.emit(rex(w = false, r = src, b = dst))
  buf.emit(0x09)
  buf.emit(modRM(0b11, src.uint8, dst.uint8))

proc xorRegReg32*(buf: var X64AsmBuffer, dst, src: X64Reg) =
  ## XOR dst(32), src(32)
  if needsRex(dst) or needsRex(src):
    buf.emit(rex(w = false, r = src, b = dst))
  buf.emit(0x31)
  buf.emit(modRM(0b11, src.uint8, dst.uint8))

proc cmpRegReg32*(buf: var X64AsmBuffer, a, b: X64Reg) =
  ## CMP a(32), b(32)
  if needsRex(a) or needsRex(b):
    buf.emit(rex(w = false, r = b, b = a))
  buf.emit(0x39)
  buf.emit(modRM(0b11, b.uint8, a.uint8))

proc cdqX64*(buf: var X64AsmBuffer) =
  ## CDQ: sign-extend EAX into EDX:EAX (for 32-bit IDIV)
  buf.emit(0x99)

proc sdivRegX6432*(buf: var X64AsmBuffer, divisor: X64Reg) =
  ## IDIV r/m32 — signed divide EDX:EAX by divisor(32)
  if needsRex(divisor):
    buf.emit(rex(w = false, b = divisor))
  buf.emit(0xF7)
  buf.emit(modRM(0b11, 7, divisor.uint8))

proc udivRegX6432*(buf: var X64AsmBuffer, divisor: X64Reg) =
  ## DIV r/m32 — unsigned divide EDX:EAX by divisor(32)
  if needsRex(divisor):
    buf.emit(rex(w = false, b = divisor))
  buf.emit(0xF7)
  buf.emit(modRM(0b11, 6, divisor.uint8))

proc shiftRegCL32(buf: var X64AsmBuffer, dst: X64Reg, regField: byte) {.inline.} =
  ## Generic 32-bit shift/rotate by CL register
  if needsRex(dst):
    buf.emit(rex(w = false, b = dst))
  buf.emit(0xD3)
  buf.emit(modRM(0b11, regField, dst.uint8))

proc shlRegX6432*(buf: var X64AsmBuffer, dst: X64Reg) = buf.shiftRegCL32(dst, 4)
proc shrRegX6432*(buf: var X64AsmBuffer, dst: X64Reg) = buf.shiftRegCL32(dst, 5)
proc sarRegX6432*(buf: var X64AsmBuffer, dst: X64Reg) = buf.shiftRegCL32(dst, 7)
proc rolRegX6432*(buf: var X64AsmBuffer, dst: X64Reg) = buf.shiftRegCL32(dst, 0)
proc rorRegX6432*(buf: var X64AsmBuffer, dst: X64Reg) = buf.shiftRegCL32(dst, 1)

# ---- Prologue / Epilogue helpers ----

proc emitPrologue*(buf: var X64AsmBuffer, frameSize: int32 = 0) =
  ## Standard SysV AMD64 prologue: push rbp; mov rbp, rsp; sub rsp, frameSize
  buf.pushReg(rbp)
  buf.movRegReg(rbp, rsp)
  if frameSize > 0:
    buf.subRegImm32(rsp, frameSize)

proc emitEpilogue*(buf: var X64AsmBuffer) =
  ## Standard epilogue: mov rsp, rbp; pop rbp; ret
  buf.movRegReg(rsp, rbp)
  buf.popReg(rbp)
  buf.ret()

# ---- x86_64 JIT memory (simpler than ARM — no W^X dance) ----

when defined(linux) or defined(macosx):
  proc mmapX64*(size: int): pointer =
    const PROT_READ = 0x01
    const PROT_WRITE = 0x02
    const PROT_EXEC = 0x04
    const MAP_PRIVATE = 0x0002
    const MAP_ANON = when defined(macosx): 0x1000 else: 0x0020

    proc mmap(addr0: pointer, len: csize_t, prot, flags, fd: cint,
              offset: clong): pointer {.importc, header: "<sys/mman.h>".}

    let p = mmap(nil, size.csize_t,
                 PROT_READ or PROT_WRITE or PROT_EXEC,
                 MAP_PRIVATE or MAP_ANON, -1, 0)
    if cast[int](p) == -1:
      raise newException(OSError, "mmap failed for x64 JIT")
    p

# ---- SSE2 / SSE4.1 scalar float helpers ----
# All float values are kept in GP registers as bit patterns (zero-extended).
# XMM0-XMM2 are used as ephemeral scratch registers during computations.

proc rexSseXX(buf: var X64AsmBuffer, dst, src: X64FReg) {.inline.} =
  ## Emit REX prefix for XMM-XMM if needed (dst in reg field, src in rm field).
  if dst.uint8 >= 8 or src.uint8 >= 8:
    var v: byte = 0x40
    if dst.uint8 >= 8: v = v or 0x04  # REX.R extends reg (dst xmm)
    if src.uint8 >= 8: v = v or 0x01  # REX.B extends rm  (src xmm)
    buf.emit(v)

proc rexSseXG(buf: var X64AsmBuffer, xmm: X64FReg, gp: X64Reg, w: bool = false) {.inline.} =
  ## Emit REX for XMM in reg field, GP in rm field.
  if xmm.uint8 >= 8 or gp.uint8 >= 8 or w:
    var v: byte = 0x40
    if w: v = v or 0x08               # REX.W for 64-bit GP operand
    if xmm.uint8 >= 8: v = v or 0x04  # REX.R extends reg (xmm)
    if gp.uint8 >= 8:  v = v or 0x01  # REX.B extends rm  (gp)
    buf.emit(v)

proc rexSseGX(buf: var X64AsmBuffer, gp: X64Reg, xmm: X64FReg, w: bool = false) {.inline.} =
  ## Emit REX for GP in reg field, XMM in rm field (used by CVTTSS2SI etc.).
  if gp.uint8 >= 8 or xmm.uint8 >= 8 or w:
    var v: byte = 0x40
    if w: v = v or 0x08               # REX.W for 64-bit result
    if gp.uint8 >= 8:  v = v or 0x04  # REX.R extends reg (gp)
    if xmm.uint8 >= 8: v = v or 0x01  # REX.B extends rm  (xmm)
    buf.emit(v)

# ---- MOVD / MOVQ (GP ↔ XMM) ----

proc movdFromGp32*(buf: var X64AsmBuffer, dst: X64FReg, src: X64Reg) =
  ## MOVD xmm, r32  (66 [REX?] 0F 6E /r) — load 32-bit GP into XMM
  buf.emit(0x66)
  buf.rexSseXG(dst, src)
  buf.emit(0x0F); buf.emit(0x6E)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc movqFromGp64*(buf: var X64AsmBuffer, dst: X64FReg, src: X64Reg) =
  ## MOVQ xmm, r64  (66 REX.W 0F 6E /r) — load 64-bit GP into XMM
  buf.emit(0x66)
  buf.rexSseXG(dst, src, w = true)
  buf.emit(0x0F); buf.emit(0x6E)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc movdToGp32*(buf: var X64AsmBuffer, dst: X64Reg, src: X64FReg) =
  ## MOVD r32, xmm  (66 [REX?] 0F 7E /r) — copy XMM low dword to GP (zero-extends)
  buf.emit(0x66)
  buf.rexSseXG(src, dst)
  buf.emit(0x0F); buf.emit(0x7E)
  buf.emit(modRM(0b11, src.uint8, dst.uint8))

proc movqToGp64*(buf: var X64AsmBuffer, dst: X64Reg, src: X64FReg) =
  ## MOVQ r64, xmm  (66 REX.W 0F 7E /r) — copy XMM low qword to GP
  buf.emit(0x66)
  buf.rexSseXG(src, dst, w = true)
  buf.emit(0x0F); buf.emit(0x7E)
  buf.emit(modRM(0b11, src.uint8, dst.uint8))

# ---- SSE2 scalar float helpers ----

proc sseF32RR*(buf: var X64AsmBuffer, opc: byte, dst, src: X64FReg) {.inline.} =
  ## F3 [REX?] 0F opc ModRM — generic scalar f32 XMM-XMM instruction
  buf.emit(0xF3)
  buf.rexSseXX(dst, src)
  buf.emit(0x0F); buf.emit(opc)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc sseF64RR*(buf: var X64AsmBuffer, opc: byte, dst, src: X64FReg) {.inline.} =
  ## F2 [REX?] 0F opc ModRM — generic scalar f64 XMM-XMM instruction
  buf.emit(0xF2)
  buf.rexSseXX(dst, src)
  buf.emit(0x0F); buf.emit(opc)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc addss*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sseF32RR(0x58, dst, src)
proc subss*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sseF32RR(0x5C, dst, src)
proc mulss*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sseF32RR(0x59, dst, src)
proc divss*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sseF32RR(0x5E, dst, src)
proc sqrtss*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sseF32RR(0x51, dst, src)
proc minss*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sseF32RR(0x5D, dst, src)
proc maxss*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sseF32RR(0x5F, dst, src)
proc cvtss2sd*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sseF32RR(0x5A, dst, src)

proc addsd*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sseF64RR(0x58, dst, src)
proc subsd*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sseF64RR(0x5C, dst, src)
proc mulsd*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sseF64RR(0x59, dst, src)
proc divsd*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sseF64RR(0x5E, dst, src)
proc sqrtsd*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sseF64RR(0x51, dst, src)
proc minsd*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sseF64RR(0x5D, dst, src)
proc maxsd*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sseF64RR(0x5F, dst, src)
proc cvtsd2ss*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sseF64RR(0x5A, dst, src)

# ---- Float comparisons ----

proc ucomiss*(buf: var X64AsmBuffer, a, b: X64FReg) =
  ## UCOMISS a, b  (0F 2E /r) — sets ZF/CF/PF for ordered comparison; PF=1 if NaN
  buf.rexSseXX(a, b)
  buf.emit(0x0F); buf.emit(0x2E)
  buf.emit(modRM(0b11, a.uint8, b.uint8))

proc ucomisd*(buf: var X64AsmBuffer, a, b: X64FReg) =
  ## UCOMISD a, b  (66 0F 2E /r) — as UCOMISS but for f64
  buf.emit(0x66)
  buf.rexSseXX(a, b)
  buf.emit(0x0F); buf.emit(0x2E)
  buf.emit(modRM(0b11, a.uint8, b.uint8))

# ---- Int ↔ Float conversions ----

proc cvtsi2ss32*(buf: var X64AsmBuffer, dst: X64FReg, src: X64Reg) =
  ## CVTSI2SS xmm, r32  (F3 0F 2A /r) — signed i32 → f32
  buf.emit(0xF3); buf.rexSseXG(dst, src)
  buf.emit(0x0F); buf.emit(0x2A)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc cvtsi2ss64*(buf: var X64AsmBuffer, dst: X64FReg, src: X64Reg) =
  ## CVTSI2SS xmm, r64  (F3 REX.W 0F 2A /r) — signed i64 → f32
  buf.emit(0xF3); buf.rexSseXG(dst, src, w = true)
  buf.emit(0x0F); buf.emit(0x2A)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc cvtsi2sd32*(buf: var X64AsmBuffer, dst: X64FReg, src: X64Reg) =
  ## CVTSI2SD xmm, r32  (F2 0F 2A /r) — signed i32 → f64
  buf.emit(0xF2); buf.rexSseXG(dst, src)
  buf.emit(0x0F); buf.emit(0x2A)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc cvtsi2sd64*(buf: var X64AsmBuffer, dst: X64FReg, src: X64Reg) =
  ## CVTSI2SD xmm, r64  (F2 REX.W 0F 2A /r) — signed i64 → f64
  buf.emit(0xF2); buf.rexSseXG(dst, src, w = true)
  buf.emit(0x0F); buf.emit(0x2A)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc cvttss2si32*(buf: var X64AsmBuffer, dst: X64Reg, src: X64FReg) =
  ## CVTTSS2SI r32, xmm  (F3 0F 2C /r) — f32 → signed i32 (truncate)
  buf.emit(0xF3); buf.rexSseGX(dst, src)
  buf.emit(0x0F); buf.emit(0x2C)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc cvttss2si64*(buf: var X64AsmBuffer, dst: X64Reg, src: X64FReg) =
  ## CVTTSS2SI r64, xmm  (F3 REX.W 0F 2C /r) — f32 → signed i64 (truncate)
  buf.emit(0xF3); buf.rexSseGX(dst, src, w = true)
  buf.emit(0x0F); buf.emit(0x2C)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc cvttsd2si32*(buf: var X64AsmBuffer, dst: X64Reg, src: X64FReg) =
  ## CVTTSD2SI r32, xmm  (F2 0F 2C /r) — f64 → signed i32 (truncate)
  buf.emit(0xF2); buf.rexSseGX(dst, src)
  buf.emit(0x0F); buf.emit(0x2C)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc cvttsd2si64*(buf: var X64AsmBuffer, dst: X64Reg, src: X64FReg) =
  ## CVTTSD2SI r64, xmm  (F2 REX.W 0F 2C /r) — f64 → signed i64 (truncate)
  buf.emit(0xF2); buf.rexSseGX(dst, src, w = true)
  buf.emit(0x0F); buf.emit(0x2C)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

# ---- SSE4.1 rounding ----

proc sseRound(buf: var X64AsmBuffer, opc: byte, dst, src: X64FReg, imm: byte) =
  ## 66 [REX?] 0F 3A opc ModRM imm8 — SSE4.1 ROUNDSS/ROUNDSD
  buf.emit(0x66)
  buf.rexSseXX(dst, src)
  buf.emit(0x0F); buf.emit(0x3A); buf.emit(opc)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))
  buf.emit(imm)

proc roundss*(buf: var X64AsmBuffer, dst, src: X64FReg, imm: byte) =
  ## ROUNDSS xmm, xmm, imm8 (SSE4.1) — imm: 0=nearest, 1=floor, 2=ceil, 3=trunc
  buf.sseRound(0x0A, dst, src, imm)

proc roundsd*(buf: var X64AsmBuffer, dst, src: X64FReg, imm: byte) =
  ## ROUNDSD xmm, xmm, imm8 (SSE4.1) — imm: 0=nearest, 1=floor, 2=ceil, 3=trunc
  buf.sseRound(0x0B, dst, src, imm)

# ===========================================================================
# SSE2 / SSSE3 / SSE4.1 packed 128-bit (v128) instructions
# ===========================================================================
#
# Additional XMM registers for v128 SIMD allocation (beyond xmm0-xmm3).
const
  xmm4*  = X64FReg(4)
  xmm5*  = X64FReg(5)
  xmm6*  = X64FReg(6)
  xmm7*  = X64FReg(7)
  xmm8*  = X64FReg(8)
  xmm9*  = X64FReg(9)
  xmm10* = X64FReg(10)
  xmm11* = X64FReg(11)
  xmm12* = X64FReg(12)
  xmm13* = X64FReg(13)
  xmm14* = X64FReg(14)
  xmm15* = X64FReg(15)

# ---------------------------------------------------------------------------
# Low-level encoding helpers for packed SSE instructions
# ---------------------------------------------------------------------------

proc sse2PackedRR(buf: var X64AsmBuffer, opc: byte, dst, src: X64FReg) {.inline.} =
  ## 66 [REX?] 0F opc ModRM — SSE2 packed XMM-XMM instruction
  buf.emit(0x66)
  buf.rexSseXX(dst, src)
  buf.emit(0x0F); buf.emit(opc)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc sse2PackedRM(buf: var X64AsmBuffer, opc: byte, dst: X64FReg,
                  base: X64Reg, offset: int32) {.inline.} =
  ## 66 [REX?] 0F opc ModRM — SSE2 packed load from memory [base+offset]
  buf.emit(0x66)
  if dst.uint8 >= 8 or base.uint8 >= 8:
    var v: byte = 0x40
    if dst.uint8  >= 8: v = v or 0x04  # REX.R
    if base.uint8 >= 8: v = v or 0x01  # REX.B
    buf.emit(v)
  buf.emit(0x0F); buf.emit(opc)
  buf.emitModRMMem(dst.uint8, base, offset)

proc sse2PackedMR(buf: var X64AsmBuffer, opc: byte, base: X64Reg,
                  offset: int32, src: X64FReg) {.inline.} =
  ## 66 [REX?] 0F opc ModRM — SSE2 packed store to memory [base+offset]
  buf.emit(0x66)
  if src.uint8 >= 8 or base.uint8 >= 8:
    var v: byte = 0x40
    if src.uint8  >= 8: v = v or 0x04  # REX.R
    if base.uint8 >= 8: v = v or 0x01  # REX.B
    buf.emit(v)
  buf.emit(0x0F); buf.emit(opc)
  buf.emitModRMMem(src.uint8, base, offset)

proc ssse3PackedRR(buf: var X64AsmBuffer, opc: byte, dst, src: X64FReg) {.inline.} =
  ## 66 [REX?] 0F 38 opc ModRM — SSSE3/SSE4.1 packed XMM-XMM instruction
  buf.emit(0x66)
  buf.rexSseXX(dst, src)
  buf.emit(0x0F); buf.emit(0x38); buf.emit(opc)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

proc sse41PackedRRI(buf: var X64AsmBuffer, opc: byte,
                    dst, src: X64FReg, imm: byte) {.inline.} =
  ## 66 [REX?] 0F 3A opc ModRM imm8 — SSE4.1 packed extract/insert
  buf.emit(0x66)
  buf.rexSseXX(dst, src)
  buf.emit(0x0F); buf.emit(0x3A); buf.emit(opc)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))
  buf.emit(imm)

proc sse41PackedGRI(buf: var X64AsmBuffer, opc: byte,
                    dst: X64Reg, src: X64FReg, imm: byte) {.inline.} =
  ## 66 [REX?] 0F 3A opc ModRM imm8 — SSE4.1 extract to GP register
  ## dst = GP register (in rm field), src = XMM (in reg field)
  buf.emit(0x66)
  if src.uint8 >= 8 or dst.uint8 >= 8:
    var v: byte = 0x40
    if src.uint8 >= 8: v = v or 0x04  # REX.R (reg = src xmm)
    if dst.uint8 >= 8: v = v or 0x01  # REX.B (rm  = dst gp)
    buf.emit(v)
  buf.emit(0x0F); buf.emit(0x3A); buf.emit(opc)
  buf.emit(modRM(0b11, src.uint8, dst.uint8))
  buf.emit(imm)

proc sse41PackedRGI(buf: var X64AsmBuffer, opc: byte,
                    dst: X64FReg, src: X64Reg, imm: byte) {.inline.} =
  ## 66 [REX?] 0F 3A opc ModRM imm8 — SSE4.1 insert from GP register
  ## dst = XMM (in reg field), src = GP (in rm field)
  buf.emit(0x66)
  if dst.uint8 >= 8 or src.uint8 >= 8:
    var v: byte = 0x40
    if dst.uint8 >= 8: v = v or 0x04  # REX.R (reg = dst xmm)
    if src.uint8 >= 8: v = v or 0x01  # REX.B (rm  = src gp)
    buf.emit(v)
  buf.emit(0x0F); buf.emit(0x3A); buf.emit(opc)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))
  buf.emit(imm)

# ---------------------------------------------------------------------------
# MOVDQU — unaligned 128-bit load/store
# ---------------------------------------------------------------------------

proc movdquLoad*(buf: var X64AsmBuffer, dst: X64FReg, base: X64Reg,
                 offset: int32 = 0) =
  ## MOVDQU xmm, [base+offset]  (F3 [REX?] 0F 6F /r)
  buf.emit(0xF3)
  if dst.uint8 >= 8 or base.uint8 >= 8:
    var v: byte = 0x40
    if dst.uint8  >= 8: v = v or 0x04
    if base.uint8 >= 8: v = v or 0x01
    buf.emit(v)
  buf.emit(0x0F); buf.emit(0x6F)
  buf.emitModRMMem(dst.uint8, base, offset)

proc movdquStore*(buf: var X64AsmBuffer, base: X64Reg, offset: int32,
                  src: X64FReg) =
  ## MOVDQU [base+offset], xmm  (F3 [REX?] 0F 7F /r)
  buf.emit(0xF3)
  if src.uint8 >= 8 or base.uint8 >= 8:
    var v: byte = 0x40
    if src.uint8  >= 8: v = v or 0x04
    if base.uint8 >= 8: v = v or 0x01
    buf.emit(v)
  buf.emit(0x0F); buf.emit(0x7F)
  buf.emitModRMMem(src.uint8, base, offset)

proc movdqaRR*(buf: var X64AsmBuffer, dst, src: X64FReg) =
  ## MOVDQA xmm, xmm  (66 [REX?] 0F 6F /r) — copy XMM register
  buf.sse2PackedRR(0x6F, dst, src)

# ---------------------------------------------------------------------------
# SSE2 bitwise
# ---------------------------------------------------------------------------
proc pandRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0xDB, dst, src)
proc porRR*(buf: var X64AsmBuffer, dst, src: X64FReg)  = buf.sse2PackedRR(0xEB, dst, src)
proc pxorRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0xEF, dst, src)
proc pandnRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0xDF, dst, src)
  ## PANDN dst, src — dst = (~dst) & src (SSE2)

# ---------------------------------------------------------------------------
# SSE2 i8x16
# ---------------------------------------------------------------------------
proc paddbRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0xFC, dst, src)
proc psubbRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0xF8, dst, src)
proc pminubRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0xDA, dst, src)
proc pmaxubRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0xDE, dst, src)
proc pabsbRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.ssse3PackedRR(0x1C, dst, src)
proc pminsb*(buf: var X64AsmBuffer, dst, src: X64FReg)   = buf.ssse3PackedRR(0x38, dst, src)
proc pmaxsb*(buf: var X64AsmBuffer, dst, src: X64FReg)   = buf.ssse3PackedRR(0x3C, dst, src)
proc punpcklbwRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0x60, dst, src)
proc pshufbRR*(buf: var X64AsmBuffer, dst, src: X64FReg)    = buf.ssse3PackedRR(0x00, dst, src)

proc pextrb*(buf: var X64AsmBuffer, dst: X64Reg, src: X64FReg, lane: byte) =
  ## PEXTRB r32, xmm, imm8  (66 0F 3A 14 /r imm) — SSE4.1
  buf.sse41PackedGRI(0x14, dst, src, lane)

proc pinsrb*(buf: var X64AsmBuffer, dst: X64FReg, src: X64Reg, lane: byte) =
  ## PINSRB xmm, r32, imm8  (66 0F 3A 20 /r imm) — SSE4.1
  buf.sse41PackedRGI(0x20, dst, src, lane)

# ---------------------------------------------------------------------------
# SSE2 i16x8
# ---------------------------------------------------------------------------
proc paddwRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0xFD, dst, src)
proc psubwRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0xF9, dst, src)
proc pmullwRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0xD5, dst, src)
proc pminuwRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.ssse3PackedRR(0x3A, dst, src)
proc pmaxuwRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.ssse3PackedRR(0x3E, dst, src)
proc pminswRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0xEA, dst, src)
proc pmaxswRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0xEE, dst, src)
proc pabswRR*(buf: var X64AsmBuffer, dst, src: X64FReg)  = buf.ssse3PackedRR(0x1D, dst, src)
proc punpcklwdRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0x61, dst, src)

proc pextrw*(buf: var X64AsmBuffer, dst: X64Reg, src: X64FReg, lane: byte) =
  ## PEXTRW r32, xmm, imm8  (66 0F C5 /r imm) — SSE2
  buf.emit(0x66); buf.rexSseXG(src, dst)
  buf.emit(0x0F); buf.emit(0xC5)
  buf.emit(modRM(0b11, src.uint8, dst.uint8))
  buf.emit(lane)

proc pinsrw*(buf: var X64AsmBuffer, dst: X64FReg, src: X64Reg, lane: byte) =
  ## PINSRW xmm, r32, imm8  (66 0F C4 /r imm) — SSE2
  buf.emit(0x66); buf.rexSseXG(dst, src)
  buf.emit(0x0F); buf.emit(0xC4)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))
  buf.emit(lane)

# ---------------------------------------------------------------------------
# SSE2/SSE4.1 i32x4
# ---------------------------------------------------------------------------
proc padddRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0xFE, dst, src)
proc psubdRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0xFA, dst, src)
proc pmulldRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.ssse3PackedRR(0x40, dst, src)
proc pminsdRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.ssse3PackedRR(0x39, dst, src)
proc pmaxsdRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.ssse3PackedRR(0x3D, dst, src)
proc pminudRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.ssse3PackedRR(0x3B, dst, src)
proc pmaxudRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.ssse3PackedRR(0x3F, dst, src)
proc pabsdRR*(buf: var X64AsmBuffer, dst, src: X64FReg)  = buf.ssse3PackedRR(0x1E, dst, src)
proc pcmpeqdRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0x76, dst, src)
  ## PCMPEQD xmm, xmm  (66 0F 76 /r) — compare equal packed i32 lanes → all-ones or zero
proc pshufdRRI*(buf: var X64AsmBuffer, dst, src: X64FReg, imm: byte) =
  ## PSHUFD xmm, xmm, imm8  (66 0F 70 /r imm8)
  buf.emit(0x66); buf.rexSseXX(dst, src)
  buf.emit(0x0F); buf.emit(0x70)
  buf.emit(modRM(0b11, dst.uint8, src.uint8)); buf.emit(imm)

proc pslldImm*(buf: var X64AsmBuffer, dst: X64FReg, imm: byte) =
  ## PSLLD xmm, imm8  (66 0F 72 /6 imm8) — left shift all i32 lanes
  buf.emit(0x66)
  if dst.uint8 >= 8: buf.emit(0x41)
  buf.emit(0x0F); buf.emit(0x72)
  buf.emit(modRM(0b11, 6, dst.uint8)); buf.emit(imm)

proc psrldImm*(buf: var X64AsmBuffer, dst: X64FReg, imm: byte) =
  ## PSRLD xmm, imm8  (66 0F 72 /2 imm8) — logical right shift all i32 lanes
  buf.emit(0x66)
  if dst.uint8 >= 8: buf.emit(0x41)
  buf.emit(0x0F); buf.emit(0x72)
  buf.emit(modRM(0b11, 2, dst.uint8)); buf.emit(imm)

proc psradImm*(buf: var X64AsmBuffer, dst: X64FReg, imm: byte) =
  ## PSRAD xmm, imm8  (66 0F 72 /4 imm8) — arithmetic right shift all i32 lanes
  buf.emit(0x66)
  if dst.uint8 >= 8: buf.emit(0x41)
  buf.emit(0x0F); buf.emit(0x72)
  buf.emit(modRM(0b11, 4, dst.uint8)); buf.emit(imm)

proc pslldRR*(buf: var X64AsmBuffer, dst, cnt: X64FReg) =
  ## PSLLD xmm, xmm  (66 0F F2 /r) — left shift by register (count in low 64 bits)
  buf.sse2PackedRR(0xF2, dst, cnt)

proc psrldRR*(buf: var X64AsmBuffer, dst, cnt: X64FReg) =
  ## PSRLD xmm, xmm  (66 0F D2 /r)
  buf.sse2PackedRR(0xD2, dst, cnt)

proc psradRR*(buf: var X64AsmBuffer, dst, cnt: X64FReg) =
  ## PSRAD xmm, xmm  (66 0F E2 /r)
  buf.sse2PackedRR(0xE2, dst, cnt)

proc pextrdRR*(buf: var X64AsmBuffer, dst: X64Reg, src: X64FReg, lane: byte) =
  ## PEXTRD r32, xmm, imm8  (66 0F 3A 16 /r imm) — SSE4.1
  buf.sse41PackedGRI(0x16, dst, src, lane)

proc pinsrdRR*(buf: var X64AsmBuffer, dst: X64FReg, src: X64Reg, lane: byte) =
  ## PINSRD xmm, r32, imm8  (66 0F 3A 22 /r imm) — SSE4.1
  buf.sse41PackedRGI(0x22, dst, src, lane)

# ---------------------------------------------------------------------------
# SSE2 i64x2
# ---------------------------------------------------------------------------
proc paddqRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0xD4, dst, src)
proc psubqRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0xFB, dst, src)

proc pextrqRR*(buf: var X64AsmBuffer, dst: X64Reg, src: X64FReg, lane: byte) =
  ## PEXTRQ r64, xmm, imm8  (66 REX.W 0F 3A 16 /r imm) — SSE4.1
  buf.emit(0x66)
  var v: byte = 0x48  # REX.W always needed for 64-bit GP
  if src.uint8 >= 8: v = v or 0x04
  if dst.uint8 >= 8: v = v or 0x01
  buf.emit(v)
  buf.emit(0x0F); buf.emit(0x3A); buf.emit(0x16)
  buf.emit(modRM(0b11, src.uint8, dst.uint8)); buf.emit(lane)

proc pinsrqRR*(buf: var X64AsmBuffer, dst: X64FReg, src: X64Reg, lane: byte) =
  ## PINSRQ xmm, r64, imm8  (66 REX.W 0F 3A 22 /r imm) — SSE4.1
  buf.emit(0x66)
  var v: byte = 0x48  # REX.W always needed for 64-bit GP
  if dst.uint8 >= 8: v = v or 0x04
  if src.uint8 >= 8: v = v or 0x01
  buf.emit(v)
  buf.emit(0x0F); buf.emit(0x3A); buf.emit(0x22)
  buf.emit(modRM(0b11, dst.uint8, src.uint8)); buf.emit(lane)

# ---------------------------------------------------------------------------
# SSE2 f32x4
# ---------------------------------------------------------------------------
proc addpsRR*(buf: var X64AsmBuffer, dst, src: X64FReg) =
  ## ADDPS xmm, xmm  (0F 58 /r)
  buf.rexSseXX(dst, src); buf.emit(0x0F); buf.emit(0x58)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))
proc subpsRR*(buf: var X64AsmBuffer, dst, src: X64FReg) =
  buf.rexSseXX(dst, src); buf.emit(0x0F); buf.emit(0x5C)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))
proc mulpsRR*(buf: var X64AsmBuffer, dst, src: X64FReg) =
  buf.rexSseXX(dst, src); buf.emit(0x0F); buf.emit(0x59)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))
proc divpsRR*(buf: var X64AsmBuffer, dst, src: X64FReg) =
  buf.rexSseXX(dst, src); buf.emit(0x0F); buf.emit(0x5E)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))
proc abspsRR*(buf: var X64AsmBuffer, dst, src: X64FReg, signMaskXmm: X64FReg) =
  ## Abs via ANDPS with 0x7FFFFFFF mask (caller must pre-load signMaskXmm)
  if dst != src: buf.movdqaRR(dst, src)
  buf.rexSseXX(dst, signMaskXmm); buf.emit(0x0F); buf.emit(0x54)
  buf.emit(modRM(0b11, dst.uint8, signMaskXmm.uint8))
proc negpsRR*(buf: var X64AsmBuffer, dst, src: X64FReg, signMaskXmm: X64FReg) =
  ## Neg via XORPS with 0x80000000 sign mask (caller pre-loads signMaskXmm)
  if dst != src: buf.movdqaRR(dst, src)
  buf.rexSseXX(dst, signMaskXmm); buf.emit(0x0F); buf.emit(0x57)
  buf.emit(modRM(0b11, dst.uint8, signMaskXmm.uint8))
proc xorpsRR*(buf: var X64AsmBuffer, dst, src: X64FReg) =
  buf.rexSseXX(dst, src); buf.emit(0x0F); buf.emit(0x57)
  buf.emit(modRM(0b11, dst.uint8, src.uint8))

# ---------------------------------------------------------------------------
# SSE2 f64x2
# ---------------------------------------------------------------------------
proc addpdRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0x58, dst, src)
proc subpdRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0x5C, dst, src)
proc mulpdRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0x59, dst, src)
proc divpdRR*(buf: var X64AsmBuffer, dst, src: X64FReg) = buf.sse2PackedRR(0x5E, dst, src)

# ---------------------------------------------------------------------------
# Helper: MOVD xmm, r32 then broadcast to all lanes (splat)
# ---------------------------------------------------------------------------
proc movdToXmm*(buf: var X64AsmBuffer, dst: X64FReg, src: X64Reg) =
  ## MOVD xmm, r32  (alias for movdFromGp32)
  buf.movdFromGp32(dst, src)

proc movqToXmm*(buf: var X64AsmBuffer, dst: X64FReg, src: X64Reg) =
  ## MOVQ xmm, r64  (alias for movqFromGp64)
  buf.movqFromGp64(dst, src)
