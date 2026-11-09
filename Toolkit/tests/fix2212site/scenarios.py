"""2.2.12 (Fix this site) regression scenarios: the real FixSite.ps1 entry point against mock_site.py devices, loopback only.
   Codex's 2.2.11 review findings #1, #2 and #4 as permanent tests (each one failed on 2.2.11 head 91d5353):
   multinvr:   a camera two NVRs record is NOT moved (the other NVR would lose it) and the run does not say all fixed (#1)
   multilist:  the same, when the site list names one NVR (offline) and the scan finds the other recording it (#1)
   singlenvr:  control: a camera only ONE NVR records still moves normally (the guard is not too wide)
   netfail:    one HTTP 500 on the network read after the backup: no change at all to that camera, no empty net_before (#2)
   settings:   the camera accepts "20 fps" but stays at 12: no green check, Still a problem, exit not 0 (#4)
   settingsok: control: the camera takes the settings: confirmed, exit 0
   Every mode can run twice (--twice): the second run must be just as honest."""
import argparse, base64, hashlib, importlib.util, json, re, subprocess, tempfile, threading, sys
from pathlib import Path
from http.server import ThreadingHTTPServer


def cam(ip, brand, serial, mac, pw, **kw):
    d = {'kind': 'camera', 'brand': brand, 'model': 'DS-2CD2143G2-I' if brand == 'Hikvision' else 'IPC-HDW2431T', 'serial': serial, 'mac': mac, 'password': pw, 'https': True}
    d.update(kw); return d


def nvr(ip, serial, mac, chans, **kw):
    d = {'kind': 'nvr', 'brand': 'Hikvision', 'model': 'DS-7608NI-K2', 'serial': serial, 'mac': mac, 'password': 'Sitepass456', 'https': True, 'channels': chans}
    d.update(kw); return d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', required=True); ap.add_argument('--powershell', required=True); ap.add_argument('--only', default='')
    args = ap.parse_args(); repo = Path(args.repo)
    spec = importlib.util.spec_from_file_location('mock_site', repo / 'Toolkit/tests/fixsite/mock_site.py')
    mock = importlib.util.module_from_spec(spec); spec.loader.exec_module(mock)
    modes = ['multinvr', 'multilist', 'singlenvr', 'netfail', 'settings', 'settingsok']
    if args.only: modes = [m for m in modes if m in args.only.split(',')]
    results = {}
    with tempfile.TemporaryDirectory(prefix='fix2212site-') as tmp:
        for mode in modes:
            case = Path(tmp) / mode; vault = case / 'vault'; vault.mkdir(parents=True); runs = case / 'runs'
            pc = {'ip': '192.168.1.105', 'gw': '192.168.1.1', 'mask': '255.255.255.0', 'dhcp': True}
            sec = {'site': 'Review', 'password': 'Sitepass456', 'known': ['Oldpass123'], 'nvr': {}, 'cams': {}, 'rollback': {}, 'bitwardenSaved': True, 'shownOnce': True}
            extra = []; site_list = None; camip = ''
            if mode in ('multinvr', 'multilist', 'singlenvr'):
                camip = '192.168.0.150'
                ch = lambda: {'1': {'ip': camip, 'password': 'Sitepass456', 'protocol': 'HIKVISION', 'name': 'Gate'}}
                devices = {camip: cam(camip, 'Hikvision', 'CAMSER150', 'c4:2f:90:00:01:50', 'Sitepass456'),
                           '192.168.1.20': nvr('192.168.1.20', 'NVRSER20', 'c4:2f:90:00:00:20', ch() if mode != 'singlenvr' else {}),
                           '192.168.1.19': nvr('192.168.1.19', 'NVRSER19', 'c4:2f:90:00:00:19', ch())}
                if mode == 'multilist':
                    devices['192.168.1.20']['answers'] = False   # the NVR the list names is offline today; .19 records the camera
                    site_list = {'site': 'Review', 'scheme': '192.168.1', 'nvrs': [{'brand': 'Hikvision', 'mac': 'c4:2f:90:00:00:20', 'ip': '192.168.1.20'}, {'brand': 'Hikvision', 'mac': 'c4:2f:90:00:00:19', 'ip': '192.168.1.19'}],
                                 'cameras': [{'name': 'Gate', 'mac': 'c4:2f:90:00:01:50', 'ip': '192.168.1.50', 'nvr': '192.168.1.20', 'channel': 1}]}
                sec['nvr']['192.168.1.20'] = 'Sitepass456'; sec['nvr']['192.168.1.19'] = 'Sitepass456'
            elif mode == 'netfail':
                camip = '192.168.0.40'
                devices = {camip: cam(camip, 'Dahua', '7J0NETFAIL40', '3c:ef:8c:00:00:40', 'Oldpass123', stream={'codec': 'H.264', 'fps': 15, 'width': 2688, 'height': 1520, 'bitrate': 4096, 'gop': 15, 'smart': 'off', 'maxw': 2688, 'maxh': 1520})}
            else:
                camip = '192.168.1.21'
                devices = {camip: cam(camip, 'Hikvision', 'CAMSERIAL9', 'c4:2f:90:00:00:29', 'Sitepass456', stream={'codec': 'H.264', 'fps': 12, 'width': 2688, 'height': 1520, 'bitrate': 4096, 'gop': 12, 'smart': 'off', 'maxw': 2688, 'maxh': 1520})}
                extra = ['-Fps', '20', '-AllCameras']
            scene = case / 'scene.json'; scene.write_text(json.dumps({'pc': pc, 'devices': devices})); mock.load(scene)
            ctl = {'after_backup': False, 'failed': 0, 'fail_on': mode == 'netfail'}

            class Handler(mock.H):
                def send(self, *a, **k):
                    try: return super().send(*a, **k)
                    except (BrokenPipeError, ConnectionResetError): pass

                def route(self, method, ip, path, q, body, rawq):
                    if mode == 'netfail' and path == '/cgi-bin/Config.backup': ctl['after_backup'] = True
                    if mode == 'netfail' and ctl['fail_on'] and path == '/cgi-bin/configManager.cgi' and q.get('action') == 'getConfig' and q.get('name') == 'Network' and ctl['after_backup'] and self.headers.get('Authorization'):
                        # the backup has just read Network fine; THIS read (the one Undo would journal) fails once
                        if ctl.get('seen_backup_net'):
                            ctl['fail_on'] = False; ctl['failed'] += 1
                            return self.send(500, 'Error\r\nInternal error\r\n')
                        ctl['seen_backup_net'] = True
                    if mode == 'settings' and method == 'PUT' and path == '/ISAPI/Streaming/channels/101':
                        d = mock.S['devices'].get(ip); keep = dict(d['stream']) if d else None
                        r = super().route(method, ip, path, q, body, rawq)
                        if d: d['stream'].update(fps=keep['fps'])   # accepts the write ("OK") but stays at 12 fps
                        return r
                    return super().route(method, ip, path, q, body, rawq)

            class Server(ThreadingHTTPServer):
                daemon_threads = True
                def handle_error(self, request, client_address): pass

            server = Server(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
            slug = 'review-' + hashlib.sha256(b'review').hexdigest()[:8]
            (vault / ('site-' + slug + '.dat')).write_text('TEST:' + base64.b64encode(json.dumps(sec).encode()).decode())
            answers = case / 'answers.txt'; answers.write_text('YES\nY\nYES\n' if mode.startswith('settings') else 'N\nYES\nY\nYES\n')
            config = case / 'config.json'; config.write_text(json.dumps({'fixSite': {'moveWaitSec': 2, 'rebootWaitSec': 2, 'verifyHoldSec': 0}}))
            cmd = [args.powershell, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(repo / 'Toolkit/FixSite.ps1'), '-Site', 'Review', '-MockUrl', 'http://127.0.0.1:' + str(server.server_port),
                   '-SecretsDir', str(vault), '-RunsRoot', str(runs), '-SitesDir', str(case / 'sites'), '-Answers', str(answers), '-ConfigPath', str(config)] + extra
            if site_list:
                lf = case / 'list.json'; lf.write_text(json.dumps(site_list)); cmd += ['-ListFile', str(lf)]
            for run in (1, 2):
                try:
                    p = subprocess.run(cmd, capture_output=True, text=True, timeout=240)
                    out, code = p.stdout + p.stderr, p.returncode
                except subprocess.TimeoutExpired as e:
                    out, code = 'TIMEOUT ' + str(e.stdout or ''), -9
                S = mock.S
                cams = {k: v for k, v in S['devices'].items() if v['kind'] == 'camera'}
                camnow = list(cams.keys())
                chans = {k: {c: v2['ip'] for c, v2 in v.get('channels', {}).items()} for k, v in S['devices'].items() if v['kind'] == 'nvr'}
                online19 = False
                n19 = S['devices'].get('192.168.1.19')
                if n19 and '1' in n19.get('channels', {}): online19 = mock.camera_online(n19, n19['channels']['1'])
                rbs = []
                for rb in sorted(runs.glob('FixSite-*/rollback.json')):
                    try: rbs.append(json.loads(rb.read_text(encoding='utf-8-sig')))
                    except Exception as ex: rbs.append({'unreadable': str(ex)})
                nets = []
                for rb in rbs:
                    for c in rb.get('cameras', []) or []:
                        if c and 'net_before' in c: nets.append(c['net_before'])
                stream = next(iter(cams.values()))['stream'] if cams else {}
                pwnow = next(iter(cams.values()))['password'] if cams else ''
                m = re.search(r'Still a problem:\s*(\d+)', out)
                results['%s%d' % (mode, run)] = {'exit': code, 'cams': camnow, 'chans': chans, 'online19': online19, 'nets': nets, 'fps': stream.get('fps'), 'pw': pwnow,
                                                 'problems': int(m.group(1)) if m else -1, 'failed500': ctl['failed'],
                                                 'said_multi': bool(re.search(r'NVRs record this camera', out)), 'said_netread': bool(re.search(r'network settings could not be read', out)),
                                                 'said_unconfirmed': bool(re.search(r'NOT confirmed', out)), 'said_20fps_green': bool(re.search(r'(?<!asked )20 fps(, I-frame 20)? (\u2705|\[OK\])', out)), 'out': out[-2500:]}
            server.shutdown()
    print(json.dumps(results))


if __name__ == '__main__':
    main()
