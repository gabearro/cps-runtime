## BEP 20: Peer ID Conventions.
##
## Defines the two standard peer ID formats:
## - Azureus-style: -XX0000-xxxxxxxxxxxx (8 prefix + 12 random)
## - Shadow-style: Xnnn--xxxxxxxxxxxx (less common)
##
## Our client uses Azureus-style: -NC0100-xxxxxxxxxxxx
## NC = NimCPS, 01.00 = version 0.1.0

import std/strutils
import utils

const
  ClientId* = "NC"          ## NimCPS client identifier
  VersionMajor* = 0
  VersionMinor* = 1
  VersionPatch* = 0

type
  PeerIdInfo* = object
    clientName*: string
    version*: string
    style*: string  ## "azureus" or "shadow" or "unknown"

proc generatePeerId*(): array[20, byte] =
  ## Generate an Azureus-style peer ID: -NC0100-<12 random bytes>
  let prefix = "-" & ClientId &
               $VersionMajor & $VersionMinor &
               ($VersionPatch).align(2, '0') & "-"
  assert prefix.len == 8, "peer ID prefix must be 8 bytes"
  copyMem(addr result[0], unsafeAddr prefix[0], 8)
  for i in 8 ..< 20:
    result[i] = byte(btRandU32() and 0xFF)

proc parsePeerId*(peerId: array[20, byte]): PeerIdInfo =
  ## Parse a peer ID and try to identify the client.
  var idStr = newString(20)
  copyMem(addr idStr[0], unsafeAddr peerId[0], 20)

  # Azureus-style: -XX0000-
  if idStr[0] == '-' and idStr[7] == '-':
    let clientCode = idStr[1..2]
    let versionStr = idStr[3..6]
    result.style = "azureus"
    result.version = versionStr

    case clientCode
    of "NC": result.clientName = "NimCPS"
    of "AZ": result.clientName = "Azureus/Vuze"
    of "UT": result.clientName = "uTorrent"
    of "TR": result.clientName = "Transmission"
    of "LT": result.clientName = "libtorrent"
    of "lt": result.clientName = "libtorrent (Rasterbar)"
    of "DE": result.clientName = "Deluge"
    of "qB": result.clientName = "qBittorrent"
    of "KT": result.clientName = "KTorrent"
    of "BI": result.clientName = "BiglyBT"
    of "BT": result.clientName = "BitTorrent"
    of "FD": result.clientName = "Free Download Manager"
    of "WW": result.clientName = "WebTorrent"
    of "FL": result.clientName = "Flud"
    of "tT": result.clientName = "tTorrent"
    else:
      result.clientName = "Unknown (" & clientCode & ")"
    return

  # Shadow-style: First byte is client letter, followed by version digits
  if idStr[0] in {'A'..'Z', 'a'..'z'}:
    result.style = "shadow"
    result.clientName = case idStr[0]
      of 'A': "ABC"
      of 'M': "Mainline"
      of 'O': "Osprey"
      of 'S': "Shadow"
      of 'T': "BitTornado"
      else: "Unknown (" & idStr[0] & ")"
    # Version from bytes 1-3
    if idStr.len > 3:
      result.version = idStr[1..3]
    return

  result.style = "unknown"
  result.clientName = "Unknown"

proc peerIdToString*(peerId: array[20, byte]): string =
  ## Convert peer ID to a printable string (hex for non-printable bytes).
  for b in peerId:
    if b >= 0x20 and b <= 0x7E:
      result.add(char(b))
    else:
      result.add("\\x" & b.int.toHex(2).toLowerAscii())
