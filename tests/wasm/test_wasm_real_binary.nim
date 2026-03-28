## Test: load and run a real clang-compiled .wasm binary

import std/os
import cps/wasm/types
import cps/wasm/binary
import cps/wasm/runtime

proc testRealFib() =
  let wasmPath = currentSourcePath.parentDir / "testdata" / "fib.wasm"
  let data = readFile(wasmPath)
  let module = decodeModule(cast[seq[byte]](data))

  echo "Module loaded: ", module.types.len, " types, ",
       module.funcTypeIdxs.len, " functions, ",
       module.memories.len, " memories, ",
       module.exports.len, " exports"

  for exp in module.exports:
    echo "  export: ", exp.name, " (", exp.kind, " idx=", exp.idx, ")"

  var vm = initWasmVM()
  let modIdx = vm.instantiate(module, @[])

  # Test fibonacci
  assert vm.invoke(modIdx, "fib", @[wasmI32(0)])[0].i32 == 0
  assert vm.invoke(modIdx, "fib", @[wasmI32(1)])[0].i32 == 1
  assert vm.invoke(modIdx, "fib", @[wasmI32(10)])[0].i32 == 55
  assert vm.invoke(modIdx, "fib", @[wasmI32(20)])[0].i32 == 6765
  echo "PASS: fib(0..20) correct"

  # Test factorial
  assert vm.invoke(modIdx, "factorial", @[wasmI32(0)])[0].i32 == 1
  assert vm.invoke(modIdx, "factorial", @[wasmI32(1)])[0].i32 == 1
  assert vm.invoke(modIdx, "factorial", @[wasmI32(5)])[0].i32 == 120
  assert vm.invoke(modIdx, "factorial", @[wasmI32(10)])[0].i32 == 3628800
  echo "PASS: factorial(0..10) correct"

  echo "PASS: factorial(0..10) correct"

proc testRealSortO2() =
  let wasmPath = currentSourcePath.parentDir / "testdata" / "sort_o2.wasm"
  let data = readFile(wasmPath)
  let module = decodeModule(cast[seq[byte]](data))
  var vm = initWasmVM()
  let modIdx = vm.instantiate(module, @[])
  for n in [3, 5, 10, 50, 100]:
    discard vm.invoke(modIdx, "init", @[wasmI32(n.int32)])
    discard vm.invoke(modIdx, "sort", @[wasmI32(n.int32)])
    assert vm.invoke(modIdx, "check", @[wasmI32(n.int32)])[0].i32 == 1
  echo "PASS: O2 bubble sort (3..100 elements)"

testRealFib()
testRealSortO2()
echo ""
echo "All real binary tests passed!"
