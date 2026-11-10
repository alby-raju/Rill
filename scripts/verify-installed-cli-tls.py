#!/usr/bin/env python3
"""Exercise a trusted CLI archive with a synthetic 600-request mTLS collection."""

import argparse
import hashlib
import json
import platform
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import ExitStack
from functools import partial
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

OVERRIDES = ("runLinks", "runDelivery", "runManagementExtras", "runCleanup")
REQUESTS_PER_GROUP = 150
TOTAL_REQUESTS = len(OVERRIDES) * REQUESTS_PER_GROUP
SENTINEL = "rill-installed-tls-synthetic-secret"


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def workspace_snapshot():
    # Compare metadata only. No personal workspace content enters this process.
    path = Path.home() / "Library/Application Support/Rill/workspace.json"
    try:
        status = path.stat()
    except FileNotFoundError:
        return None
    return status.st_ino, status.st_size, status.st_mtime_ns, status.st_ctime_ns


def require_desktop_closed():
    process = subprocess.run(["/usr/bin/pgrep", "-x", "Rill"], capture_output=True, check=False)
    require(process.returncode == 1, "Close Rill before running installed CLI acceptance.")


class Fixture(BaseHTTPRequestHandler):
    def __init__(self, observed, lock, peer, parity, *args):
        self.observed = observed
        self.lock = lock
        self.peer = peer
        self.parity = parity
        super().__init__(*args)

    def do_GET(self):
        with self.lock:
            index = len(self.observed)
            valid = (
                index < TOTAL_REQUESTS
                and index % 2 == self.parity
                and self.path == f"/verify/{index}"
                and self.connection.getpeercert(binary_form=True) == self.peer
                and self.headers.get("X-Run-Override") == "enabled"
                and self.headers.get("X-Fixture-Key") == SENTINEL
            )
            self.observed.append(valid)
        self.send_response(204 if valid else 400)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_):
        pass


def start_server(stack, materials, client, parity, observed, lock):
    peer = ssl.PEM_cert_to_DER_cert((materials / f"{client}.pem").read_text())
    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(Fixture, observed, lock, peer, parity))
    stack.callback(server.server_close)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(materials / "server.pem", materials / "server.key")
    context.load_verify_locations(materials / "ca.pem")
    context.verify_mode = ssl.CERT_REQUIRED
    server.socket = context.wrap_socket(server.socket, server_side=True)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    stack.callback(worker.join, 5)
    stack.callback(server.shutdown)
    return f"https://localhost:{server.server_port}"


def collection(groups):
    return {
        "info": {
            "name": "Installed CLI TLS acceptance",
            "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
        },
        "item": [
            {
                "name": override,
                "item": [
                    {
                        "name": f"Request {index + 1}",
                        "request": {
                            "method": "GET",
                            "url": "{{"
                            + ("rsaURL" if index % 2 == 0 else "ecURL")
                            + f"}}}}/verify/{index}",
                            "header": [
                                {"key": "X-Run-Override", "value": "{{" + override + "}}"},
                                {"key": "X-Fixture-Key", "value": "{{fixtureKey}}"},
                            ],
                        },
                    }
                    for index in indexes
                ],
            }
            for override, indexes in groups
        ],
    }


def write_json(path, document):
    path.write_text(json.dumps(document), encoding="utf-8")
    return path


def check_archive(archive, root, expected_source=None):
    checksum = Path(str(archive) + ".sha256").read_text(encoding="utf-8").split()[0]
    require(checksum == digest(archive), "CLI archive checksum mismatch.")
    provenance = json.loads(archive.with_suffix(".provenance.json").read_text(encoding="utf-8"))
    require(
        provenance["artifact"] == archive.name
        and provenance["architecture"] == platform.machine()
        and not provenance["dirtySource"],
        "Expected a clean source archive for this architecture.",
    )
    if expected_source is not None:
        require(
            provenance["sourceCommit"] == expected_source,
            "CLI archive source does not match the expected revision.",
        )
    subprocess.run(["ditto", "-x", "-k", str(archive), str(root)], check=True, timeout=60)
    binary = root / archive.stem / "bin" / "rill"
    subprocess.run(["codesign", "--verify", "--strict", binary], check=True, timeout=10)
    doctor = subprocess.check_output([binary, "doctor", "--json"], timeout=10)
    require(json.loads(doctor)["passed"], "Relocated CLI doctor failed.")
    return binary, provenance["sourceCommit"], checksum


def run_acceptance(binary, root):
    materials = root / "TLS inputs"
    generator = Path(__file__).with_name("tls-fixture.py")
    subprocess.run(
        [sys.executable, generator, materials, "--materials-only"], check=True, timeout=30
    )
    (materials / "RSA password.txt").write_text("rill-fixture\n", encoding="utf-8")
    (materials / "EC password.txt").write_text(" rill-fixture \r\n", encoding="utf-8")
    observed = []
    lock = threading.Lock()
    with ExitStack() as stack:
        rsa_url = start_server(stack, materials, "client", 0, observed, lock)
        ec_url = start_server(stack, materials, "ec-client", 1, observed, lock)
        values = dict.fromkeys(OVERRIDES, "disabled")
        values.update(rsaURL=rsa_url, ecURL=ec_url, fixtureKey=SENTINEL)
        environment = write_json(
            root / "acceptance environment.json",
            {
                "_postman_variable_scope": "environment",
                "values": [
                    {"key": key, "value": value, "enabled": True} for key, value in values.items()
                ],
            },
        )
        source = write_json(
            root / "acceptance collection.json",
            collection(
                (key, range(group * REQUESTS_PER_GROUP, (group + 1) * REQUESTS_PER_GROUP))
                for group, key in enumerate(OVERRIDES)
            ),
        )
        identities = [
            {"origin": rsa_url, "pkcs12": "client.p12", "passphraseFile": "RSA password.txt"},
            {
                "origin": ec_url,
                "certificate": "ec-client.pem",
                "key": "ec-client-encrypted.pem",
                "passphraseFile": "EC password.txt",
            },
        ]
        manifest = write_json(
            materials / "client identities.json", {"schemaVersion": 1, "identities": identities}
        )
        inputs = [source, environment, *materials.iterdir()]
        before = [digest(path) for path in inputs]
        workspace = workspace_snapshot()
        report = root / "acceptance report.json"
        started = time.monotonic()
        result = subprocess.run(
            [
                binary,
                "run",
                source,
                "--environment-file",
                environment,
                "--ssl-client-map",
                manifest,
                "--ca-cert",
                materials / "ca.pem",
                "--color",
                "never",
                "--detail",
                "--report",
                report,
                *(option for key in OVERRIDES for option in ("--env-var", f"{key}=enabled")),
            ],
            cwd=root,
            capture_output=True,
            timeout=180,
            check=False,
        )
        elapsed = round(time.monotonic() - started, 2)
        require(
            result.returncode == 0 and observed == [True] * TOTAL_REQUESTS,
            f"Run failed with exit {result.returncode} after {len(observed)} HTTP requests.",
        )
        require(
            b"PASSED" in result.stdout and b"Request visits" in result.stdout,
            "Terminal report missing.",
        )
        report_bytes = report.read_bytes()
        outcomes = json.loads(report_bytes)["outcomes"]
        require(
            len(outcomes) == TOTAL_REQUESTS
            and all(row["state"] == "passed" and row["status"] == 204 for row in outcomes),
            "JSON report does not record all successful requests.",
        )
        ordinary_output = result.stdout + result.stderr + report_bytes
        require(
            all(
                marker not in ordinary_output
                for marker in (SENTINEL.encode(), b"rill-fixture", b"-----BEGIN")
            ),
            "Ordinary output disclosed a synthetic credential marker.",
        )
        require(
            before == [digest(path) for path in inputs], "Acceptance run changed an input file."
        )
        require(workspace == workspace_snapshot(), "Default workspace metadata changed.")
        return elapsed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "archive", type=Path, help="trusted CLI ZIP with checksum and provenance sidecars"
    )
    parser.add_argument("--source-commit", help="require the archive's exact source revision")
    args = parser.parse_args()
    require_desktop_closed()
    with tempfile.TemporaryDirectory(prefix="Rill installed TLS ") as temporary:
        root = Path(temporary)
        binary, source, checksum = check_archive(args.archive.resolve(), root, args.source_commit)
        elapsed = run_acceptance(binary, root)
    require_desktop_closed()
    print(
        json.dumps(
            {
                "sourceCommit": source,
                "archiveSHA256": checksum,
                "macOS": platform.mac_ver()[0],
                "architecture": platform.machine(),
                "tlsProvider": ssl.OPENSSL_VERSION,
                "requests": TOTAL_REQUESTS,
                "seconds": elapsed,
                "result": "passed",
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
