import asyncio
import sys
from aioquic.asyncio import serve
from aioquic.quic.configuration import QuicConfiguration


async def main(cert_path: str, key_path: str, port_file: str = "") -> None:
    cfg = QuicConfiguration(is_client=False, alpn_protocols=["h3"])
    cfg.load_cert_chain(cert_path, key_path)
    server = await serve("127.0.0.1", 0, configuration=cfg)
    port = server._transport.get_extra_info("sockname")[1]
    print(f"PORT:{port}", flush=True)
    if port_file:
      with open(port_file, "w", encoding="utf-8") as fh:
        fh.write(f"{port}\n")
        fh.flush()
    try:
      while True:
        await asyncio.sleep(3600)
    finally:
      server.close()


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
      print("usage: quic_vn_server.py <cert_file> <key_file> [port_file]")
      raise SystemExit(2)
    asyncio.run(main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else ""))
