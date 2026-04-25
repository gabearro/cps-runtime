## Tests for holepunch message validation.

import cps/bittorrent/holepunch

block test_valid_ipv4_addr_type:
  let msg = connectMsg("1.2.3.4", 6881)
  let encoded = encodeHolepunchMsg(msg)
  let decoded = decodeHolepunchMsg(encoded)
  assert decoded.addrType == AddrIPv4
  assert decoded.ip == "1.2.3.4"
  echo "PASS: valid IPv4 addr_type accepted"

block test_valid_ipv6_addr_type:
  let msg = connectMsg("2001:db8::1", 6882)
  let encoded = encodeHolepunchMsg(msg)
  let decoded = decodeHolepunchMsg(encoded)
  assert decoded.addrType == AddrIPv6
  echo "PASS: valid IPv6 addr_type accepted"

block test_invalid_addr_type_2:
  # Craft a message with addr_type = 2 (invalid per BEP 55)
  var data = "\x01\x02"  # HpConnect, addr_type=2
  data.add("\x00\x00\x00\x00")  # 4 bytes fake addr
  data.add("\x00\x50")          # port
  data.add("\x00\x00\x00\x00")  # error code
  var caught = false
  try:
    discard decodeHolepunchMsg(data)
  except ValueError:
    caught = true
  assert caught, "addr_type=2 should be rejected"
  echo "PASS: invalid addr_type=2 rejected"

block test_invalid_addr_type_255:
  var data = "\x00\xFF"  # HpRendezvous, addr_type=255
  data.add("\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00") # 16 bytes
  data.add("\x00\x50")  # port
  data.add("\x00\x00\x00\x00")  # error code
  var caught = false
  try:
    discard decodeHolepunchMsg(data)
  except ValueError:
    caught = true
  assert caught, "addr_type=255 should be rejected"
  echo "PASS: invalid addr_type=255 rejected"

block test_encode_invalid_addr_type:
  ## Encode should also reject invalid addr_type (not just decode).
  let msg = HolepunchMsg(
    msgType: HpConnect,
    addrType: 0x03,
    ip: "1.2.3.4",
    port: 6881,
    errCode: 0
  )
  var caught = false
  try:
    discard encodeHolepunchMsg(msg)
  except ValueError:
    caught = true
  assert caught, "encode should reject addr_type=3"
  echo "PASS: encode rejects invalid addr_type"

echo "ALL HOLEPUNCH VALIDATION TESTS PASSED"
