"""Independently authored loopback GraphQL/SSE/WebSocket test fixture (stdlib only)."""
import base64
import hashlib
import json
import socket
import struct
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer
from mqtt_fixture import session as mqtt_session

class Server(ThreadingHTTPServer):
    daemon_threads = True
    def server_bind(self):
        TCPServer.server_bind(self); self.server_name = "127.0.0.1"; self.server_port = self.server_address[1]

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *_): pass
    def json_response(self, body, status=200):
        data = json.dumps(body).encode()
        self.send_response(status); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if not 0 <= length <= 2 * 1024 * 1024: self.send_error(413); return
        try: body = json.loads(self.rfile.read(length))
        except (ValueError, UnicodeError): self.send_error(400); return
        if self.path == "/graphql-disabled": self.json_response({"errors": [{"message": "Introspection disabled"}]}); return
        if self.path == "/graphql-errors": self.json_response({"data": None, "errors": [{"message": "Synthetic GraphQL error"}]}); return
        if "__schema" in body.get("query", ""):
            self.json_response({"data": {"__schema": {"queryType": {"name": "Query"}, "types": [{"kind": "OBJECT", "name": "Query", "fields": [{"name": "hello", "args": [{"name": "recipient"}]}]}, {"kind": "ENUM", "name": "Color", "enumValues": [{"name": "BLUE"}]}]}}}); return
        self.json_response({"data": {"echo": body.get("variables"), "query": body.get("query")}})
    def do_GET(self):
        if self.path == "/health": self.json_response({"fixture": "RillLive"}); return
        if self.path.startswith("/sse"):
            if self.path == "/sse-bad": self.json_response({}); return
            body = b'\xef\xbb\xbfid: first\r\nevent: update\r\ndata: hello\rdata: \xf0\x9f\x90\x9f\r\nretry: 1000\r\n\r\n: comment\nid:\ndata: second\n\n'
            self.send_response(200); self.send_header("Content-Type", "text/event-stream")
            if self.path == "/sse": self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                for index in range(0, len(body), 3): self.wfile.write(body[index:index+3]); self.wfile.flush()
                if self.path == "/sse-stall": time.sleep(20)
            except (BrokenPipeError, ConnectionResetError): pass
            return
        if self.headers.get("Upgrade", "").lower() != "websocket": self.send_error(404); return
        key = self.headers.get("Sec-WebSocket-Key", "")
        try:
            if len(base64.b64decode(key, validate=True)) != 16: self.send_error(400); return
        except ValueError: self.send_error(400); return
        self.send_response(101); self.send_header("Upgrade", "websocket"); self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode())
        if self.path.startswith("/subscription"):
            self.send_header("Sec-WebSocket-Protocol", "graphql-transport-ws")
        if self.path.startswith("/mqtt"):
            self.send_header("Sec-WebSocket-Protocol", "mqtt")
        self.end_headers(); self.connection.settimeout(5)
        try: self.websocket()
        except (OSError, ValueError, EOFError): pass
        self.close_connection = True
    def frame(self, opcode, payload=b"", final=True):
        header = bytes([(128 if final else 0) | opcode])
        if len(payload) < 126: header += bytes([len(payload)])
        elif len(payload) <= 65535: header += b'\x7e' + struct.pack('!H', len(payload))
        else: header += b'\x7f' + struct.pack('!Q', len(payload))
        self.connection.sendall(header + payload)
    def exact(self, length):
        data = self.rfile.read(length)
        if len(data) != length: raise EOFError()
        return data
    def mqtt_websocket(self):
        buffer = bytearray()
        def read(count):
            while len(buffer) < count:
                fragmented = bytearray(); initial = None
                while True:
                    first, second = self.exact(2); opcode = first & 15; length = second & 127
                    if not second & 128 or first & 112: raise ValueError("Invalid frame")
                    if length == 126: length = struct.unpack('!H', self.exact(2))[0]
                    elif length == 127: length = struct.unpack('!Q', self.exact(8))[0]
                    if length > 1024 * 1024 + 65536: raise ValueError("Oversize")
                    mask = self.exact(4); body = bytes(value ^ mask[index % 4] for index, value in enumerate(self.exact(length)))
                    if opcode == 8: raise EOFError()
                    if opcode == 9: self.frame(10, body); continue
                    if opcode == 10: continue
                    if opcode == 2 and initial is None: initial = opcode
                    elif opcode != 0 or initial is None: raise ValueError("Binary required")
                    fragmented.extend(body)
                    if len(fragmented) > 1024 * 1024 + 65536: raise ValueError("Oversize")
                    if first & 128: break
                buffer.extend(fragmented)
            result = bytes(buffer[:count]); del buffer[:count]; return result
        def write(body):
            split = max(1, len(body)//2)
            self.frame(2, body[:split], final=False); self.frame(0, body[split:])
        mqtt_session(read, write)
    def websocket(self):
        if self.path.startswith("/mqtt"):
            self.mqtt_websocket(); return
        subscription = self.path.startswith("/subscription")
        if not subscription:
            self.frame(1, b"frag", final=False); self.frame(0, b"mented")
        fragmented = bytearray(); initial = None; initialized = False
        for _ in range(1000):
            first, second = self.exact(2)
            final = bool(first & 128); opcode = first & 15
            if first & 112 or not second & 128: raise ValueError("Invalid frame")
            length = second & 127
            if length == 126: length = struct.unpack('!H', self.exact(2))[0]
            elif length == 127: length = struct.unpack('!Q', self.exact(8))[0]
            if length > 1024 * 1024: raise ValueError("Oversized frame")
            mask = self.exact(4); payload = bytes(value ^ mask[index % 4] for index, value in enumerate(self.exact(length)))
            if opcode == 8: self.frame(8, payload[:125]); return
            if opcode == 9: self.frame(10, payload); continue
            if opcode == 10: continue
            if opcode in (1, 2):
                if initial is not None: raise ValueError("Interleaved data")
                initial = opcode
            elif opcode != 0 or initial is None: raise ValueError("Invalid continuation")
            fragmented.extend(payload)
            if len(fragmented) > 1024 * 1024: raise ValueError("Oversized message")
            if not final: continue
            payload = bytes(fragmented); opcode = initial; initial = None; fragmented.clear()
            if not subscription: self.frame(opcode, payload); continue
            if opcode != 1: raise ValueError("GraphQL text required")
            message = json.loads(payload)
            kind = message.get("type")
            if kind == "connection_init":
                initialized = True
                if self.path == "/subscription-no-ack": continue
                self.frame(1, b'{"type":"ping","payload":{"check":true}}')
                self.frame(1, b'{"type":"connection_ack"}')
            elif kind == "pong": pass
            elif kind == "subscribe" and initialized:
                identifier = message["id"]
                self.frame(1, json.dumps({"id": identifier, "type": "next", "payload": {"data": {"value": 1}}}).encode())
                self.frame(1, json.dumps({"id": identifier, "type": "complete"}).encode())
                # Client owns closing after complete; do not race its send callback.
            elif kind == "complete": self.frame(8, struct.pack('!H', 1000)); return
            else: raise ValueError("Invalid protocol order")

if __name__ == '__main__':
    Server(('127.0.0.1', 18755), Handler).serve_forever()
