## Tests for signed cookie session middleware.

import std/strutils
import cps/http/server/dsl
import cps/http/server/testclient
import cps/http/middleware/session

block testSessionRoundTrip:
  let cfg = newSessionConfig("primary-secret-key")
  let handler = router:
    use sessionMiddleware(cfg)

    get "/login":
      setSession(req, "user", "alice")
      respond 200, "ok"

    get "/me":
      let user = getSession(req, "user")
      if user.len == 0:
        respond 401, "missing"
      respond 200, user

  let client = newTestClient(handler)
  let loginResp = client.runRequest("GET", "/login")
  assert loginResp.statusCode == 200
  let setCookie = loginResp.getResponseHeader("set-cookie")
  assert setCookie.len > 0, "Expected Set-Cookie on login"
  let cookieHeader = setCookie.split(';')[0]

  let meResp = client.runRequest("GET", "/me", "", @[("Cookie", cookieHeader)])
  assert meResp.statusCode == 200
  assert meResp.body == "alice", "Expected session user to round-trip"
  echo "PASS: session cookie round-trip"

block testSessionSecretRotation:
  let oldCfg = newSessionConfig("old-secret-key")
  let mintCookieHandler = router:
    use sessionMiddleware(oldCfg)
    get "/mint":
      setSession(req, "role", "admin")
      respond 200, "minted"
  let mintClient = newTestClient(mintCookieHandler)
  let minted = mintClient.runRequest("GET", "/mint")
  assert minted.statusCode == 200
  let oldCookie = minted.getResponseHeader("set-cookie").split(';')[0]

  let rotatedCfg = newSessionConfig(
    "new-secret-key",
    secretFallbacks = @["old-secret-key"]
  )
  let readHandler = router:
    use sessionMiddleware(rotatedCfg)
    get "/read":
      respond 200, getSession(req, "role")
  let readClient = newTestClient(readHandler)

  let readResp = readClient.runRequest("GET", "/read", "", @[("Cookie", oldCookie)])
  assert readResp.statusCode == 200
  assert readResp.body == "admin", "Expected fallback secret to validate old cookie"
  assert readResp.getResponseHeader("set-cookie").len > 0, "Expected rotated cookie to be re-issued"
  echo "PASS: session secret rotation"
