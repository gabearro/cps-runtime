## MASQUE client adapter.

import ../../runtime
import ../../transform
import ../shared/masque as masque_shared

proc connectUdp*(authority: string, targetHostPort: string): CpsFuture[masque_shared.MasqueSession] {.cps.} =
  return masque_shared.connectUdp(authority, targetHostPort)

proc connectIp*(authority: string, targetIpPrefix: string): CpsFuture[masque_shared.MasqueSession] {.cps.} =
  return masque_shared.connectIp(authority, targetIpPrefix)

proc buildConnectUdpHeaders*(authority: string, targetHostPort: string): seq[(string, string)] =
  masque_shared.buildMasqueConnectUdpHeaders(authority, targetHostPort)

proc buildConnectIpHeaders*(authority: string, targetIpPrefix: string): seq[(string, string)] =
  masque_shared.buildMasqueConnectIpHeaders(authority, targetIpPrefix)

proc sendCapsule*(session: masque_shared.MasqueSession, capsuleType: uint64, payload: openArray[byte]) =
  masque_shared.sendCapsule(session, capsuleType, payload)

proc recvCapsule*(session: masque_shared.MasqueSession): masque_shared.MasqueCapsule =
  masque_shared.recvCapsule(session)

proc openDatagramContext*(session: masque_shared.MasqueSession, label: string = ""): uint64 =
  masque_shared.openDatagramContext(session, label)

proc sendDatagram*(session: masque_shared.MasqueSession, contextId: uint64, payload: openArray[byte]) =
  masque_shared.sendDatagram(session, contextId, payload)

proc recvDatagram*(session: masque_shared.MasqueSession): masque_shared.MasqueDatagram =
  masque_shared.recvDatagram(session)

proc encodeCapsuleWire*(capsuleType: uint64, payload: openArray[byte]): seq[byte] =
  masque_shared.encodeCapsuleWire(capsuleType, payload)

proc decodeMasqueDatagramWire*(wire: openArray[byte]): masque_shared.MasqueDatagram =
  masque_shared.decodeMasqueDatagramWire(wire)
