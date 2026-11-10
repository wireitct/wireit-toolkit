#!/usr/bin/env python3
"""Codex 2.2.15 F7: the mock SADP device (tests/hikreset/fake_sadp.py) answered BEFORE it published its state file, and published it by
truncating the file first. A test that reads the state right after the answer then saw an old or empty file (pack abort "Cannot index
into a null array"). This runs the repo's real fake_sadp.py with a slow disk (each state write pauses 0.4 s half-way) and checks that the
state read right after each answer already holds the change and is a whole JSON file. Safe = PASS on every line.
usage: reproduce-sadp-state-race.py --repo <checkout> [--powershell <ignored>]"""
import argparse, json, os, socket, subprocess, sys, tempfile, time
ap = argparse.ArgumentParser(); ap.add_argument('--repo', default=os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..')))
ap.add_argument('--powershell', default=''); a = ap.parse_args()
fake = os.path.join(a.repo, 'Toolkit', 'tests', 'hikreset', 'fake_sadp.py')
tmp = tempfile.mkdtemp(prefix='repro2216-sadp-')
wrap = os.path.join(tmp, 'slow_fake.py')
open(wrap, 'w').write(r"""
import json, runpy, sys, time
_dump = json.dump
def slow_dump(obj, fp, *x, **k):
    fp.write(' '); fp.flush(); time.sleep(0.4)   # a slow disk: the write is half done for 0.4 s
    return _dump(obj, fp, *x, **k)
json.dump = slow_dump
fake = sys.argv[1]; sys.argv = [fake] + sys.argv[2:]
sys.path.insert(0, __import__('os').path.dirname(fake))
runpy.run_path(fake, run_name='__main__')
""")
devs = [{'mac': 'c0-6d-ed-2b-f3-85', 'ip': '192.168.1.23', 'mask': '255.255.255.0', 'gw': '192.168.1.1', 'serial': 'SN1', 'model': 'DS-X', 'activated': True,
         'kind': 'camera', 'boot': '2026-11-05 19:09:38', 'code': 'AwAAAA==', 'unlock': 'UNL', 'codeTypes': ['getcode'], 'importTypes': ['resetPassword'], 'password': 'Old12345'}]
df = os.path.join(tmp, 'devs.json'); json.dump(devs, open(df, 'w'))
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(('127.0.0.1', 0)); port = s.getsockname()[1]; s.close()
p = subprocess.Popen([sys.executable, wrap, fake, str(port), df], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
passed = failed = 0
def chk(ok, what):
    global passed, failed
    print(('PASS ' if ok else 'FAIL ') + what); passed += bool(ok); failed += (not ok)
try:
    end = time.time() + 10
    while not os.path.exists(df + '.ready') and time.time() < end: time.sleep(0.05)
    chk(os.path.exists(df + '.ready'), 'the fake device started')
    c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); c.settimeout(5)
    seen = []
    for i, (pw, newpw, ip) in enumerate([('Old12345', 'New54321', '10.0.0.9'), (None, None, '10.0.0.10')]):
        if pw:   # import the reset reply: password changes
            msg = '<Probe><Uuid>U%d</Uuid><Types>resetPassword</Types><MAC>c0-6d-ed-2b-f3-85</MAC><Code>UNL</Code><Password>%s</Password></Probe>' % (i, newpw)
        else:    # change the address with the new password
            msg = '<Probe><Uuid>U%d</Uuid><Types>update</Types><MAC>c0-6d-ed-2b-f3-85</MAC><Password>New54321</Password><IPv4Address>%s</IPv4Address></Probe>' % (i, ip)
        c.sendto(msg.encode(), ('127.0.0.1', port))
        ans = c.recvfrom(65535)[0].decode()
        chk('success' in ans, 'step %d: the device answered success' % (i + 1))
        raw = ''
        try: raw = open(df + '.state.json').read()
        except Exception as e: raw = ''
        st = None
        try: st = json.loads(raw)
        except Exception: pass
        chk(st is not None, 'step %d: the state file read RIGHT AFTER the answer is a whole JSON file (got %d bytes)' % (i + 1, len(raw)))
        d = (st or {}).get('devices', [{}])[0] if st else {}
        if pw: chk(d.get('password') == newpw, 'step 1: that state already holds the new password (got %r)' % d.get('password'))
        else: chk(d.get('ip') == ip, 'step 2: that state already holds the new address (got %r)' % d.get('ip'))
    print('REPRO=' + json.dumps({'port': port, 'repo': a.repo}))
finally:
    open(df + '.stop', 'w').write('1')
    try: p.wait(5)
    except Exception: p.kill(); p.wait(5)
    chk(p.poll() is not None, 'the fake device process is gone after the stop marker / kill')
print('%d passed, %d failed' % (passed, failed))
sys.exit(1 if failed else 0)
