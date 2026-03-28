## Test: high-level WASM API
## Demonstrates the clean library interface

import std/os
import cps/wasm/api

proc testLoadAndCall() =
  var engine = newWasmEngine(jit = false)

  let mod1 = engine.loadFile(currentSourcePath.parentDir / "testdata" / "fib.wasm")

  # Simple typed calls
  assert mod1.callI32("fib", 0) == 0
  assert mod1.callI32("fib", 1) == 1
  assert mod1.callI32("fib", 10) == 55
  assert mod1.callI32("fib", 20) == 6765
  echo "PASS: fib via callI32"

  assert mod1.callI32("factorial", 5) == 120
  assert mod1.callI32("factorial", 10) == 3628800
  echo "PASS: factorial via callI32"

  engine.destroy()

proc testGenericCall() =
  var engine = newWasmEngine(jit = false)
  let mod1 = engine.loadFile(currentSourcePath.parentDir / "testdata" / "fib.wasm")

  # Generic call with WasmValue args
  let r = mod1.call("fib", wasmI32(10))
  assert r.i32 == 55
  assert $r == "55"
  echo "PASS: generic call + WasmResult.i32"

  # Void result
  # (no void functions in fib.wasm, skip)

  engine.destroy()

proc testMemoryAccess() =
  var engine = newWasmEngine(jit = false)
  let mod1 = engine.loadFile(currentSourcePath.parentDir / "testdata" / "sort_o2.wasm")

  echo "PASS: memory size = " & $mod1.memoryPages() & " pages"

  # Init the sort array, then read memory
  mod1.callVoid("init", wasmI32(5))

  # The sort module stores arr at offset 65536
  # Read 4 bytes (i32) at offset 65536 = arr[0] = 5
  let bytes = mod1.readBytes(65536, 4)
  let val = cast[ptr int32](bytes[0].unsafeAddr)[]
  assert val == 5, "Expected arr[0]=5, got " & $val
  echo "PASS: memory read arr[0] = " & $val

  engine.destroy()

proc testModuleInspection() =
  var engine = newWasmEngine(jit = false)
  let mod1 = engine.loadFile(currentSourcePath.parentDir / "testdata" / "fib.wasm")

  assert mod1.hasExport("fib")
  assert mod1.hasExport("factorial")
  assert not mod1.hasExport("nonexistent")

  let funcs = mod1.exportedFunctions()
  assert "fib" in funcs
  assert "factorial" in funcs
  echo "PASS: module inspection (" & $funcs.len & " exported functions)"

  let globals = mod1.exportedGlobals()
  assert globals.len > 0
  echo "PASS: " & $globals.len & " exported globals"

  engine.destroy()

proc testHostFunctions() =
  # Build a minimal WASM module that imports env.log(i32)
  proc leb128U32(v: uint32): seq[byte] =
    var val = v
    while true:
      var b = byte(val and 0x7F); val = val shr 7
      if val != 0: b = b or 0x80
      result.add(b); if val == 0: break

  proc section(id: byte, content: seq[byte]): seq[byte] =
    result.add(id); result.add(leb128U32(uint32(content.len))); result.add(content)

  var wasm: seq[byte] = @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]

  # Type section: type 0 = (i32)->(), type 1 = (i32)->i32
  var typeSec: seq[byte] = @[2'u8]  # 2 types
  typeSec.add(@[0x60'u8, 1, 0x7F, 0])             # (i32)->()
  typeSec.add(@[0x60'u8, 1, 0x7F, 1, 0x7F])       # (i32)->i32
  wasm.add(section(1, typeSec))

  # Import section: env.log = func type 0
  var importSec: seq[byte] = @[1'u8]  # 1 import
  importSec.add(@[3'u8, byte('e'), byte('n'), byte('v')])  # "env"
  importSec.add(@[3'u8, byte('l'), byte('o'), byte('g')])  # "log"
  importSec.add(@[0x00'u8, 0x00])  # func, type 0
  wasm.add(section(2, importSec))

  # Function section: 1 func of type 1
  wasm.add(section(3, @[1'u8, 0x01]))

  # Export section: "test" = func 1
  var exportSec: seq[byte] = @[1'u8]
  exportSec.add(@[4'u8, byte('t'), byte('e'), byte('s'), byte('t')])
  exportSec.add(@[0x00'u8, 0x01])
  wasm.add(section(7, exportSec))

  # Code section: test(x) = { log(x); return x + 1 }
  var code: seq[byte] = @[0'u8]  # 0 locals
  code.add(@[0x20'u8, 0x00, 0x10, 0x00])  # local.get 0; call 0 (log)
  code.add(@[0x20'u8, 0x00, 0x41, 0x01, 0x6A])  # local.get 0; i32.const 1; i32.add
  code.add(0x0B)
  var codeSec: seq[byte] = @[1'u8]
  codeSec.add(leb128U32(code.len.uint32))
  codeSec.add(code)
  wasm.add(section(10, codeSec))

  # Set up engine with host function
  var logged: seq[int32]
  var engine = newWasmEngine(jit = false)
  engine.addHostFunc("env", "log", proc(x: int32) = logged.add(x))

  let mod1 = engine.loadBytes(wasm)
  let r = mod1.callI32("test", 42)
  assert r == 43
  assert logged == @[42'i32]
  echo "PASS: host function binding (logged: " & $logged & ", result: " & $r & ")"

  engine.destroy()

# ---- Run ----
testLoadAndCall()
testGenericCall()
testMemoryAccess()
testModuleInspection()
testHostFunctions()

echo ""
echo "All API tests passed!"
