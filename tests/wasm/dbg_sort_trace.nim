# Minimal: init 3 elements, sort 3, check result
import cps/wasm/types, cps/wasm/binary, cps/wasm/runtime

let data = cast[seq[byte]](readFile("tests/wasm/testdata/sort_simple_o2.wasm"))
let m = decodeModule(data)
var vm = initWasmVM()
let modIdx = vm.instantiate(m, @[])

# Just 3 elements for minimal trace
discard vm.invoke(modIdx, "init", @[wasmI32(3)])
echo "Before: ", vm.invoke(modIdx, "get", @[wasmI32(0)])[0].i32, " ", 
  vm.invoke(modIdx, "get", @[wasmI32(1)])[0].i32, " ",
  vm.invoke(modIdx, "get", @[wasmI32(2)])[0].i32
discard vm.invoke(modIdx, "sort", @[wasmI32(3)])
echo "After: ", vm.invoke(modIdx, "get", @[wasmI32(0)])[0].i32, " ",
  vm.invoke(modIdx, "get", @[wasmI32(1)])[0].i32, " ",
  vm.invoke(modIdx, "get", @[wasmI32(2)])[0].i32
