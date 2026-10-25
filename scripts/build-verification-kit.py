#!/usr/bin/env python3
"""Bundle first-party test materials and existing fixture helpers for standalone use."""

import hashlib
import json
import shutil
import subprocess
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"
DIST.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="rill-kit-") as temp:
    kit = Path(temp) / "Rill-Verification-Kit"
    shutil.copytree(
        ROOT / "verification",
        kit,
        ignore=shutil.ignore_patterns("__pycache__", ".venv", "results", "*.pyc"),
    )
    shutil.copy2(ROOT / "LICENSE", kit / "LICENSE")
    support = kit / "support"
    support.mkdir()
    for filename in ["live-fixture.py", "mqtt_fixture.py", "amqp_fixture.py", "tls-fixture.py"]:
        shutil.copy2(ROOT / "scripts" / filename, support / filename)
    origin = {
        "project": "Rill",
        "sourceCommit": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
        ).strip(),
        "dirtySource": bool(
            subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip()
        ),
        "data": "first-party synthetic verification materials; no user workspace or credentials",
        "optionalDependency": "grpcio 1.80.0 is installed separately, not bundled",
    }
    (kit / "ORIGIN.json").write_text(json.dumps(origin, indent=2) + "\n")
    manifest = "".join(
        hashlib.sha256(p.read_bytes()).hexdigest() + "  " + str(p.relative_to(kit)) + "\n"
        for p in sorted(kit.rglob("*"))
        if p.is_file()
    )
    (kit / "SHA256SUMS").write_text(manifest)
    destination = DIST / "Rill-Verification-Kit.zip"
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(kit.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(Path(temp)))
    (DIST / "Rill-Verification-Kit.zip.sha256").write_text(
        hashlib.sha256(destination.read_bytes()).hexdigest() + "  " + destination.name + "\n"
    )
print(destination)
