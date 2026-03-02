## CPS IRC Bouncer - State Tracking
##
## Processes IrcEvent stream and maintains per-server channel/user state.
## Returns BufferedMessages for events that should be stored and forwarded.

import std/[tables, times, strutils]
import ../irc/protocol
import ./types

# ============================================================
# Case-insensitive channel name helpers
# ============================================================

proc chanKey(name: string): string =
  ## Normalize channel name for table lookup (lowercase).
  result = newString(name.len)
  for i in 0 ..< name.len:
    let c = name[i]
    if c >= 'A' and c <= 'Z':
      result[i] = chr(ord(c) + 32)
    else:
      result[i] = c

# ============================================================
# NAMES reply user parsing
# ============================================================

proc parseNamesUser(entry: string): (string, string) =
  ## Parse a NAMES reply entry like "@nick" or "+nick" into (nick, prefix).
  var nick = entry
  var prefix = ""
  while nick.len > 0 and nick[0] in {'@', '+', '%', '~', '&', '!'}:
    prefix.add(nick[0])
    nick = nick[1 .. ^1]
  result = (nick, prefix)

# ============================================================
# Create BufferedMessage from IrcEvent
# ============================================================

proc makeBufferedMessage*(server: ServerState, kind, source, target, text: string,
                          tags: Table[string, string] = initTable[string, string](),
                          prefix: string = "", raw: string = ""): BufferedMessage =
  ## Create a BufferedMessage with a fresh ID and timestamp.
  server.nextMsgId += 1
  result = BufferedMessage(
    id: server.nextMsgId,
    timestamp: epochTime(),
    serverTime: tags.getOrDefault("time", ""),
    kind: kind,
    source: source,
    target: target,
    text: text,
    prefix: prefix,
    tags: tags,
    raw: raw,
  )

# ============================================================
# Event processing
# ============================================================

proc processEvent*(server: ServerState, evt: IrcEvent): seq[BufferedMessage] =
  ## Process an IrcEvent, update server state, and return messages to buffer/forward.
  ## Returns empty seq for events that only update state without producing messages.
  result = @[]

  case evt.kind
  of iekConnected:
    server.connected = true
    result.add(makeBufferedMessage(server, "system", "", "",
      "Connected to " & server.name))

  of iekDisconnected:
    server.connected = false
    # Clear users from all channels (they may have changed during disconnect)
    for key in server.channels.keys:
      server.channels[key].users = initTable[string, string]()
    result.add(makeBufferedMessage(server, "system", "", "",
      "Disconnected: " & evt.reason))

  of iekPrivMsg:
    # Update last activity for detach-after tracking
    let pmKey = evt.pmTarget.toLowerAscii()
    if pmKey in server.channels:
      server.channels[pmKey].lastActivity = epochTime()
    result.add(makeBufferedMessage(server, "privmsg",
      evt.pmSource, evt.pmTarget, evt.pmText,
      prefix = evt.pmPrefix.raw))

  of iekNotice:
    let nKey = evt.pmTarget.toLowerAscii()
    if nKey in server.channels:
      server.channels[nKey].lastActivity = epochTime()
    result.add(makeBufferedMessage(server, "notice",
      evt.pmSource, evt.pmTarget, evt.pmText,
      prefix = evt.pmPrefix.raw))

  of iekJoin:
    let key = chanKey(evt.joinChannel)
    if evt.joinNick == server.currentNick:
      # Self-join: create channel if not exists
      if key notin server.channels:
        server.channels[key] = ChannelState(
          name: evt.joinChannel,
          users: initTable[string, string](),
        )
      server.channels[key].users[evt.joinNick] = ""
    else:
      if key in server.channels:
        server.channels[key].users[evt.joinNick] = ""
    result.add(makeBufferedMessage(server, "join",
      evt.joinNick, evt.joinChannel, "",
      prefix = evt.joinPrefix.raw))

  of iekPart:
    let key = chanKey(evt.partChannel)
    if evt.partNick == server.currentNick:
      # Self-part: remove channel
      server.channels.del(key)
    else:
      if key in server.channels:
        server.channels[key].users.del(evt.partNick)
    result.add(makeBufferedMessage(server, "part",
      evt.partNick, evt.partChannel, evt.partReason,
      prefix = evt.partPrefix.raw))

  of iekKick:
    let key = chanKey(evt.kickChannel)
    if evt.kickNick == server.currentNick:
      server.channels.del(key)
    else:
      if key in server.channels:
        server.channels[key].users.del(evt.kickNick)
    result.add(makeBufferedMessage(server, "kick",
      evt.kickBy, evt.kickChannel, evt.kickReason & " (kicked " & evt.kickNick & ")"))

  of iekQuit:
    # Remove user from all channels
    for key in server.channels.keys:
      server.channels[key].users.del(evt.quitNick)
    result.add(makeBufferedMessage(server, "quit",
      evt.quitNick, "", evt.quitReason,
      prefix = evt.quitPrefix.raw))

  of iekNick:
    # Rename user in all channels
    for key in server.channels.keys:
      if evt.nickOld in server.channels[key].users:
        let prefix = server.channels[key].users[evt.nickOld]
        server.channels[key].users.del(evt.nickOld)
        server.channels[key].users[evt.nickNew] = prefix
    if evt.nickOld == server.currentNick:
      server.currentNick = evt.nickNew
    result.add(makeBufferedMessage(server, "nick",
      evt.nickOld, "", evt.nickNew))

  of iekTopic:
    let key = chanKey(evt.topicChannel)
    if key in server.channels:
      server.channels[key].topic = evt.topicText
      server.channels[key].topicSetBy = evt.topicBy
      server.channels[key].topicSetAt = $epochTime()
    result.add(makeBufferedMessage(server, "topic",
      evt.topicBy, evt.topicChannel, evt.topicText))

  of iekMode:
    let key = chanKey(evt.modeTarget)
    if key in server.channels:
      # Track channel mode changes (simplified — just store the modes string)
      server.channels[key].modes = evt.modeChanges
      # Update user prefixes for +o/-o, +v/-v etc.
      if evt.modeParams.len > 0:
        var adding = true
        var paramIdx = 0
        for c in evt.modeChanges:
          if c == '+': adding = true
          elif c == '-': adding = false
          elif c in {'o', 'v', 'h', 'a', 'q'} and paramIdx < evt.modeParams.len:
            let nick = evt.modeParams[paramIdx]
            paramIdx += 1
            if nick in server.channels[key].users:
              if adding:
                let prefix = case c
                  of 'o': "@"
                  of 'v': "+"
                  of 'h': "%"
                  of 'a': "&"
                  of 'q': "~"
                  else: ""
                server.channels[key].users[nick] = prefix
              else:
                server.channels[key].users[nick] = ""
          elif c in {'b', 'e', 'I', 'k'} and paramIdx < evt.modeParams.len:
            paramIdx += 1  # These modes take params but don't affect user prefix
    result.add(makeBufferedMessage(server, "mode",
      evt.modeTarget, evt.modeTarget, evt.modeChanges & " " & evt.modeParams.join(" ")))

  of iekNumeric:
    case evt.numCode
    of 353:  # RPL_NAMREPLY
      # :server 353 nick = #channel :@op +voice user
      if evt.numParams.len >= 3:
        let channel = evt.numParams[2]
        let key = chanKey(channel)
        if key in server.channels:
          let namesStr = if evt.numParams.len > 3: evt.numParams[3] else: ""
          let entries = namesStr.split(' ')
          for entry in entries:
            if entry.len > 0:
              let (nick, prefix) = parseNamesUser(entry)
              if nick.len > 0:
                server.channels[key].users[nick] = prefix
      # Don't buffer NAMES reply

    of 366:  # RPL_ENDOFNAMES
      discard  # Don't buffer

    of 332:  # RPL_TOPIC
      if evt.numParams.len >= 3:
        let channel = evt.numParams[1]
        let key = chanKey(channel)
        if key in server.channels:
          server.channels[key].topic = evt.numParams[2]
      # Don't buffer (we buffer iekTopic instead)

    of 333:  # RPL_TOPICWHOTIME
      if evt.numParams.len >= 4:
        let channel = evt.numParams[1]
        let key = chanKey(channel)
        if key in server.channels:
          server.channels[key].topicSetBy = evt.numParams[2]
          server.channels[key].topicSetAt = evt.numParams[3]

    else:
      discard  # Don't buffer other numerics

  of iekCtcp:
    if evt.ctcpCommand == "ACTION":
      result.add(makeBufferedMessage(server, "action",
        evt.ctcpSource, evt.ctcpTarget, evt.ctcpArgs,
        prefix = evt.ctcpPrefix.raw))

  of iekAway:
    if evt.awayNick == server.currentNick:
      server.isAway = evt.awayMessage.len > 0

  else:
    discard  # Other events don't update state or produce buffered messages
