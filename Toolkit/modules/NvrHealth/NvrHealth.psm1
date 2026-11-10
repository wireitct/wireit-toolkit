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
$script:ModVersion = '1.4 (2026-11-03)'
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
  ForceCurl      = $false  # TEST HARNESS ONLY: send login-free calls through curl.exe (the HTTPS fallback path)
  TimeoutSec     = 10
}
# 2.2.1 (review H2): certificate checks are skipped ONLY for devices on the local network (a private IPv4 address: cameras, NVRs).
# Anything with a name (the service log, Google, the download service) keeps Windows' normal certificate check. Same code in
# FixSiteDevices.ps1, NvrHealth.psm1, SiteCheck.ps1, FixNVR.ps1 and NetCheck.ps1 (it is compiled once per PowerShell).
$script:WireItLanTlsCode = @"
using System; using System.Net; using System.Net.Security; using System.Security.Cryptography.X509Certificates;
public static class WireItLanTls {
  public static bool IsLanHost(string h) {
    if (string.IsNullOrEmpty(h)) return false;
    IPAddress a; if (!IPAddress.TryParse(h.Trim('[', ']'), out a)) return false;
    if (a.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork) return false;
    byte[] b = a.GetAddressBytes();
    if (b[0] == 10 || b[0] == 127) return true;
    if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
    if (b[0] == 192 && b[1] == 168) return true;
    if (b[0] == 169 && b[1] == 254) return true;
    return false;
  }
  public static bool Check(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
    if (errors == SslPolicyErrors.None) return true;
    string host = null;
    HttpWebRequest r = sender as HttpWebRequest; if (r != null) { host = r.RequestUri.Host; } else { string s = sender as string; if (s != null) host = s; }
    return IsLanHost(host);
  }
  public static readonly RemoteCertificateValidationCallback Callback = new RemoteCertificateValidationCallback(Check);
  public static void Install() { ServicePointManager.ServerCertificateValidationCallback = Callback; }
}
"@
# 2.2.2 (Codex): -IgnoreWarnings - PowerShell 7.5 (.NET 9) turned the SYSLIB0014 'ServicePointManager is obsolete' warning into a failed compile
# 2.2.2 (Codex H2): the same private-IPv4 test in plain PowerShell, for PowerShell 7's per-call certificate skip and curl's -k
function Test-WireItLanHost([string]$h) {
  if (-not $h) { return $false }; $a = $null; if (-not [Net.IPAddress]::TryParse($h.Trim('[', ']'), [ref]$a)) { return $false }
  if ($a.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
  $b = $a.GetAddressBytes()
  return ($b[0] -eq 10 -or $b[0] -eq 127 -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 169 -and $b[1] -eq 254))
}
function Enable-WireItLanTls { try { if (-not ('WireItLanTls' -as [type])) { Add-Type -TypeDefinition $script:WireItLanTlsCode -IgnoreWarnings -WarningAction SilentlyContinue -ErrorAction Stop }; [WireItLanTls]::Install(); return $true } catch { return $false } }
$script:IsPs5 = $PSVersionTable.PSVersion.Major -lt 6
if ($script:IsPs5) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls   # 2.2.2 (re-review): old camera/NVR firmware that only speaks TLS 1.0/1.1 stays on HTTPS
  [void](Enable-WireItLanTls)   # 2.2.1 (review H2): recorders on private addresses only, never a site with a name
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
  $s = [regex]::Replace($s, '(?i)(/login/sessions/)[^/\s?]+', '$1***')   # 1.4: the DW logout carries the session token in its path
  return $s
}
function Start-Log([string]$what) {
  $script:LoginState = @{}   # 1.6.1: one login try per run - a refused or skipped login is never sent again in this run
  $dir = [string]$script:Opt.LogDir; if (-not $dir) { $dir = Join-Path $script:Here 'logs' }
  if ($script:Opt.LogFile) { $dir = Split-Path -Parent ([string]$script:Opt.LogFile) }
  New-Item -ItemType Directory -Force -Path $dir -WhatIf:$false -Confirm:$false | Out-Null
  if ($script:Opt.LogFile) { $script:LogFile = [string]$script:Opt.LogFile } else { $script:LogFile = Join-Path $dir ('nvrhealth-' + $what + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt') }
  $script:Sum.Clear()
  Log ('NvrHealth ' + $script:ModVersion + ' ' + $what + ' on ' + $env:COMPUTERNAME)
}
function Add-NhLine([string]$path, [string]$line) {
  # 1.3: append one line while another process (the Toolkit window) is reading the same file. Add-Content stopped the
  # whole YKW Elm check with "being used by another process"; this shares the file, retries briefly and never throws.
  $b = [Text.Encoding]::UTF8.GetBytes($line + "`r`n")
  for ($i = 0; $i -lt 6; $i++) {
    try { $fs = New-Object IO.FileStream($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]'ReadWrite, Delete'); try { $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }; return $true }
    catch { Start-Sleep -Milliseconds (40 * ($i + 1)) }
  }
  return $false
}
function Log([string]$s) {
  if (-not $script:LogFile) { return }
  $line = (Get-Date -Format 'HH:mm:ss') + ' ' + (Redact $s)
  if (Add-NhLine $script:LogFile $line) { $script:LogFails = 0; return }
  $script:LogFails = [int]$script:LogFails + 1
  if ($script:LogFails -ge 3 -and $script:LogFile -notmatch '-2\.txt$') {
    # the log file stays locked: carry on in a second file next to it instead of stopping the check
    $alt = ($script:LogFile -replace '\.txt$', '') + '-2.txt'; $script:LogFile = $alt; $script:LogFails = 0
    try { Write-Host ('(log file busy - the rest of the log goes to ' + $alt + ')') -ForegroundColor DarkYellow } catch {}
    [void](Add-NhLine $alt $line)
  }
}
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
# 1.6.1 (YKW Elm live test Nov 3 2026): an EMPTY password = skip the recorder login (nothing is sent), and a refused login is
# never tried again in the same run (recording, clock and firmware used to log in one after the other = up to 3 failed tries).
$script:LoginState = @{}
$script:DwOld = @()
$script:DwTokens = @{}   # 1.4: one DW session per server per run (shared by recording, clock, firmware); Close-NvrSessions logs it out
function Login-Blocked($t) { $k = [string]$t.ip; if ($script:LoginState -and $script:LoginState.ContainsKey($k)) { return [string]$script:LoginState[$k] }; return '' }
function Mark-Login($t, [string]$why) { if ($null -eq $script:LoginState) { $script:LoginState = @{} }; $k = [string]$t.ip; if (-not $script:LoginState.ContainsKey($k)) { $script:LoginState[$k] = $why } }
function Login-Words([string]$why) { switch ($why) { 'skipped' { 'login skipped (no password typed - nothing was sent)' } 'refused' { 'login refused' } default { 'no answer' } } }

# ---------------- HTTP ----------------
function Base([string]$ip, [int]$port = 0, [string]$scheme = '') {
  if ($script:Opt.MockUrl) { return ([string]$script:Opt.MockUrl).TrimEnd('/') + '/dev/' + $ip }
  $key = $ip + ':' + $port
  if (-not $scheme) { if ($script:Scheme.ContainsKey($key)) { $scheme = $script:Scheme[$key] } else { $scheme = 'http' } }
  $hp = $ip; if ($port -gt 0) { $hp = $ip + ':' + $port }
  return ($scheme + '://' + $hp)
}
function Err-Body($ex) {
  # PS 5.1 has often read the error body already: it is then in ErrorDetails, and the stream is at its end (seek back)
  try { if ($ex.ErrorDetails -and $ex.ErrorDetails.Message) { return [string]$ex.ErrorDetails.Message } } catch {}
  try { $r = $ex.Exception.Response; if ($r) { $st = $r.GetResponseStream(); if ($st.CanSeek) { $st.Position = 0 }; $sr = New-Object IO.StreamReader($st); return $sr.ReadToEnd() } } catch {}; return ''
}
# Nov 3 2026 (YKW Elm live test): on that DW server .NET HTTPS to https://127.0.0.1:7001 failed ("underlying connection was closed")
# while curl.exe -k and plain http on 7001 worked. Fallbacks: curl.exe (ships with Windows 10/11), then http for this PC only.
$script:ViaCurl = @{}
$script:NhSecretTls = @{}
function Test-NhSecretRequest([string]$path, [string]$body) {
  return ($body -match '(?i)<(?:\w+:)?(?:password|loginPassword)(?:\s|>)|"(?:password|passwd|pwd)"\s*:' -or $path -match '(?i)[?&](?:pwd|pwdOld|password)=')
}
function Get-NhNetErrorKind($ex) {
  for ($e = $ex; $e; $e = $e.InnerException) {
    if ($e -is [Net.Sockets.SocketException] -and [string]$e.SocketErrorCode -eq 'ConnectionRefused') { return 'refused' }
  }
  return 'failed'
}
function Invoke-NhSecretHttp([hashtable]$a) {
  $k = [string]$a.Ip + ':' + [int]$a.Port
  $a.SecretTransport = $true
  if ($script:NhSecretTls[$k] -ne 'no') {
    $a.Scheme = 'https'
    $r = Http @a
    if ($r.code -gt 0) { $script:NhSecretTls[$k] = 'yes'; $script:Scheme[$k] = 'https'; return $r }
    if ($script:NhSecretTls[$k] -eq 'yes' -or $r.errKind -ne 'refused') {
      Bad ('HTTPS did not work on ' + $a.Ip + ': the password was NOT sent over plain HTTP.')
      return $r
    }
    $script:NhSecretTls[$k] = 'no'
  }
  Warn ($a.Ip + ' has no HTTPS (connection refused): the password goes over plain HTTP on this network.')
  $a.Scheme = 'http'
  return (Http @a)
}
function Http-Curl([string]$Uri, [string]$Method = 'GET', [string]$Body = '', [string]$ContentType = '', [hashtable]$Headers = $null, [int]$Timeout = 10) {
  $curl = Join-Path $env:SystemRoot 'System32\curl.exe'; if (-not (Test-Path $curl)) { $c = Get-Command curl.exe -ErrorAction SilentlyContinue; if ($c) { $curl = $c.Source } else { return $null } }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('nvrh-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $tmp -Force -WhatIf:$false -Confirm:$false | Out-Null
  try {
    # header and body go through files, so a token or a password never shows on a command line
    $h = @(); if ($Headers) { foreach ($k in $Headers.Keys) { $h += ($k + ': ' + $Headers[$k]) } }; if ($Body -and $ContentType) { $h += ('Content-Type: ' + $ContentType) }
    $hf = Join-Path $tmp 'h.txt'; [IO.File]::WriteAllText($hf, (($h -join "`r`n") + "`r`n"))
    $of = Join-Path $tmp 'o.bin'
    # 2.2.2 (Codex H2): -k (no certificate check) only for a private IPv4 address; a named host keeps curl's normal check
    $hostK = ''; try { $hostK = [string]([uri]$Uri).Host } catch {}
    $ca = @(); if (Test-WireItLanHost $hostK) { $ca += '-k' }
    $ca += @('-s', '-S', '-m', [string]$Timeout, '-X', $Method, '-H', ('@' + $hf), '-o', $of, '-w', '%{http_code}')
    if ($Body) { $bf = Join-Path $tmp 'b.bin'; [IO.File]::WriteAllBytes($bf, [Text.Encoding]::UTF8.GetBytes($Body)); $ca += @('--data-binary', ('@' + $bf)) }
    $code = (& $curl @ca $Uri 2>$null | Out-String).Trim()
    $c = ''; if (Test-Path $of) { $c = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($of)) }
    $n = 0; [void][int]::TryParse(($code -replace '\D', ''), [ref]$n)
    return @{ code = $n; body = $c; err = $(if ($n) { '' } else { 'no answer (curl)' }) }
  } catch { return $null } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false }
}
function Http {
  param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = 'application/xml',
        $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '', [switch]$SecretTransport)
  # Authentication and verification also carry a password. Protect these reads as well as password-bearing bodies.
  if (-not $script:Opt.MockUrl -and -not $SecretTransport -and ($Credential -or (Test-NhSecretRequest $Path $Body))) {
    $secretArgs = @{}; foreach ($key in $PSBoundParameters.Keys) { $secretArgs[$key] = $PSBoundParameters[$key] }
    return (Invoke-NhSecretHttp $secretArgs)
  }
  if (-not $Timeout) { $Timeout = [int]$script:Opt.TimeoutSec }
  # 2.2.3 (Codex #21): -OutFile = the answer's bytes straight to a file (a config export is binary: never through a string)
  if ($OutFile) { $a = @{ Uri = ((Base $Ip $Port $Scheme) + $Path); Method = $Method; UseBasicParsing = $true; TimeoutSec = $Timeout; OutFile = $OutFile; ErrorAction = 'Stop' }; if ($Credential) { $a.Credential = $Credential }; if (-not $script:IsPs5) { if (Test-WireItLanHost $Ip) { $a.SkipCertificateCheck = $true }; if ($Credential) { $a.AllowUnencryptedAuthentication = $true } }
    Log ($Method + ' ' + $Ip + $Path + ' -> file'); try { Invoke-WebRequest @a; $n = $(if (Test-Path -LiteralPath $OutFile) { (Get-Item -LiteralPath $OutFile).Length } else { 0 }); return @{ code = $(if ($n -gt 0) { 200 } else { 204 }); body = ''; err = ''; bytes = $n } } catch { $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}; Remove-Item -LiteralPath $OutFile -ErrorAction SilentlyContinue; return @{ code = $code; body = ''; err = [string]$_.Exception.Message; bytes = 0 } } }
  $a = @{ Uri = ((Base $Ip $Port $Scheme) + $Path); Method = $Method; UseBasicParsing = $true; TimeoutSec = $Timeout }
  if ($Credential) { $a.Credential = $Credential }
  if ($Headers) { $a.Headers = $Headers }
  if ($Body) { $a.Body = [Text.Encoding]::UTF8.GetBytes($Body); $a.ContentType = $ContentType }
  if ($BodyBytes) { $a.Body = $BodyBytes; $a.ContentType = $ContentType }
  if (-not $script:IsPs5) { if (Test-WireItLanHost $Ip) { $a.SkipCertificateCheck = $true }; if ($Credential) { $a.AllowUnencryptedAuthentication = $true } }   # 2.2.2 (Codex H2): the skip only for a device on the LAN
  Log ($Method + ' ' + $Ip + $(if ($Port) { ':' + $Port } else { '' }) + $Path + $(if ($Body -and -not $NoLogBody) { ' BODY ' + $Body } elseif ($Body) { ' BODY (not logged)' } else { '' }))
  $hk = $Ip + ':' + $Port
  if (-not $Credential -and ($script:Opt.ForceCurl -or $script:ViaCurl.ContainsKey($hk))) {
    $c = Http-Curl -Uri $a.Uri -Method $Method -Body $Body -ContentType $ContentType -Headers $Headers -Timeout $Timeout
    if ($c) { Log ('  -> ' + $c.code + ' (curl.exe) ' + $(if ($c.body.Length -gt 700) { $c.body.Substring(0, 700) + '...' } else { $c.body })); return $c }
  }
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
      if ($code -eq 0 -and $a.Uri -like 'https://*' -and -not $Credential -and -not $script:Opt.MockUrl) {
        $c = Http-Curl -Uri $a.Uri -Method $Method -Body $Body -ContentType $ContentType -Headers $Headers -Timeout $Timeout
        if ($c -and $c.code -gt 0) { $script:ViaCurl[$hk] = $true; Log ('  -> ' + $c.code + ' (curl.exe, .NET HTTPS failed)'); return $c }
        if (-not $SecretTransport -and $Ip -in @('127.0.0.1', 'localhost', '::1')) {   # this PC only: plain http on the same port, never a password-bearing request
          try { $a.Uri = $a.Uri -replace '^https://', 'http://'; $r = Invoke-WebRequest @a; $c2 = [string]$r.Content; if ($r.Content -is [byte[]]) { $c2 = [Text.Encoding]::UTF8.GetString($r.Content) }; Log ('  -> ' + [int]$r.StatusCode + ' (http on this PC)'); return @{ code = [int]$r.StatusCode; body = $c2; err = '' } } catch {}
        }
      }
      if ($code -eq 0 -and $try -eq 0 -and -not $script:Opt.MockUrl -and -not $Scheme) {
        $key = $Ip + ':' + $Port
        if (-not $script:Scheme.ContainsKey($key)) { $script:Scheme[$key] = 'https'; $a.Uri = ((Base $Ip $Port) + $Path); continue }
      }
      return @{ code = $code; body = $eb; err = $_.Exception.Message; errKind = (Get-NhNetErrorKind $_.Exception) }
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
# 2.2.7 (Codex file-by-file F13): "real time" at the moment a clock was READ (this PC's clock corrected by the offset measured once).
# 2.2.6 kept the one time taken when the check started, so every clock read later (after a slow recorder, 300 cameras) looked behind.
function Get-RefAt($ref) { $off = $(if ($null -ne $ref.pcOffsetSec) { [double]$ref.pcOffsetSec } else { 0 }); $r = @{}; foreach ($k in $ref.Keys) { $r[$k] = $ref[$k] }; $r.utc = [DateTime]::UtcNow.AddSeconds(-$off); return $r }
function Fmt-Span([double]$sec) {
  $a = [math]::Abs($sec)
  if ($a -lt 90) { return ([string][math]::Round($a) + ' seconds') }
  if ($a -lt 5400) { return ([string][math]::Round($a / 60) + ' minutes') }
  if ($a -lt 172800) { return ([string][math]::Round($a / 3600, 1) + ' hours') }
  return ([string][math]::Round($a / 86400, 1) + ' days')
}

# 1.4: footage times from DW / ONVIF are UTC; show them in this PC's local time (a recorder's own local stamps are shown as they are)
function Fmt-Local($d, [string]$fmt = 'MMM d h:mm tt') {
  if ($null -eq $d) { return '' }
  $x = [datetime]$d; if ($x.Kind -eq [DateTimeKind]::Utc) { $x = $x.ToLocalTime() }
  return $x.ToString($fmt, [Globalization.CultureInfo]::InvariantCulture)
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
  $t = @{ ip = $Ip; vendor = $Vendor; cred = $Credential; port = $Port; token = $null }
  if (-not $Credential -or -not (Plain $Credential)) { Mark-Login $t 'skipped' }
  return $t
}

# ================= HIKVISION (ISAPI) =================
function Hik-DeviceInfo($t) {
  $blk = Login-Blocked $t; if ($blk) { return @{ login = $(if ($blk -eq 'skipped') { 'skipped' } else { 'refused' }) } }
  $r = Http -Ip $t.ip -Path '/ISAPI/System/deviceInfo' -Credential $t.cred -Port $t.port
  if ($r.code -eq 401) { Mark-Login $t 'refused'; return @{ login = 'refused' } }
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
  # 2.2.13: an answer that is not a search result (a login / error page that happens to be XML) = failed, never "no footage"
  if (-not $x.DocumentElement -or $x.DocumentElement.LocalName -notmatch '(?i)^CMSearchResult$') { Log ('search answer is not a search result: ' + $x.DocumentElement.LocalName); return $null }
  $segs = @()
  foreach ($m in (XFind $x 'searchMatchItem')) {
    $st = Parse-DeviceTime (XText $m 'startTime') $null; $en = Parse-DeviceTime (XText $m 'endTime') $null
    if ($st) { $segs += [pscustomobject]@{ start = $st.local; end = $(if ($en) { $en.local } else { $st.local }) } }
  }
  return @{ status = (XText $x 'responseStatusStrg'); segs = $segs }
}
function Get-HikAllSegs($t, [int]$trackId, [DateTime]$from, [DateTime]$to) {
  # 2.2.13 (Codex 2.2.12 #5): EVERY clip between $from and $to. A full answer (200 clips or "MORE") is split in half until each
  # part is complete; a part that can not be read completely (200+ clips in 2 hours, a failed search, or the search budget used
  # up) = $null: unknown, never treated as continuous footage.
  if ([int]$script:NhSearchBudget -le 0) { Log ('footage search budget used up (track ' + $trackId + ')'); return $null }
  $script:NhSearchBudget = [int]$script:NhSearchBudget - 1
  $r = Hik-Search $t $trackId $from $to 200
  if ($null -eq $r) { return $null }
  $segs = @($r.segs)
  $full = ($segs.Count -ge 200 -or [string]$r.status -match '(?i)more')
  if (-not $full) { return ,$segs }
  if (($to - $from).TotalHours -le 2) { Log ('track ' + $trackId + ': 200+ clips in ' + $from + ' .. ' + $to + ' - can not be read completely'); return $null }
  $mid = $from.AddTicks([long](($to - $from).Ticks / 2))
  $a = Get-HikAllSegs $t $trackId $from $mid; if ($null -eq $a) { return $null }
  $b = Get-HikAllSegs $t $trackId $mid $to; if ($null -eq $b) { return $null }
  return ,@(@($a) + @($b))
}
function Get-NhContinuousStart([object[]]$segs, [double]$maxGapHours) {
  # 2.2.13 (Codex 2.2.12 #5): merge the clips (oldest first), then walk the merged stretches from the newest back; the footage is
  # continuous back to the start of the stretch after the first REAL empty time longer than $maxGapHours (end of one stretch to
  # the start of the next - not "does a 36 h window hold a clip"). @{ start; hole } ($hole = a hole ended it); $null = no clips.
  $s = @($segs | Where-Object { $_ -and $_.start } | Sort-Object { $_.start })
  if (-not $s.Count) { return $null }
  $m = New-Object System.Collections.Generic.List[object]
  foreach ($g in $s) {
    $gEnd = $(if ($g.end -and $g.end -ge $g.start) { $g.end } else { $g.start })
    if ($m.Count -and $g.start -le $m[$m.Count - 1].end) { if ($gEnd -gt $m[$m.Count - 1].end) { $m[$m.Count - 1].end = $gEnd } }
    else { $m.Add([pscustomobject]@{ start = $g.start; end = $gEnd }) }
  }
  $cur = $m[$m.Count - 1].start; $hole = $false
  for ($i = $m.Count - 2; $i -ge 0; $i--) {
    if (($cur - $m[$i].end).TotalHours -gt $maxGapHours) { $hole = $true; break }
    $cur = $m[$i].start
  }
  return @{ start = $cur; hole = $hole }
}
function Get-HikContinuousDays($t, [int]$trackId, [DateTime]$anchor, [DateTime]$nowLocal, [int]$daysHeld, $tz = $null) {
  # how many days back from now the footage is continuous. An empty stretch longer than 36 h = a hole: retention stops there.
  # A search that fails = $null (unknown, never a pass).
  # 2.2.12 (Codex P1-8): every day up to the target (+1) or 60 days, whichever is more, is checked; older days only sampled
  # ($script:NhContinuousSampledFrom then says from which day; 0 = every day checked).
  # 2.2.13 (Codex 2.2.12 #5): 2.2.12 asked "does each 36 h window starting every 24 h hold any clip?", so a 40 h hole between two
  # window starts passed. Now every clip of that part is read (7-day searches, a full answer split until complete) and the real
  # empty stretches between neighbouring clips are measured. A full answer that can not be split complete = unknown.
  $script:NhContinuousSampledFrom = 0
  $maxGapH = 36
  $tg = [int]$script:NhTargetDays
  $daily = [math]::Min($daysHeld, [math]::Max($tg + 1, 60))
  $script:NhSearchBudget = 400
  # the fully-read part: from ($daily + 2) days ago (the oldest clip is inside it when $daysHeld <= $daily) up to the newest clip
  $regionStart = $nowLocal.AddDays( - ($daily + 2))
  $top = $(if ($anchor -gt $nowLocal) { $anchor } else { $nowLocal }).AddMinutes(5)
  $all = @()
  $b1 = $top
  while ($b1 -gt $regionStart) {
    $b0 = $b1.AddDays(-7); if ($b0 -lt $regionStart) { $b0 = $regionStart }
    $part = Get-HikAllSegs $t $trackId $b0 $b1
    if ($null -eq $part) { return $null }
    $all += @($part)
    $b1 = $b0
  }
  $cr = Get-NhContinuousStart $all $maxGapH
  if ($null -eq $cr) { return 0 }
  $cs = $cr.start
  $span = $nowLocal - $cs
  # device stamps are local wall-clock: undo a DST shift between then and now (same as the oldest-clip count in Hik-Recording)
  if ($tz -and $tz.ok) { $span = $span.Add([TimeSpan]::FromMinutes((Tz-OffsetAtLocal $tz $cs) - (Tz-OffsetAtLocal $tz $nowLocal))) }
  $days = [int][math]::Floor($span.TotalDays); if ($days -lt 0) { $days = 0 }
  if ($cr.hole -or $daysHeld -le $daily) { return [math]::Min($days, $daysHeld) }
  # older footage exists past the fully-read part: continuous only if the footage reaches (within 36 h) the start of that part
  if ($cs -gt $nowLocal.AddDays(-$daily).AddHours($maxGapH)) { return [math]::Min($days, $daysHeld) }
  $ok = $daily
  # older than the day-by-day part: sampled only (said so on the report, never counted as checked)
  $pts = @(75, 90, 120, 180, 270, 365) + @($daysHeld)
  $pts = @($pts | Where-Object { $_ -gt $daily -and $_ -le $daysHeld } | Sort-Object -Unique)
  foreach ($d in $pts) {
    $from = $nowLocal.AddDays(-$d); $r = Hik-Search $t $trackId $from $from.AddHours(36) 1
    if ($null -eq $r) { return $null }
    if (-not @($r.segs).Count) { break }
    $ok = $d
  }
  if ($ok -gt $daily) { $script:NhContinuousSampledFrom = $daily + 1 }
  return $ok
}
function Hik-ParseTracks([string]$body) {
  # 2.2.13 (Codex 2.2.12 #7): $null = the answer is not a track list (empty, not XML, an error page): UNKNOWN, never "all on".
  # A real list (even an empty one) = a hashtable id -> track.
  $x = Xml $body; if (-not $x -or -not $x.DocumentElement) { return $null }
  if ($x.DocumentElement.LocalName -notmatch '(?i)^Track(List)?$') { return $null }
  $out = @{}
  foreach ($tr in (XFind $x 'Track')) {
    $id = 0; [void][int]::TryParse((XText $tr 'id'), [ref]$id); if (-not $id) { continue }
    $modes = @((XFind $tr 'ActionRecordingMode') | ForEach-Object { $_.InnerText.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    $rec = @((XFind $tr 'Record') | ForEach-Object { $_.InnerText.Trim() })
    $en = XText $tr 'Enable'
    # 2.2.14 (Codex 2.2.13 F9): only an explicit true / false is a known state. A missing or unrecognised Enable = $null (UNKNOWN,
    # never "on"); no schedule entries at all = hasSchedule $null (unknown), not "has a schedule".
    $enabled = $(if ($en -match '^(?i)true$') { $true } elseif ($en -match '^(?i)false$') { $false } else { $null })
    # 2.2.15 (Codex 2.2.14 R6): every Record value must be an explicit true / false. One value that is neither (empty, 'unknown',
    # garbage) makes the schedule UNKNOWN ($null) - never "known off" (which the fix would then write over blindly).
    $badRec = @($rec | Where-Object { $_ -notmatch '^(?i)(true|false)$' })
    $sched = $(if (-not $rec.Count -or $badRec.Count) { $null } else { [bool](@($rec | Where-Object { $_ -match '^(?i)true$' }).Count) })
    $out[$id] = [pscustomobject]@{ id = $id; enabled = $enabled; modes = $modes; hasSchedule = $sched }
  }
  return $out
}
function Hik-ReadTracks($t) {
  # 2.2.13: @{ ok; map; why } - ok only for a 200 answer that is a real track list
  $r = Http -Ip $t.ip -Path '/ISAPI/ContentMgmt/record/tracks' -Credential $t.cred -Port $t.port
  if ($r.code -ne 200) { return @{ ok = $false; map = @{}; why = ('answer ' + $r.code); body = '' } }
  $m = Hik-ParseTracks ([string]$r.body)
  if ($null -eq $m) { return @{ ok = $false; map = @{}; why = 'the answer was not a recording list'; body = '' } }
  return @{ ok = $true; map = $m; why = ''; body = [string]$r.body }
}
function Hik-Tracks($t) {
  # read-only checks: an unreadable list gives no tracks (the recording check then says "unknown" per camera)
  $rt = Hik-ReadTracks $t
  return $rt.map
}
function Hik-ReadChannel($t, [int]$ch) {
  # 2.2.13 (Codex 2.2.12 #6): read ONE NVR channel back: which camera address it really uses and whether it is online.
  # ok = both the channel list and the status list were real 200 answers. found = the channel is in the list.
  $res = @{ ok = $false; found = $false; ip = ''; online = $null; why = ''; statusFound = $false }
  $a = Http -Ip $t.ip -Path '/ISAPI/ContentMgmt/InputProxy/channels' -Credential $t.cred -Port $t.port
  $x = $(if ($a.code -eq 200) { Xml $a.body } else { $null })
  if (-not $x -or -not $x.DocumentElement -or $x.DocumentElement.LocalName -notmatch '(?i)^InputProxyChannelList$') { $res.why = 'the channel list could not be read (answer ' + $a.code + ')'; return $res }
  foreach ($c in (XFind $x 'InputProxyChannel')) { if ([string](XText $c 'id') -eq [string]$ch) { $res.found = $true; $res.ip = XText $c 'ipAddress' } }
  $s = Http -Ip $t.ip -Path '/ISAPI/ContentMgmt/InputProxy/channels/status' -Credential $t.cred -Port $t.port
  $y = $(if ($s.code -eq 200) { Xml $s.body } else { $null })
  if (-not $y -or -not $y.DocumentElement -or $y.DocumentElement.LocalName -notmatch '(?i)^InputProxyChannelStatusList$') { $res.why = 'the channel status could not be read (answer ' + $s.code + ')'; return $res }
  # 2.2.14: statusFound = the status list names this channel with an explicit online true/false (a positive reading)
  foreach ($c in (XFind $y 'InputProxyChannelStatus')) { if ([string](XText $c 'id') -eq [string]$ch) { $on = XText $c 'online'; if ($on -match '^(?i)(true|false)$') { $res.statusFound = $true; $res.online = ($on -match '^(?i)true$') } } }
  if ($null -eq $res.online) { $res.online = $false }
  $res.ok = $true
  return $res
}
function Hik-UpTime($t, [int]$timeout = 5) {
  # 2.2.13 (Codex 2.2.12 #8): the camera's own boot marker (seconds since it started), /ISAPI/System/status <deviceUpTime>.
  # @{ code; up } - up = $null when the camera does not give it. UNVERIFIED on real cameras (some models may not offer it).
  $r = Http -Ip $t.ip -Path '/ISAPI/System/status' -Credential $t.cred -Port $t.port -Timeout $timeout
  $up = $null
  if ($r.code -eq 200) { $v = XText (Xml $r.body) 'deviceUpTime'; $n = [double]0; if ($v -and [double]::TryParse($v, [ref]$n)) { $up = $n } }
  return @{ code = [int]$r.code; up = $up }
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
    $o = [pscustomobject]@{ ch = $c.ch; ip = $c.ip; online = $c.online; scheduled = $(if ($tr) { $(if ($tr.enabled -eq $false -or $tr.hasSchedule -eq $false) { $false } elseif ($null -eq $tr.enabled -or $null -eq $tr.hasSchedule) { $null } else { $true }) } else { $null }); mode = $(if ($tr) { $tr.modes -join '/' } else { '' });
                            recording_now = $false; newest = $null; oldest = $null; days_held = $null; detect = $c.detect }
    $old = Hik-Search $t $tid (New-Object DateTime(2000, 1, 1)) $nowLocal 1
    if ($old -and $old.segs.Count) { $o.oldest = $old.segs[0].start }
    # 2.2.14 (Codex 2.2.13 F5): a failed oldest-clip search leaves days held UNKNOWN for this camera, and says so (the summary
    # counts every camera with unknown retention as NOT CHECKED, whichever search failed)
    elseif ($null -eq $old) { Log ('ch ' + $c.ch + ': oldest-clip search failed - days held unknown'); $o | Add-Member -NotePropertyName days_note -NotePropertyValue 'unknown (search failed)' -Force }
    $new = Hik-Search $t $tid $nowLocal.AddHours(-2) $nowLocal.AddMinutes(5) 50
    if ($new -and $new.segs.Count) { $o.newest = ($new.segs | Sort-Object end | Select-Object -Last 1).end }
    elseif ($o.oldest -or $null -eq $old) { $wk = Hik-Search $t $tid $nowLocal.AddDays(-7) $nowLocal 200; if ($wk -and $wk.segs.Count) { $o.newest = ($wk.segs | Sort-Object end | Select-Object -Last 1).end } }
    if ($o.newest) { $o.recording_now = (($nowLocal - $o.newest).TotalMinutes -le [double]$script:Opt.FreshMinutes) }
    if (-not $o.oldest -and $o.newest -and -not $o.PSObject.Properties['days_note']) { Log ('ch ' + $c.ch + ': recent clips but the oldest-clip search found none - days held unknown'); $o | Add-Member -NotePropertyName days_note -NotePropertyValue 'unknown (oldest clip not found)' -Force }
    if ($o.oldest) {
      # count in real elapsed time: device stamps are local wall-clock, so undo the DST shift (else 1 h short across a DST change)
      $span = $nowLocal - $o.oldest
      if ($tm -and $tm.tz -and $tm.tz.ok) { $span = $span.Add([TimeSpan]::FromMinutes((Tz-OffsetAtLocal $tm.tz $o.oldest) - (Tz-OffsetAtLocal $tm.tz $nowLocal))) }
      $o.days_held = [int][math]::Floor($span.TotalDays)
      # 2.2.4 (Codex re-review): the oldest clip alone is not retention: a full drive with 1 day of footage plus one old locked /
      # event clip said "45-day target met". Footage must be there all the way back: probe days in between; a gap ends it.
      $cd = Get-HikContinuousDays $t $tid $(if ($o.newest) { $o.newest } else { $nowLocal }) $nowLocal ([int]$o.days_held) $(if ($tm) { $tm.tz } else { $null })
      if ($null -eq $cd) { Log ('ch ' + $c.ch + ': footage check between ' + $o.oldest + ' and now failed - days held unknown'); $o.days_held = $null; $o | Add-Member -NotePropertyName days_note -NotePropertyValue 'unknown (search failed)' -Force }
      elseif ($cd -lt $o.days_held) { Log ('ch ' + $c.ch + ': oldest clip ' + $o.oldest + ' but footage is continuous only ' + $cd + ' days back'); $o | Add-Member -NotePropertyName days_note -NotePropertyValue ('older clip ' + (Fmt-Local $o.oldest 'MMM d') + ' is isolated') -Force; $o.days_held = $cd }
      if ($null -ne $cd -and [int]$script:NhContinuousSampledFrom -gt 0) { Log ('ch ' + $c.ch + ': footage checked every day for ' + ($script:NhContinuousSampledFrom - 1) + ' days; older days only sampled'); $o | Add-Member -NotePropertyName days_note -NotePropertyValue ('every day checked for ' + ($script:NhContinuousSampledFrom - 1) + ' days, older days only sampled') -Force }
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
function Onvif-TimeNoLogin($t, [int]$timeout = 3) {
  # 1.4: read-only clock read WITHOUT a login. ONVIF lets anyone ask GetSystemDateAndTime (so a client can line up its clock
  # before it logs in), so no password is sent and nothing can lock. Returns $null when the device does not answer it.
  $env = '<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:x="' + $script:NsDev + '"><s:Body><x:GetSystemDateAndTime/></s:Body></s:Envelope>'
  $r = Http -Ip $t.ip -Method 'POST' -Path '/onvif/device_service' -Body $env -ContentType 'application/soap+xml; charset=utf-8' -Port $t.port -Scheme $(if ($script:Opt.MockUrl) { '' } else { 'http' }) -Timeout $timeout -NoLogBody
  $x = Xml $r.body; if ($r.code -ne 200 -or -not $x) { return $null }
  $u = @(XFind $x 'UTCDateTime') | Select-Object -First 1; if (-not $u) { return $null }
  try { $utc = New-Object DateTime([int](XText $u 'Year'), [int](XText $u 'Month'), [int](XText $u 'Day'), [int](XText $u 'Hour'), [int](XText $u 'Minute'), [int](XText $u 'Second'), ([DateTimeKind]::Utc)) } catch { return $null }
  return @{ utc = $utc; mode = (XText $x 'DateTimeType') }
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
  $blk = Login-Blocked $t; if ($blk) { return @{ login = $(if ($blk -eq 'skipped') { 'skipped' } else { 'refused' }) } }
  $r = Unv-Get $t '/LAPI/V1.0/System/DeviceInfo'
  if ($r.login -eq 'refused') { Mark-Login $t 'refused' }
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
function Dw-Key($t) { return ([string]$t.ip + ':' + (Dw-Port $t)) }
function Dw-Login($t) {
  if ($t.token) { return $true }
  $k = Dw-Key $t
  if ($script:DwTokens.ContainsKey($k) -and $script:DwTokens[$k].token -and [object]::ReferenceEquals($script:DwTokens[$k].cred, $t.cred)) { $t.token = $script:DwTokens[$k].token; return $true }   # 1.4: reuse this run's session (same login) - no second login
  if (Login-Blocked $t) { return $false }   # skipped (empty password) or already refused in this run: nothing is sent
  $body = (@{ username = $t.cred.UserName; password = (Plain $t.cred); setCookie = $false } | ConvertTo-Json -Compress)
  $r = Http -Ip $t.ip -Method 'POST' -Path '/rest/v3/login/sessions' -Body $body -ContentType 'application/json' -Port (Dw-Port $t) -Scheme (Dw-Scheme) -NoLogBody
  $body = $null
  if ($r.code -ne 200) { Mark-Login $t $(if ($r.code -in @(401, 403)) { 'refused' } else { 'noanswer' }); return $false }
  try { $t.token = ($r.body | ConvertFrom-Json).token } catch {}
  if ($t.token) {
    if ($script:DwTokens.ContainsKey($k) -and $script:DwTokens[$k].token) { $script:DwOld += @(@{ k = $k; token = $script:DwTokens[$k].token }) }   # another login on the same server: still log that one out
    $script:DwTokens[$k] = @{ token = [string]$t.token; cred = $t.cred }
  }
  return [bool]$t.token
}
function Close-NvrSessions {
  <#
  .SYNOPSIS 1.4: log out of every DW session this run opened (DELETE /rest/v3/login/sessions/<token>). Safe to call twice; never throws.
  Callers run it in a finally block, so the logout is sent even when a check stopped with an error.
  #>
  $n = 0; $list = @($script:DwOld); $script:DwOld = @()
  foreach ($k in @($script:DwTokens.Keys)) { $list += @(@{ k = $k; token = $script:DwTokens[$k].token }); $script:DwTokens.Remove($k) }
  foreach ($e in $list) {
    $k = [string]$e.k; $tok = [string]$e.token
    if (-not $tok) { continue }
    $i = $k.LastIndexOf(':'); $ip = $k.Substring(0, $i); $port = [int]$k.Substring($i + 1)
    try {
      $r = Http -Ip $ip -Method 'DELETE' -Path ('/rest/v3/login/sessions/' + [uri]::EscapeDataString($tok)) -Headers @{ Authorization = ('Bearer ' + $tok) } -Port $port -Scheme (Dw-Scheme) -ContentType 'application/json' -Timeout 5
      if ($r.code -ge 200 -and $r.code -lt 300) { $n++; Log ('DW logout: session closed on ' + $ip) } else { Log ('DW logout on ' + $ip + ': answer ' + $r.code + ' (DW ends the session by itself later)') }
    } catch { Log ('DW logout on ' + $ip + ' failed: ' + $_.Exception.Message) }
  }
  return $n
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
function Dw-ParseSched($d) {
  # 2.2.14 (Codex 2.2.13 F6/F9): only an explicit true/false recording flag is known; anything else = $null (UNKNOWN, never "on")
  if (-not $d -or -not $d.PSObject.Properties['schedule'] -or -not $d.schedule) { return $null }
  if (-not $d.schedule.PSObject.Properties['isEnabled']) { return $null }
  $v = $d.schedule.isEnabled
  if ($v -is [bool]) { return $v }
  if ([string]$v -match '^(?i)true$') { return $true }
  if ([string]$v -match '^(?i)false$') { return $false }
  return $null
}
function Dw-ReadDevices($t) {
  # 2.2.14 (Codex 2.2.13 F6): @{ ok; devs; why }. ok only when the device list was a real 200 answer that parsed as a list of
  # devices; a failed / unparseable answer is "could not read", never an empty list (2.2.13 turned it into "all on").
  $r = Http -Ip $t.ip -Path '/rest/v3/devices?_with=id,name,status,model,vendor,url,schedule,parameters,physicalId,mac' -Headers @{ Authorization = ('Bearer ' + $t.token) } -Port (Dw-Port $t) -Scheme (Dw-Scheme) -ContentType 'application/json'
  if ($r.code -ne 200) { return @{ ok = $false; devs = @(); why = ('answer ' + $r.code) } }
  $j = $null; $parsed = $false
  try { $j = ([string]$r.body | ConvertFrom-Json); $parsed = $true } catch {}
  if ($parsed -and [string]$r.body -match '^\s*\[\s*\]\s*$') { return @{ ok = $true; devs = @(); why = '' } }   # a real, empty list
  if (-not $parsed -or $null -eq $j -or [string]$r.body -notmatch '^\s*\[') { return @{ ok = $false; devs = @(); why = 'the answer was not a camera list' } }
  $out = @()
  foreach ($d in @($j)) {
    if (-not $d) { continue }
    if (-not $d.PSObject.Properties['id'] -or -not [string]$d.id) { return @{ ok = $false; devs = @(); why = 'a camera in the list has no id (not a DW camera list)' } }
    $ip = ''; $m = [regex]::Match([string]$d.url, '//([^/:]+)'); if ($m.Success) { $ip = $m.Groups[1].Value } elseif ($d.url) { $ip = [string]$d.url }
    $fw = ''; if ($d.parameters -and $d.parameters.firmware) { $fw = [string]$d.parameters.firmware } elseif ($d.firmware) { $fw = [string]$d.firmware }
    $mac = $(if ($d.mac) { [string]$d.mac } elseif ([string]$d.physicalId -match '^([0-9A-Fa-f]{2}[-:]){5}[0-9A-Fa-f]{2}$') { [string]$d.physicalId } else { '' })
    $out += [pscustomobject]@{ id = [string]$d.id; name = [string]$d.name; mac = $mac.ToUpper().Replace('-', ':'); ip = $ip; status = [string]$d.status; model = [string]$d.model; vendor = [string]$d.vendor; scheduled = (Dw-ParseSched $d); firmware = $fw }
  }
  return @{ ok = $true; devs = $out; why = '' }
}
function Dw-Devices($t) {
  # read-only callers: an unreadable list gives no cameras (they then say "no cameras found" / not in the list - never green)
  $rd = Dw-ReadDevices $t
  return @($rd.devs)
}
function Dw-Periods($t, [string]$id, [DateTime]$nowUtc) {
  $j = Dw-Get $t ('/ec2/recordedTimePeriods?cameraId=' + [uri]::EscapeDataString($id) + '&startTime=0&endTime=' + (Utc-ToMs $nowUtc) + '&detail=60000&flat=true')
  $p = @(); if ($j -and $j.reply) { $p = @($j.reply) } elseif ($j) { $p = @($j) }
  $p = @($p | Where-Object { $_ -and $null -ne $_.startTimeMs } | Sort-Object { [double]$_.startTimeMs })
  if (-not $p.Count) { return $null }
  $last = $p[$p.Count - 1]
  # 2.2.4: the oldest period that is part of continuous footage back from the newest (a gap over 36 h ends it; an isolated old chunk is not retention)
  $fi = $p.Count - 1
  while ($fi -gt 0) { $pe = [double]$p[$fi - 1].startTimeMs + [math]::Max(0, [double]$p[$fi - 1].durationMs); if (([double]$p[$fi].startTimeMs - $pe) -gt 129600000) { break }; $fi-- }
  $first = $p[$fi]
  $live = ([double]$last.durationMs -lt 0)
  $lastEnd = $(if ($live) { $nowUtc } else { Ms-ToUtc ([double]$last.startTimeMs + [double]$last.durationMs) })
  return @{ oldest = (Ms-ToUtc $first.startTimeMs); newest = $lastEnd; live = $live }
}

# ================= Get-RecordingStatus =================
# ---- Nov 3 2026: stream audit (read-only GETs): sub-stream on?, main/sub resolution, bitrate, frame rate ----
function Hik-Streams($t) {
  $out = @()
  foreach ($path in @('/ISAPI/ContentMgmt/StreamingProxy/channels', '/ISAPI/Streaming/channels')) {
    $r = Http -Ip $t.ip -Path $path -Credential $t.cred -Port $t.port
    $x = Xml $r.body; if (-not $x) { continue }
    foreach ($c in (XFind $x 'StreamingChannel')) {
      $id = [int](XText $c 'id'); if (-not $id) { continue }
      $v = @(XFind $c 'Video') | Select-Object -First 1
      $q = (XText $v 'videoQualityControlType').ToUpper()
      $kb = $(if ($q -eq 'VBR' -and (XText $v 'vbrUpperCap')) { [int](XText $v 'vbrUpperCap') } else { [int](XText $v 'constantBitRate') })
      $en = ((XText $c 'enabled') -ne 'false') -and (-not $v -or (XText $v 'enabled') -ne 'false')
      $fr = [int](XText $v 'maxFrameRate'); $fps = $(if ($fr -ge 100) { [math]::Round($fr / 100, 1) } else { $fr })
      $out += [pscustomobject]@{ ch = [int][math]::Floor($id / 100); stream = ($id % 100); enabled = $en; w = [int](XText $v 'videoResolutionWidth'); h = [int](XText $v 'videoResolutionHeight'); fps = $fps; kbps = $kb; rc = $q; codec = (XText $v 'videoCodecType') }
    }
    if ($out.Count) { break }
  }
  return $out
}
function Get-StreamLimitKbps([int]$w, [int]$h) {
  # WireIt rule of thumb (Moshe-approved Nov 3 2026): > 8 Mbps main at 4 MP or less, > 16 Mbps at 8 MP is excessive
  $px = [double]$w * $h
  if ($px -le 4.3e6) { return 8192 }
  if ($px -le 8.9e6) { return 16384 }
  return 24576
}
function Judge-Streams($streams) {
  $res = [ordered]@{ checked = 0; ok = $true; flags = @(); cameras = @() }
  $s = @($streams); if (-not $s.Count) { return [pscustomobject]$res }
  $mains = @($s | Where-Object { $_.stream -eq 1 -and $_.enabled -and $_.fps -gt 0 })
  $major = $null
  if ($mains.Count) { $major = ($mains | Group-Object fps | Sort-Object Count -Descending | Select-Object -First 1).Name }
  $flags = New-Object System.Collections.Generic.List[string]
  foreach ($g in ($s | Group-Object ch | Sort-Object { [int]$_.Name })) {
    $ch = [int]$g.Name; $m = @($g.Group | Where-Object { $_.stream -eq 1 }) | Select-Object -First 1; $sub = @($g.Group | Where-Object { $_.stream -eq 2 }) | Select-Object -First 1
    if (-not $m) { continue }
    $res.checked++
    $mine = @()
    $fmt = { param($x) if (-not $x) { return 'none' }; if (-not $x.enabled) { return 'OFF' }; return ('' + $x.w + 'x' + $x.h + ' ' + $x.fps + ' fps ' + [math]::Round($x.kbps / 1024, 1) + ' Mbps' + $(if ($x.rc) { ' ' + $x.rc } else { '' })) }
    if (-not $sub -or -not $sub.enabled) { $mine += 'sub-stream off' }
    $lim = Get-StreamLimitKbps $m.w $m.h
    if ($m.enabled -and $m.kbps -gt $lim) { $mine += ('main bitrate ' + [math]::Round($m.kbps / 1024, 1) + ' Mbps is high for ' + [math]::Round(($m.w * $m.h) / 1e6, 1) + ' MP (max ' + ($lim / 1024) + ')') }
    if ($null -ne $major -and $m.enabled -and $m.fps -gt 0 -and [string]$m.fps -ne [string]$major) { $mine += ('' + $m.fps + ' fps, the others run ' + $major) }
    $line = 'Camera ' + $ch + ': main ' + (& $fmt $m) + ' | sub ' + (& $fmt $sub)
    if ($mine.Count) { Warn ($line + ' - ' + ($mine -join '; ')); foreach ($x in $mine) { $flags.Add('cam ' + $ch + ': ' + $x) } } else { Ok $line }
    $res.cameras += [pscustomobject]@{ ch = $ch; main = $m; sub = $sub; flags = $mine }
  }
  $res.flags = @($flags); $res.ok = ($flags.Count -eq 0)
  return [pscustomobject]$res
}

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
  $script:NhTargetDays = $TargetDays
  $t = Resolve-Target $Ip $Vendor $Credential $Port
  Say ''; Say ('----- Recording check: ' + $Ip + ' (target ' + $TargetDays + ' days) -----') 'Cyan'
  $result = [ordered]@{ check = 'recording'; ip = $Ip; vendor = $t.vendor; streams = $null; target_days = $TargetDays; ok = $false; days_held = $null; shortest_days = $null; short_cameras = @(); target_pending = $false; recording = 0; channels = @(); disks = @(); problems = @(); log = $script:LogFile }
  $problems = New-Object System.Collections.Generic.List[string]
  $chans = @(); $disks = @(); $now = $null; $diskApi = $true
  $blk = Login-Blocked $t
  if ($blk) {
    # 1.6.1: no login sent (empty password) or already refused in this run -> NOT CHECKED, never an all-clear
    if ($t.vendor -eq 'DW') { $info = Dw-Info $t; if ($info) { Info ('DW Spectrum ' + $info.version + '  server "' + $info.name + '"') } }
    Warn ('Recorder ' + (Login-Words $blk) + '. Recording NOT CHECKED.')
    $result.problems = @($(if ($blk -eq 'noanswer') { 'no answer' } else { 'login ' + $blk })); return [pscustomobject]$result
  }
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
        $chans += [pscustomobject]@{ ch = $i; ip = $d.ip; online = $online; scheduled = $d.scheduled; recording_now = [bool]$recNow; mode = ''; newest = $(if ($p) { $p.newest } else { $null }); oldest = $(if ($p) { $p.oldest } else { $null }); days_held = $(if ($p) { [int][math]::Floor(($now - $p.oldest).TotalDays) } else { $null }); detect = $d.status; name = $d.name; mac = $d.mac; model = $d.model; vendor = $d.vendor }
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
  $filling = $false; $pending = $false
  $maxCap = ($disks | Measure-Object -Property capMB -Maximum).Maximum
  $big = @($disks | Where-Object { $_.capMB -ge 0.1 * $maxCap })   # a small system drive next to the media drives does not count
  $bigCap = ($big | Measure-Object -Property capMB -Sum).Sum; $bigFree = ($big | Measure-Object -Property freeMB -Sum).Sum
  if ($bigCap -gt 0) { $filling = (($bigFree / $bigCap) -gt $(if ($t.vendor -eq 'DW') { 0.12 } else { 0.03 })) }   # DW keeps ~10% free on purpose
  if ($capT -gt 0) { Info ('Total ' + [math]::Round($capT / 1024) + ' GB, ' + [math]::Round(100 * ($capT - $freeT) / $capT) + '% used.') }

  Say ''; Say 'Cameras:' 'Cyan'
  $rec = 0; $notRec = @(); $minDays = $null; $maxDays = $null; $schedUnk = @()
  foreach ($c in ($chans | Sort-Object ch)) {
    # 1.4: a DW camera is named by its DW name + IP (the running number is only DW's list order, it means nothing on site)
    $label = $(if ($t.vendor -eq 'DW' -and $c.name) { [string]$c.name + $(if ($c.ip) { ' (' + $c.ip + ')' } else { '' }) } else { 'Camera ' + $c.ch + $(if ($c.ip) { ' (' + $c.ip + ')' } else { '' }) })
    $tag = $(if ($t.vendor -eq 'DW' -and ($c.name -or $c.ip)) { $(if ($c.name) { $label } else { $c.ip }) } else { $c.ch })
    if ($null -ne $c.days_held) { if ($null -eq $minDays -or $c.days_held -lt $minDays) { $minDays = $c.days_held }; if ($null -eq $maxDays -or $c.days_held -gt $maxDays) { $maxDays = $c.days_held } }
    $note = $(if ($c.PSObject.Properties['days_note'] -and $c.days_note) { ' - ' + $c.days_note } else { '' })
    $held = $(if ($null -ne $c.days_held) { ', footage continuous for ' + $c.days_held + ' days' + $(if ($note) { $note } else { ' (back to ' + (Fmt-Local $c.oldest 'MMM d') + ')' }) } elseif ($note) { ', days held ' + $c.days_note } else { '' })
    # 2.2.7 (Codex file-by-file F10): what the recorder KNOWS about a camera comes first: one it reports OFFLINE, or with recording
    # turned OFF in its schedule, is not recording - a clip from a few minutes ago (before it dropped) does not make it "recording"
    if ($c.online -eq $false) { Bad ($label + ': camera OFFLINE, not recording' + $(if ($c.newest) { ' (last footage ' + (Fmt-Local $c.newest) + ')' } else { '' })); $notRec += $tag }
    elseif ($c.scheduled -eq $false) { Bad ($label + ': recording is turned OFF in its schedule' + $held); $notRec += $tag }
    # 2.2.15 (Codex 2.2.14 R5): fresh footage says the camera records NOW; it does not say the schedule keeps it recording.
    # A Hikvision / DW camera whose schedule could not be read is shown with its footage, but the schedule is NOT CHECKED (a problem).
    elseif (($c.recording_now -or ($c.mode -match '(?i)motion|alarm|event|smart|vmd' -and $c.newest -and ($now - $c.newest).TotalHours -lt 24)) -and $t.vendor -in @('Hikvision', 'DW') -and $null -eq $c.scheduled) {
      $rec++; $schedUnk += $tag
      Warn ($label + ': footage is fresh' + $(if (-not $c.recording_now -and $c.newest) { ' (last clip ' + (Fmt-Local $c.newest) + ')' } else { '' }) + $held + ', but its recording schedule could NOT be read - schedule NOT CHECKED. Look at its recording schedule on the recorder.')
    }
    elseif ($c.recording_now) { $rec++; Ok ($label + ': recording' + $held) }
    elseif ($c.mode -match '(?i)motion|alarm|event|smart|vmd' -and $c.newest -and ($now - $c.newest).TotalHours -lt 24) { $rec++; Ok ($label + ': motion recording, last clip ' + (Fmt-Local $c.newest) + $held) }
    elseif ($c.newest) { Bad ($label + ': NOT recording - last footage ' + (Fmt-Local $c.newest) + $held); $notRec += $tag }
    else { Bad ($label + ': NO footage found at all'); $notRec += $tag }
  }
  if (-not $chans.Count) { Warn 'No camera channels found on this recorder.'; $problems.Add('no channels') }
  # 2.2.4; 2.2.14 (Codex 2.2.13 F5): EVERY camera whose days held are unknown (any failed search, or footage with no measured
  # oldest clip) is NOT CHECKED and keeps the result from being green, even when another camera meets the target
  $unk = @($chans | Where-Object { $null -eq $_.days_held -and (($_.PSObject.Properties['days_note'] -and $_.days_note) -or $_.newest -or $_.recording_now) })
  if ($unk.Count -and $null -ne $maxDays) { Warn ('' + $unk.Count + ' camera(s): days held NOT CHECKED (could not be measured): ' + (@($unk | ForEach-Object { $(if ($t.vendor -eq 'DW' -and $_.name) { [string]$_.name } else { 'cam ' + $_.ch }) }) -join ', ') + '.'); $problems.Add(('days held NOT CHECKED on ' + $unk.Count + ' camera(s)')) }
  if ($schedUnk.Count) { $problems.Add(('recording schedule NOT CHECKED on ' + $schedUnk.Count + ' camera(s): ' + (@($schedUnk | Select-Object -First 10) -join ', ') + $(if ($schedUnk.Count -gt 10) { ' and ' + ($schedUnk.Count - 10) + ' more (see the log)' } else { '' }))) }
  if ($notRec.Count) { $problems.Add(('' + $notRec.Count + ' camera(s) not recording: ' + (@($notRec | Select-Object -First 10) -join ', ') + $(if ($notRec.Count -gt 10) { ' and ' + ($notRec.Count - 10) + ' more (see the log)' } else { '' }))) }
  # stream audit (report only; never counted as a recording problem, never changes anything)
  $streams = $null
  if ($t.vendor -eq 'Hikvision') {
    Say ''; Say 'Streams (main / sub):' 'Cyan'
    try { $streams = Judge-Streams (Hik-Streams $t) } catch { Log ('streams: ' + $_.Exception.Message) }
    if (-not $streams -or -not $streams.checked) { Info 'Stream settings could not be read from this recorder (older firmware?). Nothing else is affected.' }
    elseif ($streams.ok) { Info ('All ' + $streams.checked + ' cameras: sub-stream on, bitrate and frame rate normal.') }
  } else { Say ''; Info 'Stream audit (sub-stream / bitrate / frame rate): Hikvision recorders only for now.' }

  # The recorder overwrites its oldest footage for ALL cameras together, so the deepest camera = how far back the drives reach.
  # A camera whose footage starts later was added / re-added or was not recording before that (listed, not counted as retention).
  $short = @(Get-RetentionShort $chans $TargetDays $maxDays)
  Say ''
  # 2.2.3 (Codex #23): every camera is judged on its OWN footage: one deep camera does not meet the target for the others. Short ones
  # are a problem until somebody confirms they were added later (the tool cannot know that).
  if ($short.Count) { Warn ('' + $short.Count + ' camera(s) have less footage than the ' + $TargetDays + '-day target (' + (($short | ForEach-Object { $(if ($t.vendor -eq 'DW' -and $_.name) { [string]$_.name } else { 'cam ' + $_.ch }) + ': ' + $_.days_held + ' days' }) -join ', ') + '): not recording before, or added later. Check they were not off.'); $problems.Add(('' + $short.Count + ' camera(s) below the ' + $TargetDays + '-day target')) }
  if ($null -ne $maxDays) {
    if ($maxDays -ge $TargetDays) { Say ('DAYS HELD: ' + $maxDays + ' days on the deepest camera (target ' + $TargetDays + ')' + $(if ($short.Count) { '; ' + $short.Count + ' camera(s) below it (above).' } else { '. OK.' })) $(if ($short.Count) { 'Yellow' } else { 'Green' }) }
    elseif (-not $diskApi) { Say ('DAYS HELD: only ' + $maxDays + ' days (target ' + $TargetDays + '). Could not read whether the drives are full - check the recorder''s Storage page.') 'Yellow'; $problems.Add('only ' + $maxDays + ' of ' + $TargetDays + ' days (drive fill unknown)') }
    # 2.2.15 (Codex 2.2.14 R9): a recorder that is still filling its drives is not a fault, but its target is NOT met yet:
    # never "target met", never ok. The result says how far it is (target_pending).
    elseif ($filling) { $pending = $true; Say ('DAYS HELD: ' + $maxDays + ' days so far (target ' + $TargetDays + '), still filling: the drives are not full yet, so this keeps growing. Target NOT reached yet. Check again after they fill.') 'Yellow' }
    else { Say ('DAYS HELD: only ' + $maxDays + ' days (target ' + $TargetDays + '). Drives are full and overwriting. Add storage or lower the recording bitrate.') 'Red'; $problems.Add('only ' + $maxDays + ' of ' + $TargetDays + ' days') }
  } elseif ($chans.Count) { Say 'DAYS HELD: unknown (no footage found to measure).' 'Red'; $problems.Add('days held unknown') }
  Say $(if ($problems.Count) { 'RESULT: ' + $problems.Count + ' problem(s): ' + ($problems -join '; ') } elseif ($pending) { 'RESULT: all ' + $rec + ' cameras recording, drives healthy; ' + $maxDays + ' days so far, still filling, ' + $TargetDays + '-day target not reached yet (not a fault).' } else { 'RESULT: all ' + $rec + ' cameras recording, drives healthy, ' + $TargetDays + '-day target met.' }) $(if ($problems.Count) { 'Red' } elseif ($pending) { 'Yellow' } else { 'Green' })
  $result.target_pending = [bool]($pending -and -not $problems.Count)
  $result.streams = $streams; $result.ok = ($problems.Count -eq 0 -and -not $pending); $result.days_held = $maxDays; $result.shortest_days = $minDays; $result.short_cameras = @($short | ForEach-Object { $_.ch }); $result.recording = $rec; $result.channels = $chans; $result.disks = $disks; $result.problems = @($problems); $result.log = $script:LogFile
  return [pscustomobject]$result
}

function Get-RetentionShort($chans, [int]$TargetDays, $maxDays) {
  # cameras whose OWN footage is under the target - only when the recorder as a whole reaches it (else the overall line says it)
  if ($null -eq $maxDays -or [int]$maxDays -lt $TargetDays) { return @() }
  return @(@($chans) | Where-Object { $null -ne $_.days_held -and [double]$_.days_held -lt $TargetDays })
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
function Judge-Clock([string]$label, $c, $ref, [string]$why = '') {
  $p = @()
  # 1.6.1: an unreadable clock is NOT CHECKED - not a wrong clock, and no time fix is offered for it
  if (-not $c) { Warn ($label + ': clock NOT CHECKED (' + $(if ($why) { Login-Words $why } else { 'could not read it - login refused or no answer' }) + '). Nothing to fix from this.'); return @('clock not checked') }
  if ($c.utc) {
    $drift = ($c.utc - $ref.utc).TotalSeconds; $dir = $(if ($drift -gt 0) { 'ahead' } else { 'behind' })
    if ([math]::Abs($drift) -ge [double]$script:Opt.DriftBadSec) { Bad ($label + ': clock is ' + (Fmt-Span $drift) + ' ' + $dir + '. Footage times are wrong - not usable as evidence until fixed.'); $p += ('clock ' + (Fmt-Span $drift) + ' ' + $dir) }
    elseif ([math]::Abs($drift) -ge [double]$script:Opt.DriftWarnSec) { Warn ($label + ': clock is ' + (Fmt-Span $drift) + ' ' + $dir + '.'); $p += ('clock ' + (Fmt-Span $drift) + ' ' + $dir) }
    else { Ok ($label + ': clock correct (within ' + [math]::Max(1, [math]::Round([math]::Abs($drift))) + ' s).') }
  } else { Warn ($label + ': clock reading not understood - NOT CHECKED.'); $p += 'clock not checked' }
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
function Get-CameraTargets($t, [string[]]$CameraIps, [pscredential]$CameraCredential, [string[]]$FindIps = @()) {
  if ($t.vendor -eq 'DW' -and -not $CameraCredential) {
    $CameraIps = @(@($CameraIps) + @($FindIps))
    # 1.4: behind a DW server the camera passwords are not known (the DW login is NOT a camera login, so it is never tried on a
    # camera). Cameras from the fresh Find-cameras list get a NO-LOGIN clock read only (ONVIF GetSystemDateAndTime, no password sent).
    $out = @(); foreach ($i in (@($CameraIps | Where-Object { $_ -and $_ -ne $t.ip }) | Select-Object -Unique)) { $out += @{ ip = $i; vendor = 'NoLogin'; cred = $null; port = 0; token = $null; nologin = $true } }
    return $out
  }
  if (-not $CameraCredential -and (Login-Blocked $t)) { Info 'Cameras: not checked (no working recorder login, so no camera login is tried).'; return @() }
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
        [pscredential]$Credential, [int]$Port = 0, [switch]$IncludeCameras, [string[]]$CameraIps, [pscredential]$CameraCredential, [string[]]$FindIps, [switch]$NoLog)
  if (-not $NoLog) { Start-Log 'clock' }
  $t = Resolve-Target $Ip $Vendor $Credential $Port
  $ref = Get-ReferenceTime
  Say ''; Say ('----- Clock check: ' + $Ip + ' (compared with ' + $ref.source + ') -----') 'Cyan'
  if ($null -ne $ref.pcOffsetSec -and [math]::Abs($ref.pcOffsetSec) -ge 30) { Warn ('This PC''s own clock is off by ' + (Fmt-Span $ref.pcOffsetSec) + '; using internet time instead.') }
  $blk = Login-Blocked $t
  $c = $(if ($blk) { $null } else { Clock-Of $t }); $refR = Get-RefAt $ref   # 2.2.7 (F13): compared with the time it was read
  if (-not $blk) { $blk = Login-Blocked $t }   # Clock-Of may have just been refused
  $probs = @(Judge-Clock 'Recorder' $c $refR $blk)
  $cams = @()
  $camNc = 0
  if ($IncludeCameras) {
    $tgs = @(Get-CameraTargets $t $CameraIps $CameraCredential $FindIps)
    $nl = @($tgs | Where-Object { $_.nologin }); $tgs = @($tgs | Where-Object { -not $_.nologin })
    foreach ($ct in $tgs) {
      if ($ct.vendor -eq 'Auto') { $ct.vendor = Detect-Vendor $ct.ip 0 }
      $cc = Clock-Of $ct; $refC = Get-RefAt $ref   # 2.2.7 (F13)
      $cp = @(Judge-Clock ('Camera ' + $ct.ip) $cc $refC)
      $cams += [pscustomobject]@{ ip = $ct.ip; ok = ($cp.Count -eq 0); problems = $cp; drift_sec = $(if ($cc -and $cc.utc) { [math]::Round(($cc.utc - $refC.utc).TotalSeconds) } else { $null }) }
    }
    if ($nl.Count) {
      # 1.4 (YKW Elm): the cameras Find cameras just found, read WITHOUT a login - one summary line, only the wrong clocks listed
      if ($nl.Count -gt 300) { Info ('Camera clocks: reading the first 300 of ' + $nl.Count + ' cameras.'); $nl = @($nl | Select-Object -First 300) }
      Info ('Camera clocks: ' + $nl.Count + ' camera(s) from the Find cameras list, read WITHOUT a login (no password is sent to any camera).')
      $okN = 0; $okMax = 0; $noAns = @()
      foreach ($ct in $nl) {
        $u = Onvif-TimeNoLogin $ct; $refN = Get-RefAt $ref   # 2.2.7 (F13)
        if (-not $u -or -not $u.utc) { $noAns += $ct.ip; continue }
        $drift = ($u.utc - $refN.utc).TotalSeconds; $dir = $(if ($drift -gt 0) { 'ahead' } else { 'behind' }); $cp = @()
        if ([math]::Abs($drift) -ge [double]$script:Opt.DriftBadSec) { Bad ('Camera ' + $ct.ip + ': clock is ' + (Fmt-Span $drift) + ' ' + $dir + '. Its footage times are wrong.'); $cp = @('clock ' + (Fmt-Span $drift) + ' ' + $dir) }
        elseif ([math]::Abs($drift) -ge [double]$script:Opt.DriftWarnSec) { Warn ('Camera ' + $ct.ip + ': clock is ' + (Fmt-Span $drift) + ' ' + $dir + '.'); $cp = @('clock ' + (Fmt-Span $drift) + ' ' + $dir) }
        else { $okN++; $okMax = [math]::Max($okMax, [math]::Abs($drift)) }
        $cams += [pscustomobject]@{ ip = $ct.ip; ok = ($cp.Count -eq 0); problems = $cp; drift_sec = [math]::Round($drift); nologin = $true }
      }
      if ($okN) { Ok ('' + $okN + ' camera clock(s) correct (within ' + [math]::Max(1, [math]::Round($okMax)) + ' s).') }
      if ($noAns.Count) { $camNc = $noAns.Count; Info ('' + $noAns.Count + ' camera(s) did not answer the no-login time read - not checked: ' + (@($noAns | Select-Object -First 8) -join ', ') + $(if ($noAns.Count -gt 8) { ' and ' + ($noAns.Count - 8) + ' more (see the log)' } else { '' })); Log ('no-login clock read, no answer: ' + ($noAns -join ', ')) }
    }
    if (-not $cams.Count -and -not $camNc) {
      if ($t.vendor -eq 'DW') { Info 'Camera clocks: not checked - no fresh Find cameras list (run Find cameras first; Check this site does it by itself).' }
      else { Info 'No cameras reachable by IP from this PC (cameras on the NVR''s own PoE ports normally take the NVR''s time).' }
    }
  }
  $all = @($probs) + @($cams | ForEach-Object { $ip = $_.ip; $_.problems | ForEach-Object { 'camera ' + $ip + ': ' + $_ } })
  $real = @($all | Where-Object { $_ -notmatch 'not checked' }); $nc = @($all | Where-Object { $_ -match 'not checked' })
  $nlOnly = ($real.Count -and -not @($real | Where-Object { $_ -notmatch '^camera ' }).Count -and $t.vendor -eq 'DW')
  if ($nlOnly) { Say ('RESULT: camera clock(s) wrong (' + (@($real | Select-Object -First 6) -join '; ') + '). Behind a DW server: set the time on the camera''s own page (or let DW sync camera time) - the Toolkit has no camera password here, so "Fix time" does not change them.') 'Red' }
  elseif ($real.Count) { Say ('RESULT: time needs fixing (' + ($real -join '; ') + '). "Fix time" (Set-NtpTime) fixes it.' + $(if ($nc.Count) { ' Not checked: ' + ($nc -join '; ') + '.' } else { '' })) 'Red' }
  elseif ($nc.Count) { $ncs = @($nc | Where-Object { $_ -ne 'clock not checked' }); Say ('RESULT: Clock: not checked' + $(if ($ncs.Count) { ' (' + ($ncs -join '; ') + ')' } else { '' }) + '. Nothing to fix from this check.') 'Yellow' }
  else { Say 'RESULT: time is right and stays right (NTP + US Eastern).' 'Green' }
  return [pscustomobject]@{ check = 'clock'; ip = $Ip; vendor = $t.vendor; ok = ($all.Count -eq 0); cameras_not_checked = $camNc; notChecked = ($nc.Count -gt 0 -and $real.Count -eq 0); reference = $ref.source;
    drift_sec = $(if ($c -and $c.utc) { [math]::Round(($c.utc - $refR.utc).TotalSeconds) } else { $null }); mode = $(if ($c) { $c.mode } else { '' });
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
  if (-not $still.ok) { return @{ ok = $false; why = 'saved, but its time settings could not be read back to check them' } }   # 2.2.3 (Codex #41)
  if ($still.changes.Count) { return @{ ok = $false; why = ('saved, but it still reads back wrong: ' + ($still.changes -join '; ')) } }
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
  if (-not $still.ok) { return @{ ok = $false; why = 'saved, but its time settings could not be read back to check them' } }   # 2.2.3 (Codex #41)
  if ($still.changes.Count) { return @{ ok = $false; why = ('saved, but it still reads back wrong: ' + ($still.changes -join '; ')) } }
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
  if ($IncludeCameras) { foreach ($ct in (Get-CameraTargets $t $CameraIps $CameraCredential)) { if ($ct.nologin) { continue }; if ($ct.vendor -eq 'Auto') { $ct.vendor = Detect-Vendor $ct.ip 0 }; $targets += @{ label = ('Camera ' + $ct.ip); t = $ct } } }
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
function Get-FwResultLine([int]$sec, [int]$old, [int]$notJudged) {
  if ($sec) { return @{ ok = $false; color = 'Red'; text = ('RESULT: ' + $sec + ' device(s) with known security holes, ' + $old + ' more on old firmware' + $(if ($notJudged) { ', ' + $notJudged + ' not checked' } else { '' }) + '. Plan updates (with the owner''s OK; an update reboots the device).') } }
  if ($notJudged) { return @{ ok = $false; color = 'Yellow'; text = ('RESULT: NOT fully checked - ' + $notJudged + ' device(s) could not be judged (model not in the list, or not readable). Check those on the maker''s site.' + $(if ($old) { ' ' + $old + ' on older firmware.' } else { '' })) } }
  if ($old) { return @{ ok = $true; color = 'Yellow'; text = ('RESULT: no known holes; ' + $old + ' device(s) on older firmware.') } }
  return @{ ok = $true; color = 'Green'; text = 'RESULT: firmware OK.' }
}
function Judge-Firmware([string]$label, [string]$model, [string]$fw, $ref, [switch]$Quiet) {
  $o = [ordered]@{ label = $label; model = $model; firmware = $fw; latest = ''; update_available = $null; advisories = @(); verdict = 'unknown'; note = ''; unlisted = $false }
  $cur = Parse-Fw $fw; $m = Find-RefModel $ref $model
  if (-not $m) {
    $o.unlisted = $true; $line = $label + ' ' + $model + ', firmware ' + $fw + ': model not in the reference list. Check the maker''s site.'
    if ($Quiet) { Log ('FW ' + $line) } else { Warn $line }   # 1.4: cameras -> one summary line (Write-FwUnlisted), each one in the log
    return [pscustomobject]$o
  }
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
function Write-FwUnlisted($items, [int]$noFw = 0) {
  # 1.4 (YKW Elm: 183 "model not in the reference list" lines drowned the result): one line for all of them, details in the log
  $u = @($items | Where-Object { $_.unlisted -and $_.label -like 'Camera *' })
  if ($u.Count) { $ms = @($u | ForEach-Object { [string]$_.model } | Where-Object { $_ } | Select-Object -Unique); Warn ('' + $ms.Count + ' camera model(s) not in the reference list (' + $u.Count + ' camera(s): ' + (@($ms | Select-Object -First 4) -join ', ') + $(if ($ms.Count -gt 4) { ', ...' } else { '' }) + ') - not judged; each one is listed in the log.') }
  if ($noFw) { Info ('' + $noFw + ' camera(s): DW does not report their firmware (listed in the log).') }
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
  $items = @(); $fwUnread = 0
  switch ($t.vendor) {
    'Hikvision' {
      $di = Hik-DeviceInfo $t
      if ($di.login -in @('skipped', 'refused')) { Warn ('Firmware NOT CHECKED (' + (Login-Words $di.login) + ').'); return [pscustomobject]@{ check = 'firmware'; ip = $Ip; vendor = $t.vendor; ok = $false; notChecked = $true; devices = @(); problems = @('not checked (login ' + $di.login + ')'); log = $script:LogFile } }
      if ($di.login -ne 'ok') { Bad ('Could not read the recorder (' + $di.login + ').'); return [pscustomobject]@{ check = 'firmware'; ip = $Ip; vendor = $t.vendor; ok = $false; devices = @(); problems = @('recorder unreadable'); log = $script:LogFile } }
      $items += Judge-Firmware 'Recorder' $di.model $di.firmware $ref
      if ($IncludeCameras) {
        foreach ($ct in (Get-CameraTargets $t $CameraIps $CameraCredential)) {
          $cd = Hik-DeviceInfo $ct
          if ($cd.login -eq 'ok') { $items += Judge-Firmware ('Camera ' + $ct.ip) $cd.model $cd.firmware $ref -Quiet } else { Warn ('Camera ' + $ct.ip + ': could not read it (' + $cd.login + ').'); $fwUnread++ }
        }
        Write-FwUnlisted $items
      }
    }
    'DW' {
      $info = Dw-Info $t
      if (-not $info) { Bad 'Could not read the DW server version.'; return [pscustomobject]@{ check = 'firmware'; ip = $Ip; vendor = 'DW'; ok = $false; devices = @(); problems = @('server unreadable'); log = $script:LogFile } }
      $items += Judge-Firmware 'Server' 'DW Spectrum' $info.version $ref
      Info 'A DW server is updated with Digital Watchdog''s own installer - report only, the Toolkit never updates it.'
      if ($IncludeCameras -and (Dw-Login $t)) {
        $noFw = 0
        foreach ($d in (Dw-Devices $t)) { if ($d.firmware) { $items += Judge-Firmware ('Camera ' + $d.ip) $d.model $d.firmware $ref -Quiet } else { $noFw++; Log ('FW Camera ' + $d.ip + ' ' + $d.model + ': DW does not report its firmware.') } }
        Write-FwUnlisted $items $noFw
        $fwUnread += $noFw   # 2.2.7 (Codex file-by-file F11): a camera whose firmware is unknown is NOT checked (2.2.6 left it out of the count)
      } elseif ($IncludeCameras) {
        # 2.2.7 (F11): camera checks were asked for and could not run (the DW login failed): counted, never "firmware OK"
        Warn 'Camera firmware NOT CHECKED: the DW login did not work.'; $fwUnread++
      }
    }
    default {
      $blk = Login-Blocked $t
      if ($blk) { Warn ('Firmware NOT CHECKED (' + (Login-Words $blk) + ').'); return [pscustomobject]@{ check = 'firmware'; ip = $Ip; vendor = $t.vendor; ok = $false; notChecked = $true; devices = @(); problems = @('not checked (login ' + $blk + ')'); log = $script:LogFile } }
      $di = $(if ($t.vendor -eq 'Uniview') { Unv-DeviceInfo $t } else { $null })
      if ($di -and $di.login -eq 'ok') { $items += Judge-Firmware 'Recorder' $di.model $di.firmware $ref }
      else {
        $r = Onvif-Call $t '/onvif/device_service' '<x:GetDeviceInformation/>' $script:NsDev
        $x = Xml $r.body
        if ($x) { $items += Judge-Firmware 'Recorder' (XText $x 'Model') (XText $x 'FirmwareVersion') $ref } else { Bad 'Could not read the recorder''s model / firmware.'; $fwUnread++ }
      }
      if ($IncludeCameras) {
        foreach ($ct in (Get-CameraTargets $t $CameraIps $CameraCredential)) {
          if ($ct.vendor -eq 'Auto') { $ct.vendor = Detect-Vendor $ct.ip 0 }
          $cd = $(if ($ct.vendor -eq 'Hikvision') { Hik-DeviceInfo $ct } elseif ($ct.vendor -eq 'Uniview') { Unv-DeviceInfo $ct } else { $null })
          if ($cd -and $cd.login -eq 'ok') { $items += Judge-Firmware ('Camera ' + $ct.ip) $cd.model $cd.firmware $ref -Quiet } else { Warn ('Camera ' + $ct.ip + ': could not read it.'); $fwUnread++ }
        }
        Write-FwUnlisted $items
      }
    }
  }
  $sec = @($items | Where-Object { $_.verdict -eq 'security' }); $old = @($items | Where-Object { $_.verdict -eq 'old' })
  # 2.2.3 (Codex #22): a device whose firmware could not be judged (model not in the list, no reference data, not readable) is NOT "OK"
  $unk = @($items | Where-Object { $_.verdict -eq 'unknown' }); $notJudged = $unk.Count + [int]$fwUnread; if (-not $items.Count -and -not $notJudged) { $notJudged = 1 }
  $res = Get-FwResultLine $sec.Count $old.Count $notJudged
  Say $res.text $res.color
  return [pscustomobject]@{ check = 'firmware'; ip = $Ip; vendor = $t.vendor; ok = $res.ok; not_judged = $notJudged; devices = $items; problems = @($sec | ForEach-Object { $_.label + ': ' + (($_.advisories | ForEach-Object { $_.id }) -join ',') }); log = $script:LogFile }
}

# ================= all three (read-only) =================
function Get-NvrHealth {
  <#
  .SYNOPSIS Read-only: recording + clock + firmware in one run (one password prompt).
  .EXAMPLE Get-NvrHealth -Ip 192.168.1.20 -TargetDays 45 -Json C:\WireIt\Toolkit\logs\health.json
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Ip, [ValidateSet('Auto', 'Hikvision', 'Uniview', 'DW', 'Onvif')][string]$Vendor = 'Auto',
        [pscredential]$Credential, [int]$TargetDays = 0, [int]$Port = 0, [switch]$IncludeCameras, [string[]]$FindIps, [string]$Json = '')
  Start-Log 'health'
  $t = Resolve-Target $Ip $Vendor $Credential $Port
  $rec = Get-RecordingStatus -Ip $Ip -Vendor $t.vendor -Credential $t.cred -TargetDays $TargetDays -Port $Port -NoLog
  $clk = Get-ClockStatus -Ip $Ip -Vendor $t.vendor -Credential $t.cred -Port $Port -IncludeCameras:$IncludeCameras -FindIps $FindIps -NoLog
  $fw = Get-FirmwareStatus -Ip $Ip -Vendor $t.vendor -Credential $t.cred -Port $Port -IncludeCameras:$IncludeCameras -NoLog
  $out = [pscustomobject]@{ taken = (Get-Date).ToString('s'); ip = $Ip; vendor = $t.vendor; recording = $rec; clock = $clk; firmware = $fw; ok = ($rec.ok -and $clk.ok -and $fw.ok); log = $script:LogFile }
  # 2.2.15 (R9): a recorder still filling toward its target (no problem found) is STILL FILLING - not OK, not a problem
  $wd = { param($x) if ($x.ok) { 'OK' } elseif ($x.PSObject.Properties['target_pending'] -and $x.target_pending -and -not @($x.problems).Count) { 'STILL FILLING' } elseif (@($x.problems).Count -and -not @(@($x.problems) | Where-Object { $_ -notmatch 'login refused|login skipped|not checked|no answer|unreadable' }).Count) { 'NOT CHECKED' } else { 'PROBLEM' } }
  $ws = @((& $wd $rec), (& $wd $clk), (& $wd $fw))
  Say ''; Say ('SUMMARY: recording ' + $ws[0] + ' | time ' + $ws[1] + ' | firmware ' + $ws[2]) $(if ($out.ok) { 'Green' } elseif ($ws -contains 'PROBLEM') { 'Red' } else { 'Yellow' })
  if ($Json) { ($out | ConvertTo-Json -Depth 8) | Set-Content -Path $Json -Encoding UTF8 -WhatIf:$false -Confirm:$false }
  return $out
}

# ================= Camera doctor (Nov 3 2026) =================
# ONE camera, read-only except ONE login try with the password the tech typed (never stored, never retried).
# Steps: ping / ARP-MAC / ports (from the caller, -Reach) -> web page within 5 s -> one login -> RTSP DESCRIBE -> DW's view of it.
# Uniview lock answer shape is UNVERIFIED on real gear (mock only): any 401/403 whose body says "lock" counts as LOCKED.
function Rtsp-Describe([string]$Ip, [int]$Port = 554, [int]$ms = 4000) {
  $c = New-Object Net.Sockets.TcpClient
  try {
    $a = $c.BeginConnect($Ip, $Port, $null, $null); if (-not ($a.AsyncWaitHandle.WaitOne(1500) -and $c.Connected)) { return 'closed' }
    $s = $c.GetStream(); $s.ReadTimeout = $ms
    $q = [Text.Encoding]::ASCII.GetBytes('DESCRIBE rtsp://' + $Ip + ':' + $Port + '/ RTSP/1.0' + "`r`nCSeq: 1`r`nUser-Agent: WireIt-Doctor`r`n`r`n"); $s.Write($q, 0, $q.Length)
    $buf = New-Object byte[] 512; $n = $s.Read($buf, 0, 512)
    $line = ([Text.Encoding]::ASCII.GetString($buf, 0, $n) -split "`r?`n")[0]
    if ($line -match '^RTSP/1\.\d\s+(\d{3})') { return ('answers ' + $Matches[1]) }; return 'garbled'
  } catch { return 'hung' } finally { $c.Close() }
}
function Invoke-CameraDoctor {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Ip, [pscredential]$Credential, $Reach = $null, [string]$Maker = '', [string]$DwIp = '', [pscredential]$DwCredential, [int]$DwPort = 0, [int]$Port = 0)
  Start-Log 'doctor'
  $res = [ordered]@{ check = 'doctor'; ip = $Ip; maker = $Maker; ping = $null; mac = ''; open = @(); web = ''; login = ''; lockMin = $null; rtsp = ''; dw = ''; verdict = ''; fixes = @(); steps = @() }
  $step = { param($n, $t, $k) $res.steps += [pscustomobject]@{ n = $n; t = $t; k = $k }; switch ($k) { 'ok' { Ok $t } 'bad' { Bad $t } 'warn' { Warn $t } default { Info $t } } }
  Say ''; Say ('----- Camera doctor: ' + $Ip + ' -----') 'Cyan'
  # 1-3 network (measured by the caller: ping, ARP table, TCP ports)
  if ($Reach) {
    $res.ping = [bool]$Reach.ping; $res.mac = [string]$Reach.mac; $res.open = @($Reach.open)
    & $step 1 $(if ($Reach.ping) { 'Ping: answers.' } else { 'Ping: no answer.' }) $(if ($Reach.ping) { 'ok' } else { 'warn' })
    & $step 2 $(if ($Reach.mac) { 'MAC ' + $Reach.mac + $(if ($Reach.macMatch -eq $false) { ' - NOT the MAC on the saved list (another device has this IP?)' } elseif ($Reach.macMatch) { ' - matches the saved list.' } else { '.' }) } elseif ($Reach.movedTo) { 'Its MAC now answers at ' + $Reach.movedTo + ' (IP moved).' } else { 'Not in the ARP table (nothing at this IP on this network right now).' }) $(if ($Reach.macMatch -eq $false -or $Reach.movedTo) { 'bad' } elseif ($Reach.mac) { 'ok' } else { 'warn' })
    & $step 3 $(if (@($Reach.open).Count) { 'Ports open: ' + (@($Reach.open) -join ', ') + '.' } else { 'No port answers (80 / 443 / 554 / 8000).' }) $(if (@($Reach.open).Count) { 'ok' } else { 'bad' })
  }
  $dead = $Reach -and -not $Reach.ping -and -not $Reach.mac -and -not @($Reach.open).Count
  # 4 web page within 5 s
  if (-not $dead) {
    $w = Http -Ip $Ip -Path '/' -Port $Port -Timeout 5
    if ($w.code -gt 0) { $res.web = 'answers'; & $step 4 ('Web page: answers (' + $w.code + ').') 'ok' }
    else { $res.web = 'hung'; & $step 4 'Web page: connection opens but no page within 5 s - the web service is HUNG.' 'bad' }
  }
  # 5 ONE login try (Uniview LAPI or Hikvision ISAPI), never repeated
  if (-not $dead -and $res.web -ne 'hung' -and $Credential) {
    $u = $null; if ($Maker -notmatch '(?i)hik') { $u = Http -Ip $Ip -Path '/LAPI/V1.0/System/DeviceInfo' -Port $Port -Timeout 5 }   # no password: tells the maker, and a Uniview says "locked" here without any login try
    if (-not $Maker) { if ($u -and $u.code -in @(200, 401, 403)) { $Maker = 'Uniview' } else { $Maker = 'Hikvision' } }
    $res.maker = $Maker
    $path = $(if ($Maker -match '(?i)uniview|unv') { '/LAPI/V1.0/System/DeviceInfo' } else { '/ISAPI/System/deviceInfo' })
    if ($u -and $u.code -in @(401, 403) -and ($u.body -match '(?i)lock')) { $r = $u }   # already locked: no login try at all
    else { $r = Http -Ip $Ip -Path $path -Credential $Credential -Port $Port -Timeout 8 }
    if ($r.code -eq 200) { $res.login = 'ok'; & $step 5 ('Login with the typed password: OK (' + $Maker + ').') 'ok' }
    elseif ($r.code -in @(401, 403) -and ($r.body -match '(?i)lock')) {
      $res.login = 'locked'; $m = [regex]::Match($r.body, '(?i)"?(RemainLockTime|unlockTime|LockTime)"?\s*[:=>]\s*"?(\d+)'); if ($m.Success) { $res.lockMin = [math]::Ceiling([int]$m.Groups[2].Value / 60) }
      & $step 5 ('Login: the camera is LOCKED (too many wrong passwords)' + $(if ($res.lockMin) { ' - unlocks in about ' + $res.lockMin + ' min' } else { '' }) + '. No more tries from here.') 'bad'
    }
    elseif ($r.code -in @(401, 403)) { $res.login = 'wrong'; & $step 5 'Login: WRONG password (the typed site password is not this camera''s).' 'bad' }
    elseif ($r.code -eq 0) { $res.login = 'hung'; & $step 5 'Login: no answer - hung.' 'bad' }
    else { $res.login = 'other'; & $step 5 ('Login: unexpected answer ' + $r.code + '.') 'warn' }
  } elseif (-not $Credential -and -not $dead) { & $step 5 'Login: skipped (no password typed).' 'plain' }
  # 6 RTSP
  if (-not $dead) {
    $res.rtsp = $(if ($Reach -and $Reach.rtsp) { [string]$Reach.rtsp } else { Rtsp-Describe $Ip })
    & $step 6 ('Video (RTSP 554): ' + $(switch -regex ($res.rtsp) { '^answers' { 'answers.' } '^hung' { 'connects but never answers - HUNG.' } '^closed' { 'port closed.' } default { $res.rtsp } })) $(if ($res.rtsp -like 'answers*') { 'ok' } else { 'bad' })
  }
  # 7 DW's view
  $dwBad = $false
  if ($DwIp -and $DwCredential) {
    $t = @{ ip = $DwIp; vendor = 'DW'; cred = $DwCredential; port = $DwPort; token = $null }
    if (Dw-Login $t) {
      $d = @(Dw-Devices $t | Where-Object { $_.ip -eq $Ip }) | Select-Object -First 1
      if ($d) { $res.dw = $d.status; $dwBad = ($d.status -eq 'Unauthorized'); & $step 7 ('DW says: ' + $d.status + $(if ($dwBad) { ' - DW keeps logging in with a WRONG password. On a Uniview that keeps it locked.' } else { '' })) $(if ($dwBad) { 'bad' } elseif ($d.status -in @('Recording', 'Online')) { 'ok' } else { 'warn' }) }
      else { & $step 7 'DW: this IP is not in DW''s camera list.' 'warn' }
    } else { & $step 7 'DW: login refused - not checked.' 'warn' }
  }
  # verdict + fix (Release C buttons; nothing is changed here)
  $fx = New-Object System.Collections.Generic.List[string]
  if ($dead) { $v = 'DEAD or no power/link: check the cable and the switch port / PoE. If PoE is on and still nothing: replace the camera.'; $fx.Add('poe'); $fx.Add('replace') }
  elseif ($res.login -eq 'locked') { $v = 'LOCKED' + $(if ($dwBad) { ': DW keeps retrying the old password, so it stays locked. Pause the camera in DW (or fix its password there), wait ' + $(if ($res.lockMin) { $res.lockMin } else { '30' }) + ' min, then fix the password in DW.' } else { ': wait ' + $(if ($res.lockMin) { $res.lockMin } else { '30' }) + ' min and try once more with the right password.' }); if ($dwBad) { $fx.Add('dwpassword') } }
  elseif ($res.login -eq 'wrong' -and $dwBad) { $v = 'WRONG PASSWORD IN DW: the camera answers but DW has the wrong password.'; $fx.Add('dwpassword') }
  elseif ($res.login -eq 'wrong') { $v = 'The typed password is not this camera''s. Check the site password (one try per run, so nothing gets locked).' }
  elseif ($res.web -eq 'hung' -or $res.login -eq 'hung' -or $res.rtsp -like 'hung*') { $v = 'HUNG: it is on the network but its services stopped answering. Restart its PoE port (or power)' + $(if ($res.login -eq 'ok') { ', or reboot it' } else { '' }) + '.'; $fx.Add('poe'); if ($res.login -eq 'ok' -and $Maker -match '(?i)uniview') { $fx.Add('reboot') } }
  elseif ($dwBad) { $v = 'WRONG PASSWORD IN DW: the camera works with the site password; DW has an old one.'; $fx.Add('dwpassword') }
  elseif ($res.login -eq 'ok') { $v = 'The camera itself is fine. If DW still shows it offline, look at DW (address, stream settings).' }
  else { $v = 'Not sure - see the steps above.' }
  $res.verdict = $v; $res.fixes = @($fx | Select-Object -Unique)
  Say ''; Say ('VERDICT: ' + $v) $(if ($fx.Count) { 'Red' } else { 'Green' })
  if ($fx.Count) { Say ('Fix buttons for this (each asks first; nothing was changed): ' + ($res.fixes -join ', ')) 'Yellow' }
  return [pscustomobject]$res
}

$nvrFixFile = Join-Path $PSScriptRoot 'NvrFix.ps1'   # Release C (1.6.0) fix buttons; absent in 1.5.0
if (Test-Path $nvrFixFile) { . $nvrFixFile; Export-ModuleMember -Function Invoke-NvrFix }
Export-ModuleMember -Function Close-NvrSessions, Invoke-CameraDoctor, Get-RecordingStatus, Get-ClockStatus, Set-NtpTime, Get-FirmwareStatus, Get-NvrHealth, Set-NvrHealthOption, Get-NvrHealthOption, Get-NvrHealthSummary, Read-NvrCredential
