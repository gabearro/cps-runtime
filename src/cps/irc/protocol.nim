## CPS IRC Protocol
##
## IRC message parsing and formatting per RFC 2812.
## Provides types and helpers for the IRC wire protocol.

import std/[strutils, tables, options, sequtils]

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
    iekStandardReply   ## FAIL/WARN/NOTE structured reply
    iekCompletedBatch  ## Aggregated batch (all messages collected)
    iekMonOnline       ## MONITOR: targets came online (RPL_MONONLINE)
    iekMonOffline      ## MONITOR: targets went offline (RPL_MONOFFLINE)
    iekRedact          ## Message redaction (REDACT command)
    iekTagMsg          ## Tags-only message (TAGMSG command)
    iekTyping          ## Typing indicator (from +typing tag)
    iekChannelRename   ## Channel renamed (RENAME command)
    iekMarkread        ## Read marker update (MARKREAD command)

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
    of iekStandardReply:
      srLevel*: string          ## "FAIL", "WARN", or "NOTE"
      srCommand*: string        ## The command this reply refers to
      srCode*: string           ## Machine-readable code
      srContext*: seq[string]   ## Context parameters
      srDescription*: string    ## Human-readable description
    of iekCompletedBatch:
      cbBatchRef*: string
      cbBatchType*: string
      cbBatchParams*: seq[string]
      cbMessages*: seq[IrcEvent]
      cbNestedBatches*: seq[IrcEvent]   ## Nested iekCompletedBatch events
    of iekMonOnline:
      monOnlineTargets*: seq[string]
    of iekMonOffline:
      monOfflineTargets*: seq[string]
    of iekRedact:
      redactTarget*: string     ## Channel or user
      redactMsgId*: string      ## msgid of message being redacted
      redactReason*: string     ## Reason for redaction (may be empty)
      redactBy*: string         ## Nick of who redacted
    of iekTagMsg:
      tagmsgSource*: string
      tagmsgTarget*: string
      tagmsgTags*: Table[string, string]
      tagmsgPrefix*: IrcPrefix
    of iekTyping:
      typingNick*: string
      typingTarget*: string
      typingActive*: bool
    of iekChannelRename:
      renameOld*: string
      renameNew*: string
      renameReason*: string
    of iekMarkread:
      markreadTarget*: string
      markreadTimestamp*: string

# ============================================================
# Tag key constants
# ============================================================

const
  tagMsgId* = "msgid"
  tagTime* = "time"
  tagAccount* = "account"
  tagBatch* = "batch"
  tagLabel* = "label"
  tagBot* = "bot"
  tagReply* = "+draft/reply"
  tagReact* = "+draft/react"
  tagUnreact* = "+draft/unreact"
  tagTyping* = "+typing"
  tagChannelContext* = "+draft/channel-context"
  tagMultilineConcat* = "draft/multiline-concat"

# ============================================================
# Standard reply FAIL/WARN/NOTE codes (IRCv3 registry)
# ============================================================

const
  # Global
  failAccountRequired* = "ACCOUNT_REQUIRED"
  failInvalidUtf8* = "INVALID_UTF8"
  warnInvalidUtf8* = "INVALID_UTF8"

  # BATCH
  failBatchMultilineMaxBytes* = "MULTILINE_MAX_BYTES"
  failBatchMultilineMaxLines* = "MULTILINE_MAX_LINES"
  failBatchMultilineInvalidTarget* = "MULTILINE_INVALID_TARGET"
  failBatchMultilineInvalid* = "MULTILINE_INVALID"
  failBatchInvalidReftag* = "INVALID_REFTAG"
  failBatchTimeout* = "TIMEOUT"
  failBatchUnknownType* = "UNKNOWN_TYPE"

  # CHATHISTORY
  failChathistoryInvalidParams* = "INVALID_PARAMS"
  failChathistoryInvalidTarget* = "INVALID_TARGET"
  failChathistoryMessageError* = "MESSAGE_ERROR"
  failChathistoryNeedMoreParams* = "NEED_MORE_PARAMS"
  failChathistoryUnknownCommand* = "UNKNOWN_COMMAND"

  # JOIN
  failJoinChannelRenamed* = "CHANNEL_RENAMED"

  # NICK
  failNickNicknameReserved* = "NICKNAME_RESERVED"

  # REDACT
  failRedactInvalidTarget* = "INVALID_TARGET"
  failRedactForbidden* = "REDACT_FORBIDDEN"
  failRedactWindowExpired* = "REDACT_WINDOW_EXPIRED"
  failRedactUnknownMsgid* = "UNKNOWN_MSGID"

  # METADATA
  failMetadataInvalidTarget* = "INVALID_TARGET"
  failMetadataKeyInvalid* = "KEY_INVALID"
  failMetadataKeyNoPermission* = "KEY_NO_PERMISSION"
  failMetadataKeyNotSet* = "KEY_NOT_SET"
  failMetadataLimitReached* = "LIMIT_REACHED"
  failMetadataRateLimited* = "RATE_LIMITED"
  failMetadataSubcommandInvalid* = "SUBCOMMAND_INVALID"
  failMetadataTooManySubs* = "TOO_MANY_SUBS"
  failMetadataValueInvalid* = "VALUE_INVALID"

  # REGISTER
  failRegisterAccountExists* = "ACCOUNT_EXISTS"
  failRegisterAccountNameMustBeNick* = "ACCOUNT_NAME_MUST_BE_NICK"
  failRegisterAlreadyAuthenticated* = "ALREADY_AUTHENTICATED"
  failRegisterBadAccountName* = "BAD_ACCOUNT_NAME"
  failRegisterCompleteConnectionRequired* = "COMPLETE_CONNECTION_REQUIRED"
  failRegisterInvalidEmail* = "INVALID_EMAIL"
  failRegisterNeedNick* = "NEED_NICK"
  failRegisterTemporarilyUnavailable* = "TEMPORARILY_UNAVAILABLE"
  failRegisterUnacceptableEmail* = "UNACCEPTABLE_EMAIL"
  failRegisterUnacceptablePassword* = "UNACCEPTABLE_PASSWORD"
  failRegisterWeakPassword* = "WEAK_PASSWORD"

  # RENAME
  failRenameChannelNameInUse* = "CHANNEL_NAME_IN_USE"
  failRenameCannotRename* = "CANNOT_RENAME"

  # SETNAME
  failSetnameCannotChangeRealname* = "CANNOT_CHANGE_REALNAME"
  failSetnameInvalidRealname* = "INVALID_REALNAME"

  # VERIFY
  failVerifyAlreadyAuthenticated* = "ALREADY_AUTHENTICATED"
  failVerifyInvalidCode* = "INVALID_CODE"
  failVerifyCompleteConnectionRequired* = "COMPLETE_CONNECTION_REQUIRED"
  failVerifyTemporarilyUnavailable* = "TEMPORARILY_UNAVAILABLE"

# ============================================================
# Metadata key constants (IRCv3 registry)
# ============================================================

const
  # User metadata keys
  metaAvatar* = "avatar"
  metaBot* = "bot"
  metaColor* = "color"
  metaDisplayName* = "display-name"
  metaHomepage* = "homepage"
  metaStatus* = "status"

  # Channel metadata keys (same names, different context)
  metaChanAvatar* = "avatar"
  metaChanDisplayName* = "display-name"

# ============================================================
# Batch type constants
# ============================================================

const
  batchNetjoin* = "netjoin"
  batchNetsplit* = "netsplit"
  batchChathistory* = "chathistory"
  batchMultiline* = "draft/multiline"
  batchLabeledResponse* = "labeled-response"

# ============================================================
# IRCv3 capability name constants
# ============================================================

const
  capServerTime* = "server-time"
  capMessageTags* = "message-tags"
  capAwayNotify* = "away-notify"
  capAccountNotify* = "account-notify"
  capExtendedJoin* = "extended-join"
  capMultiPrefix* = "multi-prefix"
  capCapNotify* = "cap-notify"
  capChghost* = "chghost"
  capSetname* = "setname"
  capInviteNotify* = "invite-notify"
  capUserhostInNames* = "userhost-in-names"
  capSasl* = "sasl"
  capBatch* = "batch"
  capLabeledResponse* = "labeled-response"
  capEchoMessage* = "echo-message"
  capAccountTag* = "account-tag"
  capStandardReplies* = "standard-replies"
  capMonitor* = "monitor"
  capDraftChathistory* = "draft/chathistory"
  capDraftMessageRedaction* = "draft/message-redaction"
  capDraftChannelRename* = "draft/channel-rename"
  capDraftReadMarker* = "draft/read-marker"
  capDraftMultiline* = "draft/multiline"
  capDraftPreAway* = "draft/pre-away"
  capDraftNoImplicitNames* = "draft/no-implicit-names"
  capDraftExtendedIsupport* = "draft/extended-isupport"
  capDraftEventPlayback* = "draft/event-playback"
  capDraftExtendedMonitor* = "draft/extended-monitor"
  capDraftAccountRegistration* = "draft/account-registration"
  capDraftMetadata2* = "draft/metadata-2"
  capTls* = "tls"  ## STARTTLS capability

# ============================================================
# Tag value escaping/unescaping (IRCv3)
# ============================================================

proc unescapeTagValue*(value: string): string =
  ## Unescape an IRCv3 tag value.
  ## \: → ;  \s → space  \\ → \  \r → CR  \n → LF
  result = newStringOfCap(value.len)
  var i = 0
  while i < value.len:
    if value[i] == '\\' and i + 1 < value.len:
      case value[i + 1]
      of ':': result.add(';')
      of 's': result.add(' ')
      of '\\': result.add('\\')
      of 'r': result.add('\r')
      of 'n': result.add('\n')
      else:
        # Unknown escape — drop the backslash per spec
        result.add(value[i + 1])
      i += 2
    elif value[i] == '\\':
      # Trailing backslash — drop it per spec
      i += 1
    else:
      result.add(value[i])
      i += 1

proc escapeTagValue*(value: string): string =
  ## Escape a string for use as an IRCv3 tag value.
  ## ; → \:  space → \s  \ → \\  CR → \r  LF → \n
  result = newStringOfCap(value.len)
  for ch in value:
    case ch
    of ';': result.add("\\:")
    of ' ': result.add("\\s")
    of '\\': result.add("\\\\")
    of '\r': result.add("\\r")
    of '\n': result.add("\\n")
    else: result.add(ch)

# ============================================================
# ISUPPORT (005) tracking
# ============================================================

type
  ISupport* = ref object
    ## Parsed ISUPPORT (005) parameters from the server.
    raw*: Table[string, string]       ## All key=value pairs
    monitor*: int                     ## MONITOR limit (-1 if not supported)
    whox*: bool                       ## WHOX support
    bot*: string                      ## BOT mode character
    utf8Only*: bool                   ## UTF8ONLY support
    clientTagDeny*: seq[string]       ## CLIENTTAGDENY list
    network*: string                  ## Network name
    prefix*: string                   ## PREFIX value (e.g., "(ov)@+")
    chanModes*: string                ## CHANMODES value
    statusMsg*: string                ## STATUSMSG characters
    chanTypes*: string                ## CHANTYPES (default "#&")
    modes*: int                       ## Max mode changes per command
    maxTargets*: int                  ## Max targets per command
    nickLen*: int                     ## Max nick length
    topicLen*: int                    ## Max topic length
    awayLen*: int                     ## Max AWAY message length
    kickLen*: int                     ## Max KICK reason length
    accountExtban*: seq[string]       ## ACCOUNTEXTBAN account type prefixes
    msgRefTypes*: seq[string]         ## MSGREFTYPES supported reference types
    icon*: string                     ## draft/ICON: server icon URL

proc newISupport*(): ISupport =
  ISupport(
    raw: initTable[string, string](),
    monitor: -1,
    chanTypes: "#&",
    nickLen: 30,
    modes: 3,
  )

proc parseIsupport*(params: seq[string]): seq[tuple[key, value: string]] =
  ## Parse ISUPPORT (005) parameters. Skips first (nick) and last (trailing text).
  if params.len < 2: return @[]
  for i in 1 ..< params.len - 1:
    let token = params[i]
    if token.startsWith("-"):
      # Negation: -KEY means remove
      result.add((token[1..^1], ""))
    else:
      let eqIdx = token.find('=')
      if eqIdx >= 0:
        result.add((token[0 ..< eqIdx], token[eqIdx + 1 .. ^1]))
      else:
        result.add((token, ""))

proc updateIsupport*(isup: ISupport, params: seq[string]) =
  ## Update ISUPPORT fields from a 005 numeric's parameters.
  let parsed = parseIsupport(params)
  for (key, value) in parsed:
    isup.raw[key] = value
    case key.toUpperAscii()
    of "MONITOR":
      if value.len > 0:
        try: isup.monitor = parseInt(value)
        except ValueError: isup.monitor = 0
      else:
        isup.monitor = 0
    of "WHOX": isup.whox = true
    of "BOT": isup.bot = value
    of "UTF8ONLY": isup.utf8Only = true
    of "CLIENTTAGDENY":
      isup.clientTagDeny = if value.len > 0: value.split(',') else: @[]
    of "NETWORK": isup.network = value
    of "PREFIX": isup.prefix = value
    of "CHANMODES": isup.chanModes = value
    of "STATUSMSG": isup.statusMsg = value
    of "CHANTYPES": isup.chanTypes = value
    of "MODES":
      try: isup.modes = parseInt(value)
      except ValueError: discard
    of "TARGMAX", "MAXTARGETS":
      if value.len > 0:
        try: isup.maxTargets = parseInt(value)
        except ValueError: discard
    of "NICKLEN", "MAXNICKLEN":
      try: isup.nickLen = parseInt(value)
      except ValueError: discard
    of "TOPICLEN":
      try: isup.topicLen = parseInt(value)
      except ValueError: discard
    of "AWAYLEN":
      try: isup.awayLen = parseInt(value)
      except ValueError: discard
    of "KICKLEN":
      try: isup.kickLen = parseInt(value)
      except ValueError: discard
    of "ACCOUNTEXTBAN":
      isup.accountExtban = if value.len > 0: value.split(',') else: @[]
    of "MSGREFTYPES":
      isup.msgRefTypes = if value.len > 0: value.split(',') else: @[]
    of "DRAFT/ICON":
      isup.icon = value
    else: discard

# ============================================================
# Tag helpers
# ============================================================

proc getMsgId*(msg: IrcMessage): string =
  ## Get the msgid tag from a message, or empty string.
  msg.tags.getOrDefault(tagMsgId, "")

proc getTime*(msg: IrcMessage): string =
  ## Get the time tag from a message, or empty string.
  msg.tags.getOrDefault(tagTime, "")

proc getAccount*(msg: IrcMessage): string =
  ## Get the account tag from a message, or empty string.
  msg.tags.getOrDefault(tagAccount, "")

proc isBot*(msg: IrcMessage): bool =
  ## Check if the message has a bot tag.
  msg.tags.hasKey(tagBot)

proc getBatchRef*(msg: IrcMessage): string =
  ## Get the batch reference tag from a message, or empty string.
  msg.tags.getOrDefault(tagBatch, "")

# ============================================================
# Batch aggregation types
# ============================================================

type
  BatchedMessage* = object
    ## A message collected as part of a batch.
    event*: IrcEvent
    msg*: IrcMessage

  CompletedBatch* = object
    ## A fully aggregated batch with all its messages.
    batchRef*: string
    batchType*: string
    batchParams*: seq[string]
    messages*: seq[BatchedMessage]
    nestedBatches*: seq[CompletedBatch]

  ActiveBatch = object
    batchRef: string
    batchType: string
    batchParams: seq[string]
    parentRef: string          ## Parent batch ref (for nesting)
    messages: seq[BatchedMessage]
    nestedBatches: seq[CompletedBatch]

  BatchAggregator* = ref object
    ## Accumulates messages by batch reference, emitting CompletedBatch when closed.
    activeBatches*: Table[string, ActiveBatch]
    enabled*: bool

proc newBatchAggregator*(enabled: bool = true): BatchAggregator =
  BatchAggregator(
    activeBatches: initTable[string, ActiveBatch](),
    enabled: enabled,
  )

proc processBatch*(agg: BatchAggregator, event: IrcEvent, msg: IrcMessage): Option[CompletedBatch] =
  ## Process a message through the batch aggregator.
  ## Returns Some(CompletedBatch) when a batch completes, None otherwise.
  ## Call this for BATCH start/end events and for messages with a batch tag.
  if not agg.enabled:
    return none(CompletedBatch)

  if event.kind == iekBatch:
    if event.batchStarting:
      # Open a new batch
      var batch = ActiveBatch(
        batchRef: event.batchRef,
        batchType: event.batchType,
        batchParams: event.batchParams,
      )
      # Check if this is a nested batch (has batch tag on the BATCH message itself)
      if msg.tags.hasKey("batch"):
        batch.parentRef = msg.tags["batch"]
      agg.activeBatches[event.batchRef] = batch
      return none(CompletedBatch)
    else:
      # Close a batch
      if event.batchRef in agg.activeBatches:
        let batch = agg.activeBatches[event.batchRef]
        agg.activeBatches.del(event.batchRef)
        let completed = CompletedBatch(
          batchRef: batch.batchRef,
          batchType: batch.batchType,
          batchParams: batch.batchParams,
          messages: batch.messages,
          nestedBatches: batch.nestedBatches,
        )
        # If nested, add to parent batch
        if batch.parentRef.len > 0 and batch.parentRef in agg.activeBatches:
          agg.activeBatches[batch.parentRef].nestedBatches.add(completed)
          return none(CompletedBatch)
        return some(completed)
      return none(CompletedBatch)
  else:
    # Regular message with batch tag — accumulate
    let batchRef = msg.tags.getOrDefault("batch", "")
    if batchRef.len > 0 and batchRef in agg.activeBatches:
      agg.activeBatches[batchRef].messages.add(BatchedMessage(event: event, msg: msg))
      return none(CompletedBatch)
    return none(CompletedBatch)

proc isInBatch*(agg: BatchAggregator, msg: IrcMessage): bool =
  ## Check if a message belongs to an active batch.
  let batchRef = msg.tags.getOrDefault("batch", "")
  batchRef.len > 0 and batchRef in agg.activeBatches

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
        result.tags[tag[0 ..< eqIdx]] = unescapeTagValue(tag[eqIdx + 1 .. ^1])
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

proc formatTagPrefix*(tags: Table[string, string]): string =
  ## Format an IRCv3 tag prefix string: @key=escaped_val;key2=escaped_val2
  if tags.len == 0: return ""
  result = "@"
  var first = true
  for key, value in tags:
    if not first: result.add(';')
    first = false
    result.add(key)
    if value.len > 0:
      result.add('=')
      result.add(escapeTagValue(value))
  result.add(' ')

proc formatTaggedMessage*(tags: Table[string, string], command: string, params: varargs[string]): string =
  ## Format an IRC message with IRCv3 tags prepended.
  result = formatTagPrefix(tags)
  result.add(command)
  for i in 0 ..< params.len:
    result.add(' ')
    if i == params.len - 1:
      result.add(':')
    result.add(params[i])
  result.add("\r\n")

proc formatTagMsg*(target: string, tags: Table[string, string]): string =
  ## Format a TAGMSG (tags-only message, no text body).
  formatTaggedMessage(tags, "TAGMSG", target)

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

  # WHOX
  RPL_WHOSPCRPL* = 354
  RPL_WHOISBOT* = 335

  # STARTTLS
  RPL_STARTTLS* = 670
  ERR_STARTTLS* = 691

  # Metadata (draft/metadata-2)
  RPL_WHOISKEYVALUE* = 760   ## WHOIS metadata key-value
  RPL_KEYVALUE* = 761        ## Key-value response
  RPL_METADATAEND* = 762     ## End of metadata list
  ERR_METADATALIMIT* = 764   ## Too many metadata subscriptions
  ERR_TARGETINVALID* = 765   ## Invalid metadata target
  RPL_KEYNOTSET* = 766       ## Key not set
  ERR_NOMATCHINGKEY* = 767   ## No matching key
  ERR_KEYINVALID* = 768      ## Invalid key name
  ERR_KEYNOPERM* = 769       ## No permission for key
  RPL_METADATASUBOK* = 770   ## Metadata subscribe OK
  RPL_METADATAUNSUBOK* = 771 ## Metadata unsubscribe OK
  RPL_METADATASUBS* = 772    ## Current metadata subscriptions
  RPL_METADATASYNCLATER* = 774 ## Metadata sync later (rate limited)

  # Additional SASL numerics
  ERR_NICKLOCKED* = 902      ## Nick is locked (cannot change during SASL)

  # Misc
  RPL_INVITING* = 341
  ERR_CHANOPRIVSNEEDED* = 482
  ERR_NOSUCHNICK* = 401
  ERR_NOSUCHCHANNEL* = 403
  ERR_CANNOTSENDTOCHAN* = 404
  ERR_NOTONCHANNEL* = 442
  ERR_USERONCHANNEL* = 443

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
    # Standard Replies (IRCv3) — structured parsing
    # Format: FAIL/WARN/NOTE <command> <code> [<context>...] :<description>
    if msg.params.len >= 3:
      let srCmd = msg.params[0]
      let srCode = msg.params[1]
      let srDesc = msg.params[^1]  # Last param is always the trailing description
      let srCtx = if msg.params.len > 3: msg.params[2 ..< msg.params.len - 1] else: @[]
      result = IrcEvent(kind: iekStandardReply, srLevel: msg.command,
                       srCommand: srCmd, srCode: srCode,
                       srContext: srCtx, srDescription: srDesc)
    else:
      # Fallback for malformed standard replies
      let text = msg.params.join(" ")
      result = IrcEvent(kind: iekError, errMsg: "[" & msg.command & "] " & text)

  of "TAGMSG":
    # Tags-only message (no text body)
    if msg.params.len >= 1:
      let target = msg.params[0]
      # Check for typing indicator
      if msg.tags.hasKey(tagTyping):
        let active = msg.tags[tagTyping] == "active"
        result = IrcEvent(kind: iekTyping, typingNick: msg.prefix.nick,
                         typingTarget: target, typingActive: active)
      else:
        result = IrcEvent(kind: iekTagMsg, tagmsgSource: msg.prefix.nick,
                         tagmsgTarget: target, tagmsgTags: msg.tags,
                         tagmsgPrefix: msg.prefix)
    else:
      result = IrcEvent(kind: iekMessage, msg: msg)

  of "REDACT":
    # REDACT <target> <msgid> [:<reason>]
    if msg.params.len >= 2:
      let target = msg.params[0]
      let msgid = msg.params[1]
      let reason = if msg.params.len > 2: msg.params[2] else: ""
      result = IrcEvent(kind: iekRedact, redactTarget: target,
                       redactMsgId: msgid, redactReason: reason,
                       redactBy: msg.prefix.nick)
    else:
      result = IrcEvent(kind: iekMessage, msg: msg)

  of "RENAME":
    # :server RENAME <oldchannel> <newchannel> :<reason>
    if msg.params.len >= 2:
      let oldCh = msg.params[0]
      let newCh = msg.params[1]
      let reason = if msg.params.len > 2: msg.params[2] else: ""
      result = IrcEvent(kind: iekChannelRename, renameOld: oldCh,
                       renameNew: newCh, renameReason: reason)
    else:
      result = IrcEvent(kind: iekMessage, msg: msg)

  of "MARKREAD":
    # MARKREAD <target> [timestamp=<ts>]
    if msg.params.len >= 1:
      let target = msg.params[0]
      let ts = if msg.params.len > 1: msg.params[1] else: ""
      # Strip "timestamp=" prefix if present
      let cleanTs = if ts.startsWith("timestamp="): ts[10..^1] else: ts
      result = IrcEvent(kind: iekMarkread, markreadTarget: target,
                       markreadTimestamp: cleanTs)
    else:
      result = IrcEvent(kind: iekMessage, msg: msg)

  else:
    # Try to parse as numeric
    var numVal: int
    if msg.command.len == 3 and msg.command.allCharsInSet({'0'..'9'}):
      numVal = parseInt(msg.command)
      case numVal
      of RPL_MONONLINE:
        # :server 730 nick :target1!user@host,target2!user@host
        let targets = if msg.params.len > 1: msg.params[^1].split(',').mapIt(it.split('!')[0].strip())
                      else: @[]
        result = IrcEvent(kind: iekMonOnline, monOnlineTargets: targets)
      of RPL_MONOFFLINE:
        # :server 731 nick :target1,target2
        let targets = if msg.params.len > 1: msg.params[^1].split(',').mapIt(it.strip())
                      else: @[]
        result = IrcEvent(kind: iekMonOffline, monOfflineTargets: targets)
      else:
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
      # Hex color: \x04RRGGBB[,RRGGBB] — exactly 6 hex digits required
      let hexStart = i + 1
      var j = hexStart
      var fgDigits = 0
      while j < text.len and text[j] in {'0'..'9', 'a'..'f', 'A'..'F'} and fgDigits < 6:
        inc j; inc fgDigits
      if fgDigits == 6:
        i = j
        if i < text.len and text[i] == ',':
          var k = i + 1
          var bgDigits = 0
          while k < text.len and text[k] in {'0'..'9', 'a'..'f', 'A'..'F'} and bgDigits < 6:
            inc k; inc bgDigits
          if bgDigits == 6:
            i = k
      else:
        inc i  # Just skip the \x04 control char
    else:
      result.add(ch)
      inc i

# ============================================================
# MONITOR formatting
# ============================================================

proc formatMonitorAdd*(targets: varargs[string]): string =
  ## MONITOR + target[,target2,...]
  formatIrcMessage("MONITOR", "+", targets.toSeq.join(","))

proc formatMonitorRemove*(targets: varargs[string]): string =
  ## MONITOR - target[,target2,...]
  formatIrcMessage("MONITOR", "-", targets.toSeq.join(","))

proc formatMonitorClear*(): string =
  ## MONITOR C — clear the monitor list
  formatIrcMessage("MONITOR", "C")

proc formatMonitorList*(): string =
  ## MONITOR L — list current monitor list
  formatIrcMessage("MONITOR", "L")

proc formatMonitorStatus*(): string =
  ## MONITOR S — get current online/offline status
  formatIrcMessage("MONITOR", "S")

# ============================================================
# WHO/WHOX formatting
# ============================================================

proc formatWho*(target: string): string =
  ## Format a standard WHO command.
  formatIrcMessage("WHO", target)

proc formatWhox*(target: string, fields: string = "%tcnuhraf", token: string = ""): string =
  ## Format a WHOX command with field selection.
  ## fields: WHOX field selector (default "%tcnuhraf" = typical useful fields)
  ## token: optional query token for correlating responses
  if token.len > 0:
    formatIrcMessage("WHO", target, fields & "," & token)
  else:
    formatIrcMessage("WHO", target, fields)

# ============================================================
# CHATHISTORY formatting
# ============================================================

proc formatChathistoryLatest*(target: string, msgidOrTimestamp: string, limit: int): string =
  ## CHATHISTORY LATEST <target> <msgid|timestamp|*> <limit>
  formatIrcMessage("CHATHISTORY", "LATEST", target, msgidOrTimestamp, $limit)

proc formatChathistoryBefore*(target: string, msgidOrTimestamp: string, limit: int): string =
  formatIrcMessage("CHATHISTORY", "BEFORE", target, msgidOrTimestamp, $limit)

proc formatChathistoryAfter*(target: string, msgidOrTimestamp: string, limit: int): string =
  formatIrcMessage("CHATHISTORY", "AFTER", target, msgidOrTimestamp, $limit)

proc formatChathistoryBetween*(target: string, start, stop: string, limit: int): string =
  formatIrcMessage("CHATHISTORY", "BETWEEN", target, start, stop, $limit)

proc formatChathistoryAround*(target: string, msgidOrTimestamp: string, limit: int): string =
  formatIrcMessage("CHATHISTORY", "AROUND", target, msgidOrTimestamp, $limit)

proc formatChathistoryTargets*(start, stop: string, limit: int): string =
  formatIrcMessage("CHATHISTORY", "TARGETS", start, stop, $limit)

# ============================================================
# REDACT formatting
# ============================================================

proc formatRedact*(target, msgid: string, reason: string = ""): string =
  ## Format a REDACT command.
  if reason.len > 0:
    formatIrcMessage("REDACT", target, msgid, reason)
  else:
    formatIrcMessage("REDACT", target, msgid)

# ============================================================
# Account Registration formatting
# ============================================================

proc formatRegister*(account: string, email: string = "*", password: string = "*"): string =
  ## REGISTER <account> <email> <password>
  formatIrcMessage("REGISTER", account, email, password)

proc formatVerify*(account, code: string): string =
  ## VERIFY <account> <code>
  formatIrcMessage("VERIFY", account, code)

# ============================================================
# METADATA formatting
# ============================================================

proc formatMetadataGet*(target: string, keys: seq[string]): string =
  ## METADATA GET <target> <key> [<key>...]
  result = "METADATA GET " & target
  for k in keys: result.add(" " & k)
  result.add("\r\n")

proc formatMetadataSet*(target, key, value: string): string =
  formatIrcMessage("METADATA", "SET", target, key, value)

proc formatMetadataClear*(target, key: string): string =
  formatIrcMessage("METADATA", "SET", target, key)

proc formatMetadataList*(target: string): string =
  formatIrcMessage("METADATA", "LIST", target)

proc formatMetadataSub*(target: string, keys: seq[string]): string =
  ## METADATA SUB <target> <key> [<key>...]
  result = "METADATA SUB " & target
  for k in keys: result.add(" " & k)
  result.add("\r\n")

proc formatMetadataUnsub*(target: string, keys: seq[string]): string =
  ## METADATA UNSUB <target> <key> [<key>...]
  result = "METADATA UNSUB " & target
  for k in keys: result.add(" " & k)
  result.add("\r\n")

# ============================================================
# MARKREAD formatting
# ============================================================

proc formatMarkread*(target, timestamp: string): string =
  ## MARKREAD <target> timestamp=<ts>
  formatIrcMessage("MARKREAD", target, "timestamp=" & timestamp)

# ============================================================
# WEBIRC formatting
# ============================================================

proc formatWebirc*(password, gateway, hostname, ip: string,
                   options: seq[string] = @[]): string =
  ## WEBIRC <password> <gateway> <hostname> <ip> [<options>...]
  result = "WEBIRC " & password & " " & gateway & " " & hostname & " " & ip
  for opt in options: result.add(" " & opt)
  result.add("\r\n")

# ============================================================
# Multiline message assembly
# ============================================================

# ============================================================
# STARTTLS formatting
# ============================================================

proc formatStarttls*(): string =
  ## Format a STARTTLS command to initiate TLS negotiation.
  formatIrcMessage("STARTTLS")

# ============================================================
# AUTHENTICATE formatting
# ============================================================

proc formatAuthenticate*(payload: string): string =
  ## Format an AUTHENTICATE command with the given payload.
  ## payload should be base64-encoded or "*" to abort.
  formatIrcMessage("AUTHENTICATE", payload)

# ============================================================
# CLIENTTAGDENY enforcement
# ============================================================

proc isTagAllowed*(isup: ISupport, tagName: string): bool =
  ## Check if a client tag is allowed based on CLIENTTAGDENY ISUPPORT.
  ## Returns true if the tag is allowed, false if denied.
  ## Per spec: only applies to tags starting with "+" (client-only tags).
  if not tagName.startsWith("+"):
    return true  # Not a client-only tag, always allowed
  if isup.clientTagDeny.len == 0:
    return true  # No restrictions
  # Check for wildcard deny-all
  if "*" in isup.clientTagDeny:
    # All client tags denied, but check for explicit allows (prefixed with "-")
    # This is not standard but a reasonable extension
    return false
  # Check explicit deny list
  for deny in isup.clientTagDeny:
    if deny == tagName or deny == tagName[1..^1]:  # Match with or without "+"
      return false
  return true

proc filterAllowedTags*(isup: ISupport, tags: Table[string, string]): Table[string, string] =
  ## Filter a set of tags to only include those allowed by CLIENTTAGDENY.
  result = initTable[string, string]()
  for key, value in tags:
    if isup.isTagAllowed(key):
      result[key] = value

# ============================================================
# Multiline message assembly
# ============================================================

proc assembleMultiline*(batch: CompletedBatch): string =
  ## Assemble a multiline batch into a single string.
  ## Lines with the draft/multiline-concat tag join without newline.
  for i, bm in batch.messages:
    if i > 0 and not bm.msg.tags.hasKey(tagMultilineConcat):
      result.add('\n')
    if bm.event.kind == iekPrivMsg:
      result.add(bm.event.pmText)
    elif bm.event.kind == iekNotice:
      result.add(bm.event.pmText)
