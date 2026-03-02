## Test: Bouncer End-to-End (All Soju-Style Features)
##
## Tests authentication, BouncerServ commands, dynamic network management,
## channel detach/reattach, auto-away, message search, per-client delivery
## tracking, and config persistence — all over the Unix socket protocol.

import std/[json, tables, os, strutils]
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/unix
import cps/io/buffered
import cps/bouncer/types
import cps/bouncer/protocol
import cps/bouncer/buffer
import cps/bouncer/server
import cps/bouncer/daemon

const
  testSocketPath = "/tmp/cps-bouncer-e2e-test.sock"
  testLogDir = "/tmp/cps-bouncer-e2e-logs/"
  testConfigPath = "/tmp/cps-bouncer-e2e-config.json"
  testPassword = "secret123"

proc cleanup() =
  discard tryRemoveFile(testSocketPath)
  discard tryRemoveFile(testConfigPath)
  discard tryRemoveFile(testConfigPath & ".tmp")
  removeDir(testLogDir)

# ============================================================
# Test helper: connect and handshake
# ============================================================

type
  TestClient = object
    stream: UnixStream
    reader: BufferedReader

proc connectClient(password: string = testPassword,
                   clientName: string = "test-client"): CpsFuture[TestClient] {.cps.} =
  let stream = await unixConnect(testSocketPath)
  let reader = newBufferedReader(stream.AsyncStream)
  let helloMsg = BouncerMsg(kind: bmkHello,
    helloVersion: 1,
    helloClientName: clientName,
    helloPassword: password)
  await stream.write(helloMsg.toJsonLine() & "\n")
  return TestClient(stream: stream, reader: reader)

proc readMsg(tc: TestClient): CpsFuture[BouncerMsg] {.cps.} =
  let line = await tc.reader.readLine("\n")
  return parseBouncerMsg(line)

proc sendMsg(tc: TestClient, msg: BouncerMsg): CpsVoidFuture {.cps.} =
  await tc.stream.write(msg.toJsonLine() & "\n")

proc closeClient(tc: TestClient): CpsVoidFuture {.cps.} =
  tc.stream.close()

# ============================================================
# Test 1: Authentication
# ============================================================

proc testAuthentication(bouncer: Bouncer): CpsVoidFuture {.cps.} =
  echo "--- Test 1: Authentication ---"

  # Test bad password
  echo "  Testing bad password..."
  let badStream = await unixConnect(testSocketPath)
  let badReader = newBufferedReader(badStream.AsyncStream)
  let badHello = BouncerMsg(kind: bmkHello,
    helloVersion: 1, helloClientName: "bad-client", helloPassword: "wrong")
  await badStream.write(badHello.toJsonLine() & "\n")
  let errLine = await badReader.readLine("\n")
  let errMsg = parseBouncerMsg(errLine)
  assert errMsg.kind == bmkError, "Expected error for bad password, got: " & $errMsg.kind
  assert "Authentication" in errMsg.errText or "auth" in errMsg.errText.toLowerAscii(),
    "Error should mention authentication: " & errMsg.errText
  badStream.close()
  echo "  Bad password rejected correctly."

  # Test correct password
  echo "  Testing correct password..."
  let tc = await connectClient()
  let okMsg = await readMsg(tc)
  assert okMsg.kind == bmkHelloOk, "Expected hello_ok, got: " & $okMsg.kind
  echo "  Correct password accepted, servers: ", okMsg.helloOkServers

  # Drain server_state messages
  let stateMsg = await readMsg(tc)
  assert stateMsg.kind == bmkServerState

  await closeClient(tc)
  echo "  PASS: Authentication"
  echo ""

# ============================================================
# Test 2: BouncerServ help + network status
# ============================================================

proc testBouncerServHelp(bouncer: Bouncer): CpsVoidFuture {.cps.} =
  echo "--- Test 2: BouncerServ help + network status ---"

  let tc = await connectClient()
  # Drain hello_ok + server_state
  let okMsg = await readMsg(tc)
  assert okMsg.kind == bmkHelloOk
  let stateMsg = await readMsg(tc)
  assert stateMsg.kind == bmkServerState

  # Send help command via BouncerServ
  echo "  Sending 'help' to BouncerServ..."
  await sendMsg(tc, BouncerMsg(kind: bmkSendPrivmsg,
    spServer: "testnet", spTarget: "BouncerServ", spText: "help"))

  # Read help responses (NOTICEs from BouncerServ) — 6 lines
  var helpLines: seq[string] = @[]
  for i in 0 ..< 6:
    let msg = await readMsg(tc)
    assert msg.kind == bmkMessage
    assert msg.msgData.source == "BouncerServ"
    assert msg.msgData.kind == "notice"
    helpLines.add(msg.msgData.text)
  echo "  Got ", helpLines.len, " help lines"
  assert helpLines.len == 6, "Expected 6 help lines"
  echo "  First help line: ", helpLines[0]

  # Send network status
  echo "  Sending 'network status' to BouncerServ..."
  await sendMsg(tc, BouncerMsg(kind: bmkSendPrivmsg,
    spServer: "testnet", spTarget: "BouncerServ", spText: "network status"))

  let statusMsg = await readMsg(tc)
  assert statusMsg.kind == bmkMessage
  assert statusMsg.msgData.source == "BouncerServ"
  assert "testnet" in statusMsg.msgData.text
  echo "  Network status: ", statusMsg.msgData.text

  await closeClient(tc)
  echo "  PASS: BouncerServ help + network status"
  echo ""

# ============================================================
# Test 3: Dynamic network management (create + delete)
# ============================================================

proc testDynamicNetworks(bouncer: Bouncer): CpsVoidFuture {.cps.} =
  echo "--- Test 3: Dynamic network management ---"

  let tc = await connectClient()
  # Drain hello_ok + server_state
  let okMsg = await readMsg(tc)
  assert okMsg.kind == bmkHelloOk
  let stateMsg = await readMsg(tc)
  assert stateMsg.kind == bmkServerState

  # Create a new network via BouncerServ
  echo "  Creating network 'oftc'..."
  await sendMsg(tc, BouncerMsg(kind: bmkSendPrivmsg,
    spServer: "testnet", spTarget: "BouncerServ",
    spText: "network create -name oftc -host irc.oftc.net -port 6667"))

  # Should get server_added broadcast + BouncerServ notice (2 messages)
  var gotNotice = false
  var gotServerAdded = false
  for i in 0 ..< 2:
    let msg = await readMsg(tc)
    if msg.kind == bmkMessage and msg.msgData.source == "BouncerServ":
      gotNotice = true
      assert "oftc" in msg.msgData.text.toLowerAscii() or "created" in msg.msgData.text.toLowerAscii(),
        "Expected creation notice, got: " & msg.msgData.text
      echo "  BouncerServ response: ", msg.msgData.text
    elif msg.kind == bmkServerAdded:
      gotServerAdded = true
      assert msg.saServer == "oftc"
      echo "  Got server_added for: ", msg.saServer

  assert gotNotice, "Expected BouncerServ notice for network create"
  assert gotServerAdded, "Expected server_added broadcast"

  # Verify it's in the config now
  assert bouncer.servers.hasKey("oftc"), "Server 'oftc' should exist in bouncer.servers"
  echo "  Server 'oftc' exists in bouncer state"

  # Check config was saved
  assert fileExists(testConfigPath), "Config file should exist after save"
  let savedConfig = parseJson(readFile(testConfigPath))
  var foundOftc = false
  for s in savedConfig["servers"]:
    if s["name"].getStr() == "oftc":
      foundOftc = true
      assert s["host"].getStr() == "irc.oftc.net"
      assert s["port"].getInt() == 6667
  assert foundOftc, "Config should contain 'oftc' server"
  echo "  Config persisted correctly"

  # Delete the network
  echo "  Deleting network 'oftc'..."
  await sendMsg(tc, BouncerMsg(kind: bmkSendPrivmsg,
    spServer: "testnet", spTarget: "BouncerServ",
    spText: "network delete oftc"))

  var gotDeleteNotice = false
  var gotServerRemoved = false
  for i in 0 ..< 2:
    let msg = await readMsg(tc)
    if msg.kind == bmkMessage and msg.msgData.source == "BouncerServ":
      gotDeleteNotice = true
      echo "  BouncerServ response: ", msg.msgData.text
    elif msg.kind == bmkServerRemoved:
      gotServerRemoved = true
      assert msg.srServer == "oftc"
      echo "  Got server_removed for: ", msg.srServer

  assert gotDeleteNotice, "Expected BouncerServ notice for network delete"
  assert gotServerRemoved, "Expected server_removed broadcast"
  assert not bouncer.servers.hasKey("oftc"), "Server 'oftc' should be removed from bouncer.servers"
  echo "  Server 'oftc' removed from bouncer state"

  await closeClient(tc)
  echo "  PASS: Dynamic network management"
  echo ""

# ============================================================
# Test 4: Channel detach/reattach
# ============================================================

proc testChannelDetach(bouncer: Bouncer): CpsVoidFuture {.cps.} =
  echo "--- Test 4: Channel detach/reattach ---"

  # First, manually add a channel to the testnet server state
  let server = bouncer.servers["testnet"]
  server.channels["#test"] = ChannelState(
    name: "#test",
    topic: "Test channel",
    users: {"testbot": "", "otheruser": ""}.toTable,
    detachState: cdsAttached,
    detachPolicy: defaultDetachPolicy(),
  )

  let tc = await connectClient()
  # Drain hello_ok + server_state
  let okMsg = await readMsg(tc)
  assert okMsg.kind == bmkHelloOk
  let stateMsg = await readMsg(tc)
  assert stateMsg.kind == bmkServerState

  # Detach the channel
  echo "  Detaching #test..."
  await sendMsg(tc, BouncerMsg(kind: bmkSendPrivmsg,
    spServer: "testnet", spTarget: "BouncerServ",
    spText: "channel update testnet #test -detached"))

  # Expect exactly 2 messages: channel_detach event + BouncerServ notice
  var gotDetachNotice = false
  var gotDetachEvent = false
  for i in 0 ..< 2:
    let msg = await readMsg(tc)
    if msg.kind == bmkMessage and msg.msgData.source == "BouncerServ":
      gotDetachNotice = true
      echo "  BouncerServ response: ", msg.msgData.text
    elif msg.kind == bmkChannelDetach:
      gotDetachEvent = true
      assert msg.cdServer == "testnet"
      assert msg.cdChannel == "#test"
      echo "  Got channel_detach event"

  assert gotDetachNotice, "Expected detach notice"
  assert gotDetachEvent, "Expected channel_detach event"

  # Verify channel state
  assert server.channels["#test"].detachState == cdsDetached,
    "Channel should be detached"
  echo "  Channel state is cdsDetached"

  # Verify isChannelDetached helper
  assert isChannelDetached(bouncer, "testnet", "#test"),
    "isChannelDetached should return true"

  # Reattach the channel
  echo "  Reattaching #test..."
  await sendMsg(tc, BouncerMsg(kind: bmkSendPrivmsg,
    spServer: "testnet", spTarget: "BouncerServ",
    spText: "channel update testnet #test -attached"))

  # Expect exactly 2 messages: channel_attach event + BouncerServ notice
  var gotAttachNotice = false
  var gotAttachEvent = false
  for i in 0 ..< 2:
    let msg = await readMsg(tc)
    if msg.kind == bmkMessage and msg.msgData.source == "BouncerServ":
      gotAttachNotice = true
      echo "  BouncerServ response: ", msg.msgData.text
    elif msg.kind == bmkChannelAttach:
      gotAttachEvent = true
      assert msg.caServer == "testnet"
      assert msg.caChannel == "#test"
      echo "  Got channel_attach event"

  assert gotAttachNotice, "Expected attach notice"
  assert gotAttachEvent, "Expected channel_attach event"
  assert server.channels["#test"].detachState == cdsAttached,
    "Channel should be reattached"
  echo "  Channel state is cdsAttached"

  await closeClient(tc)
  echo "  PASS: Channel detach/reattach"
  echo ""

# ============================================================
# Test 5: Message search
# ============================================================

proc testSearch(bouncer: Bouncer): CpsVoidFuture {.cps.} =
  echo "--- Test 5: Message search ---"

  # Insert some messages into the buffer
  let key = bufferKey("testnet", "#test")
  if key notin bouncer.buffers:
    bouncer.buffers[key] = newMessageRingBuffer(100)
  let rb = bouncer.buffers[key]

  rb.push(BufferedMessage(id: 1, timestamp: 1000.0, kind: "privmsg",
    source: "alice", target: "#test", text: "Hello world from CPS!"))
  rb.push(BufferedMessage(id: 2, timestamp: 1001.0, kind: "privmsg",
    source: "bob", target: "#test", text: "Testing the bouncer"))
  rb.push(BufferedMessage(id: 3, timestamp: 1002.0, kind: "privmsg",
    source: "alice", target: "#test", text: "CPS is awesome"))
  rb.push(BufferedMessage(id: 4, timestamp: 1003.0, kind: "notice",
    source: "server", target: "#test", text: "Server notice"))

  let tc = await connectClient()
  # Drain hello_ok + server_state
  let okMsg = await readMsg(tc)
  assert okMsg.kind == bmkHelloOk
  let stateMsg = await readMsg(tc)
  assert stateMsg.kind == bmkServerState

  # Search via BouncerServ
  echo "  Searching for 'CPS' via BouncerServ..."
  await sendMsg(tc, BouncerMsg(kind: bmkSendPrivmsg,
    spServer: "testnet", spTarget: "BouncerServ",
    spText: "search CPS"))

  # Should get header line + result lines
  var resultLines: seq[string] = @[]
  for i in 0 ..< 3:
    let msg = await readMsg(tc)
    assert msg.kind == bmkMessage
    assert msg.msgData.source == "BouncerServ"
    resultLines.add(msg.msgData.text)
    echo "  Search result: ", msg.msgData.text

  assert resultLines.len > 0, "Expected search results"
  assert "2 result" in resultLines[0], "Expected 2 results, got: " & resultLines[0]

  # Search via protocol search message
  echo "  Searching via protocol bmkSearch..."
  await sendMsg(tc, BouncerMsg(kind: bmkSearch,
    searchText: "bouncer", searchServer: "testnet",
    searchLimit: 10))

  let searchResult = await readMsg(tc)
  assert searchResult.kind == bmkSearchResults
  assert searchResult.srchMessages.len == 1, "Expected 1 result for 'bouncer'"
  assert searchResult.srchMessages[0].source == "bob"
  echo "  Protocol search found: ", searchResult.srchMessages[0].text

  # Search with nick filter
  echo "  Searching for messages from 'alice'..."
  await sendMsg(tc, BouncerMsg(kind: bmkSearch,
    searchText: "", searchNick: "alice", searchServer: "testnet",
    searchLimit: 10))

  let aliceResult = await readMsg(tc)
  assert aliceResult.kind == bmkSearchResults
  assert aliceResult.srchMessages.len == 2, "Expected 2 results from alice, got: " & $aliceResult.srchMessages.len
  echo "  Found ", aliceResult.srchMessages.len, " messages from alice"

  await closeClient(tc)
  echo "  PASS: Message search"
  echo ""

# ============================================================
# Test 6: Config persistence
# ============================================================

proc testConfigPersistence(bouncer: Bouncer): CpsVoidFuture {.cps.} =
  echo "--- Test 6: Config persistence ---"

  # Trigger a config save
  saveConfig(bouncer)

  assert fileExists(testConfigPath), "Config file should exist"
  let j = parseJson(readFile(testConfigPath))

  assert j["socketPath"].getStr() == testSocketPath
  assert j["logDir"].getStr() == testLogDir
  assert j["bufferSize"].getInt() == 100
  assert j["password"].getStr() == testPassword
  assert j["autoAway"].getBool() == true
  assert j["autoAwayMessage"].getStr() == "Gone bouncing"

  let servers = j["servers"]
  assert servers.len >= 1
  assert servers[0]["name"].getStr() == "testnet"
  assert servers[0]["host"].getStr() == "127.0.0.1"
  assert servers[0]["useTls"].getBool() == false

  echo "  Config file verified:"
  echo "    socketPath: ", j["socketPath"].getStr()
  echo "    password: <present>"
  echo "    autoAway: ", j["autoAway"].getBool()
  echo "    servers: ", servers.len

  echo "  PASS: Config persistence"
  echo ""

# ============================================================
# Test 7: Per-client delivery tracking
# ============================================================

proc testDeliveryTracking(bouncer: Bouncer): CpsVoidFuture {.cps.} =
  echo "--- Test 7: Per-client delivery tracking ---"

  # Connect first client
  let tc1 = await connectClient(clientName = "client-alpha")
  let ok1 = await readMsg(tc1)
  assert ok1.kind == bmkHelloOk
  let state1 = await readMsg(tc1)
  assert state1.kind == bmkServerState

  # Broadcast a message to the client
  let testMsg = BufferedMessage(
    id: 100, timestamp: 2000.0, kind: "privmsg",
    source: "testuser", target: "#test", text: "Delivery tracking test")
  await broadcastToClients(bouncer, "testnet", testMsg)

  # Read the broadcast message
  let delivered = await readMsg(tc1)
  assert delivered.kind == bmkMessage
  assert delivered.msgData.id == 100
  echo "  Message delivered to client-alpha"

  # Check that lastDeliveredIds was updated
  let deliveryKey = bufferKey("testnet", "#test")
  assert bouncer.clients.len > 0
  let session = bouncer.clients[0]
  assert session.lastDeliveredIds.hasKey(deliveryKey),
    "lastDeliveredIds should have key: " & deliveryKey
  assert session.lastDeliveredIds[deliveryKey] == 100,
    "lastDeliveredIds should be 100, got: " & $session.lastDeliveredIds[deliveryKey]
  echo "  Delivery ID tracked: ", session.lastDeliveredIds[deliveryKey]

  await closeClient(tc1)
  # Give the bouncer a moment to process the disconnect
  await cpsSleep(50)

  # Check that delivery IDs were saved to disk
  let clientDir = testLogDir & "clients/"
  let clientFile = clientDir & "client-alpha.json"
  assert fileExists(clientFile), "Client delivery file should exist: " & clientFile
  let saved = parseJson(readFile(clientFile))
  assert saved.hasKey(deliveryKey)
  assert saved[deliveryKey].getBiggestInt() == 100
  echo "  Delivery IDs persisted to disk"

  # Reconnect and verify delivery IDs are loaded
  let tc2 = await connectClient(clientName = "client-alpha")
  let ok2 = await readMsg(tc2)
  assert ok2.kind == bmkHelloOk
  let state2 = await readMsg(tc2)
  assert state2.kind == bmkServerState

  # Check that the loaded session has the saved delivery IDs
  assert bouncer.clients.len > 0
  let reloadedSession = bouncer.clients[0]
  assert reloadedSession.lastDeliveredIds.hasKey(deliveryKey),
    "Reloaded session should have delivery ID for: " & deliveryKey
  assert reloadedSession.lastDeliveredIds[deliveryKey] == 100,
    "Reloaded delivery ID should be 100"
  echo "  Delivery IDs reloaded from disk"

  await closeClient(tc2)
  await cpsSleep(50)

  echo "  PASS: Per-client delivery tracking"
  echo ""

# ============================================================
# Test 8: Channel status command
# ============================================================

proc testChannelStatus(bouncer: Bouncer): CpsVoidFuture {.cps.} =
  echo "--- Test 8: Channel status command ---"

  let tc = await connectClient()
  let okMsg = await readMsg(tc)
  assert okMsg.kind == bmkHelloOk
  let stateMsg = await readMsg(tc)
  assert stateMsg.kind == bmkServerState

  # Query channel status
  await sendMsg(tc, BouncerMsg(kind: bmkSendPrivmsg,
    spServer: "testnet", spTarget: "BouncerServ",
    spText: "channel status"))

  let statusMsg = await readMsg(tc)
  assert statusMsg.kind == bmkMessage
  assert statusMsg.msgData.source == "BouncerServ"
  assert "#test" in statusMsg.msgData.text
  echo "  Channel status: ", statusMsg.msgData.text

  await closeClient(tc)
  echo "  PASS: Channel status command"
  echo ""

# ============================================================
# Test 9: Duplicate network prevention
# ============================================================

proc testDuplicateNetwork(bouncer: Bouncer): CpsVoidFuture {.cps.} =
  echo "--- Test 9: Duplicate network prevention ---"

  let tc = await connectClient()
  let okMsg = await readMsg(tc)
  assert okMsg.kind == bmkHelloOk
  let stateMsg = await readMsg(tc)
  assert stateMsg.kind == bmkServerState

  # Try to create a network with the same name as existing one
  await sendMsg(tc, BouncerMsg(kind: bmkSendPrivmsg,
    spServer: "testnet", spTarget: "BouncerServ",
    spText: "network create -name testnet -host example.com"))

  let errMsg = await readMsg(tc)
  assert errMsg.kind == bmkMessage
  assert errMsg.msgData.source == "BouncerServ"
  assert "already exists" in errMsg.msgData.text.toLowerAscii() or
         "error" in errMsg.msgData.text.toLowerAscii(),
    "Expected duplicate error, got: " & errMsg.msgData.text
  echo "  Duplicate rejected: ", errMsg.msgData.text

  await closeClient(tc)
  echo "  PASS: Duplicate network prevention"
  echo ""

# ============================================================
# Test 10: Message replay with buffered data
# ============================================================

proc testReplayWithData(bouncer: Bouncer): CpsVoidFuture {.cps.} =
  echo "--- Test 10: Message replay ---"

  let tc = await connectClient()
  let okMsg = await readMsg(tc)
  assert okMsg.kind == bmkHelloOk
  let stateMsg = await readMsg(tc)
  assert stateMsg.kind == bmkServerState

  # Request replay since ID 0 (should get all messages in buffer)
  await sendMsg(tc, BouncerMsg(kind: bmkReplay,
    replayServer: "testnet", replayChannel: "#test",
    replaySinceId: 0, replayLimit: 100))

  var replayedMessages: seq[BufferedMessage] = @[]
  var replayEnded = false
  while not replayEnded:
    let msg = await readMsg(tc)
    if msg.kind == bmkMessage:
      replayedMessages.add(msg.msgData)
    elif msg.kind == bmkReplayEnd:
      replayEnded = true
      echo "  Replay ended, newestId=", msg.reNewestId

  echo "  Replayed ", replayedMessages.len, " messages"
  # We inserted 4 messages + 1 delivery tracking test message = 5 total
  assert replayedMessages.len >= 4, "Expected at least 4 replayed messages, got: " & $replayedMessages.len

  # Request replay since ID 2 (should skip first 2)
  await sendMsg(tc, BouncerMsg(kind: bmkReplay,
    replayServer: "testnet", replayChannel: "#test",
    replaySinceId: 2, replayLimit: 100))

  var replayedSince2: seq[BufferedMessage] = @[]
  replayEnded = false
  while not replayEnded:
    let msg = await readMsg(tc)
    if msg.kind == bmkMessage:
      replayedSince2.add(msg.msgData)
    elif msg.kind == bmkReplayEnd:
      replayEnded = true

  echo "  Replayed since ID 2: ", replayedSince2.len, " messages"
  assert replayedSince2.len < replayedMessages.len,
    "Should have fewer messages when replaying since ID 2"

  await closeClient(tc)
  echo "  PASS: Message replay"
  echo ""

# ============================================================
# Main test runner
# ============================================================

proc runAllTests(): CpsVoidFuture {.cps.} =
  cleanup()

  # Create config with password
  let config = BouncerConfig(
    socketPath: testSocketPath,
    logDir: testLogDir,
    bufferSize: 100,
    flushIntervalMs: 60000,
    password: testPassword,
    autoAway: true,
    autoAwayMessage: "Gone bouncing",
    servers: @[BouncerServerConfig(
      name: "testnet",
      host: "127.0.0.1",
      port: 16667,  # No server listening here
      nick: "testbot",
      username: "cps",
      realname: "Test",
      useTls: false,
      autoJoinChannels: @["#test"],
    )],
  )

  let bouncer = newBouncer(config, testConfigPath)

  # Ensure dirs
  if not dirExists(testLogDir):
    createDir(testLogDir)
  let socketDir = parentDir(testSocketPath)
  if not dirExists(socketDir):
    createDir(socketDir)

  # Initialize servers
  initServersFromConfig(bouncer, config)

  echo "Starting bouncer for E2E tests..."
  echo ""

  # Start accept loop
  let serverFut = startClientServer(bouncer)

  # Give the listener a moment to bind
  await cpsSleep(100)

  # Run all tests sequentially
  await testAuthentication(bouncer)
  await testBouncerServHelp(bouncer)
  await testConfigPersistence(bouncer)
  await testChannelDetach(bouncer)
  await testSearch(bouncer)
  await testDeliveryTracking(bouncer)
  await testChannelStatus(bouncer)
  await testDuplicateNetwork(bouncer)
  await testDynamicNetworks(bouncer)
  await testReplayWithData(bouncer)

  # Shutdown
  bouncer.running = false
  if bouncer.listener != nil:
    bouncer.listener.close()
  serverFut.cancel()

  cleanup()

block:
  let fut = runAllTests()
  runCps(fut)

echo "============================================"
echo "ALL BOUNCER E2E TESTS PASSED!"
echo "============================================"
