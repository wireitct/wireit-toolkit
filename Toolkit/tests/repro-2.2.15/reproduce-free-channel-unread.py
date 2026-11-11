"""reproduce-free-channel-unread.py - Codex 2.2.15 review, free-channel follow-up (a CONTROL: it passes on 2.2.15 and on 2.2.16).
   The REAL FixSite.ps1 against the repository's mock devices (loopback only), run twice. The site list puts camera Gate (.50, old
   password) on NVR .19 with channel 0 (no channel yet); .19 has no channels; every channel-list read after the scan's first answers
   HTTP 500. -PasswordAll. The tool must NOT pick "a free channel" from a list it could not read: no channel PUT/POST, the line says
   "NOT put on the NVR", nonzero exit, both runs.
   Usage: python3 reproduce-free-channel-unread.py --repo <repo root> --powershell <pwsh>"""
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', default=str(Path(__file__).resolve().parents[3])); ap.add_argument('--powershell', default='pwsh')
    args = ap.parse_args(); repo = Path(args.repo)
    spec = importlib.util.spec_from_file_location('mock_site', repo / 'Toolkit/tests/fixsite/mock_site.py')
    mock = importlib.util.module_from_spec(spec); spec.loader.exec_module(mock)
    results = {}
    with tempfile.TemporaryDirectory(prefix='repro2215-freech-') as tmp:
        case = Path(tmp) / 'single'; vault = case / 'vault'; vault.mkdir(parents=True); runs = case / 'runs'
        pc = {'ip': '192.168.1.105', 'gw': '192.168.1.1', 'mask': '255.255.255.0', 'dhcp': True}
        sec = {'site': 'Review', 'password': 'Sitepass456', 'known': ['Oldpass123'], 'nvr': {'192.168.1.19': 'Sitepass456'}, 'cams': {}, 'rollback': {}, 'bitwardenSaved': True, 'shownOnce': True}
        devices = {'192.168.1.50': {'kind': 'camera', 'brand': 'Hikvision', 'model': 'DS-2CD2143G2-I', 'serial': 'CAMSER150', 'mac': M50, 'password': 'Oldpass123', 'https': True},
                   '192.168.1.19': {'kind': 'nvr', 'brand': 'Hikvision', 'model': 'DS-7608NI-K2', 'serial': 'NVRSER19', 'mac': M19, 'password': 'Sitepass456', 'https': True, 'channels': {}}}
        site_list = {'site': 'Review', 'scheme': '192.168.1', 'nvrs': [{'brand': 'Hikvision', 'mac': M19, 'ip': '192.168.1.19'}],
                     'cameras': [{'name': 'Gate', 'mac': M50, 'ip': '192.168.1.50', 'nvr': '192.168.1.19', 'channel': 0}]}
        scene = case / 'scene.json'; scene.write_text(json.dumps({'pc': pc, 'devices': devices})); mock.load(scene)
        ctl = {'puts': [], 'listReads': 0}

        class Handler(mock.H):
            def send(self, *a, **k):
                try: return super().send(*a, **k)
                except (BrokenPipeError, ConnectionResetError): pass

            def route(self, method, ip, path, q, body, rawq):
                if method == 'GET' and path == '/ISAPI/ContentMgmt/InputProxy/channels':
                    ctl['listReads'] += 1
                    if ctl['listReads'] > 1: return self.send(500, 'unread at free-channel step')
                if method in ('PUT', 'POST') and '/InputProxy/channels' in path: ctl['puts'].append({'ip': ip, 'path': path})
                return super().route(method, ip, path, q, body, rawq)

        class Server(ThreadingHTTPServer):
            daemon_threads = True
            def handle_error(self, request, client_address): pass

        server = Server(('127.0.0.1', 0), Handler); threading.Thread(target=server.serve_forever, daemon=True).start()
        slug = 'review-' + hashlib.sha256(b'review').hexdigest()[:8]
        (vault / ('site-' + slug + '.dat')).write_text('TEST:' + base64.b64encode(json.dumps(sec).encode()).decode())
        answers = case / 'answers.txt'; answers.write_text('YES\nY\nYES\n')
        config = case / 'config.json'; config.write_text(json.dumps({'fixSite': {'moveWaitSec': 2, 'rebootWaitSec': 2, 'verifyHoldSec': 0}}))
        lf = case / 'list.json'; lf.write_text(json.dumps(site_list))
        cmd = [args.powershell, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(repo / 'Toolkit/FixSite.ps1'), '-Site', 'Review', '-MockUrl', 'http://127.0.0.1:' + str(server.server_port),
               '-SecretsDir', str(vault), '-RunsRoot', str(runs), '-SitesDir', str(case / 'sites'), '-Answers', str(answers), '-ConfigPath', str(config), '-ListFile', str(lf), '-PasswordAll']
        for run in (1, 2):
            ctl['puts'] = []; ctl['listReads'] = 0
            try:
                p = subprocess.run(cmd, capture_output=True, text=True, timeout=200); out, code = p.stdout + p.stderr, p.returncode
            except subprocess.TimeoutExpired as e:
                out, code = 'TIMEOUT ' + str(e.stdout or ''), -9
            if os.environ.get('REPRO_DEBUG'): print(out[-4000:])
            chans = mock.S['devices']['192.168.1.19'].get('channels', {})
            r = {'exit': code, 'puts': ctl['puts'], 'channels': list(chans.keys()), 'notput': 'NOT put on the NVR' in out}
            results['single%d' % run] = r
            tag = 'run %d: ' % run
            check(tag + 'no channel is written on NVR .19 from an unread channel list', not r['puts'] and not chans)
            check(tag + 'the line says "NOT put on the NVR"', r['notput'])
            check(tag + 'nonzero exit', code != 0)
        server.shutdown()
    print('REPRO=' + json.dumps(results))
    print('%d passed, %d failed' % (PASS, FAIL))
    sys.exit(0 if FAIL == 0 else 1)


if __name__ == '__main__':
    main()
