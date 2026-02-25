## CPS IRC Protocol
##
## IRC message parsing and formatting per RFC 2812.
## Provides types and helpers for the IRC wire protocol.

import std/[strutils, tables, options]

type
  IrcPrefix* = object
    ## Parsed IRC message prefix (source).
    raw*: string
    nick*: string       ## Nickname (empty for server messages)
    user*: string       ## Username (ident)
    host*: string       ## Hostname

  IrcMessage* = object
    ## A parsed IRC protocol message.
    prefix*: IrcPrefix  ## Message source (may be empty)
    command*: string    ## Command or numeric (e.g. "PRIVMSG", "001")
    params*: seq[string]  ## Parameters (last may be trailing)
    raw*: string        ## Original raw line
    tags*: Table[string, string]  ## IRCv3 message tags

  # IRC event types for the event-driven client
  IrcEventKind* = enum
    iekConnected        ## Successfully connected and registered
    iekDisconnected     ## Disconnected from server
    iekMessage          ## Raw IRC message received
    iekPrivMsg          ## PRIVMSG received
    iekNotice           ## NOTICE received
    iekJoin             ## Channel join
    iekPart             ## Channel part
    iekQuit             ## User quit
    iekKick             ## User kicked
    iekNick             ## Nick change
    iekMode             ## Mode change
    iekTopic            ## Topic change
    iekNumeric          ## Numeric reply
    iekCtcp             ## CTCP message (ACTION, VERSION, etc.)
    iekDccSend          ## DCC SEND offer received
    iekDccChat          ## DCC CHAT offer received
    iekDccAccept        ## DCC ACCEPT received
    iekDccResume        ## DCC RESUME received
    iekError            ## Error (protocol or connection)
    iekPing             ## PING from server
    iekInvite           ## Invited to a channel
    iekCap             ## CAP negotiation response
    iekPong            ## PONG from server
    iekAway            ## User away status change (away-notify)
    iekChghost         ## User changed host (chghost cap)
    iekSetname         ## User changed realname (setname cap)
    iekAccount         ## User account change (account-notify)
    iekBatch           ## BATCH start/end

  DccInfo* = object
    ## Parsed DCC request information.
    kind*: string       ## "SEND", "CHAT", "ACCEPT", "RESUME"
    filename*: string
    ip*: uint32         ## Network-order IP (from DCC long IP format)
    port*: int
    filesize*: int64    ## File size (-1 if not provided)
    token*: string      ## Token for passive/reverse DCC

  IrcEvent* = object
    ## An event emitted by the IRC client.
    msgBatchRef*: string      ## IRCv3 batch reference tag (from message tags), empty if not in a batch
    case kind*: IrcEventKind
    of iekConnected:
      discard
    of iekDisconnected:
      reason*: string
    of iekMessage:
      msg*: IrcMessage
    of iekPrivMsg, iekNotice:
      pmSource*: string     ## Nick or channel
      pmTarget*: string     ## Target (nick or channel)
      pmText*: string       ## Message text
      pmPrefix*: IrcPrefix  ## Full prefix
    of iekJoin:
      joinNick*: string
      joinChannel*: string
      joinPrefix*: IrcPrefix
    of iekPart:
      partNick*: string
      partChannel*: string
      partReason*: string
      partPrefix*: IrcPrefix
    of iekQuit:
      quitNick*: string
      quitReason*: string
      quitPrefix*: IrcPrefix
    of iekKick:
      kickChannel*: string
      kickNick*: string     ## Who was kicked
      kickBy*: string       ## Who kicked
      kickReason*: string
    of iekNick:
      nickOld*: string
      nickNew*: string
    of iekMode:
      modeTarget*: string
      modeChanges*: string
      modeParams*: seq[string]
    of iekTopic:
      topicChannel*: string
      topicText*: string
      topicBy*: string
    of iekNumeric:
      numCode*: int
      numParams*: seq[string]
      numPrefix*: IrcPrefix
    of iekCtcp:
      ctcpSource*: string
      ctcpTarget*: string
      ctcpCommand*: string
      ctcpArgs*: string
      ctcpPrefix*: IrcPrefix
    of iekDccSend, iekDccChat, iekDccAccept, iekDccResume:
      dccSource*: string
      dccInfo*: DccInfo
    of iekError:
      errMsg*: string
    of iekPing:
      pingToken*: string
    of iekInvite:
      inviteNick*: string
      inviteChannel*: string
    of iekCap:
      capSubcommand*: string    ## LS, ACK, NAK, NEW, DEL
      capParams*: seq[string]   ## Capability parameters
    of iekPong:
      pongToken*: string
    of iekAway:
      awayNick*: string
      awayMessage*: string      ## Empty = returned from away
      awayPrefix*: IrcPrefix
    of iekChghost:
      chghostNick*: string
      chghostNewUser*: string
      chghostNewHost*: string
    of iekSetname:
      setnameNick*: string
      setnameRealname*: string
    of iekAccount:
      accountNick*: string
      accountName*: string      ## "*" = logged out
    of iekBatch:
      batchRef*: string         ## Batch reference tag
      batchType*: string        ## Type (e.g., "netsplit", "netjoin", "chathistory")
      batchStarting*: bool      ## True = start, False = end
      batchParams*: seq[string]

# ============================================================
# IRC message parsing
# ============================================================

proc parsePrefix*(raw: string): IrcPrefix =
  ## Parse an IRC prefix string like "nick!user@host".
  result.raw = raw
  let bangIdx = raw.find('!')
  let atIdx = raw.find('@')
  if bangIdx >= 0 and atIdx > bangIdx:
    result.nick = raw[0 ..< bangIdx]
    result.user = raw[bangIdx + 1 ..< atIdx]
    result.host = raw[atIdx + 1 .. ^1]
  elif atIdx >= 0:
    result.nick = raw[0 ..< atIdx]
    result.host = raw[atIdx + 1 .. ^1]
  else:
    # Could be a server name or just a nick
    result.nick = raw
    result.host = raw

proc parseIrcMessage*(line: string): IrcMessage =
  ## Parse a raw IRC protocol line into an IrcMessage.
  ## Handles IRCv3 tags, prefix, command, and params.
  result.raw = line
  var pos = 0

  # Skip leading whitespace
  while pos < line.len and line[pos] == ' ':
    inc pos

  # IRCv3 tags (starts with '@')
  if pos < line.len and line[pos] == '@':
    inc pos
    let tagEnd = line.find(' ', pos)
    if tagEnd < 0:
      result.command = ""
      return
    let tagStr = line[pos ..< tagEnd]
    result.tags = initTable[string, string]()
    for tag in tagStr.split(';'):
      let eqIdx = tag.find('=')
      if eqIdx >= 0:
        result.tags[tag[0 ..< eqIdx]] = tag[eqIdx + 1 .. ^1]
      else:
        result.tags[tag] = ""
    pos = tagEnd
    while pos < line.len and line[pos] == ' ':
      inc pos

  # Prefix (starts with ':')
  if pos < line.len and line[pos] == ':':
    inc pos
    let prefixEnd = line.find(' ', pos)
    if prefixEnd < 0:
      result.command = ""
      return
    result.prefix = parsePrefix(line[pos ..< prefixEnd])
    pos = prefixEnd
    while pos < line.len and line[pos] == ' ':
      inc pos

  # Command
  let cmdEnd = line.find(' ', pos)
  if cmdEnd < 0:
    result.command = line[pos .. ^1].toUpperAscii()
    return
  result.command = line[pos ..< cmdEnd].toUpperAscii()
  pos = cmdEnd
  while pos < line.len and line[pos] == ' ':
    inc pos

  # Parameters
  while pos < line.len:
    if line[pos] == ':':
      # Trailing parameter — rest of line
      result.params.add(line[pos + 1 .. ^1])
      break
    else:
      let paramEnd = line.find(' ', pos)
      if paramEnd < 0:
        result.params.add(line[pos .. ^1])
        break
      result.params.add(line[pos ..< paramEnd])
      pos = paramEnd
      while pos < line.len and line[pos] == ' ':
        inc pos

proc isChannel*(target: string): bool =
  ## Returns true if the target looks like a channel name.
  target.len > 0 and target[0] in {'#', '&', '+', '!'}

# ============================================================
# IRC message formatting
# ============================================================

proc formatIrcMessage*(command: string, params: varargs[string]): string =
  ## Format an IRC message for sending. The last parameter is always
  ## made trailing (prefixed with ':') per IRC convention.
  result = command
  for i in 0 ..< params.len:
    result.add(' ')
    if i == params.len - 1:
      result.add(':')
    result.add(params[i])
  result.add("\r\n")

proc formatNick*(nick: string): string =
  formatIrcMessage("NICK", nick)

proc formatUser*(username, realname: string): string =
  formatIrcMessage("USER", username, "0", "*", realname)

proc formatPass*(password: string): string =
  formatIrcMessage("PASS", password)

proc formatJoin*(channel: string, key: string = ""): string =
  if key.len > 0:
    formatIrcMessage("JOIN", channel, key)
  else:
    formatIrcMessage("JOIN", channel)

proc formatPart*(channel: string, reason: string = ""): string =
  if reason.len > 0:
    formatIrcMessage("PART", channel, reason)
  else:
    formatIrcMessage("PART", channel)

proc formatPrivMsg*(target, text: string): string =
  formatIrcMessage("PRIVMSG", target, text)

proc formatNotice*(target, text: string): string =
  formatIrcMessage("NOTICE", target, text)

proc formatPong*(token: string): string =
  formatIrcMessage("PONG", token)

proc formatQuit*(reason: string = ""): string =
  if reason.len > 0:
    formatIrcMessage("QUIT", reason)
  else:
    formatIrcMessage("QUIT")

proc formatCtcp*(target, command: string, args: string = ""): string =
  ## Format a CTCP message (wrapped in \x01).
  var ctcpText = "\x01" & command
  if args.len > 0:
    ctcpText.add(' ')
    ctcpText.add(args)
  ctcpText.add('\x01')
  formatPrivMsg(target, ctcpText)

proc formatCtcpReply*(target, command: string, args: string = ""): string =
  ## Format a CTCP reply via NOTICE.
  var ctcpText = "\x01" & command
  if args.len > 0:
    ctcpText.add(' ')
    ctcpText.add(args)
  ctcpText.add('\x01')
  formatNotice(target, ctcpText)

# ============================================================
# DCC formatting
# ============================================================

proc formatDccResume*(target, filename: string, port: int, position: int64): string =
  ## Format a DCC RESUME CTCP request.
  ## Sent to request resuming a partially downloaded file.
  formatCtcp(target, "DCC", "RESUME " & filename & " " & $port & " " & $position)

proc formatDccAccept*(target, filename: string, port: int, position: int64): string =
  ## Format a DCC ACCEPT CTCP message.
  ## Sent in response to a RESUME request to confirm the resume position.
  formatCtcp(target, "DCC", "ACCEPT " & filename & " " & $port & " " & $position)

# ============================================================
# DCC parsing
# ============================================================

proc longIpToString*(ip: uint32): string =
  ## Convert a DCC long-format IP to dotted notation.
  let a = (ip shr 24) and 0xFF
  let b = (ip shr 16) and 0xFF
  let c = (ip shr 8) and 0xFF
  let d = ip and 0xFF
  $a & "." & $b & "." & $c & "." & $d

proc stringToLongIp*(ip: string): uint32 =
  ## Convert a dotted notation IP to DCC long-format.
  let parts = ip.split('.')
  if parts.len != 4:
    raise newException(ValueError, "Invalid IP address: " & ip)
  result = uint32(parseInt(parts[0])) shl 24 or
           uint32(parseInt(parts[1])) shl 16 or
           uint32(parseInt(parts[2])) shl 8 or
           uint32(parseInt(parts[3]))

proc parseDcc*(text: string): Option[DccInfo] =
  ## Parse a DCC request from a CTCP message argument string.
  ## Expected formats:
  ##   SEND <filename> <ip> <port> [<filesize>] [<token>]
  ##   SEND "<filename with spaces>" <ip> <port> [<filesize>] [<token>]
  ##   CHAT chat <ip> <port>
  ##   ACCEPT <filename> <port> <position> [<token>]
  ##   RESUME <filename> <port> <position> [<token>]
  var info: DccInfo
  var parts: seq[string]
  var remaining = text.strip()

  # Extract the DCC subcommand
  let spaceIdx = remaining.find(' ')
  if spaceIdx < 0:
    return none(DccInfo)
  info.kind = remaining[0 ..< spaceIdx].toUpperAscii()
  remaining = remaining[spaceIdx + 1 .. ^1].strip()

  # Handle quoted filenames
  if remaining.len > 0 and remaining[0] == '"':
    let closeQuote = remaining.find('"', 1)
    if closeQuote < 0:
      return none(DccInfo)
    info.filename = remaining[1 ..< closeQuote]
    remaining = remaining[closeQuote + 1 .. ^1].strip()
    parts = remaining.splitWhitespace()
  else:
    parts = remaining.splitWhitespace()
    if parts.len > 0:
      info.filename = parts[0]
      parts.delete(0)

  info.filesize = -1

  case info.kind
  of "SEND":
    if parts.len < 2:
      return none(DccInfo)
    try:
      info.ip = uint32(parseBiggestUInt(parts[0]))
      info.port = parseInt(parts[1])
    except ValueError:
      return none(DccInfo)
    if parts.len > 2:
      try:
        info.filesize = parseBiggestInt(parts[2])
      except ValueError:
        discard
    if parts.len > 3:
      info.token = parts[3]

  of "CHAT":
    if parts.len < 2:
      return none(DccInfo)
    try:
      info.ip = uint32(parseBiggestUInt(parts[0]))
      info.port = parseInt(parts[1])
    except ValueError:
      return none(DccInfo)

  of "ACCEPT", "RESUME":
    if parts.len < 2:
      return none(DccInfo)
    try:
      info.port = parseInt(parts[0])
      info.filesize = parseBiggestInt(parts[1])  # position
    except ValueError:
      return none(DccInfo)
    if parts.len > 2:
      info.token = parts[2]

  else:
    return none(DccInfo)

  result = some(info)

proc isCtcp*(text: string): bool =
  ## Check if a message text is a CTCP message (wrapped in \x01).
  text.len >= 2 and text[0] == '\x01' and text[^1] == '\x01'

proc parseCtcp*(text: string): tuple[command: string, args: string] =
  ## Parse a CTCP message. Returns (command, args).
  let inner = text[1 ..< text.len - 1]  # Strip \x01
  let spaceIdx = inner.find(' ')
  if spaceIdx < 0:
    result = (inner.toUpperAscii(), "")
  else:
    result = (inner[0 ..< spaceIdx].toUpperAscii(), inner[spaceIdx + 1 .. ^1])

proc classifyMessage*(msg: IrcMessage): IrcEvent =
  ## Classify a raw IrcMessage into a typed IrcEvent.
  case msg.command
  of "PING":
    let token = if msg.params.len > 0: msg.params[0] else: ""
    result = IrcEvent(kind: iekPing, pingToken: token)

  of "PRIVMSG":
    if msg.params.len >= 2:
      let target = msg.params[0]
      let text = msg.params[1]
      let source = msg.prefix.nick

      if isCtcp(text):
        let (ctcpCmd, ctcpArgs) = parseCtcp(text)
        if ctcpCmd == "DCC":
          let dccOpt = parseDcc(ctcpArgs)
          if dccOpt.isSome:
            let dcc = dccOpt.get()
            case dcc.kind
            of "SEND":
              result = IrcEvent(kind: iekDccSend, dccSource: source, dccInfo: dcc)
            of "CHAT":
              result = IrcEvent(kind: iekDccChat, dccSource: source, dccInfo: dcc)
            of "ACCEPT":
              result = IrcEvent(kind: iekDccAccept, dccSource: source, dccInfo: dcc)
            of "RESUME":
              result = IrcEvent(kind: iekDccResume, dccSource: source, dccInfo: dcc)
            else:
              result = IrcEvent(kind: iekCtcp, ctcpSource: source, ctcpTarget: target,
                               ctcpCommand: ctcpCmd, ctcpArgs: ctcpArgs, ctcpPrefix: msg.prefix)
          else:
            result = IrcEvent(kind: iekCtcp, ctcpSource: source, ctcpTarget: target,
                             ctcpCommand: ctcpCmd, ctcpArgs: ctcpArgs, ctcpPrefix: msg.prefix)
        else:
          result = IrcEvent(kind: iekCtcp, ctcpSource: source, ctcpTarget: target,
                           ctcpCommand: ctcpCmd, ctcpArgs: ctcpArgs, ctcpPrefix: msg.prefix)
      else:
        result = IrcEvent(kind: iekPrivMsg, pmSource: source, pmTarget: target,
                         pmText: text, pmPrefix: msg.prefix)
    else:
      result = IrcEvent(kind: iekMessage, msg: msg)

  of "NOTICE":
    if msg.params.len >= 2:
      let target = msg.params[0]
      let text = msg.params[1]
      let source = msg.prefix.nick
      if isCtcp(text):
        let (ctcpCmd, ctcpArgs) = parseCtcp(text)
        # Parse DCC subcommands from NOTICE too — bots (especially XDCC)
        # often send DCC SEND offers via NOTICE rather than PRIVMSG.
        if ctcpCmd == "DCC":
          let dccOpt = parseDcc(ctcpArgs)
          if dccOpt.isSome:
            let dcc = dccOpt.get()
            case dcc.kind
            of "SEND":
              result = IrcEvent(kind: iekDccSend, dccSource: source, dccInfo: dcc)
            of "CHAT":
              result = IrcEvent(kind: iekDccChat, dccSource: source, dccInfo: dcc)
            of "ACCEPT":
              result = IrcEvent(kind: iekDccAccept, dccSource: source, dccInfo: dcc)
            of "RESUME":
              result = IrcEvent(kind: iekDccResume, dccSource: source, dccInfo: dcc)
            else:
              result = IrcEvent(kind: iekCtcp, ctcpSource: source, ctcpTarget: target,
                               ctcpCommand: ctcpCmd, ctcpArgs: ctcpArgs, ctcpPrefix: msg.prefix)
          else:
            result = IrcEvent(kind: iekCtcp, ctcpSource: source, ctcpTarget: target,
                             ctcpCommand: ctcpCmd, ctcpArgs: ctcpArgs, ctcpPrefix: msg.prefix)
        else:
          result = IrcEvent(kind: iekCtcp, ctcpSource: source, ctcpTarget: target,
                           ctcpCommand: ctcpCmd, ctcpArgs: ctcpArgs, ctcpPrefix: msg.prefix)
      else:
        result = IrcEvent(kind: iekNotice, pmSource: source, pmTarget: target,
                         pmText: text, pmPrefix: msg.prefix)
    else:
      result = IrcEvent(kind: iekMessage, msg: msg)

  of "JOIN":
    let channel = if msg.params.len > 0: msg.params[0] else: ""
    result = IrcEvent(kind: iekJoin, joinNick: msg.prefix.nick,
                     joinChannel: channel, joinPrefix: msg.prefix)

  of "PART":
    let channel = if msg.params.len > 0: msg.params[0] else: ""
    let reason = if msg.params.len > 1: msg.params[1] else: ""
    result = IrcEvent(kind: iekPart, partNick: msg.prefix.nick,
                     partChannel: channel, partReason: reason, partPrefix: msg.prefix)

  of "QUIT":
    let reason = if msg.params.len > 0: msg.params[0] else: ""
    result = IrcEvent(kind: iekQuit, quitNick: msg.prefix.nick,
                     quitReason: reason, quitPrefix: msg.prefix)

  of "KICK":
    if msg.params.len >= 2:
      let channel = msg.params[0]
      let kicked = msg.params[1]
      let reason = if msg.params.len > 2: msg.params[2] else: ""
      result = IrcEvent(kind: iekKick, kickChannel: channel, kickNick: kicked,
                       kickBy: msg.prefix.nick, kickReason: reason)
    else:
      result = IrcEvent(kind: iekMessage, msg: msg)

  of "NICK":
    let newNick = if msg.params.len > 0: msg.params[0] else: ""
    result = IrcEvent(kind: iekNick, nickOld: msg.prefix.nick, nickNew: newNick)

  of "MODE":
    if msg.params.len >= 2:
      result = IrcEvent(kind: iekMode, modeTarget: msg.params[0],
                       modeChanges: msg.params[1],
                       modeParams: if msg.params.len > 2: msg.params[2 .. ^1] else: @[])
    else:
      result = IrcEvent(kind: iekMessage, msg: msg)

  of "TOPIC":
    if msg.params.len >= 2:
      result = IrcEvent(kind: iekTopic, topicChannel: msg.params[0],
                       topicText: msg.params[1], topicBy: msg.prefix.nick)
    else:
      result = IrcEvent(kind: iekMessage, msg: msg)

  of "INVITE":
    if msg.params.len >= 2:
      result = IrcEvent(kind: iekInvite, inviteNick: msg.prefix.nick,
                       inviteChannel: msg.params[1])
    else:
      result = IrcEvent(kind: iekMessage, msg: msg)

  of "ERROR":
    let errText = if msg.params.len > 0: msg.params[0] else: "Unknown error"
    result = IrcEvent(kind: iekError, errMsg: errText)


  of "CAP":
    if msg.params.len >= 2:
      result = IrcEvent(kind: iekCap, capSubcommand: msg.params[1].toUpperAscii,
                       capParams: if msg.params.len > 2: msg.params[2..^1] else: @[])
    else:
      result = IrcEvent(kind: iekMessage, msg: msg)

  of "PONG":
    let token = if msg.params.len > 1: msg.params[1]
                elif msg.params.len > 0: msg.params[0]
                else: ""
    result = IrcEvent(kind: iekPong, pongToken: token)

  of "AWAY":
    # away-notify: :nick!user@host AWAY :message  or  :nick!user@host AWAY
    let awayMsg = if msg.params.len > 0: msg.params[0] else: ""
    result = IrcEvent(kind: iekAway, awayNick: msg.prefix.nick,
                     awayMessage: awayMsg, awayPrefix: msg.prefix)

  of "CHGHOST":
    # :nick!user@host CHGHOST newuser newhost
    if msg.params.len >= 2:
      result = IrcEvent(kind: iekChghost, chghostNick: msg.prefix.nick,
                       chghostNewUser: msg.params[0], chghostNewHost: msg.params[1])
    else:
      result = IrcEvent(kind: iekMessage, msg: msg)

  of "SETNAME":
    # :nick!user@host SETNAME :new realname
    let realname = if msg.params.len > 0: msg.params[0] else: ""
    result = IrcEvent(kind: iekSetname, setnameNick: msg.prefix.nick,
                     setnameRealname: realname)

  of "ACCOUNT":
    # :nick!user@host ACCOUNT accountname  (or * for logged out)
    let acct = if msg.params.len > 0: msg.params[0] else: "*"
    result = IrcEvent(kind: iekAccount, accountNick: msg.prefix.nick,
                     accountName: acct)

  of "BATCH":
    if msg.params.len >= 1:
      let refTag = msg.params[0]
      let starting = refTag.len > 0 and refTag[0] == '+'
      let cleanRef = if starting: refTag[1..^1]
                     elif refTag.len > 0 and refTag[0] == '-': refTag[1..^1]
                     else: refTag
      let batchType = if starting and msg.params.len > 1: msg.params[1] else: ""
      let batchParams = if starting and msg.params.len > 2: msg.params[2..^1] else: @[]
      result = IrcEvent(kind: iekBatch, batchRef: cleanRef, batchType: batchType,
                       batchStarting: starting, batchParams: batchParams)
    else:
      result = IrcEvent(kind: iekMessage, msg: msg)

  of "AUTHENTICATE":
    # SASL auth challenge/response - pass as raw message
    result = IrcEvent(kind: iekMessage, msg: msg)

  of "FAIL", "WARN", "NOTE":
    # Standard Replies (IRCv3)
    let text = msg.params.join(" ")
    result = IrcEvent(kind: iekError, errMsg: "[" & msg.command & "] " & text)

  else:
    # Try to parse as numeric
    var numVal: int
    if msg.command.len == 3 and msg.command.allCharsInSet({'0'..'9'}):
      numVal = parseInt(msg.command)
      result = IrcEvent(kind: iekNumeric, numCode: numVal,
                       numParams: msg.params, numPrefix: msg.prefix)
    else:
      # Unknown command — emit as raw message
      result = IrcEvent(kind: iekMessage, msg: msg)

  # Propagate batch reference from message tags
  if msg.tags.hasKey("batch"):
    result.msgBatchRef = msg.tags["batch"]

# ============================================================
# IRC formatting code stripping
# ============================================================

proc stripIrcFormatting*(text: string): string =
  ## Strip IRC color codes and formatting characters from text.
  ##
  ## IRC formatting uses control characters:
  ##   \x02 = bold
  ##   \x03 = color (followed by optional fg[,bg] digits)
  ##   \x04 = hex color (followed by RRGGBB[,RRGGBB])
  ##   \x0F = reset all formatting
  ##   \x11 = monospace
  ##   \x16 = reverse/italic
  ##   \x1D = italic
  ##   \x1E = strikethrough
  ##   \x1F = underline
  result = newStringOfCap(text.len)
  var i = 0
  while i < text.len:
    let ch = text[i]
    case ch
    of '\x02', '\x0F', '\x11', '\x16', '\x1D', '\x1E', '\x1F':
      # Single-byte formatting codes — skip
      inc i
    of '\x03':
      # Color code: \x03[fg[,bg]] where fg/bg are 1-2 digits
      inc i
      # Skip foreground digits (0-2 digits)
      var digits = 0
      while i < text.len and text[i] in {'0'..'9'} and digits < 2:
        inc i
        inc digits
      # Check for comma + background digits
      if i < text.len and text[i] == ',' and digits > 0:
        # Peek ahead — only consume comma if followed by digit
        if i + 1 < text.len and text[i + 1] in {'0'..'9'}:
          inc i  # skip comma
          digits = 0
          while i < text.len and text[i] in {'0'..'9'} and digits < 2:
            inc i
            inc digits
    of '\x04':
      # Hex color: \x04RRGGBB[,RRGGBB]
      inc i
      # Skip up to 6 hex digits
      var digits = 0
      while i < text.len and text[i] in {'0'..'9', 'a'..'f', 'A'..'F'} and digits < 6:
        inc i
        inc digits
      if i < text.len and text[i] == ',' and digits > 0:
        if i + 1 < text.len and text[i + 1] in {'0'..'9', 'a'..'f', 'A'..'F'}:
          inc i
          digits = 0
          while i < text.len and text[i] in {'0'..'9', 'a'..'f', 'A'..'F'} and digits < 6:
            inc i
            inc digits
    else:
      result.add(ch)
      inc i

# ============================================================
# Common IRC numeric codes
# ============================================================

const
  RPL_WELCOME* = 1
  RPL_YOURHOST* = 2
  RPL_CREATED* = 3
  RPL_MYINFO* = 4
  RPL_ISUPPORT* = 5
  RPL_NAMREPLY* = 353
  RPL_ENDOFNAMES* = 366
  RPL_MOTD* = 372
  RPL_MOTDSTART* = 375
  RPL_ENDOFMOTD* = 376
  RPL_TOPIC* = 332
  RPL_TOPICWHOTIME* = 333
  RPL_WHOREPLY* = 352
  RPL_ENDOFWHO* = 315
  ERR_NICKNAMEINUSE* = 433
  ERR_ERRONEUSNICKNAME* = 432
  ERR_NOTREGISTERED* = 451
  ERR_NEEDMOREPARAMS* = 461
  ERR_ALREADYREGISTERED* = 462
  ERR_NOMOTD* = 422

  # WHOIS numerics
  RPL_WHOISUSER* = 311
  RPL_WHOISSERVER* = 312
  RPL_WHOISOPERATOR* = 313
  RPL_WHOISIDLE* = 317
  RPL_ENDOFWHOIS* = 318
  RPL_WHOISCHANNELS* = 319
  RPL_WHOISACCOUNT* = 330
  RPL_WHOISACTUALLY* = 338

  # Away
  RPL_UNAWAY* = 305
  RPL_NOWAWAY* = 306

  # Channel modes
  RPL_CHANNELMODEIS* = 324
  RPL_CREATIONTIME* = 329
  RPL_BANLIST* = 367
  RPL_ENDOFBANLIST* = 368

  # SASL
  RPL_LOGGEDIN* = 900
  RPL_LOGGEDOUT* = 901
  RPL_SASLSUCCESS* = 903
  RPL_SASLFAIL* = 904
  RPL_SASLTOOLONG* = 905
  RPL_SASLABORTED* = 906
  RPL_SASLALREADY* = 907
  RPL_SASLMECHS* = 908

  # MONITOR
  RPL_MONONLINE* = 730
  RPL_MONOFFLINE* = 731
  RPL_MONLIST* = 732
  RPL_ENDOFMONLIST* = 733
  ERR_MONLISTFULL* = 734

  # Misc
  RPL_INVITING* = 341
  ERR_CHANOPRIVSNEEDED* = 482
  ERR_NOSUCHNICK* = 401
  ERR_NOSUCHCHANNEL* = 403
  ERR_CANNOTSENDTOCHAN* = 404
  ERR_NOTONCHANNEL* = 442
  ERR_USERONCHANNEL* = 443
