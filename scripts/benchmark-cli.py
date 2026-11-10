#!/usr/bin/env python3
"""Measure synthetic CLI workloads, with optional loopback-only collection runs."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import re
import socket
import statistics
import subprocess
import tempfile
import threading
import time
import uuid
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def hardware_value(name: str) -> str | None:
    try:
        return subprocess.check_output(
            ["/usr/sbin/sysctl", "-n", name], stderr=subprocess.DEVNULL, timeout=5, text=True
        ).strip()
    except (OSError, subprocess.SubprocessError):
        return None


def workloads(count: int) -> tuple[dict, dict]:
    if count not in (600, 5000, 10000):
        raise ValueError("Use the published 600/5000/10000 workload sizes.")
    requests = []
    for index in range(count):
        requests.append(
            {
                "id": str(
                    uuid.uuid5(uuid.NAMESPACE_URL, f"https://rill.invalid/benchmark/{index}")
                ),
                "name": f"Synthetic request {index:05d}",
                "method": "GET",
                "url": f"http://127.0.0.1:1/synthetic/{index}",
                "headers": [],
                "parameters": [],
                "body": "",
                "contentType": "application/json",
                "auth": "None",
                "username": "",
                "credential": "",
                "timeout": 30,
                "expectedStatus": "",
                "bodyContains": "",
            }
        )
    workspace = {
        "version": 1,
        "collections": [],
        "requests": requests,
        "environments": [],
        "history": [],
    }
    postman = {
        "info": {
            "name": "Synthetic benchmark",
            "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
        },
        "item": [
            {"name": request["name"], "request": {"method": "GET", "url": request["url"]}}
            for request in requests
        ],
    }
    return workspace, postman


class BenchmarkServer(ThreadingHTTPServer):
    def __init__(self, count: int, body_bytes: int):
        super().__init__(("127.0.0.1", 0), BenchmarkHandler)
        self.count = count
        prefix = b'{"ok":true,"padding":"'
        suffix = b'"}'
        self.body = prefix + b"a" * (body_bytes - len(prefix) - len(suffix)) + suffix
        self.requests = 0
        self.connections = 0
        self.lock = threading.Lock()

    def get_request(self):
        connection, address = super().get_request()
        connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        with self.lock:
            self.connections += 1
        return connection, address


class BenchmarkHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def do_GET(self):
        server = self.server
        with server.lock:
            expected = server.requests % server.count
            valid = (
                self.path == f"/synthetic/{expected}"
                and self.headers.get("X-Rill-Benchmark") == "1"
            )
            if valid:
                server.requests += 1
        if not valid:
            self.send_error(400)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(server.body)))
        self.end_headers()
        self.wfile.write(server.body)


@contextmanager
def run_fixture(postman: dict, count: int, collection: Path):
    body_bytes = 64 * 1024 if count == 600 else 1024
    with BenchmarkServer(count, body_bytes) as server:
        port = server.server_address[1]
        postman["event"] = [
            {
                "listen": "prerequest",
                "script": {
                    "type": "text/javascript",
                    "exec": ["pm.request.headers.upsert({key: 'X-Rill-Benchmark', value: '1'});"],
                },
            },
            {
                "listen": "test",
                "script": {
                    "type": "text/javascript",
                    "exec": [
                        "pm.test('body check', () => { pm.expect(pm.response.json().ok).to.eql(true); });"
                    ],
                },
            },
        ]
        for index, item in enumerate(postman["item"]):
            item["request"]["url"] = f"http://127.0.0.1:{port}/synthetic/{index}"
        collection.write_text(json.dumps(postman, separators=(",", ":")), encoding="utf-8")
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server
        finally:
            server.shutdown()
            thread.join()


def measure(executable: str, arguments: list[str]) -> dict:
    start = time.perf_counter()
    result = subprocess.run(
        ["/usr/bin/time", "-l", executable, *arguments],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        timeout=120,
    )
    elapsed = time.perf_counter() - start
    if result.returncode:
        diagnostic = result.stderr[:2048].decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"Benchmark command failed (exit {result.returncode}): {diagnostic}")
    memory = re.search(rb"(\d+)\s+maximum resident set size", result.stderr)
    if memory is None:
        raise RuntimeError("macOS time did not return peak resident memory.")
    return {"seconds": elapsed, "peakRSSBytes": int(memory[1])}


def measure_run(executable: str, collection: Path, server: BenchmarkServer, report: Path | None):
    arguments = ["run", str(collection), "--translate-scripts", "--json"]
    if report:
        arguments += ["--report", str(report), "--report-format", report.suffix[1:]]
    with server.lock:
        before, connections = server.requests, server.connections
    sample = measure(executable, arguments)
    with server.lock:
        if server.requests - before != server.count:
            raise RuntimeError("The loopback workload did not receive every request in order.")
        sample["connections"] = server.connections - connections
    sample["responseBytes"] = len(server.body) * server.count
    if report:
        sample["reportBytes"] = report.stat().st_size
        with report.open(encoding="utf-8") as handle:
            if report.suffix == ".json":
                result = json.load(handle)
                attempts = len(result["outcomes"])
            else:
                attempts = 0
                result = {}
                for line in handle:
                    result = json.loads(line)
                    if result["type"] == "attempt":
                        attempts += 1
            if result.get("passed") is not True or attempts != server.count:
                raise RuntimeError("The benchmark report is incomplete or unsuccessful.")
        report.unlink()
    return sample


def summarize(count: int, operation: str, first: dict, samples: list[dict]) -> dict:
    times = sorted(sample["seconds"] for sample in samples)
    median = statistics.median(times)
    p95 = times[math.ceil(len(times) * 0.95) - 1]
    print(f"{count} {operation}: median={median:.3f}s p95={p95:.3f}s", flush=True)
    return {
        "requests": count,
        "operation": operation,
        "firstInvocation": first,
        "repeatedSamples": samples,
        "medianSeconds": median,
        "p95Seconds": p95,
        "maximumPeakRSSBytes": max(sample["peakRSSBytes"] for sample in samples),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True, type=Path, help="Optimized RillCLI/rill executable")
    parser.add_argument("--output", required=True, type=Path, help="New JSON result file")
    parser.add_argument("--repetitions", type=int, choices=range(3, 11), default=5)
    parser.add_argument(
        "--include-runs", action="store_true", help="Also measure loopback runs and reports"
    )
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error(
            "This baseline uses macOS time -l; it does not establish portable CLI support."
        )
    if args.output.exists():
        parser.error("Output exists; choose a new result file.")
    executable = str(args.cli.resolve(strict=True))
    record = {
        "schemaVersion": 1,
        "sourceCommit": subprocess.check_output(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True
        ).strip(),
        "dirtySource": bool(
            subprocess.check_output(["git", "-C", str(ROOT), "status", "--porcelain"]).strip()
        ),
        "binarySHA256": hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
        "version": subprocess.check_output([executable, "--version"], text=True).strip(),
        "hardware": {
            "architecture": platform.machine(),
            "logicalCPUs": os.cpu_count(),
            "processorModel": hardware_value("machdep.cpu.brand_string"),
            "physicalMemoryBytes": int(memory)
            if (memory := hardware_value("hw.memsize"))
            else None,
        },
        "os": platform.mac_ver()[0],
        "conditions": "Release executable, separate process per sample; first invocation and repeated OS-cache samples. Caches are not flushed. No Keychain, personal workspace or external traffic.",
        "measurements": [],
    }
    with tempfile.TemporaryDirectory(prefix="rill-benchmark-") as temporary:
        root = Path(temporary)
        for count in (600, 5000, 10000):
            native, postman = workloads(count)
            workspace = root / f"native-{count}.json"
            collection = root / f"postman-{count}.json"
            workspace.write_text(json.dumps(native, separators=(",", ":")), encoding="utf-8")
            collection.write_text(json.dumps(postman, separators=(",", ":")), encoding="utf-8")
            for operation, arguments in (
                ("list", ["list", "--workspace", str(workspace)]),
                ("search", ["search", "00599", "--workspace", str(workspace)]),
                ("postmanPreflight", ["preflight", str(collection), "--json"]),
            ):
                first = measure(executable, arguments)
                samples = [measure(executable, arguments) for _ in range(args.repetitions)]
                record["measurements"].append(summarize(count, operation, first, samples))
            if args.include_runs:
                with run_fixture(postman, count, collection) as server:
                    for operation, report in (
                        ("postmanRun", None),
                        ("postmanRunJSON", root / "run.json"),
                        ("postmanRunNDJSON", root / "run.ndjson"),
                    ):
                        first = measure_run(executable, collection, server, report)
                        samples = [
                            measure_run(executable, collection, server, report)
                            for _ in range(args.repetitions)
                        ]
                        record["measurements"].append(summarize(count, operation, first, samples))
    with args.output.open("x", encoding="utf-8") as handle:
        json.dump(record, handle, indent=2)
        handle.write("\n")


if __name__ == "__main__":
    main()
