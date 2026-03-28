## Test: JIT memory management and basic code execution on AArch64

import cps/wasm/jit/memory
import cps/wasm/jit/codegen

proc testJitMemPool() =
  var pool = initJitMemPool(64 * 1024)  # 64KB
  assert pool.remaining > 0
  echo "PASS: JIT memory pool created (" & $pool.remaining & " bytes)"

  # Write a simple function: return x0 + 1
  # AArch64: ADD X0, X0, #1; RET
  var buf = initAsmBuffer()
  buf.addImm(x0, x0, 1)
  buf.ret()

  let code = pool.writeCode(buf.code)
  assert code.address != nil
  echo "PASS: JIT code written at " & $cast[uint](code.address)

  # Cast to a function pointer and call it
  type AddOneFunc = proc(x: int64): int64 {.cdecl.}
  let f = cast[AddOneFunc](code.address)
  let result = f(41)
  assert result == 42, "Expected 42, got " & $result
  echo "PASS: JIT add_one(41) = " & $result

  pool.destroy()
  echo "PASS: JIT memory pool destroyed"

proc testJitArithmetic() =
  var pool = initJitMemPool()

  # Function: (x0, x1) -> x0 * x1 + x0
  var buf = initAsmBuffer()
  buf.mulReg(x2, x0, x1, is64 = false)  # w2 = w0 * w1
  buf.addReg(x0, x2, x0, is64 = false)  # w0 = w2 + w0
  buf.ret()

  let code = pool.writeCode(buf.code)
  type MulAddFunc = proc(a, b: int32): int32 {.cdecl.}
  let f = cast[MulAddFunc](code.address)

  assert f(3, 4) == 15  # 3*4+3=15
  assert f(10, 5) == 60  # 10*5+10=60
  echo "PASS: JIT mul_add arithmetic"

  pool.destroy()

proc testJitBranch() =
  var pool = initJitMemPool()

  # Function: abs(x0) — if x0 < 0 then negate it
  # CMP W0, #0
  # B.GE skip (2 instructions forward)
  # SUB W0, WZR, W0 (negate)
  # skip: RET
  var buf = initAsmBuffer()
  buf.cmpImm(x0, 0, is64 = false)
  buf.bCond(condGE, 2)  # skip 2 instructions forward (to RET)
  buf.subReg(x0, xzr, x0, is64 = false)  # negate
  buf.ret()

  let code = pool.writeCode(buf.code)
  type AbsFunc = proc(x: int32): int32 {.cdecl.}
  let f = cast[AbsFunc](code.address)

  assert f(42) == 42
  assert f(-7) == 7
  assert f(0) == 0
  echo "PASS: JIT abs branch"

  pool.destroy()

proc testJitLoop() =
  var pool = initJitMemPool()

  # Function: sum(n) = 1 + 2 + ... + n
  # W1 = 0 (accumulator)
  # loop: CMP W0, #0; B.EQ done
  # ADD W1, W1, W0
  # SUB W0, W0, #1
  # B loop
  # done: MOV W0, W1; RET
  var buf = initAsmBuffer()
  buf.movz(x1, 0, is64 = false)       # [0] w1 = 0
  # loop:
  buf.cmpImm(x0, 0, is64 = false)      # [1] cmp w0, #0
  buf.bCond(condEQ, 4)                  # [2] b.eq done (skip 4 instr to [6])
  buf.addReg(x1, x1, x0, is64 = false) # [3] w1 += w0
  buf.subImm(x0, x0, 1, is64 = false)  # [4] w0 -= 1
  buf.b(-4)                              # [5] b loop (back to [1])
  buf.movReg(x0, x1, is64 = false)      # [6] w0 = w1
  buf.ret()                              # [7] ret

  let code = pool.writeCode(buf.code)
  type SumFunc = proc(n: int32): int32 {.cdecl.}
  let f = cast[SumFunc](code.address)

  assert f(0) == 0
  assert f(1) == 1
  assert f(10) == 55
  assert f(100) == 5050
  echo "PASS: JIT loop sum"

  pool.destroy()

proc testJitLoadStore() =
  var pool = initJitMemPool()

  # Function: read an i32 from memory at [x0 + x1] where x1 is byte offset
  # ADD X2, X0, X1      ; compute address
  # LDR W0, [X2, #0]    ; load 32-bit value
  # RET
  var buf = initAsmBuffer()
  buf.addReg(x2, x0, x1)                  # x2 = base + byte_offset
  buf.ldrImm(x0, x2, 0, is64 = false)    # w0 = [x2]
  buf.ret()

  let code = pool.writeCode(buf.code)
  type ReadFunc = proc(base: pointer, byteOff: int64): int32 {.cdecl.}
  let f = cast[ReadFunc](code.address)

  var arr = [10'i32, 20, 30, 40, 50]
  assert f(arr[0].addr, 0) == 10
  assert f(arr[0].addr, 8) == 30     # index 2 = 8 bytes offset
  assert f(arr[0].addr, 16) == 50    # index 4 = 16 bytes offset
  echo "PASS: JIT load from memory"

  pool.destroy()

# ---- Run ----
testJitMemPool()
testJitArithmetic()
testJitBranch()
testJitLoop()
testJitLoadStore()

echo ""
echo "All JIT basic tests passed!"
