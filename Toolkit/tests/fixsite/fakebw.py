#!/usr/bin/env python3
# fakebw.py - a stand-in for the Bitwarden CLI in Test-Fix221 (Linux/macOS; state in $FAKEBW_STATE). Never touches a real vault.
# FAKEBW_MODE=noedit: "bw edit" answers OK but changes nothing (the server did not take it) - the Toolkit must notice on the read-back.
import sys, os, json, base64
st_path = os.environ['FAKEBW_STATE']
st = json.load(open(st_path)) if os.path.exists(st_path) else {'items': [], 'calls': []}
a = sys.argv[1:]
st['calls'].append(' '.join(a[:2]))
def save(): json.dump(st, open(st_path, 'w'))
def out(o): sys.stdout.write(json.dumps(o)); save(); sys.exit(0)
if not a: save(); sys.exit(1)
if a[0] == 'status': out({'status': 'unlocked'})
if a[0] == 'sync': save(); sys.exit(0)
if a[0] == 'list' and a[1] == 'items':
    q = a[a.index('--search') + 1] if '--search' in a else ''
    out([i for i in st['items'] if q.lower() in i['name'].lower()])
if a[0] == 'get' and a[1] == 'item':
    for i in st['items']:
        if i['id'] == a[2]: out(i)
    save(); sys.exit(1)
if a[0] in ('create', 'edit') and a[1] == 'item':
    raw = sys.stdin.read().strip()
    if 'password' in ' '.join(a): save(); sys.exit(2)   # a password on the command line = test failure
    it = json.loads(base64.b64decode(raw).decode('utf-8'))
    if a[0] == 'create':
        it['id'] = 'id-%d' % (len(st['items']) + 1); st['items'].append(it); out(it)
    for k, i in enumerate(st['items']):
        if i['id'] == a[2]:
            if os.environ.get('FAKEBW_MODE') != 'noedit': it['id'] = a[2]; st['items'][k] = it
            out(it)
    save(); sys.exit(1)
save(); sys.exit(1)
