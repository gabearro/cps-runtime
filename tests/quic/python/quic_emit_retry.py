import sys

from aioquic.quic.packet import encode_quic_retry

version = 1
source_cid = bytes.fromhex(sys.argv[1])
destination_cid = bytes.fromhex(sys.argv[2])
original_destination_cid = bytes.fromhex(sys.argv[3])
retry_token = bytes.fromhex(sys.argv[4])

pkt = encode_quic_retry(
    version=version,
    source_cid=source_cid,
    destination_cid=destination_cid,
    original_destination_cid=original_destination_cid,
    retry_token=retry_token,
)
print("RETRYHEX:" + pkt.hex())
