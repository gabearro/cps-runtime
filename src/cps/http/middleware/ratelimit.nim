## Rate Limiting Middleware
##
## Token bucket rate limiter for HTTP requests.
## Tracks requests per key (IP, API key, etc.) and returns 429 when exceeded.

import std/[tables, times, locks, strutils]
import ../../runtime
import ../server/types
import ../server/router

type
  TokenBucket = object
    tokens: float
    lastRefill: float  # epochTime

  RateLimiter* = ref object
    buckets: Table[string, TokenBucket]
    maxTokens: int
    refillRate: float  # tokens per second
    maxKeys: int
    idleTtlSeconds: int
    cleanupIntervalSeconds: int
    lastCleanup: float
    lock: Lock

proc newRateLimiter*(maxRequests: int, windowSeconds: int,
                     maxKeys: int = 10000,
                     idleTtlSeconds: int = 600,
                     cleanupIntervalSeconds: int = 60): RateLimiter =
  ## Create a new rate limiter. maxRequests per windowSeconds.
  if maxRequests <= 0:
    raise newException(ValueError, "maxRequests must be > 0")
  if windowSeconds <= 0:
    raise newException(ValueError, "windowSeconds must be > 0")
  result = RateLimiter(
    buckets: initTable[string, TokenBucket](),
    maxTokens: maxRequests,
    refillRate: maxRequests.float / windowSeconds.float,
    maxKeys: maxKeys,
    idleTtlSeconds: idleTtlSeconds,
    cleanupIntervalSeconds: cleanupIntervalSeconds,
    lastCleanup: epochTime()
  )
  initLock(result.lock)

proc extractIp*(req: HttpRequest): string =
  ## Default key extractor: trusted client IP extraction.
  extractClientIp(req)

proc extractHeader*(headerName: string): proc(req: HttpRequest): string =
  ## Key extractor using a specific header value.
  let capturedHeader = headerName
  result = proc(req: HttpRequest): string =
    req.getHeader(capturedHeader)

proc tryConsume(limiter: RateLimiter, key: string): (bool, int) =
  ## Try to consume a token. Returns (allowed, retryAfterSeconds).
  acquire(limiter.lock)
  defer: release(limiter.lock)

  let now = epochTime()

  if limiter.idleTtlSeconds > 0 and limiter.cleanupIntervalSeconds > 0:
    if now - limiter.lastCleanup >= limiter.cleanupIntervalSeconds.float:
      var staleKeys: seq[string]
      for k, bucket in limiter.buckets:
        if now - bucket.lastRefill >= limiter.idleTtlSeconds.float:
          staleKeys.add k
      for k in staleKeys:
        limiter.buckets.del(k)
      limiter.lastCleanup = now

  var bucketExists = key in limiter.buckets
  if not bucketExists and limiter.maxKeys > 0 and limiter.buckets.len >= limiter.maxKeys:
    # Evict the stalest bucket to keep memory bounded.
    var oldestKey = ""
    var oldestTs = now
    var haveOldest = false
    for k, bucket in limiter.buckets:
      if not haveOldest or bucket.lastRefill < oldestTs:
        oldestKey = k
        oldestTs = bucket.lastRefill
        haveOldest = true
    if haveOldest:
      limiter.buckets.del(oldestKey)

  if key notin limiter.buckets:
    limiter.buckets[key] = TokenBucket(
      tokens: limiter.maxTokens.float - 1.0,
      lastRefill: now
    )
    return (true, 0)

  var bucket = limiter.buckets[key]
  let elapsed = now - bucket.lastRefill
  bucket.tokens = min(limiter.maxTokens.float, bucket.tokens + elapsed * limiter.refillRate)
  bucket.lastRefill = now

  if bucket.tokens >= 1.0:
    bucket.tokens -= 1.0
    limiter.buckets[key] = bucket
    return (true, 0)
  else:
    let retryAfter = int((1.0 - bucket.tokens) / limiter.refillRate) + 1
    limiter.buckets[key] = bucket
    return (false, retryAfter)

proc rateLimitMiddleware*(maxRequests: int, windowSeconds: int,
                           keyExtractor: proc(req: HttpRequest): string = nil,
                           maxKeys: int = 10000,
                           idleTtlSeconds: int = 600,
                           cleanupIntervalSeconds: int = 60): Middleware =
  ## Create a rate limiting middleware.
  ## Uses IP extraction by default. Pass a custom keyExtractor to use API keys etc.
  let limiter = newRateLimiter(
    maxRequests,
    windowSeconds,
    maxKeys = maxKeys,
    idleTtlSeconds = idleTtlSeconds,
    cleanupIntervalSeconds = cleanupIntervalSeconds
  )
  let capturedExtractor = keyExtractor

  result = proc(req: HttpRequest, next: HttpHandler): CpsFuture[HttpResponseBuilder] {.closure.} =
    let key = if capturedExtractor != nil:
      capturedExtractor(req)
    else:
      extractIp(req)

    let (allowed, retryAfter) = limiter.tryConsume(key)
    if not allowed:
      let fut = newCpsFuture[HttpResponseBuilder]()
      fut.complete(newResponse(429, "Too Many Requests", @[
        ("Retry-After", $retryAfter),
        ("Content-Type", "text/plain")
      ]))
      return fut

    return next(req)
