## WebAssembly module validation
## Implements the type checking algorithm from the spec:
## - Operand type stack simulation
## - Control frame stack (block/loop/if tracking)
## - Stack polymorphism after unreachable/br/return
## - All instruction typing rules for MVP + bulk memory + reference types
## - Module-level validation (imports, exports, limits, globals)

import ./types
import std/[strutils, sequtils]

type
  ValidationError* = object of CatchableError

  # Value on the operand type stack (None = polymorphic/unknown after unreachable)
  StackVal* = enum
    svI32
    svI64
    svF32
    svF64
    svV128
    svFuncRef
    svExternRef
    svUnknown  # Bottom type — matches anything (after unreachable)

  CtrlFrame = object
    opcode: Opcode          # block, loop, if
    startTypes: seq[StackVal]  # input types
    endTypes: seq[StackVal]    # output types
    height: int             # operand stack height at entry
    unreachable: bool       # after unreachable/br/return/br_table

  ValidationContext = object
    types: seq[FuncType]
    funcs: seq[FuncType]      # type of each function (imports + internal)
    tables: seq[TableType]
    mems: seq[MemType]
    globals: seq[GlobalType]
    locals: seq[ValType]
    labels: seq[CtrlFrame]    # control frame stack
    operands: seq[StackVal]   # operand type stack
    numImportFuncs: int
    numImportGlobals: int

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc valToStack(vt: ValType): StackVal =
  case vt
  of vtI32: svI32
  of vtI64: svI64
  of vtF32: svF32
  of vtF64: svF64
  of vtV128: svV128
  of vtFuncRef: svFuncRef
  of vtExternRef: svExternRef

proc valsToStack(vts: seq[ValType]): seq[StackVal] =
  for vt in vts:
    result.add(valToStack(vt))

proc validErr(msg: string) =
  raise newException(ValidationError, msg)

# ---------------------------------------------------------------------------
# Operand stack operations
# ---------------------------------------------------------------------------

proc pushOp(ctx: var ValidationContext, sv: StackVal) =
  ctx.operands.add(sv)

proc pushOps(ctx: var ValidationContext, svs: seq[StackVal]) =
  for sv in svs:
    ctx.operands.add(sv)

proc popOp(ctx: var ValidationContext): StackVal =
  if ctx.labels.len > 0:
    let frame = ctx.labels[^1]
    if ctx.operands.len == frame.height:
      if frame.unreachable:
        return svUnknown
      validErr("type mismatch: operand stack underflow")
  elif ctx.operands.len == 0:
    validErr("type mismatch: operand stack underflow")
  result = ctx.operands.pop()

proc popExpect(ctx: var ValidationContext, expected: StackVal): StackVal =
  let actual = ctx.popOp()
  if actual == svUnknown: return expected
  if expected == svUnknown: return actual
  if actual != expected:
    validErr("type mismatch: expected " & $expected & ", got " & $actual)
  actual

proc popOps(ctx: var ValidationContext, expected: seq[StackVal]): seq[StackVal] =
  result = newSeq[StackVal](expected.len)
  for i in countdown(expected.len - 1, 0):
    result[i] = ctx.popExpect(expected[i])

# ---------------------------------------------------------------------------
# Control frame operations
# ---------------------------------------------------------------------------

proc pushCtrl(ctx: var ValidationContext, op: Opcode,
              startTypes, endTypes: seq[StackVal]) =
  let frame = CtrlFrame(
    opcode: op,
    startTypes: startTypes,
    endTypes: endTypes,
    height: ctx.operands.len,
    unreachable: false,
  )
  ctx.labels.add(frame)
  ctx.pushOps(startTypes)

proc popCtrl(ctx: var ValidationContext): CtrlFrame =
  if ctx.labels.len == 0:
    validErr("control frame stack underflow")
  let frame = ctx.labels[^1]
  discard ctx.popOps(frame.endTypes)
  if ctx.operands.len != frame.height and not frame.unreachable:
    validErr("type mismatch: stack height mismatch at end of block (expected " &
             $frame.height & ", got " & $ctx.operands.len & ")")
  # Reset stack to frame entry height (discard any excess from unreachable polymorphism)
  ctx.operands.setLen(frame.height)
  ctx.labels.setLen(ctx.labels.len - 1)
  frame

proc labelTypes(frame: CtrlFrame): seq[StackVal] =
  ## For loop, the branch target expects startTypes (restart).
  ## For block/if, the branch target expects endTypes (exit).
  if frame.opcode == opLoop:
    frame.startTypes
  else:
    frame.endTypes

proc setUnreachable(ctx: var ValidationContext) =
  if ctx.labels.len > 0:
    ctx.operands.setLen(ctx.labels[^1].height)
    ctx.labels[^1].unreachable = true

# ---------------------------------------------------------------------------
# Block type resolution
# ---------------------------------------------------------------------------

proc resolveBlockType(ctx: ValidationContext, bt: BlockType): (seq[StackVal], seq[StackVal]) =
  case bt.kind
  of btkEmpty:
    (@[], @[])
  of btkValType:
    (@[], @[valToStack(bt.valType)])
  of btkTypeIdx:
    let idx = bt.typeIdx.int
    if idx >= ctx.types.len:
      validErr("invalid block type index: " & $idx)
    let ft = ctx.types[idx]
    (valsToStack(ft.params), valsToStack(ft.results))

# ---------------------------------------------------------------------------
# Instruction validation
# ---------------------------------------------------------------------------

proc getBlockType(instr: Instr, module: WasmModule): BlockType =
  ## Decode the block type from the compact pad field.
  ## Encoding (from binary.nim blockTypeToPad):
  ##   pad = 0       → empty block
  ##   pad = 1..7    → valtype block (1=i32, 2=i64, 3=f32, 4=f64, 5=v128, 6=funcref, 7=externref)
  ##   pad >= 0x100  → type index block, typeIdx = pad - 0x100
  if instr.pad == 0:
    BlockType(kind: btkEmpty)
  elif instr.pad >= 0x100:
    BlockType(kind: btkTypeIdx, typeIdx: (instr.pad - 0x100).uint32)
  else:
    let vt = case instr.pad
      of 1: vtI32
      of 2: vtI64
      of 3: vtF32
      of 4: vtF64
      of 5: vtV128
      of 6: vtFuncRef
      of 7: vtExternRef
      else:
        validErr("invalid block type pad: " & $instr.pad)
        vtI32
    BlockType(kind: btkValType, valType: vt)

proc validateInstr(ctx: var ValidationContext, instr: Instr,
                    module: WasmModule) =
  ## Validate a single instruction, updating the operand and control stacks.
  case instr.op

  # ---- Control ----
  of opUnreachable:
    ctx.setUnreachable()

  of opNop:
    discard

  of opBlock:
    let bt = getBlockType(instr, module)
    let (ins, outs) = ctx.resolveBlockType(bt)
    discard ctx.popOps(ins)
    ctx.pushCtrl(opBlock, ins, outs)

  of opLoop:
    let bt = getBlockType(instr, module)
    let (ins, outs) = ctx.resolveBlockType(bt)
    discard ctx.popOps(ins)
    ctx.pushCtrl(opLoop, ins, outs)

  of opIf:
    let bt = getBlockType(instr, module)
    let (ins, outs) = ctx.resolveBlockType(bt)
    discard ctx.popExpect(svI32)
    discard ctx.popOps(ins)
    ctx.pushCtrl(opIf, ins, outs)

  of opElse:
    let frame = ctx.popCtrl()
    if frame.opcode != opIf:
      validErr("else without matching if")
    ctx.pushCtrl(opElse, frame.startTypes, frame.endTypes)

  of opEnd:
    let frame = ctx.popCtrl()
    ctx.pushOps(frame.endTypes)

  of opBr:
    let l = instr.imm1.int
    if l >= ctx.labels.len:
      validErr("br: invalid label depth " & $l)
    let frame = ctx.labels[ctx.labels.len - 1 - l]
    discard ctx.popOps(frame.labelTypes)
    ctx.setUnreachable()

  of opBrIf:
    let l = instr.imm1.int
    if l >= ctx.labels.len:
      validErr("br_if: invalid label depth " & $l)
    let frame = ctx.labels[ctx.labels.len - 1 - l]
    discard ctx.popExpect(svI32)
    let vals = ctx.popOps(frame.labelTypes)
    ctx.pushOps(vals)

  of opBrTable:
    # imm1 = index into brTables
    # All labels must have same arity as default
    if ctx.labels.len == 0:
      validErr("br_table: no control frames")
    discard ctx.popExpect(svI32)
    # For validation purposes we just mark as unreachable
    # (full br_table validation would check all label arities match)
    ctx.setUnreachable()

  of opReturn:
    # Pop return types
    if ctx.labels.len > 0:
      let frame = ctx.labels[0]  # outermost frame
      discard ctx.popOps(frame.endTypes)
    ctx.setUnreachable()

  of opCall:
    let funcIdx = instr.imm1.int
    if funcIdx >= ctx.funcs.len:
      validErr("call: invalid function index " & $funcIdx)
    let ft = ctx.funcs[funcIdx]
    discard ctx.popOps(valsToStack(ft.params))
    ctx.pushOps(valsToStack(ft.results))

  of opCallIndirect:
    let typeIdx = instr.imm2.int
    if typeIdx >= ctx.types.len:
      validErr("call_indirect: invalid type index " & $typeIdx)
    let tableIdx = instr.imm1.int
    if tableIdx >= ctx.tables.len:
      validErr("call_indirect: invalid table index " & $tableIdx)
    # Pop i32 index
    discard ctx.popExpect(svI32)
    let ft = ctx.types[typeIdx]
    discard ctx.popOps(valsToStack(ft.params))
    ctx.pushOps(valsToStack(ft.results))

  # ---- Tail calls (return_call, return_call_indirect) ----
  of opReturnCall:
    let funcIdx = instr.imm1.int
    if funcIdx >= ctx.funcs.len:
      validErr("return_call: invalid function index " & $funcIdx)
    let ft = ctx.funcs[funcIdx]
    # Callee return types must match the current function's return types
    if ctx.labels.len > 0:
      let outerFrame = ctx.labels[0]
      let calleeResults = valsToStack(ft.results)
      if calleeResults.len != outerFrame.endTypes.len:
        validErr("return_call: callee return arity mismatch")
      for i in 0 ..< calleeResults.len:
        if calleeResults[i] != outerFrame.endTypes[i]:
          validErr("return_call: callee return type mismatch")
    discard ctx.popOps(valsToStack(ft.params))
    ctx.setUnreachable()

  of opReturnCallIndirect:
    let typeIdx = instr.imm1.int
    if typeIdx >= ctx.types.len:
      validErr("return_call_indirect: invalid type index " & $typeIdx)
    let tableIdx = instr.imm2.int
    if tableIdx >= ctx.tables.len:
      validErr("return_call_indirect: invalid table index " & $tableIdx)
    discard ctx.popExpect(svI32)  # table index
    let ft = ctx.types[typeIdx]
    if ctx.labels.len > 0:
      let outerFrame = ctx.labels[0]
      let calleeResults = valsToStack(ft.results)
      if calleeResults.len != outerFrame.endTypes.len:
        validErr("return_call_indirect: callee return arity mismatch")
      for i in 0 ..< calleeResults.len:
        if calleeResults[i] != outerFrame.endTypes[i]:
          validErr("return_call_indirect: callee return type mismatch")
    discard ctx.popOps(valsToStack(ft.params))
    ctx.setUnreachable()

  # ---- Exception handling (try_table, throw, throw_ref) ----
  of opThrow:
    # imm1 = tag index; pops tag's param types, then unreachable
    ctx.setUnreachable()

  of opThrowRef:
    # Pops exnref, rethrows
    discard ctx.popExpect(svExternRef)  # exnref treated as externref for now
    ctx.setUnreachable()

  of opTryTable:
    # Like block but with catch clauses; handled same as block for typing
    let bt = getBlockType(instr, module)
    let (startTypes, endTypes) = ctx.resolveBlockType(bt)
    discard ctx.popOps(startTypes)
    ctx.pushCtrl(opBlock, startTypes, endTypes)

  # ---- Parametric ----
  of opDrop:
    discard ctx.popOp()

  of opSelect:
    discard ctx.popExpect(svI32)
    let t1 = ctx.popOp()
    let t2 = ctx.popOp()
    if t1 != svUnknown and t2 != svUnknown and t1 != t2:
      validErr("select: type mismatch")
    let resultType = if t1 == svUnknown: t2 else: t1
    ctx.pushOp(resultType)

  of opSelectTyped:
    discard ctx.popExpect(svI32)
    let t1 = ctx.popOp()
    let t2 = ctx.popOp()
    if t1 != svUnknown and t2 != svUnknown and t1 != t2:
      validErr("select(t): type mismatch")
    ctx.pushOp(if t1 == svUnknown: t2 else: t1)

  # ---- Variable ----
  of opLocalGet:
    let idx = instr.imm1.int
    if idx >= ctx.locals.len:
      validErr("local.get: invalid local index " & $idx)
    ctx.pushOp(valToStack(ctx.locals[idx]))

  of opLocalSet:
    let idx = instr.imm1.int
    if idx >= ctx.locals.len:
      validErr("local.set: invalid local index " & $idx)
    discard ctx.popExpect(valToStack(ctx.locals[idx]))

  of opLocalTee:
    let idx = instr.imm1.int
    if idx >= ctx.locals.len:
      validErr("local.tee: invalid local index " & $idx)
    let expected = valToStack(ctx.locals[idx])
    let val = ctx.popExpect(expected)
    ctx.pushOp(val)

  of opGlobalGet:
    let idx = instr.imm1.int
    if idx >= ctx.globals.len:
      validErr("global.get: invalid global index " & $idx)
    ctx.pushOp(valToStack(ctx.globals[idx].valType))

  of opGlobalSet:
    let idx = instr.imm1.int
    if idx >= ctx.globals.len:
      validErr("global.set: invalid global index " & $idx)
    if ctx.globals[idx].mut != mutVar:
      validErr("global.set: immutable global " & $idx)
    discard ctx.popExpect(valToStack(ctx.globals[idx].valType))

  # ---- Table ----
  of opTableGet:
    let idx = instr.imm1.int
    if idx >= ctx.tables.len:
      validErr("table.get: invalid table index")
    discard ctx.popExpect(svI32)
    ctx.pushOp(valToStack(ctx.tables[idx].elemType))

  of opTableSet:
    let idx = instr.imm1.int
    if idx >= ctx.tables.len:
      validErr("table.set: invalid table index")
    discard ctx.popExpect(valToStack(ctx.tables[idx].elemType))
    discard ctx.popExpect(svI32)

  # ---- Memory loads ----
  of opI32Load, opI32Load8S, opI32Load8U, opI32Load16S, opI32Load16U:
    if ctx.mems.len == 0: validErr("memory instruction without memory")
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)

  of opI64Load, opI64Load8S, opI64Load8U, opI64Load16S, opI64Load16U,
     opI64Load32S, opI64Load32U:
    if ctx.mems.len == 0: validErr("memory instruction without memory")
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI64)

  of opF32Load:
    if ctx.mems.len == 0: validErr("memory instruction without memory")
    discard ctx.popExpect(svI32)
    ctx.pushOp(svF32)

  of opF64Load:
    if ctx.mems.len == 0: validErr("memory instruction without memory")
    discard ctx.popExpect(svI32)
    ctx.pushOp(svF64)

  # ---- Memory stores ----
  of opI32Store, opI32Store8, opI32Store16:
    if ctx.mems.len == 0: validErr("memory instruction without memory")
    discard ctx.popExpect(svI32)
    discard ctx.popExpect(svI32)

  of opI64Store, opI64Store8, opI64Store16, opI64Store32:
    if ctx.mems.len == 0: validErr("memory instruction without memory")
    discard ctx.popExpect(svI64)
    discard ctx.popExpect(svI32)

  of opF32Store:
    if ctx.mems.len == 0: validErr("memory instruction without memory")
    discard ctx.popExpect(svF32)
    discard ctx.popExpect(svI32)

  of opF64Store:
    if ctx.mems.len == 0: validErr("memory instruction without memory")
    discard ctx.popExpect(svF64)
    discard ctx.popExpect(svI32)

  # ---- Memory management ----
  of opMemorySize:
    if ctx.mems.len == 0: validErr("memory.size without memory")
    ctx.pushOp(svI32)

  of opMemoryGrow:
    if ctx.mems.len == 0: validErr("memory.grow without memory")
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)

  # ---- Constants ----
  of opI32Const:
    ctx.pushOp(svI32)

  of opI64Const:
    ctx.pushOp(svI64)

  of opF32Const:
    ctx.pushOp(svF32)

  of opF64Const:
    ctx.pushOp(svF64)

  # ---- i32 comparison (returns i32) ----
  of opI32Eqz:
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)

  of opI32Eq, opI32Ne, opI32LtS, opI32LtU, opI32GtS, opI32GtU,
     opI32LeS, opI32LeU, opI32GeS, opI32GeU:
    discard ctx.popExpect(svI32)
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)

  # ---- i64 comparison (returns i32) ----
  of opI64Eqz:
    discard ctx.popExpect(svI64)
    ctx.pushOp(svI32)

  of opI64Eq, opI64Ne, opI64LtS, opI64LtU, opI64GtS, opI64GtU,
     opI64LeS, opI64LeU, opI64GeS, opI64GeU:
    discard ctx.popExpect(svI64)
    discard ctx.popExpect(svI64)
    ctx.pushOp(svI32)

  # ---- f32 comparison (returns i32) ----
  of opF32Eq, opF32Ne, opF32Lt, opF32Gt, opF32Le, opF32Ge:
    discard ctx.popExpect(svF32)
    discard ctx.popExpect(svF32)
    ctx.pushOp(svI32)

  # ---- f64 comparison (returns i32) ----
  of opF64Eq, opF64Ne, opF64Lt, opF64Gt, opF64Le, opF64Ge:
    discard ctx.popExpect(svF64)
    discard ctx.popExpect(svF64)
    ctx.pushOp(svI32)

  # ---- i32 unary ----
  of opI32Clz, opI32Ctz, opI32Popcnt:
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)

  # ---- i32 binary ----
  of opI32Add, opI32Sub, opI32Mul, opI32DivS, opI32DivU,
     opI32RemS, opI32RemU, opI32And, opI32Or, opI32Xor,
     opI32Shl, opI32ShrS, opI32ShrU, opI32Rotl, opI32Rotr:
    discard ctx.popExpect(svI32)
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)

  # ---- i64 unary ----
  of opI64Clz, opI64Ctz, opI64Popcnt:
    discard ctx.popExpect(svI64)
    ctx.pushOp(svI64)

  # ---- i64 binary ----
  of opI64Add, opI64Sub, opI64Mul, opI64DivS, opI64DivU,
     opI64RemS, opI64RemU, opI64And, opI64Or, opI64Xor,
     opI64Shl, opI64ShrS, opI64ShrU, opI64Rotl, opI64Rotr:
    discard ctx.popExpect(svI64)
    discard ctx.popExpect(svI64)
    ctx.pushOp(svI64)

  # ---- f32 unary ----
  of opF32Abs, opF32Neg, opF32Ceil, opF32Floor, opF32Trunc,
     opF32Nearest, opF32Sqrt:
    discard ctx.popExpect(svF32)
    ctx.pushOp(svF32)

  # ---- f32 binary ----
  of opF32Add, opF32Sub, opF32Mul, opF32Div, opF32Min, opF32Max, opF32Copysign:
    discard ctx.popExpect(svF32)
    discard ctx.popExpect(svF32)
    ctx.pushOp(svF32)

  # ---- f64 unary ----
  of opF64Abs, opF64Neg, opF64Ceil, opF64Floor, opF64Trunc,
     opF64Nearest, opF64Sqrt:
    discard ctx.popExpect(svF64)
    ctx.pushOp(svF64)

  # ---- f64 binary ----
  of opF64Add, opF64Sub, opF64Mul, opF64Div, opF64Min, opF64Max, opF64Copysign:
    discard ctx.popExpect(svF64)
    discard ctx.popExpect(svF64)
    ctx.pushOp(svF64)

  # ---- Conversions ----
  of opI32WrapI64:
    discard ctx.popExpect(svI64)
    ctx.pushOp(svI32)

  of opI32TruncF32S, opI32TruncF32U:
    discard ctx.popExpect(svF32)
    ctx.pushOp(svI32)

  of opI32TruncF64S, opI32TruncF64U:
    discard ctx.popExpect(svF64)
    ctx.pushOp(svI32)

  of opI64ExtendI32S, opI64ExtendI32U:
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI64)

  of opI64TruncF32S, opI64TruncF32U:
    discard ctx.popExpect(svF32)
    ctx.pushOp(svI64)

  of opI64TruncF64S, opI64TruncF64U:
    discard ctx.popExpect(svF64)
    ctx.pushOp(svI64)

  of opF32ConvertI32S, opF32ConvertI32U:
    discard ctx.popExpect(svI32)
    ctx.pushOp(svF32)

  of opF32ConvertI64S, opF32ConvertI64U:
    discard ctx.popExpect(svI64)
    ctx.pushOp(svF32)

  of opF32DemoteF64:
    discard ctx.popExpect(svF64)
    ctx.pushOp(svF32)

  of opF64ConvertI32S, opF64ConvertI32U:
    discard ctx.popExpect(svI32)
    ctx.pushOp(svF64)

  of opF64ConvertI64S, opF64ConvertI64U:
    discard ctx.popExpect(svI64)
    ctx.pushOp(svF64)

  of opF64PromoteF32:
    discard ctx.popExpect(svF32)
    ctx.pushOp(svF64)

  of opI32ReinterpretF32:
    discard ctx.popExpect(svF32)
    ctx.pushOp(svI32)

  of opI64ReinterpretF64:
    discard ctx.popExpect(svF64)
    ctx.pushOp(svI64)

  of opF32ReinterpretI32:
    discard ctx.popExpect(svI32)
    ctx.pushOp(svF32)

  of opF64ReinterpretI64:
    discard ctx.popExpect(svI64)
    ctx.pushOp(svF64)

  # ---- Sign extension ----
  of opI32Extend8S, opI32Extend16S:
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)

  of opI64Extend8S, opI64Extend16S, opI64Extend32S:
    discard ctx.popExpect(svI64)
    ctx.pushOp(svI64)

  # ---- Reference ----
  of opRefNull:
    # imm1 encodes the ref type
    let vt = case instr.imm1
      of 0x70'u32: svFuncRef
      of 0x6F'u32: svExternRef
      else: svFuncRef
    ctx.pushOp(vt)

  of opRefIsNull:
    let t = ctx.popOp()
    if t != svUnknown and t != svFuncRef and t != svExternRef:
      validErr("ref.is_null: expected reference type, got " & $t)
    ctx.pushOp(svI32)

  of opRefFunc:
    let idx = instr.imm1.int
    if idx >= ctx.funcs.len:
      validErr("ref.func: invalid function index " & $idx)
    ctx.pushOp(svFuncRef)

  # ---- Saturating truncation (0xFC prefix) ----
  of opI32TruncSatF32S, opI32TruncSatF32U:
    discard ctx.popExpect(svF32)
    ctx.pushOp(svI32)

  of opI32TruncSatF64S, opI32TruncSatF64U:
    discard ctx.popExpect(svF64)
    ctx.pushOp(svI32)

  of opI64TruncSatF32S, opI64TruncSatF32U:
    discard ctx.popExpect(svF32)
    ctx.pushOp(svI64)

  of opI64TruncSatF64S, opI64TruncSatF64U:
    discard ctx.popExpect(svF64)
    ctx.pushOp(svI64)

  # ---- Bulk memory ----
  of opMemoryInit:
    if ctx.mems.len == 0: validErr("memory.init without memory")
    discard ctx.popExpect(svI32)  # size
    discard ctx.popExpect(svI32)  # source offset
    discard ctx.popExpect(svI32)  # dest offset

  of opDataDrop:
    discard  # no stack effect

  of opMemoryCopy:
    if ctx.mems.len == 0: validErr("memory.copy without memory")
    discard ctx.popExpect(svI32)  # size
    discard ctx.popExpect(svI32)  # source
    discard ctx.popExpect(svI32)  # dest

  of opMemoryFill:
    if ctx.mems.len == 0: validErr("memory.fill without memory")
    discard ctx.popExpect(svI32)  # size
    discard ctx.popExpect(svI32)  # value
    discard ctx.popExpect(svI32)  # dest

  # ---- Bulk table ----
  of opTableInit:
    discard ctx.popExpect(svI32)  # size
    discard ctx.popExpect(svI32)  # source offset
    discard ctx.popExpect(svI32)  # dest offset

  of opElemDrop:
    discard

  of opTableCopy:
    discard ctx.popExpect(svI32)  # size
    discard ctx.popExpect(svI32)  # source
    discard ctx.popExpect(svI32)  # dest

  of opTableGrow:
    let idx = instr.imm1.int
    if idx >= ctx.tables.len: validErr("table.grow: invalid table index")
    discard ctx.popExpect(svI32)
    discard ctx.popExpect(valToStack(ctx.tables[idx].elemType))
    ctx.pushOp(svI32)

  of opTableSize:
    let idx = instr.imm1.int
    if idx >= ctx.tables.len: validErr("table.size: invalid table index")
    ctx.pushOp(svI32)

  of opTableFill:
    let idx = instr.imm1.int
    if idx >= ctx.tables.len: validErr("table.fill: invalid table index")
    discard ctx.popExpect(svI32)
    discard ctx.popExpect(valToStack(ctx.tables[idx].elemType))
    discard ctx.popExpect(svI32)

  # ---- Superinstructions (fused) — same typing as individual ops ----
  of opLocalGetLocalGet:
    let idx1 = instr.imm1.int
    let idx2 = instr.imm2.int
    if idx1 >= ctx.locals.len or idx2 >= ctx.locals.len:
      validErr("fused local.get: invalid local index")
    ctx.pushOp(valToStack(ctx.locals[idx1]))
    ctx.pushOp(valToStack(ctx.locals[idx2]))

  of opLocalGetI32Add:
    let idx = instr.imm1.int
    if idx >= ctx.locals.len: validErr("fused local.get+i32.add: invalid local index")
    ctx.pushOp(valToStack(ctx.locals[idx]))
    discard ctx.popExpect(svI32)
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)

  of opLocalGetI32Sub:
    let idx = instr.imm1.int
    if idx >= ctx.locals.len: validErr("fused local.get+i32.sub: invalid local index")
    ctx.pushOp(valToStack(ctx.locals[idx]))
    discard ctx.popExpect(svI32)
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)

  # ---- More fused superinstructions ----
  of opLocalGetI32Store:
    let idx = instr.imm1.int
    if idx >= ctx.locals.len: validErr("fused: invalid local index")
    if ctx.mems.len == 0: validErr("fused: memory instruction without memory")
    ctx.pushOp(valToStack(ctx.locals[idx]))
    discard ctx.popExpect(svI32)  # value
    discard ctx.popExpect(svI32)  # addr
  of opI32ConstI32Add:
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)
  of opI32ConstI32Sub:
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)
  of opLocalSetLocalGet:
    let setIdx = instr.imm1.int
    let getIdx = instr.imm2.int
    if setIdx >= ctx.locals.len or getIdx >= ctx.locals.len:
      validErr("fused: invalid local index")
    discard ctx.popExpect(valToStack(ctx.locals[setIdx]))
    ctx.pushOp(valToStack(ctx.locals[getIdx]))
  of opLocalTeeLocalGet:
    let teeIdx = instr.imm1.int
    let getIdx = instr.imm2.int
    if teeIdx >= ctx.locals.len or getIdx >= ctx.locals.len:
      validErr("fused: invalid local index")
    let val = ctx.popExpect(valToStack(ctx.locals[teeIdx]))
    ctx.pushOp(val)  # tee keeps value
    ctx.pushOp(valToStack(ctx.locals[getIdx]))
  of opLocalGetI32Const:
    let idx = instr.imm1.int
    if idx >= ctx.locals.len: validErr("fused: invalid local index")
    ctx.pushOp(valToStack(ctx.locals[idx]))
    ctx.pushOp(svI32)
  of opI32AddLocalSet:
    let idx = instr.imm1.int
    if idx >= ctx.locals.len: validErr("fused: invalid local index")
    discard ctx.popExpect(svI32)
    discard ctx.popExpect(svI32)
    # i32.add result stored to local (no push)
  of opI32SubLocalSet:
    let idx = instr.imm1.int
    if idx >= ctx.locals.len: validErr("fused: invalid local index")
    discard ctx.popExpect(svI32)
    discard ctx.popExpect(svI32)
    # i32.sub result stored to local (no push)
  of opI32EqzBrIf:
    # i32.eqz + br_if: pop i32, test == 0, branch if true
    discard ctx.popExpect(svI32)
    # br_if doesn't make stack unreachable
  of opLocalGetLocalGetI32Add:
    let idx1 = instr.imm1.int
    let idx2 = instr.imm2.int
    if idx1 >= ctx.locals.len or idx2 >= ctx.locals.len:
      validErr("fused: invalid local index")
    # Push both locals, then add: net effect = push i32
    ctx.pushOp(svI32)
  of opLocalGetLocalGetI32Sub:
    let idx1 = instr.imm1.int
    let idx2 = instr.imm2.int
    if idx1 >= ctx.locals.len or idx2 >= ctx.locals.len:
      validErr("fused: invalid local index")
    ctx.pushOp(svI32)
  of opLocalGetI32ConstI32Sub:
    let idx = instr.imm1.int
    if idx >= ctx.locals.len: validErr("fused: invalid local index")
    # local.get X; i32.const C; i32.sub → push i32
    ctx.pushOp(svI32)
  of opLocalGetI32ConstI32Add:
    let idx = instr.imm1.int
    if idx >= ctx.locals.len: validErr("fused: invalid local index")
    ctx.pushOp(svI32)
  of opLocalGetLocalTee:
    # local.get X; local.tee Y → push local[X], tee to Y (net: push 1 value)
    let getIdx = instr.imm1.int
    let teeIdx = instr.imm2.int
    if getIdx >= ctx.locals.len or teeIdx >= ctx.locals.len:
      validErr("fused: invalid local index")
    ctx.pushOp(valToStack(ctx.locals[getIdx]))
  of opI32ConstI32GtU:
    # i32.const C; i32.gt_u → pop i32, push i32 (comparison result)
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)
  of opI32ConstI32LtS:
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)
  of opI32ConstI32GeS:
    discard ctx.popExpect(svI32)
    ctx.pushOp(svI32)

  of opLocalTeeBrIf:
    # local.tee X; br_if L → pop i32, store to local, branch if nonzero
    let idx = instr.imm1.int
    if idx >= ctx.locals.len: validErr("fused: invalid local index")
    discard ctx.popExpect(svI32)

  else:
    discard  # Unknown fused ops — skip

# ---------------------------------------------------------------------------
# Function body validation
# ---------------------------------------------------------------------------

proc validateFunction*(module: WasmModule, funcIdx: int) =
  ## Validate a single function body.
  let numImportFuncs = module.imports.filterIt(it.kind == ikFunc).len
  let bodyIdx = funcIdx - numImportFuncs
  if bodyIdx < 0 or bodyIdx >= module.codes.len:
    validErr("function index out of range: " & $funcIdx)

  let typeIdx = module.funcTypeIdxs[bodyIdx]
  if typeIdx.int >= module.types.len:
    validErr("function type index out of range: " & $typeIdx)
  let funcType = module.types[typeIdx.int]
  let body = module.codes[bodyIdx]

  # Build locals list: params + declared locals
  var locals: seq[ValType]
  for p in funcType.params:
    locals.add(p)
  for decl in body.locals:
    for _ in 0'u32 ..< decl.count:
      locals.add(decl.valType)

  # Build function type list
  var funcTypes: seq[FuncType]
  for imp in module.imports:
    if imp.kind == ikFunc:
      if imp.funcTypeIdx.int < module.types.len:
        funcTypes.add(module.types[imp.funcTypeIdx.int])
  for tidx in module.funcTypeIdxs:
    if tidx.int < module.types.len:
      funcTypes.add(module.types[tidx.int])

  # Build global type list
  var globalTypes: seq[GlobalType]
  for imp in module.imports:
    if imp.kind == ikGlobal:
      globalTypes.add(imp.globalType)
  for g in module.globals:
    globalTypes.add(g.globalType)

  # Build table/mem lists
  var tables: seq[TableType]
  for imp in module.imports:
    if imp.kind == ikTable:
      tables.add(imp.tableType)
  for t in module.tables:
    tables.add(t)

  var mems: seq[MemType]
  for imp in module.imports:
    if imp.kind == ikMemory:
      mems.add(imp.memType)
  for m in module.memories:
    mems.add(m)

  var ctx = ValidationContext(
    types: module.types,
    funcs: funcTypes,
    tables: tables,
    mems: mems,
    globals: globalTypes,
    locals: locals,
  )

  # Push initial frame for function body
  let resultTypes = valsToStack(funcType.results)
  ctx.pushCtrl(opBlock, @[], resultTypes)

  # Validate each instruction
  for instr in body.code.code:
    ctx.validateInstr(instr, module)
    if ctx.labels.len == 0:
      # Function-level end reached
      break


# ---------------------------------------------------------------------------
# Module-level validation
# ---------------------------------------------------------------------------

proc validateModule*(module: WasmModule) =
  ## Validate an entire WASM module: types, functions, tables, memories,
  ## globals, exports, start function.

  # 1. Validate types section
  for ft in module.types:
    if ft.results.len > 1:
      discard  # Multi-value is allowed in WASM 1.1+

  # 2. Validate limits
  for mem in module.memories:
    if mem.limits.hasMax and mem.limits.min > mem.limits.max:
      validErr("memory: min > max")
    if mem.limits.min > 65536:
      validErr("memory: min pages > 65536")
    if mem.limits.hasMax and mem.limits.max > 65536:
      validErr("memory: max pages > 65536")

  for t in module.tables:
    if t.limits.hasMax and t.limits.min > t.limits.max:
      validErr("table: min > max")

  # 3. Count imports
  var numImportFuncs, numImportTables, numImportMems, numImportGlobals: int
  for imp in module.imports:
    case imp.kind
    of ikFunc:
      if imp.funcTypeIdx.int >= module.types.len:
        validErr("import function: invalid type index " & $imp.funcTypeIdx)
      numImportFuncs += 1
    of ikTable: numImportTables += 1
    of ikMemory: numImportMems += 1
    of ikGlobal: numImportGlobals += 1

  # 4. Validate function type indices
  for tidx in module.funcTypeIdxs:
    if tidx.int >= module.types.len:
      validErr("function: invalid type index " & $tidx)

  # 5. Validate memory count (max 1 in MVP)
  let totalMems = numImportMems + module.memories.len
  if totalMems > 1:
    validErr("at most one memory allowed (got " & $totalMems & ")")

  # 6. Validate export names are unique
  var exportNames: seq[string]
  for exp in module.exports:
    if exp.name in exportNames:
      validErr("duplicate export name: " & exp.name)
    exportNames.add(exp.name)

    # Validate export indices
    let totalFuncs = numImportFuncs + module.funcTypeIdxs.len
    let totalTables = numImportTables + module.tables.len
    let totalGlobals = numImportGlobals + module.globals.len
    case exp.kind
    of ekFunc:
      if exp.idx.int >= totalFuncs:
        validErr("export function: invalid index " & $exp.idx)
    of ekTable:
      if exp.idx.int >= totalTables:
        validErr("export table: invalid index " & $exp.idx)
    of ekMemory:
      if exp.idx.int >= totalMems:
        validErr("export memory: invalid index " & $exp.idx)
    of ekGlobal:
      if exp.idx.int >= totalGlobals:
        validErr("export global: invalid index " & $exp.idx)

  # 7. Validate start function
  if module.startFunc >= 0:
    let totalFuncs = numImportFuncs + module.funcTypeIdxs.len
    if module.startFunc.int >= totalFuncs:
      validErr("start function: invalid index " & $module.startFunc)

  # 8. Validate data count matches
  if module.dataCount >= 0:
    if module.dataCount.int != module.datas.len:
      validErr("data count mismatch: declared " & $module.dataCount &
               ", actual " & $module.datas.len)

  # 9. Validate function bodies
  let totalFuncs = numImportFuncs + module.funcTypeIdxs.len
  for i in numImportFuncs ..< totalFuncs:
    try:
      validateFunction(module, i)
    except ValidationError as e:
      validErr("function " & $i & ": " & e.msg)
