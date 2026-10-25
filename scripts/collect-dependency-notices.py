#!/usr/bin/env python3
"""Collect licenses from pinned dependency checkouts, including vendored native components."""

import argparse
import hashlib
import json
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("--check", action="store_true")
args = parser.parse_args()
pins = json.loads((root / "Package.resolved").read_text())["pins"]
sections = [
    "Rill dependency notices\n\nSelected dependency source graph, including vendored compiler/TLS/compression components. Some transitive packages are not linked into every artifact.\n"
]
skip = {".git", "Tests", "IntegrationTests", "Benchmarks", "Examples", "PerformanceTests"}
for pin in sorted(pins, key=lambda pin: pin["identity"]):
    name = pin["location"].rstrip("/").rsplit("/", 1)[-1].removesuffix(".git")
    checkout = root / ".build" / "checkouts" / name
    revision = subprocess.check_output(
        ["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True
    ).strip()
    if revision != pin["state"]["revision"]:
        raise SystemExit(f"Unexpected dependency revision: {name}")
    if subprocess.check_output(
        ["git", "-C", str(checkout), "status", "--porcelain", "--untracked-files=no"], text=True
    ).strip():
        raise SystemExit(f"Modified dependency checkout: {name}")
    files = []
    for path in checkout.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        relative = path.relative_to(checkout)
        if any(part in skip or part.endswith(".docc") for part in relative.parts):
            continue
        if not path.name.upper().startswith(("LICENSE", "COPYING", "NOTICE")):
            continue
        if path.stat().st_size > 512 * 1024:
            raise SystemExit(f"Oversized notice: {relative}")
        files.append(path)
    if not files:
        raise SystemExit(f"Missing license: {name}")
    sections.append(
        f"\n{'=' * 72}\n{name} {pin['state'].get('version', revision)}\n{pin['location']}\nPinned revision: {revision}\n"
    )
    for path in sorted(files):
        data = path.read_bytes()
        sections.append(
            f"\n--- {path.relative_to(checkout)} · SHA256 {hashlib.sha256(data).hexdigest()} ---\n"
            + data.decode("utf-8")
            + "\n"
        )
for path in sorted((root / "ThirdParty").glob("*.txt")):
    sections.append(
        f"\n{'=' * 72}\nAdditional vendored notice: {path.name}\n" + path.read_text() + "\n"
    )
text = "".join(sections)
if len(text.encode()) > 8 * 1024 * 1024:
    raise SystemExit("Notice output exceeds 8 MiB")
destination = root / "THIRD_PARTY_NOTICES.txt"
if args.check:
    if destination.read_text() != text:
        raise SystemExit("Dependency notices are stale; run scripts/collect-dependency-notices.py")
else:
    destination.write_text(text)
print(f"Pinned dependency notices verified: {len(pins)} packages, {len(text.encode())} bytes")
