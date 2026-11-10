"""fix2214site/scenarios.py - WireIt Toolkit 2.2.14, Fix this site: Codex's 2.2.13 review findings F1, F2, F8 as permanent tests.
   The REAL FixSite.ps1 against the repository's mock devices (fixsite/mock_site.py, loopback only). Every mode runs twice.
   F1 (one recorder, TWO channels record the camera):
     multi:     Codex's reproduction: NVR .19 ch 1 and ch 2 both record camera .50 (old password), -PasswordAll. The password must NOT
                change (ch 2 would lose its video); Still a problem, nonzero exit.
     multioff:  Codex's second run: ch 1 has video, ch 2 (same camera) has none. Must be a problem, never "Still a problem: 0".
     multimove: address change: camera on the wrong subnet 192.168.0.150, .19 ch 1 + ch 2 record it: NOT moved, nonzero exit.
     multihalf: failing half-way: 2-channel camera, the NVR stops answering right after the camera's backup: nothing written.
     wrongcam:  wrong device (control): .19 ch 1 records ANOTHER camera (.51), ch 2 ours: ONE dependent channel -> ours gets the
                site password, .51 and its channel untouched, exit 0 (the new guard is not too wide).
     single:    control: one channel, one NVR: changed, channel follows, video back, exit 0.
   F2 (official reset target selection under -MockUrl):
     reset:     camera login unknown, .19 ch 1 has no video, NVR .20 still records it: the official reset is NOT run for it (blocked with
                the reason), its password untouched, nonzero exit.
   F8 (Undo of a channel replacement; constructed journal like Codex's):
     undo:      Codex's reproduction: the saved channel names a DIFFERENT original camera (.51, its own password Othercam789). The
                replacement's password (Sitepass456) must never be written to that channel; "NOT confirmed", nonzero exit.
     undook:    control: the original camera .51 uses the site password: it logs in, the channel goes back with it, video back, exit 0.
     undohalf:  failing half-way: the original camera .51 does not answer during Undo: NOT confirmed, nonzero exit.
     undosame:  control: the saved channel is the SAME camera: its own password, video back, exit 0."""
import argparse, base64, hashlib, importlib.util, json, re, subprocess, tempfile, threading
from pathlib import Path
from http.server import ThreadingHTTPServer

M50 = 'c4:2f:90:00:01:50'; M51 = 'c4:2f:90:00:01:51'; M20 = 'c4:2f:90:00:00:20'; M19 = 'c4:2f:90:00:00:19'


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
    ap.add_argument('--repo', required=True); ap.add_argument('--powershell', required=True); ap.add_argument('--only', default='')
    args = ap.parse_args(); repo = Path(args.repo)
    spec = importlib.util.spec_from_file_location('mock_site', repo / 'Toolkit/tests/fixsite/mock_site.py')
    mock = importlib.util.module_from_spec(spec); spec.loader.exec_module(mock)
    modes = ['multi', 'multioff', 'multimove', 'multihalf', 'wrongcam', 'single', 'reset', 'undo', 'undook', 'undohalf', 'undosame']
    if args.only: modes = [x for x in modes if x in args.only.split(',')]
    results = {}
    with tempfile.TemporaryDirectory(prefix='fix2214site-') as tmp:
        for mode in modes:
            case = Path(tmp) / mode; vault = case / 'vault'; vault.mkdir(parents=True); runs = case / 'runs'
            pc = {'ip': '192.168.1.105', 'gw': '192.168.1.1', 'mask': '255.255.255.0', 'dhcp': True}
            sec = {'site': 'Review', 'password': 'Sitepass456', 'known': ['Oldpass123'], 'nvr': {'192.168.1.20': 'Sitepass456', '192.168.1.19': 'Sitepass456'},
                   'cams': {}, 'rollback': {}, 'bitwardenSaved': True, 'shownOnce': True}
            camip = '192.168.0.150' if mode == 'multimove' else '192.168.1.50'
            lcams = [{'name': 'Gate', 'mac': M50, 'ip': '192.168.1.50', 'nvr': '192.168.1.19', 'channel': 1}]
            lnvrs = [{'brand': 'Hikvision', 'mac': M19, 'ip': '192.168.1.19'}]
            undo = mode.startswith('undo')
            pwall = mode not in ('multimove', 'reset') and not undo
            if mode in ('multi', 'multihalf', 'multimove'):
                devices = {camip: cam('CAMSER150', M50, 'Oldpass123'),
                           '192.168.1.19': nvr('NVRSER19', M19, {'1': ch(camip, 'Oldpass123', 'Gate'), '2': ch(camip, 'Oldpass123', 'Gate second sensor')})}
            elif mode == 'multioff':
                devices = {camip: cam('CAMSER150', M50, 'Sitepass456'),
                           '192.168.1.19': nvr('NVRSER19', M19, {'1': ch(camip, 'Sitepass456', 'Gate'), '2': ch(camip, 'Oldpass123', 'Gate second sensor')})}
            elif mode == 'wrongcam':
                devices = {camip: cam('CAMSER150', M50, 'Oldpass123'), '192.168.1.51': cam('CAMSER151', M51, 'Sitepass456'),
                           '192.168.1.19': nvr('NVRSER19', M19, {'1': ch('192.168.1.51', 'Sitepass456', 'Door'), '2': ch(camip, 'Oldpass123', 'Gate')})}
                lcams = [{'name': 'Gate', 'mac': M50, 'ip': '192.168.1.50', 'nvr': '192.168.1.19', 'channel': 2}, {'name': 'Door', 'mac': M51, 'ip': '192.168.1.51', 'nvr': '192.168.1.19', 'channel': 1}]
            elif mode == 'single':
                devices = {camip: cam('CAMSER150', M50, 'Oldpass123'), '192.168.1.19': nvr('NVRSER19', M19, {'1': ch(camip, 'Oldpass123', 'Gate')})}
            elif mode == 'reset':
                devices = {camip: cam('CAMSER150', M50, 'Unknown999'),
                           '192.168.1.19': nvr('NVRSER19', M19, {'1': ch(camip, 'Wrongpw000', 'Gate')}),
                           '192.168.1.20': nvr('NVRSER20', M20, {'1': ch(camip, 'Unknown999', 'Gate')})}
                lnvrs = [{'brand': 'Hikvision', 'mac': M19, 'ip': '192.168.1.19'}, {'brand': 'Hikvision', 'mac': M20, 'ip': '192.168.1.20'}]
            else:   # undo*: the forward run replaced the channel's camera with .50 (site password); the journal is constructed
                origip = '192.168.1.50' if mode == 'undosame' else '192.168.1.51'
                origpw = 'Sitepass456' if mode in ('undook', 'undosame') else 'Othercam789'
                devices = {'192.168.1.50': cam('CAM50', M50, 'Sitepass456'),
                           '192.168.1.19': nvr('NVR19', M19, {'1': ch('192.168.1.50', 'Sitepass456', 'Gate')})}
                if mode != 'undosame': devices['192.168.1.51'] = cam('CAM51', M51, origpw, answers=(mode != 'undohalf'))
                sec['known'] = []; sec['cams'] = {M50: 'Sitepass456'}; sec['rollback'] = {'review-before': {}}
            site_list = {'site': 'Review', 'scheme': '192.168.1', 'nvrs': lnvrs, 'cameras': lcams}
            scene = case / 'scene.json'; scene.write_text(json.dumps({'pc': pc, 'devices': devices})); mock.load(scene)
            ctl = {'down': False, 'puts': []}

            class Handler(mock.H):
                def send(self, *a, **k):
                    try: return super().send(*a, **k)
                    except (BrokenPipeError, ConnectionResetError): pass

                def route(self, method, ip, path, q, body, rawq):
                    if method in ('PUT', 'POST') and '/InputProxy/channels' in path: ctl['puts'].append({'ip': ip, 'path': path, 'pw': mock.xml_text(body, 'password') if body else ''})
                    r = super().route(method, ip, path, q, body, rawq)
                    if mode == 'multihalf' and ip == camip and path == '/ISAPI/System/configurationData' and not ctl['down']:
                        ctl['down'] = True; n = mock.S['devices'].get('192.168.1.19')
                        if n: n['answers'] = False
                    return r

            class Server(ThreadingHTTPServer):
                daemon_threads = True
                def handle_error(self, request, client_address): pass

            server = Server(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
            slug = 'review-' + hashlib.sha256(b'review').hexdigest()[:8]
            (vault / ('site-' + slug + '.dat')).write_text('TEST:' + base64.b64encode(json.dumps(sec).encode()).decode())
            answers = case / 'answers.txt'
            config = case / 'config.json'; config.write_text(json.dumps({'fixSite': {'moveWaitSec': 2, 'rebootWaitSec': 2, 'verifyHoldSec': 0}}))
            lf = case / 'list.json'; lf.write_text(json.dumps(site_list))
            base = [args.powershell, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(repo / 'Toolkit/FixSite.ps1'), '-Site', 'Review', '-MockUrl', 'http://127.0.0.1:' + str(server.server_port),
                    '-SecretsDir', str(vault), '-RunsRoot', str(runs), '-SitesDir', str(case / 'sites'), '-Answers', str(answers), '-ConfigPath', str(config)]
            if undo:
                rb = case / 'original-run'; (rb / 'backup').mkdir(parents=True)
                (rb / 'backup/channel.xml').write_text(mock.H.chxml(None, '1', {'ip': origip, 'protocol': 'HIKVISION', 'name': 'Original camera'}))
                c = {'name': 'Gate', 'mac': M50, 'brand': 'Hikvision', 'ip_before': '192.168.1.50', 'ip_after': '', 'net_before': {'ip': '192.168.1.50', 'mask': '255.255.255.0', 'gw': '192.168.1.1', 'dhcp': False, 'dns1': '8.8.8.8', 'dns2': ''},
                     'stream_before': None, 'password_changed': False, 'nvr': {'nvr': '192.168.1.19', 'channel': 1, 'action': 'updated', 'before_file': 'backup/channel.xml'}}
                (rb / 'rollback.json').write_text(json.dumps({'run': 'review-before', 'site': 'Review', 'scheme': '192.168.1', 'taken_on': 'test', 'cameras': [c], 'nvrs': []}))
                answers.write_text('YES\n'); cmd = base + ['-Mode', 'Rollback', '-RollbackDir', str(rb)]
            else:
                answers.write_text('N\nYES\nY\nYES\n' if mode == 'multimove' else 'YES\nY\nYES\n'); cmd = base + ['-ListFile', str(lf)]
                if pwall: cmd += ['-PasswordAll']
            for run in (1, 2):
                ctl['puts'] = []
                if mode == 'reset' and run == 2: answers.write_text('Y\nYES\nY\nYES\n')   # run 2 first asks to switch the (now locked) camera's password
                try:
                    p = subprocess.run(cmd, capture_output=True, text=True, timeout=200)
                    out, code = p.stdout + p.stderr, p.returncode
                except subprocess.TimeoutExpired as e:
                    out, code = 'TIMEOUT ' + str(e.stdout or ''), -9
                S = mock.S
                c50 = next((v for v in S['devices'].values() if v.get('mac') == M50), None)
                c50ip = next((k for k, v in S['devices'].items() if v.get('mac') == M50), '')
                c51 = S['devices'].get('192.168.1.51')
                chans = {k: {cc: {'ip': v2['ip'], 'pw': v2.get('password')} for cc, v2 in v.get('channels', {}).items()} for k, v in S['devices'].items() if v['kind'] == 'nvr'}
                onl = {}
                for k, v in S['devices'].items():
                    if v['kind'] == 'nvr':
                        for cc, v2 in v.get('channels', {}).items(): onl[k + '/' + cc] = bool(mock.camera_online(v, v2))
                m = re.search(r'Still a problem:\s*(\d+)', out)
                results['%s%d' % (mode, run)] = {'exit': code, 'camip': c50ip, 'pw': c50['password'] if c50 else '', 'pwchanges': c50.get('pw_changes', 0) if c50 else -1,
                                                 'pw51': c51['password'] if c51 else '', 'pwchanges51': c51.get('pw_changes', 0) if c51 else 0,
                                                 'chans': chans, 'online': onl, 'problems': int(m.group(1)) if m else -1, 'puts': ctl['puts'],
                                                 'said_chans': bool(re.search(r'NVR channels record this camera', out)),
                                                 'said_alsonovideo': bool(re.search(r'also records this camera and has NO video', out)),
                                                 'said_down': bool(re.search(r'does not answer right now|login is unknown \(or it did not answer', out)),
                                                 'said_resetblocked': bool(re.search(r'official reset NOT run', out)),
                                                 'said_notconfirmed': bool(re.search(r'NOT confirmed', out)),
                                                 'said_allback': bool(re.search(r'everything is back', out)),
                                                 'said_videoback': bool(re.search(r'video back', out)),
                                                 'said_pwset': bool(re.search(r'password set', out)), 'out': out[-2500:]}
            server.shutdown()
    print(json.dumps(results))


if __name__ == '__main__':
    main()
