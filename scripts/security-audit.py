#!/usr/bin/env python3
"""Fail closed on OSV matches/errors for pinned Swift revisions and Python tools."""

import json
import re
import sys
from pathlib import Path
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent.parent


def main():
    pins = json.loads((ROOT / "Package.resolved").read_text())["pins"]
    names = []
    queries = []
    for pin in pins:
        revision = pin["state"]["revision"]
        if not re.fullmatch(r"[0-9a-f]{40}", revision):
            raise ValueError("Expected an immutable Swift commit")
        names.append(pin["identity"] + "@" + revision)
        queries.append({"commit": revision})
    for line in (ROOT / "requirements-dev.txt").read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        match = re.fullmatch(r"([A-Za-z0-9_.-]+)==([A-Za-z0-9_.+-]+)", line)
        if not match:
            raise ValueError("Expected a pinned development requirement")
        name, version = match.groups()
        names.append(name + "@" + version)
        queries.append({"package": {"name": name, "ecosystem": "PyPI"}, "version": version})
    request = Request(
        "https://api.osv.dev/v1/querybatch",
        data=json.dumps({"queries": queries}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urlopen(request, timeout=60) as response:
        results = json.load(response)["results"]
    if len(results) != len(queries):
        raise ValueError("Incomplete vulnerability response")
    findings = 0
    for name, result in zip(names, results):
        if "error" in result:
            raise ValueError("Vulnerability query failed: " + name)
        for vulnerability in result.get("vulns", []):
            findings += 1
            print(name + ": https://osv.dev/vulnerability/" + vulnerability["id"])
    print(f"Checked {len(queries)} pinned dependencies; {findings} advisory matches.")
    print("Coverage is OSV's known commit/package records, not proof of safety.")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
