## BEP 5: DHT Protocol (Distributed Hash Table).
##
## Implements the Kademlia-based DHT for trackerless peer discovery.
## Supports: ping, find_node, get_peers, announce_peer.

import std/[tables, times, strutils, hashes]

import utils
import bencode
import sha1

const
  K* = 8              ## Bucket size (max nodes per bucket)
  Alpha* = 3          ## Concurrency parameter for lookups
  NodeIdLen* = 20     ## Length of node IDs in bytes
  DhtPort* = 6881     ## Default DHT port
  TokenLifetime* = 600  ## Token validity in seconds (10 min)
  BucketRefreshInterval* = 900  ## Refresh buckets every 15 min
  MaxTokenAge* = 600
  MaxPeersPerInfoHash = 100  ## Max stored peers per info hash

type
  NodeId* = array[20, byte]

  DhtNode* = object
    id*: NodeId
    ip*: string
    port*: uint16
    lastSeen*: float
    lastQueried*: float
    failCount*: int

  Bucket* = object
    rangeStart*: NodeId
    rangeEnd*: NodeId
    nodes*: seq[DhtNode]
    lastChanged*: float

  RoutingTable* = object
    ownId*: NodeId
    buckets*: seq[Bucket]

  DhtQueryKind* = enum
    dqPing
    dqFindNode
    dqGetPeers
    dqAnnouncePeer

  DhtResponseKind* = enum
    drPing
    drFindNode
    drGetPeers
    drAnnouncePeer
    drError

  CompactNodeInfo* = object
    id*: NodeId
    ip*: string
    port*: uint16

  DhtMessage* = object
    transactionId*: string
    case isQuery*: bool
    of true:
      queryType*: string  ## "ping", "find_node", "get_peers", "announce_peer"
      queryerId*: NodeId
      targetId*: NodeId   ## For find_node / get_peers
      infoHash*: NodeId   ## For get_peers / announce_peer
      impliedPort*: bool  ## BEP 5: use source port
      announcePort*: uint16
      rawAnnouncePort*: int64   ## Raw port value from bencoded message (for validation)
      token*: string      ## For announce_peer
    of false:
      responderId*: NodeId
      nodes*: seq[CompactNodeInfo]
      values*: seq[tuple[ip: string, port: uint16]]  ## Peers for get_peers
      respToken*: string  ## Token for future announce_peer
      errorCode*: int
      errorMsg*: string

# Node ID operations

proc xorDistance*(a, b: NodeId): NodeId =
  for i in 0 ..< NodeIdLen:
    result[i] = a[i] xor b[i]

proc `<`*(a, b: NodeId): bool =
  for i in 0 ..< NodeIdLen:
    if a[i] < b[i]: return true
    if a[i] > b[i]: return false
  return false

proc `==`*(a, b: NodeId): bool =
  for i in 0 ..< NodeIdLen:
    if a[i] != b[i]: return false
  return true

proc `<=`*(a, b: NodeId): bool =
  for i in 0 ..< NodeIdLen:
    if a[i] < b[i]: return true
    if a[i] > b[i]: return false
  return true  # Equal

proc hash*(id: NodeId): Hash =
  var h: Hash = 0
  for b in id:
    h = h !& hash(b)
  result = !$h

proc bucketIndex*(ownId: NodeId, nodeId: NodeId): int =
  ## Calculate the bucket index for a node based on XOR distance.
  ## Returns the index of the highest differing bit (0-159).
  let dist = xorDistance(ownId, nodeId)
  for i in 0 ..< NodeIdLen:
    if dist[i] != 0:
      # Find highest set bit in this byte
      var b = dist[i]
      var bit = 7
      while bit >= 0 and (b and (1'u8 shl bit)) == 0:
        dec bit
      return i * 8 + (7 - bit)
  return 159  # Same ID, put in last bucket

proc generateNodeId*(): NodeId =
  ## Generate a random node ID.
  for i in 0 ..< NodeIdLen:
    result[i] = byte(btRandU32() and 0xFF)


proc nodeIdToStr*(id: NodeId): string =
  ## Convert a NodeId to a 20-byte binary string (for KRPC encoding).
  result = newStringOfCap(NodeIdLen)
  for b in id:
    result.add(char(b))

proc strToNodeId*(s: string): NodeId =
  ## Convert a 20-byte binary string to a NodeId.
  assert s.len == NodeIdLen
  copyMem(addr result[0], unsafeAddr s[0], NodeIdLen)

# BEP 42: DHT Security Extension

proc bep42MaskedIp(ipBytes: array[4, byte], r: byte): array[4, byte] =
  ## BEP 42 IPv4 mask:
  ## - Keep low 2 bits of first octet and inject low 3 random bits in the high bits.
  ## - Keep low 4 bits of second octet.
  ## - Keep low 6 bits of third octet.
  ## - Keep full fourth octet.
  result[0] = (ipBytes[0] and 0x03) or ((r and 0x07) shl 5)
  result[1] = ipBytes[1] and 0x0F
  result[2] = ipBytes[2] and 0x3F
  result[3] = ipBytes[3]

proc bep42MaskedIpv6(ipBytes: array[8, uint16], r: byte): array[8, byte] =
  ## BEP 42 IPv6 mask: uses first 8 bytes of the IPv6 address.
  ## Mask: [0x01, 0x03, 0x07, 0x0f, 0x1f, 0x3f, 0x7f, 0xff]
  ## The random bits r (3 bits) are injected into the high bits of the first byte.
  const mask = [0x01'u8, 0x03, 0x07, 0x0f, 0x1f, 0x3f, 0x7f, 0xff]
  # Extract first 8 bytes from the 8 uint16 groups
  var ipBytes8: array[8, byte]
  for i in 0 ..< 4:
    ipBytes8[i * 2] = byte((ipBytes[i] shr 8) and 0xFF)
    ipBytes8[i * 2 + 1] = byte(ipBytes[i] and 0xFF)
  for i in 0 ..< 8:
    result[i] = ipBytes8[i] and mask[i]
  result[0] = result[0] or ((r and 0x07) shl 5)

proc generateSecureNodeId*(ip: string): NodeId =
  ## Generate a BEP 42-compliant node ID from an IP address.
  ## The first 21 bits must match CRC32C of the masked IP.
  ## Supports both IPv4 and IPv6 addresses.
  let randByte = byte(btRandU32() and 0xFF)
  let r = randByte and 0x07
  var crc: uint32
  if isIpv6(ip):
    let words = parseIpv6Words(ip)
    let masked = bep42MaskedIpv6(words, r)
    crc = crc32c(masked)
  else:
    let ipBytes = parseIpv4(ip)
    let masked = bep42MaskedIp(ipBytes, r)
    crc = crc32c(masked)

  # Set first 21 bits of node ID from CRC32C
  result[0] = byte((crc shr 24) and 0xFF)
  result[1] = byte((crc shr 16) and 0xFF)
  result[2] = byte(((crc shr 8) and 0xF8) or (byte(btRandU32()) and 0x07))

  # Rest is random
  for i in 3 ..< 19:
    result[i] = byte(btRandU32() and 0xFF)
  result[19] = randByte

proc isValidSecureNodeId*(nodeId: NodeId, ip: string): bool =
  ## Verify a node ID complies with BEP 42 (first 21 bits match IP-derived CRC32C).
  ## Supports both IPv4 and IPv6 addresses.
  let r = nodeId[19] and 0x07
  var crc: uint32
  if isIpv6(ip):
    let words = parseIpv6Words(ip)
    let masked = bep42MaskedIpv6(words, r)
    crc = crc32c(masked)
  else:
    let ipBytes = parseIpv4(ip)
    let masked = bep42MaskedIp(ipBytes, r)
    crc = crc32c(masked)

  # Check first 21 bits
  if nodeId[0] != byte((crc shr 24) and 0xFF): return false
  if nodeId[1] != byte((crc shr 16) and 0xFF): return false
  if (nodeId[2] and 0xF8) != byte((crc shr 8) and 0xF8): return false
  return true

proc nodeIdToHex*(id: NodeId): string =
  bytesToHex(id)

proc hexToNodeId*(s: string): NodeId =
  assert s.len == 40
  let bytes = hexToBytes(s)
  copyMem(addr result[0], unsafeAddr bytes[0], 20)

# Routing table operations

proc newRoutingTable*(ownId: NodeId): RoutingTable =
  var minId: NodeId
  var maxId: NodeId
  for i in 0 ..< NodeIdLen:
    maxId[i] = 0xFF
  result = RoutingTable(
    ownId: ownId,
    buckets: @[Bucket(
      rangeStart: minId,
      rangeEnd: maxId,
      lastChanged: epochTime()
    )]
  )

proc findBucket(rt: RoutingTable, id: NodeId): int =
  ## Find the bucket that should contain this node ID.
  for i in 0 ..< rt.buckets.len:
    if id <= rt.buckets[i].rangeEnd:
      return i
  return rt.buckets.len - 1

proc midpoint*(a, b: NodeId): NodeId =
  ## Calculate the midpoint of two node IDs (for splitting).
  ## NodeIds are big-endian byte arrays, so addition carry propagates
  ## from low index (MSB) to high index (LSB) — wait, from high index
  ## (LSB) to low index (MSB). Division carry propagates from low
  ## index (MSB) to high index (LSB). These are opposite directions,
  ## so we must do them as two separate passes.

  # Pass 1: Add a + b into a wider buffer (carry propagates LSB to MSB)
  var sum: array[NodeIdLen, uint16]
  var carry: uint16 = 0
  for i in countdown(NodeIdLen - 1, 0):
    let s = uint16(a[i]) + uint16(b[i]) + carry
    sum[i] = s and 0xFF
    carry = s shr 8

  # Pass 2: Divide by 2 / shift right by 1 (carry propagates MSB to LSB)
  var bit: uint16 = carry  # carry from addition is the MSB of the sum
  for i in 0 ..< NodeIdLen:
    let val = (bit shl 8) or sum[i]
    result[i] = byte(val shr 1)
    bit = val and 1

const
  MaxBuckets = 160  ## Max number of buckets (20 bytes * 8 bits)

proc addNodeImpl(rt: var RoutingTable, node: DhtNode, depth: int): bool =
  ## Internal recursive implementation of addNode.
  if node.id == rt.ownId:
    return false
  if depth > 10:
    return false  # Prevent infinite recursion from degenerate splits

  let idx = rt.findBucket(node.id)
  var bucket = addr rt.buckets[idx]

  # Check if node already exists
  for existing in bucket.nodes.mitems:
    if existing.id == node.id:
      existing.lastSeen = node.lastSeen
      existing.ip = node.ip
      existing.port = node.port
      existing.failCount = 0
      bucket.lastChanged = epochTime()
      return true

  # Add to bucket if not full
  if bucket.nodes.len < K:
    bucket.nodes.add(node)
    bucket.lastChanged = epochTime()
    return true

  # Bucket is full - try to split if our own ID is in this bucket
  # and we haven't exceeded the max bucket count
  let ownBucket = rt.findBucket(rt.ownId)
  if idx == ownBucket and rt.buckets.len < MaxBuckets:
    # Split the bucket
    let mid = midpoint(bucket.rangeStart, bucket.rangeEnd)
    var newBucket = Bucket(
      rangeStart: mid,
      rangeEnd: bucket.rangeEnd,
      lastChanged: epochTime()
    )
    # Increment mid by 1 to avoid overlap
    var midPlusOne = mid
    var carry = true
    for i in countdown(NodeIdLen - 1, 0):
      if carry:
        if midPlusOne[i] < 0xFF:
          midPlusOne[i] += 1
          carry = false
        else:
          midPlusOne[i] = 0
    newBucket.rangeStart = midPlusOne
    bucket.rangeEnd = mid

    # Redistribute nodes
    var keep: seq[DhtNode]
    for n in bucket.nodes:
      if n.id <= mid:
        keep.add(n)
      else:
        newBucket.nodes.add(n)
    bucket.nodes = keep
    rt.buckets.insert(newBucket, idx + 1)

    # Try adding again (with depth guard)
    return rt.addNodeImpl(node, depth + 1)

  # Bucket full and can't split - try to evict bad nodes
  var evicted = false
  for i in 0 ..< bucket.nodes.len:
    if bucket.nodes[i].failCount >= 2:
      bucket.nodes.delete(i)
      bucket.nodes.add(node)
      bucket.lastChanged = epochTime()
      evicted = true
      break
  return evicted

proc addNode*(rt: var RoutingTable, node: DhtNode): bool =
  ## Add or update a node in the routing table. Returns true if added.
  rt.addNodeImpl(node, 0)

proc findClosest*(rt: RoutingTable, target: NodeId, count: int = K): seq[DhtNode] =
  ## Find the K closest nodes to a target ID using partial selection.
  ## O(n·K) instead of O(n log n) full sort — K is typically 8.
  result = newSeqOfCap[DhtNode](count)
  var resultDists = newSeqOfCap[NodeId](count)
  for bucket in rt.buckets:
    for node in bucket.nodes:
      let dist = xorDistance(node.id, target)
      if result.len < count:
        # Insert maintaining sorted order (small K, so linear insert is fine)
        var pos = result.len
        while pos > 0 and dist < resultDists[pos - 1]:
          dec pos
        result.insert(node, pos)
        resultDists.insert(dist, pos)
      elif dist < resultDists[^1]:
        # Replace the farthest node
        var pos = result.len - 1
        while pos > 0 and dist < resultDists[pos - 1]:
          dec pos
        result.insert(node, pos)
        resultDists.insert(dist, pos)
        result.setLen(count)
        resultDists.setLen(count)

proc markFailed*(rt: var RoutingTable, id: NodeId) =
  ## Mark a node as having failed a query.
  let idx = rt.findBucket(id)
  for node in rt.buckets[idx].nodes.mitems:
    if node.id == id:
      node.failCount += 1
      break

proc removeNode*(rt: var RoutingTable, id: NodeId) =
  ## Remove a node from the routing table.
  let idx = rt.findBucket(id)
  var i = 0
  while i < rt.buckets[idx].nodes.len:
    if rt.buckets[idx].nodes[i].id == id:
      rt.buckets[idx].nodes.delete(i)
      break
    inc i

proc totalNodes*(rt: RoutingTable): int =
  for bucket in rt.buckets:
    result += bucket.nodes.len

proc staleBuckets*(rt: RoutingTable, maxAgeSec: float): seq[int] =
  ## Return indices of buckets not refreshed within maxAgeSec seconds.
  let cutoff = epochTime() - maxAgeSec
  for i in 0 ..< rt.buckets.len:
    if rt.buckets[i].lastChanged < cutoff and rt.buckets[i].nodes.len > 0:
      result.add(i)

proc leastRecentlySeenNode*(rt: RoutingTable, bucketIdx: int): DhtNode =
  ## Return the least recently seen node in a bucket (for ping-based refresh).
  assert bucketIdx >= 0 and bucketIdx < rt.buckets.len
  assert rt.buckets[bucketIdx].nodes.len > 0
  result = rt.buckets[bucketIdx].nodes[0]
  for i in 1 ..< rt.buckets[bucketIdx].nodes.len:
    if rt.buckets[bucketIdx].nodes[i].lastSeen < result.lastSeen:
      result = rt.buckets[bucketIdx].nodes[i]

# DHT message encoding/decoding (KRPC protocol)

proc encodeCompactNode*(node: CompactNodeInfo): string =
  ## Encode a node as 26 bytes: 20 byte id + 4 byte IP + 2 byte port (IPv4).
  result = newStringOfCap(26)
  result.add(nodeIdToStr(node.id))
  let ipBytes = parseIpv4(node.ip)
  for b in ipBytes:
    result.add(char(b))
  writeUint16BE(result, node.port)

proc encodeCompactNode6*(node: CompactNodeInfo): string =
  ## Encode a node as 38 bytes: 20 byte id + 16 byte IPv6 + 2 byte port (BEP 32).
  result = newStringOfCap(38)
  result.add(nodeIdToStr(node.id))
  let words = parseIpv6Words(node.ip)
  for w in words:
    writeUint16BE(result, w)
  writeUint16BE(result, node.port)

proc decodeCompactNodes*(data: string): seq[CompactNodeInfo] =
  ## Decode compact node info (26 bytes per node, IPv4).
  if data.len mod 26 != 0:
    return @[]
  let count = data.len div 26
  result = newSeqOfCap[CompactNodeInfo](count)
  for i in 0 ..< count:
    let offset = i * 26
    var node: CompactNodeInfo
    copyMem(addr node.id[0], unsafeAddr data[offset], NodeIdLen)
    var ipBytes: array[4, byte]
    copyMem(addr ipBytes[0], unsafeAddr data[offset + NodeIdLen], 4)
    node.ip = ipv4ToString(ipBytes)
    node.port = readUint16BE(data, offset + 24)
    result.add(node)

proc decodeCompactNodes6*(data: string): seq[CompactNodeInfo] =
  ## Decode compact node info (38 bytes per node, IPv6, BEP 32).
  if data.len mod 38 != 0:
    return @[]
  let count = data.len div 38
  result = newSeqOfCap[CompactNodeInfo](count)
  for i in 0 ..< count:
    let offset = i * 38
    var node: CompactNodeInfo
    copyMem(addr node.id[0], unsafeAddr data[offset], NodeIdLen)
    var words: array[8, uint16]
    for w in 0 ..< 8:
      words[w] = readUint16BE(data, offset + NodeIdLen + w * 2)
    # Build expanded IPv6 directly without seq allocation
    var expanded = newStringOfCap(39)
    for w in 0 ..< 8:
      if w > 0: expanded.add(':')
      expanded.add(words[w].int.toHex(4).toLowerAscii())
    node.ip = canonicalizeIpv6(expanded)
    node.port = readUint16BE(data, offset + 36)
    result.add(node)

proc encodeDhtQuery*(transId: string, queryType: string,
                     args: Table[string, BencodeValue]): string =
  ## Encode a KRPC query message.
  var d = initTable[string, BencodeValue]()
  d["t"] = bStr(transId)
  d["y"] = bStr("q")
  d["q"] = bStr(queryType)
  d["a"] = bDict(args)
  return encode(bDict(d))

proc encodeDhtResponse*(transId: string,
                        resp: Table[string, BencodeValue]): string =
  ## Encode a KRPC response message.
  var d = initTable[string, BencodeValue]()
  d["t"] = bStr(transId)
  d["y"] = bStr("r")
  d["r"] = bDict(resp)
  return encode(bDict(d))

proc encodeDhtError*(transId: string, code: int, msg: string): string =
  ## Encode a KRPC error message.
  var d = initTable[string, BencodeValue]()
  d["t"] = bStr(transId)
  d["y"] = bStr("e")
  d["e"] = bList(bInt(code.int64), bStr(msg))
  return encode(bDict(d))

# Query builders

proc encodePingQuery*(transId: string, ownId: NodeId): string =
  var args = initTable[string, BencodeValue]()
  args["id"] = bStr(nodeIdToStr(ownId))
  return encodeDhtQuery(transId, "ping", args)

proc encodeFindNodeQuery*(transId: string, ownId: NodeId, target: NodeId): string =
  var args = initTable[string, BencodeValue]()
  args["id"] = bStr(nodeIdToStr(ownId))
  args["target"] = bStr(nodeIdToStr(target))
  return encodeDhtQuery(transId, "find_node", args)

proc encodeGetPeersQuery*(transId: string, ownId: NodeId, infoHash: NodeId): string =
  var args = initTable[string, BencodeValue]()
  args["id"] = bStr(nodeIdToStr(ownId))
  args["info_hash"] = bStr(nodeIdToStr(infoHash))
  return encodeDhtQuery(transId, "get_peers", args)

proc encodeAnnouncePeerQuery*(transId: string, ownId: NodeId,
                               infoHash: NodeId, port: uint16,
                               token: string, impliedPort: bool = false): string =
  var args = initTable[string, BencodeValue]()
  args["id"] = bStr(nodeIdToStr(ownId))
  args["info_hash"] = bStr(nodeIdToStr(infoHash))
  args["port"] = bInt(port.int64)
  args["token"] = bStr(token)
  if impliedPort:
    args["implied_port"] = bInt(1)
  return encodeDhtQuery(transId, "announce_peer", args)

# Response builders

proc addCompactNodeList(resp: var Table[string, BencodeValue],
                        nodes: seq[CompactNodeInfo]) =
  ## Encode and add compact nodes split by IP version (BEP 32).
  var nodesStr = ""
  var nodes6Str = ""
  for n in nodes:
    if isIpv6(n.ip):
      nodes6Str.add(encodeCompactNode6(n))
    else:
      nodesStr.add(encodeCompactNode(n))
  if nodesStr.len > 0:
    resp["nodes"] = bStr(nodesStr)
  if nodes6Str.len > 0:
    resp["nodes6"] = bStr(nodes6Str)

proc encodeCompactPeerValue(ip: string, port: uint16): string =
  ## Encode a single peer as compact binary (6 bytes IPv4 or 18 bytes IPv6).
  if isIpv6(ip):
    result = newStringOfCap(18)
    let words = parseIpv6Words(ip)
    for w in words:
      writeUint16BE(result, w)
  else:
    result = newStringOfCap(6)
    let ipBytes = parseIpv4(ip)
    for b in ipBytes:
      result.add(char(b))
  writeUint16BE(result, port)

proc encodePingResponse*(transId: string, ownId: NodeId): string =
  var resp = initTable[string, BencodeValue]()
  resp["id"] = bStr(nodeIdToStr(ownId))
  return encodeDhtResponse(transId, resp)

proc encodeFindNodeResponse*(transId: string, ownId: NodeId,
                              nodes: seq[CompactNodeInfo]): string =
  var resp = initTable[string, BencodeValue]()
  resp["id"] = bStr(nodeIdToStr(ownId))
  resp.addCompactNodeList(nodes)
  return encodeDhtResponse(transId, resp)

proc encodeGetPeersResponse*(transId: string, ownId: NodeId,
                              token: string,
                              peers: seq[tuple[ip: string, port: uint16]] = @[],
                              nodes: seq[CompactNodeInfo] = @[]): string =
  var resp = initTable[string, BencodeValue]()
  resp["id"] = bStr(nodeIdToStr(ownId))
  resp["token"] = bStr(token)

  if peers.len > 0:
    var values: seq[BencodeValue]
    var values6: seq[BencodeValue]
    for p in peers:
      let encoded = encodeCompactPeerValue(p.ip, p.port)
      if isIpv6(p.ip):
        values6.add(bStr(encoded))
      else:
        values.add(bStr(encoded))
    if values.len > 0:
      resp["values"] = BencodeValue(kind: bkList, listVal: values)
    if values6.len > 0:
      resp["values6"] = BencodeValue(kind: bkList, listVal: values6)
  else:
    resp.addCompactNodeList(nodes)

  return encodeDhtResponse(transId, resp)

# Message parser

proc decodeDhtMessage*(data: string): DhtMessage =
  ## Decode a KRPC message from bencoded data.
  let root = decode(data)
  if root.kind != bkDict:
    raise newException(ValueError, "DHT message not a dict")

  let tNode = root.getOrDefault("t")
  if tNode != nil and tNode.kind == bkStr:
    result.transactionId = tNode.strVal

  let yNode = root.getOrDefault("y")
  if yNode == nil or yNode.kind != bkStr:
    raise newException(ValueError, "missing message type")

  case yNode.strVal
  of "q":
    # Query
    result = DhtMessage(isQuery: true, transactionId: result.transactionId)
    let qNode = root.getOrDefault("q")
    if qNode != nil and qNode.kind == bkStr:
      result.queryType = qNode.strVal
    let aNode = root.getOrDefault("a")
    if aNode != nil and aNode.kind == bkDict:
      let idNode = aNode.getOrDefault("id")
      if idNode != nil and idNode.kind == bkStr and idNode.strVal.len == NodeIdLen:
        result.queryerId = strToNodeId(idNode.strVal)
      let targetNode = aNode.getOrDefault("target")
      if targetNode != nil and targetNode.kind == bkStr and targetNode.strVal.len == NodeIdLen:
        result.targetId = strToNodeId(targetNode.strVal)
      let ihNode = aNode.getOrDefault("info_hash")
      if ihNode != nil and ihNode.kind == bkStr and ihNode.strVal.len == NodeIdLen:
        result.infoHash = strToNodeId(ihNode.strVal)
      let portNode = aNode.getOrDefault("port")
      if portNode != nil and portNode.kind == bkInt:
        result.rawAnnouncePort = portNode.intVal
        if portNode.intVal >= 1 and portNode.intVal <= 65535:
          result.announcePort = portNode.intVal.uint16
        else:
          result.announcePort = 0  # Invalid port — don't silently wrap
      let tokenNode = aNode.getOrDefault("token")
      if tokenNode != nil and tokenNode.kind == bkStr:
        result.token = tokenNode.strVal
      let ipNode = aNode.getOrDefault("implied_port")
      if ipNode != nil and ipNode.kind == bkInt:
        result.impliedPort = ipNode.intVal != 0

  of "r":
    # Response
    result = DhtMessage(isQuery: false, transactionId: result.transactionId)
    let rNode = root.getOrDefault("r")
    if rNode != nil and rNode.kind == bkDict:
      let idNode = rNode.getOrDefault("id")
      if idNode != nil and idNode.kind == bkStr and idNode.strVal.len == NodeIdLen:
        result.responderId = strToNodeId(idNode.strVal)
      let nodesNode = rNode.getOrDefault("nodes")
      if nodesNode != nil and nodesNode.kind == bkStr:
        result.nodes = decodeCompactNodes(nodesNode.strVal)
      # BEP 32: IPv6 compact nodes
      let nodes6Node = rNode.getOrDefault("nodes6")
      if nodes6Node != nil and nodes6Node.kind == bkStr:
        result.nodes.add(decodeCompactNodes6(nodes6Node.strVal))
      let valuesNode = rNode.getOrDefault("values")
      if valuesNode != nil and valuesNode.kind == bkList:
        for v in valuesNode.listVal:
          if v.kind == bkStr:
            if v.strVal.len == 18:
              # 18 bytes: single IPv6 compact peer (16 IP + 2 port)
              let peers6 = decodeCompactPeers6(v.strVal)
              for p in peers6:
                result.values.add((p.ip, p.port))
            elif v.strVal.len == 6:
              # 6 bytes: single IPv4 compact peer (4 IP + 2 port)
              let peers = decodeCompactPeers(v.strVal)
              for p in peers:
                result.values.add(p)
            else:
              # Batch: try IPv4 first (more common), fall back to IPv6
              let peers = decodeCompactPeers(v.strVal)
              for p in peers:
                result.values.add(p)
      # BEP 32: IPv6 peer values in separate key
      let values6Node = rNode.getOrDefault("values6")
      if values6Node != nil and values6Node.kind == bkList:
        for v in values6Node.listVal:
          if v.kind == bkStr:
            let peers6 = decodeCompactPeers6(v.strVal)
            for p in peers6:
              result.values.add((p.ip, p.port))
      let tokenNode = rNode.getOrDefault("token")
      if tokenNode != nil and tokenNode.kind == bkStr:
        result.respToken = tokenNode.strVal

  of "e":
    # Error
    result = DhtMessage(isQuery: false, transactionId: result.transactionId)
    let eNode = root.getOrDefault("e")
    if eNode != nil and eNode.kind == bkList and eNode.listVal.len >= 2:
      if eNode.listVal[0].kind == bkInt:
        result.errorCode = eNode.listVal[0].intVal.int
      if eNode.listVal[1].kind == bkStr:
        result.errorMsg = eNode.listVal[1].strVal

  else:
    raise newException(ValueError, "unknown message type: " & yNode.strVal)

# Token generation for announce validation
proc generateToken*(ip: string, secret: string): string =
  ## Generate a token for a peer to use in announce_peer.
  let data = ip & secret
  let hash = sha1(data)
  result = newStringOfCap(4)
  for i in 0 ..< 4:
    result.add(char(hash[i]))

proc validateToken*(token: string, ip: string, secret: string, prevSecret: string): bool =
  ## Validate a token from announce_peer (check against current and previous secret).
  if token == generateToken(ip, secret):
    return true
  if prevSecret.len > 0 and token == generateToken(ip, prevSecret):
    return true
  return false

# Peer storage for DHT
type
  DhtPeerStore* = object
    peers*: Table[NodeId, seq[tuple[ip: string, port: uint16, addedAt: float]]]

proc addPeer*(store: var DhtPeerStore, infoHash: NodeId,
              ip: string, port: uint16) =
  if infoHash notin store.peers:
    store.peers[infoHash] = @[]
  # Check for duplicates
  for existing in store.peers[infoHash]:
    if existing.ip == ip and existing.port == port:
      return
  store.peers[infoHash].add((ip, port, epochTime()))
  if store.peers[infoHash].len > MaxPeersPerInfoHash:
    store.peers[infoHash].delete(0)

proc getPeers*(store: DhtPeerStore, infoHash: NodeId): seq[tuple[ip: string, port: uint16]] =
  if infoHash in store.peers:
    for p in store.peers[infoHash]:
      result.add((p.ip, p.port))

proc expirePeers*(store: var DhtPeerStore, ttlSec: float) =
  ## Remove peers older than ttlSec seconds.
  let cutoff = epochTime() - ttlSec
  var emptyHashes: seq[NodeId]
  for hash, peers in store.peers.mpairs:
    # Filter-rebuild: O(n) instead of O(n²) from repeated delete
    var kept = newSeqOfCap[typeof(peers[0])](peers.len)
    for p in peers:
      if p.addedAt >= cutoff:
        kept.add(p)
    if kept.len == 0:
      emptyHashes.add(hash)
    else:
      peers = kept
  for h in emptyHashes:
    store.peers.del(h)
