import socket
import sys
import time

from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.connection import QuicConnection

host = "127.0.0.1"
port = int(sys.argv[1])

cfg = QuicConfiguration(is_client=True, alpn_protocols=["h3"])
conn = QuicConnection(configuration=cfg)
now = time.time()
conn.connect((host, port), now=now)
datagrams = conn.datagrams_to_send(now)
assert datagrams, "No QUIC datagrams produced by client"

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(2.0)
for data, _ in datagrams:
    sock.sendto(data, (host, port))

response, _ = sock.recvfrom(65535)
conn.receive_datagram(response, (host, port), now=time.time())

ok = False
reason = ""
while True:
    ev = conn.next_event()
    if ev is None:
        break
    if ev.__class__.__name__ == "ConnectionTerminated":
        reason = getattr(ev, "reason_phrase", "")
        if "common protocol version" in reason.lower():
            ok = True

assert ok, f"Expected version-negotiation termination, got reason={reason!r}"
print("PYTHON_QUIC_CLIENT_VN_OK")
