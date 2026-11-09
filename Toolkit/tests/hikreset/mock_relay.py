#!/usr/bin/env python3
"""mock_relay.py - a stand-in for appsscript/HikRelay.gs (op hikReplyGet), plain http on 127.0.0.1 for the Toolkit tests.
usage: mock_relay.py PORT DATADIR KEY
DATADIR/replies.json = {"<serial or short serial>": {"kind": "file", "name": "...", "data": "<base64>"} | {"kind": "code", "code": "..."}}
DATADIR/mode.txt (optional) = ok | down (HTTP 500) | junk (not JSON) | slow (25 s)
Every request is appended to DATADIR/requests.log as JSON with the key replaced by key_ok true/false. A reply is served once."""
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT, DATA, KEY = int(sys.argv[1]), sys.argv[2], sys.argv[3]

def mode():
    try:
        return open(os.path.join(DATA, 'mode.txt')).read().strip()
    except OSError:
        return 'ok'

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body, ctype='application/json'):
        b = body.encode()
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(n)
        try:
            req = json.loads(raw.decode('utf-8'))
        except Exception:
            req = {}
        logged = {k: v for k, v in req.items() if k != 'key'}
        logged['key_ok'] = req.get('key') == KEY
        logged['ua'] = self.headers.get('User-Agent', '')
        with open(os.path.join(DATA, 'requests.log'), 'a') as f:
            f.write(json.dumps(logged) + '\n')
        m = mode()
        if m == 'down':
            return self.send(500, 'Service unavailable', 'text/plain')
        if m == 'junk':
            return self.send(200, '<html>Sign in</html>', 'text/html')
        if m == 'slow':
            time.sleep(25)
        if req.get('op') != 'hikReplyGet':
            return self.send(200, json.dumps({'ok': False, 'msg': 'Unknown op.'}))
        if req.get('key') != KEY:
            return self.send(200, json.dumps({'ok': False, 'msg': 'Wrong key.'}))
        p = os.path.join(DATA, 'replies.json')
        try:
            rep = json.load(open(p))
        except Exception:
            rep = {}
        for k in (req.get('serial', ''), req.get('shortSerial', '')):
            if k and k in rep:
                r = rep.pop(k)
                json.dump(rep, open(p, 'w'))
                # 2.2.8: like the real relay (HikRelay.gs), it only answers with a mail received after the request's exportedAt: now
                out = {'ok': True, 'found': True, 'subject': 'Hikvision reset', 'receivedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}
                out.update(r)
                return self.send(200, json.dumps(out))
        return self.send(200, json.dumps({'ok': True, 'found': False}))

HTTPServer(('127.0.0.1', PORT), H).serve_forever()
