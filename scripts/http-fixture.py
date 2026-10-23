"""Loopback fixture for transport integration tests. No external service needed."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import time

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/slow':
            time.sleep(5)
        if self.path == '/large':
            self.send_response(200)
            self.send_header('Content-Length', str(17 * 1024 * 1024))
            self.end_headers()
            try:
                for _ in range(17):
                    self.wfile.write(b'x' * (1024 * 1024))
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        body = b'{"message":"hello from fixture"}'
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('X-Fixture', 'Rill')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
    def log_message(self, *_):
        pass

if __name__ == '__main__':
    import sys
    server = ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1]) if len(sys.argv) > 1 else 18749), Handler)
    print(f'Listening on http://127.0.0.1:{server.server_port}', flush=True)
    server.serve_forever()
