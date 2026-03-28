## Instruction scheduler: list scheduling with Apple M-series pipeline model
##
## Reorders instructions within basic blocks to minimize pipeline stalls.
## Uses a dependency DAG and priority-based scheduling.

import ir
import ../pgo  # for PgoBranchLikelyThresh, PgoBranchUnlikelyThresh

# ---- Apple Silicon (Firestorm/Avalanche) latency model ----

type
  FunctionalUnit* = enum
    fuALU      # Integer ALU (6 units on M-series)
    fuMul      # Integer multiply (shared with ALU)
    fuDiv      # Integer divide (1 unit, blocking)
    fuLoad     # Load unit (2 units)
    fuStore    # Store unit (2 units)
    fuBranch   # Branch unit

  LatencyInfo* = object
    latency*: int          # cycles from issue to result available
    unit*: FunctionalUnit  # required functional unit

proc getLatency*(op: IrOpKind): LatencyInfo =
  case op
  # ALU: 1 cycle
  of irConst32, irConst64, irConstF32, irConstF64, irParam, irNop:
    LatencyInfo(latency: 0, unit: fuALU)
  of irAdd32, irSub32, irAnd32, irOr32, irXor32,
     irAdd64, irSub64, irAnd64, irOr64, irXor64,
     irShl32, irShr32S, irShr32U, irRotl32, irRotr32,
     irShl64, irShr64S, irShr64U, irRotl64, irRotr64,
     irEq32, irNe32, irLt32S, irLt32U, irGt32S, irGt32U,
     irLe32S, irLe32U, irGe32S, irGe32U, irEqz32,
     irEq64, irNe64, irLt64S, irLt64U, irGt64S, irGt64U,
     irLe64S, irLe64U, irGe64S, irGe64U, irEqz64,
     irWrapI64, irExtendI32S, irExtendI32U,
     irExtend8S32, irExtend16S32, irExtend8S64, irExtend16S64, irExtend32S64,
     irSelect,
     irI32ReinterpretF32, irI64ReinterpretF64,
     irF32ReinterpretI32, irF64ReinterpretI64,
     irCopysignF32, irCopysignF64:
    LatencyInfo(latency: 1, unit: fuALU)
  of irClz32, irCtz32, irClz64, irCtz64:
    LatencyInfo(latency: 1, unit: fuALU)

  # Multiply: 3 cycles
  of irMul32, irMul64:
    LatencyInfo(latency: 3, unit: fuMul)

  # Divide: 7-12 cycles
  of irDiv32S, irDiv32U, irRem32S, irRem32U:
    LatencyInfo(latency: 7, unit: fuDiv)
  of irDiv64S, irDiv64U, irRem64S, irRem64U:
    LatencyInfo(latency: 12, unit: fuDiv)

  # Popcnt (via NEON): 3 cycles
  of irPopcnt32, irPopcnt64:
    LatencyInfo(latency: 3, unit: fuALU)

  # FP arithmetic: 3-4 cycles (Apple M-series NEON/FP pipeline)
  of irAddF32, irSubF32, irMulF32, irAddF64, irSubF64, irMulF64,
     irAbsF32, irNegF32, irAbsF64, irNegF64,
     irMinF32, irMaxF32, irMinF64, irMaxF64,
     irCeilF32, irFloorF32, irTruncF32, irNearestF32,
     irCeilF64, irFloorF64, irTruncF64, irNearestF64,
     irEqF32, irNeF32, irLtF32, irGtF32, irLeF32, irGeF32,
     irEqF64, irNeF64, irLtF64, irGtF64, irLeF64, irGeF64,
     irF32ConvertI32S, irF32ConvertI32U, irF32ConvertI64S, irF32ConvertI64U,
     irF64ConvertI32S, irF64ConvertI32U, irF64ConvertI64S, irF64ConvertI64U,
     irF32DemoteF64, irF64PromoteF32,
     irI32TruncF32S, irI32TruncF32U, irI32TruncF64S, irI32TruncF64U,
     irI64TruncF32S, irI64TruncF32U, irI64TruncF64S, irI64TruncF64U:
    LatencyInfo(latency: 4, unit: fuALU)
  # FMA: 4 cycles on Apple M-series (single-cycle latency adder, but
  # back-to-back FMA chains have 4-cycle throughput bottleneck)
  of irFmaF32, irFmsF32, irFnmaF32, irFnmsF32,
     irFmaF64, irFmsF64, irFnmaF64, irFnmsF64:
    LatencyInfo(latency: 4, unit: fuMul)
  of irSqrtF32:
    LatencyInfo(latency: 9, unit: fuDiv)
  of irSqrtF64:
    LatencyInfo(latency: 16, unit: fuDiv)
  of irDivF32:
    LatencyInfo(latency: 10, unit: fuDiv)
  of irDivF64:
    LatencyInfo(latency: 15, unit: fuDiv)

  # Loads: 3-4 cycles (L1 hit)
  of irLoad32, irLoad64, irLoad8U, irLoad8S, irLoad16U, irLoad16S,
     irLoad32U, irLoad32S, irLoadF32, irLoadF64, irLocalGet:
    LatencyInfo(latency: 4, unit: fuLoad)

  # Stores: 1 cycle (fire and forget to store buffer)
  of irStore32, irStore64, irStore8, irStore16, irStore32From64,
     irStoreF32, irStoreF64, irLocalSet:
    LatencyInfo(latency: 1, unit: fuStore)

  # Branches / calls
  of irBr, irBrIf, irReturn, irCall:
    LatencyInfo(latency: 1, unit: fuBranch)

  # Indirect call: treated as a branch with high latency (full call overhead)
  of irCallIndirect:
    LatencyInfo(latency: 20, unit: fuBranch)

  of irPhi, irTrap:
    LatencyInfo(latency: 0, unit: fuALU)

  # SIMD v128 — NEON pipeline (Apple M-series)
  of irLoadV128:
    LatencyInfo(latency: 4, unit: fuLoad)
  of irStoreV128:
    LatencyInfo(latency: 1, unit: fuStore)
  of irConstV128:
    LatencyInfo(latency: 1, unit: fuALU)
  of irI32x4Splat, irF32x4Splat, irI8x16Splat, irI16x8Splat, irI64x2Splat, irF64x2Splat:
    LatencyInfo(latency: 2, unit: fuALU)
  of irI32x4ExtractLane, irF32x4ExtractLane,
     irI8x16ExtractLaneS, irI8x16ExtractLaneU,
     irI16x8ExtractLaneS, irI16x8ExtractLaneU,
     irI64x2ExtractLane, irF64x2ExtractLane:
    LatencyInfo(latency: 2, unit: fuALU)
  of irI32x4ReplaceLane, irF32x4ReplaceLane,
     irI8x16ReplaceLane, irI16x8ReplaceLane,
     irI64x2ReplaceLane, irF64x2ReplaceLane:
    LatencyInfo(latency: 2, unit: fuALU)
  of irV128Not, irV128And, irV128Or, irV128Xor, irV128AndNot:
    LatencyInfo(latency: 1, unit: fuALU)
  of irI8x16Abs, irI8x16Neg, irI16x8Abs, irI16x8Neg, irI32x4Abs, irI32x4Neg:
    LatencyInfo(latency: 2, unit: fuALU)
  of irF32x4Abs, irF32x4Neg, irF64x2Abs, irF64x2Neg:
    LatencyInfo(latency: 2, unit: fuALU)
  of irI8x16Add, irI8x16Sub, irI8x16MinS, irI8x16MinU, irI8x16MaxS, irI8x16MaxU:
    LatencyInfo(latency: 2, unit: fuALU)
  of irI16x8Add, irI16x8Sub:
    LatencyInfo(latency: 2, unit: fuALU)
  of irI16x8Mul:
    LatencyInfo(latency: 3, unit: fuMul)
  of irI32x4Add, irI32x4Sub, irI32x4Mul,
     irI32x4MinS, irI32x4MinU, irI32x4MaxS, irI32x4MaxU:
    LatencyInfo(latency: 3, unit: fuMul)
  of irI32x4Shl, irI32x4ShrS, irI32x4ShrU:
    LatencyInfo(latency: 3, unit: fuALU)
  of irI64x2Add, irI64x2Sub:
    LatencyInfo(latency: 2, unit: fuALU)
  of irF32x4Add, irF32x4Sub, irF32x4Mul:
    LatencyInfo(latency: 4, unit: fuMul)
  of irF32x4Div:
    LatencyInfo(latency: 10, unit: fuDiv)
  of irF64x2Add, irF64x2Sub, irF64x2Mul:
    LatencyInfo(latency: 4, unit: fuMul)
  of irF64x2Div:
    LatencyInfo(latency: 15, unit: fuDiv)

# ---- Dependency DAG ----

type
  DepKind* = enum
    depTrue     # RAW: read-after-write (true dependence)
    depAnti     # WAR: write-after-read
    depOutput   # WAW: write-after-write
    depMemory   # memory ordering

  DepEdge* = object
    source*: int    # instruction index
    sink*: int      # instruction index (depends on source)
    kind*: DepKind
    latency*: int

  DepDAG* = object
    edges*: seq[seq[DepEdge]]  # edges FROM each instruction
    numInstrs*: int

proc buildDepDAG*(bb: BasicBlock): DepDAG =
  ## Build dependency DAG for a basic block
  let n = bb.instrs.len
  result.numInstrs = n
  result.edges = newSeq[seq[DepEdge]](n)

  # Track last writer and readers for each SSA value
  var lastDef: seq[int]  # last instruction that defined each value
  var lastUse: seq[seq[int]]  # instructions that used each value since last def

  # Find max value ID in this block
  var maxVal = 0
  for instr in bb.instrs:
    if instr.result >= 0 and instr.result.int > maxVal:
      maxVal = instr.result.int
    for op in instr.operands:
      if op >= 0 and op.int > maxVal:
        maxVal = op.int

  lastDef = newSeq[int](maxVal + 1)
  lastUse = newSeq[seq[int]](maxVal + 1)
  for i in 0 ..< lastDef.len:
    lastDef[i] = -1

  var lastStore = -1
  var lastLoad = -1

  for i in 0 ..< n:
    let instr = bb.instrs[i]
    let lat = getLatency(instr.op)

    # True dependencies: this instruction reads values defined by earlier instructions
    for op in instr.operands:
      if op >= 0 and op.int < lastDef.len:
        let defIdx = lastDef[op.int]
        if defIdx >= 0:
          let defLat = getLatency(bb.instrs[defIdx].op)
          result.edges[defIdx].add(DepEdge(
            source: defIdx, sink: i, kind: depTrue, latency: defLat.latency
          ))

    # Output dependencies: this instruction defines a value also defined earlier
    if instr.result >= 0 and instr.result.int < lastDef.len:
      let prevDef = lastDef[instr.result.int]
      if prevDef >= 0:
        result.edges[prevDef].add(DepEdge(
          source: prevDef, sink: i, kind: depOutput, latency: 0
        ))

    # Anti-dependencies: this instruction defines a value used by earlier instructions
    if instr.result >= 0 and instr.result.int < lastUse.len:
      for useIdx in lastUse[instr.result.int]:
        result.edges[useIdx].add(DepEdge(
          source: useIdx, sink: i, kind: depAnti, latency: 0
        ))

    # Memory dependencies (conservative: stores can't be reordered)
    let isStore = instr.op in {irStore32, irStore64, irStore8, irStore16,
                                irStore32From64, irLocalSet}
    let isLoad = instr.op in {irLoad32, irLoad64, irLoad8U, irLoad8S,
                               irLoad16U, irLoad16S, irLoad32U, irLoad32S,
                               irLocalGet}
    if isStore:
      if lastStore >= 0:
        result.edges[lastStore].add(DepEdge(
          source: lastStore, sink: i, kind: depMemory, latency: 0
        ))
      if lastLoad >= 0:
        result.edges[lastLoad].add(DepEdge(
          source: lastLoad, sink: i, kind: depMemory, latency: 0
        ))
      lastStore = i
    elif isLoad:
      if lastStore >= 0:
        result.edges[lastStore].add(DepEdge(
          source: lastStore, sink: i, kind: depMemory, latency: 0
        ))
      lastLoad = i

    # Call dependencies: calls clobber scratch registers and have side effects.
    # Instructions that produce values consumed by the call (its arguments)
    # are already handled by true data dependencies above.
    # Memory ordering: treat calls and indirect calls as both loads and stores.
    if instr.op == irCall or instr.op == irCallIndirect:
      if lastStore >= 0:
        result.edges[lastStore].add(DepEdge(
          source: lastStore, sink: i, kind: depMemory, latency: 0
        ))
      if lastLoad >= 0:
        result.edges[lastLoad].add(DepEdge(
          source: lastLoad, sink: i, kind: depMemory, latency: 0
        ))
      lastStore = i
      lastLoad = i

    # Update tracking
    if instr.result >= 0 and instr.result.int < lastDef.len:
      lastUse[instr.result.int] = @[]
      lastDef[instr.result.int] = i
    for op in instr.operands:
      if op >= 0 and op.int < lastUse.len:
        lastUse[op.int].add(i)

  # Control flow dependencies: block terminators must execute after all
  # other instructions to ensure stores/side-effects complete before branches.
  let lastIdx = n - 1
  if lastIdx >= 0 and bb.instrs[lastIdx].op in {irBr, irBrIf, irReturn}:
    for i in 0 ..< lastIdx:
      # Add dependency from every preceding instruction to the terminator
      result.edges[i].add(DepEdge(
        source: i, sink: lastIdx, kind: depMemory, latency: 0
      ))

# ---- Priority computation ----

proc computePriorities*(dag: DepDAG, bb: BasicBlock): seq[int] =
  ## Compute scheduling priority for each instruction (longest path to sink).
  ## Likely-taken irBrIf instructions receive a priority boost so they are
  ## scheduled earlier in the BB, exposing the hot path sooner.
  let n = dag.numInstrs
  result = newSeq[int](n)

  # Reverse topological order computation
  # Priority[i] = max over successors (priority[j] + latency(i,j))
  for i in countdown(n - 1, 0):
    var maxP = 0
    for edge in dag.edges[i]:
      let p = result[edge.sink] + edge.latency
      if p > maxP: maxP = p
    result[i] = maxP + getLatency(bb.instrs[i].op).latency
    # PGO boost: highly likely/unlikely branches get elevated priority so the
    # scheduler places them (and their condition inputs) earlier in the block.
    if bb.instrs[i].op == irBrIf:
      let prob = bb.instrs[i].branchProb
      if prob >= PgoBranchLikelyThresh or prob <= PgoBranchUnlikelyThresh:
        result[i] += 4  # push toward top of the ready list

# ---- List scheduler ----

proc scheduleBlock*(bb: BasicBlock, phiHints: seq[PhiCoalescePair] = @[]): seq[int] =
  ## Schedule instructions in a basic block using list scheduling.
  ## Returns the new instruction order (indices into bb.instrs).
  ## When phiHints are provided, adds synthetic anti-dependency edges
  ## forcing phi-result consumers to be scheduled before back-edge-operand
  ## definitions (enabling phi copy coalescing).
  let n = bb.instrs.len
  if n <= 1:
    result = @[]
    for i in 0 ..< n: result.add(i)
    return

  var dag = buildDepDAG(bb)

  # Phi anchoring: phis must stay at the top of the block (before all
  # non-phi instructions). They represent values from block entry, and
  # the codegen emits no code for them — their registers are set up by
  # phi resolution at incoming branch sites. If the scheduler moves phis
  # after other instructions, the register may be clobbered.
  var lastPhiIdx = -1
  for i in 0 ..< n:
    if bb.instrs[i].op == irPhi:
      lastPhiIdx = i
  if lastPhiIdx >= 0:
    # Add edges from all phis to all non-phis (phis must come first)
    for i in 0 ..< n:
      if bb.instrs[i].op == irPhi:
        for j in 0 ..< n:
          if bb.instrs[j].op != irPhi:
            dag.edges[i].add(DepEdge(
              source: i, sink: j, kind: depAnti, latency: 0
            ))

  # Add synthetic anti-dependency edges for phi coalescing:
  # For each phi pair, ALL users of the phi result must be scheduled
  # BEFORE the instruction that defines the back-edge operand.
  for hint in phiHints:
    for userIdx in hint.phiUsers:
      if userIdx != hint.defInstrIdx and userIdx < n and hint.defInstrIdx < n:
        dag.edges[userIdx].add(DepEdge(
          source: userIdx, sink: hint.defInstrIdx,
          kind: depAnti, latency: 0
        ))
  let priorities = computePriorities(dag, bb)

  # Compute in-degree for each instruction (number of unresolved dependencies)
  var inDegree = newSeq[int](n)
  for i in 0 ..< n:
    for edge in dag.edges[i]:
      inc inDegree[edge.sink]

  # Ready set: instructions with all dependencies satisfied
  var ready: seq[int]
  for i in 0 ..< n:
    if inDegree[i] == 0:
      ready.add(i)

  result = newSeqOfCap[int](n)
  var scheduled = newSeq[bool](n)

  while ready.len > 0:
    # Pick highest-priority instruction from ready set
    var bestIdx = 0
    for i in 1 ..< ready.len:
      if priorities[ready[i]] > priorities[ready[bestIdx]]:
        bestIdx = i

    let chosen = ready[bestIdx]
    ready.delete(bestIdx)
    result.add(chosen)
    scheduled[chosen] = true

    # Update ready set: check if scheduling 'chosen' enables new instructions
    for edge in dag.edges[chosen]:
      dec inDegree[edge.sink]
      if inDegree[edge.sink] == 0 and not scheduled[edge.sink]:
        ready.add(edge.sink)

  # Any remaining unscheduled instructions (shouldn't happen in well-formed DAG)
  for i in 0 ..< n:
    if not scheduled[i]:
      result.add(i)
