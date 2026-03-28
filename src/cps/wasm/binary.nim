## WebAssembly binary format decoder
## Decodes .wasm binary files into WasmModule objects

import ./types
import std/strutils

type
  WasmDecodeError* = object of CatchableError

  BinaryReader* = object
    data: seq[byte]
    pos: int

# ---- Error helper ----

proc decodeError(msg: string) {.noreturn.} =
  raise newException(WasmDecodeError, msg)

# ---- BinaryReader primitives ----

proc initBinaryReader*(data: openArray[byte]): BinaryReader =
  result.data = @data
  result.pos = 0

proc atEnd*(r: BinaryReader): bool =
  r.pos >= r.data.len

proc remaining*(r: BinaryReader): int =
  r.data.len - r.pos

proc readByte*(r: var BinaryReader): byte =
  if r.pos >= r.data.len:
    decodeError("unexpected end of binary data")
  result = r.data[r.pos]
  inc r.pos

proc readBytes*(r: var BinaryReader, n: int): seq[byte] =
  if r.pos + n > r.data.len:
    decodeError("unexpected end of binary data (need " & $n & " bytes)")
  result = r.data[r.pos ..< r.pos + n]
  r.pos += n

# ---- LEB128 decoding ----

proc readU32*(r: var BinaryReader): uint32 =
  var shift = 0
  result = 0
  while true:
    let b = r.readByte()
    result = result or (uint32(b and 0x7F) shl shift)
    if (b and 0x80) == 0:
      break
    shift += 7
    if shift >= 35:
      decodeError("LEB128 u32 overflow")

proc readS32*(r: var BinaryReader): int32 =
  var shift = 0
  var resultU: uint32 = 0
  var b: byte
  while true:
    b = r.readByte()
    resultU = resultU or (uint32(b and 0x7F) shl shift)
    shift += 7
    if (b and 0x80) == 0:
      break
    if shift >= 35:
      decodeError("LEB128 s32 overflow")
  # Sign extend
  if shift < 32 and (b and 0x40) != 0:
    resultU = resultU or (not uint32(0) shl shift)
  result = cast[int32](resultU)

proc readS64*(r: var BinaryReader): int64 =
  var shift = 0
  var resultU: uint64 = 0
  var b: byte
  while true:
    b = r.readByte()
    resultU = resultU or (uint64(b and 0x7F) shl shift)
    shift += 7
    if (b and 0x80) == 0:
      break
    if shift >= 70:
      decodeError("LEB128 s64 overflow")
  # Sign extend
  if shift < 64 and (b and 0x40) != 0:
    resultU = resultU or (not uint64(0) shl shift)
  result = cast[int64](resultU)

# ---- Additional primitives ----

proc readF32*(r: var BinaryReader): float32 =
  let bytes = r.readBytes(4)
  copyMem(addr result, unsafeAddr bytes[0], 4)

proc readF64*(r: var BinaryReader): float64 =
  let bytes = r.readBytes(8)
  copyMem(addr result, unsafeAddr bytes[0], 8)

proc readName*(r: var BinaryReader): string =
  let length = r.readU32()
  if r.pos + length.int > r.data.len:
    decodeError("name length exceeds available data")
  let bytes = r.readBytes(length.int)
  result = newString(bytes.len)
  if bytes.len > 0:
    copyMem(addr result[0], unsafeAddr bytes[0], bytes.len)

# ---- Type decoders ----

proc readValType*(r: var BinaryReader): ValType =
  let b = r.readByte()
  case b
  of 0x7F: result = vtI32
  of 0x7E: result = vtI64
  of 0x7D: result = vtF32
  of 0x7C: result = vtF64
  of 0x7B: result = vtV128
  of 0x70: result = vtFuncRef
  of 0x6F: result = vtExternRef
  else: decodeError("unknown value type: 0x" & b.toHex(2))

proc readBlockType*(r: var BinaryReader): BlockType =
  # Block type: 0x40 = empty, valtype byte, or s33 type index
  let b = r.data[r.pos]
  if b == 0x40:
    inc r.pos
    return BlockType(kind: btkEmpty)
  # Check if it's a value type
  if b in {0x7F'u8, 0x7E, 0x7D, 0x7C, 0x7B, 0x70, 0x6F}:
    let vt = r.readValType()
    return BlockType(kind: btkValType, valType: vt)
  # Otherwise it's a signed LEB128 type index
  let idx = r.readS32()
  if idx < 0:
    decodeError("invalid block type index: " & $idx)
  return BlockType(kind: btkTypeIdx, typeIdx: uint32(idx))

proc readFuncType*(r: var BinaryReader): FuncType =
  let tag = r.readByte()
  if tag != 0x60:
    decodeError("expected func type tag 0x60, got 0x" & tag.toHex(2))
  let paramCount = r.readU32()
  result.params = newSeqOfCap[ValType](paramCount.int)
  for i in 0 ..< paramCount.int:
    result.params.add(r.readValType())
  let resultCount = r.readU32()
  result.results = newSeqOfCap[ValType](resultCount.int)
  for i in 0 ..< resultCount.int:
    result.results.add(r.readValType())

proc readLimits*(r: var BinaryReader): Limits =
  let flag = r.readByte()
  result.min = r.readU32()
  if (flag and 0x01) != 0:
    result.hasMax = true
    result.max = r.readU32()
  else:
    result.hasMax = false
    result.max = 0

proc readMemType*(r: var BinaryReader): MemType =
  result.limits = r.readLimits()

proc readTableType*(r: var BinaryReader): TableType =
  result.elemType = r.readValType()
  result.limits = r.readLimits()

proc readGlobalType*(r: var BinaryReader): GlobalType =
  result.valType = r.readValType()
  let m = r.readByte()
  case m
  of 0x00: result.mut = mutConst
  of 0x01: result.mut = mutVar
  else: decodeError("invalid mutability flag: 0x" & m.toHex(2))


# ---- Block type encoding for compact Instr pad field ----

proc blockTypeToPad(bt: BlockType): uint16 =
  ## Encode a BlockType into the pad field of a compact Instr.
  ##   pad = 0       → empty block
  ##   pad = 1..7    → valtype block (ValType ordinal mapped to small int)
  ##   pad >= 0x100  → type index block, typeIdx = pad - 0x100
  case bt.kind
  of btkEmpty:
    result = 0
  of btkValType:
    # Map each ValType to a unique small value 1..7
    case bt.valType
    of vtI32:      result = 1
    of vtI64:      result = 2
    of vtF32:      result = 3
    of vtF64:      result = 4
    of vtV128:     result = 5
    of vtFuncRef:  result = 6
    of vtExternRef: result = 7
  of btkTypeIdx:
    result = uint16(0x100) + uint16(bt.typeIdx)

# ---- Instruction decoder ----

proc readMemArg(r: var BinaryReader): tuple[offset: uint32, align: uint32] =
  let align = r.readU32()
  let offset = r.readU32()
  result = (offset: offset, align: align)

proc readExpr*(r: var BinaryReader): Expr =
  ## Decode an expression (sequence of instructions terminated by opEnd).
  ## Does NOT include the terminating end in the result.
  ## Produces compact Instr objects. br_table auxiliary data is stored in
  ## result.brTables, referenced by imm1 index.
  var instrs: seq[Instr] = @[]
  var brTables: seq[BrTableData] = @[]
  var v128Consts: seq[array[16, byte]] = @[]
  var catchTables: seq[seq[CatchClause]] = @[]
  var depth = 0
  while true:
    let b = r.readByte()
    if b == 0x0B'u8: # end
      if depth == 0:
        break
      else:
        dec depth
        instrs.add(Instr(op: opEnd))
        continue

    case b
    of 0x00: # unreachable
      instrs.add(Instr(op: opUnreachable))
    of 0x01: # nop
      instrs.add(Instr(op: opNop))
    of 0x02: # block
      let bt = r.readBlockType()
      inc depth
      instrs.add(Instr(op: opBlock, pad: blockTypeToPad(bt)))
    of 0x03: # loop
      let bt = r.readBlockType()
      inc depth
      instrs.add(Instr(op: opLoop, pad: blockTypeToPad(bt)))
    of 0x04: # if
      let bt = r.readBlockType()
      inc depth
      instrs.add(Instr(op: opIf, pad: blockTypeToPad(bt)))
    of 0x05: # else
      instrs.add(Instr(op: opElse))
    of 0x0C: # br
      let idx = r.readU32()
      instrs.add(Instr(op: opBr, imm1: idx))
    of 0x0D: # br_if
      let idx = r.readU32()
      instrs.add(Instr(op: opBrIf, imm1: idx))
    of 0x0E: # br_table
      let count = r.readU32()
      var labels = newSeqOfCap[uint32](count.int)
      for i in 0 ..< count.int:
        labels.add(r.readU32())
      let defaultLabel = r.readU32()
      let btIdx = uint32(brTables.len)
      brTables.add(BrTableData(labels: labels, defaultLabel: defaultLabel))
      instrs.add(Instr(op: opBrTable, imm1: btIdx))
    of 0x0F: # return
      instrs.add(Instr(op: opReturn))
    of 0x10: # call
      let idx = r.readU32()
      instrs.add(Instr(op: opCall, imm1: idx))
    of 0x11: # call_indirect
      let typeIdx = r.readU32()
      let tableIdx = r.readU32()
      instrs.add(Instr(op: opCallIndirect, imm1: typeIdx, imm2: tableIdx))

    of 0x12: # return_call (tail call proposal)
      let idx = r.readU32()
      instrs.add(Instr(op: opReturnCall, imm1: idx))
    of 0x13: # return_call_indirect (tail call proposal)
      let typeIdx = r.readU32()
      let tableIdx = r.readU32()
      instrs.add(Instr(op: opReturnCallIndirect, imm1: typeIdx, imm2: tableIdx))

    # Exception handling
    of 0x08: # throw tagIdx
      let tagIdx = r.readU32()
      instrs.add(Instr(op: opThrow, imm1: tagIdx))
    of 0x0A: # throw_ref
      instrs.add(Instr(op: opThrowRef))

    of 0x1F: # try_table
      let bt = r.readBlockType()
      let catchCount = r.readU32()
      var clauses: seq[CatchClause]
      for ci in 0 ..< catchCount.int:
        let kind = r.readByte()
        case kind
        of 0x00: # catch tagIdx label
          let tagIdx = r.readU32()
          let lbl    = r.readU32()
          clauses.add(CatchClause(kind: ckCatch, tagIdx: tagIdx, labelDepth: lbl))
        of 0x01: # catch_ref tagIdx label
          let tagIdx = r.readU32()
          let lbl    = r.readU32()
          clauses.add(CatchClause(kind: ckCatchRef, tagIdx: tagIdx, labelDepth: lbl))
        of 0x02: # catch_all label
          let lbl = r.readU32()
          clauses.add(CatchClause(kind: ckCatchAll, labelDepth: lbl))
        of 0x03: # catch_all_ref label
          let lbl = r.readU32()
          clauses.add(CatchClause(kind: ckCatchAllRef, labelDepth: lbl))
        else:
          decodeError("unknown catch kind: " & $kind)
      let catchTableIdx = catchTables.len.uint32
      catchTables.add(clauses)
      inc depth
      instrs.add(Instr(op: opTryTable, pad: blockTypeToPad(bt), imm2: catchTableIdx))

    # Parametric
    of 0x1A: # drop
      instrs.add(Instr(op: opDrop))
    of 0x1B: # select
      instrs.add(Instr(op: opSelect))
    of 0x1C: # select (typed)
      let count = r.readU32()
      for i in 0 ..< count.int:
        discard r.readValType()
      instrs.add(Instr(op: opSelectTyped))

    # Variable
    of 0x20: # local.get
      let idx = r.readU32()
      instrs.add(Instr(op: opLocalGet, imm1: idx))
    of 0x21: # local.set
      let idx = r.readU32()
      instrs.add(Instr(op: opLocalSet, imm1: idx))
    of 0x22: # local.tee
      let idx = r.readU32()
      instrs.add(Instr(op: opLocalTee, imm1: idx))
    of 0x23: # global.get
      let idx = r.readU32()
      instrs.add(Instr(op: opGlobalGet, imm1: idx))
    of 0x24: # global.set
      let idx = r.readU32()
      instrs.add(Instr(op: opGlobalSet, imm1: idx))

    # Table
    of 0x25: # table.get
      let idx = r.readU32()
      instrs.add(Instr(op: opTableGet, imm1: idx))
    of 0x26: # table.set
      let idx = r.readU32()
      instrs.add(Instr(op: opTableSet, imm1: idx))

    # Memory load/store
    of 0x28 .. 0x3E:
      let ma = r.readMemArg()
      let op = case b
        of 0x28: opI32Load
        of 0x29: opI64Load
        of 0x2A: opF32Load
        of 0x2B: opF64Load
        of 0x2C: opI32Load8S
        of 0x2D: opI32Load8U
        of 0x2E: opI32Load16S
        of 0x2F: opI32Load16U
        of 0x30: opI64Load8S
        of 0x31: opI64Load8U
        of 0x32: opI64Load16S
        of 0x33: opI64Load16U
        of 0x34: opI64Load32S
        of 0x35: opI64Load32U
        of 0x36: opI32Store
        of 0x37: opI64Store
        of 0x38: opF32Store
        of 0x39: opF64Store
        of 0x3A: opI32Store8
        of 0x3B: opI32Store16
        of 0x3C: opI64Store8
        of 0x3D: opI64Store16
        of 0x3E: opI64Store32
        else: opI32Load # unreachable
      instrs.add(Instr(op: op, imm1: ma.offset, imm2: ma.align))

    of 0x3F: # memory.size
      let memIdx = r.readByte()
      instrs.add(Instr(op: opMemorySize, imm1: uint32(memIdx)))
    of 0x40: # memory.grow
      let memIdx = r.readByte()
      instrs.add(Instr(op: opMemoryGrow, imm1: uint32(memIdx)))

    # Constants
    of 0x41: # i32.const
      let v = r.readS32()
      instrs.add(Instr(op: opI32Const, imm1: cast[uint32](v)))
    of 0x42: # i64.const
      let v = r.readS64()
      let bits = cast[uint64](v)
      instrs.add(Instr(op: opI64Const,
                        imm1: uint32(bits and 0xFFFFFFFF'u64),
                        imm2: uint32(bits shr 32)))
    of 0x43: # f32.const
      let v = r.readF32()
      instrs.add(Instr(op: opF32Const, imm1: cast[uint32](v)))
    of 0x44: # f64.const
      let v = r.readF64()
      let bits = cast[uint64](v)
      instrs.add(Instr(op: opF64Const,
                        imm1: uint32(bits and 0xFFFFFFFF'u64),
                        imm2: uint32(bits shr 32)))

    # Numeric (no immediates): i32 comparison, i64 comparison,
    # f32 comparison, f64 comparison, i32 arith, i64 arith,
    # f32 arith, f64 arith, conversions, sign extension
    of 0x45 .. 0xC4:
      let op = case b
        of 0x45: opI32Eqz
        of 0x46: opI32Eq
        of 0x47: opI32Ne
        of 0x48: opI32LtS
        of 0x49: opI32LtU
        of 0x4A: opI32GtS
        of 0x4B: opI32GtU
        of 0x4C: opI32LeS
        of 0x4D: opI32LeU
        of 0x4E: opI32GeS
        of 0x4F: opI32GeU
        of 0x50: opI64Eqz
        of 0x51: opI64Eq
        of 0x52: opI64Ne
        of 0x53: opI64LtS
        of 0x54: opI64LtU
        of 0x55: opI64GtS
        of 0x56: opI64GtU
        of 0x57: opI64LeS
        of 0x58: opI64LeU
        of 0x59: opI64GeS
        of 0x5A: opI64GeU
        of 0x5B: opF32Eq
        of 0x5C: opF32Ne
        of 0x5D: opF32Lt
        of 0x5E: opF32Gt
        of 0x5F: opF32Le
        of 0x60: opF32Ge
        of 0x61: opF64Eq
        of 0x62: opF64Ne
        of 0x63: opF64Lt
        of 0x64: opF64Gt
        of 0x65: opF64Le
        of 0x66: opF64Ge
        of 0x67: opI32Clz
        of 0x68: opI32Ctz
        of 0x69: opI32Popcnt
        of 0x6A: opI32Add
        of 0x6B: opI32Sub
        of 0x6C: opI32Mul
        of 0x6D: opI32DivS
        of 0x6E: opI32DivU
        of 0x6F: opI32RemS
        of 0x70: opI32RemU
        of 0x71: opI32And
        of 0x72: opI32Or
        of 0x73: opI32Xor
        of 0x74: opI32Shl
        of 0x75: opI32ShrS
        of 0x76: opI32ShrU
        of 0x77: opI32Rotl
        of 0x78: opI32Rotr
        of 0x79: opI64Clz
        of 0x7A: opI64Ctz
        of 0x7B: opI64Popcnt
        of 0x7C: opI64Add
        of 0x7D: opI64Sub
        of 0x7E: opI64Mul
        of 0x7F: opI64DivS
        of 0x80: opI64DivU
        of 0x81: opI64RemS
        of 0x82: opI64RemU
        of 0x83: opI64And
        of 0x84: opI64Or
        of 0x85: opI64Xor
        of 0x86: opI64Shl
        of 0x87: opI64ShrS
        of 0x88: opI64ShrU
        of 0x89: opI64Rotl
        of 0x8A: opI64Rotr
        of 0x8B: opF32Abs
        of 0x8C: opF32Neg
        of 0x8D: opF32Ceil
        of 0x8E: opF32Floor
        of 0x8F: opF32Trunc
        of 0x90: opF32Nearest
        of 0x91: opF32Sqrt
        of 0x92: opF32Add
        of 0x93: opF32Sub
        of 0x94: opF32Mul
        of 0x95: opF32Div
        of 0x96: opF32Min
        of 0x97: opF32Max
        of 0x98: opF32Copysign
        of 0x99: opF64Abs
        of 0x9A: opF64Neg
        of 0x9B: opF64Ceil
        of 0x9C: opF64Floor
        of 0x9D: opF64Trunc
        of 0x9E: opF64Nearest
        of 0x9F: opF64Sqrt
        of 0xA0: opF64Add
        of 0xA1: opF64Sub
        of 0xA2: opF64Mul
        of 0xA3: opF64Div
        of 0xA4: opF64Min
        of 0xA5: opF64Max
        of 0xA6: opF64Copysign
        of 0xA7: opI32WrapI64
        of 0xA8: opI32TruncF32S
        of 0xA9: opI32TruncF32U
        of 0xAA: opI32TruncF64S
        of 0xAB: opI32TruncF64U
        of 0xAC: opI64ExtendI32S
        of 0xAD: opI64ExtendI32U
        of 0xAE: opI64TruncF32S
        of 0xAF: opI64TruncF32U
        of 0xB0: opI64TruncF64S
        of 0xB1: opI64TruncF64U
        of 0xB2: opF32ConvertI32S
        of 0xB3: opF32ConvertI32U
        of 0xB4: opF32ConvertI64S
        of 0xB5: opF32ConvertI64U
        of 0xB6: opF32DemoteF64
        of 0xB7: opF64ConvertI32S
        of 0xB8: opF64ConvertI32U
        of 0xB9: opF64ConvertI64S
        of 0xBA: opF64ConvertI64U
        of 0xBB: opF64PromoteF32
        of 0xBC: opI32ReinterpretF32
        of 0xBD: opI64ReinterpretF64
        of 0xBE: opF32ReinterpretI32
        of 0xBF: opF64ReinterpretI64
        of 0xC0: opI32Extend8S
        of 0xC1: opI32Extend16S
        of 0xC2: opI64Extend8S
        of 0xC3: opI64Extend16S
        of 0xC4: opI64Extend32S
        else: opNop # unreachable
      instrs.add(Instr(op: op))

    # Reference
    of 0xD0: # ref.null
      let rt = r.readValType()
      instrs.add(Instr(op: opRefNull, imm1: cast[uint32](rt.ord)))
    of 0xD1: # ref.is_null
      instrs.add(Instr(op: opRefIsNull))
    of 0xD2: # ref.func
      let idx = r.readU32()
      instrs.add(Instr(op: opRefFunc, imm1: idx))

    # 0xFC prefix instructions
    of 0xFC:
      let subOp = r.readU32()
      case subOp
      of 0 .. 7: # saturating truncations (no additional immediates)
        let op = case subOp
          of 0: opI32TruncSatF32S
          of 1: opI32TruncSatF32U
          of 2: opI32TruncSatF64S
          of 3: opI32TruncSatF64U
          of 4: opI64TruncSatF32S
          of 5: opI64TruncSatF32U
          of 6: opI64TruncSatF64S
          of 7: opI64TruncSatF64U
          else: opI32TruncSatF32S # unreachable
        instrs.add(Instr(op: op))
      of 8: # memory.init dataIdx memIdx
        let dataIdx = r.readU32()
        let memIdx = r.readByte()
        instrs.add(Instr(op: opMemoryInit, imm1: dataIdx, imm2: uint32(memIdx)))
      of 9: # data.drop dataIdx
        let dataIdx = r.readU32()
        instrs.add(Instr(op: opDataDrop, imm1: dataIdx))
      of 10: # memory.copy dstMem srcMem
        let dstMem = r.readByte()
        let srcMem = r.readByte()
        instrs.add(Instr(op: opMemoryCopy, imm1: uint32(dstMem), imm2: uint32(srcMem)))
      of 11: # memory.fill memIdx
        let memIdx = r.readByte()
        instrs.add(Instr(op: opMemoryFill, imm1: uint32(memIdx)))
      of 12: # table.init elemIdx tableIdx
        let elemIdx = r.readU32()
        let tableIdx = r.readU32()
        instrs.add(Instr(op: opTableInit, imm1: elemIdx, imm2: tableIdx))
      of 13: # elem.drop elemIdx
        let elemIdx = r.readU32()
        instrs.add(Instr(op: opElemDrop, imm1: elemIdx))
      of 14: # table.copy dstTable srcTable
        let dstTable = r.readU32()
        let srcTable = r.readU32()
        instrs.add(Instr(op: opTableCopy, imm1: dstTable, imm2: srcTable))
      of 15: # table.grow tableIdx
        let tableIdx = r.readU32()
        instrs.add(Instr(op: opTableGrow, imm1: tableIdx))
      of 16: # table.size tableIdx
        let tableIdx = r.readU32()
        instrs.add(Instr(op: opTableSize, imm1: tableIdx))
      of 17: # table.fill tableIdx
        let tableIdx = r.readU32()
        instrs.add(Instr(op: opTableFill, imm1: tableIdx))
      else:
        decodeError("unknown 0xFC sub-opcode: " & $subOp)

    # 0xFD prefix: SIMD v128 instructions
    of 0xFD:
      let subOp = r.readU32()
      case subOp
      of 0:  # v128.load memarg
        let al = r.readU32(); let off = r.readU32()
        instrs.add(Instr(op: opV128Load, imm1: al, imm2: off))
      of 11: # v128.store memarg
        let al = r.readU32(); let off = r.readU32()
        instrs.add(Instr(op: opV128Store, imm1: al, imm2: off))
      of 12: # v128.const — 16 literal bytes follow
        var b16: array[16, byte]
        for i in 0..15: b16[i] = r.readByte()
        let idx = v128Consts.len
        v128Consts.add(b16)
        instrs.add(Instr(op: opV128Const, imm1: uint32(idx)))
      of 15: instrs.add(Instr(op: opI8x16Splat))
      of 16: instrs.add(Instr(op: opI16x8Splat))
      of 17: instrs.add(Instr(op: opI32x4Splat))
      of 18: instrs.add(Instr(op: opI64x2Splat))
      of 19: instrs.add(Instr(op: opF32x4Splat))
      of 20: instrs.add(Instr(op: opF64x2Splat))
      of 21: # i8x16.extract_lane_s laneidx
        let lane = r.readByte()
        instrs.add(Instr(op: opI8x16ExtractLaneS, imm1: uint32(lane)))
      of 22: # i8x16.extract_lane_u laneidx
        let lane = r.readByte()
        instrs.add(Instr(op: opI8x16ExtractLaneU, imm1: uint32(lane)))
      of 23: # i8x16.replace_lane laneidx
        let lane = r.readByte()
        instrs.add(Instr(op: opI8x16ReplaceLane, imm1: uint32(lane)))
      of 24: # i16x8.extract_lane_s laneidx
        let lane = r.readByte()
        instrs.add(Instr(op: opI16x8ExtractLaneS, imm1: uint32(lane)))
      of 25: # i16x8.extract_lane_u laneidx
        let lane = r.readByte()
        instrs.add(Instr(op: opI16x8ExtractLaneU, imm1: uint32(lane)))
      of 26: # i16x8.replace_lane laneidx
        let lane = r.readByte()
        instrs.add(Instr(op: opI16x8ReplaceLane, imm1: uint32(lane)))
      of 27: # i32x4.extract_lane laneidx
        let lane = r.readByte()
        instrs.add(Instr(op: opI32x4ExtractLane, imm1: uint32(lane)))
      of 28: # i32x4.replace_lane laneidx
        let lane = r.readByte()
        instrs.add(Instr(op: opI32x4ReplaceLane, imm1: uint32(lane)))
      of 29: # i64x2.extract_lane laneidx
        let lane = r.readByte()
        instrs.add(Instr(op: opI64x2ExtractLane, imm1: uint32(lane)))
      of 30: # i64x2.replace_lane laneidx
        let lane = r.readByte()
        instrs.add(Instr(op: opI64x2ReplaceLane, imm1: uint32(lane)))
      of 31: # f32x4.extract_lane laneidx
        let lane = r.readByte()
        instrs.add(Instr(op: opF32x4ExtractLane, imm1: uint32(lane)))
      of 32: # f32x4.replace_lane laneidx
        let lane = r.readByte()
        instrs.add(Instr(op: opF32x4ReplaceLane, imm1: uint32(lane)))
      of 33: # f64x2.extract_lane laneidx
        let lane = r.readByte()
        instrs.add(Instr(op: opF64x2ExtractLane, imm1: uint32(lane)))
      of 34: # f64x2.replace_lane laneidx
        let lane = r.readByte()
        instrs.add(Instr(op: opF64x2ReplaceLane, imm1: uint32(lane)))
      of 77:  instrs.add(Instr(op: opV128Not))
      of 78:  instrs.add(Instr(op: opV128And))
      of 79:  instrs.add(Instr(op: opV128AndNot))
      of 80:  instrs.add(Instr(op: opV128Or))
      of 81:  instrs.add(Instr(op: opV128Xor))
      # i8x16 arithmetic
      of 96:  instrs.add(Instr(op: opI8x16Abs))
      of 97:  instrs.add(Instr(op: opI8x16Neg))
      of 110: instrs.add(Instr(op: opI8x16Add))
      of 113: instrs.add(Instr(op: opI8x16Sub))
      of 118: instrs.add(Instr(op: opI8x16MinS))
      of 119: instrs.add(Instr(op: opI8x16MinU))
      of 120: instrs.add(Instr(op: opI8x16MaxS))
      of 121: instrs.add(Instr(op: opI8x16MaxU))
      # i16x8 arithmetic
      of 128: instrs.add(Instr(op: opI16x8Abs))
      of 129: instrs.add(Instr(op: opI16x8Neg))
      of 142: instrs.add(Instr(op: opI16x8Add))
      of 145: instrs.add(Instr(op: opI16x8Sub))
      of 149: instrs.add(Instr(op: opI16x8Mul))
      # i32x4 extensions
      of 160: instrs.add(Instr(op: opI32x4Abs))
      of 161: instrs.add(Instr(op: opI32x4Neg))
      of 171: instrs.add(Instr(op: opI32x4Shl))
      of 172: instrs.add(Instr(op: opI32x4ShrS))
      of 173: instrs.add(Instr(op: opI32x4ShrU))
      of 174: instrs.add(Instr(op: opI32x4Add))
      of 177: instrs.add(Instr(op: opI32x4Sub))
      of 181: instrs.add(Instr(op: opI32x4Mul))
      of 182: instrs.add(Instr(op: opI32x4MinS))
      of 183: instrs.add(Instr(op: opI32x4MinU))
      of 184: instrs.add(Instr(op: opI32x4MaxS))
      of 185: instrs.add(Instr(op: opI32x4MaxU))
      # i64x2 arithmetic
      of 206: instrs.add(Instr(op: opI64x2Add))
      of 209: instrs.add(Instr(op: opI64x2Sub))
      # f32x4 unary
      of 224: instrs.add(Instr(op: opF32x4Abs))
      of 225: instrs.add(Instr(op: opF32x4Neg))
      # f32x4 binary (existing)
      of 228: instrs.add(Instr(op: opF32x4Add))
      of 229: instrs.add(Instr(op: opF32x4Sub))
      of 230: instrs.add(Instr(op: opF32x4Mul))
      of 231: instrs.add(Instr(op: opF32x4Div))
      # f64x2 arithmetic
      of 236: instrs.add(Instr(op: opF64x2Abs))
      of 237: instrs.add(Instr(op: opF64x2Neg))
      of 240: instrs.add(Instr(op: opF64x2Add))
      of 241: instrs.add(Instr(op: opF64x2Sub))
      of 242: instrs.add(Instr(op: opF64x2Mul))
      of 243: instrs.add(Instr(op: opF64x2Div))
      else:
        discard  # unimplemented SIMD sub-opcode — skip (JIT will trap)

    else:
      decodeError("unknown opcode: 0x" & b.toHex(2))

  result = Expr(code: instrs, brTables: brTables, v128Consts: v128Consts, catchTables: catchTables)

# ---- Block offset resolution ----

type
  BlockEntry = object
    instrIdx: int
    isIf: bool

proc resolveBlockOffsets*(code: var seq[Instr]) =
  ## Resolve elseOffset and endOffset for block/loop/if instructions.
  ## After resolution (using compact Instr fields):
  ##   - block/loop: imm1 = index of matching end instruction
  ##   - if: imm1 = index of matching end instruction
  ##         imm2 = index of else (or end if no else)
  var stack: seq[BlockEntry] = @[]

  for i in 0 ..< code.len:
    let op = code[i].op
    case op
    of opBlock, opLoop, opTryTable:
      stack.add(BlockEntry(instrIdx: i, isIf: false))
    of opIf:
      stack.add(BlockEntry(instrIdx: i, isIf: true))
    of opElse:
      if stack.len == 0:
        decodeError("else without matching if")
      let top = stack[^1]
      if not top.isIf:
        decodeError("else without matching if")
      # Patch the if's elseOffset (imm2) to point here
      code[top.instrIdx].imm2 = uint32(i)
    of opEnd:
      if stack.len == 0:
        # This is the function-level end, skip
        continue
      let top = stack.pop()
      # Patch endOffset (imm1)
      code[top.instrIdx].imm1 = uint32(i)
      # If this is an if without else, set elseOffset = endOffset
      if top.isIf and code[top.instrIdx].imm2 == 0:
        code[top.instrIdx].imm2 = uint32(i)
    else:
      discard

# ---- Peephole optimizer: fuse common instruction pairs ----

proc peepholeOptimize*(expr: var Expr) =
  ## Fuse common instruction pairs into superinstructions.
  ## This reduces dispatch overhead by ~30% on hot loops.

  # Compute a conservative upper bound on operand stack depth.
  # We model the net stack effect of each standard WASM opcode.
  # Control flow is left at 0 (conservative). Unknown ops default to 0.
  proc stackDelta(op: Opcode): int =
    case op
    # Push 1 (constants, loads from locals/globals/tables)
    of opI32Const, opI64Const, opF32Const, opF64Const, opV128Const,
       opLocalGet, opGlobalGet, opTableGet, opRefFunc, opRefNull,
       opMemorySize, opTableSize:
      1
    # Binary ops: pop 2, push 1 = -1
    of opI32Add, opI32Sub, opI32Mul, opI32DivS, opI32DivU,
       opI32RemS, opI32RemU, opI32And, opI32Or, opI32Xor,
       opI32Shl, opI32ShrS, opI32ShrU, opI32Rotl, opI32Rotr,
       opI32Eq, opI32Ne, opI32LtS, opI32LtU, opI32GtS, opI32GtU,
       opI32LeS, opI32LeU, opI32GeS, opI32GeU,
       opI64Add, opI64Sub, opI64Mul, opI64DivS, opI64DivU,
       opI64RemS, opI64RemU, opI64And, opI64Or, opI64Xor,
       opI64Shl, opI64ShrS, opI64ShrU, opI64Rotl, opI64Rotr,
       opI64Eq, opI64Ne, opI64LtS, opI64LtU, opI64GtS, opI64GtU,
       opI64LeS, opI64LeU, opI64GeS, opI64GeU,
       opF32Add, opF32Sub, opF32Mul, opF32Div, opF32Min, opF32Max, opF32Copysign,
       opF32Eq, opF32Ne, opF32Lt, opF32Gt, opF32Le, opF32Ge,
       opF64Add, opF64Sub, opF64Mul, opF64Div, opF64Min, opF64Max, opF64Copysign,
       opF64Eq, opF64Ne, opF64Lt, opF64Gt, opF64Le, opF64Ge,
       opV128And, opV128Or, opV128Xor, opI32x4Add:
      -1
    # Pop 1, no push: local.set, global.set, drop
    of opLocalSet, opGlobalSet, opDrop:
      -1
    # Memory/table stores: pop addr + val = -2
    of opI32Store, opI64Store, opF32Store, opF64Store,
       opI32Store8, opI32Store16, opI64Store8, opI64Store16, opI64Store32,
       opV128Store, opTableSet:
      -2
    # Select: pop 3, push 1 = -2
    of opSelect, opSelectTyped:
      -2
    # If: pops condition = -1
    of opIf:
      -1
    # Bulk ops: pop 3 operands = -3
    of opMemoryInit, opMemoryCopy, opMemoryFill,
       opTableInit, opTableCopy, opTableFill:
      -3
    # table.grow: pop 2, push 1 = -1
    of opTableGrow:
      -1
    # Everything else: 0 (conservative; includes all unary ops, loads, control)
    else:
      0

  block:
    var depth = 0
    var maxDepth = 0
    for instr in expr.code:
      depth += stackDelta(instr.op)
      if depth < 0: depth = 0
      if depth > maxDepth: maxDepth = depth
    expr.maxStackDepth = maxDepth.int32

  let code = expr.code
  var opt = newSeqOfCap[Instr](code.len)
  var i = 0
  while i < code.len:
    # ---- Quad fusions (check first — consume 4 instructions) ----
    if i + 3 < code.len:
      let a = code[i]
      let b = code[i + 1]
      let c = code[i + 2]
      let d = code[i + 3]
      # local.get X; i32.const C; i32.add; local.set X → local[X] += C
      if a.op == opLocalGet and b.op == opI32Const and c.op == opI32Add and
         d.op == opLocalSet and a.imm1 == d.imm1:
        opt.add(Instr(op: opLocalI32AddInPlace, imm1: a.imm1, imm2: b.imm1))
        i += 4; continue
      # local.get X; i32.const C; i32.sub; local.set X → local[X] -= C
      if a.op == opLocalGet and b.op == opI32Const and c.op == opI32Sub and
         d.op == opLocalSet and a.imm1 == d.imm1:
        opt.add(Instr(op: opLocalI32SubInPlace, imm1: a.imm1, imm2: b.imm1))
        i += 4; continue
      # local.get X; local.get Y; i32.add; local.set Z (X,Y <= 0xFFFF)
      if a.op == opLocalGet and b.op == opLocalGet and c.op == opI32Add and
         d.op == opLocalSet and a.imm1 <= 0xFFFF'u32 and b.imm1 <= 0xFFFF'u32:
        opt.add(Instr(op: opLocalGetLocalGetI32AddLocalSet,
                      imm1: a.imm1 or (b.imm1 shl 16), imm2: d.imm1))
        i += 4; continue
      # local.get X; local.get Y; i32.sub; local.set Z (X,Y <= 0xFFFF)
      if a.op == opLocalGet and b.op == opLocalGet and c.op == opI32Sub and
         d.op == opLocalSet and a.imm1 <= 0xFFFF'u32 and b.imm1 <= 0xFFFF'u32:
        opt.add(Instr(op: opLocalGetLocalGetI32SubLocalSet,
                      imm1: a.imm1 or (b.imm1 shl 16), imm2: d.imm1))
        i += 4; continue
    # ---- Triple fusions (check first, since they consume 3 instructions) ----
    if i + 2 < code.len:
      let a = code[i]
      let b = code[i + 1]
      let c = code[i + 2]
      # local.get X; local.get Y; i32.add → push(local[X] + local[Y])
      if a.op == opLocalGet and b.op == opLocalGet and c.op == opI32Add:
        opt.add(Instr(op: opLocalGetLocalGetI32Add, imm1: a.imm1, imm2: b.imm1))
        i += 3; continue
      # local.get X; local.get Y; i32.sub → push(local[X] - local[Y])
      if a.op == opLocalGet and b.op == opLocalGet and c.op == opI32Sub:
        opt.add(Instr(op: opLocalGetLocalGetI32Sub, imm1: a.imm1, imm2: b.imm1))
        i += 3; continue
      # local.get X; i32.const C; i32.sub → push(local[X] - C)
      if a.op == opLocalGet and b.op == opI32Const and c.op == opI32Sub:
        opt.add(Instr(op: opLocalGetI32ConstI32Sub, imm1: a.imm1, imm2: b.imm1))
        i += 3; continue
      # local.get X; i32.const C; i32.add → push(local[X] + C)
      if a.op == opLocalGet and b.op == opI32Const and c.op == opI32Add:
        opt.add(Instr(op: opLocalGetI32ConstI32Add, imm1: a.imm1, imm2: b.imm1))
        i += 3; continue
      # local.get X; i32.load off; i32.add → push(TOS + mem[local[X]+off])
      if a.op == opLocalGet and b.op == opI32Load and c.op == opI32Add:
        opt.add(Instr(op: opLocalGetI32LoadI32Add, imm1: a.imm1, imm2: b.imm1))
        i += 3; continue
      # i32.const C; i32.eq; br_if L → branch if TOS == C (imm1=C, imm2=L)
      if a.op == opI32Const and b.op == opI32Eq and c.op == opBrIf:
        opt.add(Instr(op: opI32ConstI32EqBrIf, imm1: a.imm1, imm2: c.imm1))
        i += 3; continue
      # i32.const C; i32.ne; br_if L
      if a.op == opI32Const and b.op == opI32Ne and c.op == opBrIf:
        opt.add(Instr(op: opI32ConstI32NeBrIf, imm1: a.imm1, imm2: c.imm1))
        i += 3; continue
      # i32.const C; i32.lt_s; br_if L
      if a.op == opI32Const and b.op == opI32LtS and c.op == opBrIf:
        opt.add(Instr(op: opI32ConstI32LtSBrIf, imm1: a.imm1, imm2: c.imm1))
        i += 3; continue
      # i32.const C; i32.ge_s; br_if L
      if a.op == opI32Const and b.op == opI32GeS and c.op == opBrIf:
        opt.add(Instr(op: opI32ConstI32GeSBrIf, imm1: a.imm1, imm2: c.imm1))
        i += 3; continue
      # i32.const C; i32.gt_u; br_if L
      if a.op == opI32Const and b.op == opI32GtU and c.op == opBrIf:
        opt.add(Instr(op: opI32ConstI32GtUBrIf, imm1: a.imm1, imm2: c.imm1))
        i += 3; continue
      # i32.const C; i32.le_u; br_if L
      if a.op == opI32Const and b.op == opI32LeU and c.op == opBrIf:
        opt.add(Instr(op: opI32ConstI32LeUBrIf, imm1: a.imm1, imm2: c.imm1))
        i += 3; continue
    # ---- Pair fusions ----
    if i + 1 < code.len:
      let a = code[i]
      let b = code[i + 1]
      # local.get X; local.get Y → fused
      if a.op == opLocalGet and b.op == opLocalGet:
        opt.add(Instr(op: opLocalGetLocalGet, imm1: a.imm1, imm2: b.imm1))
        i += 2; continue
      # local.get X; i32.add → fused (stack: ..., val, local[X] → ..., val+local[X])
      if a.op == opLocalGet and b.op == opI32Add:
        opt.add(Instr(op: opLocalGetI32Add, imm1: a.imm1))
        i += 2; continue
      # local.get X; i32.sub → fused
      if a.op == opLocalGet and b.op == opI32Sub:
        opt.add(Instr(op: opLocalGetI32Sub, imm1: a.imm1))
        i += 2; continue
      # i32.const C; i32.add → fused
      if a.op == opI32Const and b.op == opI32Add:
        opt.add(Instr(op: opI32ConstI32Add, imm1: a.imm1))
        i += 2; continue
      # i32.const C; i32.sub → fused
      if a.op == opI32Const and b.op == opI32Sub:
        opt.add(Instr(op: opI32ConstI32Sub, imm1: a.imm1))
        i += 2; continue
      # local.set X; local.get Y → fused
      if a.op == opLocalSet and b.op == opLocalGet:
        opt.add(Instr(op: opLocalSetLocalGet, imm1: a.imm1, imm2: b.imm1))
        i += 2; continue
      # i32.add; local.set X → fused
      if a.op == opI32Add and b.op == opLocalSet:
        opt.add(Instr(op: opI32AddLocalSet, imm1: b.imm1))
        i += 2; continue
      # i32.sub; local.set X → fused
      if a.op == opI32Sub and b.op == opLocalSet:
        opt.add(Instr(op: opI32SubLocalSet, imm1: b.imm1))
        i += 2; continue
      # local.get X; local.tee Y → fused
      if a.op == opLocalGet and b.op == opLocalTee:
        opt.add(Instr(op: opLocalGetLocalTee, imm1: a.imm1, imm2: b.imm1))
        i += 2; continue
      # i32.const C; i32.gt_u → fused
      if a.op == opI32Const and b.op == opI32GtU:
        opt.add(Instr(op: opI32ConstI32GtU, imm1: a.imm1))
        i += 2; continue
      # i32.const C; i32.lt_s → fused
      if a.op == opI32Const and b.op == opI32LtS:
        opt.add(Instr(op: opI32ConstI32LtS, imm1: a.imm1))
        i += 2; continue
      # i32.const C; i32.ge_s → fused
      if a.op == opI32Const and b.op == opI32GeS:
        opt.add(Instr(op: opI32ConstI32GeS, imm1: a.imm1))
        i += 2; continue
      # local.get X; i32.load offset → fused
      if a.op == opLocalGet and b.op == opI32Load:
        opt.add(Instr(op: opLocalGetI32Load, imm1: a.imm1, imm2: b.imm1))
        i += 2; continue
      # i32.const C; i32.eq → fused
      if a.op == opI32Const and b.op == opI32Eq:
        opt.add(Instr(op: opI32ConstI32Eq, imm1: a.imm1))
        i += 2; continue
      # i32.const C; i32.ne → fused
      if a.op == opI32Const and b.op == opI32Ne:
        opt.add(Instr(op: opI32ConstI32Ne, imm1: a.imm1))
        i += 2; continue
      # local.get X; i32.gt_s → fused
      if a.op == opLocalGet and b.op == opI32GtS:
        opt.add(Instr(op: opLocalGetI32GtS, imm1: a.imm1))
        i += 2; continue
      # i32.const C; i32.and → fused
      if a.op == opI32Const and b.op == opI32And:
        opt.add(Instr(op: opI32ConstI32And, imm1: a.imm1))
        i += 2; continue
      # i32.const C; i32.mul → fused
      if a.op == opI32Const and b.op == opI32Mul:
        opt.add(Instr(op: opI32ConstI32Mul, imm1: a.imm1))
        i += 2; continue
      # local.get X; i32.mul → fused
      if a.op == opLocalGet and b.op == opI32Mul:
        opt.add(Instr(op: opLocalGetI32Mul, imm1: a.imm1))
        i += 2; continue
      # ---- Binary comparison + br_if pairs (imm1 = label depth) ----
      if b.op == opBrIf:
        case a.op
        of opI32Eqz: opt.add(Instr(op: opI32EqzBrIf, imm1: b.imm1)); i += 2; continue
        of opI32Eq:  opt.add(Instr(op: opI32EqBrIf,  imm1: b.imm1)); i += 2; continue
        of opI32Ne:  opt.add(Instr(op: opI32NeBrIf,  imm1: b.imm1)); i += 2; continue
        of opI32LtS: opt.add(Instr(op: opI32LtSBrIf, imm1: b.imm1)); i += 2; continue
        of opI32GeS: opt.add(Instr(op: opI32GeSBrIf, imm1: b.imm1)); i += 2; continue
        of opI32GtS: opt.add(Instr(op: opI32GtSBrIf, imm1: b.imm1)); i += 2; continue
        of opI32LeS: opt.add(Instr(op: opI32LeSBrIf, imm1: b.imm1)); i += 2; continue
        of opI32LtU: opt.add(Instr(op: opI32LtUBrIf, imm1: b.imm1)); i += 2; continue
        of opI32GeU: opt.add(Instr(op: opI32GeUBrIf, imm1: b.imm1)); i += 2; continue
        of opI32GtU: opt.add(Instr(op: opI32GtUBrIf, imm1: b.imm1)); i += 2; continue
        of opI32LeU: opt.add(Instr(op: opI32LeUBrIf, imm1: b.imm1)); i += 2; continue
        else: discard
      # local.tee X; br_if L → fused (tee then branch)
      if a.op == opLocalTee and b.op == opBrIf:
        opt.add(Instr(op: opLocalTeeBrIf, imm1: a.imm1, imm2: b.imm1))
        i += 2; continue
      # local.tee X; local.get Y → fused (tee then push another local)
      if a.op == opLocalTee and b.op == opLocalGet:
        opt.add(Instr(op: opLocalTeeLocalGet, imm1: a.imm1, imm2: b.imm1))
        i += 2; continue
      # local.get X; i32.store offset → fused (store local to memory)
      if a.op == opLocalGet and b.op == opI32Store:
        opt.add(Instr(op: opLocalGetI32Store, imm1: a.imm1, imm2: b.imm1))
        i += 2; continue
      # ---- i64 local.get + arithmetic ----
      if a.op == opLocalGet and b.op == opI64Add:
        opt.add(Instr(op: opLocalGetI64Add, imm1: a.imm1))
        i += 2; continue
      if a.op == opLocalGet and b.op == opI64Sub:
        opt.add(Instr(op: opLocalGetI64Sub, imm1: a.imm1))
        i += 2; continue
    opt.add(code[i])
    inc i

  # Reset block offsets before re-resolving (since old absolute indices are stale)
  for j in 0 ..< opt.len:
    if opt[j].op in {opBlock, opLoop, opIf}:
      opt[j].imm1 = 0
      opt[j].imm2 = 0
  expr.code = opt
  resolveBlockOffsets(expr.code)

# ---- Code body decoder (instructions + block resolution) ----

proc readCodeBody(r: var BinaryReader): Expr =
  result = r.readExpr()
  resolveBlockOffsets(result.code)
  peepholeOptimize(result)

# ---- Section decoders ----

proc readTypeSection(r: var BinaryReader, m: var WasmModule) =
  let count = r.readU32()
  m.types = newSeqOfCap[FuncType](count.int)
  for i in 0 ..< count.int:
    m.types.add(r.readFuncType())

proc readImportSection(r: var BinaryReader, m: var WasmModule) =
  let count = r.readU32()
  m.imports = newSeqOfCap[Import](count.int)
  for i in 0 ..< count.int:
    let moduleName = r.readName()
    let name = r.readName()
    let kind = r.readByte()
    case kind
    of 0x00:
      let typeIdx = r.readU32()
      m.imports.add(Import(module: moduleName, name: name,
                           kind: ikFunc, funcTypeIdx: typeIdx))
    of 0x01:
      let tt = r.readTableType()
      m.imports.add(Import(module: moduleName, name: name,
                           kind: ikTable, tableType: tt))
    of 0x02:
      let mt = r.readMemType()
      m.imports.add(Import(module: moduleName, name: name,
                           kind: ikMemory, memType: mt))
    of 0x03:
      let gt = r.readGlobalType()
      m.imports.add(Import(module: moduleName, name: name,
                           kind: ikGlobal, globalType: gt))
    else:
      decodeError("unknown import kind: 0x" & kind.toHex(2))

proc readFunctionSection(r: var BinaryReader, m: var WasmModule) =
  let count = r.readU32()
  m.funcTypeIdxs = newSeqOfCap[uint32](count.int)
  for i in 0 ..< count.int:
    m.funcTypeIdxs.add(r.readU32())

proc readTableSection(r: var BinaryReader, m: var WasmModule) =
  let count = r.readU32()
  m.tables = newSeqOfCap[TableType](count.int)
  for i in 0 ..< count.int:
    m.tables.add(r.readTableType())

proc readMemorySection(r: var BinaryReader, m: var WasmModule) =
  let count = r.readU32()
  m.memories = newSeqOfCap[MemType](count.int)
  for i in 0 ..< count.int:
    m.memories.add(r.readMemType())

proc readGlobalSection(r: var BinaryReader, m: var WasmModule) =
  let count = r.readU32()
  m.globals = newSeqOfCap[GlobalDef](count.int)
  for i in 0 ..< count.int:
    var g: GlobalDef
    g.globalType = r.readGlobalType()
    g.init = r.readExpr()
    m.globals.add(g)

proc readExportSection(r: var BinaryReader, m: var WasmModule) =
  let count = r.readU32()
  m.exports = newSeqOfCap[Export](count.int)
  for i in 0 ..< count.int:
    var e: Export
    e.name = r.readName()
    let kind = r.readByte()
    case kind
    of 0x00: e.kind = ekFunc
    of 0x01: e.kind = ekTable
    of 0x02: e.kind = ekMemory
    of 0x03: e.kind = ekGlobal
    else: decodeError("unknown export kind: 0x" & kind.toHex(2))
    e.idx = r.readU32()
    m.exports.add(e)

proc readStartSection(r: var BinaryReader, m: var WasmModule) =
  m.startFunc = int32(r.readU32())

proc readElementSection(r: var BinaryReader, m: var WasmModule) =
  let count = r.readU32()
  m.elements = newSeqOfCap[ElemSegment](count.int)
  for i in 0 ..< count.int:
    var seg: ElemSegment
    let flags = r.readU32()
    # Element segment encoding uses a 3-bit flags field:
    # bit 0: passive/declarative (1) vs active with implicit table 0 (0)
    # bit 1: has explicit table index (active) or elem kind/type
    # bit 2: elements are expressions (1) vs function indices (0)
    let isPassiveOrDeclarative = (flags and 0x01) != 0
    let hasTableIdxOrElemKind = (flags and 0x02) != 0
    let usesExpressions = (flags and 0x04) != 0

    if isPassiveOrDeclarative:
      if hasTableIdxOrElemKind:
        # flags=3 or flags=7: declarative
        seg.mode = elemDeclarative
      else:
        # flags=1 or flags=5: passive
        seg.mode = elemPassive
      seg.tableIdx = 0
    else:
      # flags=0,2,4,6: active
      seg.mode = elemActive
      if hasTableIdxOrElemKind:
        # flags=2 or flags=6: explicit table index
        seg.tableIdx = r.readU32()
      else:
        # flags=0 or flags=4: implicit table 0
        seg.tableIdx = 0
      # Active segments have an offset expression
      seg.offset = r.readExpr()

    # Read element type / elem kind
    if isPassiveOrDeclarative or hasTableIdxOrElemKind:
      if usesExpressions:
        # Read reftype
        seg.elemType = r.readValType()
      else:
        # Read elemkind (0x00 = funcref)
        let elemKind = r.readByte()
        if elemKind != 0x00:
          decodeError("unknown elemkind: 0x" & elemKind.toHex(2))
        seg.elemType = vtFuncRef
    else:
      # flags=0 or 4: implicit funcref
      seg.elemType = vtFuncRef

    # Read elements
    let elemCount = r.readU32()
    seg.init = newSeqOfCap[Expr](elemCount.int)
    if usesExpressions:
      # Each element is an expression
      for j in 0 ..< elemCount.int:
        seg.init.add(r.readExpr())
    else:
      # Each element is a function index — wrap as ref.func instruction
      for j in 0 ..< elemCount.int:
        let funcIdx = r.readU32()
        var expr: Expr
        expr.code = @[Instr(op: opRefFunc, imm1: funcIdx)]
        seg.init.add(expr)

    m.elements.add(seg)

proc readCodeSection(r: var BinaryReader, m: var WasmModule) =
  let count = r.readU32()
  m.codes = newSeqOfCap[FuncBody](count.int)
  for i in 0 ..< count.int:
    let bodySize = r.readU32()
    let bodyEnd = r.pos + bodySize.int
    var body: FuncBody
    let localDeclCount = r.readU32()
    body.locals = newSeqOfCap[LocalDecl](localDeclCount.int)
    for j in 0 ..< localDeclCount.int:
      var ld: LocalDecl
      ld.count = r.readU32()
      ld.valType = r.readValType()
      body.locals.add(ld)
    body.code = r.readCodeBody()
    # Ensure we consumed exactly the right number of bytes
    if r.pos != bodyEnd:
      decodeError("code body size mismatch: expected pos " & $bodyEnd &
                  ", got " & $r.pos)
    m.codes.add(body)

proc readDataSection(r: var BinaryReader, m: var WasmModule) =
  let count = r.readU32()
  m.datas = newSeqOfCap[DataSegment](count.int)
  for i in 0 ..< count.int:
    var seg: DataSegment
    let flags = r.readU32()
    case flags
    of 0:
      # Active, memory 0, with offset expr
      seg.mode = dataActive
      seg.memIdx = 0
      seg.offset = r.readExpr()
    of 1:
      # Passive
      seg.mode = dataPassive
      seg.memIdx = 0
    of 2:
      # Active, explicit memory index, with offset expr
      seg.mode = dataActive
      seg.memIdx = r.readU32()
      seg.offset = r.readExpr()
    else:
      decodeError("unknown data segment flags: " & $flags)
    let dataLen = r.readU32()
    seg.data = r.readBytes(dataLen.int)
    m.datas.add(seg)

proc readDataCountSection(r: var BinaryReader, m: var WasmModule) =
  m.dataCount = int32(r.readU32())

proc readCustomSection(r: var BinaryReader, m: var WasmModule, sectionSize: int) =
  let startPos = r.pos
  let name = r.readName()
  let consumedByName = r.pos - startPos
  let dataLen = sectionSize - consumedByName
  var data: seq[byte]
  if dataLen > 0:
    data = r.readBytes(dataLen)
  m.customSections.add((name: name, data: data))

# Note: tag section (id=13) for exception handling proposal
proc readTagSection(r: var BinaryReader, m: var WasmModule) =
  let count = r.readU32()
  for i in 0 ..< count.int:
    discard r.readByte()  # attribute (always 0x00 = exception)
    let typeIdx = r.readU32()
    m.tagDefs.add(WasmTagDef(typeIdx: typeIdx))

# ---- Top-level decoder ----

proc decodeModule*(data: openArray[byte]): WasmModule =
  ## Decode a WebAssembly binary module from raw bytes.
  ## Raises WasmDecodeError for malformed input.
  if data.len < 8:
    decodeError("data too short for wasm module header")

  var r = initBinaryReader(data)

  # Validate magic: \0asm
  let magic = r.readBytes(4)
  if magic[0] != 0x00 or magic[1] != 0x61 or
     magic[2] != 0x73 or magic[3] != 0x6D:
    decodeError("invalid wasm magic number")

  # Validate version: 1
  let version = r.readBytes(4)
  if version[0] != 0x01 or version[1] != 0x00 or
     version[2] != 0x00 or version[3] != 0x00:
    decodeError("unsupported wasm version")

  result.startFunc = -1
  result.dataCount = -1

  var lastSectionId: int = -1

  while not r.atEnd():
    let sectionId = r.readByte().int
    let sectionSize = r.readU32().int
    let sectionEnd = r.pos + sectionSize

    # Validate section ordering (custom sections can appear anywhere)
    if sectionId != 0:
      if sectionId <= lastSectionId:
        decodeError("sections out of order: " & $sectionId &
                    " after " & $lastSectionId)
      lastSectionId = sectionId

    case sectionId
    of 0: readCustomSection(r, result, sectionSize)
    of 1: readTypeSection(r, result)
    of 2: readImportSection(r, result)
    of 3: readFunctionSection(r, result)
    of 4: readTableSection(r, result)
    of 5: readMemorySection(r, result)
    of 6: readGlobalSection(r, result)
    of 7: readExportSection(r, result)
    of 8: readStartSection(r, result)
    of 9: readElementSection(r, result)
    of 10: readCodeSection(r, result)
    of 11: readDataSection(r, result)
    of 12: readDataCountSection(r, result)
    of 13: readTagSection(r, result)
    else:
      # Unknown section — skip
      r.pos = sectionEnd

    # Ensure section was fully consumed
    if r.pos != sectionEnd:
      decodeError("section " & $sectionId & " size mismatch: expected pos " &
                  $sectionEnd & ", got " & $r.pos)
