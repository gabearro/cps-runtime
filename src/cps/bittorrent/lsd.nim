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

proc encodeLsdAnnounce*(infoHash: array[20, byte],
                        port: uint16,
                        cookie: string = ""): string =
  ## Encode an LSD announce message (HTTP-like format).
  ## BT-SEARCH * HTTP/1.1\r\n
  ## Host: 239.192.152.143:6771\r\n
  ## Port: <port>\r\n
  ## Infohash: <hex_info_hash>\r\n
  ## cookie: <cookie>\r\n
  ## \r\n
  let hashHex = bytesToHex(infoHash)

  result = "BT-SEARCH * HTTP/1.1\r\n"
  result.add("Host: " & LsdMulticastAddr & ":" & $LsdPort & "\r\n")
  result.add("Port: " & $port & "\r\n")
  result.add("Infohash: " & hashHex & "\r\n")
  if cookie.len > 0:
    result.add("cookie: " & cookie & "\r\n")
  result.add("\r\n")

proc decodeLsdAnnounce*(data: string): seq[LsdAnnounce] =
  ## Decode one or more LSD announce messages.
  ## Returns a sequence because multiple Infohash headers are allowed.
  let lines = data.split("\r\n")
  if lines.len < 2:
    return @[]

  # First line should be "BT-SEARCH * HTTP/1.1"
  if not lines[0].startsWith("BT-SEARCH"):
    return @[]

  var port: uint16 = 0
  var cookie = ""
  var hashes: seq[array[20, byte]]

  for line in lines[1..^1]:
    if line.len == 0:
      continue
    let colonIdx = line.find(':')
    if colonIdx < 0:
      continue
    let key = line[0 ..< colonIdx].strip().toLowerAscii()
    let value = line[colonIdx+1..^1].strip()

    case key
    of "port":
      port = safeParseUint16(value)
    of "infohash":
      if value.len == 40:
        var hash: array[20, byte]
        let bytes = hexToBytes(value)
        copyMem(addr hash[0], unsafeAddr bytes[0], 20)
        hashes.add(hash)
    of "cookie":
      cookie = value

  for hash in hashes:
    result.add(LsdAnnounce(
      infoHash: hash,
      port: port,
      cookie: cookie
    ))
