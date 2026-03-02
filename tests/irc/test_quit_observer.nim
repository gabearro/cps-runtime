## Test: Observe another client's QUIT message
##
## Connects to IRC, joins a test channel, then watches for the QUIT message
## of a specific nick.
##
## Usage:
##   nim c -r tests/irc/test_quit_observer.nim [host] [port] [watch_nick]

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
  let useTls = port == 6697
  let watchNick = if args.len > 2: args[2] else: ""

  let nick = "obs" & $(epochTime().int mod 100000)

  stderr.write("=== QUIT OBSERVER ===\n")
  stderr.write("Connecting to " & host & ":" & $port & " as " & nick & "\n")
  if watchNick.len > 0:
    stderr.write("Watching for quit from: " & watchNick & "\n")

  var config = newIrcClientConfig(host, port, nick)
  config.useTls = useTls
  config.autoReconnect = false

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
      if evtOpt.isNone:
        break
      let evt = evtOpt.get()
      if evt.kind == iekConnected:
        registered = true
        stderr.write("Registered. Watching for QUIT events...\n")

  if not registered:
    stderr.write("ERROR: Failed to register\n")
    return

  # Monitor for 60 seconds
  for i in 0..599:
    await cpsSleep(100)
    while true:
      let evtOpt = client.events.tryRecv()
      if evtOpt.isNone:
        break
      let evt = evtOpt.get()
      if evt.kind == iekQuit:
        stderr.write("[QUIT] " & evt.quitNick & " quit: \"" & evt.quitMsg & "\"\n")
        if watchNick.len > 0 and evt.quitNick == watchNick:
          stderr.write("=== FOUND TARGET QUIT ===\n")
      elif evt.kind == iekMessage:
        let msg = evt.rawMessage
        if "QUIT" in msg.command or "ERROR" in msg.command:
          stderr.write("[RAW] " & msg.command & " " & msg.params.join(" ") & "\n")

  stderr.write("Observer timeout\n")
  await client.disconnect()

runCps(main())
