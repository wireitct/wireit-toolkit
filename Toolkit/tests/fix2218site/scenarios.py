"""scenarios.py - WireIt Toolkit 2.2.18, Fix this site: Codex's review of 2.2.17 (head c3c0c69), findings 2 and 3, as real runs.
   The REAL FixSite.ps1 (Undo = -Mode Rollback, and forward Fix runs) against the repository's mock devices (fixsite/mock_site.py,
   loopback only). Every mode runs twice through the real entry point (Undo pressed again / Fix this site pressed again).
   Finding 2 - channel Undo (the selected camera is .50; NVR .19 ch 1):
     addedother:   the run ADDED ch 1 for .50; ch 1 now shows a different working camera .51. Undo must NOT delete it.
     updatedother: the run UPDATED ch 1 (saved copy names .50); ch 1 now shows .51. Undo must NOT put .50 back on it.
     addedunread:  the run ADDED ch 1; the NVR answers HTTP 500 for that channel now. Undo must not delete what it cannot read.
     addedmine / updatedmine: controls - ch 1 still shows .50: Undo deletes it / puts the saved copy back, "everything is back", exit 0.
     nocopysticky: twin (F3 pattern): the run moved the camera .50 -> .60 and updated ch 1 with no saved copy; Undo points ch 1 back at .50,
                   the NVR ACKNOWLEDGES and keeps .60: NOT back, Undo incomplete.   nocopyok: control: the NVR takes it, exit 0.
   Finding 3 - network read-back:
     netsticky:    NVR .19 has router .254, the PC's router is .1: Fix this site corrects it in place; the NVR ACKNOWLEDGES the PUT and keeps
                   router .254. Must NOT say "network settings fixed": NOT fixed, the router named, Still a problem, nonzero exit.
     netok:        control: the same, the NVR takes it: "network settings fixed", exit 0.
     camsticky:    twin: camera on the wrong scheme (192.168.0.150) is moved; it takes the new address but keeps router 192.168.0.1:
                   NOT confirmed, Still a problem, nonzero exit.
     undonetsticky: Undo of an in-place NVR network fix (saved: router .254). The NVR acknowledges and keeps router .1: Undo incomplete.
     undonetok:    control: the NVR takes it: "everything is back", exit 0.
   Usage: python3 scenarios.py --repo <repo root> --powershell <pwsh> [--only a,b]   Prints PASS / FAIL lines and "N passed, M failed"."""
import argparse, base64, hashlib, importlib.util, json, os, re, subprocess, sys, tempfile, threading
from pathlib import Path
from http.server import ThreadingHTTPServer

M50 = 'c4:2f:90:00:01:50'; M51 = 'c4:2f:90:00:01:51'; M19 = 'c4:2f:90:00:00:19'
PASS = 0; FAIL = 0
MODES = ['addedother', 'updatedother', 'addedunread', 'addedmine', 'updatedmine', 'nocopysticky', 'nocopyok', 'netsticky', 'netok', 'camsticky', 'undonetsticky', 'undonetok']


def check(what, ok, more=''):
    global PASS, FAIL
    if ok: PASS += 1; print('PASS ' + what)
    else:
        FAIL += 1; print('FAIL ' + what)
        if more: print('     ' + more.replace('\n', '\n     ')[-1500:])
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
    ap.add_argument('--repo', required=True); ap.add_argument('--powershell', required=True); ap.add_argument('--only', default='')
    args = ap.parse_args(); repo = Path(args.repo); here = Path(__file__).resolve().parent
    # the mock devices come from THIS checkout's tests (the code under test comes from --repo), so an older checkout runs the same devices
    spec = importlib.util.spec_from_file_location('mock_site', here.parent / 'fixsite' / 'mock_site.py')
    mock = importlib.util.module_from_spec(spec); spec.loader.exec_module(mock)
    modes = MODES
    if args.only: modes = [x for x in modes if x in args.only.split(',')]
    results = {}
    with tempfile.TemporaryDirectory(prefix='fix2218site-') as tmp:
        for mode in modes:
            case = Path(tmp) / mode; vault = case / 'vault'; vault.mkdir(parents=True); runs = case / 'runs'
            pc = {'ip': '192.168.1.105', 'gw': '192.168.1.1', 'mask': '255.255.255.0', 'dhcp': True}
            sec = {'site': 'Review', 'password': 'Sitepass456', 'known': [], 'nvr': {'192.168.1.19': 'Sitepass456'},
                   'cams': {M50: 'Sitepass456'}, 'rollback': {'review-before': {}}, 'bitwardenSaved': True, 'shownOnce': True}
            undo = mode.startswith(('added', 'updated', 'undo', 'nocopy'))
            lcams = [{'name': 'Gate', 'mac': M50, 'ip': '192.168.1.50', 'nvr': '192.168.1.19', 'channel': 1}]
            lnvrs = [{'brand': 'Hikvision', 'mac': M19, 'ip': '192.168.1.19'}]
            nvr_net = {'ip': '192.168.1.19', 'mask': '255.255.255.0', 'gw': '192.168.1.1', 'dhcp': False, 'dns1': '8.8.8.8', 'dns2': ''}
            camip = '192.168.1.60' if mode.startswith('nocopy') else '192.168.1.50'
            if mode in ('netsticky', 'netok'): nvr_net['gw'] = '192.168.1.254'
            if mode == 'camsticky': camip = '192.168.0.150'
            chip = '192.168.1.51' if mode in ('addedother', 'updatedother') else camip
            devices = {camip: cam('CAMSER150', M50, 'Sitepass456'),
                       '192.168.1.19': nvr('NVRSER19', M19, {'1': ch(chip, 'Sitepass456', 'Gate')}, net=nvr_net)}
            if mode in ('addedother', 'updatedother'): devices['192.168.1.51'] = cam('CAMSER151', M51, 'Sitepass456')
            site_list = {'site': 'Review', 'scheme': '192.168.1', 'nvrs': lnvrs, 'cameras': lcams}
            scene = case / 'scene.json'; scene.write_text(json.dumps({'pc': pc, 'devices': devices})); mock.load(scene)
            ctl = {'writes': []}
            sticky = {'netsticky': M19, 'camsticky': M50, 'undonetsticky': M19}.get(mode)

            class Handler(mock.H):
                def send(self, *a, **k):
                    try: return super().send(*a, **k)
                    except (BrokenPipeError, ConnectionResetError): pass

                def route(self, method, ip, path, q, body, rawq):
                    if method in ('PUT', 'POST', 'DELETE'): ctl['writes'].append({'ip': ip, 'method': method, 'path': path})
                    if mode == 'addedunread' and ip == '192.168.1.19' and re.match(r'^/ISAPI/ContentMgmt/InputProxy/channels/1$', path) and method == 'GET':
                        return self.send(500, 'busy')
                    if mode == 'nocopysticky' and ip == '192.168.1.19' and method == 'PUT' and path == '/ISAPI/ContentMgmt/InputProxy/channels/1':
                        return self.send(200, '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>', 'application/xml')   # acknowledged, not applied
                    if sticky and method == 'PUT' and path.endswith('/ipAddress'):
                        d = mock.S['devices'].get(ip); oldgw = d['net']['gw'] if d else None
                        r = super().route(method, ip, path, q, body, rawq)
                        for v in mock.S['devices'].values():
                            if v.get('mac') == sticky and oldgw is not None: v['net']['gw'] = oldgw   # acknowledged, but the router did not change
                        return r
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
            base = [args.powershell, '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(repo / 'Toolkit/FixSite.ps1'), '-Site', 'Review', '-MockUrl', 'http://127.0.0.1:' + str(server.server_port),
                    '-SecretsDir', str(vault), '-RunsRoot', str(runs), '-SitesDir', str(case / 'sites'), '-Answers', str(answers), '-ConfigPath', str(config)]
            if undo:
                rb = case / 'original-run'; (rb / 'backup').mkdir(parents=True)
                cams = []; nvrs = []
                if not mode.startswith('undo'):
                    action = 'added' if mode.startswith('added') else 'updated'
                    bf = ''
                    if action == 'updated' and not mode.startswith('nocopy'):
                        bf = 'backup/nvr-192.168.1.19-ch1.xml'
                        (rb / bf).write_text(mock.H.chxml(None, '1', {'ip': '192.168.1.50', 'protocol': 'HIKVISION', 'name': 'Gate'}))
                    cams = [{'name': 'Gate', 'mac': M50, 'serial': 'CAMSER150', 'brand': 'Hikvision', 'ip_before': '192.168.1.50', 'ip_after': '192.168.1.60' if mode.startswith('nocopy') else '',
                             'net_before': None if mode.startswith('nocopy') else {'ip': '192.168.1.50', 'mask': '255.255.255.0', 'gw': '192.168.1.1', 'dhcp': False, 'dns1': '8.8.8.8', 'dns2': ''},
                             'stream_before': None, 'password_changed': False,
                             'nvr': {'nvr': '192.168.1.19', 'channel': 1, 'action': action, 'before_file': bf, 'nvr_mac': M19, 'nvr_serial': 'NVRSER19'}}]
                else:
                    mock.S['devices']['192.168.1.19']['net']['gw'] = '192.168.1.1'   # the run set router .1 in place; the saved settings have .254
                    nvrs = [{'ip': '192.168.1.19', 'target': '192.168.1.19', 'mac': M19, 'serial': 'NVRSER19', 'iface': '1',
                             'old': {'ip': '192.168.1.19', 'mask': '255.255.255.0', 'gw': '192.168.1.254', 'dhcp': False, 'dns1': '8.8.8.8', 'dns2': ''}}]
                (rb / 'rollback.json').write_text(json.dumps({'run': 'review-before', 'site': 'Review', 'scheme': '192.168.1', 'taken_on': 'test', 'cameras': cams, 'nvrs': nvrs}))
                answers.write_text('YES\n'); cmd = base + ['-Mode', 'Rollback', '-RollbackDir', str(rb)]
            else:
                answers.write_text('N\nYES\nY\nYES\n'); cmd = base + ['-ListFile', str(lf)]
            for run in (1, 2):
                ctl['writes'] = []
                try:
                    p = subprocess.run(cmd, capture_output=True, text=True, timeout=200); out, code = p.stdout + p.stderr, p.returncode
                except subprocess.TimeoutExpired as e:
                    out, code = 'TIMEOUT ' + str(e.stdout or ''), -9
                if os.environ.get('REPRO_DEBUG'): print(out[-5000:])
                S = mock.S
                n19 = next((v for v in S['devices'].values() if v.get('mac') == M19), {})
                ch1 = (n19.get('channels') or {}).get('1')
                c50ip = next((k for k, v in S['devices'].items() if v.get('mac') == M50), '')
                c50 = S['devices'].get(c50ip) or {}
                chw = [w for w in ctl['writes'] if w['ip'] == '192.168.1.19' and '/InputProxy/channels' in w['path']]
                m = re.search(r'Still a problem:\s*(\d+)', out)
                r = {'exit': code, 'ch1': ch1['ip'] if ch1 else None, 'ch1_online': bool(mock.camera_online(n19, ch1)) if ch1 else False, 'chwrites': chw,
                     'nvrgw': (n19.get('net') or {}).get('gw'), 'camip': c50ip, 'camgw': (c50.get('net') or {}).get('gw'),
                     'problems': int(m.group(1)) if m else -1, 'allback': bool(re.search(r'everything is back', out)),
                     'fixedwords': bool(re.search(r'network settings fixed', out)), 'notfixed': bool(re.search(r'NOT (fixed|confirmed|back)', out)),
                     'namesgw': bool(re.search(r'router \(gateway\) is 192\.168\.\d+\.\d+, not', out)), 'another': bool(re.search(r'ANOTHER camera', out)),
                     'incomplete': (rb / 'undo-incomplete.txt').exists() if undo else None, 'out': out[-3000:]}
                results['%s%d' % (mode, run)] = r
                tag = '%s run %d: ' % (mode, run); o = r['out']
                if mode in ('addedother', 'updatedother'):
                    check(tag + 'Undo leaves NVR ch 1 alone: nothing written to the channel, it still shows the other working camera .51 with video', not chw and r['ch1'] == '192.168.1.51' and r['ch1_online'], json.dumps(chw) + ' ch1=' + str(r['ch1']) + '\n' + o)
                    check(tag + 'Undo is reported incomplete: never "everything is back", nonzero exit, the other camera named', not r['allback'] and code != 0 and r['another'] and r['incomplete'], 'exit=%s\n%s' % (code, o))
                elif mode == 'addedunread':
                    check(tag + 'Undo does not delete a channel it could not read (HTTP 500): no DELETE, ch 1 kept', not [w for w in chw if w['method'] == 'DELETE'] and r['ch1'] == camip, json.dumps(chw) + '\n' + o)
                    check(tag + 'Undo is reported incomplete, nonzero exit', not r['allback'] and code != 0, 'exit=%s\n%s' % (code, o))
                elif mode == 'addedmine':
                    if run == 1:
                        check(tag + 'control: ch 1 still shows this camera: Undo deletes it, "everything is back", exit 0', r['ch1'] is None and r['allback'] and code == 0 and any(w['method'] == 'DELETE' for w in chw), 'exit=%s\n%s' % (code, o))
                    else: check(tag + 'control: Undo again: nothing left to do, exit 0', r['ch1'] is None and code == 0 and not chw, 'exit=%s\n%s' % (code, o))
                elif mode == 'updatedmine':
                    if run == 1:
                        check(tag + 'control: ch 1 still shows this camera: the saved channel goes back, video back, "everything is back", exit 0', r['ch1'] == '192.168.1.50' and r['ch1_online'] and r['allback'] and code == 0 and any(w['method'] == 'PUT' for w in chw), 'exit=%s\n%s' % (code, o))
                    else: check(tag + 'control: Undo again: nothing left to do, exit 0', r['ch1'] == '192.168.1.50' and code == 0 and not chw, 'exit=%s\n%s' % (code, o))
                elif mode == 'nocopysticky':
                    check(tag + 'twin: Undo of a channel with no saved copy: the NVR acknowledged .50 but still reads .60: NOT back, never "everything is back", nonzero exit', r['ch1'] == '192.168.1.60' and not r['allback'] and code != 0 and r['incomplete'], 'exit=%s ch1=%s\n%s' % (code, r['ch1'], o))
                elif mode == 'nocopyok':
                    if run == 1: check(tag + 'control: no saved copy, the NVR takes ch 1 -> .50 and reads it back: "everything is back", exit 0', r['ch1'] == '192.168.1.50' and r['allback'] and code == 0, 'exit=%s ch1=%s\n%s' % (code, r['ch1'], o))
                    else: check(tag + 'control: Undo again: nothing left, exit 0', r['ch1'] == '192.168.1.50' and code == 0, 'exit=%s\n%s' % (code, o))
                elif mode == 'netsticky':
                    check(tag + 'the NVR kept router .254 after acknowledging .1: never "network settings fixed"', not r['fixedwords'] and r['nvrgw'] == '192.168.1.254', 'gw=%s\n%s' % (r['nvrgw'], o))
                    check(tag + 'NOT fixed, the router named, Still a problem >= 1, nonzero exit', r['notfixed'] and r['namesgw'] and r['problems'] >= 1 and code != 0, 'exit=%s problems=%s\n%s' % (code, r['problems'], o))
                elif mode == 'netok':
                    if run == 1: check(tag + 'control: the NVR takes router .1: "network settings fixed", Still a problem 0, exit 0', r['fixedwords'] and r['nvrgw'] == '192.168.1.1' and r['problems'] == 0 and code == 0, 'exit=%s problems=%s gw=%s\n%s' % (code, r['problems'], r['nvrgw'], o))
                    else: check(tag + 'control: second run: nothing to fix there, exit 0', r['nvrgw'] == '192.168.1.1' and code == 0, 'exit=%s\n%s' % (code, o))
                elif mode == 'camsticky':
                    if run == 1:
                        check(tag + 'twin: camera moved but kept router 192.168.0.1: NOT confirmed, router named, Still a problem >= 1, nonzero exit', r['camip'].startswith('192.168.1.') and r['camgw'] == '192.168.0.1' and r['notfixed'] and r['namesgw'] and r['problems'] >= 1 and code != 0, 'exit=%s camip=%s gw=%s\n%s' % (code, r['camip'], r['camgw'], o))
                elif mode == 'undonetsticky':
                    check(tag + 'Undo: the NVR acknowledged router .254 but kept .1: NOT back, router named, never "everything is back", nonzero exit', r['nvrgw'] == '192.168.1.1' and not r['allback'] and r['namesgw'] and code != 0 and r['incomplete'], 'exit=%s gw=%s\n%s' % (code, r['nvrgw'], o))
                elif mode == 'undonetok':
                    if run == 1: check(tag + 'control: Undo puts router .254 back and reads it back: "everything is back", exit 0', r['nvrgw'] == '192.168.1.254' and r['allback'] and code == 0, 'exit=%s gw=%s\n%s' % (code, r['nvrgw'], o))
                    else: check(tag + 'control: Undo again: nothing left, exit 0', r['nvrgw'] == '192.168.1.254' and code == 0, 'exit=%s\n%s' % (code, o))
            server.shutdown()
    print('REPRO=' + json.dumps({k: {kk: vv for kk, vv in v.items() if kk != 'out'} for k, v in results.items()}))
    print('%d passed, %d failed' % (PASS, FAIL))
    sys.exit(0 if FAIL == 0 else 1)


if __name__ == '__main__':
    main()
