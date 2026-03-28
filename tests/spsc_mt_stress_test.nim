## Multi-threaded stress test for SPSC queue with complex payloads.
## Mirrors the exact pattern in the torrent bridge:
##   - Producer thread: creates events, clones (isolates), pushes to SPSC queue
##   - Consumer thread: drains queue, reads data, moves some fields to globals, destroys rest
##
## Run with: nim c -r --mm:atomicArc tests/spsc_mt_stress_test.nim

import std/[atomics, os]

const SpscCapacity = 256  # Smaller for faster wrap-around testing
const NumEvents = 100_000  # Total events to push

type
  PeerEntry = object
    address: string
    clientName: string
    flags: string
    transport: string

  TrackerEntry = object
    url: string
    status: string
    errorText: string

  TestEvent = object
    kind: int
    torrentId: int
    intParam: int
    floatParam: float
    text: string
    text2: string
    text3: string
    peers: seq[PeerEntry]
    pieceMap: string
    trackers: seq[TrackerEntry]
    files: seq[tuple[path: string, length: int64]]

  SpscQueue[T] = object
    buf: ptr UncheckedArray[T]
    mask: int
    pad0: array[64, byte]
    head: Atomic[int64]
    pad1: array[64, byte]
    tail: Atomic[int64]

proc initSpscQueue[T](q: var SpscQueue[T]) =
  q.mask = SpscCapacity - 1
  q.buf = cast[ptr UncheckedArray[T]](allocShared0(SpscCapacity * sizeof(T)))
  q.head.store(0, moRelaxed)
  q.tail.store(0, moRelaxed)

proc push[T](q: var SpscQueue[T], item: sink T): bool =
  let t = q.tail.load(moRelaxed)
  let h = q.head.load(moAcquire)
  if t - h >= SpscCapacity:
    return false
  q.buf[int(t) and q.mask] = move item
  q.tail.store(t + 1, moRelease)
  true

proc drainAll[T](q: var SpscQueue[T]): seq[T] =
  let h = q.head.load(moRelaxed)
  let t = q.tail.load(moAcquire)
  let count = int(t - h)
  if count <= 0: return @[]
  result = newSeq[T](count)
  for i in 0 ..< count:
    let idx = int(h + i.int64) and q.mask
    result[i] = move(q.buf[idx])
  q.head.store(t, moRelease)

# --- Clone isolation (mirrors cloneUiEventIsolated) ---

proc cloneStr(s: string): string =
  if s.len == 0: return ""
  result = newString(s.len)
  copyMem(addr result[0], unsafeAddr s[0], s.len)

proc cloneEvent(evt: TestEvent): TestEvent =
  result = evt  # shallow copy (increments refcounts)
  result.text = cloneStr(evt.text)
  result.text2 = cloneStr(evt.text2)
  result.text3 = cloneStr(evt.text3)
  result.pieceMap = cloneStr(evt.pieceMap)
  # Deep clone peers
  if evt.peers.len > 0:
    result.peers = newSeq[PeerEntry](evt.peers.len)
    for i in 0 ..< evt.peers.len:
      result.peers[i] = PeerEntry(
        address: cloneStr(evt.peers[i].address),
        clientName: cloneStr(evt.peers[i].clientName),
        flags: cloneStr(evt.peers[i].flags),
        transport: cloneStr(evt.peers[i].transport),
      )
  # Deep clone trackers
  if evt.trackers.len > 0:
    result.trackers = newSeq[TrackerEntry](evt.trackers.len)
    for i in 0 ..< evt.trackers.len:
      result.trackers[i] = TrackerEntry(
        url: cloneStr(evt.trackers[i].url),
        status: cloneStr(evt.trackers[i].status),
        errorText: cloneStr(evt.trackers[i].errorText),
      )
  # Deep clone files
  if evt.files.len > 0:
    result.files = newSeq[tuple[path: string, length: int64]](evt.files.len)
    for i in 0 ..< evt.files.len:
      result.files[i] = (path: cloneStr(evt.files[i].path), length: evt.files[i].length)

# --- Shared state ---

var queue: SpscQueue[TestEvent]
var producerDone: Atomic[bool]
var consumedCount: Atomic[int64]
var droppedCount: Atomic[int64]

# Consumer-side "globals" (like gPeerSnapshots, gTorrents in the bridge)
var gPeers: seq[PeerEntry]
var gTrackers: seq[TrackerEntry]
var gPieceMap: string
var gName: string

# --- Producer thread ---

proc producerThread() {.thread.} =
  {.cast(gcsafe).}:
    for i in 0 ..< NumEvents:
      # Build a TestEvent with lots of strings/seqs (like drainClientEvents does)
      var evt = TestEvent(
        kind: i mod 5,
        torrentId: 1,
        intParam: i,
        floatParam: float(i) * 1.5,
        text: "dht-nodes-" & $i,
        text2: "torrent-name-" & $(i mod 100),
        text3: "total-pieces-" & $i,
        pieceMap: newString(200),
        peers: newSeq[PeerEntry](3 + (i mod 5)),
        trackers: @[
          TrackerEntry(url: "udp://tracker.example.com:6969/announce",
                       status: "ok", errorText: ""),
          TrackerEntry(url: "https://tracker2.example.com/announce",
                       status: if i mod 3 == 0: "error" else: "ok",
                       errorText: if i mod 3 == 0: "timeout after 15s" else: ""),
        ],
        files: @[
          (path: "ubuntu-24.04-desktop-amd64.iso", length: 4_800_000_000'i64),
          (path: "ubuntu-24.04-desktop-amd64.iso.torrent", length: 128_000'i64),
        ],
      )
      for j in 0 ..< evt.pieceMap.len:
        evt.pieceMap[j] = char('0'.ord + (j mod 5))
      for j in 0 ..< evt.peers.len:
        evt.peers[j] = PeerEntry(
          address: $((i * 7 + j) mod 256) & "." & $((i * 3 + j) mod 256) & ".1.1:" & $(6881 + j),
          clientName: "qBittorrent-" & $j,
          flags: "uHXD",
          transport: if j mod 2 == 0: "tcp" else: "utp",
        )

      # Clone and push (like pushEvent does)
      let cloned = cloneEvent(evt)
      if not queue.push(cloned):
        discard droppedCount.fetchAdd(1, moRelaxed)
        # Brief yield to let consumer catch up
        sleep(0)

    producerDone.store(true, moRelease)

# --- Consumer thread ---

proc consumerThread() {.thread.} =
  {.cast(gcsafe).}:
    var totalConsumed: int64 = 0
    while true:
      var events = queue.drainAll()
      if events.len == 0:
        if producerDone.load(moAcquire):
          # Drain one more time to catch stragglers
          events = queue.drainAll()
          if events.len == 0:
            break
        else:
          sleep(0)
          continue

      for i in 0 ..< events.len:
        let evt = addr events[i]
        # Simulate processUiEvents behavior
        case evt.kind
        of 0:
          # Like uiProgress: move peers out, copy other fields
          gPeers = move evt.peers
          gPieceMap = evt.pieceMap
          gName = evt.text2
          if evt.trackers.len > 0:
            gTrackers = evt.trackers
        of 1:
          # Like uiClientReady: copy fields
          gName = evt.text2
        of 2:
          # Like uiPeerConnected: just read
          discard evt.text
        of 3:
          # Like uiError: copy text
          gName = evt.text
        else:
          discard

      totalConsumed += events.len.int64
      # events goes out of scope here — =destroy runs on all TestEvents
      # If any TestEvent's fields are corrupted, we crash here

    consumedCount.store(totalConsumed, moRelease)

# --- Main ---

initSpscQueue[TestEvent](queue)
producerDone.store(false, moRelaxed)
consumedCount.store(0, moRelaxed)
droppedCount.store(0, moRelaxed)

var t1, t2: Thread[void]
createThread(t1, producerThread)
createThread(t2, consumerThread)
joinThread(t1)
joinThread(t2)

let consumed = consumedCount.load(moRelaxed)
let dropped = droppedCount.load(moRelaxed)
echo "Consumed: ", consumed, " Dropped: ", dropped, " Total: ", consumed + dropped
assert consumed + dropped == NumEvents, "consumed + dropped should equal NumEvents"
echo "PASS: multi-threaded SPSC stress test (", NumEvents, " events)"
