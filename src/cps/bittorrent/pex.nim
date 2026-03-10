## BEP 11: Peer Exchange (PEX).
##
## Allows peers to exchange peer lists without contacting the tracker.
## Uses the extension protocol (BEP 10) with extension name "ut_pex".

import bencode
import utils

const
  UtPexName* = "ut_pex"  ## Extension name for BEP 11
  MaxPexPeers* = 50       ## Max peers to send in a single PEX message
  PexIntervalMs* = 60000  ## Send PEX messages every 60s

type
  PexFlags* = distinct uint8

proc `or`*(a, b: PexFlags): PexFlags {.borrow.}
proc `and`*(a, b: PexFlags): PexFlags {.borrow.}
proc `not`*(a: PexFlags): PexFlags {.borrow.}
proc `==`*(a, b: PexFlags): bool {.borrow.}
proc `$`*(f: PexFlags): string = $uint8(f)

const
  pexEncryption* = PexFlags(0x01)    ## Peer supports encryption
  pexSeedOnly* = PexFlags(0x02)      ## Peer is a seed/upload-only
  pexUtp* = PexFlags(0x04)           ## Peer supports uTP
  pexHolepunch* = PexFlags(0x08)     ## Peer supports holepunch
  pexOutgoing* = PexFlags(0x10)      ## Outgoing connection
  pexNone* = PexFlags(0x00)          ## No flags set

type
  PexMessage* = object
    added*: seq[CompactPeer]
    addedFlags*: seq[uint8]
    dropped*: seq[CompactPeer]
    added6*: seq[CompactPeer]
    added6Flags*: seq[uint8]
    dropped6*: seq[CompactPeer]

proc flagsToStr(flags: openArray[uint8]): string {.inline.} =
  result = newStringOfCap(flags.len)
  for f in flags:
    result.add(char(f))

proc strToFlags(s: string): seq[uint8] {.inline.} =
  result = newSeqOfCap[uint8](s.len)
  for c in s:
    result.add(c.byte)

proc encodePexMessage*(added: openArray[CompactPeer],
                       addedFlags: openArray[uint8],
                       dropped: openArray[CompactPeer],
                       added6: openArray[CompactPeer] = [],
                       added6Flags: openArray[uint8] = [],
                       dropped6: openArray[CompactPeer] = []): string =
  ## Encode a PEX message payload (bencoded dict).
  var d = bDict()
  d["added"] = bStr(encodeCompactPeers(@added))
  d["added.f"] = bStr(flagsToStr(addedFlags))
  d["dropped"] = bStr(encodeCompactPeers(@dropped))

  if added6.len > 0:
    d["added6"] = bStr(encodeCompactPeers6(@added6))
    d["added6.f"] = bStr(flagsToStr(added6Flags))
  if dropped6.len > 0:
    d["dropped6"] = bStr(encodeCompactPeers6(@dropped6))

  encode(d)

proc decodePexMessage*(payload: string): PexMessage =
  ## Decode a PEX message payload.
  let root = decode(payload)
  if root.kind != bkDict:
    return

  let addedNode = root.getOrDefault("added")
  if addedNode != nil and addedNode.kind == bkStr:
    result.added = decodeCompactPeers(addedNode.strVal)

  let flagsNode = root.getOrDefault("added.f")
  if flagsNode != nil and flagsNode.kind == bkStr:
    result.addedFlags = strToFlags(flagsNode.strVal)

  let droppedNode = root.getOrDefault("dropped")
  if droppedNode != nil and droppedNode.kind == bkStr:
    result.dropped = decodeCompactPeers(droppedNode.strVal)

  let added6Node = root.getOrDefault("added6")
  if added6Node != nil and added6Node.kind == bkStr and added6Node.strVal.len > 0:
    result.added6 = decodeCompactPeers6(added6Node.strVal)

  let flags6Node = root.getOrDefault("added6.f")
  if flags6Node != nil and flags6Node.kind == bkStr:
    result.added6Flags = strToFlags(flags6Node.strVal)

  let dropped6Node = root.getOrDefault("dropped6")
  if dropped6Node != nil and dropped6Node.kind == bkStr and dropped6Node.strVal.len > 0:
    result.dropped6 = decodeCompactPeers6(dropped6Node.strVal)
