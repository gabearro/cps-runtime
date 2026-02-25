## CPS IRC Client
##
## Barrel module for the IRC client library.
##
## Provides:
## - IRC protocol parsing/formatting
## - Event-driven IRC client with proxy support
## - DCC file transfer (direct and proxied)
## - XDCC pack-based file transfer support
## - Ebook indexer for IRC book channels

import cps/irc/protocol
import cps/irc/client
import cps/irc/dcc
import cps/irc/xdcc
import cps/irc/ebook_indexer

export protocol
export client
export dcc
export xdcc
export ebook_indexer
