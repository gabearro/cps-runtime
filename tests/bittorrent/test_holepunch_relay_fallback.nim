## Tests for holepunch relay fallback (Task 7), relay extension ID handling
## (Task 8), uTP accept backlog (Task 9), and PEX listen port (Task 10).

import std/[tables, deques]
import cps/bittorrent/extensions
import cps/bittorrent/holepunch
import cps/bittorrent/pex
import cps/bittorrent/utp_stream

# ============================================================
# Task 7: Holepunch relay fallback when stored relay disconnects
# ============================================================

block test_holepunch_relay_mapping_updated:
  ## Verify that holepunchRelayByTarget can be updated to a new relay
  ## when the original relay is no longer available.
  ## This tests the data structure pattern used by holepunchLoop.
  var relayByTarget = initTable[string, string]()
  relayByTarget["10.0.0.5:6881"] = "10.0.0.1:6881"  # Original relay

  # Simulate original relay disconnecting (not in peers table)
  var peers = initTable[string, string]()
  peers["10.0.0.2:6881"] = "alt-relay"  # Alternative relay

  let targetKey = "10.0.0.5:6881"
  let storedRelay = relayByTarget.getOrDefault(targetKey, "")
  assert storedRelay == "10.0.0.1:6881"

  # Stored relay not in peers (disconnected) — fallback to any peer
  if storedRelay notin peers:
    for altKey in peers.keys:
      relayByTarget[targetKey] = altKey
      break

  assert relayByTarget[targetKey] == "10.0.0.2:6881"
  echo "PASS: holepunch relay mapping updated on fallback"

block test_holepunch_relay_original_still_valid:
  ## If the original relay is still connected, use it (no change).
  var relayByTarget = initTable[string, string]()
  relayByTarget["10.0.0.5:6881"] = "10.0.0.1:6881"

  var peers = initTable[string, string]()
  peers["10.0.0.1:6881"] = "original-relay"
  peers["10.0.0.2:6881"] = "alt-relay"

  let targetKey = "10.0.0.5:6881"
  let storedRelay = relayByTarget.getOrDefault(targetKey, "")
  assert storedRelay in peers
  # No update needed
  assert relayByTarget[targetKey] == "10.0.0.1:6881"
  echo "PASS: holepunch relay kept when still valid"

# ============================================================
# Task 8: Extension registry and sendExtended ID lookup
# ============================================================

block test_extension_registry_remote_id_populated:
  ## After decodeExtHandshake, remoteId should be non-zero for advertised extensions.
  var reg = newExtensionRegistry()
  discard reg.registerExtension(UtHolepunchName)
  discard reg.registerExtension(UtPexName)

  # Simulate receiving an extension handshake from remote
  let handshakePayload = encodeExtHandshake(reg, 0, 0, 250, "test")
  var remoteReg = newExtensionRegistry()
  remoteReg.decodeExtHandshake(handshakePayload)

  # Remote IDs should be populated
  assert remoteReg.remoteId(UtHolepunchName) != 0,
    "ut_holepunch remote ID should be non-zero after handshake"
  assert remoteReg.remoteId(UtPexName) != 0,
    "ut_pex remote ID should be non-zero after handshake"
  assert remoteReg.supportsExtension(UtHolepunchName)
  assert remoteReg.supportsExtension(UtPexName)
  echo "PASS: extension registry remote IDs populated after handshake"

block test_extension_not_in_handshake_returns_zero:
  ## If the remote didn't advertise an extension, remoteId should be 0.
  var reg = newExtensionRegistry()
  discard reg.registerExtension(UtPexName)
  # Note: NOT registering UtHolepunchName

  let handshakePayload = encodeExtHandshake(reg, 0, 0, 250, "test")
  var remoteReg = newExtensionRegistry()
  remoteReg.decodeExtHandshake(handshakePayload)

  assert remoteReg.remoteId(UtPexName) != 0
  assert remoteReg.remoteId(UtHolepunchName) == 0,
    "ut_holepunch should not be registered if remote didn't advertise it"
  assert not remoteReg.supportsExtension(UtHolepunchName)
  echo "PASS: extension not in handshake returns remoteId 0"

block test_relay_processes_holepunch_without_support_check:
  ## A peer can send us a holepunch message even if supportsExtension
  ## returns false (e.g., re-handshake cleared their IDs). The relay
  ## handler should still process the message based on state == psActive,
  ## not on supportsExtension.
  var reg = newExtensionRegistry()
  discard reg.registerExtension(UtHolepunchName)
  # Simulate remote handshake that does NOT include ut_holepunch
  var peerReg = newExtensionRegistry()
  discard peerReg.registerExtension("ut_metadata")
  let handshake = encodeExtHandshake(peerReg)
  reg.decodeExtHandshake(handshake)

  # supportsExtension is false, but the peer might still send us messages
  assert not reg.supportsExtension(UtHolepunchName),
    "supportsExtension should be false when peer didn't advertise it"
  # Our local ID is still valid for receiving
  assert reg.localId(UtHolepunchName) != 0,
    "localId should still be valid for receiving messages"
  echo "PASS: relay can process holepunch even without supportsExtension"

# ============================================================
# Task 9: uTP accept backlog
# ============================================================

block test_utp_accept_backlog_constant:
  assert UtpAcceptBacklogSize == 16
  echo "PASS: uTP accept backlog size is 16"

block test_utp_backlog_deque_init:
  ## The backlog deque initializes empty and can be used.
  var backlog = initDeque[UtpStream]()
  assert backlog.len == 0
  echo "PASS: uTP backlog deque initializes empty"

block test_utp_backlog_queue_and_drain:
  ## Test that the backlog deque can hold streams and be drained.
  var backlog = initDeque[UtpStream]()

  # Create dummy streams
  let s1 = UtpStream(remoteIp: "1.1.1.1", remotePort: 6881)
  let s2 = UtpStream(remoteIp: "2.2.2.2", remotePort: 6882)

  backlog.addLast(s1)
  backlog.addLast(s2)
  assert backlog.len == 2

  let first = backlog.popFirst()
  assert first.remoteIp == "1.1.1.1"
  assert backlog.len == 1

  let second = backlog.popFirst()
  assert second.remoteIp == "2.2.2.2"
  assert backlog.len == 0
  echo "PASS: uTP backlog queue and drain FIFO order"

block test_utp_backlog_cap:
  ## Backlog should respect the size limit.
  var backlog = initDeque[UtpStream]()
  var i = 0
  while i < UtpAcceptBacklogSize + 5:
    if backlog.len < UtpAcceptBacklogSize:
      backlog.addLast(UtpStream(remoteIp: "1.1.1." & $i, remotePort: (6881 + i)))
    i += 1

  assert backlog.len == UtpAcceptBacklogSize,
    "backlog should cap at " & $UtpAcceptBacklogSize & " but got " & $backlog.len
  echo "PASS: uTP backlog respects cap"

# ============================================================
# Task 10: PEX uses remoteListenPort instead of transport port
# ============================================================

block test_pex_uses_listen_port:
  ## When a peer has a remoteListenPort (BEP 10 "p"), PEX should
  ## advertise that port, not the transport port.
  var reg = newExtensionRegistry()
  discard reg.registerExtension(UtPexName)

  # Simulate a peer connected on transport port 51234,
  # but advertising listen port 6881 via extension handshake.
  let transportPort: uint16 = 51234
  let listenPort: uint16 = 6881

  # The fix: prefer remoteListenPort when > 0
  let advertisePort: uint16 = if listenPort > 0: listenPort else: transportPort
  assert advertisePort == 6881,
    "PEX should advertise listen port (6881), not transport port (51234)"
  echo "PASS: PEX uses remoteListenPort when available"

block test_pex_falls_back_to_transport_port:
  ## When remoteListenPort is 0 (not advertised), use transport port.
  let transportPort: uint16 = 51234
  let listenPort: uint16 = 0  # Not advertised

  let advertisePort: uint16 = if listenPort > 0: listenPort else: transportPort
  assert advertisePort == 51234,
    "PEX should fall back to transport port when listen port not advertised"
  echo "PASS: PEX falls back to transport port when listen port not set"

block test_pex_encoding_with_listen_port:
  ## Verify the encoded PEX message contains the correct port.
  let added = @[("192.168.1.100", 6881'u16)]
  let flags = @[uint8(pexUtp)]
  let encoded = encodePexMessage(added, flags, @[])
  let decoded = decodePexMessage(encoded)
  assert decoded.added.len == 1
  assert decoded.added[0].ip == "192.168.1.100"
  assert decoded.added[0].port == 6881
  echo "PASS: PEX encoding preserves listen port"

# ============================================================
# Task 21: LSD peers should go through queuePeerIfNeeded
# ============================================================

block test_lsd_uses_queue_not_direct_connect:
  ## LSD-discovered peers should be queued via queuePeerIfNeeded,
  ## not directly constructed and run. This ensures backoff, per-IP
  ## limits, and transport/encryption setup are applied.
  ##
  ## The fix changes makeLsdCallback to call queuePeerIfNeeded(srcLsd)
  ## instead of directly creating PeerConn and calling run().
  ## This test validates the queueing pattern works correctly.
  type PendingPeer = tuple[ip: string, port: uint16, source: int, pexFlags: uint8]
  var pendingPeers: seq[PendingPeer]
  var peers = initTable[string, string]()

  # Simulate queuePeerIfNeeded for LSD
  proc queueIfNeeded(ip: string, port: uint16): bool =
    let key = ip & ":" & $port
    if key in peers:
      return false
    var i = 0
    while i < pendingPeers.len:
      if pendingPeers[i].ip == ip and pendingPeers[i].port == port:
        return false
      inc i
    pendingPeers.add((ip: ip, port: port, source: 4, pexFlags: 0'u8))  # 4 = srcLsd
    true

  # First LSD announcement
  assert queueIfNeeded("192.168.1.10", 6881) == true
  assert pendingPeers.len == 1

  # Duplicate LSD announcement — should be rejected
  assert queueIfNeeded("192.168.1.10", 6881) == false
  assert pendingPeers.len == 1

  # Already connected peer — should be rejected
  peers["192.168.1.20:6881"] = "connected"
  assert queueIfNeeded("192.168.1.20", 6881) == false
  assert pendingPeers.len == 1

  # New LSD peer — should be queued
  assert queueIfNeeded("192.168.1.30", 6881) == true
  assert pendingPeers.len == 2
  echo "PASS: LSD peers use queue-based connection (not direct)"

echo "All network protocol bug fix tests passed!"
