## Prometheus-compatible HTTP metrics middleware.
## Tracks request counts and latency by method, path pattern, and status code.

import std/[tables, strutils, times, locks]
import ../../runtime
import ../server/types
import ../server/router

type
  HistogramBucket = object
    le: float  # upper bound
    count: int

  RouteMetrics = object
    requestCount: int
    statusCounts: Table[int, int]  # status code -> count
    buckets: seq[HistogramBucket]
    sumMs: float

  MetricsCollector* = ref object
    lock: Lock
    routes: Table[string, RouteMetrics]  # "METHOD /pattern" -> metrics
    defaultBuckets: seq[float]

proc newMetricsCollector*(): MetricsCollector =
  ## Create a new metrics collector with default histogram buckets (in milliseconds).
  result = MetricsCollector(
    routes: initTable[string, RouteMetrics](),
    defaultBuckets: @[5.0, 10.0, 25.0, 50.0, 100.0, 250.0, 500.0, 1000.0, 2500.0, 5000.0, 10000.0]
  )
  initLock(result.lock)

proc newMetricsCollector*(buckets: seq[float]): MetricsCollector =
  ## Create a new metrics collector with custom histogram buckets (in milliseconds).
  result = MetricsCollector(
    routes: initTable[string, RouteMetrics](),
    defaultBuckets: buckets
  )
  initLock(result.lock)

proc record*(collector: MetricsCollector, meth, pattern: string, status: int, durationMs: float) =
  ## Record a completed request metric. Thread-safe.
  acquire(collector.lock)
  defer: release(collector.lock)
  let key = meth & " " & pattern
  if key notin collector.routes:
    var buckets: seq[HistogramBucket]
    for b in collector.defaultBuckets:
      buckets.add HistogramBucket(le: b, count: 0)
    collector.routes[key] = RouteMetrics(
      requestCount: 0,
      statusCounts: initTable[int, int](),
      buckets: buckets,
      sumMs: 0.0
    )
  var m = collector.routes[key]
  inc m.requestCount
  if status notin m.statusCounts:
    m.statusCounts[status] = 0
  m.statusCounts[status] = m.statusCounts[status] + 1
  m.sumMs += durationMs
  for i in 0 ..< m.buckets.len:
    if durationMs <= m.buckets[i].le:
      inc m.buckets[i].count
  collector.routes[key] = m

proc renderPrometheus*(collector: MetricsCollector): string =
  ## Render all collected metrics in Prometheus exposition format.
  acquire(collector.lock)
  defer: release(collector.lock)
  result = ""
  result.add "# HELP http_requests_total Total number of HTTP requests\n"
  result.add "# TYPE http_requests_total counter\n"
  for key, m in collector.routes:
    let parts = key.split(' ', 1)
    let meth = parts[0]
    let pattern = if parts.len > 1: parts[1] else: "/"
    for status, count in m.statusCounts:
      result.add "http_requests_total{method=\"" & meth &
        "\",path=\"" & pattern &
        "\",status=\"" & $status &
        "\"} " & $count & "\n"

  result.add "# HELP http_request_duration_ms HTTP request duration in milliseconds\n"
  result.add "# TYPE http_request_duration_ms histogram\n"
  for key, m in collector.routes:
    let parts = key.split(' ', 1)
    let meth = parts[0]
    let pattern = if parts.len > 1: parts[1] else: "/"
    let labels = "method=\"" & meth & "\",path=\"" & pattern & "\""
    for bucket in m.buckets:
      result.add "http_request_duration_ms_bucket{" & labels &
        ",le=\"" & $bucket.le &
        "\"} " & $bucket.count & "\n"
    result.add "http_request_duration_ms_bucket{" & labels &
      ",le=\"+Inf\"} " & $m.requestCount & "\n"
    result.add "http_request_duration_ms_sum{" & labels &
      "} " & $m.sumMs & "\n"
    result.add "http_request_duration_ms_count{" & labels &
      "} " & $m.requestCount & "\n"

proc metricsMiddleware*(collector: MetricsCollector): Middleware =
  ## Create a middleware that records request count and latency metrics.
  ##
  ## The middleware measures the time taken by downstream handlers and records
  ## the method, path, and status code for each request.
  let cap = collector
  result = proc(req: HttpRequest, next: HttpHandler): CpsFuture[HttpResponseBuilder] {.closure.} =
    let startTime = epochTime()
    let capturedMethod = req.meth
    let capturedPath =
      if req.context.isNil: pathWithoutQuery(req.path)
      else: req.context.getOrDefault("route_pattern", pathWithoutQuery(req.path))
    let fut = next(req)
    let resultFut = newCpsFuture[HttpResponseBuilder]()
    fut.addCallback(proc() =
      let duration = (epochTime() - startTime) * 1000.0
      if fut.hasError():
        cap.record(capturedMethod, capturedPath, 500, duration)
        resultFut.fail(fut.getError())
      else:
        let resp = fut.read()
        cap.record(capturedMethod, capturedPath, resp.statusCode, duration)
        resultFut.complete(resp)
    )
    return resultFut

proc metricsHandler*(collector: MetricsCollector): HttpHandler =
  ## Create an HTTP handler that serves the /metrics endpoint in Prometheus format.
  ##
  ## Typically registered as:
  ##   router.get("/metrics", collector.metricsHandler())
  let cap = collector
  result = proc(req: HttpRequest): CpsFuture[HttpResponseBuilder] {.closure.} =
    let body = cap.renderPrometheus()
    let fut = newCpsFuture[HttpResponseBuilder]()
    fut.complete(newResponse(200, body, @[
      ("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
    ]))
    return fut
