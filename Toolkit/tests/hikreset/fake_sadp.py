#!/usr/bin/env python3
"""fake_sadp.py - a pretend set of Hikvision devices for the Toolkit tests (UDP, loopback). Speaks the same XML a real device does
(shape taken from real answers read on 3 Hewlett St, Nov 6 2026: ERI-K108-P8 + 3x ECI-T44F2). Usage: fake_sadp.py <port> <devices.json>
devices.json: [{mac, ip, mask, gw, serial, model, activated, kind, boot, code, unlock, codeTypes:[...], importTypes:[...], password}]
  code   = what the device gives when asked for its request code (base64, starts AwAAA = 03 00 00 00)
  unlock = what Hikvision's reply file must contain for the device to accept the reset
State changes are written to <devices.json>.state.json so a test can read what the device did.
"""
import json, socket, sys, re, os, base64
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
port = int(sys.argv[1]); path = sys.argv[2]
devs = json.load(open(path, encoding='utf-8-sig')); statep = path + '.state.json'
log = []
def save():
    json.dump({'devices': devs, 'log': log}, open(statep, 'w'), indent=1)
def tag(x, n):
    m = re.search(r'<%s>([^<]*)</%s>' % (n, n), x); return m.group(1) if m else ''
CURUUID = ['X']
def probe_match(d, types, extra=''):
    return ('<?xml version="1.0" encoding="UTF-8"?><ProbeMatch><Uuid>' + CURUUID[0] + '</Uuid><Types>%s</Types>%s<DeviceType>1</DeviceType><DeviceDescription>%s</DeviceDescription><DeviceSN>%s</DeviceSN>'
            '<CommandPort>8000</CommandPort><HttpPort>80</HttpPort><MAC>%s</MAC><IPv4Address>%s</IPv4Address><IPv4SubnetMask>%s</IPv4SubnetMask><IPv4Gateway>%s</IPv4Gateway>'
            '<DHCP>false</DHCP><AnalogChannelNum>0</AnalogChannelNum><DigitalChannelNum>%d</DigitalChannelNum><SoftwareVersion>V5.5.90build 220609</SoftwareVersion><DSPVersion>V7.3</DSPVersion>'
            '<BootTime>%s</BootTime><Encrypt>true</Encrypt><Salt>aa11</Salt><Activated>%s</Activated><PasswordResetAbility>true</PasswordResetAbility></ProbeMatch>') % (
            types, extra, d['model'], d['serial'], d['mac'], d['ip'], d['mask'], d['gw'], 8 if d.get('kind') == 'nvr' else 1, d['boot'], 'true' if d['activated'] else 'false')
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(('127.0.0.1', port)); s.settimeout(0.5)
open(path + '.ready', 'w').write('1')
while True:
    if os.path.exists(path + '.stop'): break
    try: data, addr = s.recvfrom(65535)
    except socket.timeout: continue
    x = data.decode('utf8', 'ignore'); ty = tag(x, 'Types'); mac = tag(x, 'MAC').lower()
    if '<Probe>' not in x: continue
    CURUUID[0] = tag(x, 'Uuid') or 'X'
    def send(t): s.sendto(t.encode(), addr)
    if ty in ('inquiry', 'inquiry_v32'):
        for d in devs: send(probe_match(d, ty))
        continue
    for d in devs:
        if d['mac'] != mac: continue
        log.append({'type': ty, 'mac': mac})
        if d.get('real') and ty == 'exchangecode' and tag(x, 'Code'):
            # SADP 3.x key exchange: client public key (PKCS#1 DER b64) -> session key (hex text) encrypted with it
            pub = serialization.load_der_public_key(base64.b64decode(tag(x, 'Code')))
            d['_sess'] = os.urandom(16).hex()
            ct = pub.encrypt(d['_sess'].encode(), padding.PKCS1v15())
            send(probe_match(d, ty, '<Result>success</Result><Code>%s</Code>' % base64.b64encode(ct).decode())); save(); continue
        if d.get('real') and ty == 'reset':
            ok = False
            try:
                key = bytes.fromhex(d['_sess']); raw = base64.b64decode(tag(x, 'Password'))
                dec = Cipher(algorithms.AES(key), modes.ECB()).decryptor(); pt = dec.update(raw) + dec.finalize()
                first = key if d.get('layout') == 2 else d['_sess'][:16].encode()
                ok = pt[:16] == first and tag(x, 'Code') == d['realUnlock'] and not d.get('bootChanged')
                if ok: d['activated'] = True; d['password'] = pt[16:].rstrip(b'\0').decode()
            except Exception as e: log.append({'err': str(e)})
            log[-1].update({'result': 'success' if ok else 'failed', 'form': 'reset'})
            send(probe_match(d, ty, '<Result>%s</Result>' % ('success' if ok else 'failed'))); save(); continue
        if ty in d.get('codeTypes', ['getcode']) and d['activated']:
            send(probe_match(d, ty, '<Code>%s</Code>' % d['code']))
        elif ty in d.get('importTypes', ['resetPassword']):
            code = tag(x, 'Code') or tag(x, 'SecurityCode'); pw = tag(x, 'Password')
            ok = pw and (code == d['unlock'] or code == d['unlock'] + d['serial'])
            if ok and d.get('bootChanged'): ok = False
            if ok: d['activated'] = True; d['password'] = pw
            log[-1].update({'result': 'success' if ok else 'denied', 'form': ty})
            send(probe_match(d, ty, '<Result>%s</Result>' % ('success' if ok else 'denied')))
        elif ty == 'activate':
            ok = not d['activated'] and tag(x, 'Password')
            if ok: d['activated'] = True; d['password'] = tag(x, 'Password')
            send(probe_match(d, ty, '<Result>%s</Result>' % ('success' if ok else 'failure')))
        elif ty == 'update':
            ok = tag(x, 'Password') == d.get('password')
            if ok: d['ip'] = tag(x, 'IPv4Address') or d['ip']; d['mask'] = tag(x, 'IPv4SubnetMask') or d['mask']; d['gw'] = tag(x, 'IPv4Gateway') or d['gw']
            send(probe_match(d, ty, '<Result>%s</Result>' % ('success' if ok else 'failure')))
        save()
save()
