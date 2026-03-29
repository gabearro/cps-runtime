## Phi coalescing analysis and verification
##
## Identifies opportunities where a phi result and its back-edge operand
## can share the same physical register, eliminating the MOV in the
## trampoline block. The key requirement: all instructions that USE the
## phi result must be scheduled BEFORE the instruction that DEFINES the
## back-edge operand (so the phi result is "dead" when overwritten).

import std/tables
import ir, optimize  # isRealBackEdge

proc analyzePhiCoalescing*(f: IrFunc): PhiCoalesceInfo =
  ## Identify phi coalescing opportunities in loop headers.
  for bbIdx in 0 ..< f.blocks.len:
    let bb = f.blocks[bbIdx]

    # Detect loop headers via validated back-edges
    var isLoopHeader = false
    for pred in bb.predecessors:
      if pred >= bbIdx and isRealBackEdge(f, bbIdx, pred):
        isLoopHeader = true
        break
    if not isLoopHeader:
      continue

    # Build def map once per block: result value -> instruction index
    var defMap: Table[IrValue, int]
    for i in 0 ..< bb.instrs.len:
      if bb.instrs[i].result >= 0:
        defMap[bb.instrs[i].result] = i

    for instrIdx in 0 ..< bb.instrs.len:
      let phi = bb.instrs[instrIdx]
      if phi.op != irPhi or phi.result < 0:
        continue
      if phi.operands.len < 2: continue
      let backOp = phi.operands[1]
      if backOp < 0 or backOp == phi.result:
        continue  # self-referencing or undefined

      let defIdx = defMap.getOrDefault(backOp, -1)
      if defIdx < 0:
        continue  # back-edge operand defined in another block

      # Find instructions that USE the phi result, excluding the phi itself
      # and the back-edge def (which reads the old value then writes the new)
      var users: seq[int]
      for i in 0 ..< bb.instrs.len:
        if i == instrIdx or i == defIdx: continue
        for op in bb.instrs[i].operands:
          if op == phi.result:
            users.add(i)
            break

      result.pairs.add(PhiCoalescePair(
        phiResult: phi.result,
        backEdgeOp: backOp,
        defInstrIdx: defIdx,
        phiUsers: users,
        blockIdx: bbIdx,
        feasible: true,
      ))

  # Check for cycles in the inter-phi dependency graph.
  # If phi A's back-edge def uses phi B's result and vice versa,
  # at least one must be marked infeasible.
  let n = result.pairs.len
  if n <= 1:
    return

  # Map phiResult -> pair index for O(n) adjacency build
  var phiToPair: Table[IrValue, int]
  for i in 0 ..< n:
    phiToPair[result.pairs[i].phiResult] = i

  var adj = newSeq[seq[int]](n)
  for i in 0 ..< n:
    let defInstr = f.blocks[result.pairs[i].blockIdx].instrs[result.pairs[i].defInstrIdx]
    for op in defInstr.operands:
      let j = phiToPair.getOrDefault(op, -1)
      if j >= 0 and j != i:
        adj[j].add(i)

  # Iterative DFS cycle detection — only mark participants infeasible
  var visited = newSeq[int](n)  # 0=unvisited, 1=in-progress, 2=done
  var childIdx = newSeq[int](n) # next child to visit per node
  var stack: seq[int]

  for root in 0 ..< n:
    if visited[root] != 0: continue
    stack.add(root)
    visited[root] = 1
    childIdx[root] = 0
    while stack.len > 0:
      let node = stack[^1]
      if childIdx[node] < adj[node].len:
        let next = adj[node][childIdx[node]]
        inc childIdx[node]
        if visited[next] == 1:
          result.pairs[node].feasible = false
          result.pairs[next].feasible = false
        elif visited[next] == 0:
          visited[next] = 1
          childIdx[next] = 0
          stack.add(next)
      else:
        visited[node] = 2
        discard stack.pop()

proc verifyPhiCoalescing*(f: IrFunc, info: var PhiCoalesceInfo) =
  ## After scheduling, verify that for each feasible pair,
  ## all phi-result users appear before the back-edge definition
  ## in the scheduled instruction order.
  var lastBlockIdx = -1
  var defMap: Table[IrValue, int]
  for i in 0 ..< info.pairs.len:
    if not info.pairs[i].feasible:
      continue
    let pair = info.pairs[i]
    let bb = f.blocks[pair.blockIdx]

    # Rebuild defMap when we encounter a new block
    if pair.blockIdx != lastBlockIdx:
      lastBlockIdx = pair.blockIdx
      defMap.clear()
      for j in 0 ..< bb.instrs.len:
        if bb.instrs[j].result >= 0:
          defMap[bb.instrs[j].result] = j

    let defPos = defMap.getOrDefault(pair.backEdgeOp, -1)
    if defPos < 0:
      info.pairs[i].feasible = false
      continue

    # Instructions after defPos must not use the phi result — it's been
    # overwritten. The defInstr itself may read the phi as input (reads
    # old value then writes new), so we only check positions past it.
    for pos in defPos + 1 ..< bb.instrs.len:
      let ins = bb.instrs[pos]
      if ins.op == irPhi: continue
      for op in ins.operands:
        if op == pair.phiResult:
          info.pairs[i].feasible = false
          break
      if not info.pairs[i].feasible:
        break

proc phiHintsForBlock*(info: PhiCoalesceInfo, blockIdx: int): seq[PhiCoalescePair] =
  ## Extract feasible phi coalescing pairs for a specific block.
  for i in 0 ..< info.pairs.len:
    if info.pairs[i].feasible and info.pairs[i].blockIdx == blockIdx:
      result.add(info.pairs[i])
