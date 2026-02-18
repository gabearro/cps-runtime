## Server-Side TLS
##
## Provides TLS server context creation (certificate/key loading, ALPN),
## async SSL_accept handshake, and AsyncStream vtable for server connections.
##
## IMPORTANT: All SSL operations (SSL_accept, SSL_read, SSL_write) must run
## on the reactor thread. In MT mode, if called from a worker thread, the
## initial call is proxied to the event loop via postToEventLoop.

import std/[nativesockets, net, os, openssl]
import ../runtime
import ../eventloop
import ../io/tcp
import ../io/streams

# Reuse the SSL_CTX_ctrl binding from client tls.nim for min proto version
const SSL_CTRL_SET_MIN_PROTO_VERSION = 123.clong
const TLS1_2_VERSION = 0x0303.clong
const SSL_FILETYPE_PEM = 1.cint

proc SSL_CTX_ctrl*(ctx: SslCtx, cmd: clong, larg: clong, parg: pointer): clong
  {.cdecl, dynlib: DLLSSLName, importc.}

type
  TlsServerContext* = ref object
    sslCtx*: SslCtx
    alpnProtocols*: seq[string]
    alpnWire*: seq[byte]  ## Wire-format of server preferred protocols

  TlsServerStream* = ref object of AsyncStream
    ssl: SslPtr
    ctx: TlsServerContext
    tcpStream*: TcpStream
    connected: bool
    alpnProto*: string  ## Negotiated ALPN protocol

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

# ============================================================
# ALPN server callback
# ============================================================

proc alpnSelectCallback(ssl: SslPtr, outProto: ptr cstring,
                         outLen: cstring,  # Actually ptr cuchar
                         inProto: cstring, inLen: cuint,
                         arg: pointer): cint {.cdecl.} =
  let serverCtx = cast[TlsServerContext](arg)
  if serverCtx.alpnWire.len == 0:
    return 3  # SSL_TLSEXT_ERR_NOACK

  let ret = SSL_select_next_proto(
    outProto,
    outLen,
    cast[cstring](unsafeAddr serverCtx.alpnWire[0]),
    cuint(serverCtx.alpnWire.len),
    inProto,
    inLen
  )
  if ret == 1:  # OPENSSL_NPN_NEGOTIATED
    return 0    # SSL_TLSEXT_ERR_OK
  else:
    return 3    # SSL_TLSEXT_ERR_NOACK

# ============================================================
# TLS Server Context
# ============================================================

proc newTlsServerContext*(certFile: string, keyFile: string,
                           alpnProtocols: seq[string] = @["h2", "http/1.1"]): TlsServerContext =
  SSL_library_init()
  SSL_load_error_strings()

  let ctx = SSL_CTX_new(TLS_method())
  if ctx.isNil:
    raise newException(system.IOError, "Failed to create server SSL context")

  discard SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, TLS1_2_VERSION, nil)

  if SSL_CTX_use_certificate_chain_file(ctx, certFile.cstring) != 1:
    SSL_CTX_free(ctx)
    raise newException(system.IOError, "Failed to load certificate: " & certFile)

  if SSL_CTX_use_PrivateKey_file(ctx, keyFile.cstring, SSL_FILETYPE_PEM) != 1:
    SSL_CTX_free(ctx)
    raise newException(system.IOError, "Failed to load private key: " & keyFile)

  if SSL_CTX_check_private_key(ctx) != 1:
    SSL_CTX_free(ctx)
    raise newException(system.IOError, "Private key does not match certificate")

  result = TlsServerContext(
    sslCtx: ctx,
    alpnProtocols: alpnProtocols
  )

  for proto in alpnProtocols:
    result.alpnWire.add byte(proto.len)
    for c in proto:
      result.alpnWire.add byte(c)

  if alpnProtocols.len > 0:
    GC_ref(result)
    discard SSL_CTX_set_alpn_select_cb(ctx, alpnSelectCallback,
                                        cast[pointer](result))

proc closeTlsServerContext*(ctx: TlsServerContext) =
  if not ctx.sslCtx.isNil:
    SSL_CTX_free(ctx.sslCtx)

# ============================================================
# AsyncStream vtable for TlsServerStream
# ============================================================

proc tlsServerStreamRead(s: AsyncStream, size: int): CpsFuture[string] =
  let tls = TlsServerStream(s)
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
      fut.complete("")
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
        fut.complete("")
      else:
        fut.fail(newException(system.IOError, "TLS server read failed, SSL error: " & $err))

  # SSL objects are not thread-safe. Ensure doRecv runs on the reactor.
  ensureOnReactor(doRecv)
  result = fut

proc tlsServerStreamWrite(s: AsyncStream, data: string): CpsVoidFuture =
  let tls = TlsServerStream(s)
  let fut = newCpsVoidFuture()
  fut.pinFutureRuntime()
  let loop = getEventLoop()
  var sent = 0
  let totalLen = data.len

  proc doSend() =
    while sent < totalLen:
      let remaining = totalLen - sent
      let ret = SSL_write(tls.ssl, unsafeAddr data[sent], remaining.cint)
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
          fut.fail(newException(system.IOError, "TLS server write failed, SSL error: " & $err))
          return
    fut.complete()

  # SSL objects are not thread-safe. Ensure doSend runs on the reactor.
  ensureOnReactor(doSend)
  result = fut

proc tlsServerStreamClose(s: AsyncStream) =
  let tls = TlsServerStream(s)
  if tls.connected:
    discard SSL_shutdown(tls.ssl)
    tls.connected = false
  SSL_free(tls.ssl)
  tls.tcpStream.close()

# ============================================================
# TLS Accept (async handshake)
# ============================================================

proc getAlpnProtocol(tls: TlsServerStream): string =
  var proto: cstring
  var protoLen: cuint
  SSL_get0_alpn_selected(tls.ssl, cast[ptr cstring](addr proto), addr protoLen)
  if protoLen > 0 and not proto.isNil:
    result = newString(protoLen)
    copyMem(addr result[0], proto, protoLen)
  else:
    result = "http/1.1"

proc tlsAccept*(ctx: TlsServerContext, tcpStream: TcpStream): CpsFuture[TlsServerStream] =
  ## Perform TLS server handshake asynchronously.
  let fut = newCpsFuture[TlsServerStream]()
  fut.pinFutureRuntime()
  let loop = getEventLoop()

  let ssl = SSL_new(ctx.sslCtx)
  if ssl.isNil:
    fut.fail(newException(system.IOError, "Failed to create server SSL object"))
    return fut

  discard SSL_set_fd(ssl, tcpStream.fd)

  let tls = TlsServerStream(
    ssl: ssl,
    ctx: ctx,
    tcpStream: tcpStream,
    connected: false,
    alpnProto: "",
    closed: false
  )
  tls.readProc = tlsServerStreamRead
  tls.writeProc = tlsServerStreamWrite
  tls.closeProc = tlsServerStreamClose

  proc doAccept() =
    ErrClearError()
    let ret = SSL_accept(tls.ssl)
    if ret == 1:
      tls.connected = true
      tls.alpnProto = tls.getAlpnProtocol()
      fut.complete(tls)
      return

    let err = SSL_get_error(tls.ssl, ret)
    if err == SSL_ERROR_WANT_READ:
      loop.registerRead(tls.tcpStream.fd, proc() =
        loop.unregister(tls.tcpStream.fd)
        doAccept()
      )
    elif err == SSL_ERROR_WANT_WRITE:
      loop.registerWrite(tls.tcpStream.fd, proc() =
        loop.unregister(tls.tcpStream.fd)
        doAccept()
      )
    else:
      fut.fail(newException(system.IOError, "TLS server handshake failed, SSL error: " & $err))

  # SSL_accept must run on the reactor thread (SSL not thread-safe).
  ensureOnReactor(doAccept)
  return fut
