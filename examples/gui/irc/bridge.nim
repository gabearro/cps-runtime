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
import cps/io/unix
import cps/io/buffered
import cps/io/streams
import cps/bouncer/bridge except ChannelState
import cps/bouncer/types as bouncerTypes

import std/[json, os, strutils, locks, tables, times, algorithm, atomics, posix, options]

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
  tagDisconnectServer = 20'u32
  tagReconnectServer = 21'u32
  tagConnectServer = 22'u32
  tagRemoveServerById = 23'u32
  tagWhoisUser = 24'u32
  tagStartDm = 25'u32
  tagIgnoreUser = 26'u32
  tagHighlightUser = 27'u32
  tagShowTransfers = 28'u32
  tagHideTransfers = 29'u32
  tagAcceptTransfer = 30'u32
  tagDeclineTransfer = 31'u32
  tagShowJoinChannel = 32'u32   # owner swift — not dispatched to bridge
  tagHideJoinChannel = 33'u32   # owner swift — not dispatched to bridge
  tagSubmitJoinChannel = 34'u32
  tagSelectUser = 35'u32
  tagRequestWhois = 36'u32
  tagHideWhois = 37'u32         # owner swift
  tagRetryTransfer = 38'u32
  tagInputChanged = 39'u32
  tagCompletionSelect = 40'u32
  tagShowSettings = 41'u32       # owner swift
  tagHideSettings = 42'u32       # owner swift
  tagSetFontSize = 43'u32
  tagSetMessageDensity = 44'u32
  tagSetTimestampFormat = 45'u32
  tagUpdateSidebarFilter = 46'u32
  tagToggleAway = 47'u32
  tagShowChannelInfo = 48'u32    # owner swift
  tagHideChannelInfo = 49'u32    # owner swift
  tagToggleSearch = 50'u32       # owner swift
  tagClearSearch = 51'u32        # owner swift
  tagUpdateSearch = 52'u32
  tagSelectNetwork = 53'u32      # owner swift
  tagHistoryUp = 54'u32
  tagHistoryDown = 55'u32
  tagMuteJoinPart = 56'u32
  tagSetSmartFilter = 57'u32
  tagSetSmartFilterTimeout = 58'u32
  tagSwitchChannelByIndex = 59'u32
  tagPrevChannel = 60'u32
  tagNextChannel = 61'u32
  tagNextUnreadChannel = 62'u32
  tagClearScrollback = 63'u32
  tagShowChannelSwitcher = 64'u32  # owner swift
  tagHideChannelSwitcher = 65'u32  # owner swift
  tagSwitchChannelFromSwitcher = 66'u32
  tagSetNickColor = 67'u32
  tagPrevServer = 68'u32
  tagNextServer = 69'u32
  tagPrevUnreadChannel = 70'u32
  tagShowKeybindSheet = 71'u32     # owner swift
  tagHideKeybindSheet = 72'u32     # owner swift
  tagUpdateKeybind = 73'u32
  tagResetKeybinds = 74'u32
  tagSetQuitMessage = 75'u32
  tagAppShutdown = 76'u32
  tagSetLoggingEnabled = 77'u32
  tagSetLogDir = 78'u32
  tagSetBouncerPassword = 79'u32
  tagSetShowUserList = 80'u32
  tagUpdateIgnoreList = 81'u32
  tagUpdateHighlightWords = 82'u32
  tagUpdateJoinPartMuteList = 83'u32
  tagOpenKeyboardShortcuts = 84'u32
  tagEditServer = 85'u32
  tagHideServerEditor = 86'u32       # owner swift
  tagSaveServerConfig = 87'u32
  tagDeleteServer = 88'u32
  tagDuplicateServer = 89'u32
  tagMoveServer = 90'u32
  tagMoveChannel = 91'u32

# ============================================================
# Bridge types
# ============================================================

type
  BridgeCommandKind = enum
    cmdConnect, cmdDisconnect, cmdSendMessage, cmdJoinChannel, cmdPartChannel,
    cmdChangeNick, cmdSetAway, cmdClearAway, cmdSetTopic, cmdSendRaw,
    cmdSwitchServer, cmdReconnect, cmdQuit, cmdAcceptDcc, cmdRetryDcc,
    cmdShutdownAll

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
    uiNickChange, uiChghost, uiSetname, uiAccount, uiBatchComplete,
    uiMonOnline, uiMonOffline, uiDccProgress, uiDccComplete, uiDccFailed

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
    isChannel: bool
    isDm: bool

  MessageState = object
    id: int
    kind: string
    nick: string
    text: string
    timestamp: string
    timestampFull: string
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
    fromBouncer: bool          ## True if this connection is managed by the bouncer

  BouncerBridgeSession = ref object
    stream: UnixStream
    reader: BufferedReader
    serverNames: seq[string]   ## Servers available from bouncer
    lastSeenIds: Table[string, int64]
    connected: bool

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
    getNotifyFd: proc(): int32 {.cdecl.}
    waitShutdown: proc(timeoutMs: int32): int32 {.cdecl.}

  DccTransferState = enum
    dccPending, dccActive, dccDone, dccDeclined, dccFailed

  DccTransfer = object
    id: int
    nick: string
    filename: string
    filesize: int64
    state: DccTransferState
    progress: float
    bytesReceived: int64
    errorText: string
    outputPath: string
    serverId: int
    ip: uint32
    port: int

  KeybindDef = object
    id: string
    key: string
    modifiers: string
    label: string
    actionTag: uint32

const
  guiBridgeAbiVersion = 4'u32
  MaxMessagesPerChannel = 500
  ServerChannel = "*server*"

  defaultKeybinds = @[
    KeybindDef(id: "channelSwitcher",  key: "k", modifiers: "command",       label: "Channel Switcher",     actionTag: tagShowChannelSwitcher),
    KeybindDef(id: "prevChannel",      key: "[", modifiers: "command",       label: "Previous Channel",     actionTag: tagPrevChannel),
    KeybindDef(id: "nextChannel",      key: "]", modifiers: "command",       label: "Next Channel",         actionTag: tagNextChannel),
    KeybindDef(id: "nextUnread",       key: "n", modifiers: "command",       label: "Next Unread Channel",  actionTag: tagNextUnreadChannel),
    KeybindDef(id: "prevUnread",       key: "p", modifiers: "command",       label: "Prev Unread Channel",  actionTag: tagPrevUnreadChannel),
    KeybindDef(id: "prevServer",       key: "[", modifiers: "command+shift", label: "Previous Server",      actionTag: tagPrevServer),
    KeybindDef(id: "nextServer",       key: "]", modifiers: "command+shift", label: "Next Server",          actionTag: tagNextServer),
    KeybindDef(id: "joinChannel",      key: "t", modifiers: "command",       label: "Join Channel",         actionTag: tagShowJoinChannel),
    KeybindDef(id: "closeChannel",     key: "w", modifiers: "command",       label: "Close Channel",        actionTag: tagCloseChannel),
    KeybindDef(id: "clearScrollback",  key: "l", modifiers: "command",       label: "Clear Scrollback",     actionTag: tagClearScrollback),
    KeybindDef(id: "toggleUserList",   key: "u", modifiers: "command+shift", label: "Toggle User List",     actionTag: tagToggleUserList),
    KeybindDef(id: "connectToServer",  key: "c", modifiers: "command+shift", label: "Connect to Server",    actionTag: tagShowConnectForm),
    KeybindDef(id: "channel1",         key: "1", modifiers: "command",       label: "Jump to Channel 1",    actionTag: tagSwitchChannelByIndex),
    KeybindDef(id: "channel2",         key: "2", modifiers: "command",       label: "Jump to Channel 2",    actionTag: tagSwitchChannelByIndex),
    KeybindDef(id: "channel3",         key: "3", modifiers: "command",       label: "Jump to Channel 3",    actionTag: tagSwitchChannelByIndex),
    KeybindDef(id: "channel4",         key: "4", modifiers: "command",       label: "Jump to Channel 4",    actionTag: tagSwitchChannelByIndex),
    KeybindDef(id: "channel5",         key: "5", modifiers: "command",       label: "Jump to Channel 5",    actionTag: tagSwitchChannelByIndex),
    KeybindDef(id: "channel6",         key: "6", modifiers: "command",       label: "Jump to Channel 6",    actionTag: tagSwitchChannelByIndex),
    KeybindDef(id: "channel7",         key: "7", modifiers: "command",       label: "Jump to Channel 7",    actionTag: tagSwitchChannelByIndex),
    KeybindDef(id: "channel8",         key: "8", modifiers: "command",       label: "Jump to Channel 8",    actionTag: tagSwitchChannelByIndex),
    KeybindDef(id: "channel9",         key: "9", modifiers: "command",       label: "Jump to Channel 9",    actionTag: tagSwitchChannelByIndex),
  ]

# ============================================================
# Global state
# ============================================================

var
  gLock: Lock
  gCommandQueue: seq[BridgeCommand]
  gEventQueue: seq[UiEvent]
  gEventLoopThread: Thread[void]
  gEventLoopRunning: bool
  gShutdownLock: Lock
  gShutdownComplete: bool

  # IRC state (modified during bridgeDispatch on main thread)
  gServers: seq[ServerState]
  gChannels: Table[string, seq[ChannelState]]
  gMessages: Table[string, seq[MessageState]]
  gUsers: Table[string, seq[UserState]]
  gActiveServerId: int = -1
  gActiveChannelName: string = ""
  gLastChannelPerServer: Table[int, string]  ## Remembers last active channel per server
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

  # Tab completion / @-mention autocomplete
  gCompletionSuggestions: seq[string] = @[]
  gCompletionActive: bool = false
  gCompletionIndex: int = -1
  gMentionAtPos: int = -1  # byte position of '@' trigger (-1 = tab-complete mode)
  gCompletionSelectIndex: int = -1  # for CompletionSelect action

  # Input history (up/down arrow for previous messages)
  gInputHistory: seq[string] = @[]       # sent messages, newest last
  gHistoryIndex: int = -1                 # -1 = not browsing, 0..len-1 = position
  gSavedInput: string = ""               # unsent input saved when starting to browse

  # Config persistence
  gConfigPath: string = ""
  gInitialized: bool = false
  gPollActive: bool = false
  gDirty: bool = true  ## Set when event-loop thread pushes UI events; cleared after buildPatch

  # Ignore list, highlight words, join/part mute list
  gIgnoreList: seq[string] = @[]
  gHighlightWords: seq[string] = @[]
  gJoinPartMuteList: seq[string] = @[]

  # Nick color overrides: nick (lowercase) → hex color string (e.g. "#FF453A")
  gNickColors: Table[string, string]

  # Smart filter: auto-hide join/part/quit for users who haven't spoken recently
  gSmartFilterEnabled: bool = true
  gSmartFilterTimeout: int = 1800  # seconds (default 30 min)
  gLastSpoke: Table[string, Table[string, float]] = initTable[string, Table[string, float]]()

  # Keybind config: user-remappable keyboard shortcuts
  gKeybinds: seq[KeybindDef] = defaultKeybinds

  # Typing state: (serverId:channel) → seq[(nick, epochTime)]
  gTypingUsers: Table[string, seq[tuple[nick: string, time: float]]]

  # DCC transfers
  gDccTransfers: seq[DccTransfer]
  gNextDccId: int = 1
  gShowTransfers: bool = false
  gActionTransferId: int = -1

  # Join channel
  gJoinChannelText: string = ""

  # Channel switcher
  gChannelSwitcherText: string = ""

  # WHOIS
  gWhoisNick: string = ""
  gWhoisInfo: string = ""       # Accumulated WHOIS lines
  gWhoisActive: bool = false    # Whether we're collecting WHOIS data
  gSelectedUserNick: string = ""

  # Logging
  gLoggingEnabled: bool = false
  gLogDir: string = ""

  # JSON strings for list fields (synced from Swift snapshot, parsed on update actions)
  gIgnoreListJson: string = "[]"
  gHighlightWordsJson: string = "[]"
  gJoinPartMuteListJson: string = "[]"

  # Action params (set by reducer before dispatch)
  gActionServerId: int = -1
  gActionNick: string = ""
  gActionColor: string = ""
  gActionChannelName: string = ""

  # Servers that were intentionally disconnected (don't show as reconnecting)
  gIntentionalDisconnects: seq[int]

  # echo-message tracking: set of server IDs with echo-message capability
  gEchoMessageServers: seq[int]

  # Event loop side: IRC connections (only accessed from event loop thread)
  gConnections: seq[IrcConnection]

  # Quit message
  gQuitMessage: string = "Goodbye"  ## QUIT reason shown to other IRC users

  # Bouncer config
  gBouncerPassword: string = ""  ## Password for bouncer authentication

  # Server editor state
  gEditingServerId: int = -1
  gEditServerJson: string = "{}"

  # Bouncer session (only accessed from event loop thread)
  gBouncerSession: BouncerBridgeSession

  # Appearance settings (persisted)
  gFontSize: int = 13
  gMessageDensity: string = "comfortable"
  gTimestampFormat: string = "short"

  # Notification pipe: Nim writes when state changes, Swift monitors with DispatchSource
  gNotifyPipeRead: cint = -1
  gNotifyPipeWrite: cint = -1
  gNotifyPending: Atomic[bool]

# ============================================================
# Notification pipe
# ============================================================

proc notifySwift() =
  ## Coalesced pipe write to wake Swift's DispatchSource.
  ## Safe to call from any thread; at most one byte is in the pipe at a time.
  if gNotifyPipeWrite < 0: return
  if gNotifyPending.exchange(true, moAcquireRelease): return  # already signaled
  var buf: array[1, byte] = [1'u8]
  while true:
    let n = posix.write(gNotifyPipeWrite, addr buf[0], 1)
    if n == 1: return
    if osLastError().int == EINTR: continue
    return  # pipe full or error — already signaled

# ============================================================
# Event queue helpers
# ============================================================

proc pushEvent(evt: UiEvent) =
  ## Push a UI event and mark state dirty. Caller must hold gLock.
  gEventQueue.add(evt)
  gDirty = true
  notifySwift()

# ============================================================
# UTF-8 sanitization
# ============================================================

proc sanitizeUtf8(s: string): string =
  ## Replace invalid UTF-8 byte sequences with the Unicode replacement character
  ## (U+FFFD). IRC data is not guaranteed to be UTF-8, but JSON requires it.
  var i = 0
  while i < s.len:
    let b0 = s[i].uint8
    if b0 <= 0x7F:
      # ASCII
      result.add s[i]
      inc i
    elif (b0 and 0xE0'u8) == 0xC0'u8:
      # 2-byte sequence
      if i + 1 < s.len and (s[i+1].uint8 and 0xC0'u8) == 0x80'u8:
        # Check overlong: must encode >= U+0080
        let cp = ((b0.uint32 and 0x1F) shl 6) or (s[i+1].uint8.uint32 and 0x3F)
        if cp >= 0x80:
          result.add s[i]; result.add s[i+1]
        else:
          result.add "\xEF\xBF\xBD"  # replacement char
        i += 2
      else:
        result.add "\xEF\xBF\xBD"
        inc i
    elif (b0 and 0xF0'u8) == 0xE0'u8:
      # 3-byte sequence
      if i + 2 < s.len and
         (s[i+1].uint8 and 0xC0'u8) == 0x80'u8 and
         (s[i+2].uint8 and 0xC0'u8) == 0x80'u8:
        let cp = ((b0.uint32 and 0x0F) shl 12) or
                 ((s[i+1].uint8.uint32 and 0x3F) shl 6) or
                 (s[i+2].uint8.uint32 and 0x3F)
        if cp >= 0x800 and (cp < 0xD800 or cp > 0xDFFF):
          result.add s[i]; result.add s[i+1]; result.add s[i+2]
        else:
          result.add "\xEF\xBF\xBD"
        i += 3
      else:
        result.add "\xEF\xBF\xBD"
        inc i
    elif (b0 and 0xF8'u8) == 0xF0'u8:
      # 4-byte sequence
      if i + 3 < s.len and
         (s[i+1].uint8 and 0xC0'u8) == 0x80'u8 and
         (s[i+2].uint8 and 0xC0'u8) == 0x80'u8 and
         (s[i+3].uint8 and 0xC0'u8) == 0x80'u8:
        let cp = ((b0.uint32 and 0x07) shl 18) or
                 ((s[i+1].uint8.uint32 and 0x3F) shl 12) or
                 ((s[i+2].uint8.uint32 and 0x3F) shl 6) or
                 (s[i+3].uint8.uint32 and 0x3F)
        if cp >= 0x10000 and cp <= 0x10FFFF:
          result.add s[i]; result.add s[i+1]; result.add s[i+2]; result.add s[i+3]
        else:
          result.add "\xEF\xBF\xBD"
        i += 4
      else:
        result.add "\xEF\xBF\xBD"
        inc i
    else:
      # Continuation byte without leading byte, or invalid 0xFE/0xFF
      result.add "\xEF\xBF\xBD"
      inc i

# ============================================================
# mIRC color parsing
# ============================================================

## Dark-mode-friendly mIRC color palette.
## Original mIRC colors were designed for white backgrounds. We brighten
## dark colors (black, navy, maroon) so they remain legible on the dark
## chat background (~#141415).
const mircColorHex: array[16, string] = [
  "#E0E0E0",  #  0 white  → off-white (pure white is too harsh)
  "#8E8E93",  #  1 black  → medium grey (visible on dark bg)
  "#5E8ACE",  #  2 navy   → brighter blue
  "#32D74B",  #  3 green  → Apple green (bright, legible)
  "#FF453A",  #  4 red    → Apple red
  "#D4746A",  #  5 maroon → salmon (lightened)
  "#BF5AF2",  #  6 purple → Apple purple
  "#FF9F0A",  #  7 orange → Apple orange
  "#FFD60A",  #  8 yellow → Apple yellow
  "#30D158",  #  9 lime   → Apple green
  "#64D2FF",  # 10 teal   → bright teal
  "#5AC8FA",  # 11 cyan   → Apple cyan
  "#0A84FF",  # 12 blue   → Apple blue
  "#FF6EAA",  # 13 magenta → bright pink
  "#8E8E93",  # 14 grey
  "#C7C7CC",  # 15 light grey
]

proc stripMircCodes*(text: string): string =
  ## Strip mIRC color/formatting control codes, returning plain text.
  var i = 0
  while i < text.len:
    let ch = text[i]
    case ch
    of '\x02', '\x1D', '\x1F', '\x1E', '\x16', '\x0F', '\x11':
      inc i  # Skip formatting toggles
    of '\x03':
      inc i
      # Skip fg digits
      if i < text.len and text[i] in {'0'..'9'}:
        inc i
        if i < text.len and text[i] in {'0'..'9'}:
          inc i
      # Skip bg digits
      if i < text.len and text[i] == ',':
        if i + 1 < text.len and text[i + 1] in {'0'..'9'}:
          inc i  # skip comma
          inc i  # skip first bg digit
          if i < text.len and text[i] in {'0'..'9'}:
            inc i
    of '\x04':
      inc i
      # Skip hex color RRGGBB
      var hexCount = 0
      while i < text.len and hexCount < 6 and
            text[i] in {'0'..'9', 'A'..'F', 'a'..'f'}:
        inc i
        inc hexCount
      if i < text.len and text[i] == ',':
        inc i
        hexCount = 0
        while i < text.len and hexCount < 6 and
              text[i] in {'0'..'9', 'A'..'F', 'a'..'f'}:
          inc i
          inc hexCount
    else:
      result.add(ch)
      inc i

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
  root["fontSize"] = %gFontSize
  root["messageDensity"] = %gMessageDensity
  root["timestampFormat"] = %gTimestampFormat
  root["loggingEnabled"] = %gLoggingEnabled
  if gLogDir.len > 0:
    root["logDir"] = %gLogDir
  if gIgnoreList.len > 0:
    var ign = newJArray()
    for n in gIgnoreList: ign.add(%n)
    root["ignoreList"] = ign
  if gHighlightWords.len > 0:
    var hl = newJArray()
    for w in gHighlightWords: hl.add(%w)
    root["highlightWords"] = hl
  if gJoinPartMuteList.len > 0:
    var jpm = newJArray()
    for n in gJoinPartMuteList: jpm.add(%n)
    root["joinPartMuteList"] = jpm
  root["smartFilterEnabled"] = %gSmartFilterEnabled
  root["smartFilterTimeout"] = %gSmartFilterTimeout
  if gNickColors.len > 0:
    var nc = newJObject()
    for nick, color in gNickColors:
      nc[nick] = %color
    root["nickColors"] = nc
  if gQuitMessage.len > 0 and gQuitMessage != "Goodbye":
    root["quitMessage"] = %gQuitMessage
  if gBouncerPassword.len > 0:
    root["bouncerPassword"] = %gBouncerPassword
  # Only save non-default keybinds
  var customKeybinds = newJArray()
  for i, kb in gKeybinds:
    if i < defaultKeybinds.len:
      let def = defaultKeybinds[i]
      if kb.key != def.key or kb.modifiers != def.modifiers:
        var obj = newJObject()
        obj["id"] = %kb.id
        obj["key"] = %kb.key
        obj["modifiers"] = %kb.modifiers
        customKeybinds.add(obj)
    else:
      var obj = newJObject()
      obj["id"] = %kb.id
      obj["key"] = %kb.key
      obj["modifiers"] = %kb.modifiers
      customKeybinds.add(obj)
  if customKeybinds.len > 0:
    root["keybinds"] = customKeybinds
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
    gFontSize = jsonInt(parsed, "fontSize", 13)
    gMessageDensity = jsonString(parsed, "messageDensity", "comfortable")
    gTimestampFormat = jsonString(parsed, "timestampFormat", "short")
    gLoggingEnabled = jsonBool(parsed, "loggingEnabled", false)
    gLogDir = jsonString(parsed, "logDir", "")
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
    # Load join/part mute list
    if "joinPartMuteList" in parsed and parsed["joinPartMuteList"].kind == JArray:
      gJoinPartMuteList = @[]
      for item in parsed["joinPartMuteList"].items:
        if item.kind == JString and item.getStr().len > 0:
          gJoinPartMuteList.add(item.getStr().toLowerAscii)
    # Load smart filter settings
    gSmartFilterEnabled = jsonBool(parsed, "smartFilterEnabled", true)
    gSmartFilterTimeout = jsonInt(parsed, "smartFilterTimeout", 1800)
    # Load nick color overrides
    if "nickColors" in parsed and parsed["nickColors"].kind == JObject:
      gNickColors = initTable[string, string]()
      for nick, colorNode in parsed["nickColors"].pairs:
        if colorNode.kind == JString and colorNode.getStr().len > 0:
          gNickColors[nick.toLowerAscii] = colorNode.getStr()
    # Load quit message
    gQuitMessage = jsonString(parsed, "quitMessage", "Goodbye")
    # Load bouncer password
    gBouncerPassword = jsonString(parsed, "bouncerPassword", "")
    # Load custom keybinds (override defaults)
    gKeybinds = defaultKeybinds  # start from defaults
    if "keybinds" in parsed and parsed["keybinds"].kind == JArray:
      for item in parsed["keybinds"].items:
        if item.kind != JObject:
          continue
        let kbId = jsonString(item, "id", "")
        if kbId.len == 0:
          continue
        let kbKey = jsonString(item, "key", "")
        let kbMods = jsonString(item, "modifiers", "")
        if kbKey.len == 0:
          continue
        for i in 0 ..< gKeybinds.len:
          if gKeybinds[i].id == kbId:
            gKeybinds[i].key = kbKey
            gKeybinds[i].modifiers = kbMods
            break
  except CatchableError:
    discard

# ============================================================
# Forward declarations
proc updateTypingText()

# State helpers
# ============================================================

proc serverKey(serverId: int): string =
  $serverId

proc channelKey(serverId: int, channelName: string): string =
  $serverId & ":" & channelName.toLowerAscii

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

proc syncAutoJoinChannels(serverId: int) =
  ## Update autoJoinChannels from current channel list and save config.
  let si = findServerIdx(serverId)
  if si < 0: return
  let sk = serverKey(serverId)
  var chans: seq[string] = @[]
  if sk in gChannels:
    for ch in gChannels[sk]:
      if ch.name != ServerChannel and ch.name.len > 0 and ch.name[0] == '#':
        chans.add(ch.name)
  gServers[si].autoJoinChannels = chans
  saveConfig()

proc ensureChannel(serverId: int, channelName: string) =
  let sk = serverKey(serverId)
  if sk notin gChannels:
    gChannels[sk] = @[]
  # Case-insensitive lookup (IRC nicks and channels are case-insensitive)
  let nameLower = channelName.toLowerAscii
  for i in 0 ..< gChannels[sk].len:
    if gChannels[sk][i].name.toLowerAscii == nameLower:
      # Update display name to latest casing (e.g. "chanserv" → "ChanServ")
      if gChannels[sk][i].name != channelName and channelName != channelName.toLowerAscii:
        gChannels[sk][i].name = channelName
      return
  let isCh = channelName.len > 0 and channelName[0] == '#'
  let isDm = not isCh and channelName != ServerChannel
  gChannels[sk].add(ChannelState(
    id: gNextChannelId,
    serverId: serverId,
    name: channelName,
    topic: "",
    unread: 0,
    mentions: 0,
    userCount: 0,
    isChannel: isCh,
    isDm: isDm,
  ))
  inc gNextChannelId

proc ensureDmUsers(serverId: int, channelName: string, otherNick: string) =
  ## Populate gUsers for a DM channel with both participants.
  let ck = channelKey(serverId, channelName)
  if ck notin gUsers:
    gUsers[ck] = @[]
  let si = findServerIdx(serverId)
  let myNick = if si >= 0: gServers[si].nick else: ""
  for nick in [myNick, otherNick]:
    if nick.len == 0: continue
    var found = false
    for u in gUsers[ck]:
      if u.nick == nick:
        found = true
        break
    if not found:
      gUsers[ck].add(UserState(nick: nick, prefix: "", isAway: false))
  # Update userCount on ChannelState
  let sk = serverKey(serverId)
  if sk in gChannels:
    for i in 0 ..< gChannels[sk].len:
      if gChannels[sk][i].name.toLowerAscii == channelName.toLowerAscii:
        gChannels[sk][i].userCount = gUsers[ck].len
        break

proc logToFile(channelName: string, nick: string, text: string, kind: string) =
  ## Append a message to the per-channel log file.
  if not gLoggingEnabled or gLogDir.len == 0:
    return
  let sanitized = channelName.replace("/", "_").replace("\\", "_")
  let logPath = gLogDir / sanitized & ".log"
  let ts = now().format("yyyy-MM-dd HH:mm:ss")
  let line = case kind
    of "action": "[" & ts & "] * " & nick & " " & text
    of "system": "[" & ts & "] -- " & text
    of "error": "[" & ts & "] !! " & text
    else:
      if nick.len > 0: "[" & ts & "] <" & nick & "> " & text
      else: "[" & ts & "] " & text
  try:
    var f = open(logPath, fmAppend)
    f.writeLine(line)
    f.close()
  except CatchableError:
    discard

proc addMessage(serverId: int, channelName: string, kind: string,
                nick: string, text: string, isMention: bool, isOwn: bool) =
  let ck = channelKey(serverId, channelName)
  if ck notin gMessages:
    gMessages[ck] = @[]
  # Sanitize text to valid UTF-8 (IRC data may contain non-UTF-8 bytes)
  let safeText = sanitizeUtf8(text)
  let safeNick = sanitizeUtf8(nick)
  let spans = parseSpans(safeText)
  let t = now()
  let ts = t.format("HH:mm")
  let tsFull = t.format("yyyy-MM-dd HH:mm:ss")
  gMessages[ck].add(MessageState(
    id: gNextMessageId,
    kind: kind,
    nick: safeNick,
    text: safeText,
    timestamp: ts,
    timestampFull: tsFull,
    isMention: isMention,
    isOwn: isOwn,
    spans: spansToJson(spans),
  ))
  inc gNextMessageId
  logToFile(channelName, nick, text, kind)
  # Cap messages
  if gMessages[ck].len > MaxMessagesPerChannel:
    gMessages[ck].delete(0)

  # Update unread/mention counts if not active channel
  if serverId != gActiveServerId or channelName.toLowerAscii != gActiveChannelName.toLowerAscii:
    let sk = serverKey(serverId)
    if sk in gChannels:
      for i in 0 ..< gChannels[sk].len:
        if gChannels[sk][i].name.toLowerAscii == channelName.toLowerAscii:
          inc gChannels[sk][i].unread
          if isMention:
            inc gChannels[sk][i].mentions
          break

proc addSystemMessage(serverId: int, channelName: string, text: string) =
  addMessage(serverId, channelName, "system", "", text, false, false)

proc addErrorMessage(serverId: int, channelName: string, text: string) =
  addMessage(serverId, channelName, "error", "", text, false, false)

proc shouldSuppressJoinPart(nick: string, serverId: int, channelName: string): bool =
  ## Check if a join/part/quit notification for this nick should be suppressed.
  ## Returns true if the notification should be hidden.
  let nickLower = nick.toLowerAscii
  # Per-nick mute list always suppresses
  if nickLower in gJoinPartMuteList:
    return true
  # Smart filter: suppress if user hasn't spoken within the timeout
  if gSmartFilterEnabled and gSmartFilterTimeout > 0:
    let ck = channelKey(serverId, channelName)
    if ck in gLastSpoke and nickLower in gLastSpoke[ck]:
      let elapsed = epochTime() - gLastSpoke[ck][nickLower]
      if elapsed <= float(gSmartFilterTimeout):
        return false  # spoke recently, show the notification
    # Not spoken recently (or never spoken), suppress
    return true
  return false

# Forward declaration
proc ensureEventLoop()

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
      # Only add local message if echo-message is not active
      if serverId notin gEchoMessageServers:
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
          if gChannels[sk][i].name.toLowerAscii == gActiveChannelName.toLowerAscii:
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

  of "/mutejp":
    if args.len > 0:
      let nick = args.split(' ')[0].toLowerAscii
      if nick notin gJoinPartMuteList:
        gJoinPartMuteList.add(nick)
        saveConfig()
      addSystemMessage(serverId, gActiveChannelName, "Muted join/part for: " & nick)
    else:
      if gJoinPartMuteList.len > 0:
        addSystemMessage(serverId, gActiveChannelName,
          "Join/part mute list: " & gJoinPartMuteList.join(", "))
      else:
        addSystemMessage(serverId, gActiveChannelName, "Join/part mute list is empty")
    return true

  of "/unmutejp":
    if args.len > 0:
      let nick = args.split(' ')[0].toLowerAscii
      let idx = gJoinPartMuteList.find(nick)
      if idx >= 0:
        gJoinPartMuteList.delete(idx)
        saveConfig()
        addSystemMessage(serverId, gActiveChannelName, "Unmuted join/part for: " & nick)
      else:
        addErrorMessage(serverId, gActiveChannelName, nick & " is not in join/part mute list")
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /unmutejp nick")
    return true

  of "/smartfilter":
    if args.len > 0:
      case args.split(' ')[0].toLowerAscii
      of "on":
        gSmartFilterEnabled = true
        saveConfig()
        addSystemMessage(serverId, gActiveChannelName, "Smart join/part filter enabled")
      of "off":
        gSmartFilterEnabled = false
        saveConfig()
        addSystemMessage(serverId, gActiveChannelName, "Smart join/part filter disabled")
      else:
        let secs = try: parseInt(args.split(' ')[0]) * 60 except ValueError: -1
        if secs > 0:
          gSmartFilterTimeout = secs
          saveConfig()
          addSystemMessage(serverId, gActiveChannelName,
            "Smart filter timeout: " & $gSmartFilterTimeout.div(60) & " minutes")
        else:
          addErrorMessage(serverId, gActiveChannelName,
            "Usage: /smartfilter on|off|<minutes>")
    else:
      let status = if gSmartFilterEnabled: "enabled" else: "disabled"
      let mins = gSmartFilterTimeout div 60
      addSystemMessage(serverId, gActiveChannelName,
        "Smart filter: " & status & " (timeout: " & $mins & " min)")
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
            # Save current channel for old server (skip *server* pseudo-channel)
            if gActiveServerId >= 0 and gActiveChannelName.len > 0 and
               gActiveChannelName != ServerChannel:
              gLastChannelPerServer[gActiveServerId] = gActiveChannelName
            gActiveServerId = targetId
            # Restore previously viewed channel for target server
            let sk = serverKey(targetId)
            if targetId in gLastChannelPerServer:
              gActiveChannelName = gLastChannelPerServer[targetId]
            elif sk in gChannels:
              var found = false
              for ch in gChannels[sk]:
                if ch.name != ServerChannel:
                  gActiveChannelName = ch.name
                  found = true
                  break
              if not found:
                gActiveChannelName = ServerChannel
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

  of "/log":
    let parts = if args.len > 0: args.split(' ', 1) else: @["status"]
    case parts[0].toLowerAscii
    of "on":
      gLoggingEnabled = true
      if gLogDir.len == 0:
        gLogDir = configDir() / "logs"
      if not dirExists(gLogDir):
        createDir(gLogDir)
      saveConfig()
      addSystemMessage(serverId, gActiveChannelName,
        "Logging enabled (dir: " & gLogDir & ")")
    of "off":
      gLoggingEnabled = false
      saveConfig()
      addSystemMessage(serverId, gActiveChannelName, "Logging disabled")
    of "dir":
      if parts.len >= 2 and parts[1].strip().len > 0:
        gLogDir = parts[1].strip()
        if not dirExists(gLogDir):
          try:
            createDir(gLogDir)
          except CatchableError:
            discard
        saveConfig()
        addSystemMessage(serverId, gActiveChannelName, "Log directory: " & gLogDir)
      else:
        addSystemMessage(serverId, gActiveChannelName,
          "Log directory: " & (if gLogDir.len > 0: gLogDir else: "(not set)"))
    of "status":
      let status = if gLoggingEnabled: "enabled" else: "disabled"
      addSystemMessage(serverId, gActiveChannelName,
        "Logging: " & status & " (dir: " & gLogDir & ")")
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /log on|off|dir <path>|status")
    return true

  of "/debug":
    var debugLines: seq[string] = @[]
    debugLines.add("--- Debug Info ---")
    debugLines.add("Servers: " & $gServers.len)
    debugLines.add("Active server: " & $gActiveServerId)
    debugLines.add("Active channel: " & gActiveChannelName)
    let totalMsg = block:
      var n = 0
      for k, v in gMessages: n += v.len
      n
    debugLines.add("Total messages in memory: " & $totalMsg)
    debugLines.add("Ignore list: " & (if gIgnoreList.len > 0: gIgnoreList.join(", ") else: "(empty)"))
    debugLines.add("Highlight words: " & (if gHighlightWords.len > 0: gHighlightWords.join(", ") else: "(empty)"))
    debugLines.add("Join/part mute list: " & (if gJoinPartMuteList.len > 0: gJoinPartMuteList.join(", ") else: "(empty)"))
    debugLines.add("Smart filter: " & (if gSmartFilterEnabled: "on" else: "off") & " (timeout: " & $(gSmartFilterTimeout div 60) & " min)")
    debugLines.add("Logging: " & (if gLoggingEnabled: "on" else: "off"))
    debugLines.add("DCC transfers: " & $gDccTransfers.len)
    debugLines.add("Echo-message servers: " & $gEchoMessageServers.len)
    for line in debugLines:
      addSystemMessage(serverId, gActiveChannelName, line)
    return true

  of "/monitor":
    if args.len > 0:
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdSendRaw,
          serverId: serverId, text: "MONITOR " & args))
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /monitor + nick1,nick2 | - nick1 | C | L | S")
    return true

  of "/accept":
    let filterNick = if args.len > 0: args.split(' ')[0].toLowerAscii else: ""
    var accepted = 0
    for i in 0 ..< gDccTransfers.len:
      if gDccTransfers[i].state == dccPending and gDccTransfers[i].serverId == serverId:
        if filterNick.len == 0 or gDccTransfers[i].nick.toLowerAscii == filterNick:
          gDccTransfers[i].state = dccActive
          addSystemMessage(serverId, gActiveChannelName,
            "Accepted DCC transfer: " & gDccTransfers[i].filename & " from " & gDccTransfers[i].nick)
          # Start the actual download on the event loop
          ensureEventLoop()
          withLock gLock:
            gCommandQueue.add(BridgeCommand(kind: cmdAcceptDcc,
              serverId: serverId,
              intParam: gDccTransfers[i].id,
              text: gDccTransfers[i].filename))
          inc accepted
    if accepted == 0:
      addSystemMessage(serverId, gActiveChannelName, "No pending DCC transfers to accept")
    return true

  of "/decline":
    let filterNick = if args.len > 0: args.split(' ')[0].toLowerAscii else: ""
    var declined = 0
    for i in 0 ..< gDccTransfers.len:
      if gDccTransfers[i].state == dccPending and gDccTransfers[i].serverId == serverId:
        if filterNick.len == 0 or gDccTransfers[i].nick.toLowerAscii == filterNick:
          gDccTransfers[i].state = dccDeclined
          addSystemMessage(serverId, gActiveChannelName,
            "Declined DCC transfer: " & gDccTransfers[i].filename & " from " & gDccTransfers[i].nick)
          inc declined
    if declined == 0:
      addSystemMessage(serverId, gActiveChannelName, "No pending DCC transfers to decline")
    return true

  of "/transfers":
    if gDccTransfers.len == 0:
      addSystemMessage(serverId, gActiveChannelName, "No DCC transfers")
    else:
      for t in gDccTransfers:
        let statusStr = case t.state
          of dccPending: "PENDING"
          of dccActive: "ACTIVE"
          of dccDone: "DONE"
          of dccDeclined: "DECLINED"
          of dccFailed: "FAILED"
        let sizeStr = if t.filesize > 1024 * 1024:
                        $(t.filesize div (1024 * 1024)) & " MB"
                      elif t.filesize > 1024:
                        $(t.filesize div 1024) & " KB"
                      else:
                        $t.filesize & " B"
        addSystemMessage(serverId, gActiveChannelName,
          "[" & statusStr & "] " & t.filename & " (" & sizeStr & ") from " & t.nick)
    return true

  of "/kick":
    if gActiveChannelName.len > 0 and gActiveChannelName[0] == '#':
      let parts = args.split(' ', 1)
      if parts.len >= 1 and parts[0].len > 0:
        let target = parts[0]
        let reason = if parts.len >= 2: parts[1] else: ""
        let rawCmd = if reason.len > 0:
                       "KICK " & gActiveChannelName & " " & target & " :" & reason
                     else:
                       "KICK " & gActiveChannelName & " " & target
        withLock gLock:
          gCommandQueue.add(BridgeCommand(kind: cmdSendRaw,
            serverId: serverId, text: rawCmd))
      else:
        addErrorMessage(serverId, gActiveChannelName,
          "Usage: /kick nick [reason]")
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Cannot kick outside of a channel")
    return true

  of "/ban":
    if gActiveChannelName.len > 0 and gActiveChannelName[0] == '#':
      if args.len > 0:
        let target = args.split(' ')[0]
        let mask = if '*' in target or '!' in target or '@' in target:
                     target
                   else:
                     target & "!*@*"
        withLock gLock:
          gCommandQueue.add(BridgeCommand(kind: cmdSendRaw,
            serverId: serverId, text: "MODE " & gActiveChannelName & " +b " & mask))
      else:
        withLock gLock:
          gCommandQueue.add(BridgeCommand(kind: cmdSendRaw,
            serverId: serverId, text: "MODE " & gActiveChannelName & " +b"))
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Cannot ban outside of a channel")
    return true

  of "/ctcp":
    let parts = args.split(' ', 1)
    if parts.len >= 2:
      let target = parts[0]
      let ctcpCmd = parts[1].toUpperAscii
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdSendRaw,
          serverId: serverId, text: "PRIVMSG " & target & " :\x01" & ctcpCmd & "\x01"))
      addSystemMessage(serverId, gActiveChannelName,
        "CTCP " & ctcpCmd & " sent to " & target)
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /ctcp nick command")
    return true

  of "/list":
    let filter = if args.len > 0: args else: ""
    withLock gLock:
      if filter.len > 0:
        gCommandQueue.add(BridgeCommand(kind: cmdSendRaw,
          serverId: serverId, text: "LIST " & filter))
      else:
        gCommandQueue.add(BridgeCommand(kind: cmdSendRaw,
          serverId: serverId, text: "LIST"))
    addSystemMessage(serverId, gActiveChannelName,
      "Channel list requested (check server window)")
    return true

  of "/invite":
    let parts = args.split(' ', 1)
    if parts.len >= 1 and parts[0].len > 0:
      let target = parts[0]
      let channel = if parts.len >= 2 and parts[1].strip().len > 0: parts[1].strip()
                    else: gActiveChannelName
      if channel.len > 0 and channel[0] == '#':
        withLock gLock:
          gCommandQueue.add(BridgeCommand(kind: cmdSendRaw,
            serverId: serverId, text: "INVITE " & target & " " & channel))
        addSystemMessage(serverId, gActiveChannelName,
          "Invited " & target & " to " & channel)
      else:
        addErrorMessage(serverId, gActiveChannelName,
          "Usage: /invite nick [#channel]")
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /invite nick [#channel]")
    return true

  of "/oper":
    let parts = args.split(' ', 1)
    if parts.len >= 2:
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdSendRaw,
          serverId: serverId, text: "OPER " & parts[0] & " " & parts[1]))
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /oper name password")
    return true

  of "/scrollback":
    let num = if args.len > 0:
                try: parseInt(args.strip())
                except ValueError: -1
              else: -1
    if num > 0:
      let ck = channelKey(serverId, gActiveChannelName)
      if ck in gMessages and gMessages[ck].len > num:
        gMessages[ck] = gMessages[ck][gMessages[ck].len - num .. ^1]
        addSystemMessage(serverId, gActiveChannelName,
          "Scrollback trimmed to " & $num & " messages")
      else:
        addSystemMessage(serverId, gActiveChannelName,
          "Scrollback has " & (if ck in gMessages: $gMessages[ck].len else: "0") & " messages")
    else:
      let ck = channelKey(serverId, gActiveChannelName)
      addSystemMessage(serverId, gActiveChannelName,
        "Scrollback: " & (if ck in gMessages: $gMessages[ck].len else: "0") & " messages. Usage: /scrollback <count>")
    return true

  of "/nickcolor":
    if args.len > 0:
      let parts = args.split(' ', 1)
      let nick = parts[0].toLowerAscii
      if parts.len >= 2 and parts[1].strip().len > 0:
        let colorArg = parts[1].strip().toLowerAscii
        let hexColor = case colorArg
          of "red": "#FF453A"
          of "orange": "#FF9F0A"
          of "yellow": "#FFD60A"
          of "green": "#30D158"
          of "cyan": "#5AC8FA"
          of "blue": "#0A84FF"
          of "purple": "#BF5AF2"
          of "pink": "#FF6EAA"
          of "lime": "#32D74B"
          of "teal": "#64D2FF"
          of "coral": "#FF6B6B"
          of "gold": "#FFD700"
          else:
            let raw = if colorArg[0] == '#': colorArg else: "#" & colorArg
            if raw.len == 7: raw else: ""
        if hexColor.len > 0:
          gNickColors[nick] = hexColor
          saveConfig()
          addSystemMessage(serverId, gActiveChannelName,
            "Nick color for " & nick & " set to " & hexColor)
        else:
          addErrorMessage(serverId, gActiveChannelName,
            "Invalid color. Use: red, orange, yellow, green, cyan, blue, purple, pink, lime, teal, coral, gold, or #RRGGBB")
      else:
        if nick in gNickColors:
          addSystemMessage(serverId, gActiveChannelName,
            "Nick color for " & nick & ": " & gNickColors[nick])
        else:
          addSystemMessage(serverId, gActiveChannelName,
            "No custom color set for " & nick & " (using default hash)")
    else:
      if gNickColors.len > 0:
        var lines: seq[string] = @[]
        for nick, color in gNickColors:
          lines.add(nick & " = " & color)
        addSystemMessage(serverId, gActiveChannelName,
          "Nick colors: " & lines.join(", "))
      else:
        addSystemMessage(serverId, gActiveChannelName,
          "No custom nick colors set. Usage: /nickcolor nick [color]")
    return true

  of "/unnickcolor":
    if args.len > 0:
      let nick = args.split(' ')[0].toLowerAscii
      if nick in gNickColors:
        gNickColors.del(nick)
        saveConfig()
        addSystemMessage(serverId, gActiveChannelName,
          "Nick color for " & nick & " cleared")
      else:
        addErrorMessage(serverId, gActiveChannelName,
          nick & " has no custom color")
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /unnickcolor nick")
    return true

  of "/bouncer":
    # Send a command to BouncerServ (e.g. /bouncer network status)
    if args.len == 0:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /bouncer <command> (e.g. /bouncer help, /bouncer network status)")
      return true
    # Route through bouncer as a PRIVMSG to BouncerServ
    # Use gServers.host for server name (stores bouncer server name for bouncer connections)
    let si = findServerIdx(serverId)
    if si >= 0 and gBouncerSession != nil:
      ensureEventLoop()
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdSendMessage,
          serverId: serverId, text: args, text2: "BouncerServ"))
    else:
      addErrorMessage(serverId, gActiveChannelName,
        "Not connected via bouncer")
    return true

  of "/detach":
    # Detach a channel from the bouncer
    let channel = if args.len > 0: args.split(' ')[0]
                  else: gActiveChannelName
    if channel.len == 0 or channel == ServerChannel:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /detach [#channel]")
      return true
    let dsi = findServerIdx(serverId)
    if dsi < 0 or gBouncerSession == nil:
      addErrorMessage(serverId, gActiveChannelName, "Not connected via bouncer")
      return true
    let detachCmd = "channel update " & gServers[dsi].host & " " & channel & " -detached"
    ensureEventLoop()
    withLock gLock:
      gCommandQueue.add(BridgeCommand(kind: cmdSendMessage,
        serverId: serverId, text: detachCmd, text2: "BouncerServ"))
    return true

  of "/attach":
    # Reattach a detached channel
    let channel = if args.len > 0: args.split(' ')[0]
                  else: gActiveChannelName
    if channel.len == 0 or channel == ServerChannel:
      addErrorMessage(serverId, gActiveChannelName,
        "Usage: /attach [#channel]")
      return true
    let asi = findServerIdx(serverId)
    if asi < 0 or gBouncerSession == nil:
      addErrorMessage(serverId, gActiveChannelName, "Not connected via bouncer")
      return true
    let attachCmd = "channel update " & gServers[asi].host & " " & channel & " -attached"
    ensureEventLoop()
    withLock gLock:
      gCommandQueue.add(BridgeCommand(kind: cmdSendMessage,
        serverId: serverId, text: attachCmd, text2: "BouncerServ"))
    return true

  of "/help":
    let helpLines = @[
      "Chat: /msg /me /notice /ctcp /query",
      "Channels: /join /part /close /topic /invite /list /kick /ban /mode",
      "User: /nick /away /back /whois /ignore /unignore",
      "Nick colors: /nickcolor /unnickcolor",
      "Highlight: /highlight add|remove|list [word]",
      "Filtering: /mutejp /unmutejp /smartfilter",
      "Server: /server /disconnect /quit /raw /oper",
      "Bouncer: /bouncer /detach /attach",
      "Display: /clear /scrollback",
      "DCC: /accept /decline /transfers",
      "Other: /log /debug /monitor /help",
    ]
    for line in helpLines:
      addSystemMessage(serverId, gActiveChannelName, line)
    return true

  else:
    addErrorMessage(serverId, gActiveChannelName,
      "Unknown command: " & cmd)
    return true

# ============================================================
# Event loop thread: CPS coroutines
# ============================================================

proc findConnection(serverId: int): int =
  for i in 0 ..< gConnections.len:
    if gConnections[i].id == serverId:
      return i
  -1

proc lagPinger(connId: int, client: IrcClient): CpsVoidFuture {.cps.} =
  ## Periodically send PINGs to measure lag, independent of keepAlive.
  ## keepAliveLoop only pings after silence; this ensures lag is always visible.
  ## Note: client.state starts as icsDisconnected — we must keep looping and
  ## wait for it to reach icsConnected before sending pings.
  var disconnectedCount = 0
  var alive = true
  while alive:
    await cpsSleep(5_000)  # check every 5 seconds
    if client.state == icsConnected:
      disconnectedCount = 0
      try:
        await client.sendPing("lagcheck")
        await cpsSleep(25_000)  # total ~30s between pings
      except CatchableError:
        alive = false
    elif client.state == icsDisconnected:
      inc disconnectedCount
      # If disconnected for 5+ checks (25s) with no reconnect, give up
      if disconnectedCount >= 5 and not client.config.autoReconnect:
        alive = false
    else:
      # Connecting or registering — keep waiting
      disconnectedCount = 0

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
      # Detect if it's a PM (not a channel) — channel name is the *other* person's nick
      if event.pmTarget.len > 0 and event.pmTarget[0] != '#':
        if event.pmSource == client.currentNick:
          uiEvt.channel = event.pmTarget   # echo-message: we sent this
        else:
          uiEvt.channel = event.pmSource   # incoming PM from them
      withLock gLock:
        pushEvent(uiEvt)

    of iekNotice:
      uiEvt.kind = uiNewMessage
      uiEvt.channel = if event.pmTarget.len > 0 and event.pmTarget[0] == '#':
                         event.pmTarget
                       else: ServerChannel
      uiEvt.nick = event.pmSource
      uiEvt.text = event.pmText
      uiEvt.text2 = "notice"
      withLock gLock:
        pushEvent(uiEvt)

    of iekJoin:
      uiEvt.kind = uiUserJoin
      uiEvt.channel = event.joinChannel
      uiEvt.nick = event.joinNick
      withLock gLock:
        pushEvent(uiEvt)

    of iekPart:
      uiEvt.kind = uiUserPart
      uiEvt.channel = event.partChannel
      uiEvt.nick = event.partNick
      uiEvt.text = event.partReason
      withLock gLock:
        pushEvent(uiEvt)

    of iekQuit:
      uiEvt.kind = uiUserQuit
      uiEvt.nick = event.quitNick
      uiEvt.text = event.quitReason
      withLock gLock:
        pushEvent(uiEvt)

    of iekKick:
      uiEvt.kind = uiUserPart
      uiEvt.channel = event.kickChannel
      uiEvt.nick = event.kickNick
      uiEvt.text = "Kicked by " & event.kickBy & ": " & event.kickReason
      withLock gLock:
        pushEvent(uiEvt)

    of iekNick:
      uiEvt.kind = uiUserNick
      uiEvt.nick = event.nickNew
      uiEvt.text2 = event.nickOld
      withLock gLock:
        pushEvent(uiEvt)

    of iekMode:
      uiEvt.kind = uiModeChange
      uiEvt.channel = event.modeTarget
      uiEvt.text = event.modeChanges
      uiEvt.users = event.modeParams
      withLock gLock:
        pushEvent(uiEvt)

    of iekTopic:
      uiEvt.kind = uiTopicChange
      uiEvt.channel = event.topicChannel
      uiEvt.text = event.topicText
      uiEvt.nick = event.topicBy
      withLock gLock:
        pushEvent(uiEvt)

    of iekConnected:
      uiEvt.kind = uiConnected
      # Check if echo-message is enabled
      uiEvt.boolParam = "echo-message" in client.enabledCaps
      withLock gLock:
        pushEvent(uiEvt)

    of iekDisconnected:
      uiEvt.kind = uiDisconnected
      uiEvt.text = event.reason
      withLock gLock:
        pushEvent(uiEvt)

    of iekNumeric:
      case event.numCode
      of 353:  # RPL_NAMREPLY
        uiEvt.kind = uiUserList
        if event.numParams.len >= 2:
          uiEvt.channel = event.numParams[^2]
          uiEvt.users = event.numParams[^1].strip().split(' ')
        withLock gLock:
          pushEvent(uiEvt)
      of 332:  # RPL_TOPIC
        uiEvt.kind = uiTopicChange
        if event.numParams.len >= 2:
          uiEvt.channel = event.numParams[1]
          uiEvt.text = event.numParams[^1]
        withLock gLock:
          pushEvent(uiEvt)
      of 366:  # RPL_ENDOFNAMES - ignore
        discard
      of 376, 422:  # RPL_ENDOFMOTD, ERR_NOMOTD
        discard
      of 433:  # ERR_NICKNAMEINUSE
        let idx = findConnection(connId)
        if idx >= 0:
          let oldNick = gConnections[idx].myNick
          let newNick = oldNick & "_"
          gConnections[idx].myNick = newNick
          discard spawn client.changeNick(newNick)
          uiEvt.kind = uiNewMessage
          uiEvt.channel = ServerChannel
          uiEvt.nick = ""
          uiEvt.text = "Nick '" & oldNick & "' in use, trying '" & newNick & "'"
          uiEvt.text2 = "system"
          withLock gLock:
            pushEvent(uiEvt)
      of 311:  # RPL_WHOISUSER
        if event.numParams.len >= 5:
          let line = event.numParams[1] & " (" & event.numParams[2] & "@" & event.numParams[3] & ")\n" & event.numParams[^1]
          withLock gLock:
            if gWhoisActive:
              gWhoisInfo = line
            else:
              uiEvt.kind = uiNewMessage
              uiEvt.channel = ServerChannel
              uiEvt.nick = ""
              uiEvt.text = "[WHOIS] " & line
              uiEvt.text2 = "system"
              pushEvent(uiEvt)
      of 312:  # RPL_WHOISSERVER
        if event.numParams.len >= 3:
          let line = "Server: " & event.numParams[2] & " (" & event.numParams[^1] & ")"
          withLock gLock:
            if gWhoisActive:
              gWhoisInfo.add("\n" & line)
            else:
              uiEvt.kind = uiNewMessage
              uiEvt.channel = ServerChannel
              uiEvt.nick = ""
              uiEvt.text = "[WHOIS] " & line
              uiEvt.text2 = "system"
              pushEvent(uiEvt)
      of 319:  # RPL_WHOISCHANNELS
        if event.numParams.len >= 2:
          let line = "Channels: " & event.numParams[^1]
          withLock gLock:
            if gWhoisActive:
              gWhoisInfo.add("\n" & line)
            else:
              uiEvt.kind = uiNewMessage
              uiEvt.channel = ServerChannel
              uiEvt.nick = ""
              uiEvt.text = "[WHOIS] " & line
              uiEvt.text2 = "system"
              pushEvent(uiEvt)
      of 317:  # RPL_WHOISIDLE
        if event.numParams.len >= 3:
          let secs = try: parseInt(event.numParams[2]) except: 0
          let idleStr = if secs >= 3600: $(secs div 3600) & "h " & $((secs mod 3600) div 60) & "m"
                        elif secs >= 60: $(secs div 60) & "m " & $(secs mod 60) & "s"
                        else: $secs & "s"
          let line = "Idle: " & idleStr
          withLock gLock:
            if gWhoisActive:
              gWhoisInfo.add("\n" & line)
            else:
              uiEvt.kind = uiNewMessage
              uiEvt.channel = ServerChannel
              uiEvt.nick = ""
              uiEvt.text = "[WHOIS] " & line
              uiEvt.text2 = "system"
              pushEvent(uiEvt)
      of 330:  # RPL_WHOISACCOUNT
        if event.numParams.len >= 3:
          let line = "Account: " & event.numParams[2]
          withLock gLock:
            if gWhoisActive:
              gWhoisInfo.add("\n" & line)
            else:
              uiEvt.kind = uiNewMessage
              uiEvt.channel = ServerChannel
              uiEvt.nick = ""
              uiEvt.text = "[WHOIS] " & line
              uiEvt.text2 = "system"
              pushEvent(uiEvt)
      of 313:  # RPL_WHOISOPERATOR
        if event.numParams.len >= 2:
          let line = "IRC Operator"
          withLock gLock:
            if gWhoisActive:
              gWhoisInfo.add("\n" & line)
      of 335:  # RPL_WHOISBOT
        withLock gLock:
          if gWhoisActive:
            gWhoisInfo.add("\nBot")
      of 318:  # RPL_ENDOFWHOIS
        withLock gLock:
          gWhoisActive = false
      of 324:  # RPL_CHANNELMODEIS
        if event.numParams.len >= 2:
          uiEvt.kind = uiNewMessage
          uiEvt.channel = event.numParams[1]
          uiEvt.nick = ""
          uiEvt.text = "Channel mode: " & event.numParams[2 .. ^1].join(" ")
          uiEvt.text2 = "system"
          withLock gLock:
            pushEvent(uiEvt)
      else:
        # Forward other numerics as system messages
        if event.numParams.len > 0:
          uiEvt.kind = uiNewMessage
          uiEvt.channel = ServerChannel
          uiEvt.nick = ""
          uiEvt.text = $event.numCode & " " & event.numParams.join(" ")
          uiEvt.text2 = "numeric"
          withLock gLock:
            pushEvent(uiEvt)

    of iekCtcp:
      if event.ctcpCommand == "ACTION":
        uiEvt.kind = uiNewMessage
        uiEvt.channel = event.ctcpTarget
        uiEvt.nick = event.ctcpSource
        uiEvt.text = event.ctcpArgs
        uiEvt.boolParam = true  # isAction flag
        # If target is not a channel, channel name is the *other* person's nick
        if event.ctcpTarget.len > 0 and event.ctcpTarget[0] != '#':
          if event.ctcpSource == client.currentNick:
            uiEvt.channel = event.ctcpTarget   # echo-message: we sent this
          else:
            uiEvt.channel = event.ctcpSource   # incoming action from them
        withLock gLock:
          pushEvent(uiEvt)
      elif event.ctcpCommand == "TIME":
        discard spawn client.ctcpReply(event.ctcpSource, "TIME", now().format("ddd MMM dd HH:mm:ss yyyy"))
      else:
        discard  # VERSION and PING handled by the IRC client library

    of iekTyping:
      uiEvt.kind = uiTyping
      uiEvt.channel = event.typingTarget
      uiEvt.nick = event.typingNick
      uiEvt.boolParam = event.typingActive
      # For DM typing, channel is the *other* person's nick
      if event.typingTarget.len > 0 and event.typingTarget[0] != '#':
        uiEvt.channel = event.typingNick  # DM typing: route to sender's nick
      withLock gLock:
        pushEvent(uiEvt)

    of iekChghost:
      uiEvt.kind = uiChghost
      uiEvt.nick = event.chghostNick
      uiEvt.text = event.chghostNewUser & "@" & event.chghostNewHost
      withLock gLock:
        pushEvent(uiEvt)

    of iekSetname:
      uiEvt.kind = uiSetname
      uiEvt.nick = event.setnameNick
      uiEvt.text = event.setnameRealname
      withLock gLock:
        pushEvent(uiEvt)

    of iekAccount:
      uiEvt.kind = uiAccount
      uiEvt.nick = event.accountNick
      uiEvt.text = event.accountName
      withLock gLock:
        pushEvent(uiEvt)

    of iekCompletedBatch:
      uiEvt.kind = uiBatchComplete
      uiEvt.text = event.cbBatchType
      uiEvt.text2 = event.cbBatchRef
      # For netsplit/netjoin, gather nicks from the batch messages
      var nicks: seq[string] = @[]
      for msg in event.cbMessages:
        var nick = ""
        case msg.kind
        of iekQuit: nick = msg.quitNick
        of iekJoin: nick = msg.joinNick
        of iekPart: nick = msg.partNick
        of iekPrivMsg: nick = msg.pmSource
        else: discard
        if nick.len > 0 and nick notin nicks:
          nicks.add(nick)
      uiEvt.users = nicks
      if event.cbBatchParams.len > 0:
        uiEvt.channel = event.cbBatchParams[0]
      withLock gLock:
        pushEvent(uiEvt)

    of iekBatch:
      discard  # Individual batch start/end; wait for iekCompletedBatch

    of iekMonOnline:
      uiEvt.kind = uiMonOnline
      uiEvt.users = event.monOnlineTargets
      withLock gLock:
        pushEvent(uiEvt)

    of iekMonOffline:
      uiEvt.kind = uiMonOffline
      uiEvt.users = event.monOfflineTargets
      withLock gLock:
        pushEvent(uiEvt)

    of iekPong:
      uiEvt.kind = uiLagUpdate
      uiEvt.intParam = client.lagMs
      withLock gLock:
        pushEvent(uiEvt)

    of iekAway:
      uiEvt.kind = uiAwayChange
      uiEvt.nick = event.awayNick
      uiEvt.boolParam = event.awayMessage.len > 0
      uiEvt.text = event.awayMessage
      withLock gLock:
        pushEvent(uiEvt)

    of iekError:
      uiEvt.kind = uiError
      uiEvt.text = event.errMsg
      withLock gLock:
        pushEvent(uiEvt)

    of iekInvite:
      uiEvt.kind = uiNewMessage
      uiEvt.channel = ServerChannel
      uiEvt.nick = event.inviteNick
      uiEvt.text = event.inviteNick & " invited you to " & event.inviteChannel
      uiEvt.text2 = "system"
      withLock gLock:
        pushEvent(uiEvt)

    of iekDccSend:
      uiEvt.kind = uiNewMessage
      uiEvt.channel = ServerChannel
      uiEvt.nick = ""
      let sizeKb = event.dccInfo.filesize div 1024
      uiEvt.text = "DCC SEND from " & event.dccSource & ": " & event.dccInfo.filename & " (" & $sizeKb & " KB) — use /accept or /decline"
      uiEvt.text2 = "system"
      withLock gLock:
        pushEvent(uiEvt)
        # Track the DCC offer with connection info
        gDccTransfers.add(DccTransfer(
          id: gNextDccId,
          nick: event.dccSource,
          filename: event.dccInfo.filename,
          filesize: event.dccInfo.filesize,
          state: dccPending,
          progress: 0.0,
          serverId: connId,
          ip: event.dccInfo.ip,
          port: event.dccInfo.port,
        ))
        inc gNextDccId

    of iekDccChat:
      uiEvt.kind = uiNewMessage
      uiEvt.channel = ServerChannel
      uiEvt.nick = ""
      uiEvt.text = "DCC CHAT request from " & event.dccSource & " (not supported)"
      uiEvt.text2 = "system"
      withLock gLock:
        pushEvent(uiEvt)

    of iekDccAccept, iekDccResume:
      uiEvt.kind = uiNewMessage
      uiEvt.channel = ServerChannel
      uiEvt.nick = ""
      uiEvt.text = "DCC " & (if event.kind == iekDccAccept: "ACCEPT" else: "RESUME") & " from " & event.dccSource
      uiEvt.text2 = "system"
      withLock gLock:
        pushEvent(uiEvt)

    else:
      discard

proc pushDccEvent(evKind: UiEventKind, sid: int, tid: int,
                  msg: string = "") =
  ## Push a DCC UI event to the event queue (called from event loop thread).
  var evt: UiEvent
  evt.kind = evKind
  evt.serverId = sid
  evt.intParam = tid
  evt.text = msg
  {.cast(gcsafe).}:
    withLock gLock:
      pushEvent(evt)

proc makeDccProgressCb(sid: int, tid: int): DccProgressCallback =
  ## Factory that returns a progress callback for DCC transfers.
  ## Uses a factory to avoid CPS lambda rewriting issues.
  result = proc(received: int64, total: int64) =
    let p = if total > 0: received.float / total.float else: -1.0
    pushDccEvent(uiDccProgress, sid, tid, $p & "|" & $received)

proc dccDownloader(dccTransferId: int, dccIp: uint32, dccPort: int,
                    dccFilename: string, dccFilesize: int64,
                    dccServerId: int): CpsVoidFuture {.cps.} =
  ## CPS proc that runs on the event loop to download a DCC file.
  ## Pushes progress/complete/failed events back to the UI.

  # Create a dcc.DccTransfer for the actual download
  var info: DccInfo
  info.kind = "SEND"
  info.filename = dccFilename
  info.ip = dccIp
  info.port = dccPort
  info.filesize = dccFilesize

  let outPath = getHomeDir() / "Downloads" / dccFilename.replace("/", "_").replace("\\", "_")
  let transfer = dcc.DccTransfer(
    info: info,
    source: "",
    state: dtsIdle,
    totalBytes: dccFilesize,
    outputPath: outPath,
    connectTimeoutMs: 30000,
  )

  # Set progress callback via factory (avoids CPS lambda issues)
  transfer.setProgressCallback(makeDccProgressCb(dccServerId, dccTransferId))

  try:
    await receiveDcc(transfer)
    if transfer.state == dtsCompleted:
      pushDccEvent(uiDccComplete, dccServerId, dccTransferId, transfer.outputPath)
    else:
      pushDccEvent(uiDccFailed, dccServerId, dccTransferId, transfer.error)
  except CatchableError as e:
    pushDccEvent(uiDccFailed, dccServerId, dccTransferId, e.msg)

# ============================================================
# Bouncer integration helpers (event loop thread only)
# ============================================================

proc sendBouncerCmd(session: BouncerBridgeSession, msg: BouncerMsg) =
  ## Fire-and-forget send a bouncer command. Non-CPS, uses POSIX send().
  if session == nil or not session.connected: return
  let line = buildBouncerLine(msg)
  var offset = 0
  while offset < line.len:
    let n = posix.send(session.stream.fd, cast[pointer](unsafeAddr line[offset]),
                       line.len - offset, cint(0))
    if n <= 0: break
    offset += n

proc isBouncerConnection(connId: int): bool =
  ## Check if a connection is bouncer-managed.
  for i in 0 ..< gConnections.len:
    if gConnections[i].id == connId:
      return gConnections[i].fromBouncer
  false

proc findBouncerServerName(connId: int): string =
  ## Get the bouncer server name for a connection ID.
  ## Convention: IrcConnection.config.host stores the bouncer server name.
  for i in 0 ..< gConnections.len:
    if gConnections[i].id == connId and gConnections[i].fromBouncer:
      return gConnections[i].config.host
  ""

proc channelUpdateNamesLineGui(users: Table[string, string]): string =
  ## Build a NAMES-style line from ChannelState.users (non-CPS helper).
  var parts: seq[string] = @[]
  for nick, prefix in users:
    parts.add(prefix & nick)
  parts.join(" ")

proc findBouncerConnId(serverName: string): int =
  ## Find the connection ID for a bouncer-managed server. Non-CPS helper.
  for i in 0 ..< gConnections.len:
    if gConnections[i].fromBouncer and gConnections[i].config.host == serverName:
      return gConnections[i].id
  -1

proc getConnNick(connId: int): string =
  ## Get the current nick for a connection. Non-CPS helper.
  for i in 0 ..< gConnections.len:
    if gConnections[i].id == connId:
      return gConnections[i].myNick
  ""

proc setConnNick(connId: int, nick: string) =
  ## Set the current nick for a connection. Non-CPS helper.
  for i in 0 ..< gConnections.len:
    if gConnections[i].id == connId:
      gConnections[i].myNick = nick
      return

proc findBouncerConnIdAndSetNick(serverName: string, nick: string): int =
  ## Find bouncer connection ID and update nick. Non-CPS helper.
  for i in 0 ..< gConnections.len:
    if gConnections[i].fromBouncer and gConnections[i].config.host == serverName:
      gConnections[i].myNick = nick
      return gConnections[i].id
  -1

proc allocBouncerServerId(): int =
  ## Allocate a new server ID. Non-CPS helper.
  let id = gNextServerId
  inc gNextServerId
  id

proc addBouncerServer(connId: int, serverName: string, nick: string,
                      connected: bool) =
  ## Add a bouncer server to the GUI state. Non-CPS helper. Must hold gLock.
  gServers.add(ServerState(
    id: connId,
    name: serverName,
    host: serverName,
    port: 0,
    nick: nick,
    connected: connected,
    connecting: not connected,
    lagMs: -1,
  ))
  gDirty = true

proc setActiveServerIfNone() =
  ## Set the active server to the first connection if none selected. Must hold gLock.
  if gActiveServerId < 0 and gConnections.len > 0:
    gActiveServerId = gConnections[0].id

proc bouncerEventForwarder(session: BouncerBridgeSession): CpsVoidFuture {.cps.} =
  ## Reads JSON lines from bouncer socket, converts to UiEvent, pushes to gEventQueue.
  ## Runs on the event loop thread.
  var alive = true
  while alive and session.connected:
    var line: string
    try:
      line = await session.reader.readLine("\n")
    except CatchableError:
      alive = false
    if not alive:
      discard  # exit loop
    elif line.len == 0:
      alive = false
    else:
      var msg: BouncerMsg
      var parsed = false
      try:
        msg = parseBouncerMsg(line)
        parsed = true
      except CatchableError:
        discard

      if parsed:
        case msg.kind
        of bmkMessage:
          let data = msg.msgData
          let serverName = msg.msgServer
          let connId = findBouncerConnId(serverName)
          if connId >= 0:
            let evtOpt = bouncerMsgToIrcEvent(data, serverName)
            if evtOpt.isSome:
              let event = evtOpt.get()
              var uiEvt = UiEvent(serverId: connId)

              case event.kind
              of iekPrivMsg:
                uiEvt.kind = uiNewMessage
                uiEvt.channel = event.pmTarget
                uiEvt.nick = event.pmSource
                uiEvt.text = event.pmText
                if event.pmTarget.len > 0 and event.pmTarget[0] != '#':
                  let myNick = getConnNick(connId)
                  if event.pmSource == myNick:
                    uiEvt.channel = event.pmTarget
                  else:
                    uiEvt.channel = event.pmSource
                withLock gLock:
                  pushEvent(uiEvt)
              of iekNotice:
                uiEvt.kind = uiNewMessage
                uiEvt.channel = if event.pmTarget.len > 0 and event.pmTarget[0] == '#':
                                   event.pmTarget
                                 else: ServerChannel
                uiEvt.nick = event.pmSource
                uiEvt.text = event.pmText
                uiEvt.text2 = "notice"
                withLock gLock:
                  pushEvent(uiEvt)
              of iekJoin:
                uiEvt.kind = uiUserJoin
                uiEvt.channel = event.joinChannel
                uiEvt.nick = event.joinNick
                withLock gLock:
                  pushEvent(uiEvt)
              of iekPart:
                uiEvt.kind = uiUserPart
                uiEvt.channel = event.partChannel
                uiEvt.nick = event.partNick
                uiEvt.text = event.partReason
                withLock gLock:
                  pushEvent(uiEvt)
              of iekQuit:
                uiEvt.kind = uiUserQuit
                uiEvt.nick = event.quitNick
                uiEvt.text = event.quitReason
                withLock gLock:
                  pushEvent(uiEvt)
              of iekKick:
                uiEvt.kind = uiUserPart
                uiEvt.channel = event.kickChannel
                uiEvt.nick = event.kickNick
                uiEvt.text = "Kicked by " & event.kickBy & ": " & event.kickReason
                withLock gLock:
                  pushEvent(uiEvt)
              of iekNick:
                uiEvt.kind = uiUserNick
                uiEvt.nick = event.nickNew
                uiEvt.text2 = event.nickOld
                withLock gLock:
                  pushEvent(uiEvt)
              of iekMode:
                uiEvt.kind = uiModeChange
                uiEvt.channel = event.modeTarget
                uiEvt.text = event.modeChanges
                uiEvt.users = event.modeParams
                withLock gLock:
                  pushEvent(uiEvt)
              of iekTopic:
                uiEvt.kind = uiTopicChange
                uiEvt.channel = event.topicChannel
                uiEvt.text = event.topicText
                uiEvt.nick = event.topicBy
                withLock gLock:
                  pushEvent(uiEvt)
              of iekCtcp:
                if event.ctcpCommand == "ACTION":
                  uiEvt.kind = uiNewMessage
                  uiEvt.channel = event.ctcpTarget
                  uiEvt.nick = event.ctcpSource
                  uiEvt.text = event.ctcpArgs
                  uiEvt.boolParam = true
                  if event.ctcpTarget.len > 0 and event.ctcpTarget[0] != '#':
                    let myNick = getConnNick(connId)
                    if event.ctcpSource == myNick:
                      uiEvt.channel = event.ctcpTarget
                    else:
                      uiEvt.channel = event.ctcpSource
                  withLock gLock:
                    pushEvent(uiEvt)
              of iekNumeric:
                case event.numCode
                of 353:
                  uiEvt.kind = uiUserList
                  if event.numParams.len >= 2:
                    uiEvt.channel = event.numParams[^2]
                    uiEvt.users = event.numParams[^1].strip().split(' ')
                  withLock gLock:
                    pushEvent(uiEvt)
                of 332:
                  uiEvt.kind = uiTopicChange
                  if event.numParams.len >= 2:
                    uiEvt.channel = event.numParams[1]
                    uiEvt.text = event.numParams[^1]
                  withLock gLock:
                    pushEvent(uiEvt)
                of 366:
                  discard
                else:
                  if event.numParams.len > 0:
                    uiEvt.kind = uiNewMessage
                    uiEvt.channel = ServerChannel
                    uiEvt.nick = ""
                    uiEvt.text = $event.numCode & " " & event.numParams.join(" ")
                    uiEvt.text2 = "numeric"
                    withLock gLock:
                      pushEvent(uiEvt)
              else:
                discard

        of bmkServerConnected:
          let connId = findBouncerConnIdAndSetNick(msg.scServer, msg.scNick)
          if connId >= 0:
            withLock gLock:
              pushEvent(UiEvent(kind: uiConnected, serverId: connId))

        of bmkServerDisconnected:
          let connId = findBouncerConnId(msg.sdServer)
          if connId >= 0:
            withLock gLock:
              pushEvent(UiEvent(kind: uiDisconnected, serverId: connId, text: msg.sdReason))

        of bmkChannelUpdate:
          let connId = findBouncerConnId(msg.cuServer)
          if connId >= 0:
            let ch = msg.cuChannel
            if ch.topic.len > 0:
              withLock gLock:
                pushEvent(UiEvent(kind: uiTopicChange, serverId: connId,
                  channel: ch.name, text: ch.topic, nick: ch.topicSetBy))
            let namesLine = channelUpdateNamesLineGui(ch.users)
            if namesLine.len > 0:
              withLock gLock:
                pushEvent(UiEvent(kind: uiUserList, serverId: connId,
                  channel: ch.name, users: namesLine.split(' ')))

        of bmkNickChanged:
          let connId = findBouncerConnIdAndSetNick(msg.ncServer, msg.ncNewNick)
          if connId >= 0:
            withLock gLock:
              pushEvent(UiEvent(kind: uiNickChange, serverId: connId,
                nick: msg.ncNewNick, text2: msg.ncOldNick))

        of bmkReplayEnd:
          let key = msg.reServer & ":" & msg.reChannel.toLowerAscii()
          session.lastSeenIds[key] = msg.reNewestId

        of bmkServerAdded:
          # Dynamic network added at runtime — create a new IrcConnection + ServerState
          let newServerName = msg.saServer
          # Check if we already have this server
          let existingId = findBouncerConnId(newServerName)
          if existingId < 0:
            let newConnId = allocBouncerServerId()
            var newCfg = newIrcClientConfig(host = newServerName, port = 0, nick = "")
            newCfg.autoReconnect = false
            gConnections.add(IrcConnection(
              id: newConnId,
              client: nil,
              config: newCfg,
              channels: @[],
              myNick: "",
              fromBouncer: true,
            ))
            withLock gLock:
              addBouncerServer(newConnId, newServerName, "", false)
              setActiveServerIfNone()

        of bmkServerRemoved:
          # Dynamic network removed at runtime — remove IrcConnection + ServerState
          let rmServerName = msg.srServer
          let rmConnId = findBouncerConnId(rmServerName)
          if rmConnId >= 0:
            # Remove from gConnections
            for ri in 0 ..< gConnections.len:
              if gConnections[ri].id == rmConnId:
                gConnections.delete(ri)
                break
            # Remove from gServers (under lock)
            withLock gLock:
              for rsi in 0 ..< gServers.len:
                if gServers[rsi].id == rmConnId:
                  gServers.delete(rsi)
                  break
              # If this was the active server, switch to another
              if gActiveServerId == rmConnId:
                if gServers.len > 0:
                  gActiveServerId = gServers[0].id
                  gActiveChannelName = ServerChannel
                else:
                  gActiveServerId = -1
                  gActiveChannelName = ""
              gDirty = true
              notifySwift()

        of bmkChannelDetach:
          let detachServer = msg.cdServer
          let detachChannel = msg.cdChannel
          let detachConnId = findBouncerConnId(detachServer)
          if detachConnId >= 0:
            withLock gLock:
              pushEvent(UiEvent(kind: uiNewMessage, serverId: detachConnId,
                channel: detachChannel, nick: "",
                text: "Channel " & detachChannel & " detached",
                text2: "system"))

        of bmkChannelAttach:
          let attachServer = msg.caServer
          let attachChannel = msg.caChannel
          let attachConnId = findBouncerConnId(attachServer)
          if attachConnId >= 0:
            withLock gLock:
              pushEvent(UiEvent(kind: uiNewMessage, serverId: attachConnId,
                channel: attachChannel, nick: "",
                text: "Channel " & attachChannel & " reattached",
                text2: "system"))
            # Request replay for missed messages
            let attachKey = attachServer & ":" & attachChannel.toLowerAscii()
            let sinceId = session.lastSeenIds.getOrDefault(attachKey, 0'i64)
            sendBouncerCmd(session, BouncerMsg(kind: bmkReplay,
              replayServer: attachServer,
              replayChannel: attachChannel,
              replaySinceId: sinceId,
              replayLimit: 500))

        of bmkSearchResults:
          # Display search results in the active channel as system messages
          let srServer = msg.srchServer
          let srConnId = findBouncerConnId(srServer)
          if srConnId >= 0:
            let resultCount = msg.srchMessages.len
            if resultCount == 0:
              withLock gLock:
                pushEvent(UiEvent(kind: uiNewMessage, serverId: srConnId,
                  channel: ServerChannel, nick: "",
                  text: "Search: no results found",
                  text2: "system"))
            else:
              withLock gLock:
                pushEvent(UiEvent(kind: uiNewMessage, serverId: srConnId,
                  channel: ServerChannel, nick: "",
                  text: "Search: " & $resultCount & " result(s):",
                  text2: "system"))
              for sri in 0 ..< resultCount:
                let sr = msg.srchMessages[sri]
                let srText = "[" & sr.target & "] <" & sr.source & "> " & sr.text
                withLock gLock:
                  pushEvent(UiEvent(kind: uiNewMessage, serverId: srConnId,
                    channel: ServerChannel, nick: "",
                    text: srText, text2: "system"))
          elif msg.srchServer.len == 0:
            # No server specified — show in first bouncer connection
            if gConnections.len > 0:
              let fallbackConnId = gConnections[0].id
              let fbResultCount = msg.srchMessages.len
              withLock gLock:
                pushEvent(UiEvent(kind: uiNewMessage, serverId: fallbackConnId,
                  channel: ServerChannel, nick: "",
                  text: "Search: " & $fbResultCount & " result(s)",
                  text2: "system"))

        of bmkError:
          withLock gLock:
            pushEvent(UiEvent(kind: uiError, text: "Bouncer: " & msg.errText))

        else:
          discard

  # Bouncer disconnected
  session.connected = false

proc connectToBouncerGui(): CpsVoidFuture {.cps.} =
  ## Try to discover and connect to a running bouncer daemon.
  ## Creates IrcConnection entries with fromBouncer=true for each bouncer server.
  let socketPath = discoverBouncer()
  if socketPath.len == 0: return

  var stream: UnixStream
  try:
    stream = await unixConnect(socketPath)
  except CatchableError:
    return

  let reader = newBufferedReader(stream.AsyncStream)
  let session = BouncerBridgeSession(
    stream: stream,
    reader: reader,
    serverNames: @[],
    lastSeenIds: initTable[string, int64](),
    connected: true,
  )

  # Send hello handshake
  let helloMsg = BouncerMsg(kind: bmkHello,
    helloVersion: 1,
    helloClientName: "cps-irc-gui",
    helloPassword: gBouncerPassword)
  sendBouncerCmd(session, helloMsg)

  # Read hello_ok
  var helloLine: string
  try:
    helloLine = await reader.readLine("\n")
  except CatchableError:
    stream.close()
    return
  if helloLine.len == 0:
    stream.close()
    return

  var helloReply: BouncerMsg
  try:
    helloReply = parseBouncerMsg(helloLine)
  except CatchableError:
    stream.close()
    return

  if helloReply.kind != bmkHelloOk:
    stream.close()
    return

  session.serverNames = helloReply.helloOkServers
  gBouncerSession = session

  # Read server_state messages for each server
  let serverCount = session.serverNames.len
  var readOk = true
  for si in 0 ..< serverCount:
    if not readOk:
      discard  # skip remaining servers
    else:
      var stateLine: string
      try:
        stateLine = await reader.readLine("\n")
      except CatchableError:
        readOk = false
      if readOk and stateLine.len == 0:
        readOk = false

      if readOk:
        var stateMsg: BouncerMsg
        var parsed = false
        try:
          stateMsg = parseBouncerMsg(stateLine)
          parsed = true
        except CatchableError:
          discard

        if parsed and stateMsg.kind == bmkServerState:
          let serverName = stateMsg.ssServer
          let nick = stateMsg.ssNick

          let connId = allocBouncerServerId()

          var cfg = newIrcClientConfig(host = serverName, port = 0, nick = nick)
          cfg.autoReconnect = false

          gConnections.add(IrcConnection(
            id: connId,
            client: nil,
            config: cfg,
            channels: @[],
            myNick: nick,
            fromBouncer: true,
          ))

          withLock gLock:
            addBouncerServer(connId, serverName, nick, stateMsg.ssConnected)

          # Synthesize join/topic/names events from channel state
          let events = channelStateToIrcEvents(nick, stateMsg.ssChannels)
          let evtCount = events.len
          for ei in 0 ..< evtCount:
            let evt = events[ei]
            var uiEvt = UiEvent(serverId: connId)
            case evt.kind
            of iekJoin:
              uiEvt.kind = uiUserJoin
              uiEvt.channel = evt.joinChannel
              uiEvt.nick = evt.joinNick
              withLock gLock:
                pushEvent(uiEvt)
            of iekTopic:
              uiEvt.kind = uiTopicChange
              uiEvt.channel = evt.topicChannel
              uiEvt.text = evt.topicText
              uiEvt.nick = evt.topicBy
              withLock gLock:
                pushEvent(uiEvt)
            of iekNumeric:
              if evt.numCode == 353:
                uiEvt.kind = uiUserList
                if evt.numParams.len >= 2:
                  uiEvt.channel = evt.numParams[^2]
                  uiEvt.users = evt.numParams[^1].strip().split(' ')
                withLock gLock:
                  pushEvent(uiEvt)
            else:
              discard

          # Request replay for each channel
          let chanCount = stateMsg.ssChannels.len
          for ci in 0 ..< chanCount:
            let ch = stateMsg.ssChannels[ci]
            let key = serverName & ":" & ch.name.toLowerAscii()
            let sinceId = session.lastSeenIds.getOrDefault(key, 0'i64)
            sendBouncerCmd(session, BouncerMsg(kind: bmkReplay,
              replayServer: serverName,
              replayChannel: ch.name,
              replaySinceId: sinceId,
              replayLimit: 500))

  # If connected, set as active server
  if session.serverNames.len > 0 and gConnections.len > 0:
    withLock gLock:
      setActiveServerIfNone()

  # Start the bouncer event forwarder background task
  discard spawn bouncerEventForwarder(session)

proc commandProcessor(): CpsVoidFuture {.cps.} =
  ## Runs on event loop thread. Drains command queue every 50ms.

  # Try to connect to bouncer at startup
  await connectToBouncerGui()

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
          if gConnections[existing].fromBouncer:
            continue  # Bouncer-managed server — skip direct connect
          # Stale connection — clean it up first
          let oldClient = gConnections[existing].client
          oldClient.config.autoReconnect = false
          discard spawn oldClient.disconnect()
          gConnections.delete(existing)

        var cfg = newIrcClientConfig(
          host = cmd.text,
          port = cmd.intParam,
          nick = cmd.text2,
        )
        cfg.useTls = cmd.boolParam
        cfg.autoReconnect = true
        cfg.maxReconnectAttempts = 0
        cfg.reconnectDelayMs = 5000
        cfg.ctcpVersion = "CPS IRC GUI 1.0"
        {.cast(gcsafe).}:
          if gQuitMessage.len > 0:
            cfg.quitMessage = gQuitMessage
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

        # Spawn client, event forwarder, and lag pinger as concurrent tasks
        discard spawn client.run()
        discard spawn ircEventForwarder(connId, client)
        discard spawn lagPinger(connId, client)

      of cmdDisconnect:
        let idx = findConnection(cmd.serverId)
        if idx >= 0:
          if gConnections[idx].fromBouncer:
            let srvName = findBouncerServerName(cmd.serverId)
            if srvName.len > 0 and gBouncerSession != nil:
              sendBouncerCmd(gBouncerSession, BouncerMsg(kind: bmkQuit,
                quitServer: srvName, quitReason: "Disconnecting"))
          else:
            {.cast(gcsafe).}:
              withLock gLock:
                if cmd.serverId notin gIntentionalDisconnects:
                  gIntentionalDisconnects.add(cmd.serverId)
            let client = gConnections[idx].client
            client.config.autoReconnect = false
            # Patch quit message from current setting (may have changed since connect)
            {.cast(gcsafe).}:
              if gQuitMessage.len > 0:
                client.config.quitMessage = gQuitMessage
            discard spawn client.disconnect()
            gConnections.delete(idx)

      of cmdSendMessage:
        let idx = findConnection(cmd.serverId)
        if idx >= 0:
          if gConnections[idx].fromBouncer:
            let srvName = findBouncerServerName(cmd.serverId)
            if srvName.len > 0 and gBouncerSession != nil:
              sendBouncerCmd(gBouncerSession, BouncerMsg(kind: bmkSendPrivmsg,
                spServer: srvName, spTarget: cmd.text2, spText: cmd.text))
          else:
            discard spawn gConnections[idx].client.privMsg(cmd.text2, cmd.text)

      of cmdJoinChannel:
        let idx = findConnection(cmd.serverId)
        if idx >= 0:
          if gConnections[idx].fromBouncer:
            let srvName = findBouncerServerName(cmd.serverId)
            if srvName.len > 0 and gBouncerSession != nil:
              sendBouncerCmd(gBouncerSession, BouncerMsg(kind: bmkJoin,
                joinServer: srvName, joinChannel: cmd.text))
          else:
            discard spawn gConnections[idx].client.joinChannel(cmd.text)

      of cmdPartChannel:
        let idx = findConnection(cmd.serverId)
        if idx >= 0:
          if gConnections[idx].fromBouncer:
            let srvName = findBouncerServerName(cmd.serverId)
            if srvName.len > 0 and gBouncerSession != nil:
              sendBouncerCmd(gBouncerSession, BouncerMsg(kind: bmkPart,
                partServer: srvName, partChannel: cmd.text, partReason: cmd.text2))
          else:
            discard spawn gConnections[idx].client.partChannel(cmd.text, cmd.text2)

      of cmdChangeNick:
        let idx = findConnection(cmd.serverId)
        if idx >= 0:
          if gConnections[idx].fromBouncer:
            let srvName = findBouncerServerName(cmd.serverId)
            if srvName.len > 0 and gBouncerSession != nil:
              sendBouncerCmd(gBouncerSession, BouncerMsg(kind: bmkNick,
                nickServer: srvName, nickNewNick: cmd.text))
          else:
            discard spawn gConnections[idx].client.changeNick(cmd.text)

      of cmdSetAway:
        let idx = findConnection(cmd.serverId)
        if idx >= 0:
          if gConnections[idx].fromBouncer:
            let srvName = findBouncerServerName(cmd.serverId)
            if srvName.len > 0 and gBouncerSession != nil:
              sendBouncerCmd(gBouncerSession, BouncerMsg(kind: bmkAway,
                awayServer: srvName, awayMessage: cmd.text))
          else:
            discard spawn gConnections[idx].client.sendMessage("AWAY", cmd.text)

      of cmdClearAway:
        let idx = findConnection(cmd.serverId)
        if idx >= 0:
          if gConnections[idx].fromBouncer:
            let srvName = findBouncerServerName(cmd.serverId)
            if srvName.len > 0 and gBouncerSession != nil:
              sendBouncerCmd(gBouncerSession, BouncerMsg(kind: bmkBack,
                backServer: srvName))
          else:
            discard spawn gConnections[idx].client.sendMessage("AWAY")

      of cmdSetTopic:
        let idx = findConnection(cmd.serverId)
        if idx >= 0:
          if gConnections[idx].fromBouncer:
            let srvName = findBouncerServerName(cmd.serverId)
            if srvName.len > 0 and gBouncerSession != nil:
              sendBouncerCmd(gBouncerSession, BouncerMsg(kind: bmkRaw,
                rawServer: srvName, rawLine: "TOPIC " & cmd.text2 & " :" & cmd.text))
          else:
            discard spawn gConnections[idx].client.sendMessage("TOPIC", cmd.text2, cmd.text)

      of cmdSendRaw:
        let idx = findConnection(cmd.serverId)
        if idx >= 0:
          if gConnections[idx].fromBouncer:
            let srvName = findBouncerServerName(cmd.serverId)
            if srvName.len > 0 and gBouncerSession != nil:
              sendBouncerCmd(gBouncerSession, BouncerMsg(kind: bmkRaw,
                rawServer: srvName, rawLine: cmd.text.strip()))
          else:
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
          if gConnections[idx].fromBouncer:
            discard  # Bouncer handles reconnection
          else:
            let oldClient = gConnections[idx].client
            oldClient.config.autoReconnect = false
            discard spawn oldClient.disconnect()
            gConnections.delete(idx)
            # Re-read current server config (user may have edited host/port/SASL/etc.)
            var cfg: IrcClientConfig
            {.cast(gcsafe).}:
              let si = findServerIdx(cmd.serverId)
              if si >= 0:
                let s = gServers[si]
                cfg = newIrcClientConfig(host = s.host, port = s.port, nick = s.nick)
                cfg.useTls = s.useTls
                if s.password.len > 0:
                  cfg.password = s.password
                if s.saslUser.len > 0 and s.saslPass.len > 0:
                  cfg.saslUsername = s.saslUser
                  cfg.saslPassword = s.saslPass
              else:
                # Server was removed while reconnecting — use defaults
                cfg = newIrcClientConfig(host = "localhost", port = 6667, nick = "user")
            cfg.autoReconnect = true
            cfg.maxReconnectAttempts = 0
            cfg.reconnectDelayMs = 5000
            cfg.ctcpVersion = "CPS IRC GUI 1.0"
            {.cast(gcsafe).}:
              if gQuitMessage.len > 0:
                cfg.quitMessage = gQuitMessage
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
            discard spawn lagPinger(cmd.serverId, client)

      of cmdQuit:
        let idx = findConnection(cmd.serverId)
        if idx >= 0:
          if gConnections[idx].fromBouncer:
            let srvName = findBouncerServerName(cmd.serverId)
            if srvName.len > 0 and gBouncerSession != nil:
              let reason = if cmd.text.len > 0: cmd.text else: "Goodbye"
              sendBouncerCmd(gBouncerSession, BouncerMsg(kind: bmkQuit,
                quitServer: srvName, quitReason: reason))
          else:
            let reason = if cmd.text.len > 0: cmd.text else: "Goodbye"
            discard spawn gConnections[idx].client.quit(reason)

      of cmdAcceptDcc, cmdRetryDcc:
        # Look up DCC transfer info and spawn the download.
        # NOTE: gDccTransfers is accessed locklessly here. The main thread
        # also reads/writes it without the lock (tagAcceptTransfer), so
        # using gLock here previously caused a self-deadlock with the
        # withLock at the top of the loop (CPS try/finally interaction).
        var dccIp: uint32 = 0
        var dccPort: int = 0
        var dccFilename: string = ""
        var dccFilesize: int64 = 0
        {.cast(gcsafe).}:
          for t in gDccTransfers:
            if t.id == cmd.intParam:
              dccIp = t.ip
              dccPort = t.port
              dccFilename = t.filename
              dccFilesize = t.filesize
              break
        if dccIp == 0 or dccPort == 0:
          pushDccEvent(uiDccFailed, cmd.serverId, cmd.intParam,
            "Passive DCC not supported (port=0 or ip=0)")
        else:
          try:
            discard spawn dccDownloader(cmd.intParam, dccIp, dccPort,
              dccFilename, dccFilesize, cmd.serverId)
          except Exception as e:
            stderr.writeLine "[DCC] CRASH in spawn dccDownloader: " & e.msg &
              " (" & $e.name & ")"
            pushDccEvent(uiDccFailed, cmd.serverId, cmd.intParam,
              "DCC spawn failed: " & e.msg)

      of cmdShutdownAll:
        # Gracefully disconnect all IRC connections (sends QUIT to servers).
        # Runs on the event loop thread so gConnections access is safe.
        # We await all disconnect futures to ensure QUIT messages are flushed
        # to the kernel's TCP buffer before returning (critical for TLS where
        # SSL_write may return WANT_WRITE/WANT_READ).
        var disconnectFuts: seq[CpsVoidFuture]
        for conn in gConnections:
          if not conn.fromBouncer:
            conn.client.config.autoReconnect = false
            {.cast(gcsafe).}:
              if gQuitMessage.len > 0:
                conn.client.config.quitMessage = gQuitMessage
            disconnectFuts.add(conn.client.disconnect())
        if disconnectFuts.len > 0:
          await waitAll(disconnectFuts)
        gConnections.setLen(0)
        if gBouncerSession != nil and gBouncerSession.connected:
          gBouncerSession.connected = false
          gBouncerSession.stream.close()
        # All connections closed — exit the command processor so the event
        # loop thread terminates cleanly before Swift calls dlclose().
        return

    await cpsSleep(50)

proc eventLoopMain() {.thread.} =
  ## Event loop thread entry point.
  {.cast(gcsafe).}:
    try:
      runCps(commandProcessor())
    except Exception as e:
      stderr.writeLine "[EVENT LOOP] FATAL CRASH: " & e.msg & " (" & $e.name & ")"
    # Signal that the event loop thread is done (for waitShutdown).
    withLock gShutdownLock:
      gShutdownComplete = true

proc ensureEventLoop() =
  if not gEventLoopRunning:
    gEventLoopRunning = true
    createThread(gEventLoopThread, eventLoopMain)

# ============================================================
# Process UI events from the event loop thread
# ============================================================

proc syncActiveChannelContext()  # forward declaration

proc processUiEvents(): bool =
  ## Drain gEventQueue and update main-thread state.
  ## Returns true if any events were processed (state changed).
  var events: seq[UiEvent]
  withLock gLock:
    events = gEventQueue
    gEventQueue.setLen(0)
    result = gDirty
    gDirty = false
    gNotifyPending.store(false, moRelease)

  for evt in events:
    let si = findServerIdx(evt.serverId)

    case evt.kind
    of uiConnected:
      if si >= 0:
        gServers[si].connected = true
        gServers[si].connecting = false
        gStatusText = "Connected to " & gServers[si].host
        # Clear from intentional disconnects on reconnect
        let idx = gIntentionalDisconnects.find(evt.serverId)
        if idx >= 0: gIntentionalDisconnects.delete(idx)
        # Track echo-message capability
        if evt.boolParam and evt.serverId notin gEchoMessageServers:
          gEchoMessageServers.add(evt.serverId)
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
        gServers[si].lagMs = -1
        let intentional = evt.serverId in gIntentionalDisconnects
        if intentional:
          # Remove from intentional list
          let idx = gIntentionalDisconnects.find(evt.serverId)
          if idx >= 0: gIntentionalDisconnects.delete(idx)
          gServers[si].connecting = false
          gStatusText = "Disconnected from " & gServers[si].host
        else:
          # Connection lost — auto-reconnect will kick in
          gServers[si].connecting = true
          gStatusText = "Connection lost to " & gServers[si].host & " — reconnecting..."
        addSystemMessage(evt.serverId, ServerChannel,
          "Disconnected: " & evt.text)

    of uiNewMessage:
      let channelName = if evt.channel.len > 0: evt.channel else: ServerChannel
      ensureChannel(evt.serverId, channelName)
      # For DM channels, ensure both participants are in the user list
      if channelName.len > 0 and channelName[0] != '#' and channelName != ServerChannel:
        ensureDmUsers(evt.serverId, channelName, channelName)

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
      # Clear typing for this user when they send a message
      if evt.nick.len > 0:
        let ck = channelKey(evt.serverId, channelName)
        if ck in gTypingUsers:
          for i in countdown(gTypingUsers[ck].len - 1, 0):
            if gTypingUsers[ck][i].nick == evt.nick:
              gTypingUsers[ck].delete(i)
              break
        # Track last-spoke time for smart join/part filtering
        if msgKind in ["normal", "action"]:
          if ck notin gLastSpoke:
            gLastSpoke[ck] = initTable[string, float]()
          gLastSpoke[ck][evt.nick.toLowerAscii] = epochTime()

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
          if gChannels[sk][i].name.toLowerAscii == evt.channel.toLowerAscii:
            gChannels[sk][i].userCount = gUsers[ck].len
            break
      # Show join message unless suppressed by mute list or smart filter
      let isOwnJoin = si >= 0 and evt.nick == gServers[si].nick
      if isOwnJoin or not shouldSuppressJoinPart(evt.nick, evt.serverId, evt.channel):
        addSystemMessage(evt.serverId, evt.channel,
          evt.nick & " has joined " & evt.channel)
      # If this is our own join, save channel to auto-join list
      if isOwnJoin:
        syncAutoJoinChannels(evt.serverId)

    of uiUserPart:
      let ck = channelKey(evt.serverId, evt.channel)
      let isOwnPart = si >= 0 and evt.nick == gServers[si].nick
      if isOwnPart:
        # We parted — remove the channel from sidebar and clean up state
        let sk = serverKey(evt.serverId)
        if sk in gChannels:
          for i in countdown(gChannels[sk].len - 1, 0):
            if gChannels[sk][i].name.toLowerAscii == evt.channel.toLowerAscii:
              gChannels[sk].delete(i)
              break
        gMessages.del(ck)
        gUsers.del(ck)
        # Switch away if this was the active channel
        if evt.serverId == gActiveServerId and
           gActiveChannelName.toLowerAscii == evt.channel.toLowerAscii:
          let sk2 = serverKey(gActiveServerId)
          if sk2 in gChannels and gChannels[sk2].len > 0:
            gActiveChannelName = gChannels[sk2][0].name
          else:
            gActiveChannelName = ServerChannel
          syncActiveChannelContext()
        syncAutoJoinChannels(evt.serverId)
      else:
        # Someone else parted — just remove them from the user list
        if ck in gUsers:
          for i in countdown(gUsers[ck].len - 1, 0):
            if gUsers[ck][i].nick == evt.nick:
              gUsers[ck].delete(i)
              break
        let sk = serverKey(evt.serverId)
        if sk in gChannels:
          for i in 0 ..< gChannels[sk].len:
            if gChannels[sk][i].name.toLowerAscii == evt.channel.toLowerAscii:
              if ck in gUsers:
                gChannels[sk][i].userCount = gUsers[ck].len
              break
        let reason = if evt.text.len > 0: " (" & evt.text & ")" else: ""
        if not shouldSuppressJoinPart(evt.nick, evt.serverId, evt.channel):
          addSystemMessage(evt.serverId, evt.channel,
            evt.nick & " has left " & evt.channel & reason)

    of uiUserQuit:
      # Remove user from all channels on this server where they were present,
      # and post the quit message only to those channels.
      let sk = serverKey(evt.serverId)
      let reason = if evt.text.len > 0: " (" & evt.text & ")" else: ""
      if sk in gChannels:
        for ch in gChannels[sk]:
          if ch.isDm: continue
          let ck = channelKey(evt.serverId, ch.name)
          if ck in gUsers:
            var wasPresent = false
            for i in countdown(gUsers[ck].len - 1, 0):
              if gUsers[ck][i].nick == evt.nick:
                gUsers[ck].delete(i)
                wasPresent = true
                break
            if wasPresent and ch.name != ServerChannel:
              if not shouldSuppressJoinPart(evt.nick, evt.serverId, ch.name):
                addSystemMessage(evt.serverId, ch.name,
                  evt.nick & " has quit" & reason)

    of uiUserNick:
      # Update nick in all channels where the user is present,
      # and post the nick change message only to those channels.
      let sk = serverKey(evt.serverId)
      if sk in gChannels:
        for ch in gChannels[sk]:
          let ck = channelKey(evt.serverId, ch.name)
          if ck in gUsers:
            for i in 0 ..< gUsers[ck].len:
              if gUsers[ck][i].nick == evt.text2:  # old nick
                gUsers[ck][i].nick = evt.nick       # new nick
                if ch.name != ServerChannel:
                  addSystemMessage(evt.serverId, ch.name,
                    evt.text2 & " is now known as " & evt.nick)
                break
      # Check if it's our nick
      if si >= 0 and evt.text2 == gServers[si].nick:
        gServers[si].nick = evt.nick

    of uiTopicChange:
      let sk = serverKey(evt.serverId)
      let plainTopic = sanitizeUtf8(stripMircCodes(evt.text))
      if sk in gChannels:
        for i in 0 ..< gChannels[sk].len:
          if gChannels[sk][i].name.toLowerAscii == evt.channel.toLowerAscii:
            gChannels[sk][i].topic = plainTopic
            break
      if evt.serverId == gActiveServerId and evt.channel == gActiveChannelName:
        gCurrentTopic = plainTopic
      if evt.nick.len > 0:
        addSystemMessage(evt.serverId, evt.channel,
          evt.nick & " changed the topic to: " & plainTopic)

    of uiUserList:
      ensureChannel(evt.serverId, evt.channel)
      let ck = channelKey(evt.serverId, evt.channel)
      if ck notin gUsers:
        gUsers[ck] = @[]
      # Parse user entries (may have @, +, %, ~, & prefixes)
      # With userhost-in-names cap, entries are like @nick!user@host
      for raw in evt.users:
        if raw.len == 0:
          continue
        var nick = raw
        var prefix = ""
        if nick[0] in {'@', '+', '%', '~', '&'}:
          prefix = $nick[0]
          nick = nick[1..^1]
        # Strip !user@host suffix (userhost-in-names cap)
        let bangIdx = nick.find('!')
        if bangIdx >= 0:
          nick = nick[0 ..< bangIdx]
        nick = sanitizeUtf8(nick)
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
          if gChannels[sk][i].name.toLowerAscii == evt.channel.toLowerAscii:
            gChannels[sk][i].userCount = gUsers[ck].len
            break

    of uiModeChange:
      # Parse mode changes and update user prefixes
      if evt.channel.len > 0 and evt.channel[0] == '#' and evt.text.len > 0:
        let ck = channelKey(evt.serverId, evt.channel)
        if ck in gUsers:
          var adding = true
          var paramIdx = 0
          for ch in evt.text:
            case ch
            of '+': adding = true
            of '-': adding = false
            of 'o', 'v', 'h', 'a', 'q':
              if paramIdx < evt.users.len:
                let targetNick = evt.users[paramIdx]
                inc paramIdx
                let newPrefix = case ch
                  of 'q': "~"
                  of 'a': "&"
                  of 'o': "@"
                  of 'h': "%"
                  of 'v': "+"
                  else: ""
                for i in 0 ..< gUsers[ck].len:
                  if gUsers[ck][i].nick == targetNick:
                    if adding:
                      gUsers[ck][i].prefix = newPrefix
                    else:
                      if gUsers[ck][i].prefix == newPrefix:
                        gUsers[ck][i].prefix = ""
                    break
            of 'b', 'e', 'I', 'k':
              # Modes that take a parameter but don't affect user prefix
              inc paramIdx
            of 'l':
              if adding: inc paramIdx
            else:
              discard  # Parameter-less modes
      addSystemMessage(evt.serverId, evt.channel,
        "Mode " & evt.channel & " " & evt.text &
        (if evt.users.len > 0: " " & evt.users.join(" ") else: ""))

    of uiError:
      # Detect reconnect messages to update server state
      if si >= 0 and evt.text.startsWith("Reconnecting in"):
        gServers[si].connecting = true
        gStatusText = evt.text
      elif si >= 0 and evt.text.startsWith("Connection failed"):
        gServers[si].connecting = true  # Still attempting
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
      let ck = channelKey(evt.serverId, evt.channel)
      if ck notin gTypingUsers:
        gTypingUsers[ck] = @[]
      if evt.boolParam:
        # Add or update typing timestamp
        var found = false
        for i in 0 ..< gTypingUsers[ck].len:
          if gTypingUsers[ck][i].nick == evt.nick:
            gTypingUsers[ck][i].time = epochTime()
            found = true
            break
        if not found:
          gTypingUsers[ck].add((nick: evt.nick, time: epochTime()))
      else:
        # Remove from typing
        for i in countdown(gTypingUsers[ck].len - 1, 0):
          if gTypingUsers[ck][i].nick == evt.nick:
            gTypingUsers[ck].delete(i)
            break
      # Rebuild typing indicator text immediately
      updateTypingText()

    of uiNickChange:
      discard

    of uiChghost:
      if gActiveServerId == evt.serverId and gActiveChannelName.len > 0:
        addSystemMessage(evt.serverId, gActiveChannelName,
          evt.nick & " changed host to " & evt.text)

    of uiSetname:
      if gActiveServerId == evt.serverId and gActiveChannelName.len > 0:
        addSystemMessage(evt.serverId, gActiveChannelName,
          evt.nick & " changed realname to " & evt.text)

    of uiAccount:
      if gActiveServerId == evt.serverId and gActiveChannelName.len > 0:
        let action = if evt.text == "*": "logged out" else: "logged in as " & evt.text
        addSystemMessage(evt.serverId, gActiveChannelName,
          evt.nick & " " & action)

    of uiBatchComplete:
      let btype = evt.text
      if btype == "netsplit" or btype == "netjoin":
        let verb = if btype == "netsplit": "quit" else: "rejoined"
        let summary = if evt.users.len <= 5:
                        evt.users.join(", ")
                      else:
                        evt.users[0 ..< 5].join(", ") & " and " &
                          $(evt.users.len - 5) & " others"
        let server = if evt.channel.len > 0: " (" & evt.channel & ")" else: ""
        let label = if btype == "netsplit": "Netsplit" else: "Netjoin"
        # Show in all channels on this server
        let sk = serverKey(evt.serverId)
        if sk in gChannels:
          for ch in gChannels[sk]:
            if ch.name != ServerChannel:
              addSystemMessage(evt.serverId, ch.name,
                label & server & ": " & summary & " " & verb)
      elif btype == "chathistory":
        # Replay messages from chathistory batch — already forwarded individually
        discard

    of uiMonOnline:
      if gActiveServerId == evt.serverId:
        for nick in evt.users:
          addSystemMessage(evt.serverId,
            if gActiveChannelName.len > 0: gActiveChannelName else: ServerChannel,
            "MONITOR: " & nick & " is now online")

    of uiMonOffline:
      if gActiveServerId == evt.serverId:
        for nick in evt.users:
          addSystemMessage(evt.serverId,
            if gActiveChannelName.len > 0: gActiveChannelName else: ServerChannel,
            "MONITOR: " & nick & " is now offline")

    of uiDccProgress:
      let tid = evt.intParam
      let parts = evt.text.split('|')
      let progress = try: parseFloat(parts[0]) except: 0.0
      let received = if parts.len > 1: (try: parseBiggestInt(parts[1]) except: 0'i64) else: 0'i64
      for i in 0 ..< gDccTransfers.len:
        if gDccTransfers[i].id == tid:
          gDccTransfers[i].progress = progress
          gDccTransfers[i].bytesReceived = received
          break

    of uiDccComplete:
      let tid = evt.intParam
      for i in 0 ..< gDccTransfers.len:
        if gDccTransfers[i].id == tid:
          gDccTransfers[i].state = dccDone
          gDccTransfers[i].progress = 1.0
          gDccTransfers[i].outputPath = evt.text
          addSystemMessage(evt.serverId, ServerChannel,
            "DCC transfer complete: " & gDccTransfers[i].filename)
          break

    of uiDccFailed:
      let tid = evt.intParam
      for i in 0 ..< gDccTransfers.len:
        if gDccTransfers[i].id == tid:
          gDccTransfers[i].state = dccFailed
          gDccTransfers[i].errorText = evt.text
          addSystemMessage(evt.serverId, ServerChannel,
            "DCC transfer failed: " & gDccTransfers[i].filename &
            (if evt.text.len > 0: " — " & evt.text else: ""))
          break

# ============================================================
# Tab completion / @-mention autocomplete
# ============================================================

proc levenshtein(a, b: string): int =
  ## Levenshtein edit distance, single-row O(min(m,n)) space.
  let m = a.len
  let n = b.len
  if m == 0: return n
  if n == 0: return m
  var row = newSeq[int](n + 1)
  for j in 0 .. n:
    row[j] = j
  for i in 1 .. m:
    var prev = row[0]
    row[0] = i
    for j in 1 .. n:
      let old = row[j]
      let cost = if a[i - 1] == b[j - 1]: 0 else: 1
      row[j] = min(min(row[j] + 1, row[j - 1] + 1), prev + cost)
      prev = old
  row[n]

proc fuzzyScore(query, candidate: string): int =
  ## Lower is better.  0 = exact prefix, 9999 = no match.
  let q = query.toLowerAscii
  let c = candidate.toLowerAscii
  if q.len == 0:
    return 0
  if c.startsWith(q):
    return 0
  let subIdx = c.find(q)
  if subIdx >= 0:
    return subIdx + 1
  let prefixLen = min(q.len, c.len)
  let prefixDist = levenshtein(q, c[0 ..< prefixLen])
  let maxDist = (q.len + 1) div 2
  if prefixDist <= maxDist:
    return 100 + prefixDist
  let fullDist = levenshtein(q, c)
  if fullDist <= maxDist + 1:
    return 200 + fullDist
  return 9999

proc dismissCompletion() =
  gCompletionActive = false
  gCompletionSuggestions = @[]
  gCompletionIndex = -1
  gMentionAtPos = -1

const slashCommands = [
  "/join", "/part", "/nick", "/msg", "/me", "/topic", "/quit", "/raw",
  "/away", "/back", "/disconnect", "/close", "/clear", "/whois", "/mode",
  "/notice", "/ignore", "/unignore", "/highlight", "/server", "/log",
  "/debug", "/monitor", "/accept", "/decline", "/transfers", "/help",
  "/kick", "/ban", "/ctcp", "/list", "/invite", "/oper", "/scrollback",
  "/nickcolor", "/unnickcolor", "/query", "/mutejp", "/unmutejp",
  "/smartfilter", "/bouncer", "/detach", "/attach",
]

proc computeCompletions() =
  ## Tab-complete: match partial word at end of input.
  ## If input starts with '/', complete slash commands instead of nicks.
  gCompletionSuggestions = @[]
  gCompletionActive = false
  gCompletionIndex = -1
  gMentionAtPos = -1

  if gInputText.len == 0 or gActiveServerId < 0:
    return

  # Slash command completion: when input starts with / and has no space yet
  if gInputText[0] == '/' and gInputText.find(' ') < 0:
    let partialLower = gInputText.toLowerAscii
    for cmd in slashCommands:
      if cmd.startsWith(partialLower):
        gCompletionSuggestions.add(cmd)
    gCompletionSuggestions.sort()
    if gCompletionSuggestions.len > 0:
      gCompletionActive = true
      gCompletionIndex = 0
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

proc computeMentionCompletions() =
  ## @-mention: detect '@' before cursor, fuzzy-match users.
  ## Called on every input change.
  if gInputText.len == 0 or gActiveServerId < 0:
    dismissCompletion()
    return

  # Scan backwards from end for '@'
  let cursorPos = gInputText.len  # SwiftUI TextField doesn't expose cursor; use end
  var atPos = -1
  for i in countdown(cursorPos - 1, 0):
    if gInputText[i] == '@':
      atPos = i
      break
    if gInputText[i] == ' ':
      break

  if atPos < 0:
    dismissCompletion()
    return

  # '@' must be at start or preceded by a space
  if atPos > 0 and gInputText[atPos - 1] != ' ':
    dismissCompletion()
    return

  let query = gInputText[atPos + 1 ..< cursorPos]

  # Get my nick to exclude self
  let si = findServerIdx(gActiveServerId)
  let myNick = if si >= 0: gServers[si].nick else: ""

  # Score and filter users
  let ck = channelKey(gActiveServerId, gActiveChannelName)
  if ck notin gUsers:
    dismissCompletion()
    return

  var scored: seq[tuple[score: int, nick: string]] = @[]
  for u in gUsers[ck]:
    let nick = u.nick
    if nick == myNick: continue
    let s = fuzzyScore(query, nick)
    if s < 9999:
      scored.add((s, nick))

  scored.sort(proc(a, b: tuple[score: int, nick: string]): int =
    result = cmp(a.score, b.score)
    if result == 0:
      result = cmp(a.nick.toLowerAscii, b.nick.toLowerAscii)
  )

  const maxSuggestions = 10
  gCompletionSuggestions = @[]
  for i in 0 ..< min(scored.len, maxSuggestions):
    gCompletionSuggestions.add(scored[i].nick)

  if gCompletionSuggestions.len == 0:
    dismissCompletion()
    return

  gCompletionActive = true
  gMentionAtPos = atPos
  if gCompletionIndex < 0 or gCompletionIndex >= gCompletionSuggestions.len:
    gCompletionIndex = 0

proc acceptCompletion() =
  if not gCompletionActive or gCompletionIndex < 0 or
     gCompletionIndex >= gCompletionSuggestions.len:
    return

  let completed = gCompletionSuggestions[gCompletionIndex]

  if gMentionAtPos >= 0:
    # @-mention mode: replace from '@' to end of query
    let before = gInputText[0 ..< gMentionAtPos]
    let suffix = if gMentionAtPos == 0: ": " else: " "
    gInputText = before & completed & suffix
  elif completed.len > 0 and completed[0] == '/':
    # Slash command completion: replace entire input with command + space
    gInputText = completed & " "
  else:
    # Tab-complete mode: replace last partial word
    let lastSpace = gInputText.rfind(' ')
    let prefix = if lastSpace >= 0: gInputText[0 .. lastSpace] else: ""
    let suffix = if lastSpace < 0: ": " else: " "
    gInputText = prefix & completed & suffix

  dismissCompletion()

# ============================================================
# State patch builder
# ============================================================

proc keybindsToJson(): string =
  ## Serialize keybinds to JSON array string for the Swift shortcut monitor.
  var arr = newJArray()
  for kb in gKeybinds:
    var obj = newJObject()
    obj["id"] = %kb.id
    obj["key"] = %kb.key
    obj["modifiers"] = %kb.modifiers
    obj["label"] = %kb.label
    # For channel-index shortcuts, use synthetic tags (1001..1009)
    if kb.id.startsWith("channel") and kb.id.len == 8 and kb.actionTag == tagSwitchChannelByIndex:
      let digit = kb.id[7]
      if digit >= '1' and digit <= '9':
        obj["actionTag"] = %(1000 + ord(digit) - ord('0'))
      else:
        obj["actionTag"] = %kb.actionTag.int
    else:
      obj["actionTag"] = %kb.actionTag.int
    arr.add(obj)
  $arr

proc buildPatch(includeEditableFields: bool): seq[byte] =
  ## Build JSON state patch. When includeEditableFields is false (Poll),
  ## user-editable text fields are excluded to avoid overwriting in-progress typing.
  var patch = newJObject()

  # Servers
  var serversArr = newJArray()
  for s in gServers:
    var obj = newJObject()
    obj["id"] = %s.id
    obj["name"] = %sanitizeUtf8(s.name)
    obj["host"] = %sanitizeUtf8(s.host)
    obj["port"] = %s.port
    obj["nick"] = %sanitizeUtf8(s.nick)
    obj["useTls"] = %s.useTls
    obj["connected"] = %s.connected
    obj["connecting"] = %s.connecting
    obj["lagMs"] = %s.lagMs
    obj["isAway"] = %s.isAway
    serversArr.add(obj)
  patch["servers"] = serversArr

  # Channels for active server
  var channelsArr = newJArray()
  let sk = serverKey(gActiveServerId)
  if sk in gChannels:
    for ch in gChannels[sk]:
      var obj = newJObject()
      obj["id"] = %ch.id
      obj["serverId"] = %ch.serverId
      obj["name"] = %sanitizeUtf8(ch.name)
      obj["topic"] = %sanitizeUtf8(ch.topic)
      obj["unread"] = %ch.unread
      obj["mentions"] = %ch.mentions
      obj["userCount"] = %ch.userCount
      obj["isChannel"] = %ch.isChannel
      obj["isDm"] = %ch.isDm
      channelsArr.add(obj)
  patch["channels"] = channelsArr

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
      obj["timestampFull"] = %m.timestampFull
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
      obj["nick"] = %sanitizeUtf8(u.nick)
      obj["prefix"] = %sanitizeUtf8(u.prefix)
      obj["isAway"] = %u.isAway
      usersArr.add(obj)
  patch["users"] = usersArr

  # Scalar state (non-editable — always included)
  patch["showUserList"] = %gShowUserList
  patch["statusText"] = %sanitizeUtf8(gStatusText)
  patch["typingText"] = %sanitizeUtf8(gTypingText)
  patch["currentTopic"] = %sanitizeUtf8(gCurrentTopic)
  patch["currentUserCount"] = %gCurrentUserCount
  patch["activeChannelIsChannel"] = %(gActiveChannelName.len > 0 and gActiveChannelName[0] == '#')
  patch["activeChannelIsDm"] = %(gActiveChannelName.len > 0 and gActiveChannelName[0] != '#' and gActiveChannelName != ServerChannel)
  patch["lastMessageId"] = %(gNextMessageId - 1)
  patch["pollActive"] = %gPollActive

  # Completion state
  var compArr = newJArray()
  for s in gCompletionSuggestions:
    compArr.add(%s)
  patch["completionSuggestions"] = compArr
  patch["completionActive"] = %gCompletionActive
  patch["completionIndex"] = %gCompletionIndex

  # DCC transfers
  var dccArr = newJArray()
  var pendingCount = 0
  for t in gDccTransfers:
    var obj = newJObject()
    obj["id"] = %t.id
    obj["nick"] = %sanitizeUtf8(t.nick)
    obj["filename"] = %sanitizeUtf8(t.filename)
    let sizeStr = if t.filesize <= 0:
                    "Unknown size"
                  elif t.filesize > 1024 * 1024:
                    $(t.filesize div (1024 * 1024)) & " MB"
                  elif t.filesize > 1024:
                    $(t.filesize div 1024) & " KB"
                  else:
                    $t.filesize & " B"
    obj["sizeText"] = %sizeStr
    obj["status"] = %(case t.state
      of dccPending: "pending"
      of dccActive: "active"
      of dccDone: "done"
      of dccDeclined: "declined"
      of dccFailed: "failed")
    obj["progress"] = %t.progress
    obj["bytesReceived"] = %t.bytesReceived
    obj["errorText"] = %t.errorText
    obj["outputPath"] = %t.outputPath
    dccArr.add(obj)
    if t.state == dccPending: inc pendingCount
  patch["dccTransfers"] = dccArr
  patch["pendingTransferCount"] = %pendingCount

  # WHOIS (sanitize — IRC data may not be valid UTF-8)
  patch["whoisNick"] = %sanitizeUtf8(gWhoisNick)
  patch["whoisInfo"] = %sanitizeUtf8(gWhoisInfo)
  patch["selectedUserNick"] = %sanitizeUtf8(gSelectedUserNick)

  # Action param fields
  patch["actionServerId"] = %gActionServerId
  patch["actionNick"] = %gActionNick
  patch["actionColor"] = %gActionColor
  patch["actionChannelName"] = %gActionChannelName
  patch["actionTransferId"] = %gActionTransferId

  # Nick color overrides (serialized as JSON string for Swift)
  var nickColorsObj = newJObject()
  for nick, color in gNickColors:
    nickColorsObj[nick] = %color
  patch["nickColors"] = %($nickColorsObj)

  # Keybinds (serialized as JSON string for Swift shortcut monitor)
  patch["keybinds"] = %keybindsToJson()

  # Settings state (always included so Swift shows current values)
  patch["loggingEnabled"] = %gLoggingEnabled
  patch["logDir"] = %gLogDir
  patch["bouncerPassword"] = %gBouncerPassword
  # Serialize lists as JSON strings for Swift
  var ignArr = newJArray()
  for n in gIgnoreList: ignArr.add(%n)
  patch["ignoreListJson"] = %($ignArr)
  var hlArr = newJArray()
  for w in gHighlightWords: hlArr.add(%w)
  patch["highlightWordsJson"] = %($hlArr)
  var jpmArr = newJArray()
  for n in gJoinPartMuteList: jpmArr.add(%n)
  patch["joinPartMuteListJson"] = %($jpmArr)

  # Server editor JSON (always included so Swift form sees Nim-populated data)
  patch["editServerJson"] = %gEditServerJson

  # Fields only included when the bridge explicitly modifies them
  # (not during Poll, to avoid overwriting in-progress typing, sheet state,
  # or active channel/server selection which flickers on stale poll patches)
  if includeEditableFields:
    patch["activeServerId"] = %gActiveServerId
    patch["activeChannelName"] = %gActiveChannelName
    patch["inputText"] = %gInputText
    patch["connectHost"] = %gConnectHost
    patch["connectPort"] = %gConnectPort
    patch["connectNick"] = %gConnectNick
    patch["connectUseTls"] = %gConnectUseTls
    patch["connectPassword"] = %gConnectPassword
    patch["connectSaslUser"] = %gConnectSaslUser
    patch["connectSaslPass"] = %gConnectSaslPass
    patch["showConnectForm"] = %gShowConnectForm
    patch["showTransfers"] = %gShowTransfers
    patch["smartFilterEnabled"] = %gSmartFilterEnabled
    patch["smartFilterTimeout"] = %gSmartFilterTimeout
    patch["quitMessage"] = %gQuitMessage
    patch["fontSize"] = %gFontSize
    patch["messageDensity"] = %gMessageDensity
    patch["timestampFormat"] = %gTimestampFormat

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
    gActionServerId = jsonInt(node, "actionServerId", gActionServerId)
    gActionNick = jsonString(node, "actionNick", gActionNick)
    gActionColor = jsonString(node, "actionColor", gActionColor)
    gActionChannelName = jsonString(node, "actionChannelName", gActionChannelName)
    gActionTransferId = jsonInt(node, "actionTransferId", gActionTransferId)
    gJoinChannelText = jsonString(node, "joinChannelText", gJoinChannelText)
    gChannelSwitcherText = jsonString(node, "channelSwitcherText", gChannelSwitcherText)
    gCompletionSelectIndex = jsonInt(node, "completionSelectIndex", gCompletionSelectIndex)
    gSmartFilterEnabled = jsonBool(node, "smartFilterEnabled", gSmartFilterEnabled)
    gSmartFilterTimeout = jsonInt(node, "smartFilterTimeout", gSmartFilterTimeout)
    gQuitMessage = jsonString(node, "quitMessage", gQuitMessage)
    gFontSize = jsonInt(node, "fontSize", gFontSize)
    gMessageDensity = jsonString(node, "messageDensity", gMessageDensity)
    gTimestampFormat = jsonString(node, "timestampFormat", gTimestampFormat)
    gLoggingEnabled = jsonBool(node, "loggingEnabled", gLoggingEnabled)
    gLogDir = jsonString(node, "logDir", gLogDir)
    gBouncerPassword = jsonString(node, "bouncerPassword", gBouncerPassword)
    gIgnoreListJson = jsonString(node, "ignoreListJson", gIgnoreListJson)
    gHighlightWordsJson = jsonString(node, "highlightWordsJson", gHighlightWordsJson)
    gJoinPartMuteListJson = jsonString(node, "joinPartMuteListJson", gJoinPartMuteListJson)
    gShowUserList = jsonBool(node, "showUserList", gShowUserList)
    gEditingServerId = jsonInt(node, "editingServerId", gEditingServerId)
    gEditServerJson = jsonString(node, "editServerJson", gEditServerJson)

    # Sync activeServerId and activeChannelName if provided
    let snapServerId = jsonInt(node, "activeServerId", gActiveServerId)
    if snapServerId >= 0 and findServerIdx(snapServerId) >= 0:
      # Save current channel for old server before switching (skip *server*)
      if gActiveServerId >= 0 and gActiveChannelName.len > 0 and
         gActiveChannelName != ServerChannel and snapServerId != gActiveServerId:
        gLastChannelPerServer[gActiveServerId] = gActiveChannelName
      gActiveServerId = snapServerId
    let snapChannel = jsonString(node, "activeChannelName", "")
    # Only update channel from snapshot if Swift sends a non-empty value.
    # Swift resets activeChannelName to "" on server switch, but Nim
    # restores the correct channel in tagSwitchServer. We must not
    # overwrite it on subsequent tagPoll dispatches.
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
    initLock(gShutdownLock)
    # Create notification pipe (non-blocking)
    var fds: array[2, cint]
    if posix.pipe(fds) == 0:
      gNotifyPipeRead = fds[0]
      gNotifyPipeWrite = fds[1]
      # Set both ends non-blocking
      discard fcntl(gNotifyPipeRead, F_SETFL,
        fcntl(gNotifyPipeRead, F_GETFL) or O_NONBLOCK)
      discard fcntl(gNotifyPipeWrite, F_SETFL,
        fcntl(gNotifyPipeWrite, F_GETFL) or O_NONBLOCK)
    gNotifyPending.store(false)
    gInitialized = true

# ============================================================
# Update active channel context
# ============================================================

proc updateTypingText() =
  ## Build typing indicator text from tracked users, expiring old entries.
  let ck = channelKey(gActiveServerId, gActiveChannelName)
  if ck notin gTypingUsers or gTypingUsers[ck].len == 0:
    gTypingText = ""
    return
  let now = epochTime()
  const typingTimeout = 6.0  # seconds
  # Remove expired entries
  for i in countdown(gTypingUsers[ck].len - 1, 0):
    if now - gTypingUsers[ck][i].time > typingTimeout:
      gTypingUsers[ck].delete(i)
  if gTypingUsers[ck].len == 0:
    gTypingText = ""
  elif gTypingUsers[ck].len == 1:
    gTypingText = gTypingUsers[ck][0].nick & " is typing..."
  elif gTypingUsers[ck].len == 2:
    gTypingText = gTypingUsers[ck][0].nick & " and " & gTypingUsers[ck][1].nick & " are typing..."
  else:
    gTypingText = gTypingUsers[ck][0].nick & " and " & $(gTypingUsers[ck].len - 1) & " others are typing..."

proc syncActiveChannelContext() =
  ## Update current topic and user count from active channel state.
  if gActiveServerId < 0 or gActiveChannelName.len == 0:
    gCurrentTopic = ""
    gCurrentUserCount = 0
    gTypingText = ""
    return
  let sk = serverKey(gActiveServerId)
  if sk in gChannels:
    for ch in gChannels[sk]:
      if ch.name.toLowerAscii == gActiveChannelName.toLowerAscii:
        gCurrentTopic = ch.topic
        gCurrentUserCount = ch.userCount
        updateTypingText()
        return
  gCurrentTopic = ""
  gCurrentUserCount = 0
  gTypingText = ""

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
  of tagDisconnectServer: "DisconnectServer"
  of tagReconnectServer: "ReconnectServer"
  of tagConnectServer: "ConnectServer"
  of tagRemoveServerById: "RemoveServerById"
  of tagWhoisUser: "WhoisUser"
  of tagStartDm: "StartDm"
  of tagIgnoreUser: "IgnoreUser"
  of tagHighlightUser: "HighlightUser"
  of tagShowTransfers: "ShowTransfers"
  of tagHideTransfers: "HideTransfers"
  of tagAcceptTransfer: "AcceptTransfer"
  of tagDeclineTransfer: "DeclineTransfer"
  of tagShowJoinChannel: "ShowJoinChannel"
  of tagHideJoinChannel: "HideJoinChannel"
  of tagSubmitJoinChannel: "SubmitJoinChannel"
  of tagSelectUser: "SelectUser"
  of tagRequestWhois: "RequestWhois"
  of tagHideWhois: "HideWhois"
  of tagInputChanged: "InputChanged"
  of tagCompletionSelect: "CompletionSelect"
  of tagShowSettings: "ShowSettings"
  of tagHideSettings: "HideSettings"
  of tagSetFontSize: "SetFontSize"
  of tagSetMessageDensity: "SetMessageDensity"
  of tagSetTimestampFormat: "SetTimestampFormat"
  of tagUpdateSidebarFilter: "UpdateSidebarFilter"
  of tagToggleAway: "ToggleAway"
  of tagShowChannelInfo: "ShowChannelInfo"
  of tagHideChannelInfo: "HideChannelInfo"
  of tagToggleSearch: "ToggleSearch"
  of tagClearSearch: "ClearSearch"
  of tagUpdateSearch: "UpdateSearch"
  of tagSelectNetwork: "SelectNetwork"
  of tagHistoryUp: "HistoryUp"
  of tagHistoryDown: "HistoryDown"
  of tagMuteJoinPart: "MuteJoinPart"
  of tagSetSmartFilter: "SetSmartFilter"
  of tagSetSmartFilterTimeout: "SetSmartFilterTimeout"
  of tagSwitchChannelByIndex: "SwitchChannelByIndex"
  of tagPrevChannel: "PrevChannel"
  of tagNextChannel: "NextChannel"
  of tagNextUnreadChannel: "NextUnreadChannel"
  of tagClearScrollback: "ClearScrollback"
  of tagShowChannelSwitcher: "ShowChannelSwitcher"
  of tagHideChannelSwitcher: "HideChannelSwitcher"
  of tagSwitchChannelFromSwitcher: "SwitchChannelFromSwitcher"
  of tagSetNickColor: "SetNickColor"
  of tagPrevServer: "PrevServer"
  of tagNextServer: "NextServer"
  of tagPrevUnreadChannel: "PrevUnreadChannel"
  of tagShowKeybindSheet: "ShowKeybindSheet"
  of tagHideKeybindSheet: "HideKeybindSheet"
  of tagUpdateKeybind: "UpdateKeybind"
  of tagResetKeybinds: "ResetKeybinds"
  of tagSetQuitMessage: "SetQuitMessage"
  of tagAppShutdown: "AppShutdown"
  of tagSetLoggingEnabled: "SetLoggingEnabled"
  of tagSetLogDir: "SetLogDir"
  of tagSetBouncerPassword: "SetBouncerPassword"
  of tagSetShowUserList: "SetShowUserList"
  of tagUpdateIgnoreList: "UpdateIgnoreList"
  of tagUpdateHighlightWords: "UpdateHighlightWords"
  of tagUpdateJoinPartMuteList: "UpdateJoinPartMuteList"
  of tagOpenKeyboardShortcuts: "OpenKeyboardShortcuts"
  of tagEditServer: "EditServer"
  of tagHideServerEditor: "HideServerEditor"
  of tagSaveServerConfig: "SaveServerConfig"
  of tagDeleteServer: "DeleteServer"
  of tagDuplicateServer: "DuplicateServer"
  of tagMoveServer: "MoveServer"
  of tagMoveChannel: "MoveChannel"
  else: "Unknown"

# ============================================================
# Dispatch
# ============================================================

proc bridgeDispatch(payload: ptr uint8, payloadLen: uint32,
                    outp: ptr GUIBridgeDispatchOutput): int32 {.cdecl.} =
  ensureInit()

  let actionTag = decodeActionTag(payload, payloadLen)
  let prevServerId = gActiveServerId
  syncFromSnapshot(payload, payloadLen)

  var pollSkipped = false  # true when poll found no dirty state → skip buildPatch

  case actionTag
  of tagPoll:
    let hadEvents = processUiEvents()
    # Check if typing indicators need expiry (even when no IRC events arrived)
    let ck = channelKey(gActiveServerId, gActiveChannelName)
    let hasTyping = ck in gTypingUsers and gTypingUsers[ck].len > 0
    if not hadEvents and not hasTyping:
      pollSkipped = true
    else:
      syncActiveChannelContext()
      # Clear unread for active channel
      if gActiveServerId >= 0 and gActiveChannelName.len > 0:
        let sk = serverKey(gActiveServerId)
        if sk in gChannels:
          for i in 0 ..< gChannels[sk].len:
            if gChannels[sk][i].name.toLowerAscii == gActiveChannelName.toLowerAscii:
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
      # Save current channel for old server before switching to new one (skip *server*)
      if gActiveServerId >= 0 and gActiveChannelName.len > 0 and
         gActiveChannelName != ServerChannel:
        gLastChannelPerServer[gActiveServerId] = gActiveChannelName
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
      if gActiveServerId notin gIntentionalDisconnects:
        gIntentionalDisconnects.add(gActiveServerId)
      let si = findServerIdx(gActiveServerId)
      if si >= 0:
        gServers[si].connected = false
        gServers[si].connecting = false
        addSystemMessage(gActiveServerId, ServerChannel,
          "Disconnected from " & gServers[si].host)
      ensureEventLoop()
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdDisconnect,
          serverId: gActiveServerId))
      gStatusText = "Disconnected"

  of tagSwitchServer:
    if prevServerId == gActiveServerId:
      # Same server clicked — navigate to server console
      gActiveChannelName = ServerChannel
      syncActiveChannelContext()
    else:
      let si = findServerIdx(gActiveServerId)
      if si >= 0:
        gStatusText = gServers[si].name
        # Restore last viewed channel for this server
        let sk = serverKey(gActiveServerId)
        if gActiveServerId in gLastChannelPerServer:
          gActiveChannelName = gLastChannelPerServer[gActiveServerId]
        elif sk in gChannels:
          var found = false
          for ch in gChannels[sk]:
            if ch.name != ServerChannel:
              gActiveChannelName = ch.name
              found = true
              break
          if not found:
            gActiveChannelName = ServerChannel
        else:
          gActiveChannelName = ServerChannel
      syncActiveChannelContext()

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
    # Channel name is in snapshot — remember it for this server (skip *server*)
    if gActiveServerId >= 0 and gActiveChannelName.len > 0 and
       gActiveChannelName != ServerChannel:
      gLastChannelPerServer[gActiveServerId] = gActiveChannelName
    syncActiveChannelContext()
    gSelectedUserNick = ""
    # Clear unread
    if gActiveServerId >= 0 and gActiveChannelName.len > 0:
      let sk = serverKey(gActiveServerId)
      if sk in gChannels:
        for i in 0 ..< gChannels[sk].len:
          if gChannels[sk][i].name.toLowerAscii == gActiveChannelName.toLowerAscii:
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
    let targetChan = if gActionChannelName.len > 0: gActionChannelName
                     else: gActiveChannelName
    if gActiveServerId >= 0 and targetChan.len > 0 and
       targetChan != ServerChannel:
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdPartChannel,
          serverId: gActiveServerId, text: targetChan))
      syncAutoJoinChannels(gActiveServerId)

  of tagCloseChannel:
    let targetChan = if gActionChannelName.len > 0: gActionChannelName
                     else: gActiveChannelName
    if gActiveServerId >= 0 and targetChan.len > 0 and
       targetChan != ServerChannel:
      if targetChan[0] == '#':
        withLock gLock:
          gCommandQueue.add(BridgeCommand(kind: cmdPartChannel,
            serverId: gActiveServerId, text: targetChan))
      let sk = serverKey(gActiveServerId)
      if sk in gChannels:
        for i in countdown(gChannels[sk].len - 1, 0):
          if gChannels[sk][i].name.toLowerAscii == targetChan.toLowerAscii:
            gChannels[sk].delete(i)
            break
      let ck = channelKey(gActiveServerId, targetChan)
      gMessages.del(ck)
      gUsers.del(ck)
      # If we closed the active channel, switch to another
      if gActiveChannelName.toLowerAscii == targetChan.toLowerAscii:
        if sk in gChannels and gChannels[sk].len > 0:
          gActiveChannelName = gChannels[sk][0].name
        else:
          gActiveChannelName = ServerChannel
      syncAutoJoinChannels(gActiveServerId)
      syncActiveChannelContext()

  of tagSendMessage:
    # If completion popup is active, Enter accepts the selection instead of sending
    if gCompletionActive:
      acceptCompletion()
    elif gActiveServerId >= 0 and gActiveChannelName.len > 0:
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
            # Only add local message if echo-message is not active
            # (with echo-message, server echoes our message back)
            if gActiveServerId notin gEchoMessageServers:
              let si = findServerIdx(gActiveServerId)
              let myNick = if si >= 0: gServers[si].nick else: "me"
              addMessage(gActiveServerId, gActiveChannelName, "normal",
                         myNick, text, false, true)
          else:
            addErrorMessage(gActiveServerId, ServerChannel,
              "Cannot send messages to server window. Use /msg or switch to a channel.")
        # Push to input history
        if gInputHistory.len == 0 or gInputHistory[^1] != text:
          gInputHistory.add(text)
          const MaxHistory = 100
          if gInputHistory.len > MaxHistory:
            gInputHistory.delete(0)
        gHistoryIndex = -1
        gSavedInput = ""
        gInputText = ""
      dismissCompletion()

  of tagUpdateInput:
    # Input text already synced from snapshot — check for @-mention
    computeMentionCompletions()

  of tagToggleUserList:
    gShowUserList = not gShowUserList
    saveConfig()

  of tagShowConnectForm:
    gShowConnectForm = true

  of tagHideConnectForm:
    gShowConnectForm = false

  of tagTabComplete:
    if gCompletionActive:
      acceptCompletion()
    else:
      computeCompletions()

  of tagAcceptCompletion:
    acceptCompletion()

  of tagInputChanged:
    computeMentionCompletions()

  of tagCompletionSelect:
    if gCompletionActive and gCompletionSelectIndex >= 0 and
       gCompletionSelectIndex < gCompletionSuggestions.len:
      gCompletionIndex = gCompletionSelectIndex
      acceptCompletion()

  of tagSaveServer:
    if gActiveServerId >= 0:
      syncAutoJoinChannels(gActiveServerId)
    else:
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
      # Auto-select first server and auto-connect all saved servers
      if gActiveServerId < 0:
        gActiveServerId = gServers[0].id
        gActiveChannelName = ServerChannel
      ensureEventLoop()
      for s in gServers:
        if not s.connected and not s.connecting:
          let si = findServerIdx(s.id)
          if si >= 0:
            gServers[si].connecting = true
            ensureChannel(s.id, ServerChannel)
            addSystemMessage(s.id, ServerChannel,
              "Connecting to " & s.host & ":" & $s.port & "...")
            withLock gLock:
              gCommandQueue.add(BridgeCommand(kind: cmdConnect,
                serverId: s.id,
                text: s.host,
                intParam: s.port,
                text2: s.nick,
                boolParam: s.useTls,
                text3: s.password,
                text4: s.saslUser,
                text5: s.saslPass))
      gStatusText = "Connecting to " & $gServers.len & " server(s)..."

  of tagDisconnectServer:
    let sid = gActionServerId
    if sid >= 0:
      if sid notin gIntentionalDisconnects:
        gIntentionalDisconnects.add(sid)
      let si = findServerIdx(sid)
      if si >= 0:
        gServers[si].connected = false
        gServers[si].connecting = false
        addSystemMessage(sid, ServerChannel,
          "Disconnected from " & gServers[si].host)
        gStatusText = "Disconnected from " & gServers[si].host
      ensureEventLoop()
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdDisconnect, serverId: sid))

  of tagReconnectServer:
    let sid = gActionServerId
    if sid >= 0:
      ensureEventLoop()
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdReconnect, serverId: sid))
      let si = findServerIdx(sid)
      if si >= 0:
        gServers[si].connecting = true
        gStatusText = "Reconnecting to " & gServers[si].host & "..."

  of tagConnectServer:
    let sid = gActionServerId
    if sid >= 0:
      let si = findServerIdx(sid)
      if si >= 0 and not gServers[si].connected and not gServers[si].connecting:
        ensureEventLoop()
        gServers[si].connecting = true
        withLock gLock:
          gCommandQueue.add(BridgeCommand(kind: cmdConnect,
            serverId: sid, text: gServers[si].host, text2: gServers[si].nick,
            text3: gServers[si].password, text4: gServers[si].saslUser,
            text5: gServers[si].saslPass,
            intParam: gServers[si].port, boolParam: gServers[si].useTls))
        gActiveServerId = sid
        gActiveChannelName = ServerChannel
        ensureChannel(sid, ServerChannel)
        addSystemMessage(sid, ServerChannel,
          "Connecting to " & gServers[si].host & ":" & $gServers[si].port & "...")
        gStatusText = "Connecting to " & gServers[si].host & "..."

  of tagRemoveServerById:
    let sid = gActionServerId
    if sid >= 0:
      let si = findServerIdx(sid)
      if si >= 0:
        let name = gServers[si].name
        if gServers[si].connected:
          withLock gLock:
            gCommandQueue.add(BridgeCommand(kind: cmdDisconnect, serverId: sid))
        gServers.delete(si)
        let sk = serverKey(sid)
        if sk in gChannels:
          for ch in gChannels[sk]:
            let ck = channelKey(sid, ch.name)
            gMessages.del(ck)
            gUsers.del(ck)
          gChannels.del(sk)
        if gActiveServerId == sid:
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

  of tagWhoisUser:
    let nick = gActionNick
    if nick.len > 0 and gActiveServerId >= 0:
      ensureEventLoop()
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdSendRaw,
          serverId: gActiveServerId, text: "WHOIS " & nick))

  of tagStartDm:
    let nick = gActionNick
    if nick.len > 0 and gActiveServerId >= 0:
      ensureChannel(gActiveServerId, nick)
      ensureDmUsers(gActiveServerId, nick, nick)
      gActiveChannelName = nick
      syncActiveChannelContext()

  of tagIgnoreUser:
    let nick = gActionNick
    if nick.len > 0 and gActiveServerId >= 0:
      let nickLower = nick.toLowerAscii
      if nickLower in gIgnoreList:
        let idx = gIgnoreList.find(nickLower)
        if idx >= 0:
          gIgnoreList.delete(idx)
          saveConfig()
          addSystemMessage(gActiveServerId, gActiveChannelName, "Unignored: " & nick)
      else:
        gIgnoreList.add(nickLower)
        saveConfig()
        addSystemMessage(gActiveServerId, gActiveChannelName, "Ignoring: " & nick)

  of tagHighlightUser:
    let nick = gActionNick
    if nick.len > 0 and gActiveServerId >= 0:
      let nickLower = nick.toLowerAscii
      if nickLower in gHighlightWords:
        let idx = gHighlightWords.find(nickLower)
        if idx >= 0:
          gHighlightWords.delete(idx)
          saveConfig()
          addSystemMessage(gActiveServerId, gActiveChannelName, "Unhighlighted: " & nick)
      else:
        gHighlightWords.add(nickLower)
        saveConfig()
        addSystemMessage(gActiveServerId, gActiveChannelName, "Highlighting: " & nick)

  of tagShowTransfers:
    gShowTransfers = true

  of tagHideTransfers:
    gShowTransfers = false

  of tagAcceptTransfer:
    let tid = gActionTransferId
    if tid >= 0:
      for i in 0 ..< gDccTransfers.len:
        if gDccTransfers[i].id == tid and gDccTransfers[i].state == dccPending:
          gDccTransfers[i].state = dccActive
          addSystemMessage(gActiveServerId,
            if gActiveChannelName.len > 0: gActiveChannelName else: ServerChannel,
            "Accepted DCC transfer: " & gDccTransfers[i].filename & " from " & gDccTransfers[i].nick)
          # Send command to event loop to actually start the download
          ensureEventLoop()
          withLock gLock:
            gCommandQueue.add(BridgeCommand(kind: cmdAcceptDcc,
              serverId: gDccTransfers[i].serverId,
              intParam: tid,
              text: gDccTransfers[i].filename))
          break

  of tagDeclineTransfer:
    let tid = gActionTransferId
    if tid >= 0:
      for i in 0 ..< gDccTransfers.len:
        if gDccTransfers[i].id == tid and gDccTransfers[i].state == dccPending:
          gDccTransfers[i].state = dccDeclined
          addSystemMessage(gActiveServerId,
            if gActiveChannelName.len > 0: gActiveChannelName else: ServerChannel,
            "Declined DCC transfer: " & gDccTransfers[i].filename & " from " & gDccTransfers[i].nick)
          break

  of tagRetryTransfer:
    let tid = gActionTransferId
    if tid >= 0:
      for i in 0 ..< gDccTransfers.len:
        if gDccTransfers[i].id == tid and gDccTransfers[i].state == dccFailed:
          gDccTransfers[i].state = dccActive
          gDccTransfers[i].progress = 0.0
          gDccTransfers[i].bytesReceived = 0
          gDccTransfers[i].errorText = ""
          addSystemMessage(gActiveServerId,
            if gActiveChannelName.len > 0: gActiveChannelName else: ServerChannel,
            "Retrying DCC transfer: " & gDccTransfers[i].filename & " from " & gDccTransfers[i].nick)
          ensureEventLoop()
          withLock gLock:
            gCommandQueue.add(BridgeCommand(kind: cmdRetryDcc,
              serverId: gDccTransfers[i].serverId,
              intParam: tid,
              text: gDccTransfers[i].filename))
          break

  of tagSubmitJoinChannel:
    if gActiveServerId >= 0 and gJoinChannelText.len > 0:
      var channel = gJoinChannelText.strip()
      if channel.len > 0:
        if channel[0] != '#':
          channel = "#" & channel
        ensureEventLoop()
        withLock gLock:
          gCommandQueue.add(BridgeCommand(kind: cmdJoinChannel,
            serverId: gActiveServerId, text: channel))
        gActiveChannelName = channel
        ensureChannel(gActiveServerId, channel)
        addSystemMessage(gActiveServerId, channel,
          "Joining " & channel & "...")
        gStatusText = "Joining " & channel & "..."
    gJoinChannelText = ""

  of tagRequestWhois:
    let nick = gActionNick
    if nick.len > 0 and gActiveServerId >= 0:
      gWhoisNick = nick
      gWhoisInfo = ""
      gWhoisActive = true
      ensureEventLoop()
      withLock gLock:
        gCommandQueue.add(BridgeCommand(kind: cmdSendRaw,
          serverId: gActiveServerId, text: "WHOIS " & nick))

  of tagSelectUser:
    gSelectedUserNick = gActionNick

  of tagShowJoinChannel, tagHideJoinChannel, tagHideWhois:
    discard  # Handled by Swift reducer

  of tagToggleAway:
    if gActiveServerId >= 0:
      let si = findServerIdx(gActiveServerId)
      if si >= 0 and gServers[si].connected:
        ensureEventLoop()
        if gServers[si].isAway:
          withLock gLock:
            gCommandQueue.add(BridgeCommand(kind: cmdClearAway,
              serverId: gActiveServerId))
          addSystemMessage(gActiveServerId,
            if gActiveChannelName.len > 0: gActiveChannelName else: ServerChannel,
            "You are no longer away")
        else:
          withLock gLock:
            gCommandQueue.add(BridgeCommand(kind: cmdSetAway,
              serverId: gActiveServerId, text: "Away"))
          addSystemMessage(gActiveServerId,
            if gActiveChannelName.len > 0: gActiveChannelName else: ServerChannel,
            "You have been marked as away")

  of tagSetFontSize, tagSetMessageDensity, tagSetTimestampFormat:
    # Appearance values synced from snapshot; persist to config
    saveConfig()

  of tagUpdateSidebarFilter, tagUpdateSearch:
    discard  # State handled by Swift reducer

  of tagShowSettings, tagHideSettings, tagShowChannelInfo, tagHideChannelInfo,
     tagToggleSearch, tagClearSearch, tagSelectNetwork:
    discard  # Handled by Swift reducer

  of tagHistoryUp:
    if gCompletionActive and gCompletionSuggestions.len > 0:
      # Navigate completion list upward
      if gCompletionIndex > 0:
        gCompletionIndex -= 1
      else:
        gCompletionIndex = gCompletionSuggestions.len - 1
    elif gInputHistory.len > 0:
      if gHistoryIndex < 0:
        # Start browsing: save current input, go to most recent
        gSavedInput = gInputText
        gHistoryIndex = gInputHistory.len - 1
        gInputText = gInputHistory[gHistoryIndex]
      elif gHistoryIndex > 0:
        # Go to older entry
        gHistoryIndex -= 1
        gInputText = gInputHistory[gHistoryIndex]
      # else: already at oldest, do nothing

  of tagHistoryDown:
    if gCompletionActive and gCompletionSuggestions.len > 0:
      # Navigate completion list downward
      if gCompletionIndex < gCompletionSuggestions.len - 1:
        gCompletionIndex += 1
      else:
        gCompletionIndex = 0
    elif gHistoryIndex >= 0:
      if gHistoryIndex < gInputHistory.len - 1:
        # Go to newer entry
        gHistoryIndex += 1
        gInputText = gInputHistory[gHistoryIndex]
      else:
        # Past the newest: restore saved input
        gHistoryIndex = -1
        gInputText = gSavedInput
        gSavedInput = ""

  of tagMuteJoinPart:
    let nick = gActionNick
    if nick.len > 0 and gActiveServerId >= 0:
      let nickLower = nick.toLowerAscii
      if nickLower in gJoinPartMuteList:
        let idx = gJoinPartMuteList.find(nickLower)
        if idx >= 0:
          gJoinPartMuteList.delete(idx)
          saveConfig()
          addSystemMessage(gActiveServerId, gActiveChannelName, "Unmuted join/part for: " & nick)
      else:
        gJoinPartMuteList.add(nickLower)
        saveConfig()
        addSystemMessage(gActiveServerId, gActiveChannelName, "Muted join/part for: " & nick)

  of tagSetSmartFilter:
    # State synced from snapshot (smartFilterEnabled)
    saveConfig()

  of tagSetSmartFilterTimeout:
    # State synced from snapshot (smartFilterTimeout)
    saveConfig()

  of tagSwitchChannelByIndex:
    if gActiveServerId >= 0:
      let sk = serverKey(gActiveServerId)
      if sk in gChannels:
        var visibleChannels: seq[string]
        for ch in gChannels[sk]:
          if ch.name != ServerChannel and (ch.isChannel or ch.isDm):
            visibleChannels.add ch.name
        # The index is passed via actionServerId field
        let idx = gActionServerId
        if idx >= 0 and idx < visibleChannels.len:
          gActiveChannelName = visibleChannels[idx]
          if gActiveChannelName != ServerChannel:
            gLastChannelPerServer[gActiveServerId] = gActiveChannelName
          syncActiveChannelContext()
          for i in 0 ..< gChannels[sk].len:
            if gChannels[sk][i].name.toLowerAscii == gActiveChannelName.toLowerAscii:
              gChannels[sk][i].unread = 0
              gChannels[sk][i].mentions = 0
              break

  of tagPrevChannel:
    if gActiveServerId >= 0:
      let sk = serverKey(gActiveServerId)
      if sk in gChannels:
        var visibleChannels: seq[string]
        for ch in gChannels[sk]:
          if ch.name != ServerChannel and (ch.isChannel or ch.isDm):
            visibleChannels.add ch.name
        if visibleChannels.len > 0:
          let curIdx = visibleChannels.find(gActiveChannelName)
          if curIdx > 0:
            gActiveChannelName = visibleChannels[curIdx - 1]
          else:
            gActiveChannelName = visibleChannels[^1]
          if gActiveChannelName != ServerChannel:
            gLastChannelPerServer[gActiveServerId] = gActiveChannelName
          syncActiveChannelContext()
          for i in 0 ..< gChannels[sk].len:
            if gChannels[sk][i].name.toLowerAscii == gActiveChannelName.toLowerAscii:
              gChannels[sk][i].unread = 0
              gChannels[sk][i].mentions = 0
              break

  of tagNextChannel:
    if gActiveServerId >= 0:
      let sk = serverKey(gActiveServerId)
      if sk in gChannels:
        var visibleChannels: seq[string]
        for ch in gChannels[sk]:
          if ch.name != ServerChannel and (ch.isChannel or ch.isDm):
            visibleChannels.add ch.name
        if visibleChannels.len > 0:
          let curIdx = visibleChannels.find(gActiveChannelName)
          if curIdx >= 0 and curIdx < visibleChannels.len - 1:
            gActiveChannelName = visibleChannels[curIdx + 1]
          else:
            gActiveChannelName = visibleChannels[0]
          if gActiveChannelName != ServerChannel:
            gLastChannelPerServer[gActiveServerId] = gActiveChannelName
          syncActiveChannelContext()
          for i in 0 ..< gChannels[sk].len:
            if gChannels[sk][i].name.toLowerAscii == gActiveChannelName.toLowerAscii:
              gChannels[sk][i].unread = 0
              gChannels[sk][i].mentions = 0
              break

  of tagNextUnreadChannel:
    if gActiveServerId >= 0:
      let sk = serverKey(gActiveServerId)
      if sk in gChannels:
        var visibleChannels: seq[ChannelState]
        for ch in gChannels[sk]:
          if ch.name != ServerChannel and (ch.isChannel or ch.isDm):
            visibleChannels.add ch
        if visibleChannels.len > 0:
          let curIdx = block:
            var found = -1
            for i, ch in visibleChannels:
              if ch.name.toLowerAscii == gActiveChannelName.toLowerAscii:
                found = i
                break
            found
          for offset in 1 .. visibleChannels.len:
            let idx = (curIdx + offset) mod visibleChannels.len
            if visibleChannels[idx].unread > 0 or visibleChannels[idx].mentions > 0:
              gActiveChannelName = visibleChannels[idx].name
              if gActiveChannelName != ServerChannel:
                gLastChannelPerServer[gActiveServerId] = gActiveChannelName
              syncActiveChannelContext()
              for i in 0 ..< gChannels[sk].len:
                if gChannels[sk][i].name.toLowerAscii == gActiveChannelName.toLowerAscii:
                  gChannels[sk][i].unread = 0
                  gChannels[sk][i].mentions = 0
                  break
              break

  of tagClearScrollback:
    if gActiveServerId >= 0 and gActiveChannelName.len > 0:
      let ck = channelKey(gActiveServerId, gActiveChannelName)
      gMessages[ck] = @[]
      addSystemMessage(gActiveServerId, gActiveChannelName, "Scrollback cleared")

  of tagShowChannelSwitcher, tagHideChannelSwitcher:
    discard  # Handled by Swift reducer

  of tagSwitchChannelFromSwitcher:
    if gActiveServerId >= 0 and gChannelSwitcherText.len > 0:
      let sk = serverKey(gActiveServerId)
      if sk in gChannels:
        let filterLower = gChannelSwitcherText.toLowerAscii
        for ch in gChannels[sk]:
          if ch.name != ServerChannel and (ch.isChannel or ch.isDm):
            if filterLower.len == 0 or ch.name.toLowerAscii.contains(filterLower):
              gActiveChannelName = ch.name
              if gActiveChannelName != ServerChannel:
                gLastChannelPerServer[gActiveServerId] = gActiveChannelName
              syncActiveChannelContext()
              for i in 0 ..< gChannels[sk].len:
                if gChannels[sk][i].name.toLowerAscii == gActiveChannelName.toLowerAscii:
                  gChannels[sk][i].unread = 0
                  gChannels[sk][i].mentions = 0
                  break
              break
    gChannelSwitcherText = ""

  of tagSetNickColor:
    let nick = gActionNick.toLowerAscii
    # Color is stored in gActionColor (set by snapshot sync)
    if nick.len > 0 and gActiveServerId >= 0:
      if gActionColor.len > 0:
        gNickColors[nick] = gActionColor
        saveConfig()
        addSystemMessage(gActiveServerId,
          if gActiveChannelName.len > 0: gActiveChannelName else: ServerChannel,
          "Nick color for " & nick & " set to " & gActionColor)
      else:
        # No color means clear
        if nick in gNickColors:
          gNickColors.del(nick)
          saveConfig()
          addSystemMessage(gActiveServerId,
            if gActiveChannelName.len > 0: gActiveChannelName else: ServerChannel,
            "Nick color for " & nick & " cleared")

  of tagPrevServer:
    if gServers.len > 1:
      let curIdx = findServerIdx(gActiveServerId)
      if curIdx > 0:
        let newId = gServers[curIdx - 1].id
        # Save current channel
        if gActiveServerId >= 0 and gActiveChannelName.len > 0 and
           gActiveChannelName != ServerChannel:
          gLastChannelPerServer[gActiveServerId] = gActiveChannelName
        gActiveServerId = newId
      else:
        # Wrap around to last server
        let newId = gServers[^1].id
        if gActiveServerId >= 0 and gActiveChannelName.len > 0 and
           gActiveChannelName != ServerChannel:
          gLastChannelPerServer[gActiveServerId] = gActiveChannelName
        gActiveServerId = newId
      # Restore last channel for new server
      if gActiveServerId in gLastChannelPerServer:
        gActiveChannelName = gLastChannelPerServer[gActiveServerId]
      else:
        let sk = serverKey(gActiveServerId)
        if sk in gChannels and gChannels[sk].len > 0:
          gActiveChannelName = gChannels[sk][0].name
        else:
          gActiveChannelName = ServerChannel
      syncActiveChannelContext()

  of tagNextServer:
    if gServers.len > 1:
      let curIdx = findServerIdx(gActiveServerId)
      if curIdx >= 0 and curIdx < gServers.len - 1:
        let newId = gServers[curIdx + 1].id
        if gActiveServerId >= 0 and gActiveChannelName.len > 0 and
           gActiveChannelName != ServerChannel:
          gLastChannelPerServer[gActiveServerId] = gActiveChannelName
        gActiveServerId = newId
      else:
        # Wrap around to first server
        let newId = gServers[0].id
        if gActiveServerId >= 0 and gActiveChannelName.len > 0 and
           gActiveChannelName != ServerChannel:
          gLastChannelPerServer[gActiveServerId] = gActiveChannelName
        gActiveServerId = newId
      if gActiveServerId in gLastChannelPerServer:
        gActiveChannelName = gLastChannelPerServer[gActiveServerId]
      else:
        let sk = serverKey(gActiveServerId)
        if sk in gChannels and gChannels[sk].len > 0:
          gActiveChannelName = gChannels[sk][0].name
        else:
          gActiveChannelName = ServerChannel
      syncActiveChannelContext()

  of tagPrevUnreadChannel:
    if gActiveServerId >= 0:
      let sk = serverKey(gActiveServerId)
      if sk in gChannels:
        var visibleChannels: seq[ChannelState]
        for ch in gChannels[sk]:
          if ch.name != ServerChannel and (ch.isChannel or ch.isDm):
            visibleChannels.add ch
        if visibleChannels.len > 0:
          let curIdx = block:
            var found = -1
            for i, ch in visibleChannels:
              if ch.name.toLowerAscii == gActiveChannelName.toLowerAscii:
                found = i
                break
            found
          # Search backward from current position, wrapping around
          for offset in 1 .. visibleChannels.len:
            let idx = (curIdx - offset + visibleChannels.len) mod visibleChannels.len
            if visibleChannels[idx].unread > 0 or visibleChannels[idx].mentions > 0:
              gActiveChannelName = visibleChannels[idx].name
              if gActiveChannelName != ServerChannel:
                gLastChannelPerServer[gActiveServerId] = gActiveChannelName
              syncActiveChannelContext()
              for i in 0 ..< gChannels[sk].len:
                if gChannels[sk][i].name.toLowerAscii == gActiveChannelName.toLowerAscii:
                  gChannels[sk][i].unread = 0
                  gChannels[sk][i].mentions = 0
                  break
              break

  of tagUpdateKeybind:
    # id stored in actionNick, key|modifiers stored in actionColor
    let kbId = gActionNick
    let combined = gActionColor
    let pipePos = combined.find('|')
    if kbId.len > 0 and pipePos > 0:
      let kbKey = combined[0 ..< pipePos]
      let kbMods = combined[pipePos + 1 .. ^1]
      for i in 0 ..< gKeybinds.len:
        if gKeybinds[i].id == kbId:
          gKeybinds[i].key = kbKey
          gKeybinds[i].modifiers = kbMods
          break
      saveConfig()

  of tagResetKeybinds:
    gKeybinds.setLen(0)
    for kb in defaultKeybinds:
      gKeybinds.add(kb)
    saveConfig()

  of tagSetQuitMessage:
    # Quit message synced from snapshot (quitMessage).
    # Live client configs are patched in cmdDisconnect/cmdShutdownAll
    # (gConnections is only safe to access from the event loop thread).
    saveConfig()

  of tagShowKeybindSheet, tagHideKeybindSheet:
    discard  # handled by Swift reducer

  of tagSetLoggingEnabled:
    # loggingEnabled synced from snapshot
    if gLoggingEnabled and gLogDir.len > 0:
      try:
        if not dirExists(gLogDir):
          createDir(gLogDir)
      except CatchableError:
        discard
    saveConfig()

  of tagSetLogDir:
    # logDir synced from snapshot
    if gLogDir.len > 0 and gLoggingEnabled:
      try:
        if not dirExists(gLogDir):
          createDir(gLogDir)
      except CatchableError:
        discard
    saveConfig()

  of tagSetBouncerPassword:
    # bouncerPassword synced from snapshot
    saveConfig()

  of tagSetShowUserList:
    # showUserList synced from snapshot (via Swift reducer)
    saveConfig()

  of tagUpdateIgnoreList:
    # ignoreListJson synced from snapshot; parse into gIgnoreList
    gIgnoreList = @[]
    try:
      let arr = parseJson(gIgnoreListJson)
      if arr.kind == JArray:
        for item in arr.items:
          if item.kind == JString and item.getStr().len > 0:
            gIgnoreList.add(item.getStr().toLowerAscii)
    except CatchableError:
      discard
    saveConfig()

  of tagUpdateHighlightWords:
    gHighlightWords = @[]
    try:
      let arr = parseJson(gHighlightWordsJson)
      if arr.kind == JArray:
        for item in arr.items:
          if item.kind == JString and item.getStr().len > 0:
            gHighlightWords.add(item.getStr().toLowerAscii)
    except CatchableError:
      discard
    saveConfig()

  of tagUpdateJoinPartMuteList:
    gJoinPartMuteList = @[]
    try:
      let arr = parseJson(gJoinPartMuteListJson)
      if arr.kind == JArray:
        for item in arr.items:
          if item.kind == JString and item.getStr().len > 0:
            gJoinPartMuteList.add(item.getStr().toLowerAscii)
    except CatchableError:
      discard
    saveConfig()

  of tagOpenKeyboardShortcuts:
    discard  # handled by Swift reducer

  of tagEditServer:
    let sid = gEditingServerId
    let si = findServerIdx(sid)
    if si >= 0:
      let s = gServers[si]
      var obj = newJObject()
      obj["host"] = %s.host
      obj["port"] = %s.port
      obj["nick"] = %s.nick
      obj["useTls"] = %s.useTls
      obj["password"] = %s.password
      obj["saslUser"] = %s.saslUser
      obj["saslPass"] = %s.saslPass
      var chArr = newJArray()
      for ch in s.autoJoinChannels:
        chArr.add(%ch)
      obj["autoJoinChannels"] = chArr
      obj["name"] = %s.name
      gEditServerJson = $obj
    else:
      gEditServerJson = "{}"

  of tagHideServerEditor:
    discard  # handled by Swift reducer

  of tagSaveServerConfig:
    let sid = gActionServerId
    try:
      let node = parseJson(gEditServerJson)
      let si = findServerIdx(sid)
      if si >= 0:
        gServers[si].name = jsonString(node, "name", gServers[si].name)
        gServers[si].host = jsonString(node, "host", gServers[si].host)
        gServers[si].port = jsonInt(node, "port", gServers[si].port)
        gServers[si].nick = jsonString(node, "nick", gServers[si].nick)
        gServers[si].useTls = jsonBool(node, "useTls", gServers[si].useTls)
        gServers[si].password = jsonString(node, "password", gServers[si].password)
        gServers[si].saslUser = jsonString(node, "saslUser", gServers[si].saslUser)
        gServers[si].saslPass = jsonString(node, "saslPass", gServers[si].saslPass)
        if "autoJoinChannels" in node and node["autoJoinChannels"].kind == JArray:
          var channels: seq[string] = @[]
          for ch in node["autoJoinChannels"].items:
            if ch.kind == JString and ch.getStr().len > 0:
              channels.add(ch.getStr())
          gServers[si].autoJoinChannels = channels
      saveConfig()
    except CatchableError:
      discard

  of tagDeleteServer:
    let sid = gActionServerId
    if sid >= 0:
      let si = findServerIdx(sid)
      if si >= 0:
        let name = gServers[si].name
        if gServers[si].connected:
          withLock gLock:
            gCommandQueue.add(BridgeCommand(kind: cmdDisconnect, serverId: sid))
        gServers.delete(si)
        let sk = serverKey(sid)
        if sk in gChannels:
          for ch in gChannels[sk]:
            let ck = channelKey(sid, ch.name)
            gMessages.del(ck)
            gUsers.del(ck)
          gChannels.del(sk)
        if gActiveServerId == sid:
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

  of tagDuplicateServer:
    let sid = gActionServerId
    let si = findServerIdx(sid)
    if si >= 0:
      let src = gServers[si]
      let newId = gNextServerId
      inc gNextServerId
      gServers.add(ServerState(
        id: newId,
        name: src.name & " (copy)",
        host: src.host,
        port: src.port,
        nick: src.nick,
        useTls: src.useTls,
        password: src.password,
        saslUser: src.saslUser,
        saslPass: src.saslPass,
        autoJoinChannels: src.autoJoinChannels,
        connected: false,
        connecting: false,
        lagMs: -1,
        isAway: false,
      ))
      saveConfig()

  of tagMoveServer:
    let fromIdx = gActionServerId
    let toIdx = gActionTransferId
    if fromIdx >= 0 and fromIdx < gServers.len and
       toIdx >= 0 and toIdx < gServers.len and fromIdx != toIdx:
      let item = gServers[fromIdx]
      gServers.delete(fromIdx)
      gServers.insert(item, toIdx)
      saveConfig()

  of tagMoveChannel:
    let fromIdx = gActionServerId
    let toIdx = gActionTransferId
    if gActiveServerId >= 0:
      let sk = serverKey(gActiveServerId)
      if sk in gChannels:
        if fromIdx >= 0 and fromIdx < gChannels[sk].len and
           toIdx >= 0 and toIdx < gChannels[sk].len and fromIdx != toIdx:
          let item = gChannels[sk][fromIdx]
          gChannels[sk].delete(fromIdx)
          gChannels[sk].insert(item, toIdx)
          saveConfig()

  of tagAppShutdown:
    # Queue a shutdown-all command for the event loop thread.
    # The event loop thread owns gConnections, so we must not access
    # it here (dispatch runs on the Swift main thread).
    ensureEventLoop()
    withLock gLock:
      gCommandQueue.add(BridgeCommand(kind: cmdShutdownAll))

  else:
    gStatusText = "Unknown action (" & $actionTag & ")"

  if not pollSkipped:
    # For non-poll actions, syncActiveChannelContext was already called in the
    # action handler or needs to run here. For poll with events, it ran above.
    if actionTag != tagPoll:
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

  # When poll found no state changes, skip the expensive buildPatch entirely.
  # This drops idle CPU from ~30-40% to near 0%.
  var patchBlob: seq[byte]
  if pollSkipped:
    patchBlob = @[]  # empty → Swift skips applyBridgeStatePatch entirely
  else:
    # During Poll / InputChanged, don't include user-editable text fields in the
    # patch to avoid overwriting in-progress typing (race condition with 100ms timer)
    let includeEditable = actionTag != tagPoll and actionTag != tagStartPoll and
                          actionTag != tagInputChanged
    try:
      patchBlob = buildPatch(includeEditable)
    except CatchableError as e:
      stderr.writeLine "[BRIDGE] buildPatch failed: " & e.msg
      patchBlob = toBytes("{}")
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

proc bridgeGetNotifyFd(): int32 {.cdecl.} =
  ensureInit()
  gNotifyPipeRead.int32

proc bridgeWaitShutdown(timeoutMs: int32): int32 {.cdecl.} =
  ## Block until the event loop thread exits or timeout expires.
  ## Returns 0 on success (thread exited), 1 on timeout.
  if not gEventLoopRunning:
    return 0  # Never started
  let deadline = epochTime() + float(timeoutMs) / 1000.0
  while epochTime() < deadline:
    withLock gShutdownLock:
      if gShutdownComplete:
        joinThread(gEventLoopThread)
        gEventLoopRunning = false
        return 0
    sleep(10)  # Poll every 10ms
  return 1  # Timeout

var gBridgeTable = GUIBridgeFunctionTable(
  abiVersion: guiBridgeAbiVersion,
  alloc: bridgeAlloc,
  free: bridgeFree,
  dispatch: bridgeDispatch,
  getNotifyFd: bridgeGetNotifyFd,
  waitShutdown: bridgeWaitShutdown
)

proc gui_bridge_get_table(): ptr GUIBridgeFunctionTable {.cdecl, exportc, dynlib.} =
  addr gBridgeTable
