## Test: try_table exception handling (WASM exception handling proposal).
##
## Builds minimal WASM modules that use try_table / throw / catch and
## verifies correct value dispatch, catch_all, and uncaught-exception trapping.

import std/[os, strutils]
import cps/wasm/types
import cps/wasm/binary
import cps/wasm/runtime

# ---------------------------------------------------------------------------
# Minimal WASM binary builder helpers
# ---------------------------------------------------------------------------

proc leb128U32(v: uint32): seq[byte] =
  var val = v
  while true:
    var b = byte(val and 0x7F); val = val shr 7
    if val != 0: b = b or 0x80
    result.add(b)
    if val == 0: break

proc leb128S32(v: int32): seq[byte] =
  var val = v; var more = true
  while more:
    var b = byte(val and 0x7F); val = val shr 7
    if (val == 0 and (b and 0x40) == 0) or (val == -1 and (b and 0x40) != 0): more = false
    else: b = b or 0x80
    result.add(b)

proc section(id: byte, content: seq[byte]): seq[byte] =
  result.add(id); result.add(leb128U32(uint32(content.len))); result.add(content)

proc wasmHeader(): seq[byte] = @[0x00'u8, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]

proc funcType(p, r: seq[byte]): seq[byte] =
  result.add(0x60); result.add(leb128U32(uint32(p.len))); result.add(p)
  result.add(leb128U32(uint32(r.len))); result.add(r)

proc typeSection(types: seq[seq[byte]]): seq[byte] =
  var c: seq[byte]; c.add(leb128U32(uint32(types.len)))
  for t in types: c.add(t)
  section(1, c)

proc funcSection(idxs: seq[uint32]): seq[byte] =
  var c = leb128U32(uint32(idxs.len))
  for i in idxs: c.add(leb128U32(i))
  section(3, c)

proc exportSection(exps: seq[tuple[name: string, kind: byte, idx: uint32]]): seq[byte] =
  var c: seq[byte]; c.add(leb128U32(uint32(exps.len)))
  for e in exps:
    c.add(leb128U32(uint32(e.name.len)))
    for ch in e.name: c.add(byte(ch))
    c.add(e.kind); c.add(leb128U32(e.idx))
  section(7, c)

proc codeSection(bodies: seq[seq[byte]]): seq[byte] =
  var c: seq[byte]; c.add(leb128U32(uint32(bodies.len)))
  for b in bodies:
    c.add(leb128U32(uint32(b.len))); c.add(b)
  section(10, c)

proc funcBody(locals: seq[tuple[count: uint32, valType: byte]], code: seq[byte]): seq[byte] =
  var b: seq[byte]; b.add(leb128U32(uint32(locals.len)))
  for l in locals: b.add(leb128U32(l.count)); b.add(l.valType)
  b.add(code); b.add(0x0B); b

# Tag section (section id = 13)
# Each tag: attribute(0x00) + typeIdx
proc tagSection(tagTypeIdxs: seq[uint32]): seq[byte] =
  var c: seq[byte]; c.add(leb128U32(uint32(tagTypeIdxs.len)))
  for idx in tagTypeIdxs:
    c.add(0x00)              # attribute = exception
    c.add(leb128U32(idx))
  section(13, c)

# Encode a try_table instruction:
#   0x1F <blocktype=empty> <catchCount> [catch clauses...]
# catchKind: 0=catch, 1=catch_ref, 2=catch_all, 3=catch_all_ref
proc tryTableInstr(catches: seq[tuple[kind: byte, tagIdx: uint32, labelDepth: uint32]]): seq[byte] =
  result.add(0x1F)              # opcode try_table
  result.add(0x40)              # block type = empty (0x40)
  result.add(leb128U32(uint32(catches.len)))
  for c in catches:
    result.add(c.kind)
    case c.kind
    of 0x00, 0x01:  # catch, catch_ref
      result.add(leb128U32(c.tagIdx))
      result.add(leb128U32(c.labelDepth))
    of 0x02, 0x03:  # catch_all, catch_all_ref
      result.add(leb128U32(c.labelDepth))
    else: discard

# ---------------------------------------------------------------------------
# Test 1: throw i32 value, catch with catch clause, return value
#
# WASM pseudo-code:
#   (func (result i32)
#     (block $handler (result i32)
#       (try_table (catch $tag_i32 0)  ;; depth 0 = branch to $handler
#         i32.const 99
#         throw $tag_i32
#         i32.const 0  ;; unreachable
#       )
#       i32.const 0  ;; unreachable (block result if try_table completes normally)
#     )
#     ;; catch payload 99 is on the stack here
#   )
#
# Encoding layout (block wraps the try_table so catch can branch out):
#   block (result i32)       ;; label depth 1 (outer block)
#     try_table (catch $tag 0) (result void)
#       i32.const 99
#       throw 0
#     end
#     unreachable
#   end
# ---------------------------------------------------------------------------

proc buildCatchI32Module(): seq[byte] =
  let i32 = 0x7F'u8
  let voidTy  = funcType(@[], @[])       # type 0: () -> () — for the tag
  let resultTy = funcType(@[], @[i32])   # type 1: () -> i32 — for the test func

  # Body:
  #   block (result i32)
  #     try_table (catch tag=0 depth=1) [empty result type]
  #       i32.const 99
  #       throw 0
  #     end  (end of try_table)
  #     unreachable
  #   end  (end of block — caught value pops here)
  var body: seq[byte]
  # block (result i32) — depth 0 from inside = label 0 (outermost of this func body)
  # actually from inside the try_table, depth 1 would refer to this block
  body.add(0x02); body.add(i32)          # block result=i32
  body.add tryTableInstr(@[(kind: 0x00'u8, tagIdx: 0'u32, labelDepth: 1'u32)])
  body.add leb128S32(99'i32)             # i32.const 99  (wait, wrong opcode)
  # i32.const opcode
  body = @[]
  # Rebuild with correct opcodes:
  body.add(0x02); body.add(i32)          # block result=i32
  # try_table catch $tag=0 (depth=1 = the outer block above)
  body.add tryTableInstr(@[(kind: 0x00'u8, tagIdx: 0'u32, labelDepth: 1'u32)])
  body.add(0x41); body.add(leb128S32(99'i32))  # i32.const 99
  body.add(0x08); body.add(leb128U32(0'u32))   # throw 0  (tag index 0)
  body.add(0x0B)                         # end try_table
  body.add(0x00)                         # unreachable
  body.add(0x0B)                         # end block

  let fbody = funcBody(@[], body)
  # Section ordering: type(1) func(3) export(7) code(10) tag(13)
  result = wasmHeader() &
           typeSection(@[voidTy, resultTy]) &
           funcSection(@[1'u32]) &
           exportSection(@[("test", 0x00.byte, 0'u32)]) &
           codeSection(@[fbody]) &
           tagSection(@[0'u32])     # tag 0 uses type 0 (() -> ())

# ---------------------------------------------------------------------------
# Test 2: catch_all catches any exception
# ---------------------------------------------------------------------------

proc buildCatchAllModule(): seq[byte] =
  let i32 = 0x7F'u8
  let voidTy   = funcType(@[], @[])      # type 0: () -> () for tag (no payload)
  let resultTy = funcType(@[], @[i32])   # type 1: () -> i32 for test func

  # (func (result i32)
  #   try_table (catch_all 0)   ;; depth=0 = try_table label (arity=0)
  #     throw 0
  #   end try_table
  #   ;; landed here: either by catch_all (caught) or by normal exit (no exception)
  #   i32.const 42
  # )
  # catch_all with depth=0 branches to the try_table label's pc = instruction after opEnd.
  # From there we push 42 and return. Both normal path and caught path return 42.
  var body: seq[byte]
  body.add tryTableInstr(@[(kind: 0x02'u8, tagIdx: 0'u32, labelDepth: 0'u32)])
  body.add(0x08); body.add(leb128U32(0'u32))   # throw 0  (always throws)
  body.add(0x0B)                               # end try_table
  body.add(0x41); body.add(leb128S32(42'i32)) # i32.const 42

  let fbody = funcBody(@[], body)
  result = wasmHeader() &
           typeSection(@[voidTy, resultTy]) &
           funcSection(@[1'u32]) &
           exportSection(@[("test", 0x00.byte, 0'u32)]) &
           codeSection(@[fbody]) &
           tagSection(@[0'u32])

# ---------------------------------------------------------------------------
# Test 3: uncaught exception → trap
# ---------------------------------------------------------------------------

proc buildUncaughtModule(): seq[byte] =
  let voidTy = funcType(@[], @[])    # type 0: tag type and func type
  var body: seq[byte]
  body.add(0x08); body.add(leb128U32(0'u32))   # throw 0
  # funcBody appends the function-end 0x0B automatically

  let fbody = funcBody(@[], body)
  result = wasmHeader() &
           typeSection(@[voidTy]) &
           funcSection(@[0'u32]) &
           exportSection(@[("test", 0x00.byte, 0'u32)]) &
           codeSection(@[fbody]) &
           tagSection(@[0'u32])

# ---------------------------------------------------------------------------
# Test 4: throw with i32 payload, catch and return payload
# ---------------------------------------------------------------------------

proc buildThrowPayloadModule(): seq[byte] =
  let i32 = 0x7F'u8
  # type 0: (i32) -> () — tag type (one i32 payload)
  # type 1: () -> i32 — test func
  let tagTy  = funcType(@[i32], @[])
  let funcTy = funcType(@[], @[i32])

  # (func (result i32)
  #   block (result i32)                  ;; outer block, arity=1
  #     try_table (catch $tag 1)          ;; catch branches to outer block
  #       i32.const 77
  #       throw $tag                      ;; pops i32(77), stores as payload
  #     end
  #     i32.const 0                       ;; normal path (not reached)
  #   end                                 ;; outer block end — arrives with 77 on stack
  # )
  var body: seq[byte]
  body.add(0x02); body.add(i32)      # block (result i32)
  body.add tryTableInstr(@[(kind: 0x00'u8, tagIdx: 0'u32, labelDepth: 1'u32)])
  body.add(0x41); body.add(leb128S32(77'i32))  # i32.const 77
  body.add(0x08); body.add(leb128U32(0'u32))   # throw 0  (pops 77 as payload)
  body.add(0x0B)                     # end try_table
  body.add(0x41); body.add(leb128S32(0'i32))   # i32.const 0 (normal path)
  body.add(0x0B)                     # end block

  let fbody = funcBody(@[], body)
  result = wasmHeader() &
           typeSection(@[tagTy, funcTy]) &
           funcSection(@[1'u32]) &
           exportSection(@[("test", 0x00.byte, 0'u32)]) &
           codeSection(@[fbody]) &
           tagSection(@[0'u32])      # tag 0 uses type 0

# ---------------------------------------------------------------------------
# Run tests
# ---------------------------------------------------------------------------

proc testCatchI32() =
  ## Verify module with catch clause decodes correctly (tag, catch table, clause kind).
  let modBytes = buildCatchI32Module()
  let module = decodeModule(modBytes)
  assert module.tagDefs.len == 1, "expected 1 tag def"
  assert module.codes.len == 1, "expected 1 func body"
  assert module.codes[0].code.catchTables.len == 1, "expected 1 catch table"
  assert module.codes[0].code.catchTables[0].len == 1, "expected 1 catch clause"
  assert module.codes[0].code.catchTables[0][0].kind == ckCatch
  echo "PASS: catch i32 module decodes correctly"

proc testCatchAll() =
  ## catch_all fires for any thrown exception and returns 42.
  let modBytes = buildCatchAllModule()
  let module = decodeModule(modBytes)
  var vm = initWasmVM()
  discard vm.instantiate(module, [])
  let result = vm.execute(0, [])
  assert result.len == 1 and result[0].kind == wvkI32,
    "expected i32 result"
  assert result[0].i32 == 42,
    "expected 42, got " & $result[0].i32
  echo "PASS: catch_all returns 42"

proc testUncaughtTrap() =
  ## Uncaught throw should raise WasmTrap.
  let modBytes = buildUncaughtModule()
  let module = decodeModule(modBytes)
  var vm = initWasmVM()
  discard vm.instantiate(module, [])
  var trapped = false
  try:
    discard vm.execute(0, [])
  except WasmTrap:
    trapped = true
  assert trapped, "expected WasmTrap for uncaught exception"
  echo "PASS: uncaught exception traps"

proc testThrowPayload() =
  ## Throw an i32 payload, catch it, return as function result.
  let modBytes = buildThrowPayloadModule()
  let module = decodeModule(modBytes)
  var vm = initWasmVM()
  discard vm.instantiate(module, [])
  let result = vm.execute(0, [])
  assert result.len == 1 and result[0].kind == wvkI32,
    "expected i32 result"
  assert result[0].i32 == 77,
    "expected 77, got " & $result[0].i32
  echo "PASS: throw with i32 payload caught and returned"

testCatchI32()
testCatchAll()
testUncaughtTrap()
testThrowPayload()
echo "All try_table tests passed!"
