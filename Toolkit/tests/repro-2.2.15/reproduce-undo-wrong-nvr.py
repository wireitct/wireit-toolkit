"""reproduce-undo-wrong-nvr.py - Codex 2.2.15 review F3, adapted to run from the repo and ASSERT the safe outcome.
   The REAL FixSite.ps1 Undo (-Mode Rollback) against the repository's mock devices (loopback only). The undo file says the run moved
   NVR "NVR18" (MAC ...:18) from .18 to .19 and changed its password. Every mode runs twice.
     wrongnvr:  Codex's case: a DIFFERENT NVR (OTHER-NVR, MAC ...:20) answers at .19 with the site password. Undo must write NOTHING to it
                (address and password unchanged), say NOT moved back / NOT put back, exit nonzero, never "everything is back".
     noid:      the NVR at .19 does not tell its MAC or serial: same - nothing written, nonzero exit.
     oldfile:   an older undo file with no MAC / serial for the NVR, and the RIGHT NVR at .19: stays unconfirmed (nothing written, nonzero).
     samenvr:   control: the NVR at .19 IS NVR18 (MAC ...:18): moved back to .18, old password back, exit 0, "everything is back".
   Usage: python3 reproduce-undo-wrong-nvr.py --repo <repo root> --powershell <pwsh> [--only wrongnvr,noid,oldfile,samenvr]"""

import argparse, base64, hashlib, importlib.util, json, re, subprocess, sys, tempfile, threading
from pathlib import Path
from http.server import ThreadingHTTPServer

M18 = 'c4:2f:90:00:00:18'; M20 = 'c4:2f:90:00:00:20'
PASS = 0; FAIL = 0


def check(what, ok):
    global PASS, FAIL
    if ok: PASS += 1; print('PASS ' + what)
    else: FAIL += 1; print('FAIL ' + what)
    sys.stdout.flush()


def cam(serial, mac, pw, **kw):
    d = {'kind': 'camera', 'brand': 'Hikvision', 'model': 'DS-2CD2143G2-I', 'serial': serial, 'mac': mac, 'password': pw, 'https': True}
    d.update(kw); return d


def nvr(serial, mac, chans, **kw):
    d = {'kind': 'nvr', 'brand': 'Hikvision', 'model': 'DS-7608NI-K2', 'serial': serial, 'mac': mac, 'password': 'Sitepass456', 'https': True, 'channels': chans}
    d.update(kw); return d


def ch(ip, pw, name):
    return {'ip': ip, 'password': pw, 'protocol': 'HIKVISION', 'name': name}


def load_mock(repo):
    spec = importlib.util.spec_from_file_location('mock_site', repo / 'Toolkit/tests/fixsite/mock_site.py')
    mock = importlib.util.module_from_spec(spec); spec.loader.exec_module(mock); return mock


def summary():
    print('%d passed, %d failed' % (PASS, FAIL))
    sys.exit(0 if FAIL == 0 else 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', default=str(Path(__file__).resolve().parents[3])); ap.add_argument('--powershell', default='pwsh'); ap.add_argument('--only', default='')
    args = ap.parse_args(); repo = Path(args.repo); mock = load_mock(repo)
    modes = ['wrongnvr', 'noid', 'oldfile', 'samenvr']
    if args.only: modes = [x for x in modes if x in args.only.split(',')]
    results = {}
    with tempfile.TemporaryDirectory(prefix='repro2215-undonvr-') as tmp:
        for mode in modes:
            case = Path(tmp) / mode; vault = case / 'vault'; vault.mkdir(parents=True); runs = case / 'runs'
            pc = {'ip': '192.168.1.105', 'gw': '192.168.1.1', 'mask': '255.255.255.0', 'dhcp': True}
            sec = {'site': 'Review', 'password': 'Sitepass456', 'known': [], 'nvr': {'192.168.1.19': 'Sitepass456', '192.168.1.18': 'Oldnvr123'},
                   'cams': {}, 'rollback': {'review-before': {'nvr|192.168.1.19': 'Oldnvr123'}}, 'bitwardenSaved': True, 'shownOnce': True}
            if mode in ('samenvr', 'oldfile'): dev = nvr('NVR18', M18, {}, password='Sitepass456')
            else: dev = nvr('OTHER-NVR', M20, {}, password='Sitepass456')
            devices = {'192.168.1.19': dev}
            scene = case / 'scene.json'; scene.write_text(json.dumps({'pc': pc, 'devices': devices})); mock.load(scene)
            ctl = {'writes': []}

            class Handler(mock.H):
                def send(self, *a, **k):
                    try: return super().send(*a, **k)
                    except (BrokenPipeError, ConnectionResetError): pass

                def route(self, method, ip, path, q, body, rawq):
                    if method in ('PUT', 'POST'): ctl['writes'].append({'ip': ip, 'path': path})
                    if mode == 'noid' and path == '/ISAPI/System/deviceInfo':
                        d = mock.S['devices'].get(ip)
                        if d and self.headers.get('Authorization'):
                            return self.send(200, '<DeviceInfo xmlns="http://www.hikvision.com/ver20/XMLSchema"><deviceName>x</deviceName><model>%s</model><firmwareVersion>V4</firmwareVersion></DeviceInfo>' % d['model'], 'application/xml')
                    return super().route(method, ip, path, q, body, rawq)

            class Server(ThreadingHTTPServer):
                daemon_threads = True
                def handle_error(self, request, client_address): pass

            server = Server(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
            slug = 'review-' + hashlib.sha256(b'review').hexdigest()[:8]
            (vault / ('site-' + slug + '.dat')).write_text('TEST:' + base64.b64encode(json.dumps(sec).encode()).decode())
            answers = case / 'answers.txt'; answers.write_text('YES\n')
            config = case / 'config.json'; config.write_text(json.dumps({'fixSite': {'moveWaitSec': 2, 'rebootWaitSec': 2, 'verifyHoldSec': 0}}))
            rb = case / 'original-run'; (rb / 'backup').mkdir(parents=True)
            mv = {'ip': '192.168.1.18', 'target': '192.168.1.19', 'iface': 1,
                  'old': {'ip': '192.168.1.18', 'mask': '255.255.255.0', 'gw': '192.168.1.1', 'dhcp': False, 'dns1': '8.8.8.8', 'dns2': ''}}
            npw = {'ip': '192.168.1.19', 'changed': True, 'attempted': True}
            if mode != 'oldfile': mv.update({'mac': M18, 'serial': 'NVR18'}); npw.update({'mac': M18, 'serial': 'NVR18'})
            (rb / 'rollback.json').write_text(json.dumps({'run': 'review-before', 'site': 'Review', 'scheme': '192.168.1', 'taken_on': 'test', 'cameras': [],
                                                          'nvrs': [mv], 'nvr_passwords': [npw]}))
            cmd = [args.powershell, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(repo / 'Toolkit/FixSite.ps1'), '-Site', 'Review', '-MockUrl', 'http://127.0.0.1:' + str(server.server_port),
                   '-SecretsDir', str(vault), '-RunsRoot', str(runs), '-SitesDir', str(case / 'sites'), '-Answers', str(answers), '-ConfigPath', str(config),
                   '-Mode', 'Rollback', '-RollbackDir', str(rb)]
            for run in (1, 2):
                ctl['writes'] = []
                try:
                    p = subprocess.run(cmd, capture_output=True, text=True, timeout=200); out, code = p.stdout + p.stderr, p.returncode
                except subprocess.TimeoutExpired as e:
                    out, code = 'TIMEOUT ' + str(e.stdout or ''), -9
                S = mock.S
                d = next((v for v in S['devices'].values() if v.get('serial') == dev['serial']), None)
                dip = next((k for k, v in S['devices'].items() if v.get('serial') == dev['serial']), '')
                r = {'exit': code, 'ip': dip, 'pw': d['password'] if d else '', 'writes': ctl['writes'],
                     'notback': bool(re.search(r'NOT (moved back|put back|confirmed)', out)), 'allback': 'everything is back' in out, 'out': out[-2500:]}
                results["%s%d" % (mode, run)] = r
                if __import__("os").environ.get("REPRO_DEBUG"): print(out[-3000:])
                tag = '%s run %d: ' % (mode, run)
                if mode == 'samenvr':
                    if run == 1: check(tag + 'control: same NVR: moved back to .18, old password back, exit 0', dip == '192.168.1.18' and r['pw'] == 'Oldnvr123' and code == 0 and r['allback'])
                    else: check(tag + 'control: second Undo does nothing twice, exit 0', dip == '192.168.1.18' and r['pw'] == 'Oldnvr123' and code == 0)
                else:
                    check(tag + 'the NVR at .19 is NOT written to (address and password unchanged)', dip == '192.168.1.19' and r['pw'] == 'Sitepass456' and not r['writes'])
                    check(tag + 'Undo says NOT moved back / NOT put back, never "everything is back"', r['notback'] and not r['allback'])
                    check(tag + 'nonzero exit', code != 0)
            server.shutdown()
    print('REPRO=' + json.dumps({k: {kk: vv for kk, vv in v.items() if kk != 'out'} for k, v in results.items()}))
    summary()


if __name__ == '__main__':
    main()
