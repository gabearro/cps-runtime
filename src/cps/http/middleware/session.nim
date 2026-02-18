## Signed Cookie Session Middleware
##
## Provides cookie-based sessions with HMAC signatures.
## Session data is stored entirely in the cookie as:
##   base64(json_payload) & "." & hex(hmac_signature)
##
## The middleware reads the session cookie from incoming requests,
## verifies the HMAC signature, decodes the JSON payload into
## `req.context` keys prefixed with "session:", and after the handler
## runs, re-encodes modified session data into a Set-Cookie header.

import std/[tables, strutils, json, base64]
import checksums/sha1
import ../../runtime
import ../server/types
import ../server/router

type
  SessionConfig* = object
    secret*: string       ## HMAC signing key
    secretFallbacks*: seq[string]  ## Additional legacy keys accepted for verification
    cookieName*: string   ## Cookie name (default: "session")
    maxAge*: int          ## Cookie max-age in seconds, -1 for session cookie
    httpOnly*: bool       ## HttpOnly flag
    secure*: bool         ## Secure flag
    sameSite*: string     ## SameSite attribute (Lax, Strict, None)
    path*: string         ## Cookie path
    maxCookieBytes*: int  ## Upper bound for inbound cookie value (0 = unlimited)

proc newSessionConfig*(secret: string, cookieName: string = "session",
                       secretFallbacks: seq[string] = @[],
                       maxAge: int = 3600, httpOnly: bool = true,
                       secure: bool = false, sameSite: string = "Lax",
                       path: string = "/", maxCookieBytes: int = 4096): SessionConfig =
  if secret.len == 0:
    raise newException(ValueError, "Session secret must not be empty")
  var filteredFallbacks: seq[string]
  for s in secretFallbacks:
    if s.len > 0 and s != secret:
      filteredFallbacks.add s
  SessionConfig(
    secret: secret,
    secretFallbacks: filteredFallbacks,
    cookieName: cookieName,
    maxAge: maxAge,
    httpOnly: httpOnly,
    secure: secure,
    sameSite: sameSite,
    path: path,
    maxCookieBytes: maxCookieBytes
  )

# ============================================================
# HMAC-SHA1 implementation
# ============================================================

const HmacBlockSize = 64
const Ipad = 0x36'u8
const Opad = 0x5c'u8

proc hmacSha1(key: string, msg: string): string =
  ## HMAC-SHA1: SHA1((key XOR opad) || SHA1((key XOR ipad) || msg))
  ## Returns raw 20-byte digest as a string.
  var keyBytes: array[HmacBlockSize, uint8]

  # If key is longer than block size, hash it first
  if key.len > HmacBlockSize:
    let hashed = $secureHash(key)
    # secureHash returns hex string; convert to bytes
    let hashBytes = parseHexStr(hashed)
    for i in 0 ..< hashBytes.len:
      keyBytes[i] = uint8(hashBytes[i])
  else:
    for i in 0 ..< key.len:
      keyBytes[i] = uint8(key[i])
  # Remaining bytes are already 0

  # Build inner and outer padded keys
  var innerPad = newString(HmacBlockSize)
  var outerPad = newString(HmacBlockSize)
  for i in 0 ..< HmacBlockSize:
    innerPad[i] = char(keyBytes[i] xor Ipad)
    outerPad[i] = char(keyBytes[i] xor Opad)

  # Inner hash: SHA1(ipad_key || msg)
  let innerData = innerPad & msg
  let innerHash = $secureHash(innerData)
  let innerHashBytes = parseHexStr(innerHash)

  # Outer hash: SHA1(opad_key || inner_hash_bytes)
  let outerData = outerPad & innerHashBytes
  let outerHash = $secureHash(outerData)
  let outerHashBytes = parseHexStr(outerHash)

  return outerHashBytes

proc hmacSha1Hex(key: string, msg: string): string =
  ## HMAC-SHA1, returned as lowercase hex string.
  let raw = hmacSha1(key, msg)
  result = newStringOfCap(raw.len * 2)
  for c in raw:
    result.add toHex(ord(c), 2).toLowerAscii

proc constantTimeEq(a: string, b: string): bool =
  ## Constant-time string compare for signature checks.
  if a.len != b.len:
    return false
  var diff = 0
  for i in 0 ..< a.len:
    diff = diff or (ord(a[i]) xor ord(b[i]))
  result = diff == 0

# ============================================================
# Session encoding/decoding
# ============================================================

proc signSession(config: SessionConfig, payload: string): string =
  ## Create a signed session cookie value: base64(payload) & "." & hex(hmac)
  let encoded = base64.encode(payload)
  let sig = hmacSha1Hex(config.secret, encoded)
  result = encoded & "." & sig

proc verifyAndDecode(config: SessionConfig, cookieValue: string): Table[string, string] =
  ## Verify the HMAC signature and decode the session data.
  ## Returns empty table if verification fails.
  result = initTable[string, string]()
  if config.maxCookieBytes > 0 and cookieValue.len > config.maxCookieBytes:
    return  # Too large

  let dotIdx = cookieValue.rfind('.')
  if dotIdx < 0:
    return  # Invalid format

  let encoded = cookieValue[0 ..< dotIdx]
  let sig = cookieValue[dotIdx + 1 .. ^1]

  # Verify HMAC with primary + fallback secrets (for key rotation).
  var sigOk = constantTimeEq(sig, hmacSha1Hex(config.secret, encoded))
  if not sigOk:
    for fallback in config.secretFallbacks:
      if constantTimeEq(sig, hmacSha1Hex(fallback, encoded)):
        sigOk = true
        break
  if not sigOk:
    return  # Signature mismatch

  # Decode base64 payload
  var decoded: string
  try:
    decoded = base64.decode(encoded)
  except ValueError:
    return  # Invalid base64

  # Parse JSON
  var jsonNode: JsonNode
  try:
    jsonNode = parseJson(decoded)
  except JsonParsingError:
    return  # Invalid JSON

  if jsonNode.kind != JObject:
    return  # Expected object

  for key, val in jsonNode.pairs:
    if val.kind == JString:
      result[key] = val.getStr()
    else:
      # Store non-string values as their JSON representation
      result[key] = $val

# ============================================================
# Session access helpers
# ============================================================

proc getSession*(req: HttpRequest, key: string): string =
  ## Get a session value. Session keys are stored in context as "session:key".
  if req.context.isNil:
    return ""
  req.context.getOrDefault("session:" & key)

proc setSession*(req: HttpRequest, key: string, value: string) =
  ## Set a session value.
  if req.context.isNil:
    return
  req.context["session:" & key] = value

proc clearSession*(req: HttpRequest) =
  ## Clear all session data.
  if req.context.isNil:
    return
  var toRemove: seq[string]
  for k, v in req.context:
    if k.startsWith("session:"):
      toRemove.add k
  for k in toRemove:
    req.context.del(k)

# ============================================================
# Middleware
# ============================================================

proc collectSessionData(context: TableRef[string, string]): Table[string, string] =
  ## Extract all "session:" prefixed keys from context, stripping the prefix.
  result = initTable[string, string]()
  if context.isNil:
    return
  for k, v in context:
    if k.startsWith("session:"):
      result[k[8 .. ^1]] = v

proc encodeSessionJson(data: Table[string, string]): string =
  ## Encode session data as a JSON object string.
  var obj = newJObject()
  for k, v in data:
    obj[k] = newJString(v)
  result = $obj

proc sessionMiddleware*(config: SessionConfig): Middleware =
  ## Create a session middleware.
  ##
  ## On each request:
  ## 1. Read the session cookie and verify the HMAC signature
  ## 2. Decode the JSON payload into req.context with "session:" prefix
  ## 3. Call the next handler
  ## 4. After the handler returns, collect all "session:" keys from context
  ## 5. Encode to JSON, sign with HMAC, and set the cookie on the response
  ##
  ## If signature verification fails, the session starts empty (no error).
  let capturedConfig = config
  result = proc(req: HttpRequest, next: HttpHandler): CpsFuture[HttpResponseBuilder] {.closure.} =
    var modReq = req
    if modReq.context.isNil:
      modReq.context = newTable[string, string]()

    # 1. Read and decode session cookie
    let cookieValue = getCookie(modReq, capturedConfig.cookieName)
    if cookieValue.len > 0:
      let sessionData = verifyAndDecode(capturedConfig, cookieValue)
      for k, v in sessionData:
        modReq.context["session:" & k] = v

    # 2. Call next handler
    let handlerFut = next(modReq)
    let resultFut = newCpsFuture[HttpResponseBuilder]()

    # 3. After handler completes, encode session and set cookie
    handlerFut.addCallback(proc() =
      if handlerFut.hasError():
        resultFut.fail(handlerFut.getError())
      else:
        var resp = handlerFut.read()

        # req.context is a shared table reference so handler/session
        # mutations are visible here after next() completes.
        let sessionData = collectSessionData(modReq.context)
        if sessionData.len > 0:
          let payload = encodeSessionJson(sessionData)
          let signedValue = signSession(capturedConfig, payload)
          let cookie = setCookieHeader(
            capturedConfig.cookieName,
            signedValue,
            maxAge = capturedConfig.maxAge,
            path = capturedConfig.path,
            httpOnly = capturedConfig.httpOnly,
            secure = capturedConfig.secure,
            sameSite = capturedConfig.sameSite
          )
          resp.headers.add cookie
        else:
          # No session data — if there was a cookie, clear it
          if cookieValue.len > 0:
            let cookie = setCookieHeader(
              capturedConfig.cookieName,
              "",
              maxAge = 0,
              path = capturedConfig.path,
              httpOnly = capturedConfig.httpOnly,
              secure = capturedConfig.secure,
              sameSite = capturedConfig.sameSite
            )
            resp.headers.add cookie

        resultFut.complete(resp)
    )
    return resultFut
