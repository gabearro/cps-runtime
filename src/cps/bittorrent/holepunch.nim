## BEP 55: Holepunch Extension.
##
## Enables NAT traversal via a relay peer. The initiating peer sends a
## rendezvous message to a relay, which forwards connect messages to both
## sides, prompting simultaneous uTP connection attempts.

import std/[strutils, tables, sets, times, math]
import utils

const
  UtHolepunchName* = "ut_holepunch"

  # Message types
  HpRendezvous* = 0x00'u8
  HpConnect* = 0x01'u8
  HpError* = 0x02'u8

  # Address types
  AddrIPv4* = 0x00'u8
  AddrIPv6* = 0x01'u8

  # Error codes
  HpErrNoSuchPeer* = 0x01'u32
  HpErrNotConnected* = 0x02'u32
  HpErrNoSupport* = 0x03'u32
  HpErrNoSelf* = 0x04'u32

type
  HolepunchMsg* = object
    msgType*: uint8
    addrType*: uint8
    ip*: string            ## Dotted-quad IPv4 or colon-hex IPv6
    port*: uint16
    errCode*: uint32

proc encodeHolepunchMsg*(msg: HolepunchMsg): string =
  ## Encode a holepunch message to binary format.
  ## Format: [msg_type(1), addr_type(1), addr(4 or 16), port(2), err_code(4)]
  result = newStringOfCap(12)
  result.add(char(msg.msgType))
  result.add(char(msg.addrType))

  if msg.addrType != AddrIPv4 and msg.addrType != AddrIPv6:
    raise newException(ValueError, "unknown holepunch addr_type: " & $msg.addrType)

  if msg.addrType == AddrIPv4:
    # Parse dotted-quad IPv4 and encode as 4 bytes big-endian
    let parts = msg.ip.split('.')
    if parts.len != 4:
      raise newException(ValueError, "invalid IPv4 address: " & msg.ip)
    for part in parts:
      let v = parseInt(part)
      result.add(char(v and 0xFF))
  else:
    # IPv6: parse colon-hex groups and encode as 16 bytes big-endian
    var words: array[8, uint16]
    let groups = msg.ip.split(':')
    var gi = 0
    var wi = 0
    while gi < groups.len and wi < 8:
      if groups[gi].len == 0:
        # Found :: — count non-empty groups to determine zero fill
        gi += 1
        if gi < groups.len and groups[gi].len == 0:
          gi += 1  # skip second empty from "::"
        var tailCount = 0
        for ti in gi ..< groups.len:
          if groups[ti].len > 0:
            tailCount += 1
        let zeroFill = 8 - wi - tailCount
        wi += zeroFill  # words default to 0
      else:
        words[wi] = uint16(parseHexInt(groups[gi]))
        wi += 1
        gi += 1
    for w in words:
      result.add(char((w shr 8) and 0xFF))
      result.add(char(w and 0xFF))

  # Port (2 bytes big-endian)
  result.add(char((msg.port shr 8) and 0xFF))
  result.add(char(msg.port and 0xFF))

  # Error code (4 bytes big-endian)
  result.add(char((msg.errCode shr 24) and 0xFF))
  result.add(char((msg.errCode shr 16) and 0xFF))
  result.add(char((msg.errCode shr 8) and 0xFF))
  result.add(char(msg.errCode and 0xFF))

proc decodeHolepunchMsg*(data: string): HolepunchMsg =
  ## Decode a holepunch message from binary format.
  if data.len < 2:
    raise newException(ValueError, "holepunch message too short")

  result.msgType = data[0].byte
  result.addrType = data[1].byte

  if result.addrType != AddrIPv4 and result.addrType != AddrIPv6:
    raise newException(ValueError, "unknown holepunch addr_type: " & $result.addrType)

  var offset = 2
  if result.addrType == AddrIPv4:
    if data.len < offset + 4 + 2 + 4:
      raise newException(ValueError, "holepunch IPv4 message too short")
    result.ip = $data[offset].byte & "." &
                $data[offset+1].byte & "." &
                $data[offset+2].byte & "." &
                $data[offset+3].byte
    offset += 4
  else:
    if data.len < offset + 16 + 2 + 4:
      raise newException(ValueError, "holepunch IPv6 message too short")
    var parts: seq[string]
    for i in 0 ..< 8:
      let hi = data[offset + i*2].byte
      let lo = data[offset + i*2 + 1].byte
      let val = (uint16(hi) shl 8) or uint16(lo)
      parts.add(val.int.toHex(4).toLowerAscii())
    result.ip = canonicalizeIpv6(parts.join(":"))
    offset += 16

  # Port
  result.port = (uint16(data[offset].byte) shl 8) or uint16(data[offset+1].byte)
  offset += 2

  # Error code
  result.errCode = (uint32(data[offset].byte) shl 24) or
                   (uint32(data[offset+1].byte) shl 16) or
                   (uint32(data[offset+2].byte) shl 8) or
                   uint32(data[offset+3].byte)

proc rendezvousMsg*(ip: string, port: uint16): HolepunchMsg =
  ## Create a rendezvous message to request holepunching via relay.
  HolepunchMsg(
    msgType: HpRendezvous,
    addrType: if ip.contains(':'): AddrIPv6 else: AddrIPv4,
    ip: ip,
    port: port,
    errCode: 0
  )

proc connectMsg*(ip: string, port: uint16): HolepunchMsg =
  ## Create a connect message to initiate uTP connection.
  HolepunchMsg(
    msgType: HpConnect,
    addrType: if ip.contains(':'): AddrIPv6 else: AddrIPv4,
    ip: ip,
    port: port,
    errCode: 0
  )

proc errorMsg*(ip: string, port: uint16, errCode: uint32): HolepunchMsg =
  ## Create an error message for failed rendezvous.
  HolepunchMsg(
    msgType: HpError,
    addrType: if ip.contains(':'): AddrIPv6 else: AddrIPv4,
    ip: ip,
    port: port,
    errCode: errCode
  )

proc errorName*(code: uint32): string =
  ## Human-readable name for an error code.
  case code
  of HpErrNoSuchPeer: "NoSuchPeer"
  of HpErrNotConnected: "NotConnected"
  of HpErrNoSupport: "NoSupport"
  of HpErrNoSelf: "NoSelf"
  else: "Unknown(" & $code & ")"

# ---------------------------------------------------------------------------
# HolepunchState: consolidated holepunch bookkeeping
# ---------------------------------------------------------------------------

const
  DefaultRetrySec* = 30.0        ## Initial backoff after a rendezvous attempt
  DefaultErrorBackoffSec* = 90.0 ## Backoff after receiving an error from relay
  BackoffMultiplier* = 1.5       ## Exponential growth per consecutive failure
  MaxBackoffSec* = 600.0         ## Ceiling for exponential backoff (10 min)
  DefaultExpectedSec* = 30.0     ## Window for expecting an incoming holepunch
  MaxCandidatesPerCycle* = 3     ## Max rendezvous candidates per loop cycle
  MaxRelaysPerTarget* = 6        ## Cap relay set size per target

type
  HolepunchState* = object
    relayByTarget: Table[string, HashSet[string]]  ## target key -> relay peer keys
    targetsByRelay: Table[string, HashSet[string]]  ## relay key -> target keys (inverse index)
    inFlight: HashSet[string]                       ## targets currently being direct-attempted
    expected: Table[string, float]                  ## key -> incoming-connection expiry epoch
    backoff: Table[string, float]                   ## key -> retry-after epoch
    retryCount: Table[string, int]                  ## key -> consecutive failure count
    attempts*: int
    successes*: int
    lastError*: string

proc removeTarget*(hp: var HolepunchState, targetKey: string)  # forward decl

proc initHolepunchState*(): HolepunchState =
  HolepunchState(
    relayByTarget: initTable[string, HashSet[string]](),
    targetsByRelay: initTable[string, HashSet[string]](),
    inFlight: initHashSet[string](),
    expected: initTable[string, float](),
    backoff: initTable[string, float](),
    retryCount: initTable[string, int]()
  )

proc isBackedOff*(hp: HolepunchState, key: string): bool =
  if key in hp.backoff:
    return hp.backoff[key] > epochTime()

proc isBackedOff*(hp: HolepunchState, key: string, nowTs: float): bool =
  if key in hp.backoff:
    return hp.backoff[key] > nowTs

proc isInFlight*(hp: HolepunchState, key: string): bool =
  key in hp.inFlight

proc isExpected*(hp: HolepunchState, key: string): bool =
  if key in hp.expected:
    return epochTime() < hp.expected[key]

proc clearInFlight*(hp: var HolepunchState, key: string) =
  hp.inFlight.excl(key)

proc clearExpected*(hp: var HolepunchState, key: string) =
  hp.expected.del(key)

proc markInFlight*(hp: var HolepunchState, key: string) =
  hp.inFlight.incl(key)
  hp.expected[key] = epochTime() + DefaultExpectedSec

proc recordSuccess*(hp: var HolepunchState, key: string) =
  ## Record a successful holepunch connection. Resets backoff state
  ## and removes relay mappings — we no longer need relay candidates
  ## for a target we've directly connected to.
  hp.successes += 1
  hp.backoff.del(key)
  hp.expected.del(key)
  hp.inFlight.excl(key)
  hp.retryCount.del(key)
  hp.removeTarget(key)

proc recordError*(hp: var HolepunchState, key: string, errCode: uint32) =
  ## Record a holepunch error from a relay. Applies exponential backoff.
  hp.lastError = errorName(errCode)
  hp.inFlight.excl(key)
  let count = hp.retryCount.getOrDefault(key, 0) + 1
  hp.retryCount[key] = count
  let backoff = min(DefaultErrorBackoffSec * pow(BackoffMultiplier,
                    float(count - 1)), MaxBackoffSec)
  hp.backoff[key] = epochTime() + backoff

proc recordAttempt*(hp: var HolepunchState, key: string) =
  ## Record a rendezvous attempt. Applies exponential backoff per target.
  hp.attempts += 1
  let count = hp.retryCount.getOrDefault(key, 0) + 1
  hp.retryCount[key] = count
  let backoff = min(DefaultRetrySec * pow(BackoffMultiplier,
                    float(count - 1)), MaxBackoffSec)
  hp.backoff[key] = epochTime() + backoff
  hp.expected[key] = epochTime() + DefaultExpectedSec

proc recordDisconnect*(hp: var HolepunchState, key: string) =
  ## Clean up all holepunch state for a disconnected peer.
  ## Uses inverse index for O(targets-for-relay) cleanup instead of O(all-targets).
  hp.inFlight.excl(key)
  hp.backoff.del(key)
  hp.retryCount.del(key)
  hp.expected.del(key)
  # Remove this peer as a relay using the inverse index
  if key in hp.targetsByRelay:
    let targets = hp.targetsByRelay[key]
    for target in targets:
      if target in hp.relayByTarget:
        hp.relayByTarget[target].excl(key)
        if hp.relayByTarget[target].len == 0:
          hp.relayByTarget.del(target)
    hp.targetsByRelay.del(key)

proc recordRelay*(hp: var HolepunchState, targetKey: string, relayKey: string) =
  ## Record that `relayKey` can relay for `targetKey`.
  ## Maintains both forward and inverse indexes. Evicts oldest relay
  ## when MaxRelaysPerTarget is exceeded.
  if targetKey notin hp.relayByTarget:
    hp.relayByTarget[targetKey] = initHashSet[string]()
  hp.relayByTarget[targetKey].incl(relayKey)
  # Evict excess relays
  while hp.relayByTarget[targetKey].len > MaxRelaysPerTarget:
    var oldest: string
    for rk in hp.relayByTarget[targetKey]:
      oldest = rk
      break
    hp.relayByTarget[targetKey].excl(oldest)
    if oldest in hp.targetsByRelay:
      hp.targetsByRelay[oldest].excl(targetKey)
      if hp.targetsByRelay[oldest].len == 0:
        hp.targetsByRelay.del(oldest)
  # Maintain inverse index
  if relayKey notin hp.targetsByRelay:
    hp.targetsByRelay[relayKey] = initHashSet[string]()
  hp.targetsByRelay[relayKey].incl(targetKey)

proc removeTarget*(hp: var HolepunchState, targetKey: string) =
  ## Remove all state for a target peer.
  if targetKey in hp.relayByTarget:
    let relays = hp.relayByTarget[targetKey]
    for rk in relays:
      if rk in hp.targetsByRelay:
        hp.targetsByRelay[rk].excl(targetKey)
        if hp.targetsByRelay[rk].len == 0:
          hp.targetsByRelay.del(rk)
    hp.relayByTarget.del(targetKey)
  hp.backoff.del(targetKey)
  hp.retryCount.del(targetKey)
  hp.expected.del(targetKey)
  hp.inFlight.excl(targetKey)

proc cleanupExpired*(hp: var HolepunchState) =
  ## Remove stale entries to prevent unbounded table growth.
  ## Call periodically (e.g., every 60s).
  let now = epochTime()
  var expiredBackoffs: seq[string]
  for k, v in hp.backoff:
    if v <= now:
      expiredBackoffs.add(k)
  for k in expiredBackoffs:
    hp.backoff.del(k)
    # Also clean retryCount for expired backoffs with no other state
    if k notin hp.inFlight and k notin hp.expected:
      hp.retryCount.del(k)
  var expiredExpected: seq[string]
  for k, v in hp.expected:
    if v <= now:
      expiredExpected.add(k)
  for k in expiredExpected:
    hp.expected.del(k)

  # Sweep stale relay targets: remove targets that have no active state
  # (not in backoff, inFlight, or expected). These are targets we've either
  # already connected to, permanently failed, or forgotten about.
  var staleTargets: seq[string]
  for targetKey in hp.relayByTarget.keys:
    if targetKey notin hp.backoff and
       targetKey notin hp.inFlight and
       targetKey notin hp.expected and
       targetKey notin hp.retryCount:
      staleTargets.add(targetKey)
  for targetKey in staleTargets:
    hp.removeTarget(targetKey)

iterator relaysFor*(hp: HolepunchState, targetKey: string): string =
  ## Yield all relay peer keys for a given target.
  if targetKey in hp.relayByTarget:
    for rk in hp.relayByTarget[targetKey]:
      yield rk
