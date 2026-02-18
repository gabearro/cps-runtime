#!/usr/bin/env python3
"""HTTP/2 test server using h2 library with self-signed TLS certificate."""

import ssl
import os
import sys
import tempfile
import subprocess
import socket
import json
import threading

try:
    import h2.connection
    import h2.config
    import h2.events
except ImportError:
    print("ERROR: h2 library not installed. Install with: pip install h2", flush=True)
    sys.exit(1)

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8444

# Generate a self-signed certificate
cert_dir = tempfile.mkdtemp()
cert_file = os.path.join(cert_dir, "cert.pem")
key_file = os.path.join(cert_dir, "key.pem")

subprocess.run([
    "openssl", "req", "-x509", "-newkey", "rsa:2048",
    "-keyout", key_file, "-out", cert_file,
    "-days", "1", "-nodes",
    "-subj", "/CN=localhost"
], check=True, capture_output=True)


def handle_client(sock):
    """Handle a single HTTP/2 client connection."""
    config = h2.config.H2Configuration(client_side=False)
    conn = h2.connection.H2Connection(config=config)
    conn.initiate_connection()
    sock.sendall(conn.data_to_send())

    # Track request data per stream
    request_data = {}

    while True:
        try:
            data = sock.recv(65535)
            if not data:
                break

            events = conn.receive_data(data)

            for event in events:
                if isinstance(event, h2.events.RequestReceived):
                    headers = dict(event.headers)
                    stream_id = event.stream_id
                    request_data[stream_id] = {
                        "headers": headers,
                        "body": b"",
                    }

                elif isinstance(event, h2.events.DataReceived):
                    stream_id = event.stream_id
                    if stream_id in request_data:
                        request_data[stream_id]["body"] += event.data
                    conn.acknowledge_received_data(
                        event.flow_controlled_length, stream_id
                    )

                elif isinstance(event, h2.events.StreamEnded):
                    stream_id = event.stream_id
                    if stream_id not in request_data:
                        continue

                    req = request_data[stream_id]
                    headers = req["headers"]
                    method = headers.get(b":method", b"GET").decode()
                    path = headers.get(b":path", b"/").decode()

                    if path == "/json":
                        body = json.dumps({
                            "message": "hello from http/2",
                            "path": path,
                            "stream_id": stream_id
                        })
                    elif method == "POST":
                        body = json.dumps({
                            "echo": req["body"].decode(),
                            "method": "POST",
                            "stream_id": stream_id
                        })
                    else:
                        body = f"Hello from HTTP/2! Path: {path} Stream: {stream_id}"

                    response_headers = [
                        (":status", "200"),
                        ("content-type", "text/plain" if path != "/json" else "application/json"),
                        ("content-length", str(len(body))),
                        ("x-protocol", "h2"),
                        ("x-stream-id", str(stream_id)),
                    ]

                    conn.send_headers(stream_id, response_headers)
                    conn.send_data(stream_id, body.encode(), end_stream=True)

                    del request_data[stream_id]

                elif isinstance(event, h2.events.WindowUpdated):
                    pass

            out_data = conn.data_to_send()
            if out_data:
                sock.sendall(out_data)

        except Exception as e:
            break

    sock.close()


# Set up TLS context
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert_file, key_file)
context.set_alpn_protocols(["h2"])

# Create server socket
server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server_sock.bind(("127.0.0.1", PORT))
server_sock.listen(5)

tls_server_sock = context.wrap_socket(server_sock, server_side=True)

# Signal that server is ready
print(f"READY:{PORT}", flush=True)
print(f"CERT:{cert_file}", flush=True)

try:
    while True:
        client_sock, addr = tls_server_sock.accept()
        t = threading.Thread(target=handle_client, args=(client_sock,), daemon=True)
        t.start()
except KeyboardInterrupt:
    pass
finally:
    tls_server_sock.close()
    os.unlink(cert_file)
    os.unlink(key_file)
    os.rmdir(cert_dir)
