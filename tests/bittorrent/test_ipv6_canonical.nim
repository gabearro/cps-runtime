## Tests for IPv6 address canonicalization.

import cps/bittorrent/utils

block test_already_compressed:
  assert canonicalizeIpv6("::1") == "::1"
  echo "PASS: already compressed ::1"

block test_fully_expanded:
  assert canonicalizeIpv6("2001:0db8:0000:0000:0000:0000:0000:0001") == "2001:db8::1"
  echo "PASS: fully expanded -> compressed"

block test_partially_compressed:
  assert canonicalizeIpv6("2001:db8:0:0:0:0:0:1") == "2001:db8::1"
  echo "PASS: partially compressed -> compressed"

block test_all_zeros:
  assert canonicalizeIpv6("0:0:0:0:0:0:0:0") == "::"
  echo "PASS: all zeros -> ::"

block test_loopback:
  assert canonicalizeIpv6("0:0:0:0:0:0:0:1") == "::1"
  echo "PASS: loopback"

block test_no_double_colon_needed:
  # Only one zero group — no :: compression (RFC 5952: must be >= 2 consecutive)
  assert canonicalizeIpv6("2001:db8:0:1:2:3:4:5") == "2001:db8:0:1:2:3:4:5"
  echo "PASS: single zero group - no compression"

block test_leading_zeros_stripped:
  assert canonicalizeIpv6("2001:0db8:0001:0000:0000:0000:0000:0001") == "2001:db8:1::1"
  echo "PASS: leading zeros stripped"

block test_uppercase_input:
  assert canonicalizeIpv6("2001:0DB8:0000:0000:0000:0000:0000:0001") == "2001:db8::1"
  echo "PASS: uppercase input -> lowercase output"

block test_already_compressed_complex:
  assert canonicalizeIpv6("fe80::1") == "fe80::1"
  echo "PASS: already compressed fe80::1"

block test_ipv4_passthrough:
  assert canonicalizeIpv6("192.168.1.1") == "192.168.1.1"
  echo "PASS: IPv4 passthrough"

block test_two_zero_runs_longest_wins:
  # 2001:db8:0:0:1:0:0:0 -> longest run is at end (3 zeros)
  assert canonicalizeIpv6("2001:db8:0:0:1:0:0:0") == "2001:db8:0:0:1::"
  echo "PASS: two zero runs - longest wins"

block test_equal_zero_runs_first_wins:
  # 2001:0:0:1:0:0:2:3 -> two equal runs of 2, first one wins (RFC 5952 section 4.2.3)
  let result = canonicalizeIpv6("2001:0:0:1:0:0:2:3")
  assert result == "2001::1:0:0:2:3"
  echo "PASS: equal zero runs - first wins"

echo "ALL IPV6 CANONICALIZATION TESTS PASSED"
