## Resource-aware JIT triage: abstract cost interpretation
##
## Computes a multi-dimensional execution cost profile for each function,
## then translates that profile into concrete JIT resource allocation
## decisions: which optimization passes to run, whether to inline a callee,
## tier-up thresholds, code cache eviction scores, and compilation priority.
##
## The cost domain uses symbolic polynomials over loop-trip-count variables
## so that unbounded computations get informative abstract costs (e.g.,
## `12·n₀ + 5`) rather than ⊤ or a guess.
##
## Two layers:
##   Layer 1 (execution cost profile): what does the generated code cost?
##   Layer 2 (JIT resource decisions): how should the JIT spend its budget?
##
## The analysis exploits WASM's structured control flow (no irreducible
## loops) to compute costs in a single structured pass — no fixpoint
## iteration or widening needed.

{.experimental: "codeReordering".}

import std/[sequtils, algorithm]
import ir
import scheduler  # getLatency, LatencyInfo
import optimize   # isRealBackEdge, sideEffectOps
import ../types   # Opcode, Instr, WasmModule, FuncBody, etc.
import ../pgo     # FuncPgoData, branchTakenProb, hotCalleeOf, isMegamorphic

# =========================================================================
# Part 1: The Cost Algebra
# =========================================================================

const
  MaxTermVars* = 3     ## max loop variables per term (caps nesting depth)
  MaxTerms* = 8        ## max symbolic terms per polynomial
  LoopOverhead* = 2'i32  ## fixed cost of loop entry/exit
  ## Estimated cost multiplier: interpreter is ~4× slower than Tier 1 JIT
  InterpSlowdown* = 4'i32
  ## Estimated cost multiplier: Tier 1 is ~2× slower than Tier 2
  Tier1Slowdown* = 2'i32
  ## Available physical registers (mirrors regalloc.nim constants to avoid import)
  CostNumIntRegs* = 12    # x14-x15 + x19-x28
  CostNumFPRegs* = 16     # d0-d7 + d8-d15
  CostNumSimdRegs* = 14   # v16-v29

type
  CostVarId* = int16  ## Symbolic loop-trip-count variable index. -1 = absent.

  CostTerm* = object
    ## A symbolic term: coeff × Π(n[vars[i]] for i where vars[i] >= 0).
    ## vars=[0, -1, -1] → coeff × n₀
    ## vars=[0, 1, -1]  → coeff × n₀ × n₁ (nested loops)
    coeff*: int32
    vars*: array[MaxTermVars, CostVarId]

  CostPoly* = object
    ## Polynomial over symbolic loop-trip-count variables.
    ## Represents: constant + Σ terms[i]
    constant*: int32
    terms*: seq[CostTerm]

  CostVector* = object
    ## Multi-dimensional cost at a program point.
    cycles*: CostPoly       ## execution time (Apple M-series latencies)
    codeSize*: CostPoly     ## estimated native bytes emitted
    memOps*: CostPoly       ## load + store count (cache pressure proxy)
    regPressure*: int16     ## peak simultaneous live int values (per-block)
    fpRegPressure*: int16   ## peak simultaneous live FP values
    spillEstimate*: int16   ## max(regPressure - CostNumIntRegs, 0)

  LoopVarInfo* = object
    headerBb*: int16        ## BB index of the loop header
    depth*: int8            ## nesting depth (0 = outermost)
    estimatedTrips*: int32  ## from PGO exit probability; -1 = unknown

  LoopInfo* = object
    varId*: CostVarId
    headerBb*: int16
    backEdgeBb*: int16      ## BB index of the back-edge source
    bodyCost*: CostVector   ## cost of one iteration body
    isInnermost*: bool
    estimatedTrips*: int32  ## from PGO; -1 = stays symbolic

  CostState* = object
    ## Complete cost analysis result for a function.
    perBlock*: seq[CostVector]     ## cost vector per basic block
    funcTotal*: CostVector         ## whole-function summary
    hotPath*: CostVector           ## PGO-weighted expected case
    loops*: seq[LoopInfo]          ## per-loop breakdown
    loopVars*: seq[LoopVarInfo]    ## metadata per cost variable
    bbCount*: int16
    ssaValueCount*: int32
    estimatedCompileTimeUs*: int32 ## JIT's own resource cost

  InlineDecision* = object
    shouldInline*: bool
    benefit*: int32        ## estimated cycles saved per call
    codeGrowth*: int32     ## estimated bytes added to caller

  MemAccessClass* = enum
    macSequentialScan   ## Same root, constant stride. 2 cycles (prefetcher).
    macStructField      ## Same root, varied offsets. 4 cycles (L1 hit).
    macPointerChase     ## Address from another load. 10 cycles (serialized).
    macDefault          ## Unclassified. 4 cycles.

  # CalleeCostCache is defined after StaticFuncProfile (Part 6) due to type ordering

# =========================================================================
# CostTerm helpers
# =========================================================================

proc initTerm*(coeff: int32, v0: CostVarId, v1: CostVarId = -1,
               v2: CostVarId = -1): CostTerm =
  result.coeff = coeff
  result.vars = [v0, v1, v2]

proc termDegree*(t: CostTerm): int =
  ## Number of variables in the product (0 = constant, shouldn't appear as term).
  for v in t.vars:
    if v >= 0: inc result

proc sameVars*(a, b: CostTerm): bool =
  ## Do two terms have the same variable product? (order matters)
  a.vars == b.vars

proc termWithAppendedVar*(t: CostTerm, v: CostVarId): CostTerm =
  ## Append a new variable to the product. Returns a zero-coeff term if full.
  result.coeff = t.coeff
  result.vars = t.vars
  for i in 0 ..< MaxTermVars:
    if result.vars[i] < 0:
      result.vars[i] = v
      return
  # All slots full — cap depth, fold conservatively
  result.coeff = 0

# =========================================================================
# CostPoly lattice operations
# =========================================================================

proc zeroPoly*(): CostPoly =
  CostPoly(constant: 0)

proc constPoly*(c: int32): CostPoly =
  CostPoly(constant: c)

proc add*(a, b: CostPoly): CostPoly =
  ## Sequential composition: a then b.
  result.constant = a.constant + b.constant
  # Start with a's terms
  result.terms = a.terms
  # Merge b's terms: add coefficients for matching vars, append new
  for bt in b.terms:
    var merged = false
    for i in 0 ..< result.terms.len:
      if sameVars(result.terms[i], bt):
        result.terms[i].coeff += bt.coeff
        merged = true
        break
    if not merged and result.terms.len < MaxTerms:
      result.terms.add(bt)

proc join*(a, b: CostPoly): CostPoly =
  ## Control flow merge without PGO: conservative max.
  ## Sound over-approximation: real cost ≤ join.
  result.constant = max(a.constant, b.constant)
  # For each term in a: if b has matching vars, take max coeff; else keep a's.
  result.terms = a.terms
  for bt in b.terms:
    var found = false
    for i in 0 ..< result.terms.len:
      if sameVars(result.terms[i], bt):
        result.terms[i].coeff = max(result.terms[i].coeff, bt.coeff)
        found = true
        break
    if not found and result.terms.len < MaxTerms:
      result.terms.add(bt)

proc weightedJoin*(a, b: CostPoly, probA: uint8): CostPoly =
  ## PGO-weighted merge: expected value = p*a + (1-p)*b.
  ## probA is probability of path a in [0, 255].
  let pA = probA.int32
  let pB = 255'i32 - pA
  result.constant = int32((a.constant.int64 * pA + b.constant.int64 * pB) div 255)
  # Merge terms with weighted coefficients
  result.terms = @[]
  # Process a's terms
  for at in a.terms:
    var matched = false
    for bt in b.terms:
      if sameVars(at, bt):
        let wCoeff = int32((at.coeff.int64 * pA + bt.coeff.int64 * pB) div 255)
        if wCoeff > 0:
          var t = at
          t.coeff = wCoeff
          result.terms.add(t)
        matched = true
        break
    if not matched:
      var t = at
      t.coeff = int32(at.coeff.int64 * pA div 255)
      if t.coeff > 0:
        result.terms.add(t)
  # Process b's terms that weren't matched by a
  for bt in b.terms:
    var found = false
    for at in a.terms:
      if sameVars(at, bt):
        found = true
        break
    if not found:
      var t = bt
      t.coeff = int32(bt.coeff.int64 * pB div 255)
      if t.coeff > 0 and result.terms.len < MaxTerms:
        result.terms.add(t)

proc loopWrap*(body: CostPoly, varId: CostVarId): CostPoly =
  ## Wrap a loop body cost with a symbolic trip count variable.
  ## body = "c + Σ(aᵢ·product_i)" becomes:
  ##   result = overhead + c·n[varId] + Σ(aᵢ·n[varId]·product_i)
  result.constant = LoopOverhead
  # Promote body.constant into a term with the new variable
  if body.constant > 0:
    result.terms.add(initTerm(body.constant, varId))
  # Each existing term gets the new variable appended
  for t in body.terms:
    let promoted = termWithAppendedVar(t, varId)
    if promoted.coeff > 0 and result.terms.len < MaxTerms:
      result.terms.add(promoted)

proc scale*(a: CostPoly, factor: int32): CostPoly =
  ## Multiply by a concrete factor (e.g., a known trip count from PGO).
  result.constant = a.constant * factor
  for t in a.terms:
    var scaled = t
    scaled.coeff = t.coeff * factor
    result.terms.add(scaled)

proc concretize*(a: CostPoly, varId: CostVarId, value: int32): CostPoly =
  ## Substitute n[varId] = value. Terms containing varId have that variable
  ## removed and their coefficient multiplied by value. If removal makes the
  ## term constant (no remaining variables), fold into result.constant.
  result.constant = a.constant
  for t in a.terms:
    var hasVar = false
    var remaining: CostTerm
    remaining.coeff = t.coeff
    var ri = 0
    for i in 0 ..< MaxTermVars:
      remaining.vars[i] = -1
    for i in 0 ..< MaxTermVars:
      if t.vars[i] == varId:
        hasVar = true
        remaining.coeff = remaining.coeff * value
      elif t.vars[i] >= 0:
        if ri < MaxTermVars:
          remaining.vars[ri] = t.vars[i]
          inc ri
    if hasVar:
      if ri == 0:
        # Fully concretized — fold into constant
        result.constant += remaining.coeff
      elif result.terms.len < MaxTerms:
        result.terms.add(remaining)
    else:
      # varId not in this term — keep as-is
      if result.terms.len < MaxTerms:
        result.terms.add(t)

proc dominantTerm*(a: CostPoly): CostTerm =
  ## The term with the highest variable degree (ties: largest coefficient).
  ## Used for asymptotic comparison.
  var best = CostTerm(coeff: a.constant, vars: [-1.CostVarId, -1, -1])
  var bestDeg = 0
  for t in a.terms:
    let d = termDegree(t)
    if d > bestDeg or (d == bestDeg and t.coeff > best.coeff):
      best = t
      bestDeg = d
  best

proc hasSymbolicTerms*(a: CostPoly): bool =
  a.terms.len > 0

# =========================================================================
# CostVector operations (lift CostPoly ops)
# =========================================================================

proc zeroVec*(): CostVector = discard  # all fields zero-init

proc addVec*(a, b: CostVector): CostVector =
  result.cycles = add(a.cycles, b.cycles)
  result.codeSize = add(a.codeSize, b.codeSize)
  result.memOps = add(a.memOps, b.memOps)
  result.regPressure = max(a.regPressure, b.regPressure)
  result.fpRegPressure = max(a.fpRegPressure, b.fpRegPressure)
  result.spillEstimate = max(a.spillEstimate, b.spillEstimate)

proc joinVec*(a, b: CostVector): CostVector =
  result.cycles = join(a.cycles, b.cycles)
  result.codeSize = add(a.codeSize, b.codeSize)  # both branches emit code
  result.memOps = join(a.memOps, b.memOps)
  result.regPressure = max(a.regPressure, b.regPressure)
  result.fpRegPressure = max(a.fpRegPressure, b.fpRegPressure)
  result.spillEstimate = max(a.spillEstimate, b.spillEstimate)

proc weightedJoinVec*(a, b: CostVector, probA: uint8): CostVector =
  result.cycles = weightedJoin(a.cycles, b.cycles, probA)
  result.codeSize = add(a.codeSize, b.codeSize)
  result.memOps = weightedJoin(a.memOps, b.memOps, probA)
  result.regPressure = max(a.regPressure, b.regPressure)
  result.fpRegPressure = max(a.fpRegPressure, b.fpRegPressure)
  result.spillEstimate = max(a.spillEstimate, b.spillEstimate)

proc loopWrapVec*(body: CostVector, varId: CostVarId): CostVector =
  result.cycles = loopWrap(body.cycles, varId)
  result.codeSize = body.codeSize  # code size doesn't scale with iterations
  result.memOps = loopWrap(body.memOps, varId)
  result.regPressure = body.regPressure
  result.fpRegPressure = body.fpRegPressure
  result.spillEstimate = body.spillEstimate

# =========================================================================
# Part 2: Transfer Functions
# =========================================================================

type
  CostDelta* = object
    cycles*: int32
    codeSize*: int32
    memOps*: int32

proc instrCostDelta*(op: IrOpKind): CostDelta =
  ## Map an IR op to its estimated Tier 2 generated-code cost.
  ##
  ## We start from the scheduler's latency model but override specific ops
  ## where the scheduler models interpreter/stack-machine behaviour that
  ## doesn't apply after register allocation:
  ##
  ##   irLocalGet/Set: scheduler says 4/1 (memory load/store for locals array).
  ##     After regalloc, locals live in registers → 0 cycles (eliminated) or
  ##     1 cycle (register move). We use 0: the optimizer promotes most
  ##     LocalGet/Set into SSA values, and regalloc handles the rest.
  ##
  ##   irCall: scheduler says 1 (branch unit). Real cost is higher: callee
  ##     prologue/epilogue, argument passing, potential spills around the call.
  ##     We use 5 to reflect this (bl + save/restore linkage registers).
  ##
  ##   irCallIndirect: scheduler says 20. We keep this — it includes the
  ##     inline cache lookup, type check, and indirect branch penalty.

  # Cycle cost: scheduler baseline with overrides for post-regalloc reality
  result.cycles = case op
    of irLocalGet, irLocalSet:
      0'i32  # eliminated by regalloc / SSA promotion
    of irCall:
      5'i32  # bl + callee prologue/epilogue overhead
    of irPhi:
      0'i32  # eliminated (coalesced or becomes a register move)
    else:
      getLatency(op).latency.int32

  # Estimate native code bytes per IR instruction
  result.codeSize = case op
    of irConst32, irParam, irNop, irPhi: 0'i32   # eliminated or free
    of irLocalGet, irLocalSet: 0  # eliminated by regalloc
    of irConst64: 8   # movz + movk pair
    of irCall: 16     # bl + prologue/epilogue glue
    of irCallIndirect: 40  # IC lookup + type check + blr + spill
    of irLoad32, irLoad64, irLoad8U, irLoad8S, irLoad16U, irLoad16S,
       irLoad32U, irLoad32S, irLoadF32, irLoadF64: 8  # ldr + bounds check
    of irStore32, irStore64, irStore8, irStore16, irStore32From64,
       irStoreF32, irStoreF64: 8  # str + bounds check
    of irLoadV128: 8
    of irStoreV128: 8
    of irDiv32S, irDiv32U, irRem32S, irRem32U,
       irDiv64S, irDiv64U, irRem64S, irRem64U: 12  # division + trap check
    of irTrap: 8  # branch + trap stub
    else: 4  # most ARM64 instructions = 4 bytes

  # Linear memory operations (loads/stores to WASM linear memory)
  # LocalGet/Set are NOT memory ops — they're register-allocated locals.
  result.memOps = case op
    of irLoad32, irLoad64, irLoad8U, irLoad8S, irLoad16U, irLoad16S,
       irLoad32U, irLoad32S, irLoadF32, irLoadF64, irLoadV128: 1'i32
    of irStore32, irStore64, irStore8, irStore16, irStore32From64,
       irStoreF32, irStoreF64, irStoreV128: 1
    of irCall: 2      # callee may spill/reload around call boundary
    of irCallIndirect: 3  # IC + callee spills
    else: 0

# =========================================================================
# Part 3: Block Analysis
# =========================================================================

const
  irLoadOps* = {irLoad32, irLoad64, irLoad8U, irLoad8S, irLoad16U, irLoad16S,
                irLoad32U, irLoad32S, irLoadF32, irLoadF64, irLoadV128}
  irStoreOps* = {irStore32, irStore64, irStore8, irStore16, irStore32From64,
                 irStoreF32, irStoreF64, irStoreV128}
  irMemOps* = irLoadOps + irStoreOps
  boundsCheckedFlag = 0x40000000'i32  ## from optimize.nim

proc memAccessCycleCost(class: MemAccessClass, isStore: bool): int32 =
  case class
  of macSequentialScan: (if isStore: 1'i32 else: 2)
  of macStructField: 4
  of macPointerChase: 10
  of macDefault: 4

proc classifyMemoryAccesses*(bb: BasicBlock, origins: seq[PtrOrigin]): seq[MemAccessClass] =
  ## Classify each instruction's memory access pattern within a basic block.
  ## Non-memory instructions get macDefault (ignored by the caller).
  result = newSeq[MemAccessClass](bb.instrs.len)
  for i in 0 ..< result.len:
    result[i] = macDefault

  if origins.len == 0:
    return

  # Step 1: Collect memory accesses with their canonical (root, offset)
  type MemRecord = object
    instrIdx: int
    root: IrValue
    totalOffset: int64
    isLoad: bool

  var records: seq[MemRecord]
  # Track which SSA values are produced by loads in this BB (for pointer chase)
  var loadResults: set[int16]

  for i, instr in bb.instrs:
    if instr.op notin irMemOps: continue
    let isLoad = instr.op in irLoadOps
    let addr0 = instr.operands[0]
    if addr0 < 0: continue

    let staticOffset = (instr.imm2 and (not boundsCheckedFlag)).int64
    let origin: PtrOrigin =
      if addr0.int >= 0 and addr0.int < origins.len: origins[addr0.int]
      else: (addr0, 0'i64)
    let totalOff = origin.offset + staticOffset

    records.add(MemRecord(instrIdx: i, root: origin.root,
                           totalOffset: totalOff, isLoad: isLoad))

    if isLoad and instr.result >= 0:
      loadResults.incl(instr.result.int16)

  if records.len == 0: return

  # Step 2: Pointer chase detection (takes priority over group classification)
  for i, instr in bb.instrs:
    if instr.op notin irLoadOps: continue
    let addr0 = instr.operands[0]
    if addr0 >= 0 and addr0.int16 in loadResults:
      result[i] = macPointerChase

  # Step 3: Group by root, classify stride patterns
  # Simple O(n²) grouping — BB sizes are typically <50 instructions
  var processed = newSeq[bool](records.len)
  for i in 0 ..< records.len:
    if processed[i]: continue
    if result[records[i].instrIdx] == macPointerChase: continue  # already classified

    # Collect group: all records with the same root
    var group: seq[int]  # indices into records
    group.add(i)
    for j in (i + 1) ..< records.len:
      if processed[j]: continue
      if records[j].root == records[i].root:
        group.add(j)
        processed[j] = true
    processed[i] = true

    if group.len < 2:
      # Single access from this root — keep default
      continue

    # Sort group by offset
    var offsets = newSeq[int64](group.len)
    for gi, ri in group:
      offsets[gi] = records[ri].totalOffset
    offsets.sort()

    # Check for constant stride
    var isStrided = true
    let stride = if offsets.len >= 2: offsets[1] - offsets[0] else: 0
    if stride > 0 and stride in [1'i64, 2, 4, 8, 16]:
      for k in 2 ..< offsets.len:
        if offsets[k] - offsets[k - 1] != stride:
          isStrided = false
          break
    else:
      isStrided = false

    # Classify the group
    let class = if isStrided: macSequentialScan else: macStructField
    for ri in group:
      let idx = records[ri].instrIdx
      if result[idx] != macPointerChase:  # don't override pointer chase
        result[idx] = class

# --- Callee cost cache and analyzeBlock are defined after StaticFuncProfile (Part 6) ---

proc analyzeBlock*(bb: BasicBlock, f: IrFunc,
                   origins: seq[PtrOrigin] = @[],
                   calleeCostCachePtr: pointer = nil,
                   selfFuncIdx: int = -1,
                   pgoData: ptr FuncPgoData = nil): CostVector =
  ## Compute the cost of a single basic block.
  ## With origins: uses memory access pattern classification.
  ## With calleeCostCachePtr: uses callee body cost for irCall.
  ## With pgoData: devirtualizes irCallIndirect using hot callee profile.
  var memClasses: seq[MemAccessClass]
  if origins.len > 0:
    memClasses = classifyMemoryAccesses(bb, origins)

  # Track call_indirect site index for PGO profile lookup
  var callIndirectSiteIdx = 0

  for i, instr in bb.instrs:
    let d = instrCostDelta(instr.op)

    # Memory ops: use classified cost if available
    var cycles = d.cycles
    if instr.op in irMemOps and memClasses.len > i:
      cycles = memAccessCycleCost(memClasses[i], instr.op in irStoreOps)

    # Direct calls: use callee cost if available (skip self-calls)
    if instr.op == irCall and calleeCostCachePtr != nil and
       instr.imm.int != selfFuncIdx:
      cycles = lookupCalleeCostRaw(calleeCostCachePtr, instr.imm.int)

    # Indirect calls: devirtualize via PGO if hot callee is known
    if instr.op == irCallIndirect:
      if pgoData != nil and calleeCostCachePtr != nil:
        # Scan PGO data for call_indirect profiles with recorded targets
        if callIndirectSiteIdx < pgoData.callIndirectProfiles.len:
          let prof = addr pgoData.callIndirectProfiles[callIndirectSiteIdx]
          if not isMegamorphic(prof):
            let hotCallee = hotCalleeOf(prof)
            if hotCallee >= 0:
              # Monomorphic: dispatch overhead + hot callee body cost
              cycles = 20 + lookupCalleeCostRaw(calleeCostCachePtr, hotCallee.int)
      inc callIndirectSiteIdx

    result.cycles.constant += cycles
    result.codeSize.constant += d.codeSize
    result.memOps.constant += d.memOps

proc estimateBlockPressure*(bb: BasicBlock, isSimd: openArray[bool],
                            numValues: int): tuple[intRegs, fpRegs: int16] =
  ## Backward liveness sweep to estimate peak register pressure.
  ## O(instructions) per block, no graph construction.
  if bb.instrs.len == 0:
    return (0'i16, 0'i16)

  # Use a flat bool array for liveness. True = currently live.
  var live = newSeq[bool](numValues)
  var liveInt: int16 = 0
  var liveFP: int16 = 0
  var peakInt: int16 = 0
  var peakFP: int16 = 0

  # Walk instructions in reverse
  for i in countdown(bb.instrs.len - 1, 0):
    let instr = bb.instrs[i]

    # Kill the result (no longer live after its definition)
    if instr.result >= 0 and instr.result.int < numValues:
      let v = instr.result.int
      if live[v]:
        live[v] = false
        if v < isSimd.len and isSimd[v]:
          discard  # SIMD tracked separately, skip for now
        else:
          # Heuristic: FP ops produce FP values
          let isFP = instr.op in {irAddF32, irSubF32, irMulF32, irDivF32,
            irAbsF32, irNegF32, irSqrtF32, irMinF32, irMaxF32,
            irCeilF32, irFloorF32, irTruncF32, irNearestF32,
            irCopysignF32, irLoadF32,
            irFmaF32, irFmsF32, irFnmaF32, irFnmsF32,
            irAddF64, irSubF64, irMulF64, irDivF64,
            irAbsF64, irNegF64, irSqrtF64, irMinF64, irMaxF64,
            irCeilF64, irFloorF64, irTruncF64, irNearestF64,
            irCopysignF64, irLoadF64,
            irFmaF64, irFmsF64, irFnmaF64, irFnmsF64,
            irConstF32, irConstF64,
            irF32ConvertI32S, irF32ConvertI32U, irF32ConvertI64S, irF32ConvertI64U,
            irF64ConvertI32S, irF64ConvertI32U, irF64ConvertI64S, irF64ConvertI64U,
            irF32DemoteF64, irF64PromoteF32, irF32ReinterpretI32, irF64ReinterpretI64}
          if isFP:
            dec liveFP
          else:
            dec liveInt

    # Birth operands (become live at their use)
    for opIdx in 0 ..< 3:
      let op = instr.operands[opIdx]
      if op >= 0 and op.int < numValues and not live[op.int]:
        live[op.int] = true
        if op.int < isSimd.len and isSimd[op.int]:
          discard
        else:
          # Check if operand is from an FP-producing instruction
          # Heuristic: assume same class as the consuming instruction
          # (accurate enough for pressure estimation)
          let isFPUse = instr.op in {irAddF32, irSubF32, irMulF32, irDivF32,
            irStoreF32, irStoreF64,
            irAddF64, irSubF64, irMulF64, irDivF64,
            irFmaF32, irFmsF32, irFnmaF32, irFnmsF32,
            irFmaF64, irFmsF64, irFnmaF64, irFnmsF64,
            irF32DemoteF64, irF64PromoteF32,
            irI32ReinterpretF32, irI64ReinterpretF64}
          if isFPUse:
            inc liveFP
          else:
            inc liveInt

    if liveInt > peakInt: peakInt = liveInt
    if liveFP > peakFP: peakFP = liveFP

  result = (peakInt, peakFP)

# =========================================================================
# Part 4: Loop Detection and CFG Composition
# =========================================================================

proc estimateTripCount*(exitProb: uint8): int32 =
  ## Convert loop-exit probability to estimated trip count.
  ## Geometric distribution: E[trips] = 1/P(exit).
  ## exitProb is in [0, 255] where 255 = always exits.
  if exitProb == 0: return -1  # truly unknown → keep symbolic
  if exitProb >= 255: return 1
  result = int32(min(255.0 / exitProb.float, 10000.0))

type
  DetectedLoop = object
    headerBb: int
    backEdgeBb: int
    bodyBlocks: seq[int]  # BB indices in the loop body (between header+1 and backEdge)

proc isReachable(f: IrFunc, src, dst: int): bool =
  ## Check if `dst` is reachable from `src` via CFG successor edges.
  ## Used to validate back-edges: a back-edge pred→header is real if
  ## header can reach pred through forward edges.
  if src == dst: return true
  var visited = newSeq[bool](f.blocks.len)
  var stack = @[src]
  visited[src] = true
  while stack.len > 0:
    let cur = stack.pop()
    for succ in f.blocks[cur].successors:
      if succ == dst: return true
      if succ >= 0 and succ < f.blocks.len and not visited[succ]:
        visited[succ] = true
        stack.add(succ)
  false

proc detectLoops*(f: IrFunc): seq[DetectedLoop] =
  ## Identify loops via back-edges in the CFG.
  ## A back-edge is pred→header where header can reach pred through
  ## forward CFG edges (forming a cycle).
  for bbIdx in 0 ..< f.blocks.len:
    for pred in f.blocks[bbIdx].predecessors:
      if pred >= bbIdx and isReachable(f, bbIdx, pred):
        var loop = DetectedLoop(headerBb: bbIdx, backEdgeBb: pred)
        # Collect body blocks: all blocks reachable from header that can
        # reach the back-edge source (i.e., blocks in the loop body).
        var visited = newSeq[bool](f.blocks.len)
        var stack = @[bbIdx]
        visited[bbIdx] = true
        while stack.len > 0:
          let cur = stack.pop()
          for succ in f.blocks[cur].successors:
            if succ >= 0 and succ < f.blocks.len and not visited[succ]:
              # Don't follow edges out of the loop (past the back-edge source)
              # Include the block if it's between header and back-edge or
              # if it can reach the back-edge source
              visited[succ] = true
              stack.add(succ)
              if succ != bbIdx:  # don't include header as body block
                loop.bodyBlocks.add(succ)
        result.add(loop)

proc findLoopExitProb(f: IrFunc, headerBb: int,
                      pgoData: ptr FuncPgoData): uint8 =
  ## Find the exit probability of the loop at headerBb.
  ## The loop exit is typically a brIf at the back-edge or header.
  ## We look for the irBrIf that branches to the header (back-edge)
  ## and invert its probability to get exit probability.
  let bb = f.blocks[headerBb]
  # Check last instruction of header for a conditional branch
  if bb.instrs.len > 0:
    let last = bb.instrs[^1]
    if last.op == irBrIf and last.branchProb > 0:
      # branchProb = probability of TAKING the branch
      # If the branch goes back to the header, taken = stay, exit = 1-taken
      # If the branch exits the loop, taken = exit
      # Determine direction by checking if taken successor is the header itself
      if bb.successors.len > 0 and bb.successors[0] == headerBb:
        # Taken branch goes to header → prob is "stay" probability
        return 255'u8 - last.branchProb
      else:
        # Taken branch exits → prob is exit probability
        return last.branchProb
  # Check back-edge block's last instruction
  for bodyBb in 0 ..< f.blocks.len:
    if bodyBb <= headerBb: continue
    let blk = f.blocks[bodyBb]
    if headerBb in blk.successors:
      if blk.instrs.len > 0:
        let last = blk.instrs[^1]
        if last.op == irBrIf and last.branchProb > 0:
          if blk.successors.len > 0 and blk.successors[0] == headerBb:
            return 255'u8 - last.branchProb
          else:
            return last.branchProb
  return 0  # unknown

proc computeBlockFrequencies*(f: IrFunc): seq[float32] =
  ## Forward propagation of expected execution frequency per basic block.
  ## Entry block = 1.0. At branches, frequency splits by branchProb.
  ## At merge points, incoming frequencies sum. Loop headers accumulate
  ## back-edge frequency (but we cap at 1.0 for the non-loop-scaled part;
  ## the symbolic loop cost handles the iteration count separately).
  let n = f.blocks.len
  if n == 0: return @[]
  result = newSeq[float32](n)
  result[0] = 1.0  # entry block

  # Process blocks in order (structured CF → RPO ≈ block index order)
  for i in 0 ..< n:
    let freq = result[i]
    if freq == 0: continue
    let bb = f.blocks[i]
    if bb.instrs.len == 0: continue

    let last = bb.instrs[^1]
    case last.op
    of irBr:
      # Unconditional: all frequency goes to successor
      let target = last.imm.int
      if target >= 0 and target < n:
        result[target] += freq
    of irBrIf:
      # Conditional: split by branch probability
      let prob = last.branchProb
      if bb.successors.len >= 2:
        let takenIdx = bb.successors[0]
        let fallthroughIdx = bb.successors[1]
        if prob > 0 and prob != 128:
          let pTaken = prob.float32 / 255.0
          if takenIdx >= 0 and takenIdx < n:
            result[takenIdx] += freq * pTaken
          if fallthroughIdx >= 0 and fallthroughIdx < n:
            result[fallthroughIdx] += freq * (1.0 - pTaken)
        else:
          # No PGO or 50/50: split evenly
          if takenIdx >= 0 and takenIdx < n:
            result[takenIdx] += freq * 0.5
          if fallthroughIdx >= 0 and fallthroughIdx < n:
            result[fallthroughIdx] += freq * 0.5
      elif bb.successors.len == 1:
        let target = bb.successors[0]
        if target >= 0 and target < n:
          result[target] += freq
    of irReturn:
      discard  # frequency ends here
    else:
      # For blocks without explicit terminators, frequency flows to next block
      if i + 1 < n:
        result[i + 1] += freq

  # Cap frequencies at a reasonable maximum (loop headers can accumulate
  # unbounded frequency from back-edges; we cap at 1.0 since loop scaling
  # is handled separately by the symbolic cost model)
  for i in 0 ..< n:
    if result[i] > 1.0:
      result[i] = 1.0

proc analyzeCost*(f: IrFunc, pgoData: ptr FuncPgoData = nil,
                  calleeCostCachePtr: pointer = nil,
                  selfFuncIdx: int = -1): CostState =
  ## Abstract interpretation over the function's CFG.
  ## Structured single-pass: compute per-block costs, detect loops,
  ## compose through control flow (add for sequence, join for branches,
  ## loopWrap for loops), resolve PGO trip counts.
  let numBlocks = f.blocks.len
  if numBlocks == 0:
    return

  result.bbCount = numBlocks.int16
  result.ssaValueCount = f.numValues.int32

  # Build pointer origins for memory access pattern classification
  let origins = buildPtrOrigins(f)

  # Step 1: Per-block costs (with memory classification and callee cost)
  result.perBlock = newSeq[CostVector](numBlocks)
  for i in 0 ..< numBlocks:
    result.perBlock[i] = analyzeBlock(f.blocks[i], f, origins,
                                       calleeCostCachePtr, selfFuncIdx, pgoData)
    let (intP, fpP) = estimateBlockPressure(f.blocks[i], f.isSimd, f.numValues)
    result.perBlock[i].regPressure = intP
    result.perBlock[i].fpRegPressure = fpP
    result.perBlock[i].spillEstimate = max(intP - CostNumIntRegs.int16, 0'i16)

  # Step 2: Detect loops
  let detectedLoops = detectLoops(f)

  # Assign cost variables to loops
  var nextVarId: CostVarId = 0
  for dl in detectedLoops:
    let varId = nextVarId
    inc nextVarId

    # Sum body block costs (header + body blocks between header and back-edge)
    var bodyCost = result.perBlock[dl.headerBb]
    for bodyBb in dl.bodyBlocks:
      bodyCost = addVec(bodyCost, result.perBlock[bodyBb])

    # Check if innermost (no other loop's header is inside this loop's body)
    var innermost = true
    for otherLoop in detectedLoops:
      if otherLoop.headerBb != dl.headerBb and
         otherLoop.headerBb > dl.headerBb and
         otherLoop.headerBb <= dl.backEdgeBb:
        innermost = false
        break

    # PGO trip count
    var trips: int32 = -1
    if pgoData != nil:
      let exitProb = findLoopExitProb(f, dl.headerBb, pgoData)
      if exitProb > 0:
        trips = estimateTripCount(exitProb)

    result.loopVars.add(LoopVarInfo(
      headerBb: dl.headerBb.int16,
      depth: 0,  # will refine below
      estimatedTrips: trips
    ))

    result.loops.add(LoopInfo(
      varId: varId,
      headerBb: dl.headerBb.int16,
      backEdgeBb: dl.backEdgeBb.int16,
      bodyCost: bodyCost,
      isInnermost: innermost,
      estimatedTrips: trips
    ))

  # Compute nesting depth for each loop
  for i in 0 ..< result.loops.len:
    var depth: int8 = 0
    for j in 0 ..< result.loops.len:
      if i != j and
         result.loops[j].headerBb < result.loops[i].headerBb and
         result.loops[j].backEdgeBb >= result.loops[i].backEdgeBb:
        inc depth
    result.loopVars[i].depth = depth

  # Step 3: Compose function total
  # For a structured CFG, we walk blocks in order and compose:
  # - Sequential blocks: add
  # - Branch points: join (or weighted join with PGO)
  # - Loops: wrap body with symbolic variable
  #
  # Simplified approach: sum all block costs, then wrap loops.
  # This over-approximates branch costs (takes both paths) but is
  # sound and fast. The hotPath uses PGO-weighted joins.

  # Compute block frequencies for the hot-path cost estimate
  let blockFreqs = computeBlockFrequencies(f)

  # funcTotal: sum of all blocks weighted by execution frequency.
  # Cold blocks (after unlikely branches) contribute less to the total.
  result.funcTotal = zeroVec()
  for i in 0 ..< numBlocks:
    let freq = if i < blockFreqs.len: blockFreqs[i] else: 1.0'f32
    if freq >= 0.99:
      # Hot block (always executed): add full cost
      result.funcTotal = addVec(result.funcTotal, result.perBlock[i])
    elif freq > 0.01:
      # Warm block: scale cycles and memOps by frequency
      var scaled = result.perBlock[i]
      scaled.cycles.constant = int32(scaled.cycles.constant.float * freq)
      scaled.memOps.constant = int32(scaled.memOps.constant.float * freq)
      # codeSize is not frequency-dependent (both paths emit code)
      result.funcTotal = addVec(result.funcTotal, scaled)
    else:
      # Cold block (near-zero frequency): only count code size
      result.funcTotal.codeSize = add(result.funcTotal.codeSize, result.perBlock[i].codeSize)

  # For loops, the body blocks are counted once in the sum above,
  # but the actual cost scales with trip count. Replace the flat body
  # cost with the loop-wrapped version.
  for loop in result.loops:
    # Subtract the flat body cost (it was added once in the total)
    # then add the wrapped version
    let wrappedBody = loopWrapVec(loop.bodyCost, loop.varId)
    # Subtract body from funcTotal cycles/memOps (not codeSize — that doesn't scale)
    result.funcTotal.cycles.constant -= loop.bodyCost.cycles.constant
    result.funcTotal.cycles = add(result.funcTotal.cycles, wrappedBody.cycles)
    result.funcTotal.memOps.constant -= loop.bodyCost.memOps.constant
    result.funcTotal.memOps = add(result.funcTotal.memOps, wrappedBody.memOps)

  # hotPath: concretize with PGO trip counts where available
  result.hotPath = result.funcTotal
  for loop in result.loops:
    if loop.estimatedTrips > 0:
      result.hotPath.cycles = concretize(result.hotPath.cycles,
                                          loop.varId, loop.estimatedTrips)
      result.hotPath.memOps = concretize(result.hotPath.memOps,
                                          loop.varId, loop.estimatedTrips)

  # Overall register pressure = max across all blocks
  result.funcTotal.regPressure = 0
  result.funcTotal.fpRegPressure = 0
  result.funcTotal.spillEstimate = 0
  for i in 0 ..< numBlocks:
    if result.perBlock[i].regPressure > result.funcTotal.regPressure:
      result.funcTotal.regPressure = result.perBlock[i].regPressure
    if result.perBlock[i].fpRegPressure > result.funcTotal.fpRegPressure:
      result.funcTotal.fpRegPressure = result.perBlock[i].fpRegPressure
    if result.perBlock[i].spillEstimate > result.funcTotal.spillEstimate:
      result.funcTotal.spillEstimate = result.perBlock[i].spillEstimate
  result.hotPath.regPressure = result.funcTotal.regPressure
  result.hotPath.fpRegPressure = result.funcTotal.fpRegPressure
  result.hotPath.spillEstimate = result.funcTotal.spillEstimate

  # Estimate JIT compile time (Layer 2: JIT's own resource cost)
  # ~2µs per SSA value for core O(n) passes, more for global passes
  let baseUs = result.ssaValueCount * 2
  let globalUs = if numBlocks > 3: numBlocks.int32 * result.ssaValueCount div 10
                 else: 0
  let regAllocUs = result.ssaValueCount * numBlocks.int32 div 5
  result.estimatedCompileTimeUs = baseUs + globalUs + regAllocUs

# =========================================================================
# Part 5: Decision APIs
# =========================================================================

# --- Decision 1: Optimization pass gating ---

proc computeOptGating*(cost: CostState): OptGating =
  ## Decide which optimization passes to enable based on the cost profile.
  ## Core passes (constantFold, strengthReduce, instrCombine, local CSE,
  ## local BCE, DCE) always run — they're O(n) and always beneficial.
  let hasLoops = cost.loops.len > 0
  let hasSignificantMem = cost.funcTotal.memOps.constant > 5 or
                          cost.funcTotal.memOps.hasSymbolicTerms
  let bbCount = cost.bbCount.int

  result.runLICM = hasLoops
  result.runLoopBCEHoist = hasLoops and hasSignificantMem
  result.runLoopUnroll = hasLoops and cost.loops.anyIt(
    it.isInnermost and it.bodyCost.cycles.constant < 80)
  result.runGlobalCSE = bbCount > 3
  result.runGlobalBCE = hasSignificantMem and bbCount > 1
  result.runAliasBCE = hasSignificantMem
  result.runAliasGlobalBCE = result.runAliasBCE and bbCount > 3
  result.runStoreLoadForward = hasSignificantMem
  result.runPromoteLocals = cost.funcTotal.regPressure > 4
  result.runFMA = true  # cheap, always run

  # Estimate compile time for enabled passes
  let n = cost.ssaValueCount
  var us = n * 7  # core always-on passes: ~7µs/value
  if result.runGlobalCSE: us += bbCount.int32 * n div 8
  if result.runAliasBCE: us += n * 3
  if result.runAliasGlobalBCE: us += bbCount.int32 * n div 6
  if result.runLICM: us += n * 2
  if result.runLoopUnroll: us += n * 4
  us += n * bbCount.int32 div 5  # regalloc
  result.estimatedCompileTimeUs = us

# --- Decision 2: Inlining ---

proc computeInlineDecision*(callerCost: CostState, calleeCost: CostState,
                            callBbIdx: int,
                            inlinesSoFar: int): InlineDecision =
  ## Should we inline this callee at this call site?
  ## Uses multi-factor benefit/cost analysis with register pressure awareness.

  # Reject callees with loops — their cost is symbolic (unbounded growth)
  if calleeCost.funcTotal.cycles.hasSymbolicTerms:
    return InlineDecision(shouldInline: false, benefit: 0,
                          codeGrowth: calleeCost.funcTotal.codeSize.constant)

  let callOverhead = 10'i32  # call + return + arg shuffle
  let calleeCycles = calleeCost.funcTotal.cycles.constant
  let codeGrowth = calleeCost.funcTotal.codeSize.constant

  # Register pressure impact
  let callerPressure = if callBbIdx >= 0 and callBbIdx < callerCost.perBlock.len:
                         callerCost.perBlock[callBbIdx].regPressure
                       else: callerCost.funcTotal.regPressure
  let calleePressure = calleeCost.funcTotal.regPressure
  let combinedPressure = callerPressure.int + calleePressure.int
  let spillPenalty = max(combinedPressure - CostNumIntRegs, 0).int32 * 8

  let benefit = callOverhead + calleeCycles - spillPenalty

  # Diminishing returns: each successive inline reduces benefit
  let adjustedBenefit = if inlinesSoFar == 0: benefit
                        else: benefit * 7 div (10 + inlinesSoFar.int32 * 3)

  result.benefit = adjustedBenefit
  result.codeGrowth = codeGrowth
  result.shouldInline = adjustedBenefit > 0 and
                        codeGrowth < 200 and
                        calleeCost.bbCount <= 12

# --- Decision 3: Tier thresholds ---

proc computeTierThresholds*(cost: CostState,
                            poolUsedBytes: int = 0,
                            poolCapacity: int = 4 * 1024 * 1024,
                            bgQueueDepth: int = 0):
    tuple[tier1, tier2, priority: int32] =
  ## Compute adaptive tier-up thresholds from the cost profile.

  # How much does JIT help this function per call?
  # Use hotPath if PGO-concretized, else use dominant term coefficient
  let cyclesPerCall = if cost.hotPath.cycles.constant > 0:
                        cost.hotPath.cycles.constant
                      else:
                        let dom = dominantTerm(cost.funcTotal.cycles)
                        dom.coeff * 100  # assume 100 iterations for unknown loops
  let jitSpeedup = cyclesPerCall - cyclesPerCall div InterpSlowdown
  let compileCost = cost.funcTotal.codeSize.constant * 10  # proxy

  # Tier 1: breakeven = compileCost / speedup_per_call
  let breakevenCalls = if jitSpeedup > 0: compileCost div jitSpeedup
                       else: 500
  result.tier1 = breakevenCalls.clamp(10, 500)

  # Tier 2: additionally consider optimization opportunity
  let hasLoops = cost.loops.len > 0
  let optBenefit = if hasLoops:
                     max(cost.loops.len.int32 * 5, 3)
                   else: 1
  let baseTier2 = max(breakevenCalls * 10, 500)

  # Memory pool pressure: raise threshold when scarce
  let poolFraction = if poolCapacity > 0: poolUsedBytes * 100 div poolCapacity
                     else: 0
  let pressureFactor = if poolFraction > 90: 4'i32
                       elif poolFraction > 75: 2
                       else: 1

  # Background queue pressure
  let queueFactor = if bgQueueDepth > 8: 3'i32
                    elif bgQueueDepth > 4: 2
                    else: 1

  result.tier2 = int32(baseTier2 div optBenefit * pressureFactor * queueFactor)
  result.tier2 = result.tier2.clamp(5, 50000)

  # Compile priority: higher = compile sooner.
  # Weight by loop body cost (heavier loops benefit more from optimization)
  # and spill risk (Tier 2 register allocation helps most when pressure is high).
  var loopWeight: int32 = 0
  for loop in cost.loops:
    loopWeight += loop.bodyCost.cycles.constant  # heavier body = more priority
  result.priority = loopWeight +
                    cost.funcTotal.memOps.constant +
                    (if cost.funcTotal.spillEstimate > 2: cost.funcTotal.spillEstimate.int32 * 5
                     else: 0)

# --- Decision 4: Compile deferral ---

proc shouldDeferCompilation*(cost: CostState, bgQueueDepth: int): bool =
  ## Should this function be deferred to avoid starving the background thread?
  cost.estimatedCompileTimeUs > 50_000 and bgQueueDepth > 2

# --- Decision 5: Cache eviction ---

proc computeEvictionScore*(codeSize: int, compileTimeMs: float,
                           callCount: int, lastUsed: float,
                           cost: CostState, now: float): float32 =
  ## Higher score = more valuable, keep longer. Evict the minimum.
  let recency = 1.0 / max(now - lastUsed, 0.001)
  let frequency = callCount.float
  let cycleCost = cost.funcTotal.cycles.constant.float +
                  cost.funcTotal.cycles.dominantTerm.coeff.float * 10.0
  let density = cycleCost / max(codeSize.float, 1.0)
  let recompileCost = compileTimeMs

  float32(recency * 0.3 + frequency * 0.3 + density * 0.2 + recompileCost * 0.2)

# =========================================================================
# Part 6: Static Bytecode Analysis (no IR lowering required)
# =========================================================================
# This runs at module instantiation time on raw WASM bytecodes.
# Used for tier threshold computation where lowering is too expensive.

type
  StaticFuncProfile* = object
    ## Lightweight cost profile from WASM bytecodes (no IR needed).
    cycles*: CostPoly          ## estimated execution cost
    codeSize*: int32           ## estimated native bytes
    instrCount*: int32         ## post-fusion instruction count
    loopCount*: int16          ## number of loop opcodes
    maxLoopNest*: int8         ## deepest loop nesting
    callCount*: int16          ## direct call sites
    callIndirectCount*: int16  ## indirect call sites
    memAccessCount*: int16     ## loads + stores
    hasSIMD*: bool
    usesGlobals*: bool        ## uses global.get/set (shadow stack — needs Tier 2)
    maxStackDepth*: int16    ## WASM operand stack high-water mark (proxy for reg pressure)
    callerCount*: int16      ## how many other functions call this one (from call graph)
    localCount*: int16
    paramCount*: int16

  CalleeCostCache* = object
    ## Per-module cache of static cost profiles, indexed by code-section index.
    profiles*: seq[StaticFuncProfile]
    importFuncCount*: int

# ---- Call graph ----

type
  CallGraph* = object
    ## Static call graph built from WASM bytecodes.
    callerCount*: seq[int16]   ## per funcIdx: how many other functions call this one
    isLeaf*: seq[bool]         ## per funcIdx: no outgoing calls
    isRecursive*: seq[bool]    ## per funcIdx: directly calls itself

proc buildCallGraph*(module: types.WasmModule): CallGraph =
  ## Build a static call graph by scanning all function bytecodes for opCall.
  ## O(total bytecode size). Used to populate callerCount in StaticFuncProfile.
  var numImportFuncs = 0
  for imp in module.imports:
    if imp.kind == types.ikFunc: inc numImportFuncs
  let totalFuncs = numImportFuncs + module.codes.len
  result.callerCount = newSeq[int16](totalFuncs)
  result.isLeaf = newSeq[bool](totalFuncs)
  result.isRecursive = newSeq[bool](totalFuncs)
  for i in 0 ..< totalFuncs:
    result.isLeaf[i] = true

  for codeIdx in 0 ..< module.codes.len:
    let funcIdx = numImportFuncs + codeIdx
    var callees: set[int16]  # deduplicate within a function
    for instr in module.codes[codeIdx].code.code:
      if instr.op == types.opCall:
        let targetIdx = instr.imm1.int
        if targetIdx >= 0 and targetIdx < totalFuncs:
          result.isLeaf[funcIdx] = false
          if targetIdx == funcIdx:
            result.isRecursive[funcIdx] = true
          if targetIdx.int16 notin callees:
            callees.incl(targetIdx.int16)
            if targetIdx < result.callerCount.len:
              inc result.callerCount[targetIdx]
      elif instr.op == types.opCallIndirect:
        result.isLeaf[funcIdx] = false

# Forward-declared in Part 3 via untyped pointer; actual implementation here.
proc lookupCalleeCostRaw*(cachePtr: pointer, absoluteFuncIdx: int): int32 =
  ## Look up callee cost from an untyped pointer to CalleeCostCache.
  let cache = cast[ptr CalleeCostCache](cachePtr)
  let codeIdx = absoluteFuncIdx - cache.importFuncCount
  if codeIdx < 0 or codeIdx >= cache.profiles.len:
    return 5  # import or out-of-range
  let profile = cache.profiles[codeIdx]
  var bodyCost = profile.cycles.constant
  if profile.cycles.hasSymbolicTerms:
    bodyCost += dominantTerm(profile.cycles).coeff * 10  # ~10 iterations
  result = 5 + bodyCost  # 5 = call/return overhead

proc buildCalleeCostCache*(module: types.WasmModule): CalleeCostCache =
  ## Build a cost cache for all functions in the module using bytecode-level
  ## analysis. Cheap: single pass per function body, no IR lowering.
  ## Also builds the static call graph to populate callerCount per function.
  for imp in module.imports:
    if imp.kind == types.ikFunc:
      inc result.importFuncCount
  let callGraph = buildCallGraph(module)
  result.profiles = newSeq[StaticFuncProfile](module.codes.len)
  for i in 0 ..< module.codes.len:
    let typeIdx = module.funcTypeIdxs[i]
    let funcType = module.types[typeIdx.int]
    var localCount: int16 = funcType.params.len.int16
    for ld in module.codes[i].locals:
      localCount += ld.count.int16
    result.profiles[i] = analyzeStatic(
      module.codes[i].code.code, funcType.params.len.int16, localCount,
      module.codes[i].code.maxStackDepth)
    # Populate caller count from call graph
    let absIdx = result.importFuncCount + i
    if absIdx < callGraph.callerCount.len:
      result.profiles[i].callerCount = callGraph.callerCount[absIdx]

proc wasmOpCycles(op: types.Opcode): int32 =
  ## Estimated post-Tier2 cycle cost per WASM opcode.
  case op
  of opI32Add, opI32Sub, opI32And, opI32Or, opI32Xor,
     opI32Shl, opI32ShrS, opI32ShrU, opI32Rotl, opI32Rotr,
     opI64Add, opI64Sub, opI64And, opI64Or, opI64Xor,
     opI64Shl, opI64ShrS, opI64ShrU, opI64Rotl, opI64Rotr,
     opI32Eq, opI32Ne, opI32LtS, opI32LtU, opI32GtS, opI32GtU,
     opI32LeS, opI32LeU, opI32GeS, opI32GeU, opI32Eqz,
     opI64Eq, opI64Ne, opI64LtS, opI64LtU, opI64GtS, opI64GtU,
     opI64LeS, opI64LeU, opI64GeS, opI64GeU, opI64Eqz,
     opI32Clz, opI32Ctz, opI64Clz, opI64Ctz,
     opI32WrapI64, opI64ExtendI32S, opI64ExtendI32U,
     opI32Extend8S, opI32Extend16S, opI64Extend8S, opI64Extend16S, opI64Extend32S,
     opSelect, opSelectTyped, opDrop,
     opI32ReinterpretF32, opI64ReinterpretF64,
     opF32ReinterpretI32, opF64ReinterpretI64,
     opF32Copysign, opF64Copysign:
    1
  of opI32Mul, opI64Mul, opI32Popcnt, opI64Popcnt:
    3
  of opI32DivS, opI32DivU, opI32RemS, opI32RemU:
    7
  of opI64DivS, opI64DivU, opI64RemS, opI64RemU:
    12
  of opF32Add, opF32Sub, opF32Mul, opF64Add, opF64Sub, opF64Mul,
     opF32Eq, opF32Ne, opF32Lt, opF32Gt, opF32Le, opF32Ge,
     opF64Eq, opF64Ne, opF64Lt, opF64Gt, opF64Le, opF64Ge,
     opF32Abs, opF32Neg, opF64Abs, opF64Neg,
     opF32Ceil, opF32Floor, opF32Trunc, opF32Nearest,
     opF64Ceil, opF64Floor, opF64Trunc, opF64Nearest,
     opF32ConvertI32S, opF32ConvertI32U, opF32ConvertI64S, opF32ConvertI64U,
     opF64ConvertI32S, opF64ConvertI32U, opF64ConvertI64S, opF64ConvertI64U,
     opF32DemoteF64, opF64PromoteF32,
     opI32TruncF32S, opI32TruncF32U, opI32TruncF64S, opI32TruncF64U,
     opI64TruncF32S, opI64TruncF32U, opI64TruncF64S, opI64TruncF64U:
    4
  of opF32Div: 10
  of opF64Div: 15
  of opF32Sqrt: 9
  of opF64Sqrt: 16
  of opI32Load, opI64Load, opF32Load, opF64Load,
     opI32Load8S, opI32Load8U, opI32Load16S, opI32Load16U,
     opI64Load8S, opI64Load8U, opI64Load16S, opI64Load16U,
     opI64Load32S, opI64Load32U:
    4
  of opI32Store, opI64Store, opF32Store, opF64Store,
     opI32Store8, opI32Store16, opI64Store8, opI64Store16, opI64Store32:
    1
  of opCall: 5
  of opCallIndirect: 20
  of opLocalGet, opLocalSet, opLocalTee, opGlobalGet, opGlobalSet: 0
  of opI32Const, opI64Const, opF32Const, opF64Const: 0
  of opBlock, opLoop, opIf, opElse, opEnd, opNop: 0
  of opBr, opBrIf, opBrTable, opReturn: 1
  of opUnreachable: 0
  of opMemorySize, opMemoryGrow: 4
  # Fused superinstructions: cost of the constituent ops
  of opLocalGetLocalGet: 0
  of opLocalGetI32Add, opLocalGetI32Sub: 1
  of opI32ConstI32Add, opI32ConstI32Sub: 1
  of opLocalGetLocalGetI32Add, opLocalGetLocalGetI32Sub: 1
  of opLocalGetI32ConstI32Add, opLocalGetI32ConstI32Sub: 1
  of opLocalGetI32Load: 4
  of opLocalGetI32LoadI32Add: 5
  of opI32EqzBrIf, opI32EqBrIf, opI32NeBrIf,
     opI32LtSBrIf, opI32GeSBrIf, opI32GtSBrIf, opI32LeSBrIf,
     opI32LtUBrIf, opI32GeUBrIf, opI32GtUBrIf, opI32LeUBrIf: 2
  of opI32ConstI32EqBrIf, opI32ConstI32NeBrIf,
     opI32ConstI32LtSBrIf, opI32ConstI32GeSBrIf,
     opI32ConstI32GtUBrIf, opI32ConstI32LeUBrIf: 2
  of opLocalI32AddInPlace, opLocalI32SubInPlace: 1
  of opLocalGetLocalGetI32AddLocalSet, opLocalGetLocalGetI32SubLocalSet: 1
  of opLocalTeeBrIf: 1
  of opLocalGetI32Mul, opI32ConstI32Mul, opLocalGetI32GtS: 3
  of opI32ConstI32GtU, opI32ConstI32LtS, opI32ConstI32GeS: 1
  of opI32ConstI32Eq, opI32ConstI32Ne, opI32ConstI32And: 1
  of opLocalSetLocalGet, opLocalTeeLocalGet, opLocalGetLocalTee: 0
  of opLocalGetI32Const: 0
  of opI32AddLocalSet, opI32SubLocalSet: 1
  of opLocalGetI32Store: 1
  of opLocalGetI64Add, opLocalGetI64Sub: 1
  else: 1  # conservative default

proc wasmOpIsMemory(op: types.Opcode): bool =
  op in {opI32Load, opI64Load, opF32Load, opF64Load,
         opI32Load8S, opI32Load8U, opI32Load16S, opI32Load16U,
         opI64Load8S, opI64Load8U, opI64Load16S, opI64Load16U,
         opI64Load32S, opI64Load32U,
         opI32Store, opI64Store, opF32Store, opF64Store,
         opI32Store8, opI32Store16, opI64Store8, opI64Store16, opI64Store32,
         opLocalGetI32Load, opLocalGetI32Store, opLocalGetI32LoadI32Add}

proc analyzeStatic*(code: openArray[types.Instr], paramCount, localCount: int16,
                    maxStackDepth: int32 = 0): StaticFuncProfile =
  ## Single-pass bytecode analysis. No IR lowering needed.
  ## Walks the instruction stream tracking loop nesting to build symbolic cost.
  result.instrCount = code.len.int32
  result.paramCount = paramCount
  result.localCount = localCount
  result.maxStackDepth = maxStackDepth.int16

  # Track structured nesting to distinguish loop-ends from block-ends
  var nestStack: seq[types.Opcode]  # opBlock, opLoop, opIf, opTryTable
  var loopCostStack: seq[CostPoly]  # saved cost when entering a loop
  var currentCycles = zeroPoly()
  var currentMem = zeroPoly()
  var nextVarId: CostVarId = 0

  for instr in code:
    let op = instr.op
    case op
    of opLoop:
      nestStack.add(opLoop)
      loopCostStack.add(currentCycles)
      currentCycles = zeroPoly()
      inc result.loopCount
      let depth = nestStack.countIt(it == opLoop)
      if depth > result.maxLoopNest: result.maxLoopNest = depth.int8
    of opBlock, opIf:
      nestStack.add(op)
    of opTryTable:
      nestStack.add(opTryTable)
    of opEnd:
      if nestStack.len > 0:
        let closing = nestStack[^1]
        nestStack.setLen(nestStack.len - 1)
        if closing == opLoop:
          # Wrap loop body cost with a fresh symbolic variable
          let savedCost = loopCostStack[^1]
          loopCostStack.setLen(loopCostStack.len - 1)
          let varId = nextVarId; inc nextVarId
          let wrappedCycles = loopWrap(currentCycles, varId)
          currentCycles = add(savedCost, wrappedCycles)
    of opElse:
      discard  # conservative: both branches counted
    else:
      currentCycles.constant += wasmOpCycles(op)
      if wasmOpIsMemory(op): inc result.memAccessCount
      if op in {opGlobalGet, opGlobalSet}: result.usesGlobals = true
      result.codeSize += 4  # approximate 4 bytes per native instruction
      case op
      of opCall: inc result.callCount
      of opCallIndirect: inc result.callIndirectCount
      of opV128Load, opV128Store, opV128Const, opI8x16Splat .. opF64x2Div:
        result.hasSIMD = true
      else: discard

  result.cycles = currentCycles

proc computeStaticTierThresholds*(profile: StaticFuncProfile,
                                  poolUsedBytes: int = 0,
                                  poolCapacity: int = 4 * 1024 * 1024,
                                  bgQueueDepth: int = 0):
    tuple[tier1, tier2: int32] =
  ## Compute tier thresholds from static bytecode analysis.
  ## Used at instantiation time (no IR lowering needed).
  ##
  ## Functions using globals (shadow stack from -O0) skip Tier 1 entirely
  ## (set tier1 = tier2) because Tier 1 doesn't handle globals correctly
  ## for recursive functions. Tier 2 handles globals via local-mapping and
  ## auto-TCO converts the recursion to a loop.

  # Per-call cost estimate: use dominant term coefficient for loop functions,
  # constant for leaf functions
  let perCallCost = if profile.cycles.hasSymbolicTerms:
                      let dom = dominantTerm(profile.cycles)
                      dom.coeff * 100  # assume ~100 iterations
                    else:
                      profile.cycles.constant
  let jitSpeedup = perCallCost - perCallCost div InterpSlowdown
  let compileCost = max(profile.codeSize, 20) * 10

  # Tier 1: breakeven calls
  let breakeven = if jitSpeedup > 0: compileCost div jitSpeedup else: 500'i32
  result.tier1 = breakeven.clamp(10, 500)

  # Tier 2: factor in optimization opportunity
  let hasLoops = profile.loopCount > 0
  let highPressure = profile.maxStackDepth > CostNumIntRegs.int16
  var optBenefit = if hasLoops: max(profile.loopCount.int32 * 3, 3) else: 1'i32
  if highPressure: optBenefit = max(optBenefit, 2)  # high reg pressure → benefit from Tier 2 regalloc
  let baseTier2 = max(breakeven * 10, 500'i32)

  # Pool pressure
  let poolFraction = if poolCapacity > 0: poolUsedBytes * 100 div poolCapacity else: 0
  let pressureFactor = if poolFraction > 90: 4'i32
                       elif poolFraction > 75: 2
                       else: 1

  result.tier2 = int32(baseTier2 div optBenefit * pressureFactor)
  result.tier2 = result.tier2.clamp(5, 50000)

  discard  # usesGlobals no longer affects thresholds; both tiers handle globals
