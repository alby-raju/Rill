#!/usr/bin/env python3
"""Conservative docs-only PR detection; unknown changes always require native CI."""

import json
import os
import subprocess
from pathlib import Path

PRIMARY = {"runner": "macos-15", "xcode": "26.3"}
FULL = [
    PRIMARY,
    {"runner": "macos-15", "xcode": "26.2"},
    {"runner": "macos-15-intel", "xcode": "26.3"},
]
ROOT_DOCS = {
    "README.md",
    "CONTRIBUTING.md",
    "SECURITY.md",
    "SUPPORT.md",
    "CHANGELOG.md",
    "ROADMAP.md",
}


def docs_only(paths):
    return bool(paths) and all(
        name in ROOT_DOCS
        or (name.startswith("docs/") and Path(name).suffix in {".md", ".csv", ".png"})
        for name in paths
    )


def main():
    event = os.environ["GITHUB_EVENT_NAME"]
    native = True
    if event == "pull_request":
        # Include both sides of renames/deletions, so moving source into docs cannot skip CI.
        changed = (
            subprocess.check_output(
                [
                    "git",
                    "diff",
                    "--no-renames",
                    "--name-only",
                    "-z",
                    os.environ["BASE_SHA"],
                    os.environ["HEAD_SHA"],
                ],
            )
            .decode()
            .rstrip("\0")
            .split("\0")
        )
        native = not docs_only(changed)
    matrix = {"include": FULL if event in {"schedule", "workflow_dispatch"} else [PRIMARY]}
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write("native=" + str(native).lower() + "\n")
        output.write("matrix=" + json.dumps(matrix) + "\n")
    print("Native checks required:", native, "matrix:", json.dumps(matrix))


if __name__ == "__main__":
    main()
