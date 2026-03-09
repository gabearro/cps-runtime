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
##   await limiter.consumeUpload(data.len)
##   # In peer read loop:
##   await limiter.consumeDownload(bytesRead)

import std/times
import ../runtime
import ../transform
import ../eventloop

const
  MinBurstBytes* = 16384    ## Minimum burst size (16 KiB) — prevents micro-sleeps
  MaxBurstBytes* = 65536    ## Maximum burst size (64 KiB) — caps burst regardless of rate
  MaxSleepMs* = 1000        ## Cap sleep to 1s to stay responsive

type
  TokenBucket* = object
    tokens*: float           ## Current available tokens (bytes); may be negative (debt)
    capacity*: float         ## Max tokens (burst ceiling)
    rate*: float             ## Refill rate (bytes/sec), 0 = unlimited
    lastRefill*: float       ## epochTime of last refill

  BandwidthLimiter* = ref object
    upload*: TokenBucket
    download*: TokenBucket
    percent*: int            ## Percentage of bandwidth to use (1-100)

proc initTokenBucket*(bps: int, percent: int): TokenBucket =
  ## Create a token bucket for the given bandwidth (bytes/sec) and percentage.
  if bps <= 0 or percent <= 0:
    return TokenBucket(tokens: 0, capacity: 0, rate: 0, lastRefill: epochTime())
  let effectiveRate = float(bps) * float(percent) / 100.0
  # Burst capacity: clamped between MinBurstBytes and MaxBurstBytes.
  # At most ~4 standard blocks can burst, regardless of rate.
  let cap = max(min(effectiveRate * 0.25, MaxBurstBytes.float), MinBurstBytes.float)
  TokenBucket(
    tokens: cap,          # Start full (but cap is small, so burst is limited)
    capacity: cap,
    rate: effectiveRate,
    lastRefill: epochTime()
  )

proc refill*(bucket: var TokenBucket) {.inline.} =
  ## Refill tokens based on elapsed time since last refill.
  ## Tokens are clamped to capacity (debt is recovered gradually, not instantly).
  if bucket.rate <= 0:
    return
  let now = epochTime()
  let elapsed = now - bucket.lastRefill
  if elapsed > 0:
    bucket.tokens = min(bucket.capacity, bucket.tokens + elapsed * bucket.rate)
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
  # Sleep proportional to debt
  let waitSec = (-bucket.tokens) / bucket.rate
  return min(MaxSleepMs, int(waitSec * 1000) + 1)

proc tryConsume*(bucket: var TokenBucket, bytes: int): int =
  ## Try to consume `bytes` tokens. Returns 0 if consumed, otherwise the
  ## number of milliseconds to wait before enough tokens are available.
  ## NOTE: does NOT consume on failure — use consumeWithDebt for strict limiting.
  if bucket.rate <= 0:
    return 0  # Unlimited
  bucket.refill()
  if bucket.tokens >= bytes.float:
    bucket.tokens -= bytes.float
    return 0
  # Calculate wait time for deficit
  let deficit = bytes.float - bucket.tokens
  let waitSec = deficit / bucket.rate
  return min(MaxSleepMs, int(waitSec * 1000) + 1)

proc consume*(bucket: var TokenBucket, bytes: int) =
  ## Consume tokens unconditionally (after waiting). Tokens may go negative
  ## briefly; the next refill will recover.
  if bucket.rate <= 0:
    return
  bucket.refill()
  bucket.tokens -= bytes.float

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
  ##
  ## Example: 10 Mbps upload at 80% → effective limit = 1_000_000 bytes/sec
  let pct = clamp(percent, 1, 100)
  BandwidthLimiter(
    upload: initTokenBucket(uploadBps, pct),
    download: initTokenBucket(downloadBps, pct),
    percent: pct
  )

proc isUploadLimited*(limiter: BandwidthLimiter): bool {.inline.} =
  limiter.upload.rate > 0

proc isDownloadLimited*(limiter: BandwidthLimiter): bool {.inline.} =
  limiter.download.rate > 0

proc effectiveUploadRate*(limiter: BandwidthLimiter): float {.inline.} =
  limiter.upload.rate

proc effectiveDownloadRate*(limiter: BandwidthLimiter): float {.inline.} =
  limiter.download.rate

proc hasBudget*(limiter: BandwidthLimiter, download: bool): bool {.inline.} =
  ## Check if the bucket has any budget (tokens >= 0) without consuming.
  ## Useful for pre-read throttling on the download side.
  if limiter == nil:
    return true
  if download:
    if limiter.download.rate <= 0: return true
    return limiter.download.tokens >= 0
  else:
    if limiter.upload.rate <= 0: return true
    return limiter.upload.tokens >= 0

proc waitForBudget*(limiter: BandwidthLimiter, download: bool): CpsVoidFuture {.cps.} =
  ## Wait until the bucket has non-negative tokens (debt is repaid).
  ## Call this BEFORE reading from the network to prevent reading at wire speed
  ## while over budget.
  if limiter == nil:
    return
  var bucket = if download: addr limiter.download else: addr limiter.upload
  if bucket.rate <= 0:
    return
  bucket[].refill()
  if bucket.tokens >= 0:
    return
  # Sleep for the time needed to repay the debt
  let waitSec = (-bucket.tokens) / bucket.rate
  let waitMs = min(MaxSleepMs, int(waitSec * 1000) + 1)
  await cpsSleep(waitMs)

proc consumeUpload*(limiter: BandwidthLimiter, bytes: int): CpsVoidFuture {.cps.} =
  ## Throttle upload: consume tokens and wait if in debt.
  ## Call this before sending data to a peer.
  if limiter == nil or not limiter.isUploadLimited():
    return
  let waitMs = limiter.upload.consumeWithDebt(bytes)
  if waitMs > 0:
    await cpsSleep(waitMs)

proc consumeDownload*(limiter: BandwidthLimiter, bytes: int): CpsVoidFuture {.cps.} =
  ## Throttle download: consume tokens and wait if in debt.
  ## Call this after receiving data from a peer (post-hoc throttling).
  ## Pair with waitForBudget() before the read for tighter enforcement.
  if limiter == nil or not limiter.isDownloadLimited():
    return
  let waitMs = limiter.download.consumeWithDebt(bytes)
  if waitMs > 0:
    await cpsSleep(waitMs)

proc updateLimits*(limiter: BandwidthLimiter, uploadBps: int = 0,
                   downloadBps: int = 0, percent: int = 0) =
  ## Update rate limits at runtime (e.g., user changes settings).
  ## Pass 0 for any parameter to leave it unchanged.
  ## Pass -1 for uploadBps/downloadBps to disable that limit.
  let oldPct = limiter.percent
  let pct = if percent > 0: clamp(percent, 1, 100) else: oldPct
  # Recover original bandwidth from current rate before updating percent
  if uploadBps != 0:
    let bps = if uploadBps < 0: 0 else: uploadBps
    limiter.upload = initTokenBucket(bps, pct)
  elif percent > 0 and limiter.upload.rate > 0:
    # Percent changed but bandwidth unchanged — recover original bps from old percent
    let originalBps = int(limiter.upload.rate * 100.0 / float(oldPct))
    limiter.upload = initTokenBucket(originalBps, pct)
  if downloadBps != 0:
    let bps = if downloadBps < 0: 0 else: downloadBps
    limiter.download = initTokenBucket(bps, pct)
  elif percent > 0 and limiter.download.rate > 0:
    let originalBps = int(limiter.download.rate * 100.0 / float(oldPct))
    limiter.download = initTokenBucket(originalBps, pct)
  limiter.percent = pct
