## Tests for the global bandwidth rate limiter.

import std/[monotimes, times]
import cps/bittorrent/ratelimit

# === TokenBucket ===

block test_unlimited_bucket:
  ## Rate 0 means unlimited — consumeWithDebt always returns 0.
  var bucket = TokenBucket(tokens: 0, capacity: 0, rate: 0, baseBps: 0)
  assert bucket.consumeWithDebt(1_000_000) == 0, "unlimited always succeeds"
  echo "PASS: unlimited bucket"

block test_bucket_initial_full:
  ## A fresh bucket starts full and can consume up to capacity.
  var bucket = initTokenBucket(100_000, 100)  # 100 KB/s at 100%
  assert bucket.rate == 100_000.0
  assert bucket.tokens == bucket.capacity
  assert bucket.baseBps == 100_000
  # Consume within capacity — no wait
  assert bucket.consumeWithDebt(int(bucket.capacity)) == 0
  echo "PASS: bucket initial full"

block test_bucket_deficit_returns_wait:
  ## When tokens are insufficient, consumeWithDebt returns wait ms.
  var bucket = initTokenBucket(10_000, 100)  # 10 KB/s
  # Drain the bucket
  discard bucket.consumeWithDebt(int(bucket.capacity))
  # Now consume more — should return wait time (tokens go negative)
  let waitMs = bucket.consumeWithDebt(5_000)
  assert waitMs > 0, "should wait: " & $waitMs
  # 5000 bytes at 10000 bytes/sec = 0.5 sec = 500ms
  assert waitMs >= 400 and waitMs <= 600,
    "wait ~500ms: " & $waitMs
  echo "PASS: bucket deficit returns wait"

block test_bucket_refill:
  ## After time passes, tokens refill based on rate.
  var bucket = initTokenBucket(100_000, 100)  # 100 KB/s
  # Drain completely
  bucket.tokens = 0
  # Pretend 0.5 seconds have passed
  bucket.lastRefill = getMonoTime() - initDuration(milliseconds = 500)
  bucket.refill()
  # Should have ~50,000 tokens (0.5s * 100,000 bytes/s), capped at capacity
  let expected = min(bucket.capacity, 50_000.0)
  assert bucket.tokens >= expected - 5000 and bucket.tokens <= expected + 5000,
    "refilled ~" & $expected & ": " & $bucket.tokens
  echo "PASS: bucket refill"

block test_bucket_refill_caps_at_capacity:
  ## Tokens never exceed capacity even after long idle.
  var bucket = initTokenBucket(100_000, 100)
  bucket.tokens = 0
  bucket.lastRefill = getMonoTime() - initDuration(seconds = 100)
  bucket.refill()
  assert bucket.tokens == bucket.capacity,
    "capped at capacity: " & $bucket.tokens
  echo "PASS: bucket refill caps at capacity"

# === Percentage-based limiting ===

block test_percentage_50:
  ## 50% of 1 MB/s = 500 KB/s effective rate.
  let limiter = newBandwidthLimiter(uploadBps = 1_000_000, percent = 50)
  assert limiter.effectiveRate(Upload) == 500_000.0,
    "50% of 1MB/s: " & $limiter.effectiveRate(Upload)
  echo "PASS: percentage 50%"

block test_percentage_80_default:
  ## Default 80% of 10 MB/s = 8 MB/s.
  let limiter = newBandwidthLimiter(
    uploadBps = 10_000_000,
    downloadBps = 100_000_000
  )
  assert limiter.percent == 80
  assert limiter.effectiveRate(Upload) == 8_000_000.0,
    "80% upload: " & $limiter.effectiveRate(Upload)
  assert limiter.effectiveRate(Download) == 80_000_000.0,
    "80% download: " & $limiter.effectiveRate(Download)
  echo "PASS: percentage 80% default"

block test_percentage_clamped:
  ## Percent clamped to [1, 100].
  let limiter1 = newBandwidthLimiter(uploadBps = 1000, percent = 0)
  assert limiter1.percent == 1  # Clamped to 1

  let limiter2 = newBandwidthLimiter(uploadBps = 1000, percent = 200)
  assert limiter2.percent == 100  # Clamped to 100
  echo "PASS: percentage clamped"

block test_unlimited_when_zero:
  ## uploadBps=0 means unlimited.
  let limiter = newBandwidthLimiter(uploadBps = 0, downloadBps = 0)
  assert not limiter.isLimited(Upload)
  assert not limiter.isLimited(Download)
  assert limiter.effectiveRate(Upload) == 0.0
  echo "PASS: unlimited when zero"

block test_mixed_limits:
  ## Upload limited, download unlimited.
  let limiter = newBandwidthLimiter(uploadBps = 500_000, downloadBps = 0, percent = 60)
  assert limiter.isLimited(Upload)
  assert not limiter.isLimited(Download)
  assert limiter.effectiveRate(Upload) == 300_000.0,
    "60% of 500KB/s: " & $limiter.effectiveRate(Upload)
  echo "PASS: mixed limits"

# === Runtime update ===

block test_update_limits_percent:
  ## Changing percent recalculates rates using stored baseBps.
  let limiter = newBandwidthLimiter(uploadBps = 1_000_000, percent = 80)
  assert limiter.effectiveRate(Upload) == 800_000.0
  assert limiter.buckets[Upload].baseBps == 1_000_000

  limiter.updateLimits(percent = 50)
  assert limiter.percent == 50
  assert limiter.effectiveRate(Upload) == 500_000.0,
    "updated to 50%: " & $limiter.effectiveRate(Upload)
  echo "PASS: update limits percent"

block test_update_limits_bandwidth:
  ## Changing bandwidth recalculates rates.
  let limiter = newBandwidthLimiter(uploadBps = 1_000_000, percent = 80)
  limiter.updateLimits(uploadBps = 2_000_000)
  assert limiter.effectiveRate(Upload) == 1_600_000.0,
    "updated bandwidth: " & $limiter.effectiveRate(Upload)
  echo "PASS: update limits bandwidth"

block test_update_limits_disable:
  ## Passing -1 disables the limit.
  let limiter = newBandwidthLimiter(uploadBps = 1_000_000, percent = 80)
  assert limiter.isLimited(Upload)
  limiter.updateLimits(uploadBps = -1)
  assert not limiter.isLimited(Upload)
  echo "PASS: update limits disable"

# === Burst size ===

block test_burst_minimum:
  ## Even at very low rates, burst capacity is at least MinBurstBytes.
  let limiter = newBandwidthLimiter(uploadBps = 100, percent = 100)  # 100 B/s
  assert limiter.buckets[Upload].capacity >= MinBurstBytes.float,
    "burst at least MinBurstBytes: " & $limiter.buckets[Upload].capacity
  echo "PASS: burst minimum"

block test_burst_maximum:
  ## At high rates, burst is capped at MaxBurstBytes.
  let limiter = newBandwidthLimiter(uploadBps = 10_000_000, percent = 100)  # 10 MB/s
  assert limiter.buckets[Upload].capacity == MaxBurstBytes.float,
    "burst capped at MaxBurstBytes: " & $limiter.buckets[Upload].capacity
  echo "PASS: burst maximum"

# === Direction enum ===

block test_direction_enum:
  ## Direction enum indexes buckets correctly.
  let limiter = newBandwidthLimiter(uploadBps = 500_000, downloadBps = 1_000_000, percent = 100)
  assert limiter.effectiveRate(Upload) == 500_000.0
  assert limiter.effectiveRate(Download) == 1_000_000.0
  assert limiter.isLimited(Upload)
  assert limiter.isLimited(Download)
  echo "PASS: direction enum"

# === Consume with debt semantics ===

block test_consume_with_debt_deducts:
  ## consumeWithDebt deducts tokens unconditionally.
  var bucket = initTokenBucket(100_000, 100)
  let before = bucket.tokens
  let waitMs = bucket.consumeWithDebt(10_000)
  assert waitMs == 0, "no wait within budget"
  assert bucket.tokens < before
  echo "PASS: consume with debt deducts"

block test_consume_with_debt_goes_negative:
  ## consumeWithDebt can make tokens negative and returns sleep time.
  var bucket = initTokenBucket(100_000, 100)
  bucket.tokens = 100
  let waitMs = bucket.consumeWithDebt(1000)
  assert bucket.tokens < 0, "tokens went negative: " & $bucket.tokens
  assert waitMs > 0, "returns positive wait time"
  echo "PASS: consume with debt goes negative"

# === Refund ===

block test_refund_returns_tokens:
  ## refund adds tokens back to the bucket.
  let limiter = newBandwidthLimiter(downloadBps = 100_000, percent = 100)
  let before = limiter.buckets[Download].tokens
  discard limiter.buckets[Download].consumeWithDebt(10_000)
  let afterConsume = limiter.buckets[Download].tokens
  limiter.refund(5_000, Download)
  let afterRefund = limiter.buckets[Download].tokens
  assert afterRefund > afterConsume, "refund increased tokens"
  assert afterRefund - afterConsume == 5000.0,
    "refund exact amount: " & $(afterRefund - afterConsume)
  echo "PASS: refund returns tokens"

block test_refund_zero_or_negative_noop:
  ## refund(0) or refund(negative) is a no-op.
  let limiter = newBandwidthLimiter(downloadBps = 100_000, percent = 100)
  let before = limiter.buckets[Download].tokens
  limiter.refund(0, Download)
  assert limiter.buckets[Download].tokens == before, "refund(0) is no-op"
  limiter.refund(-100, Download)
  assert limiter.buckets[Download].tokens == before, "refund(negative) is no-op"
  echo "PASS: refund zero or negative is no-op"

block test_refund_unlimited_noop:
  ## refund on unlimited bucket is a no-op.
  let limiter = newBandwidthLimiter(downloadBps = 0, percent = 80)
  limiter.refund(10_000, Download)
  # No crash, tokens stay at 0
  assert limiter.buckets[Download].tokens == 0.0
  echo "PASS: refund unlimited is no-op"

block test_refund_nil_noop:
  ## refund on nil limiter is safe.
  var limiter: BandwidthLimiter = nil
  limiter.refund(10_000, Download)  # Should not crash
  echo "PASS: refund nil is no-op"

echo ""
echo "All rate limiter tests passed!"
