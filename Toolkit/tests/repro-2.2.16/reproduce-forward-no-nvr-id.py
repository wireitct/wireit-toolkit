"""reproduce-forward-no-nvr-id.py - Codex 2.2.16 re-review (head c9f9fb2): "a forward camera fix can succeed without the NVR identity
   that Undo now requires". The REAL FixSite.ps1 (forward run) against the repository's mock devices (fixsite/mock_site.py, loopback only).
   Camera Gate is recorded by NVR .19 ch 1 (its login is known). Every mode runs twice through the real entry point.
     pwnoid:    -PasswordAll, camera on its old password, the NVR does NOT tell its MAC / serial: the camera password must NOT change,
                nothing is written to the NVR's channels, the result names the reason (MAC / serial), Still a problem, nonzero exit.
     movenoid:  camera on the wrong subnet 192.168.0.150, the NVR does NOT tell its MAC / serial: the camera is NOT moved, nothing is
                written to the NVR's channels, nonzero exit, never "Nothing to fix".
     pwid:      control: the NVR tells its MAC / serial: password set, channel follows, video back, exit 0, and the undo file holds the
                NVR's MAC for the camera's channel entry.
   Usage: python3 reproduce-forward-no-nvr-id.py --repo <repo root> --powershell <pwsh> [--only pwnoid,movenoid,pwid]"""
import argparse, base64, hashlib, importlib.util, json, os, re, subprocess, sys, tempfile, threading
from pathlib import Path
from http.server import ThreadingHTTPServer

M50 = 'c4:2f:90:00:01:50'; M19 = 'c4:2f:90:00:00:19'
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


def undo_nvr_macs(runs):
    out = []
    for f in Path(runs).rglob('rollback.json'):
        try: j = json.loads(f.read_text(encoding='utf-8-sig'))
        except Exception: continue
        for c in j.get('cameras') or []:
            n = c.get('nvr') or {}
            if isinstance(n, dict) and n.get('nvr'): out.append(str(n.get('nvr_mac') or ''))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', default=str(Path(__file__).resolve().parents[3])); ap.add_argument('--powershell', default='pwsh'); ap.add_argument('--only', default='')
    args = ap.parse_args(); repo = Path(args.repo)
    spec = importlib.util.spec_from_file_location('mock_site', repo / 'Toolkit/tests/fixsite/mock_site.py')
    mock = importlib.util.module_from_spec(spec); spec.loader.exec_module(mock)
    modes = ['pwnoid', 'movenoid', 'pwid']
    if args.only: modes = [x for x in modes if x in args.only.split(',')]
    results = {}
    with tempfile.TemporaryDirectory(prefix='repro2216-fwdid-') as tmp:
        for mode in modes:
            case = Path(tmp) / mode; vault = case / 'vault'; vault.mkdir(parents=True); runs = case / 'runs'
            pc = {'ip': '192.168.1.105', 'gw': '192.168.1.1', 'mask': '255.255.255.0', 'dhcp': True}
            sec = {'site': 'Review', 'password': 'Sitepass456', 'known': ['Oldpass123'], 'nvr': {'192.168.1.19': 'Sitepass456'},
                   'cams': {}, 'rollback': {}, 'bitwardenSaved': True, 'shownOnce': True}
            camip = '192.168.0.150' if mode == 'movenoid' else '192.168.1.50'
            lcams = [{'name': 'Gate', 'mac': M50, 'ip': '192.168.1.50', 'nvr': '192.168.1.19', 'channel': 1}]
            lnvrs = [{'brand': 'Hikvision', 'mac': M19, 'ip': '192.168.1.19'}]
            campw = 'Sitepass456' if mode == 'movenoid' else 'Oldpass123'
            if mode == 'movenoid': sec['cams'] = {M50: 'Sitepass456'}
            devices = {camip: cam('CAMSER150', M50, campw), '192.168.1.19': nvr('NVRSER19', M19, {'1': ch(camip, campw, 'Gate')})}
            site_list = {'site': 'Review', 'scheme': '192.168.1', 'nvrs': lnvrs, 'cameras': lcams}
            scene = case / 'scene.json'; scene.write_text(json.dumps({'pc': pc, 'devices': devices})); mock.load(scene)
            ctl = {'nvrputs': [], 'camwrites': []}
            hide = mode in ('pwnoid', 'movenoid')

            class Handler(mock.H):
                def send(self, *a, **k):
                    try: return super().send(*a, **k)
                    except (BrokenPipeError, ConnectionResetError): pass

                def route(self, method, ip, path, q, body, rawq):
                    if method in ('PUT', 'POST', 'DELETE') and ip == '192.168.1.19': ctl['nvrputs'].append({'path': path, 'method': method})
                    if method in ('PUT', 'POST') and ip != '192.168.1.19': ctl['camwrites'].append({'ip': ip, 'path': path})
                    if hide and ip == '192.168.1.19' and path == '/ISAPI/System/deviceInfo':
                        d = mock.S['devices'].get(ip)
                        if d and self.headers.get('Authorization'):
                            return self.send(200, '<DeviceInfo xmlns="http://www.hikvision.com/ver20/XMLSchema"><deviceName>x</deviceName><model>%s</model><firmwareVersion>V4</firmwareVersion><deviceType>NVR</deviceType></DeviceInfo>' % d['model'], 'application/xml')
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
            answers.write_text('N\nYES\nY\nYES\n' if mode == 'movenoid' else 'YES\nY\nYES\n')
            if mode != 'movenoid': cmd += ['-PasswordAll']
            for run in (1, 2):
                ctl['nvrputs'] = []; ctl['camwrites'] = []
                try:
                    p = subprocess.run(cmd, capture_output=True, text=True, timeout=200); out, code = p.stdout + p.stderr, p.returncode
                except subprocess.TimeoutExpired as e:
                    out, code = 'TIMEOUT ' + str(e.stdout or ''), -9
                if os.environ.get('REPRO_DEBUG'): print(out[-4000:])
                S = mock.S
                c50 = next((v for v in S['devices'].values() if v.get('mac') == M50), None)
                c50ip = next((k for k, v in S['devices'].items() if v.get('mac') == M50), '')
                n19 = S['devices'].get('192.168.1.19') or {}
                vid = bool(mock.camera_online(n19, (n19.get('channels') or {}).get('1'))) if (n19.get('channels') or {}).get('1') else False
                m = re.search(r'Still a problem:\s*(\d+)', out)
                r = {'exit': code, 'camip': c50ip, 'pw': c50['password'] if c50 else '', 'pwchanges': c50.get('pw_changes', 0) if c50 else -1, 'video19': vid,
                     'problems': int(m.group(1)) if m else -1, 'nvrputs': ctl['nvrputs'], 'camwrites': ctl['camwrites'], 'undo_macs': undo_nvr_macs(runs),
                     'nothing': bool(re.search(r'Nothing to fix', out)), 'saidid': bool(re.search(r'MAC / serial', out)), 'out': out[-2500:]}
                results['%s%d' % (mode, run)] = r
                tag = '%s run %d: ' % (mode, run)
                if mode == 'pwnoid':
                    check(tag + 'camera password NOT changed (the NVR did not tell its MAC / serial)', r['pw'] == 'Oldpass123' and r['pwchanges'] == 0 and not r['camwrites'])
                    check(tag + 'nothing written to the NVR, its channel keeps video', not r['nvrputs'] and vid)
                    check(tag + 'the result names the missing MAC / serial, Still a problem, nonzero exit', r['saidid'] and code != 0 and r['problems'] != 0)
                elif mode == 'movenoid':
                    check(tag + 'camera NOT moved (still on 192.168.0.150), nothing written to it', c50ip == '192.168.0.150' and not r['camwrites'])
                    check(tag + 'nothing written to the NVR, its channel keeps video', not r['nvrputs'] and vid)
                    check(tag + 'the result names the missing MAC / serial, nonzero exit, never "Nothing to fix"', r['saidid'] and code != 0 and not r['nothing'])
                else:
                    if run == 1:
                        check(tag + 'control: the NVR tells its MAC: password set, video back, exit 0', r['pw'] == 'Sitepass456' and vid and code == 0)
                        check(tag + 'control: the undo file holds the NVR MAC for the camera channel', M19 in [x.lower() for x in r['undo_macs']])
                    else: check(tag + 'control: second run is clean, exit 0', r['pw'] == 'Sitepass456' and vid and code == 0)
            server.shutdown()
    print('REPRO=' + json.dumps({k: {kk: vv for kk, vv in v.items() if kk != 'out'} for k, v in results.items()}))
    print('%d passed, %d failed' % (PASS, FAIL))
    sys.exit(0 if FAIL == 0 else 1)


if __name__ == '__main__':
    main()
