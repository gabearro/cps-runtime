## QUIC recovery and congestion-control helpers (baseline NewReno).

const
  QuicGranularityMicros* = 1_000'i64
  QuicInitialRttMicros* = 333_000'i64
  QuicMinPtoMicros* = 1_000'i64

type
  QuicCongestionController* = enum
    qccNewReno
    qccCubic
    qccBbr

  QuicRecoveryState* = object
    maxDatagramSize*: int
    controller*: QuicCongestionController
    congestionWindow*: int
    slowStartThreshold*: int
    bytesInFlight*: int
    ssthreshInitialized*: bool
    smoothedRttMicros*: int64
    rttVarMicros*: int64
    latestRttMicros*: int64
    minRttMicros*: int64
    ptoCount*: int
    lostPackets*: int
    ackedPackets*: int

proc initRecoveryState*(maxDatagramSize: int = 1200,
                        controller: QuicCongestionController = qccCubic): QuicRecoveryState =
  let mds = max(1200, maxDatagramSize)
  QuicRecoveryState(
    maxDatagramSize: mds,
    controller: controller,
    congestionWindow: max(2 * mds, min(10 * mds, max(14_720, 2 * mds))),
    slowStartThreshold: int.high,
    ssthreshInitialized: true,
    bytesInFlight: 0,
    smoothedRttMicros: 0,
    rttVarMicros: 0,
    latestRttMicros: 0,
    minRttMicros: int64.high,
    ptoCount: 0,
    lostPackets: 0,
    ackedPackets: 0
  )

proc setCongestionController*(st: var QuicRecoveryState, controller: QuicCongestionController) =
  st.controller = controller

proc onPacketSent*(st: var QuicRecoveryState, packetBytes: int, ackEliciting: bool) =
  if ackEliciting:
    st.bytesInFlight += max(0, packetBytes)

proc updateRtt*(st: var QuicRecoveryState, latestRttMicros: int64, ackDelayMicros: int64 = 0) =
  if latestRttMicros <= 0:
    return
  st.latestRttMicros = latestRttMicros
  if latestRttMicros < st.minRttMicros:
    st.minRttMicros = latestRttMicros

  var adjustedRtt = latestRttMicros
  if ackDelayMicros > 0 and latestRttMicros > st.minRttMicros + ackDelayMicros:
    adjustedRtt = latestRttMicros - ackDelayMicros

  if st.smoothedRttMicros == 0:
    st.smoothedRttMicros = adjustedRtt
    st.rttVarMicros = adjustedRtt div 2
  else:
    let rttVarSample = abs(st.smoothedRttMicros - adjustedRtt)
    st.rttVarMicros = (3 * st.rttVarMicros + rttVarSample) div 4
    st.smoothedRttMicros = (7 * st.smoothedRttMicros + adjustedRtt) div 8

proc onPacketAcked*(st: var QuicRecoveryState, packetBytes: int) =
  let bytes = max(0, packetBytes)
  st.ackedPackets += 1
  st.bytesInFlight = max(0, st.bytesInFlight - bytes)

  if st.congestionWindow < st.slowStartThreshold:
    st.congestionWindow += bytes
  else:
    let denom = max(st.congestionWindow, 1)
    case st.controller
    of qccNewReno:
      st.congestionWindow += max((st.maxDatagramSize * bytes) div denom, 1)
    of qccCubic:
      # Lightweight CUBIC approximation for runtime scheduling.
      st.congestionWindow += max((3 * st.maxDatagramSize * bytes) div denom, 1)
    of qccBbr:
      # Experimental BBR-like mode: keep cwnd growth conservative and RTT-driven.
      let gain = max(st.maxDatagramSize div 2, 1)
      st.congestionWindow += max((gain * bytes) div denom, 1)

  st.ptoCount = 0

proc onPacketLost*(st: var QuicRecoveryState, packetBytes: int) =
  let bytes = max(0, packetBytes)
  st.lostPackets += 1
  st.bytesInFlight = max(0, st.bytesInFlight - bytes)
  st.slowStartThreshold = max(st.congestionWindow div 2, 2 * st.maxDatagramSize)
  st.congestionWindow = st.slowStartThreshold

proc onPersistentCongestion*(st: var QuicRecoveryState) =
  st.slowStartThreshold = max(st.congestionWindow div 2, 2 * st.maxDatagramSize)
  st.congestionWindow = 2 * st.maxDatagramSize
  st.bytesInFlight = min(st.bytesInFlight, st.congestionWindow)

proc currentPtoMicros*(st: QuicRecoveryState): int64 =
  let srtt = if st.smoothedRttMicros > 0: st.smoothedRttMicros else: QuicInitialRttMicros
  let rttVar = if st.rttVarMicros > 0: st.rttVarMicros else: QuicInitialRttMicros div 2
  let base = srtt + max(4 * rttVar, QuicGranularityMicros)
  let pto = max(base shl st.ptoCount, QuicMinPtoMicros)
  pto

proc onPtoExpired*(st: var QuicRecoveryState) =
  st.ptoCount = min(st.ptoCount + 1, 31)

proc congestionWindowAvailable*(st: QuicRecoveryState): int =
  max(0, st.congestionWindow - st.bytesInFlight)

proc pacingDelayMicros*(st: QuicRecoveryState, packetBytes: int): int64 =
  ## Approximate pacing delay for one packet based on cwnd and SRTT.
  let bytes = max(packetBytes, 1)
  let cwnd = max(st.congestionWindow, st.maxDatagramSize)
  let srtt = if st.smoothedRttMicros > 0: st.smoothedRttMicros else: QuicInitialRttMicros
  max(0'i64, (int64(bytes) * srtt) div int64(cwnd))
