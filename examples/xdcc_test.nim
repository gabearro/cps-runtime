## XDCC Client Test
##
## Connects to IRC, joins a channel, and tests XDCC commands against bots.
##
## Usage:
##   nim c -r examples/xdcc_test.nim                          # observe bots
##   nim c -r examples/xdcc_test.nim BotName                  # XDCC LIST
##   nim c -r examples/xdcc_test.nim BotName 5                # XDCC SEND #5
##   nim c -r examples/xdcc_test.nim --server irc.rizon.net --channel "#nibl" BotName

import cps/runtime
import cps/transform
import cps/eventloop
import cps/concurrency/channels
import cps/irc/protocol
import cps/irc/client
import cps/irc/dcc
import cps/irc/xdcc
import std/[os, strutils, options]

proc main() =
  var server = "irc.rizon.net"
  var port = 6667
  var channel = "#nibl"
  var nick = "xdcctester"
  var targetBot = ""
  var targetPack = -1

  # Parse arguments
  var i = 1
  while i <= paramCount():
    let arg = paramStr(i)
    if arg == "--server" and i < paramCount():
      inc i; server = paramStr(i)
    elif arg == "--port" and i < paramCount():
      inc i; port = parseInt(paramStr(i))
    elif arg == "--channel" and i < paramCount():
      inc i; channel = paramStr(i)
    elif arg == "--nick" and i < paramCount():
      inc i; nick = paramStr(i)
    elif targetBot.len == 0:
      targetBot = arg
    elif targetPack < 0:
      targetPack = parseInt(arg)
    inc i

  echo "=== XDCC Client Test ==="
  echo "Server: ", server, ":", port
  echo "Channel: ", channel
  if targetBot.len > 0:
    echo "Target bot: ", targetBot
    if targetPack >= 0:
      echo "Target pack: #", targetPack
  echo ""

  if not dirExists("downloads"):
    createDir("downloads")

  var config = newIrcClientConfig(server, port, nick)
  config.autoJoinChannels = @[channel]
  config.autoReconnect = false
  config.ctcpVersion = "HexChat 2.16.1"

  let ircClient = newIrcClient(config)
  let xdcc = newXdccClient(ircClient, "downloads")
  xdcc.autoAccept = false

  if targetBot.len > 0:
    xdcc.trackBot(targetBot)

  proc handleEvents(cl: IrcClient, xc: XdccClient,
                    bot: string, pack: int): CpsVoidFuture {.cps.} =
    var joined = false
    var xdccSent = false
    while true:
      let evt: IrcEvent = await cl.events.recv()
      case evt.kind
      of iekConnected:
        echo "[+] Connected to IRC"

      of iekDisconnected:
        echo "[-] Disconnected: ", evt.reason

      of iekPing:
        discard

      of iekNumeric:
        let code = evt.numCode
        if code == RPL_WELCOME:
          echo "[+] Registered as: ", evt.numParams[0]
        elif code == RPL_ENDOFMOTD or code == ERR_NOMOTD:
          echo "[+] Ready"
        elif code == RPL_TOPIC:
          if evt.numParams.len >= 2:
            let topic = evt.numParams[^1]
            if topic.len > 150:
              echo "[#] Topic: ", topic[0..149], "..."
            else:
              echo "[#] Topic: ", topic
        else:
          discard

      of iekJoin:
        if evt.joinNick == cl.currentNick:
          echo "[+] Joined ", evt.joinChannel
          joined = true

          if bot.len > 0 and not xdccSent:
            xdccSent = true
            if pack >= 0:
              echo "[*] Sending: XDCC SEND #", pack, " to ", bot
              await xc.xdccSend(bot, pack)
            else:
              echo "[*] Sending: XDCC LIST to ", bot
              await xc.xdccList(bot)
          elif not xdccSent:
            xdccSent = true
            echo "[*] Watching channel for XDCC bot announcements..."
            echo "[*] Pass a bot name as argument to interact"

      of iekPrivMsg:
        let source = evt.pmSource
        let text = evt.pmText

        if isChannel(evt.pmTarget):
          # Channel messages — check for bot announcements
          let botInfo = parseXdccAnnouncement(source, text)
          if botInfo.isSome:
            let info = botInfo.get()
            echo "[BOT] ", info.nick, ": ", info.totalPacks, " packs, ",
                 info.slotsOpen, "/", info.slotsTotal, " slots"
          else:
            # Show abbreviated channel messages
            if text.len > 150:
              echo "[MSG ", source, " -> ", evt.pmTarget, "] ", text[0..149], "..."
            else:
              echo "[MSG ", source, " -> ", evt.pmTarget, "] ", text
        else:
          # Private message from bot
          echo "[PM ", source, "] ", text

          let xdccEvt = parseXdccNotice(source, text)
          if xdccEvt.isSome:
            let xe = xdccEvt.get()
            case xe.kind
            of xekTransferStarting:
              echo "  >> Transfer starting! Pack #", xe.tsPackNumber
            of xekQueued:
              echo "  >> Queued at position ", xe.qPosition
            of xekNoSuchPack:
              echo "  >> No such pack #", xe.nspPackNumber
            of xekDenied:
              echo "  >> Denied: ", xe.dReason
            of xekTransferComplete:
              echo "  >> Transfer complete!"
            of xekPackList:
              for p in xe.plPacks:
                echo "  >> Pack #", p.number, " [", p.filesize, "] ", p.filename
            else:
              discard

      of iekNotice:
        let source = evt.pmSource
        let text = evt.pmText

        # Try XDCC parse
        let xdccEvt = parseXdccNotice(source, text)
        if xdccEvt.isSome:
          let xe = xdccEvt.get()
          case xe.kind
          of xekPackList:
            for p in xe.plPacks:
              echo "[PACK ", source, "] #", p.number, " [", p.filesize, "] ", p.filename
          of xekTransferStarting:
            echo "[XDCC ", source, "] Sending pack #", xe.tsPackNumber,
                 " \"", xe.tsFilename, "\""
          of xekQueued:
            echo "[XDCC ", source, "] Queued position ", xe.qPosition,
                 " wait: ", xe.qEstimatedWait
          of xekDenied:
            echo "[XDCC ", source, "] Denied: ", xe.dReason
          of xekNoSuchPack:
            echo "[XDCC ", source, "] No such pack"
          of xekBotMessage:
            echo "[XDCC ", source, "] ", xe.bmText
          else:
            echo "[NOTICE ", source, "] ", text
        else:
          # Show raw notice (abbreviated)
          if text.len > 150:
            echo "[NOTICE ", source, "] ", text[0..149], "..."
          else:
            echo "[NOTICE ", source, "] ", text

      of iekCtcp:
        echo "[CTCP ", evt.ctcpSource, "] ", evt.ctcpCommand

      of iekDccSend:
        echo "[DCC SEND] ", evt.dccInfo.filename, " from ", evt.dccSource,
             " (", evt.dccInfo.filesize, " bytes)"
        echo "[*] Accepting DCC transfer..."
        let transfer = xc.dccManager.addOffer(evt.dccSource, evt.dccInfo)
        await receiveDcc(transfer)
        if transfer.state == dtsCompleted:
          echo "[+] Downloaded: ", transfer.outputPath,
               " (", transfer.bytesReceived, " bytes)"
        else:
          echo "[-] Download failed: ", transfer.error

      of iekError:
        echo "[!] Error: ", evt.errMsg

      else:
        discard

  let clientFut = ircClient.run()
  let handlerFut = handleEvents(ircClient, xdcc, targetBot, targetPack)

  let loop = getEventLoop()
  while not handlerFut.finished:
    loop.tick()
    if not loop.hasWork:
      break

  echo "Done."

main()
