## QUIC initial secret derivation (RFC 9001 section 5.2).

import std/[strformat]
import std/openssl

const
  QuicVersion1Id* = 0x00000001'u32
  QuicVersion2Id* = 0x6B3343CF'u32

  QuicV1InitialSalt* = [
    0x38'u8, 0x76, 0x2C, 0xF7, 0xF5, 0x59, 0x34, 0xB3,
    0x4D, 0x17, 0x9A, 0xE6, 0xA4, 0xC8, 0x0C, 0xAD,
    0xCC, 0xBB, 0x7F, 0x0A
  ]
  QuicV2InitialSalt* = [
    0x0D'u8, 0xED, 0xE3, 0xDE, 0xF7, 0x00, 0xA6, 0xDB,
    0x81, 0x93, 0x81, 0xBE, 0x6E, 0x26, 0x9D, 0xCB,
    0xF9, 0xBD, 0x2E, 0xD9
  ]

  QuicV1AeadKeyLen* = 16
  QuicV1AeadIvLen* = 12
  QuicV1HpKeyLen* = 16

type
  QuicHkdfHash* = enum
    qhhSha256
    qhhSha384

proc toSeq(a: openArray[byte]): seq[byte] =
  result = newSeq[byte](a.len)
  for i in 0 ..< a.len:
    result[i] = a[i]

proc hashDigestLen(hashAlg: QuicHkdfHash): int {.inline.} =
  case hashAlg
  of qhhSha256: 32
  of qhhSha384: 48

proc hmacDigest(hashAlg: QuicHkdfHash,
                key: openArray[byte],
                data: openArray[byte]): seq[byte] =
  let digestLen = hashDigestLen(hashAlg)
  var digest = newSeq[byte](digestLen)
  var outLen: cuint = 0

  let keyPtr = if key.len > 0: unsafeAddr key[0] else: nil
  let dataPtr = if data.len > 0: cast[cstring](unsafeAddr data[0]) else: nil
  let md = case hashAlg
    of qhhSha256: EVP_sha256()
    of qhhSha384: EVP_sha384()

  let rc = HMAC(
    md,
    cast[pointer](keyPtr),
    key.len.cint,
    dataPtr,
    data.len.csize_t,
    cast[cstring](addr digest[0]),
    addr outLen
  )
  if rc.isNil:
    raise newException(ValueError, "HMAC failed")

  digest.setLen(int(outLen))
  if digest.len != digestLen:
    raise newException(ValueError, fmt"unexpected digest length: {digest.len}")
  digest

proc hkdfExtract*(salt: openArray[byte],
                  ikm: openArray[byte],
                  hashAlg: QuicHkdfHash = qhhSha256): seq[byte] =
  ## HKDF-Extract.
  let effectiveSalt = if salt.len == 0: newSeq[byte](hashDigestLen(hashAlg)) else: toSeq(salt)
  hmacDigest(hashAlg, effectiveSalt, ikm)

proc hkdfExpand*(prk: openArray[byte],
                 info: openArray[byte],
                 outLen: int,
                 hashAlg: QuicHkdfHash = qhhSha256): seq[byte] =
  ## HKDF-Expand.
  if outLen < 0:
    raise newException(ValueError, "HKDF output length must be non-negative")
  if outLen == 0:
    return @[]

  let hashLen = hashDigestLen(hashAlg)
  let n = (outLen + hashLen - 1) div hashLen
  if n > 255:
    raise newException(ValueError, "HKDF output too large")

  result = newSeq[byte](0)
  var t: seq[byte] = @[]

  for i in 1 .. n:
    var msgBlock: seq[byte] = @[]
    msgBlock.add t
    msgBlock.add info
    msgBlock.add byte(i)
    t = hmacDigest(hashAlg, prk, msgBlock)
    result.add t

  result.setLen(outLen)

proc hkdfExpandLabel*(secret: openArray[byte],
                      label: string,
                      context: openArray[byte],
                      outLen: int,
                      hashAlg: QuicHkdfHash = qhhSha256): seq[byte] =
  ## TLS 1.3 HKDF-Expand-Label wrapper used by QUIC.
  ## HkdfLabel = length(2) || labelLen(1) || "tls13 " + label || contextLen(1) || context
  let fullLabel = "tls13 " & label
  if fullLabel.len > 255:
    raise newException(ValueError, "HKDF label too long")
  if context.len > 255:
    raise newException(ValueError, "HKDF context too long")

  var info: seq[byte] = @[]
  info.add byte((outLen shr 8) and 0xFF)
  info.add byte(outLen and 0xFF)
  info.add byte(fullLabel.len)
  for c in fullLabel:
    info.add byte(c)
  info.add byte(context.len)
  info.add context

  hkdfExpand(secret, info, outLen, hashAlg)

proc labelPrefix(version: uint32): string {.inline.} =
  if version == QuicVersion2Id:
    "quicv2 "
  else:
    "quic "

proc deriveInitialSecrets*(destinationConnectionId: openArray[byte]): tuple[
    initialSecret: seq[byte],
    clientInitialSecret: seq[byte],
    serverInitialSecret: seq[byte]
  ] =
  let initial = hkdfExtract(QuicV1InitialSalt, destinationConnectionId, qhhSha256)
  let client = hkdfExpandLabel(initial, "client in", @[], 32, qhhSha256)
  let server = hkdfExpandLabel(initial, "server in", @[], 32, qhhSha256)
  (initialSecret: initial, clientInitialSecret: client, serverInitialSecret: server)

proc deriveInitialSecrets*(destinationConnectionId: openArray[byte],
                           version: uint32): tuple[
    initialSecret: seq[byte],
    clientInitialSecret: seq[byte],
    serverInitialSecret: seq[byte]
  ] =
  ## QUIC initial secret derivation from Destination Connection ID.
  let salt =
    if version == QuicVersion2Id:
      QuicV2InitialSalt
    else:
      QuicV1InitialSalt
  let initial = hkdfExtract(salt, destinationConnectionId, qhhSha256)
  let client = hkdfExpandLabel(initial, "client in", @[], 32, qhhSha256)
  let server = hkdfExpandLabel(initial, "server in", @[], 32, qhhSha256)
  (initialSecret: initial, clientInitialSecret: client, serverInitialSecret: server)

proc deriveAeadKey*(trafficSecret: openArray[byte],
                    keyLen: int = QuicV1AeadKeyLen,
                    version: uint32 = QuicVersion1Id,
                    hashAlg: QuicHkdfHash = qhhSha256): seq[byte] =
  hkdfExpandLabel(trafficSecret, labelPrefix(version) & "key", @[], keyLen, hashAlg)

proc deriveAeadIv*(trafficSecret: openArray[byte],
                   ivLen: int = QuicV1AeadIvLen,
                   version: uint32 = QuicVersion1Id,
                   hashAlg: QuicHkdfHash = qhhSha256): seq[byte] =
  hkdfExpandLabel(trafficSecret, labelPrefix(version) & "iv", @[], ivLen, hashAlg)

proc deriveHeaderProtectionKey*(trafficSecret: openArray[byte],
                                keyLen: int = QuicV1HpKeyLen,
                                version: uint32 = QuicVersion1Id,
                                hashAlg: QuicHkdfHash = qhhSha256): seq[byte] =
  hkdfExpandLabel(trafficSecret, labelPrefix(version) & "hp", @[], keyLen, hashAlg)

proc deriveNextTrafficSecret*(trafficSecret: openArray[byte],
                              version: uint32 = QuicVersion1Id,
                              hashAlg: QuicHkdfHash = qhhSha256): seq[byte] =
  ## Derive next-generation application traffic secret for QUIC key updates.
  ## RFC 9001 section 6: HKDF-Expand-Label(current_secret, "quic ku", "", Hash.length)
  hkdfExpandLabel(
    trafficSecret,
    labelPrefix(version) & "ku",
    @[],
    hashDigestLen(hashAlg),
    hashAlg
  )
