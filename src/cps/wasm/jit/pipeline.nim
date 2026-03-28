## Tier 2 optimizing JIT pipeline
## Connects: WASM bytecode → IR lowering → inlining → optimization →
##           phi analysis → scheduling → register allocation → codegen

import ../types
import ../pgo
import ir, regalloc, scheduler, lower, ircodegen, ircodegen_x64, memory, optimize, phicoalesce
import inline
import compiler  # for TableElem, CallIndirectCache
import aotcache  # for Relocation type (persistent cache support)
import cost      # resource-aware triage pass
# Note: automatic TCO (tco.nim) runs inside the lowerer at bytecode level

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
  ## 2. Inline small function calls
  ## 3. Optimize IR (constant fold, DCE, strength reduce, CSE, LICM, BCE)
  ## 4. Analyze phi coalescing opportunities
  ## 5. Schedule instructions (PGO-biased priorities for likely branches)
  ## 6. Verify phi coalescing feasibility after scheduling
  ## 7. Allocate registers (with phi coalescing)
  ## 8. Generate AArch64 code with physical registers

  # Step 1: Lower WASM → SSA IR (with PGO branch-probability annotations)
  var irFunc = lowerFunction(module, funcIdx, pgoData)

  # Step 1b: Cost analysis triage — compute execution cost profile
  # Build callee cost cache so irCall cost reflects actual callee body cost
  var calleeCostCache = buildCalleeCostCache(module)
  let costState = analyzeCost(irFunc, pgoData, calleeCostCache.addr, funcIdx)

  # Step 2: Inline small function calls
  inlineFunctionCalls(irFunc, module, funcIdx)

  # Step 3: Optimize IR (cost-gated: skip passes the function doesn't need)
  let gating = computeOptGating(costState)
  optimizeIrGated(irFunc, gating)

  # Step 4: Analyze phi coalescing opportunities
  var phiCoalesce = analyzePhiCoalescing(irFunc)

  # Step 4: Instruction scheduling (with phi hints for coalescing)
  for i in 0 ..< irFunc.blocks.len:
    let hints = phiHintsForBlock(phiCoalesce, i)
    let order = scheduleBlock(irFunc.blocks[i], hints)
    var reordered = newSeq[IrInstr](order.len)
    for j in 0 ..< order.len:
      reordered[j] = irFunc.blocks[i].instrs[order[j]]
    irFunc.blocks[i].instrs = reordered

  # Step 5: Verify phi coalescing feasibility after scheduling
  verifyPhiCoalescing(irFunc, phiCoalesce)

  # Step 6: Register allocation (with phi coalescing)
  let allocResult = allocateRegisters(irFunc, phiCoalesce)

  # Step 7: Emit AArch64 with physical registers
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

  # Cost analysis triage
  var calleeCostCacheX64 = buildCalleeCostCache(module)
  let costState = analyzeCost(irFunc, pgoData, addr calleeCostCacheX64, funcIdx)

  inlineFunctionCalls(irFunc, module, funcIdx)

  # Cost-gated optimization
  let gating = computeOptGating(costState)
  optimizeIrGated(irFunc, gating)

  var phiCoalesce = analyzePhiCoalescing(irFunc)

  for i in 0 ..< irFunc.blocks.len:
    let hints = phiHintsForBlock(phiCoalesce, i)
    let order = scheduleBlock(irFunc.blocks[i], hints)
    var reordered = newSeq[IrInstr](order.len)
    for j in 0 ..< order.len:
      reordered[j] = irFunc.blocks[i].instrs[order[j]]
    irFunc.blocks[i].instrs = reordered

  verifyPhiCoalescing(irFunc, phiCoalesce)

  # x86_64: 5 allocatable regs, callee-saved starts at color 4 (rbx)
  let allocResult = allocateRegisters(irFunc, phiCoalesce,
                                      numIntRegs = NumIntRegsX64,
                                      calleeSavedStart = CalleeSavedStartX64)

  result = emitIrFuncX64(pool, irFunc, allocResult, selfModuleIdx, tableElems, tableLen,
                          relocSites = relocSites)
