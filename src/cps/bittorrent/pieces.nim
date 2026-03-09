## Piece manager for BitTorrent downloads.
##
## Manages piece state, block requests, verification, and rarest-first selection.

import std/[algorithm, tables, times]
import metainfo
import peer_protocol
import sha1

import utils

const
  BlockSize* = 16384  ## Standard block size (16 KiB)
  MaxBlockSize* = 32768  ## Maximum allowed block size

type
  PieceState* = enum
    psEmpty       ## No blocks downloaded
    psPartial     ## Some blocks downloaded
    psComplete    ## All blocks downloaded, not verified
    psVerified    ## SHA1 verified
    psFailed      ## SHA1 mismatch

  BlockState* = enum
    bsEmpty
    bsRequested
    bsReceived

  BlockInfo* = object
    offset*: int
    length*: int
    state*: BlockState

  PieceData* = object
    index*: int
    state*: PieceState
    blocks*: seq[BlockInfo]
    data*: string          ## Accumulated piece data
    totalLength*: int
    receivedBytes*: int
    lastBlockTime*: float  ## Last time a new block was received for this piece

  BlockKey* = tuple[pieceIdx: int, offset: int]

  BlockRaceInfo* = object
    requesters*: seq[string]   ## Peer keys that have requested this block
    firstRequestTime*: float   ## When the first request was sent

  BlockRaceTracker* = object
    raced*: Table[BlockKey, BlockRaceInfo]
    maxRacers*: int            ## Max concurrent requesters per block

  PieceManager* = ref object
    info*: TorrentInfo
    pieces*: seq[PieceData]
    completedCount*: int
    verifiedCount*: int
    totalPieces*: int
    downloaded*: int64
    uploaded*: int64
    raceTracker*: BlockRaceTracker

proc newPieceManager*(info: TorrentInfo, maxRacers: int = 3): PieceManager =
  let numPieces = info.pieceCount
  result = PieceManager(
    info: info,
    pieces: newSeq[PieceData](numPieces),
    totalPieces: numPieces,
    raceTracker: BlockRaceTracker(
      raced: initTable[BlockKey, BlockRaceInfo](),
      maxRacers: maxRacers
    )
  )

  for i in 0 ..< numPieces:
    let pieceLen = info.pieceSize(i)
    var blocks: seq[BlockInfo]
    var offset = 0
    while offset < pieceLen:
      let blockLen = min(BlockSize, pieceLen - offset)
      blocks.add(BlockInfo(offset: offset, length: blockLen, state: bsEmpty))
      offset += blockLen

    result.pieces[i] = PieceData(
      index: i,
      state: psEmpty,
      blocks: blocks,
      data: "",  # Lazy allocation: buffer created on first block receipt
      totalLength: pieceLen,
      receivedBytes: 0
    )

proc isComplete*(pm: PieceManager): bool =
  pm.verifiedCount == pm.totalPieces

proc progress*(pm: PieceManager): float =
  if pm.totalPieces == 0: 1.0
  else: pm.verifiedCount.float / pm.totalPieces.float

proc bytesRemaining*(pm: PieceManager): int64 =
  pm.info.totalLength - pm.downloaded

proc receiveBlock*(pm: PieceManager, pieceIdx: int, offset: int, data: string): bool =
  ## Store a received block. Returns true if the piece is now complete.
  if pieceIdx < 0 or pieceIdx >= pm.totalPieces:
    return false

  var piece = addr pm.pieces[pieceIdx]
  if piece.state in {psVerified, psFailed}:
    return false

  # Find matching block
  for blk in piece.blocks.mitems:
    if blk.offset == offset and blk.length == data.len:
      if blk.state == bsReceived:
        return false  # Duplicate
      blk.state = bsReceived
      piece.lastBlockTime = epochTime()
      # Lazy allocation: create buffer on first block receipt
      if piece.data.len == 0:
        piece.data = newString(piece.totalLength)
      # Copy data into piece buffer
      copyMem(addr piece.data[offset], unsafeAddr data[0], data.len)
      piece.receivedBytes += data.len
      pm.downloaded += data.len

      # Check if all blocks received
      var allReceived = true
      for b in piece.blocks:
        if b.state != bsReceived:
          allReceived = false
          break

      if allReceived:
        piece.state = psComplete
        pm.completedCount += 1
        return true
      else:
        piece.state = psPartial
      return false

  return false

proc applyVerification*(pm: PieceManager, pieceIdx: int, hashMatch: bool) =
  ## Apply the result of a SHA1 hash check to piece state.
  ## Called after computing SHA1 (possibly on a blocking thread).
  var piece = addr pm.pieces[pieceIdx]
  if hashMatch:
    piece.state = psVerified
    pm.verifiedCount += 1
  else:
    piece.state = psFailed
    # Reset all blocks for re-download
    var bi = 0
    while bi < piece.blocks.len:
      piece.blocks[bi].state = bsEmpty
      bi += 1
    # Correct download accounting before zeroing receivedBytes
    pm.downloaded -= int64(piece.receivedBytes)
    piece.receivedBytes = 0
    pm.completedCount -= 1
    # Deallocate failed piece buffer — will be re-allocated on next block receipt
    piece.data = ""

proc verifyPiece*(pm: PieceManager, pieceIdx: int): bool =
  ## Verify SHA1 hash of a completed piece. Returns true if valid.
  if pieceIdx < 0 or pieceIdx >= pm.totalPieces:
    return false

  var piece = addr pm.pieces[pieceIdx]
  if piece.state != psComplete:
    return false

  let expected = pm.info.pieceHash(pieceIdx)
  let actual = sha1(piece.data[0 ..< piece.totalLength])
  let hashMatch = actual == expected
  pm.applyVerification(pieceIdx, hashMatch)
  result = hashMatch

proc resetPiece*(pm: PieceManager, pieceIdx: int) =
  ## Reset a piece for re-download (e.g., after verification failure).
  var piece = addr pm.pieces[pieceIdx]
  # Correct download accounting: subtract bytes that were received for this piece
  pm.downloaded -= int64(piece.receivedBytes)
  if piece.state == psVerified:
    pm.verifiedCount -= 1
  if piece.state in {psComplete, psVerified}:
    pm.completedCount -= 1
  piece.state = psEmpty
  piece.receivedBytes = 0
  piece.data = ""  # Deallocate buffer — will be re-allocated on next block receipt
  for blk in piece.blocks.mitems:
    blk.state = bsEmpty

proc getNeededBlocks*(pm: PieceManager, pieceIdx: int, maxBlocks: int = 5): seq[tuple[offset: int, length: int]] =
  ## Get unrequested blocks for a piece.
  if pieceIdx < 0 or pieceIdx >= pm.totalPieces:
    return @[]

  let piece = pm.pieces[pieceIdx]
  if piece.state in {psVerified, psComplete}:
    return @[]

  for blk in piece.blocks:
    if blk.state == bsEmpty:
      result.add((blk.offset, blk.length))
      if result.len >= maxBlocks:
        break

proc markBlockRequested*(pm: PieceManager, pieceIdx: int, offset: int) =
  ## Mark a block as requested (in-flight).
  if pieceIdx < 0 or pieceIdx >= pm.totalPieces:
    return
  for blk in pm.pieces[pieceIdx].blocks.mitems:
    if blk.offset == offset:
      blk.state = bsRequested
      break

proc cancelBlockRequest*(pm: PieceManager, pieceIdx: int, offset: int) =
  ## Cancel a block request (mark as empty again).
  ## If other peers are still racing this block, keep it as bsRequested.
  if pieceIdx < 0 or pieceIdx >= pm.totalPieces:
    return
  let key: BlockKey = (pieceIdx, offset)
  if key in pm.raceTracker.raced:
    if pm.raceTracker.raced[key].requesters.len > 0:
      return  # Other racers still have this block in-flight
  for blk in pm.pieces[pieceIdx].blocks.mitems:
    if blk.offset == offset and blk.state == bsRequested:
      blk.state = bsEmpty
      break

proc cancelPeerRequests*(pm: PieceManager, requests: seq[tuple[pieceIdx: int, offset: int]]) =
  ## Cancel all block requests from a disconnected/choked peer.
  for req in requests:
    pm.cancelBlockRequest(req.pieceIdx, req.offset)

proc hasEmptyBlocks(piece: PieceData): bool =
  ## Check if a piece has any blocks that haven't been requested yet.
  for blk in piece.blocks:
    if blk.state == bsEmpty:
      return true
  return false

proc selectPiece*(pm: PieceManager, peerBitfield: seq[byte],
                  availability: seq[int],
                  exclude: seq[int] = @[]): int =
  ## Select the rarest piece that the peer has and we need.
  ## Among equally-rare pieces, pick randomly to avoid sequential behavior.
  ## Always prefers partially downloaded pieces first.
  ## Pieces in `exclude` are skipped (used when a piece has no empty blocks left).
  ## Returns -1 if no suitable piece found.
  type PieceCandidate = tuple[index: int, rarity: int]
  var candidates: seq[PieceCandidate]

  for i in 0 ..< pm.totalPieces:
    if pm.pieces[i].state in {psVerified, psComplete}:
      continue
    if not pm.pieces[i].hasEmptyBlocks:
      continue  # All blocks already requested or received
    if not hasPiece(peerBitfield, i):
      continue
    if i in exclude:
      continue
    let rarity = if i < availability.len: availability[i] else: 0
    candidates.add((i, rarity))

  if candidates.len == 0:
    return -1

  # Sort by rarity (ascending) - rarest first
  candidates.sort(proc(a, b: PieceCandidate): int = cmp(a.rarity, b.rarity))

  # Always prefer completing a partial piece first (finish what we started).
  # Pick the partial piece closest to completion so all peers collaborate
  # on finishing the same piece rather than scattering across many partials.
  var bestPartial = -1
  var bestReceived = -1
  for c in candidates:
    if pm.pieces[c.index].state == psPartial:
      let received = pm.pieces[c.index].receivedBytes
      if received > bestReceived:
        bestReceived = received
        bestPartial = c.index
  if bestPartial >= 0:
    return bestPartial

  # No partial pieces — pick randomly among the rarest tier.
  let minRarity = candidates[0].rarity
  var rarestCount = 0
  for c in candidates:
    if c.rarity == minRarity:
      inc rarestCount
    else:
      break
  return candidates[btRand(rarestCount)].index

proc selectPieceSimple*(pm: PieceManager, peerBitfield: seq[byte]): int =
  ## Simple sequential piece selection (no rarity tracking).
  ## Prefers partially downloaded pieces.

  # First: finish partial pieces
  for i in 0 ..< pm.totalPieces:
    if pm.pieces[i].state == psPartial and hasPiece(peerBitfield, i):
      return i

  # Then: start new pieces sequentially
  for i in 0 ..< pm.totalPieces:
    if pm.pieces[i].state == psEmpty and hasPiece(peerBitfield, i):
      return i

  return -1

proc piecesRemaining*(pm: PieceManager): int =
  ## Number of pieces not yet verified.
  pm.totalPieces - pm.verifiedCount

proc isStuckPartial*(piece: PieceData, timeoutSec: float): bool =
  ## Returns true if a partial piece hasn't received a new block within
  ## timeoutSec. The piece must have at least one received block and at
  ## least one outstanding (requested) block.
  if piece.state != psPartial:
    return false
  if piece.lastBlockTime <= 0.0:
    return false
  if (epochTime() - piece.lastBlockTime) < timeoutSec:
    return false
  # Must have at least one bsRequested block to steal
  for blk in piece.blocks:
    if blk.state == bsRequested:
      return true
  return false

proc inEndgame*(pm: PieceManager): bool =
  ## Returns true when we're in endgame mode (few pieces left, all requested).
  ## Endgame: every remaining block has been requested at least once.
  if pm.piecesRemaining > 20:
    return false
  for i in 0 ..< pm.totalPieces:
    let piece = pm.pieces[i]
    if piece.state in {psVerified, psComplete}:
      continue
    for blk in piece.blocks:
      if blk.state == bsEmpty:
        return false  # Still an unrequested block
  return true

proc getEndgameBlocks*(pm: PieceManager, peerBitfield: seq[byte],
                       maxBlocks: int = 5): seq[tuple[pieceIdx: int, offset: int, length: int]] =
  ## In endgame mode, return blocks that are requested but not yet received.
  ## These will be sent as duplicate requests to speed up the final pieces.
  ## Respects maxRacers limit to avoid excessive duplicate traffic.
  for i in 0 ..< pm.totalPieces:
    if result.len >= maxBlocks:
      return
    let piece = pm.pieces[i]
    if piece.state in {psVerified, psComplete}:
      continue
    if not hasPiece(peerBitfield, i):
      continue
    for blk in piece.blocks:
      if blk.state == bsRequested:
        let key: BlockKey = (i, blk.offset)
        if key in pm.raceTracker.raced:
          if pm.raceTracker.raced[key].requesters.len >= pm.raceTracker.maxRacers:
            continue
        result.add((i, blk.offset, blk.length))
        if result.len >= maxBlocks:
          return

proc getPieceData*(pm: PieceManager, pieceIdx: int): string =
  ## Get the data for a verified piece and release the buffer.
  ## After this call, the piece buffer is deallocated (uploads read from disk).
  if pieceIdx >= 0 and pieceIdx < pm.totalPieces and
     pm.pieces[pieceIdx].state == psVerified:
    result = move(pm.pieces[pieceIdx].data)
    pm.pieces[pieceIdx].data = ""
  else:
    return ""

proc generateBitfield*(pm: PieceManager): seq[byte] =
  ## Generate our bitfield for sending to peers.
  result = newBitfield(pm.totalPieces)
  for i in 0 ..< pm.totalPieces:
    if pm.pieces[i].state == psVerified:
      setPiece(result, i)

# ============================================================
# Block Racing
# ============================================================

proc registerRacer*(pm: PieceManager, pieceIdx: int, offset: int, peerKey: string) =
  ## Record that peerKey has requested this block. Creates a race entry if needed.
  let key: BlockKey = (pieceIdx, offset)
  if key in pm.raceTracker.raced:
    var info = addr pm.raceTracker.raced[key]
    # Don't add duplicate entries for the same peer
    var found = false
    for r in info.requesters:
      if r == peerKey:
        found = true
        break
    if not found:
      info.requesters.add(peerKey)
  else:
    pm.raceTracker.raced[key] = BlockRaceInfo(
      requesters: @[peerKey],
      firstRequestTime: epochTime()
    )

proc unregisterRacer*(pm: PieceManager, pieceIdx: int, offset: int, peerKey: string) =
  ## Remove peerKey from the racers of this block.
  let key: BlockKey = (pieceIdx, offset)
  if key in pm.raceTracker.raced:
    var info = addr pm.raceTracker.raced[key]
    var i = 0
    while i < info.requesters.len:
      if info.requesters[i] == peerKey:
        info.requesters.del(i)
        break
      i += 1
    if info.requesters.len == 0:
      pm.raceTracker.raced.del(key)

proc getRacingPeers*(pm: PieceManager, pieceIdx: int, offset: int): seq[string] =
  ## Get all peer keys that have requested this block.
  let key: BlockKey = (pieceIdx, offset)
  if key in pm.raceTracker.raced:
    return pm.raceTracker.raced[key].requesters
  return @[]

proc clearRaceEntry*(pm: PieceManager, pieceIdx: int, offset: int) =
  ## Remove the race tracking entry for a block (after block received).
  let key: BlockKey = (pieceIdx, offset)
  pm.raceTracker.raced.del(key)

proc blockLength*(pm: PieceManager, pieceIdx: int, offset: int): int =
  ## Look up block length from piece index and offset.
  if pieceIdx < 0 or pieceIdx >= pm.totalPieces:
    return 0
  for blk in pm.pieces[pieceIdx].blocks:
    if blk.offset == offset:
      return blk.length
  return 0

proc getRaceableBlocks*(pm: PieceManager, pieceIdx: int, peerKey: string,
                        peerBitfield: seq[byte],
                        maxBlocks: int = 5): seq[tuple[offset: int, length: int]] =
  ## Get blocks from a piece that are bsRequested and eligible for racing.
  ## Filters: block not already requested by this peer, race count < maxRacers,
  ## peer has this piece, block not already bsReceived.
  if pieceIdx < 0 or pieceIdx >= pm.totalPieces:
    return @[]
  if not hasPiece(peerBitfield, pieceIdx):
    return @[]
  let piece = pm.pieces[pieceIdx]
  if piece.state in {psVerified, psComplete}:
    return @[]
  for blk in piece.blocks:
    if blk.state != bsRequested:
      continue
    let key: BlockKey = (pieceIdx, blk.offset)
    if key in pm.raceTracker.raced:
      let info = pm.raceTracker.raced[key]
      # Already at max racers
      if info.requesters.len >= pm.raceTracker.maxRacers:
        continue
      # This peer already has this block
      var alreadyRacing = false
      for r in info.requesters:
        if r == peerKey:
          alreadyRacing = true
          break
      if alreadyRacing:
        continue
    result.add((blk.offset, blk.length))
    if result.len >= maxBlocks:
      return

proc clearPieceRaceEntries*(pm: PieceManager, pieceIdx: int) =
  ## Remove all race tracking entries for a piece (after verification).
  if pieceIdx < 0 or pieceIdx >= pm.totalPieces:
    return
  for blk in pm.pieces[pieceIdx].blocks:
    let key: BlockKey = (pieceIdx, blk.offset)
    pm.raceTracker.raced.del(key)
