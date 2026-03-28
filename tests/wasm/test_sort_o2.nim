## Test: O2-compiled bubble sort produces correct results
import std/os
import cps/wasm/types
import cps/wasm/binary
import cps/wasm/runtime

proc testSortO2() =
  let wasmPath = currentSourcePath.parentDir / "testdata" / "sort_simple_o2.wasm"
  let data = cast[seq[byte]](readFile(wasmPath))
  let module = decodeModule(data)

  echo "Module: ", module.types.len, " types, ",
       module.funcTypeIdxs.len, " functions, ",
       module.memories.len, " memories"

  for exp in module.exports:
    echo "  export: ", exp.name, " (", exp.kind, " idx=", exp.idx, ")"

  echo "Memory min=", module.memories[0].limits.min, " hasMax=", module.memories[0].limits.hasMax

  var vm = initWasmVM()
  let modIdx = vm.instantiate(module, @[])

  echo "Memory size: ", vm.getMemory(modIdx).data.len, " bytes"

  # Init array with 5 elements: arr = [5,4,3,2,1]
  discard vm.invoke(modIdx, "init", @[wasmI32(5)])

  echo "After init(5):"
  for i in 0..4:
    let v = vm.invoke(modIdx, "get", @[wasmI32(int32(i))])
    echo "  arr[", i, "] = ", v[0].i32

  # Sort
  discard vm.invoke(modIdx, "sort", @[wasmI32(5)])

  echo "After sort(5):"
  for i in 0..4:
    let v = vm.invoke(modIdx, "get", @[wasmI32(int32(i))])
    echo "  arr[", i, "] = ", v[0].i32

  # Check
  let check = vm.invoke(modIdx, "check", @[wasmI32(5)])
  echo "check(5) = ", check[0].i32
  assert check[0].i32 == 1, "Expected sorted array"

  echo ""
  echo "PASS: O2 sort test"

testSortO2()
