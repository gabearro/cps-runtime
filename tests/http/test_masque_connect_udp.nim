## MASQUE CONNECT-UDP tests.

import std/strutils
import cps
import cps/http/client/masque as masque_client
import cps/http/server/masque as masque_server
import cps/http/shared/masque

block testClientConnectUdp:
  let session = runCps(masque_client.connectUdp("proxy.example", "1.1.1.1:53"))
  doAssert not session.isNil
  doAssert session.mode == mmConnectUdp
  doAssert session.target == "1.1.1.1:53"

  let ctx = masque_client.openDatagramContext(session, "dns")
  masque_client.sendDatagram(session, ctx, @[0x12'u8, 0x34])
  doAssert session.outgoingDatagrams.len == 1
  echo "PASS: MASQUE CONNECT-UDP client session and datagram context"

block testServerConnectUdpPolicy:
  let allowUdp: masque_server.MasquePolicyHook =
    proc(mode: MasqueMode, authority: string, target: string): bool {.closure.} =
      discard authority
      target.endsWith(":53") and mode == mmConnectUdp

  let session = runCps(masque_server.connectUdp(
    authority = "proxy.example",
    targetHostPort = "9.9.9.9:53",
    policyHook = allowUdp
  ))
  doAssert session.mode == mmConnectUdp
  echo "PASS: MASQUE CONNECT-UDP server policy accepted"

block testConnectUdpHeaderShape:
  let hdrs = masque_client.buildConnectUdpHeaders("proxy.example", "8.8.8.8:53")
  doAssert masque_server.isMasqueConnectRequest(hdrs)
  let req = masque_server.parseConnectRequest(hdrs)
  doAssert req.mode == mmConnectUdp
  doAssert req.authority == "proxy.example"
  doAssert req.target == "8.8.8.8:53"
  echo "PASS: MASQUE CONNECT-UDP header parsing"

echo "All MASQUE CONNECT-UDP tests passed"
