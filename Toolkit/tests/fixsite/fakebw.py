#!/usr/bin/env python3
# fakebw.py - a stand-in for the Bitwarden CLI in Test-Fix221 (Linux/macOS; state in $FAKEBW_STATE). Never touches a real vault.
# FAKEBW_MODE=noedit: "bw edit" answers OK but changes nothing (the server did not take it) - the Toolkit must notice on the read-back.
# 2.2.2: FAKEBW_MODE=nosync: every "bw sync" fails (no server);  =syncafter: the first sync works, every later one fails.
#        FAKEBW_NOORG=1: this login sees no organization;  FAKEBW_STATUS: what "bw status" says (default unlocked).
#        The WireIt CT organization (org-1) has the collections Sites (col-sites) and WireIt Business (col-biz).
import sys, os, json, base64
st_path = os.environ['FAKEBW_STATE']
st = json.load(open(st_path)) if os.path.exists(st_path) else {'items': [], 'calls': []}
a = sys.argv[1:]
st['calls'].append(' '.join(a[:2]))
def save(): json.dump(st, open(st_path, 'w'))
def out(o): sys.stdout.write(json.dumps(o)); save(); sys.exit(0)
if not a: save(); sys.exit(1)
if a[0] == 'status': out({'status': os.environ.get('FAKEBW_STATUS') or 'unlocked'})
if a[0] == 'unlock':
    if os.environ.get(a[a.index('--passwordenv') + 1] if '--passwordenv' in a else '') == 'Master#1': sys.stdout.write('SESSIONKEY123'); save(); sys.exit(0)
    save(); sys.exit(1)
if a[0] == 'sync':
    st['syncs'] = st.get('syncs', 0) + 1
    m = os.environ.get('FAKEBW_MODE')
    if m == 'nosync' or (m == 'syncafter' and st['syncs'] > 1): save(); sys.exit(1)
    save(); sys.exit(0)
if a[0] == 'list' and a[1] == 'organizations':
    out([] if os.environ.get('FAKEBW_NOORG') else [{'id': 'org-1', 'name': 'WireIt CT'}])
if a[0] == 'list' and a[1] == 'org-collections':
    oid = a[a.index('--organizationid') + 1] if '--organizationid' in a else ''
    out([{'id': 'col-sites', 'name': 'Sites', 'organizationId': 'org-1'}, {'id': 'col-biz', 'name': 'WireIt Business', 'organizationId': 'org-1'}] if oid == 'org-1' else [])
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
