## Python QUIC interop tests.
##
## Validates native Nim QUIC packet handling against Python `aioquic`
## running inside an isolated virtual environment.

import std/[os, osproc, streams as stdstreams, strutils, times]
import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/udp
import cps/quic
import ./interop_helpers

proc hexToBytes(hex: string): seq[byte] =
  let s = hex.strip().replace(" ", "")
  doAssert s.len mod 2 == 0, "hex input length must be even"
  result = newSeq[byte](s.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(s[i * 2 .. i * 2 + 1]))

proc bytesToHex(data: openArray[byte]): string =
  result = newStringOfCap(data.len * 2)
  for b in data:
    result.add toHex(int(b), 2).toLowerAscii

proc seqContainsVersion(versions: seq[uint32], version: uint32): bool =
  for v in versions:
    if v == version:
      return true
  false

proc parsePacketHeaderAtStart(data: openArray[byte]): QuicPacketHeader =
  var off = 0
  parsePacketHeader(data, off)

proc runLoopUntilFinished[T](f: CpsFuture[T], maxTicks: int = 10_000) =
  let loop = getEventLoop()
  var ticks = 0
  while not f.finished and ticks < maxTicks:
    loop.tick()
    inc ticks
  doAssert f.finished, "Timed out waiting for CPS future to finish"

proc runLoopUntilFinished(f: CpsVoidFuture, maxTicks: int = 10_000) =
  let loop = getEventLoop()
  var ticks = 0
  while not f.finished and ticks < maxTicks:
    loop.tick()
    inc ticks
  doAssert f.finished, "Timed out waiting for CPS void future to finish"

block testNimClientToPythonServerVersionNegotiation:
  let venvPython = ensureAioquicVenv()
  let (certFile, keyFile) = generateTestCert()
  let pyFile = pythonFixturePath("quic_vn_server.py")
  let portFile = getTempDir() / ("cps_quic_vn_port_" & $int64(epochTime() * 1_000_000.0) & ".txt")
  if fileExists(portFile):
    removeFile(portFile)

  let pyProcess = startProcess(
    venvPython,
    args = [pyFile, certFile, keyFile, portFile],
    options = {poStdErrToStdOut}
  )
  let portLine = waitForFileLine(portFile, timeoutMs = 15_000)
  let port = parseInt(portLine)

  let clientSock = newUdpSocket()
  clientSock.bindAddr("127.0.0.1", 0)

  proc clientTask(sock: UdpSocket, port: int): CpsFuture[seq[byte]] {.cps.} =
    let hdr = QuicPacketHeader(
      packetType: qptInitial,
      version: 0x1A2A3A4A'u32, # unsupported, triggers VN from server
      dstConnId: hexToBytes("8394c8f03e515708"),
      srcConnId: hexToBytes("f067a5502a4262b5"),
      token: @[],
      packetNumberLen: 1
    )
    var datagram = encodePacketHeader(hdr, payloadLen = 1, packetNumberLen = 1)
    appendPacketNumber(datagram, packetNumber = 0, packetNumberLen = 1)
    datagram.add 0'u8

    await sock.sendTo(bytesToString(datagram), "127.0.0.1", port)
    let response = await sock.recvFrom(4096)
    return stringToBytes(response.data)

  let cf = clientTask(clientSock, port)
  runLoopUntilFinished(cf)
  doAssert not cf.hasError(), "Nim->Python VN exchange failed"

  let resp = cf.read()
  let vn = parseVersionNegotiationPacket(resp)
  doAssert vn.destinationConnId == hexToBytes("f067a5502a4262b5")
  doAssert vn.sourceConnId == hexToBytes("8394c8f03e515708")
  doAssert vn.supportedVersions.len >= 1
  doAssert seqContainsVersion(vn.supportedVersions, 1'u32),
    "Python aioquic server did not advertise QUIC v1"

  clientSock.close()
  terminate(pyProcess)
  discard pyProcess.waitForExit()
  pyProcess.close()
  if fileExists(portFile):
    removeFile(portFile)
  echo "PASS: Nim QUIC client -> Python aioquic server (Version Negotiation)"

block testPythonClientToNimServerVersionNegotiation:
  let venvPython = ensureAioquicVenv()

  let serverSock = newUdpSocket()
  serverSock.bindAddr("127.0.0.1", 0)
  let serverPort = getUdpBoundPort(serverSock)
  let supportedVersions = @[0x1A2A3A4A'u32] # intentionally excludes both v1 and v2

  proc vnServerTask(sock: UdpSocket, versions: seq[uint32]): CpsVoidFuture {.cps.} =
    let req = await sock.recvFrom(4096)
    let data = stringToBytes(req.data)
    let hdr = parsePacketHeaderAtStart(data)
    doAssert hdr.packetType == qptInitial, "Expected Initial from Python client"
    doAssert hdr.version notin versions, "Test setup expects unsupported version from Python client"

    let vn = encodeVersionNegotiationPacket(
      sourceConnId = hdr.dstConnId,
      destinationConnId = hdr.srcConnId,
      supportedVersions = versions
    )
    await sock.sendTo(bytesToString(vn), req.address, req.port)

  let pyFile = pythonFixturePath("quic_vn_client.py")

  let sf = vnServerTask(serverSock, supportedVersions)
  let pyProcess = startProcess(
    venvPython,
    args = [pyFile, $serverPort],
    options = {poStdErrToStdOut}
  )

  runLoopUntilFinished(sf)
  doAssert not sf.hasError(), "Nim VN server task failed"

  let pyExit = pyProcess.waitForExit()
  let pyOutput = stdstreams.readAll(pyProcess.outputStream)
  pyProcess.close()
  doAssert pyExit == 0, "Python QUIC client failed (exit " & $pyExit & "): " & pyOutput
  doAssert "PYTHON_QUIC_CLIENT_VN_OK" in pyOutput,
    "Python QUIC client did not confirm VN handling: " & pyOutput

  serverSock.close()
  echo "PASS: Python aioquic client -> Nim QUIC server (Version Negotiation)"

block testNimRetryPacketParsedByPython:
  let venvPython = ensureAioquicVenv()
  let odcid = hexToBytes("8394c8f03e515708")
  let dcid = hexToBytes("1122334455667788")
  let scid = hexToBytes("99aabbccddeeff00")
  let token = hexToBytes("01020304a1a2a3a4")
  let pkt = encodeRetryPacket(
    version = QuicVersion1,
    destinationConnId = dcid,
    sourceConnId = scid,
    token = token,
    originalDestinationConnId = odcid
  )
  let pyFile = pythonFixturePath("quic_parse_retry.py")
  let p = startProcess(
    venvPython,
    args = [pyFile, bytesToHex(pkt)],
    options = {poStdErrToStdOut}
  )
  let exitCode = p.waitForExit()
  let output = stdstreams.readAll(p.outputStream)
  p.close()
  doAssert exitCode == 0, "Python failed to parse Nim Retry packet: " & output
  doAssert "PYTHON_RETRY_PARSE_OK" in output, "Missing Retry success marker: " & output
  echo "PASS: Nim QUIC Retry packet -> Python aioquic parser"

block testPythonRetryPacketParsedByNim:
  let venvPython = ensureAioquicVenv()
  let scidHex = "99aabbccddeeff00"
  let dcidHex = "1122334455667788"
  let odcidHex = "8394c8f03e515708"
  let tokenHex = "01020304a1a2a3a4"
  let pyFile = pythonFixturePath("quic_emit_retry.py")
  let p = startProcess(
    venvPython,
    args = [pyFile, scidHex, dcidHex, odcidHex, tokenHex],
    options = {poStdErrToStdOut}
  )
  let exitCode = p.waitForExit()
  let output = stdstreams.readAll(p.outputStream)
  p.close()
  doAssert exitCode == 0, "Python failed to emit Retry packet: " & output

  var retryHex = ""
  for l in output.splitLines():
    if l.startsWith("RETRYHEX:"):
      retryHex = l.split("RETRYHEX:")[1].strip()
      break
  doAssert retryHex.len > 0, "Python output missing RETRYHEX line: " & output

  let pkt = hexToBytes(retryHex)
  let parsed = parseRetryPacket(pkt)
  doAssert parsed.version == QuicVersion1
  doAssert parsed.srcConnId == hexToBytes(scidHex)
  doAssert parsed.dstConnId == hexToBytes(dcidHex)
  doAssert parsed.token == hexToBytes(tokenHex)
  doAssert validateRetryPacketIntegrity(pkt, hexToBytes(odcidHex))
  echo "PASS: Python aioquic Retry packet -> Nim QUIC parser"

block testNimProtectedHeaderParsedByPython:
  let venvPython = ensureAioquicVenv()
  let pyFile = pythonFixturePath("quic_parse_header.py")
  let conn = newQuicConnection(
    role = qcrClient,
    localConnId = hexToBytes("f067a5502a4262b5"),
    peerConnId = hexToBytes("8394c8f03e515708"),
    peerAddress = "127.0.0.1",
    peerPort = 4433
  )
  let initial = conn.encodeProtectedPacket(qptInitial, @[QuicFrame(kind: qfkPing)])
  var p = startProcess(
    venvPython,
    args = [pyFile, bytesToHex(initial), "INITIAL"],
    options = {poStdErrToStdOut}
  )
  var exitCode = p.waitForExit()
  var output = stdstreams.readAll(p.outputStream)
  p.close()
  doAssert exitCode == 0, "Python failed to parse protected Initial header: " & output
  doAssert "PYTHON_QUIC_HEADER_OK:INITIAL" in output

  let appSecret = @[1'u8, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
  conn.setLevelWriteSecret(qelApplication, appSecret)
  let oneRtt = conn.encodeProtectedPacket(qptShort, @[QuicFrame(kind: qfkPing)])
  p = startProcess(
    venvPython,
    args = [pyFile, bytesToHex(oneRtt), "ONE_RTT", "8"],
    options = {poStdErrToStdOut}
  )
  exitCode = p.waitForExit()
  output = stdstreams.readAll(p.outputStream)
  p.close()
  doAssert exitCode == 0, "Python failed to parse protected 1-RTT header: " & output
  doAssert "PYTHON_QUIC_HEADER_OK:ONE_RTT" in output
  echo "PASS: Nim protected QUIC headers -> Python aioquic parser"

echo "All Python QUIC interop tests passed"
