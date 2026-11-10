"""fix2213site/scenarios.py - WireIt Toolkit 2.2.13, Fix this site: Codex's 2.2.12 review finding #1 as permanent tests.
   The REAL FixSite.ps1 against the repository's mock devices (fixsite/mock_site.py, loopback only).
   sameip:   Codex's reproduction. Camera .50 already on the right address, old password; NVR .20 (offline today) is the one the
             site list names, live NVR .19 records it. -PasswordAll must NOT change the camera password (.20 would lose it).
   move:     Codex's wrong-subnet variant: the same camera on 192.168.0.150 (needs a move): the password is not changed before the
             move that is then refused.
   wrongcam: wrong device: NVR .19 ch 1 records ANOTHER camera (.51), ch 2 records ours; the list names offline .20 for ours.
             Ours keeps its password; the other camera and its channel are untouched.
   nvrdown:  failing half-way: the camera's only NVR (.19) answers at the scan, then stops answering right after the camera's
             backup. The password is not changed (it could not be updated and checked on the NVR).
   single:   control: a camera only ONE live NVR records (the list names that one): -PasswordAll changes it, the channel follows,
             video back, exit 0 (the guard is not too wide).
   Every mode runs twice: the second run must be just as honest and do no damage."""
import argparse, base64, hashlib, importlib.util, json, re, subprocess, tempfile, threading
from pathlib import Path
from http.server import ThreadingHTTPServer


def cam(ip, serial, mac, pw):
    return {'kind': 'camera', 'brand': 'Hikvision', 'model': 'DS-2CD2143G2-I', 'serial': serial, 'mac': mac, 'password': pw, 'https': True}


def nvr(serial, mac, chans, **kw):
    d = {'kind': 'nvr', 'brand': 'Hikvision', 'model': 'DS-7608NI-K2', 'serial': serial, 'mac': mac, 'password': 'Sitepass456', 'https': True, 'channels': chans}
    d.update(kw); return d


def ch(ip, pw, name):
    return {'ip': ip, 'password': pw, 'protocol': 'HIKVISION', 'name': name}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', required=True); ap.add_argument('--powershell', required=True); ap.add_argument('--only', default='')
    args = ap.parse_args(); repo = Path(args.repo)
    spec = importlib.util.spec_from_file_location('mock_site', repo / 'Toolkit/tests/fixsite/mock_site.py')
    mock = importlib.util.module_from_spec(spec); spec.loader.exec_module(mock)
    modes = ['sameip', 'move', 'wrongcam', 'nvrdown', 'single']
    if args.only: modes = [x for x in modes if x in args.only.split(',')]
    results = {}
    M50 = 'c4:2f:90:00:01:50'; M51 = 'c4:2f:90:00:01:51'; M20 = 'c4:2f:90:00:00:20'; M19 = 'c4:2f:90:00:00:19'
    with tempfile.TemporaryDirectory(prefix='fix2213site-') as tmp:
        for mode in modes:
            case = Path(tmp) / mode; vault = case / 'vault'; vault.mkdir(parents=True); runs = case / 'runs'
            pc = {'ip': '192.168.1.105', 'gw': '192.168.1.1', 'mask': '255.255.255.0', 'dhcp': True}
            sec = {'site': 'Review', 'password': 'Sitepass456', 'known': ['Oldpass123'], 'nvr': {'192.168.1.20': 'Sitepass456', '192.168.1.19': 'Sitepass456'},
                   'cams': {}, 'rollback': {}, 'bitwardenSaved': True, 'shownOnce': True}
            camip = '192.168.0.150' if mode == 'move' else '192.168.1.50'
            devices = {camip: cam(camip, 'CAMSER150', M50, 'Oldpass123')}
            lcams = [{'name': 'Gate', 'mac': M50, 'ip': '192.168.1.50', 'nvr': '192.168.1.20', 'channel': 1}]
            lnvrs = [{'brand': 'Hikvision', 'mac': M20, 'ip': '192.168.1.20'}, {'brand': 'Hikvision', 'mac': M19, 'ip': '192.168.1.19'}]
            if mode in ('sameip', 'move'):
                devices['192.168.1.20'] = nvr('NVRSER20', M20, {'1': ch(camip, 'Oldpass123', 'Gate')}, answers=False)
                devices['192.168.1.19'] = nvr('NVRSER19', M19, {'1': ch(camip, 'Oldpass123', 'Gate')})
            elif mode == 'wrongcam':
                devices['192.168.1.51'] = cam('192.168.1.51', 'CAMSER151', M51, 'Sitepass456')
                devices['192.168.1.20'] = nvr('NVRSER20', M20, {'1': ch(camip, 'Oldpass123', 'Gate')}, answers=False)
                devices['192.168.1.19'] = nvr('NVRSER19', M19, {'1': ch('192.168.1.51', 'Sitepass456', 'Door'), '2': ch(camip, 'Oldpass123', 'Gate')})
                lcams.append({'name': 'Door', 'mac': M51, 'ip': '192.168.1.51', 'nvr': '192.168.1.19', 'channel': 1})
            else:   # nvrdown, single: only .19 records the camera and the list names .19
                devices['192.168.1.19'] = nvr('NVRSER19', M19, {'1': ch(camip, 'Oldpass123', 'Gate')})
                lcams = [{'name': 'Gate', 'mac': M50, 'ip': '192.168.1.50', 'nvr': '192.168.1.19', 'channel': 1}]
                lnvrs = [{'brand': 'Hikvision', 'mac': M19, 'ip': '192.168.1.19'}]
            site_list = {'site': 'Review', 'scheme': '192.168.1', 'nvrs': lnvrs, 'cameras': lcams}
            scene = case / 'scene.json'; scene.write_text(json.dumps({'pc': pc, 'devices': devices})); mock.load(scene)
            ctl = {'down': False}

            class Handler(mock.H):
                def send(self, *a, **k):
                    try: return super().send(*a, **k)
                    except (BrokenPipeError, ConnectionResetError): pass

                def route(self, method, ip, path, q, body, rawq):
                    r = super().route(method, ip, path, q, body, rawq)
                    if mode == 'nvrdown' and ip == camip and path == '/ISAPI/System/configurationData' and not ctl['down']:
                        # the camera's backup has just been saved: its only NVR stops answering now (power cut, cable pulled)
                        ctl['down'] = True; n = mock.S['devices'].get('192.168.1.19')
                        if n: n['answers'] = False
                    return r

            class Server(ThreadingHTTPServer):
                daemon_threads = True
                def handle_error(self, request, client_address): pass

            server = Server(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
            slug = 'review-' + hashlib.sha256(b'review').hexdigest()[:8]
            (vault / ('site-' + slug + '.dat')).write_text('TEST:' + base64.b64encode(json.dumps(sec).encode()).decode())
            answers = case / 'answers.txt'; answers.write_text('N\nYES\nY\nYES\n' if mode == 'move' else 'YES\nY\nYES\n')
            config = case / 'config.json'; config.write_text(json.dumps({'fixSite': {'moveWaitSec': 2, 'rebootWaitSec': 2, 'verifyHoldSec': 0}}))
            lf = case / 'list.json'; lf.write_text(json.dumps(site_list))
            cmd = [args.powershell, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(repo / 'Toolkit/FixSite.ps1'), '-Site', 'Review', '-MockUrl', 'http://127.0.0.1:' + str(server.server_port),
                   '-SecretsDir', str(vault), '-RunsRoot', str(runs), '-SitesDir', str(case / 'sites'), '-Answers', str(answers), '-ConfigPath', str(config), '-ListFile', str(lf)]
            if mode != 'move': cmd += ['-PasswordAll']
            for run in (1, 2):
                try:
                    p = subprocess.run(cmd, capture_output=True, text=True, timeout=240)
                    out, code = p.stdout + p.stderr, p.returncode
                except subprocess.TimeoutExpired as e:
                    out, code = 'TIMEOUT ' + str(e.stdout or ''), -9
                S = mock.S
                c50 = next((v for v in S['devices'].values() if v.get('mac') == M50), None)
                c50ip = next((k for k, v in S['devices'].items() if v.get('mac') == M50), '')
                c51 = S['devices'].get('192.168.1.51')
                chans = {k: {c: {'ip': v2['ip'], 'pw': v2.get('password')} for c, v2 in v.get('channels', {}).items()} for k, v in S['devices'].items() if v['kind'] == 'nvr'}
                onl = {}
                for k, v in S['devices'].items():
                    if v['kind'] == 'nvr':
                        for c, v2 in v.get('channels', {}).items(): onl[k + '/' + c] = bool(mock.camera_online(v, v2))
                m = re.search(r'Still a problem:\s*(\d+)', out)
                results['%s%d' % (mode, run)] = {'exit': code, 'camip': c50ip, 'pw': c50['password'] if c50 else '', 'pwchanges': c50.get('pw_changes', 0) if c50 else -1,
                                                 'pw51': c51['password'] if c51 else '', 'pwchanges51': c51.get('pw_changes', 0) if c51 else 0,
                                                 'chans': chans, 'online': onl, 'problems': int(m.group(1)) if m else -1,
                                                 'said_multi': bool(re.search(r'NVRs record this camera', out)), 'said_list': bool(re.search(r'counting the NVR the site list names', out)),
                                                 'said_down': bool(re.search(r'does not answer right now|login is unknown \(or it did not answer', out)),
                                                 'said_pwset': bool(re.search(r'password set', out)), 'out': out[-2500:]}
            server.shutdown()
    print(json.dumps(results))


if __name__ == '__main__':
    main()
