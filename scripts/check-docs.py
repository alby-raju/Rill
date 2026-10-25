#!/usr/bin/env python3
"""Validate the compact MVP documentation and preserved acceptance checklist."""

import csv
import re
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent
REQUIRED = [
    "README.md",
    "CONTRIBUTING.md",
    "LICENSE",
    "SECURITY.md",
    "SUPPORT.md",
    "CHANGELOG.md",
    "ROADMAP.md",
    "docs/ARCHITECTURE.md",
    "docs/FEATURES.md",
    "docs/TESTING.md",
    "docs/DEPENDENCIES.md",
    "docs/CLI.md",
    "docs/RELEASE.md",
    "docs/CAPABILITIES.csv",
    "docs/images/workbench-dark.png",
    "docs/images/welcome-light.png",
]


def check():
    for name in REQUIRED:
        if not (ROOT / name).is_file():
            raise ValueError("Missing documentation input: " + name)
    if not (ROOT / "LICENSE").read_text().startswith("MIT License\n"):
        raise ValueError("Expected the owner-selected MIT license")
    documents = [
        p
        for p in ROOT.rglob("*.md")
        if not any(
            part in {".git", ".build", ".venv", "dist"} for part in p.relative_to(ROOT).parts
        )
    ]
    links = 0
    for document in documents:
        text = re.sub(r"```.*?```", "", document.read_text(), flags=re.DOTALL)
        for target in re.findall(r"!?\[[^\]]*\]\(([^)]+)\)", text):
            target = target.strip().strip("<>")
            if target.startswith(("https://", "http://", "mailto:", "#")):
                continue
            target = unquote(target.split("#", 1)[0])
            path = document.parent / target
            if not path.exists():
                raise ValueError(f"Broken link in {document.relative_to(ROOT)}: {target}")
            links += 1
    with (ROOT / "docs/CAPABILITIES.csv").open(newline="") as stream:
        reader = csv.DictReader(stream)
        if reader.fieldnames != ["id", "area", "status", "capability", "acceptance", "evidence"]:
            raise ValueError("Unexpected capability columns")
        rows = list(reader)
    if len(rows) < 122 or len({row["id"] for row in rows}) != len(rows):
        raise ValueError("Capability IDs were lost or duplicated")
    for row in rows:
        if not re.fullmatch(r"[A-Z]+-\d{2,}", row["id"]) or row["status"] not in {
            "planned",
            "partial",
            "verified",
            "deviation",
        }:
            raise ValueError("Invalid capability: " + row["id"])
        if not all(row[key].strip() for key in reader.fieldnames):
            raise ValueError("Missing capability evidence/acceptance: " + row["id"])
    for image in (ROOT / "docs/images").glob("*.png"):
        if not image.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError("Invalid screenshot: " + image.name)
    print(
        f"Documentation passed: {len(documents)} pages, {links} local links, {len(rows)} preserved capabilities."
    )


if __name__ == "__main__":
    check()
