"""2.2.7 regression scenarios against the real FixSite.ps1 entry point, on loopback only (mock_site.py devices).
   channel:  a run killed right after the NVR accepted a camera's channel change still leaves Undo that channel (F01).
   nvrmove:  a run killed while an NVR moves still lets Undo log in to it at its new address and move it back (F02).
   atomic:   an undo file rewrite that fails half-way never destroys the undo file already on disk (F03; Linux: file-size limit).
   settings: Undo puts back the I-frame interval and Smart Codec, and never says "everything is back" when a setting did not take (F09)."""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from http.server import ThreadingHTTPServer


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', required=True)
    ap.add_argument('--powershell', required=True)
    ap.add_argument('--only', default='')
    args = ap.parse_args()
    repo = Path(args.repo)
    spec = importlib.util.spec_from_file_location('mock_site', repo / 'Toolkit/tests/fixsite/mock_site.py')
    mock = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mock)
    results = {}
    modes = ['channel', 'nvrmove', 'atomic', 'settings']
    if args.only:
        modes = [m for m in modes if m in args.only.split(',')]
    with tempfile.TemporaryDirectory(prefix='fix227-') as tmp:
        root = Path(tmp)
        for mode in modes:
            if mode == 'atomic' and os.name == 'nt':
                results['atomic_skipped'] = 'Windows has no per-process file-size limit to stop a write half-way; runs on Linux'
                continue
            case = root / mode
            vault = case / 'vault'
            vault.mkdir(parents=True)
            runs = case / 'runs'
            pc = {'ip': '192.168.1.105', 'gw': '192.168.1.1', 'mask': '255.255.255.0', 'dhcp': True}
            sec = {'site': 'Review', 'password': 'Sitepass456', 'known': ['Oldpass123'], 'nvr': {}, 'cams': {},
                   'rollback': {}, 'bitwardenSaved': True, 'shownOnce': True}
            extra = []
            if mode == 'channel':
                devices = {'192.168.1.20': {'kind': 'nvr', 'brand': 'Hikvision', 'model': 'DS-7608NI-K2', 'serial': 'NVRSERIAL1',
                                            'mac': 'c4:2f:90:00:00:20', 'password': 'Sitepass456', 'https': True,
                                            'channels': {'1': {'ip': '192.168.1.21', 'password': 'Oldpass123', 'protocol': 'HIKVISION', 'name': 'Door'}}},
                           '192.168.1.21': {'kind': 'camera', 'brand': 'Hikvision', 'model': 'DS-2CD2143G2-I', 'serial': 'CAMSERIAL1',
                                            'mac': 'c4:2f:90:00:00:21', 'password': 'Oldpass123', 'https': True}}
                sec['nvr']['192.168.1.20'] = 'Sitepass456'
                extra = ['-PasswordAll']
            elif mode == 'nvrmove':
                devices = {'192.168.5.20': {'kind': 'nvr', 'brand': 'Hikvision', 'model': 'DS-7608NI-K2', 'serial': 'NVRSERIAL2',
                                            'mac': 'c4:2f:90:00:00:22', 'password': 'Sitepass456', 'https': True, 'channels': {}}}
                sec['nvr']['192.168.5.20'] = 'Sitepass456'
            elif mode == 'atomic':
                devices = {}
                for n in range(21, 27):
                    devices['192.168.1.%d' % n] = {'kind': 'camera', 'brand': 'Hikvision', 'model': 'DS-2CD2143G2-I', 'serial': 'CAMSER%04d' % n,
                                                   'mac': 'c4:2f:90:00:01:%02x' % n, 'password': 'Oldpass123', 'https': True}
                extra = ['-PasswordAll']
            else:
                devices = {'192.168.1.21': {'kind': 'camera', 'brand': 'Hikvision', 'model': 'DS-2CD2143G2-I', 'serial': 'CAMSERIAL9',
                                            'mac': 'c4:2f:90:00:00:29', 'password': 'Sitepass456', 'https': True,
                                            'stream': {'codec': 'H.264', 'fps': 12, 'width': 2688, 'height': 1520, 'bitrate': 4096, 'gop': 12, 'smart': 'off', 'maxw': 2688, 'maxh': 1520}}}
            scene_file = case / 'scene.json'
            scene_file.write_text(json.dumps({'pc': pc, 'devices': devices}))
            mock.load(scene_file)
            waiting, release = threading.Event(), threading.Event()
            moved = {'to': ''}

            class Handler(mock.H):
                def send(self, *a, **k):
                    try:
                        return super().send(*a, **k)
                    except (BrokenPipeError, ConnectionResetError):
                        pass

                def route(self, method, ip, path, q, body, rawq):
                    if mode == 'nvrmove' and moved['to'] and ip == moved['to'] and method == 'GET' and not release.is_set():
                        waiting.set()
                        release.wait(20)
                    if mode == 'settings' and method == 'PUT' and path == '/ISAPI/Streaming/channels/101':
                        d = mock.S['devices'].get(ip)
                        keep = d['stream']['gop'] if d else None
                        r = super().route(method, ip, path, q, body, rawq)
                        if d:
                            d['stream']['gop'] = keep   # this camera accepts the write but keeps its I-frame interval
                        return r
                    r = super().route(method, ip, path, q, body, rawq)
                    if mode == 'channel' and method == 'PUT' and re.match(r'^/ISAPI/ContentMgmt/InputProxy/channels/\d+$', path) and not release.is_set():
                        waiting.set()          # the NVR took the change; the run is stopped before it hears the answer
                        release.wait(20)
                    if mode == 'nvrmove' and method == 'PUT' and path == '/ISAPI/System/Network/interfaces/1/ipAddress' and not moved['to']:
                        for k, d in mock.S['devices'].items():
                            if d['serial'] == 'NVRSERIAL2' and k != '192.168.5.20':
                                moved['to'] = k
                    return r

            class Server(ThreadingHTTPServer):
                daemon_threads = True

                def handle_error(self, request, client_address):
                    pass

            server = Server(('127.0.0.1', 0), Handler)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            slug = 'review-' + hashlib.sha256(b'review').hexdigest()[:8]
            answers = case / 'answers.txt'
            answers.write_text('N\nYES\nYES\n' if mode == 'nvrmove' else 'YES\nY\nYES\n')
            undo_answers = case / 'undo-answers.txt'
            undo_answers.write_text('YES\n')
            config = case / 'config.json'
            config.write_text(json.dumps({'fixSite': {'moveWaitSec': 1, 'rebootWaitSec': 1, 'verifyHoldSec': 0}}))
            command = [args.powershell, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(repo / 'Toolkit/FixSite.ps1'), '-Site', 'Review',
                       '-MockUrl', 'http://127.0.0.1:' + str(server.server_port), '-SecretsDir', str(vault),
                       '-RunsRoot', str(runs), '-SitesDir', str(case / 'sites'), '-Answers', str(answers), '-ConfigPath', str(config)]
            if mode == 'settings':
                run_name = '20261108-120000'
                rd = runs / ('FixSite-' + run_name)
                rd.mkdir(parents=True)
                (rd / 'rollback.json').write_text(json.dumps({'run': run_name, 'site': 'Review', 'taken_on': 'TEST', 'nvrs': [], 'nvr_passwords': [], 'cameras': [
                    {'name': 'Door', 'mac': 'c4:2f:90:00:00:29', 'brand': 'Hikvision', 'ip_before': '192.168.1.21', 'ip_after': '', 'net_before': None,
                     'stream_before': {'codec': 'H.264', 'fps': 12, 'width': 2688, 'height': 1520, 'bitrate': 4096, 'gop': 30, 'smartCodec': 'on'},
                     'password_changed': False, 'nvr': None, 'backup': ''}]}))
                sec['rollback'][run_name] = {}
            (vault / ('site-' + slug + '.dat')).write_text('TEST:' + base64.b64encode(json.dumps(sec).encode()).decode())
            proc = None
            try:
                if mode in ('channel', 'nvrmove'):
                    with open(case / 'forward.log', 'w') as log:
                        proc = subprocess.Popen(command + extra, stdout=log, stderr=subprocess.STDOUT)
                        if not waiting.wait(90):
                            raise RuntimeError('The test did not reach the change it stops at: ' + (case / 'forward.log').read_text(errors='replace')[-3000:])
                        proc.kill()
                        proc.wait()
                        release.set()
                    rollback = next(runs.glob('FixSite-*/rollback.json'))
                    time.sleep(1.1)   # run folders have one-second names
                    ucmd = [x if x != str(answers) else str(undo_answers) for x in command]
                    undo = subprocess.run(ucmd + ['-Mode', 'Rollback', '-RollbackDir', str(rollback.parent)], capture_output=True, text=True, timeout=120)
                    out = (undo.stdout + undo.stderr)
                    results[mode + '_undo_exit'] = undo.returncode
                    results[mode + '_out'] = out[-2000:]
                    if mode == 'channel':
                        nvr = mock.S['devices']['192.168.1.20']
                        cam = mock.S['devices'].get('192.168.1.21')
                        ch = nvr['channels'].get('1')
                        results['channel_cam_old_pw'] = bool(cam and cam['password'] == 'Oldpass123')
                        results['channel_video_back'] = bool(ch and mock.camera_online(nvr, ch))
                        results['channel_said_all_back'] = 'everything is back' in out
                        results['channel_undone_file'] = (rollback.parent / 'undone.txt').exists()
                    else:
                        results['nvrmove_back'] = '192.168.5.20' in mock.S['devices'] and mock.S['devices']['192.168.5.20']['serial'] == 'NVRSERIAL2'
                        results['nvrmove_no_login_msg'] = 'no saved login' in out
                elif mode == 'atomic':
                    import resource
                    state = {'size': 0}

                    def limit():
                        import signal
                        signal.signal(signal.SIGXFSZ, signal.SIG_IGN)   # a write past the limit fails (EFBIG) instead of killing the process
                        resource.setrlimit(resource.RLIMIT_FSIZE, (state['size'], state['size']))
                    # the first undo file of this run is small; later ones grow past the limit as cameras are added
                    state['size'] = 2600
                    env = dict(os.environ)
                    env['HOME'] = str(case / 'home')
                    (case / 'home').mkdir()
                    # 2.2.20: the run's scan.json and plan.json are now checked records that stop a Fix run when they cannot be saved whole,
                    # and both are bigger than this limit; so the limit is put on the running process (prlimit) only once its plan.json is
                    # saved - the undo file's later rewrites are what it stops half-way, as before
                    state['size'] = 10 ** 9
                    proc = subprocess.Popen(command + extra, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, preexec_fn=limit, env=env)
                    end = time.time() + 120
                    while time.time() < end and proc.poll() is None and not list(runs.glob('FixSite-*/plan.json')):
                        time.sleep(0.01)
                    if proc.poll() is None:
                        resource.prlimit(proc.pid, resource.RLIMIT_FSIZE, (2600, 2600))
                    so, _ = proc.communicate(timeout=180)

                    class _R: pass
                    run = _R(); run.returncode = proc.returncode; run.stdout = so or ''; run.stderr = ''
                    results['atomic_exit'] = run.returncode
                    rbs = list(runs.glob('FixSite-*/rollback.json'))
                    ok = False
                    size = -1
                    if rbs:
                        t = rbs[0].read_bytes()
                        size = len(t)
                        try:
                            json.loads(t.decode('utf-8-sig'))
                            ok = True
                        except Exception:
                            ok = False
                    results['atomic_journal_valid'] = ok
                    results['atomic_journal_size'] = size
                    results['atomic_left_tmp'] = [p.name for p in runs.glob('FixSite-*/rollback.json.*')]
                    results['atomic_out'] = (run.stdout + run.stderr)[-1500:]
                else:
                    rd = runs / 'FixSite-20261108-120000'
                    undo = subprocess.run(command + ['-Mode', 'Rollback', '-RollbackDir', str(rd)], capture_output=True, text=True, timeout=120)
                    s = mock.S['devices']['192.168.1.21']['stream']
                    results['settings_undo_exit'] = undo.returncode
                    results['settings_smart_back'] = s['smart'] == 'on'
                    results['settings_gop_now'] = s['gop']
                    results['settings_undone_file'] = (rd / 'undone.txt').exists()
                    results['settings_out'] = (undo.stdout + undo.stderr)[-2000:]
            except Exception as e:
                results[mode + '_error'] = str(e)[-3000:]
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
