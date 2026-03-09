## Bencode encoder/decoder for BitTorrent protocol.
##
## Bencode supports four data types:
## - Integers: i42e
## - Byte strings: 5:hello
## - Lists: l...e
## - Dictionaries: d...e (keys must be byte strings, sorted)

import std/[tables, algorithm, strutils, hashes]

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
  if d.kind == bkDict and key in d.dictVal:
    d.dictVal[key]
  else:
    nil

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
    var first = true
    for k, val in v.dictVal:
      if not first: s.add(", ")
      first = false
      s.add("\"" & k & "\": " & $val)
    s.add("}")
    s

# Encoder
proc encode*(v: BencodeValue): string =
  case v.kind
  of bkInt:
    result = "i" & $v.intVal & "e"
  of bkStr:
    result = $v.strVal.len & ":" & v.strVal
  of bkList:
    result = "l"
    for item in v.listVal:
      result.add(encode(item))
    result.add("e")
  of bkDict:
    # Keys must be sorted
    var keys: seq[string]
    for k in v.dictVal.keys:
      keys.add(k)
    keys.sort()
    result = "d"
    for k in keys:
      result.add($k.len & ":" & k)
      result.add(encode(v.dictVal[k]))
    result.add("e")

# Decoder
type
  BencodeParser = object
    data: string
    pos: int

proc peek(p: BencodeParser): char =
  if p.pos >= p.data.len:
    raise newException(BencodeError, "unexpected end of data")
  p.data[p.pos]

proc advance(p: var BencodeParser) =
  inc p.pos

proc expect(p: var BencodeParser, c: char) =
  if p.pos >= p.data.len or p.data[p.pos] != c:
    raise newException(BencodeError, "expected '" & $c & "' at pos " & $p.pos)
  inc p.pos

proc parseValue(p: var BencodeParser): BencodeValue

proc parseInt(p: var BencodeParser): BencodeValue =
  p.expect('i')
  var numStr = ""
  while p.pos < p.data.len and p.data[p.pos] != 'e':
    numStr.add(p.data[p.pos])
    inc p.pos
  p.expect('e')
  if numStr.len == 0:
    raise newException(BencodeError, "empty integer")
  # Leading zeros are not allowed (except i0e)
  if numStr.len > 1 and numStr[0] == '0':
    raise newException(BencodeError, "leading zero in integer")
  if numStr.len > 1 and numStr[0] == '-' and numStr[1] == '0':
    raise newException(BencodeError, "negative zero in integer")
  result = bInt(parseBiggestInt(numStr))

proc parseStr(p: var BencodeParser): BencodeValue =
  var lenStr = ""
  while p.pos < p.data.len and p.data[p.pos] != ':':
    lenStr.add(p.data[p.pos])
    inc p.pos
  p.expect(':')
  let strLen = parseInt(lenStr)
  if strLen < 0:
    raise newException(BencodeError, "negative string length")
  if p.pos + strLen > p.data.len:
    raise newException(BencodeError, "string length exceeds data")
  result = bStr(p.data[p.pos ..< p.pos + strLen])
  p.pos += strLen

proc parseList(p: var BencodeParser): BencodeValue =
  p.expect('l')
  result = BencodeValue(kind: bkList, listVal: @[])
  while p.peek() != 'e':
    result.listVal.add(parseValue(p))
  p.expect('e')

proc parseDict(p: var BencodeParser): BencodeValue =
  p.expect('d')
  result = bDict()
  while p.peek() != 'e':
    let key = parseStr(p)
    let val = parseValue(p)
    result.dictVal[key.strVal] = val
  p.expect('e')

proc parseValue(p: var BencodeParser): BencodeValue =
  let c = p.peek()
  case c
  of 'i': result = parseInt(p)
  of 'l': result = parseList(p)
  of 'd': result = parseDict(p)
  of '0'..'9': result = parseStr(p)
  else:
    raise newException(BencodeError, "unexpected character '" & $c & "' at pos " & $p.pos)

proc decode*(data: string): BencodeValue =
  var p = BencodeParser(data: data, pos: 0)
  result = parseValue(p)
  if p.pos != data.len:
    raise newException(BencodeError, "trailing data at pos " & $p.pos)

proc decodePartial*(data: string, startPos: int = 0): tuple[value: BencodeValue, endPos: int] =
  ## Decode a bencode value starting at startPos, returning value and end position.
  var p = BencodeParser(data: data, pos: startPos)
  result.value = parseValue(p)
  result.endPos = p.pos

# Extract raw bytes for a dict key (used for info hash computation)
proc extractRawValue*(data: string, key: string): string =
  ## Find a top-level dict key and return the raw bencoded bytes of its value.
  ## Used to extract the raw "info" dict for SHA1 hashing.
  var p = BencodeParser(data: data, pos: 0)
  if p.peek() != 'd':
    raise newException(BencodeError, "not a dictionary")
  p.advance()
  while p.peek() != 'e':
    let k = parseStr(p)
    let valStart = p.pos
    discard parseValue(p)
    let valEnd = p.pos
    if k.strVal == key:
      return data[valStart ..< valEnd]
  raise newException(BencodeError, "key not found: " & key)
