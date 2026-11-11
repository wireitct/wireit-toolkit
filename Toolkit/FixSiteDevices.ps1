<#
 FixSiteDevices.ps1 - WireIt Toolkit 2.0 "Fix this site": talking to cameras, NVRs, this PC and the site's secret store.
 Official interfaces only: Hikvision ISAPI, Dahua HTTP API (CGI), Hikvision SADP / Dahua search (read-only discovery).
 No exploits, no password guessing: a login is tried only with the site's own saved passwords (a short, fixed list).
 Passwords are never written to a log or a file in plain text. Dot-sourced by FixSite.ps1 (and the tests).
 Test harness: $script:FsMockUrl = 'http://127.0.0.1:<port>' sends every device call to the mock server (tests\fixsite\mock_site.py).
#>
$script:FsMockUrl = ''
$script:FsIsPs5 = $PSVersionTable.PSVersion.Major -lt 6
$script:FsTestSecrets = $false
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
  // 2.2.3 (Codex #7): a device's own certificate is accepted once, then PINNED for this run: another certificate on the same
  // address (an impersonating box on the LAN) is refused. Only in this FixSiteDevices copy (Fix this site sends passwords).
  public static readonly System.Collections.Generic.Dictionary<string, string> Pins = new System.Collections.Generic.Dictionary<string, string>();
  public static bool Check(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
    if (errors == SslPolicyErrors.None) return true;
    string host = null;
    HttpWebRequest r = sender as HttpWebRequest; if (r != null) { host = r.RequestUri.Host; } else { string s = sender as string; if (s != null) host = s; }
    if (!IsLanHost(host) || cert == null) return false;
    string tp = cert.GetCertHashString(); string seen;
    lock (Pins) { if (Pins.TryGetValue(host, out seen)) return seen == tp; Pins[host] = tp; }
    return true;
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
if ($script:FsIsPs5) {
  # 2.2.2 (re-review H1): TLS 1.2 first, but also 1.1/1.0 - older camera firmware speaks only those, and it must stay HTTPS (2.2.1 sent it plain HTTP)
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls; [Net.ServicePointManager]::Expect100Continue = $false } catch {}
  [void](Enable-WireItLanTls)   # devices answer HTTPS with their own (self-made) certificate
}
function Fs-LogLine([string]$s) { if (Get-Command Fs-Log -ErrorAction SilentlyContinue) { Fs-Log $s } }

# 2.2.7 (Codex file-by-file F03): a file that must never be half-written (the undo file, Undo's progress file) is written to a
# temporary file beside it first and only then put in its place in one step. A write that fails half-way leaves the old file whole.
function Write-FsFileAtomic([string]$path, [string]$text) {
  $tmp = $path + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp'
  try {
    [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding($true)))
    if ([IO.File]::Exists($path)) { [IO.File]::Replace($tmp, $path, [NullString]::Value) } else { [IO.File]::Move($tmp, $path) }
  } finally { if ([IO.File]::Exists($tmp)) { try { [IO.File]::Delete($tmp) } catch {} } }
  # 2.2.20 (Codex 2.2.19 class A): "saved" only when the file in its place reads back exactly as written
  $back = $null; try { $back = [IO.File]::ReadAllText($path) } catch { throw ('the file was written but cannot be read back (' + $_.Exception.Message + ')') }
  if ($back.TrimStart([char]0xFEFF) -cne $text.TrimStart([char]0xFEFF)) { throw 'the file does not read back as it was written' }
}
# 2.2.20 (Codex 2.2.19 R01): an authoritative record (this PC's network journal, its recovery marker) is installed in ONE checked step
# and READ BACK before the change it protects. Every failure THROWS (2.2.19's Move-Item had no -ErrorAction Stop: under the caller's
# Continue a refused move was only a warning, the catch never ran, and the adapter was changed with no journal on disk). Saved =
# the final file exists, reads back byte-for-byte as written and parses as JSON. <path>.tmp is the same fixed name every time: one
# left behind after a stop is EVIDENCE of a change in progress (Resolve-FsNetOrphanTmp), so it is never deleted here.
function Save-FsRecordVerified([string]$path, [string]$text) {
  if (-not $path) { throw 'no record file name' }
  $dir = Split-Path -Parent $path
  if ($dir) { New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null }
  $tmp = $path + '.tmp'
  try {
    [IO.File]::WriteAllText($tmp, $text)
    Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
  } catch { throw ('the record could not be put in place: ' + $_.Exception.Message) }
  $back = $null
  try { $back = [IO.File]::ReadAllText($path) } catch { throw ('the record cannot be read back: ' + $_.Exception.Message) }
  if ($back -cne $text) { throw 'the record does not read back as it was saved' }
  try { [void](ConvertFrom-Json -InputObject $back -ErrorAction Stop) } catch { throw 'the record does not read back as valid JSON' }
}
# ---------------- HTTP (digest/basic handled by .NET; passwords never logged) ----------------
function Fs-Cred([string]$pw, [string]$user = 'admin') { if (-not $pw) { return $null }; return New-Object PSCredential($user, (ConvertTo-SecureString $pw -AsPlainText -Force)) }
function Fs-Plain($cred) { if (-not $cred) { return '' }; return $cred.GetNetworkCredential().Password }
function Fs-Xml([string]$s) { return [Security.SecurityElement]::Escape([string]$s) }
# 2.2.3 (Codex #7): over plain HTTP a password is only ever answered to a Digest challenge (the password itself never crosses the
# wire). A device - or a box pretending to be one - that asks only for Basic gets no password over plain HTTP.
$script:FsAuthScheme = @{}
function Test-FsDigestOffered([string[]]$challenges) { return [bool](@($challenges | Where-Object { [string]$_ -match '(?i)^\s*digest\b' }).Count) }
function Get-FsHttpChallenge([string]$ip, [string]$path) {
  if ($script:FsAuthScheme.ContainsKey($ip)) { return $script:FsAuthScheme[$ip] }
  $ch = @()
  try { [void](Invoke-WebRequest -Uri ('http://' + $ip + $path) -UseBasicParsing -TimeoutSec 6 -ErrorAction Stop); $ch = @('none') }
  catch { try { $h = $_.Exception.Response.Headers; $v = $null; try { $v = $h['WWW-Authenticate'] } catch {}; if (-not $v) { try { $v = @($h.WwwAuthenticate | ForEach-Object { $_.ToString() }) } catch {} }; $ch = @($v | ForEach-Object { [string]$_ -split '(?i),\s*(?=(basic|digest)\b)' } | Where-Object { $_ -match '(?i)^\s*(basic|digest)\b' }) } catch {} }
  $script:FsAuthScheme[$ip] = $ch; return $ch
}
function Fs-Http {
  param([string]$Ip, [string]$Path, [string]$Method = 'GET', [string]$Body = '', [string]$ContentType = 'application/xml', $Cred = $null, [int]$Timeout = 8, [string]$OutFile = '', [switch]$Secret, [switch]$Tls)
  if ($Cred -and -not $Tls -and -not $script:FsMockUrl) {
    $chs = @(Get-FsHttpChallenge $Ip $Path)
    if ($chs.Count -and $chs[0] -ne 'none' -and -not (Test-FsDigestOffered $chs)) { Fs-LogLine ($Method + ' ' + $Ip + ' refused: plain HTTP with Basic login only (the password is not sent)'); return [pscustomobject]@{ code = 0; body = ''; err = 'basic-over-http' } }
  }
  $base = $(if ($script:FsMockUrl) { $script:FsMockUrl.TrimEnd('/') + $(if ($Tls) { '/tls/' } else { '/dev/' }) + $Ip } elseif ($Tls) { 'https://' + $Ip } else { 'http://' + $Ip })
  $a = @{ Uri = ($base + $Path); Method = $Method; UseBasicParsing = $true; TimeoutSec = $Timeout; ErrorAction = 'Stop' }
  if ($Tls -and -not $script:FsIsPs5 -and -not $script:FsMockUrl -and (Test-WireItLanHost $Ip)) { $a.SkipCertificateCheck = $true }   # this one device call only (PS 5.1: Enable-WireItLanTls)
  if ($Cred) { $a.Credential = $Cred; if (-not $script:FsIsPs5) { $a.AllowUnencryptedAuthentication = $true } }
  if ($Body) { $a.Body = [Text.Encoding]::UTF8.GetBytes($Body); $a.ContentType = $ContentType }
  if ($OutFile) { $a.OutFile = $OutFile }
  $shown = $(if ($Secret) { ($Path -replace '\?.*$', '?(hidden)') } else { $Path })
  Fs-LogLine ($Method + ' ' + $(if ($Tls) { 'https ' } else { '' }) + $Ip + $shown + $(if ($Body -and -not $Secret) { ' BODY ' + $(if ($Body.Length -gt 300) { $Body.Substring(0, 300) + '...' } else { $Body }) } elseif ($Body) { ' BODY (hidden)' } else { '' }))
  try {
    $r = Invoke-WebRequest @a
    $c = ''; if (-not $OutFile) { $c = [string]$r.Content; if ($r.Content -is [byte[]]) { $c = [Text.Encoding]::UTF8.GetString($r.Content) } }
    $code = 200; if ($r -and $r.StatusCode) { $code = [int]$r.StatusCode }
    Fs-LogLine ('  -> ' + $code + $(if ($c -and -not $Secret) { ' ' + $(if ($c.Length -gt 200) { $c.Substring(0, 200) + '...' } else { $c }) } else { '' }))
    return [pscustomobject]@{ code = $code; body = $c }
  } catch {
    $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
    $eb = ''; try { if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $eb = [string]$_.ErrorDetails.Message } } catch {}
    $err = $(if ($code -eq 0) { Get-FsNetErrorKind $_.Exception } else { '' })
    # 2.2.5: Windows PowerShell 5.1 reports a TLS handshake with a box that is not speaking TLS as a plain "connection closed" (WebException
    # SendFailure/ReceiveFailure, inner IOException), not as a TLS error, so it came out as 'other'. When the port itself answers a TCP
    # connect, the HTTPS failure was the handshake or the certificate: 'tls' (the password is still not sent in clear either way).
    if ($Tls -and $err -eq 'other' -and -not $script:FsMockUrl -and (Test-FsTcpAnswers $Ip) -eq 'yes') { $err = 'tls' }
    # test harness: the mock answers 599 "MOCKNET:<kind>" for what a real device does on the wire (port closed, no answer, bad TLS)
    if ($script:FsMockUrl -and $code -eq 599 -and $eb -match '^MOCKNET:(\w+)') { $code = 0; $err = $Matches[1]; $eb = '' }
    Fs-LogLine ('  -> ' + $code + ' ' + $_.Exception.Message + $(if ($err) { ' [' + $err + ']' } else { '' }))
    return [pscustomobject]@{ code = $code; body = $eb; err = $err }
  }
}
# 2.2.5: does anything accept a TCP connection on the HTTPS port? 'yes' | 'refused' | 'no' (timeout / no route / error)
function Test-FsTcpAnswers([string]$ip, [int]$ms = 4000) {   # 4 s: Windows retries a refused connect for ~2 s before it says so (Office PC, Nov 8 2026)
  $h = $ip; $port = 443; if ($ip -match '^(.+):(\d+)$') { $h = $Matches[1]; $port = [int]$Matches[2] }
  $c = New-Object Net.Sockets.TcpClient
  try {
    $ar = $c.BeginConnect($h, $port, $null, $null)
    if (-not $ar.AsyncWaitHandle.WaitOne($ms)) { return 'no' }
    $c.EndConnect($ar); return 'yes'
  } catch {
    $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
    if ($e -is [Net.Sockets.SocketException] -and ([string]$e.SocketErrorCode -eq 'ConnectionRefused' -or [int]$e.NativeErrorCode -in @(10061, 111))) { return 'refused' }
    return 'no'
  } finally { try { $c.Close() } catch {} }
}
# 2.2.2 (review H1): WHY a call got no HTTP answer. 'refused' = nothing listens on that port (the device has no HTTPS);
# 'timeout' = no answer in time; 'tls' = the TLS handshake or the certificate failed; 'unreachable' = no route; 'other'.
# Works for Windows PowerShell 5.1 (WebException + SocketException 10061) and PowerShell 7 (HttpRequestException + SocketException).
function Get-FsNetErrorKind($ex) {
  $kind = ''
  for ($e = $ex; $e; $e = $e.InnerException) {
    if ($e -is [Net.Sockets.SocketException]) {
      $sc = [string]$e.SocketErrorCode
      if ($sc -eq 'ConnectionRefused' -or [int]$e.NativeErrorCode -eq 10061) { return 'refused' }
      if ($sc -eq 'TimedOut') { $kind = 'timeout' } elseif ($sc -in @('HostUnreachable', 'NetworkUnreachable', 'HostNotFound', 'HostDown')) { if (-not $kind) { $kind = 'unreachable' } }
    }
    elseif ($e -is [Net.WebException]) {
      $st = [string]$e.Status
      if ($st -eq 'Timeout') { $kind = 'timeout' } elseif ($st -in @('TrustFailure', 'SecureChannelFailure')) { if (-not $kind) { $kind = 'tls' } }
    }
    elseif ($e -is [Security.Authentication.AuthenticationException]) { if (-not $kind) { $kind = 'tls' } }
    elseif ($e -is [IO.IOException] -and [string]$e.Message -match '(?i)(SSL|TLS|handshake|transport stream)') { if (-not $kind) { $kind = 'tls' } }   # 2.2.5: Windows PowerShell 5.1's words for a failed handshake
    elseif ($e -is [TimeoutException] -or $e -is [OperationCanceledException]) { $kind = 'timeout' }
  }
  if ($kind) { return $kind }
  return 'other'
}
# 2.2.1 (review H1): a call that carries a password (a new password, the NVR's copy of a camera password) goes over HTTPS first.
# Plain HTTP only when the device has no HTTPS at all (nothing answers on 443), and then with a warning the tech sees.
# A device that answered HTTPS once is never asked over plain HTTP again in this run.
# 2.2.2 (re-review H1): "no HTTPS" now means exactly that: the connection to 443 was REFUSED, or the model is on the known no-HTTPS
# list ($script:FsNoTlsModels, regexes; config.json "noHttpsModels" adds to it). A timeout, a TLS handshake failure or a certificate
# problem is NOT a reason to send the password in clear: the password is not sent, and the run says so in red.
$script:FsTlsState = @{}                                     # ip -> 'yes' | 'no'
$script:FsPlainSecret = New-Object System.Collections.ArrayList   # devices that got a password over plain HTTP in this run
$script:FsTlsFailed = @{}                                    # ip -> why HTTPS failed (timeout / tls / other): password NOT sent
$script:FsNoPlainSecrets = $false                            # $true = never fall back (refuse instead)
$script:FsNoTlsModels = @()                                  # model regexes known to have no HTTPS at all (none confirmed yet)
$script:FsModels = @{}                                       # ip -> model, filled from the scan
function Test-FsNoTlsModel([string]$ip) {
  $m = [string]$script:FsModels[$ip]; if (-not $m) { return $false }
  foreach ($rx in @($script:FsNoTlsModels)) { if ($rx -and $m -match $rx) { return $true } }
  return $false
}
function Fs-HttpSecret {
  param([string]$Ip, [string]$Path, [string]$Method = 'GET', [string]$Body = '', [string]$ContentType = 'application/xml', $Cred = $null, [int]$Timeout = 8)
  $st = [string]$script:FsTlsState[$Ip]
  if ($st -ne 'no' -and (Test-FsNoTlsModel $Ip)) { $st = 'no'; $script:FsTlsState[$Ip] = 'no'; Fs-LogLine ('  ' + $Ip + ': model ' + $script:FsModels[$Ip] + ' is on the no-HTTPS list') }
  if ($st -ne 'no') {
    $r = Fs-Http -Ip $Ip -Path $Path -Method $Method -Body $Body -ContentType $ContentType -Cred $Cred -Timeout $Timeout -Secret -Tls
    if ($r.code -ne 0) { $script:FsTlsState[$Ip] = 'yes'; return $r }
    if ($st -eq 'yes') { return $r }   # it has HTTPS: a failed answer is a failure, never a reason to send the password in clear
    $why = [string]$r.err
    if ($why -ne 'refused') {
      # 2.2.2 (re-review H1): HTTPS is there (or may be) but did not work: fail loudly, never plain HTTP
      $script:FsTlsFailed[$Ip] = $(if ($why) { $why } else { 'other' })
      Fs-LogLine ('  ERROR ' + $Ip + ': HTTPS did not work (' + $script:FsTlsFailed[$Ip] + ') - the password was NOT sent (plain HTTP is only used when the device has no HTTPS at all)')
      return [pscustomobject]@{ code = 0; body = ''; err = $why; tlsFailed = $true }
    }
    $script:FsTlsState[$Ip] = 'no'
  }
  if ($script:FsNoPlainSecrets) { Fs-LogLine ('  ' + $Ip + ': no HTTPS - password NOT sent (plain HTTP is switched off)'); return [pscustomobject]@{ code = 0; body = '' } }
  if (-not $script:FsPlainSecret.Contains($Ip)) { [void]$script:FsPlainSecret.Add($Ip) }
  Fs-LogLine ('  WARNING ' + $Ip + ': this device has no HTTPS - the password goes over plain HTTP on the site network')
  return (Fs-Http -Ip $Ip -Path $Path -Method $Method -Body $Body -ContentType $ContentType -Cred $Cred -Timeout $Timeout -Secret)
}
function Test-FsSentPlain([string]$ip) { return $script:FsPlainSecret.Contains($ip) }
function Get-FsTlsFailure([string]$ip) { return [string]$script:FsTlsFailed[$ip] }
function Fs-XmlDoc([string]$s) { if (-not $s) { return $null }; try { [xml]$x = $s; return $x } catch { return $null } }
function Fs-XFind($node, [string]$name) { if (-not $node) { return @() }; return @($node.SelectNodes(".//*[local-name()='" + $name + "']")) }
function Fs-XText($node, [string]$name) { $n = @(Fs-XFind $node $name); if ($n.Count -and $n[0]) { return ([string]$n[0].InnerText).Trim() }; return '' }
function Fs-XSet($node, [string]$name, [string]$v) { $n = @(Fs-XFind $node $name); if ($n.Count -and $n[0]) { $n[0].InnerText = $v; return $true }; return $false }
# 2.2.20 (Codex 2.2.19 class C sweep): an HTTP 200 is an accepted write only when it is not a login / HTML page or other non-XML
# document; an XML answer must not carry an error status. (An empty 200 body stays accepted: every write's outcome is read back.)
function Fs-HikOk($r) {
  if (-not $r -or $r.code -ne 200) { return $false }
  $b = [string]$r.body; if (-not $b.Trim()) { return $true }
  if (Test-FsHtmlText $b) { return $false }
  $x = Fs-XmlDoc $b; if (-not $x -or -not $x.DocumentElement) { return $false }
  if ($x.DocumentElement.LocalName -ne 'ResponseStatus') { return $true }
  $sc = Fs-XText $x 'statusCode'; return (-not $sc -or $sc -eq '1' -or $sc -eq '7')
}
function Fs-HikNeedsReboot($r) { $x = Fs-XmlDoc $r.body; return ((Fs-XText $x 'statusCode') -eq '7') }
function Fs-DhLines([string]$body) {
  # Dahua answers "table.Network.eth0.IPAddress=192.168.1.83" lines -> hashtable without the "table." prefix
  $h = @{}; foreach ($l in ($body -split "`r?`n")) { $m = [regex]::Match($l, '^(?:table\.)?([^=]+)=(.*)$'); if ($m.Success) { $h[$m.Groups[1].Value.Trim()] = $m.Groups[2].Value.Trim() } }; return $h
}
function Fs-DhSet([string]$ip, $cred, [hashtable]$kv) {
  $q = @(); foreach ($k in $kv.Keys) { $q += ([uri]::EscapeDataString([string]$k).Replace('%5B', '[').Replace('%5D', ']') + '=' + [uri]::EscapeDataString([string]$kv[$k])) }
  $r = Fs-Http -Ip $ip -Path ('/cgi-bin/configManager.cgi?action=setConfig&' + ($q -join '&')) -Cred $cred
  return ($r.code -eq 200 -and $r.body -match '(?i)^\s*OK')
}

# ---------------- login (one try per known password; stops at "locked") ----------------
# 2.2.3 (Codex #29): ONE wrong-password budget per device for the whole run (all steps, recovery and undo together), below the
# lockout of Hikvision/Dahua (5-6 wrong tries). Spent = the device is not tried again with a password this run ('locked').
$script:FsLoginFails = @{}; $script:FsMaxLoginFails = 4
# 2.2.10 (Codex R19): the count is ALSO kept on disk per device ($script:FsLoginLedger, set by Fix this site and HikReset to the same
# file), so a rerun does not start from zero: at most $FsMaxLoginFails wrong passwords per device until $FsLoginCooldownMin minutes
# have passed since its last wrong one (Hikvision/Dahua lock after 5-7 and unlock after about 30 min). Inside the cool-down no
# password at all is sent to that device. A password that works clears its count. Lockout numbers on real gear: NEEDS DEVICE CHECK.
$script:FsLoginLedger = ''; $script:FsLoginCooldownMin = 30
# 2.2.19 (Codex 2.2.18 F27): the count file is SAFETY state. 2.2.10-2.2.18 read a damaged file as "no wrong passwords yet" and
# carried on when it could not be saved, so a rerun could send a full set of wrong passwords inside a device's cool-down. Now:
# - a count file that is there but cannot be read, or holds an entry without a whole number of tries and a time = the count is
#   UNKNOWN: no password is sent to any device until the file is sorted out (Read-FsLoginLedger sets $script:FsLoginLedgerWhy)
# - every password try is WRITTEN DOWN (count + 1, now) and read back BEFORE it is sent; if that cannot be saved the password is
#   not sent to that device. A try that got no answer gives its count back; a refused one keeps it; one that works clears it.
# - a save that fails afterwards holds that device for the rest of this run ($script:FsLoginHold), the plain reason logged.
$script:FsLoginLedgerWhy = ''; $script:FsLoginHold = @{}; $script:FsLoginHoldSaid = @{}
function Test-FsLedgerTime([string]$s) {
  $t = [datetime]::MinValue
  return ([bool]$s -and [datetime]::TryParse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$t))
}
function Read-FsLoginLedger {
  # a table device -> { fails; last }. A missing file = nothing counted yet. A file that is there but unreadable or damaged:
  # $script:FsLoginLedgerWhy says why (the budget is then unknown) and the table holds only what could be read.
  $h = @{}; $script:FsLoginLedgerWhy = ''
  if (-not $script:FsLoginLedger) { return $h }
  $there = $false; try { $there = Test-Path -LiteralPath $script:FsLoginLedger -ErrorAction Stop } catch { $script:FsLoginLedgerWhy = 'the wrong-password count file could not be checked (' + $_.Exception.Message + ')'; return $h }
  if (-not $there) { return $h }
  $o = $null
  try { $raw = [IO.File]::ReadAllText($script:FsLoginLedger); $o = $raw | ConvertFrom-Json -ErrorAction Stop } catch { $script:FsLoginLedgerWhy = 'the wrong-password count file could not be read (' + $_.Exception.Message + ')'; return $h }
  if ($null -eq $o -or $o -is [array] -or $o -isnot [pscustomobject]) { $script:FsLoginLedgerWhy = 'the wrong-password count file is damaged (it does not hold a list of devices)'; return $h }
  foreach ($p in @($o.PSObject.Properties)) {
    $v = $p.Value; $n = 0
    if ($null -eq $v -or $v -isnot [pscustomobject] -or -not $v.PSObject.Properties['fails'] -or -not $v.PSObject.Properties['last'] -or -not [int]::TryParse([string]$v.fails, [ref]$n) -or $n -lt 0 -or -not (Test-FsLedgerTime ([string]$v.last))) {
      $script:FsLoginLedgerWhy = 'the wrong-password count file is damaged (the entry for ' + $p.Name + ' has no whole count and time)'; continue
    }
    $h[$p.Name] = [pscustomobject]@{ fails = $n; last = [string]$v.last }
  }
  return $h
}
# $true only when the file was written AND reads back with the same counts
function Save-FsLoginLedger($h) {
  if (-not $script:FsLoginLedger) { return $true }
  try {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:FsLoginLedger) -ErrorAction Stop | Out-Null
    $o = [ordered]@{}; foreach ($k in @($h.Keys | Sort-Object)) { $o[$k] = [ordered]@{ fails = [int]$h[$k].fails; last = [string]$h[$k].last } }
    $tmp = $script:FsLoginLedger + '.tmp'; [IO.File]::WriteAllText($tmp, (ConvertTo-Json -Depth 4 -InputObject $o)); Move-Item -LiteralPath $tmp -Destination $script:FsLoginLedger -Force -ErrorAction Stop
  } catch { Fs-LogLine ('wrong-password count not saved: ' + $_.Exception.Message); return $false }
  $back = Read-FsLoginLedger
  if ($script:FsLoginLedgerWhy) { Fs-LogLine ('wrong-password count saved but does not read back: ' + $script:FsLoginLedgerWhy); return $false }
  foreach ($k in @($h.Keys)) { if (-not $back.ContainsKey($k) -or [int]$back[$k].fails -ne [int]$h[$k].fails) { Fs-LogLine ('wrong-password count for ' + $k + ' does not read back as saved'); return $false } }
  if (@($back.Keys).Count -ne @($h.Keys).Count) { Fs-LogLine 'wrong-password count file does not read back as saved'; return $false }
  return $true
}
function Get-FsLoginBudget([string]$k) {
  # { fails; until; unknown } for this device: this run's count or the saved one inside its cool-down, whichever is higher.
  # unknown = why the count is not known (the file unreadable, or this device's count could not be saved this run): the device
  # counts as spent (fails = the limit) and no password is sent to it.
  $n = [int]$script:FsLoginFails[$k]; $until = $null
  $led = Read-FsLoginLedger
  if ($script:FsLoginLedgerWhy) { return [pscustomobject]@{ fails = [int]$script:FsMaxLoginFails; until = $null; unknown = [string]$script:FsLoginLedgerWhy } }
  if ($script:FsLoginHold.ContainsKey($k)) { return [pscustomobject]@{ fails = [int]$script:FsMaxLoginFails; until = $null; unknown = [string]$script:FsLoginHold[$k] } }
  $e = $led[$k]
  if ($e -and $e.last) {
    $t = [datetime]::MinValue; if ([datetime]::TryParse([string]$e.last, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$t)) {
      $u = $t.ToLocalTime().AddMinutes([int]$script:FsLoginCooldownMin)
      if ((Get-Date) -lt $u) { $n = [math]::Max($n, [int]$e.fails); $until = $u }
    }
  }
  return [pscustomobject]@{ fails = $n; until = $until; unknown = '' }
}
# writes the result of one try. $prev = the device's entry before the try was reserved ($null = none)
# 2.2.20 (Codex 2.2.19 R13): $notSent = the try failed BEFORE the password left this PC (the connection was refused, there was no
# route, or the password was held back: Basic over plain HTTP). Only then is the reserved try given back. A try that timed out, was
# cut off, or got an answer that is not the device's login document is UNKNOWN: the camera may have counted a wrong password, so the
# reserved try STAYS counted (2.2.19 gave it back, and six uncertain tries went to a camera with a limit of four).
function Set-FsLoginResult([string]$k, [string]$s, $prev = $null, [int]$reserved = -1, [bool]$notSent = $false) {
  if ($s -notin @('ok', 'refused', 'locked', 'noanswer', 'notfound', 'unknown')) { return }
  $h = Read-FsLoginLedger
  if ($script:FsLoginLedgerWhy) { $script:FsLoginHold[$k] = $script:FsLoginLedgerWhy; return }
  if ($s -eq 'ok') { $script:FsLoginFails.Remove($k); if ($h.ContainsKey($k)) { $h.Remove($k); if (-not (Save-FsLoginLedger $h)) { $script:FsLoginHold[$k] = 'the wrong-password count for this device could not be saved' } }; return }
  if ($s -in @('noanswer', 'notfound', 'unknown') -and $notSent) {
    # the password never left this PC: the reserved try is given back (a failed save leaves the higher count = the careful side)
    if ($null -ne $prev) { $h[$k] = $prev } else { [void]$h.Remove($k) }
    if (-not (Save-FsLoginLedger $h)) { Fs-LogLine ('the reserved try for ' + $k + ' could not be given back (the count stays one higher)') }
    return
  }
  if ($s -in @('noanswer', 'notfound', 'unknown')) { Fs-LogLine ('login to ' + $k + ': no clear answer (' + $s + ') - the try stays counted, the camera may have counted it as a wrong password') }
  $n = $(if ($s -eq 'locked') { [int]$script:FsMaxLoginFails } elseif ($reserved -ge 1) { $reserved } else { 1 + [int](Get-FsLoginBudget $k).fails })
  $script:FsLoginFails[$k] = $n
  $h[$k] = [pscustomobject]@{ fails = $n; last = (Get-Date).ToUniversalTime().ToString('o') }
  if (-not (Save-FsLoginLedger $h)) { $script:FsLoginHold[$k] = 'the wrong-password count for this device could not be saved' }
}
function Say-FsLoginHold([string]$k, [string]$why) {
  $t = 'login to ' + $k + ' not tried: ' + $why + ', so it is not known how many wrong passwords it has had - no password is sent to it until that is sorted out (it could lock)'
  Fs-LogLine $t
  if (-not $script:FsLoginHoldSaid.ContainsKey($k)) { $script:FsLoginHoldSaid[$k] = $true; try { Write-Host ('  ' + $t) -ForegroundColor Yellow } catch {} }
}
function Test-FsLogin([string]$ip, [string]$brand, [string]$pw) {
  $k = ($ip -replace ':\d+$', '')
  $prev = $null; $res = -1
  if ($pw) {
    $b = Get-FsLoginBudget $k
    if ($b.unknown) { Say-FsLoginHold $k ([string]$b.unknown); return 'locked' }
    if ([int]$b.fails -ge $script:FsMaxLoginFails) {
      Fs-LogLine ('login to ' + $k + ' not tried: ' + [int]$b.fails + ' wrong passwords already' + $(if ($b.until) { ' (this or an earlier run); not tried again before ' + $b.until.ToString('HH:mm') + ' so it does not lock' } else { ' this run' }))
      return 'locked'
    }
    # 2.2.19 (F27): the try is written down BEFORE the password is sent
    $res = 1 + [int]$b.fails
    if ($script:FsLoginLedger) {
      $h = Read-FsLoginLedger
      if ($script:FsLoginLedgerWhy) { Say-FsLoginHold $k $script:FsLoginLedgerWhy; return 'locked' }
      if ($h.ContainsKey($k)) { $prev = $h[$k] }
      $h[$k] = [pscustomobject]@{ fails = $res; last = (Get-Date).ToUniversalTime().ToString('o') }
      if (-not (Save-FsLoginLedger $h)) { $script:FsLoginHold[$k] = 'the wrong-password count could not be saved before the try'; Say-FsLoginHold $k $script:FsLoginHold[$k]; return 'locked' }
    }
  }
  $script:FsLoginNotSent = $false
  $s = Test-FsLoginOnce $ip $brand $pw
  if ($pw) { Set-FsLoginResult $k $s $prev $res ([bool]$script:FsLoginNotSent) }
  return $s
}
# 2.2.20 (Codex 2.2.19 R12): 'ok' only for the device's AUTHENTICATED information document - Hikvision a <DeviceInfo> XML document,
# Dahua a "type=<model>" answer. An HTTP 200 that is a login / HTML page, an error answer or garbage is 'unknown' (never "logs in").
# $script:FsLoginNotSent = $true when no request carrying the password reached the device (see Set-FsLoginResult).
$script:FsLoginNotSent = $false
function Test-FsLoginSentBefore($r) { if (-not $r -or [int]$r.code -ne 0) { return $false }; return (([string]$r.err) -in @('refused', 'unreachable', 'basic-over-http')) }
function Test-FsLoginOnce([string]$ip, [string]$brand, [string]$pw) {
  # 'ok' | 'refused' | 'locked' | 'noanswer' | 'notfound' | 'unknown'
  $cred = Fs-Cred $pw
  if ($brand -eq 'Dahua') {
    $r = Fs-Http -Ip $ip -Path '/cgi-bin/magicBox.cgi?action=getDeviceType' -Cred $cred -Timeout 6
    if ($r.code -eq 200) { if ([string]$r.body -match '(?im)^\s*type\s*=\s*\S' -and -not (Test-FsHtmlText ([string]$r.body))) { return 'ok' }; Fs-LogLine ('login to ' + $ip + ': HTTP 200 but not the device''s answer (a login or error page) - not taken as logged in'); return 'unknown' }
    if ($r.code -eq 401) { if ($r.body -match '(?i)lock') { return 'locked' }; return 'refused' }; if ($r.code -eq 404) { return 'notfound' }
    if (Test-FsLoginSentBefore $r) { $script:FsLoginNotSent = $true }
    return 'noanswer'
  }
  $r = Fs-Http -Ip $ip -Path '/ISAPI/System/deviceInfo' -Cred $cred -Timeout 6
  if ($r.code -eq 200) {
    $x = Fs-XmlDoc ([string]$r.body)
    if ($x -and $x.DocumentElement -and $x.DocumentElement.LocalName -eq 'DeviceInfo') { return 'ok' }
    Fs-LogLine ('login to ' + $ip + ': HTTP 200 but not a DeviceInfo document (a login or error page) - not taken as logged in'); return 'unknown'
  }
  if ($r.code -eq 401 -or $r.code -eq 403) { if ($r.body -match '(?i)lock|unlockTime') { return 'locked' }; return 'refused' }
  if ($r.code -eq 404 -and $brand -ne 'Hikvision') { return (Test-FsLoginOnce $ip 'Dahua' $pw) }
  if (Test-FsLoginSentBefore $r) { $script:FsLoginNotSent = $true }
  return 'noanswer'
}
function Find-FsPassword([string]$ip, [string]$brand, $candidates, [int]$maxTries = 3) {
  # tries the site's own passwords in order, never more than $maxTries, stops at a lock. Returns { state; label; value; tries }
  $n = 0; $last = 'unknown'
  foreach ($c in @($candidates)) {
    if ($n -ge $maxTries) { break }; $n++
    $s = Test-FsLogin $ip $brand $c.value
    if ($s -eq 'ok') { return [pscustomobject]@{ state = 'ok'; label = $c.label; value = $c.value; tries = $n } }
    if ($s -eq 'locked') { return [pscustomobject]@{ state = 'locked'; label = ''; value = ''; tries = $n } }
    if ($s -eq 'noanswer' -or $s -eq 'notfound' -or $s -eq 'unknown') { return [pscustomobject]@{ state = 'noanswer'; label = ''; value = ''; tries = $n } }
    $last = 'unknown'
  }
  return [pscustomobject]@{ state = $last; label = ''; value = ''; tries = $n }
}

# ---------------- device info / backup ----------------
function Get-FsInfo([string]$ip, [string]$brand, $cred) {
  if ($brand -eq 'Dahua') {
    $t = Fs-DhLines (Fs-Http -Ip $ip -Path '/cgi-bin/magicBox.cgi?action=getSystemInfo' -Cred $cred).body
    $v = Fs-DhLines (Fs-Http -Ip $ip -Path '/cgi-bin/magicBox.cgi?action=getSoftwareVersion' -Cred $cred).body
    return [pscustomobject]@{ brand = 'Dahua'; model = [string]$t['deviceType']; serial = [string]$t['serialNumber']; firmware = [string]$v['version'] }
  }
  $x = Fs-XmlDoc (Fs-Http -Ip $ip -Path '/ISAPI/System/deviceInfo' -Cred $cred).body
  return [pscustomobject]@{ brand = 'Hikvision'; model = (Fs-XText $x 'model'); serial = (Fs-XText $x 'serialNumber'); mac = (Fs-XText $x 'macAddress'); firmware = ((Fs-XText $x 'firmwareVersion') + ' ' + (Fs-XText $x 'firmwareReleasedDate')).Trim() }
}
# 2.2.15 (Codex 2.2.14 R2): WHICH device answers at an address: its MAC and serial as the device itself reports them ('' = could not
# be read). A password that logs in is not identity (a site password works on every camera of the site).
function Get-FsIdentity([string]$ip, [string]$brand, $cred) {
  $mac = ''; $ser = ''
  try {
    if ($brand -eq 'Dahua') {
      $rn = Fs-Http -Ip $ip -Path '/cgi-bin/configManager.cgi?action=getConfig&name=Network' -Cred $cred
      if ($rn -and [int]$rn.code -eq 200) { $h = Fs-DhLines $rn.body; $if = [string]$h['Network.DefaultInterface']; if (-not $if) { $if = 'eth0' }; $mac = [string]$h['Network.' + $if + '.PhysicalAddress'] }
      $rs = Fs-Http -Ip $ip -Path '/cgi-bin/magicBox.cgi?action=getSystemInfo' -Cred $cred
      if ($rs -and [int]$rs.code -eq 200) { $ser = [string](Fs-DhLines $rs.body)['serialNumber'] }
    } else {
      $r = Fs-Http -Ip $ip -Path '/ISAPI/System/deviceInfo' -Cred $cred
      if ($r -and [int]$r.code -eq 200) { $x = Fs-XmlDoc $r.body; if ($x) { $mac = Fs-XText $x 'macAddress'; $ser = Fs-XText $x 'serialNumber' } }
    }
  } catch { }
  return [pscustomobject]@{ mac = (ConvertTo-FsMac ([string]$mac)); serial = ([string]$ser).Trim() }
}
# 2.2.15 (Codex 2.2.14 R2): is the device that answers at $ip the camera the undo file names? '' = yes (same MAC; with no MAC in the
# file, the same serial). Otherwise the plain reason: another device, or its identity could not be read / the file has none.
# 2.2.19: $Src names where the wanted MAC / serial comes from ('the undo file', 'the scan'); read FRESH on every call (no cache).
function Get-FsUndoIdentityBlock([string]$ip, [string]$brand, $cred, [string]$wantMac, [string]$wantSerial, [string]$What = 'this camera', [string]$Src = 'the undo file') {
  $wm = ConvertTo-FsMac $wantMac; $ws = ([string]$wantSerial).Trim()
  if (-not $wm -and -not $ws) { return ($Src + ' has no MAC or serial for it, so it cannot be checked that the device at ' + $ip + ' is ' + $What) }
  $id = Get-FsIdentity $ip $brand $cred
  if ($wm) {
    if (-not $id.mac) { return ('the device at ' + $ip + ' did not tell its MAC, so it is not certain it is ' + $What) }
    if ($id.mac -ne $wm) { return ('the device at ' + $ip + ' is ANOTHER device (MAC ' + $id.mac + $(if ($id.serial) { ', serial ' + $id.serial } else { '' }) + '; ' + $Src + ' has MAC ' + $wm + ')') }
    return ''
  }
  if (-not $id.serial) { return ('the device at ' + $ip + ' did not tell its serial, so it is not certain it is ' + $What) }
  if ($id.serial.ToUpperInvariant() -ne $ws.ToUpperInvariant()) { return ('the device at ' + $ip + ' is ANOTHER device (serial ' + $id.serial + '; ' + $Src + ' has ' + $ws + ')') }
  return ''
}
# 2.2.16 (Codex 2.2.15 F3): the NVR's own MAC / serial, for the undo file. A site password that logs in is not identity (another NVR
# on the same password can take the address). mac/serial '' = could not be read.
# 2.2.19 (Codex 2.2.18 F03): read FRESH on every call. 2.2.16-2.2.18 kept the first answer per address for the whole run, so a
# recorder swapped in later in the run was taken for the first one.
function Get-FsNvrIdRecord([string]$ip, $cred) {
  return (Get-FsIdentity $ip 'Hikvision' $cred)
}
# 2.2.19 (Codex 2.2.18 F03): before a forward write to an NVR: is the recorder answering at $ip NOW the one the scan found (its MAC;
# serial only when the scan has no MAC)? '' = yes, else the plain reason. Fresh read every time; $id = an identity just read (optional).
function Get-FsFwdNvrBlock([string]$ip, $cred, [string]$scanMac, [string]$scanSerial, $id = $null) {
  $wm = ConvertTo-FsMac $scanMac; $ws = ([string]$scanSerial).Trim()
  if (-not $wm -and -not $ws) { return ('the scan did not record the MAC or serial of NVR ' + $ip + ', so it cannot be checked that the recorder answering there now is that NVR') }
  if (-not $id) { $id = Get-FsIdentity $ip 'Hikvision' $cred }
  if ($wm) {
    if (-not $id.mac) { return ('NVR ' + $ip + ' did not tell its MAC now, so it is not certain it is the NVR the scan found') }
    if ($id.mac -ne $wm) { return ('the recorder at ' + $ip + ' is now ANOTHER device (MAC ' + $id.mac + $(if ($id.serial) { ', serial ' + $id.serial } else { '' }) + '; the scan found MAC ' + $wm + ')') }
    return ''
  }
  if (-not $id.serial) { return ('NVR ' + $ip + ' did not tell its serial now, so it is not certain it is the NVR the scan found') }
  if ($id.serial.ToUpperInvariant() -ne $ws.ToUpperInvariant()) { return ('the recorder at ' + $ip + ' is now ANOTHER device (serial ' + $id.serial + '; the scan found ' + $ws + ')') }
  return ''
}
# 2.2.16 (Codex 2.2.15 F3): before Undo writes ANYTHING to an NVR (network, password, channel): is the device answering at $ip the NVR
# the undo file names? '' = yes. An undo file without its MAC / serial (older Toolkit) can never be confirmed = the reason, no write.
# 2.2.19 (Codex 2.2.18 F03): checked FRESH every time (2.2.16-2.2.18 remembered a first "yes" per address for the rest of the run).
function Get-FsUndoNvrBlock([string]$ip, $cred, $entry, [string]$macField = 'mac', [string]$serField = 'serial') {
  $m = ''; $s = ''
  if ($entry -is [System.Collections.IDictionary]) { $m = [string]$entry[$macField]; $s = [string]$entry[$serField] }
  elseif ($entry) { if ($entry.PSObject.Properties[$macField]) { $m = [string]$entry.$macField }; if ($entry.PSObject.Properties[$serField]) { $s = [string]$entry.$serField } }
  if (-not $m -and -not $s) { return ('the undo file has no MAC or serial for this NVR (made by an older Toolkit), so it cannot be checked that the device at ' + $ip + ' is that NVR') }
  return (Get-FsUndoIdentityBlock $ip 'Hikvision' $cred $m $s 'that NVR')
}
# 2.2.19 (Codex 2.2.18 F02): before a device is MOVED to $dest (forward or Undo): is that address free right now? Returns
# { state ('free'|'self'|'taken'|'unknown'); why }. 'self' = the device answering there IS the saved device (its MAC / serial, read
# fresh; an earlier Undo already put it there). Anything else answering there = 'taken' (another device, or one that cannot be
# identified): nothing is moved onto it. $pw / $mac / $serial = the saved device's login and identity ('' = do not try to identify).
function Get-FsMoveTargetState([string]$dest, [string]$brand, [string]$pw, [string]$mac, [string]$serial, [string]$What = 'this camera') {
  if (-not (Test-FsIPv4 $dest)) { return [pscustomobject]@{ state = 'unknown'; why = ('the address to move to (' + $dest + ') is not a valid address') } }
  $free = $false; try { $free = [bool](Test-FsIpFree $dest) } catch { $free = $false }
  if ($free) { return [pscustomobject]@{ state = 'free'; why = '' } }
  if ($pw -and ($mac -or $serial) -and (Test-FsLogin $dest $brand $pw) -eq 'ok') {
    $idw = Get-FsUndoIdentityBlock $dest $brand (Fs-Cred $pw) $mac $serial $What
    if (-not $idw) { return [pscustomobject]@{ state = 'self'; why = '' } }
    return [pscustomobject]@{ state = 'taken'; why = ($dest + ' is already used: ' + $idw) }
  }
  if ($script:FsIpFreeWhy) { return [pscustomobject]@{ state = 'unknown'; why = $script:FsIpFreeWhy } }   # 2.2.20 (R04): unknown, not free
  return [pscustomobject]@{ state = 'taken'; why = ($dest + ' is already used by another device (it answers there and it is not ' + $What + ')') }
}
# 2.2.19 (Codex 2.2.18 F13): a device switched back to DHCP leaves the address it had; it counts as back only when it is FOUND again by
# its MAC and reads back DHCP on. The addresses where that MAC answers now ($first is tried first: the address it had before the run).
function Find-FsAddrByMac([string]$mac, [string]$first = '') {
  $m = ConvertTo-FsMac $mac; $out = @(); if ($first) { $out += $first }
  if (-not $m) { return $out }
  $hits = @()
  try {
    if ($script:FsNetOps -and $script:FsNetOps.ContainsKey('findmac')) { $hits = @(& $script:FsNetOps['findmac'] @{ mac = $m }) }
    elseif ($script:FsMockUrl) { $fj = (Fs-Http -Ip '_pc' -Path '/scan').body | ConvertFrom-Json; foreach ($d in @($fj)) { if ((ConvertTo-FsMac ([string]$d.mac)) -eq $m) { $hits += [string]$d.ip } } }
    else { foreach ($n in @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue)) { if ($n.State -in @('Reachable', 'Stale', 'Permanent', 'Delay', 'Probe') -and (ConvertTo-FsMac (([string]$n.LinkLayerAddress) -replace '-', ':')) -eq $m) { $hits += [string]$n.IPAddress } } }
  } catch { }
  foreach ($h in $hits) { if ($h -and $out -notcontains $h) { $out += $h } }
  return $out
}
# 2.2.19 (Codex 2.2.18 F13): after a DHCP restore: find the device by its MAC and read DHCP back. Returns { ok; ip; why }.
# ok = $true only when a device that logs in is THIS one (MAC / serial) and reads back DHCP on. Anything else = NOT CHECKED.
function Test-FsDhcpBack([string]$mac, [string]$serial, [string]$brand, [string]$pw, [string]$first, [string]$What = 'this camera') {
  $seen = @()
  foreach ($a in @(Find-FsAddrByMac $mac $first)) {
    if ((Test-FsLogin $a $brand $pw) -ne 'ok') { continue }
    $idw = Get-FsUndoIdentityBlock $a $brand (Fs-Cred $pw) $mac $serial $What
    if ($idw) { $seen += $idw; continue }
    $nm = Get-FsNetMismatch $a $brand (Fs-Cred $pw) $null '' '' '' -Dhcp
    if ($nm) { return [pscustomobject]@{ ok = $false; ip = $a; why = ('found at ' + $a + ' by its MAC, but ' + $nm) } }
    return [pscustomobject]@{ ok = $true; ip = $a; why = '' }
  }
  return [pscustomobject]@{ ok = $false; ip = ''; why = ('it was not found again by its MAC' + $(if ($seen.Count) { ' (' + ($seen -join '; ') + ')' } else { '' })) }
}
# 2.2.4 (Codex re-review): a backup file counts only when its CONTENT is what the device exports: a login or HTML page, an
# error answer, or a file too small to be a config export is FAILED (2.2.3 counted any non-empty file, so a login page was "backup saved").
function Get-FsFileHead([string]$path, [int]$n = 4096) {
  $fs = [IO.File]::OpenRead($path); try { $b = New-Object byte[] ([Math]::Min([int64]$n, $fs.Length)); [void]$fs.Read($b, 0, $b.Length) } finally { $fs.Dispose() }
  return [Text.Encoding]::UTF8.GetString($b)
}
function Test-FsHtmlText([string]$t) { return ($t -match '(?is)^\s*(\xEF\xBB\xBF|\uFEFF)?\s*(<!doctype\s+html|<html)' -or $t -match '(?is)<html[\s>]|<body[\s>]|<form[^>]*>|type\s*=\s*["'']?password|<title>[^<]*(log\s*in|sign\s*in)') }
function Test-FsBackupFile([string]$path, [string]$kind) {
  # returns '' when the file is a real backup of that kind, else why not. kind: config (the device's own export), xml, text (Dahua key=value)
  if (-not $path -or -not (Test-Path -LiteralPath $path)) { return 'missing' }
  $len = (Get-Item -LiteralPath $path).Length; if ($len -le 0) { return 'empty' }
  $head = Get-FsFileHead $path
  if (Test-FsHtmlText $head) { return 'the device answered with a login/HTML page, not its settings' }
  if ($kind -eq 'config') {
    if ($head -match '(?is)^\s*<\?xml[^>]*>\s*<ResponseStatus|^\s*<ResponseStatus') { return 'the device answered with an error, not its settings' }
    if ($len -lt 512) { return ('too small to be a settings export (' + $len + ' bytes)') }
    return ''
  }
  if ($kind -eq 'xml') {
    try { $x = New-Object Xml.XmlDocument; $x.XmlResolver = $null; $x.LoadXml([IO.File]::ReadAllText($path)) } catch { return 'not valid XML' }
    $root = [string]$x.DocumentElement.LocalName; if ($root -in @('html', 'ResponseStatus')) { return ('the device answered ' + $root + ', not its settings') }
    return ''
  }
  if ($kind -eq 'text') { if ([IO.File]::ReadAllText($path) -notmatch '(?m)^[A-Za-z][\w.\[\]]*=') { return 'not the device''s key=value settings' }; return '' }
  return ''
}
function Get-FsBackupKind([string]$leaf) { $l = $leaf.ToLower(); if ($l -in @('configurationdata.bin', 'config-export.backup')) { return 'config' }; if ($l -like '*.xml') { return 'xml' }; return 'text' }
function Add-FsBackupFile([string]$f, $r) {
  # keep the file only when the answer was 200 and the content checks out; otherwise delete it and log FAILED
  $why = $(if ($r -and $r.PSObject.Properties['code'] -and [int]$r.code -ne 200) { 'answer ' + $r.code } else { Test-FsBackupFile $f (Get-FsBackupKind (Split-Path -Leaf $f)) })
  if ($why) { Fs-LogLine ('backup FAILED: ' + (Split-Path -Leaf $f) + ' - ' + $why); $script:FsBackupFailed += ((Split-Path -Leaf $f) + ': ' + $why); Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue; return $false }
  return $true
}
function Save-FsBackup([string]$ip, [string]$brand, $cred, [string]$dir) {
  # the camera's own config export (its import format) + readable network / video settings. Stays on this PC (run folder).
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $files = @(); $script:FsBackupFailed = @()
  if ($brand -eq 'Dahua') {
    $f = Join-Path $dir 'config-export.backup'; $r = Fs-Http -Ip $ip -Path '/cgi-bin/Config.backup?action=All' -Cred $cred -OutFile $f -Timeout 20
    if (Add-FsBackupFile $f $r) { $files += $f }
    foreach ($n in @('Network', 'Encode', 'SmartEncode', 'NTP')) { $r = Fs-Http -Ip $ip -Path ('/cgi-bin/configManager.cgi?action=getConfig&name=' + $n) -Cred $cred; if ($r.code -eq 200) { $p = Join-Path $dir ($n + '.txt'); [IO.File]::WriteAllText($p, $r.body); if (Add-FsBackupFile $p $r) { $files += $p } } }
  } else {
    $f = Join-Path $dir 'configurationData.bin'; $r = Fs-Http -Ip $ip -Path '/ISAPI/System/configurationData' -Cred $cred -OutFile $f -Timeout 30
    if (Add-FsBackupFile $f $r) { $files += $f }
    foreach ($pp in @(@('network.xml', '/ISAPI/System/Network/interfaces'), @('stream-101.xml', '/ISAPI/Streaming/channels/101'), @('stream-102.xml', '/ISAPI/Streaming/channels/102'), @('time.xml', '/ISAPI/System/time'))) {
      $r = Fs-Http -Ip $ip -Path $pp[1] -Cred $cred; if ($r.code -eq 200) { $p = Join-Path $dir $pp[0]; [IO.File]::WriteAllText($p, $r.body); if (Add-FsBackupFile $p $r) { $files += $p } }
    }
  }
  return $files
}

# ---------------- 2.2.3 (Codex #12, #18): live checks before a recorder or camera is changed ----------------
function Get-FsNvrMoveTarget([string]$planned, [string]$scheme, $nvrHosts, $taken) {
  # the planned NVR address is checked LIVE (ping + ARP) right before the move: a printer or router device nobody discovered may
  # sit on .20. Taken -> the next standard NVR address that is free; none free -> '' (the NVR is not moved).
  # $taken: addresses other devices of this run already have or were given.
  $cands = @(); if ($planned) { $cands += $planned }
  foreach ($h in @($nvrHosts)) { $a = $scheme + '.' + [int]$h; if ($cands -notcontains $a) { $cands += $a } }
  foreach ($a in $cands) { if (@($taken) -contains $a) { continue }; if (Test-FsIpFree $a) { return $a } }
  return ''
}
function Test-FsBackupComplete($files, [string]$brand, [switch]$Nvr) {
  # a backup counts only when it can bring the device back: the device's own config export AND its network settings
  # (cameras: AND the main stream). One stray file (time.xml) is not a backup. 2.2.4: each needed file's CONTENT is checked too
  # (a login/HTML page or an error answer saved under the right name is FAILED); $script:FsBackupWhy says why.
  $script:FsBackupWhy = ''
  $byName = @{}; foreach ($f in @($files)) { if ($f) { $byName[(Split-Path -Leaf ([string]$f)).ToLower()] = [string]$f } }
  if ($brand -eq 'Dahua') { $need = @('config-export.backup', 'network.txt'); if (-not $Nvr) { $need += 'encode.txt' } }
  else { $need = @('configurationdata.bin', 'network.xml'); if (-not $Nvr) { $need += 'stream-101.xml' } }
  foreach ($n in $need) {
    if (-not $byName.ContainsKey($n)) { $fw = @(@($script:FsBackupFailed) | Where-Object { ([string]$_).ToLower().StartsWith($n + ':') }); $script:FsBackupWhy = $(if ($fw.Count) { [string]$fw[0] } else { $n + ': not saved' }); return $false }
    $why = Test-FsBackupFile $byName[$n] (Get-FsBackupKind $n); if ($why) { $script:FsBackupWhy = $n + ': ' + $why; return $false }
  }
  return $true
}

# ---------------- network ----------------
# 2.2.12 (Codex 2.2.11 #2): an address read is only used when it is a real, complete answer: HTTP 200, a valid IPv4 address and
# mask, a known DHCP flag and a gateway that is empty or a valid IPv4. An error page (Dahua "Error", Hikvision <ResponseStatus>) or a
# half answer returns $null and says why in $script:FsNetWhy, so nothing is ever journaled (or moved) from a read that failed.
function Test-FsIPv4([string]$s) {
  $m = [regex]::Match(([string]$s).Trim(), '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$'); if (-not $m.Success) { return $false }
  for ($i = 1; $i -le 4; $i++) { if ([int]$m.Groups[$i].Value -gt 255) { return $false } }
  return $true
}
function Test-FsNetComplete($n) {
  # $null = complete; otherwise the plain reason
  if (-not $n) { return 'no answer' }
  if (-not (Test-FsIPv4 ([string]$n.ip)) -or [string]$n.ip -eq '0.0.0.0') { return 'no valid address in the answer' }
  if (-not (Test-FsIPv4 ([string]$n.mask)) -or [string]$n.mask -eq '0.0.0.0') { return 'no valid subnet mask in the answer' }
  if ([string]$n.gw -and -not (Test-FsIPv4 ([string]$n.gw))) { return 'the gateway in the answer is not an address' }
  if ($n.dhcp -isnot [bool]) { return 'the answer does not say whether it uses DHCP' }
  return $null
}
# 2.2.19 (Codex 2.2.18 class D): one reading of an addressing mode everywhere it is compared or restored.
# $true = DHCP (dynamic / dhcp / DHCP / true / 1 / on / enabled), $false = fixed (static / manual / fixed / false / 0 / off / disabled),
# $null = unknown (missing or anything else: never taken as either).
function ConvertTo-FsDhcpMode($v) {
  if ($v -is [bool]) { return $v }
  $s = ([string]$v).Trim().ToLowerInvariant()
  if ($s -in @('dynamic', 'dhcp', 'true', '1', 'on', 'enabled', 'enable', 'yes', 'auto')) { return $true }
  if ($s -in @('static', 'manual', 'fixed', 'false', '0', 'off', 'disabled', 'disable', 'no')) { return $false }
  return $null
}
function Get-FsNet([string]$ip, [string]$brand, $cred) {
  $script:FsNetWhy = ''
  if ($brand -eq 'Dahua') {
    $rd = Fs-Http -Ip $ip -Path '/cgi-bin/configManager.cgi?action=getConfig&name=Network' -Cred $cred
    if (-not $rd -or [int]$rd.code -ne 200) { $script:FsNetWhy = ('the camera answered ' + $(if ($rd -and [int]$rd.code) { 'HTTP ' + $rd.code } else { 'nothing' })); return $null }
    $h = Fs-DhLines $rd.body
    $if = [string]$h['Network.DefaultInterface']; if (-not $if) { $if = 'eth0' }
    $pre = 'Network.' + $if + '.'
    $dh = ConvertTo-FsDhcpMode ([string]$h[$pre + 'DhcpEnable'])   # 2.2.19 (Codex 2.2.18 D): true/1/dhcp/dynamic = DHCP; false/0/static/manual = fixed
    if (-not $h.ContainsKey($pre + 'IPAddress') -or -not $h.ContainsKey($pre + 'DefaultGateway')) { $script:FsNetWhy = 'the answer has no address/gateway lines'; return $null }
    $o = [pscustomobject]@{ iface = $if; ip = [string]$h[$pre + 'IPAddress']; mask = [string]$h[$pre + 'SubnetMask']; gw = [string]$h[$pre + 'DefaultGateway']; dhcp = $dh; dns1 = [string]$h[$pre + 'DnsServers[0]']; dns2 = [string]$h[$pre + 'DnsServers[1]']; raw = $null
      has = [pscustomobject]@{ gw = $h.ContainsKey($pre + 'DefaultGateway'); dns1 = $h.ContainsKey($pre + 'DnsServers[0]'); dns2 = $h.ContainsKey($pre + 'DnsServers[1]') } }   # 2.2.20 (R09): present, not only non-empty
    $why = Test-FsNetComplete $o; if ($why) { $script:FsNetWhy = $why; return $null }
    return $o
  }
  $rl = Fs-Http -Ip $ip -Path '/ISAPI/System/Network/interfaces' -Cred $cred
  $li = $null; if ($rl -and [int]$rl.code -eq 200) { $li = Fs-XmlDoc $rl.body }
  # 2.2.3 (Codex #10): a recorder with a LAN port and a PoE camera port has two interfaces; the one to read/change is the one
  # carrying the address we are talking to. One interface = that one. Several and none carries it = $null (nothing is changed).
  $ids = @(); if ($li) { foreach ($nd in @(Fs-XFind $li 'NetworkInterface')) { $v = Fs-XText $nd 'id'; if ($v) { $ids += $v } } }
  if (-not $ids.Count) { $ids = @('1') }
  $want = ($ip -replace ':\d+$', ''); $r = $null; $x = $null; $id = ''; $lastWhy = ''
  foreach ($cand in $ids) {
    $rr = Fs-Http -Ip $ip -Path ('/ISAPI/System/Network/interfaces/' + $cand + '/ipAddress') -Cred $cred
    if (-not $rr -or [int]$rr.code -ne 200) { $lastWhy = ('the device answered ' + $(if ($rr -and [int]$rr.code) { 'HTTP ' + $rr.code } else { 'nothing' })); continue }
    $xx = Fs-XmlDoc $rr.body
    if (-not $xx -or -not $xx.DocumentElement -or $xx.DocumentElement.LocalName -ne 'IPAddress') { $lastWhy = 'the answer is not an address document (an error answer)'; continue }
    if ($ids.Count -eq 1 -or (Fs-XText $xx 'ipAddress') -eq $want) { $r = $rr; $x = $xx; $id = $cand; break }
  }
  if (-not $x) { $script:FsNetWhy = $(if ($lastWhy) { $lastWhy } else { 'no interface carries ' + $want }); return $null }
  $gwn = @(Fs-XFind $x 'DefaultGateway'); $gw = ''; if ($gwn.Count) { $gw = Fs-XText $gwn[0] 'ipAddress' }
  $d1 = @(Fs-XFind $x 'PrimaryDNS'); $d2 = @(Fs-XFind $x 'SecondaryDNS')
  $dh = ConvertTo-FsDhcpMode (Fs-XText $x 'addressingType')   # 2.2.19 (Codex 2.2.18 D): dynamic / dhcp / DHCP = DHCP; static / manual / fixed = fixed
  # the top-level address (not the gateway's / DNS's ipAddress)
  $top = ''; foreach ($n in @($x.DocumentElement.ChildNodes)) { if ($n.LocalName -eq 'ipAddress') { $top = ([string]$n.InnerText).Trim() } }
  $mk = ''; foreach ($n in @($x.DocumentElement.ChildNodes)) { if ($n.LocalName -eq 'subnetMask') { $mk = ([string]$n.InnerText).Trim() } }
  # 2.2.20 (Codex 2.2.19 R09): WHETHER the router / DNS fields are in the answer is kept apart from their value: a missing node is
  # "not known", an explicit empty <ipAddress/> inside the node is a real empty setting
  $hasN = { param($nodes) [bool](@($nodes).Count -and @(Fs-XFind $nodes[0] 'ipAddress').Count) }
  $o = [pscustomobject]@{ iface = $id; ip = $top; mask = $mk; gw = $gw; dhcp = $dh; dns1 = $(if ($d1.Count) { Fs-XText $d1[0] 'ipAddress' } else { '' }); dns2 = $(if ($d2.Count) { Fs-XText $d2[0] 'ipAddress' } else { '' }); raw = $r.body
    has = [pscustomobject]@{ gw = (& $hasN $gwn); dns1 = (& $hasN $d1); dns2 = (& $hasN $d2) } }
  $why = Test-FsNetComplete $o; if ($why) { $script:FsNetWhy = $why; return $null }
  return $o
}
# 2.2.20 (Codex 2.2.19 R09): '' when a network reading holds every value a later Undo needs to put it back (mask, mode, router, DNS 1,
# DNS 2 - each PRESENT in the answer, empty allowed), else which ones are not known. A reading without the presence record (older
# callers / stand-ins) counts its non-empty values as present.
function Get-FsNetUndoGap($n) {
  if (-not $n) { return 'its network settings could not be read' }
  $miss = @()
  if (-not (Test-FsIPv4 ([string]$n.mask))) { $miss += 'subnet mask' }
  if ($n.dhcp -isnot [bool]) { $miss += 'fixed / DHCP' }
  $has = $(if ($n.PSObject.Properties['has']) { $n.has } else { $null })
  foreach ($f in @(@('gw', 'router (gateway)'), @('dns1', 'DNS 1'), @('dns2', 'DNS 2'))) {
    $p = $(if ($has -and $has.PSObject.Properties[$f[0]]) { [bool]$has.($f[0]) } else { [bool][string]$n.($f[0]) })
    if (-not $p) { $miss += $f[1] }
  }
  if ($miss.Count) { return ('its answer does not include its ' + ($miss -join ', ') + ', so it could not be put back as it was') }
  return ''
}
function Set-FsNet([string]$ip, [string]$brand, $cred, $net, [string]$newIp, [string]$mask, [string]$gw, [string]$dns1 = '8.8.8.8', [string]$dns2 = '1.1.1.1', [switch]$Dhcp) {
  # returns { ok; reboot; why } . The device answers on the NEW address afterwards (or after its own restart).
  # 2.2.1 (review H8): -Dhcp = undo of a device that got its address from the router: it goes back to DHCP (address fields as saved).
  if (-not $mask) { $mask = '255.255.255.0' }
  # 2.2.20 (Codex 2.2.19 R09): a value asked for must be IN the document that is written. 2.2.19 skipped DNS / router silently when
  # the device's answer had no such node, sent the PUT without them and reported success. Now nothing is written then.
  if ($brand -ne 'Dahua' -and $net) {
    $x0 = Fs-XmlDoc ([string]$net.raw)
    if ($x0) {
      $lack = @()
      if ($gw -and -not @(Fs-XFind $x0 'DefaultGateway').Count) { $lack += 'router (gateway)' }
      if ($dns1 -and -not @(Fs-XFind $x0 'PrimaryDNS').Count) { $lack += 'DNS 1' }
      if ($dns2 -and -not @(Fs-XFind $x0 'SecondaryDNS').Count) { $lack += 'DNS 2' }
      if ($lack.Count) { $w = ('its network settings have no ' + ($lack -join ', ') + ' field, so they could not be set - nothing was written'); Fs-LogLine ($ip + ': ' + $w); return [pscustomobject]@{ ok = $false; reboot = $false; why = $w } }
    }
  }
  if ($brand -eq 'Dahua') {
    $pre = 'Network.' + $net.iface + '.'
    $ok = Fs-DhSet $ip $cred @{ ($pre + 'IPAddress') = $newIp; ($pre + 'SubnetMask') = $mask; ($pre + 'DefaultGateway') = $gw; ($pre + 'DhcpEnable') = $(if ($Dhcp) { 'true' } else { 'false' }); ($pre + 'DnsServers[0]') = $dns1; ($pre + 'DnsServers[1]') = $dns2 }
    return [pscustomobject]@{ ok = $ok; reboot = $false }
  }
  $x = Fs-XmlDoc $net.raw; if (-not $x) { return [pscustomobject]@{ ok = $false; reboot = $false } }
  [void](Fs-XSet $x 'addressingType' $(if ($Dhcp) { 'dynamic' } else { 'static' }))
  $top = @(Fs-XFind $x 'IPAddress')[0]
  foreach ($n in @($top.ChildNodes)) { if ($n.LocalName -eq 'ipAddress') { $n.InnerText = $newIp }; if ($n.LocalName -eq 'subnetMask') { $n.InnerText = $mask } }
  $g = @(Fs-XFind $x 'DefaultGateway'); if ($g.Count) { [void](Fs-XSet $g[0] 'ipAddress' $gw) }
  $d = @(Fs-XFind $x 'PrimaryDNS'); if ($d.Count) { [void](Fs-XSet $d[0] 'ipAddress' $dns1) }
  $d = @(Fs-XFind $x 'SecondaryDNS'); if ($d.Count) { [void](Fs-XSet $d[0] 'ipAddress' $dns2) }
  $r = Fs-Http -Ip $ip -Method 'PUT' -Path ('/ISAPI/System/Network/interfaces/' + $net.iface + '/ipAddress') -Body $x.OuterXml -Cred $cred
  return [pscustomobject]@{ ok = (Fs-HikOk $r); reboot = (Fs-HikNeedsReboot $r) }
}
# 2.2.18 (Codex F3): an accepted network write, and a device that logs in afterwards, is not proof the settings took (a recorder can
# acknowledge a new router and keep its old one). Read the WHOLE network config back where the device answers now ($ip) and compare
# every field Set-FsNet was asked for: address, mask, router, DNS 1 / 2, fixed or DHCP. $before = Get-FsNet's read before the write
# (a DNS field the device never had stays out of the check). -Dhcp: only "DHCP is on" is checked (the router picks the rest).
# Returns '' when everything reads back as asked, otherwise the fields that do not, in plain words.
function Get-FsNetMismatch([string]$ip, [string]$brand, $cred, $before, [string]$wantIp, [string]$mask, [string]$gw, [string]$dns1 = '8.8.8.8', [string]$dns2 = '1.1.1.1', [switch]$Dhcp) {
  $rd = $null; try { $rd = Get-FsNet $ip $brand $cred } catch { $rd = $null }
  if (-not $rd) { return ('its network settings could not be read back (' + $(if ($script:FsNetWhy) { $script:FsNetWhy } else { 'no answer' }) + ')') }
  if (-not $mask) { $mask = '255.255.255.0' }
  $bad = @()
  if ($Dhcp) {
    if ($rd.dhcp -ne $true) { $bad += 'it still has a fixed address (DHCP is off)' }
    return ($bad -join '; ')
  }
  if ($rd.dhcp -ne $false) { $bad += 'it is still on DHCP (not a fixed address)' }
  if ([string]$rd.ip -ne $wantIp) { $bad += ('address is ' + $rd.ip + ', not ' + $wantIp) }
  if ([string]$rd.mask -ne $mask) { $bad += ('mask is ' + $rd.mask + ', not ' + $mask) }
  if ($rh -and $gw -and -not [bool]$rh.gw) { $bad += ('router (gateway) is missing from its settings, not ' + $gw) }
  elseif ([string]$rd.gw -ne $gw) { $bad += ('router (gateway) is ' + $(if ($rd.gw) { $rd.gw } else { 'empty' }) + ', not ' + $(if ($gw) { $gw } else { 'empty' })) }
  # 2.2.20 (Codex 2.2.19 R09): a DNS asked for is ALWAYS checked (2.2.19 skipped the check when neither reading had one, so a write that
  # left DNS out "verified"); a DNS missing from the answer is "missing", never equal to an empty one
  $b1 = ''; $b2 = ''; if ($before) { $b1 = [string]$before.dns1; $b2 = [string]$before.dns2 }
  $rh = $(if ($rd.PSObject.Properties['has']) { $rd.has } else { $null })
  if ($rh -and ($dns1 -or $b1) -and -not [bool]$rh.dns1) { $bad += ('DNS 1 is missing from its settings, not ' + $(if ($dns1) { $dns1 } else { 'empty' })) }
  elseif (($dns1 -or $b1 -or [string]$rd.dns1) -and [string]$rd.dns1 -ne $dns1) { $bad += ('DNS 1 is ' + $(if ($rd.dns1) { $rd.dns1 } else { 'empty' }) + ', not ' + $(if ($dns1) { $dns1 } else { 'empty' })) }
  if ($rh -and ($dns2 -or $b2) -and -not [bool]$rh.dns2) { $bad += ('DNS 2 is missing from its settings, not ' + $(if ($dns2) { $dns2 } else { 'empty' })) }
  elseif (($dns2 -or $b2 -or [string]$rd.dns2) -and [string]$rd.dns2 -ne $dns2) { $bad += ('DNS 2 is ' + $(if ($rd.dns2) { $rd.dns2 } else { 'empty' }) + ', not ' + $(if ($dns2) { $dns2 } else { 'empty' })) }
  return ($bad -join '; ')
}

# ---------------- password ----------------
# 2.2.20 (Codex 2.2.19 R12): a password that logs in proves the outcome of a password write ONLY on the saved device: 'ok' = the
# authenticated information document came back (Test-FsLoginOnce) AND, when a MAC / serial was saved, the device answering is that
# device (fresh read, Get-FsUndoIdentityBlock). Otherwise 'other' (another / unidentified device: $script:FsLoginIsWhy) or the
# login's own state. Used in the accepted-write AND the lost-answer branches (Resolve-FsPwChange, "old password back" checks).
$script:FsLoginIsWhy = ''
function Test-FsLoginIs([string]$ip, [string]$brand, [string]$pw, [string]$mac = '', [string]$serial = '', [string]$What = 'this camera') {
  $script:FsLoginIsWhy = ''
  $s = Test-FsLogin $ip $brand $pw
  if ($s -ne 'ok') { return $s }
  if (-not (ConvertTo-FsMac $mac) -and -not ([string]$serial).Trim()) { return 'ok' }
  $idw = Get-FsUndoIdentityBlock $ip $brand (Fs-Cred $pw) $mac $serial $What 'the record'
  if ($idw) { $script:FsLoginIsWhy = $idw; Fs-LogLine ('login to ' + $ip + ' works, but not certified: ' + $idw); return 'other' }
  return 'ok'
}
function Resolve-FsPwChange([string]$ip, [string]$brand, [string]$newPw, [string]$oldPw, [string]$mac = '', [string]$serial = '') {
  # 2.2.3 (Codex #19): after a password write, what the device REALLY has: 'changed' (new logs in), 'unchanged' (old still logs in)
  # or 'unknown' (neither answers now: the write may have taken). One login try each; 'unknown' is bookkept as maybe-changed.
  # 2.2.20 (R12): "logs in" = the authenticated DeviceInfo / type answer of the SAVED device (MAC / serial when given), never HTTP 200 alone
  $sn = Test-FsLoginIs $ip $brand $newPw $mac $serial
  if ($sn -eq 'ok') { return 'changed' }
  if ($sn -eq 'other') { return 'unknown' }
  if ($oldPw -and (Test-FsLoginIs $ip $brand $oldPw $mac $serial) -eq 'ok') { return 'unchanged' }
  return 'unknown'
}
function Set-FsPassword([string]$ip, [string]$brand, $oldCred, [string]$newPw) {
  if ($brand -eq 'Dahua') {
    # Dahua's password CGI only takes the passwords in its address: over HTTPS that address is encrypted too (2.2.1, review H1)
    $r = Fs-HttpSecret -Ip $ip -Path ('/cgi-bin/userManager.cgi?action=modifyPassword&name=admin&pwd=' + [uri]::EscapeDataString($newPw) + '&pwdOld=' + [uri]::EscapeDataString((Fs-Plain $oldCred))) -Cred $oldCred
    return ($r.code -eq 200 -and $r.body -match '(?i)OK')
  }
  $xml = '<?xml version="1.0" encoding="UTF-8"?><User version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema"><id>1</id><userName>admin</userName><password>' + (Fs-Xml $newPw) + '</password><loginPassword>' + (Fs-Xml (Fs-Plain $oldCred)) + '</loginPassword></User>'
  $r = Fs-HttpSecret -Ip $ip -Method 'PUT' -Path '/ISAPI/Security/users/1' -Body $xml -Cred $oldCred
  return (Fs-HikOk $r)
}

# ---------------- video settings (main stream) ----------------
function Get-FsStream([string]$ip, [string]$brand, $cred) {
  if ($brand -eq 'Dahua') {
    $h = Fs-DhLines (Fs-Http -Ip $ip -Path '/cgi-bin/configManager.cgi?action=getConfig&name=Encode' -Cred $cred).body
    if (-not $h.Count) { return $null }
    $p = 'Encode[0].MainFormat[0].Video.'
    # 2.2.19 (F19): Smart Codec on / off only from an explicit true / false; a 200 answer without the setting = the camera has none
    $scR = Fs-Http -Ip $ip -Path '/cgi-bin/configManager.cgi?action=getConfig&name=SmartEncode' -Cred $cred
    $sc = $(if ($scR -and [int]$scR.code -eq 200) { Fs-DhLines $scR.body } else { @{} })
    $scv = ''; $scSeen = $false; foreach ($k in $sc.Keys) { if ($k -match 'SmartEncode\[0\]\.Enable$') { $scSeen = $true; $vv = ([string]$sc[$k]).ToLowerInvariant(); if ($vv -eq 'true') { $scv = 'on' } elseif ($vv -eq 'false') { $scv = 'off' } } }
    if (-not $scSeen -and $scR -and [int]$scR.code -eq 200 -and $sc.Count) { $scv = 'none' }
    return [pscustomobject]@{ codec = ([string]$h[$p + 'Compression'] -replace 'H\.?26', 'H.26'); fps = [int][double]$h[$p + 'FPS']; width = [int]$h[$p + 'Width']; height = [int]$h[$p + 'Height']; bitrate = [int]$h[$p + 'BitRate']; gop = [int]$h[$p + 'GOP']; smartCodec = $scv; maxWidth = 0; maxHeight = 0; raw = $null }
  }
  # 2.2.19 (Codex 2.2.18 F19): only a 200 answer that IS a stream document counts; a field missing from it stays empty / 0 (unknown),
  # and Smart Codec is 'none' only when the camera's capabilities were read and list no Smart Codec (a missing or garbled answer = unknown)
  $r = Fs-Http -Ip $ip -Path '/ISAPI/Streaming/channels/101' -Cred $cred
  if (-not $r -or [int]$r.code -ne 200) { return $null }
  $x = Fs-XmlDoc $r.body; if (-not $x -or -not $x.DocumentElement -or $x.DocumentElement.LocalName -ne 'StreamingChannel') { return $null }
  $q = Fs-XText $x 'videoQualityControlType'; $br = $(if ($q -eq 'VBR') { Fs-XText $x 'vbrUpperCap' } else { Fs-XText $x 'constantBitRate' })
  $scn = @(Fs-XFind $x 'SmartCodec'); $sc = ''
  if ($scn.Count) { $sev = ([string](Fs-XText $scn[0] 'enabled')).ToLowerInvariant(); if ($sev -eq 'true') { $sc = 'on' } elseif ($sev -eq 'false') { $sc = 'off' } }
  $mw = 0; $mh = 0
  $capR = Fs-Http -Ip $ip -Path '/ISAPI/Streaming/channels/101/capabilities' -Cred $cred
  $cap = $(if ($capR -and [int]$capR.code -eq 200) { Fs-XmlDoc $capR.body } else { $null })
  if (-not $scn.Count -and $cap -and @(Fs-XFind $cap 'Video').Count -and -not @(Fs-XFind $cap 'SmartCodec').Count) { $sc = 'none' }
  if ($cap) { $wn = @(Fs-XFind $cap 'videoResolutionWidth'); if ($wn.Count -and $wn[0].opt) { $mw = [int](@($wn[0].opt -split ',' | ForEach-Object { [int]$_ } | Sort-Object -Descending)[0]) }; $hn = @(Fs-XFind $cap 'videoResolutionHeight'); if ($hn.Count -and $hn[0].opt) { $mh = [int](@($hn[0].opt -split ',' | ForEach-Object { [int]$_ } | Sort-Object -Descending)[0]) } }
  return [pscustomobject]@{ codec = ((Fs-XText $x 'videoCodecType') -replace '^H\.?26', 'H.26'); fps = [int]([int](Fs-XText $x 'maxFrameRate') / 100); width = [int](Fs-XText $x 'videoResolutionWidth'); height = [int](Fs-XText $x 'videoResolutionHeight'); bitrate = [int]$br; gop = [int](Fs-XText $x 'GovLength'); smartCodec = $sc; maxWidth = $mw; maxHeight = $mh; raw = $r.body }
}
function Set-FsStream([string]$ip, [string]$brand, $cred, $current, $diff) {
  # applies ONLY the fields in $diff (from Get-FsSettingsDiff). Returns { ok; reboot }
  # 2.2.19 (F19): a field the camera did not report (unknown) is never written; with nothing known to write, nothing is sent
  $diff = @(@($diff) | Where-Object { $_ -and -not ($_.PSObject.Properties['unknown'] -and $_.unknown) })
  if (-not @($diff).Count) { return [pscustomobject]@{ ok = $true; reboot = $false; sent = $false } }
  if ($brand -eq 'Dahua') {
    $p = 'Encode[0].MainFormat[0].Video.'; $kv = @{}; $smart = $null
    foreach ($d in @($diff)) {
      switch ($d.field) {
        'codec' { $kv[$p + 'Compression'] = [string]$d.to; if ([string]$d.to -eq 'H.264') { $kv[$p + 'Profile'] = 'Main' } }
        'fps' { $kv[$p + 'FPS'] = [string]$d.to } 'bitrate' { $kv[$p + 'BitRate'] = [string]$d.to } 'gop' { $kv[$p + 'GOP'] = [string]$d.to }
        'resolution' { $wh = ([string]$d.to) -split 'x'; $kv[$p + 'Width'] = $wh[0]; $kv[$p + 'Height'] = $wh[1] }
        'smartCodec' { $smart = 'false' } 'smartCodecOn' { $smart = 'true' }   # 2.2.7 (F09): Undo turns it back on
      }
    }
    $ok = $true
    if ($smart) { $ok = (Fs-DhSet $ip $cred @{ 'SmartEncode[0].Enable' = $smart }) -and $ok }
    if ($kv.Count) { $ok = (Fs-DhSet $ip $cred $kv) -and $ok }
    return [pscustomobject]@{ ok = $ok; reboot = $false }
  }
  $x = Fs-XmlDoc $current.raw; if (-not $x) { return [pscustomobject]@{ ok = $false; reboot = $false } }
  foreach ($d in @($diff)) {
    switch ($d.field) {
      'codec' { [void](Fs-XSet $x 'videoCodecType' ([string]$d.to)) }
      'fps' { [void](Fs-XSet $x 'maxFrameRate' ([string]([int]$d.to * 100))) }
      'gop' { [void](Fs-XSet $x 'GovLength' ([string]$d.to)) }
      'bitrate' { if ((Fs-XText $x 'videoQualityControlType') -eq 'VBR') { [void](Fs-XSet $x 'vbrUpperCap' ([string]$d.to)) } else { [void](Fs-XSet $x 'constantBitRate' ([string]$d.to)) } }
      'resolution' { $wh = ([string]$d.to) -split 'x'; [void](Fs-XSet $x 'videoResolutionWidth' $wh[0]); [void](Fs-XSet $x 'videoResolutionHeight' $wh[1]) }
      'smartCodec' { $n = @(Fs-XFind $x 'SmartCodec'); if ($n.Count) { [void](Fs-XSet $n[0] 'enabled' 'false') } }
      'smartCodecOn' { $n = @(Fs-XFind $x 'SmartCodec'); if ($n.Count) { [void](Fs-XSet $n[0] 'enabled' 'true') } }   # 2.2.7 (F09)
    }
  }
  $r = Fs-Http -Ip $ip -Method 'PUT' -Path '/ISAPI/Streaming/channels/101' -Body $x.OuterXml -Cred $cred
  return [pscustomobject]@{ ok = (Fs-HikOk $r); reboot = (Fs-HikNeedsReboot $r) }
}

function Restart-FsDevice([string]$ip, [string]$brand, $cred) {
  if ($brand -eq 'Dahua') { $r = Fs-Http -Ip $ip -Path '/cgi-bin/magicBox.cgi?action=reboot' -Cred $cred; return ($r.code -eq 200) }
  $r = Fs-Http -Ip $ip -Method 'PUT' -Path '/ISAPI/System/reboot' -Cred $cred; return (Fs-HikOk $r)
}
function Test-FsPicture([string]$ip, [string]$path, $cred) {
  # a real JPEG back = video is there
  $f = Join-Path ([IO.Path]::GetTempPath()) ('fs-pic-' + [guid]::NewGuid().ToString('N') + '.jpg')
  try {
    $r = Fs-Http -Ip $ip -Path $path -Cred $cred -OutFile $f -Timeout 12
    if (-not (Test-Path $f)) { return $false }
    $b = [IO.File]::ReadAllBytes($f); return ($b.Length -gt 1500 -and $b[0] -eq 0xFF -and $b[1] -eq 0xD8)
  } catch { return $false } finally { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

# ---------------- Hikvision NVR ----------------
# 2.2.15 (Codex 2.2.14 R1): reading an NVR's channel list says whether it WAS read. ok = $true only for an HTTP 200 answer that is a
# real channel list (InputProxyChannelList); a failed or garbled answer is ok = $false with the reason, never "no channels".
# Returns { ok; channels; why }. Get-FsNvrChannels (below) keeps its old shape for the callers that only need the channels.
function Read-FsNvrChannelList([string]$nvrIp, $cred) {
  $r = $null; try { $r = Fs-Http -Ip $nvrIp -Path '/ISAPI/ContentMgmt/InputProxy/channels' -Cred $cred } catch { $r = $null }
  if (-not $r -or [int]$r.code -ne 200) { return [pscustomobject]@{ ok = $false; channels = @(); why = $(if ($r -and [int]$r.code) { 'the NVR answered HTTP ' + $r.code } else { 'the NVR did not answer' }) } }
  $x = Fs-XmlDoc $r.body
  if (-not $x -or -not $x.DocumentElement -or $x.DocumentElement.LocalName -ne 'InputProxyChannelList') { return [pscustomobject]@{ ok = $false; channels = @(); why = 'the NVR answer was not a channel list' } }
  return [pscustomobject]@{ ok = $true; channels = @(Get-FsNvrChannels $nvrIp $cred -Body $r.body); why = '' }
}
function Get-FsNvrChannels([string]$nvrIp, $cred, [string]$Body = '') {
  if ($Body) { $x = Fs-XmlDoc $Body } else { $r = Fs-Http -Ip $nvrIp -Path '/ISAPI/ContentMgmt/InputProxy/channels' -Cred $cred; $x = Fs-XmlDoc $r.body }
  if (-not $x) { return $null }
  $st = Fs-XmlDoc (Fs-Http -Ip $nvrIp -Path '/ISAPI/ContentMgmt/InputProxy/channels/status' -Cred $cred).body
  $on = @{}; foreach ($s in (Fs-XFind $st 'InputProxyChannelStatus')) { $on[[int](Fs-XText $s 'id')] = ((Fs-XText $s 'online') -eq 'true') }
  $out = @()
  foreach ($c in (Fs-XFind $x 'InputProxyChannel')) {
    $id = [int](Fs-XText $c 'id')
    $out += [pscustomobject]@{ channel = $id; name = (Fs-XText $c 'name'); ip = (Fs-XText $c 'ipAddress'); port = (Fs-XText $c 'managePortNo'); protocol = (Fs-XText $c 'proxyProtocol'); online = $(if ($on.ContainsKey($id)) { $on[$id] } else { $null }) }
  }
  return $out
}
# 2.2.10 (Codex R06): is the channel showing a DIFFERENT camera that is live right now? Read just before the change.
# Returns '' (free to change) or the reason it must not be overwritten. A live state that cannot be read counts as "may be live".
function Get-FsNvrChannelGuard([string]$nvrIp, $nvrCred, [int]$ch, [string]$curIp, [string]$camIp, [string[]]$OwnIps = @()) {
  if (-not $curIp -or $curIp -eq $camIp -or @($OwnIps | Where-Object { $_ }) -contains $curIp) { return '' }
  $st = $null; try { $st = Fs-Http -Ip $nvrIp -Path '/ISAPI/ContentMgmt/InputProxy/channels/status' -Cred $nvrCred } catch { $st = $null }
  $online = $null
  $sx = $null; if ($st -and $st.code -eq 200) { $sx = Fs-XmlDoc $st.body }
  if ($sx -and $sx.DocumentElement -and $sx.DocumentElement.LocalName -eq 'InputProxyChannelStatusList') {
    # 2.2.15 (Codex 2.2.14 R3): only an explicit "true" / "false" for THIS channel id counts. A missing, empty or garbled <online>
    # (or no entry for the channel) stays unknown = "may be live", so another camera's channel is never overwritten on a guess.
    foreach ($n in @(Fs-XFind $sx 'InputProxyChannelStatus')) {
      if ([string](Fs-XText $n 'id') -ne [string]$ch) { continue }
      if (-not @(Fs-XFind $n 'online').Count) { continue }
      $ov = ([string](Fs-XText $n 'online')).ToLowerInvariant()
      if ($ov -eq 'true') { $online = $true } elseif ($ov -eq 'false') { if ($null -eq $online) { $online = $false } } else { $online = 'bad' }
    }
    if ($online -is [string]) { $online = $null }   # one garbled entry for the channel = unknown
  }
  if ($online -eq $false) { return '' }
  if ($online) { return ('NVR ' + $nvrIp + ' ch ' + $ch + ' shows another LIVE camera (' + $curIp + '), not ' + $camIp + ': not overwritten. Check which camera belongs on it and set it by hand.') }
  return ('NVR ' + $nvrIp + ' ch ' + $ch + ' points at another camera (' + $curIp + ') and whether it is live could not be read: not overwritten. Check it by hand.')
}
# 2.2.16 (Codex 2.2.15 F4): a 200 answer for one channel must be that channel (root InputProxyChannel, same id). '' = fine.
function Get-FsNvrChannelReadBlock($x, [string]$nvrIp, [int]$ch) {
  if (-not $x -or -not $x.DocumentElement -or $x.DocumentElement.LocalName -ne 'InputProxyChannel') { return ('NVR ' + $nvrIp + ' ch ' + $ch + ': the answer was not a channel, so it is NOT known which camera is on it: not changed. Run it again.') }
  $cid = ''; foreach ($n in @($x.DocumentElement.ChildNodes)) { if ($n.LocalName -eq 'id') { $cid = ([string]$n.InnerText).Trim(); break } }
  if ($cid -and $cid -ne [string]$ch) { return ('NVR ' + $nvrIp + ' ch ' + $ch + ': the NVR answered for channel ' + $cid + ' instead, so it is NOT known which camera is on ch ' + $ch + ': not changed. Run it again.') }
  return ''
}
# 2.2.16 (Codex 2.2.15 F4): how a configured channel addresses its camera. isIp = a plain IPv4 address (type empty or ipaddress) and no
# other address form beside it; hostname / IPv6 / unknown type / no readable address = isIp $false with a plain "how" for the crew.
function Get-FsChannelAddressing($x) {
  $aft = Fs-XText $x 'addressingFormatType'; $ip = Fs-XText $x 'ipAddress'; $hn = Fs-XText $x 'hostName'; $v6 = Fs-XText $x 'ipv6Address'
  $isIp = (($aft -eq '' -or $aft -match '^(?i)ip(address)?$') -and $ip -match '^\d{1,3}(\.\d{1,3}){3}$' -and -not $hn -and -not $v6)
  $how = ''
  if (-not $isIp) {
    if ($hn) { $how = 'by name (' + $hn + ')' }
    elseif ($v6) { $how = 'by IPv6 address (' + $v6 + ')' }
    elseif ($aft -and $aft -notmatch '^(?i)ip(address)?$') { $how = 'with address type "' + $aft + '"' + $(if ($ip) { ' (' + $ip + ')' } else { '' }) }
    elseif ($ip) { $how = 'with an address the tool cannot read (' + $ip + ')' }
    else { $how = 'with no address the tool can read' }
  }
  return [pscustomobject]@{ isIp = $isIp; ip = $(if ($isIp) { $ip } else { '' }); type = $aft; host = $hn; how = $how }
}
function Set-FsNvrChannel([string]$nvrIp, $nvrCred, [int]$ch, [string]$camIp, [string]$camPw, [string]$camBrand, [string]$backupDir = '', [string[]]$OwnIps = @()) {
  # puts the camera on that channel with its new address + the site password. Updates the channel when it exists, adds it when not.
  # returns { ok; action ('updated'|'added'|'refused'|'failed'); before (xml, no password: the NVR never returns it); why }
  # $OwnIps: other addresses of THIS camera (Undo: its address after the run) - the channel may be moved off them
  $r = Fs-Http -Ip $nvrIp -Path ('/ISAPI/ContentMgmt/InputProxy/channels/' + $ch) -Cred $nvrCred
  $proto = $(if ($camBrand -eq 'Hikvision') { 'HIKVISION' } else { 'ONVIF' }); $port = $(if ($proto -eq 'HIKVISION') { '8000' } else { '80' })
  # 2.2.16 (Codex 2.2.15 F4): a channel the NVR answers for must be READ before it is written. Only "not there" (404) means add it.
  # An answer that is not this channel, or any other failed read, = refuse (a working camera could be on it).
  $x = $null; if ($r -and $r.code -eq 200) { $x = Fs-XmlDoc $r.body }
  if ($r -and $r.code -eq 200) {
    $whyR = Get-FsNvrChannelReadBlock $x $nvrIp $ch
    if ($whyR) { Fs-LogLine $whyR; return [pscustomobject]@{ ok = $false; action = 'refused'; before = ''; protocol = $proto; why = $whyR } }
  } elseif (-not $r -or $r.code -ne 404) {
    $whyR = ('NVR ' + $nvrIp + ' ch ' + $ch + ' could not be read (answer ' + $(if ($r) { [string]$r.code } else { 'none' }) + '), so it is NOT known which camera is on it: not changed. Run it again.')
    Fs-LogLine $whyR; return [pscustomobject]@{ ok = $false; action = 'refused'; before = ''; protocol = $proto; why = $whyR }
  }
  if ($x) {
    # 2.2.16 (Codex 2.2.15 F4): check HOW the configured camera is addressed (hostname, IPv6, odd type), not only <ipAddress>.
    # Only a plain IPv4 address can be checked against the camera and the NVR's live status; anything else is NOT a free slot.
    $ad = Get-FsChannelAddressing $x
    if (-not $ad.isIp) {
      $why = ('NVR ' + $nvrIp + ' ch ' + $ch + ' is already set up ' + $ad.how + '. The tool can only check cameras added by IP address, so it is NOT known whether that camera is working: not changed (a working camera could lose its recording). Check channel ' + $ch + ' in the NVR by hand.')
      Fs-LogLine $why; return [pscustomobject]@{ ok = $false; action = 'refused'; before = ''; protocol = $proto; why = $why }
    }
    $why = Get-FsNvrChannelGuard $nvrIp $nvrCred $ch ([string]$ad.ip) $camIp $OwnIps
    if ($why) { Fs-LogLine $why; return [pscustomobject]@{ ok = $false; action = 'refused'; before = ''; protocol = $proto; why = $why } }
    # 2.2.1: the FIRST state of the channel in this run is kept (a second change in the same run must not overwrite it: undo uses it)
    if ($backupDir) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null; $bkf = Join-Path $backupDir ('nvr-' + $nvrIp + '-ch' + $ch + '.xml'); if (-not (Test-Path -LiteralPath $bkf)) { [IO.File]::WriteAllText($bkf, $r.body) } }
    $before = $r.body
    $cur = Fs-XText $x 'proxyProtocol'; if ($cur) { $proto = $cur; $port = Fs-XText $x 'managePortNo' }
    [void](Fs-XSet $x 'ipAddress' $camIp); [void](Fs-XSet $x 'userName' 'admin')
    # 2.1.0: a plug-and-play (PoE port) channel ignores a new address until it is switched to manual (3 Hewlett, ch1)
    if ((Fs-XText $x 'connMode') -eq 'plugplay') { [void](Fs-XSet $x 'connMode' 'manual') }
    if (-not (Fs-XSet $x 'password' $camPw)) {
      $sd = @(Fs-XFind $x 'sourceInputPortDescriptor')[0]; if ($sd) { $e = $x.CreateElement('password', $sd.NamespaceURI); $e.InnerText = $camPw; [void]$sd.AppendChild($e) }
    }
    $w = Fs-HttpSecret -Ip $nvrIp -Method 'PUT' -Path ('/ISAPI/ContentMgmt/InputProxy/channels/' + $ch) -Body $x.OuterXml -Cred $nvrCred
    return [pscustomobject]@{ ok = (Fs-HikOk $w); action = 'updated'; before = $before; protocol = $proto }
  }
  $xml = '<?xml version="1.0" encoding="UTF-8"?><InputProxyChannel version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema"><id>' + $ch + '</id><sourceInputPortDescriptor><proxyProtocol>' + $proto + '</proxyProtocol><addressingFormatType>ipaddress</addressingFormatType><ipAddress>' + $camIp + '</ipAddress><managePortNo>' + $port + '</managePortNo><srcInputPort>1</srcInputPort><userName>admin</userName><password>' + (Fs-Xml $camPw) + '</password><streamType>auto</streamType></sourceInputPortDescriptor></InputProxyChannel>'
  $w = Fs-HttpSecret -Ip $nvrIp -Method 'POST' -Path '/ISAPI/ContentMgmt/InputProxy/channels' -Body $xml -Cred $nvrCred
  return [pscustomobject]@{ ok = (Fs-HikOk $w); action = 'added'; before = ''; protocol = $proto }
}
# 2.2.1 (review H8): undo puts the channel back EXACTLY as the backup has it (address, port, protocol, plug-and-play mode, name),
# with the camera's password added (the NVR never hands its copy out, so the backup has none). A channel the run ADDED is deleted.
function Restore-FsNvrChannel([string]$nvrIp, $nvrCred, [int]$ch, [string]$beforeXml, [string]$camPw) {
  $x = Fs-XmlDoc $beforeXml; if (-not $x) { return [pscustomobject]@{ ok = $false; why = 'the saved channel file is unreadable' } }
  if ($camPw) {
    if (-not (Fs-XSet $x 'password' $camPw)) { $sd = @(Fs-XFind $x 'sourceInputPortDescriptor')[0]; if ($sd) { $e = $x.CreateElement('password', $sd.NamespaceURI); $e.InnerText = $camPw; [void]$sd.AppendChild($e) } }
  }
  $w = Fs-HttpSecret -Ip $nvrIp -Method 'PUT' -Path ('/ISAPI/ContentMgmt/InputProxy/channels/' + $ch) -Body $x.OuterXml -Cred $nvrCred
  return [pscustomobject]@{ ok = (Fs-HikOk $w); why = $(if (Fs-HikOk $w) { '' } else { 'the NVR refused the saved channel (HTTP ' + $w.code + ')' }) }
}
# 2.2.14 (Codex 2.2.13 F8): the camera address a saved channel file names ('' = none / unreadable)
function Get-FsChannelXmlIp([string]$xml) { $x = Fs-XmlDoc $xml; if (-not $x) { return '' }; $n = @(Fs-XFind $x 'ipAddress'); if ($n.Count -and $n[0]) { return ([string]$n[0].InnerText).Trim() }; return '' }
function Get-FsChannelXmlBrand([string]$xml, [string]$default) { $x = Fs-XmlDoc $xml; $n = @(Fs-XFind $x 'proxyProtocol'); if ($n.Count -and $n[0]) { $p = ([string]$n[0].InnerText).Trim().ToUpper(); if ($p -eq 'HIKVISION') { return 'Hikvision' }; if ($p -eq 'DAHUA') { return 'Dahua' } }; return $default }
# 2.2.14 (Codex 2.2.13 F8): Undo puts an NVR channel back from its saved copy and calls it back ONLY when the NVR shows video on it
# again from the camera the saved copy names. The saved copy has no password (the NVR never hands it out):
#  - the saved channel is THIS camera ($OwnIps): its own current password goes in, as before;
#  - it is a DIFFERENT camera (the run replaced an offline one): the replacement's password is NEVER put in. A password that logs in
#    to THAT camera ($OrigCands: the site password, ones saved at this site) is used; none = the address/settings go back without a
#    password and the line says the password is NOT confirmed (put it in the NVR by hand) - never "back exactly as it was".
# An accepted write alone is never "back". Returns ok ($true only with video), text, manual ($true = needs a person).
function Restore-FsUndoChannel([string]$nvrIp, $nvrCred, [int]$ch, [string]$beforeXml, [string[]]$OwnIps, [string]$camPw, [string]$camBrand, [string[]]$OrigCands, [int]$WaitSec = 60) {
  $origIp = Get-FsChannelXmlIp $beforeXml
  if (-not (Fs-XmlDoc $beforeXml)) { return [pscustomobject]@{ ok = $false; manual = $true; text = ('NVR ch ' + $ch + ': the saved channel file is unreadable - put it back by hand') } }
  $own = @($OwnIps | Where-Object { $_ })
  $same = (-not $origIp) -or ($own -contains $origIp)
  $useIp = $(if ($origIp) { $origIp } else { [string]@($own)[0] })
  $brand = Get-FsChannelXmlBrand $beforeXml $camBrand
  $usePw = ''; $known = $false
  if ($same) { $usePw = $camPw; $known = [bool]$camPw }
  else { foreach ($cand in @($OrigCands | Where-Object { $_ } | Select-Object -Unique)) { if ((Test-FsLogin $origIp $brand $cand) -eq 'ok') { $usePw = $cand; $known = $true; break } } }
  $w = Restore-FsNvrChannel $nvrIp $nvrCred $ch $beforeXml $usePw
  if (-not $w.ok) { return [pscustomobject]@{ ok = $false; manual = $true; text = ('NVR ch ' + $ch + ': ' + [string]$w.why + ' - put it back by hand') } }
  if ($same -and $origIp -and $own.Count -and [string]$own[0] -ne $origIp) {
    # the saved channel looks for an address this camera is no longer on (it had no video there before the run either): back =
    # the NVR reads the channel back with that address; no video is claimed
    $rb = @(Get-FsNvrChannels $nvrIp $nvrCred | Where-Object { [int]$_.channel -eq $ch })
    if ($rb.Count -and [string]$rb[0].ip -eq $origIp) { return [pscustomobject]@{ ok = $true; manual = $false; text = ('NVR ch ' + $ch + ' back exactly as it was (it looks for ' + $origIp + ', as before the run; this camera is on ' + $own[0] + ', so no video there)') } }
    return [pscustomobject]@{ ok = $false; manual = $true; text = ('NVR ch ' + $ch + ': put back, but the NVR does not read it back as it was - NOT confirmed, check ch ' + $ch + ' in the NVR') }
  }
  if (-not $known) {
    return [pscustomobject]@{ ok = $false; manual = $true; text = ('NVR ch ' + $ch + ': address back to ' + $useIp + ', but its password is NOT confirmed (that camera''s own password is not known here) - put this camera''s password in the NVR by hand') }
  }
  $end = (Get-Date).AddSeconds($WaitSec); $vid = $false
  do { $vid = Test-FsVideo $nvrIp $nvrCred $ch $useIp $brand (Fs-Cred $usePw); if (-not $vid) { Start-Sleep -Seconds 2 } } while (-not $vid -and (Get-Date) -lt $end)
  if ($vid) { return [pscustomobject]@{ ok = $true; manual = $false; text = ('NVR ch ' + $ch + ' back exactly as it was' + $(if (-not $same) { ' (camera ' + $useIp + ', its own password checked)' } else { '' }) + ', video back') } }
  return [pscustomobject]@{ ok = $false; manual = $true; text = ('NVR ch ' + $ch + ' put back to ' + $useIp + ', but NO video on it - NOT confirmed, check ch ' + $ch + ' in the NVR') }
}
function Remove-FsNvrChannel([string]$nvrIp, $nvrCred, [int]$ch) {
  $w = Fs-Http -Ip $nvrIp -Method 'DELETE' -Path ('/ISAPI/ContentMgmt/InputProxy/channels/' + $ch) -Cred $nvrCred
  return (Fs-HikOk $w)
}
# 2.2.18 (Codex F2): before Undo deletes or puts back an NVR channel: WHICH camera is on that channel NOW? Read fresh, just before the
# write. Undo may only touch it while it still points at THIS camera (an address this run gave it: $OwnIps). Another camera on it, a
# channel set up by name / IPv6, or an answer that cannot be read = Undo leaves it alone (the other camera keeps recording).
# 2.2.19 (Codex 2.2.18 F01): "points at one of this camera's addresses" is not ownership: another camera may have taken that address
# since the run. 'mine' now needs PROOF, read fresh: the device answering at the channel's address logs in on this camera's password
# and tells this camera's MAC (serial only when the undo file has no MAC). A login that is refused, locked, times out or cannot be
# read, an identity that cannot be read, or no saved MAC / serial = 'unread' (NOT checked, nothing written). The one other proof:
# nothing at all answers at that address (checked live) AND this camera was just identified by its MAC at $CamIp, a different
# address = the channel holds this camera's old address and no other device uses it.
# 2.2.19 (Codex 2.2.18 F01): a channel already showing the address the saved copy names ($AlsoOk, not one of this camera's own) is
# 'saved' - Undo writes nothing to it (that camera's identity is not known here); the caller only checks its video.
# -ReadBack: only for reading a channel back right AFTER Undo wrote it (no write follows): 'mine' = it points at one of $OwnIps.
# Returns { state ('mine'|'gone'|'other'|'unread'|'saved'); ip; why }. 'gone' = the NVR says there is no such channel (HTTP 404).
function Get-FsUndoChannelOwner([string]$nvrIp, $nvrCred, [int]$ch, [string[]]$OwnIps, [string[]]$AlsoOk = @(), [string]$CamIp = '', [string]$Brand = 'Hikvision', [string]$Pw = '', [string]$Mac = '', [string]$Serial = '', [switch]$ReadBack) {
  $r = $null; try { $r = Fs-Http -Ip $nvrIp -Path ('/ISAPI/ContentMgmt/InputProxy/channels/' + $ch) -Cred $nvrCred } catch { $r = $null }
  if ($r -and [int]$r.code -eq 404) { return [pscustomobject]@{ state = 'gone'; ip = ''; why = ('NVR ' + $nvrIp + ' has no ch ' + $ch + ' now') } }
  if (-not $r -or [int]$r.code -ne 200) { return [pscustomobject]@{ state = 'unread'; ip = ''; why = ('NVR ' + $nvrIp + ' ch ' + $ch + ' could not be read now (answer ' + $(if ($r -and [int]$r.code) { [string]$r.code } else { 'none' }) + '), so it is NOT known which camera is on it') } }
  $x = Fs-XmlDoc $r.body
  $whyR = Get-FsNvrChannelReadBlock $x $nvrIp $ch; if ($whyR) { return [pscustomobject]@{ state = 'unread'; ip = ''; why = $whyR } }
  $ad = Get-FsChannelAddressing $x
  if (-not $ad.isIp) { return [pscustomobject]@{ state = 'other'; ip = ''; why = ('NVR ' + $nvrIp + ' ch ' + $ch + ' is now set up ' + $ad.how + ', not with this camera''s address') } }
  $own = @($OwnIps | Where-Object { $_ } | ForEach-Object { ([string]$_) -replace ':\d+$', '' })
  $also = @($AlsoOk | Where-Object { $_ } | ForEach-Object { ([string]$_) -replace ':\d+$', '' })
  if (-not ($own -contains $ad.ip)) {
    if ($also -contains $ad.ip) { return [pscustomobject]@{ state = 'saved'; ip = $ad.ip; why = ('NVR ' + $nvrIp + ' ch ' + $ch + ' already shows ' + $ad.ip + ', the camera its saved copy names') } }
    return [pscustomobject]@{ state = 'other'; ip = $ad.ip; why = ('NVR ' + $nvrIp + ' ch ' + $ch + ' now shows ANOTHER camera (' + $ad.ip + '), not this one (' + (($own | Select-Object -Unique) -join ' / ') + ')') }
  }
  if ($ReadBack) { return [pscustomobject]@{ state = 'mine'; ip = $ad.ip; why = '' } }
  $pre = 'NVR ' + $nvrIp + ' ch ' + $ch + ' points at ' + $ad.ip + ', but it is NOT confirmed that this camera is there: '
  if (-not $Mac -and -not $Serial) { return [pscustomobject]@{ state = 'unread'; ip = $ad.ip; why = ($pre + 'the undo file has no MAC or serial for this camera') } }
  $st = $(if ($Pw) { Test-FsLogin $ad.ip $Brand $Pw } else { 'nopw' })
  if ($st -eq 'ok') {
    $idw = Get-FsUndoIdentityBlock $ad.ip $Brand (Fs-Cred $Pw) $Mac $Serial
    if (-not $idw) { return [pscustomobject]@{ state = 'mine'; ip = $ad.ip; why = '' } }
    if ($idw -like '*ANOTHER device*') { return [pscustomobject]@{ state = 'other'; ip = $ad.ip; why = ('NVR ' + $nvrIp + ' ch ' + $ch + ' points at ' + $ad.ip + ', and ' + $idw) } }
    return [pscustomobject]@{ state = 'unread'; ip = $ad.ip; why = ($pre + $idw) }
  }
  $camIpN = ([string]$CamIp) -replace ':\d+$', ''
  if ($st -eq 'noanswer' -and $camIpN -and $camIpN -ne $ad.ip -and $Pw) {
    $free = $false; try { $free = [bool](Test-FsIpFree $ad.ip) } catch { $free = $false }
    if ($free -and (Test-FsLogin $camIpN $Brand $Pw) -eq 'ok' -and -not (Get-FsUndoIdentityBlock $camIpN $Brand (Fs-Cred $Pw) $Mac $Serial)) { return [pscustomobject]@{ state = 'mine'; ip = $ad.ip; why = '' } }
  }
  $how = $(switch ($st) { 'nopw' { 'no working password for this camera is known here' } 'noanswer' { 'nothing answers there and this camera was not found on another address' } 'refused' { 'the device there does not take this camera''s password - it may be ANOTHER camera' } 'locked' { 'the device there is locked after wrong passwords' } default { 'the device there could not be signed in to (' + $st + ')' } })
  return [pscustomobject]@{ state = 'unread'; ip = $ad.ip; why = ($pre + $how) }
}
function Test-FsVideo([string]$nvrIp, $nvrCred, [int]$ch, [string]$camIp, [string]$camBrand, $camCred) {
  # video is back = NVR says the channel is online AND hands out a picture of it (or, with no NVR, the camera itself does)
  if ($nvrIp -and $ch -gt 0) {
    $chs = @(Get-FsNvrChannels $nvrIp $nvrCred); $c = $chs | Where-Object { $_.channel -eq $ch } | Select-Object -First 1
    if (-not $c -or $c.online -ne $true) { return $false }
    # 2.2.3 (Codex #16): the channel must point at THIS camera; an online ch 5 showing another camera is not this camera's video
    if ($camIp -and [string]$c.ip -ne ($camIp -replace ':\d+$', '')) { return $false }
    # 2.1.0: some NVRs (ERI-K108-P8, seen at 3 Hewlett) only hand the picture out on the StreamingProxy path: try both
    if (Test-FsPicture $nvrIp ('/ISAPI/Streaming/channels/' + $ch + '01/picture') $nvrCred) { return $true }
    return (Test-FsPicture $nvrIp ('/ISAPI/ContentMgmt/StreamingProxy/channels/' + $ch + '01/picture') $nvrCred)
  }
  if ($camBrand -eq 'Dahua') { return (Test-FsPicture $camIp '/cgi-bin/snapshot.cgi?channel=1' $camCred) }
  return (Test-FsPicture $camIp '/ISAPI/Streaming/channels/101/picture' $camCred)
}

# ---------------- this PC: which network adapter, and a temporary extra address to reach a camera on the wrong scheme ----------------
# 2.2.1 (review H9): the adapter's REAL prefix and mask (not always /24), and every usable adapter is listed so the tech can pick the
# camera network when the PC is on two (Wi-Fi for internet + Ethernet for the cameras).
# 2.2.1 (review H4): before the first temporary address, this PC's adapter settings are saved (DHCP on/off, DHCP+static coexistence,
# its own addresses, its default gateway) in fixsite-runs\_state; they are put back at the end - also after a crash (next start, and the
# "Fix this site" task's own finally) - and the saved state is only deleted once everything checked back to normal.
$script:FsTemps = New-Object System.Collections.ArrayList
$script:FsPcBefore = $null        # the adapter as it was before the first temporary address (null = nothing changed yet)
$script:FsCoexistChanged = $false
$script:FsNetOps = $null          # TESTS ONLY: a hashtable of scriptblocks standing in for Windows' network commands (see Invoke-FsNetOp)
$script:FsLastRestore = $null     # { ok; problems } of the last Restore-FsPcNet
$script:FsNetBlocked = $null      # 2.2.10 (Codex R03): why no adapter change may happen in this run (an unreadable journal)
# 2.2.19 (F08): $true when a failed Windows network query only means "there is none" (no address / no route), not a failed read
function Test-FsNoneFound($err) {
  try { if ([string]$err.CategoryInfo.Category -eq 'ObjectNotFound') { return $true } } catch {}
  try { if ($err.Exception -and $err.Exception.GetType().Name -eq 'CimException' -and [string]$err.Exception.NativeErrorCode -eq 'NotFound') { return $true } } catch {}
  return $false
}
function Invoke-FsNetOp([string]$op, [hashtable]$a) {
  if ($script:FsNetOps -and $script:FsNetOps.ContainsKey($op)) { return (& $script:FsNetOps[$op] $a) }
  $ix = [int]$a.ifIndex
  switch ($op) {
    'state' {
      # 2.2.19 (Codex 2.2.18 F08): every query's success is tracked on its own ($unread names what could not be read). A query that
      # FAILS is not "no addresses" / "no router": 2.2.18 read SilentlyContinue's empty answer as proof a temporary address was gone.
      # Windows answers "no matching object" (ObjectNotFound) when there really is none: that one is a real empty answer.
      $unread = @()
      $ipi = $null; try { $ipi = Get-NetIPInterface -InterfaceIndex $ix -AddressFamily IPv4 -ErrorAction Stop } catch { $unread += 'the DHCP setting' }
      if (-not $ipi -and -not ($unread -contains 'the DHCP setting')) { $unread += 'the DHCP setting' }
      $co = 'unknown'; try { $t = (netsh interface ipv4 show interface ([string]$ix)) -join "`n"; $m = [regex]::Match($t, '(?i)DHCP/Static IP coexistence\s*:\s*(\w+)'); if ($m.Success) { $co = $m.Groups[1].Value.ToLower() } } catch {}
      $ad = @(); try { $ad = @(Get-NetIPAddress -InterfaceIndex $ix -AddressFamily IPv4 -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ ip = [string]$_.IPAddress; prefix = [int]$_.PrefixLength; origin = [string]$_.PrefixOrigin; skip = [bool]$_.SkipAsSource; store = [string]$_.PolicyStore; addrState = [string]$_.AddressState } }) } catch { if (-not (Test-FsNoneFound $_)) { $unread += 'the addresses' } }
      $gw = @(); try { $gw = @(Get-NetRoute -InterfaceIndex $ix -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction Stop | ForEach-Object { [string]$_.NextHop } | Select-Object -Unique) } catch { if (-not (Test-FsNoneFound $_)) { $unread += 'the router (default route)' } }
      return [pscustomobject]@{ dhcp = ($ipi -and [string]$ipi.Dhcp -eq 'Enabled'); coexist = $co; addrs = $ad; gw = $gw; unread = @($unread) }
    }
    # 2.2.19 (Codex 2.2.18 F05): which adapter is at this number right now (name + its InterfaceGuid, which never changes); $null = unread
    'ident' { try { $n = @(Get-NetAdapter -InterfaceIndex $ix -ErrorAction Stop)[0]; if (-not $n) { return $null }; return [pscustomobject]@{ name = [string]$n.Name; guid = [string]$n.InterfaceGuid } } catch { return $null } }
    # 2.2.19 (decision: a positive check of the actual state): every connected adapter, each with a full state read; $null = unread
    'allstate' {
      try {
        $l = @()
        foreach ($n in @(Get-NetAdapter -ErrorAction Stop | Where-Object { [string]$_.Status -eq 'Up' })) { $l += [pscustomobject]@{ name = [string]$n.Name; ifIndex = [int]$n.ifIndex; state = (Invoke-FsNetOp 'state' @{ ifIndex = [int]$n.ifIndex }) } }
        return [pscustomobject]@{ adapters = $l }
      } catch { return $null }
    }
    'coexist' { $null = netsh interface ipv4 set interface ([string]$ix) ('dhcpstaticipcoexistence=' + $(if ($a.on) { 'enabled' } else { 'disabled' })); return ($LASTEXITCODE -eq 0) }
    'dhcp' { Set-NetIPInterface -InterfaceIndex $ix -AddressFamily IPv4 -Dhcp $(if ($a.on) { 'Enabled' } else { 'Disabled' }) -ErrorAction Stop; return $true }
    'addtemp' {
      New-NetIPAddress -InterfaceIndex $ix -IPAddress $a.ip -PrefixLength ([int]$a.prefix) -SkipAsSource $true -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
      $st = 'Tentative'; for ($w = 0; $w -lt 8 -and $st -eq 'Tentative'; $w++) { Start-Sleep -Seconds 1; $st = [string](Get-NetIPAddress -InterfaceIndex $ix -IPAddress $a.ip -ErrorAction SilentlyContinue).AddressState }
      return $st
    }
    'remove' { Remove-NetIPAddress -IPAddress $a.ip -InterfaceIndex $ix -Confirm:$false -ErrorAction SilentlyContinue; Remove-NetIPAddress -IPAddress $a.ip -InterfaceIndex $ix -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue; return $true }
    'addstatic' {
      $p = @{ InterfaceIndex = $ix; IPAddress = $a.ip; PrefixLength = [int]$a.prefix; ErrorAction = 'Stop' }; if ($a.gw) { $p.DefaultGateway = $a.gw }
      New-NetIPAddress @p | Out-Null; return $true
    }
    'addroute' { New-NetRoute -InterfaceIndex $ix -DestinationPrefix '0.0.0.0/0' -NextHop $a.gw -ErrorAction Stop | Out-Null; return $true }
    'renew' { if ($a.name) { $null = & ipconfig.exe /renew ([string]$a.name) 2>&1 }; return $true }   # 2.2.2 (H4): ask DHCP for the address now
    # 2.2.18 (Codex F5): for the verified-recovery check: when Windows last started (UTC), and every "skip as source" IPv4 address now
    'boottime' { try { return ([datetime](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime).ToUniversalTime() } catch { try { $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop; return ([Management.ManagementDateTimeConverter]::ToDateTime([string]$os.LastBootUpTime)).ToUniversalTime() } catch { return $null } } }
    'skipaddrs' { try { $l = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.SkipAsSource -eq $true -and [string]$_.IPAddress -notlike '169.254.*' } | ForEach-Object { [string]$_.IPAddress }); return [pscustomobject]@{ ips = $l } } catch { return $null } }
  }
  return $null
}
function Get-FsPcNets {
  # every adapter this PC could reach the cameras on: up, IPv4, not a VPN/virtual one. Sorted: the internet one (lowest route metric) first.
  if ($script:FsNetOps -and $script:FsNetOps.ContainsKey('adapters')) { $l = @(& $script:FsNetOps['adapters'] @{}) }
  elseif ($script:FsMockUrl) {
    $r = Fs-Http -Ip '_pc' -Path '/net'; $o = $r.body | ConvertFrom-Json; $l = @()
    foreach ($x in @($o)) { $pre = 24; if ($x.PSObject.Properties['prefix'] -and [int]$x.prefix) { $pre = [int]$x.prefix }; $l += [pscustomobject]@{ ip = [string]$x.ip; prefix = $pre; mask = (ConvertTo-FsMask $pre); gw = [string]$x.gw; ifIndex = $(if ($x.PSObject.Properties['ifIndex']) { [int]$x.ifIndex } else { 0 }); dhcp = [bool]$x.dhcp; name = $(if ($x.PSObject.Properties['name']) { [string]$x.name } else { 'Ethernet' }); metric = 0 } }
  } else {
    $l = @()
    foreach ($ad in @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Tailscale|WireGuard|TAP|VPN|Cellular|Mobile Broadband|Hyper-V|Loopback' })) {
      # 2.2.2 (re-review H9): an adapter with ONLY a 169.254 address (an isolated camera switch with no DHCP) is listed too
      $aa = @(Get-NetIPAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.SkipAsSource -ne $true })
      $a = @($aa | Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1)[0]; if (-not $a) { $a = @($aa | Select-Object -First 1)[0] }
      if (-not $a) { continue }
      $rt = Get-NetRoute -InterfaceIndex $ad.ifIndex -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
      $ipi = Get-NetIPInterface -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
      $l += [pscustomobject]@{ ip = [string]$a.IPAddress; prefix = [int]$a.PrefixLength; mask = (ConvertTo-FsMask ([int]$a.PrefixLength)); gw = $(if ($rt) { [string]$rt.NextHop } else { '' }); ifIndex = [int]$ad.ifIndex; dhcp = ($ipi -and [string]$ipi.Dhcp -eq 'Enabled'); name = [string]$ad.Name; metric = $(if ($rt) { [int]$rt.RouteMetric + [int]$ipi.InterfaceMetric } else { 99999 }) }
    }
  }
  return @($l | Where-Object { $_.ip } | Sort-Object @{ Expression = { if ($_.gw) { 0 } else { 1 } } }, metric)
}
function Get-FsPcNet([int]$IfIndex = -1) {
  $all = @(Get-FsPcNets)
  if ($IfIndex -ge 0) { $m = @($all | Where-Object { [int]$_.ifIndex -eq $IfIndex })[0]; if ($m) { return $m } }
  $g = @($all | Where-Object { $_.gw })[0]; if ($g) { return $g }
  # 2.2.2 (re-review H9): no adapter has a router (an isolated camera switch): the one adapter there is
  $o = @($all)[0]; if ($o) { return $o }
  return $null
}
function Test-FsLinkLocal([string]$ip) { return ([string]$ip -like '169.254.*') }
# 2.2.2 (re-review H9): the mask and router written to a device that is moved. The PC's own when it is on the site network with a
# router; on an isolated camera switch (no router, or only a 169.254 address) the WireIt standard: /24 and router .1 on the scheme.
function Get-FsDeviceNet($pc, [string]$scheme) {
  $mask = '255.255.255.0'; $gw = $(if ($scheme) { $scheme + '.1' } else { '' })
  if ($pc -and -not (Test-FsLinkLocal ([string]$pc.ip)) -and $pc.mask -and (Get-FsP3 ([string]$pc.ip)) -eq $scheme) { $mask = [string]$pc.mask }
  if ($pc -and $pc.gw) { $gw = [string]$pc.gw }
  return [pscustomobject]@{ mask = $mask; gw = $gw }
}
# the words for the "which network are the cameras on?" question (one line per adapter)
function Format-FsPcNetChoice($nets) { $i = 0; return @($nets | ForEach-Object { $i++; '' + $i + ' = ' + $_.name + ' (this PC ' + $_.ip + '/' + $_.prefix + $(if ($_.gw) { ', router ' + $_.gw } elseif (Test-FsLinkLocal ([string]$_.ip)) { ', no router, no DHCP address' } else { ', no router' }) + ')' }) }
function Select-FsPcNet($nets, [string]$answer) {
  # Enter = the first one (the internet one); a number picks that line; anything else = $null (asked again)
  $nets = @($nets); if (-not $nets.Count) { return $null }
  $a = ([string]$answer).Trim(); if (-not $a) { return $nets[0] }
  if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $nets.Count) { return $nets[[int]$a - 1] }
  return $null
}
# 2.2.20 (Codex 2.2.19 R04): $true ONLY from a readable "nobody there": no ping answer AND a neighbour-table read that worked and has
# no live entry (Windows' "no matching MSFT_NetNeighbor" = no entry = readable empty). A neighbour read that fails any other way is
# UNKNOWN = not free ($script:FsIpFreeWhy says why), the same as the classic Test-IpFree since 2.2.19. 2.2.19 read every neighbour
# error as "free", so a camera / NVR could be moved onto an occupied address that does not answer ping (forward and Undo gates).
$script:FsIpFreeWhy = ''
function Test-FsIpFree([string]$ip) {
  $script:FsIpFreeWhy = ''
  if ($script:FsNetOps -and $script:FsNetOps.ContainsKey('free')) { return [bool](& $script:FsNetOps['free'] @{ ip = $ip }) }
  if ($script:FsMockUrl) {
    $r = Fs-Http -Ip '_pc' -Path ('/free?ip=' + $ip)
    if (-not $r -or [int]$r.code -ne 200 -or [string]$r.body -notmatch '(?i)\b(true|false)\b') { $script:FsIpFreeWhy = 'the check whether ' + $ip + ' is free got no answer'; return $false }
    return ([string]$r.body -match '(?i)\btrue\b')
  }
  for ($k = 0; $k -lt 2; $k++) { try { if ((New-Object Net.NetworkInformation.Ping).Send($ip, 700).Status -eq 'Success') { return $false } } catch {} }
  $n = $null
  try { $n = @(Get-NetNeighbor -IPAddress $ip -ErrorAction Stop | Where-Object { $_.State -in @('Reachable', 'Stale', 'Permanent') -and $_.LinkLayerAddress -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' }) }
  catch {
    if ([string]$_.CategoryInfo.Category -ne 'ObjectNotFound' -and $_.Exception.Message -notmatch '(?i)No matching MSFT_NetNeighbor') {
      $script:FsIpFreeWhy = ('this PC''s neighbour table could not be read for ' + $ip + ' (' + $_.Exception.Message + '), so it is not known whether a device uses that address')
      Fs-LogLine $script:FsIpFreeWhy; return $false
    }
    $n = @()
  }
  return (-not @($n).Count)
}
function Save-FsNetState([string]$stateFile) {
  if (-not $stateFile) { return }
  $o = [ordered]@{ version = 2; written = (Get-Date -Format 's'); before = $script:FsPcBefore; coexistChanged = [bool]$script:FsCoexistChanged; temps = @($script:FsTemps) }
  # 2.2.20 (Codex 2.2.19 R01): terminating + read back; the callers stop before ANY adapter change when this throws
  Save-FsRecordVerified $stateFile ($o | ConvertTo-Json -Depth 6)
}
# 2.2.19 (Codex 2.2.18 F05/F08): '' when this state read is complete, else what could not be read (plain words).
# $null (the "nothing came back" answer) is a failed read too. A read that lists what it could not read ('unread') is incomplete.
function Get-FsNetReadProblem($st) {
  if ($null -eq $st) { return 'this PC''s network settings could not be read back' }
  if ($st.PSObject.Properties['unread'] -and @($st.unread | Where-Object { $_ }).Count) { return ('this PC''s network settings could not be fully read back (' + (@($st.unread | Where-Object { $_ }) -join ', ') + ')') }
  if (-not $st.PSObject.Properties['addrs']) { return 'this PC''s network settings could not be read back (no address list came back)' }
  return ''
}
# 2.2.19 (Codex 2.2.18 F05): '' when the adapter at the saved number is positively the saved one, else why not (plain words).
# The saved adapter = its InterfaceGuid (it never changes, also when the adapter is renamed or another one takes its number) AND
# its name. A record from before 2.2.19 has no GUID: then the name must match exactly, and the log says it was matched by name only.
# Read FRESH every time it is asked (right before each change), never from an earlier answer.
function Get-FsPcAdapterIdProblem($b, [int]$ix) {
  if (-not $b) { return 'the record does not say which adapter it was (no adapter name), so nothing on this PC''s network is changed' }
  $want = [string]$b.name; $wantG = $(if ($b.PSObject.Properties['guid']) { [string]$b.guid } else { '' })
  if (-not $want) { return 'the record does not say which adapter it was (no adapter name), so nothing on this PC''s network is changed' }
  $id = $null; try { $id = Invoke-FsNetOp 'ident' @{ ifIndex = $ix } } catch { $id = $null }
  if (-not $id -or -not [string]$id.name) { return ('it could not be read which adapter is number ' + $ix + ' now (it should be "' + $want + '"), so nothing on it was changed') }
  $gotG = $(if ($id.PSObject.Properties['guid']) { [string]$id.guid } else { '' })
  if ($wantG) {
    if (-not $gotG) { return ('the ID of adapter number ' + $ix + ' could not be read (it should be "' + $want + '"), so nothing on it was changed') }
    if ($gotG.Trim('{}').ToLower() -ne $wantG.Trim('{}').ToLower()) { return ('adapter number ' + $ix + ' is now another adapter ("' + [string]$id.name + '", not "' + $want + '"), so nothing on it was changed') }
  }
  if ([string]$id.name -ne $want) { return ('adapter number ' + $ix + ' is now "' + [string]$id.name + '", not "' + $want + '", so nothing on it was changed') }
  if (-not $wantG -and -not $script:FsIdNameOnlySaid) { $script:FsIdNameOnlySaid = $true; Fs-LogLine ('the network record has no adapter ID (older Toolkit): adapter "' + $want + '" matched by its name only') }
  return ''
}
$script:FsIdNameOnlySaid = $false
# a change to this PC's adapter during recovery: the adapter is identified again right before it, the change is refused otherwise
function Invoke-FsNetFix([string]$op, [hashtable]$a) {
  $w = Get-FsPcAdapterIdProblem $script:FsPcBefore ([int]$a.ifIndex)
  if ($w) { throw $w }
  return (Invoke-FsNetOp $op $a)
}
function Add-FsTempIp([string]$p3, $pc, [string]$stateFile) {
  # memory-only (ActiveStore) extra address on the old scheme; never used as a source for normal traffic; removed at the end
  foreach ($t in $script:FsTemps) { if ($t.p3 -eq $p3) { return $t.ip } }
  if ($script:FsMockUrl -and -not $script:FsNetOps) { $r = Fs-Http -Ip '_pc' -Path ('/addtemp?p3=' + $p3); $ip = $p3 + '.253'; [void]$script:FsTemps.Add([pscustomobject]@{ p3 = $p3; ip = $ip; ifIndex = 0 }); return $ip }
  if (-not $pc) { return '' }
  if ($script:FsNetBlocked) { Fs-LogLine ('no temporary address added: ' + $script:FsNetBlocked); return '' }   # 2.2.10 (Codex R03)
  # 1) the adapter as it is now, saved BEFORE anything changes
  if (-not $script:FsPcBefore) {
    try { $st = Invoke-FsNetOp 'state' @{ ifIndex = $pc.ifIndex } } catch { Fs-LogLine ('could not read this PC''s network settings - no temporary address added: ' + $_.Exception.Message); return '' }
    # 2.2.19 (F08): an incomplete read is not "the adapter as it was": nothing is added
    $rp = Get-FsNetReadProblem $st; if ($rp) { Fs-LogLine ($rp + ' - no temporary address added'); return '' }
    # 2.2.19 (F05): the adapter's stable ID is saved with it, so the clean-up can check it is still the same adapter
    $id = $null; try { $id = Invoke-FsNetOp 'ident' @{ ifIndex = $pc.ifIndex } } catch { $id = $null }
    if (-not $id -or -not [string]$id.name) { Fs-LogLine ('could not read which adapter is number ' + $pc.ifIndex + ' - no temporary address added'); return '' }
    if ([string]$id.name -ne [string]$pc.name) { Fs-LogLine ('adapter number ' + $pc.ifIndex + ' is "' + [string]$id.name + '", not the chosen "' + [string]$pc.name + '" - no temporary address added'); return '' }
    # 2.2.19 (class D): the coexistence setting must be known on a DHCP adapter - 2.2.18 read 'unknown' as "not enabled" and turned
    # it OFF at the end even when it had been on
    if ([bool]$st.dhcp -and [string]$st.coexist -notin @('enabled', 'disabled')) { Fs-LogLine 'the DHCP+static coexistence setting of this PC could not be read - no temporary address added (DHCP could not be kept safely)'; return '' }
    $script:FsPcBefore = [pscustomobject]@{ ifIndex = [int]$pc.ifIndex; name = [string]$pc.name; guid = $(if ($id.PSObject.Properties['guid']) { [string]$id.guid } else { '' }); dhcp = [bool]$st.dhcp; coexist = [string]$st.coexist; addrs = @($st.addrs | Where-Object { -not $_.skip }); gw = @($st.gw) }
    # 2.2.19 (class E): the record is the safety net - no record on disk, no change to the adapter
    try { Save-FsNetState $stateFile } catch { Fs-LogLine ('the record of this PC''s network could not be saved (' + $_.Exception.Message + ') - no temporary address added'); $script:FsPcBefore = $null; return '' }
  }
  # 2) a DHCP adapter keeps DHCP while it has an extra fixed address (Windows can switch DHCP off otherwise: review H4)
  # 2.2.10 (Codex R03): the intent is journaled BEFORE coexistence is switched on, so a run stopped in between still puts it back
  if ($script:FsPcBefore.dhcp -and $script:FsPcBefore.coexist -ne 'enabled' -and -not $script:FsCoexistChanged) {
    $script:FsCoexistChanged = $true
    try { Save-FsNetState $stateFile } catch { $script:FsCoexistChanged = $false; Fs-LogLine ('the record of this PC''s network could not be saved (' + $_.Exception.Message + ') - no temporary address added'); return '' }
    $okc = $false; try { $okc = [bool](Invoke-FsNetFix 'coexist' @{ ifIndex = $pc.ifIndex; on = $true }) } catch { Fs-LogLine ('coexistence not turned on: ' + $_.Exception.Message) }
    if (-not $okc) { Fs-LogLine 'could not turn on DHCP+static coexistence on this PC - no temporary address added (DHCP would be lost)'; return '' }   # the journal keeps "changed": the restore puts it back (harmless if it never changed)
  }
  foreach ($h in @(253, 252, 247, 246, 245)) {
    $ip = $p3 + '.' + $h; if (-not (Test-FsIpFree $ip)) { continue }
    $t = [pscustomobject]@{ p3 = $p3; ip = $ip; ifIndex = [int]$pc.ifIndex }
    [void]$script:FsTemps.Add($t)
    # written BEFORE the address goes on: a crash in between is still cleaned up. 2.2.19: not saved = not added
    try { Save-FsNetState $stateFile } catch { [void]$script:FsTemps.Remove($t); Fs-LogLine ('the record of this PC''s network could not be saved (' + $_.Exception.Message + ') - no temporary address added'); return '' }
    try {
      $st = [string](Invoke-FsNetFix 'addtemp' @{ ifIndex = $pc.ifIndex; ip = $ip; prefix = 24 })
      if ($st -eq 'Duplicate') {
        Fs-LogLine ('temp IP ' + $ip + ' is used by another device - trying the next')
        # 2.2.10 (Codex R03): it leaves the journal only once it is checked off the adapter; otherwise stop adding more
        if (-not (Remove-FsOneTempChecked $t $stateFile)) { return '' }
        continue
      }
      if (-not $script:FsNetOps) { Start-Sleep -Seconds 1 }
      return $ip
    } catch {
      # 2.2.10 (Codex R03): 2.2.9 dropped it from the journal whatever happened and tried the next one (five aliases, none tracked).
      # Now: try to take it off, keep it journaled unless the adapter shows it gone, and add no more addresses this time.
      Fs-LogLine ('temp IP ' + $ip + ' failed: ' + $_.Exception.Message)
      [void](Remove-FsOneTempChecked $t $stateFile)
      return ''
    }
  }
  return ''
}
# 2.2.10 (Codex R03): remove one temporary address and drop it from the journal ONLY when a fresh read shows it gone.
# 2.2.19 (F05/F08): only on the same adapter (identified again first), and "gone" only from a COMPLETE read of its addresses.
function Remove-FsOneTempChecked($t, [string]$stateFile) {
  try { [void](Invoke-FsNetFix 'remove' @{ ifIndex = $t.ifIndex; ip = $t.ip }) } catch { Fs-LogLine ('removing temp IP ' + $t.ip + ' failed: ' + $_.Exception.Message) }
  $gone = $false
  try { $now = Invoke-FsNetOp 'state' @{ ifIndex = $t.ifIndex }; if (-not (Get-FsNetReadProblem $now)) { $gone = -not @(@($now.addrs) | Where-Object { $_ -and [string]$_.ip -eq [string]$t.ip }).Count } } catch { $gone = $false }
  if ($gone) {
    [void]$script:FsTemps.Remove($t)
    try { Save-FsNetState $stateFile } catch { Fs-LogLine ('the record could not be updated (' + $_.Exception.Message + '); the older copy still lists ' + $t.ip + ' - the clean-up checks it again') }
    return $true
  }
  Fs-LogLine ('temp IP ' + $t.ip + ' may still be on this PC - kept in the journal so the clean-up takes it off')
  try { Save-FsNetState $stateFile } catch { Fs-LogLine ('the record could not be updated: ' + $_.Exception.Message) }
  return $false
}
function Restore-FsPcNet([string]$stateFile) {
  # takes every temporary address off, then puts the adapter back the way it was (DHCP, coexistence, its own addresses, its router).
  # Returns { ok; problems }. The saved state is kept (and tried again next start) unless every part checked back to normal.
  # 2.2.19 (Codex 2.2.18 F05/F08): nothing is changed unless the adapter at the saved number is positively the saved one (GUID +
  # name, read fresh before each change); a state read that is missing or incomplete is never taken as "the address is gone" or
  # "back to normal"; every temporary address and the record stay until a COMPLETE read shows them gone.
  $problems = @()
  $b = $script:FsPcBefore
  $ix = $(if ($b) { [int]$b.ifIndex } else { -1 })
  if (-not $b -and @($script:FsTemps).Count) {
    # a record without the adapter (2.2.0 list): no adapter name to check, so nothing is changed - only checked
    $ix = [int]@($script:FsTemps)[0].ifIndex
    $now = $null; try { $now = Invoke-FsNetOp 'state' @{ ifIndex = $ix } } catch { $now = $null }
    $rp = Get-FsNetReadProblem $now
    if ($rp) { $problems += ($rp + ', so it is not known whether the temporary addresses of an older run are gone') }
    else { foreach ($t in @($script:FsTemps)) { if (@(@($now.addrs) | Where-Object { $_ -and [string]$_.ip -eq [string]$t.ip }).Count) { $problems += ('the temporary address ' + $t.ip + ' of an older run is still on adapter number ' + $ix + '; its record does not name the adapter, so it is not taken off automatically - restart this PC (that takes it off), then run again') } } }
  }
  elseif ($b) {
    $coexistAtStart = [bool]$script:FsCoexistChanged
    $idw = Get-FsPcAdapterIdProblem $b $ix
    if ($idw) { $problems += $idw }
    else {
      foreach ($t in @($script:FsTemps)) { try { [void](Invoke-FsNetFix 'remove' @{ ifIndex = $ix; ip = $t.ip }) } catch { $problems += ('the temporary address ' + $t.ip + ' was not taken off: ' + $_.Exception.Message) } }
      $now = $null; try { $now = Invoke-FsNetOp 'state' @{ ifIndex = $ix } } catch { $problems += ('could not read the network settings back: ' + $_.Exception.Message) }
      $rp = Get-FsNetReadProblem $now
      if ($rp) { $problems += ($rp + ', so it is not known whether the temporary addresses are gone; they stay in the record') }
      else {
        $left = @(); foreach ($t in @($script:FsTemps)) { if (@(@($now.addrs) | Where-Object { $_ -and $_.ip -eq $t.ip }).Count) { $left += $t; $problems += ('the temporary address ' + $t.ip + ' is still on the adapter') } }
        $script:FsTemps.Clear(); foreach ($t in $left) { [void]$script:FsTemps.Add($t) }
        if ($b.dhcp -and -not $now.dhcp) { try { [void](Invoke-FsNetFix 'dhcp' @{ ifIndex = $ix; on = $true }); Fs-LogLine 'DHCP switched back on for this PC' } catch { $problems += ('DHCP could not be switched back on: ' + $_.Exception.Message) } }
        if (-not $b.dhcp) {
          foreach ($ad in @($b.addrs)) { if ($ad -and -not @(@($now.addrs) | Where-Object { $_ -and $_.ip -eq $ad.ip }).Count) { try { [void](Invoke-FsNetFix 'addstatic' @{ ifIndex = $ix; ip = $ad.ip; prefix = $ad.prefix; gw = '' }); Fs-LogLine ('this PC''s own address ' + $ad.ip + ' put back') } catch { $problems += ('this PC''s own address ' + $ad.ip + ' could not be put back: ' + $_.Exception.Message) } } }
          foreach ($g in @($b.gw)) { if ($g -and @($now.gw) -notcontains $g) { try { [void](Invoke-FsNetFix 'addroute' @{ ifIndex = $ix; gw = $g }); Fs-LogLine ('this PC''s router ' + $g + ' put back') } catch { $problems += ('the router route ' + $g + ' could not be put back: ' + $_.Exception.Message) } } }
        }
        if ($script:FsCoexistChanged) { $okc = $false; try { $okc = [bool](Invoke-FsNetFix 'coexist' @{ ifIndex = $ix; on = $false }) } catch { Fs-LogLine ('coexistence not put back: ' + $_.Exception.Message) }; if (-not $okc) { $problems += 'the DHCP+static coexistence setting could not be put back' } }
        # check it again: DHCP on (when it was), own addresses back (when fixed)
        # 2.2.2 (re-review H4): a read that fails is a problem (not a pass); a DHCP adapter must have a real address again and every
        # router it had (default route) must be back - for DHCP too. DHCP can take a few seconds to hand the address back: asked again.
        # 2.2.19: the temporary addresses must still be gone, the coexistence setting (when it was changed) must READ BACK as it was
        $chk = $null; $vp = @()
        for ($try = 0; $try -lt [math]::Max(1, [int]$script:FsRestoreChecks); $try++) {
          if ($try -gt 0) { if ($b.dhcp -and $try -eq 1) { try { [void](Invoke-FsNetFix 'renew' @{ ifIndex = $ix; name = [string]$b.name }) } catch {} }; Fs-NetWait }
          $chk = $null; try { $chk = Invoke-FsNetOp 'state' @{ ifIndex = $ix } } catch { $chk = $null }
          $vp = @(Get-FsNetVerifyProblems $b $chk @($left) $coexistAtStart)
          if (-not $vp.Count) { break }
        }
        $problems += $vp
        if (-not $vp.Count) { $script:FsCoexistChanged = $false }
      }
    }
  }
  $problems = @($problems | Select-Object -Unique)
  if (-not $problems.Count) {
    $script:FsPcBefore = $null; $script:FsCoexistChanged = $false; $script:FsTemps.Clear()
    if ($stateFile -and (Test-Path -LiteralPath $stateFile)) { try { Remove-Item -LiteralPath $stateFile -Force -ErrorAction Stop } catch { Fs-LogLine ('this PC''s network is back, but its finished record could not be removed (' + $_.Exception.Message + '); the next start checks it again') } }
    # 2.2.20 (R01): every part was checked back, so an unfinished copy of the record is stale now (a copy that stays is merged and checked again next start)
    if ($stateFile -and (Test-Path -LiteralPath ($stateFile + '.tmp'))) { try { Remove-Item -LiteralPath ($stateFile + '.tmp') -Force -ErrorAction Stop } catch { Fs-LogLine ('an unfinished copy of the network record could not be removed (' + $_.Exception.Message + '); the next start checks it again') } }
  } else {
    foreach ($pb in $problems) { Fs-LogLine ('NETWORK NOT BACK TO NORMAL: ' + $pb) }
    # an older record without the adapter (2.2.0 list) is left exactly as it is; a 2.2.10+ record is updated with what is left
    if ($b) { try { Save-FsNetState $stateFile } catch { Fs-LogLine ('the record could not be updated (' + $_.Exception.Message + '); the older copy is kept') } }
  }
  $script:FsLastRestore = [pscustomobject]@{ ok = (-not $problems.Count); problems = @($problems) }
  return $script:FsLastRestore
}
# 2.2.2 (re-review H4): what is still not as it was ($b = saved before, $chk = read now, $temps = temporary addresses still on).
$script:FsRestoreChecks = 5     # reads of the adapter before it counts as "not back" (about 2 s apart)
function Fs-NetWait { if ($script:FsNetOps -and $script:FsNetOps.ContainsKey('wait')) { [void](& $script:FsNetOps['wait'] @{}); return }; Start-Sleep -Seconds 2 }
function Get-FsNetVerifyProblems($b, $chk, $temps = @(), [bool]$coexist = $false) {
  # 2.2.19 (F08): an incomplete read is "not known", never "back"
  $rp = Get-FsNetReadProblem $chk
  if ($rp) { return @($rp + ', so it is not known whether they are back') }
  $p = @()
  $tempIps = @(@($temps) + @($script:FsTemps) | Where-Object { $_ } | ForEach-Object { [string]$_.ip })
  foreach ($ti in @($tempIps | Select-Object -Unique)) { if (@(@($chk.addrs) | Where-Object { $_ -and [string]$_.ip -eq $ti }).Count) { $p += ('the temporary address ' + $ti + ' is still on the adapter') } }
  $own = @(@($chk.addrs) | Where-Object { $_ -and $_.ip -and -not $_.skip -and [string]$_.ip -notlike '169.254.*' -and $tempIps -notcontains [string]$_.ip })
  if ($b.dhcp) {
    if (-not $chk.dhcp) { $p += 'DHCP is still off on this PC' }
    $hadAddr = @(@($b.addrs) | Where-Object { $_ -and [string]$_.ip -notlike '169.254.*' }).Count -gt 0
    if ($hadAddr -and -not $own.Count) { $p += 'this PC has no address from DHCP yet' }
  } else {
    foreach ($ad in @($b.addrs)) { if ($ad -and -not @(@($chk.addrs) | Where-Object { $_ -and $_.ip -eq $ad.ip }).Count) { $p += ('this PC''s address ' + $ad.ip + ' is still missing') } }
  }
  foreach ($g in @($b.gw)) { if ($g -and @($chk.gw) -notcontains $g) { $p += ('this PC''s router ' + $g + ' (default route) is not back') } }
  # 2.2.19 (Codex 2.2.18 F18 twin): a coexistence setting this run changed must read back as it was; unreadable = not known
  if ($coexist) {
    $want = $(if ([string]$b.coexist -eq 'enabled') { 'enabled' } else { 'disabled' })
    $got = $(if ($chk.PSObject.Properties['coexist']) { ([string]$chk.coexist).ToLower() } else { '' })
    if ($got -notin @('enabled', 'disabled')) { $p += ('the DHCP+static coexistence setting could not be read back (it should be ' + $want + '), so it is not known whether it is back') }
    elseif ($got -ne $want) { $p += ('the DHCP+static coexistence setting is ' + $got + ', it should be ' + $want) }
  }
  return $p
}
function Remove-FsTempIps([string]$stateFile) {
  if ($script:FsMockUrl -and -not $script:FsNetOps) {
    foreach ($t in @($script:FsTemps)) { [void](Fs-Http -Ip '_pc' -Path ('/deltemp?p3=' + $t.p3)) }
    $script:FsTemps.Clear(); if ($stateFile -and (Test-Path $stateFile)) { Remove-Item $stateFile -Force -ErrorAction SilentlyContinue }
    $script:FsLastRestore = [pscustomobject]@{ ok = $true; problems = @() }; return $script:FsLastRestore
  }
  if (-not $script:FsPcBefore -and -not @($script:FsTemps).Count) {
    if ($script:FsNetBlocked) { $script:FsLastRestore = [pscustomobject]@{ ok = $false; problems = @($script:FsNetBlocked) }; return $script:FsLastRestore }   # 2.2.10 (Codex R03)
    $script:FsLastRestore = [pscustomobject]@{ ok = $true; problems = @() }; return $script:FsLastRestore
  }
  $rr = Restore-FsPcNet $stateFile
  # 2.2.18 (Codex F5): while an unresolved recovery stands, the clean-up never says "back to normal"
  if ($script:FsNetBlocked -and $rr -and $rr.ok) { $rr = [pscustomobject]@{ ok = $false; problems = @(@($rr.problems) + @($script:FsNetBlocked)) }; $script:FsLastRestore = $rr }
  return $rr
}
# 2.2.18 (Codex F5): "an earlier run left this PC's network changed and its record could not be read" is kept ON DISK, not only in
# this run's memory (2.2.10-2.2.17 renamed the unreadable record away and kept the block in memory, so the next start found nothing
# and changed the adapter again). The marker is <journal>.recovery-needed.json beside the journal: { version = 1; created (local time);
# createdUtcTicks (UTC ticks); kept (the renamed unreadable record); why }. Every start reads it FIRST and blocks every adapter change
# while it is there - a new window, a second run, a fresh PowerShell all see it. Only a VERIFIED recovery clears it: this PC has
# restarted since the marker was written (a temporary address lives only in the adapter's memory, so a restart takes it off) AND no
# adapter shows a temporary address now (IPv4 "skip as source", the kind the Toolkit adds). Cleared = the marker is renamed
# .recovery-cleared-<time>.json and the unreadable records .cleared-unreadable-<time>.json (kept, never deleted). An unreadable record
# left by 2.2.10-2.2.17 (.unreadable-*.json with no marker) gets a marker at the next start (its own file time = when it was written).
function Get-FsNetMarkerPath([string]$stateFile) { return ($stateFile -replace '\.json$', '.recovery-needed.json') }
function Set-FsNetRecoveryMarker([string]$stateFile, [string]$kept, [datetime]$whenUtc) {
  $mk = Get-FsNetMarkerPath $stateFile
  if (Test-Path -LiteralPath $mk) { return $mk }   # the FIRST marker's time stands: the restart must come after the first problem
  $o = [ordered]@{ version = 1; created = $whenUtc.ToLocalTime().ToString('s'); createdUtcTicks = [int64]$whenUtc.Ticks; kept = $kept; why = 'the record of an earlier run''s changes to this PC''s network could not be read' }
  Save-FsRecordVerified $mk ($o | ConvertTo-Json)   # 2.2.20 (Codex 2.2.19 R01 twin): the durable block is read back too
  return $mk
}
# '' = the recovery is verified now, else what is still missing (plain words)
# 2.2.19 (decision, Codex 2.2.18 F05/F08/F09): a restart alone never clears it. Cleared only by a POSITIVE check of the actual state,
# with every query readable: this PC restarted since the problem was written down (a temporary address lives only in memory), AND
# no adapter has a "skip as source" address (the kind the Toolkit adds), AND every connected adapter reads completely and is
# normal: DHCP on with coexistence off, or its own fixed address. Anything unreadable or not normal = still blocked.
function Test-FsNetRecoveryVerified($createdUtc) {
  if (-not $createdUtc) { return 'it is not known when the problem was written down' }
  $boot = $null; try { $boot = Invoke-FsNetOp 'boottime' @{} } catch { $boot = $null }
  if (-not ($boot -is [datetime])) { return 'it could not be read when this PC last restarted' }
  if ($boot.ToUniversalTime() -le ([datetime]$createdUtc)) { return 'this PC has not been restarted since' }
  $sk = $null; try { $sk = Invoke-FsNetOp 'skipaddrs' @{} } catch { $sk = $null }
  if (-not $sk -or -not $sk.PSObject.Properties['ips']) { return 'this PC''s network addresses could not be read' }
  if (@($sk.ips | Where-Object { $_ }).Count) { return ('a temporary address is still on this PC (' + (@($sk.ips | Where-Object { $_ }) -join ', ') + ')') }
  $all = $null; try { $all = Invoke-FsNetOp 'allstate' @{} } catch { $all = $null }
  if (-not $all -or -not $all.PSObject.Properties['adapters']) { return 'this PC''s network adapters could not be read' }
  foreach ($x in @($all.adapters | Where-Object { $_ })) {
    $st = $x.state; $nm = [string]$x.name
    $rp = Get-FsNetReadProblem $st
    if ($rp) { return ('the settings of adapter "' + $nm + '" could not be fully read') }
    if (@(@($st.addrs) | Where-Object { $_ -and $_.skip -and [string]$_.ip -notlike '169.254.*' }).Count) { return ('a temporary address is still on adapter "' + $nm + '"') }
    $own = @(@($st.addrs) | Where-Object { $_ -and $_.ip -and -not $_.skip -and [string]$_.ip -notlike '169.254.*' })
    if ($st.dhcp) {
      $co = $(if ($st.PSObject.Properties['coexist']) { ([string]$st.coexist).ToLower() } else { '' })
      if ($co -notin @('enabled', 'disabled')) { return ('the DHCP+static coexistence setting of adapter "' + $nm + '" could not be read') }
      if ($co -eq 'enabled') { return ('adapter "' + $nm + '" still has DHCP+static coexistence on (the Toolkit turns it on while it works) - run Restore Network') }
    } elseif (-not $own.Count) { return ('adapter "' + $nm + '" has DHCP off and no address of its own - run Restore Network') }
  }
  return ''
}
# '' = no unresolved recovery (or it was just verified and cleared); otherwise the block, in plain words
function Test-FsNetRecoveryMarker([string]$stateFile) {
  if (-not $stateFile) { return '' }
  $dir = Split-Path -Parent $stateFile; $base = [IO.Path]::GetFileNameWithoutExtension($stateFile)
  if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return '' }
  $mk = Get-FsNetMarkerPath $stateFile
  $ev = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ($base + '.unreadable-*.json') } | Sort-Object LastWriteTimeUtc)
  $hasMk = Test-Path -LiteralPath $mk
  if (-not $hasMk -and -not $ev.Count) { return '' }
  $created = $null; $kept = ''
  if (-not $hasMk) { $created = $ev[-1].LastWriteTimeUtc; $kept = $ev[-1].Name; try { [void](Set-FsNetRecoveryMarker $stateFile $kept $created) } catch { Fs-LogLine ('the network recovery reminder could not be written: ' + $_.Exception.Message) } }
  else {
    try { $mj = Get-Content -LiteralPath $mk -Raw -ErrorAction Stop | ConvertFrom-Json; if ($mj -and $mj.PSObject.Properties['createdUtcTicks']) { $created = New-Object DateTime ([int64]$mj.createdUtcTicks), ([DateTimeKind]::Utc) }; if ($mj -and $mj.PSObject.Properties['kept']) { $kept = [string]$mj.kept } } catch {}
    if (-not $created) { try { $created = (Get-Item -LiteralPath $mk).LastWriteTimeUtc } catch {} }   # an unreadable marker still blocks
    if ($ev.Count -and $ev[-1].LastWriteTimeUtc -gt $created) { $created = $ev[-1].LastWriteTimeUtc }
  }
  $why = Test-FsNetRecoveryVerified $created
  if (-not $why) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    try { if (Test-Path -LiteralPath $mk) { Move-Item -LiteralPath $mk -Destination ($stateFile -replace '\.json$', ('.recovery-cleared-' + $stamp + '.json')) -Force } } catch {}
    foreach ($f in $ev) { try { Move-Item -LiteralPath $f.FullName -Destination (Join-Path $dir ($f.Name -replace '\.unreadable-', '.cleared-unreadable-')) -Force } catch {} }
    Fs-LogLine 'the earlier unreadable network record is sorted out: this PC restarted since, and no temporary address is on it'
    return ''
  }
  return ('an earlier run left this PC''s network changed and its record could not be read' + $(if ($kept) { ' (kept as ' + $kept + ')' } else { '' }) + '; no change is made to this PC''s network until that is sorted out - ' + $why + '. Restart this PC, then run again')
}
# 2.2.19 (Codex 2.2.18 F09): '' when a journal read from disk has a supported shape with every value recovery needs, else what
# is wrong. Version 2: { version = 2; before = { ifIndex (number); name; dhcp (true/false); coexist; addrs (list); gw (list); guid
# (2.2.19+, may be missing in older ones) }; coexistChanged (true/false); temps (list of { ip; ifIndex }) }. The 2.2.0 form: a
# non-empty list of { ip; ifIndex }. Anything else ({} included) is NOT "nothing changed": it is quarantined under the durable block.
function Test-FsIpv4([string]$s) { $p = [Net.IPAddress]::None; return ($s -match '^\d{1,3}(\.\d{1,3}){3}$' -and [Net.IPAddress]::TryParse($s, [ref]$p)) }
function Test-FsJsonInt($v) { if ($null -eq $v -or $v -is [bool]) { return $false }; $n = 0; return ([int]::TryParse([string]$v, [ref]$n) -and $n -ge 0) }
function Test-FsNetTempEntry($t) { return ($t -and $t -is [pscustomobject] -and $t.PSObject.Properties['ip'] -and (Test-FsIpv4 ([string]$t.ip)) -and $t.PSObject.Properties['ifIndex'] -and (Test-FsJsonInt $t.ifIndex)) }
function Get-FsNetJournalProblem($tj) {
  if ($null -eq $tj) { return 'it is empty' }
  if ($tj -is [array]) {
    $l = @($tj); if (-not $l.Count) { return 'it is an empty list' }
    foreach ($t in $l) { if (-not (Test-FsNetTempEntry $t)) { return 'an address in it has no valid IP or adapter number' } }
    return ''
  }
  if ($tj -isnot [pscustomobject]) { return 'it is not a record' }
  if (-not $tj.PSObject.Properties['version']) { if ($tj.PSObject.Properties['ip']) { if (Test-FsNetTempEntry $tj) { return '' }; return 'its address has no valid IP or adapter number' }; return 'it has no version' }
  if (-not (Test-FsJsonInt $tj.version) -or [int]$tj.version -ne 2) { return ('its version (' + [string]$tj.version + ') is not one this Toolkit knows') }
  $miss = @()
  foreach ($k in @('before', 'coexistChanged', 'temps')) { if (-not $tj.PSObject.Properties[$k]) { $miss += $k } }
  if ($miss.Count) { return ('it is missing ' + ($miss -join ', ')) }
  if ($tj.coexistChanged -isnot [bool]) { return 'its coexistChanged is not true/false' }
  $b = $tj.before
  if ($null -eq $b -or $b -isnot [pscustomobject]) { return 'it does not say how the adapter was before' }
  foreach ($k in @('ifIndex', 'name', 'dhcp', 'coexist', 'addrs', 'gw')) { if (-not $b.PSObject.Properties[$k]) { $miss += ('before.' + $k) } }
  if ($miss.Count) { return ('it is missing ' + ($miss -join ', ')) }
  if (-not (Test-FsJsonInt $b.ifIndex)) { return 'its adapter number is not a number' }
  if (-not [string]$b.name) { return 'it does not name the adapter' }
  if ($b.dhcp -isnot [bool]) { return 'its DHCP setting is not true/false' }
  if ([string]$b.coexist -notin @('enabled', 'disabled', 'unknown')) { return 'its coexistence setting is not readable' }
  foreach ($ad in @($b.addrs)) { if ($null -ne $ad -and -not ($ad -is [pscustomobject] -and (Test-FsIpv4 ([string]$ad.ip)))) { return 'one of its own addresses is not a valid IP' } }
  foreach ($g in @($b.gw)) { if ($null -ne $g -and [string]$g -and -not (Test-FsIpv4 ([string]$g))) { return 'one of its routers is not a valid IP' } }
  if (-not $b.dhcp -and -not @(@($b.addrs) | Where-Object { $_ }).Count) { return 'it says the adapter had a fixed setup but lists no address' }
  if ($null -ne $tj.temps -and $tj.temps -isnot [array] -and $tj.temps -isnot [pscustomobject]) { return 'its list of temporary addresses is not a list' }
  foreach ($t in @($tj.temps | Where-Object { $null -ne $_ })) { if (-not (Test-FsNetTempEntry $t)) { return 'a temporary address in it has no valid IP or adapter number' } }
  return ''
}
# an unreadable or damaged journal: kept (renamed .unreadable-<time>.json) + the durable marker; returns the block (plain words)
function Set-FsNetJournalQuarantine([string]$stateFile, [string]$what) {
  $keep = $stateFile -replace '\.json$', ('.unreadable-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
  try { Move-Item -LiteralPath $stateFile -Destination $keep -Force -ErrorAction Stop } catch { $keep = $stateFile }
  # 2.2.18 (Codex F5): ...and written down on disk, so the next start is blocked too (see Test-FsNetRecoveryMarker)
  $mw = ''; try { [void](Set-FsNetRecoveryMarker $stateFile (Split-Path -Leaf $keep) ((Get-Date).ToUniversalTime())) } catch { $mw = ' (the reminder file could not be written: ' + $_.Exception.Message + ')' }
  return ('the record of an earlier run''s changes to this PC''s network ' + $what + ' (kept as ' + (Split-Path -Leaf $keep) + '); no change is made to this PC''s network until that is sorted out - restart this PC, then run again (it is checked then)' + $mw)
}
# 2.2.20 (Codex 2.2.19 R01): <journal>.tmp is written right before the journal is put in place. One that is still there at the next
# start means a run stopped (or its save failed) in between: what it lists may have been changed on this PC. It is EVIDENCE:
# - it cannot be read or is damaged: kept as <journal>.unreadable-<time>-tmp.json under the durable block (Test-FsNetRecoveryMarker);
# - it is a whole record: its temporary addresses (and a coexistence change) are added to the journal (or it becomes the journal
#   when there is none), the result is saved and READ BACK, and the normal recovery then takes everything it lists off;
# - a record that names another adapter than the journal, or a save that does not read back: the durable block.
# '' = nothing left over or it was taken in; otherwise the block in plain words (no change to this PC's network this run).
function Resolve-FsNetOrphanTmp([string]$stateFile) {
  if (-not $stateFile) { return '' }
  $tmp = $stateFile + '.tmp'
  $there = $false; try { $there = Test-Path -LiteralPath $tmp -ErrorAction Stop } catch { return ('it could not be checked whether an earlier run left an unfinished network record (' + $_.Exception.Message + '); no change is made to this PC''s network') }
  if (-not $there) { return '' }
  $quar = {
    param([string]$what)
    $keep = $stateFile -replace '\.json$', ('.unreadable-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-tmp.json')
    try { Move-Item -LiteralPath $tmp -Destination $keep -Force -ErrorAction Stop } catch { $keep = $tmp }
    $mw = ''; try { [void](Set-FsNetRecoveryMarker $stateFile (Split-Path -Leaf $keep) ((Get-Date).ToUniversalTime())) } catch { $mw = ' (the reminder file could not be written: ' + $_.Exception.Message + ')' }
    return ('an earlier run stopped while saving the record of its changes to this PC''s network, and that unfinished record ' + $what + ' (kept as ' + (Split-Path -Leaf $keep) + '); no change is made to this PC''s network until that is sorted out - restart this PC, then run again (it is checked then)' + $mw)
  }
  $raw = ''; $t = $null
  try { $raw = [IO.File]::ReadAllText($tmp); $t = ConvertFrom-Json -InputObject $raw -ErrorAction Stop } catch { return (& $quar 'could not be read') }
  $tp = Get-FsNetJournalProblem $t
  if ($tp) { return (& $quar ('is damaged (' + $tp + ')')) }
  if ($t -is [array] -or -not $t.PSObject.Properties['version']) { return (& $quar 'is in an old form that cannot be merged') }
  $final = $null; $fThere = $false
  try { $fThere = Test-Path -LiteralPath $stateFile -ErrorAction Stop } catch { return (& $quar 'could not be compared with the journal') }
  if ($fThere) {
    try { $final = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($stateFile)) -ErrorAction Stop } catch { $final = $null }
    # a damaged journal is quarantined by the normal start check; the unfinished record is kept as evidence beside it
    if (-not $final -or (Get-FsNetJournalProblem $final) -or $final -is [array]) { return (& $quar 'sits beside a journal that cannot be read') }
    if ([int]$final.before.ifIndex -ne [int]$t.before.ifIndex -or [string]$final.before.name -ne [string]$t.before.name -or [string](Get-FsProp $final.before 'guid' '') -ne [string](Get-FsProp $t.before 'guid' '')) { return (& $quar 'names another adapter than the journal') }
    $temps = New-Object System.Collections.ArrayList
    foreach ($x in @(@($final.temps) + @($t.temps))) { if ($x -and -not @($temps | Where-Object { [string]$_.ip -eq [string]$x.ip -and [int]$_.ifIndex -eq [int]$x.ifIndex }).Count) { [void]$temps.Add($x) } }
    $o = [ordered]@{ version = 2; written = (Get-Date -Format 's'); before = $final.before; coexistChanged = ([bool]$final.coexistChanged -or [bool]$t.coexistChanged); temps = @($temps) }
    $text = ($o | ConvertTo-Json -Depth 6)
  } else { $text = $raw }
  try { Save-FsRecordVerified $stateFile $text } catch { return (& $quar ('could not be taken into the journal (' + $_.Exception.Message + ')')) }
  Fs-LogLine ('an unfinished network record of an earlier run was found (' + (Split-Path -Leaf $tmp) + ') and taken into the journal - everything it lists is put back')
  return ''
}
function Clear-FsLeftoverTemps([string]$stateFile) {
  # a run that crashed or was stopped left this PC changed: put it back at the next start (and from the "Fix this site" task's finally)
  if (($script:FsMockUrl -and -not $script:FsNetOps) -or -not $stateFile) { return $null }
  # 2.2.18 (Codex F5): an unresolved recovery written down by an earlier start blocks this one too, until it is verified
  $mb = Test-FsNetRecoveryMarker $stateFile
  if ($mb) {
    $script:FsNetBlocked = $mb; Fs-LogLine ('NETWORK NOT BACK TO NORMAL: ' + $mb)
    $script:FsLastRestore = [pscustomobject]@{ ok = $false; problems = @($mb) }
    return $script:FsLastRestore
  }
  # 2.2.20 (Codex 2.2.19 R01): a record left half-installed (<journal>.tmp) is evidence, never ignored
  $ob = Resolve-FsNetOrphanTmp $stateFile
  if ($ob) {
    $script:FsNetBlocked = $ob; Fs-LogLine ('NETWORK NOT BACK TO NORMAL: ' + $ob)
    $script:FsLastRestore = [pscustomobject]@{ ok = $false; problems = @($ob) }
    return $script:FsLastRestore
  }
  if (-not (Test-Path -LiteralPath $stateFile)) { return $null }
  $tj = $null; $rdErr = ''
  try { $raw = [IO.File]::ReadAllText($stateFile); $tj = ConvertFrom-Json -InputObject $raw -ErrorAction Stop } catch { $rdErr = $_.Exception.Message; $tj = $null }
  # 2.2.10 (Codex R03): an unreadable journal is an unsolved recovery, not "nothing to do". It is kept (renamed, so the PC can be
  # put back by hand from it), no adapter change happens in this run, and the run ends FAILED - Run again.
  # 2.2.19 (Codex 2.2.18 F09): the same for a journal that reads but is damaged ({} or a required value missing/invalid)
  $jp = $(if ($rdErr) { 'could not be read' } else { Get-FsNetJournalProblem $tj })
  if ($jp) {
    $what = $(if ($rdErr) { 'could not be read' } else { 'is damaged (' + $jp + ')' })
    $script:FsNetBlocked = Set-FsNetJournalQuarantine $stateFile $what
    Fs-LogLine ('NETWORK NOT BACK TO NORMAL: ' + $script:FsNetBlocked)
    $script:FsLastRestore = [pscustomobject]@{ ok = $false; problems = @($script:FsNetBlocked) }
    return $script:FsLastRestore
  }
  $script:FsTemps.Clear()
  if ($tj -isnot [array] -and $tj.PSObject.Properties['version']) {
    $script:FsPcBefore = $tj.before; $script:FsCoexistChanged = [bool]$tj.coexistChanged
    foreach ($t in @($tj.temps)) { if ($t) { [void]$script:FsTemps.Add($t) } }
  } else { $script:FsPcBefore = $null; foreach ($t in @($tj)) { if ($t -and $t.ip) { [void]$script:FsTemps.Add($t) } } }   # 2.2.0 and older: a plain list of addresses
  Fs-LogLine 'a previous run left this PC''s network changed - putting it back'
  return (Restore-FsPcNet $stateFile)
}

function Wait-FsDevice([string]$ip, [string]$brand, [string]$pw, [int]$seconds) {
  $end = (Get-Date).AddSeconds($seconds)
  # 2.2.20 (Codex 2.2.19 R13): while it restarts, it is asked WITHOUT a password until it answers at all, so a reboot's timeouts do not
  # spend wrong-password tries (each uncertain try with a password now stays counted); then ONE login with the password per round
  do {
    $s0 = Test-FsLogin $ip $brand ''
    if ($s0 -ne 'noanswer') { $s = Test-FsLogin $ip $brand $pw; if ($s -eq 'ok') { return $true }; if ($s -eq 'refused' -or $s -eq 'locked') { return $false } }
    Fs-Sleep 5
  } while ((Get-Date) -lt $end)
  return $false
}
function Fs-Sleep([int]$s) { if ($script:FsMockUrl) { Start-Sleep -Milliseconds ([math]::Min(200, $s * 20)) } else { Start-Sleep -Seconds $s } }

# ---------------- PoE power-cycle through the office Dell's UniFi path (C:\WireIt\PortMap\camreboot.py --cycle) ----------------
function Invoke-FsPoeCycle([string]$siteId, [string]$mac, [string]$portMapDir) {
  # returns { state ('done'|'failed'|'refused'|'unavailable'); msg }
  if ($script:FsMockUrl) { $r = Fs-Http -Ip '_pc' -Path ('/poe?mac=' + $mac); return ($r.body | ConvertFrom-Json) }
  $py = $null; foreach ($p in @((Join-Path (Split-Path -Parent $portMapDir) 'VendorMonitor\python\python.exe'), (Join-Path $portMapDir 'python\python.exe'))) { if (Test-Path $p) { $py = $p; break } }
  $cr = Join-Path $portMapDir 'camreboot.py'
  if (-not $siteId -or -not $py -or -not (Test-Path $cr) -or -not (Select-String -Path $cr -Pattern '--cycle' -SimpleMatch -Quiet)) { return [pscustomobject]@{ state = 'unavailable'; msg = 'switch power-cycle is only on the office Dell (PortMap)' } }
  $out = & $py $cr '--cycle' $siteId $mac 2>&1 | Out-String
  $last = @($out -split "`r?`n" | Where-Object { $_ -match '^\{' } | Select-Object -Last 1)
  if ($last.Count) { try { return ($last[0] | ConvertFrom-Json) } catch {} }
  return [pscustomobject]@{ state = 'failed'; msg = ('no answer from the switch job: ' + ($out.Trim() -replace '\s+', ' ')).Substring(0, [math]::Min(160, $out.Length + 30)) }
}

# ---------------- the site's secret store (encrypted on THIS PC; never Drive, never logs) ----------------
# 2.2.0 (review M1): DPAPI LocalMachine scope, so ANY admin account and the background "Fix this site" task (SYSTEM) read the same
# store. LocalMachine means anyone who can READ the file can decrypt it on this PC, so the store lives in vault\, which only
# Administrators and SYSTEM can open (Install-Toolkit sets that). Files written by 2.1 (CurrentUser scope, no "LM1:" mark) are still
# read when the same Windows account that wrote them runs it, and are then re-saved as LocalMachine. A file nobody here can read
# is reported as "saved by another Windows account" - it is never treated as "no password yet".
$script:FsDpapi = $null   # TESTS ONLY: { param([string]$op, [byte[]]$data, [string]$scope) } stands in for Windows' DPAPI
$script:FsLegacySecretsDir = ''   # 2.1's secrets\ folder: read there when vault\ has no file yet (then moved into vault\)
function Invoke-FsDpapi([string]$Op, [byte[]]$Data, [string]$Scope) {
  if ($script:FsDpapi) { return [byte[]](& $script:FsDpapi $Op $Data $Scope) }
  Add-Type -AssemblyName System.Security
  $ent = [Text.Encoding]::UTF8.GetBytes('WireIt-FixSite')
  if ($Op -eq 'protect') { return [Security.Cryptography.ProtectedData]::Protect($Data, $ent, [Security.Cryptography.DataProtectionScope]$Scope) }
  return [Security.Cryptography.ProtectedData]::Unprotect($Data, $ent, [Security.Cryptography.DataProtectionScope]$Scope)
}
function Protect-FsText([string]$s) {
  if ($script:FsTestSecrets) { return ('TEST:' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s))) }
  return ('LM1:' + [Convert]::ToBase64String((Invoke-FsDpapi 'protect' ([Text.Encoding]::UTF8.GetBytes($s)) 'LocalMachine')))
}
function Unprotect-FsText([string]$s) {
  $s = ([string]$s).Trim()
  if ($s.StartsWith('TEST:')) { if (-not $script:FsTestSecrets) { throw 'test secret file on a real run' }; return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s.Substring(5))) }
  if ($s.StartsWith('LM1:')) {
    try { return [Text.Encoding]::UTF8.GetString((Invoke-FsDpapi 'unprotect' ([Convert]::FromBase64String($s.Substring(4))) 'LocalMachine')) }
    catch { throw 'FS_OTHER_PC: saved on another PC (this PC cannot read it)' }
  }
  try { $t = [Text.Encoding]::UTF8.GetString((Invoke-FsDpapi 'unprotect' ([Convert]::FromBase64String($s)) 'CurrentUser')); $script:FsLastWasLegacy = $true; return $t }
  catch { throw 'FS_OTHER_ACCOUNT: saved by another Windows account (2.1 kept it for that account only)' }
}
# the plain words for the screen when a store can't be read
function Get-FsUnreadableText([string]$why) {
  if ($why -match 'FS_OTHER_PC') { return 'This site''s saved password file was made on another PC, so this PC cannot read it.' }
  return 'This site''s saved password was saved by another Windows account, so this PC cannot read it here.'
}
function Get-FsSecretPath([string]$dir, [string]$site, [switch]$Legacy) { return (Join-Path $dir ('site-' + $(if ($Legacy) { Get-FsLegacySlug $site } else { Get-FsSiteSlug $site }) + '.dat')) }   # 2.2.3 (Codex #24); 2.2.4: every name fingerprinted
function Read-FsSecrets([string]$dir, [string]$site) {
  $o = [ordered]@{ site = $site; password = ''; known = @(); nvr = @{}; cams = @{}; rollback = @{}; bitwardenSaved = $false; shownOnce = $false; unreadable = $false; unreadableWhy = '' }
  $p = Get-FsSecretPath $dir $site
  $fromLegacy = $false
  $oldName = $false
  if (-not (Test-Path -LiteralPath $p)) {
    # 2.2.4: old names (2.2.3 / 2.2.2) and the old secrets\ folder: the first store that says it is exactly this site (or names no site)
    $cands = @(); foreach ($s in @(Get-FsOldSlugs $site)) { $cands += ,@((Join-Path $dir ('site-' + $s + '.dat')), $true, $false) }
    if ($script:FsLegacySecretsDir) { $cands += ,@((Get-FsSecretPath $script:FsLegacySecretsDir $site), $false, $true); foreach ($s in @(Get-FsOldSlugs $site)) { $cands += ,@((Join-Path $script:FsLegacySecretsDir ('site-' + $s + '.dat')), $false, $true) } }
    foreach ($c in $cands) {
      if (-not (Test-Path -LiteralPath $c[0])) { continue }
      $owner = $null; try { $pj = (Unprotect-FsText ((Get-Content -LiteralPath $c[0] -Raw).Trim())) | ConvertFrom-Json; if ($pj -and $pj.PSObject.Properties['site']) { $owner = [string]$pj.site } } catch { $owner = $null }   # unreadable: taken, so it is reported as unreadable (not as "no password")
      if ($owner -and -not (Test-FsSameSite $owner $site)) { Fs-LogLine 'secret store belongs to another site name: not used'; continue }
      $p = $c[0]; $oldName = $c[1]; $fromLegacy = $c[2]; break
    }
  }
  $script:FsLastWasLegacy = $false
  if (Test-Path -LiteralPath $p) {
    try { $j = (Unprotect-FsText ((Get-Content -LiteralPath $p -Raw).Trim())) | ConvertFrom-Json
      # 2.2.3 (Codex #24): the store says which site it is: another site's store is never used for this one
      if ($j -and $j.PSObject.Properties['site'] -and [string]$j.site -and -not (Test-FsSameSite ([string]$j.site) $site)) { Fs-LogLine 'secret store belongs to another site name: not used'; $j = $null; $oldName = $false; $fromLegacy = $false }
      if ($j) { foreach ($k in @('password', 'known', 'bitwardenSaved', 'shownOnce')) { if ($j.PSObject.Properties[$k]) { $o[$k] = $j.$k } }; foreach ($k in @('nvr', 'cams', 'rollback')) { if ($j.PSObject.Properties[$k] -and $j.$k) { $h = @{}; foreach ($q in $j.$k.PSObject.Properties) { $h[$q.Name] = $q.Value }; $o[$k] = $h } } } }
    catch { $o.unreadable = $true; $o.unreadableWhy = [string]$_.Exception.Message; Fs-LogLine ('secret store unreadable: ' + $_.Exception.Message) }
  }
  $o.known = @($o.known | Where-Object { $_ }); $r = [pscustomobject]$o
  # 2.2.0: a 2.1 file (CurrentUser) or one still in secrets\ is moved into vault\ as LocalMachine the first time it is read
  if (-not $r.unreadable -and $oldName) { try { Save-FsSecrets $dir $r; Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } catch {} }   # 2.2.3: old file name -> the exact-site name
  if (-not $r.unreadable -and ($script:FsLastWasLegacy -or $fromLegacy) -and -not $script:FsTestSecrets) { try { Save-FsSecrets $dir $r; if ($fromLegacy) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }; Fs-LogLine 'secret store moved to the machine-wide (LocalMachine) store' } catch {} }
  return $r
}
# A first save must be private even when the installer has never run. LocalMachine DPAPI is readable by anyone who can read
# the file, so create and protect the directory BEFORE a password (including its temporary file) is written.
$script:FsVaultAcl = $null   # tests: { param($dir) -> bool }
function Initialize-FsSecretDirectory([string]$dir) {
  New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null
  if ($script:FsTestSecrets) { return }
  if ($script:FsVaultAcl) { if (-not (& $script:FsVaultAcl $dir)) { throw 'The password folder could not be made private. No password was saved.' }; return }
  if ($env:OS -ne 'Windows_NT') { return }
  $sids = @('S-1-5-32-544', 'S-1-5-18', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) | Select-Object -Unique
  $di = New-Object IO.DirectoryInfo($dir)
  # 2.2.6: only the DACL (who may open it) is read and written. Set-Acl on Windows PowerShell 5.1 also writes the audit list (SACL),
  # which needs SeSecurityPrivilege, so a normal (not "Run as administrator") login could not save a password at all in 2.2.5.
  $cur = $null; try { $cur = $(if ($PSVersionTable.PSEdition -eq 'Core') { [IO.FileSystemAclExtensions]::GetAccessControl($di, [Security.AccessControl.AccessControlSections]::Access) } else { $di.GetAccessControl([Security.AccessControl.AccessControlSections]::Access) }) } catch { $cur = $null }
  if ($cur -and $cur.AreAccessRulesProtected) {
    $have = @($cur.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
    if (($have -join ',') -eq ((@($sids) | Sort-Object -Unique) -join ',')) { return }   # already private exactly like this
  }
  $acl = New-Object Security.AccessControl.DirectorySecurity
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($sid in $sids) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
  }
  # a new security object with only access rules: SetAccessControl persists the DACL alone (no owner, no SACL)
  if ($PSVersionTable.PSEdition -eq 'Core') { [IO.FileSystemAclExtensions]::SetAccessControl($di, $acl) } else { $di.SetAccessControl($acl) }
}
function Save-FsSecrets([string]$dir, $sec) {
  $ErrorActionPreference = 'Stop'
  Initialize-FsSecretDirectory $dir
  $keep = [ordered]@{ site = $sec.site; password = $sec.password; known = @($sec.known); nvr = $sec.nvr; cams = $(if ($sec.PSObject.Properties['cams'] -and $sec.cams) { $sec.cams } else { @{} }); rollback = $sec.rollback; bitwardenSaved = [bool]$sec.bitwardenSaved; shownOnce = [bool]$sec.shownOnce; updated = (Get-Date -Format 's') }
  $p = Get-FsSecretPath $dir $sec.site; $tmp = $p + '.tmp'
  $enc = Protect-FsText ($keep | ConvertTo-Json -Depth 6 -Compress)
  [IO.File]::WriteAllText($tmp, $enc)
  Move-Item -LiteralPath $tmp -Destination $p -Force -ErrorAction Stop
  # 2.2.20 (Codex 2.2.19 class A sweep): the site's passwords (and the old ones Undo needs) count as saved only when the file in
  # place reads back exactly as written; otherwise this throws and the change it protects is not made
  if ([IO.File]::ReadAllText($p) -cne $enc) { throw ('the site secret store does not read back as it was saved (' + $p + ')') }
}
# 2.0.3 (Moshe, Nov 4 2026: "There are no usual passwords. Every single password is specific to that site."): ONE password per site,
# made as <his word> + 4 random digits, different for every site. The word is NOT in this public code: it comes from config.json
# (fixSite.sitePasswordPrefix, never shipped by the updater) or is typed once and kept encrypted on this PC (secrets\password-word.dat).
function Test-FsSitePrefix([string]$p) { return ($p -cmatch '^[A-Za-z][A-Za-z0-9]{3,15}$') }
function Get-FsSitePrefix($cfg, [string]$dir) {
  $p = ''
  if ($cfg -and $cfg.PSObject.Properties['sitePasswordPrefix']) { $p = [string]$cfg.sitePasswordPrefix }
  if (-not (Test-FsSitePrefix $p)) {
    $p = ''; $f = Join-Path $dir 'password-word.dat'
    if (-not (Test-Path -LiteralPath $f) -and $script:FsLegacySecretsDir) { $f2 = Join-Path $script:FsLegacySecretsDir 'password-word.dat'; if (Test-Path -LiteralPath $f2) { $f = $f2 } }
    if (Test-Path -LiteralPath $f) {
      $script:FsLastWasLegacy = $false
      try { $p = Unprotect-FsText ((Get-Content -LiteralPath $f -Raw).Trim()) } catch { $p = ''; $script:FsPrefixUnreadable = [string]$_.Exception.Message }
      if ($p -and (Test-FsSitePrefix $p) -and ($script:FsLastWasLegacy -or $f -ne (Join-Path $dir 'password-word.dat')) -and -not $script:FsTestSecrets) { try { Save-FsSitePrefix $dir $p } catch {} }
    }
  }
  if (-not (Test-FsSitePrefix $p)) { $p = '' }
  return $p
}
function Save-FsSitePrefix([string]$dir, [string]$p) { Initialize-FsSecretDirectory $dir; [IO.File]::WriteAllText((Join-Path $dir 'password-word.dat'), (Protect-FsText $p)) }
# 2.2.0: Install-Toolkit (run as an admin) moves every 2.1 store it can read into vault\ as LocalMachine. Returns { moved; unreadable = @(files) }.
function Convert-FsSecretStores([string]$FromDir, [string]$ToDir) {
  $moved = 0; $bad = @()
  if (-not (Test-Path -LiteralPath $FromDir)) { return [pscustomobject]@{ moved = 0; unreadable = @() } }
  Initialize-FsSecretDirectory $ToDir
  foreach ($f in @(Get-ChildItem -LiteralPath $FromDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'site-*.dat' -or $_.Name -eq 'password-word.dat' })) {
    $dst = Join-Path $ToDir $f.Name
    if (Test-Path -LiteralPath $dst) { continue }
    try { $t = Unprotect-FsText ((Get-Content -LiteralPath $f.FullName -Raw).Trim()); [IO.File]::WriteAllText($dst, (Protect-FsText $t)); Remove-Item -LiteralPath $f.FullName -Force; $moved++ } catch { $bad += $f.Name }
  }
  foreach ($d in @(Get-ChildItem -LiteralPath $FromDir -Directory -Filter 'hikreset-*' -ErrorAction SilentlyContinue)) { $dd = Join-Path $ToDir $d.Name; if (-not (Test-Path -LiteralPath $dd)) { try { Move-Item -LiteralPath $d.FullName -Destination $dd; $moved++ } catch {} } }
  return [pscustomobject]@{ moved = $moved; unreadable = @($bad) }
}
function New-FsSitePassword([string]$prefix) {
  # <prefix> + 4 random digits (crypto random). No 3 same digits in a row and no straight run (1234 / 9876): cameras flag those as weak.
  if (-not (Test-FsSitePrefix $prefix)) { throw 'site password prefix missing' }
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    for ($t = 0; $t -lt 100; $t++) {
      $d = -join (1..4 | ForEach-Object { [string](Get-FsRandom $rng 10) })
      $run = $true; $runDown = $true; for ($i = 1; $i -lt 4; $i++) { if ([int][string]$d[$i] -ne [int][string]$d[$i - 1] + 1) { $run = $false }; if ([int][string]$d[$i] -ne [int][string]$d[$i - 1] - 1) { $runDown = $false } }
      if ($d -notmatch '(\d)\1\1' -and -not $run -and -not $runDown) { return ($prefix + $d) }
    }
    return ($prefix + $d)
  } finally { $rng.Dispose() }
}

# 2.2.1 (review M1): a made site password is fully random (no shared word, no shared part with any other site), 14 characters
# (inside every camera's 8-16 limit), upper + lower + digits, no look-alike characters, no symbols (some Dahua/ONVIF screens refuse them),
# and never the same as a password any other site on this PC has (checked against every store this PC can read).
$script:FsPwSets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnpqrstuvwxyz', '23456789')
function New-FsRandomSitePassword([string[]]$Avoid = @(), [int]$Length = 14) {
  if ($Length -lt 10) { $Length = 10 }; if ($Length -gt 16) { $Length = 16 }
  $all = -join $script:FsPwSets
  $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
  try {
    for ($t = 0; $t -lt 200; $t++) {
      $c = New-Object System.Collections.Generic.List[char]
      foreach ($set in $script:FsPwSets) { $c.Add($set[(Get-FsRandom $rng $set.Length)]) }
      while ($c.Count -lt $Length) { $c.Add($all[(Get-FsRandom $rng $all.Length)]) }
      for ($i = $c.Count - 1; $i -gt 0; $i--) { $j = Get-FsRandom $rng ($i + 1); $x = $c[$i]; $c[$i] = $c[$j]; $c[$j] = $x }
      $pw = -join $c
      if ($pw -cmatch '(.)\1\1') { continue }                  # no 3 of the same in a row (cameras call that weak)
      if (@($Avoid | Where-Object { $_ -and $_ -ceq $pw }).Count) { continue }
      return $pw
    }
    throw 'could not make a unique site password'
  } finally { $rng.Dispose() }
}
# every password the OTHER sites saved on this PC use (their site password and the ones typed there): a new one must differ from all
function Get-FsOtherSitePasswords([string]$dir, [string]$site) {
  $out = New-Object System.Collections.Generic.List[string]
  if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return @() }
  $mine = Split-Path -Leaf (Get-FsSecretPath $dir $site)
  foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'site-*.dat' -File -ErrorAction SilentlyContinue)) {
    if ($f.Name -eq $mine) { continue }
    try { $j = (Unprotect-FsText ((Get-Content -LiteralPath $f.FullName -Raw).Trim())) | ConvertFrom-Json; foreach ($p in @($j.password) + @($j.known)) { if ($p) { $out.Add([string]$p) } } } catch {}
  }
  return @($out)
}
# ---------------- Bitwarden: FixSiteBw.ps1 (2.2.2: also used by the Toolkit window, on the tech's own login) ----------------
. (Join-Path $PSScriptRoot 'FixSiteBw.ps1')
function Get-FsRandom($rng, [int]$n) { $b = New-Object byte[] 4; do { $rng.GetBytes($b); $v = [BitConverter]::ToUInt32($b, 0) } while ($v -ge ([uint32]::MaxValue - ([uint32]::MaxValue % [uint32]$n))); return [int]($v % [uint32]$n) }

# ---------------- Dahua search (read-only, the same packet ConfigTool sends; answers even from the wrong IP scheme) ----------------
function ConvertFrom-FsDhipAnswer([byte[]]$b, [string]$from = '') {
  # 32-byte DHIP header, then JSON {"method":"client.notifyDevInfo","params":{"deviceInfo":{...}}}
  $s = [Text.Encoding]::UTF8.GetString($b); $i = $s.IndexOf('{'); if ($i -lt 0) { return $null }
  try { $j = $s.Substring($i).TrimEnd([char]0, "`n", "`r") | ConvertFrom-Json } catch { return $null }
  $di = $null; if ($j.PSObject.Properties['params'] -and $j.params.PSObject.Properties['deviceInfo']) { $di = $j.params.deviceInfo }; if (-not $di) { return $null }
  $v4 = $di.IPv4Address; $ip = $(if ($v4) { [string]$v4.IPAddress } else { $from })
  if (-not $ip) { return $null }
  $mac = ''; if ($di.PSObject.Properties['MAC']) { $mac = [string]$di.MAC } elseif ($j.PSObject.Properties['mac']) { $mac = [string]$j.mac }
  $type = [string]$di.DeviceType; $kind = $(if ($type -match '(?i)NVR|XVR|DVR|HCVR') { 'nvr' } else { 'camera' })
  $init = $true; if ($di.PSObject.Properties['Init'] -and [string]$di.Init -match '^(0|false|uninit)') { $init = $false }
  return [pscustomobject]@{ brand = 'Dahua'; model = $type; serial = [string]$di.SerialNo; mac = $mac; ip = $ip; firmware = [string]$di.Version; kind = $kind; activated = $init; dhcp = ($v4 -and [string]$v4.DhcpEnable -eq 'True') }
}
function Find-FsDahua([int]$seconds = 4) {
  $out = @{}
  $body = [Text.Encoding]::UTF8.GetBytes('{"method":"DHDiscover.search","params":{"mac":"","uni":1}}' + "`n")
  $hdr = New-Object byte[] 32; [byte[]]$m = 0x20, 0, 0, 0, 0x44, 0x48, 0x49, 0x50; [Array]::Copy($m, $hdr, 8)
  [Array]::Copy([BitConverter]::GetBytes([int]$body.Length), 0, $hdr, 16, 4); [Array]::Copy([BitConverter]::GetBytes([int]$body.Length), 0, $hdr, 24, 4)
  $pkt = New-Object byte[] (32 + $body.Length); [Array]::Copy($hdr, $pkt, 32); [Array]::Copy($body, 0, $pkt, 32, $body.Length)
  $u = $null
  try {
    $u = New-Object Net.Sockets.UdpClient; $u.Client.SetSocketOption('Socket', 'ReuseAddress', $true); $u.Client.Bind((New-Object Net.IPEndPoint([Net.IPAddress]::Any, 37810)))
    try { $u.JoinMulticastGroup([Net.IPAddress]::Parse('239.255.255.251')) } catch {}
    $u.EnableBroadcast = $true; $u.Client.ReceiveTimeout = 500
    foreach ($dst in @('239.255.255.251', '255.255.255.255')) { try { [void]$u.Send($pkt, $pkt.Length, (New-Object Net.IPEndPoint([Net.IPAddress]::Parse($dst), 37810))) } catch {} }
    $end = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $end) {
      try { $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0); $b = $u.Receive([ref]$ep); $d = ConvertFrom-FsDhipAnswer $b $ep.Address.ToString(); if ($d -and -not $out.ContainsKey($d.ip)) { $out[$d.ip] = $d } } catch {}
    }
  } catch { Fs-LogLine ('Dahua search could not run: ' + $_.Exception.Message) } finally { if ($u) { $u.Close() } }
  return @($out.Values)
}

# 2.1.0: which NVR channel a camera goes on: the one that already holds its address, else the one that held its OLD address, else the first
# empty channel, else the first channel that is offline (a plug-and-play slot nobody uses). Never an online channel of another camera.
function Get-FsFreeNvrChannel($Channels, [string]$CamIp, [string]$OldIp = '', [int[]]$Taken = @()) {
  $c = @($Channels)
  foreach ($ip in @($CamIp, $OldIp)) { if (-not $ip) { continue }; $m = $c | Where-Object { $_.ip -eq $ip -and [int]$_.channel -notin $Taken } | Select-Object -First 1; if ($m) { return [int]$m.channel } }
  $m = $c | Where-Object { (-not $_.ip -or $_.ip -eq '0.0.0.0') -and [int]$_.channel -notin $Taken } | Sort-Object { [int]$_.channel } | Select-Object -First 1; if ($m) { return [int]$m.channel }
  # 2.2.3 (Codex #15): an OFFLINE (or unknown) channel that points at another camera is that camera's slot, not a free one
  return 0
}

# 2.2.3: moved here from WireItAcl.ps1 (removed with the Crew/SYSTEM split); the installer blanks 2.1's logged site-password word
function Clear-WordAnswerFromLogs([string[]]$LogRoots) {
  $n = 0
  foreach ($r in @($LogRoots)) {
    if (-not $r -or -not (Test-Path -LiteralPath $r)) { continue }
    foreach ($f in @(Get-ChildItem -LiteralPath $r -Recurse -Filter 'log.txt' -File -ErrorAction SilentlyContinue)) {
      try {
        $lines = [IO.File]::ReadAllLines($f.FullName); $chg = $false
        for ($i = 0; $i -lt $lines.Count - 1; $i++) {
          if ($lines[$i] -match 'ASK Site passwords start with your word' -and $lines[$i + 1] -match '^(\d\d:\d\d:\d\d )?ANSWER (?!\(hidden\))') { $lines[$i + 1] = ($Matches[1] + 'ANSWER (hidden)'); $chg = $true; $n++ }
        }
        if ($chg) { [IO.File]::WriteAllLines($f.FullName, $lines) }
      } catch {}
    }
  }
  return $n
}
