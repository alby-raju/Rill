"""Loopback fixture for transport integration tests. No external service needed."""

import base64
import gzip
import hashlib
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer
from urllib.parse import parse_qs


class LoopbackServer(ThreadingHTTPServer):
    def server_bind(self):
        # Avoid HTTPServer's reverse-DNS lookup on hosted runner networks.
        TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]


class Handler(BaseHTTPRequestHandler):
    def do_echo(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length > 1024 * 1024:
            self.send_error(413)
            return
        payload = self.rfile.read(length)
        if self.path.startswith("/oauth/"):
            fields = parse_qs(payload.decode(), keep_blank_values=True)
            valid_client = (
                self.headers.get("Authorization")
                == "Basic " + base64.b64encode(b"fixture-client:fixture-secret").decode()
            )
            valid_client = valid_client or fields.get("client_secret") == ["fixture-secret"]
            valid_code = fields.get("code") == ["fixture-code"] and fields.get("client_id") == [
                "fixture-client"
            ]
            verifier = fields.get("code_verifier", [""])[0]
            challenge = (
                base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
                .decode()
                .rstrip("=")
            )
            valid_code = valid_code and challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
            valid = (fields.get("grant_type") == ["client_credentials"] and valid_client) or (
                fields.get("grant_type") == ["authorization_code"] and valid_code
            )
            status = 200 if valid else 400
            body = json.dumps(
                {"access_token": "fixture-access-token", "token_type": "Bearer", "expires_in": 3600}
                if valid
                else {"error": "invalid_client", "error_description": "SEEDED_SECRET"}
            ).encode()
            if self.path == "/oauth/redirect":
                status = 302
            if self.path == "/oauth/oversized":
                body = b"x" * 65537
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            if status == 302:
                self.send_header("Location", "/oauth/token")
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if self.path.startswith("/redirect-"):
            self.send_response(307)
            self.send_header(
                "Location", "/echo" if self.path == "/redirect-same" else "http://127.0.0.1:9/echo"
            )
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = json.dumps(
            {
                "method": self.command,
                "path": self.path,
                "headers": dict(self.headers),
                "body": base64.b64encode(payload).decode(),
            }
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_POST = do_echo
    do_PUT = do_echo
    do_PATCH = do_echo
    do_DELETE = do_echo
    do_OPTIONS = do_echo

    def do_GET(self):
        if self.path.startswith("/gzip/"):
            count = min(int(self.path.rsplit("/", 1)[1]), 1024 * 1024)
            body = gzip.compress(b"x" * count)
            self.send_response(200)
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/slow-chunks":
            self.protocol_version = "HTTP/1.1"
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                self.wfile.write(b"1\r\nx\r\n")
                self.wfile.flush()
                time.sleep(5)
                self.wfile.write(b"1\r\ny\r\n0\r\n\r\n")
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if self.path.startswith("/echo"):
            return self.do_echo()
        if self.path.startswith(("/bytes/", "/chunked/", "/unknown/")):
            mode, count = self.path.strip("/").split("/")
            count = min(int(count), 1024 * 1024)
            if mode == "chunked":
                self.protocol_version = "HTTP/1.1"
            self.send_response(200)
            if mode == "bytes":
                self.send_header("Content-Length", str(count))
            elif mode == "chunked":
                self.protocol_version = "HTTP/1.1"
                self.send_header("Transfer-Encoding", "chunked")
            else:
                self.send_header("Connection", "close")
                self.close_connection = True
            self.end_headers()
            try:
                while count:
                    chunk = b"x" * min(count, 512)
                    count -= len(chunk)
                    if mode == "chunked":
                        self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                    else:
                        self.wfile.write(chunk)
                if mode == "chunked":
                    self.wfile.write(b"0\r\n\r\n")
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if self.path == "/slow":
            time.sleep(5)
        if self.path == "/large":
            self.send_response(200)
            self.send_header("Content-Length", str(17 * 1024 * 1024))
            self.end_headers()
            try:
                for _ in range(17):
                    self.wfile.write(b"x" * (1024 * 1024))
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        body = b'{"message":"hello from fixture"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Fixture", "Rill")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    import sys

    server = LoopbackServer(
        ("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 18749), Handler
    )
    print(f"Listening on http://127.0.0.1:{server.server_port}", flush=True)
    server.serve_forever()
