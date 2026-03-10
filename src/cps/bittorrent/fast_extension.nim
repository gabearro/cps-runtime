## BEP 6: Fast Extension.
##
## Handshake bit helpers and Allowed Fast set generation.
## Message encoding/decoding is handled by peer_protocol.nim.

import sha1
import utils

const
  FastExtensionBit* = 0x04'u8  ## Bit in reserved[7]

proc supportsFastExtension*(reserved: array[8, byte]): bool =
  (reserved[7] and FastExtensionBit) != 0

proc setFastExtensionBit*(reserved: var array[8, byte]) =
  reserved[7] = reserved[7] or FastExtensionBit

proc generateAllowedFastSet*(infoHash: array[20, byte],
                              ip: string,
                              numPieces: int,
                              setSize: int = 10): seq[uint32] =
  ## Generate the Allowed Fast set for a peer using the BEP 6 algorithm.
  var ipBytes = parseIpv4(ip)
  if ipBytes == default(array[4, byte]):
    return @[]
  ipBytes[3] = 0  # Mask to /24

  # Initial hash: SHA1(ip_masked + info_hash)
  var hashInput = newStringOfCap(24)
  for b in ipBytes:
    hashInput.add(char(b))
  for b in infoHash:
    hashInput.add(char(b))

  var hash = sha1(hashInput)
  result = newSeqOfCap[uint32](setSize)

  while result.len < setSize:
    for i in countup(0, 16, 4):
      if result.len >= setSize:
        break
      let idx = (uint32(hash[i]) shl 24 or uint32(hash[i+1]) shl 16 or
                 uint32(hash[i+2]) shl 8 or uint32(hash[i+3])) mod uint32(numPieces)
      var found = false
      for existing in result:
        if existing == idx:
          found = true
          break
      if not found:
        result.add(idx)

    # Generate next hash from current hash
    var nextInput = newStringOfCap(20)
    for b in hash:
      nextInput.add(char(b))
    hash = sha1(nextInput)
