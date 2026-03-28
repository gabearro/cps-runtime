## Multi-threaded stress test for the lock-free Mailbox (Treiber stack).
## Mirrors the torrent bridge pattern:
##   - Producer thread: creates events, sends to mailbox (CAS push)
##   - Consumer thread: drains mailbox (atomic exchange), reads data, destroys rest
##
## Verifies that Nim's ARC properly manages ref-counted fields (strings, seqs)
## through the lock-free Treiber stack without heap corruption.
##
## Run with: nim c -r --mm:atomicArc tests/mailbox_mt_stress_test.nim

import std/[atomics, os]

const MailboxMaxCapacity = 8192
const NumEvents = 200_000  # Total events to push

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

  MailboxNode[T] = object
    next: ptr MailboxNode[T]
    value: T

  Mailbox[T] = object
    head: Atomic[pointer]   # ptr MailboxNode[T], Treiber stack top
    count: Atomic[int]      # Approximate count for soft capacity check

proc initMailbox[T](mb: var Mailbox[T]) =
  mb.head.store(nil, moRelaxed)
  mb.count.store(0, moRelaxed)

proc send[T](mb: var Mailbox[T], item: sink T): bool =
  ## Producer: push an item. Lock-free (CAS loop).
  if mb.count.load(moRelaxed) >= MailboxMaxCapacity:
    return false
  let node = cast[ptr MailboxNode[T]](allocShared0(sizeof(MailboxNode[T])))
  copyMem(addr node.value, unsafeAddr item, sizeof(T))
  zeroMem(unsafeAddr item, sizeof(T))
  # CAS-push to Treiber stack
  var oldHead = mb.head.load(moRelaxed)
  while true:
    node.next = cast[ptr MailboxNode[T]](oldHead)
    if mb.head.compareExchangeWeak(oldHead, cast[pointer](node),
                                   moRelease, moRelaxed):
      break
  discard mb.count.fetchAdd(1, moRelaxed)
  true

proc drainAll[T](mb: var Mailbox[T]): seq[T] =
  ## Consumer: atomically take all pending items in FIFO order.
  let head = cast[ptr MailboxNode[T]](mb.head.exchange(nil, moAcquireRelease))
  if head == nil:
    return @[]
  # Count nodes
  var n = 0
  var node = head
  while node != nil:
    inc n
    node = node.next
  # Extract values in reverse (Treiber stack is LIFO, we want FIFO)
  result = newSeq[T](n)
  node = head
  var i = n - 1
  while node != nil:
    let next = node.next
    copyMem(addr result[i], addr node.value, sizeof(T))
    zeroMem(addr node.value, sizeof(T))
    deallocShared(node)
    node = next
    dec i
  discard mb.count.fetchSub(n, moRelaxed)

# --- Shared state ---

var mailbox: Mailbox[TestEvent]
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

      # Send directly (no deep clone needed — atomicArc handles thread safety)
      if not mailbox.send(move evt):
        discard droppedCount.fetchAdd(1, moRelaxed)
        sleep(0)

    producerDone.store(true, moRelease)

# --- Consumer thread ---

proc consumerThread() {.thread.} =
  {.cast(gcsafe).}:
    var totalConsumed: int64 = 0
    while true:
      var events = mailbox.drainAll()
      if events.len == 0:
        if producerDone.load(moAcquire):
          events = mailbox.drainAll()
          if events.len == 0:
            break
        else:
          sleep(0)
          continue

      for i in 0 ..< events.len:
        let evt = addr events[i]
        case evt.kind
        of 0:
          gPeers = move evt.peers
          gPieceMap = evt.pieceMap
          gName = evt.text2
          if evt.trackers.len > 0:
            gTrackers = evt.trackers
        of 1:
          gName = evt.text2
        of 2:
          discard evt.text
        of 3:
          gName = evt.text
        else:
          discard

      totalConsumed += events.len.int64
      # events goes out of scope here — =destroy runs on all TestEvents.
      # If any field's memory is corrupted, we crash here.

    consumedCount.store(totalConsumed, moRelease)

# --- Main ---

initMailbox[TestEvent](mailbox)
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
echo "PASS: Mailbox lock-free multi-threaded stress test (", NumEvents, " events)"
