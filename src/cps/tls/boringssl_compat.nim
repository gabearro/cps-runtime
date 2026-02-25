## Shared BoringSSL compatibility shims and helpers for TLS / QUIC.

when defined(useBoringSSL):
  import std/openssl

  # Compile compatibility C shims once for all BoringSSL users.
  {.compile: "boringssl_compat.c".}

  proc boringSslSetTlsExtHostName*(ssl: SslPtr, name: cstring): cint
    {.cdecl, importc: "cps_boringssl_set_tlsext_host_name".}

  proc boringSslGetPeerCertificate*(ssl: SslPtr): PX509
    {.cdecl, importc: "cps_boringssl_get_peer_certificate".}

  proc boringSslChacha20Poly1305Seal*(
    key: ptr uint8, keyLen: csize_t,
    nonce: ptr uint8, nonceLen: csize_t,
    aad: ptr uint8, aadLen: csize_t,
    plaintext: ptr uint8, plaintextLen: csize_t,
    outBuf: ptr uint8, outLen: ptr csize_t,
    maxOutLen: csize_t
  ): cint {.cdecl, importc: "cps_boringssl_chacha20poly1305_seal".}

  proc boringSslChacha20Poly1305Open*(
    key: ptr uint8, keyLen: csize_t,
    nonce: ptr uint8, nonceLen: csize_t,
    aad: ptr uint8, aadLen: csize_t,
    ciphertext: ptr uint8, ciphertextLen: csize_t,
    outBuf: ptr uint8, outLen: ptr csize_t,
    maxOutLen: csize_t
  ): cint {.cdecl, importc: "cps_boringssl_chacha20poly1305_open".}

  proc boringSslChacha20HeaderProtectionMask*(
    key: ptr uint8, keyLen: csize_t,
    sample: ptr uint8, sampleLen: csize_t,
    outMask: ptr uint8, outMaskLen: csize_t
  ): cint {.cdecl, importc: "cps_boringssl_chacha20_hp_mask".}
else:
  discard
