## HPACK Header Compression for HTTP/2
##
## Implements RFC 7541 - HPACK: Header Compression for HTTP/2.
## Provides encoding and decoding of HTTP/2 header fields.

import std/[tables, strutils]

const StaticTable*: seq[(string, string)] = @[
  ("", ""),                              # 0: unused
  (":authority", ""),                    # 1
  (":method", "GET"),                    # 2
  (":method", "POST"),                   # 3
  (":path", "/"),                        # 4
  (":path", "/index.html"),              # 5
  (":scheme", "http"),                   # 6
  (":scheme", "https"),                  # 7
  (":status", "200"),                    # 8
  (":status", "204"),                    # 9
  (":status", "206"),                    # 10
  (":status", "304"),                    # 11
  (":status", "400"),                    # 12
  (":status", "404"),                    # 13
  (":status", "500"),                    # 14
  ("accept-charset", ""),                # 15
  ("accept-encoding", "gzip, deflate"), # 16
  ("accept-language", ""),               # 17
  ("accept-ranges", ""),                 # 18
  ("accept", ""),                        # 19
  ("access-control-allow-origin", ""),   # 20
  ("age", ""),                           # 21
  ("allow", ""),                         # 22
  ("authorization", ""),                 # 23
  ("cache-control", ""),                 # 24
  ("content-disposition", ""),           # 25
  ("content-encoding", ""),              # 26
  ("content-language", ""),              # 27
  ("content-length", ""),                # 28
  ("content-location", ""),              # 29
  ("content-range", ""),                 # 30
  ("content-type", ""),                  # 31
  ("cookie", ""),                        # 32
  ("date", ""),                          # 33
  ("etag", ""),                          # 34
  ("expect", ""),                        # 35
  ("expires", ""),                       # 36
  ("from", ""),                          # 37
  ("host", ""),                          # 38
  ("if-match", ""),                      # 39
  ("if-modified-since", ""),             # 40
  ("if-none-match", ""),                 # 41
  ("if-range", ""),                      # 42
  ("if-unmodified-since", ""),           # 43
  ("last-modified", ""),                 # 44
  ("link", ""),                          # 45
  ("location", ""),                      # 46
  ("max-forwards", ""),                  # 47
  ("proxy-authenticate", ""),            # 48
  ("proxy-authorization", ""),           # 49
  ("range", ""),                         # 50
  ("referer", ""),                       # 51
  ("refresh", ""),                       # 52
  ("retry-after", ""),                   # 53
  ("server", ""),                        # 54
  ("set-cookie", ""),                    # 55
  ("strict-transport-security", ""),     # 56
  ("transfer-encoding", ""),             # 57
  ("user-agent", ""),                    # 58
  ("vary", ""),                          # 59
  ("via", ""),                           # 60
  ("www-authenticate", ""),              # 61
]

type
  DynamicTable* = object
    entries: seq[(string, string)]
    size: int
    maxSize: int

  HpackEncoder* = object
    dynTable: DynamicTable

  HpackDecoder* = object
    dynTable: DynamicTable

proc entrySize(name, value: string): int =
  name.len + value.len + 32  # RFC 7541 section 4.1

proc initDynamicTable*(maxSize: int = 4096): DynamicTable =
  DynamicTable(maxSize: maxSize)

proc evict(dt: var DynamicTable) =
  while dt.size > dt.maxSize and dt.entries.len > 0:
    let (name, value) = dt.entries.pop()
    dt.size -= entrySize(name, value)

proc add*(dt: var DynamicTable, name, value: string) =
  let eSize = entrySize(name, value)
  # Evict until we have room
  while dt.size + eSize > dt.maxSize and dt.entries.len > 0:
    let (n, v) = dt.entries.pop()
    dt.size -= entrySize(n, v)
  if eSize <= dt.maxSize:
    dt.entries.insert((name, value), 0)
    dt.size += eSize

proc get*(dt: DynamicTable, index: int): (string, string) =
  ## Index is 0-based within the dynamic table.
  if index < dt.entries.len:
    return dt.entries[index]
  raise newException(IndexDefect, "Dynamic table index out of range: " & $index)

proc lookup(index: int, dt: DynamicTable): (string, string) =
  ## Lookup by HPACK index (1-based, static table first).
  if index < 1:
    raise newException(ValueError, "Invalid HPACK index: " & $index)
  if index <= StaticTable.high:
    return StaticTable[index]
  let dynIdx = index - StaticTable.len
  return dt.get(dynIdx)

# ============================================================
# Integer encoding/decoding (RFC 7541 section 5.1)
# ============================================================

proc encodeInteger*(value: int, prefixBits: int, firstByte: byte): seq[byte] =
  let maxPrefix = (1 shl prefixBits) - 1
  if value < maxPrefix:
    result = @[firstByte or byte(value)]
  else:
    result = @[firstByte or byte(maxPrefix)]
    var remaining = value - maxPrefix
    while remaining >= 128:
      result.add byte((remaining and 0x7F) or 0x80)
      remaining = remaining shr 7
    result.add byte(remaining)

proc decodeInteger*(data: openArray[byte], offset: var int, prefixBits: int): int =
  let maxPrefix = (1 shl prefixBits) - 1
  result = int(data[offset] and byte(maxPrefix))
  offset += 1
  if result < maxPrefix:
    return
  var shift = 0
  while offset < data.len:
    let b = data[offset]
    offset += 1
    result += int(b and 0x7F) shl shift
    shift += 7
    if (b and 0x80) == 0:
      break

# ============================================================
# Huffman decoding (RFC 7541 Appendix B)
# ============================================================

# HPACK Huffman table: (code, bitLength) for each symbol 0-256.
# Symbol 256 is EOS (end of string).
const HuffmanTable: array[257, (uint32, uint8)] = [
  (0x1ff8'u32, 13'u8),     # 0
  (0x7fffd8'u32, 23'u8),   # 1
  (0xfffffe2'u32, 28'u8),  # 2
  (0xfffffe3'u32, 28'u8),  # 3
  (0xfffffe4'u32, 28'u8),  # 4
  (0xfffffe5'u32, 28'u8),  # 5
  (0xfffffe6'u32, 28'u8),  # 6
  (0xfffffe7'u32, 28'u8),  # 7
  (0xfffffe8'u32, 28'u8),  # 8
  (0xffffea'u32, 24'u8),   # 9
  (0x3ffffffc'u32, 30'u8), # 10
  (0xfffffe9'u32, 28'u8),  # 11
  (0xfffffea'u32, 28'u8),  # 12
  (0x3ffffffd'u32, 30'u8), # 13
  (0xfffffeb'u32, 28'u8),  # 14
  (0xfffffec'u32, 28'u8),  # 15
  (0xfffffed'u32, 28'u8),  # 16
  (0xfffffee'u32, 28'u8),  # 17
  (0xfffffef'u32, 28'u8),  # 18
  (0xffffff0'u32, 28'u8),  # 19
  (0xffffff1'u32, 28'u8),  # 20
  (0xffffff2'u32, 28'u8),  # 21
  (0x3ffffffe'u32, 30'u8), # 22
  (0xffffff3'u32, 28'u8),  # 23
  (0xffffff4'u32, 28'u8),  # 24
  (0xffffff5'u32, 28'u8),  # 25
  (0xffffff6'u32, 28'u8),  # 26
  (0xffffff7'u32, 28'u8),  # 27
  (0xffffff8'u32, 28'u8),  # 28
  (0xffffff9'u32, 28'u8),  # 29
  (0xffffffa'u32, 28'u8),  # 30
  (0xffffffb'u32, 28'u8),  # 31
  (0x14'u32, 6'u8),        # 32 ' '
  (0x3f8'u32, 10'u8),      # 33 '!'
  (0x3f9'u32, 10'u8),      # 34 '"'
  (0xffa'u32, 12'u8),      # 35 '#'
  (0x1ff9'u32, 13'u8),     # 36 '$'
  (0x15'u32, 6'u8),        # 37 '%'
  (0xf8'u32, 8'u8),        # 38 '&'
  (0x7fa'u32, 11'u8),      # 39 '\''
  (0x3fa'u32, 10'u8),      # 40 '('
  (0x3fb'u32, 10'u8),      # 41 ')'
  (0xf9'u32, 8'u8),        # 42 '*'
  (0x7fb'u32, 11'u8),      # 43 '+'
  (0xfa'u32, 8'u8),        # 44 ','
  (0x16'u32, 6'u8),        # 45 '-'
  (0x17'u32, 6'u8),        # 46 '.'
  (0x18'u32, 6'u8),        # 47 '/'
  (0x0'u32, 5'u8),         # 48 '0'
  (0x1'u32, 5'u8),         # 49 '1'
  (0x2'u32, 5'u8),         # 50 '2'
  (0x19'u32, 6'u8),        # 51 '3'
  (0x1a'u32, 6'u8),        # 52 '4'
  (0x1b'u32, 6'u8),        # 53 '5'
  (0x1c'u32, 6'u8),        # 54 '6'
  (0x1d'u32, 6'u8),        # 55 '7'
  (0x1e'u32, 6'u8),        # 56 '8'
  (0x1f'u32, 6'u8),        # 57 '9'
  (0x5c'u32, 7'u8),        # 58 ':'
  (0xfb'u32, 8'u8),        # 59 ';'
  (0x7ffc'u32, 15'u8),     # 60 '<'
  (0x20'u32, 6'u8),        # 61 '='
  (0xffb'u32, 12'u8),      # 62 '>'
  (0x3fc'u32, 10'u8),      # 63 '?'
  (0x1ffa'u32, 13'u8),     # 64 '@'
  (0x21'u32, 6'u8),        # 65 'A'
  (0x5d'u32, 7'u8),        # 66 'B'
  (0x5e'u32, 7'u8),        # 67 'C'
  (0x5f'u32, 7'u8),        # 68 'D'
  (0x60'u32, 7'u8),        # 69 'E'
  (0x61'u32, 7'u8),        # 70 'F'
  (0x62'u32, 7'u8),        # 71 'G'
  (0x63'u32, 7'u8),        # 72 'H'
  (0x64'u32, 7'u8),        # 73 'I'
  (0x65'u32, 7'u8),        # 74 'J'
  (0x66'u32, 7'u8),        # 75 'K'
  (0x67'u32, 7'u8),        # 76 'L'
  (0x68'u32, 7'u8),        # 77 'M'
  (0x69'u32, 7'u8),        # 78 'N'
  (0x6a'u32, 7'u8),        # 79 'O'
  (0x6b'u32, 7'u8),        # 80 'P'
  (0x6c'u32, 7'u8),        # 81 'Q'
  (0x6d'u32, 7'u8),        # 82 'R'
  (0x6e'u32, 7'u8),        # 83 'S'
  (0x6f'u32, 7'u8),        # 84 'T'
  (0x70'u32, 7'u8),        # 85 'U'
  (0x71'u32, 7'u8),        # 86 'V'
  (0x72'u32, 7'u8),        # 87 'W'
  (0xfc'u32, 8'u8),        # 88 'X'
  (0x73'u32, 7'u8),        # 89 'Y'
  (0xfd'u32, 8'u8),        # 90 'Z'
  (0x1ffb'u32, 13'u8),     # 91 '['
  (0x7fff0'u32, 19'u8),    # 92 '\\'
  (0x1ffc'u32, 13'u8),     # 93 ']'
  (0x3ffc'u32, 14'u8),     # 94 '^'
  (0x22'u32, 6'u8),        # 95 '_'
  (0x7ffd'u32, 15'u8),     # 96 '`'
  (0x3'u32, 5'u8),         # 97 'a'
  (0x23'u32, 6'u8),        # 98 'b'
  (0x4'u32, 5'u8),         # 99 'c'
  (0x24'u32, 6'u8),        # 100 'd'
  (0x5'u32, 5'u8),         # 101 'e'
  (0x25'u32, 6'u8),        # 102 'f'
  (0x26'u32, 6'u8),        # 103 'g'
  (0x27'u32, 6'u8),        # 104 'h'
  (0x6'u32, 5'u8),         # 105 'i'
  (0x74'u32, 7'u8),        # 106 'j'
  (0x75'u32, 7'u8),        # 107 'k'
  (0x28'u32, 6'u8),        # 108 'l'
  (0x29'u32, 6'u8),        # 109 'm'
  (0x2a'u32, 6'u8),        # 110 'n'
  (0x7'u32, 5'u8),         # 111 'o'
  (0x2b'u32, 6'u8),        # 112 'p'
  (0x76'u32, 7'u8),        # 113 'q'
  (0x2c'u32, 6'u8),        # 114 'r'
  (0x8'u32, 5'u8),         # 115 's'
  (0x9'u32, 5'u8),         # 116 't'
  (0x2d'u32, 6'u8),        # 117 'u'
  (0x77'u32, 7'u8),        # 118 'v'
  (0x78'u32, 7'u8),        # 119 'w'
  (0x79'u32, 7'u8),        # 120 'x'
  (0x7a'u32, 7'u8),        # 121 'y'
  (0x7b'u32, 7'u8),        # 122 'z'
  (0x7fffe'u32, 19'u8),    # 123 '{'
  (0x7fc'u32, 11'u8),      # 124 '|'
  (0x3ffd'u32, 14'u8),     # 125 '}'
  (0x1ffd'u32, 13'u8),     # 126 '~'
  (0xffffffc'u32, 28'u8),  # 127
  (0xfffe6'u32, 20'u8),    # 128
  (0x3fffd2'u32, 22'u8),   # 129
  (0xfffe7'u32, 20'u8),    # 130
  (0xfffe8'u32, 20'u8),    # 131
  (0x3fffd3'u32, 22'u8),   # 132
  (0x3fffd4'u32, 22'u8),   # 133
  (0x3fffd5'u32, 22'u8),   # 134
  (0x7fffd9'u32, 23'u8),   # 135
  (0x3fffd6'u32, 22'u8),   # 136
  (0x7fffda'u32, 23'u8),   # 137
  (0x7fffdb'u32, 23'u8),   # 138
  (0x7fffdc'u32, 23'u8),   # 139
  (0x7fffdd'u32, 23'u8),   # 140
  (0x7fffde'u32, 23'u8),   # 141
  (0xffffeb'u32, 24'u8),   # 142
  (0x7fffdf'u32, 23'u8),   # 143
  (0xffffec'u32, 24'u8),   # 144
  (0xffffed'u32, 24'u8),   # 145
  (0x3fffd7'u32, 22'u8),   # 146
  (0x7fffe0'u32, 23'u8),   # 147
  (0xffffee'u32, 24'u8),   # 148
  (0x7fffe1'u32, 23'u8),   # 149
  (0x7fffe2'u32, 23'u8),   # 150
  (0x7fffe3'u32, 23'u8),   # 151
  (0x7fffe4'u32, 23'u8),   # 152
  (0x1fffdc'u32, 21'u8),   # 153
  (0x3fffd8'u32, 22'u8),   # 154
  (0x7fffe5'u32, 23'u8),   # 155
  (0x3fffd9'u32, 22'u8),   # 156
  (0x7fffe6'u32, 23'u8),   # 157
  (0x7fffe7'u32, 23'u8),   # 158
  (0xffffef'u32, 24'u8),   # 159
  (0x3fffda'u32, 22'u8),   # 160
  (0x1fffdd'u32, 21'u8),   # 161
  (0xfffe9'u32, 20'u8),    # 162
  (0x3fffdb'u32, 22'u8),   # 163
  (0x3fffdc'u32, 22'u8),   # 164
  (0x7fffe8'u32, 23'u8),   # 165
  (0x7fffe9'u32, 23'u8),   # 166
  (0x1fffde'u32, 21'u8),   # 167
  (0x7fffea'u32, 23'u8),   # 168
  (0x3fffdd'u32, 22'u8),   # 169
  (0x3fffde'u32, 22'u8),   # 170
  (0xfffff0'u32, 24'u8),   # 171
  (0x1fffdf'u32, 21'u8),   # 172
  (0x3fffdf'u32, 22'u8),   # 173
  (0x7fffeb'u32, 23'u8),   # 174
  (0x7fffec'u32, 23'u8),   # 175
  (0x1fffe0'u32, 21'u8),   # 176
  (0x1fffe1'u32, 21'u8),   # 177
  (0x3fffe0'u32, 22'u8),   # 178
  (0x1fffe2'u32, 21'u8),   # 179
  (0x7fffed'u32, 23'u8),   # 180
  (0x3fffe1'u32, 22'u8),   # 181
  (0x7fffee'u32, 23'u8),   # 182
  (0x7fffef'u32, 23'u8),   # 183
  (0xfffea'u32, 20'u8),    # 184
  (0x3fffe2'u32, 22'u8),   # 185
  (0x3fffe3'u32, 22'u8),   # 186
  (0x3fffe4'u32, 22'u8),   # 187
  (0x7ffff0'u32, 23'u8),   # 188
  (0x3fffe5'u32, 22'u8),   # 189
  (0x3fffe6'u32, 22'u8),   # 190
  (0x7ffff1'u32, 23'u8),   # 191
  (0x3ffffe0'u32, 26'u8),  # 192
  (0x3ffffe1'u32, 26'u8),  # 193
  (0xfffeb'u32, 20'u8),    # 194
  (0x7fff1'u32, 19'u8),    # 195
  (0x3fffe7'u32, 22'u8),   # 196
  (0x7ffff2'u32, 23'u8),   # 197
  (0x3fffe8'u32, 22'u8),   # 198
  (0x1ffffec'u32, 25'u8),  # 199
  (0x3ffffe2'u32, 26'u8),  # 200
  (0x3ffffe3'u32, 26'u8),  # 201
  (0x3ffffe4'u32, 26'u8),  # 202
  (0x7ffffde'u32, 27'u8),  # 203
  (0x7ffffdf'u32, 27'u8),  # 204
  (0x3ffffe5'u32, 26'u8),  # 205
  (0xfffff1'u32, 24'u8),   # 206
  (0x1ffffed'u32, 25'u8),  # 207
  (0x7fff2'u32, 19'u8),    # 208
  (0x1fffe3'u32, 21'u8),   # 209
  (0x3ffffe6'u32, 26'u8),  # 210
  (0x7ffffe0'u32, 27'u8),  # 211
  (0x7ffffe1'u32, 27'u8),  # 212
  (0x3ffffe7'u32, 26'u8),  # 213
  (0x7ffffe2'u32, 27'u8),  # 214
  (0xfffff2'u32, 24'u8),   # 215
  (0x1fffe4'u32, 21'u8),   # 216
  (0x1fffe5'u32, 21'u8),   # 217
  (0x3ffffe8'u32, 26'u8),  # 218
  (0x3ffffe9'u32, 26'u8),  # 219
  (0xffffffd'u32, 28'u8),  # 220
  (0x7ffffe3'u32, 27'u8),  # 221
  (0x7ffffe4'u32, 27'u8),  # 222
  (0x7ffffe5'u32, 27'u8),  # 223
  (0xfffec'u32, 20'u8),    # 224
  (0xfffff3'u32, 24'u8),   # 225
  (0xfffed'u32, 20'u8),    # 226
  (0x1fffe6'u32, 21'u8),   # 227
  (0x3fffe9'u32, 22'u8),   # 228
  (0x1fffe7'u32, 21'u8),   # 229
  (0x1fffe8'u32, 21'u8),   # 230
  (0x7ffff3'u32, 23'u8),   # 231
  (0x3fffea'u32, 22'u8),   # 232
  (0x3fffeb'u32, 22'u8),   # 233
  (0x1ffffee'u32, 25'u8),  # 234
  (0x1ffffef'u32, 25'u8),  # 235
  (0xfffff4'u32, 24'u8),   # 236
  (0xfffff5'u32, 24'u8),   # 237
  (0x3ffffea'u32, 26'u8),  # 238
  (0x7ffff4'u32, 23'u8),   # 239
  (0x3ffffeb'u32, 26'u8),  # 240
  (0x7ffffe6'u32, 27'u8),  # 241
  (0x3ffffec'u32, 26'u8),  # 242
  (0x3ffffed'u32, 26'u8),  # 243
  (0x7ffffe7'u32, 27'u8),  # 244
  (0x7ffffe8'u32, 27'u8),  # 245
  (0x7ffffe9'u32, 27'u8),  # 246
  (0x7ffffea'u32, 27'u8),  # 247
  (0x7ffffeb'u32, 27'u8),  # 248
  (0xffffffe'u32, 28'u8),  # 249
  (0x7ffffec'u32, 27'u8),  # 250
  (0x7ffffed'u32, 27'u8),  # 251
  (0x7ffffee'u32, 27'u8),  # 252
  (0x7ffffef'u32, 27'u8),  # 253
  (0x7fffff0'u32, 27'u8),  # 254
  (0x3ffffee'u32, 26'u8),  # 255
  (0x3fffffff'u32, 30'u8), # 256 EOS
]

proc huffmanDecode(data: openArray[byte], startOffset: int, length: int): string =
  ## Decode Huffman-encoded bytes per RFC 7541 Appendix B.
  ## Uses bit-by-bit traversal against the Huffman table.
  result = ""
  var bits: uint64 = 0
  var bitsAvail = 0

  for i in 0 ..< length:
    bits = (bits shl 8) or uint64(data[startOffset + i])
    bitsAvail += 8

    # Try to decode symbols while we have enough bits
    while bitsAvail >= 5:  # Shortest code is 5 bits
      var found = false
      for sym in 0 ..< 256:
        let (code, codeLen) = HuffmanTable[sym]
        if int(codeLen) <= bitsAvail:
          # Check if the top codeLen bits match this symbol's code
          let shift = bitsAvail - int(codeLen)
          let candidate = uint32((bits shr shift) and ((1'u64 shl codeLen) - 1))
          if candidate == code:
            result.add char(sym)
            bitsAvail -= int(codeLen)
            bits = bits and ((1'u64 shl bitsAvail) - 1)
            found = true
            break
      if not found:
        break  # Need more bits

# ============================================================
# String encoding/decoding (RFC 7541 section 5.2)
# ============================================================

proc encodeString*(s: string, huffman: bool = false): seq[byte] =
  # For simplicity, we use literal encoding (no Huffman)
  result = encodeInteger(s.len, 7, 0x00)
  for c in s:
    result.add byte(c)

proc decodeString*(data: openArray[byte], offset: var int): string =
  let isHuffman = (data[offset] and 0x80) != 0
  let length = decodeInteger(data, offset, 7)
  if isHuffman:
    result = huffmanDecode(data, offset, length)
    offset += length
  else:
    result = newString(length)
    for i in 0 ..< length:
      result[i] = char(data[offset + i])
    offset += length

# ============================================================
# HPACK Encoder
# ============================================================

proc initHpackEncoder*(maxSize: int = 4096): HpackEncoder =
  HpackEncoder(dynTable: initDynamicTable(maxSize))

proc findInStaticTable(name, value: string): (int, bool) =
  ## Returns (index, exactMatch). index=0 means not found.
  var nameOnlyIdx = 0
  for i in 1 .. StaticTable.high:
    let (n, v) = StaticTable[i]
    if n == name:
      if v == value:
        return (i, true)
      if nameOnlyIdx == 0:
        nameOnlyIdx = i
  return (nameOnlyIdx, false)

proc encode*(enc: var HpackEncoder, headers: seq[(string, string)]): seq[byte] =
  result = @[]
  for (name, value) in headers:
    let (staticIdx, exactMatch) = findInStaticTable(name, value)

    if exactMatch and staticIdx > 0:
      # Indexed header field (section 6.1)
      result.add encodeInteger(staticIdx, 7, 0x80)
    elif staticIdx > 0:
      # Literal with incremental indexing, indexed name (section 6.2.1)
      result.add encodeInteger(staticIdx, 6, 0x40)
      result.add encodeString(value)
      enc.dynTable.add(name, value)
    else:
      # Literal with incremental indexing, new name (section 6.2.1)
      result.add 0x40.byte
      result.add encodeString(name)
      result.add encodeString(value)
      enc.dynTable.add(name, value)

# ============================================================
# HPACK Decoder
# ============================================================

proc initHpackDecoder*(maxSize: int = 4096): HpackDecoder =
  HpackDecoder(dynTable: initDynamicTable(maxSize))

proc decode*(dec: var HpackDecoder, data: openArray[byte]): seq[(string, string)] =
  result = @[]
  var offset = 0

  while offset < data.len:
    let firstByte = data[offset]

    if (firstByte and 0x80) != 0:
      # Indexed header field (section 6.1)
      let idx = decodeInteger(data, offset, 7)
      let (name, value) = lookup(idx, dec.dynTable)
      result.add (name, value)

    elif (firstByte and 0xC0) == 0x40:
      # Literal with incremental indexing (section 6.2.1)
      let nameIdx = decodeInteger(data, offset, 6)
      var name, value: string
      if nameIdx > 0:
        let pair = lookup(nameIdx, dec.dynTable); name = pair[0]
      else:
        name = decodeString(data, offset)
      value = decodeString(data, offset)
      dec.dynTable.add(name, value)
      result.add (name, value)

    elif (firstByte and 0xF0) == 0x00:
      # Literal without indexing (section 6.2.2)
      let nameIdx = decodeInteger(data, offset, 4)
      var name, value: string
      if nameIdx > 0:
        let pair = lookup(nameIdx, dec.dynTable); name = pair[0]
      else:
        name = decodeString(data, offset)
      value = decodeString(data, offset)
      result.add (name, value)

    elif (firstByte and 0xF0) == 0x10:
      # Literal never indexed (section 6.2.3)
      let nameIdx = decodeInteger(data, offset, 4)
      var name, value: string
      if nameIdx > 0:
        let pair = lookup(nameIdx, dec.dynTable); name = pair[0]
      else:
        name = decodeString(data, offset)
      value = decodeString(data, offset)
      result.add (name, value)

    elif (firstByte and 0xE0) == 0x20:
      # Dynamic table size update (section 6.3)
      let newSize = decodeInteger(data, offset, 5)
      dec.dynTable.maxSize = newSize
      dec.dynTable.evict()

    else:
      raise newException(ValueError, "Unknown HPACK encoding byte: " & $firstByte)
