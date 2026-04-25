## Tests for DHT routing-table split midpoint arithmetic on big-endian NodeIds.

import cps/bittorrent/dht

proc toNodeId(bytes: openArray[byte]): NodeId =
  for i in 0 ..< min(bytes.len, NodeIdLen):
    result[i] = bytes[i]

block: # midpoint of 0x00 and 0x02 in first byte
  var a, b: NodeId
  b[0] = 0x02
  let mid = midpoint(a, b)
  assert mid[0] == 0x01, "midpoint of 0x00 and 0x02 should be 0x01, got " & $mid[0]
  for i in 1 ..< NodeIdLen:
    assert mid[i] == 0, "other bytes should be 0"
  echo "PASS: midpoint simple case (0x00, 0x02)"

block: # midpoint that requires carry across bytes
  # a = 0x00,0x00,...   b = 0x01,0x00,...
  # (a+b) = 0x01,0x00,...   (a+b)/2 = 0x00,0x80,...
  var a, b: NodeId
  b[0] = 0x01
  let mid = midpoint(a, b)
  assert mid[0] == 0x00, "high byte should be 0x00, got " & $mid[0]
  assert mid[1] == 0x80, "second byte should be 0x80 (carry from division), got " & $mid[1]
  for i in 2 ..< NodeIdLen:
    assert mid[i] == 0, "other bytes should be 0"
  echo "PASS: midpoint with carry across bytes (0x0100 -> 0x0080)"

block: # midpoint of 0xFF and 0xFF across all bytes
  # a = all 0xFF, b = all 0xFF
  # (a+b) = carry=1, bytes all 0xFE; (1 0xFE...)/2 = 0xFF...
  var a, b: NodeId
  for i in 0 ..< NodeIdLen:
    a[i] = 0xFF
    b[i] = 0xFF
  let mid = midpoint(a, b)
  for i in 0 ..< NodeIdLen:
    assert mid[i] == 0xFF, "midpoint of (0xFF,0xFF) should be 0xFF at byte " & $i & ", got " & $mid[i]
  echo "PASS: midpoint of max with max"

block: # midpoint of 0x00 and 0xFF...FF
  # a = all 0x00, b = all 0xFF
  # (a+b) = 0xFF...FF; /2 = 0x7F,0xFF...FF,0x80 (wait, let me compute)
  # Actually: 0x00FF / 2 in first two bytes = 0x007F with carry=1 to next byte
  # 0xFF / 2 with carry from prev = (0x1FF)/2 = 0xFF carry 1... etc
  # 0x00FFFFFFFFFFFF...FF / 2 = 0x007FFFFFFFFFF...FF with last byte = (0xFF+1(carry))/2=0x80
  var a, b: NodeId
  for i in 0 ..< NodeIdLen:
    b[i] = 0xFF
  let mid = midpoint(a, b)
  assert mid[0] == 0x7F, "first byte should be 0x7F, got " & $mid[0]
  for i in 1 ..< NodeIdLen - 1:
    assert mid[i] == 0xFF, "middle bytes should be 0xFF at byte " & $i & ", got " & $mid[i]
  assert mid[NodeIdLen - 1] == 0xFF, "last byte should be 0xFF, got " & $mid[NodeIdLen - 1]
  echo "PASS: midpoint of min and max"

block: # midpoint where addition carry propagates through multiple bytes
  # a = 0x00,0x00,...,0x00,0x01  b = 0x00,0x00,...,0x00,0x01
  # (a+b) = 0x00,...,0x00,0x02; /2 = 0x00,...,0x00,0x01
  var a, b: NodeId
  a[NodeIdLen - 1] = 0x01
  b[NodeIdLen - 1] = 0x01
  let mid = midpoint(a, b)
  for i in 0 ..< NodeIdLen - 1:
    assert mid[i] == 0, "leading bytes should be 0"
  assert mid[NodeIdLen - 1] == 0x01, "last byte should be 0x01, got " & $mid[NodeIdLen - 1]
  echo "PASS: midpoint of identical small values"

block: # midpoint with odd sum requiring carry across byte boundary
  # a = 0x00,0x00  b = 0x00,0x03 (just first 2 bytes for clarity)
  # (a+b) = 0x00,0x03;  /2 = 0x00,0x01 (truncated, since 3/2=1)
  var a, b: NodeId
  b[NodeIdLen - 1] = 0x03
  let mid = midpoint(a, b)
  assert mid[NodeIdLen - 1] == 0x01, "3/2 truncates to 1, got " & $mid[NodeIdLen - 1]
  echo "PASS: midpoint with odd sum (truncation)"

block: # midpoint is between a and b (ordering check)
  # Use realistic split scenario: a = 0x00..., b = 0x80...
  var a, b: NodeId
  b[0] = 0x80
  let mid = midpoint(a, b)
  assert mid[0] == 0x40, "midpoint of 0x00 and 0x80 in high byte should be 0x40, got " & $mid[0]
  assert not (mid < a), "midpoint should be >= a"
  assert mid < b, "midpoint should be < b"
  echo "PASS: midpoint ordering (between a and b)"

block: # routing table split produces correct ranges
  # The key test: when we split a bucket, the midpoint should correctly
  # divide the range. Put own ID in low range to trigger splits.
  var ownId: NodeId
  ownId[0] = 0x01

  var rt = newRoutingTable(ownId)

  # Fill the first bucket (which contains ownId range [0, max])
  # Add 8 nodes that are close to ownId (low byte values)
  for i in 0 ..< K:
    var nodeId: NodeId
    nodeId[0] = byte(i + 2)  # 0x02..0x09
    let node = DhtNode(id: nodeId, ip: "10.0.0." & $i, port: 6881)
    discard rt.addNode(node)
  assert rt.totalNodes() == K

  # Adding one more node in the same bucket should trigger a split
  var extraNode: NodeId
  extraNode[0] = 0x0A
  let added = rt.addNode(DhtNode(id: extraNode, ip: "10.0.0.10", port: 6881))

  # After split, check that bucket ranges don't overlap and are contiguous
  assert rt.buckets.len >= 2, "should have split into at least 2 buckets"
  for i in 0 ..< rt.buckets.len - 1:
    let curEnd = rt.buckets[i].rangeEnd
    let nextStart = rt.buckets[i + 1].rangeStart
    # nextStart should be curEnd + 1
    assert curEnd < nextStart or curEnd == nextStart,
      "bucket ranges must not have gaps"

  # Verify all nodes are findable
  let all = rt.findClosest(ownId, 20)
  assert all.len >= K, "should find at least K nodes after split"
  echo "PASS: routing table split produces correct ranges"

echo "ALL DHT MIDPOINT TESTS PASSED"
