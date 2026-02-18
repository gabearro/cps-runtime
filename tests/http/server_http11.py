#!/usr/bin/env python3
"""HTTP/1.1 test server with self-signed TLS certificate."""

import http.server
import ssl
import os
import sys
import tempfile
import subprocess
import json

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8443

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

class TestHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path == "/json":
            body = json.dumps({"message": "hello from http/1.1", "path": self.path})
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-Protocol", "HTTP/1.1")
            self.end_headers()
            self.wfile.write(body.encode())
        elif self.path == "/chunked":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("X-Protocol", "HTTP/1.1")
            self.end_headers()
            chunks = ["Hello ", "World ", "from ", "chunked!"]
            for chunk in chunks:
                self.wfile.write(f"{len(chunk):x}\r\n{chunk}\r\n".encode())
            self.wfile.write(b"0\r\n\r\n")
        else:
            body = f"Hello from HTTP/1.1! Path: {self.path}"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-Protocol", "HTTP/1.1")
            self.end_headers()
            self.wfile.write(body.encode())

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length else b""
        response = json.dumps({"echo": body.decode(), "method": "POST"})
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.send_header("X-Protocol", "HTTP/1.1")
        self.end_headers()
        self.wfile.write(response.encode())

    def log_message(self, format, *args):
        pass  # Suppress logs

context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert_file, key_file)
# Set ALPN to only offer http/1.1
context.set_alpn_protocols(["http/1.1"])

server = http.server.HTTPServer(("127.0.0.1", PORT), TestHandler)
server.socket = context.wrap_socket(server.socket, server_side=True)

# Signal that server is ready
print(f"READY:{PORT}", flush=True)
print(f"CERT:{cert_file}", flush=True)

try:
    server.serve_forever()
except KeyboardInterrupt:
    pass
finally:
    server.server_close()
    os.unlink(cert_file)
    os.unlink(key_file)
    os.rmdir(cert_dir)
