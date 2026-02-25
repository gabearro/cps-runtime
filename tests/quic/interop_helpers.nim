## Shared helpers for QUIC / HTTP3 Python interop tests.

import std/[os, osproc, streams as stdstreams, strutils, times, nativesockets]
from std/posix import Sockaddr_in, SockLen, getsockname
import cps/io/udp

proc bytesToString*(data: openArray[byte]): string =
  result = newString(data.len)
  for i in 0 ..< data.len:
    result[i] = char(data[i])

proc stringToBytes*(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len:
    result[i] = byte(ord(s[i]) and 0xFF)

proc getUdpBoundPort*(sock: UdpSocket): int =
  var localAddr: Sockaddr_in
  var addrLen: SockLen = sizeof(localAddr).SockLen
  let rc = getsockname(sock.fd, cast[ptr SockAddr](addr localAddr), addr addrLen)
  doAssert rc == 0, "getsockname failed for UDP socket"
  result = ntohs(localAddr.sin_port).int

proc runChecked*(exe: string, args: openArray[string]) =
  let p = startProcess(exe, args = @args, options = {poStdErrToStdOut, poUsePath})
  let output = stdstreams.readAll(p.outputStream)
  let exitCode = p.waitForExit()
  p.close()
  doAssert exitCode == 0,
    "Command failed (" & exe & " " & args.join(" ") & "), exit=" &
    $exitCode & "\nOutput:\n" & output

proc waitForLine*(p: Process, pattern: string, timeoutMs: int = 15000): string =
  let startTime = epochTime()
  var accumulated = ""
  while true:
    if epochTime() - startTime > timeoutMs.float / 1000.0:
      raise newException(system.IOError, "Timeout waiting for '" & pattern &
        "'. Output so far:\n" & accumulated)
    try:
      let line = stdstreams.readLine(p.outputStream)
      accumulated &= line & "\n"
      if pattern in line:
        return line
    except system.IOError:
      let code = p.waitForExit()
      raise newException(system.IOError, "Process exited before '" & pattern &
        "', exit=" & $code & ". Output:\n" & accumulated)

proc waitForFileLine*(path: string, timeoutMs: int = 15000): string =
  ## Poll a file until it contains at least one non-empty line.
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    if fileExists(path):
      try:
        let content = readFile(path)
        for rawLine in content.splitLines():
          let line = rawLine.strip()
          if line.len > 0:
            return line
      except CatchableError:
        discard
    sleep(10)
  raise newException(system.IOError, "Timeout waiting for file line: " & path)

proc resolveVenvPython(venvDir: string): string =
  let py3 = venvDir / "bin" / "python3"
  let py = venvDir / "bin" / "python"
  if fileExists(py3):
    return py3
  if fileExists(py):
    return py
  raise newException(IOError, "No python executable in venv: " & venvDir)

proc ensureAioquicVenv*(): string =
  ## Create and provision a dedicated venv for QUIC/HTTP3 interop tests.
  let venvDir = getTempDir() / "cps_quic_http3_venv"
  let marker = venvDir / ".aioquic_ready"

  if not dirExists(venvDir):
    runChecked("python3", ["-m", "venv", venvDir])

  let venvPython = resolveVenvPython(venvDir)
  if not fileExists(marker):
    runChecked(venvPython, ["-m", "pip", "install", "--upgrade", "pip"])
    runChecked(venvPython, ["-m", "pip", "install", "aioquic"])
    writeFile(marker, "ok\n")

  result = venvPython

proc generateTestCert*(): (string, string) =
  ## Generate a short-lived self-signed cert for QUIC interop tests.
  ## Include SAN entries so browser QUIC handshakes accept localhost targets.
  let nonce = $int64(epochTime() * 1_000_000.0)
  let certFile = getTempDir() / ("test_quic_interop_cert_" & nonce & ".pem")
  let keyFile = getTempDir() / ("test_quic_interop_key_" & nonce & ".pem")
  let cmd = "openssl req -x509 -newkey rsa:2048 -keyout " & keyFile &
            " -out " & certFile &
            " -days 1 -nodes -subj '/CN=localhost' " &
            "-addext 'subjectAltName = DNS:localhost,IP:127.0.0.1' 2>/dev/null"
  let exitCode = execCmd(cmd)
  doAssert exitCode == 0, "Failed to generate test certificate"
  result = (certFile, keyFile)

proc pythonFixturePath*(name: string): string =
  ## Return absolute path to a Python interop fixture script in tests/quic/python.
  let baseDir = parentDir(currentSourcePath())
  let p = baseDir / "python" / name
  doAssert fileExists(p), "Missing Python interop fixture: " & p
  p
