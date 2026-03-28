## Debug: dump IR of auto-TCO'd factorial_tail
import std/os
import cps/wasm/types
import cps/wasm/binary
import cps/wasm/jit/ir
import cps/wasm/jit/lower

let wasmPath = currentSourcePath.parentDir / "testdata" / "tco_simple_o0.wasm"
let data = readFile(wasmPath)
let module = decodeModule(cast[seq[byte]](data))

let irFunc = lowerFunction(module, 1)  # factorial_tail

echo "IR: " & $irFunc.blocks.len & " blocks, " & $irFunc.numValues & " values"
echo "Params: " & $irFunc.numParams & ", Locals: " & $irFunc.numLocals
echo ""

for i, bb in irFunc.blocks:
  echo "BB" & $i & " (preds=" & $bb.predecessors & " succs=" & $bb.successors & ")"
  for j, instr in bb.instrs:
    var line = "  [" & $j & "] "
    if instr.result >= 0:
      line &= "v" & $instr.result & " = "
    line &= $instr.op
    for k in 0 ..< 3:
      if instr.operands[k] >= 0:
        line &= " v" & $instr.operands[k]
    if instr.imm != 0:
      line &= " imm=" & $instr.imm
    if instr.imm2 != 0:
      line &= " imm2=" & $instr.imm2
    echo line
  echo ""
