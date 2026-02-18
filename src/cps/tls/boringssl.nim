## BoringSSL-specific FFI declarations
##
## These APIs are only available when compiling with -d:useBoringSSL.
## They provide fine-grained control over the TLS ClientHello for
## browser fingerprint impersonation (GREASE, extension permutation,
## cert compression, ALPS, etc.).

when not defined(useBoringSSL):
  {.error: "boringssl.nim requires -d:useBoringSSL".}

import std/openssl

# ============================================================
# GREASE and extension permutation
# ============================================================

proc SSL_CTX_set_grease_enabled*(ctx: SslCtx, enabled: cint)
  {.cdecl, dynlib: DLLSSLName, importc.}
  ## Enable/disable GREASE (Generate Random Extensions And Sustain Extensibility).
  ## Inserts random unknown values into ClientHello extensions, cipher suites, etc.

proc SSL_CTX_set_permute_extensions*(ctx: SslCtx, enabled: cint)
  {.cdecl, dynlib: DLLSSLName, importc.}
  ## Enable/disable random permutation of TLS extensions in ClientHello.
  ## Makes the extension order non-deterministic to defeat ordering-based fingerprinting.

# ============================================================
# Groups and signature algorithms
# ============================================================

proc SSL_CTX_set1_groups_list*(ctx: SslCtx, list: cstring): cint
  {.cdecl, dynlib: DLLSSLName, importc.}
  ## Set the supported groups (curves) for key exchange.
  ## `list` is colon-separated, e.g. "X25519:P-256:P-384".

proc SSL_CTX_set1_sigalgs_list*(ctx: SslCtx, str: cstring): cint
  {.cdecl, dynlib: DLLSSLName, importc.}
  ## Set the supported signature algorithms.
  ## `str` is colon-separated, e.g. "ecdsa_secp256r1_sha256:rsa_pss_rsae_sha256:...".

# ============================================================
# Version control (real functions in BoringSSL, not macros)
# ============================================================

proc SSL_CTX_set_min_proto_version*(ctx: SslCtx, version: uint16): cint
  {.cdecl, dynlib: DLLSSLName, importc.}

proc SSL_CTX_set_max_proto_version*(ctx: SslCtx, version: uint16): cint
  {.cdecl, dynlib: DLLSSLName, importc.}

# ============================================================
# Certificate compression (RFC 8879)
# ============================================================

type
  SslCertCompressionAlgCompressFunc* = proc(ssl: SslPtr, output: ptr ptr uint8,
    outputLen: ptr csize_t, input: ptr uint8, inputLen: csize_t): cint {.cdecl.}
  SslCertCompressionAlgDecompressFunc* = proc(ssl: SslPtr, output: ptr ptr uint8,
    outputLen: ptr csize_t, maxUncompressedLen: csize_t,
    input: ptr uint8, inputLen: csize_t): cint {.cdecl.}

const
  CertCompressionBrotli* = 0x0002'u16  ## Brotli algorithm ID for cert compression

proc SSL_CTX_add_cert_compression_alg*(ctx: SslCtx, algId: uint16,
    compress: SslCertCompressionAlgCompressFunc,
    decompress: SslCertCompressionAlgDecompressFunc): cint
  {.cdecl, dynlib: DLLSSLName, importc.}
  ## Register a certificate compression algorithm.
  ## `compress` can be nil (client-only). `decompress` must handle decompression.

# ============================================================
# ALPS (Application-Layer Protocol Settings)
# ============================================================

proc SSL_add_application_settings*(ssl: SslPtr, proto: ptr uint8,
    protoLen: csize_t, settings: ptr uint8, settingsLen: csize_t): cint
  {.cdecl, dynlib: DLLSSLName, importc.}
  ## Add ALPS data for a given ALPN protocol.
  ## Called after SSL_new, before SSL_connect.
