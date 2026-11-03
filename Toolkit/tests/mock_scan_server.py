"""mock_scan_server.py - a stand-in for the service site's op scanPush (Toolkit tests only; no real site).
usage: python mock_scan_server.py <port> <bodies-file>   POST /first | /same | /missing answers like the real server."""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
PORT = int(sys.argv[1]); BODIES = sys.argv[2]
NVR = 'NVR Hikvision DS-7616NXI-I2/16P/S 192.168.1.20 44:19:B6:00:00:01'
CAM = 'Camera DS-2CD2143G2-I 192.168.1.21 44:19:B6:00:01:01'
BASE = {'ok': True, 'site': '2336 Main St', 'code': 'WI-064', 'snapshot': False, 'same': False, 'total': 2, 'added': [], 'changedIp': [], 'changed': [], 'missing': [], 'stillMissing': [], 'back': [], 'alerted': 0}
ANS = {
  'first': dict(BASE, added=[NVR, CAM]),
  'same': dict(BASE, same=True),
  'missing': dict(BASE, total=3, missing=['Camera DS-2CD2143G2-I 192.168.1.23 44:19:B6:00:01:03'], changedIp=[{'label': 'Camera DS-2CD2143G2-I 44:19:B6:00:01:01', 'from': '192.168.1.41', 'to': '192.168.1.21'}], alerted=1),
}
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, obj):
        b = json.dumps(obj).encode(); self.send_response(200); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self): self.send({'ok': True})
    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0); body = self.rfile.read(n).decode('utf-8', 'replace')
        with open(BODIES, 'a', encoding='utf-8') as f: f.write(body + '\n')
        try: req = json.loads(body)
        except Exception: return self.send({'ok': False, 'msg': 'bad json'})
        if req.get('op') != 'scanPush' or len(req.get('key') or '') < 32: return self.send({'ok': False, 'msg': 'Not allowed.'})
        mode = self.path.strip('/') or 'first'
        a = dict(ANS.get(mode, ANS['first'])); a['site'] = '2336 Main St' if '2336' in req.get('site', '') else req.get('site')
        self.send(a)
HTTPServer(('127.0.0.1', PORT), H).serve_forever()
