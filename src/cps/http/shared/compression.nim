## HTTP Compression
##
## Unified compression/decompression module supporting gzip, deflate,
## raw deflate (for WebSocket permessage-deflate), and optionally zstd/brotli.
##
## - Buffered (in-memory) compression via zippy (always available)
## - Streaming compression via zlib C FFI (for SSE)
## - zstd via C FFI (compile with -d:useZstd)
## - brotli via C FFI (compile with -d:useBrotli)

import std/strutils
import zippy
import ../../runtime
import ../../io/streams

type
  ContentEncoding* = enum
    ceIdentity = "identity"
    ceGzip = "gzip"
    ceDeflate = "deflate"
    ceZstd = "zstd"
    ceBrotli = "br"

  CompressionError* = object of CatchableError

  CompressionLevel* = enum
    clFast
    clDefault
    clBest

# ============================================================
# Buffered compression via zippy
# ============================================================

proc gzipCompress*(data: string, level: CompressionLevel = clDefault): string =
  let zLevel = case level
    of clFast: zippy.BestSpeed
    of clDefault: zippy.DefaultCompression
    of clBest: zippy.BestCompression
  try:
    result = zippy.compress(data, zLevel, dfGzip)
  except ZippyError as e:
    raise newException(CompressionError, "gzip compress failed: " & e.msg)

proc gzipDecompress*(data: string): string =
  try:
    result = zippy.uncompress(data, dfGzip)
  except ZippyError as e:
    raise newException(CompressionError, "gzip decompress failed: " & e.msg)

proc deflateCompress*(data: string, level: CompressionLevel = clDefault): string =
  ## HTTP "deflate" is actually zlib-wrapped deflate (RFC 2616).
  let zLevel = case level
    of clFast: zippy.BestSpeed
    of clDefault: zippy.DefaultCompression
    of clBest: zippy.BestCompression
  try:
    result = zippy.compress(data, zLevel, dfZlib)
  except ZippyError as e:
    raise newException(CompressionError, "deflate compress failed: " & e.msg)

proc deflateDecompress*(data: string): string =
  try:
    result = zippy.uncompress(data, dfZlib)
  except ZippyError as e:
    raise newException(CompressionError, "deflate decompress failed: " & e.msg)

# rawDeflateCompress/rawDeflateDecompress are defined after zlib FFI section below

# ============================================================
# zlib C FFI — streaming compression for SSE
# ============================================================

const
  Z_OK* = 0.cint
  Z_STREAM_END* = 1.cint
  Z_BUF_ERROR* = -5.cint
  Z_SYNC_FLUSH* = 2.cint
  Z_FINISH* = 4.cint
  Z_NO_FLUSH* = 0.cint
  MAX_WBITS* = 15.cint
  Z_DEFLATED* = 8.cint
  Z_DEFAULT_STRATEGY* = 0.cint
  Z_DEFAULT_COMPRESSION* = -1.cint
  ZLIB_VERSION = "1.2.11"

{.passL: "-lz".}

type
  ZStream* {.importc: "z_stream", header: "<zlib.h>".} = object
    next_in* {.importc: "next_in".}: ptr uint8
    avail_in* {.importc: "avail_in".}: cuint
    total_in* {.importc: "total_in".}: culong
    next_out* {.importc: "next_out".}: ptr uint8
    avail_out* {.importc: "avail_out".}: cuint
    total_out* {.importc: "total_out".}: culong
    msg* {.importc: "msg".}: cstring
    state {.importc: "state".}: pointer
    zalloc {.importc: "zalloc".}: pointer
    zfree {.importc: "zfree".}: pointer
    opaque {.importc: "opaque".}: pointer
    data_type {.importc: "data_type".}: cint
    adler {.importc: "adler".}: culong
    reserved {.importc: "reserved".}: culong

proc deflateInit2(strm: ptr ZStream, level: cint, meth: cint,
                  windowBits: cint, memLevel: cint,
                  strategy: cint, version: cstring,
                  stream_size: cint): cint
  {.importc: "deflateInit2_", header: "<zlib.h>".}

proc deflate(strm: ptr ZStream, flush: cint): cint
  {.importc: "deflate", header: "<zlib.h>".}

proc deflateEnd(strm: ptr ZStream): cint
  {.importc: "deflateEnd", header: "<zlib.h>".}

proc inflateInit2(strm: ptr ZStream, windowBits: cint,
                  version: cstring, stream_size: cint): cint
  {.importc: "inflateInit2_", header: "<zlib.h>".}

proc inflate(strm: ptr ZStream, flush: cint): cint
  {.importc: "inflate", header: "<zlib.h>".}

proc inflateEnd(strm: ptr ZStream): cint
  {.importc: "inflateEnd", header: "<zlib.h>".}

type
  ZlibCompressor* = ref object
    strm: ZStream
    initialized: bool

  ZlibDecompressor* = ref object
    strm: ZStream
    initialized: bool

proc newZlibCompressor*(encoding: ContentEncoding = ceGzip): ZlibCompressor =
  ## Create a streaming compressor. encoding must be ceGzip or ceDeflate.
  result = ZlibCompressor()
  var windowBits: cint
  case encoding
  of ceGzip:
    windowBits = MAX_WBITS + 16  # gzip format
  of ceDeflate:
    windowBits = MAX_WBITS       # zlib format
  else:
    raise newException(CompressionError,
      "ZlibCompressor only supports gzip/deflate, not " & $encoding)

  let rc = deflateInit2(addr result.strm, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                        windowBits, 8, Z_DEFAULT_STRATEGY,
                        ZLIB_VERSION, cint(sizeof(ZStream)))
  if rc != Z_OK:
    raise newException(CompressionError, "deflateInit2 failed: " & $rc)
  result.initialized = true

proc compressChunk*(c: ZlibCompressor, data: string): string =
  ## Compress a chunk of data, flushing with Z_SYNC_FLUSH so the output
  ## is immediately decompressible. Used for SSE event streaming.
  if not c.initialized:
    raise newException(CompressionError, "Compressor not initialized")

  let outBufSize = data.len + 256  # enough for small chunks
  var outBuf = newString(outBufSize)

  c.strm.next_in = if data.len > 0: cast[ptr uint8](unsafeAddr data[0]) else: nil
  c.strm.avail_in = cuint(data.len)
  c.strm.next_out = cast[ptr uint8](addr outBuf[0])
  c.strm.avail_out = cuint(outBufSize)

  let rc = deflate(addr c.strm, Z_SYNC_FLUSH)
  if rc != Z_OK and rc != Z_BUF_ERROR:
    raise newException(CompressionError, "deflate failed: " & $rc)

  let produced = outBufSize - c.strm.avail_out.int
  outBuf.setLen(produced)
  result = outBuf

proc finish*(c: ZlibCompressor): string =
  ## Finish the compression stream. Returns any remaining compressed bytes.
  if not c.initialized:
    return ""

  let outBufSize = 256
  var outBuf = newString(outBufSize)

  c.strm.next_in = nil
  c.strm.avail_in = 0
  c.strm.next_out = cast[ptr uint8](addr outBuf[0])
  c.strm.avail_out = cuint(outBufSize)

  discard deflate(addr c.strm, Z_FINISH)
  let produced = outBufSize - c.strm.avail_out.int
  outBuf.setLen(produced)

  discard deflateEnd(addr c.strm)
  c.initialized = false
  result = outBuf

proc destroy*(c: ZlibCompressor) =
  if c.initialized:
    discard deflateEnd(addr c.strm)
    c.initialized = false

proc newZlibDecompressor*(encoding: ContentEncoding = ceGzip): ZlibDecompressor =
  ## Create a streaming decompressor. encoding must be ceGzip or ceDeflate.
  result = ZlibDecompressor()
  var windowBits: cint
  case encoding
  of ceGzip:
    windowBits = MAX_WBITS + 16  # gzip format
  of ceDeflate:
    windowBits = MAX_WBITS       # zlib format
  else:
    raise newException(CompressionError,
      "ZlibDecompressor only supports gzip/deflate, not " & $encoding)

  let rc = inflateInit2(addr result.strm, windowBits,
                        ZLIB_VERSION, cint(sizeof(ZStream)))
  if rc != Z_OK:
    raise newException(CompressionError, "inflateInit2 failed: " & $rc)
  result.initialized = true

proc decompressChunk*(d: ZlibDecompressor, data: string): string =
  ## Decompress a chunk of compressed data. Returns decompressed bytes.
  if not d.initialized:
    raise newException(CompressionError, "Decompressor not initialized")
  if data.len == 0:
    return ""

  var output = ""
  let chunkSize = data.len * 4 + 256
  var outBuf = newString(chunkSize)

  d.strm.next_in = cast[ptr uint8](unsafeAddr data[0])
  d.strm.avail_in = cuint(data.len)

  while d.strm.avail_in > 0:
    d.strm.next_out = cast[ptr uint8](addr outBuf[0])
    d.strm.avail_out = cuint(chunkSize)

    let rc = inflate(addr d.strm, Z_NO_FLUSH)
    if rc != Z_OK and rc != Z_STREAM_END and rc != Z_BUF_ERROR:
      raise newException(CompressionError, "inflate failed: " & $rc)

    let produced = chunkSize - d.strm.avail_out.int
    if produced > 0:
      output.add outBuf[0 ..< produced]

    if rc == Z_STREAM_END:
      break

  result = output

proc destroy*(d: ZlibDecompressor) =
  if d.initialized:
    discard inflateEnd(addr d.strm)
    d.initialized = false

# ============================================================
# Raw deflate via zlib FFI — for WebSocket permessage-deflate (RFC 7692)
# ============================================================

proc rawDeflateCompress*(data: string, level: CompressionLevel = clDefault): string =
  ## Compress data using raw deflate (no zlib/gzip header), with Z_SYNC_FLUSH,
  ## stripping the trailing 0x00 0x00 0xFF 0xFF as per RFC 7692.
  var strm: ZStream
  let rc = deflateInit2(addr strm, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                        -MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
                        ZLIB_VERSION, cint(sizeof(ZStream)))
  if rc != Z_OK:
    raise newException(CompressionError, "deflateInit2 failed for raw deflate: " & $rc)

  let chunkSize = 16 * 1024
  var outChunk = newString(chunkSize)
  var output = newStringOfCap(data.len + 256)
  strm.next_in = if data.len > 0: cast[ptr uint8](unsafeAddr data[0]) else: nil
  strm.avail_in = cuint(data.len)

  while true:
    strm.next_out = cast[ptr uint8](addr outChunk[0])
    strm.avail_out = cuint(chunkSize)
    let drc = deflate(addr strm, Z_SYNC_FLUSH)
    if drc != Z_OK and drc != Z_BUF_ERROR and drc != Z_STREAM_END:
      discard deflateEnd(addr strm)
      raise newException(CompressionError, "deflate failed for raw deflate: " & $drc)

    let produced = chunkSize - strm.avail_out.int
    if produced > 0:
      output.add outChunk[0 ..< produced]

    # Done when all input has been consumed and the output buffer was not filled.
    if strm.avail_in == 0 and strm.avail_out > 0:
      break

    # No progress indicates a malformed zlib state.
    if produced == 0 and strm.avail_in > 0 and strm.avail_out > 0:
      discard deflateEnd(addr strm)
      raise newException(CompressionError, "deflate made no progress for raw deflate")

  discard deflateEnd(addr strm)

  # Strip trailing 0x00 0x00 0xFF 0xFF per RFC 7692
  if output.len >= 4 and
     output[output.len - 4].byte == 0x00 and output[output.len - 3].byte == 0x00 and
     output[output.len - 2].byte == 0xFF and output[output.len - 1].byte == 0xFF:
    output.setLen(output.len - 4)
  result = output

proc rawDeflateDecompressLimited*(data: string, maxOutputBytes: int = -1): string =
  ## Decompress raw deflate data, appending 0x00 0x00 0xFF 0xFF tail per RFC 7692.
  ## When maxOutputBytes > 0, fails if decompressed output would exceed that limit.
  var withTail = data
  withTail.add '\x00'
  withTail.add '\x00'
  withTail.add '\xFF'
  withTail.add '\xFF'

  var strm: ZStream
  let rc = inflateInit2(addr strm, -MAX_WBITS,
                        ZLIB_VERSION, cint(sizeof(ZStream)))
  if rc != Z_OK:
    raise newException(CompressionError, "inflateInit2 failed for raw deflate: " & $rc)

  let chunkSize = 16 * 1024
  var outChunk = newString(chunkSize)
  var output =
    if maxOutputBytes > 0:
      newStringOfCap(min(maxOutputBytes, chunkSize))
    else:
      newStringOfCap(max(data.len * 2, chunkSize))

  strm.next_in = cast[ptr uint8](unsafeAddr withTail[0])
  strm.avail_in = cuint(withTail.len)

  while true:
    strm.next_out = cast[ptr uint8](addr outChunk[0])
    strm.avail_out = cuint(chunkSize)
    let irc = inflate(addr strm, Z_NO_FLUSH)
    if irc != Z_OK and irc != Z_STREAM_END and irc != Z_BUF_ERROR:
      discard inflateEnd(addr strm)
      raise newException(CompressionError, "inflate failed for raw deflate: " & $irc)

    let produced = chunkSize - strm.avail_out.int
    if produced > 0:
      if maxOutputBytes > 0 and output.len + produced > maxOutputBytes:
        discard inflateEnd(addr strm)
        raise newException(CompressionError, "raw deflate output exceeds configured max size")
      output.add outChunk[0 ..< produced]

    if irc == Z_STREAM_END:
      break

    # For permessage-deflate, a sync-flush terminated block can complete
    # without reaching Z_STREAM_END once all input is consumed.
    if strm.avail_in == 0:
      break

    # If input remains but inflate cannot make progress, the stream is invalid.
    if produced == 0 and strm.avail_out > 0:
      discard inflateEnd(addr strm)
      raise newException(CompressionError, "inflate made no progress for raw deflate")

  discard inflateEnd(addr strm)
  result = output

proc rawDeflateDecompress*(data: string): string =
  rawDeflateDecompressLimited(data, -1)

# ============================================================
# zstd FFI (optional, compile with -d:useZstd)
# ============================================================

when defined(useZstd):
  {.passL: "-lzstd".}

  proc ZSTD_compress(dst: pointer, dstCapacity: csize_t,
                     src: pointer, srcSize: csize_t,
                     compressionLevel: cint): csize_t
    {.importc, header: "<zstd.h>".}

  proc ZSTD_decompress(dst: pointer, dstCapacity: csize_t,
                       src: pointer, compressedSize: csize_t): csize_t
    {.importc, header: "<zstd.h>".}

  proc ZSTD_compressBound(srcSize: csize_t): csize_t
    {.importc, header: "<zstd.h>".}

  proc ZSTD_getFrameContentSize(src: pointer, srcSize: csize_t): culonglong
    {.importc, header: "<zstd.h>".}

  proc ZSTD_isError(code: csize_t): cuint
    {.importc, header: "<zstd.h>".}

  proc ZSTD_getErrorName(code: csize_t): cstring
    {.importc, header: "<zstd.h>".}

  proc zstdCompress*(data: string, level: CompressionLevel = clDefault): string =
    let zLevel: cint = case level
      of clFast: 1
      of clDefault: 3
      of clBest: 19
    let bound = ZSTD_compressBound(csize_t(data.len))
    result = newString(bound.int)
    let rc = ZSTD_compress(addr result[0], bound,
                           unsafeAddr data[0], csize_t(data.len), zLevel)
    if ZSTD_isError(rc) != 0:
      raise newException(CompressionError, "zstd compress failed: " & $ZSTD_getErrorName(rc))
    result.setLen(rc.int)

  proc zstdDecompress*(data: string): string =
    let frameSize = ZSTD_getFrameContentSize(unsafeAddr data[0], csize_t(data.len))
    const ZSTD_CONTENTSIZE_ERROR = high(culonglong)
    const ZSTD_CONTENTSIZE_UNKNOWN = high(culonglong) - 1
    if frameSize == ZSTD_CONTENTSIZE_ERROR:
      raise newException(CompressionError, "zstd: invalid frame content size")
    let dstSize = if frameSize == ZSTD_CONTENTSIZE_UNKNOWN:
                    csize_t(data.len * 4)  # estimate
                  else:
                    csize_t(frameSize)
    result = newString(dstSize.int)
    let rc = ZSTD_decompress(addr result[0], dstSize,
                             unsafeAddr data[0], csize_t(data.len))
    if ZSTD_isError(rc) != 0:
      raise newException(CompressionError, "zstd decompress failed: " & $ZSTD_getErrorName(rc))
    result.setLen(rc.int)

# ============================================================
# brotli FFI (optional, compile with -d:useBrotli)
# ============================================================

when defined(useBrotli):
  {.passL: "-lbrotlienc -lbrotlidec -lbrotlicommon".}

  proc BrotliEncoderCompress(quality: cint, lgwin: cint, mode: cint,
                             input_size: csize_t, input_buffer: ptr uint8,
                             encoded_size: ptr csize_t, encoded_buffer: ptr uint8): cint
    {.importc, header: "<brotli/encode.h>".}

  proc BrotliDecoderDecompress(encoded_size: csize_t, encoded_buffer: ptr uint8,
                               decoded_size: ptr csize_t, decoded_buffer: ptr uint8): cint
    {.importc, header: "<brotli/decode.h>".}

  proc brotliCompress*(data: string, level: CompressionLevel = clDefault): string =
    let quality: cint = case level
      of clFast: 1
      of clDefault: 6
      of clBest: 11
    let maxSize = data.len + (data.len shr 2) + 1024
    result = newString(maxSize)
    var outSize = csize_t(maxSize)
    let rc = BrotliEncoderCompress(quality, 22, 0,
                                   csize_t(data.len),
                                   cast[ptr uint8](unsafeAddr data[0]),
                                   addr outSize,
                                   cast[ptr uint8](addr result[0]))
    if rc == 0:
      raise newException(CompressionError, "brotli compress failed")
    result.setLen(outSize.int)

  proc brotliDecompress*(data: string): string =
    var outSize = csize_t(data.len * 4 + 1024)
    result = newString(outSize.int)
    let rc = BrotliDecoderDecompress(csize_t(data.len),
                                     cast[ptr uint8](unsafeAddr data[0]),
                                     addr outSize,
                                     cast[ptr uint8](addr result[0]))
    if rc == 0:
      raise newException(CompressionError, "brotli decompress failed")
    result.setLen(outSize.int)

# ============================================================
# Unified API
# ============================================================

proc compress*(data: string, encoding: ContentEncoding,
               level: CompressionLevel = clDefault): string =
  case encoding
  of ceGzip: gzipCompress(data, level)
  of ceDeflate: deflateCompress(data, level)
  of ceIdentity: data
  of ceZstd:
    when defined(useZstd):
      zstdCompress(data, level)
    else:
      raise newException(CompressionError, "zstd not compiled in (use -d:useZstd)")
  of ceBrotli:
    when defined(useBrotli):
      brotliCompress(data, level)
    else:
      raise newException(CompressionError, "brotli not compiled in (use -d:useBrotli)")

proc decompress*(data: string, encoding: ContentEncoding): string =
  case encoding
  of ceGzip: gzipDecompress(data)
  of ceDeflate: deflateDecompress(data)
  of ceIdentity: data
  of ceZstd:
    when defined(useZstd):
      zstdDecompress(data)
    else:
      raise newException(CompressionError, "zstd not compiled in (use -d:useZstd)")
  of ceBrotli:
    when defined(useBrotli):
      brotliDecompress(data)
    else:
      raise newException(CompressionError, "brotli not compiled in (use -d:useBrotli)")

# ============================================================
# Header parsing utilities
# ============================================================

proc parseContentEncoding*(header: string): ContentEncoding =
  let h = header.strip().toLowerAscii
  case h
  of "gzip", "x-gzip": ceGzip
  of "deflate": ceDeflate
  of "zstd": ceZstd
  of "br": ceBrotli
  of "identity", "": ceIdentity
  else: ceIdentity

proc parseAcceptEncoding*(header: string): seq[(ContentEncoding, float)] =
  ## Parse Accept-Encoding header into (encoding, quality) pairs.
  ## e.g. "gzip, deflate;q=0.5, br;q=0.9"
  for part in header.split(','):
    let trimmed = part.strip()
    if trimmed.len == 0:
      continue
    let semicolonPos = trimmed.find(';')
    var encName: string
    var quality = 1.0
    if semicolonPos >= 0:
      encName = trimmed[0 ..< semicolonPos].strip()
      let qualPart = trimmed[semicolonPos + 1 .. ^1].strip()
      if qualPart.startsWith("q="):
        try:
          quality = parseFloat(qualPart[2 .. ^1])
        except ValueError:
          quality = 1.0
    else:
      encName = trimmed
    let enc = parseContentEncoding(encName)
    if enc != ceIdentity or encName.toLowerAscii == "identity":
      result.add (enc, quality)

proc bestEncoding*(accepted: seq[(ContentEncoding, float)]): ContentEncoding =
  ## Pick the best encoding from what the client accepts and what's compiled in.
  ## Priority: brotli > zstd > gzip > deflate > identity
  var best = ceIdentity
  var bestQ = 0.0

  for (enc, q) in accepted:
    if q <= 0:
      continue
    # Skip encodings not compiled in
    case enc
    of ceZstd:
      when not defined(useZstd):
        continue
    of ceBrotli:
      when not defined(useBrotli):
        continue
    else:
      discard

    # Prefer higher quality, then higher priority encoding
    let priority = case enc
      of ceBrotli: 4
      of ceZstd: 3
      of ceGzip: 2
      of ceDeflate: 1
      of ceIdentity: 0
    if q > bestQ or (q == bestQ and priority > (case best
      of ceBrotli: 4
      of ceZstd: 3
      of ceGzip: 2
      of ceDeflate: 1
      of ceIdentity: 0)):
      best = enc
      bestQ = q

  result = best

proc buildAcceptEncoding*(): string =
  ## Build Accept-Encoding header value based on compiled-in codecs.
  var parts: seq[string]
  parts.add "gzip"
  parts.add "deflate"
  when defined(useBrotli):
    parts.add "br"
  when defined(useZstd):
    parts.add "zstd"
  result = parts.join(", ")

proc encodingName*(enc: ContentEncoding): string =
  case enc
  of ceGzip: "gzip"
  of ceDeflate: "deflate"
  of ceZstd: "zstd"
  of ceBrotli: "br"
  of ceIdentity: "identity"

proc isCompressible*(contentType: string): bool =
  ## Returns true if the content type is compressible (text, JSON, XML, etc.).
  let ct = contentType.toLowerAscii
  if ct.startsWith("text/"):
    return true
  if ct.startsWith("application/json") or
     ct.startsWith("application/xml") or
     ct.startsWith("application/javascript") or
     ct.startsWith("application/wasm") or
     ct.startsWith("application/x-www-form-urlencoded") or
     ct.startsWith("image/svg+xml"):
    return true
  return false

# ============================================================
# DecompressedStream — wraps an AsyncStream with streaming decompression
# ============================================================

type
  DecompressedStream* = ref object of AsyncStream
    underlying*: AsyncStream
    decompressor*: ZlibDecompressor

proc decompressedStreamRead(s: AsyncStream, size: int): CpsFuture[string] =
  let ds = DecompressedStream(s)
  let fut = newCpsFuture[string]()
  let readFut = ds.underlying.read(size)
  let capturedDs = ds
  readFut.addCallback(proc() =
    if readFut.hasError():
      fut.fail(readFut.getError())
    else:
      let compressed = readFut.read()
      if compressed.len == 0:
        fut.complete("")  # EOF
      else:
        try:
          let decompressed = capturedDs.decompressor.decompressChunk(compressed)
          fut.complete(decompressed)
        except CompressionError as e:
          fut.fail(e)
  )
  return fut

proc decompressedStreamClose(s: AsyncStream) =
  let ds = DecompressedStream(s)
  ds.decompressor.destroy()
  ds.underlying.close()

proc newDecompressedStream*(underlying: AsyncStream,
                            encoding: ContentEncoding = ceGzip): DecompressedStream =
  ## Create a read-only stream that transparently decompresses data
  ## from the underlying stream.
  result = DecompressedStream(
    underlying: underlying,
    decompressor: newZlibDecompressor(encoding)
  )
  result.readProc = decompressedStreamRead
  result.writeProc = nil  # read-only
  result.closeProc = decompressedStreamClose

# ============================================================
# PrefixedStream — serves a prefix buffer then delegates to underlying
# ============================================================

type
  PrefixedStream* = ref object of AsyncStream
    prefix: string
    prefixPos: int
    underlying: AsyncStream

proc prefixedStreamRead(s: AsyncStream, size: int): CpsFuture[string] =
  let ps = PrefixedStream(s)
  let remaining = ps.prefix.len - ps.prefixPos
  if remaining > 0:
    # Serve from prefix buffer
    let toRead = min(size, remaining)
    let data = ps.prefix[ps.prefixPos ..< ps.prefixPos + toRead]
    ps.prefixPos += toRead
    let fut = newCpsFuture[string]()
    fut.complete(data)
    return fut
  else:
    # Prefix exhausted, delegate to underlying stream
    return ps.underlying.read(size)

proc prefixedStreamWrite(s: AsyncStream, data: string): CpsVoidFuture =
  let ps = PrefixedStream(s)
  return ps.underlying.write(data)

proc prefixedStreamClose(s: AsyncStream) =
  let ps = PrefixedStream(s)
  ps.underlying.close()

proc newPrefixedStream*(prefix: string, underlying: AsyncStream): PrefixedStream =
  ## Create a stream that first serves `prefix` bytes, then reads from `underlying`.
  ## Useful when a BufferedReader has consumed extra data from a stream and you need
  ## to re-inject it before wrapping with another stream layer.
  result = PrefixedStream(
    prefix: prefix,
    prefixPos: 0,
    underlying: underlying
  )
  result.readProc = prefixedStreamRead
  result.writeProc = prefixedStreamWrite
  result.closeProc = prefixedStreamClose

# ============================================================
# ChunkedDecompressedStream — HTTP chunked transfer + decompression
# ============================================================

type
  ChunkedDecompressedStream* = ref object of AsyncStream
    underlying*: AsyncStream
    decompressor*: ZlibDecompressor
    chunkBuf: string      ## buffered data from current chunk
    chunkRemain: int      ## remaining bytes in current chunk
    needChunkHeader: bool ## true when we need to read the next chunk header
    eof: bool

proc parseChunkSize(line: string): int =
  ## Parse hex chunk size from a chunk header line.
  var s = line.strip()
  # Strip any chunk extensions after semicolon
  let semiPos = s.find(';')
  if semiPos >= 0:
    s = s[0 ..< semiPos]
  try:
    result = parseHexInt(s)
  except ValueError:
    result = 0

proc chunkedDecompressedStreamRead(s: AsyncStream, size: int): CpsFuture[string] =
  let cds = ChunkedDecompressedStream(s)
  let fut = newCpsFuture[string]()

  if cds.eof:
    fut.complete("")
    return fut

  # Read raw data from chunked stream then decompress
  let readFut = cds.underlying.read(size)
  let capturedCds = cds
  readFut.addCallback(proc() =
    if readFut.hasError():
      fut.fail(readFut.getError())
      return

    let raw = readFut.read()
    if raw.len == 0:
      capturedCds.eof = true
      fut.complete("")
      return

    # Feed all data through decompressor
    # The chunked framing is transparent to decompression — the zlib
    # decompressor handles the gzip stream boundaries correctly even
    # with chunk framing mixed in. We just need to strip chunk headers/trailers.
    # For simplicity, collect all data and feed to decompressor.
    capturedCds.chunkBuf.add raw

    # Parse and extract chunk data
    var output = ""
    while capturedCds.chunkBuf.len > 0:
      if capturedCds.needChunkHeader:
        # Look for \r\n to get chunk size
        let crlfPos = capturedCds.chunkBuf.find("\r\n")
        if crlfPos < 0:
          break  # Need more data
        let sizeStr = capturedCds.chunkBuf[0 ..< crlfPos]
        capturedCds.chunkBuf = capturedCds.chunkBuf[crlfPos + 2 .. ^1]
        capturedCds.chunkRemain = parseChunkSize(sizeStr)
        if capturedCds.chunkRemain == 0:
          capturedCds.eof = true
          break
        capturedCds.needChunkHeader = false
      else:
        # Read chunk data
        let toRead = min(capturedCds.chunkRemain, capturedCds.chunkBuf.len)
        if toRead > 0:
          output.add capturedCds.chunkBuf[0 ..< toRead]
          capturedCds.chunkBuf = capturedCds.chunkBuf[toRead .. ^1]
          capturedCds.chunkRemain -= toRead
        if capturedCds.chunkRemain == 0:
          # Skip trailing \r\n after chunk data
          if capturedCds.chunkBuf.len >= 2 and
             capturedCds.chunkBuf[0] == '\r' and capturedCds.chunkBuf[1] == '\n':
            capturedCds.chunkBuf = capturedCds.chunkBuf[2 .. ^1]
          capturedCds.needChunkHeader = true
        else:
          break  # Need more data

    if output.len > 0:
      try:
        let decompressed = capturedCds.decompressor.decompressChunk(output)
        fut.complete(decompressed)
      except CompressionError as e:
        fut.fail(e)
    else:
      fut.complete("")
  )
  return fut

proc chunkedDecompressedStreamClose(s: AsyncStream) =
  let cds = ChunkedDecompressedStream(s)
  cds.decompressor.destroy()
  cds.underlying.close()

proc newChunkedDecompressedStream*(underlying: AsyncStream,
                                   encoding: ContentEncoding = ceGzip): ChunkedDecompressedStream =
  ## Create a read-only stream that decodes HTTP chunked transfer encoding
  ## and then decompresses the payload.
  result = ChunkedDecompressedStream(
    underlying: underlying,
    decompressor: newZlibDecompressor(encoding),
    chunkBuf: "",
    chunkRemain: 0,
    needChunkHeader: true,
    eof: false
  )
  result.readProc = chunkedDecompressedStreamRead
  result.writeProc = nil  # read-only
  result.closeProc = chunkedDecompressedStreamClose
