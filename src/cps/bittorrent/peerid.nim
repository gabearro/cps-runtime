## BEP 20: Peer ID Conventions.
##
## Defines the two standard peer ID formats:
## - Azureus-style: -XX0000-xxxxxxxxxxxx (8 prefix + 12 random)
## - Shadow-style: Xnnn--xxxxxxxxxxxx (less common)
##
## Our client uses Azureus-style: -NC0100-xxxxxxxxxxxx
## NC = NimCPS, 01.00 = version 0.1.0

import utils

const
  ClientId* = "NC"          ## NimCPS client identifier
  VersionMajor* = 0
  VersionMinor* = 1
  VersionPatch* = 0
  PeerIdPrefix: array[8, byte] = [
    byte('-'), byte('N'), byte('C'),
    byte('0'), byte('1'), byte('0'), byte('0'),
    byte('-')
  ]

type
  PeerIdStyle* = enum
    pisAzureus = "azureus"
    pisShadow = "shadow"
    pisUnknown = "unknown"

  PeerIdInfo* = object
    clientName*: string
    version*: string
    style*: PeerIdStyle

proc generatePeerId*(): array[20, byte] =
  ## Generate an Azureus-style peer ID: -NC0100-<12 random bytes>
  copyMem(addr result[0], unsafeAddr PeerIdPrefix[0], 8)
  for i in 8 ..< 20:
    result[i] = byte(btRandU32())

proc parsePeerId*(peerId: array[20, byte]): PeerIdInfo =
  ## Parse a peer ID and try to identify the client.
  # Azureus-style: -XX0000-
  if peerId[0] == byte('-') and peerId[7] == byte('-'):
    var clientCode = newString(2)
    clientCode[0] = char(peerId[1])
    clientCode[1] = char(peerId[2])
    var versionStr = newString(4)
    for i in 0 ..< 4:
      versionStr[i] = char(peerId[3 + i])

    result.style = pisAzureus
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
  let firstChar = char(peerId[0])
  if firstChar in {'A'..'Z', 'a'..'z'}:
    result.style = pisShadow
    result.clientName = case firstChar
      of 'A': "ABC"
      of 'M': "Mainline"
      of 'O': "Osprey"
      of 'S': "Shadow"
      of 'T': "BitTornado"
      else: "Unknown (" & firstChar & ")"
    var versionStr = newString(3)
    for i in 0 ..< 3:
      versionStr[i] = char(peerId[1 + i])
    result.version = versionStr
    return

  result.style = pisUnknown
  result.clientName = "Unknown"

proc peerIdToString*(peerId: array[20, byte]): string =
  ## Convert peer ID to a printable string (hex for non-printable bytes).
  const HexChars = "0123456789abcdef"
  result = newStringOfCap(20 * 4)
  for b in peerId:
    if b >= 0x20 and b <= 0x7E:
      result.add(char(b))
    else:
      result.add('\\')
      result.add('x')
      result.add(HexChars[int(b shr 4)])
      result.add(HexChars[int(b and 0x0F)])
