// HikRelay.gs tests (no Google): node appsscript/tests/hikrelay.test.js
const assert = require('assert'), fs = require('fs'), path = require('path'), vm = require('vm');
let pass = 0; const ok = (c, m) => { assert(c, m); pass++; }; const eq = (a, b, m) => { assert.deepStrictEqual(a, b, m); pass++; };
function env() {
  const props = {}, cache = {}, files = {}, trig = []; let fileN = 0, NOW = Date.parse('2026-11-08T15:00:00Z'), mails = [], slept = 0;
  // getDataAsString: Gmail attachments are Blobs, and the relay reads their text with it (2.2.6: the tests left it out)
  const blob = (name, bytes, type) => ({ getName: () => name, getBytes: () => Buffer.from(bytes), getSize: () => Buffer.from(bytes).length, getContentType: () => type, getDataAsString: () => Buffer.from(bytes).toString('latin1'), copyBlob() { return this; } });
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
  vm.createContext(g); vm.runInContext(fs.readFileSync(process.env.HIKRELAY_GS || path.join(__dirname, '..', 'HikRelay.gs'), 'utf8'), g);   // HIKRELAY_GS (tests only): another copy, for the old-code proof
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

// Full NVR serials contain model punctuation. The client must not have to remove it.
g = env(); g._props.STATUS_PUSH_KEY = KEY; g.setupHikRelay();
const nvrSerial = 'DS-7608NI-K2/8P20210505CCWRF99887766';
g._mail('slash', 'support@hikvision.com', 'Reset ' + nvrSerial, 'code: AB12CD34', []); g.scanHikReplies();
a = g._post({op:'hikReplyGet',key:KEY,serial:nvrSerial,shortSerial:'F99887766',pc:'NVRPC'});
eq([a.ok,a.found,a.code],[true,true,'AB12CD34'],'full NVR serial with slash is accepted unchanged');

// One email, two devices: a file and a delivery receipt for each device, including different PCs.
g = env(); g._props.STATUS_PUSH_KEY = KEY; g.setupHikRelay();
const ser2 = 'DS-2CD2143G2-I20230101AAWRK87654321';
g._mail('two', 'support@hikvision.com', 'Reset '+SER+' and '+ser2, 'Two files', [g._blob('reset_'+SS+'.xml','UNLOCK-A','application/xml'),g._blob('reset_K87654321.xml','UNLOCK-B','application/xml')]);
g.scanHikReplies();
a = g._post({op:'hikReplyGet',key:KEY,serial:SER,shortSerial:SS,pc:'A'});
eq(Buffer.from(a.data,'base64').toString(),'UNLOCK-A','first device receives its own attachment');
a = g._post({op:'hikReplyGet',key:KEY,serial:ser2,shortSerial:'K87654321',pc:'B'});
eq(Buffer.from(a.data,'base64').toString(),'UNLOCK-B','second device on another PC receives its own attachment');
a = g._post({op:'hikReplyGet',key:KEY,serial:SER,shortSerial:SS,pc:'A'});
eq(Buffer.from(a.data,'base64').toString(),'UNLOCK-A','retry remains per attachment');
a = g._post({op:'hikReplyGet',key:KEY,serial:SER,shortSerial:SS,pc:'C'});
eq(a.found,false,'another PC cannot claim an attachment already served');
g._now(g._t()+31*86400000); g.scanHikReplies();
ok(Object.values(g._files).every(f=>f.trashed),'expiry removes every file in a multiple-attachment record');
g = env(); g._props.STATUS_PUSH_KEY = KEY; g.setupHikRelay();
g._mail('ambiguous', 'support@hikvision.com', 'Reset '+SER+' and '+ser2, 'Two files', [g._blob('one.xml','UNLOCK-A','application/xml'),g._blob('two.xml','UNLOCK-B','application/xml')]);
g.scanHikReplies();
a = g._post({op:'hikReplyGet',key:KEY,serial:SER,shortSerial:SS,pc:'A'});
eq(a.found,false,'multiple attachments with no individual serial are never guessed');
eq(g.unmatchedHikReplies().length,1,'ambiguous attachments remain visible for manual handling');
eq(Array.from(g.hrSerials_(nvrSerial)),[nvrSerial],'the complete slash serial is extracted without splitting it');
// 2.2.6 (Codex file-by-file B): words in the attachment that look like serials (a date in the file name, encrypted content) must not
// stop a valid single-file reply from matching the device the mail names
g = env(); g._props.STATUS_PUSH_KEY = KEY; g.setupHikRelay();
g._mail('date', 'support@hikvision.com', 'Password reset for device ' + SER, 'Please import the attached file.', [g._blob('reply-20261108T1500.xml', '<xml>unlock-date</xml>', 'application/xml')]);
g.scanHikReplies();
a = g._post({op:'hikReplyGet',key:KEY,serial:SER,shortSerial:SS,pc:'A'});
eq([a.found, a.found && Buffer.from(a.data,'base64').toString()], [true, '<xml>unlock-date</xml>'], 'reproduction: a date-like attachment name does not stop the single file from matching its device');
g = env(); g._props.STATUS_PUSH_KEY = KEY; g.setupHikRelay();
const enc = 'U2FsdGVkX19aB3cD4eF5gH6iJ7kL8mN9oP0qR1sT2uV3wX4yZ5Ab7Cd9Ef1Gh3Ij5Kl7Mn9Op1Qr3St5Uv7Wx9Yz';
g._mail('enc', 'support@hikvision.com', 'Password reset for device ' + SER, 'Please import the attached file.', [g._blob('unlock.bin', enc, 'application/octet-stream')]);
g.scanHikReplies();
a = g._post({op:'hikReplyGet',key:KEY,serial:SER,shortSerial:SS,pc:'A'});
eq([a.found, a.found && Buffer.from(a.data,'base64').toString()], [true, enc], 'reproduction: encrypted attachment text does not stop the single file from matching its device');
eq(g.unmatchedHikReplies().length, 0, '...and it is not listed as unmatched');
g = env(); g._props.STATUS_PUSH_KEY = KEY; g.setupHikRelay();
g._mail('two-content', 'support@hikvision.com', 'Reset '+SER+' and '+ser2, 'Two files', [g._blob('a.xml','<dev>'+SS+'</dev> UNLOCK-A','application/xml'),g._blob('b.xml','<dev>K87654321</dev> UNLOCK-B','application/xml')]);
g.scanHikReplies();
a = g._post({op:'hikReplyGet',key:KEY,serial:ser2,shortSerial:'K87654321',pc:'B'});
eq(Buffer.from(a.data,'base64').toString(),'<dev>K87654321</dev> UNLOCK-B','two files: each is matched by the device its content names');

// ---- 2.2.19 (sweep2): a failed property / Drive read is not "no reply"; nothing is marked used or deleted unless it really worked ----
// These checks count failures instead of stopping, so the old-code run (HIKRELAY_GS=<2.2.18 HikRelay.gs>) shows each one failing.
let softFail = 0; const soft = (c, m) => { if (c) { pass++; console.log('PASS ' + m); } else { softFail++; console.log('FAIL ' + m); } };
const tryRun = f => { try { return { v: f() }; } catch (e) { return { err: String(e && e.message || e) }; } };
const fresh = () => { const h = env(); h._props.STATUS_PUSH_KEY = KEY; h.setupHikRelay(); return h; };
// 1. a damaged stored record and no other reply: NOT CHECKED, never "no reply"
g = fresh(); g._props.HIKR_bad = '{not json';
a = g._post({ op: 'hikReplyGet', key: KEY, serial: SER, shortSerial: SS, pc: 'A' });
soft(a.ok === false && /could not be read/.test(a.msg || ''), 'sweep2 relay: a damaged stored record is NOT CHECKED (ok:false), not "no reply" (found:false)');
soft(g.unmatchedHikReplies().some(x => x.kind === 'damaged'), 'sweep2 relay: unmatchedHikReplies lists the damaged record (it was skipped without a word)');
// control: a damaged record does not stop a real reply for this device
g._mail('ok1', 'Hikvision <noreply@hikvision.com>', 'Password reset for device ' + SER, 'Please import the attached file.', [g._blob('reset.xml', '<xml>good</xml>', 'application/xml')]);
g.scanHikReplies();
a = g._post({ op: 'hikReplyGet', key: KEY, serial: SER, shortSerial: SS, pc: 'A' });
soft(a.ok === true && a.found === true && Buffer.from(a.data, 'base64').toString() === '<xml>good</xml>', 'sweep2 relay control: a damaged record beside a real reply still hands out the real reply');
// 2. the stored Drive file reads back empty: not handed out, not marked as given to this PC
g = fresh();
g._mail('e1', 'Hikvision <noreply@hikvision.com>', 'Password reset for device ' + SER, 'Please import the attached file.', [g._blob('reset.xml', '<xml>x</xml>', 'application/xml')]);
g.scanHikReplies();
{ const rec = JSON.parse(g._props.HIKR_e1); g._files[rec.fileId].bytes = Buffer.from(''); }
a = g._post({ op: 'hikReplyGet', key: KEY, serial: SER, shortSerial: SS, pc: 'A' });
soft(a.ok === false, 'sweep2 relay: a stored reply file that reads back empty is refused (ok:false), not handed out as a reply');
soft(!JSON.parse(g._props.HIKR_e1).servedAt, '...and it is NOT marked as given to this PC (another PC / a later try can still get the real file)');
// 2b. the Drive read itself fails: an error answer, and not marked used
g = fresh();
g._mail('e2', 'Hikvision <noreply@hikvision.com>', 'Password reset for device ' + SER, 'x', [g._blob('reset.xml', '<xml>y</xml>', 'application/xml')]);
g.scanHikReplies();
{ const real = g.DriveApp.getFileById; g.DriveApp.getFileById = id => { throw new Error('Drive is not answering'); };
  a = g._post({ op: 'hikReplyGet', key: KEY, serial: SER, shortSerial: SS, pc: 'A' }); g.DriveApp.getFileById = real; }
soft(a.ok === false && !JSON.parse(g._props.HIKR_e2).servedAt, 'sweep2 relay control: a Drive read that fails answers ok:false and leaves the reply unmarked');
// 3. scan: one mail whose Drive copy cannot be made is not filed and not marked seen; the other mail is filed; the scan says it failed
g = fresh();
g._mail('d1', 'Hikvision <noreply@hikvision.com>', 'Password reset for device ' + SER, 'x', [g._blob('broken.xml', '<xml>1</xml>', 'application/xml')]);
g._mail('d2', 'support@hikvision.com', 'Re: reset request serial DS-7608NI-K2/8P20210505CCWRF99887766', 'Your verification code: AB12CD34', []);
{ const realFolder = g.DriveApp.getFolderById; g.DriveApp.getFolderById = id => { const f = realFolder(id); return { getName: f.getName, createFile: b => { if (b.getName() === 'broken.xml') throw new Error('Drive quota'); return f.createFile(b); } }; };
  r = tryRun(() => g.scanHikReplies()); g.DriveApp.getFolderById = realFolder; }
soft(!r.err && r.v.ok === false && r.v.failed === 1, 'sweep2 relay: a scan where one mail could not be kept says so (ok:false, failed 1) instead of stopping', JSON.stringify(r));
soft(!g._props.HIKR_d1, '...that mail is NOT marked seen, so the next scan files it');
soft(!!g._props.HIKR_d2 && JSON.parse(g._props.HIKR_d2).code === 'AB12CD34', '...and the other mail in the same scan is still filed');
r = tryRun(() => g.scanHikReplies());
soft(!r.err && r.v.ok === true && !!g._props.HIKR_d1, '...the next scan (Drive working again) files it');
// 4. scan: the record save fails after the Drive copy was made: the copy goes back to the bin (no orphan), the mail is tried again
g = fresh();
g._mail('s1', 'Hikvision <noreply@hikvision.com>', 'Password reset for device ' + SER, 'x', [g._blob('reset.xml', '<xml>2</xml>', 'application/xml')]);
{ const realPS = g.PropertiesService.getScriptProperties; g.PropertiesService.getScriptProperties = () => { const o = realPS(); const sp = o.setProperty; o.setProperty = (k, v) => { if (k === 'HIKR_s1') throw new Error('property store full'); sp(k, v); }; return o; };
  r = tryRun(() => g.scanHikReplies()); g.PropertiesService.getScriptProperties = realPS; }
soft(!r.err && r.v.ok === false && !g._props.HIKR_s1 && Object.values(g._files).every(f => f.trashed), 'sweep2 relay: a record that could not be saved leaves no Drive copy behind (it went back to the bin) and is not marked seen', JSON.stringify(r));
// 5. clean-up after 30 days: the record stays when its Drive copy could not be put in the bin
g = fresh();
g._mail('o1', 'Hikvision <noreply@hikvision.com>', 'Password reset for device ' + SER, 'x', [g._blob('reset.xml', '<xml>3</xml>', 'application/xml')]);
g.scanHikReplies();
g._now(g._t() + 31 * 86400000);
{ const real = g.DriveApp.getFileById; g.DriveApp.getFileById = id => ({ setTrashed: () => { throw new Error('Drive is not answering'); } });
  r = tryRun(() => g.scanHikReplies()); g.DriveApp.getFileById = real; }
soft(!r.err && !!g._props.HIKR_o1, 'sweep2 relay: an old record whose Drive copy could not be put in the bin is KEPT (tried again), not deleted');
r = tryRun(() => g.scanHikReplies());
soft(!r.err && !g._props.HIKR_o1, 'sweep2 relay: once the Drive copy does go to the bin, the old record is removed');
if (softFail) { console.log('hikrelay sweep2: ' + softFail + ' FAILED'); process.exitCode = 1; }
console.log('hikrelay total: ' + pass + ' ok' + (softFail ? ' (' + softFail + ' failed)' : ''));
