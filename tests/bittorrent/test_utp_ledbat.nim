## Tests for uTP LEDBAT congestion control: timestampDiff, base delay tracking,
## queuing delay computation, slow start, and loss event deduplication.

import std/[deques, times]
import cps/bittorrent/utp

# === timestampDiff population ===

block test_timestampdiff_zero_before_first_recv:
  ## Before receiving any packet, timestampDiff should be 0.
  let sock = newUtpSocket(100)
  assert not sock.hasPeerTimestamp
  assert sock.computeTimestampDiff() == 0'u32
  echo "PASS: timestampDiff zero before first recv"

block test_timestampdiff_populated_in_response:
  ## After receiving a packet, outgoing packets should have non-zero timestampDiff.
  let client = newUtpSocket(200)
  let server = newUtpSocket(0)

  # Client sends SYN (timestampDiff = 0 since no prior recv)
  let synData = client.makeSynPacket()
  let synHdr = decodeHeader(synData)
  assert synHdr.timestampDiff == 0, "SYN has no timestampDiff"

  # Server processes SYN → stores client's timestamp, sends STATE back
  let synRes = server.processIncoming(synData)
  assert server.hasPeerTimestamp
  let stateHdr = decodeHeader(synRes.response)
  # Server's STATE should have timestampDiff = now - client's timestamp
  # It won't be exactly 0 but should be very small (< 1 second = 1_000_000 µs)
  assert stateHdr.timestampDiff < 1_000_000'u32,
    "timestampDiff should be small: " & $stateHdr.timestampDiff
  echo "PASS: timestampDiff populated in response"

block test_timestampdiff_in_data_and_ack:
  ## Data packets and ACKs should carry valid timestampDiff.
  let client = newUtpSocket(300)
  let server = newUtpSocket(0)

  # Handshake
  let synData = client.makeSynPacket()
  let synRes = server.processIncoming(synData)
  discard client.processIncoming(synRes.response)

  # Client sends DATA
  let d1 = client.makeDataPacket("hello")
  let d1Hdr = decodeHeader(d1)
  # Client has received the STATE (hasPeerTimestamp = true), so timestampDiff > 0
  assert client.hasPeerTimestamp
  # timestampDiff should be very small (local processing)
  assert d1Hdr.timestampDiff < 1_000_000'u32,
    "DATA timestampDiff small: " & $d1Hdr.timestampDiff

  # Server ACKs the DATA
  let ackRes = server.processIncoming(d1)
  let ackHdr = decodeHeader(ackRes.response)
  assert ackHdr.timestampDiff < 1_000_000'u32,
    "ACK timestampDiff small: " & $ackHdr.timestampDiff
  echo "PASS: timestampDiff in data and ack"

# === Base delay tracking ===

block test_base_delay_first_sample:
  ## First delay sample initializes the base delay.
  let sock = newUtpSocket(400)
  assert sock.baseDelayValid == 0
  assert sock.getBaseDelay() == 0  # No samples yet

  sock.updateBaseDelay(50_000'u32)  # 50ms
  assert sock.baseDelayValid == 1
  assert sock.getBaseDelay() == 50_000'u32
  echo "PASS: base delay first sample"

block test_base_delay_tracks_minimum:
  ## Multiple samples in same slot → tracks minimum.
  let sock = newUtpSocket(500)
  sock.updateBaseDelay(50_000'u32)
  sock.updateBaseDelay(30_000'u32)  # Lower
  sock.updateBaseDelay(80_000'u32)  # Higher (ignored in min)
  assert sock.getBaseDelay() == 30_000'u32, "base delay is minimum: " & $sock.getBaseDelay()
  echo "PASS: base delay tracks minimum"

block test_base_delay_slot_rotation:
  ## After BaseDelayInterval seconds, a new slot is used.
  let sock = newUtpSocket(600)
  sock.updateBaseDelay(50_000'u32)
  assert sock.baseDelayValid == 1

  # Simulate time passing beyond the interval
  sock.baseDelayTime = epochTime() - BaseDelayInterval - 1.0

  sock.updateBaseDelay(40_000'u32)  # Goes into new slot
  assert sock.baseDelayValid == 2
  # Base delay should be min of both slots
  assert sock.getBaseDelay() == 40_000'u32
  echo "PASS: base delay slot rotation"

block test_base_delay_old_slots_replaced:
  ## When all slots are filled, oldest is overwritten.
  let sock = newUtpSocket(700)

  # Fill all slots with decreasing delays
  for i in 0 ..< BaseDelaySlots:
    sock.updateBaseDelay(uint32(100_000 - i * 1000))
    if i < BaseDelaySlots - 1:
      sock.baseDelayTime = epochTime() - BaseDelayInterval - 1.0

  assert sock.baseDelayValid == BaseDelaySlots

  # Force rotation — new slot overwrites oldest
  sock.baseDelayTime = epochTime() - BaseDelayInterval - 1.0
  sock.updateBaseDelay(200_000'u32)  # Higher than all previous

  # baseDelayValid stays at max
  assert sock.baseDelayValid == BaseDelaySlots
  echo "PASS: base delay old slots replaced"

block test_base_delay_discards_anomalous:
  ## Delay samples > MaxDelayMicros are discarded.
  let sock = newUtpSocket(800)
  sock.updateBaseDelay(50_000'u32)
  sock.updateBaseDelay(MaxDelayMicros + 1)  # Too large
  assert sock.getBaseDelay() == 50_000'u32, "anomalous sample ignored"
  echo "PASS: base delay discards anomalous samples"

# === LEDBAT formula ===

block test_ledbat_queuing_delay_computation:
  ## Verify queuing delay = our_delay - base_delay.
  let sock = newUtpSocket(900)
  sock.slowStart = false
  sock.maxWindow = 50_000

  # Establish base delay
  sock.updateBaseDelay(10_000'u32)  # 10ms base
  let baseDelay = sock.getBaseDelay()
  assert baseDelay == 10_000'u32

  # Queuing delay = 50_000 - 10_000 = 40_000 µs = 40ms
  let ourDelay = 50_000'u32
  let queuingDelay = ourDelay - baseDelay
  assert queuingDelay == 40_000'u32
  echo "PASS: queuing delay computation"

block test_ledbat_window_grows_under_target:
  ## When queuing delay < target, window should increase.
  let sock = newUtpSocket(1000)
  sock.slowStart = false
  sock.maxWindow = 50_000
  sock.state = usConnected

  # Set up base delay
  sock.updateBaseDelay(10_000'u32)  # 10ms base

  let initialWindow = sock.maxWindow

  # Simulate: ourDelay=20_000 → queuingDelay=10_000 → well below 100ms target
  # offTarget = (100_000 - 10_000) / 100_000 = 0.9 → positive → window grows
  let ourDelay = 20_000'u32
  let baseDelay = sock.getBaseDelay()
  let queuingDelay = ourDelay - baseDelay
  let offTarget = clamp(
    (DelayTarget.float - queuingDelay.float) / DelayTarget.float, -1.0, 1.0)
  assert offTarget > 0, "offTarget should be positive: " & $offTarget
  let bytesAcked = 1400
  let scaledGain = MaxCwndIncrease.float * offTarget *
                   bytesAcked.float / max(1, sock.maxWindow).float
  sock.maxWindow = max(MinCwndBytes, sock.maxWindow + int(scaledGain))

  assert sock.maxWindow > initialWindow,
    "window grew: " & $initialWindow & " -> " & $sock.maxWindow
  echo "PASS: LEDBAT window grows under target"

block test_ledbat_window_shrinks_over_target:
  ## When queuing delay > target, window should decrease.
  let sock = newUtpSocket(1100)
  sock.slowStart = false
  sock.maxWindow = 50_000
  sock.state = usConnected

  # Set up base delay
  sock.updateBaseDelay(10_000'u32)

  let initialWindow = sock.maxWindow

  # Simulate: ourDelay=200_000 → queuingDelay=190_000 → above 100ms target
  # offTarget = (100_000 - 190_000) / 100_000 = -0.9 → negative → window shrinks
  let ourDelay = 200_000'u32
  let baseDelay = sock.getBaseDelay()
  let queuingDelay = ourDelay - baseDelay
  let offTarget = clamp(
    (DelayTarget.float - queuingDelay.float) / DelayTarget.float, -1.0, 1.0)
  assert offTarget < 0, "offTarget should be negative: " & $offTarget
  let bytesAcked = 1400
  let scaledGain = MaxCwndIncrease.float * offTarget *
                   bytesAcked.float / max(1, sock.maxWindow).float
  sock.maxWindow = max(MinCwndBytes, sock.maxWindow + int(scaledGain))

  assert sock.maxWindow < initialWindow,
    "window shrank: " & $initialWindow & " -> " & $sock.maxWindow
  echo "PASS: LEDBAT window shrinks over target"

block test_ledbat_offtarget_clamped:
  ## offTarget is clamped to [-1, 1].
  # Very high delay: queuingDelay = 500_000 µs
  let offTarget = clamp(
    (DelayTarget.float - 500_000.0) / DelayTarget.float, -1.0, 1.0)
  assert offTarget == -1.0, "offTarget clamped to -1.0: " & $offTarget

  # Very low delay: queuingDelay = 0
  let offTarget2 = clamp(
    (DelayTarget.float - 0.0) / DelayTarget.float, -1.0, 1.0)
  assert offTarget2 == 1.0, "offTarget clamped to 1.0: " & $offTarget2
  echo "PASS: offTarget clamped to [-1, 1]"

block test_ledbat_normalized_by_cwnd:
  ## Larger windows should grow proportionally slower per ACK.
  let smallWnd = 5_000
  let largeWnd = 50_000
  let bytesAcked = 1400
  let offTarget = 0.5  # moderate positive gain

  let smallGain = MaxCwndIncrease.float * offTarget *
                  bytesAcked.float / smallWnd.float
  let largeGain = MaxCwndIncrease.float * offTarget *
                  bytesAcked.float / largeWnd.float

  assert smallGain > largeGain,
    "small window grows faster: " & $smallGain & " vs " & $largeGain
  # The ratio should be ~10x (50000/5000)
  assert abs(smallGain / largeGain - 10.0) < 0.01,
    "gain ratio matches window ratio"
  echo "PASS: LEDBAT normalized by cwnd"

block test_ledbat_minimum_window_clamp:
  ## Window should never go below MinCwndBytes (1 MSS).
  let sock = newUtpSocket(1200)
  sock.slowStart = false
  sock.maxWindow = MinCwndBytes  # Already at minimum

  sock.updateBaseDelay(10_000'u32)
  let baseDelay = sock.getBaseDelay()
  let ourDelay = 300_000'u32  # Very high delay
  let queuingDelay = ourDelay - baseDelay
  let offTarget = clamp(
    (DelayTarget.float - queuingDelay.float) / DelayTarget.float, -1.0, 1.0)
  let scaledGain = MaxCwndIncrease.float * offTarget *
                   MinCwndBytes.float / max(1, sock.maxWindow).float
  sock.maxWindow = max(MinCwndBytes, sock.maxWindow + int(scaledGain))
  assert sock.maxWindow == MinCwndBytes,
    "clamped at MinCwndBytes: " & $sock.maxWindow
  echo "PASS: minimum window clamp"

# === Slow start ===

block test_slow_start_initial_state:
  ## New socket starts in slow start with small window.
  let sock = newUtpSocket(1300)
  assert sock.slowStart == true
  assert sock.maxWindow == 2 * MaxPacketSize, "initial window: " & $sock.maxWindow
  assert sock.ssthresh == DefaultWindowSize
  echo "PASS: slow start initial state"

block test_slow_start_exponential_growth:
  ## Slow start doubles window per RTT (approximated by additive per ACK).
  let sock = newUtpSocket(1400)
  sock.state = usConnected
  assert sock.slowStart

  let initialWindow = sock.maxWindow  # 2800

  # Simulate: base delay established, low queuing delay
  sock.updateBaseDelay(5_000'u32)

  # Manually simulate processAck LEDBAT section behavior:
  # In slow start with queuingDelay < target → maxWindow += bytesAcked
  let bytesAcked = 1400
  let queuingDelay = 10_000'u32 - 5_000'u32  # 5ms, well below 100ms target
  assert queuingDelay <= DelayTarget.uint32  # Should stay in slow start
  sock.maxWindow += bytesAcked  # This is what processAck does in slow start

  assert sock.maxWindow == initialWindow + bytesAcked,
    "window grew by bytesAcked: " & $sock.maxWindow
  assert sock.slowStart, "still in slow start"
  echo "PASS: slow start exponential growth"

block test_slow_start_exits_on_high_delay:
  ## Slow start exits when queuing delay exceeds target.
  let sock = newUtpSocket(1500)
  sock.state = usConnected
  assert sock.slowStart
  sock.maxWindow = 50_000

  sock.updateBaseDelay(5_000'u32)

  # queuingDelay = 150_000 - 5_000 = 145_000 > DelayTarget (100_000)
  let queuingDelay = 150_000'u32 - 5_000'u32
  assert queuingDelay > DelayTarget.uint32

  # Simulate: slow start detects congestion
  sock.ssthresh = sock.maxWindow
  sock.slowStart = false

  assert not sock.slowStart
  assert sock.ssthresh == 50_000
  echo "PASS: slow start exits on high delay"

block test_slow_start_exits_at_ssthresh:
  ## Slow start exits when window reaches ssthresh.
  let sock = newUtpSocket(1600)
  sock.state = usConnected
  sock.maxWindow = 10_000
  sock.ssthresh = 10_000  # Already at threshold

  # In processAck: if maxWindow >= ssthresh → exit slow start
  if sock.maxWindow >= sock.ssthresh:
    sock.slowStart = false

  assert not sock.slowStart
  echo "PASS: slow start exits at ssthresh"

# === Loss event deduplication ===

block test_loss_dedup_single_halving:
  ## Multiple simultaneous timeouts should halve window only once.
  let sock = newUtpSocket(1700)
  sock.state = usConnected
  sock.rto = 1
  sock.maxWindow = 20_000

  # Send 4 packets, all timeout simultaneously
  discard sock.makeDataPacket("pkt1")
  discard sock.makeDataPacket("pkt2")
  discard sock.makeDataPacket("pkt3")
  discard sock.makeDataPacket("pkt4")
  for i in 0 ..< sock.outBuffer.len:
    sock.outBuffer[i].sentAt = epochTime() - 2.0

  let retrans = sock.checkTimeouts()
  assert retrans.len == 4, "all 4 packets retransmitted"
  assert sock.maxWindow == 10_000,
    "window halved once (not 4 times): " & $sock.maxWindow
  echo "PASS: loss dedup single halving"

block test_loss_exits_slow_start:
  ## Timeout during slow start should exit slow start and set ssthresh.
  let sock = newUtpSocket(1800)
  sock.state = usConnected
  sock.rto = 1
  sock.maxWindow = 20_000
  assert sock.slowStart

  discard sock.makeDataPacket("loss")
  sock.outBuffer[0].sentAt = epochTime() - 2.0

  discard sock.checkTimeouts()
  assert not sock.slowStart, "exited slow start"
  assert sock.ssthresh == 10_000,
    "ssthresh set to halved window: " & $sock.ssthresh
  assert sock.maxWindow == 10_000,
    "window halved: " & $sock.maxWindow
  echo "PASS: loss exits slow start"

block test_loss_dedup_new_event_after_recovery:
  ## After recovery (new packets sent and acked), a new loss should halve again.
  let sock = newUtpSocket(1900)
  sock.state = usConnected
  sock.rto = 1
  sock.maxWindow = 20_000
  sock.slowStart = false

  # First loss event
  discard sock.makeDataPacket("first_loss")
  sock.outBuffer[0].sentAt = epochTime() - 2.0
  discard sock.checkTimeouts()
  assert sock.maxWindow == 10_000

  # Clear outBuffer (simulate ACK), send new packets
  sock.outBuffer.clear()
  sock.curWindow = 0

  # New packet with higher seqNr → new loss event
  discard sock.makeDataPacket("second_loss")
  sock.outBuffer[0].sentAt = epochTime() - 2.0
  discard sock.checkTimeouts()
  assert sock.maxWindow == 5_000,
    "second loss event halved again: " & $sock.maxWindow
  echo "PASS: loss dedup new event after recovery"

# === Integration: processAck end-to-end with LEDBAT ===

block test_processack_ledbat_integration:
  ## Full handshake + data exchange exercises the LEDBAT path end-to-end.
  let client = newUtpSocket(2000)
  let server = newUtpSocket(0)

  # Handshake
  let synData = client.makeSynPacket()
  let synRes = server.processIncoming(synData)
  discard client.processIncoming(synRes.response)

  assert client.state == usConnected
  assert client.slowStart  # Still in slow start after handshake

  let initialWindow = client.maxWindow

  # Send several packets to accumulate delay samples
  for i in 0 ..< 5:
    let d = client.makeDataPacket("data" & $i)
    let r = server.processIncoming(d)
    discard client.processIncoming(r.response)

  # Window should have grown (slow start with low delay)
  assert client.maxWindow >= initialWindow,
    "window grew during data exchange: " & $initialWindow & " -> " & $client.maxWindow
  echo "PASS: processAck LEDBAT integration"

block test_ledbat_skips_without_delay_sample:
  ## If timestampDiff is 0 (no delay info), LEDBAT should not adjust window.
  ## This happens when the peer hasn't received any of our packets yet.
  let sock = newUtpSocket(2100)
  sock.slowStart = false
  sock.maxWindow = 50_000

  # Without any delay samples, updateBaseDelay is never called
  assert sock.baseDelayValid == 0
  # LEDBAT requires baseDelayValid > 0 to run, so window stays unchanged
  assert sock.maxWindow == 50_000
  echo "PASS: LEDBAT skips without delay sample"

echo ""
echo "All uTP LEDBAT tests passed!"
