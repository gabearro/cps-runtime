#!/usr/bin/env python3
import asyncio
import sys
from typing import Dict, Optional

from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.asyncio.server import serve
from aioquic.h3.connection import H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration


class LiveHttp3ServerProtocol(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._http = H3Connection(self._quic)
        self._requests: Dict[int, Dict[str, object]] = {}

    def _request_for(self, stream_id: int) -> Dict[str, object]:
        if stream_id not in self._requests:
            self._requests[stream_id] = {"headers": [], "body": bytearray()}
        return self._requests[stream_id]

    def _respond(self, stream_id: int) -> None:
        req = self._requests.pop(stream_id, {"headers": [], "body": bytearray()})
        headers = req["headers"]
        body = bytes(req["body"])

        method = ""
        path = ""
        for key, value in headers:
            if key == b":method":
                method = value.decode(errors="ignore")
            elif key == b":path":
                path = value.decode(errors="ignore")

        if method == "GET" and path == "/":
            status = b"200"
            payload = b"python-live-get-ok"
        elif method == "POST" and path == "/":
            status = b"200"
            payload = b"echo:" + body
        else:
            status = b"404"
            payload = b"not-found"

        response_headers = [
            (b":status", status),
            (b"content-type", b"text/plain"),
            (b"content-length", str(len(payload)).encode()),
        ]
        self._http.send_headers(stream_id, response_headers, end_stream=(len(payload) == 0))
        if payload:
            chunk_size = 1024
            offset = 0
            while offset < len(payload):
                next_offset = min(len(payload), offset + chunk_size)
                self._http.send_data(
                    stream_id,
                    payload[offset:next_offset],
                    end_stream=(next_offset == len(payload)),
                )
                offset = next_offset

    def quic_event_received(self, event) -> None:
        for http_event in self._http.handle_event(event):
            if isinstance(http_event, HeadersReceived):
                req = self._request_for(http_event.stream_id)
                req["headers"] = http_event.headers
                if http_event.stream_ended:
                    self._respond(http_event.stream_id)
            elif isinstance(http_event, DataReceived):
                req = self._request_for(http_event.stream_id)
                req["body"].extend(http_event.data)
                if http_event.stream_ended:
                    self._respond(http_event.stream_id)

        self.transmit()


async def run_server(
    cert_file: str,
    key_file: str,
    port_file: Optional[str] = None,
    retry_enabled: bool = False,
) -> None:
    configuration = QuicConfiguration(is_client=False, alpn_protocols=["h3"])
    configuration.load_cert_chain(cert_file, key_file)

    server = await serve(
        "127.0.0.1",
        0,
        configuration=configuration,
        create_protocol=LiveHttp3ServerProtocol,
        retry=retry_enabled,
    )

    sockname = server._transport.get_extra_info("sockname")
    print(f"PORT:{sockname[1]}", flush=True)
    if port_file:
        with open(port_file, "w", encoding="utf-8") as fh:
            fh.write(f"{sockname[1]}\n")
            fh.flush()

    try:
        while True:
            await asyncio.sleep(3600)
    finally:
        server.close()


def main() -> int:
    if len(sys.argv) < 3 or len(sys.argv) > 5:
        print("usage: http3_live_server.py <cert_file> <key_file> [port_file] [--retry]")
        return 2

    cert_file = sys.argv[1]
    key_file = sys.argv[2]
    rest = sys.argv[3:]
    port_file: Optional[str] = None
    if rest and rest[0] != "--retry":
        port_file = rest[0]
        rest = rest[1:]
    retry_enabled = False
    if rest:
        if len(rest) != 1 or rest[0] != "--retry":
            print("unknown option:", " ".join(rest))
            return 2
        retry_enabled = True
    asyncio.run(run_server(cert_file, key_file, port_file, retry_enabled=retry_enabled))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
