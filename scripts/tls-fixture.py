"""Generate disposable local TLS/mTLS fixtures. Never uses a personal Keychain."""
import os
from pathlib import Path
import ssl
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
os.chmod(root, 0o700)
os.umask(0o077)

def openssl(*args):
    subprocess.run(['openssl', *args], cwd=root, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
        '-subj', '/CN=RillFixtureRoot', '-keyout', 'ca.key', '-out', 'ca.pem')
for kind, usage, subject in [('server', 'serverAuth', 'localhost'),
                             ('client', 'clientAuth', 'RillFixtureClient')]:
    openssl('req', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=' + subject,
            '-keyout', kind + '.key', '-out', kind + '.csr')
    extension = 'basicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=' + usage + '\n'
    if kind == 'server':
        extension += 'subjectAltName=DNS:localhost\n'
    (root / (kind + '.ext')).write_text(extension)
    openssl('x509', '-req', '-in', kind + '.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key',
            '-CAcreateserial', '-days', '2', '-extfile', kind + '.ext', '-out', kind + '.pem')
openssl('x509', '-in', 'ca.pem', '-outform', 'DER', '-out', 'ca.der')
openssl('pkcs12', '-export', '-in', 'client.pem', '-inkey', 'client.key', '-certfile', 'ca.pem',
        '-out', 'client.p12', '-passout', 'pass:rill-fixture',
        '-keypbe', 'PBE-SHA1-3DES', '-certpbe', 'PBE-SHA1-3DES', '-macalg', 'sha1')

class Server(ThreadingHTTPServer):
    def server_bind(self):
        TCPServer.server_bind(self)
        self.server_name = '127.0.0.1'
        self.server_port = self.server_address[1]

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'{"message":"TLS fixture"}'
        self.send_response(200)
        self.send_header('X-Fixture', 'RillTLS')
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_):
        pass

servers = []
for port, require_client in [(18750, False), (18751, True)]:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(root / 'server.pem', root / 'server.key')
    if require_client:
        context.load_verify_locations(root / 'ca.pem')
        context.verify_mode = ssl.CERT_REQUIRED
    server = Server(('127.0.0.1', port), Handler)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    servers.append(server)
    threading.Thread(target=server.serve_forever, daemon=True).start()
print('TLS fixtures ready', flush=True)
threading.Event().wait()
