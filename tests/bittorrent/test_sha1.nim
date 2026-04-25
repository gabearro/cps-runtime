## Tests for SHA1 implementation.

import std/strutils
import cps/bittorrent/sha1

# Known test vectors from FIPS 180-4
block testEmptyString:
  let hash = sha1Hex("")
  assert hash == "da39a3ee5e6b4b0d3255bfef95601890afd80709", "empty: " & hash
  echo "PASS: SHA1 empty string"

block testAbc:
  let hash = sha1Hex("abc")
  assert hash == "a9993e364706816aba3e25717850c26c9cd0d89d", "abc: " & hash
  echo "PASS: SHA1 'abc'"

block testLonger:
  let hash = sha1Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
  assert hash == "84983e441c3bd26ebaae4aa1f95129e5e54670f1", "long: " & hash
  echo "PASS: SHA1 longer message"

block testBinaryData:
  # Test with binary data (all byte values 0-255)
  var data = ""
  for i in 0 ..< 256:
    data.add(char(i))
  let hash = sha1(data)
  assert hash.len == 20
  # Just verify it runs without error and produces consistent results
  let hash2 = sha1(data)
  assert hash == hash2
  echo "PASS: SHA1 binary data"

block testLargeData:
  # 1MB of data
  var data = newString(1048576)
  for i in 0 ..< data.len:
    data[i] = char(i mod 256)
  let hash = sha1(data)
  let hash2 = sha1(data)
  assert hash == hash2
  echo "PASS: SHA1 large data consistency"

block testHexOutput:
  let hex = sha1Hex("test")
  assert hex.len == 40
  for c in hex:
    assert c in {'0'..'9', 'a'..'f'}
  echo "PASS: SHA1 hex output format"

echo "ALL SHA1 TESTS PASSED"
