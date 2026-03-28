import cps/wasm/types
import cps/wasm/binary
import cps/wasm/jit/memory
import cps/wasm/jit/pipeline
import std/os

let wasmPath = currentSourcePath.parentDir / "testdata" / "binom.wasm"
let data = readFile(wasmPath)
let module = decodeModule(cast[seq[byte]](data))
echo "types: ", module.types.len
echo "codes: ", module.codes.len

var pool = initJitMemPool()
echo "compiling T2 selfModuleIdx=0..."
let code = compileTier2(pool, module, 0, selfModuleIdx = 0)
echo "compiled OK, numLocals=", code.numLocals

type Fn = proc(vsp: ptr uint64, locals: ptr uint64, mem: ptr byte, memSz: uint64): ptr uint64 {.cdecl.}
let f = cast[Fn](code.address)

for n in [2'i32, 3, 2]:
  for k in [0'i32]:
    var locals = newSeq[uint64](max(code.numLocals, 4))
    locals[0] = n.uint64; locals[1] = k.uint64
    var vstack: array[1024, uint64]
    stderr.writeLine("calling binom(" & $n & "," & $k & ")...")
    let ret = f(vstack[0].addr, locals[0].addr, nil, 0)
    stderr.writeLine("returned")
    echo "binom(", n, ",", k, ") = ", cast[int32](vstack[0])

assert block:
  var locals = newSeq[uint64](max(code.numLocals, 4))
  locals[0] = 25; locals[1] = 12
  var vstack: array[1024, uint64]
  discard f(vstack[0].addr, locals[0].addr, nil, 0)
  cast[int32](vstack[0]) == 5200300
echo "PASS binom(25,12) = 5200300"
pool.destroy()
