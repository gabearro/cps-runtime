## Test: Bouncer Integration (Unix Socket Handshake)
##
## Starts the bouncer with a dummy config (no real IRC server),
## connects a client via Unix socket, performs the hello handshake,
## verifies server state is received, sends a replay request.

import std/[json, tables, os]
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/unix
import cps/io/buffered
import cps/concurrency/signals
import cps/concurrency/taskgroup
import cps/bouncer/types
import cps/bouncer/protocol
import cps/bouncer/buffer
import cps/bouncer/state
import cps/bouncer/server
import cps/bouncer/daemon

const
  testSocketPath = "/tmp/cps-bouncer-integ-test.sock"
  testLogDir = "/tmp/cps-bouncer-integ-logs/"

proc cleanup() =
  discard tryRemoveFile(testSocketPath)
  removeDir(testLogDir)

proc testClient(): CpsVoidFuture {.cps.} =
  ## Connect to the bouncer, do the handshake, check state, then disconnect.
  # Give the bouncer a moment to start listening
  await cpsSleep(200)

  echo "Client: connecting to bouncer..."
  let stream = await unixConnect(testSocketPath)
  let reader = newBufferedReader(stream.AsyncStream)
  echo "Client: connected!"

  # Send hello
  let helloMsg = BouncerMsg(kind: bmkHello, helloVersion: 1, helloClientName: "test-client")
  let helloLine = helloMsg.toJsonLine() & "\n"
  await stream.write(helloLine)
  echo "Client: sent hello"

  # Read hello_ok
  let okLine = await reader.readLine("\n")
  let okMsg = parseBouncerMsg(okLine)
  assert okMsg.kind == bmkHelloOk, "Expected hello_ok, got: " & $okMsg.kind
  assert okMsg.helloOkVersion == 1
  assert okMsg.helloOkServers == @["testnet"]
  echo "Client: got hello_ok, servers: ", okMsg.helloOkServers

  # Read server_state for "testnet"
  let stateLine = await reader.readLine("\n")
  let stateMsg = parseBouncerMsg(stateLine)
  assert stateMsg.kind == bmkServerState, "Expected server_state, got: " & $stateMsg.kind
  assert stateMsg.ssServer == "testnet"
  assert stateMsg.ssNick == "testbot"
  # Server won't be connected (no real IRC), so connected should be false
  echo "Client: got server_state for '", stateMsg.ssServer, "', connected=", stateMsg.ssConnected,
       ", nick=", stateMsg.ssNick

  # Send replay request (will get replay_end with newestId=0 since no messages)
  let replayMsg = BouncerMsg(kind: bmkReplay,
    replayServer: "testnet", replayChannel: "#test",
    replaySinceId: 0, replayLimit: 100)
  await stream.write(replayMsg.toJsonLine() & "\n")
  echo "Client: sent replay request"

  let replayEndLine = await reader.readLine("\n")
  let replayEnd = parseBouncerMsg(replayEndLine)
  assert replayEnd.kind == bmkReplayEnd, "Expected replay_end, got: " & $replayEnd.kind
  assert replayEnd.reServer == "testnet"
  assert replayEnd.reChannel == "#test"
  echo "Client: got replay_end, newestId=", replayEnd.reNewestId

  # Close
  stream.close()
  echo "Client: disconnected"
  echo ""
  echo "PASS: bouncer integration test (handshake + state + replay)"

proc runTest(): CpsVoidFuture {.cps.} =
  ## Run the bouncer and the test client concurrently.
  cleanup()

  # Create config
  let config = BouncerConfig(
    socketPath: testSocketPath,
    logDir: testLogDir,
    bufferSize: 100,
    flushIntervalMs: 60000,
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

  let bouncer = newBouncer(config)

  # Ensure dirs
  if not dirExists(testLogDir):
    createDir(testLogDir)
  let socketDir = parentDir(testSocketPath)
  if not dirExists(socketDir):
    createDir(socketDir)

  # Initialize servers (won't connect since no real IRC server)
  initServersFromConfig(bouncer, config)

  echo "Starting bouncer client server..."
  # Start accept loop in background
  let serverFut = startClientServer(bouncer)

  # Run test client
  await testClient()

  # Shutdown
  bouncer.running = false
  if bouncer.listener != nil:
    bouncer.listener.close()
  serverFut.cancel()

  cleanup()

block:
  let fut = runTest()
  runCps(fut)

echo "\nBouncer integration test complete!"
