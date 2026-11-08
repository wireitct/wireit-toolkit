/**
 * HikRelay.gs - WireIt Toolkit 2.2.0: Hikvision's password-reset replies, handed to the site boxes by serial.
 *
 * Runs as its own Apps Script project on the accounting@wireitct.com Google account, where hikreset@wireitct.com is an alias.
 * Site boxes keep NO mail password and use NO IMAP: they POST {op:'hikReplyGet', key, serial, shortSerial, pc} here over HTTPS
 * with the same upload key they already use for the service log (STATUS_PUSH_KEY), and get the reply file (base64) or the code once.
 *
 *  - scanHikReplies() runs on a time trigger (every 5 minutes, made by setupHikRelay()). It searches mail sent to the reset address,
 *    takes each reply's attachment (the unlock file) or, with no attachment, an 8-character code in the mail text, finds the device
 *    serial(s) the mail names, keeps the file in a private Drive folder and files the reply by serial (Script Properties).
 *  - doPost answers hikReplyGet: a reply for that serial is served once; for 15 minutes after that the same box can fetch it again
 *    (a dropped connection), then it is gone for the boxes (it stays in Gmail and Drive for 30 days).
 *  - Wrong keys: 1 s pause each; 20 wrong keys in 10 minutes and every request is refused for 10 minutes.
 *
 * Hikvision's reply format is NOT verified yet (attachment vs code in the text). Both are handled; anything the scan cannot match
 * to a serial is listed by unmatchedHikReplies() and the techs still have the "I got Hik's email" button.
 *
 * DEPLOY (by hand, once; nothing here deploys itself):
 *  1. Gmail admin: add hikreset@wireitct.com as an alias of accounting@wireitct.com (mail to it lands in accounting@'s inbox).
 *  2. Signed in as accounting@, script.google.com > New project "WireIt Hik relay"; paste this file as Code.gs.
 *  3. Project Settings > Script Properties: STATUS_PUSH_KEY = the same value as in the WireIt Service Log project
 *     (the key the site boxes already hold in secrets\upload-key.bin); optional HIK_ADDRESS if not hikreset@wireitct.com.
 *  4. Run setupHikRelay once from the editor; approve Gmail (read), Drive and trigger access for accounting@.
 *  5. Deploy > New deployment > Web app: Execute as Me (accounting@), Who has access: Anyone. Copy the /exec URL.
 *  6. Check: open the /exec URL in a browser -> {"ok":true,"app":"WireIt Hik relay"}.
 *  7. On each site box, config.json: "hikReset": {"relay": {"url": "<the /exec URL>", "address": "hikreset@wireitct.com", "everySec": 60}, "waitMinutes": 15}.
 *  8. First real reply: run unmatchedHikReplies in the editor; if Hik's mail was not matched, adjust hrSerials_/hrCode_.
 *
 * Script Properties: STATUS_PUSH_KEY (copy of the service-log one; required), HIK_ADDRESS (default hikreset@wireitct.com),
 * HIK_FOLDER_ID (made by setupHikRelay). Records: HIKR_<message id> (JSON). Nothing is deployed by the Toolkit; see the deploy steps.
 */
var HR = {
  ADDRESS: 'hikreset@wireitct.com', FOLDER: 'WireIt Hik replies (relay)', KEEP_DAYS: 30, GRACE_MS: 15 * 60 * 1000,
  MAX_BYTES: 2 * 1024 * 1024, SEARCH_DAYS: 7, BAD_KEY_MAX: 20, BAD_KEY_WINDOW_S: 600, EVERY_MIN: 5,
  PAGE: 50, MAX_THREADS: 500, VALID_H: 48, TRUSTED: 'hikvision.com'
};
/** 2.2.3 (Codex #50): only mail from Hikvision (or a sender the admin names in Script Property HIK_TRUSTED_SENDERS, comma list of
 *  addresses or domains) is filed. A reply from anyone else is kept as 'untrusted' for unmatchedHikReplies and never served. */
function hrTrusted_(from) {
  var m = /<([^>]+)>/.exec(String(from || '')), addr = String(m ? m[1] : from || '').trim().toLowerCase(), dom = addr.split('@')[1] || '';
  if (!dom) return false;
  var list = (HR.TRUSTED + ',' + String(hrProps_().getProperty('HIK_TRUSTED_SENDERS') || '')).toLowerCase().split(',').map(function (s) { return s.trim(); }).filter(Boolean);
  return list.some(function (t) { return t.indexOf('@') >= 0 ? addr === t : (dom === t || dom.slice(-(t.length + 1)) === '.' + t); });
}

function hrProps_() { return PropertiesService.getScriptProperties(); }
function hrAddress_() { var a = String(hrProps_().getProperty('HIK_ADDRESS') || '').trim(); return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(a) ? a : HR.ADDRESS; }
function hrJson_(o) { return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON); }

/** One-time setup, run by hand from the editor as accounting@: the Drive folder and the 5-minute trigger. Safe to run again. */
function setupHikRelay() {
  var p = hrProps_();
  if (!String(p.getProperty('STATUS_PUSH_KEY') || '')) throw new Error('Set Script Property STATUS_PUSH_KEY first (copy it from the WireIt Service Log project).');
  var id = p.getProperty('HIK_FOLDER_ID'), ok = false;
  if (id) { try { DriveApp.getFolderById(id).getName(); ok = true; } catch (e) { ok = false; } }
  if (!ok) { id = DriveApp.createFolder(HR.FOLDER).getId(); p.setProperty('HIK_FOLDER_ID', id); }
  var have = ScriptApp.getProjectTriggers().some(function (t) { return t.getHandlerFunction() === 'scanHikReplies'; });
  if (!have) ScriptApp.newTrigger('scanHikReplies').timeBased().everyMinutes(HR.EVERY_MIN).create();
  return { ok: true, folder: id, address: hrAddress_(), trigger: have ? 'already there' : 'made' };
}

/** Upper-case serial-looking words, including the slash in NVR model names, with both letters and digits. */
function hrSerials_(text) {
  var out = {}, m, re = /[A-Za-z0-9][A-Za-z0-9/-]{7,126}[A-Za-z0-9]/g;
  text = String(text || '');
  while ((m = re.exec(text)) !== null) { var w = m[0].toUpperCase(); if (/[A-Z]/.test(w) && /\d/.test(w)) out[w] = 1; }
  return Object.keys(out);
}
/** Same pattern as the Toolkit's Get-HikCodeFromText. */
function hrCode_(text) {
  // 2.2.3 (Codex #53): same rule as the laptop: "code:" / "code is" before it, and the code has a digit ("the code provided" is prose)
  var re = /(?:^|[^A-Za-z])(?:(?:verification|security|reset|unlock)\s+)?(?:code|key)\s*(?:is\s*[:\uFF1A]?|[:\uFF1A])\s*([A-Za-z0-9]{8})(?![A-Za-z0-9])/gi, m;
  text = String(text || '');
  while ((m = re.exec(text)) !== null) { if (/\d/.test(m[1])) return m[1]; }
  return '';
}
function hrUsableAttachment_(a) {
  var ct = String(a.getContentType() || '').toLowerCase(), n = String(a.getName() || '');
  // 2.2.3 (Codex #52): the same rule as the laptop: never a picture, PDF, office document or web page (a cover letter is not the unlock file)
  if (/^image\//.test(ct) || /^(application\/pdf|text\/html)/.test(ct) || /\.(png|jpe?g|gif|bmp|tiff?|webp|ico|svg|pdf|html?|docx?|xlsx?|exe|bat|cmd|ps1|vbs|js|scr|msi|lnk)$/i.test(n)) return false;
  var sz = a.getSize ? a.getSize() : a.getBytes().length;
  return sz > 0 && sz <= HR.MAX_BYTES;
}

/** The time trigger. Files every new reply by serial. Returns counts (for the editor and the tests). */
function scanHikReplies() {
  var lock = LockService.getScriptLock(); if (!lock.tryLock(20000)) return { ok: false, msg: 'busy' };
  try {
    var p = hrProps_(), all = p.getProperties(), now = Date.now(), filed = 0, unmatched = 0, seen = 0;
    var folderId = p.getProperty('HIK_FOLDER_ID'); var folder = folderId ? DriveApp.getFolderById(folderId) : null;
    var q = 'to:(' + hrAddress_() + ') newer_than:' + HR.SEARCH_DAYS + 'd';
    // 2.2.3 (Codex #55): every page of the search, not only the newest 50 threads (old processed threads no longer starve new ones)
    var threads = [];
    for (var start = 0; start < HR.MAX_THREADS; start += HR.PAGE) { var pg = GmailApp.search(q, start, HR.PAGE) || []; threads = threads.concat(pg); if (pg.length < HR.PAGE) break; }
    for (var t = 0; t < threads.length; t++) {
      var msgs = threads[t].getMessages();
      for (var i = 0; i < msgs.length; i++) {
        var msg = msgs[i], mid = String(msg.getId()), key = 'HIKR_' + mid;
        if (all[key]) { seen++; continue; }
        var from = String(msg.getFrom() || '');
        if (from.toLowerCase().indexOf(hrAddress_().toLowerCase()) >= 0) { p.setProperty(key, JSON.stringify({ skip: 'own', at: now })); continue; }
        if (!hrTrusted_(from)) { p.setProperty(key, JSON.stringify({ at: now, kind: 'untrusted', from: from.slice(0, 120), subject: String(msg.getSubject() || '').slice(0, 200), receivedAt: new Date(msg.getDate()).toISOString(), serials: [] })); unmatched++; continue; }
        var subject = String(msg.getSubject() || ''), body = String(msg.getPlainBody() || '');
        var atts = (msg.getAttachments() || []).filter(hrUsableAttachment_);
        var names = atts.map(function (a) { return String(a.getName() || ''); }).join(' ');
        var serials = hrSerials_(subject + ' ' + body + ' ' + names);
        var rec = { at: now, receivedAt: new Date(msg.getDate()).toISOString(), subject: subject.slice(0, 200), serials: serials, servedAt: 0, servedTo: '' };
        if (atts.length) {
          // Each attachment has its own serials and delivery receipt. Never hand the first device's file to all serials in a mail.
          var replies = atts.map(function (a, index) {
            var own = hrSerials_(String(a.getName() || ''));
            if (!own.length && a.getDataAsString) { try { own = hrSerials_(a.getDataAsString()); } catch (err) {} }
            if (!own.length && atts.length === 1) own = serials;
            var item = { at: now, receivedAt: rec.receivedAt, subject: rec.subject, serials: own, servedAt: 0, servedTo: '', kind: 'file', name: String(a.getName() || 'reply.bin').replace(/[^A-Za-z0-9._-]/g, '_').slice(0, 100) };
            if (folder) { var f = folder.createFile(a.copyBlob ? a.copyBlob() : a); f.setName(((atts.length === 1 ? serials[0] : own[0]) || 'UNMATCHED') + '__' + mid + '__' + (atts.length > 1 ? index + '__' : '') + item.name); item.fileId = f.getId(); }
            else item.data = Utilities.base64Encode(a.getBytes());
            return item;
          });
          // Keep the single-file record shape compatible with already deployed clients and stored records.
          if (replies.length === 1) rec = replies[0];
          else { rec.kind = 'files'; rec.items = replies; rec.serials = [].concat.apply([], replies.map(function (x) { return x.serials; })); }
        } else {
          var code = hrCode_(subject + '\n' + body);
          if (!code) { rec.kind = 'none'; }
          else { rec.kind = 'code'; rec.code = code; }
        }
        // a code word is not a serial
        if (rec.code) rec.serials = rec.serials.filter(function (s) { return s !== rec.code.toUpperCase(); });
        if (rec.kind === 'none' || !rec.serials.length || (rec.items || []).some(function (x) { return !x.serials.length; })) unmatched++; else filed++;
        p.setProperty(key, JSON.stringify(rec));
      }
    }
    // forget records past KEEP_DAYS (their Drive copy goes to the bin; Gmail keeps the mail)
    for (var k in all) {
      if (k.indexOf('HIKR_') !== 0) continue;
      var r = null; try { r = JSON.parse(all[k]); } catch (e) { r = null; }
      if (r && now - Number(r.at || 0) > HR.KEEP_DAYS * 86400000) { [r].concat(r.items || []).forEach(function (x) { if (x.fileId) { try { DriveApp.getFileById(x.fileId).setTrashed(true); } catch (e2) {} } }); p.deleteProperty(k); }
    }
    return { ok: true, filed: filed, unmatched: unmatched, seen: seen };
  } finally { lock.releaseLock(); }
}

/** For Moshe in the editor: replies the scan could not tie to a serial (forward the mail to a tech; the button takes it). */
function unmatchedHikReplies() {
  var all = hrProps_().getProperties(), out = [];
  for (var k in all) { if (k.indexOf('HIKR_') !== 0) continue; try { var r = JSON.parse(all[k]); if (!r.skip && (r.kind === 'none' || r.kind === 'untrusted' || !(r.serials || []).length || (r.items || []).some(function (x) { return !x.serials.length; }))) out.push({ subject: r.subject, receivedAt: r.receivedAt, kind: r.kind, from: r.from || '' }); } catch (e) {} }
  return out;
}

function hrSerialMatch_(rec, serial, shortSerial) {
  var s = String(serial || '').toUpperCase(), ss = String(shortSerial || '').toUpperCase();
  return (rec.serials || []).some(function (w) { return (s && w === s) || (ss.length >= 8 && (w === ss || w.slice(-ss.length) === ss)) || (s.length >= 9 && w.length >= 9 && s.slice(-w.length) === w); });
}
function hrBadKey_() {
  var c = CacheService.getScriptCache(), n = Number(c.get('hr_bad') || 0) + 1; c.put('hr_bad', String(n), HR.BAD_KEY_WINDOW_S); Utilities.sleep(1000);
  return { ok: false, msg: 'Wrong key.' };
}

/** POST {op:'hikReplyGet', key, serial, shortSerial, pc} -> {ok,found:false} | {ok,found:true,kind:'file',data,name,...} | {ok,found:true,kind:'code',code,...} | {ok:false,msg} */
function hikReplyGet_(req) {
  var cache = CacheService.getScriptCache();
  var want = String(hrProps_().getProperty('STATUS_PUSH_KEY') || ''), k = String(req.key || '');
  // 2.2.3 (Codex #54): the right key always gets in. The wrong-key count only slows and then refuses WRONG keys, so strangers
  // sending bad keys cannot lock the site boxes out.
  if (!want || k.length !== want.length || k !== want) {
    if (Number(cache.get('hr_bad') || 0) >= HR.BAD_KEY_MAX) { Utilities.sleep(1000); return { ok: false, msg: 'Too many wrong keys - try again in 10 minutes.' }; }
    return hrBadKey_();
  }
  var serial = String(req.serial || ''), ss = String(req.shortSerial || ''), pc = String(req.pc || '').replace(/[^A-Za-z0-9._-]/g, '').slice(0, 40);
  if (!/^[A-Za-z0-9][A-Za-z0-9/._-]{3,127}$/.test(serial) || (ss && !/^[A-Za-z0-9-]{4,64}$/.test(ss))) return { ok: false, msg: 'Bad serial.' };
  // 2.2.3 (Codex #51): only a reply that came AFTER this box's request file was made (and inside its 48 hours) answers it
  var nowMs = Date.now(), since = Date.parse(String(req.exportedAt || ''));
  if (isNaN(since)) since = nowMs - HR.VALID_H * 3600000;
  since = Math.max(since - 10 * 60000, nowMs - HR.VALID_H * 3600000);   // 10 min of clock skew between the PC and Google
  var lock = LockService.getScriptLock(); if (!lock.tryLock(15000)) return { ok: false, msg: 'Busy - try again in a minute.' };
  try {
    var p = hrProps_(), all = p.getProperties(), now = Date.now(), best = null, bestKey = '', bestRecord = null;
    for (var key in all) {
      if (key.indexOf('HIKR_') !== 0) continue;
      var r = null; try { r = JSON.parse(all[key]); } catch (e) { continue; }
      if (!r || r.skip) continue;
      var candidates = r.kind === 'files' ? (r.items || []) : [r];
      for (var ci = 0; ci < candidates.length; ci++) {
        var candidate = candidates[ci];
        if ((candidate.kind !== 'file' && candidate.kind !== 'code') || !hrSerialMatch_(candidate, serial, ss)) continue;
        if (!(Date.parse(String(candidate.receivedAt || '')) >= since)) continue;
        if (candidate.servedAt && (now - candidate.servedAt > HR.GRACE_MS || (candidate.servedTo && candidate.servedTo !== pc))) continue;
        if (!best || String(candidate.receivedAt) > String(best.receivedAt)) { best = candidate; bestKey = key; bestRecord = r; }
      }
    }
    if (!best) return { ok: true, found: false };
    var out = { ok: true, found: true, kind: best.kind, subject: best.subject, receivedAt: best.receivedAt };
    if (best.kind === 'code') out.code = best.code;
    else { out.name = best.name; out.data = best.fileId ? Utilities.base64Encode(DriveApp.getFileById(best.fileId).getBlob().getBytes()) : best.data; }
    if (!best.servedAt) { best.servedAt = now; best.servedTo = pc; p.setProperty(bestKey, JSON.stringify(bestRecord)); }
    console.log('hikReplyGet served ' + best.kind + ' for ' + serial.slice(-9) + ' to ' + pc);
    return out;
  } finally { lock.releaseLock(); }
}

function doPost(e) {
  var req = {};
  try { req = JSON.parse((e && e.postData && e.postData.contents) || '{}') || {}; } catch (err) { req = {}; }
  var r;
  try { r = (req.op === 'hikReplyGet') ? hikReplyGet_(req) : { ok: false, msg: 'Unknown op.' }; }
  catch (err) { console.error(String(err && err.message || err)); r = { ok: false, msg: 'Relay error.' }; }
  return hrJson_(r);
}
function doGet() { return hrJson_({ ok: true, app: 'WireIt Hik relay' }); }
