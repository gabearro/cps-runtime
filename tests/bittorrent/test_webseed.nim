## Tests for BEP 19: HTTP/FTP Seeding (GetRight-style).

import std/strutils
import cps/bittorrent/webseed
import cps/bittorrent/metainfo

block test_build_range_url_single_file:
  var info: TorrentInfo
  info.pieceLength = 262144  # 256 KiB
  info.totalLength = 1048576  # 1 MiB
  info.files = @[FileEntry(path: "test.dat", length: 1048576)]
  info.pieces = newString(info.totalLength div info.pieceLength * 20)

  let (url, rangeStart, rangeEnd) = buildRangeUrl(
    "http://example.com/test.dat", info, 0, 0, 16384)
  assert url == "http://example.com/test.dat"
  assert rangeStart == 0
  assert rangeEnd == 16383
  echo "PASS: buildRangeUrl single file first piece"

block test_build_range_url_single_file_offset:
  var info: TorrentInfo
  info.pieceLength = 262144
  info.totalLength = 1048576
  info.files = @[FileEntry(path: "test.dat", length: 1048576)]
  info.pieces = newString(info.totalLength div info.pieceLength * 20)

  let (url, rangeStart, rangeEnd) = buildRangeUrl(
    "http://example.com/test.dat", info, 2, 1000, 5000)
  # globalStart = 2 * 262144 + 1000 = 525288
  assert url == "http://example.com/test.dat"
  assert rangeStart == 525288
  assert rangeEnd == 525288 + 4999
  echo "PASS: buildRangeUrl single file with offset"

block test_build_range_url_single_file_directory_base:
  ## Some BEP 19 single-file torrents publish directory URLs in url-list.
  var info: TorrentInfo
  info.pieceLength = 262144
  info.totalLength = 1048576
  info.files = @[FileEntry(path: "archlinux-2026.03.01-x86_64.iso", length: 1048576)]
  info.pieces = newString(info.totalLength div info.pieceLength * 20)

  let (url, rangeStart, rangeEnd) = buildRangeUrl(
    "https://mirror.example/iso/2026.03.01/", info, 0, 0, 4096)
  assert url == "https://mirror.example/iso/2026.03.01/archlinux-2026.03.01-x86_64.iso"
  assert rangeStart == 0
  assert rangeEnd == 4095
  echo "PASS: buildRangeUrl single file directory base"

block test_build_range_url_single_file_root_base:
  ## Host-only base URLs should map to /<filename> for single-file torrents.
  var info: TorrentInfo
  info.pieceLength = 262144
  info.totalLength = 1048576
  info.files = @[FileEntry(path: "test.dat", length: 1048576)]
  info.pieces = newString(info.totalLength div info.pieceLength * 20)

  let (url, _, _) = buildRangeUrl("https://mirror.example", info, 0, 0, 1024)
  assert url == "https://mirror.example/test.dat"
  echo "PASS: buildRangeUrl single file root base"

block test_build_range_url_multi_file_first:
  var info: TorrentInfo
  info.pieceLength = 262144
  info.files = @[
    FileEntry(path: "dir/file1.txt", length: 300000),
    FileEntry(path: "dir/file2.txt", length: 500000),
    FileEntry(path: "dir/file3.txt", length: 200000),
  ]
  info.totalLength = 1000000
  info.pieces = newString(info.totalLength div info.pieceLength * 20 + 20)

  # Request in first file
  let (url, rangeStart, rangeEnd) = buildRangeUrl(
    "http://example.com/dir", info, 0, 0, 1000)
  assert url == "http://example.com/dir/dir/file1.txt"
  assert rangeStart == 0
  assert rangeEnd == 999
  echo "PASS: buildRangeUrl multi-file first file"

block test_build_range_url_multi_file_second:
  var info: TorrentInfo
  info.pieceLength = 262144
  info.files = @[
    FileEntry(path: "file1.txt", length: 300000),
    FileEntry(path: "file2.txt", length: 500000),
  ]
  info.totalLength = 800000
  info.pieces = newString(info.totalLength div info.pieceLength * 20 + 20)

  # Request starting in second file
  # globalStart = 1 * 262144 + 100000 = 362144
  # 362144 >= 300000 (file1 ends) → in file2
  let (url, rangeStart, rangeEnd) = buildRangeUrl(
    "http://example.com/", info, 1, 100000, 1000)
  assert url == "http://example.com/file2.txt"
  assert rangeStart == 362144 - 300000  # = 62144, offset within file2
  assert rangeEnd == rangeStart + 999
  echo "PASS: buildRangeUrl multi-file second file"

block test_build_range_url_trailing_slash:
  # Multi-file torrent to test trailing slash on base URL
  var info: TorrentInfo
  info.pieceLength = 262144
  info.files = @[
    FileEntry(path: "data.bin", length: 300000),
    FileEntry(path: "extra.bin", length: 200000),
  ]
  info.totalLength = 500000
  info.pieces = newString(info.totalLength div info.pieceLength * 20 + 20)

  # URL with trailing slash
  let (url1, _, _) = buildRangeUrl("http://example.com/dir/", info, 0, 0, 100)
  assert url1 == "http://example.com/dir/data.bin"

  # URL without trailing slash
  let (url2, _, _) = buildRangeUrl("http://example.com/dir", info, 0, 0, 100)
  assert url2 == "http://example.com/dir/data.bin"
  echo "PASS: buildRangeUrl trailing slash handling"

block test_build_range_url_out_of_bounds:
  # Multi-file torrent - range past all files should raise
  var info: TorrentInfo
  info.pieceLength = 100
  info.files = @[
    FileEntry(path: "a.dat", length: 50),
    FileEntry(path: "b.dat", length: 50),
  ]
  info.totalLength = 100
  info.pieces = newString(20)

  var caught = false
  try:
    discard buildRangeUrl("http://example.com", info, 10, 0, 100)
  except WebSeedError:
    caught = true
  assert caught, "should raise for out-of-bounds range"
  echo "PASS: buildRangeUrl out of bounds"

block test_build_piece_ranges_spans_files:
  ## Piece ranges should fully cover pieces that cross multi-file boundaries.
  var info: TorrentInfo
  info.pieceLength = 16
  info.files = @[
    FileEntry(path: "a.bin", length: 10),
    FileEntry(path: "b.bin", length: 10),
  ]
  info.totalLength = 20
  info.pieces = newString(40)  # 2 pieces

  let ranges = buildPieceRanges("http://example.com/root", info, 0, 16, maxChunk = 8)
  assert ranges.len == 3
  assert ranges[0].url == "http://example.com/root/a.bin"
  assert ranges[0].rangeStart == 0
  assert ranges[0].rangeEnd == 7
  assert ranges[0].pieceOffset == 0

  # Boundary split in file1 (only 2 bytes remain there).
  assert ranges[1].url == "http://example.com/root/a.bin"
  assert ranges[1].rangeStart == 8
  assert ranges[1].rangeEnd == 9
  assert ranges[1].pieceOffset == 8

  # Remaining bytes from file2.
  assert ranges[2].url == "http://example.com/root/b.bin"
  assert ranges[2].rangeStart == 0
  assert ranges[2].rangeEnd == 5
  assert ranges[2].pieceOffset == 10

  var covered = 0
  for rr in ranges:
    covered += int(rr.rangeEnd - rr.rangeStart + 1)
  assert covered == 16
  echo "PASS: buildPieceRanges spans files"

block test_build_piece_ranges_single_file_chunks:
  var info: TorrentInfo
  info.pieceLength = 32
  info.files = @[FileEntry(path: "one.bin", length: 64)]
  info.totalLength = 64
  info.pieces = newString(40)

  let ranges = buildPieceRanges("http://example.com/one.bin", info, 1, 32, maxChunk = 10)
  assert ranges.len == 4
  assert ranges[0].rangeStart == 32 and ranges[0].rangeEnd == 41 and ranges[0].pieceOffset == 0
  assert ranges[1].rangeStart == 42 and ranges[1].rangeEnd == 51 and ranges[1].pieceOffset == 10
  assert ranges[2].rangeStart == 52 and ranges[2].rangeEnd == 61 and ranges[2].pieceOffset == 20
  assert ranges[3].rangeStart == 62 and ranges[3].rangeEnd == 63 and ranges[3].pieceOffset == 30
  echo "PASS: buildPieceRanges single-file chunks"

block test_multi_file_url_encoding:
  ## Multi-file paths with special chars should be URL-encoded
  var info: TorrentInfo
  info.pieceLength = 262144
  info.files = @[
    FileEntry(path: "my album/track 01.mp3", length: 500000),
    FileEntry(path: "my album/track 02.mp3", length: 500000),
  ]
  info.totalLength = 1000000
  info.pieces = newString(info.totalLength div info.pieceLength * 20 + 20)

  let (url, _, _) = buildRangeUrl("http://example.com/music", info, 0, 0, 1000)
  # Path should be URL-encoded (spaces → %20), NOT contain raw spaces
  assert "track 01" notin url, "multi-file URL should not contain raw spaces, got: " & url
  assert "track%2001" in url or "track+01" in url,
    "multi-file URL should be percent-encoded, got: " & url
  echo "PASS: multi-file URL encoding"

block test_new_web_seed:
  let ws = newWebSeed("http://example.com/file.torrent")
  assert ws.url == "http://example.com/file.torrent"
  assert ws.state == wssIdle
  assert ws.failCount == 0
  echo "PASS: newWebSeed"

block test_parse_web_seeds:
  var meta: TorrentMetainfo
  meta.urlList = @["http://seed1.com/file", "http://seed2.com/file"]
  let urls = parseWebSeeds(meta)
  assert urls.len == 2
  assert urls[0] == "http://seed1.com/file"
  assert urls[1] == "http://seed2.com/file"
  echo "PASS: parseWebSeeds"

echo "All webseed tests passed!"
