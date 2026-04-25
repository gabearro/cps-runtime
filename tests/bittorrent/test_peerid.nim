## Tests for BEP 20: Peer ID Conventions.

import std/strutils
import cps/bittorrent/peerid

block test_generate_peer_id_format:
  let id = generatePeerId()
  assert id[0] == byte('-'), "must start with dash"
  assert id[1] == byte('N'), "client code NC"
  assert id[2] == byte('C'), "client code NC"
  assert id[7] == byte('-'), "dash at position 7"
  echo "PASS: generatePeerId format"

block test_generate_peer_id_unique:
  let id1 = generatePeerId()
  let id2 = generatePeerId()
  # Random suffix should differ (20-8=12 random bytes)
  var differ = false
  for i in 8 ..< 20:
    if id1[i] != id2[i]:
      differ = true
      break
  assert differ, "two generated peer IDs should differ in random suffix"
  echo "PASS: generatePeerId uniqueness"

block test_parse_azureus_nimcps:
  let id = generatePeerId()
  let info = parsePeerId(id)
  assert info.style == pisAzureus
  assert info.clientName == "NimCPS"
  assert info.version == "0100"
  echo "PASS: parsePeerId NimCPS"

block test_parse_azureus_utorrent:
  var id: array[20, byte]
  let prefix = "-UT3560-"
  copyMem(addr id[0], unsafeAddr prefix[0], 8)
  for i in 8 ..< 20:
    id[i] = byte('A')
  let info = parsePeerId(id)
  assert info.style == pisAzureus
  assert info.clientName == "uTorrent"
  assert info.version == "3560"
  echo "PASS: parsePeerId uTorrent"

block test_parse_azureus_transmission:
  var id: array[20, byte]
  let prefix = "-TR2940-"
  copyMem(addr id[0], unsafeAddr prefix[0], 8)
  for i in 8 ..< 20:
    id[i] = byte('x')
  let info = parsePeerId(id)
  assert info.style == pisAzureus
  assert info.clientName == "Transmission"
  echo "PASS: parsePeerId Transmission"

block test_parse_azureus_qbittorrent:
  var id: array[20, byte]
  let prefix = "-qB4500-"
  copyMem(addr id[0], unsafeAddr prefix[0], 8)
  for i in 8 ..< 20:
    id[i] = byte('0')
  let info = parsePeerId(id)
  assert info.style == pisAzureus
  assert info.clientName == "qBittorrent"
  echo "PASS: parsePeerId qBittorrent"

block test_parse_azureus_unknown:
  var id: array[20, byte]
  let prefix = "-ZZ1000-"
  copyMem(addr id[0], unsafeAddr prefix[0], 8)
  for i in 8 ..< 20:
    id[i] = byte('0')
  let info = parsePeerId(id)
  assert info.style == pisAzureus
  assert info.clientName == "Unknown (ZZ)"
  echo "PASS: parsePeerId unknown Azureus client"

block test_parse_shadow_style:
  var id: array[20, byte]
  id[0] = byte('M')
  id[1] = byte('1')
  id[2] = byte('2')
  id[3] = byte('3')
  for i in 4 ..< 20:
    id[i] = byte('-')
  let info = parsePeerId(id)
  assert info.style == pisShadow
  assert info.clientName == "Mainline"
  assert info.version == "123"
  echo "PASS: parsePeerId Shadow style (Mainline)"

block test_parse_unknown:
  var id: array[20, byte]
  # All zeros - no known pattern
  let info = parsePeerId(id)
  assert info.style == pisUnknown
  assert info.clientName == "Unknown"
  echo "PASS: parsePeerId unknown style"

block test_peer_id_to_string:
  var id: array[20, byte]
  let prefix = "-NC0100-"
  copyMem(addr id[0], unsafeAddr prefix[0], 8)
  id[8] = 0x41  # 'A'
  id[9] = 0x01  # non-printable
  id[10] = 0x7E  # '~'
  let s = peerIdToString(id)
  assert s.len > 0
  assert s[0] == '-'
  # Non-printable should be hex-escaped
  assert "\\x01" in s
  echo "PASS: peerIdToString"

echo "All peerid tests passed!"
