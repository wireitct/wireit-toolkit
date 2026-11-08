"""Answers every POST with {"ok": true} and appends each body to a file (2.2.6 outbox test). Loopback only."""
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(n).decode('utf-8', 'replace')
        with open(sys.argv[2], 'a', encoding='utf-8') as f:
            f.write(body + '\n')
        out = b'{"ok": true}'
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(out))); self.end_headers(); self.wfile.write(out)

    def do_GET(self):
        out = b'pong'
        self.send_response(200); self.send_header('Content-Length', str(len(out))); self.end_headers(); self.wfile.write(out)


s = ThreadingHTTPServer(('127.0.0.1', 0), H)
with open(sys.argv[1], 'w') as f:
    f.write(str(s.server_port))
s.serve_forever()
