## Tests for BEP 5: DHT Protocol.

import std/[tables, strutils]
import cps/bittorrent/dht
import cps/bittorrent/bencode

block: # XOR distance calculation
  var a, b: NodeId
  a[0] = 0xFF
  b[0] = 0x00
  let dist = xorDistance(a, b)
  assert dist[0] == 0xFF
  assert dist[1] == 0

  let dist2 = xorDistance(a, a)
  for i in 0 ..< NodeIdLen:
    assert dist2[i] == 0, "XOR with self is zero"
  echo "PASS: XOR distance calculation"

block: # node ID ordering
  var a, b: NodeId
  a[0] = 0x00
  b[0] = 0x01
  assert a < b
  assert not (b < a)
  assert not (a < a)
  assert a == a
  assert not (a == b)
  echo "PASS: node ID ordering"

block: # bucket index
  var ownId, nodeId: NodeId
  ownId[0] = 0x00
  nodeId[0] = 0x80  # Highest bit differs
  assert bucketIndex(ownId, nodeId) == 0, "highest bit differs -> bucket 0"

  var nodeId2: NodeId
  nodeId2[0] = 0x01
  assert bucketIndex(ownId, nodeId2) == 7, "lowest bit of first byte -> bucket 7"

  var nodeId3: NodeId
  nodeId3[1] = 0x01
  assert bucketIndex(ownId, nodeId3) == 15, "lowest bit of second byte -> bucket 15"
  echo "PASS: bucket index"

block: # routing table - add and find
  var ownId: NodeId
  ownId[0] = 0xFF  # Our ID is far from test nodes
  var rt = newRoutingTable(ownId)

  # Add some nodes spread across different distances
  for i in 0 ..< 8:
    var nodeId: NodeId
    nodeId[0] = byte(i + 1)
    let node = DhtNode(id: nodeId, ip: "10.0.0." & $i, port: 6881)
    discard rt.addNode(node)

  assert rt.totalNodes() >= 8, "added 8 nodes (bucket K=8)"

  # Find closest to a target
  var target: NodeId
  target[0] = 0x05
  let closest = rt.findClosest(target, 5)
  assert closest.len == 5, "found 5 closest nodes"
  # First should be closest by XOR
  let firstDist = xorDistance(closest[0].id, target)
  let secondDist = xorDistance(closest[1].id, target)
  assert firstDist < secondDist or firstDist == secondDist, "sorted by distance"
  echo "PASS: routing table - add and find"

block: # routing table - don't add self
  let ownId = generateNodeId()
  var rt = newRoutingTable(ownId)
  let node = DhtNode(id: ownId, ip: "127.0.0.1", port: 6881)
  let added = rt.addNode(node)
  assert not added, "should not add own ID"
  assert rt.totalNodes() == 0
  echo "PASS: routing table - don't add self"

block: # routing table - update existing node
  let ownId = generateNodeId()
  var rt = newRoutingTable(ownId)

  var nodeId: NodeId
  nodeId[0] = 0x42
  let node1 = DhtNode(id: nodeId, ip: "10.0.0.1", port: 6881, lastSeen: 100.0)
  discard rt.addNode(node1)
  assert rt.totalNodes() == 1

  let node2 = DhtNode(id: nodeId, ip: "10.0.0.2", port: 6882, lastSeen: 200.0)
  discard rt.addNode(node2)
  assert rt.totalNodes() == 1, "should update, not add duplicate"

  let found = rt.findClosest(nodeId, 1)
  assert found[0].ip == "10.0.0.2", "IP updated"
  assert found[0].port == 6882, "port updated"
  echo "PASS: routing table - update existing node"

block: # routing table - mark failed and remove
  let ownId = generateNodeId()
  var rt = newRoutingTable(ownId)

  var nodeId: NodeId
  nodeId[0] = 0x42
  let node = DhtNode(id: nodeId, ip: "10.0.0.1", port: 6881)
  discard rt.addNode(node)
  assert rt.totalNodes() == 1

  rt.markFailed(nodeId)
  assert rt.totalNodes() == 1, "marking failed doesn't remove"

  rt.removeNode(nodeId)
  assert rt.totalNodes() == 0, "remove works"
  echo "PASS: routing table - mark failed and remove"

block: # compact node encoding/decoding
  var nodes: seq[CompactNodeInfo]
  for i in 0 ..< 3:
    var id: NodeId
    id[0] = byte(i + 1)
    nodes.add(CompactNodeInfo(id: id, ip: "192.168.1." & $i, port: uint16(6881 + i)))

  # Encode manually for test
  var encoded = ""
  for n in nodes:
    for b in n.id:
      encoded.add(char(b))
    let parts = n.ip.split('.')
    for p in parts:
      encoded.add(char(parseInt(p).byte))
    encoded.add(char((n.port shr 8).byte))
    encoded.add(char((n.port and 0xFF).byte))

  let decoded = decodeCompactNodes(encoded)
  assert decoded.len == 3
  for i in 0 ..< 3:
    assert decoded[i].id[0] == byte(i + 1)
    assert decoded[i].ip == "192.168.1." & $i
    assert decoded[i].port == uint16(6881 + i)
  echo "PASS: compact node encoding/decoding"

block: # KRPC ping query encoding/decoding
  var ownId: NodeId
  ownId[0] = 0xAA
  let encoded = encodePingQuery("aa", ownId)
  let msg = decodeDhtMessage(encoded)
  assert msg.isQuery
  assert msg.transactionId == "aa"
  assert msg.queryType == "ping"
  assert msg.queryerId[0] == 0xAA
  echo "PASS: KRPC ping query encoding/decoding"

block: # KRPC find_node query
  var ownId, target: NodeId
  ownId[0] = 0x11
  target[0] = 0x22
  let encoded = encodeFindNodeQuery("bb", ownId, target)
  let msg = decodeDhtMessage(encoded)
  assert msg.isQuery
  assert msg.queryType == "find_node"
  assert msg.queryerId[0] == 0x11
  assert msg.targetId[0] == 0x22
  echo "PASS: KRPC find_node query"

block: # KRPC get_peers query
  var ownId, infoHash: NodeId
  ownId[0] = 0x33
  infoHash[0] = 0x44
  let encoded = encodeGetPeersQuery("cc", ownId, infoHash)
  let msg = decodeDhtMessage(encoded)
  assert msg.isQuery
  assert msg.queryType == "get_peers"
  assert msg.queryerId[0] == 0x33
  assert msg.infoHash[0] == 0x44
  echo "PASS: KRPC get_peers query"

block: # KRPC announce_peer query
  var ownId, infoHash: NodeId
  ownId[0] = 0x55
  infoHash[0] = 0x66
  let encoded = encodeAnnouncePeerQuery("dd", ownId, infoHash, 6881, "token123", true)
  let msg = decodeDhtMessage(encoded)
  assert msg.isQuery
  assert msg.queryType == "announce_peer"
  assert msg.announcePort == 6881
  assert msg.token == "token123"
  assert msg.impliedPort
  echo "PASS: KRPC announce_peer query"

block: # KRPC ping response
  var ownId: NodeId
  ownId[0] = 0x77
  let encoded = encodePingResponse("ee", ownId)
  let msg = decodeDhtMessage(encoded)
  assert not msg.isQuery
  assert msg.transactionId == "ee"
  assert msg.responderId[0] == 0x77
  echo "PASS: KRPC ping response"

block: # KRPC error message
  let encoded = encodeDhtError("ff", 201, "A Generic Error Occurred")
  let msg = decodeDhtMessage(encoded)
  assert not msg.isQuery
  assert msg.transactionId == "ff"
  assert msg.errorCode == 201
  assert msg.errorMsg == "A Generic Error Occurred"
  echo "PASS: KRPC error message"

block: # token generation and validation
  let token = generateToken("192.168.1.1", "secret1")
  assert token.len == 4

  assert validateToken(token, "192.168.1.1", "secret1", ""), "valid token accepted"
  assert not validateToken(token, "192.168.1.2", "secret1", ""), "wrong IP rejected"
  assert not validateToken(token, "192.168.1.1", "wrong_secret", ""), "wrong secret rejected"

  # Test with previous secret
  let prevToken = generateToken("192.168.1.1", "old_secret")
  assert validateToken(prevToken, "192.168.1.1", "new_secret", "old_secret"), "prev secret accepted"
  echo "PASS: token generation and validation"

block: # peer store
  var store = DhtPeerStore()
  var hash: NodeId
  hash[0] = 0xAA

  store.addPeer(hash, "10.0.0.1", 6881)
  store.addPeer(hash, "10.0.0.2", 6882)
  store.addPeer(hash, "10.0.0.1", 6881)  # Duplicate

  let peers = store.getPeers(hash)
  assert peers.len == 2, "no duplicates"
  assert peers[0].ip == "10.0.0.1"
  assert peers[1].ip == "10.0.0.2"

  var unknownHash: NodeId
  unknownHash[0] = 0xBB
  let noPeers = store.getPeers(unknownHash)
  assert noPeers.len == 0
  echo "PASS: peer store"

block: # node ID hex conversion
  var id: NodeId
  id[0] = 0xAB
  id[1] = 0xCD
  id[19] = 0xEF
  let hex = nodeIdToHex(id)
  assert hex.len == 40
  assert hex.startsWith("abcd")
  assert hex.endsWith("ef")

  let restored = hexToNodeId(hex)
  assert restored == id
  echo "PASS: node ID hex conversion"

block: # BEP 42 secure node IDs
  let secureId = generateSecureNodeId("203.0.113.10")
  assert isValidSecureNodeId(secureId, "203.0.113.10")
  assert not isValidSecureNodeId(secureId, "203.0.113.11")
  var tampered = secureId
  tampered[0] = tampered[0] xor 0x01
  assert not isValidSecureNodeId(tampered, "203.0.113.10")
  echo "PASS: BEP 42 secure node ID validation"

echo "ALL DHT TESTS PASSED"
