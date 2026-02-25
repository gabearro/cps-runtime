import sys

from aioquic._buffer import Buffer
from aioquic.quic.packet import pull_quic_header

packet = bytes.fromhex(sys.argv[1])
expected_type = sys.argv[2].upper()
host_cid_length = int(sys.argv[3]) if len(sys.argv) > 3 else None

buf = Buffer(data=packet)
h = pull_quic_header(buf, host_cid_length=host_cid_length)
actual = h.packet_type.name.upper()
assert actual == expected_type, f"Expected {expected_type}, got {actual}"
print("PYTHON_QUIC_HEADER_OK:" + actual)
