#!/usr/bin/env python3
"""fake_imap.py - a tiny IMAP server for the Toolkit mail tests (plain TCP). Usage: fake_imap.py <port> <dir-with-.eml-files> <user> <password>
Supports LOGIN, EXAMINE/SELECT, SEARCH (returns every message), FETCH n (BODY.PEEK[]), LOGOUT. Wrong login -> NO. Logs commands to <dir>/commands.log (passwords not logged)."""
import socketserver, sys, os, glob, re
port = int(sys.argv[1]); d = sys.argv[2]; user = sys.argv[3]; pw = bytes.fromhex(sys.argv[4]).decode()
class H(socketserver.StreamRequestHandler):
    def w(self, b): self.wfile.write(b if isinstance(b, bytes) else b.encode()); self.wfile.flush()
    def handle(self):
        self.w('* OK fake imap ready\r\n'); ok = False
        msgs = sorted(glob.glob(os.path.join(d, '*.eml')))
        while True:
            line = self.rfile.readline()
            if not line: break
            t = line.decode('utf8', 'ignore').rstrip('\r\n'); m = re.match(r'(\S+)\s+(\S+)\s*(.*)', t)
            if not m: continue
            tag, cmd, rest = m.group(1), m.group(2).upper(), m.group(3)
            with open(os.path.join(d, 'commands.log'), 'a') as f: f.write(cmd + (' ' + rest if cmd not in ('LOGIN',) else '') + '\n')
            if cmd == 'LOGIN':
                a = re.findall(r'"((?:[^"\\]|\\.)*)"', rest); ok = (len(a) == 2 and a[0] == user and a[1].replace('\\"', '"').replace('\\\\', '\\') == pw)
                self.w(tag + (' OK LOGIN done\r\n' if ok else ' NO bad login\r\n'))
            elif not ok: self.w(tag + ' NO login first\r\n')
            elif cmd in ('SELECT', 'EXAMINE'): self.w('* %d EXISTS\r\n%s OK done\r\n' % (len(msgs), tag))
            elif cmd == 'SEARCH': self.w('* SEARCH %s\r\n%s OK done\r\n' % (' '.join(str(i + 1) for i in range(len(msgs))), tag))
            elif cmd == 'FETCH':
                n = int(rest.split()[0]) - 1; b = open(msgs[n], 'rb').read()
                self.w(('* %d FETCH (BODY[] {%d}\r\n' % (n + 1, len(b))).encode() + b + b')\r\n' + (tag + ' OK done\r\n').encode())
            elif cmd == 'LOGOUT': self.w('* BYE\r\n' + tag + ' OK bye\r\n'); break
            else: self.w(tag + ' BAD unknown\r\n')
class S(socketserver.ThreadingTCPServer): allow_reuse_address = True; daemon_threads = True
S(('127.0.0.1', port), H).serve_forever()
