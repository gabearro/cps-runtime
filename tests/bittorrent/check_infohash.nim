import cps/bittorrent/metainfo
import std/strutils

let torrentData = readFile("/Users/gabriel/Downloads/linuxmint-22.3-cinnamon-64bit.iso.torrent")
let meta = parseTorrent(torrentData)
echo "Info hash hex: ", meta.info.infoHashHex()
echo "Name: ", meta.info.name
echo "Piece count: ", meta.info.pieceCount
echo "Total length: ", meta.info.totalLength
echo "Announce: ", meta.announce
echo "Announce list: ", meta.announceList.len, " tiers"
for tier in meta.announceList:
  for url in tier:
    echo "  ", url
echo "URL list: ", meta.urlList.len
for url in meta.urlList:
  echo "  ", url
