## CPS IRC Bouncer - Message Buffer
##
## Per-channel ring buffer with JSONL disk persistence.
## Messages are stored in a fixed-size circular buffer in memory and
## periodically flushed to append-only JSONL files on disk.

import std/[os, json, strutils, tables]
import ./types
import ./protocol

# ============================================================
# Ring buffer operations
# ============================================================

proc newMessageRingBuffer*(capacity: int): MessageRingBuffer =
  ## Create a new ring buffer with the given capacity.
  MessageRingBuffer(
    buf: newSeq[BufferedMessage](capacity),
    head: 0,
    count: 0,
    capacity: capacity,
    lastFlushedId: 0,
  )

proc push*(rb: MessageRingBuffer, msg: BufferedMessage) =
  ## Add a message to the buffer. Overwrites oldest when full.
  rb.buf[rb.head] = msg
  rb.head = (rb.head + 1) mod rb.capacity
  if rb.count < rb.capacity:
    rb.count += 1

proc isEmpty*(rb: MessageRingBuffer): bool =
  rb.count == 0

proc len*(rb: MessageRingBuffer): int =
  rb.count

proc newestId*(rb: MessageRingBuffer): int64 =
  ## Return the ID of the most recent message, or 0 if empty.
  if rb.count == 0:
    return 0
  let idx = (rb.head - 1 + rb.capacity) mod rb.capacity
  rb.buf[idx].id

proc oldestId*(rb: MessageRingBuffer): int64 =
  ## Return the ID of the oldest message, or 0 if empty.
  if rb.count == 0:
    return 0
  let startIdx = (rb.head - rb.count + rb.capacity) mod rb.capacity
  rb.buf[startIdx].id

proc getAllMessages*(rb: MessageRingBuffer): seq[BufferedMessage] =
  ## Return all messages in chronological order.
  result = newSeqOfCap[BufferedMessage](rb.count)
  let startIdx = (rb.head - rb.count + rb.capacity) mod rb.capacity
  for i in 0 ..< rb.count:
    let idx = (startIdx + i) mod rb.capacity
    result.add(rb.buf[idx])

proc getMessagesSince*(rb: MessageRingBuffer, sinceId: int64,
                       limit: int = 500): seq[BufferedMessage] =
  ## Return messages with id > sinceId, up to limit.
  result = newSeqOfCap[BufferedMessage](min(limit, rb.count))
  let startIdx = (rb.head - rb.count + rb.capacity) mod rb.capacity
  var found = 0
  for i in 0 ..< rb.count:
    let idx = (startIdx + i) mod rb.capacity
    if rb.buf[idx].id > sinceId:
      result.add(rb.buf[idx])
      found += 1
      if found >= limit:
        break

# ============================================================
# JSONL disk persistence
# ============================================================

proc ensureDir(path: string) =
  ## Create directory and parents if they don't exist.
  if not dirExists(path):
    createDir(path)

proc logFilePath*(logDir, serverName, target: string): string =
  ## Compute the JSONL log file path for a given server:channel.
  let safeName = serverName.replace("/", "_").replace(":", "_")
  let safeTarget = target.replace("/", "_").replace(":", "_").toLowerAscii()
  ensureDir(logDir)
  logDir / (safeName & "_" & safeTarget & ".jsonl")

proc flushToDisk*(rb: MessageRingBuffer, logDir, serverName, target: string) =
  ## Append new messages (since lastFlushedId) to the JSONL log file.
  let path = logFilePath(logDir, serverName, target)
  let startIdx = (rb.head - rb.count + rb.capacity) mod rb.capacity

  var lines: seq[string] = @[]
  for i in 0 ..< rb.count:
    let idx = (startIdx + i) mod rb.capacity
    if rb.buf[idx].id > rb.lastFlushedId:
      lines.add($bufferedMessageToJson(rb.buf[idx]))

  if lines.len > 0:
    let f = open(path, fmAppend)
    try:
      for line in lines:
        f.writeLine(line)
    finally:
      f.close()
    rb.lastFlushedId = rb.newestId()

proc loadFromDisk*(logDir, serverName, target: string,
                   capacity: int): MessageRingBuffer =
  ## Load the last `capacity` messages from the JSONL log file.
  ## Returns a new ring buffer populated with the loaded messages.
  result = newMessageRingBuffer(capacity)
  let path = logFilePath(logDir, serverName, target)
  if not fileExists(path):
    return

  # Read all lines and take the last `capacity` ones
  var allLines: seq[string] = @[]
  let f = open(path, fmRead)
  try:
    var line: string
    while f.readLine(line):
      if line.len > 0:
        allLines.add(line)
  finally:
    f.close()

  # Take last `capacity` lines
  let startLine = max(0, allLines.len - capacity)
  for i in startLine ..< allLines.len:
    try:
      let msg = jsonToBufferedMessage(parseJson(allLines[i]))
      result.push(msg)
    except CatchableError:
      discard  # Skip malformed lines

  if result.count > 0:
    result.lastFlushedId = result.newestId()

# ============================================================
# Per-client delivery tracking persistence
# ============================================================

proc clientDeliveryPath(logDir, clientName: string): string =
  let safeName = clientName.replace("/", "_").replace(":", "_")
  let dir = logDir / "clients"
  if not dirExists(dir):
    createDir(dir)
  dir / (safeName & ".json")

proc loadClientDeliveryIds*(logDir, clientName: string): Table[string, int64] =
  ## Load per-client delivery tracking from disk.
  result = initTable[string, int64]()
  if clientName.len == 0:
    return
  let path = clientDeliveryPath(logDir, clientName)
  if not fileExists(path):
    return
  try:
    let j = parseJson(readFile(path))
    if j.kind == JObject:
      for key, val in j.pairs:
        result[key] = val.getBiggestInt()
  except CatchableError:
    discard

proc saveClientDeliveryIds*(logDir, clientName: string, ids: Table[string, int64]) =
  ## Save per-client delivery tracking to disk.
  if clientName.len == 0:
    return
  let path = clientDeliveryPath(logDir, clientName)
  var j = newJObject()
  for key, val in ids:
    j[key] = newJInt(val)
  writeFile(path, $j)
