## Tests for CPS IRC Protocol parsing and formatting

import cps/irc/protocol
import std/[options, tables, strutils]

# ============================================================
# Test: Parse IRC prefix
# ============================================================

block testParsePrefix:
  let p1 = parsePrefix("nick!user@host.com")
  assert p1.nick == "nick", "Expected nick, got: " & p1.nick
  assert p1.user == "user", "Expected user, got: " & p1.user
  assert p1.host == "host.com", "Expected host.com, got: " & p1.host

  let p2 = parsePrefix("nick@host.com")
  assert p2.nick == "nick"
  assert p2.user == ""
  assert p2.host == "host.com"

  let p3 = parsePrefix("irc.server.com")
  assert p3.nick == "irc.server.com"
  assert p3.host == "irc.server.com"

  echo "PASS: Parse IRC prefix"

# ============================================================
# Test: Parse IRC messages
# ============================================================

block testParseMessage:
  # Simple PING
  let m1 = parseIrcMessage("PING :irc.server.com")
  assert m1.command == "PING", "Expected PING, got: " & m1.command
  assert m1.params.len == 1
  assert m1.params[0] == "irc.server.com"

  # PRIVMSG with prefix
  let m2 = parseIrcMessage(":nick!user@host PRIVMSG #channel :Hello world!")
  assert m2.prefix.nick == "nick"
  assert m2.prefix.user == "user"
  assert m2.prefix.host == "host"
  assert m2.command == "PRIVMSG"
  assert m2.params.len == 2
  assert m2.params[0] == "#channel"
  assert m2.params[1] == "Hello world!"

  # Numeric reply
  let m3 = parseIrcMessage(":irc.server.com 001 cpsbot :Welcome to IRC")
  assert m3.prefix.nick == "irc.server.com"
  assert m3.command == "001"
  assert m3.params.len == 2
  assert m3.params[0] == "cpsbot"
  assert m3.params[1] == "Welcome to IRC"

  # JOIN
  let m4 = parseIrcMessage(":nick!user@host JOIN #channel")
  assert m4.command == "JOIN"
  assert m4.params[0] == "#channel"

  # No trailing parameter
  let m5 = parseIrcMessage(":nick!user@host QUIT")
  assert m5.command == "QUIT"
  assert m5.params.len == 0

  # QUIT with reason
  let m6 = parseIrcMessage(":nick!user@host QUIT :Goodbye cruel world")
  assert m6.command == "QUIT"
  assert m6.params.len == 1
  assert m6.params[0] == "Goodbye cruel world"

  echo "PASS: Parse IRC messages"

# ============================================================
# Test: Parse IRCv3 tags
# ============================================================

block testParseTags:
  let m = parseIrcMessage("@time=2024-01-01T00:00:00Z;account=nick :nick!user@host PRIVMSG #ch :hi")
  assert m.tags.len == 2
  assert m.tags["time"] == "2024-01-01T00:00:00Z"
  assert m.tags["account"] == "nick"
  assert m.command == "PRIVMSG"
  assert m.params[1] == "hi"

  echo "PASS: Parse IRCv3 tags"

# ============================================================
# Test: Format IRC messages
# ============================================================

block testFormatMessage:
  assert formatIrcMessage("PING", "token") == "PING :token\r\n"
  assert formatIrcMessage("PRIVMSG", "#channel", "Hello world") == "PRIVMSG #channel :Hello world\r\n"
  assert formatIrcMessage("JOIN", "#test") == "JOIN :#test\r\n"
  assert formatNick("cpsbot") == "NICK :cpsbot\r\n"
  assert formatUser("cps", "CPS Bot") == "USER cps 0 * :CPS Bot\r\n"
  assert formatPong("server.com") == "PONG :server.com\r\n"
  assert formatJoin("#test") == "JOIN :#test\r\n"
  assert formatJoin("#test", "key123") == "JOIN #test :key123\r\n"
  assert formatPart("#test") == "PART :#test\r\n"
  assert formatPart("#test", "bye") == "PART #test :bye\r\n"
  assert formatQuit() == "QUIT\r\n"
  assert formatQuit("leaving") == "QUIT :leaving\r\n"

  echo "PASS: Format IRC messages"

# ============================================================
# Test: CTCP parsing
# ============================================================

block testCtcp:
  assert isCtcp("\x01VERSION\x01")
  assert isCtcp("\x01PING 1234\x01")
  assert not isCtcp("normal message")
  assert not isCtcp("\x01")
  assert not isCtcp("")

  let (cmd1, args1) = parseCtcp("\x01VERSION\x01")
  assert cmd1 == "VERSION"
  assert args1 == ""

  let (cmd2, args2) = parseCtcp("\x01PING 12345\x01")
  assert cmd2 == "PING"
  assert args2 == "12345"

  let (cmd3, args3) = parseCtcp("\x01DCC SEND file.txt 3232235777 1234 56789\x01")
  assert cmd3 == "DCC"
  assert args3 == "SEND file.txt 3232235777 1234 56789"

  echo "PASS: CTCP parsing"

# ============================================================
# Test: CTCP formatting
# ============================================================

block testCtcpFormat:
  let msg = formatCtcp("#channel", "VERSION")
  assert msg == "PRIVMSG #channel :\x01VERSION\x01\r\n", "Got: " & repr(msg)

  let msg2 = formatCtcp("nick", "PING", "12345")
  assert msg2 == "PRIVMSG nick :\x01PING 12345\x01\r\n"

  let reply = formatCtcpReply("nick", "VERSION", "CPS IRC 1.0")
  assert reply == "NOTICE nick :\x01VERSION CPS IRC 1.0\x01\r\n"

  echo "PASS: CTCP formatting"

# ============================================================
# Test: DCC long IP conversion
# ============================================================

block testDccIp:
  # 192.168.1.1 = 3232235777
  let ip = longIpToString(3232235777'u32)
  assert ip == "192.168.1.1", "Expected 192.168.1.1, got: " & ip

  let longIp = stringToLongIp("192.168.1.1")
  assert longIp == 3232235777'u32, "Expected 3232235777, got: " & $longIp

  # Round trip
  assert longIpToString(stringToLongIp("10.0.0.1")) == "10.0.0.1"
  assert longIpToString(stringToLongIp("127.0.0.1")) == "127.0.0.1"
  assert longIpToString(stringToLongIp("255.255.255.255")) == "255.255.255.255"

  echo "PASS: DCC long IP conversion"

# ============================================================
# Test: DCC parsing
# ============================================================

block testDccParse:
  # DCC SEND
  let d1 = parseDcc("SEND file.epub 3232235777 1234 56789")
  assert d1.isSome
  let dcc1 = d1.get()
  assert dcc1.kind == "SEND"
  assert dcc1.filename == "file.epub"
  assert dcc1.ip == 3232235777'u32
  assert dcc1.port == 1234
  assert dcc1.filesize == 56789

  # DCC SEND with quoted filename
  let d2 = parseDcc("SEND \"My Book Title.pdf\" 3232235777 1234 12345678")
  assert d2.isSome
  let dcc2 = d2.get()
  assert dcc2.kind == "SEND"
  assert dcc2.filename == "My Book Title.pdf"
  assert dcc2.ip == 3232235777'u32
  assert dcc2.port == 1234
  assert dcc2.filesize == 12345678

  # DCC SEND without filesize
  let d3 = parseDcc("SEND file.txt 2130706433 8080")
  assert d3.isSome
  let dcc3 = d3.get()
  assert dcc3.kind == "SEND"
  assert dcc3.filename == "file.txt"
  assert dcc3.filesize == -1

  # DCC CHAT
  let d4 = parseDcc("CHAT chat 3232235777 9999")
  assert d4.isSome
  let dcc4 = d4.get()
  assert dcc4.kind == "CHAT"
  assert dcc4.ip == 3232235777'u32
  assert dcc4.port == 9999

  # Invalid DCC
  let d5 = parseDcc("INVALID")
  assert d5.isNone

  # DCC SEND with token (passive/reverse DCC)
  let d6 = parseDcc("SEND file.epub 3232235777 0 56789 token123")
  assert d6.isSome
  let dcc6 = d6.get()
  assert dcc6.port == 0
  assert dcc6.token == "token123"

  echo "PASS: DCC parsing"

# ============================================================
# Test: Message classification
# ============================================================

block testClassify:
  # PING
  let pingMsg = parseIrcMessage("PING :server.com")
  let pingEvt = classifyMessage(pingMsg)
  assert pingEvt.kind == iekPing
  assert pingEvt.pingToken == "server.com"

  # PRIVMSG
  let privMsg = parseIrcMessage(":user!ident@host PRIVMSG #channel :Hello!")
  let privEvt = classifyMessage(privMsg)
  assert privEvt.kind == iekPrivMsg
  assert privEvt.pmSource == "user"
  assert privEvt.pmTarget == "#channel"
  assert privEvt.pmText == "Hello!"

  # NOTICE
  let noticeMsg = parseIrcMessage(":bot!ident@host NOTICE user :You are noticed")
  let noticeEvt = classifyMessage(noticeMsg)
  assert noticeEvt.kind == iekNotice
  assert noticeEvt.pmSource == "bot"
  assert noticeEvt.pmText == "You are noticed"

  # JOIN
  let joinMsg = parseIrcMessage(":user!ident@host JOIN #newchannel")
  let joinEvt = classifyMessage(joinMsg)
  assert joinEvt.kind == iekJoin
  assert joinEvt.joinNick == "user"
  assert joinEvt.joinChannel == "#newchannel"

  # PART
  let partMsg = parseIrcMessage(":user!ident@host PART #channel :Leaving")
  let partEvt = classifyMessage(partMsg)
  assert partEvt.kind == iekPart
  assert partEvt.partNick == "user"
  assert partEvt.partChannel == "#channel"
  assert partEvt.partReason == "Leaving"

  # QUIT
  let quitMsg = parseIrcMessage(":user!ident@host QUIT :Goodbye")
  let quitEvt = classifyMessage(quitMsg)
  assert quitEvt.kind == iekQuit
  assert quitEvt.quitNick == "user"
  assert quitEvt.quitReason == "Goodbye"

  # KICK
  let kickMsg = parseIrcMessage(":op!ident@host KICK #channel user :Behave")
  let kickEvt = classifyMessage(kickMsg)
  assert kickEvt.kind == iekKick
  assert kickEvt.kickChannel == "#channel"
  assert kickEvt.kickNick == "user"
  assert kickEvt.kickBy == "op"
  assert kickEvt.kickReason == "Behave"

  # NICK change
  let nickMsg = parseIrcMessage(":oldnick!ident@host NICK newnick")
  let nickEvt = classifyMessage(nickMsg)
  assert nickEvt.kind == iekNick
  assert nickEvt.nickOld == "oldnick"
  assert nickEvt.nickNew == "newnick"

  # Numeric (001 RPL_WELCOME)
  let numMsg = parseIrcMessage(":server 001 cpsbot :Welcome to IRC")
  let numEvt = classifyMessage(numMsg)
  assert numEvt.kind == iekNumeric
  assert numEvt.numCode == 1
  assert numEvt.numParams[0] == "cpsbot"

  # CTCP VERSION
  let ctcpMsg = parseIrcMessage(":user!ident@host PRIVMSG cpsbot :\x01VERSION\x01")
  let ctcpEvt = classifyMessage(ctcpMsg)
  assert ctcpEvt.kind == iekCtcp
  assert ctcpEvt.ctcpSource == "user"
  assert ctcpEvt.ctcpCommand == "VERSION"

  # DCC SEND via CTCP
  let dccMsg = parseIrcMessage(":bot!ident@host PRIVMSG user :\x01DCC SEND file.epub 3232235777 1234 56789\x01")
  let dccEvt = classifyMessage(dccMsg)
  assert dccEvt.kind == iekDccSend
  assert dccEvt.dccSource == "bot"
  assert dccEvt.dccInfo.filename == "file.epub"
  assert dccEvt.dccInfo.ip == 3232235777'u32
  assert dccEvt.dccInfo.port == 1234
  assert dccEvt.dccInfo.filesize == 56789

  # INVITE
  let inviteMsg = parseIrcMessage(":user!ident@host INVITE cpsbot #secret")
  let inviteEvt = classifyMessage(inviteMsg)
  assert inviteEvt.kind == iekInvite
  assert inviteEvt.inviteNick == "user"
  assert inviteEvt.inviteChannel == "#secret"

  # MODE
  let modeMsg = parseIrcMessage(":op!ident@host MODE #channel +o user")
  let modeEvt = classifyMessage(modeMsg)
  assert modeEvt.kind == iekMode
  assert modeEvt.modeTarget == "#channel"
  assert modeEvt.modeChanges == "+o"
  assert modeEvt.modeParams.len == 1
  assert modeEvt.modeParams[0] == "user"

  # TOPIC
  let topicMsg = parseIrcMessage(":user!ident@host TOPIC #channel :New topic here")
  let topicEvt = classifyMessage(topicMsg)
  assert topicEvt.kind == iekTopic
  assert topicEvt.topicChannel == "#channel"
  assert topicEvt.topicText == "New topic here"
  assert topicEvt.topicBy == "user"

  echo "PASS: Message classification"

# ============================================================
# Test: isChannel
# ============================================================

block testIsChannel:
  assert isChannel("#test")
  assert isChannel("&local")
  assert isChannel("+channel")
  assert isChannel("!12345")
  assert not isChannel("nick")
  assert not isChannel("")

  echo "PASS: isChannel"

# ============================================================
# Test: DCC SEND via CTCP in classified message (round trip)
# ============================================================

block testDccRoundTrip:
  # Simulate what an IRC client would see
  let raw = ":BookBot!bot@irc.server.com PRIVMSG cpsbot :\x01DCC SEND \"The Lord of the Rings.epub\" 3232235777 4567 8901234\x01"
  let msg = parseIrcMessage(raw)
  let evt = classifyMessage(msg)
  assert evt.kind == iekDccSend
  assert evt.dccSource == "BookBot"
  assert evt.dccInfo.filename == "The Lord of the Rings.epub"
  assert evt.dccInfo.port == 4567
  assert evt.dccInfo.filesize == 8901234
  let ipStr = longIpToString(evt.dccInfo.ip)
  assert ipStr == "192.168.1.1", "Expected 192.168.1.1, got: " & ipStr

  echo "PASS: DCC round trip"

# ============================================================
# Test: DCC RESUME/ACCEPT formatting
# ============================================================

block testDccResumeAcceptFormatting:
  let resume = formatDccResume("BookBot", "test.epub", 4567, 1048576)
  assert resume.contains("DCC RESUME test.epub 4567 1048576")
  assert resume.contains("\x01")  # CTCP wrapped
  assert resume.startsWith("PRIVMSG BookBot :")

  let accept = formatDccAccept("user123", "test.epub", 4567, 1048576)
  assert accept.contains("DCC ACCEPT test.epub 4567 1048576")
  assert accept.contains("\x01")
  assert accept.startsWith("PRIVMSG user123 :")

  echo "PASS: DCC RESUME/ACCEPT formatting"

# ============================================================
# Test: IRC formatting stripping
# ============================================================

block testIrcFormattingStripping:
  # Bold
  assert stripIrcFormatting("\x02bold\x02") == "bold"

  # Color codes
  assert stripIrcFormatting("\x034red") == "red"
  assert stripIrcFormatting("\x0304,01colored") == "colored"

  # Mixed formatting (FWServer style)
  let messy = "\x0304,00\x0314,00 \x0312,00Type:\x0304,00 @Bot"
  let clean = stripIrcFormatting(messy)
  assert clean.contains("Type:")
  assert clean.contains("@Bot")
  assert not clean.contains("\x03")

  # Reset, underline, italic
  assert stripIrcFormatting("a\x0Fb") == "ab"
  assert stripIrcFormatting("\x1Funderlined\x1F") == "underlined"
  assert stripIrcFormatting("\x1Ditalic\x1D") == "italic"

  # No formatting
  assert stripIrcFormatting("plain") == "plain"
  assert stripIrcFormatting("") == ""

  echo "PASS: IRC formatting stripping"

# ============================================================
# Test: Tag value escaping/unescaping
# ============================================================

block testTagEscaping:
  # Basic escapes
  assert unescapeTagValue("hello\\sworld") == "hello world"
  assert unescapeTagValue("semi\\:colon") == "semi;colon"
  assert unescapeTagValue("back\\\\slash") == "back\\slash"
  assert unescapeTagValue("cr\\r") == "cr\r"
  assert unescapeTagValue("lf\\n") == "lf\n"

  # Multiple escapes
  assert unescapeTagValue("a\\sb\\:c\\\\d") == "a b;c\\d"

  # Unknown escape — drop backslash
  assert unescapeTagValue("\\x") == "x"

  # Trailing backslash — dropped
  assert unescapeTagValue("trail\\") == "trail"

  # No escapes
  assert unescapeTagValue("plain") == "plain"
  assert unescapeTagValue("") == ""

  # Round-trip
  assert unescapeTagValue(escapeTagValue("hello world; test\\")) == "hello world; test\\"
  assert unescapeTagValue(escapeTagValue("line\nbreak\rreturn")) == "line\nbreak\rreturn"
  assert unescapeTagValue(escapeTagValue("")) == ""
  assert unescapeTagValue(escapeTagValue("no escapes needed")) == "no escapes needed"

  echo "PASS: Tag value escaping/unescaping"

# ============================================================
# Test: Tag escaping in parseIrcMessage
# ============================================================

block testTagEscapingInParse:
  let m = parseIrcMessage("@key=value\\swith\\:special :nick!user@host PRIVMSG #ch :hi")
  assert m.tags["key"] == "value with;special", "Got: " & m.tags["key"]
  echo "PASS: Tag escaping in parseIrcMessage"

# ============================================================
# Test: Tagged message formatting
# ============================================================

block testTaggedMessageFormat:
  var tags = initTable[string, string]()
  tags["+draft/reply"] = "abc123"
  tags["label"] = "1"

  let msg = formatTaggedMessage(tags, "PRIVMSG", "#channel", "Hello!")
  assert msg.startsWith("@"), "Should start with @"
  assert msg.contains("PRIVMSG #channel :Hello!\r\n"), "Should contain command"
  assert msg.contains("+draft/reply=abc123"), "Should contain reply tag"
  assert msg.contains("label=1"), "Should contain label tag"

  # TAGMSG formatting
  var tagmsgTags = initTable[string, string]()
  tagmsgTags["+typing"] = "active"
  let tagmsg = formatTagMsg("#channel", tagmsgTags)
  assert tagmsg.contains("TAGMSG"), "Should contain TAGMSG"
  assert tagmsg.contains("+typing=active"), "Should contain typing tag"

  echo "PASS: Tagged message formatting"

# ============================================================
# Test: Tag prefix with escaping
# ============================================================

block testTagPrefixEscaping:
  var tags = initTable[string, string]()
  tags["key"] = "value with spaces"
  let prefix = formatTagPrefix(tags)
  assert prefix.contains("key=value\\swith\\sspaces"), "Got: " & prefix

  echo "PASS: Tag prefix escaping"

# ============================================================
# Test: ISUPPORT parsing
# ============================================================

block testIsupportParsing:
  # Typical 005 line params: [nick, token1, token2, ..., "are supported by this server"]
  let params = @["testbot", "MONITOR=100", "WHOX", "NETWORK=Libera.Chat",
                  "PREFIX=(ov)@+", "UTF8ONLY", "NICKLEN=16", "TOPICLEN=390",
                  "are supported by this server"]

  let parsed = parseIsupport(params)
  assert parsed.len == 7, "Expected 7 tokens, got: " & $parsed.len

  let isup = newISupport()
  updateIsupport(isup, params)
  assert isup.monitor == 100, "MONITOR: " & $isup.monitor
  assert isup.whox == true, "WHOX should be true"
  assert isup.network == "Libera.Chat", "NETWORK: " & isup.network
  assert isup.prefix == "(ov)@+", "PREFIX: " & isup.prefix
  assert isup.utf8Only == true
  assert isup.nickLen == 16
  assert isup.topicLen == 390
  assert isup.raw["MONITOR"] == "100"
  assert isup.raw["WHOX"] == ""

  echo "PASS: ISUPPORT parsing"

# ============================================================
# Test: Standard replies (FAIL/WARN/NOTE)
# ============================================================

block testStandardReplies:
  # FAIL with context
  let m1 = parseIrcMessage(":server FAIL CHATHISTORY NEED_MORE_PARAMS LATEST :Missing parameters")
  let e1 = classifyMessage(m1)
  assert e1.kind == iekStandardReply, "Expected iekStandardReply, got: " & $e1.kind
  assert e1.srLevel == "FAIL"
  assert e1.srCommand == "CHATHISTORY"
  assert e1.srCode == "NEED_MORE_PARAMS"
  assert e1.srContext == @["LATEST"], "Context: " & $e1.srContext
  assert e1.srDescription == "Missing parameters"

  # WARN without context
  let m2 = parseIrcMessage(":server WARN CONNECT INVALID_CERT :Certificate is self-signed")
  let e2 = classifyMessage(m2)
  assert e2.kind == iekStandardReply
  assert e2.srLevel == "WARN"
  assert e2.srCommand == "CONNECT"
  assert e2.srCode == "INVALID_CERT"
  assert e2.srContext.len == 0
  assert e2.srDescription == "Certificate is self-signed"

  # NOTE
  let m3 = parseIrcMessage(":server NOTE * COMPAT :Using compatibility mode")
  let e3 = classifyMessage(m3)
  assert e3.kind == iekStandardReply
  assert e3.srLevel == "NOTE"
  assert e3.srCommand == "*"
  assert e3.srCode == "COMPAT"

  echo "PASS: Standard replies (FAIL/WARN/NOTE)"

# ============================================================
# Test: Tag helper procs
# ============================================================

block testTagHelpers:
  let m = parseIrcMessage("@msgid=abc;time=2024-01-01T00:00:00Z;account=user1;bot :nick!user@host PRIVMSG #ch :hi")
  assert getMsgId(m) == "abc"
  assert getTime(m) == "2024-01-01T00:00:00Z"
  assert getAccount(m) == "user1"
  assert isBot(m) == true
  assert getBatchRef(m) == ""

  let m2 = parseIrcMessage(":nick!user@host PRIVMSG #ch :hi")
  assert getMsgId(m2) == ""
  assert isBot(m2) == false

  echo "PASS: Tag helper procs"

# ============================================================
# Test: MONITOR numeric classification
# ============================================================

block testMonitorNumerics:
  # RPL_MONONLINE (730)
  let m1 = parseIrcMessage(":server 730 mynick :user1!ident@host,user2!ident@host2")
  let e1 = classifyMessage(m1)
  assert e1.kind == iekMonOnline
  assert e1.monOnlineTargets == @["user1", "user2"], "Got: " & $e1.monOnlineTargets

  # RPL_MONOFFLINE (731)
  let m2 = parseIrcMessage(":server 731 mynick :user3,user4")
  let e2 = classifyMessage(m2)
  assert e2.kind == iekMonOffline
  assert e2.monOfflineTargets == @["user3", "user4"]

  echo "PASS: MONITOR numeric classification"

# ============================================================
# Test: TAGMSG classification
# ============================================================

block testTagmsgClassification:
  # \: in IRC tag values means semicolon (;), so the react value will be ";)"
  let m = parseIrcMessage("@+draft/react=\\:) :nick!user@host TAGMSG #channel")
  let e = classifyMessage(m)
  assert e.kind == iekTagMsg
  assert e.tagmsgSource == "nick"
  assert e.tagmsgTarget == "#channel"
  assert e.tagmsgTags["+draft/react"] == ";)", "React value: " & e.tagmsgTags.getOrDefault("+draft/react", "<missing>")

  echo "PASS: TAGMSG classification"

# ============================================================
# Test: Typing indicator via TAGMSG
# ============================================================

block testTypingIndicator:
  let m = parseIrcMessage("@+typing=active :nick!user@host TAGMSG #channel")
  let e = classifyMessage(m)
  assert e.kind == iekTyping
  assert e.typingNick == "nick"
  assert e.typingTarget == "#channel"
  assert e.typingActive == true

  let m2 = parseIrcMessage("@+typing=done :nick!user@host TAGMSG #channel")
  let e2 = classifyMessage(m2)
  assert e2.kind == iekTyping
  assert e2.typingActive == false

  echo "PASS: Typing indicator"

# ============================================================
# Test: REDACT classification
# ============================================================

block testRedactClassification:
  let m = parseIrcMessage(":nick!user@host REDACT #channel msg123 :Inappropriate content")
  let e = classifyMessage(m)
  assert e.kind == iekRedact
  assert e.redactTarget == "#channel"
  assert e.redactMsgId == "msg123"
  assert e.redactReason == "Inappropriate content"
  assert e.redactBy == "nick"

  # Without reason
  let m2 = parseIrcMessage(":nick!user@host REDACT #channel msg456")
  let e2 = classifyMessage(m2)
  assert e2.kind == iekRedact
  assert e2.redactMsgId == "msg456"
  assert e2.redactReason == ""

  echo "PASS: REDACT classification"

# ============================================================
# Test: RENAME classification
# ============================================================

block testRenameClassification:
  let m = parseIrcMessage(":server RENAME #old #new :Channel has been renamed")
  let e = classifyMessage(m)
  assert e.kind == iekChannelRename
  assert e.renameOld == "#old"
  assert e.renameNew == "#new"
  assert e.renameReason == "Channel has been renamed"

  echo "PASS: RENAME classification"

# ============================================================
# Test: MARKREAD classification
# ============================================================

block testMarkreadClassification:
  let m = parseIrcMessage(":server MARKREAD #channel timestamp=2024-01-01T00:00:00Z")
  let e = classifyMessage(m)
  assert e.kind == iekMarkread
  assert e.markreadTarget == "#channel"
  assert e.markreadTimestamp == "2024-01-01T00:00:00Z"

  echo "PASS: MARKREAD classification"

# ============================================================
# Test: MONITOR formatting
# ============================================================

block testMonitorFormatting:
  assert formatMonitorAdd("nick1", "nick2").contains("MONITOR + :nick1,nick2")
  assert formatMonitorRemove("nick1").contains("MONITOR - :nick1")
  assert formatMonitorClear().contains("MONITOR :C")
  assert formatMonitorList().contains("MONITOR :L")
  assert formatMonitorStatus().contains("MONITOR :S")

  echo "PASS: MONITOR formatting"

# ============================================================
# Test: WHO/WHOX formatting
# ============================================================

block testWhoFormatting:
  assert formatWho("#channel").contains("WHO :#channel")
  let whox = formatWhox("#channel", "%tcnuhraf", "123")
  assert whox.contains("WHO #channel :%tcnuhraf,123"), "Got: " & whox

  echo "PASS: WHO/WHOX formatting"

# ============================================================
# Test: CHATHISTORY formatting
# ============================================================

block testChathistoryFormatting:
  let latest = formatChathistoryLatest("#channel", "*", 50)
  assert latest.contains("CHATHISTORY"), "Got: " & latest
  assert latest.contains("LATEST"), latest
  assert latest.contains("#channel"), latest
  assert latest.contains("50"), latest

  let before = formatChathistoryBefore("#channel", "msgid=abc", 25)
  assert before.contains("BEFORE"), before

  echo "PASS: CHATHISTORY formatting"

# ============================================================
# Test: REDACT formatting
# ============================================================

block testRedactFormatting:
  let r1 = formatRedact("#channel", "msg123", "spam")
  assert r1.contains("REDACT #channel msg123 :spam"), "Got: " & r1

  let r2 = formatRedact("#channel", "msg456")
  assert r2.contains("REDACT #channel :msg456"), "Got: " & r2

  echo "PASS: REDACT formatting"

# ============================================================
# Test: Batch aggregation
# ============================================================

block testBatchAggregation:
  let agg = newBatchAggregator()

  # Open batch
  let batchStartMsg = parseIrcMessage(":server BATCH +abc chathistory #channel")
  let batchStartEvt = classifyMessage(batchStartMsg)
  let r1 = agg.processBatch(batchStartEvt, batchStartMsg)
  assert r1.isNone, "Should not complete on start"

  # Add messages to batch
  let pm1 = parseIrcMessage("@batch=abc :nick!user@host PRIVMSG #channel :hello")
  let pm1evt = classifyMessage(pm1)
  assert agg.isInBatch(pm1), "Message should be in batch"
  let r2 = agg.processBatch(pm1evt, pm1)
  assert r2.isNone, "Should not complete on message"

  let pm2 = parseIrcMessage("@batch=abc :nick2!user@host PRIVMSG #channel :world")
  let pm2evt = classifyMessage(pm2)
  let r3 = agg.processBatch(pm2evt, pm2)
  assert r3.isNone

  # Close batch
  let batchEndMsg = parseIrcMessage(":server BATCH -abc")
  let batchEndEvt = classifyMessage(batchEndMsg)
  let r4 = agg.processBatch(batchEndEvt, batchEndMsg)
  assert r4.isSome, "Should complete on end"
  let batch = r4.get()
  assert batch.batchRef == "abc"
  assert batch.batchType == "chathistory"
  assert batch.batchParams == @["#channel"]
  assert batch.messages.len == 2, "Expected 2 messages, got: " & $batch.messages.len

  echo "PASS: Batch aggregation"

# ============================================================
# Test: Nested batch aggregation
# ============================================================

block testNestedBatches:
  let agg = newBatchAggregator()

  # Open outer batch
  let outer = parseIrcMessage(":server BATCH +outer netsplit")
  let outerEvt = classifyMessage(outer)
  discard agg.processBatch(outerEvt, outer)

  # Open inner batch (has batch=outer tag)
  let inner = parseIrcMessage("@batch=outer :server BATCH +inner netjoin")
  let innerEvt = classifyMessage(inner)
  discard agg.processBatch(innerEvt, inner)

  # Add message to inner batch
  let m = parseIrcMessage("@batch=inner :nick!user@host JOIN #channel")
  let mEvt = classifyMessage(m)
  discard agg.processBatch(mEvt, m)

  # Close inner batch
  let innerEnd = parseIrcMessage(":server BATCH -inner")
  let innerEndEvt = classifyMessage(innerEnd)
  let r1 = agg.processBatch(innerEndEvt, innerEnd)
  assert r1.isNone, "Nested batch should go to parent, not returned directly"

  # Close outer batch
  let outerEnd = parseIrcMessage(":server BATCH -outer")
  let outerEndEvt = classifyMessage(outerEnd)
  let r2 = agg.processBatch(outerEndEvt, outerEnd)
  assert r2.isSome
  let batch = r2.get()
  assert batch.batchRef == "outer"
  assert batch.nestedBatches.len == 1, "Expected 1 nested batch"
  assert batch.nestedBatches[0].batchRef == "inner"
  assert batch.nestedBatches[0].messages.len == 1

  echo "PASS: Nested batch aggregation"

# ============================================================
# Test: Multiline assembly
# ============================================================

block testMultilineAssembly:
  let batch = CompletedBatch(
    batchRef: "ml1",
    batchType: "draft/multiline",
    batchParams: @["#channel"],
    messages: @[
      BatchedMessage(
        event: IrcEvent(kind: iekPrivMsg, pmSource: "nick", pmTarget: "#channel", pmText: "Hello"),
        msg: IrcMessage(command: "PRIVMSG", params: @["#channel", "Hello"]),
      ),
      BatchedMessage(
        event: IrcEvent(kind: iekPrivMsg, pmSource: "nick", pmTarget: "#channel", pmText: "World"),
        msg: IrcMessage(command: "PRIVMSG", params: @["#channel", "World"]),
      ),
    ],
  )
  let text = assembleMultiline(batch)
  assert text == "Hello\nWorld", "Got: " & text

  # With concat tag (no newline between)
  var concatTags = initTable[string, string]()
  concatTags[tagMultilineConcat] = ""
  let batchConcat = CompletedBatch(
    batchRef: "ml2",
    batchType: "draft/multiline",
    messages: @[
      BatchedMessage(
        event: IrcEvent(kind: iekPrivMsg, pmSource: "nick", pmTarget: "#ch", pmText: "Hel"),
        msg: IrcMessage(command: "PRIVMSG", params: @["#ch", "Hel"]),
      ),
      BatchedMessage(
        event: IrcEvent(kind: iekPrivMsg, pmSource: "nick", pmTarget: "#ch", pmText: "lo"),
        msg: IrcMessage(command: "PRIVMSG", params: @["#ch", "lo"], tags: concatTags),
      ),
      BatchedMessage(
        event: IrcEvent(kind: iekPrivMsg, pmSource: "nick", pmTarget: "#ch", pmText: "World"),
        msg: IrcMessage(command: "PRIVMSG", params: @["#ch", "World"]),
      ),
    ],
  )
  let text2 = assembleMultiline(batchConcat)
  assert text2 == "Hello\nWorld", "Got: " & text2

  echo "PASS: Multiline assembly"

# ============================================================
# Test: Account registration formatting
# ============================================================

block testAccountRegistration:
  let r = formatRegister("myaccount", "email@example.com", "secretpass")
  assert r.contains("REGISTER myaccount email@example.com :secretpass"), "Got: " & r

  let v = formatVerify("myaccount", "123456")
  assert v.contains("VERIFY myaccount :123456"), "Got: " & v

  echo "PASS: Account registration formatting"

# ============================================================
# Test: MARKREAD formatting
# ============================================================

block testMarkreadFormatting:
  let m = formatMarkread("#channel", "2024-01-01T00:00:00Z")
  assert m.contains("MARKREAD #channel :timestamp=2024-01-01T00:00:00Z"), "Got: " & m

  echo "PASS: MARKREAD formatting"

# ============================================================
# Test: STARTTLS formatting
# ============================================================

block testStarttlsFormatting:
  let s = formatStarttls()
  assert s == "STARTTLS\r\n", "Got: " & s

  echo "PASS: STARTTLS formatting"

# ============================================================
# Test: AUTHENTICATE formatting
# ============================================================

block testAuthenticateFormatting:
  let a1 = formatAuthenticate("PLAIN")
  assert a1 == "AUTHENTICATE :PLAIN\r\n", "Got: " & a1

  let a2 = formatAuthenticate("dGVzdA==")
  assert a2 == "AUTHENTICATE :dGVzdA==\r\n", "Got: " & a2

  let a3 = formatAuthenticate("*")
  assert a3 == "AUTHENTICATE :*\r\n", "Got: " & a3

  echo "PASS: AUTHENTICATE formatting"

# ============================================================
# Test: FAIL/WARN code constants exist
# ============================================================

block testFailWarnCodeConstants:
  # Verify key constants are defined and have expected values
  assert failAccountRequired == "ACCOUNT_REQUIRED"
  assert failInvalidUtf8 == "INVALID_UTF8"
  assert warnInvalidUtf8 == "INVALID_UTF8"

  # BATCH FAIL codes
  assert failBatchMultilineMaxBytes == "MULTILINE_MAX_BYTES"
  assert failBatchMultilineMaxLines == "MULTILINE_MAX_LINES"
  assert failBatchMultilineInvalidTarget == "MULTILINE_INVALID_TARGET"
  assert failBatchInvalidReftag == "INVALID_REFTAG"

  # CHATHISTORY FAIL codes
  assert failChathistoryInvalidParams == "INVALID_PARAMS"
  assert failChathistoryMessageError == "MESSAGE_ERROR"

  # REDACT FAIL codes
  assert failRedactForbidden == "REDACT_FORBIDDEN"
  assert failRedactWindowExpired == "REDACT_WINDOW_EXPIRED"

  # REGISTER FAIL codes
  assert failRegisterAccountExists == "ACCOUNT_EXISTS"
  assert failRegisterWeakPassword == "WEAK_PASSWORD"
  assert failRegisterBadAccountName == "BAD_ACCOUNT_NAME"

  # RENAME FAIL codes
  assert failRenameChannelNameInUse == "CHANNEL_NAME_IN_USE"

  # SETNAME FAIL codes
  assert failSetnameCannotChangeRealname == "CANNOT_CHANGE_REALNAME"

  # VERIFY FAIL codes
  assert failVerifyInvalidCode == "INVALID_CODE"

  echo "PASS: FAIL/WARN code constants"

# ============================================================
# Test: Metadata key constants
# ============================================================

block testMetadataKeyConstants:
  assert metaAvatar == "avatar"
  assert metaBot == "bot"
  assert metaColor == "color"
  assert metaDisplayName == "display-name"
  assert metaHomepage == "homepage"
  assert metaStatus == "status"
  assert metaChanAvatar == "avatar"
  assert metaChanDisplayName == "display-name"

  echo "PASS: Metadata key constants"

# ============================================================
# Test: Batch type constants
# ============================================================

block testBatchTypeConstants:
  assert batchNetjoin == "netjoin"
  assert batchNetsplit == "netsplit"
  assert batchChathistory == "chathistory"
  assert batchMultiline == "draft/multiline"
  assert batchLabeledResponse == "labeled-response"

  echo "PASS: Batch type constants"

# ============================================================
# Test: Capability name constants
# ============================================================

block testCapabilityConstants:
  assert capServerTime == "server-time"
  assert capSasl == "sasl"
  assert capStandardReplies == "standard-replies"
  assert capMonitor == "monitor"
  assert capTls == "tls"
  assert capDraftChathistory == "draft/chathistory"
  assert capDraftMultiline == "draft/multiline"
  assert capDraftAccountRegistration == "draft/account-registration"

  echo "PASS: Capability name constants"

# ============================================================
# Test: Numeric constants (new/fixed)
# ============================================================

block testNumericConstants:
  # STARTTLS
  assert RPL_STARTTLS == 670
  assert ERR_STARTTLS == 691

  # SASL
  assert ERR_NICKLOCKED == 902
  assert RPL_SASLSUCCESS == 903

  # Metadata (corrected per IRCv3 registry)
  assert RPL_WHOISKEYVALUE == 760
  assert RPL_KEYVALUE == 761
  assert RPL_METADATAEND == 762
  assert RPL_KEYNOTSET == 766
  assert RPL_METADATASUBOK == 770
  assert RPL_METADATAUNSUBOK == 771
  assert RPL_METADATASUBS == 772
  assert RPL_METADATASYNCLATER == 774

  echo "PASS: Numeric constants"

# ============================================================
# Test: CLIENTTAGDENY enforcement
# ============================================================

block testClientTagDeny:
  var isup = newISupport()

  # No restrictions — all tags allowed
  assert isup.isTagAllowed("+typing")
  assert isup.isTagAllowed("+draft/reply")
  assert isup.isTagAllowed("msgid")  # Server tags always allowed

  # Deny specific tag
  isup.clientTagDeny = @["+typing"]
  assert not isup.isTagAllowed("+typing"), "Should deny +typing"
  assert isup.isTagAllowed("+draft/reply"), "Should allow +draft/reply"
  assert isup.isTagAllowed("msgid"), "Server tags always allowed"

  # Deny all client tags with wildcard
  isup.clientTagDeny = @["*"]
  assert not isup.isTagAllowed("+typing"), "Wildcard should deny all client tags"
  assert not isup.isTagAllowed("+draft/reply"), "Wildcard should deny all client tags"
  assert isup.isTagAllowed("msgid"), "Server tags always allowed even with wildcard"

  # Filter tags
  isup.clientTagDeny = @["+typing"]
  var tags = initTable[string, string]()
  tags["+typing"] = "active"
  tags["+draft/reply"] = "abc123"
  tags["msgid"] = "def456"
  let filtered = isup.filterAllowedTags(tags)
  assert "+typing" notin filtered, "Should filter out denied tag"
  assert "+draft/reply" in filtered, "Should keep allowed client tag"
  assert "msgid" in filtered, "Should keep server tag"

  echo "PASS: CLIENTTAGDENY enforcement"

# ============================================================
# Test: ISUPPORT new params (ACCOUNTEXTBAN, MSGREFTYPES, ICON)
# ============================================================

block testIsupportNewParams:
  var isup = newISupport()

  # ACCOUNTEXTBAN
  isup.updateIsupport(@["nick", "ACCOUNTEXTBAN=a,R", "are supported"])
  assert isup.accountExtban == @["a", "R"], "Got: " & $isup.accountExtban

  # MSGREFTYPES
  isup.updateIsupport(@["nick", "MSGREFTYPES=msgid,timestamp", "are supported"])
  assert isup.msgRefTypes == @["msgid", "timestamp"], "Got: " & $isup.msgRefTypes

  # draft/ICON
  isup.updateIsupport(@["nick", "DRAFT/ICON=https://example.com/icon.png", "are supported"])
  assert isup.icon == "https://example.com/icon.png", "Got: " & isup.icon

  echo "PASS: ISUPPORT new params"

echo "All IRC protocol tests passed!"
