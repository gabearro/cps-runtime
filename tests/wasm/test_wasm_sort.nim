## Test: load and run a sort algorithm compiled from C

import std/[times, strutils]
import cps/wasm/types
import cps/wasm/binary
import cps/wasm/runtime

proc testSort() =
  let data = cast[seq[byte]](readFile("tests/wasm/testdata/sort.wasm"))
  let module = decodeModule(data)
  var vm = initWasmVM()
  let modIdx = vm.instantiate(module, @[])

  # Init array with 100 elements (reverse sorted = worst case)
  discard vm.invoke(modIdx, "init_array", @[wasmI32(100)])

  # Verify first element is 100 (largest, at position 0)
  let first = vm.invoke(modIdx, "get_element", @[wasmI32(0)])
  assert first[0].i32 == 100, "Expected arr[0]=100, got " & $first[0].i32

  # Not sorted yet
  let sorted0 = vm.invoke(modIdx, "is_sorted", @[wasmI32(100)])
  assert sorted0[0].i32 == 0, "Expected not sorted"

  # Sort
  discard vm.invoke(modIdx, "bubble_sort", @[wasmI32(100)])

  # Now it should be sorted
  let sorted1 = vm.invoke(modIdx, "is_sorted", @[wasmI32(100)])
  assert sorted1[0].i32 == 1, "Expected sorted after bubble_sort"

  # Check first and last elements
  let afterFirst = vm.invoke(modIdx, "get_element", @[wasmI32(0)])
  assert afterFirst[0].i32 == 1, "Expected arr[0]=1 after sort, got " & $afterFirst[0].i32

  let afterLast = vm.invoke(modIdx, "get_element", @[wasmI32(99)])
  assert afterLast[0].i32 == 100, "Expected arr[99]=100 after sort, got " & $afterLast[0].i32

  echo "PASS: sort correctness"

  # Benchmark: sort 500 elements
  discard vm.invoke(modIdx, "init_array", @[wasmI32(500)])
  let t = cpuTime()
  discard vm.invoke(modIdx, "bubble_sort", @[wasmI32(500)])
  let elapsed = cpuTime() - t
  echo "PASS: bubble_sort(500): " & formatFloat(elapsed * 1000, ffDecimal, 2) & " ms"

  let sorted2 = vm.invoke(modIdx, "is_sorted", @[wasmI32(500)])
  assert sorted2[0].i32 == 1

testSort()
echo ""
echo "All sort tests passed!"
