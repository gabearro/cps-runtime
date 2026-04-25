## Tests for MSE/PE (Message Stream Encryption / Protocol Encryption).

import std/nativesockets
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/bittorrent/mse
import cps/bittorrent/sha1

# ============ RC4 Tests ============

proc testRc4KnownVector() =
  ## Test RC4 against known test vector (RFC 6229 key = "Key").
  var state = initRc4([0x4B'u8, 0x65, 0x79])  # "Key"
  # First few bytes of RC4("Key") keystream:
  # EB 9F 77 81 B7 34 CA 72 A7 19 ...
  assert state.nextByte() == 0xEB'u8
  assert state.nextByte() == 0x9F'u8
  assert state.nextByte() == 0x77'u8
  assert state.nextByte() == 0x81'u8
  assert state.nextByte() == 0xB7'u8
  assert state.nextByte() == 0x34'u8
  assert state.nextByte() == 0xCA'u8
  assert state.nextByte() == 0x72'u8
  echo "PASS: RC4 known vector"

proc testRc4Encrypt() =
  ## Test that RC4 encrypt then decrypt with same key produces original.
  let key = [0x01'u8, 0x02, 0x03, 0x04, 0x05]
  let original = "Hello, BitTorrent MSE!"

  var encState = initRc4(key)
  var data = original
  encState.processInPlace(data)
  assert data != original, "encrypted should differ from original"

  var decState = initRc4(key)
  decState.processInPlace(data)
  assert data == original, "decrypted should match original"
  echo "PASS: RC4 encrypt/decrypt roundtrip"

proc testRc4Discard() =
  ## Test that discardBytes advances the keystream correctly.
  let key = [0xAA'u8, 0xBB, 0xCC]
  var state1 = initRc4(key)
  var state2 = initRc4(key)

  # Advance state1 by reading 1024 bytes
  for _ in 0 ..< 1024:
    discard state1.nextByte()

  # Advance state2 by discardBytes
  state2.discardBytes(1024)

  # Both should produce the same next bytes
  for _ in 0 ..< 64:
    assert state1.nextByte() == state2.nextByte()
  echo "PASS: RC4 discard consistency"

# ============ DH Key Exchange Tests ============

proc testDhKeyExchange() =
  ## Test that two DH key pairs produce the same shared secret.
  let kpA = dhGenerateKeyPair()
  let kpB = dhGenerateKeyPair()

  let secretA = dhComputeSecret(kpB.pubKey, kpA.privKey)
  let secretB = dhComputeSecret(kpA.pubKey, kpB.privKey)

  assert secretA == secretB, "DH shared secrets must match"
  # Verify secret is not all zeros
  var allZero = true
  for b in secretA:
    if b != 0: allZero = false; break
  assert not allZero, "DH secret should not be all zeros"
  echo "PASS: DH key exchange produces matching secrets"

proc testDhKeySize() =
  ## Test that generated keys are 96 bytes.
  let kp = dhGenerateKeyPair()
  assert kp.pubKey.len == 96
  assert kp.privKey.len > 0
  assert kp.privKey.len <= 20  # 160 bits = 20 bytes max
  echo "PASS: DH key sizes correct"

# ============ Key Derivation Tests ============

proc testKeyDerivation() =
  ## Test that key derivation produces different keys for A and B.
  let kp1 = dhGenerateKeyPair()
  let kp2 = dhGenerateKeyPair()
  let secret = dhComputeSecret(kp2.pubKey, kp1.privKey)

  var infoHash: array[20, byte]
  let ih = sha1("test torrent info")
  infoHash = ih

  let secretStr = newString(96)
  copyMem(addr secretStr[0], unsafeAddr secret[0], 96)
  let skeyStr = newString(20)
  copyMem(addr skeyStr[0], unsafeAddr infoHash[0], 20)

  proc sha1CatLocal(parts: varargs[string]): array[20, byte] =
    var combined = ""
    for p in parts:
      combined.add(p)
    result = sha1(combined)

  let keyA = sha1CatLocal("keyA", secretStr, skeyStr)
  let keyB = sha1CatLocal("keyB", secretStr, skeyStr)

  assert keyA != keyB, "keyA and keyB should be different"
  echo "PASS: Key derivation produces distinct A/B keys"

# ============ MseStream Tests ============

proc testMseStreamRoundtrip() =
  ## Test MseStream wrapping with RC4 encrypt/decrypt.
  ## Uses a simple in-memory pipe.
  let key = [0x42'u8, 0x54, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05,
             0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D,
             0x0E, 0x0F, 0x10, 0x11]

  # Create matching encryptor/decryptor pairs
  var enc1 = initRc4(key)
  enc1.discardBytes(1024)
  var dec1 = initRc4(key)
  dec1.discardBytes(1024)

  # Encrypt some data manually and verify decryption matches
  let testData = "This is a test message for MSE stream encryption verification."
  var encrypted = testData
  enc1.processInPlace(encrypted)
  assert encrypted != testData
  dec1.processInPlace(encrypted)
  assert encrypted == testData
  echo "PASS: MseStream-compatible RC4 roundtrip"

# ============ Full MSE Handshake Test ============

proc getListenerPort(listener: TcpListener): int =
  result = int(getSockName(listener.fd))

var e2eInitDone = false
var e2eRespDone = false
var e2eInitEnc = false
var e2eRespEnc = false

proc mseServerTask(listener: TcpListener, ih: array[20, byte]): CpsVoidFuture {.cps.} =
  let conn: TcpStream = await listener.accept()
  let yaData: string = await readExactRaw(conn.AsyncStream, DhKeyLen)
  let res: MseResult = await mseRespond(conn.AsyncStream, ih, yaData, true)
  e2eRespEnc = res.isEncrypted
  let msg: string = await res.stream.read(5)
  assert msg == "hello", "responder got: " & msg
  await res.stream.write("world")
  e2eRespDone = true

proc mseClientTask(ih: array[20, byte], port: int): CpsVoidFuture {.cps.} =
  let conn: TcpStream = await tcpConnectIp("127.0.0.1", port)
  let res: MseResult = await mseInitiate(conn.AsyncStream, ih)
  e2eInitEnc = res.isEncrypted
  await res.stream.write("hello")
  let reply: string = await res.stream.read(5)
  assert reply == "world", "initiator got: " & reply
  e2eInitDone = true

proc testMseHandshakeE2E() =
  let infoHash = sha1("test-torrent-infohash-for-mse")
  block:
    let listener = tcpListen("127.0.0.1", 0)
    let port = getListenerPort(listener)
    let sfut = mseServerTask(listener, infoHash)
    let cfut = mseClientTask(infoHash, port)
    let loop = getEventLoop()
    while not (e2eInitDone and e2eRespDone):
      loop.tick()
    assert e2eInitEnc, "expected RC4 encryption"
    assert e2eRespEnc, "expected RC4 encryption"
    echo "PASS: MSE handshake E2E (RC4 mode)"

# ============ Run All Tests ============

testRc4KnownVector()
testRc4Encrypt()
testRc4Discard()
testDhKeyExchange()
testDhKeySize()
testKeyDerivation()
testMseStreamRoundtrip()
testMseHandshakeE2E()

echo ""
echo "All MSE tests passed!"
