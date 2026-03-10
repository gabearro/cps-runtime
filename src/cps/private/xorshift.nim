## XorShift32 PRNG
##
## Minimal pseudo-random number generator. Avoids importing std/random
## which loads macOS Security framework and clobbers Homebrew OpenSSL
## symbols (reduces available ciphers from 62 to 6).

import std/times

type
  XorShift32* = object
    state: uint32

proc initXorShift32*(seed: uint32): XorShift32 =
  result.state = if seed == 0: 2654435761'u32 else: seed

proc initXorShift32*(seed: int): XorShift32 =
  initXorShift32(uint32(seed))

proc next*(rng: var XorShift32): uint32 =
  var x = rng.state
  x = x xor (x shl 13)
  x = x xor (x shr 17)
  x = x xor (x shl 5)
  rng.state = x
  result = x

proc rand*(rng: var XorShift32, bound: int): int =
  ## Return a pseudo-random int in [0, bound).
  if bound <= 1: return 0
  int(rng.next() mod uint32(bound))

proc seedFromTime*(): uint32 =
  ## Derive a seed from current epoch time.
  uint32(int64(epochTime() * 1e9) and 0xFFFF_FFFF'i64) or 1
