## Tests for bencode encoder/decoder.

import std/strutils
import cps/bittorrent/bencode

# Integer encoding/decoding
block testIntEncodeDecode:
  assert encode(bInt(42)) == "i42e"
  assert encode(bInt(0)) == "i0e"
  assert encode(bInt(-5)) == "i-5e"
  assert encode(bInt(1234567890)) == "i1234567890e"

  let v1 = decode("i42e")
  assert v1.kind == bkInt
  assert v1.intVal == 42

  let v2 = decode("i0e")
  assert v2.kind == bkInt
  assert v2.intVal == 0

  let v3 = decode("i-5e")
  assert v3.kind == bkInt
  assert v3.intVal == -5

  echo "PASS: integer encode/decode"

# String encoding/decoding
block testStrEncodeDecode:
  assert encode(bStr("hello")) == "5:hello"
  assert encode(bStr("")) == "0:"
  assert encode(bStr("spam")) == "4:spam"

  let v1 = decode("5:hello")
  assert v1.kind == bkStr
  assert v1.strVal == "hello"

  let v2 = decode("0:")
  assert v2.kind == bkStr
  assert v2.strVal == ""

  echo "PASS: string encode/decode"

# Binary string (arbitrary bytes)
block testBinaryStr:
  var binaryData = ""
  for i in 0 ..< 20:
    binaryData.add(char(i))
  let encoded = encode(bStr(binaryData))
  assert encoded.startsWith("20:")
  let decoded = decode(encoded)
  assert decoded.strVal == binaryData
  echo "PASS: binary string encode/decode"

# List encoding/decoding
block testListEncodeDecode:
  let list = bList(bStr("spam"), bStr("eggs"))
  assert encode(list) == "l4:spam4:eggse"

  let decoded = decode("l4:spam4:eggse")
  assert decoded.kind == bkList
  assert decoded.listVal.len == 2
  assert decoded.listVal[0].strVal == "spam"
  assert decoded.listVal[1].strVal == "eggs"

  # Nested list
  let nested = bList(bList(bInt(1), bInt(2)), bStr("hello"))
  let enc = encode(nested)
  let dec = decode(enc)
  assert dec.kind == bkList
  assert dec.listVal[0].kind == bkList
  assert dec.listVal[0].listVal[0].intVal == 1

  # Empty list
  assert encode(bList()) == "le"
  let emptyList = decode("le")
  assert emptyList.kind == bkList
  assert emptyList.listVal.len == 0

  echo "PASS: list encode/decode"

# Dictionary encoding/decoding
block testDictEncodeDecode:
  let dict = bDict()
  dict["cow"] = bStr("moo")
  dict["spam"] = bStr("eggs")

  # Keys must be sorted in encoding
  let encoded = encode(dict)
  assert encoded == "d3:cow3:moo4:spam4:eggse"

  let decoded = decode("d3:cow3:moo4:spam4:eggse")
  assert decoded.kind == bkDict
  assert decoded["cow"].strVal == "moo"
  assert decoded["spam"].strVal == "eggs"

  # Nested dict
  let outer = bDict()
  let inner = bDict()
  inner["key"] = bInt(42)
  outer["nested"] = inner
  let enc = encode(outer)
  let dec = decode(enc)
  assert dec["nested"]["key"].intVal == 42

  echo "PASS: dictionary encode/decode"

# Key sorting
block testDictKeySorting:
  let dict = bDict()
  dict["z"] = bInt(1)
  dict["a"] = bInt(2)
  dict["m"] = bInt(3)
  let encoded = encode(dict)
  # Keys should be sorted: a, m, z
  assert encoded == "d1:ai2e1:mi3e1:zi1ee"
  echo "PASS: dictionary key sorting"

# Round-trip encoding
block testRoundTrip:
  let complex = bDict()
  complex["announce"] = bStr("http://tracker.example.com/announce")
  let info = bDict()
  info["name"] = bStr("test.txt")
  info["piece length"] = bInt(262144)
  info["length"] = bInt(1048576)
  info["pieces"] = bStr("01234567890123456789")  # 20 bytes
  complex["info"] = info

  let encoded = encode(complex)
  let decoded = decode(encoded)
  let reencoded = encode(decoded)
  assert encoded == reencoded
  echo "PASS: round-trip encoding"

# Error handling
block testDecodeErrors:
  var caught = false
  try:
    discard decode("i03e")  # Leading zero
  except BencodeError:
    caught = true
  assert caught, "should reject leading zeros"

  caught = false
  try:
    discard decode("i-0e")  # Negative zero
  except BencodeError:
    caught = true
  assert caught, "should reject negative zero"

  caught = false
  try:
    discard decode("ie")  # Empty integer
  except BencodeError:
    caught = true
  assert caught, "should reject empty integer"

  caught = false
  try:
    discard decode("5:hi")  # Short string
  except BencodeError:
    caught = true
  assert caught, "should reject short string"

  caught = false
  try:
    discard decode("i42eXXX")  # Trailing data
  except BencodeError:
    caught = true
  assert caught, "should reject trailing data"

  echo "PASS: decode error handling"

# extractRawValue
block testExtractRawValue:
  let dict = bDict()
  dict["announce"] = bStr("http://example.com")
  let info = bDict()
  info["name"] = bStr("test")
  info["length"] = bInt(100)
  dict["info"] = info

  let encoded = encode(dict)
  let rawInfo = extractRawValue(encoded, "info")
  # rawInfo should be the bencoded info dict
  let parsedInfo = decode(rawInfo)
  assert parsedInfo["name"].strVal == "test"
  assert parsedInfo["length"].intVal == 100
  echo "PASS: extractRawValue"

# Partial decode
block testDecodePartial:
  let data = "i42e4:spam"
  let (val, endPos) = decodePartial(data, 0)
  assert val.intVal == 42
  assert endPos == 4
  let (val2, endPos2) = decodePartial(data, 4)
  assert val2.strVal == "spam"
  assert endPos2 == data.len
  echo "PASS: partial decode"

# contains and getOrDefault
block testDictHelpers:
  let d = bDict()
  d["foo"] = bInt(1)
  assert "foo" in d
  assert "bar" notin d
  assert d.getOrDefault("foo") != nil
  assert d.getOrDefault("bar") == nil
  echo "PASS: dict helpers"

echo "ALL BENCODE TESTS PASSED"
