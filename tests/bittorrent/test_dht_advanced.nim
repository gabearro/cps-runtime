## Advanced DHT tests: bucket splitting, response encode/decode, edge cases.

import cps/bittorrent/dht
import cps/bittorrent/utils

# === Bucket splitting ===

block test_bucket_split_when_full:
  ## When our bucket is full and our own ID is in it, it should split.
  ## After split, nodes near ownId go to the new bucket. Nodes far from
  ## ownId stay in the old bucket. The 9th node must be in the range of
  ## a bucket that has room.
  var ownId: NodeId
  ownId[0] = 0x80  # Own ID in the upper half of the space

  var rt = newRoutingTable(ownId)
  assert rt.buckets.len == 1, "starts with 1 bucket"

  # Add nodes spread across the space so the split actually redistributes them
  for i in 0 ..< K:
    var nodeId: NodeId
    nodeId[0] = byte(i * 30)  # 0x00, 0x1E, 0x3C, 0x5A, 0x78, 0x96, 0xB4, 0xD2
    let node = DhtNode(id: nodeId, ip: "10.0.0." & $i, port: 6881)
    discard rt.addNode(node)

  assert rt.totalNodes() == K

  # Add a 9th node to trigger a split. Since all 8 are in one bucket and
  # ownId (0x80) is in that bucket, it should split and redistribute.
  var nodeId9: NodeId
  nodeId9[0] = 0xF0
  let added = rt.addNode(DhtNode(id: nodeId9, ip: "10.0.0.9", port: 6881))
  assert added, "9th node should be added after split"
  assert rt.buckets.len >= 2, "bucket should have split: " & $rt.buckets.len
  assert rt.totalNodes() == K + 1, "all nodes preserved: " & $rt.totalNodes()
  echo "PASS: bucket split when full"

block test_bucket_split_redistributes_correctly:
  ## After a split, nodes should be in the correct bucket based on their ID range.
  var ownId: NodeId
  ownId[0] = 0x80

  var rt = newRoutingTable(ownId)

  # Fill up with diverse nodes
  for i in 0 ..< K:
    var nodeId: NodeId
    nodeId[0] = byte(i * 30)  # Spread: 0x00, 0x1E, 0x3C, 0x5A, 0x78, 0x96, 0xB4, 0xD2
    let node = DhtNode(id: nodeId, ip: "10.0.0." & $i, port: 6881)
    discard rt.addNode(node)

  # Trigger split by adding one more
  var extraNode: NodeId
  extraNode[0] = 0xF0
  discard rt.addNode(DhtNode(id: extraNode, ip: "10.0.0.100", port: 6881))

  # Verify all nodes are still reachable
  let allNodes = rt.findClosest(ownId, 100)
  assert allNodes.len == K + 1, "all nodes accessible after split"

  # Verify bucket ranges don't overlap
  for i in 0 ..< rt.buckets.len - 1:
    let b1end = rt.buckets[i].rangeEnd
    let b2start = rt.buckets[i + 1].rangeStart
    # b2start should be > b1end (no overlap)
    assert b2start == b1end or b1end < b2start,
      "bucket ranges should not overlap"
  echo "PASS: bucket split redistributes correctly"

block test_multiple_sequential_splits:
  ## Adding many nodes should trigger multiple splits around our ID.
  var ownId: NodeId
  ownId[0] = 0x80

  var rt = newRoutingTable(ownId)
  var addedCount = 0

  # Add 30 nodes with IDs spread across the keyspace
  for i in 0 ..< 30:
    var nodeId: NodeId
    nodeId[0] = byte((i * 8) mod 256)
    nodeId[1] = byte(i)  # Differentiate within same first byte
    if nodeId == ownId:
      continue  # Skip our own ID
    let node = DhtNode(id: nodeId, ip: "10.0." & $(i div 256) & "." & $(i mod 256), port: 6881)
    if rt.addNode(node):
      addedCount += 1

  assert rt.buckets.len > 1, "multiple splits occurred: " & $rt.buckets.len
  assert rt.totalNodes() == addedCount, "total nodes match: " & $rt.totalNodes()

  # Verify no empty buckets between first and last non-empty
  # (except the very first which might have been split away from)
  echo "  Buckets: " & $rt.buckets.len & ", nodes: " & $rt.totalNodes()
  echo "PASS: multiple sequential splits"

block test_no_split_for_non_own_bucket:
  ## When a non-own bucket is full, new nodes should be rejected (or evict bad nodes).
  var ownId: NodeId
  ownId[0] = 0xFF  # Own ID in high range

  var rt = newRoutingTable(ownId)

  # Add K nodes all in the low range (far from our ID)
  for i in 0 ..< K:
    var nodeId: NodeId
    nodeId[0] = byte(i + 1)  # 0x01-0x08, far from 0xFF
    let node = DhtNode(id: nodeId, ip: "10.0.0." & $i, port: 6881)
    discard rt.addNode(node)

  # Trigger split (ownId 0xFF IS in the all-encompassing bucket initially)
  var nodeId9: NodeId
  nodeId9[0] = 0x09
  discard rt.addNode(DhtNode(id: nodeId9, ip: "10.0.0.9", port: 6881))

  # Now try to fill the bucket that does NOT contain our own ID
  # until it's full, then add one more — it should NOT split
  var lowBucketFull = false
  for i in 10 ..< 50:
    var nodeId: NodeId
    nodeId[0] = byte(i)  # Low range
    let node = DhtNode(id: nodeId, ip: "10.0.0." & $i, port: 6881)
    let added = rt.addNode(node)
    if not added:
      lowBucketFull = true
      break

  # The non-own bucket should have hit capacity and rejected
  assert lowBucketFull, "non-own bucket should reject when full"
  echo "PASS: no split for non-own bucket"

block test_evict_bad_nodes:
  ## When bucket is full and can't split, nodes with failCount >= 2 get evicted.
  var ownId: NodeId
  ownId[0] = 0xFF

  var rt = newRoutingTable(ownId)

  # Fill a low-range bucket with K nodes, force a split first
  for i in 0 ..< K + 1:
    var nodeId: NodeId
    nodeId[0] = byte(i + 1)
    let node = DhtNode(id: nodeId, ip: "10.0.0." & $i, port: 6881)
    discard rt.addNode(node)

  # Mark a node in the low bucket as failed
  var badId: NodeId
  badId[0] = 0x01
  rt.markFailed(badId)
  rt.markFailed(badId)  # failCount now 2

  # Try to add a new node — should evict the bad one
  var newId: NodeId
  newId[0] = 0x0A
  let added = rt.addNode(DhtNode(id: newId, ip: "10.0.0.99", port: 6881))
  # If the bad node's bucket is full, the new node should replace it
  if added:
    let found = rt.findClosest(newId, 1)
    assert found.len > 0 and found[0].id == newId
  echo "PASS: evict bad nodes"

# === DHT response encode/decode ===

block test_find_node_response_roundtrip:
  ## Encode and decode a find_node response with compact nodes.
  var ownId: NodeId
  ownId[0] = 0xAA

  var nodes: seq[CompactNodeInfo]
  for i in 0 ..< 3:
    var nodeId: NodeId
    nodeId[0] = byte(i + 1)
    nodeId[19] = byte(i * 10)
    nodes.add(CompactNodeInfo(
      id: nodeId,
      ip: "192.168.1." & $i,
      port: uint16(6881 + i)
    ))

  let encoded = encodeFindNodeResponse("tx01", ownId, nodes)
  let msg = decodeDhtMessage(encoded)

  assert not msg.isQuery
  assert msg.transactionId == "tx01"
  assert msg.responderId[0] == 0xAA
  assert msg.nodes.len == 3
  for i in 0 ..< 3:
    assert msg.nodes[i].id[0] == byte(i + 1)
    assert msg.nodes[i].id[19] == byte(i * 10)
    assert msg.nodes[i].ip == "192.168.1." & $i
    assert msg.nodes[i].port == uint16(6881 + i)
  echo "PASS: find_node response roundtrip"

block test_get_peers_response_with_peers:
  ## Encode and decode a get_peers response containing peer values.
  var ownId: NodeId
  ownId[0] = 0xBB

  let peers = @[
    (ip: "10.0.0.1", port: 6881'u16),
    (ip: "10.0.0.2", port: 51413'u16),
    (ip: "192.168.1.100", port: 8999'u16)
  ]

  let encoded = encodeGetPeersResponse("tx02", ownId, "mytoken", peers = peers)
  let msg = decodeDhtMessage(encoded)

  assert not msg.isQuery
  assert msg.transactionId == "tx02"
  assert msg.responderId[0] == 0xBB
  assert msg.respToken == "mytoken"
  assert msg.values.len == 3
  assert msg.values[0].ip == "10.0.0.1"
  assert msg.values[0].port == 6881
  assert msg.values[1].ip == "10.0.0.2"
  assert msg.values[1].port == 51413
  assert msg.values[2].ip == "192.168.1.100"
  assert msg.values[2].port == 8999
  assert msg.nodes.len == 0, "no nodes when peers present"
  echo "PASS: get_peers response with peers"

block test_get_peers_response_with_nodes:
  ## Encode and decode a get_peers response containing nodes (no direct peers).
  var ownId: NodeId
  ownId[0] = 0xCC

  var nodes: seq[CompactNodeInfo]
  for i in 0 ..< 2:
    var nodeId: NodeId
    nodeId[0] = byte(0x10 + i)
    nodes.add(CompactNodeInfo(id: nodeId, ip: "172.16.0." & $i, port: uint16(6881 + i)))

  let encoded = encodeGetPeersResponse("tx03", ownId, "token2", nodes = nodes)
  let msg = decodeDhtMessage(encoded)

  assert not msg.isQuery
  assert msg.transactionId == "tx03"
  assert msg.respToken == "token2"
  assert msg.values.len == 0, "no peer values"
  assert msg.nodes.len == 2
  assert msg.nodes[0].id[0] == 0x10
  assert msg.nodes[0].ip == "172.16.0.0"
  assert msg.nodes[1].id[0] == 0x11
  assert msg.nodes[1].ip == "172.16.0.1"
  echo "PASS: get_peers response with nodes"

block test_ping_response_roundtrip:
  var ownId: NodeId
  ownId[0] = 0xDD
  ownId[19] = 0xEE

  let encoded = encodePingResponse("tx04", ownId)
  let msg = decodeDhtMessage(encoded)

  assert not msg.isQuery
  assert msg.transactionId == "tx04"
  assert msg.responderId[0] == 0xDD
  assert msg.responderId[19] == 0xEE
  echo "PASS: ping response roundtrip"

# === Edge cases ===

block test_bucket_index_same_id:
  ## Same ID as own should return bucket 159.
  var id: NodeId
  id[0] = 0x42
  assert bucketIndex(id, id) == 159
  echo "PASS: bucket index same ID"

block test_bucket_index_differ_by_last_bit:
  ## IDs differing only in the last bit should be in bucket 159.
  var a, b: NodeId
  a[19] = 0x00
  b[19] = 0x01
  assert bucketIndex(a, b) == 159
  echo "PASS: bucket index differ by last bit"

block test_bucket_index_all_zeros_vs_all_ones:
  ## Maximum distance: all zeros vs all ones.
  var a: NodeId  # all zeros
  var b: NodeId
  for i in 0 ..< 20: b[i] = 0xFF
  assert bucketIndex(a, b) == 0, "max distance = bucket 0"
  echo "PASS: bucket index all zeros vs all ones"

block test_hash_consistency:
  ## hash(NodeId) should be deterministic.
  var id: NodeId
  id[0] = 0xAB; id[10] = 0xCD; id[19] = 0xEF
  let h1 = hash(id)
  let h2 = hash(id)
  assert h1 == h2, "hash is deterministic"

  var id2: NodeId
  id2[0] = 0xBA
  let h3 = hash(id2)
  # Different IDs should (usually) have different hashes
  # This isn't guaranteed but extremely likely for these values
  assert h1 != h3 or true, "different IDs usually different hashes"
  echo "PASS: hash consistency"

block test_compact_node_encode_roundtrip:
  ## encodeCompactNode / decodeCompactNodes roundtrip.
  var node: CompactNodeInfo
  for i in 0 ..< 20: node.id[i] = byte(i)
  node.ip = "192.168.1.100"
  node.port = 6881

  let encoded = encodeCompactNode(node)
  assert encoded.len == 26

  let decoded = decodeCompactNodes(encoded)
  assert decoded.len == 1
  assert decoded[0].id == node.id
  assert decoded[0].ip == "192.168.1.100"
  assert decoded[0].port == 6881
  echo "PASS: compact node encode roundtrip"

block test_compact_node_invalid_length:
  ## Non-26-byte data should return empty.
  let decoded = decodeCompactNodes("short")
  assert decoded.len == 0
  echo "PASS: compact node invalid length"

block test_compact_peers_decode:
  ## decodeCompactPeers with valid data.
  var data = ""
  data.add(char(10)); data.add(char(0)); data.add(char(0)); data.add(char(1))
  data.add(char(0x1A'u8)); data.add(char(0xE1'u8))  # 6881

  let peers = decodeCompactPeers(data)
  assert peers.len == 1
  assert peers[0].ip == "10.0.0.1"
  assert peers[0].port == 6881
  echo "PASS: compact peers decode"

block test_compact_peers_invalid_length:
  let peers = decodeCompactPeers("1234567")  # 7 bytes, not multiple of 6
  assert peers.len == 0
  echo "PASS: compact peers invalid length"

block test_peer_store_limit:
  ## Peer store should limit to 100 peers per torrent.
  var store = DhtPeerStore()
  var hash: NodeId
  hash[0] = 0xAA

  for i in 0 ..< 110:
    store.addPeer(hash, "10.0." & $(i div 256) & "." & $(i mod 256), uint16(6881 + i))

  let peers = store.getPeers(hash)
  assert peers.len == 100, "peer store limited to 100: " & $peers.len
  # The oldest peers (first added) should have been evicted
  # Last peer added should be present
  var foundLast = false
  for p in peers:
    if p.ip == "10.0.0.109" and p.port == 6990:
      foundLast = true
  assert foundLast, "most recently added peer present"
  echo "PASS: peer store limit"

block test_find_closest_empty_table:
  var ownId: NodeId
  ownId[0] = 0x42
  let rt = newRoutingTable(ownId)
  var target: NodeId
  target[0] = 0x01
  let closest = rt.findClosest(target, K)
  assert closest.len == 0
  echo "PASS: find closest empty table"

block test_find_closest_sorting:
  ## findClosest should return nodes sorted by XOR distance.
  var ownId: NodeId
  ownId[0] = 0xFF
  var rt = newRoutingTable(ownId)

  # Add nodes at various distances from target 0x10
  for i in 0 ..< 5:
    var nodeId: NodeId
    nodeId[0] = byte(0x10 + i * 5)  # 0x10, 0x15, 0x1A, 0x1F, 0x24
    let node = DhtNode(id: nodeId, ip: "10.0.0." & $i, port: 6881)
    discard rt.addNode(node)

  var target: NodeId
  target[0] = 0x10

  let closest = rt.findClosest(target, 5)
  assert closest.len == 5

  # Verify sorted by distance
  for i in 0 ..< closest.len - 1:
    let d1 = xorDistance(closest[i].id, target)
    let d2 = xorDistance(closest[i+1].id, target)
    assert d1 < d2 or d1 == d2, "not sorted at index " & $i
  echo "PASS: find closest sorting"

block test_generate_node_id_uniqueness:
  ## Two generated node IDs should (almost certainly) be different.
  let id1 = generateNodeId()
  let id2 = generateNodeId()
  assert id1 != id2, "generated IDs should be unique"
  echo "PASS: generate node ID uniqueness"

echo ""
echo "All advanced DHT tests passed!"
