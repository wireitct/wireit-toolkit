"""Loopback HTTP server for the 2.2.7 credential tests. Mode basic: every request gets 401 "Basic" (the password would be sent in
   clear text if a client answered it). Mode digest: 401 "Digest" until a Digest answer comes, then 200. Every Authorization header
   seen is written (scheme word only, never the value) to the log file, one per line. Port goes to the port file."""
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

mode, port_file, log_file = sys.argv[1], sys.argv[2], sys.argv[3]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def answer(self):
        n = int(self.headers.get('Content-Length') or 0)
        if n:
            self.rfile.read(n)
        auth = self.headers.get('Authorization') or ''
        with open(log_file, 'a') as f:
            f.write((auth.split(' ')[0] if auth else 'none') + '\n')
        try:
            if mode == 'digest' and auth.lower().startswith('digest '):
                b = b'<DeviceInfo><deviceName>ok</deviceName></DeviceInfo>'
                self.send_response(200); self.send_header('Content-Type', 'application/xml'); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
                return
            self.send_response(401)
            if mode == 'digest':
                self.send_header('WWW-Authenticate', 'Digest realm="IP Camera", qop="auth", nonce="4e6f6e63653132333435", opaque="0a1b2c", algorithm=MD5')
            else:
                self.send_header('WWW-Authenticate', 'Basic realm="IP Camera"')
            self.send_header('Content-Length', '0'); self.end_headers()
        except (BrokenPipeError, ConnectionResetError):
            pass

    do_GET = answer
    do_POST = answer
    do_PUT = answer


class S(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        pass


s = S(('127.0.0.1', 0), H)
open(port_file + '.tmp', 'w').write(str(s.server_port))
import os
os.replace(port_file + '.tmp', port_file)
s.serve_forever()
