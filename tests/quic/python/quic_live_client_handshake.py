#!/usr/bin/env python3
import asyncio
import socket
import ssl
import sys
from typing import Optional

from aioquic.asyncio import QuicConnectionProtocol
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.connection import QuicConnection
from aioquic.quic.events import StreamDataReceived


class LiveQuicClientProtocol(QuicConnectionProtocol):
    def __init__(self, connection: QuicConnection) -> None:
        super().__init__(connection)
        self.echo_stream_id: Optional[int] = None
        self.echo_done: Optional[asyncio.Future] = None
        self.echo_payload = bytearray()

    def begin_echo_wait(self, stream_id: int) -> asyncio.Future:
        self.echo_stream_id = stream_id
        self.echo_done = asyncio.get_running_loop().create_future()
        self.echo_payload = bytearray()
        return self.echo_done

    def quic_event_received(self, event) -> None:
        if isinstance(event, StreamDataReceived):
            if self.echo_done is not None and event.stream_id == self.echo_stream_id:
                self.echo_payload.extend(event.data)
                if event.end_stream and not self.echo_done.done():
                    self.echo_done.set_result(bytes(self.echo_payload))


async def run_client(host: str, port: int) -> None:
    config = QuicConfiguration(is_client=True, alpn_protocols=["h3"])
    config.verify_mode = ssl.CERT_NONE
    config.server_name = host

    loop = asyncio.get_running_loop()
    infos = await loop.getaddrinfo(host, port, type=socket.SOCK_DGRAM)
    addr = infos[0][4]
    if len(addr) == 2:
        addr = ("::ffff:" + addr[0], addr[1], 0, 0)

    connection = QuicConnection(configuration=config)
    sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
    sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    sock.bind(("::", 0, 0, 0))

    transport, protocol = await loop.create_datagram_endpoint(
        lambda: LiveQuicClientProtocol(connection),
        sock=sock,
    )
    protocol = protocol  # type: LiveQuicClientProtocol
    protocol.connect(addr, transmit=True)
    await asyncio.wait_for(protocol.wait_connected(), timeout=5.0)

    # Send one stream frame and validate a server echo to exercise
    # post-handshake stream data in both directions.
    stream_id = protocol._quic.get_next_available_stream_id()  # noqa: SLF001
    echo_wait = protocol.begin_echo_wait(stream_id)
    payload = b"ping-live"
    protocol._quic.send_stream_data(stream_id, payload, end_stream=True)  # noqa: SLF001
    protocol.transmit()
    echoed = await asyncio.wait_for(echo_wait, timeout=5.0)
    if echoed != b"nim-echo:" + payload:
        raise RuntimeError(f"unexpected echo payload: {echoed!r}")
    print("PYTHON_QUIC_LIVE_STREAM_ECHO_OK", flush=True)

    # Emit success marker before waiting for graceful close paths.
    print("PYTHON_QUIC_LIVE_CLIENT_OK", flush=True)

    protocol.close()
    transport.close()


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: quic_live_client_handshake.py <host> <port>")
        return 2
    host = sys.argv[1]
    port = int(sys.argv[2])
    try:
        asyncio.run(run_client(host, port))
        return 0
    except Exception as exc:  # pragma: no cover - fixture diagnostic path
        print(
            f"PYTHON_QUIC_LIVE_CLIENT_ERR:{type(exc).__name__}:{repr(exc)}",
            flush=True,
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
