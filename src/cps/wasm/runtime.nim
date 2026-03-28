## WebAssembly runtime / execution engine
## Implements: Store, module instantiation, stack machine interpreter,
## all MVP instructions, host function binding, bulk memory/table ops.

{.experimental: "codeReordering".}

import ./types
import ./pgo
import std/[math, bitops]
when defined(wasmGuardPages):
  import ./guardmem

const WasmPageSize* = 65536
const MaxPages = 65536  # 4 GiB
# Arena sizes: start small, grow by doubling.
# Small defaults keep per-VM overhead low; most programs fit in the initial
# allocation and never pay a reallocation cost on the hot path.
const InitialValueStackSize = 1024   # 8 KB; typical programs rarely exceed 512 slots deep
const InitialCallStackSize   = 64    # 64 frames; standard depth limit is well below 4096
const InitialLabelStackSize  = 128   # 128 labels; covers deeply-nested blocks
const InitialLocalsSize      = 256   # 256 uint64 = 2 KB; grows per function call depth

# ---------------------------------------------------------------------------
# Runtime data structures
# ---------------------------------------------------------------------------

type
  WasmTrap* = object of CatchableError

  HostFunc* = proc(args: openArray[WasmValue]): seq[WasmValue] {.closure.}

  FuncInst* = object
    funcType*: FuncType
    case isHost*: bool
    of true:
      hostFunc*: HostFunc
    of false:
      moduleIdx*: int
      funcIdx*: int
      code*: ptr Expr
      localTypes*: seq[ValType]

  TableInst* = object
    tableType*: TableType
    elems*: seq[WasmValue]

  MemInst* = object
    memType*: MemType
    data*: seq[byte]
    when defined(wasmGuardPages):
      guardMem*: GuardedMem    ## guard-page-backed virtual reservation
      useGuard*: bool          ## true when guardMem is active

  GlobalInst* = object
    globalType*: GlobalType
    value*: WasmValue

  ElemInst* = object
    elemType*: ValType
    elems*: seq[WasmValue]
    dropped*: bool

  DataInst* = object
    data*: seq[byte]
    dropped*: bool

  ExportInst* = object
    name*: string
    kind*: ExportKind
    idx*: int

  ModuleInst* = object
    types*: seq[FuncType]
    funcAddrs*: seq[int]
    tableAddrs*: seq[int]
    memAddrs*: seq[int]
    globalAddrs*: seq[int]
    elemAddrs*: seq[int]
    dataAddrs*: seq[int]
    tagAddrs*: seq[int]
    exports*: seq[ExportInst]

  Label* = object
    arity*: int
    pc*: int
    stackHeight*: int
    isLoop*: bool
    catchTableIdx*: int32  ## ≥0 = try_table label, index into Frame.code.catchTables; -1 = no catches

  Frame* = object
    pc*: int
    code*: ptr Expr
    brTables*: ptr seq[BrTableData]
    localsStart*: int
    localsCount*: int
    labelStackStart*: int
    returnArity*: int
    moduleIdx*: int
    funcAddr*: int  # store funcAddr of the executing function (for PGO)

  WasmTagInst* = object
    funcType*: FuncType  ## param types = thrown value types; results always empty

  Store* = object
    funcs*: seq[FuncInst]
    tables*: seq[TableInst]
    mems*: seq[MemInst]
    globals*: seq[GlobalInst]
    elems*: seq[ElemInst]
    datas*: seq[DataInst]
    modules*: seq[ModuleInst]
    tags*: seq[WasmTagInst]  ## exception tags (module + imported)

  ## Per-call-site 2-way associative inline cache for call_indirect.
  ## Keyed by (funcAddr, callSitePc) encoded as a uint64.
  ## Each slot holds two (key, elemIdx, calleeAddr) entries and a 1-bit LRU
  ## counter so bimorphic call sites (alternating between 2 targets) hit on
  ## both entries instead of thrashing a single direct-mapped slot.
  ##
  ## Layout: 512 slots × 2 entries = 1024 total entries (same total memory as
  ## the former 1024-slot direct-mapped table).  Hash: key and 511.
  CallIcEntry* = object
    key*: uint64       ## (funcAddr.uint32 shl 32) or callSitePc.uint32; 0 = empty
    elemIdx*: int32    ## cached element index (-1 = unused)
    calleeAddr*: int32 ## resolved store funcAddr of the callee

  CallIcSlot* = object
    a*: CallIcEntry    ## first entry
    b*: CallIcEntry    ## second entry
    evictB*: bool      ## LRU bit: true → next miss evicts b, false → evicts a

  WasmVM* = object
    store*: Store
    # Hot-path stacks use flat uint64 for zero-overhead push/pop
    valueStack*: seq[uint64]
    valueStackTop*: int
    callStack*: seq[Frame]
    callStackTop*: int
    labelStack*: seq[Label]
    labelStackTop*: int
    locals*: seq[uint64]
    localsTop*: int
    # call_indirect inline cache (direct-mapped, 1024 slots)
    callIcBuf*: seq[CallIcSlot]

  ExternalVal* = object
    case kind*: ExportKind
    of ekFunc:
      funcType*: FuncType
      hostFunc*: HostFunc
    of ekTable:
      tableInst*: TableInst
    of ekMemory:
      memInst*: MemInst
    of ekGlobal:
      globalInst*: GlobalInst

# ---------------------------------------------------------------------------
# Trap helper
# ---------------------------------------------------------------------------

template trap(msg: string) =
  raise newException(WasmTrap, msg)

# ---------------------------------------------------------------------------
# VM initialization
# ---------------------------------------------------------------------------

proc initWasmVM*(): WasmVM =
  result.valueStack = newSeq[uint64](InitialValueStackSize)
  result.valueStackTop = 0
  result.callStack = newSeq[Frame](InitialCallStackSize)
  result.callStackTop = 0
  result.labelStack = newSeq[Label](InitialLabelStackSize)
  result.labelStackTop = 0
  result.locals = newSeq[uint64](InitialLocalsSize)
  result.localsTop = 0
  # 512-slot 2-way associative call_indirect IC (512 × 2 = 1024 total entries)
  result.callIcBuf = newSeq[CallIcSlot](512)

# ---------------------------------------------------------------------------
# Value stack operations
# ---------------------------------------------------------------------------

# Flat uint64 push/pop — no variant overhead on hot path
# Bounds checks removed: WASM is pre-validated, stack overflow can't happen
proc pushRaw*(vm: var WasmVM, val: uint64) {.inline.} =
  if unlikely(vm.valueStackTop >= vm.valueStack.len):
    vm.valueStack.setLen(vm.valueStack.len * 2)
  vm.valueStack[vm.valueStackTop] = val
  inc vm.valueStackTop

proc popRaw*(vm: var WasmVM): uint64 {.inline.} =
  dec vm.valueStackTop
  vm.valueStack[vm.valueStackTop]

proc push*(vm: var WasmVM, val: WasmValue) {.inline.} =
  case val.kind
  of wvkI32: vm.pushRaw(cast[uint64](val.i32.int64))
  of wvkI64: vm.pushRaw(cast[uint64](val.i64))
  of wvkF32: vm.pushRaw(cast[uint64](cast[uint32](val.f32)))
  of wvkF64: vm.pushRaw(cast[uint64](val.f64))
  of wvkFuncRef: vm.pushRaw(cast[uint64](val.funcRef.int64))
  of wvkExternRef: vm.pushRaw(cast[uint64](val.externRef.int64))
  of wvkV128:
    # v128 occupies 2 value stack slots (low 64 bits first, high 64 bits second)
    var lo, hi: uint64
    copyMem(lo.addr, val.v128[0].unsafeAddr, 8)
    copyMem(hi.addr, val.v128[8].unsafeAddr, 8)
    vm.pushRaw(lo)
    vm.pushRaw(hi)

proc pop*(vm: var WasmVM): WasmValue {.inline.} =
  ## Only used at API boundary — prefer typed popI32/popI64/etc on hot path
  wasmI64(cast[int64](vm.popRaw()))  # return as raw i64; caller converts

proc popI32*(vm: var WasmVM): int32 {.inline.} =
  cast[int32](vm.popRaw() and 0xFFFFFFFF'u64)

proc popI64*(vm: var WasmVM): int64 {.inline.} =
  cast[int64](vm.popRaw())

proc popF32*(vm: var WasmVM): float32 {.inline.} =
  var bits = uint32(vm.popRaw() and 0xFFFFFFFF'u64)
  cast[float32](bits)

proc popF64*(vm: var WasmVM): float64 {.inline.} =
  cast[float64](vm.popRaw())

proc pushI32*(vm: var WasmVM, v: int32) {.inline.} =
  # Zero-extend to 64 bits to keep upper bits clean
  vm.pushRaw(cast[uint64](v.int64) and 0xFFFFFFFF'u64)

proc pushI64*(vm: var WasmVM, v: int64) {.inline.} =
  vm.pushRaw(cast[uint64](v))

proc pushF32*(vm: var WasmVM, v: float32) {.inline.} =
  vm.pushRaw(cast[uint64](cast[uint32](v)))

proc pushF64*(vm: var WasmVM, v: float64) {.inline.} =
  vm.pushRaw(cast[uint64](v))

proc peekRaw*(vm: var WasmVM): uint64 {.inline.} =
  if vm.valueStackTop <= 0:
    trap("value stack underflow on peek")
  vm.valueStack[vm.valueStackTop - 1]

# ---------------------------------------------------------------------------
# WasmValue <-> uint64 conversion helpers
# ---------------------------------------------------------------------------

proc wasmValueToRaw*(v: WasmValue): uint64 {.inline.} =
  ## Convert WasmValue to its raw uint64 representation.
  ## For v128, returns only the low 64 bits (use push() for full 2-slot storage).
  case v.kind
  of wvkI32: cast[uint64](v.i32.int64) and 0xFFFFFFFF'u64
  of wvkI64: cast[uint64](v.i64)
  of wvkF32: cast[uint64](cast[uint32](v.f32))
  of wvkF64: cast[uint64](v.f64)
  of wvkFuncRef: cast[uint64](v.funcRef.int64) and 0xFFFFFFFF'u64
  of wvkExternRef: cast[uint64](v.externRef.int64) and 0xFFFFFFFF'u64
  of wvkV128:
    var lo: uint64
    copyMem(lo.addr, v.v128[0].unsafeAddr, 8)
    lo

proc rawToWasmValue*(raw: uint64, vt: ValType): WasmValue {.inline.} =
  case vt
  of vtI32: wasmI32(cast[int32](raw and 0xFFFFFFFF'u64))
  of vtI64: wasmI64(cast[int64](raw))
  of vtF32:
    var bits = uint32(raw and 0xFFFFFFFF'u64)
    wasmF32(cast[float32](bits))
  of vtF64: wasmF64(cast[float64](raw))
  of vtFuncRef: wasmFuncRef(cast[int32](raw and 0xFFFFFFFF'u64))
  of vtExternRef: wasmExternRef(cast[int32](raw and 0xFFFFFFFF'u64))
  of vtV128: WasmValue(kind: wvkV128)

# ---------------------------------------------------------------------------
# Label stack operations
# ---------------------------------------------------------------------------

proc pushLabel*(vm: var WasmVM, lbl: Label) {.inline.} =
  if vm.labelStackTop >= vm.labelStack.len:
    vm.labelStack.setLen(vm.labelStack.len * 2)
  vm.labelStack[vm.labelStackTop] = lbl
  inc vm.labelStackTop

proc popLabel*(vm: var WasmVM): Label {.inline.} =
  if vm.labelStackTop <= 0:
    trap("label stack underflow")
  dec vm.labelStackTop
  result = vm.labelStack[vm.labelStackTop]

# ---------------------------------------------------------------------------
# Call stack operations
# ---------------------------------------------------------------------------

proc pushFrame*(vm: var WasmVM, frame: Frame) {.inline.} =
  if vm.callStackTop >= vm.callStack.len:
    vm.callStack.setLen(vm.callStack.len * 2)
  vm.callStack[vm.callStackTop] = frame
  inc vm.callStackTop

proc popFrame*(vm: var WasmVM): Frame {.inline.} =
  if vm.callStackTop <= 0:
    trap("call stack underflow")
  dec vm.callStackTop
  result = vm.callStack[vm.callStackTop]

proc currentFrame*(vm: var WasmVM): var Frame {.inline.} =
  if vm.callStackTop <= 0:
    trap("no current frame")
  vm.valueStack.setLen(vm.valueStack.len) # ensure accessible
  vm.callStack[vm.callStackTop - 1]

# ---------------------------------------------------------------------------
# Locals access
# ---------------------------------------------------------------------------

proc getLocalRaw*(vm: var WasmVM, localsStart: int, idx: int): uint64 {.inline.} =
  vm.locals[localsStart + idx]

proc setLocalRaw*(vm: var WasmVM, localsStart: int, idx: int, val: uint64) {.inline.} =
  vm.locals[localsStart + idx] = val

# ---------------------------------------------------------------------------
# Block type helpers
# ---------------------------------------------------------------------------

proc blockResultArity(vm: var WasmVM, pad: uint16, cachedModIdx: int): int {.inline.} =
  ## Decode block result arity from compact pad field.
  ##   pad=0: empty (0 results), pad=1..0xFF: valtype (1 result),
  ##   pad>=0x100: type index (results.len)
  if pad == 0: return 0
  if pad < 0x100: return 1
  let typeIdx = (pad - 0x100).int
  vm.store.modules[cachedModIdx].types[typeIdx].results.len

proc blockParamArity(vm: var WasmVM, pad: uint16, cachedModIdx: int): int {.inline.} =
  ## Decode block param arity from compact pad field.
  ##   pad < 0x100: 0 params, pad >= 0x100: type index (params.len)
  if pad < 0x100: return 0
  let typeIdx = (pad - 0x100).int
  vm.store.modules[cachedModIdx].types[typeIdx].params.len

# ---------------------------------------------------------------------------
# Memory helpers
# ---------------------------------------------------------------------------

proc getMem(vm: var WasmVM, modIdx: int, memIdx: int = 0): var MemInst {.inline.} =
  let addr0 = vm.store.modules[modIdx].memAddrs[memIdx]
  vm.store.mems[addr0]

proc boundsCheck(mem: var MemInst, ea: uint64, size: int) {.inline.} =
  when defined(wasmGuardPages):
    if mem.useGuard:
      return  # hardware guard pages handle the check
  if ea + size.uint64 > mem.data.len.uint64:
    trap("out of bounds memory access")

proc memBasePtr*(mem: var MemInst): ptr byte {.inline.} =
  when defined(wasmGuardPages):
    if mem.useGuard:
      return cast[ptr byte](mem.guardMem.base)
  if mem.data.len > 0:
    return mem.data[0].addr
  nil

proc memBulkPtr(mem: var MemInst, offset: uint64): ptr byte {.inline.} =
  ## Pointer to byte at `offset` — works for both seq and guard-backed memory.
  when defined(wasmGuardPages):
    if mem.useGuard:
      return cast[ptr byte](cast[uint64](mem.guardMem.base) + offset)
  mem.data[offset.int].addr

proc memByteLen(mem: var MemInst): uint64 {.inline.} =
  ## Current accessible byte count.
  when defined(wasmGuardPages):
    if mem.useGuard:
      return mem.guardMem.accessibleBytes
  mem.data.len.uint64

proc loadVal[T](mem: var MemInst, ea: uint64): T {.inline.} =
  boundsCheck(mem, ea, sizeof(T))
  when defined(wasmGuardPages):
    if mem.useGuard:
      copyMem(result.addr, cast[ptr byte](cast[uint64](mem.guardMem.base) + ea), sizeof(T))
      return
  copyMem(result.addr, mem.data[ea.int].unsafeAddr, sizeof(T))

proc storeVal[T](mem: var MemInst, ea: uint64, val: T) {.inline.} =
  boundsCheck(mem, ea, sizeof(T))
  var v = val
  when defined(wasmGuardPages):
    if mem.useGuard:
      copyMem(cast[ptr byte](cast[uint64](mem.guardMem.base) + ea), v.addr, sizeof(T))
      return
  copyMem(mem.data[ea.int].addr, v.addr, sizeof(T))

# ---------------------------------------------------------------------------
# Init expression evaluator (for globals, data/elem offsets)
# ---------------------------------------------------------------------------

proc evalInitExpr*(vm: var WasmVM, expr: Expr, modIdx: int): WasmValue =
  for instr in expr.code:
    case instr.op
    of opI32Const:
      return wasmI32(cast[int32](instr.imm1))
    of opI64Const:
      let u = uint64(instr.imm1) or (uint64(instr.imm2) shl 32)
      return wasmI64(cast[int64](u))
    of opF32Const:
      return wasmF32(cast[float32](instr.imm1))
    of opF64Const:
      let u = uint64(instr.imm1) or (uint64(instr.imm2) shl 32)
      return wasmF64(cast[float64](u))
    of opGlobalGet:
      let globalIdx = instr.imm1.int
      let globalAddr = vm.store.modules[modIdx].globalAddrs[globalIdx]
      return vm.store.globals[globalAddr].value
    of opRefNull:
      let rtOrd = instr.imm1
      if rtOrd == uint32(ord(vtFuncRef)): return wasmNullFuncRef()
      elif rtOrd == uint32(ord(vtExternRef)): return wasmNullExternRef()
      else: trap("invalid ref.null type in init expr")
    of opRefFunc:
      let funcIdx = instr.imm1.int
      let funcAddr = vm.store.modules[modIdx].funcAddrs[funcIdx]
      return wasmFuncRef(funcAddr.int32)
    of opEnd:
      break
    else:
      trap("invalid instruction in init expression: " & $instr.op)
  trap("init expression did not produce a value")

# ---------------------------------------------------------------------------
# Module instantiation
# ---------------------------------------------------------------------------

proc instantiate*(vm: var WasmVM, module: WasmModule,
                  imports: openArray[(string, string, ExternalVal)]): int =
  ## Instantiate a module into the VM store. Returns the module instance index.
  let modIdx = vm.store.modules.len
  var modInst = ModuleInst()
  modInst.types = module.types

  # --- Count imported functions/tables/mems/globals ---
  var importFuncCount = 0
  var importTableCount = 0
  var importMemCount = 0
  var importGlobalCount = 0

  for imp in module.imports:
    case imp.kind
    of ikFunc: inc importFuncCount
    of ikTable: inc importTableCount
    of ikMemory: inc importMemCount
    of ikGlobal: inc importGlobalCount

  # --- Resolve imports ---
  for imp in module.imports:
    var found = false
    for (impMod, impName, extVal) in imports:
      if impMod == imp.module and impName == imp.name:
        case imp.kind
        of ikFunc:
          if extVal.kind != ekFunc:
            trap("import type mismatch for " & imp.module & "." & imp.name & ": expected function")
          let funcAddr = vm.store.funcs.len
          vm.store.funcs.add(FuncInst(
            funcType: extVal.funcType,
            isHost: true,
            hostFunc: extVal.hostFunc
          ))
          modInst.funcAddrs.add(funcAddr)
        of ikTable:
          if extVal.kind != ekTable:
            trap("import type mismatch for " & imp.module & "." & imp.name & ": expected table")
          let tableAddr = vm.store.tables.len
          vm.store.tables.add(extVal.tableInst)
          modInst.tableAddrs.add(tableAddr)
        of ikMemory:
          if extVal.kind != ekMemory:
            trap("import type mismatch for " & imp.module & "." & imp.name & ": expected memory")
          let memAddr = vm.store.mems.len
          vm.store.mems.add(extVal.memInst)
          modInst.memAddrs.add(memAddr)
        of ikGlobal:
          if extVal.kind != ekGlobal:
            trap("import type mismatch for " & imp.module & "." & imp.name & ": expected global")
          let globalAddr = vm.store.globals.len
          vm.store.globals.add(extVal.globalInst)
          modInst.globalAddrs.add(globalAddr)
        found = true
        break
    if not found:
      trap("unresolved import: " & imp.module & "." & imp.name)

  # --- Allocate defined functions ---
  for i in 0 ..< module.funcTypeIdxs.len:
    let funcAddr = vm.store.funcs.len
    let typeIdx = module.funcTypeIdxs[i].int
    let ft = module.types[typeIdx]
    var localTys: seq[ValType] = @[]
    # Expand params
    for p in ft.params:
      localTys.add(p)
    # Expand body locals
    if i < module.codes.len:
      for ld in module.codes[i].locals:
        for j in 0'u32 ..< ld.count:
          localTys.add(ld.valType)
    vm.store.funcs.add(FuncInst(
      funcType: ft,
      isHost: false,
      moduleIdx: modIdx,
      funcIdx: i,
      code: if i < module.codes.len: module.codes[i].code.addr else: nil,
      localTypes: localTys
    ))
    modInst.funcAddrs.add(funcAddr)

  # --- Allocate defined tables ---
  for tt in module.tables:
    let tableAddr = vm.store.tables.len
    var elems = newSeq[WasmValue](tt.limits.min.int)
    let initVal = if tt.elemType == vtFuncRef: wasmNullFuncRef()
                  else: wasmNullExternRef()
    for i in 0 ..< elems.len:
      elems[i] = initVal
    vm.store.tables.add(TableInst(tableType: tt, elems: elems))
    modInst.tableAddrs.add(tableAddr)

  # --- Allocate defined memories ---
  for mt in module.memories:
    let memAddr = vm.store.mems.len
    let initialPages = mt.limits.min.int
    let maxPages = if mt.limits.hasMax: mt.limits.max.int else: 0
    when defined(wasmGuardPages):
      var mi = MemInst(memType: mt)
      mi.guardMem = allocGuardedMem(initialPages, maxPages)
      mi.useGuard = true
      vm.store.mems.add(mi)
    else:
      let numBytes = initialPages * WasmPageSize
      vm.store.mems.add(MemInst(
        memType: mt,
        data: newSeq[byte](numBytes)
      ))
    modInst.memAddrs.add(memAddr)

  # We need the module in store before evaluating init exprs (for global.get)
  vm.store.modules.add(modInst)

  # --- Allocate defined globals ---
  for gd in module.globals:
    let globalAddr = vm.store.globals.len
    let initVal = vm.evalInitExpr(gd.init, modIdx)
    vm.store.globals.add(GlobalInst(
      globalType: gd.globalType,
      value: initVal
    ))
    vm.store.modules[modIdx].globalAddrs.add(globalAddr)

  # --- Allocate element segments ---
  for es in module.elements:
    let elemAddr = vm.store.elems.len
    var elemInst = ElemInst(elemType: es.elemType, dropped: false)
    for initExpr in es.init:
      elemInst.elems.add(vm.evalInitExpr(initExpr, modIdx))
    vm.store.elems.add(elemInst)
    vm.store.modules[modIdx].elemAddrs.add(elemAddr)

  # --- Allocate data segments ---
  for ds in module.datas:
    let dataAddr = vm.store.datas.len
    vm.store.datas.add(DataInst(data: ds.data, dropped: false))
    vm.store.modules[modIdx].dataAddrs.add(dataAddr)

  # --- Initialize active element segments ---
  for i, es in module.elements:
    if es.mode == elemActive:
      let tableAddr = vm.store.modules[modIdx].tableAddrs[es.tableIdx.int]
      let offsetVal = vm.evalInitExpr(es.offset, modIdx)
      let offset = offsetVal.i32.int
      let elemAddr = vm.store.modules[modIdx].elemAddrs[i]
      let elemInst = vm.store.elems[elemAddr]
      if offset + elemInst.elems.len > vm.store.tables[tableAddr].elems.len:
        trap("out of bounds table access during element initialization")
      for j in 0 ..< elemInst.elems.len:
        vm.store.tables[tableAddr].elems[offset + j] = elemInst.elems[j]
      vm.store.elems[elemAddr].dropped = true

  # --- Initialize active data segments ---
  for i, ds in module.datas:
    if ds.mode == dataActive:
      let memAddr = vm.store.modules[modIdx].memAddrs[ds.memIdx.int]
      let offsetVal = vm.evalInitExpr(ds.offset, modIdx)
      let offset = offsetVal.i32.int
      let dataAddr = vm.store.modules[modIdx].dataAddrs[i]
      let dataInst = vm.store.datas[dataAddr]
      when defined(wasmGuardPages):
        if vm.store.mems[memAddr].useGuard:
          let guardBytes = vm.store.mems[memAddr].guardMem.accessibleBytes
          if uint64(offset) + uint64(dataInst.data.len) > guardBytes:
            trap("out of bounds memory access during data initialization")
          if dataInst.data.len > 0:
            let dst = cast[ptr byte](cast[uint64](vm.store.mems[memAddr].guardMem.base) + uint64(offset))
            copyMem(dst, dataInst.data[0].unsafeAddr, dataInst.data.len)
          vm.store.datas[dataAddr].dropped = true
          continue
      if offset + dataInst.data.len > vm.store.mems[memAddr].data.len:
        trap("out of bounds memory access during data initialization")
      if dataInst.data.len > 0:
        copyMem(vm.store.mems[memAddr].data[offset].addr,
                dataInst.data[0].unsafeAddr,
                dataInst.data.len)
      vm.store.datas[dataAddr].dropped = true

  # --- Allocate exception tags ---
  for td in module.tagDefs:
    let tagAddr = vm.store.tags.len
    let ft = module.types[td.typeIdx.int]
    vm.store.tags.add(WasmTagInst(funcType: ft))
    vm.store.modules[modIdx].tagAddrs.add(tagAddr)

  # --- Exports ---
  for exp in module.exports:
    var ei = ExportInst(name: exp.name, kind: exp.kind)
    case exp.kind
    of ekFunc:
      ei.idx = vm.store.modules[modIdx].funcAddrs[exp.idx.int]
    of ekTable:
      ei.idx = vm.store.modules[modIdx].tableAddrs[exp.idx.int]
    of ekMemory:
      ei.idx = vm.store.modules[modIdx].memAddrs[exp.idx.int]
    of ekGlobal:
      ei.idx = vm.store.modules[modIdx].globalAddrs[exp.idx.int]
    vm.store.modules[modIdx].exports.add(ei)

  # --- Start function ---
  # --- Patch opCall instructions to use direct store indices ---
  # Replace module-relative funcIdx with pre-resolved store funcAddr.
  # This eliminates a double indirection at call time.
  let patchModInst = vm.store.modules[modIdx]
  for i in 0 ..< module.codes.len:
    let codeIdx = i
    let importFuncCount = patchModInst.funcAddrs.len - module.codes.len
    let funcStoreIdx = patchModInst.funcAddrs[importFuncCount + i]
    if funcStoreIdx < vm.store.funcs.len:
      let funcInst = vm.store.funcs[funcStoreIdx]
      if not funcInst.isHost and funcInst.code != nil:
        let code = funcInst.code
        for j in 0 ..< code[].code.len:
          if code[].code[j].op == opCall:
            let origIdx = code[].code[j].imm1.int
            if origIdx < patchModInst.funcAddrs.len:
              code[].code[j].imm1 = uint32(patchModInst.funcAddrs[origIdx])
              code[].code[j].pad = 1  # mark as pre-resolved

  if module.startFunc >= 0:
    let startFuncAddr = vm.store.modules[modIdx].funcAddrs[module.startFunc.int]
    discard vm.execute(startFuncAddr, [])

  result = modIdx

# ---------------------------------------------------------------------------
# Branch helper
# ---------------------------------------------------------------------------

proc doBranch(vm: var WasmVM, labelDepth: int): int {.inline.} =
  ## Branch to the label at the given depth. Returns the new pc.
  let targetLabelIdx = vm.labelStackTop - 1 - labelDepth
  let targetLabel = vm.labelStack[targetLabelIdx]

  let arity = targetLabel.arity
  var results: array[128, uint64]
  for i in countdown(arity - 1, 0):
    results[i] = vm.popRaw()

  vm.valueStackTop = targetLabel.stackHeight

  for i in 0 ..< arity:
    vm.pushRaw(results[i])

  if targetLabel.isLoop:
    vm.labelStackTop = targetLabelIdx + 1
  else:
    vm.labelStackTop = targetLabelIdx

  targetLabel.pc

# ---------------------------------------------------------------------------
# Float helpers
# ---------------------------------------------------------------------------

proc f32Nearest(v: float32): float32 =
  ## Round to nearest even (IEEE 754 roundTiesToEven)
  if v.isNaN: return v
  if v.classify in {fcInf, fcNegInf, fcZero, fcNegZero}: return v
  let rounded = round(v)
  let diff = v - rounded
  if abs(diff) == 0.5f:
    # Tie: round to even
    let r = rounded.int64
    if (r and 1) != 0:
      if v > 0: return rounded - 1.0f
      else: return rounded + 1.0f
  return rounded

proc f64Nearest(v: float64): float64 =
  ## Round to nearest even (IEEE 754 roundTiesToEven)
  if v.isNaN: return v
  if v.classify in {fcInf, fcNegInf, fcZero, fcNegZero}: return v
  let rounded = round(v)
  let diff = v - rounded
  if abs(diff) == 0.5:
    let r = rounded.int64
    if (r and 1) != 0:
      if v > 0: return rounded - 1.0
      else: return rounded + 1.0
  return rounded

proc f32Min(a, b: float32): float32 =
  if a.isNaN or b.isNaN: return float32(NaN)
  if a == 0 and b == 0:
    # Distinguish -0 and +0
    var ai: uint32
    var bi: uint32
    copyMem(ai.addr, a.unsafeAddr, 4)
    copyMem(bi.addr, b.unsafeAddr, 4)
    if (ai or bi) >= 0x80000000'u32: # at least one is negative zero
      var nz = -0.0f
      return nz
    return a
  if a < b: a else: b

proc f32Max(a, b: float32): float32 =
  if a.isNaN or b.isNaN: return float32(NaN)
  if a == 0 and b == 0:
    var ai: uint32
    var bi: uint32
    copyMem(ai.addr, a.unsafeAddr, 4)
    copyMem(bi.addr, b.unsafeAddr, 4)
    if (ai and bi) >= 0x80000000'u32: # both negative zero
      var nz = -0.0f
      return nz
    return 0.0f
  if a > b: a else: b

proc f64Min(a, b: float64): float64 =
  if a.isNaN or b.isNaN: return NaN
  if a == 0 and b == 0:
    var ai: uint64
    var bi: uint64
    copyMem(ai.addr, a.unsafeAddr, 8)
    copyMem(bi.addr, b.unsafeAddr, 8)
    if (ai or bi) >= 0x8000000000000000'u64:
      var nz = -0.0
      return nz
    return a
  if a < b: a else: b

proc f64Max(a, b: float64): float64 =
  if a.isNaN or b.isNaN: return NaN
  if a == 0 and b == 0:
    var ai: uint64
    var bi: uint64
    copyMem(ai.addr, a.unsafeAddr, 8)
    copyMem(bi.addr, b.unsafeAddr, 8)
    if (ai and bi) >= 0x8000000000000000'u64:
      var nz = -0.0
      return nz
    return 0.0
  if a > b: a else: b

proc f32Copysign(mag, sgn: float32): float32 =
  result = copySign(mag, sgn)

proc f64Copysign(mag, sgn: float64): float64 =
  result = copySign(mag, sgn)

# ---------------------------------------------------------------------------
# Integer rotation helpers
# ---------------------------------------------------------------------------

proc rotl32(val: uint32, count: uint32): uint32 {.inline.} =
  let k = count and 31
  if k == 0: return val
  (val shl k) or (val shr (32 - k))

proc rotr32(val: uint32, count: uint32): uint32 {.inline.} =
  let k = count and 31
  if k == 0: return val
  (val shr k) or (val shl (32 - k))

proc rotl64(val: uint64, count: uint64): uint64 {.inline.} =
  let k = count and 63
  if k == 0: return val
  (val shl k) or (val shr (64 - k))

proc rotr64(val: uint64, count: uint64): uint64 {.inline.} =
  let k = count and 63
  if k == 0: return val
  (val shr k) or (val shl (64 - k))

# ---------------------------------------------------------------------------
# Reinterpret cast helpers
# ---------------------------------------------------------------------------

proc reinterpretI32AsF32(v: int32): float32 {.inline.} =
  copyMem(result.addr, v.unsafeAddr, 4)

proc reinterpretI64AsF64(v: int64): float64 {.inline.} =
  copyMem(result.addr, v.unsafeAddr, 8)

proc reinterpretF32AsI32(v: float32): int32 {.inline.} =
  copyMem(result.addr, v.unsafeAddr, 4)

proc reinterpretF64AsI64(v: float64): int64 {.inline.} =
  copyMem(result.addr, v.unsafeAddr, 8)

# ---------------------------------------------------------------------------
# Truncation helpers (trapping and saturating)
# ---------------------------------------------------------------------------

proc truncI32F32S(v: float32): int32 =
  if v.isNaN: trap("invalid conversion to integer")
  let tv = trunc(v)
  if tv >= 2147483648.0f or tv < -2147483648.0f:
    trap("integer overflow")
  int32(tv)

proc truncI32F32U(v: float32): int32 =
  if v.isNaN: trap("invalid conversion to integer")
  let tv = trunc(v)
  if tv >= 4294967296.0f or tv < 0.0f:
    trap("integer overflow")
  cast[int32](uint32(tv))

proc truncI32F64S(v: float64): int32 =
  if v.isNaN: trap("invalid conversion to integer")
  let tv = trunc(v)
  if tv >= 2147483648.0 or tv < -2147483648.0:
    trap("integer overflow")
  int32(tv)

proc truncI32F64U(v: float64): int32 =
  if v.isNaN: trap("invalid conversion to integer")
  let tv = trunc(v)
  if tv >= 4294967296.0 or tv < 0.0:
    trap("integer overflow")
  cast[int32](uint32(tv))

proc truncI64F32S(v: float32): int64 =
  if v.isNaN: trap("invalid conversion to integer")
  let tv = trunc(v.float64)
  if tv >= 9223372036854775808.0 or tv < -9223372036854775808.0:
    trap("integer overflow")
  int64(tv)

proc truncI64F32U(v: float32): int64 =
  if v.isNaN: trap("invalid conversion to integer")
  let tv = trunc(v.float64)
  if tv >= 18446744073709551616.0 or tv < 0.0:
    trap("integer overflow")
  cast[int64](uint64(tv))

proc truncI64F64S(v: float64): int64 =
  if v.isNaN: trap("invalid conversion to integer")
  let tv = trunc(v)
  if tv >= 9223372036854775808.0 or tv < -9223372036854775808.0:
    trap("integer overflow")
  int64(tv)

proc truncI64F64U(v: float64): int64 =
  if v.isNaN: trap("invalid conversion to integer")
  let tv = trunc(v)
  if tv >= 18446744073709551616.0 or tv < 0.0:
    trap("integer overflow")
  cast[int64](uint64(tv))

# Saturating truncations
proc truncSatI32F32S(v: float32): int32 =
  if v.isNaN: return 0
  let tv = trunc(v)
  if tv >= 2147483647.0f: return int32.high
  if tv < -2147483648.0f: return int32.low
  int32(tv)

proc truncSatI32F32U(v: float32): int32 =
  if v.isNaN: return 0
  let tv = trunc(v)
  if tv >= 4294967295.0f: return cast[int32](uint32.high)
  if tv < 0.0f: return 0
  cast[int32](uint32(tv))

proc truncSatI32F64S(v: float64): int32 =
  if v.isNaN: return 0
  let tv = trunc(v)
  if tv >= 2147483647.0: return int32.high
  if tv < -2147483648.0: return int32.low
  int32(tv)

proc truncSatI32F64U(v: float64): int32 =
  if v.isNaN: return 0
  let tv = trunc(v)
  if tv >= 4294967295.0: return cast[int32](uint32.high)
  if tv < 0.0: return 0
  cast[int32](uint32(tv))

proc truncSatI64F32S(v: float32): int64 =
  if v.isNaN: return 0
  let tv = trunc(v.float64)
  if tv >= 9223372036854775807.0: return int64.high
  if tv < -9223372036854775808.0: return int64.low
  int64(tv)

proc truncSatI64F32U(v: float32): int64 =
  if v.isNaN: return 0
  let tv = trunc(v.float64)
  if tv >= 18446744073709551615.0: return cast[int64](uint64.high)
  if tv < 0.0: return 0
  cast[int64](uint64(tv))

proc truncSatI64F64S(v: float64): int64 =
  if v.isNaN: return 0
  let tv = trunc(v)
  if tv >= 9223372036854775807.0: return int64.high
  if tv < -9223372036854775808.0: return int64.low
  int64(tv)

proc truncSatI64F64U(v: float64): int64 =
  if v.isNaN: return 0
  let tv = trunc(v)
  if tv >= 18446744073709551615.0: return cast[int64](uint64.high)
  if tv < 0.0: return 0
  cast[int64](uint64(tv))

# ---------------------------------------------------------------------------
# Main execution loop
# ---------------------------------------------------------------------------

## On-stack-replacement trigger: filled by execute() when a top-level function's
## inner loops are hot enough to warrant immediate JIT compilation.
## The function runs to completion in the interpreter; the caller should compile
## the flagged function so subsequent invocations run at JIT speed.
type OsrTrigger* = object
  triggered*: bool   ## true when a function crossed the back-edge heat threshold
  funcAddr*: int     ## store funcAddr of the hot function

const OsrBackEdgeThreshold* = 50_000  ## back-edges before signalling OSR

proc execute*(vm: var WasmVM, funcAddr: int,
              args: openArray[WasmValue],
              profiler: ptr PgoProfiler = nil,
              osrOut: ptr OsrTrigger = nil): seq[WasmValue] =
  ## Execute a function by its address in the store.
  ## Returns the function's result values.
  ## If osrOut is non-nil and the top-level function executes OsrBackEdgeThreshold
  ## loop back-edges, osrOut[].triggered is set to true so the caller can JIT-compile
  ## the function for subsequent calls.
  let funcInst {.cursor.} = vm.store.funcs[funcAddr]

  # Handle host functions directly
  if funcInst.isHost:
    return funcInst.hostFunc(args)

  # Type check arguments
  let ft = funcInst.funcType
  if args.len != ft.params.len:
    trap("argument count mismatch: expected " & $ft.params.len &
         ", got " & $args.len)

  # Save entry state
  let entryValueStackTop = vm.valueStackTop
  let entryCallStackTop = vm.callStackTop
  let entryLabelStackTop = vm.labelStackTop
  let entryLocalsTop = vm.localsTop

  # Allocate locals: params + body locals
  let localsStart = vm.localsTop
  let totalLocals = funcInst.localTypes.len
  while vm.localsTop + totalLocals > vm.locals.len:
    vm.locals.setLen(vm.locals.len * 2)

  # Copy args into params (convert WasmValue -> uint64)
  for i in 0 ..< ft.params.len:
    vm.locals[localsStart + i] = wasmValueToRaw(args[i])
  # Zero-init body locals
  for i in ft.params.len ..< totalLocals:
    vm.locals[localsStart + i] = 0'u64
  vm.localsTop = localsStart + totalLocals

  # Push frame
  let frame = Frame(
    pc: 0,
    code: funcInst.code,
    brTables: funcInst.code[].brTables.addr,
    localsStart: localsStart,
    localsCount: totalLocals,
    labelStackStart: vm.labelStackTop,
    returnArity: ft.results.len,
    moduleIdx: funcInst.moduleIdx,
    funcAddr: funcAddr
  )
  vm.pushFrame(frame)

  # Push implicit function-body label
  vm.pushLabel(Label(
    arity: ft.results.len,
    pc: funcInst.code[].code.len,  # end of function
    stackHeight: vm.valueStackTop,
    isLoop: false,
    catchTableIdx: -1
  ))

  # Pre-reserve value stack based on the function's known max stack depth.
  # This converts the per-push bounds check into an occasional resize.
  let needed = vm.valueStackTop + funcInst.code[].maxStackDepth.int + 8
  if needed > vm.valueStack.len:
    vm.valueStack.setLen(max(vm.valueStack.len * 2, needed))

  # Main dispatch loop — cached frame state for minimal overhead
  {.push checks: off.}  # Disable bounds checks on hot path
  var cachedCode: ptr UncheckedArray[Instr]
  var cachedCodeLen: int
  var cachedPc: int
  var cachedModIdx: int
  var cachedLocalsStart: int
  var cachedBrTables: ptr seq[BrTableData]
  var cachedFuncAddr: int
  # Self-call cache: avoids store.funcs lookup and redundant Frame field writes
  # for self-recursive calls (same function calling itself). Set on first
  # self-call, invalidated when a different function is entered.
  var scParamCount: int = -1    # -1 = cache invalid
  var scTotalLocals: int
  var scReturnArity: int
  var scCode: ptr Expr
  var scCodeLen: int
  # Cache value stack as raw pointer + top index to avoid seq field indirection
  var sp: int = vm.valueStackTop  # stack pointer (value stack top)
  var vsBase: ptr UncheckedArray[uint64] = cast[ptr UncheckedArray[uint64]](vm.valueStack[0].addr)
  var locBase: ptr UncheckedArray[uint64] = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)
  # OSR heat tracking: count loop back-edges executed in the top-level frame.
  # Only counts when osrOut is provided (i.e., executing inside TieredVM).
  var osrBackEdges: int = 0
  template trackOsrBackEdge() =
    ## Call at every loop back-edge in the top-level frame.
    ## Signals the caller to JIT-compile the function when the threshold is hit.
    if osrOut != nil and vm.callStackTop == entryCallStackTop + 1:
      inc osrBackEdges
      if osrBackEdges == OsrBackEdgeThreshold and not osrOut[].triggered:
        osrOut[].triggered = true
        osrOut[].funcAddr = cachedFuncAddr
  template loadFrameCache() =
    let f = vm.callStack[vm.callStackTop - 1]
    cachedCode = cast[ptr UncheckedArray[Instr]](f.code[].code[0].addr)
    cachedCodeLen = f.code[].code.len
    cachedPc = f.pc
    cachedModIdx = f.moduleIdx
    cachedLocalsStart = f.localsStart
    cachedBrTables = f.brTables
    cachedFuncAddr = f.funcAddr

  template loadFrameCacheFast() =
    ## Fast path for self-recursive call returns. When the parent frame's
    ## function is the same as the callee (cachedFuncAddr unchanged), only
    ## the varying fields (pc, localsStart) need restoring. Skips 5 loads
    ## (code, codeLen, brTables, moduleIdx, funcAddr) that are invariant.
    let f = vm.callStack[vm.callStackTop - 1]
    cachedPc = f.pc
    cachedLocalsStart = f.localsStart

  template saveFramePc() =
    vm.callStack[vm.callStackTop - 1].pc = cachedPc

  template syncSp() =
    ## Sync cached sp back to vm
    vm.valueStackTop = sp

  template spush(val: uint64) =
    if unlikely(sp >= vm.valueStack.len):
      vm.valueStack.setLen(vm.valueStack.len * 2)
      vsBase = cast[ptr UncheckedArray[uint64]](vm.valueStack[0].addr)
    vsBase[sp] = val
    inc sp

  template spop(): uint64 =
    dec sp
    vsBase[sp]

  template speek(): uint64 =
    vsBase[sp - 1]

  template spushI32(v: int32) = spush(cast[uint64](v.int64) and 0xFFFFFFFF'u64)
  template spopI32(): int32 = cast[int32](spop() and 0xFFFFFFFF'u64)
  template spushI64(v: int64) = spush(cast[uint64](v))
  template spopI64(): int64 = cast[int64](spop())
  template spushF32(v: float32) = spush(cast[uint64](cast[uint32](v)))
  template spopF32(): float32 = (var spopF32Bits = uint32(spop() and 0xFFFFFFFF'u64); cast[float32](spopF32Bits))
  template spushF64(v: float64) = spush(cast[uint64](v))
  template spopF64(): float64 = cast[float64](spop())

  template reloadLocBase() =
    locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)

  template inlineBranch(depth: int) =
    ## Inline fast-path branch for arity 0/1 (same logic as opBr).
    ## Avoids the syncSp → doBranch → sp reload round-trip for common cases.
    let ibTargetIdx = vm.labelStackTop - 1 - depth
    let ibTarget = vm.labelStack[ibTargetIdx]
    if ibTarget.arity == 0:
      sp = ibTarget.stackHeight
      if ibTarget.isLoop:
        vm.labelStackTop = ibTargetIdx + 1
        trackOsrBackEdge()
      else:
        vm.labelStackTop = ibTargetIdx
      cachedPc = ibTarget.pc
    elif ibTarget.arity == 1:
      let ibRetVal = vsBase[sp - 1]
      sp = ibTarget.stackHeight + 1
      vsBase[ibTarget.stackHeight] = ibRetVal
      if ibTarget.isLoop:
        vm.labelStackTop = ibTargetIdx + 1
        trackOsrBackEdge()
      else:
        vm.labelStackTop = ibTargetIdx
      cachedPc = ibTarget.pc
    else:
      syncSp()
      cachedPc = vm.doBranch(depth)
      sp = vm.valueStackTop
    continue

  loadFrameCache()

  # Main dispatch loop
  while vm.callStackTop > entryCallStackTop:
    if unlikely(cachedPc >= cachedCodeLen):
      # Implicit return — function body end reached
      let curFrame = vm.callStack[vm.callStackTop - 1]
      vm.localsTop = curFrame.localsStart
      vm.labelStackTop = curFrame.labelStackStart
      dec vm.callStackTop
      discard curFrame.returnArity  # stack already clean for validated WASM
      if vm.callStackTop > entryCallStackTop:
        loadFrameCache()
        locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)
      continue

    let instr = cachedCode[cachedPc]
    inc cachedPc

    when defined(wasmTrace):
      block traceBlock:
        # Only trace when the function has 12+ locals (sort function) to reduce noise
        let traceLocCount = vm.callStack[vm.callStackTop - 1].localsCount
        if traceLocCount >= 12:
          var line = "  [" & $(cachedPc - 1) & "] " & $instr.op
          # Add immediates
          case instr.op
          of opLocalGet, opLocalSet, opLocalTee:
            line &= " idx=" & $instr.imm1
          of opI32Const:
            line &= " " & $cast[int32](instr.imm1)
          of opI32Load, opI32Store:
            line &= " off=" & $instr.imm1
          of opBr, opBrIf:
            line &= " depth=" & $instr.imm1
          of opBlock, opLoop, opIf:
            line &= " end=" & $instr.imm1 & " else=" & $instr.imm2
          of opLocalGetLocalGet, opLocalSetLocalGet, opLocalTeeLocalGet, opLocalGetLocalTee:
            line &= " " & $instr.imm1 & "," & $instr.imm2
          of opLocalGetI32Add, opLocalGetI32Sub:
            line &= " loc=" & $instr.imm1
          of opI32ConstI32Add, opI32ConstI32Sub:
            line &= " C=" & $cast[int32](instr.imm1)
          of opI32ConstI32GeS, opI32ConstI32LtS:
            line &= " C=" & $cast[int32](instr.imm1)
          of opI32ConstI32GtU:
            line &= " C=" & $instr.imm1
          of opLocalGetLocalGetI32Add, opLocalGetLocalGetI32Sub:
            line &= " " & $instr.imm1 & "," & $instr.imm2
          of opLocalGetI32ConstI32Sub, opLocalGetI32ConstI32Add:
            line &= " loc=" & $instr.imm1 & " C=" & $cast[int32](instr.imm2)
          of opI32AddLocalSet, opI32SubLocalSet:
            line &= " loc=" & $instr.imm1
          of opLocalGetI32Const:
            line &= " loc=" & $instr.imm1 & " C=" & $cast[int32](instr.imm2)
          of opI32EqzBrIf,
             opI32EqBrIf, opI32NeBrIf, opI32LtSBrIf, opI32GeSBrIf,
             opI32GtSBrIf, opI32LeSBrIf, opI32LtUBrIf, opI32GeUBrIf,
             opI32GtUBrIf, opI32LeUBrIf:
            line &= " depth=" & $instr.imm1
          of opI32ConstI32EqBrIf, opI32ConstI32NeBrIf, opI32ConstI32LtSBrIf,
             opI32ConstI32GeSBrIf, opI32ConstI32GtUBrIf, opI32ConstI32LeUBrIf:
            line &= " C=" & $cast[int32](instr.imm1) & " depth=" & $instr.imm2
          of opLocalTeeBrIf:
            line &= " loc=" & $instr.imm1 & " depth=" & $instr.imm2
          of opLocalGetI64Add, opLocalGetI64Sub:
            line &= " loc=" & $instr.imm1
          of opLocalI32AddInPlace, opLocalI32SubInPlace:
            line &= " loc=" & $instr.imm1 & " C=" & $cast[int32](instr.imm2)
          of opLocalGetLocalGetI32AddLocalSet, opLocalGetLocalGetI32SubLocalSet:
            line &= " X=" & $(instr.imm1 and 0xFFFF'u32) & " Y=" & $(instr.imm1 shr 16) &
                    " Z=" & $instr.imm2
          else:
            if instr.imm1 != 0: line &= " imm1=" & $instr.imm1
          # Stack top 3
          line &= "  | stack["
          let nShow = min(sp, 3)
          for si in countdown(nShow - 1, 0):
            if si < nShow - 1: line &= ", "
            line &= $cast[int32](vsBase[sp - 1 - si] and 0xFFFFFFFF'u64)
          line &= "] sp=" & $sp
          # Show key locals
          line &= " L[0..5]=["
          let ls = cachedLocalsStart
          for li in 0..min(12, traceLocCount - 1):
            if li > 0: line &= ","
            line &= $cast[int32](locBase[ls + li] and 0xFFFFFFFF'u64)
          line &= "]"
          # Dump label stack for branch instructions
          if instr.op in {opBr, opBrIf, opBrTable}:
            line &= " labels["
            let lstart = vm.callStack[vm.callStackTop - 1].labelStackStart
            for li in lstart ..< vm.labelStackTop:
              if li > lstart: line &= ","
              let l = vm.labelStack[li]
              line &= (if l.isLoop: "L" else: "B") & "(" & $l.pc & ")"
            line &= "]"
          echo line

    {.computedGoto.}
    case instr.op
    # ===== Control =====
    of opUnreachable:
      trap("unreachable executed")

    of opNop:
      discard

    of opBlock:
      let resultArity = vm.blockResultArity(instr.pad, cachedModIdx)
      let paramArity = vm.blockParamArity(instr.pad, cachedModIdx)
      # imm1 = index of matching end instruction
      let endIdx = instr.imm1.int
      let sh = sp - paramArity
      vm.pushLabel(Label(
        arity: resultArity,
        pc: endIdx + 1,  # continuation is after end
        stackHeight: sh,
        isLoop: false,
        catchTableIdx: -1
      ))

    of opLoop:
      let paramArity = vm.blockParamArity(instr.pad, cachedModIdx)
      let loopStart = cachedPc  # already advanced past the loop instruction
      let sh = sp - paramArity
      vm.pushLabel(Label(
        arity: paramArity,  # loop branches to start, arity = params
        pc: loopStart,
        stackHeight: sh,
        isLoop: true,
        catchTableIdx: -1
      ))

    of opIf:
      let cond = spopI32()
      let resultArity = vm.blockResultArity(instr.pad, cachedModIdx)
      let paramArity = vm.blockParamArity(instr.pad, cachedModIdx)
      let endIdx = instr.imm1.int
      let elseIdx = instr.imm2.int
      let sh = sp - paramArity
      if cond == 0 and elseIdx == endIdx:
        # No else clause and condition is false: skip entire if block
        # Don't push a label — we jump past the end, so opEnd won't pop it
        cachedPc = endIdx + 1
      else:
        vm.pushLabel(Label(
          arity: resultArity,
          pc: endIdx + 1,
          stackHeight: sh,
          isLoop: false,
          catchTableIdx: -1
        ))
        if cond == 0:
          # Jump to else clause
          cachedPc = elseIdx + 1

    of opElse:
      # We're in the then-branch; pop the if label and jump past end.
      # The else-path never reaches opElse (opIf jumps directly to elseIdx+1),
      # so opEnd won't see this label again.
      let lbl = vm.popLabel()
      cachedPc = lbl.pc  # jump to end+1

    of opEnd:
      if vm.labelStackTop > vm.callStack[vm.callStackTop - 1].labelStackStart:
        discard vm.popLabel()
      else:
        # End of function body — return
        let curFrame = vm.callStack[vm.callStackTop - 1]
        let arity = curFrame.returnArity
        vm.localsTop = curFrame.localsStart
        vm.labelStackTop = curFrame.labelStackStart
        dec vm.callStackTop  # inline popFrame

        # Restore stack: keep only the arity return values
        if arity == 0:
          discard  # nothing to do
        elif arity == 1:
          # Single return: move it to the label's stack height
          let retVal = vsBase[sp - 1]
          sp = vm.labelStack[curFrame.labelStackStart].stackHeight
          vsBase[sp] = retVal
          inc sp
        else:
          var rets: array[128, uint64]
          for ri in countdown(arity - 1, 0):
            dec sp
            rets[ri] = vsBase[sp]
          sp = vm.labelStack[curFrame.labelStackStart].stackHeight
          for ri in 0 ..< arity:
            vsBase[sp] = rets[ri]
            inc sp

        if vm.callStackTop > entryCallStackTop:
          loadFrameCache()
          locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)
        continue

    of opBr:
      let depth = instr.imm1.int
      let targetLabelIdx = vm.labelStackTop - 1 - depth
      let targetLabel = vm.labelStack[targetLabelIdx]
      if targetLabel.arity == 0:
        sp = targetLabel.stackHeight
        if targetLabel.isLoop:
          vm.labelStackTop = targetLabelIdx + 1
          trackOsrBackEdge()
        else:
          vm.labelStackTop = targetLabelIdx
        cachedPc = targetLabel.pc
      elif targetLabel.arity == 1:
        let retVal = vsBase[sp - 1]
        sp = targetLabel.stackHeight + 1
        vsBase[targetLabel.stackHeight] = retVal
        if targetLabel.isLoop:
          vm.labelStackTop = targetLabelIdx + 1
          trackOsrBackEdge()
        else:
          vm.labelStackTop = targetLabelIdx
        cachedPc = targetLabel.pc
      else:
        syncSp()
        cachedPc = vm.doBranch(depth)
        sp = vm.valueStackTop
      continue

    of opBrIf:
      let cond = spopI32()
      if profiler != nil:
        profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, cond != 0)
      if cond != 0:
        let depth = instr.imm1.int
        let targetLabelIdx = vm.labelStackTop - 1 - depth
        let targetLabel = vm.labelStack[targetLabelIdx]
        if targetLabel.arity == 0:
          sp = targetLabel.stackHeight
          if targetLabel.isLoop:
            vm.labelStackTop = targetLabelIdx + 1
            trackOsrBackEdge()
          else:
            vm.labelStackTop = targetLabelIdx
          cachedPc = targetLabel.pc
        elif targetLabel.arity == 1:
          let retVal = vsBase[sp - 1]
          sp = targetLabel.stackHeight + 1
          vsBase[targetLabel.stackHeight] = retVal
          if targetLabel.isLoop:
            vm.labelStackTop = targetLabelIdx + 1
            trackOsrBackEdge()
          else:
            vm.labelStackTop = targetLabelIdx
          cachedPc = targetLabel.pc
        else:
          syncSp()
          cachedPc = vm.doBranch(depth)
          sp = vm.valueStackTop
        continue

    of opBrTable:
      let idx = spopI32()
      let btData = cachedBrTables[][instr.imm1.int]
      let target = if idx >= 0 and idx.int < btData.labels.len: btData.labels[idx.int]
                   else: btData.defaultLabel
      syncSp()
      cachedPc = vm.doBranch(target.int)
      sp = vm.valueStackTop
      continue

    of opReturn:
      let curFrame = vm.callStack[vm.callStackTop - 1]
      let arity = curFrame.returnArity
      let labelSh = vm.labelStack[curFrame.labelStackStart].stackHeight
      if arity == 1:
        let retVal = vsBase[sp - 1]
        sp = labelSh
        vsBase[sp] = retVal
        inc sp
      elif arity == 0:
        sp = labelSh
      else:
        var results: array[128, uint64]
        for i in countdown(arity - 1, 0):
          dec sp
          results[i] = vsBase[sp]
        sp = labelSh
        for i in 0 ..< arity:
          vsBase[sp] = results[i]
          inc sp
      vm.localsTop = curFrame.localsStart
      vm.labelStackTop = curFrame.labelStackStart
      dec vm.callStackTop
      if vm.callStackTop <= entryCallStackTop:
        break
      # Fast path: if parent frame is the same function (self-recursive return),
      # only restore the 2 varying fields (pc, localsStart). Skip 5 invariant
      # loads (code, codeLen, brTables, moduleIdx, funcAddr).
      if vm.callStack[vm.callStackTop - 1].funcAddr == cachedFuncAddr:
        loadFrameCacheFast()
      else:
        loadFrameCache()
      locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)
      continue

    of opCall:
      # pad=1 means imm1 is already the direct store index (pre-resolved)
      let calleeAddr = if instr.pad == 1: instr.imm1.int
                        else: vm.store.modules[cachedModIdx].funcAddrs[instr.imm1.int]

      # Self-recursive call fast path: skip store.funcs lookup, skip invariant
      # Frame/Label field writes, skip redundant loadFrameCache fields.
      # The self-call cache (sc*) is populated on the first self-call and
      # reused on subsequent calls to the same function.
      if calleeAddr == cachedFuncAddr and scParamCount >= 0:
        let newLocalsStart = vm.localsTop
        let needed = newLocalsStart + scTotalLocals

        if unlikely(needed > vm.locals.len):
          vm.locals.setLen(needed * 2)
          locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)

        sp -= scParamCount
        for i in 0 ..< scParamCount:
          locBase[newLocalsStart + i] = vsBase[sp + i]
        for i in scParamCount ..< scTotalLocals:
          locBase[newLocalsStart + i] = 0'u64
        vm.localsTop = needed

        # Save caller pc; write only varying Frame fields
        vm.callStack[vm.callStackTop - 1].pc = cachedPc
        vm.callStack[vm.callStackTop] = Frame(
          pc: 0,
          code: scCode,
          brTables: scCode[].brTables.addr,
          localsStart: newLocalsStart,
          localsCount: scTotalLocals,
          labelStackStart: vm.labelStackTop,
          returnArity: scReturnArity,
          moduleIdx: cachedModIdx,
          funcAddr: calleeAddr
        )
        inc vm.callStackTop

        vm.labelStack[vm.labelStackTop] = Label(
          arity: scReturnArity,
          pc: scCodeLen,
          stackHeight: sp,
          isLoop: false,
          catchTableIdx: -1
        )
        inc vm.labelStackTop

        # Only update varying cached fields (code/brTables/moduleIdx/funcAddr unchanged)
        cachedPc = 0
        cachedLocalsStart = newLocalsStart
        continue

      # Cursor avoids copying FuncInst (which has seq fields that trigger
      # atomic refcount ops under --mm:atomicArc on every call)
      let callee {.cursor.} = vm.store.funcs[calleeAddr]

      if unlikely(callee.isHost):
        let nParams = callee.funcType.params.len
        var hostArgs = newSeq[WasmValue](nParams)
        for i in countdown(nParams - 1, 0):
          hostArgs[i] = rawToWasmValue(spop(), callee.funcType.params[i])
        syncSp()
        let hostResults = callee.hostFunc(hostArgs)
        sp = vm.valueStackTop
        for r in hostResults:
          spush(wasmValueToRaw(r))
      else:
        let paramCount = callee.funcType.params.len
        let newLocalsStart = vm.localsTop
        let newTotalLocals = callee.localTypes.len
        let calleeCode = callee.code
        let returnArity = callee.funcType.results.len
        let calleeModIdx = callee.moduleIdx
        let needed = newLocalsStart + newTotalLocals

        # Ensure locals capacity (single check)
        if unlikely(needed > vm.locals.len):
          vm.locals.setLen(needed * 2)
          locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)

        # Pop args directly into locals (no temp array)
        sp -= paramCount
        for i in 0 ..< paramCount:
          locBase[newLocalsStart + i] = vsBase[sp + i]
        for i in paramCount ..< newTotalLocals:
          locBase[newLocalsStart + i] = 0'u64
        vm.localsTop = needed

        # Populate self-call cache if this is a self-recursive call
        if calleeAddr == cachedFuncAddr:
          scParamCount = paramCount
          scTotalLocals = newTotalLocals
          scReturnArity = returnArity
          scCode = calleeCode
          scCodeLen = calleeCode[].code.len
        else:
          scParamCount = -1  # invalidate: entering a different function

        # Save caller pc, push frame inline (skip pushFrame proc overhead)
        vm.callStack[vm.callStackTop - 1].pc = cachedPc
        vm.callStack[vm.callStackTop] = Frame(
          pc: 0,
          code: calleeCode,
          brTables: calleeCode[].brTables.addr,
          localsStart: newLocalsStart,
          localsCount: newTotalLocals,
          labelStackStart: vm.labelStackTop,
          returnArity: returnArity,
          moduleIdx: calleeModIdx,
          funcAddr: calleeAddr
        )
        inc vm.callStackTop

        # Push label inline
        vm.labelStack[vm.labelStackTop] = Label(
          arity: returnArity,
          pc: calleeCode[].code.len,
          stackHeight: sp,
          isLoop: false,
          catchTableIdx: -1
        )
        inc vm.labelStackTop

        # Inline loadFrameCache for callee
        cachedCode = cast[ptr UncheckedArray[Instr]](calleeCode[].code[0].addr)
        cachedCodeLen = calleeCode[].code.len
        cachedPc = 0
        cachedModIdx = calleeModIdx
        cachedLocalsStart = newLocalsStart
        cachedBrTables = calleeCode[].brTables.addr
        cachedFuncAddr = calleeAddr
        continue

    of opCallIndirect:
      let typeIdx = instr.imm1.int
      let tableIdx = instr.imm2.int
      let modIdx = cachedModIdx
      let tableAddr = vm.store.modules[modIdx].tableAddrs[tableIdx]
      let elemIdx = spopI32()
      if elemIdx < 0 or elemIdx.int >= vm.store.tables[tableAddr].elems.len:
        trap("undefined element")

      # --- 2-way associative inline cache ---
      # Key encodes the call site uniquely: upper 32 bits = funcAddr,
      # lower 32 bits = PC of this call_indirect instruction.
      # 512-slot 2-way: hash selects the slot; both entries are checked in order.
      let icKey  = (cachedFuncAddr.uint64 shl 32) or (cachedPc - 1).uint32.uint64
      let icSlot = (icKey and 511'u64).int
      var calleeAddr: int
      var skipTypeCheck = false
      block icCheck:
        # Check entry A first, then entry B.
        template tryEntry(entry: CallIcEntry) =
          if entry.key == icKey and entry.elemIdx == elemIdx:
            let cachedCallee = entry.calleeAddr.int
            let elem2 = vm.store.tables[tableAddr].elems[elemIdx.int]
            if elem2.kind == wvkFuncRef and elem2.funcRef == cachedCallee:
              calleeAddr = cachedCallee
              skipTypeCheck = true
              break icCheck
        tryEntry(vm.callIcBuf[icSlot].a)
        tryEntry(vm.callIcBuf[icSlot].b)
      if not skipTypeCheck:
        let elem = vm.store.tables[tableAddr].elems[elemIdx.int]
        if elem.kind != wvkFuncRef:
          trap("indirect call on non-funcref")
        if elem.funcRef < 0:
          trap("uninitialized element")
        calleeAddr = elem.funcRef.int
        if calleeAddr >= vm.store.funcs.len:
          trap("undefined function")
        let callee2 {.cursor.} = vm.store.funcs[calleeAddr]
        let expectedType {.cursor.} = vm.store.modules[modIdx].types[typeIdx]
        if callee2.funcType.params.len != expectedType.params.len or
           callee2.funcType.results.len != expectedType.results.len:
          trap("indirect call type mismatch")
        for i in 0 ..< expectedType.params.len:
          if callee2.funcType.params[i] != expectedType.params[i]:
            trap("indirect call type mismatch")
        for i in 0 ..< expectedType.results.len:
          if callee2.funcType.results[i] != expectedType.results[i]:
            trap("indirect call type mismatch")
        # Update the LRU entry: evictB toggles on each miss so both entries age fairly.
        let newEntry = CallIcEntry(key: icKey, elemIdx: elemIdx,
                                   calleeAddr: calleeAddr.int32)
        if vm.callIcBuf[icSlot].evictB:
          vm.callIcBuf[icSlot].b = newEntry
        else:
          vm.callIcBuf[icSlot].a = newEntry
        vm.callIcBuf[icSlot].evictB = not vm.callIcBuf[icSlot].evictB

      let callee {.cursor.} = vm.store.funcs[calleeAddr]

      # Record call_indirect target for PGO before dispatching.
      if profiler != nil:
        profiler[].recordCallIndirect(cachedFuncAddr, cachedPc - 1, calleeAddr.int32)

      if callee.isHost:
        let nParams = callee.funcType.params.len
        var hostArgs = newSeq[WasmValue](nParams)
        for i in countdown(nParams - 1, 0):
          hostArgs[i] = rawToWasmValue(spop(), callee.funcType.params[i])
        syncSp()
        let hostResults = callee.hostFunc(hostArgs)
        sp = vm.valueStackTop
        for r in hostResults:
          spush(wasmValueToRaw(r))
      else:
        let paramCount = callee.funcType.params.len
        let newLocalsStart = vm.localsTop
        let newTotalLocals = callee.localTypes.len
        let calleeCode = callee.code
        let returnArity = callee.funcType.results.len
        let calleeModIdx = callee.moduleIdx
        let needed = newLocalsStart + newTotalLocals

        # Ensure locals capacity (single check)
        if unlikely(needed > vm.locals.len):
          vm.locals.setLen(needed * 2)
          locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)

        # Pop args directly into locals (no temp array — same as opCall)
        sp -= paramCount
        for i in 0 ..< paramCount:
          locBase[newLocalsStart + i] = vsBase[sp + i]
        for i in paramCount ..< newTotalLocals:
          locBase[newLocalsStart + i] = 0'u64
        vm.localsTop = needed

        # Save caller pc, push frame inline (skip pushFrame proc overhead)
        vm.callStack[vm.callStackTop - 1].pc = cachedPc
        vm.callStack[vm.callStackTop] = Frame(
          pc: 0,
          code: calleeCode,
          brTables: calleeCode[].brTables.addr,
          localsStart: newLocalsStart,
          localsCount: newTotalLocals,
          labelStackStart: vm.labelStackTop,
          returnArity: returnArity,
          moduleIdx: calleeModIdx,
          funcAddr: calleeAddr
        )
        inc vm.callStackTop

        # Push label inline
        vm.labelStack[vm.labelStackTop] = Label(
          arity: returnArity,
          pc: calleeCode[].code.len,
          stackHeight: sp,
          isLoop: false,
          catchTableIdx: -1
        )
        inc vm.labelStackTop

        # Inline loadFrameCache for callee
        cachedCode = cast[ptr UncheckedArray[Instr]](calleeCode[].code[0].addr)
        cachedCodeLen = calleeCode[].code.len
        cachedPc = 0
        cachedModIdx = calleeModIdx
        cachedLocalsStart = newLocalsStart
        cachedBrTables = calleeCode[].brTables.addr
        cachedFuncAddr = calleeAddr
        continue

    # ===== Parametric =====
    of opDrop:
      discard spop()

    of opSelect:
      let cond = spopI32()
      let val2 = spop()
      let val1 = spop()
      if cond != 0:
        spush(val1)
      else:
        spush(val2)

    of opSelectTyped:
      # Same as select but with explicit type
      let cond = spopI32()
      let val2 = spop()
      let val1 = spop()
      if cond != 0:
        spush(val1)
      else:
        spush(val2)

    # ===== Variable =====
    of opLocalGet:
      spush(locBase[cachedLocalsStart + instr.imm1.int])

    of opLocalSet:
      locBase[cachedLocalsStart + instr.imm1.int] = spop()

    of opLocalTee:
      locBase[cachedLocalsStart + instr.imm1.int] = speek()

    of opGlobalGet:
      let modIdx = cachedModIdx
      let globalIdx = instr.imm1.int
      let globalAddr = vm.store.modules[modIdx].globalAddrs[globalIdx]
      spush(wasmValueToRaw(vm.store.globals[globalAddr].value))

    of opGlobalSet:
      let modIdx = cachedModIdx
      let globalIdx = instr.imm1.int
      let globalAddr = vm.store.modules[modIdx].globalAddrs[globalIdx]
      if vm.store.globals[globalAddr].globalType.mut != mutVar:
        trap("cannot set immutable global")
      vm.store.globals[globalAddr].value = rawToWasmValue(spop(), vm.store.globals[globalAddr].globalType.valType)

    # ===== Table =====
    of opTableGet:
      let modIdx = cachedModIdx
      let tableIdx = instr.imm1.int
      let tableAddr = vm.store.modules[modIdx].tableAddrs[tableIdx]
      let idx = spopI32()
      if idx < 0 or idx.int >= vm.store.tables[tableAddr].elems.len:
        trap("out of bounds table access")
      spush(wasmValueToRaw(vm.store.tables[tableAddr].elems[idx.int]))

    of opTableSet:
      let modIdx = cachedModIdx
      let tableIdx = instr.imm1.int
      let tableAddr = vm.store.modules[modIdx].tableAddrs[tableIdx]
      let rawVal = spop()
      let idx = spopI32()
      if idx < 0 or idx.int >= vm.store.tables[tableAddr].elems.len:
        trap("out of bounds table access")
      vm.store.tables[tableAddr].elems[idx.int] = rawToWasmValue(rawVal, vm.store.tables[tableAddr].tableType.elemType)

    # ===== Memory load/store =====
    of opI32Load:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI32(loadVal[int32](vm.getMem(cachedModIdx), ea))

    of opI64Load:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI64(loadVal[int64](vm.getMem(cachedModIdx), ea))

    of opF32Load:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushF32(loadVal[float32](vm.getMem(cachedModIdx), ea))

    of opF64Load:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushF64(loadVal[float64](vm.getMem(cachedModIdx), ea))

    of opI32Load8S:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI32(int32(loadVal[int8](vm.getMem(cachedModIdx), ea)))

    of opI32Load8U:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI32(int32(loadVal[uint8](vm.getMem(cachedModIdx), ea)))

    of opI32Load16S:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI32(int32(loadVal[int16](vm.getMem(cachedModIdx), ea)))

    of opI32Load16U:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI32(int32(loadVal[uint16](vm.getMem(cachedModIdx), ea)))

    of opI64Load8S:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI64(int64(loadVal[int8](vm.getMem(cachedModIdx), ea)))

    of opI64Load8U:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI64(int64(loadVal[uint8](vm.getMem(cachedModIdx), ea)))

    of opI64Load16S:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI64(int64(loadVal[int16](vm.getMem(cachedModIdx), ea)))

    of opI64Load16U:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI64(int64(loadVal[uint16](vm.getMem(cachedModIdx), ea)))

    of opI64Load32S:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI64(int64(loadVal[int32](vm.getMem(cachedModIdx), ea)))

    of opI64Load32U:
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      spushI64(int64(loadVal[uint32](vm.getMem(cachedModIdx), ea)))

    of opI32Store:
      let val = spopI32()
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      storeVal[int32](vm.getMem(cachedModIdx), ea, val)

    of opI64Store:
      let val = spopI64()
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      storeVal[int64](vm.getMem(cachedModIdx), ea, val)

    of opF32Store:
      let val = spopF32()
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      storeVal[float32](vm.getMem(cachedModIdx), ea, val)

    of opF64Store:
      let val = spopF64()
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      storeVal[float64](vm.getMem(cachedModIdx), ea, val)

    of opI32Store8:
      let val = spopI32()
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      storeVal[uint8](vm.getMem(cachedModIdx), ea, uint8(val and 0xFF))

    of opI32Store16:
      let val = spopI32()
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      storeVal[uint16](vm.getMem(cachedModIdx), ea, uint16(val and 0xFFFF))

    of opI64Store8:
      let val = spopI64()
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      storeVal[uint8](vm.getMem(cachedModIdx), ea, uint8(val and 0xFF))

    of opI64Store16:
      let val = spopI64()
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      storeVal[uint16](vm.getMem(cachedModIdx), ea, uint16(val and 0xFFFF))

    of opI64Store32:
      let val = spopI64()
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm1.uint64
      storeVal[uint32](vm.getMem(cachedModIdx), ea, uint32(val and 0xFFFFFFFF))

    of opMemorySize:
      let mem = vm.getMem(cachedModIdx)
      when defined(wasmGuardPages):
        if mem.useGuard:
          spushI32(int32(mem.guardMem.accessibleBytes div WasmPageSize.uint64))
        else:
          spushI32(int32(mem.data.len div WasmPageSize))
      else:
        spushI32(int32(mem.data.len div WasmPageSize))

    of opMemoryGrow:
      let delta = spopI32()
      let memAddr = vm.store.modules[cachedModIdx].memAddrs[0]
      when defined(wasmGuardPages):
        if vm.store.mems[memAddr].useGuard:
          let oldPages = int(vm.store.mems[memAddr].guardMem.accessibleBytes div WasmPageSize.uint64)
          let newPages = oldPages + delta.int
          if delta < 0 or not growGuardedMem(vm.store.mems[memAddr].guardMem, newPages):
            spushI32(-1)
          else:
            spushI32(int32(oldPages))
        else:
          let oldPages = vm.store.mems[memAddr].data.len div WasmPageSize
          let newPages = oldPages + delta.int
          let maxPages = if vm.store.mems[memAddr].memType.limits.hasMax:
                           vm.store.mems[memAddr].memType.limits.max.int
                         else:
                           MaxPages
          if delta < 0 or newPages > maxPages or newPages > MaxPages:
            spushI32(-1)
          else:
            vm.store.mems[memAddr].data.setLen(newPages * WasmPageSize)
            spushI32(int32(oldPages))
      else:
        let oldPages = vm.store.mems[memAddr].data.len div WasmPageSize
        let newPages = oldPages + delta.int
        let maxPages = if vm.store.mems[memAddr].memType.limits.hasMax:
                         vm.store.mems[memAddr].memType.limits.max.int
                       else:
                         MaxPages
        if delta < 0 or newPages > maxPages or newPages > MaxPages:
          spushI32(-1)
        else:
          vm.store.mems[memAddr].data.setLen(newPages * WasmPageSize)
          spushI32(int32(oldPages))

    # ===== Constants =====
    of opI32Const:
      spushI32(cast[int32](instr.imm1))

    of opI64Const:
      let u = uint64(instr.imm1) or (uint64(instr.imm2) shl 32)
      spushI64(cast[int64](u))

    of opF32Const:
      spushF32(cast[float32](instr.imm1))

    of opF64Const:
      let u = uint64(instr.imm1) or (uint64(instr.imm2) shl 32)
      spushF64(cast[float64](u))

    # ===== i32 comparison =====
    of opI32Eqz:
      let a = spopI32()
      spushI32(if a == 0: 1'i32 else: 0'i32)

    of opI32Eq:
      let b = spopI32(); let a = spopI32()
      spushI32(if a == b: 1'i32 else: 0'i32)

    of opI32Ne:
      let b = spopI32(); let a = spopI32()
      spushI32(if a != b: 1'i32 else: 0'i32)

    of opI32LtS:
      let b = spopI32(); let a = spopI32()
      spushI32(if a < b: 1'i32 else: 0'i32)

    of opI32LtU:
      let b = spopI32(); let a = spopI32()
      spushI32(if cast[uint32](a) < cast[uint32](b): 1'i32 else: 0'i32)

    of opI32GtS:
      let b = spopI32(); let a = spopI32()
      spushI32(if a > b: 1'i32 else: 0'i32)

    of opI32GtU:
      let b = spopI32(); let a = spopI32()
      spushI32(if cast[uint32](a) > cast[uint32](b): 1'i32 else: 0'i32)

    of opI32LeS:
      let b = spopI32(); let a = spopI32()
      spushI32(if a <= b: 1'i32 else: 0'i32)

    of opI32LeU:
      let b = spopI32(); let a = spopI32()
      spushI32(if cast[uint32](a) <= cast[uint32](b): 1'i32 else: 0'i32)

    of opI32GeS:
      let b = spopI32(); let a = spopI32()
      spushI32(if a >= b: 1'i32 else: 0'i32)

    of opI32GeU:
      let b = spopI32(); let a = spopI32()
      spushI32(if cast[uint32](a) >= cast[uint32](b): 1'i32 else: 0'i32)

    # ===== i64 comparison =====
    of opI64Eqz:
      let a = spopI64()
      spushI32(if a == 0: 1'i32 else: 0'i32)

    of opI64Eq:
      let b = spopI64(); let a = spopI64()
      spushI32(if a == b: 1'i32 else: 0'i32)

    of opI64Ne:
      let b = spopI64(); let a = spopI64()
      spushI32(if a != b: 1'i32 else: 0'i32)

    of opI64LtS:
      let b = spopI64(); let a = spopI64()
      spushI32(if a < b: 1'i32 else: 0'i32)

    of opI64LtU:
      let b = spopI64(); let a = spopI64()
      spushI32(if cast[uint64](a) < cast[uint64](b): 1'i32 else: 0'i32)

    of opI64GtS:
      let b = spopI64(); let a = spopI64()
      spushI32(if a > b: 1'i32 else: 0'i32)

    of opI64GtU:
      let b = spopI64(); let a = spopI64()
      spushI32(if cast[uint64](a) > cast[uint64](b): 1'i32 else: 0'i32)

    of opI64LeS:
      let b = spopI64(); let a = spopI64()
      spushI32(if a <= b: 1'i32 else: 0'i32)

    of opI64LeU:
      let b = spopI64(); let a = spopI64()
      spushI32(if cast[uint64](a) <= cast[uint64](b): 1'i32 else: 0'i32)

    of opI64GeS:
      let b = spopI64(); let a = spopI64()
      spushI32(if a >= b: 1'i32 else: 0'i32)

    of opI64GeU:
      let b = spopI64(); let a = spopI64()
      spushI32(if cast[uint64](a) >= cast[uint64](b): 1'i32 else: 0'i32)

    # ===== f32 comparison =====
    of opF32Eq:
      let b = spopF32(); let a = spopF32()
      spushI32(if a == b: 1'i32 else: 0'i32)

    of opF32Ne:
      let b = spopF32(); let a = spopF32()
      spushI32(if a != b: 1'i32 else: 0'i32)

    of opF32Lt:
      let b = spopF32(); let a = spopF32()
      spushI32(if a < b: 1'i32 else: 0'i32)

    of opF32Gt:
      let b = spopF32(); let a = spopF32()
      spushI32(if a > b: 1'i32 else: 0'i32)

    of opF32Le:
      let b = spopF32(); let a = spopF32()
      spushI32(if a <= b: 1'i32 else: 0'i32)

    of opF32Ge:
      let b = spopF32(); let a = spopF32()
      spushI32(if a >= b: 1'i32 else: 0'i32)

    # ===== f64 comparison =====
    of opF64Eq:
      let b = spopF64(); let a = spopF64()
      spushI32(if a == b: 1'i32 else: 0'i32)

    of opF64Ne:
      let b = spopF64(); let a = spopF64()
      spushI32(if a != b: 1'i32 else: 0'i32)

    of opF64Lt:
      let b = spopF64(); let a = spopF64()
      spushI32(if a < b: 1'i32 else: 0'i32)

    of opF64Gt:
      let b = spopF64(); let a = spopF64()
      spushI32(if a > b: 1'i32 else: 0'i32)

    of opF64Le:
      let b = spopF64(); let a = spopF64()
      spushI32(if a <= b: 1'i32 else: 0'i32)

    of opF64Ge:
      let b = spopF64(); let a = spopF64()
      spushI32(if a >= b: 1'i32 else: 0'i32)

    # ===== i32 arithmetic =====
    of opI32Clz:
      let a = spopI32()
      spushI32(int32(countLeadingZeroBits(cast[uint32](a))))

    of opI32Ctz:
      let a = spopI32()
      spushI32(int32(countTrailingZeroBits(cast[uint32](a))))

    of opI32Popcnt:
      let a = spopI32()
      spushI32(int32(popcount(cast[uint32](a))))

    of opI32Add:
      let b = spopI32(); let a = spopI32()
      spushI32(a +% b)

    of opI32Sub:
      let b = spopI32(); let a = spopI32()
      spushI32(a -% b)

    of opI32Mul:
      let b = spopI32(); let a = spopI32()
      spushI32(a *% b)

    of opI32DivS:
      let b = spopI32(); let a = spopI32()
      if b == 0: trap("integer divide by zero")
      if a == int32.low and b == -1'i32: trap("integer overflow")
      spushI32(a div b)

    of opI32DivU:
      let b = spopI32(); let a = spopI32()
      if b == 0: trap("integer divide by zero")
      spushI32(cast[int32](cast[uint32](a) div cast[uint32](b)))

    of opI32RemS:
      let b = spopI32(); let a = spopI32()
      if b == 0: trap("integer divide by zero")
      if a == int32.low and b == -1'i32:
        spushI32(0'i32)
      else:
        spushI32(a mod b)

    of opI32RemU:
      let b = spopI32(); let a = spopI32()
      if b == 0: trap("integer divide by zero")
      spushI32(cast[int32](cast[uint32](a) mod cast[uint32](b)))

    of opI32And:
      let b = spopI32(); let a = spopI32()
      spushI32(a and b)

    of opI32Or:
      let b = spopI32(); let a = spopI32()
      spushI32(a or b)

    of opI32Xor:
      let b = spopI32(); let a = spopI32()
      spushI32(a xor b)

    of opI32Shl:
      let b = spopI32(); let a = spopI32()
      spushI32(cast[int32](cast[uint32](a) shl (cast[uint32](b) and 31)))

    of opI32ShrS:
      let b = spopI32(); let a = spopI32()
      spushI32(ashr(a, b and 31))

    of opI32ShrU:
      let b = spopI32(); let a = spopI32()
      spushI32(cast[int32](cast[uint32](a) shr (cast[uint32](b) and 31)))

    of opI32Rotl:
      let b = spopI32(); let a = spopI32()
      spushI32(cast[int32](rotl32(cast[uint32](a), cast[uint32](b))))

    of opI32Rotr:
      let b = spopI32(); let a = spopI32()
      spushI32(cast[int32](rotr32(cast[uint32](a), cast[uint32](b))))

    # ===== i64 arithmetic =====
    of opI64Clz:
      let a = spopI64()
      spushI64(int64(countLeadingZeroBits(cast[uint64](a))))

    of opI64Ctz:
      let a = spopI64()
      spushI64(int64(countTrailingZeroBits(cast[uint64](a))))

    of opI64Popcnt:
      let a = spopI64()
      spushI64(int64(popcount(cast[uint64](a))))

    of opI64Add:
      let b = spopI64(); let a = spopI64()
      spushI64(a +% b)

    of opI64Sub:
      let b = spopI64(); let a = spopI64()
      spushI64(a -% b)

    of opI64Mul:
      let b = spopI64(); let a = spopI64()
      spushI64(a *% b)

    of opI64DivS:
      let b = spopI64(); let a = spopI64()
      if b == 0: trap("integer divide by zero")
      if a == int64.low and b == -1'i64: trap("integer overflow")
      spushI64(a div b)

    of opI64DivU:
      let b = spopI64(); let a = spopI64()
      if b == 0: trap("integer divide by zero")
      spushI64(cast[int64](cast[uint64](a) div cast[uint64](b)))

    of opI64RemS:
      let b = spopI64(); let a = spopI64()
      if b == 0: trap("integer divide by zero")
      if a == int64.low and b == -1'i64:
        spushI64(0'i64)
      else:
        spushI64(a mod b)

    of opI64RemU:
      let b = spopI64(); let a = spopI64()
      if b == 0: trap("integer divide by zero")
      spushI64(cast[int64](cast[uint64](a) mod cast[uint64](b)))

    of opI64And:
      let b = spopI64(); let a = spopI64()
      spushI64(a and b)

    of opI64Or:
      let b = spopI64(); let a = spopI64()
      spushI64(a or b)

    of opI64Xor:
      let b = spopI64(); let a = spopI64()
      spushI64(a xor b)

    of opI64Shl:
      let b = spopI64(); let a = spopI64()
      spushI64(cast[int64](cast[uint64](a) shl (cast[uint64](b) and 63)))

    of opI64ShrS:
      let b = spopI64(); let a = spopI64()
      spushI64(ashr(a, int(b and 63)))

    of opI64ShrU:
      let b = spopI64(); let a = spopI64()
      spushI64(cast[int64](cast[uint64](a) shr (cast[uint64](b) and 63)))

    of opI64Rotl:
      let b = spopI64(); let a = spopI64()
      spushI64(cast[int64](rotl64(cast[uint64](a), cast[uint64](b))))

    of opI64Rotr:
      let b = spopI64(); let a = spopI64()
      spushI64(cast[int64](rotr64(cast[uint64](a), cast[uint64](b))))

    # ===== f32 arithmetic =====
    of opF32Abs:
      let a = spopF32()
      spushF32(abs(a))

    of opF32Neg:
      let a = spopF32()
      spushF32(-a)

    of opF32Ceil:
      let a = spopF32()
      spushF32(ceil(a))

    of opF32Floor:
      let a = spopF32()
      spushF32(floor(a))

    of opF32Trunc:
      let a = spopF32()
      spushF32(trunc(a))

    of opF32Nearest:
      let a = spopF32()
      spushF32(f32Nearest(a))

    of opF32Sqrt:
      let a = spopF32()
      spushF32(sqrt(a))

    of opF32Add:
      let b = spopF32(); let a = spopF32()
      spushF32(a + b)

    of opF32Sub:
      let b = spopF32(); let a = spopF32()
      spushF32(a - b)

    of opF32Mul:
      let b = spopF32(); let a = spopF32()
      spushF32(a * b)

    of opF32Div:
      let b = spopF32(); let a = spopF32()
      spushF32(a / b)

    of opF32Min:
      let b = spopF32(); let a = spopF32()
      spushF32(f32Min(a, b))

    of opF32Max:
      let b = spopF32(); let a = spopF32()
      spushF32(f32Max(a, b))

    of opF32Copysign:
      let b = spopF32(); let a = spopF32()
      spushF32(f32Copysign(a, b))

    # ===== f64 arithmetic =====
    of opF64Abs:
      let a = spopF64()
      spushF64(abs(a))

    of opF64Neg:
      let a = spopF64()
      spushF64(-a)

    of opF64Ceil:
      let a = spopF64()
      spushF64(ceil(a))

    of opF64Floor:
      let a = spopF64()
      spushF64(floor(a))

    of opF64Trunc:
      let a = spopF64()
      spushF64(trunc(a))

    of opF64Nearest:
      let a = spopF64()
      spushF64(f64Nearest(a))

    of opF64Sqrt:
      let a = spopF64()
      spushF64(sqrt(a))

    of opF64Add:
      let b = spopF64(); let a = spopF64()
      spushF64(a + b)

    of opF64Sub:
      let b = spopF64(); let a = spopF64()
      spushF64(a - b)

    of opF64Mul:
      let b = spopF64(); let a = spopF64()
      spushF64(a * b)

    of opF64Div:
      let b = spopF64(); let a = spopF64()
      spushF64(a / b)

    of opF64Min:
      let b = spopF64(); let a = spopF64()
      spushF64(f64Min(a, b))

    of opF64Max:
      let b = spopF64(); let a = spopF64()
      spushF64(f64Max(a, b))

    of opF64Copysign:
      let b = spopF64(); let a = spopF64()
      spushF64(f64Copysign(a, b))

    # ===== Conversions =====
    of opI32WrapI64:
      let a = spopI64()
      spushI32(cast[int32](a and 0xFFFFFFFF'i64))

    of opI32TruncF32S:
      let a = spopF32()
      spushI32(truncI32F32S(a))

    of opI32TruncF32U:
      let a = spopF32()
      spushI32(truncI32F32U(a))

    of opI32TruncF64S:
      let a = spopF64()
      spushI32(truncI32F64S(a))

    of opI32TruncF64U:
      let a = spopF64()
      spushI32(truncI32F64U(a))

    of opI64ExtendI32S:
      let a = spopI32()
      spushI64(int64(a))

    of opI64ExtendI32U:
      let a = spopI32()
      spushI64(int64(cast[uint32](a)))

    of opI64TruncF32S:
      let a = spopF32()
      spushI64(truncI64F32S(a))

    of opI64TruncF32U:
      let a = spopF32()
      spushI64(truncI64F32U(a))

    of opI64TruncF64S:
      let a = spopF64()
      spushI64(truncI64F64S(a))

    of opI64TruncF64U:
      let a = spopF64()
      spushI64(truncI64F64U(a))

    of opF32ConvertI32S:
      let a = spopI32()
      spushF32(float32(a))

    of opF32ConvertI32U:
      let a = spopI32()
      spushF32(float32(cast[uint32](a)))

    of opF32ConvertI64S:
      let a = spopI64()
      spushF32(float32(a))

    of opF32ConvertI64U:
      let a = spopI64()
      spushF32(float32(cast[uint64](a)))

    of opF32DemoteF64:
      let a = spopF64()
      spushF32(float32(a))

    of opF64ConvertI32S:
      let a = spopI32()
      spushF64(float64(a))

    of opF64ConvertI32U:
      let a = spopI32()
      spushF64(float64(cast[uint32](a)))

    of opF64ConvertI64S:
      let a = spopI64()
      spushF64(float64(a))

    of opF64ConvertI64U:
      let a = spopI64()
      spushF64(float64(cast[uint64](a)))

    of opF64PromoteF32:
      let a = spopF32()
      spushF64(float64(a))

    of opI32ReinterpretF32:
      let a = spopF32()
      spushI32(reinterpretF32AsI32(a))

    of opI64ReinterpretF64:
      let a = spopF64()
      spushI64(reinterpretF64AsI64(a))

    of opF32ReinterpretI32:
      let a = spopI32()
      spushF32(reinterpretI32AsF32(a))

    of opF64ReinterpretI64:
      let a = spopI64()
      spushF64(reinterpretI64AsF64(a))

    # ===== Sign extension =====
    of opI32Extend8S:
      let a = spopI32()
      spushI32(int32(int8(a and 0xFF)))

    of opI32Extend16S:
      let a = spopI32()
      spushI32(int32(int16(a and 0xFFFF)))

    of opI64Extend8S:
      let a = spopI64()
      spushI64(int64(int8(a and 0xFF)))

    of opI64Extend16S:
      let a = spopI64()
      spushI64(int64(int16(a and 0xFFFF)))

    of opI64Extend32S:
      let a = spopI64()
      spushI64(int64(int32(a and 0xFFFFFFFF'i64)))

    # ===== Reference =====
    of opRefNull:
      # Null refs are -1 as int32 -> 0xFFFFFFFF in low 32 bits
      # imm1 = refType ordinal
      let rtOrd = instr.imm1
      if rtOrd == uint32(ord(vtFuncRef)):
        spush(wasmValueToRaw(wasmNullFuncRef()))
      elif rtOrd == uint32(ord(vtExternRef)):
        spush(wasmValueToRaw(wasmNullExternRef()))
      else:
        trap("invalid ref.null type")

    of opRefIsNull:
      # Check if ref value is null (-1 in low 32 bits = 0xFFFFFFFF)
      let raw = spop()
      let asI32 = cast[int32](raw and 0xFFFFFFFF'u64)
      spushI32(if asI32 == -1: 1'i32 else: 0'i32)

    of opRefFunc:
      let modIdx = cachedModIdx
      let funcIdx = instr.imm1.int
      let funcAddr2 = vm.store.modules[modIdx].funcAddrs[funcIdx]
      spush(wasmValueToRaw(wasmFuncRef(funcAddr2.int32)))

    # ===== Saturating truncations =====
    of opI32TruncSatF32S:
      let a = spopF32()
      spushI32(truncSatI32F32S(a))

    of opI32TruncSatF32U:
      let a = spopF32()
      spushI32(truncSatI32F32U(a))

    of opI32TruncSatF64S:
      let a = spopF64()
      spushI32(truncSatI32F64S(a))

    of opI32TruncSatF64U:
      let a = spopF64()
      spushI32(truncSatI32F64U(a))

    of opI64TruncSatF32S:
      let a = spopF32()
      spushI64(truncSatI64F32S(a))

    of opI64TruncSatF32U:
      let a = spopF32()
      spushI64(truncSatI64F32U(a))

    of opI64TruncSatF64S:
      let a = spopF64()
      spushI64(truncSatI64F64S(a))

    of opI64TruncSatF64U:
      let a = spopF64()
      spushI64(truncSatI64F64U(a))

    # ===== Bulk memory =====
    of opMemoryInit:
      let modIdx = cachedModIdx
      let dataIdx = instr.imm1.int
      let memIdx = instr.imm2.int
      let n = cast[uint32](spopI32())
      let s = cast[uint32](spopI32())
      let d = cast[uint32](spopI32())
      let dataAddr = vm.store.modules[modIdx].dataAddrs[dataIdx]
      let dataInst = vm.store.datas[dataAddr]
      if dataInst.dropped:
        if n != 0:
          trap("out of bounds memory access")
      else:
        if s.uint64 + n.uint64 > dataInst.data.len.uint64:
          trap("out of bounds memory access")
      let memAddr = vm.store.modules[modIdx].memAddrs[memIdx]
      if d.uint64 + n.uint64 > vm.store.mems[memAddr].memByteLen():
        trap("out of bounds memory access")
      if n > 0:
        copyMem(vm.store.mems[memAddr].memBulkPtr(d.uint64),
                vm.store.datas[dataAddr].data[s.int].unsafeAddr,
                n.int)

    of opDataDrop:
      let modIdx = cachedModIdx
      let dataIdx = instr.imm1.int
      let dataAddr = vm.store.modules[modIdx].dataAddrs[dataIdx]
      vm.store.datas[dataAddr].dropped = true
      vm.store.datas[dataAddr].data = @[]

    of opMemoryCopy:
      let modIdx = cachedModIdx
      let dstMemIdx = instr.imm1.int
      let srcMemIdx = instr.imm2.int
      let n = cast[uint32](spopI32())
      let s = cast[uint32](spopI32())
      let d = cast[uint32](spopI32())
      let dstMemAddr = vm.store.modules[modIdx].memAddrs[dstMemIdx]
      let srcMemAddr = vm.store.modules[modIdx].memAddrs[srcMemIdx]
      if s.uint64 + n.uint64 > vm.store.mems[srcMemAddr].memByteLen():
        trap("out of bounds memory access")
      if d.uint64 + n.uint64 > vm.store.mems[dstMemAddr].memByteLen():
        trap("out of bounds memory access")
      if n > 0:
        if dstMemAddr == srcMemAddr:
          # Overlapping: use moveMem
          moveMem(vm.store.mems[dstMemAddr].memBulkPtr(d.uint64),
                  vm.store.mems[srcMemAddr].memBulkPtr(s.uint64),
                  n.int)
        else:
          copyMem(vm.store.mems[dstMemAddr].memBulkPtr(d.uint64),
                  vm.store.mems[srcMemAddr].memBulkPtr(s.uint64),
                  n.int)

    of opMemoryFill:
      let modIdx = cachedModIdx
      let memIdx = instr.imm1.int
      let n = cast[uint32](spopI32())
      let val = cast[uint8](spopI32() and 0xFF)
      let d = cast[uint32](spopI32())
      let memAddr = vm.store.modules[modIdx].memAddrs[memIdx]
      if d.uint64 + n.uint64 > vm.store.mems[memAddr].memByteLen():
        trap("out of bounds memory access")
      if n > 0:
        let dstPtr = vm.store.mems[memAddr].memBulkPtr(d.uint64)
        for i in 0'u32 ..< n:
          (cast[ptr byte](cast[uint64](dstPtr) + i.uint64))[] = val

    # ===== Table operations =====
    of opTableInit:
      let modIdx = cachedModIdx
      let elemIdx = instr.imm1.int
      let tableIdx = instr.imm2.int
      let n = cast[uint32](spopI32())
      let s = cast[uint32](spopI32())
      let d = cast[uint32](spopI32())
      let elemAddr = vm.store.modules[modIdx].elemAddrs[elemIdx]
      let tableAddr = vm.store.modules[modIdx].tableAddrs[tableIdx]
      let elemInst = vm.store.elems[elemAddr]
      if elemInst.dropped:
        if n != 0:
          trap("out of bounds table access")
      else:
        if s.uint64 + n.uint64 > elemInst.elems.len.uint64:
          trap("out of bounds table access")
      if d.uint64 + n.uint64 > vm.store.tables[tableAddr].elems.len.uint64:
        trap("out of bounds table access")
      for i in 0'u32 ..< n:
        vm.store.tables[tableAddr].elems[d.int + i.int] =
          vm.store.elems[elemAddr].elems[s.int + i.int]

    of opElemDrop:
      let modIdx = cachedModIdx
      let elemIdx = instr.imm1.int
      let elemAddr = vm.store.modules[modIdx].elemAddrs[elemIdx]
      vm.store.elems[elemAddr].dropped = true
      vm.store.elems[elemAddr].elems = @[]

    of opTableCopy:
      let modIdx = cachedModIdx
      let dstTableIdx = instr.imm1.int
      let srcTableIdx = instr.imm2.int
      let n = cast[uint32](spopI32())
      let s = cast[uint32](spopI32())
      let d = cast[uint32](spopI32())
      let dstTableAddr = vm.store.modules[modIdx].tableAddrs[dstTableIdx]
      let srcTableAddr = vm.store.modules[modIdx].tableAddrs[srcTableIdx]
      if s.uint64 + n.uint64 > vm.store.tables[srcTableAddr].elems.len.uint64:
        trap("out of bounds table access")
      if d.uint64 + n.uint64 > vm.store.tables[dstTableAddr].elems.len.uint64:
        trap("out of bounds table access")
      if n > 0:
        if d <= s:
          for i in 0'u32 ..< n:
            vm.store.tables[dstTableAddr].elems[d.int + i.int] =
              vm.store.tables[srcTableAddr].elems[s.int + i.int]
        else:
          for i in countdown(n.int - 1, 0):
            vm.store.tables[dstTableAddr].elems[d.int + i] =
              vm.store.tables[srcTableAddr].elems[s.int + i]

    of opTableGrow:
      let modIdx = cachedModIdx
      let tableIdx = instr.imm1.int
      let tableAddr = vm.store.modules[modIdx].tableAddrs[tableIdx]
      let n = cast[uint32](spopI32())
      let initVal = rawToWasmValue(spop(), vm.store.tables[tableAddr].tableType.elemType)
      let oldSize = vm.store.tables[tableAddr].elems.len
      let newSize = oldSize + n.int
      let maxSize = if vm.store.tables[tableAddr].tableType.limits.hasMax:
                      vm.store.tables[tableAddr].tableType.limits.max.int
                    else:
                      high(int)
      if newSize > maxSize:
        spushI32(-1'i32)
      else:
        let oldLen = vm.store.tables[tableAddr].elems.len
        vm.store.tables[tableAddr].elems.setLen(newSize)
        for i in oldLen ..< newSize:
          vm.store.tables[tableAddr].elems[i] = initVal
        vm.store.tables[tableAddr].tableType.limits.min = uint32(newSize)
        spushI32(int32(oldSize))

    of opTableSize:
      let modIdx = cachedModIdx
      let tableIdx = instr.imm1.int
      let tableAddr = vm.store.modules[modIdx].tableAddrs[tableIdx]
      spushI32(int32(vm.store.tables[tableAddr].elems.len))

    of opTableFill:
      let modIdx = cachedModIdx
      let tableIdx = instr.imm1.int
      let tableAddr = vm.store.modules[modIdx].tableAddrs[tableIdx]
      let n = cast[uint32](spopI32())
      let val = rawToWasmValue(spop(), vm.store.tables[tableAddr].tableType.elemType)
      let d = cast[uint32](spopI32())
      if d.uint64 + n.uint64 > vm.store.tables[tableAddr].elems.len.uint64:
        trap("out of bounds table access")
      for i in 0'u32 ..< n:
        vm.store.tables[tableAddr].elems[d.int + i.int] = val

    # ===== Fused superinstructions =====
    of opLocalGetLocalGet:
      # Push two locals in one dispatch
      let v1 = locBase[cachedLocalsStart + instr.imm1.int]
      let v2 = locBase[cachedLocalsStart + instr.imm2.int]
      spush(v1)
      spush(v2)

    of opLocalGetI32Add:
      # TOS = TOS + local[X]  (net sp change = 0 → peek/poke, skip resize check)
      let localVal = cast[int32](locBase[cachedLocalsStart + instr.imm1.int] and 0xFFFFFFFF'u64)
      let tos = cast[int32](vsBase[sp - 1] and 0xFFFFFFFF'u64)
      vsBase[sp - 1] = uint64(cast[uint32](tos + localVal))

    of opLocalGetI32Sub:
      # TOS = TOS - local[X]  (net sp change = 0)
      let localVal = cast[int32](locBase[cachedLocalsStart + instr.imm1.int] and 0xFFFFFFFF'u64)
      let tos = cast[int32](vsBase[sp - 1] and 0xFFFFFFFF'u64)
      vsBase[sp - 1] = uint64(cast[uint32](tos - localVal))

    of opI32ConstI32Add:
      # TOS = TOS + C  (net sp change = 0)
      let c = cast[int32](instr.imm1)
      let tos = cast[int32](vsBase[sp - 1] and 0xFFFFFFFF'u64)
      vsBase[sp - 1] = uint64(cast[uint32](tos + c))

    of opI32ConstI32Sub:
      # TOS = TOS - C  (net sp change = 0)
      let c = cast[int32](instr.imm1)
      let tos = cast[int32](vsBase[sp - 1] and 0xFFFFFFFF'u64)
      vsBase[sp - 1] = uint64(cast[uint32](tos - c))

    of opLocalSetLocalGet:
      # local[X] = pop; push local[Y]
      locBase[cachedLocalsStart + instr.imm1.int] = spop()
      spush(locBase[cachedLocalsStart + instr.imm2.int])

    of opLocalTeeLocalGet:
      # local[X] = peek; push local[Y]
      locBase[cachedLocalsStart + instr.imm1.int] = speek()
      spush(locBase[cachedLocalsStart + instr.imm2.int])

    of opLocalGetI32Const:
      # Push local[X] then push i32 const C
      spush(locBase[cachedLocalsStart + instr.imm1.int])
      spushI32(cast[int32](instr.imm2))

    of opI32AddLocalSet:
      # local[X] = pop + pop (i32.add then local.set)
      let b = spopI32()
      let a = spopI32()
      let r = a + b
      locBase[cachedLocalsStart + instr.imm1.int] = cast[uint64](r.int64) and 0xFFFFFFFF'u64

    of opI32SubLocalSet:
      # local[X] = pop - pop (i32.sub then local.set)
      let b = spopI32()
      let a = spopI32()
      let r = a - b
      locBase[cachedLocalsStart + instr.imm1.int] = cast[uint64](r.int64) and 0xFFFFFFFF'u64

    of opLocalGetI32Store:
      let localVal = locBase[cachedLocalsStart + instr.imm1.int]
      let base = cast[uint32](spopI32())
      let ea = base.uint64 + instr.imm2.uint64
      storeVal[int32](vm.getMem(cachedModIdx), ea, cast[int32](localVal and 0xFFFFFFFF'u64))

    of opLocalGetI32Load:
      # load mem[local[X] + offset]
      let base = cast[uint32](locBase[cachedLocalsStart + instr.imm1.int] and 0xFFFFFFFF'u64)
      let ea = base.uint64 + instr.imm2.uint64
      spushI32(loadVal[int32](vm.getMem(cachedModIdx), ea))

    of opI32ConstI32Eq:
      # TOS == C
      let a = spopI32()
      let c = cast[int32](instr.imm1)
      spushI32(if a == c: 1'i32 else: 0'i32)

    of opI32ConstI32Ne:
      # TOS != C
      let a = spopI32()
      let c = cast[int32](instr.imm1)
      spushI32(if a != c: 1'i32 else: 0'i32)

    of opLocalGetI32GtS:
      # TOS > local[X] (signed)
      let localVal = cast[int32](locBase[cachedLocalsStart + instr.imm1.int] and 0xFFFFFFFF'u64)
      let tos = spopI32()
      spushI32(if tos > localVal: 1'i32 else: 0'i32)

    of opI32ConstI32And:
      # TOS & C
      let a = spopI32()
      let c = cast[int32](instr.imm1)
      spushI32(a and c)

    of opI32ConstI32Mul:
      # TOS * C
      let a = spopI32()
      let c = cast[int32](instr.imm1)
      spushI32(a * c)

    of opLocalGetI32Mul:
      # TOS * local[X]
      let localVal = cast[int32](locBase[cachedLocalsStart + instr.imm1.int] and 0xFFFFFFFF'u64)
      let tos = spopI32()
      spushI32(tos * localVal)

    # ===== Triple fused superinstructions =====
    of opLocalGetLocalGetI32Add:
      # push(local[X] + local[Y])
      let a = cast[int32](locBase[cachedLocalsStart + instr.imm1.int] and 0xFFFFFFFF'u64)
      let b = cast[int32](locBase[cachedLocalsStart + instr.imm2.int] and 0xFFFFFFFF'u64)
      spushI32(a + b)

    of opLocalGetLocalGetI32Sub:
      let a = cast[int32](locBase[cachedLocalsStart + instr.imm1.int] and 0xFFFFFFFF'u64)
      let b = cast[int32](locBase[cachedLocalsStart + instr.imm2.int] and 0xFFFFFFFF'u64)
      spushI32(a - b)

    of opLocalGetI32ConstI32Sub:
      # push(local[X] - C)
      let a = cast[int32](locBase[cachedLocalsStart + instr.imm1.int] and 0xFFFFFFFF'u64)
      let c = cast[int32](instr.imm2)
      spushI32(a - c)

    of opLocalGetI32ConstI32Add:
      # push(local[X] + C)
      let a = cast[int32](locBase[cachedLocalsStart + instr.imm1.int] and 0xFFFFFFFF'u64)
      let c = cast[int32](instr.imm2)
      spushI32(a + c)

    of opLocalGetLocalTee:
      # Push local[X], then tee TOS to local[Y]
      spush(locBase[cachedLocalsStart + instr.imm1.int])
      locBase[cachedLocalsStart + instr.imm2.int] = speek()

    of opI32ConstI32GtU:
      # TOS > C (unsigned)  (net sp change = 0)
      let a = cast[uint32](vsBase[sp - 1] and 0xFFFFFFFF'u64)
      let c = instr.imm1
      vsBase[sp - 1] = uint64(if a > c: 1'u32 else: 0'u32)

    of opI32ConstI32LtS:
      # TOS < C (signed)  (net sp change = 0)
      let a = cast[int32](vsBase[sp - 1] and 0xFFFFFFFF'u64)
      let c = cast[int32](instr.imm1)
      vsBase[sp - 1] = uint64(if a < c: 1'u32 else: 0'u32)

    of opI32ConstI32GeS:
      # TOS >= C (signed)  (net sp change = 0)
      let a = cast[int32](vsBase[sp - 1] and 0xFFFFFFFF'u64)
      let c = cast[int32](instr.imm1)
      vsBase[sp - 1] = uint64(if a >= c: 1'u32 else: 0'u32)

    of opLocalGetI32LoadI32Add:
      # push(TOS + mem[local[X] + offset])
      let base = cast[uint32](locBase[cachedLocalsStart + instr.imm1.int] and 0xFFFFFFFF'u64)
      let ea = base.uint64 + instr.imm2.uint64
      let loaded = loadVal[int32](vm.getMem(cachedModIdx), ea)
      let tos = spopI32()
      spushI32(tos + loaded)

    of opI32EqzBrIf:
      # Branch if TOS == 0
      let v = spopI32()
      let taken = v == 0
      if profiler != nil:
        profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken:
        inlineBranch(instr.imm1.int)

    # ---- Binary comparison + br_if pairs (pop b, pop a, branch if condition) ----
    of opI32EqBrIf:
      let b = spopI32(); let a = spopI32()
      let taken = a == b
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm1.int)
    of opI32NeBrIf:
      let b = spopI32(); let a = spopI32()
      let taken = a != b
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm1.int)
    of opI32LtSBrIf:
      let b = spopI32(); let a = spopI32()
      let taken = a < b
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm1.int)
    of opI32GeSBrIf:
      let b = spopI32(); let a = spopI32()
      let taken = a >= b
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm1.int)
    of opI32GtSBrIf:
      let b = spopI32(); let a = spopI32()
      let taken = a > b
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm1.int)
    of opI32LeSBrIf:
      let b = spopI32(); let a = spopI32()
      let taken = a <= b
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm1.int)
    of opI32LtUBrIf:
      let b = cast[uint32](spopI32()); let a = cast[uint32](spopI32())
      let taken = a < b
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm1.int)
    of opI32GeUBrIf:
      let b = cast[uint32](spopI32()); let a = cast[uint32](spopI32())
      let taken = a >= b
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm1.int)
    of opI32GtUBrIf:
      let b = cast[uint32](spopI32()); let a = cast[uint32](spopI32())
      let taken = a > b
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm1.int)
    of opI32LeUBrIf:
      let b = cast[uint32](spopI32()); let a = cast[uint32](spopI32())
      let taken = a <= b
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm1.int)

    # ---- Triple: i32.const C; comparison; br_if L (imm1=C, imm2=L) ----
    of opI32ConstI32EqBrIf:
      let a = spopI32(); let c = cast[int32](instr.imm1)
      let taken = a == c
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm2.int)
    of opI32ConstI32NeBrIf:
      let a = spopI32(); let c = cast[int32](instr.imm1)
      let taken = a != c
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm2.int)
    of opI32ConstI32LtSBrIf:
      let a = spopI32(); let c = cast[int32](instr.imm1)
      let taken = a < c
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm2.int)
    of opI32ConstI32GeSBrIf:
      let a = spopI32(); let c = cast[int32](instr.imm1)
      let taken = a >= c
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm2.int)
    of opI32ConstI32GtUBrIf:
      let a = cast[uint32](spopI32()); let c = instr.imm1
      let taken = a > c
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm2.int)
    of opI32ConstI32LeUBrIf:
      let a = cast[uint32](spopI32()); let c = instr.imm1
      let taken = a <= c
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken: inlineBranch(instr.imm2.int)

    # ---- local.tee + br_if pair ----
    of opLocalTeeBrIf:
      # Semantics: local[X] = TOS; pop; branch if nonzero
      let val = spop()
      locBase[cachedLocalsStart + instr.imm1.int] = val
      let taken = cast[int32](val and 0xFFFFFFFF'u64) != 0
      if profiler != nil: profiler[].recordBranch(cachedFuncAddr, cachedPc - 1, taken)
      if taken:
        inlineBranch(instr.imm2.int)

    # ---- i64 local.get + arithmetic ----
    of opLocalGetI64Add:
      let v = cast[int64](locBase[cachedLocalsStart + instr.imm1.int])
      let tos = spopI64()
      spushI64(tos + v)
    of opLocalGetI64Sub:
      let v = cast[int64](locBase[cachedLocalsStart + instr.imm1.int])
      let tos = spopI64()
      spushI64(tos - v)

    # ---- Quad fusions ----
    of opLocalI32AddInPlace:
      # local[X] += C
      let idx = cachedLocalsStart + instr.imm1.int
      let c = cast[int32](instr.imm2)
      let cur = cast[int32](locBase[idx] and 0xFFFFFFFF'u64)
      locBase[idx] = uint64(cast[uint32](cur + c))
    of opLocalI32SubInPlace:
      # local[X] -= C
      let idx = cachedLocalsStart + instr.imm1.int
      let c = cast[int32](instr.imm2)
      let cur = cast[int32](locBase[idx] and 0xFFFFFFFF'u64)
      locBase[idx] = uint64(cast[uint32](cur - c))
    of opLocalGetLocalGetI32AddLocalSet:
      # Z = local[X] + local[Y]
      let x = int(instr.imm1 and 0xFFFF'u32)
      let y = int(instr.imm1 shr 16)
      let z = instr.imm2.int
      let a = cast[int32](locBase[cachedLocalsStart + x] and 0xFFFFFFFF'u64)
      let b = cast[int32](locBase[cachedLocalsStart + y] and 0xFFFFFFFF'u64)
      locBase[cachedLocalsStart + z] = uint64(cast[uint32](a + b))
    of opLocalGetLocalGetI32SubLocalSet:
      # Z = local[X] - local[Y]
      let x = int(instr.imm1 and 0xFFFF'u32)
      let y = int(instr.imm1 shr 16)
      let z = instr.imm2.int
      let a = cast[int32](locBase[cachedLocalsStart + x] and 0xFFFFFFFF'u64)
      let b = cast[int32](locBase[cachedLocalsStart + y] and 0xFFFFFFFF'u64)
      locBase[cachedLocalsStart + z] = uint64(cast[uint32](a - b))

    # ===== Tail calls (return_call, return_call_indirect) =====
    of opReturnCall:
      let calleeAddr = if instr.pad == 1: instr.imm1.int
                        else: vm.store.modules[cachedModIdx].funcAddrs[instr.imm1.int]
      let callee {.cursor.} = vm.store.funcs[calleeAddr]
      if callee.isHost:
        let nParams = callee.funcType.params.len
        var hostArgs = newSeq[WasmValue](nParams)
        for i in countdown(nParams - 1, 0):
          hostArgs[i] = rawToWasmValue(spop(), callee.funcType.params[i])
        syncSp()
        let hostResults = callee.hostFunc(hostArgs)
        sp = vm.valueStackTop
        for r in hostResults:
          spush(wasmValueToRaw(r))
        # Treat as return
        let curFrame = vm.callStack[vm.callStackTop - 1]
        vm.localsTop = curFrame.localsStart
        vm.labelStackTop = curFrame.labelStackStart
        dec vm.callStackTop
        if vm.callStackTop <= entryCallStackTop:
          break
        loadFrameCache()
        locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)
        continue
      else:
        # Tail call: reuse current frame's stack space
        let calleeCode = callee.code
        let paramCount = callee.funcType.params.len
        let returnArity = callee.funcType.results.len
        let calleeModIdx = callee.moduleIdx
        let curFrame = vm.callStack[vm.callStackTop - 1]
        let localsStart = curFrame.localsStart
        let newTotalLocals = callee.localTypes.len
        let needed = localsStart + newTotalLocals
        if unlikely(needed > vm.locals.len):
          vm.locals.setLen(needed * 2)
          locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)
        # Pop args directly into reused locals
        sp -= paramCount
        for i in 0 ..< paramCount:
          locBase[localsStart + i] = vsBase[sp + i]
        for i in paramCount ..< newTotalLocals:
          locBase[localsStart + i] = 0'u64
        vm.localsTop = needed
        # Reuse frame: update in place (no push/pop)
        vm.labelStackTop = curFrame.labelStackStart
        vm.callStack[vm.callStackTop - 1] = Frame(
          pc: 0,
          code: calleeCode,
          brTables: calleeCode[].brTables.addr,
          localsStart: localsStart,
          localsCount: newTotalLocals,
          labelStackStart: curFrame.labelStackStart,
          returnArity: returnArity,
          moduleIdx: calleeModIdx
        )
        vm.labelStack[vm.labelStackTop] = Label(
          arity: returnArity,
          pc: calleeCode[].code.len,
          stackHeight: sp,
          isLoop: false,
          catchTableIdx: -1
        )
        inc vm.labelStackTop
        cachedCode = cast[ptr UncheckedArray[Instr]](calleeCode[].code[0].addr)
        cachedCodeLen = calleeCode[].code.len
        cachedPc = 0
        cachedModIdx = calleeModIdx
        cachedLocalsStart = localsStart
        cachedBrTables = calleeCode[].brTables.addr
        continue

    of opReturnCallIndirect:
      let typeIdx = instr.imm1.int
      let tableIdx = instr.imm2.int
      let modIdx = cachedModIdx
      let expectedType {.cursor.} = vm.store.modules[modIdx].types[typeIdx]
      let tableAddr = vm.store.modules[modIdx].tableAddrs[tableIdx]
      let elemIdx = spopI32()
      if elemIdx < 0 or elemIdx.int >= vm.store.tables[tableAddr].elems.len:
        trap("undefined element")
      let elem = vm.store.tables[tableAddr].elems[elemIdx.int]
      if elem.kind != wvkFuncRef or elem.funcRef < 0:
        trap("uninitialized element")
      let calleeAddr = elem.funcRef.int
      let callee {.cursor.} = vm.store.funcs[calleeAddr]
      if callee.funcType.params.len != expectedType.params.len or
         callee.funcType.results.len != expectedType.results.len:
        trap("indirect call type mismatch")
      # Tail call reusing current frame
      if callee.isHost:
        let nParams = callee.funcType.params.len
        var hostArgs = newSeq[WasmValue](nParams)
        for i in countdown(nParams - 1, 0):
          hostArgs[i] = rawToWasmValue(spop(), callee.funcType.params[i])
        syncSp()
        let hostResults = callee.hostFunc(hostArgs)
        sp = vm.valueStackTop
        for r in hostResults:
          spush(wasmValueToRaw(r))
        let curFrame = vm.callStack[vm.callStackTop - 1]
        vm.localsTop = curFrame.localsStart
        vm.labelStackTop = curFrame.labelStackStart
        dec vm.callStackTop
        if vm.callStackTop <= entryCallStackTop:
          break
        loadFrameCache()
        locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)
        continue
      else:
        let calleeCode = callee.code
        let paramCount = callee.funcType.params.len
        let returnArity = callee.funcType.results.len
        let calleeModIdx = callee.moduleIdx
        let curFrame = vm.callStack[vm.callStackTop - 1]
        let localsStart = curFrame.localsStart
        let newTotalLocals = callee.localTypes.len
        let needed = localsStart + newTotalLocals
        if unlikely(needed > vm.locals.len):
          vm.locals.setLen(needed * 2)
          locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)
        sp -= paramCount
        for i in 0 ..< paramCount:
          locBase[localsStart + i] = vsBase[sp + i]
        for i in paramCount ..< newTotalLocals:
          locBase[localsStart + i] = 0'u64
        vm.localsTop = needed
        vm.labelStackTop = curFrame.labelStackStart
        vm.callStack[vm.callStackTop - 1] = Frame(
          pc: 0,
          code: calleeCode,
          brTables: calleeCode[].brTables.addr,
          localsStart: localsStart,
          localsCount: newTotalLocals,
          labelStackStart: curFrame.labelStackStart,
          returnArity: returnArity,
          moduleIdx: calleeModIdx
        )
        vm.labelStack[vm.labelStackTop] = Label(
          arity: returnArity,
          pc: calleeCode[].code.len,
          stackHeight: sp,
          isLoop: false,
          catchTableIdx: -1
        )
        inc vm.labelStackTop
        cachedCode = cast[ptr UncheckedArray[Instr]](calleeCode[].code[0].addr)
        cachedCodeLen = calleeCode[].code.len
        cachedPc = 0
        cachedModIdx = calleeModIdx
        cachedLocalsStart = localsStart
        cachedBrTables = calleeCode[].brTables.addr
        continue

    # ===== Exception handling =====
    of opThrow:
      # Resolve tag
      let tagIdx = instr.imm1.int
      let tagAddr = vm.store.modules[cachedModIdx].tagAddrs[tagIdx]
      let tagFt = vm.store.tags[tagAddr].funcType
      let payloadLen = tagFt.params.len
      # Pop payload values off the value stack (TOS = last param)
      var payload: array[128, uint64]
      for i in countdown(payloadLen - 1, 0):
        dec sp
        payload[i] = vsBase[sp]
      # Scan label stack top-to-bottom for a matching try_table catch clause.
      # Keep track of which call frame each label segment belongs to,
      # so we can unwind the call stack when we cross a frame boundary.
      var frameIdx = vm.callStackTop - 1
      var scanLabelIdx = vm.labelStackTop - 1
      var caught = false
      block scanLoop:
        while scanLabelIdx >= entryLabelStackTop:
          # When we pass below a frame's label start, step down one frame
          while frameIdx > 0 and
                scanLabelIdx < vm.callStack[frameIdx].labelStackStart:
            dec frameIdx
          let lbl = vm.labelStack[scanLabelIdx]
          if lbl.catchTableIdx >= 0:
            let clauses = vm.callStack[frameIdx].code[].catchTables[lbl.catchTableIdx]
            let frameModIdx = vm.callStack[frameIdx].moduleIdx
            for clause in clauses:
              var matches = false
              case clause.kind
              of ckCatch, ckCatchRef:
                let resolvedAddr = vm.store.modules[frameModIdx].tagAddrs[clause.tagIdx.int]
                matches = (resolvedAddr == tagAddr)
              of ckCatchAll, ckCatchAllRef:
                matches = true
              if matches:
                # Unwind call stack down to frame frameIdx
                while vm.callStackTop - 1 > frameIdx:
                  let f = vm.callStack[vm.callStackTop - 1]
                  vm.localsTop = f.localsStart
                  dec vm.callStackTop
                # Restore label stack to the matching try_table label slot
                vm.labelStackTop = scanLabelIdx + 1
                # Restore cached frame state
                loadFrameCache()
                locBase = cast[ptr UncheckedArray[uint64]](vm.locals[0].addr)
                # Determine the branch target label (labelDepth relative to the try_table label)
                let targetLabelIdx = scanLabelIdx - clause.labelDepth.int
                let targetLbl = vm.labelStack[targetLabelIdx]
                # Restore value stack to target label's stack height
                sp = targetLbl.stackHeight
                vsBase = cast[ptr UncheckedArray[uint64]](vm.valueStack[0].addr)
                # Push payload for ckCatch / ckCatchRef
                case clause.kind
                of ckCatch:
                  for i in 0 ..< payloadLen:
                    vsBase[sp] = payload[i]; inc sp
                of ckCatchRef:
                  for i in 0 ..< payloadLen:
                    vsBase[sp] = payload[i]; inc sp
                  # push a null exnref placeholder (i32 -1)
                  vsBase[sp] = cast[uint64](-1'i64); inc sp
                of ckCatchAll:
                  discard  # no payload
                of ckCatchAllRef:
                  # push a null exnref placeholder
                  vsBase[sp] = cast[uint64](-1'i64); inc sp
                # Pop labels to the target label (branch: non-loop = pop)
                vm.labelStackTop = targetLabelIdx
                # Jump to the target label's continuation pc
                cachedPc = targetLbl.pc
                caught = true
                break scanLoop
          dec scanLabelIdx
      if not caught:
        trap("uncaught WASM exception: tag " & $tagAddr)

    of opThrowRef:
      # Simplified: treat the exnref as opaque. Pop it and trap.
      # Full exnref tracking would require heap-allocated exception objects.
      discard spop()  # exnref
      trap("throw_ref: exnref propagation not supported in interpreter")

    of opTryTable:
      let resultArity = vm.blockResultArity(instr.pad, cachedModIdx)
      let paramArity = vm.blockParamArity(instr.pad, cachedModIdx)
      let endIdx = instr.imm1.int
      let sh = sp - paramArity
      if vm.labelStackTop >= vm.labelStack.len:
        vm.labelStack.setLen(vm.labelStack.len * 2)
      vm.labelStack[vm.labelStackTop] = Label(
        arity: resultArity,
        pc: endIdx + 1,
        stackHeight: sh,
        isLoop: false,
        catchTableIdx: instr.imm2.int32
      )
      inc vm.labelStackTop

    # ===== SIMD v128 =====
    # The interpreter does not implement SIMD; these instructions trap.
    # SIMD execution is handled exclusively by the Tier 2 JIT backend.
    of opV128Load, opV128Store, opV128Const,
       opI8x16Splat, opI16x8Splat, opI32x4Splat, opI64x2Splat,
       opF32x4Splat, opF64x2Splat,
       opI8x16ExtractLaneS, opI8x16ExtractLaneU, opI8x16ReplaceLane,
       opI16x8ExtractLaneS, opI16x8ExtractLaneU, opI16x8ReplaceLane,
       opI32x4ExtractLane, opI32x4ReplaceLane,
       opI64x2ExtractLane, opI64x2ReplaceLane,
       opF32x4ExtractLane, opF32x4ReplaceLane,
       opF64x2ExtractLane, opF64x2ReplaceLane,
       opV128Not, opV128And, opV128Or, opV128Xor, opV128AndNot,
       opI8x16Abs, opI8x16Neg, opI8x16Add, opI8x16Sub,
       opI8x16MinS, opI8x16MinU, opI8x16MaxS, opI8x16MaxU,
       opI16x8Abs, opI16x8Neg, opI16x8Add, opI16x8Sub, opI16x8Mul,
       opI32x4Abs, opI32x4Neg, opI32x4Add, opI32x4Sub, opI32x4Mul,
       opI32x4Shl, opI32x4ShrS, opI32x4ShrU,
       opI32x4MinS, opI32x4MinU, opI32x4MaxS, opI32x4MaxU,
       opI64x2Add, opI64x2Sub,
       opF32x4Abs, opF32x4Neg, opF32x4Add, opF32x4Sub, opF32x4Mul, opF32x4Div,
       opF64x2Abs, opF64x2Neg, opF64x2Add, opF64x2Sub, opF64x2Mul, opF64x2Div:
      trap("SIMD v128 not supported in interpreter; use Tier 2 JIT")

  # Sync cached sp back before collecting results
  syncSp()

  # Collect results (convert uint64 -> WasmValue based on result types)
  let returnArity = ft.results.len
  result = newSeq[WasmValue](returnArity)
  for i in countdown(returnArity - 1, 0):
    result[i] = rawToWasmValue(vm.popRaw(), ft.results[i])

  # Restore entry state (in case of nested calls through host)
  vm.valueStackTop = entryValueStackTop
  vm.callStackTop = entryCallStackTop
  vm.labelStackTop = entryLabelStackTop
  vm.localsTop = entryLocalsTop

# ---------------------------------------------------------------------------
# Helper procs for external use
# ---------------------------------------------------------------------------

proc getExport*(vm: var WasmVM, moduleIdx: int, name: string): ExportInst =
  for exp in vm.store.modules[moduleIdx].exports:
    if exp.name == name:
      return exp
  trap("export not found: " & name)

proc invoke*(vm: var WasmVM, moduleIdx: int, name: string,
             args: openArray[WasmValue]): seq[WasmValue] =
  let exp = vm.getExport(moduleIdx, name)
  if exp.kind != ekFunc:
    trap("export is not a function: " & name)
  vm.execute(exp.idx, args)

proc getMemory*(vm: var WasmVM, moduleIdx: int, memIdx: int = 0): var MemInst =
  let memAddr = vm.store.modules[moduleIdx].memAddrs[memIdx]
  vm.store.mems[memAddr]

proc getGlobal*(vm: var WasmVM, moduleIdx: int, globalIdx: int): var GlobalInst =
  let globalAddr = vm.store.modules[moduleIdx].globalAddrs[globalIdx]
  vm.store.globals[globalAddr]

proc getTable*(vm: var WasmVM, moduleIdx: int, tableIdx: int): var TableInst =
  let tableAddr = vm.store.modules[moduleIdx].tableAddrs[tableIdx]
  vm.store.tables[tableAddr]

proc destroyWasmVM*(vm: var WasmVM) =
  ## Release all resources held by the VM, including guard-page memory.
  when defined(wasmGuardPages):
    for i in 0 ..< vm.store.mems.len:
      if vm.store.mems[i].useGuard:
        freeGuardedMem(vm.store.mems[i].guardMem)

proc memCurrentPages*(mem: var MemInst): int {.inline.} =
  ## Current number of allocated WASM pages.
  when defined(wasmGuardPages):
    if mem.useGuard:
      return int(mem.guardMem.accessibleBytes div WasmPageSize.uint64)
  mem.data.len div WasmPageSize
