## MASQUE CONNECT-IP tests.

import cps
import cps/http/client/masque as masque_client
import cps/http/server/masque as masque_server
import cps/http/shared/masque

block testClientConnectIp:
  let session = runCps(masque_client.connectIp("proxy.example", "2001:db8::/32"))
  doAssert not session.isNil
  doAssert session.mode == mmConnectIp
  doAssert session.target == "2001:db8::/32"
  echo "PASS: MASQUE CONNECT-IP client session"

block testServerConnectIpPolicyRejection:
  let denyIp: masque_server.MasquePolicyHook =
    proc(mode: MasqueMode, authority: string, target: string): bool {.closure.} =
      discard authority
      discard target
      mode != mmConnectIp

  var rejected = false
  try:
    discard runCps(masque_server.connectIp(
      authority = "proxy.example",
      targetIpPrefix = "10.0.0.0/24",
      policyHook = denyIp
    ))
  except ValueError:
    rejected = true
  doAssert rejected
  echo "PASS: MASQUE CONNECT-IP policy rejection propagates"

block testConnectIpHeaderShape:
  let hdrs = masque_client.buildConnectIpHeaders("proxy.example", "2001:db8::/32")
  doAssert masque_server.isMasqueConnectRequest(hdrs)
  let req = masque_server.parseConnectRequest(hdrs)
  doAssert req.mode == mmConnectIp
  doAssert req.authority == "proxy.example"
  doAssert req.target == "2001:db8::/32"
  doAssert req.draftVersion.len > 0
  echo "PASS: MASQUE CONNECT-IP header parsing"

echo "All MASQUE CONNECT-IP tests passed"
