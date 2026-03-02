## CPS IRC Bouncer - Protocol
##
## JSON-lines codec for bouncer <-> client communication.
## Each message is a single JSON object terminated by '\n'.
## Uses std/json for simplicity — performance is not critical on Unix sockets.

import std/[json, tables]
import ./types

type
  BouncerMsgKind* = enum
    # Client -> Bouncer
    bmkHello            ## Initial handshake from client
    bmkReplay           ## Request message replay
    bmkSendPrivmsg      ## Send a PRIVMSG through upstream
    bmkSendNotice       ## Send a NOTICE through upstream
    bmkJoin             ## Join a channel
    bmkPart             ## Part a channel
    bmkNick             ## Change nickname
    bmkRaw              ## Send raw IRC command
    bmkMarkRead         ## Mark messages as read
    bmkQuit             ## Disconnect from a server
    bmkAway             ## Set away status
    bmkBack             ## Clear away status

    # Bouncer -> Client
    bmkHelloOk          ## Handshake response
    bmkServerState      ## Full server state dump
    bmkMessage          ## A buffered/live IRC message
    bmkReplayEnd        ## End of replay batch
    bmkChannelUpdate    ## Channel state change (topic, users, modes)
    bmkServerConnected  ## Upstream server connected
    bmkServerDisconnected ## Upstream server disconnected
    bmkNickChanged      ## Nick change notification
    bmkServerAdded      ## New server added to bouncer
    bmkServerRemoved    ## Server removed from bouncer
    bmkChannelDetach    ## Channel was detached
    bmkChannelAttach    ## Channel was reattached (triggers replay)
    bmkSearch           ## Client -> Bouncer: search request
    bmkSearchResults    ## Bouncer -> Client: search results
    bmkError            ## Error from bouncer

  BouncerMsg* = object
    ## A parsed bouncer protocol message.
    case kind*: BouncerMsgKind
    of bmkHello:
      helloVersion*: int
      helloClientName*: string
      helloPassword*: string
    of bmkHelloOk:
      helloOkVersion*: int
      helloOkServers*: seq[string]
    of bmkServerState:
      ssServer*: string
      ssConnected*: bool
      ssNick*: string
      ssChannels*: seq[ChannelState]
    of bmkReplay:
      replayServer*: string
      replayChannel*: string
      replaySinceId*: int64
      replayLimit*: int
    of bmkMessage:
      msgServer*: string
      msgData*: BufferedMessage
    of bmkReplayEnd:
      reServer*: string
      reChannel*: string
      reNewestId*: int64
    of bmkSendPrivmsg:
      spServer*: string
      spTarget*: string
      spText*: string
    of bmkSendNotice:
      snServer*: string
      snTarget*: string
      snText*: string
    of bmkJoin:
      joinServer*: string
      joinChannel*: string
    of bmkPart:
      partServer*: string
      partChannel*: string
      partReason*: string
    of bmkNick:
      nickServer*: string
      nickNewNick*: string
    of bmkRaw:
      rawServer*: string
      rawLine*: string
    of bmkMarkRead:
      mrServer*: string
      mrChannel*: string
      mrLastId*: int64
    of bmkQuit:
      quitServer*: string
      quitReason*: string
    of bmkAway:
      awayServer*: string
      awayMessage*: string
    of bmkBack:
      backServer*: string
    of bmkChannelUpdate:
      cuServer*: string
      cuChannel*: ChannelState
    of bmkServerConnected:
      scServer*: string
      scNick*: string
    of bmkServerDisconnected:
      sdServer*: string
      sdReason*: string
    of bmkNickChanged:
      ncServer*: string
      ncOldNick*: string
      ncNewNick*: string
    of bmkServerAdded:
      saServer*: string
    of bmkServerRemoved:
      srServer*: string
    of bmkChannelDetach:
      cdServer*: string
      cdChannel*: string
    of bmkChannelAttach:
      caServer*: string
      caChannel*: string
    of bmkSearch:
      searchText*: string
      searchChannel*: string
      searchNick*: string
      searchServer*: string
      searchLimit*: int
      searchBefore*: int64
      searchAfter*: int64
    of bmkSearchResults:
      srchServer*: string
      srchMessages*: seq[BufferedMessage]
      srchHasMore*: bool
    of bmkError:
      errText*: string

# ============================================================
# JSON serialization helpers
# ============================================================

proc tagsToJson(tags: Table[string, string]): JsonNode =
  result = newJObject()
  for k, v in tags:
    result[k] = newJString(v)

proc jsonToTags(node: JsonNode): Table[string, string] =
  result = initTable[string, string]()
  if node.kind == JObject:
    for k, v in node.pairs:
      result[k] = v.getStr()

proc channelStateToJson*(cs: ChannelState): JsonNode =
  result = newJObject()
  result["name"] = newJString(cs.name)
  result["topic"] = newJString(cs.topic)
  result["topicSetBy"] = newJString(cs.topicSetBy)
  result["topicSetAt"] = newJString(cs.topicSetAt)
  var users = newJObject()
  for nick, prefix in cs.users:
    users[nick] = newJString(prefix)
  result["users"] = users
  result["modes"] = newJString(cs.modes)

proc jsonToChannelState(node: JsonNode): ChannelState =
  result.name = node.getOrDefault("name").getStr()
  result.topic = node.getOrDefault("topic").getStr()
  result.topicSetBy = node.getOrDefault("topicSetBy").getStr()
  result.topicSetAt = node.getOrDefault("topicSetAt").getStr()
  result.modes = node.getOrDefault("modes").getStr()
  result.users = initTable[string, string]()
  let usersNode = node.getOrDefault("users")
  if usersNode != nil and usersNode.kind == JObject:
    for nick, prefix in usersNode.pairs:
      result.users[nick] = prefix.getStr()

proc bufferedMessageToJson*(msg: BufferedMessage): JsonNode =
  result = newJObject()
  result["id"] = newJInt(msg.id)
  result["timestamp"] = newJFloat(msg.timestamp)
  result["serverTime"] = newJString(msg.serverTime)
  result["kind"] = newJString(msg.kind)
  result["source"] = newJString(msg.source)
  result["target"] = newJString(msg.target)
  result["text"] = newJString(msg.text)
  result["prefix"] = newJString(msg.prefix)
  if msg.tags.len > 0:
    result["tags"] = tagsToJson(msg.tags)
  if msg.raw.len > 0:
    result["raw"] = newJString(msg.raw)

proc jsonToBufferedMessage*(node: JsonNode): BufferedMessage =
  result.id = node.getOrDefault("id").getBiggestInt()
  result.timestamp = node.getOrDefault("timestamp").getFloat()
  result.serverTime = node.getOrDefault("serverTime").getStr()
  result.kind = node.getOrDefault("kind").getStr()
  result.source = node.getOrDefault("source").getStr()
  result.target = node.getOrDefault("target").getStr()
  result.text = node.getOrDefault("text").getStr()
  result.prefix = node.getOrDefault("prefix").getStr()
  let tagsNode = node.getOrDefault("tags")
  if tagsNode != nil and tagsNode.kind == JObject:
    result.tags = jsonToTags(tagsNode)
  else:
    result.tags = initTable[string, string]()
  result.raw = node.getOrDefault("raw").getStr()

# ============================================================
# Serialization: BouncerMsg -> JSON line
# ============================================================

proc toJsonLine*(msg: BouncerMsg): string =
  ## Serialize a BouncerMsg to a JSON line (without trailing newline).
  var j = newJObject()
  case msg.kind
  of bmkHello:
    j["type"] = newJString("hello")
    j["version"] = newJInt(msg.helloVersion)
    j["clientName"] = newJString(msg.helloClientName)
    if msg.helloPassword.len > 0:
      j["password"] = newJString(msg.helloPassword)
  of bmkHelloOk:
    j["type"] = newJString("hello_ok")
    j["version"] = newJInt(msg.helloOkVersion)
    j["servers"] = %msg.helloOkServers
  of bmkServerState:
    j["type"] = newJString("server_state")
    j["server"] = newJString(msg.ssServer)
    j["connected"] = newJBool(msg.ssConnected)
    j["nick"] = newJString(msg.ssNick)
    var chans = newJArray()
    for ch in msg.ssChannels:
      chans.add(channelStateToJson(ch))
    j["channels"] = chans
  of bmkReplay:
    j["type"] = newJString("replay")
    j["server"] = newJString(msg.replayServer)
    j["channel"] = newJString(msg.replayChannel)
    j["sinceId"] = newJInt(msg.replaySinceId)
    j["limit"] = newJInt(msg.replayLimit)
  of bmkMessage:
    j["type"] = newJString("message")
    j["server"] = newJString(msg.msgServer)
    let msgJson = bufferedMessageToJson(msg.msgData)
    for k, v in msgJson.pairs:
      j[k] = v
  of bmkReplayEnd:
    j["type"] = newJString("replay_end")
    j["server"] = newJString(msg.reServer)
    j["channel"] = newJString(msg.reChannel)
    j["newestId"] = newJInt(msg.reNewestId)
  of bmkSendPrivmsg:
    j["type"] = newJString("send_privmsg")
    j["server"] = newJString(msg.spServer)
    j["target"] = newJString(msg.spTarget)
    j["text"] = newJString(msg.spText)
  of bmkSendNotice:
    j["type"] = newJString("send_notice")
    j["server"] = newJString(msg.snServer)
    j["target"] = newJString(msg.snTarget)
    j["text"] = newJString(msg.snText)
  of bmkJoin:
    j["type"] = newJString("join")
    j["server"] = newJString(msg.joinServer)
    j["channel"] = newJString(msg.joinChannel)
  of bmkPart:
    j["type"] = newJString("part")
    j["server"] = newJString(msg.partServer)
    j["channel"] = newJString(msg.partChannel)
    j["reason"] = newJString(msg.partReason)
  of bmkNick:
    j["type"] = newJString("nick")
    j["server"] = newJString(msg.nickServer)
    j["nick"] = newJString(msg.nickNewNick)
  of bmkRaw:
    j["type"] = newJString("raw")
    j["server"] = newJString(msg.rawServer)
    j["line"] = newJString(msg.rawLine)
  of bmkMarkRead:
    j["type"] = newJString("mark_read")
    j["server"] = newJString(msg.mrServer)
    j["channel"] = newJString(msg.mrChannel)
    j["lastId"] = newJInt(msg.mrLastId)
  of bmkQuit:
    j["type"] = newJString("quit")
    j["server"] = newJString(msg.quitServer)
    j["reason"] = newJString(msg.quitReason)
  of bmkAway:
    j["type"] = newJString("away")
    j["server"] = newJString(msg.awayServer)
    j["message"] = newJString(msg.awayMessage)
  of bmkBack:
    j["type"] = newJString("back")
    j["server"] = newJString(msg.backServer)
  of bmkChannelUpdate:
    j["type"] = newJString("channel_update")
    j["server"] = newJString(msg.cuServer)
    j["channel"] = channelStateToJson(msg.cuChannel)
  of bmkServerConnected:
    j["type"] = newJString("server_connected")
    j["server"] = newJString(msg.scServer)
    j["nick"] = newJString(msg.scNick)
  of bmkServerDisconnected:
    j["type"] = newJString("server_disconnected")
    j["server"] = newJString(msg.sdServer)
    j["reason"] = newJString(msg.sdReason)
  of bmkNickChanged:
    j["type"] = newJString("nick_changed")
    j["server"] = newJString(msg.ncServer)
    j["oldNick"] = newJString(msg.ncOldNick)
    j["newNick"] = newJString(msg.ncNewNick)
  of bmkServerAdded:
    j["type"] = newJString("server_added")
    j["server"] = newJString(msg.saServer)
  of bmkServerRemoved:
    j["type"] = newJString("server_removed")
    j["server"] = newJString(msg.srServer)
  of bmkChannelDetach:
    j["type"] = newJString("channel_detach")
    j["server"] = newJString(msg.cdServer)
    j["channel"] = newJString(msg.cdChannel)
  of bmkChannelAttach:
    j["type"] = newJString("channel_attach")
    j["server"] = newJString(msg.caServer)
    j["channel"] = newJString(msg.caChannel)
  of bmkSearch:
    j["type"] = newJString("search")
    j["text"] = newJString(msg.searchText)
    if msg.searchChannel.len > 0:
      j["channel"] = newJString(msg.searchChannel)
    if msg.searchNick.len > 0:
      j["nick"] = newJString(msg.searchNick)
    if msg.searchServer.len > 0:
      j["server"] = newJString(msg.searchServer)
    j["limit"] = newJInt(msg.searchLimit)
    if msg.searchBefore > 0:
      j["before"] = newJInt(msg.searchBefore)
    if msg.searchAfter > 0:
      j["after"] = newJInt(msg.searchAfter)
  of bmkSearchResults:
    j["type"] = newJString("search_results")
    j["server"] = newJString(msg.srchServer)
    var msgs = newJArray()
    for m in msg.srchMessages:
      msgs.add(bufferedMessageToJson(m))
    j["messages"] = msgs
    j["hasMore"] = newJBool(msg.srchHasMore)
  of bmkError:
    j["type"] = newJString("error")
    j["text"] = newJString(msg.errText)
  result = $j

# ============================================================
# Deserialization: JSON line -> BouncerMsg
# ============================================================

proc parseBouncerMsg*(line: string): BouncerMsg =
  ## Parse a JSON line into a BouncerMsg. Raises on invalid JSON.
  let j = parseJson(line)
  let msgType = j.getOrDefault("type").getStr()
  case msgType
  of "hello":
    result = BouncerMsg(kind: bmkHello,
      helloVersion: j.getOrDefault("version").getInt(1),
      helloClientName: j.getOrDefault("clientName").getStr(),
      helloPassword: j.getOrDefault("password").getStr())
  of "hello_ok":
    var servers: seq[string] = @[]
    let serversNode = j.getOrDefault("servers")
    if serversNode != nil and serversNode.kind == JArray:
      for s in serversNode:
        servers.add(s.getStr())
    result = BouncerMsg(kind: bmkHelloOk,
      helloOkVersion: j.getOrDefault("version").getInt(1),
      helloOkServers: servers)
  of "server_state":
    var channels: seq[ChannelState] = @[]
    let chansNode = j.getOrDefault("channels")
    if chansNode != nil and chansNode.kind == JArray:
      for ch in chansNode:
        channels.add(jsonToChannelState(ch))
    result = BouncerMsg(kind: bmkServerState,
      ssServer: j["server"].getStr(),
      ssConnected: j.getOrDefault("connected").getBool(),
      ssNick: j.getOrDefault("nick").getStr(),
      ssChannels: channels)
  of "replay":
    result = BouncerMsg(kind: bmkReplay,
      replayServer: j["server"].getStr(),
      replayChannel: j["channel"].getStr(),
      replaySinceId: j.getOrDefault("sinceId").getBiggestInt(),
      replayLimit: j.getOrDefault("limit").getInt(500))
  of "message":
    result = BouncerMsg(kind: bmkMessage,
      msgServer: j["server"].getStr(),
      msgData: jsonToBufferedMessage(j))
  of "replay_end":
    result = BouncerMsg(kind: bmkReplayEnd,
      reServer: j["server"].getStr(),
      reChannel: j.getOrDefault("channel").getStr(),
      reNewestId: j.getOrDefault("newestId").getBiggestInt())
  of "send_privmsg":
    result = BouncerMsg(kind: bmkSendPrivmsg,
      spServer: j["server"].getStr(),
      spTarget: j["target"].getStr(),
      spText: j["text"].getStr())
  of "send_notice":
    result = BouncerMsg(kind: bmkSendNotice,
      snServer: j["server"].getStr(),
      snTarget: j["target"].getStr(),
      snText: j["text"].getStr())
  of "join":
    result = BouncerMsg(kind: bmkJoin,
      joinServer: j["server"].getStr(),
      joinChannel: j["channel"].getStr())
  of "part":
    result = BouncerMsg(kind: bmkPart,
      partServer: j["server"].getStr(),
      partChannel: j["channel"].getStr(),
      partReason: j.getOrDefault("reason").getStr())
  of "nick":
    result = BouncerMsg(kind: bmkNick,
      nickServer: j["server"].getStr(),
      nickNewNick: j["nick"].getStr())
  of "raw":
    result = BouncerMsg(kind: bmkRaw,
      rawServer: j["server"].getStr(),
      rawLine: j["line"].getStr())
  of "mark_read":
    result = BouncerMsg(kind: bmkMarkRead,
      mrServer: j["server"].getStr(),
      mrChannel: j["channel"].getStr(),
      mrLastId: j.getOrDefault("lastId").getBiggestInt())
  of "quit":
    result = BouncerMsg(kind: bmkQuit,
      quitServer: j["server"].getStr(),
      quitReason: j.getOrDefault("reason").getStr())
  of "away":
    result = BouncerMsg(kind: bmkAway,
      awayServer: j["server"].getStr(),
      awayMessage: j.getOrDefault("message").getStr())
  of "back":
    result = BouncerMsg(kind: bmkBack,
      backServer: j["server"].getStr())
  of "channel_update":
    result = BouncerMsg(kind: bmkChannelUpdate,
      cuServer: j["server"].getStr(),
      cuChannel: jsonToChannelState(j["channel"]))
  of "server_connected":
    result = BouncerMsg(kind: bmkServerConnected,
      scServer: j["server"].getStr(),
      scNick: j.getOrDefault("nick").getStr())
  of "server_disconnected":
    result = BouncerMsg(kind: bmkServerDisconnected,
      sdServer: j["server"].getStr(),
      sdReason: j.getOrDefault("reason").getStr())
  of "nick_changed":
    result = BouncerMsg(kind: bmkNickChanged,
      ncServer: j["server"].getStr(),
      ncOldNick: j.getOrDefault("oldNick").getStr(),
      ncNewNick: j.getOrDefault("newNick").getStr())
  of "server_added":
    result = BouncerMsg(kind: bmkServerAdded,
      saServer: j["server"].getStr())
  of "server_removed":
    result = BouncerMsg(kind: bmkServerRemoved,
      srServer: j["server"].getStr())
  of "channel_detach":
    result = BouncerMsg(kind: bmkChannelDetach,
      cdServer: j["server"].getStr(),
      cdChannel: j["channel"].getStr())
  of "channel_attach":
    result = BouncerMsg(kind: bmkChannelAttach,
      caServer: j["server"].getStr(),
      caChannel: j["channel"].getStr())
  of "search":
    result = BouncerMsg(kind: bmkSearch,
      searchText: j.getOrDefault("text").getStr(),
      searchChannel: j.getOrDefault("channel").getStr(),
      searchNick: j.getOrDefault("nick").getStr(),
      searchServer: j.getOrDefault("server").getStr(),
      searchLimit: j.getOrDefault("limit").getInt(50),
      searchBefore: j.getOrDefault("before").getBiggestInt(),
      searchAfter: j.getOrDefault("after").getBiggestInt())
  of "search_results":
    var messages: seq[BufferedMessage] = @[]
    let msgsNode = j.getOrDefault("messages")
    if msgsNode != nil and msgsNode.kind == JArray:
      for m in msgsNode:
        messages.add(jsonToBufferedMessage(m))
    result = BouncerMsg(kind: bmkSearchResults,
      srchServer: j.getOrDefault("server").getStr(),
      srchMessages: messages,
      srchHasMore: j.getOrDefault("hasMore").getBool())
  of "error":
    result = BouncerMsg(kind: bmkError,
      errText: j.getOrDefault("text").getStr())
  else:
    result = BouncerMsg(kind: bmkError,
      errText: "Unknown message type: " & msgType)
