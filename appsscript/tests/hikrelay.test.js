// HikRelay.gs tests (no Google): node appsscript/tests/hikrelay.test.js
const assert = require('assert'), fs = require('fs'), path = require('path'), vm = require('vm');
let pass = 0; const ok = (c, m) => { assert(c, m); pass++; }; const eq = (a, b, m) => { assert.deepStrictEqual(a, b, m); pass++; };
function env() {
  const props = {}, cache = {}, files = {}, trig = []; let fileN = 0, NOW = Date.parse('2026-11-08T15:00:00Z'), mails = [], slept = 0;
  const blob = (name, bytes, type) => ({ getName: () => name, getBytes: () => Buffer.from(bytes), getSize: () => Buffer.from(bytes).length, getContentType: () => type, copyBlob() { return this; } });
  const g = {
    console: { log() {}, error() {} }, JSON, Date: class extends Date { constructor(...a) { a.length ? super(...a) : super(NOW); } static now() { return NOW; } },
    PropertiesService: { getScriptProperties: () => ({ getProperty: k => (k in props ? props[k] : null), setProperty: (k, v) => { props[k] = String(v); }, deleteProperty: k => { delete props[k]; }, getProperties: () => Object.assign({}, props) }) },
    CacheService: { getScriptCache: () => ({ get: k => (k in cache ? cache[k] : null), put: (k, v) => { cache[k] = v; } }) },
    LockService: { getScriptLock: () => ({ tryLock: () => true, releaseLock() {} }) },
    Utilities: { sleep: ms => { slept += ms; }, base64Encode: b => Buffer.from(b).toString('base64') },
    ContentService: { MimeType: { JSON: 'json' }, createTextOutput: s => ({ s, setMimeType() { return this; } }) },
    ScriptApp: { getProjectTriggers: () => trig, newTrigger: fn => { const t = { getHandlerFunction: () => fn }; const b = { timeBased: () => b, everyMinutes: m => { t.every = m; return b; }, create: () => { trig.push(t); return t; } }; return b; } },
    DriveApp: {
      createFolder: n => { return { getId: () => 'FOLDER1', getName: () => n }; },
      getFolderById: id => { if (id !== 'FOLDER1') throw new Error('no folder'); return { getName: () => 'f', createFile: b => { const id2 = 'F' + (++fileN); files[id2] = { name: b.getName(), bytes: b.getBytes(), trashed: false }; return { getId: () => id2, setName: n => { files[id2].name = n; } }; } }; },
      getFileById: id => ({ getBlob: () => ({ getBytes: () => files[id].bytes }), setTrashed: v => { files[id].trashed = v; } })
    },
    GmailApp: { search: (q) => { g._q = q; return mails.length ? [{ getMessages: () => mails }] : []; } }
  };
  vm.createContext(g); vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'HikRelay.gs'), 'utf8'), g);
  g._props = props; g._cache = cache; g._files = files; g._trig = trig; g._blob = blob;
  g._mail = (id, from, subject, body, atts, when) => mails.push({ getId: () => id, getFrom: () => from, getSubject: () => subject, getPlainBody: () => body, getAttachments: () => atts || [], getDate: () => new Date(when || NOW) });
  g._now = v => { NOW = v; }; g._t = () => NOW; g._slept = () => slept;
  g._post = o => JSON.parse(g.doPost({ postData: { contents: JSON.stringify(o) } }).s);
  return g;
}
const KEY = 'k'.repeat(32), SER = 'DS-2CD2143G2-I20230101AAWRK12345678', SS = 'K12345678';
// ---- setup ----
let g = env();
assert.throws(() => g.setupHikRelay(), /STATUS_PUSH_KEY/); pass++;
g._props.STATUS_PUSH_KEY = KEY;
let s = g.setupHikRelay(); eq([s.ok, s.folder, s.address, s.trigger], [true, 'FOLDER1', 'hikreset@wireitct.com', 'made'], 'setup makes the folder and the trigger');
eq([g._trig.length, g._trig[0].every], [1, 5], 'one 5-minute trigger');
s = g.setupHikRelay(); eq([g._trig.length, s.trigger], [1, 'already there'], 'setup again: no second trigger');
// ---- scan: an attachment, a code, an unmatched mail, our own sent mail, a logo image ----
g._mail('m1', 'Hikvision <noreply@hikvision.com>', 'Password reset for device ' + SER, 'Please import the attached file.', [g._blob('logo.png', 'PNG', 'image/png'), g._blob('reset_' + SS + '.xml', '<xml>unlock</xml>', 'application/xml')]);
g._mail('m2', 'support@hikvision.com', 'Re: reset request serial DS-7608NI-K2/8P20210505CCWRF99887766', 'Your verification code: AB12CD34\nThanks', []);
g._mail('m3', 'support@hikvision.com', 'Your ticket', 'We received your request.', []);
g._mail('m4', 'hikreset@wireitct.com', 'request ' + SER, 'sent by us', []);
let r = g.scanHikReplies();
eq([r.ok, r.filed, r.unmatched], [true, 2, 1], 'scan: 2 replies filed by serial, 1 unmatched');
ok(/^to:\(hikreset@wireitct\.com\) newer_than:7d$/.test(g._q), 'scan searches mail to the reset address');
const rec1 = JSON.parse(g._props.HIKR_m1); eq([rec1.kind, rec1.name], ['file', 'reset_' + SS + '.xml'], 'the xml attachment is kept, the logo skipped');
ok(g._files[rec1.fileId] && g._files[rec1.fileId].name.indexOf('DS-2CD2143G2-I20230101AAWRK12345678__m1__') === 0, 'file kept in the Drive folder under its serial');
eq(JSON.parse(g._props.HIKR_m2).code, 'AB12CD34', 'code read from the mail text');
ok(JSON.parse(g._props.HIKR_m2).serials.indexOf('AB12CD34') < 0, 'the code is not taken as a serial');
ok(JSON.parse(g._props.HIKR_m4).skip === 'own', 'our own sent request is skipped');
eq(g.unmatchedHikReplies().length, 1, 'unmatchedHikReplies lists the one it could not tie');
r = g.scanHikReplies(); eq([r.filed, r.seen], [0, 4], 'scan again: nothing filed twice');
// ---- get ----
let a = g._post({ op: 'hikReplyGet', key: 'x'.repeat(32), serial: SER, shortSerial: SS, pc: 'SITEBOX2' });
eq([a.ok, a.msg], [false, 'Wrong key.'], 'wrong key refused'); ok(g._slept() >= 1000, 'wrong key costs a pause');
a = g._post({ op: 'hikReplyGet', key: KEY, serial: 'bad serial!', pc: 'SITEBOX2' }); eq([a.ok, a.msg], [false, 'Bad serial.'], 'bad serial refused');
a = g._post({ op: 'hikReplyGet', key: KEY, serial: 'DS-2CD2387G2P20240101AAWRL55555555', shortSerial: 'L55555555', pc: 'SITEBOX2' }); eq([a.ok, a.found], [true, false], 'no reply yet: found false');
a = g._post({ op: 'hikReplyGet', key: KEY, serial: SER, shortSerial: SS, pc: 'SITEBOX2' });
eq([a.ok, a.found, a.kind, a.name, Buffer.from(a.data, 'base64').toString()], [true, true, 'file', 'reset_' + SS + '.xml', '<xml>unlock</xml>'], 'the file is served by full serial');
a = g._post({ op: 'hikReplyGet', key: KEY, serial: SER, shortSerial: SS, pc: 'SITEBOX2' }); eq(a.found, true, 'same box within 15 min: served again (dropped connection)');
a = g._post({ op: 'hikReplyGet', key: KEY, serial: SER, shortSerial: SS, pc: 'OTHERPC' }); eq(a.found, false, 'another box: not served (served once)');
g._now(g._t() + 16 * 60000);
a = g._post({ op: 'hikReplyGet', key: KEY, serial: SER, shortSerial: SS, pc: 'SITEBOX2' }); eq(a.found, false, 'after 15 min: gone');
a = g._post({ op: 'hikReplyGet', key: KEY, serial: 'DS-7608NI-K2/8P20210505CCWRF99887766'.replace('/', ''), shortSerial: 'F99887766', pc: 'SITEBOX2' });
eq([a.found, a.kind, a.code], [true, 'code', 'AB12CD34'], 'the code is served by short serial');
a = g._post({ op: 'nope', key: KEY }); eq(a.ok, false, 'unknown op refused');
a = JSON.parse(g.doPost({ postData: { contents: '{not json' } }).s); eq(a.ok, false, 'bad body refused, no crash');
// ---- bad key flood ----
g = env(); g._props.STATUS_PUSH_KEY = KEY;
for (let i = 0; i < 20; i++) g._post({ op: 'hikReplyGet', key: 'bad', serial: SER });
a = g._post({ op: 'hikReplyGet', key: KEY, serial: SER, shortSerial: SS }); ok(a.ok === true, '2.2.3 #54 reproduction: 20 wrong keys from a stranger do NOT lock out the right key (2.2.2 refused it)');
a = g._post({ op: 'hikReplyGet', key: 'bad2', serial: SER }); ok(a.ok === false && /Too many/.test(a.msg), '...wrong keys are still refused for 10 minutes');
// ---- 2.2.3 relay fixes ----
// #50: a stranger's mail naming our serial is not filed or served
g = env(); g._props.STATUS_PUSH_KEY = KEY; g.setupHikRelay();
g._mail('x1', 'Mallory <mallory@evil.example>', 'Reset for ' + SER, 'verification code: ZZ12ZZ34', []);
r = g.scanHikReplies(); eq([r.filed, r.unmatched], [0, 1], '#50 reproduction: an unrelated sender is not filed (2.2.2 filed it)');
a = g._post({ op: 'hikReplyGet', key: KEY, serial: SER, shortSerial: SS }); eq(a.found, false, '#50 ...and not served');
eq(g.unmatchedHikReplies()[0].kind, 'untrusted', '#50 ...listed for the admin as untrusted');
g._props.HIK_TRUSTED_SENDERS = 'partner.example'; g._mail('x2', 'tech@partner.example', 'Reset for ' + SER, 'verification code: YY12YY34', []);
r = g.scanHikReplies(); eq(r.filed, 1, '#50 a sender the admin names is trusted');
eq(g.hrTrusted_('Hik <no-reply@mail.hikvision.com>'), true, '#50 a hikvision.com subdomain is trusted'); eq(g.hrTrusted_('x@nothikvision.com'), false, '#50 a look-alike domain is not');
// #51: an old reply does not answer a new request
g = env(); g._props.STATUS_PUSH_KEY = KEY; g.setupHikRelay();
g._mail('o1', 'support@hikvision.com', 'Reset for ' + SER, 'verification code: OL12DD34', [], g._t() - 6 * 86400000);
g.scanHikReplies();
a = g._post({ op: 'hikReplyGet', key: KEY, serial: SER, shortSerial: SS, exportedAt: new Date(g._t() - 3600000).toISOString() }); eq(a.found, false, '#51 reproduction: a 6-day-old code is not returned for a request made an hour ago');
a = g._post({ op: 'hikReplyGet', key: KEY, serial: SER, shortSerial: SS }); eq(a.found, false, '#51 no exportedAt: only the last 48 hours count');
g._mail('o2', 'support@hikvision.com', 'Reset for ' + SER, 'verification code: NE12WW34', [], g._t() - 600000); g.scanHikReplies();
a = g._post({ op: 'hikReplyGet', key: KEY, serial: SER, shortSerial: SS, exportedAt: new Date(g._t() - 3600000).toISOString() }); eq([a.found, a.code], [true, 'NE12WW34'], '#51 a reply after the request is served');
// #52: a PDF before the XML is never the unlock file
g = env(); g._props.STATUS_PUSH_KEY = KEY; g.setupHikRelay();
g._mail('p1', 'support@hikvision.com', 'Reset for ' + SER, 'see attached', [g._blob('cover.pdf', '%PDF', 'application/pdf'), g._blob('reset_' + SS + '.xml', '<xml>unlock</xml>', 'application/xml')]);
g.scanHikReplies(); eq(JSON.parse(g._props.HIKR_p1).name, 'reset_' + SS + '.xml', '#52 reproduction: the XML is kept, not the PDF before it');
g._mail('p2', 'support@hikvision.com', 'Reset for ' + SER, 'Your verification code: CD34EF56', [g._blob('letter.docx', 'DOC', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document')]);
g.scanHikReplies(); eq([JSON.parse(g._props.HIKR_p2).kind, JSON.parse(g._props.HIKR_p2).code], ['code', 'CD34EF56'], '#52 a Word cover letter: the code in the text is used');
// #53: prose is not a code
eq(g.hrCode_('please use the code provided by your installer'), '', '#53 reproduction: "the code provided" is not a code');
eq(g.hrCode_('Your verification code: AB12CD34'), 'AB12CD34', '#53 a real code is still read'); eq(g.hrCode_('reset key is QW12ER34.'), 'QW12ER34', '#53 "key is" form');
// #55: more than 50 threads are paged through
g = env(); g._props.STATUS_PUSH_KEY = KEY; g.setupHikRelay();
for (let i = 0; i < 120; i++) g._mail('pg' + i, 'support@hikvision.com', 'Reset for DS-2CD2143G2-I2023010' + String(i).padStart(3, '0') + 'AAWRK' + String(10000000 + i), 'x', []);
{ const calls = []; const old = g.GmailApp.search; const msgs = []; g.GmailApp.search = (q, s, n) => { calls.push([s, n]); const all = old(q)[0].getMessages(); return all.slice(s, s + n).map(m => ({ getMessages: () => [m] })); };
  r = g.scanHikReplies(); eq(r.unmatched + r.filed, 120, '#55 reproduction: all 120 threads read (2.2.2 stopped at the newest 50)'); ok(calls.length === 3, '#55 three pages'); }
// ---- no key set: everything refused ----
g = env(); a = g._post({ op: 'hikReplyGet', key: '', serial: SER }); eq(a.ok, false, 'no STATUS_PUSH_KEY: refused');
// ---- old records are forgotten after 30 days ----
g = env(); g._props.STATUS_PUSH_KEY = KEY; g.setupHikRelay();
g._mail('m9', 'support@hikvision.com', 'reset ' + SER, '', [g._blob('k.xml', 'x', 'text/xml')]); g.scanHikReplies();
const fid = JSON.parse(g._props.HIKR_m9).fileId; g._now(g._t() + 31 * 86400000); g.scanHikReplies();
ok(!g._props.HIKR_m9 && g._files[fid].trashed, 'after 30 days: record dropped, Drive copy binned');
// ---- big / risky attachments are not served ----
g = env(); g._props.STATUS_PUSH_KEY = KEY; g.setupHikRelay();
g._mail('mA', 'support@hikvision.com', 'reset ' + SER, 'code: ZZ99ZZ99', [g._blob('big.bin', 'x'.repeat(3 * 1024 * 1024), 'application/octet-stream'), g._blob('run.exe', 'MZ', 'application/octet-stream')]);
g.scanHikReplies(); eq([JSON.parse(g._props.HIKR_mA).kind, JSON.parse(g._props.HIKR_mA).code], ['code', 'ZZ99ZZ99'], 'over-2MB and .exe attachments ignored; falls back to the code');
console.log('hikrelay: ' + pass + ' ok');
