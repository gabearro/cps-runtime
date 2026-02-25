import sys

from aioquic._buffer import Buffer
from aioquic.quic.packet import pull_quic_header

packet = bytes.fromhex(sys.argv[1])
buf = Buffer(data=packet)
h = pull_quic_header(buf, host_cid_length=None)
assert h.packet_type.name.upper() == "RETRY", f"Unexpected packet type: {h.packet_type}"
assert h.version == 1, f"Unexpected version: {h.version}"
print("PYTHON_RETRY_PARSE_OK")
