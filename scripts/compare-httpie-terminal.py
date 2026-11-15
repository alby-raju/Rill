#!/usr/bin/env python3
"""Compare live terminal workflows with HTTPie 3.2.4 on disposable fixtures."""

import argparse
import json
import os
import select
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def run(command, environment, expected=0):
    result = subprocess.run(command, env=environment, capture_output=True, timeout=12)
    assert result.returncode == expected, (result.returncode, result.stderr)
    return result


def headers(data):
    return {name.lower(): value for name, value in json.loads(data)["headers"].items()}


def compare_stream(rill, httpie, base, environment):
    commands = (
        [rill, "request", base + "/slow-chunks", "--stream"],
        [httpie, "--ignore-stdin", "--body", "--pretty=none", "--stream", base + "/slow-chunks"],
    )
    for command in commands:
        with subprocess.Popen(
            command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        ) as child:
            try:
                ready, _, _ = select.select([child.stdout], [], [], 4)
                assert ready and os.read(child.stdout.fileno(), 1) == b"x"
                assert child.poll() is None
                tail, error = child.communicate(timeout=8)
                assert child.returncode == 0 and tail == b"y", error
            finally:
                if child.poll() is None:
                    child.kill()
    print("PASS incremental stdout and exact delivered bytes")


def compare_resume(rill, httpie, base, directory, environment):
    for path in ("resume", "resume-restart", "resume-invalid"):
        native_file = directory / "rill.partial"
        reference_file = directory / "httpie.partial"
        native_file.write_bytes(b"first-")
        reference_file.write_bytes(b"first-")
        invalid = path == "resume-invalid"
        run(
            [
                rill,
                "request",
                f"{base}/{path}",
                "--download",
                native_file,
                "--resume-etag",
                '"fixture"',
            ],
            environment,
            expected=3 if invalid else 0,
        )
        run(
            [
                httpie,
                "--ignore-stdin",
                "--download",
                "--continue",
                "--output",
                reference_file,
                f"{base}/{path}",
            ],
            environment,
        )
        assert reference_file.read_bytes() == b"first-second"
        assert native_file.read_bytes() == (b"first-" if invalid else b"first-second")
    print("PASS resume and full-response restart; Rill rejects a changed 206 ETag")


def compare_session(rill, httpie, tls_base, ca, directory, environment):
    key = directory / "key"
    key.touch(mode=0o600)
    key.write_text("b" * 64 + "\n")
    native_session = directory / "rill.session"
    reference_session = directory / "httpie.json"
    native = [
        rill,
        "request",
        tls_base + "/session-echo",
        "--ca-cert",
        ca,
        "--session",
        native_session,
        "--session-key-file",
        key,
        "--body-stdout",
    ]
    reference = [
        httpie,
        "--ignore-stdin",
        "--body",
        "--pretty=none",
        "--verify",
        ca,
    ]
    token = "Bearer synthetic-session-token"
    expected = {"authorization": token, "x-fixture": "saved-value"}
    run(
        native
        + [
            "--session-save-auth",
            "--session-save-header",
            "X-Fixture",
            "--header",
            f"Authorization: {token}",
            "--header",
            "X-Fixture: saved-value",
        ],
        environment,
    )
    run(
        reference
        + [
            "--session",
            reference_session,
            tls_base + "/session-echo",
            f"Authorization:{token}",
            "X-Fixture:saved-value",
        ],
        environment,
    )
    native_headers = headers(run(native, environment).stdout)
    reference_headers = headers(
        run(
            reference
            + [
                "--session",
                reference_session,
                tls_base + "/session-echo",
            ],
            environment,
        ).stdout
    )
    for name, value in expected.items():
        assert native_headers[name] == reference_headers[name] == value
    assert token.encode() not in native_session.read_bytes()
    for tool in ("rill", "httpie"):
        override = (
            native + ["--header", "X-Fixture: temporary"]
            if tool == "rill"
            else reference
            + [
                "--session-read-only",
                reference_session,
                tls_base + "/session-echo",
                "X-Fixture:temporary",
            ]
        )
        assert headers(run(override, environment).stdout)["x-fixture"] == "temporary"
    assert headers(run(native, environment).stdout)["x-fixture"] == "saved-value"
    assert (
        headers(
            run(
                reference
                + [
                    "--session",
                    reference_session,
                    tls_base + "/session-echo",
                ],
                environment,
            ).stdout
        )["x-fixture"]
        == "saved-value"
    )
    print("PASS session header/auth replay and temporary overrides; Rill session is encrypted")


def compare_redirect(rill, httpie, environment):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):  # noqa: N802
            if self.path == "/start":
                self.send_response(302)
                self.send_header("Location", next_url)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            body = json.dumps(
                {
                    "authorization": self.headers.get("Authorization") is not None,
                    "custom_key": self.headers.get("X-API-Key") is not None,
                }
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    with (
        ThreadingHTTPServer(("127.0.0.1", 0), Handler) as source,
        ThreadingHTTPServer(("127.0.0.1", 0), Handler) as destination,
    ):
        next_url = f"http://127.0.0.1:{destination.server_port}/target?fixture=private-hop"
        workers = [
            threading.Thread(target=server.serve_forever, daemon=True)
            for server in (source, destination)
        ]
        for worker in workers:
            worker.start()
        try:
            url = f"http://127.0.0.1:{source.server_port}/start"
            actual = run(
                [
                    rill,
                    "request",
                    url,
                    "--show-redirects",
                    "--body-stdout",
                    "--header",
                    "Authorization: Bearer synthetic",
                    "--header",
                    "X-API-Key: synthetic",
                ],
                environment,
                expected=3,
            )
            assert b"302 stopped hop=1 reason=cross-origin" in actual.stderr
            assert b"private-hop" not in actual.stderr and b"synthetic" not in actual.stderr
            reference = run(
                [
                    httpie,
                    "--ignore-stdin",
                    "--follow",
                    "--pretty=none",
                    "--body",
                    url,
                    "Authorization:Bearer synthetic",
                    "X-API-Key:synthetic",
                ],
                environment,
            )
            assert json.loads(reference.stdout) == {"authorization": False, "custom_key": True}
        finally:
            for server, worker in zip((source, destination), workers):
                server.shutdown()
                worker.join()
    print(
        "PASS cross-origin evaluation: HTTPie forwards synthetic custom auth; Rill blocks the hop"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rill")
    parser.add_argument("httpie", type=Path)
    parser.add_argument("base")
    parser.add_argument("tls_base")
    parser.add_argument("ca", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        environment = {
            **os.environ,
            "HTTPIE_CONFIG_DIR": directory,
            "NO_PROXY": "127.0.0.1,localhost",
        }
        httpie = str(args.httpie.resolve())
        assert run([httpie, "--version"], environment).stdout.strip() == b"3.2.4"
        compare_stream(args.rill, httpie, args.base, environment)
        compare_resume(args.rill, httpie, args.base, root, environment)
        compare_session(args.rill, httpie, args.tls_base, args.ca, root, environment)
        compare_redirect(args.rill, httpie, environment)


if __name__ == "__main__":
    main()
