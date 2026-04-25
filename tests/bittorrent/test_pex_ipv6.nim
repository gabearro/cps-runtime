## Tests for IPv6 PEX support (BEP 11 added6/dropped6).

import cps/bittorrent/pex
import cps/bittorrent/utils

block test_ipv6_compact_peers_roundtrip:
  let peers = @[
    (ip: "2001:db8::1", port: 6881'u16),
    (ip: "fe80::abcd", port: 51413'u16)
  ]
  let encoded = encodeCompactPeers6(peers)
  assert encoded.len == 36  # 2 * 18 bytes
  let decoded = decodeCompactPeers6(encoded)
  assert decoded.len == 2
  assert decoded[0].port == 6881
  assert decoded[1].port == 51413
  echo "PASS: IPv6 compact peers roundtrip"

block test_pex_message_with_ipv6:
  let added = @[(ip: "10.0.0.1", port: 6881'u16)]
  let flags = @[0x04'u8]  # uTP
  let dropped: seq[tuple[ip: string, port: uint16]] = @[]
  let added6 = @[(ip: "2001:db8::1", port: 6882'u16)]
  let flags6 = @[0x08'u8]  # holepunch
  let dropped6: seq[tuple[ip: string, port: uint16]] = @[]

  let payload = encodePexMessage(added, flags, dropped, added6, flags6, dropped6)
  let msg = decodePexMessage(payload)

  # IPv4
  assert msg.added.len == 1
  assert msg.added[0].ip == "10.0.0.1"
  assert msg.added[0].port == 6881
  assert msg.addedFlags.len == 1
  assert msg.addedFlags[0] == 0x04

  # IPv6
  assert msg.added6.len == 1
  assert msg.added6[0].port == 6882
  assert msg.added6Flags.len == 1
  assert msg.added6Flags[0] == 0x08

  assert msg.dropped.len == 0
  assert msg.dropped6.len == 0
  echo "PASS: PEX message with IPv6 peers"

block test_pex_message_ipv4_only_backward_compat:
  # Ensure backward compatibility: IPv4-only messages still decode correctly.
  let added = @[(ip: "10.0.0.2", port: 6881'u16)]
  let flags = @[0x01'u8]
  let dropped: seq[tuple[ip: string, port: uint16]] = @[]

  let payload = encodePexMessage(added, flags, dropped)
  let msg = decodePexMessage(payload)

  assert msg.added.len == 1
  assert msg.added6.len == 0
  assert msg.dropped6.len == 0
  echo "PASS: IPv4-only PEX backward compatible"

block test_pex_message_ipv6_dropped:
  let added: seq[tuple[ip: string, port: uint16]] = @[]
  let flags: seq[uint8] = @[]
  let dropped: seq[tuple[ip: string, port: uint16]] = @[]
  let added6: seq[tuple[ip: string, port: uint16]] = @[]
  let flags6: seq[uint8] = @[]
  let dropped6 = @[(ip: "fe80::dead", port: 9999'u16)]

  let payload = encodePexMessage(added, flags, dropped, added6, flags6, dropped6)
  let msg = decodePexMessage(payload)

  assert msg.dropped6.len == 1
  assert msg.dropped6[0].port == 9999
  echo "PASS: PEX message with IPv6 dropped peers"

# === IPv6 routability tests (mirrors isPublicIpv6 in client.nim) ===

proc isPublicIpv6(ip: string): bool =
  ## Mirror of logic in client.nim for testing.
  if ip.len == 0 or ':' notin ip:
    return false
  try:
    let words = parseIpv6Words(ip)
    var allZero = true
    for w in words:
      if w != 0: allZero = false
    if allZero: return false
    var isLoopback = true
    for i in 0 ..< 7:
      if words[i] != 0: isLoopback = false
    if isLoopback and words[7] == 1: return false
    if (words[0] and 0xFFC0'u16) == 0xFE80'u16: return false
    if (words[0] and 0xFE00'u16) == 0xFC00'u16: return false
    if (words[0] and 0xFF00'u16) == 0xFF00'u16: return false
    return true
  except CatchableError:
    return false

block test_ipv6_public_accepted:
  assert isPublicIpv6("2001:db8::1")
  assert isPublicIpv6("2607:f8b0:4004:800::200e")  # Google
  echo "PASS: public IPv6 addresses accepted"

block test_ipv6_loopback_rejected:
  assert not isPublicIpv6("::1")
  echo "PASS: IPv6 loopback rejected"

block test_ipv6_unspecified_rejected:
  assert not isPublicIpv6("::")
  echo "PASS: IPv6 unspecified rejected"

block test_ipv6_link_local_rejected:
  assert not isPublicIpv6("fe80::1")
  assert not isPublicIpv6("fe80::abcd:1234")
  echo "PASS: IPv6 link-local rejected"

block test_ipv6_unique_local_rejected:
  assert not isPublicIpv6("fc00::1")
  assert not isPublicIpv6("fd00::1")
  echo "PASS: IPv6 unique-local rejected"

block test_ipv6_multicast_rejected:
  assert not isPublicIpv6("ff02::1")
  assert not isPublicIpv6("ff0e::1")
  echo "PASS: IPv6 multicast rejected"

block test_ipv6_empty_and_ipv4_rejected:
  assert not isPublicIpv6("")
  assert not isPublicIpv6("8.8.8.8")
  echo "PASS: empty/IPv4 rejected by isPublicIpv6"

echo "ALL PEX IPV6 TESTS PASSED"
