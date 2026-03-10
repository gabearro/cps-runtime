## Bencode encoder/decoder for BitTorrent protocol.
##
## Bencode supports four data types:
## - Integers: i42e
## - Byte strings: 5:hello
## - Lists: l...e
## - Dictionaries: d...e (keys must be byte strings, sorted)

import std/[tables, algorithm, strutils, sequtils]

const
  MaxDecodeDepth = 512 ## Maximum nesting depth for decode (prevents stack overflow on untrusted input)

type
  BencodeKind* = enum
    bkInt
    bkStr
    bkList
    bkDict

  BencodeValue* = ref object
    case kind*: BencodeKind
    of bkInt:
      intVal*: int64
    of bkStr:
      strVal*: string
    of bkList:
      listVal*: seq[BencodeValue]
    of bkDict:
      dictVal*: OrderedTable[string, BencodeValue]

  BencodeError* = object of CatchableError

# Constructors
proc bInt*(v: int64): BencodeValue =
  BencodeValue(kind: bkInt, intVal: v)

proc bStr*(v: string): BencodeValue =
  BencodeValue(kind: bkStr, strVal: v)

proc bList*(items: varargs[BencodeValue]): BencodeValue =
  BencodeValue(kind: bkList, listVal: @items)

proc bDict*(): BencodeValue =
  BencodeValue(kind: bkDict, dictVal: initOrderedTable[string, BencodeValue]())

proc bDict*(t: Table[string, BencodeValue]): BencodeValue =
  var ot = initOrderedTable[string, BencodeValue]()
  for k, v in t:
    ot[k] = v
  BencodeValue(kind: bkDict, dictVal: ot)

iterator dictKeys*(d: BencodeValue): string =
  ## Iterate over dictionary keys.
  assert d.kind == bkDict
  for k in d.dictVal.keys:
    yield k

proc `[]=`*(d: BencodeValue, key: string, val: BencodeValue) =
  assert d.kind == bkDict
  d.dictVal[key] = val

proc `[]`*(d: BencodeValue, key: string): BencodeValue =
  assert d.kind == bkDict
  d.dictVal[key]

proc contains*(d: BencodeValue, key: string): bool =
  d.kind == bkDict and key in d.dictVal

proc getOrDefault*(d: BencodeValue, key: string): BencodeValue =
  if d.kind == bkDict:
    d.dictVal.getOrDefault(key)
  else:
    nil

# Require/opt helpers — shared error formatting
proc raiseFieldError(key: string, context: string) {.noreturn, noinline.} =
  let ctx = if context.len > 0: " in " & context else: ""
  raise newException(BencodeError, "missing '" & key & "'" & ctx)

template requireField(d: BencodeValue, key: string, context: string,
                      expectedKind: BencodeKind, field: untyped): untyped =
  let node = d.getOrDefault(key)
  if node == nil or node.kind != expectedKind:
    raiseFieldError(key, context)
  node.field

proc requireStr*(d: BencodeValue, key: string, context: string = ""): string =
  ## Get a required string field, raising BencodeError if missing or wrong type.
  requireField(d, key, context, bkStr, strVal)

proc requireInt*(d: BencodeValue, key: string, context: string = ""): int64 =
  ## Get a required integer field, raising BencodeError if missing or wrong type.
  requireField(d, key, context, bkInt, intVal)

proc requireDict*(d: BencodeValue, key: string, context: string = ""): BencodeValue =
  ## Get a required dict field, raising BencodeError if missing or wrong type.
  let node = d.getOrDefault(key)
  if node == nil or node.kind != bkDict:
    raiseFieldError(key, context)
  node

proc optStr*(d: BencodeValue, key: string): string =
  ## Get an optional string field, returning "" if missing.
  let node = d.getOrDefault(key)
  if node != nil and node.kind == bkStr: node.strVal else: ""

proc optInt*(d: BencodeValue, key: string): int64 =
  ## Get an optional integer field, returning 0 if missing.
  let node = d.getOrDefault(key)
  if node != nil and node.kind == bkInt: node.intVal else: 0

proc optStrList*(d: BencodeValue, key: string): seq[string] =
  ## Get an optional list-of-strings field. Also accepts a single string.
  let node = d.getOrDefault(key)
  if node == nil: return @[]
  case node.kind
  of bkStr: return @[node.strVal]
  of bkList:
    for item in node.listVal:
      if item.kind == bkStr:
        result.add(item.strVal)
  else: discard

proc len*(v: BencodeValue): int =
  case v.kind
  of bkStr: v.strVal.len
  of bkList: v.listVal.len
  of bkDict: v.dictVal.len
  of bkInt: 0

proc `$`*(v: BencodeValue): string =
  case v.kind
  of bkInt: "i(" & $v.intVal & ")"
  of bkStr:
    if v.strVal.len <= 40:
      "s(\"" & v.strVal & "\")"
    else:
      "s(\"" & v.strVal[0..39] & "...\" len=" & $v.strVal.len & ")"
  of bkList:
    var s = "["
    for i, item in v.listVal:
      if i > 0: s.add(", ")
      s.add($item)
    s.add("]")
    s
  of bkDict:
    var s = "{"
    var i = 0
    for k, val in v.dictVal:
      if i > 0: s.add(", ")
      s.add("\"" & k & "\": " & $val)
      inc i
    s.add("}")
    s

# Encoder
proc encodeInto*(v: BencodeValue, result: var string) =
  ## Encode a BencodeValue, appending to `result`. Zero intermediate allocations.
  case v.kind
  of bkInt:
    result.add('i')
    result.add($v.intVal)
    result.add('e')
  of bkStr:
    result.add($v.strVal.len)
    result.add(':')
    result.add(v.strVal)
  of bkList:
    result.add('l')
    for item in v.listVal:
      encodeInto(item, result)
    result.add('e')
  of bkDict:
    var keys = toSeq(v.dictVal.keys)
    keys.sort()
    result.add('d')
    for k in keys:
      result.add($k.len)
      result.add(':')
      result.add(k)
      encodeInto(v.dictVal[k], result)
    result.add('e')

proc encode*(v: BencodeValue): string =
  encodeInto(v, result)

# Decoder
type
  BencodeParser = object
    data: ptr UncheckedArray[char]
    len: int
    pos: int
    depth: int

template atEnd(p: BencodeParser): bool =
  p.pos >= p.len

proc peek(p: BencodeParser): char {.inline.} =
  if p.atEnd:
    raise newException(BencodeError, "unexpected end of data")
  p.data[p.pos]

proc expect(p: var BencodeParser, c: char) {.inline.} =
  if p.atEnd or p.data[p.pos] != c:
    raise newException(BencodeError, "expected '" & $c & "' at pos " & $p.pos)
  inc p.pos

proc enterNested(p: var BencodeParser) {.inline.} =
  inc p.depth
  if p.depth > MaxDecodeDepth:
    raise newException(BencodeError, "maximum nesting depth exceeded at pos " & $p.pos)

proc leaveNested(p: var BencodeParser) {.inline.} =
  dec p.depth

proc parseValue(p: var BencodeParser): BencodeValue

proc parseInt(p: var BencodeParser): BencodeValue =
  p.expect('i')
  let start = p.pos
  while not p.atEnd and p.data[p.pos] != 'e':
    inc p.pos
  let numLen = p.pos - start
  let numStr = block:
    var s = newString(numLen)
    if numLen > 0:
      copyMem(addr s[0], addr p.data[start], numLen)
    s
  p.expect('e')
  if numStr.len == 0:
    raise newException(BencodeError, "empty integer")
  if numStr.len > 1 and numStr[0] == '0':
    raise newException(BencodeError, "leading zero in integer")
  if numStr.len > 1 and numStr[0] == '-' and numStr[1] == '0':
    raise newException(BencodeError, "negative zero in integer")
  bInt(parseBiggestInt(numStr))

proc parseRawStr(p: var BencodeParser): string =
  ## Parse a bencode string, returning the raw string value without BencodeValue allocation.
  let start = p.pos
  while not p.atEnd and p.data[p.pos] != ':':
    inc p.pos
  let lenStr = block:
    var s = newString(p.pos - start)
    if s.len > 0:
      copyMem(addr s[0], addr p.data[start], p.pos - start)
    s
  p.expect(':')
  let strLen = parseInt(lenStr)
  if strLen < 0:
    raise newException(BencodeError, "negative string length")
  if p.pos + strLen > p.len:
    raise newException(BencodeError, "string length exceeds data")
  result = newString(strLen)
  if strLen > 0:
    copyMem(addr result[0], addr p.data[p.pos], strLen)
  p.pos += strLen

proc parseStr(p: var BencodeParser): BencodeValue =
  bStr(parseRawStr(p))

proc parseList(p: var BencodeParser): BencodeValue =
  p.expect('l')
  p.enterNested()
  result = BencodeValue(kind: bkList, listVal: @[])
  while p.peek() != 'e':
    result.listVal.add(parseValue(p))
  p.expect('e')
  p.leaveNested()

proc parseDict(p: var BencodeParser): BencodeValue =
  p.expect('d')
  p.enterNested()
  result = bDict()
  while p.peek() != 'e':
    let key = parseRawStr(p)
    let val = parseValue(p)
    result.dictVal[key] = val
  p.expect('e')
  p.leaveNested()

proc parseValue(p: var BencodeParser): BencodeValue =
  let c = p.peek()
  case c
  of 'i': parseInt(p)
  of 'l': parseList(p)
  of 'd': parseDict(p)
  of '0'..'9': parseStr(p)
  else:
    raise newException(BencodeError, "unexpected character '" & $c & "' at pos " & $p.pos)

proc initParser(data: string, startPos: int = 0): BencodeParser =
  if data.len == 0:
    BencodeParser(data: nil, len: 0, pos: startPos, depth: 0)
  else:
    BencodeParser(
      data: cast[ptr UncheckedArray[char]](unsafeAddr data[0]),
      len: data.len,
      pos: startPos,
      depth: 0
    )

proc decode*(data: string): BencodeValue =
  var p = initParser(data)
  result = parseValue(p)
  if p.pos != p.len:
    raise newException(BencodeError, "trailing data at pos " & $p.pos)

proc decodePartial*(data: string, startPos: int = 0): tuple[value: BencodeValue, endPos: int] =
  ## Decode a bencode value starting at startPos, returning value and end position.
  var p = initParser(data, startPos)
  result.value = parseValue(p)
  result.endPos = p.pos

# Extract raw bytes for a dict key (used for info hash computation)
proc extractRawValue*(data: string, key: string): string =
  ## Find a top-level dict key and return the raw bencoded bytes of its value.
  ## Used to extract the raw "info" dict for SHA1 hashing.
  var p = initParser(data)
  if p.peek() != 'd':
    raise newException(BencodeError, "not a dictionary")
  inc p.pos
  while p.peek() != 'e':
    let k = parseRawStr(p)
    let valStart = p.pos
    discard parseValue(p)
    let valEnd = p.pos
    if k == key:
      return data[valStart ..< valEnd]
  raise newException(BencodeError, "key not found: " & key)
