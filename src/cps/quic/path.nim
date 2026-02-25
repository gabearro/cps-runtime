## QUIC path validation and migration helpers.

import ./types
import ./secure_random

type
  QuicPathValidationState* = enum
    qpvsNone
    qpvsChallenging
    qpvsValidated
    qpvsFailed

  QuicPathInfo* = object
    pathId*: uint64
    peerAddress*: string
    peerPort*: int
    challengeData*: array[8, byte]
    validationState*: QuicPathValidationState
    challengeSentCount*: int
    bytesSent*: uint64
    bytesReceived*: uint64
    addressValidated*: bool

  QuicPathManager* = object
    activePathId*: uint64
    paths*: seq[QuicPathInfo]

proc generatePathChallengeData*(): array[8, byte] =
  var b = secureRandomBytes(8)
  for i in 0 ..< 8:
    result[i] = b[i]

proc initPathManager*(peerAddress: string,
                      peerPort: int,
                      validated: bool = true): QuicPathManager =
  let path = QuicPathInfo(
    pathId: 0'u64,
    peerAddress: peerAddress,
    peerPort: peerPort,
    challengeData: [0'u8, 0, 0, 0, 0, 0, 0, 0],
    validationState: if validated: qpvsValidated else: qpvsNone,
    challengeSentCount: 0,
    bytesSent: 0'u64,
    bytesReceived: 0'u64,
    addressValidated: validated
  )
  QuicPathManager(activePathId: 0, paths: @[path])

proc activePathIndex*(pm: QuicPathManager): int =
  for i in 0 ..< pm.paths.len:
    if pm.paths[i].pathId == pm.activePathId:
      return i
  if pm.paths.len == 0:
    return -1
  0

proc activePath*(pm: QuicPathManager): QuicPathInfo =
  let idx = pm.activePathIndex()
  if idx < 0:
    raise newException(ValueError, "path manager has no paths")
  pm.paths[idx]

proc findPathIndex(pm: QuicPathManager, peerAddress: string, peerPort: int): int =
  for i in 0 ..< pm.paths.len:
    if pm.paths[i].peerAddress == peerAddress and pm.paths[i].peerPort == peerPort:
      return i
  -1

proc ensurePath*(pm: var QuicPathManager, peerAddress: string, peerPort: int): int =
  result = findPathIndex(pm, peerAddress, peerPort)
  if result >= 0:
    return result
  let pathId =
    if pm.paths.len == 0: 0'u64
    else: pm.paths[^1].pathId + 1
  pm.paths.add QuicPathInfo(
    pathId: pathId,
    peerAddress: peerAddress,
    peerPort: peerPort,
    challengeData: [0'u8, 0, 0, 0, 0, 0, 0, 0],
    validationState: qpvsNone,
    challengeSentCount: 0,
    bytesSent: 0'u64,
    bytesReceived: 0'u64,
    addressValidated: false
  )
  result = pm.paths.high

proc beginValidation*(pm: var QuicPathManager, peerAddress: string, peerPort: int): QuicPathInfo =
  let idx = pm.ensurePath(peerAddress, peerPort)
  let challenge = generatePathChallengeData()
  pm.paths[idx].challengeData = challenge
  pm.paths[idx].validationState = qpvsChallenging
  pm.paths[idx].challengeSentCount += 1
  pm.paths[idx].addressValidated = false
  pm.paths[idx]

proc pathChallengeFrame*(path: QuicPathInfo): QuicFrame =
  QuicFrame(kind: qfkPathChallenge, pathData: path.challengeData)

proc onPathResponse*(pm: var QuicPathManager,
                     peerAddress: string,
                     peerPort: int,
                     data: array[8, byte]): bool =
  for i in 0 ..< pm.paths.len:
    if pm.paths[i].peerAddress == peerAddress and pm.paths[i].peerPort == peerPort and
        pm.paths[i].validationState == qpvsChallenging and pm.paths[i].challengeData == data:
      pm.paths[i].validationState = qpvsValidated
      pm.paths[i].addressValidated = true
      pm.activePathId = pm.paths[i].pathId
      return true
  false

proc markPathValidationFailed*(pm: var QuicPathManager, pathId: uint64) =
  for i in 0 ..< pm.paths.len:
    if pm.paths[i].pathId == pathId:
      pm.paths[i].validationState = qpvsFailed
      pm.paths[i].addressValidated = false

proc canMigrateToActivePath*(pm: QuicPathManager): bool =
  let p = pm.activePath()
  p.validationState == qpvsValidated and p.addressValidated

proc noteDatagramReceived*(pm: var QuicPathManager,
                           peerAddress: string,
                           peerPort: int,
                           bytes: int) =
  if bytes <= 0:
    return
  let idx = pm.ensurePath(peerAddress, peerPort)
  pm.paths[idx].bytesReceived += uint64(bytes)

proc noteDatagramSent*(pm: var QuicPathManager,
                       peerAddress: string,
                       peerPort: int,
                       bytes: int) =
  if bytes <= 0:
    return
  let idx = pm.ensurePath(peerAddress, peerPort)
  pm.paths[idx].bytesSent += uint64(bytes)

proc markPathValidated*(pm: var QuicPathManager, peerAddress: string, peerPort: int) =
  let idx = pm.ensurePath(peerAddress, peerPort)
  pm.paths[idx].validationState = qpvsValidated
  pm.paths[idx].addressValidated = true
  pm.activePathId = pm.paths[idx].pathId

proc canSendToPath*(pm: QuicPathManager,
                    peerAddress: string,
                    peerPort: int,
                    bytes: int,
                    enforceAmplification: bool): bool =
  if bytes <= 0:
    return true
  let idx = pm.findPathIndex(peerAddress, peerPort)
  if idx < 0:
    return not enforceAmplification
  if not enforceAmplification:
    return true
  if pm.paths[idx].addressValidated or pm.paths[idx].validationState == qpvsValidated:
    return true
  let maxAllowed = pm.paths[idx].bytesReceived * 3'u64
  pm.paths[idx].bytesSent + uint64(bytes) <= maxAllowed
