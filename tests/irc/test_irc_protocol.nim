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

echo "All IRC protocol tests passed!"
