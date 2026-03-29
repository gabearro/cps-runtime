## Baseline WASM -> AArch64 JIT compiler
## Uses stack-machine emulation: x8=VSP, x9=locals, x10=memBase, x11=memSize
##
## Value stack layout: all slots are 8 bytes (uint64), x8 points to the next
## free slot (one past the top). Push = store + post-increment, pop = pre-decrement + load.
##
## Function ABI:
##   (x0=vsp: ptr uint64, x1=locals: ptr uint64, x2=memBase: ptr byte, x3=memSize: uint64) -> ptr uint64
##
## Unimplemented opcodes emit BRK #1 (debug trap).

import ../types, ../pgo
import codegen, memory

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

type
  JitCompiledFunc* = object
    code*: JitCode
    funcIdx*: int

  JitFuncPtr* = proc(vsp: ptr uint64, locals: ptr uint64,
                     memBase: ptr byte, memSize: uint64): ptr uint64 {.cdecl.}

  # Label tracking for control flow (block/loop/if)
  LabelKind = enum
    lkBlock   # branch-forward: br jumps to end
    lkLoop    # branch-backward: br jumps to start
    lkIf      # like block but has optional else

  Label = object
    kind: LabelKind
    patchList: seq[int]   # instruction indices needing forward-branch patching
    startPos: int         # instruction index at the label start (for loops)
    elsePos: int          # instruction index of the else-branch placeholder (for if)
    hasElse: bool

  CallTarget* = object
    ## Resolved call target for a WASM function
    jitAddr*: pointer      # JIT code address (nil if not JIT'd)
    paramCount*: int       # number of parameters
    localCount*: int       # total locals (params + body locals)
    resultCount*: int      # number of results
    globalsCount*: int     # number of module globals (appended after locals)

  TableElem* = object
    ## Pre-resolved WASM table element for call_indirect dispatch.
    jitAddr*: pointer    # JIT code address (nil = null element or not JIT'd)
    localCount*: int32   # total locals (params + body locals)
    paramCount*: int32   # number of parameters
    resultCount*: int32  # number of results

  CallIndirectCache* = object
    ## Per-call-site inline cache for call_indirect.
    ## Heap-allocated; address embedded as a constant in JIT code.
    ## The IC only caches one target (monomorphic); falls back to table lookup on miss.
    cachedElemIdx*: int32    # -1 = empty
    cachedLocalCount*: int32 # localCount of cached target
    cachedJitAddr*: pointer  # JIT address of cached target (nil = empty)
    tableElems*: ptr UncheckedArray[TableElem]  # pre-resolved table (read-only)
    tableLen*: int32         # number of valid entries
    paramCount*: int32       # expected param count (from call site's typeIdx)
    resultCount*: int32      # expected result count

  CompilerCtx = object
    buf: AsmBuffer
    labels: seq[Label]    # label stack (mirrors WASM block nesting)
    callTargets: seq[CallTarget]  # resolved targets indexed by module funcAddr
    selfIdx: int          # this function's index in callTargets (for self-calls)
    selfEntry: int        # instruction index of this function's entry (for self-recursion)
    brTablesRef: ptr seq[BrTableData]  # br_table auxiliary data (from Expr.brTables)
    globalsOffset: int    # byte offset into locals array where globals start
    tosValid: bool        # whether rTos holds a valid TOS value
    usesMemory: bool      # true if function uses memory load/store/size/grow ops
    moduleTypes: ptr seq[FuncType]           # for call_indirect type lookup
    tableElems: ptr UncheckedArray[TableElem]  # pre-resolved table 0
    tableElemsLen: int                       # length of tableElems
    poolRef: ptr JitMemPool                  # for allocating side data

const rTos = Reg(16)  # x16 = TOS cache register

# ---------------------------------------------------------------------------
# Additional AsmBuffer encoding helpers (not in codegen.nim)
# ---------------------------------------------------------------------------

proc strPostIdx(buf: var AsmBuffer, src, base: Reg, imm9: int32, is64: bool = true) =
  ## STR Rt, [Rn], #imm9 (post-index: store then add offset)
  let size = if is64: 3'u32 else: 2'u32
  let simm9 = (imm9.uint32 and 0x1FF)
  buf.emit((size shl 30) or 0x38000400'u32 or (simm9 shl 12) or
           (base.uint8.uint32 shl 5) or src.uint8.uint32)

proc ldrPreIdx(buf: var AsmBuffer, dst, base: Reg, imm9: int32, is64: bool = true) =
  ## LDR Rt, [Rn, #imm9]! (pre-index: add offset then load)
  let size = if is64: 3'u32 else: 2'u32
  let simm9 = (imm9.uint32 and 0x1FF)
  buf.emit((size shl 30) or 0x38400C00'u32 or (simm9 shl 12) or
           (base.uint8.uint32 shl 5) or dst.uint8.uint32)

proc ldpPreIdx(buf: var AsmBuffer, rt1, rt2, base: Reg, offset: int32, is64: bool = true) =
  ## LDP Rt1, Rt2, [Rn, #offset]! (pre-index load pair)
  let opc = if is64: 2'u32 else: 0'u32
  let scale = if is64: 8 else: 4
  let simm7 = ((offset div scale).uint32 and 0x7F)
  buf.emit((opc shl 30) or 0x29C00000'u32 or (simm7 shl 15) or
           (rt2.uint8.uint32 shl 10) or (base.uint8.uint32 shl 5) or rt1.uint8.uint32)

# ---------------------------------------------------------------------------
# Sub-word memory encoding helpers
# ---------------------------------------------------------------------------

proc ldrbImm(buf: var AsmBuffer, dst, base: Reg, offset: int32) =
  ## LDRB Wt, [Xn, #offset] — unsigned byte load, zero-extends to 32-bit
  ## Encoding: 00 111 001 01 imm12 Rn Rt  (0x39400000)
  let uoff = offset.uint32 and 0xFFF
  buf.emit(0x39400000'u32 or (uoff shl 10) or (base.uint8.uint32 shl 5) or dst.uint8.uint32)

proc ldrhImm(buf: var AsmBuffer, dst, base: Reg, offset: int32) =
  ## LDRH Wt, [Xn, #offset] — unsigned halfword load, zero-extends to 32-bit
  ## Encoding: 01 111 001 01 imm12 Rn Rt  (0x79400000)
  ## offset is scaled by 2
  let uoff = (offset div 2).uint32 and 0xFFF
  buf.emit(0x79400000'u32 or (uoff shl 10) or (base.uint8.uint32 shl 5) or dst.uint8.uint32)

proc ldrsbImm32(buf: var AsmBuffer, dst, base: Reg, offset: int32) =
  ## LDRSB Wt, [Xn, #offset] — signed byte load, sign-extends to 32-bit
  ## Encoding: 00 111 001 11 imm12 Rn Rt  (0x39C00000)
  let uoff = offset.uint32 and 0xFFF
  buf.emit(0x39C00000'u32 or (uoff shl 10) or (base.uint8.uint32 shl 5) or dst.uint8.uint32)

proc ldrsbImm64(buf: var AsmBuffer, dst, base: Reg, offset: int32) =
  ## LDRSB Xt, [Xn, #offset] — signed byte load, sign-extends to 64-bit
  ## Encoding: 00 111 001 10 imm12 Rn Rt  (0x39800000)
  let uoff = offset.uint32 and 0xFFF
  buf.emit(0x39800000'u32 or (uoff shl 10) or (base.uint8.uint32 shl 5) or dst.uint8.uint32)

proc ldrshImm32(buf: var AsmBuffer, dst, base: Reg, offset: int32) =
  ## LDRSH Wt, [Xn, #offset] — signed halfword load, sign-extends to 32-bit
  ## Encoding: 01 111 001 11 imm12 Rn Rt  (0x79C00000)
  ## offset is scaled by 2
  let uoff = (offset div 2).uint32 and 0xFFF
  buf.emit(0x79C00000'u32 or (uoff shl 10) or (base.uint8.uint32 shl 5) or dst.uint8.uint32)

proc ldrshImm64(buf: var AsmBuffer, dst, base: Reg, offset: int32) =
  ## LDRSH Xt, [Xn, #offset] — signed halfword load, sign-extends to 64-bit
  ## Encoding: 01 111 001 10 imm12 Rn Rt  (0x79800000)
  ## offset is scaled by 2
  let uoff = (offset div 2).uint32 and 0xFFF
  buf.emit(0x79800000'u32 or (uoff shl 10) or (base.uint8.uint32 shl 5) or dst.uint8.uint32)

proc ldrswImm(buf: var AsmBuffer, dst, base: Reg, offset: int32) =
  ## LDRSW Xt, [Xn, #offset] — signed word load, sign-extends to 64-bit
  ## Encoding: 10 111 001 10 imm12 Rn Rt  (0xB9800000)
  ## offset is scaled by 4
  let uoff = (offset div 4).uint32 and 0xFFF
  buf.emit(0xB9800000'u32 or (uoff shl 10) or (base.uint8.uint32 shl 5) or dst.uint8.uint32)

proc strbImm(buf: var AsmBuffer, src, base: Reg, offset: int32) =
  ## STRB Wt, [Xn, #offset] — store byte
  ## Encoding: 00 111 001 00 imm12 Rn Rt  (0x39000000)
  let uoff = offset.uint32 and 0xFFF
  buf.emit(0x39000000'u32 or (uoff shl 10) or (base.uint8.uint32 shl 5) or src.uint8.uint32)

proc strhImm(buf: var AsmBuffer, src, base: Reg, offset: int32) =
  ## STRH Wt, [Xn, #offset] — store halfword
  ## Encoding: 01 111 001 00 imm12 Rn Rt  (0x79000000)
  ## offset is scaled by 2
  let uoff = (offset div 2).uint32 and 0xFFF
  buf.emit(0x79000000'u32 or (uoff shl 10) or (base.uint8.uint32 shl 5) or src.uint8.uint32)

# ---------------------------------------------------------------------------
# call_indirect runtime dispatch helper
# ---------------------------------------------------------------------------

proc callIndirectDispatch*(
    cache: ptr CallIndirectCache,
    elemIdx: int32,
    vsp: ptr uint64,
    locals: ptr uint64,
    memBase: ptr byte,
    memSize: uint64): ptr uint64 {.cdecl.} =
  ## Runtime helper for call_indirect with monomorphic inline caching.
  ## Checks the IC for a fast hit; falls back to table lookup on miss.
  ## Returns the new VSP after the call, or nil to signal a WASM trap.
  var jitAddr: pointer
  var localCount: int
  let pc = cache.paramCount.int

  # Monomorphic IC fast path
  if cache.cachedElemIdx == elemIdx and cache.cachedJitAddr != nil:
    jitAddr = cache.cachedJitAddr
    localCount = cache.cachedLocalCount.int
  else:
    # Bounds check
    if elemIdx < 0 or elemIdx.int >= cache.tableLen.int:
      return nil
    let elem = cache.tableElems[elemIdx]
    if elem.jitAddr == nil:
      return nil  # null element or callee not JIT-compiled
    # Update monomorphic IC
    cache.cachedElemIdx = elemIdx
    cache.cachedLocalCount = elem.localCount
    cache.cachedJitAddr = elem.jitAddr
    jitAddr = elem.jitAddr
    localCount = elem.localCount.int

  # argBase: move VSP back over the args (they sit just below vsp)
  let argBase = cast[ptr UncheckedArray[uint64]](cast[uint](vsp) - pc.uint * 8)

  # Allocate callee locals; use a fixed-size stack buffer for the common case
  var smallLocals: array[64, uint64]
  var bigLocals: seq[uint64]
  let calleeLocals: ptr uint64 =
    if localCount <= 64:
      for i in 0 ..< pc:
        smallLocals[i] = argBase[i]
      for i in pc ..< localCount:
        smallLocals[i] = 0
      smallLocals[0].addr
    else:
      bigLocals = newSeq[uint64](localCount)
      for i in 0 ..< pc:
        bigLocals[i] = argBase[i]
      bigLocals[0].addr

  let fn = cast[JitFuncPtr](jitAddr)
  fn(cast[ptr uint64](argBase), calleeLocals, memBase, memSize)

proc tier2CallIndirectDispatch*(
    cache: ptr CallIndirectCache,
    elemIdx: int32,
    argPtr: ptr uint64,    ## &locals[tempBase]; args at [0..pc-1], result written to [0]
    memBase: ptr byte,
    memSize: uint64): int32 {.cdecl.} =
  ## Runtime helper for call_indirect in Tier 2 JIT.
  ## Args are pre-spilled by the caller into locals[tempBase..tempBase+pc-1].
  ## On success, callee writes result to argPtr[0] and we return 0.
  ## On trap (out-of-bounds, null element, or unJIT'd callee), returns 1.
  var jitAddr: pointer
  var localCount: int
  let pc = cache.paramCount.int

  # Monomorphic IC fast path
  if cache.cachedElemIdx == elemIdx and cache.cachedJitAddr != nil:
    jitAddr = cache.cachedJitAddr
    localCount = cache.cachedLocalCount.int
  else:
    # Bounds check
    if elemIdx < 0 or elemIdx.int >= cache.tableLen.int:
      return 1  # trap: out of bounds
    let elem = cache.tableElems[elemIdx]
    if elem.jitAddr == nil:
      return 1  # trap: null element or callee not JIT-compiled yet
    # Update monomorphic IC
    cache.cachedElemIdx = elemIdx
    cache.cachedLocalCount = elem.localCount
    cache.cachedJitAddr = elem.jitAddr
    jitAddr = elem.jitAddr
    localCount = elem.localCount.int

  # Set up callee locals: copy args from argPtr[0..pc-1], zero the rest.
  # Use a stack-allocated buffer for the common case (≤64 locals) to avoid GC pressure.
  var smallLocals: array[64, uint64]
  var bigLocals: seq[uint64]
  let calleeLocals: ptr uint64 =
    if localCount <= 64:
      let arr = cast[ptr UncheckedArray[uint64]](argPtr)
      for i in 0 ..< pc:
        smallLocals[i] = arr[i]
      for i in pc ..< localCount:
        smallLocals[i] = 0
      smallLocals[0].addr
    else:
      bigLocals = newSeq[uint64](localCount)
      let arr = cast[ptr UncheckedArray[uint64]](argPtr)
      for i in 0 ..< pc:
        bigLocals[i] = arr[i]
      bigLocals[0].addr  # rest zeroed by newSeq

  # Call: argPtr is used as the VSP for result collection.
  # The callee writes its result to argPtr[0] via irReturn (STR, [x8], #8).
  discard cast[JitFuncPtr](jitAddr)(argPtr, calleeLocals, memBase, memSize)
  0  # success

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc emitTrap(ctx: var CompilerCtx) =
  ## Emit a debug breakpoint for unimplemented or erroneous paths
  ctx.buf.brk(1)

proc emitPushX(ctx: var CompilerCtx, src: Reg) =
  ## Push a 64-bit value from `src` onto the value stack (post-index STR)
  ctx.buf.strPostIdx(src, rVSP, 8)

proc emitPopX(ctx: var CompilerCtx, dst: Reg) =
  ## Pop a 64-bit value from the value stack into `dst` (pre-index LDR)
  ctx.buf.ldrPreIdx(dst, rVSP, -8)

proc emitPopPairX(ctx: var CompilerCtx, first, second: Reg) =
  ## Pop two 64-bit values: `second` = TOS, `first` = TOS-1
  ## After: VSP -= 16, first = [old VSP - 16], second = [old VSP - 8]
  ctx.buf.ldpPreIdx(first, second, rVSP, -16)

proc emitPeekX(ctx: var CompilerCtx, dst: Reg) =
  ## Read TOS without popping (signed offset since VSP points past top)
  ctx.buf.ldurImm(dst, rVSP, -8)

# ---------------------------------------------------------------------------
# TOS register cache helpers
# ---------------------------------------------------------------------------

proc emitFlushTos(ctx: var CompilerCtx) =
  ## If TOS cache is valid, push it to the memory stack and invalidate.
  if ctx.tosValid:
    ctx.buf.strPostIdx(rTos, rVSP, 8)
    ctx.tosValid = false

proc emitEnsureTos(ctx: var CompilerCtx) =
  ## If TOS cache is not valid, pop from memory stack into rTos.
  if not ctx.tosValid:
    ctx.buf.ldrPreIdx(rTos, rVSP, -8)
    ctx.tosValid = true

proc emitPushCached(ctx: var CompilerCtx, src: Reg) =
  ## Push src onto the logical stack using the TOS cache.
  ## If TOS cache already holds a value, flush it to memory first.
  if ctx.tosValid:
    ctx.buf.strPostIdx(rTos, rVSP, 8)
  if src == rTos:
    ctx.tosValid = true
  else:
    ctx.buf.movReg(rTos, src)
    ctx.tosValid = true

proc emitPopCached(ctx: var CompilerCtx, dst: Reg) =
  ## Pop from logical stack into dst using the TOS cache.
  if ctx.tosValid:
    if dst != rTos:
      ctx.buf.movReg(dst, rTos)
    ctx.tosValid = false
  else:
    ctx.buf.ldrPreIdx(dst, rVSP, -8)

# ---------------------------------------------------------------------------
# Prologue / Epilogue
# ---------------------------------------------------------------------------

proc emitPrologue(ctx: var CompilerCtx) =
  # Self-recursive calls BL here — each recursion level needs its own FP/LR save
  ctx.selfEntry = ctx.buf.pos
  # STP x29, x30, [sp, #-16]!
  ctx.buf.stpPreIdx(fp, lr, sp, -16)
  # MOV x29, sp
  ctx.buf.movReg(fp, sp)
  # Set up WASM register convention from ABI args
  ctx.buf.movReg(rVSP, x0)      # x8 = vsp
  ctx.buf.movReg(rLocals, x1)   # x9 = locals
  if ctx.usesMemory:
    ctx.buf.movReg(rMemBase, x2)  # x10 = memBase
    ctx.buf.movReg(rMemSize, x3)  # x11 = memSize

proc emitEpilogue(ctx: var CompilerCtx) =
  # MOV x0, x8  (return updated VSP)
  ctx.buf.movReg(x0, rVSP)
  # LDP x29, x30, [sp], #16
  ctx.buf.ldpPostIdx(fp, lr, sp, 16)
  # RET
  ctx.buf.ret()

# ---------------------------------------------------------------------------
# Forward-branch patching
# ---------------------------------------------------------------------------

proc addPatch(ctx: var CompilerCtx, labelDepth: int) =
  ## Record current position as needing a forward-branch patch for the
  ## label at the given depth (0 = innermost).
  let idx = ctx.labels.len - 1 - labelDepth
  if idx >= 0 and idx < ctx.labels.len:
    ctx.labels[idx].patchList.add(ctx.buf.pos)

proc patchForwardBranches(ctx: var CompilerCtx, label: Label) =
  ## Patch all recorded forward branches to point to current position
  let target = ctx.buf.pos
  for patchIdx in label.patchList:
    let offset = target - patchIdx
    # Determine instruction type by inspecting opcode bits
    let inst = ctx.buf.code[patchIdx]
    let op = inst and 0xFC000000'u32
    if op == 0x14000000'u32:
      # Unconditional B: imm26
      let imm26 = offset.uint32 and 0x03FFFFFF
      ctx.buf.patchAt(patchIdx, 0x14000000'u32 or imm26)
    elif op == 0x54000000'u32:
      # B.cond: imm19 at bits [23:5]
      let cond = inst and 0xF
      let imm19 = offset.uint32 and 0x7FFFF
      ctx.buf.patchAt(patchIdx, 0x54000000'u32 or (imm19 shl 5) or cond)
    elif (inst and 0x7F000000'u32) == 0x34000000'u32:
      # CBZ: sf | 0x34 | imm19 | Rt
      let sfAndRt = inst and 0x800000FF'u32
      let imm19 = offset.uint32 and 0x7FFFF
      ctx.buf.patchAt(patchIdx, sfAndRt or 0x34000000'u32 or (imm19 shl 5))
    elif (inst and 0x7F000000'u32) == 0x35000000'u32:
      # CBNZ: sf | 0x35 | imm19 | Rt
      let sfAndRt = inst and 0x800000FF'u32
      let imm19 = offset.uint32 and 0x7FFFF
      ctx.buf.patchAt(patchIdx, sfAndRt or 0x35000000'u32 or (imm19 shl 5))
    else:
      # Unknown instruction at patch site — emit BRK as safety
      ctx.buf.patchAt(patchIdx, 0xD4200020'u32)  # BRK #1

# ---------------------------------------------------------------------------
# Instruction compilation
# ---------------------------------------------------------------------------

proc compileInstr(ctx: var CompilerCtx, instr: Instr) =
  case instr.op

  # ---- Constants ----
  of opI32Const:
    let val = cast[int32](instr.imm1)
    # Use TOS cache: load constant directly into rTos
    ctx.emitFlushTos()
    ctx.buf.loadImm32(rTos, val)
    ctx.tosValid = true

  of opI64Const:
    let val = instr.imm1.uint64 or (instr.imm2.uint64 shl 32)
    ctx.emitFlushTos()
    ctx.buf.loadImm64(rTos, val)
    ctx.tosValid = true

  # ---- Local variables ----
  of opLocalGet:
    let offset = instr.imm1.int32 * 8  # each local is 8 bytes
    # Use TOS cache: load local directly into rTos
    ctx.emitFlushTos()
    ctx.buf.ldrImm(rTos, rLocals, offset)
    ctx.tosValid = true

  of opLocalSet:
    # Pop TOS and store to local — use cached rTos directly if available
    let offset = instr.imm1.int32 * 8
    if ctx.tosValid:
      ctx.buf.strImm(rTos, rLocals, offset)
      ctx.tosValid = false
    else:
      ctx.emitPopX(rScratch0)
      ctx.buf.strImm(rScratch0, rLocals, offset)

  of opLocalTee:
    # Peek TOS (ensure cached), store copy to local, keep TOS valid
    ctx.emitEnsureTos()
    let offset = instr.imm1.int32 * 8
    ctx.buf.strImm(rTos, rLocals, offset)

  # ---- Parametric ----
  of opDrop:
    # If TOS is cached, just invalidate it (no memory traffic needed)
    if ctx.tosValid:
      ctx.tosValid = false
    else:
      ctx.buf.subImm(rVSP, rVSP, 8)

  of opSelect, opSelectTyped:
    # Pop condition, val2, val1. Push val1 if condition != 0, else val2.
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch2)  # condition
    ctx.emitPopX(rScratch1)  # val2 (false-value)
    ctx.emitPopX(rScratch0)  # val1 (true-value)
    ctx.buf.cmpImm(rScratch2, 0)
    ctx.buf.csel(rScratch0, rScratch0, rScratch1, condNE)
    ctx.emitPushX(rScratch0)

  # ---- i32 Arithmetic (binary) ----
  of opI32Add:
    # TOS-cached binary op: use rTos directly (no MOV to scratch needed)
    if ctx.tosValid:
      ctx.buf.ldrPreIdx(rScratch0, rVSP, -8)  # a = memory TOS-1
      ctx.buf.addReg(rTos, rScratch0, rTos, is64 = false)  # rTos = a + old_TOS
      # tosValid stays true
    else:
      ctx.emitPopPairX(rScratch0, rScratch1)
      ctx.buf.addReg(rTos, rScratch0, rScratch1, is64 = false)
      ctx.tosValid = true

  of opI32Sub:
    # i32.sub: a - b where b = TOS, a = TOS-1. Result = a - b.
    if ctx.tosValid:
      ctx.buf.ldrPreIdx(rScratch0, rVSP, -8)  # a = memory TOS-1
      ctx.buf.subReg(rTos, rScratch0, rTos, is64 = false)  # rTos = a - old_TOS
      # tosValid stays true
    else:
      ctx.emitPopPairX(rScratch0, rScratch1)
      ctx.buf.subReg(rTos, rScratch0, rScratch1, is64 = false)
      ctx.tosValid = true

  of opI32Mul:
    if ctx.tosValid:
      ctx.buf.ldrPreIdx(rScratch0, rVSP, -8)  # a = memory TOS-1
      ctx.buf.mulReg(rTos, rScratch0, rTos, is64 = false)  # rTos = a * old_TOS
      # tosValid stays true
    else:
      ctx.emitPopPairX(rScratch0, rScratch1)
      ctx.buf.mulReg(rTos, rScratch0, rScratch1, is64 = false)
      ctx.tosValid = true

  of opI32DivS:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)  # a / b
    # Trap on division by zero
    ctx.buf.cmpImm(rScratch1, 0, is64 = false)
    ctx.buf.bCond(condEQ, 2)  # skip to BRK if zero
    ctx.buf.sdivReg(rScratch0, rScratch0, rScratch1, is64 = false)
    ctx.buf.b(2)  # skip BRK
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  of opI32DivU:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.cmpImm(rScratch1, 0, is64 = false)
    ctx.buf.bCond(condEQ, 2)
    ctx.buf.udivReg(rScratch0, rScratch0, rScratch1, is64 = false)
    ctx.buf.b(2)
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  of opI32RemS:
    # a rem b = a - (a / b) * b
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)  # a, b
    ctx.buf.cmpImm(rScratch1, 0, is64 = false)
    ctx.buf.bCond(condEQ, 4)  # skip to BRK
    ctx.buf.sdivReg(rScratch2, rScratch0, rScratch1, is64 = false)  # q = a /s b
    ctx.buf.mulReg(rScratch2, rScratch2, rScratch1, is64 = false)   # q * b
    ctx.buf.subReg(rScratch0, rScratch0, rScratch2, is64 = false)   # a - q*b
    ctx.buf.b(2)
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  of opI32RemU:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.cmpImm(rScratch1, 0, is64 = false)
    ctx.buf.bCond(condEQ, 4)
    ctx.buf.udivReg(rScratch2, rScratch0, rScratch1, is64 = false)
    ctx.buf.mulReg(rScratch2, rScratch2, rScratch1, is64 = false)
    ctx.buf.subReg(rScratch0, rScratch0, rScratch2, is64 = false)
    ctx.buf.b(2)
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  # ---- i32 Bitwise ----
  of opI32And:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.andReg(rScratch0, rScratch0, rScratch1, is64 = false)
    ctx.emitPushX(rScratch0)

  of opI32Or:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.orrReg(rScratch0, rScratch0, rScratch1, is64 = false)
    ctx.emitPushX(rScratch0)

  of opI32Xor:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.eorReg(rScratch0, rScratch0, rScratch1, is64 = false)
    ctx.emitPushX(rScratch0)

  of opI32Shl:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)  # a << b
    ctx.buf.lslReg(rScratch0, rScratch0, rScratch1, is64 = false)
    ctx.emitPushX(rScratch0)

  of opI32ShrS:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.asrReg(rScratch0, rScratch0, rScratch1, is64 = false)
    ctx.emitPushX(rScratch0)

  of opI32ShrU:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.lsrReg(rScratch0, rScratch0, rScratch1, is64 = false)
    ctx.emitPushX(rScratch0)

  of opI32Rotl:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)  # a rotl b
    # AArch64 has RORV but not ROLV. rotl(a,b) = rotr(a, 32-b)
    # Negate shift amount: 32 - b (mod 32) via NEG + AND
    ctx.buf.subReg(rScratch1, xzr, rScratch1, is64 = false)  # neg
    ctx.buf.rorReg(rScratch0, rScratch0, rScratch1, is64 = false)
    ctx.emitPushX(rScratch0)

  of opI32Rotr:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.rorReg(rScratch0, rScratch0, rScratch1, is64 = false)
    ctx.emitPushX(rScratch0)

  # ---- i32 Unary ----
  of opI32Clz:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.clzReg(rScratch0, rScratch0, is64 = false)
    ctx.emitPushX(rScratch0)

  of opI32Ctz:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    # CTZ = CLZ(RBIT(x))
    ctx.buf.rbitReg(rScratch0, rScratch0, is64 = false)
    ctx.buf.clzReg(rScratch0, rScratch0, is64 = false)
    ctx.emitPushX(rScratch0)

  of opI32Popcnt:
    # Use NEON: FMOV to SIMD, CNT per byte, ADDV to sum, FMOV back.
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    # FMOV S0, W<scratch0> (GP to FP, 32-bit): 0x1E270000 | (Wn << 5) | Sd
    ctx.buf.emit(0x1E270000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    # CNT V0.8B, V0.8B — count set bits per byte
    ctx.buf.emit(0x0E205800'u32)
    # ADDV B0, V0.8B — horizontal sum of bytes
    ctx.buf.emit(0x0E31B800'u32)
    # FMOV W<scratch0>, S0 (FP to GP, 32-bit): 0x1E260000 | (Sn << 5) | Wd
    ctx.buf.emit(0x1E260000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  # ---- i32 Comparisons ----
  of opI32Eqz:
    # Unary op: pop via cache, result stays in cache
    if ctx.tosValid:
      ctx.buf.cmpImm(rTos, 0, is64 = false)
      ctx.buf.cset(rTos, condEQ)
      # tosValid remains true, result is in rTos
    else:
      ctx.emitPopX(rScratch0)
      ctx.buf.cmpImm(rScratch0, 0, is64 = false)
      ctx.buf.cset(rTos, condEQ)
      ctx.tosValid = true

  of opI32Eq, opI32Ne, opI32LtS, opI32LtU, opI32GtS, opI32GtU,
     opI32LeS, opI32LeU, opI32GeS, opI32GeU:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)  # a, b
    ctx.buf.cmpReg(rScratch0, rScratch1, is64 = false)
    # Map opcode to condition for "a op b"
    let cond = case instr.op
      of opI32Eq:  condEQ
      of opI32Ne:  condNE
      of opI32LtS: condLT
      of opI32LtU: condCC   # unsigned <
      of opI32GtS: condGT
      of opI32GtU: condHI   # unsigned >
      of opI32LeS: condLE
      of opI32LeU: condLS   # unsigned <=
      of opI32GeS: condGE
      of opI32GeU: condCS   # unsigned >=
      else: condAL  # unreachable
    ctx.buf.cset(rScratch0, cond)
    ctx.emitPushX(rScratch0)

  # ---- Control flow ----
  of opBlock:
    # Flush TOS at control flow join point
    ctx.emitFlushTos()
    # Push a block label. Forward branches (br) will be patched when we see opEnd.
    # imm1 stores endOffset — but we don't use it; we patch at opEnd.
    ctx.labels.add(Label(kind: lkBlock, patchList: @[], startPos: ctx.buf.pos,
                         elsePos: -1, hasElse: false))

  of opLoop:
    # Flush TOS at control flow join point
    ctx.emitFlushTos()
    # Push a loop label. Backward branches (br) jump to startPos.
    ctx.labels.add(Label(kind: lkLoop, patchList: @[], startPos: ctx.buf.pos,
                         elsePos: -1, hasElse: false))

  of opIf:
    # Flush TOS at control flow join point
    ctx.emitFlushTos()
    # Pop condition, CBZ to else/end (forward, patch later)
    ctx.emitPopX(rScratch0)
    # Record patch site for CBZ
    let patchIdx = ctx.buf.pos
    ctx.buf.cbz(rScratch0, 0, is64 = true)  # placeholder offset
    ctx.labels.add(Label(kind: lkIf, patchList: @[patchIdx], startPos: ctx.buf.pos,
                         elsePos: -1, hasElse: false))

  of opElse:
    # Flush TOS at control flow join point
    ctx.emitFlushTos()
    # We're inside an if block. The "then" path needs to branch past the else.
    if ctx.labels.len > 0:
      let labelIdx = ctx.labels.len - 1
      # Emit unconditional branch (then-path jumps to end) — patch later
      let thenEndPatch = ctx.buf.pos
      ctx.buf.b(0)  # placeholder
      ctx.labels[labelIdx].patchList.add(thenEndPatch)
      # Patch the CBZ from the if: it should jump here (start of else)
      # The original CBZ was at patchList[0] (from opIf)
      let cbzIdx = ctx.labels[labelIdx].patchList[0]
      let offset = ctx.buf.pos - cbzIdx
      let inst = ctx.buf.code[cbzIdx]
      let sfAndRt = inst and 0x800000FF'u32
      let imm19 = offset.uint32 and 0x7FFFF
      ctx.buf.patchAt(cbzIdx, sfAndRt or 0x34000000'u32 or (imm19 shl 5))
      # Remove the CBZ from patchList since it's resolved
      ctx.labels[labelIdx].patchList.delete(0)
      ctx.labels[labelIdx].hasElse = true
      ctx.labels[labelIdx].elsePos = ctx.buf.pos

  of opEnd:
    # Flush TOS at control flow join point
    ctx.emitFlushTos()
    if ctx.labels.len > 0:
      let label = ctx.labels.pop()
      # Patch all forward branches to here
      ctx.patchForwardBranches(label)
    # If labels is empty, this is the function-level end — handled by epilogue
    # (the main compilation loop emits the epilogue after the instruction loop)

  of opBr:
    ctx.emitFlushTos()
    let depth = instr.imm1.int
    let labelIdx = ctx.labels.len - 1 - depth
    if labelIdx >= 0 and labelIdx < ctx.labels.len:
      if ctx.labels[labelIdx].kind == lkLoop:
        # Backward branch to loop start
        let offset = ctx.labels[labelIdx].startPos - ctx.buf.pos
        ctx.buf.b(offset.int32)
      else:
        # Forward branch — record patch site
        ctx.labels[labelIdx].patchList.add(ctx.buf.pos)
        ctx.buf.b(0)  # placeholder
    else:
      ctx.emitTrap()

  of opBrIf:
    ctx.emitFlushTos()
    let depth = instr.imm1.int
    ctx.emitPopX(rScratch0)
    let labelIdx = ctx.labels.len - 1 - depth
    if labelIdx >= 0 and labelIdx < ctx.labels.len:
      if ctx.labels[labelIdx].kind == lkLoop:
        # Backward conditional branch
        let offset = ctx.labels[labelIdx].startPos - ctx.buf.pos
        ctx.buf.cbnz(rScratch0, offset.int32, is64 = true)
      else:
        # Forward conditional branch — record patch
        ctx.labels[labelIdx].patchList.add(ctx.buf.pos)
        ctx.buf.cbnz(rScratch0, 0, is64 = true)  # placeholder
    else:
      ctx.emitTrap()

  of opBrTable:
    ctx.emitFlushTos()
    # Multi-way branch via linear scan over label targets
    # imm1 = index into brTables auxiliary data
    ctx.emitPopX(rScratch0)  # branch index
    if ctx.brTablesRef != nil and instr.imm1.int < ctx.brTablesRef[].len:
      let btData = ctx.brTablesRef[][instr.imm1.int]
      # For each label: CMP index, #i → B.EQ to target
      for i in 0 ..< btData.labels.len:
        let depth = btData.labels[i].int
        let labelIdx = ctx.labels.len - 1 - depth
        ctx.buf.cmpImm(rScratch0, i.uint32, is64 = false)
        if labelIdx >= 0 and labelIdx < ctx.labels.len:
          if ctx.labels[labelIdx].kind == lkLoop:
            # Backward branch to loop start — emit B.EQ with known offset
            let offset = ctx.labels[labelIdx].startPos - ctx.buf.pos
            ctx.buf.bCond(condEQ, offset.int32)
          else:
            # Forward branch — record patch site, emit B.EQ placeholder
            ctx.labels[labelIdx].patchList.add(ctx.buf.pos)
            ctx.buf.bCond(condEQ, 0)
        else:
          # Invalid depth — trap on match
          ctx.buf.bCond(condEQ, 2)
          ctx.buf.b(2)
          ctx.emitTrap()
      # Default label: unconditional branch
      let defaultDepth = btData.defaultLabel.int
      let defaultLabelIdx = ctx.labels.len - 1 - defaultDepth
      if defaultLabelIdx >= 0 and defaultLabelIdx < ctx.labels.len:
        if ctx.labels[defaultLabelIdx].kind == lkLoop:
          let offset = ctx.labels[defaultLabelIdx].startPos - ctx.buf.pos
          ctx.buf.b(offset.int32)
        else:
          ctx.labels[defaultLabelIdx].patchList.add(ctx.buf.pos)
          ctx.buf.b(0)
      else:
        ctx.emitTrap()
    else:
      ctx.emitTrap()

  of opReturn:
    ctx.emitFlushTos()
    ctx.emitEpilogue()

  of opNop:
    ctx.buf.nop()

  of opUnreachable:
    ctx.emitFlushTos()
    ctx.emitTrap()

  # ---- i64 Constant ----
  # (opI64Const is already handled above in the Constants section)

  # ---- i64 Arithmetic (binary) ----
  of opI64Add:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.addReg(rScratch0, rScratch0, rScratch1, is64 = true)
    ctx.emitPushX(rScratch0)

  of opI64Sub:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.subReg(rScratch0, rScratch0, rScratch1, is64 = true)
    ctx.emitPushX(rScratch0)

  of opI64Mul:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.mulReg(rScratch0, rScratch0, rScratch1, is64 = true)
    ctx.emitPushX(rScratch0)

  of opI64DivS:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.cmpImm(rScratch1, 0, is64 = true)
    ctx.buf.bCond(condEQ, 2)
    ctx.buf.sdivReg(rScratch0, rScratch0, rScratch1, is64 = true)
    ctx.buf.b(2)
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  of opI64DivU:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.cmpImm(rScratch1, 0, is64 = true)
    ctx.buf.bCond(condEQ, 2)
    ctx.buf.udivReg(rScratch0, rScratch0, rScratch1, is64 = true)
    ctx.buf.b(2)
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  of opI64RemS:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.cmpImm(rScratch1, 0, is64 = true)
    ctx.buf.bCond(condEQ, 4)
    ctx.buf.sdivReg(rScratch2, rScratch0, rScratch1, is64 = true)
    ctx.buf.mulReg(rScratch2, rScratch2, rScratch1, is64 = true)
    ctx.buf.subReg(rScratch0, rScratch0, rScratch2, is64 = true)
    ctx.buf.b(2)
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  of opI64RemU:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.cmpImm(rScratch1, 0, is64 = true)
    ctx.buf.bCond(condEQ, 4)
    ctx.buf.udivReg(rScratch2, rScratch0, rScratch1, is64 = true)
    ctx.buf.mulReg(rScratch2, rScratch2, rScratch1, is64 = true)
    ctx.buf.subReg(rScratch0, rScratch0, rScratch2, is64 = true)
    ctx.buf.b(2)
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  # ---- i64 Bitwise ----
  of opI64And:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.andReg(rScratch0, rScratch0, rScratch1, is64 = true)
    ctx.emitPushX(rScratch0)

  of opI64Or:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.orrReg(rScratch0, rScratch0, rScratch1, is64 = true)
    ctx.emitPushX(rScratch0)

  of opI64Xor:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.eorReg(rScratch0, rScratch0, rScratch1, is64 = true)
    ctx.emitPushX(rScratch0)

  of opI64Shl:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.lslReg(rScratch0, rScratch0, rScratch1, is64 = true)
    ctx.emitPushX(rScratch0)

  of opI64ShrS:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.asrReg(rScratch0, rScratch0, rScratch1, is64 = true)
    ctx.emitPushX(rScratch0)

  of opI64ShrU:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.lsrReg(rScratch0, rScratch0, rScratch1, is64 = true)
    ctx.emitPushX(rScratch0)

  of opI64Rotl:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    # rotl(a,b) = rotr(a, 64-b). NEG gives 64-b mod 64 for free.
    ctx.buf.subReg(rScratch1, xzr, rScratch1, is64 = true)
    ctx.buf.rorReg(rScratch0, rScratch0, rScratch1, is64 = true)
    ctx.emitPushX(rScratch0)

  of opI64Rotr:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.rorReg(rScratch0, rScratch0, rScratch1, is64 = true)
    ctx.emitPushX(rScratch0)

  # ---- i64 Unary ----
  of opI64Clz:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.clzReg(rScratch0, rScratch0, is64 = true)
    ctx.emitPushX(rScratch0)

  of opI64Ctz:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.rbitReg(rScratch0, rScratch0, is64 = true)
    ctx.buf.clzReg(rScratch0, rScratch0, is64 = true)
    ctx.emitPushX(rScratch0)

  of opI64Popcnt:
    ctx.emitFlushTos()
    # Use NEON: FMOV D0, X<scratch0> (64-bit GP to FP), CNT, ADDV, FMOV back
    ctx.emitPopX(rScratch0)
    # FMOV D0, X<scratch0> (GP 64-bit to FP 64-bit): 0x9E670000 | (Xn << 5) | Dd
    ctx.buf.emit(0x9E670000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    # CNT V0.8B, V0.8B — count set bits per byte
    ctx.buf.emit(0x0E205800'u32)
    # ADDV B0, V0.8B — horizontal sum of bytes
    ctx.buf.emit(0x0E31B800'u32)
    # FMOV X<scratch0>, D0 (FP 64-bit to GP 64-bit): 0x9E660000 | (Dn << 5) | Xd
    ctx.buf.emit(0x9E660000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  # ---- i64 Comparisons ----
  of opI64Eqz:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.cmpImm(rScratch0, 0, is64 = true)
    # CSET Xd, EQ => CSINC Xd, XZR, XZR, NE (sf=1)
    ctx.buf.emit(0x9A800400'u32 or (xzr.uint8.uint32 shl 16) or
                 (condNE.uint32 shl 12) or (xzr.uint8.uint32 shl 5) or
                 rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opI64Eq, opI64Ne, opI64LtS, opI64LtU, opI64GtS, opI64GtU,
     opI64LeS, opI64LeU, opI64GeS, opI64GeU:
    ctx.emitFlushTos()
    ctx.emitPopPairX(rScratch0, rScratch1)
    ctx.buf.cmpReg(rScratch0, rScratch1, is64 = true)
    let cond = case instr.op
      of opI64Eq:  condEQ
      of opI64Ne:  condNE
      of opI64LtS: condLT
      of opI64LtU: condCC
      of opI64GtS: condGT
      of opI64GtU: condHI
      of opI64LeS: condLE
      of opI64LeU: condLS
      of opI64GeS: condGE
      of opI64GeU: condCS
      else: condAL
    ctx.buf.cset(rScratch0, cond)
    ctx.emitPushX(rScratch0)

  # ---- Conversions ----
  of opI32WrapI64:
    ctx.emitFlushTos()
    # Pop 64-bit value, mask to 32-bit (AND with 0xFFFFFFFF)
    ctx.emitPopX(rScratch0)
    # Use 32-bit MOV which zeros the upper 32 bits
    ctx.buf.movReg(rScratch0, rScratch0, is64 = false)
    ctx.emitPushX(rScratch0)

  of opI64ExtendI32S:
    ctx.emitFlushTos()
    # Pop 32-bit value, sign-extend to 64-bit via SXTW
    ctx.emitPopX(rScratch0)
    ctx.buf.sxtwReg(rScratch0, rScratch0)
    ctx.emitPushX(rScratch0)

  of opI64ExtendI32U:
    ctx.emitFlushTos()
    # Pop 32-bit value, zero-extend to 64-bit (just clear upper 32 bits)
    ctx.emitPopX(rScratch0)
    ctx.buf.movReg(rScratch0, rScratch0, is64 = false)
    ctx.emitPushX(rScratch0)

  of opI32Extend8S:
    ctx.emitFlushTos()
    # Sign-extend byte to i32 via SXTB (32-bit)
    ctx.emitPopX(rScratch0)
    ctx.buf.sxtbReg(rScratch0, rScratch0, is64 = false)
    ctx.emitPushX(rScratch0)

  of opI32Extend16S:
    ctx.emitFlushTos()
    # Sign-extend halfword to i32 via SXTH (32-bit)
    ctx.emitPopX(rScratch0)
    ctx.buf.sxthReg(rScratch0, rScratch0, is64 = false)
    ctx.emitPushX(rScratch0)

  of opI64Extend8S:
    ctx.emitFlushTos()
    # Sign-extend byte to i64 via SXTB (64-bit)
    ctx.emitPopX(rScratch0)
    ctx.buf.sxtbReg(rScratch0, rScratch0, is64 = true)
    ctx.emitPushX(rScratch0)

  of opI64Extend16S:
    ctx.emitFlushTos()
    # Sign-extend halfword to i64 via SXTH (64-bit)
    ctx.emitPopX(rScratch0)
    ctx.buf.sxthReg(rScratch0, rScratch0, is64 = true)
    ctx.emitPushX(rScratch0)

  of opI64Extend32S:
    ctx.emitFlushTos()
    # Sign-extend word to i64 via SXTW
    ctx.emitPopX(rScratch0)
    ctx.buf.sxtwReg(rScratch0, rScratch0)
    ctx.emitPushX(rScratch0)

  # ---- Memory load/store ----
  of opI32Load:
    ctx.emitFlushTos()
    # Pop address, add offset, bounds check, load 4 bytes
    let memOffset = instr.imm1  # memarg offset
    ctx.emitPopX(rScratch0)     # base address (i32, zero-extended)
    # Effective address = scratch0 + memOffset
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch1, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch1)
    # Bounds check: ea + 4 <= memSize
    ctx.buf.addImm(rScratch2, rScratch0, 4)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)  # if ea+4 > memSize, trap
    # Load: LDR W12, [x10, x12] (register offset, no shift for byte addressing)
    # Use LDRW with register offset — need unscaled or register form
    # LDR Wt, [Xn, Xm] — but we need byte-offset (not scaled)
    # Use ADD + LDR:
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.ldrImm(rScratch0, rScratch0, 0, is64 = false)
    ctx.buf.b(2)  # skip trap
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  of opI32Store:
    ctx.emitFlushTos()
    # Pop value, pop address, add offset, bounds check, store 4 bytes
    let memOffset = instr.imm1
    ctx.emitPopX(rScratch1)     # value
    ctx.emitPopX(rScratch0)     # address
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch2, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch2)
    # Bounds check
    ctx.buf.addImm(rScratch2, rScratch0, 4)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.strImm(rScratch1, rScratch0, 0, is64 = false)
    ctx.buf.b(2)
    ctx.emitTrap()

  of opI64Load:
    ctx.emitFlushTos()
    # Pop address, add offset, bounds check, load 8 bytes
    let memOffset = instr.imm1
    ctx.emitPopX(rScratch0)
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch1, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch1)
    # Bounds check: ea + 8 <= memSize
    ctx.buf.addImm(rScratch2, rScratch0, 8)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.ldrImm(rScratch0, rScratch0, 0, is64 = true)
    ctx.buf.b(2)
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  of opI64Store:
    ctx.emitFlushTos()
    # Pop value, pop address, add offset, bounds check, store 8 bytes
    let memOffset = instr.imm1
    ctx.emitPopX(rScratch1)     # value
    ctx.emitPopX(rScratch0)     # address
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch2, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch2)
    ctx.buf.addImm(rScratch2, rScratch0, 8)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.strImm(rScratch1, rScratch0, 0, is64 = true)
    ctx.buf.b(2)
    ctx.emitTrap()

  # ---- Sub-word loads (i32) ----
  of opI32Load8U:
    ctx.emitFlushTos()
    let memOffset = instr.imm1
    ctx.emitPopX(rScratch0)
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch1, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch1)
    # Bounds check: ea + 1 <= memSize
    ctx.buf.addImm(rScratch2, rScratch0, 1)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.ldrbImm(rScratch0, rScratch0, 0)
    ctx.buf.b(2)
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  of opI32Load8S:
    ctx.emitFlushTos()
    let memOffset = instr.imm1
    ctx.emitPopX(rScratch0)
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch1, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch1)
    ctx.buf.addImm(rScratch2, rScratch0, 1)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.ldrsbImm32(rScratch0, rScratch0, 0)
    ctx.buf.b(2)
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  of opI32Load16U:
    ctx.emitFlushTos()
    let memOffset = instr.imm1
    ctx.emitPopX(rScratch0)
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch1, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch1)
    ctx.buf.addImm(rScratch2, rScratch0, 2)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.ldrhImm(rScratch0, rScratch0, 0)
    ctx.buf.b(2)
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  of opI32Load16S:
    ctx.emitFlushTos()
    let memOffset = instr.imm1
    ctx.emitPopX(rScratch0)
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch1, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch1)
    ctx.buf.addImm(rScratch2, rScratch0, 2)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.ldrshImm32(rScratch0, rScratch0, 0)
    ctx.buf.b(2)
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  # ---- Sub-word loads (i64) ----
  of opI64Load8U:
    ctx.emitFlushTos()
    let memOffset = instr.imm1
    ctx.emitPopX(rScratch0)
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch1, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch1)
    ctx.buf.addImm(rScratch2, rScratch0, 1)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.ldrbImm(rScratch0, rScratch0, 0)  # zero-extends to 64-bit via Wt
    ctx.buf.b(2)
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  of opI64Load8S:
    ctx.emitFlushTos()
    let memOffset = instr.imm1
    ctx.emitPopX(rScratch0)
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch1, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch1)
    ctx.buf.addImm(rScratch2, rScratch0, 1)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.ldrsbImm64(rScratch0, rScratch0, 0)  # sign-extends to 64-bit
    ctx.buf.b(2)
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  of opI64Load16U:
    ctx.emitFlushTos()
    let memOffset = instr.imm1
    ctx.emitPopX(rScratch0)
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch1, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch1)
    ctx.buf.addImm(rScratch2, rScratch0, 2)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.ldrhImm(rScratch0, rScratch0, 0)  # zero-extends to 64-bit via Wt
    ctx.buf.b(2)
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  of opI64Load16S:
    ctx.emitFlushTos()
    let memOffset = instr.imm1
    ctx.emitPopX(rScratch0)
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch1, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch1)
    ctx.buf.addImm(rScratch2, rScratch0, 2)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.ldrshImm64(rScratch0, rScratch0, 0)  # sign-extends to 64-bit
    ctx.buf.b(2)
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  of opI64Load32U:
    ctx.emitFlushTos()
    let memOffset = instr.imm1
    ctx.emitPopX(rScratch0)
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch1, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch1)
    ctx.buf.addImm(rScratch2, rScratch0, 4)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.ldrImm(rScratch0, rScratch0, 0, is64 = false)  # LDR Wt zero-extends to 64-bit
    ctx.buf.b(2)
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  of opI64Load32S:
    ctx.emitFlushTos()
    let memOffset = instr.imm1
    ctx.emitPopX(rScratch0)
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch1, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch1)
    ctx.buf.addImm(rScratch2, rScratch0, 4)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.ldrswImm(rScratch0, rScratch0, 0)  # LDRSW sign-extends to 64-bit
    ctx.buf.b(2)
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  # ---- Sub-word stores ----
  of opI32Store8, opI64Store8:
    ctx.emitFlushTos()
    # Store low byte of value
    let memOffset = instr.imm1
    ctx.emitPopX(rScratch1)     # value
    ctx.emitPopX(rScratch0)     # address
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch2, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch2)
    ctx.buf.addImm(rScratch2, rScratch0, 1)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.strbImm(rScratch1, rScratch0, 0)
    ctx.buf.b(2)
    ctx.emitTrap()

  of opI32Store16, opI64Store16:
    ctx.emitFlushTos()
    # Store low halfword of value
    let memOffset = instr.imm1
    ctx.emitPopX(rScratch1)     # value
    ctx.emitPopX(rScratch0)     # address
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch2, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch2)
    ctx.buf.addImm(rScratch2, rScratch0, 2)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.strhImm(rScratch1, rScratch0, 0)
    ctx.buf.b(2)
    ctx.emitTrap()

  of opI64Store32:
    ctx.emitFlushTos()
    # Store low 32 bits of 64-bit value
    let memOffset = instr.imm1
    ctx.emitPopX(rScratch1)     # value
    ctx.emitPopX(rScratch0)     # address
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch2, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch2)
    ctx.buf.addImm(rScratch2, rScratch0, 4)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.strImm(rScratch1, rScratch0, 0, is64 = false)  # STR Wt stores low 32 bits
    ctx.buf.b(2)
    ctx.emitTrap()

  # ---- f32 Constants ----
  of opF32Const:
    ctx.emitFlushTos()
    # imm1 has the f32 bits as uint32
    let val = instr.imm1
    ctx.buf.loadImm32(rScratch0, cast[int32](val))
    # Zero-extend to 64-bit (loadImm32 uses is64=false so upper 32 bits are zeroed)
    ctx.emitPushX(rScratch0)

  # ---- f64 Constants ----
  of opF64Const:
    ctx.emitFlushTos()
    let val = instr.imm1.uint64 or (instr.imm2.uint64 shl 32)
    ctx.buf.loadImm64(rScratch0, val)
    ctx.emitPushX(rScratch0)

  # ---- f32 Arithmetic (binary) ----
  of opF32Add, opF32Sub, opF32Mul, opF32Div:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch1)   # b
    ctx.emitPopX(rScratch0)   # a
    # FMOV S0, W<scratch0> (GP→FP 32-bit)
    ctx.buf.emit(0x1E270000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    # FMOV S1, W<scratch1>
    ctx.buf.emit(0x1E270000'u32 or (rScratch1.uint8.uint32 shl 5) or 1)
    # FP operation: S0 = S0 op S1
    case instr.op
    of opF32Add: ctx.buf.faddScalar(d0, d0, d1, is64 = false)
    of opF32Sub: ctx.buf.fsubScalar(d0, d0, d1, is64 = false)
    of opF32Mul: ctx.buf.fmulScalar(d0, d0, d1, is64 = false)
    of opF32Div: ctx.buf.fdivScalar(d0, d0, d1, is64 = false)
    else: discard
    # FMOV W<scratch0>, S0 (FP→GP 32-bit)
    ctx.buf.emit(0x1E260000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  # ---- f32 Unary ----
  of opF32Abs:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x1E270000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)  # FMOV S0, W<scratch0>
    ctx.buf.emit(0x1E20C000'u32 or (0'u32 shl 5) or 0)                   # FABS S0, S0
    ctx.buf.emit(0x1E260000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)  # FMOV W<scratch0>, S0
    ctx.emitPushX(rScratch0)

  of opF32Neg:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x1E270000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E214000'u32 or (0'u32 shl 5) or 0)                   # FNEG S0, S0
    ctx.buf.emit(0x1E260000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opF32Sqrt:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x1E270000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E21C000'u32 or (0'u32 shl 5) or 0)                   # FSQRT S0, S0
    ctx.buf.emit(0x1E260000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opF32Ceil:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x1E270000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E24C000'u32 or (0'u32 shl 5) or 0)                   # FRINTP S0, S0
    ctx.buf.emit(0x1E260000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opF32Floor:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x1E270000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E254000'u32 or (0'u32 shl 5) or 0)                   # FRINTM S0, S0
    ctx.buf.emit(0x1E260000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opF32Trunc:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x1E270000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E25C000'u32 or (0'u32 shl 5) or 0)                   # FRINTZ S0, S0
    ctx.buf.emit(0x1E260000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opF32Nearest:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x1E270000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E244000'u32 or (0'u32 shl 5) or 0)                   # FRINTN S0, S0
    ctx.buf.emit(0x1E260000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  # ---- f32 Min/Max ----
  of opF32Min:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch1)   # b
    ctx.emitPopX(rScratch0)   # a
    ctx.buf.emit(0x1E270000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)  # FMOV S0, W<scratch0>
    ctx.buf.emit(0x1E270000'u32 or (rScratch1.uint8.uint32 shl 5) or 1)  # FMOV S1, W<scratch1>
    # FMINNM S0, S0, S1
    ctx.buf.emit(0x1E207800'u32 or (1'u32 shl 16) or (0'u32 shl 5) or 0)
    ctx.buf.emit(0x1E260000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opF32Max:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch1)
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x1E270000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E270000'u32 or (rScratch1.uint8.uint32 shl 5) or 1)
    # FMAXNM S0, S0, S1
    ctx.buf.emit(0x1E206800'u32 or (1'u32 shl 16) or (0'u32 shl 5) or 0)
    ctx.buf.emit(0x1E260000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  # ---- f32 Copysign ----
  of opF32Copysign:
    ctx.emitFlushTos()
    # Extract sign from b, magnitude from a using bit manipulation
    # f32 sign bit = bit 31
    ctx.emitPopX(rScratch1)   # b (sign source)
    ctx.emitPopX(rScratch0)   # a (magnitude source)
    # Clear sign bit of a: AND W<s0>, W<s0>, #0x7FFFFFFF
    # Use BIC with mask: load 0x80000000, BIC a with it
    ctx.buf.loadImm32(rScratch2, cast[int32](0x80000000'u32))
    # BIC W<s0>, W<s0>, W<s2> (clear sign bit of a) — AND with NOT mask
    # BIC encoding (32-bit): 0x0A200000 | Rm<<16 | Rn<<5 | Rd
    ctx.buf.emit(0x0A200000'u32 or (rScratch2.uint8.uint32 shl 16) or
                 (rScratch0.uint8.uint32 shl 5) or rScratch0.uint8.uint32)
    # Extract sign bit of b: AND W<s1>, W<s1>, #0x80000000
    ctx.buf.andReg(rScratch1, rScratch1, rScratch2, is64 = false)
    # Combine: ORR W<s0>, W<s0>, W<s1>
    ctx.buf.orrReg(rScratch0, rScratch0, rScratch1, is64 = false)
    ctx.emitPushX(rScratch0)

  # ---- f32 Comparisons ----
  of opF32Eq, opF32Ne, opF32Lt, opF32Gt, opF32Le, opF32Ge:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch1)   # b
    ctx.emitPopX(rScratch0)   # a
    ctx.buf.emit(0x1E270000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)  # FMOV S0, W<scratch0>
    ctx.buf.emit(0x1E270000'u32 or (rScratch1.uint8.uint32 shl 5) or 1)  # FMOV S1, W<scratch1>
    # FCMP S0, S1
    ctx.buf.emit(0x1E202000'u32 or (1'u32 shl 16) or (0'u32 shl 5) or 0x00)
    # Map opcode to condition
    let cond = case instr.op
      of opF32Eq: condEQ
      of opF32Ne: condNE
      of opF32Lt: condMI   # MI = less than (unordered → false)
      of opF32Gt: condGT
      of opF32Le: condLS   # LS = less or same (unordered → false)
      of opF32Ge: condGE
      else: condAL
    ctx.buf.cset(rScratch0, cond)
    ctx.emitPushX(rScratch0)

  # ---- f64 Arithmetic (binary) ----
  of opF64Add, opF64Sub, opF64Mul, opF64Div:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch1)   # b
    ctx.emitPopX(rScratch0)   # a
    # FMOV D0, X<scratch0> (GP→FP 64-bit)
    ctx.buf.emit(0x9E670000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    # FMOV D1, X<scratch1>
    ctx.buf.emit(0x9E670000'u32 or (rScratch1.uint8.uint32 shl 5) or 1)
    # FP operation: D0 = D0 op D1
    case instr.op
    of opF64Add: ctx.buf.faddScalar(d0, d0, d1, is64 = true)
    of opF64Sub: ctx.buf.fsubScalar(d0, d0, d1, is64 = true)
    of opF64Mul: ctx.buf.fmulScalar(d0, d0, d1, is64 = true)
    of opF64Div: ctx.buf.fdivScalar(d0, d0, d1, is64 = true)
    else: discard
    # FMOV X<scratch0>, D0 (FP→GP 64-bit)
    ctx.buf.emit(0x9E660000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  # ---- f64 Unary ----
  of opF64Abs:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E670000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)  # FMOV D0, X<scratch0>
    ctx.buf.emit(0x1E60C000'u32 or (0'u32 shl 5) or 0)                   # FABS D0, D0
    ctx.buf.emit(0x9E660000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)  # FMOV X<scratch0>, D0
    ctx.emitPushX(rScratch0)

  of opF64Neg:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E670000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E614000'u32 or (0'u32 shl 5) or 0)                   # FNEG D0, D0
    ctx.buf.emit(0x9E660000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opF64Sqrt:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E670000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E61C000'u32 or (0'u32 shl 5) or 0)                   # FSQRT D0, D0
    ctx.buf.emit(0x9E660000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opF64Ceil:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E670000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E64C000'u32 or (0'u32 shl 5) or 0)                   # FRINTP D0, D0
    ctx.buf.emit(0x9E660000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opF64Floor:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E670000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E654000'u32 or (0'u32 shl 5) or 0)                   # FRINTM D0, D0
    ctx.buf.emit(0x9E660000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opF64Trunc:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E670000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E65C000'u32 or (0'u32 shl 5) or 0)                   # FRINTZ D0, D0
    ctx.buf.emit(0x9E660000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opF64Nearest:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E670000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E644000'u32 or (0'u32 shl 5) or 0)                   # FRINTN D0, D0
    ctx.buf.emit(0x9E660000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  # ---- f64 Min/Max ----
  of opF64Min:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch1)
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E670000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)  # FMOV D0, X<scratch0>
    ctx.buf.emit(0x9E670000'u32 or (rScratch1.uint8.uint32 shl 5) or 1)  # FMOV D1, X<scratch1>
    # FMINNM D0, D0, D1
    ctx.buf.emit(0x1E607800'u32 or (1'u32 shl 16) or (0'u32 shl 5) or 0)
    ctx.buf.emit(0x9E660000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opF64Max:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch1)
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E670000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x9E670000'u32 or (rScratch1.uint8.uint32 shl 5) or 1)
    # FMAXNM D0, D0, D1
    ctx.buf.emit(0x1E606800'u32 or (1'u32 shl 16) or (0'u32 shl 5) or 0)
    ctx.buf.emit(0x9E660000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  # ---- f64 Copysign ----
  of opF64Copysign:
    ctx.emitFlushTos()
    # Extract sign from b, magnitude from a using bit manipulation
    # f64 sign bit = bit 63
    ctx.emitPopX(rScratch1)   # b (sign source)
    ctx.emitPopX(rScratch0)   # a (magnitude source)
    # Load sign mask: 0x8000000000000000
    ctx.buf.movz(rScratch2, 0x8000'u32, 48)
    # BIC X<s0>, X<s0>, X<s2> — clear sign bit of a
    ctx.buf.emit(0x8A200000'u32 or (rScratch2.uint8.uint32 shl 16) or
                 (rScratch0.uint8.uint32 shl 5) or rScratch0.uint8.uint32)
    # AND X<s1>, X<s1>, X<s2> — extract sign bit of b
    ctx.buf.andReg(rScratch1, rScratch1, rScratch2, is64 = true)
    # ORR X<s0>, X<s0>, X<s1> — combine
    ctx.buf.orrReg(rScratch0, rScratch0, rScratch1, is64 = true)
    ctx.emitPushX(rScratch0)

  # ---- f64 Comparisons ----
  of opF64Eq, opF64Ne, opF64Lt, opF64Gt, opF64Le, opF64Ge:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch1)
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E670000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)  # FMOV D0, X<scratch0>
    ctx.buf.emit(0x9E670000'u32 or (rScratch1.uint8.uint32 shl 5) or 1)  # FMOV D1, X<scratch1>
    # FCMP D0, D1
    ctx.buf.emit(0x1E602000'u32 or (1'u32 shl 16) or (0'u32 shl 5) or 0x00)
    let cond = case instr.op
      of opF64Eq: condEQ
      of opF64Ne: condNE
      of opF64Lt: condMI
      of opF64Gt: condGT
      of opF64Le: condLS
      of opF64Ge: condGE
      else: condAL
    ctx.buf.cset(rScratch0, cond)
    ctx.emitPushX(rScratch0)

  # ---- Float↔Int conversions ----
  of opF32ConvertI32S:
    ctx.emitFlushTos()
    # SCVTF S0, W12
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x1E220000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E260000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)  # FMOV W<s0>, S0
    ctx.emitPushX(rScratch0)

  of opF32ConvertI32U:
    ctx.emitFlushTos()
    # UCVTF S0, W12
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x1E230000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E260000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opF64ConvertI32S:
    ctx.emitFlushTos()
    # SCVTF D0, W12
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x1E620000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x9E660000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)  # FMOV X<s0>, D0
    ctx.emitPushX(rScratch0)

  of opF64ConvertI32U:
    ctx.emitFlushTos()
    # UCVTF D0, W12
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x1E630000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x9E660000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opF32ConvertI64S:
    ctx.emitFlushTos()
    # SCVTF S0, X12
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E220000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E260000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opF32ConvertI64U:
    ctx.emitFlushTos()
    # UCVTF S0, X12
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E230000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E260000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opF64ConvertI64S:
    ctx.emitFlushTos()
    # SCVTF D0, X12
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E620000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x9E660000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opF64ConvertI64U:
    ctx.emitFlushTos()
    # UCVTF D0, X12
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E630000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x9E660000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  # ---- Int truncations from float ----
  of opI32TruncF32S:
    ctx.emitFlushTos()
    # FCVTZS W12, S0
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x1E270000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)  # FMOV S0, W<s0>
    ctx.buf.emit(0x1E380000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opI32TruncF32U:
    ctx.emitFlushTos()
    # FCVTZU W12, S0
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x1E270000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E390000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opI32TruncF64S:
    ctx.emitFlushTos()
    # FCVTZS W12, D0
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E670000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)  # FMOV D0, X<s0>
    ctx.buf.emit(0x1E780000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opI32TruncF64U:
    ctx.emitFlushTos()
    # FCVTZU W12, D0
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E670000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E790000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opI64TruncF32S:
    ctx.emitFlushTos()
    # FCVTZS X12, S0
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x1E270000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)  # FMOV S0, W<s0>
    ctx.buf.emit(0x9E380000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opI64TruncF32U:
    ctx.emitFlushTos()
    # FCVTZU X12, S0
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x1E270000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x9E390000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opI64TruncF64S:
    ctx.emitFlushTos()
    # FCVTZS X12, D0
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E670000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)  # FMOV D0, X<s0>
    ctx.buf.emit(0x9E780000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opI64TruncF64U:
    ctx.emitFlushTos()
    # FCVTZU X12, D0
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E670000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x9E790000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  # ---- Demote/Promote ----
  of opF32DemoteF64:
    ctx.emitFlushTos()
    # FCVT S0, D0
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E670000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)  # FMOV D0, X<s0>
    ctx.buf.emit(0x1E624000'u32 or (0'u32 shl 5) or 0)                   # FCVT S0, D0
    ctx.buf.emit(0x1E260000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)  # FMOV W<s0>, S0
    ctx.emitPushX(rScratch0)

  of opF64PromoteF32:
    ctx.emitFlushTos()
    # FCVT D0, S0
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x1E270000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)  # FMOV S0, W<s0>
    ctx.buf.emit(0x1E22C000'u32 or (0'u32 shl 5) or 0)                   # FCVT D0, S0
    ctx.buf.emit(0x9E660000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)  # FMOV X<s0>, D0
    ctx.emitPushX(rScratch0)

  # ---- Reinterpret (no-op: value stack stores bit patterns) ----
  of opI32ReinterpretF32, opI64ReinterpretF64,
     opF32ReinterpretI32, opF64ReinterpretI64:
    discard  # no-op: bit pattern is already correct on the value stack

  # ---- Saturating truncations (same as regular on AArch64 — saturates to min/max, NaN→0) ----
  of opI32TruncSatF32S:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x1E270000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E380000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opI32TruncSatF32U:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x1E270000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E390000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opI32TruncSatF64S:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E670000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E780000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opI32TruncSatF64U:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E670000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x1E790000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opI64TruncSatF32S:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x1E270000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x9E380000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opI64TruncSatF32U:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x1E270000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x9E390000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opI64TruncSatF64S:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E670000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x9E780000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  of opI64TruncSatF64U:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    ctx.buf.emit(0x9E670000'u32 or (rScratch0.uint8.uint32 shl 5) or 0)
    ctx.buf.emit(0x9E790000'u32 or (0'u32 shl 5) or rScratch0.uint8.uint32)
    ctx.emitPushX(rScratch0)

  # ---- Float memory load/store (same as integer — bit patterns on value stack) ----
  of opF32Load:
    ctx.emitFlushTos()
    # Same as opI32Load — load 4 bytes, push as uint64 (zero-extended)
    let memOffset = instr.imm1
    ctx.emitPopX(rScratch0)
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch1, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch1)
    ctx.buf.addImm(rScratch2, rScratch0, 4)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.ldrImm(rScratch0, rScratch0, 0, is64 = false)
    ctx.buf.b(2)
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  of opF64Load:
    ctx.emitFlushTos()
    # Same as opI64Load — load 8 bytes, push as uint64
    let memOffset = instr.imm1
    ctx.emitPopX(rScratch0)
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch1, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch1)
    ctx.buf.addImm(rScratch2, rScratch0, 8)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.ldrImm(rScratch0, rScratch0, 0, is64 = true)
    ctx.buf.b(2)
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  of opF32Store:
    ctx.emitFlushTos()
    # Same as opI32Store — pop value and address, store 4 bytes
    let memOffset = instr.imm1
    ctx.emitPopX(rScratch1)     # value
    ctx.emitPopX(rScratch0)     # address
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch2, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch2)
    ctx.buf.addImm(rScratch2, rScratch0, 4)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.strImm(rScratch1, rScratch0, 0, is64 = false)
    ctx.buf.b(2)
    ctx.emitTrap()

  of opF64Store:
    ctx.emitFlushTos()
    # Same as opI64Store — pop value and address, store 8 bytes
    let memOffset = instr.imm1
    ctx.emitPopX(rScratch1)     # value
    ctx.emitPopX(rScratch0)     # address
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch2, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch2)
    ctx.buf.addImm(rScratch2, rScratch0, 8)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.strImm(rScratch1, rScratch0, 0, is64 = true)
    ctx.buf.b(2)
    ctx.emitTrap()

  # ---- Fused superinstructions ----
  of opLocalGetLocalGet:
    # Push first local to memory, keep second in TOS cache
    ctx.emitFlushTos()
    let offset0 = instr.imm1.int32 * 8
    let offset1 = instr.imm2.int32 * 8
    ctx.buf.ldrImm(rScratch0, rLocals, offset0)
    ctx.emitPushX(rScratch0)                   # first → memory
    ctx.buf.ldrImm(rTos, rLocals, offset1)     # second → TOS cache
    ctx.tosValid = true

  of opLocalGetI32Add:
    # TOS-aware: use cached TOS if available, leave result in TOS cache
    let offset = instr.imm1.int32 * 8
    if ctx.tosValid:
      # TOS cached: local[X] + rTos → rTos
      ctx.buf.ldrImm(rScratch0, rLocals, offset)
      ctx.buf.addReg(rTos, rScratch0, rTos, is64 = false)
      # tosValid stays true
    else:
      ctx.buf.ldrPreIdx(rScratch1, rVSP, -8)  # pop existing TOS
      ctx.buf.ldrImm(rScratch0, rLocals, offset)
      ctx.buf.addReg(rTos, rScratch0, rScratch1, is64 = false)
      ctx.tosValid = true

  of opLocalGetI32Sub:
    # TOS-aware: Y - local[X] where Y is current TOS
    let offset = instr.imm1.int32 * 8
    if ctx.tosValid:
      ctx.buf.ldrImm(rScratch0, rLocals, offset)
      ctx.buf.subReg(rTos, rTos, rScratch0, is64 = false)
    else:
      ctx.buf.ldrPreIdx(rScratch1, rVSP, -8)
      ctx.buf.ldrImm(rScratch0, rLocals, offset)
      ctx.buf.subReg(rTos, rScratch1, rScratch0, is64 = false)
      ctx.tosValid = true

  of opI32ConstI32Add:
    # TOS-aware: TOS + C → TOS cache
    let constVal = cast[int32](instr.imm1)
    ctx.emitEnsureTos()
    if constVal >= 0 and constVal <= 4095:
      ctx.buf.addImm(rTos, rTos, constVal.uint32, is64 = false)
    elif constVal < 0 and constVal >= -4095:
      ctx.buf.subImm(rTos, rTos, (-constVal).uint32, is64 = false)
    else:
      ctx.buf.loadImm32(rScratch1, constVal)
      ctx.buf.addReg(rTos, rTos, rScratch1, is64 = false)
    # tosValid stays true

  of opI32ConstI32Sub:
    let constVal = cast[int32](instr.imm1)
    ctx.emitEnsureTos()
    if constVal >= 0 and constVal <= 4095:
      ctx.buf.subImm(rTos, rTos, constVal.uint32, is64 = false)
    elif constVal < 0 and constVal >= -4095:
      ctx.buf.addImm(rTos, rTos, (-constVal).uint32, is64 = false)
    else:
      ctx.buf.loadImm32(rScratch1, constVal)
      ctx.buf.subReg(rTos, rTos, rScratch1, is64 = false)

  of opLocalSetLocalGet:
    ctx.emitFlushTos()
    let setIdx = instr.imm1.int32 * 8
    let getIdx = instr.imm2.int32 * 8
    ctx.emitPopX(rScratch0)
    ctx.buf.strImm(rScratch0, rLocals, setIdx)
    ctx.buf.ldrImm(rScratch0, rLocals, getIdx)
    ctx.emitPushX(rScratch0)

  of opLocalTeeLocalGet:
    ctx.emitFlushTos()
    let teeIdx = instr.imm1.int32 * 8
    let getIdx = instr.imm2.int32 * 8
    ctx.emitPeekX(rScratch0)
    ctx.buf.strImm(rScratch0, rLocals, teeIdx)
    ctx.buf.ldrImm(rScratch0, rLocals, getIdx)
    ctx.emitPushX(rScratch0)

  of opLocalGetI32Const:
    ctx.emitFlushTos()
    let localOffset = instr.imm1.int32 * 8
    let constVal = cast[int32](instr.imm2)
    ctx.buf.ldrImm(rScratch0, rLocals, localOffset)
    ctx.emitPushX(rScratch0)
    ctx.buf.loadImm32(rScratch0, constVal)
    ctx.emitPushX(rScratch0)

  of opI32AddLocalSet:
    # TOS-aware: use cached rTos directly (no MOV to scratch needed)
    let setIdx = instr.imm1.int32 * 8
    if ctx.tosValid:
      ctx.buf.ldrPreIdx(rScratch0, rVSP, -8)    # a = memory
      ctx.buf.addReg(rScratch0, rScratch0, rTos, is64 = false)
      ctx.tosValid = false
    else:
      ctx.emitPopPairX(rScratch0, rScratch1)
      ctx.buf.addReg(rScratch0, rScratch0, rScratch1, is64 = false)
    ctx.buf.strImm(rScratch0, rLocals, setIdx)

  of opI32SubLocalSet:
    let setIdx = instr.imm1.int32 * 8
    if ctx.tosValid:
      ctx.buf.ldrPreIdx(rScratch0, rVSP, -8)
      ctx.buf.subReg(rScratch0, rScratch0, rTos, is64 = false)
      ctx.tosValid = false
    else:
      ctx.emitPopPairX(rScratch0, rScratch1)
      ctx.buf.subReg(rScratch0, rScratch0, rScratch1, is64 = false)
    ctx.buf.strImm(rScratch0, rLocals, setIdx)

  of opI32EqzBrIf:
    ctx.emitFlushTos()
    # Pop value, branch if == 0 to label depth imm1
    let depth = instr.imm1.int
    ctx.emitPopX(rScratch0)
    let labelIdx = ctx.labels.len - 1 - depth
    if labelIdx >= 0 and labelIdx < ctx.labels.len:
      if ctx.labels[labelIdx].kind == lkLoop:
        let offset = ctx.labels[labelIdx].startPos - ctx.buf.pos
        ctx.buf.cbz(rScratch0, offset.int32, is64 = true)
      else:
        ctx.labels[labelIdx].patchList.add(ctx.buf.pos)
        ctx.buf.cbz(rScratch0, 0, is64 = true)
    else:
      ctx.emitTrap()

  of opLocalGetLocalGetI32Add:
    ctx.emitFlushTos()
    let idx0 = instr.imm1.int32 * 8
    let idx1 = instr.imm2.int32 * 8
    ctx.buf.ldrImm(rScratch0, rLocals, idx0)
    ctx.buf.ldrImm(rScratch1, rLocals, idx1)
    ctx.buf.addReg(rScratch0, rScratch0, rScratch1, is64 = false)
    ctx.emitPushX(rScratch0)

  of opLocalGetLocalGetI32Sub:
    ctx.emitFlushTos()
    let idx0 = instr.imm1.int32 * 8
    let idx1 = instr.imm2.int32 * 8
    ctx.buf.ldrImm(rScratch0, rLocals, idx0)
    ctx.buf.ldrImm(rScratch1, rLocals, idx1)
    ctx.buf.subReg(rScratch0, rScratch0, rScratch1, is64 = false)
    ctx.emitPushX(rScratch0)

  of opLocalGetI32ConstI32Sub:
    # Result → TOS cache (saves STR; next consumer reads rTos directly)
    ctx.emitFlushTos()
    let localOffset = instr.imm1.int32 * 8
    let constVal = cast[int32](instr.imm2)
    ctx.buf.ldrImm(rScratch0, rLocals, localOffset)
    if constVal >= 0 and constVal <= 4095:
      ctx.buf.subImm(rTos, rScratch0, constVal.uint32, is64 = false)
    elif constVal < 0 and constVal >= -4095:
      ctx.buf.addImm(rTos, rScratch0, (-constVal).uint32, is64 = false)
    else:
      ctx.buf.loadImm32(rScratch1, constVal)
      ctx.buf.subReg(rTos, rScratch0, rScratch1, is64 = false)
    ctx.tosValid = true

  of opLocalGetI32ConstI32Add:
    ctx.emitFlushTos()
    let localOffset = instr.imm1.int32 * 8
    let constVal = cast[int32](instr.imm2)
    ctx.buf.ldrImm(rScratch0, rLocals, localOffset)
    if constVal >= 0 and constVal <= 4095:
      ctx.buf.addImm(rTos, rScratch0, constVal.uint32, is64 = false)
    elif constVal < 0 and constVal >= -4095:
      ctx.buf.subImm(rTos, rScratch0, (-constVal).uint32, is64 = false)
    else:
      ctx.buf.loadImm32(rScratch1, constVal)
      ctx.buf.addReg(rTos, rScratch0, rScratch1, is64 = false)
    ctx.tosValid = true

  of opLocalGetLocalTee:
    ctx.emitFlushTos()
    let getIdx = instr.imm1.int32 * 8
    let teeIdx = instr.imm2.int32 * 8
    ctx.buf.ldrImm(rScratch0, rLocals, getIdx)
    ctx.emitPushX(rScratch0)
    # local.tee Y: peek TOS, store to local[Y]
    ctx.buf.strImm(rScratch0, rLocals, teeIdx)

  of opI32ConstI32GtU:
    ctx.emitFlushTos()
    let constVal = cast[int32](instr.imm1)
    ctx.emitPopX(rScratch0)  # value
    ctx.buf.loadImm32(rScratch1, constVal)
    ctx.buf.cmpReg(rScratch0, rScratch1, is64 = false)
    ctx.buf.cset(rScratch0, condHI)
    ctx.emitPushX(rScratch0)

  of opI32ConstI32LtS:
    ctx.emitFlushTos()
    let constVal = cast[int32](instr.imm1)
    ctx.emitPopX(rScratch0)
    ctx.buf.loadImm32(rScratch1, constVal)
    ctx.buf.cmpReg(rScratch0, rScratch1, is64 = false)
    ctx.buf.cset(rScratch0, condLT)
    ctx.emitPushX(rScratch0)

  of opI32ConstI32GeS:
    ctx.emitFlushTos()
    let constVal = cast[int32](instr.imm1)
    ctx.emitPopX(rScratch0)
    ctx.buf.loadImm32(rScratch1, constVal)
    ctx.buf.cmpReg(rScratch0, rScratch1, is64 = false)
    ctx.buf.cset(rScratch0, condGE)
    ctx.emitPushX(rScratch0)

  of opI32ConstI32Eq:
    # i32.const C; i32.eq → (TOS == C) ? 1 : 0
    ctx.emitFlushTos()
    let constVal = cast[int32](instr.imm1)
    ctx.emitPopX(rScratch0)
    ctx.buf.loadImm32(rScratch1, constVal)
    ctx.buf.cmpReg(rScratch0, rScratch1, is64 = false)
    ctx.buf.cset(rScratch0, condEQ)
    ctx.emitPushX(rScratch0)

  of opI32ConstI32Ne:
    # i32.const C; i32.ne → (TOS != C) ? 1 : 0
    ctx.emitFlushTos()
    let constVal = cast[int32](instr.imm1)
    ctx.emitPopX(rScratch0)
    ctx.buf.loadImm32(rScratch1, constVal)
    ctx.buf.cmpReg(rScratch0, rScratch1, is64 = false)
    ctx.buf.cset(rScratch0, condNE)
    ctx.emitPushX(rScratch0)

  of opLocalGetI32GtS:
    # local.get X; i32.gt_s → (TOS >s local[X]) ? 1 : 0
    ctx.emitFlushTos()
    let localOffset = instr.imm1.int32 * 8
    ctx.emitPopX(rScratch0)  # TOS (left operand)
    ctx.buf.ldrImm(rScratch1, rLocals, localOffset)
    ctx.buf.cmpReg(rScratch0, rScratch1, is64 = false)
    ctx.buf.cset(rScratch0, condGT)
    ctx.emitPushX(rScratch0)

  of opI32ConstI32And:
    # i32.const C; i32.and → TOS & C
    ctx.emitFlushTos()
    let constVal = cast[int32](instr.imm1)
    ctx.emitPopX(rScratch0)
    ctx.buf.loadImm32(rScratch1, constVal)
    ctx.buf.andReg(rScratch0, rScratch0, rScratch1, is64 = false)
    ctx.emitPushX(rScratch0)

  of opI32ConstI32Mul:
    # i32.const C; i32.mul → TOS * C
    ctx.emitFlushTos()
    let constVal = cast[int32](instr.imm1)
    ctx.emitPopX(rScratch0)
    ctx.buf.loadImm32(rScratch1, constVal)
    ctx.buf.mulReg(rScratch0, rScratch0, rScratch1, is64 = false)
    ctx.emitPushX(rScratch0)

  of opLocalGetI32Mul:
    # local.get X; i32.mul → TOS * local[X]
    if ctx.tosValid:
      let localOffset = instr.imm1.int32 * 8
      ctx.buf.ldrImm(rScratch0, rLocals, localOffset)
      ctx.buf.mulReg(rTos, rTos, rScratch0, is64 = false)
      # tosValid stays true
    else:
      ctx.emitFlushTos()
      let localOffset = instr.imm1.int32 * 8
      ctx.emitPopX(rScratch0)
      ctx.buf.ldrImm(rScratch1, rLocals, localOffset)
      ctx.buf.mulReg(rScratch0, rScratch0, rScratch1, is64 = false)
      ctx.emitPushX(rScratch0)

  of opLocalGetI32Load:
    # local.get X; i32.load off → push(mem[local[X] + off]) (imm1=X, imm2=off)
    ctx.emitFlushTos()
    let localOffset = instr.imm1.int32 * 8
    let memOffset = instr.imm2
    ctx.buf.ldrImm(rScratch0, rLocals, localOffset)  # addr = local[X]
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch1, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch1)
    # Bounds check: ea + 4 <= memSize
    ctx.buf.addImm(rScratch2, rScratch0, 4)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.ldrImm(rScratch0, rScratch0, 0, is64 = false)
    ctx.buf.b(2)
    ctx.emitTrap()
    ctx.emitPushX(rScratch0)

  of opLocalGetI32LoadI32Add:
    # local.get X; i32.load off; i32.add → push(TOS + mem[local[X]+off])
    # TOS is the left operand; the loaded value is added to it.
    ctx.emitFlushTos()
    let localOffset = instr.imm1.int32 * 8
    let memOffset = instr.imm2
    ctx.buf.ldrImm(rScratch0, rLocals, localOffset)  # addr = local[X]
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch1, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch1)
    # Bounds check: ea + 4 <= memSize
    ctx.buf.addImm(rScratch2, rScratch0, 4)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.ldrImm(rScratch1, rScratch0, 0, is64 = false)  # rScratch1 = loaded value
    ctx.buf.b(2)
    ctx.emitTrap()
    ctx.emitPopX(rScratch0)  # pop TOS (the accumulator)
    ctx.buf.addReg(rScratch0, rScratch0, rScratch1, is64 = false)
    ctx.emitPushX(rScratch0)

  of opLocalGetI32Store:
    ctx.emitFlushTos()
    let localIdx = instr.imm1.int32 * 8
    let memOffset = instr.imm2
    # local.get X pushes value, i32.store pops value and addr
    # Stack before: [..., addr]. local.get X pushes local[X]: [..., addr, local[X]]
    # i32.store pops value=local[X], addr.
    ctx.buf.ldrImm(rScratch1, rLocals, localIdx)  # value = local[X]
    ctx.emitPopX(rScratch0)  # address
    if memOffset > 0:
      if memOffset < 4096:
        ctx.buf.addImm(rScratch0, rScratch0, memOffset)
      else:
        ctx.buf.loadImm64(rScratch2, memOffset.uint64)
        ctx.buf.addReg(rScratch0, rScratch0, rScratch2)
    # Bounds check
    ctx.buf.addImm(rScratch2, rScratch0, 4)
    ctx.buf.cmpReg(rScratch2, rMemSize)
    ctx.buf.bCond(condHI, 3)
    ctx.buf.addReg(rScratch0, rMemBase, rScratch0)
    ctx.buf.strImm(rScratch1, rScratch0, 0, is64 = false)
    ctx.buf.b(2)
    ctx.emitTrap()

  # ---- New fused: decompose into constituent instruction calls ----

  of opI32EqBrIf:
    compileInstr(ctx, Instr(op: opI32Eq))
    compileInstr(ctx, Instr(op: opBrIf, imm1: instr.imm1))
  of opI32NeBrIf:
    compileInstr(ctx, Instr(op: opI32Ne))
    compileInstr(ctx, Instr(op: opBrIf, imm1: instr.imm1))
  of opI32LtSBrIf:
    compileInstr(ctx, Instr(op: opI32LtS))
    compileInstr(ctx, Instr(op: opBrIf, imm1: instr.imm1))
  of opI32GeSBrIf:
    compileInstr(ctx, Instr(op: opI32GeS))
    compileInstr(ctx, Instr(op: opBrIf, imm1: instr.imm1))
  of opI32GtSBrIf:
    compileInstr(ctx, Instr(op: opI32GtS))
    compileInstr(ctx, Instr(op: opBrIf, imm1: instr.imm1))
  of opI32LeSBrIf:
    compileInstr(ctx, Instr(op: opI32LeS))
    compileInstr(ctx, Instr(op: opBrIf, imm1: instr.imm1))
  of opI32LtUBrIf:
    compileInstr(ctx, Instr(op: opI32LtU))
    compileInstr(ctx, Instr(op: opBrIf, imm1: instr.imm1))
  of opI32GeUBrIf:
    compileInstr(ctx, Instr(op: opI32GeU))
    compileInstr(ctx, Instr(op: opBrIf, imm1: instr.imm1))
  of opI32GtUBrIf:
    compileInstr(ctx, Instr(op: opI32GtU))
    compileInstr(ctx, Instr(op: opBrIf, imm1: instr.imm1))
  of opI32LeUBrIf:
    compileInstr(ctx, Instr(op: opI32LeU))
    compileInstr(ctx, Instr(op: opBrIf, imm1: instr.imm1))

  of opI32ConstI32EqBrIf:
    compileInstr(ctx, Instr(op: opI32Const, imm1: instr.imm1))
    compileInstr(ctx, Instr(op: opI32Eq))
    compileInstr(ctx, Instr(op: opBrIf, imm1: instr.imm2))
  of opI32ConstI32NeBrIf:
    compileInstr(ctx, Instr(op: opI32Const, imm1: instr.imm1))
    compileInstr(ctx, Instr(op: opI32Ne))
    compileInstr(ctx, Instr(op: opBrIf, imm1: instr.imm2))
  of opI32ConstI32LtSBrIf:
    compileInstr(ctx, Instr(op: opI32Const, imm1: instr.imm1))
    compileInstr(ctx, Instr(op: opI32LtS))
    compileInstr(ctx, Instr(op: opBrIf, imm1: instr.imm2))
  of opI32ConstI32GeSBrIf:
    compileInstr(ctx, Instr(op: opI32Const, imm1: instr.imm1))
    compileInstr(ctx, Instr(op: opI32GeS))
    compileInstr(ctx, Instr(op: opBrIf, imm1: instr.imm2))
  of opI32ConstI32GtUBrIf:
    compileInstr(ctx, Instr(op: opI32Const, imm1: instr.imm1))
    compileInstr(ctx, Instr(op: opI32GtU))
    compileInstr(ctx, Instr(op: opBrIf, imm1: instr.imm2))
  of opI32ConstI32LeUBrIf:
    compileInstr(ctx, Instr(op: opI32Const, imm1: instr.imm1))
    compileInstr(ctx, Instr(op: opI32LeU))
    compileInstr(ctx, Instr(op: opBrIf, imm1: instr.imm2))

  of opLocalGetI64Add:
    compileInstr(ctx, Instr(op: opLocalGet, imm1: instr.imm1))
    compileInstr(ctx, Instr(op: opI64Add))
  of opLocalGetI64Sub:
    compileInstr(ctx, Instr(op: opLocalGet, imm1: instr.imm1))
    compileInstr(ctx, Instr(op: opI64Sub))

  of opLocalI32AddInPlace:
    compileInstr(ctx, Instr(op: opLocalGet, imm1: instr.imm1))
    compileInstr(ctx, Instr(op: opI32Const, imm1: instr.imm2))
    compileInstr(ctx, Instr(op: opI32Add))
    compileInstr(ctx, Instr(op: opLocalSet, imm1: instr.imm1))
  of opLocalI32SubInPlace:
    compileInstr(ctx, Instr(op: opLocalGet, imm1: instr.imm1))
    compileInstr(ctx, Instr(op: opI32Const, imm1: instr.imm2))
    compileInstr(ctx, Instr(op: opI32Sub))
    compileInstr(ctx, Instr(op: opLocalSet, imm1: instr.imm1))
  of opLocalGetLocalGetI32AddLocalSet:
    let x = instr.imm1 and 0xFFFF'u32
    let y = instr.imm1 shr 16
    compileInstr(ctx, Instr(op: opLocalGet, imm1: x))
    compileInstr(ctx, Instr(op: opLocalGet, imm1: y))
    compileInstr(ctx, Instr(op: opI32Add))
    compileInstr(ctx, Instr(op: opLocalSet, imm1: instr.imm2))
  of opLocalGetLocalGetI32SubLocalSet:
    let x = instr.imm1 and 0xFFFF'u32
    let y = instr.imm1 shr 16
    compileInstr(ctx, Instr(op: opLocalGet, imm1: x))
    compileInstr(ctx, Instr(op: opLocalGet, imm1: y))
    compileInstr(ctx, Instr(op: opI32Sub))
    compileInstr(ctx, Instr(op: opLocalSet, imm1: instr.imm2))

  of opLocalTeeBrIf:
    # Fused: local.tee X + br_if L → pop TOS, store to local, branch on value.
    # Avoids the STR+LDR store-forward stall from decomposition (opLocalTee
    # flushes TOS to memory, opBrIf immediately reloads it).
    let localOffset = instr.imm1.int32 * 8
    if ctx.tosValid:
      # TOS cached in rTos — use it directly (no MOV, no memory traffic)
      ctx.buf.strImm(rTos, rLocals, localOffset)
      ctx.tosValid = false  # consumed
      let depth = instr.imm2.int
      let labelIdx = ctx.labels.len - 1 - depth
      if labelIdx >= 0 and labelIdx < ctx.labels.len:
        if ctx.labels[labelIdx].kind == lkLoop:
          let brOffset = ctx.labels[labelIdx].startPos - ctx.buf.pos
          ctx.buf.cbnz(rTos, brOffset.int32, is64 = true)
        else:
          ctx.labels[labelIdx].patchList.add(ctx.buf.pos)
          ctx.buf.cbnz(rTos, 0, is64 = true)
      else:
        ctx.emitTrap()
    else:
      # TOS on memory stack — pop, store, branch
      ctx.buf.ldrPreIdx(rScratch0, rVSP, -8)
      ctx.buf.strImm(rScratch0, rLocals, localOffset)
      let depth = instr.imm2.int
      let labelIdx = ctx.labels.len - 1 - depth
      if labelIdx >= 0 and labelIdx < ctx.labels.len:
        if ctx.labels[labelIdx].kind == lkLoop:
          let brOffset = ctx.labels[labelIdx].startPos - ctx.buf.pos
          ctx.buf.cbnz(rScratch0, brOffset.int32, is64 = true)
        else:
          ctx.labels[labelIdx].patchList.add(ctx.buf.pos)
          ctx.buf.cbnz(rScratch0, 0, is64 = true)
      else:
        ctx.emitTrap()

  # ---- Function calls ----
  of opCall:
    ctx.emitFlushTos()
    let funcIdx = instr.imm1.int
    let isSelfCall = funcIdx == ctx.selfIdx and ctx.selfEntry >= 0
    if funcIdx < ctx.callTargets.len and
       (ctx.callTargets[funcIdx].jitAddr != nil or isSelfCall):
      let target = ctx.callTargets[funcIdx]
      # JIT-to-JIT call: callee uses same ABI (x0=vsp, x1=locals, x2=memBase, x3=memSize)
      # 1. Allocate locals + globals on the native stack for the callee.
      #    Globals are appended after locals so callee can access them
      #    at locals[localCount + globalIdx].
      let totalSlots = target.localCount + target.globalsCount
      let localsBytes = ((totalSlots * 8 + 15) and (not 15))
      if localsBytes > 0:
        ctx.buf.subImm(sp, sp, localsBytes.uint32)

      # 2. Pop args from value stack into callee locals on native stack
      #    Args are on VSP in order: arg0 at bottom. Pop in reverse.
      for i in countdown(target.paramCount - 1, 0):
        ctx.emitPopX(rScratch0)
        ctx.buf.strImm(rScratch0, sp, (i * 8).int32)

      # 3. Zero remaining locals (params are set, zero the rest)
      if target.localCount > target.paramCount:
        ctx.buf.movz(rScratch0, 0)
        for i in target.paramCount ..< target.localCount:
          ctx.buf.strImm(rScratch0, sp, (i * 8).int32)

      # 3b. Copy globals from caller's locals to callee's locals.
      #     Caller's globals are at rLocals[globalsOffset..].
      #     Callee's globals are at sp[target.localCount*8..].
      if target.globalsCount > 0:
        for i in 0 ..< target.globalsCount:
          let callerOff = ctx.globalsOffset + i * 8
          let calleeOff = target.localCount * 8 + i * 8
          if callerOff < 32760:
            ctx.buf.ldrImm(rScratch0, rLocals, callerOff.int32)
          else:
            ctx.buf.loadImm64(rScratch0, callerOff.uint64)
            ctx.buf.addReg(rScratch0, rLocals, rScratch0)
            ctx.buf.ldrImm(rScratch0, rScratch0, 0)
          if calleeOff < 32760:
            ctx.buf.strImm(rScratch0, sp, calleeOff.int32)
          else:
            ctx.buf.loadImm64(rScratch1, calleeOff.uint64)
            ctx.buf.addReg(rScratch1, sp, rScratch1)
            ctx.buf.strImm(rScratch0, rScratch1, 0)

      # 4. Save our WASM state registers (callee will clobber them)
      ctx.buf.stpPreIdx(rVSP, rLocals, sp, -16)       # push x8, x9
      let savedBytes = if ctx.usesMemory:
        ctx.buf.stpPreIdx(rMemBase, rMemSize, sp, -16)   # push x10, x11
        32
      else:
        16

      # 5. Set up callee ABI args
      ctx.buf.movReg(x0, rVSP)          # x0 = current VSP (callee pushes results here)
      ctx.buf.addImm(x1, sp, savedBytes.uint32) # x1 = locals pointer (past saved regs)
      if ctx.usesMemory:
        ctx.buf.movReg(x2, rMemBase)      # x2 = memBase (shared)
        ctx.buf.movReg(x3, rMemSize)      # x3 = memSize (shared)

      # 6. Call the target
      if isSelfCall:
        # Self-recursive call: branch to own entry
        let offset = ctx.selfEntry - ctx.buf.pos
        ctx.buf.bl(offset.int32)
      else:
        # Call via register
        ctx.buf.loadImm64(rScratch0, cast[uint64](target.jitAddr))
        ctx.buf.blr(rScratch0)

      # 7. Restore WASM state registers
      if ctx.usesMemory:
        ctx.buf.ldpPostIdx(rMemBase, rMemSize, sp, 16)   # pop x10, x11
      ctx.buf.ldpPostIdx(rVSP, rLocals, sp, 16)        # pop x8, x9

      # 8. Copy callee's globals back to caller's locals.
      #    The callee may have modified globals (e.g., __stack_pointer via global.set).
      #    Callee's locals are still on the native stack at sp[0..].
      #    Caller's locals are at rLocals (just restored in step 7).
      if target.globalsCount > 0:
        for i in 0 ..< target.globalsCount:
          let calleeOff = target.localCount * 8 + i * 8
          let callerOff = ctx.globalsOffset + i * 8
          if calleeOff < 32760:
            ctx.buf.ldrImm(rScratch0, sp, calleeOff.int32)
          else:
            ctx.buf.loadImm64(rScratch0, calleeOff.uint64)
            ctx.buf.addReg(rScratch0, sp, rScratch0)
            ctx.buf.ldrImm(rScratch0, rScratch0, 0)
          if callerOff < 32760:
            ctx.buf.strImm(rScratch0, rLocals, callerOff.int32)
          else:
            ctx.buf.loadImm64(rScratch1, callerOff.uint64)
            ctx.buf.addReg(rScratch1, rLocals, rScratch1)
            ctx.buf.strImm(rScratch0, rScratch1, 0)

      # 9. x0 = callee's returned VSP; results are on our value stack
      #    Update our VSP to the callee's returned VSP
      ctx.buf.movReg(rVSP, x0)

      # 10. Deallocate callee locals from native stack
      if localsBytes > 0:
        ctx.buf.addImm(sp, sp, localsBytes.uint32)
    else:
      # Target not JIT'd — trap for now (tier.nim handles fallback)
      ctx.emitTrap()

  of opCallIndirect:
    ctx.emitFlushTos()
    let typeIdx = instr.imm1.int
    # Determine expected param/result counts from the type signature
    var paramCount = 0
    var resultCount = 0
    if ctx.moduleTypes != nil and typeIdx < ctx.moduleTypes[].len:
      let ft = ctx.moduleTypes[][typeIdx]
      paramCount = ft.params.len
      resultCount = ft.results.len

    # Allocate a per-site CallIndirectCache on the shared heap
    let cache = cast[ptr CallIndirectCache](allocShared0(sizeof(CallIndirectCache)))
    cache.cachedElemIdx = -1
    cache.tableElems = ctx.tableElems
    cache.tableLen = ctx.tableElemsLen.int32
    cache.paramCount = paramCount.int32
    cache.resultCount = resultCount.int32
    if ctx.poolRef != nil:
      ctx.poolRef[].sideData.add(cast[pointer](cache))

    # 1. Pop elemIdx from WASM value stack into rScratch0 (x12)
    ctx.emitPopX(rScratch0)

    # 2. Set up args for callIndirectDispatch:
    #    x0=cache, x1=elemIdx, x2=vsp, x3=locals, x4=memBase, x5=memSize
    ctx.buf.loadImm64(x0, cast[uint64](cache))
    ctx.buf.movReg(x1, rScratch0)   # elemIdx (low 32 bits = int32)
    ctx.buf.movReg(x2, rVSP)        # VSP after popping elemIdx (args are below)
    ctx.buf.movReg(x3, rLocals)     # caller's locals
    ctx.buf.movReg(x4, rMemBase)    # memBase
    ctx.buf.movReg(x5, rMemSize)    # memSize

    # 3. Save WASM state registers (BLR clobbers x0-x18)
    ctx.buf.stpPreIdx(rVSP, rLocals, sp, -16)
    ctx.buf.stpPreIdx(rMemBase, rMemSize, sp, -16)

    # 4. Call the dispatch helper
    ctx.buf.loadImm64(rScratch0, cast[uint64](callIndirectDispatch))
    ctx.buf.blr(rScratch0)

    # 5. Restore WASM state registers
    ctx.buf.ldpPostIdx(rMemBase, rMemSize, sp, 16)
    ctx.buf.ldpPostIdx(rVSP, rLocals, sp, 16)

    # 6. x0 = new VSP (or nil on trap); branch to trap on nil
    let trapPatch = ctx.buf.pos
    ctx.buf.cbz(x0, 0)              # placeholder: if nil, jump to trap

    # 7. Success: update rVSP with the returned VSP
    ctx.buf.movReg(rVSP, x0)

    # 8. Skip over the trap instruction
    let skipPatch = ctx.buf.pos
    ctx.buf.b(0)                    # placeholder: jump past trap

    # 9. Trap site — patch the CBZ to branch here
    let trapSite = ctx.buf.pos
    let cbzInst = ctx.buf.code[trapPatch]
    let sfAndRt = cbzInst and 0x800000FF'u32
    ctx.buf.patchAt(trapPatch,
      sfAndRt or 0x34000000'u32 or
      (((trapSite - trapPatch).uint32 and 0x7FFFF) shl 5))
    ctx.emitTrap()                  # BRK #1

    # 10. Continue site — patch the B to branch here
    let continueSite = ctx.buf.pos
    ctx.buf.patchAt(skipPatch,
      0x14000000'u32 or ((continueSite - skipPatch).uint32 and 0x03FFFFFF))

  # ---- Global variables ----
  of opGlobalGet:
    ctx.emitFlushTos()
    let offset = ctx.globalsOffset + instr.imm1.int * 8
    if offset < 32760:  # LDR unsigned imm12 range (scaled by 8): 0..32760
      ctx.buf.ldrImm(rScratch0, rLocals, offset.int32)
    else:
      ctx.buf.loadImm64(rScratch0, offset.uint64)
      ctx.buf.addReg(rScratch0, rLocals, rScratch0)
      ctx.buf.ldrImm(rScratch0, rScratch0, 0)
    ctx.emitPushX(rScratch0)

  of opGlobalSet:
    ctx.emitFlushTos()
    ctx.emitPopX(rScratch0)
    let offset = ctx.globalsOffset + instr.imm1.int * 8
    if offset < 32760:
      ctx.buf.strImm(rScratch0, rLocals, offset.int32)
    else:
      ctx.buf.loadImm64(rScratch1, offset.uint64)
      ctx.buf.addReg(rScratch1, rLocals, rScratch1)
      ctx.buf.strImm(rScratch0, rScratch1, 0)

  # ---- Memory size/grow ----
  of opMemorySize:
    ctx.emitFlushTos()
    # Memory size in pages: memSize (bytes) >> 16
    # LSR imm via UBFM Xd, Xn, #16, #63 — encoding: 1 10 100110 1 immr imms Rn Rd
    # sf=1, opc=10, N=1, immr=16, imms=63
    ctx.buf.emit(0xD340FC00'u32 or (rMemSize.uint8.uint32 shl 5) or rScratch0.uint8.uint32 or
                 (16'u32 shl 16))  # UBFM X<s0>, X<memSize>, #16, #63
    ctx.emitPushX(rScratch0)

  of opMemoryGrow:
    ctx.emitFlushTos()
    # memory.grow requires runtime support (may reallocate) — trap for now
    ctx.emitTrap()

  # ---- Reference types ----
  of opRefNull:
    ctx.emitFlushTos()
    # Push null ref as -1 (0xFFFFFFFF for 32-bit ref, but use full 64-bit -1)
    ctx.buf.loadImm64(rScratch0, 0xFFFFFFFF'u64)
    ctx.emitPushX(rScratch0)

  of opRefIsNull:
    ctx.emitFlushTos()
    # Pop ref, compare with null (-1 / 0xFFFFFFFF), push 1 if null else 0
    ctx.emitPopX(rScratch0)
    # Mask to 32-bit for ref comparison
    ctx.buf.movReg(rScratch0, rScratch0, is64 = false)  # zero-extend 32-bit
    ctx.buf.loadImm32(rScratch1, cast[int32](0xFFFFFFFF'u32))
    ctx.buf.cmpReg(rScratch0, rScratch1, is64 = false)
    ctx.buf.cset(rScratch0, condEQ)
    ctx.emitPushX(rScratch0)

  of opRefFunc:
    ctx.emitFlushTos()
    # Push function index as the ref value
    let funcIdx = instr.imm1
    ctx.buf.loadImm32(rScratch0, cast[int32](funcIdx))
    ctx.emitPushX(rScratch0)

  # ---- Table operations (require runtime support) ----
  of opTableGet, opTableSet:
    ctx.emitFlushTos()
    ctx.emitTrap()

  # ---- Bulk memory/table operations (require runtime support) ----
  of opMemoryInit, opDataDrop, opMemoryCopy, opMemoryFill,
     opElemDrop, opTableInit, opTableCopy, opTableFill:
    ctx.emitFlushTos()
    ctx.emitTrap()

  # ---- Everything else: trap (fall back to interpreter) ----
  else:
    ctx.emitFlushTos()
    ctx.emitTrap()

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc compileFunction*(pool: var JitMemPool, module: WasmModule,
                      funcIdx: int,
                      callTargets: seq[CallTarget] = @[],
                      tableData: seq[TableElem] = @[],
                      globalsOffset: int = 0,
                      selfIdx: int = -1): JitCompiledFunc =
  ## Compile a single WASM function to AArch64 machine code.
  ## `funcIdx` is the index into module.codes (not counting imports).
  ## `callTargets` provides resolved addresses for call instructions.
  ## `tableData` provides pre-resolved table 0 elements for call_indirect.
  ## `globalsOffset` is the byte offset into the locals array where globals
  ## are placed (i.e., totalLocals * 8).
  assert funcIdx >= 0 and funcIdx < module.codes.len,
    "funcIdx out of range: " & $funcIdx & " (module has " & $module.codes.len & " code entries)"

  # Allocate table element data on the shared heap (lifetime tied to pool)
  var tableElemsPtr: ptr UncheckedArray[TableElem] = nil
  let tableElemsLen = tableData.len
  if tableData.len > 0:
    let dataBytes = tableData.len * sizeof(TableElem)
    let dataMem = allocShared0(dataBytes)
    pool.sideData.add(dataMem)
    tableElemsPtr = cast[ptr UncheckedArray[TableElem]](dataMem)
    for i in 0 ..< tableData.len:
      tableElemsPtr[i] = tableData[i]

  let body = module.codes[funcIdx]

  # Pre-scan bytecode for memory operations to skip x10/x11 setup when unused
  var usesMemory = false
  for instr in body.code.code:
    if instr.op in {opI32Load, opI64Load, opF32Load, opF64Load,
                    opI32Load8S, opI32Load8U, opI32Load16S, opI32Load16U,
                    opI64Load8S, opI64Load8U, opI64Load16S, opI64Load16U,
                    opI64Load32S, opI64Load32U,
                    opI32Store, opI64Store, opF32Store, opF64Store,
                    opI32Store8, opI32Store16, opI64Store8, opI64Store16, opI64Store32,
                    opMemorySize, opMemoryGrow, opMemoryFill, opMemoryCopy,
                    opLocalGetI32Store, opLocalGetI32Load, opLocalGetI32LoadI32Add}:
      usesMemory = true
      break

  var brTables = body.code.brTables
  var moduleTypesCopy = module.types  # copy to keep a stable reference
  var ctx = CompilerCtx(
    buf: initAsmBuffer(body.code.code.len * 4),
    labels: @[],
    callTargets: callTargets,
    selfIdx: selfIdx,
    selfEntry: -1,
    brTablesRef: if brTables.len > 0: brTables.addr else: nil,
    globalsOffset: globalsOffset,
    tosValid: false,
    usesMemory: usesMemory,
    moduleTypes: moduleTypesCopy.addr,
    tableElems: tableElemsPtr,
    tableElemsLen: tableElemsLen,
    poolRef: pool.addr,
  )

  # Emit prologue (sets ctx.selfEntry for self-recursive calls)
  ctx.emitPrologue()

  # Push an implicit function-level block that opEnd at the end will pop
  ctx.labels.add(Label(kind: lkBlock, patchList: @[], startPos: ctx.buf.pos,
                        elsePos: -1, hasElse: false))

  # Compile each instruction
  for i in 0 ..< body.code.code.len:
    ctx.compileInstr(body.code.code[i])

  # If the label stack still has the function-level block, pop and patch it
  if ctx.labels.len > 0:
    let label = ctx.labels.pop()
    ctx.patchForwardBranches(label)

  # Flush TOS cache before epilogue (ensure VSP reflects true stack state)
  ctx.emitFlushTos()

  # Emit epilogue (function fall-through)
  ctx.emitEpilogue()

  # Write code to executable memory
  let jitCode = pool.writeCode(ctx.buf.code)

  result = JitCompiledFunc(code: jitCode, funcIdx: funcIdx)

proc getFuncPtr*(compiled: JitCompiledFunc): JitFuncPtr =
  ## Cast the compiled code address to a callable function pointer
  cast[JitFuncPtr](compiled.code.address)
