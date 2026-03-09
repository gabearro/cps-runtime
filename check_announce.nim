import cps/bittorrent/metainfo
import std/strformat, std/strutils

for path in ["/Users/gabriel/Downloads/linuxmint-22.3-cinnamon-64bit.iso.torrent",
             "/Users/gabriel/Downloads/ubuntu-24.04.4-desktop-amd64.iso.torrent",
             "/Users/gabriel/Downloads/archlinux-2026.03.01-x86_64.iso.torrent"]:
  echo "=== ", path.split("/")[^1], " ==="
  let m = parseTorrentFile(path)
  echo fmt"  announce: {m.announce}"
  echo fmt"  announceList tiers: {m.announceList.len}"
  for i, tier in m.announceList:
    echo fmt"    tier {i} ({tier.len} urls):"
    for url in tier:
      echo fmt"      {url}"

  # Simulate what the bridge does
  var trackerUrls: seq[string]
  if m.announce.len > 0:
    trackerUrls.add(m.announce)
  for tier in m.announceList:
    for url in tier:
      if url notin trackerUrls:
        trackerUrls.add(url)
  echo fmt"  deduped trackerUrls: {trackerUrls.len}"
  for url in trackerUrls:
    echo fmt"    {url}"
  echo ""
