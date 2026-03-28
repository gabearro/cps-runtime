import std/os
import cps/wasm/types
import cps/wasm/binary
import cps/wasm/runtime

let wasmPath = currentSourcePath.parentDir / "testdata" / "tco_simple_o0.wasm"
let data = readFile(wasmPath)
let module = decodeModule(cast[seq[byte]](data))

var vm = initWasmVM()
let modIdx = vm.instantiate(module, @[])

echo "Module globals:"
for i in 0 ..< vm.store.modules[modIdx].globalAddrs.len:
  let ga = vm.store.modules[modIdx].globalAddrs[i]
  let g = vm.store.globals[ga]
  echo "  global[" & $i & "] addr=" & $ga & " type=" & $g.globalType.valType &
       " mut=" & $g.globalType.mut & " value=" & $g.value.i32
echo ""
echo "Memory: " & $vm.store.mems[vm.store.modules[modIdx].memAddrs[0]].data.len & " bytes"
