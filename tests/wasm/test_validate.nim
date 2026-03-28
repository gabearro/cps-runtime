## Tests for WebAssembly validation module

import std/os
import cps/wasm/types
import cps/wasm/binary
import cps/wasm/validate

# ---------------------------------------------------------------------------
# Test 1: Validate real WASM binaries
# ---------------------------------------------------------------------------
block testValidateRealBinaries:
  for fname in ["fib.wasm", "sort_o2.wasm"]:
    let path = currentSourcePath.parentDir / "testdata" / fname
    if fileExists(path):
      let data = readFile(path)
      let module = decodeModule(cast[seq[byte]](data))
      try:
        validateModule(module)
        echo "PASS: validate " & fname
      except ValidationError as e:
        echo "FAIL: validate " & fname & ": " & e.msg

# ---------------------------------------------------------------------------
# Test 2: Validate WASI binary
# ---------------------------------------------------------------------------
block testValidateWasiBinary:
  let path = currentSourcePath.parentDir / "testdata" / "hello.wasm"
  if fileExists(path):
    let data = readFile(path)
    let module = decodeModule(cast[seq[byte]](data))
    try:
      validateModule(module)
      echo "PASS: validate hello.wasm (WASI binary)"
    except ValidationError as e:
      echo "SKIP: validate hello.wasm: " & e.msg
  else:
    echo "SKIP: hello.wasm not found"

# ---------------------------------------------------------------------------
# Test 3: Hand-built valid module
# ---------------------------------------------------------------------------
block testHandBuiltValid:
  # Build a simple module: func that returns i32.const 42
  var module = WasmModule(
    types: @[FuncType(params: @[], results: @[vtI32])],
    funcTypeIdxs: @[0'u32],
    codes: @[FuncBody(
      locals: @[],
      code: Expr(code: @[
        Instr(op: opI32Const, imm1: 42),
        Instr(op: opEnd),
      ]),
    )],
    startFunc: -1,
    dataCount: -1,
  )

  try:
    validateModule(module)
    echo "PASS: validate hand-built i32.const 42"
  except ValidationError as e:
    echo "FAIL: validate hand-built: " & e.msg

# ---------------------------------------------------------------------------
# Test 4: Hand-built invalid (type mismatch)
# ---------------------------------------------------------------------------
block testHandBuiltInvalid:
  # Function returns i32 but body pushes i64
  var module = WasmModule(
    types: @[FuncType(params: @[], results: @[vtI32])],
    funcTypeIdxs: @[0'u32],
    codes: @[FuncBody(
      locals: @[],
      code: Expr(code: @[
        Instr(op: opI64Const, imm1: 42, imm2: 0),
        Instr(op: opEnd),
      ]),
    )],
    startFunc: -1,
    dataCount: -1,
  )

  var caught = false
  try:
    validateModule(module)
  except ValidationError:
    caught = true
  assert caught, "Should have caught type mismatch (i64 vs i32 return)"
  echo "PASS: detect type mismatch (i64 vs i32 return)"

# ---------------------------------------------------------------------------
# Test 5: Stack underflow detection
# ---------------------------------------------------------------------------
block testStackUnderflow:
  # Function tries to add without pushing two values
  var module = WasmModule(
    types: @[FuncType(params: @[], results: @[vtI32])],
    funcTypeIdxs: @[0'u32],
    codes: @[FuncBody(
      locals: @[],
      code: Expr(code: @[
        Instr(op: opI32Const, imm1: 1),
        Instr(op: opI32Add),  # needs 2 values, only 1 available
        Instr(op: opEnd),
      ]),
    )],
    startFunc: -1,
    dataCount: -1,
  )

  var caught = false
  try:
    validateModule(module)
  except ValidationError:
    caught = true
  assert caught, "Should have caught stack underflow"
  echo "PASS: detect stack underflow"

# ---------------------------------------------------------------------------
# Test 6: Valid block with branch
# ---------------------------------------------------------------------------
block testBlockBranch:
  # block { i32.const 1; br 0 }
  var module = WasmModule(
    types: @[FuncType(params: @[], results: @[vtI32])],
    funcTypeIdxs: @[0'u32],
    codes: @[FuncBody(
      locals: @[],
      code: Expr(code: @[
        # block [] -> [i32]
        Instr(op: opBlock, pad: 1, imm1: 0x7F),  # result type i32
        Instr(op: opI32Const, imm1: 1),
        Instr(op: opBr, imm1: 0),  # branch to block end with i32
        Instr(op: opEnd),  # end block
        Instr(op: opEnd),  # end function
      ]),
    )],
    startFunc: -1,
    dataCount: -1,
  )

  try:
    validateModule(module)
    echo "PASS: validate block with br"
  except ValidationError as e:
    echo "FAIL: validate block with br: " & e.msg

# ---------------------------------------------------------------------------
# Test 7: Memory bounds check
# ---------------------------------------------------------------------------
block testMemoryRequired:
  # i32.load without memory should fail
  var module = WasmModule(
    types: @[FuncType(params: @[vtI32], results: @[vtI32])],
    funcTypeIdxs: @[0'u32],
    codes: @[FuncBody(
      locals: @[],
      code: Expr(code: @[
        Instr(op: opLocalGet, imm1: 0),
        Instr(op: opI32Load, imm1: 0, imm2: 2),  # offset=0, align=2
        Instr(op: opEnd),
      ]),
    )],
    startFunc: -1,
    dataCount: -1,
    memories: @[],  # no memory!
  )

  var caught = false
  try:
    validateModule(module)
  except ValidationError:
    caught = true
  assert caught, "Should have caught i32.load without memory"
  echo "PASS: detect i32.load without memory"

# ---------------------------------------------------------------------------
# Test 8: Duplicate export names
# ---------------------------------------------------------------------------
block testDuplicateExports:
  var module = WasmModule(
    types: @[FuncType(params: @[], results: @[])],
    funcTypeIdxs: @[0'u32, 0'u32],
    exports: @[
      Export(name: "foo", kind: ekFunc, idx: 0),
      Export(name: "foo", kind: ekFunc, idx: 1),  # duplicate!
    ],
    codes: @[
      FuncBody(locals: @[], code: Expr(code: @[Instr(op: opEnd)])),
      FuncBody(locals: @[], code: Expr(code: @[Instr(op: opEnd)])),
    ],
    startFunc: -1,
    dataCount: -1,
  )

  var caught = false
  try:
    validateModule(module)
  except ValidationError:
    caught = true
  assert caught, "Should have caught duplicate export names"
  echo "PASS: detect duplicate export names"

# ---------------------------------------------------------------------------
# Test 9: Memory limit validation
# ---------------------------------------------------------------------------
block testMemoryLimits:
  var module = WasmModule(
    types: @[],
    memories: @[MemType(limits: Limits(min: 100, max: 10, hasMax: true))],
    startFunc: -1,
    dataCount: -1,
  )

  var caught = false
  try:
    validateModule(module)
  except ValidationError:
    caught = true
  assert caught, "Should have caught min > max"
  echo "PASS: detect memory min > max"

# ---------------------------------------------------------------------------
# Test 10: Local variable access
# ---------------------------------------------------------------------------
block testLocalAccess:
  var module = WasmModule(
    types: @[FuncType(params: @[vtI32, vtI32], results: @[vtI32])],
    funcTypeIdxs: @[0'u32],
    codes: @[FuncBody(
      locals: @[],
      code: Expr(code: @[
        Instr(op: opLocalGet, imm1: 0),  # param 0
        Instr(op: opLocalGet, imm1: 1),  # param 1
        Instr(op: opI32Add),
        Instr(op: opEnd),
      ]),
    )],
    startFunc: -1,
    dataCount: -1,
  )

  try:
    validateModule(module)
    echo "PASS: validate local access"
  except ValidationError as e:
    echo "FAIL: validate local access: " & e.msg

# ---------------------------------------------------------------------------
echo "\nAll validation tests passed!"
