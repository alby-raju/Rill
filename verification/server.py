#!/usr/bin/env python3
"""Synthetic, loopback-only Rill acceptance playground. Python standard library."""
import base64
import importlib.util
import json
from pathlib import Path
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parent
SUPPORT = ROOT / 'support' if (ROOT / 'support').exists() else ROOT.parent / 'scripts'
sys.path.insert(0, str(SUPPORT))
LOCK = threading.Lock()
COUNTS = {}
PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZ1kAAAAASUVORK5CYII=')

class Server(ThreadingHTTPServer):
    daemon_threads = True
    def server_bind(self):
        # Do not trigger reverse DNS during local startup.
        from socketserver import TCPServer
        TCPServer.server_bind(self)
        self.server_name = '127.0.0.1'
        self.server_port = self.server_address[1]

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def send(self, status, body, mime='application/json', headers=None):
        if not isinstance(body, bytes): body = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('X-Rill-Fixture', 'verification-kit')
        for key, value in (headers or {}).items(): self.send_header(key, value)
        self.end_headers()
        if self.command != 'HEAD':
            try: self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError): pass
    def handle_request(self):
        self.connection.settimeout(10)
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 <= length <= 1024 * 1024: self.send(413, {'error':'body limit'}); return
            body = self.rfile.read(length)
        except (ValueError, OSError): self.send(400, {'error':'invalid body'}); return
        url = urlsplit(self.path); path = url.path; query = parse_qs(url.query, keep_blank_values=True)
        if path == '/oauth/token' and self.command == 'POST':
            fields = parse_qs(body.decode('utf-8',errors='replace'))
            basic = self.headers.get('Authorization') == 'Basic ' + base64.b64encode(b'rill:demo-password').decode()
            form = fields.get('client_id') == ['rill'] and fields.get('client_secret') == ['demo-password']
            valid = fields.get('grant_type') == ['client_credentials'] and (basic or form)
            self.send(200 if valid else 400, {'access_token':'rill-demo-token','token_type':'Bearer','expires_in':3600} if valid else {'error':'invalid_client'})
            return
        if path == '/health': self.send(200, {'ok':True,'service':'Rill verification kit'}); return
        if path == '/reset' and self.command == 'POST':
            with LOCK: COUNTS.clear()
            self.send(200, {'reset':True}); return
        if path == '/session' and self.command == 'POST': self.send(201, {'token':'rill-demo-token','user':{'id':'user-42'}}); return
        if path in ['/auth/basic','/auth/bearer','/auth/api-key','/profile']:
            valid = (self.headers.get('Authorization') == 'Basic ' + base64.b64encode(b'rill:demo-password').decode() if path == '/auth/basic' else
                     self.headers.get('X-API-Key') == 'rill-demo-key' if path == '/auth/api-key' else self.headers.get('Authorization') == 'Bearer rill-demo-token')
            self.send(200 if valid else 401, {'authenticated':valid,'user':{'id':'user-42'}}); return
        if path == '/flaky':
            key = query.get('key',['manual'])[0]
            with LOCK:
                if key not in COUNTS and len(COUNTS) >= 1000: self.send(429, {'error':'reset fixture counters'}); return
                COUNTS[key] = COUNTS.get(key,0)+1; attempt = COUNTS[key]
            self.send(503 if attempt == 1 else 200, {'attempt':attempt,'recovered':attempt > 1}); return
        if path.startswith('/delay/'):
            try: delay = float(path.split('/')[-1]); assert 0 <= delay <= 10
            except (ValueError, AssertionError): self.send(400, {'error':'delay 0..10'}); return
            time.sleep(delay); self.send(200, {'delayedSeconds':delay}); return
        if path.startswith('/status/'):
            try: status = int(path.split('/')[-1]); assert 200 <= status <= 599
            except (ValueError, AssertionError): self.send(400, {'error':'status 200..599'}); return
            self.send(status, {'status':status}); return
        if path.startswith('/bytes/'):
            try: size = int(path.split('/')[-1]); assert 0 <= size <= 17*1024*1024
            except (ValueError, AssertionError): self.send(400, {'error':'size 0..17825792'}); return
            self.send(200, b'x'*size, 'application/octet-stream'); return
        if path == '/echo':
            self.send(200, {'method':self.command,'path':path,'query':query,'headers':dict(self.headers),
                            'bodyText':body.decode('utf-8',errors='replace'),'bodyBase64':base64.b64encode(body).decode(),'bodyBytes':len(body)}); return
        if path == '/json': self.send(200, {'id':42,'name':'Rill demo','active':True,'items':[{'id':1,'price':12.5},{'id':2,'price':0}],'unicode':'Hello 👋 café'}); return
        if path == '/invalid-json': self.send(200, b'{"broken":', 'application/json'); return
        if path == '/xml': self.send(200, b'<catalog><item id="42">Rill demo</item></catalog>', 'application/xml'); return
        if path == '/html': self.send(200, b'<html><body><h1>Rill demo</h1><script>window.fixture=true</script></body></html>', 'text/html'); return
        if path == '/image': self.send(200, PNG, 'image/png'); return
        if path == '/redirect': self.send(302, b'', 'text/plain', {'Location':'/json'}); return
        self.send(404, {'error':'unknown fixture route'})
    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = handle_request

def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, SUPPORT / filename)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result); return result

def start_services():
    live = module('rill_live_fixture','live-fixture.py')
    mqtt = module('rill_mqtt_fixture','mqtt_fixture.py')
    amqp = module('rill_amqp_fixture','amqp_fixture.py')
    servers = []
    try:
        for factory, port, handler in [(Server,18990,Handler),(live.Server,18991,live.Handler),(mqtt.Server,18992,mqtt.Handler),(amqp.Server,18993,amqp.Handler)]:
            servers.append(factory(('127.0.0.1',port),handler))
        for server in servers: threading.Thread(target=server.serve_forever,daemon=True).start()
        return servers
    except Exception:
        for server in servers: server.server_close()
        raise

def main():
    try: servers = start_services()
    except OSError as error: raise SystemExit('Could not bind kit ports 18990–18993. Stop the conflicting service and retry. ' + str(error))
    stopping = threading.Event()
    for number in (signal.SIGINT,signal.SIGTERM): signal.signal(number,lambda *_: stopping.set())
    print('Rill verification kit ready (synthetic data only)\nHTTP http://127.0.0.1:18990\nGraphQL/SSE/WebSocket http://127.0.0.1:18991\nMQTT mqtt://127.0.0.1:18992\nAMQP amqp://127.0.0.1:18993\nCtrl+C stops all four services.',flush=True)
    try: stopping.wait()
    finally:
        for server in servers: server.shutdown(); server.server_close()
if __name__ == '__main__': main()
