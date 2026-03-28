## CLI tool: Resource-aware JIT triage analysis of a WASM binary
##
## Usage:
##   wasm-cost <file.wasm> [function] [options]
##
## Without a function argument: analyzes all exported functions.
## With a function name: analyzes that specific export.
## With a numeric index: analyzes the function at that absolute index.
## --all:  analyze ALL functions (including non-exported).
## --pgo:  run the function in the interpreter first to collect profiling
##         data, then show cost analysis with PGO-resolved trip counts.
## --pgo-calls N:  number of profiling warm-up calls (default: 100).
## --pgo-arg V:    i32 argument for profiling calls (repeatable).
##
## Output: CFG with per-block abstract cost vectors, loop structure,
## symbolic cost polynomials, optimization pass gating decisions.

import std/[os, strutils, sequtils, strformat]
import ../types
import ../binary
import ../runtime
import ../pgo
import ../wasi
import ir, lower, cost, optimize

# =========================================================================
# Pretty-printing for cost types
# =========================================================================

proc `$`(v: CostVarId): string =
  if v < 0: "_" else: "n" & $v.int

proc `$`(t: CostTerm): string =
  result = $t.coeff
  for i in 0 ..< MaxTermVars:
    if t.vars[i] >= 0:
      result &= "·" & $t.vars[i]

proc `$`(p: CostPoly): string =
  result = $p.constant
  for t in p.terms:
    if t.coeff > 0:
      result &= " + " & $t
    elif t.coeff < 0:
      result &= " - "
      var neg = t
      neg.coeff = -neg.coeff
      result &= $neg

proc fmtCostVec(cv: CostVector, indent: string = "  "): string =
  result = indent & "cycles:     " & $cv.cycles & "\n"
  result &= indent & "code_size:  " & $cv.codeSize & " bytes\n"
  result &= indent & "mem_ops:    " & $cv.memOps & "\n"
  result &= indent & "reg_press:  " & $cv.regPressure & " int, " &
            $cv.fpRegPressure & " fp\n"
  if cv.spillEstimate > 0:
    result &= indent & "spill_est:  " & $cv.spillEstimate & " regs"

proc fmtGating(g: OptGating): string =
  var enabled: seq[string]
  var skipped: seq[string]
  template gate(name: string, flag: bool) =
    if flag: enabled.add(name)
    else: skipped.add(name)
  gate("store-load-forward", g.runStoreLoadForward)
  gate("global-CSE", g.runGlobalCSE)
  gate("promote-locals", g.runPromoteLocals)
  gate("global-bounds-elim", g.runGlobalBCE)
  gate("alias-bounds-elim", g.runAliasBCE)
  gate("alias-global-bounds-elim", g.runAliasGlobalBCE)
  gate("loop-bounds-hoist", g.runLoopBCEHoist)
  gate("loop-invariant-motion", g.runLICM)
  gate("fused-multiply-add", g.runFMA)
  gate("loop-unroll", g.runLoopUnroll)
  result = "  enabled:  " & enabled.join(", ") & "\n"
  if skipped.len > 0:
    result &= "  skipped:  " & skipped.join(", ") & "\n"
  result &= "  est. compile: " & $g.estimatedCompileTimeUs & " µs"

proc fmtInstrOp(op: IrOpKind): string =
  ($op).replace("ir", "")

# =========================================================================
# CFG rendering
# =========================================================================

proc renderCfg(f: IrFunc, cs: CostState) =
  for i, bb in f.blocks:
    let cv = cs.perBlock[i]

    # Header with loop info
    var header = fmt"BB{i}"
    if bb.predecessors.len > 0:
      header &= "  <-- " & bb.predecessors.mapIt("BB" & $it).join(", ")

    # Check if this is a loop header
    for loop in cs.loops:
      if loop.headerBb == i.int16:
        header &= fmt"  [LOOP header, var={loop.varId}"
        if loop.estimatedTrips > 0:
          header &= fmt", ~{loop.estimatedTrips} trips (PGO)"
        elif loop.estimatedTrips < 0:
          header &= ", trips=symbolic"
        header &= "]"

    echo header
    echo "  ├── successors: " & bb.successors.mapIt("BB" & $it).join(", ")

    # Instructions (compact)
    let maxShow = 12
    let total = bb.instrs.len
    if total <= maxShow:
      for j, instr in bb.instrs:
        var line = "  │  "
        if instr.result >= 0:
          line &= fmt"v{instr.result} = "
        line &= fmtInstrOp(instr.op)
        for k in 0 ..< 3:
          if instr.operands[k] >= 0:
            if k == 0: line &= " "
            else: line &= ", "
            line &= fmt"v{instr.operands[k]}"
        if instr.imm != 0:
          line &= fmt" imm={instr.imm}"
        if instr.op == irBrIf and instr.branchProb > 0:
          line &= fmt" prob={instr.branchProb}/255"
        echo line
    else:
      for j in 0 ..< 5:
        let instr = bb.instrs[j]
        var line = "  │  "
        if instr.result >= 0: line &= fmt"v{instr.result} = "
        line &= fmtInstrOp(instr.op)
        for k in 0 ..< 3:
          if instr.operands[k] >= 0:
            if k == 0: line &= " " else: line &= ", "
            line &= fmt"v{instr.operands[k]}"
        if instr.imm != 0: line &= fmt" imm={instr.imm}"
        echo line
      echo fmt"  │  ... ({total - 10} more instructions)"
      for j in (total - 5) ..< total:
        let instr = bb.instrs[j]
        var line = "  │  "
        if instr.result >= 0: line &= fmt"v{instr.result} = "
        line &= fmtInstrOp(instr.op)
        for k in 0 ..< 3:
          if instr.operands[k] >= 0:
            if k == 0: line &= " " else: line &= ", "
            line &= fmt"v{instr.operands[k]}"
        if instr.imm != 0: line &= fmt" imm={instr.imm}"
        echo line

    # Per-block cost
    echo "  └── cost:"
    echo "        cycles=" & $cv.cycles &
         "  code=" & $cv.codeSize &
         "  mem=" & $cv.memOps &
         "  reg=" & $cv.regPressure & "/" & $cv.fpRegPressure
    if cv.spillEstimate > 0:
      echo "        SPILL RISK: " & $cv.spillEstimate & " values over limit"
    echo ""

# =========================================================================
# Function analysis
# =========================================================================

proc analyzeFunction(module: WasmModule, funcIdx: int, funcName: string,
                     pgoData: ptr FuncPgoData = nil) =
  let numImportFuncs = module.imports.countIt(it.kind == ikFunc)
  let codeIdx = funcIdx - numImportFuncs

  if codeIdx < 0 or codeIdx >= module.codes.len:
    echo "  (imported function, no code to analyze)"
    return

  let typeIdx = module.funcTypeIdxs[codeIdx]
  let funcType = module.types[typeIdx.int]

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo fmt"Function: {funcName} (idx={funcIdx}, code={codeIdx})"
  echo fmt"  params: {funcType.params.len}  results: {funcType.results.len}  " &
       fmt"bytecode_instrs: {module.codes[codeIdx].code.code.len}"
  if pgoData != nil:
    echo "  PGO: profiling data available"
  echo ""

  # Lower to IR (with PGO branch annotations if available)
  let irFunc = lowerFunction(module, funcIdx, pgoData)

  echo fmt"IR: {irFunc.blocks.len} basic blocks, {irFunc.numValues} SSA values, " &
       fmt"{irFunc.numLocals} locals"
  if irFunc.usesMemory:
    echo "    uses linear memory"
  echo ""

  # Cost analysis (with PGO trip count resolution if available)
  var calleeCostCache = buildCalleeCostCache(module)
  let cs = analyzeCost(irFunc, pgoData, calleeCostCache.addr, funcIdx)

  # Render CFG with cost annotations
  echo "── Control Flow Graph ──"
  echo ""
  renderCfg(irFunc, cs)

  # Loop summary
  if cs.loops.len > 0:
    echo "── Loops ──"
    for loop in cs.loops:
      echo fmt"  Loop at BB{loop.headerBb} (var={loop.varId}):"
      echo "    body cost: " & $loop.bodyCost.cycles & " cycles, " &
           $loop.bodyCost.memOps & " mem_ops"
      if loop.estimatedTrips > 0:
        echo fmt"    PGO trips: ~{loop.estimatedTrips}"
      else:
        echo "    trips: symbolic (unknown)"
      echo fmt"    innermost: {loop.isInnermost}"
    echo ""

  # Function totals
  let hasCalls = irFunc.callIndirectSiteCount > 0 or irFunc.nonSelfCallSiteCount > 0
  if hasCalls:
    echo "── Frame Cost (excludes callee work) ──"
  else:
    echo "── Function Total ──"
  echo fmtCostVec(cs.funcTotal)
  echo ""

  if cs.hotPath.cycles.constant != cs.funcTotal.cycles.constant or
     cs.hotPath.cycles.terms.len != cs.funcTotal.cycles.terms.len:
    echo "── Hot Path (PGO-weighted) ──"
    echo fmtCostVec(cs.hotPath)
    echo ""

  # Optimization gating
  let gating = computeOptGating(cs)
  echo "── Optimization Pass Gating ──"
  echo fmtGating(gating)
  echo ""

  # Inlining profile
  echo "── Inlining Profile ──"
  echo fmt"  body_cycles: {cs.funcTotal.cycles.constant}"
  echo fmt"  code_growth: {cs.funcTotal.codeSize.constant} bytes"
  echo fmt"  reg_pressure: {cs.funcTotal.regPressure}"
  if cs.funcTotal.cycles.hasSymbolicTerms:
    echo "  has_loops: YES (symbolic cost → would NOT be inlined)"
  else:
    echo "  has_loops: NO (constant cost → inline candidate)"
  echo ""

  # Tier thresholds — use the same static bytecode analysis as the actual tiering
  let ft = module.types[module.funcTypeIdxs[codeIdx].int]
  var totalLocals: int16 = ft.params.len.int16
  for ld in module.codes[codeIdx].locals:
    totalLocals += ld.count.int16
  let staticProfile = analyzeStatic(
    module.codes[codeIdx].code.code, ft.params.len.int16, totalLocals)
  let (t1, t2) = computeStaticTierThresholds(staticProfile)
  echo "── Tier Thresholds (live — used by tiered VM) ──"
  echo fmt"  tier1 (interp→JIT):  {t1} calls"
  echo fmt"  tier2 (JIT→opt-JIT): {t2} calls"
  echo fmt"  est_compile_time:    {cs.estimatedCompileTimeUs} µs"
  echo ""

# =========================================================================
# PGO: run function in interpreter to collect profiling data
# =========================================================================

proc collectPgo(module: WasmModule, funcIdx: int, funcName: string,
                numCalls: int, args: seq[int32]): ptr FuncPgoData =
  ## Instantiate the module, run the function `numCalls` times with the
  ## profiler enabled, return a pointer to the collected PGO data.
  ## The returned pointer is into the profiler's storage (caller must
  ## keep the VM alive while using it, or copy the data).
  var vm = initWasmVM()
  var profiler = PgoProfiler()

  # Resolve imports: support WASI modules
  var imports: seq[(string, string, ExternalVal)]
  var needsWasi = false
  for imp in module.imports:
    if imp.module == "wasi_snapshot_preview1" or imp.module == "wasi_unstable":
      needsWasi = true
      break

  if needsWasi:
    var ctx = newWasiContext(args = @["wasm_program"])
    ctx.bindToVm(vm)
    for (m, n, ev) in ctx.makeWasiImports():
      imports.add((m, n, ev))

  let modIdx = vm.instantiate(module, imports)

  # Pre-allocate profiler slots for all functions
  for i in 0 ..< vm.store.funcs.len:
    let f = vm.store.funcs[i]
    if not f.isHost and f.code != nil:
      profiler.ensureFunc(i, f.code[].code.len)

  # Find the function's store address from the export
  let numImportFuncs = module.imports.countIt(it.kind == ikFunc)
  var funcAddr = funcIdx
  # If funcIdx is module-relative, convert to store address
  if modIdx < vm.store.modules.len and funcIdx < vm.store.modules[modIdx].funcAddrs.len:
    funcAddr = vm.store.modules[modIdx].funcAddrs[funcIdx]

  let funcInst = vm.store.funcs[funcAddr]
  let ft = funcInst.funcType

  # Build arguments for warm-up calls
  var wasmArgs: seq[WasmValue]
  if args.len > 0:
    for a in args:
      wasmArgs.add(wasmI32(a))
  else:
    # Default: use small values (0, 1, 2, ...) to avoid expensive computations
    for i in 0 ..< ft.params.len:
      case ft.params[i]
      of vtI32: wasmArgs.add(wasmI32(min(i.int32 + 5, 10)))
      of vtI64: wasmArgs.add(wasmI64(min(i.int64 + 5, 10)))
      of vtF32: wasmArgs.add(wasmF32(1.0f))
      of vtF64: wasmArgs.add(wasmF64(1.0))
      else: wasmArgs.add(wasmI32(0))

  echo fmt"  PGO: running {funcName}({wasmArgs.len} args) x {numCalls} calls..."

  # Run with profiler
  var succeeded = 0
  for i in 0 ..< numCalls:
    try:
      discard vm.execute(funcAddr, wasmArgs, profiler.addr)
      inc succeeded
    except CatchableError:
      discard  # traps are fine — we still collect partial profile data

  echo fmt"  PGO: {succeeded}/{numCalls} calls completed"

  # Extract PGO data for the target function.
  # The profiler keys by store funcAddr (= funcAddr after instantiation).
  result = profiler.getFuncData(funcAddr)
  if result != nil:
    var branchSites = 0
    var callSites = 0
    for bp in result.branchProfiles:
      if bp.taken > 0 or bp.notTaken > 0: inc branchSites
    for cp in result.callIndirectProfiles:
      if cp.totalCount > 0: inc callSites
    if branchSites > 0 or callSites > 0:
      echo fmt"  PGO: {branchSites} branch sites, {callSites} indirect call sites"
      var shown = 0
      for pc, bp in result.branchProfiles:
        if bp.taken > 0 or bp.notTaken > 0:
          let total = bp.taken.int + bp.notTaken.int
          let pct = if total > 0: bp.taken.int * 100 div total else: 0
          echo fmt"        pc={pc}: taken={bp.taken} notTaken={bp.notTaken} ({pct}% taken)"
          inc shown
          if shown >= 8: break
    else:
      echo fmt"  PGO: profiler active but no branches recorded (funcAddr={funcAddr})"
  else:
    echo fmt"  PGO: no profiling data at funcAddr={funcAddr}"
  echo ""

# =========================================================================
# Main
# =========================================================================

proc main() =
  let args = commandLineParams()
  if args.len < 1:
    echo "wasm-cost: Resource-aware JIT triage analysis"
    echo ""
    echo "Usage: wasm-cost <file.wasm> [function] [options]"
    echo ""
    echo "  Without argument:  analyze all exported functions"
    echo "  function_name:     analyze a specific exported function"
    echo "  func_index:        analyze function at absolute index (e.g. '3')"
    echo "  --all:             analyze ALL functions (including non-exported)"
    echo "  --pgo:             run interpreter first to collect profiling data"
    echo "  --pgo-calls N:     warm-up calls for profiling (default: 100)"
    echo "  --pgo-arg V:       i32 argument for profiling calls (repeatable)"
    quit(0)

  let wasmPath = args[0]
  if not fileExists(wasmPath):
    echo "Error: file not found: " & wasmPath
    quit(1)

  # Parse flags
  var pgoEnabled = false
  var pgoCalls = 100
  var pgoArgs: seq[int32]
  var positionalArgs: seq[string]

  var i = 1
  while i < args.len:
    let arg = args[i]
    if arg == "--pgo":
      pgoEnabled = true
    elif arg == "--pgo-calls" and i + 1 < args.len:
      inc i
      pgoCalls = parseInt(args[i])
    elif arg == "--pgo-arg" and i + 1 < args.len:
      inc i
      pgoArgs.add(parseInt(args[i]).int32)
    else:
      positionalArgs.add(arg)
    inc i

  let data = cast[seq[byte]](readFile(wasmPath))
  let module = decodeModule(data)

  let numImportFuncs = module.imports.countIt(it.kind == ikFunc)
  let numLocalFuncs = module.codes.len
  let totalFuncs = numImportFuncs + numLocalFuncs

  echo fmt"Module: {wasmPath}"
  echo fmt"  types: {module.types.len}  imports: {module.imports.len} " &
       fmt"({numImportFuncs} funcs)  local_funcs: {numLocalFuncs}  " &
       fmt"exports: {module.exports.len}"
  echo fmt"  memories: {module.memories.len}  tables: {module.tables.len}  " &
       fmt"globals: {module.globals.len}"
  if pgoEnabled:
    echo fmt"  PGO: enabled ({pgoCalls} warm-up calls)"
  echo ""

  # Build export name map
  var funcNames: seq[string]
  funcNames.setLen(totalFuncs)
  for fi in 0 ..< totalFuncs:
    funcNames[fi] = "func_" & $fi
  for exp in module.exports:
    if exp.kind == ekFunc and exp.idx.int < totalFuncs:
      funcNames[exp.idx.int] = exp.name

  # Helper: analyze with optional PGO
  proc analyzeWithPgo(funcIdx: int, name: string) =
    var pgoPtr: ptr FuncPgoData = nil
    if pgoEnabled:
      pgoPtr = collectPgo(module, funcIdx, name, pgoCalls, pgoArgs)
    analyzeFunction(module, funcIdx, name, pgoPtr)

  if positionalArgs.len > 0:
    let target = positionalArgs[0]

    if target == "--all":
      for fi in numImportFuncs ..< totalFuncs:
        analyzeWithPgo(fi, funcNames[fi])
    else:
      # Try as number first
      try:
        let idx = parseInt(target)
        if idx < numImportFuncs or idx >= totalFuncs:
          echo fmt"Error: function index {idx} out of range " &
               fmt"[{numImportFuncs}..{totalFuncs - 1}] (non-imported)"
          quit(1)
        analyzeWithPgo(idx, funcNames[idx])
      except ValueError:
        # Try as export name
        var found = false
        for exp in module.exports:
          if exp.name == target and exp.kind == ekFunc:
            analyzeWithPgo(exp.idx.int, exp.name)
            found = true
            break
        if not found:
          echo "Error: export not found: " & target
          echo "Available exports:"
          for exp in module.exports:
            if exp.kind == ekFunc:
              echo "  " & exp.name & " (idx=" & $exp.idx & ")"
          quit(1)
  else:
    # Default: analyze all exported functions
    var analyzed = 0
    for exp in module.exports:
      if exp.kind == ekFunc:
        analyzeWithPgo(exp.idx.int, exp.name)
        inc analyzed
    if analyzed == 0:
      echo "No exported functions found. Use --all to analyze all functions."

when isMainModule:
  main()
