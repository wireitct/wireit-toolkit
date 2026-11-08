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
# $Devices = state devices (serial, shortSerial, mac). Returns [{ device; name; bytes; how; mail }] and the unmatched ones.
function Find-HikReplyMatches($Devices, $Messages) {
  $l1 = Hm-Latin1; $matches2 = @(); $un = @()
  foreach ($m in @($Messages)) {
    if ($null -eq $m) { continue }
    $cands = @()
    foreach ($a in @($m.attachments)) { if ($null -eq $a -or $null -eq $a.bytes) { continue }; $cands += [pscustomobject]@{ name = $a.name; bytes = $a.bytes; fromFile = $false } }
    foreach ($c in $cands) {
      $txt = $l1.GetString($c.bytes); $hit = $null; $how = ''
      foreach ($d in @($Devices)) {
        $sn = [string]$d.serial; $sh = [string]$d.shortSerial; $mac = ([string]$d.mac) -replace '[-:]', ''
        if ($sn -and ($c.name -like ('*' + $sn + '*') -or $txt -like ('*' + $sn + '*'))) { $hit = $d; $how = 'serial'; break }
      }
      if (-not $hit) { foreach ($d in @($Devices)) { $sh = [string]$d.shortSerial; if ($sh -and ($c.name -like ('*' + $sh + '*') -or $txt -like ('*' + $sh + '*'))) { if ($hit) { $hit = $null; $how = 'ambiguous'; break }; $hit = $d; $how = 'short serial' } } }
      if (-not $hit) { foreach ($d in @($Devices)) { $mac = ([string]$d.mac) -replace '[-:]', ''; if ($mac -and (($txt -replace '[-:]', '') -match ('(?i)' + $mac))) { $hit = $d; $how = 'MAC'; break } } }
      if (-not $hit -and $how -ne 'ambiguous' -and $m.text) {
        # 2.2.0: else the mail's own text (a code mail names the serial in its text, the attachment is only the code)
        $mt = [string]$m.text; $cnt = 0
        foreach ($d in @($Devices)) { $sn = [string]$d.serial; $sh = [string]$d.shortSerial; if (($sn -and $mt -like ('*' + $sn + '*')) -or ($sh -and $mt -like ('*' + $sh + '*'))) { $cnt++; $hit = $d; $how = 'serial in the mail text' } }
        if ($cnt -gt 1) { $hit = $null; $how = 'ambiguous' }
      }
      if ($hit) { $matches2 += [pscustomobject]@{ device = $hit; name = $c.name; bytes = $c.bytes; how = $how; mail = $m.subject; src = [string]$m.id } } else { $un += [pscustomobject]@{ name = $c.name; bytes = $c.bytes; mail = $m.subject; why = $(if ($how -eq 'ambiguous') { 'could belong to more than one device' } else { 'no serial or MAC of ours in it' }) } }
    }
  }
  return [pscustomobject]@{ matched = $matches2; unmatched = $un }
}
# a Hikvision code written in a mail's text (no attachment). Returns '' when there is none. UNVERIFIED: shape of Hik's code mail not seen yet.
function Get-HikCodeFromText([string]$Text) {
  if (-not $Text) { return '' }
  $m = [regex]::Match($Text, '(?i)(?:verification|security|reset|unlock)?\s*(?:code|key)\s*(?:is)?\s*[:\uFF1A]?\s*([A-Za-z0-9]{8})(?![A-Za-z0-9])')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}
# folder mode: every regular file in $Dir newer than $Since becomes a pseudo-message with one attachment (.zip = its files, .eml = its attachments or code)
function Get-HikFolderMessages([string]$Dir, [datetime]$Since) {
  $out = @()
  if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return $out }
  foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $Since -and $_.Length -lt 5MB -and $_.Name -notlike '*.json' -and $_.Name -notlike '*.tmp' })) {
    $att = New-Object System.Collections.ArrayList; $text = ''
    if ($f.Extension -match '(?i)\.zip$') { try { $tmp = Join-Path ([IO.Path]::GetTempPath()) ('hz' + [guid]::NewGuid().ToString('N').Substring(0, 6)); Expand-Archive -LiteralPath $f.FullName -DestinationPath $tmp -Force; foreach ($z in Get-ChildItem $tmp -File -Recurse) { [void]$att.Add([pscustomobject]@{ name = ($f.BaseName + '-' + $z.Name); bytes = [IO.File]::ReadAllBytes($z.FullName); type = 'file' }) }; Remove-Item -Recurse -Force $tmp } catch {} }
    elseif ($f.Extension -match '(?i)\.eml$') {
      try {
        $mm = Read-MimeMessage ([IO.File]::ReadAllBytes($f.FullName)); $text = [string]$mm.text
        foreach ($a in @($mm.attachments)) { [void]$att.Add([pscustomobject]@{ name = ($f.BaseName + '-' + $a.name); bytes = $a.bytes; type = $a.type }) }
        if (-not $att.Count) { $code = Get-HikCodeFromText $text; if ($code) { [void]$att.Add([pscustomobject]@{ name = ($f.BaseName + '-code.txt'); bytes = [Text.Encoding]::ASCII.GetBytes($code); type = 'text/plain' }) } }
      } catch {}
    }
    else { [void]$att.Add([pscustomobject]@{ name = $f.Name; bytes = [IO.File]::ReadAllBytes($f.FullName); type = 'file' }) }
    $out += [pscustomobject]@{ from = 'folder'; subject = $f.Name; date = $f.LastWriteTime.ToString('s'); text = $text; attachments = @($att); id = $f.FullName }
  }
  return $out
}
