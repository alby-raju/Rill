#!/usr/bin/env python3
"""Compare independently authored synthetic workflows against pinned Newman, loopback only."""

from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
VERSION = "6.2.3"


def event(source: str, phase: str = "test") -> dict:
    return {"listen": phase, "script": {"type": "text/javascript", "exec": [source]}}


def test(status: int = 200) -> str:
    return f"pm.test('synthetic status', () => {{ pm.response.to.have.status({status}); }});"


def item(name: str, url: str, scripts: list | None = None, headers: dict | None = None) -> dict:
    return {
        "name": name,
        "request": {
            "method": "GET",
            "url": url,
            "header": [{"key": key, "value": value} for key, value in (headers or {}).items()],
        },
        "event": scripts if scripts is not None else [event(test())],
    }


def collection(items: list, scripts: list | None = None) -> dict:
    return {
        "info": {
            "name": "Rill synthetic conformance",
            "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json",
        },
        "variable": [{"key": "fallback", "value": "collection-fallback"}],
        "item": items,
        "event": scripts or [],
    }


class Fixture(BaseHTTPRequestHandler):
    records: list[dict] = []

    def do_GET(self) -> None:
        selected = {
            key.lower(): value
            for key, value in self.headers.items()
            if key.lower().startswith("x-case-")
        }
        self.records.append({"path": self.path, "headers": selected})
        body = json.dumps({"token": "synthetic-token", "seen": selected}).encode()
        self.send_response(404 if self.path == "/expected404" else 200)
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Token", "synthetic-header")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args: object) -> None:
        pass


def corpus(base: str) -> list[tuple[str, dict, dict, bool, list[str]]]:
    inherited = collection(
        [
            {
                "name": "Folder",
                "event": [
                    event("pm.environment.set('order', 'folder');", "prerequest"),
                    event("pm.environment.set('post', 'folder');"),
                ],
                "item": [
                    item(
                        "Login",
                        base + "/login",
                        [
                            event("pm.environment.set('order', 'request');", "prerequest"),
                            event(
                                "pm.environment.set('post', 'request'); pm.environment.set('token', pm.response.json().token); pm.environment.set('header', pm.response.headers.get('X-Token')); "
                                + test()
                            ),
                        ],
                        {"X-Case-Order": "{{order}}"},
                    ),
                    item(
                        "Echo",
                        base + "/echo",
                        headers={
                            "X-Case-Order": "{{order}}",
                            "X-Case-Post": "{{post}}",
                            "X-Case-Token": "{{token}}",
                            "X-Case-Header": "{{header}}",
                        },
                    ),
                ],
            },
        ],
        [
            event("pm.environment.set('order', 'collection');", "prerequest"),
            event("pm.environment.set('post', 'collection');"),
        ],
    )
    branching = collection(
        [
            {
                "name": "A",
                "item": [
                    item(
                        "Skip",
                        base + "/never-skip",
                        [event("pm.execution.skipRequest();", "prerequest")],
                    ),
                    item(
                        "Branch",
                        base + "/branch",
                        [event(test() + " pm.execution.setNextRequest('Target');")],
                    ),
                ],
            },
            item("Not visited", base + "/never-branch"),
            {
                "name": "B",
                "item": [
                    item(
                        "Target",
                        base + "/target",
                        [event(test() + " pm.execution.setNextRequest(null);")],
                    )
                ],
            },
            item("After stop", base + "/never-stop"),
        ]
    )
    failure = collection(
        [
            item(
                "Failure",
                base + "/failed-check",
                [event(test(500) + " pm.environment.set('after', 'retained');")],
            ),
            item("After", base + "/after-failed-check", headers={"X-Case-After": "{{after}}"}),
        ]
    )
    conditional = collection(
        [
            item(
                "Conditional",
                base + "/conditional",
                [
                    event(
                        "if (pm.environment.get('run') === 'yes') { pm.environment.set('choice', 'yes'); } else { pm.execution.skipRequest(); }",
                        "prerequest",
                    ),
                    event(test()),
                ],
            ),
            item(
                "Echo",
                base + "/echo-choice",
                headers={"X-Case-Choice": "{{choice}}", "X-Case-Fallback": "{{fallback}}"},
            ),
        ]
    )
    scopes = collection(
        [
            item(
                "Scopes",
                base + "/scopes",
                [
                    event(
                        "pm.globals.set('g', 'global'); pm.collectionVariables.set('c', 'collection'); pm.environment.set('copy', pm.globals.get('g')); pm.variables.set('local', 'local'); pm.environment.unset('removed');",
                        "prerequest",
                    ),
                    event(test()),
                ],
                {
                    "X-Case-G": "{{g}}",
                    "X-Case-C": "{{c}}",
                    "X-Case-Copy": "{{copy}}",
                    "X-Case-Local": "{{local}}",
                },
            ),
        ]
    )
    return [
        ("inheritance-extraction", inherited, {}, True, ["token", "header", "post", "order"]),
        ("skip-branch-stop", branching, {}, True, []),
        ("failed-check-mutation", failure, {}, False, ["after"]),
        ("conditional-yes", conditional, {"run": "yes", "choice": "initial"}, True, ["choice"]),
        ("conditional-skip", conditional, {"run": "no", "choice": "initial"}, True, ["choice"]),
        ("scoped-mutation", scopes, {"removed": "old"}, True, ["copy", "removed"]),
        (
            "expected-non2xx",
            collection([item("Expected404", base + "/expected404", [event(test(404))])]),
            {},
            True,
            [],
        ),
    ]


def values(path: Path) -> dict:
    return {
        row["key"]: row.get("value")
        for row in json.loads(path.read_text())["values"]
        if row.get("enabled", True)
    }


def run(cli: Path) -> None:
    newman = HERE / "node_modules/.bin/newman"
    actual_version = subprocess.check_output(
        [str(newman), "--version"], text=True, timeout=15
    ).strip()
    if actual_version != VERSION:
        raise RuntimeError("Run npm ci with the committed Newman lockfile first.")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    base = f"http://127.0.0.1:{server.server_port}"
    try:
        with tempfile.TemporaryDirectory(prefix="rill-newman conformance ") as directory:
            root = Path(directory)
            for name, source, environment, passed, exported in corpus(base):
                collection_file, env = root / "collection.json", root / "env.json"
                collection_file.write_text(json.dumps(source))
                env.write_text(
                    json.dumps(
                        {
                            "name": "Synthetic",
                            "_postman_variable_scope": "environment",
                            "values": [
                                {"key": key, "value": value, "enabled": True}
                                for key, value in environment.items()
                            ],
                        }
                    )
                )
                newman_report, newman_env = root / "newman.json", root / "newman-env.json"
                Fixture.records.clear()
                reference = subprocess.run(
                    [
                        str(newman),
                        "run",
                        str(collection_file),
                        "--environment",
                        str(env),
                        "--reporters",
                        "json",
                        "--reporter-json-export",
                        str(newman_report),
                        "--export-environment",
                        str(newman_env),
                    ],
                    capture_output=True,
                    timeout=60,
                )
                expected_wire = list(Fixture.records)
                rill_report, rill_env = root / "rill.json", root / "rill-env.json"
                Fixture.records.clear()
                candidate = subprocess.run(
                    [
                        str(cli),
                        "run",
                        str(collection_file),
                        "--environment-file",
                        str(env),
                        "--translate-scripts",
                        "--continue-on-failure",
                        "--report",
                        str(rill_report),
                        "--export-environment",
                        str(rill_env),
                        "--overwrite",
                        "--json",
                    ],
                    capture_output=True,
                    timeout=60,
                )
                actual_wire = list(Fixture.records)
                if reference.returncode != (0 if passed else 1) or candidate.returncode != (
                    0 if passed else 4
                ):
                    raise AssertionError(
                        f"{name}: exits Newman={reference.returncode}, Rill={candidate.returncode}; Rill diagnostics={candidate.stderr.decode()}"
                    )
                if actual_wire != expected_wire:
                    raise AssertionError(
                        f"{name}: synthetic wire mismatch\nNewman={expected_wire}\nRill={actual_wire}"
                    )
                n = json.loads(newman_report.read_text())["run"]["stats"]["assertions"]
                r = json.loads(rill_report.read_text())
                checks = sum(item.get("checkCount", len(item["checks"])) for item in r["outcomes"])
                failed = sum(
                    item.get("failedCheckCount", sum(not c["passed"] for c in item["checks"]))
                    for item in r["outcomes"]
                )
                if (checks, failed) != (n["total"], n["failed"]):
                    raise AssertionError(
                        f"{name}: assertion counts differ {(checks, failed)} != {(n['total'], n['failed'])}"
                    )
                reference_values, candidate_values = values(newman_env), values(rill_env)
                for key in exported:
                    if reference_values.get(key) != candidate_values.get(key):
                        raise AssertionError(
                            f"{name}: synthetic environment mutation differs for {key}"
                        )
                print(
                    f"PASS {name}: {len(actual_wire)} HTTP requests, {checks} checks, {failed} failures"
                )
            # Unknown and remote source must fail before even the first request.
            for source in [
                event("unknownPrivateCall('private-source');"),
                {"listen": "test", "script": {"src": base + "/never-fetch-script"}},
            ]:
                collection_file.write_text(
                    json.dumps(
                        collection(
                            [
                                item("First", base + "/never-first"),
                                item("Later", base + "/never-later", [source]),
                            ]
                        )
                    )
                )
                Fixture.records.clear()
                blocked = subprocess.run(
                    [str(cli), "run", str(collection_file), "--translate-scripts", "--json"],
                    capture_output=True,
                    timeout=30,
                )
                if (
                    blocked.returncode != 2
                    or Fixture.records
                    or b"private-source" in blocked.stderr + blocked.stdout
                ):
                    raise AssertionError(
                        "Unsupported source did not fail closed with redacted diagnostics."
                    )
            print(
                f"PASS fail-closed source cases; Newman {VERSION}; Node {subprocess.check_output(['node', '--version'], text=True).strip()}"
            )
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, required=True)
    run(parser.parse_args().cli.resolve(strict=True))
