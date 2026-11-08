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
    # test harness: the mock answers 599 "MOCKNET:<kind>" for what a real device does on the wire (port closed, no answer, bad TLS)
    if ($script:FsMockUrl -and $code -eq 599 -and $eb -match '^MOCKNET:(\w+)') { $code = 0; $err = $Matches[1]; $eb = '' }
    Fs-LogLine ('  -> ' + $code + ' ' + $_.Exception.Message + $(if ($err) { ' [' + $err + ']' } else { '' }))
    return [pscustomobject]@{ code = $code; body = $eb; err = $err }
  }
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
function Fs-HikOk($r) { if (-not $r -or $r.code -ne 200) { return $false }; $x = Fs-XmlDoc $r.body; if (-not $x) { return $true }; $sc = Fs-XText $x 'statusCode'; return (-not $sc -or $sc -eq '1' -or $sc -eq '7') }
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
function Test-FsLogin([string]$ip, [string]$brand, [string]$pw) {
  $k = ($ip -replace ':\d+$', '')
  if ($pw -and $script:FsLoginFails.ContainsKey($k) -and [int]$script:FsLoginFails[$k] -ge $script:FsMaxLoginFails) { Fs-LogLine ('login to ' + $k + ' not tried: ' + $script:FsMaxLoginFails + ' wrong passwords this run already'); return 'locked' }
  $s = Test-FsLoginOnce $ip $brand $pw
  if ($pw -and $s -eq 'refused') { $script:FsLoginFails[$k] = 1 + [int]$script:FsLoginFails[$k] }
  return $s
}
function Test-FsLoginOnce([string]$ip, [string]$brand, [string]$pw) {
  # 'ok' | 'refused' | 'locked' | 'noanswer' | 'notfound'
  $cred = Fs-Cred $pw
  if ($brand -eq 'Dahua') {
    $r = Fs-Http -Ip $ip -Path '/cgi-bin/magicBox.cgi?action=getDeviceType' -Cred $cred -Timeout 6
    if ($r.code -eq 200) { return 'ok' }; if ($r.code -eq 401) { if ($r.body -match '(?i)lock') { return 'locked' }; return 'refused' }; if ($r.code -eq 404) { return 'notfound' }; return 'noanswer'
  }
  $r = Fs-Http -Ip $ip -Path '/ISAPI/System/deviceInfo' -Cred $cred -Timeout 6
  if ($r.code -eq 200) { return 'ok' }
  if ($r.code -eq 401 -or $r.code -eq 403) { if ($r.body -match '(?i)lock|unlockTime') { return 'locked' }; return 'refused' }
  if ($r.code -eq 404 -and $brand -ne 'Hikvision') { return (Test-FsLoginOnce $ip 'Dahua' $pw) }
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
    if ($s -eq 'noanswer' -or $s -eq 'notfound') { return [pscustomobject]@{ state = 'noanswer'; label = ''; value = ''; tries = $n } }
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
function Save-FsBackup([string]$ip, [string]$brand, $cred, [string]$dir) {
  # the camera's own config export (its import format) + readable network / video settings. Stays on this PC (run folder).
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $files = @()
  if ($brand -eq 'Dahua') {
    $f = Join-Path $dir 'config-export.backup'; $r = Fs-Http -Ip $ip -Path '/cgi-bin/Config.backup?action=All' -Cred $cred -OutFile $f -Timeout 20
    if ((Test-Path $f) -and (Get-Item $f).Length -gt 0) { $files += $f } else { Remove-Item $f -ErrorAction SilentlyContinue }
    foreach ($n in @('Network', 'Encode', 'SmartEncode', 'NTP')) { $r = Fs-Http -Ip $ip -Path ('/cgi-bin/configManager.cgi?action=getConfig&name=' + $n) -Cred $cred; if ($r.code -eq 200) { $p = Join-Path $dir ($n + '.txt'); [IO.File]::WriteAllText($p, $r.body); $files += $p } }
  } else {
    $f = Join-Path $dir 'configurationData.bin'; $r = Fs-Http -Ip $ip -Path '/ISAPI/System/configurationData' -Cred $cred -OutFile $f -Timeout 30
    if ((Test-Path $f) -and (Get-Item $f).Length -gt 0) { $files += $f } else { Remove-Item $f -ErrorAction SilentlyContinue }
    foreach ($pp in @(@('network.xml', '/ISAPI/System/Network/interfaces'), @('stream-101.xml', '/ISAPI/Streaming/channels/101'), @('stream-102.xml', '/ISAPI/Streaming/channels/102'), @('time.xml', '/ISAPI/System/time'))) {
      $r = Fs-Http -Ip $ip -Path $pp[1] -Cred $cred; if ($r.code -eq 200) { $p = Join-Path $dir $pp[0]; [IO.File]::WriteAllText($p, $r.body); $files += $p }
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
  # (cameras: AND the main stream). One stray file (time.xml) is not a backup.
  $names = @(@($files) | ForEach-Object { if ($_) { (Split-Path -Leaf ([string]$_)).ToLower() } })
  if ($brand -eq 'Dahua') { $need = @('config-export.backup', 'network.txt'); if (-not $Nvr) { $need += 'encode.txt' } }
  else { $need = @('configurationdata.bin', 'network.xml'); if (-not $Nvr) { $need += 'stream-101.xml' } }
  foreach ($n in $need) { if ($names -notcontains $n) { return $false } }
  return $true
}

# ---------------- network ----------------
function Get-FsNet([string]$ip, [string]$brand, $cred) {
  if ($brand -eq 'Dahua') {
    $h = Fs-DhLines (Fs-Http -Ip $ip -Path '/cgi-bin/configManager.cgi?action=getConfig&name=Network' -Cred $cred).body
    $if = [string]$h['Network.DefaultInterface']; if (-not $if) { $if = 'eth0' }
    $pre = 'Network.' + $if + '.'
    return [pscustomobject]@{ iface = $if; ip = [string]$h[$pre + 'IPAddress']; mask = [string]$h[$pre + 'SubnetMask']; gw = [string]$h[$pre + 'DefaultGateway']; dhcp = ([string]$h[$pre + 'DhcpEnable'] -eq 'true'); dns1 = [string]$h[$pre + 'DnsServers[0]']; dns2 = [string]$h[$pre + 'DnsServers[1]']; raw = $null }
  }
  $li = Fs-XmlDoc (Fs-Http -Ip $ip -Path '/ISAPI/System/Network/interfaces' -Cred $cred).body
  # 2.2.3 (Codex #10): a recorder with a LAN port and a PoE camera port has two interfaces; the one to read/change is the one
  # carrying the address we are talking to. One interface = that one. Several and none carries it = $null (nothing is changed).
  $ids = @(); if ($li) { foreach ($nd in @(Fs-XFind $li 'NetworkInterface')) { $v = Fs-XText $nd 'id'; if ($v) { $ids += $v } } }
  if (-not $ids.Count) { $ids = @('1') }
  $want = ($ip -replace ':\d+$', ''); $r = $null; $x = $null; $id = ''
  foreach ($cand in $ids) {
    $rr = Fs-Http -Ip $ip -Path ('/ISAPI/System/Network/interfaces/' + $cand + '/ipAddress') -Cred $cred; $xx = Fs-XmlDoc $rr.body
    if (-not $xx) { continue }
    if ($ids.Count -eq 1 -or (Fs-XText $xx 'ipAddress') -eq $want) { $r = $rr; $x = $xx; $id = $cand; break }
  }
  if (-not $x) { return $null }
  $gwn = @(Fs-XFind $x 'DefaultGateway'); $gw = ''; if ($gwn.Count) { $gw = Fs-XText $gwn[0] 'ipAddress' }
  $d1 = @(Fs-XFind $x 'PrimaryDNS'); $d2 = @(Fs-XFind $x 'SecondaryDNS')
  return [pscustomobject]@{ iface = $id; ip = (Fs-XText $x 'ipAddress'); mask = (Fs-XText $x 'subnetMask'); gw = $gw; dhcp = ((Fs-XText $x 'addressingType') -eq 'dynamic'); dns1 = $(if ($d1.Count) { Fs-XText $d1[0] 'ipAddress' } else { '' }); dns2 = $(if ($d2.Count) { Fs-XText $d2[0] 'ipAddress' } else { '' }); raw = $r.body }
}
function Set-FsNet([string]$ip, [string]$brand, $cred, $net, [string]$newIp, [string]$mask, [string]$gw, [string]$dns1 = '8.8.8.8', [string]$dns2 = '1.1.1.1', [switch]$Dhcp) {
  # returns { ok; reboot } . The device answers on the NEW address afterwards (or after its own restart).
  # 2.2.1 (review H8): -Dhcp = undo of a device that got its address from the router: it goes back to DHCP (address fields as saved).
  if (-not $mask) { $mask = '255.255.255.0' }
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

# ---------------- password ----------------
function Resolve-FsPwChange([string]$ip, [string]$brand, [string]$newPw, [string]$oldPw) {
  # 2.2.3 (Codex #19): after a password write, what the device REALLY has: 'changed' (new logs in), 'unchanged' (old still logs in)
  # or 'unknown' (neither answers now: the write may have taken). One login try each; 'unknown' is bookkept as maybe-changed.
  if ((Test-FsLogin $ip $brand $newPw) -eq 'ok') { return 'changed' }
  if ($oldPw -and (Test-FsLogin $ip $brand $oldPw) -eq 'ok') { return 'unchanged' }
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
    $sc = Fs-DhLines (Fs-Http -Ip $ip -Path '/cgi-bin/configManager.cgi?action=getConfig&name=SmartEncode' -Cred $cred).body
    $scv = ''; foreach ($k in $sc.Keys) { if ($k -match 'SmartEncode\[0\]\.Enable$') { $scv = $(if ($sc[$k] -eq 'true') { 'on' } else { 'off' }) } }
    return [pscustomobject]@{ codec = ([string]$h[$p + 'Compression'] -replace 'H\.?26', 'H.26'); fps = [int][double]$h[$p + 'FPS']; width = [int]$h[$p + 'Width']; height = [int]$h[$p + 'Height']; bitrate = [int]$h[$p + 'BitRate']; gop = [int]$h[$p + 'GOP']; smartCodec = $scv; maxWidth = 0; maxHeight = 0; raw = $null }
  }
  $r = Fs-Http -Ip $ip -Path '/ISAPI/Streaming/channels/101' -Cred $cred; $x = Fs-XmlDoc $r.body; if (-not $x) { return $null }
  $q = Fs-XText $x 'videoQualityControlType'; $br = $(if ($q -eq 'VBR') { Fs-XText $x 'vbrUpperCap' } else { Fs-XText $x 'constantBitRate' })
  $scn = @(Fs-XFind $x 'SmartCodec'); $sc = ''; if ($scn.Count) { $sc = $(if ((Fs-XText $scn[0] 'enabled') -eq 'true') { 'on' } else { 'off' }) }
  $mw = 0; $mh = 0
  $cap = Fs-XmlDoc (Fs-Http -Ip $ip -Path '/ISAPI/Streaming/channels/101/capabilities' -Cred $cred).body
  if ($cap) { $wn = @(Fs-XFind $cap 'videoResolutionWidth'); if ($wn.Count -and $wn[0].opt) { $mw = [int](@($wn[0].opt -split ',' | ForEach-Object { [int]$_ } | Sort-Object -Descending)[0]) }; $hn = @(Fs-XFind $cap 'videoResolutionHeight'); if ($hn.Count -and $hn[0].opt) { $mh = [int](@($hn[0].opt -split ',' | ForEach-Object { [int]$_ } | Sort-Object -Descending)[0]) } }
  return [pscustomobject]@{ codec = ((Fs-XText $x 'videoCodecType') -replace '^H\.?26', 'H.26'); fps = [int]([int](Fs-XText $x 'maxFrameRate') / 100); width = [int](Fs-XText $x 'videoResolutionWidth'); height = [int](Fs-XText $x 'videoResolutionHeight'); bitrate = [int]$br; gop = [int](Fs-XText $x 'GovLength'); smartCodec = $sc; maxWidth = $mw; maxHeight = $mh; raw = $r.body }
}
function Set-FsStream([string]$ip, [string]$brand, $cred, $current, $diff) {
  # applies ONLY the fields in $diff (from Get-FsSettingsDiff). Returns { ok; reboot }
  if (-not @($diff).Count) { return [pscustomobject]@{ ok = $true; reboot = $false } }
  if ($brand -eq 'Dahua') {
    $p = 'Encode[0].MainFormat[0].Video.'; $kv = @{}; $smart = $null
    foreach ($d in @($diff)) {
      switch ($d.field) {
        'codec' { $kv[$p + 'Compression'] = [string]$d.to; if ([string]$d.to -eq 'H.264') { $kv[$p + 'Profile'] = 'Main' } }
        'fps' { $kv[$p + 'FPS'] = [string]$d.to } 'bitrate' { $kv[$p + 'BitRate'] = [string]$d.to } 'gop' { $kv[$p + 'GOP'] = [string]$d.to }
        'resolution' { $wh = ([string]$d.to) -split 'x'; $kv[$p + 'Width'] = $wh[0]; $kv[$p + 'Height'] = $wh[1] }
        'smartCodec' { $smart = 'false' }
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
function Get-FsNvrChannels([string]$nvrIp, $cred) {
  $r = Fs-Http -Ip $nvrIp -Path '/ISAPI/ContentMgmt/InputProxy/channels' -Cred $cred
  $x = Fs-XmlDoc $r.body; if (-not $x) { return $null }
  $st = Fs-XmlDoc (Fs-Http -Ip $nvrIp -Path '/ISAPI/ContentMgmt/InputProxy/channels/status' -Cred $cred).body
  $on = @{}; foreach ($s in (Fs-XFind $st 'InputProxyChannelStatus')) { $on[[int](Fs-XText $s 'id')] = ((Fs-XText $s 'online') -eq 'true') }
  $out = @()
  foreach ($c in (Fs-XFind $x 'InputProxyChannel')) {
    $id = [int](Fs-XText $c 'id')
    $out += [pscustomobject]@{ channel = $id; name = (Fs-XText $c 'name'); ip = (Fs-XText $c 'ipAddress'); port = (Fs-XText $c 'managePortNo'); protocol = (Fs-XText $c 'proxyProtocol'); online = $(if ($on.ContainsKey($id)) { $on[$id] } else { $null }) }
  }
  return $out
}
function Set-FsNvrChannel([string]$nvrIp, $nvrCred, [int]$ch, [string]$camIp, [string]$camPw, [string]$camBrand, [string]$backupDir = '') {
  # puts the camera on that channel with its new address + the site password. Updates the channel when it exists, adds it when not.
  # returns { ok; action ('updated'|'added'|'failed'); before (xml, no password: the NVR never returns it) }
  $r = Fs-Http -Ip $nvrIp -Path ('/ISAPI/ContentMgmt/InputProxy/channels/' + $ch) -Cred $nvrCred
  $proto = $(if ($camBrand -eq 'Hikvision') { 'HIKVISION' } else { 'ONVIF' }); $port = $(if ($proto -eq 'HIKVISION') { '8000' } else { '80' })
  if ($r.code -eq 200 -and ($x = Fs-XmlDoc $r.body)) {
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
function Remove-FsNvrChannel([string]$nvrIp, $nvrCred, [int]$ch) {
  $w = Fs-Http -Ip $nvrIp -Method 'DELETE' -Path ('/ISAPI/ContentMgmt/InputProxy/channels/' + $ch) -Cred $nvrCred
  return (Fs-HikOk $w)
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
function Invoke-FsNetOp([string]$op, [hashtable]$a) {
  if ($script:FsNetOps -and $script:FsNetOps.ContainsKey($op)) { return (& $script:FsNetOps[$op] $a) }
  $ix = [int]$a.ifIndex
  switch ($op) {
    'state' {
      $ipi = Get-NetIPInterface -InterfaceIndex $ix -AddressFamily IPv4 -ErrorAction SilentlyContinue
      $co = 'unknown'; try { $t = (netsh interface ipv4 show interface ([string]$ix)) -join "`n"; $m = [regex]::Match($t, '(?i)DHCP/Static IP coexistence\s*:\s*(\w+)'); if ($m.Success) { $co = $m.Groups[1].Value.ToLower() } } catch {}
      $ad = @(Get-NetIPAddress -InterfaceIndex $ix -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ ip = [string]$_.IPAddress; prefix = [int]$_.PrefixLength; origin = [string]$_.PrefixOrigin; skip = [bool]$_.SkipAsSource; store = [string]$_.PolicyStore; addrState = [string]$_.AddressState } })
      $gw = @(Get-NetRoute -InterfaceIndex $ix -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.NextHop } | Select-Object -Unique)
      return [pscustomobject]@{ dhcp = ($ipi -and [string]$ipi.Dhcp -eq 'Enabled'); coexist = $co; addrs = $ad; gw = $gw }
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
function Test-FsIpFree([string]$ip) {
  if ($script:FsNetOps -and $script:FsNetOps.ContainsKey('free')) { return [bool](& $script:FsNetOps['free'] @{ ip = $ip }) }
  if ($script:FsMockUrl) { $r = Fs-Http -Ip '_pc' -Path ('/free?ip=' + $ip); return ($r.body -match 'true') }
  try { if ((New-Object Net.NetworkInformation.Ping).Send($ip, 700).Status -eq 'Success') { return $false } } catch {}
  $n = Get-NetNeighbor -IPAddress $ip -ErrorAction SilentlyContinue | Where-Object { $_.State -in @('Reachable', 'Stale', 'Permanent') -and $_.LinkLayerAddress -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' }
  return (-not $n)
}
function Save-FsNetState([string]$stateFile) {
  if (-not $stateFile) { return }
  $o = [ordered]@{ version = 2; written = (Get-Date -Format 's'); before = $script:FsPcBefore; coexistChanged = [bool]$script:FsCoexistChanged; temps = @($script:FsTemps) }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $stateFile) | Out-Null
  $tmp = $stateFile + '.tmp'; [IO.File]::WriteAllText($tmp, ($o | ConvertTo-Json -Depth 6)); Move-Item -LiteralPath $tmp -Destination $stateFile -Force
}
function Add-FsTempIp([string]$p3, $pc, [string]$stateFile) {
  # memory-only (ActiveStore) extra address on the old scheme; never used as a source for normal traffic; removed at the end
  foreach ($t in $script:FsTemps) { if ($t.p3 -eq $p3) { return $t.ip } }
  if ($script:FsMockUrl -and -not $script:FsNetOps) { $r = Fs-Http -Ip '_pc' -Path ('/addtemp?p3=' + $p3); $ip = $p3 + '.253'; [void]$script:FsTemps.Add([pscustomobject]@{ p3 = $p3; ip = $ip; ifIndex = 0 }); return $ip }
  if (-not $pc) { return '' }
  # 1) the adapter as it is now, saved BEFORE anything changes
  if (-not $script:FsPcBefore) {
    try { $st = Invoke-FsNetOp 'state' @{ ifIndex = $pc.ifIndex } } catch { Fs-LogLine ('could not read this PC''s network settings - no temporary address added: ' + $_.Exception.Message); return '' }
    $script:FsPcBefore = [pscustomobject]@{ ifIndex = [int]$pc.ifIndex; name = [string]$pc.name; dhcp = [bool]$st.dhcp; coexist = [string]$st.coexist; addrs = @($st.addrs | Where-Object { -not $_.skip }); gw = @($st.gw) }
    Save-FsNetState $stateFile
  }
  # 2) a DHCP adapter keeps DHCP while it has an extra fixed address (Windows can switch DHCP off otherwise: review H4)
  if ($script:FsPcBefore.dhcp -and $script:FsPcBefore.coexist -ne 'enabled' -and -not $script:FsCoexistChanged) {
    $okc = $false; try { $okc = [bool](Invoke-FsNetOp 'coexist' @{ ifIndex = $pc.ifIndex; on = $true }) } catch {}
    if (-not $okc) { Fs-LogLine 'could not turn on DHCP+static coexistence on this PC - no temporary address added (DHCP would be lost)'; return '' }
    $script:FsCoexistChanged = $true; Save-FsNetState $stateFile
  }
  foreach ($h in @(253, 252, 247, 246, 245)) {
    $ip = $p3 + '.' + $h; if (-not (Test-FsIpFree $ip)) { continue }
    $t = [pscustomobject]@{ p3 = $p3; ip = $ip; ifIndex = [int]$pc.ifIndex }
    [void]$script:FsTemps.Add($t); Save-FsNetState $stateFile   # written BEFORE the address goes on: a crash in between is still cleaned up
    try {
      $st = [string](Invoke-FsNetOp 'addtemp' @{ ifIndex = $pc.ifIndex; ip = $ip; prefix = 24 })
      if ($st -eq 'Duplicate') { Fs-LogLine ('temp IP ' + $ip + ' is used by another device - trying the next'); [void](Invoke-FsNetOp 'remove' @{ ifIndex = $pc.ifIndex; ip = $ip }); [void]$script:FsTemps.Remove($t); Save-FsNetState $stateFile; continue }
      if (-not $script:FsNetOps) { Start-Sleep -Seconds 1 }
      return $ip
    } catch { Fs-LogLine ('temp IP ' + $ip + ' failed: ' + $_.Exception.Message); try { [void](Invoke-FsNetOp 'remove' @{ ifIndex = $pc.ifIndex; ip = $ip }) } catch {}; [void]$script:FsTemps.Remove($t); Save-FsNetState $stateFile }
  }
  return ''
}
function Restore-FsPcNet([string]$stateFile) {
  # takes every temporary address off, then puts the adapter back the way it was (DHCP, coexistence, its own addresses, its router).
  # Returns { ok; problems }. The saved state is kept (and tried again next start) unless every part checked back to normal.
  $problems = @()
  $ix = $(if ($script:FsPcBefore) { [int]$script:FsPcBefore.ifIndex } else { -1 })
  foreach ($t in @($script:FsTemps)) { try { [void](Invoke-FsNetOp 'remove' @{ ifIndex = $t.ifIndex; ip = $t.ip }) } catch {}; if ($ix -lt 0) { $ix = [int]$t.ifIndex } }
  if ($ix -ge 0 -and ($script:FsPcBefore -or @($script:FsTemps).Count)) {
    $now = $null; try { $now = Invoke-FsNetOp 'state' @{ ifIndex = $ix } } catch { $problems += ('could not read the network settings back: ' + $_.Exception.Message) }
    if ($now) {
      $left = @(); foreach ($t in @($script:FsTemps)) { if (@($now.addrs | Where-Object { $_.ip -eq $t.ip }).Count) { $left += $t; $problems += ('the temporary address ' + $t.ip + ' is still on the adapter') } }
      $script:FsTemps.Clear(); foreach ($t in $left) { [void]$script:FsTemps.Add($t) }
      $b = $script:FsPcBefore
      if ($b) {
        if ($b.dhcp -and -not $now.dhcp) { try { [void](Invoke-FsNetOp 'dhcp' @{ ifIndex = $ix; on = $true }); Fs-LogLine 'DHCP switched back on for this PC' } catch { $problems += ('DHCP could not be switched back on: ' + $_.Exception.Message) } }
        if (-not $b.dhcp) {
          foreach ($ad in @($b.addrs)) { if (-not @($now.addrs | Where-Object { $_.ip -eq $ad.ip }).Count) { try { [void](Invoke-FsNetOp 'addstatic' @{ ifIndex = $ix; ip = $ad.ip; prefix = $ad.prefix; gw = '' }); Fs-LogLine ('this PC''s own address ' + $ad.ip + ' put back') } catch { $problems += ('this PC''s own address ' + $ad.ip + ' could not be put back: ' + $_.Exception.Message) } } }
          foreach ($g in @($b.gw)) { if ($g -and @($now.gw) -notcontains $g) { try { [void](Invoke-FsNetOp 'addroute' @{ ifIndex = $ix; gw = $g }); Fs-LogLine ('this PC''s router ' + $g + ' put back') } catch { $problems += ('the router route ' + $g + ' could not be put back: ' + $_.Exception.Message) } } }
        }
        if ($script:FsCoexistChanged) { $okc = $false; try { $okc = [bool](Invoke-FsNetOp 'coexist' @{ ifIndex = $ix; on = $false }) } catch {}; if ($okc) { $script:FsCoexistChanged = $false } else { $problems += 'the DHCP+static coexistence setting could not be put back' } }
        # check it again: DHCP on (when it was), own addresses back (when fixed)
        # 2.2.2 (re-review H4): a read that fails is a problem (not a pass); a DHCP adapter must have a real address again and every
        # router it had (default route) must be back - for DHCP too. DHCP can take a few seconds to hand the address back: asked again.
        $chk = $null; $vp = @()
        for ($try = 0; $try -lt [math]::Max(1, [int]$script:FsRestoreChecks); $try++) {
          if ($try -gt 0) { if ($b.dhcp -and $try -eq 1) { try { [void](Invoke-FsNetOp 'renew' @{ ifIndex = $ix; name = [string]$b.name }) } catch {} }; Fs-NetWait }
          $chk = $null; try { $chk = Invoke-FsNetOp 'state' @{ ifIndex = $ix } } catch { $chk = $null }
          $vp = @(Get-FsNetVerifyProblems $b $chk @($left))
          if (-not $vp.Count) { break }
        }
        $problems += $vp
      }
    }
  } else { $script:FsTemps.Clear() }
  $problems = @($problems | Select-Object -Unique)
  if (-not $problems.Count) {
    $script:FsPcBefore = $null; $script:FsCoexistChanged = $false; $script:FsTemps.Clear()
    if ($stateFile -and (Test-Path -LiteralPath $stateFile)) { Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue }
  } else {
    foreach ($pb in $problems) { Fs-LogLine ('NETWORK NOT BACK TO NORMAL: ' + $pb) }
    try { Save-FsNetState $stateFile } catch {}
  }
  $script:FsLastRestore = [pscustomobject]@{ ok = (-not $problems.Count); problems = @($problems) }
  return $script:FsLastRestore
}
# 2.2.2 (re-review H4): what is still not as it was ($b = saved before, $chk = read now, $temps = temporary addresses still on).
$script:FsRestoreChecks = 5     # reads of the adapter before it counts as "not back" (about 2 s apart)
function Fs-NetWait { if ($script:FsNetOps -and $script:FsNetOps.ContainsKey('wait')) { [void](& $script:FsNetOps['wait'] @{}); return }; Start-Sleep -Seconds 2 }
function Get-FsNetVerifyProblems($b, $chk, $temps = @()) {
  if (-not $chk) { return @('this PC''s network settings could not be read back, so it is not known whether they are back') }
  $p = @()
  $tempIps = @(@($temps) + @($script:FsTemps) | Where-Object { $_ } | ForEach-Object { [string]$_.ip })
  $own = @(@($chk.addrs) | Where-Object { $_ -and $_.ip -and -not $_.skip -and [string]$_.ip -notlike '169.254.*' -and $tempIps -notcontains [string]$_.ip })
  if ($b.dhcp) {
    if (-not $chk.dhcp) { $p += 'DHCP is still off on this PC' }
    $hadAddr = @(@($b.addrs) | Where-Object { $_ -and [string]$_.ip -notlike '169.254.*' }).Count -gt 0
    if ($hadAddr -and -not $own.Count) { $p += 'this PC has no address from DHCP yet' }
  } else {
    foreach ($ad in @($b.addrs)) { if ($ad -and -not @($chk.addrs | Where-Object { $_.ip -eq $ad.ip }).Count) { $p += ('this PC''s address ' + $ad.ip + ' is still missing') } }
  }
  foreach ($g in @($b.gw)) { if ($g -and @($chk.gw) -notcontains $g) { $p += ('this PC''s router ' + $g + ' (default route) is not back') } }
  return $p
}
function Remove-FsTempIps([string]$stateFile) {
  if ($script:FsMockUrl -and -not $script:FsNetOps) {
    foreach ($t in @($script:FsTemps)) { [void](Fs-Http -Ip '_pc' -Path ('/deltemp?p3=' + $t.p3)) }
    $script:FsTemps.Clear(); if ($stateFile -and (Test-Path $stateFile)) { Remove-Item $stateFile -Force -ErrorAction SilentlyContinue }
    $script:FsLastRestore = [pscustomobject]@{ ok = $true; problems = @() }; return $script:FsLastRestore
  }
  if (-not $script:FsPcBefore -and -not @($script:FsTemps).Count) { $script:FsLastRestore = [pscustomobject]@{ ok = $true; problems = @() }; return $script:FsLastRestore }
  return (Restore-FsPcNet $stateFile)
}
function Clear-FsLeftoverTemps([string]$stateFile) {
  # a run that crashed or was stopped left this PC changed: put it back at the next start (and from the "Fix this site" task's finally)
  if (($script:FsMockUrl -and -not $script:FsNetOps) -or -not $stateFile -or -not (Test-Path -LiteralPath $stateFile)) { return $null }
  $tj = $null; try { $tj = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json } catch {}
  if (-not $tj) { Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue; return $null }
  $script:FsTemps.Clear()
  if ($tj.PSObject.Properties['version'] -and [int]$tj.version -ge 2) {
    $script:FsPcBefore = $tj.before; $script:FsCoexistChanged = [bool]$tj.coexistChanged
    foreach ($t in @($tj.temps)) { if ($t) { [void]$script:FsTemps.Add($t) } }
  } else { foreach ($t in @($tj)) { if ($t -and $t.ip) { [void]$script:FsTemps.Add($t) } } }   # 2.2.0 and older: a plain list of addresses
  Fs-LogLine 'a previous run left this PC''s network changed - putting it back'
  return (Restore-FsPcNet $stateFile)
}
function Wait-FsDevice([string]$ip, [string]$brand, [string]$pw, [int]$seconds) {
  $end = (Get-Date).AddSeconds($seconds)
  do { $s = Test-FsLogin $ip $brand $pw; if ($s -eq 'ok') { return $true }; if ($s -eq 'refused' -or $s -eq 'locked') { return $false }; Fs-Sleep 5 } while ((Get-Date) -lt $end)
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
function Get-FsSecretPath([string]$dir, [string]$site, [switch]$Legacy) { return (Join-Path $dir ('site-' + $(if ($Legacy) { Get-FsLegacySlug $site } else { Get-FsSiteSlug $site }) + '.dat')) }   # 2.2.3 (Codex #24)
function Read-FsSecrets([string]$dir, [string]$site) {
  $o = [ordered]@{ site = $site; password = ''; known = @(); nvr = @{}; cams = @{}; rollback = @{}; bitwardenSaved = $false; shownOnce = $false; unreadable = $false; unreadableWhy = '' }
  $p = Get-FsSecretPath $dir $site
  $fromLegacy = $false
  $oldName = $false
  if (-not (Test-Path -LiteralPath $p)) { $lp = Get-FsSecretPath $dir $site -Legacy; if ($lp -ne $p -and (Test-Path -LiteralPath $lp)) { $p = $lp; $oldName = $true } }
  if (-not (Test-Path -LiteralPath $p) -and $script:FsLegacySecretsDir) { $lp = Get-FsSecretPath $script:FsLegacySecretsDir $site; if (-not (Test-Path -LiteralPath $lp)) { $lp = Get-FsSecretPath $script:FsLegacySecretsDir $site -Legacy }; if (Test-Path -LiteralPath $lp) { $p = $lp; $fromLegacy = $true } }
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
function Save-FsSecrets([string]$dir, $sec) {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $keep = [ordered]@{ site = $sec.site; password = $sec.password; known = @($sec.known); nvr = $sec.nvr; cams = $(if ($sec.PSObject.Properties['cams'] -and $sec.cams) { $sec.cams } else { @{} }); rollback = $sec.rollback; bitwardenSaved = [bool]$sec.bitwardenSaved; shownOnce = [bool]$sec.shownOnce; updated = (Get-Date -Format 's') }
  $p = Get-FsSecretPath $dir $sec.site; $tmp = $p + '.tmp'
  [IO.File]::WriteAllText($tmp, (Protect-FsText ($keep | ConvertTo-Json -Depth 6 -Compress)))
  Move-Item -LiteralPath $tmp -Destination $p -Force
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
function Save-FsSitePrefix([string]$dir, [string]$p) { New-Item -ItemType Directory -Force -Path $dir | Out-Null; [IO.File]::WriteAllText((Join-Path $dir 'password-word.dat'), (Protect-FsText $p)) }
# 2.2.0: Install-Toolkit (run as an admin) moves every 2.1 store it can read into vault\ as LocalMachine. Returns { moved; unreadable = @(files) }.
function Convert-FsSecretStores([string]$FromDir, [string]$ToDir) {
  $moved = 0; $bad = @()
  if (-not (Test-Path -LiteralPath $FromDir)) { return [pscustomobject]@{ moved = 0; unreadable = @() } }
  New-Item -ItemType Directory -Force -Path $ToDir | Out-Null
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
