## Tests for XDCC protocol support

import cps/irc/protocol
import cps/irc/client
import cps/irc/xdcc
import std/[options, strutils, tables]

# ============================================================
# Test 1: XDCC command formatting
# ============================================================

block testXdccCommandFormatting:
  assert formatXdccSend(5) == "XDCC SEND #5"
  assert formatXdccSend(100) == "XDCC SEND #100"
  assert formatXdccSend(-1) == "XDCC SEND -1"
  assert formatXdccGet(3) == "XDCC GET #3"
  assert formatXdccBatchRange(1, 10) == "XDCC BATCH 1-10"
  assert formatXdccBatchList([1, 5, 10]) == "XDCC BATCH 1,5,10"
  assert formatXdccList() == "XDCC LIST"
  assert formatXdccSearch("ubuntu iso") == "XDCC SEARCH ubuntu iso"
  assert formatXdccInfo(42) == "XDCC INFO #42"
  assert formatXdccQueue() == "XDCC QUEUE"
  assert formatXdccCancel() == "XDCC CANCEL"
  assert formatXdccRemoveAll() == "XDCC REMOVE"
  assert formatXdccRemove(7) == "XDCC REMOVE #7"
  assert formatXdccHelp() == "XDCC HELP"

  echo "PASS: XDCC command formatting"

# ============================================================
# Test 2: Pack line parsing
# ============================================================

block testPackLineParsing:
  # Standard format: #N Nx [size] filename
  let p1 = parsePackLine("#1  3x [1.2G] Ubuntu-24.04.iso")
  assert p1.isSome, "Should parse standard pack line"
  let pack1 = p1.get()
  assert pack1.number == 1
  assert pack1.downloads == 3
  assert pack1.filesize == "1.2G"
  assert pack1.filesizeBytes > 1_000_000_000'i64, "1.2G should be > 1 billion bytes"
  assert pack1.filename == "Ubuntu-24.04.iso"

  # Without download count
  let p2 = parsePackLine("#15 [700M] Fedora-40.iso")
  assert p2.isSome
  let pack2 = p2.get()
  assert pack2.number == 15
  assert pack2.downloads == -1, "No download count"
  assert pack2.filesize == "700M"
  assert pack2.filename == "Fedora-40.iso"

  # Large pack number
  let p3 = parsePackLine("#1234  99x [350K] small_file.txt")
  assert p3.isSome
  let pack3 = p3.get()
  assert pack3.number == 1234
  assert pack3.downloads == 99
  assert pack3.filesize == "350K"

  # Not a pack line
  let p4 = parsePackLine("** 5 packs ** 3 of 5 slots open")
  assert p4.isNone, "Not a pack line"

  let p5 = parsePackLine("Just a regular message")
  assert p5.isNone

  let p6 = parsePackLine("")
  assert p6.isNone

  echo "PASS: Pack line parsing"

# ============================================================
# Test 3: Bot response parsing
# ============================================================

block testBotResponseParsing:
  # Transfer starting
  let e1 = parseXdccNotice("FileBot", "** Sending you pack #5 \"Ubuntu-24.04.iso\"")
  assert e1.isSome
  let ev1 = e1.get()
  assert ev1.kind == xekTransferStarting
  assert ev1.tsBotNick == "FileBot"
  assert ev1.tsPackNumber == 5
  assert ev1.tsFilename == "Ubuntu-24.04.iso"

  # Queued
  let e2 = parseXdccNotice("FileBot",
    "All slots full. Added to queue position 3. Estimated wait: 12 minutes.")
  assert e2.isSome
  let ev2 = e2.get()
  assert ev2.kind == xekQueued
  assert ev2.qPosition == 3

  # No such pack
  let e3 = parseXdccNotice("FileBot", "Invalid pack number #999")
  assert e3.isSome
  let ev3 = e3.get()
  assert ev3.kind == xekNoSuchPack
  assert ev3.nspPackNumber == 999

  # Denied
  let e4 = parseXdccNotice("FileBot", "You are being ignored because of flooding")
  assert e4.isSome
  assert e4.get().kind == xekDenied

  # Transfer complete
  let e5 = parseXdccNotice("FileBot", "Transfer complete! 1.4GB in 5m23s (4.5MB/s)")
  assert e5.isSome
  assert e5.get().kind == xekTransferComplete

  # Pack list line
  let e6 = parseXdccNotice("FileBot", "#1  3x [1.2G] Ubuntu-24.04.iso")
  assert e6.isSome
  assert e6.get().kind == xekPackList
  assert e6.get().plPacks.len == 1
  assert e6.get().plPacks[0].number == 1

  echo "PASS: Bot response parsing"

# ============================================================
# Test 4: Channel announcement parsing
# ============================================================

block testAnnouncementParsing:
  # Standard XDCC announcement
  let a1 = parseXdccAnnouncement("BigBot",
    "** 150 packs ** 3 of 5 slots open, Record: 45.2KB/s")
  assert a1.isSome
  let info1 = a1.get()
  assert info1.nick == "BigBot"
  assert info1.totalPacks == 150
  assert info1.slotsOpen == 3
  assert info1.slotsTotal == 5
  assert info1.record == "45.2KB/s"

  # FWServer advertisement (plain text, no color codes)
  let a2 = parseXdccAnnouncement("Bsk",
    "Type: @Bsk For My List Of: 1,384,329 Files  Slots: 15/15  Queued: 0  Speed: 0cps  Next: NOW  Served: 2,668,153")
  assert a2.isSome, "Should parse FWServer advertisement"
  let info2 = a2.get()
  assert info2.nick == "Bsk"
  assert info2.totalPacks == 1384329, "Packs: " & $info2.totalPacks
  assert info2.slotsOpen == 15, "Slots open: " & $info2.slotsOpen
  assert info2.slotsTotal == 15, "Slots total: " & $info2.slotsTotal
  assert info2.queueSize == 0, "Queue: " & $info2.queueSize

  # FWServer with IRC color codes (as seen in live IRC)
  # \x03 = color code, followed by fg[,bg] digits
  let a3 = parseXdccAnnouncement("peapod",
    "\x0304,00\x0314,00 \x0312,00Type:\x0304,00 @peapod \x0312,00For My List Of:\x0304,00 757,202 \x0312,00Files \x0314,00 \x0312,00Slots:\x0304,00 20/20 \x0314,00 \x0312,00Queued:\x0304,00 0")
  assert a3.isSome, "Should parse FWServer ad with IRC color codes"
  let info3 = a3.get()
  assert info3.nick == "peapod"
  assert info3.totalPacks == 757202, "Packs: " & $info3.totalPacks
  assert info3.slotsOpen == 20, "Slots open: " & $info3.slotsOpen
  assert info3.slotsTotal == 20, "Slots total: " & $info3.slotsTotal
  assert info3.queueSize == 0, "Queue: " & $info3.queueSize

  # Not an announcement
  let a4 = parseXdccAnnouncement("user", "Hello everyone!")
  assert a4.isNone

  echo "PASS: Channel announcement parsing"

# ============================================================
# Test 4b: IRC formatting stripping
# ============================================================

block testIrcFormatStripping:
  # Bold
  assert stripIrcFormatting("\x02bold text\x02") == "bold text"

  # Color codes
  assert stripIrcFormatting("\x034red text") == "red text"
  assert stripIrcFormatting("\x0304,01red on black") == "red on black"
  assert stripIrcFormatting("\x03text after bare color reset") == "text after bare color reset"

  # Mixed formatting
  let messy = "\x0304,00\x0314,00 \x0312,00Type:\x0304,00 @Bsk"
  let clean = stripIrcFormatting(messy)
  assert clean.contains("Type:"), "Stripped: " & clean
  assert clean.contains("@Bsk"), "Stripped: " & clean
  assert not clean.contains("\x03"), "Should not contain color codes"

  # Reset
  assert stripIrcFormatting("hello\x0Fworld") == "helloworld"

  # Underline, italic
  assert stripIrcFormatting("\x1Funderlined\x1F") == "underlined"
  assert stripIrcFormatting("\x1Ditalic\x1D") == "italic"

  # No formatting
  assert stripIrcFormatting("plain text") == "plain text"
  assert stripIrcFormatting("") == ""

  echo "PASS: IRC formatting stripping"

# ============================================================
# Test 5: XdccClient creation and bot tracking
# ============================================================

block testXdccClientCreation:
  var config = newIrcClientConfig("127.0.0.1", 6667, "testxdcc")
  config.autoReconnect = false
  let ircClient = newIrcClient(config)
  let xdcc = newXdccClient(ircClient, "/tmp/xdcc_test")

  assert xdcc.autoAccept == true
  assert xdcc.bots.len == 0

  xdcc.trackBot("BigBot")
  assert xdcc.isTracked("BigBot")
  assert xdcc.isTracked("bigbot")  # case insensitive

  xdcc.trackBot("BigBot")  # duplicate should not add twice
  assert xdcc.isTracked("BigBot")

  xdcc.trackBot("SmallBot")
  assert xdcc.isTracked("SmallBot")
  assert xdcc.isTracked("BigBot")

  xdcc.untrackBot("BigBot")
  assert not xdcc.isTracked("BigBot")
  assert xdcc.isTracked("SmallBot")

  echo "PASS: XdccClient creation and bot tracking"

# ============================================================
# Test 6: Size parsing
# ============================================================

block testSizeParsing:
  # Test via pack line parsing
  let p1 = parsePackLine("#1 [1G] file1.txt")
  assert p1.isSome
  assert p1.get().filesizeBytes == 1073741824'i64

  let p2 = parsePackLine("#2 [500M] file2.txt")
  assert p2.isSome
  assert p2.get().filesizeBytes == 524288000'i64

  let p3 = parsePackLine("#3 [1.5G] file3.txt")
  assert p3.isSome
  assert p3.get().filesizeBytes > 1_500_000_000'i64

  let p4 = parsePackLine("#4 [256K] file4.txt")
  assert p4.isSome
  assert p4.get().filesizeBytes == 262144'i64

  echo "PASS: Size parsing"

# ============================================================
# Test 7: XDCC commands are plain PRIVMSG (not CTCP)
# ============================================================

block testXdccUsesPrivmsg:
  # XDCC commands should be plain text, not CTCP-wrapped
  let cmd = formatXdccSend(5)
  assert not cmd.startsWith("\x01"), "XDCC commands should NOT be CTCP"
  assert not cmd.contains("\x01"), "No CTCP delimiters"
  assert cmd == "XDCC SEND #5"

  # The actual IRC message wrapping happens at the client level via privMsg
  let ircMsg = formatPrivMsg("BotName", cmd)
  assert ircMsg == "PRIVMSG BotName :XDCC SEND #5\r\n"

  echo "PASS: XDCC commands are plain PRIVMSG"

# ============================================================
# Test 8: Multiple pack formats
# ============================================================

block testMultiplePackFormats:
  # Format with tabs
  let p1 = parsePackLine("#1\t3x\t[1.2G]\tUbuntu-24.04.iso")
  assert p1.isSome, "Should handle tabs"
  assert p1.get().number == 1

  # Pack with spaces in filename
  let p2 = parsePackLine("#7  1x [2.3G] Some File With Spaces.mkv")
  assert p2.isSome
  assert p2.get().filename == "Some File With Spaces.mkv"

  # Single digit download count without padding
  let p3 = parsePackLine("#99 1x [100M] file.zip")
  assert p3.isSome
  assert p3.get().number == 99
  assert p3.get().downloads == 1

  echo "PASS: Multiple pack formats"

# ============================================================
# Test 9: Queue event parsing edge cases
# ============================================================

block testQueueEdgeCases:
  # Simple queue message
  let e1 = parseXdccNotice("Bot", "You have been queued for pack #7, position 5")
  assert e1.isSome
  assert e1.get().kind == xekQueued
  assert e1.get().qPackNumber == 7
  assert e1.get().qPosition == 5

  # "Sending you pack" with different wording
  let e2 = parseXdccNotice("Bot", "Sending pack #3 to you now")
  assert e2.isSome
  assert e2.get().kind == xekTransferStarting
  assert e2.get().tsPackNumber == 3

  # "All slots full" without queue info
  let e3 = parseXdccNotice("Bot", "All slots full, please try again later")
  assert e3.isSome
  assert e3.get().kind == xekDenied

  echo "PASS: Queue event parsing edge cases"

# ============================================================
# Test 10: Batch command formatting
# ============================================================

block testBatchFormatting:
  assert formatXdccBatchRange(1, 5) == "XDCC BATCH 1-5"
  assert formatXdccBatchRange(10, 20) == "XDCC BATCH 10-20"
  assert formatXdccBatchList([1, 3, 5, 7]) == "XDCC BATCH 1,3,5,7"
  assert formatXdccBatchList([42]) == "XDCC BATCH 42"

  echo "PASS: Batch command formatting"

echo "All XDCC tests passed!"
