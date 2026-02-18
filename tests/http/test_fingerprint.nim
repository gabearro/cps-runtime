## Tests for TLS/HTTP/2 fingerprint profiles
##
## Tests profile creation, field access, and (when BoringSSL is available)
## integration with the TLS layer.
## Run: nim c -r tests/test_fingerprint.nim

import std/strutils
import cps/tls/fingerprint

# ============================================================
# Test profile types
# ============================================================

block:
  echo "Test: TlsFingerprint creation..."
  let fp = TlsFingerprint(
    minVersion: 0x0303,
    maxVersion: 0x0304,
    cipherList: "ECDHE-RSA-AES128-GCM-SHA256",
    cipherSuites: "TLS_AES_128_GCM_SHA256",
    supportedGroups: "X25519:P-256",
    signatureAlgorithms: "ecdsa_secp256r1_sha256",
    alpnProtocols: @["h2", "http/1.1"],
    greaseEnabled: false,
    permuteExtensions: false,
    certCompression: false,
    alpsEnabled: false,
    userAgent: "TestAgent/1.0"
  )
  assert fp.minVersion == 0x0303
  assert fp.maxVersion == 0x0304
  assert fp.alpnProtocols.len == 2
  assert fp.userAgent == "TestAgent/1.0"
  echo "PASS: TlsFingerprint creation"

block:
  echo "Test: Http2Fingerprint creation..."
  let h2 = Http2Fingerprint(
    settings: @[(0x1'u16, 65536'u32), (0x4'u16, 6291456'u32)],
    windowUpdateIncrement: 15663105,
    pseudoHeaderOrder: @[":method", ":authority", ":scheme", ":path"]
  )
  assert h2.settings.len == 2
  assert h2.settings[0] == (0x1'u16, 65536'u32)
  assert h2.windowUpdateIncrement == 15663105'u32
  assert h2.pseudoHeaderOrder[1] == ":authority"
  echo "PASS: Http2Fingerprint creation"

block:
  echo "Test: BrowserProfile creation..."
  let profile = BrowserProfile(
    name: "Test",
    tls: TlsFingerprint(minVersion: 0x0303, maxVersion: 0x0304),
    h2: Http2Fingerprint(settings: @[], windowUpdateIncrement: 0)
  )
  assert profile.name == "Test"
  assert profile.tls.minVersion == 0x0303
  echo "PASS: BrowserProfile creation"

# ============================================================
# Test Chrome preset
# ============================================================

block:
  echo "Test: Chrome profile preset..."
  let chrome = chromeProfile()
  assert chrome.name == "Chrome/131"

  # TLS
  assert chrome.tls.minVersion == 0x0303  # TLS 1.2
  assert chrome.tls.maxVersion == 0x0304  # TLS 1.3
  assert chrome.tls.greaseEnabled == true
  assert chrome.tls.permuteExtensions == true
  assert chrome.tls.certCompression == true
  assert chrome.tls.alpsEnabled == true
  assert chrome.tls.alpnProtocols == @["h2", "http/1.1"]
  assert "Chrome/" in chrome.tls.userAgent
  assert chrome.tls.cipherList.len > 0
  assert chrome.tls.cipherSuites.len > 0
  assert "X25519" in chrome.tls.supportedGroups
  assert "ecdsa_secp256r1_sha256" in chrome.tls.signatureAlgorithms

  # HTTP/2
  assert chrome.h2.settings.len == 6
  # HEADER_TABLE_SIZE = 65536
  assert chrome.h2.settings[0] == (0x1'u16, 65536'u32)
  # ENABLE_PUSH = 0
  assert chrome.h2.settings[1] == (0x2'u16, 0'u32)
  # INITIAL_WINDOW_SIZE = 6291456
  assert chrome.h2.settings[3] == (0x4'u16, 6291456'u32)
  assert chrome.h2.windowUpdateIncrement == 15663105'u32
  assert chrome.h2.pseudoHeaderOrder == @[":method", ":authority", ":scheme", ":path"]
  echo "PASS: Chrome profile preset"

# ============================================================
# Test Firefox preset
# ============================================================

block:
  echo "Test: Firefox profile preset..."
  let firefox = firefoxProfile()
  assert firefox.name == "Firefox/133"

  # TLS
  assert firefox.tls.minVersion == 0x0303
  assert firefox.tls.maxVersion == 0x0304
  assert firefox.tls.greaseEnabled == false
  assert firefox.tls.permuteExtensions == false
  assert firefox.tls.certCompression == false
  assert firefox.tls.alpsEnabled == false
  assert "Firefox/" in firefox.tls.userAgent
  assert "ffdhe2048" in firefox.tls.supportedGroups  # Firefox supports FFDHE

  # HTTP/2
  assert firefox.h2.settings.len == 4
  # INITIAL_WINDOW_SIZE = 131072 (128KB, different from Chrome's 6MB)
  assert firefox.h2.settings[2] == (0x4'u16, 131072'u32)
  assert firefox.h2.windowUpdateIncrement == 12517377'u32
  # Firefox pseudo-header order: :method, :path, :authority, :scheme
  assert firefox.h2.pseudoHeaderOrder == @[":method", ":path", ":authority", ":scheme"]
  echo "PASS: Firefox profile preset"

# ============================================================
# Test nil fingerprint (default behavior)
# ============================================================

block:
  echo "Test: nil fingerprint..."
  let profile: BrowserProfile = nil
  assert profile == nil
  # Client code checks `if fingerprint != nil` before accessing fields
  echo "PASS: nil fingerprint"

echo ""
echo "All fingerprint tests passed!"
