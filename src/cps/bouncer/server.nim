## CPS IRC Bouncer - Client Server
##
## Unix socket accept loop for bouncer clients. Handles handshake,
## state sync, message replay, command routing, and live event broadcast.

import std/[tables, strutils]
import ../runtime
import ../transform
import ../eventloop
import ../io/streams
import ../io/unix
import ../io/buffered
import ../concurrency/taskgroup
import ./types
import ./protocol
import ./buffer
import ./bouncerserv
import ./search

# ============================================================
# Table iteration helpers (CPS procs can't iterate Tables directly)
# ============================================================

proc getServerNames*(bouncer: Bouncer): seq[string] =
  result = @[]
  for name in bouncer.servers.keys:
    result.add(name)

proc getServerList*(bouncer: Bouncer): seq[ServerState] =
  result = @[]
  for name, server in bouncer.servers:
    result.add(server)

proc getChannelList*(server: ServerState): seq[ChannelState] =
  result = @[]
  for key, ch in server.channels:
    result.add(ch)

# ============================================================
# Send helpers
# ============================================================

proc sendLine*(session: ClientSession, msg: BouncerMsg): CpsVoidFuture {.cps.} =
  ## Send a bouncer message to a client session as a JSON line.
  let line = msg.toJsonLine() & "\n"
  try:
    await session.stream.write(line)
  except CatchableError:
    discard  # Client disconnected; will be cleaned up

proc sendLineRaw*(session: ClientSession, line: string): CpsVoidFuture {.cps.} =
  ## Send a raw string line to a client session.
  try:
    await session.stream.write(line)
  except CatchableError:
    discard

# ============================================================
# Handshake
# ============================================================

proc doHandshake(bouncer: Bouncer, session: ClientSession): CpsFuture[bool] {.cps.} =
  ## Perform the hello handshake. Returns true on success.
  let line = await session.reader.readLine("\n")
  if line.len == 0:
    return false

  try:
    let msg = parseBouncerMsg(line)
    if msg.kind != bmkHello:
      await sendLine(session, BouncerMsg(kind: bmkError,
        errText: "Expected hello message"))
      return false

    session.clientName = msg.helloClientName

    # Verify password if bouncer requires one
    if bouncer.config.password.len > 0:
      if msg.helloPassword != bouncer.config.password:
        await sendLine(session, BouncerMsg(kind: bmkError,
          errText: "Authentication failed"))
        return false

    # Send hello_ok with server list
    let serverNames = getServerNames(bouncer)
    await sendLine(session, BouncerMsg(kind: bmkHelloOk,
      helloOkVersion: 1,
      helloOkServers: serverNames))

    return true
  except CatchableError:
    return false

# ============================================================
# State sync
# ============================================================

proc sendServerState(bouncer: Bouncer, session: ClientSession,
                     server: ServerState): CpsVoidFuture {.cps.} =
  ## Send full state for a single server to the client.
  let channels = getChannelList(server)

  await sendLine(session, BouncerMsg(kind: bmkServerState,
    ssServer: server.name,
    ssConnected: server.connected,
    ssNick: server.currentNick,
    ssChannels: channels))

proc sendAllState(bouncer: Bouncer, session: ClientSession): CpsVoidFuture {.cps.} =
  ## Send state for all servers to the client.
  let servers = getServerList(bouncer)
  let serverCount = servers.len
  for i in 0 ..< serverCount:
    await sendServerState(bouncer, session, servers[i])

# ============================================================
# Message replay
# ============================================================

proc replayMessages(bouncer: Bouncer, session: ClientSession,
                    serverName, channel: string,
                    sinceId: int64, limit: int): CpsVoidFuture {.cps.} =
  ## Replay buffered messages for a channel.
  let key = bufferKey(serverName, channel)
  if key in bouncer.buffers:
    let rb = bouncer.buffers[key]
    let messages = rb.getMessagesSince(sinceId, limit)
    let msgCount = messages.len
    for i in 0 ..< msgCount:
      await sendLine(session, BouncerMsg(kind: bmkMessage,
        msgServer: serverName,
        msgData: messages[i]))
    await sendLine(session, BouncerMsg(kind: bmkReplayEnd,
      reServer: serverName,
      reChannel: channel,
      reNewestId: rb.newestId()))
  else:
    await sendLine(session, BouncerMsg(kind: bmkReplayEnd,
      reServer: serverName,
      reChannel: channel,
      reNewestId: 0))

# ============================================================
# BouncerServ command execution
# ============================================================

## NOTE: addServer/removeServer/reconnectServer/saveConfig are called via
## bouncer.onAddServer/onRemoveServer/onReconnectServer/onSaveConfig callbacks
## set by daemon.nim during initialization. This avoids circular imports.

proc sendBouncerServNotice(session: ClientSession, text: string): CpsVoidFuture {.cps.} =
  ## Send a NOTICE from BouncerServ to the client.
  let msg = BufferedMessage(
    id: 0,
    timestamp: 0.0,
    kind: "notice",
    source: "BouncerServ",
    target: session.clientName,
    text: text,
  )
  await sendLine(session, BouncerMsg(kind: bmkMessage,
    msgServer: "",
    msgData: msg))

proc handleBouncerServCmd(bouncer: Bouncer, session: ClientSession,
                           cmd: BouncerServCmd): CpsVoidFuture {.cps.} =
  ## Execute a BouncerServ command and send responses as NOTICEs.
  case cmd.command
  of "help":
    let topic = if cmd.args.len > 0: cmd.args[0]
                elif cmd.subcommand.len > 0: cmd.subcommand
                else: ""
    let lines = helpLines(topic)
    let lineCount = lines.len
    for hlp in 0 ..< lineCount:
      await sendBouncerServNotice(session, lines[hlp])

  of "network":
    case cmd.subcommand
    of "create":
      let sc = parseServerConfigFromFlags(cmd)
      if sc.name.len == 0:
        await sendBouncerServNotice(session, "Error: -name is required")
      elif sc.host.len == 0:
        await sendBouncerServNotice(session, "Error: -host is required")
      else:
        # Check for duplicate
        let names = getServerNames(bouncer)
        var duplicate = false
        let nameCount = names.len
        for nci in 0 ..< nameCount:
          if names[nci].toLowerAscii() == sc.name.toLowerAscii():
            duplicate = true
            break
        if duplicate:
          await sendBouncerServNotice(session, "Error: network '" & sc.name & "' already exists")
        else:
          await bouncer.onAddServer(bouncer, sc)
          bouncer.onSaveConfig(bouncer)
          await sendBouncerServNotice(session, "Network '" & sc.name & "' created and connecting...")

    of "delete":
      let name = if cmd.args.len > 0: cmd.args[0] else: ""
      if name.len == 0:
        await sendBouncerServNotice(session, "Error: network name is required")
      elif name notin bouncer.servers:
        await sendBouncerServNotice(session, "Error: network '" & name & "' not found")
      else:
        await bouncer.onRemoveServer(bouncer, name)
        bouncer.onSaveConfig(bouncer)
        await sendBouncerServNotice(session, "Network '" & name & "' removed.")

    of "update":
      let name = if cmd.args.len > 0: cmd.args[0] else: ""
      if name.len == 0:
        await sendBouncerServNotice(session, "Error: network name is required")
      else:
        var configIdx = -1
        let serverCount = bouncer.config.servers.len
        for sci in 0 ..< serverCount:
          if bouncer.config.servers[sci].name == name:
            configIdx = sci
            break
        if configIdx < 0:
          await sendBouncerServNotice(session, "Error: network '" & name & "' not found")
        else:
          var needsReconnect = false
          if "host" in cmd.flags:
            bouncer.config.servers[configIdx].host = cmd.flags["host"]
            needsReconnect = true
          if "port" in cmd.flags:
            bouncer.config.servers[configIdx].port = parseInt(cmd.flags["port"])
            needsReconnect = true
          if "nick" in cmd.flags:
            bouncer.config.servers[configIdx].nick = cmd.flags["nick"]
            needsReconnect = true
          if "username" in cmd.flags:
            bouncer.config.servers[configIdx].username = cmd.flags["username"]
            needsReconnect = true
          if "realname" in cmd.flags:
            bouncer.config.servers[configIdx].realname = cmd.flags["realname"]
          if "password" in cmd.flags:
            bouncer.config.servers[configIdx].password = cmd.flags["password"]
            needsReconnect = true
          if "tls" in cmd.flags:
            bouncer.config.servers[configIdx].useTls = true
            needsReconnect = true
          let saslPlain = cmd.flags.getOrDefault("sasl-plain", "")
          if saslPlain.len > 0 and ':' in saslPlain:
            let parts = saslPlain.split(":", 1)
            bouncer.config.servers[configIdx].saslUsername = parts[0]
            bouncer.config.servers[configIdx].saslPassword = parts[1]
            needsReconnect = true
          if "join" in cmd.flags:
            let joinStr = cmd.flags["join"]
            var chans: seq[string] = @[]
            let chanParts = joinStr.split(",")
            let chanPartCount = chanParts.len
            for cpi in 0 ..< chanPartCount:
              let chanItem = chanParts[cpi].strip()
              if chanItem.len > 0:
                chans.add(chanItem)
            bouncer.config.servers[configIdx].autoJoinChannels = chans
          bouncer.onSaveConfig(bouncer)
          if needsReconnect and name in bouncer.servers:
            await sendBouncerServNotice(session, "Network '" & name & "' updated. Reconnecting...")
            let updatedSc = bouncer.config.servers[configIdx]
            await bouncer.onRemoveServer(bouncer, name)
            await bouncer.onAddServer(bouncer, updatedSc)
          else:
            await sendBouncerServNotice(session, "Network '" & name & "' updated.")

    of "status", "":
      let servers = getServerList(bouncer)
      if servers.len == 0:
        await sendBouncerServNotice(session, "No networks configured.")
      else:
        let serverCount = servers.len
        for sti in 0 ..< serverCount:
          let s = servers[sti]
          let status = if s.connected: "connected" else: "disconnected"
          let chanCount = s.channels.len
          await sendBouncerServNotice(session, s.name & ": " & status &
            " (" & $chanCount & " channels, nick: " & s.currentNick & ")")

    of "connect":
      let name = if cmd.args.len > 0: cmd.args[0] else: ""
      if name.len == 0:
        await sendBouncerServNotice(session, "Error: network name is required")
      elif name notin bouncer.servers:
        await sendBouncerServNotice(session, "Error: network '" & name & "' not found")
      else:
        await bouncer.onReconnectServer(bouncer, name)
        await sendBouncerServNotice(session, "Reconnecting to '" & name & "'...")

    of "disconnect":
      let name = if cmd.args.len > 0: cmd.args[0] else: ""
      if name.len == 0:
        await sendBouncerServNotice(session, "Error: network name is required")
      elif name notin bouncer.servers:
        await sendBouncerServNotice(session, "Error: network '" & name & "' not found")
      else:
        let server = bouncer.servers[name]
        if server.connected:
          try:
            await server.client.quit("Disconnected via BouncerServ")
          except CatchableError:
            discard
        await sendBouncerServNotice(session, "Disconnected from '" & name & "'.")

    else:
      await sendBouncerServNotice(session, "Unknown network subcommand: " & cmd.subcommand)

  of "channel":
    case cmd.subcommand
    of "status", "":
      let filterServer = if cmd.args.len > 0: cmd.args[0] else: ""
      let filterChannel = if cmd.args.len > 1: cmd.args[1] else: ""
      let servers = getServerList(bouncer)
      var anyOutput = false
      let serverCount = servers.len
      for si in 0 ..< serverCount:
        let s = servers[si]
        if filterServer.len > 0 and s.name.toLowerAscii() != filterServer.toLowerAscii():
          continue
        let channels = getChannelList(s)
        let chanCount = channels.len
        for ci in 0 ..< chanCount:
          let ch = channels[ci]
          if filterChannel.len > 0 and ch.name.toLowerAscii() != filterChannel.toLowerAscii():
            continue
          let detachStr = if ch.detachState == cdsDetached: " [detached]" else: ""
          await sendBouncerServNotice(session, s.name & " " & ch.name &
            ": " & $ch.users.len & " users" & detachStr)
          anyOutput = true
      if not anyOutput:
        await sendBouncerServNotice(session, "No channels found.")

    of "update":
      if cmd.args.len < 2:
        await sendBouncerServNotice(session, "Usage: channel update <network> <channel> [flags]")
      else:
        let serverName = cmd.args[0]
        let channelName = cmd.args[1]
        if serverName notin bouncer.servers:
          await sendBouncerServNotice(session, "Error: network '" & serverName & "' not found")
        else:
          let server = bouncer.servers[serverName]
          let key = channelName.toLowerAscii()
          if key notin server.channels:
            await sendBouncerServNotice(session, "Error: channel '" & channelName & "' not found on " & serverName)
          else:
            if "detached" in cmd.flags:
              server.channels[key].detachState = cdsDetached
              let detachMsg = BouncerMsg(kind: bmkChannelDetach,
                cdServer: serverName, cdChannel: channelName)
              let detachLine = detachMsg.toJsonLine() & "\n"
              let dcCount = bouncer.clients.len
              for dci in 0 ..< dcCount:
                await sendLineRaw(bouncer.clients[dci], detachLine)
              await sendBouncerServNotice(session, "Channel " & channelName & " on " & serverName & " detached.")
            elif "attached" in cmd.flags:
              server.channels[key].detachState = cdsAttached
              let attachMsg = BouncerMsg(kind: bmkChannelAttach,
                caServer: serverName, caChannel: channelName)
              let attachLine = attachMsg.toJsonLine() & "\n"
              let acCount = bouncer.clients.len
              for aci in 0 ..< acCount:
                await sendLineRaw(bouncer.clients[aci], attachLine)
              await sendBouncerServNotice(session, "Channel " & channelName & " on " & serverName & " reattached.")
            if "relay" in cmd.flags:
              server.channels[key].detachPolicy.relayDetached = cmd.flags["relay"]
            if "reattach-on" in cmd.flags:
              server.channels[key].detachPolicy.reattachOn = cmd.flags["reattach-on"]
            if "detach-after" in cmd.flags:
              server.channels[key].detachPolicy.detachAfter = parseInt(cmd.flags["detach-after"])
            if "detach-on" in cmd.flags:
              server.channels[key].detachPolicy.detachOn = cmd.flags["detach-on"]

    of "delete":
      if cmd.args.len < 2:
        await sendBouncerServNotice(session, "Usage: channel delete <network> <channel>")
      else:
        let serverName = cmd.args[0]
        let channelName = cmd.args[1]
        if serverName notin bouncer.servers:
          await sendBouncerServNotice(session, "Error: network '" & serverName & "' not found")
        else:
          let server = bouncer.servers[serverName]
          if server.connected:
            await server.client.partChannel(channelName, "Removed via BouncerServ")
          let key = channelName.toLowerAscii()
          server.channels.del(key)
          let bkey = bufferKey(serverName, channelName)
          bouncer.buffers.del(bkey)
          await sendBouncerServNotice(session, "Channel " & channelName & " removed from " & serverName & ".")

    else:
      await sendBouncerServNotice(session, "Unknown channel subcommand: " & cmd.subcommand)

  of "search":
    # "search CPS" parses "CPS" as subcommand; prepend it to args for the text
    var searchParts: seq[string] = @[]
    if cmd.subcommand.len > 0:
      searchParts.add(cmd.subcommand)
    let sArgCount = cmd.args.len
    for sai in 0 ..< sArgCount:
      searchParts.add(cmd.args[sai])
    let text = searchParts.join(" ")
    if text.len == 0:
      await sendBouncerServNotice(session, "Usage: search [-in <channel>] [-from <nick>] [-server <name>] [-limit <n>] <text>")
    else:
      let query = SearchQuery(
        text: text,
        nick: cmd.flags.getOrDefault("from", ""),
        channel: cmd.flags.getOrDefault("in", ""),
        serverName: cmd.flags.getOrDefault("server", ""),
        limit: parseInt(cmd.flags.getOrDefault("limit", "50")),
      )
      let searchResult = searchBuffers(bouncer, query)
      if searchResult.messages.len == 0:
        await sendBouncerServNotice(session, "No results found.")
      else:
        let msgCount = searchResult.messages.len
        await sendBouncerServNotice(session, "Found " & $msgCount & " result(s):" &
          (if searchResult.hasMore: " (more available)" else: ""))
        for sri in 0 ..< msgCount:
          let m = searchResult.messages[sri]
          await sendBouncerServNotice(session, "[" & m.source & " -> " & m.target & "] " & m.text)

  else:
    await sendBouncerServNotice(session, "Unknown command: " & cmd.command & ". Try 'help'.")

# ============================================================
# Command dispatch
# ============================================================

proc handleClientCommand(bouncer: Bouncer, session: ClientSession,
                         msg: BouncerMsg): CpsVoidFuture {.cps.} =
  ## Handle a command from a bouncer client.
  case msg.kind
  of bmkReplay:
    await replayMessages(bouncer, session,
      msg.replayServer, msg.replayChannel,
      msg.replaySinceId, msg.replayLimit)

  of bmkSendPrivmsg:
    if msg.spTarget.toLowerAscii() == "bouncerserv":
      let cmd = parseBouncerServCmd(msg.spText)
      await handleBouncerServCmd(bouncer, session, cmd)
    elif msg.spServer in bouncer.servers:
      let server = bouncer.servers[msg.spServer]
      if server.connected:
        await server.client.privMsg(msg.spTarget, msg.spText)

  of bmkSendNotice:
    if msg.snServer in bouncer.servers:
      let server = bouncer.servers[msg.snServer]
      if server.connected:
        await server.client.notice(msg.snTarget, msg.snText)

  of bmkJoin:
    if msg.joinServer in bouncer.servers:
      let server = bouncer.servers[msg.joinServer]
      if server.connected:
        await server.client.joinChannel(msg.joinChannel)

  of bmkPart:
    if msg.partServer in bouncer.servers:
      let server = bouncer.servers[msg.partServer]
      if server.connected:
        await server.client.partChannel(msg.partChannel, msg.partReason)

  of bmkNick:
    if msg.nickServer in bouncer.servers:
      let server = bouncer.servers[msg.nickServer]
      if server.connected:
        await server.client.changeNick(msg.nickNewNick)

  of bmkRaw:
    if msg.rawServer in bouncer.servers:
      let server = bouncer.servers[msg.rawServer]
      if server.connected:
        await server.client.sendMessage(msg.rawLine)

  of bmkMarkRead:
    let key = bufferKey(msg.mrServer, msg.mrChannel)
    session.lastSeenIds[key] = msg.mrLastId

  of bmkQuit:
    if msg.quitServer in bouncer.servers:
      let server = bouncer.servers[msg.quitServer]
      if server.connected:
        await server.client.quit(msg.quitReason)

  of bmkAway:
    if msg.awayServer in bouncer.servers:
      let server = bouncer.servers[msg.awayServer]
      if server.connected:
        await server.client.sendMessage("AWAY", msg.awayMessage)

  of bmkBack:
    if msg.backServer in bouncer.servers:
      let server = bouncer.servers[msg.backServer]
      if server.connected:
        await server.client.sendMessage("AWAY")

  of bmkSearch:
    let query = SearchQuery(
      text: msg.searchText,
      nick: msg.searchNick,
      channel: msg.searchChannel,
      serverName: msg.searchServer,
      limit: msg.searchLimit,
      before: msg.searchBefore,
      after: msg.searchAfter,
    )
    let searchResult = searchBuffers(bouncer, query)
    await sendLine(session, BouncerMsg(kind: bmkSearchResults,
      srchServer: msg.searchServer,
      srchMessages: searchResult.messages,
      srchHasMore: searchResult.hasMore))

  else:
    await sendLine(session, BouncerMsg(kind: bmkError,
      errText: "Unexpected message type from client"))

# ============================================================
# Client connection handler
# ============================================================

proc handleClientConnection*(bouncer: Bouncer,
                              stream: UnixStream): CpsVoidFuture {.cps.} =
  ## Handle a single bouncer client connection.
  let session = ClientSession(
    id: bouncer.nextClientId,
    stream: stream,
    reader: newBufferedReader(stream.AsyncStream),
    lastSeenIds: initTable[string, int64](),
    lastDeliveredIds: initTable[string, int64](),
  )
  bouncer.nextClientId += 1
  bouncer.clients.add(session)

  # Handshake
  let ok = await doHandshake(bouncer, session)
  if not ok:
    stream.close()
    # Remove from clients list
    for i in 0 ..< bouncer.clients.len:
      if bouncer.clients[i].id == session.id:
        bouncer.clients.delete(i)
        break
    return

  # Load per-client delivery tracking from disk
  if session.clientName.len > 0:
    session.lastDeliveredIds = loadClientDeliveryIds(bouncer.config.logDir, session.clientName)

  # Auto-away: clear away when first client connects
  if bouncer.clients.len == 1 and bouncer.config.autoAway:
    let awayServers = getServerList(bouncer)
    let awayCount = awayServers.len
    for ai in 0 ..< awayCount:
      if awayServers[ai].connected:
        try:
          await awayServers[ai].client.sendMessage("AWAY")
        except CatchableError:
          discard

  # Send state
  await sendAllState(bouncer, session)

  # Read loop
  var connected = true
  while connected:
    try:
      let line = await session.reader.readLine("\n")
      if line.len == 0 and session.reader.atEof:
        connected = false
      elif line.len > 0:
        try:
          let msg = parseBouncerMsg(line)
          await handleClientCommand(bouncer, session, msg)
        except CatchableError:
          await sendLine(session, BouncerMsg(kind: bmkError,
            errText: "Invalid JSON"))
    except CatchableError:
      connected = false

  # Save per-client delivery tracking to disk
  if session.clientName.len > 0:
    saveClientDeliveryIds(bouncer.config.logDir, session.clientName, session.lastDeliveredIds)

  # Cleanup
  stream.close()
  for i in 0 ..< bouncer.clients.len:
    if bouncer.clients[i].id == session.id:
      bouncer.clients.delete(i)
      break

  # Auto-away: set away when last client disconnects
  if bouncer.clients.len == 0 and bouncer.config.autoAway:
    let awayMsg = if bouncer.config.autoAwayMessage.len > 0:
                    bouncer.config.autoAwayMessage
                  else:
                    "Detached from bouncer"
    let awayServers = getServerList(bouncer)
    let awayCount = awayServers.len
    for ai in 0 ..< awayCount:
      if awayServers[ai].connected:
        try:
          await awayServers[ai].client.sendMessage("AWAY", awayMsg)
        except CatchableError:
          discard

# ============================================================
# Broadcast to all connected clients
# ============================================================

proc isChannelDetached*(bouncer: Bouncer, serverName, target: string): bool =
  ## Check if a channel is detached on this server.
  if serverName in bouncer.servers:
    let server = bouncer.servers[serverName]
    let key = target.toLowerAscii()
    if key in server.channels:
      return server.channels[key].detachState == cdsDetached
  return false

proc checkDetachPolicies*(bouncer: Bouncer, serverName: string,
                           msg: BufferedMessage) =
  ## Check detach policies and auto-reattach/detach as needed.
  ## Non-CPS helper (called from CPS context).
  if serverName notin bouncer.servers:
    return
  let server = bouncer.servers[serverName]
  let key = msg.target.toLowerAscii()
  if key notin server.channels:
    return
  let ch = server.channels[key]
  # Auto-reattach on message
  if ch.detachState == cdsDetached:
    if ch.detachPolicy.reattachOn == "message" and msg.kind in ["privmsg", "notice", "action"]:
      server.channels[key].detachState = cdsAttached
    elif ch.detachPolicy.reattachOn == "highlight" and msg.kind in ["privmsg", "notice", "action"]:
      if server.currentNick.toLowerAscii() in msg.text.toLowerAscii():
        server.channels[key].detachState = cdsAttached

proc broadcastToClients*(bouncer: Bouncer, serverName: string,
                         msg: BufferedMessage): CpsVoidFuture {.cps.} =
  ## Send a message to all connected bouncer clients.
  ## Skips forwarding for detached channels (messages are still buffered).
  # Check detach policies (may auto-reattach)
  checkDetachPolicies(bouncer, serverName, msg)

  # Skip if channel is detached (unless relay policy says otherwise)
  if isChannelDetached(bouncer, serverName, msg.target):
    let server = bouncer.servers[serverName]
    let key = msg.target.toLowerAscii()
    let policy = server.channels[key].detachPolicy
    # Check relay policy
    if policy.relayDetached == "none":
      return
    elif policy.relayDetached == "highlight":
      if server.currentNick.toLowerAscii() notin msg.text.toLowerAscii():
        return
    # "message" → relay all (fall through)

  let bouncerMsg = BouncerMsg(kind: bmkMessage,
    msgServer: serverName,
    msgData: msg)
  let line = bouncerMsg.toJsonLine() & "\n"
  let deliveryKey = bufferKey(serverName, msg.target)
  let clientCount = bouncer.clients.len
  for i in 0 ..< clientCount:
    let session = bouncer.clients[i]
    await sendLineRaw(session, line)
    # Track delivery for multi-client sync
    session.lastDeliveredIds[deliveryKey] = msg.id

proc broadcastChannelUpdate*(bouncer: Bouncer, serverName: string,
                              channel: ChannelState): CpsVoidFuture {.cps.} =
  ## Broadcast a channel state update to all clients.
  let bmsg = BouncerMsg(kind: bmkChannelUpdate,
    cuServer: serverName,
    cuChannel: channel)
  let line = bmsg.toJsonLine() & "\n"
  let clientCount = bouncer.clients.len
  for i in 0 ..< clientCount:
    await sendLineRaw(bouncer.clients[i], line)

proc broadcastServerConnected*(bouncer: Bouncer, serverName, nick: string): CpsVoidFuture {.cps.} =
  let bmsg = BouncerMsg(kind: bmkServerConnected,
    scServer: serverName, scNick: nick)
  let line = bmsg.toJsonLine() & "\n"
  let clientCount = bouncer.clients.len
  for i in 0 ..< clientCount:
    await sendLineRaw(bouncer.clients[i], line)

proc broadcastServerDisconnected*(bouncer: Bouncer, serverName, reason: string): CpsVoidFuture {.cps.} =
  let bmsg = BouncerMsg(kind: bmkServerDisconnected,
    sdServer: serverName, sdReason: reason)
  let line = bmsg.toJsonLine() & "\n"
  let clientCount = bouncer.clients.len
  for i in 0 ..< clientCount:
    await sendLineRaw(bouncer.clients[i], line)

proc broadcastNickChanged*(bouncer: Bouncer, serverName, oldNick, newNick: string): CpsVoidFuture {.cps.} =
  let bmsg = BouncerMsg(kind: bmkNickChanged,
    ncServer: serverName, ncOldNick: oldNick, ncNewNick: newNick)
  let line = bmsg.toJsonLine() & "\n"
  let clientCount = bouncer.clients.len
  for i in 0 ..< clientCount:
    await sendLineRaw(bouncer.clients[i], line)

# ============================================================
# Accept loop
# ============================================================

proc startClientServer*(bouncer: Bouncer): CpsVoidFuture {.cps.} =
  ## Start the Unix socket accept loop for bouncer clients.
  bouncer.resetStopSignal()
  bouncer.listener = unixListen(bouncer.config.socketPath)
  while bouncer.running:
    try:
      let client = await bouncer.listener.accept()
      bouncer.clientGroup.spawn(handleClientConnection(bouncer, client))
    except CatchableError:
      if bouncer.running:
        await sleepOrSignal(100, bouncer.stopSignal)  # Brief pause before retrying accept
