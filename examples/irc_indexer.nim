## IRC Ebook Indexer Example
##
## Connects to irc.irchighway.net #ebooks, searches for books via the
## SearchOok bot, receives search results via DCC, and parses them.
##
## Protocol summary (as used by OpenBooks and other clients):
##   1. Join #ebooks, respond to CTCP VERSION with an approved client string
##   2. Send "@searchook <keywords>" to the channel
##   3. Bot sends NOTICE with "accepted" / "matches" / "Sorry" status
##   4. Bot DCC SENDs a zip file containing search results (.txt inside)
##   5. Each line in the results: "!botname Author - Title.epub ::INFO:: 1.2MB"
##   6. To download: send "!botname Author - Title.epub" to the channel
##
## Usage:
##   nim c -r examples/irc_indexer.nim
##   nim c -r examples/irc_indexer.nim "search terms here"

import cps/runtime
import cps/transform
import cps/eventloop
import cps/concurrency/channels
import cps/irc/protocol
import cps/irc/client
import cps/irc/dcc
import cps/irc/ebook_indexer
import std/[os, strutils]

# ============================================================
# Configuration
# ============================================================

const
  ircHost = "irc.irchighway.net"
  ircPort = 6667
  ircNick = "ebookindexer"
  ircChannel = "#ebooks"
  downloadDir = "downloads"

# ============================================================
# Main
# ============================================================

proc main() =
  # Default search query; override via command line
  var searchQuery = "tolkien"
  if paramCount() >= 1:
    searchQuery = commandLineParams().join(" ")

  echo "=== IRC Ebook Indexer ==="
  echo "Server: ", ircHost, ":", ircPort
  echo "Channel: ", ircChannel
  echo "Search: ", searchQuery
  echo ""

  # Create download directory
  if not dirExists(downloadDir):
    createDir(downloadDir)

  # Configure IRC
  var config = newIrcClientConfig(ircHost, ircPort, ircNick)
  config.autoJoinChannels = @[ircChannel]
  config.autoReconnect = false  # Don't reconnect for a one-shot search
  config.ctcpVersion = "HexChat 2.16.1"  # IRChighway requires an approved client

  let ircClient = newIrcClient(config)
  let dccMgr = newDccManager(downloadDir)

  # Event consumer
  proc handleEvents(cl: IrcClient, dm: DccManager,
                    query: string): CpsVoidFuture {.cps.} =
    var searchSent = false
    var searchAccepted = false
    var resultsReceived = false
    while true:
      let evt: IrcEvent = await cl.events.recv()
      case evt.kind
      of iekConnected:
        echo "[+] Connected to IRC"

      of iekDisconnected:
        echo "[-] Disconnected: ", evt.reason

      of iekPing:
        discard  # silent

      of iekNumeric:
        let code = evt.numCode
        if code == RPL_WELCOME:
          echo "[+] Registered as: ", evt.numParams[0]
        elif code == RPL_ENDOFMOTD or code == ERR_NOMOTD:
          echo "[+] Ready"
        elif code == RPL_TOPIC:
          if evt.numParams.len >= 2:
            echo "[#] Topic set"
        else:
          discard

      of iekJoin:
        # Wait for our own JOIN before sending search
        if evt.joinNick == cl.currentNick and evt.joinChannel == ircChannel:
          echo "[+] Joined ", ircChannel
          if not searchSent:
            searchSent = true
            # The search command format: @searchook <keywords>
            let searchCmd = "@searchook " & query
            echo "[*] Searching: ", searchCmd
            await cl.privMsg(ircChannel, searchCmd)

      of iekPrivMsg:
        echo "[MSG ", evt.pmSource, " -> ", evt.pmTarget, "] ", evt.pmText

      of iekNotice:
        let text = evt.pmText
        let source = evt.pmSource
        # SearchOok sends status notices
        if source.toLowerAscii().contains("search"):
          if text.toLowerAscii().contains("accepted"):
            searchAccepted = true
            echo "[+] Search accepted"
          elif text.toLowerAscii().contains("sorry"):
            echo "[-] No results found"
          elif text.toLowerAscii().contains("match"):
            echo "[+] ", text
          else:
            echo "[NOTICE ", source, "] ", text
        else:
          echo "[NOTICE ", source, "] ", text

      of iekCtcp:
        echo "[CTCP ", evt.ctcpSource, "] ", evt.ctcpCommand

      of iekDccSend:
        let filename = evt.dccInfo.filename
        echo "[DCC SEND] ", filename, " from ", evt.dccSource,
             " (", evt.dccInfo.filesize, " bytes)"

        let transfer = dm.addOffer(evt.dccSource, evt.dccInfo)
        echo "[*] Accepting DCC transfer..."
        await receiveDcc(transfer)

        if transfer.state == dtsCompleted:
          echo "[+] Downloaded: ", transfer.outputPath,
               " (", transfer.bytesReceived, " bytes)"

          # Search results come as .txt.zip files
          if isCatalogFile(filename):
            # Try to unzip and parse
            if filename.toLowerAscii().endsWith(".zip"):
              echo "[*] Extracting zip..."
              # Use system unzip to extract
              let extractDir = downloadDir / "extracted"
              if not dirExists(extractDir):
                createDir(extractDir)
              let rc = execShellCmd("unzip -o -q " &
                quoteShell(transfer.outputPath) & " -d " &
                quoteShell(extractDir))
              if rc == 0:
                # Find .txt files in the extracted dir
                for kind, path in walkDir(extractDir):
                  if kind == pcFile and path.toLowerAscii().endsWith(".txt"):
                    echo "[*] Parsing results: ", extractFilename(path)
                    let books = parseCatalogFile(path, evt.dccSource,
                                                  ircChannel, "!" & evt.dccSource)
                    echo "[+] Found ", books.len, " books:"
                    for i in 0 ..< min(20, books.len):
                      let b = books[i]
                      if b.triggerCommand.len > 0:
                        echo "  ", b.triggerCommand
                      else:
                        echo "  ", b.filename
                    if books.len > 20:
                      echo "  ... and ", books.len - 20, " more"
                    resultsReceived = true
              else:
                echo "[-] Failed to extract zip (rc=", rc, ")"
                # Try parsing the raw file as text
                let books = parseCatalogFile(transfer.outputPath, evt.dccSource,
                                              ircChannel, "!" & evt.dccSource)
                if books.len > 0:
                  echo "[+] Parsed ", books.len, " books from raw file"
                  resultsReceived = true
            else:
              # Plain text catalog
              let books = parseCatalogFile(transfer.outputPath, evt.dccSource,
                                            ircChannel, "!" & evt.dccSource)
              echo "[+] Parsed ", books.len, " books"
              for i in 0 ..< min(20, books.len):
                let b = books[i]
                echo "  ", b.triggerCommand, " ", b.filename
              if books.len > 20:
                echo "  ... and ", books.len - 20, " more"
              resultsReceived = true
          else:
            echo "[+] Book downloaded: ", filename
            resultsReceived = true

          # Disconnect after receiving results
          if resultsReceived:
            echo ""
            echo "[+] Done! Results saved in ", downloadDir, "/"
            await cl.quit("Got results, thanks!")

        else:
          echo "[-] Download failed: ", transfer.error

      of iekDccChat:
        echo "[DCC CHAT] from ", evt.dccSource

      of iekError:
        echo "[!] Error: ", evt.errMsg

      else:
        discard

  # Launch
  let clientFut = ircClient.run()
  let handlerFut = handleEvents(ircClient, dccMgr, searchQuery)

  let loop = getEventLoop()
  while not handlerFut.finished:
    loop.tick()
    if not loop.hasWork:
      break

  echo "Done."

main()
