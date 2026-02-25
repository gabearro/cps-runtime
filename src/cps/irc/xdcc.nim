## CPS IRC XDCC Client
##
## XDCC (eXtended DCC) support for IRC file sharing bots.
##
## XDCC is a command layer on top of DCC SEND. Users send commands via
## plain PRIVMSG to bots, and bots respond with DCC SEND offers for the
## actual file transfers.
##
## Supported commands:
##   XDCC SEND #N     — Request pack number N
##   XDCC GET #N      — Alias for SEND
##   XDCC BATCH N-M   — Request packs N through M
##   XDCC BATCH N,M,O — Request specific packs
##   XDCC LIST        — Request pack listing (via NOTICE)
##   XDCC SEND LIST   — Request pack listing via DCC SEND (as file)
##   XDCC SEND -1     — Alias for SEND LIST
##   XDCC SEARCH term — Search packs by keyword
##   XDCC INFO #N     — Get info on a specific pack
##   XDCC QUEUE       — Check your queue position
##   XDCC CANCEL      — Cancel active transfer
##   XDCC REMOVE      — Remove all queued packs
##   XDCC REMOVE #N   — Remove specific pack from queue
##   XDCC HELP        — Show bot's help text
##
## All commands are sent as:  PRIVMSG botname :XDCC <command>

import std/[strutils, options, tables, times]
import ../runtime
import ../transform
import ../eventloop
import ../concurrency/channels
import ./protocol
import ./client
import ./dcc

export client, dcc, protocol

type
  XdccPack* = object
    ## A single pack offered by an XDCC bot.
    number*: int              ## Pack number
    filename*: string         ## Filename
    filesize*: string         ## Size as displayed (e.g., "1.4G", "700M")
    filesizeBytes*: int64     ## Size in bytes (-1 if unknown)
    downloads*: int           ## Number of times downloaded (-1 if unknown)
    description*: string      ## Optional description/info text
    md5*: string              ## MD5 hash (from XDCC INFO, if available)
    crc32*: string            ## CRC32 hash (from XDCC INFO, if available)

  XdccBotInfo* = object
    ## Information about an XDCC bot.
    nick*: string             ## Bot's nickname
    totalPacks*: int          ## Total number of packs
    slotsOpen*: int           ## Open transfer slots (-1 if unknown)
    slotsTotal*: int          ## Total transfer slots (-1 if unknown)
    queueSize*: int           ## Number of users in queue (-1 if unknown)
    record*: string           ## Record transfer speed
    packs*: seq[XdccPack]     ## Known packs

  XdccQueueEntry* = object
    ## A queued transfer.
    botNick*: string          ## Bot nickname
    packNumber*: int          ## Pack number requested
    position*: int            ## Queue position (-1 if unknown)
    estimatedWait*: string    ## Estimated wait time (bot's string)

  XdccEventKind* = enum
    xekPackList             ## Pack list received (partial or complete)
    xekPackInfo             ## Pack info received
    xekSearchResult         ## Search results received
    xekTransferStarting     ## Bot is starting a DCC SEND for our request
    xekQueued               ## Request was queued (slots full)
    xekQueueUpdate          ## Queue position update
    xekTransferComplete     ## Bot reported transfer complete
    xekNoSuchPack           ## Pack not found
    xekDenied               ## Request denied (flood, banned, etc.)
    xekBotMessage           ## Other message from bot
    xekDccOffer             ## DCC SEND received from bot (actual transfer)

  XdccEvent* = object
    case kind*: XdccEventKind
    of xekPackList:
      plBotNick*: string
      plPacks*: seq[XdccPack]
    of xekPackInfo:
      piBotNick*: string
      piPack*: XdccPack
    of xekSearchResult:
      srBotNick*: string
      srPacks*: seq[XdccPack]
    of xekTransferStarting:
      tsBotNick*: string
      tsPackNumber*: int
      tsFilename*: string
    of xekQueued:
      qBotNick*: string
      qPackNumber*: int
      qPosition*: int
      qEstimatedWait*: string
    of xekQueueUpdate:
      quBotNick*: string
      quEntries*: seq[XdccQueueEntry]
    of xekTransferComplete:
      tcBotNick*: string
      tcFilename*: string
      tcMessage*: string
    of xekNoSuchPack:
      nspBotNick*: string
      nspPackNumber*: int
    of xekDenied:
      dBotNick*: string
      dReason*: string
    of xekBotMessage:
      bmBotNick*: string
      bmText*: string
    of xekDccOffer:
      doBotNick*: string
      doTransfer*: DccTransfer
      doPackNumber*: int      ## -1 if unknown

  XdccRequest = object
    ## Internal: tracks a pending XDCC request.
    botNick: string
    packNumber: int           ## -1 for LIST, -2 for SEARCH
    requestTime: DateTime

  XdccClient* = ref object
    ## High-level XDCC client built on top of IrcClient.
    ## Manages XDCC commands, parses bot responses, and tracks transfers.
    ircClient*: IrcClient
    dccManager*: DccManager
    events*: AsyncChannel[XdccEvent]
    bots*: Table[string, XdccBotInfo]  ## Known bot info by lowercase nick
    pendingRequests: seq[XdccRequest]
    autoAccept*: bool         ## Auto-accept DCC offers from requested bots
    trackedBots: seq[string]  ## Bots we're listening to (lowercase nicks)

# ============================================================
# XDCC command formatting
# ============================================================

proc formatXdccSend*(packNumber: int): string =
  ## Format XDCC SEND command. Use pack number or -1 for list.
  if packNumber == -1:
    "XDCC SEND -1"
  else:
    "XDCC SEND #" & $packNumber

proc formatXdccGet*(packNumber: int): string =
  ## Format XDCC GET command (alias for SEND).
  "XDCC GET #" & $packNumber

proc formatXdccBatchRange*(start, finish: int): string =
  ## Format XDCC BATCH range command.
  "XDCC BATCH " & $start & "-" & $finish

proc formatXdccBatchList*(packs: openArray[int]): string =
  ## Format XDCC BATCH comma-separated command.
  result = "XDCC BATCH "
  for i, p in packs:
    if i > 0: result.add(',')
    result.add($p)

proc formatXdccList*(): string = "XDCC LIST"
proc formatXdccSearch*(terms: string): string = "XDCC SEARCH " & terms
proc formatXdccInfo*(packNumber: int): string = "XDCC INFO #" & $packNumber
proc formatXdccQueue*(): string = "XDCC QUEUE"
proc formatXdccCancel*(): string = "XDCC CANCEL"
proc formatXdccRemoveAll*(): string = "XDCC REMOVE"

proc formatXdccRemove*(packNumber: int): string =
  "XDCC REMOVE #" & $packNumber

proc formatXdccHelp*(): string = "XDCC HELP"

# ============================================================
# Pack list parsing
# ============================================================

proc parseSizeToBytes(sizeStr: string): int64 =
  ## Parse a size string like "1.4G", "700M", "350K" to bytes.
  let s = sizeStr.strip()
  if s.len == 0: return -1
  let lastChar = s[^1].toLowerAscii()
  try:
    case lastChar
    of 'g':
      return int64(parseFloat(s[0 ..< s.len - 1]) * 1073741824.0)
    of 'm':
      return int64(parseFloat(s[0 ..< s.len - 1]) * 1048576.0)
    of 'k':
      return int64(parseFloat(s[0 ..< s.len - 1]) * 1024.0)
    of 'b':
      # Could be "350MB", "1.4GB", "500KB", or just "12345B"
      if s.len >= 3:
        let prefix = s[s.len - 2].toLowerAscii()
        case prefix
        of 'g': return int64(parseFloat(s[0 ..< s.len - 2]) * 1073741824.0)
        of 'm': return int64(parseFloat(s[0 ..< s.len - 2]) * 1048576.0)
        of 'k': return int64(parseFloat(s[0 ..< s.len - 2]) * 1024.0)
        else: return parseBiggestInt(s[0 ..< s.len - 1])
      else:
        return parseBiggestInt(s[0 ..< s.len - 1])
    of '0'..'9':
      return parseBiggestInt(s)
    else:
      return -1
  except ValueError:
    return -1

proc parsePackLine*(line: string): Option[XdccPack] =
  ## Parse a pack listing line.
  ## Common formats:
  ##   #1  3x [1.2G] SomeFile.mkv
  ##   #2  1x [700M] AnotherFile.avi
  ##   #1 12x [1.4G] SomeFile.mkv
  ##   Pack #1: filename.ext (1.2GB) - downloaded 3 times
  let stripped = line.strip()
  if stripped.len == 0: return none(XdccPack)

  var pack: XdccPack
  pack.filesizeBytes = -1
  pack.downloads = -1

  # Look for pack number: #N at start
  var pos = 0

  # Skip leading whitespace and find #
  while pos < stripped.len and stripped[pos] in {' ', '\t'}:
    inc pos

  if pos >= stripped.len or stripped[pos] != '#':
    return none(XdccPack)

  inc pos  # skip '#'
  var numStr = ""
  while pos < stripped.len and stripped[pos] in {'0'..'9'}:
    numStr.add(stripped[pos])
    inc pos

  if numStr.len == 0:
    return none(XdccPack)
  pack.number = parseInt(numStr)

  # Skip whitespace
  while pos < stripped.len and stripped[pos] in {' ', '\t'}:
    inc pos

  # Look for download count: Nx (optional)
  var remaining = stripped[pos .. ^1].strip()
  let xIdx = remaining.find('x')
  if xIdx > 0 and xIdx < 10:
    # Check if everything before 'x' is a number
    let beforeX = remaining[0 ..< xIdx].strip()
    var isNum = true
    for ch in beforeX:
      if ch notin {'0'..'9'}:
        isNum = false
        break
    if isNum and beforeX.len > 0:
      pack.downloads = parseInt(beforeX)
      remaining = remaining[xIdx + 1 .. ^1].strip()

  # Look for size in brackets: [1.2G] or [700M]
  if remaining.len > 0 and remaining[0] == '[':
    let closeIdx = remaining.find(']')
    if closeIdx > 0:
      let sizeStr = remaining[1 ..< closeIdx]
      pack.filesize = sizeStr
      pack.filesizeBytes = parseSizeToBytes(sizeStr)
      remaining = remaining[closeIdx + 1 .. ^1].strip()

  # Rest is the filename
  if remaining.len > 0:
    pack.filename = remaining
  else:
    return none(XdccPack)

  result = some(pack)

# ============================================================
# Bot response parsing
# ============================================================

proc parseXdccNotice*(botNick, text: string): Option[XdccEvent] =
  ## Parse a NOTICE or PRIVMSG from a bot for XDCC-specific content.
  ## Returns an XdccEvent if recognized, none otherwise.
  let lower = text.toLowerAscii()

  # "Sending you pack #N ..."
  if lower.contains("sending you pack") or lower.contains("sending pack"):
    var packNum = -1
    let hashIdx = lower.find('#')
    if hashIdx >= 0:
      var numStr = ""
      var i = hashIdx + 1
      while i < text.len and text[i] in {'0'..'9'}:
        numStr.add(text[i])
        inc i
      if numStr.len > 0:
        packNum = parseInt(numStr)
    # Try to extract filename
    var filename = ""
    let quoteIdx = text.find('"')
    if quoteIdx >= 0:
      let closeQuote = text.find('"', quoteIdx + 1)
      if closeQuote > quoteIdx:
        filename = text[quoteIdx + 1 ..< closeQuote]
    return some(XdccEvent(kind: xekTransferStarting,
                          tsBotNick: botNick,
                          tsPackNumber: packNum,
                          tsFilename: filename))

  # Queue notification: "queued", "queue position", "added to queue"
  if lower.contains("queue") and (lower.contains("position") or
     lower.contains("added") or lower.contains("queued")):
    var packNum = -1
    var position = -1
    var waitStr = ""

    # Extract pack number
    let hashIdx = lower.find('#')
    if hashIdx >= 0:
      var numStr = ""
      var i = hashIdx + 1
      while i < text.len and text[i] in {'0'..'9'}:
        numStr.add(text[i])
        inc i
      if numStr.len > 0:
        packNum = parseInt(numStr)

    # Extract position number (look for "position N" or "position: N")
    let posIdx = lower.find("position")
    if posIdx >= 0:
      var i = posIdx + 8  # len("position")
      while i < text.len and text[i] in {' ', ':', '\t'}:
        inc i
      var numStr = ""
      while i < text.len and text[i] in {'0'..'9'}:
        numStr.add(text[i])
        inc i
      if numStr.len > 0:
        position = parseInt(numStr)

    # Extract estimated wait
    let waitIdx = lower.find("estimated")
    if waitIdx >= 0:
      let colonIdx = text.find(':', waitIdx)
      if colonIdx >= 0 and colonIdx < text.len - 1:
        waitStr = text[colonIdx + 1 .. ^1].strip()
    elif lower.contains("wait"):
      let wIdx = lower.find("wait")
      let colonIdx2 = text.find(':', wIdx)
      if colonIdx2 >= 0 and colonIdx2 < text.len - 1:
        waitStr = text[colonIdx2 + 1 .. ^1].strip()

    return some(XdccEvent(kind: xekQueued,
                          qBotNick: botNick,
                          qPackNumber: packNum,
                          qPosition: position,
                          qEstimatedWait: waitStr))

  # Transfer complete
  if lower.contains("transfer complete") or lower.contains("download complete"):
    return some(XdccEvent(kind: xekTransferComplete,
                          tcBotNick: botNick,
                          tcFilename: "",
                          tcMessage: text))

  # No such pack
  if lower.contains("invalid pack") or lower.contains("no such pack") or
     lower.contains("pack not found"):
    var packNum = -1
    let hashIdx = lower.find('#')
    if hashIdx >= 0:
      var numStr = ""
      var i = hashIdx + 1
      while i < text.len and text[i] in {'0'..'9'}:
        numStr.add(text[i])
        inc i
      if numStr.len > 0:
        packNum = parseInt(numStr)
    return some(XdccEvent(kind: xekNoSuchPack,
                          nspBotNick: botNick,
                          nspPackNumber: packNum))

  # Denied: flood, banned, etc.
  if lower.contains("denied") or lower.contains("ignored") or
     lower.contains("banned") or lower.contains("throttled") or
     lower.contains("you are being ignored"):
    return some(XdccEvent(kind: xekDenied,
                          dBotNick: botNick,
                          dReason: text))

  # "All slots full" (without queue info — some bots just reject)
  if lower.contains("all slots full") and not lower.contains("queue"):
    return some(XdccEvent(kind: xekDenied,
                          dBotNick: botNick,
                          dReason: text))

  # Pack listing lines (from XDCC LIST via NOTICE)
  let packOpt = parsePackLine(text)
  if packOpt.isSome:
    return some(XdccEvent(kind: xekPackList,
                          plBotNick: botNick,
                          plPacks: @[packOpt.get()]))

  return none(XdccEvent)

# ============================================================
# Channel announcement parsing
# ============================================================

proc extractNumberBefore(text: string, keyword: string): int =
  ## Find a number immediately before a keyword in text. Returns -1 if not found.
  let idx = text.toLowerAscii().find(keyword.toLowerAscii())
  if idx <= 0: return -1
  var numEnd = idx - 1
  while numEnd >= 0 and text[numEnd] == ' ':
    dec numEnd
  if numEnd < 0 or text[numEnd] notin {'0'..'9'}:
    return -1
  var numStart = numEnd
  while numStart > 0 and text[numStart - 1] in {'0'..'9', ',', '.'}:
    dec numStart
  let numStr = text[numStart .. numEnd].replace(",", "")
  try: return parseInt(numStr)
  except ValueError: return -1

proc extractNumberAfterLabel(text: string, label: string): int =
  ## Extract a number after "Label:" or "Label: " in text. Returns -1 if not found.
  let lower = text.toLowerAscii()
  let idx = lower.find(label.toLowerAscii())
  if idx < 0: return -1
  var i = idx + label.len
  # Skip ':'  and whitespace
  while i < text.len and text[i] in {':', ' ', '\t'}:
    inc i
  var numStr = ""
  while i < text.len and text[i] in {'0'..'9', ','}:
    numStr.add(text[i])
    inc i
  numStr = numStr.replace(",", "")
  if numStr.len == 0: return -1
  try: return parseInt(numStr)
  except ValueError: return -1

proc extractSlashPair(text: string, label: string): tuple[a, b: int] =
  ## Extract "N/M" after a label. Returns (-1, -1) if not found.
  result = (-1, -1)
  let lower = text.toLowerAscii()
  let idx = lower.find(label.toLowerAscii())
  if idx < 0: return
  var i = idx + label.len
  while i < text.len and text[i] in {':', ' ', '\t'}:
    inc i
  var aStr = ""
  while i < text.len and text[i] in {'0'..'9'}:
    aStr.add(text[i]); inc i
  if i < text.len and text[i] == '/':
    inc i
    var bStr = ""
    while i < text.len and text[i] in {'0'..'9'}:
      bStr.add(text[i]); inc i
    if aStr.len > 0 and bStr.len > 0:
      try: result = (parseInt(aStr), parseInt(bStr))
      except ValueError: discard
  elif aStr.len > 0:
    try: result.a = parseInt(aStr)
    except ValueError: discard

proc parseXdccAnnouncement*(nick, text: string): Option[XdccBotInfo] =
  ## Parse a bot's channel announcement to extract bot info.
  ## Strips IRC color/formatting codes before parsing.
  ##
  ## Supported formats:
  ##   XDCC style:    ** 5 packs ** 3 of 5 slots open, Record: 45.2KB/s
  ##   FWServer style: Type: @bot For My List Of: 1,384,329 Files  Slots: 15/15  Queued: 0
  ##   ServBot style:  Type: @bot for my list of 526903 files. Updated: 2026-02-19.
  let clean = stripIrcFormatting(text)
  let lower = clean.toLowerAscii()

  # Must contain file/pack count AND slot information to be a bot ad
  let hasFiles = lower.contains("file") or lower.contains("pack")
  let hasSlots = lower.contains("slot")
  if not (hasFiles and hasSlots):
    return none(XdccBotInfo)

  var info = XdccBotInfo(
    nick: nick,
    slotsOpen: -1,
    slotsTotal: -1,
    queueSize: -1,
  )

  # === FWServer/ServBot format ===
  # "Type: @bot For My List Of: 1,384,329 Files  Slots: 15/15  Queued: 0"
  if lower.contains("type:") and (lower.contains("list of") or lower.contains("files")):
    # Extract file/pack count: "List Of: N Files" or "N files"
    let filesCount = extractNumberBefore(clean, "files")
    if filesCount > 0:
      info.totalPacks = filesCount
    else:
      info.totalPacks = extractNumberBefore(clean, "file")

    # Slots: "Slots: N/M" or "Slots: N"
    let slots = extractSlashPair(clean, "slots")
    if slots.b > 0:
      info.slotsOpen = slots.a
      info.slotsTotal = slots.b
    elif slots.a >= 0:
      info.slotsOpen = slots.a

    # Queued: N
    info.queueSize = extractNumberAfterLabel(clean, "queued")

    # Record speed
    let recIdx = lower.find("speed")
    if recIdx >= 0:
      var i = recIdx + 5
      while i < clean.len and clean[i] in {':', ' '}:
        inc i
      var speedEnd = i
      while speedEnd < clean.len and clean[speedEnd] notin {' ', '\t'}:
        inc speedEnd
      if speedEnd > i:
        info.record = clean[i ..< speedEnd]

    return some(info)

  # === Standard XDCC announcement ===
  # "** N packs ** N of M slots open, Record: 45.2KB/s"
  info.totalPacks = extractNumberBefore(clean, "pack")

  # "N of M slots"
  let slotIdx = lower.find("slot")
  if slotIdx > 0:
    let beforeSlots = lower[0 ..< slotIdx].strip()
    let ofIdx = beforeSlots.rfind(" of ")
    if ofIdx >= 0:
      let afterOf = beforeSlots[ofIdx + 4 .. ^1].strip()
      let beforeOf = beforeSlots[0 ..< ofIdx]
      # Last number before "of"
      var numStr = ""
      for i in countdown(beforeOf.len - 1, 0):
        if beforeOf[i] in {'0'..'9'}:
          numStr = beforeOf[i] & numStr
        elif numStr.len > 0:
          break
      if numStr.len > 0:
        try: info.slotsOpen = parseInt(numStr) except ValueError: discard
      # Number after "of"
      numStr = ""
      for ch in afterOf:
        if ch in {'0'..'9'}:
          numStr.add(ch)
        elif numStr.len > 0:
          break
      if numStr.len > 0:
        try: info.slotsTotal = parseInt(numStr) except ValueError: discard
    else:
      # Try "N/M" pattern
      let slots = extractSlashPair(clean, "slots")
      if slots.b > 0:
        info.slotsOpen = slots.a
        info.slotsTotal = slots.b

  # Record speed
  let recIdx = lower.find("record")
  if recIdx >= 0:
    let colonIdx = clean.find(':', recIdx)
    if colonIdx >= 0 and colonIdx < clean.len - 1:
      let rest = clean[colonIdx + 1 .. ^1].strip()
      let endIdx = rest.find(',')
      info.record = if endIdx >= 0: rest[0 ..< endIdx].strip()
                    else: rest.strip()

  result = some(info)

# ============================================================
# XdccClient creation
# ============================================================

proc newXdccClient*(ircClient: IrcClient,
                    downloadDir: string = "downloads",
                    eventBufferSize: int = 256): XdccClient =
  XdccClient(
    ircClient: ircClient,
    dccManager: newDccManager(downloadDir),
    events: newAsyncChannel[XdccEvent](eventBufferSize),
    bots: initTable[string, XdccBotInfo](),
    autoAccept: true,
  )

proc newXdccClient*(host: string, port: int = 6667,
                    nick: string = "xdccbot",
                    downloadDir: string = "downloads"): XdccClient =
  let config = newIrcClientConfig(host, port, nick)
  let client = newIrcClient(config)
  newXdccClient(client, downloadDir)

# ============================================================
# Bot tracking
# ============================================================

proc trackBot*(xdcc: XdccClient, botNick: string) =
  ## Start tracking messages from a specific bot.
  let lower = botNick.toLowerAscii()
  if lower notin xdcc.trackedBots:
    xdcc.trackedBots.add(lower)

proc untrackBot*(xdcc: XdccClient, botNick: string) =
  ## Stop tracking a bot.
  let lower = botNick.toLowerAscii()
  var i = 0
  while i < xdcc.trackedBots.len:
    if xdcc.trackedBots[i] == lower:
      xdcc.trackedBots.delete(i)
      return
    inc i

proc isTracked*(xdcc: XdccClient, nick: string): bool =
  ## Check if a bot nick is being tracked.
  nick.toLowerAscii() in xdcc.trackedBots

proc hasPendingRequest(xdcc: XdccClient, botNick: string): bool =
  let lower = botNick.toLowerAscii()
  for req in xdcc.pendingRequests:
    if req.botNick == lower:
      return true

# ============================================================
# XDCC commands (high-level)
# ============================================================

proc xdccSend*(xdcc: XdccClient, botNick: string,
               packNumber: int): CpsVoidFuture {.cps.} =
  ## Request a pack from a bot via XDCC SEND.
  xdcc.trackBot(botNick)
  xdcc.pendingRequests.add(XdccRequest(
    botNick: botNick.toLowerAscii(),
    packNumber: packNumber,
    requestTime: now(),
  ))
  await xdcc.ircClient.privMsg(botNick, formatXdccSend(packNumber))

proc xdccGet*(xdcc: XdccClient, botNick: string,
              packNumber: int): CpsVoidFuture {.cps.} =
  ## Request a pack from a bot via XDCC GET (alias for SEND).
  xdcc.trackBot(botNick)
  xdcc.pendingRequests.add(XdccRequest(
    botNick: botNick.toLowerAscii(),
    packNumber: packNumber,
    requestTime: now(),
  ))
  await xdcc.ircClient.privMsg(botNick, formatXdccGet(packNumber))

proc xdccBatch*(xdcc: XdccClient, botNick: string,
                start, finish: int): CpsVoidFuture {.cps.} =
  ## Request a range of packs via XDCC BATCH.
  xdcc.trackBot(botNick)
  for i in start .. finish:
    xdcc.pendingRequests.add(XdccRequest(
      botNick: botNick.toLowerAscii(),
      packNumber: i,
      requestTime: now(),
    ))
  await xdcc.ircClient.privMsg(botNick, formatXdccBatchRange(start, finish))

proc xdccBatchPacks*(xdcc: XdccClient, botNick: string,
                     packs: seq[int]): CpsVoidFuture {.cps.} =
  ## Request specific packs via XDCC BATCH (comma-separated).
  xdcc.trackBot(botNick)
  for p in packs:
    xdcc.pendingRequests.add(XdccRequest(
      botNick: botNick.toLowerAscii(),
      packNumber: p,
      requestTime: now(),
    ))
  await xdcc.ircClient.privMsg(botNick, formatXdccBatchList(packs))

proc xdccList*(xdcc: XdccClient, botNick: string): CpsVoidFuture {.cps.} =
  ## Request the bot's pack list (via NOTICE messages).
  xdcc.trackBot(botNick)
  await xdcc.ircClient.privMsg(botNick, formatXdccList())

proc xdccSendList*(xdcc: XdccClient, botNick: string): CpsVoidFuture {.cps.} =
  ## Request the bot's pack list as a DCC file transfer.
  xdcc.trackBot(botNick)
  xdcc.pendingRequests.add(XdccRequest(
    botNick: botNick.toLowerAscii(),
    packNumber: -1,
    requestTime: now(),
  ))
  await xdcc.ircClient.privMsg(botNick, formatXdccSend(-1))

proc xdccSearch*(xdcc: XdccClient, botNick: string,
                 terms: string): CpsVoidFuture {.cps.} =
  ## Search a bot's packs by keyword.
  xdcc.trackBot(botNick)
  await xdcc.ircClient.privMsg(botNick, formatXdccSearch(terms))

proc xdccInfo*(xdcc: XdccClient, botNick: string,
               packNumber: int): CpsVoidFuture {.cps.} =
  ## Get detailed info on a specific pack.
  xdcc.trackBot(botNick)
  await xdcc.ircClient.privMsg(botNick, formatXdccInfo(packNumber))

proc xdccQueue*(xdcc: XdccClient, botNick: string): CpsVoidFuture {.cps.} =
  ## Check your queue position on a bot.
  await xdcc.ircClient.privMsg(botNick, formatXdccQueue())

proc xdccCancel*(xdcc: XdccClient, botNick: string): CpsVoidFuture {.cps.} =
  ## Cancel the active transfer from a bot.
  await xdcc.ircClient.privMsg(botNick, formatXdccCancel())

proc xdccRemove*(xdcc: XdccClient, botNick: string,
                 packNumber: int = -1): CpsVoidFuture {.cps.} =
  ## Remove queued packs. Use -1 to remove all.
  if packNumber < 0:
    await xdcc.ircClient.privMsg(botNick, formatXdccRemoveAll())
  else:
    await xdcc.ircClient.privMsg(botNick, formatXdccRemove(packNumber))
  # Clean up pending requests
  let lower = botNick.toLowerAscii()
  var i = 0
  while i < xdcc.pendingRequests.len:
    if xdcc.pendingRequests[i].botNick == lower:
      if packNumber < 0 or xdcc.pendingRequests[i].packNumber == packNumber:
        xdcc.pendingRequests.delete(i)
        continue
    inc i

proc xdccHelp*(xdcc: XdccClient, botNick: string): CpsVoidFuture {.cps.} =
  ## Request help text from a bot.
  await xdcc.ircClient.privMsg(botNick, formatXdccHelp())

# ============================================================
# Internal: process IRC events for XDCC
# ============================================================

proc removePendingRequest(xdcc: XdccClient, botNick: string,
                          packNumber: int = -1) =
  let lower = botNick.toLowerAscii()
  var i = 0
  while i < xdcc.pendingRequests.len:
    if xdcc.pendingRequests[i].botNick == lower:
      if packNumber < 0 or xdcc.pendingRequests[i].packNumber == packNumber:
        xdcc.pendingRequests.delete(i)
        return
    inc i

proc processIrcEvent(xdcc: XdccClient, event: IrcEvent): CpsVoidFuture {.cps.} =
  ## Process an IRC event and emit XDCC events.
  case event.kind
  of iekPrivMsg, iekNotice:
    let source = event.pmSource.toLowerAscii()
    # Only process messages from tracked bots or bots we have pending requests for
    if xdcc.isTracked(event.pmSource) or xdcc.hasPendingRequest(event.pmSource):
      let xdccEvt = parseXdccNotice(event.pmSource, event.pmText)
      if xdccEvt.isSome:
        await xdcc.events.send(xdccEvt.get())
      else:
        # Unrecognized but from a tracked bot — pass through
        await xdcc.events.send(XdccEvent(kind: xekBotMessage,
                                          bmBotNick: event.pmSource,
                                          bmText: event.pmText))

    # Also check channel messages for bot announcements
    if event.kind == iekPrivMsg and isChannel(event.pmTarget):
      let botInfo = parseXdccAnnouncement(event.pmSource, event.pmText)
      if botInfo.isSome:
        let info = botInfo.get()
        xdcc.bots[info.nick.toLowerAscii()] = info

  of iekDccSend:
    let source = event.dccSource.toLowerAscii()
    # Check if this DCC SEND is from a bot we requested from
    if xdcc.isTracked(event.dccSource) or xdcc.hasPendingRequest(event.dccSource):
      let transfer = xdcc.dccManager.addOffer(event.dccSource, event.dccInfo)

      # Find which pack this corresponds to
      var packNum = -1
      for req in xdcc.pendingRequests:
        if req.botNick == source:
          packNum = req.packNumber
          break

      await xdcc.events.send(XdccEvent(kind: xekDccOffer,
                                        doBotNick: event.dccSource,
                                        doTransfer: transfer,
                                        doPackNumber: packNum))

      # Auto-accept if enabled
      if xdcc.autoAccept:
        await receiveDcc(transfer)
        if transfer.state == dtsCompleted:
          await xdcc.events.send(XdccEvent(kind: xekTransferComplete,
                                            tcBotNick: event.dccSource,
                                            tcFilename: event.dccInfo.filename,
                                            tcMessage: "Downloaded " &
                                              $transfer.bytesReceived & " bytes"))
        xdcc.removePendingRequest(event.dccSource, packNum)

  else:
    discard

# ============================================================
# Main run loop
# ============================================================

proc run*(xdcc: XdccClient): CpsVoidFuture {.cps.} =
  ## Start the XDCC client. Connects IRC and processes events.
  ## The IRC client must already be running (call ircClient.run() first),
  ## or pass startIrc=true.
  while true:
    let ircEvent: IrcEvent = await xdcc.ircClient.events.recv()
    await xdcc.processIrcEvent(ircEvent)

proc runWithIrc*(xdcc: XdccClient): CpsVoidFuture {.cps.} =
  ## Start both the IRC client and XDCC event processing.
  let ircFut = xdcc.ircClient.run()
  while true:
    let ircEvent: IrcEvent = await xdcc.ircClient.events.recv()
    await xdcc.processIrcEvent(ircEvent)

# ============================================================
# Convenience: find packs
# ============================================================

proc findPack*(xdcc: XdccClient, botNick: string,
               packNumber: int): Option[XdccPack] =
  ## Look up a pack by number from cached bot info.
  let lower = botNick.toLowerAscii()
  if lower in xdcc.bots:
    for pack in xdcc.bots[lower].packs:
      if pack.number == packNumber:
        return some(pack)
  return none(XdccPack)

proc searchPacks*(xdcc: XdccClient, query: string): seq[tuple[bot: string, pack: XdccPack]] =
  ## Search cached pack info across all known bots.
  let lowerQuery = query.toLowerAscii()
  for botNick, botInfo in xdcc.bots:
    for pack in botInfo.packs:
      if pack.filename.toLowerAscii().contains(lowerQuery) or
         pack.description.toLowerAscii().contains(lowerQuery):
        result.add((bot: botNick, pack: pack))
