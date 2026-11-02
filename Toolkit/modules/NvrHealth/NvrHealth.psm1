<#
 NvrHealth.psm1 - WireIt CT "NVR health" checks (Windows PowerShell 5.1, no installs). Version 1.0 (2026-11-02)

 On site, from the Toolkit PC (same LAN as the recorder):
   Get-RecordingStatus  read-only: is every camera recording, days of footage held vs. the target, hard-drive health (status + SMART).
   Get-ClockStatus      read-only: recorder (and camera) clock vs. real time; NTP on; US Eastern time zone with daylight saving.
   Set-NtpTime          THE ONLY WRITE: time server + US Eastern/DST. Idempotent (skips what is already right), logs before/after, -WhatIf.
   Get-FirmwareStatus   read-only: firmware vs. newest published + known security advisories (firmware-latest.json).
   Get-NvrHealth        the three read-only checks in a row.
 Vendors: Hikvision (ISAPI), DW Spectrum (REST), Uniview (LAPI + ONVIF), anything else (ONVIF, partial).
 Passwords: hidden console prompt (Read-Host -AsSecureString) or a PSCredential passed in. Never logged or shown.
#>
Set-StrictMode -Off
$script:ModVersion = '1.1 (2026-11-02)'
$script:Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Opt = [ordered]@{
  TargetDays     = 30
  NtpServer      = 'time.nist.gov'
  NtpBackup      = 'pool.ntp.org'
  NtpIntervalMin = 60
  HikTimeZone    = 'CST+5:00:00DST01:00:00,M3.2.0/02:00:00,M11.1.0/02:00:00'   # Hikvision's string for (GMT-05:00) Eastern + DST
  PosixTimeZone  = 'EST5EDT,M3.2.0,M11.1.0'                                     # ONVIF/POSIX string for US Eastern + DST
  DriftWarnSec   = 30
  DriftBadSec    = 300
  FreshMinutes   = 20
  LogDir         = ''
  LogFile        = ''      # one fixed log file for every check (the Toolkit tails it); empty = a new file per check in LogDir
  ReferenceFile  = ''
  MockUrl        = ''      # TEST HARNESS ONLY: device calls go to <MockUrl>/dev/<ip>
  TimeoutSec     = 10
}
$script:IsPs5 = $PSVersionTable.PSVersion.Major -lt 6
if ($script:IsPs5) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
  [Net.ServicePointManager]::Expect100Continue = $false
}
$script:LogFile = $null
$script:Sum = New-Object System.Collections.Generic.List[string]
$script:Scheme = @{}

function Set-NvrHealthOption { param([Parameter(Mandatory)][string]$Name, $Value); if (-not $script:Opt.Contains($Name)) { throw ('Unknown option ' + $Name) }; $script:Opt[$Name] = $Value }
function Get-NvrHealthOption { return [pscustomobject]$script:Opt }
function Get-NvrHealthSummary { return @($script:Sum) }

# ---------------- output + log ----------------
function Redact([string]$s) {
  if (-not $s) { return $s }
  $s = [regex]::Replace($s, '(?is)<password[^>]*>.*?</password>', '<password>***</password>')
  $s = [regex]::Replace($s, '(?is)<(wsse:)?Password[^>]*>.*?</(wsse:)?Password>', '<Password>***</Password>')
  $s = [regex]::Replace($s, '(?i)"(password|passwd|pwd|token)"\s*:\s*"[^"]*"', '"$1":"***"')
  $s = [regex]::Replace($s, '(?i)(Bearer\s+)[A-Za-z0-9._\-]+', '$1***')
  return $s
}
function Start-Log([string]$what) {
  $dir = [string]$script:Opt.LogDir; if (-not $dir) { $dir = Join-Path $script:Here 'logs' }
  if ($script:Opt.LogFile) { $dir = Split-Path -Parent ([string]$script:Opt.LogFile) }
  New-Item -ItemType Directory -Force -Path $dir -WhatIf:$false -Confirm:$false | Out-Null
  if ($script:Opt.LogFile) { $script:LogFile = [string]$script:Opt.LogFile } else { $script:LogFile = Join-Path $dir ('nvrhealth-' + $what + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt') }
  $script:Sum.Clear()
  Log ('NvrHealth ' + $script:ModVersion + ' ' + $what + ' on ' + $env:COMPUTERNAME)
}
function Log([string]$s) { if ($script:LogFile) { Add-Content -WhatIf:$false -Confirm:$false -Path $script:LogFile -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + (Redact $s)) } }
function Say([string]$s, [string]$color = '') { if ($color) { Write-Host $s -ForegroundColor $color } else { Write-Host $s }; $script:Sum.Add($s); Log ('SAY ' + $s) }
function Ok([string]$s) { Say ('  OK      ' + $s) 'Green' }
function Warn([string]$s) { Say ('  CHECK   ' + $s) 'Yellow' }
function Bad([string]$s) { Say ('  PROBLEM ' + $s) 'Red' }
function Info([string]$s) { Say ('          ' + $s) }

# ---------------- credentials: hidden prompt only ----------------
function Read-NvrCredential([string]$what) {
  $u = Read-Host ('User name for ' + $what + ' [admin]'); if (-not $u) { $u = 'admin' }
  $p = Read-Host ('Password for ' + $u + ' on ' + $what) -AsSecureString
  return New-Object PSCredential($u, $p)
}
function Plain([pscredential]$c) { return $c.GetNetworkCredential().Password }

# ---------------- HTTP ----------------
function Base([string]$ip, [int]$port = 0, [string]$scheme = '') {
  if ($script:Opt.MockUrl) { return ([string]$script:Opt.MockUrl).TrimEnd('/') + '/dev/' + $ip }
  $key = $ip + ':' + $port
  if (-not $scheme) { if ($script:Scheme.ContainsKey($key)) { $scheme = $script:Scheme[$key] } else { $scheme = 'http' } }
  $hp = $ip; if ($port -gt 0) { $hp = $ip + ':' + $port }
  return ($scheme + '://' + $hp)
}
function Err-Body($ex) { try { $r = $ex.Exception.Response; if ($r) { $sr = New-Object IO.StreamReader($r.GetResponseStream()); return $sr.ReadToEnd() } } catch {}; return '' }
function Http {
  param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = 'application/xml',
        $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0)
  if (-not $Timeout) { $Timeout = [int]$script:Opt.TimeoutSec }
  $a = @{ Uri = ((Base $Ip $Port $Scheme) + $Path); Method = $Method; UseBasicParsing = $true; TimeoutSec = $Timeout }
  if ($Credential) { $a.Credential = $Credential }
  if ($Headers) { $a.Headers = $Headers }
  if ($Body) { $a.Body = [Text.Encoding]::UTF8.GetBytes($Body); $a.ContentType = $ContentType }
  if (-not $script:IsPs5) { $a.SkipCertificateCheck = $true; if ($Credential) { $a.AllowUnencryptedAuthentication = $true } }
  Log ($Method + ' ' + $Ip + $(if ($Port) { ':' + $Port } else { '' }) + $Path + $(if ($Body -and -not $NoLogBody) { ' BODY ' + $Body } elseif ($Body) { ' BODY (not logged)' } else { '' }))
  for ($try = 0; $try -lt 2; $try++) {
    try {
      $r = Invoke-WebRequest @a
      $c = [string]$r.Content; if ($r.Content -is [byte[]]) { $c = [Text.Encoding]::UTF8.GetString($r.Content) }
      Log ('  -> ' + [int]$r.StatusCode + ' ' + $(if ($c.Length -gt 700) { $c.Substring(0, 700) + '...' } else { $c }))
      return @{ code = [int]$r.StatusCode; body = $c; err = '' }
    } catch {
      $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
      $eb = Err-Body $_
      Log ('  -> ' + $code + ' ' + $_.Exception.Message + ' ' + $eb)
      if ($code -eq 0 -and $try -eq 0 -and -not $script:Opt.MockUrl -and -not $Scheme) {
        $key = $Ip + ':' + $Port
        if (-not $script:Scheme.ContainsKey($key)) { $script:Scheme[$key] = 'https'; $a.Uri = ((Base $Ip $Port) + $Path); continue }
      }
      return @{ code = $code; body = $eb; err = $_.Exception.Message }
    }
  }
  return @{ code = 0; body = ''; err = 'no answer' }
}
function Xml([string]$s) { if (-not $s) { return $null }; try { [xml]$x = $s; return $x } catch { return $null } }
function XFind($node, [string]$name) { if (-not $node) { return @() }; return @($node.SelectNodes(".//*[local-name()='" + $name + "']")) }
function XText($node, [string]$name) { $n = @(XFind $node $name); if ($n.Count -and $n[0]) { return ([string]$n[0].InnerText).Trim() }; return '' }
function XSetText($doc, [string]$name, [string]$v) {
  $n = @(XFind $doc $name)
  if ($n.Count -and $n[0]) { $n[0].InnerText = $v; return }
  $root = $doc.DocumentElement
  $e = $doc.CreateElement($name, $root.NamespaceURI); $e.InnerText = $v; [void]$root.AppendChild($e)
}
function Hik-Ok($r) { if ($r.code -ne 200) { return $false }; $x = Xml $r.body; if (-not $x) { return $true }; $sc = XText $x 'statusCode'; return (-not $sc -or $sc -eq '1' -or $sc -eq '7') }

# ---------------- time helpers ----------------
function NthDow([int]$y, [int]$m, [int]$week, [int]$dow) {
  if ($week -ge 5) { $d = New-Object DateTime($y, $m, [DateTime]::DaysInMonth($y, $m)); while ([int]$d.DayOfWeek -ne $dow) { $d = $d.AddDays(-1) }; return $d }
  $d = New-Object DateTime($y, $m, 1); while ([int]$d.DayOfWeek -ne $dow) { $d = $d.AddDays(1) }
  return $d.AddDays(7 * ($week - 1))
}
function Parse-Tz([string]$tz) {
  # Hikvision "CST+5:00:00DST01:00:00,M3.2.0/02:00:00,M11.1.0/02:00:00" or POSIX "EST5EDT,M3.2.0,M11.1.0".
  # stdOffsetMin = minutes EAST of UTC (US Eastern = -300).
  $o = [ordered]@{ raw = $tz; ok = $false; stdOffsetMin = 0; dstMin = 0; start = $null; end = $null; isUsEastern = $false }
  if (-not $tz) { return [pscustomobject]$o }
  $m = [regex]::Match($tz, '^\s*([A-Za-z]{3,}|<[^>]+>)\s*([+-]?)(\d{1,2})(?::(\d{2}))?(?::(\d{2}))?\s*(?:([A-Za-z]{3,}|<[^>]+>)\s*(?:([+-]?\d{1,2})(?::(\d{2}))?(?::(\d{2}))?)?\s*,\s*M(\d+)\.(\d)\.(\d)(?:/(\d+)(?::(\d+))?(?::(\d+))?)?\s*,\s*M(\d+)\.(\d)\.(\d)(?:/(\d+)(?::(\d+))?(?::(\d+))?)?)?')
  if (-not $m.Success) { return [pscustomobject]$o }
  $sign = 1; if ($m.Groups[2].Value -eq '-') { $sign = -1 }
  $posix = $sign * ([int]$m.Groups[3].Value * 60 + $(if ($m.Groups[4].Value) { [int]$m.Groups[4].Value } else { 0 }))
  $o.stdOffsetMin = - $posix; $o.ok = $true
  if ($m.Groups[10].Value) {
    $o.dstMin = 60
    if ($m.Groups[6].Value -eq 'DST' -and $m.Groups[7].Value) { $o.dstMin = [math]::Abs([int]$m.Groups[7].Value) * 60 + $(if ($m.Groups[8].Value) { [int]$m.Groups[8].Value } else { 0 }) }
    $o.start = @([int]$m.Groups[10].Value, [int]$m.Groups[11].Value, [int]$m.Groups[12].Value, $(if ($m.Groups[13].Value) { [int]$m.Groups[13].Value } else { 2 }))
    $o.end = @([int]$m.Groups[16].Value, [int]$m.Groups[17].Value, [int]$m.Groups[18].Value, $(if ($m.Groups[19].Value) { [int]$m.Groups[19].Value } else { 2 }))
  }
  $o.isUsEastern = ($o.stdOffsetMin -eq -300 -and $o.start -and $o.start[0] -eq 3 -and $o.start[1] -eq 2 -and $o.start[2] -eq 0 -and $o.end[0] -eq 11 -and $o.end[1] -eq 1 -and $o.end[2] -eq 0 -and $o.dstMin -eq 60)
  return [pscustomobject]$o
}
function Tz-OffsetAtLocal($tz, [DateTime]$local) {
  if (-not $tz -or -not $tz.ok) { return $null }
  if (-not $tz.start) { return $tz.stdOffsetMin }
  $s = (NthDow $local.Year $tz.start[0] $tz.start[1] $tz.start[2]).AddHours($tz.start[3])
  $e = (NthDow $local.Year $tz.end[0] $tz.end[1] $tz.end[2]).AddHours($tz.end[3])
  if ($local -ge $s -and $local -lt $e) { return $tz.stdOffsetMin + $tz.dstMin }
  return $tz.stdOffsetMin
}
function Parse-DeviceTime([string]$s, $tz) {
  if (-not $s) { return $null }
  $m = [regex]::Match($s.Trim(), '^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?\s*(Z|[+-]\d{2}:?\d{2})?$')
  if (-not $m.Success) { return $null }
  $local = New-Object DateTime([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value, [int]$m.Groups[4].Value, [int]$m.Groups[5].Value, [int]$m.Groups[6].Value)
  $z = $m.Groups[7].Value; $utc = $null
  if ($z -and $z -ne 'Z') {
    $zm = [regex]::Match($z, '([+-])(\d{2}):?(\d{2})'); $off = [int]$zm.Groups[2].Value * 60 + [int]$zm.Groups[3].Value; if ($zm.Groups[1].Value -eq '-') { $off = -$off }
    $utc = [DateTime]::SpecifyKind($local.AddMinutes(-$off), 'Utc')
  } elseif ($tz -and $tz.ok) { $off = Tz-OffsetAtLocal $tz $local; $utc = [DateTime]::SpecifyKind($local.AddMinutes(-$off), 'Utc') }
  elseif ($z -eq 'Z') { $utc = [DateTime]::SpecifyKind($local, 'Utc') }
  return @{ local = $local; utc = $utc }
}
function Get-ReferenceTime {
  $pc = [DateTime]::UtcNow
  if ($script:Opt.MockUrl) { return @{ utc = $pc; source = 'this PC clock (test mode)'; pcOffsetSec = 0 } }
  foreach ($u in @('https://www.google.com', 'https://www.cloudflare.com')) {
    try {
      $r = Invoke-WebRequest -Uri $u -Method Head -UseBasicParsing -TimeoutSec 5
      $d = [DateTime]::Parse([string]$r.Headers['Date']).ToUniversalTime()
      $off = [math]::Round(($pc - $d).TotalSeconds)
      return @{ utc = [DateTime]::UtcNow.AddSeconds(-$off); source = ('internet time (' + ([uri]$u).Host + ')'); pcOffsetSec = $off }
    } catch {}
  }
  return @{ utc = $pc; source = 'this PC clock (no internet to double-check it)'; pcOffsetSec = $null }
}
function Fmt-Span([double]$sec) {
  $a = [math]::Abs($sec)
  if ($a -lt 90) { return ([string][math]::Round($a) + ' seconds') }
  if ($a -lt 5400) { return ([string][math]::Round($a / 60) + ' minutes') }
  if ($a -lt 172800) { return ([string][math]::Round($a / 3600, 1) + ' hours') }
  return ([string][math]::Round($a / 86400, 1) + ' days')
}

# ---------------- vendor detection + target ----------------
function Detect-Vendor([string]$Ip, [int]$Port = 0) {
  $r = Http -Ip $Ip -Path '/api/moduleInformation' -Port $(if ($Port) { $Port } else { 7001 }) -Scheme $(if ($script:Opt.MockUrl) { '' } else { 'https' }) -Timeout 5
  if ($r.code -eq 200 -and $r.body -match '(?i)"version"') { return 'DW' }
  $r = Http -Ip $Ip -Path '/ISAPI/System/deviceInfo' -Port $Port -Timeout 6
  if ($r.code -eq 401 -or ($r.code -eq 200 -and $r.body -match 'DeviceInfo')) { return 'Hikvision' }
  $r = Http -Ip $Ip -Path '/LAPI/V1.0/System/DeviceInfo' -Port $Port -Timeout 6
  if ($r.code -eq 401 -or ($r.code -eq 200 -and $r.body -match 'Response')) { return 'Uniview' }
  return 'Onvif'
}
function Resolve-Target([string]$Ip, [string]$Vendor, $Credential, [int]$Port) {
  if (-not $Vendor -or $Vendor -eq 'Auto') { $Vendor = Detect-Vendor $Ip $Port; Info ('Recorder at ' + $Ip + ' looks like: ' + $(if ($Vendor -eq 'DW') { 'DW Spectrum server' } else { $Vendor })) }
  if (-not $Credential) { $Credential = Read-NvrCredential ($Ip + ' (' + $Vendor + ')') }
  return @{ ip = $Ip; vendor = $Vendor; cred = $Credential; port = $Port; token = $null }
}

# ================= HIKVISION (ISAPI) =================
function Hik-DeviceInfo($t) {
  $r = Http -Ip $t.ip -Path '/ISAPI/System/deviceInfo' -Credential $t.cred -Port $t.port
  if ($r.code -eq 401) { return @{ login = 'refused' } }
  $x = Xml $r.body; if ($r.code -ne 200 -or -not $x) { return @{ login = 'noanswer'; err = $r.err } }
  return @{ login = 'ok'; model = (XText $x 'model'); serial = (XText $x 'serialNumber'); name = (XText $x 'deviceName');
            firmware = ((XText $x 'firmwareVersion') + ' ' + (XText $x 'firmwareReleasedDate')).Trim(); type = (XText $x 'deviceType') }
}
function Hik-Time($t) {
  $r = Http -Ip $t.ip -Path '/ISAPI/System/time' -Credential $t.cred -Port $t.port
  $x = Xml $r.body; if ($r.code -ne 200 -or -not $x) { return $null }
  $tz = Parse-Tz (XText $x 'timeZone')
  $dt = Parse-DeviceTime (XText $x 'localTime') $tz
  $n = Http -Ip $t.ip -Path '/ISAPI/System/time/ntpServers' -Credential $t.cred -Port $t.port
  $nx = Xml $n.body; $ntp = @()
  foreach ($s in (XFind $nx 'NTPServer')) {
    $fmt = XText $s 'addressingFormatType'
    $ntp += [pscustomobject]@{ id = (XText $s 'id'); host = $(if ($fmt -eq 'ipaddress') { XText $s 'ipAddress' } else { XText $s 'hostName' }); port = (XText $s 'portNo'); interval = (XText $s 'synchronizeInterval') }
  }
  return @{ raw = $r.body; mode = (XText $x 'timeMode'); tz = $tz; time = $dt; ntp = $ntp; ntpRaw = $n.body }
}
function Hik-Channels($t) {
  $out = @()
  $r = Http -Ip $t.ip -Path '/ISAPI/ContentMgmt/InputProxy/channels' -Credential $t.cred -Port $t.port
  foreach ($c in (XFind (Xml $r.body) 'InputProxyChannel')) {
    $out += [pscustomobject]@{ ch = [int](XText $c 'id'); name = (XText $c 'name'); ip = (XText $c 'ipAddress'); online = $null; kind = 'ip'; detect = '' }
  }
  $s = Http -Ip $t.ip -Path '/ISAPI/ContentMgmt/InputProxy/channels/status' -Credential $t.cred -Port $t.port
  foreach ($c in (XFind (Xml $s.body) 'InputProxyChannelStatus')) {
    $id = [int](XText $c 'id'); $o = $out | Where-Object { $_.ch -eq $id } | Select-Object -First 1
    if (-not $o) { $o = [pscustomobject]@{ ch = $id; name = ''; ip = ''; online = $null; kind = 'ip'; detect = '' }; $out += $o }
    $o.online = ((XText $c 'online') -eq 'true'); $o.detect = (XText $c 'chanDetectResult')
    if (-not $o.ip) { $o.ip = XText $c 'ipAddress' }
  }
  if (-not $out.Count) {
    $a = Http -Ip $t.ip -Path '/ISAPI/System/Video/inputs/channels' -Credential $t.cred -Port $t.port
    foreach ($c in (XFind (Xml $a.body) 'VideoInputChannel')) { $out += [pscustomobject]@{ ch = [int](XText $c 'id'); name = (XText $c 'name'); ip = ''; online = ((XText $c 'resDesc') -ne 'NO VIDEO'); kind = 'analog'; detect = '' } }
  }
  return @($out | Sort-Object ch)
}
function Hik-Search($t, [int]$trackId, [DateTime]$fromLocal, [DateTime]$toLocal, [int]$max = 1) {
  # NVRs read the search times as their own local time (the trailing Z is not UTC on Hikvision recorders).
  $body = '<?xml version="1.0" encoding="UTF-8"?><CMSearchDescription><searchID>' + [guid]::NewGuid().ToString().ToUpper() + '</searchID><trackIDList><trackID>' + $trackId + '</trackID></trackIDList><timeSpanList><timeSpan><startTime>' + $fromLocal.ToString('yyyy-MM-ddTHH:mm:ss') + 'Z</startTime><endTime>' + $toLocal.ToString('yyyy-MM-ddTHH:mm:ss') + 'Z</endTime></timeSpan></timeSpanList><maxResults>' + $max + '</maxResults><searchResultPostion>0</searchResultPostion><metadataList><metadataDescriptor>//recordType.meta.std-cgi.com</metadataDescriptor></metadataList></CMSearchDescription>'
  $r = Http -Ip $t.ip -Method 'POST' -Path '/ISAPI/ContentMgmt/search' -Body $body -Credential $t.cred -Port $t.port -Timeout 25
  $x = Xml $r.body; if ($r.code -ne 200 -or -not $x) { return $null }
  $segs = @()
  foreach ($m in (XFind $x 'searchMatchItem')) {
    $st = Parse-DeviceTime (XText $m 'startTime') $null; $en = Parse-DeviceTime (XText $m 'endTime') $null
    if ($st) { $segs += [pscustomobject]@{ start = $st.local; end = $(if ($en) { $en.local } else { $st.local }) } }
  }
  return @{ status = (XText $x 'responseStatusStrg'); segs = $segs }
}
function Hik-Tracks($t) {
  $r = Http -Ip $t.ip -Path '/ISAPI/ContentMgmt/record/tracks' -Credential $t.cred -Port $t.port
  $out = @{}
  foreach ($tr in (XFind (Xml $r.body) 'Track')) {
    $id = [int](XText $tr 'id'); if (-not $id) { continue }
    $modes = @((XFind $tr 'ActionRecordingMode') | ForEach-Object { $_.InnerText.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    $rec = @((XFind $tr 'Record') | ForEach-Object { $_.InnerText.Trim() })
    $en = XText $tr 'Enable'
    $out[$id] = [pscustomobject]@{ id = $id; enabled = ($en -ne 'false'); modes = $modes; hasSchedule = (($rec -contains 'true') -or -not $rec.Count) }
  }
  return $out
}
function Hik-Storage($t) {
  $r = Http -Ip $t.ip -Path '/ISAPI/ContentMgmt/Storage' -Credential $t.cred -Port $t.port
  $x = Xml $r.body; if ($r.code -ne 200 -or -not $x) { return $null }
  $hdds = @()
  foreach ($h in (XFind $x 'hdd')) {
    $id = XText $h 'id'
    $o = [pscustomobject]@{ id = $id; status = (XText $h 'status'); capMB = [double]('0' + (XText $h 'capacity')); freeMB = [double]('0' + (XText $h 'freeSpace')); property = (XText $h 'property'); smartOk = $null; smartAll = ''; tempC = $null; powerOnDays = $null }
    if ($id) {
      $s = Http -Ip $t.ip -Path ('/ISAPI/ContentMgmt/Storage/hdd/' + $id + '/SMARTTest/status') -Credential $t.cred -Port $t.port
      $sx = Xml $s.body
      if ($s.code -eq 200 -and $sx -and @(XFind $sx 'SMARTTestStatus').Count) {
        $se = XText $sx 'selfEvaluaingStatus'; $o.smartOk = ($se -eq '' -or $se -eq 'ok'); $o.smartAll = XText $sx 'allEvaluaingStatus'
        $tc = XText $sx 'temprature'; if ($tc) { $o.tempC = [int]$tc }
        $pd = XText $sx 'powerOnDay'; if ($pd) { $o.powerOnDays = [int]$pd }
      }
    }
    $hdds += $o
  }
  $nas = @(); foreach ($n in (XFind $x 'nas')) { $nas += [pscustomobject]@{ id = ('NAS ' + (XText $n 'id')); status = (XText $n 'status'); capMB = [double]('0' + (XText $n 'capacity')); freeMB = [double]('0' + (XText $n 'freeSpace')); property = ''; smartOk = $null; smartAll = ''; tempC = $null; powerOnDays = $null } }
  return @($hdds + $nas)
}
function Hik-Recording($t) {
  $tm = Hik-Time $t
  $nowLocal = $(if ($tm -and $tm.time) { $tm.time.local } else { Get-Date })
  $chans = @(Hik-Channels $t)
  $tracks = Hik-Tracks $t
  if (-not $chans.Count) { foreach ($k in ($tracks.Keys | Sort-Object)) { if ($k % 100 -eq 1) { $chans += [pscustomobject]@{ ch = [int][math]::Floor($k / 100); name = ''; ip = ''; online = $null; kind = 'ip'; detect = '' } } } }
  $res = @()
  foreach ($c in $chans) {
    $tid = $c.ch * 100 + 1; $tr = $tracks[$tid]
    $o = [pscustomobject]@{ ch = $c.ch; ip = $c.ip; online = $c.online; scheduled = $(if ($tr) { $tr.enabled -and $tr.hasSchedule } else { $null }); mode = $(if ($tr) { $tr.modes -join '/' } else { '' });
                            recording_now = $false; newest = $null; oldest = $null; days_held = $null; detect = $c.detect }
    $old = Hik-Search $t $tid (New-Object DateTime(2000, 1, 1)) $nowLocal 1
    if ($old -and $old.segs.Count) { $o.oldest = $old.segs[0].start }
    $new = Hik-Search $t $tid $nowLocal.AddHours(-2) $nowLocal.AddMinutes(5) 50
    if ($new -and $new.segs.Count) { $o.newest = ($new.segs | Sort-Object end | Select-Object -Last 1).end }
    elseif ($o.oldest) { $wk = Hik-Search $t $tid $nowLocal.AddDays(-7) $nowLocal 200; if ($wk -and $wk.segs.Count) { $o.newest = ($wk.segs | Sort-Object end | Select-Object -Last 1).end } }
    if ($o.newest) { $o.recording_now = (($nowLocal - $o.newest).TotalMinutes -le [double]$script:Opt.FreshMinutes) }
    if ($o.oldest) {
      # count in real elapsed time: device stamps are local wall-clock, so undo the DST shift (else 1 h short across a DST change)
      $span = $nowLocal - $o.oldest
      if ($tm -and $tm.tz -and $tm.tz.ok) { $span = $span.Add([TimeSpan]::FromMinutes((Tz-OffsetAtLocal $tm.tz $o.oldest) - (Tz-OffsetAtLocal $tm.tz $nowLocal))) }
      $o.days_held = [int][math]::Floor($span.TotalDays)
    }
    $res += $o
  }
  return @{ now = $nowLocal; channels = $res; disks = @(Hik-Storage $t) }
}

# ================= ONVIF (Uniview time + recordings; any other brand) =================
$script:NsDev = 'http://www.onvif.org/ver10/device/wsdl'
$script:NsRec = 'http://www.onvif.org/ver10/recording/wsdl'
$script:NsSearch = 'http://www.onvif.org/ver10/search/wsdl'
function Onvif-Call($t, [string]$path, [string]$inner, [string]$ns) {
  $nonce = New-Object byte[] 16; (New-Object Security.Cryptography.RNGCryptoServiceProvider).GetBytes($nonce)
  $created = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
  $pwb = [Text.Encoding]::UTF8.GetBytes((Plain $t.cred)); $cb = [Text.Encoding]::UTF8.GetBytes($created)
  $sha = [Security.Cryptography.SHA1]::Create(); $dig = [Convert]::ToBase64String($sha.ComputeHash([byte[]]($nonce + $cb + $pwb)))
  $env = '<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tt="http://www.onvif.org/ver10/schema" xmlns:x="' + $ns + '"><s:Header><wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"><wsse:UsernameToken><wsse:Username>' + [Security.SecurityElement]::Escape($t.cred.UserName) + '</wsse:Username><wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">' + $dig + '</wsse:Password><wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">' + [Convert]::ToBase64String($nonce) + '</wsse:Nonce><wsu:Created>' + $created + '</wsu:Created></wsse:UsernameToken></wsse:Security></s:Header><s:Body>' + $inner + '</s:Body></s:Envelope>'
  Log ('ONVIF ' + $path + ' ' + $inner)
  return (Http -Ip $t.ip -Method 'POST' -Path $path -Body $env -ContentType 'application/soap+xml; charset=utf-8' -Port $t.port -NoLogBody)
}
function Onvif-Time($t) {
  $r = Onvif-Call $t '/onvif/device_service' '<x:GetSystemDateAndTime/>' $script:NsDev
  $x = Xml $r.body; if ($r.code -ne 200 -or -not $x) { return $null }
  $u = @(XFind $x 'UTCDateTime') | Select-Object -First 1; $utc = $null
  if ($u) { $utc = New-Object DateTime([int](XText $u 'Year'), [int](XText $u 'Month'), [int](XText $u 'Day'), [int](XText $u 'Hour'), [int](XText $u 'Minute'), [int](XText $u 'Second'), ([DateTimeKind]::Utc)) }
  $n = Onvif-Call $t '/onvif/device_service' '<x:GetNTP/>' $script:NsDev
  $nx = Xml $n.body; $ntp = @()
  foreach ($m in @(@(XFind $nx 'NTPManual') + @(XFind $nx 'NTPFromDHCP'))) { $h = XText $m 'DNSname'; if (-not $h) { $h = XText $m 'IPv4Address' }; if ($h) { $ntp += [pscustomobject]@{ host = $h; port = ''; interval = '' } } }
  return @{ mode = (XText $x 'DateTimeType'); dst = ((XText $x 'DaylightSavings') -eq 'true'); tz = (Parse-Tz (XText $x 'TZ')); utc = $utc; ntp = $ntp }
}
function Onvif-Services($t) {
  $r = Onvif-Call $t '/onvif/device_service' '<x:GetServices><x:IncludeCapability>false</x:IncludeCapability></x:GetServices>' $script:NsDev
  $map = @{}
  foreach ($s in (XFind (Xml $r.body) 'Service')) { $ns = XText $s 'Namespace'; $xa = XText $s 'XAddr'; if ($ns -and $xa) { try { $map[$ns] = ([uri]$xa).AbsolutePath } catch {} } }
  return $map
}
function Onvif-Date([string]$s) { if (-not $s) { return $null }; try { return ([DateTime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)) } catch { return $null } }
function Onvif-Recordings($t) {
  $svc = Onvif-Services $t
  $recPath = $svc[$script:NsRec]; $seaPath = $svc[$script:NsSearch]
  if (-not $recPath -or -not $seaPath) { return $null }
  $r = Onvif-Call $t $recPath '<x:GetRecordings/>' $script:NsRec
  $out = @()
  foreach ($it in (XFind (Xml $r.body) 'RecordingItem')) {
    $tok = XText $it 'RecordingToken'; $nm = XText $it 'Name'; if (-not $nm) { $nm = XText $it 'SourceId' }
    $i = Onvif-Call $t $seaPath ('<x:GetRecordingInformation><x:RecordingToken>' + [Security.SecurityElement]::Escape($tok) + '</x:RecordingToken></x:GetRecordingInformation>') $script:NsSearch
    $ix = Xml $i.body
    $out += [pscustomobject]@{ token = $tok; source = $nm; earliest = (Onvif-Date (XText $ix 'EarliestRecording')); latest = (Onvif-Date (XText $ix 'LatestRecording')); status = (XText $ix 'RecordingStatus') }
  }
  return $out
}

# ================= UNIVIEW (LAPI) =================
function Unv-Get($t, [string]$path) {
  $r = Http -Ip $t.ip -Path $path -Credential $t.cred -Port $t.port -ContentType 'application/json'
  if ($r.code -eq 401) { return @{ login = 'refused' } }
  try { $j = $r.body | ConvertFrom-Json } catch { $j = $null }
  if (-not $j -or -not $j.Response) { return @{ login = 'noanswer' } }
  return @{ login = 'ok'; code = $j.Response.ResponseCode; data = $j.Response.Data }
}
function Unv-DeviceInfo($t) {
  $r = Unv-Get $t '/LAPI/V1.0/System/DeviceInfo'
  if ($r.login -ne 'ok') { return @{ login = $r.login } }
  $d = $r.data
  return @{ login = 'ok'; model = [string]$d.DeviceModel; serial = [string]$d.SerialNumber; firmware = [string]$d.FirmwareVersion; name = [string]$d.DeviceName }
}
function Unv-Ntp($t) {
  $r = Unv-Get $t '/LAPI/V1.0/System/Time/NTP'
  if ($r.login -ne 'ok') { return $null }
  $out = @(); foreach ($s in @($r.data.NTPServerInfos)) { if ($s) { $h = [string]$s.IPAddress; if (-not $h) { $h = [string]$s.Domain }; if ($h) { $out += [pscustomobject]@{ host = $h; port = [string]$s.Port; interval = [string]$s.SynchronizeInterval } } } }
  return @{ enabled = $r.data.Enabled; servers = $out }
}

# ================= DW SPECTRUM (REST) =================
function Dw-Port($t) { if ($t.port) { return $t.port }; return 7001 }
function Dw-Scheme { if ($script:Opt.MockUrl) { return '' }; return 'https' }
function Dw-Login($t) {
  if ($t.token) { return $true }
  $body = (@{ username = $t.cred.UserName; password = (Plain $t.cred); setCookie = $false } | ConvertTo-Json -Compress)
  $r = Http -Ip $t.ip -Method 'POST' -Path '/rest/v3/login/sessions' -Body $body -ContentType 'application/json' -Port (Dw-Port $t) -Scheme (Dw-Scheme) -NoLogBody
  $body = $null
  if ($r.code -ne 200) { return $false }
  try { $t.token = ($r.body | ConvertFrom-Json).token } catch {}
  return [bool]$t.token
}
function Dw-Get($t, [string]$path) {
  $r = Http -Ip $t.ip -Path $path -Headers @{ Authorization = ('Bearer ' + $t.token) } -Port (Dw-Port $t) -Scheme (Dw-Scheme) -ContentType 'application/json'
  if ($r.code -ne 200) { return $null }
  try { return ($r.body | ConvertFrom-Json) } catch { return $null }
}
function Dw-Info($t) {
  $r = Http -Ip $t.ip -Path '/api/moduleInformation' -Port (Dw-Port $t) -Scheme (Dw-Scheme)
  try { $j = ($r.body | ConvertFrom-Json); if ($j.reply) { $j = $j.reply } } catch { $j = $null }
  if (-not $j) { return $null }
  return @{ version = [string]$j.version; name = [string]$j.name; brand = [string]$j.brand }
}
function Ms-ToUtc($ms) { return (New-Object DateTime(1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc))).AddMilliseconds([double]$ms) }
function Utc-ToMs([DateTime]$d) { return [long]($d.ToUniversalTime() - (New-Object DateTime(1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)))).TotalMilliseconds }
function Dw-Time($t) {
  $j = Dw-Get $t '/api/gettime'
  if ($j -and $j.reply) { $j = $j.reply }
  if (-not $j) { return $null }
  $utc = $null; if ($j.utcTime) { $utc = Ms-ToUtc $j.utcTime }
  $offMin = $null; if ($null -ne $j.timeZoneOffset) { $offMin = [math]::Round([double]$j.timeZoneOffset / 60000) }
  return @{ utc = $utc; tzId = [string]$j.timezoneId; offMin = $offMin }
}
function Dw-Storage($t) {
  $out = @()
  $j = Dw-Get $t '/rest/v3/servers/this/storages/*/status'
  foreach ($s in @($j)) { if ($s -and ($null -ne $s.totalSpace)) { $out += [pscustomobject]@{ id = [string]$(if ($s.url) { $s.url } else { $s.path }); status = $(if ($s.isOnline -eq $false) { 'offline' } else { 'ok' }); capMB = [double]$s.totalSpace / 1MB; freeMB = [double]$s.freeSpace / 1MB; property = $(if ($s.isBackup) { 'backup' } elseif ($s.isUsedForWriting -eq $false) { 'not used' } else { 'RW' }); smartOk = $null; smartAll = ''; tempC = $null; powerOnDays = $null } } }
  if (-not $out.Count) {
    $j = Dw-Get $t '/api/storageSpace'
    if ($j -and $j.reply) { foreach ($s in @($j.reply.storages)) { $out += [pscustomobject]@{ id = [string]$s.url; status = $(if ($s.isOnline -eq $false) { 'offline' } else { 'ok' }); capMB = [double]$s.totalSpace / 1MB; freeMB = [double]$s.freeSpace / 1MB; property = $(if ($s.isBackup) { 'backup' } elseif ($s.isUsedForWriting -eq $false) { 'not used' } else { 'RW' }); smartOk = $null; smartAll = ''; tempC = $null; powerOnDays = $null } } }
  }
  return $out
}
function Dw-Devices($t) {
  $j = Dw-Get $t '/rest/v3/devices?_with=id,name,status,model,vendor,url,schedule,parameters'
  $out = @()
  foreach ($d in @($j)) {
    if (-not $d) { continue }
    $ip = ''; $m = [regex]::Match([string]$d.url, '//([^/:]+)'); if ($m.Success) { $ip = $m.Groups[1].Value } elseif ($d.url) { $ip = [string]$d.url }
    $fw = ''; if ($d.parameters -and $d.parameters.firmware) { $fw = [string]$d.parameters.firmware } elseif ($d.firmware) { $fw = [string]$d.firmware }
    $out += [pscustomobject]@{ id = [string]$d.id; ip = $ip; status = [string]$d.status; model = [string]$d.model; vendor = [string]$d.vendor; scheduled = $(if ($d.schedule) { [bool]$d.schedule.isEnabled } else { $null }); firmware = $fw }
  }
  return $out
}
function Dw-Periods($t, [string]$id, [DateTime]$nowUtc) {
  $j = Dw-Get $t ('/ec2/recordedTimePeriods?cameraId=' + [uri]::EscapeDataString($id) + '&startTime=0&endTime=' + (Utc-ToMs $nowUtc) + '&detail=60000&flat=true')
  $p = @(); if ($j -and $j.reply) { $p = @($j.reply) } elseif ($j) { $p = @($j) }
  $p = @($p | Where-Object { $_ -and $null -ne $_.startTimeMs } | Sort-Object { [double]$_.startTimeMs })
  if (-not $p.Count) { return $null }
  $first = $p[0]; $last = $p[$p.Count - 1]
  $live = ([double]$last.durationMs -lt 0)
  $lastEnd = $(if ($live) { $nowUtc } else { Ms-ToUtc ([double]$last.startTimeMs + [double]$last.durationMs) })
  return @{ oldest = (Ms-ToUtc $first.startTimeMs); newest = $lastEnd; live = $live }
}

# ================= Get-RecordingStatus =================
function Get-RecordingStatus {
  <#
  .SYNOPSIS Read-only. Per camera: recording yes/no; oldest footage -> days held vs. target; hard drives (status + SMART).
  .EXAMPLE Get-RecordingStatus -Ip 192.168.1.20 -TargetDays 45
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Ip, [ValidateSet('Auto', 'Hikvision', 'Uniview', 'DW', 'Onvif')][string]$Vendor = 'Auto',
        [pscredential]$Credential, [int]$TargetDays = 0, [int]$Port = 0, [switch]$NoLog)
  if (-not $NoLog) { Start-Log 'recording' }
  if (-not $TargetDays) { $TargetDays = [int]$script:Opt.TargetDays }
  $t = Resolve-Target $Ip $Vendor $Credential $Port
  Say ''; Say ('----- Recording check: ' + $Ip + ' (target ' + $TargetDays + ' days) -----') 'Cyan'
  $result = [ordered]@{ check = 'recording'; ip = $Ip; vendor = $t.vendor; target_days = $TargetDays; ok = $false; days_held = $null; shortest_days = $null; short_cameras = @(); recording = 0; channels = @(); disks = @(); problems = @(); log = $script:LogFile }
  $problems = New-Object System.Collections.Generic.List[string]
  $chans = @(); $disks = @(); $now = $null; $diskApi = $true
  switch ($t.vendor) {
    'Hikvision' {
      $di = Hik-DeviceInfo $t
      if ($di.login -eq 'refused') { Bad 'The recorder refused the user name / password. Nothing was checked (not retried, so the account does not lock).'; $result.problems = @('login refused'); return [pscustomobject]$result }
      if ($di.login -ne 'ok') { Bad ('No answer from ' + $Ip + '. Is this PC on the same network as the recorder?'); $result.problems = @('no answer'); return [pscustomobject]$result }
      Info ($di.model + '  serial ' + $di.serial + '  firmware ' + $di.firmware)
      $hr = Hik-Recording $t; $now = $hr.now; $chans = @($hr.channels); $disks = @($hr.disks | Where-Object { $_ })
    }
    'DW' {
      $info = Dw-Info $t
      if (-not (Dw-Login $t)) { Bad 'The DW server refused the login (or did not answer on port 7001). Nothing was checked.'; $result.problems = @('login refused'); return [pscustomobject]$result }
      if ($info) { Info ('DW Spectrum ' + $info.version + '  server "' + $info.name + '"') }
      $tm = Dw-Time $t; $now = $(if ($tm -and $tm.utc) { $tm.utc } else { [DateTime]::UtcNow })
      $i = 0
      foreach ($d in (Dw-Devices $t)) {
        $i++; $p = Dw-Periods $t $d.id $now
        $online = ($d.status -eq 'Online' -or $d.status -eq 'Recording')
        $recNow = ($d.status -eq 'Recording') -or ($p -and ($p.live -or (($now - $p.newest).TotalMinutes -le [double]$script:Opt.FreshMinutes)))
        $chans += [pscustomobject]@{ ch = $i; ip = $d.ip; online = $online; scheduled = $d.scheduled; recording_now = [bool]$recNow; mode = ''; newest = $(if ($p) { $p.newest } else { $null }); oldest = $(if ($p) { $p.oldest } else { $null }); days_held = $(if ($p) { [int][math]::Floor(($now - $p.oldest).TotalDays) } else { $null }); detect = $d.status }
      }
      $disks = @(Dw-Storage $t)
    }
    default {
      $recs = Onvif-Recordings $t
      if ($null -eq $recs) { Warn 'This recorder does not offer the standard (ONVIF) recording search, or refused the login. Read the recording days on its own screen (Storage / Recording).'; $result.problems = @('no ONVIF recording search'); return [pscustomobject]$result }
      $now = [DateTime]::UtcNow; $i = 0; $diskApi = $false
      foreach ($r in $recs) {
        $i++
        $recNow = ($r.status -eq 'Recording') -or ($r.latest -and (($now - $r.latest).TotalMinutes -le [double]$script:Opt.FreshMinutes))
        $chans += [pscustomobject]@{ ch = $i; ip = ''; online = $null; scheduled = $null; recording_now = [bool]$recNow; mode = ''; newest = $r.latest; oldest = $r.earliest; days_held = $(if ($r.earliest) { [int][math]::Floor(($now - $r.earliest).TotalDays) } else { $null }); detect = $r.source }
      }
    }
  }

  Say ''; Say 'Hard drives:' 'Cyan'
  if (-not $diskApi) { Info 'Drive health is not available through the standard (ONVIF) interface. Look at the recorder''s Storage page.' }
  elseif (-not $disks.Count) { Bad 'No hard drive found. This recorder is NOT saving footage.'; $problems.Add('no hard drive') }
  $capT = 0.0; $freeT = 0.0
  foreach ($d in $disks) {
    $capT += $d.capMB; $freeT += $d.freeMB
    $line = 'Drive ' + $d.id + ': ' + [math]::Round($d.capMB / 1024) + ' GB'
    $st = ([string]$d.status).ToLower()
    if ($st -in @('ok', 'idle', 'normal', 'sleeping')) {
      $bits = @(); if ($null -ne $d.tempC) { $bits += ([string]$d.tempC + ' C') }; if ($null -ne $d.powerOnDays) { $bits += ('on for ' + [math]::Round($d.powerOnDays / 365, 1) + ' years') }
      if ($d.smartOk -eq $false -or $d.smartAll -in @('badsectors', 'fault')) { Bad ($line + ' - its own health test (SMART) says it is FAILING' + $(if ($d.smartAll) { ' (' + $d.smartAll + ')' } else { '' }) + '. Replace it soon.'); $problems.Add('drive ' + $d.id + ' failing') }
      elseif ($null -ne $d.tempC -and $d.tempC -ge 55) { Warn ($line + ' - running hot (' + $d.tempC + ' C). Give the recorder air.'); $problems.Add('drive ' + $d.id + ' hot') }
      elseif ($null -ne $d.powerOnDays -and $d.powerOnDays -ge 1825) { Warn ($line + ' - healthy but old (' + [math]::Round($d.powerOnDays / 365, 1) + ' years on). Plan a replacement.') }
      else { Ok ($line + ' - healthy' + $(if ($bits.Count) { ' (' + ($bits -join ', ') + ')' } else { '' }) + $(if ($d.property -and $d.property -ne 'RW') { ' [' + $d.property + ']' } else { '' })) }
    } else {
      $why = switch ($st) { 'unformatted' { 'not formatted, nothing is saved on it' } 'error' { 'in ERROR' } 'smartfailed' { 'failing its health test (SMART)' } 'offline' { 'offline / not detected' } 'notexist' { 'missing' } 'mismatch' { 'from another recorder (mismatch)' } 'formating' { 'being formatted right now' } 'reparing' { 'being repaired right now' } default { 'status "' + $d.status + '"' } }
      Bad ($line + ' - ' + $why + '.'); $problems.Add('drive ' + $d.id + ' ' + $st)
    }
  }
  $filling = $false
  $maxCap = ($disks | Measure-Object -Property capMB -Maximum).Maximum
  $big = @($disks | Where-Object { $_.capMB -ge 0.1 * $maxCap })   # a small system drive next to the media drives does not count
  $bigCap = ($big | Measure-Object -Property capMB -Sum).Sum; $bigFree = ($big | Measure-Object -Property freeMB -Sum).Sum
  if ($bigCap -gt 0) { $filling = (($bigFree / $bigCap) -gt $(if ($t.vendor -eq 'DW') { 0.12 } else { 0.03 })) }   # DW keeps ~10% free on purpose
  if ($capT -gt 0) { Info ('Total ' + [math]::Round($capT / 1024) + ' GB, ' + [math]::Round(100 * ($capT - $freeT) / $capT) + '% used.') }

  Say ''; Say 'Cameras:' 'Cyan'
  $rec = 0; $notRec = @(); $minDays = $null; $maxDays = $null
  foreach ($c in ($chans | Sort-Object ch)) {
    $label = 'Camera ' + $c.ch + $(if ($c.ip) { ' (' + $c.ip + ')' } else { '' })
    if ($null -ne $c.days_held) { if ($null -eq $minDays -or $c.days_held -lt $minDays) { $minDays = $c.days_held }; if ($null -eq $maxDays -or $c.days_held -gt $maxDays) { $maxDays = $c.days_held } }
    $held = $(if ($null -ne $c.days_held) { ', footage back to ' + $c.oldest.ToString('MMM d') + ' (' + $c.days_held + ' days)' } else { '' })
    if ($c.recording_now) { $rec++; Ok ($label + ': recording' + $held) }
    elseif ($c.online -eq $false) { Bad ($label + ': camera OFFLINE, not recording' + $(if ($c.newest) { ' (last footage ' + $c.newest.ToString('MMM d h:mm tt') + ')' } else { '' })); $notRec += $c.ch }
    elseif ($c.scheduled -eq $false) { Bad ($label + ': recording is turned OFF in its schedule' + $held); $notRec += $c.ch }
    elseif ($c.mode -match '(?i)motion|alarm|event|smart|vmd' -and $c.newest -and ($now - $c.newest).TotalHours -lt 24) { $rec++; Ok ($label + ': motion recording, last clip ' + $c.newest.ToString('MMM d h:mm tt') + $held) }
    elseif ($c.newest) { Bad ($label + ': NOT recording - last footage ' + $c.newest.ToString('MMM d h:mm tt') + $held); $notRec += $c.ch }
    else { Bad ($label + ': NO footage found at all'); $notRec += $c.ch }
  }
  if (-not $chans.Count) { Warn 'No camera channels found on this recorder.'; $problems.Add('no channels') }
  if ($notRec.Count) { $problems.Add(('' + $notRec.Count + ' camera(s) not recording: ' + ($notRec -join ', '))) }

  # The recorder overwrites its oldest footage for ALL cameras together, so the deepest camera = how far back the drives reach.
  # A camera whose footage starts later was added / re-added or was not recording before that (listed, not counted as retention).
  $short = @($chans | Where-Object { $null -ne $_.days_held -and $_.days_held -lt $TargetDays -and $_.days_held -lt ($maxDays - 2) })
  Say ''
  if ($short.Count) { Warn ('' + $short.Count + ' camera(s) have less footage than the others (' + (($short | ForEach-Object { 'cam ' + $_.ch + ': ' + $_.days_held + ' days' }) -join ', ') + '): added / re-added later, or were not recording before. Check they were not off.') }
  if ($null -ne $maxDays) {
    if ($maxDays -ge $TargetDays) { Say ('DAYS HELD: ' + $maxDays + ' days (target ' + $TargetDays + '). OK.') 'Green' }
    elseif (-not $diskApi) { Say ('DAYS HELD: only ' + $maxDays + ' days (target ' + $TargetDays + '). Could not read whether the drives are full - check the recorder''s Storage page.') 'Yellow'; $problems.Add('only ' + $maxDays + ' of ' + $TargetDays + ' days (drive fill unknown)') }
    elseif ($filling) { Say ('DAYS HELD: ' + $maxDays + ' days so far (target ' + $TargetDays + '). The drives are not full yet, so this keeps growing. Check again after they fill.') 'Yellow' }
    else { Say ('DAYS HELD: only ' + $maxDays + ' days (target ' + $TargetDays + '). Drives are full and overwriting. Add storage or lower the recording bitrate.') 'Red'; $problems.Add('only ' + $maxDays + ' of ' + $TargetDays + ' days') }
  } elseif ($chans.Count) { Say 'DAYS HELD: unknown (no footage found to measure).' 'Red'; $problems.Add('days held unknown') }
  Say $(if ($problems.Count) { 'RESULT: ' + $problems.Count + ' problem(s): ' + ($problems -join '; ') } else { 'RESULT: all ' + $rec + ' cameras recording, drives healthy, ' + $TargetDays + '-day target met.' }) $(if ($problems.Count) { 'Red' } else { 'Green' })
  $result.ok = ($problems.Count -eq 0); $result.days_held = $maxDays; $result.shortest_days = $minDays; $result.short_cameras = @($short | ForEach-Object { $_.ch }); $result.recording = $rec; $result.channels = $chans; $result.disks = $disks; $result.problems = @($problems); $result.log = $script:LogFile
  return [pscustomobject]$result
}

# ================= Get-ClockStatus =================
function Clock-Of($t) {
  switch ($t.vendor) {
    'Hikvision' { $h = Hik-Time $t; if (-not $h) { return $null }; return @{ utc = $(if ($h.time) { $h.time.utc } else { $null }); mode = $h.mode; tz = $h.tz; ntp = @($h.ntp | ForEach-Object { $_.host }) } }
    'DW' { if (-not (Dw-Login $t)) { return $null }; $d = Dw-Time $t; if (-not $d) { return $null }; return @{ utc = $d.utc; mode = 'Windows clock'; tz = $null; tzId = $d.tzId; ntp = @() } }
    default {
      $o = Onvif-Time $t; if (-not $o) { return $null }
      $ntp = @($o.ntp | ForEach-Object { $_.host })
      if ($t.vendor -eq 'Uniview' -and -not $ntp.Count) { $u = Unv-Ntp $t; if ($u) { $ntp = @($u.servers | ForEach-Object { $_.host }) } }
      $tz = $o.tz; if ($tz -and $tz.ok -and -not $o.dst -and $tz.start) { $tz.isUsEastern = $false }
      return @{ utc = $o.utc; mode = $o.mode; tz = $tz; ntp = $ntp; dst = $o.dst }
    }
  }
}
function Judge-Clock([string]$label, $c, $ref) {
  $p = @()
  if (-not $c) { Bad ($label + ': could not read its clock (login refused or no answer).'); return @('clock unreadable') }
  if ($c.utc) {
    $drift = ($c.utc - $ref.utc).TotalSeconds; $dir = $(if ($drift -gt 0) { 'ahead' } else { 'behind' })
    if ([math]::Abs($drift) -ge [double]$script:Opt.DriftBadSec) { Bad ($label + ': clock is ' + (Fmt-Span $drift) + ' ' + $dir + '. Footage times are wrong - not usable as evidence until fixed.'); $p += ('clock ' + (Fmt-Span $drift) + ' ' + $dir) }
    elseif ([math]::Abs($drift) -ge [double]$script:Opt.DriftWarnSec) { Warn ($label + ': clock is ' + (Fmt-Span $drift) + ' ' + $dir + '.'); $p += ('clock ' + (Fmt-Span $drift) + ' ' + $dir) }
    else { Ok ($label + ': clock correct (within ' + [math]::Max(1, [math]::Round([math]::Abs($drift))) + ' s).') }
  } else { Warn ($label + ': clock reading not understood.'); $p += 'clock unreadable' }
  if ($c.mode -eq 'Windows clock') {
    if ($c.tzId -and $c.tzId -notmatch '(?i)New_York|Eastern|Detroit|Toronto') { Bad ($label + ': server time zone is "' + $c.tzId + '", not US Eastern.'); $p += 'wrong time zone' } elseif ($c.tzId) { Ok ($label + ': time zone ' + $c.tzId + '.') }
    Info 'A DW server takes its time from Windows. Fix drift on the server: Windows time sync (w32tm) to time.nist.gov.'
    return $p
  }
  if ($c.mode -notmatch '(?i)^ntp$') { Bad ($label + ': time is set by hand ("' + $c.mode + '"), not synced to an internet time server. It will drift.'); $p += 'NTP off' }
  elseif (-not @($c.ntp | Where-Object { $_ }).Count) { Bad ($label + ': NTP is on but no time server is filled in.'); $p += 'no NTP server' }
  else { Ok ($label + ': syncs to ' + (@($c.ntp | Where-Object { $_ }) -join ', ') + '.') }
  if ($c.tz -and $c.tz.ok) {
    if ($c.tz.isUsEastern) { Ok ($label + ': time zone US Eastern with daylight saving.') }
    elseif ($c.tz.stdOffsetMin -eq -300) { Bad ($label + ': US Eastern but daylight saving is OFF or wrong - clock is 1 hour off half the year.'); $p += 'DST off' }
    else { Bad ($label + ': time zone is GMT' + $(if ($c.tz.stdOffsetMin -ge 0) { '+' } else { '-' }) + ([math]::Abs($c.tz.stdOffsetMin) / 60) + ', should be US Eastern (GMT-5 with daylight saving).'); $p += 'wrong time zone' }
  } elseif ($c.tz) { Warn ($label + ': time zone text not understood: "' + $c.tz.raw + '".'); $p += 'time zone unclear' }
  return $p
}
function Get-CameraTargets($t, [string[]]$CameraIps, [pscredential]$CameraCredential) {
  $ips = @($CameraIps | Where-Object { $_ })
  if (-not $ips.Count -and $t.vendor -eq 'Hikvision') { $ips = @(Hik-Channels $t | Where-Object { $_.ip -and $_.ip -notmatch '^192\.168\.254\.' } | ForEach-Object { $_.ip }) }
  $out = @(); foreach ($i in ($ips | Select-Object -Unique)) { $out += @{ ip = $i; vendor = $(if ($t.vendor -in @('DW', 'Onvif')) { 'Auto' } else { $t.vendor }); cred = $(if ($CameraCredential) { $CameraCredential } else { $t.cred }); port = 0; token = $null } }
  return $out
}
function Get-ClockStatus {
  <#
  .SYNOPSIS Read-only. Recorder (and camera) clocks vs. real time; NTP on; US Eastern with daylight saving.
  .EXAMPLE Get-ClockStatus -Ip 192.168.1.20 -IncludeCameras
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Ip, [ValidateSet('Auto', 'Hikvision', 'Uniview', 'DW', 'Onvif')][string]$Vendor = 'Auto',
        [pscredential]$Credential, [int]$Port = 0, [switch]$IncludeCameras, [string[]]$CameraIps, [pscredential]$CameraCredential, [switch]$NoLog)
  if (-not $NoLog) { Start-Log 'clock' }
  $t = Resolve-Target $Ip $Vendor $Credential $Port
  $ref = Get-ReferenceTime
  Say ''; Say ('----- Clock check: ' + $Ip + ' (compared with ' + $ref.source + ') -----') 'Cyan'
  if ($null -ne $ref.pcOffsetSec -and [math]::Abs($ref.pcOffsetSec) -ge 30) { Warn ('This PC''s own clock is off by ' + (Fmt-Span $ref.pcOffsetSec) + '; using internet time instead.') }
  $c = Clock-Of $t
  $probs = @(Judge-Clock 'Recorder' $c $ref)
  $cams = @()
  if ($IncludeCameras) {
    foreach ($ct in (Get-CameraTargets $t $CameraIps $CameraCredential)) {
      if ($ct.vendor -eq 'Auto') { $ct.vendor = Detect-Vendor $ct.ip 0 }
      $cc = Clock-Of $ct
      $cp = @(Judge-Clock ('Camera ' + $ct.ip) $cc $ref)
      $cams += [pscustomobject]@{ ip = $ct.ip; ok = ($cp.Count -eq 0); problems = $cp; drift_sec = $(if ($cc -and $cc.utc) { [math]::Round(($cc.utc - $ref.utc).TotalSeconds) } else { $null }) }
    }
    if (-not $cams.Count) { Info 'No cameras reachable by IP from this PC (cameras on the NVR''s own PoE ports normally take the NVR''s time).' }
  }
  $all = @($probs) + @($cams | ForEach-Object { $ip = $_.ip; $_.problems | ForEach-Object { 'camera ' + $ip + ': ' + $_ } })
  Say $(if ($all.Count) { 'RESULT: time needs fixing (' + ($all -join '; ') + '). "Fix time" (Set-NtpTime) fixes it.' } else { 'RESULT: time is right and stays right (NTP + US Eastern).' }) $(if ($all.Count) { 'Red' } else { 'Green' })
  return [pscustomobject]@{ check = 'clock'; ip = $Ip; vendor = $t.vendor; ok = ($all.Count -eq 0); reference = $ref.source;
    drift_sec = $(if ($c -and $c.utc) { [math]::Round(($c.utc - $ref.utc).TotalSeconds) } else { $null }); mode = $(if ($c) { $c.mode } else { '' });
    ntp = $(if ($c) { @($c.ntp) } else { @() }); timezone = $(if ($c -and $c.tz) { $c.tz.raw } elseif ($c) { $c.tzId } else { '' }); problems = @($all); cameras = $cams; log = $script:LogFile }
}

# ================= Set-NtpTime: THE ONLY WRITE =================
function Hik-NtpPlan($t, [string]$server) {
  $h = Hik-Time $t; if (-not $h) { return @{ ok = $false; why = 'could not read its time settings' } }
  $first = $h.ntp | Select-Object -First 1
  $needNtp = (-not $first) -or ($first.host -ne $server) -or ($first.interval -and [int]$first.interval -gt [int]$script:Opt.NtpIntervalMin)
  $needMode = $h.mode -ne 'NTP'; $needTz = -not ($h.tz -and $h.tz.isUsEastern)
  $ch = @()
  if ($needNtp) { $ch += ('time server -> ' + $server + ' every ' + $script:Opt.NtpIntervalMin + ' min (was ' + $(if ($first -and $first.host) { $first.host + $(if ($first.interval) { ' every ' + $first.interval + ' min' } else { '' }) } else { 'none' }) + ')') }
  if ($needMode) { $ch += ('time mode -> NTP (was ' + $h.mode + ')') }
  if ($needTz) { $ch += ('time zone -> US Eastern with daylight saving (was ' + $(if ($h.tz -and $h.tz.raw) { $h.tz.raw } else { 'unknown' }) + ')') }
  return @{ ok = $true; changes = $ch; needNtp = $needNtp; needMode = $needMode; needTz = $needTz; h = $h; first = $first }
}
function Hik-NtpApply($t, [string]$server, $plan) {
  $h = $plan.h
  Log ('BEFORE /ISAPI/System/time: ' + $h.raw); Log ('BEFORE /ISAPI/System/time/ntpServers: ' + $h.ntpRaw)
  if ($plan.needNtp) {
    $id = $(if ($plan.first -and $plan.first.id) { $plan.first.id } else { '1' })
    $nx = Xml (Http -Ip $t.ip -Path ('/ISAPI/System/time/ntpServers/' + $id) -Credential $t.cred -Port $t.port).body
    if (-not $nx -or -not @(XFind $nx 'NTPServer').Count) { $nx = Xml ('<?xml version="1.0" encoding="UTF-8"?><NTPServer version="2.0" xmlns="http://www.isapi.org/ver20/XMLSchema"><id>' + $id + '</id></NTPServer>') }
    $isIp = $server -match '^\d+\.\d+\.\d+\.\d+$'
    XSetText $nx 'addressingFormatType' $(if ($isIp) { 'ipaddress' } else { 'hostname' })
    if ($isIp) { XSetText $nx 'ipAddress' $server } else { XSetText $nx 'hostName' $server }
    XSetText $nx 'portNo' '123'; XSetText $nx 'synchronizeInterval' ([string]$script:Opt.NtpIntervalMin)
    $r = Http -Ip $t.ip -Method 'PUT' -Path ('/ISAPI/System/time/ntpServers/' + $id) -Body $nx.OuterXml -Credential $t.cred -Port $t.port
    if (-not (Hik-Ok $r)) { return @{ ok = $false; why = ('it refused the time-server setting (HTTP ' + $r.code + ')') } }
  }
  if ($plan.needMode -or $plan.needTz) {
    $tx = Xml $h.raw
    XSetText $tx 'timeMode' 'NTP'
    XSetText $tx 'timeZone' ([string]$script:Opt.HikTimeZone)
    foreach ($n in @(XFind $tx 'localTime')) { [void]$n.ParentNode.RemoveChild($n) }
    $r = Http -Ip $t.ip -Method 'PUT' -Path '/ISAPI/System/time' -Body $tx.OuterXml -Credential $t.cred -Port $t.port
    if (-not (Hik-Ok $r)) { return @{ ok = $false; why = ('it refused the time-mode / time-zone setting (HTTP ' + $r.code + ')') } }
  }
  $after = Hik-Time $t
  Log ('AFTER /ISAPI/System/time: ' + $(if ($after) { $after.raw } else { '(unreadable)' })); Log ('AFTER ntpServers: ' + $(if ($after) { $after.ntpRaw } else { '' }))
  $still = Hik-NtpPlan $t $server
  if ($still.ok -and $still.changes.Count) { return @{ ok = $false; why = ('saved, but it still reads back wrong: ' + ($still.changes -join '; ')) } }
  return @{ ok = $true }
}
function Onvif-NtpPlan($t, [string]$server) {
  $o = Onvif-Time $t; if (-not $o) { return @{ ok = $false; why = 'could not read its time settings (ONVIF)' } }
  $hosts = @($o.ntp | ForEach-Object { $_.host })
  $needNtp = -not ($hosts -contains $server); $needMode = $o.mode -ne 'NTP'; $needTz = (-not ($o.tz -and $o.tz.isUsEastern)) -or (-not $o.dst)
  $ch = @()
  if ($needNtp) { $ch += ('time server -> ' + $server + ' (was ' + $(if ($hosts.Count) { $hosts -join ', ' } else { 'none' }) + ')') }
  if ($needMode) { $ch += ('time mode -> NTP (was ' + $o.mode + ')') }
  if ($needTz) { $ch += ('time zone -> US Eastern with daylight saving (was ' + $(if ($o.tz -and $o.tz.raw) { $o.tz.raw } else { 'unknown' }) + $(if (-not $o.dst) { ', DST off' } else { '' }) + ')') }
  return @{ ok = $true; changes = $ch; needNtp = $needNtp; needMode = $needMode; needTz = $needTz; o = $o }
}
function Onvif-NtpApply($t, [string]$server, $plan) {
  $o = $plan.o
  Log ('BEFORE (ONVIF) mode=' + $o.mode + ' dst=' + $o.dst + ' tz=' + $(if ($o.tz) { $o.tz.raw } else { '' }) + ' ntp=' + (@($o.ntp | ForEach-Object { $_.host }) -join ','))
  if ($plan.needNtp) {
    $isIp = $server -match '^\d+\.\d+\.\d+\.\d+$'
    $man = $(if ($isIp) { '<x:NTPManual><tt:Type>IPv4</tt:Type><tt:IPv4Address>' + $server + '</tt:IPv4Address></x:NTPManual>' } else { '<x:NTPManual><tt:Type>DNS</tt:Type><tt:DNSname>' + $server + '</tt:DNSname></x:NTPManual>' })
    $r = Onvif-Call $t '/onvif/device_service' ('<x:SetNTP><x:FromDHCP>false</x:FromDHCP>' + $man + '</x:SetNTP>') $script:NsDev
    if ($r.code -ne 200) { return @{ ok = $false; why = ('it refused the time-server setting (HTTP ' + $r.code + ')') } }
  }
  if ($plan.needMode -or $plan.needTz) {
    $r = Onvif-Call $t '/onvif/device_service' ('<x:SetSystemDateAndTime><x:DateTimeType>NTP</x:DateTimeType><x:DaylightSavings>true</x:DaylightSavings><x:TimeZone><tt:TZ>' + $script:Opt.PosixTimeZone + '</tt:TZ></x:TimeZone></x:SetSystemDateAndTime>') $script:NsDev
    if ($r.code -ne 200) { return @{ ok = $false; why = ('it refused the time-mode / time-zone setting (HTTP ' + $r.code + ')') } }
  }
  $a = Onvif-Time $t
  Log ('AFTER (ONVIF) ' + $(if ($a) { 'mode=' + $a.mode + ' dst=' + $a.dst + ' tz=' + $a.tz.raw + ' ntp=' + (@($a.ntp | ForEach-Object { $_.host }) -join ',') } else { '(unreadable)' }))
  $still = Onvif-NtpPlan $t $server
  if ($still.ok -and $still.changes.Count) { return @{ ok = $false; why = ('saved, but it still reads back wrong: ' + ($still.changes -join '; ')) } }
  return @{ ok = $true }
}
function Set-NtpTime {
  <#
  .SYNOPSIS THE ONLY WRITE. Time server (time.nist.gov) + US Eastern with DST on the recorder (and reachable cameras).
            Skips devices already right. Logs before/after. -WhatIf prints the plan and changes nothing.
  .EXAMPLE Set-NtpTime -Ip 192.168.1.20 -IncludeCameras -WhatIf
  #>
  [CmdletBinding(SupportsShouldProcess = $true)]
  param([Parameter(Mandatory)][string]$Ip, [ValidateSet('Auto', 'Hikvision', 'Uniview', 'DW', 'Onvif')][string]$Vendor = 'Auto',
        [pscredential]$Credential, [int]$Port = 0, [string]$NtpServer = '', [switch]$IncludeCameras, [string[]]$CameraIps, [pscredential]$CameraCredential, [switch]$NoLog)
  if (-not $NoLog) { Start-Log 'settime' }
  if (-not $NtpServer) { $NtpServer = [string]$script:Opt.NtpServer }
  $t = Resolve-Target $Ip $Vendor $Credential $Port
  $dry = [bool]$WhatIfPreference
  Say ''; Say ('----- Fix time: ' + $Ip + ' -> ' + $NtpServer + ', US Eastern with daylight saving' + $(if ($dry) { '  (WHAT-IF: nothing will be changed)' } else { '' }) + ' -----') 'Cyan'
  $targets = @(@{ label = 'Recorder'; t = $t })
  if ($IncludeCameras) { foreach ($ct in (Get-CameraTargets $t $CameraIps $CameraCredential)) { if ($ct.vendor -eq 'Auto') { $ct.vendor = Detect-Vendor $ct.ip 0 }; $targets += @{ label = ('Camera ' + $ct.ip); t = $ct } } }
  $rows = @(); $failed = 0; $changedN = 0
  foreach ($x in $targets) {
    $tt = $x.t
    if ($tt.vendor -eq 'DW') {
      Warn ($x.label + ': a DW Spectrum server takes its time from Windows. Not changed here. On the server, as admin: w32tm /config /manualpeerlist:"' + $NtpServer + ',0x8 ' + $script:Opt.NtpBackup + ',0x8" /syncfromflags:manual /update ; w32tm /resync ; time zone (UTC-05:00) Eastern Time.')
      $rows += [pscustomobject]@{ target = $x.label; ip = $tt.ip; result = 'manual (DW = Windows time)'; changes = @() }; continue
    }
    $isHik = ($tt.vendor -eq 'Hikvision')
    $plan = $(if ($isHik) { Hik-NtpPlan $tt $NtpServer } else { Onvif-NtpPlan $tt $NtpServer })
    if (-not $plan.ok) { Bad ($x.label + ': ' + $plan.why + '. Nothing changed.'); $failed++; $rows += [pscustomobject]@{ target = $x.label; ip = $tt.ip; result = ('failed: ' + $plan.why); changes = @() }; continue }
    if (-not $plan.changes.Count) { Ok ($x.label + ': already right. Skipped, nothing changed.'); $rows += [pscustomobject]@{ target = $x.label; ip = $tt.ip; result = 'already right'; changes = @() }; continue }
    foreach ($c in $plan.changes) { Info ($x.label + ': ' + $c) }
    if (-not $PSCmdlet.ShouldProcess($(if ($x.label -eq 'Recorder') { 'Recorder ' + $tt.ip } else { $x.label }), ($plan.changes -join '; '))) { $rows += [pscustomobject]@{ target = $x.label; ip = $tt.ip; result = 'what-if (not changed)'; changes = $plan.changes }; continue }
    $w = $(if ($isHik) { Hik-NtpApply $tt $NtpServer $plan } else { Onvif-NtpApply $tt $NtpServer $plan })
    if ($w.ok) { Ok ($x.label + ': time settings saved and read back correctly.'); $changedN++; $rows += [pscustomobject]@{ target = $x.label; ip = $tt.ip; result = 'changed'; changes = $plan.changes } }
    else { Bad ($x.label + ': ' + $w.why + '.'); $failed++; $rows += [pscustomobject]@{ target = $x.label; ip = $tt.ip; result = ('failed: ' + $w.why); changes = $plan.changes } }
  }
  $after = $null
  if ($changedN -and -not $dry) {
    Say ''; Info 'Giving it a moment to reach the time server, then checking the clock again...'
    if (-not $script:Opt.MockUrl) { Start-Sleep -Seconds 20 }
    $after = Get-ClockStatus -Ip $Ip -Vendor $t.vendor -Credential $t.cred -Port $Port -IncludeCameras:$IncludeCameras -CameraIps $CameraIps -CameraCredential $CameraCredential -NoLog
    if ($after -and -not $after.ok -and ($after.problems | Where-Object { $_ -match '^clock ' })) { Warn 'Settings are right but the clock has not caught up yet. If it stays off, the recorder cannot reach the internet time server (check its DNS / gateway, or use the router''s IP as the time server).' }
  }
  Say $(if ($failed) { 'RESULT: ' + $failed + ' device(s) could not be changed (see above).' } elseif ($dry) { 'RESULT: what-if only. Nothing was changed.' } elseif ($changedN) { 'RESULT: time fixed on ' + $changedN + ' device(s). Before/after is in the log.' } else { 'RESULT: nothing needed changing.' }) $(if ($failed) { 'Red' } else { 'Green' })
  return [pscustomobject]@{ check = 'settime'; ip = $Ip; vendor = $t.vendor; whatif = $dry; changed = $changedN; failed = $failed; devices = $rows; after = $after; log = $script:LogFile }
}

# ================= Get-FirmwareStatus =================
function Parse-Fw([string]$s) {
  # "V5.03.020 build 240904" | "Firmware_V5.04.088_260903" | "NVR-B3613.43.52.260918" | "6.1.0.42176"
  $o = @{ raw = $s; ver = ''; build = '' }
  if (-not $s) { return $o }
  $m = [regex]::Match($s, '(?i)B(\d{4})\.(\d+)\.(\d+)\.(\d{6})'); if ($m.Success) { $o.ver = ('B' + $m.Groups[1].Value + '.' + $m.Groups[2].Value + '.' + $m.Groups[3].Value); $o.build = $m.Groups[4].Value; return $o }
  $m = [regex]::Match($s, '(?i)V?(\d+\.\d+(?:\.\d+)?)\D{0,8}?(?:build\s*)?(\d{6})(?!\d)'); if ($m.Success -and $s -notmatch '^\d+\.\d+\.\d+\.\d+$') { $o.ver = $m.Groups[1].Value; $o.build = $m.Groups[2].Value; return $o }
  $m = [regex]::Match($s, '(\d+\.\d+\.\d+\.\d+)'); if ($m.Success) { $o.ver = $m.Groups[1].Value; return $o }
  $m = [regex]::Match($s, '(?i)V?(\d+(?:\.\d+)+)'); if ($m.Success) { $o.ver = $m.Groups[1].Value }
  return $o
}
function Cmp-Ver([string]$a, [string]$b) {
  $pa = @(([regex]::Matches($a, '\d+')) | ForEach-Object { [long]$_.Value }); $pb = @(([regex]::Matches($b, '\d+')) | ForEach-Object { [long]$_.Value })
  for ($i = 0; $i -lt [math]::Max($pa.Count, $pb.Count); $i++) { $x = $(if ($i -lt $pa.Count) { $pa[$i] } else { 0 }); $y = $(if ($i -lt $pb.Count) { $pb[$i] } else { 0 }); if ($x -ne $y) { return [math]::Sign($x - $y) } }
  return 0
}
function Load-Reference([string]$path) {
  if (-not $path) { $path = [string]$script:Opt.ReferenceFile }
  if (-not $path) { $path = Join-Path $script:Here 'firmware-latest.json' }
  if (-not (Test-Path $path)) { return $null }
  return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Find-RefModel($ref, [string]$model) {
  if (-not $ref -or -not $model) { return $null }
  $n = ($model -replace '\s', '').ToUpper()
  foreach ($p in $ref.models.PSObject.Properties) {
    if ((($p.Name -replace '\s', '').ToUpper()) -eq $n) { return $p.Value }
    foreach ($a in @($p.Value.aliases)) { if ($a -and ((([string]$a) -replace '\s', '').ToUpper() -eq $n)) { return $p.Value } }
  }
  foreach ($p in $ref.models.PSObject.Properties) { $k = ($p.Name -replace '\s', '').ToUpper(); if ($n.StartsWith($k + '(') -or $n.StartsWith($k + '/')) { return $p.Value } }
  return $null
}
function Advisory-Hits($adv, $cur) {
  # adv: affected_below_build "250807" | affected_below_version "6.1.2" | affected_from_version + affected_below_version | affected_builds_from/below
  if ($adv.affected_below_build -and $cur.build) {
    if ($adv.affected_from_build -and [string]$cur.build -lt [string]$adv.affected_from_build) { return $false }
    return ([string]$cur.build -lt [string]$adv.affected_below_build)
  }
  if ($adv.affected_below_version -and $cur.ver) {
    if ($adv.affected_from_version -and (Cmp-Ver $cur.ver ([string]$adv.affected_from_version)) -lt 0) { return $false }
    return ((Cmp-Ver $cur.ver ([string]$adv.affected_below_version)) -lt 0)
  }
  return $false
}
function Judge-Firmware([string]$label, [string]$model, [string]$fw, $ref) {
  $o = [ordered]@{ label = $label; model = $model; firmware = $fw; latest = ''; update_available = $null; advisories = @(); verdict = 'unknown'; note = '' }
  $cur = Parse-Fw $fw; $m = Find-RefModel $ref $model
  if (-not $m) { Warn ($label + ' ' + $model + ', firmware ' + $fw + ': model not in the reference list. Check the maker''s site.'); return [pscustomobject]$o }
  $lat = @($m.latest) | Where-Object { $_ } | Sort-Object { [string]$_.build }, { [string]$_.version } | Select-Object -Last 1
  if ($lat) {
    $o.latest = ([string]$lat.version + $(if ($lat.build) { ' build ' + $lat.build } else { '' }))
    if ($cur.build -and $lat.build) { $o.update_available = ([string]$cur.build -lt [string]$lat.build) }
    elseif ($cur.ver -and $lat.version) { $o.update_available = ((Cmp-Ver $cur.ver ([string]$lat.version)) -lt 0) }
  }
  foreach ($a in @($m.advisories)) { if ($a -and (Advisory-Hits $a $cur)) { $o.advisories += [pscustomobject]@{ id = [string]$a.id; severity = [string]$a.severity; kev = [bool]$a.kev; fixed = [string]$a.fixed; summary = [string]$a.summary; url = [string]$a.url } } }
  if ($m.note) { $o.note = [string]$m.note }
  $head = $label + ' ' + $model + ', firmware ' + $fw
  if ($o.advisories.Count) {
    $o.verdict = 'security'
    $kev = @($o.advisories | Where-Object { $_.kev }).Count
    Bad ($head + ': known security hole(s): ' + (($o.advisories | ForEach-Object { $_.id + $(if ($_.kev) { ' (actively exploited)' } else { '' }) }) -join ', ') + '. Update to ' + $(if ($o.latest) { $o.latest } else { 'the newest firmware' }) + '.')
    foreach ($a in $o.advisories) { Info ('  ' + $a.id + ': ' + $a.summary + $(if ($a.fixed) { ' Fixed in: ' + $a.fixed + '.' } else { '' })) }
  } elseif ($o.update_available) { $o.verdict = 'old'; Warn ($head + ': newer firmware exists (' + $o.latest + '). No known hole for this version in our list.') }
  elseif ($o.update_available -eq $false) { $o.verdict = 'current'; Ok ($head + ': up to date.') }
  else { Warn ($head + ': could not compare with ' + $(if ($o.latest) { $o.latest } else { 'the reference' }) + '.') }
  if ($o.note) { Info ('  Note: ' + $o.note) }
  return [pscustomobject]$o
}
function Get-FirmwareStatus {
  <#
  .SYNOPSIS Read-only. Recorder (and reachable cameras) firmware vs. newest published + known advisories (firmware-latest.json).
  .EXAMPLE Get-FirmwareStatus -Ip 192.168.1.20 -IncludeCameras
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Ip, [ValidateSet('Auto', 'Hikvision', 'Uniview', 'DW', 'Onvif')][string]$Vendor = 'Auto',
        [pscredential]$Credential, [int]$Port = 0, [switch]$IncludeCameras, [string[]]$CameraIps, [pscredential]$CameraCredential, [string]$ReferenceFile = '', [switch]$NoLog)
  if (-not $NoLog) { Start-Log 'firmware' }
  $ref = Load-Reference $ReferenceFile
  $t = Resolve-Target $Ip $Vendor $Credential $Port
  Say ''; Say ('----- Firmware / security check: ' + $Ip + $(if ($ref) { ' (reference list of ' + $ref.updated + ')' } else { ' (NO reference list found)' }) + ' -----') 'Cyan'
  if (-not $ref) { Warn 'firmware-latest.json is missing, so versions are only listed, not judged.' }
  $items = @()
  switch ($t.vendor) {
    'Hikvision' {
      $di = Hik-DeviceInfo $t
      if ($di.login -ne 'ok') { Bad ('Could not read the recorder (' + $di.login + ').'); return [pscustomobject]@{ check = 'firmware'; ip = $Ip; vendor = $t.vendor; ok = $false; devices = @(); problems = @('recorder unreadable'); log = $script:LogFile } }
      $items += Judge-Firmware 'Recorder' $di.model $di.firmware $ref
      if ($IncludeCameras) {
        foreach ($ct in (Get-CameraTargets $t $CameraIps $CameraCredential)) {
          $cd = Hik-DeviceInfo $ct
          if ($cd.login -eq 'ok') { $items += Judge-Firmware ('Camera ' + $ct.ip) $cd.model $cd.firmware $ref } else { Warn ('Camera ' + $ct.ip + ': could not read it (' + $cd.login + ').') }
        }
      }
    }
    'DW' {
      $info = Dw-Info $t
      if (-not $info) { Bad 'Could not read the DW server version.'; return [pscustomobject]@{ check = 'firmware'; ip = $Ip; vendor = 'DW'; ok = $false; devices = @(); problems = @('server unreadable'); log = $script:LogFile } }
      $items += Judge-Firmware 'Server' 'DW Spectrum' $info.version $ref
      if ($IncludeCameras -and (Dw-Login $t)) {
        foreach ($d in (Dw-Devices $t)) { if ($d.firmware) { $items += Judge-Firmware ('Camera ' + $d.ip) $d.model $d.firmware $ref } else { Info ('Camera ' + $d.ip + ' ' + $d.model + ': DW does not report its firmware.') } }
      }
    }
    default {
      $di = $(if ($t.vendor -eq 'Uniview') { Unv-DeviceInfo $t } else { $null })
      if ($di -and $di.login -eq 'ok') { $items += Judge-Firmware 'Recorder' $di.model $di.firmware $ref }
      else {
        $r = Onvif-Call $t '/onvif/device_service' '<x:GetDeviceInformation/>' $script:NsDev
        $x = Xml $r.body
        if ($x) { $items += Judge-Firmware 'Recorder' (XText $x 'Model') (XText $x 'FirmwareVersion') $ref } else { Bad 'Could not read the recorder''s model / firmware.' }
      }
      if ($IncludeCameras) {
        foreach ($ct in (Get-CameraTargets $t $CameraIps $CameraCredential)) {
          if ($ct.vendor -eq 'Auto') { $ct.vendor = Detect-Vendor $ct.ip 0 }
          $cd = $(if ($ct.vendor -eq 'Hikvision') { Hik-DeviceInfo $ct } elseif ($ct.vendor -eq 'Uniview') { Unv-DeviceInfo $ct } else { $null })
          if ($cd -and $cd.login -eq 'ok') { $items += Judge-Firmware ('Camera ' + $ct.ip) $cd.model $cd.firmware $ref } else { Warn ('Camera ' + $ct.ip + ': could not read it.') }
        }
      }
    }
  }
  $sec = @($items | Where-Object { $_.verdict -eq 'security' }); $old = @($items | Where-Object { $_.verdict -eq 'old' })
  Say $(if ($sec.Count) { 'RESULT: ' + $sec.Count + ' device(s) with known security holes, ' + $old.Count + ' more on old firmware. Plan updates (with the owner''s OK; an update reboots the device).' } elseif ($old.Count) { 'RESULT: no known holes; ' + $old.Count + ' device(s) on older firmware.' } else { 'RESULT: firmware OK.' }) $(if ($sec.Count) { 'Red' } elseif ($old.Count) { 'Yellow' } else { 'Green' })
  return [pscustomobject]@{ check = 'firmware'; ip = $Ip; vendor = $t.vendor; ok = ($sec.Count -eq 0); devices = $items; problems = @($sec | ForEach-Object { $_.label + ': ' + (($_.advisories | ForEach-Object { $_.id }) -join ',') }); log = $script:LogFile }
}

# ================= all three (read-only) =================
function Get-NvrHealth {
  <#
  .SYNOPSIS Read-only: recording + clock + firmware in one run (one password prompt).
  .EXAMPLE Get-NvrHealth -Ip 192.168.1.20 -TargetDays 45 -Json C:\WireIt\Toolkit\logs\health.json
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Ip, [ValidateSet('Auto', 'Hikvision', 'Uniview', 'DW', 'Onvif')][string]$Vendor = 'Auto',
        [pscredential]$Credential, [int]$TargetDays = 0, [int]$Port = 0, [switch]$IncludeCameras, [string]$Json = '')
  Start-Log 'health'
  $t = Resolve-Target $Ip $Vendor $Credential $Port
  $rec = Get-RecordingStatus -Ip $Ip -Vendor $t.vendor -Credential $t.cred -TargetDays $TargetDays -Port $Port -NoLog
  $clk = Get-ClockStatus -Ip $Ip -Vendor $t.vendor -Credential $t.cred -Port $Port -IncludeCameras:$IncludeCameras -NoLog
  $fw = Get-FirmwareStatus -Ip $Ip -Vendor $t.vendor -Credential $t.cred -Port $Port -IncludeCameras:$IncludeCameras -NoLog
  $out = [pscustomobject]@{ taken = (Get-Date).ToString('s'); ip = $Ip; vendor = $t.vendor; recording = $rec; clock = $clk; firmware = $fw; ok = ($rec.ok -and $clk.ok -and $fw.ok); log = $script:LogFile }
  Say ''; Say ('SUMMARY: recording ' + $(if ($rec.ok) { 'OK' } else { 'PROBLEM' }) + ' | time ' + $(if ($clk.ok) { 'OK' } else { 'PROBLEM' }) + ' | firmware ' + $(if ($fw.ok) { 'OK' } else { 'PROBLEM' })) $(if ($out.ok) { 'Green' } else { 'Red' })
  if ($Json) { ($out | ConvertTo-Json -Depth 8) | Set-Content -Path $Json -Encoding UTF8 -WhatIf:$false -Confirm:$false }
  return $out
}

Export-ModuleMember -Function Get-RecordingStatus, Get-ClockStatus, Set-NtpTime, Get-FirmwareStatus, Get-NvrHealth, Set-NvrHealthOption, Get-NvrHealthOption, Get-NvrHealthSummary, Read-NvrCredential
