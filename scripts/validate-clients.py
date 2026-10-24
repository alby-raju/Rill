#!/usr/bin/env python3
"""Compile/run only synthetic generated fixtures against an owned loopback server.

Usage: python validate-clients.py FIXTURES --targets requests,httpx,fetch,axios,java,okhttp,go,rust,csharp
SDKs/toolchains must already be installed. No workspace inputs or package install here.
"""
import argparse
import base64
import http.server
import json
import os
import pathlib
import queue
import shutil
import subprocess
import tempfile
import threading
import urllib.parse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("fixtures", type=pathlib.Path)
parser.add_argument("--targets", required=True)
args = parser.parse_args()
targets = args.targets.split(",")
allowed = {"requests", "httpx", "fetch", "axios", "java", "okhttp", "go", "rust", "csharp"}
if not set(targets) <= allowed:
    raise SystemExit("Unknown target")
received = queue.Queue()
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args):
        pass
    def handle_request(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length > 1048576 or self.headers.get("Transfer-Encoding"):
            self.send_error(400); return
        body = self.rfile.read(length)
        received.put((self.command, self.path, {k.lower(): v for k, v in self.headers.items()}, body))
        payload = b"x" * 16777217 if self.path == "/overflow" else b"synthetic response"
        self.send_response(302 if self.path == "/redirect" else 200)
        if self.path == "/redirect": self.send_header("Location", "http://127.0.0.1:1/never-follow")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if self.command != "HEAD":
            try: self.wfile.write(payload)
            except (BrokenPipeError, ConnectionResetError): pass
    do_GET = do_HEAD = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = handle_request
server = http.server.ThreadingHTTPServer(("127.0.0.1", 18750), Handler)
server.daemon_threads = True
thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()

def run(command, cwd, timeout=120, check=True):
    # Avoid proxy/runtime injection in this independent SDK interoperability check.
    env = {k: v for k, v in os.environ.items() if k.lower() not in {
        "http_proxy", "https_proxy", "all_proxy", "node_options", "java_tool_options", "jdk_java_options"}}
    return subprocess.run(command, cwd=cwd, env=env, check=check, capture_output=True, timeout=timeout)

def command_for(target, source, folder):
    if target in {"requests", "httpx"}:
        return [os.environ.get("RILL_CLIENT_PYTHON", "python3"), str(source)]
    if target in {"fetch", "axios"}:
        script = folder / "request.mjs"; shutil.copyfile(source, script)
        if target == "axios":
            modules = pathlib.Path(os.environ["RILL_CLIENT_NODE_MODULES"]).resolve()
            (folder / "node_modules").symlink_to(modules, target_is_directory=True)
        return ["node", str(script)]
    if target in {"java", "okhttp"}:
        script = folder / "RillRequest.java"; shutil.copyfile(source, script)
        java = pathlib.Path(os.environ["RILL_CLIENT_JAVA_HOME"]) / "bin"
        classpath = os.environ.get("RILL_CLIENT_OKHTTP_CLASSPATH", ".") if target == "okhttp" else "."
        run([str(java / "javac"), "-cp", classpath, str(script)], folder)
        return [str(java / "java"), "-cp", str(folder) + os.pathsep + classpath, "RillRequest"]
    if target == "go":
        script = folder / "request.go"; shutil.copyfile(source, script)
        run(["go", "build", "-o", "request", str(script)], folder)
        return [str(folder / "request")]
    if target == "rust":
        (folder / "src").mkdir(); shutil.copyfile(source, folder / "src/main.rs")
        (folder / "Cargo.toml").write_text('[package]\nname="rill-client-fixture"\nversion="0.1.0"\nedition="2021"\n[dependencies]\nreqwest={version="=0.13.5", features=["blocking"]}\nbase64="=0.22.1"\n')
        run(["cargo", "build", "--quiet", "--target-dir", os.environ.get("RILL_CLIENT_CARGO_TARGET", str(folder / "target"))], folder, timeout=300)
        return [str(pathlib.Path(os.environ.get("RILL_CLIENT_CARGO_TARGET", str(folder / "target"))) / "debug/rill-client-fixture")]
    (folder / "Fixture.csproj").write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>')
    shutil.copyfile(source, folder / "Program.cs")
    run(["dotnet", "build", "--nologo", "-o", "out"], folder)
    return ["dotnet", str(folder / "out/Fixture.dll")]

try:
    for case in sorted(args.fixtures.iterdir()):
        if not case.is_dir(): continue
        expected = json.loads((case / "expected.json").read_text())
        parts = urllib.parse.urlsplit(expected["url"])
        assert parts.scheme == "http" and parts.hostname == "127.0.0.1" and parts.port == 18750
        for target in targets:
            source = (case / (target + ".txt")).resolve()
            with tempfile.TemporaryDirectory(prefix="rill-client-") as temp:
                folder = pathlib.Path(temp)
                try:
                    result = run(command_for(target, source, folder), folder, timeout=30, check=False)
                    assert (result.returncode != 0) == expected.get("overflow", False), (target, "exit status", result.stderr.decode(errors="replace")[:1000])
                    method, path, headers, body = received.get(timeout=2)
                    assert method == expected["method"], (target, "method")
                    assert path == parts.path + ("?" + parts.query if parts.query else ""), (target, "URL")
                    assert body == base64.b64decode(expected["body"]), (target, "body")
                    for key, value in expected["headers"].items():
                        assert headers.get(key.lower()) == value, (target, "header", key)
                    assert result.stdout == (b"" if method == "HEAD" or expected.get("overflow", False) else b"synthetic response"), (target, "response")
                    assert received.empty(), (target, "unexpected extra request")
                except subprocess.CalledProcessError as error:
                    raise RuntimeError(f"{case.name}/{target}: {error.stderr.decode(errors='replace')[:4000]}") from error
                print(f"PASS {case.name}/{target}", flush=True)
finally:
    server.shutdown(); server.server_close()
