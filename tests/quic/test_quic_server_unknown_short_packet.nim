## QUIC server handling for unknown short-header packets.
##
## Production behavior:
## - Do not create a new connection from an unknown short-header datagram.
## - Emit a stateless reset candidate back to the sender.

when defined(useBoringSSL):
  import std/[net, nativesockets, os, tables, times]
  import cps/eventloop
  import cps/quic
  import ./interop_helpers

  proc tickBounded(loop: EventLoop, maxBlockMs: int = 10) =
    discard loop.registerTimer(maxBlockMs, proc() = discard)
    loop.tick()

  block testServerRejectsUnknownShortPacket:
    var cfg = defaultQuicEndpointConfig()
    cfg.quicUseRetry = false

    let endpoint = newQuicServerEndpoint(
      bindHost = "127.0.0.1",
      bindPort = 0,
      config = cfg
    )
    endpoint.start()

    let serverPort = getUdpBoundPort(endpoint.dispatcher.socket)
    let sock = newSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    defer: sock.close()

    var shortProbe = newSeq[byte](29)
    shortProbe[0] = 0x40'u8 # short header candidate (fixed bit set, long-header bit clear)
    for i in 1 ..< shortProbe.len:
      shortProbe[i] = byte((i * 19) and 0xFF)
    sock.sendTo("127.0.0.1", Port(serverPort), bytesToString(shortProbe))

    let loop = getEventLoop()
    let deadline = epochTime() + 0.5
    while epochTime() < deadline:
      loop.tickBounded()
      sleep(2)

    doAssert len(endpoint.connectionsByCid) == 0,
      "Server created connection from unknown short-header packet"

    sock.getFd().setBlocking(false)
    var gotResetCandidate = false
    let recvDeadline = epochTime() + 0.5
    while epochTime() < recvDeadline and not gotResetCandidate:
      var response = ""
      var fromHost = ""
      var fromPort: Port
      try:
        discard sock.recvFrom(response, 128, fromHost, fromPort)
        if response.len >= 21:
          let first = byte(ord(response[0]))
          gotResetCandidate =
            ((first and 0x80'u8) == 0'u8) and
            ((first and 0x40'u8) != 0'u8)
      except CatchableError:
        discard
      loop.tickBounded()
      sleep(2)

    endpoint.shutdown(closeSocket = true)

    doAssert gotResetCandidate, "Expected stateless reset candidate for unknown short packet"
    echo "PASS: QUIC server rejects unknown short packet and sends stateless reset candidate"

  block testServerDoesNotAmplifyTooShortUnknownShortPacket:
    var cfg = defaultQuicEndpointConfig()
    cfg.quicUseRetry = false

    let endpoint = newQuicServerEndpoint(
      bindHost = "127.0.0.1",
      bindPort = 0,
      config = cfg
    )
    endpoint.start()

    let serverPort = getUdpBoundPort(endpoint.dispatcher.socket)
    let sock = newSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    defer: sock.close()

    var shortProbe = newSeq[byte](12)
    shortProbe[0] = 0x40'u8 # short header candidate
    for i in 1 ..< shortProbe.len:
      shortProbe[i] = byte((i * 31) and 0xFF)
    sock.sendTo("127.0.0.1", Port(serverPort), bytesToString(shortProbe))

    let loop = getEventLoop()
    let deadline = epochTime() + 0.25
    while epochTime() < deadline:
      loop.tickBounded()
      sleep(2)

    sock.getFd().setBlocking(false)
    var gotResponse = false
    let recvDeadline = epochTime() + 0.3
    while epochTime() < recvDeadline and not gotResponse:
      var response = ""
      var fromHost = ""
      var fromPort: Port
      try:
        discard sock.recvFrom(response, 128, fromHost, fromPort)
        gotResponse = response.len > 0
      except CatchableError:
        discard
      loop.tickBounded()
      sleep(2)

    endpoint.shutdown(closeSocket = true)

    doAssert not gotResponse, "Server should not send stateless reset for too-short unknown packet"
    echo "PASS: QUIC server drops too-short unknown short packet without response"

  echo "All QUIC unknown short-header server tests passed"
else:
  echo "SKIP: Unknown short-header server test requires -d:useBoringSSL"
