## HTTP Test Client
##
## In-process test client that constructs HttpRequest objects and calls
## handlers directly — no TCP, no HTTP parsing. Fast for unit tests.

import std/[tables, strutils, json]
import ../../runtime
import ../../transform
import ../../eventloop
import ./types
import ./router

type
  TestClient* = object
    handler: HttpHandler

proc newTestClient*(handler: HttpHandler): TestClient =
  ## Create a test client that calls the given handler directly.
  TestClient(handler: handler)

proc buildRequest(meth: string, path: string, body: string,
                   headers: seq[(string, string)]): HttpRequest =
  ## Build an HttpRequest for testing.
  HttpRequest(
    meth: meth,
    path: path,
    httpVersion: "HTTP/1.1",
    headers: headers,
    body: body,
    context: newTable[string, string]()
  )

proc request*(client: TestClient, meth: string, path: string,
               body: string = "",
               headers: seq[(string, string)] = @[]): CpsFuture[HttpResponseBuilder] =
  ## Send a request to the handler and return the response.
  let req = buildRequest(meth, path, body, headers)
  client.handler(req)

proc get*(client: TestClient, path: string,
           headers: seq[(string, string)] = @[]): CpsFuture[HttpResponseBuilder] =
  ## Send a GET request.
  client.request("GET", path, "", headers)

proc post*(client: TestClient, path: string, body: string = "",
            headers: seq[(string, string)] = @[]): CpsFuture[HttpResponseBuilder] =
  ## Send a POST request.
  client.request("POST", path, body, headers)

proc put*(client: TestClient, path: string, body: string = "",
           headers: seq[(string, string)] = @[]): CpsFuture[HttpResponseBuilder] =
  ## Send a PUT request.
  client.request("PUT", path, body, headers)

proc delete*(client: TestClient, path: string,
              headers: seq[(string, string)] = @[]): CpsFuture[HttpResponseBuilder] =
  ## Send a DELETE request.
  client.request("DELETE", path, "", headers)

proc patch*(client: TestClient, path: string, body: string = "",
             headers: seq[(string, string)] = @[]): CpsFuture[HttpResponseBuilder] =
  ## Send a PATCH request.
  client.request("PATCH", path, body, headers)

proc head*(client: TestClient, path: string,
            headers: seq[(string, string)] = @[]): CpsFuture[HttpResponseBuilder] =
  ## Send a HEAD request.
  client.request("HEAD", path, "", headers)

proc options*(client: TestClient, path: string,
               headers: seq[(string, string)] = @[]): CpsFuture[HttpResponseBuilder] =
  ## Send an OPTIONS request.
  client.request("OPTIONS", path, "", headers)

proc runRequest*(client: TestClient, meth: string, path: string,
                  body: string = "",
                  headers: seq[(string, string)] = @[]): HttpResponseBuilder =
  ## Synchronously run a request through the event loop.
  let fut = client.request(meth, path, body, headers)
  let loop = getEventLoop()
  while not fut.finished:
    loop.tick()
    if not loop.hasWork:
      break
  if fut.hasError():
    raise fut.getError()
  return fut.read()

proc assertStatus*(resp: HttpResponseBuilder, expected: int) =
  if resp.statusCode != expected:
    raise newException(AssertionDefect,
      "Expected status " & $expected & " but got " & $resp.statusCode)

proc assertBody*(resp: HttpResponseBuilder, expected: string) =
  if resp.body != expected:
    raise newException(AssertionDefect,
      "Expected body \"" & expected & "\" but got \"" & resp.body & "\"")

proc assertBodyContains*(resp: HttpResponseBuilder, substring: string) =
  if substring notin resp.body:
    raise newException(AssertionDefect,
      "Expected body to contain \"" & substring & "\" but body is \"" & resp.body & "\"")

proc assertHeader*(resp: HttpResponseBuilder, name: string, expected: string) =
  for (k, v) in resp.headers:
    if k.toLowerAscii == name.toLowerAscii:
      if v == expected:
        return
      else:
        raise newException(AssertionDefect,
          "Header " & name & ": expected \"" & expected & "\" but got \"" & v & "\"")
  raise newException(AssertionDefect,
    "Header " & name & " not found in response")

proc assertHeaderContains*(resp: HttpResponseBuilder, name: string, substring: string) =
  for (k, v) in resp.headers:
    if k.toLowerAscii == name.toLowerAscii:
      if substring in v:
        return
      else:
        raise newException(AssertionDefect,
          "Header " & name & ": expected to contain \"" & substring & "\" but got \"" & v & "\"")
  raise newException(AssertionDefect,
    "Header " & name & " not found in response")

proc assertJsonBody*(resp: HttpResponseBuilder, expected: JsonNode) =
  let actual = parseJson(resp.body)
  if actual != expected:
    raise newException(AssertionDefect,
      "Expected JSON " & $expected & " but got " & $actual)
