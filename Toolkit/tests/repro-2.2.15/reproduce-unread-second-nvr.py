"""reproduce-unread-second-nvr.py - Codex 2.2.15 review F1, adapted to run from the repo and ASSERT the safe outcome.
   The REAL FixSite.ps1 against the repository's mock devices (fixsite/mock_site.py, loopback only). Two NVRs record camera Gate:
   .19 ch 1 (on the site list) and .20 ch 1 (found by the scan). Only the FIRST channel-list request to .20 answers HTTP 500.
   Every mode runs twice through the real entry point.
     pw:      -PasswordAll, camera .50 on its old password. Run 1: .20 unread = the password must NOT change (.20 would lose video),
              Still a problem, nonzero exit, and the result must not claim cameras it may record "kept their password and address"
              unless that is true. Run 2 (.20 now readable): two NVRs record it = still NOT changed, both channels keep video.
     move:    camera on the wrong subnet 192.168.0.150: NOT moved in either run (run 1: .20 unread; run 2: two NVRs), .20 keeps video,
              nonzero exit, never "Nothing to fix".
     orphan:  the damage a 2.2.15 run left: camera already moved to 192.168.1.50, .19 ch 1 follows it, .20 ch 1 still points at the
              OLD address 192.168.0.150 (no video, nothing answers there). Both runs (no list failure): a problem naming .20 ch 1,
              nonzero exit, never "Nothing to fix. N cameras are fine".
     single:  control: one NVR (.19) only, -PasswordAll: changed, channel follows, video back, exit 0.
   Usage: python3 reproduce-unread-second-nvr.py --repo <repo root> --powershell <pwsh> [--only pw,move,orphan,single]"""
import argparse, base64, hashlib, importlib.util, json, os, re, subprocess, sys, tempfile, threading
from pathlib import Path
from http.server import ThreadingHTTPServer

M50 = 'c4:2f:90:00:01:50'; M20 = 'c4:2f:90:00:00:20'; M19 = 'c4:2f:90:00:00:19'
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', default=str(Path(__file__).resolve().parents[3])); ap.add_argument('--powershell', default='pwsh'); ap.add_argument('--only', default='')
    args = ap.parse_args(); repo = Path(args.repo)
    spec = importlib.util.spec_from_file_location('mock_site', repo / 'Toolkit/tests/fixsite/mock_site.py')
    mock = importlib.util.module_from_spec(spec); spec.loader.exec_module(mock)
    modes = ['pw', 'move', 'orphan', 'single']
    if args.only: modes = [x for x in modes if x in args.only.split(',')]
    results = {}
    with tempfile.TemporaryDirectory(prefix='repro2215-unread2-') as tmp:
        for mode in modes:
            case = Path(tmp) / mode; vault = case / 'vault'; vault.mkdir(parents=True); runs = case / 'runs'
            pc = {'ip': '192.168.1.105', 'gw': '192.168.1.1', 'mask': '255.255.255.0', 'dhcp': True}
            sec = {'site': 'Review', 'password': 'Sitepass456', 'known': ['Oldpass123'], 'nvr': {'192.168.1.20': 'Sitepass456', '192.168.1.19': 'Sitepass456'},
                   'cams': {}, 'rollback': {}, 'bitwardenSaved': True, 'shownOnce': True}
            camip = '192.168.0.150' if mode == 'move' else '192.168.1.50'
            lcams = [{'name': 'Gate', 'mac': M50, 'ip': '192.168.1.50', 'nvr': '192.168.1.19', 'channel': 1}]
            lnvrs = [{'brand': 'Hikvision', 'mac': M19, 'ip': '192.168.1.19'}]
            if mode == 'orphan':
                sec['cams'] = {M50: 'Sitepass456'}
                devices = {camip: cam('CAMSER150', M50, 'Sitepass456'),
                           '192.168.1.19': nvr('NVRSER19', M19, {'1': ch(camip, 'Sitepass456', 'Gate')}), '192.168.1.20': nvr('NVRSER20', M20, {'1': ch('192.168.0.150', 'Sitepass456', 'Gate backup recording')})}
            elif mode == 'single':
                devices = {camip: cam('CAMSER150', M50, 'Oldpass123'), '192.168.1.19': nvr('NVRSER19', M19, {'1': ch(camip, 'Oldpass123', 'Gate')})}
                sec['nvr'] = {'192.168.1.19': 'Sitepass456'}
            else:
                devices = {camip: cam('CAMSER150', M50, 'Oldpass123'),
                           '192.168.1.19': nvr('NVRSER19', M19, {'1': ch(camip, 'Oldpass123', 'Gate')}), '192.168.1.20': nvr('NVRSER20', M20, {'1': ch(camip, 'Oldpass123', 'Gate backup recording')})}
            site_list = {'site': 'Review', 'scheme': '192.168.1', 'nvrs': lnvrs, 'cameras': lcams}
            scene = case / 'scene.json'; scene.write_text(json.dumps({'pc': pc, 'devices': devices})); mock.load(scene)
            ctl = {'puts': [], 'scan_failed': mode in ('orphan', 'single')}

            class Handler(mock.H):
                def send(self, *a, **k):
                    try: return super().send(*a, **k)
                    except (BrokenPipeError, ConnectionResetError): pass

                def route(self, method, ip, path, q, body, rawq):
                    if method in ('PUT', 'POST') and '/InputProxy/channels' in path: ctl['puts'].append({'ip': ip, 'path': path})
                    if ip == '192.168.1.20' and method == 'GET' and path == '/ISAPI/ContentMgmt/InputProxy/channels' and not ctl.get('scan_failed'):
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
            answers.write_text('N\nYES\nY\nYES\n' if mode in ('move', 'orphan') else 'YES\nY\nYES\n')
            if mode in ('pw', 'single'): cmd += ['-PasswordAll']
            for run in (1, 2):
                ctl['puts'] = []
                try:
                    p = subprocess.run(cmd, capture_output=True, text=True, timeout=200); out, code = p.stdout + p.stderr, p.returncode
                except subprocess.TimeoutExpired as e:
                    out, code = 'TIMEOUT ' + str(e.stdout or ''), -9
                if os.environ.get('REPRO_DEBUG'): print(out[-4000:])
                S = mock.S
                c50 = next((v for v in S['devices'].values() if v.get('mac') == M50), None)
                c50ip = next((k for k, v in S['devices'].items() if v.get('mac') == M50), '')
                onl = {}
                for k, v in S['devices'].items():
                    if v['kind'] == 'nvr':
                        for cc, v2 in v.get('channels', {}).items(): onl[k + '/' + cc] = bool(mock.camera_online(v, v2))
                m = re.search(r'Still a problem:\s*(\d+)', out)
                r = {'exit': code, 'camip': c50ip, 'pw': c50['password'] if c50 else '', 'pwchanges': c50.get('pw_changes', 0) if c50 else -1, 'online': onl,
                     'problems': int(m.group(1)) if m else -1, 'puts': ctl['puts'],
                     'nothing': bool(re.search(r'Nothing to fix', out)), 'kept': bool(re.search(r'kept their password and address', out)),
                     'said20': bool(re.search(r'(?i)192\.168\.1\.20 ch 1.{0,80}(no video|not checked)', out)), 'out': out[-2500:]}
                results['%s%d' % (mode, run)] = r
                tag = '%s run %d: ' % (mode, run)
                if mode == 'pw':
                    check(tag + 'camera password NOT changed (NVR .20 may record it)', r['pw'] == 'Oldpass123' and r['pwchanges'] == 0)
                    check(tag + 'both NVR channels keep their video', onl.get('192.168.1.19/1') and onl.get('192.168.1.20/1'))
                    check(tag + 'Still a problem, nonzero exit', code != 0 and r['problems'] != 0)
                    check(tag + 'no false "kept their password and address" claim (nothing was changed on .20 because of it only when true)', (not r['kept']) or (r['pwchanges'] == 0 and onl.get('192.168.1.20/1')))
                elif mode == 'move':
                    check(tag + 'camera NOT moved (still on 192.168.0.150)', c50ip == '192.168.0.150')
                    check(tag + 'NVR .20 keeps its video', bool(onl.get('192.168.1.20/1')))
                    check(tag + 'nonzero exit, never "Nothing to fix"', code != 0 and not r['nothing'])
                elif mode == 'orphan':
                    check(tag + 'the old-address channel .20 ch 1 is reported as a problem (no video), nonzero exit, never "Nothing to fix"', not r['nothing'] and r['said20'] and code != 0)
                    check(tag + 'the working camera is not touched (password, address)', c50ip == '192.168.1.50' and r['pwchanges'] == 0)
                else:
                    if run == 1: check(tag + 'control: one NVR: password set, video back, exit 0', r['pw'] == 'Sitepass456' and onl.get('192.168.1.19/1') and code == 0)
                    else: check(tag + 'control: second run is clean, exit 0', r['pw'] == 'Sitepass456' and onl.get('192.168.1.19/1') and code == 0)
            server.shutdown()
    print('REPRO=' + json.dumps({k: {kk: vv for kk, vv in v.items() if kk != 'out'} for k, v in results.items()}))
    print('%d passed, %d failed' % (PASS, FAIL))
    sys.exit(0 if FAIL == 0 else 1)


if __name__ == '__main__':
    main()
