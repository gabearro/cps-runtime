## SHA1 implementation for BitTorrent info hash and piece verification.
##
## Uses OpenSSL's SHA1 (hardware-accelerated on modern CPUs).

# OpenSSL SHA1 — already linked via config.nims
# Declare without header to avoid include path issues; OpenSSL is linked via config.nims
proc SHA1(d: pointer, n: csize_t, md: pointer): pointer {.importc, cdecl.}

proc sha1*(data: string): array[20, byte] =
  ## Compute SHA-1 hash using OpenSSL.
  if data.len == 0:
    discard SHA1(nil, 0.csize_t, addr result[0])
  else:
    discard SHA1(unsafeAddr data[0], data.len.csize_t, addr result[0])

proc sha1*(data: pointer, length: int): array[20, byte] =
  ## Compute SHA-1 hash from a raw buffer pointer.
  discard SHA1(data, length.csize_t, addr result[0])

proc sha1Hex*(data: string): string =
  ## Compute SHA-1 hash and return as hex string.
  let hash = sha1(data)
  result = newStringOfCap(40)
  const hexChars = "0123456789abcdef"
  for b in hash:
    result.add(hexChars[b.int shr 4])
    result.add(hexChars[b.int and 0x0F])
