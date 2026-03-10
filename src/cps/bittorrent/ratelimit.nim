## Global bandwidth rate limiter for BitTorrent.
##
## Token bucket with debt tracking and percentage-based bandwidth allocation.
## A single BandwidthLimiter is shared across all peer connections, enforcing
## aggregate upload and download rate limits.
##
## Key design: unconditional consume with debt. Each consume immediately deducts
## tokens (which may go negative), then sleeps proportionally to the debt. This
## prevents the thundering-herd problem where multiple peers wake simultaneously
## and all see the same positive token balance.
##
## Usage:
##   let limiter = newBandwidthLimiter(
##     uploadBps = 10_000_000,     # 10 MB/s total upload
##     downloadBps = 100_000_000,  # 100 MB/s total download
##     percent = 80                # Use up to 80% of each
##   )
##   # In peer write loop:
##   await limiter.consume(data.len, Upload)
##   # In peer read loop:
##   await limiter.consume(bytesRead, Download)

import std/[monotimes, times]
import ../runtime
import ../transform
import ../eventloop

const
  MinBurstBytes* = 16384    ## Minimum burst size (16 KiB) — prevents micro-sleeps
  MaxBurstBytes* = 65536    ## Maximum burst size (64 KiB) — caps burst regardless of rate
  MaxSleepMs* = 1000        ## Cap sleep to 1s to stay responsive

type
  Direction* = enum
    Upload, Download

  TokenBucket* = object
    tokens*: float           ## Current available tokens (bytes); may be negative (debt)
    capacity*: float         ## Max tokens (burst ceiling)
    rate*: float             ## Refill rate (bytes/sec), 0 = unlimited
    baseBps*: int            ## Original user-provided bytes/sec (before percent)
    lastRefill*: MonoTime    ## Monotonic time of last refill

  BandwidthLimiter* = ref object
    buckets*: array[Direction, TokenBucket]
    percent*: int            ## Percentage of bandwidth to use (1-100)

proc initTokenBucket*(bps: int, percent: int): TokenBucket =
  ## Create a token bucket for the given bandwidth (bytes/sec) and percentage.
  if bps <= 0 or percent <= 0:
    return TokenBucket(tokens: 0, capacity: 0, rate: 0, baseBps: 0)
  let effectiveRate = float(bps) * float(percent) / 100.0
  # Burst capacity: clamped between MinBurstBytes and MaxBurstBytes.
  let cap = max(min(effectiveRate * 0.25, MaxBurstBytes.float), MinBurstBytes.float)
  TokenBucket(
    tokens: cap,
    capacity: cap,
    rate: effectiveRate,
    baseBps: bps,
    lastRefill: getMonoTime()
  )

proc refill*(bucket: var TokenBucket) {.inline.} =
  ## Refill tokens based on elapsed time since last refill.
  ## Tokens are clamped to capacity (debt is recovered gradually, not instantly).
  if bucket.rate <= 0:
    return
  let now = getMonoTime()
  let elapsedNs = (now - bucket.lastRefill).inNanoseconds
  if elapsedNs > 0:
    let elapsedSec = elapsedNs.float / 1_000_000_000.0
    bucket.tokens = min(bucket.capacity, bucket.tokens + elapsedSec * bucket.rate)
    bucket.lastRefill = now

proc consumeWithDebt*(bucket: var TokenBucket, bytes: int): int =
  ## Consume tokens unconditionally — tokens may go negative (debt).
  ## Returns the number of milliseconds to sleep before the debt is repaid.
  ## Returns 0 if no wait needed.
  ##
  ## This is the key primitive: by always consuming immediately, each caller
  ## sees the cumulative debt from prior callers and gets a proportionally
  ## longer sleep. No two callers can race on the same positive balance.
  if bucket.rate <= 0:
    return 0  # Unlimited
  bucket.refill()
  bucket.tokens -= bytes.float
  if bucket.tokens >= 0:
    return 0
  let waitSec = (-bucket.tokens) / bucket.rate
  return min(MaxSleepMs, int(waitSec * 1000) + 1)

# ============================================================
# BandwidthLimiter
# ============================================================

proc newBandwidthLimiter*(uploadBps: int = 0, downloadBps: int = 0,
                          percent: int = 80): BandwidthLimiter =
  ## Create a bandwidth limiter.
  ##
  ## - `uploadBps`: Total upload bandwidth in bytes/sec (0 = unlimited)
  ## - `downloadBps`: Total download bandwidth in bytes/sec (0 = unlimited)
  ## - `percent`: Percentage of bandwidth to allocate (1-100)
  let pct = clamp(percent, 1, 100)
  BandwidthLimiter(
    buckets: [initTokenBucket(uploadBps, pct), initTokenBucket(downloadBps, pct)],
    percent: pct
  )

proc isLimited*(limiter: BandwidthLimiter, dir: Direction): bool {.inline.} =
  limiter.buckets[dir].rate > 0

proc effectiveRate*(limiter: BandwidthLimiter, dir: Direction): float {.inline.} =
  limiter.buckets[dir].rate

proc waitForBudget*(limiter: BandwidthLimiter, dir: Direction): CpsVoidFuture {.cps.} =
  ## Wait until the bucket has non-negative tokens (debt is repaid).
  ## Call this BEFORE reading from the network to prevent reading at wire speed
  ## while over budget.
  if limiter == nil:
    return
  var bucket = addr limiter.buckets[dir]
  if bucket.rate <= 0:
    return
  bucket[].refill()
  if bucket.tokens >= 0:
    return
  let waitSec = (-bucket.tokens) / bucket.rate
  let waitMs = min(MaxSleepMs, int(waitSec * 1000) + 1)
  await cpsSleep(waitMs)

proc consume*(limiter: BandwidthLimiter, bytes: int, dir: Direction): CpsVoidFuture {.cps.} =
  ## Throttle traffic: consume tokens and wait if in debt.
  if limiter == nil or not limiter.isLimited(dir):
    return
  let waitMs = limiter.buckets[dir].consumeWithDebt(bytes)
  if waitMs > 0:
    await cpsSleep(waitMs)

proc updateLimits*(limiter: BandwidthLimiter, uploadBps: int = 0,
                   downloadBps: int = 0, percent: int = 0) =
  ## Update rate limits at runtime (e.g., user changes settings).
  ## Pass 0 for any parameter to leave it unchanged.
  ## Pass -1 for uploadBps/downloadBps to disable that limit.
  let pct = if percent > 0: clamp(percent, 1, 100) else: limiter.percent
  for (dir, bps) in [(Upload, uploadBps), (Download, downloadBps)]:
    if bps != 0:
      limiter.buckets[dir] = initTokenBucket(max(bps, 0), pct)
    elif percent > 0 and limiter.buckets[dir].rate > 0:
      limiter.buckets[dir] = initTokenBucket(limiter.buckets[dir].baseBps, pct)
  limiter.percent = pct
