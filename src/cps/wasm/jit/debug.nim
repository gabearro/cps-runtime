## JIT debugging support
## Source maps, trap handlers, and disassembly for JIT-generated code

import std/[strutils, tables]
import codegen, memory

type
  SourceMap* = object
    ## Maps native code offsets to WASM instruction indices
    entries*: seq[SourceMapEntry]

  SourceMapEntry* = object
    nativeOffset*: int    # byte offset from function start
    wasmPc*: int          # WASM instruction index
    funcIdx*: int         # WASM function index

  TrapInfo* = object
    ## Information about a trap in JIT code
    reason*: string
    nativeAddr*: uint     # address where trap occurred
    wasmPc*: int          # WASM instruction index (-1 if unknown)
    funcIdx*: int         # WASM function index (-1 if unknown)

proc initSourceMap*(): SourceMap =
  result.entries = @[]

proc addEntry*(sm: var SourceMap, nativeOffset, wasmPc, funcIdx: int) =
  sm.entries.add(SourceMapEntry(
    nativeOffset: nativeOffset, wasmPc: wasmPc, funcIdx: funcIdx))

proc lookup*(sm: SourceMap, nativeOffset: int): SourceMapEntry =
  ## Find the WASM instruction for a given native code offset
  ## Uses binary search since entries are sorted by nativeOffset
  result = SourceMapEntry(nativeOffset: -1, wasmPc: -1, funcIdx: -1)
  var best = -1
  for i, entry in sm.entries:
    if entry.nativeOffset <= nativeOffset:
      best = i
    else:
      break
  if best >= 0:
    result = sm.entries[best]

proc lookupTrap*(sm: SourceMap, codeBase: pointer, trapAddr: uint): TrapInfo =
  ## Resolve a trap address to WASM source location
  let offset = (trapAddr - cast[uint](codeBase)).int
  let entry = sm.lookup(offset)
  result.nativeAddr = trapAddr
  result.wasmPc = entry.wasmPc
  result.funcIdx = entry.funcIdx
  if entry.wasmPc >= 0:
    result.reason = "trap at WASM pc=" & $entry.wasmPc & " func=" & $entry.funcIdx
  else:
    result.reason = "trap at native offset=" & $offset & " (no source map)"

# ---- AArch64 Disassembler (minimal) ----

type
  DisasmLine* = object
    offset*: int
    hex*: string
    mnemonic*: string

proc disasmAarch64*(code: JitCode): seq[DisasmLine] =
  ## Minimal AArch64 disassembler for debugging JIT output
  let base = cast[ptr UncheckedArray[uint32]](code.address)
  let count = code.size div 4

  for i in 0 ..< count:
    let inst = base[i]
    var line = DisasmLine(offset: i * 4, hex: toHex(inst, 8))

    # Decode common instructions
    let op = inst shr 24

    # NOP
    if inst == 0xD503201F'u32:
      line.mnemonic = "nop"
    # BRK
    elif (inst and 0xFFE0001F'u32) == 0xD4200000'u32:
      let imm = (inst shr 5) and 0xFFFF
      line.mnemonic = "brk #" & $imm
    # RET
    elif (inst and 0xFFFFFC1F'u32) == 0xD65F0000'u32:
      let rn = (inst shr 5) and 0x1F
      line.mnemonic = "ret" & (if rn != 30: " x" & $rn else: "")
    # B (unconditional)
    elif (inst and 0xFC000000'u32) == 0x14000000'u32:
      let imm26 = cast[int32]((inst and 0x03FFFFFF) shl 6) shr 6
      line.mnemonic = "b #" & $(imm26 * 4)
    # BL
    elif (inst and 0xFC000000'u32) == 0x94000000'u32:
      let imm26 = cast[int32]((inst and 0x03FFFFFF) shl 6) shr 6
      line.mnemonic = "bl #" & $(imm26 * 4)
    # BR
    elif (inst and 0xFFFFFC1F'u32) == 0xD61F0000'u32:
      let rn = (inst shr 5) and 0x1F
      line.mnemonic = "br x" & $rn
    # BLR
    elif (inst and 0xFFFFFC1F'u32) == 0xD63F0000'u32:
      let rn = (inst shr 5) and 0x1F
      line.mnemonic = "blr x" & $rn
    # CBZ / CBNZ
    elif (inst and 0x7F000000'u32) == 0x34000000'u32 or
         (inst and 0x7F000000'u32) == 0x35000000'u32:
      let sf = if (inst and 0x80000000'u32) != 0: "x" else: "w"
      let rt = inst and 0x1F
      let imm19 = cast[int32](((inst shr 5) and 0x7FFFF) shl 13) shr 13
      let op2 = if (inst and 0x01000000'u32) != 0: "cbnz" else: "cbz"
      line.mnemonic = op2 & " " & sf & $rt & ", #" & $(imm19 * 4)
    # B.cond
    elif (inst and 0xFF000010'u32) == 0x54000000'u32:
      let cond = inst and 0xF
      let imm19 = cast[int32](((inst shr 5) and 0x7FFFF) shl 13) shr 13
      let condStr = ["eq","ne","cs","cc","mi","pl","vs","vc",
                     "hi","ls","ge","lt","gt","le","al","nv"][cond]
      line.mnemonic = "b." & condStr & " #" & $(imm19 * 4)
    # ADD/SUB (register, 32/64)
    elif (inst and 0x1F200000'u32) == 0x0B000000'u32:
      let sf = if (inst and 0x80000000'u32) != 0: "x" else: "w"
      let rd = inst and 0x1F
      let rn = (inst shr 5) and 0x1F
      let rm = (inst shr 16) and 0x1F
      let isSub = (inst and 0x40000000'u32) != 0
      line.mnemonic = (if isSub: "sub" else: "add") & " " & sf & $rd & ", " & sf & $rn & ", " & sf & $rm
    # ADD/SUB (immediate)
    elif (inst and 0x1F000000'u32) == 0x11000000'u32:
      let sf = if (inst and 0x80000000'u32) != 0: "x" else: "w"
      let rd = inst and 0x1F
      let rn = (inst shr 5) and 0x1F
      let imm12 = (inst shr 10) and 0xFFF
      let isSub = (inst and 0x40000000'u32) != 0
      line.mnemonic = (if isSub: "sub" else: "add") & " " & sf & $rd & ", " & sf & $rn & ", #" & $imm12
    # MOV (ORR Rd, XZR, Rm)
    elif (inst and 0x1FE0FFE0'u32) == 0x0A0003E0'u32 or
         (inst and 0x1FE0FFE0'u32) == 0x2A0003E0'u32:
      let sf = if (inst and 0x80000000'u32) != 0: "x" else: "w"
      let rd = inst and 0x1F
      let rm = (inst shr 16) and 0x1F
      line.mnemonic = "mov " & sf & $rd & ", " & sf & $rm
    # MOVZ
    elif (inst and 0x1F800000'u32) == 0x12800000'u32 or
         (inst and 0x1F800000'u32) == 0x52800000'u32:
      let sf = if (inst and 0x80000000'u32) != 0: "x" else: "w"
      let rd = inst and 0x1F
      let imm16 = (inst shr 5) and 0xFFFF
      let hw = (inst shr 21) and 0x3
      let isMovn = (inst and 0x40000000'u32) == 0
      let mnm = if isMovn: "movn" else: "movz"
      line.mnemonic = mnm & " " & sf & $rd & ", #" & $imm16
      if hw > 0: line.mnemonic &= ", lsl #" & $(hw * 16)
    # LDR/STR (unsigned immediate)
    elif (inst and 0x3B000000'u32) == 0x39000000'u32:
      let size = (inst shr 30) and 3
      let isLoad = (inst and 0x00400000'u32) != 0
      let rd = inst and 0x1F
      let rn = (inst shr 5) and 0x1F
      let imm12 = (inst shr 10) and 0xFFF
      let scale = 1 shl size
      let prefix = if size == 3: "x" elif size == 2: "w" elif size == 1: "h" else: "b"
      let op2 = if isLoad: "ldr" else: "str"
      line.mnemonic = op2 & " " & (if size >= 2: prefix & $rd else: "w" & $rd) &
                      ", [x" & $rn & ", #" & $(imm12.int * scale.int) & "]"
    # STP/LDP (pre-index)
    elif (inst and 0x3E000000'u32) == 0x28000000'u32 or
         (inst and 0x3E000000'u32) == 0x2A000000'u32:
      let opc = (inst shr 30) and 3
      let isLoad = (inst and 0x00400000'u32) != 0
      let isPre = (inst and 0x01000000'u32) != 0
      let isPost = not isPre and (inst and 0x00800000'u32) != 0
      let rt1 = inst and 0x1F
      let rt2 = (inst shr 10) and 0x1F
      let rn = (inst shr 5) and 0x1F
      let imm7 = cast[int32](((inst shr 15) and 0x7F) shl 25) shr 25
      let scale = if opc >= 2: 8 else: 4
      let sf = if opc >= 2: "x" else: "w"
      let op2 = if isLoad: "ldp" else: "stp"
      var addrStr = "[x" & $rn & ", #" & $(imm7 * scale) & "]"
      if isPre: addrStr &= "!"
      line.mnemonic = op2 & " " & sf & $rt1 & ", " & sf & $rt2 & ", " & addrStr
    else:
      line.mnemonic = "?" & toHex(inst, 8)

    result.add(line)

proc formatDisasm*(lines: seq[DisasmLine]): string =
  for line in lines:
    result &= toHex(line.offset, 4) & ": " & line.hex & "  " & line.mnemonic & "\n"

proc dumpJitCode*(code: JitCode): string =
  ## Convenience: disassemble and format a JIT code block
  formatDisasm(disasmAarch64(code))
