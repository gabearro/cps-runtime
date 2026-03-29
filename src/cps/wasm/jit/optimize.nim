## Optimization passes that operate on the SSA IR
##
## Passes:
##   1. constantFold      — Evaluate constant expressions at compile time
##   2. strengthReduce    — Replace expensive ops with cheaper equivalents
##   3. commonSubexprElim — Reuse duplicate computations within a basic block
##   4. deadCodeElim      — Remove instructions with unused results
##   5. boundsCheckElim   — Eliminate redundant memory access bounds checks
##   6. peepholeAarch64   — Post-codegen AArch64 instruction simplification
##   7. instrCombine      — Multi-instruction pattern recognition and fusion
## (peepholeX64 lives in ircodegen_x64.nim, uses X64AsmBuffer directly)

import ir
import codegen
import std/[tables, sets]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

type
  ConstInfo = tuple[known: bool, val: int64]

# Bit flag in imm2 to indicate "bounds check already covered"
const boundsCheckedFlag* = 0x40000000'i32

proc accessSize*(op: IrOpKind): int32 =
  ## Byte width of a memory load/store instruction, or 0 for non-memory ops.
  case op
  of irLoad8U, irLoad8S, irStore8: 1
  of irLoad16U, irLoad16S, irStore16: 2
  of irLoad32, irLoad32U, irLoad32S, irStore32, irStore32From64: 4
  of irLoad64, irStore64: 8
  of irLoadF32, irStoreF32: 4
  of irLoadF64, irStoreF64: 8
  else: 0

const pureOps* = {irConst32, irConst64,
  irAdd32, irSub32, irMul32, irDiv32S, irDiv32U, irRem32S, irRem32U,
  irAnd32, irOr32, irXor32, irShl32, irShr32S, irShr32U,
  irRotl32, irRotr32, irClz32, irCtz32, irPopcnt32, irEqz32,
  irAdd64, irSub64, irMul64, irDiv64S, irDiv64U, irRem64S, irRem64U,
  irAnd64, irOr64, irXor64, irShl64, irShr64S, irShr64U,
  irRotl64, irRotr64, irClz64, irCtz64, irPopcnt64, irEqz64,
  irEq32, irNe32, irLt32S, irLt32U, irGt32S, irGt32U,
  irLe32S, irLe32U, irGe32S, irGe32U,
  irEq64, irNe64, irLt64S, irLt64U, irGt64S, irGt64U,
  irLe64S, irLe64U, irGe64S, irGe64U,
  irWrapI64, irExtendI32S, irExtendI32U,
  irExtend8S32, irExtend16S32, irExtend8S64, irExtend16S64, irExtend32S64,
  irSelect, irNop}

const pureOpsWithFma* = pureOps + {
  irFmaF32, irFmsF32, irFnmaF32, irFnmsF32,
  irFmaF64, irFmsF64, irFnmaF64, irFnmsF64}

proc isPowerOfTwo(v: int64): bool =
  v > 0 and (v and (v - 1)) == 0

proc isRealBackEdge*(f: IrFunc, header: int, backEdge: int): bool =
  ## Return true iff there is a forward path from `header` to `backEdge`
  ## using only blocks with indices in [header, backEdge].
  ##
  ## This distinguishes genuine loop back-edges (where the loop body is
  ## reachable from the header within the range) from false positives that
  ## arise in inlined diamond/if-else patterns (where a "merge" block has a
  ## higher-indexed predecessor that is not reachable from the merge itself).
  if header < 0 or backEdge < header or backEdge >= f.blocks.len:
    return false
  if header == backEdge:
    return true
  let rangeLen = backEdge - header + 1
  var reachable = newSeq[bool](rangeLen)
  reachable[0] = true  # header is trivially reachable from itself
  var changed = true
  while changed:
    changed = false
    for i in 0 ..< rangeLen:
      if not reachable[i]: continue
      for succ in f.blocks[header + i].successors:
        if succ >= header and succ <= backEdge:
          let j = succ - header
          if not reachable[j]:
            reachable[j] = true
            changed = true
  result = reachable[backEdge - header]

proc log2Int(v: int64): int =
  ## Number of trailing zero bits (log2 for power-of-two values)
  assert v > 0
  result = 0
  var x = v
  while x > 1:
    x = x shr 1
    inc result

const sideEffectOps* = {irStore32, irStore64, irStore8, irStore16, irStore32From64,
                         irStoreF32, irStoreF64,
                         irLocalSet, irBr, irBrIf, irReturn, irCall, irTrap}

const loadOps = {irLoad32, irLoad64, irLoad8U, irLoad8S, irLoad16U, irLoad16S,
                 irLoad32U, irLoad32S, irLoadF32, irLoadF64}

const storeOps = {irStore32, irStore64, irStore8, irStore16, irStore32From64,
                  irStoreF32, irStoreF64}

proc buildConstantMap(f: IrFunc): seq[ConstInfo] =
  ## Scan all blocks and collect known constant values
  result = newSeq[ConstInfo](f.numValues)
  for bb in f.blocks:
    for instr in bb.instrs:
      if instr.op in {irConst32, irConst64} and instr.result >= 0:
        result[instr.result.int] = (true, instr.imm)

# ---------------------------------------------------------------------------
# Pointer origin analysis (helper for alias-aware BCE)
# ---------------------------------------------------------------------------

type PtrOrigin* = tuple[root: IrValue, offset: int64]

proc buildPtrOrigins*(f: IrFunc): seq[PtrOrigin] =
  ## Flow-insensitive pointer origin analysis.
  ##
  ## For each SSA value, determine the canonical (root, offset) where
  ##   value = root + offset
  ## where root is an SSA value that cannot be traced further as a
  ## constant-offset add/sub or alias copy.
  ##
  ## Supported def patterns:
  ##   irAdd32/64  where one operand is a known constant → follow the other
  ##   irSub32/64  where the subtracted operand is a known constant
  ##   irNop       (copy/alias produced by localValueForward, strengthReduce,
  ##               etc.) → propagate the origin of the source value
  ##
  ## Because WASM SSA has structured control flow (definitions dominate uses
  ## in block-index order), a single forward pass across all blocks is enough
  ## to resolve chains correctly, including multi-level derivations such as
  ##   ptr2 = ptr  + 4   (origin: (ptr, 4))
  ##   ptr3 = ptr2 + 8   (origin: (ptr, 12))  ← correctly chained
  ##
  ## Phi nodes and non-constant-offset additions stop the chain (origin
  ## becomes the value itself at offset 0), which is the safe fallback.
  let constants = buildConstantMap(f)
  result = newSeq[PtrOrigin](f.numValues)
  for i in 0 ..< f.numValues:
    result[i] = (IrValue(i), 0'i64)   # default: identity

  for bb in f.blocks:
    for instr in bb.instrs:
      let v = instr.result
      if v < 0 or v.int >= result.len: continue
      let a = instr.operands[0]
      let b = instr.operands[1]
      case instr.op
      of irAdd32, irAdd64:
        if a >= 0 and b >= 0:
          if b.int < constants.len and constants[b.int].known:
            let ao = result[a.int]
            result[v.int] = (ao.root, ao.offset + constants[b.int].val)
          elif a.int < constants.len and constants[a.int].known:
            let bo = result[b.int]
            result[v.int] = (bo.root, bo.offset + constants[a.int].val)
      of irSub32, irSub64:
        if a >= 0 and b >= 0 and b.int < constants.len and constants[b.int].known:
          let ao = result[a.int]
          result[v.int] = (ao.root, ao.offset - constants[b.int].val)
      of irNop:
        # Copy / alias: propagate origin of the source value.
        # irNop with operands[0] >= 0 is a value copy (result = operands[0]).
        if a >= 0 and a.int < result.len:
          result[v.int] = result[a.int]
      else: discard

# ---------------------------------------------------------------------------
# 1. Constant Folding
# ---------------------------------------------------------------------------

proc constantFold*(f: var IrFunc) =
  ## Walk all instructions. If both operands of a binary op are known constants,
  ## compute the result at compile time and replace with a constant instruction.
  var constants = newSeq[ConstInfo](f.numValues)

  for bb in f.blocks.mitems:
    var i = 0
    while i < bb.instrs.len:
      let instr = bb.instrs[i]

      # Track constants (including float bit patterns)
      if instr.op in {irConst32, irConst64, irConstF32, irConstF64} and instr.result >= 0:
        constants[instr.result.int] = (true, instr.imm)
        inc i
        continue

      # Binary ops with two constant operands
      if instr.operands[0] >= 0 and instr.operands[1] >= 0:
        let ca = constants[instr.operands[0].int]
        let cb = constants[instr.operands[1].int]
        if ca.known and cb.known:
          var folded = false
          var foldedVal: int64

          case instr.op
          of irAdd32:
            foldedVal = (cast[int32](ca.val) + cast[int32](cb.val)).int64
            folded = true
          of irSub32:
            foldedVal = (cast[int32](ca.val) - cast[int32](cb.val)).int64
            folded = true
          of irMul32:
            foldedVal = (cast[int32](ca.val) * cast[int32](cb.val)).int64
            folded = true
          of irAnd32:
            foldedVal = (cast[int32](ca.val) and cast[int32](cb.val)).int64
            folded = true
          of irOr32:
            foldedVal = (cast[int32](ca.val) or cast[int32](cb.val)).int64
            folded = true
          of irXor32:
            foldedVal = (cast[int32](ca.val) xor cast[int32](cb.val)).int64
            folded = true
          of irShl32:
            foldedVal = (cast[int32](ca.val) shl (cast[int32](cb.val) and 31)).int64
            folded = true
          of irShr32U:
            foldedVal = (cast[uint32](ca.val) shr (cast[int32](cb.val) and 31)).int64
            folded = true
          of irShr32S:
            foldedVal = (cast[int32](ca.val) shr (cast[int32](cb.val) and 31)).int64
            folded = true

          of irAdd64:
            foldedVal = ca.val + cb.val
            folded = true
          of irSub64:
            foldedVal = ca.val - cb.val
            folded = true
          of irMul64:
            foldedVal = ca.val * cb.val
            folded = true
          of irAnd64:
            foldedVal = ca.val and cb.val
            folded = true
          of irOr64:
            foldedVal = ca.val or cb.val
            folded = true
          of irXor64:
            foldedVal = ca.val xor cb.val
            folded = true
          of irShl64:
            foldedVal = ca.val shl (cb.val and 63).int
            folded = true
          of irShr64U:
            foldedVal = cast[int64](cast[uint64](ca.val) shr (cb.val and 63).int)
            folded = true
          of irShr64S:
            foldedVal = ca.val shr (cb.val and 63).int
            folded = true

          # Comparisons (i32)
          of irEq32:
            foldedVal = (if cast[int32](ca.val) == cast[int32](cb.val): 1'i64 else: 0'i64)
            folded = true
          of irNe32:
            foldedVal = (if cast[int32](ca.val) != cast[int32](cb.val): 1'i64 else: 0'i64)
            folded = true
          of irLt32S:
            foldedVal = (if cast[int32](ca.val) < cast[int32](cb.val): 1'i64 else: 0'i64)
            folded = true
          of irLt32U:
            foldedVal = (if cast[uint32](ca.val) < cast[uint32](cb.val): 1'i64 else: 0'i64)
            folded = true
          of irGt32S:
            foldedVal = (if cast[int32](ca.val) > cast[int32](cb.val): 1'i64 else: 0'i64)
            folded = true
          of irGt32U:
            foldedVal = (if cast[uint32](ca.val) > cast[uint32](cb.val): 1'i64 else: 0'i64)
            folded = true
          of irLe32S:
            foldedVal = (if cast[int32](ca.val) <= cast[int32](cb.val): 1'i64 else: 0'i64)
            folded = true
          of irLe32U:
            foldedVal = (if cast[uint32](ca.val) <= cast[uint32](cb.val): 1'i64 else: 0'i64)
            folded = true
          of irGe32S:
            foldedVal = (if cast[int32](ca.val) >= cast[int32](cb.val): 1'i64 else: 0'i64)
            folded = true
          of irGe32U:
            foldedVal = (if cast[uint32](ca.val) >= cast[uint32](cb.val): 1'i64 else: 0'i64)
            folded = true

          # Comparisons (i64)
          of irEq64:
            foldedVal = (if ca.val == cb.val: 1'i64 else: 0'i64)
            folded = true
          of irNe64:
            foldedVal = (if ca.val != cb.val: 1'i64 else: 0'i64)
            folded = true
          of irLt64S:
            foldedVal = (if ca.val < cb.val: 1'i64 else: 0'i64)
            folded = true
          of irLt64U:
            foldedVal = (if cast[uint64](ca.val) < cast[uint64](cb.val): 1'i64 else: 0'i64)
            folded = true
          of irGt64S:
            foldedVal = (if ca.val > cb.val: 1'i64 else: 0'i64)
            folded = true
          of irGt64U:
            foldedVal = (if cast[uint64](ca.val) > cast[uint64](cb.val): 1'i64 else: 0'i64)
            folded = true
          of irLe64S:
            foldedVal = (if ca.val <= cb.val: 1'i64 else: 0'i64)
            folded = true
          of irLe64U:
            foldedVal = (if cast[uint64](ca.val) <= cast[uint64](cb.val): 1'i64 else: 0'i64)
            folded = true
          of irGe64S:
            foldedVal = (if ca.val >= cb.val: 1'i64 else: 0'i64)
            folded = true
          of irGe64U:
            foldedVal = (if cast[uint64](ca.val) >= cast[uint64](cb.val): 1'i64 else: 0'i64)
            folded = true

          # Float32 binary ops (bit patterns stored as int64)
          of irAddF32:
            foldedVal = cast[int32](cast[float32](cast[int32](ca.val)) +
                                    cast[float32](cast[int32](cb.val))).int64
            folded = true
          of irSubF32:
            foldedVal = cast[int32](cast[float32](cast[int32](ca.val)) -
                                    cast[float32](cast[int32](cb.val))).int64
            folded = true
          of irMulF32:
            foldedVal = cast[int32](cast[float32](cast[int32](ca.val)) *
                                    cast[float32](cast[int32](cb.val))).int64
            folded = true
          of irDivF32:
            foldedVal = cast[int32](cast[float32](cast[int32](ca.val)) /
                                    cast[float32](cast[int32](cb.val))).int64
            folded = true

          # Float64 binary ops
          of irAddF64:
            foldedVal = cast[int64](cast[float64](ca.val) + cast[float64](cb.val))
            folded = true
          of irSubF64:
            foldedVal = cast[int64](cast[float64](ca.val) - cast[float64](cb.val))
            folded = true
          of irMulF64:
            foldedVal = cast[int64](cast[float64](ca.val) * cast[float64](cb.val))
            folded = true
          of irDivF64:
            foldedVal = cast[int64](cast[float64](ca.val) / cast[float64](cb.val))
            folded = true

          else:
            discard

          if folded and instr.result >= 0:
            # Determine whether to fold as i32, i64, f32, or f64 constant
            let foldOp = case instr.op
              of irAdd64, irSub64, irMul64, irAnd64, irOr64, irXor64,
                 irShl64, irShr64U, irShr64S,
                 irEq64, irNe64, irLt64S, irLt64U, irGt64S, irGt64U,
                 irLe64S, irLe64U, irGe64S, irGe64U:
                irConst64
              of irAddF32, irSubF32, irMulF32, irDivF32:
                irConstF32
              of irAddF64, irSubF64, irMulF64, irDivF64:
                irConstF64
              else:
                irConst32
            bb.instrs[i] = IrInstr(op: foldOp, result: instr.result, imm: foldedVal)
            constants[instr.result.int] = (true, foldedVal)

      # Unary ops with a constant operand
      elif instr.operands[0] >= 0 and instr.operands[1] < 0:
        let ca = constants[instr.operands[0].int]
        if ca.known:
          var folded = false
          var foldedVal: int64
          var foldOp = irConst32

          case instr.op
          of irEqz32:
            foldedVal = (if cast[int32](ca.val) == 0: 1'i64 else: 0'i64)
            folded = true
          of irEqz64:
            foldedVal = (if ca.val == 0: 1'i64 else: 0'i64)
            folded = true
          of irWrapI64:
            foldedVal = (ca.val and 0xFFFFFFFF'i64)
            folded = true
          of irExtendI32S:
            foldedVal = cast[int32](ca.val).int64
            foldOp = irConst64
            folded = true
          of irExtendI32U:
            foldedVal = cast[int64](cast[uint32](ca.val))
            foldOp = irConst64
            folded = true
          of irExtend8S32:
            foldedVal = cast[int8](ca.val and 0xFF).int64
            folded = true
          of irExtend16S32:
            foldedVal = cast[int16](ca.val and 0xFFFF).int64
            folded = true
          of irExtend8S64:
            foldedVal = cast[int8](ca.val and 0xFF).int64
            foldOp = irConst64
            folded = true
          of irExtend16S64:
            foldedVal = cast[int16](ca.val and 0xFFFF).int64
            foldOp = irConst64
            folded = true
          of irExtend32S64:
            foldedVal = cast[int32](ca.val).int64
            foldOp = irConst64
            folded = true
          else:
            discard

          if folded and instr.result >= 0:
            bb.instrs[i] = IrInstr(op: foldOp, result: instr.result, imm: foldedVal)
            constants[instr.result.int] = (true, foldedVal)

      inc i

# ---------------------------------------------------------------------------
# 2. Dead Code Elimination
# ---------------------------------------------------------------------------

proc deadCodeElim*(f: var IrFunc) =
  ## Mark all values that are used (referenced as operands). Remove instructions
  ## that produce unused values, unless they have side effects.
  var used = newSeq[bool](f.numValues)

  # Mark phase: walk all instructions and mark operands as used
  for bb in f.blocks:
    for instr in bb.instrs:
      for op in instr.operands:
        if op >= 0:
          used[op.int] = true

  # Sweep phase: remove instructions with unused results and no side effects
  for bb in f.blocks.mitems:
    var kept: seq[IrInstr]
    for instr in bb.instrs:
      if instr.result < 0 or used[instr.result.int] or instr.op in sideEffectOps:
        kept.add(instr)
    bb.instrs = kept

# ---------------------------------------------------------------------------
# 3. Strength Reduction
# ---------------------------------------------------------------------------

proc strengthReduce*(f: var IrFunc) =
  ## Replace expensive operations with cheaper equivalents based on known
  ## constant operands:
  ##   mul x, 0  -> const 0
  ##   mul x, 1  -> copy x (nop)
  ##   mul x, 2^n -> shl x, n
  ##   div x, 1  -> copy x (nop)
  ##   divU x, 2^n -> shrU x, n
  ##   add x, 0  -> copy x (nop)
  ##   sub x, 0  -> copy x (nop)
  var constants = buildConstantMap(f)

  for bb in f.blocks.mitems:
    for i in 0 ..< bb.instrs.len:
      let instr = bb.instrs[i]
      if instr.result < 0:
        continue

      # Check second operand as constant (for binary ops)
      if instr.operands[1] >= 0 and constants[instr.operands[1].int].known:
        let c = constants[instr.operands[1].int].val
        let lhs = instr.operands[0]

        case instr.op

        # --- i32 multiply ---
        of irMul32:
          if c == 0:
            bb.instrs[i] = IrInstr(op: irConst32, result: instr.result, imm: 0)
            constants[instr.result.int] = (true, 0'i64)
          elif c == 1:
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [lhs, -1.IrValue, -1.IrValue])
          elif isPowerOfTwo(c):
            # Generate a constant for the shift amount, then create shl
            # Since we cannot easily insert instructions here, create a
            # shl with the existing constant operand replaced by a new one.
            # Instead, we rewrite to use an inline approach: emit irConst32
            # for the shift amount into this slot, and a shl in the next.
            # Simpler: rewrite to irShl32 reusing the operand slots.
            # We need the shift amount as an IrValue. Since we cannot easily
            # allocate one mid-pass, use the existing constant operand and
            # check if it happens to be the shift amount. It is not -- the
            # constant is the multiplier. So we just mark it as a shl hint
            # and let a follow-up handle it. For simplicity, replace with
            # irAdd32 x, x when c == 2.
            if c == 2:
              bb.instrs[i] = IrInstr(op: irAdd32, result: instr.result,
                operands: [lhs, lhs, -1.IrValue])
            # For higher powers of 2, we keep the mul -- a full implementation
            # would insert a const + shl pair, but that requires instruction
            # insertion which complicates indexing. Left for future work.

        # --- i64 multiply ---
        of irMul64:
          if c == 0:
            bb.instrs[i] = IrInstr(op: irConst64, result: instr.result, imm: 0)
            constants[instr.result.int] = (true, 0'i64)
          elif c == 1:
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [lhs, -1.IrValue, -1.IrValue])
          elif c == 2:
            bb.instrs[i] = IrInstr(op: irAdd64, result: instr.result,
              operands: [lhs, lhs, -1.IrValue])

        # --- i32 unsigned divide ---
        of irDiv32U:
          if c == 1:
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [lhs, -1.IrValue, -1.IrValue])
          elif isPowerOfTwo(c):
            # Power-of-2 unsigned division is handled by strengthReduceShifts
            # (which inserts a const+shr_u pair).  Nothing to do here.
            discard

        # --- i64 unsigned divide ---
        of irDiv64U:
          if c == 1:
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [lhs, -1.IrValue, -1.IrValue])

        # --- i32 signed divide ---
        of irDiv32S:
          if c == 1:
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [lhs, -1.IrValue, -1.IrValue])

        # --- i64 signed divide ---
        of irDiv64S:
          if c == 1:
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [lhs, -1.IrValue, -1.IrValue])

        # --- i32 add ---
        of irAdd32:
          if c == 0:
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [lhs, -1.IrValue, -1.IrValue])

        # --- i64 add ---
        of irAdd64:
          if c == 0:
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [lhs, -1.IrValue, -1.IrValue])

        # --- i32 sub ---
        of irSub32:
          if c == 0:
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [lhs, -1.IrValue, -1.IrValue])

        # --- i64 sub ---
        of irSub64:
          if c == 0:
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [lhs, -1.IrValue, -1.IrValue])

        # --- i32 and ---
        of irAnd32:
          if c == 0:
            bb.instrs[i] = IrInstr(op: irConst32, result: instr.result, imm: 0)
            constants[instr.result.int] = (true, 0'i64)
          elif cast[int32](c) == -1:  # all bits set
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [lhs, -1.IrValue, -1.IrValue])

        # --- i64 and ---
        of irAnd64:
          if c == 0:
            bb.instrs[i] = IrInstr(op: irConst64, result: instr.result, imm: 0)
            constants[instr.result.int] = (true, 0'i64)
          elif c == -1'i64:  # all bits set
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [lhs, -1.IrValue, -1.IrValue])

        # --- i32 or ---
        of irOr32:
          if c == 0:
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [lhs, -1.IrValue, -1.IrValue])

        # --- i64 or ---
        of irOr64:
          if c == 0:
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [lhs, -1.IrValue, -1.IrValue])

        # --- i32 xor ---
        of irXor32:
          if c == 0:
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [lhs, -1.IrValue, -1.IrValue])

        # --- i64 xor ---
        of irXor64:
          if c == 0:
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [lhs, -1.IrValue, -1.IrValue])

        # --- shifts by 0 ---
        of irShl32, irShr32S, irShr32U, irShl64, irShr64S, irShr64U:
          if c == 0:
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [lhs, -1.IrValue, -1.IrValue])

        else:
          discard

      # Also check first operand for commutative ops
      if instr.operands[0] >= 0 and constants[instr.operands[0].int].known:
        let c = constants[instr.operands[0].int].val
        let rhs = instr.operands[1]

        case instr.op

        # add 0, x -> x
        of irAdd32, irAdd64:
          if c == 0:
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [rhs, -1.IrValue, -1.IrValue])

        # mul 0, x -> 0
        of irMul32:
          if c == 0:
            bb.instrs[i] = IrInstr(op: irConst32, result: instr.result, imm: 0)
            constants[instr.result.int] = (true, 0'i64)
          elif c == 1:
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [rhs, -1.IrValue, -1.IrValue])

        of irMul64:
          if c == 0:
            bb.instrs[i] = IrInstr(op: irConst64, result: instr.result, imm: 0)
            constants[instr.result.int] = (true, 0'i64)
          elif c == 1:
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [rhs, -1.IrValue, -1.IrValue])

        # and 0, x -> 0
        of irAnd32:
          if c == 0:
            bb.instrs[i] = IrInstr(op: irConst32, result: instr.result, imm: 0)
            constants[instr.result.int] = (true, 0'i64)

        of irAnd64:
          if c == 0:
            bb.instrs[i] = IrInstr(op: irConst64, result: instr.result, imm: 0)
            constants[instr.result.int] = (true, 0'i64)

        # or 0, x -> x
        of irOr32, irOr64:
          if c == 0:
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [rhs, -1.IrValue, -1.IrValue])

        # xor 0, x -> x
        of irXor32, irXor64:
          if c == 0:
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [rhs, -1.IrValue, -1.IrValue])

        else:
          discard

# ---------------------------------------------------------------------------
# 4. Common Subexpression Elimination (CSE)
# ---------------------------------------------------------------------------

proc commonSubexprElim*(f: var IrFunc) =
  ## Within a basic block, if two instructions have the same opcode and operands,
  ## replace the second with a copy (irNop) from the first result.
  ##
  ## Only pure (non-side-effect) instructions are candidates for elimination.
  ## Loads are also excluded because intervening stores may change the value.
  ## Uses a hash table for O(1) lookup instead of O(n) linear scan.

  # Key: (opcode, op0, op1, op2, imm, imm2) — fully identifies a pure expression.
  type CseKey = tuple[op: IrOpKind, op0, op1, op2: IrValue, imm: int64, imm2: int32]

  for bb in f.blocks.mitems:
    var seen: Table[CseKey, IrValue]
    for i in 0 ..< bb.instrs.len:
      let instr = bb.instrs[i]
      if instr.op notin pureOps or instr.result < 0:
        continue
      let key = CseKey((instr.op, instr.operands[0], instr.operands[1],
                        instr.operands[2], instr.imm, instr.imm2))
      let existing = seen.getOrDefault(key, -1.IrValue)
      if existing >= 0:
        bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
          operands: [existing, -1.IrValue, -1.IrValue])
      else:
        seen[key] = instr.result

# ---------------------------------------------------------------------------
# 4b. Global Common Subexpression Elimination
# ---------------------------------------------------------------------------

proc commonSubexprElimGlobal*(f: var IrFunc) =
  ## Cross-block CSE.  Extends commonSubexprElim to propagate available
  ## expressions across basic-block boundaries.
  ##
  ## Algorithm (forward data-flow, conservative):
  ##
  ##   For each basic block b (processed in index order, which approximates
  ##   dominator pre-order for structured WASM CFG):
  ##
  ##     1. Collect the available-expression set at b's entry:
  ##        · Single lower-index predecessor  → inherit its full out-set.
  ##        · Multiple lower-index predecessors → intersect their out-sets
  ##          (keep only entries present in ALL of them with the same resultVal;
  ##           this ensures the value is available regardless of which path
  ##           was taken).
  ##        · No lower-index predecessors (entry block or loop header) → empty.
  ##
  ##     2. Walk b's instructions.  For each pure instruction, look it up in the
  ##        current available set.  On a hit, replace with irNop(copy).  On a
  ##        miss, add it.  Store/call/side-effect ops are not CSE'd but also do
  ##        not invalidate pure available expressions (pure ops have no memory
  ##        dependencies).
  ##
  ##     3. Record b's out-set (entry-set ∪ new entries from this block) for
  ##        use by b's successors.
  ##
  ## This handles the common WASM patterns:
  ##   · Linear dominator chains: expression computed in BB0 reused in BB1..BBn
  ##   · if-else bodies: header's computations visible in then/else/merge blocks
  ##   · Inlined code: repeated sub-expressions after inlining show up as
  ##     identical (op, operands) tuples across BBs

  # Key: (opcode, op0, op1, op2, imm, imm2); Value: resultVal (IrValue).
  # Using a hash table gives O(1) lookup and O(n) intersection vs O(n²) with seq.
  type CseKey = tuple[op: IrOpKind, op0, op1, op2: IrValue, imm: int64, imm2: int32]

  # blockOut[bbIdx]: available expressions after processing block bbIdx.
  var blockOut = newSeq[Table[CseKey, IrValue]](f.blocks.len)

  for bbIdx in 0 ..< f.blocks.len:
    let bb = f.blocks[bbIdx]

    # ---- Build entry available-expression set ----
    var lowerPreds: seq[int]
    for pred in bb.predecessors:
      if pred < bbIdx: lowerPreds.add(pred)

    var avail: Table[CseKey, IrValue]
    if lowerPreds.len == 1:
      avail = blockOut[lowerPreds[0]]
    elif lowerPreds.len > 1:
      # Intersect: keep entries present in ALL lower-index predecessors with the
      # same resultVal.  Hash-table intersection is O(n) in the smaller table.
      avail = blockOut[lowerPreds[0]]
      for k in 1 ..< lowerPreds.len:
        let other = blockOut[lowerPreds[k]]
        var toRemove: seq[CseKey]
        for key, val in avail:
          let otherVal = other.getOrDefault(key, -1.IrValue)
          if otherVal != val:
            toRemove.add(key)
        for key in toRemove:
          avail.del(key)
    # else: entry block or loop header — empty avail (conservative)

    # ---- Apply CSE to this block ----
    for i in 0 ..< f.blocks[bbIdx].instrs.len:
      let instr = f.blocks[bbIdx].instrs[i]
      if instr.op notin pureOpsWithFma or instr.result < 0:
        continue
      let key = CseKey((instr.op, instr.operands[0], instr.operands[1],
                        instr.operands[2], instr.imm, instr.imm2))
      let existing = avail.getOrDefault(key, -1.IrValue)
      if existing >= 0:
        f.blocks[bbIdx].instrs[i] = IrInstr(op: irNop, result: instr.result,
          operands: [existing, -1.IrValue, -1.IrValue])
      else:
        avail[key] = instr.result

    blockOut[bbIdx] = avail

# ---------------------------------------------------------------------------
# 5. Bounds Check Elimination
# ---------------------------------------------------------------------------

proc boundsCheckElim*(f: var IrFunc) =
  ## Within a basic block, track memory accesses from the same base address.
  ## If we have already verified that (base + offset + size) is in bounds for
  ## a larger access, smaller subsequent accesses from the same base at equal
  ## or smaller (offset + size) can skip their bounds check.
  ##
  ## This pass marks instructions by setting a flag in imm2's high bit.
  ## The codegen pass must check this flag and omit the bounds check.
  ##
  ## For now, a conservative heuristic: if two loads/stores share the same
  ## base operand (operands[0]) and the second access's (offset + accessSize)
  ## is <= the first access's (offset + accessSize), the second is redundant.

  type AccessRecord = tuple[base: IrValue, maxReach: int64]  # offset + size

  for bb in f.blocks.mitems:
    var checked: seq[AccessRecord]

    for i in 0 ..< bb.instrs.len:
      let instr = bb.instrs[i]
      let sz = accessSize(instr.op)
      if sz == 0:
        continue

      let base = instr.operands[0]
      if base < 0:
        continue

      let offset = instr.imm2 and (not boundsCheckedFlag)  # mask out our flag
      let reach = offset.int64 + sz.int64

      # Check if any previous access from the same base already covers this range
      var covered = false
      for rec in checked:
        if rec.base == base and reach <= rec.maxReach:
          covered = true
          break

      if covered:
        # Mark as bounds-check-safe
        bb.instrs[i].imm2 = instr.imm2 or boundsCheckedFlag
      else:
        # Record this access for future checks
        # Update existing record if same base with a larger reach
        var updated = false
        for j in 0 ..< checked.len:
          if checked[j].base == base:
            if reach > checked[j].maxReach:
              checked[j].maxReach = reach
            updated = true
            break
        if not updated:
          checked.add((base, reach))

# ---------------------------------------------------------------------------
# 5b. Global Bounds Check Elimination
# ---------------------------------------------------------------------------

proc boundsCheckElimGlobal*(f: var IrFunc) =
  ## Cross-block bounds check elimination. For structured WASM control flow,
  ## a predecessor block with a lower index is a conservative approximation
  ## of a dominator. Build a global map of (base IrValue -> max reach) across
  ## all blocks, propagating from predecessors, then eliminate redundant checks.

  type AccessRecord = tuple[base: IrValue, maxReach: int64]

  # Per-block: the set of (base, maxReach) that are verified by the end of that block
  var blockChecked = newSeq[seq[AccessRecord]](f.blocks.len)

  # First pass: compute per-block local checks (same logic as boundsCheckElim)
  for bbIdx in 0 ..< f.blocks.len:
    var checked: seq[AccessRecord]
    for instr in f.blocks[bbIdx].instrs:
      let sz = accessSize(instr.op)
      if sz == 0: continue
      let base = instr.operands[0]
      if base < 0: continue
      let offset = instr.imm2 and (not boundsCheckedFlag)
      let reach = offset.int64 + sz.int64
      # Already flagged by per-block pass means it was covered locally; skip
      if (instr.imm2 and boundsCheckedFlag) != 0: continue
      var updated = false
      for j in 0 ..< checked.len:
        if checked[j].base == base:
          if reach > checked[j].maxReach:
            checked[j].maxReach = reach
          updated = true
          break
      if not updated:
        checked.add((base, reach))
    blockChecked[bbIdx] = checked

  # Second pass: propagate checks from predecessors (lower-index only)
  # and eliminate redundant checks in each block
  for bbIdx in 0 ..< f.blocks.len:
    # Gather incoming checks from predecessor blocks with lower indices
    var incoming: seq[AccessRecord]
    for pred in f.blocks[bbIdx].predecessors:
      if pred >= bbIdx: continue  # skip back-edges
      for rec in blockChecked[pred]:
        # Merge into incoming: keep max reach per base
        var found = false
        for j in 0 ..< incoming.len:
          if incoming[j].base == rec.base:
            # For multiple predecessors, take the minimum (intersection)
            # since we need the check to hold on ALL paths
            if rec.maxReach < incoming[j].maxReach:
              incoming[j].maxReach = rec.maxReach
            found = true
            break
        if not found:
          # Only add if this base appears in ALL lower-index predecessors
          # For single-predecessor blocks, add directly
          incoming.add(rec)

    if incoming.len == 0: continue

    # For blocks with multiple lower-index predecessors, intersect:
    # keep only bases present in ALL lower-index predecessors
    var lowerPreds = 0
    for pred in f.blocks[bbIdx].predecessors:
      if pred < bbIdx: inc lowerPreds

    if lowerPreds > 1:
      var intersected: seq[AccessRecord]
      for rec in incoming:
        var count = 0
        var minReach = rec.maxReach
        for pred in f.blocks[bbIdx].predecessors:
          if pred >= bbIdx: continue
          for predRec in blockChecked[pred]:
            if predRec.base == rec.base:
              inc count
              if predRec.maxReach < minReach:
                minReach = predRec.maxReach
              break
        if count == lowerPreds:
          intersected.add((rec.base, minReach))
      incoming = intersected

    # Apply incoming checks to this block's instructions
    for i in 0 ..< f.blocks[bbIdx].instrs.len:
      let instr = f.blocks[bbIdx].instrs[i]
      let sz = accessSize(instr.op)
      if sz == 0: continue
      let base = instr.operands[0]
      if base < 0: continue
      if (instr.imm2 and boundsCheckedFlag) != 0: continue  # already eliminated
      let offset = instr.imm2 and (not boundsCheckedFlag)
      let reach = offset.int64 + sz.int64
      for rec in incoming:
        if rec.base == base and reach <= rec.maxReach:
          f.blocks[bbIdx].instrs[i].imm2 = instr.imm2 or boundsCheckedFlag
          break

# ---------------------------------------------------------------------------
# 5c. Alias-aware Bounds Check Elimination
# ---------------------------------------------------------------------------

proc boundsCheckElimAlias*(f: var IrFunc) =
  ## Alias-aware per-block bounds check elimination.
  ##
  ## The existing boundsCheckElim only merges checks when the base SSA value
  ## is identical.  This pass uses pointer-origin analysis so that patterns
  ## like struct field accesses share a single check:
  ##
  ##   ptr2  = ptr  + 4           # ptr2.origin = (ptr, 4)
  ##   load32 ptr, offset=0  → checks ptr+0+4 ≤ memSize  (maxReach = 4, root=ptr)
  ##   load32 ptr2, offset=4 → ptr2.origin=(ptr,4), totalOffset=8, reach=12
  ##   load32 ptr2, offset=0 → ptr2.origin=(ptr,4), totalOffset=4, reach=8
  ##
  ## Once we've seen a check that covers root+reach ≤ memSize, any access
  ## with the same root and a smaller or equal reach is redundant.
  ##
  ## We operate per-basic-block (conservative, always correct).
  ## The flow-insensitive global pass (boundsCheckElimGlobal) then propagates
  ## the already-flagged instructions across blocks.

  let origins = buildPtrOrigins(f)

  type AliasRecord = tuple[root: IrValue, maxReach: int64]
  # maxReach is the maximum (origin.offset + static_offset + access_size)
  # seen so far for this root — all future accesses with the same root and
  # reach ≤ maxReach are redundant.

  for bb in f.blocks.mitems:
    var checked: seq[AliasRecord]

    for i in 0 ..< bb.instrs.len:
      let instr = bb.instrs[i]
      let sz = accessSize(instr.op)
      if sz == 0: continue
      let base = instr.operands[0]
      if base < 0: continue
      if (instr.imm2 and boundsCheckedFlag) != 0: continue  # already flagged

      let exprOffset = (instr.imm2 and (not boundsCheckedFlag)).int64
      let origin: PtrOrigin =
        if base.int < origins.len: origins[base.int]
        else: (base, 0'i64)
      let totalOffset = origin.offset + exprOffset
      let reach = totalOffset + sz.int64

      # Negative offsets or very large offsets that wrap around are unsafe to
      # speculate about — skip them rather than risk a wrong elimination.
      if totalOffset < 0: continue

      var covered = false
      for rec in checked:
        if rec.root == origin.root and reach <= rec.maxReach:
          covered = true
          break

      if covered:
        bb.instrs[i].imm2 = instr.imm2 or boundsCheckedFlag
      else:
        var updated = false
        for j in 0 ..< checked.len:
          if checked[j].root == origin.root:
            if reach > checked[j].maxReach:
              checked[j].maxReach = reach
            updated = true
            break
        if not updated:
          checked.add((origin.root, reach))

# ---------------------------------------------------------------------------
# 5d. Global Alias-aware Bounds Check Elimination
# ---------------------------------------------------------------------------

proc boundsCheckElimAliasGlobal*(f: var IrFunc) =
  ## Cross-block extension of boundsCheckElimAlias.
  ##
  ## boundsCheckElimAlias works per-basic-block; a check established in BB0
  ## is not visible to BB1 even when BB0 strictly dominates BB1.
  ## This pass propagates (root, maxReach) records from lower-indexed
  ## predecessor blocks (a conservative approximation of dominators for
  ## structured WASM CFG) so that struct-field accesses in dominated blocks
  ## can also be de-checked.
  ##
  ## Algorithm mirrors boundsCheckElimGlobal but tracks (root, maxReach)
  ## tuples derived via pointer-origin analysis rather than exact base values.

  let origins = buildPtrOrigins(f)

  type AliasRecord = tuple[root: IrValue, maxReach: int64]

  # Per-block: (root, maxReach) established by the end of that block
  var blockChecked = newSeq[seq[AliasRecord]](f.blocks.len)

  # First pass: compute per-block alias records from already-flagged and
  # unflagged accesses, recording the maximum confirmed reach per root.
  for bbIdx in 0 ..< f.blocks.len:
    var checked: seq[AliasRecord]
    for instr in f.blocks[bbIdx].instrs:
      let sz = accessSize(instr.op)
      if sz == 0: continue
      let base = instr.operands[0]
      if base < 0: continue
      if (instr.imm2 and boundsCheckedFlag) != 0: continue  # skip already-eliminated

      let exprOff = (instr.imm2 and (not boundsCheckedFlag)).int64
      let origin: PtrOrigin =
        if base.int < origins.len: origins[base.int]
        else: (base, 0'i64)
      let totalOff = origin.offset + exprOff
      if totalOff < 0: continue
      let reach = totalOff + sz.int64

      var updated = false
      for j in 0 ..< checked.len:
        if checked[j].root == origin.root:
          if reach > checked[j].maxReach:
            checked[j].maxReach = reach
          updated = true
          break
      if not updated:
        checked.add((origin.root, reach))
    blockChecked[bbIdx] = checked

  # Second pass: propagate from lower-index predecessors and eliminate
  # redundant checks in each block.
  for bbIdx in 0 ..< f.blocks.len:
    var incoming: seq[AliasRecord]
    var lowerPreds = 0
    for pred in f.blocks[bbIdx].predecessors:
      if pred < bbIdx: inc lowerPreds

    for pred in f.blocks[bbIdx].predecessors:
      if pred >= bbIdx: continue  # skip back-edges
      for rec in blockChecked[pred]:
        var found = false
        for j in 0 ..< incoming.len:
          if incoming[j].root == rec.root:
            # Multiple predecessors → take the minimum (must hold on all paths)
            if rec.maxReach < incoming[j].maxReach:
              incoming[j].maxReach = rec.maxReach
            found = true
            break
        if not found:
          incoming.add(rec)

    if incoming.len == 0: continue

    # Intersect: keep only roots present in ALL lower-index predecessors
    if lowerPreds > 1:
      var intersected: seq[AliasRecord]
      for rec in incoming:
        var count = 0
        var minReach = rec.maxReach
        for pred in f.blocks[bbIdx].predecessors:
          if pred >= bbIdx: continue
          for predRec in blockChecked[pred]:
            if predRec.root == rec.root:
              inc count
              if predRec.maxReach < minReach:
                minReach = predRec.maxReach
              break
        if count == lowerPreds:
          intersected.add((rec.root, minReach))
      incoming = intersected

    # Apply incoming alias records to instructions in this block
    for i in 0 ..< f.blocks[bbIdx].instrs.len:
      let instr = f.blocks[bbIdx].instrs[i]
      let sz = accessSize(instr.op)
      if sz == 0: continue
      let base = instr.operands[0]
      if base < 0: continue
      if (instr.imm2 and boundsCheckedFlag) != 0: continue

      let exprOff = (instr.imm2 and (not boundsCheckedFlag)).int64
      let origin: PtrOrigin =
        if base.int < origins.len: origins[base.int]
        else: (base, 0'i64)
      let totalOff = origin.offset + exprOff
      if totalOff < 0: continue
      let reach = totalOff + sz.int64

      for rec in incoming:
        if rec.root == origin.root and reach <= rec.maxReach:
          f.blocks[bbIdx].instrs[i].imm2 = instr.imm2 or boundsCheckedFlag
          break

# ---------------------------------------------------------------------------
# 6. AArch64 Peephole Optimization
# ---------------------------------------------------------------------------

proc peepholeAarch64*(buf: var AsmBuffer) =
  ## Post-codegen peephole optimization on the raw instruction buffer.
  ##
  ## Patterns:
  ##   - MOV Xd, Xd (self-move via ORR Xd, XZR, Xd) -> NOP
  ##   - MOV Xd, Xa; MOV Xb, Xd where Xd not used again -> MOV Xb, Xa
  ##   - STR Xd, [Xn, #off]; LDR Xd, [Xn, #off] -> remove redundant LDR

  const nopEncoding = 0xD503201F'u32

  # Detect MOV Rd, Rm encoded as ORR Rd, XZR, Rm
  # 64-bit: 1_01_01010_00_0_Rm_000000_11111_Rd  = 0xAA0003E0 | rm | rd
  #   mask for sf=x, op=ORR, shift=00, N=0, imm6=000000, Rn=11111:
  #   We want: bits[30:29]=01 (ORR), bits[23:22]=00 (shift LSL), bit[21]=0 (N),
  #   bits[15:10]=000000 (imm6), bits[9:5]=11111 (Rn=XZR)
  # 32-bit: 0_01_01010_00_0_Rm_000000_11111_Rd  = 0x2A0003E0 | rm | rd
  # Mask that ignores sf and Rm and Rd: 0x7FE0FFE0

  proc isMov(inst: uint32): bool =
    (inst and 0x7FE0FFE0'u32) == 0x2A0003E0'u32

  proc movRd(inst: uint32): uint32 =
    inst and 0x1F'u32

  proc movRm(inst: uint32): uint32 =
    (inst shr 16) and 0x1F'u32

  # Detect LDR/STR unsigned-offset forms for pattern matching
  # STR (64-bit): 11_111_0_01_00_imm12_Rn_Rt = 0xF9000000 | ...
  # LDR (64-bit): 11_111_0_01_01_imm12_Rn_Rt = 0xF9400000 | ...
  # STR (32-bit): 10_111_0_01_00_imm12_Rn_Rt = 0xB9000000 | ...
  # LDR (32-bit): 10_111_0_01_01_imm12_Rn_Rt = 0xB9400000 | ...

  proc isStr64(inst: uint32): bool =
    (inst and 0xFFC00000'u32) == 0xF9000000'u32

  proc isLdr64(inst: uint32): bool =
    (inst and 0xFFC00000'u32) == 0xF9400000'u32

  proc isStr32(inst: uint32): bool =
    (inst and 0xFFC00000'u32) == 0xB9000000'u32

  proc isLdr32(inst: uint32): bool =
    (inst and 0xFFC00000'u32) == 0xB9400000'u32

  proc memRt(inst: uint32): uint32 =
    inst and 0x1F'u32

  proc memRn(inst: uint32): uint32 =
    (inst shr 5) and 0x1F'u32

  proc memImm12(inst: uint32): uint32 =
    (inst shr 10) and 0xFFF'u32

  var i = 0
  while i < buf.code.len:
    let inst = buf.code[i]

    # Pattern 1: Self-move (MOV Xd, Xd) -> NOP
    if isMov(inst):
      let rd = movRd(inst)
      let rm = movRm(inst)
      if rd == rm:
        buf.code[i] = nopEncoding

    # Pattern 2: STR Rt, [Rn, #off]; LDR Rt, [Rn, #off] -> remove LDR
    # (redundant load immediately after a store of the same register to the
    # same address)
    if i + 1 < buf.code.len:
      let next = buf.code[i + 1]

      # 64-bit STR followed by 64-bit LDR
      if isStr64(inst) and isLdr64(next):
        if memRt(inst) == memRt(next) and
           memRn(inst) == memRn(next) and
           memImm12(inst) == memImm12(next):
          buf.code[i + 1] = nopEncoding

      # 32-bit STR followed by 32-bit LDR
      elif isStr32(inst) and isLdr32(next):
        if memRt(inst) == memRt(next) and
           memRn(inst) == memRn(next) and
           memImm12(inst) == memImm12(next):
          buf.code[i + 1] = nopEncoding

      # Pattern 3: MOV Xd, Xa; MOV Xb, Xd -> MOV Xb, Xa
      # (eliminate the intermediate register when Xd is only used as a temp)
      # Conservative version: only apply when the two MOVs are adjacent
      if isMov(inst) and isMov(next):
        let rd1 = movRd(inst)
        let rm1 = movRm(inst)
        let rd2 = movRd(next)
        let rm2 = movRm(next)
        # Second MOV reads from first MOV's destination
        if rm2 == rd1 and rd1 != rm1 and rd2 != rd1:
          # Check that rd1 (the intermediate) is not xzr (31), which has
          # special semantics as the zero register
          if rd1 != 31:
            # Rewrite: MOV Xb, Xa (keeping sf bit from the second MOV)
            let sf = next and 0x80000000'u32
            buf.code[i + 1] = sf or 0x2A0003E0'u32 or (rm1 shl 16) or rd2
            # First MOV becomes NOP since its result is unused
            buf.code[i] = nopEncoding

      # Pattern 4: CMP Wn, #0; B.EQ/B.NE -> CBZ/CBNZ Wn
      # CMP Wn, #0 = SUBS WZR, Wn, #0:
      #   encoding 0x7100001F with Rn in bits[9:5]
      #   mask ignoring Rn: (inst & 0xFFC003FF) == 0x7100001F
      proc isCmpW0(inst: uint32): bool =
        (inst and 0xFFC003FF'u32) == 0x7100001F'u32
      # B.cond: bits[31:24]=0x54, bit[4]=0, cond in bits[3:0]
      proc isBcond(inst: uint32): bool =
        (inst and 0xFF000010'u32) == 0x54000000'u32
      proc bcondCond(inst: uint32): uint32 = inst and 0xF'u32
      proc bcondImm19(inst: uint32): uint32 = (inst shr 5) and 0x7FFFF'u32

      if isCmpW0(inst) and isBcond(next):
        let cond = bcondCond(next)
        if cond == 0'u32 or cond == 1'u32:   # B.EQ=0 → CBZ, B.NE=1 → CBNZ
          let rn    = (inst shr 5) and 0x1F'u32
          let imm19 = bcondImm19(next)
          buf.code[i] = nopEncoding
          # CBZ Wn = 0x34000000, CBNZ Wn = 0x35000000
          let cbzBase = if cond == 0'u32: 0x34000000'u32 else: 0x35000000'u32
          buf.code[i + 1] = cbzBase or (imm19 shl 5) or rn

      # Pattern 5: LDR Xt1, [Xn, #off]; LDR Xt2, [Xn, #off+8] → LDP Xt1, Xt2, [Xn, #off]
      # Saves one load-issue slot on Apple Silicon (LDP is a single μop).
      # Constraints: same Rn, consecutive 8-byte-aligned offsets, distinct Rt1/Rt2,
      #   Rt1 ≠ Rn and Rt2 ≠ Rn (conservative: avoids base-register overlap),
      #   imm1 ≤ 63 so simm7 fits in the 7-bit signed LDP offset field (max 504 bytes).
      if isLdr64(inst) and isLdr64(next):
        let rn1  = memRn(inst)
        let rn2  = memRn(next)
        let rt1  = memRt(inst)
        let rt2  = memRt(next)
        let imm1 = memImm12(inst)
        let imm2 = memImm12(next)
        if rn1 == rn2 and imm2 == imm1 + 1 and imm1 <= 63 and
           rt1 != rt2 and rt1 != rn1 and rt2 != rn1:
          # LDP Xt1, Xt2, [Xn, #imm1*8]  (64-bit signed-offset form: opc=10, L=1)
          buf.code[i]     = 0xA9400000'u32 or (imm1 shl 15) or
                            (rt2 shl 10) or (rn1 shl 5) or rt1
          buf.code[i + 1] = nopEncoding

      # Pattern 6: STR Xt1, [Xn, #off]; STR Xt2, [Xn, #off+8] → STP Xt1, Xt2, [Xn, #off]
      elif isStr64(inst) and isStr64(next):
        let rn1  = memRn(inst)
        let rn2  = memRn(next)
        let rt1  = memRt(inst)
        let rt2  = memRt(next)
        let imm1 = memImm12(inst)
        let imm2 = memImm12(next)
        if rn1 == rn2 and imm2 == imm1 + 1 and imm1 <= 63 and rt1 != rt2:
          # STP Xt1, Xt2, [Xn, #imm1*8]  (64-bit signed-offset form: opc=10, L=0)
          buf.code[i]     = 0xA9000000'u32 or (imm1 shl 15) or
                            (rt2 shl 10) or (rn1 shl 5) or rt1
          buf.code[i + 1] = nopEncoding

    inc i

# ---------------------------------------------------------------------------
# Main optimization pipeline
# ---------------------------------------------------------------------------
# Note: peepholeX64 (x86-64 byte-stream peephole) is defined in
# ircodegen_x64.nim and called at the end of emitIrFuncX64.

proc localValueForward*(f: var IrFunc) =
  ## Within each basic block, track the SSA value for each WASM local.
  ## When irLocalGet reads a local whose value is already known (from a
  ## previous irLocalGet or irLocalSet), replace the load with a NOP that
  ## aliases the known SSA value. DCE will then remove the dead load.
  ##
  ## This eliminates redundant local loads in tight loops and straight-line code.
  for bb in f.blocks.mitems:
    var localVal = newSeq[IrValue](f.numLocals)
    for i in 0 ..< localVal.len:
      localVal[i] = -1.IrValue  # unknown

    for i in 0 ..< bb.instrs.len:
      let instr = bb.instrs[i]

      case instr.op
      of irLocalGet:
        let localIdx = instr.imm.int
        if localIdx >= 0 and localIdx < localVal.len:
          if localVal[localIdx] >= 0:
            # We already know the value of this local — forward it
            bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
              operands: [localVal[localIdx], -1.IrValue, -1.IrValue])
          elif instr.result >= 0:
            # First load of this local in this block — remember it
            localVal[localIdx] = instr.result

      of irLocalSet:
        let localIdx = instr.imm.int
        if localIdx >= 0 and localIdx < localVal.len:
          # The stored value is now the known value for this local
          localVal[localIdx] = instr.operands[0]

      of irParam:
        # Parameters initialize their local
        let paramIdx = instr.imm.int
        if paramIdx >= 0 and paramIdx < localVal.len and instr.result >= 0:
          localVal[paramIdx] = instr.result

      else:
        discard

proc promoteLocals*(f: var IrFunc) =
  ## Eliminate dead irLocalSet instructions for locals that are never read
  ## back via irLocalGet (register promotion).
  ##
  ## In the lowered IR, opLocalGet does NOT emit an irLocalGet instruction —
  ## it just pushes the current SSA value from ctx.locals[idx] directly.
  ## irLocalGet instructions appear only in TCO-restart blocks and in
  ## explicit IR construction.  For ordinary functions, all irLocalSet
  ## instructions are therefore writes to slots that are never read back
  ## through the IR, making them dead stores once phi nodes carry the
  ## actual loop-carried values.
  ##
  ## Safe even in the presence of irCall: WASM function calls cannot observe
  ## the caller's locals (each function has its own local frame).
  ##
  ## Algorithm:
  ##   1. Scan every instruction for irLocalGet; record which local indices
  ##      are actually read.
  ##   2. Remove every irLocalSet for a local index that is not in that set.
  ##
  ## The pass is deliberately conservative: any local whose index appears in
  ## ANY irLocalGet is kept entirely; we never partially remove stores.

  # Collect which locals are actually read via irLocalGet
  var needed: array[256, bool]   # WASM spec: max 50 000 locals, but in practice ≪ 256
  var neededDyn: seq[bool]       # fallback for large local counts
  let useArray = f.numLocals <= 256

  if useArray:
    for bb in f.blocks:
      for instr in bb.instrs:
        if instr.op == irLocalGet:
          let idx = instr.imm.int
          if idx >= 0 and idx < 256: needed[idx] = true
        elif instr.op == irCallIndirect:
          # Temp locals [tempBase..tempBase+paramCount-1] are written by irLocalSet
          # and read directly by the codegen (not via irLocalGet) — keep their stores.
          let paramCount = (instr.imm and 0xFFFF).int
          let tempBase   = instr.imm2.int
          for k in tempBase ..< tempBase + max(paramCount, if (instr.imm shr 16) > 0: 1 else: 0):
            if k >= 0 and k < 256: needed[k] = true
  else:
    neededDyn = newSeq[bool](f.numLocals)
    for bb in f.blocks:
      for instr in bb.instrs:
        if instr.op == irLocalGet:
          let idx = instr.imm.int
          if idx >= 0 and idx < neededDyn.len: neededDyn[idx] = true
        elif instr.op == irCallIndirect:
          let paramCount = (instr.imm and 0xFFFF).int
          let tempBase   = instr.imm2.int
          for k in tempBase ..< tempBase + max(paramCount, if (instr.imm shr 16) > 0: 1 else: 0):
            if k >= 0 and k < neededDyn.len: neededDyn[k] = true

  proc isNeeded(idx: int): bool =
    if useArray:
      idx >= 0 and idx < 256 and needed[idx]
    else:
      idx >= 0 and idx < neededDyn.len and neededDyn[idx]

  # Remove dead irLocalSet instructions
  var anyRemoved = false
  for bb in f.blocks:
    for instr in bb.instrs:
      if instr.op == irLocalSet and not isNeeded(instr.imm.int):
        anyRemoved = true
        break
    if anyRemoved: break

  if not anyRemoved: return  # nothing to do — fast path

  for bb in f.blocks.mitems:
    var newInstrs: seq[IrInstr]
    newInstrs.setLen(0)
    for instr in bb.instrs:
      if instr.op == irLocalSet and not isNeeded(instr.imm.int):
        discard  # dead store — drop
      else:
        newInstrs.add(instr)
    bb.instrs = newInstrs

proc loopInvariantCodeMotion*(f: var IrFunc) =
  ## Hoist loop-invariant instructions from ALL loop body blocks to the preheader.
  ##
  ## Loop detection: a block H is a loop header if it has a back-edge predecessor
  ## (pred index >= H's index). The loop body spans blocks [H, maxBackEdge].
  ## The preheader is the highest-index predecessor of H with index < H.
  ##
  ## An instruction is hoistable when:
  ##   - It is pure (no side effects, not a phi/param/local-get/nop)
  ##   - ALL operands are defined OUTSIDE [H, maxBackEdge] or already hoisted
  ##
  ## Constants (irConst32/64/F32/F64) are always hoistable unless the loop
  ## contains a call — hoisting constants across calls forces callee-save spills
  ## that cost more than repeating the movz each iteration.
  ##
  ## Multi-pass over the body range: hoisting one instruction exposes further
  ## candidates that depend on it (e.g., an address computation using a hoisted
  ## constant). Converges quickly in practice (typically 2–3 passes).

  const nonHoistableOps = sideEffectOps + storeOps +
    {irPhi, irParam, irLocalGet, irNop}
  const constOps = {irConst32, irConst64, irConstF32, irConstF64}

  # Pointer-origin analysis for alias-aware load hoisting.
  let origins = buildPtrOrigins(f)

  # Build defBlock: SSA value → block index where it is defined
  var defBlock = newSeq[int](f.numValues)
  for i in 0 ..< defBlock.len:
    defBlock[i] = -1
  for bbIdx in 0 ..< f.blocks.len:
    for instr in f.blocks[bbIdx].instrs:
      if instr.result >= 0:
        defBlock[instr.result.int] = bbIdx

  # Per-value: has this value been hoisted to the preheader already?
  var hoistedVals = newSeq[bool](f.numValues)

  for bbIdx in 0 ..< f.blocks.len:
    let header = addr f.blocks[bbIdx]
    # Collect back-edge predecessors and find the preheader.
    # Skip dead blocks (no predecessors, not the entry) as back-edge sources —
    # TCO construction leaves unreachable blocks with edges to merge points,
    # which would otherwise be mistaken for loop back-edges.
    var maxBackEdge = -1
    var preheaderIdx = -1
    for pred in header[].predecessors:
      if pred >= bbIdx:
        if pred > 0 and f.blocks[pred].predecessors.len == 0:
          continue  # dead block, not a real back-edge
        if pred > maxBackEdge: maxBackEdge = pred
      else:
        if pred > preheaderIdx: preheaderIdx = pred

    if maxBackEdge < 0 or preheaderIdx < 0:
      continue  # not a loop header or missing a preheader

    # Verify this is a genuine loop: the header must be able to reach the
    # back-edge predecessor through forward edges within [bbIdx, maxBackEdge].
    # Without this check, inlined if-else diamonds (where the merge block has a
    # higher-indexed "else" predecessor) are falsely treated as loops, causing
    # LICM to hoist else-branch code into the then-branch preheader.
    if not isRealBackEdge(f, bbIdx, maxBackEdge):
      continue

    let loopEnd = min(maxBackEdge, f.blocks.len - 1)

    # Collect the set of canonical roots that are written anywhere in the loop.
    # A load whose address root is NOT in this set is safe to hoist (no aliasing
    # store can invalidate it during any loop iteration).
    var writtenRoots: HashSet[IrValue]
    for bodyIdx in bbIdx .. loopEnd:
      for instr in f.blocks[bodyIdx].instrs:
        if instr.op in storeOps and instr.operands[0] >= 0:
          let addrOp = instr.operands[0]
          let root = if addrOp.int < origins.len: origins[addrOp.int].root
                     else: addrOp
          writtenRoots.incl(root)

    # Multi-pass until no new instructions can be hoisted
    var globalChanged = true
    while globalChanged:
      globalChanged = false

      for bodyIdx in bbIdx .. loopEnd:
        if bodyIdx >= f.blocks.len: break

        var hoisted: seq[IrInstr]
        var kept: seq[IrInstr]

        for instr in f.blocks[bodyIdx].instrs:
          # Loads: hoist when address is loop-invariant and no aliasing store
          # in the loop body can overwrite the loaded location.
          if instr.result >= 0 and instr.op in loadOps:
            let addrOp = instr.operands[0]
            if addrOp >= 0:
              let db = defBlock[addrOp.int]
              let addrOutside = db < bbIdx or db > loopEnd or hoistedVals[addrOp.int]
              if addrOutside:
                let root = if addrOp.int < origins.len: origins[addrOp.int].root
                           else: addrOp
                if root notin writtenRoots:
                  hoisted.add(instr)
                  hoistedVals[instr.result.int] = true
                  defBlock[instr.result.int] = preheaderIdx
                  globalChanged = true
                  continue
            kept.add(instr)
            continue

          if instr.result < 0 or instr.op in nonHoistableOps:
            kept.add(instr)
            continue

          # Constants: always hoistable. The register allocator handles
          # constants live across calls via rematerialization (OPT-023),
          # so hoisting them out of call-containing loops is safe — they
          # won't burn callee-saved registers.
          if instr.op in constOps:
            hoisted.add(instr)
            hoistedVals[instr.result.int] = true
            defBlock[instr.result.int] = preheaderIdx
            globalChanged = true
            continue

          # Pure computation: all operands must be defined before the loop
          # (or already hoisted out of it)
          var allOutside = true
          for op in instr.operands:
            if op >= 0:
              let db = defBlock[op.int]
              # "inside loop" = defined in [bbIdx, loopEnd] and not yet hoisted
              if db >= bbIdx and db <= loopEnd and not hoistedVals[op.int]:
                allOutside = false
                break

          if allOutside:
            hoisted.add(instr)
            hoistedVals[instr.result.int] = true
            defBlock[instr.result.int] = preheaderIdx
            globalChanged = true
          else:
            kept.add(instr)

        if hoisted.len > 0:
          # Insert before the preheader's terminal branch so execution order is
          # preserved and the hoisted values are ready before the first loop entry.
          var pre = f.blocks[preheaderIdx].instrs
          if pre.len > 0 and pre[^1].op in {irBr, irBrIf}:
            let term = pre[^1]
            pre.setLen(pre.len - 1)
            pre.add(hoisted)
            pre.add(term)
          else:
            pre.add(hoisted)
          f.blocks[preheaderIdx].instrs = pre
          f.blocks[bodyIdx].instrs = kept

proc strengthReduceShifts*(f: var IrFunc) =
  ## Replace mul/div-by-constant-power-of-2 (> 2) with shift instructions.
  ##
  ## The basic `strengthReduce` handles c==0, c==1, and c==2 (→ add) in-place.
  ## This pass handles c==4,8,16,… by INSERTING a new const instruction for the
  ## shift amount followed by the shift, which avoids in-place indexing issues
  ## and enables the newly inserted constants to be hoisted by LICM.
  ##
  ## Patterns handled:
  ##   mul x, 2^n  (n>1)  → shl x, n     (both i32 and i64)
  ##   div_u x, 2^n (n>1) → shr_u x, n   (both i32 and i64)
  ##   mul 2^n, x  (n>1)  → shl x, n     (commutative)

  let constants = buildConstantMap(f)

  for bb in f.blocks.mitems:
    var newInstrs: seq[IrInstr]
    for instr in bb.instrs:
      var handled = false

      # --- right operand is a power-of-two constant > 2 ---
      if instr.result >= 0 and instr.operands[1] >= 0:
        let cb = constants[instr.operands[1].int]
        if cb.known and cb.val > 2 and isPowerOfTwo(cb.val):
          let shift = log2Int(cb.val)
          let lhs = instr.operands[0]
          case instr.op
          of irMul32:
            let sv = f.newValue()
            newInstrs.add(IrInstr(op: irConst32, result: sv, imm: shift.int64))
            newInstrs.add(IrInstr(op: irShl32, result: instr.result,
              operands: [lhs, sv, -1.IrValue]))
            handled = true
          of irMul64:
            let sv = f.newValue()
            newInstrs.add(IrInstr(op: irConst64, result: sv, imm: shift.int64))
            newInstrs.add(IrInstr(op: irShl64, result: instr.result,
              operands: [lhs, sv, -1.IrValue]))
            handled = true
          of irDiv32U:
            let sv = f.newValue()
            newInstrs.add(IrInstr(op: irConst32, result: sv, imm: shift.int64))
            newInstrs.add(IrInstr(op: irShr32U, result: instr.result,
              operands: [lhs, sv, -1.IrValue]))
            handled = true
          of irDiv64U:
            let sv = f.newValue()
            newInstrs.add(IrInstr(op: irConst64, result: sv, imm: shift.int64))
            newInstrs.add(IrInstr(op: irShr64U, result: instr.result,
              operands: [lhs, sv, -1.IrValue]))
            handled = true
          of irRem32U:
            # x rem 2^n  →  x AND (2^n - 1)
            let sv = f.newValue()
            newInstrs.add(IrInstr(op: irConst32, result: sv, imm: cb.val - 1))
            newInstrs.add(IrInstr(op: irAnd32, result: instr.result,
              operands: [lhs, sv, -1.IrValue]))
            handled = true
          of irRem64U:
            let sv = f.newValue()
            newInstrs.add(IrInstr(op: irConst64, result: sv, imm: cb.val - 1))
            newInstrs.add(IrInstr(op: irAnd64, result: instr.result,
              operands: [lhs, sv, -1.IrValue]))
            handled = true
          of irDiv32S:
            # x /s 2^n  →  t1=x>>s(n-1); t2=t1>>u(32-n); t3=x+t2; result=t3>>s n
            let sv1 = f.newValue()
            let t1  = f.newValue()
            let sv2 = f.newValue()
            let t2  = f.newValue()
            let t3  = f.newValue()
            let svN = f.newValue()
            newInstrs.add(IrInstr(op: irConst32, result: sv1, imm: (shift - 1).int64))
            newInstrs.add(IrInstr(op: irShr32S,  result: t1,
              operands: [lhs, sv1, -1.IrValue]))
            newInstrs.add(IrInstr(op: irConst32, result: sv2, imm: (32 - shift).int64))
            newInstrs.add(IrInstr(op: irShr32U,  result: t2,
              operands: [t1, sv2, -1.IrValue]))
            newInstrs.add(IrInstr(op: irAdd32,   result: t3,
              operands: [lhs, t2, -1.IrValue]))
            newInstrs.add(IrInstr(op: irConst32, result: svN, imm: shift.int64))
            newInstrs.add(IrInstr(op: irShr32S,  result: instr.result,
              operands: [t3, svN, -1.IrValue]))
            handled = true
          of irDiv64S:
            let sv1 = f.newValue()
            let t1  = f.newValue()
            let sv2 = f.newValue()
            let t2  = f.newValue()
            let t3  = f.newValue()
            let svN = f.newValue()
            newInstrs.add(IrInstr(op: irConst64, result: sv1, imm: (shift - 1).int64))
            newInstrs.add(IrInstr(op: irShr64S,  result: t1,
              operands: [lhs, sv1, -1.IrValue]))
            newInstrs.add(IrInstr(op: irConst64, result: sv2, imm: (64 - shift).int64))
            newInstrs.add(IrInstr(op: irShr64U,  result: t2,
              operands: [t1, sv2, -1.IrValue]))
            newInstrs.add(IrInstr(op: irAdd64,   result: t3,
              operands: [lhs, t2, -1.IrValue]))
            newInstrs.add(IrInstr(op: irConst64, result: svN, imm: shift.int64))
            newInstrs.add(IrInstr(op: irShr64S,  result: instr.result,
              operands: [t3, svN, -1.IrValue]))
            handled = true
          else:
            discard

      # --- left operand is a power-of-two constant > 2 (commutative mul only) ---
      if not handled and instr.result >= 0 and instr.operands[0] >= 0:
        let ca = constants[instr.operands[0].int]
        if ca.known and ca.val > 2 and isPowerOfTwo(ca.val):
          let shift = log2Int(ca.val)
          let rhs = instr.operands[1]
          case instr.op
          of irMul32:
            let sv = f.newValue()
            newInstrs.add(IrInstr(op: irConst32, result: sv, imm: shift.int64))
            newInstrs.add(IrInstr(op: irShl32, result: instr.result,
              operands: [rhs, sv, -1.IrValue]))
            handled = true
          of irMul64:
            let sv = f.newValue()
            newInstrs.add(IrInstr(op: irConst64, result: sv, imm: shift.int64))
            newInstrs.add(IrInstr(op: irShl64, result: instr.result,
              operands: [rhs, sv, -1.IrValue]))
            handled = true
          else:
            discard

      if not handled:
        newInstrs.add(instr)

    bb.instrs = newInstrs

proc fuseMultiplyAdd*(f: var IrFunc) =
  ## Fuse adjacent mul+add / mul+sub sequences into FMA instructions.
  ##
  ## Patterns detected (within a single basic block):
  ##   t = irMulF32(a,b); r = irAddF32(t,c) → irFmaF32(a,b,c)    a*b+c
  ##   t = irMulF32(a,b); r = irAddF32(c,t) → irFmaF32(a,b,c)    commutative
  ##   t = irMulF32(a,b); r = irSubF32(c,t) → irFmsF32(a,b,c)    c-a*b
  ##   t = irMulF32(a,b); r = irSubF32(t,c) → irFnmsF32(a,b,c)   a*b-c
  ##   (analogous for F64)
  ##
  ## The mul result must be single-use. After fusion the mul becomes irNop
  ## and DCE cleans it up.

  # Count uses of each SSA value across the whole function
  var useCount = newSeq[int](f.numValues)
  for bb in f.blocks:
    for instr in bb.instrs:
      for op in instr.operands:
        if op >= 0 and op.int < useCount.len:
          inc useCount[op.int]

  # Per-block: for each SSA value that is the result of a MulF32/MulF64,
  # record its instruction index and whether it is f32 (true) or f64 (false).
  # instrIdx == -1 means "no mul here".
  type MulEntry = tuple[instrIdx: int, isF32: bool]

  for bbIdx in 0 ..< f.blocks.len:
    var mulDef = newSeq[MulEntry](f.numValues)
    for i in 0 ..< mulDef.len:
      mulDef[i] = (-1, false)

    # First pass: find mul definitions in this block
    let blk = f.blocks[bbIdx]
    for i in 0 ..< blk.instrs.len:
      let instr = blk.instrs[i]
      if instr.result >= 0 and instr.result.int < mulDef.len:
        case instr.op
        of irMulF32: mulDef[instr.result.int] = (i, true)
        of irMulF64: mulDef[instr.result.int] = (i, false)
        else: discard

    # Second pass: detect add/sub consuming a single-use mul and fuse
    for i in 0 ..< f.blocks[bbIdx].instrs.len:
      let instr = f.blocks[bbIdx].instrs[i]
      if instr.result < 0: continue

      # Helper: check if `v` refers to a fuseable mul in this block
      template isFusableMul(v: IrValue, expectF32: bool): bool =
        (v >= 0 and v.int < mulDef.len and
         mulDef[v.int].instrIdx >= 0 and
         mulDef[v.int].isF32 == expectF32 and
         useCount[v.int] == 1)

      template applyFusion(mulVal: IrValue, addend: IrValue, fmaOp: IrOpKind) =
        let mIdx = mulDef[mulVal.int].instrIdx
        let mulInstr = f.blocks[bbIdx].instrs[mIdx]
        f.blocks[bbIdx].instrs[i] = IrInstr(op: fmaOp, result: instr.result,
          operands: [mulInstr.operands[0], mulInstr.operands[1], addend])
        f.blocks[bbIdx].instrs[mIdx] = IrInstr(op: irNop, result: mulInstr.result,
          operands: [-1.IrValue, -1.IrValue, -1.IrValue])
        mulDef[mulVal.int] = (-1, false)  # prevent double-fuse on same mul

      let op0 = instr.operands[0]
      let op1 = instr.operands[1]

      case instr.op
      of irAddF32:
        if isFusableMul(op0, true):       applyFusion(op0, op1, irFmaF32)
        elif isFusableMul(op1, true):     applyFusion(op1, op0, irFmaF32)
      of irSubF32:
        if isFusableMul(op1, true):       applyFusion(op1, op0, irFmsF32)   # c - a*b
        elif isFusableMul(op0, true):     applyFusion(op0, op1, irFnmsF32)  # a*b - c
      of irAddF64:
        if isFusableMul(op0, false):      applyFusion(op0, op1, irFmaF64)
        elif isFusableMul(op1, false):    applyFusion(op1, op0, irFmaF64)
      of irSubF64:
        if isFusableMul(op1, false):      applyFusion(op1, op0, irFmsF64)
        elif isFusableMul(op0, false):    applyFusion(op0, op1, irFnmsF64)
      else:
        discard

proc boundsCheckLoopHoist*(f: var IrFunc) =
  ## Hoist memory bounds checks out of loops when the access base is
  ## loop-invariant and the stride is known and constant.
  ##
  ## Pattern: within a loop body, if a memory access address is computed as
  ##   addr = base + (index * stride) + offset
  ## where base, stride and offset are loop-invariant (defined before the loop),
  ## and the loop index increments by a fixed stride each iteration, we can
  ## emit a single pre-loop bounds check of the maximum address instead of one
  ## per iteration.
  ##
  ## For now, we detect the simpler case: a loop body where the SAME base
  ## register (loop-invariant) is used for EVERY memory access in the block,
  ## and the highest static offset across all accesses is used for a single
  ## pre-check. The per-iteration checks are then marked safe.
  ##
  ## This is a conservative approximation; a full implementation would track
  ## induction variables. The approximation is sound: we only skip a check
  ## when we know the pre-check covers it.

  # Build defBlock for invariance check (reuse the same approach as LICM)
  var defBlock = newSeq[int](f.numValues)
  for i in 0 ..< defBlock.len:
    defBlock[i] = -1
  for bbIdx in 0 ..< f.blocks.len:
    for instr in f.blocks[bbIdx].instrs:
      if instr.result >= 0:
        defBlock[instr.result.int] = bbIdx

  for bbIdx in 0 ..< f.blocks.len:
    # Identify loop headers
    var maxBackEdge = -1
    var preheaderIdx = -1
    for pred in f.blocks[bbIdx].predecessors:
      if pred >= bbIdx:
        if pred > maxBackEdge: maxBackEdge = pred
      else:
        if pred > preheaderIdx: preheaderIdx = pred
    if maxBackEdge < 0 or preheaderIdx < 0:
      continue
    if not isRealBackEdge(f, bbIdx, maxBackEdge):
      continue
    let loopEnd = min(maxBackEdge, f.blocks.len - 1)

    # For each loop body block, find the maximum static reach for each
    # loop-invariant base pointer. "Invariant" means defined before bbIdx.
    type BaseRecord = tuple[base: IrValue, maxReach: int64]
    var invariantBases: seq[BaseRecord]

    for bodyIdx in bbIdx .. loopEnd:
      if bodyIdx >= f.blocks.len: break
      for instr in f.blocks[bodyIdx].instrs:
        let sz = accessSize(instr.op)
        if sz == 0: continue
        let base = instr.operands[0]
        if base < 0: continue
        if (instr.imm2 and boundsCheckedFlag) != 0: continue  # already safe
        # Base must be defined outside the loop (invariant)
        let db = defBlock[base.int]
        if db >= bbIdx and db <= loopEnd: continue  # not invariant
        let offset = int64(instr.imm2 and (not boundsCheckedFlag))
        let reach = offset + int64(sz)
        # Track maximum reach for this base
        var updated = false
        for j in 0 ..< invariantBases.len:
          if invariantBases[j].base == base:
            if reach > invariantBases[j].maxReach:
              invariantBases[j].maxReach = reach
            updated = true
            break
        if not updated:
          invariantBases.add((base, reach))

    if invariantBases.len == 0: continue

    # Mark accesses from these invariant bases as bounds-check-safe,
    # EXCEPT the first access with maxReach per base — that one serves as
    # the guard check (without it, no check verifies the address at all).
    var guardEmitted: seq[IrValue]  # bases whose max-reach guard has been kept
    for bodyIdx in bbIdx .. loopEnd:
      if bodyIdx >= f.blocks.len: break
      for i in 0 ..< f.blocks[bodyIdx].instrs.len:
        let instr = f.blocks[bodyIdx].instrs[i]
        let sz = accessSize(instr.op)
        if sz == 0: continue
        let base = instr.operands[0]
        if base < 0: continue
        if (instr.imm2 and boundsCheckedFlag) != 0: continue
        let db = defBlock[base.int]
        if db >= bbIdx and db <= loopEnd: continue  # not invariant
        let offset = int64(instr.imm2 and (not boundsCheckedFlag))
        let reach = offset + int64(sz)
        for rec in invariantBases:
          if rec.base == base and reach <= rec.maxReach:
            if reach == rec.maxReach and base notin guardEmitted:
              # Keep this as the guard check — it covers the max reach
              guardEmitted.add(base)
            else:
              f.blocks[bodyIdx].instrs[i].imm2 = instr.imm2 or boundsCheckedFlag
            break

proc loopUnroll*(f: var IrFunc) =
  ## 2× software-pipeline unrolling for simple phi-based while-loops.
  ##
  ## Eligible loops (the structure lower.nim produces for phi-based loops):
  ##
  ##   header [phis; cond_instrs; brif(exit_cond → exitBb, bodyBb)]
  ##   bodyBb  [body_instrs; irBr → header]       ← single back-edge
  ##   exitBb  [LocalSet*; irBr → after_loop]      ← no SSA results
  ##
  ## brif.imm  = exitBb  (taken when exit_cond is TRUE)
  ## brif.imm2 = bodyBb  (not-taken = loop continues)
  ##
  ## After 2× unrolling:
  ##
  ##   header  [phis; cond_A; brif(exit_cond_A → exitBb, bodyBb)]   unchanged
  ##   bodyBb  [body_A; irBr → midCheck]      ← back-edge now goes to mid-check
  ##   midCheck[cond_B_instrs; brif(exit_cond_B → exitB, bodyB)]   NEW
  ##   bodyB   [body_B; irBr → header]                              NEW
  ##   exitB   [LocalSet*(Iter-A values); irBr → after_loop]        NEW
  ##   exitBb  [LocalSet*(Iter-A phis);  irBr → after_loop]         unchanged
  ##
  ## Phi back-edges now point to bodyB outputs (stride 2).
  ##
  ## Correctness: every path checks the exit condition before each half-iteration,
  ## so no iteration is skipped or spuriously added for any trip count.

  type LoopInfo = object
    headerIdx: int
    bodyIdx: int   # brif.imm2 = not-taken = loop body
    exitIdx: int   # brif.imm  = taken     = exit block

  # ── Phase 1: collect eligible loops ──────────────────────────────────────
  var eligible: seq[LoopInfo]

  for hIdx in 0 ..< f.blocks.len:
    let hdr = f.blocks[hIdx]

    # Header must start with at least one phi and end with irBrIf
    if hdr.instrs.len < 2: continue
    if hdr.instrs[0].op != irPhi: continue
    let brif = hdr.instrs[^1]
    if brif.op != irBrIf: continue

    let exitIdx = brif.imm.int    # taken path = exit
    let bodyIdx = brif.imm2.int   # not-taken = loop body

    if exitIdx < 0 or bodyIdx < 0: continue
    if exitIdx >= f.blocks.len or bodyIdx >= f.blocks.len: continue

    # Body block: must end with a single irBr back to header (the back-edge)
    let bodyBb = f.blocks[bodyIdx]
    if bodyBb.instrs.len == 0: continue
    let backEdge = bodyBb.instrs[^1]
    if backEdge.op != irBr: continue
    if backEdge.imm.int != hIdx: continue  # must branch back to header
    if bodyIdx <= hIdx: continue           # body is a forward block

    # Body must have header as its only predecessor (simple loop, no multi-entry)
    var singlePred = true
    for pred in bodyBb.predecessors:
      if pred != hIdx: singlePred = false
    if not singlePred: continue

    # Exit block must have an irBr at the end (to find after_loop)
    let exitBb = f.blocks[exitIdx]
    if exitBb.instrs.len == 0: continue
    if exitBb.instrs[^1].op != irBr: continue

    # No calls in header or body (calling conventions differ; don't unroll)
    var hasCalls = false
    for instr in hdr.instrs:
      if instr.op == irCall: hasCalls = true
    for instr in bodyBb.instrs:
      if instr.op == irCall: hasCalls = true
    if hasCalls: continue

    # At least one loop-variant phi (otherwise unrolling buys nothing)
    var hasVariant = false
    var phiCount = 0
    while phiCount < hdr.instrs.len and hdr.instrs[phiCount].op == irPhi:
      let phi = hdr.instrs[phiCount]
      if phi.operands[1] >= 0 and phi.operands[1] != phi.result:
        hasVariant = true
      inc phiCount
    if not hasVariant: continue

    # The exit condition must be computed in the header (between phis and brif)
    # so that cloning the cond instrs gives a meaningful Iter-B check.
    let condA = brif.operands[0]
    var condInHeader = false
    for i in phiCount ..< hdr.instrs.len - 1:
      if hdr.instrs[i].result == condA:
        condInHeader = true; break
    if not condInHeader: continue

    eligible.add(LoopInfo(headerIdx: hIdx, bodyIdx: bodyIdx, exitIdx: exitIdx))

  # ── Phase 2: apply 2× unrolling ──────────────────────────────────────────
  for info in eligible:
    let hIdx    = info.headerIdx
    let bodyIdx = info.bodyIdx
    let exitIdx = info.exitIdx

    let brIfIdx  = f.blocks[hIdx].instrs.len - 1
    let condA    = f.blocks[hIdx].instrs[brIfIdx].operands[0]

    var phiCount = 0
    while phiCount < f.blocks[hIdx].instrs.len and
          f.blocks[hIdx].instrs[phiCount].op == irPhi:
      inc phiCount

    # ── Substitution map: phi.result → phi.operands[1] (Iter-A body outputs) ──
    # Extended in-place as we clone instructions.
    var sub = initTable[IrValue, IrValue]()
    for i in 0 ..< phiCount:
      let phi = f.blocks[hIdx].instrs[i]
      if phi.operands[1] >= 0:
        sub[phi.result] = phi.operands[1]

    # Inline clone helper: apply `sub` to operands, assign fresh result if needed.
    template applyAndClone(orig: IrInstr; dest: var seq[IrInstr]) =
      var c = orig
      c.result = if orig.result >= 0: f.newValue() else: -1.IrValue
      for j in 0 ..< 3:
        if c.operands[j] >= 0:
          let ov = c.operands[j]
          c.operands[j] = sub.getOrDefault(ov, ov)
      if orig.result >= 0:
        sub[orig.result] = c.result
      dest.add(c)

    # ── Clone header cond instrs (phiCount .. brIfIdx-1) ─────────────────
    # These use phi values from `sub` (phi → Iter-A body output).
    var condClones: seq[IrInstr]
    for i in phiCount ..< brIfIdx:
      let orig = f.blocks[hIdx].instrs[i]
      if orig.op == irNop: continue
      applyAndClone(orig, condClones)
    let condB = sub.getOrDefault(condA, condA)

    # ── Clone body instrs (all except last irBr) ─────────────────────────
    var bodyClones: seq[IrInstr]
    let bodyLen = f.blocks[bodyIdx].instrs.len - 1  # exclude the irBr back-edge
    for i in 0 ..< bodyLen:
      let orig = f.blocks[bodyIdx].instrs[i]
      if orig.op == irNop: continue
      applyAndClone(orig, bodyClones)

    # ── Find after_loop (irBr target in exit block) ──────────────────────
    let afterLoopIdx = f.blocks[exitIdx].instrs[^1].imm.int

    let midCheckIdx = f.blocks.len
    let bodyBIdx    = f.blocks.len + 1
    let exitBIdx    = f.blocks.len + 2

    # ── Build mid_check block: cond_B instrs + brif(condB → exitB, bodyB) ─
    var midCheck = BasicBlock(id: midCheckIdx, loopDepth: f.blocks[hIdx].loopDepth)
    midCheck.instrs = condClones
    midCheck.instrs.add(IrInstr(
      op: irBrIf, result: -1.IrValue,
      operands: [condB, -1.IrValue, -1.IrValue],
      imm:  exitBIdx.int64,
      imm2: bodyBIdx.int32))
    midCheck.successors   = @[exitBIdx, bodyBIdx]
    midCheck.predecessors = @[bodyIdx]

    # ── Build body_B block: cloned body + irBr → header ─────────────────
    var bodyB = BasicBlock(id: bodyBIdx, loopDepth: f.blocks[bodyIdx].loopDepth)
    bodyB.instrs = bodyClones
    bodyB.instrs.add(IrInstr(
      op: irBr, result: -1.IrValue,
      operands: [-1.IrValue, -1.IrValue, -1.IrValue],
      imm: hIdx.int64))
    bodyB.successors   = @[hIdx]
    bodyB.predecessors = @[midCheckIdx]

    # ── Build exit_B block: spill Iter-A outputs + irBr → after_loop ─────
    # Clone exit block's instrs with sub applied (phi → Iter-A body output).
    var exitB = BasicBlock(id: exitBIdx, loopDepth: f.blocks[exitIdx].loopDepth)
    for instr in f.blocks[exitIdx].instrs:
      var clone = instr
      if clone.op == irLocalSet and clone.operands[0] >= 0:
        let ov = clone.operands[0]
        clone.operands[0] = sub.getOrDefault(ov, ov)
      exitB.instrs.add(clone)
    exitB.successors   = if afterLoopIdx >= 0: @[afterLoopIdx] else: @[]
    exitB.predecessors = @[midCheckIdx]

    # ── Patch original body: back-edge irBr → header becomes irBr → midCheck
    let bodyLastIdx = f.blocks[bodyIdx].instrs.len - 1
    f.blocks[bodyIdx].instrs[bodyLastIdx].imm = midCheckIdx.int64

    # ── Update body's successor list ──────────────────────────────────────
    for i in 0 ..< f.blocks[bodyIdx].successors.len:
      if f.blocks[bodyIdx].successors[i] == hIdx:
        f.blocks[bodyIdx].successors[i] = midCheckIdx; break

    # ── Update header's back-edge predecessor: body → body_B ─────────────
    for i in 0 ..< f.blocks[hIdx].predecessors.len:
      if f.blocks[hIdx].predecessors[i] == bodyIdx:
        f.blocks[hIdx].predecessors[i] = bodyBIdx; break

    # ── Update phi back-edges to stride-2 values (body_B outputs) ────────
    for i in 0 ..< phiCount:
      let ov = f.blocks[hIdx].instrs[i].operands[1]
      if ov >= 0:
        f.blocks[hIdx].instrs[i].operands[1] = sub.getOrDefault(ov, ov)

    # ── Patch after_loop's predecessor list (add exit_B) ─────────────────
    if afterLoopIdx >= 0:
      f.blocks[afterLoopIdx].predecessors.add(exitBIdx)

    # ── Append new blocks ────────────────────────────────────────────────
    f.blocks.add(midCheck)
    f.blocks.add(bodyB)
    f.blocks.add(exitB)


proc instrCombine*(f: var IrFunc) =
  ## Multi-instruction pattern recognition and replacement.
  ##
  ## Patterns handled (within a single basic block, SSA-value lookup):
  ##
  ##  Sign-extension idioms (C-compiler output for integer narrowing):
  ##    (x shl 24) shr_s 24  →  irExtend8S32(x)    i32 sign-extend from 8-bit
  ##    (x shl 16) shr_s 16  →  irExtend16S32(x)   i32 sign-extend from 16-bit
  ##    (x shl 56) shr_s 56  →  irExtend8S64(x)    i64 sign-extend from 8-bit
  ##    (x shl 48) shr_s 48  →  irExtend16S64(x)   i64 sign-extend from 16-bit
  ##    (x shl 32) shr_s 32  →  irExtend32S64(x)   i64 sign-extend from 32-bit
  ##
  ##  Rotate detection (C-compiler output for bitwise rotate intrinsics):
  ##    (x shl n) or (x shr_u (32-n))  →  irRotl32(x, n)
  ##    (x shr_u n) or (x shl (32-n))  →  irRotr32(x, n)
  ##    (x shl n) or (x shr_u (64-n))  →  irRotl64(x, n)
  ##    (x shr_u n) or (x shl (64-n))  →  irRotr64(x, n)
  ##    Shift amounts must be constants summing to 32/64 respectively.
  ##
  ##  Redundant zero-masking after logical shift:
  ##    (x shr_u n) and mask   where mask == (2^(W-n) - 1)  →  (x shr_u n)
  ##    Logical right-shift already zeroes the high bits; AND is redundant.
  ##
  ##  Constant distribution (avoids a second multiplication):
  ##    (x * c1) + (x * c2)  →  x * (c1 + c2)  when c1, c2 are constants
  ##    (x * c1) - (x * c2)  →  x * (c1 - c2)  when c1, c2 are constants

  let constants = buildConstantMap(f)

  # Per-block definition index: defInstrIdx[v] = index of v's def in this BB.
  var defInstrIdx = newSeq[int](f.numValues)

  for bb in f.blocks.mitems:
    for j in 0 ..< defInstrIdx.len: defInstrIdx[j] = -1
    for idx in 0 ..< bb.instrs.len:
      let r = bb.instrs[idx].result
      if r >= 0 and r.int < defInstrIdx.len:
        defInstrIdx[r.int] = idx

    # Return the defining instruction of v within the current BB, or a
    # sentinel irNop with result=-1 when v is defined outside the block.
    template defOf(v: IrValue): IrInstr =
      (if v >= 0 and v.int < defInstrIdx.len and defInstrIdx[v.int] >= 0:
        bb.instrs[defInstrIdx[v.int]]
       else:
        IrInstr(op: irNop, result: -1.IrValue))

    # Convenience: look up a constant value (returns 0 / false if unknown)
    template knownConst(v: IrValue): bool =
      v >= 0 and v.int < constants.len and constants[v.int].known

    for i in 0 ..< bb.instrs.len:
      let instr = bb.instrs[i]
      if instr.result < 0: continue

      case instr.op

      # ----------------------------------------------------------------
      # Sign-extension idioms:  shr_s(shl(x, N), N)  →  extend_Ns(x)
      # ----------------------------------------------------------------
      of irShr32S:
        let shifteeVal = instr.operands[0]
        let shrAmtVal  = instr.operands[1]
        if knownConst(shrAmtVal):
          let n = constants[shrAmtVal.int].val
          let inner = defOf(shifteeVal)
          if inner.op == irShl32 and knownConst(inner.operands[1]) and
             constants[inner.operands[1].int].val == n:
            let extOp = case n
              of 24: irExtend8S32
              of 16: irExtend16S32
              else:  irNop
            if extOp != irNop:
              bb.instrs[i] = IrInstr(op: extOp, result: instr.result,
                operands: [inner.operands[0], -1.IrValue, -1.IrValue])

      of irShr64S:
        let shifteeVal = instr.operands[0]
        let shrAmtVal  = instr.operands[1]
        if knownConst(shrAmtVal):
          let n = constants[shrAmtVal.int].val
          let inner = defOf(shifteeVal)
          if inner.op == irShl64 and knownConst(inner.operands[1]) and
             constants[inner.operands[1].int].val == n:
            let extOp = case n
              of 56: irExtend8S64
              of 48: irExtend16S64
              of 32: irExtend32S64
              else:  irNop
            if extOp != irNop:
              bb.instrs[i] = IrInstr(op: extOp, result: instr.result,
                operands: [inner.operands[0], -1.IrValue, -1.IrValue])

      # ----------------------------------------------------------------
      # Rotate detection:
      #   (x shl n) or (x shr_u W-n)  →  rotl(x, n)
      #   (x shr_u n) or (x shl W-n)  →  rotr(x, n)
      # ----------------------------------------------------------------
      of irOr32:
        let lhsVal = instr.operands[0]
        let rhsVal = instr.operands[1]
        if lhsVal >= 0 and rhsVal >= 0:
          let lhs = defOf(lhsVal)
          let rhs = defOf(rhsVal)
          if lhs.op == irShl32 and rhs.op == irShr32U and
             lhs.operands[0] == rhs.operands[0] and
             knownConst(lhs.operands[1]) and knownConst(rhs.operands[1]):
            let n = constants[lhs.operands[1].int].val
            let m = constants[rhs.operands[1].int].val
            if n + m == 32 and n > 0 and n < 32:
              bb.instrs[i] = IrInstr(op: irRotl32, result: instr.result,
                operands: [lhs.operands[0], lhs.operands[1], -1.IrValue])
          elif lhs.op == irShr32U and rhs.op == irShl32 and
               lhs.operands[0] == rhs.operands[0] and
               knownConst(lhs.operands[1]) and knownConst(rhs.operands[1]):
            let n = constants[lhs.operands[1].int].val
            let m = constants[rhs.operands[1].int].val
            if n + m == 32 and n > 0 and n < 32:
              bb.instrs[i] = IrInstr(op: irRotr32, result: instr.result,
                operands: [lhs.operands[0], lhs.operands[1], -1.IrValue])

      of irOr64:
        let lhsVal = instr.operands[0]
        let rhsVal = instr.operands[1]
        if lhsVal >= 0 and rhsVal >= 0:
          let lhs = defOf(lhsVal)
          let rhs = defOf(rhsVal)
          if lhs.op == irShl64 and rhs.op == irShr64U and
             lhs.operands[0] == rhs.operands[0] and
             knownConst(lhs.operands[1]) and knownConst(rhs.operands[1]):
            let n = constants[lhs.operands[1].int].val
            let m = constants[rhs.operands[1].int].val
            if n + m == 64 and n > 0 and n < 64:
              bb.instrs[i] = IrInstr(op: irRotl64, result: instr.result,
                operands: [lhs.operands[0], lhs.operands[1], -1.IrValue])
          elif lhs.op == irShr64U and rhs.op == irShl64 and
               lhs.operands[0] == rhs.operands[0] and
               knownConst(lhs.operands[1]) and knownConst(rhs.operands[1]):
            let n = constants[lhs.operands[1].int].val
            let m = constants[rhs.operands[1].int].val
            if n + m == 64 and n > 0 and n < 64:
              bb.instrs[i] = IrInstr(op: irRotr64, result: instr.result,
                operands: [lhs.operands[0], lhs.operands[1], -1.IrValue])

      # ----------------------------------------------------------------
      # Redundant zero-mask after logical right shift:
      #   (x shr_u n) and mask  where mask == (1 << (W-n)) - 1  →  copy of shift
      # ----------------------------------------------------------------
      of irAnd32:
        let lhsVal = instr.operands[0]
        let rhsVal = instr.operands[1]
        # Form: shr_u result AND constant
        if knownConst(rhsVal):
          let mask = cast[uint32](constants[rhsVal.int].val)
          let lhs  = defOf(lhsVal)
          if lhs.op == irShr32U and knownConst(lhs.operands[1]):
            let n = constants[lhs.operands[1].int].val
            if n > 0 and n < 32:
              let expectedMask = uint32((1'u64 shl (32 - int(n))) - 1)
              if mask == expectedMask:
                bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
                  operands: [lhsVal, -1.IrValue, -1.IrValue])
        # Commutative: constant AND shr_u result
        elif knownConst(lhsVal):
          let mask = cast[uint32](constants[lhsVal.int].val)
          let rhs  = defOf(rhsVal)
          if rhs.op == irShr32U and knownConst(rhs.operands[1]):
            let n = constants[rhs.operands[1].int].val
            if n > 0 and n < 32:
              let expectedMask = uint32((1'u64 shl (32 - int(n))) - 1)
              if mask == expectedMask:
                bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
                  operands: [rhsVal, -1.IrValue, -1.IrValue])

      of irAnd64:
        let lhsVal = instr.operands[0]
        let rhsVal = instr.operands[1]
        if knownConst(rhsVal):
          let mask = cast[uint64](constants[rhsVal.int].val)
          let lhs  = defOf(lhsVal)
          if lhs.op == irShr64U and knownConst(lhs.operands[1]):
            let n = constants[lhs.operands[1].int].val
            if n > 0 and n < 64:
              let expectedMask = (1'u64 shl (64 - int(n))) - 1
              if mask == expectedMask:
                bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
                  operands: [lhsVal, -1.IrValue, -1.IrValue])
        elif knownConst(lhsVal):
          let mask = cast[uint64](constants[lhsVal.int].val)
          let rhs  = defOf(rhsVal)
          if rhs.op == irShr64U and knownConst(rhs.operands[1]):
            let n = constants[rhs.operands[1].int].val
            if n > 0 and n < 64:
              let expectedMask = (1'u64 shl (64 - int(n))) - 1
              if mask == expectedMask:
                bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
                  operands: [rhsVal, -1.IrValue, -1.IrValue])

      # ----------------------------------------------------------------
      # Constant distribution:
      #   (x * c1) + (x * c2)  →  x * (c1 + c2)
      #   (x * c1) - (x * c2)  →  x * (c1 - c2)
      # Both multiplications must share the same base SSA value and both
      # multipliers must be known constants.  We overwrite c1's constant
      # with the combined value, redirect lhsMul to use the new constant,
      # and replace rhsMul + the add/sub with irNop copies so DCE can clean
      # up the now-dead rhsMul.
      # ----------------------------------------------------------------
      of irAdd32:
        let lhsVal = instr.operands[0]
        let rhsVal = instr.operands[1]
        if lhsVal >= 0 and rhsVal >= 0:
          let lhs = defOf(lhsVal)
          let rhs = defOf(rhsVal)
          if lhs.op == irMul32 and rhs.op == irMul32 and
             lhs.operands[0] == rhs.operands[0]:
            let c1 = lhs.operands[1];  let c2 = rhs.operands[1]
            if knownConst(c1) and knownConst(c2):
              let combined = cast[int32](constants[c1.int].val) +
                             cast[int32](constants[c2.int].val)
              let c1Def = defInstrIdx[c1.int]
              if c1Def >= 0:
                bb.instrs[c1Def] = IrInstr(op: irConst32, result: c1,
                  imm: combined.int64)
              # The lhs mul now multiplies x by the new combined constant
              # (it already refers to c1, which holds the new value).
              # Kill the rhs mul and collapse add → copy of lhsMul.
              let rhsDef = defInstrIdx[rhsVal.int]
              if rhsDef >= 0:
                bb.instrs[rhsDef] = IrInstr(op: irNop, result: rhsVal,
                  operands: [lhsVal, -1.IrValue, -1.IrValue])
              bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
                operands: [lhsVal, -1.IrValue, -1.IrValue])

      of irSub32:
        let lhsVal = instr.operands[0]
        let rhsVal = instr.operands[1]
        if lhsVal >= 0 and rhsVal >= 0:
          let lhs = defOf(lhsVal)
          let rhs = defOf(rhsVal)
          if lhs.op == irMul32 and rhs.op == irMul32 and
             lhs.operands[0] == rhs.operands[0]:
            let c1 = lhs.operands[1];  let c2 = rhs.operands[1]
            if knownConst(c1) and knownConst(c2):
              let combined = cast[int32](constants[c1.int].val) -
                             cast[int32](constants[c2.int].val)
              let c1Def = defInstrIdx[c1.int]
              if c1Def >= 0:
                bb.instrs[c1Def] = IrInstr(op: irConst32, result: c1,
                  imm: combined.int64)
              let rhsDef = defInstrIdx[rhsVal.int]
              if rhsDef >= 0:
                bb.instrs[rhsDef] = IrInstr(op: irNop, result: rhsVal,
                  operands: [lhsVal, -1.IrValue, -1.IrValue])
              bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
                operands: [lhsVal, -1.IrValue, -1.IrValue])

      else:
        discard

proc storeLoadForward*(f: var IrFunc) =
  ## Within each basic block, if a load's address matches a preceding store of
  ## the same type, replace the load with a copy of the stored value.
  ## Any intervening call or irTrap clears the tracked stores (conservative).
  ##
  ## Address matching is alias-aware: uses pointer-origin analysis so that
  ## patterns like `ptr2 = ptr + 4; store ptr, v; load ptr2` are forwarded
  ## when ptr and ptr2 have the same canonical root + total offset.
  proc compatible(storeOp, loadOp: IrOpKind): bool =
    case storeOp
    of irStore32:  loadOp == irLoad32
    of irStore64:  loadOp == irLoad64
    of irStoreF32: loadOp == irLoadF32
    of irStoreF64: loadOp == irLoadF64
    else: false

  let origins = buildPtrOrigins(f)

  # Normalize an IR address value + static byte offset to (root, totalOffset).
  proc normalize(v: IrValue, immOff: int32): tuple[root: IrValue, total: int64] =
    let o = if v >= 0 and v.int < origins.len: origins[v.int] else: (v, 0'i64)
    (o.root, o.offset + immOff.int64)

  # Key: (canonical root, total byte offset, store op kind)
  type StoreKey = tuple[root: IrValue, total: int64]
  type StoreEntry = tuple[val: IrValue, storeOp: IrOpKind]

  for bb in f.blocks.mitems:
    var stores: Table[StoreKey, StoreEntry]

    for i in 0 ..< bb.instrs.len:
      let instr = bb.instrs[i]

      if instr.op in storeOps:
        let (root, total) = normalize(instr.operands[0], instr.imm2)
        stores[(root, total)] = (instr.operands[1], instr.op)

      elif instr.op in loadOps and instr.result >= 0:
        let (root, total) = normalize(instr.operands[0], instr.imm2)
        let entry = stores.getOrDefault((root, total),
                                        (val: -1.IrValue, storeOp: irNop))
        if entry.val >= 0 and compatible(entry.storeOp, instr.op):
          bb.instrs[i] = IrInstr(op: irNop, result: instr.result,
            operands: [entry.val, -1.IrValue, -1.IrValue])

      elif instr.op == irCall or instr.op == irTrap:
        stores.clear()

proc optimizeIr*(f: var IrFunc) =
  ## Run all IR optimization passes in the standard order.
  constantFold(f)
  strengthReduce(f)
  strengthReduceShifts(f)   # insert const+shift for mul/div by 2^n (n>1)
  instrCombine(f)            # sign-extension idioms, rotate detection, etc.
  localValueForward(f)
  storeLoadForward(f)        # forward stored values to matching loads
  commonSubexprElim(f)
  commonSubexprElimGlobal(f) # cross-block CSE: propagate available exprs via dominator chains
  deadCodeElim(f)            # first: remove dead irLocalGet (unused reloads)
  promoteLocals(f)           # then: remove dead irLocalSet (orphaned spills)
  boundsCheckElim(f)
  boundsCheckElimGlobal(f)
  boundsCheckElimAlias(f)          # alias-aware BCE: struct-field patterns (per-block)
  boundsCheckElimAliasGlobal(f)    # cross-block propagation of alias-based checks
  boundsCheckLoopHoist(f)          # hoist per-iteration bounds checks to preheader
  loopInvariantCodeMotion(f)
  commonSubexprElim(f)       # LICM exposes new CSE opportunities in preheaders
  deadCodeElim(f)            # clean up newly dead code after LICM + CSE
  fuseMultiplyAdd(f)         # fuse mul+add/sub → FMADD/FMSUB
  deadCodeElim(f)            # clean up irNop muls left by FMA fusion and instrCombine
  loopUnroll(f)              # 2× software-pipeline unrolling for tight loops

# ---------------------------------------------------------------------------
# Cost-gated optimization: skip passes the cost model says aren't needed
# ---------------------------------------------------------------------------

type
  OptGating* = object
    ## Which optimization passes to enable. Populated by cost.computeOptGating.
    runStoreLoadForward*: bool
    runGlobalCSE*: bool
    runPromoteLocals*: bool
    runGlobalBCE*: bool
    runAliasBCE*: bool
    runAliasGlobalBCE*: bool
    runLoopBCEHoist*: bool
    runLICM*: bool
    runFMA*: bool
    runLoopUnroll*: bool
    estimatedCompileTimeUs*: int32

proc optimizeIrGated*(f: var IrFunc, g: OptGating) =
  ## Run IR optimization passes gated by the cost analysis triage.
  ## Core O(n) passes always run. Expensive/situational passes are conditional.
  constantFold(f)
  strengthReduce(f)
  strengthReduceShifts(f)
  instrCombine(f)
  localValueForward(f)
  if g.runStoreLoadForward: storeLoadForward(f)
  commonSubexprElim(f)
  if g.runGlobalCSE: commonSubexprElimGlobal(f)
  deadCodeElim(f)
  if g.runPromoteLocals: promoteLocals(f)
  boundsCheckElim(f)
  if g.runGlobalBCE: boundsCheckElimGlobal(f)
  if g.runAliasBCE: boundsCheckElimAlias(f)
  if g.runAliasGlobalBCE: boundsCheckElimAliasGlobal(f)
  if g.runLoopBCEHoist: boundsCheckLoopHoist(f)
  if g.runLICM: loopInvariantCodeMotion(f)
  if g.runGlobalCSE: commonSubexprElim(f)
  deadCodeElim(f)
  if g.runFMA: fuseMultiplyAdd(f)
  deadCodeElim(f)
  if g.runLoopUnroll: loopUnroll(f)
