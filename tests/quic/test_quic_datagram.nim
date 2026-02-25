## QUIC DATAGRAM extension tests.

import cps/quic

block testDatagramFrameCodec:
  let frame = QuicFrame(kind: qfkDatagram, datagramData: @[0xDE'u8, 0xAD'u8, 0xBE'u8, 0xEF'u8])
  let enc = encodeFrame(frame)
  var off = 0
  let dec = parseFrame(enc, off)
  doAssert off == enc.len
  doAssert dec.kind == qfkDatagram
  doAssert dec.datagramData == frame.datagramData
  echo "PASS: QUIC DATAGRAM frame codec"

block testDatagramQueueOnConnection:
  var conn = newQuicConnection(qcrServer, @[0xAA'u8], @[0xBB'u8], "127.0.0.1", 4433)
  conn.applyReceivedFrame(QuicFrame(kind: qfkDatagram, datagramData: @[1'u8, 2, 3]))
  let queued = conn.popIncomingDatagrams()
  doAssert queued.len == 1
  doAssert queued[0] == @[1'u8, 2, 3]
  echo "PASS: QUIC DATAGRAM delivery to connection queue"

block testDatagramQueueIsBounded:
  var conn = newQuicConnection(qcrServer, @[0x11'u8], @[0x22'u8], "127.0.0.1", 4433)
  let payload = newSeq[byte](8192)
  let attempts = QuicMaxIncomingDatagramQueueLen * 8
  for _ in 0 ..< attempts:
    conn.applyReceivedFrame(QuicFrame(kind: qfkDatagram, datagramData: payload))

  let queued = conn.popIncomingDatagrams()
  var totalBytes = 0
  for d in queued:
    totalBytes += d.len
  doAssert queued.len <= QuicMaxIncomingDatagramQueueLen
  doAssert totalBytes <= QuicMaxIncomingDatagramQueueBytes
  doAssert queued.len < attempts
  doAssert conn.popIncomingDatagrams().len == 0
  echo "PASS: QUIC DATAGRAM queue is bounded by count and bytes"

echo "All QUIC DATAGRAM tests passed"
