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
import std/[times, base64, strutils]

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
    lagMs*: int                 ## Current lag in milliseconds (-1 = unknown)
    isAway*: bool               ## True if marked away

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
    requestedCaps: @["server-time", "message-tags", "away-notify", "account-notify",
                     "extended-join", "multi-prefix", "cap-notify", "chghost",
                     "setname", "invite-notify", "userhost-in-names", "sasl", "batch"],
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

# ============================================================
# Internal: emit events
# ============================================================

proc emit(client: IrcClient, event: IrcEvent): CpsVoidFuture =
  client.events.send(event)

# ============================================================
# Internal: handle registration
# ============================================================

proc doRegister(client: IrcClient): CpsVoidFuture {.cps.} =
  ## Send CAP LS, NICK/USER (and optionally PASS) to register.
  ## CAP negotiation and SASL are handled in processMessage.
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

proc processMessage(client: IrcClient, msg: IrcMessage): CpsVoidFuture {.cps.} =
  ## Process a parsed IRC message and emit appropriate events.
  let event = classifyMessage(msg)

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
      # Server sent available caps. Find intersection with requested caps.
      let available = if event.capParams.len > 0: event.capParams[0].split(' ') else: @[]
      var toRequest: seq[string] = @[]
      for cap in client.config.requestedCaps:
        for avail in available:
          # Handle caps with values like "sasl=PLAIN,EXTERNAL"
          let capName = if avail.contains('='): avail.split('=')[0] else: avail
          if capName == cap:
            toRequest.add(cap)
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
      if "sasl" in client.enabledCaps and client.config.saslUsername.len > 0:
        client.saslState = 1
        await client.sendRaw(formatIrcMessage("AUTHENTICATE", "PLAIN"))
      else:
        client.capNegotiating = false
        await client.sendRaw(formatIrcMessage("CAP", "END"))
    of "NAK":
      # Capabilities rejected — end negotiation
      client.capNegotiating = false
      await client.sendRaw(formatIrcMessage("CAP", "END"))
    of "NEW":
      # Server offers new caps (cap-notify)
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
      if client.saslState == 1 and msg.params.len > 0 and msg.params[0] == "+":
        # Server ready for credentials — send SASL PLAIN
        let payload = "\0" & client.config.saslUsername & "\0" & client.config.saslPassword
        let encoded = base64.encode(payload)
        client.saslState = 2
        await client.sendRaw(formatIrcMessage("AUTHENTICATE", encoded))
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
      for ch in client.config.autoJoinChannels:
        await client.joinChannel(ch)
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
  while client.stream != nil and not client.stream.closed:
    let line = await client.reader.readLine("\r\n")
    if line.len == 0 and client.reader.atEof:
      break
    if line.len > 0:
      let msg = parseIrcMessage(line)
      if msg.command.len > 0:
        await client.processMessage(msg)

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
      await client.doRegister()
      await client.readLoop()

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
