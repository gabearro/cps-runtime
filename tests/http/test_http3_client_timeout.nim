## HTTP/3 client transport timeout behavior tests.

import cps/runtime
import cps/transform
import cps/eventloop
import cps/http/client/http3 as client_http3
import cps/http/shared/http3 as http3_shared
import cps/http/shared/http3_connection
import cps/http/shared/qpack
import cps/quic/endpoint as quic_endpoint
import cps/quic/connection as quic_connection
import cps/quic/streams as quic_streams
import cps/quic/varint
import ../quic/interop_helpers
import std/[times, strutils, tables]

proc runLoopUntilFinished[T](f: CpsFuture[T], maxTicks: int = 20_000) =
  let loop = getEventLoop()
  var ticks = 0
  while not f.finished and ticks < maxTicks:
    loop.tick()
    inc ticks
  doAssert f.finished, "Timed out waiting for CPS future"

proc runLoopUntilFinished(f: CpsVoidFuture, maxTicks: int = 20_000) =
  let loop = getEventLoop()
  var ticks = 0
  while not f.finished and ticks < maxTicks:
    loop.tick()
    inc ticks
  doAssert f.finished, "Timed out waiting for CPS future"

block testRejectNonPositiveTimeout:
  let fut = client_http3.newHttp3ClientTransport(
    host = "127.0.0.1",
    port = 4433,
    timeoutMs = 0
  )
  var raised = false
  var err = ""
  try:
    runLoopUntilFinished(fut)
  except ValueError as e:
    raised = true
    err = e.msg
  if not raised:
    doAssert fut.hasError(), "Expected timeoutMs <= 0 to fail fast"
    err = fut.getError().msg
  doAssert err.contains("timeoutMs"), "Expected timeout validation error, got: " & err
  echo "PASS: HTTP/3 transport rejects non-positive timeout"

block testRejectOutOfRangePort:
  let fut = client_http3.newHttp3ClientTransport(
    host = "127.0.0.1",
    port = 70_000,
    timeoutMs = 200
  )
  var raised = false
  var err = ""
  try:
    runLoopUntilFinished(fut)
  except ValueError as e:
    raised = true
    err = e.msg
  if not raised:
    doAssert fut.hasError(), "Expected out-of-range port to fail fast"
    err = fut.getError().msg
  doAssert err.toLowerAscii.contains("port"), "Expected port-range validation error, got: " & err
  echo "PASS: HTTP/3 transport rejects out-of-range port"

block testRejectOutOfRangeAuthorityPort:
  let fut = client_http3.doHttp3Request(
    host = "127.0.0.1",
    port = 0,
    meth = "GET",
    path = "/",
    authority = "127.0.0.1:70000",
    headers = @[],
    body = "",
    timeoutMs = 200
  )
  var raised = false
  var err = ""
  try:
    runLoopUntilFinished(fut)
  except ValueError as e:
    raised = true
    err = e.msg
  if not raised:
    doAssert fut.hasError(), "Expected out-of-range authority port to fail fast"
    err = fut.getError().msg
  doAssert err.contains("1..65535"),
    "Expected explicit authority port-range validation error, got: " & err
  echo "PASS: HTTP/3 request rejects out-of-range authority port"

block testTransportConnectRespectsTimeoutBudget:
  let startedAt = epochTime()
  let fut = client_http3.newHttp3ClientTransport(
    host = "127.0.0.1",
    port = 65534, # expected to have no QUIC peer
    timeoutMs = 150
  )
  var raised = false
  var err = ""
  try:
    runLoopUntilFinished(fut, maxTicks = 40_000)
  except ValueError as e:
    raised = true
    err = e.msg
  let elapsedMs = int((epochTime() - startedAt) * 1000.0)
  if not raised:
    doAssert fut.hasError(), "Expected HTTP/3 transport connect to fail without a peer"
    err = fut.getError().msg
  doAssert elapsedMs < 4_000, "Transport timeout budget not respected; elapsed=" & $elapsedMs & "ms"
  doAssert err.contains("timed out") or err.contains("1-RTT") or err.contains("cannot send stream data"),
    "Expected timeout/readiness error, got: " & err
  echo "PASS: HTTP/3 transport connect honors timeout budget"

block testInvalidRequestValidationDoesNotLeakRequestStreams:
  let (certFile, keyFile) = generateTestCert()

  var endpoint: quic_endpoint.QuicEndpoint = nil
  proc onStreamReadable(conn: quic_connection.QuicConnection,
                        streamId: uint64): CpsVoidFuture {.cps.} =
    if endpoint.isNil:
      return
    let streamObj = conn.getOrCreateStream(streamId)
    discard streamObj.popRecvData(high(int))

  var serverCfg = quic_endpoint.defaultQuicEndpointConfig()
  serverCfg.tlsCertFile = certFile
  serverCfg.tlsKeyFile = keyFile
  serverCfg.quicUseRetry = false
  serverCfg.alpn = @["h3"]
  endpoint = quic_endpoint.newQuicServerEndpoint(
    bindHost = "127.0.0.1",
    bindPort = 0,
    config = serverCfg,
    onStreamReadable = onStreamReadable
  )
  endpoint.start()
  let serverPort = getUdpBoundPort(endpoint.dispatcher.socket)

  var clientCfg = quic_endpoint.defaultQuicEndpointConfig()
  clientCfg.tlsVerifyPeer = false
  var transport: client_http3.Http3ClientTransport = nil
  try:
    let transportFut = client_http3.newHttp3ClientTransport(
      host = "127.0.0.1",
      port = serverPort,
      timeoutMs = 2_000,
      endpointConfig = clientCfg
    )
    runLoopUntilFinished(transportFut, maxTicks = 40_000)
    doAssert not transportFut.hasError(),
      "Expected transport bootstrap to succeed for request-validation test"
    transport = transportFut.read()
    let streamsBefore = transport.conn.streams.len

    var raised = false
    var err = ""
    try:
      let reqFut = client_http3.doHttp3RequestOnTransport(
        transport = transport,
        meth = "GE T",
        path = "/bad-method",
        authority = "127.0.0.1:" & $serverPort,
        headers = @[],
        body = "",
        timeoutMs = 500
      )
      runLoopUntilFinished(reqFut, maxTicks = 40_000)
      if reqFut.hasError():
        raised = true
        err = reqFut.getError().msg
    except ValueError as e:
      raised = true
      err = e.msg
    doAssert raised, "Expected invalid request method to be rejected"
    doAssert err.toLowerAscii.contains("method"),
      "Expected invalid method validation error, got: " & err
    doAssert transport.conn.streams.len == streamsBefore,
      "Invalid request input should not allocate/leak a request stream"
    echo "PASS: HTTP/3 transport rejects invalid request input without stream leaks"
  finally:
    if not transport.isNil:
      transport.close(closeSocket = true)
    if not endpoint.isNil:
      endpoint.shutdown(closeSocket = true)

block testTransportRejectsResponseStreamWithoutHeaders:
  let (certFile, keyFile) = generateTestCert()

  var endpoint: quic_endpoint.QuicEndpoint = nil
  var responded = initTable[uint64, bool]()
  proc onStreamReadable(conn: quic_connection.QuicConnection,
                        streamId: uint64): CpsVoidFuture {.cps.} =
    if endpoint.isNil:
      return
    let streamObj = conn.getOrCreateStream(streamId)
    discard streamObj.popRecvData(high(int))
    if not quic_streams.isBidirectionalStream(streamId) or
        not quic_streams.isClientInitiatedStream(streamId):
      return
    if streamId in responded:
      return
    responded[streamId] = true
    # Deliberately send only an unknown frame and FIN (no HEADERS) to validate
    # client-side final-response completeness checks.
    let unknownFrame = http3_shared.encodeHttp3Frame(0xF0700'u64, @[0xAA'u8])
    await endpoint.sendStreamData(conn, streamId, unknownFrame, fin = true)

  var serverCfg = quic_endpoint.defaultQuicEndpointConfig()
  serverCfg.tlsCertFile = certFile
  serverCfg.tlsKeyFile = keyFile
  serverCfg.quicUseRetry = false
  serverCfg.alpn = @["h3"]
  endpoint = quic_endpoint.newQuicServerEndpoint(
    bindHost = "127.0.0.1",
    bindPort = 0,
    config = serverCfg,
    onStreamReadable = onStreamReadable
  )
  endpoint.start()
  let serverPort = getUdpBoundPort(endpoint.dispatcher.socket)

  var clientCfg = quic_endpoint.defaultQuicEndpointConfig()
  clientCfg.tlsVerifyPeer = false
  var transport: client_http3.Http3ClientTransport = nil
  try:
    let transportFut = client_http3.newHttp3ClientTransport(
      host = "127.0.0.1",
      port = serverPort,
      timeoutMs = 2_000,
      endpointConfig = clientCfg
    )
    runLoopUntilFinished(transportFut, maxTicks = 40_000)
    doAssert not transportFut.hasError(),
      "Expected transport bootstrap to succeed for response-validation test"
    transport = transportFut.read()

    let reqFut = client_http3.doHttp3RequestOnTransport(
      transport = transport,
      meth = "GET",
      path = "/no-headers",
      authority = "127.0.0.1:" & $serverPort,
      headers = @[],
      body = "",
      timeoutMs = 1_500
    )
    runLoopUntilFinished(reqFut, maxTicks = 40_000)

    var raised = false
    var err = ""
    if reqFut.hasError():
      raised = true
      err = reqFut.getError().msg
    doAssert raised, "Expected response stream without HEADERS to be rejected"
    doAssert err.toLowerAscii.contains("missing headers"),
      "Expected missing HEADERS error, got: " & err
    echo "PASS: HTTP/3 transport rejects response stream without HEADERS"
  finally:
    if not transport.isNil:
      transport.close(closeSocket = true)
    if not endpoint.isNil:
      endpoint.shutdown(closeSocket = true)

block testTransportRejectsTruncatedBlockedResponseAfterUnblock:
  let (certFile, keyFile) = generateTestCert()

  var endpoint: quic_endpoint.QuicEndpoint = nil
  var responded = initTable[uint64, bool]()
  var qpackSent = false

  proc onStreamReadable(conn: quic_connection.QuicConnection,
                        streamId: uint64): CpsVoidFuture {.cps.} =
    if endpoint.isNil:
      return
    let streamObj = conn.getOrCreateStream(streamId)
    discard streamObj.popRecvData(high(int))
    if not quic_streams.isBidirectionalStream(streamId) or
        not quic_streams.isClientInitiatedStream(streamId):
      return
    if streamId in responded:
      return
    responded[streamId] = true

    # First response HEADERS block is QPACK-blocked, so decode completion is
    # deferred until encoder-stream updates arrive.
    let blockedHeaderBlock = @[0x02'u8, 0x00'u8, 0x80'u8]
    var respPayload = http3_shared.encodeHttp3Frame(http3_shared.H3FrameHeaders, blockedHeaderBlock)
    # Append a deliberately truncated DATA frame. This must be rejected once
    # blocked header decode is unblocked and end-of-stream validation is replayed.
    let fullDataFrame = http3_shared.encodeHttp3Frame(
      http3_shared.H3FrameData,
      @[0x41'u8, 0x42'u8]
    )
    doAssert fullDataFrame.len > 0
    respPayload.add fullDataFrame[0 ..< fullDataFrame.len - 1]
    await endpoint.sendStreamData(conn, streamId, respPayload, fin = true)

    # Unblock the required dynamic entry after the response stream has ended.
    await cpsSleep(30)
    if not qpackSent:
      qpackSent = true
      let qpackUni = conn.openLocalUniStream()
      var encoderStreamBytes: seq[byte] = @[]
      encoderStreamBytes.appendQuicVarInt(http3_shared.H3UniQpackEncoderStream)
      encoderStreamBytes.add encodeEncoderInstruction(QpackEncoderInstruction(
        kind: qeikInsertLiteral,
        name: ":status",
        value: "200"
      ))
      await endpoint.sendStreamData(conn, qpackUni.id, encoderStreamBytes, fin = false)

  var serverCfg = quic_endpoint.defaultQuicEndpointConfig()
  serverCfg.tlsCertFile = certFile
  serverCfg.tlsKeyFile = keyFile
  serverCfg.quicUseRetry = false
  serverCfg.alpn = @["h3"]
  endpoint = quic_endpoint.newQuicServerEndpoint(
    bindHost = "127.0.0.1",
    bindPort = 0,
    config = serverCfg,
    onStreamReadable = onStreamReadable
  )
  endpoint.start()
  let serverPort = getUdpBoundPort(endpoint.dispatcher.socket)

  var clientCfg = quic_endpoint.defaultQuicEndpointConfig()
  clientCfg.tlsVerifyPeer = false
  var transport: client_http3.Http3ClientTransport = nil
  try:
    let transportFut = client_http3.newHttp3ClientTransport(
      host = "127.0.0.1",
      port = serverPort,
      timeoutMs = 2_000,
      endpointConfig = clientCfg
    )
    runLoopUntilFinished(transportFut, maxTicks = 40_000)
    doAssert not transportFut.hasError(),
      "Expected transport bootstrap to succeed for blocked-response truncation test"
    transport = transportFut.read()

    let reqFut = client_http3.doHttp3RequestOnTransport(
      transport = transport,
      meth = "GET",
      path = "/blocked-truncated",
      authority = "127.0.0.1:" & $serverPort,
      headers = @[],
      body = "",
      timeoutMs = 1_500
    )
    runLoopUntilFinished(reqFut, maxTicks = 40_000)

    var raised = false
    var err = ""
    if reqFut.hasError():
      raised = true
      err = reqFut.getError().msg
    doAssert raised,
      "Expected blocked-then-unblocked truncated response to be rejected"
    doAssert err.toLowerAscii.contains("incomplete frame payload"),
      "Expected truncated-frame validation error, got: " & err
    echo "PASS: HTTP/3 transport rejects truncated blocked response after QPACK unblock"
  finally:
    if not transport.isNil:
      transport.close(closeSocket = true)
    if not endpoint.isNil:
      endpoint.shutdown(closeSocket = true)

block testTimedOutRequestDoesNotPoisonTransportOnLateResponse:
  let (certFile, keyFile) = generateTestCert()

  var endpoint: quic_endpoint.QuicEndpoint = nil
  var responded = initTable[uint64, bool]()
  let serverH3 = newHttp3Connection(isClient = false, useRfcQpackWire = true)

  proc onStreamReadable(conn: quic_connection.QuicConnection,
                        streamId: uint64): CpsVoidFuture {.cps.} =
    if endpoint.isNil:
      return
    let streamObj = conn.getOrCreateStream(streamId)
    discard streamObj.popRecvData(high(int))
    if not quic_streams.isBidirectionalStream(streamId) or
        not quic_streams.isClientInitiatedStream(streamId):
      return
    if streamId in responded:
      return
    responded[streamId] = true

    let ordinal = responded.len
    if ordinal == 1:
      await cpsSleep(250)
    var respPayload = serverH3.encodeHeadersFrame(@[
      (":status", "200"),
      ("content-type", "text/plain")
    ])
    let body =
      if ordinal == 1:
        @[byte('l'), byte('a'), byte('t'), byte('e')]
      else:
        @[byte('o'), byte('k')]
    respPayload.add http3_connection.encodeDataFrame(body)
    await endpoint.sendStreamData(conn, streamId, respPayload, fin = true)

  var serverCfg = quic_endpoint.defaultQuicEndpointConfig()
  serverCfg.tlsCertFile = certFile
  serverCfg.tlsKeyFile = keyFile
  serverCfg.quicUseRetry = false
  serverCfg.alpn = @["h3"]
  endpoint = quic_endpoint.newQuicServerEndpoint(
    bindHost = "127.0.0.1",
    bindPort = 0,
    config = serverCfg,
    onStreamReadable = onStreamReadable
  )
  endpoint.start()
  let serverPort = getUdpBoundPort(endpoint.dispatcher.socket)

  var clientCfg = quic_endpoint.defaultQuicEndpointConfig()
  clientCfg.tlsVerifyPeer = false
  var transport: client_http3.Http3ClientTransport = nil
  try:
    let transportFut = client_http3.newHttp3ClientTransport(
      host = "127.0.0.1",
      port = serverPort,
      timeoutMs = 2_000,
      endpointConfig = clientCfg
    )
    runLoopUntilFinished(transportFut, maxTicks = 40_000)
    doAssert not transportFut.hasError(),
      "Expected transport bootstrap to succeed for timeout-poisoning test"
    transport = transportFut.read()

    let slowReq = client_http3.doHttp3RequestOnTransport(
      transport = transport,
      meth = "GET",
      path = "/slow",
      authority = "127.0.0.1:" & $serverPort,
      headers = @[],
      body = "",
      timeoutMs = 60
    )
    runLoopUntilFinished(slowReq, maxTicks = 40_000)
    doAssert slowReq.hasError(), "Expected first request to time out"
    doAssert slowReq.getError().msg.toLowerAscii.contains("timed out"),
      "Expected timeout error on first request"

    let settle = cpsSleep(350)
    runLoopUntilFinished(settle, maxTicks = 40_000)

    let fastReq = client_http3.doHttp3RequestOnTransport(
      transport = transport,
      meth = "GET",
      path = "/fast",
      authority = "127.0.0.1:" & $serverPort,
      headers = @[],
      body = "",
      timeoutMs = 1_000
    )
    runLoopUntilFinished(fastReq, maxTicks = 40_000)
    doAssert not fastReq.hasError(),
      "Expected transport to remain usable after late response on timed-out stream"
    let resp = fastReq.read()
    doAssert resp.statusCode == 200
    doAssert resp.body == "ok"
    echo "PASS: timed-out HTTP/3 request stream does not poison transport when late response arrives"
  finally:
    if not transport.isNil:
      transport.close(closeSocket = true)
    if not endpoint.isNil:
      endpoint.shutdown(closeSocket = true)

echo "All HTTP/3 client timeout tests passed"
