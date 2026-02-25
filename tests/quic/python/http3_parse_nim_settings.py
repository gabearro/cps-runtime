import sys

from aioquic._buffer import Buffer
from aioquic.h3.connection import parse_settings

frame = bytes.fromhex(sys.argv[1])
buf = Buffer(data=frame)
frame_type = buf.pull_uint_var()
frame_len = buf.pull_uint_var()
payload = buf.pull_bytes(frame_len)

assert frame_type == 0x04, f"Expected SETTINGS frame, got type={frame_type}"
settings = parse_settings(payload)
assert settings.get(0x01) == 0, f"Unexpected QPACK table capacity: {settings}"
assert settings.get(0x06) == 65536, f"Unexpected max field section size: {settings}"
assert settings.get(0x08) == 1, f"Unexpected connect-protocol setting: {settings}"
assert settings.get(0x33) == 1, f"Unexpected H3_DATAGRAM setting: {settings}"
print("PYTHON_H3_PARSE_OK")
