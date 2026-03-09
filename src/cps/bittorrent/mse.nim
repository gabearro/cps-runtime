## BitTorrent Message Stream Encryption (MSE/PE).
##
## Traffic obfuscation using DH key exchange (768-bit) + RC4 stream cipher.
## Protects against passive deep packet inspection (DPI) by ISPs.
##
## Protocol: DH exchange → derive RC4 keys → negotiate crypto mode →
## wrap stream with RC4 (or continue plaintext after handshake).

import ../runtime
import ../transform
import ../io/streams
import sha1
import utils

# ============ OpenSSL BIGNUM + RAND FFI ============
# Linked via -lcrypto (--dynlibOverride:crypto in config.nims)

proc BN_new(): pointer {.importc, cdecl.}
proc BN_free(a: pointer) {.importc, cdecl.}
proc BN_CTX_new(): pointer {.importc, cdecl.}
proc BN_CTX_free(ctx: pointer) {.importc, cdecl.}
proc BN_bin2bn(s: ptr byte, len: cint, ret: pointer): pointer {.importc, cdecl.}
proc BN_bn2bin(a: pointer, to: ptr byte): cint {.importc, cdecl.}
proc BN_num_bits(a: pointer): cint {.importc, cdecl.}
proc BN_mod_exp(r, a, p, m: pointer, ctx: pointer): cint {.importc, cdecl.}
proc BN_set_word(a: pointer, w: culong): cint {.importc, cdecl.}
proc BN_rand(rnd: pointer, bits: cint, top: cint, bottom: cint): cint {.importc, cdecl.}
proc RAND_bytes(buf: ptr byte, num: cint): cint {.importc, cdecl.}

proc BN_num_bytes(a: pointer): cint {.inline.} =
  (BN_num_bits(a) + 7) div 8

# ============ RC4 Cipher ============

type
  Rc4State* = object
    s: array[256, uint8]
    i, j: uint8

proc initRc4*(key: openArray[byte]): Rc4State =
  for idx in 0 .. 255:
    result.s[idx] = uint8(idx)
  var j: uint8 = 0
  for idx in 0 .. 255:
    j = j + result.s[idx] + key[idx mod key.len]
    swap(result.s[idx], result.s[j])

proc nextByte*(state: var Rc4State): byte {.inline.} =
  state.i += 1
  state.j += state.s[state.i]
  swap(state.s[state.i], state.s[state.j])
  result = state.s[(state.s[state.i] + state.s[state.j])]

proc processInPlace*(state: var Rc4State, data: var string) =
  for idx in 0 ..< data.len:
    data[idx] = char(data[idx].byte xor state.nextByte())

proc discardBytes*(state: var Rc4State, n: int) =
  for _ in 0 ..< n:
    discard state.nextByte()

# ============ Constants ============

const
  DhKeyLen* = 96  ## 768-bit DH public key
  MseVcLen = 8
  MseRc4Discard = 1024
  MsePadMax = 512
  MseCryptoPlaintext* = 0x01'u32
  MseCryptoRc4* = 0x02'u32

  ## MSE 768-bit prime P (big-endian hex)
  MsePrimeHex = "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1" &
                 "29024E088A67CC74020BBEA63B139B22514A08798E3404DD" &
                 "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245" &
                 "E485B576625E7EC6F44C42E9A63A36210000000000090563"

let MsePrimeBytes = block:
  let decoded = hexToBytes(MsePrimeHex)
  doAssert decoded.len == DhKeyLen
  var prime: array[DhKeyLen, byte]
  copyMem(addr prime[0], unsafeAddr decoded[0], DhKeyLen)
  prime

type
  EncryptionMode* = enum
    emPreferEncrypted   ## Try MSE, fall back to plain
    emRequireEncrypted  ## MSE required
    emPreferPlaintext   ## No MSE attempt
    emForceRc4          ## Require full RC4

  MseResult* = object
    stream*: AsyncStream
    isEncrypted*: bool
    cryptoSelected*: uint32
    initialPayload*: string  ## IA from initiator (responder only)
    matchedInfoHash*: array[20, byte]  ## Which info hash matched (multi-hash respond)

# ============ Helpers ============

proc bytesToStr(data: openArray[byte]): string =
  result = newString(data.len)
  if data.len > 0:
    copyMem(addr result[0], unsafeAddr data[0], data.len)

proc randomBytes(n: int): string =
  if n <= 0: return ""
  result = newString(n)
  let rc = RAND_bytes(cast[ptr byte](addr result[0]), cint(n))
  if rc != 1:
    raise newException(CatchableError, "RAND_bytes failed")

proc randomPadLen(): int =
  var buf: array[2, byte]
  discard RAND_bytes(addr buf[0], 2)
  result = int((uint16(buf[0]) shl 8 or uint16(buf[1])) mod uint16(MsePadMax + 1))

proc sha1Cat(parts: varargs[string]): array[20, byte] =
  var combined = ""
  for p in parts:
    combined.add(p)
  result = sha1(combined)

proc xorHash(a, b: array[20, byte]): array[20, byte] =
  for idx in 0 ..< 20:
    result[idx] = a[idx] xor b[idx]

proc copySlice(data: string, first, lastExcl: int): string =
  ## Force an owned copy; avoids CPS env aliasing when substrings survive awaits.
  if first < 0 or lastExcl < first or lastExcl > data.len:
    raise newException(AsyncIoError, "MSE: invalid slice bounds")
  let n = lastExcl - first
  if n == 0:
    return ""
  result = newString(n)
  copyMem(addr result[0], unsafeAddr data[first], n)

proc writeU16BE(s: var string, v: uint16) =
  s.add(char((v shr 8) and 0xFF))
  s.add(char(v and 0xFF))

proc readU16BE(s: string, offset: int): uint16 =
  (uint16(s[offset].byte) shl 8) or uint16(s[offset + 1].byte)

# Keep MSE CPS state machines on copy semantics: ARC sink moves in large
# transformed environments can alias string payloads and double-free on teardown.
proc readExactRaw*(stream: AsyncStream, size: int): CpsFuture[string] {.cps, nosinks.} =
  ## Read exactly `size` bytes from a raw (unbuffered) stream.
  if size < 0:
    raise newException(AsyncIoError, "MSE: invalid read size")
  if size == 0:
    return ""

  var resultBuf = newString(size)
  var filled = 0
  while filled < size:
    let remaining = size - filled
    let chunk: string = await stream.read(remaining)
    if chunk.len == 0:
      raise newException(AsyncIoError, "MSE: connection closed")
    if chunk.len > remaining:
      raise newException(AsyncIoError, "MSE: over-read from stream")
    copyMem(addr resultBuf[filled], unsafeAddr chunk[0], chunk.len)
    filled += chunk.len
  return resultBuf

proc readExactDhPub(stream: AsyncStream): CpsFuture[array[DhKeyLen, byte]] {.cps, nosinks.} =
  ## Read exactly one DH public key (96 bytes) directly into fixed storage.
  var pub: array[DhKeyLen, byte]
  var filled = 0
  while filled < DhKeyLen:
    let remaining = DhKeyLen - filled
    let chunk: string = await stream.read(remaining)
    if chunk.len == 0:
      raise newException(AsyncIoError, "MSE: connection closed reading DH key")
    if chunk.len > remaining:
      raise newException(AsyncIoError, "MSE: over-read while reading DH key")
    copyMem(addr pub[filled], unsafeAddr chunk[0], chunk.len)
    filled += chunk.len
  return pub

# ============ DH Key Exchange ============

proc dhGenerateKeyPair*(): tuple[privKey: seq[byte], pubKey: array[DhKeyLen, byte]] =
  let bnP = BN_new()
  let bnG = BN_new()
  let bnX = BN_new()
  let bnY = BN_new()
  let ctx = BN_CTX_new()
  defer:
    BN_free(bnP); BN_free(bnG); BN_free(bnX); BN_free(bnY); BN_CTX_free(ctx)

  discard BN_bin2bn(unsafeAddr MsePrimeBytes[0], cint(DhKeyLen), bnP)
  discard BN_set_word(bnG, 2)
  if BN_rand(bnX, 160, -1, 0) != 1:
    raise newException(CatchableError, "BN_rand failed")
  if BN_mod_exp(bnY, bnG, bnX, bnP, ctx) != 1:
    raise newException(CatchableError, "BN_mod_exp failed")

  let privLen = BN_num_bytes(bnX)
  result.privKey = newSeq[byte](privLen)
  if privLen > 0:
    discard BN_bn2bin(bnX, addr result.privKey[0])

  let pubLen = BN_num_bytes(bnY)
  let off = DhKeyLen - pubLen
  if pubLen > 0:
    discard BN_bn2bin(bnY, addr result.pubKey[off])

proc dhComputeSecret*(remotePub: openArray[byte], privKey: seq[byte]): array[DhKeyLen, byte] =
  let bnP = BN_new()
  let bnR = BN_new()
  let bnX = BN_new()
  let bnS = BN_new()
  let ctx = BN_CTX_new()
  defer:
    BN_free(bnP); BN_free(bnR); BN_free(bnX); BN_free(bnS); BN_CTX_free(ctx)

  discard BN_bin2bn(unsafeAddr MsePrimeBytes[0], cint(DhKeyLen), bnP)
  discard BN_bin2bn(unsafeAddr remotePub[0], cint(remotePub.len), bnR)
  discard BN_bin2bn(unsafeAddr privKey[0], cint(privKey.len), bnX)
  if BN_mod_exp(bnS, bnR, bnX, bnP, ctx) != 1:
    raise newException(CatchableError, "BN_mod_exp failed")

  let sLen = BN_num_bytes(bnS)
  let off = DhKeyLen - sLen
  if sLen > 0:
    discard BN_bn2bin(bnS, addr result[off])

# ============ MseStream (RC4 stream wrapper) ============

type
  MseStream* = ref object of AsyncStream
    inner*: AsyncStream
    enc*: Rc4State
    dec*: Rc4State

proc mseRead(stream: AsyncStream, size: int): CpsFuture[string] {.cps, nosinks.} =
  let mse = MseStream(stream)
  var data: string = await mse.inner.read(size)
  mse.dec.processInPlace(data)
  return data

proc mseWrite(stream: AsyncStream, data: string): CpsVoidFuture {.cps, nosinks.} =
  let mse = MseStream(stream)
  var encrypted = data
  mse.enc.processInPlace(encrypted)
  await mse.inner.write(encrypted)

proc mseClose(stream: AsyncStream) =
  let mse = MseStream(stream)
  mse.inner.close()

proc newMseStream*(inner: AsyncStream, enc, dec: Rc4State): MseStream =
  result = MseStream(inner: inner, enc: enc, dec: dec)
  result.readProc = mseRead
  result.writeProc = mseWrite
  result.closeProc = mseClose

# ============ MSE Initiator Handshake ============

type
  MseInitiateOffer = object
    enc: Rc4State
    dec: Rc4State
    vcPattern: array[MseVcLen, byte]

proc buildEncryptedVcPattern(dec: Rc4State): array[MseVcLen, byte] =
  var scanDec = dec
  var i = 0
  while i < MseVcLen:
    result[i] = scanDec.nextByte()
    inc i

proc mseInitiatePrepareOffer(stream: AsyncStream,
                             infoHash: array[20, byte],
                             cryptoProvide: uint32): CpsFuture[MseInitiateOffer] {.cps, nosinks.} =
  var offer: MseInitiateOffer
  let skeyStr = bytesToStr(infoHash)
  let kp = dhGenerateKeyPair()
  var yaPlusPadA = bytesToStr(kp.pubKey)
  yaPlusPadA.add(randomBytes(randomPadLen()))
  await stream.write(yaPlusPadA)

  let yb = await readExactDhPub(stream)

  let secret = dhComputeSecret(yb, kp.privKey)
  let secretStr = bytesToStr(secret)

  let keyA = sha1Cat("keyA", secretStr, skeyStr)
  let keyB = sha1Cat("keyB", secretStr, skeyStr)
  var enc = initRc4(keyA)
  enc.discardBytes(MseRc4Discard)
  var dec = initRc4(keyB)
  dec.discardBytes(MseRc4Discard)

  let req1Hash = sha1Cat("req1", secretStr)
  let req2Hash = sha1Cat("req2", skeyStr)
  let req3Hash = sha1Cat("req3", secretStr)

  var encPayload = "\x00\x00\x00\x00\x00\x00\x00\x00"
  encPayload.writeUint32BE(cryptoProvide)
  encPayload.writeU16BE(0)
  encPayload.writeU16BE(0)
  enc.processInPlace(encPayload)

  var offerMsg = ""
  offerMsg.add(bytesToStr(req1Hash))
  offerMsg.add(bytesToStr(xorHash(req2Hash, req3Hash)))
  offerMsg.add(encPayload)
  await stream.write(offerMsg)

  offer.enc = enc
  offer.dec = dec
  offer.vcPattern = buildEncryptedVcPattern(dec)
  return offer

proc mseInitiateReadSelection(stream: AsyncStream,
                              cryptoProvide: uint32,
                              decIn: Rc4State,
                              vcPattern: array[MseVcLen, byte]
                              ): CpsFuture[tuple[cryptoSelect: uint32, dec: Rc4State]] {.cps, nosinks.} =
  var selection: tuple[cryptoSelect: uint32, dec: Rc4State]
  var dec = decIn
  var scanBuf = ""
  var vcPos = -1
  let maxScan = MsePadMax + MseVcLen + 64

  while scanBuf.len < maxScan:
    let chunk = await stream.read(min(256, maxScan - scanBuf.len))
    if chunk.len == 0:
      raise newException(AsyncIoError, "MSE: VC not found, connection closed")
    let prevLen = scanBuf.len
    scanBuf.add(chunk)

    var si = max(0, prevLen - MseVcLen + 1)
    while si <= scanBuf.len - MseVcLen:
      var matched = true
      var sj = 0
      while sj < MseVcLen:
        if scanBuf[si + sj].byte != vcPattern[sj]:
          matched = false
          break
        inc sj
      if matched:
        vcPos = si
        break
      inc si

    if vcPos >= 0:
      break

  if vcPos < 0:
    raise newException(AsyncIoError, "MSE: VC pattern not found")

  dec.discardBytes(MseVcLen)
  let afterVc = vcPos + MseVcLen
  var respBuf = copySlice(scanBuf, afterVc, scanBuf.len)
  while respBuf.len < 6:
    let more = await stream.read(6 - respBuf.len)
    if more.len == 0:
      raise newException(AsyncIoError, "MSE: incomplete response")
    respBuf.add(more)

  dec.processInPlace(respBuf)
  let cryptoSelect = readUint32BE(respBuf, 0)
  let padDLen = int(readU16BE(respBuf, 4))
  if (cryptoSelect and cryptoProvide) == 0:
    raise newException(AsyncIoError, "MSE: no common crypto method")

  let padDHave = respBuf.len - 6
  if padDHave < padDLen:
    var remaining = padDLen - padDHave
    while remaining > 0:
      let more = await stream.read(min(256, remaining))
      if more.len == 0:
        raise newException(AsyncIoError, "MSE: incomplete PadD")
      var decMore = more
      dec.processInPlace(decMore)
      remaining -= more.len

  selection.cryptoSelect = cryptoSelect
  selection.dec = dec
  return selection

proc mseInitiate*(stream: AsyncStream, infoHash: array[20, byte],
                  cryptoProvide: uint32 = MseCryptoRc4 or MseCryptoPlaintext
                  ): CpsFuture[MseResult] {.cps, nosinks.} =
  ## MSE handshake as initiator (outgoing connection).
  let offer = await mseInitiatePrepareOffer(stream, infoHash, cryptoProvide)
  let selection = await mseInitiateReadSelection(stream, cryptoProvide, offer.dec, offer.vcPattern)

  if selection.cryptoSelect == MseCryptoRc4:
    return MseResult(
      stream: newMseStream(stream, offer.enc, selection.dec).AsyncStream,
      isEncrypted: true,
      cryptoSelected: MseCryptoRc4
    )

  return MseResult(stream: stream, isEncrypted: false, cryptoSelected: MseCryptoPlaintext)

# ============ MSE Responder Handshake ============

proc mseRespond*(stream: AsyncStream, infoHash: array[20, byte],
                 yaData: string,
                 preferRc4: bool = true
                 ): CpsFuture[MseResult] {.cps, nosinks.} =
  ## MSE handshake as responder (incoming connection).
  ## yaData: the 96-byte DH public key already read from stream.
  let skeyStr: string = bytesToStr(infoHash)

  if yaData.len != DhKeyLen:
    raise newException(AsyncIoError, "MSE: invalid Ya length: " & $yaData.len)

  var ya: array[DhKeyLen, byte]
  copyMem(addr ya[0], unsafeAddr yaData[0], DhKeyLen)

  # 1. Generate our DH key pair and send Yb + PadB
  let kp = dhGenerateKeyPair()
  let secret: array[DhKeyLen, byte] = dhComputeSecret(ya, kp.privKey)
  let secretStr: string = bytesToStr(secret)

  var msg1: string = bytesToStr(kp.pubKey)
  msg1.add(randomBytes(randomPadLen()))
  await stream.write(msg1)

  # 2. Scan for HASH('req1' || S) in initiator's stream (after Ya)
  let req1Hash: array[20, byte] = sha1Cat("req1", secretStr)
  let req1Str: string = bytesToStr(req1Hash)

  var scanBuf = ""
  var hashPos = -1
  let maxScan: int = MsePadMax + 20 + 20 + 14 + MsePadMax + 128

  while scanBuf.len < maxScan:
    let chunk: string = await stream.read(min(256, maxScan - scanBuf.len))
    if chunk.len == 0:
      raise newException(AsyncIoError, "MSE: req1 hash not found, connection closed")
    let prevLen: int = scanBuf.len
    scanBuf.add(chunk)

    var ri: int = max(0, prevLen - 19)
    while ri <= scanBuf.len - 20:
      var matched = true
      var rj = 0
      while rj < 20:
        if scanBuf[ri + rj] != req1Str[rj]:
          matched = false
          break
        rj += 1
      if matched:
        hashPos = ri
        break
      ri += 1

    if hashPos >= 0:
      break

  if hashPos < 0:
    raise newException(AsyncIoError, "MSE: req1 hash not found")

  # 3. Read XOR hash and verify SKEY
  let xorStart: int = hashPos + 20
  while scanBuf.len < xorStart + 20:
    let more: string = await stream.read(xorStart + 20 - scanBuf.len)
    if more.len == 0:
      raise newException(AsyncIoError, "MSE: incomplete XOR hash")
    scanBuf.add(more)

  var receivedXor: array[20, byte]
  copyMem(addr receivedXor[0], unsafeAddr scanBuf[xorStart], 20)

  let req3Hash: array[20, byte] = sha1Cat("req3", secretStr)
  let derivedReq2: array[20, byte] = xorHash(receivedXor, req3Hash)
  let expectedReq2: array[20, byte] = sha1Cat("req2", skeyStr)

  if derivedReq2 != expectedReq2:
    raise newException(AsyncIoError, "MSE: SKEY verification failed")

  # 4. Derive RC4 keys (responder: decrypt with keyA, encrypt with keyB)
  let keyA: array[20, byte] = sha1Cat("keyA", secretStr, skeyStr)
  let keyB: array[20, byte] = sha1Cat("keyB", secretStr, skeyStr)
  var dec: Rc4State = initRc4(keyA)  # A→B (incoming from initiator)
  dec.discardBytes(MseRc4Discard)
  var enc: Rc4State = initRc4(keyB)  # B→A (our outgoing)
  enc.discardBytes(MseRc4Discard)

  # 5. Decrypt initiator's encrypted block
  let encStart: int = xorStart + 20
  let needMin: int = encStart + MseVcLen + 4 + 2
  while scanBuf.len < needMin:
    let more: string = await stream.read(needMin - scanBuf.len)
    if more.len == 0:
      raise newException(AsyncIoError, "MSE: incomplete encrypted block")
    scanBuf.add(more)

  var encBlock: string = copySlice(scanBuf, encStart, scanBuf.len)
  dec.processInPlace(encBlock)

  # Verify VC
  var vcIdx = 0
  while vcIdx < MseVcLen:
    if encBlock[vcIdx].byte != 0:
      raise newException(AsyncIoError, "MSE: VC verification failed")
    vcIdx += 1

  let peerCryptoProvide: uint32 = readUint32BE(encBlock, MseVcLen)
  let padCLen: int = int(readU16BE(encBlock, MseVcLen + 4))

  # Read PadC + IA length
  let needPadC: int = MseVcLen + 4 + 2 + padCLen + 2
  while encBlock.len < needPadC:
    var more: string = await stream.read(needPadC - encBlock.len)
    if more.len == 0:
      raise newException(AsyncIoError, "MSE: incomplete PadC")
    dec.processInPlace(more)
    encBlock.add(more)

  let iaLen: int = int(readU16BE(encBlock, MseVcLen + 4 + 2 + padCLen))
  var ia = ""

  # Read IA (initial payload)
  if iaLen > 0:
    let iaStart: int = MseVcLen + 4 + 2 + padCLen + 2
    let needIa: int = iaStart + iaLen
    while encBlock.len < needIa:
      var more: string = await stream.read(needIa - encBlock.len)
      if more.len == 0:
        raise newException(AsyncIoError, "MSE: incomplete IA")
      dec.processInPlace(more)
      encBlock.add(more)
    ia = copySlice(encBlock, iaStart, iaStart + iaLen)

  # 6. Select crypto and send response
  var selectedCrypto: uint32 = 0
  if preferRc4 and (peerCryptoProvide and MseCryptoRc4) != 0:
    selectedCrypto = MseCryptoRc4
  elif (peerCryptoProvide and MseCryptoPlaintext) != 0:
    selectedCrypto = MseCryptoPlaintext
  elif (peerCryptoProvide and MseCryptoRc4) != 0:
    selectedCrypto = MseCryptoRc4
  else:
    raise newException(AsyncIoError, "MSE: no common crypto method")

  var respPayload = "\x00\x00\x00\x00\x00\x00\x00\x00"  # VC (8 zero bytes)
  respPayload.writeUint32BE(selectedCrypto)
  respPayload.writeU16BE(0)  # PadD length = 0
  enc.processInPlace(respPayload)
  await stream.write(respPayload)

  if selectedCrypto == MseCryptoRc4:
    return MseResult(
      stream: newMseStream(stream, enc, dec).AsyncStream,
      isEncrypted: true,
      cryptoSelected: MseCryptoRc4,
      initialPayload: ia,
      matchedInfoHash: infoHash
    )
  else:
    return MseResult(
      stream: stream,
      isEncrypted: false,
      cryptoSelected: MseCryptoPlaintext,
      initialPayload: ia,
      matchedInfoHash: infoHash
    )

proc mseRespondMulti*(stream: AsyncStream, infoHashes: seq[array[20, byte]],
                      yaData: string,
                      preferRc4: bool = true
                      ): CpsFuture[MseResult] {.cps, nosinks.} =
  ## MSE handshake as responder, trying multiple info hashes as SKEY.
  ## Returns MseResult with matchedInfoHash set to the hash that verified.
  ## Used by shared accept loops serving multiple torrents.
  if infoHashes.len == 0:
    raise newException(AsyncIoError, "MSE: no info hashes to try")

  if yaData.len != DhKeyLen:
    raise newException(AsyncIoError, "MSE: invalid Ya length: " & $yaData.len)

  var ya: array[DhKeyLen, byte]
  copyMem(addr ya[0], unsafeAddr yaData[0], DhKeyLen)

  # 1. Generate our DH key pair and send Yb + PadB
  let kp = dhGenerateKeyPair()
  let multiSecret: array[DhKeyLen, byte] = dhComputeSecret(ya, kp.privKey)
  let multiSecretStr: string = bytesToStr(multiSecret)

  var multiMsg1: string = bytesToStr(kp.pubKey)
  multiMsg1.add(randomBytes(randomPadLen()))
  await stream.write(multiMsg1)

  # 2. Scan for HASH('req1' || S) in initiator's stream
  let multiReq1Hash: array[20, byte] = sha1Cat("req1", multiSecretStr)
  let multiReq1Str: string = bytesToStr(multiReq1Hash)

  var multiScanBuf = ""
  var multiHashPos = -1
  let multiMaxScan: int = MsePadMax + 20 + 20 + 14 + MsePadMax + 128

  while multiScanBuf.len < multiMaxScan:
    let multiChunk: string = await stream.read(min(256, multiMaxScan - multiScanBuf.len))
    if multiChunk.len == 0:
      raise newException(AsyncIoError, "MSE: req1 hash not found, connection closed")
    let multiPrevLen: int = multiScanBuf.len
    multiScanBuf.add(multiChunk)

    var mri: int = max(0, multiPrevLen - 19)
    while mri <= multiScanBuf.len - 20:
      var mMatched = true
      var mrj = 0
      while mrj < 20:
        if multiScanBuf[mri + mrj] != multiReq1Str[mrj]:
          mMatched = false
          break
        mrj += 1
      if mMatched:
        multiHashPos = mri
        break
      mri += 1

    if multiHashPos >= 0:
      break

  if multiHashPos < 0:
    raise newException(AsyncIoError, "MSE: req1 hash not found")

  # 3. Read XOR hash and try each info hash as SKEY
  let multiXorStart: int = multiHashPos + 20
  while multiScanBuf.len < multiXorStart + 20:
    let multiMore: string = await stream.read(multiXorStart + 20 - multiScanBuf.len)
    if multiMore.len == 0:
      raise newException(AsyncIoError, "MSE: incomplete XOR hash")
    multiScanBuf.add(multiMore)

  var multiReceivedXor: array[20, byte]
  copyMem(addr multiReceivedXor[0], unsafeAddr multiScanBuf[multiXorStart], 20)

  let multiReq3Hash: array[20, byte] = sha1Cat("req3", multiSecretStr)
  let multiDerivedReq2: array[20, byte] = xorHash(multiReceivedXor, multiReq3Hash)

  var matchedHash: array[20, byte]
  var matchFound = false
  var mhi = 0
  while mhi < infoHashes.len:
    let candidateSkeyStr: string = bytesToStr(infoHashes[mhi])
    let candidateReq2: array[20, byte] = sha1Cat("req2", candidateSkeyStr)
    if multiDerivedReq2 == candidateReq2:
      matchedHash = infoHashes[mhi]
      matchFound = true
      break
    mhi += 1

  if not matchFound:
    raise newException(AsyncIoError, "MSE: SKEY verification failed (no matching info hash)")

  let matchedSkeyStr: string = bytesToStr(matchedHash)

  # 4. Derive RC4 keys
  let multiKeyA: array[20, byte] = sha1Cat("keyA", multiSecretStr, matchedSkeyStr)
  let multiKeyB: array[20, byte] = sha1Cat("keyB", multiSecretStr, matchedSkeyStr)
  var multiDec: Rc4State = initRc4(multiKeyA)
  multiDec.discardBytes(MseRc4Discard)
  var multiEnc: Rc4State = initRc4(multiKeyB)
  multiEnc.discardBytes(MseRc4Discard)

  # 5. Decrypt initiator's encrypted block
  let multiEncStart: int = multiXorStart + 20
  let multiNeedMin: int = multiEncStart + MseVcLen + 4 + 2
  while multiScanBuf.len < multiNeedMin:
    let mMore2: string = await stream.read(multiNeedMin - multiScanBuf.len)
    if mMore2.len == 0:
      raise newException(AsyncIoError, "MSE: incomplete encrypted block")
    multiScanBuf.add(mMore2)

  var multiEncBlock: string = copySlice(multiScanBuf, multiEncStart, multiScanBuf.len)
  multiDec.processInPlace(multiEncBlock)

  # Verify VC
  var mvcIdx = 0
  while mvcIdx < MseVcLen:
    if multiEncBlock[mvcIdx].byte != 0:
      raise newException(AsyncIoError, "MSE: VC verification failed")
    mvcIdx += 1

  let multiPeerCrypto: uint32 = readUint32BE(multiEncBlock, MseVcLen)
  let multiPadCLen: int = int(readU16BE(multiEncBlock, MseVcLen + 4))

  let multiNeedPadC: int = MseVcLen + 4 + 2 + multiPadCLen + 2
  while multiEncBlock.len < multiNeedPadC:
    var mMore3: string = await stream.read(multiNeedPadC - multiEncBlock.len)
    if mMore3.len == 0:
      raise newException(AsyncIoError, "MSE: incomplete PadC")
    multiDec.processInPlace(mMore3)
    multiEncBlock.add(mMore3)

  let multiIaLen: int = int(readU16BE(multiEncBlock, MseVcLen + 4 + 2 + multiPadCLen))
  var multiIa = ""

  if multiIaLen > 0:
    let multiIaStart: int = MseVcLen + 4 + 2 + multiPadCLen + 2
    let multiNeedIa: int = multiIaStart + multiIaLen
    while multiEncBlock.len < multiNeedIa:
      var mMore4: string = await stream.read(multiNeedIa - multiEncBlock.len)
      if mMore4.len == 0:
        raise newException(AsyncIoError, "MSE: incomplete IA")
      multiDec.processInPlace(mMore4)
      multiEncBlock.add(mMore4)
    multiIa = copySlice(multiEncBlock, multiIaStart, multiIaStart + multiIaLen)

  # 6. Select crypto and send response
  var multiSelectedCrypto: uint32 = 0
  if preferRc4 and (multiPeerCrypto and MseCryptoRc4) != 0:
    multiSelectedCrypto = MseCryptoRc4
  elif (multiPeerCrypto and MseCryptoPlaintext) != 0:
    multiSelectedCrypto = MseCryptoPlaintext
  elif (multiPeerCrypto and MseCryptoRc4) != 0:
    multiSelectedCrypto = MseCryptoRc4
  else:
    raise newException(AsyncIoError, "MSE: no common crypto method")

  var multiRespPayload = "\x00\x00\x00\x00\x00\x00\x00\x00"
  multiRespPayload.writeUint32BE(multiSelectedCrypto)
  multiRespPayload.writeU16BE(0)
  multiEnc.processInPlace(multiRespPayload)
  await stream.write(multiRespPayload)

  if multiSelectedCrypto == MseCryptoRc4:
    return MseResult(
      stream: newMseStream(stream, multiEnc, multiDec).AsyncStream,
      isEncrypted: true,
      cryptoSelected: MseCryptoRc4,
      initialPayload: multiIa,
      matchedInfoHash: matchedHash
    )
  else:
    return MseResult(
      stream: stream,
      isEncrypted: false,
      cryptoSelected: MseCryptoPlaintext,
      initialPayload: multiIa,
      matchedInfoHash: matchedHash
    )
