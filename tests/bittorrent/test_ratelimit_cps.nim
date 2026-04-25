## Test that the CPS-based bandwidth limiter actually mutates the shared bucket.
## This verifies that consumeWithDebt's `var TokenBucket` parameter works
## correctly when called from within a CPS proc (through env.limiter.buckets[dir]).

import std/[monotimes, times]
import cps/runtime
import cps/transform
import cps/eventloop
import cps/bittorrent/ratelimit

# ============================================================
# Test 1: consume modifies the shared bucket through CPS
# ============================================================

block test_cps_consume_mutates_bucket:
  let limiter = newBandwidthLimiter(downloadBps = 100_000, percent = 100)
  # capacity = clamp(100000 * 0.25, 16384, 4MiB) = 25000
  let initialTokens = limiter.buckets[Download].tokens
  assert initialTokens == 25000.0,
    "initial tokens: " & $initialTokens

  proc drainBucket(): CpsVoidFuture {.cps.} =
    await limiter.consume(25000, Download)

  runCps(drainBucket())

  let afterTokens = limiter.buckets[Download].tokens
  assert afterTokens <= 100.0,
    "FAIL: tokens should be ~0 after consume(25000), got " & $afterTokens &
    " — consume did NOT mutate the shared bucket!"
  echo "PASS: CPS consume mutates shared bucket (tokens: " & $afterTokens & ")"

# ============================================================
# Test 2: consume goes into debt through CPS
# ============================================================

block test_cps_consume_debt:
  let limiter = newBandwidthLimiter(downloadBps = 100_000, percent = 100)

  proc goIntoDebt(): CpsVoidFuture {.cps.} =
    await limiter.consume(25000, Download)
    await limiter.consume(10000, Download)

  runCps(goIntoDebt())

  let afterTokens = limiter.buckets[Download].tokens
  # With 10000 bytes debt at 100000 bytes/sec, sleep is ~100ms
  # After sleep, refill recovers tokens close to 0
  assert afterTokens <= 1000.0,
    "FAIL: expected debt or near-zero tokens, got " & $afterTokens
  echo "PASS: CPS consume creates debt correctly (tokens: " & $afterTokens & ")"

# ============================================================
# Test 3: multiple CPS procs share the same bucket
# ============================================================

block test_cps_shared_limiter:
  let limiter = newBandwidthLimiter(downloadBps = 100_000, percent = 100)

  proc consumer1(): CpsVoidFuture {.cps.} =
    await limiter.consume(15000, Download)

  proc consumer2(): CpsVoidFuture {.cps.} =
    await limiter.consume(15000, Download)

  runCps(consumer1())
  let after1 = limiter.buckets[Download].tokens
  assert after1 <= 11000.0 and after1 >= 9000.0,
    "FAIL: after consumer1, expected ~10000, got " & $after1

  runCps(consumer2())
  let after2 = limiter.buckets[Download].tokens
  assert after2 < 1000.0,
    "FAIL: after consumer2, expected negative or near-zero, got " & $after2
  echo "PASS: CPS shared limiter works across procs (after1: " & $after1 &
    ", after2: " & $after2 & ")"

# ============================================================
# Test 4: waitForBudget blocks when in debt
# ============================================================

block test_cps_waitForBudget:
  let limiter = newBandwidthLimiter(downloadBps = 100_000, percent = 100)
  limiter.buckets[Download].tokens = -5000.0

  proc waitAndCheck(): CpsVoidFuture {.cps.} =
    await limiter.waitForBudget(Download)

  let start = getMonoTime()
  runCps(waitAndCheck())
  let elapsed = (getMonoTime() - start).inMilliseconds

  # With -5000 debt at 100000 rate, wait should be ~50ms
  assert elapsed >= 30,
    "FAIL: waitForBudget should have waited ~50ms, only waited " & $elapsed & "ms"
  echo "PASS: waitForBudget blocks when in debt (waited " & $elapsed & "ms)"

# ============================================================
# Test 5: consume() repays large debt across multiple sleep intervals
# ============================================================

block test_cps_consume_large_debt_waits_full_duration:
  ## Regression test: consume() must continue waiting when debt requires
  ## more than MaxSleepMs (1s). A single capped sleep is insufficient.
  let limiter = newBandwidthLimiter(downloadBps = 50_000, percent = 100)

  proc oneBigConsume(): CpsVoidFuture {.cps.} =
    # Initial burst is MinBurstBytes (16 KiB) at this rate.
    # Consuming 80 KiB creates ~63.6 KiB debt => ~1.27s wait.
    await limiter.consume(80_000, Download)

  let start = getMonoTime()
  runCps(oneBigConsume())
  let elapsedMs = (getMonoTime() - start).inMilliseconds

  assert elapsedMs >= 1150,
    "FAIL: large-debt consume returned too early (" & $elapsedMs & "ms)"
  assert elapsedMs <= 3000,
    "FAIL: large-debt consume waited unexpectedly long (" & $elapsedMs & "ms)"
  echo "PASS: consume waits for full large-debt repayment (" & $elapsedMs & "ms)"

# ============================================================
# Test 6: unlimited limiter is a no-op
# ============================================================

block test_cps_unlimited:
  let limiter = newBandwidthLimiter(downloadBps = 0, percent = 80)

  proc consumeUnlimited(): CpsVoidFuture {.cps.} =
    await limiter.consume(1_000_000, Download)

  let start = getMonoTime()
  runCps(consumeUnlimited())
  let elapsed = (getMonoTime() - start).inMilliseconds

  assert elapsed < 5,
    "FAIL: unlimited consume should be instant, took " & $elapsed & "ms"
  echo "PASS: unlimited limiter is no-op"

# ============================================================
# Test 7: measure actual throughput with rate limit
# ============================================================

block test_throughput:
  let rateBps = 200_000  # 200 KB/s
  let limiter = newBandwidthLimiter(downloadBps = rateBps, percent = 100)
  var totalBytes = 0
  let blockSize = 16384

  proc downloadLoop(): CpsVoidFuture {.cps.} =
    var i = 0
    while i < 30:
      await limiter.waitForBudget(Download)
      await limiter.consume(blockSize, Download)
      totalBytes += blockSize
      i += 1

  let start = getMonoTime()
  runCps(downloadLoop())
  let elapsed = (getMonoTime() - start).inMilliseconds.float / 1000.0

  let actualRate = float(totalBytes) / elapsed
  let expectedRate = float(rateBps)

  let ratio = actualRate / expectedRate
  echo "  Rate limit: " & $rateBps & " B/s"
  echo "  Transferred: " & $totalBytes & " bytes in " & $elapsed & "s"
  echo "  Actual rate: " & $(int(actualRate)) & " B/s"
  echo "  Ratio (actual/expected): " & $ratio
  assert ratio < 2.0,
    "FAIL: actual rate " & $int(actualRate) &
    " is more than 2x the limit " & $rateBps
  assert ratio > 0.3,
    "FAIL: actual rate " & $int(actualRate) &
    " is less than 30% of the limit " & $rateBps
  echo "PASS: throughput is within expected range"

# ============================================================
# Test 8: high-rate throughput (100 MiB/s) — verifies no
# artificial ceiling from sleep rounding at high rates
# ============================================================

block test_high_rate_throughput:
  let rateBps = 100 * 1024 * 1024  # 100 MiB/s
  let limiter = newBandwidthLimiter(downloadBps = rateBps, percent = 80)
  var totalBytes = 0
  let blockSize = 16384

  proc downloadLoop(): CpsVoidFuture {.cps.} =
    var i = 0
    while i < 500:
      await limiter.waitForBudget(Download)
      await limiter.consume(blockSize, Download)
      totalBytes += blockSize
      i += 1

  let start = getMonoTime()
  runCps(downloadLoop())
  let elapsed = (getMonoTime() - start).inMilliseconds.float / 1000.0
  let effectiveRate = float(rateBps) * 0.80
  let actualRate = float(totalBytes) / elapsed
  let ratio = actualRate / effectiveRate

  echo "  Rate limit: " & $rateBps & " B/s (80% = " & $int(effectiveRate) & " B/s)"
  echo "  Transferred: " & $totalBytes & " bytes in " & $elapsed & "s"
  echo "  Actual rate: " & $(int(actualRate)) & " B/s (" &
    $(int(actualRate.float / (1024*1024))) & " MiB/s)"
  echo "  Ratio (actual/effective): " & $ratio
  # Must exceed 50% of effective rate — old code hit ~19% due to 1ms sleep floor
  assert ratio > 0.5,
    "FAIL: actual rate " & $int(actualRate) & " B/s is less than 50% of effective " &
    $int(effectiveRate) & " B/s — sleep rounding still capping throughput"
  assert ratio < 5.0,
    "FAIL: actual rate " & $int(actualRate) & " B/s is more than 5x effective rate"
  echo "PASS: high-rate throughput within expected range"

# ============================================================
# Test 9: pre-consume + refund pattern
# ============================================================

block test_preconsume_refund:
  ## Simulates the readLoop pattern: pre-consume an estimate, then
  ## refund the difference. Net effect should match actual bytes.
  let limiter = newBandwidthLimiter(downloadBps = 100_000, percent = 100)
  let initialTokens = limiter.buckets[Download].tokens
  let estimate = 16397  # BlockSize + 13
  let actualBytes = 5  # e.g., a small control message

  proc preConsumeAndRefund(): CpsVoidFuture {.cps.} =
    await limiter.consume(estimate, Download)
    limiter.refund(estimate - actualBytes, Download)

  runCps(preConsumeAndRefund())

  let afterTokens = limiter.buckets[Download].tokens
  # Net deduction should be ~actualBytes (+ small refill from elapsed time)
  let netDeducted = initialTokens - afterTokens
  assert netDeducted >= float(actualBytes) - 100.0 and
         netDeducted <= float(actualBytes) + 100.0,
    "FAIL: net deduction should be ~" & $actualBytes &
    ", got " & $netDeducted
  echo "PASS: pre-consume + refund nets to actual bytes (deducted: " &
    $int(netDeducted) & ")"

# ============================================================
# Test 10: pre-consume with underestimate charges extra
# ============================================================

block test_preconsume_underestimate:
  ## When actual bytes exceed the estimate, the extra is consumed.
  let limiter = newBandwidthLimiter(downloadBps = 100_000, percent = 100)
  let initialTokens = limiter.buckets[Download].tokens
  let estimate = 16397
  let actualBytes = 20000  # Larger than estimate (e.g., bitfield)

  proc preConsumeUnderestimate(): CpsVoidFuture {.cps.} =
    await limiter.consume(estimate, Download)
    let diff: int = estimate - actualBytes
    if diff > 0:
      limiter.refund(diff, Download)
    elif diff < 0:
      await limiter.consume(-diff, Download)

  runCps(preConsumeUnderestimate())

  let afterTokens = limiter.buckets[Download].tokens
  let netDeducted = initialTokens - afterTokens
  assert netDeducted >= float(actualBytes) - 100.0 and
         netDeducted <= float(actualBytes) + 100.0,
    "FAIL: net deduction should be ~" & $actualBytes &
    ", got " & $netDeducted
  echo "PASS: pre-consume underestimate charges extra (deducted: " &
    $int(netDeducted) & ")"

echo ""
echo "All CPS rate limiter integration tests passed!"
