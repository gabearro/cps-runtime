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

  ## Max bytes to scan for responder: PadA + req1(20) + xor(20) +
  ## VC+crypto+padCLen(14) + PadC + safety margin.
  MseResponderMaxScan = MsePadMax + 20 + 20 + 14 + MsePadMax + 128

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

proc findInBuf(buf, pattern: string, startFrom: int = 0): int =
  ## Find first occurrence of pattern in buf starting from startFrom.
  ## Returns index or -1 if not found.
  let patLen = pattern.len
  if patLen == 0 or buf.len < patLen:
    return -1
  var i = startFrom
  while i <= buf.len - patLen:
    var j = 0
    while j < patLen:
      if buf[i + j] != pattern[j]:
        break
      inc j
    if j == patLen:
      return i
    inc i
  return -1

proc selectCrypto(peerProvide: uint32, preferRc4: bool): uint32 =
  ## Choose a common crypto method from the peer's offer.
  if preferRc4 and (peerProvide and MseCryptoRc4) != 0:
    return MseCryptoRc4
  if (peerProvide and MseCryptoPlaintext) != 0:
    return MseCryptoPlaintext
  if (peerProvide and MseCryptoRc4) != 0:
    return MseCryptoRc4
  raise newException(AsyncIoError, "MSE: no common crypto method")

proc verifyVc(encBlock: string) =
  ## Verify the 8-byte VC (verification constant) is all zeros.
  var i = 0
  while i < MseVcLen:
    if encBlock[i].byte != 0:
      raise newException(AsyncIoError, "MSE: VC verification failed")
    inc i

# ============ Stream Helpers ============

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

proc scanStreamFor(stream: AsyncStream, pattern: string,
                   maxScan: int, errMsg: string): CpsFuture[tuple[buf: string, pos: int]] {.cps, nosinks.} =
  ## Read from stream until `pattern` is found or `maxScan` bytes exhausted.
  ## Returns the accumulated buffer and the position of the first match.
  var scanBuf: string = newStringOfCap(maxScan)
  var foundPos = -1
  let patLen: int = pattern.len
  while scanBuf.len < maxScan:
    let chunk: string = await stream.read(min(256, maxScan - scanBuf.len))
    if chunk.len == 0:
      raise newException(AsyncIoError, errMsg & ", connection closed")
    let prevLen: int = scanBuf.len
    scanBuf.add(chunk)
    let startSearch: int = max(0, prevLen - patLen + 1)
    foundPos = findInBuf(scanBuf, pattern, startSearch)
    if foundPos >= 0:
      break
  if foundPos < 0:
    raise newException(AsyncIoError, errMsg)
  return (scanBuf, foundPos)

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

proc buildMseResult(stream: AsyncStream, enc, dec: Rc4State,
                    selectedCrypto: uint32, ia: string,
                    matchedHash: array[20, byte]): MseResult =
  if selectedCrypto == MseCryptoRc4:
    return MseResult(
      stream: newMseStream(stream, enc, dec).AsyncStream,
      isEncrypted: true,
      cryptoSelected: MseCryptoRc4,
      initialPayload: ia,
      matchedInfoHash: matchedHash
    )
  return MseResult(
    stream: stream,
    isEncrypted: false,
    cryptoSelected: MseCryptoPlaintext,
    initialPayload: ia,
    matchedInfoHash: matchedHash
  )

# ============ MSE Initiator Handshake ============

proc mseInitiate*(stream: AsyncStream, infoHash: array[20, byte],
                  cryptoProvide: uint32 = MseCryptoRc4 or MseCryptoPlaintext
                  ): CpsFuture[MseResult] {.cps, nosinks.} =
  ## MSE handshake as initiator (outgoing connection).
  ##
  ## 1. Send Ya + PadA
  ## 2. Receive Yb, derive shared secret S
  ## 3. Derive RC4 keys from S + SKEY (info hash)
  ## 4. Send req1/req2/req3 hashes + encrypted offer (VC + crypto flags)
  ## 5. Scan response for encrypted VC, read crypto selection + PadD
  let skeyStr: string = bytesToStr(infoHash)

  # 1. DH key exchange
  let kp = dhGenerateKeyPair()
  var yaPlusPadA: string = bytesToStr(kp.pubKey)
  yaPlusPadA.add(randomBytes(randomPadLen()))
  await stream.write(yaPlusPadA)

  let yb: array[DhKeyLen, byte] = await readExactDhPub(stream)
  let secret: array[DhKeyLen, byte] = dhComputeSecret(yb, kp.privKey)
  let secretStr: string = bytesToStr(secret)

  # 2. Derive RC4 keys
  let keyA: array[20, byte] = sha1Cat("keyA", secretStr, skeyStr)
  let keyB: array[20, byte] = sha1Cat("keyB", secretStr, skeyStr)
  var enc: Rc4State = initRc4(keyA)
  enc.discardBytes(MseRc4Discard)
  var dec: Rc4State = initRc4(keyB)
  dec.discardBytes(MseRc4Discard)

  # 3. Send offer: req1 || XOR(req2, req3) || encrypt(VC + crypto_provide + padC_len + IA_len)
  let req1Hash: array[20, byte] = sha1Cat("req1", secretStr)
  let req2Hash: array[20, byte] = sha1Cat("req2", skeyStr)
  let req3Hash: array[20, byte] = sha1Cat("req3", secretStr)

  var encPayload = "\x00\x00\x00\x00\x00\x00\x00\x00"  # VC
  encPayload.writeUint32BE(cryptoProvide)
  encPayload.writeUint16BE(0)  # PadC length
  encPayload.writeUint16BE(0)  # IA length
  enc.processInPlace(encPayload)

  var offerMsg: string = newStringOfCap(20 + 20 + encPayload.len)
  offerMsg.add(bytesToStr(req1Hash))
  offerMsg.add(bytesToStr(xorHash(req2Hash, req3Hash)))
  offerMsg.add(encPayload)
  await stream.write(offerMsg)

  # 4. Scan response for encrypted VC pattern
  # The responder encrypts 8 zero bytes with its RC4 enc (= our dec keystream).
  var scanDec: Rc4State = dec
  var vcPatStr: string = newString(MseVcLen)
  var vcIdx = 0
  while vcIdx < MseVcLen:
    vcPatStr[vcIdx] = char(scanDec.nextByte())
    inc vcIdx

  let maxScan: int = MsePadMax + MseVcLen + 64
  let scan = await scanStreamFor(stream, vcPatStr, maxScan, "MSE: VC pattern not found")

  # 5. Read crypto selection + PadD
  dec.discardBytes(MseVcLen)
  let afterVc: int = scan.pos + MseVcLen
  var respBuf: string = copySlice(scan.buf, afterVc, scan.buf.len)
  while respBuf.len < 6:
    let more: string = await stream.read(6 - respBuf.len)
    if more.len == 0:
      raise newException(AsyncIoError, "MSE: incomplete response")
    respBuf.add(more)

  dec.processInPlace(respBuf)
  let cryptoSelect: uint32 = readUint32BE(respBuf, 0)
  let padDLen: int = int(readUint16BE(respBuf, 4))
  if (cryptoSelect and cryptoProvide) == 0:
    raise newException(AsyncIoError, "MSE: no common crypto method")

  # Consume PadD
  let padDHave: int = respBuf.len - 6
  if padDHave < padDLen:
    var remaining: int = padDLen - padDHave
    while remaining > 0:
      let more: string = await stream.read(min(256, remaining))
      if more.len == 0:
        raise newException(AsyncIoError, "MSE: incomplete PadD")
      var decMore: string = more
      dec.processInPlace(decMore)
      remaining -= more.len

  var emptyHash: array[20, byte]
  return buildMseResult(stream, enc, dec, cryptoSelect, "", emptyHash)

# ============ MSE Responder Handshake ============

proc mseRespondMulti*(stream: AsyncStream, infoHashes: seq[array[20, byte]],
                      yaData: string,
                      preferRc4: bool = true
                      ): CpsFuture[MseResult] {.cps, nosinks.} =
  ## MSE handshake as responder (incoming connection).
  ## Tries each info hash as SKEY; matchedInfoHash identifies which one verified.
  ##
  ## 1. Receive Ya (already in yaData), send Yb + PadB
  ## 2. Derive shared secret S, scan for HASH('req1' || S)
  ## 3. Read XOR hash, verify SKEY against candidate info hashes
  ## 4. Derive RC4 keys, decrypt initiator's offer (VC + crypto + PadC + IA)
  ## 5. Select crypto mode, send encrypted response
  if infoHashes.len == 0:
    raise newException(AsyncIoError, "MSE: no info hashes to try")
  if yaData.len != DhKeyLen:
    raise newException(AsyncIoError, "MSE: invalid Ya length: " & $yaData.len)

  var ya: array[DhKeyLen, byte]
  copyMem(addr ya[0], unsafeAddr yaData[0], DhKeyLen)

  # 1. Generate our DH key pair and send Yb + PadB
  let kp = dhGenerateKeyPair()
  let secret: array[DhKeyLen, byte] = dhComputeSecret(ya, kp.privKey)
  let secretStr: string = bytesToStr(secret)

  var ybPlusPadB: string = bytesToStr(kp.pubKey)
  ybPlusPadB.add(randomBytes(randomPadLen()))
  await stream.write(ybPlusPadB)

  # 2. Scan for HASH('req1' || S)
  let req1Str: string = bytesToStr(sha1Cat("req1", secretStr))
  let scan = await scanStreamFor(stream, req1Str, MseResponderMaxScan,
                                 "MSE: req1 hash not found")
  var scanBuf: string = scan.buf
  let hashPos: int = scan.pos

  # 3. Read XOR hash and verify SKEY against candidate info hashes
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

  var matchedHash: array[20, byte]
  var matchFound = false
  var hi = 0
  while hi < infoHashes.len:
    let candidateReq2: array[20, byte] = sha1Cat("req2", bytesToStr(infoHashes[hi]))
    if derivedReq2 == candidateReq2:
      matchedHash = infoHashes[hi]
      matchFound = true
      break
    hi += 1

  if not matchFound:
    raise newException(AsyncIoError, "MSE: SKEY verification failed")

  let matchedSkeyStr: string = bytesToStr(matchedHash)

  # 4. Derive RC4 keys (responder: decrypt with keyA, encrypt with keyB)
  let keyA: array[20, byte] = sha1Cat("keyA", secretStr, matchedSkeyStr)
  let keyB: array[20, byte] = sha1Cat("keyB", secretStr, matchedSkeyStr)
  var dec: Rc4State = initRc4(keyA)  # A→B (incoming from initiator)
  dec.discardBytes(MseRc4Discard)
  var enc: Rc4State = initRc4(keyB)  # B→A (our outgoing)
  enc.discardBytes(MseRc4Discard)

  # 5. Decrypt initiator's encrypted block (VC + crypto_provide + padC_len)
  let encStart: int = xorStart + 20
  let needMin: int = encStart + MseVcLen + 4 + 2
  while scanBuf.len < needMin:
    let more: string = await stream.read(needMin - scanBuf.len)
    if more.len == 0:
      raise newException(AsyncIoError, "MSE: incomplete encrypted block")
    scanBuf.add(more)

  var encBlock: string = copySlice(scanBuf, encStart, scanBuf.len)
  dec.processInPlace(encBlock)

  verifyVc(encBlock)

  let peerCryptoProvide: uint32 = readUint32BE(encBlock, MseVcLen)
  let padCLen: int = int(readUint16BE(encBlock, MseVcLen + 4))

  # Read PadC + IA length
  let needPadC: int = MseVcLen + 4 + 2 + padCLen + 2
  while encBlock.len < needPadC:
    var more: string = await stream.read(needPadC - encBlock.len)
    if more.len == 0:
      raise newException(AsyncIoError, "MSE: incomplete PadC")
    dec.processInPlace(more)
    encBlock.add(more)

  let iaLen: int = int(readUint16BE(encBlock, MseVcLen + 4 + 2 + padCLen))
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
  let selectedCrypto: uint32 = selectCrypto(peerCryptoProvide, preferRc4)

  var respPayload = "\x00\x00\x00\x00\x00\x00\x00\x00"  # VC (8 zero bytes)
  respPayload.writeUint32BE(selectedCrypto)
  respPayload.writeUint16BE(0)  # PadD length = 0
  enc.processInPlace(respPayload)
  await stream.write(respPayload)

  return buildMseResult(stream, enc, dec, selectedCrypto, ia, matchedHash)

proc mseRespond*(stream: AsyncStream, infoHash: array[20, byte],
                 yaData: string,
                 preferRc4: bool = true
                 ): CpsFuture[MseResult] {.cps, nosinks.} =
  ## MSE handshake as responder with a single info hash.
  return await mseRespondMulti(stream, @[infoHash], yaData, preferRc4)
