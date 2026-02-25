## TLS Layer for CPS Async Streams
##
## Wraps OpenSSL to provide TLS encryption over TcpStream via AsyncStream vtable.
## Supports ALPN negotiation for HTTP/2.

import std/[nativesockets, net, strutils, openssl]
import ../runtime
import ../eventloop
import ../io/tcp
import ../io/streams
import ./fingerprint

when defined(useBoringSSL):
  import ./boringssl
  import ./boringssl_compat

# ============================================================
# Helper: ensure a closure runs on the reactor thread
# ============================================================

proc ensureOnReactor(cb: proc() {.closure.}) =
  ## If called from a worker thread in MT mode, proxy to the reactor.
  ## Otherwise, call directly.
  let rt = currentRuntime().runtime
  if rt != nil and rt.flavor == rfMultiThread and isSchedulerWorker and
      currentSchedulerPtr == cast[pointer](rt.schedulerPtr):
    let loop = getEventLoop()
    loop.postToEventLoop(proc() {.closure, gcsafe.} =
      {.cast(gcsafe).}:
        cb()
    )
  else:
    cb()

# SSL_CTX_set_min/max_proto_version are macros in OpenSSL 3.x,
# implemented via SSL_CTX_ctrl. We call ctrl directly for OpenSSL.
# In BoringSSL these are real functions (imported via boringssl.nim).
const TLS1_2_VERSION* = 0x0303.clong

proc SSL_CTX_ctrl*(ctx: SslCtx, cmd: clong, larg: clong, parg: pointer): clong
  {.cdecl, dynlib: DLLSSLName, importc.}

proc sslCtxSetMinProtoVersion(ctx: SslCtx, version: clong): bool =
  when defined(useBoringSSL):
    boringssl.SSL_CTX_set_min_proto_version(ctx, uint16(version)) != 0
  else:
    const SSL_CTRL_SET_MIN_PROTO_VERSION = 123.clong
    SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, version, nil) != 0

when not defined(useBoringSSL):
  const SSL_CTRL_SET_MAX_PROTO_VERSION = 124.clong
  proc sslCtxSetMaxProtoVersion(ctx: SslCtx, version: clong): bool =
    SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MAX_PROTO_VERSION, version, nil) != 0
else:
  proc sslCtxSetMaxProtoVersion(ctx: SslCtx, version: clong): bool =
    boringssl.SSL_CTX_set_max_proto_version(ctx, uint16(version)) != 0

# SSL_CTX_set_ciphersuites for TLS 1.3 (OpenSSL 1.1.1+ / BoringSSL)
proc SSL_CTX_set_ciphersuites*(ctx: SslCtx, str: cstring): cint
  {.cdecl, dynlib: DLLSSLName, importc.}

# SSL_CTX_set1_groups_list / SSL_CTX_set1_sigalgs_list
# In OpenSSL 3.x these are macros via SSL_CTX_ctrl.
# In BoringSSL they are real functions (imported via boringssl.nim).
when not defined(useBoringSSL):
  const SSL_CTRL_SET_GROUPS_LIST = 92.clong
  const SSL_CTRL_SET_SIGALGS_LIST = 98.clong
  proc SSL_CTX_set1_groups_list*(ctx: SslCtx, list: cstring): clong =
    SSL_CTX_ctrl(ctx, SSL_CTRL_SET_GROUPS_LIST, 0, cast[pointer](list))
  proc SSL_CTX_set1_sigalgs_list*(ctx: SslCtx, str: cstring): clong =
    SSL_CTX_ctrl(ctx, SSL_CTRL_SET_SIGALGS_LIST, 0, cast[pointer](str))

type
  TlsStream* = ref object of AsyncStream
    ssl: SslPtr
    ctx: SslCtx
    tcpStream*: TcpStream
    connected: bool
    alpnProto*: string  ## Negotiated ALPN protocol (e.g., "h2" or "http/1.1")

# ============================================================
# AsyncStream vtable implementation
# ============================================================

proc tlsStreamRead(s: AsyncStream, size: int): CpsFuture[string] =
  let tls = TlsStream(s)
  let fut = newCpsFuture[string]()
  fut.pinFutureRuntime()
  let loop = getEventLoop()

  proc doRecv() =
    var buf = newString(size)
    let ret = SSL_read(tls.ssl, addr buf[0], size.cint)
    if ret > 0:
      buf.setLen(ret)
      fut.complete(buf)
    elif ret == 0:
      fut.complete("")  # EOF / clean shutdown
    else:
      let err = SSL_get_error(tls.ssl, ret)
      if err == SSL_ERROR_WANT_READ:
        loop.registerRead(tls.tcpStream.fd, proc() =
          loop.unregister(tls.tcpStream.fd)
          doRecv()
        )
      elif err == SSL_ERROR_WANT_WRITE:
        loop.registerWrite(tls.tcpStream.fd, proc() =
          loop.unregister(tls.tcpStream.fd)
          doRecv()
        )
      elif err == SSL_ERROR_ZERO_RETURN:
        fut.complete("")  # TLS shutdown
      else:
        fut.fail(newException(system.IOError, "TLS read failed, SSL error: " & $err))

  # SSL objects are not thread-safe. Ensure doRecv runs on the reactor.
  ensureOnReactor(doRecv)
  result = fut

proc tlsStreamWrite(s: AsyncStream, data: string): CpsVoidFuture =
  let tls = TlsStream(s)
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()
  let loop = getEventLoop()
  var sent = 0
  let totalLen = data.len

  proc doSend() =
    while sent < totalLen:
      let remaining = totalLen - sent
      let writePtr = cast[cstring](unsafeAddr data[sent])
      let ret = SSL_write(tls.ssl, writePtr, remaining.cint)
      if ret > 0:
        sent += ret
      else:
        let err = SSL_get_error(tls.ssl, ret)
        if err == SSL_ERROR_WANT_READ:
          loop.registerRead(tls.tcpStream.fd, proc() =
            loop.unregister(tls.tcpStream.fd)
            doSend()
          )
          return
        elif err == SSL_ERROR_WANT_WRITE:
          loop.registerWrite(tls.tcpStream.fd, proc() =
            loop.unregister(tls.tcpStream.fd)
            doSend()
          )
          return
        else:
          fut.fail(newException(system.IOError, "TLS write failed, SSL error: " & $err))
          return
    fut.complete()

  # SSL objects are not thread-safe. Ensure doSend runs on the reactor.
  ensureOnReactor(doSend)
  result = fut

proc tlsStreamClose(s: AsyncStream) =
  let tls = TlsStream(s)
  if tls.connected:
    discard SSL_shutdown(tls.ssl)
    tls.connected = false
  SSL_free(tls.ssl)
  SSL_CTX_free(tls.ctx)
  tls.tcpStream.close()

# ============================================================
# Constructor
# ============================================================

proc newTlsStream*(tcpStream: TcpStream, hostname: string,
                   alpnProtocols: openArray[string] = @["h2", "http/1.1"],
                   fp: TlsFingerprint = nil): TlsStream =
  ## Create a TLS stream wrapping a TCP stream.
  ## Supports ALPN negotiation for HTTP/2.
  ## When `fp` is provided, applies the TLS fingerprint profile to the
  ## SSL context for browser impersonation.

  # Initialize OpenSSL
  SSL_library_init()
  SSL_load_error_strings()

  let ctx = SSL_CTX_new(TLS_method())
  if ctx.isNil:
    raise newException(system.IOError, "Failed to create SSL context")

  if fp != nil:
    # Apply fingerprint profile

    # Version control
    discard sslCtxSetMinProtoVersion(ctx, fp.minVersion.clong)
    discard sslCtxSetMaxProtoVersion(ctx, fp.maxVersion.clong)

    # Cipher suites (TLS 1.2) — works in both OpenSSL and BoringSSL
    if fp.cipherList.len > 0:
      discard SSL_CTX_set_cipher_list(ctx, fp.cipherList.cstring)

    # TLS 1.3 cipher suites — OpenSSL 1.1.1+ and BoringSSL
    if fp.cipherSuites.len > 0:
      discard SSL_CTX_set_ciphersuites(ctx, fp.cipherSuites.cstring)

    # Supported groups
    if fp.supportedGroups.len > 0:
      let rc = SSL_CTX_set1_groups_list(ctx, fp.supportedGroups.cstring)
      if rc == 0:
        # Post-quantum group may not be supported; fallback without it
        let fallback = fp.supportedGroups.replace("X25519Kyber768Draft00:", "")
        discard SSL_CTX_set1_groups_list(ctx, fallback.cstring)

    # Signature algorithms
    if fp.signatureAlgorithms.len > 0:
      discard SSL_CTX_set1_sigalgs_list(ctx, fp.signatureAlgorithms.cstring)

    # BoringSSL-only features
    when defined(useBoringSSL):
      if fp.greaseEnabled:
        SSL_CTX_set_grease_enabled(ctx, 1)
      if fp.permuteExtensions:
        SSL_CTX_set_permute_extensions(ctx, 1)
      if fp.certCompression:
        # Register Brotli cert compression algorithm.
        # compress=nil (client doesn't compress), decompress=nil (best-effort:
        # the extension appears in ClientHello but if the server sends compressed
        # certs we can't decompress — server will fall back to uncompressed).
        discard SSL_CTX_add_cert_compression_alg(ctx, CertCompressionBrotli, nil, nil)

    # ALPN: explicit parameter takes precedence over fingerprint's list
    let alpnToUse = if alpnProtocols.len > 0: @(alpnProtocols)
                    elif fp.alpnProtocols.len > 0: fp.alpnProtocols
                    else: @[]
    if alpnToUse.len > 0:
      var alpnBuf: seq[byte]
      for proto in alpnToUse:
        alpnBuf.add byte(proto.len)
        for c in proto:
          alpnBuf.add byte(c)
      discard SSL_CTX_set_alpn_protos(ctx, cast[cstring](addr alpnBuf[0]), cuint(alpnBuf.len))
  else:
    # Default behavior: TLS 1.2 minimum + ALPN
    discard sslCtxSetMinProtoVersion(ctx, TLS1_2_VERSION)
    if alpnProtocols.len > 0:
      var alpnBuf: seq[byte]
      for proto in alpnProtocols:
        alpnBuf.add byte(proto.len)
        for c in proto:
          alpnBuf.add byte(c)
      discard SSL_CTX_set_alpn_protos(ctx, cast[cstring](addr alpnBuf[0]), cuint(alpnBuf.len))

  let ssl = SSL_new(ctx)
  if ssl.isNil:
    SSL_CTX_free(ctx)
    raise newException(system.IOError, "Failed to create SSL object")

  # Set SNI hostname
  discard SSL_set_tlsext_host_name(ssl, hostname.cstring)

  # BoringSSL ALPS: set on SSL object after SSL_new
  when defined(useBoringSSL):
    if fp != nil and fp.alpsEnabled:
      # Register empty ALPS settings for "h2" (Chrome sends empty ALPS)
      let h2Proto = "h2"
      discard SSL_add_application_settings(ssl,
        cast[ptr uint8](unsafeAddr h2Proto[0]), csize_t(h2Proto.len),
        nil, 0)

  # Attach the socket fd
  discard SSL_set_fd(ssl, tcpStream.fd)

  result = TlsStream(
    ssl: ssl,
    ctx: ctx,
    tcpStream: tcpStream,
    connected: false,
    alpnProto: "",
    closed: false
  )
  result.readProc = tlsStreamRead
  result.writeProc = tlsStreamWrite
  result.closeProc = tlsStreamClose

# ============================================================
# TLS Handshake
# ============================================================

proc getAlpnProtocol(tls: TlsStream): string =
  var proto: cstring
  var protoLen: cuint
  SSL_get0_alpn_selected(tls.ssl, cast[ptr cstring](addr proto), addr protoLen)
  if protoLen > 0 and not proto.isNil:
    result = newString(protoLen)
    copyMem(addr result[0], proto, protoLen)
  else:
    result = "http/1.1"  # Default

proc tlsConnect*(tls: TlsStream): CpsVoidFuture =
  ## Perform TLS handshake asynchronously.
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()
  let loop = getEventLoop()

  proc doHandshake() =
    ErrClearError()
    let ret = SSL_connect(tls.ssl)
    if ret == 1:
      tls.connected = true
      tls.alpnProto = tls.getAlpnProtocol()
      fut.complete()
      return

    let err = SSL_get_error(tls.ssl, ret)
    if err == SSL_ERROR_WANT_READ:
      loop.registerRead(tls.tcpStream.fd, proc() =
        loop.unregister(tls.tcpStream.fd)
        doHandshake()
      )
    elif err == SSL_ERROR_WANT_WRITE:
      loop.registerWrite(tls.tcpStream.fd, proc() =
        loop.unregister(tls.tcpStream.fd)
        doHandshake()
      )
    else:
      fut.fail(newException(system.IOError, "TLS handshake failed, SSL error: " & $err))

  # SSL_connect must run on the reactor thread (SSL not thread-safe).
  ensureOnReactor(doHandshake)
  return fut
