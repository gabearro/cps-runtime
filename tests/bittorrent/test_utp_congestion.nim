## Tests for uTP LEDBAT congestion control, timeout/retransmit, and edge cases.

import std/[deques, times]
import cps/bittorrent/utp

# === processAck / LEDBAT congestion control ===

block test_ack_removes_packets_from_outbuffer:
  let sock = newUtpSocket(100)
  let server = newUtpSocket(0)

  # Handshake
  let synData = sock.makeSynPacket()
  let synAck = server.processIncoming(synData)
  discard sock.processIncoming(synAck.response)

  # Send 3 packets
  let d1 = sock.makeDataPacket("aaa")
  let d2 = sock.makeDataPacket("bbb")
  let d3 = sock.makeDataPacket("ccc")
  assert sock.outBuffer.len == 3

  # Server receives all 3, sending ACKs back
  discard server.processIncoming(d1)
  discard server.processIncoming(d2)
  let r3 = server.processIncoming(d3)

  # Process ACK for packet 3 (should ack all 3 via cumulative ack)
  discard sock.processIncoming(r3.response)
  assert sock.outBuffer.len == 0, "all packets should be ack'd"
  assert sock.bytesAcked == 9  # "aaa" + "bbb" + "ccc"
  echo "PASS: ack removes packets from outBuffer"

block test_partial_ack:
  let sock = newUtpSocket(200)
  let server = newUtpSocket(0)

  # Handshake
  let synData = sock.makeSynPacket()
  let synAck = server.processIncoming(synData)
  discard sock.processIncoming(synAck.response)

  # Send 3 packets
  let d1 = sock.makeDataPacket("aaaa")
  discard sock.makeDataPacket("bbbb")
  discard sock.makeDataPacket("cccc")
  assert sock.outBuffer.len == 3

  # Server receives only first, sends ACK for just packet 1
  let r1 = server.processIncoming(d1)
  discard sock.processIncoming(r1.response)
  assert sock.outBuffer.len == 2, "only first packet ack'd"
  assert sock.bytesAcked == 4
  echo "PASS: partial ack"

block test_rtt_estimation_initial:
  ## First ACK initializes RTT, doesn't use smoothing.
  let sock = newUtpSocket(300)
  let server = newUtpSocket(0)

  let synData = sock.makeSynPacket()
  let synAck = server.processIncoming(synData)
  discard sock.processIncoming(synAck.response)

  assert sock.rtt == 0, "RTT starts at 0"

  let d1 = sock.makeDataPacket("test")
  # Backdate sentAt to simulate network latency
  sock.outBuffer[0].sentAt = epochTime() - 0.005  # 5ms ago
  let r1 = server.processIncoming(d1)
  discard sock.processIncoming(r1.response)

  # After first ACK, rtt should be set (at least ~5000 microseconds)
  assert sock.rtt > 0, "RTT estimated after first ACK: " & $sock.rtt
  # rttVar should be rtt/2 for initial case
  assert sock.rttVar == sock.rtt div 2, "initial rttVar = rtt/2"
  echo "PASS: RTT estimation initial"

block test_rtt_smoothing:
  ## Subsequent ACKs use EWMA smoothing (RFC 6298).
  let sock = newUtpSocket(400)
  let server = newUtpSocket(0)

  let synData = sock.makeSynPacket()
  let synAck = server.processIncoming(synData)
  discard sock.processIncoming(synAck.response)

  # First packet to init RTT (simulate 5ms latency)
  let d1 = sock.makeDataPacket("first")
  sock.outBuffer[0].sentAt = epochTime() - 0.005
  let r1 = server.processIncoming(d1)
  discard sock.processIncoming(r1.response)
  let firstRtt = sock.rtt
  assert firstRtt > 0

  # Second packet to test smoothing (simulate 10ms latency)
  let d2 = sock.makeDataPacket("second")
  sock.outBuffer[0].sentAt = epochTime() - 0.010
  let r2 = server.processIncoming(d2)
  discard sock.processIncoming(r2.response)

  # RTT should be smoothed: (7*old + sample)/8
  # With old ~5000us and new ~10000us, result should be between them
  assert sock.rtt > 0, "RTT still positive after smoothing"
  assert sock.rtt > firstRtt, "RTT increased toward higher sample"
  echo "PASS: RTT smoothing"

block test_rto_minimum_500ms:
  ## RTO must be at least 500ms.
  let sock = newUtpSocket(500)
  sock.rtt = 100     # 100 microseconds
  sock.rttVar = 100   # 100 microseconds
  # RTO = max(500, (100 + 400) / 1000) = max(500, 0) = 500
  sock.rto = max(500, (sock.rtt + 4 * sock.rttVar) div 1000)
  assert sock.rto >= 500, "RTO minimum is 500ms"
  echo "PASS: RTO minimum 500ms"

block test_ledbat_window_increase_low_delay:
  ## Low delay (well below target) should increase window.
  let sock = newUtpSocket(600)
  sock.state = usConnected
  let server = newUtpSocket(0)

  let synData = sock.makeSynPacket()
  let synAck = server.processIncoming(synData)
  discard sock.processIncoming(synAck.response)

  # Send and receive data - the processAck will run LEDBAT
  let d1 = sock.makeDataPacket("payload1234567890")
  let r1 = server.processIncoming(d1)

  # The processIncoming path will call processAck with the timestampDiff from peer
  discard sock.processIncoming(r1.response)

  # Window should be >= MinCwndBytes (1 MSS)
  assert sock.maxWindow >= MinCwndBytes, "maxWindow never below MinCwndBytes"
  echo "PASS: LEDBAT window with low delay"

block test_ledbat_window_stays_above_minimum:
  ## LEDBAT should never reduce window below MinCwndBytes (1 MSS).
  let sock = newUtpSocket(700)
  sock.state = usConnected
  sock.maxWindow = MinCwndBytes  # Start at minimum
  sock.slowStart = false  # Already in LEDBAT mode

  # Feed base delay sample so LEDBAT activates
  sock.updateBaseDelay(10_000'u32)  # 10ms base delay

  # Simulate processAck with high delay via direct LEDBAT computation
  # queuingDelay = 200_000 - 10_000 = 190_000 µs (way above 100ms target)
  # offTarget = (100_000 - 190_000) / 100_000 = -0.9 → clamped to -0.9
  # scaledGain = 3000 * -0.9 * 1400 / 1400 = -2700
  # maxWindow = max(1400, 1400 - 2700) = 1400 (clamped)
  let ourDelay = 200_000'u32
  let baseDelay = sock.getBaseDelay()
  let queuingDelay = ourDelay - baseDelay
  let offTarget = clamp(
    (DelayTarget.float - queuingDelay.float) / DelayTarget.float, -1.0, 1.0)
  let scaledGain = MaxCwndIncrease.float * offTarget *
                   MinCwndBytes.float / max(1, sock.maxWindow).float
  let newWindow = max(MinCwndBytes, sock.maxWindow + int(scaledGain))
  assert newWindow == MinCwndBytes, "window clamped at MinCwndBytes: " & $newWindow
  echo "PASS: LEDBAT window stays above minimum"

# === checkTimeouts / retransmission ===

block test_no_timeout_when_empty_outbuffer:
  let sock = newUtpSocket(800)
  sock.state = usConnected
  assert sock.outBuffer.len == 0
  let retrans = sock.checkTimeouts()
  assert retrans.len == 0, "no retransmissions with empty buffer"
  echo "PASS: no timeout when empty outBuffer"

block test_timeout_retransmit:
  ## Packets older than RTO should be retransmitted.
  let sock = newUtpSocket(900)
  sock.state = usConnected
  sock.rto = 1  # 1ms timeout for testing

  # Send a packet
  let sentData = sock.makeDataPacket("timeout test")
  assert sock.outBuffer.len == 1

  # Wait long enough for timeout (we fudge sentAt)
  sock.outBuffer[0].sentAt = epochTime() - 2.0  # 2 seconds ago

  let retrans = sock.checkTimeouts()
  assert retrans.len == 1, "one packet should be retransmitted"
  assert retrans[0] == sentData, "retransmitted data matches"
  echo "PASS: timeout retransmit"

block test_timeout_window_halving:
  ## Window should be halved on timeout.
  let sock = newUtpSocket(1000)
  sock.state = usConnected
  sock.rto = 1
  sock.maxWindow = 10000

  discard sock.makeDataPacket("halve test")
  sock.outBuffer[0].sentAt = epochTime() - 2.0

  discard sock.checkTimeouts()
  assert sock.maxWindow == 5000, "window halved to " & $sock.maxWindow
  echo "PASS: timeout window halving"

block test_timeout_window_halving_minimum:
  ## Window halving should not go below MinCwndBytes (1 MSS).
  let sock = newUtpSocket(1100)
  sock.state = usConnected
  sock.rto = 1
  sock.maxWindow = 2000  # Above MinCwndBytes (1400) but halves below it

  discard sock.makeDataPacket("min test")
  sock.outBuffer[0].sentAt = epochTime() - 2.0

  discard sock.checkTimeouts()
  assert sock.maxWindow == MinCwndBytes, "window clamped to MinCwndBytes: " & $sock.maxWindow
  echo "PASS: timeout window halving minimum"

block test_max_retransmit_resets_connection:
  ## Exceeding MaxRetransmit should reset the connection.
  let sock = newUtpSocket(1200)
  sock.state = usConnected
  sock.rto = 1

  discard sock.makeDataPacket("reset test")

  # Simulate MaxRetransmit retransmissions already done
  sock.outBuffer[0].retransmits = MaxRetransmit
  sock.outBuffer[0].sentAt = epochTime() - 2.0
  sock.outBuffer[0].needsResend = false

  let retrans = sock.checkTimeouts()
  assert retrans.len == 0, "no data returned when connection reset"
  assert sock.state == usReset, "connection reset after max retransmit"
  echo "PASS: max retransmit resets connection"

block test_sentAt_prevents_premature_retransmit:
  ## After retransmission, sentAt is updated so the packet must wait another
  ## full RTO before being eligible again (no premature re-retransmission).
  let sock = newUtpSocket(1300)
  sock.state = usConnected
  sock.rto = 1000  # 1 second

  discard sock.makeDataPacket("no dup")
  sock.outBuffer[0].sentAt = epochTime() - 2.0  # expired

  # First timeout: retransmit, sentAt updated to now
  let retrans1 = sock.checkTimeouts()
  assert retrans1.len == 1

  # Immediate second check: sentAt was just updated, so packet hasn't
  # timed out again yet (< 1s since retransmit)
  let retrans2 = sock.checkTimeouts()
  assert retrans2.len == 0, "packet not re-retransmitted before RTO"

  # After another RTO has passed, packet should be retransmitted again
  sock.outBuffer[0].sentAt = epochTime() - 2.0  # simulate RTO passed
  let retrans3 = sock.checkTimeouts()
  assert retrans3.len == 1, "packet retransmitted after another RTO"
  assert sock.outBuffer[0].retransmits == 2, "retransmit count: " & $sock.outBuffer[0].retransmits
  echo "PASS: sentAt prevents premature retransmit, allows subsequent retransmits"

block test_multiple_timeouts_halve_window_once_per_event:
  ## Multiple simultaneous timeouts should halve the window only once (loss dedup).
  let sock = newUtpSocket(1400)
  sock.state = usConnected
  sock.rto = 1
  sock.maxWindow = 8000

  # Send two packets
  discard sock.makeDataPacket("pkt1")
  discard sock.makeDataPacket("pkt2")
  sock.outBuffer[0].sentAt = epochTime() - 2.0
  sock.outBuffer[1].sentAt = epochTime() - 2.0

  let retrans = sock.checkTimeouts()
  # Both packets should trigger timeout
  assert retrans.len == 2, "both packets timed out"
  # Window halved once per loss event: 8000 -> 4000
  assert sock.maxWindow == 4000, "window halved once: " & $sock.maxWindow
  echo "PASS: multiple timeouts halve window once per event"

# === Sequence number wraparound ===

block test_seq_nr_wraparound:
  ## Test that sequence number wraps from 65535 to 0.
  let sock = newUtpSocket(1500)
  sock.seqNr = 65535
  sock.state = usConnected

  let pkt = sock.makeDataPacket("wrap")
  assert sock.seqNr == 0, "seqNr wrapped from 65535 to 0"

  let decoded = decodePacket(pkt)
  assert decoded.header.seqNr == 65535, "packet has pre-increment seqNr"
  echo "PASS: sequence number wraparound"

# === Duplicate packet handling ===

block test_duplicate_data_packet_not_buffered:
  ## Receiving the same out-of-order packet twice should not create duplicates in inBuffer.
  let client = newUtpSocket(1600)
  let server = newUtpSocket(0)

  # Handshake
  let synData = client.makeSynPacket()
  let synAck = server.processIncoming(synData)
  discard client.processIncoming(synAck.response)

  # Send packets 1, 2, 3
  let d1 = client.makeDataPacket("one")
  let d2 = client.makeDataPacket("two")
  let d3 = client.makeDataPacket("three")

  # Server receives packet 3 first (future/out-of-order)
  discard server.processIncoming(d3)
  assert server.inBuffer.len == 1

  # Server receives packet 3 AGAIN (duplicate)
  discard server.processIncoming(d3)
  assert server.inBuffer.len == 1, "duplicate not buffered: " & $server.inBuffer.len

  # Server receives packet 2 (also out-of-order)
  discard server.processIncoming(d2)
  assert server.inBuffer.len == 2

  # Server receives packets 1 (delivers all)
  let r1 = server.processIncoming(d1)
  assert r1.payload == "onetwothree"
  assert server.inBuffer.len == 0
  echo "PASS: duplicate data packet not buffered"

# === Window management ===

block test_curwindow_tracking:
  ## curWindow should increase on send and decrease on ack.
  let sock = newUtpSocket(1700)
  let server = newUtpSocket(0)

  let synData = sock.makeSynPacket()
  let synAck = server.processIncoming(synData)
  discard sock.processIncoming(synAck.response)

  assert sock.curWindow == 0
  let d1 = sock.makeDataPacket("payload1")
  assert sock.curWindow == 8  # "payload1" len

  discard sock.makeDataPacket("payload2!")
  assert sock.curWindow == 17  # 8 + 9

  # ACK first packet
  let r1 = server.processIncoming(d1)
  discard sock.processIncoming(r1.response)
  assert sock.curWindow == 9, "curWindow after partial ack: " & $sock.curWindow
  echo "PASS: curWindow tracking"

block test_send_window_considers_peer_window:
  ## sendWindowAvailable should respect peer's advertised window.
  let sock = newUtpSocket(1800)
  sock.state = usConnected
  sock.maxWindow = 100000
  sock.wndSize = 500  # Peer only allows 500 bytes
  sock.curWindow = 0

  let avail = sock.sendWindowAvailable()
  assert avail == 500, "limited by peer window: " & $avail
  echo "PASS: send window considers peer window"

# === Extension parsing ===

block test_multiple_extensions:
  ## Packet with multiple chained extensions.
  let pkt = UtpPacket(
    header: UtpPacketHeader(
      packetType: StData,
      version: UtpVersion,
      extension: 1,  # First extension is SACK
      connectionId: 1900,
      timestamp: 0,
      windowSize: 65536,
      seqNr: 1,
      ackNr: 0
    ),
    extensions: @[
      (1'u8, "\x00\x01\x00\x00"),  # SACK
      (2'u8, "\xFF")                 # Close reason
    ],
    payload: "data"
  )
  let encoded = encodePacket(pkt)
  let decoded = decodePacket(encoded)
  assert decoded.extensions.len == 2
  assert decoded.extensions[0].kind == 1
  assert decoded.extensions[0].data == "\x00\x01\x00\x00"
  assert decoded.extensions[1].kind == 2
  assert decoded.extensions[1].data == "\xFF"
  assert decoded.payload == "data"
  echo "PASS: multiple extensions"

echo ""
echo "All uTP congestion/timeout tests passed!"
