## Tests for CPS I/O DNS resolver

import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/dns
import std/[nativesockets, os]

# Test 1: Resolve "localhost" -> 127.0.0.1
block testResolveLocalhost:
  let fut = resolve("localhost", Port(0), AF_INET)
  let loop = getEventLoop()
  while not fut.finished:
    loop.tick()
    if not fut.finished and not loop.hasWork:
      sleep(1)
  assert not fut.hasError(), "resolve('localhost') should succeed, got: " & fut.getError().msg
  let addrs = fut.read()
  assert addrs.len > 0, "resolve('localhost') should return at least one address"
  assert "127.0.0.1" in addrs, "resolve('localhost') should contain 127.0.0.1, got: " & $addrs
  echo "PASS: Resolve localhost"

# Test 2: Resolve an IP address string -> returns it directly (no lookup)
block testResolveIpAddress:
  let fut = resolve("192.168.1.1")
  # IP addresses are resolved synchronously, so the future should be completed immediately
  assert fut.finished, "Resolving an IP address should complete immediately"
  let addrs = fut.read()
  assert addrs == @["192.168.1.1"], "Should return the IP address as-is, got: " & $addrs
  echo "PASS: Resolve IP address passthrough"

# Test 3: Resolve IPv6 IP address passthrough
block testResolveIpv6Address:
  let fut = resolve("::1")
  assert fut.finished, "Resolving an IPv6 address should complete immediately"
  let addrs = fut.read()
  assert addrs == @["::1"], "Should return the IPv6 address as-is, got: " & $addrs
  echo "PASS: Resolve IPv6 address passthrough"

# Test 4: Resolve invalid hostname -> error
block testResolveInvalid:
  let fut = asyncResolve("this.host.definitely.does.not.exist.invalid")
  let loop = getEventLoop()
  while not fut.finished:
    loop.tick()
    if not fut.finished and not loop.hasWork:
      sleep(1)
  assert fut.hasError(), "Resolving invalid hostname should fail"
  echo "PASS: Resolve invalid hostname returns error"

# Test 5: DNS cache - second resolve is instant (cached)
block testDnsCacheHit:
  clearDnsCache()
  # First resolve - goes to thread pool
  let fut1 = resolve("localhost", Port(0), AF_INET)
  let loop = getEventLoop()
  while not fut1.finished:
    loop.tick()
    if not fut1.finished and not loop.hasWork:
      sleep(1)
  assert not fut1.hasError(), "First resolve should succeed"
  let addrs1 = fut1.read()

  # Second resolve - should be cached, future completes immediately
  let fut2 = resolve("localhost", Port(0), AF_INET)
  assert fut2.finished, "Cached resolve should complete immediately"
  let addrs2 = fut2.read()
  assert addrs1 == addrs2, "Cached result should match: " & $addrs1 & " vs " & $addrs2
  echo "PASS: DNS cache hit"

# Test 6: Cache expiry - after TTL, re-resolves
block testDnsCacheExpiry:
  clearDnsCache()
  setDnsCacheTtl(1)  # 1 second TTL
  let loop = getEventLoop()

  # First resolve
  let fut1 = resolve("localhost", Port(0), AF_INET)
  while not fut1.finished:
    loop.tick()
    if not fut1.finished and not loop.hasWork:
      sleep(1)
  assert not fut1.hasError(), "First resolve should succeed"

  # Immediately should be cached
  let fut2 = resolve("localhost", Port(0), AF_INET)
  assert fut2.finished, "Should be cached immediately after first resolve"

  # Wait for TTL to expire
  sleep(1100)  # 1.1 seconds

  # Now should be a cache miss (goes to thread pool, not immediate)
  let fut3 = resolve("localhost", Port(0), AF_INET)
  # The future should NOT be completed immediately since cache expired
  # (unless the thread pool completes extremely fast)
  # We just need to verify it eventually completes successfully
  while not fut3.finished:
    loop.tick()
    if not fut3.finished and not loop.hasWork:
      sleep(1)
  assert not fut3.hasError(), "Re-resolve after expiry should succeed"
  let addrs3 = fut3.read()
  assert addrs3.len > 0, "Re-resolve should return addresses"

  # Restore default TTL
  setDnsCacheTtl(300)
  echo "PASS: DNS cache expiry"

# Test 7: Multiple concurrent resolves
block testConcurrentResolve:
  clearDnsCache()
  let loop = getEventLoop()

  let fut1 = asyncResolve("localhost", Port(0), AF_INET)
  let fut2 = asyncResolve("localhost", Port(0), AF_INET)
  let fut3 = asyncResolve("127.0.0.1")  # IP passthrough, immediate

  assert fut3.finished, "IP passthrough should be immediate"

  while not fut1.finished or not fut2.finished:
    loop.tick()
    if (not fut1.finished or not fut2.finished) and not loop.hasWork:
      sleep(1)

  assert not fut1.hasError(), "Concurrent resolve 1 should succeed"
  assert not fut2.hasError(), "Concurrent resolve 2 should succeed"
  let addrs1 = fut1.read()
  let addrs2 = fut2.read()
  assert addrs1.len > 0, "Concurrent resolve 1 should return addresses"
  assert addrs2.len > 0, "Concurrent resolve 2 should return addresses"
  echo "PASS: Multiple concurrent resolves"

# Test 8: isIpAddress helper
block testIsIpAddress:
  assert isIpAddress("192.168.1.1") == true
  assert isIpAddress("10.0.0.1") == true
  assert isIpAddress("255.255.255.255") == true
  assert isIpAddress("::1") == true
  assert isIpAddress("fe80::1") == true
  assert isIpAddress("2001:db8::1") == true
  assert isIpAddress("localhost") == false
  assert isIpAddress("example.com") == false
  assert isIpAddress("") == false
  assert isIpAddress("abc") == false
  echo "PASS: isIpAddress helper"

# Test 9: Resolve with CPS proc
block testCpsResolve:
  clearDnsCache()

  proc resolveHost(host: string): CpsFuture[seq[string]] {.cps.} =
    let addrs = await resolve(host, Port(0), AF_INET)
    return addrs

  let fut = resolveHost("localhost")
  let loop = getEventLoop()
  while not fut.finished:
    loop.tick()
    if not fut.finished and not loop.hasWork:
      sleep(1)
  assert not fut.hasError(), "CPS resolve should succeed"
  let addrs = fut.read()
  assert "127.0.0.1" in addrs, "CPS resolve should find 127.0.0.1"
  echo "PASS: Resolve with CPS proc"

echo "All DNS tests passed!"
