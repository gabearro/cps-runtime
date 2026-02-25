import cps/http/shared/http3_connection
import cps/http/shared/http3

let conn = newHttp3Connection(isClient = true, useRfcQpackWire = true)

let blockedHeaderBlock = @[0x02'u8, 0x00'u8, 0x80'u8]
let payload = encodeHttp3Frame(H3FrameHeaders, blockedHeaderBlock)

discard conn.processRequestStreamData(0'u64, payload, allowInformationalHeaders = true)
echo "blocked_after_first=", conn.qpackDecoder.blockedStreams

discard conn.processRequestStreamData(0'u64, @[], allowInformationalHeaders = true)
echo "blocked_after_retry_no_updates=", conn.qpackDecoder.blockedStreams

discard conn.finalizeRequestStream(0'u64, allowInformationalHeaders = true)
echo "blocked_after_finalize_no_updates=", conn.qpackDecoder.blockedStreams
