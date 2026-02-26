## Tests for CPS IRC SASL Authentication

import cps/irc/sasl
import std/[base64, strutils]

# ============================================================
# Test: SASL PLAIN
# ============================================================

block testSaslPlain:
  let mech = newSaslPlain("testuser", "testpass")
  assert mech.name == "PLAIN"

  # Process the "+" challenge (server ready)
  let result = mech.processChallenge("+")
  assert not result.failed, "PLAIN should not fail: " & result.errorMsg
  assert result.finished, "PLAIN should complete in one step"
  assert result.response.len > 0

  # Verify the payload
  let decoded = base64.decode(result.response)
  assert decoded == "\0testuser\0testpass", "Decoded: " & repr(decoded)

  # Second call should fail
  let result2 = mech.processChallenge("+")
  assert result2.failed, "Should fail on second attempt"

  echo "PASS: SASL PLAIN"

# ============================================================
# Test: SASL EXTERNAL
# ============================================================

block testSaslExternal:
  # Without authzid
  let mech1 = newSaslExternal()
  assert mech1.name == "EXTERNAL"
  let r1 = mech1.processChallenge("+")
  assert not r1.failed
  assert r1.finished
  assert r1.response == "+", "Empty auth → '+', got: " & r1.response

  # With authzid
  let mech2 = newSaslExternal("admin")
  let r2 = mech2.processChallenge("+")
  assert not r2.failed
  assert r2.finished
  let decoded = base64.decode(r2.response)
  assert decoded == "admin", "Expected admin, got: " & decoded

  echo "PASS: SASL EXTERNAL"

# ============================================================
# Test: SCRAM-SHA-256 client-first message format
# ============================================================

block testScramClientFirst:
  let mech = newSaslScramSha256("user", "pencil")
  assert mech.name == "SCRAM-SHA-256"

  let r1 = mech.processChallenge("+")
  assert not r1.failed, "Step 1 should not fail: " & r1.errorMsg
  assert not r1.finished, "Step 1 should not be finished"
  assert r1.response.len > 0

  # Decode and verify format: n,,n=user,r=<nonce>
  let decoded = base64.decode(r1.response)
  assert decoded.startsWith("n,,n=user,r="), "Format: " & decoded

  echo "PASS: SCRAM-SHA-256 client-first message"

# ============================================================
# Test: SCRAM-SHA-256 username escaping
# ============================================================

block testScramUsernameEscaping:
  let mech = newSaslScramSha256("user=name,special", "pass")
  let r = mech.processChallenge("+")
  let decoded = base64.decode(r.response)
  assert decoded.contains("n=user=3Dname=2Cspecial"), "Escaped username: " & decoded

  echo "PASS: SCRAM-SHA-256 username escaping"

# ============================================================
# Test: SCRAM-SHA-256 full exchange (RFC 7677 test vector)
# ============================================================

block testScramFullExchange:
  # RFC 7677 test vector (adapted)
  # We can't replicate exact nonces, but we can verify the structure works
  let mech = newSaslScramSha256("user", "pencil")

  # Step 1: client-first
  let r1 = mech.processChallenge("+")
  assert not r1.failed, "Step 1 failed: " & r1.errorMsg
  assert not r1.finished

  # Step 2: simulate server-first-message
  # We need to create a valid server response with the client's nonce
  let decoded1 = base64.decode(r1.response)
  let clientNonce = decoded1.split("r=")[1]

  # Construct server-first with known salt and iterations
  let serverNonce = clientNonce & "server_extension"
  let salt = base64.encode("randomsalt")
  let serverFirst = "r=" & serverNonce & ",s=" & salt & ",i=4096"
  let serverFirstB64 = base64.encode(serverFirst)

  let r2 = mech.processChallenge(serverFirstB64)
  assert not r2.failed, "Step 2 failed: " & r2.errorMsg
  assert not r2.finished, "Step 2 should not be final"
  assert r2.response.len > 0

  # Verify client-final format
  let decoded2 = base64.decode(r2.response)
  assert decoded2.startsWith("c=biws,r=" & serverNonce), "Client-final format: " & decoded2
  assert decoded2.contains(",p="), "Should contain proof"

  echo "PASS: SCRAM-SHA-256 full exchange"

# ============================================================
# Test: SCRAM-SHA-256 server nonce verification
# ============================================================

block testScramNonceVerification:
  let mech = newSaslScramSha256("user", "pass")
  let r1 = mech.processChallenge("+")
  let decoded = base64.decode(r1.response)
  let clientNonce = decoded.split("r=")[1]

  # Server nonce that DOESN'T start with client nonce → should fail
  let badServerFirst = "r=totally_different_nonce,s=" & base64.encode("salt") & ",i=4096"
  let r2 = mech.processChallenge(base64.encode(badServerFirst))
  assert r2.failed, "Should fail with mismatched nonce"
  assert r2.errorMsg.contains("nonce"), "Error should mention nonce: " & r2.errorMsg

  echo "PASS: SCRAM-SHA-256 nonce verification"

# ============================================================
# Test: Mechanism selection
# ============================================================

block testMechanismSelection:
  # Prefers SCRAM-SHA-256 over PLAIN
  let m1 = selectBestMechanism(@["PLAIN", "SCRAM-SHA-256", "EXTERNAL"], "user", "pass")
  assert m1.name == "SCRAM-SHA-256"

  # Falls back to PLAIN if SCRAM not available
  let m2 = selectBestMechanism(@["PLAIN", "EXTERNAL"], "user", "pass")
  assert m2.name == "PLAIN"

  # External when nothing else
  let m3 = selectBestMechanism(@["EXTERNAL"], "user", "pass")
  assert m3.name == "EXTERNAL"

  # Unknown → PLAIN fallback
  let m4 = selectBestMechanism(@["UNKNOWN"], "user", "pass")
  assert m4.name == "PLAIN"

  echo "PASS: Mechanism selection"

# ============================================================
# Test: Generic dispatch
# ============================================================

block testGenericDispatch:
  # Create as base type, dispatch should work
  let mech: SaslMechanism = newSaslPlain("u", "p")
  let r = processChallenge(mech, "+")
  assert not r.failed
  assert r.finished
  let decoded = base64.decode(r.response)
  assert decoded == "\0u\0p"

  echo "PASS: Generic SASL dispatch"

echo "All SASL tests passed!"
