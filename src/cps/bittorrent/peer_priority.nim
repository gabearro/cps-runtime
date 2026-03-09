## BEP 40: Canonical Peer Priority.
##
## Provides deterministic peer ordering for connection decisions.
## Uses CRC32C of masked IP addresses to prioritize peers consistently
## across the swarm, reducing duplicate connections.

import std/[algorithm]
import utils

proc isIpv6*(ip: string): bool {.inline.} =
  ':' in ip

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
    result = crc32c(masked)
  else:
    # IPv4: /24 mask (first 3 octets)
    let a = parseIpv4(ourIp)
    let b = parseIpv4(peerIp)
    var masked: array[4, byte]
    masked[0] = a[0] xor b[0]
    masked[1] = a[1] xor b[1]
    masked[2] = a[2] xor b[2]
    masked[3] = 0  # Last octet masked out
    result = crc32c(masked)

proc sortByPriority*(peers: var seq[tuple[ip: string, port: uint16]], ourIp: string) =
  ## Sort peers by canonical priority (lowest CRC32C first = highest priority).
  peers.sort(proc(a, b: tuple[ip: string, port: uint16]): int =
    let pa = peerPriority(ourIp, a.ip)
    let pb = peerPriority(ourIp, b.ip)
    if pa < pb: -1
    elif pa > pb: 1
    else: 0
  )
