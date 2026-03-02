## CPS IRC Bouncer - Standalone Binary
##
## Usage:
##   cps_bouncer                          # Use default config path
##   cps_bouncer ~/.config/cps-bouncer/config.json
##   cps_bouncer --init                   # Create default config template
##
## The bouncer listens on a Unix socket for client connections and
## maintains persistent IRC connections with message buffering.
##
## Compile:
##   nim c -r examples/bouncer/cps_bouncer.nim

import std/os
import cps/eventloop
import cps/bouncer/daemon

proc main() =
  let defaultConfigPath = getHomeDir() & ".config/cps-bouncer/config.json"
  var configPath = defaultConfigPath

  # Parse command line
  let params = commandLineParams()
  if params.len > 0:
    if params[0] == "--init":
      saveDefaultConfig(defaultConfigPath)
      echo "Default config written to: ", defaultConfigPath
      echo "Edit the config and restart the bouncer."
      return
    elif params[0] == "--help" or params[0] == "-h":
      echo "CPS IRC Bouncer"
      echo ""
      echo "Usage:"
      echo "  cps_bouncer                     # Use default config"
      echo "  cps_bouncer <config.json>       # Use custom config"
      echo "  cps_bouncer --init              # Create default config"
      echo ""
      echo "Config: ", defaultConfigPath
      echo "Socket: ~/.config/cps-bouncer/bouncer.sock"
      echo "Logs:   ~/.config/cps-bouncer/logs/"
      return
    else:
      configPath = params[0]

  # Check config exists
  if not fileExists(configPath):
    echo "Config not found: ", configPath
    echo "Run with --init to create a default config."
    quit(1)

  # Run the bouncer
  let fut = startBouncer(configPath)
  runCps(fut)

main()
