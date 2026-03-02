## Test: Two-client QUIT message verification
##
## Creates two IRC clients (quitter + observer). Both join the same channel.
## The quitter disconnects with a custom QUIT message. The observer watches
## for the iekQuit event and verifies the quit reason matches.
##
## Usage:
##   nim c -r tests/irc/test_quit_two_clients.nim [host] [port]

import std/[os, strutils, times, options]
import cps/runtime
import cps/transform
import cps/eventloop
import cps/irc/protocol
import cps/irc/client
import cps/concurrency/channels

proc main(): CpsVoidFuture {.cps.} =
  let args = commandLineParams()
  let host = if args.len > 0: args[0] else: "irc.libera.chat"
  let port = if args.len > 1: parseInt(args[1]) else: 6697
  let useTls = port == 6697 or port == 6679

  let suffix = $(epochTime().int mod 100000)
  let quitterNick = "tq" & suffix
  let observerNick = "to" & suffix
  let testChannel = "#cpsqt" & suffix

  let quitMessage = "Custom quit msg 42"

  stderr.write("=== TWO-CLIENT QUIT TEST ===\n")
  stderr.write("Host: " & host & ":" & $port & " (TLS=" & $useTls & ")\n")
  stderr.write("Quitter: " & quitterNick & "\n")
  stderr.write("Observer: " & observerNick & "\n")
  stderr.write("Channel: " & testChannel & "\n")
  stderr.write("Expected quit message: \"" & quitMessage & "\"\n\n")

  # --- Create quitter ---
  var qConfig = newIrcClientConfig(host, port, quitterNick)
  qConfig.useTls = useTls
  qConfig.autoReconnect = false
  qConfig.quitMessage = quitMessage

  let quitter = newIrcClient(qConfig)
  let quitterFut = quitter.run()

  # Stagger connections to avoid rate limiting
  stderr.write("Waiting for quitter to register...\n")

  # Wait for quitter to register first
  var qRegistered = false
  var attempts = 0
  while not qRegistered and attempts < 150:
    await cpsSleep(100)
    attempts += 1
    while true:
      let evtOpt = quitter.events.tryRecv()
      if evtOpt.isNone: break
      let evt = evtOpt.get()
      if evt.kind == iekConnected:
        qRegistered = true
        stderr.write("[quitter] Registered\n")
      elif evt.kind == iekError:
        stderr.write("[quitter] Error: " & evt.errMsg & "\n")
      elif evt.kind == iekDisconnected:
        stderr.write("[quitter] Disconnected: " & evt.reason & "\n")
      elif evt.kind == iekMessage:
        discard  # Skip server messages during registration

  if not qRegistered:
    stderr.write("ERROR: Quitter failed to register\n")
    return

  stderr.write("Staggering 5s before observer connect...\n")
  await cpsSleep(5000)

  # --- Create observer ---
  var oConfig = newIrcClientConfig(host, port, observerNick)
  oConfig.useTls = useTls
  oConfig.autoReconnect = false

  let observer = newIrcClient(oConfig)
  let observerFut = observer.run()

  # --- Wait for observer to register ---
  var oRegistered = false
  attempts = 0
  while not oRegistered and attempts < 150:
    await cpsSleep(100)
    attempts += 1

    # Drain quitter events (keep draining to avoid buffer backup)
    while true:
      let evtOpt = quitter.events.tryRecv()
      if evtOpt.isNone: break

    while true:
      let evtOpt = observer.events.tryRecv()
      if evtOpt.isNone: break
      let evt = evtOpt.get()
      if evt.kind == iekConnected:
        oRegistered = true
        stderr.write("[observer] Registered\n")
      elif evt.kind == iekError:
        stderr.write("[observer] Error: " & evt.errMsg & "\n")
      elif evt.kind == iekDisconnected:
        stderr.write("[observer] Disconnected: " & evt.reason & "\n")

  if not oRegistered:
    stderr.write("ERROR: Observer failed to register\n")
    return

  # --- Both join the test channel ---
  stderr.write("\n=== Joining " & testChannel & " ===\n")
  await quitter.joinChannel(testChannel)
  await observer.joinChannel(testChannel)

  # Wait for both to confirm join
  var qJoined = false
  var oJoined = false
  attempts = 0
  while (not qJoined or not oJoined) and attempts < 100:
    await cpsSleep(100)
    attempts += 1

    while true:
      let evtOpt = quitter.events.tryRecv()
      if evtOpt.isNone: break
      let evt = evtOpt.get()
      if evt.kind == iekJoin and evt.joinNick == quitterNick:
        qJoined = true
        stderr.write("[quitter] Joined " & testChannel & "\n")

    while true:
      let evtOpt = observer.events.tryRecv()
      if evtOpt.isNone: break
      let evt = evtOpt.get()
      if evt.kind == iekJoin and evt.joinNick == observerNick:
        oJoined = true
        stderr.write("[observer] Joined " & testChannel & "\n")

  if not qJoined or not oJoined:
    stderr.write("ERROR: Failed to join channel\n")
    await quitter.disconnect()
    await observer.disconnect()
    return

  # Small delay for server to settle
  await cpsSleep(1000)

  # --- Quitter disconnects ---
  stderr.write("\n=== Quitter disconnecting (quit msg: \"" & quitMessage & "\") ===\n")
  await quitter.disconnect()
  stderr.write("[quitter] disconnect() returned\n")

  # --- Observer watches for quit event ---
  var sawQuit = false
  var observedReason = ""
  var observedNick = ""

  # Watch for up to 10 seconds, log ALL events
  for i in 0..99:
    await cpsSleep(100)
    while true:
      let evtOpt = observer.events.tryRecv()
      if evtOpt.isNone: break
      let evt = evtOpt.get()
      case evt.kind
      of iekQuit:
        stderr.write("[observer] QUIT: nick=" & evt.quitNick & " reason=\"" & evt.quitReason & "\"\n")
        if evt.quitNick == quitterNick:
          sawQuit = true
          observedReason = evt.quitReason
          observedNick = evt.quitNick
      of iekMessage:
        stderr.write("[observer] MSG: " & evt.msg.command & " " & evt.msg.params.join(" ") & "\n")
      of iekDisconnected:
        stderr.write("[observer] DISCONNECTED: " & evt.reason & "\n")
      of iekError:
        stderr.write("[observer] ERROR: " & evt.errMsg & "\n")
      of iekPart:
        stderr.write("[observer] PART: " & evt.partNick & " from " & evt.partChannel & "\n")
      else:
        discard
    if sawQuit:
      stderr.write("[observer] Found target quit, stopping watch\n")
      break

  # --- Report results ---
  stderr.write("\n=== RESULTS ===\n")
  if sawQuit:
    stderr.write("Observed QUIT from " & observedNick & "\n")
    stderr.write("Quit reason: \"" & observedReason & "\"\n")
    # Libera.Chat prefixes with "Quit: " for custom messages
    if quitMessage in observedReason:
      stderr.write("PASS: Quit message delivered correctly!\n")
    elif observedReason == "Client Quit":
      stderr.write("NOTE: Server replaced quit message with 'Client Quit'\n")
      stderr.write("  This may be an anti-spam measure for new connections.\n")
    else:
      stderr.write("FAIL: Unexpected quit reason\n")
  else:
    stderr.write("FAIL: Did not observe QUIT event from " & quitterNick & "\n")

  # --- Cleanup ---
  await observer.disconnect()
  stderr.write("=== DONE ===\n")

runCps(main())
