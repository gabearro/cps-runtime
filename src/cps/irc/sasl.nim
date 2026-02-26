## CPS IRC SASL Authentication
##
## Pluggable SASL mechanism interface with implementations for:
## - PLAIN (RFC 4616)
## - EXTERNAL (RFC 4422)
## - SCRAM-SHA-256 (RFC 7677)
##
## Usage:
##   let mech = newSaslPlain("username", "password")
##   let mech = newSaslExternal()
##   let mech = newSaslScramSha256("username", "password")

import std/[strutils, base64, sysrand]

# ============================================================
# OpenSSL FFI for HMAC-SHA256 and PBKDF2
# ============================================================

# Forward declarations use `pointer` for opaque types to avoid needing headers.
# Linked at link time against libcrypto (Homebrew OpenSSL 3.x or BoringSSL).

proc evpSha256(): pointer {.importc: "EVP_sha256", cdecl.}

proc hmacRaw(evp_md: pointer, key: pointer, key_len: cint,
          data: pointer, data_len: csize_t,
          md: pointer, md_len: ptr cuint): pointer {.importc: "HMAC", cdecl.}

proc pbkdf2HmacRaw(pass: cstring, passlen: cint,
                    salt: pointer, saltlen: cint,
                    iter: cint, digest: pointer,
                    keylen: cint, output: pointer): cint {.importc: "PKCS5_PBKDF2_HMAC", cdecl.}

proc evpDigestRaw(data: pointer, count: csize_t, md: pointer,
                   size: ptr cuint, mdtype: pointer,
                   impl: pointer): cint {.importc: "EVP_Digest", cdecl.}

# ============================================================
# Types
# ============================================================

type
  SaslStepResult* = object
    ## Result of processing a SASL challenge.
    response*: string   ## Base64-encoded response to send
    finished*: bool     ## True if authentication is complete (no more steps)
    failed*: bool       ## True if authentication failed
    errorMsg*: string   ## Error message if failed

  SaslMechanism* = ref object of RootObj
    ## Base type for SASL mechanisms.
    name*: string

  SaslPlain* = ref object of SaslMechanism
    ## SASL PLAIN mechanism (RFC 4616).
    username: string
    password: string
    sent: bool

  SaslExternal* = ref object of SaslMechanism
    ## SASL EXTERNAL mechanism (RFC 4422).
    ## Uses client certificate for authentication.
    authzid: string     ## Authorization identity (usually empty)
    sent: bool

  SaslScramSha256* = ref object of SaslMechanism
    ## SASL SCRAM-SHA-256 mechanism (RFC 7677).
    username: string
    password: string
    step: int           ## 0=initial, 1=sent-client-first, 2=sent-client-final
    clientNonce: string
    serverNonce: string
    salt: string        ## Raw salt bytes
    iterCount: int
    authMessage: string ## Concatenated auth message for signature
    clientFirstBare: string
    serverFirstMsg: string
    saltedPassword: seq[byte]

# ============================================================
# Constructors
# ============================================================

proc newSaslPlain*(username, password: string): SaslPlain =
  SaslPlain(name: "PLAIN", username: username, password: password)

proc newSaslExternal*(authzid: string = ""): SaslExternal =
  SaslExternal(name: "EXTERNAL", authzid: authzid)

proc newSaslScramSha256*(username, password: string): SaslScramSha256 =
  SaslScramSha256(name: "SCRAM-SHA-256", username: username, password: password)

# ============================================================
# Helpers
# ============================================================

proc generateNonce(length: int = 24): string =
  ## Generate a random nonce for SCRAM.
  var bytes = newSeq[byte](length)
  if not urandom(bytes):
    # Fallback: use a simple counter-based approach
    for i in 0 ..< length:
      bytes[i] = byte(i * 37 + 13)
  result = base64.encode(bytes)

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len:
    result[i] = byte(s[i])

proc toString(b: openArray[byte]): string =
  result = newString(b.len)
  for i in 0 ..< b.len:
    result[i] = char(b[i])

proc xorBytes(a, b: openArray[byte]): seq[byte] =
  result = newSeq[byte](a.len)
  for i in 0 ..< a.len:
    result[i] = a[i] xor b[i]

proc hmacSha256(key: openArray[byte], data: openArray[byte]): seq[byte] =
  ## Compute HMAC-SHA-256.
  result = newSeq[byte](32)
  var mdLen: cuint = 32
  discard hmacRaw(evpSha256(), unsafeAddr key[0], cint(key.len),
               unsafeAddr data[0], csize_t(data.len),
               addr result[0], addr mdLen)

proc hmacSha256(key: openArray[byte], data: string): seq[byte] =
  if data.len == 0:
    result = newSeq[byte](32)
    var mdLen: cuint = 32
    var emptyByte: byte = 0
    discard hmacRaw(evpSha256(), unsafeAddr key[0], cint(key.len),
                 addr emptyByte, csize_t(0),
                 addr result[0], addr mdLen)
  else:
    result = hmacSha256(key, toBytes(data))

proc pbkdf2Sha256(password: string, salt: openArray[byte], iterations: int): seq[byte] =
  ## Derive a key using PBKDF2-SHA-256.
  result = newSeq[byte](32)
  let rc = pbkdf2HmacRaw(password.cstring, cint(password.len),
                                unsafeAddr salt[0], cint(salt.len),
                                cint(iterations), evpSha256(),
                                32, addr result[0])
  if rc != 1:
    raise newException(CatchableError, "PBKDF2 failed")

# SCRAM username escaping: '=' → '=3D', ',' → '=2C'
proc scramEscapeUsername(username: string): string =
  result = ""
  for ch in username:
    case ch
    of '=': result.add("=3D")
    of ',': result.add("=2C")
    else: result.add(ch)

# ============================================================
# SASL PLAIN
# ============================================================

proc processChallenge*(mech: SaslPlain, challenge: string): SaslStepResult =
  ## Process a SASL PLAIN challenge.
  ## challenge is the base64-encoded server challenge (usually "+").
  if mech.sent:
    return SaslStepResult(finished: true, failed: true, errorMsg: "Already sent credentials")
  mech.sent = true
  let payload = "\0" & mech.username & "\0" & mech.password
  SaslStepResult(
    response: base64.encode(payload),
    finished: true,
  )

# ============================================================
# SASL EXTERNAL
# ============================================================

proc processChallenge*(mech: SaslExternal, challenge: string): SaslStepResult =
  ## Process a SASL EXTERNAL challenge.
  if mech.sent:
    return SaslStepResult(finished: true, failed: true, errorMsg: "Already sent")
  mech.sent = true
  if mech.authzid.len > 0:
    SaslStepResult(response: base64.encode(mech.authzid), finished: true)
  else:
    SaslStepResult(response: "+", finished: true)

# ============================================================
# SASL SCRAM-SHA-256
# ============================================================

proc processChallenge*(mech: SaslScramSha256, challenge: string): SaslStepResult =
  ## Process a SASL SCRAM-SHA-256 challenge.
  ## Multi-step: client-first → server-first → client-final → server-final.
  case mech.step
  of 0:
    # Step 1: Send client-first-message
    mech.clientNonce = generateNonce()
    let escapedUser = scramEscapeUsername(mech.username)
    mech.clientFirstBare = "n=" & escapedUser & ",r=" & mech.clientNonce
    let clientFirstMsg = "n,," & mech.clientFirstBare
    mech.step = 1
    SaslStepResult(response: base64.encode(clientFirstMsg))

  of 1:
    # Step 2: Process server-first-message, send client-final-message
    try:
      let decoded = base64.decode(challenge)
      mech.serverFirstMsg = decoded

      # Parse server-first-message: r=<nonce>,s=<salt>,i=<iterations>
      var serverNonce = ""
      var saltB64 = ""
      var iterStr = ""
      for part in decoded.split(','):
        if part.startsWith("r="):
          serverNonce = part[2..^1]
        elif part.startsWith("s="):
          saltB64 = part[2..^1]
        elif part.startsWith("i="):
          iterStr = part[2..^1]

      if serverNonce.len == 0 or saltB64.len == 0 or iterStr.len == 0:
        return SaslStepResult(failed: true, errorMsg: "Invalid server-first-message")

      # Verify nonce starts with our client nonce
      if not serverNonce.startsWith(mech.clientNonce):
        return SaslStepResult(failed: true, errorMsg: "Server nonce doesn't contain client nonce")

      mech.serverNonce = serverNonce
      let saltStr = base64.decode(saltB64)
      mech.salt = saltStr
      mech.iterCount = parseInt(iterStr)

      # Compute SaltedPassword = PBKDF2(password, salt, i)
      let saltBytes = toBytes(saltStr)
      mech.saltedPassword = pbkdf2Sha256(mech.password, saltBytes, mech.iterCount)

      # ClientKey = HMAC(SaltedPassword, "Client Key")
      let clientKey = hmacSha256(mech.saltedPassword, toBytes("Client Key"))

      # StoredKey = SHA-256(ClientKey) - use HMAC with empty key as a workaround
      # Actually we need raw SHA-256. Use EVP.
      # For simplicity, compute H(ClientKey) via a different approach:
      # SHA-256 is available through the EVP interface
      var storedKey = newSeq[byte](32)
      block:
        var mdLen: cuint = 32
        discard evpDigestRaw(unsafeAddr clientKey[0], csize_t(clientKey.len),
                           addr storedKey[0], addr mdLen, evpSha256(), nil)

      # AuthMessage = client-first-bare + "," + server-first-message + "," + client-final-without-proof
      let clientFinalWithoutProof = "c=biws,r=" & serverNonce
      mech.authMessage = mech.clientFirstBare & "," & mech.serverFirstMsg & "," & clientFinalWithoutProof

      # ClientSignature = HMAC(StoredKey, AuthMessage)
      let clientSignature = hmacSha256(storedKey, toBytes(mech.authMessage))

      # ClientProof = ClientKey XOR ClientSignature
      let clientProof = xorBytes(clientKey, clientSignature)

      let clientFinalMsg = clientFinalWithoutProof & ",p=" & base64.encode(toString(clientProof))
      mech.step = 2
      SaslStepResult(response: base64.encode(clientFinalMsg))

    except CatchableError as e:
      SaslStepResult(failed: true, errorMsg: "SCRAM step 2 failed: " & e.msg)

  of 2:
    # Step 3: Verify server-final-message
    try:
      let decoded = base64.decode(challenge)
      if decoded.startsWith("e="):
        return SaslStepResult(finished: true, failed: true,
                             errorMsg: "Server error: " & decoded[2..^1])

      # ServerKey = HMAC(SaltedPassword, "Server Key")
      let serverKey = hmacSha256(mech.saltedPassword, toBytes("Server Key"))
      # ServerSignature = HMAC(ServerKey, AuthMessage)
      let expectedSig = hmacSha256(serverKey, toBytes(mech.authMessage))
      let expectedB64 = "v=" & base64.encode(toString(expectedSig))

      if decoded != expectedB64:
        return SaslStepResult(finished: true, failed: true,
                             errorMsg: "Server signature mismatch")

      mech.step = 3
      SaslStepResult(finished: true)
    except CatchableError as e:
      SaslStepResult(finished: true, failed: true,
                    errorMsg: "SCRAM verification failed: " & e.msg)

  else:
    SaslStepResult(finished: true, failed: true, errorMsg: "Invalid SCRAM state")

# ============================================================
# Generic dispatch
# ============================================================

proc processChallenge*(mech: SaslMechanism, challenge: string): SaslStepResult =
  ## Dispatch challenge processing to the appropriate mechanism.
  if mech of SaslPlain:
    return SaslPlain(mech).processChallenge(challenge)
  elif mech of SaslExternal:
    return SaslExternal(mech).processChallenge(challenge)
  elif mech of SaslScramSha256:
    return SaslScramSha256(mech).processChallenge(challenge)
  else:
    SaslStepResult(failed: true, errorMsg: "Unknown SASL mechanism: " & mech.name)

# ============================================================
# Mechanism selection
# ============================================================

proc selectBestMechanism*(available: seq[string], username, password: string): SaslMechanism =
  ## Select the best SASL mechanism from the server's advertised list.
  ## Priority: SCRAM-SHA-256 > PLAIN > EXTERNAL
  if "SCRAM-SHA-256" in available:
    return newSaslScramSha256(username, password)
  elif "PLAIN" in available:
    return newSaslPlain(username, password)
  elif "EXTERNAL" in available:
    return newSaslExternal()
  else:
    return newSaslPlain(username, password)  # Fallback to PLAIN
