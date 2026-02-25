## HTTP/3 frame codec tests.

import cps/http/shared/http3

block testFrameRoundTrip:
  let settingsPayload = encodeSettingsPayload(@[
    (H3SettingQpackMaxTableCapacity, 0'u64),
    (H3SettingQpackBlockedStreams, 8'u64)
  ])
  let settingsFrame = encodeHttp3Frame(H3FrameSettings, settingsPayload)
  var off = 0
  let decoded = decodeHttp3Frame(settingsFrame, off)
  doAssert off == settingsFrame.len
  doAssert decoded.frameType == H3FrameSettings

  let parsedSettings = decodeSettingsPayload(decoded.payload)
  doAssert parsedSettings.len == 2
  doAssert parsedSettings[0] == (H3SettingQpackMaxTableCapacity, 0'u64)
  doAssert parsedSettings[1] == (H3SettingQpackBlockedStreams, 8'u64)
  echo "PASS: HTTP/3 SETTINGS frame encode/decode"

block testDecodeAllFrames:
  let f1 = encodeHttp3Frame(H3FrameHeaders, @[0x01'u8, 0x02'u8])
  let f2 = encodeHttp3Frame(H3FrameData, @[0xAA'u8, 0xBB'u8, 0xCC'u8])
  let all = f1 & f2
  let frames = decodeAllHttp3Frames(all)
  doAssert frames.len == 2
  doAssert frames[0].frameType == H3FrameHeaders
  doAssert frames[1].frameType == H3FrameData
  doAssert frames[1].payload == @[0xAA'u8, 0xBB'u8, 0xCC'u8]
  echo "PASS: HTTP/3 multi-frame decode"

block testTruncatedFrameRaises:
  var frame = encodeHttp3Frame(H3FrameData, @[0x10'u8, 0x11'u8, 0x12'u8])
  frame.setLen(frame.len - 1)

  var raised = false
  try:
    var off = 0
    discard decodeHttp3Frame(frame, off)
  except ValueError:
    raised = true
  doAssert raised
  echo "PASS: HTTP/3 truncated frame validation"

echo "All HTTP/3 frame codec tests passed"
