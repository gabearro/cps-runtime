## SSA-form intermediate representation for the optimizing JIT
## Converts WASM stack machine to explicit data-flow graph

type
  IrOpKind* = enum
    # Constants
    irConst32       # i32 constant
    irConst64       # i64 constant

    # Arithmetic (i32)
    irAdd32, irSub32, irMul32, irDiv32S, irDiv32U
    irRem32S, irRem32U
    irAnd32, irOr32, irXor32, irShl32, irShr32S, irShr32U
    irRotl32, irRotr32
    irClz32, irCtz32, irPopcnt32
    irEqz32

    # Arithmetic (i64)
    irAdd64, irSub64, irMul64, irDiv64S, irDiv64U
    irRem64S, irRem64U
    irAnd64, irOr64, irXor64, irShl64, irShr64S, irShr64U
    irRotl64, irRotr64
    irClz64, irCtz64, irPopcnt64
    irEqz64

    # Comparisons (result is i32)
    irEq32, irNe32, irLt32S, irLt32U, irGt32S, irGt32U
    irLe32S, irLe32U, irGe32S, irGe32U
    irEq64, irNe64, irLt64S, irLt64U, irGt64S, irGt64U
    irLe64S, irLe64U, irGe64S, irGe64U

    # Float constants
    irConstF32     # f32 constant (imm stores bit pattern as int64)
    irConstF64     # f64 constant (imm stores bit pattern as int64)

    # Float arithmetic (f32)
    irAddF32, irSubF32, irMulF32, irDivF32
    irAbsF32, irNegF32, irSqrtF32
    irMinF32, irMaxF32, irCopysignF32
    irCeilF32, irFloorF32, irTruncF32, irNearestF32
    ## Fused multiply-add family (f32):
    ##   irFmaF32(a,b,c)  = a*b + c   (FMADD Sd, Sa, Sb, Sc)
    ##   irFmsF32(a,b,c)  = c - a*b   (FMSUB Sd, Sa, Sb, Sc)
    ##   irFnmaF32(a,b,c) = -(a*b+c)  (FNMADD Sd, Sa, Sb, Sc)
    ##   irFnmsF32(a,b,c) = a*b - c   (FNMSUB Sd, Sa, Sb, Sc)
    ## operands[0]=a, operands[1]=b, operands[2]=c
    irFmaF32, irFmsF32, irFnmaF32, irFnmsF32

    # Float arithmetic (f64)
    irAddF64, irSubF64, irMulF64, irDivF64
    irAbsF64, irNegF64, irSqrtF64
    irMinF64, irMaxF64, irCopysignF64
    irCeilF64, irFloorF64, irTruncF64, irNearestF64
    ## Fused multiply-add family (f64):
    irFmaF64, irFmsF64, irFnmaF64, irFnmsF64

    # Float comparisons (result is i32)
    irEqF32, irNeF32, irLtF32, irGtF32, irLeF32, irGeF32
    irEqF64, irNeF64, irLtF64, irGtF64, irLeF64, irGeF64

    # Float conversions
    irF32ConvertI32S, irF32ConvertI32U
    irF32ConvertI64S, irF32ConvertI64U
    irF64ConvertI32S, irF64ConvertI32U
    irF64ConvertI64S, irF64ConvertI64U
    irF32DemoteF64, irF64PromoteF32
    irI32TruncF32S, irI32TruncF32U
    irI32TruncF64S, irI32TruncF64U
    irI64TruncF32S, irI64TruncF32U
    irI64TruncF64S, irI64TruncF64U
    irI32ReinterpretF32, irI64ReinterpretF64
    irF32ReinterpretI32, irF64ReinterpretI64

    # Float memory
    irLoadF32, irLoadF64
    irStoreF32, irStoreF64

    # Conversions
    irWrapI64, irExtendI32S, irExtendI32U
    irExtend8S32, irExtend16S32
    irExtend8S64, irExtend16S64, irExtend32S64

    # Memory
    irLoad32, irLoad64
    irLoad8U, irLoad8S, irLoad16U, irLoad16S
    irLoad32U, irLoad32S  # to i64
    irStore32, irStore64
    irStore8, irStore16, irStore32From64

    # Variables
    irLocalGet     # read a local
    irLocalSet     # write a local (side effect)

    # Control flow
    irPhi          # SSA phi function
    irBr           # unconditional branch
    irBrIf         # conditional branch
    irReturn       # function return
    irSelect       # select (ternary)
    irCall         # function call (to interpreter trampoline)

    # SIMD v128 (AArch64: NEON Q registers)
    irLoadV128          # v128 load  (operands[0]=addr, imm2=offset); result=v128
    irStoreV128         # v128 store (operands[0]=addr, operands[1]=v128, imm2=offset)
    irConstV128         # v128 const (imm=index into IrFunc.v128Consts); result=v128
    irI32x4Splat        # i32→v128.4S broadcast (operands[0]=i32); result=v128
    irF32x4Splat        # f32→v128.4S broadcast (operands[0]=f32); result=v128
    irI32x4ExtractLane  # v128→i32 (operands[0]=v128, imm=lane 0-3); result=i32
    irI32x4ReplaceLane  # (v128, i32)→v128 (operands[0]=v128, operands[1]=i32, imm=lane)
    irF32x4ExtractLane  # v128→f32 (operands[0]=v128, imm=lane 0-3); result=f32
    irF32x4ReplaceLane  # (v128, f32)→v128 (operands[0]=v128, operands[1]=f32, imm=lane)
    irV128Not           # ~v128 (operands[0]=v128); result=v128
    irV128And           # v128 & v128 (operands[0,1]=v128); result=v128
    irV128Or            # v128 | v128
    irV128Xor           # v128 ^ v128
    irI32x4Add          # i32x4 add (operands[0,1]=v128); result=v128
    irI32x4Sub          # i32x4 sub
    irI32x4Mul          # i32x4 mul
    irF32x4Add          # f32x4 add
    irF32x4Sub          # f32x4 sub
    irF32x4Mul          # f32x4 mul
    irF32x4Div          # f32x4 div

    # Extended SIMD v128 — splats for additional types
    irI8x16Splat        # i32 low byte → v128.16B (operands[0]=i32)
    irI16x8Splat        # i32 low halfword → v128.8H (operands[0]=i32)
    irI64x2Splat        # i64 → v128.2D (operands[0]=i64)
    irF64x2Splat        # i64 (f64 bits) → v128.2D (operands[0]=i64)
    # i8x16 lane ops
    irI8x16ExtractLaneS # v128→i32 sign-extended (operands[0]=v128, imm=lane 0-15)
    irI8x16ExtractLaneU # v128→i32 zero-extended (operands[0]=v128, imm=lane 0-15)
    irI8x16ReplaceLane  # (v128, i32)→v128 (operands[0]=v128, operands[1]=i32, imm=lane)
    # i16x8 lane ops
    irI16x8ExtractLaneS # v128→i32 sign-extended (operands[0]=v128, imm=lane 0-7)
    irI16x8ExtractLaneU # v128→i32 zero-extended (operands[0]=v128, imm=lane 0-7)
    irI16x8ReplaceLane  # (v128, i32)→v128 (operands[0]=v128, operands[1]=i32, imm=lane)
    # i64x2 lane ops
    irI64x2ExtractLane  # v128→i64 (operands[0]=v128, imm=lane 0-1)
    irI64x2ReplaceLane  # (v128, i64)→v128 (operands[0]=v128, operands[1]=i64, imm=lane)
    # f64x2 lane ops
    irF64x2ExtractLane  # v128→i64 (f64 bits) (operands[0]=v128, imm=lane 0-1)
    irF64x2ReplaceLane  # (v128, i64)→v128 (operands[0]=v128, operands[1]=i64, imm=lane)
    # v128 bitwise extensions
    irV128AndNot        # a & ~b (operands[0,1]=v128); result=v128
    # i8x16 arithmetic
    irI8x16Abs          # |v128| 16B (operands[0]=v128)
    irI8x16Neg          # -v128 16B
    irI8x16Add          # v128 + v128 16B (operands[0,1]=v128)
    irI8x16Sub          # v128 - v128 16B
    irI8x16MinS         # signed min 16B
    irI8x16MinU         # unsigned min 16B
    irI8x16MaxS         # signed max 16B
    irI8x16MaxU         # unsigned max 16B
    # i16x8 arithmetic
    irI16x8Abs          # |v128| 8H
    irI16x8Neg          # -v128 8H
    irI16x8Add          # v128 + v128 8H
    irI16x8Sub          # v128 - v128 8H
    irI16x8Mul          # v128 * v128 8H
    # i32x4 extensions
    irI32x4Abs          # |v128| 4S
    irI32x4Neg          # -v128 4S
    irI32x4Shl          # left shift 4S (operands[0]=v128, operands[1]=i32 shift amount)
    irI32x4ShrS         # arithmetic right shift 4S (operands[0]=v128, operands[1]=i32)
    irI32x4ShrU         # logical right shift 4S (operands[0]=v128, operands[1]=i32)
    irI32x4MinS         # signed min 4S
    irI32x4MinU         # unsigned min 4S
    irI32x4MaxS         # signed max 4S
    irI32x4MaxU         # unsigned max 4S
    # i64x2 arithmetic
    irI64x2Add          # v128 + v128 2D
    irI64x2Sub          # v128 - v128 2D
    # f32x4 unary
    irF32x4Abs          # |v128| 4S float
    irF32x4Neg          # -v128 4S float
    # f64x2 full set
    irF64x2Add          # v128 + v128 2D float
    irF64x2Sub          # v128 - v128 2D float
    irF64x2Mul          # v128 * v128 2D float
    irF64x2Div          # v128 / v128 2D float
    irF64x2Abs          # |v128| 2D float
    irF64x2Neg          # -v128 2D float

    # Indirect call
    irCallIndirect  # call_indirect: operands[0]=elemIdx, imm=paramCount|(resultCount<<16), imm2=tempBase

    # Special
    irParam        # function parameter
    irNop          # no-op (placeholder)
    irTrap         # trap (unreachable)

  IrValue* = int32  # SSA value ID (index into IrFunc.values)

  IrInstr* = object
    op*: IrOpKind
    result*: IrValue    # SSA value this produces (-1 if none)
    operands*: array[3, IrValue]  # up to 3 input SSA values (-1 if unused)
    imm*: int64          # immediate constant or offset
    imm2*: int32         # second immediate (e.g., memory offset)
    branchProb*: uint8   # irBrIf only: taken-probability [0=never,128=50%,255=always]

  BasicBlock* = object
    id*: int
    instrs*: seq[IrInstr]
    successors*: seq[int]  # block IDs
    predecessors*: seq[int]
    loopDepth*: int

  IrFunc* = object
    blocks*: seq[BasicBlock]
    numValues*: int       # total SSA values allocated
    numLocals*: int       # WASM locals count (may include synthetic temp slots for call_indirect)
    numParams*: int       # WASM params count
    numResults*: int      # WASM results count
    usesMemory*: bool     # true if any memory load/store/size/grow ops
    callIndirectSiteCount*: int  # number of call_indirect sites (for pre-allocating caches)
    nonSelfCallSiteCount*: int   # number of non-self irCall sites (for pre-allocating direct-call caches)
    v128Consts*: seq[array[16, byte]]  # literal v128 constants (indexed by irConstV128.imm)
    isSimd*: seq[bool]    # per-SSA-value: true if this value is a v128 (SIMD reg class)

  # Phi coalescing: communication between analysis, scheduler, and regalloc.
  # When a phi result and its back-edge operand can share a register,
  # the trampoline MOV is eliminated.
  PhiCoalescePair* = object
    phiResult*: IrValue     ## SSA value produced by the phi node
    backEdgeOp*: IrValue    ## SSA value from the back-edge (operands[1])
    defInstrIdx*: int       ## index of the instruction defining backEdgeOp in the loop body
    phiUsers*: seq[int]     ## indices of instructions in the loop body that USE phiResult
    blockIdx*: int          ## the loop header block index

  PhiCoalesceInfo* = object
    pairs*: seq[PhiCoalescePair]
    feasible*: seq[bool]    ## per-pair: true if scheduling achieved safe ordering

proc newValue*(f: var IrFunc): IrValue =
  result = f.numValues.IrValue
  f.isSimd.add(false)
  inc f.numValues

proc newSimdValue*(f: var IrFunc): IrValue =
  result = f.numValues.IrValue
  f.isSimd.add(true)
  inc f.numValues

proc addInstr*(bb: var BasicBlock, instr: IrInstr) =
  bb.instrs.add(instr)

proc makeConst32*(f: var IrFunc, bb: var BasicBlock, val: int32): IrValue =
  result = f.newValue()
  bb.addInstr(IrInstr(op: irConst32, result: result, imm: val.int64))

proc makeConst64*(f: var IrFunc, bb: var BasicBlock, val: int64): IrValue =
  result = f.newValue()
  bb.addInstr(IrInstr(op: irConst64, result: result, imm: val))

proc makeConstF32*(f: var IrFunc, bb: var BasicBlock, val: float32): IrValue =
  result = f.newValue()
  bb.addInstr(IrInstr(op: irConstF32, result: result, imm: cast[int32](val).int64))

proc makeConstF64*(f: var IrFunc, bb: var BasicBlock, val: float64): IrValue =
  result = f.newValue()
  bb.addInstr(IrInstr(op: irConstF64, result: result, imm: cast[int64](val)))

proc makeBinOp*(f: var IrFunc, bb: var BasicBlock, op: IrOpKind, a, b: IrValue): IrValue =
  result = f.newValue()
  bb.addInstr(IrInstr(op: op, result: result, operands: [a, b, -1.IrValue]))

proc makeUnaryOp*(f: var IrFunc, bb: var BasicBlock, op: IrOpKind, a: IrValue): IrValue =
  result = f.newValue()
  bb.addInstr(IrInstr(op: op, result: result, operands: [a, -1.IrValue, -1.IrValue]))

proc makeLoad*(f: var IrFunc, bb: var BasicBlock, op: IrOpKind, address: IrValue, offset: int32): IrValue =
  result = f.newValue()
  bb.addInstr(IrInstr(op: op, result: result, operands: [address, -1.IrValue, -1.IrValue], imm2: offset))

proc makeStore*(f: var IrFunc, bb: var BasicBlock, op: IrOpKind, address, val: IrValue, offset: int32) =
  bb.addInstr(IrInstr(op: op, result: -1.IrValue, operands: [address, val, -1.IrValue], imm2: offset))

proc makeParam*(f: var IrFunc, bb: var BasicBlock, idx: int): IrValue =
  result = f.newValue()
  bb.addInstr(IrInstr(op: irParam, result: result, imm: idx.int64))

proc makePhi*(f: var IrFunc, bb: var BasicBlock): IrValue =
  result = f.newValue()
  bb.addInstr(IrInstr(op: irPhi, result: result))
