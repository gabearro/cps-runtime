## Realistic CPS Async Benchmarks
##
## Simulates common async server/application patterns and measures
## the async framework overhead. Compare with bench_realistic_async.nim.
##
## Scenarios:
##   1. HTTP handler pipeline — parse → auth → fetch → respond (4 async hops)
##   2. Middleware chain — 5 layers of nested processing
##   3. Batch processing — N items × 3 async transform steps
##   4. Error handling — try/except around failing async calls
##   5. Deep service calls — 10-layer nested async chain
##
## Run:
##   nim c -r -d:danger benchmarks/bench_realistic_cps.nim
##   nim c -r -d:danger benchmarks/bench_realistic_async.nim

import criterion
import cps/runtime
import cps/transform
import cps/eventloop

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

proc parseRequest(raw: string): CpsFuture[Request] {.cps.} =
  return Request(
    path: "/api/users/123",
    authToken: "Bearer sk-test-token-1234567890",
    body: raw
  )

proc authenticate(token: string): CpsFuture[bool] {.cps.} =
  return computeHash(token) != 0

proc fetchUser(userId: int): CpsFuture[string] {.cps.} =
  return "{\"id\":" & $userId & ",\"name\":\"Alice\"}"

proc buildResponse(status: int, body: string): CpsFuture[Response] {.cps.} =
  return Response(status: status, body: body)

proc handleRequest(raw: string): CpsFuture[Response] {.cps.} =
  let req: Request = await parseRequest(raw)
  let ok: bool = await authenticate(req.authToken)
  if not ok:
    let errResp: Response = await buildResponse(401, "unauthorized")
    return errResp
  let user: string = await fetchUser(123)
  let resp: Response = await buildResponse(200, user)
  return resp

# ============================================================
# Scenario 2: Middleware Chain (5 layers)
#
# Simulates a server middleware stack where each layer wraps
# the input, delegates to the next layer, and transforms output.
# ============================================================

proc middlewareCore(x: int): CpsFuture[int] {.cps.} =
  return x + computeHash("core")

proc middleware4(x: int): CpsFuture[int] {.cps.} =
  let inner: int = await middlewareCore(x)
  return inner * 3 + 4

proc middleware3(x: int): CpsFuture[int] {.cps.} =
  let inner: int = await middleware4(x)
  return inner * 3 + 3

proc middleware2(x: int): CpsFuture[int] {.cps.} =
  let inner: int = await middleware3(x)
  return inner * 3 + 2

proc middleware1(x: int): CpsFuture[int] {.cps.} =
  let inner: int = await middleware2(x)
  return inner * 3 + 1

proc middlewareChain(x: int): CpsFuture[int] {.cps.} =
  let val: int = await middleware1(x)
  return val

# ============================================================
# Scenario 3: Batch Processing
#
# Process N items, each through 3 async transform steps.
# Simulates a request that fans out to multiple sub-operations
# (e.g., processing a batch API request).
# ============================================================

proc transform1(x: int): CpsFuture[int] {.cps.} =
  return x * 2 + 1

proc transform2(x: int): CpsFuture[int] {.cps.} =
  return x xor 0xFF

proc transform3(x: int): CpsFuture[int] {.cps.} =
  return (x mod 997) + computeHash($x)

proc processItem(item: int): CpsFuture[int] {.cps.} =
  let a: int = await transform1(item)
  let b: int = await transform2(a)
  let c: int = await transform3(b)
  return c

proc processBatch(n: int): CpsFuture[int] {.cps.} =
  var total = 0
  for i in 0 ..< n:
    let r: int = await processItem(i)
    total += r
  return total

# ============================================================
# Scenario 4: Error Handling
#
# Try/except around async calls that may fail.
# Simulates database operations with error recovery.
# ============================================================

proc riskyDbQuery(shouldFail: bool): CpsFuture[int] {.cps.} =
  if shouldFail:
    raise newException(ValueError, "connection timeout")
  return 42

proc queryWithRetry(): CpsFuture[int] {.cps.} =
  # First attempt fails, retry succeeds
  try:
    let v: int = await riskyDbQuery(true)
    return v
  except ValueError:
    let v: int = await riskyDbQuery(false)
    return v

# ============================================================
# Scenario 5: Deep Service Call Chain (10 layers)
#
# Simulates microservice-style nested calls:
#   API Gateway → Auth Service → User Service → DB Layer → ...
# Each layer adds a small computation.
# ============================================================

proc serviceLayer0(x: int): CpsFuture[int] {.cps.} =
  return x + computeHash("db")

proc serviceLayer1(x: int): CpsFuture[int] {.cps.} =
  let r: int = await serviceLayer0(x)
  return r + 1

proc serviceLayer2(x: int): CpsFuture[int] {.cps.} =
  let r: int = await serviceLayer1(x)
  return r + 2

proc serviceLayer3(x: int): CpsFuture[int] {.cps.} =
  let r: int = await serviceLayer2(x)
  return r + 3

proc serviceLayer4(x: int): CpsFuture[int] {.cps.} =
  let r: int = await serviceLayer3(x)
  return r + 4

proc serviceLayer5(x: int): CpsFuture[int] {.cps.} =
  let r: int = await serviceLayer4(x)
  return r + 5

proc serviceLayer6(x: int): CpsFuture[int] {.cps.} =
  let r: int = await serviceLayer5(x)
  return r + 6

proc serviceLayer7(x: int): CpsFuture[int] {.cps.} =
  let r: int = await serviceLayer6(x)
  return r + 7

proc serviceLayer8(x: int): CpsFuture[int] {.cps.} =
  let r: int = await serviceLayer7(x)
  return r + 8

proc serviceLayer9(x: int): CpsFuture[int] {.cps.} =
  let r: int = await serviceLayer8(x)
  return r + 9

# ============================================================
# Benchmarks
# ============================================================

benchmark cfg:
  proc benchHttpHandler() {.measure.} =
    ## HTTP handler pipeline (parse → auth → fetch → respond)
    let resp = handleRequest("{\"action\":\"get_user\"}").read()
    blackBox resp.status

  proc benchMiddlewareChain() {.measure.} =
    ## Middleware chain (5 layers)
    let fut = middlewareChain(42)
    blackBox fut.read()

  iterator batchSizes(): int =
    for n in [10, 50, 100]:
      yield n

  proc benchBatchProcessing(n: int) {.measure: batchSizes.} =
    ## Batch processing: N items × 3 async steps
    let fut = processBatch(n)
    blackBox fut.read()

  proc benchErrorHandling() {.measure.} =
    ## Error handling with retry (try/except + await)
    let fut = queryWithRetry()
    blackBox fut.read()

  proc benchDeepServiceCalls() {.measure.} =
    ## Deep service calls (10 layers)
    let fut = serviceLayer9(0)
    blackBox fut.read()
