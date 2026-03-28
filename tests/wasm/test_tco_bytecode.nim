## Quick bytecode dump for TCO analysis
import std/[os, strutils]
import cps/wasm/types
import cps/wasm/binary

let wasmPath = currentSourcePath.parentDir / "testdata" / "tco_simple_o0.wasm"
let data = readFile(wasmPath)
let module = decodeModule(cast[seq[byte]](data))

var numImportFuncs = 0
for imp in module.imports:
  if imp.kind == ikFunc: inc numImportFuncs

for exp in module.exports:
  if exp.kind != ekFunc: continue
  let codeIdx = exp.idx.int - numImportFuncs
  if codeIdx < 0 or codeIdx >= module.codes.len: continue
  echo "=== " & exp.name & " (funcIdx=" & $exp.idx & ", code=" & $codeIdx & ") ==="
  for i, instr in module.codes[codeIdx].code.code:
    var line = "  [" & $i & "] " & $instr.op
    if instr.imm1 != 0 or instr.op in {opI32Const, opCall, opCallIndirect,
        opReturnCall, opBr, opBrIf, opLocalGet, opLocalSet, opLocalTee,
        opBlock, opLoop, opIf}:
      line &= " imm1=" & $instr.imm1
    if instr.imm2 != 0:
      line &= " imm2=" & $instr.imm2
    echo line
  echo ""
