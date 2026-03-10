## BEP 14: Local Service Discovery (LSD).
##
## Discovers peers on the local network using multicast UDP.
## Announces and listens for peers sharing the same torrent
## on the LAN without needing a tracker.

import std/strutils
import utils

const
  LsdMulticastAddr* = "239.192.152.143"
  LsdPort* = 6771
  LsdAnnounceInterval* = 300  ## Announce every 5 minutes (seconds)
  LsdMaxAnnounceRate* = 1     ## Max 1 announce per minute per torrent

type
  LsdAnnounce* = object
    infoHash*: array[20, byte]
    port*: uint16
    cookie*: string  ## Optional session cookie

proc hexToInfoHash(hex: string): array[20, byte] {.inline.} =
  ## Decode a 40-char hex string directly into a 20-byte info hash.
  for i in 0 ..< 20:
    result[i] = byte(hexDigitToInt(hex[i * 2]) shl 4 or
                     hexDigitToInt(hex[i * 2 + 1]))

proc encodeLsdAnnounce*(infoHash: array[20, byte],
                        port: uint16,
                        cookie: string = ""): string =
  ## Encode an LSD announce message (HTTP-like format per BEP 14).
  result = newStringOfCap(150)
  result.add("BT-SEARCH * HTTP/1.1\r\nHost: ")
  result.add(LsdMulticastAddr)
  result.add(":")
  result.add($LsdPort)
  result.add("\r\nPort: ")
  result.add($port)
  result.add("\r\nInfohash: ")
  result.add(bytesToHex(infoHash))
  result.add("\r\n")
  if cookie.len > 0:
    result.add("cookie: ")
    result.add(cookie)
    result.add("\r\n")
  result.add("\r\n")

proc decodeLsdAnnounce*(data: string): seq[LsdAnnounce] =
  ## Decode one or more LSD announce messages.
  ## Multiple Infohash headers produce multiple results.
  if not data.startsWith("BT-SEARCH"):
    return @[]

  var pos = data.find("\r\n")
  if pos < 0:
    return @[]
  pos += 2  # skip request line

  var port: uint16 = 0
  var cookie = ""
  var hashes: seq[array[20, byte]]

  while pos < data.len:
    let lineEnd = data.find("\r\n", pos)
    if lineEnd < 0 or lineEnd == pos:
      break  # malformed or empty line = end of headers
    let colonIdx = data.find(':', pos)
    if colonIdx > pos and colonIdx < lineEnd:
      let key = data[pos ..< colonIdx]
      let value = data[colonIdx + 1 ..< lineEnd].strip()
      if cmpIgnoreCase(key, "Port") == 0:
        port = safeParseUint16(value)
      elif cmpIgnoreCase(key, "Infohash") == 0:
        if value.len == 40:
          hashes.add(hexToInfoHash(value))
      elif cmpIgnoreCase(key, "cookie") == 0:
        cookie = value
    pos = lineEnd + 2

  result = newSeqOfCap[LsdAnnounce](hashes.len)
  for hash in hashes:
    result.add(LsdAnnounce(infoHash: hash, port: port, cookie: cookie))
