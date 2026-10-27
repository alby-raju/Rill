#!/usr/bin/env python3
"""Launch a relocated release app without access to SwiftPM's build-tree bundles."""

import os
import plistlib
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

app = Path(sys.argv[1]).resolve()
build_products = Path(sys.argv[2]).resolve()
repository_build = Path(__file__).resolve().parent.parent / ".build"
if not build_products.is_dir() or not build_products.is_relative_to(repository_build):
    raise SystemExit("Expected this checkout’s SwiftPM build-products directory")
with (app / "Contents/Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
if info.get("CFBundleIdentifier") != "app.rill.workbench":
    raise SystemExit("Expected a packaged Rill application")
with tempfile.TemporaryDirectory(prefix="rill-installed-smoke-") as temporary:
    relocated = Path(temporary) / "Relocated Rill.app"
    subprocess.run(["ditto", str(app), str(relocated)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(relocated)], check=True)
    environment = os.environ.copy()
    for key in ["PACKAGE_RESOURCE_BUNDLE_PATH", "PACKAGE_RESOURCE_BUNDLE_URL"]:
        environment.pop(key, None)
    hidden = []
    try:
        # A relocation alone is insufficient: generated accessors can fall back
        # to an absolute build-machine path even when the installed copy is broken.
        for bundle in build_products.glob("*.bundle"):
            target = bundle.with_name(".rill-hidden-" + uuid.uuid4().hex)
            bundle.rename(target)
            hidden.append((bundle, target))

        def launch():
            stdout = Path(temporary) / "launch.stdout"
            stderr = Path(temporary) / "launch.stderr"
            stdout.unlink(missing_ok=True)
            stderr.unlink(missing_ok=True)
            # Finder launches via Launch Services. Executing the Mach-O directly
            # can enter AppKit's event loop without opening a SwiftUI window.
            result = subprocess.run(
                [
                    "/usr/bin/open",
                    "-n",
                    "-W",
                    "--stdout",
                    str(stdout),
                    "--stderr",
                    str(stderr),
                    str(relocated),
                    "--args",
                    "--verify-installation",
                ],
                cwd=temporary,
                env=environment,
                capture_output=True,
                text=True,
                timeout=25,
            )
            return subprocess.CompletedProcess(
                result.args,
                result.returncode,
                stdout.read_text() if stdout.exists() else "",
                stderr.read_text() if stderr.exists() else result.stderr,
            )

        result = launch()
        expected = (
            "RILL_INSTALLATION_OK version="
            + info["CFBundleShortVersionString"]
            + " build="
            + info["CFBundleVersion"]
        )
        if result.returncode != 0 or expected not in result.stdout:
            raise SystemExit(
                "Relocated app launch/resource check failed; exit=" + str(result.returncode)
            )
        print(result.stdout.strip())
        help_files = list((relocated / "Contents/Resources").rglob("Help.json"))
        if not help_files:
            raise SystemExit("Packaged help input is missing")
        for help_file in help_files:
            help_file.unlink()
        subprocess.run(
            ["codesign", "--force", "--sign", "-", str(relocated)], check=True, capture_output=True
        )
        missing = launch()
        if (
            "Rill installation verification failed:" not in missing.stderr
            or "RILL_INSTALLATION_OK" in missing.stdout
        ):
            raise SystemExit("Missing packaged help was incorrectly accepted")
        print("Missing-resource negative case rejected; build-tree fallbacks unavailable.")
    finally:
        for original, target in reversed(hidden):
            target.rename(original)
