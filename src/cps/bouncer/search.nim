## CPS IRC Bouncer - Message Search
##
## Search across all message buffers matching text, nick, channel, and server filters.

import std/[tables, strutils]
import ./types
import ./buffer

type
  SearchQuery* = object
    text*: string           ## Text pattern (substring match, case-insensitive)
    nick*: string           ## Filter by source nick (case-insensitive)
    channel*: string        ## Filter by channel (case-insensitive)
    serverName*: string     ## Filter by server name (case-insensitive)
    limit*: int             ## Max results (default 50)
    before*: int64          ## Messages before this ID
    after*: int64           ## Messages after this ID

  SearchResult* = object
    messages*: seq[BufferedMessage]
    hasMore*: bool

proc matchesQuery(msg: BufferedMessage, query: SearchQuery, bufKey: string): bool =
  ## Check if a single message matches the search query.
  # Server filter
  if query.serverName.len > 0:
    let colonIdx = bufKey.find(':')
    if colonIdx >= 0:
      let server = bufKey[0 ..< colonIdx]
      if server.toLowerAscii() != query.serverName.toLowerAscii():
        return false

  # Channel filter
  if query.channel.len > 0:
    if msg.target.toLowerAscii() != query.channel.toLowerAscii():
      return false

  # Nick filter
  if query.nick.len > 0:
    if msg.source.toLowerAscii() != query.nick.toLowerAscii():
      return false

  # ID range filters
  if query.before > 0 and msg.id >= query.before:
    return false
  if query.after > 0 and msg.id <= query.after:
    return false

  # Text filter (substring, case-insensitive)
  if query.text.len > 0:
    if msg.text.toLowerAscii().find(query.text.toLowerAscii()) < 0:
      return false

  # Only search message-like kinds
  if msg.kind notin ["privmsg", "notice", "action"]:
    return false

  return true

proc getBufferKeyList(bouncer: Bouncer): seq[string] =
  ## Get all buffer keys (non-CPS helper).
  result = @[]
  for key in bouncer.buffers.keys:
    result.add(key)

proc searchBuffers*(bouncer: Bouncer, query: SearchQuery): SearchResult =
  ## Search across all message buffers matching the query.
  let limit = if query.limit > 0: query.limit else: 50
  result.messages = @[]
  result.hasMore = false

  let keys = getBufferKeyList(bouncer)
  for key in keys:
    if key notin bouncer.buffers:
      continue
    let rb = bouncer.buffers[key]
    let messages = rb.getAllMessages()
    for msg in messages:
      if matchesQuery(msg, query, key):
        result.messages.add(msg)
        if result.messages.len > limit:
          result.hasMore = true
          result.messages.setLen(limit)
          return
