## Test: Verify IRC QUIT message is sent and received by server
##
## Connects, joins a channel, then quits with a custom message.
## Monitors all events including post-QUIT server responses.
##
## Usage:
##   nim c -r tests/irc/test_quit_message.nim [host] [port] [nick]

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

  let nick = if args.len > 2: args[2]
             else: "tquit" & $(epochTime().int mod 100000)

  stderr.write("=== QUIT MESSAGE TEST ===\n")
  stderr.write("Connecting to " & host & ":" & $port & " (TLS=" & $useTls & ") as " & nick & "\n")

  var config = newIrcClientConfig(host, port, nick)
  config.useTls = useTls
  config.autoReconnect = false
  config.quitMessage = "Test quit 12345"

  let client = newIrcClient(config)
  let clientFut = client.run()

  # Wait for registration
  var registered = false
  var attempts = 0
  while not registered and attempts < 100:
    await cpsSleep(100)
    attempts += 1
    while true:
      let evtOpt = client.events.tryRecv()
      if evtOpt.isNone: break
      let evt = evtOpt.get()
      if evt.kind == iekConnected:
        registered = true
        stderr.write("Registered as " & nick & "\n")
      elif evt.kind == iekError:
        stderr.write("Error: " & evt.errMsg & "\n")

  if not registered:
    stderr.write("ERROR: Failed to register\n")
    return

  stderr.write("\n=== DISCONNECT (quit msg: " & config.quitMessage & ") ===\n")
  await client.disconnect()
  stderr.write("=== disconnect() returned ===\n")

  # Now drain events for 3 seconds to see what run()/readLoop produced
  stderr.write("Draining events for 3 seconds...\n")
  for i in 0..29:
    await cpsSleep(100)
    while true:
      let evtOpt = client.events.tryRecv()
      if evtOpt.isNone: break
      let evt = evtOpt.get()
      case evt.kind
      of iekDisconnected:
        stderr.write("  [event] Disconnected: " & evt.reason & "\n")
      of iekError:
        stderr.write("  [event] Error: " & evt.errMsg & "\n")
      of iekMessage:
        stderr.write("  [event] Raw: " & evt.msg.command & " " & evt.msg.params.join(" ") & "\n")
      else:
        stderr.write("  [event] " & $evt.kind & "\n")

  stderr.write("=== DONE ===\n")

runCps(main())
