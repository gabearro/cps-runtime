## Tests for BEP 29: uTorrent Transport Protocol (uTP).

import std/deques
import cps/bittorrent/utp

block test_header_encode_decode_roundtrip:
  let hdr = UtpPacketHeader(
    packetType: StSyn,
    version: UtpVersion,
    extension: 0,
    connectionId: 12345,
    timestamp: 1000000,
    timestampDiff: 500,
    windowSize: 65536,
    seqNr: 1,
    ackNr: 0
  )
  let encoded = encodeHeader(hdr)
  assert encoded.len == UtpHeaderSize
  let decoded = decodeHeader(encoded)
  assert decoded.packetType == StSyn
  assert decoded.version == UtpVersion
  assert decoded.connectionId == 12345
  assert decoded.timestamp == 1000000
  assert decoded.timestampDiff == 500
  assert decoded.windowSize == 65536
  assert decoded.seqNr == 1
  assert decoded.ackNr == 0
  echo "PASS: header encode/decode roundtrip"

block test_header_too_short:
  var caught = false
  try:
    discard decodeHeader("too short")
  except ValueError:
    caught = true
  assert caught, "should raise on short packet"
  echo "PASS: header too short"

block test_packet_encode_decode_roundtrip:
  let pkt = UtpPacket(
    header: UtpPacketHeader(
      packetType: StData,
      version: UtpVersion,
      extension: 0,
      connectionId: 5000,
      timestamp: 2000000,
      timestampDiff: 100,
      windowSize: 1048576,
      seqNr: 42,
      ackNr: 41
    ),
    payload: "Hello, uTP!"
  )
  let encoded = encodePacket(pkt)
  let decoded = decodePacket(encoded)
  assert decoded.header.packetType == StData
  assert decoded.header.connectionId == 5000
  assert decoded.header.seqNr == 42
  assert decoded.header.ackNr == 41
  assert decoded.payload == "Hello, uTP!"
  echo "PASS: packet encode/decode roundtrip"

block test_wrong_version:
  var pkt = UtpPacket(
    header: UtpPacketHeader(
      packetType: StData,
      version: 2,  # Wrong version
      connectionId: 100,
      timestamp: 0,
      windowSize: 65536,
      seqNr: 1,
      ackNr: 0
    )
  )
  let encoded = encodePacket(pkt)
  var caught = false
  try:
    discard decodePacket(encoded)
  except ValueError:
    caught = true
  assert caught, "should reject wrong version"
  echo "PASS: wrong version rejection"

block test_new_utp_socket:
  let sock = newUtpSocket(100)
  assert sock.state == usIdle
  assert sock.connectionId == 100
  assert sock.sendConnectionId == 101
  assert sock.seqNr == 1
  assert sock.ackNr == 0
  assert sock.maxWindow == 2 * MaxPacketSize  # Slow start initial window
  assert sock.curWindow == 0
  echo "PASS: newUtpSocket"

block test_syn_packet:
  let sock = newUtpSocket(200)
  let synData = sock.makeSynPacket()
  assert sock.state == usSynSent
  assert sock.seqNr == 2  # Incremented after SYN

  let decoded = decodeHeader(synData)
  assert decoded.packetType == StSyn
  assert decoded.version == UtpVersion
  assert decoded.connectionId == 200
  assert decoded.seqNr == 1
  echo "PASS: makeSynPacket"

block test_state_packet:
  let sock = newUtpSocket(300)
  sock.ackNr = 5
  let stateData = sock.makeStatePacket()
  let decoded = decodeHeader(stateData)
  assert decoded.packetType == StState
  assert decoded.connectionId == 301  # sendConnectionId
  assert decoded.ackNr == 5
  echo "PASS: makeStatePacket"

block test_data_packet:
  let sock = newUtpSocket(400)
  sock.state = usConnected
  let payload = "test data payload"
  let dataPacket = sock.makeDataPacket(payload)

  assert sock.seqNr == 2  # Incremented
  assert sock.curWindow == payload.len
  assert sock.outBuffer.len == 1

  let decoded = decodePacket(dataPacket)
  assert decoded.header.packetType == StData
  assert decoded.header.connectionId == 401
  assert decoded.payload == payload
  echo "PASS: makeDataPacket"

block test_fin_packet:
  let sock = newUtpSocket(500)
  let finData = sock.makeFinPacket()
  assert sock.state == usFinSent
  assert sock.seqNr == 2

  let decoded = decodeHeader(finData)
  assert decoded.packetType == StFin
  assert decoded.connectionId == 501
  echo "PASS: makeFinPacket"

block test_reset_packet:
  let sock = newUtpSocket(600)
  let resetData = sock.makeResetPacket()
  assert sock.state == usReset

  let decoded = decodeHeader(resetData)
  assert decoded.packetType == StReset
  echo "PASS: makeResetPacket"

block test_connection_handshake:
  ## Simulate initiator (client) and responder (server) handshake.
  let client = newUtpSocket(700)
  let server = newUtpSocket(0)  # Will be set from SYN

  # Client sends SYN
  let synData = client.makeSynPacket()
  assert client.state == usSynSent

  # Server processes SYN
  let serverResp = server.processIncoming(synData)
  assert server.state == usConnected
  assert serverResp.response.len > 0  # STATE packet
  assert serverResp.stateChanged

  # Client processes STATE (SYN-ACK)
  let clientResp = client.processIncoming(serverResp.response)
  assert client.state == usConnected
  assert clientResp.stateChanged
  echo "PASS: connection handshake"

block test_data_transfer:
  ## Simulate data transfer after handshake.
  let client = newUtpSocket(800)
  let server = newUtpSocket(0)

  # Handshake
  let synData = client.makeSynPacket()
  let synAck = server.processIncoming(synData)
  discard client.processIncoming(synAck.response)

  # Client sends data
  let payload = "Hello from client!"
  let dataPacket = client.makeDataPacket(payload)

  # Server receives data
  let dataResp = server.processIncoming(dataPacket)
  assert dataResp.payload == payload
  assert dataResp.response.len > 0  # ACK
  assert server.bytesReceived == payload.len.int64

  # Client receives ACK
  discard client.processIncoming(dataResp.response)
  assert client.bytesAcked == payload.len.int64
  echo "PASS: data transfer"

block test_fin_close:
  ## Simulate connection close via FIN.
  let client = newUtpSocket(900)
  let server = newUtpSocket(0)

  # Handshake
  let synData = client.makeSynPacket()
  let synAck = server.processIncoming(synData)
  discard client.processIncoming(synAck.response)

  # Client sends FIN
  let finData = client.makeFinPacket()
  assert client.state == usFinSent

  # Server receives FIN
  let finResp = server.processIncoming(finData)
  assert server.state == usDestroyed
  assert finResp.response.len > 0  # Final ACK
  assert finResp.stateChanged

  # Client receives final ACK
  let closeResp = client.processIncoming(finResp.response)
  assert client.state == usDestroyed
  assert closeResp.stateChanged
  echo "PASS: FIN close"

block test_reset_close:
  ## Simulate connection reset.
  let client = newUtpSocket(1000)
  let server = newUtpSocket(0)

  # Handshake
  let synData = client.makeSynPacket()
  let synAck = server.processIncoming(synData)
  discard client.processIncoming(synAck.response)

  # Server sends RESET
  let resetData = server.makeResetPacket()
  assert server.state == usReset

  # Client receives RESET
  let resetResp = client.processIncoming(resetData)
  assert client.state == usReset
  assert resetResp.stateChanged
  echo "PASS: RESET close"

block test_can_send:
  let sock = newUtpSocket(1100)
  assert not sock.canSend()  # Not connected

  sock.state = usConnected
  assert sock.canSend()  # Connected, window open

  sock.curWindow = sock.maxWindow  # Window full
  assert not sock.canSend()
  echo "PASS: canSend"

block test_send_window_available:
  let sock = newUtpSocket(1200)
  assert sock.sendWindowAvailable() == 0  # Not connected

  sock.state = usConnected
  let avail = sock.sendWindowAvailable()
  assert avail > 0
  assert avail <= sock.maxWindow
  echo "PASS: sendWindowAvailable"

block test_out_of_order_buffering:
  ## Simulate out-of-order packet delivery.
  let client = newUtpSocket(1300)
  let server = newUtpSocket(0)

  # Handshake
  let synData = client.makeSynPacket()
  let synAck = server.processIncoming(synData)
  discard client.processIncoming(synAck.response)

  # Client sends two data packets
  let data1 = client.makeDataPacket("first")
  let data2 = client.makeDataPacket("second")

  # Server receives packet 2 first (out of order)
  let resp2 = server.processIncoming(data2)
  assert resp2.payload == ""  # Buffered, not delivered
  assert server.inBuffer.len == 1

  # Server receives packet 1
  let resp1 = server.processIncoming(data1)
  assert resp1.payload == "firstsecond"  # Both delivered in order
  assert server.inBuffer.len == 0
  echo "PASS: out-of-order buffering"

block test_multiple_data_packets:
  ## Send multiple packets in sequence.
  let client = newUtpSocket(1400)
  let server = newUtpSocket(0)

  # Handshake
  let synData = client.makeSynPacket()
  let synAck = server.processIncoming(synData)
  discard client.processIncoming(synAck.response)

  var totalReceived = 0
  for i in 0 ..< 5:
    let payload = "packet" & $i
    let pkt = client.makeDataPacket(payload)
    let resp = server.processIncoming(pkt)
    assert resp.payload == payload
    totalReceived += payload.len
    # ACK back
    if resp.response.len > 0:
      discard client.processIncoming(resp.response)

  assert server.bytesReceived == totalReceived.int64
  echo "PASS: multiple data packets"

block test_packet_with_extensions:
  let pkt = UtpPacket(
    header: UtpPacketHeader(
      packetType: StData,
      version: UtpVersion,
      extension: 1,  # Selective ACK extension
      connectionId: 1500,
      timestamp: 0,
      windowSize: 65536,
      seqNr: 1,
      ackNr: 0
    ),
    extensions: @[(1'u8, "\x00\x01\x00\x00")],  # SACK data
    payload: "with ext"
  )
  let encoded = encodePacket(pkt)
  let decoded = decodePacket(encoded)
  assert decoded.extensions.len == 1
  assert decoded.extensions[0].kind == 1
  assert decoded.extensions[0].data == "\x00\x01\x00\x00"
  assert decoded.payload == "with ext"
  echo "PASS: packet with extensions"

block test_simultaneous_fin:
  ## Both sides send FIN simultaneously.
  let client = newUtpSocket(1600)
  let server = newUtpSocket(0)

  # Handshake
  let synData = client.makeSynPacket()
  let synAck = server.processIncoming(synData)
  discard client.processIncoming(synAck.response)

  # Both send FIN
  let clientFin = client.makeFinPacket()
  let serverFin = server.makeFinPacket()
  assert client.state == usFinSent
  assert server.state == usFinSent

  # Client receives server's FIN
  let clientResp = client.processIncoming(serverFin)
  assert client.state == usDestroyed

  # Server receives client's FIN
  let serverResp = server.processIncoming(clientFin)
  assert server.state == usDestroyed
  echo "PASS: simultaneous FIN"

echo "All uTP tests passed!"
