## BEP 11: Peer Exchange (PEX).
##
## Allows peers to exchange peer lists without contacting the tracker.
## Uses the extension protocol (BEP 10) with extension name "ut_pex".

import std/tables
import bencode
import utils

const
  UtPexName* = "ut_pex"  ## Extension name for BEP 11
  MaxPexPeers* = 50       ## Max peers to send in a single PEX message
  PexIntervalMs* = 60000  ## Send PEX messages every 60s

type
  PexFlags* = distinct uint8

const
  pexEncryption* = PexFlags(0x01)    ## Peer supports encryption
  pexSeedOnly* = PexFlags(0x02)      ## Peer is a seed/upload-only
  pexUtp* = PexFlags(0x04)           ## Peer supports uTP
  pexHolepunch* = PexFlags(0x08)     ## Peer supports holepunch
  pexOutgoing* = PexFlags(0x10)      ## Outgoing connection

proc encodePexPeers*(peers: seq[tuple[ip: string, port: uint16]]): string =
  encodeCompactPeers(peers)

proc decodePexPeers*(data: string): seq[tuple[ip: string, port: uint16]] =
  decodeCompactPeers(data)

proc encodePexMessage*(added: seq[tuple[ip: string, port: uint16]],
                       addedFlags: seq[uint8],
                       dropped: seq[tuple[ip: string, port: uint16]],
                       added6: seq[tuple[ip: string, port: uint16]] = @[],
                       added6Flags: seq[uint8] = @[],
                       dropped6: seq[tuple[ip: string, port: uint16]] = @[]): string =
  ## Encode a PEX message payload (bencoded dict).
  var d = initTable[string, BencodeValue]()
  d["added"] = bStr(encodePexPeers(added))

  # Flags for each added peer
  var flagsStr = ""
  for f in addedFlags:
    flagsStr.add(char(f))
  d["added.f"] = bStr(flagsStr)

  d["dropped"] = bStr(encodePexPeers(dropped))

  # IPv6 peers (BEP 11)
  if added6.len > 0:
    d["added6"] = bStr(encodeCompactPeers6(added6))
    var flags6Str = ""
    for f in added6Flags:
      flags6Str.add(char(f))
    d["added6.f"] = bStr(flags6Str)
  if dropped6.len > 0:
    d["dropped6"] = bStr(encodeCompactPeers6(dropped6))

  return encode(bDict(d))

proc decodePexMessage*(payload: string): tuple[
    added: seq[tuple[ip: string, port: uint16]],
    addedFlags: seq[uint8],
    dropped: seq[tuple[ip: string, port: uint16]],
    added6: seq[tuple[ip: string, port: uint16]],
    added6Flags: seq[uint8],
    dropped6: seq[tuple[ip: string, port: uint16]]] =
  ## Decode a PEX message payload.
  let root = decode(payload)
  if root.kind != bkDict:
    return

  let addedNode = root.getOrDefault("added")
  if addedNode != nil and addedNode.kind == bkStr:
    result.added = decodePexPeers(addedNode.strVal)

  let flagsNode = root.getOrDefault("added.f")
  if flagsNode != nil and flagsNode.kind == bkStr:
    for c in flagsNode.strVal:
      result.addedFlags.add(c.byte)

  let droppedNode = root.getOrDefault("dropped")
  if droppedNode != nil and droppedNode.kind == bkStr:
    result.dropped = decodePexPeers(droppedNode.strVal)

  # IPv6 peers (BEP 11)
  let added6Node = root.getOrDefault("added6")
  if added6Node != nil and added6Node.kind == bkStr and added6Node.strVal.len > 0:
    result.added6 = decodeCompactPeers6(added6Node.strVal)

  let flags6Node = root.getOrDefault("added6.f")
  if flags6Node != nil and flags6Node.kind == bkStr:
    for c in flags6Node.strVal:
      result.added6Flags.add(c.byte)

  let dropped6Node = root.getOrDefault("dropped6")
  if dropped6Node != nil and dropped6Node.kind == bkStr and dropped6Node.strVal.len > 0:
    result.dropped6 = decodeCompactPeers6(dropped6Node.strVal)
