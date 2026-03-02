## Test: Bouncer Protocol JSON-lines codec
##
## Tests roundtrip serialization/deserialization of all bouncer message types.

import std/[json, tables, strutils]
import cps/bouncer/types
import cps/bouncer/protocol

# ============================================================
# Roundtrip helper
# ============================================================

proc roundtrip(msg: BouncerMsg): BouncerMsg =
  let line = msg.toJsonLine()
  result = parseBouncerMsg(line)

# ============================================================
# Tests: Client -> Bouncer messages
# ============================================================

block testHello:
  let msg = BouncerMsg(kind: bmkHello, helloVersion: 1, helloClientName: "cps-tui")
  let rt = roundtrip(msg)
  assert rt.kind == bmkHello
  assert rt.helloVersion == 1
  assert rt.helloClientName == "cps-tui"
  echo "PASS: hello roundtrip"

block testReplay:
  let msg = BouncerMsg(kind: bmkReplay,
    replayServer: "libera", replayChannel: "#nim",
    replaySinceId: 4523, replayLimit: 500)
  let rt = roundtrip(msg)
  assert rt.kind == bmkReplay
  assert rt.replayServer == "libera"
  assert rt.replayChannel == "#nim"
  assert rt.replaySinceId == 4523
  assert rt.replayLimit == 500
  echo "PASS: replay roundtrip"

block testSendPrivmsg:
  let msg = BouncerMsg(kind: bmkSendPrivmsg,
    spServer: "libera", spTarget: "#nim", spText: "Hello world!")
  let rt = roundtrip(msg)
  assert rt.kind == bmkSendPrivmsg
  assert rt.spServer == "libera"
  assert rt.spTarget == "#nim"
  assert rt.spText == "Hello world!"
  echo "PASS: send_privmsg roundtrip"

block testSendNotice:
  let msg = BouncerMsg(kind: bmkSendNotice,
    snServer: "oftc", snTarget: "user", snText: "test notice")
  let rt = roundtrip(msg)
  assert rt.kind == bmkSendNotice
  assert rt.snTarget == "user"
  echo "PASS: send_notice roundtrip"

block testJoin:
  let msg = BouncerMsg(kind: bmkJoin, joinServer: "libera", joinChannel: "#test")
  let rt = roundtrip(msg)
  assert rt.kind == bmkJoin
  assert rt.joinChannel == "#test"
  echo "PASS: join roundtrip"

block testPart:
  let msg = BouncerMsg(kind: bmkPart,
    partServer: "libera", partChannel: "#test", partReason: "bye")
  let rt = roundtrip(msg)
  assert rt.kind == bmkPart
  assert rt.partReason == "bye"
  echo "PASS: part roundtrip"

block testNick:
  let msg = BouncerMsg(kind: bmkNick, nickServer: "libera", nickNewNick: "newnick")
  let rt = roundtrip(msg)
  assert rt.kind == bmkNick
  assert rt.nickNewNick == "newnick"
  echo "PASS: nick roundtrip"

block testRaw:
  let msg = BouncerMsg(kind: bmkRaw, rawServer: "libera", rawLine: "PING :test")
  let rt = roundtrip(msg)
  assert rt.kind == bmkRaw
  assert rt.rawLine == "PING :test"
  echo "PASS: raw roundtrip"

block testMarkRead:
  let msg = BouncerMsg(kind: bmkMarkRead,
    mrServer: "libera", mrChannel: "#nim", mrLastId: 100)
  let rt = roundtrip(msg)
  assert rt.kind == bmkMarkRead
  assert rt.mrLastId == 100
  echo "PASS: mark_read roundtrip"

block testQuit:
  let msg = BouncerMsg(kind: bmkQuit, quitServer: "libera", quitReason: "bye")
  let rt = roundtrip(msg)
  assert rt.kind == bmkQuit
  assert rt.quitReason == "bye"
  echo "PASS: quit roundtrip"

block testAway:
  let msg = BouncerMsg(kind: bmkAway, awayServer: "libera", awayMessage: "afk")
  let rt = roundtrip(msg)
  assert rt.kind == bmkAway
  assert rt.awayMessage == "afk"
  echo "PASS: away roundtrip"

block testBack:
  let msg = BouncerMsg(kind: bmkBack, backServer: "libera")
  let rt = roundtrip(msg)
  assert rt.kind == bmkBack
  assert rt.backServer == "libera"
  echo "PASS: back roundtrip"

# ============================================================
# Tests: Bouncer -> Client messages
# ============================================================

block testHelloOk:
  let msg = BouncerMsg(kind: bmkHelloOk,
    helloOkVersion: 1, helloOkServers: @["libera", "oftc"])
  let rt = roundtrip(msg)
  assert rt.kind == bmkHelloOk
  assert rt.helloOkVersion == 1
  assert rt.helloOkServers == @["libera", "oftc"]
  echo "PASS: hello_ok roundtrip"

block testServerState:
  var ch = ChannelState(
    name: "#nim",
    topic: "Welcome to Nim",
    topicSetBy: "admin",
    topicSetAt: "12345",
    users: initTable[string, string](),
    modes: "+nt",
  )
  ch.users["@op"] = "@"
  ch.users["user"] = ""
  let msg = BouncerMsg(kind: bmkServerState,
    ssServer: "libera", ssConnected: true, ssNick: "me",
    ssChannels: @[ch])
  let rt = roundtrip(msg)
  assert rt.kind == bmkServerState
  assert rt.ssServer == "libera"
  assert rt.ssConnected == true
  assert rt.ssNick == "me"
  assert rt.ssChannels.len == 1
  assert rt.ssChannels[0].name == "#nim"
  assert rt.ssChannels[0].topic == "Welcome to Nim"
  assert rt.ssChannels[0].modes == "+nt"
  assert rt.ssChannels[0].users.len == 2
  echo "PASS: server_state roundtrip"

block testMessage:
  var tags = initTable[string, string]()
  tags["time"] = "2024-01-01T00:00:00Z"
  let bm = BufferedMessage(
    id: 42, timestamp: 1704067200.0,
    serverTime: "2024-01-01T00:00:00Z",
    kind: "privmsg", source: "nick", target: "#nim",
    text: "hello world", prefix: "nick!user@host",
    tags: tags,
  )
  let msg = BouncerMsg(kind: bmkMessage, msgServer: "libera", msgData: bm)
  let rt = roundtrip(msg)
  assert rt.kind == bmkMessage
  assert rt.msgServer == "libera"
  assert rt.msgData.id == 42
  assert rt.msgData.kind == "privmsg"
  assert rt.msgData.source == "nick"
  assert rt.msgData.target == "#nim"
  assert rt.msgData.text == "hello world"
  echo "PASS: message roundtrip"

block testReplayEnd:
  let msg = BouncerMsg(kind: bmkReplayEnd,
    reServer: "libera", reChannel: "#nim", reNewestId: 100)
  let rt = roundtrip(msg)
  assert rt.kind == bmkReplayEnd
  assert rt.reNewestId == 100
  echo "PASS: replay_end roundtrip"

block testChannelUpdate:
  let ch = ChannelState(name: "#nim", topic: "new topic",
    users: initTable[string, string](), modes: "+s")
  let msg = BouncerMsg(kind: bmkChannelUpdate,
    cuServer: "libera", cuChannel: ch)
  let rt = roundtrip(msg)
  assert rt.kind == bmkChannelUpdate
  assert rt.cuChannel.topic == "new topic"
  echo "PASS: channel_update roundtrip"

block testServerConnected:
  let msg = BouncerMsg(kind: bmkServerConnected,
    scServer: "libera", scNick: "me")
  let rt = roundtrip(msg)
  assert rt.kind == bmkServerConnected
  assert rt.scNick == "me"
  echo "PASS: server_connected roundtrip"

block testServerDisconnected:
  let msg = BouncerMsg(kind: bmkServerDisconnected,
    sdServer: "libera", sdReason: "timeout")
  let rt = roundtrip(msg)
  assert rt.kind == bmkServerDisconnected
  assert rt.sdReason == "timeout"
  echo "PASS: server_disconnected roundtrip"

block testNickChanged:
  let msg = BouncerMsg(kind: bmkNickChanged,
    ncServer: "libera", ncOldNick: "old", ncNewNick: "new")
  let rt = roundtrip(msg)
  assert rt.kind == bmkNickChanged
  assert rt.ncOldNick == "old"
  assert rt.ncNewNick == "new"
  echo "PASS: nick_changed roundtrip"

block testError:
  let msg = BouncerMsg(kind: bmkError, errText: "something went wrong")
  let rt = roundtrip(msg)
  assert rt.kind == bmkError
  assert rt.errText == "something went wrong"
  echo "PASS: error roundtrip"

# ============================================================
# Edge cases
# ============================================================

block testUnknownType:
  let rt = parseBouncerMsg("""{"type":"unknown_blah"}""")
  assert rt.kind == bmkError
  assert "Unknown" in rt.errText
  echo "PASS: unknown type returns error"

block testEmptyTags:
  let bm = BufferedMessage(
    id: 1, kind: "privmsg", source: "nick", target: "#ch",
    text: "test", tags: initTable[string, string](),
  )
  let msg = BouncerMsg(kind: bmkMessage, msgServer: "s", msgData: bm)
  let rt = roundtrip(msg)
  assert rt.msgData.tags.len == 0
  echo "PASS: empty tags roundtrip"

block testSpecialChars:
  let bm = BufferedMessage(
    id: 1, kind: "privmsg", source: "nick", target: "#ch",
    text: "hello \"world\" \\ \n tabs\there",
    tags: initTable[string, string](),
  )
  let msg = BouncerMsg(kind: bmkMessage, msgServer: "s", msgData: bm)
  let rt = roundtrip(msg)
  assert rt.msgData.text == "hello \"world\" \\ \n tabs\there"
  echo "PASS: special characters roundtrip"

echo "\nAll bouncer protocol tests passed!"
