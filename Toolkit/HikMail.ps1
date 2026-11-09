<#
 HikMail.ps1 - WireIt Toolkit 2.2: catch Hikvision's reply (the unlock file or code) and match it to the device it belongs to.
 2.2.0 (Moshe, Nov 7 2026, 8:06 PM): NO mail password on any site box and no IMAP from the box. Two ways, both automatic:
   relay  - the Toolkit asks WireIt's reply relay over HTTPS: {op:'hikReplyGet', key, serial} -> the reply file (base64) or the code, or "none".
            The relay is a small Apps Script (appsscript/HikRelay.gs) on the WireIt Gmail account, where hikreset@wireitct.com arrives.
            config.json "hikReset.relay": { "url": "https://script.google.com/macros/s/.../exec", "address": "hikreset@wireitct.com" }.
            The key is this PC's upload key ("Set upload key.cmd", the same push key Find cameras uses). No url = relay off.
   folder - drop folders: the replies folder of the reset, and inbox\hik (the "I got Hik's email" button saves the dragged file or the pasted code there).
 A reply is matched to a device by the device's serial (full or the 9-character short one) or MAC in the file's name or content.
 A file that matches nothing is listed as "unmatched" and is never sent to any device.
 Test harness: tests\hikreset\mock_relay.py (plain http on 127.0.0.1).
#>
function Hm-Latin1 { return [Text.Encoding]::GetEncoding(28591) }
# ---------------- MIME ----------------
function Hm-DecodeWord([string]$s) {
  return [regex]::Replace($s, '=\?([^?]+)\?([bBqQ])\?([^?]*)\?=', { param($m)
    try { $enc = [Text.Encoding]::GetEncoding($m.Groups[1].Value) } catch { $enc = [Text.Encoding]::UTF8 }
    if ($m.Groups[2].Value -match '[bB]') { return $enc.GetString([Convert]::FromBase64String($m.Groups[3].Value)) }
    $q = $m.Groups[3].Value.Replace('_', ' '); $b = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -lt $q.Length; $i++) { if ($q[$i] -eq '=' -and $i + 2 -lt $q.Length + 0 -and $q.Substring($i + 1, 2) -match '^[0-9A-Fa-f]{2}$') { $b.Add([Convert]::ToByte($q.Substring($i + 1, 2), 16)); $i += 2 } else { $b.Add([byte][char]$q[$i]) } }
    return $enc.GetString($b.ToArray()) })
}
function Hm-Headers([string]$block) {
  $h = @{}; $cur = ''
  foreach ($l in ($block -split "`r?`n")) {
    if ($l -match '^[ \t]+' -and $cur) { $h[$cur] = $h[$cur] + ' ' + $l.Trim(); continue }
    $m = [regex]::Match($l, '^([^:\s]+):\s*(.*)$'); if ($m.Success) { $cur = $m.Groups[1].Value.ToLower(); $h[$cur] = $m.Groups[2].Value }
  }
  return $h
}
function Hm-Param([string]$hdr, [string]$name) {
  $m = [regex]::Match($hdr, '(?i)\b' + $name + '\*?=\s*(?:"([^"]*)"|([^;\s]+))'); if ($m.Success) { if ($m.Groups[1].Success) { return $m.Groups[1].Value } else { return $m.Groups[2].Value } }; return ''
}
function Hm-DecodeBody([string]$body, [string]$cte) {
  $l1 = Hm-Latin1
  switch -Regex ($cte.Trim().ToLower()) {
    'base64' { try { return [Convert]::FromBase64String(($body -replace '\s', '')) } catch { return $l1.GetBytes($body) } }
    'quoted-printable' {
      $t = $body -replace "=\r?\n", ''; $b = New-Object System.Collections.Generic.List[byte]; $raw = $l1.GetBytes($t)
      for ($i = 0; $i -lt $raw.Length; $i++) { if ($raw[$i] -eq 61 -and $i + 2 -lt $raw.Length) { $hx = [string][char]$raw[$i + 1] + [string][char]$raw[$i + 2]; if ($hx -match '^[0-9A-Fa-f]{2}$') { $b.Add([Convert]::ToByte($hx, 16)); $i += 2; continue } }; $b.Add($raw[$i]) }
      return $b.ToArray() }
    default { return $l1.GetBytes($body) }
  }
}
# returns { from; subject; date; text; attachments = @({ name; bytes; type }) }
function Read-MimeMessage([byte[]]$Raw) {
  $l1 = Hm-Latin1; $s = $l1.GetString($Raw)
  $msg = [pscustomobject]@{ from = ''; subject = ''; date = ''; text = ''; attachments = New-Object System.Collections.ArrayList }
  $walk = $null
  $walk = {
    param([string]$part, [bool]$top)
    $m = [regex]::Match($part, "\r?\n\r?\n"); if (-not $m.Success) { return }
    $hdr = Hm-Headers $part.Substring(0, $m.Index); $body = $part.Substring($m.Index + $m.Length)
    if ($top) { $msg.from = Hm-DecodeWord ([string]$hdr['from']); $msg.subject = Hm-DecodeWord ([string]$hdr['subject']); $msg.date = [string]$hdr['date'] }
    $ct = [string]$hdr['content-type']; if (-not $ct) { $ct = 'text/plain' }
    if ($ct -match '(?i)^multipart/') {
      $bd = Hm-Param $ct 'boundary'; if (-not $bd) { return }
      $parts = [regex]::Split($body, '\r?\n?--' + [regex]::Escape($bd) + '(?:--)?[ \t]*\r?\n?')
      foreach ($p in $parts) { if ($p.Trim().Length -gt 0) { & $walk ($p.TrimStart("`r", "`n")) $false } }
      return
    }
    $cd = [string]$hdr['content-disposition']
    $name = Hm-DecodeWord (Hm-Param $cd 'filename'); if (-not $name) { $name = Hm-DecodeWord (Hm-Param $ct 'name') }
    $bytes = Hm-DecodeBody $body ([string]$hdr['content-transfer-encoding'])
    if ($name -or $cd -match '(?i)attachment') { [void]$msg.attachments.Add([pscustomobject]@{ name = $(if ($name) { $name } else { 'attachment' }); bytes = $bytes; type = ($ct -split ';')[0] }) }
    elseif ($ct -match '(?i)^text/') { $cs = Hm-Param $ct 'charset'; try { $enc = $(if ($cs) { [Text.Encoding]::GetEncoding($cs) } else { [Text.Encoding]::UTF8 }) } catch { $enc = [Text.Encoding]::UTF8 }; $t = $enc.GetString($bytes); if ($ct -match '(?i)text/html') { $t = ($t -replace '(?is)<(script|style).*?</\1>', ' ') -replace '<[^>]+>', ' ' }; $msg.text += "`n" + $t }
  }
  & $walk $s $true
  $msg.attachments = @($msg.attachments)
  return $msg
}
# ---------------- the reply relay (HTTPS, no mail password on this PC) ----------------
# url must be https:// (http only to 127.0.0.1 / localhost, for the tests). Returns $true when the url may be used.
function Test-HikRelayUrl([string]$Url) {
  if (-not $Url) { return $false }
  try { $u = [Uri]$Url } catch { return $false }
  if (-not $u.IsAbsoluteUri) { return $false }
  if ($u.Scheme -eq 'https') { return $true }
  return ($u.Scheme -eq 'http' -and $u.Host -in @('127.0.0.1', 'localhost'))
}
# this PC's upload key (the push key). Same file and DPAPI scope as CamViews (secrets\upload-key.bin, LocalMachine). Never logged.
function Get-HikRelayKey([string]$ToolkitDir) {
  if ($env:WIREIT_UPLOAD_KEY) { return $env:WIREIT_UPLOAD_KEY }   # tests
  $c = @(@((Join-Path $ToolkitDir 'secrets\upload-key.bin'), 'WireIt-Toolkit-v1'), @((Join-Path (Split-Path -Parent $ToolkitDir) 'VendorMonitor\secrets\ingest.bin'), 'WireIt-VendorMonitor-v1'))
  foreach ($p in $c) {
    try {
      if (-not (Test-Path -LiteralPath $p[0])) { continue }
      Add-Type -AssemblyName System.Security
      $b = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($p[0]), [Text.Encoding]::ASCII.GetBytes($p[1]), [Security.Cryptography.DataProtectionScope]::LocalMachine)
      $k = [string]([Text.Encoding]::UTF8.GetString($b) | ConvertFrom-Json).key
      if ($k) { return $k }
    } catch {}
  }
  return ''
}
# one question to the relay for one device. Returns { state = 'found'|'none'|'failed'; msg; message (a pseudo mail with one attachment) }
function Get-HikRelayReply($Relay, [string]$Key, $Device, [int]$TimeoutSec = 20) {
  $url = [string]$Relay.url
  if (-not (Test-HikRelayUrl $url)) { return [pscustomobject]@{ state = 'failed'; msg = 'the relay address in config.json is not an https address'; message = $null } }
  if (-not $Key) { return [pscustomobject]@{ state = 'failed'; msg = 'this PC has no upload key yet (an admin runs "Set upload key.cmd" once)'; message = $null } }
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
  $body = [ordered]@{ op = 'hikReplyGet'; key = $Key; serial = [string]$Device.serial; shortSerial = [string]$Device.shortSerial; pc = [string]$env:COMPUTERNAME }
  # 2.2.3 (Codex #51): when this request file was made, so the relay answers only with a reply that came after it
  if ($Device.PSObject.Properties['exportedAt'] -and $Device.exportedAt) { try { $body.exportedAt = ([datetime]$Device.exportedAt).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch {} }
  $json = $body | ConvertTo-Json -Compress
  try {
    $r = Invoke-WebRequest -Uri $url -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'text/plain;charset=utf-8' -UseBasicParsing -TimeoutSec $TimeoutSec -UserAgent 'WireIt-Toolkit' -ErrorAction Stop
  } catch {
    $m = [string]$_.Exception.Message; if ($Key) { $m = $m.Replace($Key, '****') }
    if ($m.Length -gt 140) { $m = $m.Substring(0, 140) }
    return [pscustomobject]@{ state = 'failed'; msg = ('no answer from the relay: ' + $m); message = $null }
  }
  $a = $null; try { $a = [string]$r.Content | ConvertFrom-Json -ErrorAction Stop } catch { $a = $null }   # a sign-in page or an error page is not JSON
  if (-not $a -or -not $a.PSObject.Properties['ok']) { return [pscustomobject]@{ state = 'failed'; msg = 'the relay answered something unreadable'; message = $null } }
  if (-not $a.ok) { $m = $(if ($a.PSObject.Properties['msg']) { [string]$a.msg } else { 'refused' }); return [pscustomobject]@{ state = 'failed'; msg = ('the relay said: ' + $m); message = $null } }
  if (-not $a.found) { return [pscustomobject]@{ state = 'none'; msg = ''; message = $null } }
  $sn = ([string]$Device.serial) -replace '[^A-Za-z0-9\-]', '_'
  $att = $null
  if ([string]$a.kind -eq 'code') {
    $code = ([string]$a.code).Trim()
    if ($code -notmatch '^[A-Za-z0-9+/=_-]{4,64}$') { return [pscustomobject]@{ state = 'failed'; msg = 'the relay sent a code that does not look like Hikvision''s'; message = $null } }
    $att = [pscustomobject]@{ name = ('relay-' + $sn + '-code.txt'); bytes = [Text.Encoding]::ASCII.GetBytes($code); type = 'text/plain' }
  } else {
    $bytes = $null; try { $bytes = [Convert]::FromBase64String([string]$a.data) } catch {}
    if (-not $bytes -or $bytes.Length -eq 0 -or $bytes.Length -gt 2MB) { return [pscustomobject]@{ state = 'failed'; msg = 'the relay sent an empty or damaged file'; message = $null } }
    $nm = ([string]$a.name) -replace '[^A-Za-z0-9._-]', '_'; if (-not $nm) { $nm = 'reply.xml' }
    $att = [pscustomobject]@{ name = ('relay-' + $sn + '-' + $nm); bytes = $bytes; type = 'file' }
  }
  $msg = [pscustomobject]@{ from = 'relay'; subject = $(if ($a.PSObject.Properties['subject']) { [string]$a.subject } else { 'Hikvision reply' }); date = [string]$a.receivedAt; text = ''; attachments = @($att); id = ('relay:' + $Device.serial) }
  return [pscustomobject]@{ state = 'found'; msg = ''; message = $msg }
}
# ---------------- matching ----------------
# 2.2.8 (3 Hewlett, Nov 8 2026): Hikvision sent two "Reset Password" emails, one with the key file and one with none. Toolkit 2.1.0
# crashed on the empty one ("GetString ... Array cannot be null") and then said "matches no device here: (no serial or MAC of ours
# in it)", so the real file was never used. Every email and every attachment is now judged on its own, inside its own try: one that
# cannot be used is listed in "skipped" with a plain reason and never stops the others.
# A file Hikvision's reply can be: .xml (what Hik sends), a code in a .txt (the relay / the "I got Hik's email" button), or any
# other name whose contents are xml text or one code-like token. Everything else is "not an xml file".
$script:HikNotXmlName = '(?i)\.(png|jpe?g|gif|bmp|tiff?|webp|ico|svg|pdf|html?|docx?|xlsx?|pptx?|zip|rar|7z|exe|dll|bat|cmd|ps1|js|vbs|lnk|json|csv|mp4|mov)$'
function Test-HikReplyCandidate($a) {
  # returns '' when the attachment can be Hikvision's reply, else the reason (plain words)
  if ($null -eq $a) { return 'it has no attachment' }
  if ($null -eq $a.bytes) { return 'the file is empty' }
  $b = $null; if ($a.bytes -is [byte[]]) { $b = $a.bytes } else { try { $b = [byte[]]@($a.bytes) } catch { return 'the file could not be read' } }
  if ($b.Length -eq 0) { return 'the file is empty' }
  $nm = [string]$a.name; $ty = [string]$a.type
  if ($nm -match $script:HikNotXmlName -or $ty -match '(?i)^(image/|application/pdf|text/html|video/|audio/)') { return 'not an xml file' }
  if ($nm -match '(?i)\.xml$') { return '' }
  $t = (Hm-Latin1).GetString($b).Trim()
  if ($t -match '[\x00-\x08\x0E-\x1F]') { return 'not an xml file' }
  if ($nm -match '(?i)\.txt$') { if ($t -match '^[A-Za-z0-9+/=_-]{4,64}$') { return '' }; return 'a text file with no Hikvision code in it' }
  if ($t.StartsWith('<') -or ($t.Length -le 4000 -and $t -match '^\S+$')) { return '' }
  return 'not an xml file'
}
# a Hikvision serial named in a file name or its text: <model><yyyymmdd><4 letters><short serial>, e.g. ECI-T44F220220903AAWRK52336660
function Get-HikSerialsIn([string]$Text) {
  if (-not $Text) { return @() }
  $out = @(); foreach ($m in [regex]::Matches($Text, '(?i)(?<![A-Za-z0-9])([A-Z0-9][A-Z0-9-/]{1,30}?20\d{6}[A-Z]{4}[A-Z]\d{8})(?![0-9])')) { $v = $m.Groups[1].Value.ToUpper(); if ($out -notcontains $v) { $out += $v } }
  return @($out)
}
# WHY a file matched none of the devices waiting for a reply. $Known = every device this site's reset knows (any status).
function Get-HikUnmatchedWhy([string]$Name, [string]$Text, [string]$How, $Devices, $Known) {
  if ($How -eq 'ambiguous') { return 'it could belong to more than one device here' }
  $sers = @(Get-HikSerialsIn ([uri]::UnescapeDataString([string]$Name) + ' ' + [string]$Text))
  foreach ($s in $sers) {
    $k = $null; foreach ($d in @($Known)) { if ($d -and ([string]$d.serial).ToUpper() -eq $s) { $k = $d; break } }
    if ($k) { return ('it is for serial ' + $s + ' (' + [string]$k.model + ' ' + [string]$k.ip + '), which is on this site but not waiting for a reply (status: ' + [string]$k.status + ')') }
  }
  if ($sers.Count) { return ('it is for serial ' + $sers[0] + ', which is not on this site') }
  return 'no serial or MAC found in its name or contents'
}
# $Devices = state devices (serial, shortSerial, mac) waiting for a reply. $Known (optional) = all devices of the site, to say why a
# file matched none. Returns { matched = [{ device; name; bytes; how; mail; src; date }]; unmatched = [{ name; bytes; mail; why; src; date }];
#   skipped = [{ mail; src; name; why; date; quiet }] }  (quiet = an extra attachment beside a usable one, e.g. a logo: not said on screen)
function Find-HikReplyMatches($Devices, $Messages, $Known = $null) {
  $l1 = Hm-Latin1; $matches2 = @(); $un = @(); $sk = @()
  if ($null -eq $Known) { $Known = $Devices }
  foreach ($m in @($Messages)) {
    if ($null -eq $m) { continue }
    $subj = ''; $src = ''; $mdate = ''
    try { $subj = [string]$m.subject; if ($m.PSObject.Properties['mailSubject'] -and [string]$m.mailSubject) { $subj = [string]$m.mailSubject }; $src = [string]$m.id; $mdate = [string]$m.date } catch {}
    if ($m.PSObject.Properties['error'] -and [string]$m.error) { $sk += [pscustomobject]@{ mail = $subj; src = $src; name = ''; why = ('the email could not be read (' + [string]$m.error + ')'); date = $mdate; quiet = $false }; continue }
    try {
      $cands = @(); $bad = @()
      foreach ($a in @($m.attachments)) {
        if ($null -eq $a) { continue }
        $why = Test-HikReplyCandidate $a
        if ($why) { $bad += [pscustomobject]@{ mail = $subj; src = $src; name = [string]$a.name; why = $why; date = $mdate; quiet = $false }; continue }
        $cands += [pscustomobject]@{ name = [string]$a.name; bytes = $(if ($a.bytes -is [byte[]]) { $a.bytes } else { [byte[]]@($a.bytes) }); fromFile = $false }
      }
      if (-not $cands.Count -and -not $bad.Count) { $sk += [pscustomobject]@{ mail = $subj; src = $src; name = ''; why = 'it has no attachment'; date = $mdate; quiet = $false } }
      foreach ($x in $bad) { $x.quiet = [bool]$cands.Count; $sk += $x }
      foreach ($c in $cands) {
        try {
          $txt = $l1.GetString($c.bytes); $hit = $null; $how = ''
          $matchName = [uri]::UnescapeDataString([string]$c.name)
          foreach ($d in @($Devices)) {
            $sn = [string]$d.serial
            if ($sn -and ($matchName -like ('*' + $sn + '*') -or $txt -like ('*' + $sn + '*'))) { $hit = $d; $how = 'serial'; break }
          }
          if (-not $hit) { foreach ($d in @($Devices)) { $sh = [string]$d.shortSerial; if ($sh -and ($c.name -like ('*' + $sh + '*') -or $txt -like ('*' + $sh + '*'))) { if ($hit) { $hit = $null; $how = 'ambiguous'; break }; $hit = $d; $how = 'short serial' } } }
          if (-not $hit -and $how -ne 'ambiguous') { foreach ($d in @($Devices)) { $mac = ([string]$d.mac) -replace '[-:]', ''; if ($mac -and (($txt -replace '[-:]', '') -match ('(?i)' + $mac))) { $hit = $d; $how = 'MAC'; break } } }
          if (-not $hit -and $how -ne 'ambiguous' -and $m.text) {
            # 2.2.0: else the mail's own text (a code mail names the serial in its text, the attachment is only the code)
            $mt = [string]$m.text; $cnt = 0
            foreach ($d in @($Devices)) { $sn = [string]$d.serial; $sh = [string]$d.shortSerial; if (($sn -and $mt -like ('*' + $sn + '*')) -or ($sh -and $mt -like ('*' + $sh + '*'))) { $cnt++; $hit = $d; $how = 'serial in the mail text' } }
            if ($cnt -gt 1) { $hit = $null; $how = 'ambiguous' }
          }
          if ($hit) { $matches2 += [pscustomobject]@{ device = $hit; name = $c.name; bytes = $c.bytes; how = $how; mail = $subj; src = $src; date = $mdate } }
          else { $un += [pscustomobject]@{ name = $c.name; bytes = $c.bytes; mail = $subj; src = $src; date = $mdate; why = (Get-HikUnmatchedWhy $c.name $txt $how $Devices $Known) } }
        } catch { $sk += [pscustomobject]@{ mail = $subj; src = $src; name = [string]$c.name; why = ('the file could not be read (' + $_.Exception.Message + ')'); date = $mdate; quiet = $false } }
      }
    } catch { $sk += [pscustomobject]@{ mail = $subj; src = $src; name = ''; why = ('the email could not be read (' + $_.Exception.Message + ')'); date = $mdate; quiet = $false } }
  }
  return [pscustomobject]@{ matched = $matches2; unmatched = $un; skipped = $sk }
}
# a Hikvision code written in a mail's text (no attachment). Returns '' when there is none. UNVERIFIED: shape of Hik's code mail not seen yet.
# 2.2.2 (re-review M5): only a LABELLED code: "code" / "key" (optionally "verification", "security", "reset", "unlock" before it),
# then ":" or "is", then the code itself: 4-64 characters (the same as the relay accepts) with at least one digit. "the code provided"
# or "this code is valid" is no code (2.2.1 took any 8-letter word after "code").
function Get-HikCodeFromText([string]$Text) {
  if (-not $Text) { return '' }
  $rx = '(?i)(?<![A-Za-z])(?:(?:verification|security|reset|unlock)\s+)?(?:code|key)\s*(?:(?:is)\s*[:\uFF1A]?|[:\uFF1A])\s*([A-Za-z0-9+/=_-]{4,64})(?![A-Za-z0-9+/=_-])'
  foreach ($m in [regex]::Matches($Text, $rx)) { $c = $m.Groups[1].Value; if ($c -match '\d') { return $c } }
  return ''
}
# 2.2.3 (Codex #56): a ZIP in the drop folder is read in memory with hard limits - at most 20 entries, each at most 2 MB expanded
# and 5 MB in all (the size inside the archive is not trusted: reading stops at the limit). Nothing is written to disk.
$script:HikZipMaxEntries = 20; $script:HikZipMaxEntry = 2MB; $script:HikZipMaxTotal = 5MB
function Read-HikZipEntries([string]$Path) {
  $out = @(); $total = 0
  try { Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue; Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue } catch {}
  $zip = $null
  try {
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    if ($zip.Entries.Count -gt $script:HikZipMaxEntries) { return @() }
    foreach ($e in $zip.Entries) {
      if (-not $e.Name -or $e.FullName.EndsWith('/')) { continue }
      $s = $e.Open(); $ms = New-Object IO.MemoryStream; $buf = New-Object byte[] 65536; $n = 0; $too = $false
      try { while (($k = $s.Read($buf, 0, $buf.Length)) -gt 0) { $n += $k; if ($n -gt $script:HikZipMaxEntry -or ($total + $n) -gt $script:HikZipMaxTotal) { $too = $true; break }; $ms.Write($buf, 0, $k) } } finally { $s.Dispose() }
      if ($too) { return @() }   # one oversized entry = the whole archive is refused
      $total += $n; $out += [pscustomobject]@{ name = (($e.Name) -replace '[^A-Za-z0-9._-]', '_'); bytes = $ms.ToArray() }
    }
  } catch { return @() } finally { if ($zip) { $zip.Dispose() } }
  return $out
}
# 2.2.8: when a reply arrived, as local time ($null = not known). Takes the ISO times the relay sends (UTC, "Z"), the 's' times this
# Toolkit writes (local) and an email's own Date header ("Sun, 8 Nov 2026 21:01:12 -0500 (EST)").
function ConvertTo-HikLocalTime([string]$s) {
  $s = ([string]$s).Trim(); if (-not $s) { return $null }
  $s = ($s -replace '\s*\([^)]*\)\s*$', '').Trim()
  $o = [DateTimeOffset]::MinValue
  if ([DateTimeOffset]::TryParse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$o)) { return $o.LocalDateTime }
  $s2 = $s -replace '^[A-Za-z]{3},\s*', ''
  foreach ($f in @('d MMM yyyy HH:mm:ss zzz', 'd MMM yyyy HH:mm zzz', 'd MMM yyyy HH:mm:ss')) {
    $t = ($s2 -replace '([+-]\d\d)(\d\d)$', '$1:$2')
    if ([DateTimeOffset]::TryParseExact($t, $f, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$o)) { return $o.LocalDateTime }
  }
  return $null
}
# folder mode: every regular file in $Dir newer than $Since becomes a pseudo-message with one attachment (.zip = its files, .eml = its attachments or code)
# 2.2.8: an .eml carries its own Date (when Hikvision's email arrived), not the time the file was saved; a file that cannot be read
# is a message with "error" set (said as skipped), never a stop for the other files.
function Get-HikFolderMessages([string]$Dir, [datetime]$Since) {
  $out = @()
  if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return $out }
  foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $Since -and $_.Length -lt 5MB -and $_.Name -notlike '*.json' -and $_.Name -notlike '*.tmp' })) {
    $att = New-Object System.Collections.ArrayList; $text = ''; $date = $f.LastWriteTime.ToString('s'); $subj = ''; $err = ''
    try {
      if ($f.Extension -match '(?i)\.zip$') { foreach ($z in @(Read-HikZipEntries $f.FullName)) { [void]$att.Add([pscustomobject]@{ name = ($f.BaseName + '-' + $z.name); bytes = $z.bytes; type = 'file' }) } }   # 2.2.3 (Codex #56)
      elseif ($f.Extension -match '(?i)\.eml$') {
        $mm = Read-MimeMessage ([IO.File]::ReadAllBytes($f.FullName)); $text = [string]$mm.text; $subj = [string]$mm.subject
        $md = ConvertTo-HikLocalTime ([string]$mm.date); if ($md) { $date = $md.ToString('s') }
        foreach ($a in @($mm.attachments)) { if ($null -eq $a) { continue }; [void]$att.Add([pscustomobject]@{ name = ($f.BaseName + '-' + $a.name); bytes = $a.bytes; type = $a.type }) }
        # 2.2.1 (review M5): a code written in the mail's text counts too - also when the mail has other attachments (a logo, a PDF)
        $code = Get-HikCodeFromText $text; if ($code) { [void]$att.Add([pscustomobject]@{ name = ($f.BaseName + '-code.txt'); bytes = [Text.Encoding]::ASCII.GetBytes($code); type = 'text/plain' }) }
      }
      else { [void]$att.Add([pscustomobject]@{ name = $f.Name; bytes = [IO.File]::ReadAllBytes($f.FullName); type = 'file' }) }
    } catch { $err = [string]$_.Exception.Message }
    $out += [pscustomobject]@{ from = 'folder'; subject = $f.Name; mailSubject = $subj; date = $date; text = $text; attachments = @($att); id = $f.FullName; error = $err }
  }
  return $out
}
