"""2.2.6 regression scenarios against the real FixSite.ps1 entry point, on loopback only (mock_site.py devices).
   identity: a camera at a saved camera's address, missed by discovery, must not take on the saved camera's identity.
   journal:  an undo file (rollback.json) that cannot be written stops the run before any device is changed.
   move:     a run killed while a camera is moving still leaves Undo the new address, and Undo puts the camera back."""
import argparse
import base64
import hashlib
import importlib.util
import json
import shutil
from pathlib import Path
import subprocess
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer


def read_vault(vault):
    f = next(vault.glob('site-*.dat'))
    t = f.read_text(encoding='utf-8-sig').strip()
    if t.startswith('TEST:'):
        t = t[5:]
    return json.loads(base64.b64decode(t).decode('utf-8-sig'))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', required=True)
    ap.add_argument('--powershell', required=True)
    args = ap.parse_args()
    repo = Path(args.repo)
    spec = importlib.util.spec_from_file_location('mock_site', repo / 'Toolkit/tests/fixsite/mock_site.py')
    mock = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mock)
    results = {}
    with tempfile.TemporaryDirectory(prefix='fix226-') as tmp:
        root = Path(tmp)
        for mode in ['identity', 'journal', 'move']:
            case = root / mode
            vault = case / 'vault'
            vault.mkdir(parents=True)
            runs = case / 'runs'
            pc = {'ip': '192.168.1.105', 'gw': '192.168.1.1', 'mask': '255.255.255.0', 'dhcp': True}
            sec = {'site': 'Review', 'password': 'Sitepass456', 'known': ['Oldpass123'], 'nvr': {}, 'cams': {},
                   'rollback': {}, 'bitwardenSaved': True, 'shownOnce': True}
            extra = []
            if mode == 'identity':
                # The saved list says camera A (MAC ..:aa) is at .21. Camera A is gone; camera B now has .21 and discovery misses it.
                devices = {'192.168.1.21': {'kind': 'camera', 'brand': 'Hikvision', 'model': 'DS-2CD2143G2-I', 'serial': 'CAMSERIALB',
                                            'mac': 'c4:2f:90:00:00:bb', 'password': 'Sitepass456', 'https': True}}
                sec['cams']['c4:2f:90:00:00:aa'] = 'Apass999'
                lst = case / 'list.json'
                lst.write_text(json.dumps({'site': 'Review', 'scheme': '192.168.1', 'nvrs': [], 'cameras': [
                    {'name': 'Door', 'brand': 'Hikvision', 'model': 'DS-2CD2143G2-I', 'serial': 'CAMSERIALA', 'mac': 'c4:2f:90:00:00:aa', 'ip': '192.168.1.21'}]}))
                extra = ['-Mode', 'Plan', '-ListFile', str(lst)]
            elif mode == 'journal':
                # a recorder that gets the site password; its run folder (where the undo file goes) is gone before anything is changed
                devices = {'192.168.1.20': {'kind': 'nvr', 'brand': 'Hikvision', 'model': 'DS-7608NI-K2', 'serial': 'NVRSERIAL1',
                                            'mac': 'c4:2f:90:00:00:20', 'password': 'Oldpass123', 'https': True, 'channels': {}}}
                sec['nvr']['192.168.1.20'] = 'Oldpass123'
                extra = ['-PasswordAll']
            else:
                # on the wrong scheme: Fix this site moves it onto 192.168.1.x
                devices = {'192.168.5.30': {'kind': 'camera', 'brand': 'Hikvision', 'model': 'DS-2CD2143G2-I', 'serial': 'CAMSERIAL1',
                                            'mac': 'c4:2f:90:00:00:30', 'password': 'Sitepass456', 'https': True}}
            scene_file = case / 'scene.json'
            scene_file.write_text(json.dumps({'pc': pc, 'devices': devices}))
            mock.load(scene_file)
            gate, waiting, release = threading.Event(), threading.Event(), threading.Event()
            moved = {'to': ''}

            class Handler(mock.H):
                def send(self, *a, **k):
                    try:
                        return super().send(*a, **k)
                    except (BrokenPipeError, ConnectionResetError):
                        pass

                def pc(self, method, path, q, body):
                    if mode == 'identity' and path == '/scan':
                        return self.send(200, '[]', 'application/json')
                    return super().pc(method, path, q, body)

                def route(self, method, ip, path, q, body, rawq):
                    if mode == 'journal' and not gate.is_set():
                        gate.wait(30)
                    if mode == 'move' and moved['to'] and ip == moved['to'] and method == 'GET' and not release.is_set():
                        waiting.set()
                        release.wait(20)
                    r = super().route(method, ip, path, q, body, rawq)
                    if mode == 'move' and method == 'PUT' and path == '/ISAPI/System/Network/interfaces/1/ipAddress' and not moved['to']:
                        for k, d in mock.S['devices'].items():
                            if d['serial'] == 'CAMSERIAL1' and k != '192.168.5.30':
                                moved['to'] = k
                    return r

            class Server(ThreadingHTTPServer):
                daemon_threads = True

                def handle_error(self, request, client_address):
                    pass

            server = Server(('127.0.0.1', 0), Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            slug = 'review-' + hashlib.sha256(b'review').hexdigest()[:8]
            (vault / ('site-' + slug + '.dat')).write_text('TEST:' + base64.b64encode(json.dumps(sec).encode()).decode())
            answers = case / 'answers.txt'
            answers.write_text('YES\nY\nYES\n')
            config = case / 'config.json'
            config.write_text(json.dumps({'fixSite': {'moveWaitSec': 1, 'rebootWaitSec': 1, 'verifyHoldSec': 0}}))
            command = [args.powershell, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(repo / 'Toolkit/FixSite.ps1'), '-Site', 'Review',
                       '-MockUrl', 'http://127.0.0.1:' + str(server.server_port), '-SecretsDir', str(vault),
                       '-RunsRoot', str(runs), '-SitesDir', str(case / 'sites'), '-Answers', str(answers), '-ConfigPath', str(config)]
            proc = None
            try:
                if mode == 'identity':
                    run = subprocess.run(command + extra, capture_output=True, text=True, timeout=90)
                    v = read_vault(vault)
                    results['identity_exit'] = run.returncode
                    results['identity_saved_a_kept'] = v.get('cams', {}).get('c4:2f:90:00:00:aa') == 'Apass999'
                    results['identity_b_own'] = v.get('cams', {}).get('c4:2f:90:00:00:bb') == 'Sitepass456'
                    results['identity_out'] = (run.stdout + run.stderr)[-1500:]
                elif mode == 'journal':
                    with open(case / 'forward.log', 'w') as log:
                        proc = subprocess.Popen(command + extra, stdout=log, stderr=subprocess.STDOUT)
                        end = time.time() + 30
                        while time.time() < end and not list(runs.glob('FixSite-*')):
                            time.sleep(0.05)
                        time.sleep(0.3)
                        for rd in list(runs.glob('FixSite-*')):
                            shutil.rmtree(rd, ignore_errors=True)   # the undo file cannot be written there any more
                        gate.set()
                        proc.wait(90)
                    d = mock.S['devices']['192.168.1.20']
                    results['journal_exit'] = proc.returncode
                    results['journal_password_untouched'] = d['password'] == 'Oldpass123' and not d.get('pw_changes')
                    results['journal_says_why'] = 'undo file could not be saved' in (case / 'forward.log').read_text(errors='replace')
                    results['journal_out'] = (case / 'forward.log').read_text(errors='replace')[-1500:]
                else:
                    with open(case / 'forward.log', 'w') as log:
                        proc = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
                        if not waiting.wait(60):
                            raise RuntimeError('The test did not reach the camera move: ' + (case / 'forward.log').read_text(errors='replace')[-3000:])
                        proc.kill()
                        proc.wait()
                        release.set()
                    rollback = next(runs.glob('*/rollback.json'))
                    journal = json.loads(rollback.read_text(encoding='utf-8-sig'))
                    cam = journal['cameras'][0]
                    results['move_new_address_recorded'] = moved['to'] in (cam.get('ip_after'), cam.get('ip_target'))
                    time.sleep(1.1)   # run folders have one-second names
                    undo = subprocess.run(command + ['-Mode', 'Rollback', '-RollbackDir', str(rollback.parent)], capture_output=True, text=True, timeout=90)
                    results['move_undo_exit'] = undo.returncode
                    results['move_undo_back'] = '192.168.5.30' in mock.S['devices'] and mock.S['devices']['192.168.5.30']['serial'] == 'CAMSERIAL1'
                    results['move_out'] = (undo.stdout + undo.stderr)[-1500:]
            finally:
                gate.set()
                release.set()
                if proc and proc.poll() is None:
                    proc.kill()
                    proc.wait()
                server.shutdown()
                server.server_close()
    print(json.dumps(results))


if __name__ == '__main__':
    main()
