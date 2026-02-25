## QUIC path migration + PATH_CHALLENGE/RESPONSE tests.

import cps/quic

block testPathManagerValidation:
  var pm = initPathManager("127.0.0.1", 4433)
  let base = pm.activePath()
  doAssert base.validationState == qpvsValidated

  let candidate = pm.beginValidation("127.0.0.2", 4434)
  doAssert candidate.validationState == qpvsChallenging

  let challenge = pathChallengeFrame(candidate)
  doAssert challenge.kind == qfkPathChallenge
  doAssert challenge.pathData == candidate.challengeData

  var wrong = candidate.challengeData
  wrong[0] = wrong[0] xor 0xFF
  doAssert not pm.onPathResponse(candidate.peerAddress, candidate.peerPort, wrong)
  doAssert pm.onPathResponse(candidate.peerAddress, candidate.peerPort, candidate.challengeData)

  let active = pm.activePath()
  doAssert active.peerAddress == candidate.peerAddress
  doAssert active.peerPort == candidate.peerPort
  doAssert canMigrateToActivePath(pm)

  pm.markPathValidationFailed(active.pathId)
  doAssert not canMigrateToActivePath(pm)
  echo "PASS: QUIC path manager validation lifecycle"

block testPathChallengeReflectionOnConnection:
  let conn = newQuicConnection(qcrServer, @[0x01'u8], @[0x02'u8], "127.0.0.1", 4433)
  let data = generatePathChallengeData()
  conn.applyReceivedFrame(QuicFrame(kind: qfkPathChallenge, pathData: data))

  let pending = conn.popPendingControlFrames()
  doAssert pending.len == 1
  let frame = pending[0]
  doAssert frame.kind == qfkPathResponse
  doAssert frame.pathData == data
  echo "PASS: QUIC PATH_CHALLENGE reflection on connection"

echo "All QUIC path migration tests passed"
