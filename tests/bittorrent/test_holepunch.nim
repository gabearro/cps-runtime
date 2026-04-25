## Tests for BEP 55: Holepunch Extension.

import cps/bittorrent/holepunch

block test_rendezvous_ipv4_roundtrip:
  let msg = rendezvousMsg("192.168.1.100", 6881)
  assert msg.msgType == HpRendezvous
  assert msg.addrType == AddrIPv4
  assert msg.port == 6881
  assert msg.errCode == 0

  let encoded = encodeHolepunchMsg(msg)
  assert encoded.len == 12  # 1+1+4+2+4
  let decoded = decodeHolepunchMsg(encoded)
  assert decoded.msgType == HpRendezvous
  assert decoded.addrType == AddrIPv4
  assert decoded.ip == "192.168.1.100"
  assert decoded.port == 6881
  assert decoded.errCode == 0
  echo "PASS: rendezvous IPv4 roundtrip"

block test_connect_ipv4_roundtrip:
  let msg = connectMsg("10.0.0.1", 51413)
  let encoded = encodeHolepunchMsg(msg)
  let decoded = decodeHolepunchMsg(encoded)
  assert decoded.msgType == HpConnect
  assert decoded.ip == "10.0.0.1"
  assert decoded.port == 51413
  assert decoded.errCode == 0
  echo "PASS: connect IPv4 roundtrip"

block test_error_msg_roundtrip:
  let msg = errorMsg("172.16.0.50", 8080, HpErrNotConnected)
  let encoded = encodeHolepunchMsg(msg)
  let decoded = decodeHolepunchMsg(encoded)
  assert decoded.msgType == HpError
  assert decoded.ip == "172.16.0.50"
  assert decoded.port == 8080
  assert decoded.errCode == HpErrNotConnected
  echo "PASS: error message roundtrip"

block test_all_error_codes:
  for code in [HpErrNoSuchPeer, HpErrNotConnected, HpErrNoSupport, HpErrNoSelf]:
    let msg = errorMsg("1.2.3.4", 1234, code)
    let encoded = encodeHolepunchMsg(msg)
    let decoded = decodeHolepunchMsg(encoded)
    assert decoded.errCode == code
  echo "PASS: all error codes"

block test_error_names:
  assert errorName(HpErrNoSuchPeer) == "NoSuchPeer"
  assert errorName(HpErrNotConnected) == "NotConnected"
  assert errorName(HpErrNoSupport) == "NoSupport"
  assert errorName(HpErrNoSelf) == "NoSelf"
  assert errorName(99) == "Unknown(99)"
  echo "PASS: error names"

block test_ipv6_roundtrip:
  let msg = rendezvousMsg("2001:0db8:0000:0000:0000:0000:0000:0001", 6882)
  assert msg.addrType == AddrIPv6

  let encoded = encodeHolepunchMsg(msg)
  assert encoded.len == 24  # 1+1+16+2+4
  let decoded = decodeHolepunchMsg(encoded)
  assert decoded.msgType == HpRendezvous
  assert decoded.addrType == AddrIPv6
  assert decoded.port == 6882
  assert decoded.errCode == 0
  # IPv6 addresses are canonicalized to RFC 5952 compressed form
  assert decoded.ip == "2001:db8::1"
  echo "PASS: IPv6 roundtrip"

block test_too_short_message:
  var caught = false
  try:
    discard decodeHolepunchMsg("x")
  except ValueError:
    caught = true
  assert caught
  echo "PASS: too short message"

block test_too_short_ipv4:
  var caught = false
  try:
    # msg_type + addr_type + partial address
    discard decodeHolepunchMsg("\x00\x00\x01\x02")
  except ValueError:
    caught = true
  assert caught
  echo "PASS: too short IPv4 message"

block test_port_encoding:
  # Test high port number
  let msg = connectMsg("255.255.255.255", 65535)
  let encoded = encodeHolepunchMsg(msg)
  let decoded = decodeHolepunchMsg(encoded)
  assert decoded.ip == "255.255.255.255"
  assert decoded.port == 65535
  echo "PASS: port encoding (max port)"

block test_zero_address:
  let msg = connectMsg("0.0.0.0", 0)
  let encoded = encodeHolepunchMsg(msg)
  let decoded = decodeHolepunchMsg(encoded)
  assert decoded.ip == "0.0.0.0"
  assert decoded.port == 0
  echo "PASS: zero address"

block test_constants:
  assert UtHolepunchName == "ut_holepunch"
  assert HpRendezvous == 0x00
  assert HpConnect == 0x01
  assert HpError == 0x02
  echo "PASS: constants"

echo "All holepunch tests passed!"
