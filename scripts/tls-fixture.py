"""Generate disposable local TLS/mTLS fixtures. Never uses a personal Keychain."""

import os
import ssl
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
os.chmod(root, 0o700)
os.umask(0o077)


def openssl(*args):
    subprocess.run(
        ["openssl", *args], cwd=root, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE
    )


openssl(
    "req",
    "-x509",
    "-newkey",
    "rsa:2048",
    "-nodes",
    "-days",
    "2",
    "-subj",
    "/CN=RillFixtureRoot",
    "-keyout",
    "ca.key",
    "-out",
    "ca.pem",
)
for kind, usage, subject in [
    ("server", "serverAuth", "localhost"),
    ("client", "clientAuth", "RillFixtureClient"),
]:
    openssl(
        "req",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-subj",
        "/CN=" + subject,
        "-keyout",
        kind + ".key",
        "-out",
        kind + ".csr",
    )
    extension = (
        "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage="
        + usage
        + "\n"
    )
    if kind == "server":
        extension += "subjectAltName=DNS:localhost\n"
    (root / (kind + ".ext")).write_text(extension)
    openssl(
        "x509",
        "-req",
        "-in",
        kind + ".csr",
        "-CA",
        "ca.pem",
        "-CAkey",
        "ca.key",
        "-CAcreateserial",
        "-days",
        "2",
        "-extfile",
        kind + ".ext",
        "-out",
        kind + ".pem",
    )
openssl("x509", "-in", "ca.pem", "-outform", "DER", "-out", "ca.der")
openssl("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", "ec-client.key")
openssl(
    "req",
    "-new",
    "-key",
    "ec-client.key",
    "-subj",
    "/CN=RillFixtureECClient",
    "-out",
    "ec-client.csr",
)
openssl(
    "x509",
    "-req",
    "-in",
    "ec-client.csr",
    "-CA",
    "ca.pem",
    "-CAkey",
    "ca.key",
    "-CAcreateserial",
    "-days",
    "2",
    "-extfile",
    "client.ext",
    "-out",
    "ec-client.pem",
)
openssl(
    "pkcs12",
    "-export",
    "-in",
    "client.pem",
    "-inkey",
    "client.key",
    "-certfile",
    "ca.pem",
    "-out",
    "client.p12",
    "-passout",
    "pass:rill-fixture",
    "-keypbe",
    "PBE-SHA1-3DES",
    "-certpbe",
    "PBE-SHA1-3DES",
    "-macalg",
    "sha1",
)

# A separate intermediate chain proves file-run clients actually send supplied chain certificates.
openssl(
    "req",
    "-newkey",
    "rsa:2048",
    "-nodes",
    "-subj",
    "/CN=RillFixtureIntermediate",
    "-keyout",
    "intermediate.key",
    "-out",
    "intermediate.csr",
)
(root / "intermediate.ext").write_text(
    "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n"
)
openssl(
    "x509",
    "-req",
    "-in",
    "intermediate.csr",
    "-CA",
    "ca.pem",
    "-CAkey",
    "ca.key",
    "-CAcreateserial",
    "-days",
    "2",
    "-extfile",
    "intermediate.ext",
    "-out",
    "intermediate.pem",
)
openssl(
    "x509",
    "-req",
    "-in",
    "client.csr",
    "-CA",
    "intermediate.pem",
    "-CAkey",
    "intermediate.key",
    "-CAcreateserial",
    "-days",
    "2",
    "-extfile",
    "client.ext",
    "-out",
    "chained-client.pem",
)
(root / "client-bundle.pem").write_bytes(
    (root / "chained-client.pem").read_bytes() + (root / "intermediate.pem").read_bytes()
)
(root / "client-ca-chain.pem").write_bytes(
    (root / "intermediate.pem").read_bytes() + (root / "ca.pem").read_bytes()
)
openssl(
    "pkcs12",
    "-export",
    "-in",
    "chained-client.pem",
    "-inkey",
    "client.key",
    "-certfile",
    "client-ca-chain.pem",
    "-out",
    "chained-client.p12",
    "-passout",
    "pass:rill-fixture",
    "-keypbe",
    "PBE-SHA1-3DES",
    "-certpbe",
    "PBE-SHA1-3DES",
    "-macalg",
    "sha1",
)


class Server(ThreadingHTTPServer):
    def server_bind(self):
        TCPServer.server_bind(self)
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ["/redirect-same", "/redirect-cross"]:
            self.send_response(302)
            self.send_header(
                "Location",
                "/json" if self.path == "/redirect-same" else "https://localhost:18751/json",
            )
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = b'{"message":"TLS fixture"}'
        self.send_response(200)
        self.send_header("X-Fixture", "RillTLS")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


servers = []
for port, require_client in [(18750, False), (18751, True)]:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(root / "server.pem", root / "server.key")
    if require_client:
        context.load_verify_locations(root / "ca.pem")
        context.verify_mode = ssl.CERT_REQUIRED
    server = Server(("127.0.0.1", port), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    servers.append(server)
    threading.Thread(target=server.serve_forever, daemon=True).start()
print("TLS fixtures ready", flush=True)
threading.Event().wait()
