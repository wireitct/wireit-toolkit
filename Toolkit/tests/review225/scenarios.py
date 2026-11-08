"""Regression scenarios against the real FixSite/ScanUpload entry points, on loopback only."""
import argparse
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer


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

    with tempfile.TemporaryDirectory(prefix='review225-') as tmp:
        root = Path(tmp)
        for mode in ['retarget', 'interrupt', 'interrupt-nvr']:
            case = root / mode
            vault = case / 'vault'
            vault.mkdir(parents=True)
            cam = {'kind': 'camera', 'brand': 'Hikvision', 'model': 'DS-2CD2143G2-I', 'serial': 'CAMSERIAL1',
                   'mac': 'c4:2f:90:00:00:21', 'password': 'Oldpass123', 'https': True}
            scene = {'pc': {'ip': '192.168.1.105', 'gw': '192.168.1.1', 'mask': '255.255.255.0', 'dhcp': True},
                     'devices': {'192.168.1.21': cam}}
            if mode == 'retarget':
                scene['devices']['192.168.0.20'] = {'kind': 'nvr', 'brand': 'Hikvision', 'model': 'DS-7608NI-K2',
                    'serial': 'NVRSERIAL1', 'mac': 'c4:2f:90:00:00:20', 'password': 'Oldpass123', 'https': True,
                    'channels': {'1': {'ip': '192.168.1.21', 'password': 'Oldpass123', 'protocol': 'HIKVISION', 'name': 'Front'}}}
            if mode == 'interrupt-nvr':
                scene['devices'] = {'192.168.1.20': {'kind': 'nvr', 'brand': 'Hikvision', 'model': 'DS-7608NI-K2',
                    'serial': 'NVRSERIAL1', 'mac': 'c4:2f:90:00:00:20', 'password': 'Oldpass123', 'https': True, 'channels': {}}}
            scene_file = case / 'scene.json'
            scene_file.write_text(json.dumps(scene))
            mock.load(scene_file)
            waiting, release = threading.Event(), threading.Event()
            class Handler(mock.H):
                def send(self, *args, **kwargs):
                    try:
                        return super().send(*args, **kwargs)
                    except (BrokenPipeError, ConnectionResetError):
                        pass  # The interrupted client no longer receives the pending login reply.
                def pc(self, method, path, q, body):
                    if mode == 'retarget' and path == '/free' and q['ip'] == '192.168.1.20':
                        return self.send(200, 'false')
                    return super().pc(method, path, q, body)
                def route(self, method, ip, path, q, body, rawq):
                    d = mock.S['devices'].get(ip)
                    if mode.startswith('interrupt') and d and d.get('pw_changes') and method == 'GET' and path == '/ISAPI/System/deviceInfo' and not release.is_set():
                        waiting.set()
                        release.wait(20)
                    return super().route(method, ip, path, q, body, rawq)
            class Server(ThreadingHTTPServer):
                daemon_threads = True
                def handle_error(self, request, client_address):
                    pass  # Killing the test client deliberately closes one socket before its reply.
            server = Server(('127.0.0.1', 0), Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            sec = {'site': 'Review', 'password': 'Sitepass456', 'known': ['Oldpass123'], 'nvr': {}, 'cams': {},
                   'rollback': {}, 'bitwardenSaved': False, 'shownOnce': False}
            if mode == 'retarget':
                sec['nvr']['192.168.0.20'] = 'Oldpass123'
            if mode == 'interrupt-nvr':
                sec['nvr']['192.168.1.20'] = 'Oldpass123'
            slug = 'review-' + hashlib.sha256(b'review').hexdigest()[:8]
            (vault / ('site-' + slug + '.dat')).write_text('TEST:' + base64.b64encode(json.dumps(sec).encode()).decode())
            answers = case / 'answers.txt'
            answers.write_text('YES\nY\n')
            config = case / 'config.json'
            config.write_text(json.dumps({'fixSite': {'moveWaitSec': 1, 'rebootWaitSec': 1, 'verifyHoldSec': 0}}))
            command = [args.powershell, '-NoProfile', '-File', str(repo / 'Toolkit/FixSite.ps1'), '-Site', 'Review',
                       '-MockUrl', 'http://127.0.0.1:' + str(server.server_port), '-SecretsDir', str(vault),
                       '-RunsRoot', str(case / 'runs'), '-SitesDir', str(case / 'sites'), '-Answers', str(answers), '-ConfigPath', str(config)]
            proc = None
            try:
                if mode == 'retarget':
                    run = subprocess.run(command + ['-PasswordAll'], capture_output=True, text=True, timeout=60)
                    if run.returncode:
                        raise RuntimeError(run.stdout + run.stderr)
                    site = json.loads(next((case / 'sites').glob('*.json')).read_text(encoding='utf-8-sig'))
                    results['retarget_exit'] = run.returncode
                    results['retarget_camera_password'] = mock.S['devices']['192.168.1.21']['password'] == 'Sitepass456'
                    results['retarget_channel_password'] = mock.S['devices']['192.168.1.19']['channels']['1']['password'] == 'Sitepass456'
                    results['retarget_saved_nvr'] = site['cameras'][0]['nvr'] == '192.168.1.19'
                else:
                    with open(case / 'forward.log', 'w') as log:
                        proc = subprocess.Popen(command + ['-PasswordAll'], stdout=log, stderr=subprocess.STDOUT)
                        if not waiting.wait(30):
                            raise RuntimeError('The test did not reach the password write: ' + (case / 'forward.log').read_text())
                        proc.kill()
                        proc.wait()
                        release.set()
                    rollback = next((case / 'runs').glob('*/rollback.json'))
                    journal = json.loads(rollback.read_text(encoding='utf-8-sig'))
                    is_nvr = mode == 'interrupt-nvr'
                    prefix = 'nvr_' if is_nvr else ''
                    recorded = journal['nvr_passwords' if is_nvr else 'cameras'][0]
                    results[prefix + 'interrupted_attempt_only'] = (recorded['attempted'] and not recorded['changed']) if is_nvr else (recorded['password_attempted'] and not recorded['password_changed'])
                    time.sleep(1.1)  # Run directory names have one-second precision.
                    undo = subprocess.run(command + ['-Mode', 'Rollback', '-RollbackDir', str(rollback.parent)], capture_output=True, text=True, timeout=30)
                    results[prefix + 'undo_exit'] = undo.returncode
                    results[prefix + 'undo_restored_password'] = mock.S['devices']['192.168.1.20' if is_nvr else '192.168.1.21']['password'] == 'Oldpass123'
                    results[prefix + 'undo_marker'] = (rollback.parent / 'undone.txt').exists()
                    if undo.returncode:
                        raise RuntimeError(undo.stdout + undo.stderr)
            finally:
                release.set()
                if proc and proc.poll() is None:
                    proc.kill()
                    proc.wait()
                server.shutdown()
                server.server_close()
    print(json.dumps(results))


if __name__ == '__main__':
    main()
