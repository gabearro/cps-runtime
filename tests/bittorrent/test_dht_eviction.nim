## Tests for DHT dead-node eviction via markFailed.
## Verifies that nodes with high failCount are evicted when buckets are full.

import std/[times]
import cps/bittorrent/dht

block: # markFailed increments failCount
  var ownId: NodeId
  ownId[0] = 0xFF
  var rt = newRoutingTable(ownId)

  var nodeId: NodeId
  nodeId[0] = 0x01
  let node = DhtNode(id: nodeId, ip: "10.0.0.1", port: 6881, lastSeen: epochTime())
  discard rt.addNode(node)

  rt.markFailed(nodeId)
  let found = rt.findClosest(nodeId, 1)
  assert found.len == 1
  assert found[0].failCount == 1

  rt.markFailed(nodeId)
  let found2 = rt.findClosest(nodeId, 1)
  assert found2[0].failCount == 2
  echo "PASS: markFailed increments failCount"

block: # nodes with failCount >= 2 are evicted when bucket is full
  var ownId: NodeId
  ownId[0] = 0xFF  # Far from test nodes
  var rt = newRoutingTable(ownId)

  # Fill the bucket with K nodes (all in the same bucket since ownId is far)
  for i in 0 ..< K:
    var nodeId: NodeId
    nodeId[0] = byte(i + 1)
    let node = DhtNode(id: nodeId, ip: "10.0.0." & $i, port: 6881, lastSeen: epochTime())
    discard rt.addNode(node)
  assert rt.totalNodes() == K

  # Mark one node as failed twice (failCount >= 2 triggers eviction)
  var failedId: NodeId
  failedId[0] = 0x01
  rt.markFailed(failedId)
  rt.markFailed(failedId)

  # Try to add a new node - should evict the failed one
  var newNodeId: NodeId
  newNodeId[0] = 0x0A
  let newNode = DhtNode(id: newNodeId, ip: "10.0.0.10", port: 6881, lastSeen: epochTime())
  let added = rt.addNode(newNode)
  assert added, "new node should be added by evicting failed node"
  assert rt.totalNodes() == K, "total nodes should remain K"

  # Verify the failed node was evicted
  let closest = rt.findClosest(failedId, K)
  var failedFound = false
  for n in closest:
    if n.id == failedId:
      failedFound = true
  assert not failedFound, "failed node should have been evicted"

  # Verify the new node is present
  var newFound = false
  for n in closest:
    if n.id == newNodeId:
      newFound = true
  assert newFound, "new node should be present"
  echo "PASS: failed nodes evicted when bucket is full"

block: # nodes with failCount < 2 are NOT evicted
  var ownId: NodeId
  ownId[0] = 0xFF
  var rt = newRoutingTable(ownId)

  for i in 0 ..< K:
    var nodeId: NodeId
    nodeId[0] = byte(i + 1)
    let node = DhtNode(id: nodeId, ip: "10.0.0." & $i, port: 6881, lastSeen: epochTime())
    discard rt.addNode(node)

  # Mark one node as failed only once (failCount == 1, below threshold)
  var failedId: NodeId
  failedId[0] = 0x01
  rt.markFailed(failedId)

  # Try to add a new node - should NOT evict (no node has failCount >= 2)
  var newNodeId: NodeId
  newNodeId[0] = 0x0A
  let newNode = DhtNode(id: newNodeId, ip: "10.0.0.10", port: 6881, lastSeen: epochTime())
  let added = rt.addNode(newNode)
  assert not added, "new node should NOT be added (no evictable nodes)"
  echo "PASS: nodes with failCount < 2 are not evicted"

block: # successful response resets failCount (via addNode update)
  var ownId: NodeId
  ownId[0] = 0xFF
  var rt = newRoutingTable(ownId)

  var nodeId: NodeId
  nodeId[0] = 0x01
  let node = DhtNode(id: nodeId, ip: "10.0.0.1", port: 6881, lastSeen: epochTime())
  discard rt.addNode(node)

  rt.markFailed(nodeId)
  let found1 = rt.findClosest(nodeId, 1)
  assert found1[0].failCount == 1

  # Simulate a successful response — addNode updates existing node, resets failCount
  let updatedNode = DhtNode(id: nodeId, ip: "10.0.0.1", port: 6881, lastSeen: epochTime())
  discard rt.addNode(updatedNode)

  let found2 = rt.findClosest(nodeId, 1)
  assert found2[0].failCount == 0, "failCount should be reset after successful update"
  echo "PASS: successful response resets failCount"

block: # multiple failed nodes — only failed ones evicted
  var ownId: NodeId
  ownId[0] = 0xFF
  var rt = newRoutingTable(ownId)

  for i in 0 ..< K:
    var nodeId: NodeId
    nodeId[0] = byte(i + 1)
    let node = DhtNode(id: nodeId, ip: "10.0.0." & $i, port: 6881, lastSeen: epochTime())
    discard rt.addNode(node)

  # Mark first 3 nodes as failed (failCount >= 2)
  for i in 0 ..< 3:
    var fid: NodeId
    fid[0] = byte(i + 1)
    rt.markFailed(fid)
    rt.markFailed(fid)

  # Add 3 new nodes — should evict the 3 failed ones
  for i in 0 ..< 3:
    var newId: NodeId
    newId[0] = byte(K + i + 1)
    let newNode = DhtNode(id: newId, ip: "10.0.1." & $i, port: 6881, lastSeen: epochTime())
    let added = rt.addNode(newNode)
    assert added, "new node " & $i & " should be added"

  assert rt.totalNodes() == K
  echo "PASS: multiple failed nodes evicted correctly"

echo "ALL DHT EVICTION TESTS PASSED"
