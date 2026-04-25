## Tier 2 optimizing JIT pipeline
## Connects: WASM bytecode → IR lowering → inlining → optimization →
##           phi analysis → scheduling → register allocation → codegen

import ../types
import ../pgo
import ir, regalloc, scheduler, lower, ircodegen, ircodegen_x64, ircodegen_rv64, ircodegen_rv32, codegen_rv64, memory, optimize, phicoalesce
import inline
import compiler  # for TableElem, CallIndirectCache
import aotcache  # for Relocation type (persistent cache support)
import cost      # resource-aware triage pass
# Note: automatic TCO (tco.nim) runs inside the lowerer at bytecode level

proc scheduleAllBlocks(irFunc: var IrFunc, phiCoalesce: PhiCoalesceInfo) =
  ## Apply instruction scheduling with phi-coalescing hints to every block.
  for i in 0 ..< irFunc.blocks.len:
    let hints = phiHintsForBlock(phiCoalesce, i)
    let order = scheduleBlock(irFunc.blocks[i], hints)
    var reordered = newSeq[IrInstr](order.len)
    for j in 0 ..< order.len:
      reordered[j] = irFunc.blocks[i].instrs[order[j]]
    irFunc.blocks[i].instrs = reordered

proc countImportFuncs(module: WasmModule): int =
  for imp in module.imports:
    if imp.kind == ikFunc:
      inc result

proc importedGlobalType(module: WasmModule, globalIdx: int): (bool, ValType) =
  var idx = 0
  for imp in module.imports:
    if imp.kind == ikGlobal:
      if idx == globalIdx:
        return (true, imp.globalType.valType)
      inc idx
  (false, vtI32)

proc globalType(module: WasmModule, globalIdx: int): ValType =
  let (found, vt) = importedGlobalType(module, globalIdx)
  if found:
    return vt
  var importGlobals = 0
  for imp in module.imports:
    if imp.kind == ikGlobal:
      inc importGlobals
  let localIdx = globalIdx - importGlobals
  if localIdx >= 0 and localIdx < module.globals.len:
    return module.globals[localIdx].globalType.valType
  vtI32

proc hasTier2TrapLowering(op: Opcode): bool =
  case op
  of opMemorySize, opMemoryGrow,
     opI32TruncSatF32S, opI32TruncSatF32U, opI32TruncSatF64S,
     opI32TruncSatF64U, opI64TruncSatF32S, opI64TruncSatF32U,
     opI64TruncSatF64S, opI64TruncSatF64U,
     opRefIsNull, opBrTable,
     opTableGet, opTableSet, opTableInit, opElemDrop, opTableCopy,
     opTableGrow, opTableSize, opTableFill,
     opMemoryInit, opDataDrop, opMemoryCopy, opMemoryFill,
     opThrow, opThrowRef, opTryTable:
    true
  else:
    false

proc ensureNoTier2TrapLowering(module: WasmModule, localFuncIdx: int,
                               backend: string) =
  for instr in module.codes[localFuncIdx].code.code:
    if instr.op.hasTier2TrapLowering:
      raise newException(ValueError,
        backend & " JIT does not support Tier 2 lowering for " & $instr.op)

proc ensureRv64FunctionCompatible(module: WasmModule, funcIdx: int, target: RvTarget) =
  ## RV64 codegen represents scalar values as integer bit patterns. Hardware
  ## float/vector instructions are only emitted when the selected target opts in.
  var supportedTypes =
    if rvExtD in target.features: {vtI32, vtI64, vtF32, vtF64}
    elif rvExtF in target.features: {vtI32, vtI64, vtF32}
    else: {vtI32, vtI64}
  if rvExtV in target.features or rvXTheadVector in target.features:
    supportedTypes.incl(vtV128)
  let localFuncIdx = funcIdx - module.countImportFuncs()
  if localFuncIdx < 0 or localFuncIdx >= module.codes.len:
    raise newException(ValueError, "RV64 JIT requires a non-import function index")
  let ft = module.types[module.funcTypeIdxs[localFuncIdx].int]
  if ft.results.len > 1:
    raise newException(ValueError, "RV64 JIT currently supports at most one result")
  for vt in ft.params:
    if vt notin supportedTypes:
      raise newException(ValueError, "RV64 JIT target does not support this param type")
  for vt in ft.results:
    if vt notin supportedTypes:
      raise newException(ValueError, "RV64 JIT target does not support this result type")
  for ld in module.codes[localFuncIdx].locals:
    if ld.valType notin supportedTypes:
      raise newException(ValueError, "RV64 JIT target does not support this local type")
  for instr in module.codes[localFuncIdx].code.code:
    if instr.op in {opGlobalGet, opGlobalSet}:
      if module.globalType(instr.imm1.int) notin supportedTypes:
        raise newException(ValueError, "RV64 JIT target does not support this global type")
  module.ensureNoTier2TrapLowering(localFuncIdx, "RV64")

proc ensureRv32FunctionCompatible(module: WasmModule, funcIdx: int, target: RvTarget) =
  ## RV32 scalar codegen supports integer values, f32 when the target has F,
  ## and f64 helper lowering when the target has D. i64/f64 values are
  ## represented as low-register + high-stack-slot pairs.
  var supportedTypes =
    if rvExtD in target.features: {vtI32, vtI64, vtF32, vtF64}
    elif rvExtF in target.features: {vtI32, vtI64, vtF32}
    else: {vtI32, vtI64}
  supportedTypes.incl(vtV128)
  let localFuncIdx = funcIdx - module.countImportFuncs()
  if localFuncIdx < 0 or localFuncIdx >= module.codes.len:
    raise newException(ValueError, "RV32 JIT requires a non-import function index")
  let ft = module.types[module.funcTypeIdxs[localFuncIdx].int]
  if ft.results.len > 1:
    raise newException(ValueError, "RV32 JIT currently supports at most one result")
  for vt in ft.params:
    if vt notin supportedTypes:
      raise newException(ValueError, "RV32 JIT target does not support this param type")
  for vt in ft.results:
    if vt notin supportedTypes:
      raise newException(ValueError, "RV32 JIT target does not support this result type")
  for ld in module.codes[localFuncIdx].locals:
    if ld.valType notin supportedTypes:
      raise newException(ValueError, "RV32 JIT target does not support this local type")
  for instr in module.codes[localFuncIdx].code.code:
    if instr.op in {opGlobalGet, opGlobalSet}:
      if module.globalType(instr.imm1.int) notin supportedTypes:
        raise newException(ValueError, "RV32 JIT target does not support this global type")
  module.ensureNoTier2TrapLowering(localFuncIdx, "RV32")

proc compileTier2*(pool: var JitMemPool, module: WasmModule,
                   funcIdx: int, selfModuleIdx: int = -1,
                   tableElems: ptr UncheckedArray[TableElem] = nil,
                   tableLen: int32 = 0,
                   funcElems: ptr UncheckedArray[TableElem] = nil,
                   numFuncs: int32 = 0,
                   pgoData: ptr FuncPgoData = nil,
                   relocSites: ptr seq[Relocation] = nil): JitCode =
  ## Full Tier 2 compilation pipeline:
  ## 1. Lower WASM to SSA IR  (PGO branch probabilities embedded in irBrIf)
  ## 2. Cost analysis triage (build callee cost cache, compute gating profile)
  ## 3. Inline small function calls
  ## 4. Optimize IR (cost-gated: constant fold, DCE, strength reduce, CSE, LICM, BCE)
  ## 5. Analyze phi coalescing opportunities
  ## 6. Schedule instructions (PGO-biased priorities for likely branches)
  ## 7. Verify phi coalescing feasibility after scheduling
  ## 8. Allocate registers (with phi coalescing)
  ## 9. Generate AArch64 code with physical registers

  var irFunc = lowerFunction(module, funcIdx, pgoData)

  var calleeCostCache = buildCalleeCostCache(module)
  let costState = analyzeCost(irFunc, pgoData, calleeCostCache.addr, funcIdx)

  inlineFunctionCalls(irFunc, module, funcIdx)

  let gating = computeOptGating(costState)
  optimizeIrGated(irFunc, gating)

  var phiCoalesce = analyzePhiCoalescing(irFunc)
  scheduleAllBlocks(irFunc, phiCoalesce)
  verifyPhiCoalescing(irFunc, phiCoalesce)

  let allocResult = allocateRegisters(irFunc, phiCoalesce)
  result = emitIrFunc(pool, irFunc, allocResult, selfModuleIdx, tableElems, tableLen, funcElems, numFuncs, relocSites)

proc compileTier2X64*(pool: var JitMemPool, module: WasmModule,
                      funcIdx: int, selfModuleIdx: int = -1,
                      tableElems: ptr UncheckedArray[TableElem] = nil,
                      tableLen: int32 = 0,
                      pgoData: ptr FuncPgoData = nil,
                      relocSites: ptr seq[Relocation] = nil): JitCode =
  ## Full Tier 2 compilation pipeline for x86_64:
  ## Same IR lowering/optimization/scheduling as AArch64, but uses
  ## NumIntRegsX64 (5 allocatable GP regs) and emits x86_64 machine code.
  ## If *relocSites* is non-nil, absolute-address patch sites are appended
  ## for persistent cache support.

  var irFunc = lowerFunction(module, funcIdx, pgoData)

  var calleeCostCache = buildCalleeCostCache(module)
  let costState = analyzeCost(irFunc, pgoData, calleeCostCache.addr, funcIdx)

  inlineFunctionCalls(irFunc, module, funcIdx)

  let gating = computeOptGating(costState)
  optimizeIrGated(irFunc, gating)

  var phiCoalesce = analyzePhiCoalescing(irFunc)
  scheduleAllBlocks(irFunc, phiCoalesce)
  verifyPhiCoalescing(irFunc, phiCoalesce)

  let allocResult = allocateRegisters(irFunc, phiCoalesce,
                                      numIntRegs = NumIntRegsX64,
                                      calleeSavedStart = CalleeSavedStartX64,
                                      numSimdRegs = 0)
  result = emitIrFuncX64(pool, irFunc, allocResult, selfModuleIdx, tableElems, tableLen,
                          relocSites = relocSites)

proc compileTier2Rv64*(pool: var JitMemPool, module: WasmModule,
                       funcIdx: int, selfModuleIdx: int = -1,
                       tableElems: ptr UncheckedArray[TableElem] = nil,
                       tableLen: int32 = 0,
                       funcElems: ptr UncheckedArray[TableElem] = nil,
                       numFuncs: int32 = 0,
                       pgoData: ptr FuncPgoData = nil,
                       target: Rv64Target = rv64GenericTarget): JitCode =
  ## Full Tier 2 compilation pipeline for RV64.
  ## The initial backend covers scalar integer/control-flow/memory IR and emits
  ## EBREAK for unsupported operations. Pass `rv64BL808Target` to enable
  ## C906/T-Head codegen choices such as XTheadCondMov and XTheadMemPair.

  if target.xlen != rv64:
    raise newException(ValueError, "compileTier2Rv64 requires an RV64 target")
  ensureRv64FunctionCompatible(module, funcIdx, target)

  var irFunc = lowerFunction(module, funcIdx, pgoData)

  var calleeCostCache = buildCalleeCostCache(module)
  let costState = analyzeCost(irFunc, pgoData, calleeCostCache.addr, funcIdx)

  inlineFunctionCalls(irFunc, module, funcIdx)

  let gating = computeOptGating(costState)
  optimizeIrGated(irFunc, gating)

  var phiCoalesce = analyzePhiCoalescing(irFunc)
  scheduleAllBlocks(irFunc, phiCoalesce)
  verifyPhiCoalescing(irFunc, phiCoalesce)

  let allocResult = allocateRegisters(irFunc, phiCoalesce,
                                      numIntRegs = NumIntRegsRv64,
                                      calleeSavedStart = CalleeSavedStartRv64,
                                      numSimdRegs = 0)
  result = emitIrFuncRv64(pool, irFunc, allocResult, selfModuleIdx,
                          tableElems, tableLen, funcElems, numFuncs,
                          target = target)

proc compileTier2Rv32*(pool: var JitMemPool, module: WasmModule,
                       funcIdx: int, selfModuleIdx: int = -1,
                       tableElems: ptr UncheckedArray[TableElem] = nil,
                       tableLen: int32 = 0,
                       funcElems: ptr UncheckedArray[TableElem] = nil,
                       numFuncs: int32 = 0,
                       pgoData: ptr FuncPgoData = nil,
                       target: RvTarget = rv32GenericTarget): JitCode =
  ## Full Tier 2 compilation pipeline for RV32.
  ## This backend covers scalar integer/control-flow/memory IR. i64 values are
  ## lowered to RV32 register pairs and stack high-half slots.

  if target.xlen != rv32:
    raise newException(ValueError, "compileTier2Rv32 requires an RV32 target")
  ensureRv32FunctionCompatible(module, funcIdx, target)

  var irFunc = lowerFunction(module, funcIdx, pgoData)

  var calleeCostCache = buildCalleeCostCache(module)
  let costState = analyzeCost(irFunc, pgoData, calleeCostCache.addr, funcIdx)

  inlineFunctionCalls(irFunc, module, funcIdx)

  let gating = computeOptGating(costState)
  optimizeIrGated(irFunc, gating)

  var phiCoalesce = analyzePhiCoalescing(irFunc)
  scheduleAllBlocks(irFunc, phiCoalesce)
  verifyPhiCoalescing(irFunc, phiCoalesce)

  let allocResult = allocateRegisters(irFunc, phiCoalesce,
                                      numIntRegs = NumIntRegsRv32,
                                      calleeSavedStart = CalleeSavedStartRv32)
  let valueKinds = inferRv32ValueKinds(module, funcIdx, irFunc)
  result = emitIrFuncRv32(pool, irFunc, allocResult, selfModuleIdx,
                          tableElems, tableLen, funcElems, numFuncs,
                          valueKinds = valueKinds,
                          target = target)
