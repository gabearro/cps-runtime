## Test: Tier 2 JIT multi-basic-block function inlining
##
## Verifies that callees with if/else control flow (multiple BBs) are inlined
## correctly into their callers.
##
## Module layout:
##   func 0: abs(x: i32) -> i32  = if x >= 0 then x else -x   (multi-BB: if/else)
##   func 1: caller(x: i32) -> i32 = abs(x) + 1
##
##   func 2: clamp(x,lo,hi: i32) -> i32  =  lo if x<lo, hi if x>hi, else x  (3 BBs)
##   func 3: caller2(x: i32) -> i32 = clamp(x, -10, 10)

import cps/wasm/types
import cps/wasm/binary
import cps/wasm/jit/memory
import cps/wasm/jit/pipeline
import cps/wasm/jit/lower
import cps/wasm/jit/ir

type JitFnPtr = proc(vsp: ptr uint64, locals: ptr uint64,
                     memBase: ptr byte, memSize: uint64): ptr uint64 {.cdecl.}

proc leb(v: uint32): seq[byte] =
  var x = v
  while true:
    var b = byte(x and 0x7F); x = x shr 7
    if x != 0: b = b or 0x80
    result.add(b)
    if x == 0: break

proc section(id: byte, content: seq[byte]): seq[byte] =
  result.add(id); result.add(leb(uint32(content.len))); result.add(content)

proc callJit1(fn: JitFnPtr, arg0: int32): int32 =
  var vstack: array[8, uint64]
  var locals: array[8, uint64] = [cast[uint64](arg0), 0, 0, 0, 0, 0, 0, 0]
  let ret = fn(vstack[0].addr, locals[0].addr, nil, 0)
  let cnt = (cast[uint](ret) - cast[uint](vstack[0].addr)) div 8
  assert cnt == 1, "expected 1 result"
  cast[int32](vstack[0] and 0xFFFFFFFF'u64)

proc callJit3(fn: JitFnPtr, a0, a1, a2: int32): int32 =
  var vstack: array[8, uint64]
  var locals: array[8, uint64] = [cast[uint64](a0), cast[uint64](a1), cast[uint64](a2), 0, 0, 0, 0, 0]
  let ret = fn(vstack[0].addr, locals[0].addr, nil, 0)
  let cnt = (cast[uint](ret) - cast[uint](vstack[0].addr)) div 8
  assert cnt == 1, "expected 1 result"
  cast[int32](vstack[0] and 0xFFFFFFFF'u64)

when isMainModule:
  # -----------------------------------------------------------------------
  # Test 1: inline abs(x) (if/else multi-BB callee)
  # abs: func 0 — (i32)->i32
  #   if x >= 0:
  #     return x
  #   else:
  #     return -x
  # caller: func 1 — (i32)->i32
  #   return abs(x) + 1
  #
  # WASM bytecode for abs:
  #   local.get 0                  ; 0x20 0x00
  #   i32.const 0                  ; 0x41 0x00
  #   i32.ge_s                     ; 0x4E
  #   if (result i32)              ; 0x04 0x7F
  #     local.get 0                ; 0x20 0x00
  #   else                         ; 0x05
  #     i32.const 0                ; 0x41 0x00
  #     local.get 0                ; 0x20 0x00
  #     i32.sub                    ; 0x6B
  #   end                          ; 0x0B
  #
  # WASM bytecode for caller:
  #   local.get 0                  ; 0x20 0x00
  #   call 0                       ; 0x10 0x00
  #   i32.const 1                  ; 0x41 0x01
  #   i32.add                      ; 0x6A
  # -----------------------------------------------------------------------

  block testAbs:
    var wasm = @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]
    # Type section: type 0 = (i32)->i32
    var tc: seq[byte]
    tc.add(leb(1'u32))
    tc.add(0x60'u8); tc.add(leb(1'u32)); tc.add(0x7F'u8)
    tc.add(leb(1'u32)); tc.add(0x7F'u8)
    wasm.add(section(1, tc))
    # Function section: [type0, type0]
    var fc: seq[byte]; fc.add(leb(2'u32)); fc.add(leb(0'u32)); fc.add(leb(0'u32))
    wasm.add(section(3, fc))
    # Code section
    var cc: seq[byte]; cc.add(leb(2'u32))
    # abs body
    let absBody = @[0x00'u8,  # 0 locals
                    0x20'u8, 0x00,  # local.get 0
                    0x41'u8, 0x00,  # i32.const 0
                    0x4E'u8,        # i32.ge_s
                    0x04'u8, 0x7F,  # if (result i32)
                    0x20'u8, 0x00,  # local.get 0
                    0x05'u8,        # else
                    0x41'u8, 0x00,  # i32.const 0
                    0x20'u8, 0x00,  # local.get 0
                    0x6B'u8,        # i32.sub
                    0x0B'u8,        # end
                    0x0B'u8]        # end
    cc.add(leb(uint32(absBody.len))); cc.add(absBody)
    # caller body
    let callerBody = @[0x00'u8,
                       0x20'u8, 0x00,       # local.get 0
                       0x10'u8, 0x00,       # call 0 (abs)
                       0x41'u8, 0x01,       # i32.const 1
                       0x6A'u8,             # i32.add
                       0x0B'u8]             # end
    cc.add(leb(uint32(callerBody.len))); cc.add(callerBody)
    wasm.add(section(10, cc))

    let module = decodeModule(wasm)

    # Verify the callee (abs) has multiple BBs after lowering
    let absIr = lowerFunction(module, 0)
    assert absIr.blocks.len > 1,
      "abs should have multiple BBs, got " & $absIr.blocks.len

    var pool = initJitMemPool()
    let compiled = pool.compileTier2(module, funcIdx = 1)
    let fn = cast[JitFnPtr](compiled.address)

    # caller(5) = abs(5)+1 = 6
    assert callJit1(fn, 5) == 6,  "caller(5) should be 6, got "  & $callJit1(fn, 5)
    # caller(-3) = abs(-3)+1 = 4
    assert callJit1(fn, -3) == 4, "caller(-3) should be 4, got " & $callJit1(fn, -3)
    # caller(0) = abs(0)+1 = 1
    assert callJit1(fn, 0) == 1,  "caller(0) should be 1, got "  & $callJit1(fn, 0)
    echo "PASS: multi-BB inline abs: caller(5)=6, caller(-3)=4, caller(0)=1"
    pool.destroy()

  # -----------------------------------------------------------------------
  # Test 2: inline clamp(x,lo,hi) (3-BB if/else chain callee)
  # clamp(x,lo,hi):
  #   if x < lo: return lo
  #   elif x > hi: return hi
  #   else: return x
  # caller2(x) = clamp(x, -10, 10)
  # -----------------------------------------------------------------------

  block testClamp:
    var wasm = @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]
    # Type section: type 0 = (i32,i32,i32)->i32,  type 1 = (i32)->i32
    var tc: seq[byte]; tc.add(leb(2'u32))
    # type 0: (i32,i32,i32)->i32
    tc.add(0x60'u8); tc.add(leb(3'u32)); tc.add(0x7F'u8); tc.add(0x7F'u8); tc.add(0x7F'u8)
    tc.add(leb(1'u32)); tc.add(0x7F'u8)
    # type 1: (i32)->i32
    tc.add(0x60'u8); tc.add(leb(1'u32)); tc.add(0x7F'u8); tc.add(leb(1'u32)); tc.add(0x7F'u8)
    wasm.add(section(1, tc))
    # Function section: [type0, type1]
    var fc: seq[byte]; fc.add(leb(2'u32)); fc.add(leb(0'u32)); fc.add(leb(1'u32))
    wasm.add(section(3, fc))
    # Code section
    var cc: seq[byte]; cc.add(leb(2'u32))
    # clamp body: if x < lo, return lo; if x > hi, return hi; return x
    # local.get 0; local.get 1; i32.lt_s; if (result i32)
    #   local.get 1
    # else
    #   local.get 0; local.get 2; i32.gt_s; if (result i32)
    #     local.get 2
    #   else
    #     local.get 0
    #   end
    # end
    let clampBody = @[0x00'u8,
                      0x20'u8, 0x00,  # local.get 0 (x)
                      0x20'u8, 0x01,  # local.get 1 (lo)
                      0x48'u8,        # i32.lt_s
                      0x04'u8, 0x7F,  # if (result i32)
                      0x20'u8, 0x01,  # local.get 1 (lo)
                      0x05'u8,        # else
                      0x20'u8, 0x00,  # local.get 0 (x)
                      0x20'u8, 0x02,  # local.get 2 (hi)
                      0x4A'u8,        # i32.gt_s
                      0x04'u8, 0x7F,  # if (result i32)
                      0x20'u8, 0x02,  # local.get 2 (hi)
                      0x05'u8,        # else
                      0x20'u8, 0x00,  # local.get 0 (x)
                      0x0B'u8,        # end inner if
                      0x0B'u8,        # end outer if
                      0x0B'u8]        # end function
    cc.add(leb(uint32(clampBody.len))); cc.add(clampBody)
    # caller2 body: local.get 0; i32.const -10; i32.const 10; call 0; end
    # i32.const -10 is encoded as LEB128 signed: 0x76 (= -10 in sleb128)
    let caller2Body = @[0x00'u8,
                        0x20'u8, 0x00,       # local.get 0 (x)
                        0x41'u8, 0x76,       # i32.const -10 (sleb128)
                        0x41'u8, 0x0A,       # i32.const 10
                        0x10'u8, 0x00,       # call 0 (clamp)
                        0x0B'u8]             # end
    cc.add(leb(uint32(caller2Body.len))); cc.add(caller2Body)
    wasm.add(section(10, cc))

    let module = decodeModule(wasm)

    var pool = initJitMemPool()
    let compiled = pool.compileTier2(module, funcIdx = 1)
    let fn = cast[JitFnPtr](compiled.address)

    # clamp within range
    assert callJit1(fn, 5)   == 5,   "caller2(5) should be 5,  got " & $callJit1(fn, 5)
    assert callJit1(fn, 0)   == 0,   "caller2(0) should be 0,  got " & $callJit1(fn, 0)
    assert callJit1(fn, -5)  == -5,  "caller2(-5) should be -5, got " & $callJit1(fn, -5)
    # clamp at bounds
    assert callJit1(fn, -15) == -10, "caller2(-15) should be -10, got " & $callJit1(fn, -15)
    assert callJit1(fn, 20)  == 10,  "caller2(20) should be 10, got "  & $callJit1(fn, 20)
    assert callJit1(fn, -10) == -10, "caller2(-10) should be -10, got " & $callJit1(fn, -10)
    assert callJit1(fn, 10)  == 10,  "caller2(10) should be 10, got "  & $callJit1(fn, 10)
    echo "PASS: multi-BB inline clamp: boundary and interior cases correct"
    pool.destroy()

  echo "All multi-BB inline tests passed!"
