## Tests for tracker protocol: URL building, response parsing, compact peers,
## UDP protocol packet encoding/decoding (BEP 15).

import std/[strutils, tables]
import cps/bittorrent/tracker
import cps/bittorrent/utils
import cps/bittorrent/metainfo
import cps/bittorrent/peer_protocol
import cps/bittorrent/bencode

# === Compact peer parsing ===

block test_parse_compact_peers_basic:
  ## Parse compact peer format (6 bytes: 4 IP + 2 port).
  var data = ""
  # Peer: 192.168.1.1:6881
  data.add(char(192)); data.add(char(168)); data.add(char(1)); data.add(char(1))
  data.add(char(0x1A'u8)); data.add(char(0xE1'u8))  # 6881 = 0x1AE1
  # Peer: 10.0.0.1:51413
  data.add(char(10)); data.add(char(0)); data.add(char(0)); data.add(char(1))
  data.add(char(0xC8'u8)); data.add(char(0xD5'u8))  # 51413 = 0xC8D5

  let peers = parseCompactPeers(data)
  assert peers.len == 2
  assert peers[0].ip == "192.168.1.1"
  assert peers[0].port == 6881
  assert peers[1].ip == "10.0.0.1"
  assert peers[1].port == 51413
  echo "PASS: parse compact peers basic"

block test_parse_compact_peers_empty:
  let peers = parseCompactPeers("")
  assert peers.len == 0
  echo "PASS: parse compact peers empty"

block test_parse_compact_peers_not_multiple_of_6:
  var caught = false
  try:
    discard parseCompactPeers("12345")  # 5 bytes, not multiple of 6
  except TrackerError:
    caught = true
  assert caught, "should reject non-multiple-of-6 data"
  echo "PASS: parse compact peers not multiple of 6"

block test_parse_compact_peers_all_zeros:
  var data = newString(6)
  for i in 0 ..< 6: data[i] = char(0)
  let peers = parseCompactPeers(data)
  assert peers.len == 1
  assert peers[0].ip == "0.0.0.0"
  assert peers[0].port == 0
  echo "PASS: parse compact peers all zeros"

block test_parse_compact_peers_max_values:
  var data = newString(6)
  for i in 0 ..< 6: data[i] = char(255)
  let peers = parseCompactPeers(data)
  assert peers.len == 1
  assert peers[0].ip == "255.255.255.255"
  assert peers[0].port == 65535
  echo "PASS: parse compact peers max values"

# === Dictionary peer parsing ===

block test_parse_dict_peers:
  ## Parse dictionary peer format.
  var peers = BencodeValue(kind: bkList, listVal: @[])
  var peer1 = initTable[string, BencodeValue]()
  peer1["ip"] = bStr("192.168.1.1")
  peer1["port"] = bInt(6881)
  var peerIdStr = newString(20)
  for i in 0 ..< 20: peerIdStr[i] = char(i)
  peer1["peer id"] = bStr(peerIdStr)
  peers.listVal.add(bDict(peer1))

  var peer2 = initTable[string, BencodeValue]()
  peer2["ip"] = bStr("10.0.0.1")
  peer2["port"] = bInt(51413)
  peers.listVal.add(bDict(peer2))

  let parsed = parseDictPeers(peers)
  assert parsed.len == 2
  assert parsed[0].ip == "192.168.1.1"
  assert parsed[0].port == 6881
  assert parsed[0].peerId[0] == 0
  assert parsed[0].peerId[19] == 19
  assert parsed[1].ip == "10.0.0.1"
  assert parsed[1].port == 51413
  echo "PASS: parse dict peers"

block test_parse_dict_peers_empty_list:
  let peers = BencodeValue(kind: bkList, listVal: @[])
  let parsed = parseDictPeers(peers)
  assert parsed.len == 0
  echo "PASS: parse dict peers empty list"

block test_parse_dict_peers_skips_non_dict:
  var peers = BencodeValue(kind: bkList, listVal: @[
    bStr("not a dict"),
    bInt(42)
  ])
  let parsed = parseDictPeers(peers)
  assert parsed.len == 0
  echo "PASS: parse dict peers skips non-dict"

# === Tracker response parsing ===

block test_parse_tracker_response_compact:
  ## Parse a tracker response with compact peers.
  var d = initTable[string, BencodeValue]()
  d["interval"] = bInt(1800)
  d["min interval"] = bInt(900)
  d["tracker id"] = bStr("tracker123")
  d["complete"] = bInt(150)
  d["incomplete"] = bInt(20)

  # Compact peer data for 192.168.1.1:6881
  var peerData = ""
  peerData.add(char(192)); peerData.add(char(168))
  peerData.add(char(1)); peerData.add(char(1))
  peerData.add(char(0x1A'u8)); peerData.add(char(0xE1'u8))
  d["peers"] = bStr(peerData)

  let encoded = encode(bDict(d))
  let resp = parseTrackerResponse(encoded)
  assert resp.interval == 1800
  assert resp.minInterval == 900
  assert resp.trackerId == "tracker123"
  assert resp.complete == 150
  assert resp.incomplete == 20
  assert resp.peers.len == 1
  assert resp.peers[0].ip == "192.168.1.1"
  assert resp.peers[0].port == 6881
  assert resp.failureReason == ""
  echo "PASS: parse tracker response compact"

block test_parse_tracker_response_dict_peers:
  ## Parse a tracker response with dictionary peers.
  var d = initTable[string, BencodeValue]()
  d["interval"] = bInt(1800)
  d["complete"] = bInt(50)
  d["incomplete"] = bInt(5)

  var peerList = BencodeValue(kind: bkList, listVal: @[])
  var peer1 = initTable[string, BencodeValue]()
  peer1["ip"] = bStr("10.0.0.1")
  peer1["port"] = bInt(51413)
  peerList.listVal.add(bDict(peer1))
  d["peers"] = peerList

  let encoded = encode(bDict(d))
  let resp = parseTrackerResponse(encoded)
  assert resp.peers.len == 1
  assert resp.peers[0].ip == "10.0.0.1"
  assert resp.peers[0].port == 51413
  echo "PASS: parse tracker response dict peers"

block test_parse_tracker_response_failure:
  ## Parse a tracker failure response.
  var d = initTable[string, BencodeValue]()
  d["failure reason"] = bStr("Torrent not found")

  let encoded = encode(bDict(d))
  let resp = parseTrackerResponse(encoded)
  assert resp.failureReason == "Torrent not found"
  assert resp.peers.len == 0
  assert resp.interval == 0
  echo "PASS: parse tracker response failure"

block test_parse_tracker_response_warning:
  var d = initTable[string, BencodeValue]()
  d["interval"] = bInt(900)
  d["warning message"] = bStr("Too many requests")
  d["complete"] = bInt(10)
  d["incomplete"] = bInt(2)
  d["peers"] = bStr("")  # Empty compact peers

  let encoded = encode(bDict(d))
  let resp = parseTrackerResponse(encoded)
  assert resp.warningMessage == "Too many requests"
  assert resp.interval == 900
  assert resp.peers.len == 0
  echo "PASS: parse tracker response warning"

block test_parse_tracker_response_not_dict:
  var caught = false
  try:
    discard parseTrackerResponse(encode(bStr("not a dict")))
  except TrackerError:
    caught = true
  assert caught, "should reject non-dict response"
  echo "PASS: parse tracker response not dict"

block test_parse_tracker_response_many_compact_peers:
  ## Parse response with 10 compact peers.
  var d = initTable[string, BencodeValue]()
  d["interval"] = bInt(1800)
  d["complete"] = bInt(100)
  d["incomplete"] = bInt(10)

  var peerData = ""
  for i in 0 ..< 10:
    peerData.add(char(10))
    peerData.add(char(0))
    peerData.add(char(0))
    peerData.add(char(i.byte))
    let port = uint16(6881 + i)
    peerData.add(char((port shr 8).byte))
    peerData.add(char((port and 0xFF).byte))
  d["peers"] = bStr(peerData)

  let encoded = encode(bDict(d))
  let resp = parseTrackerResponse(encoded)
  assert resp.peers.len == 10
  for i in 0 ..< 10:
    assert resp.peers[i].ip == "10.0.0." & $i
    assert resp.peers[i].port == uint16(6881 + i)
  echo "PASS: parse tracker response many compact peers"

# === UDP tracker protocol (BEP 15) - packet encoding ===

block test_udp_uint64_be_roundtrip:
  ## writeUint64BE / readUint64BE.
  var s = ""
  writeUint64BE(s, 0x0000041727101980'u64)  # Protocol ID
  assert s.len == 8
  let v = readUint64BE(s, 0)
  assert v == 0x0000041727101980'u64
  echo "PASS: UDP uint64 BE roundtrip"

block test_udp_uint64_be_zero:
  var s = ""
  writeUint64BE(s, 0'u64)
  assert s.len == 8
  for i in 0 ..< 8:
    assert s[i] == char(0)
  assert readUint64BE(s, 0) == 0'u64
  echo "PASS: UDP uint64 BE zero"

block test_udp_uint64_be_max:
  var s = ""
  writeUint64BE(s, 0xFFFFFFFFFFFFFFFF'u64)
  for i in 0 ..< 8:
    assert s[i] == char(0xFF)
  assert readUint64BE(s, 0) == 0xFFFFFFFFFFFFFFFF'u64
  echo "PASS: UDP uint64 BE max"

block test_udp_int32_be_roundtrip:
  var s = ""
  writeInt32BE(s, 1800'i32)
  assert s.len == 4
  assert readInt32BE(s, 0) == 1800
  echo "PASS: UDP int32 BE roundtrip"

block test_udp_int32_be_negative:
  var s = ""
  writeInt32BE(s, -1'i32)
  assert readInt32BE(s, 0) == -1
  echo "PASS: UDP int32 BE negative"

block test_udp_connect_request_format:
  ## Verify UDP connect request is 16 bytes with correct protocol ID.
  var req = newStringOfCap(16)
  writeUint64BE(req, 0x41727101980'u64)  # protocol_id
  writeUint32BE(req, 0'u32)               # action = connect
  writeUint32BE(req, 12345'u32)           # transaction_id

  assert req.len == 16
  assert readUint64BE(req, 0) == 0x41727101980'u64
  assert readUint32BE(req, 8) == 0  # connect action
  assert readUint32BE(req, 12) == 12345
  echo "PASS: UDP connect request format"

block test_udp_connect_response_parse:
  ## Parse a mock UDP connect response (16 bytes).
  var resp = ""
  writeUint32BE(resp, 0'u32)                     # action = connect
  writeUint32BE(resp, 12345'u32)                  # transaction_id
  writeUint64BE(resp, 0xDEADBEEFCAFE0000'u64)    # connection_id

  assert resp.len == 16
  assert readUint32BE(resp, 0) == 0               # action
  assert readUint32BE(resp, 4) == 12345            # trans_id
  assert readUint64BE(resp, 8) == 0xDEADBEEFCAFE0000'u64  # conn_id
  echo "PASS: UDP connect response parse"

block test_udp_announce_request_format:
  ## Verify UDP announce request is 98 bytes.
  var req = newStringOfCap(98)
  writeUint64BE(req, 0xDEADBEEFCAFE0000'u64)  # connection_id
  writeUint32BE(req, 1'u32)                      # action = announce
  writeUint32BE(req, 54321'u32)                  # transaction_id
  # info_hash (20 bytes)
  for i in 0 ..< 20: req.add(char(i))
  # peer_id (20 bytes)
  for i in 0 ..< 20: req.add(char(0x2D))
  # downloaded (8 bytes)
  writeUint64BE(req, 1024'u64)
  # left (8 bytes)
  writeUint64BE(req, 999999'u64)
  # uploaded (8 bytes)
  writeUint64BE(req, 512'u64)
  # event (4 bytes) - started = 2
  writeUint32BE(req, 2'u32)
  # ip (4 bytes) - 0 = default
  writeUint32BE(req, 0'u32)
  # key (4 bytes)
  writeUint32BE(req, 0xCAFEBABE'u32)
  # num_want (4 bytes)
  writeInt32BE(req, 200'i32)
  # port (2 bytes)
  req.add(char((6881'u16 shr 8).byte))
  req.add(char((6881'u16 and 0xFF).byte))

  assert req.len == 98
  assert readUint64BE(req, 0) == 0xDEADBEEFCAFE0000'u64  # conn_id
  assert readUint32BE(req, 8) == 1  # announce action
  assert readUint32BE(req, 12) == 54321  # trans_id
  assert req[16].byte == 0  # info_hash[0]
  assert readUint32BE(req, 80) == 2  # event = started
  assert readInt32BE(req, 92) == 200  # num_want
  echo "PASS: UDP announce request format"

block test_udp_announce_response_parse:
  ## Parse a mock UDP announce response.
  var resp = ""
  writeUint32BE(resp, 1'u32)       # action = announce
  writeUint32BE(resp, 54321'u32)   # transaction_id
  writeInt32BE(resp, 1800'i32)     # interval
  writeInt32BE(resp, 20'i32)       # leechers
  writeInt32BE(resp, 150'i32)      # seeders
  # Add 2 compact peers
  resp.add(char(10)); resp.add(char(0)); resp.add(char(0)); resp.add(char(1))
  resp.add(char(0x1A'u8)); resp.add(char(0xE1'u8))  # 6881
  resp.add(char(10)); resp.add(char(0)); resp.add(char(0)); resp.add(char(2))
  resp.add(char(0xC8'u8)); resp.add(char(0xD5'u8))  # 51413

  assert resp.len == 20 + 12  # header + 2 peers
  assert readUint32BE(resp, 0) == 1      # action
  assert readUint32BE(resp, 4) == 54321  # trans_id
  assert readInt32BE(resp, 8) == 1800    # interval
  assert readInt32BE(resp, 12) == 20     # leechers
  assert readInt32BE(resp, 16) == 150    # seeders

  let peerData = resp[20..^1]
  let peers = parseCompactPeers(peerData)
  assert peers.len == 2
  assert peers[0].ip == "10.0.0.1"
  assert peers[0].port == 6881
  assert peers[1].ip == "10.0.0.2"
  assert peers[1].port == 51413
  echo "PASS: UDP announce response parse"

block test_udp_error_response_parse:
  ## Parse a UDP error response (action = 3).
  var resp = ""
  writeUint32BE(resp, 3'u32)       # action = error
  writeUint32BE(resp, 99999'u32)   # transaction_id
  resp.add("Connection ID expired")

  assert readUint32BE(resp, 0) == 3  # error action
  let errMsg = resp[8..^1]
  assert errMsg == "Connection ID expired"
  echo "PASS: UDP error response parse"

# === URL building ===

block test_build_announce_url_basic:
  var params: AnnounceParams
  for i in 0 ..< 20:
    params.infoHash[i] = byte(i)
    params.peerId[i] = byte(0x2D)
  params.port = 6881
  params.uploaded = 0
  params.downloaded = 0
  params.left = 1000000
  params.event = teStarted
  params.compact = true
  params.numWant = 50

  let url = buildAnnounceUrl("http://tracker.example.com/announce", params)
  assert url.startsWith("http://tracker.example.com/announce?")
  assert "info_hash=" in url
  assert "peer_id=" in url
  assert "port=6881" in url
  assert "uploaded=0" in url
  assert "downloaded=0" in url
  assert "left=1000000" in url
  assert "compact=1" in url
  assert "numwant=50" in url
  assert "event=started" in url
  echo "PASS: build announce URL basic"

block test_build_announce_url_existing_query:
  ## URL that already has query params should use & not ?.
  var params: AnnounceParams
  params.port = 6881
  params.compact = true
  params.numWant = 50
  params.event = teNone

  let url = buildAnnounceUrl("http://tracker.example.com/announce?passkey=abc123", params)
  assert "announce?passkey=abc123&" in url
  assert "event=" notin url, "no event param when teNone"
  echo "PASS: build announce URL existing query"

block test_build_announce_url_no_event:
  var params: AnnounceParams
  params.port = 6881
  params.event = teNone
  params.compact = false
  params.numWant = 0

  let url = buildAnnounceUrl("http://tracker.example.com/announce", params)
  assert "event=" notin url
  assert "compact=" notin url
  assert "numwant=" notin url
  echo "PASS: build announce URL no event"

# === defaultAnnounceParams ===

block test_default_announce_params:
  var info: TorrentInfo
  for i in 0 ..< 20: info.infoHash[i] = byte(i)
  info.totalLength = 500_000_000

  var peerId: array[20, byte]
  for i in 0 ..< 20: peerId[i] = byte(0x2D)

  let params = defaultAnnounceParams(info, peerId, 6881)
  assert params.infoHash == info.infoHash
  assert params.peerId == peerId
  assert params.port == 6881
  assert params.uploaded == 0
  assert params.downloaded == 0
  assert params.left == 500_000_000
  assert params.event == teStarted
  assert params.compact == true
  assert params.numWant == 200
  echo "PASS: defaultAnnounceParams"

echo ""
echo "All tracker protocol tests passed!"
