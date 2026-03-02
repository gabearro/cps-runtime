## Test: Bouncer Message Buffer
##
## Tests ring buffer operations and JSONL disk persistence.

import std/[tables, os, times]
import cps/bouncer/types
import cps/bouncer/buffer
import cps/bouncer/protocol

# ============================================================
# Helpers
# ============================================================

proc makeMsg(id: int64, text: string): BufferedMessage =
  BufferedMessage(
    id: id,
    timestamp: epochTime(),
    kind: "privmsg",
    source: "nick",
    target: "#test",
    text: text,
    tags: initTable[string, string](),
  )

# ============================================================
# Ring buffer tests
# ============================================================

block testNewBuffer:
  let rb = newMessageRingBuffer(10)
  assert rb.isEmpty
  assert rb.len == 0
  assert rb.newestId() == 0
  assert rb.oldestId() == 0
  echo "PASS: new buffer is empty"

block testPushAndGet:
  let rb = newMessageRingBuffer(5)
  for i in 1 .. 3:
    rb.push(makeMsg(i.int64, "msg" & $i))
  assert rb.len == 3
  assert rb.newestId() == 3
  assert rb.oldestId() == 1
  let all = rb.getAllMessages()
  assert all.len == 3
  assert all[0].id == 1
  assert all[1].id == 2
  assert all[2].id == 3
  echo "PASS: push and get messages"

block testWrapAround:
  let rb = newMessageRingBuffer(3)
  for i in 1 .. 5:
    rb.push(makeMsg(i.int64, "msg" & $i))
  assert rb.len == 3  # Only 3 fit
  assert rb.oldestId() == 3
  assert rb.newestId() == 5
  let all = rb.getAllMessages()
  assert all.len == 3
  assert all[0].id == 3
  assert all[1].id == 4
  assert all[2].id == 5
  echo "PASS: ring buffer wraps around"

block testGetSince:
  let rb = newMessageRingBuffer(10)
  for i in 1 .. 10:
    rb.push(makeMsg(i.int64, "msg" & $i))

  # Get messages since id 7
  let msgs = rb.getMessagesSince(7)
  assert msgs.len == 3
  assert msgs[0].id == 8
  assert msgs[1].id == 9
  assert msgs[2].id == 10
  echo "PASS: getMessagesSince"

block testGetSinceWithLimit:
  let rb = newMessageRingBuffer(10)
  for i in 1 .. 10:
    rb.push(makeMsg(i.int64, "msg" & $i))

  let msgs = rb.getMessagesSince(0, 3)
  assert msgs.len == 3
  assert msgs[0].id == 1
  assert msgs[2].id == 3
  echo "PASS: getMessagesSince with limit"

block testGetSinceWrapped:
  let rb = newMessageRingBuffer(5)
  for i in 1 .. 8:
    rb.push(makeMsg(i.int64, "msg" & $i))

  # Buffer contains ids 4,5,6,7,8
  let msgs = rb.getMessagesSince(6)
  assert msgs.len == 2
  assert msgs[0].id == 7
  assert msgs[1].id == 8
  echo "PASS: getMessagesSince with wraparound"

block testGetAllEmpty:
  let rb = newMessageRingBuffer(5)
  assert rb.getAllMessages().len == 0
  assert rb.getMessagesSince(0).len == 0
  echo "PASS: get from empty buffer"

block testSingleElement:
  let rb = newMessageRingBuffer(1)
  rb.push(makeMsg(42, "only one"))
  assert rb.len == 1
  assert rb.newestId() == 42
  rb.push(makeMsg(43, "replaced"))
  assert rb.len == 1
  assert rb.newestId() == 43
  let all = rb.getAllMessages()
  assert all.len == 1
  assert all[0].text == "replaced"
  echo "PASS: single element buffer"

# ============================================================
# JSONL persistence tests
# ============================================================

block testFlushAndLoad:
  let tmpDir = getTempDir() & "cps_bouncer_test_" & $epochTime() & "/"

  # Create and populate buffer
  let rb = newMessageRingBuffer(10)
  for i in 1 .. 5:
    rb.push(makeMsg(i.int64, "persistent msg " & $i))

  # Flush to disk
  rb.flushToDisk(tmpDir, "testserver", "#testchan")
  assert rb.lastFlushedId == 5

  # Load from disk
  let loaded = loadFromDisk(tmpDir, "testserver", "#testchan", 10)
  assert loaded.len == 5
  let all = loaded.getAllMessages()
  assert all[0].id == 1
  assert all[0].text == "persistent msg 1"
  assert all[4].id == 5
  assert all[4].text == "persistent msg 5"
  assert loaded.lastFlushedId == 5

  # Cleanup
  removeDir(tmpDir)
  echo "PASS: flush and load from disk"

block testIncrementalFlush:
  let tmpDir = getTempDir() & "cps_bouncer_test2_" & $epochTime() & "/"

  let rb = newMessageRingBuffer(10)
  for i in 1 .. 3:
    rb.push(makeMsg(i.int64, "batch1 msg " & $i))
  rb.flushToDisk(tmpDir, "s", "#c")
  assert rb.lastFlushedId == 3

  # Add more messages
  for i in 4 .. 6:
    rb.push(makeMsg(i.int64, "batch2 msg " & $i))
  rb.flushToDisk(tmpDir, "s", "#c")
  assert rb.lastFlushedId == 6

  # Load should have all 6
  let loaded = loadFromDisk(tmpDir, "s", "#c", 10)
  assert loaded.len == 6
  let all = loaded.getAllMessages()
  assert all[0].text == "batch1 msg 1"
  assert all[5].text == "batch2 msg 6"

  # Cleanup
  removeDir(tmpDir)
  echo "PASS: incremental flush"

block testLoadNonexistent:
  let loaded = loadFromDisk("/tmp/nonexistent_dir_xyz", "s", "#c", 10)
  assert loaded.len == 0
  echo "PASS: load from nonexistent path"

block testLoadTruncated:
  let tmpDir = getTempDir() & "cps_bouncer_test3_" & $epochTime() & "/"

  # Fill 20 messages but load into capacity of 5
  let rb = newMessageRingBuffer(20)
  for i in 1 .. 20:
    rb.push(makeMsg(i.int64, "msg " & $i))
  rb.flushToDisk(tmpDir, "s", "#c")

  let loaded = loadFromDisk(tmpDir, "s", "#c", 5)
  assert loaded.len == 5
  let all = loaded.getAllMessages()
  # Should have the LAST 5 messages (16-20)
  assert all[0].id == 16
  assert all[4].id == 20

  removeDir(tmpDir)
  echo "PASS: load with truncation to capacity"

echo "\nAll bouncer buffer tests passed!"
