## Graph-coloring register allocator (Chaitin-Briggs with Iterated Register Coalescing)
##
## Algorithm:
## 1. Build interference graph from liveness analysis
## 2. Simplify: remove low-degree nodes
## 3. Coalesce: merge move-related non-interfering nodes
## 4. Freeze: give up coalescing for low-degree move-related nodes
## 5. Spill: select high-degree node for potential spilling
## 6. Select: assign colors (registers) to nodes
##
## This implements the full IRC algorithm from Appel & George.

import std/[algorithm, sets]
import ir
import codegen
import optimize  # for isRealBackEdge

const
  NumIntRegs* = 12   # x14-x15 (scratch) + x19-x28 (callee-saved); x12-x13 reserved as codegen scratch
  NumFPRegs* = 16    # d0-d7 (scratch) + d8-d15 (callee-saved)
  NumSimdRegs* = 14  # v16-v29 (caller-saved); v30-v31 reserved as SIMD codegen scratch

type
  RegClass* = enum
    rcInt     # integer register
    rcFloat   # floating-point/scalar register
    rcSimd    # 128-bit NEON Q register (v16-v31)

  PhysReg* = distinct int8

  LiveRange* = object
    start*: int    # first instruction index where value is defined
    stop*: int     # last instruction index where value is used
    defBlock*: int # basic block of definition
    weight*: float # spill weight (higher = more expensive to spill)
    acrossCall*: bool # true if live range spans a call instruction

  NodeState* = enum
    nsSimplify    # ready for simplification (low degree, not move-related)
    nsFreeze      # low degree, move-related
    nsSpill       # high degree candidate for spilling
    nsCoalesced   # merged into another node
    nsColored     # assigned a register
    nsSpilled     # must be spilled to stack

  ## Whether and how a spilled value can be rematerialised at its use sites
  ## instead of round-tripping through a stack spill slot.
  RematKind* = enum
    rematNone    ## normal value: in-register or spilled to stack
    rematConst   ## rematerialise as an integer immediate (irConst32 / irConst64)

  AllocNode* = object
    value*: IrValue       # SSA value this represents
    regClass*: RegClass
    state*: NodeState
    alias*: int           # if coalesced, index of the node we merged into
    degree*: int          # number of interference edges
    spillWeight*: float   # cost of spilling this node
    isRemat*: bool        # can this value be rematerialised? (irConst32/64 only)
    rematImm*: int64      # constant value for rematConst nodes

  InterferenceGraph* = object
    nodes*: seq[AllocNode]
    adjMatrix*: seq[bool]       # flat NxN adjacency matrix
    adjList*: seq[seq[int]]     # adjacency list per node
    numNodes*: int
    numRegs*: int               # K (number of available registers)
    numSimdRegs*: int           # K for SIMD register-class values

  SpillSlot* = object
    offset*: int   # byte offset from stack frame base
    size*: int     # slot size in bytes (8 for int/float, 16 for SIMD)

  RegAllocResult* = object
    assignment*: seq[PhysReg]     # physical register per SSA value (-1 if spilled/remat)
    spillSlots*: seq[SpillSlot]   # spill locations for truly-spilled values (not remat)
    calleeSaved*: set[int8]       # which callee-saved regs were used
    totalSpillBytes*: int         # total byte size of the spill area
    # Rematerialisation metadata (indexed by SSA value):
    rematKind*: seq[RematKind]    ## rematNone for in-register or normal spills
    rematImm*: seq[int64]         ## constant value when rematKind == rematConst
    # Precomputed spill byte offsets (indexed by SSA value; -1 if not a stack spill).
    # Eliminates the O(n) spillIndex scan during codegen.
    spillOffsetMap*: seq[int32]

proc `==`*(a, b: PhysReg): bool {.borrow.}

# ---- Available registers ----
const
  intRegs*: array[NumIntRegs, Reg] = [
    x14, x15,   # scratch (caller-saved); x12-x13 reserved for codegen scratch (rTmp0/rTmp1)
    x19, x20, x21, x22, x23, x24, x25, x26, x27, x28  # callee-saved
  ]

# ---- Interference graph construction ----

proc initGraph*(numValues: int, numRegs: int = NumIntRegs,
                numSimdRegs: int = NumSimdRegs): InterferenceGraph =
  result.numNodes = numValues
  result.numRegs = numRegs
  result.numSimdRegs = numSimdRegs
  result.nodes = newSeq[AllocNode](numValues)
  result.adjMatrix = newSeq[bool](numValues * numValues)
  result.adjList = newSeq[seq[int]](numValues)
  for i in 0 ..< numValues:
    result.nodes[i] = AllocNode(
      value: i.IrValue,
      regClass: rcInt,
      state: nsSimplify,
      alias: i,
      degree: 0,
      spillWeight: 1.0
    )

proc addEdge*(g: var InterferenceGraph, u, v: int) =
  ## Add an interference edge between nodes u and v
  if u == v: return
  if g.adjMatrix[u * g.numNodes + v]: return  # already exists
  g.adjMatrix[u * g.numNodes + v] = true
  g.adjMatrix[v * g.numNodes + u] = true
  g.adjList[u].add(v)
  g.adjList[v].add(u)
  if g.nodes[u].state != nsCoalesced:
    inc g.nodes[u].degree
  if g.nodes[v].state != nsCoalesced:
    inc g.nodes[v].degree

proc interferes*(g: InterferenceGraph, u, v: int): bool =
  g.adjMatrix[u * g.numNodes + v]

proc swapRemove(s: var seq[int], val: int) =
  for i in 0 ..< s.len:
    if s[i] == val:
      s[i] = s[^1]
      s.setLen(s.len - 1)
      return

proc removeEdge(g: var InterferenceGraph, u, v: int) =
  ## Only checks nsCoalesced (not nsColored) because this is called during
  ## pre-coalescing before any nodes have been simplified/colored.
  if not g.adjMatrix[u * g.numNodes + v]: return
  g.adjMatrix[u * g.numNodes + v] = false
  g.adjMatrix[v * g.numNodes + u] = false
  g.adjList[u].swapRemove(v)
  g.adjList[v].swapRemove(u)
  if g.nodes[u].state != nsCoalesced:
    dec g.nodes[u].degree
  if g.nodes[v].state != nsCoalesced:
    dec g.nodes[v].degree

# ---- Liveness analysis ----

proc computeLiveness*(f: IrFunc, phiCoalesce: PhiCoalesceInfo = PhiCoalesceInfo()): seq[LiveRange] =
  ## Compute live ranges for all SSA values using a backward pass
  result = newSeq[LiveRange](f.numValues)
  for i in 0 ..< f.numValues:
    result[i] = LiveRange(start: int.high, stop: -1, weight: 1.0)

  # Pre-build lookup set for feasible phi coalesce pairs: (blockIdx, phiResult)
  var coalescedPhis: HashSet[(int, int32)]
  for pair in phiCoalesce.pairs:
    if pair.feasible:
      coalescedPhis.incl((pair.blockIdx, pair.phiResult))

  # First pass: compute block start/end instruction indices
  var blockStartIdx = newSeq[int](f.blocks.len)
  var blockEndIdx = newSeq[int](f.blocks.len)
  var idx = 0
  for b in 0 ..< f.blocks.len:
    blockStartIdx[b] = idx
    idx += f.blocks[b].instrs.len
    blockEndIdx[b] = idx - 1

  var instrIdx = 0
  for b in 0 ..< f.blocks.len:
    let bb = f.blocks[b]
    for instr in bb.instrs:
      # Definitions
      if instr.result >= 0:
        let v = instr.result.int
        if instrIdx < result[v].start:
          result[v].start = instrIdx
          result[v].defBlock = b
        if instrIdx > result[v].stop:
          result[v].stop = instrIdx
        # Weight by loop depth
        result[v].weight = 1.0 + bb.loopDepth.float * 10.0

      # Uses
      for op in instr.operands:
        if op >= 0:
          let v = op.int
          if instrIdx < result[v].start:
            result[v].start = instrIdx
          if instrIdx > result[v].stop:
            result[v].stop = instrIdx

      inc instrIdx

  # Loop-aware liveness extension: phi results and their back-edge operands
  # must be live across the entire loop body so the register allocator
  # assigns them distinct registers.
  for b in 0 ..< f.blocks.len:
    let bb = f.blocks[b]
    # Find the back-edge predecessor (block with higher index branching to this block)
    var backEdgeBb = -1
    for pred in bb.predecessors:
      if pred >= b and pred < f.blocks.len:
        if backEdgeBb < 0 or pred > backEdgeBb:
          backEdgeBb = pred
    if backEdgeBb < 0:
      continue  # not a loop header

    # Verify this is a genuine loop back-edge (not a false positive from
    # inlined if-else diamonds where a "merge" block has a higher-indexed
    # predecessor that is not forward-reachable from the merge itself).
    if not isRealBackEdge(f, b, backEdgeBb):
      continue

    # Extend phi results and their back-edge operands to cover the full loop.
    # EXCEPTION: for feasibly coalesced pairs, DON'T extend the phi result
    # past the back-edge definition (scheduling guarantees the phi is dead
    # by then, allowing the back-edge operand to reuse its register).
    let loopEnd = blockEndIdx[backEdgeBb]
    for instr in bb.instrs:
      if instr.op != irPhi:
        continue
      let isCoalesced = (b, instr.result) in coalescedPhis

      if isCoalesced:
        # For coalesced pairs: DON'T extend the phi result to the full loop end
        # (allowing it to die at its last natural use). But DO extend the
        # back-edge operand to the loop end. Then merge both ranges so the
        # coalesced node covers the full extent of both — this ensures the
        # interference graph assigns a callee-saved register when needed.
        if instr.operands[1] >= 0:
          let v = instr.operands[1].int
          if loopEnd > result[v].stop:
            result[v].stop = loopEnd
          # Union: extend phi result to cover the back-edge operand's range
          let u = instr.result.int
          if result[v].stop > result[u].stop:
            result[u].stop = result[v].stop
          if result[v].start < result[u].start:
            result[u].start = result[v].start
      else:
        # Non-coalesced: extend both to loop end (standard safety)
        if instr.result >= 0:
          let v = instr.result.int
          if loopEnd > result[v].stop:
            result[v].stop = loopEnd
        if instr.operands[1] >= 0:
          let v = instr.operands[1].int
          if loopEnd > result[v].stop:
            result[v].stop = loopEnd

    # Extend liveness for values defined OUTSIDE the loop but used INSIDE.
    # These values (e.g., hoisted constants) must survive across all iterations.
    for lb in b .. backEdgeBb:
      for instr in f.blocks[lb].instrs:
        for op in instr.operands:
          if op >= 0:
            let v = op.int
            if result[v].defBlock < b:  # defined before the loop
              if loopEnd > result[v].stop:
                result[v].stop = loopEnd

  # Mark values that are live across call instructions.
  # These MUST be assigned callee-saved registers (not x12-x15 scratch).
  # A value is "across call" if there exists a call C where:
  #   start < C < stop  (strictly between — not at the endpoints)
  # This avoids over-constraining call arguments (last use at the call)
  # and call results (defined at the call) to callee-saved registers.
  var callPositions: seq[int]
  var cpIdx = 0
  for b in 0 ..< f.blocks.len:
    for instr in f.blocks[b].instrs:
      if instr.op == irCall:
        callPositions.add(cpIdx)
      inc cpIdx
  if callPositions.len > 0:
    for v in 0 ..< f.numValues:
      if result[v].stop < 0: continue
      # Find first call position strictly > start
      let lo = callPositions.lowerBound(result[v].start + 1)
      if lo < callPositions.len and callPositions[lo] < result[v].stop:
        result[v].acrossCall = true

proc buildInterferenceGraph*(f: IrFunc, liveness: seq[LiveRange],
                              numIntRegs: int = NumIntRegs,
                              numSimdRegs: int = NumSimdRegs): InterferenceGraph =
  ## Build interference graph: two values interfere if their live ranges overlap.
  ## Also marks rematerialisable values (irConst32/irConst64) with infinite spill
  ## weight so the allocator always prefers to spill something else first.
  result = initGraph(f.numValues, numIntRegs, numSimdRegs)

  # Build a per-value map of defining op and immediate so we can classify
  # rematerialisable defs without repeated scans.
  var defOp = newSeq[IrOpKind](f.numValues)
  var defImm = newSeq[int64](f.numValues)
  for bb in f.blocks:
    for instr in bb.instrs:
      if instr.result >= 0:
        defOp[instr.result.int] = instr.op
        defImm[instr.result.int] = instr.imm

  for i in 0 ..< f.numValues:
    result.nodes[i].spillWeight = liveness[i].weight
    # Propagate SIMD register class from IR type info
    if i < f.isSimd.len and f.isSimd[i]:
      result.nodes[i].regClass = rcSimd
    # Mark integer constants as rematerialisable: re-emitting a `mov reg, imm`
    # is always cheaper than a round-trip through the stack.
    case defOp[i]
    of irConst32, irConst64:
      result.nodes[i].isRemat = true
      result.nodes[i].rematImm = defImm[i]
      # Give constants a very high spill weight so we spill non-constants first.
      # We don't use float.high to avoid overflow in weight/degree arithmetic.
      result.nodes[i].spillWeight = 1.0e15
    else:
      discard

  # Two values interfere if their live ranges overlap AND share register class
  for i in 0 ..< f.numValues:
    if liveness[i].stop < 0: continue
    for j in (i + 1) ..< f.numValues:
      if liveness[j].stop < 0: continue
      # Only interfere if same register class (int/float/simd don't share regs)
      if result.nodes[i].regClass != result.nodes[j].regClass: continue
      if liveness[i].start <= liveness[j].stop and liveness[j].start <= liveness[i].stop:
        result.addEdge(i, j)

# ---- Coalescing ----

proc getAlias*(g: var InterferenceGraph, n: int): int =
  ## Find the representative node with path compression
  var node = n
  while g.nodes[node].state == nsCoalesced:
    node = g.nodes[node].alias
  # Path compression: point intermediate nodes directly to root
  var cur = n
  while cur != node:
    let next = g.nodes[cur].alias
    g.nodes[cur].alias = node
    cur = next
  node

proc canCoalesce*(g: var InterferenceGraph, u, v: int): bool =
  ## George's conservative coalescing criterion:
  ## Can coalesce u and v if every high-degree neighbor of v
  ## already interferes with u (or has low degree)
  let k = g.numRegs
  for t in g.adjList[v]:
    let tAlias = g.getAlias(t)
    if tAlias == u: continue
    if g.nodes[tAlias].degree < k: continue
    if not g.interferes(tAlias, u):
      return false
  return true

proc decrementDegree(g: var InterferenceGraph, n: int) =
  let a = g.getAlias(n)
  if g.nodes[a].state != nsCoalesced and g.nodes[a].state != nsColored:
    dec g.nodes[a].degree

proc coalesce*(g: var InterferenceGraph, u, v: int) =
  ## Merge node v into node u
  g.nodes[v].state = nsCoalesced
  g.nodes[v].alias = u
  for t in g.adjList[v]:
    if g.getAlias(t) != u:
      g.addEdge(u, g.getAlias(t))

# ---- IRC Main Loop ----

proc simplify*(g: var InterferenceGraph): seq[int] =
  ## Remove low-degree non-move-related nodes, push onto stack
  var stack: seq[int]
  var changed = true
  while changed:
    changed = false
    for i in 0 ..< g.numNodes:
      if g.nodes[i].state == nsSimplify and g.nodes[i].degree < g.numRegs:
        g.nodes[i].state = nsColored  # temporarily mark as removed
        for j in g.adjList[i]:
          g.decrementDegree(j)
        stack.add(i)
        changed = true
  stack

proc selectSpillCandidate*(g: InterferenceGraph): int =
  ## Select the node with lowest spill weight / degree ratio
  var bestIdx = -1
  var bestRatio = float.high
  for i in 0 ..< g.numNodes:
    if g.nodes[i].state == nsSimplify or g.nodes[i].state == nsSpill:
      if g.nodes[i].degree >= g.numRegs:
        let ratio = g.nodes[i].spillWeight / g.nodes[i].degree.float
        if ratio < bestRatio:
          bestRatio = ratio
          bestIdx = i
  bestIdx

proc assignColors*(g: var InterferenceGraph, stack: seq[int],
                   liveness: seq[LiveRange] = @[],
                   calleeSavedStart: int8 = 2): RegAllocResult =
  ## Pop nodes from stack and assign colors (registers).
  ## Values live across calls are restricted to callee-saved registers
  ## (index >= calleeSavedStart for int).
  result.assignment = newSeq[PhysReg](g.numNodes)
  for i in 0 ..< g.numNodes:
    result.assignment[i] = PhysReg(-1)

  # Assign colors in reverse stack order
  for idx in countdown(stack.len - 1, 0):
    let n = stack[idx]
    let nAlias = g.getAlias(n)

    # Find available color
    var usedColors: set[int8]
    for j in g.adjList[nAlias]:
      let jAlias = g.getAlias(j)
      let color = result.assignment[jAlias]
      if color.int8 >= 0:
        usedColors.incl(color.int8)

    let rc = g.nodes[nAlias].regClass

    # Determine available register count based on class
    let numAvail = case rc
      of rcInt:   g.numRegs     # NumIntRegs (or platform-specific value)
      of rcFloat: NumFPRegs
      of rcSimd:  g.numSimdRegs

    # Values live across calls MUST use callee-saved registers (index >= calleeSavedStart for int).
    # SIMD regs v16-v31 are all caller-saved, so no restriction needed.
    let needsCalleeSaved = rc == rcInt and nAlias < liveness.len and liveness[nAlias].acrossCall
    let startColor = if needsCalleeSaved: calleeSavedStart else: 0'i8

    # Rematerialisable values live across calls: force-spill to rematerialization.
    # Re-emitting `MOV reg, #imm` at each use (~1 cycle) is far cheaper than
    # burning a callee-saved register that must be STP'd/LDP'd on every call.
    # This is critical for recursive functions where CS save/restore dominates.
    var assigned = false
    if not (needsCalleeSaved and g.nodes[nAlias].isRemat):
      for c in startColor ..< numAvail.int8:
        if c notin usedColors:
          result.assignment[nAlias] = PhysReg(c)
          g.nodes[nAlias].state = nsColored
          assigned = true
          if rc == rcInt and c >= calleeSavedStart:
            result.calleeSaved.incl(c)
          break

    if not assigned:
      g.nodes[nAlias].state = nsSpilled
      if g.nodes[nAlias].isRemat:
        # Rematerialisable value: no stack slot needed — the code generator will
        # re-emit the defining instruction (e.g. `mov reg, imm`) at each use site.
        # assignment[nAlias] stays -1; rematKind/rematImm are populated below.
        discard
      else:
        # Regular spill: allocate a stack slot.
        let slotSize = if rc == rcSimd: 16 else: 8
        # Align running byte offset to this slot's natural alignment
        let baseOff = (result.totalSpillBytes + slotSize - 1) and (not (slotSize - 1))
        result.spillSlots.add(SpillSlot(offset: baseOff, size: slotSize))
        result.totalSpillBytes = baseOff + slotSize

  # Propagate colors to coalesced nodes
  for i in 0 ..< g.numNodes:
    if g.nodes[i].state == nsCoalesced:
      result.assignment[i] = result.assignment[g.getAlias(i)]

  # Populate rematerialisation metadata for consumers (ircodegen, ircodegen_x64).
  result.rematKind = newSeq[RematKind](g.numNodes)
  result.rematImm  = newSeq[int64](g.numNodes)
  for i in 0 ..< g.numNodes:
    let alias = g.getAlias(i)
    if result.assignment[i].int8 < 0 and g.nodes[alias].isRemat:
      result.rematKind[i] = rematConst
      result.rematImm[i]  = g.nodes[alias].rematImm

  # Precompute spill byte offset for each SSA value.
  # This turns the O(n) spillIndex scan into O(1) lookup during codegen.
  result.spillOffsetMap = newSeq[int32](g.numNodes)
  var spillIdx = 0
  for i in 0 ..< g.numNodes:
    if result.assignment[i].int8 < 0 and result.rematKind[i] == rematNone:
      if spillIdx < result.spillSlots.len:
        result.spillOffsetMap[i] = result.spillSlots[spillIdx].offset.int32
      else:
        result.spillOffsetMap[i] = (spillIdx * 8).int32
      inc spillIdx
    else:
      result.spillOffsetMap[i] = -1

proc allocateRegisters*(f: IrFunc, phiCoalesce: PhiCoalesceInfo = PhiCoalesceInfo(),
                        numIntRegs: int = NumIntRegs,
                        calleeSavedStart: int8 = 2,
                        numSimdRegs: int = NumSimdRegs): RegAllocResult =
  ## Full register allocation pipeline.
  ## numIntRegs: number of allocatable integer registers (12 for AArch64, 5 for x86_64).
  ## calleeSavedStart: first color index that is callee-saved (2 for AArch64, 4 for x86_64).
  if numIntRegs <= 0:
    result.assignment = newSeq[PhysReg](f.numValues)
    result.rematKind = newSeq[RematKind](f.numValues)
    result.rematImm = newSeq[int64](f.numValues)
    result.spillOffsetMap = newSeq[int32](f.numValues)
    for i in 0 ..< f.numValues:
      result.assignment[i] = PhysReg(-1)
      let slotSize = if i < f.isSimd.len and f.isSimd[i]: 16 else: 8
      let baseOff = (result.totalSpillBytes + slotSize - 1) and (not (slotSize - 1))
      result.spillSlots.add(SpillSlot(offset: baseOff, size: slotSize))
      result.spillOffsetMap[i] = baseOff.int32
      result.totalSpillBytes = baseOff + slotSize
    return

  var liveness = computeLiveness(f, phiCoalesce)
  var graph = buildInterferenceGraph(f, liveness, numIntRegs, numSimdRegs)

  # Pre-coalesce feasible phi pairs: merge the back-edge operand node
  # into the phi result node so they share the same register.
  # Force coalescing even if they "interfere" at the definition point,
  # because the scheduler guarantees the phi result's last use is AT (not after)
  # the back-edge definition, and AArch64 reads inputs before writing outputs.
  for i in 0 ..< phiCoalesce.pairs.len:
    if phiCoalesce.pairs[i].feasible:
      let u = phiCoalesce.pairs[i].phiResult.int
      let v = phiCoalesce.pairs[i].backEdgeOp.int
      if u >= 0 and v >= 0 and u < graph.numNodes and v < graph.numNodes:
        # Remove interference between u and v (they share a register).
        # The union liveness was already applied in computeLiveness,
        # so the interference graph has correct edges for the coalesced node.
        graph.removeEdge(u, v)
        graph.coalesce(u, v)

  # IRC: simplify → spill → select
  let stack = graph.simplify()

  var fullStack = stack
  var spilling = true
  while spilling:
    spilling = false
    let candidate = graph.selectSpillCandidate()
    if candidate >= 0:
      graph.nodes[candidate].state = nsColored
      for j in graph.adjList[candidate]:
        graph.decrementDegree(j)
      fullStack.add(candidate)
      let extra = graph.simplify()
      fullStack.add(extra)
      spilling = true

  result = graph.assignColors(fullStack, liveness, calleeSavedStart)
