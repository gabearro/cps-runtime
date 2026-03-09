## BitTorrent client barrel module.
##
## Import this to get the full client API:
##   import cps/bittorrent
##
## Provides: metainfo parsing, client orchestrator, peer protocol,
## piece management, storage, tracker communication, DHT, extensions.

import cps/bittorrent/utils
import cps/bittorrent/metainfo
import cps/bittorrent/client
import cps/bittorrent/pieces
import cps/bittorrent/storage
import cps/bittorrent/tracker
import cps/bittorrent/peer_protocol
import cps/bittorrent/bencode
import cps/bittorrent/peerid
import cps/bittorrent/dht
import cps/bittorrent/extensions
import cps/bittorrent/metadata
import cps/bittorrent/pex
import cps/bittorrent/lsd
import cps/bittorrent/mse
import cps/bittorrent/peer_priority

export utils, metainfo, client, pieces, storage, tracker, peer_protocol
export bencode, peerid, dht, extensions, metadata, pex, lsd
export mse, peer_priority
