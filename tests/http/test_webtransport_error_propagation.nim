## WebTransport error propagation tests.

import cps
import cps/http/client/webtransport as wt_client
import cps/http/server/webtransport as wt_server

block testPolicyRejectionRaises:
  let denyPolicy: wt_server.WebTransportPolicyHook =
    proc(origin: string, authority: string, path: string): bool {.closure.} =
      discard origin
      discard authority
      discard path
      false

  var rejected = false
  try:
    discard runCps(wt_server.acceptWebTransportSession(
      sessionId = 99'u64,
      authority = "example.com",
      path = "/deny",
      policyHook = denyPolicy
    ))
  except ValueError:
    rejected = true
  doAssert rejected
  echo "PASS: WebTransport policy rejection surfaces as error"

block testClosedSessionOperationsRaise:
  let session = runCps(wt_client.openWebTransportSession("example.com", "/wt"))
  wt_client.closeSession(session, errorCode = 1'u32, reason = "closing")

  var streamErr = false
  try:
    discard wt_client.openBidiStream(session)
  except ValueError:
    streamErr = true
  doAssert streamErr

  var datagramErr = false
  try:
    wt_client.sendDatagram(session, @[0x01'u8])
  except ValueError:
    datagramErr = true
  doAssert datagramErr
  echo "PASS: WebTransport closed-session errors propagate"

echo "All WebTransport error propagation tests passed"
