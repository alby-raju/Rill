#!/usr/bin/env python3
"""Compare prepared requests against HTTPie 3.2.4 using synthetic inputs."""

import argparse
import base64
import json
import os
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import urlsplit

REFERENCE_VERSION = "3.2.4"
BASE = "http://127.0.0.1:1"


def run(binary, options, directory, input_bytes=b""):
    result = subprocess.run(
        [binary, *options],
        cwd=directory,
        env={**os.environ, "HTTPIE_CONFIG_DIR": str(directory)},
        input=input_bytes,
        capture_output=True,
        timeout=10,
    )
    if result.returncode:
        raise SystemExit(f"{Path(binary).name} failed with status {result.returncode}")
    return result.stdout


def compare(rill, httpie, directory):
    header_file = directory / "header value.txt"
    header_file.write_bytes(b"fixture\r\n")
    cases = (
        ("get-query", "GET", "/items?q=a%20b&q=c", [], [], b"", b""),
        ("get-localhost", "", ":8080/items?q=ready", [], [], b"", b""),
        ("get-bare-host", "", "127.0.0.1:1/items", [], [], b"", b""),
        ("post-localhost", "", ":/items", ["--data", "sample"], ["--raw=sample"], b"sample", b""),
        (
            "get-query-fields",
            "GET",
            "/items?existing=%2B",
            ["--query-param", "tag=a+b", "--query-param", "tag="],
            ["tag==a+b", "tag=="],
            b"",
            b"",
        ),
        ("post-text", "POST", "/items", ["--data", "sample"], ["--raw=sample"], b"sample", b""),
        ("post-stdin", "POST", "/items", ["--stdin"], [], b"piped text", b"piped text"),
        (
            "post-nested-json",
            "POST",
            "/items",
            [
                "--json-field",
                "user[name]=Ada",
                "--json-field",
                "user[active]:=true",
                "--json-field",
                "ids[]:=7",
                "--json-field",
                "ids[]:=8",
            ],
            ["user[name]=Ada", "user[active]:=true", "ids[]:=7", "ids[]:=8"],
            b'{"user":{"name":"Ada","active":true},"ids":[7,8]}',
            b"",
        ),
    )
    for name, method, target, rill_body, httpie_body, expected_body, input_bytes in cases:
        url = BASE + target if target.startswith("/") else target
        operands = [method, url] if method else [url]
        prepared = json.loads(
            run(
                rill,
                [
                    "request",
                    *operands,
                    "--default-scheme",
                    "http",
                    "--offline",
                    "--raw-preview",
                    "--header-file",
                    f"X-Rill={header_file.name}",
                    "--header",
                    "Content-Type: text/plain",
                    *rill_body,
                ],
                directory,
                input_bytes,
            )
        )
        reference = run(
            httpie,
            [
                *(["--ignore-stdin"] if not input_bytes else []),
                "--offline",
                "--pretty=none",
                "--print=HB",
                "--default-scheme=http",
                *operands,
                f"X-Rill:@{header_file.name}",
                "Content-Type:text/plain",
                *httpie_body,
            ],
            directory,
            input_bytes,
        )
        head, separator, body = reference.partition(b"\r\n\r\n")
        if not separator and not expected_body:
            head, body = reference, b""
        start, *headers = head.decode("ascii").splitlines()
        ref_method, ref_target, _ = start.split(" ", 2)
        actual = urlsplit(prepared["url"])
        actual_target = actual.path + ("?" + actual.query if actual.query else "")
        expected = dict(line.split(":", 1) for line in headers)
        fields = {key.lower(): value for key, value in prepared["headers"].items()}
        actual_body = base64.b64decode(prepared.get("bodyBase64", ""))
        if name == "post-nested-json":
            bodies_match = json.loads(actual_body) == json.loads(body) == json.loads(expected_body)
        else:
            bodies_match = actual_body == body == expected_body
        if (
            prepared["sendsRequests"]
            or prepared["method"] != ref_method
            or actual_target != ref_target
            or actual.netloc != expected["Host"].strip()
            or not bodies_match
            or any(
                fields.get(key.lower()) != expected[key].strip()
                for key in ("X-Rill", "Content-Type")
            )
        ):
            raise SystemExit(f"{name}: prepared request differs")
        print(f"PASS {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rill", type=Path, required=True)
    parser.add_argument("--httpie", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="rill-httpie-") as directory:
        root = Path(directory)
        rill = str(args.rill.absolute())
        httpie = str(args.httpie.absolute())
        if run(httpie, ["--version"], root).decode().strip() != REFERENCE_VERSION:
            raise SystemExit(f"HTTPie {REFERENCE_VERSION} is required")
        compare(rill, httpie, root)


if __name__ == "__main__":
    main()
