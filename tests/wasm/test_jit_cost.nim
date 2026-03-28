## Tests for the resource-aware JIT triage cost module

import ../../src/cps/wasm/jit/cost
import ../../src/cps/wasm/jit/ir
import ../../src/cps/wasm/jit/optimize  # isRealBackEdge

# =========================================================================
# CostPoly arithmetic tests
# =========================================================================

proc testCostPolyAdd() =
  # Constant + constant
  let a = constPoly(10)
  let b = constPoly(32)
  let c = add(a, b)
  assert c.constant == 42
  assert c.terms.len == 0

  # Constant + symbolic
  var d = CostPoly(constant: 5)
  d.terms.add(initTerm(12, 0.CostVarId))  # 5 + 12·n₀
  let e = constPoly(3)
  let f = add(d, e)
  assert f.constant == 8  # 5 + 3
  assert f.terms.len == 1
  assert f.terms[0].coeff == 12

  # Symbolic + symbolic (same variable)
  var g = CostPoly(constant: 2)
  g.terms.add(initTerm(7, 0.CostVarId))  # 2 + 7·n₀
  let h = add(d, g)
  assert h.constant == 7  # 5 + 2
  assert h.terms.len == 1
  assert h.terms[0].coeff == 19  # 12 + 7

  # Different variables
  var i = CostPoly(constant: 1)
  i.terms.add(initTerm(3, 1.CostVarId))  # 1 + 3·n₁
  let j = add(d, i)
  assert j.constant == 6  # 5 + 1
  assert j.terms.len == 2
  echo "PASS: CostPoly add"

proc testCostPolyJoin() =
  let a = constPoly(10)
  let b = constPoly(20)
  let c = join(a, b)
  assert c.constant == 20  # max

  var d = CostPoly(constant: 5)
  d.terms.add(initTerm(12, 0.CostVarId))
  var e = CostPoly(constant: 8)
  e.terms.add(initTerm(7, 0.CostVarId))
  let f = join(d, e)
  assert f.constant == 8   # max(5, 8)
  assert f.terms[0].coeff == 12  # max(12, 7)
  echo "PASS: CostPoly join"

proc testCostPolyWeightedJoin() =
  # 80% probability for path a, 20% for path b
  let a = constPoly(100)
  let b = constPoly(0)
  let c = weightedJoin(a, b, 204)  # 204/255 ≈ 80%
  assert c.constant >= 78 and c.constant <= 82  # ~80
  echo "PASS: CostPoly weighted join"

proc testCostPolyLoopWrap() =
  # Body cost = 10 cycles (constant, no loops inside)
  let body = constPoly(10)
  let wrapped = loopWrap(body, 0.CostVarId)
  # Result should be: LoopOverhead + 10·n₀
  assert wrapped.constant == LoopOverhead  # 2
  assert wrapped.terms.len == 1
  assert wrapped.terms[0].coeff == 10
  assert wrapped.terms[0].vars[0] == 0.CostVarId
  assert wrapped.terms[0].vars[1] == -1.CostVarId

  # Nested loop: body = 2 + 5·n₁ (inner loop already wrapped)
  var innerBody = CostPoly(constant: 2)
  innerBody.terms.add(initTerm(5, 1.CostVarId))
  let outerWrapped = loopWrap(innerBody, 0.CostVarId)
  # Result: LoopOverhead + 2·n₀ + 5·n₀·n₁
  assert outerWrapped.constant == LoopOverhead
  assert outerWrapped.terms.len == 2
  # Find the n₀ term
  var foundN0 = false
  var foundN0N1 = false
  for t in outerWrapped.terms:
    if t.vars[0] == 0.CostVarId and t.vars[1] < 0:
      assert t.coeff == 2  # body.constant promoted
      foundN0 = true
    elif t.vars[0] == 1.CostVarId and t.vars[1] == 0.CostVarId:
      assert t.coeff == 5  # inner coeff preserved
      foundN0N1 = true
    elif t.vars[0] == 0.CostVarId and t.vars[1] == 1.CostVarId:
      assert t.coeff == 5  # might be in either order
      foundN0N1 = true
  assert foundN0, "should have n₀ term"
  assert foundN0N1, "should have n₀·n₁ term"
  echo "PASS: CostPoly loop wrap (including nested)"

proc testCostPolyConcretize() =
  # 5 + 12·n₀, concretize n₀ = 100
  var a = CostPoly(constant: 5)
  a.terms.add(initTerm(12, 0.CostVarId))
  let c = concretize(a, 0.CostVarId, 100)
  assert c.constant == 5 + 12 * 100  # 1205
  assert c.terms.len == 0  # fully concretized

  # 5 + 12·n₀ + 3·n₁, concretize only n₀ = 10
  var b = CostPoly(constant: 5)
  b.terms.add(initTerm(12, 0.CostVarId))
  b.terms.add(initTerm(3, 1.CostVarId))
  let d = concretize(b, 0.CostVarId, 10)
  assert d.constant == 5 + 12 * 10  # 125
  assert d.terms.len == 1  # n₁ term remains
  assert d.terms[0].coeff == 3
  assert d.terms[0].vars[0] == 1.CostVarId
  echo "PASS: CostPoly concretize"

proc testCostPolyDominantTerm() =
  var a = CostPoly(constant: 100)
  a.terms.add(initTerm(5, 0.CostVarId))
  a.terms.add(initTerm(2, 0.CostVarId, 1.CostVarId))
  let dom = dominantTerm(a)
  # The n₀·n₁ term has degree 2, higher than n₀ (degree 1) and constant (degree 0)
  assert dom.vars[0] >= 0 and dom.vars[1] >= 0
  assert dom.coeff == 2
  echo "PASS: CostPoly dominant term"

proc testHasSymbolicTerms() =
  assert not hasSymbolicTerms(constPoly(42))
  var a = CostPoly(constant: 5)
  a.terms.add(initTerm(10, 0.CostVarId))
  assert hasSymbolicTerms(a)
  echo "PASS: hasSymbolicTerms"

# =========================================================================
# CostVector operation tests
# =========================================================================

proc testCostVectorAdd() =
  var a = zeroVec()
  a.cycles = constPoly(10)
  a.codeSize = constPoly(40)
  a.memOps = constPoly(2)
  a.regPressure = 5

  var b = zeroVec()
  b.cycles = constPoly(20)
  b.codeSize = constPoly(16)
  b.memOps = constPoly(3)
  b.regPressure = 8

  let c = addVec(a, b)
  assert c.cycles.constant == 30
  assert c.codeSize.constant == 56
  assert c.memOps.constant == 5
  assert c.regPressure == 8  # max
  echo "PASS: CostVector add"

proc testCostVectorLoopWrap() =
  var body = zeroVec()
  body.cycles = constPoly(10)
  body.codeSize = constPoly(40)
  body.memOps = constPoly(3)
  body.regPressure = 6

  let wrapped = loopWrapVec(body, 0.CostVarId)
  assert wrapped.cycles.constant == LoopOverhead
  assert wrapped.cycles.terms.len == 1
  assert wrapped.cycles.terms[0].coeff == 10
  # Code size does NOT scale with iterations
  assert wrapped.codeSize.constant == 40
  assert wrapped.codeSize.terms.len == 0
  # Memory ops scale
  assert wrapped.memOps.terms.len == 1
  assert wrapped.memOps.terms[0].coeff == 3
  # Pressure stays the same (per-block max, not per-iteration)
  assert wrapped.regPressure == 6
  echo "PASS: CostVector loop wrap"

# =========================================================================
# Transfer function tests
# =========================================================================

proc testInstrCostDelta() =
  let addDelta = instrCostDelta(irAdd32)
  assert addDelta.cycles == 1
  assert addDelta.codeSize == 4
  assert addDelta.memOps == 0

  let loadDelta = instrCostDelta(irLoad32)
  assert loadDelta.cycles == 4
  assert loadDelta.memOps == 1

  let divDelta = instrCostDelta(irDiv32S)
  assert divDelta.cycles == 7
  assert divDelta.codeSize == 12

  let callDelta = instrCostDelta(irCallIndirect)
  assert callDelta.cycles == 20
  assert callDelta.memOps == 3

  let constDelta = instrCostDelta(irConst32)
  assert constDelta.cycles == 0
  assert constDelta.codeSize == 0
  echo "PASS: instrCostDelta"

# =========================================================================
# Block analysis tests
# =========================================================================

proc testAnalyzeBlock() =
  # Build a simple BB with: const 10, const 20, add, return
  var f = IrFunc()
  var bb = BasicBlock(id: 0)
  let v0 = f.newValue()
  bb.addInstr(IrInstr(op: irConst32, result: v0, imm: 10))
  let v1 = f.newValue()
  bb.addInstr(IrInstr(op: irConst32, result: v1, imm: 20))
  let v2 = f.newValue()
  bb.addInstr(IrInstr(op: irAdd32, result: v2, operands: [v0, v1, -1.IrValue]))
  bb.addInstr(IrInstr(op: irReturn, result: -1.IrValue, operands: [v2, -1.IrValue, -1.IrValue]))

  let cv = analyzeBlock(bb, f)
  # const32 = 0 cycles, add32 = 1 cycle, return = 1 cycle
  assert cv.cycles.constant == 2
  assert cv.memOps.constant == 0
  echo "PASS: analyzeBlock"

proc testEstimateBlockPressure() =
  # Build a BB: a = const, b = const, c = add(a, b)
  # At the point of add: a and b are both live → pressure = 2
  var f = IrFunc()
  var bb = BasicBlock(id: 0)
  let a = f.newValue()
  bb.addInstr(IrInstr(op: irConst32, result: a, imm: 1))
  let b = f.newValue()
  bb.addInstr(IrInstr(op: irConst32, result: b, imm: 2))
  let c = f.newValue()
  bb.addInstr(IrInstr(op: irAdd32, result: c, operands: [a, b, -1.IrValue]))
  bb.addInstr(IrInstr(op: irReturn, result: -1.IrValue, operands: [c, -1.IrValue, -1.IrValue]))

  let (intP, fpP) = estimateBlockPressure(bb, f.isSimd, f.numValues)
  # At the add instruction: a and b are live → 2 int registers
  assert intP >= 2, "expected int pressure >= 2, got " & $intP
  assert fpP == 0
  echo "PASS: estimateBlockPressure"

# =========================================================================
# Full cost analysis tests
# =========================================================================

proc testAnalyzeCostLeaf() =
  # Single-block function: param + const + add + return
  var f = IrFunc(numParams: 1, numResults: 1, numLocals: 1)
  var bb = BasicBlock(id: 0)
  let p = f.newValue()
  bb.addInstr(IrInstr(op: irParam, result: p))
  let c = f.newValue()
  bb.addInstr(IrInstr(op: irConst32, result: c, imm: 1))
  let r = f.newValue()
  bb.addInstr(IrInstr(op: irAdd32, result: r, operands: [p, c, -1.IrValue]))
  bb.addInstr(IrInstr(op: irReturn, result: -1.IrValue, operands: [r, -1.IrValue, -1.IrValue]))
  f.blocks.add(bb)

  let cs = analyzeCost(f)
  assert cs.loops.len == 0
  assert cs.funcTotal.cycles.constant >= 2  # add + return
  assert not cs.funcTotal.cycles.hasSymbolicTerms
  echo "PASS: analyzeCost (leaf function, no loops)"

proc testAnalyzeCostWithLoop() =
  # Three-block function with a loop:
  #   BB0 (entry) → BB1 (loop header) → BB2 (loop body, back-edge to BB1)
  #   BB1 also has exit edge to BB3
  var f = IrFunc(numParams: 0, numResults: 0, numLocals: 0)

  # BB0: entry → branch to BB1
  var bb0 = BasicBlock(id: 0)
  bb0.addInstr(IrInstr(op: irBr, result: -1.IrValue))
  bb0.successors = @[1]
  bb0.predecessors = @[]
  f.blocks.add(bb0)

  # BB1: loop header — brIf to BB2 (body) or BB3 (exit)
  var bb1 = BasicBlock(id: 1)
  let cond = f.newValue()
  bb1.addInstr(IrInstr(op: irConst32, result: cond, imm: 1))
  bb1.addInstr(IrInstr(op: irBrIf, result: -1.IrValue, operands: [cond, -1.IrValue, -1.IrValue]))
  bb1.successors = @[2, 3]  # taken=body, fallthrough=exit
  bb1.predecessors = @[0, 2]  # from entry and from back-edge
  f.blocks.add(bb1)

  # BB2: loop body — compute something, then branch back to BB1
  var bb2 = BasicBlock(id: 2)
  let v0 = f.newValue()
  bb2.addInstr(IrInstr(op: irConst32, result: v0, imm: 1))
  let v1 = f.newValue()
  bb2.addInstr(IrInstr(op: irAdd32, result: v1, operands: [v0, v0, -1.IrValue]))
  bb2.addInstr(IrInstr(op: irBr, result: -1.IrValue))
  bb2.successors = @[1]  # back-edge to loop header
  bb2.predecessors = @[1]
  f.blocks.add(bb2)

  # BB3: exit
  var bb3 = BasicBlock(id: 3)
  bb3.addInstr(IrInstr(op: irReturn, result: -1.IrValue))
  bb3.successors = @[]
  bb3.predecessors = @[1]
  f.blocks.add(bb3)

  let cs = analyzeCost(f)
  assert cs.loops.len == 1, "expected 1 loop, got " & $cs.loops.len
  assert cs.loops[0].headerBb == 1
  assert cs.loops[0].isInnermost
  # Body block BB2 has: const32(0) + add32(1) + br(1) = 2 cycles
  assert cs.loops[0].bodyCost.cycles.constant >= 2,
    "loop body should have >= 2 cycles, got " & $cs.loops[0].bodyCost.cycles.constant
  # funcTotal should have symbolic terms (loop body cost parameterized by n₀)
  assert cs.funcTotal.cycles.hasSymbolicTerms,
    "expected symbolic cycle cost for loop function"
  echo "PASS: analyzeCost (single loop, symbolic cost)"

# =========================================================================
# Decision API tests
# =========================================================================

proc testOptGatingLeafVsLoop() =
  # Leaf function: no loops, small
  var leafState = CostState()
  leafState.bbCount = 2
  leafState.ssaValueCount = 10
  leafState.funcTotal.memOps = constPoly(1)

  let leafGating = computeOptGating(leafState)
  assert not leafGating.runLICM, "leaf should skip LICM"
  assert not leafGating.runLoopUnroll, "leaf should skip loop unroll"
  assert not leafGating.runLoopBCEHoist, "leaf should skip loop BCE hoist"

  # Loop function: has loops, memory ops
  var loopState = CostState()
  loopState.bbCount = 5
  loopState.ssaValueCount = 50
  loopState.funcTotal.memOps = CostPoly(constant: 2)
  loopState.funcTotal.memOps.terms.add(initTerm(8, 0.CostVarId))
  loopState.loops.add(LoopInfo(
    varId: 0.CostVarId, headerBb: 1, backEdgeBb: 3,
    bodyCost: zeroVec(), isInnermost: true, estimatedTrips: -1
  ))
  loopState.loops[0].bodyCost.cycles = constPoly(20)

  let loopGating = computeOptGating(loopState)
  assert loopGating.runLICM, "loop function should enable LICM"
  assert loopGating.runLoopUnroll, "loop function should enable unroll (body < 80)"
  assert loopGating.runGlobalCSE, "5 BBs should enable global CSE"
  assert loopGating.runAliasBCE, "significant mem ops should enable alias BCE"
  echo "PASS: computeOptGating (leaf vs loop)"

proc testInlineDecision() =
  # Caller with moderate pressure
  var callerCost = CostState()
  callerCost.bbCount = 3
  var callerBlock = zeroVec()
  callerBlock.regPressure = 8
  callerCost.perBlock = @[callerBlock, callerBlock, callerBlock]
  callerCost.funcTotal.regPressure = 8

  # Small callee — should inline
  var smallCallee = CostState()
  smallCallee.bbCount = 1
  smallCallee.funcTotal.cycles = constPoly(5)
  smallCallee.funcTotal.codeSize = constPoly(20)
  smallCallee.funcTotal.regPressure = 3

  let d1 = computeInlineDecision(callerCost, smallCallee, 0, 0)
  assert d1.shouldInline, "small callee with low pressure should inline"
  assert d1.benefit > 0

  # Callee with loops — should reject
  var loopCallee = CostState()
  loopCallee.bbCount = 3
  loopCallee.funcTotal.cycles = CostPoly(constant: 5)
  loopCallee.funcTotal.cycles.terms.add(initTerm(100, 0.CostVarId))
  loopCallee.funcTotal.codeSize = constPoly(60)
  loopCallee.funcTotal.regPressure = 4

  let d2 = computeInlineDecision(callerCost, loopCallee, 0, 0)
  assert not d2.shouldInline, "callee with loops (symbolic cost) should not inline"

  # Callee that would cause massive spills — should reject
  var highPressureCallee = CostState()
  highPressureCallee.bbCount = 1
  highPressureCallee.funcTotal.cycles = constPoly(3)
  highPressureCallee.funcTotal.codeSize = constPoly(16)
  highPressureCallee.funcTotal.regPressure = 10  # 8 + 10 = 18 > 12 → 6 excess × 8 = 48 spill penalty

  let d3 = computeInlineDecision(callerCost, highPressureCallee, 0, 0)
  # benefit = 10 (call overhead) + 3 (callee cycles) - 48 (spill penalty) = -35
  assert not d3.shouldInline, "high-pressure callee should not inline (spill penalty)"
  echo "PASS: computeInlineDecision"

proc testTierThresholds() =
  # Hot loop function: should get low thresholds
  var hotState = CostState()
  hotState.bbCount = 4
  hotState.ssaValueCount = 30
  hotState.funcTotal.cycles = CostPoly(constant: 5)
  hotState.funcTotal.cycles.terms.add(initTerm(50, 0.CostVarId))
  hotState.funcTotal.codeSize = constPoly(100)
  var loopBody = zeroVec()
  loopBody.cycles = constPoly(10)  # 10 cycles per iteration
  loopBody.memOps = constPoly(2)
  hotState.loops.add(LoopInfo(
    varId: 0.CostVarId, headerBb: 1, backEdgeBb: 3,
    bodyCost: loopBody, isInnermost: true, estimatedTrips: -1
  ))

  let (t1, t2, pri) = computeTierThresholds(hotState)
  assert t1 <= 100, "hot loop should have low tier1 threshold, got " & $t1
  assert t2 <= 5000, "hot loop should have moderate tier2 threshold, got " & $t2
  assert pri > 0, "hot loop should have positive priority"

  # Leaf function with low cost
  var leafState = CostState()
  leafState.bbCount = 1
  leafState.ssaValueCount = 5
  leafState.funcTotal.cycles = constPoly(3)
  leafState.funcTotal.codeSize = constPoly(16)

  let (lt1, lt2, lpri) = computeTierThresholds(leafState)
  assert lt1 >= t1, "leaf should have >= tier1 threshold than loop function"
  echo "PASS: computeTierThresholds"

proc testEstimateTripCount() =
  assert estimateTripCount(0) == -1  # unknown
  assert estimateTripCount(255) == 1  # always exits
  assert estimateTripCount(1) >= 255  # rarely exits → many trips
  let mid = estimateTripCount(128)  # ~50% exit → ~2 trips
  assert mid >= 1 and mid <= 3, "50% exit should give ~2 trips, got " & $mid
  echo "PASS: estimateTripCount"

# =========================================================================
# Run all tests
# =========================================================================

testCostPolyAdd()
testCostPolyJoin()
testCostPolyWeightedJoin()
testCostPolyLoopWrap()
testCostPolyConcretize()
testCostPolyDominantTerm()
testHasSymbolicTerms()
testCostVectorAdd()
testCostVectorLoopWrap()
testInstrCostDelta()
testAnalyzeBlock()
testEstimateBlockPressure()
testAnalyzeCostLeaf()
testAnalyzeCostWithLoop()
testOptGatingLeafVsLoop()
testInlineDecision()
testTierThresholds()
testEstimateTripCount()

echo ""
echo "All JIT cost model tests passed!"
