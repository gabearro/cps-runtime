## WAT-to-binary encoder + WAST assertion runner
## Parses WAT text format, encodes to WASM binary, runs spec assertions.

import std/[strutils, math, tables]
import cps/wasm/types
import cps/wasm/binary
import cps/wasm/runtime

# ---------------------------------------------------------------------------
# S-expression tokenizer
# ---------------------------------------------------------------------------

type
  TokenKind = enum
    tkLParen, tkRParen, tkAtom, tkString, tkEof

  Token = object
    kind: TokenKind
    s: string

  Lexer = object
    src: string
    pos: int

proc initLexer(src: string): Lexer =
  Lexer(src: src, pos: 0)

proc skipWhitespace(lex: var Lexer) =
  while lex.pos < lex.src.len:
    let c = lex.src[lex.pos]
    if c in {' ', '\t', '\n', '\r'}:
      inc lex.pos
    elif c == ';' and lex.pos + 1 < lex.src.len and lex.src[lex.pos+1] == ';':
      while lex.pos < lex.src.len and lex.src[lex.pos] != '\n':
        inc lex.pos
    elif c == '(' and lex.pos + 1 < lex.src.len and lex.src[lex.pos+1] == ';':
      inc lex.pos; inc lex.pos
      while lex.pos + 1 < lex.src.len:
        if lex.src[lex.pos] == ';' and lex.src[lex.pos+1] == ')':
          inc lex.pos; inc lex.pos
          break
        inc lex.pos
    else:
      break

proc nextToken(lex: var Lexer): Token =
  lex.skipWhitespace()
  if lex.pos >= lex.src.len:
    return Token(kind: tkEof)
  let c = lex.src[lex.pos]
  if c == '(':
    inc lex.pos
    return Token(kind: tkLParen, s: "(")
  elif c == ')':
    inc lex.pos
    return Token(kind: tkRParen, s: ")")
  elif c == '"':
    inc lex.pos
    var s = ""
    while lex.pos < lex.src.len and lex.src[lex.pos] != '"':
      if lex.src[lex.pos] == '\\' and lex.pos + 1 < lex.src.len:
        inc lex.pos
        case lex.src[lex.pos]
        of 'n': s.add('\n'); inc lex.pos
        of 't': s.add('\t'); inc lex.pos
        of '\\': s.add('\\'); inc lex.pos
        of '"': s.add('"'); inc lex.pos
        else: s.add('\\'); s.add(lex.src[lex.pos]); inc lex.pos
      else:
        s.add(lex.src[lex.pos])
        inc lex.pos
    if lex.pos < lex.src.len: inc lex.pos
    return Token(kind: tkString, s: s)
  else:
    let start = lex.pos
    while lex.pos < lex.src.len and lex.src[lex.pos] notin {' ', '\t', '\n', '\r', '(', ')'}:
      inc lex.pos
    return Token(kind: tkAtom, s: lex.src[start ..< lex.pos])

# ---------------------------------------------------------------------------
# S-expression AST
# ---------------------------------------------------------------------------

type
  SExprKind = enum
    sAtom, sList

  SExpr = ref object
    case kind: SExprKind
    of sAtom:
      atom: string
    of sList:
      children: seq[SExpr]

proc parseOne(lex: var Lexer): SExpr =
  let tok = lex.nextToken()
  case tok.kind
  of tkLParen:
    result = SExpr(kind: sList, children: @[])
    while true:
      lex.skipWhitespace()
      if lex.pos >= lex.src.len: break
      if lex.src[lex.pos] == ')':
        inc lex.pos
        break
      let child = parseOne(lex)
      if child != nil: result.children.add(child)
  of tkAtom:
    result = SExpr(kind: sAtom, atom: tok.s)
  of tkString:
    result = SExpr(kind: sAtom, atom: tok.s)
  of tkRParen, tkEof:
    result = nil

proc parseSExprs*(src: string): seq[SExpr] =
  var lex = initLexer(src)
  while true:
    lex.skipWhitespace()
    if lex.pos >= lex.src.len: break
    let e = parseOne(lex)
    if e != nil: result.add(e)

proc head(e: SExpr): string =
  if e.kind == sList and e.children.len > 0 and e.children[0].kind == sAtom:
    e.children[0].atom
  else: ""

proc childCount(e: SExpr): int =
  if e.kind == sList: e.children.len else: 0

# ---------------------------------------------------------------------------
# Number parsing utilities
# ---------------------------------------------------------------------------

proc parseI32(s: string): int32 =
  let t = s.strip()
  var neg = false
  var h = t
  if h.startsWith("-"):
    neg = true; h = h[1 .. ^1]
  elif h.startsWith("+"):
    h = h[1 .. ^1]
  if h.startsWith("0x") or h.startsWith("0X"):
    let v = uint32(parseHexInt(h[2 .. ^1]))
    return if neg: -int32(v) else: int32(v)
  else:
    let v = parseBiggestInt(t)
    return int32(v)

proc parseI64(s: string): int64 =
  let t = s.strip()
  var neg = false
  var h = t
  if h.startsWith("-"):
    neg = true; h = h[1 .. ^1]
  elif h.startsWith("+"):
    h = h[1 .. ^1]
  if h.startsWith("0x") or h.startsWith("0X"):
    let v = uint64(parseHexInt(h[2 .. ^1]))
    return if neg: -int64(v) else: int64(v)
  else:
    return parseBiggestInt(t)

proc hexFloatToF64(t: string): float64 =
  var neg = false
  var h = t
  if h[0] == '-': neg = true; h = h[1 .. ^1]
  elif h[0] == '+': h = h[1 .. ^1]
  # h starts with 0x
  h = h[2 .. ^1]
  let pPos = h.toLowerAscii().find('p')
  let dotPos = h.find('.')
  var intStr, fracStr: string
  var exp2 = 0
  if pPos >= 0:
    if dotPos >= 0 and dotPos < pPos:
      intStr = h[0 ..< dotPos]; fracStr = h[dotPos+1 ..< pPos]
    else:
      intStr = h[0 ..< pPos]; fracStr = ""
    exp2 = parseInt(h[pPos+1 .. ^1])
  else:
    if dotPos >= 0:
      intStr = h[0 ..< dotPos]; fracStr = h[dotPos+1 .. ^1]
    else:
      intStr = h; fracStr = ""
  var v = 0.0
  if intStr.len > 0: v = float64(parseHexInt(intStr))
  if fracStr.len > 0:
    let fracBits = fracStr.len * 4
    v += float64(parseHexInt(fracStr)) / float64(1'u64 shl fracBits)
  v *= pow(2.0, float64(exp2))
  if neg: v = -v
  return v

proc parseF32(s: string): float32 =
  let t = s.strip()
  if t == "inf" or t == "+inf": return Inf.float32
  if t == "-inf": return NegInf.float32
  if t == "nan" or t == "+nan": return NaN.float32
  if t == "-nan": return cast[float32](0xFFC00000'u32)
  if t.startsWith("nan:0x") or t.startsWith("+nan:0x"):
    let payload = uint32(parseHexInt(t[t.find('x')+1 .. ^1]))
    return cast[float32](0x7F800000'u32 or (payload and 0x007FFFFF'u32))
  if t.startsWith("-nan:0x"):
    let payload = uint32(parseHexInt(t[t.find('x')+1 .. ^1]))
    return cast[float32](0xFF800000'u32 or (payload and 0x007FFFFF'u32))
  if t.startsWith("0x") or t.startsWith("-0x") or t.startsWith("+0x"):
    return float32(hexFloatToF64(t))
  return parseFloat(t).float32

proc parseF64(s: string): float64 =
  let t = s.strip()
  if t == "inf" or t == "+inf": return Inf
  if t == "-inf": return NegInf
  if t == "nan" or t == "+nan": return NaN
  if t == "-nan": return cast[float64](0xFFF8000000000000'u64)
  if t.startsWith("nan:0x") or t.startsWith("+nan:0x"):
    let payload = uint64(parseHexInt(t[t.find('x')+1 .. ^1]))
    return cast[float64](0x7FF0000000000000'u64 or (payload and 0x000FFFFFFFFFFFFF'u64))
  if t.startsWith("-nan:0x"):
    let payload = uint64(parseHexInt(t[t.find('x')+1 .. ^1]))
    return cast[float64](0xFFF0000000000000'u64 or (payload and 0x000FFFFFFFFFFFFF'u64))
  if t.startsWith("0x") or t.startsWith("-0x") or t.startsWith("+0x"):
    return hexFloatToF64(t)
  return parseFloat(t)

# ---------------------------------------------------------------------------
# WAT-to-binary encoder
# ---------------------------------------------------------------------------

type
  WatEncodeError* = object of CatchableError

proc watError(msg: string) {.noreturn.} =
  raise newException(WatEncodeError, msg)

proc leb128U32(v: uint32): seq[byte] =
  var val = v
  while true:
    var b = byte(val and 0x7F)
    val = val shr 7
    if val != 0: b = b or 0x80
    result.add(b)
    if val == 0: break

proc leb128S32(v: int32): seq[byte] =
  var val = v
  var more = true
  while more:
    var b = byte(val and 0x7F)
    val = val shr 7
    if (val == 0 and (b and 0x40) == 0) or (val == -1 and (b and 0x40) != 0):
      more = false
    else:
      b = b or 0x80
    result.add(b)

proc leb128S64(v: int64): seq[byte] =
  var val = v
  var more = true
  while more:
    var b = byte(val and 0x7F)
    val = val shr 7
    if (val == 0 and (b and 0x40) == 0) or (val == -1 and (b and 0x40) != 0):
      more = false
    else:
      b = b or 0x80
    result.add(b)

proc wasmSection(id: byte, content: seq[byte]): seq[byte] =
  result.add(id)
  result.add(leb128U32(uint32(content.len)))
  result.add(content)

proc valTypeByte(s: string): byte =
  case s
  of "i32": 0x7F
  of "i64": 0x7E
  of "f32": 0x7D
  of "f64": 0x7C
  else: watError("unknown valtype: " & s); 0

proc instrOpcode(name: string): int =
  case name
  of "unreachable": 0x00
  of "nop": 0x01
  of "block": 0x02
  of "loop": 0x03
  of "if": 0x04
  of "else": 0x05
  of "end": 0x0B
  of "br": 0x0C
  of "br_if": 0x0D
  of "br_table": 0x0E
  of "return": 0x0F
  of "call": 0x10
  of "call_indirect": 0x11
  of "drop": 0x1A
  of "select": 0x1B
  of "local.get": 0x20
  of "local.set": 0x21
  of "local.tee": 0x22
  of "global.get": 0x23
  of "global.set": 0x24
  of "i32.load": 0x28
  of "i64.load": 0x29
  of "f32.load": 0x2A
  of "f64.load": 0x2B
  of "i32.load8_s": 0x2C
  of "i32.load8_u": 0x2D
  of "i32.load16_s": 0x2E
  of "i32.load16_u": 0x2F
  of "i64.load8_s": 0x30
  of "i64.load8_u": 0x31
  of "i64.load16_s": 0x32
  of "i64.load16_u": 0x33
  of "i64.load32_s": 0x34
  of "i64.load32_u": 0x35
  of "i32.store": 0x36
  of "i64.store": 0x37
  of "f32.store": 0x38
  of "f64.store": 0x39
  of "i32.store8": 0x3A
  of "i32.store16": 0x3B
  of "i64.store8": 0x3C
  of "i64.store16": 0x3D
  of "i64.store32": 0x3E
  of "memory.size": 0x3F
  of "memory.grow": 0x40
  of "i32.const": 0x41
  of "i64.const": 0x42
  of "f32.const": 0x43
  of "f64.const": 0x44
  of "i32.eqz": 0x45
  of "i32.eq": 0x46
  of "i32.ne": 0x47
  of "i32.lt_s": 0x48
  of "i32.lt_u": 0x49
  of "i32.gt_s": 0x4A
  of "i32.gt_u": 0x4B
  of "i32.le_s": 0x4C
  of "i32.le_u": 0x4D
  of "i32.ge_s": 0x4E
  of "i32.ge_u": 0x4F
  of "i64.eqz": 0x50
  of "i64.eq": 0x51
  of "i64.ne": 0x52
  of "i64.lt_s": 0x53
  of "i64.lt_u": 0x54
  of "i64.gt_s": 0x55
  of "i64.gt_u": 0x56
  of "i64.le_s": 0x57
  of "i64.le_u": 0x58
  of "i64.ge_s": 0x59
  of "i64.ge_u": 0x5A
  of "f32.eq": 0x5B
  of "f32.ne": 0x5C
  of "f32.lt": 0x5D
  of "f32.gt": 0x5E
  of "f32.le": 0x5F
  of "f32.ge": 0x60
  of "f64.eq": 0x61
  of "f64.ne": 0x62
  of "f64.lt": 0x63
  of "f64.gt": 0x64
  of "f64.le": 0x65
  of "f64.ge": 0x66
  of "i32.clz": 0x67
  of "i32.ctz": 0x68
  of "i32.popcnt": 0x69
  of "i32.add": 0x6A
  of "i32.sub": 0x6B
  of "i32.mul": 0x6C
  of "i32.div_s": 0x6D
  of "i32.div_u": 0x6E
  of "i32.rem_s": 0x6F
  of "i32.rem_u": 0x70
  of "i32.and": 0x71
  of "i32.or": 0x72
  of "i32.xor": 0x73
  of "i32.shl": 0x74
  of "i32.shr_s": 0x75
  of "i32.shr_u": 0x76
  of "i32.rotl": 0x77
  of "i32.rotr": 0x78
  of "i64.clz": 0x79
  of "i64.ctz": 0x7A
  of "i64.popcnt": 0x7B
  of "i64.add": 0x7C
  of "i64.sub": 0x7D
  of "i64.mul": 0x7E
  of "i64.div_s": 0x7F
  of "i64.div_u": 0x80
  of "i64.rem_s": 0x81
  of "i64.rem_u": 0x82
  of "i64.and": 0x83
  of "i64.or": 0x84
  of "i64.xor": 0x85
  of "i64.shl": 0x86
  of "i64.shr_s": 0x87
  of "i64.shr_u": 0x88
  of "i64.rotl": 0x89
  of "i64.rotr": 0x8A
  of "f32.abs": 0x8B
  of "f32.neg": 0x8C
  of "f32.ceil": 0x8D
  of "f32.floor": 0x8E
  of "f32.trunc": 0x8F
  of "f32.nearest": 0x90
  of "f32.sqrt": 0x91
  of "f32.add": 0x92
  of "f32.sub": 0x93
  of "f32.mul": 0x94
  of "f32.div": 0x95
  of "f32.min": 0x96
  of "f32.max": 0x97
  of "f32.copysign": 0x98
  of "f64.abs": 0x99
  of "f64.neg": 0x9A
  of "f64.ceil": 0x9B
  of "f64.floor": 0x9C
  of "f64.trunc": 0x9D
  of "f64.nearest": 0x9E
  of "f64.sqrt": 0x9F
  of "f64.add": 0xA0
  of "f64.sub": 0xA1
  of "f64.mul": 0xA2
  of "f64.div": 0xA3
  of "f64.min": 0xA4
  of "f64.max": 0xA5
  of "f64.copysign": 0xA6
  of "i32.wrap_i64": 0xA7
  of "i32.trunc_f32_s": 0xA8
  of "i32.trunc_f32_u": 0xA9
  of "i32.trunc_f64_s": 0xAA
  of "i32.trunc_f64_u": 0xAB
  of "i64.extend_i32_s": 0xAC
  of "i64.extend_i32_u": 0xAD
  of "i64.trunc_f32_s": 0xAE
  of "i64.trunc_f32_u": 0xAF
  of "i64.trunc_f64_s": 0xB0
  of "i64.trunc_f64_u": 0xB1
  of "f32.convert_i32_s": 0xB2
  of "f32.convert_i32_u": 0xB3
  of "f32.convert_i64_s": 0xB4
  of "f32.convert_i64_u": 0xB5
  of "f32.demote_f64": 0xB6
  of "f64.convert_i32_s": 0xB7
  of "f64.convert_i32_u": 0xB8
  of "f64.convert_i64_s": 0xB9
  of "f64.convert_i64_u": 0xBA
  of "f64.promote_f32": 0xBB
  of "i32.reinterpret_f32": 0xBC
  of "i64.reinterpret_f64": 0xBD
  of "f32.reinterpret_i32": 0xBE
  of "f64.reinterpret_i64": 0xBF
  of "i32.extend8_s": 0xC0
  of "i32.extend16_s": 0xC1
  of "i64.extend8_s": 0xC2
  of "i64.extend16_s": 0xC3
  of "i64.extend32_s": 0xC4
  else: -1

proc isMemOp(opcode: int): bool =
  opcode in {0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F,
             0x30, 0x31, 0x32, 0x33, 0x34, 0x35,
             0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E}

proc needsImm1(opcode: int): bool =
  # Instructions that take exactly 1 immediate (local/global/func idx, label depth, const)
  opcode in {0x20, 0x21, 0x22, 0x23, 0x24,  # local/global get/set/tee
             0x10, 0x11,                       # call, call_indirect
             0x0C, 0x0D,                       # br, br_if
             0x41, 0x42, 0x43, 0x44}           # const

type
  FuncInfo = object
    name: string        # export name or "" if none
    idName: string      # $name identifier
    typeIdx: int
    paramNames: seq[string]
    paramTypes: seq[byte]
    resultTypes: seq[byte]
    locals: seq[tuple[name: string, t: byte]]
    bodyNodes: seq[SExpr]  # raw body AST nodes

  ModuleBuilder = object
    funcs: seq[FuncInfo]
    hasMemory: bool
    memPages: int

# ---------------------------------------------------------------------------
# The streaming instruction encoder
# Handles both flat form (atoms with separate args) and folded form (s-exprs)
# ---------------------------------------------------------------------------

type
  FlatEncoder = object
    nodes: seq[SExpr]
    pos: int
    fi: FuncInfo
    allFuncs: seq[FuncInfo]

proc resolveLocal(name: string, fi: FuncInfo): int =
  for i, pn in fi.paramNames:
    if pn == name: return i
  let base = fi.paramNames.len
  for i, loc in fi.locals:
    if loc.name == name: return base + i
  try: return parseInt(name)
  except: return -1

proc resolveFunc(name: string, allFuncs: seq[FuncInfo]): int =
  if name.startsWith("$"):
    for i, f in allFuncs:
      if f.idName == name: return i
  try: return parseInt(name)
  except: return -1

# Forward declarations
proc encodeSeq(enc: var FlatEncoder): seq[byte]
proc encodeOne(enc: var FlatEncoder): seq[byte]

proc nextAtom(enc: var FlatEncoder): string =
  ## Consume next node and return as atom (must be atom)
  if enc.pos >= enc.nodes.len: return ""
  let n = enc.nodes[enc.pos]
  inc enc.pos
  if n.kind == sAtom: n.atom
  else: ""

proc peekAtom(enc: FlatEncoder): string =
  if enc.pos >= enc.nodes.len: return ""
  let n = enc.nodes[enc.pos]
  if n.kind == sAtom: n.atom
  else: ""

proc peekNode(enc: FlatEncoder): SExpr =
  if enc.pos >= enc.nodes.len: return nil
  enc.nodes[enc.pos]

proc encodeMemArg(enc: var FlatEncoder, defaultAlign: uint32): seq[byte] =
  ## Read optional offset=N align=N atoms, return encoded memarg
  var offset = 0'u32
  var align = defaultAlign
  while enc.pos < enc.nodes.len:
    let n = enc.nodes[enc.pos]
    if n.kind == sAtom:
      if n.atom.startsWith("offset="):
        offset = uint32(parseInt(n.atom[7 .. ^1]))
        inc enc.pos
      elif n.atom.startsWith("align="):
        align = uint32(parseInt(n.atom[6 .. ^1]))
        inc enc.pos
      else:
        break
    else:
      break
  result.add(leb128U32(align))
  result.add(leb128U32(offset))

proc defaultMemAlign(opcode: int): uint32 =
  case opcode
  of 0x28, 0x36: 2  # i32.load/store
  of 0x29, 0x37: 3  # i64.load/store
  of 0x2A, 0x38: 2  # f32.load/store
  of 0x2B, 0x39: 3  # f64.load/store
  of 0x2C, 0x2D, 0x3A: 0  # load8, store8
  of 0x2E, 0x2F, 0x3B: 1  # load16, store16
  of 0x30, 0x31, 0x3C: 0  # i64.load8, i64.store8
  of 0x32, 0x33, 0x3D: 1  # i64.load16, i64.store16
  of 0x34, 0x35, 0x3E: 2  # i64.load32, i64.store32
  else: 0

proc encodeBlockType(enc: var FlatEncoder): seq[byte] =
  ## Check if next node is (result T), consume it and return blocktype byte
  if enc.pos < enc.nodes.len and enc.nodes[enc.pos].kind == sList:
    let n = enc.nodes[enc.pos]
    if n.head == "result" and n.childCount >= 2:
      inc enc.pos
      return @[valTypeByte(n.children[1].atom)]
  return @[0x40'u8]

proc encodeFoldedInstr(node: SExpr, fi: FuncInfo, allFuncs: seq[FuncInfo]): seq[byte]

proc encodeBlockBody(enc: var FlatEncoder): seq[byte] =
  ## Encode until we see a 'end' atom or run out of nodes
  ## Returns bytes without the end opcode
  while enc.pos < enc.nodes.len:
    let n = enc.nodes[enc.pos]
    # Check for 'end' atom
    if n.kind == sAtom and n.atom == "end":
      inc enc.pos
      break
    # Check for 'else' atom - stop (caller handles)
    if n.kind == sAtom and n.atom == "else":
      break
    result.add(encodeOne(enc))

proc encodeOne(enc: var FlatEncoder): seq[byte] =
  if enc.pos >= enc.nodes.len: return

  let node = enc.nodes[enc.pos]
  inc enc.pos

  if node.kind == sList:
    # Folded s-expression
    result.add(encodeFoldedInstr(node, enc.fi, enc.allFuncs))
    return

  # Atom = flat instruction name
  let opName = node.atom
  let op = instrOpcode(opName)

  if op < 0:
    # Not an instruction — skip (could be a label $name)
    return

  case opName
  of "block", "loop":
    result.add(byte(op))
    # Check for optional $label
    if enc.pos < enc.nodes.len and enc.nodes[enc.pos].kind == sAtom and
       enc.nodes[enc.pos].atom.startsWith("$"):
      inc enc.pos  # skip label
    # Block type
    result.add(encodeBlockType(enc))
    # Body until 'end'
    result.add(encodeBlockBody(enc))
    result.add(0x0B)

  of "if":
    result.add(0x04)
    if enc.pos < enc.nodes.len and enc.nodes[enc.pos].kind == sAtom and
       enc.nodes[enc.pos].atom.startsWith("$"):
      inc enc.pos
    result.add(encodeBlockType(enc))
    # Encode then-body until 'else' or 'end'
    while enc.pos < enc.nodes.len:
      let n = enc.nodes[enc.pos]
      if n.kind == sAtom and (n.atom == "else" or n.atom == "end"):
        break
      result.add(encodeOne(enc))
    # Check for else
    if enc.pos < enc.nodes.len and enc.nodes[enc.pos].kind == sAtom and
       enc.nodes[enc.pos].atom == "else":
      inc enc.pos  # consume 'else'
      result.add(0x05)  # else opcode
      # Encode else-body until 'end'
      while enc.pos < enc.nodes.len:
        let n = enc.nodes[enc.pos]
        if n.kind == sAtom and n.atom == "end":
          break
        result.add(encodeOne(enc))
    # Consume 'end'
    if enc.pos < enc.nodes.len and enc.nodes[enc.pos].kind == sAtom and
       enc.nodes[enc.pos].atom == "end":
      inc enc.pos
    result.add(0x0B)

  of "else":
    # Standalone else - shouldn't happen in flat sequence but handle gracefully
    result.add(0x05)

  of "end":
    result.add(0x0B)

  of "br", "br_if":
    result.add(byte(op))
    let labelAtom = enc.nextAtom()
    let labelIdx = (try: uint32(parseInt(labelAtom)) except CatchableError: 0'u32)
    result.add(leb128U32(labelIdx))

  of "br_table":
    var labels: seq[uint32]
    while enc.pos < enc.nodes.len and enc.nodes[enc.pos].kind == sAtom:
      let a = enc.nodes[enc.pos].atom
      let v = (try: parseInt(a) except CatchableError: -1)
      if v < 0: break
      labels.add(uint32(v))
      inc enc.pos
    if labels.len > 0:
      let default = labels[^1]
      let targets = labels[0 ..< labels.len - 1]
      result.add(0x0E)
      result.add(leb128U32(uint32(targets.len)))
      for t in targets: result.add(leb128U32(t))
      result.add(leb128U32(default))

  of "call":
    result.add(0x10)
    let nameAtom = enc.nextAtom()
    let funcIdx = resolveFunc(nameAtom, enc.allFuncs)
    result.add(leb128U32(uint32(funcIdx)))

  of "call_indirect":
    result.add(0x11)
    let typeAtom = enc.nextAtom()
    result.add(leb128U32(uint32(parseInt(typeAtom))))
    result.add(0x00)  # table index

  of "local.get", "local.set", "local.tee":
    result.add(byte(op))
    let nameAtom = enc.nextAtom()
    let localIdx = resolveLocal(nameAtom, enc.fi)
    result.add(leb128U32(uint32(localIdx)))

  of "global.get", "global.set":
    result.add(byte(op))
    let nameAtom = enc.nextAtom()
    let gIdx = (try: uint32(parseInt(nameAtom)) except CatchableError: 0'u32)
    result.add(leb128U32(gIdx))

  of "i32.const":
    result.add(0x41)
    let v = parseI32(enc.nextAtom())
    result.add(leb128S32(v))

  of "i64.const":
    result.add(0x42)
    let v = parseI64(enc.nextAtom())
    result.add(leb128S64(v))

  of "f32.const":
    result.add(0x43)
    let v = parseF32(enc.nextAtom())
    let bits = cast[uint32](v)
    result.add(byte(bits and 0xFF))
    result.add(byte((bits shr 8) and 0xFF))
    result.add(byte((bits shr 16) and 0xFF))
    result.add(byte((bits shr 24) and 0xFF))

  of "f64.const":
    result.add(0x44)
    let v = parseF64(enc.nextAtom())
    let bits = cast[uint64](v)
    for i in 0 ..< 8:
      result.add(byte((bits shr (i * 8)) and 0xFF))

  of "memory.size":
    result.add(0x3F)
    result.add(0x00)

  of "memory.grow":
    result.add(0x40)
    result.add(0x00)

  else:
    if isMemOp(op):
      result.add(byte(op))
      result.add(encodeMemArg(enc, defaultMemAlign(op)))
    else:
      # No-arg instructions
      result.add(byte(op))

proc encodeSeq(enc: var FlatEncoder): seq[byte] =
  while enc.pos < enc.nodes.len:
    result.add(encodeOne(enc))

# Folded form encoder: (opname operand1 operand2 ...)
proc encodeFoldedInstr(node: SExpr, fi: FuncInfo, allFuncs: seq[FuncInfo]): seq[byte] =
  if node.kind != sList or node.childCount == 0: return
  let opName = node.children[0].atom
  let op = instrOpcode(opName)

  case opName
  of "block", "loop":
    result.add(byte(op))
    var startIdx = 1
    # Skip optional $label
    if startIdx < node.childCount and node.children[startIdx].kind == sAtom and
       node.children[startIdx].atom.startsWith("$"):
      inc startIdx
    # Block type
    if startIdx < node.childCount and node.children[startIdx].kind == sList and
       node.children[startIdx].head == "result":
      let vt = node.children[startIdx].children[1].atom
      result.add(valTypeByte(vt))
      inc startIdx
    else:
      result.add(0x40'u8)
    # Body
    var enc2 = FlatEncoder(nodes: node.children[startIdx .. ^1], pos: 0, fi: fi, allFuncs: allFuncs)
    result.add(enc2.encodeSeq())
    result.add(0x0B)

  of "if":
    result.add(0x04)
    var startIdx = 1
    if startIdx < node.childCount and node.children[startIdx].kind == sAtom and
       node.children[startIdx].atom.startsWith("$"):
      inc startIdx
    # Block type
    if startIdx < node.childCount and node.children[startIdx].kind == sList and
       node.children[startIdx].head == "result":
      let vt = node.children[startIdx].children[1].atom
      result.add(valTypeByte(vt))
      inc startIdx
    else:
      result.add(0x40'u8)

    # Find (then ...) and (else ...) children
    var thenStart = -1
    var elseStart = -1
    for i in startIdx ..< node.childCount:
      if node.children[i].kind == sList and node.children[i].head == "then":
        thenStart = i
      elif node.children[i].kind == sList and node.children[i].head == "else":
        elseStart = i

    if thenStart >= 0:
      # Encode condition (children before 'then')
      for i in startIdx ..< thenStart:
        result.add(encodeFoldedInstr(node.children[i], fi, allFuncs))
      # Encode then body
      let thenNode = node.children[thenStart]
      var enc2 = FlatEncoder(nodes: thenNode.children[1 .. ^1], pos: 0, fi: fi, allFuncs: allFuncs)
      result.add(enc2.encodeSeq())
      # Encode else body
      if elseStart >= 0:
        result.add(0x05)
        let elseNode = node.children[elseStart]
        var enc3 = FlatEncoder(nodes: elseNode.children[1 .. ^1], pos: 0, fi: fi, allFuncs: allFuncs)
        result.add(enc3.encodeSeq())
    else:
      # Flat if: encode all children as body
      for i in startIdx ..< node.childCount:
        result.add(encodeFoldedInstr(node.children[i], fi, allFuncs))
    result.add(0x0B)

  of "br", "br_if":
    # Encode operands first (all but last), then br opcode + label
    # Actually in folded form: (br_if labelidx cond) - last is label, rest are operands
    # Or: (br_if cond (br_if_label_last_child))
    # WAT spec: (br_if $l cond) = encode cond, then br_if $l
    # Children: [br_if, labelAtom, ...operands] OR [br_if, ...operands, labelAtom]
    # Standard: (br_if 0 (i32.const 1)) = cond, then br_if 0
    # Hmm, in folded form br_if arg order is: label first, then operands
    # Actually WAT spec folded: (br_if $l cond) where label comes first
    # But in practice: first child after opname is the label index
    var idx = 1
    var labelAtom = ""
    # First arg after opname is the label
    if idx < node.childCount and node.children[idx].kind == sAtom:
      labelAtom = node.children[idx].atom
      inc idx
    # Remaining are operands (encode them first)
    for i in idx ..< node.childCount:
      result.add(encodeFoldedInstr(node.children[i], fi, allFuncs))
    let labelIdx = (try: uint32(parseInt(labelAtom)) except CatchableError: 0'u32)
    result.add(byte(op))
    result.add(leb128U32(labelIdx))

  of "br_table":
    var labels: seq[uint32]
    var operands: seq[SExpr]
    var idx = 1
    while idx < node.childCount:
      let c = node.children[idx]
      if c.kind == sAtom:
        let v = (try: parseInt(c.atom) except CatchableError: -1)
        if v >= 0: labels.add(uint32(v))
        else: operands.add(c)
      else:
        operands.add(c)
      inc idx
    # Encode operands first
    for op2 in operands:
      result.add(encodeFoldedInstr(op2, fi, allFuncs))
    if labels.len > 0:
      let default = labels[^1]
      let targets = labels[0 ..< labels.len - 1]
      result.add(0x0E)
      result.add(leb128U32(uint32(targets.len)))
      for t in targets: result.add(leb128U32(t))
      result.add(leb128U32(default))

  of "call":
    # Encode operands first, then call
    var idx = 1
    var nameAtom = ""
    # First atom is func name
    if idx < node.childCount and node.children[idx].kind == sAtom:
      nameAtom = node.children[idx].atom
      inc idx
    # Rest are operands
    for i in idx ..< node.childCount:
      result.add(encodeFoldedInstr(node.children[i], fi, allFuncs))
    let funcIdx = resolveFunc(nameAtom, allFuncs)
    result.add(0x10)
    result.add(leb128U32(uint32(funcIdx)))

  of "local.get", "local.set", "local.tee":
    var idx = 1
    # Encode operands before the name
    # Actually in folded: (local.set $x val) = val, local.set $x
    # The name comes first, operands after
    var nameAtom = ""
    if idx < node.childCount and node.children[idx].kind == sAtom:
      nameAtom = node.children[idx].atom
      inc idx
    # Remaining are operands
    for i in idx ..< node.childCount:
      result.add(encodeFoldedInstr(node.children[i], fi, allFuncs))
    let localIdx = resolveLocal(nameAtom, fi)
    result.add(byte(op))
    result.add(leb128U32(uint32(localIdx)))

  of "global.get", "global.set":
    var idx = 1
    var nameAtom = ""
    if idx < node.childCount and node.children[idx].kind == sAtom:
      nameAtom = node.children[idx].atom
      inc idx
    for i in idx ..< node.childCount:
      result.add(encodeFoldedInstr(node.children[i], fi, allFuncs))
    let gIdx = (try: uint32(parseInt(nameAtom)) except CatchableError: 0'u32)
    result.add(byte(op))
    result.add(leb128U32(gIdx))

  of "i32.const":
    result.add(0x41)
    let v = parseI32(node.children[1].atom)
    result.add(leb128S32(v))

  of "i64.const":
    result.add(0x42)
    let v = parseI64(node.children[1].atom)
    result.add(leb128S64(v))

  of "f32.const":
    result.add(0x43)
    let v = parseF32(node.children[1].atom)
    let bits = cast[uint32](v)
    result.add(byte(bits and 0xFF))
    result.add(byte((bits shr 8) and 0xFF))
    result.add(byte((bits shr 16) and 0xFF))
    result.add(byte((bits shr 24) and 0xFF))

  of "f64.const":
    result.add(0x44)
    let v = parseF64(node.children[1].atom)
    let bits = cast[uint64](v)
    for i in 0 ..< 8:
      result.add(byte((bits shr (i * 8)) and 0xFF))

  of "memory.size":
    result.add(0x3F); result.add(0x00)

  of "memory.grow":
    # Encode operand
    if node.childCount >= 2:
      result.add(encodeFoldedInstr(node.children[1], fi, allFuncs))
    result.add(0x40); result.add(0x00)

  of "select", "drop", "return":
    # Encode operands
    for i in 1 ..< node.childCount:
      result.add(encodeFoldedInstr(node.children[i], fi, allFuncs))
    result.add(byte(op))

  else:
    if op < 0: return
    if isMemOp(op):
      # Encode operands first, then opcode + memarg
      var idx = 1
      var offset = 0'u32
      var align = defaultMemAlign(op)
      var operands: seq[SExpr]
      while idx < node.childCount:
        let c = node.children[idx]
        if c.kind == sAtom and c.atom.startsWith("offset="):
          offset = uint32(parseInt(c.atom[7 .. ^1]))
        elif c.kind == sAtom and c.atom.startsWith("align="):
          align = uint32(parseInt(c.atom[6 .. ^1]))
        else:
          operands.add(c)
        inc idx
      for op2 in operands:
        result.add(encodeFoldedInstr(op2, fi, allFuncs))
      result.add(byte(op))
      result.add(leb128U32(align))
      result.add(leb128U32(offset))
    else:
      # Generic: encode operands first, then opcode
      for i in 1 ..< node.childCount:
        result.add(encodeFoldedInstr(node.children[i], fi, allFuncs))
      result.add(byte(op))

# ---------------------------------------------------------------------------
# Module structure parsing
# ---------------------------------------------------------------------------

proc parseParams(e: SExpr, fi: var FuncInfo) =
  var idx = 1
  if idx < e.childCount and e.children[idx].kind == sAtom and
     e.children[idx].atom.startsWith("$"):
    fi.paramNames.add(e.children[idx].atom)
    inc idx
    if idx < e.childCount:
      fi.paramTypes.add(valTypeByte(e.children[idx].atom))
  else:
    while idx < e.childCount:
      fi.paramNames.add("")
      fi.paramTypes.add(valTypeByte(e.children[idx].atom))
      inc idx

proc parseFuncNode(funcNode: SExpr): FuncInfo =
  var fi: FuncInfo
  var idx = 1

  if idx < funcNode.childCount and funcNode.children[idx].kind == sAtom and
     funcNode.children[idx].atom.startsWith("$"):
    fi.idName = funcNode.children[idx].atom
    inc idx

  while idx < funcNode.childCount:
    let c = funcNode.children[idx]
    if c.kind == sList:
      let h = c.head
      if h == "export":
        if c.childCount >= 2: fi.name = c.children[1].atom
        inc idx
      elif h == "param":
        parseParams(c, fi)
        inc idx
      elif h == "result":
        var ri = 1
        while ri < c.childCount:
          fi.resultTypes.add(valTypeByte(c.children[ri].atom))
          inc ri
        inc idx
      elif h == "local":
        var li = 1
        if li < c.childCount and c.children[li].kind == sAtom and
           c.children[li].atom.startsWith("$"):
          let lname = c.children[li].atom
          inc li
          if li < c.childCount:
            fi.locals.add((name: lname, t: valTypeByte(c.children[li].atom)))
        else:
          while li < c.childCount:
            fi.locals.add((name: "", t: valTypeByte(c.children[li].atom)))
            inc li
        inc idx
      else:
        break
    else:
      break

  # Collect body nodes
  while idx < funcNode.childCount:
    fi.bodyNodes.add(funcNode.children[idx])
    inc idx

  return fi

proc encodeWatModule*(moduleNode: SExpr): seq[byte] =
  var mb: ModuleBuilder

  var idx = 1
  # Skip optional $name
  if idx < moduleNode.childCount and moduleNode.children[idx].kind == sAtom and
     moduleNode.children[idx].atom.startsWith("$"):
    inc idx

  while idx < moduleNode.childCount:
    let c = moduleNode.children[idx]
    if c.kind == sList:
      case c.head
      of "func":
        mb.funcs.add(parseFuncNode(c))
      of "memory":
        mb.hasMemory = true
        mb.memPages = if c.childCount >= 2: parseInt(c.children[1].atom) else: 0
      else: discard
    inc idx

  # Encode function bodies
  var encodedBodies: seq[seq[byte]]
  for fi in mb.funcs:
    var enc = FlatEncoder(nodes: fi.bodyNodes, pos: 0, fi: fi, allFuncs: mb.funcs)
    encodedBodies.add(enc.encodeSeq())

  # Build WASM binary
  let magic = @[0x00'u8, 0x61, 0x73, 0x6D]
  let version = @[0x01'u8, 0x00, 0x00, 0x00]
  result.add(magic)
  result.add(version)

  # Deduplicate types
  type TypeKey = tuple[params: seq[byte], results: seq[byte]]
  var typeMap: Table[TypeKey, int]
  var types: seq[tuple[params: seq[byte], results: seq[byte]]]
  var funcTypeIdxs: seq[int]

  for fi in mb.funcs:
    let key: TypeKey = (params: fi.paramTypes, results: fi.resultTypes)
    if key notin typeMap:
      typeMap[key] = types.len
      types.add((params: fi.paramTypes, results: fi.resultTypes))
    funcTypeIdxs.add(typeMap[key])

  # Type section (1)
  if types.len > 0:
    var typeContent: seq[byte]
    typeContent.add(leb128U32(uint32(types.len)))
    for t in types:
      typeContent.add(0x60)
      typeContent.add(leb128U32(uint32(t.params.len)))
      typeContent.add(t.params)
      typeContent.add(leb128U32(uint32(t.results.len)))
      typeContent.add(t.results)
    result.add(wasmSection(1, typeContent))

  # Function section (3)
  if mb.funcs.len > 0:
    var funcContent: seq[byte]
    funcContent.add(leb128U32(uint32(mb.funcs.len)))
    for ti in funcTypeIdxs:
      funcContent.add(leb128U32(uint32(ti)))
    result.add(wasmSection(3, funcContent))

  # Memory section (5)
  if mb.hasMemory:
    var memContent: seq[byte]
    memContent.add(leb128U32(1))
    memContent.add(0x00)
    memContent.add(leb128U32(uint32(mb.memPages)))
    result.add(wasmSection(5, memContent))

  # Export section (7)
  var exportPairs: seq[tuple[name: string, funcIdx: int]]
  for i, fi in mb.funcs:
    if fi.name.len > 0:
      exportPairs.add((name: fi.name, funcIdx: i))

  if exportPairs.len > 0:
    var expContent: seq[byte]
    expContent.add(leb128U32(uint32(exportPairs.len)))
    for ep in exportPairs:
      expContent.add(leb128U32(uint32(ep.name.len)))
      for c in ep.name: expContent.add(byte(c))
      expContent.add(0x00)
      expContent.add(leb128U32(uint32(ep.funcIdx)))
    result.add(wasmSection(7, expContent))

  # Code section (10)
  if mb.funcs.len > 0:
    var codeContent: seq[byte]
    codeContent.add(leb128U32(uint32(mb.funcs.len)))
    for i, fi in mb.funcs:
      var body: seq[byte]
      # Locals grouped by type
      var localGroups: seq[tuple[count: int, t: byte]]
      var j = 0
      while j < fi.locals.len:
        var count = 1
        let t = fi.locals[j].t
        while j + count < fi.locals.len and fi.locals[j + count].t == t:
          inc count
        localGroups.add((count: count, t: t))
        j += count
      body.add(leb128U32(uint32(localGroups.len)))
      for lg in localGroups:
        body.add(leb128U32(uint32(lg.count)))
        body.add(lg.t)
      body.add(encodedBodies[i])
      body.add(0x0B)  # end
      codeContent.add(leb128U32(uint32(body.len)))
      codeContent.add(body)
    result.add(wasmSection(10, codeContent))

# ---------------------------------------------------------------------------
# Expected value type for assertion matching
# ---------------------------------------------------------------------------

type
  ExpectedKind = enum
    ekI32, ekI64, ekF32, ekF64, ekNanCanonical32, ekNanCanonical64,
    ekNanArithmetic32, ekNanArithmetic64, ekNan32, ekNan64

  ExpectedVal = object
    case kind: ExpectedKind
    of ekI32: i32: int32
    of ekI64: i64: int64
    of ekF32: f32: float32
    of ekF64: f64: float64
    of ekNanCanonical32, ekNanCanonical64, ekNanArithmetic32, ekNanArithmetic64,
       ekNan32, ekNan64: discard

proc parseExpected(e: SExpr): ExpectedVal =
  let h = e.head
  let valAtom = if e.childCount >= 2: e.children[1].atom else: ""
  case h
  of "i32.const":
    return ExpectedVal(kind: ekI32, i32: parseI32(valAtom))
  of "i64.const":
    return ExpectedVal(kind: ekI64, i64: parseI64(valAtom))
  of "f32.const":
    let s = valAtom
    if s == "nan:canonical": return ExpectedVal(kind: ekNanCanonical32)
    if s == "nan:arithmetic": return ExpectedVal(kind: ekNanArithmetic32)
    if s == "nan" or s == "+nan" or s == "-nan" or s.startsWith("nan:"):
      return ExpectedVal(kind: ekNan32)
    return ExpectedVal(kind: ekF32, f32: parseF32(s))
  of "f64.const":
    let s = valAtom
    if s == "nan:canonical": return ExpectedVal(kind: ekNanCanonical64)
    if s == "nan:arithmetic": return ExpectedVal(kind: ekNanArithmetic64)
    if s == "nan" or s == "+nan" or s == "-nan" or s.startsWith("nan:"):
      return ExpectedVal(kind: ekNan64)
    return ExpectedVal(kind: ekF64, f64: parseF64(s))
  else:
    return ExpectedVal(kind: ekI32, i32: 0)

proc matchExpected(got: WasmValue, exp: ExpectedVal): bool =
  case exp.kind
  of ekI32:
    got.kind == wvkI32 and got.i32 == exp.i32
  of ekI64:
    got.kind == wvkI64 and got.i64 == exp.i64
  of ekF32:
    if got.kind != wvkF32: return false
    cast[uint32](got.f32) == cast[uint32](exp.f32)
  of ekF64:
    if got.kind != wvkF64: return false
    cast[uint64](got.f64) == cast[uint64](exp.f64)
  of ekNanCanonical32:
    if got.kind != wvkF32: return false
    (cast[uint32](got.f32) and 0x7FFFFFFF'u32) == 0x7FC00000'u32
  of ekNanCanonical64:
    if got.kind != wvkF64: return false
    (cast[uint64](got.f64) and 0x7FFFFFFFFFFFFFFF'u64) == 0x7FF8000000000000'u64
  of ekNanArithmetic32:
    got.kind == wvkF32 and isNaN(got.f32)
  of ekNanArithmetic64:
    got.kind == wvkF64 and isNaN(got.f64)
  of ekNan32:
    got.kind == wvkF32 and isNaN(got.f32)
  of ekNan64:
    got.kind == wvkF64 and isNaN(got.f64)

proc parseArg(e: SExpr): WasmValue =
  let h = e.head
  let valAtom = if e.childCount >= 2: e.children[1].atom else: "0"
  case h
  of "i32.const": wasmI32(parseI32(valAtom))
  of "i64.const": wasmI64(parseI64(valAtom))
  of "f32.const": wasmF32(parseF32(valAtom))
  of "f64.const": wasmF64(parseF64(valAtom))
  else: wasmI32(0)

# ---------------------------------------------------------------------------
# WAST runner
# ---------------------------------------------------------------------------

type
  WastRunner* = object
    vm: WasmVM
    moduleIdx: int
    hasModule: bool
    currentModuleBytes: seq[byte]  # for VM reset after traps
    currentModule: WasmModule      # kept alive so FuncInst.code ptrs remain valid

proc initWastRunner*(): WastRunner =
  result.vm = initWasmVM()
  result.moduleIdx = -1
  result.hasModule = false

proc loadModuleFromSExpr(runner: var WastRunner, moduleNode: SExpr) =
  let bytes = encodeWatModule(moduleNode)
  runner.currentModuleBytes = bytes
  runner.currentModule = decodeModule(bytes)
  runner.vm = initWasmVM()
  runner.moduleIdx = runner.vm.instantiate(runner.currentModule, [])
  runner.hasModule = true

proc resetVMAfterTrap(runner: var WastRunner) =
  ## Re-initialize VM after a WasmTrap to restore clean stack state
  if runner.currentModuleBytes.len == 0: return
  runner.currentModule = decodeModule(runner.currentModuleBytes)
  runner.vm = initWasmVM()
  runner.moduleIdx = runner.vm.instantiate(runner.currentModule, [])

proc runWastString*(src: string, verbose = false): tuple[passed, failed: int] =
  var runner = initWastRunner()
  let exprs = parseSExprs(src)
  var passed = 0
  var failed = 0

  for expr in exprs:
    if expr.kind != sList or expr.childCount == 0: continue
    let h = expr.head

    case h
    of "module":
      try:
        runner.loadModuleFromSExpr(expr)
      except CatchableError as e:
        echo "ERROR loading module: " & e.msg
        inc failed

    of "assert_return":
      if expr.childCount < 2: continue
      let invokeNode = expr.children[1]
      if invokeNode.kind != sList or invokeNode.head != "invoke": continue

      let funcName = invokeNode.children[1].atom
      var args: seq[WasmValue]
      for i in 2 ..< invokeNode.childCount:
        args.add(parseArg(invokeNode.children[i]))

      var expected: seq[ExpectedVal]
      for i in 2 ..< expr.childCount:
        expected.add(parseExpected(expr.children[i]))

      try:
        let results = runner.vm.invoke(runner.moduleIdx, funcName, args)
        var ok = true
        if expected.len == 0 and results.len == 0:
          discard
        elif results.len != expected.len:
          ok = false
          if verbose:
            echo "FAIL assert_return " & funcName & ": got " & $results.len &
                 " results, expected " & $expected.len
        else:
          for i in 0 ..< expected.len:
            if not matchExpected(results[i], expected[i]):
              ok = false
              if verbose:
                echo "FAIL assert_return " & funcName & " result[" & $i & "]: got " &
                     $results[i] & " expected " & $expected[i]
              break
        if ok:
          inc passed
          if verbose: echo "PASS assert_return " & funcName
        else:
          inc failed
      except WasmTrap as e:
        inc failed
        if verbose: echo "FAIL assert_return " & funcName & " trapped: " & e.msg
        runner.resetVMAfterTrap()
      except CatchableError as e:
        inc failed
        if verbose: echo "FAIL assert_return " & funcName & " error: " & e.msg

    of "assert_trap":
      if expr.childCount < 2: continue
      let invokeNode = expr.children[1]
      if invokeNode.kind != sList or invokeNode.head != "invoke": continue

      let funcName = invokeNode.children[1].atom
      var args: seq[WasmValue]
      for i in 2 ..< invokeNode.childCount:
        args.add(parseArg(invokeNode.children[i]))

      try:
        discard runner.vm.invoke(runner.moduleIdx, funcName, args)
        inc failed
        if verbose: echo "FAIL assert_trap " & funcName & ": expected trap but returned"
      except WasmTrap:
        inc passed
        if verbose: echo "PASS assert_trap " & funcName
        runner.resetVMAfterTrap()
      except CatchableError as e:
        inc failed
        if verbose: echo "FAIL assert_trap " & funcName & " unexpected error: " & e.msg
        runner.resetVMAfterTrap()

    of "assert_invalid", "assert_malformed", "assert_exhaustion",
       "assert_unlinkable":
      discard

    of "invoke":
      if not runner.hasModule: continue
      let funcName = expr.children[1].atom
      var args: seq[WasmValue]
      for i in 2 ..< expr.childCount:
        args.add(parseArg(expr.children[i]))
      try:
        discard runner.vm.invoke(runner.moduleIdx, funcName, args)
      except CatchableError as e:
        if verbose: echo "invoke error: " & e.msg

    else:
      discard

  return (passed: passed, failed: failed)

proc runWastFile*(path: string, verbose = false): tuple[passed, failed: int] =
  let src = readFile(path)
  result = runWastString(src, verbose)
