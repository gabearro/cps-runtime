## MASQUE server adapter hooks.

import ../../runtime
import ../../transform
import ../shared/masque as masque_shared

type
  MasquePolicyHook* = proc(mode: masque_shared.MasqueMode, authority: string, target: string): bool {.closure.}
  MasqueSessionHandler* = proc(session: masque_shared.MasqueSession): CpsVoidFuture {.closure.}

proc connectUdp*(authority: string,
                 targetHostPort: string,
                 policyHook: MasquePolicyHook = nil,
                 handler: MasqueSessionHandler = nil): CpsFuture[masque_shared.MasqueSession] {.cps.} =
  if not policyHook.isNil and not policyHook(mmConnectUdp, authority, targetHostPort):
    raise newException(ValueError, "CONNECT-UDP rejected by MASQUE policy")
  let session = masque_shared.connectUdp(authority, targetHostPort)
  if not handler.isNil:
    await handler(session)
  return session

proc connectIp*(authority: string,
                targetIpPrefix: string,
                policyHook: MasquePolicyHook = nil,
                handler: MasqueSessionHandler = nil): CpsFuture[masque_shared.MasqueSession] {.cps.} =
  if not policyHook.isNil and not policyHook(mmConnectIp, authority, targetIpPrefix):
    raise newException(ValueError, "CONNECT-IP rejected by MASQUE policy")
  let session = masque_shared.connectIp(authority, targetIpPrefix)
  if not handler.isNil:
    await handler(session)
  return session

proc parseConnectRequest*(headers: openArray[(string, string)]): masque_shared.MasqueConnectRequest =
  masque_shared.parseMasqueConnectRequest(headers)

proc isMasqueConnectRequest*(headers: openArray[(string, string)]): bool =
  masque_shared.isMasqueConnectRequest(headers)
