## IRC TUI Client
##
## A real IRC client with a modern terminal UI built on the CPS runtime.
##
## Features:
## - First-run setup wizard for nickname and server
## - Config persistence at ~/.config/cps-irc/config.txt (using CPS IO)
## - Server list for saved connections
## - Split view: channel list on the left, chat on the right
## - Scrollable message view with timestamps and colored nicks
## - Text input with history
## - Status bar with channel info
## - Tab switching between channels (click, Tab/Shift+Tab)
## - Mouse support: click channels, tabs, input; scroll messages; drag divider
## - IRC commands: /join, /part, /quit, /nick, /msg, /me, /topic, /help
## - Multi-server: /server add, /server list, /server remove
## - Auto-reconnect on disconnect
##
## Usage:
##   nim c -r examples/tui/irc_tui.nim
##   nim c -r examples/tui/irc_tui.nim irc.libera.chat 6667 mynick "#nim"
##   nim c -r examples/tui/irc_tui.nim --reset

import cps/runtime
import cps/eventloop
import cps/ircclient
import cps/concurrency/channels
import cps/io/files
import cps/irc/dcc
import cps/tui

import std/[strutils, times, options, os, sequtils, posix, algorithm]

# ============================================================
# Clipboard
# ============================================================

proc formatSize(bytes: int64): string =
  ## Format a byte count as a human-readable string.
  if bytes < 0: return "? B"
  elif bytes < 1024: return $bytes & " B"
  elif bytes < 1024 * 1024: return $(bytes div 1024) & " KB"
  elif bytes < 1024 * 1024 * 1024: return $(bytes div (1024 * 1024)) & " MB"
  else:
    let gb = float(bytes) / (1024.0 * 1024.0 * 1024.0)
    return gb.formatFloat(ffDecimal, 1) & " GB"

proc writeOsc52(text: string) =
  ## Write OSC 52 escape sequence to copy text to system clipboard.
  ## Works in iTerm2, Kitty, WezTerm, Alacritty, foot, tmux, etc.
  let seq = osc52Copy(text)
  var written = 0
  while written < seq.len:
    let n = write(STDOUT_FILENO, unsafeAddr seq[written], (seq.len - written).cint)
    if n > 0:
      written += n
    elif n < 0:
      let err = errno
      if err == EINTR: continue
      if err == EAGAIN or err == EWOULDBLOCK:
        var pfd: TPollfd
        pfd.fd = STDOUT_FILENO
        pfd.events = POLLOUT
        discard poll(addr pfd, 1, 100)
        continue
      break
    else:
      break

# ============================================================
# Configuration
# ============================================================

type
  ServerEntry* = object
    name*: string
    host*: string
    port*: int
    channels*: seq[string]
    password*: string
    autoconnect*: bool
    useTls*: bool
    saslUsername*: string
    saslPassword*: string

  ProfileEntry* = object
    nick*: string
    username*: string
    realname*: string

  AppConfig* = ref object
    profile*: ProfileEntry
    servers*: seq[ServerEntry]
    ignoreList*: seq[string]
    highlights*: seq[string]
    logDir*: string
    loggingEnabled*: bool
    themeName*: string

proc configDir(): string =
  getConfigDir() / "cps-irc"

proc configPath(): string =
  configDir() / "config.txt"

proc newAppConfig(): AppConfig =
  AppConfig(
    profile: ProfileEntry(nick: "", username: "", realname: ""),
    servers: @[],
  )

proc serializeConfig(cfg: AppConfig): string =
  ## Serialize config to a simple INI-like format.
  var lines: seq[string] = @[]
  lines.add("[profile]")
  lines.add("nick = " & cfg.profile.nick)
  lines.add("username = " & cfg.profile.username)
  lines.add("realname = " & cfg.profile.realname)
  lines.add("")
  for s in cfg.servers:
    lines.add("[server:" & s.name & "]")
    lines.add("host = " & s.host)
    lines.add("port = " & $s.port)
    lines.add("channels = " & s.channels.join(","))
    lines.add("password = " & s.password)
    lines.add("autoconnect = " & $s.autoconnect)
    if s.useTls:
      lines.add("tls = true")
    if s.saslUsername.len > 0:
      lines.add("sasl_user = " & s.saslUsername)
    if s.saslPassword.len > 0:
      lines.add("sasl_pass = " & s.saslPassword)
    lines.add("")
  # Global settings
  if cfg.ignoreList.len > 0:
    lines.add("[ignore]")
    lines.add("nicks = " & cfg.ignoreList.join(","))
    lines.add("")
  if cfg.highlights.len > 0:
    lines.add("[highlights]")
    lines.add("words = " & cfg.highlights.join(","))
    lines.add("")
  if cfg.loggingEnabled or cfg.logDir.len > 0:
    lines.add("[logging]")
    lines.add("enabled = " & $cfg.loggingEnabled)
    if cfg.logDir.len > 0:
      lines.add("dir = " & cfg.logDir)
    lines.add("")
  if cfg.themeName.len > 0 and cfg.themeName != "dark":
    lines.add("[theme]")
    lines.add("name = " & cfg.themeName)
    lines.add("")
  lines.join("\n")

proc parseConfig(data: string): AppConfig =
  ## Parse config from INI-like format.
  result = newAppConfig()
  var currentSection = ""
  var currentServer: ServerEntry
  var inServer = false

  for rawLine in data.splitLines:
    let line = rawLine.strip()
    if line.len == 0 or line[0] == '#':
      continue
    if line[0] == '[' and line[^1] == ']':
      # Save previous server entry
      if inServer and currentServer.host.len > 0:
        result.servers.add(currentServer)
      let section = line[1..^2]
      if section == "profile":
        currentSection = "profile"
        inServer = false
      elif section.startsWith("server:"):
        currentSection = "server"
        inServer = true
        currentServer = ServerEntry(
          name: section[7..^1],
          port: 6667,
          autoconnect: false,
        )
      elif section in ["ignore", "highlights", "logging", "theme"]:
        if inServer and currentServer.host.len > 0:
          result.servers.add(currentServer)
          inServer = false
        currentSection = section
      continue
    let eqIdx = line.find('=')
    if eqIdx < 0:
      continue
    let key = line[0 ..< eqIdx].strip()
    let val = line[eqIdx + 1 .. ^1].strip()
    if currentSection == "profile":
      case key
      of "nick": result.profile.nick = val
      of "username": result.profile.username = val
      of "realname": result.profile.realname = val
      else: discard
    elif currentSection == "server":
      case key
      of "host": currentServer.host = val
      of "port": currentServer.port = (try: parseInt(val) except: 6667)
      of "channels":
        currentServer.channels = val.split(',').filterIt(it.strip().len > 0)
      of "password": currentServer.password = val
      of "autoconnect": currentServer.autoconnect = val == "true"
      of "tls": currentServer.useTls = val == "true"
      of "sasl_user": currentServer.saslUsername = val
      of "sasl_pass": currentServer.saslPassword = val
      of "name": currentServer.name = val
      else: discard
    elif currentSection == "ignore":
      case key
      of "nicks": result.ignoreList = val.split(',').filterIt(it.strip().len > 0).mapIt(it.strip())
      else: discard
    elif currentSection == "highlights":
      case key
      of "words": result.highlights = val.split(',').filterIt(it.strip().len > 0).mapIt(it.strip())
      else: discard
    elif currentSection == "logging":
      case key
      of "enabled": result.loggingEnabled = val == "true"
      of "dir": result.logDir = val
      else: discard
    elif currentSection == "theme":
      case key
      of "name": result.themeName = val
      else: discard
  # Flush last server entry
  if inServer and currentServer.host.len > 0:
    result.servers.add(currentServer)

# ============================================================
# Config persistence via CPS IO
# ============================================================

proc saveConfig(cfg: AppConfig) =
  ## Save config using CPS IO asyncWriteFile.
  ## Creates the config directory if it doesn't exist.
  let dir = configDir()
  if not dirExists(dir):
    createDir(dir)
  let data = serializeConfig(cfg)
  let fut = asyncWriteFile(configPath(), data)
  # Fire-and-forget: the event loop will process the write.
  # We attach a callback just for error logging.
  fut.addCallback(proc() =
    if fut.hasError:
      discard  # Config save failed silently
  )

# ============================================================
# Themes
# ============================================================

type
  Theme* = object
    nick*: proc(nick: string): Style
    myMsg*: Style         ## Style for own messages
    mention*: Style       ## Highlight mentions
    system*: Style        ## System/server messages
    error*: Style         ## Error messages
    action*: Style        ## /me actions
    timestamp*: Style     ## Timestamps
    statusBg*: Style      ## Status bar background
    statusBold*: Style    ## Status bar bold items
    chanActive*: Style    ## Active channel in list
    chanMention*: Style   ## Channel with mentions
    chanUnread*: Style    ## Channel with unread
    chanNormal*: Style    ## Normal channel
    inputPrompt*: Style   ## Input prompt
    urlStyle*: Style      ## URL highlighting
    awayIndicator*: Style ## Away indicator
    lagGood*: Style       ## Lag < 200ms
    lagWarn*: Style       ## Lag 200-500ms
    lagBad*: Style        ## Lag > 500ms
    prefixOp*: Style      ## @ operator
    prefixVoice*: Style   ## + voice
    prefixHalfop*: Style  ## % halfop
    separator*: Style     ## Divider

proc defaultNickColor(nick: string): Style =
  var hash = 0
  for c in nick:
    hash = hash * 31 + c.ord
  let colors = [clRed, clGreen, clYellow, clBlue, clMagenta, clCyan,
                clBrightRed, clBrightGreen, clBrightYellow, clBrightBlue,
                clBrightMagenta, clBrightCyan]
  style(colors[abs(hash) mod colors.len])

proc darkTheme*(): Theme =
  Theme(
    nick: defaultNickColor,
    myMsg: style(clBrightWhite),
    mention: Style(fg: clBrightWhite, bg: clMagenta, attrs: {taBold}),
    system: style(clBrightYellow),
    error: style(clBrightRed),
    action: style(clBrightCyan).italic(),
    timestamp: style(clBrightBlack),
    statusBg: style(clBlack, clCyan),
    statusBold: style(clBlack, clCyan).bold(),
    chanActive: style(clBrightWhite).bold(),
    chanMention: style(clBrightMagenta).bold(),
    chanUnread: style(clBrightCyan),
    chanNormal: style(clWhite),
    inputPrompt: style(clBrightCyan),
    urlStyle: style(clBrightBlue).underline(),
    awayIndicator: style(clBrightYellow).bold(),
    lagGood: style(clBrightGreen),
    lagWarn: style(clBrightYellow),
    lagBad: style(clBrightRed),
    prefixOp: style(clBrightGreen),
    prefixVoice: style(clBrightBlue),
    prefixHalfop: style(clBrightYellow),
    separator: style(clBrightBlack),
  )

proc lightTheme*(): Theme =
  Theme(
    nick: defaultNickColor,
    myMsg: style(clBlack),
    mention: Style(fg: clWhite, bg: clRed, attrs: {taBold}),
    system: style(clBlue),
    error: style(clRed),
    action: style(clCyan).italic(),
    timestamp: style(clBrightBlack),
    statusBg: style(clWhite, clBlue),
    statusBold: style(clWhite, clBlue).bold(),
    chanActive: style(clBlack).bold(),
    chanMention: style(clRed).bold(),
    chanUnread: style(clBlue),
    chanNormal: style(clBlack),
    inputPrompt: style(clBlue),
    urlStyle: style(clBlue).underline(),
    awayIndicator: style(clRed).bold(),
    lagGood: style(clGreen),
    lagWarn: style(clYellow),
    lagBad: style(clRed),
    prefixOp: style(clGreen),
    prefixVoice: style(clBlue),
    prefixHalfop: style(clYellow),
    separator: style(clBrightBlack),
  )

proc solarizedTheme*(): Theme =
  ## Solarized Dark palette using 256-color palette indices.
  let base03 = palette(234'u8)
  let base0 = palette(244'u8)
  let yellow = palette(136'u8)
  let orange = palette(166'u8)
  let red = palette(160'u8)
  let magenta = palette(125'u8)
  let blue = palette(33'u8)
  let cyan = palette(37'u8)
  let green = palette(64'u8)
  Theme(
    nick: defaultNickColor,
    myMsg: style(base0),
    mention: Style(fg: clBrightWhite, bg: magenta, attrs: {taBold}),
    system: style(yellow),
    error: style(red),
    action: style(cyan).italic(),
    timestamp: style(base03),
    statusBg: style(base0, blue),
    statusBold: style(base0, blue).bold(),
    chanActive: style(base0).bold(),
    chanMention: style(magenta).bold(),
    chanUnread: style(cyan),
    chanNormal: style(base0),
    inputPrompt: style(cyan),
    urlStyle: style(blue).underline(),
    awayIndicator: style(orange).bold(),
    lagGood: style(green),
    lagWarn: style(yellow),
    lagBad: style(red),
    prefixOp: style(green),
    prefixVoice: style(blue),
    prefixHalfop: style(yellow),
    separator: style(base03),
  )

proc getTheme*(name: string): Theme =
  case name.toLowerAscii
  of "light": lightTheme()
  of "solarized": solarizedTheme()
  else: darkTheme()

# ============================================================
# mIRC Color Parsing
# ============================================================

const mircColors*: array[16, Color] = [
  clWhite,       #  0 white
  clBlack,       #  1 black
  clBlue,        #  2 blue (navy)
  clGreen,       #  3 green
  clRed,         #  4 red
  clRed,         #  5 brown (dark red)
  clMagenta,     #  6 purple
  clYellow,      #  7 orange
  clBrightYellow,#  8 yellow
  clBrightGreen, #  9 light green
  clCyan,        # 10 teal
  clBrightCyan,  # 11 light cyan
  clBrightBlue,  # 12 light blue
  clBrightMagenta,# 13 pink
  clBrightBlack, # 14 grey
  clWhite,       # 15 light grey
]

proc parseIrcFormatting*(text: string): seq[StyledSpan] =
  ## Parse mIRC color and formatting codes into styled spans.
  result = @[]
  var curStyle = styleDefault
  var buf = ""
  var i = 0

  template flush() =
    if buf.len > 0:
      result.add(StyledSpan(text: buf, style: curStyle))
      buf = ""

  while i < text.len:
    let ch = text[i]
    case ch
    of '\x02':  # Bold toggle
      flush()
      if taBold in curStyle.attrs:
        curStyle.attrs = curStyle.attrs - {taBold}
      else:
        curStyle.attrs = curStyle.attrs + {taBold}
      inc i
    of '\x1D':  # Italic toggle
      flush()
      if taItalic in curStyle.attrs:
        curStyle.attrs = curStyle.attrs - {taItalic}
      else:
        curStyle.attrs = curStyle.attrs + {taItalic}
      inc i
    of '\x1F':  # Underline toggle
      flush()
      if taUnderline in curStyle.attrs:
        curStyle.attrs = curStyle.attrs - {taUnderline}
      else:
        curStyle.attrs = curStyle.attrs + {taUnderline}
      inc i
    of '\x16':  # Reverse toggle
      flush()
      if taReverse in curStyle.attrs:
        curStyle.attrs = curStyle.attrs - {taReverse}
      else:
        curStyle.attrs = curStyle.attrs + {taReverse}
      inc i
    of '\x1E':  # Strikethrough toggle
      flush()
      if taStrikethrough in curStyle.attrs:
        curStyle.attrs = curStyle.attrs - {taStrikethrough}
      else:
        curStyle.attrs = curStyle.attrs + {taStrikethrough}
      inc i
    of '\x0F':  # Reset
      flush()
      curStyle = styleDefault
      inc i
    of '\x11':  # Monospace (just skip the control char)
      inc i
    of '\x03':  # Color
      flush()
      inc i
      if i < text.len and text[i] in {'0'..'9'}:
        var fg = ord(text[i]) - ord('0')
        inc i
        if i < text.len and text[i] in {'0'..'9'}:
          fg = fg * 10 + ord(text[i]) - ord('0')
          inc i
        if fg >= 0 and fg <= 15:
          curStyle.fg = mircColors[fg]
        # Background
        if i < text.len and text[i] == ',':
          if i + 1 < text.len and text[i + 1] in {'0'..'9'}:
            inc i
            var bg = ord(text[i]) - ord('0')
            inc i
            if i < text.len and text[i] in {'0'..'9'}:
              bg = bg * 10 + ord(text[i]) - ord('0')
              inc i
            if bg >= 0 and bg <= 15:
              curStyle.bg = mircColors[bg]
      else:
        # Bare \x03 with no digits = reset colors
        curStyle.fg = clDefault
        curStyle.bg = clDefault
    of '\x04':  # Hex color (skip)
      inc i
      var digits = 0
      while i < text.len and text[i] in {'0'..'9', 'a'..'f', 'A'..'F'} and digits < 6:
        inc i; inc digits
      if i < text.len and text[i] == ',' and digits > 0:
        if i + 1 < text.len and text[i + 1] in {'0'..'9', 'a'..'f', 'A'..'F'}:
          inc i; digits = 0
          while i < text.len and text[i] in {'0'..'9', 'a'..'f', 'A'..'F'} and digits < 6:
            inc i; inc digits
    else:
      buf.add(ch)
      inc i

  flush()

# ============================================================
# URL Detection
# ============================================================

proc findUrls*(text: string): seq[tuple[start, stop: int]] =
  ## Find all URLs in the text. Returns (start, stop) byte positions (exclusive end).
  result = @[]
  let prefixes = ["https://", "http://", "ftp://", "irc://", "ircs://"]
  var i = 0
  while i < text.len:
    var found = false
    for prefix in prefixes:
      if i + prefix.len <= text.len and text[i ..< i + prefix.len].toLowerAscii == prefix:
        let start = i
        i += prefix.len
        # Consume until whitespace or end
        while i < text.len and text[i] notin {' ', '\t', '\n', '\r', '<', '>', '"'}:
          inc i
        # Strip trailing punctuation that's likely not part of URL
        while i > start and text[i - 1] in {'.', ',', ')', ';', ':', '!', '?', '\''}:
          dec i
        result.add((start, i))
        found = true
        break
    if not found:
      inc i

# ============================================================
# WhoisState for accumulating WHOIS replies
# ============================================================

type
  WhoisState* = object
    nick*: string
    user*: string
    host*: string
    realname*: string
    server*: string
    serverInfo*: string
    channels*: string
    idle*: string
    account*: string
    isOper*: bool
    collecting*: bool

# ============================================================
# App Screen State Machine
# ============================================================

const ServerChannel = "*server*"

type
  AppScreen = enum
    asLoading      ## Config is loading
    asSetup        ## First-time setup wizard
    asServerList   ## Server picker
    asChat         ## IRC chat

  ## Index constants for setup form fields
const
  sfNick = 0
  sfUsername = 1
  sfRealname = 2
  sfServerName = 3
  sfHost = 4
  sfPort = 5
  sfChannels = 6
  sfPassword = 7
  sfTls = 8
  sfSaslUser = 9
  sfSaslPass = 10
  SetupFieldCount = 11

  ## Labels for each setup field
  SetupLabels = [
    "Nickname:  ",
    "Username:  ",
    "Realname:  ",
    "Server:    ",
    "Host:      ",
    "Port:      ",
    "Channels:  ",
    "Password:  ",
    "TLS:       ",
    "SASL User: ",
    "SASL Pass: ",
  ]

type
  Channel = object
    name: string
    messages: ScrollableTextView
    users: seq[string]       ## Nicks with prefixes (e.g. "@nick", "+nick")
    topic: string
    unread: int
    mentions: int           ## Count of unread messages mentioning our nick

  BatchMessage = object
    ## A single message accumulated inside a BATCH.
    kind: string             ## "privmsg", "notice", "join", "part", "quit"
    source: string
    target: string
    text: string

  BatchAccumulator = object
    ## Accumulates events between BATCH start/end for grouped display.
    active: bool
    batchRef: string
    batchType: string        ## "netsplit", "netjoin", "chathistory", etc.
    batchParams: seq[string]
    messages: seq[BatchMessage]

  PasteConfirm = object
    ## State for multi-line paste confirmation dialog.
    active: bool
    lines: seq[string]       ## The lines to send
    preview: seq[string]     ## First few lines for preview

  DccConfirm = object
    ## State for DCC transfer confirmation dialog.
    active: bool
    transfer: DccTransfer

  IrcChatState = ref object
    client: IrcClient
    channels: seq[Channel]
    activeChannel: int
    splitView: SplitView
    statusBar: StatusBar
    myNick: string
    eventCounts: array[IrcEventKind, int]  ## Debug counters per event type
    whois: WhoisState       ## Accumulating WHOIS replies
    isAway: bool            ## True if we are /away
    batches: seq[BatchAccumulator]  ## Active batch accumulators
    serverLabel: string      ## Short label for multi-server (e.g., "libera")
    dccManager: DccManager   ## DCC file transfer manager

  NickComplete = object
    ## State for @-mention autocomplete.
    active: bool             ## True when popup is visible
    atPos: int               ## Byte position of the '@' in the input text
    query: string            ## Text after '@' used for filtering
    matches: seq[string]     ## Filtered user nicks
    selected: int            ## Currently highlighted match index

  TabComplete = object
    ## State for traditional Tab nick completion.
    active: bool
    prefix: string           ## The word being completed
    wordStart: int           ## Byte position of the word start
    candidates: seq[string]  ## Matching nicks
    index: int               ## Current cycle position

  SearchState = object
    ## State for Ctrl+F message search.
    active: bool
    query: string
    matchLines: seq[int]     ## Line indices that match
    currentMatch: int        ## Index into matchLines
    input: TextInput

  QuickSwitcher = object
    ## State for Ctrl+K channel quick-switcher.
    active: bool
    input: TextInput
    filtered: seq[tuple[idx: int, name: string]]
    selected: int

  MasterState = ref object
    screen: AppScreen
    config: AppConfig
    configLoaded: bool
    configLoadFut: CpsFuture[string]

    # Shared across screens
    tuiApp: TuiApp
    inputField: TextInput
    notifications: NotificationArea
    helpDialog: Dialog
    clipboardText: string   ## Last copied text
    nickComplete: NickComplete  ## @-mention autocomplete state
    tabComplete: TabComplete    ## Traditional Tab nick completion
    theme: Theme                ## Current color theme

    # Setup screen
    setupFields: array[SetupFieldCount, TextInput]
    setupFocusIdx: int
    setupError: string

    # Server list screen
    serverListIdx: int
    addServerMode: bool  ## True when adding from server list
    editServerMode: bool ## True when editing an existing server
    editServerIdx: int   ## Index of server being edited
    addFields: array[8, TextInput]  # name, host, port, channels, password, tls, sasl user, sasl pass
    addFocusIdx: int

    # Chat screen — multi-server
    chats: seq[IrcChatState]     ## All connected servers
    activeChat: int              ## Index into chats
    running: bool
    search: SearchState         ## Ctrl+F search
    quickSwitcher: QuickSwitcher ## Ctrl+K channel switcher
    lastPingTime: float          ## For periodic lag pings
    pasteConfirm: PasteConfirm   ## Multi-line paste confirmation
    dccConfirm: DccConfirm       ## DCC transfer confirmation

# ============================================================
# Multi-server convenience: active chat accessor
# ============================================================

proc chat(ms: MasterState): IrcChatState =
  ## Returns the currently active IrcChatState, or nil if none connected.
  if ms.chats.len > 0 and ms.activeChat < ms.chats.len:
    return ms.chats[ms.activeChat]
  return nil

proc `chat=`(ms: MasterState, cs: IrcChatState) =
  ## Set the active chat (for backward compat during transition to multi-server).
  if ms.chats.len == 0:
    ms.chats.add(cs)
    ms.activeChat = 0
  else:
    ms.chats[ms.activeChat] = cs

proc addChat(ms: MasterState, cs: IrcChatState) =
  ## Add a new server connection and switch to it.
  ms.chats.add(cs)
  ms.activeChat = ms.chats.len - 1

proc removeChat(ms: MasterState, idx: int) =
  ## Remove a server connection by index.
  if idx >= 0 and idx < ms.chats.len:
    ms.chats.delete(idx)
    if ms.activeChat >= ms.chats.len:
      ms.activeChat = max(0, ms.chats.len - 1)

proc switchChat(ms: MasterState, idx: int) =
  ## Switch to server connection at index.
  if idx >= 0 and idx < ms.chats.len and idx != ms.activeChat:
    ms.activeChat = idx
    ms.tuiApp.fullRedraw = true

proc nextChat(ms: MasterState) =
  if ms.chats.len > 1:
    ms.switchChat((ms.activeChat + 1) mod ms.chats.len)

proc prevChat(ms: MasterState) =
  if ms.chats.len > 1:
    ms.switchChat((ms.activeChat + ms.chats.len - 1) mod ms.chats.len)

# ============================================================
# Setup screen fields initialization
# ============================================================

proc initSetupFields(ms: MasterState) =
  ms.setupFields[sfNick] = newTextInput(placeholder = "mynick")
  ms.setupFields[sfUsername] = newTextInput(placeholder = "myuser")
  ms.setupFields[sfRealname] = newTextInput(placeholder = "IRC User")
  ms.setupFields[sfServerName] = newTextInput(placeholder = "Libera Chat")
  ms.setupFields[sfHost] = newTextInput(placeholder = "irc.libera.chat")
  ms.setupFields[sfPort] = newTextInput(placeholder = "6667")
  ms.setupFields[sfChannels] = newTextInput(placeholder = "#nim,#linux")
  ms.setupFields[sfPassword] = newTextInput(placeholder = "(none)", mask = '*')
  ms.setupFields[sfTls] = newTextInput(placeholder = "yes/no")
  ms.setupFields[sfSaslUser] = newTextInput(placeholder = "(none)")
  ms.setupFields[sfSaslPass] = newTextInput(placeholder = "(none)", mask = '*')
  # Pre-fill defaults
  ms.setupFields[sfServerName].setText("Libera Chat")
  ms.setupFields[sfHost].setText("irc.libera.chat")
  ms.setupFields[sfPort].setText("6697")
  ms.setupFields[sfTls].setText("yes")
  ms.setupFocusIdx = sfNick
  for i in 0 ..< SetupFieldCount:
    ms.setupFields[i].focused = (i == sfNick)

proc initAddFields(ms: MasterState) =
  ms.addFields[0] = newTextInput(placeholder = "Server Name")
  ms.addFields[1] = newTextInput(placeholder = "irc.example.com")
  ms.addFields[2] = newTextInput(placeholder = "6667")
  ms.addFields[3] = newTextInput(placeholder = "#channel1,#channel2")
  ms.addFields[4] = newTextInput(placeholder = "(none)", mask = '*')
  ms.addFields[5] = newTextInput(placeholder = "yes/no")
  ms.addFields[6] = newTextInput(placeholder = "(none)")
  ms.addFields[7] = newTextInput(placeholder = "(none)", mask = '*')
  ms.addFocusIdx = 0
  ms.addFields[0].focused = true

proc initEditFields(ms: MasterState, idx: int) =
  ## Pre-fill add fields with existing server settings for editing.
  ms.initAddFields()
  if idx >= 0 and idx < ms.config.servers.len:
    let s = ms.config.servers[idx]
    ms.addFields[0].setText(s.name)
    ms.addFields[1].setText(s.host)
    ms.addFields[2].setText($s.port)
    ms.addFields[3].setText(s.channels.join(","))
    ms.addFields[4].setText(s.password)
    ms.addFields[5].setText(if s.useTls: "yes" else: "no")
    ms.addFields[6].setText(s.saslUsername)
    ms.addFields[7].setText(s.saslPassword)
  ms.editServerIdx = idx
  ms.editServerMode = true
  ms.addServerMode = false

# ============================================================
# Helpers: nick colors
# ============================================================

proc bareNick*(nick: string): string =
  ## Strip mode prefixes (@, +, %, ~, &) from a nick.
  var i = 0
  while i < nick.len and nick[i] in {'@', '+', '%', '~', '&'}:
    inc i
  if i < nick.len: nick[i..^1] else: nick

proc userPrefix*(nick: string): string =
  ## Extract the mode prefix from a nick ("@", "+", etc).
  var i = 0
  while i < nick.len and nick[i] in {'@', '+', '%', '~', '&'}:
    inc i
  if i > 0: nick[0 ..< i] else: ""

proc prefixPriority(prefix: string): int =
  ## Priority for sorting: ~ > & > @ > % > + > (none)
  if prefix.len == 0: return 0
  case prefix[0]
  of '~': 5
  of '&': 4
  of '@': 3
  of '%': 2
  of '+': 1
  else: 0

proc cmpUsers(a, b: string): int =
  ## Compare users by prefix priority (descending), then alphabetically.
  let pa = prefixPriority(userPrefix(a))
  let pb = prefixPriority(userPrefix(b))
  result = cmp(pb, pa)  # Higher priority first
  if result == 0:
    result = cmp(bareNick(a).toLowerAscii, bareNick(b).toLowerAscii)

proc isWordBoundary(ch: char): bool =
  ## Characters that count as word boundaries for nick matching.
  ch in {' ', '\t', ',', '.', ':', ';', '!', '?', '(', ')', '[', ']',
         '{', '}', '<', '>', '"', '\'', '`', '@', '#', '/', '\\',
         '+', '-', '=', '|', '\0'}

proc containsMention(text, nick: string): bool =
  ## Check if `text` mentions `nick` using case-insensitive word-boundary matching.
  ## Matches "nick" when surrounded by word boundaries or at string edges.
  if nick.len == 0: return false
  let lowerText = text.toLowerAscii
  let lowerNick = nick.toLowerAscii
  var pos = 0
  while pos <= lowerText.len - lowerNick.len:
    let idx = lowerText.find(lowerNick, pos)
    if idx < 0: break
    let beforeOk = idx == 0 or lowerText[idx - 1].isWordBoundary()
    let afterIdx = idx + lowerNick.len
    let afterOk = afterIdx >= lowerText.len or lowerText[afterIdx].isWordBoundary()
    if beforeOk and afterOk:
      return true
    pos = idx + 1
  false

var activeTheme = darkTheme()  ## Global theme reference, updated when MasterState.theme changes

# ============================================================
# Chat channel management
# ============================================================

proc findChannel(cs: IrcChatState, name: string): int =
  for i, ch in cs.channels:
    if ch.name.toLowerAscii == name.toLowerAscii:
      return i
  return -1

proc getOrCreateChannel(cs: IrcChatState, name: string): int =
  let idx = cs.findChannel(name)
  if idx >= 0: return idx
  var ch = Channel(
    name: name,
    messages: newScrollableTextView(maxLines = 1000, autoScroll = true, wrapMode = twChar),
    users: @[], topic: "", unread: 0,
  )
  ch.messages.showTimestamps = true
  cs.channels.add(ch)
  return cs.channels.len - 1

proc isMention(cs: IrcChatState, text, channelName: string, highlights: seq[string] = @[]): bool =
  ## True if the text mentions our nick, highlight words, or is a DM.
  if not channelName.isChannel():
    return true  # DMs always count as mentions
  if containsMention(text, cs.myNick):
    return true
  for word in highlights:
    if containsMention(text, word):
      return true
  false

var logConfig: tuple[enabled: bool, dir: string]  ## Global logging state

proc logMessage(channelName, text: string) =
  ## Append a log line to the channel's log file.
  if not logConfig.enabled or logConfig.dir.len == 0: return
  let dir = logConfig.dir
  if not dirExists(dir):
    try: createDir(dir)
    except OSError: return
  let safeName = channelName.replace("/", "_").replace("\\", "_")
  let datestamp = now().format("yyyy-MM-dd")
  let ts = now().format("HH:mm:ss")
  let path = dir / safeName & "_" & datestamp & ".log"
  let line = "[" & ts & "] " & text & "\n"
  let fut = asyncAppendFile(path, line)
  fut.addCallback(proc() = discard)  # Fire-and-forget

proc addMsg(cs: IrcChatState, channelName, nick, text: string, highlights: seq[string] = @[]) =
  let idx = cs.getOrCreateChannel(channelName)
  let ts = now().format("HH:mm")
  let stripped = stripIrcFormatting(text)
  let mention = cs.isMention(stripped, channelName, highlights)
  let st = if mention: activeTheme.mention else: activeTheme.nick(nick)
  # Build styled spans: nick prefix + message body with mIRC colors and URL highlighting
  let nickPrefix = "<" & nick & "> "
  var spans: seq[StyledSpan] = @[StyledSpan(text: nickPrefix, style: st)]
  if mention:
    # Mention highlighting overrides everything
    spans.add(StyledSpan(text: stripped, style: st))
  else:
    # Parse mIRC formatting, then overlay URL highlighting
    let bodySpans = parseIrcFormatting(text)
    let urls = findUrls(stripped)
    if urls.len == 0:
      # No URLs — just use parsed spans
      for s in bodySpans:
        spans.add(s)
    else:
      # Apply URL underline style to URL regions
      # Reconstruct from stripped text with URL highlighting
      var pos = 0
      for urlRange in urls:
        if urlRange.start > pos:
          spans.add(StyledSpan(text: stripped[pos ..< urlRange.start], style: styleDefault))
        spans.add(StyledSpan(text: stripped[urlRange.start ..< urlRange.stop], style: activeTheme.urlStyle))
        pos = urlRange.stop
      if pos < stripped.len:
        spans.add(StyledSpan(text: stripped[pos ..< stripped.len], style: styleDefault))
  cs.channels[idx].messages.addLine(nickPrefix & stripped, st, ts, spans)
  logMessage(channelName, nickPrefix & stripped)
  if idx != cs.activeChannel:
    cs.channels[idx].unread += 1
    if mention:
      cs.channels[idx].mentions += 1

proc addAction(cs: IrcChatState, channelName, nick, text: string, highlights: seq[string] = @[]) =
  let idx = cs.getOrCreateChannel(channelName)
  let ts = now().format("HH:mm")
  let mention = cs.isMention(text, channelName, highlights)
  let st = if mention: activeTheme.mention.italic() else: activeTheme.nick(nick).italic()
  cs.channels[idx].messages.addLine("* " & nick & " " & text, st, ts)
  logMessage(channelName, "* " & nick & " " & text)
  if idx != cs.activeChannel:
    cs.channels[idx].unread += 1
    if mention:
      cs.channels[idx].mentions += 1

proc addSystem(cs: IrcChatState, channelName, text: string) =
  let idx = cs.getOrCreateChannel(channelName)
  let ts = now().format("HH:mm")
  cs.channels[idx].messages.addLine("*** " & text, activeTheme.system, ts)

proc addError(cs: IrcChatState, channelName, text: string) =
  let idx = cs.getOrCreateChannel(channelName)
  let ts = now().format("HH:mm")
  cs.channels[idx].messages.addLine("!!! " & text, activeTheme.error, ts)

proc addServerMsg(cs: IrcChatState, text: string) =
  cs.addSystem(ServerChannel, text)

proc currentChannel(cs: IrcChatState): var Channel =
  cs.channels[cs.activeChannel]

proc switchChannel(cs: IrcChatState, idx: int) =
  if idx >= 0 and idx < cs.channels.len:
    cs.activeChannel = idx
    cs.channels[idx].unread = 0
    cs.channels[idx].mentions = 0

proc nextChannel(cs: IrcChatState) =
  cs.switchChannel((cs.activeChannel + 1) mod cs.channels.len)

proc prevChannel(cs: IrcChatState) =
  cs.switchChannel((cs.activeChannel + cs.channels.len - 1) mod cs.channels.len)

proc removeChannel(cs: IrcChatState, name: string) =
  let idx = cs.findChannel(name)
  if idx >= 0 and cs.channels[idx].name != ServerChannel:
    cs.channels.delete(idx)
    if cs.activeChannel >= cs.channels.len:
      cs.activeChannel = max(0, cs.channels.len - 1)

# ============================================================
# @-mention autocomplete (fuzzy via Levenshtein distance)
# ============================================================

proc levenshtein(a, b: string): int =
  ## Compute the Levenshtein edit distance between two strings using a
  ## single-row matrix (O(min(m,n)) space).
  let m = a.len
  let n = b.len
  if m == 0: return n
  if n == 0: return m
  # Use the shorter string for the column dimension to save memory.
  var row = newSeq[int](n + 1)
  for j in 0 .. n:
    row[j] = j
  for i in 1 .. m:
    var prev = row[0]
    row[0] = i
    for j in 1 .. n:
      let old = row[j]
      let cost = if a[i - 1] == b[j - 1]: 0 else: 1
      row[j] = min(min(row[j] + 1,       # deletion
                       row[j - 1] + 1),   # insertion
                   prev + cost)            # substitution
      prev = old
  row[n]

proc fuzzyScore(query, candidate: string): int =
  ## Lower is better. Returns a combined score favouring:
  ##   1. Exact prefix match (score 0..len)
  ##   2. Substring containment (score len+1..len+editDist)
  ##   3. Pure Levenshtein distance (score 1000+dist for no prefix/substring)
  ## A high sentinel (9999) means "no reasonable match".
  let q = query.toLowerAscii
  let c = candidate.toLowerAscii
  if q.len == 0:
    return 0  # Empty query matches everything equally
  # Exact prefix
  if c.startsWith(q):
    return q.len - q.len  # 0 for exact prefix, scaled by coverage
  # Substring containment
  let subIdx = c.find(q)
  if subIdx >= 0:
    return subIdx + 1  # Earlier appearance = better
  # Levenshtein on the prefix of the candidate (match partial typing)
  let prefixLen = min(q.len, c.len)
  let prefixDist = levenshtein(q, c[0 ..< prefixLen])
  # Allow up to ceil(query.len / 2) edits for fuzzy
  let maxDist = (q.len + 1) div 2
  if prefixDist <= maxDist:
    return 100 + prefixDist
  # Full Levenshtein as last resort (but only if reasonably close)
  let fullDist = levenshtein(q, c)
  if fullDist <= maxDist + 1:
    return 200 + fullDist
  return 9999  # No match

proc dismissComplete(ms: MasterState) =
  ms.nickComplete.active = false
  ms.nickComplete.matches = @[]
  ms.nickComplete.selected = 0

proc updateComplete(ms: MasterState) =
  ## Scan the input text for an active @-mention and update filtered matches.
  let cs = ms.chat
  if cs == nil: ms.dismissComplete(); return
  let inputText = ms.inputField.text
  let cursorPos = ms.inputField.cursor

  # Find the '@' before (or at) the cursor
  var atPos = -1
  for i in countdown(cursorPos - 1, 0):
    if inputText[i] == '@':
      atPos = i; break
    if inputText[i] == ' ':
      break  # Space before finding '@' means no active trigger

  if atPos < 0:
    ms.dismissComplete(); return

  # Validate: '@' must be at start or preceded by a space
  if atPos > 0 and inputText[atPos - 1] != ' ':
    ms.dismissComplete(); return

  let query = inputText[atPos + 1 ..< cursorPos]
  let ch = cs.channels[cs.activeChannel]

  # Score and filter all users via fuzzy matching (strip mode prefixes)
  var scored: seq[tuple[score: int, nick: string]] = @[]
  for user in ch.users:
    let nick = bareNick(user)
    if nick == cs.myNick: continue  # Don't suggest yourself
    let s = fuzzyScore(query, nick)
    if s < 9999:
      scored.add((s, nick))
  # Sort by score (best first), then alphabetically for ties
  scored.sort(proc(a, b: tuple[score: int, nick: string]): int =
    result = cmp(a.score, b.score)
    if result == 0:
      result = cmp(a.nick.toLowerAscii, b.nick.toLowerAscii)
  )
  # Cap to a reasonable number of suggestions
  const maxSuggestions = 10
  var matches: seq[string] = @[]
  for i in 0 ..< min(scored.len, maxSuggestions):
    matches.add(scored[i].nick)

  if matches.len == 0:
    ms.dismissComplete(); return

  ms.nickComplete.active = true
  ms.nickComplete.atPos = atPos
  ms.nickComplete.query = query
  ms.nickComplete.matches = matches
  if ms.nickComplete.selected >= matches.len:
    ms.nickComplete.selected = 0

proc acceptComplete(ms: MasterState) =
  ## Accept the currently selected autocomplete suggestion.
  if not ms.nickComplete.active or ms.nickComplete.matches.len == 0:
    return
  let nick = ms.nickComplete.matches[ms.nickComplete.selected]
  let atPos = ms.nickComplete.atPos
  let cursorPos = ms.inputField.cursor

  # Replace @query with nick (add ": " if at start of line, " " otherwise)
  let suffix = if atPos == 0: ": " else: " "
  let replacement = nick & suffix
  let before = ms.inputField.text[0 ..< atPos]
  let after = if cursorPos < ms.inputField.text.len:
                ms.inputField.text[cursorPos .. ^1]
              else: ""
  ms.inputField.setText(before & replacement & after)
  ms.inputField.cursor = before.len + replacement.len
  ms.dismissComplete()

# ============================================================
# Traditional Tab nick-completion
# ============================================================

proc resetTabComplete(ms: MasterState) =
  ms.tabComplete = TabComplete()

proc doTabComplete(ms: MasterState) =
  let cs = ms.chat
  if cs == nil: return
  let ch = cs.channels[cs.activeChannel]
  let inputText = ms.inputField.text
  let cursor = ms.inputField.cursor

  if not ms.tabComplete.active:
    # Start new tab completion
    # Find word start: scan backwards from cursor
    var wordStart = cursor
    while wordStart > 0 and inputText[wordStart - 1] != ' ':
      dec wordStart
    let prefix = inputText[wordStart ..< cursor].toLowerAscii
    if prefix.len == 0: return

    # Find matching nicks
    var matches: seq[string] = @[]
    for user in ch.users:
      let bn = bareNick(user)
      if bn.toLowerAscii.startsWith(prefix):
        if bn notin matches:
          matches.add(bn)
    matches.sort(proc(a, b: string): int = cmp(a.toLowerAscii, b.toLowerAscii))
    if matches.len == 0: return

    ms.tabComplete = TabComplete(
      active: true,
      prefix: prefix,
      wordStart: wordStart,
      candidates: matches,
      index: 0,
    )
  else:
    # Cycle to next candidate
    ms.tabComplete.index = (ms.tabComplete.index + 1) mod ms.tabComplete.candidates.len

  # Apply completion
  let tc = ms.tabComplete
  let nick = tc.candidates[tc.index]
  let suffix = if tc.wordStart == 0: ": " else: " "
  let before = inputText[0 ..< tc.wordStart]
  let replacement = nick & suffix
  # Find end of current completion (from wordStart to next space or end)
  var endPos = tc.wordStart
  if tc.index == 0 and not ms.tabComplete.active:
    endPos = cursor  # First time: replace the typed prefix
  else:
    # Subsequent: replace previous completion
    endPos = tc.wordStart
    while endPos < inputText.len and inputText[endPos] != ' ':
      inc endPos
    # Also skip the suffix space/colon-space
    if endPos < inputText.len and inputText[endPos] == ' ':
      inc endPos
    if endPos < inputText.len and endPos > 0 and inputText[endPos - 1] == ':':
      if endPos < inputText.len and inputText[endPos] == ' ':
        inc endPos
  # Simpler approach: just replace from wordStart to current cursor
  let after = if ms.inputField.cursor < inputText.len:
                inputText[ms.inputField.cursor .. ^1]
              else: ""
  ms.inputField.setText(before & replacement & after)
  ms.inputField.cursor = before.len + replacement.len

# ============================================================
# Search helpers
# ============================================================

proc startSearch(ms: MasterState) =
  ms.search.active = true
  ms.search.query = ""
  ms.search.matchLines = @[]
  ms.search.currentMatch = -1
  ms.search.input = newTextInput(placeholder = "Search...")
  ms.search.input.focused = true

proc updateSearchMatches(ms: MasterState) =
  let cs = ms.chat
  if cs == nil: return
  let ch = cs.channels[cs.activeChannel]
  let q = ms.search.query.toLowerAscii
  ms.search.matchLines = @[]
  if q.len == 0: return
  for i, line in ch.messages.lines:
    if line.text.toLowerAscii.contains(q):
      ms.search.matchLines.add(i)
  ms.search.currentMatch = if ms.search.matchLines.len > 0: 0 else: -1

proc searchNext(ms: MasterState) =
  if ms.search.matchLines.len == 0: return
  ms.search.currentMatch = (ms.search.currentMatch + 1) mod ms.search.matchLines.len
  let lineIdx = ms.search.matchLines[ms.search.currentMatch]
  let ch = ms.chat.channels[ms.chat.activeChannel]
  ch.messages.scrollOffset = max(0, lineIdx - 2)
  ch.messages.autoScroll = false

proc searchPrev(ms: MasterState) =
  if ms.search.matchLines.len == 0: return
  ms.search.currentMatch = (ms.search.currentMatch + ms.search.matchLines.len - 1) mod ms.search.matchLines.len
  let lineIdx = ms.search.matchLines[ms.search.currentMatch]
  let ch = ms.chat.channels[ms.chat.activeChannel]
  ch.messages.scrollOffset = max(0, lineIdx - 2)
  ch.messages.autoScroll = false

proc dismissSearch(ms: MasterState) =
  ms.search.active = false

# ============================================================
# Quick Switcher helpers
# ============================================================

proc openQuickSwitcher(ms: MasterState) =
  let cs = ms.chat
  if cs == nil: return
  ms.quickSwitcher.active = true
  ms.quickSwitcher.input = newTextInput(placeholder = "Switch channel...")
  ms.quickSwitcher.input.focused = true
  ms.quickSwitcher.selected = 0
  # Initialize with all channels
  ms.quickSwitcher.filtered = @[]
  for i, ch in cs.channels:
    ms.quickSwitcher.filtered.add((i, ch.name))

proc updateQuickSwitcher(ms: MasterState) =
  let cs = ms.chat
  if cs == nil: return
  let q = ms.quickSwitcher.input.text.toLowerAscii
  ms.quickSwitcher.filtered = @[]
  if q.len == 0:
    for i, ch in cs.channels:
      ms.quickSwitcher.filtered.add((i, ch.name))
  else:
    var scored: seq[tuple[score: int, idx: int, name: string]] = @[]
    for i, ch in cs.channels:
      let s = fuzzyScore(q, ch.name)
      if s < 9999:
        scored.add((s, i, ch.name))
    scored.sort(proc(a, b: tuple[score: int, idx: int, name: string]): int = cmp(a.score, b.score))
    for item in scored:
      ms.quickSwitcher.filtered.add((item.idx, item.name))
  ms.quickSwitcher.selected = 0

proc dismissQuickSwitcher(ms: MasterState) =
  ms.quickSwitcher.active = false

# ============================================================
# IRC event processing
# ============================================================

proc processIrcEventsForChat(ms: MasterState, cs: IrcChatState): bool =
  ## Process IRC events for a single server connection.
  if cs == nil or cs.client == nil: return false
  var changed = false
  var eventsThisTick = 0
  const maxEventsPerTick = 200  # Prevent processing from starving the render loop
  while eventsThisTick < maxEventsPerTick:
    let evtOpt = cs.client.events.tryRecv()
    if evtOpt.isNone: break
    changed = true
    inc eventsThisTick
    let evt = evtOpt.get()
    cs.eventCounts[evt.kind] += 1

    # Check if this event belongs to an active batch — accumulate instead of displaying
    if evt.msgBatchRef.len > 0 and evt.kind notin {iekBatch}:
      var batchIdx = -1
      for i in 0 ..< cs.batches.len:
        if cs.batches[i].batchRef == evt.msgBatchRef:
          batchIdx = i
          break
      if batchIdx >= 0:
        # Accumulate into batch
        var bm = BatchMessage()
        case evt.kind
        of iekPrivMsg:
          bm = BatchMessage(kind: "privmsg", source: evt.pmPrefix.nick,
                           target: evt.pmTarget, text: evt.pmText)
        of iekNotice:
          bm = BatchMessage(kind: "notice", source: evt.pmPrefix.nick,
                           target: evt.pmTarget, text: evt.pmText)
        of iekJoin:
          bm = BatchMessage(kind: "join", source: evt.joinNick,
                           target: evt.joinChannel)
          # Still update user list
          let chIdx = cs.findChannel(evt.joinChannel)
          if chIdx >= 0 and evt.joinNick != cs.myNick:
            var found = false
            for u in cs.channels[chIdx].users:
              if bareNick(u) == evt.joinNick:
                found = true
                break
            if not found:
              cs.channels[chIdx].users.add(evt.joinNick)
              cs.channels[chIdx].users.sort(cmpUsers)
        of iekPart:
          bm = BatchMessage(kind: "part", source: evt.partNick,
                           target: evt.partChannel, text: evt.partReason)
          let chIdx = cs.findChannel(evt.partChannel)
          if chIdx >= 0:
            for j in countdown(cs.channels[chIdx].users.len - 1, 0):
              if bareNick(cs.channels[chIdx].users[j]) == evt.partNick:
                cs.channels[chIdx].users.delete(j)
                break
        of iekQuit:
          bm = BatchMessage(kind: "quit", source: evt.quitNick,
                           text: evt.quitReason)
          # Still remove from all channels
          for i in 0 ..< cs.channels.len:
            for j in countdown(cs.channels[i].users.len - 1, 0):
              if bareNick(cs.channels[i].users[j]) == evt.quitNick:
                cs.channels[i].users.delete(j)
                break
        else:
          bm = BatchMessage(kind: $evt.kind, source: "")
        cs.batches[batchIdx].messages.add(bm)
        continue  # Skip normal display processing

    try:
      case evt.kind
      of iekConnected:
        cs.myNick = cs.client.currentNick
        cs.addServerMsg("Connected as " & cs.myNick)
        ms.notifications.notify("Connected to " & cs.client.config.host, nlSuccess)
      of iekDisconnected:
        cs.addServerMsg("Disconnected: " & evt.reason)
        ms.notifications.notify("Disconnected", nlWarning)
      of iekPrivMsg:
        let target = evt.pmTarget
        let source = evt.pmPrefix.nick
        # Check ignore list
        if source.toLowerAscii in ms.config.ignoreList.mapIt(it.toLowerAscii):
          discard
        # echo-message: skip if this is our own message echoed back
        elif source == cs.myNick and "echo-message" in cs.client.enabledCaps:
          discard  # We already displayed it when sending
        else:
          let msgText = stripIrcFormatting(evt.pmText)
          let highlights = ms.config.highlights
          if target.isChannel():
            cs.addMsg(target, source, msgText, highlights)
            if cs.isMention(msgText, target, highlights):
              ms.notifications.notify(source & " in " & target & ": " & msgText, nlInfo, 8.0)
          else:
            cs.addMsg(source, source, msgText, highlights)
            ms.notifications.notify("DM from " & source & ": " & msgText, nlInfo, 8.0)
      of iekNotice:
        let source = evt.pmPrefix.nick
        let text = stripIrcFormatting(evt.pmText)
        if source.len > 0:
          if evt.pmTarget.isChannel():
            cs.addSystem(evt.pmTarget, "[" & source & "] " & text)
          else:
            # Route DM notices to a query window for the sender
            let idx = cs.getOrCreateChannel(source)
            let ts = now().format("HH:mm")
            cs.channels[idx].messages.addLine("-" & source & "- " & text, activeTheme.system, ts)
            logMessage(source, "-" & source & "- " & text)
            if idx != cs.activeChannel:
              cs.channels[idx].unread += 1
            ms.notifications.notify("Notice from " & source & ": " & text, nlInfo, 5.0)
        else:
          cs.addServerMsg(text)
      of iekJoin:
        let idx = cs.getOrCreateChannel(evt.joinChannel)
        if evt.joinNick == cs.myNick:
          cs.addSystem(evt.joinChannel, "You have joined " & evt.joinChannel)
          cs.switchChannel(idx)
        else:
          # Extended-join: raw message may have account and realname in extra params
          var joinInfo = evt.joinNick & " has joined"
          if evt.joinPrefix.user.len > 0:
            joinInfo &= " (" & evt.joinPrefix.user & "@" & evt.joinPrefix.host & ")"
          cs.addSystem(evt.joinChannel, joinInfo)
          if idx < cs.channels.len:
            # Check if nick already exists (by bare nick)
            var found = false
            for u in cs.channels[idx].users:
              if bareNick(u) == evt.joinNick:
                found = true
                break
            if not found:
              cs.channels[idx].users.add(evt.joinNick)
              cs.channels[idx].users.sort(cmpUsers)
      of iekPart:
        if evt.partNick == cs.myNick:
          cs.addSystem(evt.partChannel, "You have left " & evt.partChannel)
          cs.removeChannel(evt.partChannel)
        else:
          let reason = if evt.partReason.len > 0: " (" & evt.partReason & ")" else: ""
          cs.addSystem(evt.partChannel, evt.partNick & " has left" & reason)
          let idx = cs.findChannel(evt.partChannel)
          if idx >= 0:
            for j in countdown(cs.channels[idx].users.len - 1, 0):
              if bareNick(cs.channels[idx].users[j]) == evt.partNick:
                cs.channels[idx].users.delete(j)
                break
      of iekQuit:
        let reason = if evt.quitReason.len > 0: " (" & evt.quitReason & ")" else: ""
        for i in countdown(cs.channels.len - 1, 0):
          for j in countdown(cs.channels[i].users.len - 1, 0):
            if bareNick(cs.channels[i].users[j]) == evt.quitNick:
              cs.addSystem(cs.channels[i].name, evt.quitNick & " has quit" & reason)
              cs.channels[i].users.delete(j)
              break
      of iekKick:
        let reason = if evt.kickReason.len > 0: " (" & evt.kickReason & ")" else: ""
        if evt.kickNick == cs.myNick:
          cs.addError(evt.kickChannel, "You were kicked by " & evt.kickBy & reason)
          cs.removeChannel(evt.kickChannel)
        else:
          cs.addSystem(evt.kickChannel, evt.kickNick & " was kicked by " & evt.kickBy & reason)
      of iekNick:
        if evt.nickOld == cs.myNick:
          cs.myNick = evt.nickNew
          cs.addServerMsg("You are now known as " & evt.nickNew)
        else:
          for i in 0 ..< cs.channels.len:
            for j in 0 ..< cs.channels[i].users.len:
              if bareNick(cs.channels[i].users[j]) == evt.nickOld:
                let prefix = userPrefix(cs.channels[i].users[j])
                cs.channels[i].users[j] = prefix & evt.nickNew
                cs.addSystem(cs.channels[i].name, evt.nickOld & " is now known as " & evt.nickNew)
                break
      of iekTopic:
        let idx = cs.findChannel(evt.topicChannel)
        if idx >= 0:
          cs.channels[idx].topic = evt.topicText
          if evt.topicBy.len > 0:
            cs.addSystem(evt.topicChannel, evt.topicBy & " changed the topic to: " & evt.topicText)
          else:
            cs.addSystem(evt.topicChannel, "Topic: " & evt.topicText)
      of iekCtcp:
        if evt.ctcpCommand == "ACTION":
          let target = evt.ctcpTarget
          if target.isChannel():
            cs.addAction(target, evt.ctcpSource, evt.ctcpArgs)
            if containsMention(evt.ctcpArgs, cs.myNick):
              ms.notifications.notify("* " & evt.ctcpSource & " " & evt.ctcpArgs, nlInfo, 8.0)
          else:
            cs.addAction(evt.ctcpSource, evt.ctcpSource, evt.ctcpArgs)
            ms.notifications.notify("DM action from " & evt.ctcpSource, nlInfo, 8.0)
      of iekNumeric:
        case evt.numCode
        of RPL_TOPIC:
          if evt.numParams.len >= 3:
            let ch = evt.numParams[1]
            let topic = evt.numParams[2]
            let idx = cs.findChannel(ch)
            if idx >= 0:
              cs.channels[idx].topic = topic
              cs.addSystem(ch, "Topic: " & topic)
        of RPL_NAMREPLY:
          if evt.numParams.len >= 4:
            let ch = evt.numParams[2]
            let names = evt.numParams[3].split(' ')
            let idx = cs.findChannel(ch)
            if idx >= 0:
              for rawName in names:
                if rawName.len == 0: continue
                # Strip userhost-in-names hostmask: @nick!user@host → @nick
                let name = block:
                  let bangIdx = rawName.find('!')
                  if bangIdx >= 0: rawName[0 ..< bangIdx] else: rawName
                let bn = bareNick(name)
                # Remove old entry for this nick (if any) and add with prefix
                var found = false
                for j in 0 ..< cs.channels[idx].users.len:
                  if bareNick(cs.channels[idx].users[j]) == bn:
                    cs.channels[idx].users[j] = name  # Update with new prefix
                    found = true
                    break
                if not found:
                  cs.channels[idx].users.add(name)
              cs.channels[idx].users.sort(cmpUsers)
        of RPL_MOTD, RPL_MOTDSTART:
          if evt.numParams.len >= 2:
            cs.addServerMsg(evt.numParams[^1])
        of RPL_ENDOFMOTD, ERR_NOMOTD:
          cs.addServerMsg("--- End of MOTD ---")
        of ERR_NICKNAMEINUSE:
          cs.myNick = cs.client.currentNick
          cs.addServerMsg("Nick in use, trying " & cs.myNick)
        of RPL_WHOISUSER:
          if evt.numParams.len >= 6:
            cs.whois = WhoisState(collecting: true)
            cs.whois.nick = evt.numParams[1]
            cs.whois.user = evt.numParams[2]
            cs.whois.host = evt.numParams[3]
            cs.whois.realname = evt.numParams[5]
        of RPL_WHOISSERVER:
          if cs.whois.collecting and evt.numParams.len >= 4:
            cs.whois.server = evt.numParams[2]
            cs.whois.serverInfo = evt.numParams[3]
        of RPL_WHOISOPERATOR:
          if cs.whois.collecting:
            cs.whois.isOper = true
        of RPL_WHOISIDLE:
          if cs.whois.collecting and evt.numParams.len >= 3:
            cs.whois.idle = evt.numParams[2]
        of RPL_WHOISCHANNELS:
          if cs.whois.collecting and evt.numParams.len >= 3:
            cs.whois.channels = evt.numParams[2]
        of RPL_WHOISACCOUNT:
          if cs.whois.collecting and evt.numParams.len >= 3:
            cs.whois.account = evt.numParams[2]
        of RPL_ENDOFWHOIS:
          if cs.whois.collecting:
            let w = cs.whois
            let ch = cs.currentChannel.name
            cs.addSystem(ch, "--- WHOIS " & w.nick & " ---")
            cs.addSystem(ch, w.nick & " (" & w.user & "@" & w.host & "): " & w.realname)
            if w.server.len > 0:
              cs.addSystem(ch, "  Server: " & w.server & " (" & w.serverInfo & ")")
            if w.channels.len > 0:
              cs.addSystem(ch, "  Channels: " & w.channels)
            if w.account.len > 0:
              cs.addSystem(ch, "  Account: " & w.account)
            if w.idle.len > 0:
              cs.addSystem(ch, "  Idle: " & w.idle & "s")
            if w.isOper:
              cs.addSystem(ch, "  IRC Operator")
            cs.addSystem(ch, "--- End of WHOIS ---")
            cs.whois = WhoisState()
        of RPL_NOWAWAY:
          cs.isAway = true
          cs.addServerMsg("You are now marked as away")
        of RPL_UNAWAY:
          cs.isAway = false
          cs.addServerMsg("You are no longer marked as away")
        of RPL_CHANNELMODEIS:
          if evt.numParams.len >= 3:
            let ch = evt.numParams[1]
            let modes = evt.numParams[2..^1].join(" ")
            cs.addSystem(ch, "Channel mode: " & modes)
        of RPL_MONONLINE:
          if evt.numParams.len >= 2:
            cs.addServerMsg("Online: " & evt.numParams[1])
        of RPL_MONOFFLINE:
          if evt.numParams.len >= 2:
            cs.addServerMsg("Offline: " & evt.numParams[1])
        of ERR_MONLISTFULL:
          cs.addError(ServerChannel, "MONITOR list is full")
        else:
          if evt.numParams.len > 1:
            cs.addServerMsg("[" & $evt.numCode & "] " & evt.numParams[1..^1].join(" "))
      of iekMode:
        let idx = cs.findChannel(evt.modeTarget)
        if idx >= 0:
          cs.addSystem(evt.modeTarget, "Mode " & evt.modeChanges & " " & evt.modeParams.join(" "))
          # Update user prefixes based on mode changes
          if evt.modeParams.len > 0 and idx < cs.channels.len:
            var adding = true
            var paramIdx = 0
            for ch in evt.modeChanges:
              case ch
              of '+': adding = true
              of '-': adding = false
              of 'o', 'v', 'h':
                if paramIdx < evt.modeParams.len:
                  let targetNick = evt.modeParams[paramIdx]
                  inc paramIdx
                  let prefixChar = case ch
                    of 'o': '@'
                    of 'v': '+'
                    of 'h': '%'
                    else: ' '
                  # Find user in channel
                  for j in 0 ..< cs.channels[idx].users.len:
                    let bn = bareNick(cs.channels[idx].users[j])
                    if bn == targetNick:
                      if adding:
                        cs.channels[idx].users[j] = $prefixChar & bn
                      else:
                        # Remove prefix
                        cs.channels[idx].users[j] = bn
                      break
                  cs.channels[idx].users.sort(cmpUsers)
              else:
                if ch in {'k', 'l', 'b', 'e', 'I'} and paramIdx < evt.modeParams.len:
                  inc paramIdx
      of iekInvite:
        cs.addServerMsg(evt.inviteNick & " invited you to " & evt.inviteChannel)
        ms.notifications.notify("Invited to " & evt.inviteChannel & " by " & evt.inviteNick, nlInfo)
      of iekError:
        cs.addError(ServerChannel, evt.errMsg)
      of iekPing:
        discard
      of iekAway:
        # away-notify: show in channels where the user is present
        let awayNick = evt.awayNick
        if evt.awayMessage.len > 0:
          for i in 0 ..< cs.channels.len:
            for u in cs.channels[i].users:
              if bareNick(u) == awayNick:
                cs.addSystem(cs.channels[i].name, awayNick & " is away: " & evt.awayMessage)
                break
        else:
          for i in 0 ..< cs.channels.len:
            for u in cs.channels[i].users:
              if bareNick(u) == awayNick:
                cs.addSystem(cs.channels[i].name, awayNick & " is back")
                break
      of iekChghost:
        for i in 0 ..< cs.channels.len:
          for u in cs.channels[i].users:
            if bareNick(u) == evt.chghostNick:
              cs.addSystem(cs.channels[i].name, evt.chghostNick & " changed host: " & evt.chghostNewUser & "@" & evt.chghostNewHost)
              break
      of iekSetname:
        for i in 0 ..< cs.channels.len:
          for u in cs.channels[i].users:
            if bareNick(u) == evt.setnameNick:
              cs.addSystem(cs.channels[i].name, evt.setnameNick & " changed realname: " & evt.setnameRealname)
              break
      of iekAccount:
        let acctMsg = if evt.accountName == "*": "logged out"
                      else: "logged in as " & evt.accountName
        for i in 0 ..< cs.channels.len:
          for u in cs.channels[i].users:
            if bareNick(u) == evt.accountNick:
              cs.addSystem(cs.channels[i].name, evt.accountNick & " " & acctMsg)
              break
      of iekBatch:
        if evt.batchStarting:
          # Start accumulating batch messages
          cs.batches.add(BatchAccumulator(
            active: true,
            batchRef: evt.batchRef,
            batchType: evt.batchType,
            batchParams: evt.batchParams,
            messages: @[],
          ))
        else:
          # Find and close the matching batch, display grouped
          var batchIdx = -1
          for i in 0 ..< cs.batches.len:
            if cs.batches[i].batchRef == evt.batchRef:
              batchIdx = i
              break
          if batchIdx >= 0:
            let batch = cs.batches[batchIdx]
            cs.batches.delete(batchIdx)
            # Display grouped batch
            case batch.batchType
            of "netsplit":
              let server = if batch.batchParams.len >= 1: batch.batchParams[0] else: "?"
              let server2 = if batch.batchParams.len >= 2: batch.batchParams[1] else: ""
              let splitDesc = server & (if server2.len > 0: " <-> " & server2 else: "")
              var quitNicks: seq[string] = @[]
              for msg in batch.messages:
                quitNicks.add(msg.source)
              let summary = "Netsplit " & splitDesc & ": " &
                            $quitNicks.len & " users quit" &
                            (if quitNicks.len <= 5: " (" & quitNicks.join(", ") & ")"
                             else: " (" & quitNicks[0..4].join(", ") & ", ...)")
              # Display in all affected channels
              for msg in batch.messages:
                for i in 0 ..< cs.channels.len:
                  for u in cs.channels[i].users:
                    if bareNick(u) == msg.source:
                      cs.addSystem(cs.channels[i].name, summary)
                      break
              if batch.messages.len == 0:
                cs.addServerMsg(summary)
            of "netjoin":
              var joinNicks: seq[string] = @[]
              for msg in batch.messages:
                joinNicks.add(msg.source)
              let summary = "Netjoin: " & $joinNicks.len & " users rejoined" &
                            (if joinNicks.len <= 5: " (" & joinNicks.join(", ") & ")"
                             else: " (" & joinNicks[0..4].join(", ") & ", ...)")
              cs.addServerMsg(summary)
            of "chathistory":
              # Display chat history messages normally
              for msg in batch.messages:
                case msg.kind
                of "privmsg":
                  cs.addMsg(msg.target, msg.source, msg.text)
                of "notice":
                  cs.addSystem(msg.target, "[" & msg.source & "] " & msg.text)
                else:
                  cs.addSystem(msg.target, msg.source & ": " & msg.text)
            else:
              # Generic batch: display type and count
              if batch.messages.len > 0:
                cs.addServerMsg("Batch [" & batch.batchType & "]: " &
                               $batch.messages.len & " messages")
              for msg in batch.messages:
                cs.addServerMsg("  " & msg.source & " -> " & msg.target & ": " & msg.text)
      of iekDccSend:
        discard cs.dccManager.addOffer(evt.dccSource, evt.dccInfo)
        let sizeStr = formatSize(evt.dccInfo.filesize)
        cs.addServerMsg("DCC SEND from " & evt.dccSource & ": " & evt.dccInfo.filename & " (" & sizeStr & ")")
        ms.notifications.notify("DCC: " & evt.dccInfo.filename & " from " & evt.dccSource, nlInfo, 10.0)
        changed = true
      of iekDccAccept:
        for t in cs.dccManager.pendingOffers:
          if t.source.toLowerAscii == evt.dccSource.toLowerAscii and
             t.info.filename == evt.dccInfo.filename:
            t.setResumePosition(evt.dccInfo.filesize)
            break
      of iekDccChat:
        cs.addServerMsg("DCC CHAT request from " & evt.dccSource & " (not supported)")
        changed = true
      of iekDccResume:
        cs.addServerMsg("DCC RESUME from " & evt.dccSource)
        changed = true
      else:
        discard
    except Exception:
      # Don't let a single bad event crash the entire TUI
      cs.addError(ServerChannel, "Event processing error: " & getCurrentExceptionMsg())
  # Force redraw while transfers are active (progress updates)
  if cs.dccManager != nil and cs.dccManager.activeTransfers.len > 0:
    changed = true
  return changed

proc processIrcEvents(ms: MasterState): bool =
  ## Process IRC events for all connected servers.
  var changed = false
  for cs in ms.chats:
    if ms.processIrcEventsForChat(cs):
      changed = true
  return changed

# ============================================================
# Connect to a server (transition to chat)
# ============================================================

proc connectToServer(ms: MasterState, server: ServerEntry) =
  # Check if already connected to this server — switch to it instead
  for i, cs in ms.chats:
    if cs.client.config.host == server.host and
       cs.client.config.port == server.port:
      ms.activeChat = i
      ms.screen = asChat
      ms.tuiApp.fullRedraw = true
      return

  let nick = ms.config.profile.nick
  var config = newIrcClientConfig(server.host, server.port, nick)
  config.username = ms.config.profile.username
  config.realname = ms.config.profile.realname
  if server.password.len > 0:
    config.password = server.password
  config.autoJoinChannels = server.channels
  config.autoReconnect = true
  config.reconnectDelayMs = 5000
  config.ctcpVersion = "CPS IRC TUI 1.0"
  config.useTls = server.useTls
  if server.saslUsername.len > 0:
    config.saslUsername = server.saslUsername
    config.saslPassword = server.saslPassword

  let client = newIrcClient(config)
  # Derive short label from hostname (e.g., "irc.libera.chat" -> "libera")
  let hostParts = server.host.split('.')
  let label = if hostParts.len >= 2: hostParts[^2] else: server.host
  let cs = IrcChatState(
    client: client,
    channels: @[],
    activeChannel: 0,
    splitView: newSplitView(dirHorizontal, 0.2, minFirst = 12, minSecond = 30),
    statusBar: newStatusBar(style(clBlack, clCyan)),
    myNick: nick,
    serverLabel: label,
    dccManager: newDccManager(downloadDir = "downloads", maxConcurrent = 3),
  )

  # Server console
  var serverCh = Channel(
    name: ServerChannel,
    messages: newScrollableTextView(maxLines = 500, autoScroll = true),
    users: @[], topic: "Server messages", unread: 0,
  )
  serverCh.messages.showTimestamps = true
  cs.channels = @[serverCh]
  cs.addServerMsg("Connecting to " & server.host & ":" & $server.port & " as " & nick & "...")
  if server.channels.len > 0:
    cs.addServerMsg("Auto-joining: " & server.channels.join(", "))

  ms.addChat(cs)
  ms.screen = asChat
  ms.inputField.clear()
  ms.tuiApp.title = "IRC - " & server.host
  ms.tuiApp.fullRedraw = true

  # Start IRC client concurrently
  discard client.run()

# ============================================================
# Command handling (chat screen)
# ============================================================

proc handleChatCommand(ms: MasterState, cmd: string) =
  let cs = ms.chat
  let parts = cmd.split(' ', 1)
  let command = parts[0].toLowerAscii

  case command
  of "/quit":
    ms.running = false
    for chat in ms.chats:
      if chat.client != nil:
        discard chat.client.disconnect()
    ms.tuiApp.stop()
  of "/help":
    ms.helpDialog.toggle()
  of "/part":
    let ch = cs.currentChannel.name
    if ch != ServerChannel and ch.isChannel():
      discard cs.client.partChannel(ch, if parts.len > 1: parts[1] else: "")
    else:
      cs.addError(ch, "Cannot part " & ch)
  of "/join":
    if parts.len > 1:
      let target = parts[1].strip()
      if target.len > 0:
        discard cs.client.joinChannel(target)
      else:
        cs.addError(cs.currentChannel.name, "Usage: /join #channel")
    else:
      cs.addError(cs.currentChannel.name, "Usage: /join #channel")
  of "/nick":
    if parts.len > 1:
      discard cs.client.changeNick(parts[1].strip())
    else:
      cs.addError(cs.currentChannel.name, "Usage: /nick newnick")
  of "/msg":
    if parts.len > 1:
      let msgParts = parts[1].split(' ', 1)
      if msgParts.len >= 2:
        discard cs.client.privMsg(msgParts[0], msgParts[1])
        cs.addMsg(msgParts[0], cs.myNick, msgParts[1])
        # Switch to the DM channel
        let idx = cs.findChannel(msgParts[0])
        if idx >= 0:
          cs.switchChannel(idx)
      else:
        cs.addError(cs.currentChannel.name, "Usage: /msg target message")
    else:
      cs.addError(cs.currentChannel.name, "Usage: /msg target message")
  of "/query":
    # Open a DM window with a nick (optionally sending a message)
    if parts.len > 1:
      let queryParts = parts[1].strip().split(' ', 1)
      let target = queryParts[0]
      if target.len > 0:
        let idx = cs.getOrCreateChannel(target)
        cs.switchChannel(idx)
        if queryParts.len >= 2 and queryParts[1].len > 0:
          discard cs.client.privMsg(target, queryParts[1])
          cs.addMsg(target, cs.myNick, queryParts[1])
      else:
        cs.addError(cs.currentChannel.name, "Usage: /query nick [message]")
    else:
      cs.addError(cs.currentChannel.name, "Usage: /query nick [message]")
  of "/me":
    let ch = cs.currentChannel.name
    if parts.len > 1 and ch != ServerChannel:
      discard cs.client.ctcpSend(ch, "ACTION", parts[1])
      cs.addAction(ch, cs.myNick, parts[1])
    else:
      cs.addError(ch, "Usage: /me action text")
  of "/topic":
    let ch = cs.currentChannel.name
    if ch.isChannel():
      if parts.len > 1:
        discard cs.client.sendMessage("TOPIC", ch, parts[1])
      else:
        discard cs.client.sendMessage("TOPIC", ch)
    else:
      cs.addError(ch, "Not a channel")
  of "/raw":
    if parts.len > 1:
      discard cs.client.sendMessage(parts[1])
      cs.addServerMsg(">>> " & parts[1])
  of "/server":
    if parts.len > 1:
      let subParts = parts[1].strip().split(' ', 1)
      let sub = subParts[0].toLowerAscii
      case sub
      of "list":
        ms.screen = asServerList
        ms.serverListIdx = 0
        ms.addServerMode = false
        ms.tuiApp.fullRedraw = true
      of "add":
        ms.screen = asServerList
        ms.addServerMode = true
        ms.initAddFields()
        ms.tuiApp.fullRedraw = true
      of "remove":
        if subParts.len > 1:
          let name = subParts[1].strip()
          var removed = false
          for i in countdown(ms.config.servers.len - 1, 0):
            if ms.config.servers[i].name.toLowerAscii == name.toLowerAscii:
              ms.config.servers.delete(i)
              removed = true
              break
          if removed:
            saveConfig(ms.config)
            cs.addSystem(cs.currentChannel.name, "Removed server: " & name)
          else:
            cs.addError(cs.currentChannel.name, "Server not found: " & name)
        else:
          cs.addError(cs.currentChannel.name, "Usage: /server remove <name>")
      of "connect":
        # Connect to a saved server by name (multi-server)
        if subParts.len > 1:
          let name = subParts[1].strip()
          var found = false
          for srv in ms.config.servers:
            if srv.name.toLowerAscii == name.toLowerAscii:
              ms.connectToServer(srv)
              found = true
              break
          if not found:
            cs.addError(cs.currentChannel.name, "Server not found: " & name & ". Use /server list to see available.")
        else:
          cs.addError(cs.currentChannel.name, "Usage: /server connect <name>")
      of "switch":
        # Switch to another connected server by label or index
        if subParts.len > 1:
          let arg = subParts[1].strip()
          var switched = false
          # Try as index first
          try:
            let idx = parseInt(arg) - 1  # 1-based for user
            if idx >= 0 and idx < ms.chats.len:
              ms.switchChat(idx)
              switched = true
          except ValueError:
            discard
          # Try as label
          if not switched:
            for i, chat in ms.chats:
              if chat.serverLabel.toLowerAscii == arg.toLowerAscii:
                ms.switchChat(i)
                switched = true
                break
          if not switched:
            cs.addError(cs.currentChannel.name, "Server not found: " & arg)
        else:
          # List connected servers
          if ms.chats.len <= 1:
            cs.addSystem(cs.currentChannel.name, "Only one server connected")
          else:
            var lines: seq[string] = @[]
            for i, chat in ms.chats:
              let marker = if i == ms.activeChat: " *" else: ""
              lines.add("  " & $(i+1) & ". " & chat.serverLabel & " (" & chat.client.config.host & ")" & marker)
            cs.addSystem(cs.currentChannel.name, "Connected servers:\n" & lines.join("\n"))
      else:
        cs.addError(cs.currentChannel.name, "Usage: /server list|add|remove|connect|switch <name>")
    else:
      cs.addError(cs.currentChannel.name, "Usage: /server list|add|remove|connect|switch <name>")
  of "/whois":
    if parts.len > 1:
      let target = parts[1].strip()
      if target.len > 0:
        discard cs.client.sendMessage("WHOIS", target, target)
      else:
        cs.addError(cs.currentChannel.name, "Usage: /whois nick")
    else:
      cs.addError(cs.currentChannel.name, "Usage: /whois nick")
  of "/mode":
    let ch = cs.currentChannel.name
    if parts.len > 1:
      let args = parts[1].strip().split(' ')
      if args.len == 1 and args[0].isChannel():
        discard cs.client.sendMessage("MODE", args[0])
      elif args.len >= 1:
        let modeArgs = @[ch] & args
        case modeArgs.len
        of 1: discard cs.client.sendMessage("MODE", modeArgs[0])
        of 2: discard cs.client.sendMessage("MODE", modeArgs[0], modeArgs[1])
        else: discard cs.client.sendMessage("MODE", modeArgs[0], modeArgs[1], modeArgs[2..^1].join(" "))
    else:
      if ch.isChannel():
        discard cs.client.sendMessage("MODE", ch)
      else:
        cs.addError(ch, "Usage: /mode [channel] [modes] [params]")
  of "/away":
    if parts.len > 1:
      discard cs.client.sendMessage("AWAY", parts[1])
    else:
      discard cs.client.sendMessage("AWAY", "Away")
  of "/back":
    discard cs.client.sendMessage("AWAY")
  of "/ignore":
    if parts.len > 1:
      let nick = parts[1].strip().toLowerAscii
      if nick notin ms.config.ignoreList.mapIt(it.toLowerAscii):
        ms.config.ignoreList.add(nick)
        saveConfig(ms.config)
        cs.addSystem(cs.currentChannel.name, "Ignoring: " & nick)
      else:
        cs.addSystem(cs.currentChannel.name, nick & " is already ignored")
    else:
      if ms.config.ignoreList.len == 0:
        cs.addSystem(cs.currentChannel.name, "Ignore list is empty")
      else:
        cs.addSystem(cs.currentChannel.name, "Ignored: " & ms.config.ignoreList.join(", "))
  of "/unignore":
    if parts.len > 1:
      let nick = parts[1].strip().toLowerAscii
      var removed = false
      for i in countdown(ms.config.ignoreList.len - 1, 0):
        if ms.config.ignoreList[i].toLowerAscii == nick:
          ms.config.ignoreList.delete(i)
          removed = true
      if removed:
        saveConfig(ms.config)
        cs.addSystem(cs.currentChannel.name, "Unignored: " & nick)
      else:
        cs.addError(cs.currentChannel.name, nick & " is not in the ignore list")
    else:
      cs.addError(cs.currentChannel.name, "Usage: /unignore nick")
  of "/highlight":
    if parts.len > 1:
      let sub = parts[1].strip().split(' ', 1)
      case sub[0].toLowerAscii
      of "add":
        if sub.len > 1:
          let word = sub[1].strip()
          if word.len > 0 and word notin ms.config.highlights:
            ms.config.highlights.add(word)
            saveConfig(ms.config)
            cs.addSystem(cs.currentChannel.name, "Added highlight: " & word)
          else:
            cs.addSystem(cs.currentChannel.name, "Already highlighted or empty")
        else:
          cs.addError(cs.currentChannel.name, "Usage: /highlight add <word>")
      of "remove":
        if sub.len > 1:
          let word = sub[1].strip()
          let idx = ms.config.highlights.find(word)
          if idx >= 0:
            ms.config.highlights.delete(idx)
            saveConfig(ms.config)
            cs.addSystem(cs.currentChannel.name, "Removed highlight: " & word)
          else:
            cs.addError(cs.currentChannel.name, "Not in highlight list: " & word)
        else:
          cs.addError(cs.currentChannel.name, "Usage: /highlight remove <word>")
      of "list":
        if ms.config.highlights.len == 0:
          cs.addSystem(cs.currentChannel.name, "No custom highlight words")
        else:
          cs.addSystem(cs.currentChannel.name, "Highlights: " & ms.config.highlights.join(", "))
      else:
        cs.addError(cs.currentChannel.name, "Usage: /highlight add|remove|list [word]")
    else:
      if ms.config.highlights.len == 0:
        cs.addSystem(cs.currentChannel.name, "No custom highlight words")
      else:
        cs.addSystem(cs.currentChannel.name, "Highlights: " & ms.config.highlights.join(", "))
  of "/theme":
    if parts.len > 1:
      let name = parts[1].strip().toLowerAscii
      ms.theme = getTheme(name)
      activeTheme = ms.theme
      ms.config.themeName = name
      saveConfig(ms.config)
      cs.addSystem(cs.currentChannel.name, "Theme changed to: " & name)
      ms.tuiApp.fullRedraw = true
    else:
      cs.addSystem(cs.currentChannel.name, "Available themes: dark, light, solarized. Current: " & ms.config.themeName)
  of "/log":
    if parts.len > 1:
      let sub = parts[1].strip().split(' ', 1)
      case sub[0].toLowerAscii
      of "on":
        ms.config.loggingEnabled = true
        if ms.config.logDir.len == 0:
          ms.config.logDir = configDir() / "logs"
        logConfig = (true, ms.config.logDir)
        saveConfig(ms.config)
        cs.addSystem(cs.currentChannel.name, "Logging enabled: " & ms.config.logDir)
      of "off":
        ms.config.loggingEnabled = false
        logConfig = (false, "")
        saveConfig(ms.config)
        cs.addSystem(cs.currentChannel.name, "Logging disabled")
      of "dir":
        if sub.len > 1:
          ms.config.logDir = sub[1].strip()
          if ms.config.loggingEnabled:
            logConfig = (true, ms.config.logDir)
          saveConfig(ms.config)
          cs.addSystem(cs.currentChannel.name, "Log dir: " & ms.config.logDir)
        else:
          cs.addSystem(cs.currentChannel.name, "Log dir: " & (if ms.config.logDir.len > 0: ms.config.logDir else: "(not set)"))
      else:
        cs.addError(cs.currentChannel.name, "Usage: /log on|off|dir <path>")
    else:
      let status = if ms.config.loggingEnabled: "on" else: "off"
      cs.addSystem(cs.currentChannel.name, "Logging: " & status & ", dir: " & (if ms.config.logDir.len > 0: ms.config.logDir else: "(not set)"))
  of "/monitor":
    if parts.len > 1:
      let sub = parts[1].strip()
      discard cs.client.sendMessage("MONITOR", sub)
      cs.addSystem(cs.currentChannel.name, "MONITOR " & sub)
    else:
      cs.addError(cs.currentChannel.name, "Usage: /monitor + nick1,nick2 | - nick1 | C | L | S")
  of "/debug":
    var lines: seq[string] = @[]
    for kind in IrcEventKind:
      let count = cs.eventCounts[kind]
      if count > 0:
        lines.add($kind & ": " & $count)
    if lines.len == 0:
      cs.addSystem(cs.currentChannel.name, "No events received yet")
    else:
      cs.addSystem(cs.currentChannel.name, "Event counts: " & lines.join(", "))
    # Also show caps
    if cs.client.enabledCaps.len > 0:
      cs.addSystem(cs.currentChannel.name, "Enabled caps: " & cs.client.enabledCaps.join(", "))
  of "/close":
    let chName = if parts.len > 1: parts[1].strip() else: cs.currentChannel.name
    if chName == ServerChannel:
      cs.addError(chName, "Cannot close server window")
    else:
      if chName.isChannel():
        discard cs.client.partChannel(chName, "")
      cs.removeChannel(chName)
  of "/accept":
    let nick = if parts.len > 1: parts[1].strip() else: ""
    var found = false
    for t in cs.dccManager.pendingOffers:
      if nick.len == 0 or t.source.toLowerAscii == nick.toLowerAscii:
        let transfer = t
        let dm = cs.dccManager
        let fut = dm.acceptOffer(transfer)
        fut.addCallback(proc() = discard)
        cs.addServerMsg("Accepting: " & transfer.info.filename & " from " & transfer.source)
        found = true
        break
    if not found:
      cs.addError(ServerChannel, "No pending DCC offer" & (if nick.len > 0: " from " & nick else: ""))
  of "/decline":
    let nick = if parts.len > 1: parts[1].strip() else: ""
    var found = false
    for i in countdown(cs.dccManager.pendingOffers.len - 1, 0):
      let t = cs.dccManager.pendingOffers[i]
      if nick.len == 0 or t.source.toLowerAscii == nick.toLowerAscii:
        cs.addServerMsg("Declined: " & t.info.filename & " from " & t.source)
        cs.dccManager.pendingOffers.delete(i)
        found = true
        break
    if not found:
      cs.addError(ServerChannel, "No pending DCC offer to decline")
  of "/transfers":
    if cs.dccManager.pendingOffers.len == 0 and cs.dccManager.activeTransfers.len == 0 and cs.dccManager.completedTransfers.len == 0:
      cs.addServerMsg("No transfers")
    else:
      for t in cs.dccManager.pendingOffers:
        cs.addServerMsg("[pending] " & t.info.filename & " from " & t.source & " (" & formatSize(t.info.filesize) & ")")
      for t in cs.dccManager.activeTransfers:
        let pct = if t.totalBytes > 0: $int(t.bytesReceived * 100 div t.totalBytes) & "%" else: "?"
        cs.addServerMsg("[active] " & t.info.filename & " " & pct & " " & formatSize(t.bytesReceived) & "/" & formatSize(t.totalBytes))
      for t in cs.dccManager.completedTransfers:
        cs.addServerMsg("[done] " & t.info.filename & " " & formatSize(t.totalBytes))
  of "/clear":
    cs.currentChannel.messages.clear()
  of "/disconnect":
    discard cs.client.disconnect()
    if ms.chats.len > 1:
      # Remove this server from multi-server list
      let idx = ms.chats.find(cs)
      if idx >= 0:
        ms.removeChat(idx)
      ms.tuiApp.fullRedraw = true
    else:
      ms.screen = asServerList
      ms.tuiApp.fullRedraw = true
  else:
    cs.addError(cs.currentChannel.name, "Unknown command: " & command)

proc handleChatSend(ms: MasterState) =
  let text = ms.inputField.submit()
  if text.len == 0: return
  let cs = ms.chat
  if text.startsWith("/"):
    ms.handleChatCommand(text)
  else:
    let ch = cs.currentChannel.name
    if ch == ServerChannel:
      cs.addError(ch, "Cannot send messages to server console")
    else:
      discard cs.client.privMsg(ch, text)
      cs.addMsg(ch, cs.myNick, text)

# ============================================================
# Rendering: Loading screen
# ============================================================

proc renderLoading(ms: MasterState, width, height: int): Widget =
  let centerY = height div 2
  vbox(
    spacer(centerY - 1),
    text("Loading configuration...", style(clBrightCyan)).withAlign(alCenter),
    spacer(1),
    text(configPath(), style(clBrightBlack)).withAlign(alCenter),
  )

# ============================================================
# Closure factories for for-loop click handlers
# (Nim captures loop variables by reference — all closures in a loop
#  see the last value. These factories force per-iteration capture.)
# ============================================================

proc makeSetupFieldClickHandler(ms: MasterState, idx: int): proc(mx, my: int) =
  result = proc(mx, my: int) =
    ms.setupFocusIdx = idx

proc makeAddFieldClickHandler(ms: MasterState, idx: int): proc(mx, my: int) =
  result = proc(mx, my: int) =
    ms.addFocusIdx = idx

proc makeServerClickHandler(ms: MasterState, idx: int): proc(mx, my: int) =
  result = proc(mx, my: int) =
    if ms.serverListIdx == idx:
      ms.connectToServer(ms.config.servers[idx])
    else:
      ms.serverListIdx = idx

# ============================================================
# Rendering: Setup screen
# ============================================================

proc renderSetup(ms: MasterState, width, height: int): Widget =
  var rows: seq[Widget] = @[]

  # Title
  rows.add(spacer(1))
  rows.add(text("  CPS IRC Client - First Time Setup", style(clBrightCyan).bold()))
  rows.add(spacer(1))

  # Profile section
  rows.add(text("  Profile", style(clBrightWhite).bold().underline()))
  rows.add(spacer(1))
  for i in sfNick .. sfRealname:
    let labelSt = if i == ms.setupFocusIdx: style(clBrightWhite).bold()
                  else: style(clWhite)
    let indicator = if i == ms.setupFocusIdx: "> " else: "  "
    ms.setupFields[i].focused = (i == ms.setupFocusIdx)
    rows.add(
      hbox(
        text(indicator & SetupLabels[i], labelSt).withWidth(fixed(14)),
        ms.setupFields[i].toWidget(),
      ).withHeight(fixed(1))
       .withOnClick(ms.makeSetupFieldClickHandler(i))
    )

  rows.add(spacer(1))

  # Server section
  rows.add(text("  First Server", style(clBrightWhite).bold().underline()))
  rows.add(spacer(1))
  for i in sfServerName .. sfSaslPass:
    let labelSt = if i == ms.setupFocusIdx: style(clBrightWhite).bold()
                  else: style(clWhite)
    let indicator = if i == ms.setupFocusIdx: "> " else: "  "
    ms.setupFields[i].focused = (i == ms.setupFocusIdx)
    rows.add(
      hbox(
        text(indicator & SetupLabels[i], labelSt).withWidth(fixed(14)),
        ms.setupFields[i].toWidget(),
      ).withHeight(fixed(1))
       .withOnClick(ms.makeSetupFieldClickHandler(i))
    )

  rows.add(spacer(1))

  # Error message
  if ms.setupError.len > 0:
    rows.add(text("  " & ms.setupError, style(clBrightRed)))
    rows.add(spacer(1))

  let form = vbox(rows)
  let formWidth = min(width, 70)
  let pad = max(0, (width - formWidth) div 2)

  vbox(
    hbox(
      spacer(pad).withWidth(fixed(pad)),
      border(form, bsRounded, "Setup",
        titleStyle = style(clBrightCyan).bold(),
      ).withWidth(fixed(formWidth)),
      spacer(0),
    ),
    keyHelpBar([
      kh("Tab", "Next field"), kh("S-Tab", "Prev field"),
      kh("Enter", "Connect"), kh("^C", "Quit"),
    ]),
  )

# ============================================================
# Rendering: Server list screen
# ============================================================

const
  AddLabels = ["Name:      ", "Host:      ", "Port:      ", "Channels:  ", "Password:  ",
               "TLS:       ", "SASL User: ", "SASL Pass: "]
  AddFieldCount = 8

proc renderServerList(ms: MasterState, width, height: int): Widget =
  var rows: seq[Widget] = @[]
  var helpBar: Widget

  rows.add(spacer(1))
  rows.add(text("  CPS IRC Client", style(clBrightCyan).bold()))
  rows.add(spacer(1))

  if ms.addServerMode or ms.editServerMode:
    # Add/edit server form
    let formTitle = if ms.editServerMode: "  Edit Server" else: "  Add New Server"
    rows.add(text(formTitle, style(clBrightWhite).bold().underline()))
    rows.add(spacer(1))
    for i in 0 ..< AddFieldCount:
      let labelSt = if i == ms.addFocusIdx: style(clBrightWhite).bold()
                    else: style(clWhite)
      let indicator = if i == ms.addFocusIdx: "> " else: "  "
      ms.addFields[i].focused = (i == ms.addFocusIdx)
      rows.add(
        hbox(
          text(indicator & AddLabels[i], labelSt).withWidth(fixed(14)),
          ms.addFields[i].toWidget(),
        ).withHeight(fixed(1))
         .withOnClick(ms.makeAddFieldClickHandler(i))
      )
    rows.add(spacer(1))
    let enterLabel = if ms.editServerMode: "Save" else: "Save & Connect"
    helpBar = keyHelpBar([
      kh("Tab", "Next"), kh("S-Tab", "Prev"),
      kh("Enter", enterLabel), kh("Esc", "Cancel"),
    ])
  else:
    # Server list
    rows.add(text("  Select a server:", style(clBrightWhite).bold()))
    rows.add(spacer(1))

    if ms.config.servers.len == 0:
      rows.add(text("  (no saved servers)", style(clBrightBlack).italic()))
      rows.add(spacer(1))
    else:
      for i, s in ms.config.servers:
        let selected = (i == ms.serverListIdx)
        let indicator = if selected: " > " else: "   "
        let nameSt = if selected: style(clBrightWhite, clBlue).bold()
                     else: style(clBrightWhite)
        let detailSt = if selected: style(clCyan, clBlue)
                       else: style(clBrightBlack)
        let chanStr = if s.channels.len > 0: "  " & s.channels.join(", ") else: ""
        let tlsStr = if s.useTls: " [TLS]" else: ""
        let saslStr = if s.saslUsername.len > 0: " [SASL]" else: ""
        rows.add(
          vbox(
            text(indicator & s.name, nameSt),
            text("   " & s.host & ":" & $s.port & tlsStr & saslStr & chanStr, detailSt),
            spacer(1),
          ).withHeight(fixed(3))
           .withOnClick(ms.makeServerClickHandler(i))
        )

    helpBar = keyHelpBar([
      kh("Up/Down", "Select"), kh("Enter", "Connect"),
      kh("a", "Add"), kh("e", "Edit"), kh("d", "Delete"), kh("^C", "Quit"),
    ])

  let form = vbox(rows)
  let formWidth = min(width, 60)
  let pad = max(0, (width - formWidth) div 2)

  vbox(
    hbox(
      spacer(pad).withWidth(fixed(pad)),
      border(form, bsRounded, "Servers",
        titleStyle = style(clBrightCyan).bold(),
      ).withWidth(fixed(formWidth)),
      spacer(0),
    ),
    helpBar,
  )

# ============================================================
# Rendering: Chat screen
# ============================================================

proc renderChannelList(ms: MasterState, cs: IrcChatState, width, height: int, theme: Theme): Widget =
  var items: seq[ListItem] = @[]
  let innerW = max(0, width - 2)  # account for border
  let channelCount = cs.channels.len
  let closeXThreshold = innerW - 4  # x threshold for close button click
  for i, ch in cs.channels:
    let indicator = if i == cs.activeChannel: ">" else: " "
    let badge = if ch.mentions > 0: " @" & $ch.mentions
                elif ch.unread > 0: " (" & $ch.unread & ")"
                else: ""
    let closable = ch.name != ServerChannel
    let left = indicator & " " & ch.name & badge
    # Right-align [x] close button
    let label = if closable:
      let pad = max(1, innerW - left.len - 3)  # 3 for "[x]"
      left & spaces(pad) & "[x]"
    else:
      left
    let st = if i == cs.activeChannel: theme.chanActive
             elif ch.mentions > 0: theme.chanMention
             elif ch.unread > 0: theme.chanUnread
             else: theme.chanNormal
    items.add(listItem(label, st = st))
  # Transfers section
  let dm = cs.dccManager
  var transferStartIdx = -1
  if dm != nil and (dm.pendingOffers.len > 0 or dm.activeTransfers.len > 0 or dm.completedTransfers.len > 0):
    items.add(listItem(""))  # spacer
    items.add(listItem(" Transfers", st = theme.chanActive.bold()))
    transferStartIdx = channelCount + 2
    let maxW = max(0, width - 8)
    for t in dm.pendingOffers:
      let fname = if t.info.filename.len > maxW: t.info.filename[0 ..< max(0, maxW - 3)] & "..." else: t.info.filename
      items.add(listItem("  ? " & fname, st = style(clBrightYellow)))
    for t in dm.activeTransfers:
      let pct = if t.totalBytes > 0: int(t.bytesReceived * 100 div t.totalBytes) else: 0
      let maxWa = max(0, width - 12)
      let fname = if t.info.filename.len > maxWa: t.info.filename[0 ..< max(0, maxWa - 3)] & "..." else: t.info.filename
      items.add(listItem("  " & $pct & "% " & fname, st = style(clBrightCyan)))
    for t in dm.completedTransfers:
      let fname = if t.info.filename.len > maxW: t.info.filename[0 ..< max(0, maxW - 3)] & "..." else: t.info.filename
      items.add(listItem("  + " & fname, st = style(clBrightGreen)))
  let csRef = cs
  let msRef = ms
  let closeX = closeXThreshold
  let tStartIdx = transferStartIdx
  list(items, selected = cs.activeChannel,
       highlightStyle = style(clBlack, clCyan))
    .withOnClick(proc(mx, my: int) =
      # Channel item click
      if my >= 0 and my < channelCount:
        if mx >= closeX and csRef.channels[my].name != ServerChannel:
          # Close button clicked
          let chName = csRef.channels[my].name
          if chName.isChannel():
            discard csRef.client.partChannel(chName)
          csRef.removeChannel(chName)
        else:
          csRef.switchChannel(my)
      # Transfer item click
      elif tStartIdx >= 0 and my >= tStartIdx and csRef.dccManager != nil:
        let transferIdx = my - tStartIdx
        if transferIdx >= 0 and transferIdx < csRef.dccManager.pendingOffers.len:
          msRef.dccConfirm = DccConfirm(active: true, transfer: csRef.dccManager.pendingOffers[transferIdx])
    )

proc renderChat(ms: MasterState, width, height: int): Widget =
  let cs = ms.chat
  if cs.channels.len == 0:
    return text("No channels", style(clBrightRed))
  if cs.activeChannel >= cs.channels.len:
    cs.activeChannel = max(0, cs.channels.len - 1)
  let ch = cs.channels[cs.activeChannel]

  # Status bar
  let stateStr = case cs.client.state
    of icsDisconnected: " [disconnected] "
    of icsConnecting: " [connecting...] "
    of icsRegistering: " [registering...] "
    of icsConnected: ""
  let topicStr = if ch.topic.len > 0: " " & ch.topic & " " else: ""
  let userStr = if ch.users.len > 0: " " & $ch.users.len & " users " else: ""

  # Lag indicator
  let lagStr = if cs.client.lagMs >= 0:
    let lag = cs.client.lagMs
    " lag:" & $lag & "ms "
  else: ""
  let lagSt = if cs.client.lagMs < 0: ms.theme.statusBg
              elif cs.client.lagMs < 200: ms.theme.lagGood.bg(clCyan)
              elif cs.client.lagMs < 500: ms.theme.lagWarn.bg(clCyan)
              else: ms.theme.lagBad.bg(clCyan)

  # Away indicator
  let awayStr = if cs.isAway: " [AWAY] " else: ""

  cs.statusBar.items = @[
    statusItem(" " & ch.name & " ", taLeft, ms.theme.statusBold),
    statusItem(stateStr, taLeft, style(clBlack, clYellow).bold()),
    statusItem(awayStr, taLeft, ms.theme.awayIndicator.bg(clCyan)),
    statusItem(topicStr, taLeft, ms.theme.statusBg),
    statusItem(lagStr, taRight, lagSt),
    statusItem(userStr, taRight, ms.theme.statusBg),
  ]

  # Tab bar
  var tabItems: seq[TabItem] = @[]
  for i, c in cs.channels:
    let label = if c.mentions > 0: c.name & " @" & $c.mentions
                elif c.unread > 0: c.name & "(" & $c.unread & ")"
                else: c.name
    tabItems.add(tabItem(label, active = (i == cs.activeChannel)))

  # Compute actual sidebar width for channel list rendering
  let usable = max(0, width - 1)
  let sidebarW = cs.splitView.computeFirstSize(usable)
  let channelList = border(
    ms.renderChannelList(cs, sidebarW, height, ms.theme),
    bsSingle, "Channels",
    titleStyle = ms.theme.inputPrompt.bold(),
  )

  # Build autocomplete popup widget (shown between messages and status bar)
  let nc = ms.nickComplete
  var chatChildren: seq[Widget] = @[]
  let csRefTabs = cs
  chatChildren.add(interactiveTabs(tabItems,
    onSwitch = proc(idx: int) =
      if idx >= 0 and idx < csRefTabs.channels.len:
        csRefTabs.switchChannel(idx),
    tabSt = style(clWhite, clBrightBlack),
    activeSt = style(clBlack, clCyan).bold(),
  ))
  let msRefSelect = ms
  chatChildren.add(ch.messages.toWidgetWithEvents(
    onSelect = proc(text: string) =
      msRefSelect.clipboardText = text
      writeOsc52(text)
      msRefSelect.notifications.notify("Copied to clipboard", nlSuccess, 2.0)
  ))
  if nc.active and nc.matches.len > 0:
    let matches = nc.matches
    let sel = nc.selected
    let visibleCount = min(matches.len, 8)
    var rows: seq[Widget] = @[]
    for i in 0 ..< visibleCount:
      let isSelected = (i == sel)
      let st = if isSelected: style(clBlack, clCyan).bold()
               else: style(clWhite, clBrightBlack)
      let prefix = if isSelected: "> " else: "  "
      rows.add(text(prefix & matches[i], st))
    let msRefNc = ms
    let ncVisCount = visibleCount
    chatChildren.add(
      border(vbox(rows), bsSingle, "@mention",
        titleStyle = style(clBrightCyan),
      ).withHeight(fixed(visibleCount + 2))
       .withFocusTrap(true)
       .withFocus(true)
       .withOnClick(proc(mx, my: int) =
         # my is relative to the border widget: 0=top border, 1..n=items
         let itemIdx = my - 1  # Subtract top border row
         if itemIdx >= 0 and itemIdx < ncVisCount:
           msRefNc.nickComplete.selected = itemIdx
           msRefNc.acceptComplete()
       )
       .withOnKey(proc(evt: InputEvent): bool =
         if evt.isKey(kcEscape):
           msRefNc.dismissComplete()
           return true
         if evt.isKey(kcUp):
           if msRefNc.nickComplete.selected > 0:
             msRefNc.nickComplete.selected -= 1
           else:
             msRefNc.nickComplete.selected = msRefNc.nickComplete.matches.len - 1
           return true
         if evt.isKey(kcDown):
           if msRefNc.nickComplete.selected < msRefNc.nickComplete.matches.len - 1:
             msRefNc.nickComplete.selected += 1
           else:
             msRefNc.nickComplete.selected = 0
           return true
         if evt.isKey(kcTab) or evt.isKey(kcEnter):
           msRefNc.acceptComplete()
           return true
         false  # Let other keys through to the input field
       )
    )
  # Search bar (declarative event handling via focusTrap + onKey)
  if ms.search.active:
    let matchInfo = if ms.search.matchLines.len > 0:
      " [" & $(ms.search.currentMatch + 1) & "/" & $ms.search.matchLines.len & "]"
    else: " [no matches]"
    let msRefSearch = ms
    chatChildren.add(
      hbox(
        label("Search: ", ms.theme.inputPrompt).withWidth(autoSize()),
        ms.search.input.toWidget(),
        label(matchInfo, style(clBrightBlack)).withWidth(autoSize()),
      ).withHeight(fixed(1))
       .withFocusTrap(true)
       .withFocus(true)
       .withOnKey(proc(evt: InputEvent): bool =
         if evt.isKey(kcEscape):
           msRefSearch.dismissSearch()
           return true
         if evt.isKey(kcEnter):
           msRefSearch.dismissSearch()
           return true
         if evt.isCtrl('n'):
           msRefSearch.searchNext()
           return true
         if evt.isCtrl('p'):
           msRefSearch.searchPrev()
           return true
         let oldText = msRefSearch.search.input.text
         let handled = msRefSearch.search.input.handleInput(evt)
         if handled and msRefSearch.search.input.text != oldText:
           msRefSearch.search.query = msRefSearch.search.input.text
           msRefSearch.updateSearchMatches()
         return handled
       )
    )

  # Paste confirmation dialog (declarative event handling)
  if ms.pasteConfirm.active:
    let lineCount = ms.pasteConfirm.lines.len
    var previewRows: seq[Widget] = @[]
    previewRows.add(text("Paste " & $lineCount & " lines?", style(clBrightYellow).bold()))
    previewRows.add(spacer(1))
    for i, line in ms.pasteConfirm.preview:
      let prefix = if i == ms.pasteConfirm.preview.len - 1 and lineCount > ms.pasteConfirm.preview.len:
                     "  ... (" & $(lineCount - ms.pasteConfirm.preview.len) & " more)"
                   else:
                     "  " & line
      previewRows.add(text(prefix, style(clBrightBlack)))
    previewRows.add(spacer(1))
    previewRows.add(text("  [Y] Send  [N] Cancel", style(clBrightWhite)))
    let msRef = ms
    let csRef2 = cs
    let pasteLines = ms.pasteConfirm.lines
    chatChildren.add(
      border(vbox(previewRows), bsRounded, "Paste Confirm",
        titleStyle = style(clBrightYellow).bold(),
      ).withHeight(fixed(min(lineCount + 6, 12)))
       .withFocusTrap(true)
       .withOnKey(proc(evt: InputEvent): bool =
         if evt.kind == iekKey and evt.key == kcChar:
           case evt.ch
           of 'y', 'Y':
             let chName = csRef2.currentChannel.name
             if chName != ServerChannel:
               for line in pasteLines:
                 if line.len > 0:
                   discard csRef2.client.privMsg(chName, line)
                   csRef2.addMsg(chName, csRef2.myNick, line)
             else:
               csRef2.addError(chName, "Cannot paste to server console")
             msRef.pasteConfirm = PasteConfirm()
             return true
           of 'n', 'N':
             msRef.pasteConfirm = PasteConfirm()
             return true
           else:
             return true
         if evt.kind == iekKey and evt.key == kcEscape:
           msRef.pasteConfirm = PasteConfirm()
           return true
         return true  # Trap all keys
       ).withFocus(true)
    )

  # DCC transfer confirmation dialog (declarative event handling)
  if ms.dccConfirm.active:
    let t = ms.dccConfirm.transfer
    let sizeStr = if t.info.filesize > 0: formatSize(t.info.filesize) else: "unknown"
    var rows: seq[Widget] = @[]
    rows.add(text("DCC SEND from " & t.source, style(clBrightYellow).bold()))
    rows.add(spacer(1))
    rows.add(text("  File: " & t.info.filename, style(clBrightWhite)))
    rows.add(text("  Size: " & sizeStr, style(clBrightWhite)))
    rows.add(text("  From: " & longIpToString(t.info.ip) & ":" & $t.info.port, style(clBrightWhite)))
    rows.add(text("  Save: " & t.outputPath, style(clBrightWhite)))
    rows.add(spacer(1))
    rows.add(text("  [Y] Accept  [N] Decline", style(clBrightWhite)))
    let msRef2 = ms
    let csRef3 = cs
    let dccTransfer = t
    chatChildren.add(
      border(vbox(rows), bsRounded, "DCC Transfer",
        titleStyle = style(clBrightYellow).bold(),
      ).withHeight(fixed(10))
       .withFocusTrap(true)
       .withOnKey(proc(evt: InputEvent): bool =
         if evt.kind == iekKey and evt.key == kcChar:
           case evt.ch
           of 'y', 'Y':
             let fut = csRef3.dccManager.acceptOffer(dccTransfer)
             fut.addCallback(proc() = discard)
             csRef3.addServerMsg("Accepting: " & dccTransfer.info.filename & " from " & dccTransfer.source)
             msRef2.dccConfirm = DccConfirm()
             return true
           of 'n', 'N':
             for i in countdown(csRef3.dccManager.pendingOffers.len - 1, 0):
               if csRef3.dccManager.pendingOffers[i] == dccTransfer:
                 csRef3.dccManager.pendingOffers.delete(i)
                 break
             csRef3.addServerMsg("Declined: " & dccTransfer.info.filename & " from " & dccTransfer.source)
             msRef2.dccConfirm = DccConfirm()
             return true
           else:
             return true
         if evt.kind == iekKey and evt.key == kcEscape:
           msRef2.dccConfirm = DccConfirm()
           return true
         return true  # Trap all keys
       ).withFocus(true)
    )

  chatChildren.add(cs.statusBar.toWidget())

  # Dynamic input height: wrap long input text across multiple rows
  let promptText = ch.name & "> "
  let inputWidth = max(1, width - promptText.len - 2)  # account for split view margins
  let inputRows = max(1, (ms.inputField.text.len + inputWidth - 1) div inputWidth)
  let cappedRows = min(inputRows, max(1, height div 4))  # cap at 25% of screen height
  let inputFieldRef = ms.inputField
  chatChildren.add(
    hbox(
      label(promptText, ms.theme.inputPrompt).withWidth(autoSize()),
      ms.inputField.toWidget()
        .withOnClick(proc(mx, my: int) =
          let newCursor = min(mx, inputFieldRef.text.len)
          if newCursor != inputFieldRef.cursor:
            inputFieldRef.cursor = newCursor
        ),
    ).withHeight(fixed(cappedRows))
  )

  # Server tabs (when multi-server)
  var helpItems = [
    kh("^C", "Quit"), kh("Tab", "Complete"), kh("A-Left/Right", "Chan"),
    kh("^F", "Search"), kh("^K", "Switch"), kh("^O", "URL"), kh("^Y", "Copy"),
  ]
  if ms.chats.len > 1:
    # Show server tabs before key help
    var serverTabs: seq[TabItem] = @[]
    for i, chat in ms.chats:
      let totalUnread = block:
        var u = 0
        for c in chat.channels:
          u += c.unread
        u
      let lbl = if totalUnread > 0: chat.serverLabel & "(" & $totalUnread & ")"
                else: chat.serverLabel
      serverTabs.add(tabItem(lbl, active = (i == ms.activeChat)))
    let msRef3 = ms
    chatChildren.add(interactiveTabs(serverTabs,
      onSwitch = proc(idx: int) =
        if idx >= 0 and idx < msRef3.chats.len:
          msRef3.switchChat(idx),
      tabSt = style(clWhite, clBlack),
      activeSt = style(clBrightWhite, clBlue).bold(),
    ))

  chatChildren.add(keyHelpBar(helpItems))

  let chatArea = vbox(chatChildren)
  let msRefSv = ms
  cs.splitView.toWidgetWithEvents(channelList, chatArea)
    .withOnMouse(proc(evt: InputEvent): bool =
      # Handle divider drag and trigger full redraw on ratio change
      let changed = cs.splitView.handleMouse(evt, cs.splitView.lastRect)
      if changed or cs.splitView.dragging:
        msRefSv.tuiApp.fullRedraw = true
      changed
    )

# ============================================================
# Master render
# ============================================================

proc renderQuickSwitcher(ms: MasterState, width, height: int): Widget =
  if not ms.quickSwitcher.active: return spacer(0)
  let qs = ms.quickSwitcher
  var rows: seq[Widget] = @[]
  rows.add(
    hbox(
      label("Channel: ", ms.theme.inputPrompt).withWidth(autoSize()),
      qs.input.toWidget(),
    ).withHeight(fixed(1))
  )
  let visibleCount = min(qs.filtered.len, 10)
  for i in 0 ..< visibleCount:
    let isSelected = (i == qs.selected)
    let st = if isSelected: style(clBlack, clCyan).bold()
             else: style(clWhite)
    let prefix = if isSelected: "> " else: "  "
    rows.add(text(prefix & qs.filtered[i].name, st))
  let body = vbox(rows)
  let dw = min(width - 4, 50)
  let dh = visibleCount + 3  # input + items + border
  let dx = (width - dw) div 2
  let dy = max(1, (height - dh) div 3)
  # Capture full screen dimensions for the overlay
  let fullW = width
  let fullH = height
  let msRefQs = ms
  let csRefQs = ms.chat
  custom(proc(buf: var CellBuffer, rect: Rect) =
    # Semi-transparent dim overlay across the full screen
    for y in 0 ..< fullH:
      for x in 0 ..< fullW:
        let cell = buf[x, y]
        buf.setCell(x, y, cell.ch, cell.style.dim())
    # Draw popup background
    buf.fill(dx, dy, dw, dh, " ", styleDefault)
    # Draw border
    let bc = borderChars(bsRounded)
    buf.setCell(dx, dy, bc.topLeft, ms.theme.inputPrompt)
    for x in dx + 1 ..< dx + dw - 1:
      buf.setCell(x, dy, bc.horizontal, ms.theme.inputPrompt)
    buf.setCell(dx + dw - 1, dy, bc.topRight, ms.theme.inputPrompt)
    for y in dy + 1 ..< dy + dh - 1:
      buf.setCell(dx, y, bc.vertical, ms.theme.inputPrompt)
      buf.setCell(dx + dw - 1, y, bc.vertical, ms.theme.inputPrompt)
    buf.setCell(dx, dy + dh - 1, bc.bottomLeft, ms.theme.inputPrompt)
    for x in dx + 1 ..< dx + dw - 1:
      buf.setCell(x, dy + dh - 1, bc.horizontal, ms.theme.inputPrompt)
    buf.setCell(dx + dw - 1, dy + dh - 1, bc.bottomRight, ms.theme.inputPrompt)
    # Title
    buf.writeStr(dx + 2, dy, " Quick Switch ", ms.theme.inputPrompt.bold())
    # Render body inside
    renderWidget(buf, body, Rect(x: dx + 1, y: dy + 1, w: dw - 2, h: dh - 2))
  ).withFocusTrap(true)
   .withFocus(true)
   .withOnKey(proc(evt: InputEvent): bool =
     if evt.isKey(kcEscape):
       msRefQs.dismissQuickSwitcher()
       return true
     if evt.isKey(kcEnter):
       if msRefQs.quickSwitcher.filtered.len > 0 and
          msRefQs.quickSwitcher.selected < msRefQs.quickSwitcher.filtered.len:
         let idx = msRefQs.quickSwitcher.filtered[msRefQs.quickSwitcher.selected].idx
         csRefQs.switchChannel(idx)
       msRefQs.dismissQuickSwitcher()
       return true
     if evt.isKey(kcUp):
       if msRefQs.quickSwitcher.selected > 0:
         msRefQs.quickSwitcher.selected -= 1
       return true
     if evt.isKey(kcDown):
       if msRefQs.quickSwitcher.selected < msRefQs.quickSwitcher.filtered.len - 1:
         msRefQs.quickSwitcher.selected += 1
       return true
     let oldText = msRefQs.quickSwitcher.input.text
     let handled = msRefQs.quickSwitcher.input.handleInput(evt)
     if handled and msRefQs.quickSwitcher.input.text != oldText:
       msRefQs.updateQuickSwitcher()
     return handled
   )

proc renderMaster(ms: MasterState, width, height: int): Widget =
  let baseMain = case ms.screen
    of asLoading: ms.renderLoading(width, height)
    of asSetup: ms.renderSetup(width, height)
    of asServerList: ms.renderServerList(width, height)
    of asChat: ms.renderChat(width, height)

  # Overlay notifications on top of the main content (top-right corner)
  let notifCount = min(ms.notifications.maxVisible, ms.notifications.notifications.len)
  let notifWidget = ms.notifications.toWidget()
  let mainRef = baseMain
  let notifRef = notifWidget
  let notifH = notifCount + 2  # +2 for border top/bottom
  let main = if notifCount > 0:
    var overlay = custom(proc(buf: var CellBuffer, rect: Rect) =
      renderWidget(buf, mainRef, rect)
      # Render notifications in the top-right corner
      let nw = min(52, rect.w div 2)  # Max width including border
      if nw > 0:
        let nx = rect.x + rect.w - nw - 1
        let ny = rect.y + 1
        renderWidget(buf, notifRef, Rect(x: nx, y: ny, w: nw, h: notifH))
    )
    overlay.customChildren = @[mainRef]
    overlay.customChildRects = @[Rect(x: 0, y: 0, w: width, h: height)]
    overlay
  else:
    baseMain

  if ms.helpDialog.visible:
    # Help dialog is a custom overlay — render main first, then overlay on top
    let helpWidget = ms.helpDialog.toWidget(width, height)
    let msRefHelp = ms
    var overlay = custom(proc(buf: var CellBuffer, rect: Rect) =
      renderWidget(buf, main, rect)
      renderWidget(buf, helpWidget, rect)
    )
    overlay.customChildren = @[main]
    overlay.customChildRects = @[Rect(x: 0, y: 0, w: width, h: height)]
    overlay.withFocusTrap(true)
     .withFocus(true)
     .withOnKey(proc(evt: InputEvent): bool =
       if evt.isKey(kcEscape) or evt.isKey(kcF1):
         msRefHelp.helpDialog.hide()
         return true
       return true  # Trap all keys when help is visible
     )
  elif ms.quickSwitcher.active:
    # Quick switcher is a custom overlay — render main first, then overlay on top
    let qsWidget = ms.renderQuickSwitcher(width, height)
    var overlay = custom(proc(buf: var CellBuffer, rect: Rect) =
      renderWidget(buf, main, rect)
      renderWidget(buf, qsWidget, rect)
    )
    # Register both main and qsWidget as custom children for event routing.
    # qsWidget has withFocusTrap + withOnKey; main has channel list handlers etc.
    overlay.customChildren = @[main, qsWidget]
    overlay.customChildRects = @[Rect(x: 0, y: 0, w: width, h: height),
                                  Rect(x: 0, y: 0, w: width, h: height)]
    overlay
  else:
    main

# ============================================================
# Input: Setup screen
# ============================================================

proc handleSetupInput(ms: MasterState, evt: InputEvent): bool =
  if evt.isKey(kcTab) or (evt.isKey(kcDown) and ms.setupFocusIdx < SetupFieldCount - 1):
    ms.setupFocusIdx = (ms.setupFocusIdx + 1) mod SetupFieldCount
    return true
  if evt.isKeyMod(kcTab, {kmShift}) or (evt.isKey(kcUp) and ms.setupFocusIdx > 0):
    ms.setupFocusIdx = (ms.setupFocusIdx + SetupFieldCount - 1) mod SetupFieldCount
    return true
  if evt.isKey(kcEnter):
    # Validate and connect
    let nick = ms.setupFields[sfNick].text.strip()
    let host = ms.setupFields[sfHost].text.strip()
    if nick.len == 0:
      ms.setupError = "Nickname is required"
      ms.setupFocusIdx = sfNick
      return true
    if host.len == 0:
      ms.setupError = "Host is required"
      ms.setupFocusIdx = sfHost
      return true
    # Build config
    ms.config.profile.nick = nick
    ms.config.profile.username = ms.setupFields[sfUsername].text.strip()
    if ms.config.profile.username.len == 0:
      ms.config.profile.username = nick
    ms.config.profile.realname = ms.setupFields[sfRealname].text.strip()
    if ms.config.profile.realname.len == 0:
      ms.config.profile.realname = nick
    let serverName = ms.setupFields[sfServerName].text.strip()
    let port = try: parseInt(ms.setupFields[sfPort].text.strip()) except: 6667
    let channels = ms.setupFields[sfChannels].text.strip().split(',').filterIt(it.strip().len > 0)
    let tlsText = ms.setupFields[sfTls].text.strip().toLowerAscii
    let useTls = tlsText in ["yes", "true", "1", "y"]
    let server = ServerEntry(
      name: if serverName.len > 0: serverName else: host,
      host: host,
      port: port,
      channels: channels,
      password: ms.setupFields[sfPassword].text,
      useTls: useTls,
      saslUsername: ms.setupFields[sfSaslUser].text.strip(),
      saslPassword: ms.setupFields[sfSaslPass].text,
    )
    ms.config.servers.add(server)
    saveConfig(ms.config)
    ms.connectToServer(server)
    return true
  # Route to focused field
  return ms.setupFields[ms.setupFocusIdx].handleInput(evt)

# ============================================================
# Input: Server list screen
# ============================================================

proc buildServerFromFields(ms: MasterState): ServerEntry =
  ## Build a ServerEntry from the add/edit form fields.
  let name = ms.addFields[0].text.strip()
  let host = ms.addFields[1].text.strip()
  let port = try: parseInt(ms.addFields[2].text.strip()) except: 6667
  let channels = ms.addFields[3].text.strip().split(',').filterIt(it.strip().len > 0)
  let tlsText = ms.addFields[5].text.strip().toLowerAscii
  let useTls = tlsText in ["yes", "true", "1", "y"]
  ServerEntry(
    name: if name.len > 0: name else: host,
    host: host,
    port: port,
    channels: channels,
    password: ms.addFields[4].text,
    useTls: useTls,
    saslUsername: ms.addFields[6].text.strip(),
    saslPassword: ms.addFields[7].text,
  )

proc handleServerListInput(ms: MasterState, evt: InputEvent): bool =
  if ms.addServerMode or ms.editServerMode:
    # Add/edit server form
    if evt.isKey(kcEscape):
      ms.addServerMode = false
      ms.editServerMode = false
      return true
    if evt.isKey(kcTab) or evt.isKey(kcDown):
      ms.addFocusIdx = (ms.addFocusIdx + 1) mod AddFieldCount
      return true
    if evt.isKeyMod(kcTab, {kmShift}) or evt.isKey(kcUp):
      ms.addFocusIdx = (ms.addFocusIdx + AddFieldCount - 1) mod AddFieldCount
      return true
    if evt.isKey(kcEnter):
      let host = ms.addFields[1].text.strip()
      if host.len == 0:
        ms.notifications.notify("Host is required", nlError)
        return true
      let server = ms.buildServerFromFields()
      if ms.editServerMode:
        # Update existing server
        ms.config.servers[ms.editServerIdx] = server
        saveConfig(ms.config)
        ms.editServerMode = false
        ms.notifications.notify("Updated: " & server.name, nlSuccess)
      else:
        # Add new server
        ms.config.servers.add(server)
        saveConfig(ms.config)
        ms.addServerMode = false
        ms.connectToServer(server)
      return true
    return ms.addFields[ms.addFocusIdx].handleInput(evt)
  else:
    # Server list navigation
    if evt.isKey(kcUp):
      if ms.serverListIdx > 0:
        ms.serverListIdx -= 1
      return true
    if evt.isKey(kcDown):
      if ms.serverListIdx < ms.config.servers.len - 1:
        ms.serverListIdx += 1
      return true
    if evt.isKey(kcEnter):
      if ms.config.servers.len > 0 and ms.serverListIdx < ms.config.servers.len:
        ms.connectToServer(ms.config.servers[ms.serverListIdx])
      return true
    if evt.kind == iekKey and evt.key == kcChar:
      case evt.ch
      of 'a', 'A':
        ms.addServerMode = true
        ms.initAddFields()
        return true
      of 'e', 'E':
        if ms.config.servers.len > 0 and ms.serverListIdx < ms.config.servers.len:
          ms.initEditFields(ms.serverListIdx)
          return true
      of 'd', 'D':
        if ms.config.servers.len > 0 and ms.serverListIdx < ms.config.servers.len:
          let name = ms.config.servers[ms.serverListIdx].name
          ms.config.servers.delete(ms.serverListIdx)
          if ms.serverListIdx >= ms.config.servers.len:
            ms.serverListIdx = max(0, ms.config.servers.len - 1)
          saveConfig(ms.config)
          ms.notifications.notify("Removed: " & name, nlInfo)
          return true
      else:
        discard
    # Mouse: click on server
    if evt.kind == iekMouse and evt.action == maPress and evt.button == mbLeft:
      # Simple heuristic: each server takes ~3 rows, offset from top
      discard
    return false

# ============================================================
# Input: Chat screen
# ============================================================

proc handleChatInput(ms: MasterState, evt: InputEvent): bool =
  let cs = ms.chat

  # DCC and paste confirmation dialogs are now handled declaratively via
  # withOnKey + withFocusTrap in the render functions (renderChat).
  # The framework's event routing handles their input automatically.

  # Handle paste events from bracketed paste
  if evt.kind == iekPaste:
    let pasteText = evt.pasteText
    if pasteText.len > 0:
      let lines = pasteText.split('\n')
      # Filter out empty trailing lines from the paste
      var cleanLines: seq[string] = @[]
      for line in lines:
        let stripped = line.strip(chars = {'\r'})
        cleanLines.add(stripped)
      # Remove trailing empty lines
      while cleanLines.len > 0 and cleanLines[^1].len == 0:
        cleanLines.setLen(cleanLines.len - 1)
      if cleanLines.len == 0:
        discard
      elif cleanLines.len == 1:
        # Single line: insert directly into input
        ms.inputField.insertStr(cleanLines[0])
      else:
        # Multi-line: show confirmation
        const maxPreview = 5
        let preview = if cleanLines.len <= maxPreview: cleanLines
                      else: cleanLines[0 ..< maxPreview]
        ms.pasteConfirm = PasteConfirm(
          active: true,
          lines: cleanLines,
          preview: preview,
        )
    return true

  # Help dialog, quick-switcher, and search are now handled declaratively via
  # withFocusTrap + withOnKey in renderMaster, renderQuickSwitcher, and renderChat.
  # The framework's event routing handles their input automatically.

  # @-mention autocomplete navigation is now handled declaratively via
  # withFocusTrap + withOnKey on the popup widget in renderChat.

  # Ctrl+Y: copy selected text to clipboard
  if evt.isCtrl('y'):
    let msgView = cs.currentChannel.messages
    if msgView.hasSelection:
      let selected = msgView.getSelectedText()
      if selected.len > 0:
        ms.clipboardText = selected
        writeOsc52(selected)
        ms.notifications.notify("Copied to clipboard", nlSuccess, 2.0)
    else:
      ms.notifications.notify("No text selected (drag to select)", nlWarning)
    return true

  # Ctrl+F: search
  if evt.isCtrl('f'):
    ms.startSearch()
    return true
  # Ctrl+K: quick-switcher
  if evt.isCtrl('k'):
    ms.openQuickSwitcher()
    return true
  # Ctrl+Left/Right: switch between servers (multi-server)
  if ms.chats.len > 1:
    if evt.isKeyMod(kcLeft, {kmCtrl}):
      ms.prevChat()
      return true
    if evt.isKeyMod(kcRight, {kmCtrl}):
      ms.nextChat()
      return true

  if evt.isKey(kcF1):
    ms.helpDialog.toggle()
    return true

  # Tab: if @-mention not active and no @-trigger, do traditional tab-complete
  if evt.isKey(kcTab):
    if ms.nickComplete.active:
      ms.acceptComplete()
      return true
    # Check for @-trigger
    let inputText = ms.inputField.text
    let cursor = ms.inputField.cursor
    var hasAt = false
    for i in countdown(cursor - 1, 0):
      if inputText[i] == '@':
        hasAt = true; break
      if inputText[i] == ' ': break
    if hasAt:
      ms.updateComplete()
      if ms.nickComplete.active:
        ms.acceptComplete()
      return true
    # Traditional tab-complete
    ms.doTabComplete()
    return true

  if evt.isKeyMod(kcTab, {kmShift}):
    cs.prevChannel()
    return true
  # Alt+Right / Alt+Left for channel switching
  if evt.isKeyMod(kcRight, {kmAlt}):
    cs.nextChannel()
    return true
  if evt.isKeyMod(kcLeft, {kmAlt}):
    cs.prevChannel()
    return true
  # Ctrl+O: open URLs from current message view
  if evt.isCtrl('o'):
    let ch = cs.channels[cs.activeChannel]
    # Find the most recent line with a URL
    for i in countdown(ch.messages.lines.len - 1, max(0, ch.messages.lines.len - 50)):
      let urls = findUrls(ch.messages.lines[i].text)
      if urls.len > 0:
        let url = ch.messages.lines[i].text[urls[^1].start ..< urls[^1].stop]
        # Open URL using system command
        when defined(macosx):
          discard execShellCmd("open " & url.quoteShell & " &")
        elif defined(linux):
          discard execShellCmd("xdg-open " & url.quoteShell & " &")
        ms.notifications.notify("Opening: " & url, nlInfo)
        return true
    ms.notifications.notify("No URLs found in recent messages", nlWarning)
    return true
  if evt.isKey(kcPageUp):
    cs.currentChannel.messages.pageUp(10)
    return true
  if evt.isKey(kcPageDown):
    cs.currentChannel.messages.pageDown(10)
    return true
  if evt.isKey(kcEnter):
    ms.dismissComplete()
    ms.resetTabComplete()
    ms.handleChatSend()
    return true

  # Mouse — clicks are now handled declaratively via onClick/onMouse handlers on
  # widgets (channel list, tab bar, message view, split view, input field).
  # Clipboard copy is handled via ScrollableTextView's onSelect callback.

  # Text input
  let oldText = ms.inputField.text
  let handled = ms.inputField.handleInput(evt)
  if handled:
    ms.resetTabComplete()  # Reset tab-complete on any non-tab keypress
    if ms.inputField.text != oldText:
      ms.updateComplete()  # Update @-mention autocomplete on text change
  return handled

# ============================================================
# Master input handler
# ============================================================

proc handleMasterInput(ms: MasterState, evt: InputEvent): bool =
  # Global: Ctrl+C quits from any screen
  if evt.isCtrl('c'):
    for cs in ms.chats:
      if cs.client != nil:
        discard cs.client.disconnect()
    ms.running = false
    ms.tuiApp.stop()
    return false

  case ms.screen
  of asLoading:
    return false
  of asSetup:
    return ms.handleSetupInput(evt)
  of asServerList:
    return ms.handleServerListInput(evt)
  of asChat:
    return ms.handleChatInput(evt)

# ============================================================
# Master tick handler
# ============================================================

proc handleMasterTick(ms: MasterState): bool =
  var changed = ms.notifications.tick()

  # Check if config finished loading
  if ms.screen == asLoading and not ms.configLoaded and ms.configLoadFut != nil:
    if ms.configLoadFut.finished:
      ms.configLoaded = true
      if ms.configLoadFut.hasError:
        # No config file — show setup
        ms.config = newAppConfig()
        ms.screen = asSetup
        ms.initSetupFields()
      else:
        let data = ms.configLoadFut.read()
        ms.config = parseConfig(data)
        # Apply theme from config
        if ms.config.themeName.len > 0:
          ms.theme = getTheme(ms.config.themeName)
          activeTheme = ms.theme
        # Apply logging config
        if ms.config.loggingEnabled and ms.config.logDir.len > 0:
          logConfig = (true, ms.config.logDir)
        if ms.config.servers.len == 0 or ms.config.profile.nick.len == 0:
          ms.screen = asSetup
          ms.initSetupFields()
          # Pre-fill from partial config
          if ms.config.profile.nick.len > 0:
            ms.setupFields[sfNick].setText(ms.config.profile.nick)
          if ms.config.profile.username.len > 0:
            ms.setupFields[sfUsername].setText(ms.config.profile.username)
          if ms.config.profile.realname.len > 0:
            ms.setupFields[sfRealname].setText(ms.config.profile.realname)
        else:
          ms.screen = asServerList
          ms.serverListIdx = 0
      ms.tuiApp.fullRedraw = true
      changed = true

  # Process IRC events in chat mode (all servers)
  if ms.screen == asChat:
    if ms.processIrcEvents():
      changed = true
    # Periodic lag ping (every 30 seconds) — ping all connected servers
    let now = epochTime()
    if now - ms.lastPingTime > 30.0:
      ms.lastPingTime = now
      for cs in ms.chats:
        if cs.client != nil and cs.client.state == icsConnected:
          discard cs.client.sendPing("lagcheck")

  return changed

# ============================================================
# Help dialog content
# ============================================================

proc buildHelpDialog(): Dialog =
  let helpBody = text(
    "Commands:\n" &
    " /join /part /nick   /msg /query /me\n" &
    " /topic /whois /mode /away /back\n" &
    " /ignore /unignore   /highlight add|rm\n" &
    " /theme dark|light|solarized\n" &
    " /monitor +/-nick    /clear /raw\n" &
    " /server list|add|connect|switch\n" &
    " /disconnect /quit\n" &
    "\n" &
    "Keys:\n" &
    " Tab         Nick complete  ^F  Search\n" &
    " @nick+Tab   @-mention      ^K  Quick switch\n" &
    " S-Tab       Prev channel   ^O  Open URL\n" &
    " A-Left/Right  Switch chan   ^C  Quit\n" &
    " C-Left/Right  Switch server F1  Help\n" &
    " PgUp/PgDn  Scroll   ^N/^P  Search nav\n" &
    " ^Y         Copy selection\n" &
    "\n" &
    "Mouse: click chan/tab, scroll, drag select,\n" &
    "       drag divider to resize",
    style(clBrightWhite),
  ).withWrap(twNone)
  result = newDialog("Help", helpBody, width = 50, height = 24)
  result.visible = false

# ============================================================
# Main
# ============================================================

proc main() =
  let argc = paramCount()

  # Handle --reset: delete config and start fresh
  if argc >= 1 and paramStr(1) in ["--reset", "-reset"]:
    let path = configPath()
    if fileExists(path):
      removeFile(path)
      echo "Config reset: removed " & path
    else:
      echo "No config to reset: " & path & " does not exist"
    # If --reset is the only arg, continue to setup wizard.
    # If there are more args after --reset, treat as error.
    if argc > 1:
      echo "Usage: irc_tui [--reset | host [port] [nick] [channels]]"
      quit(0)
    # Fall through to normal startup (will show setup wizard)

  # Check for direct CLI args (bypass config for quick connect)
  let cliMode = argc >= 1 and paramStr(1) notin ["--reset", "-reset"]

  let tuiApp = newTuiApp()
  tuiApp.altScreen = true
  tuiApp.mouseMode = true
  tuiApp.title = "CPS IRC Client"
  tuiApp.targetFps = 30

  let ms = MasterState(
    screen: asLoading,
    config: newAppConfig(),
    configLoaded: false,
    tuiApp: tuiApp,
    inputField: newTextInput(),
    notifications: newNotificationArea(maxVisible = 3),
    helpDialog: buildHelpDialog(),
    theme: darkTheme(),
    running: true,
    serverListIdx: 0,
    addServerMode: false,
    lastPingTime: epochTime(),
  )
  activeTheme = ms.theme

  if cliMode:
    # Direct connect from CLI args — skip config loading
    let host = paramStr(1)
    let port = if argc >= 2: (try: parseInt(paramStr(2)) except: 6667) else: 6667
    let nick = if argc >= 3: paramStr(3) else: "cps_tui_" & $(epochTime().int mod 10000)
    let channelsArg = if argc >= 4: paramStr(4) else: ""
    let autoJoin = if channelsArg.len > 0:
                     channelsArg.split(',').filterIt(it.len > 0)
                   else: @[]
    ms.configLoaded = true
    ms.config.profile.nick = nick
    ms.config.profile.username = nick
    ms.config.profile.realname = nick
    let server = ServerEntry(
      name: host, host: host, port: port, channels: autoJoin,
    )
    ms.screen = asChat
    ms.connectToServer(server)
  else:
    # Load config via CPS IO async file read
    ms.configLoadFut = asyncReadFile(configPath())

  tuiApp.onRender = proc(width, height: int): Widget =
    renderMaster(ms, width, height)

  tuiApp.onInput = proc(evt: InputEvent): bool =
    handleMasterInput(ms, evt)

  tuiApp.onTick = proc(): bool =
    handleMasterTick(ms)

  runCps(tuiApp.run())

main()
