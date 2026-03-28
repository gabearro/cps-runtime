## WebAssembly core types
## Covers: value types, function types, module structure, instruction IR

type
  ValType* = enum
    vtI32 = 0x7F
    vtI64 = 0x7E
    vtF32 = 0x7D
    vtF64 = 0x7C
    vtV128 = 0x7B
    vtFuncRef = 0x70
    vtExternRef = 0x6F

  Mutability* = enum
    mutConst = 0
    mutVar = 1

  FuncType* = object
    params*: seq[ValType]
    results*: seq[ValType]

  Limits* = object
    min*: uint32
    max*: uint32
    hasMax*: bool

  MemType* = object
    limits*: Limits

  TableType* = object
    elemType*: ValType
    limits*: Limits

  GlobalType* = object
    valType*: ValType
    mut*: Mutability

  # Block types for control instructions
  BlockTypeKind* = enum
    btkEmpty
    btkValType
    btkTypeIdx

  BlockType* = object
    case kind*: BlockTypeKind
    of btkEmpty: discard
    of btkValType:
      valType*: ValType
    of btkTypeIdx:
      typeIdx*: uint32

  # Import/Export descriptors
  ImportKind* = enum
    ikFunc = 0
    ikTable = 1
    ikMemory = 2
    ikGlobal = 3

  ExportKind* = enum
    ekFunc = 0
    ekTable = 1
    ekMemory = 2
    ekGlobal = 3

  Import* = object
    module*: string
    name*: string
    case kind*: ImportKind
    of ikFunc:
      funcTypeIdx*: uint32
    of ikTable:
      tableType*: TableType
    of ikMemory:
      memType*: MemType
    of ikGlobal:
      globalType*: GlobalType

  Export* = object
    name*: string
    kind*: ExportKind
    idx*: uint32

  # Pre-decoded instruction representation
  Opcode* = enum
    # Control
    opUnreachable = 0x00
    opNop = 0x01
    opBlock = 0x02
    opLoop = 0x03
    opIf = 0x04
    opElse = 0x05
    opEnd = 0x0B
    opBr = 0x0C
    opBrIf = 0x0D
    opBrTable = 0x0E
    opReturn = 0x0F
    opCall = 0x10
    opCallIndirect = 0x11

    # Parametric
    opDrop = 0x1A
    opSelect = 0x1B
    opSelectTyped = 0x1C

    # Variable
    opLocalGet = 0x20
    opLocalSet = 0x21
    opLocalTee = 0x22
    opGlobalGet = 0x23
    opGlobalSet = 0x24

    # Table
    opTableGet = 0x25
    opTableSet = 0x26

    # Memory
    opI32Load = 0x28
    opI64Load = 0x29
    opF32Load = 0x2A
    opF64Load = 0x2B
    opI32Load8S = 0x2C
    opI32Load8U = 0x2D
    opI32Load16S = 0x2E
    opI32Load16U = 0x2F
    opI64Load8S = 0x30
    opI64Load8U = 0x31
    opI64Load16S = 0x32
    opI64Load16U = 0x33
    opI64Load32S = 0x34
    opI64Load32U = 0x35
    opI32Store = 0x36
    opI64Store = 0x37
    opF32Store = 0x38
    opF64Store = 0x39
    opI32Store8 = 0x3A
    opI32Store16 = 0x3B
    opI64Store8 = 0x3C
    opI64Store16 = 0x3D
    opI64Store32 = 0x3E
    opMemorySize = 0x3F
    opMemoryGrow = 0x40

    # Constants
    opI32Const = 0x41
    opI64Const = 0x42
    opF32Const = 0x43
    opF64Const = 0x44

    # i32 comparison
    opI32Eqz = 0x45
    opI32Eq = 0x46
    opI32Ne = 0x47
    opI32LtS = 0x48
    opI32LtU = 0x49
    opI32GtS = 0x4A
    opI32GtU = 0x4B
    opI32LeS = 0x4C
    opI32LeU = 0x4D
    opI32GeS = 0x4E
    opI32GeU = 0x4F

    # i64 comparison
    opI64Eqz = 0x50
    opI64Eq = 0x51
    opI64Ne = 0x52
    opI64LtS = 0x53
    opI64LtU = 0x54
    opI64GtS = 0x55
    opI64GtU = 0x56
    opI64LeS = 0x57
    opI64LeU = 0x58
    opI64GeS = 0x59
    opI64GeU = 0x5A

    # f32 comparison
    opF32Eq = 0x5B
    opF32Ne = 0x5C
    opF32Lt = 0x5D
    opF32Gt = 0x5E
    opF32Le = 0x5F
    opF32Ge = 0x60

    # f64 comparison
    opF64Eq = 0x61
    opF64Ne = 0x62
    opF64Lt = 0x63
    opF64Gt = 0x64
    opF64Le = 0x65
    opF64Ge = 0x66

    # i32 arithmetic
    opI32Clz = 0x67
    opI32Ctz = 0x68
    opI32Popcnt = 0x69
    opI32Add = 0x6A
    opI32Sub = 0x6B
    opI32Mul = 0x6C
    opI32DivS = 0x6D
    opI32DivU = 0x6E
    opI32RemS = 0x6F
    opI32RemU = 0x70
    opI32And = 0x71
    opI32Or = 0x72
    opI32Xor = 0x73
    opI32Shl = 0x74
    opI32ShrS = 0x75
    opI32ShrU = 0x76
    opI32Rotl = 0x77
    opI32Rotr = 0x78

    # i64 arithmetic
    opI64Clz = 0x79
    opI64Ctz = 0x7A
    opI64Popcnt = 0x7B
    opI64Add = 0x7C
    opI64Sub = 0x7D
    opI64Mul = 0x7E
    opI64DivS = 0x7F
    opI64DivU = 0x80
    opI64RemS = 0x81
    opI64RemU = 0x82
    opI64And = 0x83
    opI64Or = 0x84
    opI64Xor = 0x85
    opI64Shl = 0x86
    opI64ShrS = 0x87
    opI64ShrU = 0x88
    opI64Rotl = 0x89
    opI64Rotr = 0x8A

    # f32 arithmetic
    opF32Abs = 0x8B
    opF32Neg = 0x8C
    opF32Ceil = 0x8D
    opF32Floor = 0x8E
    opF32Trunc = 0x8F
    opF32Nearest = 0x90
    opF32Sqrt = 0x91
    opF32Add = 0x92
    opF32Sub = 0x93
    opF32Mul = 0x94
    opF32Div = 0x95
    opF32Min = 0x96
    opF32Max = 0x97
    opF32Copysign = 0x98

    # f64 arithmetic
    opF64Abs = 0x99
    opF64Neg = 0x9A
    opF64Ceil = 0x9B
    opF64Floor = 0x9C
    opF64Trunc = 0x9D
    opF64Nearest = 0x9E
    opF64Sqrt = 0x9F
    opF64Add = 0xA0
    opF64Sub = 0xA1
    opF64Mul = 0xA2
    opF64Div = 0xA3
    opF64Min = 0xA4
    opF64Max = 0xA5
    opF64Copysign = 0xA6

    # Conversions
    opI32WrapI64 = 0xA7
    opI32TruncF32S = 0xA8
    opI32TruncF32U = 0xA9
    opI32TruncF64S = 0xAA
    opI32TruncF64U = 0xAB
    opI64ExtendI32S = 0xAC
    opI64ExtendI32U = 0xAD
    opI64TruncF32S = 0xAE
    opI64TruncF32U = 0xAF
    opI64TruncF64S = 0xB0
    opI64TruncF64U = 0xB1
    opF32ConvertI32S = 0xB2
    opF32ConvertI32U = 0xB3
    opF32ConvertI64S = 0xB4
    opF32ConvertI64U = 0xB5
    opF32DemoteF64 = 0xB6
    opF64ConvertI32S = 0xB7
    opF64ConvertI32U = 0xB8
    opF64ConvertI64S = 0xB9
    opF64ConvertI64U = 0xBA
    opF64PromoteF32 = 0xBB
    opI32ReinterpretF32 = 0xBC
    opI64ReinterpretF64 = 0xBD
    opF32ReinterpretI32 = 0xBE
    opF64ReinterpretI64 = 0xBF

    # Sign extension
    opI32Extend8S = 0xC0
    opI32Extend16S = 0xC1
    opI64Extend8S = 0xC2
    opI64Extend16S = 0xC3
    opI64Extend32S = 0xC4

    # Reference
    opRefNull = 0xD0
    opRefIsNull = 0xD1
    opRefFunc = 0xD2

    # Multi-byte prefix instructions (represented as high values)
    opI32TruncSatF32S = 0x100  # 0xFC 0
    opI32TruncSatF32U = 0x101  # 0xFC 1
    opI32TruncSatF64S = 0x102  # 0xFC 2
    opI32TruncSatF64U = 0x103  # 0xFC 3
    opI64TruncSatF32S = 0x104  # 0xFC 4
    opI64TruncSatF32U = 0x105  # 0xFC 5
    opI64TruncSatF64S = 0x106  # 0xFC 6
    opI64TruncSatF64U = 0x107  # 0xFC 7

    # Bulk memory (0xFC prefix)
    opMemoryInit = 0x108  # 0xFC 8
    opDataDrop = 0x109    # 0xFC 9
    opMemoryCopy = 0x10A  # 0xFC 10
    opMemoryFill = 0x10B  # 0xFC 11

    # Bulk table (0xFC prefix)
    opTableInit = 0x10C   # 0xFC 12
    opElemDrop = 0x10D    # 0xFC 13
    opTableCopy = 0x10E   # 0xFC 14
    opTableGrow = 0x10F   # 0xFC 15
    opTableSize = 0x110   # 0xFC 16
    opTableFill = 0x111   # 0xFC 17

    # ---- Fused superinstructions (peephole optimization) ----
    # These are never in the binary format; created by peephole pass.
    # Fused instructions combine two instructions into one dispatch.
    # imm1 = first instruction's immediate, imm2 = second instruction's immediate (or shared)
    opLocalGetLocalGet = 0x200   # local.get X; local.get Y → imm1=X, imm2=Y
    opLocalGetI32Add = 0x201     # local.get X; i32.add → imm1=X
    opLocalGetI32Sub = 0x202     # local.get X; i32.sub → imm1=X
    opLocalGetI32Store = 0x203   # local.get X; i32.store offset → imm1=X, imm2=offset
    opI32ConstI32Add = 0x204     # i32.const C; i32.add → imm1=C (as uint32)
    opI32ConstI32Sub = 0x205     # i32.const C; i32.sub → imm1=C (as uint32)
    opLocalSetLocalGet = 0x206   # local.set X; local.get Y → imm1=X, imm2=Y
    opLocalTeeLocalGet = 0x207   # local.tee X; local.get Y → imm1=X, imm2=Y
    opLocalGetI32Const = 0x208   # local.get X; i32.const C → imm1=X, imm2=C (as uint32)
    opI32AddLocalSet = 0x209     # i32.add; local.set X → imm1=X
    opI32SubLocalSet = 0x20A     # i32.sub; local.set X → imm1=X
    opI32EqzBrIf = 0x20B        # i32.eqz; br_if L → imm1=L (branch if TOS == 0)

    # Triple fusions (3 instructions → 1 dispatch)
    # local.get X; local.get Y; i32.add → imm1=X, imm2=Y
    opLocalGetLocalGetI32Add = 0x210
    # local.get X; local.get Y; i32.sub → imm1=X, imm2=Y
    opLocalGetLocalGetI32Sub = 0x211
    # local.get X; i32.const C; i32.sub → imm1=X, imm2=C
    opLocalGetI32ConstI32Sub = 0x212
    # local.get X; i32.const C; i32.add → imm1=X, imm2=C
    opLocalGetI32ConstI32Add = 0x213
    # local.get X; local.tee Y → push local[X], then tee to local[Y] (imm1=X, imm2=Y)
    opLocalGetLocalTee = 0x214
    # i32.const C; i32.gt_u → compare TOS > C unsigned (imm1=C)
    opI32ConstI32GtU = 0x215
    # i32.const C; i32.lt_s → compare TOS < C signed (imm1=C)
    opI32ConstI32LtS = 0x216
    # i32.const C; i32.ge_s → compare TOS >= C signed (imm1=C)
    opI32ConstI32GeS = 0x217
    # local.get X; i32.load offset → load mem[local[X] + offset] (imm1=X, imm2=offset)
    opLocalGetI32Load = 0x218
    # i32.const C; i32.eq → compare TOS == C (imm1=C)
    opI32ConstI32Eq = 0x219
    # i32.const C; i32.ne → compare TOS != C (imm1=C)
    opI32ConstI32Ne = 0x21A
    # local.get X; i32.gt_s → compare TOS > local[X] signed (imm1=X)
    opLocalGetI32GtS = 0x21B
    # i32.const C; i32.and → TOS & C (imm1=C)
    opI32ConstI32And = 0x21C
    # i32.const C; i32.mul → TOS * C (imm1=C)
    opI32ConstI32Mul = 0x21D
    # local.get X; i32.mul → TOS * local[X] (imm1=X)
    opLocalGetI32Mul = 0x21E

    # local.get X; i32.load off; i32.add → push(TOS + mem[local[X]+off]) (imm1=X, imm2=off)
    opLocalGetI32LoadI32Add = 0x220

    # ---- Binary comparison + br_if pairs (imm1 = label depth) ----
    opI32EqBrIf   = 0x22A  # i32.eq;   br_if L → pop b, pop a, branch if a == b
    opI32NeBrIf   = 0x22B  # i32.ne;   br_if L → pop b, pop a, branch if a != b
    opI32LtSBrIf  = 0x22C  # i32.lt_s; br_if L
    opI32GeSBrIf  = 0x22D  # i32.ge_s; br_if L
    opI32GtSBrIf  = 0x22E  # i32.gt_s; br_if L
    opI32LeSBrIf  = 0x22F  # i32.le_s; br_if L
    opI32LtUBrIf  = 0x230  # i32.lt_u; br_if L
    opI32GeUBrIf  = 0x231  # i32.ge_u; br_if L
    opI32GtUBrIf  = 0x232  # i32.gt_u; br_if L
    opI32LeUBrIf  = 0x233  # i32.le_u; br_if L

    # ---- Triple: i32.const C; comparison; br_if L (imm1=C, imm2=L) ----
    opI32ConstI32EqBrIf   = 0x234  # branch if TOS == C
    opI32ConstI32NeBrIf   = 0x235  # branch if TOS != C
    opI32ConstI32LtSBrIf  = 0x236  # branch if TOS < C (signed)
    opI32ConstI32GeSBrIf  = 0x237  # branch if TOS >= C (signed)
    opI32ConstI32GtUBrIf  = 0x238  # branch if TOS > C (unsigned)
    opI32ConstI32LeUBrIf  = 0x239  # branch if TOS <= C (unsigned)

    # ---- i64 local.get + arithmetic pairs (imm1 = local index) ----
    opLocalGetI64Add = 0x240  # local.get X; i64.add → TOS_i64 + local[X] as i64
    opLocalGetI64Sub = 0x241  # local.get X; i64.sub → TOS_i64 - local[X] as i64

    # ---- Quad fusions (4 instructions → 1 dispatch) ----
    # local[X] += C  (local.get X; i32.const C; i32.add; local.set X)
    opLocalI32AddInPlace = 0x250  # imm1=X, imm2=C
    # local[X] -= C  (local.get X; i32.const C; i32.sub; local.set X)
    opLocalI32SubInPlace = 0x251  # imm1=X, imm2=C
    # Z = X + Y  (local.get X; local.get Y; i32.add; local.set Z)
    # imm1 = X | (Y << 16) [both indices <= 0xFFFF], imm2 = Z
    opLocalGetLocalGetI32AddLocalSet = 0x252
    # Z = X - Y  (local.get X; local.get Y; i32.sub; local.set Z)
    opLocalGetLocalGetI32SubLocalSet = 0x253

    # ---- Pair: local.tee X; br_if L → tee then branch ----
    # Semantics: local[X] = TOS; pop; branch to L if nonzero
    opLocalTeeBrIf = 0x260  # imm1=X, imm2=L (label depth)

    # ---- SIMD v128 (0xFD prefix) — core subset ----
    # imm1/imm2 encode memarg (align, offset) or lane index as needed.
    # For opV128Const: imm1 = index into Expr.v128Consts.
    opV128Load          = 0x300  # 0xFD 0    v128.load (imm1=align, imm2=offset)
    opV128Store         = 0x301  # 0xFD 11   v128.store
    opV128Const         = 0x302  # 0xFD 12   v128.const (imm1=idx into v128Consts)
    opI8x16Splat        = 0x303  # 0xFD 15   i8x16.splat
    opI16x8Splat        = 0x304  # 0xFD 16   i16x8.splat
    opI32x4Splat        = 0x305  # 0xFD 17   i32x4.splat
    opI64x2Splat        = 0x306  # 0xFD 18   i64x2.splat
    opF32x4Splat        = 0x307  # 0xFD 19   f32x4.splat
    opF64x2Splat        = 0x308  # 0xFD 20   f64x2.splat
    opI32x4ExtractLane  = 0x309  # 0xFD 27   i32x4.extract_lane (imm1=lane 0-3)
    opI32x4ReplaceLane  = 0x30A  # 0xFD 28   i32x4.replace_lane (imm1=lane)
    opF32x4ExtractLane  = 0x30B  # 0xFD 31   f32x4.extract_lane (imm1=lane 0-3)
    opF32x4ReplaceLane  = 0x30C  # 0xFD 32   f32x4.replace_lane (imm1=lane)
    opV128Not           = 0x30D  # 0xFD 77   v128.not
    opV128And           = 0x30E  # 0xFD 78   v128.and
    opV128Or            = 0x30F  # 0xFD 80   v128.or
    opV128Xor           = 0x310  # 0xFD 81   v128.xor
    opI32x4Add          = 0x311  # 0xFD 174  i32x4.add
    opI32x4Sub          = 0x312  # 0xFD 177  i32x4.sub
    opI32x4Mul          = 0x313  # 0xFD 181  i32x4.mul
    opF32x4Add          = 0x314  # 0xFD 228  f32x4.add
    opF32x4Sub          = 0x315  # 0xFD 229  f32x4.sub
    opF32x4Mul          = 0x316  # 0xFD 230  f32x4.mul
    opF32x4Div          = 0x317  # 0xFD 231  f32x4.div

    # ---- Extended SIMD v128 ----
    # i8x16 lane ops (each reads a lane byte immediate)
    opI8x16ExtractLaneS = 0x318  # 0xFD 21  i8x16.extract_lane_s
    opI8x16ExtractLaneU = 0x319  # 0xFD 22  i8x16.extract_lane_u
    opI8x16ReplaceLane  = 0x31A  # 0xFD 23  i8x16.replace_lane
    # i16x8 lane ops
    opI16x8ExtractLaneS = 0x31B  # 0xFD 24  i16x8.extract_lane_s
    opI16x8ExtractLaneU = 0x31C  # 0xFD 25  i16x8.extract_lane_u
    opI16x8ReplaceLane  = 0x31D  # 0xFD 26  i16x8.replace_lane
    # i64x2 lane ops
    opI64x2ExtractLane  = 0x31E  # 0xFD 29  i64x2.extract_lane
    opI64x2ReplaceLane  = 0x31F  # 0xFD 30  i64x2.replace_lane
    # f64x2 lane ops
    opF64x2ExtractLane  = 0x320  # 0xFD 33  f64x2.extract_lane
    opF64x2ReplaceLane  = 0x321  # 0xFD 34  f64x2.replace_lane
    # v128 bitwise extensions
    opV128AndNot        = 0x322  # 0xFD 79  v128.andnot
    # i8x16 arithmetic
    opI8x16Abs          = 0x323  # 0xFD 96  i8x16.abs
    opI8x16Neg          = 0x324  # 0xFD 97  i8x16.neg
    opI8x16Add          = 0x325  # 0xFD 110 i8x16.add
    opI8x16Sub          = 0x326  # 0xFD 113 i8x16.sub
    opI8x16MinS         = 0x327  # 0xFD 118 i8x16.min_s
    opI8x16MinU         = 0x328  # 0xFD 119 i8x16.min_u
    opI8x16MaxS         = 0x329  # 0xFD 120 i8x16.max_s
    opI8x16MaxU         = 0x32A  # 0xFD 121 i8x16.max_u
    # i16x8 arithmetic
    opI16x8Abs          = 0x32B  # 0xFD 128 i16x8.abs
    opI16x8Neg          = 0x32C  # 0xFD 129 i16x8.neg
    opI16x8Add          = 0x32D  # 0xFD 142 i16x8.add
    opI16x8Sub          = 0x32E  # 0xFD 145 i16x8.sub
    opI16x8Mul          = 0x32F  # 0xFD 149 i16x8.mul
    # i32x4 extensions
    opI32x4Abs          = 0x330  # 0xFD 160 i32x4.abs
    opI32x4Neg          = 0x331  # 0xFD 161 i32x4.neg
    opI32x4Shl          = 0x332  # 0xFD 171 i32x4.shl
    opI32x4ShrS         = 0x333  # 0xFD 172 i32x4.shr_s
    opI32x4ShrU         = 0x334  # 0xFD 173 i32x4.shr_u
    opI32x4MinS         = 0x335  # 0xFD 182 i32x4.min_s
    opI32x4MinU         = 0x336  # 0xFD 183 i32x4.min_u
    opI32x4MaxS         = 0x337  # 0xFD 184 i32x4.max_s
    opI32x4MaxU         = 0x338  # 0xFD 185 i32x4.max_u
    # i64x2 arithmetic
    opI64x2Add          = 0x339  # 0xFD 206 i64x2.add
    opI64x2Sub          = 0x33A  # 0xFD 209 i64x2.sub
    # f32x4 unary
    opF32x4Abs          = 0x33B  # 0xFD 224 f32x4.abs
    opF32x4Neg          = 0x33C  # 0xFD 225 f32x4.neg
    # f64x2 full set
    opF64x2Abs          = 0x33D  # 0xFD 236 f64x2.abs
    opF64x2Neg          = 0x33E  # 0xFD 237 f64x2.neg
    opF64x2Add          = 0x33F  # 0xFD 240 f64x2.add
    opF64x2Sub          = 0x340  # 0xFD 241 f64x2.sub
    opF64x2Mul          = 0x341  # 0xFD 242 f64x2.mul
    opF64x2Div          = 0x342  # 0xFD 243 f64x2.div

    # ---- Tail call proposal ----
    opReturnCall = 0x12         # return_call funcIdx
    opReturnCallIndirect = 0x13 # return_call_indirect typeIdx tableIdx

    # ---- Exception handling proposal ----
    opTryTable = 0x1F    # try_table blocktype catch*
    opThrow = 0x08       # throw tagIdx
    opThrowRef = 0x0A    # throw_ref

  # Memory argument for load/store instructions
  MemArg* = object
    align*: uint32
    offset*: uint32

  # Compact instruction (12 bytes) for fast dispatch
  # Most instructions need at most 2 x uint32 immediates.
  # For i64.const/f64.const, imm1+imm2 store the 64-bit value split across both.
  # For br_table, imm1 = index into external labels table.
  Instr* = object
    op*: Opcode          # 2 bytes
    pad*: uint16         # 2 bytes (available for flags)
    imm1*: uint32        # 4 bytes: local/global/label/func idx, memarg offset, block endOffset, i32/f32 const
    imm2*: uint32        # 4 bytes: memarg align, block elseOffset, table idx, type idx
                         # For i64/f64: imm1 = low 32 bits, imm2 = high 32 bits

  # Auxiliary data for br_table instructions
  BrTableData* = object
    labels*: seq[uint32]
    defaultLabel*: uint32

  # Exception handling: catch clause kinds (WASM exception handling proposal)
  CatchKind* = enum
    ckCatch      = 0  ## catch tagIdx label — push payload, branch
    ckCatchRef   = 1  ## catch_ref tagIdx label — push payload + exnref, branch
    ckCatchAll   = 2  ## catch_all label — no payload, branch
    ckCatchAllRef = 3 ## catch_all_ref label — push exnref, branch

  CatchClause* = object
    kind*:        CatchKind
    tagIdx*:      uint32  ## exception tag index (ckCatch and ckCatchRef only; module-relative)
    labelDepth*:  uint32  ## branch target depth (0 = try_table itself, 1 = enclosing, …)

  # Expression = sequence of compact instructions + auxiliary data
  Expr* = object
    code*: seq[Instr]
    brTables*: seq[BrTableData]        # indexed by imm1 for br_table instructions
    v128Consts*: seq[array[16, byte]]  # indexed by imm1 for opV128Const
    catchTables*: seq[seq[CatchClause]]  # indexed by imm2 for opTryTable
    maxStackDepth*: int32              ## conservative upper bound on operand stack usage

  # Global definition
  GlobalDef* = object
    globalType*: GlobalType
    init*: Expr

  # Element segment
  ElemMode* = enum
    elemPassive
    elemActive
    elemDeclarative

  ElemSegment* = object
    mode*: ElemMode
    tableIdx*: uint32      # for active
    offset*: Expr           # for active
    elemType*: ValType
    init*: seq[Expr]        # init expressions for each element

  # Data segment
  DataMode* = enum
    dataPassive
    dataActive

  DataSegment* = object
    mode*: DataMode
    memIdx*: uint32        # for active
    offset*: Expr           # for active
    data*: seq[byte]

  # Function body
  LocalDecl* = object
    count*: uint32
    valType*: ValType

  FuncBody* = object
    locals*: seq[LocalDecl]
    code*: Expr

  # Complete module
  # Exception tag definition (exception handling proposal, section id=13)
  WasmTagDef* = object
    typeIdx*: uint32  ## function type index (params = thrown value types, results = empty)

  WasmModule* = object
    types*: seq[FuncType]
    imports*: seq[Import]
    funcTypeIdxs*: seq[uint32]  # type indices for functions (not including imports)
    tables*: seq[TableType]
    memories*: seq[MemType]
    globals*: seq[GlobalDef]
    exports*: seq[Export]
    startFunc*: int32           # -1 if no start
    elements*: seq[ElemSegment]
    codes*: seq[FuncBody]
    datas*: seq[DataSegment]
    dataCount*: int32           # -1 if section absent
    customSections*: seq[tuple[name: string, data: seq[byte]]]
    tagDefs*: seq[WasmTagDef]   # exception tags (section 13)

# ---- Runtime value type ----
# Use a flat union for hot-path performance (no variant object overhead)

type
  WasmValueKind* = enum
    wvkI32
    wvkI64
    wvkF32
    wvkF64
    wvkV128
    wvkFuncRef
    wvkExternRef

  WasmValue* = object
    case kind*: WasmValueKind
    of wvkI32:
      i32*: int32
    of wvkI64:
      i64*: int64
    of wvkF32:
      f32*: float32
    of wvkF64:
      f64*: float64
    of wvkV128:
      v128*: array[16, byte]
    of wvkFuncRef:
      funcRef*: int32     # -1 = null
    of wvkExternRef:
      externRef*: int32   # -1 = null

proc wasmI32*(v: int32): WasmValue =
  WasmValue(kind: wvkI32, i32: v)

proc wasmI64*(v: int64): WasmValue =
  WasmValue(kind: wvkI64, i64: v)

proc wasmF32*(v: float32): WasmValue =
  WasmValue(kind: wvkF32, f32: v)

proc wasmF64*(v: float64): WasmValue =
  WasmValue(kind: wvkF64, f64: v)

proc wasmFuncRef*(idx: int32): WasmValue =
  WasmValue(kind: wvkFuncRef, funcRef: idx)

proc wasmExternRef*(idx: int32): WasmValue =
  WasmValue(kind: wvkExternRef, externRef: idx)

proc wasmNullFuncRef*(): WasmValue =
  WasmValue(kind: wvkFuncRef, funcRef: -1)

proc wasmNullExternRef*(): WasmValue =
  WasmValue(kind: wvkExternRef, externRef: -1)

proc toValueKind*(vt: ValType): WasmValueKind =
  case vt
  of vtI32: wvkI32
  of vtI64: wvkI64
  of vtF32: wvkF32
  of vtF64: wvkF64
  of vtV128: wvkV128
  of vtFuncRef: wvkFuncRef
  of vtExternRef: wvkExternRef

proc defaultValue*(vt: ValType): WasmValue =
  case vt
  of vtI32: wasmI32(0)
  of vtI64: wasmI64(0)
  of vtF32: wasmF32(0.0f)
  of vtF64: wasmF64(0.0)
  of vtV128: WasmValue(kind: wvkV128)
  of vtFuncRef: wasmNullFuncRef()
  of vtExternRef: wasmNullExternRef()

proc isNull*(v: WasmValue): bool =
  case v.kind
  of wvkFuncRef: v.funcRef == -1
  of wvkExternRef: v.externRef == -1
  else: false

proc isRefType*(vt: ValType): bool =
  vt in {vtFuncRef, vtExternRef}
