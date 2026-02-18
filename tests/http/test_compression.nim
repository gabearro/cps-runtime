## Tests for HTTP compression module

import std/strutils
import cps/http/shared/compression

# ============================================================
# Gzip roundtrip
# ============================================================

block:
  let original = "Hello, World! This is a test of gzip compression."
  let compressed = gzipCompress(original)
  assert compressed != original
  assert compressed.len > 0
  let decompressed = gzipDecompress(compressed)
  assert decompressed == original
  echo "PASS: gzip roundtrip"

block:
  let original = ""
  let compressed = gzipCompress(original)
  let decompressed = gzipDecompress(compressed)
  assert decompressed == original
  echo "PASS: gzip empty string"

# ============================================================
# Deflate roundtrip
# ============================================================

block:
  let original = "Hello, World! This is a test of deflate compression."
  let compressed = deflateCompress(original)
  assert compressed != original
  let decompressed = deflateDecompress(compressed)
  assert decompressed == original
  echo "PASS: deflate roundtrip"

block:
  let original = ""
  let compressed = deflateCompress(original)
  let decompressed = deflateDecompress(compressed)
  assert decompressed == original
  echo "PASS: deflate empty string"

# ============================================================
# Raw deflate roundtrip (WebSocket permessage-deflate)
# ============================================================

block:
  let original = "Hello, WebSocket permessage-deflate!"
  let compressed = rawDeflateCompress(original)
  assert compressed.len > 0
  let decompressed = rawDeflateDecompress(compressed)
  assert decompressed == original
  echo "PASS: raw deflate roundtrip"

block:
  let original = ""
  let compressed = rawDeflateCompress(original)
  let decompressed = rawDeflateDecompress(compressed)
  assert decompressed == original
  echo "PASS: raw deflate empty string"

# ============================================================
# Unified compress/decompress API
# ============================================================

block:
  let original = "Testing unified API with gzip"
  let compressed = compress(original, ceGzip)
  let decompressed = decompress(compressed, ceGzip)
  assert decompressed == original
  echo "PASS: unified API gzip"

block:
  let original = "Testing unified API with deflate"
  let compressed = compress(original, ceDeflate)
  let decompressed = decompress(compressed, ceDeflate)
  assert decompressed == original
  echo "PASS: unified API deflate"

block:
  let original = "Identity should pass through"
  let compressed = compress(original, ceIdentity)
  assert compressed == original
  let decompressed = decompress(compressed, ceIdentity)
  assert decompressed == original
  echo "PASS: unified API identity"

# ============================================================
# Compression levels
# ============================================================

block:
  let original = "A" & "B".repeat(1000) & "C".repeat(1000)
  let fast = gzipCompress(original, clFast)
  let best = gzipCompress(original, clBest)
  let defaultLevel = gzipCompress(original, clDefault)
  # All should decompress to the same thing
  assert gzipDecompress(fast) == original
  assert gzipDecompress(best) == original
  assert gzipDecompress(defaultLevel) == original
  # All levels produce valid output; sizes may vary
  echo "PASS: compression levels (fast=" & $fast.len & " default=" & $defaultLevel.len & " best=" & $best.len & ")"

# ============================================================
# Large payload
# ============================================================

block:
  var large = ""
  for i in 0 ..< 10000:
    large.add "Line " & $i & ": some repetitive data for compression testing\n"
  let compressed = gzipCompress(large)
  # Should achieve meaningful compression on repetitive data
  assert compressed.len < large.len div 2
  let decompressed = gzipDecompress(compressed)
  assert decompressed == large
  echo "PASS: large payload (original=" & $large.len & " compressed=" & $compressed.len & ")"

# ============================================================
# Invalid data -> CompressionError
# ============================================================

block:
  var caught = false
  try:
    discard gzipDecompress("this is not valid gzip data")
  except CompressionError:
    caught = true
  assert caught
  echo "PASS: invalid gzip data raises CompressionError"

block:
  var caught = false
  try:
    discard deflateDecompress("this is not valid deflate data")
  except CompressionError:
    caught = true
  assert caught
  echo "PASS: invalid deflate data raises CompressionError"

# ============================================================
# Streaming compressor/decompressor roundtrip
# ============================================================

block:
  let comp = newZlibCompressor(ceGzip)
  let decomp = newZlibDecompressor(ceGzip)

  let chunks = @["Hello, ", "World! ", "This is ", "streaming ", "compression."]
  var allCompressed = ""
  for chunk in chunks:
    allCompressed.add comp.compressChunk(chunk)
  allCompressed.add comp.finish()

  let decompressed = decomp.decompressChunk(allCompressed)
  assert decompressed == chunks.join("")
  comp.destroy()
  decomp.destroy()
  echo "PASS: streaming compressor/decompressor roundtrip"

block:
  # Test chunk-by-chunk decompression (simulating SSE)
  let comp = newZlibCompressor(ceGzip)
  let decomp = newZlibDecompressor(ceGzip)

  let events = @[
    "data: event1\n\n",
    "data: event2\n\n",
    "data: event3\n\n"
  ]

  var decompressedAll = ""
  for event in events:
    let compressed = comp.compressChunk(event)
    let decompressed = decomp.decompressChunk(compressed)
    decompressedAll.add decompressed

  let finalBytes = comp.finish()
  if finalBytes.len > 0:
    decompressedAll.add decomp.decompressChunk(finalBytes)

  assert decompressedAll == events.join("")
  comp.destroy()
  decomp.destroy()
  echo "PASS: streaming chunk-by-chunk decompression"

# ============================================================
# parseContentEncoding
# ============================================================

block:
  assert parseContentEncoding("gzip") == ceGzip
  assert parseContentEncoding("GZIP") == ceGzip
  assert parseContentEncoding("x-gzip") == ceGzip
  assert parseContentEncoding("deflate") == ceDeflate
  assert parseContentEncoding("br") == ceBrotli
  assert parseContentEncoding("zstd") == ceZstd
  assert parseContentEncoding("identity") == ceIdentity
  assert parseContentEncoding("") == ceIdentity
  assert parseContentEncoding("  gzip  ") == ceGzip
  echo "PASS: parseContentEncoding"

# ============================================================
# parseAcceptEncoding
# ============================================================

block:
  let result = parseAcceptEncoding("gzip, deflate, br")
  assert result.len == 3
  assert result[0] == (ceGzip, 1.0)
  assert result[1] == (ceDeflate, 1.0)
  assert result[2] == (ceBrotli, 1.0)
  echo "PASS: parseAcceptEncoding simple"

block:
  let result = parseAcceptEncoding("gzip;q=0.8, deflate;q=0.5, br;q=1.0")
  assert result.len == 3
  assert result[0] == (ceGzip, 0.8)
  assert result[1] == (ceDeflate, 0.5)
  assert result[2] == (ceBrotli, 1.0)
  echo "PASS: parseAcceptEncoding with quality values"

block:
  let result = parseAcceptEncoding("")
  assert result.len == 0
  echo "PASS: parseAcceptEncoding empty"

# ============================================================
# bestEncoding
# ============================================================

block:
  let accepted = @[(ceGzip, 1.0), (ceDeflate, 0.5)]
  assert bestEncoding(accepted) == ceGzip
  echo "PASS: bestEncoding gzip preferred"

block:
  let accepted = @[(ceGzip, 0.5), (ceDeflate, 1.0)]
  assert bestEncoding(accepted) == ceDeflate
  echo "PASS: bestEncoding deflate higher quality"

block:
  let accepted = @[(ceGzip, 1.0), (ceDeflate, 1.0)]
  assert bestEncoding(accepted) == ceGzip  # gzip has higher priority
  echo "PASS: bestEncoding equal quality prefers gzip"

block:
  let accepted: seq[(ContentEncoding, float)] = @[]
  assert bestEncoding(accepted) == ceIdentity
  echo "PASS: bestEncoding empty returns identity"

# ============================================================
# buildAcceptEncoding
# ============================================================

block:
  let ae = buildAcceptEncoding()
  assert "gzip" in ae
  assert "deflate" in ae
  echo "PASS: buildAcceptEncoding"

# ============================================================
# encodingName
# ============================================================

block:
  assert encodingName(ceGzip) == "gzip"
  assert encodingName(ceDeflate) == "deflate"
  assert encodingName(ceZstd) == "zstd"
  assert encodingName(ceBrotli) == "br"
  assert encodingName(ceIdentity) == "identity"
  echo "PASS: encodingName"

# ============================================================
# isCompressible
# ============================================================

block:
  assert isCompressible("text/html")
  assert isCompressible("text/plain; charset=utf-8")
  assert isCompressible("text/css")
  assert isCompressible("application/json")
  assert isCompressible("application/javascript")
  assert isCompressible("application/xml")
  assert isCompressible("image/svg+xml")
  assert not isCompressible("image/png")
  assert not isCompressible("image/jpeg")
  assert not isCompressible("application/octet-stream")
  assert not isCompressible("application/zip")
  echo "PASS: isCompressible"

# ============================================================
# Conditional zstd/brotli
# ============================================================

when defined(useZstd):
  block:
    let original = "Hello, zstd!"
    let compressed = zstdCompress(original)
    let decompressed = zstdDecompress(compressed)
    assert decompressed == original
    echo "PASS: zstd roundtrip"

  block:
    let original = "unified zstd test"
    let compressed = compress(original, ceZstd)
    let decompressed = decompress(compressed, ceZstd)
    assert decompressed == original
    echo "PASS: unified API zstd"

when defined(useBrotli):
  block:
    let original = "Hello, brotli!"
    let compressed = brotliCompress(original)
    let decompressed = brotliDecompress(compressed)
    assert decompressed == original
    echo "PASS: brotli roundtrip"

  block:
    let original = "unified brotli test"
    let compressed = compress(original, ceBrotli)
    let decompressed = decompress(compressed, ceBrotli)
    assert decompressed == original
    echo "PASS: unified API brotli"

echo "ALL COMPRESSION TESTS PASSED"
