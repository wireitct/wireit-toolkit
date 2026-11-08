#!/usr/bin/env python3
"""Mock recorders/cameras for NvrHealth tests (stdlib only). Requests go to /dev/<ip>/<device path>.
Hikvision ISAPI (digest), DW Spectrum REST (bearer), Uniview LAPI (digest) + ONVIF (WS-UsernameToken).
/mockctl/writes (GET: every write the devices received), /mockctl/reset (POST)."""
import hashlib, json, re, sys, threading, base64, uuid
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()
REALM = 'IP Camera'
EAST = 'CST+5:00:00DST01:00:00,M3.2.0/02:00:00,M11.1.0/02:00:00'
MOUNTAIN = 'MST+7:00:00DST01:00:00,M3.2.0/02:00:00,M11.1.0/02:00:00'
PW = {'good': 'NvrPass#2026', 'cam': 'CamPass#2026'}
WRITES = []
NS = 'xmlns="http://www.isapi.org/ver20/XMLSchema"'

def utcnow(): return datetime.now(timezone.utc).replace(microsecond=0)

def offset_min(tz, utc):
    """US-style rule M3.2.0 -> M11.1.0 at 2:00 local, std offset from the string."""
    m = re.match(r'^[A-Z]+([+-]?)(\d+)', tz)
    std = -(int(m.group(2)) * 60) * (-1 if m.group(1) == '-' else 1)
    if 'DST' not in tz and ',' not in tz: return std
    y = utc.year
    def nth(mo, wk, dow):
        d = datetime(y, mo, 1)
        while (d.weekday() + 1) % 7 != dow: d += timedelta(days=1)
        return d + timedelta(days=7 * (wk - 1))
    s = nth(3, 2, 0) + timedelta(hours=2); e = nth(11, 1, 0) + timedelta(hours=2)
    loc = (utc + timedelta(minutes=std)).replace(tzinfo=None)
    return std + 60 if s <= loc < e else std

def fresh_state():
    now = utcnow()
    def segs(days, last_end_min_ago, gap=None):
        # hourly segments from days ago until last_end_min_ago, device local handled at render time (stored UTC)
        out = []; t = now - timedelta(days=days); end = now - timedelta(minutes=last_end_min_ago)
        while t < end:
            e = min(t + timedelta(hours=6), end); out.append([t, e]); t = e
        return out
    good = {'kind': 'hik_nvr', 'pw': PW['good'], 'model': 'DS-7616NXI-K2/16P', 'serial': 'K72258945', 'fw': ('V4.85.040', 'build 260725'),
            'mode': 'NTP', 'tz': EAST, 'drift': 2, 'ntp': {'id': '1', 'fmt': 'hostname', 'host': 'time.nist.gov', 'ip': '', 'interval': '60'}, 'with_offset': True,
            'hdds': [{'id': '1', 'status': 'ok', 'cap': 3815447, 'free': 12288, 'smart': ('ok', 'functional', 38, 400)},
                     {'id': '2', 'status': 'ok', 'cap': 3815447, 'free': 8192, 'smart': ('ok', 'functional', 40, 400)}],
            'chans': [{'id': 1, 'ip': '192.168.254.2', 'online': True, 'segs': segs(50, 0), 'enable': 'true', 'mode': 'CMR'},
                      {'id': 2, 'ip': '10.9.0.21', 'online': True, 'segs': segs(49, 1), 'enable': 'true', 'mode': 'CMR', 'main': (2560, 1440, 2000, 12288, 'VBR', True)},
                      {'id': 3, 'ip': '192.168.254.4', 'online': True, 'segs': segs(48, 300), 'enable': 'true', 'mode': 'MOTION', 'sub': (640, 360, 1500, 512, 'VBR', False)},
                      {'id': 4, 'ip': '192.168.254.5', 'online': False, 'segs': segs(50, 2 * 24 * 60), 'enable': 'true', 'mode': 'CMR', 'main': (3840, 2160, 1500, 12288, 'CBR', True)}]}
    bad = {'kind': 'hik_nvr', 'pw': PW['good'], 'model': 'DS-7732NI-M4/16P', 'serial': 'AA3696627', 'fw': ('V4.61.420', 'build 230217'),
           'mode': 'manual', 'tz': MOUNTAIN, 'drift': -420, 'ntp': {'id': '1', 'fmt': 'ipaddress', 'host': '', 'ip': '0.0.0.0', 'interval': '1440'}, 'with_offset': False,
           'hdds': [{'id': '1', 'status': 'ok', 'cap': 1907729, 'free': 0, 'smart': ('error', 'badsectors', 47, 2400)},
                    {'id': '2', 'status': 'error', 'cap': 1907729, 'free': 0, 'smart': None}],
           'chans': [{'id': 1, 'ip': '10.9.0.31', 'online': True, 'segs': segs(20, 3000), 'enable': 'false', 'mode': 'CMR'},
                     {'id': 2, 'ip': '192.168.254.3', 'online': True, 'segs': segs(20, 0), 'enable': 'true', 'mode': 'CMR'}]}
    cam_bad = {'kind': 'hik_cam', 'pw': PW['good'], 'model': 'DS-2CD2143G0-I', 'serial': 'D11111111', 'fw': ('V5.5.83', 'build 190221'),
               'mode': 'manual', 'tz': EAST, 'drift': 900, 'ntp': {'id': '1', 'fmt': 'hostname', 'host': 'time.windows.com', 'ip': '', 'interval': '1440'}, 'with_offset': True, 'hdds': [], 'chans': []}
    cam_good = {'kind': 'hik_cam', 'pw': PW['good'], 'model': 'DS-2CD2343G2-IU', 'serial': 'G22222222', 'fw': ('V5.7.23', 'build 260320'),
                'mode': 'NTP', 'tz': EAST, 'drift': 1, 'ntp': {'id': '1', 'fmt': 'hostname', 'host': 'time.nist.gov', 'ip': '', 'interval': '60'}, 'with_offset': True, 'hdds': [], 'chans': []}
    dw = {'kind': 'dw', 'pw': PW['good'], 'version': '6.1.0.42176', 'tzid': 'America/New_York', 'drift': 0,
          'devices': [{'id': '{11111111-1111-1111-1111-111111111111}', 'name': 'Lobby', 'status': 'Recording', 'model': 'IPC328SR3-ADF28KM-G', 'vendor': 'Uniview', 'url': 'http://10.9.1.11/onvif/device_service', 'sched': True, 'fw': 'IPC_G6103-B6103.16.10.B25.201218', 'oldest_days': 46, 'live': True},
                      {'id': '{22222222-2222-2222-2222-222222222222}', 'name': 'Yard', 'status': 'Offline', 'model': 'DS-2CD2143G0-I', 'vendor': 'Hikvision', 'url': 'http://10.9.1.12', 'sched': True, 'fw': 'V5.5.83 build 190221', 'oldest_days': 45, 'live': False}],
          'storages': [{'url': 'D:\\HD Witness Media\\', 'totalSpace': 8001563222016, 'freeSpace': 40007816110, 'isOnline': True, 'isUsedForWriting': True, 'isBackup': False}]}
    unv = {'kind': 'unv', 'pw': PW['good'], 'model': 'NVR502-16B-P16', 'serial': '210235C3EVF22A000123', 'fw': 'NVR-B3613.43.52.260918',
           'mode': 'Manual', 'tz': 'CST-8:00:00', 'dst': False, 'drift': 3600, 'ntp': ['192.168.1.1'],
           'recs': [{'tok': 'rec1', 'name': 'D1', 'earliest_days': 31, 'status': 'Recording', 'latest_min': 0},
                    {'tok': 'rec2', 'name': 'D2', 'earliest_days': 31, 'status': 'Stopped', 'latest_min': 600}]}
    # Nov 3 2026: a second DW server like YKW Elm - one camera DW cannot log in to, one dead for weeks (Check this site / Camera doctor)
    dw2 = dict(dw, devices=[dict(dw['devices'][0], mac='44:19:B6:00:0A:11'),
                            {'id': '{33333333-3333-3333-3333-333333333333}', 'name': 'Dining Room Center', 'status': 'Unauthorized', 'model': 'IPC328SR3-ADF28KM-G', 'vendor': 'Uniview', 'url': 'http://10.9.1.29/onvif/device_service', 'sched': True, 'fw': 'IPC_G6103', 'oldest_days': 60, 'live': False, 'last_hours': 54 * 24, 'mac': '44:19:B6:00:0A:29'},
                            {'id': '{44444444-4444-4444-4444-444444444444}', 'name': 'Back Stairs', 'status': 'Offline', 'model': 'IPC2124LB', 'vendor': 'Uniview', 'url': 'http://10.9.1.30/onvif/device_service', 'sched': True, 'fw': 'IPC_G6103', 'oldest_days': 50, 'live': False, 'last_hours': 30, 'mac': '44:19:B6:00:0A:30'}])
    # 1.6.3: cameras behind a DW server, as Find cameras lists them - their password is NOT known; ONVIF lets anyone read the clock
    camA = dict(unv, pw='CamOnly#1', mode='NTP', drift=1, recs=[]); camB = dict(unv, pw='CamOnly#1', mode='NTP', drift=600, recs=[])
    return {'10.9.1.21': camA, '10.9.1.22': camB, '10.9.0.20': good, '10.9.0.21': cam_good, '10.9.0.30': bad, '10.9.0.31': cam_bad, '10.9.0.40': dw, '10.9.0.41': dw2, '10.9.1.29': {'kind': 'unvlock', 'remain': 1740}, '10.9.1.31': {'kind': 'hang'}, '10.9.0.50': unv,
            '10.9.0.60': dict(good, pw='SomethingElse!')}

STATE = fresh_state()

def tag(x, t):
    m = re.search(r'<(?:\w+:)?%s(?:\s[^>]*)?>([^<]*)</(?:\w+:)?%s>' % (t, t), x or '')
    return m.group(1) if m else None
def ok_xml(): return '<?xml version="1.0" encoding="UTF-8"?><ResponseStatus %s><requestURL>/</requestURL><statusCode>1</statusCode><statusString>OK</statusString><subStatusCode>ok</subStatusCode></ResponseStatus>' % NS

def dev_local(d, utc=None):
    utc = utc or utcnow()
    return (utc + timedelta(seconds=d['drift']) + timedelta(minutes=offset_min(d['tz'], utc))).replace(tzinfo=None)
def fmt_local(d, local):
    s = local.strftime('%Y-%m-%dT%H:%M:%S')
    if d.get('with_offset'):
        off = offset_min(d['tz'], utcnow()); s += '%s%02d:%02d' % ('+' if off >= 0 else '-', abs(off) // 60, abs(off) % 60)
    return s
def seg_local(d, t):  # recordings are stamped with the device's own (local) clock
    return (t + timedelta(minutes=offset_min(d['tz'], t))).replace(tzinfo=None) + timedelta(seconds=d['drift'])

class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass
    def send(self, code, body='', ctype='application/xml', extra=None):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code); self.send_header('Content-Type', ctype); self.send_header('Content-Length', str(len(b)))
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.end_headers(); self.wfile.write(b)
    def body(self):
        n = int(self.headers.get('Content-Length') or 0)
        return self.rfile.read(n).decode('utf-8', 'replace') if n else ''
    def digest_ok(self, d, method, uri):
        h = self.headers.get('Authorization') or ''
        if not h.startswith('Digest '): return False
        f = dict(re.findall(r'(\w+)="?([^",]*)"?', h[7:]))
        ha1 = hashlib.md5(('%s:%s:%s' % (f.get('username'), REALM, d['pw'])).encode()).hexdigest()
        ha2 = hashlib.md5(('%s:%s' % (method, f.get('uri'))).encode()).hexdigest()
        exp = hashlib.md5(('%s:%s:%s:%s:%s:%s' % (ha1, f.get('nonce'), f.get('nc'), f.get('cnonce'), f.get('qop'), ha2)).encode()).hexdigest()
        return f.get('response') == exp and f.get('username') == 'admin'
    def challenge(self):
        self.send(401, 'Unauthorized', 'text/plain', {'WWW-Authenticate': 'Digest realm="%s", qop="auth", nonce="%s", opaque="x"' % (REALM, uuid.uuid4().hex)})
    def do_GET(self): self.route('GET')
    def do_PUT(self): self.route('PUT')
    def do_POST(self): self.route('POST')
    def do_PATCH(self): self.route('PATCH')
    def do_DELETE(self): self.route('DELETE')
    def route(self, method):
        global STATE, WRITES
        b = self.body()
        if self.path.startswith('/mockctl/writes'): return self.send(200, json.dumps(WRITES), 'application/json')
        if self.path.startswith('/mockctl/auth/'): return self.send(200, json.dumps({'auth': STATE.get(self.path.rsplit('/', 1)[1], {}).get('auth', 0)}), 'application/json')
        if self.path.startswith('/mockctl/logouts/'): return self.send(200, json.dumps({'logouts': STATE.get(self.path.rsplit('/', 1)[1], {}).get('logouts', 0)}), 'application/json')
        if self.path.startswith('/mockctl/preauth/'): return self.send(200, json.dumps({'preauth': STATE.get(self.path.rsplit('/', 1)[1], {}).get('preauth', 0)}), 'application/json')
        if self.path.startswith('/mockctl/tries/'): return self.send(200, json.dumps({'tries': STATE.get(self.path.rsplit('/', 1)[1], {}).get('tries', 0)}), 'application/json')
        if self.path.startswith('/mockctl/reset'):
            with LOCK: STATE = fresh_state(); WRITES = []
            return self.send(200, '{}', 'application/json')
        m = re.match(r'^/dev/([\d.]+)(/.*)$', self.path)
        if not m: return self.send(404, 'no')
        ip, path = m.group(1), m.group(2)
        d = STATE.get(ip)
        if not d: return self.send(404, 'no device')
        ah = self.headers.get('Authorization') or ''
        if ah and not ah.startswith('Bearer '): d['auth'] = d.get('auth', 0) + 1   # 1.6.1 tests: every password-carrying request counts
        if d['kind'] == 'hang':   # Nov 3 2026: a camera whose web service accepts the connection and never answers
            import time; time.sleep(8); return self.send(200, '')
        if d['kind'] == 'unvlock':   # a Uniview that locked its login after too many wrong passwords (shape UNVERIFIED on real gear)
            d['tries'] = d.get('tries', 0) + 1
            return self.send(401, json.dumps({'Response': {'ResponseURL': path, 'ResponseCode': 4, 'ResponseString': 'User locked', 'Data': {'RemainLockTime': d['remain']}}}), 'application/json')
        with LOCK:
            k = d['kind']
            if k in ('hik_nvr', 'hik_cam'): return self.hik(ip, d, method, path, b)
            if k == 'dw': return self.dw(ip, d, method, path, b)
            if k == 'unv': return self.unv(ip, d, method, path, b)
        return self.send(404, 'no')

    # ---------------- Hikvision ----------------
    def hik(self, ip, d, method, path, b):
        if path.startswith('/api/') or path.startswith('/LAPI'): return self.send(404, 'Not Found', 'text/html')
        if not self.digest_ok(d, method, path): return self.challenge()
        p = path.split('?')[0]
        if method == 'PUT' or (method == 'POST' and p != '/ISAPI/ContentMgmt/search'): WRITES.append({'ip': ip, 'method': method, 'path': p, 'body': b})
        if p == '/ISAPI/System/deviceInfo':
            return self.send(200, '<?xml version="1.0" encoding="UTF-8"?><DeviceInfo %s><deviceName>Test</deviceName><model>%s</model><serialNumber>%s%s</serialNumber><firmwareVersion>%s</firmwareVersion><firmwareReleasedDate>%s</firmwareReleasedDate><deviceType>%s</deviceType></DeviceInfo>' % (NS, d['model'], d['model'].split('/')[0], d['serial'], d['fw'][0], d['fw'][1], 'NVR' if d['kind'] == 'hik_nvr' else 'IPCamera'))
        if p == '/ISAPI/System/time':
            if method == 'GET':
                lt = '' if d['mode'] == 'NTP' and False else '<localTime>%s</localTime>' % fmt_local(d, dev_local(d))
                return self.send(200, '<?xml version="1.0" encoding="UTF-8"?><Time %s><timeMode>%s</timeMode>%s<timeZone>%s</timeZone></Time>' % (NS, d['mode'], lt, d['tz']))
            if method == 'PUT':
                mode, tz = tag(b, 'timeMode'), tag(b, 'timeZone')
                if mode not in ('NTP', 'manual') or not tz: return self.send(400, ok_xml())
                d['mode'] = mode; d['tz'] = tz
                if mode == 'NTP' and (d['ntp']['host'] or d['ntp']['ip']) not in ('', '0.0.0.0'): d['drift'] = 0   # syncs at once
                return self.send(200, ok_xml())
        if p == '/ISAPI/System/time/ntpServers':
            n = d['ntp']
            return self.send(200, '<?xml version="1.0" encoding="UTF-8"?><NTPServerList %s><NTPServer><id>%s</id><addressingFormatType>%s</addressingFormatType><hostName>%s</hostName><ipAddress>%s</ipAddress><portNo>123</portNo><synchronizeInterval>%s</synchronizeInterval></NTPServer></NTPServerList>' % (NS, n['id'], n['fmt'], n['host'], n['ip'], n['interval']))
        if p.startswith('/ISAPI/System/time/ntpServers/'):
            n = d['ntp']
            if method == 'GET':
                return self.send(200, '<?xml version="1.0" encoding="UTF-8"?><NTPServer %s><id>%s</id><addressingFormatType>%s</addressingFormatType><hostName>%s</hostName><ipAddress>%s</ipAddress><portNo>123</portNo><synchronizeInterval>%s</synchronizeInterval></NTPServer>' % (NS, n['id'], n['fmt'], n['host'], n['ip'], n['interval']))
            n['fmt'] = tag(b, 'addressingFormatType') or n['fmt']; n['host'] = tag(b, 'hostName') or ''; n['ip'] = tag(b, 'ipAddress') or ''; n['interval'] = tag(b, 'synchronizeInterval') or n['interval']
            if d['mode'] == 'NTP': d['drift'] = 0
            return self.send(200, ok_xml())
        # Nov 3 2026 Release C fix buttons (mock only)
        if p == '/ISAPI/System/reboot' and method == 'PUT': d['reboots'] = d.get('reboots', 0) + 1; return self.send(200, ok_xml())
        if p == '/ISAPI/Security/users/1' and method == 'PUT':
            npw = tag(b, 'password')
            if not npw: return self.send(400, ok_xml())
            d['pw'] = npw; return self.send(200, ok_xml())
        if p == '/ISAPI/System/configurationData' and method == 'GET': return self.send(200, ('MOCKCONFIG-' + d['serial']).ljust(2048, '.'), 'application/octet-stream')   # 2.2.4: an export is KBs; a few bytes is FAILED
        if p == '/ISAPI/System/updateFirmware' and method == 'PUT':
            if not b: return self.send(400, ok_xml())
            d['fw'] = ('V9.9.9', 'build 999999'); return self.send(200, ok_xml())
        if d['kind'] != 'hik_nvr': return self.send(404, ok_xml())
        mm = re.match(r'^/ISAPI/ContentMgmt/record/tracks/(\d+)$', p)
        if mm:
            ch = next((c for c in d['chans'] if c['id'] * 100 + 1 == int(mm.group(1))), None)
            if not ch: return self.send(404, ok_xml())
            if method == 'PUT': ch['enable'] = 'true' if tag(b, 'Enable') == 'true' else 'false'; return self.send(200, ok_xml())
            return self.send(200, '<?xml version="1.0" encoding="UTF-8"?><Track %s><id>%d01</id><Channel>%d</Channel><Enable>%s</Enable><TrackSchedule><ScheduleBlock><ScheduleAction><Actions><Record>true</Record><ActionRecordingMode>%s</ActionRecordingMode></Actions></ScheduleAction></ScheduleBlock></TrackSchedule></Track>' % (NS, ch['id'], ch['id'], ch['enable'], ch['mode']))
        mm = re.match(r'^/ISAPI/ContentMgmt/InputProxy/channels/(\d+)$', p)
        if mm:
            cid = int(mm.group(1)); ch = next((c for c in d['chans'] if c['id'] == cid), None)
            if method == 'PUT':
                ip = tag(b, 'ipAddress')
                if not ip or not tag(b, 'password'): return self.send(400, ok_xml())
                if ch: ch['ip'] = ip; ch['online'] = True
                else: d['chans'].append({'id': cid, 'ip': ip, 'online': True, 'segs': [], 'enable': 'true', 'mode': 'CMR'})
                return self.send(200, ok_xml())
            if not ch: return self.send(404, ok_xml())
            return self.send(200, '<?xml version="1.0" encoding="UTF-8"?><InputProxyChannel %s><id>%d</id><name>Camera %02d</name><sourceInputPortDescriptor><ipAddress>%s</ipAddress><userName>admin</userName></sourceInputPortDescriptor></InputProxyChannel>' % (NS, cid, cid, ch['ip']))
        if p == '/ISAPI/ContentMgmt/InputProxy/channels':
            x = ''.join('<InputProxyChannel><id>%d</id><name>Camera %02d</name><sourceInputPortDescriptor><ipAddress>%s</ipAddress></sourceInputPortDescriptor></InputProxyChannel>' % (c['id'], c['id'], c['ip']) for c in d['chans'])
            return self.send(200, '<?xml version="1.0" encoding="UTF-8"?><InputProxyChannelList %s>%s</InputProxyChannelList>' % (NS, x))
        if p == '/ISAPI/ContentMgmt/StreamingProxy/channels':   # Nov 3 2026: stream audit (main x01 / sub x02)
            def sc(sid, s):
                w, h, fr, kb, rc, en = s
                return ('<StreamingChannel><id>%d</id><enabled>%s</enabled><Video><enabled>%s</enabled><videoCodecType>H.265</videoCodecType><videoResolutionWidth>%d</videoResolutionWidth>'
                        '<videoResolutionHeight>%d</videoResolutionHeight><videoQualityControlType>%s</videoQualityControlType><constantBitRate>%d</constantBitRate><vbrUpperCap>%d</vbrUpperCap>'
                        '<maxFrameRate>%d</maxFrameRate></Video></StreamingChannel>') % (sid, 'true', 'true' if en else 'false', w, h, rc, kb, kb, fr)
            x = ''.join(sc(c['id'] * 100 + 1, c.get('main', (2560, 1440, 2000, 4096, 'VBR', True))) + sc(c['id'] * 100 + 2, c.get('sub', (640, 360, 1500, 512, 'VBR', True))) for c in d['chans'])
            return self.send(200, '<?xml version="1.0" encoding="UTF-8"?><StreamingChannelList %s>%s</StreamingChannelList>' % (NS, x))
        if p == '/ISAPI/ContentMgmt/InputProxy/channels/status':
            x = ''.join('<InputProxyChannelStatus><id>%d</id><sourceInputPortDescriptor><ipAddress>%s</ipAddress></sourceInputPortDescriptor><online>%s</online><chanDetectResult>%s</chanDetectResult></InputProxyChannelStatus>' % (c['id'], c['ip'], str(c['online']).lower(), 'connect' if c['online'] else 'netUnreachable') for c in d['chans'])
            return self.send(200, '<?xml version="1.0" encoding="UTF-8"?><InputProxyChannelStatusList %s>%s</InputProxyChannelStatusList>' % (NS, x))
        if p == '/ISAPI/ContentMgmt/record/tracks':
            x = ''.join('<Track><id>%d01</id><Channel>%d</Channel><Enable>%s</Enable><TrackSchedule><ScheduleBlock><ScheduleAction><Actions><Record>true</Record><ActionRecordingMode>%s</ActionRecordingMode></Actions></ScheduleAction></ScheduleBlock></TrackSchedule></Track>' % (c['id'], c['id'], c['enable'], c['mode']) for c in d['chans'])
            return self.send(200, '<?xml version="1.0" encoding="UTF-8"?><TrackList %s>%s</TrackList>' % (NS, x))
        if p == '/ISAPI/ContentMgmt/Storage':
            x = ''.join('<hdd><id>%s</id><hddName>hdd%s</hddName><hddType>SATA</hddType><status>%s</status><capacity>%d</capacity><freeSpace>%d</freeSpace><property>RW</property></hdd>' % (h['id'], h['id'], h['status'], h['cap'], h['free']) for h in d['hdds'])
            return self.send(200, '<?xml version="1.0" encoding="UTF-8"?><storage %s><hddList>%s</hddList></storage>' % (NS, x))
        mm = re.match(r'^/ISAPI/ContentMgmt/Storage/hdd/(\d+)/SMARTTest/status$', p)
        if mm:
            h = next((h for h in d['hdds'] if h['id'] == mm.group(1)), None)
            if not h or not h['smart']: return self.send(404, ok_xml())
            s = h['smart']
            return self.send(200, '<?xml version="1.0" encoding="UTF-8"?><SMARTTestStatus %s><id>%s</id><temprature>%d</temprature><powerOnDay>%d</powerOnDay><selfEvaluaingStatus>%s</selfEvaluaingStatus><allEvaluaingStatus>%s</allEvaluaingStatus></SMARTTestStatus>' % (NS, h['id'], s[2], s[3], s[0], s[1]))
        if p == '/ISAPI/ContentMgmt/search' and method == 'POST':
            tid = int(tag(b, 'trackID')); ch = next((c for c in d['chans'] if c['id'] * 100 + 1 == tid), None)
            st = datetime.strptime(tag(b, 'startTime')[:19], '%Y-%m-%dT%H:%M:%S'); en = datetime.strptime(tag(b, 'endTime')[:19], '%Y-%m-%dT%H:%M:%S')
            mx = int(tag(b, 'maxResults') or 40)
            items = []
            for s0, e0 in (ch['segs'] if ch else []):
                ls, le = seg_local(d, s0), seg_local(d, e0)
                if le >= st and ls <= en: items.append((ls, le))
            items = items[:mx]
            x = ''.join('<searchMatchItem><sourceID>{0}</sourceID><trackID>%d</trackID><timeSpan><startTime>%sZ</startTime><endTime>%sZ</endTime></timeSpan></searchMatchItem>' % (tid, a.strftime('%Y-%m-%dT%H:%M:%S'), z.strftime('%Y-%m-%dT%H:%M:%S')) for a, z in items)
            return self.send(200, '<?xml version="1.0" encoding="UTF-8"?><CMSearchResult %s><searchID>x</searchID><responseStatus>true</responseStatus><responseStatusStrg>%s</responseStatusStrg><numOfMatches>%d</numOfMatches><matchList>%s</matchList></CMSearchResult>' % (NS, 'OK' if items else 'NO MATCHES', len(items), x))
        return self.send(404, ok_xml())

    # ---------------- DW Spectrum ----------------
    def dw(self, ip, d, method, path, b):
        p = path.split('?')[0]; q = dict(re.findall(r'[?&]([^=&]+)=([^&]*)', path))
        if p == '/api/moduleInformation': return self.send(200, json.dumps({'error': '0', 'reply': {'version': d['version'], 'name': 'YKW-TEST', 'brand': 'digitalwatchdog'}}), 'application/json')
        if p == '/rest/v3/login/sessions' and method == 'POST':
            d['tries'] = d.get('tries', 0) + 1   # 1.6.1 tests: DW login attempts (max 1 per run, 0 when skipped)
            j = json.loads(b or '{}')
            if j.get('username') == 'admin' and j.get('password') == d['pw']: return self.send(200, json.dumps({'token': 'vms-TESTTOKEN', 'username': 'admin'}), 'application/json')
            return self.send(401, json.dumps({'error': '401', 'errorString': 'Wrong password'}), 'application/json')
        if self.headers.get('Authorization') != 'Bearer vms-TESTTOKEN': return self.send(401, '{"error":"401"}', 'application/json')
        if p.startswith('/rest/v3/login/sessions/') and method == 'DELETE':   # 1.6.3: logout (not a write to the system)
            if p.rsplit('/', 1)[1] != 'vms-TESTTOKEN': return self.send(404, '{"error":"404"}', 'application/json')
            d['logouts'] = d.get('logouts', 0) + 1; return self.send(204, '')
        if method != 'GET': WRITES.append({'ip': ip, 'method': method, 'path': p, 'body': b})
        now = utcnow(); ms = lambda t: int(t.timestamp() * 1000)
        if p == '/api/gettime': return self.send(200, json.dumps({'error': '0', 'reply': {'utcTime': str(ms(now) + d['drift'] * 1000), 'timeZoneOffset': str(offset_min(EAST, now) * 60000), 'timezoneId': d['tzid']}}), 'application/json')
        if p == '/rest/v3/servers/this/storages/*/status': return self.send(200, json.dumps(d['storages']), 'application/json')
        if p == '/rest/v3/devices':
            return self.send(200, json.dumps([{'id': x['id'], 'name': x['name'], 'status': x['status'], 'model': x['model'], 'vendor': x['vendor'], 'url': x['url'], 'schedule': {'isEnabled': x['sched']}, 'parameters': {'firmware': x['fw']}, 'physicalId': x.get('mac', '')} for x in d['devices']]), 'application/json')
        if p == '/ec2/recordedTimePeriods':
            x = next(x for x in d['devices'] if x['id'] == requests_unquote(q.get('cameraId', '')))
            st = now - timedelta(days=x['oldest_days'])
            per = [{'startTimeMs': str(ms(st)), 'durationMs': str(3600 * 1000)}]
            last = now - timedelta(hours=x.get('last_hours', 3)) if not x['live'] else now - timedelta(minutes=30)
            per.append({'startTimeMs': str(ms(last)), 'durationMs': '-1' if x['live'] else str(1800 * 1000)})
            return self.send(200, json.dumps({'error': '0', 'reply': per}), 'application/json')
        mm = re.match(r'^/rest/v3/devices/(.+)$', p)
        if mm and method == 'PATCH':
            x = next((x for x in d['devices'] if x['id'] == requests_unquote(mm.group(1))), None)
            if not x: return self.send(404, '{"error":"404"}', 'application/json')
            j = json.loads(b or '{}')
            if 'schedule' in j: x['sched'] = bool(j['schedule'].get('isEnabled'))
            if 'credentials' in j:
                if not j['credentials'].get('password'): return self.send(400, '{"error":"400"}', 'application/json')
                x['status'] = 'Online'
            return self.send(200, json.dumps({'id': x['id']}), 'application/json')
        return self.send(404, '{"error":"404"}', 'application/json')

    # ---------------- Uniview ----------------
    def unv(self, ip, d, method, path, b):
        p = path.split('?')[0]
        if p.startswith('/LAPI/'):
            if not self.digest_ok(d, method, path): return self.challenge()
            if method != 'GET': WRITES.append({'ip': ip, 'method': method, 'path': p, 'body': b})
            def ok(data): return self.send(200, json.dumps({'Response': {'ResponseURL': p, 'ResponseCode': 0, 'ResponseString': 'Succeed', 'Data': data}}), 'application/json')
            if p == '/LAPI/V1.0/System/Reboot' and method == 'PUT': return ok({})
            if p == '/LAPI/V1.0/System/DeviceInfo': return ok({'DeviceModel': d['model'], 'SerialNumber': d['serial'], 'FirmwareVersion': d['fw'], 'DeviceName': 'NVR'})
            if p == '/LAPI/V1.0/System/Time/NTP': return ok({'Enabled': 1 if d['mode'] == 'NTP' else 0, 'NTPServerInfos': [{'IPAddress': h, 'Port': 123, 'SynchronizeInterval': 60} for h in d['ntp']]})
            return self.send(404, '{}', 'application/json')
        if p.startswith('/onvif/'):
            if 'UsernameToken' in b: d['auth'] = d.get('auth', 0) + 1   # 1.6.3: a WS-Security password counts as a login attempt too
            pre = 'UsernameToken' not in b and re.search(r'<s:Body><x:GetSystemDateAndTime\s*/>', b)
            if pre: d['preauth'] = d.get('preauth', 0) + 1   # ONVIF: GetSystemDateAndTime is answered without a login
            if not pre and not self.wsse_ok(d, b): return self.send(400, '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body><s:Fault><s:Code><s:Value>s:Sender</s:Value><s:Subcode><s:Value>ter:NotAuthorized</s:Value></s:Subcode></s:Code></s:Fault></s:Body></s:Envelope>', 'application/soap+xml')
            op = re.search(r'<s:Body><x:(\w+)', b); op = op.group(1) if op else ''
            if op.startswith('Set'): WRITES.append({'ip': ip, 'method': 'ONVIF', 'path': op, 'body': re.sub(r'<s:Header>.*</s:Header>', '', b)})
            env = lambda inner: self.send(200, '<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tt="http://www.onvif.org/ver10/schema" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:trc="http://www.onvif.org/ver10/recording/wsdl" xmlns:tse="http://www.onvif.org/ver10/search/wsdl"><s:Body>' + inner + '</s:Body></s:Envelope>', 'application/soap+xml')
            now = utcnow() + timedelta(seconds=d['drift'])
            if op == 'GetSystemDateAndTime':
                return env('<tds:GetSystemDateAndTimeResponse><tds:SystemDateAndTime><tt:DateTimeType>%s</tt:DateTimeType><tt:DaylightSavings>%s</tt:DaylightSavings><tt:TimeZone><tt:TZ>%s</tt:TZ></tt:TimeZone><tt:UTCDateTime><tt:Time><tt:Hour>%d</tt:Hour><tt:Minute>%d</tt:Minute><tt:Second>%d</tt:Second></tt:Time><tt:Date><tt:Year>%d</tt:Year><tt:Month>%d</tt:Month><tt:Day>%d</tt:Day></tt:Date></tt:UTCDateTime></tds:SystemDateAndTime></tds:GetSystemDateAndTimeResponse>' % (d['mode'], str(d['dst']).lower(), d['tz'], now.hour, now.minute, now.second, now.year, now.month, now.day))
            if op == 'GetNTP':
                return env('<tds:GetNTPResponse><tds:NTPInformation><tt:FromDHCP>false</tt:FromDHCP>' + ''.join('<tt:NTPManual><tt:Type>%s</tt:Type><tt:%s>%s</tt:%s></tt:NTPManual>' % (('IPv4', 'IPv4Address', h, 'IPv4Address') if re.match(r'^\d', h) else ('DNS', 'DNSname', h, 'DNSname')) for h in d['ntp']) + '</tds:NTPInformation></tds:GetNTPResponse>')
            if op == 'SetNTP':
                h = tag(b, 'DNSname') or tag(b, 'IPv4Address'); d['ntp'] = [h]
                if d['mode'] == 'NTP': d['drift'] = 0
                return env('<tds:SetNTPResponse/>')
            if op == 'SetSystemDateAndTime':
                d['mode'] = tag(b, 'DateTimeType'); d['dst'] = tag(b, 'DaylightSavings') == 'true'; d['tz'] = tag(b, 'TZ') or d['tz']
                if d['mode'] == 'NTP': d['drift'] = 0
                return env('<tds:SetSystemDateAndTimeResponse/>')
            if op == 'GetServices':
                return env('<tds:GetServicesResponse><tds:Service><tds:Namespace>http://www.onvif.org/ver10/device/wsdl</tds:Namespace><tds:XAddr>http://%s/onvif/device_service</tds:XAddr></tds:Service><tds:Service><tds:Namespace>http://www.onvif.org/ver10/recording/wsdl</tds:Namespace><tds:XAddr>http://%s/onvif/recording_service</tds:XAddr></tds:Service><tds:Service><tds:Namespace>http://www.onvif.org/ver10/search/wsdl</tds:Namespace><tds:XAddr>http://%s/onvif/search_service</tds:XAddr></tds:Service></tds:GetServicesResponse>' % (ip, ip, ip))
            if op == 'GetDeviceInformation':
                return env('<tds:GetDeviceInformationResponse><tds:Manufacturer>Uniview</tds:Manufacturer><tds:Model>%s</tds:Model><tds:FirmwareVersion>%s</tds:FirmwareVersion><tds:SerialNumber>%s</tds:SerialNumber></tds:GetDeviceInformationResponse>' % (d['model'], d['fw'], d['serial']))
            if op == 'GetRecordings':
                return env('<trc:GetRecordingsResponse>' + ''.join('<trc:RecordingItem><tt:RecordingToken>%s</tt:RecordingToken><tt:Configuration><tt:Source><tt:SourceId>%s</tt:SourceId><tt:Name>%s</tt:Name></tt:Source></tt:Configuration></trc:RecordingItem>' % (r['tok'], r['name'], r['name']) for r in d['recs']) + '</trc:GetRecordingsResponse>')
            if op == 'GetRecordingInformation':
                tok = tag(b, 'RecordingToken'); r = next(r for r in d['recs'] if r['tok'] == tok); u = utcnow()
                return env('<tse:GetRecordingInformationResponse><tse:RecordingInformation><tt:RecordingToken>%s</tt:RecordingToken><tt:EarliestRecording>%s</tt:EarliestRecording><tt:LatestRecording>%s</tt:LatestRecording><tt:RecordingStatus>%s</tt:RecordingStatus></tse:RecordingInformation></tse:GetRecordingInformationResponse>' % (tok, (u - timedelta(days=r['earliest_days'])).strftime('%Y-%m-%dT%H:%M:%SZ'), (u - timedelta(minutes=r['latest_min'])).strftime('%Y-%m-%dT%H:%M:%SZ'), r['status']))
            return self.send(400, 'unknown op ' + op, 'text/plain')
        if p.startswith('/ISAPI') or p.startswith('/api/'): return self.send(404, 'Not Found', 'text/html')
        return self.send(404, 'no')
    def wsse_ok(self, d, b):
        user, dig, nonce, created = tag(b, 'Username'), tag(b, 'Password'), tag(b, 'Nonce'), tag(b, 'Created')
        if not (user and dig and nonce and created): return False
        exp = base64.b64encode(hashlib.sha1(base64.b64decode(nonce) + created.encode() + d['pw'].encode()).digest()).decode()
        return user == 'admin' and dig == exp

def requests_unquote(s):
    from urllib.parse import unquote; return unquote(s)

if __name__ == '__main__':
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18090
    ThreadingHTTPServer(('127.0.0.1', port), H).serve_forever()
