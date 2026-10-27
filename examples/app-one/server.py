"""Minimal echo backend for routing tests (Python standard library only).

Every request gets a JSON body describing what this backend received, so a
caller can verify which backend answered, which path arrived upstream (after any
rewrite) and which headers the proxy forwarded.

A request carrying "Upgrade: websocket" gets a valid 101 handshake response,
after which the connection is closed. That is enough to prove that the proxy
passes upgrades through; it is not a full WebSocket implementation.
"""

import base64
import hashlib
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVICE_NAME = os.environ.get("SERVICE_NAME", "echo")
PORT = int(os.environ.get("PORT", "8000"))
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class EchoHandler(BaseHTTPRequestHandler):
    server_version = "echo"
    sys_version = ""
    protocol_version = "HTTP/1.1"

    def _handle(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)

        if self.headers.get("Upgrade", "").lower() == "websocket":
            return self._websocket_handshake()

        body = json.dumps(
            {
                "service": SERVICE_NAME,
                "method": self.command,
                "path": self.path,
                "host": self.headers.get("Host"),
                "peer": self.client_address[0],
                "headers": {k.lower(): v for k, v in self.headers.items()},
            },
            indent=2,
        ).encode() + b"\n"
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Served-By", SERVICE_NAME)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _websocket_handshake(self):
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.send_header("X-Served-By", SERVICE_NAME)
        self.end_headers()
        self.close_connection = True

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = _handle

    def log_message(self, fmt, *args):
        if self.path != "/healthz":
            super().log_message(fmt, *args)


if __name__ == "__main__":
    print(f"{SERVICE_NAME} listening on :{PORT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), EchoHandler).serve_forever()
