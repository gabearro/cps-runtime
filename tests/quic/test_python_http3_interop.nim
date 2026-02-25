## Python HTTP/3 codec interop tests.
##
## Validates Nim HTTP/3 frame + SETTINGS codec against Python `aioquic`
## running from an isolated virtual environment.

import std/[osproc, streams as stdstreams, strutils]
import cps/http/shared/http3
import cps/http/shared/http3_connection
import cps/quic/varint
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

block testNimSettingsFrameDecodedByPython:
  let venvPython = ensureAioquicVenv()
  let settings = @[
    (H3SettingQpackMaxTableCapacity, 0'u64),
    (H3SettingMaxFieldSectionSize, 65536'u64),
    (H3SettingEnableConnectProtocol, 1'u64),
    (H3SettingH3Datagram, 1'u64)
  ]
  let payload = encodeSettingsPayload(settings)
  let frame = encodeHttp3Frame(H3FrameSettings, payload)
  let frameHex = bytesToHex(frame)
  let pyFile = pythonFixturePath("http3_parse_nim_settings.py")

  let p = startProcess(
    venvPython,
    args = [pyFile, frameHex],
    options = {poStdErrToStdOut}
  )
  let exitCode = p.waitForExit()
  let output = stdstreams.readAll(p.outputStream)
  p.close()
  doAssert exitCode == 0, "Python failed to parse Nim SETTINGS frame: " & output
  doAssert "PYTHON_H3_PARSE_OK" in output, "Missing success marker from Python: " & output
  echo "PASS: Nim HTTP/3 SETTINGS frame -> Python aioquic parser"

block testPythonSettingsFrameDecodedByNim:
  let venvPython = ensureAioquicVenv()
  let pyFile = pythonFixturePath("http3_emit_settings.py")

  let p = startProcess(
    venvPython,
    args = [pyFile],
    options = {poStdErrToStdOut}
  )
  let exitCode = p.waitForExit()
  let output = stdstreams.readAll(p.outputStream)
  p.close()
  doAssert exitCode == 0, "Python failed to emit HTTP/3 frame: " & output

  var line = ""
  for l in output.splitLines():
    if l.startsWith("FRAMEHEX:"):
      line = l
      break
  doAssert line.len > 0, "Python output missing FRAMEHEX line: " & output

  let frameBytes = hexToBytes(line.split("FRAMEHEX:")[1].strip())
  var off = 0
  let frame = decodeHttp3Frame(frameBytes, off)
  doAssert off == frameBytes.len
  doAssert frame.frameType == H3FrameSettings

  let settings = decodeSettingsPayload(frame.payload)
  var hasMaxField = false
  var hasBlockedStreams = false
  var hasDatagram = false
  for (k, v) in settings:
    if k == H3SettingMaxFieldSectionSize and v == 131072'u64:
      hasMaxField = true
    if k == H3SettingQpackBlockedStreams and v == 16'u64:
      hasBlockedStreams = true
    if k == H3SettingH3Datagram and v == 1'u64:
      hasDatagram = true

  doAssert hasMaxField, "Nim failed to decode max-field-section-size from Python frame"
  doAssert hasBlockedStreams, "Nim failed to decode qpack-blocked-streams from Python frame"
  doAssert hasDatagram, "Nim failed to decode H3_DATAGRAM setting from Python frame"
  echo "PASS: Python aioquic SETTINGS frame -> Nim HTTP/3 parser"

block testNimGoawayFrameDecodedByPython:
  let venvPython = ensureAioquicVenv()
  let frame = encodeGoawayFrame(21'u64)
  let pyFile = pythonFixturePath("http3_parse_nim_goaway.py")
  let p = startProcess(
    venvPython,
    args = [pyFile, bytesToHex(frame), "21"],
    options = {poStdErrToStdOut}
  )
  let exitCode = p.waitForExit()
  let output = stdstreams.readAll(p.outputStream)
  p.close()
  doAssert exitCode == 0, "Python failed to parse Nim GOAWAY frame: " & output
  doAssert "PYTHON_H3_GOAWAY_PARSE_OK" in output
  echo "PASS: Nim HTTP/3 GOAWAY frame -> Python parser"

block testPythonGoawayFrameDecodedByNim:
  let venvPython = ensureAioquicVenv()
  let pyFile = pythonFixturePath("http3_emit_goaway.py")

  let p = startProcess(
    venvPython,
    args = [pyFile, "55"],
    options = {poStdErrToStdOut}
  )
  let exitCode = p.waitForExit()
  let output = stdstreams.readAll(p.outputStream)
  p.close()
  doAssert exitCode == 0, "Python failed to emit GOAWAY frame: " & output

  var line = ""
  for l in output.splitLines():
    if l.startsWith("FRAMEHEX:"):
      line = l
      break
  doAssert line.len > 0, "Python output missing FRAMEHEX line: " & output

  let frameBytes = hexToBytes(line.split("FRAMEHEX:")[1].strip())
  var off = 0
  let frame = decodeHttp3Frame(frameBytes, off)
  doAssert frame.frameType == H3FrameGoaway
  var goOff = 0
  let goId = decodeQuicVarInt(frame.payload, goOff)
  doAssert goId == 55'u64
  echo "PASS: Python HTTP/3 GOAWAY frame -> Nim parser"

echo "All Python HTTP/3 interop tests passed"
