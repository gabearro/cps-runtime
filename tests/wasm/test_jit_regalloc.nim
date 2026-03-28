## Test: graph-coloring register allocator

import cps/wasm/jit/ir
import cps/wasm/jit/regalloc

proc testSimpleAlloc() =
  # Simple function: a = param0, b = param1, c = a + b, return c
  # Values: v0=param0, v1=param1, v2=add result
  # v0 and v1 interfere (both live when add happens)
  # v2 doesn't interfere with v0 or v1 (they're dead after use)
  var f = IrFunc(numValues: 3, numLocals: 0, numParams: 2, numResults: 1)
  f.blocks = @[BasicBlock(id: 0)]
  f.blocks[0].instrs = @[
    IrInstr(op: irParam, result: 0.IrValue, imm: 0),
    IrInstr(op: irParam, result: 1.IrValue, imm: 1),
    IrInstr(op: irAdd32, result: 2.IrValue, operands: [0.IrValue, 1.IrValue, -1.IrValue]),
    IrInstr(op: irReturn, result: -1.IrValue, operands: [2.IrValue, -1.IrValue, -1.IrValue]),
  ]

  let result = allocateRegisters(f)
  assert result.assignment.len == 3

  # v0 and v1 should get different registers (they interfere)
  assert result.assignment[0] != result.assignment[1],
    "v0 and v1 should have different registers"

  # v2 can share with v0 or v1 (no interference after add)
  echo "PASS: simple register allocation"
  echo "  v0 -> r" & $result.assignment[0].int8
  echo "  v1 -> r" & $result.assignment[1].int8
  echo "  v2 -> r" & $result.assignment[2].int8

proc testManyValues() =
  # Test with more values than registers (should spill)
  var f = IrFunc(numValues: 20, numLocals: 0, numParams: 0, numResults: 1)
  f.blocks = @[BasicBlock(id: 0)]

  # Create 20 values that all interfere (all live at the same time)
  for i in 0 ..< 20:
    f.blocks[0].instrs.add(IrInstr(op: irConst32, result: i.IrValue, imm: i.int64))

  # Use them all in a big addition chain
  f.blocks[0].instrs.add(IrInstr(op: irAdd32, result: -1.IrValue,
    operands: [0.IrValue, 19.IrValue, -1.IrValue]))

  let result = allocateRegisters(f)
  assert result.assignment.len == 20

  # With 14 integer registers, 6 values must be spilled
  var spillCount = 0
  for a in result.assignment:
    if a.int8 < 0: inc spillCount
  echo "PASS: many values allocation (20 values, " & $spillCount & " spilled)"

proc testLoopAlloc() =
  # Loop pattern: value defined in loop header, used in body, updated at loop back
  var f = IrFunc(numValues: 5, numLocals: 2, numParams: 1, numResults: 1)
  f.blocks = @[
    BasicBlock(id: 0, successors: @[1]),  # entry
    BasicBlock(id: 1, successors: @[1, 2], predecessors: @[0, 1], loopDepth: 1),  # loop
    BasicBlock(id: 2, predecessors: @[1]),  # exit
  ]

  # Entry block
  f.blocks[0].instrs = @[
    IrInstr(op: irParam, result: 0.IrValue, imm: 0),     # n
    IrInstr(op: irConst32, result: 1.IrValue, imm: 0),    # sum = 0
  ]

  # Loop body
  f.blocks[1].instrs = @[
    IrInstr(op: irPhi, result: 2.IrValue),  # n_phi
    IrInstr(op: irPhi, result: 3.IrValue),  # sum_phi
    IrInstr(op: irAdd32, result: 4.IrValue, operands: [3.IrValue, 2.IrValue, -1.IrValue]),
  ]

  # Exit: return sum
  f.blocks[2].instrs = @[
    IrInstr(op: irReturn, result: -1.IrValue, operands: [4.IrValue, -1.IrValue, -1.IrValue]),
  ]

  let result = allocateRegisters(f)
  echo "PASS: loop register allocation"
  for i in 0 ..< 5:
    let r = result.assignment[i].int8
    echo "  v" & $i & " -> " & (if r >= 0: "r" & $r else: "spill")

  # Loop values (v2, v3, v4) should have higher priority due to loop depth
  # and should get registers (not spilled)
  assert result.assignment[2].int8 >= 0, "loop phi should not be spilled"
  assert result.assignment[3].int8 >= 0, "loop phi should not be spilled"
  assert result.assignment[4].int8 >= 0, "loop add should not be spilled"

testSimpleAlloc()
testManyValues()
testLoopAlloc()

echo ""
echo "All register allocator tests passed!"
