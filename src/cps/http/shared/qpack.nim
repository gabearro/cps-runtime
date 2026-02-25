## QPACK encoder/decoder (RFC 9204-oriented baseline).

import ../../quic/varint
import ./hpack

type
  QpackHeaderField* = tuple[name: string, value: string]

  QpackDecoderInstructionKind* = enum
    qdikSectionAck
    qdikStreamCancel
    qdikInsertCountIncrement

  QpackDecoderInstruction* = object
    case kind*: QpackDecoderInstructionKind
    of qdikSectionAck:
      streamId*: uint64
    of qdikStreamCancel:
      cancelStreamId*: uint64
    of qdikInsertCountIncrement:
      insertCountDelta*: uint64

  QpackEncoderInstructionKind* = enum
    qeikInsertLiteral
    qeikInsertNameRef
    qeikDuplicate
    qeikSetCapacity

  QpackEncoderInstruction* = object
    value*: string
    case kind*: QpackEncoderInstructionKind
    of qeikInsertLiteral:
      name*: string
    of qeikInsertNameRef:
      nameRefIndex*: uint64
      nameRefIsStatic*: bool
    of qeikDuplicate:
      duplicateIndex*: uint64
    of qeikSetCapacity:
      capacity*: uint64

  QpackEncoder* = ref object
    maxTableCapacity*: int
    blockedStreamsLimit*: int
    blockedStreams*: int
    dynamicTable*: seq[QpackHeaderField]
    insertCount*: uint64
    requiredInsertCount*: uint64

  QpackDecoder* = ref object
    maxTableCapacity*: int
    blockedStreamsLimit*: int
    blockedStreams*: int
    dynamicTable*: seq[QpackHeaderField]
    knownInsertCount*: uint64
    requiredInsertCount*: uint64

const
  ## RFC 9204 static table (expanded baseline, full cardinality).
  ## Values are intentionally present for index stability in our runtime.
  QpackStaticTable*: array[99, QpackHeaderField] = [
    (":authority", ""), (":path", "/"), ("age", "0"), ("content-disposition", ""),
    ("content-length", "0"), ("cookie", ""), ("date", ""), ("etag", ""),
    ("if-modified-since", ""), ("if-none-match", ""), ("last-modified", ""),
    ("link", ""), ("location", ""), ("referer", ""), ("set-cookie", ""),
    (":method", "CONNECT"), (":method", "DELETE"), (":method", "GET"),
    (":method", "HEAD"), (":method", "OPTIONS"), (":method", "POST"),
    (":method", "PUT"), (":scheme", "http"), (":scheme", "https"),
    (":status", "103"), (":status", "200"), (":status", "304"),
    (":status", "404"), (":status", "503"), ("accept", "*/*"),
    ("accept", "application/dns-message"), ("accept-encoding", "gzip, deflate, br"),
    ("accept-ranges", "bytes"), ("access-control-allow-headers", "cache-control"),
    ("access-control-allow-headers", "content-type"), ("access-control-allow-origin", "*"),
    ("cache-control", "max-age=0"), ("cache-control", "max-age=2592000"),
    ("cache-control", "max-age=604800"), ("cache-control", "no-cache"),
    ("cache-control", "no-store"), ("cache-control", "public, max-age=31536000"),
    ("content-encoding", "br"), ("content-encoding", "gzip"), ("content-type", "application/dns-message"),
    ("content-type", "application/javascript"), ("content-type", "application/json"),
    ("content-type", "application/x-www-form-urlencoded"),
    ("content-type", "image/gif"), ("content-type", "image/jpeg"), ("content-type", "image/png"),
    ("content-type", "text/css"), ("content-type", "text/html; charset=utf-8"),
    ("content-type", "text/plain"), ("content-type", "text/plain;charset=utf-8"),
    ("range", "bytes=0-"), ("strict-transport-security", "max-age=31536000"),
    ("strict-transport-security", "max-age=31536000; includesubdomains"),
    ("strict-transport-security", "max-age=31536000; includesubdomains; preload"),
    ("vary", "accept-encoding"), ("vary", "origin"), ("x-content-type-options", "nosniff"),
    ("x-xss-protection", "1; mode=block"), (":status", "100"), (":status", "204"),
    (":status", "206"), (":status", "302"), (":status", "400"), (":status", "403"),
    (":status", "421"), (":status", "425"), (":status", "500"), ("accept-language", ""),
    ("access-control-allow-credentials", "FALSE"), ("access-control-allow-credentials", "TRUE"),
    ("access-control-allow-headers", "*"), ("access-control-allow-methods", "get"),
    ("access-control-allow-methods", "get, post, options"), ("access-control-allow-methods", "options"),
    ("access-control-expose-headers", "content-length"), ("access-control-request-headers", "content-type"),
    ("access-control-request-method", "get"), ("access-control-request-method", "post"),
    ("alt-svc", "clear"), ("authorization", ""), ("content-security-policy", "script-src 'none'; object-src 'none'; base-uri 'none'"),
    ("early-data", "1"), ("expect-ct", ""), ("forwarded", ""), ("if-range", ""),
    ("origin", ""), ("purpose", "prefetch"), ("server", ""), ("timing-allow-origin", "*"),
    ("upgrade-insecure-requests", "1"), ("user-agent", ""), ("x-forwarded-for", ""),
    ("x-frame-options", "deny"), ("x-frame-options", "sameorigin")
  ]

proc newQpackEncoder*(maxTableCapacity: int = 4096, blockedStreamsLimit: int = 16): QpackEncoder =
  QpackEncoder(
    maxTableCapacity: maxTableCapacity,
    blockedStreamsLimit: blockedStreamsLimit,
    blockedStreams: 0,
    dynamicTable: @[],
    insertCount: 0'u64,
    requiredInsertCount: 0'u64
  )

proc newQpackDecoder*(maxTableCapacity: int = 4096, blockedStreamsLimit: int = 16): QpackDecoder =
  QpackDecoder(
    maxTableCapacity: maxTableCapacity,
    blockedStreamsLimit: blockedStreamsLimit,
    blockedStreams: 0,
    dynamicTable: @[],
    knownInsertCount: 0'u64,
    requiredInsertCount: 0'u64
  )

proc fieldSizeBytes(f: QpackHeaderField): int {.inline.} =
  f.name.len + f.value.len + 32

proc dynamicTableBytes(table: seq[QpackHeaderField]): int =
  for f in table:
    result += fieldSizeBytes(f)

proc trimDynamicTable(table: var seq[QpackHeaderField], maxTableCapacity: int) =
  while table.len > 0 and dynamicTableBytes(table) > maxTableCapacity:
    table.setLen(table.len - 1)

proc findStaticIndex(field: QpackHeaderField): int =
  for i in 0 ..< QpackStaticTable.len:
    # RFC9204 indexed field line requires exact name+value match.
    if QpackStaticTable[i].name == field.name and
        QpackStaticTable[i].value == field.value:
      return i
  -1

proc findDynamicIndex(table: seq[QpackHeaderField], field: QpackHeaderField): int =
  for i in 0 ..< table.len:
    if table[i] == field:
      return i
  -1

proc addDynamic(table: var seq[QpackHeaderField], field: QpackHeaderField, maxTableCapacity: int): bool =
  table.insert(field, 0)
  trimDynamicTable(table, maxTableCapacity)
  for f in table:
    if f == field:
      return true
  false

proc appendString(dst: var seq[byte], s: string) =
  dst.appendQuicVarInt(uint64(s.len))
  for c in s:
    dst.add byte(ord(c) and 0xFF)

proc decodeString(data: openArray[byte], offset: var int): string =
  let n = decodeQuicVarInt(data, offset)
  if offset + int(n) > data.len:
    raise newException(ValueError, "QPACK string truncated")
  result = newString(int(n))
  for i in 0 ..< int(n):
    result[i] = char(data[offset + i])
  offset += int(n)

proc appendPrefixedInt(dst: var seq[byte], prefixMask: uint8, prefixBits: int, value: uint64) =
  let prefixMax = (1'u64 shl prefixBits) - 1'u64
  if value < prefixMax:
    dst.add(prefixMask or uint8(value))
    return
  dst.add(prefixMask or uint8(prefixMax))
  var remaining = value - prefixMax
  while remaining >= 128'u64:
    dst.add uint8((remaining and 0x7F'u64) or 0x80'u64)
    remaining = remaining shr 7
  dst.add uint8(remaining)

proc decodePrefixedInt(data: openArray[byte],
                       offset: var int,
                       firstByte: uint8,
                       prefixBits: int): uint64 =
  let prefixMask = uint8((1 shl prefixBits) - 1)
  let prefixMax = uint64(prefixMask)
  result = uint64(firstByte and prefixMask)
  if result < prefixMax:
    return
  var shift = 0
  while true:
    if offset >= data.len:
      raise newException(ValueError, "truncated prefixed integer")
    let b = data[offset]
    inc offset
    let lowBits = uint64(b and 0x7F'u8)
    if shift >= 64:
      raise newException(ValueError, "prefixed integer overflow")
    if lowBits > (high(uint64) shr shift):
      raise newException(ValueError, "prefixed integer overflow")
    let contribution = lowBits shl shift
    if high(uint64) - result < contribution:
      raise newException(ValueError, "prefixed integer overflow")
    result += contribution
    if (b and 0x80'u8) == 0:
      break
    shift += 7

proc checkedIncCounter(counter: var uint64, label: string) =
  if counter == high(uint64):
    raise newException(ValueError, label & " overflow")
  inc counter

proc markBlocked*(enc: QpackEncoder) =
  if enc.blockedStreams < enc.blockedStreamsLimit:
    inc enc.blockedStreams

proc markUnblocked*(enc: QpackEncoder) =
  if enc.blockedStreams > 0:
    dec enc.blockedStreams

proc markBlocked*(dec: QpackDecoder) =
  if dec.blockedStreams < dec.blockedStreamsLimit:
    inc dec.blockedStreams

proc markUnblocked*(dec: QpackDecoder) =
  if dec.blockedStreams > 0:
    dec dec.blockedStreams

proc encodeHeaderBlockPrefix(requiredInsertCount: uint64, base: uint64): seq[byte] =
  result = @[]
  result.appendQuicVarInt(requiredInsertCount)
  result.appendQuicVarInt(base)

proc decodeHeaderBlockPrefix(data: openArray[byte], offset: var int): tuple[requiredInsertCount: uint64, base: uint64] =
  let ric = decodeQuicVarInt(data, offset)
  let b = decodeQuicVarInt(data, offset)
  (requiredInsertCount: ric, base: b)

proc encodeHeaders*(enc: QpackEncoder, headers: openArray[QpackHeaderField]): seq[byte] =
  ## Runtime baseline:
  ## prefix(required_insert_count, base), then fields:
  ## 0x80 static-indexed, 0x40 dynamic-indexed, 0x00 literal.
  result = encodeHeaderBlockPrefix(enc.insertCount, uint64(enc.dynamicTable.len))
  for h in headers:
    let staticIdx = findStaticIndex(h)
    if staticIdx >= 0:
      result.add 0x80'u8
      result.appendQuicVarInt(uint64(staticIdx))
      continue

    let dynIdx = findDynamicIndex(enc.dynamicTable, h)
    if dynIdx >= 0:
      result.add 0x40'u8
      result.appendQuicVarInt(uint64(dynIdx))
      continue

    result.add 0x00'u8
    result.appendString(h.name)
    result.appendString(h.value)
    if addDynamic(enc.dynamicTable, h, enc.maxTableCapacity):
      checkedIncCounter(enc.insertCount, "QPACK encoder insert count")

proc decodeHeaders*(dec: QpackDecoder, encoded: openArray[byte]): seq[QpackHeaderField] =
  var off = 0
  let prefix = decodeHeaderBlockPrefix(encoded, off)
  dec.requiredInsertCount = prefix.requiredInsertCount
  if dec.knownInsertCount < dec.requiredInsertCount:
    dec.markBlocked()
    raise newException(ValueError, "QPACK required insert count not yet available")

  while off < encoded.len:
    let marker = encoded[off]
    inc off
    if marker == 0x80'u8:
      let idx = decodeQuicVarInt(encoded, off)
      if idx >= uint64(QpackStaticTable.len):
        raise newException(ValueError, "QPACK static index out of range")
      result.add QpackStaticTable[int(idx)]
    elif marker == 0x40'u8:
      let idx = decodeQuicVarInt(encoded, off)
      if idx >= uint64(dec.dynamicTable.len):
        raise newException(ValueError, "QPACK dynamic index out of range")
      result.add dec.dynamicTable[int(idx)]
    elif marker == 0x00'u8:
      let name = decodeString(encoded, off)
      let value = decodeString(encoded, off)
      let hf: QpackHeaderField = (name, value)
      result.add hf
      if addDynamic(dec.dynamicTable, hf, dec.maxTableCapacity):
        checkedIncCounter(dec.knownInsertCount, "QPACK decoder known insert count")
    else:
      raise newException(ValueError, "unsupported QPACK field marker")

  if dec.blockedStreams > 0:
    dec.markUnblocked()

proc findStaticNameIndex(name: string): int =
  for i in 0 ..< QpackStaticTable.len:
    if QpackStaticTable[i].name == name:
      return i
  -1

proc decodeRawRfcBytes(data: openArray[byte], offset: var int, n: int): string =
  if offset + n > data.len:
    raise newException(ValueError, "QPACK string truncated")
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(data[offset + i])
  offset += n

proc appendRfcString(dst: var seq[byte], s: string, preferHuffman: bool = true) =
  if preferHuffman:
    let h = hpack.huffmanEncode(s)
    if h.len < s.len:
      appendPrefixedInt(dst, 0x80'u8, 7, uint64(h.len))
      dst.add h
      return
  appendPrefixedInt(dst, 0x00'u8, 7, uint64(s.len))
  for c in s:
    dst.add byte(ord(c) and 0xFF)

proc decodeRfcString(data: openArray[byte], offset: var int): string =
  if offset >= data.len:
    raise newException(ValueError, "QPACK string truncated")
  let first = data[offset]
  inc offset
  let isHuffman = (first and 0x80'u8) != 0'u8
  let n = decodePrefixedInt(data, offset, first, 7)
  if offset + int(n) > data.len:
    raise newException(ValueError, "QPACK string truncated")
  if isHuffman:
    result = hpack.huffmanDecode(data, offset, int(n))
    offset += int(n)
  else:
    result = decodeRawRfcBytes(data, offset, int(n))

proc maxEntriesForCapacity(maxTableCapacity: int): uint64 {.inline.} =
  if maxTableCapacity <= 0:
    return 0'u64
  uint64(maxTableCapacity div 32)

proc encodeRfcHeaderBlockPrefix(requiredInsertCount: uint64,
                                base: uint64,
                                maxTableCapacity: int): seq[byte] =
  result = @[]
  let maxEntries = maxEntriesForCapacity(maxTableCapacity)
  let encodedRic =
    if requiredInsertCount == 0'u64:
      0'u64
    else:
      if maxEntries == 0'u64:
        raise newException(ValueError, "QPACK dynamic references unavailable with zero table capacity")
      let fullRange = 2'u64 * maxEntries
      (requiredInsertCount mod fullRange) + 1'u64
  appendPrefixedInt(result, 0x00'u8, 8, encodedRic)
  if base >= requiredInsertCount:
    appendPrefixedInt(result, 0x00'u8, 7, base - requiredInsertCount)
  else:
    appendPrefixedInt(result, 0x80'u8, 7, requiredInsertCount - base - 1'u64)

proc decodeRfcHeaderBlockPrefix(dec: QpackDecoder,
                                data: openArray[byte],
                                offset: var int): tuple[requiredInsertCount: uint64, base: uint64] =
  if offset >= data.len:
    raise newException(ValueError, "QPACK RFC-wire header block truncated")
  let ricFirst = data[offset]
  inc offset
  let encodedRic = decodePrefixedInt(data, offset, ricFirst, 8)
  let maxEntries = maxEntriesForCapacity(dec.maxTableCapacity)
  let requiredInsertCount =
    if encodedRic == 0'u64:
      0'u64
    else:
      if maxEntries == 0'u64:
        raise newException(ValueError, "QPACK Encoded Required Insert Count invalid for zero table capacity")
      if maxEntries > high(uint64) div 2'u64:
        raise newException(ValueError, "QPACK Required Insert Count range overflow")
      let fullRange = 2'u64 * maxEntries
      if encodedRic > fullRange:
        raise newException(ValueError, "QPACK Encoded Required Insert Count out of range")
      if high(uint64) - dec.knownInsertCount < maxEntries:
        raise newException(ValueError, "QPACK Required Insert Count range overflow")
      let maxValue = dec.knownInsertCount + maxEntries
      let maxWrapped = (maxValue div fullRange) * fullRange
      let ricDelta = encodedRic - 1'u64
      if high(uint64) - maxWrapped < ricDelta:
        raise newException(ValueError, "QPACK Required Insert Count decode overflow")
      var ric = maxWrapped + ricDelta
      if ric > maxValue:
        if ric <= fullRange:
          raise newException(ValueError, "QPACK Required Insert Count decode underflow")
        ric -= fullRange
      ric
  if offset >= data.len:
    raise newException(ValueError, "QPACK RFC-wire header block truncated")
  let dbFirst = data[offset]
  inc offset
  let deltaBase = decodePrefixedInt(data, offset, dbFirst, 7)
  let negative = (dbFirst and 0x80'u8) != 0'u8
  let base =
    if negative:
      if requiredInsertCount == 0'u64 or deltaBase >= requiredInsertCount:
        raise newException(ValueError, "QPACK Delta Base out of range")
      requiredInsertCount - deltaBase - 1'u64
    else:
      if high(uint64) - requiredInsertCount < deltaBase:
        raise newException(ValueError, "QPACK Delta Base overflow")
      requiredInsertCount + deltaBase
  (requiredInsertCount: requiredInsertCount, base: base)

proc resolveDynamicAbsoluteIndex(dec: QpackDecoder, absoluteIndex: uint64): QpackHeaderField =
  if dec.knownInsertCount == 0'u64:
    raise newException(ValueError, "QPACK dynamic index out of range")
  if absoluteIndex >= dec.knownInsertCount:
    raise newException(ValueError, "QPACK dynamic index out of range")
  let newestAbs = dec.knownInsertCount - 1'u64
  let distanceFromNewest = newestAbs - absoluteIndex
  if distanceFromNewest >= uint64(dec.dynamicTable.len):
    raise newException(ValueError, "QPACK dynamic index out of range")
  dec.dynamicTable[int(distanceFromNewest)]

proc resolveDynamicRelativeIndex(dec: QpackDecoder,
                                 base: uint64,
                                 relativeIndex: uint64): QpackHeaderField =
  if base == 0'u64 or relativeIndex >= base:
    raise newException(ValueError, "QPACK dynamic index out of range")
  let absoluteIndex = base - relativeIndex - 1'u64
  dec.resolveDynamicAbsoluteIndex(absoluteIndex)

proc resolveDynamicPostBaseIndex(dec: QpackDecoder,
                                 base: uint64,
                                 postBaseIndex: uint64): QpackHeaderField =
  let absoluteIndex = base + postBaseIndex
  dec.resolveDynamicAbsoluteIndex(absoluteIndex)

proc dynamicAbsoluteIndex(enc: QpackEncoder, tableIndex: int): uint64 {.inline.} =
  enc.insertCount - 1'u64 - uint64(tableIndex)

proc encodeHeadersRfcWireWithInstructions*(enc: QpackEncoder,
                                           headers: openArray[QpackHeaderField],
                                           emittedInstructions: var seq[QpackEncoderInstruction]): seq[byte] =
  ## RFC-wire fallback used for live interop.
  ## Uses static/literal forms and dynamic references when peer-acknowledged
  ## insert count permits safe indexed access.
  let base = enc.requiredInsertCount
  var fieldLines: seq[seq[byte]] = @[]
  var usedDynamicReference = false
  for h in headers:
    var fieldLine: seq[byte] = @[]
    let staticIdx = findStaticIndex(h)
    if staticIdx >= 0:
      appendPrefixedInt(fieldLine, 0xC0'u8, 6, uint64(staticIdx))
      fieldLines.add fieldLine
      continue

    let dynIdx = findDynamicIndex(enc.dynamicTable, h)
    if dynIdx >= 0 and base > 0'u64:
      let absIdx = enc.dynamicAbsoluteIndex(dynIdx)
      if absIdx < base:
        # RFC9204 indexed field line with dynamic table reference.
        appendPrefixedInt(fieldLine, 0x80'u8, 6, base - absIdx - 1'u64)
        fieldLines.add fieldLine
        usedDynamicReference = true
        continue

    let staticNameIdx = findStaticNameIndex(h.name)
    if staticNameIdx >= 0:
      # Literal with name reference (static table, N=0).
      appendPrefixedInt(fieldLine, 0x50'u8, 4, uint64(staticNameIdx))
      fieldLine.appendRfcString(h.value)
    else:
      # Literal with literal name (optionally Huffman coded name).
      let nameH = hpack.huffmanEncode(h.name)
      if nameH.len < h.name.len:
        appendPrefixedInt(fieldLine, 0x28'u8, 3, uint64(nameH.len))
        fieldLine.add nameH
      else:
        appendPrefixedInt(fieldLine, 0x20'u8, 3, uint64(h.name.len))
        for c in h.name:
          fieldLine.add byte(ord(c) and 0xFF)
      fieldLine.appendRfcString(h.value)

    # If entry already exists but cannot be referenced yet, avoid duplicate
    # dynamic insertion and emit literal field line only.
    if dynIdx < 0 and addDynamic(enc.dynamicTable, h, enc.maxTableCapacity):
      if staticNameIdx >= 0:
        emittedInstructions.add QpackEncoderInstruction(
          kind: qeikInsertNameRef,
          nameRefIndex: uint64(staticNameIdx),
          nameRefIsStatic: true,
          value: h.value
        )
      else:
        emittedInstructions.add QpackEncoderInstruction(
          kind: qeikInsertLiteral,
          name: h.name,
          value: h.value
        )
      checkedIncCounter(enc.insertCount, "QPACK encoder insert count")
    fieldLines.add fieldLine

  let prefixRic = if usedDynamicReference: base else: 0'u64
  result = encodeRfcHeaderBlockPrefix(prefixRic, prefixRic, enc.maxTableCapacity)
  for line in fieldLines:
    result.add line

proc encodeHeadersRfcWire*(enc: QpackEncoder, headers: openArray[QpackHeaderField]): seq[byte] =
  var ignoredInstructions: seq[QpackEncoderInstruction] = @[]
  enc.encodeHeadersRfcWireWithInstructions(headers, ignoredInstructions)

proc decodeHeadersRfcWire*(dec: QpackDecoder, encoded: openArray[byte]): seq[QpackHeaderField] =
  var off = 0
  let prefix = decodeRfcHeaderBlockPrefix(dec, encoded, off)
  dec.requiredInsertCount = prefix.requiredInsertCount
  if dec.knownInsertCount < dec.requiredInsertCount:
    dec.markBlocked()
    raise newException(ValueError, "QPACK required insert count not yet available")

  while off < encoded.len:
    let first = encoded[off]
    inc off
    if (first and 0x80'u8) != 0'u8:
      let idx = decodePrefixedInt(encoded, off, first, 6)
      let isStatic = (first and 0x40'u8) != 0'u8
      if isStatic:
        if idx >= uint64(QpackStaticTable.len):
          raise newException(ValueError, "QPACK static index out of range")
        result.add QpackStaticTable[int(idx)]
      else:
        result.add dec.resolveDynamicRelativeIndex(prefix.base, idx)
      continue

    if (first and 0xF0'u8) == 0x10'u8:
      # RFC9204 indexed field line with post-base index.
      let idx = decodePrefixedInt(encoded, off, first, 4)
      result.add dec.resolveDynamicPostBaseIndex(prefix.base, idx)
      continue

    if (first and 0xC0'u8) == 0x40'u8:
      let nameIdx = decodePrefixedInt(encoded, off, first, 4)
      let isStatic = (first and 0x10'u8) != 0'u8
      let name =
        if isStatic:
          if nameIdx >= uint64(QpackStaticTable.len):
            raise newException(ValueError, "QPACK static name index out of range")
          QpackStaticTable[int(nameIdx)].name
        else:
          dec.resolveDynamicRelativeIndex(prefix.base, nameIdx).name
      let value = decodeRfcString(encoded, off)
      let hf: QpackHeaderField = (name, value)
      result.add hf
      continue

    if (first and 0xF0'u8) == 0x00'u8:
      # RFC9204 literal field line with post-base name reference.
      let nameIdx = decodePrefixedInt(encoded, off, first, 3)
      let name = dec.resolveDynamicPostBaseIndex(prefix.base, nameIdx).name
      let value = decodeRfcString(encoded, off)
      result.add (name, value)
      continue

    if (first and 0xE0'u8) == 0x20'u8:
      let nameHuffman = (first and 0x08'u8) != 0'u8
      let nameLen = decodePrefixedInt(encoded, off, first, 3)
      if off + int(nameLen) > encoded.len:
        raise newException(ValueError, "QPACK literal name truncated")
      let name =
        if nameHuffman:
          let decoded = hpack.huffmanDecode(encoded, off, int(nameLen))
          off += int(nameLen)
          decoded
        else:
          decodeRawRfcBytes(encoded, off, int(nameLen))
      let value = decodeRfcString(encoded, off)
      result.add (name, value)
      continue

    raise newException(ValueError, "unsupported QPACK RFC-wire field line")

  if dec.blockedStreams > 0:
    dec.markUnblocked()

proc encodeEncoderInstruction*(inst: QpackEncoderInstruction): seq[byte] =
  result = @[]
  case inst.kind
  of qeikInsertLiteral:
    # RFC9204 Insert Without Name Reference.
    let nameH = hpack.huffmanEncode(inst.name)
    if nameH.len < inst.name.len:
      appendPrefixedInt(result, 0x60'u8, 5, uint64(nameH.len))
      result.add nameH
    else:
      appendPrefixedInt(result, 0x40'u8, 5, uint64(inst.name.len))
      for c in inst.name:
        result.add byte(ord(c) and 0xFF)
    result.appendRfcString(inst.value)
  of qeikInsertNameRef:
    # RFC9204 Insert With Name Reference.
    let mask = if inst.nameRefIsStatic: 0xC0'u8 else: 0x80'u8
    appendPrefixedInt(result, mask, 6, inst.nameRefIndex)
    result.appendRfcString(inst.value)
  of qeikDuplicate:
    # RFC9204 Duplicate instruction.
    result.appendPrefixedInt(0x00'u8, 5, inst.duplicateIndex)
  of qeikSetCapacity:
    # RFC9204 Set Dynamic Table Capacity instruction.
    result.appendPrefixedInt(0x20'u8, 5, inst.capacity)

proc decodeEncoderInstructionPrefix*(payload: openArray[byte],
                                     offset: var int): QpackEncoderInstruction =
  var off = offset
  if payload.len == 0:
    raise newException(ValueError, "empty QPACK encoder instruction")
  if off >= payload.len:
    raise newException(ValueError, "truncated QPACK encoder instruction")
  let typ = payload[off]
  inc off
  # Backward-compatible legacy opcodes.
  if typ == 0x01'u8:
    result = QpackEncoderInstruction(
      kind: qeikInsertLiteral,
      name: decodeString(payload, off),
      value: decodeString(payload, off)
    )
  elif typ == 0x02'u8:
    result = QpackEncoderInstruction(kind: qeikDuplicate, duplicateIndex: decodeQuicVarInt(payload, off))
  elif typ == 0x03'u8:
    result = QpackEncoderInstruction(kind: qeikSetCapacity, capacity: decodeQuicVarInt(payload, off))
  elif (typ and 0xC0'u8) == 0x40'u8:
    # RFC9204 Insert Without Name Reference.
    let nameHuffman = (typ and 0x20'u8) != 0'u8
    let nameLen = decodePrefixedInt(payload, off, typ, 5)
    if off + int(nameLen) > payload.len:
      raise newException(ValueError, "QPACK literal name truncated")
    let name =
      if nameHuffman:
        let decoded = hpack.huffmanDecode(payload, off, int(nameLen))
        off += int(nameLen)
        decoded
      else:
        decodeRawRfcBytes(payload, off, int(nameLen))
    result = QpackEncoderInstruction(
      kind: qeikInsertLiteral,
      name: name,
      value: decodeRfcString(payload, off)
    )
  elif (typ and 0xE0'u8) == 0x20'u8:
    # RFC9204 Set Dynamic Table Capacity.
    result = QpackEncoderInstruction(
      kind: qeikSetCapacity,
      capacity: decodePrefixedInt(payload, off, typ, 5)
    )
  elif (typ and 0xE0'u8) == 0x00'u8:
    # RFC9204 Duplicate.
    result = QpackEncoderInstruction(
      kind: qeikDuplicate,
      duplicateIndex: decodePrefixedInt(payload, off, typ, 5)
    )
  elif (typ and 0x80'u8) == 0x80'u8:
    # RFC9204 Insert With Name Reference.
    result = QpackEncoderInstruction(
      kind: qeikInsertNameRef,
      nameRefIndex: decodePrefixedInt(payload, off, typ, 6),
      nameRefIsStatic: (typ and 0x40'u8) != 0'u8,
      value: decodeRfcString(payload, off)
    )
  else:
    raise newException(ValueError, "unsupported QPACK encoder instruction")
  offset = off

proc decodeEncoderInstruction*(payload: openArray[byte]): QpackEncoderInstruction =
  var off = 0
  result = decodeEncoderInstructionPrefix(payload, off)
  if off != payload.len:
    raise newException(ValueError, "trailing bytes in QPACK encoder instruction")

proc applyEncoderInstruction*(dec: QpackDecoder, inst: QpackEncoderInstruction) =
  case inst.kind
  of qeikInsertLiteral:
    let hf: QpackHeaderField = (inst.name, inst.value)
    if addDynamic(dec.dynamicTable, hf, dec.maxTableCapacity):
      checkedIncCounter(dec.knownInsertCount, "QPACK decoder known insert count")
  of qeikInsertNameRef:
    let name =
      if inst.nameRefIsStatic:
        if inst.nameRefIndex >= uint64(QpackStaticTable.len):
          raise newException(ValueError, "QPACK static name reference out of range")
        QpackStaticTable[int(inst.nameRefIndex)].name
      else:
        if inst.nameRefIndex >= uint64(dec.dynamicTable.len):
          raise newException(ValueError, "QPACK dynamic name reference out of range")
        dec.dynamicTable[int(inst.nameRefIndex)].name
    let hf: QpackHeaderField = (name, inst.value)
    if addDynamic(dec.dynamicTable, hf, dec.maxTableCapacity):
      checkedIncCounter(dec.knownInsertCount, "QPACK decoder known insert count")
  of qeikDuplicate:
    let idx = int(inst.duplicateIndex)
    if idx < 0 or idx >= dec.dynamicTable.len:
      raise newException(ValueError, "QPACK duplicate index out of range")
    if addDynamic(dec.dynamicTable, dec.dynamicTable[idx], dec.maxTableCapacity):
      checkedIncCounter(dec.knownInsertCount, "QPACK decoder known insert count")
  of qeikSetCapacity:
    dec.maxTableCapacity = int(min(uint64(high(int)), inst.capacity))
    trimDynamicTable(dec.dynamicTable, dec.maxTableCapacity)

proc encodeDecoderInstruction*(inst: QpackDecoderInstruction): seq[byte] =
  result = @[]
  case inst.kind
  of qdikSectionAck:
    # RFC9204 Section Acknowledgment.
    result.appendPrefixedInt(0x80'u8, 7, inst.streamId)
  of qdikStreamCancel:
    # RFC9204 Stream Cancellation.
    result.appendPrefixedInt(0x40'u8, 6, inst.cancelStreamId)
  of qdikInsertCountIncrement:
    # RFC9204 Insert Count Increment.
    result.appendPrefixedInt(0x00'u8, 6, inst.insertCountDelta)

proc decodeDecoderInstructionPrefix*(payload: openArray[byte],
                                     offset: var int): QpackDecoderInstruction =
  var off = offset
  if payload.len == 0:
    raise newException(ValueError, "empty QPACK decoder instruction")
  if off >= payload.len:
    raise newException(ValueError, "truncated QPACK decoder instruction")
  let typ = payload[off]
  inc off
  # Backward-compatible legacy opcodes.
  if typ == 0x81'u8:
    result = QpackDecoderInstruction(kind: qdikSectionAck, streamId: decodeQuicVarInt(payload, off))
  elif typ == 0x82'u8:
    result = QpackDecoderInstruction(kind: qdikStreamCancel, cancelStreamId: decodeQuicVarInt(payload, off))
  elif typ == 0x83'u8:
    result = QpackDecoderInstruction(kind: qdikInsertCountIncrement, insertCountDelta: decodeQuicVarInt(payload, off))
  elif (typ and 0x80'u8) != 0'u8:
    result = QpackDecoderInstruction(
      kind: qdikSectionAck,
      streamId: decodePrefixedInt(payload, off, typ, 7)
    )
  elif (typ and 0xC0'u8) == 0x40'u8:
    result = QpackDecoderInstruction(
      kind: qdikStreamCancel,
      cancelStreamId: decodePrefixedInt(payload, off, typ, 6)
    )
  else:
    result = QpackDecoderInstruction(
      kind: qdikInsertCountIncrement,
      insertCountDelta: decodePrefixedInt(payload, off, typ, 6)
    )
  offset = off

proc decodeDecoderInstruction*(payload: openArray[byte]): QpackDecoderInstruction =
  var off = 0
  result = decodeDecoderInstructionPrefix(payload, off)
  if off != payload.len:
    raise newException(ValueError, "trailing bytes in QPACK decoder instruction")

proc applyDecoderInstruction*(enc: QpackEncoder, inst: QpackDecoderInstruction) =
  case inst.kind
  of qdikSectionAck:
    discard inst.streamId
    if enc.blockedStreams > 0:
      enc.markUnblocked()
  of qdikStreamCancel:
    discard inst.cancelStreamId
    if enc.blockedStreams > 0:
      enc.markUnblocked()
  of qdikInsertCountIncrement:
    if high(uint64) - enc.requiredInsertCount < inst.insertCountDelta:
      raise newException(ValueError, "QPACK insert count increment overflow")
    enc.requiredInsertCount += inst.insertCountDelta

proc encodeEncoderInsertInstruction*(name: string, value: string): seq[byte] =
  ## Backward-compatible helper used by existing tests.
  encodeEncoderInstruction(QpackEncoderInstruction(kind: qeikInsertLiteral, name: name, value: value))
