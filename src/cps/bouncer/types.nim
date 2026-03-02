## CPS IRC Bouncer - Types
##
## All type definitions for the IRC bouncer: configuration, message buffering,
## channel state tracking, client sessions, and the main Bouncer object.

import std/[tables, os, strutils]
import ../runtime
import ../irc/protocol
import ../irc/client
import ../io/unix
import ../io/buffered
import ../concurrency/taskgroup

export protocol, client

type
  # ============================================================
  # Configuration
  # ============================================================

  BouncerServerConfig* = object
    ## Configuration for a single upstream IRC server connection.
    name*: string              ## Friendly name (e.g. "libera", "oftc")
    host*: string              ## IRC server hostname
    port*: int                 ## IRC server port (default 6667)
    nick*: string              ## Desired nickname
    username*: string          ## Username (ident)
    realname*: string          ## Real name (GECOS)
    password*: string          ## Server password (empty = none)
    useTls*: bool              ## Use TLS/SSL
    saslUsername*: string       ## SASL PLAIN username
    saslPassword*: string       ## SASL PLAIN password
    autoJoinChannels*: seq[string]  ## Channels to join on connect
    requestedCaps*: seq[string]     ## IRCv3 capabilities to request (empty = defaults)

  BouncerConfig* = object
    ## Top-level bouncer configuration.
    socketPath*: string            ## Unix socket path (default ~/.config/cps-bouncer/bouncer.sock)
    logDir*: string                ## JSONL log directory (default ~/.config/cps-bouncer/logs/)
    bufferSize*: int               ## Per-channel ring buffer capacity (default 10000)
    flushIntervalMs*: int          ## Disk flush interval in ms (default 30000)
    password*: string              ## Bouncer password (empty = no auth required)
    autoAway*: bool                ## Enable auto-away when all clients disconnect (default true)
    autoAwayMessage*: string       ## Away message (default "Detached from bouncer")
    servers*: seq[BouncerServerConfig]

  # ============================================================
  # Message buffering
  # ============================================================

  BufferedMessage* = object
    ## A single buffered IRC message with metadata.
    id*: int64                 ## Monotonic message ID (unique per bouncer instance)
    timestamp*: float          ## Local epoch time when received
    serverTime*: string        ## IRCv3 server-time tag value (empty if not present)
    kind*: string              ## Event kind string (e.g. "privmsg", "join", "notice", "system")
    source*: string            ## Nick or server that sent the message
    target*: string            ## Channel or nick target
    text*: string              ## Message body
    prefix*: string            ## Raw IRC prefix string
    tags*: Table[string, string]  ## IRCv3 message tags
    raw*: string               ## Original raw IRC line (if available)

  MessageRingBuffer* = ref object
    ## Fixed-size ring buffer for messages.
    buf*: seq[BufferedMessage]
    head*: int                 ## Next write position
    count*: int                ## Number of valid entries
    capacity*: int
    lastFlushedId*: int64      ## ID of last message flushed to disk

  # ============================================================
  # Channel detach/reattach
  # ============================================================

  ChannelDetachState* = enum
    cdsAttached     ## Normal — messages forwarded to clients
    cdsDetached     ## Detached — messages buffered but not forwarded

  DetachPolicy* = object
    relayDetached*: string   ## "message" | "highlight" | "none" (default: "message")
    reattachOn*: string      ## "message" | "highlight" | "none" (default: "message")
    detachAfter*: int        ## Seconds of inactivity before auto-detach (0 = never)
    detachOn*: string        ## "message" | "highlight" | "none" (default: "none")

  # ============================================================
  # Channel / Server state
  # ============================================================

  ChannelState* = object
    ## Tracked state for a single IRC channel.
    name*: string
    topic*: string
    topicSetBy*: string
    topicSetAt*: string
    users*: Table[string, string]   ## nick -> mode prefix (e.g. "@", "+", "")
    modes*: string                   ## Channel modes string (e.g. "+nt")
    detachState*: ChannelDetachState ## Detached/attached state
    detachPolicy*: DetachPolicy      ## Detach/reattach policy
    lastActivity*: float             ## Epoch time of last message (for detach-after)

  ServerState* = ref object
    ## Per-server state held by the bouncer.
    name*: string                    ## Friendly server name
    client*: IrcClient               ## Upstream IRC client
    channels*: Table[string, ChannelState]  ## Tracked channels (lowercase key)
    currentNick*: string
    enabledCaps*: seq[string]
    isupport*: ISupport
    lagMs*: int
    isAway*: bool
    connected*: bool
    nextMsgId*: int64                ## Monotonic message ID counter

  # ============================================================
  # Client sessions (bouncer clients connecting via Unix socket)
  # ============================================================

  ClientSession* = ref object
    ## A connected bouncer client (TUI, GUI, etc.).
    id*: int                         ## Session ID
    stream*: UnixStream
    reader*: BufferedReader
    lastSeenIds*: Table[string, int64]  ## "server:channel" -> last seen msg ID
    lastDeliveredIds*: Table[string, int64]  ## "server:channel" -> last delivered msg ID (multi-client sync)
    clientName*: string              ## Reported client name (from hello)
    subscriptions*: seq[string]      ## Server names this client is subscribed to (empty = all)

  # ============================================================
  # Main Bouncer object
  # ============================================================

  # Callback types for daemon procs (avoids circular imports between server.nim and daemon.nim)
  AddServerProc* = proc(bouncer: Bouncer, sc: BouncerServerConfig): CpsVoidFuture
  RemoveServerProc* = proc(bouncer: Bouncer, name: string): CpsVoidFuture
  ReconnectServerProc* = proc(bouncer: Bouncer, name: string): CpsVoidFuture
  SaveConfigProc* = proc(bouncer: Bouncer)

  Bouncer* = ref object
    ## The IRC bouncer daemon state.
    config*: BouncerConfig
    configPath*: string                        ## Path to config file (for runtime saves)
    listener*: UnixListener
    servers*: Table[string, ServerState]      ## name -> ServerState
    clients*: seq[ClientSession]
    clientGroup*: TaskGroup
    serverGroup*: TaskGroup
    buffers*: Table[string, MessageRingBuffer] ## "server:channel" -> ring buffer
    running*: bool
    nextClientId*: int
    nextMsgId*: int64                          ## Global monotonic message ID
    # Callbacks set by daemon.nim for runtime management
    onAddServer*: AddServerProc
    onRemoveServer*: RemoveServerProc
    onReconnectServer*: ReconnectServerProc
    onSaveConfig*: SaveConfigProc

# ============================================================
# Config defaults
# ============================================================

proc defaultDetachPolicy*(): DetachPolicy =
  DetachPolicy(
    relayDetached: "message",
    reattachOn: "message",
    detachAfter: 0,
    detachOn: "none",
  )

proc defaultBouncerConfig*(): BouncerConfig =
  let configDir = os.getHomeDir() & ".config/cps-bouncer/"
  BouncerConfig(
    socketPath: configDir & "bouncer.sock",
    logDir: configDir & "logs/",
    bufferSize: 10_000,
    flushIntervalMs: 30_000,
    password: "",
    autoAway: true,
    autoAwayMessage: "Detached from bouncer",
    servers: @[],
  )

proc toIrcClientConfig*(sc: BouncerServerConfig): IrcClientConfig =
  ## Convert a BouncerServerConfig to an IrcClientConfig for the IRC client.
  var config = newIrcClientConfig(sc.host, sc.port, sc.nick,
                                   sc.username, sc.realname)
  config.password = sc.password
  config.useTls = sc.useTls
  config.saslUsername = sc.saslUsername
  config.saslPassword = sc.saslPassword
  config.autoJoinChannels = sc.autoJoinChannels
  config.autoReconnect = true
  config.reconnectDelayMs = 5000
  if sc.requestedCaps.len > 0:
    config.requestedCaps = sc.requestedCaps
  result = config

# ============================================================
# Helpers
# ============================================================

proc bufferKey*(serverName, target: string): string =
  ## Create a buffer lookup key from server name and target.
  serverName & ":" & target.toLowerAscii()
