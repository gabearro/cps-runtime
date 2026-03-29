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

proc scheduleAllBlocks(irFunc: var IrFunc, phiCoalesce: PhiCoalesceInfo) =
  ## Apply instruction scheduling with phi-coalescing hints to every block.
  for i in 0 ..< irFunc.blocks.len:
    let hints = phiHintsForBlock(phiCoalesce, i)
    let order = scheduleBlock(irFunc.blocks[i], hints)
    var reordered = newSeq[IrInstr](order.len)
    for j in 0 ..< order.len:
      reordered[j] = irFunc.blocks[i].instrs[order[j]]
    irFunc.blocks[i].instrs = reordered

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
                                      calleeSavedStart = CalleeSavedStartX64)
  result = emitIrFuncX64(pool, irFunc, allocResult, selfModuleIdx, tableElems, tableLen,
                          relocSites = relocSites)
