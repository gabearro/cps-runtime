## CPS IRC Bouncer - BouncerServ
##
## Virtual IRC service bot for runtime management commands.
## Clients send PRIVMSG to "BouncerServ" and receive NOTICEs back.
##
## This module provides command parsing and help text generation.
## Actual command execution is handled by server.nim which has access
## to the full bouncer state and daemon helpers.

import std/[tables, strutils, sequtils]
import ./types

# ============================================================
# Command parsing
# ============================================================

type
  BouncerServCmd* = object
    command*: string         ## "network", "channel", "help", "search"
    subcommand*: string      ## "create", "update", "delete", "status", etc.
    args*: seq[string]       ## Positional args
    flags*: Table[string, string]  ## -flag value pairs

proc parseBouncerServCmd*(text: string): BouncerServCmd =
  ## Parse "network create -name libera -host irc.libera.chat ..."
  result.flags = initTable[string, string]()
  result.args = @[]
  let parts = text.strip().splitWhitespace()
  if parts.len == 0:
    result.command = "help"
    return

  result.command = parts[0].toLowerAscii()
  var idx = 1

  if parts.len > 1 and not parts[1].startsWith("-"):
    result.subcommand = parts[1].toLowerAscii()
    idx = 2

  # Parse remaining as positional args or -flag value pairs
  while idx < parts.len:
    if parts[idx].startsWith("-"):
      let flag = parts[idx][1 .. ^1]  # Strip leading -
      if idx + 1 < parts.len and not parts[idx + 1].startsWith("-"):
        result.flags[flag] = parts[idx + 1]
        idx += 2
      else:
        # Boolean flag (no value)
        result.flags[flag] = "true"
        idx += 1
    else:
      result.args.add(parts[idx])
      idx += 1

# ============================================================
# Help text
# ============================================================

proc helpLines*(topic: string): seq[string] =
  ## Return help text lines for a topic.
  case topic.toLowerAscii()
  of "network":
    result = @[
      "network create -name <name> -host <host> [-port <port>] [-nick <nick>]",
      "  [-username <user>] [-realname <real>] [-password <pass>]",
      "  [-tls] [-sasl-plain <user>:<pass>] [-join <#ch1,#ch2>]",
      "network update <name> [-host <host>] [-port <port>] [-nick <nick>] ...",
      "network delete <name>",
      "network status",
      "network connect <name>",
      "network disconnect <name>",
    ]
  of "channel":
    result = @[
      "channel status [network] [channel]",
      "channel update <network> <channel> [-detached] [-attached]",
      "  [-relay <message|highlight|none>]",
      "  [-reattach-on <message|highlight|none>]",
      "  [-detach-after <seconds>]",
      "  [-detach-on <message|highlight|none>]",
      "channel delete <network> <channel>",
    ]
  of "search":
    result = @[
      "search [-in <channel>] [-from <nick>] [-server <name>] [-limit <n>] <text>",
    ]
  else:
    result = @[
      "BouncerServ commands:",
      "  network create/update/delete/status/connect/disconnect",
      "  channel status/update/delete",
      "  search [-in <channel>] [-from <nick>] <text>",
      "  help [command]",
      "Send 'help <command>' for details.",
    ]

# ============================================================
# Config helpers (non-CPS)
# ============================================================

proc parseServerConfigFromFlags*(cmd: BouncerServCmd): BouncerServerConfig =
  ## Parse a BouncerServerConfig from command flags.
  result.name = cmd.flags.getOrDefault("name", "")
  result.host = cmd.flags.getOrDefault("host", "")
  result.port = parseInt(cmd.flags.getOrDefault("port", "6667"))
  result.nick = cmd.flags.getOrDefault("nick", "cpsbot")
  result.username = cmd.flags.getOrDefault("username", "cps")
  result.realname = cmd.flags.getOrDefault("realname", "CPS IRC Bouncer")
  result.password = cmd.flags.getOrDefault("password", "")
  result.useTls = "tls" in cmd.flags
  let saslPlain = cmd.flags.getOrDefault("sasl-plain", "")
  if saslPlain.len > 0 and ':' in saslPlain:
    let parts = saslPlain.split(":", 1)
    result.saslUsername = parts[0]
    result.saslPassword = parts[1]
  let joinStr = cmd.flags.getOrDefault("join", "")
  if joinStr.len > 0:
    result.autoJoinChannels = joinStr.split(",").mapIt(it.strip())
