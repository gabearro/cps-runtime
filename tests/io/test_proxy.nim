## Tests for CPS I/O Proxy (SOCKS4/4a, SOCKS5, HTTP CONNECT, chaining)

import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/io/buffered
import cps/io/proxy
import std/[nativesockets, strutils]
from std/posix import Sockaddr_in, getsockname, SockLen

# ============================================================
# Helpers: get OS-assigned port from a listener
# ============================================================

proc getListenerPort(listener: TcpListener): int =
  var localAddr: Sockaddr_in
  var addrLen: SockLen = sizeof(localAddr).SockLen
  let rc = getsockname(listener.fd, cast[ptr SockAddr](addr localAddr), addr addrLen)
  assert rc == 0, "getsockname failed"
  result = ntohs(localAddr.sin_port).int

# ============================================================
# Mock echo server — accepts one connection, echoes data back
# ============================================================

proc echoServer(listener: TcpListener): CpsFuture[string] {.cps.} =
  let client = await listener.accept()
  let data = await client.AsyncStream.read(1024)
  await client.AsyncStream.write(data)
  client.AsyncStream.close()
  return data

# ============================================================
# Mock SOCKS4 proxy server
# ============================================================

proc relayOneDir(src: AsyncStream, dst: AsyncStream): CpsVoidFuture =
  ## Relay data in one direction (src → dst) until EOF or error.
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()

  proc pump() =
    let rf = src.read(4096)
    rf.addCallback(proc() =
      if rf.hasError() or rf.read().len == 0:
        fut.complete()
      else:
        let wf = dst.write(rf.read())
        wf.addCallback(proc() =
          if wf.hasError():
            fut.complete()
          else:
            pump()
        )
    )

  pump()
  result = fut

proc relayBidi(a: AsyncStream, b: AsyncStream, readerA: BufferedReader): CpsVoidFuture =
  ## Relay data bidirectionally between two streams.
  ## readerA may hold buffered data from the proxy handshake.
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()

  var doneCount = 0

  proc onDirDone() =
    doneCount += 1
    if doneCount >= 2:
      fut.complete()

  # Forward leftover buffered data, then start relay
  proc startRelay() =
    let leftover = if readerA != nil: readerA.drainBuffer() else: ""
    if leftover.len > 0:
      let wf = b.write(leftover)
      wf.addCallback(proc() =
        # Start both directions
        let f1 = relayOneDir(a, b)
        f1.addCallback(proc() = onDirDone())
        let f2 = relayOneDir(b, a)
        f2.addCallback(proc() = onDirDone())
      )
    else:
      let f1 = relayOneDir(a, b)
      f1.addCallback(proc() = onDirDone())
      let f2 = relayOneDir(b, a)
      f2.addCallback(proc() = onDirDone())

  startRelay()
  result = fut

proc socks4ProxyServer(listener: TcpListener): CpsVoidFuture {.cps.} =
  let client = await listener.accept()
  let reader = newBufferedReader(client.AsyncStream)

  # Read SOCKS4 request: VN(1) CD(1) PORT(2) IP(4) USERID+NUL(variable)
  let header = await reader.readExact(8)
  assert ord(header[0]) == 0x04, "Expected SOCKS4 version"
  assert ord(header[1]) == 0x01, "Expected CONNECT command"

  let dstPort = (ord(header[2]) shl 8) or ord(header[3])
  let ip0 = ord(header[4])
  let ip1 = ord(header[5])
  let ip2 = ord(header[6])
  let ip3 = ord(header[7])

  # Read user ID (until NUL)
  var userId = ""
  while true:
    let b = await reader.readExact(1)
    if ord(b[0]) == 0:
      break
    userId.add(b[0])

  # Check for SOCKS4a (IP 0.0.0.x, x != 0)
  var targetHost: string
  if ip0 == 0 and ip1 == 0 and ip2 == 0 and ip3 != 0:
    # SOCKS4a: read hostname until NUL
    targetHost = ""
    while true:
      let b = await reader.readExact(1)
      if ord(b[0]) == 0:
        break
      targetHost.add(b[0])
  else:
    targetHost = $ip0 & "." & $ip1 & "." & $ip2 & "." & $ip3

  # Connect to the actual target
  let targetConn = await tcpConnect(targetHost, dstPort)

  # Send success response
  var resp = newString(8)
  resp[0] = char(0x00)  # VN (reply version)
  resp[1] = char(0x5A)  # CD: request granted
  resp[2] = char(0x00)  # bound port (don't care)
  resp[3] = char(0x00)
  resp[4] = char(0x00)  # bound IP (don't care)
  resp[5] = char(0x00)
  resp[6] = char(0x00)
  resp[7] = char(0x00)
  await client.AsyncStream.write(resp)

  # Full bidirectional relay (supports chaining)
  await relayBidi(client.AsyncStream, targetConn.AsyncStream, reader)

# ============================================================
# Mock SOCKS5 proxy server (no-auth and user/pass auth)
# ============================================================

proc socks5ProxyServer(listener: TcpListener, requireAuth: bool = false,
                       expectedUser: string = "", expectedPass: string = ""): CpsVoidFuture {.cps.} =
  let client = await listener.accept()
  let reader = newBufferedReader(client.AsyncStream)

  # Phase 1: Method negotiation
  let verNmethods = await reader.readExact(2)
  assert ord(verNmethods[0]) == 0x05, "Expected SOCKS5 version"
  let nmethods = ord(verNmethods[1])
  let methods = await reader.readExact(nmethods)

  if requireAuth:
    # Reply with username/password method
    await client.AsyncStream.write("\x05\x02")

    # Phase 2: Username/password auth
    let authVer = await reader.readExact(1)
    assert ord(authVer[0]) == 0x01, "Expected auth version 1"
    let ulenBytes = await reader.readExact(1)
    let ulen = ord(ulenBytes[0])
    let username = await reader.readExact(ulen)
    let plenBytes = await reader.readExact(1)
    let plen = ord(plenBytes[0])
    let password = await reader.readExact(plen)

    if username == expectedUser and password == expectedPass:
      await client.AsyncStream.write("\x01\x00")  # success
    else:
      await client.AsyncStream.write("\x01\x01")  # failure
      client.AsyncStream.close()
      return
  else:
    # Reply with no-auth method
    await client.AsyncStream.write("\x05\x00")

  # Phase 3: CONNECT request
  let connHdr = await reader.readExact(4)
  assert ord(connHdr[0]) == 0x05, "Expected SOCKS5 version in CONNECT"
  assert ord(connHdr[1]) == 0x01, "Expected CONNECT command"

  let atyp = ord(connHdr[3])
  var targetHost: string
  var targetPort: int

  if atyp == 0x01:
    # IPv4
    let ipBytes = await reader.readExact(4)
    targetHost = $ord(ipBytes[0]) & "." & $ord(ipBytes[1]) & "." & $ord(ipBytes[2]) & "." & $ord(ipBytes[3])
  elif atyp == 0x03:
    # Domain
    let domLen = await reader.readExact(1)
    targetHost = await reader.readExact(ord(domLen[0]))
  elif atyp == 0x04:
    # IPv6 - just read and skip for tests
    discard await reader.readExact(16)
    targetHost = "::1"

  let portBytes = await reader.readExact(2)
  targetPort = (ord(portBytes[0]) shl 8) or ord(portBytes[1])

  # Connect to actual target
  let targetConn = await tcpConnect(targetHost, targetPort)

  # Send success reply: bound to 0.0.0.0:0
  var resp = "\x05\x00\x00\x01"  # ver, success, rsv, atyp=IPv4
  resp.add("\x00\x00\x00\x00")   # bound addr
  resp.add("\x00\x00")            # bound port
  await client.AsyncStream.write(resp)

  # Full bidirectional relay (supports chaining)
  await relayBidi(client.AsyncStream, targetConn.AsyncStream, reader)

# ============================================================
# Mock HTTP CONNECT proxy server
# ============================================================

proc httpProxyServer(listener: TcpListener,
                     requireAuth: bool = false,
                     expectedUser: string = "",
                     expectedPass: string = ""): CpsVoidFuture {.cps.} =
  let client = await listener.accept()
  let reader = newBufferedReader(client.AsyncStream)

  # Read request line
  let requestLine: string = await reader.readLine()
  # Parse: "CONNECT host:port HTTP/1.1"
  let reqParts: seq[string] = requestLine.split(' ')
  assert reqParts[0] == "CONNECT", "Expected CONNECT, got: " & reqParts[0]
  let connectTarget: string = reqParts[1]

  # Read headers until empty line
  var gotAuth: bool = false
  while true:
    let line: string = await reader.readLine()
    if line.len == 0:
      break
    if line.startsWith("Proxy-Authorization:"):
      gotAuth = true

  if requireAuth and not gotAuth:
    await client.AsyncStream.write("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n")
    client.AsyncStream.close()
    return

  # Parse host:port
  let colonIdx: int = connectTarget.rfind(':')
  let targetHost: string = connectTarget[0 ..< colonIdx]
  let targetPort: int = parseInt(connectTarget[colonIdx + 1 .. ^1])

  # Connect to actual target
  let targetConn = await tcpConnect(targetHost, targetPort)

  # Send 200 response
  await client.AsyncStream.write("HTTP/1.1 200 Connection Established\r\n\r\n")

  # Full bidirectional relay (supports chaining)
  await relayBidi(client.AsyncStream, targetConn.AsyncStream, reader)

# ============================================================
# Utility: run event loop until all futures complete
# ============================================================

proc runUntilComplete(futures: varargs[CpsVoidFuture]) =
  let loop = getEventLoop()
  var maxTicks = 5000
  while maxTicks > 0:
    var allDone = true
    for f in futures:
      if not f.finished:
        allDone = false
        break
    if allDone:
      break
    loop.tick()
    dec maxTicks
    if not loop.hasWork:
      break

proc runUntilComplete[T](f1: CpsFuture[T], f2: CpsVoidFuture): T =
  let loop = getEventLoop()
  var maxTicks = 5000
  while maxTicks > 0:
    if f1.finished and f2.finished:
      break
    loop.tick()
    dec maxTicks
    if not loop.hasWork:
      break
  result = f1.read()

# ============================================================
# Test 1: SOCKS4 proxy (IPv4 only)
# ============================================================

block testSocks4:
  let echoListener = tcpListen("127.0.0.1", 0)
  let echoPort = getListenerPort(echoListener)

  let proxyListener = tcpListen("127.0.0.1", 0)
  let proxyPort = getListenerPort(proxyListener)

  let echoFut = echoServer(echoListener)
  let proxyFut = socks4ProxyServer(proxyListener)

  proc clientTask(pp: int, ep: int): CpsFuture[string] {.cps.} =
    let proxy = socks4Proxy("127.0.0.1", pp)
    let ps = await proxyConnect(proxy, "127.0.0.1", ep)
    await ps.AsyncStream.write("socks4 test")
    let reply = await ps.AsyncStream.read(1024)
    ps.AsyncStream.close()
    return reply

  let clientFut = clientTask(proxyPort, echoPort)

  let loop = getEventLoop()
  var ticks = 5000
  while ticks > 0 and (not clientFut.finished or not echoFut.finished):
    loop.tick()
    dec ticks
    if not loop.hasWork:
      break

  assert clientFut.finished, "Client should have finished"
  assert clientFut.read() == "socks4 test", "Got: " & clientFut.read()
  assert echoFut.read() == "socks4 test"
  echoListener.close()
  proxyListener.close()
  echo "PASS: SOCKS4 proxy"

# ============================================================
# Test 2: SOCKS4a proxy (hostname support)
# ============================================================

block testSocks4a:
  let echoListener = tcpListen("127.0.0.1", 0)
  let echoPort = getListenerPort(echoListener)

  let proxyListener = tcpListen("127.0.0.1", 0)
  let proxyPort = getListenerPort(proxyListener)

  let echoFut = echoServer(echoListener)
  let proxyFut = socks4ProxyServer(proxyListener)

  proc clientTask(pp: int, ep: int): CpsFuture[string] {.cps.} =
    let proxy = socks4aProxy("127.0.0.1", pp)
    # Use hostname instead of IP — SOCKS4a resolves on the proxy
    let ps = await proxyConnect(proxy, "localhost", ep)
    await ps.AsyncStream.write("socks4a hostname")
    let reply = await ps.AsyncStream.read(1024)
    ps.AsyncStream.close()
    return reply

  let clientFut = clientTask(proxyPort, echoPort)

  let loop = getEventLoop()
  var ticks = 5000
  while ticks > 0 and (not clientFut.finished or not echoFut.finished):
    loop.tick()
    dec ticks
    if not loop.hasWork:
      break

  assert clientFut.finished, "Client should have finished"
  assert clientFut.read() == "socks4a hostname", "Got: " & clientFut.read()
  echoListener.close()
  proxyListener.close()
  echo "PASS: SOCKS4a proxy (hostname)"

# ============================================================
# Test 3: SOCKS5 proxy (no auth)
# ============================================================

block testSocks5NoAuth:
  let echoListener = tcpListen("127.0.0.1", 0)
  let echoPort = getListenerPort(echoListener)

  let proxyListener = tcpListen("127.0.0.1", 0)
  let proxyPort = getListenerPort(proxyListener)

  let echoFut = echoServer(echoListener)
  let proxyFut = socks5ProxyServer(proxyListener)

  proc clientTask(pp: int, ep: int): CpsFuture[string] {.cps.} =
    let proxy = socks5Proxy("127.0.0.1", pp)
    let ps = await proxyConnect(proxy, "127.0.0.1", ep)
    await ps.AsyncStream.write("socks5 noauth")
    let reply = await ps.AsyncStream.read(1024)
    ps.AsyncStream.close()
    return reply

  let clientFut = clientTask(proxyPort, echoPort)

  let loop = getEventLoop()
  var ticks = 5000
  while ticks > 0 and (not clientFut.finished or not echoFut.finished):
    loop.tick()
    dec ticks
    if not loop.hasWork:
      break

  assert clientFut.finished, "Client should have finished"
  assert clientFut.read() == "socks5 noauth", "Got: " & clientFut.read()
  echoListener.close()
  proxyListener.close()
  echo "PASS: SOCKS5 proxy (no auth)"

# ============================================================
# Test 4: SOCKS5 proxy (username/password auth)
# ============================================================

block testSocks5Auth:
  let echoListener = tcpListen("127.0.0.1", 0)
  let echoPort = getListenerPort(echoListener)

  let proxyListener = tcpListen("127.0.0.1", 0)
  let proxyPort = getListenerPort(proxyListener)

  let echoFut = echoServer(echoListener)
  let proxyFut = socks5ProxyServer(proxyListener, requireAuth = true,
                                    expectedUser = "user1",
                                    expectedPass = "pass1")

  proc clientTask(pp: int, ep: int): CpsFuture[string] {.cps.} =
    let proxy = socks5Proxy("127.0.0.1", pp, "user1", "pass1")
    let ps = await proxyConnect(proxy, "127.0.0.1", ep)
    await ps.AsyncStream.write("socks5 auth")
    let reply = await ps.AsyncStream.read(1024)
    ps.AsyncStream.close()
    return reply

  let clientFut = clientTask(proxyPort, echoPort)

  let loop = getEventLoop()
  var ticks = 5000
  while ticks > 0 and (not clientFut.finished or not echoFut.finished):
    loop.tick()
    dec ticks
    if not loop.hasWork:
      break

  assert clientFut.finished, "Client should have finished"
  assert clientFut.read() == "socks5 auth", "Got: " & clientFut.read()
  echoListener.close()
  proxyListener.close()
  echo "PASS: SOCKS5 proxy (auth)"

# ============================================================
# Test 5: SOCKS5 proxy with domain name
# ============================================================

block testSocks5Domain:
  let echoListener = tcpListen("127.0.0.1", 0)
  let echoPort = getListenerPort(echoListener)

  let proxyListener = tcpListen("127.0.0.1", 0)
  let proxyPort = getListenerPort(proxyListener)

  let echoFut = echoServer(echoListener)
  let proxyFut = socks5ProxyServer(proxyListener)

  proc clientTask(pp: int, ep: int): CpsFuture[string] {.cps.} =
    let proxy = socks5Proxy("127.0.0.1", pp)
    let ps = await proxyConnect(proxy, "localhost", ep)
    await ps.AsyncStream.write("socks5 domain")
    let reply = await ps.AsyncStream.read(1024)
    ps.AsyncStream.close()
    return reply

  let clientFut = clientTask(proxyPort, echoPort)

  let loop = getEventLoop()
  var ticks = 5000
  while ticks > 0 and (not clientFut.finished or not echoFut.finished):
    loop.tick()
    dec ticks
    if not loop.hasWork:
      break

  assert clientFut.finished, "Client should have finished"
  assert clientFut.read() == "socks5 domain", "Got: " & clientFut.read()
  echoListener.close()
  proxyListener.close()
  echo "PASS: SOCKS5 proxy (domain)"

# ============================================================
# Test 6: HTTP CONNECT proxy
# ============================================================

block testHttpConnect:
  let echoListener = tcpListen("127.0.0.1", 0)
  let echoPort = getListenerPort(echoListener)

  let proxyListener = tcpListen("127.0.0.1", 0)
  let proxyPort = getListenerPort(proxyListener)

  let echoFut = echoServer(echoListener)
  let proxyFut = httpProxyServer(proxyListener)

  proc clientTask(pp: int, ep: int): CpsFuture[string] {.cps.} =
    let proxy = httpProxy("127.0.0.1", pp)
    let ps = await proxyConnect(proxy, "127.0.0.1", ep)
    await ps.AsyncStream.write("http connect")
    let reply = await ps.AsyncStream.read(1024)
    ps.AsyncStream.close()
    return reply

  let clientFut = clientTask(proxyPort, echoPort)

  let loop = getEventLoop()
  var ticks = 5000
  while ticks > 0 and (not clientFut.finished or not echoFut.finished):
    loop.tick()
    dec ticks
    if not loop.hasWork:
      break

  assert clientFut.finished, "Client should have finished"
  assert clientFut.read() == "http connect", "Got: " & clientFut.read()
  echoListener.close()
  proxyListener.close()
  echo "PASS: HTTP CONNECT proxy"

# ============================================================
# Test 7: HTTP CONNECT proxy with Basic auth
# ============================================================

block testHttpConnectAuth:
  let echoListener = tcpListen("127.0.0.1", 0)
  let echoPort = getListenerPort(echoListener)

  let proxyListener = tcpListen("127.0.0.1", 0)
  let proxyPort = getListenerPort(proxyListener)

  let echoFut = echoServer(echoListener)
  let proxyFut = httpProxyServer(proxyListener, requireAuth = true,
                                  expectedUser = "admin",
                                  expectedPass = "secret")

  proc clientTask(pp: int, ep: int): CpsFuture[string] {.cps.} =
    let proxy = httpProxy("127.0.0.1", pp, "admin", "secret")
    let ps = await proxyConnect(proxy, "127.0.0.1", ep)
    await ps.AsyncStream.write("http auth test")
    let reply = await ps.AsyncStream.read(1024)
    ps.AsyncStream.close()
    return reply

  let clientFut = clientTask(proxyPort, echoPort)

  let loop = getEventLoop()
  var ticks = 5000
  while ticks > 0 and (not clientFut.finished or not echoFut.finished):
    loop.tick()
    dec ticks
    if not loop.hasWork:
      break

  assert clientFut.finished, "Client should have finished"
  assert clientFut.read() == "http auth test", "Got: " & clientFut.read()
  echoListener.close()
  proxyListener.close()
  echo "PASS: HTTP CONNECT proxy (auth)"

# ============================================================
# Test 8: Proxy chain (SOCKS5 → HTTP CONNECT → target)
# ============================================================

block testProxyChain:
  let echoListener = tcpListen("127.0.0.1", 0)
  let echoPort = getListenerPort(echoListener)

  # Two proxy servers
  let socks5Listener = tcpListen("127.0.0.1", 0)
  let socks5Port = getListenerPort(socks5Listener)

  let httpListener = tcpListen("127.0.0.1", 0)
  let httpPort = getListenerPort(httpListener)

  let echoFut = echoServer(echoListener)
  let socks5Fut = socks5ProxyServer(socks5Listener)
  let httpFut = httpProxyServer(httpListener)

  proc clientTask(s5port: int, hport: int, ep: int): CpsFuture[string] {.cps.} =
    let chain = @[
      socks5Proxy("127.0.0.1", s5port),
      httpProxy("127.0.0.1", hport)
    ]
    let ps = await proxyChainConnect(chain, "127.0.0.1", ep)
    await ps.AsyncStream.write("chain test")
    let reply = await ps.AsyncStream.read(1024)
    ps.AsyncStream.close()
    return reply

  let clientFut = clientTask(socks5Port, httpPort, echoPort)

  let loop = getEventLoop()
  var ticks = 5000
  while ticks > 0 and (not clientFut.finished or not echoFut.finished):
    loop.tick()
    dec ticks
    if not loop.hasWork:
      break

  assert clientFut.finished, "Client should have finished"
  assert clientFut.read() == "chain test", "Got: " & clientFut.read()
  echoListener.close()
  socks5Listener.close()
  httpListener.close()
  echo "PASS: Proxy chain (SOCKS5 -> HTTP CONNECT)"

# ============================================================
# Test 9: SOCKS5 auth failure
# ============================================================

block testSocks5AuthFail:
  let proxyListener = tcpListen("127.0.0.1", 0)
  let proxyPort = getListenerPort(proxyListener)

  let proxyFut = socks5ProxyServer(proxyListener, requireAuth = true,
                                    expectedUser = "correct",
                                    expectedPass = "password")

  proc clientTask(pp: int): CpsVoidFuture {.cps.} =
    let proxy = socks5Proxy("127.0.0.1", pp, "wrong", "credentials")
    try:
      let ps = await proxyConnect(proxy, "127.0.0.1", 80)
      assert false, "Should have failed"
    except ProxyError:
      discard  # Expected

  let clientFut = clientTask(proxyPort)

  let loop = getEventLoop()
  var ticks = 5000
  while ticks > 0 and not clientFut.finished:
    loop.tick()
    dec ticks
    if not loop.hasWork:
      break

  assert clientFut.finished, "Client should have finished"
  proxyListener.close()
  echo "PASS: SOCKS5 auth failure"

# ============================================================
# Test 10: getUnderlyingFd / getUnderlyingTcpStream
# ============================================================

block testUnderlyingFd:
  let echoListener = tcpListen("127.0.0.1", 0)
  let echoPort = getListenerPort(echoListener)

  let proxyListener = tcpListen("127.0.0.1", 0)
  let proxyPort = getListenerPort(proxyListener)

  let echoFut = echoServer(echoListener)
  let proxyFut = socks5ProxyServer(proxyListener)

  proc clientTask(pp: int, ep: int): CpsFuture[bool] {.cps.} =
    let proxy = socks5Proxy("127.0.0.1", pp)
    let ps = await proxyConnect(proxy, "127.0.0.1", ep)

    # Should be able to get the underlying fd (for TLS wrapping etc.)
    let fd = ps.getUnderlyingFd()
    let tcp = ps.getUnderlyingTcpStream()
    let valid = fd != osInvalidSocket and tcp != nil

    await ps.AsyncStream.write("fd test")
    let reply = await ps.AsyncStream.read(1024)
    ps.AsyncStream.close()
    return valid

  let clientFut = clientTask(proxyPort, echoPort)

  let loop = getEventLoop()
  var ticks = 5000
  while ticks > 0 and (not clientFut.finished or not echoFut.finished):
    loop.tick()
    dec ticks
    if not loop.hasWork:
      break

  assert clientFut.finished, "Client should have finished"
  assert clientFut.read() == true, "Should have valid fd"
  echoListener.close()
  proxyListener.close()
  echo "PASS: getUnderlyingFd/getUnderlyingTcpStream"

# ============================================================
# Test 11: ProxyConfig constructors
# ============================================================

block testProxyConfigConstructors:
  let s4 = socks4Proxy("proxy.example.com", 1080, "user")
  assert s4.kind == pkSocks4
  assert s4.host == "proxy.example.com"
  assert s4.port == 1080
  assert s4.auth.username == "user"

  let s4a = socks4aProxy("proxy.example.com", 1080)
  assert s4a.kind == pkSocks4a

  let s5 = socks5Proxy("proxy.example.com", 1080, "admin", "pass")
  assert s5.kind == pkSocks5
  assert s5.auth.username == "admin"
  assert s5.auth.password == "pass"

  let http = httpProxy("proxy.example.com", 8080)
  assert http.kind == pkHttpConnect
  assert http.port == 8080
  assert http.auth.username == ""

  echo "PASS: ProxyConfig constructors"

echo "All proxy tests passed!"
