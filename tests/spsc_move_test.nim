## Test: Do =destroy / =sink hooks fire correctly through ptr UncheckedArray[T]?
## This verifies whether Nim's ARC properly manages ref-counted fields
## (strings, seqs) stored in raw pointer memory (ptr UncheckedArray[T]).

import std/atomics

var destroyCount: int = 0
var sinkCount: int = 0

type
  Payload = object
    name: string
    data: seq[string]

# proc `=destroy`(p: Payload) =
#   inc destroyCount
#   # Let the default destroy run for the fields

proc test_move_into_unchecked_array() =
  ## Test: moving a Payload into a ptr UncheckedArray slot, then moving it back out.
  ## Verifies no double-free or leak occurs.
  let buf = cast[ptr UncheckedArray[Payload]](allocShared0(8 * sizeof(Payload)))

  # Push: move into slot 0
  var item1 = Payload(name: "hello-world-test-string-that-is-long-enough-to-allocate",
                       data: @["alpha", "beta", "gamma"])
  buf[0] = move item1
  # item1 should now be zeroed (wasMoved)
  assert item1.name.len == 0, "item1.name should be empty after move"
  assert item1.data.len == 0, "item1.data should be empty after move"

  # Drain: move out of slot 0 into a seq
  var result = newSeq[Payload](1)
  result[0] = move(buf[0])
  # buf[0] should now be zeroed
  assert buf[0].name.len == 0, "buf[0].name should be empty after move"
  assert buf[0].data.len == 0, "buf[0].data should be empty after move"

  # Verify the result has the data
  assert result[0].name == "hello-world-test-string-that-is-long-enough-to-allocate"
  assert result[0].data.len == 3
  assert result[0].data[0] == "alpha"

  # Push again to the same slot (simulates queue wrap-around)
  var item2 = Payload(name: "second-item-with-different-content",
                       data: @["delta", "epsilon"])
  buf[0] = move item2

  # Drain again
  var result2 = newSeq[Payload](1)
  result2[0] = move(buf[0])
  assert result2[0].name == "second-item-with-different-content"
  assert result2[0].data.len == 2

  # Let result and result2 go out of scope — their destructors should
  # properly free the strings/seqs without crashing.
  deallocShared(buf)
  echo "PASS: basic move into/out of UncheckedArray"

proc test_push_to_full_slot_without_drain() =
  ## Test: what happens if we assign to a slot that already has data
  ## (without draining first)? This SHOULD call =destroy on the old value.
  let buf = cast[ptr UncheckedArray[Payload]](allocShared0(2 * sizeof(Payload)))

  buf[0] = Payload(name: "first-value-in-slot-zero",
                    data: @["a", "b"])

  # Overwrite without draining — old value should be destroyed
  buf[0] = Payload(name: "second-value-overwrites-first",
                    data: @["c", "d", "e"])

  assert buf[0].name == "second-value-overwrites-first"
  assert buf[0].data.len == 3

  # Clean up
  var tmp = move(buf[0])  # move out to properly destroy
  deallocShared(buf)
  echo "PASS: overwrite slot in UncheckedArray"

proc test_sink_param_on_early_return() =
  ## Test: when a proc with sink T returns early without using the value,
  ## is the value properly destroyed?
  proc pushMaybe(buf: ptr UncheckedArray[Payload], item: sink Payload, shouldPush: bool): bool =
    if not shouldPush:
      return false  # item should be destroyed here
    buf[0] = move item
    true

  let buf = cast[ptr UncheckedArray[Payload]](allocShared0(2 * sizeof(Payload)))

  # Push that fails — item should be properly destroyed
  let ok1 = pushMaybe(buf, Payload(name: "this-should-be-destroyed",
                                    data: @["x", "y", "z"]), false)
  assert not ok1

  # Push that succeeds
  let ok2 = pushMaybe(buf, Payload(name: "this-should-be-stored",
                                    data: @["1", "2"]), true)
  assert ok2
  assert buf[0].name == "this-should-be-stored"

  var tmp = move(buf[0])
  deallocShared(buf)
  echo "PASS: sink param destroyed on early return"

proc test_concurrent_pattern() =
  ## Test: simulates the SPSC push/drain cycle with multiple items,
  ## mirroring the real UiEvent flow.
  let buf = cast[ptr UncheckedArray[Payload]](allocShared0(4 * sizeof(Payload)))
  var head: Atomic[int64]
  var tail: Atomic[int64]
  head.store(0, moRelaxed)
  tail.store(0, moRelaxed)

  # Push 4 items
  for i in 0 ..< 4:
    let t = tail.load(moRelaxed)
    var p = Payload(name: "item-" & $i, data: @["data-" & $i])
    buf[int(t) and 3] = move p
    tail.store(t + 1, moRelease)

  # Drain all 4
  let h = head.load(moRelaxed)
  let t = tail.load(moAcquire)
  let count = int(t - h)
  assert count == 4
  var items = newSeq[Payload](count)
  for i in 0 ..< count:
    let idx = int(h + i.int64) and 3
    items[i] = move(buf[idx])
  head.store(t, moRelease)

  # Verify
  for i in 0 ..< 4:
    assert items[i].name == "item-" & $i
    assert items[i].data[0] == "data-" & $i

  # Push 4 more (wrap-around)
  for i in 4 ..< 8:
    let t2 = tail.load(moRelaxed)
    var p = Payload(name: "item-" & $i, data: @["data-" & $i])
    buf[int(t2) and 3] = move p
    tail.store(t2 + 1, moRelease)

  # Drain again
  let h2 = head.load(moRelaxed)
  let t2 = tail.load(moAcquire)
  let count2 = int(t2 - h2)
  assert count2 == 4
  var items2 = newSeq[Payload](count2)
  for i in 0 ..< count2:
    let idx = int(h2 + i.int64) and 3
    items2[i] = move(buf[idx])
  head.store(t2, moRelease)

  for i in 0 ..< 4:
    assert items2[i].name == "item-" & $(i + 4)

  # All items/items2 go out of scope — destructors run
  deallocShared(buf)
  echo "PASS: SPSC push/drain cycle with wrap-around"

proc test_complex_payload() =
  ## Test with a payload similar to UiEvent — many string/seq fields.
  type
    Entry = object
      address: string
      clientName: string
      flags: string

    BigPayload = object
      text: string
      text2: string
      text3: string
      peers: seq[Entry]
      pieceMap: string
      files: seq[tuple[path: string, length: int64]]
      trackers: seq[string]

  let buf = cast[ptr UncheckedArray[BigPayload]](allocShared0(4 * sizeof(BigPayload)))

  # Push a big payload
  var bp = BigPayload(
    text: "hello",
    text2: "world",
    text3: "test",
    peers: @[
      Entry(address: "1.2.3.4:5678", clientName: "qBittorrent", flags: "uHXD"),
      Entry(address: "5.6.7.8:1234", clientName: "Transmission", flags: "uHXP"),
    ],
    pieceMap: newString(1924),  # typical piece map size
    files: @[
      (path: "ubuntu-24.04.iso", length: 4800000000'i64),
    ],
    trackers: @["udp://tracker.example.com:6969/announce",
                "https://tracker2.example.com/announce"],
  )
  for i in 0 ..< bp.pieceMap.len:
    bp.pieceMap[i] = char('0'.ord + (i mod 5))

  buf[0] = move bp

  # Drain
  var items = newSeq[BigPayload](1)
  items[0] = move(buf[0])

  assert items[0].peers.len == 2
  assert items[0].peers[0].address == "1.2.3.4:5678"
  assert items[0].pieceMap.len == 1924
  assert items[0].files[0].path == "ubuntu-24.04.iso"
  assert items[0].trackers.len == 2

  # Move peers out (like the bridge does with peerSnapshot)
  var globalPeers = move items[0].peers
  assert items[0].peers.len == 0  # moved out
  assert globalPeers.len == 2

  # Now items[0] gets destroyed — peers field is zeroed, should be no-op
  deallocShared(buf)
  echo "PASS: complex payload with nested strings/seqs"

# Stress test: many push/drain cycles
proc test_stress() =
  let buf = cast[ptr UncheckedArray[Payload]](allocShared0(64 * sizeof(Payload)))
  var head: Atomic[int64]
  var tail: Atomic[int64]
  head.store(0, moRelaxed)
  tail.store(0, moRelaxed)

  for cycle in 0 ..< 10000:
    # Push a batch
    let batchSize = (cycle mod 7) + 1
    for i in 0 ..< batchSize:
      let t = tail.load(moRelaxed)
      let h = head.load(moAcquire)
      if t - h >= 64:
        break
      var p = Payload(
        name: "cycle-" & $cycle & "-item-" & $i,
        data: @["data-" & $cycle & "-" & $i, "extra-" & $i]
      )
      buf[int(t) and 63] = move p
      tail.store(t + 1, moRelease)

    # Drain all
    let h = head.load(moRelaxed)
    let t = tail.load(moAcquire)
    let count = int(t - h)
    if count > 0:
      var items = newSeq[Payload](count)
      for i in 0 ..< count:
        let idx = int(h + i.int64) and 63
        items[i] = move(buf[idx])
      head.store(t, moRelease)
      # items destroyed here

  deallocShared(buf)
  echo "PASS: stress test (10000 cycles)"

# Run all tests
test_move_into_unchecked_array()
test_push_to_full_slot_without_drain()
test_sink_param_on_early_return()
test_concurrent_pattern()
test_complex_payload()
test_stress()
echo "\nAll SPSC move tests passed!"
