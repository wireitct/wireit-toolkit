<#
 HikMail.ps1 - WireIt Toolkit 2.1: catch Hikvision's reply (the unlock file) and match it to the device it belongs to.
 Two ways, both read-only on the mailbox (messages are only read, never moved, deleted or marked):
   imap   - the reply mailbox over IMAP/SSL (config.json "hikReset.mail": host, port, user; the password/app-password is kept encrypted for THIS Windows user
            by "Set mail password" - never in config.json). Gmail / Google Workspace: imap.gmail.com:993 with an app password.
   folder - a drop folder (default CamReset\replies): save the attachments there by hand, or let Tab's mail watcher copy them in.
 A reply is matched to a device by the device's serial (full or the 9-character short one) or MAC in the attachment's name or content,
 else in the mail's text. A file that matches nothing is listed as "unmatched" and is never sent to any device.
 Test harness: tests\hikreset\fake_imap.py (plain TCP, ssl=false).
#>
function Hm-Latin1 { return [Text.Encoding]::GetEncoding(28591) }
# ---------------- secret for the mailbox (DPAPI, this Windows user only) ----------------
function Get-HikMailSecretPath([string]$Dir) { return (Join-Path $Dir 'hik-mail.dat') }
function Set-HikMailPassword([string]$Dir, [System.Security.SecureString]$Secure) {
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  ($Secure | ConvertFrom-SecureString) | Set-Content -LiteralPath (Get-HikMailSecretPath $Dir) -Encoding ASCII
}
function Get-HikMailPassword([string]$Dir) {
  $p = Get-HikMailSecretPath $Dir
  if (-not (Test-Path -LiteralPath $p)) { return '' }
  try { $sec = (Get-Content -LiteralPath $p -Raw).Trim() | ConvertTo-SecureString; return (New-Object PSCredential('x', $sec)).GetNetworkCredential().Password } catch { return '' }
}
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
# ---------------- IMAP (just enough: LOGIN, SELECT, SEARCH, FETCH BODY.PEEK[], LOGOUT) ----------------
function Imap-ReadLine($st) {
  $sb = New-Object System.Collections.Generic.List[byte]
  while ($true) { $b = $st.ReadByte(); if ($b -lt 0) { throw 'mail server closed the connection' }; if ($b -eq 10) { break }; if ($b -ne 13) { $sb.Add([byte]$b) } }
  return (Hm-Latin1).GetString($sb.ToArray())
}
function Imap-ReadBytes($st, [int]$n) { $buf = New-Object byte[] $n; $got = 0; while ($got -lt $n) { $r = $st.Read($buf, $got, $n - $got); if ($r -le 0) { throw 'mail server closed the connection' }; $got += $r }; return $buf }
function Open-ImapSession($cfg, [string]$Password) {
  $tcp = New-Object Net.Sockets.TcpClient; $tcp.ReceiveTimeout = 30000; $tcp.SendTimeout = 30000
  $tcp.Connect([string]$cfg.host, [int]$cfg.port)
  $st = $tcp.GetStream(); $st.ReadTimeout = 30000
  if ($cfg.ssl -ne $false) { $ssl = New-Object Net.Security.SslStream($st, $false); $ssl.AuthenticateAsClient([string]$cfg.host); $st = $ssl; $st.ReadTimeout = 30000 }
  $s = [pscustomobject]@{ tcp = $tcp; st = $st; n = 0 }
  [void](Imap-ReadLine $st)   # greeting
  $q = '"' + (($Password -replace '\\', '\\') -replace '"', '\"') + '"'
  $r = Imap-Cmd $s ('LOGIN "' + ([string]$cfg.user -replace '"', '\"') + '" ' + $q) -Secret
  if (-not $r.ok) { throw ('mail login refused: ' + $r.status) }
  return $s
}
function Imap-Cmd($s, [string]$Cmd, [switch]$Secret) {
  $s.n++; $tag = 'a' + $s.n
  $b = [Text.Encoding]::UTF8.GetBytes($tag + ' ' + $Cmd + "`r`n"); $s.st.Write($b, 0, $b.Length); $s.st.Flush()
  $lits = New-Object System.Collections.ArrayList; $lines = New-Object System.Collections.ArrayList
  while ($true) {
    $l = Imap-ReadLine $s.st
    $m = [regex]::Match($l, '\{(\d+)\}$')
    if ($m.Success) { [void]$lits.Add((Imap-ReadBytes $s.st ([int]$m.Groups[1].Value))); [void]$lines.Add($l); continue }
    if ($l.StartsWith($tag + ' ')) { return [pscustomobject]@{ ok = ($l -match "^$tag OK"); status = $l.Substring($tag.Length + 1); lines = @($lines); literals = @($lits) } }
    [void]$lines.Add($l)
  }
}
function Close-ImapSession($s) { try { [void](Imap-Cmd $s 'LOGOUT') } catch {}; try { $s.tcp.Close() } catch {} }
# fetches messages from the last $Days days whose sender matches $FromLike; returns parsed messages (read-only: BODY.PEEK)
function Get-HikImapMessages($cfg, [string]$Password, [int]$Days = 4, [string]$FromLike = 'hikvision') {
  $s = Open-ImapSession $cfg $Password; $out = @()
  try {
    $folder = $(if ($cfg.folder) { [string]$cfg.folder } else { 'INBOX' })
    $r = Imap-Cmd $s ('EXAMINE "' + $folder + '"'); if (-not $r.ok) { throw ('mail folder: ' + $r.status) }
    $since = (Get-Date).AddDays(-$Days).ToString('dd-MMM-yyyy', [Globalization.CultureInfo]::InvariantCulture)
    $r = Imap-Cmd $s ('SEARCH SINCE ' + $since + ' FROM "' + $FromLike + '"')
    $ids = @(); foreach ($l in $r.lines) { $m = [regex]::Match($l, '^\* SEARCH\s*(.*)$'); if ($m.Success -and $m.Groups[1].Value.Trim()) { $ids += @($m.Groups[1].Value.Trim() -split '\s+') } }
    foreach ($id in $ids) {
      $f = Imap-Cmd $s ('FETCH ' + $id + ' (BODY.PEEK[])')
      if ($f.ok -and $f.literals.Count) { $mm = Read-MimeMessage ([byte[]]$f.literals[0]); $mm | Add-Member -NotePropertyName id -NotePropertyValue $id -Force; $out += $mm }
    }
  } finally { Close-ImapSession $s }
  return $out
}
# ---------------- matching ----------------
# $Devices = state devices (serial, shortSerial, mac). Returns [{ device; name; bytes; how; mail }] and the unmatched ones.
function Find-HikReplyMatches($Devices, $Messages) {
  $l1 = Hm-Latin1; $matches2 = @(); $un = @()
  foreach ($m in @($Messages)) {
    $cands = @()
    foreach ($a in @($m.attachments)) { $cands += [pscustomobject]@{ name = $a.name; bytes = $a.bytes; fromFile = $false } }
    foreach ($c in $cands) {
      $txt = $l1.GetString($c.bytes); $hit = $null; $how = ''
      foreach ($d in @($Devices)) {
        $sn = [string]$d.serial; $sh = [string]$d.shortSerial; $mac = ([string]$d.mac) -replace '[-:]', ''
        if ($sn -and ($c.name -like ('*' + $sn + '*') -or $txt -like ('*' + $sn + '*'))) { $hit = $d; $how = 'serial'; break }
      }
      if (-not $hit) { foreach ($d in @($Devices)) { $sh = [string]$d.shortSerial; if ($sh -and ($c.name -like ('*' + $sh + '*') -or $txt -like ('*' + $sh + '*'))) { if ($hit) { $hit = $null; $how = 'ambiguous'; break }; $hit = $d; $how = 'short serial' } } }
      if (-not $hit) { foreach ($d in @($Devices)) { $mac = ([string]$d.mac) -replace '[-:]', ''; if ($mac -and (($txt -replace '[-:]', '') -match ('(?i)' + $mac))) { $hit = $d; $how = 'MAC'; break } } }
      if ($hit) { $matches2 += [pscustomobject]@{ device = $hit; name = $c.name; bytes = $c.bytes; how = $how; mail = $m.subject } } else { $un += [pscustomobject]@{ name = $c.name; bytes = $c.bytes; mail = $m.subject; why = $(if ($how -eq 'ambiguous') { 'could belong to more than one device' } else { 'no serial or MAC of ours in it' }) } }
    }
  }
  return [pscustomobject]@{ matched = $matches2; unmatched = $un }
}
# folder mode: every regular file in $Dir newer than $Since becomes a pseudo-message with one attachment
function Get-HikFolderMessages([string]$Dir, [datetime]$Since) {
  $out = @()
  if (-not (Test-Path -LiteralPath $Dir)) { return $out }
  foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $Since -and $_.Length -lt 5MB })) {
    $att = New-Object System.Collections.ArrayList
    if ($f.Extension -match '(?i)\.zip$') { try { $tmp = Join-Path ([IO.Path]::GetTempPath()) ('hz' + [guid]::NewGuid().ToString('N').Substring(0, 6)); Expand-Archive -LiteralPath $f.FullName -DestinationPath $tmp -Force; foreach ($z in Get-ChildItem $tmp -File -Recurse) { [void]$att.Add([pscustomobject]@{ name = $z.Name; bytes = [IO.File]::ReadAllBytes($z.FullName); type = 'file' }) }; Remove-Item -Recurse -Force $tmp } catch {} }
    else { [void]$att.Add([pscustomobject]@{ name = $f.Name; bytes = [IO.File]::ReadAllBytes($f.FullName); type = 'file' }) }
    $out += [pscustomobject]@{ from = 'folder'; subject = $f.Name; date = $f.LastWriteTime.ToString('s'); text = ''; attachments = @($att); id = $f.FullName }
  }
  return $out
}
