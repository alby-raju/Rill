#!/usr/bin/env python3
"""Validate an immutable prerelease candidate before spending build resources."""

import json
import os
import re
import subprocess
import sys
from pathlib import Path


def api(path):
    return json.loads(subprocess.check_output(["gh", "api", path], text=True))


def main():
    tag = sys.argv[1]
    version_source = Path("Sources/RillCore/Support/RillVersion.swift").read_text()
    version = re.search(r'"(\d+\.\d+\.\d+)"', version_source).group(1)
    if not re.fullmatch(r"v" + re.escape(version) + r"-dev\.[1-9][0-9]*", tag):
        raise ValueError("Tag must match the source version: v" + version + "-dev.N")
    if os.environ["GITHUB_REF"] != "refs/heads/main":
        raise ValueError("Release workflow must run on main")
    repository = os.environ["GITHUB_REPOSITORY"]
    sha = os.environ["GITHUB_SHA"]
    # Ask GitHub to match exactly; a failed lookup must not be mistaken for no tag.
    refs = api(f"repos/{repository}/git/matching-refs/tags/{tag}")
    if any(ref["ref"] == "refs/tags/" + tag for ref in refs):
        raise ValueError("Tag already exists; never replace release tags")
    releases = api(f"repos/{repository}/releases?per_page=100")
    if any(release["tag_name"] == tag for release in releases):
        raise ValueError("Release or draft already exists")
    runs = api(f"repos/{repository}/commits/{sha}/check-runs?per_page=100")["check_runs"]
    required = {
        "Build and test on macOS",
        "Dependency vulnerability scan",
        "CodeQL / swift",
        "CodeQL / python",
    }
    for name in required:
        matches = [
            run for run in runs if run["name"] == name and run["app"]["slug"] == "github-actions"
        ]
        if not matches or matches[0]["conclusion"] != "success":
            raise ValueError("Required successful check missing: " + name)
    print("Validated new prerelease tag, main revision and CI/security checks.")


if __name__ == "__main__":
    main()
