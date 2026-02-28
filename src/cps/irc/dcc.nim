## CPS IRC DCC (Direct Client-to-Client)
##
## Implements DCC SEND file transfers built on the CPS runtime.
## Supports both direct connections and proxied connections.
## Provides progress callbacks and resumption support.

import std/[strutils, os, times]
import ../runtime
import ../transform
import ../eventloop
import ../io/streams
import ../io/tcp
import ../io/files
import ../io/proxy
import ../io/timeouts
import ./protocol

type
  DccTransferState* = enum
    dtsIdle
    dtsConnecting
    dtsTransferring
    dtsCompleted
    dtsFailed
    dtsCancelled

  DccProgressCallback* = proc(bytesReceived: int64, totalBytes: int64) {.closure.}

  DccTransfer* = ref object
    ## Represents an active or completed DCC file transfer.
    info*: DccInfo
    source*: string           ## Nick of the sender
    state*: DccTransferState
    outputPath*: string       ## Local file path to save to
    bytesReceived*: int64
    totalBytes*: int64
    resumePosition*: int64    ## Resume offset (0 = start from beginning)
    error*: string
    proxies*: seq[ProxyConfig] ## Proxy chain for DCC connections
    connectTimeoutMs*: int    ## Connection timeout in ms (0 = no timeout)
    progressCb: DccProgressCallback
    stream: AsyncStream

  DccManager* = ref object
    ## Manages DCC transfers. Tracks pending offers and active downloads.
    pendingOffers*: seq[DccTransfer]  ## Unaccepted DCC SEND offers
    activeTransfers*: seq[DccTransfer] ## Currently downloading
    completedTransfers*: seq[DccTransfer] ## Finished downloads
    defaultDownloadDir*: string
    defaultProxies*: seq[ProxyConfig]
    maxConcurrent*: int

# ============================================================
# DccManager
# ============================================================

proc newDccManager*(downloadDir: string = getHomeDir() / "Downloads",
                    maxConcurrent: int = 5): DccManager =
  DccManager(
    defaultDownloadDir: downloadDir,
    maxConcurrent: maxConcurrent,
  )

proc addOffer*(dm: DccManager, source: string, info: DccInfo): DccTransfer =
  ## Register a new DCC SEND offer. Returns the DccTransfer for tracking.
  let transfer = DccTransfer(
    info: info,
    source: source,
    state: dtsIdle,
    totalBytes: info.filesize,
    proxies: dm.defaultProxies,
  )

  # Generate output path
  var filename = info.filename
  # Sanitize filename — remove path separators
  filename = filename.replace("/", "_").replace("\\", "_")
  if filename.len == 0:
    filename = "dcc_download"
  transfer.outputPath = dm.defaultDownloadDir / filename

  dm.pendingOffers.add(transfer)
  result = transfer

proc setProgressCallback*(transfer: DccTransfer, cb: DccProgressCallback) =
  transfer.progressCb = cb

proc checkResumable*(transfer: DccTransfer): int64 =
  ## Check if a partial file exists for this transfer.
  ## Returns the resume position (file size) if resumable, 0 otherwise.
  if fileExists(transfer.outputPath):
    let partialSize = getFileSize(transfer.outputPath)
    if partialSize > 0 and (transfer.totalBytes <= 0 or partialSize < transfer.totalBytes):
      return partialSize
  return 0

proc setResumePosition*(transfer: DccTransfer, position: int64) =
  ## Set the resume position after receiving a DCC ACCEPT confirmation.
  transfer.resumePosition = position

# ============================================================
# DCC file receiving
# ============================================================

proc writeDccAck(stream: AsyncStream, bytesReceived: int64): CpsVoidFuture =
  ## Send a 4-byte big-endian acknowledgment of bytes received (DCC protocol).
  var ack: string
  let v = uint32(bytesReceived and 0xFFFFFFFF'i64)
  ack.add(char((v shr 24) and 0xFF))
  ack.add(char((v shr 16) and 0xFF))
  ack.add(char((v shr 8) and 0xFF))
  ack.add(char(v and 0xFF))
  stream.write(ack)

proc receiveDcc*(transfer: DccTransfer): CpsVoidFuture {.cps.} =
  ## Accept and download a DCC SEND offer.
  ## Connects to the sender (directly or through proxies), receives the file,
  ## and saves it to transfer.outputPath. All I/O uses the CPS async runtime
  ## to avoid blocking the event loop.
  if transfer.state != dtsIdle:
    raise newException(AsyncIoError, "Transfer already started or completed")

  transfer.state = dtsConnecting

  # Ensure download directory exists
  let dir = parentDir(transfer.outputPath)
  if dir.len > 0 and not dirExists(dir):
    createDir(dir)

  # Connect to the DCC sender
  let ip = longIpToString(transfer.info.ip)
  let port = transfer.info.port

  try:
    var stream: AsyncStream
    if transfer.proxies.len > 0:
      if transfer.connectTimeoutMs > 0:
        let ps: ProxyStream = await withTimeout(proxyChainConnect(transfer.proxies, ip, port), transfer.connectTimeoutMs)
        stream = ps.AsyncStream
      else:
        let ps = await proxyChainConnect(transfer.proxies, ip, port)
        stream = ps.AsyncStream
    else:
      if transfer.connectTimeoutMs > 0:
        let tcp: TcpStream = await withTimeout(tcpConnect(ip, port), transfer.connectTimeoutMs)
        stream = tcp.AsyncStream
      else:
        let tcp = await tcpConnect(ip, port)
        stream = tcp.AsyncStream

    transfer.stream = stream
    transfer.state = dtsTransferring

    # Open output file via async FileStream (yields to event loop on writes)
    let fileMode = if transfer.resumePosition > 0: fmAppend else: fmWrite
    var fileStream: files.FileStream
    try:
      fileStream = files.newFileStream(transfer.outputPath, fileMode)
    except CatchableError as e:
      stream.close()
      transfer.state = dtsFailed
      transfer.error = "Failed to open output file: " & transfer.outputPath & " (" & e.msg & ")"
      return

    # Receive loop — start counting from resume position
    transfer.bytesReceived = transfer.resumePosition
    let chunkSize = 16384  # 16KB chunks
    var lastProgressTime = epochTime()
    var chunkCount = 0

    while true:
      # Check if we've received everything
      if transfer.totalBytes > 0 and transfer.bytesReceived >= transfer.totalBytes:
        break

      # Yield to the event loop so other tasks (IRC, timers, UI) can run.
      # TCP read and DCC ack both have fast paths that return pre-completed
      # futures (inline, no yield), so without this explicit yield the loop
      # can starve the event loop when data arrives faster than we process it.
      await cpsYield()

      let data = await stream.read(chunkSize)
      if data.len == 0:
        break  # EOF

      # Write to file asynchronously (scheduleCallback → yields to event loop)
      await fileStream.write(data)
      transfer.bytesReceived += data.len
      inc chunkCount

      # Send DCC acknowledgment (4 bytes — TCP fast path, usually inline)
      await writeDccAck(stream, transfer.bytesReceived)

      # Throttled progress callback — at most every 250ms
      if transfer.progressCb != nil:
        let now = epochTime()
        if now - lastProgressTime >= 0.25 or
            (transfer.totalBytes > 0 and transfer.bytesReceived >= transfer.totalBytes):
          lastProgressTime = now
          transfer.progressCb(transfer.bytesReceived, transfer.totalBytes)

    fileStream.close()
    stream.close()
    transfer.stream = nil

    if transfer.totalBytes > 0 and transfer.bytesReceived < transfer.totalBytes:
      transfer.state = dtsFailed
      transfer.error = "Incomplete transfer: got " & $transfer.bytesReceived &
                       " of " & $transfer.totalBytes & " bytes"
    else:
      transfer.state = dtsCompleted

  except CatchableError as e:
    transfer.state = dtsFailed
    transfer.error = e.msg
    if transfer.stream != nil:
      transfer.stream.close()
      transfer.stream = nil

proc cancelTransfer*(transfer: DccTransfer) =
  ## Cancel an active DCC transfer.
  transfer.state = dtsCancelled
  if transfer.stream != nil:
    transfer.stream.close()
    transfer.stream = nil

# ============================================================
# DccManager: accept and download
# ============================================================

proc acceptOffer*(dm: DccManager, transfer: DccTransfer,
                  outputPath: string = ""): CpsVoidFuture {.cps.} =
  ## Accept a pending DCC offer and start downloading.
  if outputPath.len > 0:
    transfer.outputPath = outputPath

  # Move from pending to active
  var idx = -1
  for i in 0 ..< dm.pendingOffers.len:
    if dm.pendingOffers[i] == transfer:
      idx = i
      break
  if idx >= 0:
    dm.pendingOffers.delete(idx)
  dm.activeTransfers.add(transfer)

  # Download
  await receiveDcc(transfer)

  # Move from active to completed
  idx = -1
  for i in 0 ..< dm.activeTransfers.len:
    if dm.activeTransfers[i] == transfer:
      idx = i
      break
  if idx >= 0:
    dm.activeTransfers.delete(idx)
  dm.completedTransfers.add(transfer)

proc acceptAll*(dm: DccManager): CpsVoidFuture {.cps.} =
  ## Accept all pending DCC offers concurrently (up to maxConcurrent).
  # Copy pending list since acceptOffer modifies it
  let offers = dm.pendingOffers
  for transfer in offers:
    if dm.activeTransfers.len >= dm.maxConcurrent:
      break
    await dm.acceptOffer(transfer)
