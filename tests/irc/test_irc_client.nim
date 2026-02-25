## Tests for CPS IRC Client
##
## Uses a mock IRC server to test client behavior including:
## - Connection and registration
## - PING/PONG handling
## - Message sending/receiving
## - Channel operations
## - CTCP handling
## - DCC SEND event classification
## - Event-driven consumption

import cps/runtime
import cps/transform
import cps/eventloop
import cps/io/streams
import cps/io/tcp
import cps/io/buffered
import cps/concurrency/channels
import cps/irc/protocol
import cps/irc/client
import cps/irc/dcc
import cps/irc/ebook_indexer
import std/[nativesockets, strutils, options, os, tables]
from std/posix import Sockaddr_in, getsockname, SockLen

# Helper: get OS-assigned port from a listener
proc getListenerPort(listener: TcpListener): int =
  var localAddr: Sockaddr_in
  var addrLen: SockLen = sizeof(localAddr).SockLen
  discard getsockname(listener.fd, cast[ptr SockAddr](addr localAddr), addr addrLen)
  result = ntohs(localAddr.sin_port).int

# Helper: run event loop until a future finishes or timeout
proc runUntil(fut: CpsVoidFuture, timeoutMs: int = 5000) =
  let loop = getEventLoop()
  var elapsed = 0
  while not fut.finished and elapsed < timeoutMs:
    loop.tick()
    elapsed += 10
    if not loop.hasWork:
      break

proc runUntil[T](fut: CpsFuture[T], timeoutMs: int = 5000) =
  let loop = getEventLoop()
  var elapsed = 0
  while not fut.finished and elapsed < timeoutMs:
    loop.tick()
    elapsed += 10
    if not loop.hasWork:
      break

# ============================================================
# Test 1: IRC registration and basic message exchange
# ============================================================

block testIrcRegistration:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  # Mock IRC server that sends welcome, PING, and messages
  proc mockServer(l: TcpListener): CpsFuture[seq[string]] {.cps.} =
    var receivedLines: seq[string]
    let clientConn = await l.accept()
    let stream = clientConn.AsyncStream
    let reader = newBufferedReader(stream)

    # Read NICK and USER from client
    let nickLine = await reader.readLine("\r\n")
    receivedLines.add(nickLine)
    let userLine = await reader.readLine("\r\n")
    receivedLines.add(userLine)

    # Send RPL_WELCOME
    await stream.write(":testserver 001 testbot :Welcome to the test IRC network\r\n")

    # Send a PING and wait for PONG
    await stream.write("PING :testtoken123\r\n")
    let pongLine = await reader.readLine("\r\n")
    receivedLines.add(pongLine)

    # Send a PRIVMSG
    await stream.write(":sender!user@host PRIVMSG testbot :Hello from sender\r\n")

    # Send a NOTICE
    await stream.write(":bot!user@host NOTICE testbot :Notice message\r\n")

    # Send a DCC SEND offer (no CTCP VERSION to avoid blocking on reply read)
    await stream.write(":bookbot!bot@host PRIVMSG testbot :\x01DCC SEND test.epub 2130706433 4567 12345\x01\r\n")

    # Give client time to process
    await cpsSleep(200)
    stream.close()
    return receivedLines

  # Create IRC client
  var config = newIrcClientConfig("127.0.0.1", port, "testbot")
  config.autoReconnect = false
  config.ctcpVersion = "Test Client 1.0"
  let ircClient = newIrcClient(config)

  # Collect events until DCC SEND
  proc collectEvents(cl: IrcClient): CpsFuture[seq[IrcEvent]] {.cps.} =
    var events: seq[IrcEvent]
    var done = false
    while not done:
      try:
        let evt: IrcEvent = await cl.events.recv()
        events.add(evt)
        if evt.kind == iekDccSend:
          done = true
      except CatchableError:
        done = true
    return events

  let serverFut = mockServer(listener)
  let clientFut = ircClient.run()
  let eventsFut = collectEvents(ircClient)

  runUntil(eventsFut)

  # Check collected events
  assert eventsFut.finished, "Event collector should have finished"
  let events = eventsFut.read()
  assert events.len > 0, "Should have collected events"

  var foundConnected = false
  var foundPrivMsg = false
  var foundNotice = false
  var foundDccSend = false
  var foundPing = false

  for evt in events:
    case evt.kind
    of iekConnected:
      foundConnected = true
    of iekPrivMsg:
      foundPrivMsg = true
      assert evt.pmSource == "sender", "PRIVMSG source should be sender, got: " & evt.pmSource
      assert evt.pmText == "Hello from sender", "PRIVMSG text mismatch"
    of iekNotice:
      foundNotice = true
      assert evt.pmSource == "bot"
      assert evt.pmText == "Notice message"
    of iekDccSend:
      foundDccSend = true
      assert evt.dccSource == "bookbot"
      assert evt.dccInfo.filename == "test.epub"
      assert evt.dccInfo.port == 4567
      assert evt.dccInfo.filesize == 12345
    of iekPing:
      foundPing = true
    else:
      discard

  assert foundConnected, "Should have received Connected event"
  assert foundPrivMsg, "Should have received PRIVMSG event"
  assert foundNotice, "Should have received NOTICE event"
  assert foundDccSend, "Should have received DCC SEND event"
  assert foundPing, "Should have received PING event"

  # Check server received correct data
  if serverFut.finished:
    let serverLines = serverFut.read()
    assert serverLines[0].contains("testbot"), "NICK should contain testbot"
    assert serverLines[1].startsWith("USER"), "Second line should be USER"
    assert serverLines[2].contains("testtoken123"), "PONG should contain the token"

  listener.close()
  echo "PASS: IRC registration and message exchange"

# ============================================================
# Test 2: Nick collision handling
# ============================================================

block testNickCollision:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc mockServer(l: TcpListener): CpsFuture[seq[string]] {.cps.} =
    var lines: seq[string]
    let clientConn = await l.accept()
    let stream = clientConn.AsyncStream
    let reader = newBufferedReader(stream)

    # Read initial NICK and USER
    let nick1 = await reader.readLine("\r\n")
    lines.add(nick1)
    let user = await reader.readLine("\r\n")
    lines.add(user)

    # Reply with ERR_NICKNAMEINUSE (433)
    await stream.write(":server 433 * testbot :Nickname is already in use\r\n")

    # Client should send alternative nick
    let nick2 = await reader.readLine("\r\n")
    lines.add(nick2)

    # Accept the alternative nick
    await stream.write(":server 001 testbot_ :Welcome\r\n")

    await cpsSleep(100)
    stream.close()
    return lines

  var config = newIrcClientConfig("127.0.0.1", port, "testbot")
  config.autoReconnect = false
  let ircClient = newIrcClient(config)

  proc waitForConnect(cl: IrcClient): CpsVoidFuture {.cps.} =
    var done = false
    while not done:
      try:
        let evt: IrcEvent = await cl.events.recv()
        if evt.kind == iekConnected:
          done = true
      except CatchableError:
        done = true

  let serverFut = mockServer(listener)
  let clientFut = ircClient.run()
  let waitFut = waitForConnect(ircClient)

  runUntil(waitFut)

  # Check that client tracked the nick change
  assert ircClient.currentNick == "testbot_", "Current nick should be testbot_, got: " & ircClient.currentNick

  # Check server data
  if serverFut.finished:
    let lines = serverFut.read()
    assert lines.len >= 3, "Expected at least 3 lines"
    assert lines[2].contains("testbot_"), "Alternative nick should be testbot_"

  listener.close()
  echo "PASS: Nick collision handling"

# ============================================================
# Test 3: Auto-join channels
# ============================================================

block testAutoJoin:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  proc mockServer(l: TcpListener): CpsFuture[seq[string]] {.cps.} =
    var lines: seq[string]
    let clientConn = await l.accept()
    let stream = clientConn.AsyncStream
    let reader = newBufferedReader(stream)

    # Read NICK, USER
    let nick = await reader.readLine("\r\n")
    lines.add(nick)
    let user = await reader.readLine("\r\n")
    lines.add(user)

    # Send welcome
    await stream.write(":server 001 testbot :Welcome\r\n")

    # Read JOIN commands
    let join1 = await reader.readLine("\r\n")
    lines.add(join1)
    let join2 = await reader.readLine("\r\n")
    lines.add(join2)

    await cpsSleep(50)
    stream.close()
    return lines

  var config = newIrcClientConfig("127.0.0.1", port, "testbot")
  config.autoReconnect = false
  config.autoJoinChannels = @["#books", "#ebooks"]
  let ircClient = newIrcClient(config)

  let serverFut = mockServer(listener)
  let clientFut = ircClient.run()

  runUntil(serverFut)

  assert serverFut.finished, "Server should have finished"
  let lines = serverFut.read()
  assert lines.len >= 4, "Expected at least 4 lines, got: " & $lines.len

  # Check JOIN commands
  assert lines[2].contains("JOIN") and lines[2].contains("#books"),
    "Expected JOIN #books, got: " & lines[2]
  assert lines[3].contains("JOIN") and lines[3].contains("#ebooks"),
    "Expected JOIN #ebooks, got: " & lines[3]

  listener.close()
  echo "PASS: Auto-join channels"

# ============================================================
# Test 4: DCC SEND event through DccManager
# ============================================================

block testDccManager:
  let dm = newDccManager("test_downloads")

  # Simulate a DCC SEND offer
  let info = DccInfo(
    kind: "SEND",
    filename: "tolkien.epub",
    ip: 2130706433'u32,  # 127.0.0.1
    port: 12345,
    filesize: 500000,
  )

  let transfer = dm.addOffer("BookBot", info)
  assert transfer.source == "BookBot"
  assert transfer.info.filename == "tolkien.epub"
  assert transfer.state == dtsIdle
  assert transfer.totalBytes == 500000
  assert transfer.outputPath.contains("tolkien.epub")
  assert dm.pendingOffers.len == 1

  echo "PASS: DCC manager offer tracking"

# ============================================================
# Test 5: Book line parsing
# ============================================================

block testBookParsing:
  # Standard format with ::INFO::
  let b1 = parseBookLine("!BookBot The_Lord_of_the_Rings.epub ::INFO:: 2.3MB", "BookBot", "#ebooks")
  assert b1.isSome, "Should parse book line"
  let book1 = b1.get()
  assert book1.filename == "The_Lord_of_the_Rings.epub", "Filename: " & book1.filename
  assert book1.format == "epub", "Format: " & book1.format
  assert book1.botNick == "BookBot"
  assert book1.channel == "#ebooks"
  assert book1.filesize > 0, "Should have parsed filesize"

  # SearchOok format with hash and pipe separator
  let b2 = parseBookLine("!artemis_serv dddb6db5e378 | Tolkien, JRR - History Of Middle-Earth.pdf ::INFO:: 1.20MB", "artemis_serv", "#ebooks")
  assert b2.isSome, "Should parse SearchOok format"
  let book2 = b2.get()
  assert book2.format == "pdf", "Format: " & book2.format
  assert book2.filename == "Tolkien, JRR - History Of Middle-Earth.pdf", "Filename: " & book2.filename
  assert book2.triggerCommand == "!artemis_serv dddb6db5e378 | Tolkien, JRR - History Of Middle-Earth.pdf", "Trigger: " & book2.triggerCommand
  assert book2.filesize > 0, "Should have parsed filesize"

  # Simple format without ::INFO::
  let b3 = parseBookLine("!SomeBot some_random_ebook.mobi", "SomeBot", "#books")
  assert b3.isSome, "Should parse simple !botname filename"
  let book3 = b3.get()
  assert book3.format == "mobi"

  # Non-book line (no ! prefix)
  let b4 = parseBookLine("Just a regular chat message", "Bot", "#chat")
  assert b4.isNone, "Regular messages should not parse as books"

  echo "PASS: Book line parsing"

# ============================================================
# Test 6: DCC file receive via loopback
# ============================================================

block testDccReceive:
  let listener = tcpListen("127.0.0.1", 0)
  let port = getListenerPort(listener)

  let testData = "This is test ebook content for DCC transfer testing. " &
                 "Lorem ipsum dolor sit amet, consectetur adipiscing elit."

  # Mock DCC sender: accepts connection, sends file data
  proc dccSender(l: TcpListener, data: string): CpsVoidFuture {.cps.} =
    let clientConn = await l.accept()
    let stream = clientConn.AsyncStream
    await stream.write(data)
    # Read ACK (4 bytes)
    let ack = await stream.read(4)
    # Give receiver time to process
    await cpsSleep(50)
    stream.close()

  # Create a DCC transfer
  let transfer = DccTransfer(
    info: DccInfo(
      kind: "SEND",
      filename: "test_dcc_book.txt",
      ip: stringToLongIp("127.0.0.1"),
      port: port,
      filesize: testData.len,
    ),
    source: "TestBot",
    state: dtsIdle,
    outputPath: "/tmp/test_dcc_download.txt",
    totalBytes: testData.len,
  )

  var progressCalled = false
  transfer.setProgressCallback(proc(received: int64, total: int64) =
    progressCalled = true
  )

  let senderFut = dccSender(listener, testData)
  let receiveFut = receiveDcc(transfer)

  runUntil(receiveFut, 10000)

  assert transfer.state == dtsCompleted, "Transfer should be completed, got: " & $transfer.state & " error: " & transfer.error
  assert transfer.bytesReceived == testData.len, "Should have received all bytes"
  assert progressCalled, "Progress callback should have been called"

  # Verify file content
  let content = readFile("/tmp/test_dcc_download.txt")
  assert content == testData, "File content should match"

  # Cleanup
  removeFile("/tmp/test_dcc_download.txt")
  listener.close()
  echo "PASS: DCC file receive"

# ============================================================
# Test 7: Catalog file parsing
# ============================================================

block testCatalogParsing:
  # Create a temporary catalog file in SearchOok format
  let catalogPath = "/tmp/test_booklist.txt"
  let catalogContent = """# Book List for TestBot
# Generated 2024-01-01
!TestBot abc123 | The_Hobbit.epub ::INFO:: 1.2MB
!TestBot def456 | Dune.pdf ::INFO:: 3.5MB
!TestBot ghi789 | Foundation.mobi ::INFO:: 500KB
Some random chat line that's not a book
!TestBot jkl012 | Neuromancer.epub ::INFO:: 800KB
# End of list
"""
  writeFile(catalogPath, catalogContent)

  let books = parseCatalogFile(catalogPath, "TestBot", "#ebooks", "!TestBot")
  assert books.len == 4, "Should parse 4 books from catalog, got: " & $books.len

  assert books[0].filename == "The_Hobbit.epub", "Filename: " & books[0].filename
  assert books[0].format == "epub"
  assert books[0].botNick == "TestBot"
  assert books[0].channel == "#ebooks"
  assert books[0].triggerCommand == "!TestBot abc123 | The_Hobbit.epub"

  assert books[1].filename == "Dune.pdf"
  assert books[1].format == "pdf"

  assert books[2].filename == "Foundation.mobi"
  assert books[2].format == "mobi"

  assert books[3].filename == "Neuromancer.epub"

  removeFile(catalogPath)
  echo "PASS: Catalog file parsing"

# ============================================================
# Test 8: Index export and import
# ============================================================

block testIndexExportImport:
  var config = newIrcClientConfig("127.0.0.1", 6667, "testbot")
  config.autoReconnect = false
  let indexer = newEbookIndexer(config, "/tmp/test_downloads")

  # Add some books to the index
  indexer.addBot("TestBot", "@search", "#ebooks")

  let book1Opt = parseBookLine("!TestBot Great_Book.epub ::INFO:: 2MB", "TestBot", "#ebooks")
  assert book1Opt.isSome
  indexer.index[book1Opt.get().filename.toLowerAscii()] = book1Opt.get()

  let book2Opt = parseBookLine("!TestBot Another_Book.pdf - 1.5MB", "TestBot", "#ebooks")
  assert book2Opt.isSome
  indexer.index[book2Opt.get().filename.toLowerAscii()] = book2Opt.get()

  # Export
  let exportPath = "/tmp/test_index_export.tsv"
  indexer.exportIndex(exportPath)

  # Create a new indexer and import
  let indexer2 = newEbookIndexer(config, "/tmp/test_downloads")
  let imported = indexer2.importIndex(exportPath)
  assert imported == 2, "Should import 2 books, got: " & $imported
  assert indexer2.index.len == 2

  let found = indexer2.findBooks("Great")
  assert found.len == 1, "Should find 1 book matching 'Great'"
  assert found[0].filename == "Great_Book.epub"

  removeFile(exportPath)
  echo "PASS: Index export/import"

# ============================================================
# Test 9: Book list file detection
# ============================================================

block testCatalogDetection:
  assert isCatalogFile("SearchBot_booklist.txt")
  assert isCatalogFile("catalog.zip")
  assert isCatalogFile("MyBot_list.lst")
  assert not isCatalogFile("The_Hobbit.epub")
  assert not isCatalogFile("Dune.pdf")
  assert not isCatalogFile("random.mobi")

  echo "PASS: Catalog file detection"

echo "All IRC client tests passed!"
