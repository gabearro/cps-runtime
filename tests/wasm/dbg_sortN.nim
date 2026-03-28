import cps/wasm/types, cps/wasm/binary, cps/wasm/runtime
let data = cast[seq[byte]](readFile("tests/wasm/testdata/sort_simple_o2.wasm"))
let m = decodeModule(data)

for n in [3, 4, 5, 6, 7, 8]:
  var vm = initWasmVM()
  let modIdx = vm.instantiate(m, @[])
  discard vm.invoke(modIdx, "init", @[wasmI32(n.int32)])
  discard vm.invoke(modIdx, "sort", @[wasmI32(n.int32)])
  var ok = true
  for i in 0 ..< n:
    let v = vm.invoke(modIdx, "get", @[wasmI32(i.int32)])[0].i32
    if v != (i + 1).int32:
      ok = false
  echo "n=", n, ": ", (if ok: "OK" else: "FAIL")
  if not ok:
    for i in 0 ..< n:
      let v = vm.invoke(modIdx, "get", @[wasmI32(i.int32)])[0].i32
      stdout.write "  ", v
    echo ""
