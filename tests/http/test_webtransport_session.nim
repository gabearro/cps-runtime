## WebTransport session establishment tests.

import cps
import cps/http/client/webtransport as wt_client
import cps/http/server/webtransport as wt_server

block testClientAndServerSessionOpen:
  let clientSession = runCps(wt_client.openWebTransportSession("example.com", "/wt"))
  doAssert not clientSession.isNil
  doAssert clientSession.isClient
  doAssert clientSession.authority == "example.com"
  doAssert clientSession.path == "/wt"

  let serverSession = runCps(wt_server.acceptWebTransportSession(
    sessionId = 7'u64,
    authority = "example.com",
    path = "/wt"
  ))
  doAssert not serverSession.isNil
  doAssert not serverSession.isClient
  doAssert serverSession.sessionId == 7'u64
  echo "PASS: WebTransport client/server session establishment"

block testServerPolicyHook:
  var invoked = false
  let policy: wt_server.WebTransportPolicyHook =
    proc(origin: string, authority: string, path: string): bool {.closure.} =
      discard origin
      discard authority
      invoked = true
      path == "/allowed"

  let allowed = runCps(wt_server.acceptWebTransportSession(
    sessionId = 11'u64,
    authority = "example.com",
    path = "/allowed",
    policyHook = policy
  ))
  doAssert invoked
  doAssert allowed.path == "/allowed"
  echo "PASS: WebTransport policy hook accepted session"

block testConnectHeaderShape:
  let hdrs = wt_client.buildConnectHeaders("example.com", "/wt", origin = "https://app.example")
  doAssert wt_server.isWebTransportConnectRequest(hdrs)
  let parsed = wt_server.parseConnectRequest(hdrs)
  doAssert parsed.authority == "example.com"
  doAssert parsed.path == "/wt"
  doAssert parsed.origin == "https://app.example"
  doAssert parsed.protocol == "webtransport"
  echo "PASS: WebTransport CONNECT header parsing"

echo "All WebTransport session tests passed"
