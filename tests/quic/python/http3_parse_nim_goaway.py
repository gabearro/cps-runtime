import sys

from aioquic._buffer import Buffer

frame = bytes.fromhex(sys.argv[1])
expected_id = int(sys.argv[2])

buf = Buffer(data=frame)
frame_type = buf.pull_uint_var()
frame_len = buf.pull_uint_var()
payload = buf.pull_bytes(frame_len)
payload_buf = Buffer(data=payload)
goaway_id = payload_buf.pull_uint_var()

assert frame_type == 0x07, f"Expected GOAWAY frame, got type={frame_type}"
assert goaway_id == expected_id, f"Unexpected GOAWAY id: {goaway_id}"
print("PYTHON_H3_GOAWAY_PARSE_OK")
