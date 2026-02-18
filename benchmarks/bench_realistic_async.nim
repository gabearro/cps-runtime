## Realistic std/asyncdispatch Benchmarks
##
## Simulates common async server/application patterns and measures
## the async framework overhead. Compare with bench_realistic_cps.nim.
##
## Scenarios:
##   1. HTTP handler pipeline — parse → auth → fetch → respond (4 async hops)
##   2. Middleware chain — 5 layers of nested processing
##   3. Batch processing — N items × 3 async transform steps
##   4. Error handling — try/except around failing async calls
##   5. Deep service calls — 10-layer nested async chain
##
## Run:
##   nim c -r -d:danger benchmarks/bench_realistic_async.nim
##   nim c -r -d:danger benchmarks/bench_realistic_cps.nim

import criterion
import std/asyncdispatch

var cfg = newDefaultConfig()

# ============================================================
# Shared types and helpers (identical in both benchmark files)
# ============================================================

type
  Request = object
    path: string
    authToken: string
    body: string

  Response = object
    status: int
    body: string

proc computeHash(s: string): int =
  ## Deterministic string hash (lightweight stand-in for real work).
  var h = 2166136261'u64
  for c in s:
    h = (h xor uint64(ord(c))) * 1099511628211'u64
  result = int(h mod 1000003'u64)

# ============================================================
# Scenario 1: HTTP Request Handler Pipeline
#
# Simulates a typical REST API handler:
#   parseRequest → authenticate → fetchUser → buildResponse
# Each step does a small amount of real work.
# ============================================================

proc parseRequest(raw: string): Future[Request] {.async.} =
  return Request(
    path: "/api/users/123",
    authToken: "Bearer sk-test-token-1234567890",
    body: raw
  )

proc authenticate(token: string): Future[bool] {.async.} =
  return computeHash(token) != 0

proc fetchUser(userId: int): Future[string] {.async.} =
  return "{\"id\":" & $userId & ",\"name\":\"Alice\"}"

proc buildResponse(status: int, body: string): Future[Response] {.async.} =
  return Response(status: status, body: body)

proc handleRequest(raw: string): Future[Response] {.async.} =
  let req = await parseRequest(raw)
  let ok = await authenticate(req.authToken)
  if not ok:
    let errResp = await buildResponse(401, "unauthorized")
    return errResp
  let user = await fetchUser(123)
  let resp = await buildResponse(200, user)
  return resp

# ============================================================
# Scenario 2: Middleware Chain (5 layers)
#
# Simulates a server middleware stack where each layer wraps
# the input, delegates to the next layer, and transforms output.
# ============================================================

proc middlewareCore(x: int): Future[int] {.async.} =
  return x + computeHash("core")

proc middleware4(x: int): Future[int] {.async.} =
  let inner = await middlewareCore(x)
  return inner * 3 + 4

proc middleware3(x: int): Future[int] {.async.} =
  let inner = await middleware4(x)
  return inner * 3 + 3

proc middleware2(x: int): Future[int] {.async.} =
  let inner = await middleware3(x)
  return inner * 3 + 2

proc middleware1(x: int): Future[int] {.async.} =
  let inner = await middleware2(x)
  return inner * 3 + 1

proc middlewareChain(x: int): Future[int] {.async.} =
  let val = await middleware1(x)
  return val

# ============================================================
# Scenario 3: Batch Processing
#
# Process N items, each through 3 async transform steps.
# Simulates a request that fans out to multiple sub-operations
# (e.g., processing a batch API request).
# ============================================================

proc transform1(x: int): Future[int] {.async.} =
  return x * 2 + 1

proc transform2(x: int): Future[int] {.async.} =
  return x xor 0xFF

proc transform3(x: int): Future[int] {.async.} =
  return (x mod 997) + computeHash($x)

proc processItem(item: int): Future[int] {.async.} =
  let a = await transform1(item)
  let b = await transform2(a)
  let c = await transform3(b)
  return c

proc processBatch(n: int): Future[int] {.async.} =
  var total = 0
  for i in 0 ..< n:
    let r = await processItem(i)
    total += r
  return total

# ============================================================
# Scenario 4: Error Handling
#
# Try/except around async calls that may fail.
# Simulates database operations with error recovery.
# ============================================================

proc riskyDbQuery(shouldFail: bool): Future[int] {.async.} =
  if shouldFail:
    raise newException(ValueError, "connection timeout")
  return 42

proc queryWithRetry(): Future[int] {.async.} =
  # First attempt fails, retry succeeds
  try:
    let v = await riskyDbQuery(true)
    return v
  except ValueError:
    let v = await riskyDbQuery(false)
    return v

# ============================================================
# Scenario 5: Deep Service Call Chain (10 layers)
#
# Simulates microservice-style nested calls:
#   API Gateway → Auth Service → User Service → DB Layer → ...
# Each layer adds a small computation.
# ============================================================

proc serviceLayer0(x: int): Future[int] {.async.} =
  return x + computeHash("db")

proc serviceLayer1(x: int): Future[int] {.async.} =
  let r = await serviceLayer0(x)
  return r + 1

proc serviceLayer2(x: int): Future[int] {.async.} =
  let r = await serviceLayer1(x)
  return r + 2

proc serviceLayer3(x: int): Future[int] {.async.} =
  let r = await serviceLayer2(x)
  return r + 3

proc serviceLayer4(x: int): Future[int] {.async.} =
  let r = await serviceLayer3(x)
  return r + 4

proc serviceLayer5(x: int): Future[int] {.async.} =
  let r = await serviceLayer4(x)
  return r + 5

proc serviceLayer6(x: int): Future[int] {.async.} =
  let r = await serviceLayer5(x)
  return r + 6

proc serviceLayer7(x: int): Future[int] {.async.} =
  let r = await serviceLayer6(x)
  return r + 7

proc serviceLayer8(x: int): Future[int] {.async.} =
  let r = await serviceLayer7(x)
  return r + 8

proc serviceLayer9(x: int): Future[int] {.async.} =
  let r = await serviceLayer8(x)
  return r + 9

# ============================================================
# Benchmarks
# ============================================================

benchmark cfg:
  proc benchHttpHandler() {.measure.} =
    ## HTTP handler pipeline (parse → auth → fetch → respond)
    let resp = waitFor handleRequest("{\"action\":\"get_user\"}")
    blackBox resp.status

  proc benchMiddlewareChain() {.measure.} =
    ## Middleware chain (5 layers)
    blackBox waitFor(middlewareChain(42))

  iterator batchSizes(): int =
    for n in [10, 50, 100]:
      yield n

  proc benchBatchProcessing(n: int) {.measure: batchSizes.} =
    ## Batch processing: N items × 3 async steps
    blackBox waitFor(processBatch(n))

  proc benchErrorHandling() {.measure.} =
    ## Error handling with retry (try/except + await)
    blackBox waitFor(queryWithRetry())

  proc benchDeepServiceCalls() {.measure.} =
    ## Deep service calls (10 layers)
    blackBox waitFor(serviceLayer9(0))
