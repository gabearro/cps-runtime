## CPS IRC Client
##
## Event-driven IRC client built on the CPS runtime.
## Supports proxy connections (SOCKS4/4a, SOCKS5, HTTP CONNECT),
## TLS/SSL, IRCv3 CAP negotiation, SASL PLAIN authentication,
## automatic reconnection with exponential backoff, lag tracking,
## and CTCP/DCC message handling.
##
## The client emits events via an AsyncChannel[IrcEvent] that consumers
## can read to build higher-level applications (bots, indexers, etc.).

## (no stdlib imports needed)
import ../runtime
import ../transform
import ../eventloop
import ../io/streams
import ../io/tcp
import ../io/buffered
import ../io/proxy
import ../concurrency/channels
import ../tls/client as tlsclient
import ./protocol
import ./sasl
import std/[times, base64, strutils, tables, options, sequtils, nativesockets]
from std/posix import shutdown, SHUT_RDWR

export protocol

type
  IrcClientState* = enum
    icsDisconnected
    icsConnecting
    icsRegistering
    icsConnected

  IrcClientConfig* = object
    ## Configuration for an IRC client connection.
    host*: string              ## IRC server hostname
    port*: int                 ## IRC server port (default 6667)
    nick*: string              ## Desired nickname
    username*: string          ## Username (ident)
    realname*: string          ## Real name (GECOS)
    password*: string          ## Server password (empty = none)
    proxies*: seq[ProxyConfig] ## Proxy chain (empty = direct)
    autoReconnect*: bool       ## Auto-reconnect on disconnect
    reconnectDelayMs*: int     ## Delay between reconnect attempts
    maxReconnectAttempts*: int ## Max reconnect attempts (0 = unlimited)
    pingTimeoutMs*: int        ## PING timeout (default 120000)
    autoJoinChannels*: seq[string] ## Channels to join on connect
    ctcpVersion*: string       ## CTCP VERSION reply
    eventBufferSize*: int      ## Event channel buffer size (default 256)
    useTls*: bool              ## Use TLS/SSL (default false, port 6697)
    saslUsername*: string       ## SASL PLAIN username (empty = no SASL)
    saslPassword*: string       ## SASL PLAIN password
    requestedCaps*: seq[string] ## IRCv3 capabilities to request
    aggregateBatches*: bool     ## Aggregate BATCH messages (default false for backward compat)
    initialAway*: string        ## Initial AWAY message (pre-away cap, empty = not away)
    webircPassword*: string     ## WEBIRC password (empty = no WEBIRC)
    webircGateway*: string      ## WEBIRC gateway name
    webircHostname*: string     ## WEBIRC hostname
    webircIp*: string           ## WEBIRC IP address
    saslMechanism*: SaslMechanism ## Pluggable SASL mechanism (nil = use saslUsername/saslPassword → PLAIN)

  IrcClient* = ref object
    ## An event-driven IRC client.
    config*: IrcClientConfig
    state*: IrcClientState
    currentNick*: string       ## Current effective nickname
    events*: AsyncChannel[IrcEvent] ## Event stream for consumers
    stream: AsyncStream
    reader: BufferedReader
    reconnectAttempts: int
    registered: bool
    enabledCaps*: seq[string]   ## Successfully negotiated capabilities
    capNegotiating: bool        ## True during CAP negotiation
    saslState: int              ## 0=none, 1=waitingAck, 2=waitingAuth, 3=waitingResult
    lastPingSent*: float        ## epochTime when last PING sent
    lastDataReceived*: float    ## epochTime when last data received from server
    lagMs*: int                 ## Current lag in milliseconds (-1 = unknown)
    isAway*: bool               ## True if marked away
    isupport*: ISupport         ## Parsed ISUPPORT (005) parameters
    batchAggregator*: BatchAggregator  ## Batch message aggregator
    nextLabel: int              ## Auto-incrementing label counter
    pendingLabels: Table[string, CpsFuture[CompletedBatch]] ## Pending labeled-response futures
    serverSaslMechs: seq[string] ## SASL mechanisms advertised by server
    pendingCapLs: seq[string]   ## Accumulates caps across multiline CAP LS 302 responses

# ============================================================
# Config constructors
# ============================================================

proc newIrcClientConfig*(host: string, port: int = 6667,
                         nick: string = "cpsbot",
                         username: string = "cps",
                         realname: string = "CPS IRC Client"): IrcClientConfig =
  IrcClientConfig(
    host: host,
    port: port,
    nick: nick,
    username: username,
    realname: realname,
    autoReconnect: true,
    reconnectDelayMs: 5000,
    maxReconnectAttempts: 0,
    pingTimeoutMs: 120_000,
    ctcpVersion: "CPS IRC Client 1.0",
    eventBufferSize: 256,
    useTls: false,
    requestedCaps: @[capServerTime, capMessageTags, capAwayNotify, capAccountNotify,
                     capExtendedJoin, capMultiPrefix, capCapNotify, capChghost,
                     capSetname, capInviteNotify, capUserhostInNames, capSasl, capBatch,
                     capLabeledResponse, capEchoMessage, capAccountTag,
                     capStandardReplies, capTls,
                     capSolanumIdentifyMsg, capSolanumOper, capSolanumRealhost,
                     capDraftChathistory, capDraftMessageRedaction, capDraftChannelRename,
                     capDraftReadMarker, capDraftMultiline,
                     capMonitor, capDraftPreAway, capDraftNoImplicitNames,
                     capDraftExtendedIsupport, capDraftEventPlayback,
                     capDraftExtendedMonitor, capDraftAccountRegistration,
                     capDraftMetadata2],
  )

# ============================================================
# Client creation
# ============================================================

proc newIrcClient*(config: IrcClientConfig): IrcClient =
  IrcClient(
    config: config,
    state: icsDisconnected,
    currentNick: config.nick,
    events: newAsyncChannel[IrcEvent](config.eventBufferSize),
    lagMs: -1,
    isupport: newISupport(),
    batchAggregator: newBatchAggregator(config.aggregateBatches),
    pendingLabels: initTable[string, CpsFuture[CompletedBatch]](),
  )

proc newIrcClient*(host: string, port: int = 6667,
                   nick: string = "cpsbot"): IrcClient =
  let config = newIrcClientConfig(host, port, nick)
  newIrcClient(config)

# ============================================================
# Internal: send raw data
# ============================================================

proc sendRaw(client: IrcClient, data: string): CpsVoidFuture =
  ## Send raw data to the IRC server.
  if client.stream == nil or client.stream.closed:
    let fut = newCpsVoidFuture()
    fut.fail(newException(AsyncIoError, "Not connected"))
    return fut
  client.stream.write(data)

# ============================================================
# Public: send IRC commands
# ============================================================

proc sendMessage*(client: IrcClient, command: string, params: varargs[string]): CpsVoidFuture =
  ## Send a formatted IRC message.
  client.sendRaw(formatIrcMessage(command, params))

proc joinChannel*(client: IrcClient, channel: string, key: string = ""): CpsVoidFuture =
  client.sendRaw(formatJoin(channel, key))

proc partChannel*(client: IrcClient, channel: string, reason: string = ""): CpsVoidFuture =
  client.sendRaw(formatPart(channel, reason))

proc privMsg*(client: IrcClient, target, text: string): CpsVoidFuture =
  client.sendRaw(formatPrivMsg(target, text))

proc notice*(client: IrcClient, target, text: string): CpsVoidFuture =
  client.sendRaw(formatNotice(target, text))

proc ctcpSend*(client: IrcClient, target, command: string, args: string = ""): CpsVoidFuture =
  client.sendRaw(formatCtcp(target, command, args))

proc ctcpReply*(client: IrcClient, target, command: string, args: string = ""): CpsVoidFuture =
  client.sendRaw(formatCtcpReply(target, command, args))

proc changeNick*(client: IrcClient, newNick: string): CpsVoidFuture =
  client.currentNick = newNick
  client.sendRaw(formatNick(newNick))

proc quit*(client: IrcClient, reason: string = ""): CpsVoidFuture =
  client.sendRaw(formatQuit(reason))

proc sendPing*(client: IrcClient, token: string = "lagcheck"): CpsVoidFuture =
  ## Send a PING to measure lag. Sets lastPingSent timestamp.
  client.lastPingSent = epochTime()
  client.sendRaw(formatIrcMessage("PING", token))

proc sendTagged*(client: IrcClient, tags: Table[string, string],
                  command: string, params: varargs[string]): CpsVoidFuture =
  ## Send an IRC message with tags.
  client.sendRaw(formatTaggedMessage(tags, command, params))

# ============================================================
# MONITOR commands
# ============================================================

proc monitorAdd*(client: IrcClient, targets: varargs[string]): CpsVoidFuture =
  client.sendRaw(formatMonitorAdd(targets))

proc monitorRemove*(client: IrcClient, targets: varargs[string]): CpsVoidFuture =
  client.sendRaw(formatMonitorRemove(targets))

proc monitorClear*(client: IrcClient): CpsVoidFuture =
  client.sendRaw(formatMonitorClear())

proc monitorList*(client: IrcClient): CpsVoidFuture =
  client.sendRaw(formatMonitorList())

proc monitorStatus*(client: IrcClient): CpsVoidFuture =
  client.sendRaw(formatMonitorStatus())

# ============================================================
# CHATHISTORY commands
# ============================================================

proc chathistoryLatest*(client: IrcClient, target: string, msgidOrTimestamp: string = "*", limit: int = 50): CpsVoidFuture =
  client.sendRaw(formatChathistoryLatest(target, msgidOrTimestamp, limit))

proc chathistoryBefore*(client: IrcClient, target, msgidOrTimestamp: string, limit: int = 50): CpsVoidFuture =
  client.sendRaw(formatChathistoryBefore(target, msgidOrTimestamp, limit))

proc chathistoryAfter*(client: IrcClient, target, msgidOrTimestamp: string, limit: int = 50): CpsVoidFuture =
  client.sendRaw(formatChathistoryAfter(target, msgidOrTimestamp, limit))

proc chathistoryBetween*(client: IrcClient, target: string, start, stop: string, limit: int = 50): CpsVoidFuture =
  client.sendRaw(formatChathistoryBetween(target, start, stop, limit))

proc chathistoryAround*(client: IrcClient, target, msgidOrTimestamp: string, limit: int = 50): CpsVoidFuture =
  client.sendRaw(formatChathistoryAround(target, msgidOrTimestamp, limit))

proc chathistoryTargets*(client: IrcClient, start, stop: string, limit: int = 50): CpsVoidFuture =
  client.sendRaw(formatChathistoryTargets(start, stop, limit))

# ============================================================
# REDACT
# ============================================================

proc redact*(client: IrcClient, target, msgid: string, reason: string = ""): CpsVoidFuture =
  client.sendRaw(formatRedact(target, msgid, reason))

# ============================================================
# Client-only tags: reply, react, typing
# ============================================================

proc replyTo*(client: IrcClient, target, msgid, text: string): CpsVoidFuture =
  ## Send a PRIVMSG with +draft/reply tag.
  var tags = initTable[string, string]()
  tags[tagReply] = msgid
  client.sendRaw(formatTaggedMessage(tags, "PRIVMSG", target, text))

proc react*(client: IrcClient, target, msgid, reaction: string): CpsVoidFuture =
  ## Send a TAGMSG with +draft/react tag.
  var tags = initTable[string, string]()
  tags[tagReact] = reaction
  tags[tagReply] = msgid
  client.sendRaw(formatTagMsg(target, tags))

proc unreact*(client: IrcClient, target, msgid, reaction: string): CpsVoidFuture =
  ## Send a TAGMSG with +draft/unreact tag.
  var tags = initTable[string, string]()
  tags[tagUnreact] = reaction
  tags[tagReply] = msgid
  client.sendRaw(formatTagMsg(target, tags))

proc sendTyping*(client: IrcClient, target: string, active: bool = true): CpsVoidFuture =
  ## Send a TAGMSG with +typing tag.
  var tags = initTable[string, string]()
  tags[tagTyping] = if active: "active" else: "done"
  client.sendRaw(formatTagMsg(target, tags))

proc sendWithChannelContext*(client: IrcClient, target, channel, text: string): CpsVoidFuture =
  ## Send a PRIVMSG with +draft/channel-context tag.
  var tags = initTable[string, string]()
  tags[tagChannelContext] = channel
  client.sendRaw(formatTaggedMessage(tags, "PRIVMSG", target, text))

# ============================================================
# Multiline messages
# ============================================================

proc sendMultiline*(client: IrcClient, target, text: string): CpsVoidFuture {.cps.} =
  ## Send a multiline message. Uses draft/multiline batch if cap is enabled,
  ## otherwise falls back to multiple PRIVMSGs.
  let lines = text.split('\n')
  let lineCount = lines.len
  if lineCount <= 1 or "draft/multiline" notin client.enabledCaps:
    # Simple fallback: send each line as separate PRIVMSG
    for idx in 0 ..< lineCount:
      if lines[idx].len > 0:
        await client.privMsg(target, lines[idx])
  else:
    # Use multiline batch
    client.nextLabel += 1
    let batchRef = "ml" & $client.nextLabel
    await client.sendRaw(formatIrcMessage("BATCH", "+" & batchRef, "draft/multiline", target))
    for idx in 0 ..< lineCount:
      var tags = initTable[string, string]()
      tags[tagBatch] = batchRef
      await client.sendRaw(formatTaggedMessage(tags, "PRIVMSG", target, lines[idx]))
    await client.sendRaw(formatIrcMessage("BATCH", "-" & batchRef))

# ============================================================
# Labeled-response
# ============================================================

proc generateLabel(client: IrcClient): string =
  client.nextLabel += 1
  result = $client.nextLabel

proc sendLabeled*(client: IrcClient, command: string, params: seq[string]): CpsFuture[CompletedBatch] {.cps.} =
  ## Send a command with a label tag and return the labeled-response batch.
  let label = client.generateLabel()
  var tags = initTable[string, string]()
  tags[tagLabel] = label

  let labelFut = newCpsFuture[CompletedBatch]()
  client.pendingLabels[label] = labelFut

  # Build and send the tagged message
  let paramCount = params.len
  var msgStr = formatTagPrefix(tags) & command
  for i in 0 ..< paramCount:
    msgStr.add(' ')
    if i == paramCount - 1:
      msgStr.add(':')
    msgStr.add(params[i])
  msgStr.add("\r\n")
  await client.sendRaw(msgStr)

  let batchResult: CompletedBatch = await labelFut
  return batchResult

# ============================================================
# Account registration
# ============================================================

proc register*(client: IrcClient, account: string, email: string = "*", password: string = "*"): CpsVoidFuture =
  client.sendRaw(formatRegister(account, email, password))

proc verify*(client: IrcClient, account, code: string): CpsVoidFuture =
  client.sendRaw(formatVerify(account, code))

# ============================================================
# MARKREAD
# ============================================================

proc markread*(client: IrcClient, target, timestamp: string): CpsVoidFuture =
  client.sendRaw(formatMarkread(target, timestamp))

# ============================================================
# WEBIRC
# ============================================================

proc sendWebirc*(client: IrcClient, password, gateway, hostname, ip: string,
                 options: seq[string] = @[]): CpsVoidFuture =
  client.sendRaw(formatWebirc(password, gateway, hostname, ip, options))

# ============================================================
# WHO/WHOX
# ============================================================

proc who*(client: IrcClient, target: string): CpsVoidFuture =
  client.sendRaw(formatWho(target))

proc whox*(client: IrcClient, target: string, fields: string = "%tcnuhraf", token: string = ""): CpsVoidFuture =
  client.sendRaw(formatWhox(target, fields, token))

# ============================================================
# Internal: emit events
# ============================================================

proc emit(client: IrcClient, event: IrcEvent): CpsVoidFuture =
  client.events.send(event)

# ============================================================
# Internal: handle registration
# ============================================================

proc doRegister(client: IrcClient): CpsVoidFuture {.cps.} =
  ## Send CAP LS, NICK/USER (and optionally PASS/WEBIRC) to register.
  ## CAP negotiation and SASL are handled in processMessage.

  # WEBIRC must be sent before any other commands
  if client.config.webircPassword.len > 0:
    await client.sendRaw(formatWebirc(client.config.webircPassword,
      client.config.webircGateway, client.config.webircHostname, client.config.webircIp))

  # Start IRCv3 CAP negotiation
  if client.config.requestedCaps.len > 0:
    client.capNegotiating = true
    await client.sendRaw(formatIrcMessage("CAP", "LS", "302"))

  if client.config.password.len > 0:
    await client.sendRaw(formatPass(client.config.password))
  await client.sendRaw(formatNick(client.config.nick))
  await client.sendRaw(formatUser(client.config.username, client.config.realname))

# ============================================================
# Internal: handle CTCP requests
# ============================================================

proc handleCtcp(client: IrcClient, source, command, args: string): CpsVoidFuture {.cps.} =
  ## Handle incoming CTCP requests with auto-replies.
  case command
  of "VERSION":
    if client.config.ctcpVersion.len > 0:
      await client.ctcpReply(source, "VERSION", client.config.ctcpVersion)
  of "PING":
    await client.ctcpReply(source, "PING", args)
  of "TIME":
    await client.ctcpReply(source, "TIME", now().format("ddd MMM dd HH:mm:ss yyyy"))
  else:
    discard

# ============================================================
# Internal: process a single message
# ============================================================

proc completeLabeledBatch(client: IrcClient, batch: CompletedBatch) =
  ## Check if a completed batch has a label tag and resolve the pending future.
  # Labeled batches have the label on the opening BATCH command
  # We check if any pending label matches
  discard  # Label resolution happens via the batch ref label tracking below

proc processMessage(client: IrcClient, msg: IrcMessage): CpsVoidFuture {.cps.} =
  ## Process a parsed IRC message and emit appropriate events.
  let event = classifyMessage(msg)

  # Batch aggregation: if enabled, feed through aggregator
  if client.batchAggregator.enabled:
    if event.kind == iekBatch or client.batchAggregator.isInBatch(msg):
      let batchResult = client.batchAggregator.processBatch(event, msg)
      if batchResult.isSome:
        let completedBatch = batchResult.get()

        # Check for labeled-response: look for label tag
        let label = msg.tags.getOrDefault(tagLabel, "")

        if label.len > 0 and label in client.pendingLabels:
          let pendingFut = client.pendingLabels[label]
          client.pendingLabels.del(label)
          pendingFut.complete(completedBatch)
        else:
          # Emit as iekCompletedBatch event
          await client.emit(IrcEvent(kind: iekCompletedBatch,
            cbBatchRef: completedBatch.batchRef,
            cbBatchType: completedBatch.batchType,
            cbBatchParams: completedBatch.batchParams,
            cbMessages: completedBatch.messages.mapIt(it.event),
            cbNestedBatches: @[]))
      # Suppress individual events while batching (except batch start/end which we track)
      if event.kind != iekBatch:
        return
      # For iekBatch events, still emit them for backward compat
      # but skip further processing
      await client.emit(event)
      return

  case event.kind
  of iekPing:
    await client.sendRaw(formatPong(event.pingToken))
    await client.emit(event)

  of iekPong:
    # Lag measurement: compute round-trip time
    if client.lastPingSent > 0:
      client.lagMs = int((epochTime() - client.lastPingSent) * 1000)
    await client.emit(event)

  of iekCap:
    # IRCv3 CAP negotiation
    case event.capSubcommand
    of "LS":
      # CAP LS 302 multiline support:
      # :server CAP nick LS * :cap1 cap2   (more coming — "*" is capParams[0])
      # :server CAP nick LS :cap3 cap4     (final — no "*")
      let isMultiline = event.capParams.len >= 2 and event.capParams[0] == "*"
      let capListStr = if isMultiline: event.capParams[1]
                       elif event.capParams.len > 0: event.capParams[0]
                       else: ""
      let lineCaps = capListStr.split(' ')
      for c in lineCaps:
        if c.len > 0:
          client.pendingCapLs.add(c)

      if isMultiline:
        # More LS lines coming — wait for the final one
        discard
      else:
        # Final LS line — process all accumulated caps
        let available = client.pendingCapLs
        client.pendingCapLs = @[]

        var toRequest: seq[string] = @[]
        for cap in client.config.requestedCaps:
          for avail in available:
            # Handle caps with values like "sasl=PLAIN,EXTERNAL"
            let capName = if avail.contains('='): avail.split('=')[0] else: avail
            if capName == cap:
              toRequest.add(cap)
              # Track SASL mechanisms advertised by server
              if capName == "sasl" and avail.contains('='):
                client.serverSaslMechs = avail.split('=')[1].split(',')
              break
        if toRequest.len > 0:
          await client.sendRaw(formatIrcMessage("CAP", "REQ", toRequest.join(" ")))
        else:
          client.capNegotiating = false
          await client.sendRaw(formatIrcMessage("CAP", "END"))
    of "ACK":
      let acked = if event.capParams.len > 0: event.capParams[0].split(' ') else: @[]
      for cap in acked:
        let cleanCap = cap.strip()
        if cleanCap.len > 0 and cleanCap notin client.enabledCaps:
          client.enabledCaps.add(cleanCap)
      # Check if SASL should be initiated
      if "sasl" in client.enabledCaps and
         (client.config.saslUsername.len > 0 or client.config.saslMechanism != nil):
        client.saslState = 1
        # Determine mechanism
        var mechName = "PLAIN"
        if client.config.saslMechanism != nil:
          mechName = client.config.saslMechanism.name
        elif client.serverSaslMechs.len > 0:
          # Auto-select best mechanism based on server's list
          let autoMech = selectBestMechanism(client.serverSaslMechs,
            client.config.saslUsername, client.config.saslPassword)
          client.config.saslMechanism = autoMech
          mechName = autoMech.name
        else:
          # Default to PLAIN using username/password
          client.config.saslMechanism = newSaslPlain(
            client.config.saslUsername, client.config.saslPassword)
        await client.sendRaw(formatIrcMessage("AUTHENTICATE", mechName))
      else:
        client.capNegotiating = false
        await client.sendRaw(formatIrcMessage("CAP", "END"))
    of "NAK":
      # Capabilities rejected — end negotiation
      client.capNegotiating = false
      await client.sendRaw(formatIrcMessage("CAP", "END"))
    of "NEW":
      # Server offers new caps (cap-notify) — request any we want
      let newCaps = if event.capParams.len > 0: event.capParams[0].split(' ') else: @[]
      var toRequest: seq[string] = @[]
      for cap in client.config.requestedCaps:
        if cap notin client.enabledCaps:
          for avail in newCaps:
            let capName = if avail.contains('='): avail.split('=')[0] else: avail
            if capName == cap:
              toRequest.add(cap)
              if capName == "sasl" and avail.contains('='):
                client.serverSaslMechs = avail.split('=')[1].split(',')
              break
      if toRequest.len > 0:
        await client.sendRaw(formatIrcMessage("CAP", "REQ", toRequest.join(" ")))
      await client.emit(event)
    of "DEL":
      # Server removed caps
      let removed = if event.capParams.len > 0: event.capParams[0].split(' ') else: @[]
      for cap in removed:
        let idx = client.enabledCaps.find(cap.strip())
        if idx >= 0: client.enabledCaps.delete(idx)
      await client.emit(event)
    else:
      await client.emit(event)

  of iekMessage:
    # Handle AUTHENTICATE challenge
    if msg.command == "AUTHENTICATE":
      if client.saslState >= 1 and msg.params.len > 0:
        let challenge = msg.params[0]
        if client.config.saslMechanism != nil:
          let stepResult = client.config.saslMechanism.processChallenge(challenge)
          if stepResult.failed:
            client.saslState = 0
            client.capNegotiating = false
            await client.sendRaw(formatIrcMessage("AUTHENTICATE", "*"))
            await client.sendRaw(formatIrcMessage("CAP", "END"))
            await client.emit(IrcEvent(kind: iekError, errMsg: "SASL failed: " & stepResult.errorMsg))
          elif stepResult.response.len > 0:
            client.saslState = 2
            await client.sendRaw(formatIrcMessage("AUTHENTICATE", stepResult.response))
            if stepResult.finished:
              client.saslState = 3  # Waiting for server result
          else:
            # Empty response with finished=true means no response needed
            client.saslState = 3
        else:
          # Legacy fallback: SASL PLAIN with username/password
          if challenge == "+":
            let payload = "\0" & client.config.saslUsername & "\0" & client.config.saslPassword
            let encoded = base64.encode(payload)
            client.saslState = 2
            await client.sendRaw(formatIrcMessage("AUTHENTICATE", encoded))
          else:
            await client.emit(event)
      else:
        await client.emit(event)
    else:
      await client.emit(event)

  of iekNumeric:
    case event.numCode
    of RPL_WELCOME:
      client.registered = true
      client.state = icsConnected
      client.reconnectAttempts = 0
      if event.numParams.len > 0:
        client.currentNick = event.numParams[0]
      await client.emit(IrcEvent(kind: iekConnected))
      # Send initial AWAY if pre-away cap is enabled
      if client.config.initialAway.len > 0 and "draft/pre-away" in client.enabledCaps:
        await client.sendRaw(formatIrcMessage("AWAY", client.config.initialAway))
        client.isAway = true
      for ch in client.config.autoJoinChannels:
        await client.joinChannel(ch)
      await client.emit(event)

    of RPL_ISUPPORT:
      # Parse ISUPPORT tokens
      client.isupport.updateIsupport(event.numParams)
      await client.emit(event)

    of ERR_NICKNAMEINUSE:
      client.currentNick = client.currentNick & "_"
      await client.sendRaw(formatNick(client.currentNick))
      await client.emit(event)

    of 903:  # RPL_SASLSUCCESS
      client.saslState = 0
      client.capNegotiating = false
      await client.sendRaw(formatIrcMessage("CAP", "END"))
      await client.emit(event)

    of 904, 905, 906:  # RPL_SASLFAIL, RPL_SASLTOOLONG, RPL_SASLABORTED
      client.saslState = 0
      client.capNegotiating = false
      await client.sendRaw(formatIrcMessage("CAP", "END"))
      await client.emit(IrcEvent(kind: iekError, errMsg: "SASL authentication failed"))
      await client.emit(event)

    of 907:  # RPL_SASLALREADY
      client.saslState = 0
      await client.emit(event)

    else:
      await client.emit(event)

  of iekCtcp:
    await client.handleCtcp(event.ctcpSource, event.ctcpCommand, event.ctcpArgs)
    await client.emit(event)

  of iekNick:
    if event.nickOld == client.currentNick:
      client.currentNick = event.nickNew
    await client.emit(event)

  else:
    await client.emit(event)

# ============================================================
# Internal: read loop
# ============================================================

proc readLoop(client: IrcClient): CpsVoidFuture {.cps.} =
  ## Main read loop: reads lines from the server, parses and processes them.
  ## Handles stream errors gracefully (e.g., when keepAliveLoop force-closes
  ## the stream due to ping timeout).
  var streamError = false
  while not streamError and client.stream != nil and not client.stream.closed:
    try:
      let line = await client.reader.readLine("\r\n")
      if line.len == 0 and client.reader.atEof:
        streamError = true
      elif line.len > 0:
        client.lastDataReceived = epochTime()
        let msg = parseIrcMessage(line)
        if msg.command.len > 0:
          await client.processMessage(msg)
    except CatchableError:
      streamError = true  # Stream error (e.g., force-closed by keepAliveLoop)

# ============================================================
# Internal: keep-alive / ping timeout
# ============================================================

proc abortSocket(client: IrcClient) =
  ## Shutdown the underlying socket to force pending reads to return EOF.
  ## Unlike close(), shutdown() causes the selector to fire readable events
  ## so that blocked reads in readLoop get an EOF/error immediately.
  if client.stream == nil:
    return
  var fd: SocketHandle = osInvalidSocket
  if client.stream of tlsclient.TlsStream:
    fd = tlsclient.TlsStream(client.stream).tcpStream.fd
  elif client.stream of ProxyStream:
    let tcp = ProxyStream(client.stream).getUnderlyingTcpStream()
    fd = tcp.fd
  elif client.stream of TcpStream:
    fd = TcpStream(client.stream).fd
  if fd != osInvalidSocket:
    discard shutdown(fd, SHUT_RDWR)

proc keepAliveLoop(client: IrcClient): CpsVoidFuture {.cps.} =
  ## Periodically send PINGs and detect dead connections.
  ## If no data is received within pingTimeoutMs, shutdown the socket
  ## to trigger reconnection via readLoop exit.
  let timeoutMs = client.config.pingTimeoutMs
  let checkIntervalMs = max(timeoutMs div 3, 1000)
  var done = false

  while not done and client.stream != nil and not client.stream.closed:
    await cpsSleep(checkIntervalMs)

    if client.stream == nil or client.stream.closed:
      done = true
    elif client.state != icsConnected:
      # Not yet registered, skip pinging
      discard
    else:
      let now = epochTime()
      let silentMs = int((now - client.lastDataReceived) * 1000)

      if silentMs >= timeoutMs:
        # No data for the full timeout period — connection is dead.
        # Use shutdown() instead of close() so pending reads get EOF.
        await client.emit(IrcEvent(kind: iekError,
          errMsg: "Ping timeout (" & $(timeoutMs div 1000) & "s)"))
        client.abortSocket()
        done = true
      elif silentMs >= checkIntervalMs:
        # Server has been quiet — send a PING to probe
        try:
          await client.sendPing("keepalive")
        except CatchableError:
          done = true  # Send failed, stream is broken

# ============================================================
# Internal: establish connection
# ============================================================

proc connectToServer(client: IrcClient): CpsFuture[bool] {.cps.} =
  ## Establish TCP connection (directly or through proxies).
  ## Optionally wraps with TLS if useTls is configured.
  ## Returns true on success.
  client.state = icsConnecting

  try:
    var stream: AsyncStream
    if client.config.proxies.len > 0:
      let ps = await proxyChainConnect(client.config.proxies,
                                        client.config.host, client.config.port)
      if client.config.useTls:
        # TLS over proxy tunnel
        let tcp = ps.getUnderlyingTcpStream()
        let tls = tlsclient.newTlsStream(tcp, client.config.host, alpnProtocols = @[])
        await tlsclient.tlsConnect(tls)
        stream = tls.AsyncStream
      else:
        stream = ps.AsyncStream
    else:
      let tcp = await tcpConnect(client.config.host, client.config.port)
      if client.config.useTls:
        let tls = tlsclient.newTlsStream(tcp, client.config.host, alpnProtocols = @[])
        await tlsclient.tlsConnect(tls)
        stream = tls.AsyncStream
      else:
        stream = tcp.AsyncStream

    client.stream = stream
    client.reader = newBufferedReader(stream)
    client.state = icsRegistering
    client.registered = false
    return true
  except CatchableError as e:
    await client.emit(IrcEvent(kind: iekError, errMsg: "Connection failed: " & e.msg))
    client.state = icsDisconnected
    return false

# ============================================================
# Public: run the client
# ============================================================

proc run*(client: IrcClient): CpsVoidFuture {.cps.} =
  ## Start the IRC client. Connects, registers, and enters the read loop.
  ## On disconnect, optionally reconnects based on config.
  ## This is the main entry point — call it and read events from client.events.
  while true:
    let connected = await client.connectToServer()
    if connected:
      client.lastDataReceived = epochTime()
      await client.doRegister()

      # Start keep-alive loop in background (runs concurrently via event loop).
      # It sends periodic PINGs and force-closes the stream on timeout.
      let keepAliveFut = keepAliveLoop(client)

      await client.readLoop()

      # readLoop exited — cancel keep-alive (it will also exit on its own
      # when it sees the stream is closed/nil, but cancel is immediate)
      keepAliveFut.cancel()

      # Disconnected
      client.state = icsDisconnected
      if client.stream != nil:
        client.stream.close()
        client.stream = nil
      await client.emit(IrcEvent(kind: iekDisconnected, reason: "Connection lost"))

    if not client.config.autoReconnect:
      break

    client.reconnectAttempts += 1
    if client.config.maxReconnectAttempts > 0 and
       client.reconnectAttempts > client.config.maxReconnectAttempts:
      await client.emit(IrcEvent(kind: iekError, errMsg: "Max reconnect attempts reached"))
      break

    # Exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s max
    let baseDelay = 1000
    let maxDelay = 30000
    let delay = min(maxDelay, baseDelay * (1 shl min(client.reconnectAttempts - 1, 4)))
    await client.emit(IrcEvent(kind: iekError, errMsg: "Reconnecting in " & $(delay div 1000) & "s..."))
    await cpsSleep(delay)

  # Close event channel
  client.events.close()

proc disconnect*(client: IrcClient): CpsVoidFuture {.cps.} =
  ## Gracefully disconnect from the server.
  client.config.autoReconnect = false
  if client.stream != nil and not client.stream.closed:
    try:
      await client.quit("Goodbye")
    except CatchableError:
      discard
    client.stream.close()
    client.stream = nil
  client.state = icsDisconnected
