## Dump the decoded instructions for the sort function
import std/os
import cps/wasm/types
import cps/wasm/binary
import cps/wasm/runtime

let wasmPath = currentSourcePath.parentDir / "testdata" / "sort_simple_o2.wasm"
let data = cast[seq[byte]](readFile(wasmPath))
let module = decodeModule(data)

# Function 2 is sort (funcTypeIdxs[2])
# But codes are indexed from 0 excluding imports
echo "=== sort function (codes[2]) ==="
echo "locals:"
for ld in module.codes[2].locals:
  echo "  ", ld.count, " x ", ld.valType
echo "instructions: ", module.codes[2].code.code.len
echo ""
for i, instr in module.codes[2].code.code:
  var s = $i & ": " & $instr.op
  case instr.op
  of opBlock, opLoop, opIf:
    s &= " endIdx=" & $instr.imm1 & " elseIdx=" & $instr.imm2 & " pad=" & $instr.pad
  of opBr, opBrIf:
    s &= " depth=" & $instr.imm1
  of opLocalGet, opLocalSet, opLocalTee:
    s &= " idx=" & $instr.imm1
  of opI32Const:
    s &= " val=" & $cast[int32](instr.imm1)
  of opI32Load, opI32Store:
    s &= " offset=" & $instr.imm1 & " align=" & $instr.imm2
  of opCall:
    s &= " funcIdx=" & $instr.imm1 & " pad=" & $instr.pad
  of opGlobalGet, opGlobalSet:
    s &= " idx=" & $instr.imm1
  of opLocalGetLocalGet, opLocalSetLocalGet, opLocalTeeLocalGet, opLocalGetLocalTee:
    s &= " imm1=" & $instr.imm1 & " imm2=" & $instr.imm2
  of opLocalGetI32Add, opLocalGetI32Sub:
    s &= " localIdx=" & $instr.imm1
  of opI32ConstI32Add, opI32ConstI32Sub:
    s &= " C=" & $cast[int32](instr.imm1)
  of opI32ConstI32GtU:
    s &= " C=" & $instr.imm1
  of opI32ConstI32LtS, opI32ConstI32GeS:
    s &= " C=" & $cast[int32](instr.imm1)
  of opLocalGetI32ConstI32Sub, opLocalGetI32ConstI32Add:
    s &= " localIdx=" & $instr.imm1 & " C=" & $cast[int32](instr.imm2)
  of opLocalGetLocalGetI32Add, opLocalGetLocalGetI32Sub:
    s &= " X=" & $instr.imm1 & " Y=" & $instr.imm2
  of opI32AddLocalSet, opI32SubLocalSet:
    s &= " localIdx=" & $instr.imm1
  of opLocalGetI32Const:
    s &= " localIdx=" & $instr.imm1 & " C=" & $cast[int32](instr.imm2)
  of opI32EqzBrIf:
    s &= " depth=" & $instr.imm1
  else:
    if instr.imm1 != 0 or instr.imm2 != 0:
      s &= " imm1=" & $instr.imm1 & " imm2=" & $instr.imm2
  echo s
