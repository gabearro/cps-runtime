## Piece manager for BitTorrent downloads.
##
## Manages piece state, block requests, verification, and rarest-first selection.

import std/[algorithm, sets, tables, times]
import metainfo
import peer_protocol
import sha1

import utils

const
  BlockSize* = 16384  ## Standard block size (16 KiB)
  MaxBlockSize* = 32768  ## Maximum allowed block size

proc blockIndex*(offset: int): int {.inline.} =
  ## Compute block index from byte offset. O(1) since blocks are fixed-size.
  offset div BlockSize

type
  PieceState* = enum
    psEmpty       ## No blocks downloaded
    psPartial     ## Some blocks downloaded
    psComplete    ## All blocks downloaded, not verified
    psOptimistic  ## Consensus-verified by peer agreement, pending background SHA1
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

  BlockAgreement* = object
    crc*: uint32           ## CRC32C of the accepted block data
    agreeCount*: int       ## Number of additional peers whose data matched

  PieceConsensus* = object
    blockAgreements*: seq[BlockAgreement]  ## One per block in the piece
    agreedBlockCount*: int                 ## Blocks with agreeCount >= 1

  PieceData* = object
    index*: int
    state*: PieceState
    blocks*: seq[BlockInfo]
    data*: string          ## Accumulated piece data
    totalLength*: int
    receivedBytes*: int
    lastBlockTime*: float  ## Last time a new block was received for this piece
    consensus*: PieceConsensus  ## Per-block agreement from racing peers

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
    completedCount*: int       ## Pieces in psComplete + psOptimistic + psVerified
    verifiedCount*: int        ## Pieces in psVerified
    optimisticCount*: int      ## Pieces in psOptimistic
    totalPieces*: int
    downloaded*: int64
    uploaded*: int64
    raceTracker*: BlockRaceTracker
    trackAgreement*: bool      ## Gate CRC32C tracking (only when optimistic verification enabled)

const CompletedStates* = {psComplete, psOptimistic, psVerified}

template validPieceIdx(pm: PieceManager, idx: int): bool =
  idx >= 0 and idx < pm.totalPieces

proc newPieceManager*(info: TorrentInfo, maxRacers: int = 3,
                      trackAgreement: bool = false): PieceManager =
  let numPieces = info.pieceCount
  result = PieceManager(
    info: info,
    pieces: newSeq[PieceData](numPieces),
    totalPieces: numPieces,
    raceTracker: BlockRaceTracker(
      raced: initTable[BlockKey, BlockRaceInfo](),
      maxRacers: maxRacers
    ),
    trackAgreement: trackAgreement
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
  pm.verifiedCount + pm.optimisticCount == pm.totalPieces

proc progress*(pm: PieceManager): float =
  if pm.totalPieces == 0: 1.0
  else: (pm.verifiedCount + pm.optimisticCount).float / pm.totalPieces.float

proc bytesRemaining*(pm: PieceManager): int64 =
  pm.info.totalLength - pm.downloaded

proc initConsensus*(piece: var PieceData) =
  ## Initialize per-block agreement tracking. Called on first block receipt.
  piece.consensus = PieceConsensus(
    blockAgreements: newSeq[BlockAgreement](piece.blocks.len),
    agreedBlockCount: 0
  )

proc recordBlockCrc*(piece: var PieceData, blockIdx: int, data: openArray[byte]) =
  ## Record the CRC32C of an accepted block for later agreement comparison.
  if blockIdx >= 0 and blockIdx < piece.consensus.blockAgreements.len:
    piece.consensus.blockAgreements[blockIdx].crc = crc32c(data)

proc blockNeedsAgreement*(piece: PieceData, bi: int): bool {.inline.} =
  ## True if a received block has a CRC recorded but no peer agreement yet.
  bi >= 0 and bi < piece.consensus.blockAgreements.len and
    piece.consensus.blockAgreements[bi].crc != 0 and
    piece.consensus.blockAgreements[bi].agreeCount == 0

proc isBlockEligibleForRacing*(pm: PieceManager, pieceIdx: int, offset: int,
                                peerKey: string): bool =
  ## True if the block can accept another racing requester from peerKey.
  let key: BlockKey = (pieceIdx, offset)
  pm.raceTracker.raced.withValue(key, info):
    if info.requesters.len >= pm.raceTracker.maxRacers:
      return false
    for r in info.requesters:
      if r == peerKey:
        return false
  return true

proc receiveBlock*(pm: PieceManager, pieceIdx: int, offset: int, data: string): bool =
  ## Store a received block. Returns true if the piece is now complete.
  if not pm.validPieceIdx(pieceIdx):
    return false

  var piece = addr pm.pieces[pieceIdx]
  if piece.state in {psOptimistic, psVerified, psFailed}:
    return false

  # O(1) block lookup via computed index
  let bi = blockIndex(offset)
  if bi < 0 or bi >= piece.blocks.len:
    return false
  if piece.blocks[bi].offset != offset or piece.blocks[bi].length != data.len:
    return false
  if piece.blocks[bi].state == bsReceived:
    return false  # Duplicate

  piece.blocks[bi].state = bsReceived
  piece.lastBlockTime = epochTime()
  # Lazy allocation: create buffer on first block receipt
  if piece.data.len == 0:
    piece.data = newString(piece.totalLength)
    if pm.trackAgreement:
      piece[].initConsensus()
  # Copy data into piece buffer
  copyMem(addr piece.data[offset], unsafeAddr data[0], data.len)
  piece.receivedBytes += data.len
  pm.downloaded += data.len
  # Record CRC32C for optimistic verification agreement tracking
  if pm.trackAgreement:
    piece[].recordBlockCrc(bi, data.toOpenArrayByte(0, data.len - 1))

  # Completion check: receivedBytes == totalLength iff all blocks received
  # (duplicates are rejected above, so bytes accumulate exactly once per block)
  if piece.receivedBytes == piece.totalLength:
    piece.state = psComplete
    pm.completedCount += 1
    return true
  else:
    piece.state = psPartial
  return false

proc failPiece*(pm: PieceManager, pieceIdx: int) =
  ## Common failure path: reset blocks, adjust accounting, deallocate buffer.
  ## Handles counter adjustments based on the piece's current state.
  var piece = addr pm.pieces[pieceIdx]
  let oldState = piece.state
  piece.state = psFailed
  for blk in piece.blocks.mitems:
    blk.state = bsEmpty
  pm.downloaded -= int64(piece.receivedBytes)
  piece.receivedBytes = 0
  if oldState in CompletedStates:
    pm.completedCount -= 1
  if oldState == psOptimistic:
    pm.optimisticCount -= 1
  piece.data = ""
  piece.consensus = PieceConsensus()

proc applyVerification*(pm: PieceManager, pieceIdx: int, hashMatch: bool) =
  ## Apply the result of a SHA1 hash check to piece state.
  ## Called after computing SHA1 (possibly on a blocking thread).
  if hashMatch:
    pm.pieces[pieceIdx].state = psVerified
    pm.verifiedCount += 1
  else:
    pm.failPiece(pieceIdx)

proc verifyPiece*(pm: PieceManager, pieceIdx: int): bool =
  ## Verify SHA1 hash of a completed piece. Returns true if valid.
  if not pm.validPieceIdx(pieceIdx):
    return false

  let piece = addr pm.pieces[pieceIdx]
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
  pm.downloaded -= int64(piece.receivedBytes)
  if piece.state == psVerified:
    pm.verifiedCount -= 1
  elif piece.state == psOptimistic:
    pm.optimisticCount -= 1
  if piece.state in CompletedStates:
    pm.completedCount -= 1
  piece.state = psEmpty
  piece.receivedBytes = 0
  piece.data = ""  # Deallocate buffer — will be re-allocated on next block receipt
  for blk in piece.blocks.mitems:
    blk.state = bsEmpty

proc failAndResetPiece*(pm: PieceManager, pieceIdx: int) =
  ## Fail a piece and immediately transition to psEmpty for re-download.
  ## Single-pass accounting — avoids fragile failPiece + resetPiece chains.
  if not pm.validPieceIdx(pieceIdx): return
  var piece = addr pm.pieces[pieceIdx]
  let oldState = piece.state
  pm.downloaded -= int64(piece.receivedBytes)
  if oldState == psVerified:
    pm.verifiedCount -= 1
  elif oldState == psOptimistic:
    pm.optimisticCount -= 1
  if oldState in CompletedStates:
    pm.completedCount -= 1
  piece.state = psEmpty
  piece.receivedBytes = 0
  piece.data = ""
  piece.consensus = PieceConsensus()
  for blk in piece.blocks.mitems:
    blk.state = bsEmpty

proc getNeededBlocks*(pm: PieceManager, pieceIdx: int, maxBlocks: int = 5): seq[tuple[offset: int, length: int]] =
  ## Get unrequested blocks for a piece.
  if not pm.validPieceIdx(pieceIdx):
    return @[]

  let piece = addr pm.pieces[pieceIdx]
  if piece.state in CompletedStates:
    return @[]

  for blk in piece.blocks:
    if blk.state == bsEmpty:
      result.add((blk.offset, blk.length))
      if result.len >= maxBlocks:
        break

proc markBlockRequested*(pm: PieceManager, pieceIdx: int, offset: int) =
  ## Mark a block as requested (in-flight).
  if not pm.validPieceIdx(pieceIdx): return
  let bi = blockIndex(offset)
  if bi >= 0 and bi < pm.pieces[pieceIdx].blocks.len:
    pm.pieces[pieceIdx].blocks[bi].state = bsRequested

proc cancelBlockRequest*(pm: PieceManager, pieceIdx: int, offset: int) =
  ## Cancel a block request (mark as empty again).
  ## If other peers are still racing this block, keep it as bsRequested.
  if not pm.validPieceIdx(pieceIdx): return
  let key: BlockKey = (pieceIdx, offset)
  pm.raceTracker.raced.withValue(key, info):
    if info.requesters.len > 0:
      return  # Other racers still have this block in-flight
  let bi = blockIndex(offset)
  if bi >= 0 and bi < pm.pieces[pieceIdx].blocks.len and
     pm.pieces[pieceIdx].blocks[bi].state == bsRequested:
    pm.pieces[pieceIdx].blocks[bi].state = bsEmpty

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
                  exclude: HashSet[int] = initHashSet[int]()): int =
  ## Select the rarest piece that the peer has and we need.
  ## Among equally-rare pieces, pick randomly to avoid sequential behavior.
  ## Always prefers partially downloaded pieces first.
  ## Pieces in `exclude` are skipped (used when a piece has no empty blocks left).
  ## Returns -1 if no suitable piece found.
  type PieceCandidate = tuple[index: int, rarity: int]
  var candidates: seq[PieceCandidate]

  # Track best partial inline during candidate collection (avoids extra pass)
  var bestPartial = -1
  var bestReceived = -1

  for i in 0 ..< pm.totalPieces:
    if pm.pieces[i].state in CompletedStates:
      continue
    if not pm.pieces[i].hasEmptyBlocks:
      continue  # All blocks already requested or received
    if not hasPiece(peerBitfield, i):
      continue
    if i in exclude:
      continue
    let rarity = if i < availability.len: availability[i] else: 0
    candidates.add((i, rarity))
    if pm.pieces[i].state == psPartial:
      let received = pm.pieces[i].receivedBytes
      if received > bestReceived:
        bestReceived = received
        bestPartial = i

  if candidates.len == 0:
    return -1

  # Always prefer completing a partial piece first (finish what we started).
  # Pick the partial piece closest to completion so all peers collaborate
  # on finishing the same piece rather than scattering across many partials.
  if bestPartial >= 0:
    return bestPartial

  # Sort by rarity (ascending) - rarest first
  candidates.sort(proc(a, b: PieceCandidate): int = cmp(a.rarity, b.rarity))

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
  ## Number of pieces not yet verified (optimistic pieces count as done).
  pm.totalPieces - pm.verifiedCount - pm.optimisticCount

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
    if pm.pieces[i].state in CompletedStates:
      continue
    for blk in pm.pieces[i].blocks:
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
    if pm.pieces[i].state in CompletedStates:
      continue
    if not hasPiece(peerBitfield, i):
      continue
    for blk in pm.pieces[i].blocks:
      if blk.state == bsRequested:
        let key: BlockKey = (i, blk.offset)
        var atCapacity = false
        pm.raceTracker.raced.withValue(key, info):
          atCapacity = info.requesters.len >= pm.raceTracker.maxRacers
        if atCapacity:
          continue
        result.add((i, blk.offset, blk.length))
        if result.len >= maxBlocks:
          return

proc getPieceData*(pm: PieceManager, pieceIdx: int): string =
  ## Get the data for a verified piece and release the buffer.
  ## After this call, the piece buffer is deallocated (uploads read from disk).
  if pieceIdx >= 0 and pieceIdx < pm.totalPieces and
     pm.pieces[pieceIdx].state in {psOptimistic, psVerified}:
    result = move(pm.pieces[pieceIdx].data)
    pm.pieces[pieceIdx].data = ""
  else:
    return ""

proc generateBitfield*(pm: PieceManager): seq[byte] =
  ## Generate our bitfield for sending to peers.
  result = newBitfield(pm.totalPieces)
  for i in 0 ..< pm.totalPieces:
    if pm.pieces[i].state in {psOptimistic, psVerified}:
      setPiece(result, i)

# ============================================================
# Block Racing
# ============================================================

proc registerRacer*(pm: PieceManager, pieceIdx: int, offset: int, peerKey: string) =
  ## Record that peerKey has requested this block. Creates a race entry if needed.
  let key: BlockKey = (pieceIdx, offset)
  pm.raceTracker.raced.withValue(key, info):
    for r in info.requesters:
      if r == peerKey:
        return
    info.requesters.add(peerKey)
  do:
    pm.raceTracker.raced[key] = BlockRaceInfo(
      requesters: @[peerKey],
      firstRequestTime: epochTime()
    )

proc unregisterRacer*(pm: PieceManager, pieceIdx: int, offset: int, peerKey: string) =
  ## Remove peerKey from the racers of this block.
  let key: BlockKey = (pieceIdx, offset)
  var shouldDelete = false
  pm.raceTracker.raced.withValue(key, info):
    var i = 0
    while i < info.requesters.len:
      if info.requesters[i] == peerKey:
        info.requesters.del(i)
        break
      i += 1
    shouldDelete = info.requesters.len == 0
  if shouldDelete:
    pm.raceTracker.raced.del(key)

proc getRacingPeers*(pm: PieceManager, pieceIdx: int, offset: int): seq[string] =
  ## Get all peer keys that have requested this block.
  let key: BlockKey = (pieceIdx, offset)
  pm.raceTracker.raced.withValue(key, info):
    return info.requesters
  return @[]

proc clearRaceEntry*(pm: PieceManager, pieceIdx: int, offset: int) =
  ## Remove the race tracking entry for a block (after block received).
  let key: BlockKey = (pieceIdx, offset)
  pm.raceTracker.raced.del(key)

proc blockLength*(pm: PieceManager, pieceIdx: int, offset: int): int =
  ## Look up block length from piece index and offset. O(1) via index.
  if not pm.validPieceIdx(pieceIdx): return 0
  let bi = blockIndex(offset)
  if bi >= 0 and bi < pm.pieces[pieceIdx].blocks.len:
    return pm.pieces[pieceIdx].blocks[bi].length
  return 0

proc getRaceableBlocks*(pm: PieceManager, pieceIdx: int, peerKey: string,
                        peerBitfield: seq[byte],
                        maxBlocks: int = 5,
                        includeVerifiable: bool = false): seq[tuple[pieceIdx: int, offset: int, length: int]] =
  ## Get blocks from a piece eligible for racing. Returns bsRequested blocks,
  ## and optionally bsReceived blocks needing agreement (when includeVerifiable).
  if not pm.validPieceIdx(pieceIdx):
    return @[]
  if not hasPiece(peerBitfield, pieceIdx):
    return @[]
  let piece = addr pm.pieces[pieceIdx]
  if piece.state in CompletedStates:
    return @[]
  for blk in piece.blocks:
    let eligible = (blk.state == bsRequested) or
                   (includeVerifiable and blk.state == bsReceived and
                     piece[].blockNeedsAgreement(blockIndex(blk.offset)))
    if eligible and pm.isBlockEligibleForRacing(pieceIdx, blk.offset, peerKey):
      result.add((pieceIdx, blk.offset, blk.length))
      if result.len >= maxBlocks:
        return

proc getCrossRaceBlocks*(pm: PieceManager, peerKey: string,
                         peerBitfield: seq[byte],
                         maxBlocks: int = 16,
                         excludePieces: seq[int] = @[]): seq[tuple[pieceIdx: int, offset: int, length: int]] =
  ## Get blocks from partial pieces for cross-piece agreement building.
  ## Two passes: near-complete pieces (>50% received) first, then any partial.
  for pass in 0 .. 1:
    for pi in 0 ..< pm.totalPieces:
      if result.len >= maxBlocks:
        return
      let piece = addr pm.pieces[pi]
      if piece.state != psPartial or not hasPiece(peerBitfield, pi):
        continue
      if pi in excludePieces:
        continue
      if pass == 0 and piece.receivedBytes * 2 < piece.totalLength:
        continue
      for bi, blk in piece.blocks:
        if result.len >= maxBlocks:
          break
        let eligible = (blk.state == bsRequested) or
                       (blk.state == bsReceived and piece[].blockNeedsAgreement(bi))
        if eligible and pm.isBlockEligibleForRacing(pi, blk.offset, peerKey):
          result.add((pi, blk.offset, blk.length))

proc clearPieceRaceEntries*(pm: PieceManager, pieceIdx: int) =
  ## Remove all race tracking entries for a piece (after verification).
  if not pm.validPieceIdx(pieceIdx):
    return
  for blk in pm.pieces[pieceIdx].blocks:
    let key: BlockKey = (pieceIdx, blk.offset)
    pm.raceTracker.raced.del(key)

# ============================================================
# Optimistic Piece Verification
# ============================================================

proc checkBlockAgreement*(pm: PieceManager, pieceIdx: int, offset: int,
                          data: openArray[byte]): bool =
  ## Compare a racing duplicate block against stored data via CRC32C.
  ## Returns true if the data agrees (CRC match). Does not store the data.
  if not pm.validPieceIdx(pieceIdx):
    return false
  var piece = addr pm.pieces[pieceIdx]
  let bi = blockIndex(offset)
  if bi < 0 or bi >= piece.consensus.blockAgreements.len:
    return false
  let storedCrc = piece.consensus.blockAgreements[bi].crc
  if storedCrc == 0:
    return false
  if crc32c(data) == storedCrc:
    let wasZero = piece.consensus.blockAgreements[bi].agreeCount == 0
    piece.consensus.blockAgreements[bi].agreeCount += 1
    if wasZero:
      piece.consensus.agreedBlockCount += 1
    return true
  return false

proc meetsOptimisticThreshold*(pm: PieceManager, pieceIdx: int,
                               minAgreePeers: int = 2,
                               minAgreeBlocks: int = 3): bool =
  ## Check if a completed piece has enough peer consensus for optimistic verification.
  ## `minAgreePeers` is the total peers that must agree (including the original).
  ## `minAgreeBlocks` is the absolute number of blocks that must have agreement.
  if not pm.validPieceIdx(pieceIdx):
    return false
  let piece = addr pm.pieces[pieceIdx]
  if piece.state != psComplete:
    return false
  if piece.consensus.blockAgreements.len == 0:
    return false
  var qualifiedBlocks = 0
  for ba in piece.consensus.blockAgreements:
    # agreeCount is additional peers beyond the first, so threshold is minAgreePeers - 1
    if ba.agreeCount >= minAgreePeers - 1:
      qualifiedBlocks += 1
  return qualifiedBlocks >= minAgreeBlocks

proc markOptimistic*(pm: PieceManager, pieceIdx: int) =
  ## Transition a piece from psComplete to psOptimistic.
  if not pm.validPieceIdx(pieceIdx): return
  var piece = addr pm.pieces[pieceIdx]
  if piece.state != psComplete:
    return
  piece.state = psOptimistic
  pm.optimisticCount += 1

proc applyOptimisticVerification*(pm: PieceManager, pieceIdx: int, hashMatch: bool) =
  ## Finalize an optimistic piece after background SHA1 confirmation.
  ## On success: psOptimistic -> psVerified. On failure: full rollback via failPiece.
  if not pm.validPieceIdx(pieceIdx): return
  if pm.pieces[pieceIdx].state != psOptimistic:
    return
  if hashMatch:
    pm.optimisticCount -= 1
    pm.pieces[pieceIdx].state = psVerified
    pm.verifiedCount += 1
  else:
    pm.failPiece(pieceIdx)  # Handles optimisticCount and completedCount
