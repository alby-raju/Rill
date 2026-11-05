#!/usr/bin/env python3
"""Package and verify a relocatable CLI-only archive from the already packaged app."""

import hashlib
import json
import platform
import plistlib
import shutil
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"
APP = DIST / "Rill.app" / "Contents"


def run(*arguments: str) -> bytes:
    return subprocess.check_output(arguments, timeout=60, stderr=subprocess.PIPE)


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *_arguments: object) -> None:
        pass


def main() -> None:
    with (APP / "Info.plist").open("rb") as handle:
        version = plistlib.load(handle)["CFBundleShortVersionString"]
    name = f"RillCLI-{version}-{platform.machine()}-development"
    with tempfile.TemporaryDirectory(prefix=".rill-cli.", dir=DIST) as temporary:
        stage = Path(temporary)
        installation = stage / name
        binary = installation / "bin" / "rill"
        binary.parent.mkdir(parents=True)
        shutil.copy2(APP / "Helpers" / "rill", binary)
        for directory in ("Resources", "Frameworks"):
            shutil.copytree(APP / directory, installation / directory)
        for file in ("LICENSE", "THIRD_PARTY_NOTICES.txt", "Package.resolved"):
            shutil.copy2(ROOT / file, installation / file)
        shutil.copy2(ROOT / "docs" / "CLI.md", installation / "CLI.md")
        completions = installation / "completions"
        completions.mkdir()
        for shell, filename in (("bash", "rill.bash"), ("zsh", "_rill"), ("fish", "rill.fish")):
            (completions / filename).write_bytes(run(str(binary), "completion", shell))
        (installation / "README.txt").write_text(
            "Rill CLI development preview — macOS 15+\n\n"
            "Extract and keep this entire directory together. Add its bin directory to PATH.\n"
            "Do not copy only bin/rill: Resources and Frameworks must remain beside bin.\n"
            "Run rill doctor --json, rill help run, and read CLI.md.\n"
            "Ad-hoc signed; not notarized. No automatic installation or shell changes.\n",
            encoding="utf-8",
        )
        # Relocation with spaces exercises resource lookup independently of the app layout.
        relocated = stage / "relocated CLI with spaces" / name
        relocated.parent.mkdir()
        shutil.copytree(installation, relocated)
        executable = str(relocated / "bin" / "rill")
        assert run(executable, "--version").decode().strip() == version
        diagnostics = json.loads(run(executable, "doctor", "--json"))
        assert diagnostics["passed"]
        assert any(
            check["id"] == "protobufCompiler" and check["status"] == "passed"
            for check in diagnostics["checks"]
        )
        run("codesign", "--verify", "--strict", executable)
        source = stage / "fixture.proto"
        source.write_text(
            'syntax = "proto3"; import "google/protobuf/timestamp.proto"; '
            "message Fixture { google.protobuf.Timestamp time = 1; }\n",
            encoding="utf-8",
        )
        run(
            str(relocated / "Resources" / "protoc"),
            f"--proto_path={stage}",
            f"--proto_path={relocated / 'Resources' / 'protobuf-includes'}",
            f"--descriptor_set_out={stage / 'fixture.pb'}",
            str(source),
        )
        server = ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            result = json.loads(
                run(
                    executable, "request", "GET", f"http://127.0.0.1:{server.server_port}", "--json"
                )
            )
            assert result["status"] == 200
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=5)
        archive = DIST / (name + ".zip")
        run("ditto", "-c", "-k", "--keepParent", str(installation), str(archive))
        (DIST / (archive.name + ".sha256")).write_text(
            f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n",
            encoding="utf-8",
        )
        provenance = {
            "artifact": archive.name,
            "sourceCommit": run("git", "-C", str(ROOT), "rev-parse", "HEAD").decode().strip(),
            "dirtySource": bool(run("git", "-C", str(ROOT), "status", "--porcelain").strip()),
            "architecture": platform.machine(),
            "signing": "ad-hoc development; not notarized",
            "verification": ["relocated doctor", "signature", "protobuf includes", "loopback HTTP"],
        }
        (DIST / (name + ".provenance.json")).write_text(
            json.dumps(provenance, indent=2) + "\n", encoding="utf-8"
        )
        print(f"Verified CLI-only archive: {archive.name}")


if __name__ == "__main__":
    main()
