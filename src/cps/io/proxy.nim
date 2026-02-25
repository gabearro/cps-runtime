## CPS I/O Proxy
##
## Provides proxy protocol support (SOCKS4/4a, SOCKS5, HTTP CONNECT) as
## AsyncStream-compatible wrappers. Proxy connections are transparent —
## after handshake, reads/writes pass through directly to the underlying
## stream. Supports proxy chaining (connecting through multiple proxies
## in sequence).

import std/[nativesockets, net, strutils, posix]
import ../runtime
import ../eventloop
import ./streams
import ./tcp
import ./buffered

# ============================================================
# Types
# ============================================================

type
  ProxyKind* = enum
    pkSocks4       ## SOCKS4 (IP-only)
    pkSocks4a      ## SOCKS4a (hostname support via domain name extension)
    pkSocks5       ## SOCKS5 (full: IPv4, IPv6, domain, auth)
    pkHttpConnect  ## HTTP CONNECT tunnel

  ProxyAuth* = object
    username*: string
    password*: string

  ProxyConfig* = object
    kind*: ProxyKind
    host*: string         ## Proxy server hostname/IP
    port*: int            ## Proxy server port
    auth*: ProxyAuth      ## Auth credentials (SOCKS5 user/pass, HTTP basic)

  ProxyError* = object of AsyncIoError
    ## Raised when proxy negotiation fails.

# ============================================================
# ProxyConfig constructors
# ============================================================

proc socks4Proxy*(host: string, port: int, userId: string = ""): ProxyConfig =
  ## Create a SOCKS4 proxy config.
  ProxyConfig(kind: pkSocks4, host: host, port: port,
              auth: ProxyAuth(username: userId))

proc socks4aProxy*(host: string, port: int, userId: string = ""): ProxyConfig =
  ## Create a SOCKS4a proxy config (supports hostnames).
  ProxyConfig(kind: pkSocks4a, host: host, port: port,
              auth: ProxyAuth(username: userId))

proc socks5Proxy*(host: string, port: int,
                  username: string = "", password: string = ""): ProxyConfig =
  ## Create a SOCKS5 proxy config with optional username/password auth.
  ProxyConfig(kind: pkSocks5, host: host, port: port,
              auth: ProxyAuth(username: username, password: password))

proc httpProxy*(host: string, port: int,
                username: string = "", password: string = ""): ProxyConfig =
  ## Create an HTTP CONNECT proxy config with optional basic auth.
  ProxyConfig(kind: pkHttpConnect, host: host, port: port,
              auth: ProxyAuth(username: username, password: password))

# ============================================================
# SOCKS4/4a handshake
# ============================================================

proc socks4Handshake(stream: AsyncStream, reader: BufferedReader,
                     targetHost: string, targetPort: int,
                     userId: string, useSocks4a: bool): CpsVoidFuture =
  ## Perform SOCKS4/4a handshake over `stream`.
  ## SOCKS4 requires `targetHost` to be an IPv4 address.
  ## SOCKS4a allows domain names (resolved by the proxy).
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()

  # Build CONNECT request
  # +----+----+----+----+----+----+----+----+----+----+...+----+
  # | VN | CD | DSTPORT  | DSTIP (4 bytes)  | USERID  | NULL |
  # +----+----+----+----+----+----+----+----+----+----+...+----+
  # VN = 0x04, CD = 0x01 (CONNECT)
  var req = ""
  req.add(char(0x04))  # version
  req.add(char(0x01))  # command: CONNECT

  # Port (big-endian)
  req.add(char((targetPort shr 8) and 0xFF))
  req.add(char(targetPort and 0xFF))

  if useSocks4a and not targetHost.contains('.') or
     (useSocks4a and not targetHost.allCharsInSet({'0'..'9', '.'})):
    # SOCKS4a: set IP to 0.0.0.x (x != 0) and append hostname after userid
    req.add(char(0x00))
    req.add(char(0x00))
    req.add(char(0x00))
    req.add(char(0x01))  # 0.0.0.1 signals SOCKS4a
  else:
    # SOCKS4: resolve IP and embed directly
    var ipBytes: array[4, uint8]
    let parts = targetHost.split('.')
    if parts.len != 4:
      fut.fail(newException(ProxyError, "SOCKS4 requires IPv4 address, got: " & targetHost))
      return fut
    for i in 0 ..< 4:
      try:
        let v = parseInt(parts[i])
        if v < 0 or v > 255:
          fut.fail(newException(ProxyError, "Invalid IPv4 octet: " & parts[i]))
          return fut
        ipBytes[i] = uint8(v)
      except ValueError:
        fut.fail(newException(ProxyError, "SOCKS4 requires IPv4 address, got: " & targetHost))
        return fut
    for b in ipBytes:
      req.add(char(b))

  # UserID + NUL
  req.add(userId)
  req.add(char(0x00))

  # SOCKS4a: append hostname + NUL
  if useSocks4a and not targetHost.allCharsInSet({'0'..'9', '.'}):
    req.add(targetHost)
    req.add(char(0x00))

  # Send request, then read 8-byte response
  let writeFut = stream.write(req)
  writeFut.addCallback(proc() =
    if writeFut.hasError():
      fut.fail(writeFut.getError())
      return

    let readFut = reader.readExact(8)
    readFut.addCallback(proc() =
      if readFut.hasError():
        fut.fail(readFut.getError())
        return

      let resp = readFut.read()
      # Response: VN(0x00) CD DSTPORT DSTIP
      let cd = ord(resp[1])
      if cd == 0x5A:
        # Request granted
        fut.complete()
      else:
        let msg = case cd
          of 0x5B: "request rejected or failed"
          of 0x5C: "request failed because client is not running identd"
          of 0x5D: "request failed because identd could not confirm user"
          else: "unknown SOCKS4 error code: " & $cd
        fut.fail(newException(ProxyError, "SOCKS4 proxy rejected: " & msg))
    )
  )
  result = fut

# ============================================================
# SOCKS5 handshake
# ============================================================

proc socks5Handshake(stream: AsyncStream, reader: BufferedReader,
                     targetHost: string, targetPort: int,
                     auth: ProxyAuth): CpsVoidFuture =
  ## Perform SOCKS5 handshake over `stream`.
  ## Supports no-auth (0x00) and username/password auth (0x02).
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()

  let hasAuth = auth.username.len > 0

  # Phase 1: Method negotiation
  # +----+----------+----------+
  # | VER| NMETHODS | METHODS  |
  # +----+----------+----------+
  var greeting = ""
  greeting.add(char(0x05))  # SOCKS version
  if hasAuth:
    greeting.add(char(0x02))  # 2 methods
    greeting.add(char(0x00))  # NO AUTH
    greeting.add(char(0x02))  # USERNAME/PASSWORD
  else:
    greeting.add(char(0x01))  # 1 method
    greeting.add(char(0x00))  # NO AUTH

  let greetFut = stream.write(greeting)
  greetFut.addCallback(proc() =
    if greetFut.hasError():
      fut.fail(greetFut.getError())
      return

    # Read server method selection (2 bytes)
    let methodFut = reader.readExact(2)
    methodFut.addCallback(proc() =
      if methodFut.hasError():
        fut.fail(methodFut.getError())
        return

      let methodResp = methodFut.read()
      if ord(methodResp[0]) != 0x05:
        fut.fail(newException(ProxyError, "SOCKS5 server returned invalid version: " & $ord(methodResp[0])))
        return

      let selectedMethod = ord(methodResp[1])

      proc doConnect() =
        # Phase 3: CONNECT request
        # +----+-----+-------+------+----------+----------+
        # | VER| CMD | RSV   | ATYP | DST.ADDR | DST.PORT |
        # +----+-----+-------+------+----------+----------+
        var connectReq = ""
        connectReq.add(char(0x05))  # version
        connectReq.add(char(0x01))  # CONNECT
        connectReq.add(char(0x00))  # reserved

        # Determine address type
        if targetHost.contains(':'):
          # IPv6
          connectReq.add(char(0x04))  # ATYP: IPv6
          var addr6: array[16, uint8]
          if inet_pton(AF_INET6.cint, targetHost.cstring, cast[pointer](addr addr6[0])) != 1:
            fut.fail(newException(ProxyError, "Invalid IPv6 address: " & targetHost))
            return
          for i in 0 ..< 16:
            connectReq.add(char(addr6[i]))
        elif targetHost.allCharsInSet({'0'..'9', '.'}):
          # IPv4
          connectReq.add(char(0x01))  # ATYP: IPv4
          var addr4: InAddr
          if inet_pton(AF_INET.cint, targetHost.cstring, addr addr4) != 1:
            fut.fail(newException(ProxyError, "Invalid IPv4 address: " & targetHost))
            return
          let ipBytes = cast[array[4, uint8]](addr4)
          for b in ipBytes:
            connectReq.add(char(b))
        else:
          # Domain name
          if targetHost.len > 255:
            fut.fail(newException(ProxyError, "Domain name too long for SOCKS5: " & $targetHost.len))
            return
          connectReq.add(char(0x03))  # ATYP: domain
          connectReq.add(char(targetHost.len.uint8))
          connectReq.add(targetHost)

        # Port (big-endian)
        connectReq.add(char((targetPort shr 8) and 0xFF))
        connectReq.add(char(targetPort and 0xFF))

        let connFut = stream.write(connectReq)
        connFut.addCallback(proc() =
          if connFut.hasError():
            fut.fail(connFut.getError())
            return

          # Read connect response: VER(1) REP(1) RSV(1) ATYP(1) + variable ADDR + PORT(2)
          # First read 4 bytes to get ATYP, then read remaining
          let hdrFut = reader.readExact(4)
          hdrFut.addCallback(proc() =
            if hdrFut.hasError():
              fut.fail(hdrFut.getError())
              return

            let hdr = hdrFut.read()
            let rep = ord(hdr[1])
            if rep != 0x00:
              let msg = case rep
                of 0x01: "general SOCKS server failure"
                of 0x02: "connection not allowed by ruleset"
                of 0x03: "network unreachable"
                of 0x04: "host unreachable"
                of 0x05: "connection refused"
                of 0x06: "TTL expired"
                of 0x07: "command not supported"
                of 0x08: "address type not supported"
                else: "unknown SOCKS5 error: " & $rep
              fut.fail(newException(ProxyError, "SOCKS5 proxy error: " & msg))
              return

            # Read remaining bind address bytes based on ATYP
            let atyp = ord(hdr[3])
            let addrLen = case atyp
              of 0x01: 4    # IPv4
              of 0x03: -1   # Domain: need to read length byte first
              of 0x04: 16   # IPv6
              else:
                fut.fail(newException(ProxyError, "SOCKS5: unknown ATYP: " & $atyp))
                return

            if atyp == 0x03:
              # Domain: read 1 byte length, then that many bytes + 2 port bytes
              let lenFut = reader.readExact(1)
              lenFut.addCallback(proc() =
                if lenFut.hasError():
                  fut.fail(lenFut.getError())
                  return
                let domLen = ord(lenFut.read()[0])
                let restFut = reader.readExact(domLen + 2)
                restFut.addCallback(proc() =
                  if restFut.hasError():
                    fut.fail(restFut.getError())
                  else:
                    fut.complete()
                )
              )
            else:
              # IPv4 (4 bytes) or IPv6 (16 bytes) + 2 port bytes
              let restFut = reader.readExact(addrLen + 2)
              restFut.addCallback(proc() =
                if restFut.hasError():
                  fut.fail(restFut.getError())
                else:
                  fut.complete()
              )
          )
        )

      if selectedMethod == 0xFF:
        fut.fail(newException(ProxyError, "SOCKS5 proxy: no acceptable auth method"))
        return

      if selectedMethod == 0x02:
        # Phase 2: Username/password authentication (RFC 1929)
        # +----+------+----------+------+----------+
        # | VER| ULEN | UNAME    | PLEN | PASSWD   |
        # +----+------+----------+------+----------+
        if not hasAuth:
          fut.fail(newException(ProxyError, "SOCKS5 proxy requires auth but no credentials provided"))
          return
        if auth.username.len > 255 or auth.password.len > 255:
          fut.fail(newException(ProxyError, "SOCKS5 auth credentials too long (max 255 each)"))
          return

        var authReq = ""
        authReq.add(char(0x01))  # auth version
        authReq.add(char(auth.username.len.uint8))
        authReq.add(auth.username)
        authReq.add(char(auth.password.len.uint8))
        authReq.add(auth.password)

        let authFut = stream.write(authReq)
        authFut.addCallback(proc() =
          if authFut.hasError():
            fut.fail(authFut.getError())
            return

          let authRespFut = reader.readExact(2)
          authRespFut.addCallback(proc() =
            if authRespFut.hasError():
              fut.fail(authRespFut.getError())
              return

            let authResp = authRespFut.read()
            if ord(authResp[1]) != 0x00:
              fut.fail(newException(ProxyError, "SOCKS5 authentication failed"))
              return

            doConnect()
          )
        )
      elif selectedMethod == 0x00:
        # No auth needed
        doConnect()
      else:
        fut.fail(newException(ProxyError, "SOCKS5: unsupported auth method: " & $selectedMethod))
    )
  )
  result = fut

# ============================================================
# HTTP CONNECT handshake
# ============================================================

proc httpConnectHandshake(stream: AsyncStream, reader: BufferedReader,
                         targetHost: string, targetPort: int,
                         auth: ProxyAuth): CpsVoidFuture =
  ## Perform HTTP CONNECT tunnel negotiation.
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()

  # Build CONNECT request
  var req = "CONNECT " & targetHost & ":" & $targetPort & " HTTP/1.1\r\n"
  req.add("Host: " & targetHost & ":" & $targetPort & "\r\n")

  # Basic auth if provided
  if auth.username.len > 0:
    # Base64 encode username:password
    # Simple base64 implementation to avoid importing std/base64
    const b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    let plain = auth.username & ":" & auth.password
    var encoded = ""
    var i = 0
    while i < plain.len:
      let b0 = ord(plain[i])
      let b1 = if i + 1 < plain.len: ord(plain[i + 1]) else: 0
      let b2 = if i + 2 < plain.len: ord(plain[i + 2]) else: 0
      let remaining = plain.len - i
      encoded.add(b64chars[(b0 shr 2) and 0x3F])
      encoded.add(b64chars[((b0 shl 4) or (b1 shr 4)) and 0x3F])
      if remaining > 1:
        encoded.add(b64chars[((b1 shl 2) or (b2 shr 6)) and 0x3F])
      else:
        encoded.add('=')
      if remaining > 2:
        encoded.add(b64chars[b2 and 0x3F])
      else:
        encoded.add('=')
      i += 3
    req.add("Proxy-Authorization: Basic " & encoded & "\r\n")

  req.add("\r\n")

  let writeFut = stream.write(req)
  writeFut.addCallback(proc() =
    if writeFut.hasError():
      fut.fail(writeFut.getError())
      return

    # Read response status line
    let lineFut = reader.readLine("\r\n")
    lineFut.addCallback(proc() =
      if lineFut.hasError():
        fut.fail(lineFut.getError())
        return

      let statusLine = lineFut.read()
      # Parse "HTTP/1.x 200 Connection established"
      let parts = statusLine.split(' ', 2)
      if parts.len < 2:
        fut.fail(newException(ProxyError, "Invalid HTTP proxy response: " & statusLine))
        return

      var statusCode: int
      try:
        statusCode = parseInt(parts[1])
      except ValueError:
        fut.fail(newException(ProxyError, "Invalid HTTP proxy status: " & parts[1]))
        return

      if statusCode < 200 or statusCode >= 300:
        let reason = if parts.len > 2: parts[2] else: "Unknown"
        fut.fail(newException(ProxyError,
          "HTTP proxy CONNECT failed: " & $statusCode & " " & reason))
        return

      # Drain remaining response headers (read until empty line)
      proc drainHeaders() =
        let hdrFut = reader.readLine("\r\n")
        hdrFut.addCallback(proc() =
          if hdrFut.hasError():
            fut.fail(hdrFut.getError())
            return
          let line = hdrFut.read()
          if line.len == 0:
            # Empty line — tunnel established
            fut.complete()
          else:
            drainHeaders()
        )
      drainHeaders()
    )
  )
  result = fut

# ============================================================
# ProxyStream - transparent stream wrapper after proxy handshake
# ============================================================

type
  ProxyStream* = ref object of AsyncStream
    ## A stream that wraps an inner stream (typically TcpStream) with a
    ## completed proxy tunnel. After handshake, reads and writes pass
    ## through transparently.
    innerStream*: AsyncStream
    reader: BufferedReader  ## Used during handshake; may have buffered data
    targetHost*: string
    targetPort*: int

proc proxyStreamRead(s: AsyncStream, size: int): CpsFuture[string] =
  let ps = ProxyStream(s)
  # After handshake, the BufferedReader may have extra data from
  # the proxy response. Drain it first, then read from the inner stream.
  if ps.reader != nil and not ps.reader.atEof:
    return ps.reader.read(size)
  return ps.innerStream.read(size)

proc proxyStreamWrite(s: AsyncStream, data: string): CpsVoidFuture =
  let ps = ProxyStream(s)
  ps.innerStream.write(data)

proc proxyStreamClose(s: AsyncStream) =
  let ps = ProxyStream(s)
  ps.innerStream.close()

proc newProxyStream(innerStream: AsyncStream, reader: BufferedReader,
                    targetHost: string, targetPort: int): ProxyStream =
  ## Create a ProxyStream wrapping a completed tunnel.
  ## The reader may still hold buffered data from the proxy handshake.
  result = ProxyStream(
    innerStream: innerStream,
    reader: reader,
    targetHost: targetHost,
    targetPort: targetPort,
    closed: false
  )
  result.readProc = proxyStreamRead
  result.writeProc = proxyStreamWrite
  result.closeProc = proxyStreamClose

# ============================================================
# High-level API: connect through a single proxy
# ============================================================

proc proxyConnect*(proxy: ProxyConfig,
                   targetHost: string, targetPort: int): CpsFuture[ProxyStream] =
  ## Connect to `targetHost:targetPort` through a proxy.
  ## Returns a ProxyStream that can be used as a normal AsyncStream.
  ##
  ## The ProxyStream wraps a TcpStream connected to the proxy server,
  ## with the proxy handshake already completed.
  let fut = newCpsFuture[ProxyStream]()
  fut.pinFutureRuntime()

  let tcpFut = tcpConnect(proxy.host, proxy.port)
  tcpFut.addCallback(proc() =
    if tcpFut.hasError():
      fut.fail(tcpFut.getError())
      return

    let tcpStream = tcpFut.read()
    let stream: AsyncStream = tcpStream
    let reader = newBufferedReader(stream)

    var handshakeFut: CpsVoidFuture
    case proxy.kind
    of pkSocks4:
      handshakeFut = socks4Handshake(stream, reader, targetHost, targetPort,
                                      proxy.auth.username, useSocks4a = false)
    of pkSocks4a:
      handshakeFut = socks4Handshake(stream, reader, targetHost, targetPort,
                                      proxy.auth.username, useSocks4a = true)
    of pkSocks5:
      handshakeFut = socks5Handshake(stream, reader, targetHost, targetPort,
                                      proxy.auth)
    of pkHttpConnect:
      handshakeFut = httpConnectHandshake(stream, reader, targetHost, targetPort,
                                           proxy.auth)

    handshakeFut.addCallback(proc() =
      if handshakeFut.hasError():
        tcpStream.close()
        fut.fail(handshakeFut.getError())
      else:
        let ps = newProxyStream(stream, reader, targetHost, targetPort)
        fut.complete(ps)
    )
  )
  result = fut

# ============================================================
# High-level API: connect through a chain of proxies
# ============================================================

proc proxyChainConnect*(proxies: openArray[ProxyConfig],
                        targetHost: string, targetPort: int): CpsFuture[ProxyStream] =
  ## Connect to `targetHost:targetPort` through a chain of proxies.
  ## Each proxy tunnels through the previous one, building a layered tunnel.
  ##
  ## Example chain: [proxyA, proxyB] → connects to proxyA, then through
  ## proxyA to proxyB, then through proxyB to the target.
  ##
  ## Returns a ProxyStream that transparently reads/writes to the target.
  let proxySeq = @proxies  # Copy to seq so closures can capture it

  if proxySeq.len == 0:
    let fut = newCpsFuture[ProxyStream]()
    fut.fail(newException(ProxyError, "Proxy chain is empty"))
    return fut

  if proxySeq.len == 1:
    return proxyConnect(proxySeq[0], targetHost, targetPort)

  let fut = newCpsFuture[ProxyStream]()
  fut.pinFutureRuntime()

  # Step 1: Connect to the first proxy (TCP)
  let firstProxy = proxySeq[0]
  let tcpFut = tcpConnect(firstProxy.host, firstProxy.port)

  tcpFut.addCallback(proc() =
    if tcpFut.hasError():
      fut.fail(tcpFut.getError())
      return

    let tcpStream = tcpFut.read()

    # Chain through each proxy in sequence.
    # currentStream starts as the TCP connection to proxy[0].
    # For each hop i (0 ..< proxySeq.len):
    #   - The target of hop i is proxy[i+1] (or final target for last hop)
    #   - We perform proxy[i]'s handshake on currentStream to reach that target
    #   - After handshake, currentStream becomes the tunnel
    proc doHop(hopIdx: int, currentStream: AsyncStream) =
      let proxy = proxySeq[hopIdx]
      let isLastHop = hopIdx == proxySeq.len - 1

      # Determine what this hop connects to
      var hopTarget: string
      var hopPort: int
      if isLastHop:
        hopTarget = targetHost
        hopPort = targetPort
      else:
        hopTarget = proxySeq[hopIdx + 1].host
        hopPort = proxySeq[hopIdx + 1].port

      let reader = newBufferedReader(currentStream)

      var handshakeFut: CpsVoidFuture
      case proxy.kind
      of pkSocks4:
        handshakeFut = socks4Handshake(currentStream, reader, hopTarget, hopPort,
                                        proxy.auth.username, useSocks4a = false)
      of pkSocks4a:
        handshakeFut = socks4Handshake(currentStream, reader, hopTarget, hopPort,
                                        proxy.auth.username, useSocks4a = true)
      of pkSocks5:
        handshakeFut = socks5Handshake(currentStream, reader, hopTarget, hopPort,
                                        proxy.auth)
      of pkHttpConnect:
        handshakeFut = httpConnectHandshake(currentStream, reader, hopTarget, hopPort,
                                             proxy.auth)

      handshakeFut.addCallback(proc() =
        if handshakeFut.hasError():
          currentStream.close()
          fut.fail(handshakeFut.getError())
          return

        let tunnelStream = newProxyStream(currentStream, reader, hopTarget, hopPort)

        if isLastHop:
          fut.complete(tunnelStream)
        else:
          doHop(hopIdx + 1, tunnelStream.AsyncStream)
      )

    # Perform first handshake — proxy[0] connects to proxy[1]
    doHop(0, tcpStream.AsyncStream)
  )
  result = fut

# ============================================================
# Convenience: get TcpStream-like fd access for TLS wrapping
# ============================================================

proc getUnderlyingFd*(ps: ProxyStream): SocketHandle =
  ## Get the socket handle from the deepest stream layer.
  ## Useful for TLS wrapping: TLS needs the raw fd for SSL_set_fd.
  var s = ps.innerStream
  while s of ProxyStream:
    s = ProxyStream(s).innerStream
  if s of TcpStream:
    return TcpStream(s).fd
  raise newException(ProxyError, "Could not find underlying socket fd")

proc getUnderlyingTcpStream*(ps: ProxyStream): TcpStream =
  ## Get the deepest TcpStream in the proxy chain.
  ## Useful for TLS wrapping.
  var s = ps.innerStream
  while s of ProxyStream:
    s = ProxyStream(s).innerStream
  if s of TcpStream:
    return TcpStream(s)
  raise newException(ProxyError, "Could not find underlying TcpStream")
