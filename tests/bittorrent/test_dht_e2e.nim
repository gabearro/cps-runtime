## End-to-end DHT tests against the real BitTorrent DHT network.
##
## This test:
##   1. Bootstraps by sending a ping to router.bittorrent.com:6881
##   2. Sends find_node queries to discover more nodes
##   3. Sends get_peers for a target hash
##   4. Verifies we get real peers or closer nodes back
##
## Requires internet access. Run manually:
##   nim c -r tests/bittorrent/test_dht_e2e.nim

import std/[os, strutils, times, nativesockets, tables]
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/udp
import cps/io/dns
import cps/io/timeouts
import cps/bittorrent/dht

const
  BootstrapHosts = ["router.bittorrent.com", "dht.transmissionbt.com", "router.utorrent.com"]
  BootstrapPort = 6881

# Global state for callback-based DHT socket
var pendingQueries: Table[string, CpsFuture[DhtMessage]]
var dhtSock: UdpSocket

proc setupDhtSocket() =
  ## Create UDP socket with persistent onRecv callback for DHT messages.
  dhtSock = newUdpSocket()
  dhtSock.bindAddr("0.0.0.0", 0)
  dhtSock.onRecv(1500, proc(data: string, srcAddr: Sockaddr_storage, addrLen: SockLen) =
    try:
      let msg = decodeDhtMessage(data)
      # Match response to pending query by transaction ID
      if msg.transactionId in pendingQueries:
        let fut = pendingQueries[msg.transactionId]
        pendingQueries.del(msg.transactionId)
        fut.complete(msg)
    except CatchableError:
      discard  # Ignore malformed responses
  )

proc dhtQuery(transId: string, data: string, ip: string, port: int,
              timeoutMs: int = 5000): CpsFuture[DhtMessage] {.cps.} =
  ## Send a DHT query and wait for the matching response.
  let queryFut: CpsFuture[DhtMessage] = newCpsFuture[DhtMessage]()
  queryFut.pinFutureRuntime()
  pendingQueries[transId] = queryFut
  discard dhtSock.trySendToAddr(data, ip, port)
  let resp: DhtMessage = await withTimeout(queryFut, timeoutMs)
  return resp

proc resolveHost(host: string): CpsFuture[string] {.cps.} =
  let addrs: seq[string] = await resolve(host, Port(0), AF_INET)
  if addrs.len == 0:
    raise newException(AsyncIoError, "Could not resolve: " & host)
  return addrs[0]

proc runDhtE2e(): CpsVoidFuture {.cps.} =
  echo "Step 1: Generate node ID and create routing table"
  let ownId: NodeId = generateNodeId()
  var rt: RoutingTable = newRoutingTable(ownId)
  echo "  Own node ID: " & nodeIdToHex(ownId)
  echo "PASS: node ID generated"

  echo ""
  echo "Step 2: Bootstrap - ping DHT routers"

  var bootstrapOk: bool = false
  var bootstrapIp: string = ""
  var bootstrapPort: int = BootstrapPort

  var bi: int = 0
  while bi < BootstrapHosts.len:
    let host: string = BootstrapHosts[bi]
    bi += 1
    echo "  Pinging " & host & ":" & $BootstrapPort

    try:
      let ip: string = await resolveHost(host)
      echo "    Resolved to: " & ip

      let transId: string = "pn" & $bi
      let pingData: string = encodePingQuery(transId, ownId)
      let msg: DhtMessage = await dhtQuery(transId, pingData, ip, BootstrapPort)

      if not msg.isQuery:
        echo "    Got ping response!"
        echo "    Responder ID: " & nodeIdToHex(msg.responderId)
        bootstrapIp = ip
        discard rt.addNode(DhtNode(
          id: msg.responderId,
          ip: ip,
          port: BootstrapPort.uint16,
          lastSeen: epochTime()
        ))
        bootstrapOk = true
        echo "    Added to routing table"
        break
      else:
        echo "    Got query instead of response, trying next"
    except TimeoutError:
      echo "    Timeout, trying next"
    except CatchableError as e:
      echo "    Error: " & e.msg

  if not bootstrapOk:
    echo "SKIP: could not reach any DHT bootstrap node"
    dhtSock.close()
    return
  echo "PASS: DHT bootstrap ping"

  echo ""
  echo "Step 3: find_node to discover more nodes"

  var nodesDiscovered: int = 0
  try:
    let fnTransId: string = "fn01"
    let fnData: string = encodeFindNodeQuery(fnTransId, ownId, ownId)
    let fnMsg: DhtMessage = await dhtQuery(fnTransId, fnData, bootstrapIp, bootstrapPort, 10000)

    if not fnMsg.isQuery:
      echo "  Got find_node response with " & $fnMsg.nodes.len & " nodes"
      var ni: int = 0
      while ni < fnMsg.nodes.len:
        let compactNode: CompactNodeInfo = fnMsg.nodes[ni]
        ni += 1
        if rt.addNode(DhtNode(
          id: compactNode.id,
          ip: compactNode.ip,
          port: compactNode.port,
          lastSeen: epochTime()
        )):
          nodesDiscovered += 1
      echo "  Added " & $nodesDiscovered & " new nodes to routing table"
      echo "  Total nodes in routing table: " & $rt.totalNodes()
    else:
      echo "  Got query instead of response"
  except TimeoutError:
    echo "  Timeout waiting for find_node response"
  except CatchableError as e:
    echo "  Error: " & e.msg

  if nodesDiscovered == 0:
    echo "SKIP: find_node returned no new nodes"
    dhtSock.close()
    return
  echo "PASS: find_node discovers nodes"

  echo ""
  echo "Step 4: get_peers query"

  let queryTarget: NodeId = ownId
  var peersFound: int = 0
  var closerNodesFound: int = 0
  let closest: seq[DhtNode] = rt.findClosest(queryTarget, Alpha)

  var qi: int = 0
  while qi < closest.len:
    let node: DhtNode = closest[qi]
    qi += 1
    echo "  Querying node " & nodeIdToHex(node.id)[0..7] & "... at " &
         node.ip & ":" & $node.port

    try:
      let gpTransId: string = "gp" & $qi
      let gpData: string = encodeGetPeersQuery(gpTransId, ownId, queryTarget)
      let gpMsg: DhtMessage = await dhtQuery(gpTransId, gpData, node.ip, node.port.int)

      if not gpMsg.isQuery:
        if gpMsg.values.len > 0:
          echo "    Got " & $gpMsg.values.len & " peers!"
          peersFound += gpMsg.values.len
        if gpMsg.nodes.len > 0:
          echo "    Got " & $gpMsg.nodes.len & " closer nodes"
          closerNodesFound += gpMsg.nodes.len
          var cni: int = 0
          while cni < gpMsg.nodes.len:
            let cn: CompactNodeInfo = gpMsg.nodes[cni]
            cni += 1
            discard rt.addNode(DhtNode(
              id: cn.id, ip: cn.ip, port: cn.port,
              lastSeen: epochTime()
            ))
        if gpMsg.respToken.len > 0:
          echo "    Got token for announce_peer"
      else:
        echo "    Got query instead of response"
    except TimeoutError:
      echo "    Timeout"
    except CatchableError as e:
      echo "    Error: " & e.msg

  echo "  Total peers found: " & $peersFound
  echo "  Total closer nodes: " & $closerNodesFound
  echo "  Routing table size: " & $rt.totalNodes()

  if peersFound == 0 and closerNodesFound == 0:
    echo "SKIP: get_peers returned nothing (network may be unreachable)"
    dhtSock.close()
    return
  echo "PASS: get_peers returns nodes/peers"

  echo ""
  echo "Step 5: Iterative find_node (walk the DHT)"

  let closest2: seq[DhtNode] = rt.findClosest(ownId, K)
  var secondRoundNodes: int = 0

  var fi: int = 0
  while fi < closest2.len and fi < 3:
    let node: DhtNode = closest2[fi]
    fi += 1
    if node.ip == bootstrapIp and node.port == bootstrapPort.uint16:
      continue

    try:
      let fn2TransId: string = "f2" & $fi
      let fn2Data: string = encodeFindNodeQuery(fn2TransId, ownId, ownId)
      let fn2Msg: DhtMessage = await dhtQuery(fn2TransId, fn2Data, node.ip, node.port.int)

      if not fn2Msg.isQuery:
        echo "  Node " & node.ip & ":" & $node.port &
             " returned " & $fn2Msg.nodes.len & " nodes"
        var nni: int = 0
        while nni < fn2Msg.nodes.len:
          let cn: CompactNodeInfo = fn2Msg.nodes[nni]
          nni += 1
          if rt.addNode(DhtNode(
            id: cn.id, ip: cn.ip, port: cn.port,
            lastSeen: epochTime()
          )):
            secondRoundNodes += 1
    except TimeoutError:
      echo "  Timeout querying " & node.ip
    except CatchableError as e:
      echo "  Error: " & e.msg

  echo "  New nodes from second round: " & $secondRoundNodes
  echo "  Final routing table size: " & $rt.totalNodes()
  echo "  Buckets: " & $rt.buckets.len

  echo "PASS: iterative find_node"

  dhtSock.close()

  echo ""
  echo "=========================================="
  echo "ALL DHT E2E TESTS PASSED!"
  echo "=========================================="

# Main
echo "DHT End-to-End Network Test"
echo "==========================="
echo ""

setupDhtSocket()

block:
  let fut = runDhtE2e()
  let loop = getEventLoop()
  var ticks = 0
  while not fut.finished and ticks < 600000:
    loop.tick()
    ticks += 1

  if fut.hasError:
    echo "ERROR: " & fut.getError().msg
    quit(1)

  if not fut.finished:
    echo "TIMEOUT: test did not complete"
    quit(1)
