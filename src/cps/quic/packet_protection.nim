## QUIC packet protection helpers (AES-GCM / CHACHA20-POLY1305 + header protection).

import std/openssl
when defined(useBoringSSL):
  import ../tls/boringssl_compat

const
  GcmTagLen* = 16
  AeadNonceLen* = 12

  EVP_CTRL_AEAD_SET_IVLEN = 0x9
  EVP_CTRL_AEAD_GET_TAG = 0x10
  EVP_CTRL_AEAD_SET_TAG = 0x11

type
  QuicPacketCipher* = enum
    qpcAes128Gcm
    qpcAes256Gcm
    qpcChaCha20Poly1305

  EvpCipherCtx = pointer
  EvpCipher = pointer

proc EVP_CIPHER_CTX_new(): EvpCipherCtx {.cdecl, dynlib: DLLUtilName, importc.}
proc EVP_CIPHER_CTX_free(ctx: EvpCipherCtx) {.cdecl, dynlib: DLLUtilName, importc.}
proc EVP_CIPHER_CTX_ctrl(ctx: EvpCipherCtx, cmd: cint, p1: cint, p2: pointer): cint {.cdecl, dynlib: DLLUtilName, importc.}
proc EVP_CIPHER_CTX_set_padding(ctx: EvpCipherCtx, pad: cint): cint {.cdecl, dynlib: DLLUtilName, importc.}
proc EVP_EncryptInit_ex(ctx: EvpCipherCtx, cipher: EvpCipher, engine: pointer, key: ptr byte, iv: ptr byte): cint {.cdecl, dynlib: DLLUtilName, importc.}
proc EVP_EncryptUpdate(ctx: EvpCipherCtx, outBuf: ptr byte, outLen: ptr cint, inBuf: ptr byte, inLen: cint): cint {.cdecl, dynlib: DLLUtilName, importc.}
proc EVP_EncryptFinal_ex(ctx: EvpCipherCtx, outBuf: ptr byte, outLen: ptr cint): cint {.cdecl, dynlib: DLLUtilName, importc.}
proc EVP_DecryptInit_ex(ctx: EvpCipherCtx, cipher: EvpCipher, engine: pointer, key: ptr byte, iv: ptr byte): cint {.cdecl, dynlib: DLLUtilName, importc.}
proc EVP_DecryptUpdate(ctx: EvpCipherCtx, outBuf: ptr byte, outLen: ptr cint, inBuf: ptr byte, inLen: cint): cint {.cdecl, dynlib: DLLUtilName, importc.}
proc EVP_DecryptFinal_ex(ctx: EvpCipherCtx, outBuf: ptr byte, outLen: ptr cint): cint {.cdecl, dynlib: DLLUtilName, importc.}

proc EVP_aes_128_gcm(): EvpCipher {.cdecl, dynlib: DLLUtilName, importc.}
proc EVP_aes_256_gcm(): EvpCipher {.cdecl, dynlib: DLLUtilName, importc.}
proc EVP_aes_128_ecb(): EvpCipher {.cdecl, dynlib: DLLUtilName, importc.}
proc EVP_aes_256_ecb(): EvpCipher {.cdecl, dynlib: DLLUtilName, importc.}
when not defined(useBoringSSL):
  proc EVP_chacha20_poly1305(): EvpCipher {.cdecl, dynlib: DLLUtilName, importc.}
  proc EVP_chacha20(): EvpCipher {.cdecl, dynlib: DLLUtilName, importc.}

proc keyLenForCipher*(cipher: QuicPacketCipher): int {.inline.} =
  case cipher
  of qpcAes128Gcm: 16
  of qpcAes256Gcm, qpcChaCha20Poly1305: 32

proc hpKeyLenForCipher*(cipher: QuicPacketCipher): int {.inline.} =
  case cipher
  of qpcAes128Gcm: 16
  of qpcAes256Gcm, qpcChaCha20Poly1305: 32

proc selectAeadCipher(cipher: QuicPacketCipher): EvpCipher =
  case cipher
  of qpcAes128Gcm: EVP_aes_128_gcm()
  of qpcAes256Gcm: EVP_aes_256_gcm()
  of qpcChaCha20Poly1305:
    when defined(useBoringSSL):
      nil
    else:
      EVP_chacha20_poly1305()

proc ensureAeadKeyLen(cipher: QuicPacketCipher, key: openArray[byte]) =
  let expected = keyLenForCipher(cipher)
  if key.len != expected:
    raise newException(ValueError, "AEAD key has invalid length for selected QUIC packet cipher")

proc encryptPacketPayload*(cipher: QuicPacketCipher,
                           key: openArray[byte],
                           iv: openArray[byte],
                           aad: openArray[byte],
                           plaintext: openArray[byte]): tuple[ciphertext: seq[byte], tag: array[GcmTagLen, byte]] =
  ensureAeadKeyLen(cipher, key)
  if iv.len != AeadNonceLen:
    raise newException(ValueError, "QUIC AEAD IV must be 12 bytes")

  when defined(useBoringSSL):
    if cipher == qpcChaCha20Poly1305:
      var sealedBytes = newSeq[byte](plaintext.len + GcmTagLen)
      var outLen: csize_t = 0
      let keyPtr = cast[ptr uint8](unsafeAddr key[0])
      let noncePtr = cast[ptr uint8](unsafeAddr iv[0])
      let aadPtr = if aad.len > 0: cast[ptr uint8](unsafeAddr aad[0]) else: nil
      let plainPtr = if plaintext.len > 0: cast[ptr uint8](unsafeAddr plaintext[0]) else: nil
      if boringSslChacha20Poly1305Seal(
        keyPtr, key.len.csize_t,
        noncePtr, iv.len.csize_t,
        aadPtr, aad.len.csize_t,
        plainPtr, plaintext.len.csize_t,
        cast[ptr uint8](unsafeAddr sealedBytes[0]), addr outLen,
        sealedBytes.len.csize_t
      ) != 1:
        raise newException(ValueError, "BoringSSL CHACHA20-POLY1305 seal failed")
      let totalLen = int(outLen)
      if totalLen < GcmTagLen:
        raise newException(ValueError, "BoringSSL CHACHA20-POLY1305 seal produced truncated output")
      let cipherLen = totalLen - GcmTagLen
      result.ciphertext = newSeq[byte](cipherLen)
      for i in 0 ..< cipherLen:
        result.ciphertext[i] = sealedBytes[i]
      for i in 0 ..< GcmTagLen:
        result.tag[i] = sealedBytes[cipherLen + i]
      return

  let ctx = EVP_CIPHER_CTX_new()
  if ctx.isNil:
    raise newException(ValueError, "EVP_CIPHER_CTX_new failed")
  defer: EVP_CIPHER_CTX_free(ctx)

  let evpCipher = selectAeadCipher(cipher)
  if EVP_EncryptInit_ex(ctx, evpCipher, nil, nil, nil) != 1:
    raise newException(ValueError, "EVP_EncryptInit_ex(cipher) failed")
  if EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, iv.len.cint, nil) != 1:
    raise newException(ValueError, "EVP_CTRL_AEAD_SET_IVLEN failed")
  if EVP_EncryptInit_ex(ctx, nil, nil, unsafeAddr key[0], unsafeAddr iv[0]) != 1:
    raise newException(ValueError, "EVP_EncryptInit_ex(key/iv) failed")

  var outLen: cint = 0
  if aad.len > 0:
    if EVP_EncryptUpdate(ctx, nil, addr outLen, unsafeAddr aad[0], aad.len.cint) != 1:
      raise newException(ValueError, "EVP_EncryptUpdate(aad) failed")

  result.ciphertext = newSeq[byte](plaintext.len)
  if plaintext.len > 0:
    if EVP_EncryptUpdate(ctx, unsafeAddr result.ciphertext[0], addr outLen,
                         unsafeAddr plaintext[0], plaintext.len.cint) != 1:
      raise newException(ValueError, "EVP_EncryptUpdate(plaintext) failed")

  var finalLen: cint = 0
  if EVP_EncryptFinal_ex(ctx, nil, addr finalLen) != 1:
    raise newException(ValueError, "EVP_EncryptFinal_ex failed")

  if EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_GET_TAG, GcmTagLen.cint, addr result.tag[0]) != 1:
    raise newException(ValueError, "EVP_CTRL_AEAD_GET_TAG failed")

proc decryptPacketPayload*(cipher: QuicPacketCipher,
                           key: openArray[byte],
                           iv: openArray[byte],
                           aad: openArray[byte],
                           ciphertext: openArray[byte],
                           tag: openArray[byte]): seq[byte] =
  ensureAeadKeyLen(cipher, key)
  if iv.len != AeadNonceLen:
    raise newException(ValueError, "QUIC AEAD IV must be 12 bytes")
  if tag.len != GcmTagLen:
    raise newException(ValueError, "QUIC AEAD tag must be 16 bytes")

  when defined(useBoringSSL):
    if cipher == qpcChaCha20Poly1305:
      var combined = newSeq[byte](ciphertext.len + tag.len)
      for i in 0 ..< ciphertext.len:
        combined[i] = ciphertext[i]
      for i in 0 ..< tag.len:
        combined[ciphertext.len + i] = tag[i]
      result = newSeq[byte](ciphertext.len)
      var outLen: csize_t = 0
      let keyPtr = cast[ptr uint8](unsafeAddr key[0])
      let noncePtr = cast[ptr uint8](unsafeAddr iv[0])
      let aadPtr = if aad.len > 0: cast[ptr uint8](unsafeAddr aad[0]) else: nil
      let ctPtr = if combined.len > 0: cast[ptr uint8](unsafeAddr combined[0]) else: nil
      let outPtr = if result.len > 0: cast[ptr uint8](unsafeAddr result[0]) else: nil
      if boringSslChacha20Poly1305Open(
        keyPtr, key.len.csize_t,
        noncePtr, iv.len.csize_t,
        aadPtr, aad.len.csize_t,
        ctPtr, combined.len.csize_t,
        outPtr, addr outLen,
        result.len.csize_t
      ) != 1:
        raise newException(ValueError, "BoringSSL CHACHA20-POLY1305 authentication failed")
      if int(outLen) != result.len:
        if int(outLen) < 0 or int(outLen) > result.len:
          raise newException(ValueError, "BoringSSL CHACHA20-POLY1305 returned invalid plaintext length")
        if int(outLen) == 0:
          result.setLen(0)
        else:
          result.setLen(int(outLen))
      return

  let ctx = EVP_CIPHER_CTX_new()
  if ctx.isNil:
    raise newException(ValueError, "EVP_CIPHER_CTX_new failed")
  defer: EVP_CIPHER_CTX_free(ctx)

  let evpCipher = selectAeadCipher(cipher)
  if EVP_DecryptInit_ex(ctx, evpCipher, nil, nil, nil) != 1:
    raise newException(ValueError, "EVP_DecryptInit_ex(cipher) failed")
  if EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_IVLEN, iv.len.cint, nil) != 1:
    raise newException(ValueError, "EVP_CTRL_AEAD_SET_IVLEN failed")
  if EVP_DecryptInit_ex(ctx, nil, nil, unsafeAddr key[0], unsafeAddr iv[0]) != 1:
    raise newException(ValueError, "EVP_DecryptInit_ex(key/iv) failed")

  var outLen: cint = 0
  if aad.len > 0:
    if EVP_DecryptUpdate(ctx, nil, addr outLen, unsafeAddr aad[0], aad.len.cint) != 1:
      raise newException(ValueError, "EVP_DecryptUpdate(aad) failed")

  result = newSeq[byte](ciphertext.len)
  if ciphertext.len > 0:
    if EVP_DecryptUpdate(ctx, unsafeAddr result[0], addr outLen,
                         unsafeAddr ciphertext[0], ciphertext.len.cint) != 1:
      raise newException(ValueError, "EVP_DecryptUpdate(ciphertext) failed")

  var tagBuf = newSeq[byte](GcmTagLen)
  for i in 0 ..< GcmTagLen:
    tagBuf[i] = tag[i]
  if EVP_CIPHER_CTX_ctrl(ctx, EVP_CTRL_AEAD_SET_TAG, GcmTagLen.cint, unsafeAddr tagBuf[0]) != 1:
    raise newException(ValueError, "EVP_CTRL_AEAD_SET_TAG failed")

  var finalLen: cint = 0
  if EVP_DecryptFinal_ex(ctx, nil, addr finalLen) != 1:
    raise newException(ValueError, "EVP_DecryptFinal_ex authentication failed")

proc headerProtectionMaskAes*(hpKey: openArray[byte],
                              sample: openArray[byte],
                              ecbCipher: EvpCipher,
                              expectedKeyLen: int): array[5, byte] =
  if hpKey.len != expectedKeyLen:
    raise newException(ValueError, "AES HP key has invalid length for selected QUIC packet cipher")
  if sample.len < 16:
    raise newException(ValueError, "HP sample must be at least 16 bytes")

  let ctx = EVP_CIPHER_CTX_new()
  if ctx.isNil:
    raise newException(ValueError, "EVP_CIPHER_CTX_new failed")
  defer: EVP_CIPHER_CTX_free(ctx)

  if EVP_EncryptInit_ex(ctx, ecbCipher, nil, unsafeAddr hpKey[0], nil) != 1:
    raise newException(ValueError, "EVP_EncryptInit_ex(ECB) failed")
  discard EVP_CIPHER_CTX_set_padding(ctx, 0)

  var outBlock = newSeq[byte](16)
  var outLen: cint = 0
  if EVP_EncryptUpdate(ctx, unsafeAddr outBlock[0], addr outLen, unsafeAddr sample[0], 16) != 1:
    raise newException(ValueError, "EVP_EncryptUpdate(HP sample) failed")

  var finalLen: cint = 0
  if EVP_EncryptFinal_ex(ctx, nil, addr finalLen) != 1:
    raise newException(ValueError, "EVP_EncryptFinal_ex(HP) failed")

  for i in 0 ..< 5:
    result[i] = outBlock[i]

proc headerProtectionMaskChacha20(hpKey: openArray[byte], sample: openArray[byte]): array[5, byte] =
  if hpKey.len != 32:
    raise newException(ValueError, "CHACHA20 HP key must be 32 bytes")
  if sample.len < 16:
    raise newException(ValueError, "HP sample must be at least 16 bytes")
  when defined(useBoringSSL):
    if boringSslChacha20HeaderProtectionMask(
      cast[ptr uint8](unsafeAddr hpKey[0]),
      hpKey.len.csize_t,
      cast[ptr uint8](unsafeAddr sample[0]),
      sample.len.csize_t,
      cast[ptr uint8](addr result[0]),
      result.len.csize_t
    ) != 1:
      raise newException(ValueError, "BoringSSL CHACHA20 header protection failed")
  else:
    let ctx = EVP_CIPHER_CTX_new()
    if ctx.isNil:
      raise newException(ValueError, "EVP_CIPHER_CTX_new failed")
    defer: EVP_CIPHER_CTX_free(ctx)

    var iv = newSeq[byte](16)
    for i in 0 ..< 16:
      iv[i] = sample[i]

    if EVP_EncryptInit_ex(ctx, EVP_chacha20(), nil, unsafeAddr hpKey[0], unsafeAddr iv[0]) != 1:
      raise newException(ValueError, "EVP_EncryptInit_ex(CHACHA20) failed")
    discard EVP_CIPHER_CTX_set_padding(ctx, 0)

    var zeros = [0'u8, 0, 0, 0, 0]
    var outBytes = newSeq[byte](5)
    var outLen: cint = 0
    if EVP_EncryptUpdate(ctx, unsafeAddr outBytes[0], addr outLen, unsafeAddr zeros[0], 5) != 1:
      raise newException(ValueError, "EVP_EncryptUpdate(CHACHA20 HP sample) failed")

    var finalLen: cint = 0
    if EVP_EncryptFinal_ex(ctx, nil, addr finalLen) != 1:
      raise newException(ValueError, "EVP_EncryptFinal_ex(CHACHA20 HP) failed")

    for i in 0 ..< 5:
      result[i] = outBytes[i]

proc headerProtectionMask*(cipher: QuicPacketCipher,
                           hpKey: openArray[byte],
                           sample: openArray[byte]): array[5, byte] =
  case cipher
  of qpcAes128Gcm:
    headerProtectionMaskAes(hpKey, sample, EVP_aes_128_ecb(), 16)
  of qpcAes256Gcm:
    headerProtectionMaskAes(hpKey, sample, EVP_aes_256_ecb(), 32)
  of qpcChaCha20Poly1305:
    headerProtectionMaskChacha20(hpKey, sample)

proc makeNonce*(baseIv: openArray[byte], packetNumber: uint64): array[AeadNonceLen, byte] =
  ## QUIC nonce = IV XOR packet_number (packet number left-padded to IV length).
  if baseIv.len != AeadNonceLen:
    raise newException(ValueError, "QUIC IV must be 12 bytes")

  for i in 0 ..< AeadNonceLen:
    result[i] = baseIv[i]

  var pnBytes: array[8, byte]
  for i in 0 ..< 8:
    pnBytes[7 - i] = byte((packetNumber shr (i * 8)) and 0xFF)

  for i in 0 ..< 8:
    result[AeadNonceLen - 8 + i] = result[AeadNonceLen - 8 + i] xor pnBytes[i]

proc encryptAes128Gcm*(key: openArray[byte], iv: openArray[byte],
                       aad: openArray[byte], plaintext: openArray[byte]): tuple[ciphertext: seq[byte], tag: array[GcmTagLen, byte]] =
  encryptPacketPayload(qpcAes128Gcm, key, iv, aad, plaintext)

proc decryptAes128Gcm*(key: openArray[byte], iv: openArray[byte],
                       aad: openArray[byte],
                       ciphertext: openArray[byte],
                       tag: openArray[byte]): seq[byte] =
  decryptPacketPayload(qpcAes128Gcm, key, iv, aad, ciphertext, tag)

proc headerProtectionMaskAes128*(hpKey: openArray[byte], sample: openArray[byte]): array[5, byte] =
  ## Backward-compatible helper retained for existing tests and token/retry helpers.
  headerProtectionMask(qpcAes128Gcm, hpKey, sample)
