## BEP 40: Canonical Peer Priority.
##
## Provides deterministic peer ordering for connection decisions.
## Uses CRC32C of masked IP addresses to prioritize peers consistently
## across the swarm, reducing duplicate connections.

import std/algorithm
import utils

proc peerPriority*(ourIp, peerIp: string): uint32 =
  ## Compute canonical peer priority (BEP 40).
  ## Lower value = higher priority.
  ## Supports both IPv4 (/24 mask) and IPv6 (/48 mask).
  if isIpv6(peerIp) or isIpv6(ourIp):
    # IPv6: BEP 40 uses /48 mask (first 3 groups)
    let a = parseIpv6Words(ourIp)
    let b = parseIpv6Words(peerIp)
    var masked: array[6, byte]
    for i in 0 ..< 3:
      let x = a[i] xor b[i]
      masked[i * 2] = byte((x shr 8) and 0xFF)
      masked[i * 2 + 1] = byte(x and 0xFF)
    crc32c(masked)
  else:
    # IPv4: /24 mask (first 3 octets)
    let a = parseIpv4(ourIp)
    let b = parseIpv4(peerIp)
    var masked: array[4, byte]
    for i in 0 ..< 3:
      masked[i] = a[i] xor b[i]
    crc32c(masked)

proc sortByPriority*(peers: var seq[CompactPeer], ourIp: string) =
  ## Sort peers by canonical priority (lowest CRC32C first = highest priority).
  ## Computes each priority once via decorate-sort-undecorate.
  var keyed = newSeqOfCap[(uint32, int)](peers.len)
  for i in 0 ..< peers.len:
    keyed.add((peerPriority(ourIp, peers[i].ip), i))
  keyed.sort(proc(a, b: (uint32, int)): int = cmp(a[0], b[0]))
  var sorted = newSeq[CompactPeer](peers.len)
  for i in 0 ..< keyed.len:
    sorted[i] = peers[keyed[i][1]]
  peers = sorted
