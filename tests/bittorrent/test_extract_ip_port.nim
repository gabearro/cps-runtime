## Tests for extractIpPort with both IPv4 and IPv6 sockaddr.
## Mirrors the logic from client.nim extractIpPort.

import std/[nativesockets, strutils]
import cps/bittorrent/utils

proc extractIpPort(srcAddr: Sockaddr_storage, addrLen: SockLen): tuple[ip: string, port: uint16] =
  ## Copied from client.nim for isolated testing.
  if srcAddr.ss_family.cint == toInt(AF_INET6):
    let sa6 = cast[ptr Sockaddr_in6](unsafeAddr srcAddr)
    let addrBytes = cast[ptr array[16, byte]](unsafeAddr sa6.sin6_addr)
    var parts: array[8, uint16]
    for i in 0 ..< 8:
      parts[i] = (uint16(addrBytes[i*2]) shl 8) or uint16(addrBytes[i*2 + 1])
    var expanded = ""
    for i in 0 ..< 8:
      if i > 0: expanded.add(':')
      expanded.add(parts[i].int.toHex(4).toLowerAscii())
    result.ip = canonicalizeIpv6(expanded)
    result.port = ntohs(sa6.sin6_port)
  else:
    let sa = cast[ptr Sockaddr_in](unsafeAddr srcAddr)
    let addrBytes = cast[ptr array[4, byte]](addr sa.sin_addr)
    result.ip = $addrBytes[0] & "." & $addrBytes[1] & "." & $addrBytes[2] & "." & $addrBytes[3]
    result.port = ntohs(sa.sin_port)

block test_ipv4_extract:
  var ss: Sockaddr_storage
  zeroMem(addr ss, sizeof(ss))
  let sa = cast[ptr Sockaddr_in](addr ss)
  sa.sin_family = typeof(sa.sin_family)(toInt(AF_INET))
  sa.sin_port = ntohs(6881)
  let addrBytes = cast[ptr array[4, byte]](addr sa.sin_addr)
  addrBytes[0] = 192
  addrBytes[1] = 168
  addrBytes[2] = 1
  addrBytes[3] = 100

  let (ip, port) = extractIpPort(ss, SockLen(sizeof(Sockaddr_in)))
  assert ip == "192.168.1.100", "got: " & ip
  assert port == 6881, "got: " & $port
  echo "PASS: extractIpPort IPv4"

block test_ipv6_extract:
  var ss: Sockaddr_storage
  zeroMem(addr ss, sizeof(ss))
  let sa6 = cast[ptr Sockaddr_in6](addr ss)
  sa6.sin6_family = typeof(sa6.sin6_family)(toInt(AF_INET6))
  sa6.sin6_port = ntohs(6882)
  # Set address to 2001:0db8::1
  let addrBytes = cast[ptr array[16, byte]](addr sa6.sin6_addr)
  addrBytes[0] = 0x20
  addrBytes[1] = 0x01
  addrBytes[2] = 0x0d
  addrBytes[3] = 0xb8
  # bytes 4-14 are already zero
  addrBytes[15] = 0x01

  let (ip, port) = extractIpPort(ss, SockLen(sizeof(Sockaddr_in6)))
  assert ip == "2001:db8::1", "got: " & ip
  assert port == 6882, "got: " & $port
  echo "PASS: extractIpPort IPv6"

block test_ipv6_loopback:
  var ss: Sockaddr_storage
  zeroMem(addr ss, sizeof(ss))
  let sa6 = cast[ptr Sockaddr_in6](addr ss)
  sa6.sin6_family = typeof(sa6.sin6_family)(toInt(AF_INET6))
  sa6.sin6_port = ntohs(8080)
  let addrBytes = cast[ptr array[16, byte]](addr sa6.sin6_addr)
  addrBytes[15] = 0x01  # ::1

  let (ip, port) = extractIpPort(ss, SockLen(sizeof(Sockaddr_in6)))
  assert ip == "::1", "got: " & ip
  assert port == 8080, "got: " & $port
  echo "PASS: extractIpPort IPv6 loopback"

echo "ALL EXTRACT IP PORT TESTS PASSED"
