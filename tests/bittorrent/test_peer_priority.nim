## Tests for BEP 40: Canonical Peer Priority.

import cps/bittorrent/peer_priority
import cps/bittorrent/utils

proc testCrc32c() =
  # Known CRC32C values
  let empty: seq[byte] = @[]
  assert crc32c(empty) == 0x00000000'u32

  let data = [0x31'u8, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39]  # "123456789"
  assert crc32c(data) == 0xE3069283'u32
  echo "PASS: CRC32C known vectors"

proc testPeerPriority() =
  # Same subnet should give same priority (last octet masked)
  let p1 = peerPriority("192.168.1.1", "10.0.0.1")
  let p2 = peerPriority("192.168.1.1", "10.0.0.200")
  assert p1 == p2, "same /24 subnet should have same priority"

  # Different subnets should give different priorities
  let p3 = peerPriority("192.168.1.1", "10.0.1.1")
  assert p1 != p3, "different subnets should have different priorities"
  echo "PASS: peer priority /24 masking"

proc testSortByPriority() =
  var peers: seq[CompactPeer] = @[
    ("10.0.0.1", 6881'u16),
    ("172.16.0.1", 6881'u16),
    ("192.168.0.1", 6881'u16),
    ("8.8.8.8", 6881'u16),
  ]
  sortByPriority(peers, "192.168.1.1")
  # Just verify it doesn't crash and produces a deterministic order
  assert peers.len == 4
  # Running twice should give the same order
  var peers2 = peers
  sortByPriority(peers2, "192.168.1.1")
  for i in 0 ..< peers.len:
    assert peers[i].ip == peers2[i].ip, "sort should be deterministic"
  echo "PASS: sort by priority is deterministic"

proc testPrioritySymmetric() =
  # BEP 40: priority(A, B) == priority(B, A) because XOR is commutative
  let p1 = peerPriority("192.168.1.1", "10.0.0.1")
  let p2 = peerPriority("10.0.0.1", "192.168.1.1")
  assert p1 == p2, "peer priority should be symmetric"
  echo "PASS: peer priority is symmetric"

testCrc32c()
testPeerPriority()
testSortByPriority()
testPrioritySymmetric()

echo ""
echo "All peer priority tests passed!"
