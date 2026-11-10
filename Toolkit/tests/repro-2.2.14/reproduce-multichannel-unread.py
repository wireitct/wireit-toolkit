"""reproduce-multichannel-unread.py - Codex 2.2.14 review R1, adapted to run from the repo and ASSERT the safe outcome.
   The REAL FixSite.ps1 against the repository's mock devices (Toolkit/tests/fixsite/mock_site.py, loopback only). Exactly ONE
   channel-list GET of NVR .19 answers HTTP 500 (the first, at the scan); later reads work. Every mode runs twice.
     multi:      NVR .19 ch 1 and ch 2 both record camera .50 (old password), -PasswordAll. Run 1 (list unread): the password is NOT
                 changed, both channels keep video, nonzero exit, never "Still a problem: 0". Run 2 (list read): the 2-channel guard
                 refuses, nonzero exit.
     multimove:  the camera is on the wrong subnet (192.168.0.150), .19 ch 1 + ch 2 record it. Run 1: NOT moved, nonzero exit.
                 Run 2: still not moved, nonzero exit, never "Nothing to fix" while a channel points at the old address.
     singlefail: control: one channel. Run 1 (list unread): password NOT changed, nonzero exit. Run 2 (list read): fixed, exit 0
                 (running twice is fine and says so honestly).
   Usage: python3 reproduce-multichannel-unread.py --repo <repo root> --powershell <pwsh> [--only multi,multimove,singlefail]"""

import argparse, base64, hashlib, importlib.util, json, re, subprocess, sys, tempfile, threading
from pathlib import Path
from http.server import ThreadingHTTPServer

M50 = 'c4:2f:90:00:01:50'; M51 = 'c4:2f:90:00:01:51'; M19 = 'c4:2f:90:00:00:19'
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
    modes = ['multi', 'multimove', 'singlefail']
    if args.only: modes = [x for x in modes if x in args.only.split(',')]
    results = {}
    with tempfile.TemporaryDirectory(prefix='repro2214-mcu-') as tmp:
        for mode in modes:
            case = Path(tmp) / mode; vault = case / 'vault'; vault.mkdir(parents=True); runs = case / 'runs'
            pc = {'ip': '192.168.1.105', 'gw': '192.168.1.1', 'mask': '255.255.255.0', 'dhcp': True}
            sec = {'site': 'Review', 'password': 'Sitepass456', 'known': ['Oldpass123'], 'nvr': {'192.168.1.19': 'Sitepass456'},
                   'cams': {}, 'rollback': {}, 'bitwardenSaved': True, 'shownOnce': True}
            camip = '192.168.0.150' if mode == 'multimove' else '192.168.1.50'
            lcams = [{'name': 'Gate', 'mac': M50, 'ip': '192.168.1.50', 'nvr': '192.168.1.19', 'channel': 1}]
            lnvrs = [{'brand': 'Hikvision', 'mac': M19, 'ip': '192.168.1.19'}]
            if mode == 'singlefail':
                devices = {camip: cam('CAMSER150', M50, 'Oldpass123'), '192.168.1.19': nvr('NVRSER19', M19, {'1': ch(camip, 'Oldpass123', 'Gate')})}
            else:
                devices = {camip: cam('CAMSER150', M50, 'Oldpass123'),
                           '192.168.1.19': nvr('NVRSER19', M19, {'1': ch(camip, 'Oldpass123', 'Gate'), '2': ch(camip, 'Oldpass123', 'Gate second sensor')})}
            site_list = {'site': 'Review', 'scheme': '192.168.1', 'nvrs': lnvrs, 'cameras': lcams}
            scene = case / 'scene.json'; scene.write_text(json.dumps({'pc': pc, 'devices': devices})); mock.load(scene)
            ctl = {'puts': [], 'scan_failed': False}

            class Handler(mock.H):
                def send(self, *a, **k):
                    try: return super().send(*a, **k)
                    except (BrokenPipeError, ConnectionResetError): pass

                def route(self, method, ip, path, q, body, rawq):
                    if method in ('PUT', 'POST') and '/InputProxy/channels' in path: ctl['puts'].append({'ip': ip, 'path': path})
                    if ip == '192.168.1.19' and method == 'GET' and path == '/ISAPI/ContentMgmt/InputProxy/channels' and not ctl['scan_failed']:
                        ctl['scan_failed'] = True
                        return self.send(500, 'temporary list failure')
                    return super().route(method, ip, path, q, body, rawq)

            class Server(ThreadingHTTPServer):
                daemon_threads = True
                def handle_error(self, request, client_address): pass

            server = Server(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
            slug = 'review-' + hashlib.sha256(b'review').hexdigest()[:8]
            (vault / ('site-' + slug + '.dat')).write_text('TEST:' + base64.b64encode(json.dumps(sec).encode()).decode())
            answers = case / 'answers.txt'
            config = case / 'config.json'; config.write_text(json.dumps({'fixSite': {'moveWaitSec': 2, 'rebootWaitSec': 2, 'verifyHoldSec': 0}}))
            lf = case / 'list.json'; lf.write_text(json.dumps(site_list))
            cmd = [args.powershell, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(repo / 'Toolkit/FixSite.ps1'), '-Site', 'Review', '-MockUrl', 'http://127.0.0.1:' + str(server.server_port),
                   '-SecretsDir', str(vault), '-RunsRoot', str(runs), '-SitesDir', str(case / 'sites'), '-Answers', str(answers), '-ConfigPath', str(config), '-ListFile', str(lf)]
            if mode != 'multimove': cmd += ['-PasswordAll']
            for run in (1, 2):
                ctl['puts'] = []
                answers.write_text('N\nYES\nY\nYES\n' if mode == 'multimove' else 'YES\nY\nYES\n')
                try:
                    p = subprocess.run(cmd, capture_output=True, text=True, timeout=200); out, code = p.stdout + p.stderr, p.returncode
                except subprocess.TimeoutExpired as e:
                    out, code = 'TIMEOUT ' + str(e.stdout or ''), -9
                S = mock.S
                c50 = next((v for v in S['devices'].values() if v.get('mac') == M50), None)
                c50ip = next((k for k, v in S['devices'].items() if v.get('mac') == M50), '')
                onl = {}
                for k, v in S['devices'].items():
                    if v['kind'] == 'nvr':
                        for cc, v2 in v.get('channels', {}).items(): onl[k + '/' + cc] = bool(mock.camera_online(v, v2))
                m = re.search(r'Still a problem:\s*(\d+)', out)
                r = {'exit': code, 'camip': c50ip, 'pw': c50['password'] if c50 else '', 'online': onl, 'problems': int(m.group(1)) if m else -1,
                     'nothing': bool(re.search(r'Nothing to fix', out)), 'puts': ctl['puts'], 'out': out[-2500:]}
                results['%s%d' % (mode, run)] = r
                tag = '%s run %d: ' % (mode, run)
                allvid = all(onl.values())
                if mode == 'multi':
                    check(tag + 'camera password NOT changed (one of its channels would lose video)', r['pw'] == 'Oldpass123')
                    check(tag + 'every NVR channel of the camera still has video', allvid)
                    check(tag + 'nonzero exit and never "Still a problem: 0"', code != 0 and r['problems'] != 0)
                elif mode == 'multimove':
                    check(tag + 'camera NOT moved (still on 192.168.0.150)', c50ip == '192.168.0.150')
                    check(tag + 'every NVR channel of the camera still has video', allvid)
                    check(tag + 'nonzero exit, never "Nothing to fix" or "Still a problem: 0"', code != 0 and not r['nothing'] and r['problems'] != 0)
                else:
                    if run == 1:
                        check(tag + 'list unread: password NOT changed', r['pw'] == 'Oldpass123')
                        check(tag + 'list unread: nonzero exit, never "Still a problem: 0"', code != 0 and r['problems'] != 0)
                        check(tag + 'list unread: the tech is told the channel list could not be read', 'channel list could NOT be read' in out)
                    else:
                        check(tag + 'control: list read: password set, video back, exit 0', r['pw'] == 'Sitepass456' and allvid and code == 0)
            server.shutdown()
    print('REPRO=' + json.dumps({k: {kk: vv for kk, vv in v.items() if kk != 'out'} for k, v in results.items()}))
    summary()


if __name__ == '__main__':
    main()
