#!/usr/bin/env python3
"""Self-check the supplied playground; optionally execute materials through a built Rill CLI."""

import argparse
import base64
import json
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

from server import start_services

ROOT = Path(__file__).resolve().parent
BASE = "http://127.0.0.1:18990"


def fetch(path, method="GET", data=None, headers=None, base=BASE):
    request = urllib.request.Request(base + path, data=data, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def verify(cli=None):
    servers = start_services()
    try:
        require(fetch("/health")[0] == 200, "health")
        for method in ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"]:
            status, body = fetch(
                "/echo?tag=one&tag=two",
                method,
                b'{"hello":42}' if method in ["POST", "PUT", "PATCH"] else None,
            )
            require(status == 200, method)
            if method != "HEAD":
                require(json.loads(body)["query"]["tag"] == ["one", "two"], method + " query")
        require(json.loads(fetch("/json")[1])["unicode"] == "Hello 👋 café", "JSON Unicode")
        require(fetch("/session", "POST", b"{}")[0] == 201, "session")
        require(
            fetch(
                "/oauth/token",
                "POST",
                b"grant_type=client_credentials&client_id=rill&client_secret=demo-password",
            )[0]
            == 200,
            "OAuth client credentials",
        )
        require(
            fetch("/oauth/token", "POST", b"grant_type=client_credentials")[0] == 400,
            "OAuth rejection",
        )
        for route, headers in [
            (
                "/auth/basic",
                {"Authorization": "Basic " + base64.b64encode(b"rill:demo-password").decode()},
            ),
            ("/auth/bearer", {"Authorization": "Bearer rill-demo-token"}),
            ("/auth/api-key", {"X-API-Key": "rill-demo-key"}),
        ]:
            require(fetch(route)[0] == 401, route + " rejection")
            require(fetch(route, headers=headers)[0] == 200, route + " acceptance")
        require(
            fetch("/flaky?key=verify")[0] == 503 and fetch("/flaky?key=verify")[0] == 200, "retry"
        )
        require(
            fetch("/reset", "POST", b"{}")[0] == 200 and fetch("/flaky?key=verify")[0] == 503,
            "reset",
        )
        require(len(fetch("/bytes/1024")[1]) == 1024, "binary")
        require(fetch("/bytes/999999999")[0] == 400, "size bounds")
        require(fetch("/delay/11")[0] == 400, "delay bounds")
        require(fetch("/unknown")[0] == 404, "404")
        require(fetch("/status/500")[0] == 500, "500")
        require(b"event: update" in fetch("/sse", base="http://127.0.0.1:18991")[1], "SSE")
        graph = json.loads(
            fetch(
                "/graphql",
                "POST",
                b'{"query":"query { hello }","variables":{"count":42}}',
                {"Content-Type": "application/json"},
                base="http://127.0.0.1:18991",
            )[1]
        )
        require(graph["data"]["echo"]["count"] == 42, "GraphQL payload")
        require(
            json.loads(fetch("/graphql-errors", "POST", b"{}", base="http://127.0.0.1:18991")[1])[
                "errors"
            ],
            "GraphQL error",
        )
        print(
            "PASS: HTTP methods, query/body, auth, session, retry/reset, bounds, errors, GraphQL and SSE."
        )
        if cli:
            cli = str(Path(cli).resolve())
            with tempfile.TemporaryDirectory(prefix="rill-kit-cli-") as temp:
                workspace = Path(temp) / "workspace.json"
                shutil.copy2(ROOT / "materials/rill-workspace.json", workspace)

                def run(args, code=0):
                    result = subprocess.run(
                        [cli, *args, "--workspace", str(workspace)],
                        capture_output=True,
                        text=True,
                        timeout=35,
                    )
                    require(
                        result.returncode == code,
                        "CLI "
                        + str(args)
                        + " returned "
                        + str(result.returncode)
                        + "\n"
                        + result.stderr
                        + "\n"
                        + result.stdout,
                    )
                    return result.stdout

                run(["list"])
                require("PASSED" in run(["run-collection", "Kit — Smoke"]), "smoke summary")
                require(
                    "PASSED" in run(["run-collection", "Kit — Workflow", "--detail"]),
                    "extraction chain",
                )
                fetch("/reset", "POST", b"{}")
                require(
                    "Recovered  1" in run(["run-collection", "Kit — Retry", "--retries", "1"]),
                    "recovered retry",
                )
                run(["run-request", "Intentional assertion failure", "--detail"], 4)
                require(
                    "Request timed out"
                    in run(["run-request", "Intentional timeout", "--detail"], 3),
                    "real timeout diagnostic",
                )
                run(["run-request", "Intentional unauthorized"], 4)
                run(["run-request", "Intentional response limit"], 3)
                for format, name in [
                    ("postman", "postman-collection.json"),
                    ("postman", "postman-environment.json"),
                    ("insomnia", "insomnia-v4.json"),
                    ("har", "request.har"),
                    ("bruno", "health.bru"),
                ]:
                    run(
                        [
                            "collection-import",
                            str(ROOT / "materials" / name),
                            "--format",
                            format,
                            "--apply",
                        ]
                    )
                run(["openapi-import", str(ROOT / "materials/openapi.json"), "--apply"])
                trust = Path(temp) / "plugin-trust.json"
                pluginArgs = [
                    "--plugins-dir",
                    str(ROOT / "materials/plugins"),
                    "--trust-file",
                    str(trust),
                ]
                require("rill-kit" in run(["plugins", *pluginArgs]), "plugin discovery")
                run(["plugin-enable", "rill-kit", *pluginArgs, "--apply"])
                run(
                    [
                        "plugin-template",
                        "--plugin",
                        "rill-kit",
                        "--service",
                        "health",
                        *pluginArgs,
                        "--apply",
                    ]
                )
                run(["plugin-disable", "rill-kit", *pluginArgs, "--apply"])
                report = Path(temp) / "run.json"
                run(["run-collection", "Kit — Smoke", "--report", str(report), "--quiet"])
                require(json.loads(report.read_text())["passed"], "report")
            print(
                "PASS: real Rill CLI smoke, extraction, retries, expected exits, five imports, OpenAPI, data-only plugin and JSON report."
            )
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", help="Optional absolute path to RillCLI or packaged rill")
    verify(parser.parse_args().cli)
