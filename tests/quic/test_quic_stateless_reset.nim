## QUIC stateless reset helper tests.

import cps/quic

block testStatelessResetGenerationAndDetection:
  let token = @[0x00'u8, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
  let packet = generateStatelessReset(token, 48)
  doAssert packet.len == 48
  doAssert (packet[0] and 0x40'u8) == 0x40'u8
  doAssert isStatelessResetCandidate(packet, token)

  var tampered = packet
  tampered[^1] = tampered[^1] xor 0xFF
  doAssert not isStatelessResetCandidate(tampered, token)
  echo "PASS: QUIC stateless reset generation and candidate detection"

block testStatelessResetValidationErrors:
  var raised = false
  try:
    discard generateStatelessReset(@[0x01'u8, 0x02], 32)
  except ValueError:
    raised = true
  doAssert raised

  raised = false
  let token = @[0x10'u8, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
                0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F]
  try:
    discard generateStatelessReset(token, 20)
  except ValueError:
    raised = true
  doAssert raised
  echo "PASS: QUIC stateless reset input validation"

echo "All QUIC stateless reset tests passed"
