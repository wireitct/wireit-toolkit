#!/usr/bin/env python3
# mock_site.py - a fake site for WireIt Toolkit 2.0 tests: Hikvision + Dahua cameras, a Hikvision NVR, this PC's network.
# Every device call is  http://127.0.0.1:<port>/dev/<ip>/<real path>  (the Toolkit's -MockUrl). Basic auth stands in for digest.
# A device only answers when this PC has an address on its scheme (own scheme, or a temporary one the Toolkit added), like the real LAN.
# GET /dev/_pc/state shows everything (tests read it to prove what changed).  Nothing here touches a real network.
import sys, json, re, base64, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

JPEG = b'\xff\xd8\xff\xe0' + b'\x00' * 2000 + b'\xff\xd9'
S = {}
LOCK = threading.Lock()

def p3(ip): return '.'.join(ip.split('.')[:3])

def load(path):
    global S
    S = json.load(open(path, encoding='utf-8-sig'))
    S.setdefault('temps', []); S.setdefault('log', []); S.setdefault('poe_calls', [])
    S.setdefault('pc', {'ip': '192.168.1.105', 'gw': '192.168.1.1', 'mask': '255.255.255.0', 'dhcp': True})
    for ip, d in S['devices'].items():
        d.setdefault('answers', True); d.setdefault('fails', 0); d.setdefault('activated', True)
        d.setdefault('net', {'ip': ip, 'mask': '255.255.255.0', 'gw': S['pc']['gw'] if p3(ip) == p3(S['pc']['gw']) else '192.168.0.1', 'dhcp': bool(d.get('dhcp')), 'dns1': '', 'dns2': ''})
        d.setdefault('stream', {'codec': 'H.265', 'fps': 15, 'width': 2688, 'height': 1520, 'bitrate': 4096, 'gop': 30, 'smart': 'off', 'maxw': 2688, 'maxh': 1520})
        d.setdefault('backups', 0)

def reachable(ip):
    return p3(ip) == p3(S['pc']['gw']) or p3(ip) in S['temps']

def camera_online(nvr, ch):
    # video on an NVR channel = a camera answers at that IP, the password the NVR stores is right, and the NVR can decode it
    cam = S['devices'].get(ch['ip'])
    if not cam or cam['kind'] != 'camera' or not cam['answers'] or not cam['activated']: return False
    if ch.get('password') != cam['password']: return False
    # 2.0.3 test: a camera whose picture only comes back on one password (the NVR cannot use it with any other)
    if cam.get('video_needs_pw') and cam['password'] != cam['video_needs_pw']: return False
    if cam['brand'] == 'Dahua' and (cam['stream']['smart'] == 'on' or cam['stream']['codec'] == 'H.265') and S.get('nvr_strict', True): return False
    return True

def xml_text(body, tag):
    m = re.search(r'<(?:\w+:)?%s(?:\s[^>]*)?>([^<]*)</' % tag, body); return m.group(1) if m else ''

class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *a): pass
    def send(self, code, body=b'', ctype='text/plain', headers=None):
        if isinstance(body, str): body = body.encode()
        self.send_response(code); self.send_header('Content-Type', ctype); self.send_header('Content-Length', str(len(body)))
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.end_headers(); self.wfile.write(body)
    def do_GET(self): self.handle_all('GET')
    def do_PUT(self): self.handle_all('PUT')
    def do_POST(self): self.handle_all('POST')
    def do_DELETE(self): self.handle_all('DELETE')
    def handle_all(self, method):
        n = int(self.headers.get('Content-Length') or 0); body = self.rfile.read(n).decode('utf-8', 'replace') if n else ''
        u = urlparse(self.path); m = re.match(r'^/(dev|tls)/([^/]+)(/.*)?$', u.path)
        if not m: return self.send(404)
        tls, ip, path = (m.group(1) == 'tls'), m.group(2), (m.group(3) or '/'); q = {k: v[0] for k, v in parse_qs(u.query, keep_blank_values=True).items()}
        self.tls = tls
        if tls:
            # 2.2.1: /tls/<ip>/... = the device's HTTPS port. A device without "https": true has none: the connection just closes
            d0 = S['devices'].get(ip)
            if not d0 or not d0.get('https') or not reachable(ip) or not d0['answers']:
                with LOCK: S['log'].append('TLS-NONE %s %s' % (method, ip))
                self.close_connection = True
                try: self.connection.shutdown(2)
                except Exception: pass
                return
        with LOCK:
            try: self.route(method, ip, path, q, body, u.query)
            except Exception as e:
                import traceback; traceback.print_exc(); self.send(500, str(e))

    def auth(self, d):
        a = self.headers.get('Authorization') or ''
        if not a.startswith('Basic '): return None
        try: user, pw = base64.b64decode(a[6:]).decode().split(':', 1)
        except Exception: return False
        if d['fails'] >= 5: return 'locked'
        if user == 'admin' and pw == d['password']: d['fails'] = 0; return True
        d['fails'] += 1; return False

    def route(self, method, ip, path, q, body, rawq):
        if ip == '_pc': return self.pc(method, path, q, body)
        d = S['devices'].get(ip)
        if d and reachable(ip) and not d['answers'] and d.get('wake_after'):
            # 2.0.2: a hung camera that comes back after the tech unplugs it: answers again after N unanswered calls
            d['wake_after'] -= 1
            if d['wake_after'] <= 0: d['answers'] = True; d['fails'] = 0
            return self.send(599, 'no answer')
        if not d or not reachable(ip) or not d['answers']: return self.send(599, 'no answer')
        S['log'].append(('TLS ' if getattr(self, 'tls', False) else '') + '%s %s %s' % (method, ip, path + ('?' + rawq if rawq and 'pwd' not in rawq else '')))
        if not getattr(self, 'tls', False) and ('pwd=' in rawq or (method in ('PUT', 'POST') and '<password>' in body)): S.setdefault('plain_secrets', []).append(ip)
        a = self.auth(d)
        if a is None or a is False or a == 'locked':
            return self.send(401, 'locked' if a == 'locked' else 'Unauthorized', headers={'WWW-Authenticate': 'Basic realm="x"'})
        if d['brand'] == 'Dahua': return self.dahua(d, ip, method, path, q, body)
        return self.hik(d, ip, method, path, q, body)

    # ---------------- this PC ----------------
    def pc(self, method, path, q, body):
        if path == '/net': return self.send(200, json.dumps(S['pc']), 'application/json')
        if path == '/scan':
            out = []
            for ip, d in S['devices'].items():
                out.append({'brand': d['brand'], 'model': d['model'], 'serial': d['serial'], 'mac': d['mac'], 'ip': ip, 'firmware': d.get('firmware', ''), 'kind': d['kind'], 'activated': d['activated']})
            return self.send(200, json.dumps(out), 'application/json')
        if path == '/free': return self.send(200, 'false' if (q['ip'] in S['devices'] or q['ip'] == S['pc']['ip']) else 'true')
        if path == '/addtemp':
            if q['p3'] not in S['temps']: S['temps'].append(q['p3'])
            return self.send(200, 'ok')
        if path == '/deltemp':
            if q['p3'] in S['temps']: S['temps'].remove(q['p3'])
            return self.send(200, 'ok')
        if path == '/poe':
            S['poe_calls'].append(q['mac']); mac = q['mac'].lower()
            for ip, d in S['devices'].items():
                if d['mac'].lower() == mac and S.get('poe_ok', True): d['answers'] = True; d['fails'] = 0
            ok = S.get('poe_ok', True)
            return self.send(200, json.dumps({'state': 'done' if ok else 'refused', 'msg': 'power-cycled' if ok else 'That port is the switch uplink. Nothing was done.'}), 'application/json')
        if path == '/state': return self.send(200, json.dumps(S), 'application/json')
        return self.send(404)

    # ---------------- Hikvision ----------------
    def hik(self, d, ip, method, path, q, body):
        X = 'application/xml'
        if path == '/ISAPI/System/deviceInfo':
            return self.send(200, '<DeviceInfo xmlns="http://www.hikvision.com/ver20/XMLSchema"><deviceName>x</deviceName><model>%s</model><serialNumber>%s</serialNumber><macAddress>%s</macAddress><firmwareVersion>%s</firmwareVersion><firmwareReleasedDate>build 200316</firmwareReleasedDate></DeviceInfo>' % (d['model'], d['serial'], d['mac'], d.get('firmware', 'V5')), X)
        if path == '/ISAPI/System/Network/interfaces' and method == 'GET':
            return self.send(200, '<NetworkInterfaceList xmlns="http://www.hikvision.com/ver20/XMLSchema"><NetworkInterface><id>1</id></NetworkInterface></NetworkInterfaceList>', X)
        if path == '/ISAPI/System/Network/interfaces/1/ipAddress':
            n = d['net']
            if method == 'GET':
                return self.send(200, '<IPAddress xmlns="http://www.hikvision.com/ver20/XMLSchema"><ipVersion>v4</ipVersion><addressingType>%s</addressingType><ipAddress>%s</ipAddress><subnetMask>%s</subnetMask><DefaultGateway><ipAddress>%s</ipAddress></DefaultGateway><PrimaryDNS><ipAddress>%s</ipAddress></PrimaryDNS><SecondaryDNS><ipAddress>%s</ipAddress></SecondaryDNS></IPAddress>' % ('dynamic' if n['dhcp'] else 'static', n['ip'], n['mask'], n['gw'], n['dns1'], n['dns2']), X)
            top = re.search(r'<ipAddress>([^<]*)</ipAddress><subnetMask>([^<]*)</subnetMask>', body)
            gw = re.search(r'<DefaultGateway><ipAddress>([^<]*)', body)
            new = top.group(1); old = d['net']['ip']
            d['net'].update(ip=new, mask=top.group(2), gw=gw.group(1) if gw else n['gw'], dhcp=('dynamic' in body))
            if new != old: S['devices'][new] = S['devices'].pop(old)
            return self.send(200, '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>', X)
        if path == '/ISAPI/Security/users/1' and method == 'PUT':
            old = xml_text(body, 'loginPassword')
            if old != d['password']: return self.send(403, '<ResponseStatus><statusCode>4</statusCode></ResponseStatus>', X)
            d['password'] = xml_text(body, 'password'); d['pw_changes'] = d.get('pw_changes', 0) + 1
            return self.send(200, '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>', X)
        if path == '/ISAPI/Streaming/channels/101/capabilities':
            s = d['stream']; return self.send(200, '<StreamingChannel><Video><videoResolutionWidth opt="%d,1920,1280"/><videoResolutionHeight opt="%d,1080,720"/></Video></StreamingChannel>' % (s['maxw'], s['maxh']), X)
        if path == '/ISAPI/Streaming/channels/101' and method == 'GET':
            s = d['stream']
            return self.send(200, '<StreamingChannel xmlns="http://www.hikvision.com/ver20/XMLSchema"><id>101</id><Video><videoCodecType>%s</videoCodecType><videoResolutionWidth>%d</videoResolutionWidth><videoResolutionHeight>%d</videoResolutionHeight><videoQualityControlType>CBR</videoQualityControlType><constantBitRate>%d</constantBitRate><maxFrameRate>%d</maxFrameRate><GovLength>%d</GovLength><SmartCodec><enabled>%s</enabled></SmartCodec></Video></StreamingChannel>' % (s['codec'].replace('.', ''), s['width'], s['height'], s['bitrate'], s['fps'] * 100, s['gop'], 'true' if s['smart'] == 'on' else 'false'), X)
        if path == '/ISAPI/Streaming/channels/101' and method == 'PUT':
            s = d['stream']; c = xml_text(body, 'videoCodecType'); s['codec'] = ('H.' + c[1:]) if c.startswith('H') and '.' not in c else c
            s['fps'] = int(xml_text(body, 'maxFrameRate')) // 100; s['gop'] = int(xml_text(body, 'GovLength')); s['bitrate'] = int(xml_text(body, 'constantBitRate'))
            s['width'] = int(xml_text(body, 'videoResolutionWidth')); s['height'] = int(xml_text(body, 'videoResolutionHeight'))
            s['smart'] = 'on' if re.search(r'<SmartCodec[^>]*><enabled>true', body) else 'off'
            return self.send(200, '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>', X)
        if path == '/ISAPI/Streaming/channels/102': return self.send(200, '<StreamingChannel/>', X)
        if path == '/ISAPI/System/time': return self.send(200, '<Time/>', X)
        if path == '/ISAPI/System/configurationData': d['backups'] += 1; return self.send(200, b'BACKUPDATA' * 100, 'application/octet-stream')
        if path == '/ISAPI/System/reboot' and method == 'PUT': d['reboots'] = d.get('reboots', 0) + 1; return self.send(200, '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>', X)
        # NVR
        if d['kind'] == 'nvr':
            chs = d.setdefault('channels', {})
            if path == '/ISAPI/ContentMgmt/InputProxy/channels' and method == 'GET':
                return self.send(200, '<InputProxyChannelList xmlns="http://www.hikvision.com/ver20/XMLSchema">' + ''.join(self.chxml(k, c) for k, c in sorted(chs.items(), key=lambda x: int(x[0]))) + '</InputProxyChannelList>', X)
            if path == '/ISAPI/ContentMgmt/InputProxy/channels/status':
                return self.send(200, '<InputProxyChannelStatusList xmlns="http://www.hikvision.com/ver20/XMLSchema">' + ''.join('<InputProxyChannelStatus><id>%s</id><online>%s</online></InputProxyChannelStatus>' % (k, 'true' if camera_online(d, c) else 'false') for k, c in chs.items()) + '</InputProxyChannelStatusList>', X)
            mm = re.match(r'^/ISAPI/ContentMgmt/InputProxy/channels/(\d+)$', path)
            if mm:
                k = mm.group(1)
                if method == 'GET': return self.send(200, self.chxml(k, chs[k]), X) if k in chs else self.send(404)
                if method == 'PUT' and k in chs:
                    chs[k]['ip'] = xml_text(body, 'ipAddress'); pw = xml_text(body, 'password')
                    if pw: chs[k]['password'] = pw
                    v = xml_text(body, 'proxyProtocol')
                    if v: chs[k]['protocol'] = v
                    return self.send(200, '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>', X)
                if method == 'DELETE' and k in chs:
                    del chs[k]; return self.send(200, '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>', X)
            if path == '/ISAPI/ContentMgmt/InputProxy/channels' and method == 'POST':
                k = xml_text(body, 'id'); chs[k] = {'ip': xml_text(body, 'ipAddress'), 'password': xml_text(body, 'password'), 'protocol': xml_text(body, 'proxyProtocol'), 'name': ''}
                return self.send(200, '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>', X)
            mm = re.match(r'^/ISAPI/Streaming/channels/(\d+)01/picture$', path)
            if mm:
                k = mm.group(1)
                return self.send(200, JPEG, 'image/jpeg') if k in chs and camera_online(d, chs[k]) else self.send(503)
        if path == '/ISAPI/Streaming/channels/101/picture':
            return self.send(200, JPEG, 'image/jpeg') if d['kind'] == 'camera' else self.send(404)
        return self.send(404, 'not in mock: ' + path)
    def chxml(self, k, c):
        return '<InputProxyChannel><id>%s</id><name>%s</name><sourceInputPortDescriptor><proxyProtocol>%s</proxyProtocol><addressingFormatType>ipaddress</addressingFormatType><ipAddress>%s</ipAddress><managePortNo>%s</managePortNo><userName>admin</userName></sourceInputPortDescriptor></InputProxyChannel>' % (k, c.get('name', ''), c.get('protocol', 'HIKVISION'), c['ip'], '8000' if c.get('protocol', 'HIKVISION') == 'HIKVISION' else '80')

    # ---------------- Dahua ----------------
    def dahua(self, d, ip, method, path, q, body):
        if path == '/cgi-bin/magicBox.cgi':
            a = q.get('action')
            if a == 'getDeviceType': return self.send(200, 'type=%s\r\n' % d['model'])
            if a == 'getSystemInfo': return self.send(200, 'deviceType=%s\r\nserialNumber=%s\r\n' % (d['model'], d['serial']))
            if a == 'getSoftwareVersion': return self.send(200, 'version=%s\r\n' % d.get('firmware', ''))
            if a == 'reboot': d['reboots'] = d.get('reboots', 0) + 1; return self.send(200, 'OK\r\n')
        if path == '/cgi-bin/configManager.cgi':
            a = q.get('action'); s = d['stream']; n = d['net']
            if a == 'getConfig':
                nm = q.get('name')
                if nm == 'Network': return self.send(200, 'table.Network.DefaultInterface=eth0\r\ntable.Network.eth0.IPAddress=%s\r\ntable.Network.eth0.SubnetMask=%s\r\ntable.Network.eth0.DefaultGateway=%s\r\ntable.Network.eth0.DhcpEnable=%s\r\ntable.Network.eth0.DnsServers[0]=%s\r\ntable.Network.eth0.DnsServers[1]=%s\r\n' % (n['ip'], n['mask'], n['gw'], 'true' if n['dhcp'] else 'false', n['dns1'], n['dns2']))
                if nm == 'Encode': return self.send(200, 'table.Encode[0].MainFormat[0].Video.Compression=%s\r\ntable.Encode[0].MainFormat[0].Video.FPS=%d\r\ntable.Encode[0].MainFormat[0].Video.Width=%d\r\ntable.Encode[0].MainFormat[0].Video.Height=%d\r\ntable.Encode[0].MainFormat[0].Video.BitRate=%d\r\ntable.Encode[0].MainFormat[0].Video.GOP=%d\r\n' % (s['codec'].replace('.', ''), s['fps'], s['width'], s['height'], s['bitrate'], s['gop']))
                if nm == 'SmartEncode': return self.send(200, 'table.SmartEncode[0].Enable=%s\r\n' % ('true' if s['smart'] == 'on' else 'false'))
                return self.send(200, 'table.%s=1\r\n' % nm)
            if a == 'setConfig':
                for k, v in q.items():
                    if k == 'action': continue
                    if k.endswith('Video.Compression'): s['codec'] = v.replace('H264', 'H.264').replace('H265', 'H.265') if '.' not in v else v
                    elif k.endswith('Video.FPS'): s['fps'] = int(v)
                    elif k.endswith('Video.BitRate'): s['bitrate'] = int(v)
                    elif k.endswith('Video.GOP'): s['gop'] = int(v)
                    elif k.endswith('Video.Width'): s['width'] = int(v)
                    elif k.endswith('Video.Height'): s['height'] = int(v)
                    elif k.endswith('SmartEncode[0].Enable'): s['smart'] = 'on' if v == 'true' else 'off'
                    elif k.endswith('eth0.IPAddress'): newip = v
                    elif k.endswith('eth0.SubnetMask'): n['mask'] = v
                    elif k.endswith('eth0.DefaultGateway'): n['gw'] = v
                    elif k.endswith('eth0.DhcpEnable'): n['dhcp'] = (v == 'true')
                if any(k.endswith('eth0.IPAddress') for k in q):
                    old = n['ip']; n['ip'] = q[[k for k in q if k.endswith('eth0.IPAddress')][0]]
                    if n['ip'] != old: S['devices'][n['ip']] = S['devices'].pop(old)
                return self.send(200, 'OK\r\n')
        if path == '/cgi-bin/userManager.cgi' and q.get('action') == 'modifyPassword':
            if q.get('pwdOld') != d['password']: return self.send(400, 'Error\r\n')
            d['password'] = q['pwd']; d['pw_changes'] = d.get('pw_changes', 0) + 1; return self.send(200, 'OK\r\n')
        if path == '/cgi-bin/Config.backup': d['backups'] += 1; return self.send(200, b'DAHUABACKUP' * 100, 'application/octet-stream')
        if path == '/cgi-bin/snapshot.cgi': return self.send(200, JPEG, 'image/jpeg')
        return self.send(404, 'not in mock: ' + path)

if __name__ == '__main__':
    load(sys.argv[1]); port = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    srv = ThreadingHTTPServer(('127.0.0.1', port), H); print(srv.server_address[1], flush=True); srv.serve_forever()
