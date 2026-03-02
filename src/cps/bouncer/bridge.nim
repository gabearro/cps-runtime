## CPS IRC Bouncer - Client Bridge
##
## Converter utilities shared by TUI and GUI clients for integrating
## with the bouncer daemon. Converts between bouncer protocol messages
## (BouncerMsg/BufferedMessage) and IRC events (IrcEvent).
##
## Usage:
##   import cps/bouncer/bridge
##
## The bridge provides:
## - bouncerMsgToIrcEvent: Convert a bouncer message to an IrcEvent
## - channelStateToIrcEvents: Synthesize IrcEvents from bouncer channel state
## - sendBouncerLine: Write a BouncerMsg as JSON to a stream (non-CPS helper)
## - discoverBouncer: Re-exported from daemon.nim

import std/[options, tables, strutils]
import ../irc/protocol
import ./types
import ./protocol

export protocol.BouncerMsg, protocol.BouncerMsgKind
export protocol.parseBouncerMsg, protocol.toJsonLine
export types.ChannelState, types.BufferedMessage

# Re-export discoverBouncer from daemon
import ./daemon
export daemon.discoverBouncer

# ============================================================
# BufferedMessage -> IrcEvent conversion
# ============================================================

proc bouncerMsgToIrcEvent*(data: BufferedMessage, serverName: string): Option[IrcEvent] =
  ## Convert a bouncer BufferedMessage to an IrcEvent.
  ## Returns none for message kinds that don't map to IrcEvent (e.g. "system" without a target).
  let prefix = parsePrefix(data.prefix)

  case data.kind
  of "privmsg":
    result = some(IrcEvent(kind: iekPrivMsg,
      pmSource: data.source,
      pmTarget: data.target,
      pmText: data.text,
      pmPrefix: prefix))
  of "notice":
    result = some(IrcEvent(kind: iekNotice,
      pmSource: data.source,
      pmTarget: data.target,
      pmText: data.text,
      pmPrefix: prefix))
  of "join":
    result = some(IrcEvent(kind: iekJoin,
      joinNick: data.source,
      joinChannel: data.target,
      joinPrefix: prefix))
  of "part":
    result = some(IrcEvent(kind: iekPart,
      partNick: data.source,
      partChannel: data.target,
      partReason: data.text,
      partPrefix: prefix))
  of "quit":
    result = some(IrcEvent(kind: iekQuit,
      quitNick: data.source,
      quitReason: data.text,
      quitPrefix: prefix))
  of "nick":
    result = some(IrcEvent(kind: iekNick,
      nickOld: data.source,
      nickNew: data.text))
  of "kick":
    # kick: source = kicker, target = channel, text = "kicked_nick reason"
    let kickParts = data.text.split(' ', 1)
    let kickedNick = if kickParts.len > 0: kickParts[0] else: ""
    let kickReason = if kickParts.len > 1: kickParts[1] else: ""
    result = some(IrcEvent(kind: iekKick,
      kickChannel: data.target,
      kickNick: kickedNick,
      kickBy: data.source,
      kickReason: kickReason))
  of "topic":
    result = some(IrcEvent(kind: iekTopic,
      topicChannel: data.target,
      topicText: data.text,
      topicBy: data.source))
  of "mode":
    # mode: source = who set it, target = channel, text = "+o nick"
    let modeParts = data.text.split(' ', 1)
    let changes = if modeParts.len > 0: modeParts[0] else: ""
    var params: seq[string] = @[]
    if modeParts.len > 1:
      params = modeParts[1].split(' ')
    result = some(IrcEvent(kind: iekMode,
      modeTarget: data.target,
      modeChanges: changes,
      modeParams: params))
  of "action":
    result = some(IrcEvent(kind: iekCtcp,
      ctcpSource: data.source,
      ctcpTarget: data.target,
      ctcpCommand: "ACTION",
      ctcpArgs: data.text,
      ctcpPrefix: prefix))
  of "system":
    # System messages become notices from the bouncer
    result = some(IrcEvent(kind: iekNotice,
      pmSource: "bouncer",
      pmTarget: data.target,
      pmText: data.text,
      pmPrefix: IrcPrefix(raw: "bouncer", nick: "bouncer")))
  else:
    result = none(IrcEvent)

# ============================================================
# ChannelState -> synthetic IrcEvents
# ============================================================

proc channelStateToIrcEvents*(serverNick: string, channels: seq[ChannelState]): seq[IrcEvent] =
  ## Convert bouncer server_state channels to synthetic IrcEvents.
  ## Generates: iekJoin for each channel, iekTopic (332) for topic,
  ## and iekNumeric (353 + 366) for user lists.
  result = @[]
  for ch in channels:
    # Synthesize a join event for us
    result.add(IrcEvent(kind: iekJoin,
      joinNick: serverNick,
      joinChannel: ch.name,
      joinPrefix: IrcPrefix(nick: serverNick)))

    # Synthesize topic if present
    if ch.topic.len > 0:
      result.add(IrcEvent(kind: iekTopic,
        topicChannel: ch.name,
        topicText: ch.topic,
        topicBy: ch.topicSetBy))

    # Synthesize NAMES list (353 + 366)
    # Build a single NAMES line with all users and their prefixes
    var namesLine: seq[string] = @[]
    for nick, prefix in ch.users:
      namesLine.add(prefix & nick)
    if namesLine.len > 0:
      result.add(IrcEvent(kind: iekNumeric,
        numCode: 353,
        numParams: @["=", ch.name, namesLine.join(" ")]))
      result.add(IrcEvent(kind: iekNumeric,
        numCode: 366,
        numParams: @[ch.name, "End of /NAMES list."]))

# ============================================================
# Send helper (non-CPS, synchronous for fire-and-forget commands)
# ============================================================

proc buildBouncerLine*(msg: BouncerMsg): string =
  ## Build a JSON line string for a BouncerMsg (with trailing newline).
  msg.toJsonLine() & "\n"
