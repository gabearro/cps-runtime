## CPS IRC Bouncer - Barrel Module
##
## Provides persistent IRC presence via a background daemon.
## The bouncer maintains IRC connections, buffers messages, and
## replays them when clients reconnect via Unix socket.
##
## Usage:
##   import cps/bouncer
##
## For the daemon binary, see examples/bouncer/cps_bouncer.nim.
## For client integration, use discoverBouncer() to find the socket.

import cps/bouncer/types
import cps/bouncer/protocol
import cps/bouncer/buffer
import cps/bouncer/state
import cps/bouncer/server
import cps/bouncer/daemon
import cps/bouncer/bridge
import cps/bouncer/bouncerserv
import cps/bouncer/search

export types, protocol, buffer, state, server, daemon, bridge, bouncerserv, search
