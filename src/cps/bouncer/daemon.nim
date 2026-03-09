## CPS IRC Bouncer - Daemon
##
## Entry point for the bouncer daemon. Loads config, connects to IRC servers,
## consumes events, manages client connections, and handles graceful shutdown.

import std/[tables, json, os, strutils, times]
import ../runtime
import ../transform
import ../eventloop
import ../irc/protocol
import ../irc/client
import ../io/streams
import ../io/unix
import ../concurrency/channels
import ../concurrency/taskgroup
import ../concurrency/signals
import ./types
import ./protocol as bprotocol
import ./buffer
import ./state
import ./server

# ============================================================
# Config loading
# ============================================================

proc loadConfig*(path: string): BouncerConfig =
  ## Load bouncer config from a JSON file.
  var config = defaultBouncerConfig()
  if not fileExists(path):
    return config

  let j = parseJson(readFile(path))

  if j.hasKey("socketPath"):
    config.socketPath = j["socketPath"].getStr()
  if j.hasKey("logDir"):
    config.logDir = j["logDir"].getStr()
  if j.hasKey("bufferSize"):
    config.bufferSize = j["bufferSize"].getInt()
  if j.hasKey("flushIntervalMs"):
    config.flushIntervalMs = j["flushIntervalMs"].getInt()
  if j.hasKey("password"):
    config.password = j["password"].getStr()
  if j.hasKey("autoAway"):
    config.autoAway = j["autoAway"].getBool()
  if j.hasKey("autoAwayMessage"):
    config.autoAwayMessage = j["autoAwayMessage"].getStr()

  if j.hasKey("servers"):
    for sj in j["servers"]:
      var sc = BouncerServerConfig(
        name: sj["name"].getStr(),
        host: sj["host"].getStr(),
        port: sj.getOrDefault("port").getInt(6667),
        nick: sj.getOrDefault("nick").getStr("cpsbot"),
        username: sj.getOrDefault("username").getStr("cps"),
        realname: sj.getOrDefault("realname").getStr("CPS IRC Bouncer"),
        password: sj.getOrDefault("password").getStr(),
        useTls: sj.getOrDefault("useTls").getBool(false),
        saslUsername: sj.getOrDefault("saslUsername").getStr(),
        saslPassword: sj.getOrDefault("saslPassword").getStr(),
      )
      if sj.hasKey("autoJoinChannels"):
        for ch in sj["autoJoinChannels"]:
          sc.autoJoinChannels.add(ch.getStr())
      if sj.hasKey("requestedCaps"):
        for cap in sj["requestedCaps"]:
          sc.requestedCaps.add(cap.getStr())
      config.servers.add(sc)

  result = config

proc serverConfigToJson*(sc: BouncerServerConfig): JsonNode =
  ## Serialize a BouncerServerConfig to JSON.
  result = newJObject()
  result["name"] = newJString(sc.name)
  result["host"] = newJString(sc.host)
  result["port"] = newJInt(sc.port)
  result["nick"] = newJString(sc.nick)
  result["username"] = newJString(sc.username)
  result["realname"] = newJString(sc.realname)
  if sc.password.len > 0:
    result["password"] = newJString(sc.password)
  result["useTls"] = newJBool(sc.useTls)
  if sc.saslUsername.len > 0:
    result["saslUsername"] = newJString(sc.saslUsername)
    result["saslPassword"] = newJString(sc.saslPassword)
  if sc.autoJoinChannels.len > 0:
    result["autoJoinChannels"] = %sc.autoJoinChannels
  if sc.requestedCaps.len > 0:
    result["requestedCaps"] = %sc.requestedCaps

proc configToJson*(config: BouncerConfig): JsonNode =
  ## Serialize the full bouncer config to JSON.
  result = newJObject()
  result["socketPath"] = newJString(config.socketPath)
  result["logDir"] = newJString(config.logDir)
  result["bufferSize"] = newJInt(config.bufferSize)
  result["flushIntervalMs"] = newJInt(config.flushIntervalMs)
  if config.password.len > 0:
    result["password"] = newJString(config.password)
  result["autoAway"] = newJBool(config.autoAway)
  if config.autoAwayMessage.len > 0:
    result["autoAwayMessage"] = newJString(config.autoAwayMessage)
  var servers = newJArray()
  for sc in config.servers:
    servers.add(serverConfigToJson(sc))
  result["servers"] = servers

proc saveConfig*(bouncer: Bouncer) =
  ## Save the current bouncer config to disk atomically (write to .tmp, rename).
  if bouncer.configPath.len == 0:
    return
  let tmpPath = bouncer.configPath & ".tmp"
  let j = configToJson(bouncer.config)
  writeFile(tmpPath, $j)
  moveFile(tmpPath, bouncer.configPath)

proc saveDefaultConfig*(path: string) =
  ## Write a default config template if no config exists.
  if fileExists(path):
    return
  let dir = parentDir(path)
  if not dirExists(dir):
    createDir(dir)
  let j = %*{
    "socketPath": getHomeDir() & ".config/cps-bouncer/bouncer.sock",
    "logDir": getHomeDir() & ".config/cps-bouncer/logs/",
    "bufferSize": 10000,
    "flushIntervalMs": 30000,
    "servers": [
      {
        "name": "libera",
        "host": "irc.libera.chat",
        "port": 6697,
        "nick": "mybot",
        "username": "cps",
        "realname": "CPS IRC Bouncer",
        "useTls": true,
        "saslUsername": "",
        "saslPassword": "",
        "autoJoinChannels": ["#nim"],
      }
    ]
  }
  writeFile(path, $j)

# ============================================================
# Table iteration helpers (CPS procs can't iterate Tables directly)
# ============================================================

proc initServersFromConfig*(bouncer: Bouncer, config: BouncerConfig) =
  ## Initialize server state and load buffers from config (non-CPS).
  for sc in config.servers:
    let ircConfig = toIrcClientConfig(sc)
    let ircClient = newIrcClient(ircConfig)
    let server = ServerState(
      name: sc.name,
      client: ircClient,
      channels: initTable[string, ChannelState](),
      currentNick: sc.nick,
      enabledCaps: @[],
      isupport: newISupport(),
      lagMs: -1,
      connected: false,
      nextMsgId: bouncer.nextMsgId,
    )
    bouncer.servers[sc.name] = server

    # Load existing message buffers from disk
    for ch in sc.autoJoinChannels:
      let key = bufferKey(sc.name, ch)
      bouncer.buffers[key] = loadFromDisk(config.logDir, sc.name, ch,
                                            config.bufferSize)
      let newestLoaded = bouncer.buffers[key].newestId()
      if newestLoaded > bouncer.nextMsgId:
        bouncer.nextMsgId = newestLoaded
      server.nextMsgId = bouncer.nextMsgId

    echo "  Server '", sc.name, "': ", sc.host, ":", sc.port,
         if sc.useTls: " (TLS)" else: "", " -> ", sc.autoJoinChannels.join(", ")

proc getBufferKeys(bouncer: Bouncer): seq[string] =
  result = @[]
  for key in bouncer.buffers.keys:
    result.add(key)

proc getServerEntries(bouncer: Bouncer): seq[(string, ServerState)] =
  result = @[]
  for name, server in bouncer.servers:
    result.add((name, server))

# ============================================================
# IRC event consumer (one per server)
# ============================================================

proc consumeIrcEvents*(bouncer: Bouncer, server: ServerState): CpsVoidFuture {.cps.} =
  ## Read events from an IrcClient and process them:
  ## update state, buffer messages, broadcast to clients.
  while bouncer.running:
    let evt = await server.client.events.recv()

    # Process event for state tracking + create buffered messages
    let messages = processEvent(server, evt)

    # Handle special broadcast events
    case evt.kind
    of iekConnected:
      await broadcastServerConnected(bouncer, server.name, server.currentNick)
    of iekDisconnected:
      await broadcastServerDisconnected(bouncer, server.name, evt.reason)
    of iekNick:
      if evt.nickOld == server.currentNick or evt.nickNew == server.currentNick:
        await broadcastNickChanged(bouncer, server.name, evt.nickOld, evt.nickNew)
    of iekTopic, iekMode:
      # Send channel update
      let chanName = if evt.kind == iekTopic: evt.topicChannel else: evt.modeTarget
      let key = chanName.toLowerAscii()
      if key in server.channels:
        await broadcastChannelUpdate(bouncer, server.name, server.channels[key])
    of iekJoin:
      if evt.joinNick == server.currentNick:
        let key = evt.joinChannel.toLowerAscii()
        if key in server.channels:
          await broadcastChannelUpdate(bouncer, server.name, server.channels[key])
    else:
      discard

    # Buffer and broadcast messages
    let msgCount = messages.len
    for i in 0 ..< msgCount:
      let msg = messages[i]
      let key = bufferKey(server.name, msg.target)
      if key notin bouncer.buffers:
        bouncer.buffers[key] = newMessageRingBuffer(bouncer.config.bufferSize)
      bouncer.buffers[key].push(msg)
      await broadcastToClients(bouncer, server.name, msg)

# ============================================================
# Dynamic server management
# ============================================================

proc broadcastServerAdded(bouncer: Bouncer, name: string): CpsVoidFuture {.cps.} =
  let bmsg = BouncerMsg(kind: bmkServerAdded, saServer: name)
  let line = bmsg.toJsonLine() & "\n"
  let clientCount = bouncer.clients.len
  for bsai in 0 ..< clientCount:
    await sendLineRaw(bouncer.clients[bsai], line)

proc broadcastServerRemoved(bouncer: Bouncer, name: string): CpsVoidFuture {.cps.} =
  let bmsg = BouncerMsg(kind: bmkServerRemoved, srServer: name)
  let line = bmsg.toJsonLine() & "\n"
  let clientCount = bouncer.clients.len
  for bsri in 0 ..< clientCount:
    await sendLineRaw(bouncer.clients[bsri], line)

proc addServer*(bouncer: Bouncer, sc: BouncerServerConfig): CpsVoidFuture {.cps.} =
  ## Create ServerState, start IRC client + event consumer.
  # Add to config if not already there
  var found = false
  let configCount = bouncer.config.servers.len
  for asi in 0 ..< configCount:
    if bouncer.config.servers[asi].name == sc.name:
      found = true
      break
  if not found:
    bouncer.config.servers.add(sc)

  let ircConfig = toIrcClientConfig(sc)
  let ircClient = newIrcClient(ircConfig)
  let srv = ServerState(
    name: sc.name,
    client: ircClient,
    channels: initTable[string, ChannelState](),
    currentNick: sc.nick,
    enabledCaps: @[],
    isupport: newISupport(),
    lagMs: -1,
    connected: false,
    nextMsgId: bouncer.nextMsgId,
  )
  bouncer.servers[sc.name] = srv

  # Load existing buffers
  let ajcCount = sc.autoJoinChannels.len
  for aji in 0 ..< ajcCount:
    let ch = sc.autoJoinChannels[aji]
    let bKey = bufferKey(sc.name, ch)
    if bKey notin bouncer.buffers:
      bouncer.buffers[bKey] = loadFromDisk(bouncer.config.logDir, sc.name, ch,
                                            bouncer.config.bufferSize)
      let newestLoaded = bouncer.buffers[bKey].newestId()
      if newestLoaded > bouncer.nextMsgId:
        bouncer.nextMsgId = newestLoaded
      srv.nextMsgId = bouncer.nextMsgId

  # Start IRC client and event consumer
  bouncer.serverGroup.spawn(ircClient.run(), "irc:" & sc.name)
  bouncer.serverGroup.spawn(consumeIrcEvents(bouncer, srv), "events:" & sc.name)

  # Notify clients
  await broadcastServerAdded(bouncer, sc.name)
  echo "  Added server '", sc.name, "': ", sc.host, ":", sc.port

proc removeServer*(bouncer: Bouncer, name: string): CpsVoidFuture {.cps.} =
  ## Disconnect, remove state.
  if name notin bouncer.servers:
    return
  let srv = bouncer.servers[name]

  # Disconnect IRC client (sets autoReconnect=false, so run() exits)
  try:
    await srv.client.disconnect()
  except CatchableError:
    discard

  # Close event channel to unblock the event consumer
  srv.client.events.close()

  # Remove from servers table
  bouncer.servers.del(name)

  # Remove from config
  var newServers: seq[BouncerServerConfig] = @[]
  for rsc in bouncer.config.servers:
    if rsc.name != name:
      newServers.add(rsc)
  bouncer.config.servers = newServers

  # Flush and remove associated buffers
  let rmKeys = getBufferKeys(bouncer)
  let rmKeyCount = rmKeys.len
  for rki in 0 ..< rmKeyCount:
    let rkey = rmKeys[rki]
    if rkey.startsWith(name & ":"):
      let rparts = rkey.split(":", 1)
      if rparts.len == 2 and rkey in bouncer.buffers:
        bouncer.buffers[rkey].flushToDisk(bouncer.config.logDir, rparts[0], rparts[1])
      bouncer.buffers.del(rkey)

  # Notify clients
  await broadcastServerRemoved(bouncer, name)
  echo "  Removed server '", name, "'"

proc reconnectServer*(bouncer: Bouncer, name: string): CpsVoidFuture {.cps.} =
  ## Reconnect a disconnected server by removing and re-adding it.
  if name notin bouncer.servers:
    return
  # Find the config
  var rsc: BouncerServerConfig
  var rfound = false
  let rcCount = bouncer.config.servers.len
  for rci in 0 ..< rcCount:
    if bouncer.config.servers[rci].name == name:
      rsc = bouncer.config.servers[rci]
      rfound = true
      break
  if not rfound:
    return
  await removeServer(bouncer, name)
  await addServer(bouncer, rsc)

# ============================================================
# Periodic flush
# ============================================================

proc periodicFlush*(bouncer: Bouncer): CpsVoidFuture {.cps.} =
  ## Periodically flush all message buffers to disk.
  while bouncer.running:
    await sleepOrSignal(bouncer.config.flushIntervalMs, bouncer.stopSignal)
    if not bouncer.running:
      break
    # Collect keys first (can't iterate Tables in CPS procs)
    let keys = getBufferKeys(bouncer)
    let keyCount = keys.len
    for i in 0 ..< keyCount:
      let key = keys[i]
      if key in bouncer.buffers:
        let parts = key.split(":", 1)
        if parts.len == 2:
          bouncer.buffers[key].flushToDisk(bouncer.config.logDir, parts[0], parts[1])

proc flushAll*(bouncer: Bouncer) =
  ## Synchronously flush all buffers to disk (for shutdown).
  for key, rb in bouncer.buffers:
    let parts = key.split(":", 1)
    if parts.len == 2:
      rb.flushToDisk(bouncer.config.logDir, parts[0], parts[1])

# ============================================================
# Detach timer check
# ============================================================

proc getDetachableChannels(bouncer: Bouncer): seq[(string, string, float)] =
  ## Returns (serverName, chanKey, lastActivity) for attached channels with detachAfter > 0.
  result = @[]
  for name, server in bouncer.servers:
    for key, ch in server.channels:
      if ch.detachState == cdsAttached and ch.detachPolicy.detachAfter > 0:
        result.add((name, key, ch.lastActivity))

proc checkDetachTimers*(bouncer: Bouncer): CpsVoidFuture {.cps.} =
  ## Periodically check detach-after policies and auto-detach inactive channels.
  while bouncer.running:
    await sleepOrSignal(10_000, bouncer.stopSignal)  # Check every 10 seconds
    if not bouncer.running:
      break
    let now = epochTime()
    let candidates = getDetachableChannels(bouncer)
    let candCount = candidates.len
    for i in 0 ..< candCount:
      let serverName = candidates[i][0]
      let chanKey = candidates[i][1]
      let lastActivity = candidates[i][2]
      if serverName in bouncer.servers:
        let server = bouncer.servers[serverName]
        if chanKey in server.channels:
          let ch = server.channels[chanKey]
          if ch.detachState == cdsAttached and ch.detachPolicy.detachAfter > 0:
            let idleSeconds = int(now - lastActivity)
            if lastActivity > 0 and idleSeconds >= ch.detachPolicy.detachAfter:
              server.channels[chanKey].detachState = cdsDetached
              # Broadcast detach event
              let bmsg = BouncerMsg(kind: bmkChannelDetach,
                cdServer: serverName, cdChannel: ch.name)
              let line = bmsg.toJsonLine() & "\n"
              let clientCount = bouncer.clients.len
              for ci in 0 ..< clientCount:
                await sendLineRaw(bouncer.clients[ci], line)

# ============================================================
# Main daemon
# ============================================================

proc newBouncer*(config: BouncerConfig, configPath: string = ""): Bouncer =
  result = Bouncer(
    config: config,
    configPath: configPath,
    servers: initTable[string, ServerState](),
    clients: @[],
    clientGroup: newTaskGroup(epCollectAll),
    serverGroup: newTaskGroup(epCollectAll),
    buffers: initTable[string, MessageRingBuffer](),
    running: true,
    stopSignal: newCpsVoidFuture(),
    nextClientId: 1,
    nextMsgId: 0,
  )
  result.resetStopSignal()
  # Set daemon callback procs (used by server.nim BouncerServ commands)
  result.onAddServer = proc(bouncer: Bouncer, sc: BouncerServerConfig): CpsVoidFuture =
    addServer(bouncer, sc)
  result.onRemoveServer = proc(bouncer: Bouncer, name: string): CpsVoidFuture =
    removeServer(bouncer, name)
  result.onReconnectServer = proc(bouncer: Bouncer, name: string): CpsVoidFuture =
    reconnectServer(bouncer, name)
  result.onSaveConfig = proc(bouncer: Bouncer) =
    saveConfig(bouncer)

proc startBouncer*(configPath: string): CpsVoidFuture {.cps.} =
  ## Main bouncer entry point.
  ## 1. Load config
  ## 2. Load message buffers from disk
  ## 3. Connect to IRC servers
  ## 4. Start client server (Unix socket)
  ## 5. Start periodic flush
  ## 6. Wait for shutdown signal
  ## 7. Graceful shutdown

  # 1. Load config
  let config = loadConfig(configPath)
  let bouncer = newBouncer(config, configPath)
  bouncer.resetStopSignal()

  # Ensure log directory exists
  if not dirExists(config.logDir):
    createDir(config.logDir)

  # Ensure socket directory exists
  let socketDir = parentDir(config.socketPath)
  if not dirExists(socketDir):
    createDir(socketDir)

  echo "CPS IRC Bouncer starting..."
  echo "  Socket: ", config.socketPath
  echo "  Log dir: ", config.logDir
  echo "  Servers: ", config.servers.len

  # 2. Create IRC clients and load buffers for configured servers
  initServersFromConfig(bouncer, config)

  # 3. Start IRC clients and event consumers
  let entries = getServerEntries(bouncer)
  let entryCount = entries.len
  for idx in 0 ..< entryCount:
    let srvName = entries[idx][0]
    let srv = entries[idx][1]
    bouncer.serverGroup.spawn(srv.client.run(), "irc:" & srvName)
    bouncer.serverGroup.spawn(consumeIrcEvents(bouncer, srv), "events:" & srvName)

  # 4. Start client server (Unix socket accept loop)
  let clientServerFut = startClientServer(bouncer)

  # 5. Start periodic flush
  let flushFut = periodicFlush(bouncer)

  # 5b. Start detach timer checker
  let detachFut = checkDetachTimers(bouncer)

  echo "Bouncer ready. Waiting for connections..."

  # 6. Wait for shutdown signal
  initSignalHandling()
  await waitForShutdown()

  echo "\nShutting down..."
  bouncer.running = false
  bouncer.signalStop()

  # 7. Graceful shutdown
  # Flush all buffers
  flushAll(bouncer)

  # Disconnect IRC clients
  let shutdownEntries = getServerEntries(bouncer)
  let shutdownCount = shutdownEntries.len
  for sdIdx in 0 ..< shutdownCount:
    let shutdownSrv = shutdownEntries[sdIdx][1]
    try:
      await shutdownSrv.client.disconnect()
    except CatchableError:
      discard

  # Close listener
  if bouncer.listener != nil:
    bouncer.listener.close()

  # Close client connections
  let clientCount = bouncer.clients.len
  for clIdx in 0 ..< clientCount:
    bouncer.clients[clIdx].stream.close()

  # Cancel background tasks
  flushFut.cancel()
  detachFut.cancel()
  clientServerFut.cancel()
  bouncer.serverGroup.cancelAll()
  bouncer.clientGroup.cancelAll()

  deinitSignalHandling()
  echo "Bouncer stopped."

# ============================================================
# Bouncer discovery (for clients)
# ============================================================

proc discoverBouncer*(): string =
  ## Check if a bouncer socket exists at the well-known path.
  ## Returns the socket path if found, empty string otherwise.
  let path = getHomeDir() & ".config/cps-bouncer/bouncer.sock"
  if fileExists(path):
    result = path
  else:
    result = ""
