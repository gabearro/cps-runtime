## Advanced tests for PEX (BEP 11) and LSD (BEP 14) edge cases.

import std/[strutils, tables]
import cps/bittorrent/pex
import cps/bittorrent/lsd
import cps/bittorrent/bencode
import cps/bittorrent/utils

# === PEX edge cases ===

block test_pex_empty_peers:
  ## Encoding empty peer lists.
  let encoded = encodeCompactPeers(@[])
  assert encoded.len == 0
  let decoded = decodeCompactPeers(encoded)
  assert decoded.len == 0
  echo "PASS: PEX empty peers"

block test_pex_decode_invalid_length:
  ## Non-6-byte-aligned data returns empty.
  let decoded = decodeCompactPeers("12345")  # 5 bytes
  assert decoded.len == 0
  echo "PASS: PEX decode invalid length"

block test_pex_skip_invalid_ip:
  ## Peers with non-4-octet IPs are skipped during encoding.
  var peers: seq[tuple[ip: string, port: uint16]]
  peers.add(("192.168.1.1", 6881'u16))      # Valid
  peers.add(("invalid_ip", 6882'u16))        # Invalid - skipped
  peers.add(("10.0.0.1", 6883'u16))          # Valid

  let encoded = encodeCompactPeers(peers)
  assert encoded.len == 12, "only 2 valid peers encoded: " & $encoded.len
  let decoded = decodeCompactPeers(encoded)
  assert decoded.len == 2
  assert decoded[0].ip == "192.168.1.1"
  assert decoded[1].ip == "10.0.0.1"
  echo "PASS: PEX skip invalid IP"

block test_pex_message_empty_added:
  ## PEX message with only dropped peers.
  let msg = encodePexMessage(@[], @[], @[("9.10.11.12", 6881'u16)])
  let decoded = decodePexMessage(msg)
  assert decoded.added.len == 0
  assert decoded.addedFlags.len == 0
  assert decoded.dropped.len == 1
  assert decoded.dropped[0].ip == "9.10.11.12"
  echo "PASS: PEX message empty added"

block test_pex_message_empty_dropped:
  ## PEX message with only added peers.
  let added = @[("1.2.3.4", 6881'u16)]
  let flags = @[0x05'u8]  # uTP + encryption
  let msg = encodePexMessage(added, flags, @[])
  let decoded = decodePexMessage(msg)
  assert decoded.added.len == 1
  assert decoded.addedFlags.len == 1
  assert decoded.addedFlags[0] == 0x05
  assert decoded.dropped.len == 0
  echo "PASS: PEX message empty dropped"

block test_pex_message_all_empty:
  ## Completely empty PEX message.
  let msg = encodePexMessage(@[], @[], @[])
  let decoded = decodePexMessage(msg)
  assert decoded.added.len == 0
  assert decoded.addedFlags.len == 0
  assert decoded.dropped.len == 0
  echo "PASS: PEX message all empty"

block test_pex_all_flag_combinations:
  ## Test all PEX flag constants.
  let added = @[
    ("1.1.1.1", 1'u16),
    ("2.2.2.2", 2'u16),
    ("3.3.3.3", 3'u16),
    ("4.4.4.4", 4'u16),
    ("5.5.5.5", 5'u16)
  ]
  let flags = @[
    uint8(pexEncryption),   # 0x01
    uint8(pexSeedOnly),     # 0x02
    uint8(pexUtp),          # 0x04
    uint8(pexHolepunch),    # 0x08
    uint8(pexOutgoing)      # 0x10
  ]
  let msg = encodePexMessage(added, flags, @[])
  let decoded = decodePexMessage(msg)
  assert decoded.addedFlags.len == 5
  assert decoded.addedFlags[0] == 0x01
  assert decoded.addedFlags[1] == 0x02
  assert decoded.addedFlags[2] == 0x04
  assert decoded.addedFlags[3] == 0x08
  assert decoded.addedFlags[4] == 0x10
  echo "PASS: PEX all flag combinations"

block test_pex_combined_flags:
  ## Test combined PEX flags.
  let added = @[("1.1.1.1", 1'u16)]
  let flags = @[uint8(pexEncryption) or uint8(pexUtp) or uint8(pexOutgoing)]  # 0x01 | 0x04 | 0x10 = 0x15
  let msg = encodePexMessage(added, flags, @[])
  let decoded = decodePexMessage(msg)
  assert decoded.addedFlags[0] == 0x15
  echo "PASS: PEX combined flags"

block test_pex_many_peers:
  ## Encode and decode many peers.
  var added: seq[tuple[ip: string, port: uint16]]
  var flags: seq[uint8]
  for i in 0 ..< 50:
    added.add(("10.0." & $(i div 256) & "." & $(i mod 256), uint16(6881 + i)))
    flags.add(0x01'u8)

  let msg = encodePexMessage(added, flags, @[])
  let decoded = decodePexMessage(msg)
  assert decoded.added.len == 50
  assert decoded.addedFlags.len == 50
  for i in 0 ..< 50:
    assert decoded.added[i].port == uint16(6881 + i)
  echo "PASS: PEX many peers"

block test_pex_decode_non_dict:
  ## Decoding a non-dict payload should return empty.
  let payload = encode(bStr("not a dict"))
  let decoded = decodePexMessage(payload)
  assert decoded.added.len == 0
  assert decoded.dropped.len == 0
  echo "PASS: PEX decode non-dict"

block test_pex_decode_missing_fields:
  ## PEX message with only some fields present.
  var d = initTable[string, BencodeValue]()
  # Only "added", no "added.f" or "dropped"
  var peerData = ""
  peerData.add(char(1)); peerData.add(char(2)); peerData.add(char(3)); peerData.add(char(4))
  peerData.add(char(0x1A'u8)); peerData.add(char(0xE1'u8))
  d["added"] = bStr(peerData)

  let encoded = encode(bDict(d))
  let decoded = decodePexMessage(encoded)
  assert decoded.added.len == 1
  assert decoded.added[0].ip == "1.2.3.4"
  assert decoded.added[0].port == 6881
  assert decoded.addedFlags.len == 0, "no flags field"
  assert decoded.dropped.len == 0, "no dropped field"
  echo "PASS: PEX decode missing fields"

# === LSD edge cases ===

block test_lsd_no_cookie:
  ## LSD announce without a cookie.
  var hash: array[20, byte]
  hash[0] = 0xAB
  let msg = encodeLsdAnnounce(hash, 6881)
  assert "cookie:" notin msg
  let decoded = decodeLsdAnnounce(msg)
  assert decoded.len == 1
  assert decoded[0].port == 6881
  assert decoded[0].cookie == ""
  echo "PASS: LSD no cookie"

block test_lsd_multiple_infohashes:
  ## LSD message with multiple Infohash headers (spec allows this).
  var hash1: array[20, byte]
  hash1[0] = 0x11
  var hash2: array[20, byte]
  hash2[0] = 0x22

  # Build manually since encodeLsdAnnounce only supports one hash
  var hashHex1 = ""
  for b in hash1: hashHex1.add(b.int.toHex(2).toLowerAscii())
  var hashHex2 = ""
  for b in hash2: hashHex2.add(b.int.toHex(2).toLowerAscii())

  var msg = "BT-SEARCH * HTTP/1.1\r\n"
  msg.add("Host: 239.192.152.143:6771\r\n")
  msg.add("Port: 6881\r\n")
  msg.add("Infohash: " & hashHex1 & "\r\n")
  msg.add("Infohash: " & hashHex2 & "\r\n")
  msg.add("\r\n")

  let decoded = decodeLsdAnnounce(msg)
  assert decoded.len == 2, "two infohashes: " & $decoded.len
  assert decoded[0].infoHash[0] == 0x11
  assert decoded[1].infoHash[0] == 0x22
  assert decoded[0].port == 6881
  assert decoded[1].port == 6881
  echo "PASS: LSD multiple infohashes"

block test_lsd_empty_message:
  let decoded = decodeLsdAnnounce("")
  assert decoded.len == 0
  echo "PASS: LSD empty message"

block test_lsd_malformed_first_line:
  let decoded = decodeLsdAnnounce("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n")
  assert decoded.len == 0
  echo "PASS: LSD malformed first line"

block test_lsd_case_insensitive_headers:
  ## Header keys should be parsed case-insensitively.
  var hash: array[20, byte]
  hash[0] = 0xCC
  var hashHex = ""
  for b in hash: hashHex.add(b.int.toHex(2).toLowerAscii())

  var msg = "BT-SEARCH * HTTP/1.1\r\n"
  msg.add("HOST: 239.192.152.143:6771\r\n")
  msg.add("PORT: 9999\r\n")
  msg.add("INFOHASH: " & hashHex & "\r\n")
  msg.add("COOKIE: testval\r\n")
  msg.add("\r\n")

  let decoded = decodeLsdAnnounce(msg)
  assert decoded.len == 1
  assert decoded[0].port == 9999
  assert decoded[0].cookie == "testval"
  assert decoded[0].infoHash[0] == 0xCC
  echo "PASS: LSD case-insensitive headers"

block test_lsd_upper_hex_infohash:
  ## Upper-case hex in Infohash header should parse correctly.
  var hash: array[20, byte]
  hash[0] = 0xAB; hash[19] = 0xCD
  var hashHex = ""
  for b in hash: hashHex.add(b.int.toHex(2).toUpperAscii())  # Upper-case

  var msg = "BT-SEARCH * HTTP/1.1\r\n"
  msg.add("Host: 239.192.152.143:6771\r\n")
  msg.add("Port: 6881\r\n")
  msg.add("Infohash: " & hashHex & "\r\n")
  msg.add("\r\n")

  let decoded = decodeLsdAnnounce(msg)
  assert decoded.len == 1
  assert decoded[0].infoHash[0] == 0xAB
  assert decoded[0].infoHash[19] == 0xCD
  echo "PASS: LSD upper-case hex infohash"

block test_lsd_invalid_infohash_length:
  ## Infohash not 40 hex chars should be skipped.
  var msg = "BT-SEARCH * HTTP/1.1\r\n"
  msg.add("Host: 239.192.152.143:6771\r\n")
  msg.add("Port: 6881\r\n")
  msg.add("Infohash: abcdef\r\n")  # Only 6 chars, not 40
  msg.add("\r\n")

  let decoded = decodeLsdAnnounce(msg)
  assert decoded.len == 0, "invalid-length infohash skipped"
  echo "PASS: LSD invalid infohash length"

block test_lsd_extra_headers_ignored:
  ## Unknown headers should be silently ignored.
  var hash: array[20, byte]
  hash[0] = 0xDD
  var hashHex = ""
  for b in hash: hashHex.add(b.int.toHex(2).toLowerAscii())

  var msg = "BT-SEARCH * HTTP/1.1\r\n"
  msg.add("Host: 239.192.152.143:6771\r\n")
  msg.add("Port: 6881\r\n")
  msg.add("X-Custom: something\r\n")
  msg.add("Infohash: " & hashHex & "\r\n")
  msg.add("X-Other: value\r\n")
  msg.add("\r\n")

  let decoded = decodeLsdAnnounce(msg)
  assert decoded.len == 1
  assert decoded[0].infoHash[0] == 0xDD
  echo "PASS: LSD extra headers ignored"

block test_lsd_port_zero:
  var hash: array[20, byte]
  hash[0] = 0xEE
  let msg = encodeLsdAnnounce(hash, 0)
  let decoded = decodeLsdAnnounce(msg)
  assert decoded.len == 1
  assert decoded[0].port == 0
  echo "PASS: LSD port zero"

block test_lsd_port_max:
  var hash: array[20, byte]
  hash[0] = 0xFF
  let msg = encodeLsdAnnounce(hash, 65535)
  let decoded = decodeLsdAnnounce(msg)
  assert decoded.len == 1
  assert decoded[0].port == 65535
  echo "PASS: LSD port max"

block test_lsd_constants:
  ## Verify LSD constants match spec.
  assert LsdMulticastAddr == "239.192.152.143"
  assert LsdPort == 6771
  assert LsdAnnounceInterval == 300
  assert LsdMaxAnnounceRate == 1
  echo "PASS: LSD constants"

block test_pex_constants:
  ## Verify PEX constants.
  assert UtPexName == "ut_pex"
  assert MaxPexPeers == 50
  assert PexIntervalMs == 60000
  assert uint8(pexEncryption) == 0x01
  assert uint8(pexSeedOnly) == 0x02
  assert uint8(pexUtp) == 0x04
  assert uint8(pexHolepunch) == 0x08
  assert uint8(pexOutgoing) == 0x10
  echo "PASS: PEX constants"

echo ""
echo "All PEX/LSD advanced tests passed!"
