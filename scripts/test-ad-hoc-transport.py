#!/usr/bin/env python3
"""Exercise ad-hoc CLI transport interactions against disposable loopback fixtures."""

import argparse
import base64
import json
import os
import select
import signal
import socket
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import StreamRequestHandler, ThreadingTCPServer
from urllib.parse import urlsplit


def check_stream(cli, base):
    with subprocess.Popen(
        [cli, "request", base + "/slow-chunks", "--stream"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ) as child:
        try:
            ready, _, _ = select.select([child.stdout], [], [], 4)
            assert ready and os.read(child.stdout.fileno(), 1) == b"x", "streamed byte arrived late"
            assert child.poll() is None, "response completed before the first streamed byte"
            child.send_signal(signal.SIGINT)
            assert child.communicate(timeout=5)[0] == b""
            assert child.returncode == 130, "canceled streaming must exit 130"
        finally:
            if child.poll() is None:
                child.kill()

    with subprocess.Popen(
        [cli, "request", base + "/large", "--stream"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ) as child:
        try:
            assert select.select([child.stdout], [], [], 4)[0], "large stream produced no data"
            child.send_signal(signal.SIGINT)
            assert child.wait(timeout=5) == 130, "a blocked stdout pipe prevented cancellation"
        finally:
            if child.poll() is None:
                child.kill()


def check_resume_cancellation(cli, base):
    with tempfile.TemporaryDirectory() as directory:
        destination = Path(directory) / "partial"
        destination.write_bytes(b"first-")
        with subprocess.Popen(
            [
                cli,
                "request",
                base + "/resume-slow",
                "--download",
                destination,
                "--resume-etag",
                '"fixture"',
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        ) as child:
            try:
                # A response marker is written only after a matching Range and If-Range arrive.
                marker = subprocess.run(
                    [cli, "request", base + "/resume-ready", "--body-stdout"],
                    capture_output=True,
                    timeout=5,
                    check=True,
                )
                assert marker.stdout == b"ready"
                child.send_signal(signal.SIGINT)
                child.communicate(timeout=5)
                assert child.returncode == 130, "canceled resume must exit 130"
                assert destination.read_bytes() == b"first-"
            finally:
                if child.poll() is None:
                    child.kill()


def check_proxy(cli, base):
    origin = urlsplit(base)
    proxy_credential = "Basic " + base64.b64encode(b"fixture:private-proxy-password").decode()
    tunneled = threading.Event()
    separated = threading.Event()

    class Proxy(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def do_CONNECT(self):  # noqa: N802
            if self.path != f"origin.invalid:{origin.port}":
                self.send_error(403)
                return
            if self.headers.get("Proxy-Authorization") != proxy_credential:
                self.send_response(407)
                self.send_header("Proxy-Authenticate", 'Basic realm="fixture"')
                self.send_header("Content-Length", "0")
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True
                return
            assert self.headers.get("Authorization") is None
            tunneled.set()
            self.send_response_only(200, "Connection Established")
            self.end_headers()
            with socket.create_connection((origin.hostname, origin.port), timeout=5) as upstream:
                peers = {self.connection: upstream, upstream: self.connection}
                first_request = bytearray()
                try:
                    while readable := select.select(peers, [], [], 5)[0]:
                        for source in readable:
                            data = source.recv(65536)
                            if not data:
                                return
                            if source is self.connection and len(first_request) < 65536:
                                first_request.extend(data)
                                if b"\r\n\r\n" in first_request:
                                    head = first_request.split(b"\r\n\r\n", 1)[0].lower()
                                    if (
                                        b"\r\nauthorization: bearer private-origin-token" in head
                                        and b"\r\nproxy-authorization:" not in head
                                    ):
                                        separated.set()
                            peers[source].sendall(data)
                except OSError:
                    pass
                finally:
                    self.close_connection = True

    with (
        ThreadingHTTPServer(("127.0.0.1", 0), Proxy) as server,
        tempfile.TemporaryDirectory() as directory,
    ):
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            password = Path(directory) / "password"
            password.write_text("private-proxy-password\n")
            command = [
                cli,
                "request",
                f"http://origin.invalid:{origin.port}/cookie/redirect",
                "--proxy",
                f"http://127.0.0.1:{server.server_port}",
                "--proxy-user",
                "fixture",
                "--proxy-password-file",
                password,
                "--header",
                "Authorization: Bearer private-origin-token",
                "--show-redirects",
                "--body-stdout",
                "--timeout",
                "5",
            ]
            response = subprocess.run(command, capture_output=True, timeout=12)
            assert response.returncode == 0, response.stderr
            assert tunneled.is_set(), "proxy was bypassed"
            headers = {k.lower(): v for k, v in json.loads(response.stdout)["headers"].items()}
            assert separated.is_set(), (
                "first origin request lost its authorization or received proxy credentials"
            )
            assert "proxy-authorization" not in headers
            assert b"302 followed" in response.stderr
            assert b"private-" not in response.stderr
        finally:
            server.shutdown()
            worker.join()


def check_socks(cli):
    class SOCKS(StreamRequestHandler):
        def handle(self):
            self.connection.settimeout(5)
            greeting = self.rfile.read(2)
            if len(greeting) != 2 or greeting[0] != 5:
                return
            if 0 not in self.rfile.read(greeting[1]):
                return
            self.wfile.write(b"\x05\x00")
            if self.rfile.read(4) != b"\x05\x01\x00\x03":
                return
            length = self.rfile.read(1)[0]
            if (
                self.rfile.read(length) != b"socks-origin.invalid"
                or self.rfile.read(2) != b"\x00\x50"
            ):
                return
            self.wfile.write(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x50")
            if self.rfile.readline(4096) != b"GET /fixture HTTP/1.1\r\n":
                return
            while self.rfile.readline(4096) not in (b"\r\n", b""):
                pass
            self.wfile.write(
                b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nSOCKS"
            )

    with ThreadingTCPServer(("127.0.0.1", 0), SOCKS) as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            command = [
                cli,
                "request",
                "http://socks-origin.invalid/fixture",
                "--body-stdout",
                "--proxy",
                f"socks5://127.0.0.1:{server.server_address[1]}",
                "--timeout",
                "5",
            ]
            response = subprocess.run(command, capture_output=True, timeout=8)
            assert response.returncode == 0, response.stderr
            assert response.stdout == b"SOCKS"
        finally:
            server.shutdown()
            worker.join()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cli")
    parser.add_argument("base")
    args = parser.parse_args()
    check_stream(args.cli, args.base)
    check_resume_cancellation(args.cli, args.base)
    check_proxy(args.cli, args.base)
    check_socks(args.cli)
    print("Ad-hoc HTTP transport interactions passed")


if __name__ == "__main__":
    main()
