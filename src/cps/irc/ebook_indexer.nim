## CPS IRC Ebook Indexer
##
## Builds an ebook index from IRC channels (e.g., #ebooks, #bookz).
## Monitors search-bot responses and catalogs available books.
## Supports triggering DCC downloads for indexed books.
##
## Typical IRC ebook workflow:
## 1. Join a channel with a search bot (e.g., @Search or !search)
## 2. Send search queries (e.g., "@search tolkien")
## 3. Bot responds with available books via NOTICE or PRIVMSG
## 4. Request a book (e.g., type the bot's trigger like "!bot_nick book_title")
## 5. Bot sends a DCC SEND offer
## 6. Accept and download via DCC
##
## Book list workflow:
## 1. Send the bot's list command (e.g., "@botname" or "!botname")
## 2. Bot sends a DCC SEND of a text/zip catalog file
## 3. The catalog is downloaded, parsed, and all books are indexed
## 4. Search the local index without further IRC queries

import std/[strutils, tables, options, times, os]
import ../runtime
import ../transform
import ../eventloop
import ../concurrency/channels
import ./protocol
import ./client
import ./dcc

export client, dcc, protocol

type
  BookEntry* = object
    ## A cataloged ebook entry.
    title*: string
    filename*: string
    filesize*: int64          ## File size in bytes (-1 if unknown)
    format*: string           ## File extension (epub, pdf, mobi, etc.)
    botNick*: string          ## Bot that serves this book
    channel*: string          ## Channel where the book was found
    triggerCommand*: string   ## Command to request the book
    firstSeen*: DateTime
    lastSeen*: DateTime

  SearchResult* = object
    ## A search result from a bot response.
    raw*: string              ## Raw response line
    books*: seq[BookEntry]    ## Parsed book entries

  IndexerEventKind* = enum
    idxSearchResult     ## A search result was received and parsed
    idxDccOffer         ## A DCC SEND offer was received for a book
    idxDownloadStarted  ## A download has started
    idxDownloadProgress ## Download progress update
    idxDownloadComplete ## A download finished successfully
    idxDownloadFailed   ## A download failed
    idxConnected        ## Connected to IRC
    idxDisconnected     ## Disconnected from IRC
    idxError            ## Error occurred
    idxBookListReceived ## A book list was downloaded and parsed

  IndexerEvent* = object
    case kind*: IndexerEventKind
    of idxSearchResult:
      searchResult*: SearchResult
    of idxDccOffer:
      offerBook*: BookEntry
      offerTransfer*: DccTransfer
    of idxDownloadStarted, idxDownloadComplete:
      dlBook*: BookEntry
      dlPath*: string
    of idxDownloadProgress:
      dpBook*: BookEntry
      dpBytesReceived*: int64
      dpTotalBytes*: int64
    of idxDownloadFailed:
      dfBook*: BookEntry
      dfError*: string
    of idxConnected:
      discard
    of idxDisconnected:
      idxReason*: string
    of idxError:
      idxErrMsg*: string
    of idxBookListReceived:
      listBotNick*: string
      listBooksAdded*: int
      listTotalBooks*: int

  SearchBotConfig* = object
    ## Configuration for interacting with a search bot.
    botNick*: string          ## Bot's nickname
    searchPrefix*: string     ## Prefix for search commands (e.g., "@search", "!search")
    triggerPrefix*: string    ## Prefix for download triggers (e.g., "!botname")
    listCommand*: string      ## Command to request the full book list (e.g., "@botname")
    channel*: string          ## Channel to send commands in

  EbookIndexer* = ref object
    ## Ebook indexer that monitors IRC channels for book listings.
    ircClient*: IrcClient
    dccManager*: DccManager
    events*: AsyncChannel[IndexerEvent]
    index*: Table[string, BookEntry]  ## Indexed books by filename
    bots*: seq[SearchBotConfig]
    autoDownload*: bool       ## Auto-download DCC offers
    autoDownloadLists*: bool  ## Auto-download book list catalogs from bots
    downloadFilter*: proc(book: BookEntry): bool  ## Filter for auto-download
    pendingListRequests: seq[string]  ## Bot nicks we're waiting for a list from

# ============================================================
# Indexer creation
# ============================================================

proc newEbookIndexer*(ircConfig: IrcClientConfig,
                      downloadDir: string = "downloads",
                      eventBufferSize: int = 256): EbookIndexer =
  EbookIndexer(
    ircClient: newIrcClient(ircConfig),
    dccManager: newDccManager(downloadDir),
    events: newAsyncChannel[IndexerEvent](eventBufferSize),
    index: initTable[string, BookEntry](),
    autoDownloadLists: true,
  )

proc addBot*(indexer: EbookIndexer, botNick, searchPrefix: string,
             channel: string, triggerPrefix: string = "",
             listCommand: string = "") =
  ## Register a search bot configuration.
  ## listCommand: command to request the full book list (e.g., "@botname").
  ##   If empty, defaults to "@<botNick>".
  let trigger = if triggerPrefix.len > 0: triggerPrefix else: "!" & botNick
  let listCmd = if listCommand.len > 0: listCommand else: "@" & botNick
  indexer.bots.add(SearchBotConfig(
    botNick: botNick,
    searchPrefix: searchPrefix,
    triggerPrefix: trigger,
    listCommand: listCmd,
    channel: channel,
  ))

# ============================================================
# Book parsing
# ============================================================

const bookExts* = ["epub", "pdf", "mobi", "azw", "azw3", "djvu", "fb2",
                   "cbr", "cbz", "lit", "doc", "docx", "rtf", "txt",
                   "mp3", "rar", "zip", "jpg", "opf"]

proc extractFormat(filename: string): string =
  ## Extract file format from filename.
  let dotIdx = filename.rfind('.')
  if dotIdx >= 0:
    result = filename[dotIdx + 1 .. ^1].toLowerAscii()
  else:
    result = "unknown"

proc isBookFilename*(filename: string): bool =
  ## Check if a filename has a known ebook extension.
  let ext = extractFormat(filename)
  ext in bookExts

proc parseSize(sizeStr: string): int64 =
  ## Parse file size from strings like "1.2MB", "500KB", "1234567".
  let s = sizeStr.strip().strip(chars = {'(', ')', ' '})
  if s.len == 0:
    return -1
  try:
    let lower = s.toLowerAscii()
    if lower.endsWith("gb"):
      return int64(parseFloat(s[0 ..< s.len - 2].strip()) * 1073741824.0)
    elif lower.endsWith("mb"):
      return int64(parseFloat(s[0 ..< s.len - 2].strip()) * 1048576.0)
    elif lower.endsWith("kb"):
      return int64(parseFloat(s[0 ..< s.len - 2].strip()) * 1024.0)
    elif lower.endsWith("bytes"):
      return parseBiggestInt(s[0 ..< s.len - 5].strip())
    else:
      return parseBiggestInt(s)
  except ValueError:
    return -1

proc parseBookLine*(line: string, botNick: string, channel: string): Option[BookEntry] =
  ## Parse a book entry from a search result or catalog line.
  ##
  ## Supported formats:
  ##   !botname hash | Author - Title.epub ::INFO:: 1.2MB  (SearchOok format)
  ##   !botname BookTitle.epub ::INFO:: 1.2MB              (simple format)
  ##   !botname "Book Title.pdf" - 5.4MB                   (quoted format)
  var entry: BookEntry
  entry.botNick = botNick
  entry.channel = channel
  entry.firstSeen = now()
  entry.lastSeen = now()
  entry.filesize = -1

  let stripped = line.strip()
  if stripped.len == 0:
    return none(BookEntry)

  # Must start with ! (trigger command prefix)
  if not stripped.startsWith("!"):
    return none(BookEntry)

  # Check for ::INFO:: separator — this is the standard SearchOok format
  let infoIdx = stripped.toLowerAscii().find("::info::")
  if infoIdx > 0:
    # Everything before ::INFO:: is the trigger + filename
    let beforeInfo = stripped[0 ..< infoIdx].strip()
    let afterInfo = stripped[infoIdx + 8 .. ^1].strip()

    # The full text before ::INFO:: is the trigger command to paste back
    entry.triggerCommand = beforeInfo

    # Check for " | " separator (SearchOok format: "!bot hash | filename")
    let pipeIdx = beforeInfo.find(" | ")
    if pipeIdx > 0:
      entry.filename = beforeInfo[pipeIdx + 3 .. ^1].strip()
    else:
      # Simple format: "!botname filename"
      let spaceIdx = beforeInfo.find(' ')
      if spaceIdx > 0:
        entry.filename = beforeInfo[spaceIdx + 1 .. ^1].strip()
      else:
        return none(BookEntry)

    entry.filesize = parseSize(afterInfo)
  else:
    # No ::INFO:: — try simpler formats
    var remaining = stripped

    # Extract trigger prefix (first word starting with !)
    let spaceIdx = remaining.find(' ')
    if spaceIdx <= 0:
      return none(BookEntry)
    entry.triggerCommand = remaining[0 ..< spaceIdx]
    remaining = remaining[spaceIdx + 1 .. ^1].strip()

    # Check for pipe separator
    let pipeIdx = remaining.find(" | ")
    if pipeIdx > 0:
      entry.filename = remaining[pipeIdx + 3 .. ^1].strip()
      entry.triggerCommand = stripped[0 .. stripped.find(" | ") + 2 + entry.filename.len]
    elif remaining.len > 0 and remaining[0] == '"':
      # Quoted filename
      let closeQuote = remaining.find('"', 1)
      if closeQuote > 0:
        entry.filename = remaining[1 ..< closeQuote]
      else:
        return none(BookEntry)
    else:
      entry.filename = remaining

  if entry.filename.len == 0:
    return none(BookEntry)

  entry.format = extractFormat(entry.filename)
  entry.title = entry.filename
  # Strip extension for title
  let dotIdx = entry.title.rfind('.')
  if dotIdx > 0:
    entry.title = entry.title[0 ..< dotIdx]
  # Replace underscores with spaces for readability
  entry.title = entry.title.replace('_', ' ').strip()

  result = some(entry)

# ============================================================
# Book list catalog parsing
# ============================================================

proc parseCatalogFile*(path: string, botNick: string,
                       channel: string, triggerPrefix: string): seq[BookEntry] =
  ## Parse a downloaded bot catalog file (plain text, one book per line).
  ## Returns all parsed book entries.
  ##
  ## Catalog formats vary by bot, but common patterns:
  ## - One filename per line: "Book Title.epub"
  ## - With size info: "Book Title.epub 1.2MB"
  ## - With trigger: "!botname Book Title.epub ::INFO:: 1.2MB"
  ## - Tab-separated: "Book Title.epub\t1234567"
  if not fileExists(path):
    return @[]

  let content = readFile(path)
  let lines = content.splitLines()

  for line in lines:
    let stripped = line.strip()
    if stripped.len == 0:
      continue
    # Skip common header/footer lines
    if stripped.startsWith("#") or stripped.startsWith("//") or
       stripped.startsWith("---") or stripped.startsWith("==="):
      continue

    let bookOpt = parseBookLine(stripped, botNick, channel)
    if bookOpt.isSome:
      var book = bookOpt.get()
      # Ensure trigger command is set
      if book.triggerCommand.len == 0:
        book.triggerCommand = triggerPrefix
      result.add(book)

proc isCatalogFile*(filename: string): bool =
  ## Check if a DCC filename looks like a catalog/list file (not an ebook).
  let lower = filename.toLowerAscii()
  # List files are typically .txt or .zip containing the bot's catalog
  lower.endsWith(".txt") or lower.endsWith(".zip") or
    lower.endsWith(".lst") or lower.endsWith(".list") or
    lower.contains("list") or lower.contains("catalog") or
    lower.contains("booklist")

# ============================================================
# Search
# ============================================================

proc search*(indexer: EbookIndexer, query: string,
             botIdx: int = 0): CpsVoidFuture {.cps.} =
  ## Send a search query to a configured bot.
  if botIdx < 0 or botIdx >= indexer.bots.len:
    raise newException(ValueError, "Invalid bot index: " & $botIdx)
  let bot = indexer.bots[botIdx]
  let msg = bot.searchPrefix & " " & query
  await indexer.ircClient.privMsg(bot.channel, msg)

proc searchAll*(indexer: EbookIndexer, query: string): CpsVoidFuture {.cps.} =
  ## Send a search query to all configured bots.
  for i in 0 ..< indexer.bots.len:
    await indexer.search(query, i)

# ============================================================
# Request book lists from bots
# ============================================================

proc requestBookList*(indexer: EbookIndexer, botIdx: int = 0): CpsVoidFuture {.cps.} =
  ## Request a full book list from a bot. The bot will typically respond
  ## with a DCC SEND of a catalog file containing all available books.
  ## The catalog is automatically downloaded and parsed when received.
  if botIdx < 0 or botIdx >= indexer.bots.len:
    raise newException(ValueError, "Invalid bot index: " & $botIdx)
  let bot = indexer.bots[botIdx]
  indexer.pendingListRequests.add(bot.botNick.toLowerAscii())
  await indexer.ircClient.privMsg(bot.channel, bot.listCommand)

proc requestAllBookLists*(indexer: EbookIndexer): CpsVoidFuture {.cps.} =
  ## Request book lists from all configured bots.
  for i in 0 ..< indexer.bots.len:
    await indexer.requestBookList(i)

# ============================================================
# Request a book for download
# ============================================================

proc requestBook*(indexer: EbookIndexer, book: BookEntry): CpsVoidFuture {.cps.} =
  ## Request a book for DCC download by sending its trigger command.
  if book.triggerCommand.len > 0 and book.channel.len > 0:
    await indexer.ircClient.privMsg(book.channel,
      book.triggerCommand & " " & book.filename)
  else:
    raise newException(ValueError, "Book has no trigger command or channel")

# ============================================================
# Index lookup
# ============================================================

proc findBooks*(indexer: EbookIndexer, query: string): seq[BookEntry] =
  ## Search the local index for books matching a query (case-insensitive).
  let lowerQuery = query.toLowerAscii()
  for _, book in indexer.index:
    if book.title.toLowerAscii().contains(lowerQuery) or
       book.filename.toLowerAscii().contains(lowerQuery):
      result.add(book)

proc indexBook(indexer: EbookIndexer, book: BookEntry) =
  ## Add or update a book in the index.
  let key = book.filename.toLowerAscii()
  if key in indexer.index:
    var existing = indexer.index[key]
    existing.lastSeen = now()
    if book.filesize > 0 and existing.filesize < 0:
      existing.filesize = book.filesize
    indexer.index[key] = existing
  else:
    indexer.index[key] = book

proc indexBooks(indexer: EbookIndexer, books: seq[BookEntry]): int =
  ## Index multiple books. Returns number of new books added.
  for book in books:
    let key = book.filename.toLowerAscii()
    if key notin indexer.index:
      inc result
    indexer.indexBook(book)

# ============================================================
# Internal: find bot config by nick
# ============================================================

proc findBotByNick(indexer: EbookIndexer, nick: string): int =
  ## Find a bot config index by nickname. Returns -1 if not found.
  let lowerNick = nick.toLowerAscii()
  for i in 0 ..< indexer.bots.len:
    if indexer.bots[i].botNick.toLowerAscii() == lowerNick:
      return i
  return -1

proc isPendingList(indexer: EbookIndexer, botNick: string): bool =
  ## Check if we're waiting for a book list from this bot.
  let lower = botNick.toLowerAscii()
  for pending in indexer.pendingListRequests:
    if pending == lower:
      return true
  return false

proc removePendingList(indexer: EbookIndexer, botNick: string) =
  let lower = botNick.toLowerAscii()
  var i = 0
  while i < indexer.pendingListRequests.len:
    if indexer.pendingListRequests[i] == lower:
      indexer.pendingListRequests.delete(i)
      return
    inc i

# ============================================================
# Internal: handle catalog DCC download
# ============================================================

proc handleCatalogDownload(indexer: EbookIndexer, transfer: DccTransfer,
                           botNick: string): CpsVoidFuture {.cps.} =
  ## Download a catalog file from a bot and parse it to index books.
  let botIdx = indexer.findBotByNick(botNick)
  var channel = ""
  var triggerPrefix = ""
  if botIdx >= 0:
    channel = indexer.bots[botIdx].channel
    triggerPrefix = indexer.bots[botIdx].triggerPrefix

  # Download the catalog
  await receiveDcc(transfer)

  if transfer.state == dtsCompleted:
    # Parse the downloaded catalog
    let books = parseCatalogFile(transfer.outputPath, botNick, channel, triggerPrefix)
    let newBooks = indexer.indexBooks(books)

    await indexer.events.send(IndexerEvent(
      kind: idxBookListReceived,
      listBotNick: botNick,
      listBooksAdded: newBooks,
      listTotalBooks: books.len,
    ))

    indexer.removePendingList(botNick)
  else:
    await indexer.events.send(IndexerEvent(
      kind: idxError,
      idxErrMsg: "Failed to download book list from " & botNick & ": " & transfer.error,
    ))
    indexer.removePendingList(botNick)

# ============================================================
# Event processing loop
# ============================================================

proc processIrcEvent(indexer: EbookIndexer, event: IrcEvent): CpsVoidFuture {.cps.} =
  ## Process an IRC event from the client and emit indexer events.
  case event.kind
  of iekConnected:
    await indexer.events.send(IndexerEvent(kind: idxConnected))

  of iekDisconnected:
    await indexer.events.send(IndexerEvent(kind: idxDisconnected, idxReason: event.reason))

  of iekPrivMsg, iekNotice:
    # Check if this is a response from a known bot
    let source = event.pmSource
    for bot in indexer.bots:
      if source.toLowerAscii() == bot.botNick.toLowerAscii():
        let bookOpt = parseBookLine(event.pmText, bot.botNick, bot.channel)
        if bookOpt.isSome:
          let book = bookOpt.get()
          indexer.indexBook(book)
          var searchRes = SearchResult(raw: event.pmText)
          searchRes.books.add(book)
          await indexer.events.send(IndexerEvent(kind: idxSearchResult, searchResult: searchRes))
        break

  of iekDccSend:
    let transfer = indexer.dccManager.addOffer(event.dccSource, event.dccInfo)
    let filename = event.dccInfo.filename

    # Check if this is a catalog/list file from a bot we requested
    let isList = isCatalogFile(filename) and
                 (indexer.isPendingList(event.dccSource) or
                  indexer.autoDownloadLists)

    if isList:
      # This is a book list — download and parse it
      await indexer.handleCatalogDownload(transfer, event.dccSource)
    else:
      # This is a regular book — emit as DCC offer
      let key = event.dccInfo.filename.toLowerAscii()
      var book: BookEntry
      if key in indexer.index:
        book = indexer.index[key]
      else:
        book = BookEntry(
          title: event.dccInfo.filename,
          filename: event.dccInfo.filename,
          filesize: event.dccInfo.filesize,
          format: extractFormat(event.dccInfo.filename),
          botNick: event.dccSource,
          firstSeen: now(),
          lastSeen: now(),
        )
        indexer.indexBook(book)

      await indexer.events.send(IndexerEvent(kind: idxDccOffer,
                                              offerBook: book,
                                              offerTransfer: transfer))

      # Auto-download if enabled
      if indexer.autoDownload:
        let shouldDownload = if indexer.downloadFilter != nil:
                               indexer.downloadFilter(book)
                             else:
                               true
        if shouldDownload:
          await indexer.events.send(IndexerEvent(kind: idxDownloadStarted,
                                                  dlBook: book,
                                                  dlPath: transfer.outputPath))
          try:
            await indexer.dccManager.acceptOffer(transfer)
            if transfer.state == dtsCompleted:
              await indexer.events.send(IndexerEvent(kind: idxDownloadComplete,
                                                      dlBook: book,
                                                      dlPath: transfer.outputPath))
            else:
              await indexer.events.send(IndexerEvent(kind: idxDownloadFailed,
                                                      dfBook: book,
                                                      dfError: transfer.error))
          except CatchableError as e:
            await indexer.events.send(IndexerEvent(kind: idxDownloadFailed,
                                                    dfBook: book,
                                                    dfError: e.msg))

  of iekError:
    await indexer.events.send(IndexerEvent(kind: idxError, idxErrMsg: event.errMsg))

  else:
    discard

# ============================================================
# Main run loop
# ============================================================

proc run*(indexer: EbookIndexer): CpsVoidFuture {.cps.} =
  ## Start the ebook indexer. Connects to IRC and processes events.
  ## Read indexer.events for high-level indexer events.
  ## The IRC client runs concurrently in the background.

  # Start the IRC client (this will begin emitting events)
  let clientFut = indexer.ircClient.run()

  # Process IRC events
  while true:
    let ircEvent: IrcEvent = await indexer.ircClient.events.recv()
    await indexer.processIrcEvent(ircEvent)

proc stop*(indexer: EbookIndexer): CpsVoidFuture {.cps.} =
  ## Stop the indexer and disconnect from IRC.
  await indexer.ircClient.disconnect()
  indexer.events.close()

# ============================================================
# Statistics
# ============================================================

proc stats*(indexer: EbookIndexer): string =
  ## Get a summary of the indexer state.
  var lines: seq[string]
  lines.add("Ebook Indexer Stats:")
  lines.add("  Books indexed: " & $indexer.index.len)
  lines.add("  Pending DCC offers: " & $indexer.dccManager.pendingOffers.len)
  lines.add("  Active transfers: " & $indexer.dccManager.activeTransfers.len)
  lines.add("  Completed transfers: " & $indexer.dccManager.completedTransfers.len)
  lines.add("  Configured bots: " & $indexer.bots.len)
  lines.add("  Pending list requests: " & $indexer.pendingListRequests.len)
  lines.add("  IRC state: " & $indexer.ircClient.state)
  result = lines.join("\n")

# ============================================================
# Export index
# ============================================================

proc exportIndex*(indexer: EbookIndexer, path: string) =
  ## Export the current book index to a file (tab-separated).
  ## Format: filename<TAB>title<TAB>format<TAB>filesize<TAB>bot<TAB>channel<TAB>trigger
  var f: File
  if not open(f, path, fmWrite):
    raise newException(IOError, "Failed to open export file: " & path)
  f.writeLine("# Ebook Index - Exported " & $now())
  f.writeLine("# filename\ttitle\tformat\tfilesize\tbot\tchannel\ttrigger")
  for _, book in indexer.index:
    f.writeLine(book.filename & "\t" & book.title & "\t" & book.format & "\t" &
                $book.filesize & "\t" & book.botNick & "\t" & book.channel & "\t" &
                book.triggerCommand)
  f.close()

proc importIndex*(indexer: EbookIndexer, path: string): int =
  ## Import a previously exported index file. Returns number of books imported.
  if not fileExists(path):
    return 0
  let content = readFile(path)
  for line in content.splitLines():
    if line.startsWith("#") or line.strip().len == 0:
      continue
    let parts = line.split('\t')
    if parts.len >= 5:
      let book = BookEntry(
        filename: parts[0],
        title: if parts.len > 1: parts[1] else: parts[0],
        format: if parts.len > 2: parts[2] else: extractFormat(parts[0]),
        filesize: (try: parseBiggestInt(parts[3]) except ValueError: -1'i64),
        botNick: parts[4],
        channel: if parts.len > 5: parts[5] else: "",
        triggerCommand: if parts.len > 6: parts[6] else: "",
        firstSeen: now(),
        lastSeen: now(),
      )
      indexer.indexBook(book)
      inc result
