#!/usr/bin/env python3
"""Measure synthetic metadata/preflight workloads; never sends API requests."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import platform
import re
import statistics
import subprocess
import tempfile
import time
import uuid
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


def measure(executable: str, arguments: list[str]) -> dict:
    start = time.perf_counter()
    result = subprocess.run(
        ["/usr/bin/time", "-l", executable, *arguments],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        timeout=120,
        check=True,
    )
    elapsed = time.perf_counter() - start
    memory = re.search(rb"(\d+)\s+maximum resident set size", result.stderr)
    if memory is None:
        raise RuntimeError("macOS time did not return peak resident memory.")
    return {"seconds": elapsed, "peakRSSBytes": int(memory[1])}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True, type=Path, help="Optimized RillCLI/rill executable")
    parser.add_argument("--output", required=True, type=Path, help="New JSON result file")
    parser.add_argument("--repetitions", type=int, choices=range(3, 11), default=5)
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
        "conditions": "Release executable, separate process per sample; first invocation and repeated OS-cache samples. Caches are not flushed. No API requests, Keychain or personal workspace.",
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
                times = sorted(sample["seconds"] for sample in samples)
                record["measurements"].append(
                    {
                        "requests": count,
                        "operation": operation,
                        "firstInvocation": first,
                        "repeatedSamples": samples,
                        "medianSeconds": statistics.median(times),
                        "p95Seconds": times[math.ceil(len(times) * 0.95) - 1],
                        "maximumPeakRSSBytes": max(sample["peakRSSBytes"] for sample in samples),
                    }
                )
                print(
                    f"{count} {operation}: median={statistics.median(times):.3f}s p95={times[-1]:.3f}s"
                )
    with args.output.open("x", encoding="utf-8") as handle:
        json.dump(record, handle, indent=2)
        handle.write("\n")


if __name__ == "__main__":
    main()
