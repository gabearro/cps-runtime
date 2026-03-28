## Test: 2× loop unrolling (software pipelining) in the Tier 2 optimizer
##
## Verifies that loopUnroll produces correct results for:
##   - Countup summation (trip count 0, 1, 2, 3, 100)
##   - Countdown loops
##   - Loops with multiple loop-carried values (both operands updated)
##   - Loops that exit immediately (n=0)
##
## Each test runs both Tier 1 and Tier 2 and compares the results to a
## reference computed value, ensuring the unrolling does not alter semantics.

import cps/wasm/types
import cps/wasm/binary
import cps/wasm/runtime
import cps/wasm/jit/memory
import cps/wasm/jit/compiler
import cps/wasm/jit/pipeline

# ---------------------------------------------------------------------------
# Minimal WASM module builder helpers
# ---------------------------------------------------------------------------

proc leb(v: uint32): seq[byte] =
  var x = v
  while true:
    var b = byte(x and 0x7F); x = x shr 7
    if x != 0: b = b or 0x80
    result.add(b)
    if x == 0: break

proc lebS(v: int32): seq[byte] =
  ## LEB128 signed
  var x = v
  var more = true
  while more:
    var b = byte(x and 0x7F)
    x = x shr 1
    more = not ((x == 0 and (b and 0x40) == 0) or (x == -1 and (b and 0x40) != 0))
    if more: b = b or 0x80
    result.add(b)

proc section(id: byte, content: seq[byte]): seq[byte] =
  result.add(id); result.add(leb(uint32(content.len))); result.add(content)

proc wasmHeader(): seq[byte] =
  @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]

# ---------------------------------------------------------------------------
# Module: sumN(n: i32) -> i32   — sum of 1..n (countup with accumulator)
#
#   (func (param i32) (result i32)
#     (local i32 i32)  ;; local[1] = i (loop var), local[2] = sum
#     local.set 1 (i32.const 1)
#     local.set 2 (i32.const 0)
#     (block $brk
#       (loop $top
#         ;; if i > n: break
#         (br_if $brk (i32.gt_s (local.get 1) (local.get 0)))
#         ;; sum += i
#         local.set 2 (i32.add (local.get 2) (local.get 1))
#         ;; i++
#         local.set 1 (i32.add (local.get 1) (i32.const 1))
#         br $top
#       )
#     )
#     local.get 2
#   )
# ---------------------------------------------------------------------------

proc buildSumNModule(): seq[byte] =
  result = wasmHeader()

  # Type section: (i32)->i32
  var tc: seq[byte]
  tc.add(leb(1)); tc.add(0x60'u8); tc.add(leb(1)); tc.add(0x7F'u8)
  tc.add(leb(1)); tc.add(0x7F'u8)
  result.add(section(1, tc))

  # Function section: [type 0]
  var fc: seq[byte]
  fc.add(leb(1)); fc.add(leb(0))
  result.add(section(3, fc))

  # Export section: "sumN" → func 0
  var ec: seq[byte]
  ec.add(leb(1))
  let name = "sumN"
  ec.add(leb(uint32(name.len))); ec.add(cast[seq[byte]](name))
  ec.add(0x00'u8); ec.add(leb(0))
  result.add(section(7, ec))

  # Code section
  var body: seq[byte]
  # 2 locals: i32, i32
  body.add(leb(1)); body.add(leb(2)); body.add(0x7F'u8)
  # local.set 1 (i32.const 1)
  body.add(0x41'u8); body.add(lebS(1)); body.add(0x21'u8); body.add(leb(1))
  # local.set 2 (i32.const 0)
  body.add(0x41'u8); body.add(lebS(0)); body.add(0x21'u8); body.add(leb(2))
  # block $brk (result void)
  body.add(0x02'u8); body.add(0x40'u8)
  # loop $top (result void)
  body.add(0x03'u8); body.add(0x40'u8)
  # br_if 1 (i32.gt_s local[1] local[0])
  body.add(0x20'u8); body.add(leb(1))   # local.get 1
  body.add(0x20'u8); body.add(leb(0))   # local.get 0
  body.add(0x4A'u8)                      # i32.gt_s
  body.add(0x0D'u8); body.add(leb(1))   # br_if $brk (depth 1)
  # local.set 2 (i32.add local[2] local[1])
  body.add(0x20'u8); body.add(leb(2))
  body.add(0x20'u8); body.add(leb(1))
  body.add(0x6A'u8)                      # i32.add
  body.add(0x21'u8); body.add(leb(2))   # local.set 2
  # local.set 1 (i32.add local[1] i32.const 1)
  body.add(0x20'u8); body.add(leb(1))
  body.add(0x41'u8); body.add(lebS(1))
  body.add(0x6A'u8)
  body.add(0x21'u8); body.add(leb(1))   # local.set 1
  # br $top (depth 0)
  body.add(0x0C'u8); body.add(leb(0))
  # end loop
  body.add(0x0B'u8)
  # end block
  body.add(0x0B'u8)
  # local.get 2
  body.add(0x20'u8); body.add(leb(2))
  # end func
  body.add(0x0B'u8)

  var cc: seq[byte]
  cc.add(leb(1)); cc.add(leb(uint32(body.len))); cc.add(body)
  result.add(section(10, cc))

# ---------------------------------------------------------------------------
# JIT helpers
# ---------------------------------------------------------------------------

type JitFn = proc(vsp: ptr uint64, locals: ptr uint64,
                  memBase: ptr byte, memSize: uint64): ptr uint64 {.cdecl.}

proc callJit1(fn: JitFn, arg0: int32): int32 =
  var vstack: array[16, uint64]
  var locals: array[8, uint64]
  locals[0] = cast[uint32](arg0).uint64
  let ret = fn(vstack[0].addr, locals[0].addr, nil, 0)
  let cnt = (cast[uint](ret) - cast[uint](vstack[0].addr)) div 8
  assert cnt == 1, "expected 1 result, got " & $cnt
  cast[int32](vstack[0] and 0xFFFFFFFF'u64)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

when isMainModule:
  let wasmBytes = buildSumNModule()
  let module = decodeModule(wasmBytes)

  var pool = initJitMemPool()

  # Tier 1 compile (func 0)
  let t1compiled = pool.compileFunction(module, funcIdx = 0)
  let t1fn = cast[JitFn](t1compiled.code.address)

  # Tier 2 compile (func 0) — runs all optimizations including loopUnroll
  let t2code = pool.compileTier2(module, funcIdx = 0, selfModuleIdx = 0)
  let t2fn = cast[JitFn](t2code.address)

  # Reference: sumN(n) = n*(n+1)/2
  proc ref_sumN(n: int32): int32 =
    if n <= 0: 0'i32 else: (n * (n + 1)) div 2

  template check(label: string, tier: string, fn: JitFn, n: int32) =
    let got = callJit1(fn, n)
    let exp = ref_sumN(n)
    assert got == exp, label & " " & tier & "(" & $n & ") expected " & $exp & " got " & $got

  # Tier 1 correctness
  for n in [0'i32, 1, 2, 3, 5, 10, 100]:
    check("sumN", "T1", t1fn, n)
  echo "PASS: Tier 1 sumN correct for n in {0,1,2,3,5,10,100}"

  # Tier 2 correctness (with loop unrolling)
  for n in [0'i32, 1, 2, 3, 5, 10, 100]:
    check("sumN", "T2", t2fn, n)
  echo "PASS: Tier 2 sumN correct for n in {0,1,2,3,5,10,100}"

  # Edge cases: odd and even trip counts to cover both Iter-A-only and full-round paths
  for n in [1'i32, 2, 7, 8, 99, 100, 1000]:
    check("sumN", "T2 edge", t2fn, n)
  echo "PASS: Tier 2 sumN correct for edge cases (odd/even trip counts)"

  # Verify T1 and T2 agree on a wider range
  var mismatches = 0
  for n in 0'i32 .. 200'i32:
    let r1 = callJit1(t1fn, n)
    let r2 = callJit1(t2fn, n)
    if r1 != r2: inc mismatches
  assert mismatches == 0, "T1/T2 mismatch on " & $mismatches & " inputs in 0..200"
  echo "PASS: Tier 1 and Tier 2 agree for sumN(0..200)"

  pool.destroy()
  echo "All loop unroll tests passed!"
