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
    lock: Lock

proc newRateLimiter*(maxRequests: int, windowSeconds: int): RateLimiter =
  ## Create a new rate limiter. maxRequests per windowSeconds.
  result = RateLimiter(
    buckets: initTable[string, TokenBucket](),
    maxTokens: maxRequests,
    refillRate: maxRequests.float / windowSeconds.float
  )
  initLock(result.lock)

proc extractIp*(req: HttpRequest): string =
  ## Default key extractor: uses X-Forwarded-For or falls back to "unknown".
  let forwarded = req.getHeader("x-forwarded-for")
  if forwarded.len > 0:
    return forwarded.split(',')[0].strip()
  let realIp = req.getHeader("x-real-ip")
  if realIp.len > 0:
    return realIp
  return "unknown"

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
                           keyExtractor: proc(req: HttpRequest): string = nil): Middleware =
  ## Create a rate limiting middleware.
  ## Uses IP extraction by default. Pass a custom keyExtractor to use API keys etc.
  let limiter = newRateLimiter(maxRequests, windowSeconds)
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
