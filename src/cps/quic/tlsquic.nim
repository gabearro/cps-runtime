## BoringSSL QUIC-TLS glue declarations for direct QUIC integration.

when not defined(useBoringSSL):
  {.error: "tlsquic.nim requires -d:useBoringSSL".}

import std/openssl
import ./types
import ../tls/boringssl_compat

type
  SslEncryptionLevel* {.size: sizeof(cint).} = enum
    selInitial = 0
    selEarlyData = 1
    selHandshake = 2
    selApplication = 3

  SslCipher* = object

  SslQuicSetReadSecretCb* = proc(ssl: SslPtr,
                                 level: SslEncryptionLevel,
                                 cipher: ptr SslCipher,
                                 secret: ptr uint8,
                                 secretLen: csize_t): cint {.cdecl.}
  SslQuicSetWriteSecretCb* = proc(ssl: SslPtr,
                                  level: SslEncryptionLevel,
                                  cipher: ptr SslCipher,
                                  secret: ptr uint8,
                                  secretLen: csize_t): cint {.cdecl.}
  SslQuicAddHandshakeDataCb* = proc(ssl: SslPtr,
                                    level: SslEncryptionLevel,
                                    data: ptr uint8,
                                    dataLen: csize_t): cint {.cdecl.}
  SslQuicFlushFlightCb* = proc(ssl: SslPtr): cint {.cdecl.}
  SslQuicSendAlertCb* = proc(ssl: SslPtr,
                             level: SslEncryptionLevel,
                             alert: uint8): cint {.cdecl.}

  SslQuicMethod* {.bycopy.} = object
    setReadSecret*: SslQuicSetReadSecretCb
    setWriteSecret*: SslQuicSetWriteSecretCb
    addHandshakeData*: SslQuicAddHandshakeDataCb
    flushFlight*: SslQuicFlushFlightCb
    sendAlert*: SslQuicSendAlertCb

proc SSL_CTX_set_quic_method*(ctx: SslCtx,
                              quicMethod: ptr SslQuicMethod): cint
  {.cdecl, dynlib: DLLSSLName, importc.}

proc SSL_set_quic_method*(ssl: SslPtr,
                          quicMethod: ptr SslQuicMethod): cint
  {.cdecl, dynlib: DLLSSLName, importc.}

proc SSL_set_quic_transport_params*(ssl: SslPtr,
                                    params: ptr uint8,
                                    paramsLen: csize_t): cint
  {.cdecl, dynlib: DLLSSLName, importc.}

proc SSL_get_peer_quic_transport_params*(ssl: SslPtr,
                                         outParams: ptr ptr uint8,
                                         outLen: ptr csize_t)
  {.cdecl, dynlib: DLLSSLName, importc.}

proc SSL_provide_quic_data*(ssl: SslPtr,
                            level: SslEncryptionLevel,
                            data: ptr uint8,
                            dataLen: csize_t): cint
  {.cdecl, dynlib: DLLSSLName, importc.}

proc SSL_process_quic_post_handshake*(ssl: SslPtr): cint
  {.cdecl, dynlib: DLLSSLName, importc.}

proc SSL_quic_read_level*(ssl: SslPtr): SslEncryptionLevel
  {.cdecl, dynlib: DLLSSLName, importc.}

proc SSL_quic_write_level*(ssl: SslPtr): SslEncryptionLevel
  {.cdecl, dynlib: DLLSSLName, importc.}

proc SSL_quic_max_handshake_flight_len*(ssl: SslPtr,
                                        level: SslEncryptionLevel): csize_t
  {.cdecl, dynlib: DLLSSLName, importc.}

proc SSL_CIPHER_get_id*(cipher: ptr SslCipher): culong
  {.cdecl, dynlib: DLLSSLName, importc.}

proc quicLevelFromSpace*(space: QuicPacketNumberSpace): SslEncryptionLevel {.inline.} =
  case space
  of qpnsInitial: selInitial
  of qpnsHandshake: selHandshake
  of qpnsApplication: selApplication

proc spaceFromQuicLevel*(level: SslEncryptionLevel): QuicPacketNumberSpace =
  case level
  of selInitial: qpnsInitial
  of selHandshake: qpnsHandshake
  of selApplication, selEarlyData:
    # For transport purposes, early-data and application-data use application space.
    qpnsApplication
