"""minicrypto.py - stdlib-only stand-ins for the two crypto steps fake_sadp.py needs (2.2.5).
The 2.2.4 fake imported the 'cryptography' package; a plain Python on a Windows PC does not have it, so the fake devices never
started there ("got 0, want 4"). Test-only code: RSA PKCS#1 v1.5 encryption with a public key, and AES-128/192/256 ECB decryption.
"""
import os

def _der_read(b, i):
    tag = b[i]; i += 1
    ln = b[i]; i += 1
    if ln & 0x80:
        n = ln & 0x7f; ln = int.from_bytes(b[i:i + n], 'big'); i += n
    return tag, b[i:i + ln], i + ln

def load_rsa_public_der(der):
    """(n, e) from a PKCS#1 RSAPublicKey or an X.509 SubjectPublicKeyInfo, DER."""
    tag, body, _ = _der_read(der, 0)
    if tag != 0x30: raise ValueError('not a DER sequence')
    t1, v1, j = _der_read(body, 0)
    if t1 == 0x02:                      # PKCS#1: SEQUENCE { n INTEGER, e INTEGER }
        t2, v2, _ = _der_read(body, j)
        return int.from_bytes(v1, 'big'), int.from_bytes(v2, 'big')
    if t1 == 0x30:                      # SPKI: SEQUENCE { algorithm, BIT STRING { PKCS#1 } }
        t2, v2, _ = _der_read(body, j)
        if t2 != 0x03: raise ValueError('no BIT STRING in the public key')
        return load_rsa_public_der(v2[1:])
    raise ValueError('unknown public key form')

def rsa_pkcs1v15_encrypt(n, e, msg):
    k = (n.bit_length() + 7) // 8
    if len(msg) > k - 11: raise ValueError('message too long')
    ps = b''
    while len(ps) < k - 3 - len(msg):
        ps += bytes(x for x in os.urandom(k) if x)
    em = b'\x00\x02' + ps[:k - 3 - len(msg)] + b'\x00' + msg
    return pow(int.from_bytes(em, 'big'), e, n).to_bytes(k, 'big')

# ---- AES (FIPS-197), decryption only ----
def _xt(a): return ((a << 1) ^ 0x1b) & 0xff if a & 0x80 else a << 1
def _mul(a, b):
    r = 0
    while b:
        if b & 1: r ^= a
        a = _xt(a); b >>= 1
    return r
def _sbox():
    s = [0] * 256; p = q = 1
    while True:
        p = p ^ ((p << 1) & 0xff) ^ (0x1b if p & 0x80 else 0)
        q ^= q << 1; q ^= q << 2; q ^= q << 4; q &= 0xff
        if q & 0x80: q ^= 0x09
        x = q ^ ((q << 1 | q >> 7) & 0xff) ^ ((q << 2 | q >> 6) & 0xff) ^ ((q << 3 | q >> 5) & 0xff) ^ ((q << 4 | q >> 4) & 0xff)
        s[p] = x ^ 0x63
        if p == 1: break
    s[0] = 0x63
    return s
SBOX = _sbox()
INV = [0] * 256
for _i, _v in enumerate(SBOX): INV[_v] = _i

def _expand(key):
    nk = len(key) // 4; nr = nk + 6
    w = [list(key[4 * i:4 * i + 4]) for i in range(nk)]
    rcon = 1
    for i in range(nk, 4 * (nr + 1)):
        t = list(w[i - 1])
        if i % nk == 0:
            t = t[1:] + t[:1]; t = [SBOX[x] for x in t]; t[0] ^= rcon; rcon = _xt(rcon)
        elif nk > 6 and i % nk == 4:
            t = [SBOX[x] for x in t]
        w.append([a ^ b for a, b in zip(w[i - nk], t)])
    return [sum(w[4 * r:4 * r + 4], []) for r in range(nr + 1)], nr

def _dec_block(rk, nr, blk):
    s = [a ^ b for a, b in zip(blk, rk[nr])]
    for r in range(nr - 1, -1, -1):
        # inverse shift rows (column-major state: byte i = row i%4, col i//4)
        t = [0] * 16
        for c in range(4):
            for row in range(4):
                t[row + 4 * ((c + row) % 4)] = s[row + 4 * c]
        s = [INV[x] for x in t]
        s = [a ^ b for a, b in zip(s, rk[r])]
        if r:
            u = []
            for c in range(4):
                a0, a1, a2, a3 = s[4 * c:4 * c + 4]
                u += [_mul(a0, 14) ^ _mul(a1, 11) ^ _mul(a2, 13) ^ _mul(a3, 9),
                      _mul(a0, 9) ^ _mul(a1, 14) ^ _mul(a2, 11) ^ _mul(a3, 13),
                      _mul(a0, 13) ^ _mul(a1, 9) ^ _mul(a2, 14) ^ _mul(a3, 11),
                      _mul(a0, 11) ^ _mul(a1, 13) ^ _mul(a2, 9) ^ _mul(a3, 14)]
            s = u
    return bytes(s)

def aes_ecb_decrypt(key, data):
    if len(key) not in (16, 24, 32) or len(data) % 16: raise ValueError('bad AES key or data length')
    rk, nr = _expand(bytes(key))
    return b''.join(_dec_block(rk, nr, data[i:i + 16]) for i in range(0, len(data), 16))
