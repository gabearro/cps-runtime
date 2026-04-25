## Tests for BEP 48: Tracker Scrape.

import std/[tables, strutils]
import cps/bittorrent/tracker
import cps/bittorrent/bencode
import cps/bittorrent/sha1

proc testAnnounceToScrapeUrl() =
  assert announceToScrapeUrl("http://tracker.example.com/announce") ==
    "http://tracker.example.com/scrape"
  assert announceToScrapeUrl("http://tracker.example.com/x/announce") ==
    "http://tracker.example.com/x/scrape"
  assert announceToScrapeUrl("http://tracker.example.com/announce.php") ==
    "http://tracker.example.com/scrape.php"
  assert announceToScrapeUrl("http://tracker.example.com/a/announce?x=1") ==
    "http://tracker.example.com/a/scrape?x=1"
  # Multiple occurrences: replace last one
  assert announceToScrapeUrl("http://announce.example.com/announce") ==
    "http://announce.example.com/scrape"
  echo "PASS: announce to scrape URL derivation"

proc testAnnounceToScrapeUrlInvalid() =
  var caught = false
  try:
    discard announceToScrapeUrl("http://tracker.example.com/track")
  except TrackerError:
    caught = true
  assert caught, "should fail when no 'announce' in URL"
  echo "PASS: scrape URL derivation rejects invalid URLs"

proc testParseScrapeResponse() =
  let ih = sha1("test info hash data")
  var ihStr = newString(20)
  copyMem(addr ihStr[0], unsafeAddr ih[0], 20)

  # Build a valid scrape response
  var files = initTable[string, BencodeValue]()
  var entry = initTable[string, BencodeValue]()
  entry["complete"] = bInt(42)
  entry["incomplete"] = bInt(10)
  entry["downloaded"] = bInt(1337)
  files[ihStr] = bDict(entry)
  var root = initTable[string, BencodeValue]()
  root["files"] = bDict(files)
  let data = encode(bDict(root))

  let info = parseScrapeResponse(data, ih)
  assert info.complete == 42
  assert info.incomplete == 10
  assert info.downloaded == 1337
  echo "PASS: parse scrape response"

proc testParseCompactPeers6() =
  # Build a fake compact IPv6 peer (18 bytes: 16 IP + 2 port)
  var data = newString(18)
  # IPv6 ::1 = 0000:0000:0000:0000:0000:0000:0000:0001
  data[14] = char(0)
  data[15] = char(1)
  # Port 6881
  data[16] = char((6881 shr 8).byte)
  data[17] = char((6881 and 0xFF).byte)
  let peers = parseCompactPeers6(data)
  assert peers.len == 1
  assert peers[0].port == 6881
  # IP should end with :0001
  assert peers[0].ip.endsWith(":0001")
  echo "PASS: parse compact IPv6 peers"

testAnnounceToScrapeUrl()
testAnnounceToScrapeUrlInvalid()
testParseScrapeResponse()
testParseCompactPeers6()

echo ""
echo "All scrape tests passed!"
