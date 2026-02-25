#!/usr/bin/env python3
import asyncio
import hashlib
import ssl
import sys
from typing import Dict, Tuple

from aioquic.asyncio.client import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration


REQUEST_TIMEOUT_SECONDS = 30.0


class LiveHttp3ClientProtocol(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._http = H3Connection(self._quic)
        self._responses: Dict[int, Dict[str, object]] = {}

    async def request(self, method: str, path: str, authority: str, body: bytes = b"") -> Tuple[int, bytes]:
        stream_id = self._quic.get_next_available_stream_id()
        loop = asyncio.get_running_loop()
        done = loop.create_future()
        self._responses[stream_id] = {
            "status": 0,
            "body": bytearray(),
            "done": done,
        }

        headers = [
            (b":method", method.encode()),
            (b":scheme", b"https"),
            (b":authority", authority.encode()),
            (b":path", path.encode()),
        ]
        self._http.send_headers(stream_id, headers, end_stream=(len(body) == 0))

        if body:
            # Split body into many DATA frames so interop tests cover
            # fragmented request bodies and frame reassembly behavior.
            chunk_size = 1024
            offset = 0
            while offset < len(body):
                next_offset = min(len(body), offset + chunk_size)
                self._http.send_data(
                    stream_id,
                    body[offset:next_offset],
                    end_stream=(next_offset == len(body)),
                )
                offset = next_offset

        self.transmit()
        return await done

    def _finish_stream(self, stream_id: int) -> None:
        state = self._responses.get(stream_id)
        if state is None:
            return
        done = state["done"]
        if not done.done():
            done.set_result((int(state["status"]), bytes(state["body"])))
        self._responses.pop(stream_id, None)

    def quic_event_received(self, event) -> None:
        for http_event in self._http.handle_event(event):
            if isinstance(http_event, HeadersReceived):
                state = self._responses.get(http_event.stream_id)
                if state is None:
                    continue
                for key, value in http_event.headers:
                    if key == b":status":
                        state["status"] = int(value.decode())
                if http_event.stream_ended:
                    self._finish_stream(http_event.stream_id)
            elif isinstance(http_event, DataReceived):
                state = self._responses.get(http_event.stream_id)
                if state is None:
                    continue
                state["body"].extend(http_event.data)
                if http_event.stream_ended:
                    self._finish_stream(http_event.stream_id)

        self.transmit()


async def run_live_client(host: str, port: int) -> int:
    config = QuicConfiguration(is_client=True, alpn_protocols=["h3"])
    config.verify_mode = ssl.CERT_NONE
    authority = f"{host}:{port}"

    async with connect(
        host,
        port,
        configuration=config,
        create_protocol=LiveHttp3ClientProtocol,
        wait_connected=True,
    ) as protocol:
        protocol = protocol  # type: LiveHttp3ClientProtocol
        try:
            print("LIVE_STAGE:GET_START", flush=True)
            get_status, get_body = await asyncio.wait_for(
                protocol.request("GET", "/", authority),
                timeout=REQUEST_TIMEOUT_SECONDS,
            )
            print("LIVE_STAGE:GET_DONE", flush=True)
            post_payload = b"python-live-post-body:" + (b"x" * 4096)
            print("LIVE_STAGE:POST_START", flush=True)
            post_status, post_body = await asyncio.wait_for(
                protocol.request("POST", "/", authority, post_payload),
                timeout=REQUEST_TIMEOUT_SECONDS,
            )
            print("LIVE_STAGE:POST_DONE", flush=True)
        except Exception as exc:  # noqa: BLE001
            print(f"LIVE_CLIENT_ERROR:{exc!r}", flush=True)
            return 1

        print(f"LIVE_GET_STATUS:{get_status}", flush=True)
        print(f"LIVE_GET_BODY:{get_body.decode(errors='replace')}", flush=True)
        print(f"LIVE_POST_STATUS:{post_status}", flush=True)
        print(f"LIVE_POST_BODY_LEN:{len(post_body)}", flush=True)
        print(f"LIVE_POST_BODY_SHA256:{hashlib.sha256(post_body).hexdigest()}", flush=True)

        expected_post = b"echo:" + post_payload
        if get_status != 200 or get_body != b"nim-live-get-ok":
            return 1
        if post_status != 200 or post_body != expected_post:
            return 1

        print("PYTHON_H3_LIVE_CLIENT_OK", flush=True)
        return 0


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: http3_live_client.py <host> <port>")
        return 2

    host = sys.argv[1]
    port = int(sys.argv[2])
    return asyncio.run(run_live_client(host, port))


if __name__ == "__main__":
    raise SystemExit(main())
