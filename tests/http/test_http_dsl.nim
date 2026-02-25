## Tests for HTTP Router DSL
##
## Tests route matching, path parameters, query strings, middleware,
## groups, static files, cookies, redirects, content-type helpers,
## 404 handling, async handlers, and all new features (Phases 1-6).

import std/[strutils, nativesockets, os, tables, json, uri, base64]
from std/posix import Sockaddr_in, SockLen
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/http/server/types
import cps/http/server/http1 as http1_server
import cps/http/server/router
import cps/http/server/dsl
import cps/http/shared/multipart
import cps/http/server/testclient

# ============================================================
# Helpers
# ============================================================

proc getListenerPort(listener: TcpListener): int =
  var localAddr: Sockaddr_in
  var addrLen: SockLen = sizeof(localAddr).SockLen
  let rc = posix.getsockname(listener.fd, cast[ptr SockAddr](addr localAddr), addr addrLen)
  assert rc == 0, "getsockname failed"
  result = ntohs(localAddr.sin_port).int

proc sendRawRequest(p: int, reqStr: string): CpsFuture[string] {.cps.} =
  ## Send a raw HTTP/1.1 request and read the full response.
  let conn = await tcpConnect("127.0.0.1", p)
  await conn.AsyncStream.write(reqStr)
  var response = ""
  while true:
    let chunk = await conn.AsyncStream.read(4096)
    if chunk.len == 0:
      break
    response &= chunk
  conn.AsyncStream.close()
  return response

proc runServerClient(listener: TcpListener, handler: HttpHandler,
                      reqStr: string): string =
  ## Spin up a server accepting one connection, send a request, return response.
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig,
                  h: HttpHandler): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, h)

  let sf = serverTask(listener, config, handler)
  let cf = sendRawRequest(port, reqStr)
  let loop = getEventLoop()
  while not cf.finished:
    loop.tick()
    if not loop.hasWork:
      break
  result = cf.read()

proc extractBody(response: string): string =
  ## Extract HTTP response body (after \r\n\r\n).
  let idx = response.find("\r\n\r\n")
  if idx >= 0:
    return response[idx + 4 .. ^1]
  return ""

proc extractHeader(response: string, name: string): string =
  ## Extract a header value from an HTTP response.
  let headerEnd = response.find("\r\n\r\n")
  let headerSection = if headerEnd >= 0: response[0 ..< headerEnd] else: response
  for line in headerSection.split("\r\n"):
    let colonIdx = line.find(':')
    if colonIdx > 0:
      let key = line[0 ..< colonIdx].strip()
      if key.toLowerAscii == name.toLowerAscii:
        return line[colonIdx + 1 .. ^1].strip()
  return ""

proc extractStatusCode(response: string): int =
  ## Extract HTTP status code from response.
  let firstLine = response.split("\r\n")[0]
  let parts = firstLine.split(' ')
  if parts.len >= 2:
    return parseInt(parts[1])
  return 0

# ============================================================
# Test 1: Basic GET route
# ============================================================
block testBasicGet:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    get "/":
      respond 200, "Hello World"

  let response = runServerClient(listener, handler,
    "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  assert extractStatusCode(response) == 200, "Expected 200, got: " & $extractStatusCode(response)
  assert extractBody(response) == "Hello World", "Body: " & extractBody(response)
  listener.close()
  echo "PASS: Basic GET route"

# ============================================================
# Test 2: POST route with body
# ============================================================
block testPostWithBody:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    post "/submit":
      let data = body()
      respond 201, "Got: " & data

  let postBody = "hello=world"
  let response = runServerClient(listener, handler,
    "POST /submit HTTP/1.1\r\nHost: localhost\r\nContent-Length: " &
    $postBody.len & "\r\nConnection: close\r\n\r\n" & postBody)

  assert extractStatusCode(response) == 201, "Expected 201"
  assert "Got: hello=world" in extractBody(response), "Body: " & extractBody(response)
  listener.close()
  echo "PASS: POST route with body"

# ============================================================
# Test 3: Path parameters
# ============================================================
block testPathParams:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    get "/users/{id}":
      let userId = pathParams["id"]
      respond 200, "User: " & userId

  let response = runServerClient(listener, handler,
    "GET /users/42 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  assert extractStatusCode(response) == 200
  assert extractBody(response) == "User: 42", "Body: " & extractBody(response)
  listener.close()
  echo "PASS: Path parameters"

# ============================================================
# Test 4: Multiple path parameters
# ============================================================
block testMultiplePathParams:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    get "/a/{x}/b/{y}":
      let x = pathParams["x"]
      let y = pathParams["y"]
      respond 200, x & "+" & y

  let response = runServerClient(listener, handler,
    "GET /a/hello/b/world HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  assert extractStatusCode(response) == 200
  assert extractBody(response) == "hello+world", "Body: " & extractBody(response)
  listener.close()
  echo "PASS: Multiple path parameters"

# ============================================================
# Test 5: Query string parsing
# ============================================================
block testQueryString:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    get "/search":
      let q = queryParam("q", "none")
      let page = queryParam("page", "1")
      respond 200, "q=" & q & "&page=" & page

  let response = runServerClient(listener, handler,
    "GET /search?q=hello&page=3 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  assert extractStatusCode(response) == 200
  assert extractBody(response) == "q=hello&page=3", "Body: " & extractBody(response)
  listener.close()
  echo "PASS: Query string parsing"

# ============================================================
# Test 6: Route groups with prefix
# ============================================================
block testRouteGroups:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    get "/":
      respond 200, "root"

    group "/api/v1":
      get "/items":
        respond 200, "items list"

      get "/items/{id}":
        let id = pathParams["id"]
        respond 200, "item:" & id

  # Test root
  let resp1 = runServerClient(listener, handler,
    "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  assert extractBody(resp1) == "root", "Root body: " & extractBody(resp1)
  listener.close()

  # Test group route
  let listener2 = tcpListen("127.0.0.1", 0)
  let resp2 = runServerClient(listener2, handler,
    "GET /api/v1/items HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  assert extractBody(resp2) == "items list", "Group body: " & extractBody(resp2)
  listener2.close()

  # Test group route with params
  let listener3 = tcpListen("127.0.0.1", 0)
  let resp3 = runServerClient(listener3, handler,
    "GET /api/v1/items/99 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  assert extractBody(resp3) == "item:99", "Group param body: " & extractBody(resp3)
  listener3.close()
  echo "PASS: Route groups with prefix"

# ============================================================
# Test 7: Middleware execution (adds header)
# ============================================================
block testMiddleware:
  let listener = tcpListen("127.0.0.1", 0)

  proc addHeaderMiddleware(req: HttpRequest, next: HttpHandler): CpsFuture[HttpResponseBuilder] {.closure.} =
    let fut = next(req)
    let resultFut = newCpsFuture[HttpResponseBuilder]()
    fut.addCallback(proc() =
      if fut.hasError():
        resultFut.fail(fut.getError())
      else:
        var resp = fut.read()
        resp.headers.add ("X-Custom", "middleware-was-here")
        resultFut.complete(resp)
    )
    return resultFut

  let handler = router:
    use addHeaderMiddleware

    get "/test":
      respond 200, "ok"

  let response = runServerClient(listener, handler,
    "GET /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  assert extractStatusCode(response) == 200
  assert extractHeader(response, "X-Custom") == "middleware-was-here",
    "Missing X-Custom header"
  listener.close()
  echo "PASS: Middleware execution"

# ============================================================
# Test 8: Group-scoped middleware
# ============================================================
block testGroupMiddleware:
  let listener = tcpListen("127.0.0.1", 0)

  proc apiMiddleware(req: HttpRequest, next: HttpHandler): CpsFuture[HttpResponseBuilder] {.closure.} =
    let fut = next(req)
    let resultFut = newCpsFuture[HttpResponseBuilder]()
    fut.addCallback(proc() =
      if fut.hasError():
        resultFut.fail(fut.getError())
      else:
        var resp = fut.read()
        resp.headers.add ("X-Api", "true")
        resultFut.complete(resp)
    )
    return resultFut

  let handler = router:
    get "/public":
      respond 200, "public"

    group "/api":
      use apiMiddleware

      get "/data":
        respond 200, "api data"

  # Public route should NOT have X-Api header
  let resp1 = runServerClient(listener, handler,
    "GET /public HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  assert extractHeader(resp1, "X-Api") == "", "Public should not have X-Api"
  listener.close()

  # API route should have X-Api header
  let listener2 = tcpListen("127.0.0.1", 0)
  let resp2 = runServerClient(listener2, handler,
    "GET /api/data HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  assert extractHeader(resp2, "X-Api") == "true", "API should have X-Api"
  listener2.close()
  echo "PASS: Group-scoped middleware"

# ============================================================
# Test 9: Middleware short-circuit (401)
# ============================================================
block testMiddlewareShortCircuit:
  let listener = tcpListen("127.0.0.1", 0)

  proc authMiddleware(req: HttpRequest, next: HttpHandler): CpsFuture[HttpResponseBuilder] {.closure.} =
    let authHeader = req.getHeader("authorization")
    if authHeader == "":
      let fut = newCpsFuture[HttpResponseBuilder]()
      fut.complete(newResponse(401, "Unauthorized"))
      return fut
    return next(req)

  let handler = router:
    use authMiddleware

    get "/protected":
      respond 200, "secret data"

  # Without auth header
  let resp1 = runServerClient(listener, handler,
    "GET /protected HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  assert extractStatusCode(resp1) == 401, "Expected 401"
  listener.close()

  # With auth header
  let listener2 = tcpListen("127.0.0.1", 0)
  let resp2 = runServerClient(listener2, handler,
    "GET /protected HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer token\r\nConnection: close\r\n\r\n")
  assert extractStatusCode(resp2) == 200, "Expected 200 with auth"
  assert extractBody(resp2) == "secret data"
  listener2.close()
  echo "PASS: Middleware short-circuit (401)"

# ============================================================
# Test 10: Static file serving
# ============================================================
block testStaticFile:
  # Create a temp directory with a test file
  let tmpDir = getTempDir() / "cps_static_test"
  createDir(tmpDir)
  writeFile(tmpDir / "hello.txt", "static content here")

  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    serveStatic "/public", tmpDir

  let response = runServerClient(listener, handler,
    "GET /public/hello.txt HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  assert extractStatusCode(response) == 200, "Expected 200, got " & $extractStatusCode(response)
  assert extractBody(response) == "static content here", "Body: " & extractBody(response)
  assert "text/plain" in extractHeader(response, "Content-Type"),
    "Expected text/plain content-type"
  listener.close()

  # Cleanup
  removeFile(tmpDir / "hello.txt")
  removeDir(tmpDir)
  echo "PASS: Static file serving"

# ============================================================
# Test 11: Cookie helpers (setCookie -> Set-Cookie header)
# ============================================================
block testCookieHelpers:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    get "/setcookie":
      setCookie "session", "abc123"
      respond 200, "cookie set"

  let response = runServerClient(listener, handler,
    "GET /setcookie HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  assert extractStatusCode(response) == 200
  let setCookieHeader = extractHeader(response, "Set-Cookie")
  assert "session=abc123" in setCookieHeader, "Set-Cookie: " & setCookieHeader
  listener.close()
  echo "PASS: Cookie helpers"

# ============================================================
# Test 12: Redirect (302 + Location)
# ============================================================
block testRedirect:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    get "/old":
      redirect "/new"

  let response = runServerClient(listener, handler,
    "GET /old HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  assert extractStatusCode(response) == 302, "Expected 302"
  assert extractHeader(response, "Location") == "/new",
    "Location: " & extractHeader(response, "Location")
  listener.close()
  echo "PASS: Redirect (302 + Location)"

# ============================================================
# Test 13: JSON content-type
# ============================================================
block testJsonContentType:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    get "/api/data":
      json 200, """{"key": "value"}"""

  let response = runServerClient(listener, handler,
    "GET /api/data HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  assert extractStatusCode(response) == 200
  assert "application/json" in extractHeader(response, "Content-Type"),
    "CT: " & extractHeader(response, "Content-Type")
  assert """{"key": "value"}""" in extractBody(response)
  listener.close()
  echo "PASS: JSON content-type"

# ============================================================
# Test 14: HTML content-type
# ============================================================
block testHtmlContentType:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    get "/page":
      html 200, "<h1>Hello</h1>"

  let response = runServerClient(listener, handler,
    "GET /page HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  assert extractStatusCode(response) == 200
  assert "text/html" in extractHeader(response, "Content-Type")
  assert "<h1>Hello</h1>" in extractBody(response)
  listener.close()
  echo "PASS: HTML content-type"

# ============================================================
# Test 15: 404 default
# ============================================================
block test404Default:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    get "/exists":
      respond 200, "here"

  let response = runServerClient(listener, handler,
    "GET /nonexistent HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  assert extractStatusCode(response) == 404, "Expected 404, got " & $extractStatusCode(response)
  listener.close()
  echo "PASS: 404 default"

# ============================================================
# Test 16: Custom notFound handler
# ============================================================
block testCustomNotFound:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    get "/exists":
      respond 200, "here"

    notFound:
      respond 404, "Custom: page not found"

  let response = runServerClient(listener, handler,
    "GET /missing HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  assert extractStatusCode(response) == 404
  assert extractBody(response) == "Custom: page not found",
    "Body: " & extractBody(response)
  listener.close()
  echo "PASS: Custom notFound handler"

# ============================================================
# Test 17: Async handler (awaits cpsSleep)
# ============================================================
block testAsyncHandler:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    get "/slow":
      await cpsSleep(50)
      respond 200, "delayed"

  let response = runServerClient(listener, handler,
    "GET /slow HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  assert extractStatusCode(response) == 200
  assert extractBody(response) == "delayed", "Body: " & extractBody(response)
  listener.close()
  echo "PASS: Async handler (cpsSleep)"

# ============================================================
# Test 18: Multiple routes (method+path dispatch)
# ============================================================
block testMultipleRoutes:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    get "/resource":
      respond 200, "GET resource"

    post "/resource":
      respond 201, "POST resource"

    delete "/resource":
      respond 204

  # Test GET
  let resp1 = runServerClient(listener, handler,
    "GET /resource HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  assert extractStatusCode(resp1) == 200
  assert extractBody(resp1) == "GET resource"
  listener.close()

  # Test POST
  let listener2 = tcpListen("127.0.0.1", 0)
  let resp2 = runServerClient(listener2, handler,
    "POST /resource HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
  assert extractStatusCode(resp2) == 201
  assert extractBody(resp2) == "POST resource"
  listener2.close()

  # Test DELETE
  let listener3 = tcpListen("127.0.0.1", 0)
  let resp3 = runServerClient(listener3, handler,
    "DELETE /resource HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  assert extractStatusCode(resp3) == 204
  listener3.close()
  echo "PASS: Multiple routes (method+path dispatch)"

# ============================================================
# Phase 1 Tests
# ============================================================

# ============================================================
# Test 19: URL-encoded query params
# ============================================================
block testUrlEncodedQuery:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    get "/search":
      let q = queryParam("q", "none")
      respond 200, q

  let response = runServerClient(listener, handler,
    "GET /search?q=hello%20world HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  assert extractStatusCode(response) == 200
  assert extractBody(response) == "hello world", "Body: " & extractBody(response)
  listener.close()
  echo "PASS: URL-encoded query params"

# ============================================================
# Test 20: URL-encoded path params
# ============================================================
block testUrlEncodedPathParams:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    get "/users/{name}":
      let name = pathParams["name"]
      respond 200, name

  let response = runServerClient(listener, handler,
    "GET /users/John%20Doe HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  assert extractStatusCode(response) == 200
  assert extractBody(response) == "John Doe", "Body: " & extractBody(response)
  listener.close()
  echo "PASS: URL-encoded path params"

# ============================================================
# Test 21: any route
# ============================================================
block testAnyRoute:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    any "/anything":
      respond 200, "method=" & req.meth

  let response = runServerClient(listener, handler,
    "POST /anything HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")

  assert extractStatusCode(response) == 200
  assert extractBody(response) == "method=POST", "Body: " & extractBody(response)
  listener.close()
  echo "PASS: any route"

# ============================================================
# Test 22: HEAD auto-generation
# ============================================================
block testHeadAutoGen:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    get "/resource":
      respond 200, "full body here"

  let response = runServerClient(listener, handler,
    "HEAD /resource HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  assert extractStatusCode(response) == 200, "Expected 200, got " & $extractStatusCode(response)
  # HEAD response should have Content-Length but empty body
  let cl = extractHeader(response, "Content-Length")
  assert cl == "14", "Expected Content-Length: 14, got: " & cl
  assert extractBody(response) == "", "HEAD should have empty body"
  listener.close()
  echo "PASS: HEAD auto-generation"

# ============================================================
# Test 23: OPTIONS auto-generation
# ============================================================
block testOptionsAutoGen:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    get "/resource":
      respond 200, "get"
    post "/resource":
      respond 201, "post"
    delete "/resource":
      respond 204

  let response = runServerClient(listener, handler,
    "OPTIONS /resource HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  assert extractStatusCode(response) == 204, "Expected 204, got " & $extractStatusCode(response)
  let allow = extractHeader(response, "Allow")
  assert "GET" in allow, "Allow should include GET: " & allow
  assert "POST" in allow, "Allow should include POST: " & allow
  assert "DELETE" in allow, "Allow should include DELETE: " & allow
  assert "HEAD" in allow, "Allow should include HEAD: " & allow
  listener.close()
  echo "PASS: OPTIONS auto-generation"

# ============================================================
# Test 24: onError handler
# ============================================================
block testOnError:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    get "/crash":
      raise newException(CatchableError, "test crash")

    onError:
      let msg = errorMessage()
      json 500, """{"error": """ & "\"" & msg & "\"" & """}"""

  let response = runServerClient(listener, handler,
    "GET /crash HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  assert extractStatusCode(response) == 500, "Expected 500, got " & $extractStatusCode(response)
  assert "test crash" in extractBody(response), "Body: " & extractBody(response)
  listener.close()
  echo "PASS: onError handler"

# ============================================================
# Test 25: Exception recovery without onError (default 500)
# ============================================================
block testExceptionRecoveryDefault:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    get "/crash":
      raise newException(CatchableError, "boom")

  let response = runServerClient(listener, handler,
    "GET /crash HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  assert extractStatusCode(response) == 500, "Expected 500, got " & $extractStatusCode(response)
  listener.close()
  echo "PASS: Exception recovery (default 500)"

# ============================================================
# Test 26: Form body parsing
# ============================================================
block testFormBodyParsing:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    post "/form":
      let name = formParam("name", "unknown")
      let age = formParam("age", "0")
      respond 200, "name=" & name & "&age=" & age

  let postBody = "name=John%20Doe&age=30"
  let response = runServerClient(listener, handler,
    "POST /form HTTP/1.1\r\nHost: localhost\r\nContent-Length: " &
    $postBody.len & "\r\nConnection: close\r\n\r\n" & postBody)

  assert extractStatusCode(response) == 200
  assert extractBody(response) == "name=John Doe&age=30", "Body: " & extractBody(response)
  listener.close()
  echo "PASS: Form body parsing"

# ============================================================
# Test 27: before hook (short-circuit)
# ============================================================
block testBeforeHook:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    before:
      if header("X-Api-Key") == "":
        respond 401, "API key required"

    get "/data":
      respond 200, "secret data"

  # Without API key
  let resp1 = runServerClient(listener, handler,
    "GET /data HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  assert extractStatusCode(resp1) == 401, "Expected 401, got " & $extractStatusCode(resp1)
  assert extractBody(resp1) == "API key required", "Body: " & extractBody(resp1)
  listener.close()

  # With API key
  let listener2 = tcpListen("127.0.0.1", 0)
  let resp2 = runServerClient(listener2, handler,
    "GET /data HTTP/1.1\r\nHost: localhost\r\nX-Api-Key: secret\r\nConnection: close\r\n\r\n")
  assert extractStatusCode(resp2) == 200, "Expected 200, got " & $extractStatusCode(resp2)
  assert extractBody(resp2) == "secret data", "Body: " & extractBody(resp2)
  listener2.close()
  echo "PASS: before hook (short-circuit)"

# ============================================================
# Phase 2 Tests
# ============================================================

# ============================================================
# Test 28: Status code shortcuts
# ============================================================
block testStatusCodeShortcuts:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    post "/items":
      created "/items/1"

    delete "/items/1":
      noContent()

    get "/bad":
      badRequest "invalid input"

    get "/denied":
      forbidden "access denied"

  # Test created
  let resp1 = runServerClient(listener, handler,
    "POST /items HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
  assert extractStatusCode(resp1) == 201, "Expected 201, got " & $extractStatusCode(resp1)
  assert extractHeader(resp1, "Location") == "/items/1", "Location: " & extractHeader(resp1, "Location")
  listener.close()

  # Test noContent
  let listener2 = tcpListen("127.0.0.1", 0)
  let resp2 = runServerClient(listener2, handler,
    "DELETE /items/1 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  assert extractStatusCode(resp2) == 204, "Expected 204, got " & $extractStatusCode(resp2)
  listener2.close()

  # Test badRequest
  let listener3 = tcpListen("127.0.0.1", 0)
  let resp3 = runServerClient(listener3, handler,
    "GET /bad HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  assert extractStatusCode(resp3) == 400, "Expected 400"
  assert extractBody(resp3) == "invalid input"
  listener3.close()

  # Test forbidden
  let listener4 = tcpListen("127.0.0.1", 0)
  let resp4 = runServerClient(listener4, handler,
    "GET /denied HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  assert extractStatusCode(resp4) == 403, "Expected 403"
  assert extractBody(resp4) == "access denied"
  listener4.close()
  echo "PASS: Status code shortcuts"

# ============================================================
# Phase 3 Tests
# ============================================================

# ============================================================
# Test 29: Typed path params (int)
# ============================================================
block testTypedPathParamsInt:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    get "/items/{id:int}":
      let id = pathParams["id"]
      respond 200, "item:" & id

  # Valid int
  let resp1 = runServerClient(listener, handler,
    "GET /items/42 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  assert extractStatusCode(resp1) == 200
  assert extractBody(resp1) == "item:42"
  listener.close()

  # Invalid int -> 404
  let listener2 = tcpListen("127.0.0.1", 0)
  let resp2 = runServerClient(listener2, handler,
    "GET /items/abc HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  assert extractStatusCode(resp2) == 404, "Expected 404 for non-int param, got " & $extractStatusCode(resp2)
  listener2.close()
  echo "PASS: Typed path params (int)"

# ============================================================
# Test 30: JSON body parsing
# ============================================================
block testJsonBodyParsing:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    post "/api/data":
      let data = jsonBody()
      let name = data["name"].getStr()
      respond 200, "Hello, " & name

  let postBody = """{"name": "Alice"}"""
  let response = runServerClient(listener, handler,
    "POST /api/data HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: " &
    $postBody.len & "\r\nConnection: close\r\n\r\n" & postBody)

  assert extractStatusCode(response) == 200
  assert extractBody(response) == "Hello, Alice", "Body: " & extractBody(response)
  listener.close()
  echo "PASS: JSON body parsing"

# ============================================================
# Test 31: ETag / Cache headers for static files
# ============================================================
block testStaticEtag:
  let tmpDir = getTempDir() / "cps_etag_test"
  createDir(tmpDir)
  writeFile(tmpDir / "test.txt", "cached content")

  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    serveStatic "/static", tmpDir

  # First request - get ETag
  let resp1 = runServerClient(listener, handler,
    "GET /static/test.txt HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  assert extractStatusCode(resp1) == 200
  let etag = extractHeader(resp1, "ETag")
  assert etag.len > 0, "Expected ETag header"
  assert extractHeader(resp1, "Cache-Control").len > 0, "Expected Cache-Control header"
  listener.close()

  # Second request with If-None-Match - should get 304
  let listener2 = tcpListen("127.0.0.1", 0)
  let resp2 = runServerClient(listener2, handler,
    "GET /static/test.txt HTTP/1.1\r\nHost: localhost\r\nIf-None-Match: " & etag & "\r\nConnection: close\r\n\r\n")
  assert extractStatusCode(resp2) == 304, "Expected 304, got " & $extractStatusCode(resp2)
  listener2.close()

  removeFile(tmpDir / "test.txt")
  removeDir(tmpDir)
  echo "PASS: ETag / Cache headers for static files"

# ============================================================
# Phase 4 Tests
# ============================================================

# ============================================================
# Test 32: Route listing
# ============================================================
block testRouteListing:
  # Test the router type directly, not through DSL (since DSL returns HttpHandler)
  var r = Router()
  r.routes.add RouteEntry(
    meth: "GET",
    segments: parsePath("/users/{id}"),
    name: "user_detail"
  )
  r.routes.add RouteEntry(
    meth: "POST",
    segments: parsePath("/users")
  )

  let listing = r.listRoutes()
  assert "GET\t/users/{id} [user_detail]" in listing, "Listing: " & listing
  assert "POST\t/users" in listing, "Listing: " & listing
  echo "PASS: Route listing"

# ============================================================
# Test 33: Named routes / URL generation
# ============================================================
block testNamedRoutes:
  var r = Router()
  r.routes.add RouteEntry(
    meth: "GET",
    segments: parsePath("/users/{id}"),
    name: "user_detail"
  )
  r.routes.add RouteEntry(
    meth: "GET",
    segments: parsePath("/posts/{year}/{slug}"),
    name: "post_detail"
  )

  let url1 = r.urlFor("user_detail", {"id": "42"}.toTable)
  assert url1 == "/users/42", "urlFor: " & url1

  let url2 = r.urlFor("post_detail", {"year": "2024", "slug": "hello-world"}.toTable)
  assert url2 == "/posts/2024/hello-world", "urlFor: " & url2

  let url3 = r.urlFor("nonexistent")
  assert url3 == "", "urlFor nonexistent: " & url3
  echo "PASS: Named routes / URL generation"

# ============================================================
# Test 34: Content negotiation helpers
# ============================================================
block testContentNegotiation:
  # Test parseAcceptHeader
  let entries = parseAcceptHeader("text/html, application/json;q=0.9, */*;q=0.1")
  assert entries.len == 3
  assert entries[0].mediaType == "text/html"
  assert entries[0].quality == 1.0
  assert entries[1].mediaType == "application/json"
  assert entries[1].quality == 0.9

  # Test negotiateContentType
  let ct1 = negotiateContentType("text/html, application/json;q=0.9",
    @["application/json", "text/html"])
  assert ct1 == "text/html", "Negotiated: " & ct1

  let ct2 = negotiateContentType("application/json",
    @["application/json", "text/html"])
  assert ct2 == "application/json", "Negotiated: " & ct2

  let ct3 = negotiateContentType("application/xml",
    @["application/json", "text/html"])
  assert ct3 == "", "Expected empty for no match: " & ct3

  # Test wildcard
  let ct4 = negotiateContentType("*/*",
    @["application/json"])
  assert ct4 == "application/json", "Wildcard: " & ct4
  echo "PASS: Content negotiation helpers"

# ============================================================
# Test 35: Security headers middleware
# ============================================================
block testSecurityHeaders:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    secure

    get "/secure":
      respond 200, "ok"

  let response = runServerClient(listener, handler,
    "GET /secure HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  assert extractStatusCode(response) == 200
  assert "nosniff" in extractHeader(response, "X-Content-Type-Options"),
    "Missing X-Content-Type-Options"
  assert "DENY" in extractHeader(response, "X-Frame-Options"),
    "Missing X-Frame-Options"
  assert "max-age=" in extractHeader(response, "Strict-Transport-Security"),
    "Missing HSTS"
  listener.close()
  echo "PASS: Security headers middleware"

# ============================================================
# Phase 5 Tests
# ============================================================

# ============================================================
# Test 36: Multipart form data parsing
# ============================================================
block testMultipartParsing:
  let boundary = "----WebKitFormBoundary7MA4YWxk"
  let body = "------WebKitFormBoundary7MA4YWxk\r\n" &
    "Content-Disposition: form-data; name=\"name\"\r\n\r\n" &
    "John Doe\r\n" &
    "------WebKitFormBoundary7MA4YWxk\r\n" &
    "Content-Disposition: form-data; name=\"file\"; filename=\"test.txt\"\r\n" &
    "Content-Type: text/plain\r\n\r\n" &
    "file content here\r\n" &
    "------WebKitFormBoundary7MA4YWxk--\r\n"

  let mp = parseMultipart(body, "multipart/form-data; boundary=----WebKitFormBoundary7MA4YWxk")

  assert mp.fields["name"] == "John Doe", "Field name: " & mp.fields["name"]
  assert "file" in mp.files, "Missing file"
  assert mp.files["file"].len == 1
  assert mp.files["file"][0].filename == "test.txt"
  assert mp.files["file"][0].data == "file content here"
  assert mp.files["file"][0].size == 17
  echo "PASS: Multipart form data parsing"

# ============================================================
# Phase 6 Tests
# ============================================================

# ============================================================
# Test 37: Test client
# ============================================================
block testTestClient:
  let handler = router:
    get "/hello":
      respond 200, "Hello from handler"

    post "/echo":
      let data = body()
      respond 200, "Echo: " & data

  let client = newTestClient(handler)

  # Test GET
  let resp1 = client.runRequest("GET", "/hello")
  assert resp1.statusCode == 200
  assert resp1.body == "Hello from handler"

  # Test POST
  let resp2 = client.runRequest("POST", "/echo", body = "test data")
  assert resp2.statusCode == 200
  assert resp2.body == "Echo: test data", "Body: " & resp2.body

  # Test 404
  let resp3 = client.runRequest("GET", "/nonexistent")
  assert resp3.statusCode == 404
  echo "PASS: Test client"

# ============================================================
# Test 38: SPA fallback for static files
# ============================================================
block testSpaFallback:
  let tmpDir = getTempDir() / "cps_spa_test"
  createDir(tmpDir)
  writeFile(tmpDir / "index.html", "<html>SPA</html>")
  writeFile(tmpDir / "style.css", "body{}")

  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    serveStatic "/", tmpDir:
      fallback "index.html"

  # Request for existing file works
  let resp1 = runServerClient(listener, handler,
    "GET /style.css HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  assert extractStatusCode(resp1) == 200
  assert extractBody(resp1) == "body{}"
  listener.close()

  # Request for non-existing path without extension -> fallback to index.html
  let listener2 = tcpListen("127.0.0.1", 0)
  let resp2 = runServerClient(listener2, handler,
    "GET /about HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  assert extractStatusCode(resp2) == 200, "Expected 200, got " & $extractStatusCode(resp2)
  assert "<html>SPA</html>" in extractBody(resp2), "Body: " & extractBody(resp2)
  listener2.close()

  # Request for non-existing file WITH extension -> 404
  let listener3 = tcpListen("127.0.0.1", 0)
  let resp3 = runServerClient(listener3, handler,
    "GET /missing.js HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  assert extractStatusCode(resp3) == 404, "Expected 404 for missing.js, got " & $extractStatusCode(resp3)
  listener3.close()

  removeFile(tmpDir / "index.html")
  removeFile(tmpDir / "style.css")
  removeDir(tmpDir)
  echo "PASS: SPA fallback for static files"

# ============================================================
# Test 39: Trailing slash normalization (redirect)
# ============================================================
block testTrailingSlashRedirect:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    trailingSlash redirect

    get "/about":
      respond 200, "about page"

  # Request with trailing slash -> 301 redirect
  let resp1 = runServerClient(listener, handler,
    "GET /about/ HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  assert extractStatusCode(resp1) == 301, "Expected 301, got " & $extractStatusCode(resp1)
  assert extractHeader(resp1, "Location") == "/about", "Location: " & extractHeader(resp1, "Location")
  listener.close()

  # Request without trailing slash -> 200
  let listener2 = tcpListen("127.0.0.1", 0)
  let resp2 = runServerClient(listener2, handler,
    "GET /about HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  assert extractStatusCode(resp2) == 200
  listener2.close()
  echo "PASS: Trailing slash normalization (redirect)"

# ============================================================
# Test 40: Trailing slash normalization (strip)
# ============================================================
block testTrailingSlashStrip:
  let listener = tcpListen("127.0.0.1", 0)

  let handler = router:
    trailingSlash strip

    get "/about":
      respond 200, "about page"

  # Request with trailing slash -> served silently (200)
  let response = runServerClient(listener, handler,
    "GET /about/ HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  assert extractStatusCode(response) == 200, "Expected 200, got " & $extractStatusCode(response)
  assert extractBody(response) == "about page"
  listener.close()
  echo "PASS: Trailing slash normalization (strip)"

# ============================================================
# Test 41: clientIp() DSL sugar
# ============================================================
block testClientIp:
  let handler = router:
    get "/ip":
      respond 200, clientIp()
  let client = newTestClient(handler)

  # Without trusted_proxy context, forwarded headers are not trusted.
  # Test client has no remoteAddr, so all cases return "unknown".
  var resp = client.runRequest("GET", "/ip", "", @[("X-Forwarded-For", "1.2.3.4, 5.6.7.8")])
  assert resp.statusCode == 200
  assert resp.body == "unknown", "Got: " & resp.body

  resp = client.runRequest("GET", "/ip", "", @[("X-Real-IP", "10.0.0.1")])
  assert resp.statusCode == 200
  assert resp.body == "unknown"

  resp = client.runRequest("GET", "/ip")
  assert resp.statusCode == 200
  assert resp.body == "unknown"
  echo "PASS: clientIp() DSL sugar"

# ============================================================
# Test 42: bearerToken() DSL sugar
# ============================================================
block testBearerToken:
  let handler = router:
    get "/auth":
      let token = bearerToken()
      if token.len > 0:
        respond 200, "token:" & token
      else:
        respond 401, "no token"
  let client = newTestClient(handler)

  var resp = client.runRequest("GET", "/auth", "", @[("Authorization", "Bearer abc123")])
  assert resp.statusCode == 200
  assert resp.body == "token:abc123"

  resp = client.runRequest("GET", "/auth")
  assert resp.statusCode == 401
  assert resp.body == "no token"
  echo "PASS: bearerToken() DSL sugar"

# ============================================================
# Test 43: basicAuth() DSL sugar
# ============================================================
block testBasicAuth:
  let handler = router:
    get "/login":
      let creds = basicAuth()
      if creds[0].len > 0:
        respond 200, creds[0] & ":" & creds[1]
      else:
        respond 401, "unauthorized"
  let client = newTestClient(handler)

  let encoded = base64.encode("admin:secret")
  var resp = client.runRequest("GET", "/login", "", @[("Authorization", "Basic " & encoded)])
  assert resp.statusCode == 200
  assert resp.body == "admin:secret", "Got: " & resp.body

  resp = client.runRequest("GET", "/login")
  assert resp.statusCode == 401
  echo "PASS: basicAuth() DSL sugar"

# ============================================================
# Test 44: escapeHtml() utility
# ============================================================
block testEscapeHtml:
  let handler = router:
    post "/escape":
      respond 200, escapeHtml(body())
  let client = newTestClient(handler)
  let resp = client.runRequest("POST", "/escape", "<script>alert('xss')</script>")
  assert resp.statusCode == 200
  assert resp.body == "&lt;script&gt;alert(&#x27;xss&#x27;)&lt;/script&gt;", "Got: " & resp.body
  echo "PASS: escapeHtml() utility"

# ============================================================
# Test 45: pass (next-route) control flow
# ============================================================
block testPass:
  let handler = router:
    get "/data":
      let fmt = queryParam("format")
      if fmt != "json":
        pass()
      json 200, """{"result":"ok"}"""
    get "/data":
      respond 200, "plain data"
  let client = newTestClient(handler)

  # format=json -> first route handles
  var resp = client.runRequest("GET", "/data?format=json")
  assert resp.statusCode == 200
  assert resp.body == """{"result":"ok"}""", "Got: " & resp.body

  # no format -> pass to second route
  resp = client.runRequest("GET", "/data")
  assert resp.statusCode == 200
  assert resp.body == "plain data", "Got: " & resp.body
  echo "PASS: pass (next-route) control flow"

# ============================================================
# Test 46: halt shorthand
# ============================================================
block testHalt:
  let handler = router:
    get "/halt0":
      halt()
    get "/halt1":
      halt 403
    get "/halt2":
      halt 418, "I'm a teapot"
  let client = newTestClient(handler)

  var resp = client.runRequest("GET", "/halt0")
  assert resp.statusCode == 200

  resp = client.runRequest("GET", "/halt1")
  assert resp.statusCode == 403
  assert resp.body == ""

  resp = client.runRequest("GET", "/halt2")
  assert resp.statusCode == 418
  assert resp.body == "I'm a teapot"
  echo "PASS: halt shorthand"

# ============================================================
# Test 47: ETag helper
# ============================================================
block testEtag:
  let handler = router:
    get "/resource":
      etag "\"v1\""
      respond 200, "resource content"
  let client = newTestClient(handler)

  # Without If-None-Match -> 200 with ETag header
  var resp = client.runRequest("GET", "/resource")
  assert resp.statusCode == 200
  assert resp.body == "resource content"
  # Check ETag header is set
  var foundEtag = false
  for (k, v) in resp.headers:
    if k.toLowerAscii == "etag" and v == "\"v1\"":
      foundEtag = true
  assert foundEtag, "ETag header not found"

  # With matching If-None-Match -> 304
  resp = client.runRequest("GET", "/resource", "", @[("If-None-Match", "\"v1\"")])
  assert resp.statusCode == 304, "Expected 304, got " & $resp.statusCode
  assert resp.body == ""
  echo "PASS: ETag helper"

# ============================================================
# Test 48: cacheControl and noCache helpers
# ============================================================
block testCacheControl:
  let handler = router:
    get "/cached":
      cacheControl "public, max-age=3600"
      respond 200, "cached"
    get "/nocache":
      noCache()
      respond 200, "fresh"
  let client = newTestClient(handler)

  var resp = client.runRequest("GET", "/cached")
  assert resp.statusCode == 200
  var foundCC = false
  for (k, v) in resp.headers:
    if k == "Cache-Control" and v == "public, max-age=3600":
      foundCC = true
  assert foundCC, "Cache-Control header not found"

  resp = client.runRequest("GET", "/nocache")
  assert resp.statusCode == 200
  var foundNoCache = false
  for (k, v) in resp.headers:
    if k == "Cache-Control" and "no-store" in v:
      foundNoCache = true
  assert foundNoCache, "noCache header not found"
  echo "PASS: cacheControl and noCache helpers"

# ============================================================
# Test 49: Typed query params
# ============================================================
block testTypedQueryParams:
  let handler = router:
    get "/page":
      let page = queryParam[int]("page", "1")
      let lat = queryParam[float]("lat", "0.0")
      let active = queryParam[bool]("active", "false")
      respond 200, $page & "|" & $lat & "|" & $active
  let client = newTestClient(handler)

  var resp = client.runRequest("GET", "/page?page=5&lat=37.7&active=true")
  assert resp.statusCode == 200
  assert resp.body == "5|37.7|true", "Got: " & resp.body

  # Defaults
  resp = client.runRequest("GET", "/page")
  assert resp.statusCode == 200
  assert resp.body == "1|0.0|false", "Got: " & resp.body
  echo "PASS: Typed query params"

# ============================================================
# Test 49b: Typed query params reject invalid/missing inputs with 400
# ============================================================
block testTypedQueryParamErrors:
  let handler = router:
    get "/strict":
      let page = queryParam[int]("page")
      let enabled = queryParam[bool]("enabled", false)
      respond 200, $page & "|" & $enabled
  let client = newTestClient(handler)

  var resp = client.runRequest("GET", "/strict")
  assert resp.statusCode == 400, "Expected missing param to be 400, got " & $resp.statusCode
  assert "Missing query parameter" in resp.body, "Body: " & resp.body

  resp = client.runRequest("GET", "/strict?page=nope")
  assert resp.statusCode == 400, "Expected invalid int to be 400, got " & $resp.statusCode
  assert "Invalid query parameter" in resp.body, "Body: " & resp.body

  resp = client.runRequest("GET", "/strict?page=2&enabled=notabool")
  assert resp.statusCode == 400, "Expected invalid bool to be 400, got " & $resp.statusCode
  assert "Invalid query parameter" in resp.body, "Body: " & resp.body
  echo "PASS: Typed query param 400 rejections"

# ============================================================
# Test 50: jsonAs(MyType) typed JSON body parsing
# ============================================================
block testJsonAs:
  type UserReq = object
    name: string
    age: int

  let handler = router:
    post "/user":
      let user = jsonAs(UserReq)
      respond 200, user.name & " is " & $user.age
  let client = newTestClient(handler)

  let resp = client.runRequest("POST", "/user", """{"name":"Alice","age":30}""",
    @[("Content-Type", "application/json")])
  assert resp.statusCode == 200
  assert resp.body == "Alice is 30", "Got: " & resp.body
  echo "PASS: jsonAs(MyType) typed JSON body"

# ============================================================
# Test 51: Content negotiation accept: block
# ============================================================
block testAcceptBlock:
  let handler = router:
    get "/data":
      accept:
        "application/json":
          json 200, """{"v":"json"}"""
        "text/html":
          html 200, "<p>html</p>"
        "text/plain":
          text 200, "plain"
  let client = newTestClient(handler)

  var resp = client.runRequest("GET", "/data", "", @[("Accept", "application/json")])
  assert resp.statusCode == 200
  assert resp.body == """{"v":"json"}""", "Got: " & resp.body

  resp = client.runRequest("GET", "/data", "", @[("Accept", "text/html")])
  assert resp.statusCode == 200
  assert resp.body == "<p>html</p>"

  resp = client.runRequest("GET", "/data", "", @[("Accept", "text/plain")])
  assert resp.statusCode == 200
  assert resp.body == "plain"

  # Missing Accept header -> use first declared branch
  resp = client.runRequest("GET", "/data")
  assert resp.statusCode == 200
  assert resp.body == """{"v":"json"}"""

  # q-value preference should win over declaration order
  resp = client.runRequest("GET", "/data", "", @[("Accept", "text/html;q=0.9, application/json;q=0.1")])
  assert resp.statusCode == 200
  assert resp.body == "<p>html</p>"

  # Wildcard media type should match
  resp = client.runRequest("GET", "/data", "", @[("Accept", "text/*")])
  assert resp.statusCode == 200
  assert resp.body == "<p>html</p>"

  # Unknown accept -> 406
  resp = client.runRequest("GET", "/data", "", @[("Accept", "image/png")])
  assert resp.statusCode == 406
  echo "PASS: Content negotiation accept: block"

# ============================================================
# Test 52: Multi-method route registration
# ============================================================
block testMultiMethodRoute:
  let handler = router:
    route ["GET", "POST"], "/resource":
      respond 200, req.meth & " resource"
  let client = newTestClient(handler)

  var resp = client.runRequest("GET", "/resource")
  assert resp.statusCode == 200
  assert resp.body == "GET resource", "Got: " & resp.body

  resp = client.runRequest("POST", "/resource")
  assert resp.statusCode == 200
  assert resp.body == "POST resource"

  # PUT should 405 (method not allowed for an existing path)
  resp = client.runRequest("PUT", "/resource")
  assert resp.statusCode == 405
  let allow = resp.getResponseHeader("Allow")
  assert "GET" in allow
  assert "POST" in allow
  echo "PASS: Multi-method route registration"

# ============================================================
# Test 53: healthCheck DSL keyword
# ============================================================
block testHealthCheck:
  let handler = router:
    healthCheck "/health"
    healthCheck "/ready", "READY"
    get "/":
      respond 200, "home"
  let client = newTestClient(handler)

  var resp = client.runRequest("GET", "/health")
  assert resp.statusCode == 200
  assert resp.body == "OK"

  resp = client.runRequest("GET", "/ready")
  assert resp.statusCode == 200
  assert resp.body == "READY"
  echo "PASS: healthCheck DSL keyword"

# ============================================================
# Test 54: maxBodySize middleware
# ============================================================
block testMaxBodySize:
  let handler = router:
    maxBodySize 100
    post "/upload":
      respond 200, "ok"
  let client = newTestClient(handler)

  # Small body -> ok
  var resp = client.runRequest("POST", "/upload", "small")
  assert resp.statusCode == 200

  # Large body -> 413
  resp = client.runRequest("POST", "/upload", "x".repeat(200))
  assert resp.statusCode == 413, "Expected 413, got " & $resp.statusCode
  echo "PASS: maxBodySize middleware"

# ============================================================
# Test 55: Method override
# ============================================================
block testMethodOverride:
  let handler = router:
    methodOverride()
    put "/resource":
      respond 200, "updated"
    delete "/resource":
      respond 200, "deleted"
  let client = newTestClient(handler)

  # Via header
  var resp = client.runRequest("POST", "/resource", "",
    @[("X-HTTP-Method-Override", "PUT")])
  assert resp.statusCode == 200
  assert resp.body == "updated", "Got: " & resp.body

  # Via form body
  resp = client.runRequest("POST", "/resource", "_method=DELETE",
    @[("Content-Type", "application/x-www-form-urlencoded")])
  assert resp.statusCode == 200
  assert resp.body == "deleted"
  echo "PASS: Method override"

# ============================================================
# Test 56: Multipart upload() and uploads()
# ============================================================
block testMultipartUpload:
  let handler = router:
    post "/upload":
      let file = upload("file")
      if file.filename.len > 0:
        respond 200, file.filename & ":" & $file.size
      else:
        respond 400, "no file"
  let client = newTestClient(handler)

  let boundary = "----TestBoundary123"
  let multipartBody = "--" & boundary & "\r\n" &
    "Content-Disposition: form-data; name=\"file\"; filename=\"test.txt\"\r\n" &
    "Content-Type: text/plain\r\n\r\n" &
    "hello world\r\n" &
    "--" & boundary & "--\r\n"

  let resp = client.runRequest("POST", "/upload", multipartBody,
    @[("Content-Type", "multipart/form-data; boundary=" & boundary)])
  assert resp.statusCode == 200
  assert resp.body == "test.txt:11", "Got: " & resp.body
  echo "PASS: Multipart upload()"

# ============================================================
# Test 57: Multipart formField()
# ============================================================
block testMultipartFormField:
  let handler = router:
    post "/form":
      let name = formField("username")
      respond 200, "hello " & name
  let client = newTestClient(handler)

  let boundary = "----TestBoundary456"
  let multipartBody = "--" & boundary & "\r\n" &
    "Content-Disposition: form-data; name=\"username\"\r\n\r\n" &
    "alice\r\n" &
    "--" & boundary & "--\r\n"

  let resp = client.runRequest("POST", "/form", multipartBody,
    @[("Content-Type", "multipart/form-data; boundary=" & boundary)])
  assert resp.statusCode == 200
  assert resp.body == "hello alice", "Got: " & resp.body
  echo "PASS: Multipart formField()"

# ============================================================
# Test 58: Typed path params (int constraint)
# ============================================================
block testTypedPathInt:
  let handler = router:
    get "/users/{id:int}":
      respond 200, "user:" & pathParams["id"]
  let client = newTestClient(handler)

  var resp = client.runRequest("GET", "/users/42")
  assert resp.statusCode == 200
  assert resp.body == "user:42"

  # Non-integer should 404
  resp = client.runRequest("GET", "/users/abc")
  assert resp.statusCode == 404, "Expected 404 for non-int, got " & $resp.statusCode
  echo "PASS: Typed path params (int)"

# ============================================================
# Test 59: Typed path params (uuid constraint)
# ============================================================
block testTypedPathUuid:
  let handler = router:
    get "/items/{id:uuid}":
      respond 200, "item:" & pathParams["id"]
  let client = newTestClient(handler)

  var resp = client.runRequest("GET", "/items/550e8400-e29b-41d4-a716-446655440000")
  assert resp.statusCode == 200

  # Invalid UUID should 404
  resp = client.runRequest("GET", "/items/not-a-uuid")
  assert resp.statusCode == 404
  echo "PASS: Typed path params (uuid)"

# ============================================================
# Test 60: Optional path segments
# ============================================================
block testOptionalPathSegment:
  let handler = router:
    get "/posts/{format?}":
      let fmt = pathParams.getOrDefault("format", "html")
      respond 200, "format:" & fmt
  let client = newTestClient(handler)

  var resp = client.runRequest("GET", "/posts/json")
  assert resp.statusCode == 200
  assert resp.body == "format:json"

  # Without optional segment
  resp = client.runRequest("GET", "/posts")
  assert resp.statusCode == 200
  assert resp.body == "format:html", "Got: " & resp.body
  echo "PASS: Optional path segments"

# ============================================================
# Test 61: HEAD auto-generation
# ============================================================
block testHeadAutoGen:
  let handler = router:
    get "/resource":
      respond 200, "hello world"
  let client = newTestClient(handler)

  let resp = client.runRequest("HEAD", "/resource")
  assert resp.statusCode == 200
  assert resp.body == "", "HEAD should have empty body, got: " & resp.body
  var foundCL = false
  for (k, v) in resp.headers:
    if k == "Content-Length" and v == "11":
      foundCL = true
  assert foundCL, "Content-Length should be 11 for HEAD"
  echo "PASS: HEAD auto-generation"

# ============================================================
# Test 62: OPTIONS auto-generation
# ============================================================
block testOptionsAutoGen:
  let handler = router:
    get "/res":
      respond 200, "get"
    post "/res":
      respond 200, "post"
    put "/res":
      respond 200, "put"
  let client = newTestClient(handler)

  let resp = client.runRequest("OPTIONS", "/res")
  assert resp.statusCode == 204
  var foundAllow = false
  for (k, v) in resp.headers:
    if k == "Allow":
      foundAllow = true
      assert "GET" in v, "Allow should include GET"
      assert "POST" in v, "Allow should include POST"
      assert "PUT" in v, "Allow should include PUT"
  assert foundAllow, "Allow header not found"
  echo "PASS: OPTIONS auto-generation"

# ============================================================
# Test 63: URL decoding in path params
# ============================================================
block testUrlDecoding:
  let handler = router:
    get "/search/{query}":
      respond 200, pathParams["query"]
  let client = newTestClient(handler)

  let resp = client.runRequest("GET", "/search/hello%20world")
  assert resp.statusCode == 200
  assert resp.body == "hello world", "Got: " & resp.body
  echo "PASS: URL decoding in path params"

# ============================================================
# Test 64: URL decoding in query params
# ============================================================
block testUrlDecodingQuery:
  let handler = router:
    get "/search":
      respond 200, queryParam("q")
  let client = newTestClient(handler)

  let resp = client.runRequest("GET", "/search?q=hello%20world%26more")
  assert resp.statusCode == 200
  assert resp.body == "hello world&more", "Got: " & resp.body
  echo "PASS: URL decoding in query params"

# ============================================================
# Test 65: onError handler
# ============================================================
block testOnError:
  let handler = router:
    onError:
      respond 500, "Error: " & errorMessage()

    get "/crash":
      raise newException(ValueError, "boom")
  let client = newTestClient(handler)

  let resp = client.runRequest("GET", "/crash")
  assert resp.statusCode == 500
  assert resp.body == "Error: boom", "Got: " & resp.body
  echo "PASS: onError handler"

# ============================================================
# Test 66: Named routes and urlFor
# ============================================================
block testNamedRoutes:
  # We need to access the router directly for urlFor
  var routes: seq[RouteEntry]
  var globalMiddlewares: seq[Middleware]
  var beforeMiddlewares: seq[Middleware]
  var afterMiddlewares: seq[Middleware]

  let handler = router:
    get "/users/{id}", name = "user_detail":
      respond 200, "user"

  # Test through raw route matching — urlFor needs a Router object.
  # Build a Router directly to test urlFor.
  let r = Router(
    routes: @[RouteEntry(
      meth: "GET",
      segments: parsePath("/users/{id}"),
      handler: proc(req: HttpRequest, pp: Table[string, string],
                    qp: Table[string, string]): CpsFuture[HttpResponseBuilder] {.closure.} =
        let fut = newCpsFuture[HttpResponseBuilder]()
        fut.complete(newResponse(200, "user"))
        return fut,
      name: "user_detail"
    )]
  )
  let url = r.urlFor("user_detail", {"id": "42"}.toTable)
  assert url == "/users/42", "Got: " & url
  echo "PASS: Named routes and urlFor"

# ============================================================
# Test 67: Route listing
# ============================================================
block testRouteList:
  let r = Router(
    routes: @[
      RouteEntry(meth: "GET", segments: parsePath("/"), handler: nil),
      RouteEntry(meth: "POST", segments: parsePath("/users"), handler: nil),
      RouteEntry(meth: "*", segments: parsePath("/api/*"), handler: nil, name: "api")
    ]
  )
  let listing = r.listRoutes()
  assert "GET\t/" in listing
  assert "POST\t/users" in listing
  assert "ANY\t/api/*" in listing
  assert "[api]" in listing
  echo "PASS: Route listing"

# ============================================================
# Test 68: pathParam[int]("id") typed extraction
# ============================================================
block testPathParamTyped:
  let handler = router:
    get "/items/{id:int}":
      let id = pathParam[int]("id")
      respond 200, "id=" & $(id * 2)
  let client = newTestClient(handler)

  let resp = client.runRequest("GET", "/items/21")
  assert resp.statusCode == 200
  assert resp.body == "id=42", "Got: " & resp.body
  echo "PASS: pathParam[int] typed extraction"

# ============================================================
# Test 68a: pathParam[int] invalid input returns 400
# ============================================================
block testPathParamTypedError:
  let handler = router:
    get "/items/{id}":
      let id = pathParam[int]("id")
      respond 200, "id=" & $id
  let client = newTestClient(handler)

  let resp = client.runRequest("GET", "/items/notanint")
  assert resp.statusCode == 400, "Expected 400 for invalid path int, got " & $resp.statusCode
  assert "Invalid path parameter" in resp.body, "Body: " & resp.body
  echo "PASS: pathParam[int] invalid input -> 400"

# ============================================================
# Test 68aa: ergonomic pathInt/queryInt/queryBool helpers
# ============================================================
block testErgonomicTypedHelpers:
  let handler = router:
    get "/calc/{id}":
      let id = pathInt("id")
      let mult = queryInt("m", 2)
      let boost = queryBool("boost", false)
      let resultVal = if boost: (id * mult) + 1 else: id * mult
      respond 200, $resultVal
  let client = newTestClient(handler)

  var resp = client.runRequest("GET", "/calc/10")
  assert resp.statusCode == 200
  assert resp.body == "20", "Got: " & resp.body

  resp = client.runRequest("GET", "/calc/10?m=3&boost=true")
  assert resp.statusCode == 200
  assert resp.body == "31", "Got: " & resp.body
  echo "PASS: ergonomic typed helper keywords"

# ============================================================
# Test 68b: appState directive + state[T]() helper
# ============================================================
block testAppStateTyped:
  # state[T]() requires `ref object of RootObj` so it can be stored as RootRef.
  type AppState = ref object of RootObj
    prefix: string

  let stateRef = AppState(prefix: "ok")
  let handler = router:
    appState stateRef
    get "/state":
      let st = state[AppState]()
      respond 200, st.prefix
  let client = newTestClient(handler)

  let resp = client.runRequest("GET", "/state")
  assert resp.statusCode == 200
  assert resp.body == "ok"
  echo "PASS: appState + state[T]()"

# ============================================================
# Test 69: any route
# ============================================================
block testAnyRoute:
  let handler = router:
    any "/catch-all":
      respond 200, req.meth & " caught"
  let client = newTestClient(handler)

  var resp = client.runRequest("GET", "/catch-all")
  assert resp.statusCode == 200
  assert resp.body == "GET caught"

  resp = client.runRequest("DELETE", "/catch-all")
  assert resp.statusCode == 200
  assert resp.body == "DELETE caught"
  echo "PASS: any route"

# ============================================================
# Test 70: Alpha and alnum path constraints
# ============================================================
block testAlphaAlnumConstraints:
  let handler = router:
    get "/tags/{slug:alpha}":
      respond 200, "tag:" & pathParams["slug"]
    get "/codes/{code:alnum}":
      respond 200, "code:" & pathParams["code"]
  let client = newTestClient(handler)

  var resp = client.runRequest("GET", "/tags/hello")
  assert resp.statusCode == 200
  assert resp.body == "tag:hello"

  # alpha should reject digits
  resp = client.runRequest("GET", "/tags/abc123")
  assert resp.statusCode == 404

  # alnum accepts letters+digits
  resp = client.runRequest("GET", "/codes/abc123")
  assert resp.statusCode == 200
  assert resp.body == "code:abc123"

  # alnum rejects special chars
  resp = client.runRequest("GET", "/codes/abc-123")
  assert resp.statusCode == 404
  echo "PASS: Alpha and alnum path constraints"

# ============================================================
# Test 71: bodySizeLimitMiddleware via raw HTTP
# ============================================================
block testBodySizeLimitRaw:
  let listener = tcpListen("127.0.0.1", 0)
  let handler = router:
    maxBodySize 50
    post "/data":
      respond 200, "ok"

  # Send request with Content-Length > 50
  let response = runServerClient(listener, handler,
    "POST /data HTTP/1.1\r\nHost: localhost\r\nContent-Length: 100\r\nConnection: close\r\n\r\n" & "x".repeat(100))
  assert extractStatusCode(response) == 413, "Expected 413, got " & $extractStatusCode(response)
  listener.close()
  echo "PASS: bodySizeLimitMiddleware via raw HTTP"

# ============================================================
# Test 72: Security headers middleware
# ============================================================
block testSecurityHeaders:
  let handler = router:
    secure
    get "/":
      respond 200, "hi"
  let client = newTestClient(handler)

  let resp = client.runRequest("GET", "/")
  assert resp.statusCode == 200
  var foundHSTS = false
  var foundXCTO = false
  var foundXFO = false
  for (k, v) in resp.headers:
    if k == "Strict-Transport-Security":
      foundHSTS = true
    if k == "X-Content-Type-Options" and v == "nosniff":
      foundXCTO = true
    if k == "X-Frame-Options" and v == "DENY":
      foundXFO = true
  assert foundHSTS, "HSTS header missing"
  assert foundXCTO, "X-Content-Type-Options missing"
  assert foundXFO, "X-Frame-Options missing"
  echo "PASS: Security headers middleware"

# ============================================================
# Test 73: Request ID middleware
# ============================================================
block testRequestId:
  let handler = router:
    requestId
    get "/":
      respond 200, "hi"
  let client = newTestClient(handler)

  let resp = client.runRequest("GET", "/")
  assert resp.statusCode == 200
  var foundReqId = false
  for (k, v) in resp.headers:
    if k == "X-Request-ID" and v.len > 0:
      foundReqId = true
  assert foundReqId, "X-Request-ID header missing"
  echo "PASS: Request ID middleware"

# ============================================================
# Test 74: CORS middleware (full config)
# ============================================================
block testCorsFullConfig:
  let handler = router:
    cors:
      origins "https://example.com"
      methods "GET", "POST"
      credentials true
      maxAge 3600

    get "/api":
      respond 200, "data"

    # Explicit OPTIONS route so CORS middleware can handle preflight
    options "/api":
      respond 204, ""
  let client = newTestClient(handler)

  # Preflight
  var resp = client.runRequest("OPTIONS", "/api", "",
    @[("Origin", "https://example.com"),
      ("Access-Control-Request-Method", "POST")])
  assert resp.statusCode == 204
  var foundAllowOrigin = false
  for (k, v) in resp.headers:
    if k == "Access-Control-Allow-Origin" and v == "https://example.com":
      foundAllowOrigin = true
  assert foundAllowOrigin, "Allow-Origin not found"

  # Normal request with matching origin
  resp = client.runRequest("GET", "/api", "",
    @[("Origin", "https://example.com")])
  assert resp.statusCode == 200
  foundAllowOrigin = false
  for (k, v) in resp.headers:
    if k == "Access-Control-Allow-Origin":
      foundAllowOrigin = true
  assert foundAllowOrigin, "CORS origin not added to response"

  # Request from non-allowed origin -> no CORS headers, passes through
  resp = client.runRequest("GET", "/api", "",
    @[("Origin", "https://evil.com")])
  assert resp.statusCode == 200
  echo "PASS: CORS middleware (full config)"

# ============================================================
# Test 75: before hook
# ============================================================
block testBeforeHook:
  let handler = router:
    before:
      if header("x-api-key") != "secret":
        respond 401, "Unauthorized"

    get "/protected":
      respond 200, "secret data"
  let client = newTestClient(handler)

  # Without API key -> 401
  var resp = client.runRequest("GET", "/protected")
  assert resp.statusCode == 401
  assert resp.body == "Unauthorized"

  # With API key -> 200
  resp = client.runRequest("GET", "/protected", "", @[("X-API-Key", "secret")])
  assert resp.statusCode == 200
  assert resp.body == "secret data"
  echo "PASS: before hook"

# ============================================================
# Test 76: after hook
# ============================================================
block testAfterHook:
  let listener = tcpListen("127.0.0.1", 0)
  let handler = router:
    after:
      discard  # just ensure after doesn't break anything

    get "/":
      respond 200, "hello"

  let response = runServerClient(listener, handler,
    "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
  assert extractStatusCode(response) == 200
  assert extractBody(response) == "hello"
  listener.close()
  echo "PASS: after hook"

# ============================================================
# Test 77: Sub-router mounting
# ============================================================
block testSubRouterMount:
  let apiRouter = Router(routes: @[
    RouteEntry(
      meth: "GET",
      segments: parsePath("/users"),
      handler: proc(req: HttpRequest, pp: Table[string, string],
                    qp: Table[string, string]): CpsFuture[HttpResponseBuilder] {.closure.} =
        let fut = newCpsFuture[HttpResponseBuilder]()
        fut.complete(newResponse(200, "api users"))
        return fut
    )
  ])

  var parentRouter = Router()
  mountRouter(parentRouter, "/api", apiRouter)
  let handler = toHandler(parentRouter)
  let client = newTestClient(handler)

  let resp = client.runRequest("GET", "/api/users")
  assert resp.statusCode == 200
  assert resp.body == "api users", "Got: " & resp.body
  echo "PASS: Sub-router mounting"

# ============================================================
# Test 77b: DSL mount inherits parent middleware
# ============================================================
block testDslMountInheritsMiddleware:
  let child = router:
    get "/users":
      respond 200, "api users"

  let handler = router:
    use proc(req: HttpRequest, next: HttpHandler): CpsFuture[HttpResponseBuilder] {.closure.} =
      let fut = next(req)
      let outFut = newCpsFuture[HttpResponseBuilder]()
      fut.addCallback(proc() =
        if fut.hasError():
          outFut.fail(fut.getError())
        else:
          var resp = fut.read()
          resp.headers.add ("X-MW", "on")
          outFut.complete(resp)
      )
      outFut
    mount "/api", child

  let client = newTestClient(handler)
  let resp = client.runRequest("GET", "/api/users")
  assert resp.statusCode == 200
  assert resp.body == "api users"
  assert resp.getResponseHeader("x-mw") == "on"
  echo "PASS: DSL mount inherits middleware"

# ============================================================
# Test 78: Form body parsing (URL-encoded)
# ============================================================
block testFormBodyParsing:
  let handler = router:
    post "/form":
      let name = formParam("name")
      let email = formParam("email", "none")
      respond 200, name & "|" & email
  let client = newTestClient(handler)

  var resp = client.runRequest("POST", "/form", "name=alice&email=a%40b.com",
    @[("Content-Type", "application/x-www-form-urlencoded")])
  assert resp.statusCode == 200
  assert resp.body == "alice|a@b.com", "Got: " & resp.body

  # Missing email -> default
  resp = client.runRequest("POST", "/form", "name=bob")
  assert resp.statusCode == 200
  assert resp.body == "bob|none"
  echo "PASS: Form body parsing (URL-encoded)"

# ============================================================
# Test 79: TestClient assertion helpers
# ============================================================
block testClientAssertions:
  let handler = router:
    get "/":
      json 200, """{"ok":true}"""
  let client = newTestClient(handler)

  let resp = client.runRequest("GET", "/")
  resp.assertStatus(200)
  resp.assertBodyContains("ok")
  resp.assertHeader("Content-Type", "application/json")
  resp.assertJsonBody(%*{"ok": true})
  echo "PASS: TestClient assertion helpers"

# ============================================================
# Test 80: Multiple uploads
# ============================================================
block testMultipleUploads:
  let handler = router:
    post "/multi":
      let files = uploads("file")
      respond 200, $files.len & " files"
  let client = newTestClient(handler)

  let boundary = "----Multi789"
  let multipartBody = "--" & boundary & "\r\n" &
    "Content-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n" &
    "Content-Type: text/plain\r\n\r\n" &
    "file1\r\n" &
    "--" & boundary & "\r\n" &
    "Content-Disposition: form-data; name=\"file\"; filename=\"b.txt\"\r\n" &
    "Content-Type: text/plain\r\n\r\n" &
    "file2\r\n" &
    "--" & boundary & "--\r\n"

  let resp = client.runRequest("POST", "/multi", multipartBody,
    @[("Content-Type", "multipart/form-data; boundary=" & boundary)])
  assert resp.statusCode == 200
  assert resp.body == "2 files", "Got: " & resp.body
  echo "PASS: Multiple uploads"

# ========================================================
# Tests 81-86: Template Engine, Streaming, OpenAPI
# ========================================================

echo ""
echo "--- Tests 81-86: Template Engine, Streaming, OpenAPI ---"

# Test 81: Template engine hook with render keyword
block testTemplateRenderer:
  # Define a simple template renderer
  let myRenderer: TemplateRenderer = proc(name: string, vars: JsonNode): string =
    if name == "hello.html":
      let userName = if vars.hasKey("user"): vars["user"].getStr() else: "World"
      return "<h1>Hello, " & userName & "!</h1>"
    elif name == "page.html":
      return "<html><body>Page content</body></html>"
    else:
      return "<p>Unknown template: " & name & "</p>"

  setTemplateRenderer(myRenderer)

  let handler = router:
    renderer myRenderer
    get "/hello":
      render "hello.html"
    get "/greet/{name}":
      let userName = pathParams["name"]
      render "hello.html", %*{"user": userName}
    get "/page":
      render "page.html"

  let client = newTestClient(handler)

  let resp1 = client.runRequest("GET", "/hello")
  assert resp1.statusCode == 200
  assert resp1.body == "<h1>Hello, World!</h1>", "Got: " & resp1.body
  assert resp1.getResponseHeader("content-type").contains("text/html")

  let resp2 = client.runRequest("GET", "/greet/Alice")
  assert resp2.statusCode == 200
  assert resp2.body == "<h1>Hello, Alice!</h1>", "Got: " & resp2.body

  let resp3 = client.runRequest("GET", "/page")
  assert resp3.statusCode == 200
  assert resp3.body == "<html><body>Page content</body></html>"

  # Reset renderer
  setTemplateRenderer(nil)
  echo "PASS: Template engine render keyword"

# Test 82: Template engine with headers
block testTemplateWithHeaders:
  let myRenderer: TemplateRenderer = proc(name: string, vars: JsonNode): string =
    return "<p>Rendered</p>"

  let handler = router:
    renderer myRenderer
    get "/with-cookie":
      setCookie "session", "abc123"
      render "test.html"

  setTemplateRenderer(myRenderer)
  let client = newTestClient(handler)
  let resp = client.runRequest("GET", "/with-cookie")
  assert resp.statusCode == 200
  assert resp.body == "<p>Rendered</p>"
  assert resp.getResponseHeader("set-cookie").contains("session=abc123"), "Got: " & resp.getResponseHeader("set-cookie")
  setTemplateRenderer(nil)
  echo "PASS: Template engine with headers"

# Test 83: Chunked streaming response (via raw TCP)
block testChunkedStreaming:
  let handler = router:
    stream "/stream":
      await sendChunk("Hello ")
      await sendChunk("World")

  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)
  let config = HttpServerConfig()

  proc serverTask(l: TcpListener, cfg: HttpServerConfig,
                  h: HttpHandler): CpsVoidFuture {.cps.} =
    let client = await l.accept()
    await handleHttp1Connection(client.AsyncStream, cfg, h)

  discard serverTask(listener, config, handler)

  proc clientTask(p: int): CpsFuture[string] {.cps.} =
    let conn = await tcpConnect("127.0.0.1", p)
    let stream = conn.AsyncStream
    await stream.write("GET /stream HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    # Read the full chunked response by reading until connection closes
    var data = ""
    while true:
      let chunk: string = await stream.read(4096)
      if chunk.len == 0:
        break
      data &= chunk
    stream.close()
    return data

  let cf = clientTask(port)
  let loop = getEventLoop()
  for i in 0..200:
    loop.tick()
    if cf.finished:
      break

  assert cf.finished, "Client task did not complete"
  let rawResp = cf.read()
  # Verify response has chunked encoding
  assert rawResp.contains("Transfer-Encoding: chunked"), "Expected chunked encoding in: " & rawResp
  assert rawResp.contains("200 OK"), "Expected 200 OK in: " & rawResp
  # Verify we got the chunk data (the raw response will have hex sizes + data)
  assert rawResp.contains("Hello "), "Expected 'Hello ' in response"
  assert rawResp.contains("World"), "Expected 'World' in response"
  # Verify terminal chunk
  assert rawResp.contains("\r\n0\r\n"), "Expected terminal chunk"

  listener.close()
  echo "PASS: Chunked streaming response"

# Test 84: OpenAPI spec generation
block testOpenApiSpec:
  let handler = router:
    openapi:
      title "Test API"
      version "2.0.0"
      description "A test API"
    get "/users":
      summary "List all users"
      tag "users"
      respond 200, "[]"
    get "/users/{id:int}":
      summary "Get user by ID"
      tag "users"
      respond 200, "user"
    post "/users":
      summary "Create a user"
      tag "users"
      respond 201, "created"
    delete "/users/{id:int}":
      summary "Delete user"
      tag "users"
      deprecated
      respond 200, "deleted"

  let client = newTestClient(handler)
  let resp = client.runRequest("GET", "/openapi.json")
  assert resp.statusCode == 200
  assert resp.getResponseHeader("content-type") == "application/json"

  # Parse the JSON spec
  let spec = parseJson(resp.body)
  assert spec["openapi"].getStr() == "3.0.3"
  assert spec["info"]["title"].getStr() == "Test API"
  assert spec["info"]["version"].getStr() == "2.0.0"
  assert spec["info"]["description"].getStr() == "A test API"

  # Check paths exist
  assert spec["paths"].hasKey("/users")
  assert spec["paths"].hasKey("/users/{id}")

  # Check GET /users operation
  let getUsersOp = spec["paths"]["/users"]["get"]
  assert getUsersOp["summary"].getStr() == "List all users"
  assert getUsersOp["tags"][0].getStr() == "users"

  # Check GET /users/{id} with path param
  let getUserOp = spec["paths"]["/users/{id}"]["get"]
  assert getUserOp["summary"].getStr() == "Get user by ID"
  let params = getUserOp["parameters"]
  assert params.len == 1
  assert params[0]["name"].getStr() == "id"
  assert params[0]["in"].getStr() == "path"
  assert params[0]["schema"]["type"].getStr() == "integer"

  # Check DELETE /users/{id} is deprecated
  let deleteOp = spec["paths"]["/users/{id}"]["delete"]
  assert deleteOp["summary"].getStr() == "Delete user"
  assert deleteOp["deprecated"].getBool() == true

  echo "PASS: OpenAPI spec generation"

# Test 85: OpenAPI annotations are stripped from handler body
block testOpenApiAnnotationsStripped:
  # Ensure summary/tag/deprecated don't interfere with handler execution
  let handler = router:
    openapi:
      title "Annotation Test"
      version "1.0.0"
    get "/test":
      summary "Test endpoint"
      tag "testing"
      description "This is a test"
      respond 200, "it works"

  let client = newTestClient(handler)
  let resp = client.runRequest("GET", "/test")
  assert resp.statusCode == 200
  assert resp.body == "it works", "Got: " & resp.body
  echo "PASS: OpenAPI annotations stripped from handler body"

# Test 86: OpenAPI with route without annotations
block testOpenApiNoAnnotations:
  let handler = router:
    openapi:
      title "Minimal"
      version "0.1.0"
    get "/plain":
      respond 200, "hello"
    post "/submit":
      respond 201, "ok"

  let client = newTestClient(handler)
  let spec = parseJson(client.runRequest("GET", "/openapi.json").body)
  assert spec["paths"].hasKey("/plain")
  assert spec["paths"]["/plain"].hasKey("get")
  assert spec["paths"].hasKey("/submit")
  assert spec["paths"]["/submit"].hasKey("post")
  # Verify routes still work
  assert client.runRequest("GET", "/plain").body == "hello"
  assert client.runRequest("POST", "/submit").body == "ok"
  echo "PASS: OpenAPI with unannotated routes"

# ============================================================
# Test 87: rateLimit DSL keyword compiles and limits requests
# ============================================================
block testRateLimitDsl:
  let handler = router:
    rateLimit 1, 60
    get "/":
      respond 200, "ok"
  let client = newTestClient(handler)

  var resp = client.runRequest("GET", "/")
  assert resp.statusCode == 200
  resp = client.runRequest("GET", "/")
  assert resp.statusCode == 429
  echo "PASS: rateLimit DSL keyword"

# ============================================================
# Test 88: top-level middleware should not be duplicated
# ============================================================
block testRootMiddlewareNotDuplicated:
  var hits = 0
  let countMw: Middleware = proc(req: HttpRequest, next: HttpHandler): CpsFuture[HttpResponseBuilder] {.closure.} =
    inc hits
    return next(req)

  let handler = router:
    use countMw
    get "/":
      respond 200, "ok"

  let client = newTestClient(handler)
  let resp = client.runRequest("GET", "/")
  assert resp.statusCode == 200
  assert hits == 1
  echo "PASS: top-level middleware not duplicated"

# ============================================================
# Test 89: healthCheck respects group prefix and middleware
# ============================================================
block testHealthCheckPrefixAndMiddleware:
  let handler = router:
    requestId
    group "/api":
      healthCheck "/health"

  let client = newTestClient(handler)
  let resp = client.runRequest("GET", "/api/health")
  assert resp.statusCode == 200
  assert resp.body == "OK"
  assert resp.getResponseHeader("X-Request-ID").len > 0
  echo "PASS: healthCheck prefix + middleware inheritance"

# ============================================================
# Test 90: CORS wildcard + credentials reflects origin
# ============================================================
block testCorsWildcardCredentials:
  let handler = router:
    cors:
      origins "*"
      methods "GET", "POST"
      credentials true
      maxAge 60
    get "/api":
      respond 200, "ok"
    options "/api":
      respond 204, ""

  let client = newTestClient(handler)

  var resp = client.runRequest("OPTIONS", "/api", "",
    @[("Origin", "https://client.example"),
      ("Access-Control-Request-Method", "GET")])
  assert resp.statusCode == 204
  assert resp.getResponseHeader("Access-Control-Allow-Origin") == "https://client.example"
  assert resp.getResponseHeader("Access-Control-Allow-Credentials") == "true"
  assert resp.getResponseHeader("Vary") == "Origin"

  resp = client.runRequest("GET", "/api", "", @[("Origin", "https://client.example")])
  assert resp.statusCode == 200
  assert resp.getResponseHeader("Access-Control-Allow-Origin") == "https://client.example"
  assert resp.getResponseHeader("Access-Control-Allow-Credentials") == "true"
  assert resp.getResponseHeader("Vary") == "Origin"
  echo "PASS: CORS wildcard + credentials origin reflection"

# ============================================================
# Test 91: DSL internal names do not collide with user variables
# ============================================================
block testDslNameHygiene:
  let handler = router:
    get "/":
      let dslHeaders = "h"
      let dslFormParsed = "f"
      let dslJsonParsed = "j"
      let sseWriter = "s"
      let wsConn = "w"
      let streamWriter = "t"
      respond 200, dslHeaders & dslFormParsed & dslJsonParsed & sseWriter & wsConn & streamWriter

  let client = newTestClient(handler)
  let resp = client.runRequest("GET", "/")
  assert resp.statusCode == 200
  assert resp.body == "hfjswt"
  echo "PASS: DSL internal name hygiene"

# ============================================================
# Test 92: mount respects enclosing group prefix
# ============================================================
block testMountRespectsGroupPrefix:
  let child = router:
    get "/ping":
      respond 200, "pong"

  let handler = router:
    group "/api":
      mount "/v1", child

  let client = newTestClient(handler)
  var resp = client.runRequest("GET", "/api/v1/ping")
  assert resp.statusCode == 200
  assert resp.body == "pong"
  resp = client.runRequest("GET", "/v1/ping")
  assert resp.statusCode == 404
  echo "PASS: mount respects group prefix"

# ============================================================
# Test 93: route method list normalizes method names
# ============================================================
block testRouteMethodNormalization:
  let handler = router:
    route ["get", "post"], "/multi":
      respond 200, "ok"

  let client = newTestClient(handler)
  var resp = client.runRequest("GET", "/multi")
  assert resp.statusCode == 200
  resp = client.runRequest("POST", "/multi")
  assert resp.statusCode == 200
  echo "PASS: route method list normalization"

# ============================================================
# Test 94: renderer is isolated per router
# ============================================================
block testRendererIsolation:
  proc renderA(name: string, vars: JsonNode): string = "A:" & name
  proc renderB(name: string, vars: JsonNode): string = "B:" & name

  let handlerA = router:
    renderer renderA
    get "/":
      render "home"

  let handlerB = router:
    renderer renderB
    get "/":
      render "home"

  let clientA = newTestClient(handlerA)
  let clientB = newTestClient(handlerB)
  let a1 = clientA.runRequest("GET", "/")
  let b1 = clientB.runRequest("GET", "/")
  let a2 = clientA.runRequest("GET", "/")
  assert a1.body == "A:home"
  assert b1.body == "B:home"
  assert a2.body == "A:home"
  echo "PASS: renderer is router-scoped"

# ============================================================
# Test 95: OpenAPI route inherits global middleware by default
# ============================================================
block testOpenApiDefaultMiddleware:
  let handler = router:
    requestId
    openapi:
      title "Spec"
      version "1.0.0"
    get "/ok":
      respond 200, "ok"

  let client = newTestClient(handler)
  let resp = client.runRequest("GET", "/openapi.json")
  assert resp.statusCode == 200
  assert resp.getResponseHeader("X-Request-ID").len > 0
  echo "PASS: OpenAPI route inherits global middleware"

# ============================================================
# Test 96: OpenAPI can be explicitly public
# ============================================================
block testOpenApiPublic:
  let handler = router:
    requestId
    openapi:
      title "Public"
      version "1.0.0"
      public true
    get "/ok":
      respond 200, "ok"

  let client = newTestClient(handler)
  let resp = client.runRequest("GET", "/openapi.json")
  assert resp.statusCode == 200
  assert resp.getResponseHeader("X-Request-ID").len == 0
  echo "PASS: OpenAPI public option"

# ============================================================
# Test 97: OpenAPI public bypasses before/after hooks
# ============================================================
block testOpenApiPublicBypassesHooks:
  var beforeHits = 0
  var afterHits = 0

  let handler = router:
    before:
      inc beforeHits
      respond 401, "blocked"
    after:
      inc afterHits
    openapi:
      title "Public"
      version "1.0.0"
      public true
    get "/ok":
      respond 200, "ok"

  let client = newTestClient(handler)
  let resp = client.runRequest("GET", "/openapi.json")
  assert resp.statusCode == 200
  assert beforeHits == 0
  assert afterHits == 0
  echo "PASS: OpenAPI public bypasses before/after hooks"

# ============================================================
# Test 98: trailing slash redirect uses middleware chain
# ============================================================
block testTrailingSlashRedirectUsesMiddleware:
  let handler = router:
    requestId
    secure
    trailingSlash redirect
    get "/about":
      respond 200, "about"

  let client = newTestClient(handler)
  let resp = client.runRequest("GET", "/about/")
  assert resp.statusCode == 301
  assert resp.getResponseHeader("X-Request-ID").len > 0
  assert resp.getResponseHeader("X-Content-Type-Options") == "nosniff"
  echo "PASS: trailing slash redirect uses middleware chain"

# ============================================================
# Test 99: fallback responses run global middleware
# ============================================================
block testFallbackGlobalMiddleware:
  let handler = router:
    requestId
    secure
    get "/ok":
      respond 200, "ok"

  let client = newTestClient(handler)

  var resp = client.runRequest("GET", "/missing")
  assert resp.statusCode == 404
  assert resp.getResponseHeader("X-Request-ID").len > 0
  assert resp.getResponseHeader("X-Content-Type-Options") == "nosniff"

  resp = client.runRequest("OPTIONS", "/ok")
  assert resp.statusCode == 204
  assert resp.getResponseHeader("X-Request-ID").len > 0
  assert resp.getResponseHeader("X-Content-Type-Options") == "nosniff"
  echo "PASS: fallback responses run global middleware"

# ============================================================
# Test 100: notFound exceptions are handled by onError
# ============================================================
block testNotFoundErrorHandledByOnError:
  let handler = router:
    notFound:
      raise newException(ValueError, "boom from notFound")
    onError:
      respond 500, "handled: " & errorMessage()

  let client = newTestClient(handler)
  let resp = client.runRequest("GET", "/missing")
  assert resp.statusCode == 500
  assert resp.body == "handled: boom from notFound"
  echo "PASS: notFound exceptions go through onError"

# ============================================================
# Test 101: state[T]() type mismatch returns catchable error
# ============================================================
block testStateTypeMismatchIsCatchable:
  type
    GoodState = ref object of RootObj
      count: int
    OtherState = ref object of RootObj
      name: string

  let handler = router:
    appState GoodState(count: 1)
    get "/":
      let s = state[OtherState]()
      respond 200, s.name
    onError:
      respond 500, errorMessage()

  let client = newTestClient(handler)
  let resp = client.runRequest("GET", "/")
  assert resp.statusCode == 500
  assert "type mismatch" in resp.body
  echo "PASS: state[T]() mismatch is catchable"

# ============================================================
# Test 102: routerObj macro returns Router for composition/introspection
# ============================================================
block testRouterObj:
  let r = routerObj:
    get "/":
      respond 200, "ok"

  let listing = r.listRoutes()
  assert "GET\t/" in listing

  let client = newTestClient(toHandler(r))
  let resp = client.runRequest("GET", "/")
  assert resp.statusCode == 200
  assert resp.body == "ok"
  echo "PASS: routerObj returns Router"

# ============================================================
# Test 103: const/static route paths are accepted
# ============================================================
block testConstRoutePaths:
  const userPath = "/const/users/{id:int}"

  let handler = router:
    get userPath:
      respond 200, "id=" & pathParams["id"]

  let client = newTestClient(handler)
  let resp = client.runRequest("GET", "/const/users/42")
  assert resp.statusCode == 200
  assert resp.body == "id=42"
  echo "PASS: const route path support"

# ============================================================
# Test 104: trusted proxy forwarding is opt-in
# ============================================================
block testTrustedProxyForwarding:
  var req = HttpRequest(
    headers: @[
      ("x-forwarded-for", "203.0.113.7, 10.1.2.3"),
      ("x-real-ip", "198.51.100.9")
    ],
    remoteAddr: "10.1.2.3",
    context: newTable[string, string]()
  )
  req.context["remote_addr"] = "10.1.2.3"

  # Untrusted by default: use socket peer address.
  assert extractClientIp(req) == "10.1.2.3"

  # Trusted proxy context allows forwarded source extraction.
  req.context["trusted_proxy"] = "1"
  assert extractClientIp(req) == "203.0.113.7"

  # CIDR trust helper enforces allowed proxy network.
  assert isTrustedProxyAddress("10.1.2.3", @["10.0.0.0/8"])
  assert not isTrustedProxyAddress("198.51.100.9", @["10.0.0.0/8"])
  echo "PASS: trusted proxy forwarding is opt-in"

# ============================================================
# Test 105: router DSL rejects unsupported lifecycle hooks
# ============================================================
static:
  doAssert not compiles(
    block:
      let hLocal = router:
        onStart:
          discard
        get "/":
          respond 200, "ok"
  )
  doAssert not compiles(
    block:
      let hLocal = router:
        onShutdown:
          discard
        get "/":
          respond 200, "ok"
  )
  doAssert not compiles(
    block:
      let hLocal = router:
        rateLimit 1
        get "/":
          respond 200, "ok"
  )
  doAssert not compiles(
    block:
      let hLocal = router:
        get 123:
          respond 200, "ok"
  )
  doAssert not compiles(
    block:
      let hLocal = router:
        route ["FETCH"], "/":
          respond 200, "ok"
  )
  doAssert not compiles(
    block:
      let p = "/api"
      let hLocal = router:
        group p:
          get "/":
            respond 200, "ok"
  )
  doAssert not compiles(
    block:
      let p = "/events"
      let hLocal = router:
        sse p:
          discard
  )
  doAssert not compiles(
    block:
      let p = "/ws"
      let hLocal = router:
        ws p:
          discard
  )
  doAssert not compiles(
    block:
      let p = "/assets"
      let hLocal = router:
        serveStatic p, "."
  )
  doAssert not compiles(
    block:
      let p = "/stream"
      let hLocal = router:
        stream p:
          discard
  )
  doAssert not compiles(
    block:
      let hLocal = router:
        group "/api":
          notFound:
            respond 404, "nope"
        get "/":
          respond 200, "ok"
  )
  doAssert not compiles(
    block:
      let hLocal = router:
        group "/api":
          onError:
            respond 500, "err"
        get "/":
          respond 200, "ok"
  )
  doAssert not compiles(
    block:
      let hLocal = router:
        cors:
          originz "*"
        get "/":
          respond 200, "ok"
  )
  doAssert not compiles(
    block:
      let hLocal = router:
        cors:
          credentials
        get "/":
          respond 200, "ok"
  )
  doAssert not compiles(
    block:
      let hLocal = router:
        secure:
          frameOption "DENY"
        get "/":
          respond 200, "ok"
  )
  doAssert not compiles(
    block:
      let hLocal = router:
        secure:
          noSniff
        get "/":
          respond 200, "ok"
  )
  doAssert not compiles(
    block:
      let hLocal = router:
        group "/api":
          openapi:
            title "Bad"
        get "/":
          respond 200, "ok"
  )
echo "PASS: router lifecycle hook rejection"

# ============================================================
# Test 106: compile-time route pattern validation
# ============================================================
static:
  doAssert compiles(
    block:
      const constPath = "/compile/users/{id:int}"
      let hLocal = router:
        get constPath:
          respond 200, "ok"
  )
  doAssert compiles(
    block:
      template mkPath(path: static[string]): string =
        path
      let hLocal = router:
        get mkPath("/compile/static"):
          respond 200, "ok"
  )
  doAssert not compiles(
    block:
      let hLocal = router:
        get "/bad/{id:date}":
          respond 200, "nope"
  )
  doAssert not compiles(
    block:
      let hLocal = router:
        get "/bad/{id?}/tail":
          respond 200, "nope"
  )
  doAssert not compiles(
    block:
      let hLocal = router:
        get "/bad/*/tail":
          respond 200, "nope"
  )
echo "PASS: compile-time route pattern validation"

echo ""
echo "All HTTP DSL tests passed!"
