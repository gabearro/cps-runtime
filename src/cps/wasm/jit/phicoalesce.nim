## Phi coalescing analysis and verification
##
## Identifies opportunities where a phi result and its back-edge operand
## can share the same physical register, eliminating the MOV in the
## trampoline block. The key requirement: all instructions that USE the
## phi result must be scheduled BEFORE the instruction that DEFINES the
## back-edge operand (so the phi result is "dead" when overwritten).

import ir

proc analyzePhiCoalescing*(f: IrFunc): PhiCoalesceInfo =
  ## Identify phi coalescing opportunities in loop headers.
  for bbIdx in 0 ..< f.blocks.len:
    let bb = f.blocks[bbIdx]
    # Detect loop headers (blocks with a back-edge predecessor)
    var isLoopHeader = false
    for pred in bb.predecessors:
      if pred >= bbIdx:
        isLoopHeader = true
        break
    if not isLoopHeader:
      continue

    for instrIdx in 0 ..< bb.instrs.len:
      let phi = bb.instrs[instrIdx]
      if phi.op != irPhi or phi.result < 0:
        continue
      let backOp = phi.operands[1]
      if backOp < 0 or backOp == phi.result:
        continue  # self-referencing or undefined — no coalescing needed

      # Find the instruction in this block that DEFINES the back-edge operand
      var defIdx = -1
      for i in 0 ..< bb.instrs.len:
        if bb.instrs[i].result == backOp:
          defIdx = i
          break
      if defIdx < 0:
        continue  # back-edge operand defined in another block — skip

      # Find all instructions in this block that USE the phi result as operand
      # EXCLUDE: the phi itself AND the back-edge definition instruction
      # (the definition instruction reading the phi is exactly what we want —
      # it reads the old value then writes the new value in the same register)
      var users: seq[int]
      for i in 0 ..< bb.instrs.len:
        if i == instrIdx: continue  # skip the phi itself
        if i == defIdx: continue    # the defInstr using phi as input is expected
        let ins = bb.instrs[i]
        for op in ins.operands:
          if op == phi.result:
            users.add(i)
            break

      result.pairs.add(PhiCoalescePair(
        phiResult: phi.result,
        backEdgeOp: backOp,
        defInstrIdx: defIdx,
        phiUsers: users,
        blockIdx: bbIdx,
      ))
      result.feasible.add(true)  # assume feasible until proven otherwise

  # Check for cycles in the inter-phi dependency graph.
  # If phi A's back-edge definition uses phi B's result, AND phi B's
  # back-edge definition uses phi A's result, there's a cycle and
  # at least one pair must be marked infeasible.
  # Simple approach: for each pair, check if its defInstr uses another
  # pair's phiResult. Build a directed graph and detect cycles.
  let n = result.pairs.len
  if n <= 1:
    return  # 0 or 1 pairs — no cycle possible

  # Build adjacency: edge from pair i to pair j if pair i's defInstr
  # uses pair j's phiResult (meaning j must be scheduled before i)
  var adj = newSeq[seq[int]](n)
  for i in 0 ..< n:
    let defInstr = f.blocks[result.pairs[i].blockIdx].instrs[result.pairs[i].defInstrIdx]
    for j in 0 ..< n:
      if i == j: continue
      for op in defInstr.operands:
        if op == result.pairs[j].phiResult:
          adj[j].add(i)  # j's consumers must come before i's definition
          break

  # Topological sort to check for cycles
  var visited = newSeq[int](n)  # 0=unvisited, 1=in-progress, 2=done
  var hasCycle = false

  proc dfs(node: int) =
    if hasCycle: return
    visited[node] = 1
    for next in adj[node]:
      if visited[next] == 1:
        hasCycle = true
        return
      if visited[next] == 0:
        dfs(next)
    visited[node] = 2

  for i in 0 ..< n:
    if visited[i] == 0:
      dfs(i)

  if hasCycle:
    # Mark all pairs in this block as infeasible
    for i in 0 ..< n:
      result.feasible[i] = false

proc verifyPhiCoalescing*(f: IrFunc, info: var PhiCoalesceInfo) =
  ## After scheduling, verify that for each feasible pair,
  ## all phi-result users appear before the back-edge definition
  ## in the scheduled instruction order.
  for i in 0 ..< info.pairs.len:
    if not info.feasible[i]:
      continue
    let pair = info.pairs[i]
    let bb = f.blocks[pair.blockIdx]

    # Find the position of the back-edge definition in the scheduled order
    var defPos = -1
    for pos in 0 ..< bb.instrs.len:
      if bb.instrs[pos].result == pair.backEdgeOp:
        defPos = pos
        break
    if defPos < 0:
      info.feasible[i] = false
      continue

    # Verify all phi-result users (EXCEPT the defInstr itself) are before
    # the definition. The defInstr is allowed to use the phi result as input
    # because it reads before it writes.
    for pos in 0 ..< bb.instrs.len:
      if pos == defPos: continue  # defInstr using phi as input is expected
      let ins = bb.instrs[pos]
      if ins.op == irPhi: continue
      for op in ins.operands:
        if op == pair.phiResult and pos > defPos:
          info.feasible[i] = false
          break
      if not info.feasible[i]:
        break

proc phiHintsForBlock*(info: PhiCoalesceInfo, blockIdx: int): seq[PhiCoalescePair] =
  ## Extract feasible phi coalescing pairs for a specific block.
  for i in 0 ..< info.pairs.len:
    if info.feasible[i] and info.pairs[i].blockIdx == blockIdx:
      result.add(info.pairs[i])
