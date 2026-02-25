## Cryptographically secure random bytes for QUIC runtime use.

import std/openssl

proc RAND_bytes(buf: ptr uint8, num: cint): cint {.cdecl, dynlib: DLLUtilName, importc.}

proc secureRandomFill*(dst: var openArray[byte]) =
  if dst.len == 0:
    return
  let rc = RAND_bytes(cast[ptr uint8](unsafeAddr dst[0]), dst.len.cint)
  if rc != 1:
    raise newException(ValueError, "secure random generation failed")

proc secureRandomBytes*(n: int): seq[byte] =
  if n < 0:
    raise newException(ValueError, "secure random length must be non-negative")
  result = newSeq[byte](n)
  if n > 0:
    secureRandomFill(result)
