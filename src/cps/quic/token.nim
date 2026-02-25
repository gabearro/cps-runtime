## QUIC token issuance and validation helpers.

import std/times
import ./varint
import ./packet_protection
import ./secure_random

const
  QuicTokenMagic = [byte('Q'), byte('T'), byte('K'), byte('1')]
  QuicTokenNonceLen* = 12
  QuicTokenPayloadLen = 16

type
  QuicTokenPurpose* = enum
    qtpRetry = 0
    qtpNewToken = 1

  QuicTokenValidation* = object
    valid*: bool
    purpose*: QuicTokenPurpose
    issuedAtUnix*: int64
    expiresAtUnix*: int64
    clientAddress*: string
    originalDestinationConnectionId*: seq[byte]
    retrySourceConnectionId*: seq[byte]

proc selectAeadKey(secretKey: openArray[byte]): array[16, byte] =
  if secretKey.len < 16:
    raise newException(ValueError, "token secret key must be at least 16 bytes")
  for i in 0 ..< 16:
    result[i] = secretKey[i]

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len:
    result[i] = byte(ord(s[i]) and 0xFF)

proc bytesToString(data: openArray[byte]): string =
  result = newString(data.len)
  for i in 0 ..< data.len:
    result[i] = char(data[i])

proc appendInt64Be(dst: var seq[byte], v: int64) =
  for i in countdown(7, 0):
    dst.add byte((uint64(v) shr (i * 8)) and 0xFF)

proc parseInt64Be(data: openArray[byte], offset: var int): int64 =
  if offset + 8 > data.len:
    raise newException(ValueError, "token decode truncated int64")
  var v = 0'u64
  for i in 0 ..< 8:
    v = (v shl 8) or uint64(data[offset + i])
  offset += 8
  int64(v)

proc appendBytesWithVarintLen(dst: var seq[byte], data: openArray[byte]) =
  dst.appendQuicVarInt(uint64(data.len))
  if data.len > 0:
    dst.add data

proc parseBytesWithVarintLen(data: openArray[byte], offset: var int): seq[byte] =
  let n = decodeQuicVarInt(data, offset)
  if offset + int(n) > data.len:
    raise newException(ValueError, "token decode truncated varint-sized field")
  result = @[]
  if n > 0:
    result.add data[offset ..< offset + int(n)]
    offset += int(n)

proc issueQuicToken*(secretKey: openArray[byte],
                     purpose: QuicTokenPurpose,
                     clientAddress: string,
                     originalDestinationConnectionId: openArray[byte],
                     retrySourceConnectionId: openArray[byte] = @[],
                     ttlSeconds: int64 = 600,
                     nowUnix: int64 = 0): seq[byte] =
  ## Issue an AEAD-protected QUIC token.
  let key = selectAeadKey(secretKey)
  let issuedAt = if nowUnix > 0: nowUnix else: int64(epochTime())
  let expiresAt = issuedAt + ttlSeconds

  var nonce: array[QuicTokenNonceLen, byte]
  var nonceBytes = secureRandomBytes(QuicTokenNonceLen)
  for i in 0 ..< QuicTokenNonceLen:
    nonce[i] = nonceBytes[i]

  result = @[]
  result.add QuicTokenMagic
  result.add byte(purpose.ord)
  result.appendInt64Be(issuedAt)

  let addrBytes = toBytes(clientAddress)
  result.appendBytesWithVarintLen(addrBytes)
  result.appendBytesWithVarintLen(originalDestinationConnectionId)
  result.appendBytesWithVarintLen(retrySourceConnectionId)

  for i in 0 ..< QuicTokenNonceLen:
    result.add nonce[i]

  let aad = result
  var plaintext = newSeq[byte](QuicTokenPayloadLen)
  for i in countdown(7, 0):
    plaintext[7 - i] = byte((uint64(expiresAt) shr (i * 8)) and 0xFF)
  if QuicTokenPayloadLen > 8:
    var tail = secureRandomBytes(QuicTokenPayloadLen - 8)
    for i in 0 ..< tail.len:
      plaintext[8 + i] = tail[i]

  let enc = encryptAes128Gcm(key, nonce, aad, plaintext)
  if enc.ciphertext.len > 0:
    result.add enc.ciphertext
  for i in 0 ..< GcmTagLen:
    result.add enc.tag[i]

proc decodeQuicToken*(secretKey: openArray[byte],
                      token: openArray[byte]): QuicTokenValidation =
  ## Decode and authenticate a QUIC token.
  if token.len < 4 + 1 + 8 + 1 + 1 + 1 + QuicTokenNonceLen + QuicTokenPayloadLen + GcmTagLen:
    return QuicTokenValidation(valid: false)

  let key = selectAeadKey(secretKey)
  var off = 0
  if token[0] != QuicTokenMagic[0] or token[1] != QuicTokenMagic[1] or
      token[2] != QuicTokenMagic[2] or token[3] != QuicTokenMagic[3]:
    return QuicTokenValidation(valid: false)
  off = 4

  if token[off] > byte(QuicTokenPurpose.high.ord):
    return QuicTokenValidation(valid: false)
  result.purpose = QuicTokenPurpose(token[off].int)
  inc off
  result.issuedAtUnix = parseInt64Be(token, off)

  let addrBytes = parseBytesWithVarintLen(token, off)
  result.clientAddress = bytesToString(addrBytes)
  result.originalDestinationConnectionId = parseBytesWithVarintLen(token, off)
  result.retrySourceConnectionId = parseBytesWithVarintLen(token, off)

  if off + QuicTokenNonceLen + GcmTagLen > token.len:
    return QuicTokenValidation(valid: false)
  var nonce: array[QuicTokenNonceLen, byte]
  for i in 0 ..< QuicTokenNonceLen:
    nonce[i] = token[off + i]
  off += QuicTokenNonceLen

  if off + GcmTagLen > token.len:
    return QuicTokenValidation(valid: false)
  let ctLen = token.len - off - GcmTagLen
  if ctLen <= 0:
    return QuicTokenValidation(valid: false)

  let aadEnd = off
  let aad = token[0 ..< aadEnd]
  let ciphertext = token[off ..< off + ctLen]
  let tag = token[off + ctLen ..< token.len]

  var plaintext: seq[byte]
  try:
    plaintext = decryptAes128Gcm(key, nonce, aad, ciphertext, tag)
  except ValueError:
    return QuicTokenValidation(valid: false)

  if plaintext.len < 8:
    return QuicTokenValidation(valid: false)
  var poff = 0
  result.expiresAtUnix = parseInt64Be(plaintext, poff)
  result.valid = true

proc validateQuicToken*(secretKey: openArray[byte],
                        token: openArray[byte],
                        expectedPurpose: QuicTokenPurpose,
                        clientAddress: string,
                        expectedOriginalDestinationConnectionId: openArray[byte] = @[],
                        expectedRetrySourceConnectionId: openArray[byte] = @[],
                        nowUnix: int64 = 0): QuicTokenValidation =
  ## Decode token and validate purpose/address/expiry.
  result = decodeQuicToken(secretKey, token)
  if not result.valid:
    return result
  if result.purpose != expectedPurpose:
    result.valid = false
    return result
  if result.clientAddress != clientAddress:
    result.valid = false
    return result
  if expectedOriginalDestinationConnectionId.len > 0 and
      result.originalDestinationConnectionId != @expectedOriginalDestinationConnectionId:
    result.valid = false
    return result
  if expectedRetrySourceConnectionId.len > 0 and
      result.retrySourceConnectionId != @expectedRetrySourceConnectionId:
    result.valid = false
    return result
  let nowTs = if nowUnix > 0: nowUnix else: int64(epochTime())
  if nowTs > result.expiresAtUnix:
    result.valid = false
