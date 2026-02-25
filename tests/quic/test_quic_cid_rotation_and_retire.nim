## QUIC CID rotation/retirement behavior tests.

import cps/quic

proc token(seed: byte): array[16, byte] =
  for i in 0 ..< 16:
    result[i] = seed + byte(i)

block testPeerCidRetirePriorTo:
  let conn = newQuicConnection(
    role = qcrClient,
    localConnId = @[0x11'u8, 0x22, 0x33, 0x44],
    peerConnId = @[0x55'u8, 0x66, 0x77, 0x88],
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )

  conn.applyReceivedFrame(QuicFrame(
    kind: qfkNewConnectionId,
    ncidSequence: 0'u64,
    ncidRetirePriorTo: 0'u64,
    ncidConnectionId: @[0x01'u8, 0x02, 0x03, 0x04],
    ncidResetToken: token(1'u8)
  ))
  conn.applyReceivedFrame(QuicFrame(
    kind: qfkNewConnectionId,
    ncidSequence: 1'u64,
    ncidRetirePriorTo: 0'u64,
    ncidConnectionId: @[0x05'u8, 0x06, 0x07, 0x08],
    ncidResetToken: token(17'u8)
  ))
  conn.applyReceivedFrame(QuicFrame(
    kind: qfkNewConnectionId,
    ncidSequence: 3'u64,
    ncidRetirePriorTo: 2'u64,
    ncidConnectionId: @[0x09'u8, 0x0A, 0x0B, 0x0C],
    ncidResetToken: token(33'u8)
  ))

  doAssert conn.isPeerConnectionIdRetired(0'u64)
  doAssert conn.isPeerConnectionIdRetired(1'u64)
  doAssert conn.peerConnectionIdForSequence(0'u64).len == 0
  doAssert conn.peerConnectionIdForSequence(1'u64).len == 0
  doAssert conn.peerConnectionIdForSequence(3'u64) == @[0x09'u8, 0x0A, 0x0B, 0x0C]
  echo "PASS: QUIC NEW_CONNECTION_ID retire_prior_to retires older peer CIDs"

block testExplicitRetireConnectionIdFrame:
  let conn = newQuicConnection(
    role = qcrClient,
    localConnId = @[0x21'u8, 0x22, 0x23, 0x24],
    peerConnId = @[0x25'u8, 0x26, 0x27, 0x28],
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )
  conn.applyReceivedFrame(QuicFrame(
    kind: qfkRetireConnectionId,
    retireCidSequence: 7'u64
  ))
  doAssert conn.isPeerConnectionIdRetired(7'u64)
  echo "PASS: QUIC RETIRE_CONNECTION_ID tracked"

block testInvalidRetirePriorToDoesNotMutatePeerCid:
  let conn = newQuicConnection(
    role = qcrClient,
    localConnId = @[0x31'u8, 0x32, 0x33, 0x34],
    peerConnId = @[0x41'u8, 0x42, 0x43, 0x44],
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )
  let beforePeerCid = conn.peerConnId
  conn.applyReceivedFrame(QuicFrame(
    kind: qfkNewConnectionId,
    ncidSequence: 1'u64,
    ncidRetirePriorTo: 2'u64, # invalid (> sequence)
    ncidConnectionId: @[0x91'u8, 0x92, 0x93, 0x94],
    ncidResetToken: token(49'u8)
  ))
  doAssert conn.state == qcsDraining
  doAssert conn.closeErrorCode == 0x0A'u64
  doAssert conn.peerConnId == beforePeerCid
  doAssert conn.peerConnectionIdForSequence(1'u64).len == 0
  echo "PASS: invalid NEW_CONNECTION_ID retire_prior_to is rejected before state mutation"

block testPeerCidLimitEnforced:
  let conn = newQuicConnection(
    role = qcrClient,
    localConnId = @[0x71'u8, 0x72, 0x73, 0x74],
    peerConnId = @[0x81'u8, 0x82, 0x83, 0x84],
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )
  conn.localTransportParameters.activeConnectionIdLimit = 2'u64
  conn.applyReceivedFrame(QuicFrame(
    kind: qfkNewConnectionId,
    ncidSequence: 1'u64,
    ncidRetirePriorTo: 0'u64,
    ncidConnectionId: @[0x01'u8, 0x02, 0x03, 0x04],
    ncidResetToken: token(65'u8)
  ))
  conn.applyReceivedFrame(QuicFrame(
    kind: qfkNewConnectionId,
    ncidSequence: 2'u64,
    ncidRetirePriorTo: 0'u64,
    ncidConnectionId: @[0x05'u8, 0x06, 0x07, 0x08],
    ncidResetToken: token(81'u8)
  ))
  conn.applyReceivedFrame(QuicFrame(
    kind: qfkNewConnectionId,
    ncidSequence: 3'u64,
    ncidRetirePriorTo: 0'u64,
    ncidConnectionId: @[0x09'u8, 0x0A, 0x0B, 0x0C],
    ncidResetToken: token(97'u8)
  ))
  doAssert conn.state == qcsDraining
  doAssert conn.closeErrorCode == 0x09'u64
  doAssert conn.peerConnectionIdForSequence(3'u64).len == 0
  echo "PASS: NEW_CONNECTION_ID enforces active_connection_id_limit"

block testDuplicateNewCidSequenceWithDifferentCidRejected:
  let conn = newQuicConnection(
    role = qcrClient,
    localConnId = @[0x91'u8, 0x92, 0x93, 0x94],
    peerConnId = @[0xA1'u8, 0xA2, 0xA3, 0xA4],
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )
  conn.applyReceivedFrame(QuicFrame(
    kind: qfkNewConnectionId,
    ncidSequence: 5'u64,
    ncidRetirePriorTo: 0'u64,
    ncidConnectionId: @[0x01'u8, 0x02],
    ncidResetToken: token(113'u8)
  ))
  conn.applyReceivedFrame(QuicFrame(
    kind: qfkNewConnectionId,
    ncidSequence: 5'u64,
    ncidRetirePriorTo: 0'u64,
    ncidConnectionId: @[0x03'u8, 0x04],
    ncidResetToken: token(129'u8)
  ))
  doAssert conn.state == qcsDraining
  doAssert conn.closeErrorCode == 0x0A'u64
  doAssert conn.peerConnectionIdForSequence(5'u64) == @[0x01'u8, 0x02]
  echo "PASS: duplicate NEW_CONNECTION_ID sequence with different CID is rejected"

block testDuplicateNewCidSequenceWithDifferentTokenRejected:
  let conn = newQuicConnection(
    role = qcrClient,
    localConnId = @[0xB1'u8, 0xB2, 0xB3, 0xB4],
    peerConnId = @[0xC1'u8, 0xC2, 0xC3, 0xC4],
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )
  conn.applyReceivedFrame(QuicFrame(
    kind: qfkNewConnectionId,
    ncidSequence: 6'u64,
    ncidRetirePriorTo: 0'u64,
    ncidConnectionId: @[0x0A'u8, 0x0B],
    ncidResetToken: token(145'u8)
  ))
  var mismatched = token(161'u8)
  conn.applyReceivedFrame(QuicFrame(
    kind: qfkNewConnectionId,
    ncidSequence: 6'u64,
    ncidRetirePriorTo: 0'u64,
    ncidConnectionId: @[0x0A'u8, 0x0B],
    ncidResetToken: mismatched
  ))
  doAssert conn.state == qcsDraining
  doAssert conn.closeErrorCode == 0x0A'u64
  doAssert conn.peerConnectionIdForSequence(6'u64) == @[0x0A'u8, 0x0B]
  echo "PASS: duplicate NEW_CONNECTION_ID sequence with different reset token is rejected"

echo "All QUIC CID rotation/retirement tests passed"
