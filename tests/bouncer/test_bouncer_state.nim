## Test: Bouncer State Tracking
##
## Tests IrcEvent processing for channel/user/topic state management.

import std/[tables, strutils]
import cps/irc/protocol
import cps/bouncer/types
import cps/bouncer/state

# ============================================================
# Helpers
# ============================================================

proc newTestServer(name: string = "test", nick: string = "me"): ServerState =
  ServerState(
    name: name,
    channels: initTable[string, ChannelState](),
    currentNick: nick,
    enabledCaps: @[],
    isupport: newISupport(),
    lagMs: -1,
    connected: false,
    nextMsgId: 0,
  )

# ============================================================
# Connection events
# ============================================================

block testConnected:
  var server = newTestServer()
  let msgs = processEvent(server, IrcEvent(kind: iekConnected))
  assert server.connected == true
  assert msgs.len == 1
  assert msgs[0].kind == "system"
  assert "Connected" in msgs[0].text
  echo "PASS: iekConnected updates state"

block testDisconnected:
  var server = newTestServer()
  server.connected = true
  server.channels["#test"] = ChannelState(
    name: "#test",
    users: {"user1": "", "user2": "@"}.toTable,
  )
  let msgs = processEvent(server, IrcEvent(kind: iekDisconnected, reason: "timeout"))
  assert server.connected == false
  assert server.channels["#test"].users.len == 0  # Users cleared
  assert msgs.len == 1
  assert msgs[0].kind == "system"
  echo "PASS: iekDisconnected clears users"

# ============================================================
# Channel join/part/kick
# ============================================================

block testSelfJoin:
  var server = newTestServer()
  let evt = IrcEvent(kind: iekJoin, joinNick: "me", joinChannel: "#nim",
    joinPrefix: IrcPrefix(raw: "me!user@host"))
  let msgs = processEvent(server, evt)
  assert "#nim" in server.channels
  assert "me" in server.channels["#nim"].users
  assert msgs.len == 1
  assert msgs[0].kind == "join"
  echo "PASS: self join creates channel"

block testOtherJoin:
  var server = newTestServer()
  server.channels["#nim"] = ChannelState(
    name: "#nim", users: {"me": ""}.toTable)
  let evt = IrcEvent(kind: iekJoin, joinNick: "other", joinChannel: "#nim",
    joinPrefix: IrcPrefix(raw: "other!u@h"))
  let msgs = processEvent(server, evt)
  assert "other" in server.channels["#nim"].users
  assert msgs.len == 1
  echo "PASS: other join adds user"

block testSelfPart:
  var server = newTestServer()
  server.channels["#nim"] = ChannelState(
    name: "#nim", users: {"me": "", "other": ""}.toTable)
  let evt = IrcEvent(kind: iekPart, partNick: "me", partChannel: "#nim",
    partReason: "bye", partPrefix: IrcPrefix())
  let msgs = processEvent(server, evt)
  assert "#nim" notin server.channels  # Channel removed
  assert msgs.len == 1
  assert msgs[0].kind == "part"
  echo "PASS: self part removes channel"

block testOtherPart:
  var server = newTestServer()
  server.channels["#nim"] = ChannelState(
    name: "#nim", users: {"me": "", "other": ""}.toTable)
  let evt = IrcEvent(kind: iekPart, partNick: "other", partChannel: "#nim",
    partReason: "", partPrefix: IrcPrefix())
  let msgs = processEvent(server, evt)
  assert "#nim" in server.channels
  assert "other" notin server.channels["#nim"].users
  assert "me" in server.channels["#nim"].users
  echo "PASS: other part removes user"

block testKickSelf:
  var server = newTestServer()
  server.channels["#nim"] = ChannelState(
    name: "#nim", users: {"me": ""}.toTable)
  let evt = IrcEvent(kind: iekKick, kickChannel: "#nim",
    kickNick: "me", kickBy: "op", kickReason: "bye")
  let msgs = processEvent(server, evt)
  assert "#nim" notin server.channels
  assert msgs.len == 1
  assert msgs[0].kind == "kick"
  echo "PASS: self kick removes channel"

block testKickOther:
  var server = newTestServer()
  server.channels["#nim"] = ChannelState(
    name: "#nim", users: {"me": "", "other": ""}.toTable)
  let evt = IrcEvent(kind: iekKick, kickChannel: "#nim",
    kickNick: "other", kickBy: "me", kickReason: "reason")
  let msgs = processEvent(server, evt)
  assert "other" notin server.channels["#nim"].users
  echo "PASS: kick other removes user"

# ============================================================
# Quit / Nick
# ============================================================

block testQuit:
  var server = newTestServer()
  server.channels["#nim"] = ChannelState(
    name: "#nim", users: {"me": "", "quitter": ""}.toTable)
  server.channels["#other"] = ChannelState(
    name: "#other", users: {"quitter": "@", "someone": ""}.toTable)
  let evt = IrcEvent(kind: iekQuit, quitNick: "quitter",
    quitReason: "bye", quitPrefix: IrcPrefix())
  let msgs = processEvent(server, evt)
  assert "quitter" notin server.channels["#nim"].users
  assert "quitter" notin server.channels["#other"].users
  assert msgs.len == 1
  echo "PASS: quit removes user from all channels"

block testNickChangeSelf:
  var server = newTestServer()
  server.channels["#nim"] = ChannelState(
    name: "#nim", users: {"me": "@"}.toTable)
  let evt = IrcEvent(kind: iekNick, nickOld: "me", nickNew: "me_")
  let msgs = processEvent(server, evt)
  assert server.currentNick == "me_"
  assert "me" notin server.channels["#nim"].users
  assert "me_" in server.channels["#nim"].users
  assert server.channels["#nim"].users["me_"] == "@"  # Prefix preserved
  assert msgs.len == 1
  echo "PASS: self nick change updates currentNick and channels"

block testNickChangeOther:
  var server = newTestServer()
  server.channels["#nim"] = ChannelState(
    name: "#nim", users: {"me": "", "old": "+"}.toTable)
  let evt = IrcEvent(kind: iekNick, nickOld: "old", nickNew: "new")
  let msgs = processEvent(server, evt)
  assert server.currentNick == "me"  # Unchanged
  assert "old" notin server.channels["#nim"].users
  assert "new" in server.channels["#nim"].users
  assert server.channels["#nim"].users["new"] == "+"
  echo "PASS: other nick change renames in channels"

# ============================================================
# Topic / Mode
# ============================================================

block testTopic:
  var server = newTestServer()
  server.channels["#nim"] = ChannelState(name: "#nim",
    users: initTable[string, string]())
  let evt = IrcEvent(kind: iekTopic, topicChannel: "#nim",
    topicText: "New topic!", topicBy: "admin")
  let msgs = processEvent(server, evt)
  assert server.channels["#nim"].topic == "New topic!"
  assert server.channels["#nim"].topicSetBy == "admin"
  assert msgs.len == 1
  assert msgs[0].kind == "topic"
  echo "PASS: topic updates channel state"

block testModeUserOp:
  var server = newTestServer()
  server.channels["#nim"] = ChannelState(name: "#nim",
    users: {"user1": ""}.toTable)
  let evt = IrcEvent(kind: iekMode, modeTarget: "#nim",
    modeChanges: "+o", modeParams: @["user1"])
  let msgs = processEvent(server, evt)
  assert server.channels["#nim"].users["user1"] == "@"
  assert msgs.len == 1
  echo "PASS: +o sets @ prefix"

block testModeUserDeop:
  var server = newTestServer()
  server.channels["#nim"] = ChannelState(name: "#nim",
    users: {"user1": "@"}.toTable)
  let evt = IrcEvent(kind: iekMode, modeTarget: "#nim",
    modeChanges: "-o", modeParams: @["user1"])
  let msgs = processEvent(server, evt)
  assert server.channels["#nim"].users["user1"] == ""
  echo "PASS: -o clears prefix"

block testModeVoice:
  var server = newTestServer()
  server.channels["#nim"] = ChannelState(name: "#nim",
    users: {"user1": ""}.toTable)
  let evt = IrcEvent(kind: iekMode, modeTarget: "#nim",
    modeChanges: "+v", modeParams: @["user1"])
  let msgs = processEvent(server, evt)
  assert server.channels["#nim"].users["user1"] == "+"
  echo "PASS: +v sets + prefix"

# ============================================================
# NAMES reply (numeric 353)
# ============================================================

block testNamesReply:
  var server = newTestServer()
  server.channels["#nim"] = ChannelState(name: "#nim",
    users: initTable[string, string]())
  let evt = IrcEvent(kind: iekNumeric, numCode: 353,
    numParams: @["me", "=", "#nim", "@op +voice regular"])
  let msgs = processEvent(server, evt)
  assert server.channels["#nim"].users.len == 3
  assert server.channels["#nim"].users["op"] == "@"
  assert server.channels["#nim"].users["voice"] == "+"
  assert server.channels["#nim"].users["regular"] == ""
  assert msgs.len == 0  # NAMES reply is not buffered
  echo "PASS: NAMES reply populates users"

block testTopicNumeric:
  var server = newTestServer()
  server.channels["#nim"] = ChannelState(name: "#nim",
    users: initTable[string, string]())
  let evt = IrcEvent(kind: iekNumeric, numCode: 332,
    numParams: @["me", "#nim", "The topic text"])
  let msgs = processEvent(server, evt)
  assert server.channels["#nim"].topic == "The topic text"
  assert msgs.len == 0  # 332 is not buffered
  echo "PASS: 332 RPL_TOPIC sets topic"

# ============================================================
# Messages
# ============================================================

block testPrivmsg:
  var server = newTestServer()
  let evt = IrcEvent(kind: iekPrivMsg, pmSource: "nick",
    pmTarget: "#nim", pmText: "hello", pmPrefix: IrcPrefix(raw: "nick!u@h"))
  let msgs = processEvent(server, evt)
  assert msgs.len == 1
  assert msgs[0].kind == "privmsg"
  assert msgs[0].source == "nick"
  assert msgs[0].target == "#nim"
  assert msgs[0].text == "hello"
  assert msgs[0].id > 0
  echo "PASS: privmsg creates buffered message"

block testNotice:
  var server = newTestServer()
  let evt = IrcEvent(kind: iekNotice, pmSource: "server",
    pmTarget: "me", pmText: "notice text", pmPrefix: IrcPrefix())
  let msgs = processEvent(server, evt)
  assert msgs.len == 1
  assert msgs[0].kind == "notice"
  echo "PASS: notice creates buffered message"

block testCtcpAction:
  var server = newTestServer()
  let evt = IrcEvent(kind: iekCtcp, ctcpSource: "nick",
    ctcpTarget: "#nim", ctcpCommand: "ACTION", ctcpArgs: "waves",
    ctcpPrefix: IrcPrefix(raw: "nick!u@h"))
  let msgs = processEvent(server, evt)
  assert msgs.len == 1
  assert msgs[0].kind == "action"
  assert msgs[0].text == "waves"
  echo "PASS: CTCP ACTION creates action message"

block testCtcpOther:
  var server = newTestServer()
  let evt = IrcEvent(kind: iekCtcp, ctcpSource: "nick",
    ctcpTarget: "me", ctcpCommand: "VERSION", ctcpArgs: "",
    ctcpPrefix: IrcPrefix())
  let msgs = processEvent(server, evt)
  assert msgs.len == 0  # Non-ACTION CTCP is not buffered
  echo "PASS: non-ACTION CTCP not buffered"

# ============================================================
# Away
# ============================================================

block testAwaySelf:
  var server = newTestServer()
  let evt = IrcEvent(kind: iekAway, awayNick: "me",
    awayMessage: "gone", awayPrefix: IrcPrefix())
  discard processEvent(server, evt)
  assert server.isAway == true
  echo "PASS: self away sets isAway"

block testBackSelf:
  var server = newTestServer()
  server.isAway = true
  let evt = IrcEvent(kind: iekAway, awayNick: "me",
    awayMessage: "", awayPrefix: IrcPrefix())
  discard processEvent(server, evt)
  assert server.isAway == false
  echo "PASS: self back clears isAway"

# ============================================================
# Case-insensitive channel names
# ============================================================

block testCaseInsensitive:
  var server = newTestServer()
  let joinEvt = IrcEvent(kind: iekJoin, joinNick: "me", joinChannel: "#NIM",
    joinPrefix: IrcPrefix())
  discard processEvent(server, joinEvt)
  assert "#nim" in server.channels  # Stored lowercase
  let topicEvt = IrcEvent(kind: iekTopic, topicChannel: "#Nim",
    topicText: "test", topicBy: "op")
  discard processEvent(server, topicEvt)
  assert server.channels["#nim"].topic == "test"  # Found via lowercase
  echo "PASS: case-insensitive channel tracking"

# ============================================================
# Message ID monotonicity
# ============================================================

block testIdMonotonic:
  var server = newTestServer()
  var ids: seq[int64] = @[]
  for i in 0 ..< 5:
    let evt = IrcEvent(kind: iekPrivMsg, pmSource: "nick",
      pmTarget: "#ch", pmText: "msg" & $i, pmPrefix: IrcPrefix())
    let msgs = processEvent(server, evt)
    ids.add(msgs[0].id)
  for i in 1 ..< ids.len:
    assert ids[i] > ids[i-1]
  echo "PASS: message IDs are monotonically increasing"

echo "\nAll bouncer state tests passed!"
