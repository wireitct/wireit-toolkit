"""scenarios.py - WireIt Toolkit 2.2.19, Fix this site: Codex's review of 2.2.18 (head a7ceac8), the "site" findings as real runs.
   The REAL FixSite.ps1 (Undo = -Mode Rollback, and forward Fix runs) of --repo against THIS checkout's mock devices
   (tests/fixsite/mock_site.py, loopback only), so the same devices run against 2.2.18 and 2.2.19. Every mode runs twice.
   Camera Gate = MAC ...:50 (site password Sitepass456), NVR = MAC ...:19 on .19, its channel 1 is the camera's.
   F01 channel Undo identity:
     chother:  the run ADDED ch 1 while moving Gate .50 -> .60; ch 1 now shows .50, where ANOTHER camera (other password) answers.
               Undo must not delete ch 1; incomplete, nonzero exit, the other camera named.
     chsaved:  the run UPDATED ch 1 (saved copy names .50) and moved Gate .50 -> .60; ch 1 shows .50, where ANOTHER camera on the SAME
               site password answers (the "saved original address" path). Undo writes nothing to ch 1 and does not move Gate onto .50.
     chmine:   control: ch 1 (added) still shows Gate on .50: Undo deletes it, "everything is back", exit 0.
   F02 Undo onto an occupied address:
     occnvr:   the run moved the NVR .29 -> .19; .29 is now held by another camera. Undo must not move the NVR onto it.
     occnvrfree: control: .29 is free: the NVR goes back to .29, "everything is back", exit 0.
     movefree: control: Gate moved .50 -> .60, .50 is free: it goes back to .50, "everything is back", exit 0.
     (chsaved is the camera twin: .50 taken by another camera.)
   F13 DHCP Undo:
     dhcpnvr:  Undo of an in-place NVR change (saved: DHCP). The NVR acknowledges DHCP and stays on a fixed address: NOT back.
     dhcpgone: the NVR takes DHCP and is no longer found by its MAC anywhere: NOT CHECKED, never "everything is back".
     dhcpnvrok: control: the NVR takes DHCP and is found by its MAC: "everything is back", exit 0.
     dhcpcam / dhcpcamok: the camera twin (saved: DHCP on the same address .50).
   F03 forward replacement NVR:
     fwdswap:  NVR .19 has router .254; Fix this site corrects it in place; the NVR at .19 is swapped for ANOTHER NVR after the scan
               (on the backup read). Nothing may be written to the other NVR; never "network settings fixed"; nonzero exit (run 1 only:
               a second run starts with the other NVR in the scan, so fixing it then is right).
     fwdok:    control: no swap: "network settings fixed", exit 0.
   F19 forward stream fields:
     streamgap: H.264 / 15 fps asked for every camera; the camera's stream answer has no codec and no SmartCodec. Never "settings already right", nothing written to the
               stream, "NOT CHECKED", nonzero exit.
   Power-cycle (PoE) MAC check (decision for 2.2.19):
     poeright: Gate is missing, its switch port is power-cycled, Gate (its MAC) answers again on .50: "answers again", exit 0.
     poewrong: after the power-cycle ANOTHER camera on the site password answers on .50: NOT confirmed, never "answers again".
     poewrongch: the same with Gate on NVR ch 1: nothing written to ch 1.
     poenvr:   Gate answers again, but the NVR at .19 was swapped for another NVR: nothing written to ch 1.
   Usage: python3 scenarios.py --repo <repo root> --powershell <pwsh> [--only a,b]   Prints PASS / FAIL lines and "N passed, M failed"."""
import argparse, base64, hashlib, importlib.util, json, os, re, subprocess, sys, tempfile, threading
from pathlib import Path
from http.server import ThreadingHTTPServer

M50 = 'c4:2f:90:00:01:50'; M51 = 'c4:2f:90:00:01:51'; M19 = 'c4:2f:90:00:00:19'; M99 = 'c4:2f:90:00:00:99'
PASS = 0; FAIL = 0
MODES = ['chother', 'chsaved', 'chmine', 'occnvr', 'occnvrfree', 'movefree', 'dhcpnvr', 'dhcpgone', 'dhcpnvrok', 'dhcpcam', 'dhcpcamok',
         'fwdswap', 'fwdok', 'streamgap', 'poeright', 'poewrong', 'poewrongch', 'poenvr']
STATIC50 = {'ip': '192.168.1.50', 'mask': '255.255.255.0', 'gw': '192.168.1.1', 'dhcp': False, 'dns1': '8.8.8.8', 'dns2': ''}


def check(what, ok, more=''):
    global PASS, FAIL
    if ok: PASS += 1; print('PASS ' + what)
    else:
        FAIL += 1; print('FAIL ' + what)
        if more: print('     ' + more.replace('\n', '\n     ')[-2500:])
    sys.stdout.flush()


def cam(serial, mac, pw, **kw):
    d = {'kind': 'camera', 'brand': 'Hikvision', 'model': 'DS-2CD2143G2-I', 'serial': serial, 'mac': mac, 'password': pw, 'https': True}
    d.update(kw); return d


def nvr(serial, mac, chans, **kw):
    d = {'kind': 'nvr', 'brand': 'Hikvision', 'model': 'DS-7608NI-K2', 'serial': serial, 'mac': mac, 'password': 'Sitepass456', 'https': True, 'channels': chans}
    d.update(kw); return d


def ch(ip, pw, name='Gate'):
    return {'ip': ip, 'password': pw, 'protocol': 'HIKVISION', 'name': name}


def mkdev(d, ip):
    # a device added while a run is going: the same defaults mock_site.load gives a device
    d = dict(d); d.setdefault('answers', True); d.setdefault('fails', 0); d.setdefault('activated', True); d.setdefault('backups', 0)
    d.setdefault('net', {'ip': ip, 'mask': '255.255.255.0', 'gw': '192.168.1.1', 'dhcp': False, 'dns1': '8.8.8.8', 'dns2': ''})
    d.setdefault('stream', {'codec': 'H.265', 'fps': 15, 'width': 2688, 'height': 1520, 'bitrate': 4096, 'gop': 30, 'smart': 'off', 'maxw': 2688, 'maxh': 1520})
    return d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', required=True); ap.add_argument('--powershell', required=True); ap.add_argument('--only', default='')
    args = ap.parse_args(); repo = Path(args.repo); here = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location('mock_site', here.parent / 'fixsite' / 'mock_site.py')
    mock = importlib.util.module_from_spec(spec); spec.loader.exec_module(mock)
    modes = MODES
    if args.only: modes = [x for x in modes if x in args.only.split(',')]
    with tempfile.TemporaryDirectory(prefix='fix2219site-') as tmp:
        for mode in modes:
            case = Path(tmp) / mode; vault = case / 'vault'; vault.mkdir(parents=True); runs = case / 'runs'
            pc = {'ip': '192.168.1.105', 'gw': '192.168.1.1', 'mask': '255.255.255.0', 'dhcp': True}
            sec = {'site': 'Review', 'password': 'Sitepass456', 'known': [], 'nvr': {'192.168.1.19': 'Sitepass456', '192.168.1.29': 'Sitepass456'},
                   'cams': {M50: 'Sitepass456'}, 'rollback': {'review-before': {}}, 'bitwardenSaved': True, 'shownOnce': True}
            undo = mode.startswith(('ch', 'occ', 'move', 'dhcp'))
            nvr_net = {'ip': '192.168.1.19', 'mask': '255.255.255.0', 'gw': '192.168.1.1', 'dhcp': False, 'dns1': '8.8.8.8', 'dns2': ''}
            lcam = {'name': 'Gate', 'mac': M50, 'ip': '192.168.1.50', 'nvr': '192.168.1.19', 'channel': 1}
            camip = '192.168.1.50'; chans = {'1': ch('192.168.1.50', 'Sitepass456')}; extra = {}
            if mode in ('chother', 'chsaved', 'movefree'): camip = '192.168.1.60'
            if mode == 'chother':
                chans = {'1': ch('192.168.1.50', 'Otherpass123')}; extra['192.168.1.50'] = cam('CAMSER151', M51, 'Otherpass123')
            if mode == 'chsaved': extra['192.168.1.50'] = cam('CAMSER151', M51, 'Sitepass456')
            if mode == 'movefree': chans = {'1': ch('192.168.1.60', 'Sitepass456')}
            if mode == 'occnvr': extra['192.168.1.29'] = cam('CAMSER151', M51, 'Sitepass456')
            if mode in ('fwdswap', 'fwdok'): nvr_net['gw'] = '192.168.1.254'
            if mode.startswith('poe'):
                lcam = {'name': 'Gate', 'mac': M50, 'ip': '192.168.1.50', 'switch': 'SW1', 'port': 5}
                if mode in ('poewrongch', 'poenvr', 'poeright'): lcam.update({'nvr': '192.168.1.19', 'channel': 1})
                if mode in ('poewrongch', 'poenvr'): chans = {'1': ch('192.168.1.50', 'Oldpass999')}   # the camera's channel needs a write once it is back
                if mode == 'poeright': chans = {'1': ch('192.168.1.50', 'Sitepass456')}
            devices = {'192.168.1.19': nvr('NVRSER19', M19, chans, net=nvr_net)}
            if not mode.startswith('poe'): devices[camip] = cam('CAMSER150', M50, 'Sitepass456')
            devices.update(extra)
            if mode == 'dhcpcam' or mode == 'dhcpcamok': devices[camip]['net'] = dict(STATIC50)
            site_list = {'site': 'Review', 'scheme': '192.168.1', 'nvrs': [{'brand': 'Hikvision', 'mac': M19, 'ip': '192.168.1.19'}], 'cameras': [lcam]}
            scene = case / 'scene.json'; scene.write_text(json.dumps({'pc': pc, 'devices': devices})); mock.load(scene)
            ctl = {'writes': [], 'swapped': False}

            def swap_nvr():
                d = mock.S['devices'].get('192.168.1.19')
                if d and not ctl['swapped']: d['mac'] = M99; d['serial'] = 'ANOTHER-NVR'; ctl['swapped'] = True

            class Handler(mock.H):
                def send(self, *a, **k):
                    try: return super().send(*a, **k)
                    except (BrokenPipeError, ConnectionResetError): pass

                def route(self, method, ip, path, q, body, rawq):
                    if method in ('PUT', 'POST', 'DELETE'):
                        d0 = mock.S['devices'].get(ip) or {}
                        ctl['writes'].append({'ip': ip, 'method': method, 'path': path, 'mac': d0.get('mac')})
                    if ctl.get('gone') and method == 'GET' and '192.168.1.19' in mock.S['devices']:   # the first read after the (authenticated) PUT
                        mock.S['devices']['10.250.0.19'] = mock.S['devices'].pop('192.168.1.19')   # after DHCP on it took an address nobody finds
                    if mode == 'fwdswap' and ip == '192.168.1.19' and path == '/ISAPI/System/configurationData': swap_nvr()
                    if ip == '_pc' and path == '/poe' and mode.startswith('poe'):
                        # the camera that comes up on .50 after the power-cycle: Gate itself, or ANOTHER camera on the site password
                        if '192.168.1.50' not in mock.S['devices']:
                            mock.S['devices']['192.168.1.50'] = mkdev(cam('CAMSER150', M50, 'Sitepass456') if mode in ('poeright', 'poenvr') else cam('CAMSER151', M51, 'Sitepass456'), '192.168.1.50')
                        if mode == 'poenvr': swap_nvr()
                    if mode == 'streamgap' and ip == '192.168.1.50' and method == 'GET' and path == '/ISAPI/Streaming/channels/101':
                        s = mock.S['devices'][ip]['stream']
                        xml = ('<StreamingChannel xmlns="http://www.hikvision.com/ver20/XMLSchema"><id>101</id><Video><videoResolutionWidth>%d</videoResolutionWidth>'
                               '<videoResolutionHeight>%d</videoResolutionHeight><videoQualityControlType>CBR</videoQualityControlType><constantBitRate>%d</constantBitRate>'
                               '<maxFrameRate>%d</maxFrameRate><GovLength>%d</GovLength></Video></StreamingChannel>') % (s['width'], s['height'], s['bitrate'], s['fps'] * 100, s['gop'])
                        return self.send(200, xml, 'application/xml')   # no codec, no SmartCodec in the answer
                    sticky = (mode == 'dhcpnvr' and ip == '192.168.1.19') or (mode == 'dhcpcam' and ip == '192.168.1.50')
                    if (sticky or (mode == 'dhcpgone' and ip == '192.168.1.19')) and method == 'PUT' and path.endswith('/ipAddress'):
                        r = super().route(method, ip, path, q, body, rawq)
                        for k2, v in list(mock.S['devices'].items()):
                            if sticky and v.get('mac') in (M19, M50) and k2 == ip: v['net']['dhcp'] = False   # acknowledged DHCP, kept the fixed address
                        if mode == 'dhcpgone': ctl['gone'] = True
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
                if mode.startswith('ch') or mode == 'movefree':
                    action = 'updated' if mode == 'chsaved' else 'added'
                    bf = ''
                    if action == 'updated':
                        bf = 'backup/nvr-192.168.1.19-ch1.xml'
                        (rb / bf).write_text(mock.H.chxml(None, '1', {'ip': '192.168.1.50', 'protocol': 'HIKVISION', 'name': 'Gate'}))
                    moved = mode in ('chother', 'chsaved', 'movefree')
                    cams = [{'name': 'Gate', 'mac': M50, 'serial': 'CAMSER150', 'brand': 'Hikvision', 'ip_before': '192.168.1.50', 'ip_after': '192.168.1.60' if moved else '',
                             'net_before': None if mode == 'chother' else dict(STATIC50), 'stream_before': None, 'password_changed': False,
                             'nvr': {'nvr': '192.168.1.19', 'channel': 1, 'action': action, 'before_file': bf, 'nvr_mac': M19, 'nvr_serial': 'NVRSER19'}}]
                elif mode.startswith('dhcpcam'):
                    cams = [{'name': 'Gate', 'mac': M50, 'serial': 'CAMSER150', 'brand': 'Hikvision', 'ip_before': '192.168.1.50', 'ip_after': '192.168.1.50',
                             'net_before': dict(STATIC50, dhcp=True), 'stream_before': None, 'password_changed': False}]
                elif mode.startswith('occnvr'):
                    nvrs = [{'ip': '192.168.1.29', 'target': '192.168.1.19', 'mac': M19, 'serial': 'NVRSER19', 'iface': '1',
                             'old': {'ip': '192.168.1.29', 'mask': '255.255.255.0', 'gw': '192.168.1.1', 'dhcp': False, 'dns1': '8.8.8.8', 'dns2': ''}}]
                else:
                    nvrs = [{'ip': '192.168.1.19', 'target': '192.168.1.19', 'mac': M19, 'serial': 'NVRSER19', 'iface': '1',
                             'old': {'ip': '192.168.1.19', 'mask': '255.255.255.0', 'gw': '192.168.1.1', 'dhcp': True, 'dns1': '8.8.8.8', 'dns2': ''}}]
                (rb / 'rollback.json').write_text(json.dumps({'run': 'review-before', 'site': 'Review', 'scheme': '192.168.1', 'taken_on': 'test', 'cameras': cams, 'nvrs': nvrs}))
                answers.write_text('YES\n'); cmd = base + ['-Mode', 'Rollback', '-RollbackDir', str(rb)]
            else:
                answers.write_text('N\nYES\nY\nYES\n'); cmd = base + ['-ListFile', str(lf)]
                if mode == 'streamgap': cmd += ['-AllCameras', '-Codec', 'H.264', '-Fps', '15']
            for run in (1, 2):
                ctl['writes'] = []
                try:
                    p = subprocess.run(cmd, capture_output=True, text=True, timeout=240); out, code = p.stdout + p.stderr, p.returncode
                except subprocess.TimeoutExpired as e:
                    out, code = 'TIMEOUT ' + str(e.stdout or ''), -9
                if os.environ.get('REPRO_DEBUG'): print(out[-6000:])
                S = mock.S; W = ctl['writes']
                ip_of = lambda mac: next((k for k, v in S['devices'].items() if v.get('mac') == mac), '')
                n19 = next((v for v in S['devices'].values() if v.get('mac') in (M19, M99) and v.get('kind') == 'nvr'), {})
                ch1 = (n19.get('channels') or {}).get('1')
                chw = [w for w in W if '/InputProxy/channels' in w['path']]
                m = re.search(r'Still a problem:\s*(\d+)', out)
                allback = bool(re.search(r'everything is back', out)); incomplete = (case / 'original-run' / 'undo-incomplete.txt').exists()
                tag = '%s run %d: ' % (mode, run); o = 'exit=%s writes=%s\n%s' % (code, json.dumps(W)[-1500:], out[-4000:])
                if mode == 'chother':
                    check(tag + 'F01: ch 1 shows ANOTHER camera (other password) on .50: nothing written to ch 1, it keeps .50', not chw and ch1 and ch1['ip'] == '192.168.1.50', o)
                    check(tag + 'F01: Undo incomplete, never "everything is back", nonzero exit', not allback and code != 0 and incomplete, o)
                elif mode == 'chsaved':
                    check(tag + 'F01 (saved-address path): ANOTHER camera on the site password at .50: nothing written to ch 1', not chw, o)
                    check(tag + 'F02 twin: Gate is NOT moved onto .50 (held by another camera): it stays on .60, no address write to it', ip_of(M50) == '192.168.1.60' and not [w for w in W if w['path'].endswith('/ipAddress')] and ip_of(M51) == '192.168.1.50', o)
                    check(tag + 'Undo incomplete, never "everything is back", nonzero exit', not allback and code != 0 and incomplete, o)
                elif mode == 'chmine':
                    if run == 1: check(tag + 'control: ch 1 still shows Gate: Undo deletes it, "everything is back", exit 0', ch1 is None and allback and code == 0 and any(w['method'] == 'DELETE' for w in chw), o)
                    else: check(tag + 'control: Undo again: nothing left, exit 0', ch1 is None and code == 0 and not chw, o)
                elif mode == 'occnvr':
                    check(tag + 'F02: the NVR is NOT moved onto .29 (held by another camera): no address write, it stays on .19', not [w for w in W if w['path'].endswith('/ipAddress')] and ip_of(M19) == '192.168.1.19' and ip_of(M51) == '192.168.1.29', o)
                    check(tag + 'F02: Undo incomplete, never "everything is back", nonzero exit', not allback and code != 0 and incomplete, o)
                elif mode == 'occnvrfree':
                    if run == 1: check(tag + 'control: .29 is free: the NVR goes back to .29, "everything is back", exit 0', ip_of(M19) == '192.168.1.29' and allback and code == 0, o)
                    else: check(tag + 'control: Undo again: still on .29, exit 0', ip_of(M19) == '192.168.1.29' and code == 0, o)
                elif mode == 'movefree':
                    if run == 1: check(tag + 'control: .50 is free: Gate goes back to .50, "everything is back", exit 0', ip_of(M50) == '192.168.1.50' and allback and code == 0, o)
                    else: check(tag + 'control: Undo again: still on .50, exit 0', ip_of(M50) == '192.168.1.50' and code == 0, o)
                elif mode in ('dhcpnvr', 'dhcpcam'):
                    mac = M19 if mode == 'dhcpnvr' else M50; dv = S['devices'].get(ip_of(mac)) or {}
                    check(tag + 'F13: DHCP acknowledged but the device kept its fixed address: NOT back, never "everything is back", nonzero exit', (dv.get('net') or {}).get('dhcp') is False and not allback and code != 0 and incomplete, o)
                elif mode == 'dhcpgone':
                    if run == 1: check(tag + 'F13: the NVR took DHCP and is not found by its MAC: NOT CHECKED, never "everything is back", nonzero exit', not allback and code != 0 and incomplete and 'NOT CHECKED' in out, o)
                    else: check(tag + 'F13: Undo again: still never "everything is back"', not allback and code != 0, o)
                elif mode in ('dhcpnvrok', 'dhcpcamok'):
                    mac = M19 if mode == 'dhcpnvrok' else M50; dv = S['devices'].get(ip_of(mac)) or {}
                    if run == 1: check(tag + 'control: the device takes DHCP and is found by its MAC: "everything is back", exit 0', (dv.get('net') or {}).get('dhcp') is True and allback and code == 0, o)
                    else: check(tag + 'control: Undo again: exit 0', code == 0, o)
                elif mode == 'fwdswap' and run == 1:   # run 2 starts with the other NVR already there: the scan finds IT, so that run may fix it
                    bad = [w for w in W if w.get('mac') == M99 and w['method'] == 'PUT' and not w['path'].startswith('/ISAPI/System/configurationData')]
                    check(tag + 'F03: nothing written to the replacement NVR (another MAC at .19)', not bad and n19.get('net', {}).get('gw') == '192.168.1.254', o)
                    check(tag + 'F03: never "network settings fixed", nonzero exit', not re.search(r'network settings fixed', out) and code != 0, o)
                elif mode == 'fwdok':
                    if run == 1: check(tag + 'control: the same NVR: "network settings fixed", router .1, exit 0', re.search(r'network settings fixed', out) and n19['net']['gw'] == '192.168.1.1' and code == 0, o)
                    else: check(tag + 'control: second run: exit 0', n19['net']['gw'] == '192.168.1.1' and code == 0, o)
                elif mode == 'streamgap':
                    sw = [w for w in W if w['path'] == '/ISAPI/Streaming/channels/101' and w['method'] == 'PUT']
                    check(tag + 'F19: missing codec / SmartCodec: never "settings already right", nothing written to the stream', 'settings already right' not in out and not sw, o)
                    check(tag + 'F19: the step says NOT CHECKED and names the missing fields, nonzero exit', re.search(r'settings NOT CHECKED[^\n]*(codec|Smart)', out) and code != 0, o)
                elif mode == 'poeright':
                    if run == 1: check(tag + 'PoE control: Gate (its MAC) answers after the power-cycle: "power-cycled", not "NOT confirmed", exit 0', 'power-cycled' in out and 'NOT confirmed to be this camera' not in out and code == 0 and ip_of(M50) == '192.168.1.50', o)
                elif mode in ('poewrong', 'poewrongch'):
                    if run == 1:
                        check(tag + 'PoE: ANOTHER camera answers on .50 after the power-cycle: NOT confirmed, never "answers again", nonzero exit', 'answers again' not in out and re.search(r'NOT confirmed to be this camera', out) and code != 0, o)
                        check(tag + 'PoE: nothing written to an NVR channel', not chw, o)
                elif mode == 'poenvr':
                    if run == 1: check(tag + 'PoE: Gate answers, but the NVR at .19 is now ANOTHER NVR: nothing written to ch 1, nonzero exit', not chw and code != 0 and re.search(r'NOT put on NVR', out), o)
            server.shutdown()
    print('%d passed, %d failed' % (PASS, FAIL))
    sys.exit(0 if FAIL == 0 else 1)


if __name__ == '__main__':
    main()
