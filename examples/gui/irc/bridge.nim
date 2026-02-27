## Nim bridge logic for the IRC GUI client.
##
## Connects the SwiftUI GUI to the CPS IRC client via C FFI.
## The bridge runs a background CPS event loop thread for IRC networking,
## communicating with the main (Swift) thread via locked queues.
##
## Payload contract (same as todo bridge):
## - 4 bytes: action tag (u32 little-endian)
## - 4 bytes: state blob length (u32 little-endian)
## - N bytes: UTF-8 JSON for state snapshot

import cps/runtime
import cps/transform
import cps/eventloop
import cps/ircclient
import cps/concurrency/channels

import std/[json, os, strutils, locks, tables, times, sequtils, algorithm]

# ============================================================
# Action tags (must match action declaration order in app.gui)
# ============================================================

const
  tagPoll = 0'u32
  tagStartPoll = 1'u32
  tagConnect = 2'u32
  tagDisconnect = 3'u32
  tagSwitchServer = 4'u32
  tagReconnect = 5'u32
  tagSwitchChannel = 6'u32
  tagJoinChannel = 7'u32
  tagPartChannel = 8'u32
  tagCloseChannel = 9'u32
  tagSendMessage = 10'u32
  tagUpdateInput = 11'u32
  tagToggleUserList = 12'u32
  tagShowConnectForm = 13'u32
  tagHideConnectForm = 14'u32
  tagTabComplete = 15'u32
  tagAcceptCompletion = 16'u32
  tagSaveServer = 17'u32
  tagRemoveServer = 18'u32
  tagLoadConfig = 19'u32

# ============================================================
# Bridge types
# ============================================================

type
  BridgeCommandKind = enum
    cmdConnect, cmdDisconnect, cmdSendMessage, cmdJoinChannel, cmdPartChannel,
    cmdChangeNick, cmdSetAway, cmdClearAway, cmdSetTopic, cmdSendRaw,
    cmdSwitchServer, cmdReconnect, cmdQuit

  BridgeCommand = object
    kind: BridgeCommandKind
    serverId: int
    text: string
    text2: string
    text3: string     # extra param (password, etc.)
    text4: string     # extra param (sasl user, etc.)
    text5: string     # extra param (sasl pass, etc.)
    intParam: int
    boolParam: bool

  UiEventKind = enum
    uiNewMessage, uiUserJoin, uiUserPart, uiUserQuit, uiUserNick,
    uiTopicChange, uiConnected, uiDisconnected, uiUserList, uiModeChange,
    uiError, uiLagUpdate, uiAwayChange, uiChannelListUpdate, uiTyping,
    uiNickChange

  UiEvent = object
    kind: UiEventKind
    serverId: int
    channel: string
    nick: string
    text: string
    text2: string
    intParam: int
    boolParam: bool
    users: seq[string]

  MessageSpan = object
    text: string
    fg: string
    bg: string
    bold: bool
    italic: bool
    underline: bool
    strikethrough: bool
    link: string

  ServerState = object
    id: int
    name: string
    host: string
    port: int
    nick: string
    useTls: bool
    password: string
    saslUser: string
    saslPass: string
    autoJoinChannels: seq[string]
    connected: bool
    connecting: bool
    lagMs: int
    isAway: bool

  ChannelState = object
    id: int
    serverId: int
    name: string
    topic: string
    unread: int
    mentions: int
    userCount: int

  MessageState = object
    id: int
    kind: string
    nick: string
    text: string
    timestamp: string
    isMention: bool
    isOwn: bool
    spans: string

  UserState = object
    nick: string
    prefix: string
    isAway: bool

  IrcConnection = object
    id: int
    client: IrcClient
    config: IrcClientConfig
    channels: seq[string]
    myNick: string

  GUIBridgeBuffer {.bycopy.} = object
    data: ptr uint8
    len: uint32

  GUIBridgeDispatchOutput {.bycopy.} = object
    statePatch: GUIBridgeBuffer
    effects: GUIBridgeBuffer
    emittedActions: GUIBridgeBuffer
    diagnostics: GUIBridgeBuffer

  GUIBridgeFunctionTable {.bycopy.} = object
    abiVersion: uint32
    alloc: proc(size: csize_t): pointer {.cdecl.}
    free: proc(p: pointer) {.cdecl.}
    dispatch: proc(payload: ptr uint8, payloadLen: uint32,
                   outp: ptr GUIBridgeDispatchOutput): int32 {.cdecl.}

const
  guiBridgeAbiVersion = 2'u32
  MaxMessagesPerChannel = 500
  ServerChannel = "*server*"

# ============================================================
# Global state
# ============================================================

var
  gLock: Lock
  gCommandQueue: seq[BridgeCommand]
  gEventQueue: seq[UiEvent]
  gEventLoopThread: Thread[void]
  gEventLoopRunning: bool

  # IRC state (modified during bridgeDispatch on main thread)
  gServers: seq[ServerState]
  gChannels: Table[string, seq[ChannelState]]
  gMessages: Table[string, seq[MessageState]]
  gUsers: Table[string, seq[UserState]]
  gActiveServerId: int = -1
  gActiveChannelName: string = ""
  gNextServerId: int = 1
  gNextChannelId: int = 1
  gNextMessageId: int = 1
  gInputText: string = ""
  gShowUserList: bool = true
  gShowConnectForm: bool = false
  gStatusText: string = "Disconnected"
  gTypingText: string = ""
  gCurrentTopic: string = ""
  gCurrentUserCount: int = 0

  # Connect form state
  gConnectHost: string = ""
  gConnectPort: string = "6667"
  gConnectNick: string = ""
  gConnectUseTls: bool = false
  gConnectPassword: string = ""
  gConnectSaslUser: string = ""
  gConnectSaslPass: string = ""

  # Tab completion
  gCompletionSuggestions: seq[string] = @[]
  gCompletionActive: bool = false
  gCompletionIndex: int = -1

  # Config persistence
  gConfigPath: string = ""
  gInitialized: bool = false
  gPollActive: bool = false

  # Ignore list and highlight words
  gIgnoreList: seq[string] = @[]
  gHighlightWords: seq[string] = @[]

  # Event loop side: IRC connections (only accessed from event loop thread)
  gConnections: seq[IrcConnection]

# ============================================================
# mIRC color parsing
# ============================================================

const mircColorHex: array[16, string] = [
  "#FFFFFF",  #  0 white
  "#000000",  #  1 black
  "#00007F",  #  2 navy
  "#009300",  #  3 green
  "#FF0000",  #  4 red
  "#7F0000",  #  5 maroon
  "#9C009C",  #  6 purple
  "#FC7F00",  #  7 orange
  "#FFFF00",  #  8 yellow
  "#00FC00",  #  9 lime
  "#009393",  # 10 teal
  "#00FFFF",  # 11 cyan
  "#0000FC",  # 12 blue
  "#FF00FF",  # 13 magenta
  "#7F7F7F",  # 14 grey
  "#D2D2D2",  # 15 light grey
]

proc parseSpans(text: string): seq[MessageSpan] =
  ## Parse mIRC color/formatting codes and URLs into spans.
  var spans: seq[MessageSpan] = @[]
  var curFg = ""
  var curBg = ""
  var curBold = false
  var curItalic = false
  var curUnderline = false
  var curStrikethrough = false
  var buf = ""
  var i = 0

  # Pre-detect URLs
  let urlPrefixes = ["https://", "http://", "ftp://"]

  proc flush() =
    if buf.len > 0:
      spans.add(MessageSpan(text: buf, fg: curFg, bg: curBg,
        bold: curBold, italic: curItalic, underline: curUnderline,
        strikethrough: curStrikethrough, link: ""))
      buf = ""

  proc tryUrl(): bool =
    for prefix in urlPrefixes:
      if i + prefix.len <= text.len and
         text[i ..< i + prefix.len].toLowerAscii == prefix:
        flush()
        let start = i
        i += prefix.len
        while i < text.len and text[i] notin {' ', '\t', '\n', '\r', '<', '>', '"'}:
          inc i
        while i > start and text[i - 1] in {'.', ',', ')', ';', ':', '!', '?', '\''}:
          dec i
        let url = text[start ..< i]
        spans.add(MessageSpan(text: url, fg: "", bg: "", bold: false,
          italic: false, underline: true, strikethrough: false, link: url))
        return true
    return false

  while i < text.len:
    let ch = text[i]
    case ch
    of '\x02':  # Bold toggle
      flush()
      curBold = not curBold
      inc i
    of '\x1D':  # Italic toggle
      flush()
      curItalic = not curItalic
      inc i
    of '\x1F':  # Underline toggle
      flush()
      curUnderline = not curUnderline
      inc i
    of '\x1E':  # Strikethrough toggle
      flush()
      curStrikethrough = not curStrikethrough
      inc i
    of '\x16':  # Reverse toggle (swap fg/bg)
      flush()
      swap(curFg, curBg)
      inc i
    of '\x0F':  # Reset
      flush()
      curFg = ""
      curBg = ""
      curBold = false
      curItalic = false
      curUnderline = false
      curStrikethrough = false
      inc i
    of '\x11':  # Monospace (skip control)
      inc i
    of '\x03':  # mIRC color
      flush()
      inc i
      if i < text.len and text[i] in {'0'..'9'}:
        var fg = ord(text[i]) - ord('0')
        inc i
        if i < text.len and text[i] in {'0'..'9'}:
          fg = fg * 10 + ord(text[i]) - ord('0')
          inc i
        if fg >= 0 and fg <= 15:
          curFg = mircColorHex[fg]
        if i < text.len and text[i] == ',':
          if i + 1 < text.len and text[i + 1] in {'0'..'9'}:
            inc i
            var bg = ord(text[i]) - ord('0')
            inc i
            if i < text.len and text[i] in {'0'..'9'}:
              bg = bg * 10 + ord(text[i]) - ord('0')
              inc i
            if bg >= 0 and bg <= 15:
              curBg = mircColorHex[bg]
      else:
        curFg = ""
        curBg = ""
    of '\x04':  # Hex color \x04RRGGBB[,RRGGBB]
      flush()
      let hexStart = i + 1
      var j = hexStart
      var fgDigits = 0
      while j < text.len and text[j] in {'0'..'9', 'a'..'f', 'A'..'F'} and fgDigits < 6:
        inc j; inc fgDigits
      if fgDigits == 6:
        curFg = "#" & text[hexStart ..< j].toUpperAscii
        i = j
        if i < text.len and text[i] == ',':
          var k = i + 1
          var bgDigits = 0
          while k < text.len and text[k] in {'0'..'9', 'a'..'f', 'A'..'F'} and bgDigits < 6:
            inc k; inc bgDigits
          if bgDigits == 6:
            curBg = "#" & text[i + 1 ..< k].toUpperAscii
            i = k
      else:
        inc i
    of 'h', 'H', 'f', 'F':
      if not tryUrl():
        buf.add(ch)
        inc i
    else:
      buf.add(ch)
      inc i

  flush()
  return spans

proc spansToJson(spans: seq[MessageSpan]): string =
  ## Convert spans to compact JSON array.
  var arr = newJArray()
  for s in spans:
    var obj = newJObject()
    obj["t"] = %s.text
    if s.fg.len > 0:
      obj["fg"] = %s.fg
    if s.bg.len > 0:
      obj["bg"] = %s.bg
    if s.bold:
      obj["b"] = %true
    if s.italic:
      obj["i"] = %true
    if s.underline:
      obj["u"] = %true
    if s.strikethrough:
      obj["s"] = %true
    if s.link.len > 0:
      obj["link"] = %s.link
    arr.add(obj)
  $arr

# ============================================================
# Memory helpers (same pattern as todo bridge)
# ============================================================

proc bridgeAlloc(size: csize_t): pointer {.cdecl.} =
  if size <= 0:
    return nil
  allocShared(size)

proc bridgeFree(p: pointer) {.cdecl.} =
  if p != nil:
    deallocShared(p)

proc writeBlob(value: openArray[byte]): GUIBridgeBuffer =
  if value.len == 0:
    return GUIBridgeBuffer(data: nil, len: 0)
  let mem = cast[ptr uint8](bridgeAlloc(value.len.csize_t))
  if mem == nil:
    return GUIBridgeBuffer(data: nil, len: 0)
  copyMem(mem, unsafeAddr value[0], value.len)
  GUIBridgeBuffer(data: mem, len: value.len.uint32)

proc toBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  if text.len > 0:
    copyMem(addr result[0], unsafeAddr text[0], text.len)

# ============================================================
# Payload decoding
# ============================================================

proc decodeLeU32(data: ptr UncheckedArray[uint8], offset: int): uint32 =
  uint32(data[offset]) or
  (uint32(data[offset + 1]) shl 8) or
  (uint32(data[offset + 2]) shl 16) or
  (uint32(data[offset + 3]) shl 24)

proc decodeActionTag(payload: ptr uint8, payloadLen: uint32): uint32 =
  if payload == nil or payloadLen < 4:
    return high(uint32)
  let bytes = cast[ptr UncheckedArray[uint8]](payload)
  decodeLeU32(bytes, 0)

proc decodeStateJson(payload: ptr uint8, payloadLen: uint32): string =
  if payload == nil or payloadLen < 8:
    return ""
  let bytes = cast[ptr UncheckedArray[uint8]](payload)
  let declaredLen = int(decodeLeU32(bytes, 4))
  if declaredLen <= 0:
    return ""
  let availableLen = int(payloadLen) - 8
  if availableLen <= 0:
    return ""
  let takeLen = min(declaredLen, availableLen)
  result = newString(takeLen)
  copyMem(addr result[0], addr bytes[8], takeLen)

proc jsonString(node: JsonNode, key: string, defaultValue: string): string =
  if node.kind != JObject or key notin node:
    return defaultValue
  let value = node[key]
  if value.kind == JString:
    return value.getStr()
  defaultValue

proc jsonInt(node: JsonNode, key: string, defaultValue: int): int =
  if node.kind != JObject or key notin node:
    return defaultValue
  let value = node[key]
  case value.kind
  of JInt:
    value.getInt()
  of JFloat:
    value.getFloat().int
  of JString:
    try:
      parseInt(value.getStr())
    except ValueError:
      defaultValue
  else:
    defaultValue

proc jsonBool(node: JsonNode, key: string, defaultValue: bool): bool =
  if node.kind != JObject or key notin node:
    return defaultValue
  let value = node[key]
  case value.kind
  of JBool:
    value.getBool()
  of JInt:
    value.getInt() != 0
  of JString:
    case value.getStr().toLowerAscii()
    of "true", "1", "yes", "on":
      true
    of "false", "0", "no", "off":
      false
    else:
      defaultValue
  else:
    defaultValue

# ============================================================
# Config persistence
# ============================================================

proc configDir(): string =
  getConfigDir() / "cps-irc"

proc guiConfigPath(): string =
  configDir() / "gui-config.json"

proc saveConfig() =
  let dir = configDir()
  if not dirExists(dir):
    createDir(dir)
  var root = newJObject()
  var servers = newJArray()
  for s in gServers:
    var obj = newJObject()
    obj["name"] = %s.name
    obj["host"] = %s.host
    obj["port"] = %s.port
    obj["nick"] = %s.nick
    obj["useTls"] = %s.useTls
    if s.password.len > 0:
      obj["password"] = %s.password
    if s.saslUser.len > 0:
      obj["saslUser"] = %s.saslUser
    if s.saslPass.len > 0:
      obj["saslPass"] = %s.saslPass
    if s.autoJoinChannels.len > 0:
      var chArr = newJArray()
      for ch in s.autoJoinChannels:
        chArr.add(%ch)
      obj["channels"] = chArr
    servers.add(obj)
  root["servers"] = servers
  root["showUserList"] = %gShowUserList
  if gIgnoreList.len > 0:
    var ign = newJArray()
    for n in gIgnoreList: ign.add(%n)
    root["ignoreList"] = ign
  if gHighlightWords.len > 0:
    var hl = newJArray()
    for w in gHighlightWords: hl.add(%w)
    root["highlightWords"] = hl
  try:
    writeFile(guiConfigPath(), $root)
  except CatchableError:
    discard

proc loadConfig() =
  let path = guiConfigPath()
  if not fileExists(path):
    return
  try:
    let parsed = parseJson(readFile(path))
    if parsed.kind != JObject:
      return
    gShowUserList = jsonBool(parsed, "showUserList", true)
    if "servers" in parsed and parsed["servers"].kind == JArray:
      # Clear existing non-connected servers to avoid duplicates on reload
      var keepServers: seq[ServerState] = @[]
      for s in gServers:
        if s.connected or s.connecting:
          keepServers.add(s)
      gServers = keepServers

      for item in parsed["servers"].items:
        if item.kind != JObject:
          continue
        let host = jsonString(item, "host", "")
        if host.len == 0:
          continue
        # Skip if a server with this host already exists (e.g., already connected)
        var exists = false
        for s in gServers:
          if s.host == host:
            exists = true
            break
        if exists:
          continue
        var autoJoin: seq[string] = @[]
        if "channels" in item and item["channels"].kind == JArray:
          for ch in item["channels"].items:
            if ch.kind == JString and ch.getStr().len > 0:
              autoJoin.add(ch.getStr())
        let s = ServerState(
          id: gNextServerId,
          name: jsonString(item, "name", host),
          host: host,
          port: jsonInt(item, "port", 6667),
          nick: jsonString(item, "nick", "cpsuser"),
          useTls: jsonBool(item, "useTls", false),
          password: jsonString(item, "password", ""),
          saslUser: jsonString(item, "saslUser", ""),
          saslPass: jsonString(item, "saslPass", ""),
          autoJoinChannels: autoJoin,
          connected: false,
          connecting: false,
          lagMs: -1,
          isAway: false,
        )
        gServers.add(s)
        inc gNextServerId
    # Load ignore list
    if "ignoreList" in parsed and parsed["ignoreList"].kind == JArray:
      gIgnoreList = @[]
      for item in parsed["ignoreList"].items:
        if item.kind == JString and item.getStr().len > 0:
          gIgnoreList.add(item.getStr().toLowerAscii)
    # Load highlight words
    if "highlightWords" in parsed and parsed["highlightWords"].kind == JArray:
      gHighlightWords = @[]
      for item in parsed["highlightWords"].items:
        if item.kind == JString and item.getStr().len > 0:
          gHighlightWords.add(item.getStr().toLowerAscii)
  except CatchableError:
    discard

# ============================================================
# State helpers
# ============================================================

proc serverKey(serverId: int): string =
  $serverId

proc channelKey(serverId: int, channelName: string): string =
  $serverId & ":" & channelName

proc serverLabel(host: string): string =
  ## Derive a short label from a hostname (e.g. "irc.libera.chat" → "libera")
  let parts = host.split('.')
  if parts.len >= 2: parts[^2]
  else: host

proc findServerIdx(serverId: int): int =
  for i in 0 ..< gServers.len:
    if gServers[i].id == serverId:
      return i
  -1

proc activeServerIdx(): int =
  findServerIdx(gActiveServerId)

proc ensureChannel(serverId: int, channelName: string) =
  let sk = serverKey(serverId)
  if sk notin gChannels:
    gChannels[sk] = @[]
  var found = false
  for ch in gChannels[sk]:
    if ch.name == channelName:
      found = true
      break
  if not found:
    gChannels[sk].add(ChannelState(
      id: gNextChannelId,
      serverId: serverId,
      name: channelName,
      topic: "",
      unread: 0,
      mentions: 0,
      userCount: 0,
    ))
    inc gNextChannelId

proc addMessage(serverId: int, channelName: string, kind: string,
                nick: string, text: string, isMention: bool, isOwn: bool) =
  let ck = channelKey(serverId, channelName)
  if ck notin gMessages:
    gMessages[ck] = @[]
  let spans = parseSpans(text)
  let ts = now().format("HH:mm")
  gMessages[ck].add(MessageState(
    id: gNextMessageId,
    kind: kind,
    nick: nick,
    text: text,
    timestamp: ts,
    isMention: isMention,
    isOwn: isOwn,
    spans: spansToJson(spans),
  ))
  inc gNextMessageId
  # Cap messages
  if gMessages[ck].len > MaxMessagesPerChannel:
    gMessages[ck].delete(0)

  # Update unread/mention counts if not active channel
  if serverId != gActiveServerId or channelName != gActiveChannelName:
    let sk = serverKey(serverId)
    if sk in gChannels:
      for i in 0 ..< gChannels[sk].len:
        if gChannels[sk][i].name == channelName:
          inc gChannels[sk][i].unread
          if isMention:
            inc gChannels[sk][i].mentions
          break

proc addSystemMessage(serverId: int, channelName: string, text: string) =
  addMessage(serverId, channelName, "system", "", text, false, false)

proc addErrorMessage(serverId: int, channelName: string, text: string) =
  addMessage(serverId, channelName, "error", "", text, false, false)

# ============================================================
# Slash command parsing
# ============================================================

proc handleSlashCommand(serverId: int, text: string): bool =
  ## Returns true if handled as command, false if should be sent as message.
  let stripped = text.strip()
  if stripped.len == 0 or stripped[0] != '/':
    return false
  let spaceIdx = stripped.find(' ')
  let cmd = if spaceIdx >= 0: stripped[0 ..< spaceIdx].toLowerAscii
            else: stripped.toLowerAscii
  let args = if spaceIdx >= 0: stripped[spaceIdx + 1 .. ^1].strip()
             else: ""

  case cmd
  of "/join":
    if args.len > 0:
      var channel = args.split(' ')[0]
      if channel[0] != '#':
        channel = "#" & channel
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdJoinChannel,
          serverId: serverId, text: channel))
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /join #channel")
    return true

  of "/part":
    let channel = if args.len > 0: args.split(' ')[0]
                  else: gActiveChannelName
    if channel.len > 0 and channel != ServerChannel:
      let reason = if args.len > 0 and args.find(' ') >= 0:
                     args[args.find(' ') + 1 .. ^1]
                   else: ""
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdPartChannel,
          serverId: serverId, text: channel, text2: reason))
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /part [#channel] [reason]")
    return true

  of "/nick":
    if args.len > 0:
      let newNick = args.split(' ')[0]
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdChangeNick,
          serverId: serverId, text: newNick))
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /nick newnick")
    return true

  of "/msg", "/query":
    let parts = args.split(' ', 1)
    if parts.len >= 2:
      let target = parts[0]
      let msg = parts[1]
      # Open a query window
      ensureChannel(serverId, target)
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdSendMessage,
          serverId: serverId, text: msg, text2: target))
      addMessage(serverId, target, "normal",
        gServers[findServerIdx(serverId)].nick, msg, false, true)
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /msg nick message")
    return true

  of "/me":
    if args.len > 0 and gActiveChannelName.len > 0:
      # Send as CTCP ACTION via raw command
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdSendRaw,
          serverId: serverId,
          text: "PRIVMSG " & gActiveChannelName & " :\x01ACTION " & args & "\x01"))
      let si = findServerIdx(serverId)
      let myNick = if si >= 0: gServers[si].nick else: "me"
      addMessage(serverId, gActiveChannelName, "action", myNick, args, false, true)
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /me action text")
    return true

  of "/topic":
    if gActiveChannelName.len > 0 and gActiveChannelName != ServerChannel:
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdSetTopic,
          serverId: serverId, text: args, text2: gActiveChannelName))
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /topic new topic text")
    return true

  of "/quit":
    withLock gLock:
      gCommandQueue.add(BridgeCommand(kind: cmdQuit,
        serverId: serverId, text: args))
    return true

  of "/raw":
    if args.len > 0:
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdSendRaw,
          serverId: serverId, text: args))
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /raw IRC COMMAND")
    return true

  of "/away":
    if args.len > 0:
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdSetAway,
          serverId: serverId, text: args))
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /away reason")
    return true

  of "/back":
    withLock gLock:
      gCommandQueue.add(BridgeCommand(kind: cmdClearAway,
        serverId: serverId))
    return true

  of "/disconnect":
    withLock gLock:
      gCommandQueue.add(BridgeCommand(kind: cmdDisconnect,
        serverId: serverId))
    return true

  of "/close":
    if gActiveChannelName.len > 0 and gActiveChannelName != ServerChannel:
      # Part the channel if it starts with # and remove from state
      if gActiveChannelName[0] == '#':
        withLock gLock:
          gCommandQueue.add(BridgeCommand(kind: cmdPartChannel,
            serverId: serverId, text: gActiveChannelName))
      let sk = serverKey(serverId)
      if sk in gChannels:
        for i in countdown(gChannels[sk].len - 1, 0):
          if gChannels[sk][i].name == gActiveChannelName:
            gChannels[sk].delete(i)
            break
      let ck = channelKey(serverId, gActiveChannelName)
      gMessages.del(ck)
      gUsers.del(ck)
      # Switch to first remaining channel or server
      if sk in gChannels and gChannels[sk].len > 0:
        gActiveChannelName = gChannels[sk][0].name
      else:
        gActiveChannelName = ServerChannel
    return true

  of "/clear":
    if gActiveChannelName.len > 0:
      let ck = channelKey(serverId, gActiveChannelName)
      gMessages[ck] = @[]
    return true

  of "/whois":
    if args.len > 0:
      let target = args.split(' ')[0]
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdSendRaw,
          serverId: serverId, text: "WHOIS " & target))
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /whois nick")
    return true

  of "/mode":
    if args.len > 0:
      let target = if gActiveChannelName != ServerChannel: gActiveChannelName else: ""
      let modeStr = args
      if target.len > 0:
        withLock gLock:
          gCommandQueue.add(BridgeCommand(kind: cmdSendRaw,
            serverId: serverId, text: "MODE " & target & " " & modeStr))
      else:
        withLock gLock:
          gCommandQueue.add(BridgeCommand(kind: cmdSendRaw,
            serverId: serverId, text: "MODE " & modeStr))
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /mode [+|-]modes [params]")
    return true

  of "/notice":
    let parts = args.split(' ', 1)
    if parts.len >= 2:
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdSendRaw,
          serverId: serverId, text: "NOTICE " & parts[0] & " :" & parts[1]))
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /notice target message")
    return true

  of "/ignore":
    if args.len > 0:
      let nick = args.split(' ')[0].toLowerAscii
      if nick notin gIgnoreList:
        gIgnoreList.add(nick)
        saveConfig()
      addSystemMessage(serverId, gActiveChannelName, "Ignoring: " & nick)
    else:
      if gIgnoreList.len > 0:
        addSystemMessage(serverId, gActiveChannelName,
          "Ignore list: " & gIgnoreList.join(", "))
      else:
        addSystemMessage(serverId, gActiveChannelName, "Ignore list is empty")
    return true

  of "/unignore":
    if args.len > 0:
      let nick = args.split(' ')[0].toLowerAscii
      let idx = gIgnoreList.find(nick)
      if idx >= 0:
        gIgnoreList.delete(idx)
        saveConfig()
        addSystemMessage(serverId, gActiveChannelName, "Unignored: " & nick)
      else:
        addErrorMessage(serverId, gActiveChannelName, nick & " is not in ignore list")
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /unignore nick")
    return true

  of "/highlight":
    if args.len > 0:
      let parts = args.split(' ', 1)
      case parts[0].toLowerAscii
      of "add":
        if parts.len >= 2 and parts[1].len > 0:
          let word = parts[1].toLowerAscii
          if word notin gHighlightWords:
            gHighlightWords.add(word)
            saveConfig()
          addSystemMessage(serverId, gActiveChannelName, "Highlight added: " & word)
        else:
          addErrorMessage(serverId, gActiveChannelName, "Usage: /highlight add word")
      of "remove":
        if parts.len >= 2 and parts[1].len > 0:
          let word = parts[1].toLowerAscii
          let idx = gHighlightWords.find(word)
          if idx >= 0:
            gHighlightWords.delete(idx)
            saveConfig()
            addSystemMessage(serverId, gActiveChannelName, "Highlight removed: " & word)
          else:
            addErrorMessage(serverId, gActiveChannelName, word & " is not in highlights")
      of "list":
        if gHighlightWords.len > 0:
          addSystemMessage(serverId, gActiveChannelName,
            "Highlights: " & gHighlightWords.join(", "))
        else:
          addSystemMessage(serverId, gActiveChannelName, "Highlight list is empty")
      else:
        addErrorMessage(serverId, gActiveChannelName,
          "Usage: /highlight add|remove|list [word]")
    else:
      if gHighlightWords.len > 0:
        addSystemMessage(serverId, gActiveChannelName,
          "Highlights: " & gHighlightWords.join(", "))
      else:
        addSystemMessage(serverId, gActiveChannelName, "Highlight list is empty")
    return true

  of "/server":
    let parts = if args.len > 0: args.split(' ', 1) else: @["list"]
    case parts[0].toLowerAscii
    of "list":
      if gServers.len == 0:
        addSystemMessage(serverId, gActiveChannelName, "No servers configured")
      else:
        for s in gServers:
          let status = if s.connected: "connected" elif s.connecting: "connecting" else: "disconnected"
          addSystemMessage(serverId, gActiveChannelName,
            "[" & $s.id & "] " & s.name & " (" & s.host & ":" & $s.port & ") - " & status)
    of "switch":
      if parts.len >= 2:
        try:
          let targetId = parseInt(parts[1].strip())
          let idx = findServerIdx(targetId)
          if idx >= 0:
            gActiveServerId = targetId
            let sk = serverKey(targetId)
            if sk in gChannels and gChannels[sk].len > 0:
              gActiveChannelName = gChannels[sk][0].name
            else:
              gActiveChannelName = ServerChannel
          else:
            addErrorMessage(serverId, gActiveChannelName, "No server with id " & $targetId)
        except ValueError:
          addErrorMessage(serverId, gActiveChannelName, "Usage: /server switch <id>")
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /server list|switch <id>")
    return true

  of "/help":
    let helpText = "Commands: /join /part /nick /msg /me /topic /quit /raw /away /back /disconnect /close /clear /whois /mode /notice /ignore /unignore /highlight /server /help"
    addSystemMessage(serverId, gActiveChannelName, helpText)
    return true

  else:
    return false

# ============================================================
# Event loop thread: CPS coroutines
# ============================================================

proc findConnection(serverId: int): int =
  for i in 0 ..< gConnections.len:
    if gConnections[i].id == serverId:
      return i
  -1

proc ircEventForwarder(connId: int, client: IrcClient): CpsVoidFuture {.cps.} =
  ## Reads from client.events channel, converts to UiEvent, pushes to gEventQueue.
  while true:
    let event = await client.events.recv()
    var uiEvt = UiEvent(serverId: connId)

    case event.kind
    of iekPrivMsg:
      uiEvt.kind = uiNewMessage
      uiEvt.channel = event.pmTarget
      uiEvt.nick = event.pmSource
      uiEvt.text = event.pmText
      # Detect if it's a PM to us (not a channel)
      if event.pmTarget.len > 0 and event.pmTarget[0] != '#':
        uiEvt.channel = event.pmSource  # Show under sender's nick
      withLock gLock:
        gEventQueue.add(uiEvt)

    of iekNotice:
      uiEvt.kind = uiNewMessage
      uiEvt.channel = if event.pmTarget.len > 0 and event.pmTarget[0] == '#':
                         event.pmTarget
                       else: ServerChannel
      uiEvt.nick = event.pmSource
      uiEvt.text = event.pmText
      uiEvt.text2 = "notice"
      withLock gLock:
        gEventQueue.add(uiEvt)

    of iekJoin:
      uiEvt.kind = uiUserJoin
      uiEvt.channel = event.joinChannel
      uiEvt.nick = event.joinNick
      withLock gLock:
        gEventQueue.add(uiEvt)

    of iekPart:
      uiEvt.kind = uiUserPart
      uiEvt.channel = event.partChannel
      uiEvt.nick = event.partNick
      uiEvt.text = event.partReason
      withLock gLock:
        gEventQueue.add(uiEvt)

    of iekQuit:
      uiEvt.kind = uiUserQuit
      uiEvt.nick = event.quitNick
      uiEvt.text = event.quitReason
      withLock gLock:
        gEventQueue.add(uiEvt)

    of iekKick:
      uiEvt.kind = uiUserPart
      uiEvt.channel = event.kickChannel
      uiEvt.nick = event.kickNick
      uiEvt.text = "Kicked by " & event.kickBy & ": " & event.kickReason
      withLock gLock:
        gEventQueue.add(uiEvt)

    of iekNick:
      uiEvt.kind = uiUserNick
      uiEvt.nick = event.nickNew
      uiEvt.text2 = event.nickOld
      withLock gLock:
        gEventQueue.add(uiEvt)

    of iekMode:
      uiEvt.kind = uiModeChange
      uiEvt.channel = event.modeTarget
      uiEvt.text = event.modeChanges
      withLock gLock:
        gEventQueue.add(uiEvt)

    of iekTopic:
      uiEvt.kind = uiTopicChange
      uiEvt.channel = event.topicChannel
      uiEvt.text = event.topicText
      uiEvt.nick = event.topicBy
      withLock gLock:
        gEventQueue.add(uiEvt)

    of iekConnected:
      uiEvt.kind = uiConnected
      withLock gLock:
        gEventQueue.add(uiEvt)

    of iekDisconnected:
      uiEvt.kind = uiDisconnected
      uiEvt.text = event.reason
      withLock gLock:
        gEventQueue.add(uiEvt)

    of iekNumeric:
      case event.numCode
      of 353:  # RPL_NAMREPLY
        uiEvt.kind = uiUserList
        if event.numParams.len >= 2:
          uiEvt.channel = event.numParams[^2]
          uiEvt.users = event.numParams[^1].strip().split(' ')
        withLock gLock:
          gEventQueue.add(uiEvt)
      of 332:  # RPL_TOPIC
        uiEvt.kind = uiTopicChange
        if event.numParams.len >= 2:
          uiEvt.channel = event.numParams[1]
          uiEvt.text = event.numParams[^1]
        withLock gLock:
          gEventQueue.add(uiEvt)
      of 366:  # RPL_ENDOFNAMES - ignore
        discard
      of 376, 422:  # RPL_ENDOFMOTD, ERR_NOMOTD
        # MOTD finished, good time to signal fully connected
        discard
      else:
        # Forward other numerics as system messages
        if event.numParams.len > 0:
          uiEvt.kind = uiNewMessage
          uiEvt.channel = ServerChannel
          uiEvt.nick = ""
          uiEvt.text = $event.numCode & " " & event.numParams.join(" ")
          uiEvt.text2 = "numeric"
          withLock gLock:
            gEventQueue.add(uiEvt)

    of iekCtcp:
      if event.ctcpCommand == "ACTION":
        uiEvt.kind = uiNewMessage
        uiEvt.channel = event.ctcpTarget
        uiEvt.nick = event.ctcpSource
        uiEvt.text = event.ctcpArgs
        uiEvt.boolParam = true  # isAction flag
        # If target is not a channel, show under source nick
        if event.ctcpTarget.len > 0 and event.ctcpTarget[0] != '#':
          uiEvt.channel = event.ctcpSource
        withLock gLock:
          gEventQueue.add(uiEvt)
      else:
        discard  # VERSION, PING, etc. handled automatically

    of iekTyping:
      uiEvt.kind = uiTyping
      uiEvt.channel = event.typingTarget
      uiEvt.nick = event.typingNick
      uiEvt.boolParam = event.typingActive
      withLock gLock:
        gEventQueue.add(uiEvt)

    of iekPong:
      uiEvt.kind = uiLagUpdate
      uiEvt.intParam = client.lagMs
      withLock gLock:
        gEventQueue.add(uiEvt)

    of iekAway:
      uiEvt.kind = uiAwayChange
      uiEvt.nick = event.awayNick
      uiEvt.boolParam = event.awayMessage.len > 0
      uiEvt.text = event.awayMessage
      withLock gLock:
        gEventQueue.add(uiEvt)

    of iekError:
      uiEvt.kind = uiError
      uiEvt.text = event.errMsg
      withLock gLock:
        gEventQueue.add(uiEvt)

    of iekInvite:
      uiEvt.kind = uiNewMessage
      uiEvt.channel = ServerChannel
      uiEvt.nick = event.inviteNick
      uiEvt.text = event.inviteNick & " invited you to " & event.inviteChannel
      uiEvt.text2 = "system"
      withLock gLock:
        gEventQueue.add(uiEvt)

    else:
      discard

proc commandProcessor(): CpsVoidFuture {.cps.} =
  ## Runs on event loop thread. Drains command queue every 50ms.
  while true:
    var commands: seq[BridgeCommand]
    withLock gLock:
      commands = gCommandQueue
      gCommandQueue.setLen(0)

    for cmd in commands:
      case cmd.kind
      of cmdConnect:
        let connId = cmd.serverId
        let existing = findConnection(connId)
        if existing >= 0:
          continue  # Already connected

        var cfg = newIrcClientConfig(
          host = cmd.text,
          port = cmd.intParam,
          nick = cmd.text2,
        )
        cfg.useTls = cmd.boolParam
        cfg.autoReconnect = true
        cfg.maxReconnectAttempts = 0
        if cmd.text3.len > 0:
          cfg.password = cmd.text3
        if cmd.text4.len > 0 and cmd.text5.len > 0:
          cfg.saslUsername = cmd.text4
          cfg.saslPassword = cmd.text5

        let client = newIrcClient(cfg)
        gConnections.add(IrcConnection(
          id: connId,
          client: client,
          config: cfg,
          channels: @[],
          myNick: cmd.text2,
        ))

        # Spawn client and event forwarder as concurrent tasks on event loop
        discard spawn client.run()
        discard spawn ircEventForwarder(connId, client)

      of cmdDisconnect:
        let idx = findConnection(cmd.serverId)
        if idx >= 0:
          discard spawn gConnections[idx].client.disconnect()

      of cmdSendMessage:
        let idx = findConnection(cmd.serverId)
        if idx >= 0:
          discard spawn gConnections[idx].client.privMsg(cmd.text2, cmd.text)

      of cmdJoinChannel:
        let idx = findConnection(cmd.serverId)
        if idx >= 0:
          discard spawn gConnections[idx].client.joinChannel(cmd.text)

      of cmdPartChannel:
        let idx = findConnection(cmd.serverId)
        if idx >= 0:
          discard spawn gConnections[idx].client.partChannel(cmd.text, cmd.text2)

      of cmdChangeNick:
        let idx = findConnection(cmd.serverId)
        if idx >= 0:
          discard spawn gConnections[idx].client.changeNick(cmd.text)

      of cmdSetAway:
        let idx = findConnection(cmd.serverId)
        if idx >= 0:
          discard spawn gConnections[idx].client.sendMessage("AWAY", cmd.text)

      of cmdClearAway:
        let idx = findConnection(cmd.serverId)
        if idx >= 0:
          discard spawn gConnections[idx].client.sendMessage("AWAY")

      of cmdSetTopic:
        let idx = findConnection(cmd.serverId)
        if idx >= 0:
          discard spawn gConnections[idx].client.sendMessage("TOPIC", cmd.text2, cmd.text)

      of cmdSendRaw:
        let idx = findConnection(cmd.serverId)
        if idx >= 0:
          let rawText = cmd.text.strip()
          let spaceIdx = rawText.find(' ')
          if spaceIdx < 0:
            discard spawn gConnections[idx].client.sendMessage(rawText)
          else:
            let rawCmd = rawText[0 ..< spaceIdx]
            let rest = rawText[spaceIdx + 1 .. ^1]
            discard spawn gConnections[idx].client.sendMessage(rawCmd, rest)

      of cmdSwitchServer:
        discard  # Handled on main thread

      of cmdReconnect:
        let idx = findConnection(cmd.serverId)
        if idx >= 0:
          let oldCfg = gConnections[idx].config
          let oldClient = gConnections[idx].client
          oldClient.config.autoReconnect = false
          discard spawn oldClient.disconnect()
          gConnections.delete(idx)
          var cfg = oldCfg
          cfg.autoReconnect = true
          let client = newIrcClient(cfg)
          gConnections.add(IrcConnection(
            id: cmd.serverId,
            client: client,
            config: cfg,
            channels: @[],
            myNick: cfg.nick,
          ))
          discard spawn client.run()
          discard spawn ircEventForwarder(cmd.serverId, client)

      of cmdQuit:
        let idx = findConnection(cmd.serverId)
        if idx >= 0:
          let reason = if cmd.text.len > 0: cmd.text else: "Goodbye"
          discard spawn gConnections[idx].client.quit(reason)

    await cpsSleep(50)

proc eventLoopMain() {.thread.} =
  ## Event loop thread entry point.
  {.cast(gcsafe).}:
    runCps(commandProcessor())

proc ensureEventLoop() =
  if not gEventLoopRunning:
    gEventLoopRunning = true
    createThread(gEventLoopThread, eventLoopMain)

# ============================================================
# Process UI events from the event loop thread
# ============================================================

proc processUiEvents() =
  ## Drain gEventQueue and update main-thread state.
  var events: seq[UiEvent]
  withLock gLock:
    events = gEventQueue
    gEventQueue.setLen(0)

  for evt in events:
    let si = findServerIdx(evt.serverId)

    case evt.kind
    of uiConnected:
      if si >= 0:
        gServers[si].connected = true
        gServers[si].connecting = false
        gStatusText = "Connected to " & gServers[si].host
        # Ensure server channel exists
        ensureChannel(evt.serverId, ServerChannel)
        if gActiveServerId == evt.serverId and gActiveChannelName.len == 0:
          gActiveChannelName = ServerChannel
        addSystemMessage(evt.serverId, ServerChannel,
          "Connected to " & gServers[si].host)
        # Auto-join saved channels
        if gServers[si].autoJoinChannels.len > 0:
          for ch in gServers[si].autoJoinChannels:
            withLock gLock:
              gCommandQueue.add(BridgeCommand(kind: cmdJoinChannel,
                serverId: evt.serverId, text: ch))

    of uiDisconnected:
      if si >= 0:
        gServers[si].connected = false
        gServers[si].connecting = false
        gServers[si].lagMs = -1
        gStatusText = "Disconnected from " & gServers[si].host
        addSystemMessage(evt.serverId, ServerChannel,
          "Disconnected: " & evt.text)

    of uiNewMessage:
      let channelName = if evt.channel.len > 0: evt.channel else: ServerChannel
      ensureChannel(evt.serverId, channelName)

      # Check ignore list
      if evt.nick.len > 0 and evt.nick.toLowerAscii in gIgnoreList:
        continue  # Skip messages from ignored users

      # Detect mentions (own nick + highlight words)
      var isMention = false
      if si >= 0 and evt.nick.len > 0:
        let textLower = evt.text.toLowerAscii
        let myNick = gServers[si].nick.toLowerAscii
        isMention = textLower.contains(myNick)
        if not isMention:
          for word in gHighlightWords:
            if textLower.contains(word):
              isMention = true
              break

      let isOwn = si >= 0 and evt.nick == gServers[si].nick

      let msgKind = if evt.boolParam: "action"
                    elif evt.text2 == "notice": "notice"
                    elif evt.text2 == "system" or evt.text2 == "numeric": "system"
                    elif evt.nick.len == 0: "system"
                    else: "normal"
      addMessage(evt.serverId, channelName, msgKind,
                 evt.nick, evt.text, isMention, isOwn)

    of uiUserJoin:
      ensureChannel(evt.serverId, evt.channel)
      let ck = channelKey(evt.serverId, evt.channel)
      if ck notin gUsers:
        gUsers[ck] = @[]
      # Add user if not already present
      var found = false
      for u in gUsers[ck]:
        if u.nick == evt.nick:
          found = true
          break
      if not found:
        gUsers[ck].add(UserState(nick: evt.nick, prefix: "", isAway: false))
      # Update user count
      let sk = serverKey(evt.serverId)
      if sk in gChannels:
        for i in 0 ..< gChannels[sk].len:
          if gChannels[sk][i].name == evt.channel:
            gChannels[sk][i].userCount = gUsers[ck].len
            break
      addSystemMessage(evt.serverId, evt.channel,
        evt.nick & " has joined " & evt.channel)

    of uiUserPart:
      let ck = channelKey(evt.serverId, evt.channel)
      if ck in gUsers:
        for i in countdown(gUsers[ck].len - 1, 0):
          if gUsers[ck][i].nick == evt.nick:
            gUsers[ck].delete(i)
            break
      let sk = serverKey(evt.serverId)
      if sk in gChannels:
        for i in 0 ..< gChannels[sk].len:
          if gChannels[sk][i].name == evt.channel:
            if ck in gUsers:
              gChannels[sk][i].userCount = gUsers[ck].len
            break
      let reason = if evt.text.len > 0: " (" & evt.text & ")" else: ""
      addSystemMessage(evt.serverId, evt.channel,
        evt.nick & " has left " & evt.channel & reason)

    of uiUserQuit:
      # Remove user from all channels on this server
      let sk = serverKey(evt.serverId)
      if sk in gChannels:
        for ch in gChannels[sk]:
          let ck = channelKey(evt.serverId, ch.name)
          if ck in gUsers:
            for i in countdown(gUsers[ck].len - 1, 0):
              if gUsers[ck][i].nick == evt.nick:
                gUsers[ck].delete(i)
                break
      let reason = if evt.text.len > 0: " (" & evt.text & ")" else: ""
      # Only show quit in active channel to avoid spam
      if gActiveServerId == evt.serverId and gActiveChannelName.len > 0:
        addSystemMessage(evt.serverId, gActiveChannelName,
          evt.nick & " has quit" & reason)

    of uiUserNick:
      # Update nick in all channels
      let sk = serverKey(evt.serverId)
      if sk in gChannels:
        for ch in gChannels[sk]:
          let ck = channelKey(evt.serverId, ch.name)
          if ck in gUsers:
            for i in 0 ..< gUsers[ck].len:
              if gUsers[ck][i].nick == evt.text2:  # old nick
                gUsers[ck][i].nick = evt.nick       # new nick
                break
      # Check if it's our nick
      if si >= 0 and evt.text2 == gServers[si].nick:
        gServers[si].nick = evt.nick
      addSystemMessage(evt.serverId, gActiveChannelName,
        evt.text2 & " is now known as " & evt.nick)

    of uiTopicChange:
      let sk = serverKey(evt.serverId)
      if sk in gChannels:
        for i in 0 ..< gChannels[sk].len:
          if gChannels[sk][i].name == evt.channel:
            gChannels[sk][i].topic = evt.text
            break
      if evt.serverId == gActiveServerId and evt.channel == gActiveChannelName:
        gCurrentTopic = evt.text
      if evt.nick.len > 0:
        addSystemMessage(evt.serverId, evt.channel,
          evt.nick & " changed the topic to: " & evt.text)

    of uiUserList:
      ensureChannel(evt.serverId, evt.channel)
      let ck = channelKey(evt.serverId, evt.channel)
      if ck notin gUsers:
        gUsers[ck] = @[]
      # Parse user entries (may have @, +, %, ~, & prefixes)
      for raw in evt.users:
        if raw.len == 0:
          continue
        var nick = raw
        var prefix = ""
        if nick[0] in {'@', '+', '%', '~', '&'}:
          prefix = $nick[0]
          nick = nick[1..^1]
        if nick.len == 0:
          continue
        var found = false
        for i in 0 ..< gUsers[ck].len:
          if gUsers[ck][i].nick == nick:
            gUsers[ck][i].prefix = prefix
            found = true
            break
        if not found:
          gUsers[ck].add(UserState(nick: nick, prefix: prefix, isAway: false))
      # Update user count
      let sk = serverKey(evt.serverId)
      if sk in gChannels:
        for i in 0 ..< gChannels[sk].len:
          if gChannels[sk][i].name == evt.channel:
            gChannels[sk][i].userCount = gUsers[ck].len
            break

    of uiModeChange:
      addSystemMessage(evt.serverId, evt.channel,
        "Mode " & evt.channel & " " & evt.text)

    of uiError:
      addErrorMessage(evt.serverId,
        if gActiveChannelName.len > 0: gActiveChannelName else: ServerChannel,
        evt.text)

    of uiLagUpdate:
      if si >= 0:
        gServers[si].lagMs = evt.intParam

    of uiAwayChange:
      if si >= 0 and evt.nick == gServers[si].nick:
        gServers[si].isAway = evt.boolParam
      # Update away status in user lists
      let sk = serverKey(evt.serverId)
      if sk in gChannels:
        for ch in gChannels[sk]:
          let ck = channelKey(evt.serverId, ch.name)
          if ck in gUsers:
            for i in 0 ..< gUsers[ck].len:
              if gUsers[ck][i].nick == evt.nick:
                gUsers[ck][i].isAway = evt.boolParam
                break

    of uiChannelListUpdate:
      discard

    of uiTyping:
      if evt.serverId == gActiveServerId and evt.channel == gActiveChannelName:
        if evt.boolParam:
          gTypingText = evt.nick & " is typing..."
        else:
          if gTypingText.startsWith(evt.nick):
            gTypingText = ""

    of uiNickChange:
      discard

# ============================================================
# Tab completion
# ============================================================

proc computeCompletions() =
  gCompletionSuggestions = @[]
  gCompletionActive = false
  gCompletionIndex = -1

  if gInputText.len == 0 or gActiveServerId < 0:
    return

  # Find the partial word being completed
  let lastSpace = gInputText.rfind(' ')
  let partial = if lastSpace >= 0: gInputText[lastSpace + 1 .. ^1]
                else: gInputText
  if partial.len == 0:
    return

  let partialLower = partial.toLowerAscii

  # Search in current channel's user list
  let ck = channelKey(gActiveServerId, gActiveChannelName)
  if ck in gUsers:
    for u in gUsers[ck]:
      if u.nick.toLowerAscii.startsWith(partialLower):
        gCompletionSuggestions.add(u.nick)

  gCompletionSuggestions.sort()
  if gCompletionSuggestions.len > 0:
    gCompletionActive = true
    gCompletionIndex = 0

proc acceptCompletion() =
  if not gCompletionActive or gCompletionIndex < 0 or
     gCompletionIndex >= gCompletionSuggestions.len:
    return

  let completed = gCompletionSuggestions[gCompletionIndex]
  let lastSpace = gInputText.rfind(' ')
  let prefix = if lastSpace >= 0: gInputText[0 .. lastSpace] else: ""
  let suffix = if lastSpace < 0: ": " else: " "
  gInputText = prefix & completed & suffix
  gCompletionSuggestions = @[]
  gCompletionActive = false
  gCompletionIndex = -1

# ============================================================
# State patch builder
# ============================================================

proc buildPatch(includeEditableFields: bool): seq[byte] =
  ## Build JSON state patch. When includeEditableFields is false (Poll),
  ## user-editable text fields are excluded to avoid overwriting in-progress typing.
  var patch = newJObject()

  # Servers
  var serversArr = newJArray()
  for s in gServers:
    var obj = newJObject()
    obj["id"] = %s.id
    obj["name"] = %s.name
    obj["host"] = %s.host
    obj["port"] = %s.port
    obj["nick"] = %s.nick
    obj["useTls"] = %s.useTls
    obj["connected"] = %s.connected
    obj["connecting"] = %s.connecting
    obj["lagMs"] = %s.lagMs
    obj["isAway"] = %s.isAway
    serversArr.add(obj)
  patch["servers"] = serversArr
  patch["activeServerId"] = %gActiveServerId

  # Channels for active server
  var channelsArr = newJArray()
  let sk = serverKey(gActiveServerId)
  if sk in gChannels:
    for ch in gChannels[sk]:
      var obj = newJObject()
      obj["id"] = %ch.id
      obj["serverId"] = %ch.serverId
      obj["name"] = %ch.name
      obj["topic"] = %ch.topic
      obj["unread"] = %ch.unread
      obj["mentions"] = %ch.mentions
      obj["userCount"] = %ch.userCount
      channelsArr.add(obj)
  patch["channels"] = channelsArr
  patch["activeChannelName"] = %gActiveChannelName

  # Messages for active channel
  var messagesArr = newJArray()
  let ck = channelKey(gActiveServerId, gActiveChannelName)
  if ck in gMessages:
    for m in gMessages[ck]:
      var obj = newJObject()
      obj["id"] = %m.id
      obj["kind"] = %m.kind
      obj["nick"] = %m.nick
      obj["text"] = %m.text
      obj["timestamp"] = %m.timestamp
      obj["isMention"] = %m.isMention
      obj["isOwn"] = %m.isOwn
      obj["spans"] = %m.spans
      messagesArr.add(obj)
  patch["messages"] = messagesArr

  # Users for active channel
  var usersArr = newJArray()
  if ck in gUsers:
    var sortedUsers = gUsers[ck]
    sortedUsers.sort(proc(a, b: UserState): int =
      # Sort by prefix rank then alphabetically
      let prefixRank = proc(p: string): int =
        case p
        of "~": 0
        of "&": 1
        of "@": 2
        of "%": 3
        of "+": 4
        else: 5
      let ra = prefixRank(a.prefix)
      let rb = prefixRank(b.prefix)
      if ra != rb:
        return cmp(ra, rb)
      cmp(a.nick.toLowerAscii, b.nick.toLowerAscii)
    )
    for u in sortedUsers:
      var obj = newJObject()
      obj["nick"] = %u.nick
      obj["prefix"] = %u.prefix
      obj["isAway"] = %u.isAway
      usersArr.add(obj)
  patch["users"] = usersArr

  # Scalar state (non-editable — always included)
  patch["showUserList"] = %gShowUserList
  patch["showConnectForm"] = %gShowConnectForm
  patch["statusText"] = %gStatusText
  patch["typingText"] = %gTypingText
  patch["currentTopic"] = %gCurrentTopic
  patch["currentUserCount"] = %gCurrentUserCount
  patch["lastMessageId"] = %(gNextMessageId - 1)
  patch["pollActive"] = %gPollActive

  # Completion state
  var compArr = newJArray()
  for s in gCompletionSuggestions:
    compArr.add(%s)
  patch["completionSuggestions"] = compArr
  patch["completionActive"] = %gCompletionActive
  patch["completionIndex"] = %gCompletionIndex

  # User-editable fields — only included when the bridge explicitly modifies them
  # (not during Poll, to avoid overwriting in-progress typing)
  if includeEditableFields:
    patch["inputText"] = %gInputText
    patch["connectHost"] = %gConnectHost
    patch["connectPort"] = %gConnectPort
    patch["connectNick"] = %gConnectNick
    patch["connectUseTls"] = %gConnectUseTls
    patch["connectPassword"] = %gConnectPassword
    patch["connectSaslUser"] = %gConnectSaslUser
    patch["connectSaslPass"] = %gConnectSaslPass

  toBytes($patch)

# ============================================================
# Snapshot decoding
# ============================================================

proc syncFromSnapshot(payload: ptr uint8, payloadLen: uint32) =
  let stateJson = decodeStateJson(payload, payloadLen)
  if stateJson.len == 0:
    return
  try:
    let node = parseJson(stateJson)
    gInputText = jsonString(node, "inputText", gInputText)
    gConnectHost = jsonString(node, "connectHost", gConnectHost)
    gConnectPort = jsonString(node, "connectPort", gConnectPort)
    gConnectNick = jsonString(node, "connectNick", gConnectNick)
    gConnectUseTls = jsonBool(node, "connectUseTls", gConnectUseTls)
    gConnectPassword = jsonString(node, "connectPassword", gConnectPassword)
    gConnectSaslUser = jsonString(node, "connectSaslUser", gConnectSaslUser)
    gConnectSaslPass = jsonString(node, "connectSaslPass", gConnectSaslPass)

    # Sync activeServerId and activeChannelName if provided
    let snapServerId = jsonInt(node, "activeServerId", gActiveServerId)
    if snapServerId >= 0 and findServerIdx(snapServerId) >= 0:
      gActiveServerId = snapServerId
    let snapChannel = jsonString(node, "activeChannelName", "")
    if snapChannel.len > 0:
      gActiveChannelName = snapChannel
  except CatchableError:
    discard

# ============================================================
# Init
# ============================================================

proc ensureInit() =
  if not gInitialized:
    initLock(gLock)
    gInitialized = true

# ============================================================
# Update active channel context
# ============================================================

proc syncActiveChannelContext() =
  ## Update current topic and user count from active channel state.
  if gActiveServerId < 0 or gActiveChannelName.len == 0:
    gCurrentTopic = ""
    gCurrentUserCount = 0
    return
  let sk = serverKey(gActiveServerId)
  if sk in gChannels:
    for ch in gChannels[sk]:
      if ch.name == gActiveChannelName:
        gCurrentTopic = ch.topic
        gCurrentUserCount = ch.userCount
        return
  gCurrentTopic = ""
  gCurrentUserCount = 0

# ============================================================
# Action names (for diagnostics)
# ============================================================

proc actionName(tag: uint32): string =
  case tag
  of tagPoll: "Poll"
  of tagStartPoll: "StartPoll"
  of tagConnect: "Connect"
  of tagDisconnect: "Disconnect"
  of tagSwitchServer: "SwitchServer"
  of tagReconnect: "Reconnect"
  of tagSwitchChannel: "SwitchChannel"
  of tagJoinChannel: "JoinChannel"
  of tagPartChannel: "PartChannel"
  of tagCloseChannel: "CloseChannel"
  of tagSendMessage: "SendMessage"
  of tagUpdateInput: "UpdateInput"
  of tagToggleUserList: "ToggleUserList"
  of tagShowConnectForm: "ShowConnectForm"
  of tagHideConnectForm: "HideConnectForm"
  of tagTabComplete: "TabComplete"
  of tagAcceptCompletion: "AcceptCompletion"
  of tagSaveServer: "SaveServer"
  of tagRemoveServer: "RemoveServer"
  of tagLoadConfig: "LoadConfig"
  else: "Unknown"

# ============================================================
# Dispatch
# ============================================================

proc bridgeDispatch(payload: ptr uint8, payloadLen: uint32,
                    outp: ptr GUIBridgeDispatchOutput): int32 {.cdecl.} =
  ensureInit()

  let actionTag = decodeActionTag(payload, payloadLen)
  syncFromSnapshot(payload, payloadLen)

  case actionTag
  of tagPoll:
    processUiEvents()
    syncActiveChannelContext()
    # Clear unread for active channel
    if gActiveServerId >= 0 and gActiveChannelName.len > 0:
      let sk = serverKey(gActiveServerId)
      if sk in gChannels:
        for i in 0 ..< gChannels[sk].len:
          if gChannels[sk][i].name == gActiveChannelName:
            gChannels[sk][i].unread = 0
            gChannels[sk][i].mentions = 0
            break

  of tagStartPoll:
    gPollActive = true

  of tagConnect:
    ensureEventLoop()
    let host = gConnectHost.strip()
    let nick = gConnectNick.strip()
    if host.len == 0:
      gStatusText = "Host is required"
    elif nick.len == 0:
      gStatusText = "Nickname is required"
    else:
      var port = try: parseInt(gConnectPort) except: 6667
      # Auto-adjust port for TLS: if user left the default non-TLS port, switch to 6697
      if gConnectUseTls and port == 6667:
        port = 6697
      let serverId = gNextServerId
      inc gNextServerId

      gServers.add(ServerState(
        id: serverId,
        name: serverLabel(host),
        host: host,
        port: port,
        nick: nick,
        useTls: gConnectUseTls,
        password: gConnectPassword,
        saslUser: gConnectSaslUser,
        saslPass: gConnectSaslPass,
        autoJoinChannels: @[],
        connected: false,
        connecting: true,
        lagMs: -1,
        isAway: false,
      ))
      gActiveServerId = serverId
      gActiveChannelName = ServerChannel
      ensureChannel(serverId, ServerChannel)
      addSystemMessage(serverId, ServerChannel,
        "Connecting to " & host & ":" & $port & "...")

      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdConnect,
          serverId: serverId, text: host, text2: nick,
          text3: gConnectPassword, text4: gConnectSaslUser,
          text5: gConnectSaslPass,
          intParam: port, boolParam: gConnectUseTls))

      gShowConnectForm = false
      gStatusText = "Connecting to " & host & "..."

  of tagDisconnect:
    if gActiveServerId >= 0:
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdDisconnect,
          serverId: gActiveServerId))
      gStatusText = "Disconnecting..."

  of tagSwitchServer:
    # Server ID passed via snapshot's activeServerId
    syncActiveChannelContext()
    let si = findServerIdx(gActiveServerId)
    if si >= 0:
      gStatusText = gServers[si].name
      # Select first channel of the server
      let sk = serverKey(gActiveServerId)
      if sk in gChannels and gChannels[sk].len > 0:
        gActiveChannelName = gChannels[sk][0].name
      else:
        gActiveChannelName = ServerChannel

  of tagReconnect:
    if gActiveServerId >= 0:
      ensureEventLoop()
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdReconnect,
          serverId: gActiveServerId))
      gStatusText = "Reconnecting..."
      let si = findServerIdx(gActiveServerId)
      if si >= 0:
        gServers[si].connecting = true

  of tagSwitchChannel:
    # Channel name is in snapshot
    syncActiveChannelContext()
    # Clear unread
    if gActiveServerId >= 0 and gActiveChannelName.len > 0:
      let sk = serverKey(gActiveServerId)
      if sk in gChannels:
        for i in 0 ..< gChannels[sk].len:
          if gChannels[sk][i].name == gActiveChannelName:
            gChannels[sk][i].unread = 0
            gChannels[sk][i].mentions = 0
            break

  of tagJoinChannel:
    if gActiveServerId >= 0:
      # Parse channel from input text (e.g., "/join #channel")
      let text = gInputText.strip()
      var channel = ""
      if text.startsWith("/join "):
        channel = text[6..^1].strip().split(' ')[0]
      elif text.startsWith("#"):
        channel = text.split(' ')[0]
      if channel.len > 0:
        if channel[0] != '#':
          channel = "#" & channel
        ensureEventLoop()
        withLock gLock:
          gCommandQueue.add(BridgeCommand(kind: cmdJoinChannel,
            serverId: gActiveServerId, text: channel))
        gInputText = ""
      else:
        gStatusText = "Enter a channel name (e.g., #nim)"

  of tagPartChannel:
    if gActiveServerId >= 0 and gActiveChannelName.len > 0 and
       gActiveChannelName != ServerChannel:
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdPartChannel,
          serverId: gActiveServerId, text: gActiveChannelName))

  of tagCloseChannel:
    if gActiveServerId >= 0 and gActiveChannelName.len > 0 and
       gActiveChannelName != ServerChannel:
      if gActiveChannelName[0] == '#':
        withLock gLock:
          gCommandQueue.add(BridgeCommand(kind: cmdPartChannel,
            serverId: gActiveServerId, text: gActiveChannelName))
      let sk = serverKey(gActiveServerId)
      if sk in gChannels:
        for i in countdown(gChannels[sk].len - 1, 0):
          if gChannels[sk][i].name == gActiveChannelName:
            gChannels[sk].delete(i)
            break
      let ck = channelKey(gActiveServerId, gActiveChannelName)
      gMessages.del(ck)
      gUsers.del(ck)
      if sk in gChannels and gChannels[sk].len > 0:
        gActiveChannelName = gChannels[sk][0].name
      else:
        gActiveChannelName = ServerChannel
      syncActiveChannelContext()

  of tagSendMessage:
    if gActiveServerId >= 0 and gActiveChannelName.len > 0:
      let text = gInputText.strip()
      if text.len > 0:
        if not handleSlashCommand(gActiveServerId, text):
          # Regular message
          if gActiveChannelName != ServerChannel:
            ensureEventLoop()
            withLock gLock:
              gCommandQueue.add(BridgeCommand(kind: cmdSendMessage,
                serverId: gActiveServerId, text: text,
                text2: gActiveChannelName))
            let si = findServerIdx(gActiveServerId)
            let myNick = if si >= 0: gServers[si].nick else: "me"
            addMessage(gActiveServerId, gActiveChannelName, "normal",
                       myNick, text, false, true)
          else:
            addErrorMessage(gActiveServerId, ServerChannel,
              "Cannot send messages to server window. Use /msg or switch to a channel.")
        gInputText = ""
      gCompletionActive = false
      gCompletionSuggestions = @[]

  of tagUpdateInput:
    # Input text already synced from snapshot
    gCompletionActive = false
    gCompletionSuggestions = @[]

  of tagToggleUserList:
    gShowUserList = not gShowUserList

  of tagShowConnectForm:
    gShowConnectForm = true

  of tagHideConnectForm:
    gShowConnectForm = false

  of tagTabComplete:
    computeCompletions()

  of tagAcceptCompletion:
    acceptCompletion()

  of tagSaveServer:
    # Update active server's autoJoinChannels from current channel list, then save
    if gActiveServerId >= 0:
      let si = findServerIdx(gActiveServerId)
      if si >= 0:
        let sk = serverKey(gActiveServerId)
        var chans: seq[string] = @[]
        if sk in gChannels:
          for ch in gChannels[sk]:
            if ch.name != ServerChannel and ch.name.len > 0 and ch.name[0] == '#':
              chans.add(ch.name)
        gServers[si].autoJoinChannels = chans
    saveConfig()
    gStatusText = "Server saved"

  of tagRemoveServer:
    # Remove the active server from saved config
    if gActiveServerId >= 0:
      let si = findServerIdx(gActiveServerId)
      if si >= 0:
        let name = gServers[si].name
        # Disconnect first if connected
        if gServers[si].connected:
          withLock gLock:
            gCommandQueue.add(BridgeCommand(kind: cmdDisconnect,
              serverId: gActiveServerId))
        # Remove from state
        gServers.delete(si)
        # Clean up channels/messages/users
        let sk = serverKey(gActiveServerId)
        if sk in gChannels:
          for ch in gChannels[sk]:
            let ck = channelKey(gActiveServerId, ch.name)
            gMessages.del(ck)
            gUsers.del(ck)
          gChannels.del(sk)
        # Select another server or clear
        if gServers.len > 0:
          gActiveServerId = gServers[0].id
          let newSk = serverKey(gActiveServerId)
          if newSk in gChannels and gChannels[newSk].len > 0:
            gActiveChannelName = gChannels[newSk][0].name
          else:
            gActiveChannelName = ""
        else:
          gActiveServerId = -1
          gActiveChannelName = ""
        saveConfig()
        gStatusText = "Removed server: " & name

  of tagLoadConfig:
    loadConfig()
    if gServers.len == 0:
      # First launch — show connect form with helpful defaults
      gShowConnectForm = true
      if gConnectHost.len == 0:
        gConnectHost = "irc.libera.chat"
      if gConnectPort.len == 0:
        gConnectPort = "6667"
      if gConnectNick.len == 0:
        gConnectNick = "cpsuser_" & $((epochTime().int) mod 10000)
      gStatusText = "Welcome! Connect to an IRC server to get started."
    else:
      # Auto-select first server
      if gActiveServerId < 0:
        gActiveServerId = gServers[0].id
      gStatusText = "Config loaded (" & $gServers.len & " servers)"

  else:
    gStatusText = "Unknown action (" & $actionTag & ")"

  syncActiveChannelContext()

  # Update status text from active server state
  if gActiveServerId >= 0:
    let si = findServerIdx(gActiveServerId)
    if si >= 0:
      if gServers[si].connected:
        var status = "Connected to " & gServers[si].host
        if gServers[si].lagMs >= 0:
          status.add(" | Lag: " & $gServers[si].lagMs & "ms")
        if gServers[si].isAway:
          status.add(" | Away")
        gStatusText = status
      elif gServers[si].connecting:
        gStatusText = "Connecting to " & gServers[si].host & "..."

  # During Poll, don't include user-editable text fields in the patch
  # to avoid overwriting in-progress typing (race condition with 100ms timer)
  let includeEditable = actionTag != tagPoll and actionTag != tagStartPoll
  let patchBlob = buildPatch(includeEditable)
  let diagBlob = toBytes("nim.irc action=" & actionName(actionTag))

  if outp != nil:
    outp[].statePatch = writeBlob(patchBlob)
    outp[].effects = writeBlob(@[])
    outp[].emittedActions = writeBlob(@[])
    outp[].diagnostics = writeBlob(diagBlob)

  0'i32

# ============================================================
# FFI export
# ============================================================

var gBridgeTable = GUIBridgeFunctionTable(
  abiVersion: guiBridgeAbiVersion,
  alloc: bridgeAlloc,
  free: bridgeFree,
  dispatch: bridgeDispatch
)

proc gui_bridge_get_table(): ptr GUIBridgeFunctionTable {.cdecl, exportc, dynlib.} =
  addr gBridgeTable
