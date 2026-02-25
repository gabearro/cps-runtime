import sys

from aioquic._buffer import Buffer

goaway_id = int(sys.argv[1])

payload_buf = Buffer(capacity=32)
payload_buf.push_uint_var(goaway_id)
payload = bytes(payload_buf.data)

frame_buf = Buffer(capacity=64)
frame_buf.push_uint_var(0x07)  # GOAWAY
frame_buf.push_uint_var(len(payload))
frame_buf.push_bytes(payload)
print("FRAMEHEX:" + bytes(frame_buf.data).hex())
