@echo off
rem WireIt Site Check - read-only camera/NVR check. Double-click to run. Changes nothing, installs nothing.
setlocal
set "WSC_SELF=%~f0"
start "WireIt Site Check" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command "$f=$env:WSC_SELF; $s=[IO.File]::ReadAllText($f); $i=$s.IndexOf('##'+'PSSTART'); try { & ([scriptblock]::Create($s.Substring($i))) -Launcher $f } catch { Add-Type -AssemblyName System.Windows.Forms; [void][Windows.Forms.MessageBox]::Show('WireIt Site Check could not start: ' + $_.Exception.Message, 'WireIt Site Check') }"
exit /b
##PSSTART
<#
 WireIt Site Check  -  READ-ONLY camera/NVR network check for a customer PC (Windows 10/11, PowerShell 5.1)
 No install, no admin. Finds the NVR and cameras (Hikvision SADP, ONVIF, ping, ports), tests each with 20 pings,
 spots IP conflicts and wrong IP schemes, and - if you type the NVR password - reads which NVR channels are offline
 (official Hikvision ISAPI / Dahua HTTP API, GET requests only, one login try). Changes nothing on any device.
 The password is used once and never saved or logged.
 Run:  double-click WireIt-SiteCheck.cmd   (or:  powershell -ExecutionPolicy Bypass -File SiteCheck.ps1)
 Console: SiteCheck.ps1 -NoWindow [-Nvr 192.168.1.100 -AskPassword] [-Site WI-061 -UploadCode ABC123]
 Upload (optional): type the Site ID + the 2-hour upload code from the site page (Remote check card); the result then shows
 on the site page. No camera names and no password are ever sent.
#>
param(
  [string]$Nvr = '', [string]$User = 'admin', [int]$Pings = 20, [string[]]$ExtraNet = @(),
  [switch]$NoWindow, [switch]$AskPassword, [string]$OutDir = '',
  [string]$Site = '', [string]$UploadCode = '',
  [switch]$SelfTest, [switch]$LoadOnly, [switch]$GuiSmoke, [string]$Screenshot = '', [string]$Launcher = ''
)
$SC_CODE = @'

# ======================= CORE (read-only checks) =======================
$script:SC_VERSION = '1.1.0'
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
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

$script:OUI = @{
 'DC-07-F8'='Hikvision';'28-57-BE'='Hikvision';'44-19-B6'='Hikvision';'4C-BD-8F'='Hikvision';'54-C4-15'='Hikvision';'58-03-FB'='Hikvision';'BC-AD-28'='Hikvision';'C0-56-E3'='Hikvision';'C4-2F-90'='Hikvision';'18-68-CB'='Hikvision';'24-48-45'='Hikvision';'80-BE-AF'='Hikvision';'A4-14-37'='Hikvision';'8C-E7-48'='Hikvision';'94-E1-AC'='Hikvision';'BC-BA-C2'='Hikvision';'64-DB-8B'='Hikvision';'98-DF-82'='Hikvision';'E0-CA-3C'='Hikvision';'08-A1-89'='Hikvision';'24-0F-9B'='Hikvision';'2C-A5-9C'='Hikvision';'40-AC-BF'='Hikvision';'44-47-CC'='Hikvision';'4C-F5-DC'='Hikvision';'68-6D-BC'='Hikvision';'84-94-37'='Hikvision';'AC-B9-2F'='Hikvision';'B4-A3-82'='Hikvision';'C8-A7-02'='Hikvision';'10-12-FB'='Hikvision';'AC-CB-51'='Hikvision';'E8-A0-ED'='Hikvision';'F8-4D-FC'='Hikvision';'0C-75-D2'='Hikvision';
 'E0-50-8B'='Dahua';'3C-EF-8C'='Dahua';'4C-11-BF'='Dahua';'90-02-A9'='Dahua';'A0-BD-1D'='Dahua';'BC-32-5F'='Dahua';'14-A7-8B'='Dahua';'38-AF-29'='Dahua';'9C-14-63'='Dahua';'B4-4C-3B'='Dahua';'D4-43-0E'='Dahua';'F4-B1-C2'='Dahua';'08-ED-ED'='Dahua';'6C-1C-71'='Dahua';'24-52-6A'='Dahua';'C0-39-5A'='Dahua';
 '48-EA-63'='Uniview';'6C-F1-7E'='Uniview';'C4-79-05'='Uniview';
 '1C-6A-1B'='Ubiquiti';'24-5A-4C'='Ubiquiti';'74-83-C2'='Ubiquiti';'78-8A-20'='Ubiquiti';'80-2A-A8'='Ubiquiti';'B4-FB-E4'='Ubiquiti';'D0-21-F9'='Ubiquiti';'E0-63-DA'='Ubiquiti';'F0-9F-C2'='Ubiquiti';'FC-EC-DA'='Ubiquiti';'68-D7-9A'='Ubiquiti';'18-E8-29'='Ubiquiti';'AC-8B-A9'='Ubiquiti';'9C-05-D6'='Ubiquiti';'60-22-32'='Ubiquiti';
 '00-1D-AA'='DrayTek';'00-50-7F'='DrayTek';'B8-27-EB'='Raspberry Pi';'DC-A6-32'='Raspberry Pi'
}
function ConvertTo-ScMac([string]$m) { if (-not $m) { return '' }; $h = ($m -replace '[^0-9A-Fa-f]', '').ToUpper(); if ($h.Length -ne 12) { return '' }; return (($h -split '(..)' | Where-Object { $_ }) -join '-') }
function Get-ScVendor([string]$mac) {
  $mac = ConvertTo-ScMac $mac; if (-not $mac) { return '' }
  $p = $mac.Substring(0,8); if ($script:OUI.ContainsKey($p)) { return $script:OUI[$p] }
  $b = [Convert]::ToInt32($mac.Substring(0,2),16); if ($b -band 2) { return 'random/private MAC' }
  return 'other'
}
function ConvertTo-ScUInt([string]$ip) { $b = ([Net.IPAddress]::Parse($ip)).GetAddressBytes(); [Array]::Reverse($b); return [BitConverter]::ToUInt32($b, 0) }
function ConvertFrom-ScUInt([uint32]$n) { $b = [BitConverter]::GetBytes($n); [Array]::Reverse($b); return ([Net.IPAddress]$b).ToString() }
function Get-ScMaskFromPrefix([int]$p) { if ($p -le 0) { return [uint32]0 }; return [uint32]([uint64]4294967295 -shl (32 - $p) -band 4294967295) }
function Get-ScPrefixFromMask([string]$mask) { try { $n = ConvertTo-ScUInt $mask; $c = 0; for ($i = 31; $i -ge 0; $i--) { if ($n -band ([uint32]1 -shl $i)) { $c++ } else { break } }; return $c } catch { return 24 } }
function Test-ScSameSubnet([string]$a, [string]$b, [int]$prefix) {
  try { $m = Get-ScMaskFromPrefix $prefix; return (((ConvertTo-ScUInt $a) -band $m) -eq ((ConvertTo-ScUInt $b) -band $m)) } catch { return $false }
}
function Get-ScNet24([string]$ip) { return (($ip -split '\.')[0..2] -join '.') }
function Test-ScIp([string]$s) { return ($s -match '^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$') }
function Get-ScXml([string]$xml, [string]$name) { $m = [regex]::Match($xml, '<(?:\w+:)?' + $name + '>([^<]*)</(?:\w+:)?' + $name + '>'); if ($m.Success) { return $m.Groups[1].Value.Trim() } else { return '' } }
function Get-ScMedian($list) { $a = @($list | Sort-Object); if ($a.Count -eq 0) { return $null }; return $a[[int][math]::Floor(($a.Count - 1) / 2)] }

# ---------- this PC ----------
function Get-ScLocalNets {
  $out = @()
  $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
    $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.InterfaceAlias -notmatch 'Tailscale|ZeroTier|Cellular|Bluetooth|Loopback|vEthernet|VirtualBox|VMware|WireGuard|OpenVPN|TAP|NordLynx|Hyper-V' -and
    -not ($_.IPAddress -match '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.') })
  foreach ($i in $ips) {
    $a = Get-NetAdapter -InterfaceIndex $i.InterfaceIndex -ErrorAction SilentlyContinue
    if ($a -and $a.Status -ne 'Up') { continue }
    $out += [pscustomobject]@{ Ip = $i.IPAddress; Prefix = [int]$i.PrefixLength; Alias = $i.InterfaceAlias; Desc = $(if ($a) { $a.InterfaceDescription } else { '' }); Speed = $(if ($a) { [string]$a.LinkSpeed } else { '' }); Mac = $(if ($a) { ConvertTo-ScMac $a.MacAddress } else { '' }) }
  }
  return $out
}

# ---------- discovery: Hikvision SADP + ONVIF WS-Discovery (read-only multicast probes) ----------
function Invoke-ScDiscovery($locals, [int]$seconds = 4) {
  $socks = @(); $found = New-Object System.Collections.Generic.List[object]
  $grp = [Net.IPAddress]::Parse('239.255.255.250')
  foreach ($l in $locals) {
    foreach ($kind in @('sadp','onvif')) {
      try {
        $u = New-Object System.Net.Sockets.UdpClient
        $u.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket, [Net.Sockets.SocketOptionName]::ReuseAddress, $true)
        $port = $(if ($kind -eq 'sadp') { 37020 } else { 0 })
        $u.Client.Bind((New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($l.Ip)), $port))
        if ($kind -eq 'sadp') { try { $u.JoinMulticastGroup($grp, [Net.IPAddress]::Parse($l.Ip)) } catch {} }
        $u.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::IP, [Net.Sockets.SocketOptionName]::MulticastInterface, ([Net.IPAddress]::Parse($l.Ip)).GetAddressBytes())
        $socks += [pscustomobject]@{ U = $u; Kind = $kind }
      } catch {}
    }
  }
  $sadp = '<?xml version="1.0" encoding="utf-8"?><Probe><Uuid>' + ([guid]::NewGuid().ToString().ToUpper()) + '</Uuid><Types>inquiry</Types></Probe>'
  $wsd = '<?xml version="1.0" encoding="UTF-8"?><e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl"><e:Header><w:MessageID>uuid:' + [guid]::NewGuid() + '</w:MessageID><w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To><w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>'
  foreach ($s in $socks) {
    if ($s.Kind -eq 'sadp') { $b = [Text.Encoding]::UTF8.GetBytes($sadp); $ep = New-Object Net.IPEndPoint ($grp, 37020) } else { $b = [Text.Encoding]::UTF8.GetBytes($wsd); $ep = New-Object Net.IPEndPoint ($grp, 3702) }
    for ($k = 0; $k -lt 2; $k++) { try { [void]$s.U.Send($b, $b.Length, $ep) } catch {} }
  }
  $end = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $end) {
    foreach ($s in $socks) {
      try {
        while ($s.U.Available -gt 0) {
          $from = New-Object Net.IPEndPoint ([Net.IPAddress]::Any), 0
          $b = $s.U.Receive([ref]$from)
          $found.Add([pscustomobject]@{ From = $from.Address.ToString(); Text = [Text.Encoding]::UTF8.GetString($b) })
        }
      } catch {}
    }
    Start-Sleep -Milliseconds 100
  }
  foreach ($s in $socks) { try { $s.U.Close() } catch {} }
  return ,$found
}
function ConvertFrom-ScDiscovery($answers) {
  $devs = @{}
  foreach ($a in $answers) {
    $t = [string]$a.Text
    if ($t -match '<ProbeMatch>' -and $t -match '<DeviceSN>') {
      $ip = Get-ScXml $t 'IPv4Address'; if (-not $ip) { $ip = $a.From }
      if ($t -match '<Types>inquiry</Types>' -and -not (Get-ScXml $t 'DeviceSN')) { continue }
      $mac = ConvertTo-ScMac (Get-ScXml $t 'MAC')
      $k = 'SADP|' + $mac + '|' + $ip
      $devs[$k] = [pscustomobject]@{ Ip = $ip; Mac = $mac; Brand = 'Hikvision'; Model = (Get-ScXml $t 'DeviceDescription'); Serial = (Get-ScXml $t 'DeviceSN'); Firmware = (Get-ScXml $t 'SoftwareVersion'); Mask = (Get-ScXml $t 'IPv4SubnetMask'); Gateway = (Get-ScXml $t 'IPv4Gateway'); Activated = (Get-ScXml $t 'Activated'); Source = 'SADP' }
    } elseif ($t -match 'ProbeMatch' -and $t -match 'XAddrs') {
      $x = Get-ScXml $t 'XAddrs'; $ip = $a.From
      $m = [regex]::Match($x, 'https?://(\d+\.\d+\.\d+\.\d+)'); if ($m.Success) { $ip = $m.Groups[1].Value }
      $scopes = Get-ScXml $t 'Scopes'
      $brand = ''; $model = ''
      $mm = [regex]::Match($scopes, 'onvif://www\.onvif\.org/(?:name|manufacturer|mfr)/([^ ]+)'); if ($mm.Success) { $brand = [uri]::UnescapeDataString($mm.Groups[1].Value) }
      $mm = [regex]::Match($scopes, 'onvif://www\.onvif\.org/hardware/([^ ]+)'); if ($mm.Success) { $model = [uri]::UnescapeDataString($mm.Groups[1].Value) }
      $k = 'ONVIF|' + $ip
      if (-not $devs.ContainsKey($k)) { $devs[$k] = [pscustomobject]@{ Ip = $ip; Mac = ''; Brand = $brand; Model = $model; Serial = ''; Firmware = ''; Mask = ''; Gateway = ''; Activated = ''; Source = 'ONVIF' } }
    }
  }
  return @($devs.Values)
}

# ---------- ping sweep + per-host ping quality (parallel, ICMP only) ----------
function Invoke-ScPingRounds([string[]]$ips, [int]$rounds, [int]$timeoutMs = 1000, [int]$gapMs = 250, [scriptblock]$OnRound = $null) {
  $res = @{}; foreach ($i in $ips) { $res[$i] = [pscustomobject]@{ Ip = $i; Sent = 0; Ok = 0; Rtt = (New-Object System.Collections.Generic.List[int]) } }
  for ($r = 0; $r -lt $rounds; $r++) {
    $tasks = @{}; $pingers = @()
    foreach ($i in $ips) { $p = New-Object System.Net.NetworkInformation.Ping; $pingers += $p; try { $tasks[$i] = $p.SendPingAsync($i, $timeoutMs) } catch {} }
    try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($tasks.Values), $timeoutMs + 3000) } catch {}
    foreach ($i in $ips) {
      $t = $tasks[$i]
      if (-not $t) { continue }   # 2.2.20 (class C): a ping that could not even be sent is not a ping that was lost (not counted as Sent)
      $res[$i].Sent++
      if ($t -and $t.Status -eq 'RanToCompletion' -and $t.Result.Status -eq 'Success') { $res[$i].Ok++; $res[$i].Rtt.Add([int]$t.Result.RoundtripTime) }
    }
    foreach ($p in $pingers) { try { $p.Dispose() } catch {} }
    if ($OnRound) { & $OnRound ($r + 1) }
    if ($gapMs -gt 0) { Start-Sleep -Milliseconds $gapMs }
  }
  return $res
}
# 2.2.20 (class C): $script:ScArpWhy = why the last ARP read failed ('' = it was read). A table that could not be read is not an empty one:
# the scan says ARP NOT CHECKED and never gives the "No network problems found" all-clear on it.
$script:ScArpWhy = ''
function Get-ScArp([string[]]$prefixes) {
  $h = @{}; $script:ScArpWhy = ''
  $nb = $null; try { $nb = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop) } catch { $script:ScArpWhy = [string]$_.Exception.Message; return $h }
  @($nb) | Where-Object { $_ } | Where-Object { $_.State -ne 'Unreachable' -and $_.State -ne 'Incomplete' -and $_.LinkLayerAddress -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' -and $_.LinkLayerAddress -ne 'FF-FF-FF-FF-FF-FF' } | ForEach-Object {
    $ip = $_.IPAddress; foreach ($p in $prefixes) { if ($ip.StartsWith($p + '.')) { $h[$ip] = ConvertTo-ScMac $_.LinkLayerAddress; break } }
  }
  return $h
}
# ---------- TCP port check (connect only, nothing sent) ----------
function Invoke-ScPorts([string[]]$ips, [int[]]$ports, [int]$timeoutMs = 1200) {
  $jobs = @()
  foreach ($i in $ips) { foreach ($p in $ports) { $c = New-Object Net.Sockets.TcpClient; try { $jobs += [pscustomobject]@{ Ip = $i; Port = $p; C = $c; T = $c.ConnectAsync($i, $p) } } catch { $c.Close() } } }
  $tasks = @($jobs | ForEach-Object { $_.T })
  if ($tasks.Count) { try { [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks, $timeoutMs) } catch {} }
  $open = @{}; foreach ($i in $ips) { $open[$i] = @() }
  foreach ($j in $jobs) { if ($j.T.Status -eq 'RanToCompletion' -and $j.C.Connected) { $open[$j.Ip] += $j.Port }; try { $j.C.Close() } catch {} }
  return $open
}

# ---------- NVR reads (official Hikvision ISAPI / Dahua HTTP API, GET only, one login try) ----------
function Invoke-ScHttpGet([string]$url, $cred, [int]$timeoutMs = 8000) {
  try {
    $rq = [Net.HttpWebRequest]::Create($url); $rq.Method = 'GET'; $rq.Timeout = $timeoutMs; $rq.ReadWriteTimeout = $timeoutMs; $rq.AllowAutoRedirect = $false
    if (Enable-WireItLanTls) { try { $rq.ServerCertificateValidationCallback = [WireItLanTls]::Callback } catch {} }   # this request only: a self-made NVR certificate on a private address
    # 2.2.7 (Codex file-by-file F06): over plain HTTP only Digest is offered the password (never Basic, which sends it in clear); HTTPS may use Basic
    if ($cred) { $cc = New-Object Net.CredentialCache; $u = [uri]$url; $base = [uri]($u.Scheme + '://' + $u.Authority); $nc = $cred.GetNetworkCredential(); $cc.Add($base, 'Digest', $nc); if ($u.Scheme -eq 'https') { $cc.Add($base, 'Basic', $nc) }; $rq.Credentials = $cc; $rq.PreAuthenticate = $false }
    $rs = $rq.GetResponse(); $sr = New-Object IO.StreamReader($rs.GetResponseStream()); $body = $sr.ReadToEnd(); $sr.Close(); $code = [int]$rs.StatusCode; $rs.Close()
    return [pscustomobject]@{ Code = $code; Body = $body }
  } catch [Net.WebException] {
    $c = 0; try { $c = [int]$_.Exception.Response.StatusCode } catch {}
    return [pscustomobject]@{ Code = $c; Body = ''; Error = $_.Exception.Message }
  } catch { return [pscustomobject]@{ Code = 0; Body = ''; Error = $_.Exception.Message } }
}
function ConvertFrom-ScHikStatus([string]$statusXml, [string]$namesXml) {
  $names = @{}
  foreach ($m in [regex]::Matches([string]$namesXml, '(?s)<InputProxyChannel(?:\s[^>]*)?>(.*?)</InputProxyChannel>')) { $b = $m.Groups[1].Value; $id = Get-ScXml $b 'id'; if ($id) { $names[$id] = Get-ScXml $b 'name' } }
  $out = @()
  foreach ($m in [regex]::Matches([string]$statusXml, '(?s)<InputProxyChannelStatus(?:\s[^>]*)?>(.*?)</InputProxyChannelStatus>')) {
    $b = $m.Groups[1].Value; $id = Get-ScXml $b 'id'
    # 2.2.19 (sweep2, class C): a channel whose answer has no online true/false is NOT CHECKED (Known false), never "OFFLINE"
    $ov = ([string](Get-ScXml $b 'online')).Trim().ToLower(); $online = ($ov -eq 'true')
    $out += [pscustomobject]@{ Ch = [int]$id; Ip = (Get-ScXml $b 'ipAddress'); Online = $online; Known = ($ov -eq 'true' -or $ov -eq 'false'); Detail = (Get-ScXml $b 'chanDetectResult'); Name = $(if ($names.ContainsKey($id)) { $names[$id] } else { '' }); Protocol = (Get-ScXml $b 'proxyProtocol'); Model = (Get-ScXml $b 'model') }
  }
  return @($out | Sort-Object Ch)
}
function ConvertFrom-ScDahuaKv([string]$text) { $h = @{}; foreach ($line in ($text -split "`r?`n")) { $i = $line.IndexOf('='); if ($i -gt 0) { $h[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim() } }; return $h }
function ConvertFrom-ScDahuaStatus([string]$stateText, [string]$remoteText, [string]$titleText) {
  $st = ConvertFrom-ScDahuaKv $stateText; $rd = ConvertFrom-ScDahuaKv $remoteText; $ti = ConvertFrom-ScDahuaKv $titleText
  $chs = @{}
  foreach ($k in $st.Keys) { $m = [regex]::Match($k, '^states\[(\d+)\]\.(channel|connectionState)$'); if ($m.Success) { $n = $m.Groups[1].Value; if (-not $chs.ContainsKey($n)) { $chs[$n] = @{} }; $chs[$n][$m.Groups[2].Value] = $st[$k] } }
  $addr = @{}; $en = @{}
  foreach ($k in $rd.Keys) {   # only Address/Enable are read; any other field (e.g. stored camera logins) is ignored and never saved
    $m = [regex]::Match($k, 'RemoteDevice\.uuid:System_CONFIG_NETCAMERA_INFO_(\d+)\.(Address|Enable)$'); if ($m.Success) { if ($m.Groups[2].Value -eq 'Address') { $addr[$m.Groups[1].Value] = $rd[$k] } else { $en[$m.Groups[1].Value] = $rd[$k] } }
  }
  $out = @()
  foreach ($n in $chs.Keys) {
    $c = $chs[$n]; $chIdx = $(if ($c.ContainsKey('channel')) { [int]$c['channel'] } else { [int]$n })
    $state = [string]$c['connectionState']
    if ($en.ContainsKey([string]$chIdx) -and $en[[string]$chIdx] -eq 'false' -and $state -ne 'Connected') { continue }
    $name = ''; $tk = 'table.ChannelTitle[' + $chIdx + '].Name'; if ($ti.ContainsKey($tk)) { $name = $ti[$tk] }
    $out += [pscustomobject]@{ Ch = $chIdx + 1; Ip = $(if ($addr.ContainsKey([string]$chIdx)) { $addr[[string]$chIdx] } else { '' }); Online = ($state -eq 'Connected'); Known = [bool]$state.Trim(); Detail = $state; Name = $name; Protocol = 'Dahua'; Model = '' }   # 2.2.19 (sweep2): no state = NOT CHECKED
  }
  return @($out | Sort-Object Ch)
}
function Get-ScNvrChannels([string]$nvr, $cred, [int[]]$openPorts) {
  $r = [pscustomobject]@{ Brand = ''; Model = ''; Ok = $false; Msg = ''; Channels = @(); Scheme = '' }
  $schemes = @(); if ($openPorts -contains 80 -or -not $openPorts) { $schemes += 'http' }; if ($openPorts -contains 443) { $schemes += 'https' }; if (-not $schemes) { $schemes = @('http') }
  [void](Enable-WireItLanTls)   # 2.2.1: NVRs (private addresses) only; the upload to the service log keeps the normal certificate check
  $dahuaFirst = ($openPorts -contains 37777) -and -not ($openPorts -contains 8000)
  foreach ($sc in $schemes) {
    $base = $sc + '://' + $nvr
    if ($dahuaFirst) { $di = [pscustomobject]@{ Code = 404; Body = '' } } else { $di = Invoke-ScHttpGet ($base + '/ISAPI/System/deviceInfo') $cred }
    if ($di.Code -eq 401) { $r.Msg = 'The NVR said the user name or password is wrong. (Only one try was made, so it will not lock.)'; $r.Brand = 'Hikvision?'; return $r }
    if ($di.Code -eq 200 -and $di.Body -match '<DeviceInfo') {
      $r.Brand = 'Hikvision'; $r.Model = Get-ScXml $di.Body 'model'; $r.Scheme = $sc
      $s = Invoke-ScHttpGet ($base + '/ISAPI/ContentMgmt/InputProxy/channels/status') $cred
      $n = Invoke-ScHttpGet ($base + '/ISAPI/ContentMgmt/InputProxy/channels') $cred
      # 2.2.18 (sweep C): an answer with no channel in it is NOT "0 cameras": it is said as not read (amber), never an empty all-clear
      if ($s.Code -eq 200) { $r.Channels = @(ConvertFrom-ScHikStatus $s.Body $n.Body); $r.Ok = [bool]@($r.Channels).Count; $r.Msg = $(if ($r.Ok) { 'Read ' + @($r.Channels).Count + ' camera channels from the NVR.' } else { 'Logged in, but the NVR''s channel list had no channel in it that could be read - channel status NOT CHECKED.' }) } else { $r.Msg = 'Logged in, but the NVR did not give its channel list (HTTP ' + $s.Code + ').' }
      return $r
    }
    $dt = Invoke-ScHttpGet ($base + '/cgi-bin/magicBox.cgi?action=getDeviceType') $cred
    if ($dt.Code -eq 401) { $r.Msg = 'The NVR said the user name or password is wrong. (Only one try was made.)'; $r.Brand = 'Dahua?'; return $r }
    if ($dt.Code -eq 200 -and $dt.Body -match 'type=') {
      $r.Brand = 'Dahua'; $r.Model = ($dt.Body -replace '^type=', '').Trim(); $r.Scheme = $sc
      $st = Invoke-ScHttpGet ($base + '/cgi-bin/LogicDeviceManager.cgi?action=getCameraState&uniqueChannels[0]=-1') $cred
      $rd = Invoke-ScHttpGet ($base + '/cgi-bin/configManager.cgi?action=getConfig&name=RemoteDevice') $cred
      $ti = Invoke-ScHttpGet ($base + '/cgi-bin/configManager.cgi?action=getConfig&name=ChannelTitle') $cred
      if ($st.Code -eq 200) { $r.Channels = @(ConvertFrom-ScDahuaStatus $st.Body $rd.Body $ti.Body); $r.Ok = [bool]@($r.Channels).Count; $r.Msg = $(if ($r.Ok) { 'Read ' + @($r.Channels).Count + ' camera channels from the NVR.' } else { 'Logged in, but the NVR''s camera states had no camera in them that could be read - channel status NOT CHECKED.' }) } else { $r.Msg = 'Logged in, but the NVR did not give its camera states (HTTP ' + $st.Code + ').' }
      $rd = $null
      return $r
    }
  }
  $r.Msg = 'Could not read the NVR web API at ' + $nvr + ' (not Hikvision/Dahua, or web access is off).'
  return $r
}

# ---------- the whole scan ----------
function Invoke-SiteCheck([string]$Nvr = '', $Cred = $null, [int]$Pings = 20, [scriptblock]$Say = { param($s) Write-Host $s }, [string[]]$ExtraNets = @()) {
  $t0 = Get-Date
  $R = [ordered]@{ tool = 'WireIt Site Check'; version = $script:SC_VERSION; started = $t0.ToString('s'); pc = $env:COMPUTERNAME; nets = @(); nvr = $Nvr; nvrRead = $null; devices = @(); channels = @(); duplicates = @(); notes = @() }
  & $Say 'Looking at this PC''s network...'
  $locals = @(Get-ScLocalNets)
  $R.nets = @($locals | ForEach-Object { [ordered]@{ ip = $_.Ip; prefix = $_.Prefix; adapter = $_.Alias; speed = $_.Speed } })
  if (-not $locals) { $R.notes += 'This PC has no wired or Wi-Fi network address.'; return $R }
  $prefixes = @()
  foreach ($l in $locals) {
    $pl = [math]::Max(22, [math]::Min(24, $l.Prefix)); $net = (ConvertTo-ScUInt $l.Ip) -band (Get-ScMaskFromPrefix $pl)
    for ($k = 0; $k -lt [math]::Pow(2, 24 - $pl); $k++) { $prefixes += (Get-ScNet24 (ConvertFrom-ScUInt ([uint32]($net + $k * 256)))) }
    if ($l.Prefix -lt 22) { $R.notes += ('This PC''s network is large (/' + $l.Prefix + '); only the 1024 addresses around it were checked.') }
  }
  if ($Nvr -and (Test-ScIp $Nvr)) { $prefixes += (Get-ScNet24 $Nvr) }
  foreach ($x in $ExtraNets) { if ($x -match '^\d+\.\d+\.\d+$') { $prefixes += $x } }
  $prefixes = @($prefixes | Select-Object -Unique | Select-Object -First 6)
  & $Say ('Network(s) to check: ' + (($prefixes | ForEach-Object { $_ + '.x' }) -join ', '))

  & $Say 'Asking cameras and NVRs to identify themselves (Hikvision + ONVIF)...'
  $disc = @(ConvertFrom-ScDiscovery (Invoke-ScDiscovery $locals 4))
  & $Say ('  ' + $disc.Count + ' answered.')
  if (-not $Nvr) {
    $cand = $disc | Where-Object { $_.Model -match '^(i?DS-7|DS-9|DHI-NVR|NVR)' -or $_.Model -match 'NVR|DVR' } | Select-Object -First 1
    if ($cand) { $Nvr = $cand.Ip; $R.nvr = $Nvr; $R.notes += ('NVR found automatically: ' + $Nvr + ' (' + $cand.Model + ')'); & $Say ('  NVR found: ' + $Nvr + ' ' + $cand.Model) }
  }

  & $Say 'Finding everything that answers on the network...'
  $all = @(); foreach ($p in $prefixes) { foreach ($n in 1..254) { $all += ($p + '.' + $n) } }
  $mine = @($locals | ForEach-Object { $_.Ip })
  $sweep = Invoke-ScPingRounds $all 2 800 200
  $arp1 = Get-ScArp $prefixes
  if ($script:ScArpWhy) { $R.arpRead = $false; $R.notes += ('ARP table NOT CHECKED (' + $script:ScArpWhy + '): devices that do not answer ping may be missing from this report.') } else { $R.arpRead = $true }
  $live = New-Object System.Collections.Generic.HashSet[string]
  foreach ($i in $all) { if ($sweep[$i].Ok -gt 0 -or $arp1.ContainsKey($i)) { [void]$live.Add($i) } }
  foreach ($d in $disc) { if ($d.Ip -and (Test-ScIp $d.Ip)) { foreach ($p in $prefixes) { if ($d.Ip.StartsWith($p + '.')) { [void]$live.Add($d.Ip) } } } }
  if ($Nvr -and (Test-ScIp $Nvr)) { [void]$live.Add($Nvr) }
  foreach ($m in $mine) { [void]$live.Remove($m) }

  $nv = $null
  $openNvr = @()
  if ($Nvr -and (Test-ScIp $Nvr)) { $openNvr = @((Invoke-ScPorts @($Nvr) @(80, 443, 554, 8000, 37777))[$Nvr]) }
  if ($Nvr -and $Cred) {
    & $Say ('Reading camera channels from the NVR at ' + $Nvr + ' (read-only, one login try)...')
    $nv = Get-ScNvrChannels $Nvr $Cred $openNvr
    & $Say ('  ' + $nv.Msg)
    $R.nvrRead = [ordered]@{ brand = $nv.Brand; model = $nv.Model; ok = $nv.Ok; msg = $nv.Msg }
  }
  $chIps = @(); if ($nv -and $nv.Ok) { $chIps = @($nv.Channels | Where-Object { $_.Ip -and (Test-ScIp $_.Ip) } | ForEach-Object { $_.Ip } | Select-Object -Unique) }
  $targets = @(@($live) + @($chIps) | Select-Object -Unique)

  & $Say ('Testing each device with ' + $Pings + ' pings (about ' + [int]($Pings * 1.3) + ' seconds)...')
  $arpSeen = @{}
  $q = Invoke-ScPingRounds $targets $Pings 1000 250 { param($n) $a = Get-ScArp $prefixes; foreach ($k in $a.Keys) { if (-not $arpSeen.ContainsKey($k)) { $arpSeen[$k] = New-Object System.Collections.Generic.HashSet[string] }; [void]$arpSeen[$k].Add($a[$k]) } }
  & $Say 'Checking which camera/NVR ports answer...'
  $ports = Invoke-ScPorts $targets @(80, 443, 554, 8000, 37777)
  $arp = Get-ScArp $prefixes
  if ($script:ScArpWhy -and $R.arpRead) { $R.arpRead = $false; $R.notes += ('ARP table NOT CHECKED (' + $script:ScArpWhy + ').') }

  # duplicate IPs: one IP answering from 2+ MACs (ARP changes during the test, or 2 SADP answers)
  $macsByIp = @{}
  foreach ($k in $arpSeen.Keys) { $macsByIp[$k] = New-Object System.Collections.Generic.HashSet[string]; foreach ($m in $arpSeen[$k]) { [void]$macsByIp[$k].Add($m) } }
  foreach ($d in $disc) { if ($d.Mac -and $d.Ip) { if (-not $macsByIp.ContainsKey($d.Ip)) { $macsByIp[$d.Ip] = New-Object System.Collections.Generic.HashSet[string] }; [void]$macsByIp[$d.Ip].Add($d.Mac) } }
  foreach ($k in $macsByIp.Keys) { if ($macsByIp[$k].Count -gt 1) { $R.duplicates += [ordered]@{ ip = $k; macs = @($macsByIp[$k]) } } }

  # NVR network (for "different subnet" flags)
  $nvrNet = ''; $nvrPrefix = 24
  if ($Nvr) { $nd = $disc | Where-Object { $_.Ip -eq $Nvr -and $_.Mask } | Select-Object -First 1; if ($nd) { $nvrPrefix = Get-ScPrefixFromMask $nd.Mask }; $nvrNet = $Nvr }

  $devs = @()
  foreach ($i in ($targets | Sort-Object { try { ConvertTo-ScUInt $_ } catch { 0 } })) {
    $pq = $q[$i]; $mac = ''; if ($arp.ContainsKey($i)) { $mac = $arp[$i] } elseif ($arpSeen.ContainsKey($i)) { $mac = @($arpSeen[$i])[0] }
    $dd = @($disc | Where-Object { $_.Ip -eq $i }); $sd = $dd | Where-Object { $_.Source -eq 'SADP' } | Select-Object -First 1; $od = $dd | Where-Object { $_.Source -eq 'ONVIF' } | Select-Object -First 1
    if (-not $mac -and $sd) { $mac = $sd.Mac }
    $op = @($ports[$i])
    $brand = ''; if ($sd) { $brand = 'Hikvision' } elseif ($od -and $od.Brand) { $brand = $od.Brand } else { $brand = Get-ScVendor $mac }
    if (-not $brand -or $brand -eq 'other') { if ($op -contains 37777) { $brand = 'Dahua (port 37777)' } elseif ($op -contains 8000 -and $op -contains 554) { $brand = 'Hikvision? (ports 8000+554)' } }
    $model = $(if ($sd) { $sd.Model } elseif ($od) { $od.Model } else { '' })
    $kind = ''
    if ($i -eq $Nvr) { $kind = 'NVR' } elseif ($model -match '^(i?DS-7|DS-9|DS-96|NVR|DHI-NVR|XVR|DVR)' -or $model -match 'NVR|DVR') { $kind = 'NVR/DVR' } elseif ($sd -or $od -or $op -contains 554) { $kind = 'camera' } elseif ($op -contains 37777) { $kind = 'camera/NVR' }
    # 2.2.20 (Codex 2.2.19 class C, second pass): no ping could even be SENT to it = not checked (loss unknown), never 100% loss
    $loss = $(if ($pq.Sent) { [math]::Round(100.0 * ($pq.Sent - $pq.Ok) / $pq.Sent) } else { $null })
    $diff = $false; if ($nvrNet -and $i -ne $Nvr) { $diff = -not (Test-ScSameSubnet $i $nvrNet $nvrPrefix) }
    if ($sd -and $sd.Mask -and $sd.Gateway -and $nvrNet) { $diff = -not (Test-ScSameSubnet $sd.Ip $nvrNet $nvrPrefix) }
    $devs += [pscustomobject]@{ Ip = $i; Mac = $mac; Vendor = $brand; Model = $model; Kind = $kind; Sent = $pq.Sent; Ok = $pq.Ok; LossPct = $loss; Median = (Get-ScMedian $pq.Rtt); Max = $(if ($pq.Rtt.Count) { ($pq.Rtt | Measure-Object -Maximum).Maximum } else { $null }); Ports = $op; InArp = [bool]$mac; DiffSubnet = $diff; Firmware = $(if ($sd) { $sd.Firmware } else { '' }); Source = (@($dd | ForEach-Object { $_.Source }) -join '+'); PingNotSent = (-not $pq.Sent) }
  }
  # SADP devices on a different IP scheme (not reachable by ping from here)
  foreach ($d in $disc) { if ($d.Source -eq 'SADP' -and $d.Ip -and -not ($devs | Where-Object { $_.Ip -eq $d.Ip })) { $devs += [pscustomobject]@{ Ip = $d.Ip; Mac = $d.Mac; Vendor = 'Hikvision'; Model = $d.Model; Kind = $(if ($d.Model -match '^(i?DS-7|DS-9)') { 'NVR/DVR' } else { 'camera' }); Sent = 0; Ok = 0; LossPct = 100; Median = $null; Max = $null; Ports = @(); InArp = $false; DiffSubnet = $true; Firmware = $d.Firmware; Source = 'SADP (other IP scheme)' } } }
  $R.devices = $devs
  if ($nv -and $nv.Ok) { $R.channels = @($nv.Channels) }
  $R.finished = (Get-Date).ToString('s'); $R.seconds = [int]((Get-Date) - $t0).TotalSeconds
  return $R
}

# ======================= DIAGNOSIS (plain English) =======================
function Get-ScDiagnosis($R) {
  $lines = New-Object System.Collections.Generic.List[string]; $find = @()
  $devs = @($R.devices); $chs = @($R.channels); $dups = @($R.duplicates)
  $nvr = [string]$R.nvr
  $byIp = @{}; foreach ($d in $devs) { $byIp[[string]$d.Ip] = $d }
  $dupIps = @{}; foreach ($x in $dups) { $dupIps[[string]$x.ip] = $x }
  $localPrefixes = @(); foreach ($n in @($R.nets)) { $localPrefixes += (Get-ScNet24 ([string]$n.ip)) }
  if ($nvr) { $localPrefixes += (Get-ScNet24 $nvr) }
  $head = ''
  # NVR itself
  $nvrDev = $null; if ($nvr) { $nvrDev = $byIp[$nvr] }
  # 2.2.3 (Codex #63): no ping answer is not "down" when its login / API or its ports answered (ping can be turned off)
  $nvrAlive = ($R.nvrRead -and $R.nvrRead.ok) -or ($nvrDev -and @($nvrDev.Ports).Count)
  if ($nvr -and (-not $nvrDev -or $nvrDev.Ok -eq 0) -and $nvrAlive) {
    $find += [pscustomobject]@{ Level = 'info'; Text = ('NVR ' + $nvr + ' does not answer ping, but ' + $(if ($R.nvrRead -and $R.nvrRead.ok) { 'it answered the login' } else { 'its ports ' + (@($nvrDev.Ports) -join '/') + ' are open' }) + ' - it is working (ping is turned off on it).') }
  } elseif ($nvr -and (-not $nvrDev -or $nvrDev.Ok -eq 0)) {
    $nvrArp = ($nvrDev -and $nvrDev.InArp)
    $find += [pscustomobject]@{ Level = 'bad'; Text = ('NVR ' + $nvr + ' is NOT answering. ' + $(if ($nvrArp) { 'Something holds that address but does not reply to ping - NVR may be frozen. Power-cycle the NVR.' } else { 'Check the NVR has power and its network cable/switch port is lit, or that the NVR address is right.' })) }
  } elseif ($nvrDev -and $nvrDev.LossPct -ge 5) {
    $find += [pscustomobject]@{ Level = 'warn'; Text = ('NVR ' + $nvr + ' drops ' + $nvrDev.LossPct + '% of pings - check the NVR''s network cable and switch port.') }
  }
  if ($R.nvrRead -and -not $R.nvrRead.ok) { $find += [pscustomobject]@{ Level = 'warn'; Text = ('NVR login: ' + $R.nvrRead.msg) } }
  # channels from the NVR
  # 2.2.19 (sweep2, class C): a channel the NVR gave no state for is NOT CHECKED (amber), not OFFLINE (red) - red only for a state READ as down
  $unk = @($chs | Where-Object { $_.PSObject.Properties['Known'] -and -not $_.Known })
  $off = @($chs | Where-Object { -not $_.Online -and -not ($_.PSObject.Properties['Known'] -and -not $_.Known) })
  foreach ($c in $unk) { $find += [pscustomobject]@{ Level = 'warn'; Text = ('ch ' + $c.Ch + $(if ($c.Ip) { '  ' + $c.Ip } else { '' }) + $(if ($c.Name) { '  "' + $c.Name + '"' } else { '' }) + ' - NOT CHECKED: the NVR''s answer had no online/offline state for this channel.') } }
  $deadCount = 0
  foreach ($c in $off) {
    $ip = [string]$c.Ip; $d = $null; if ($ip) { $d = $byIp[$ip] }
    $label = 'ch ' + $c.Ch + $(if ($ip) { '  ' + $ip } else { '' }) + $(if ($c.Name) { '  "' + $c.Name + '"' } else { '' })
    $det = [string]$c.Detail; $why = ''
    $onLan = $false; foreach ($p in $localPrefixes) { if ($ip -and $ip.StartsWith($p + '.')) { $onLan = $true } }
    if ($ip -and $dupIps.ContainsKey($ip)) { $why = 'IP CONFLICT: two devices use ' + $ip + ' (' + (@($dupIps[$ip].macs) -join ', ') + '). Give one of them a new address.' }
    elseif ($det -match 'password|user|auth') { $why = 'The camera answers but rejects the NVR''s login (password changed or camera was reset). Fix the camera password in the NVR.' }
    elseif ($det -match 'andwidth|Flow|ipcLimit') { $why = 'The NVR is over its camera bandwidth limit - not a camera fault.' }
    elseif (-not $ip) { $why = 'No camera address set for this channel in the NVR.' }
    elseif ($d -and $d.PSObject.Properties['PingNotSent'] -and $d.PingNotSent -and -not @($d.Ports).Count) { $why = 'NOT CHECKED: this PC could not send a single ping to ' + $ip + ' (its own network error), so it is not known whether the camera answers. Check this PC''s network connection and run the check again.' }   # 2.2.20 (class C)
    elseif (-not $onLan -and -not $d) { $deadCount++; $why = 'This camera is on the NVR''s own PoE ports (' + $ip + '), so only the NVR can see it. Offline there = no power or no link on that PoE port: check the cable/jack, re-seat it at the NVR, or try another NVR port. If a known-good port and cable fail, the camera is dead.' }
    elseif ($d -and $d.Ok -gt 0 -and $d.LossPct -ge 10) { $why = 'The camera answers but drops ' + $d.LossPct + '% of pings - a flaky cable, jack, or switch port (or a PoE port that is browning out). Re-terminate or move it to another port.' }
    elseif ($d -and $d.Ok -gt 0) { $why = 'The camera is ON the network (pings fine' + $(if (@($d.Ports).Count) { ', ports ' + (@($d.Ports) -join '/') + ' open' } else { ', but its video ports are closed' }) + '), but the NVR gets no video. Likely the camera is frozen or its settings changed. Reboot it (unplug its PoE 10 s); if it comes back then goes again, update its firmware.' }
    elseif ($d -and @($d.Ports).Count) { $why = 'The camera does not answer ping (it may be turned off on it), but its ports ' + (@($d.Ports) -join '/') + ' are open, so it is powered and on the network. The NVR gets no video: check the channel''s address / password / protocol in the NVR before rebooting anything.' }   # 2.2.3 (Codex #63)
    elseif ($d -and $d.InArp) { $why = 'Something holds that address but does not answer ping - camera is probably frozen. Reboot it at the PoE switch.' }
    else { $deadCount++; $why = 'Nothing answers at ' + $ip + ' at all: no power or no network link. Check the PoE switch port lights, the cable, and the switch''s power. If it''s only this camera, the camera may be dead.' }
    if ($det -and $det -ne 'Disconnected') { $why += ' (NVR says: ' + $det + ')' }
    $find += [pscustomobject]@{ Level = 'bad'; Text = ($label + ' - ' + $why) }
  }
  if ($deadCount -ge 3) { $find = @([pscustomobject]@{ Level = 'bad'; Text = ('' + $deadCount + ' cameras have no power/link at the same time. That usually means ONE shared thing: a PoE switch (or its power/breaker/UPS) or the cable between switches. Check that switch first.') }) + $find }
  # online channels that are flaky
  foreach ($c in @($chs | Where-Object { $_.Online })) {
    $d = $null; if ($c.Ip) { $d = $byIp[[string]$c.Ip] }
    if ($d -and $d.Ok -gt 0 -and $d.LossPct -ge 10) { $find += [pscustomobject]@{ Level = 'warn'; Text = ('ch ' + $c.Ch + '  ' + $c.Ip + ' is up but drops ' + $d.LossPct + '% of pings - it may drop out again. Check its cable/port.') } }
  }
  # devices (no NVR login or not on the channel list)
  $chIps = @{}; foreach ($c in $chs) { if ($c.Ip) { $chIps[[string]$c.Ip] = 1 } }
  foreach ($d in $devs) {
    if ($chIps.ContainsKey([string]$d.Ip) -or $d.Ip -eq $nvr) { continue }
    $cam = ($d.Kind -match 'camera|NVR') -or ($d.Vendor -match 'Hikvision|Dahua|Uniview')
    if (($cam -or $d.Vendor -match 'Ubiquiti|DrayTek') -and $d.Sent -ge 10 -and $d.Ok -gt 0 -and $d.LossPct -ge 10) { $find += [pscustomobject]@{ Level = 'warn'; Text = ($d.Ip + ' ' + $(if ($d.Vendor) { '(' + $d.Vendor + ') ' } else { '' }) + 'drops ' + $d.LossPct + '% of pings - flaky cable/port.') } }
    if ($d.PSObject.Properties['PingNotSent'] -and $d.PingNotSent -and -not @($d.Ports).Count) { $find += [pscustomobject]@{ Level = 'warn'; Text = ($d.Ip + ' ' + $(if ($d.Vendor) { '(' + $d.Vendor + ') ' } else { '' }) + '- NOT CHECKED: this PC could not send a ping to it.') } }   # 2.2.20 (class C)
    if ($cam -and $d.DiffSubnet) { $find += [pscustomobject]@{ Level = 'warn'; Text = ($d.Ip + ' ' + $d.Model + ' is on a DIFFERENT IP scheme than the NVR (' + $nvr + '), so the NVR can''t reach it. Change its address to the NVR''s scheme.') } }
  }
  # 2.2.19 (sweep2): only a channel READ as offline already names the conflict in its own line
  foreach ($x in $dups) { if (-not ($off | Where-Object { $_.Ip -eq $x.ip })) { $find += [pscustomobject]@{ Level = 'bad'; Text = ('IP CONFLICT at ' + $x.ip + ': answered from ' + (@($x.macs) -join ' and ') + '. Two devices share this address.') } } }
  # comparison with the previous run on this PC
  if ($R.previous) {
    $now = @{}; foreach ($d in $devs) { if ($d.Ok -gt 0) { $now[[string]$d.Ip] = 1 } }
    # 2.2.20 (class C): a device this run could not even ping is NOT CHECKED, not "gone"
    $nsIps = @{}; foreach ($d in $devs) { if ($d.PSObject.Properties['PingNotSent'] -and $d.PingNotSent) { $nsIps[[string]$d.Ip] = 1 } }
    foreach ($g in @($R.previous | Where-Object { $nsIps.ContainsKey([string]$_.ip) -and -not $chIps.ContainsKey([string]$_.ip) })) { $find += [pscustomobject]@{ Level = 'warn'; Text = ($g.ip + ' ' + $(if ($g.vendor) { '(' + $g.vendor + ') ' } else { '' }) + 'answered last time (' + $R.previousWhen + ') - NOT CHECKED now: this PC could not send a ping to it.') } }
    $gone = @($R.previous | Where-Object { -not $now.ContainsKey([string]$_.ip) -and -not $nsIps.ContainsKey([string]$_.ip) -and -not $chIps.ContainsKey([string]$_.ip) })
    foreach ($g in $gone) { $find += [pscustomobject]@{ Level = 'warn'; Text = ($g.ip + ' ' + $(if ($g.vendor) { '(' + $g.vendor + ') ' } else { '' }) + 'answered last time (' + $R.previousWhen + ') but not now.') } }
  }
  # headline
  $camsSeen = @($devs | Where-Object { $_.Ok -gt 0 -and (($_.Kind -match 'camera') -or ($_.Vendor -match 'Hikvision|Dahua|Uniview')) -and $_.Ip -ne $nvr }).Count
  if ($chs.Count) {
    if ($off.Count -eq 0 -and $unk.Count -eq 0) { $head = 'All ' + $chs.Count + ' cameras on the NVR are online.' }
    elseif ($off.Count -eq 0) { $head = '' + ($chs.Count - $unk.Count) + ' of ' + $chs.Count + ' cameras on the NVR are online; ' + $unk.Count + ' NOT CHECKED (no state in the NVR''s answer) - not an all-clear.' }
    else { $head = '' + $off.Count + ' of ' + $chs.Count + ' cameras are NOT working: ' + ((@($off | ForEach-Object { 'ch ' + $_.Ch }) | Select-Object -First 12) -join ', ') + $(if ($unk.Count) { '; ' + $unk.Count + ' NOT CHECKED' } else { '' }) }
  } elseif ($R.nvrRead) { $head = 'Could not read the camera list from the NVR. ' + $camsSeen + ' cameras answer on this network.' }
  else { $head = '' + $camsSeen + ' cameras answer on this network.' + $(if ($nvr) { ' Type the NVR password and run again to see exactly which channels are down.' } else { ' Type the NVR address + password to see which channels are down.' }) }
  $bad = @($find | Where-Object { $_.Level -eq 'bad' }).Count; $warn = @($find | Where-Object { $_.Level -eq 'warn' }).Count
  # 2.2.20 (class C): an ARP table that could not be read is a NOT CHECKED (amber), never the all-clear below
  if ($R.Contains('arpRead') -and $R.arpRead -eq $false) { $find += [pscustomobject]@{ Level = 'warn'; Text = 'ARP table NOT CHECKED: this PC''s neighbour table could not be read, so devices that do not answer ping (and duplicate IPs) may be missing - not an all-clear.' }; $warn++ }
  if (-not $find.Count) { $find += [pscustomobject]@{ Level = 'ok'; Text = 'No network problems found: everything that answered did so on every ping.' } }
  return [pscustomobject]@{ Headline = $head; Findings = $find; Bad = $bad; Warn = $warn }
}
function Format-ScReport($R, $D) {
  $L = New-Object System.Collections.Generic.List[string]
  $L.Add('WIREIT SITE CHECK  ' + $R.started.Replace('T', ' ') + '  on PC ' + $R.pc + '  (v' + $R.version + ', read-only)')
  $L.Add(''); $L.Add($D.Headline); $L.Add('')
  foreach ($f in $D.Findings) { $L.Add($(if ($f.Level -eq 'bad') { '[PROBLEM] ' } elseif ($f.Level -eq 'warn') { '[CHECK]   ' } else { '[OK]      ' }) + $f.Text) }
  $L.Add('')
  $L.Add('This PC: ' + ((@($R.nets) | ForEach-Object { $_.ip + '/' + $_.prefix + ' (' + $_.adapter + ' ' + $_.speed + ')' }) -join '; '))
  if ($R.nvr) { $L.Add('NVR: ' + $R.nvr + $(if ($R.nvrRead) { '  ' + $R.nvrRead.brand + ' ' + $R.nvrRead.model } else { '  (no login - channel status not read)' })) }
  foreach ($n in @($R.notes)) { $L.Add('Note: ' + $n) }
  if (@($R.channels).Count) {
    $L.Add(''); $L.Add('NVR CHANNELS')
    foreach ($c in @($R.channels)) { $dv = $null; foreach ($x in @($R.devices)) { if ($x.Ip -eq $c.Ip) { $dv = $x } }
      $L.Add(('  ch {0,-3} {1,-16} {2,-8} {3,-22} {4}' -f $c.Ch, $c.Ip, $(if ($c.Online) { 'online' } elseif ($c.PSObject.Properties['Known'] -and -not $c.Known) { 'NOT CHKD' } else { 'OFFLINE' }), $(if ($dv -and $dv.PSObject.Properties['PingNotSent'] -and $dv.PingNotSent) { 'ping NOT SENT ' } elseif ($dv) { 'ping ' + (100 - $dv.LossPct) + '% ok ' + $(if ($dv.Median -ne $null) { '' + $dv.Median + 'ms' } else { '' }) } else { 'not pingable here' }), $c.Name)) }
  }
  $L.Add(''); $L.Add('DEVICES THAT ANSWERED (' + @($R.devices).Count + ')')
  $L.Add('  IP               MAC                VENDOR                 KIND       PINGS   LOSS  MS(med/max) PORTS          MODEL')
  foreach ($dv in @($R.devices)) {
    $L.Add(('  {0,-16} {1,-18} {2,-22} {3,-10} {4,-7} {5,-5} {6,-11} {7,-14} {8}{9}' -f $dv.Ip, $dv.Mac, $dv.Vendor, $dv.Kind, ('' + $dv.Ok + '/' + $dv.Sent), $(if ($null -eq $dv.LossPct) { 'n/a' } else { '' + $dv.LossPct + '%' }), $(if ($dv.Median -ne $null) { '' + $dv.Median + '/' + $dv.Max } else { '-' }), (@($dv.Ports) -join ','), $dv.Model, $(if ($dv.DiffSubnet) { '  <- other IP scheme' } else { '' })))
  }
  if (@($R.duplicates).Count) { $L.Add(''); $L.Add('DUPLICATE IPs'); foreach ($x in @($R.duplicates)) { $L.Add('  ' + $x.ip + ': ' + (@($x.macs) -join ', ')) } }
  $L.Add(''); $L.Add('Checked in ' + $R.seconds + ' s. Nothing was changed on any device.')
  return ($L -join "`r`n")
}
function Save-ScReport($R, $D, [string]$dir) {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $txt = Format-ScReport $R $D
  $base = Join-Path $dir ('SiteCheck-' + $stamp)
  [IO.File]::WriteAllText($base + '.txt', $txt)
  $o = [ordered]@{}; foreach ($k in $R.Keys) { if ($k -ne 'previous') { $o[$k] = $R[$k] } }; $o.headline = $D.Headline; $o.findings = @($D.Findings)
  [IO.File]::WriteAllText($base + '.json', ($o | ConvertTo-Json -Depth 6))
  $prev = @($R.devices | Where-Object { $_.Ok -gt 0 } | ForEach-Object { [ordered]@{ ip = $_.Ip; mac = $_.Mac; vendor = $_.Vendor } })
  # 2.2.20 (Codex 2.2.19 class C, second pass): a device this run could not ping stays in the comparison as it was last time (not checked
  # is not gone); (class A) last-scan.json feeds the next run's comparison, so it counts as saved only when it reads back as written. A
  # save that fails removes the old one, so the next run compares with nothing rather than with a stale list.
  $nsIps = @{}; foreach ($d in @($R.devices)) { if ($d.PSObject.Properties['PingNotSent'] -and $d.PingNotSent) { $nsIps[[string]$d.Ip] = 1 } }
  foreach ($g in @($R.previous)) { if ($g -and $nsIps.ContainsKey([string]$g.ip)) { $prev += [ordered]@{ ip = [string]$g.ip; mac = [string]$g.mac; vendor = [string]$g.vendor } } }
  $ls = Join-Path $dir 'last-scan.json'; $lsJson = [string]([ordered]@{ when = $R.started; nets = @(Get-ScNetKeys $R.nets); devices = $prev } | ConvertTo-Json -Depth 4)
  $lsOk = $true; $tmp = $ls + '.tmp'
  try { [IO.File]::WriteAllText($tmp, $lsJson); Move-Item -LiteralPath $tmp -Destination $ls -Force -ErrorAction Stop; if ([IO.File]::ReadAllText($ls) -cne $lsJson) { throw 'it does not read back as written' } }
  catch { $lsOk = $false; try { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction Stop } } catch {}; try { if (Test-Path -LiteralPath $ls) { Remove-Item -LiteralPath $ls -Force -ErrorAction Stop } } catch {} }
  return [pscustomobject]@{ Txt = $base + '.txt'; Json = $base + '.json'; Text = $txt; LastScanSaved = $lsOk }
}
# 2.2.3 (Codex #44): the previous scan is compared only when it was taken on the SAME network(s): another site's devices are not "missing" here
function Get-ScNetKeys($nets) {
  $k = @(); foreach ($n in @($nets)) { try { $a = ([Net.IPAddress]::Parse([string]$n.ip)).GetAddressBytes(); $p = [int]$n.prefix; for ($i = 0; $i -lt 4; $i++) { $m = [Math]::Max(0, [Math]::Min(8, $p - 8 * $i)); $a[$i] = $a[$i] -band ((0xFF -shl (8 - $m)) -band 0xFF) }; $k += ((($a | ForEach-Object { [string]$_ }) -join '.') + '/' + $p) } catch {} }
  return @($k | Sort-Object -Unique)
}
function Read-ScPrevious($R, [string]$dir) {
  $p = Join-Path $dir 'last-scan.json'
  if (Test-Path $p) { try { $j = Get-Content $p -Raw | ConvertFrom-Json
    $now = @(Get-ScNetKeys $R.nets); $then = @($j.nets | Where-Object { $_ })
    if ($then.Count -and $now.Count -and @($now | Where-Object { $then -contains $_ }).Count) { $R.previous = @($j.devices); $R.previousWhen = ([string]$j.when).Replace('T', ' ') }
  } catch { $R.notes = @($R.notes) + @('the previous scan (last-scan.json) could not be read, so this run is NOT compared with it') } }   # 2.2.20 (class C): said, not silent
}
# Upload to the site page: OFF until the server side exists (see INTEGRATION.md). Never sends passwords.
function Send-ScReport($R, $D, [string]$siteCode, [string]$uploadCode) {
  # Posts the result to the site page (WireIt service log). Sends channel # + IP + state only: camera NAMES are taken out of the
  # finding lines, and no password or user name is ever in the report. Returns one plain line for the status bar.
  $url = $script:SC_UPLOAD_URL
  $siteCode = ([string]$siteCode).Trim().ToUpper(); $uploadCode = (([string]$uploadCode).ToUpper() -replace '[^A-Z0-9]', '')
  if (-not $url -or -not $siteCode -or -not $uploadCode) { return 'Upload is off (no Site ID / upload code).' }
  if ($siteCode -match '^\d{3,4}$') { $siteCode = 'WI-' + $siteCode }
  $names = @($R.channels | ForEach-Object { [string]$_.Name } | Where-Object { $_ })
  $clean = { param($t) $t = [string]$t; foreach ($n in $names) { $t = $t.Replace('  "' + $n + '"', '').Replace('"' + $n + '"', '') }; $t }
  $body = [ordered]@{ op = 'siteCheckPush'; site = $siteCode; code = $uploadCode; pc = $R.pc; version = $R.version; when = $R.started; headline = (& $clean $D.Headline)
    findings = @($D.Findings | ForEach-Object { [ordered]@{ level = $_.Level; text = (& $clean $_.Text) } })
    channels = @($R.channels | ForEach-Object { [ordered]@{ ch = $_.Ch; ip = $_.Ip; online = $(if ($_.PSObject.Properties['Known'] -and -not $_.Known) { $null } else { [bool]$_.Online }); detail = $_.Detail } })   # 2.2.19 (sweep2): null = NOT CHECKED, not offline
    devices = @($R.devices | ForEach-Object { [ordered]@{ ip = $_.Ip; mac = $_.Mac; vendor = $_.Vendor; kind = $_.Kind; loss = $_.LossPct; ms = $_.Median; ports = @($_.Ports) } }) }
  $json = $body | ConvertTo-Json -Depth 5 -Compress
  try {
    $r = Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 20 -UseBasicParsing
    # 2.2.20 (class C): only the page's own ok = true is "posted" (2.2.19 took any truthy ok, e.g. the text "false")
    $okv = $null; $msg = ''; if ($r -is [Collections.IDictionary]) { $okv = $r['ok']; $msg = [string]$r['msg'] } elseif ($r) { $okv = $r.ok; $msg = [string]$r.msg }
    if ($okv -is [bool] -and $okv) { return 'Results posted to the site page.' } else { return ('Not posted: ' + $(if ($msg) { $msg } else { 'the site page did not say it took them' })) }
  } catch { return ('Not posted (no internet or the site page did not answer): ' + $_.Exception.Message) }
}
$script:SC_UPLOAD_URL = 'https://wireit-api.wireitct.workers.dev/'   # the WireIt service log (Cloudflare); op siteCheckPush + per-site upload code

'@
. ([scriptblock]::Create($SC_CODE))

# ======================= MAIN =======================
function Get-ScReportDir {
  $cands = @()
  if ($Launcher) { $cands += (Join-Path (Split-Path -Parent $Launcher) 'SiteCheck-reports') }
  elseif ($PSCommandPath) { $cands += (Join-Path (Split-Path -Parent $PSCommandPath) 'SiteCheck-reports') }
  $dl = Join-Path $env:USERPROFILE 'Downloads'; $cands += (Join-Path $dl 'WireIt-SiteCheck-reports'); $cands += (Join-Path $env:TEMP 'WireIt-SiteCheck-reports')
  foreach ($c in $cands) { try { New-Item -ItemType Directory -Force -Path $c -ErrorAction Stop | Out-Null; $t = Join-Path $c '.w'; [IO.File]::WriteAllText($t, 'x'); Remove-Item $t -Force; return $c } catch {} }
  return $env:TEMP
}
function New-ScMock {
  $R = [ordered]@{ tool = 'WireIt Site Check'; version = $script:SC_VERSION; started = '2026-11-02T13:00:00'; pc = 'TEST-PC'; nets = @([ordered]@{ ip = '192.0.2.50'; prefix = 24; adapter = 'Ethernet'; speed = '1 Gbps' }); nvr = '192.0.2.10'; nvrRead = [ordered]@{ brand = 'Hikvision'; model = 'DS-7732NI-I4/16P'; ok = $true; msg = 'Read 6 camera channels from the NVR.' }; duplicates = @([ordered]@{ ip = '192.0.2.24'; macs = @('C4-2F-90-00-00-24', 'E0-50-8B-00-00-99') }); notes = @(); seconds = 41 }
  function D($ip, $mac, $v, $k, $ok, $med, $ports, $diff = $false, $arp = $true) { [pscustomobject]@{ Ip = $ip; Mac = $mac; Vendor = $v; Model = ''; Kind = $k; Sent = 20; Ok = $ok; LossPct = [math]::Round(100.0 * (20 - $ok) / 20); Median = $(if ($ok) { $med } else { $null }); Max = $(if ($ok) { $med * 3 } else { $null }); Ports = $ports; InArp = $arp; DiffSubnet = $diff; Firmware = ''; Source = '' } }
  $R.devices = @(
    (D '192.0.2.10' 'C4-2F-90-00-00-10' 'Hikvision' 'NVR' 20 1 @(80, 554, 8000)),
    (D '192.0.2.21' 'C4-2F-90-00-00-21' 'Hikvision' 'camera' 20 1 @(80, 554, 8000)),
    (D '192.0.2.22' 'E0-50-8B-00-00-22' 'Dahua' 'camera' 20 2 @(80, 554, 37777)),
    (D '192.0.2.23' 'E0-50-8B-00-00-23' 'Dahua' 'camera' 14 9 @(80, 554, 37777)),
    (D '192.0.2.24' 'C4-2F-90-00-00-24' 'Hikvision' 'camera' 20 1 @(80, 554, 8000)),
    (D '10.0.0.64' 'C4-2F-90-00-00-64' 'Hikvision' 'camera' 0 0 @() $true $false))
  $R.channels = @(
    [pscustomobject]@{ Ch = 1; Ip = '192.0.2.21'; Online = $true; Detail = 'connect'; Name = 'Front door'; Protocol = 'HIKVISION'; Model = '' },
    [pscustomobject]@{ Ch = 2; Ip = '192.0.2.22'; Online = $false; Detail = 'ipcStreamFail'; Name = 'Lobby'; Protocol = 'ONVIF'; Model = '' },
    [pscustomobject]@{ Ch = 3; Ip = '192.0.2.23'; Online = $true; Detail = 'connect'; Name = 'Gym'; Protocol = 'ONVIF'; Model = '' },
    [pscustomobject]@{ Ch = 4; Ip = '192.0.2.24'; Online = $false; Detail = 'netUnreachable'; Name = 'Hall'; Protocol = 'HIKVISION'; Model = '' },
    [pscustomobject]@{ Ch = 5; Ip = '192.0.2.85'; Online = $false; Detail = 'netUnreachable'; Name = 'Back lot'; Protocol = 'HIKVISION'; Model = '' },
    [pscustomobject]@{ Ch = 6; Ip = '192.168.254.7'; Online = $false; Detail = 'netUnreachable'; Name = 'Stairs'; Protocol = 'HIKVISION'; Model = '' })
  return $R
}

if ($LoadOnly) { return }

if ($SelfTest) {
  $R = New-ScMock; $D = Get-ScDiagnosis $R
  Write-Output (Format-ScReport $R $D)
  return
}

function Invoke-ScConsole {
  $cred = $null
  if ($AskPassword -and $Nvr) { $sec = Read-Host ('NVR password for ' + $User + ' (hidden, not saved)') -AsSecureString; if ($sec.Length) { $cred = New-Object PSCredential($User, $sec) } }
  $dir = $(if ($OutDir) { $OutDir } else { Get-ScReportDir })
  $R = Invoke-SiteCheck -Nvr $Nvr -Cred $cred -Pings $Pings -ExtraNets $ExtraNet
  $cred = $null
  Read-ScPrevious $R $dir
  $D = Get-ScDiagnosis $R
  $s = Save-ScReport $R $D $dir
  Write-Output ''; Write-Output $s.Text; Write-Output ''; Write-Output ('Report saved: ' + $s.Txt)
  if (-not $s.LastScanSaved) { Write-Output 'NOTE: this scan could not be saved for the next run''s comparison (last-scan.json), so the next run is not compared with anything.' }   # 2.2.20 (class A)
  if ($Site -and $UploadCode) { Write-Output (Send-ScReport $R $D $Site $UploadCode) }
}
if ($NoWindow) { Invoke-ScConsole; if ($Launcher) { Read-Host 'Press Enter to close' | Out-Null }; return }

# ---------- window ----------
$hideConsole = $false
try {
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing -ErrorAction Stop
  try { Add-Type -Namespace WSC -Name Win -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n); [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -ErrorAction Stop; [void][WSC.Win]::SetProcessDPIAware(); $hideConsole = $true } catch {}
  [Windows.Forms.Application]::EnableVisualStyles()
} catch {
  if ($Launcher) {   # started hidden by the .cmd: open a visible console instead
    $cmdTxt = '$s=[IO.File]::ReadAllText(''' + $Launcher.Replace("'", "''") + '''); $i=$s.IndexOf(''##''+''PSSTART''); & ([scriptblock]::Create($s.Substring($i))) -NoWindow -AskPassword -Launcher ''' + $Launcher.Replace("'", "''") + ''''
    Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmdTxt); return
  }
  Write-Host ('Could not open the window (' + $_.Exception.Message + '). Running in this console instead.')
  if (-not $Nvr) { $Nvr = Read-Host 'NVR address (Enter to skip)' }; $AskPassword = $true; Invoke-ScConsole; return
}
$fontUi = 'Segoe UI'
$navy = [Drawing.Color]::FromArgb(43, 47, 54); $red = [Drawing.Color]::FromArgb(200, 32, 38); $green = [Drawing.Color]::FromArgb(22, 128, 61); $amber = [Drawing.Color]::FromArgb(180, 110, 0)
$f = New-Object Windows.Forms.Form
$f.Text = 'WireIt Site Check'; $f.ClientSize = New-Object Drawing.Size(1000, 740); $f.StartPosition = 'CenterScreen'; $f.BackColor = [Drawing.Color]::FromArgb(244, 245, 247)
$f.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96); $f.AutoScaleMode = 'Dpi'; $f.Font = New-Object Drawing.Font($fontUi, 10); $f.MinimumSize = New-Object Drawing.Size(820, 600)
$hdr = New-Object Windows.Forms.Panel; $hdr.Dock = 'Top'; $hdr.Height = 64; $hdr.BackColor = $navy
$t1 = New-Object Windows.Forms.Label; $t1.Text = 'WireIt Site Check'; $t1.ForeColor = [Drawing.Color]::White; $t1.Font = New-Object Drawing.Font($fontUi, 18, [Drawing.FontStyle]::Bold); $t1.AutoSize = $true; $t1.Location = New-Object Drawing.Point(18, 12)
$t2 = New-Object Windows.Forms.Label; $t2.Text = 'Finds which cameras are down and why. Read-only: changes nothing.  v' + $script:SC_VERSION; $t2.ForeColor = [Drawing.Color]::FromArgb(200, 205, 212); $t2.AutoSize = $true; $t2.Location = New-Object Drawing.Point(280, 25)
$stripe = New-Object Windows.Forms.Panel; $stripe.Dock = 'Top'; $stripe.Height = 4; $stripe.BackColor = $red
$hdr.Controls.AddRange(@($t1, $t2))
$in = New-Object Windows.Forms.Panel; $in.Dock = 'Top'; $in.Height = 150; $in.Padding = New-Object Windows.Forms.Padding(16, 10, 16, 4)
function New-L($txt, $x, $y) { $l = New-Object Windows.Forms.Label; $l.Text = $txt; $l.AutoSize = $true; $l.Location = New-Object Drawing.Point($x, $y); $l.ForeColor = [Drawing.Color]::FromArgb(70, 75, 85); return $l }
$lNvr = New-L 'NVR address' 18 8; $tNvr = New-Object Windows.Forms.TextBox; $tNvr.Location = New-Object Drawing.Point(18, 30); $tNvr.Width = 170; $tNvr.Font = New-Object Drawing.Font($fontUi, 12); $tNvr.Text = $Nvr
$lUser = New-L 'User' 200 8; $tUser = New-Object Windows.Forms.TextBox; $tUser.Location = New-Object Drawing.Point(200, 30); $tUser.Width = 110; $tUser.Font = New-Object Drawing.Font($fontUi, 12); $tUser.Text = $User
$lPw = New-L 'NVR password (optional)' 322 8; $tPw = New-Object Windows.Forms.TextBox; $tPw.Location = New-Object Drawing.Point(322, 30); $tPw.Width = 200; $tPw.Font = New-Object Drawing.Font($fontUi, 12); $tPw.UseSystemPasswordChar = $true
$bGo = New-Object Windows.Forms.Button; $bGo.Text = 'Start check'; $bGo.Location = New-Object Drawing.Point(540, 22); $bGo.Size = New-Object Drawing.Size(200, 46); $bGo.FlatStyle = 'Flat'; $bGo.FlatAppearance.BorderSize = 0; $bGo.BackColor = $green; $bGo.ForeColor = [Drawing.Color]::White; $bGo.Font = New-Object Drawing.Font($fontUi, 13, [Drawing.FontStyle]::Bold)
$lSite = New-L 'Site ID (optional, e.g. WI-061)' 18 66; $tSite = New-Object Windows.Forms.TextBox; $tSite.Location = New-Object Drawing.Point(18, 88); $tSite.Width = 170; $tSite.Font = New-Object Drawing.Font($fontUi, 12); $tSite.Text = $Site
$lCode = New-L 'Upload code (optional)' 200 66; $tCode = New-Object Windows.Forms.TextBox; $tCode.Location = New-Object Drawing.Point(200, 88); $tCode.Width = 110; $tCode.Font = New-Object Drawing.Font($fontUi, 12); $tCode.CharacterCasing = 'Upper'; $tCode.MaxLength = 6; $tCode.Text = $UploadCode
$lUp = New-L 'Fill both to put the result on the site page (code from the Remote check card).' 322 92
$hint = New-L 'Leave the address blank to find the NVR automatically. The password is used once to read which channels are offline and is never saved.' 18 124
$in.Controls.AddRange(@($lNvr, $tNvr, $lUser, $tUser, $lPw, $tPw, $bGo, $lSite, $tSite, $lCode, $tCode, $lUp, $hint))
$st = New-Object Windows.Forms.Label; $st.Dock = 'Top'; $st.Height = 34; $st.Padding = New-Object Windows.Forms.Padding(18, 6, 0, 0); $st.Font = New-Object Drawing.Font($fontUi, 11); $st.Text = 'Ready. Press Start check (takes about 1 minute).'; $st.ForeColor = [Drawing.Color]::FromArgb(60, 64, 72)
$head = New-Object Windows.Forms.Label; $head.Dock = 'Top'; $head.Height = 58; $head.Padding = New-Object Windows.Forms.Padding(18, 4, 18, 0); $head.Font = New-Object Drawing.Font($fontUi, 17, [Drawing.FontStyle]::Bold); $head.Text = ''
$rt = New-Object Windows.Forms.RichTextBox; $rt.Dock = 'Fill'; $rt.ReadOnly = $true; $rt.BorderStyle = 'None'; $rt.BackColor = [Drawing.Color]::White; $rt.Font = New-Object Drawing.Font($fontUi, 13); $rt.DetectUrls = $false
$rtWrap = New-Object Windows.Forms.Panel; $rtWrap.Dock = 'Fill'; $rtWrap.Padding = New-Object Windows.Forms.Padding(16, 6, 16, 6); $rtWrap.Controls.Add($rt)
$bot = New-Object Windows.Forms.FlowLayoutPanel; $bot.Dock = 'Bottom'; $bot.Height = 58; $bot.Padding = New-Object Windows.Forms.Padding(14, 8, 14, 8)
function New-B($txt) { $b = New-Object Windows.Forms.Button; $b.Text = $txt; $b.AutoSize = $false; $b.Size = New-Object Drawing.Size(190, 40); $b.FlatStyle = 'Flat'; $b.BackColor = [Drawing.Color]::White; $b.Font = New-Object Drawing.Font($fontUi, 11); $b.Enabled = $false; return $b }
$bCopy = New-B 'Copy results'; $bOpen = New-B 'Open report folder'; $bFull = New-B 'Show full details'; $bClose = New-B 'Close'; $bClose.Enabled = $true
$bot.Controls.AddRange(@($bCopy, $bOpen, $bFull, $bClose))
$f.Controls.Add($rtWrap); $f.Controls.Add($head); $f.Controls.Add($st); $f.Controls.Add($in); $f.Controls.Add($stripe); $f.Controls.Add($hdr); $f.Controls.Add($bot)
$f.AcceptButton = $bGo

$script:last = $null; $script:full = $false
function Show-ScResult($R, $D, $saved) {
  $head.Text = $D.Headline; $head.ForeColor = $(if ($D.Bad) { $red } elseif ($D.Warn) { $amber } else { $green })
  $rt.Clear(); $rt.Font = New-Object Drawing.Font($fontUi, 13)
  foreach ($x in $D.Findings) {
    $rt.SelectionStart = $rt.TextLength; $rt.SelectionColor = $(if ($x.Level -eq 'bad') { $red } elseif ($x.Level -eq 'warn') { $amber } else { $green })
    $rt.SelectionFont = New-Object Drawing.Font($fontUi, 13, [Drawing.FontStyle]::Bold); $rt.AppendText($(if ($x.Level -eq 'bad') { 'PROBLEM  ' } elseif ($x.Level -eq 'warn') { 'CHECK  ' } else { 'OK  ' }))
    $rt.SelectionColor = [Drawing.Color]::FromArgb(30, 32, 36); $rt.SelectionFont = New-Object Drawing.Font($fontUi, 13); $rt.AppendText($x.Text + "`r`n`r`n")
  }
  if ($saved) { $rt.SelectionColor = [Drawing.Color]::Gray; $rt.SelectionFont = New-Object Drawing.Font($fontUi, 10); $rt.AppendText('Full report saved: ' + $saved.Txt) }
  $rt.SelectionStart = 0; $rt.ScrollToCaret()
}
$sync = [hashtable]::Synchronized(@{ Log = (New-Object System.Collections.ArrayList); Done = $false; R = $null; Err = '' })
$script:ps = $null; $script:rs = $null
$timer = New-Object Windows.Forms.Timer; $timer.Interval = 300
$timer.Add_Tick({
  while ($sync.Log.Count -gt 0) { $m = $sync.Log[0]; $sync.Log.RemoveAt(0); $st.Text = $m }
  if ($sync.Done) {
    $timer.Stop(); $sync.Done = $false
    try { if ($script:ps) { $script:ps.Dispose() }; if ($script:rs) { $script:rs.Close(); $script:rs.Dispose() } } catch {}
    $script:ps = $null; $script:rs = $null
    $bGo.Enabled = $true; $bGo.Text = 'Run again'
    if ($sync.Err) { $st.Text = 'The check stopped: ' + $sync.Err; return }
    $R = $sync.R; if ($R.nvr -and -not $tNvr.Text.Trim()) { $tNvr.Text = [string]$R.nvr }; $dir = Get-ScReportDir; Read-ScPrevious $R $dir; $D = Get-ScDiagnosis $R; $saved = $null
    try { $saved = Save-ScReport $R $D $dir } catch { $st.Text = 'Could not save the report: ' + $_.Exception.Message }
    $script:last = [pscustomobject]@{ R = $R; D = $D; Saved = $saved; Dir = $dir }
    Show-ScResult $R $D $saved; $st.Text = 'Done in ' + $R.seconds + ' s. Nothing was changed on any device.' + $(if ($saved -and -not $saved.LastScanSaved) { ' (This scan could not be saved for the next run''s comparison.)' } else { '' })
    if ($tSite.Text.Trim() -and $tCode.Text.Trim()) { $st.Text = 'Posting the result to the site page...'; [Windows.Forms.Application]::DoEvents(); $st.Text = 'Done in ' + $R.seconds + ' s. ' + (Send-ScReport $R $D $tSite.Text $tCode.Text) }
    $bCopy.Enabled = $true; $bOpen.Enabled = $true; $bFull.Enabled = $true; $script:full = $false; $bFull.Text = 'Show full details'
  }
})
$bGo.Add_Click({
  $nvrTxt = $tNvr.Text.Trim()
  if ($nvrTxt -and -not (Test-ScIp $nvrTxt)) { $st.Text = 'The NVR address should look like 192.168.1.100 (or leave it blank).'; return }
  $cred = $null
  if ($tPw.Text.Length) {
    if (-not $nvrTxt) { $st.Text = 'Type the NVR address too, so the password goes only to the NVR.'; return }
    $sec = New-Object Security.SecureString; foreach ($ch in $tPw.Text.ToCharArray()) { $sec.AppendChar($ch) }; $sec.MakeReadOnly()
    $cred = New-Object PSCredential($(if ($tUser.Text.Trim()) { $tUser.Text.Trim() } else { 'admin' }), $sec)
  }
  $tPw.Text = ''
  $bGo.Enabled = $false; $bGo.Text = 'Checking...'; $head.Text = ''; $rt.Clear(); $bCopy.Enabled = $false; $bOpen.Enabled = $false; $bFull.Enabled = $false
  $sync.Log.Clear(); $sync.Done = $false; $sync.R = $null; $sync.Err = ''
  $script:rs = [runspacefactory]::CreateRunspace(); $script:rs.ApartmentState = 'MTA'; $script:rs.Open()
  $script:rs.SessionStateProxy.SetVariable('sync', $sync); $script:rs.SessionStateProxy.SetVariable('cred', $cred); $script:rs.SessionStateProxy.SetVariable('nvrIp', $nvrTxt); $script:rs.SessionStateProxy.SetVariable('pings', $Pings); $script:rs.SessionStateProxy.SetVariable('extra', $ExtraNet)
  $script:ps = [powershell]::Create(); $script:ps.Runspace = $script:rs
  [void]$script:ps.AddScript($SC_CODE).AddScript({ try { $sync.R = Invoke-SiteCheck -Nvr $nvrIp -Cred $cred -Pings $pings -ExtraNets $extra -Say { param($s) [void]$sync.Log.Add($s) } } catch { $sync.Err = $_.Exception.Message } finally { $cred = $null; $sync.Done = $true } })
  [void]$script:ps.BeginInvoke(); $cred = $null
  $timer.Start()
})
$bCopy.Add_Click({ if ($script:last) { try { [Windows.Forms.Clipboard]::SetText($script:last.Saved.Text); $st.Text = 'Copied. Paste it into WhatsApp/text/email.' } catch { $st.Text = 'Could not copy: ' + $_.Exception.Message } } })
$bOpen.Add_Click({ if ($script:last) { Start-Process explorer.exe -ArgumentList ('"' + $script:last.Dir + '"') } })
$bFull.Add_Click({ if (-not $script:last) { return }; if ($script:full) { Show-ScResult $script:last.R $script:last.D $script:last.Saved; $bFull.Text = 'Show full details'; $script:full = $false } else { $rt.Clear(); $rt.Font = New-Object Drawing.Font('Consolas', 10); $rt.Text = $script:last.Saved.Text; $bFull.Text = 'Show summary'; $script:full = $true } })
$bClose.Add_Click({ $f.Close() })
$f.Add_FormClosing({ $timer.Stop(); try { if ($script:ps) { $script:ps.Stop(); $script:ps.Dispose() }; if ($script:rs) { $script:rs.Close(); $script:rs.Dispose() } } catch {} })

if ($Screenshot) {
  $R = New-ScMock; $D = Get-ScDiagnosis $R; $tNvr.Text = '192.0.2.10'
  Show-ScResult $R $D ([pscustomobject]@{ Txt = 'C:\Users\you\Downloads\SiteCheck-reports\SiteCheck-20261102-130000.txt' }); $st.Text = 'Done in 41 s. Nothing was changed on any device.'; $bCopy.Enabled = $true; $bOpen.Enabled = $true; $bFull.Enabled = $true
  $f.ShowInTaskbar = $false; $f.StartPosition = 'Manual'; $f.Location = New-Object Drawing.Point(-4000, -4000); $f.Opacity = 0
  $f.Show(); [Windows.Forms.Application]::DoEvents()
  $bmp = New-Object Drawing.Bitmap($f.Width, $f.Height); $f.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $f.Width, $f.Height)))
  try {   # a RichTextBox draws blank in DrawToBitmap; print its contents into the same spot (EM_FORMATRANGE)
    Add-Type -TypeDefinition @"
using System; using System.Drawing; using System.Runtime.InteropServices; using System.Windows.Forms;
public static class WscRtf {
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] struct CHARRANGE { public int cpMin, cpMax; }
  [StructLayout(LayoutKind.Sequential)] struct FORMATRANGE { public IntPtr hdc, hdcTarget; public RECT rc, rcPage; public CHARRANGE chrg; }
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
  public static void Draw(RichTextBox rt, Graphics g, Rectangle r) {
    IntPtr hdc = g.GetHdc();
    try {
      FORMATRANGE fr = new FORMATRANGE(); fr.hdc = hdc; fr.hdcTarget = hdc;
      fr.rc.Left = r.Left * 15; fr.rc.Top = r.Top * 15; fr.rc.Right = r.Right * 15; fr.rc.Bottom = r.Bottom * 15; fr.rcPage = fr.rc;
      fr.chrg.cpMin = 0; fr.chrg.cpMax = -1;
      IntPtr p = Marshal.AllocCoTaskMem(Marshal.SizeOf(fr)); Marshal.StructureToPtr(fr, p, false);
      SendMessage(rt.Handle, 0x439, (IntPtr)1, p); SendMessage(rt.Handle, 0x439, IntPtr.Zero, IntPtr.Zero); Marshal.FreeCoTaskMem(p);
    } finally { g.ReleaseHdc(hdc); }
  }
}
"@ -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop
    $g = [Drawing.Graphics]::FromImage($bmp); $pt = $f.PointToClient($rt.PointToScreen((New-Object Drawing.Point(0, 0)))); $off = $f.PointToScreen((New-Object Drawing.Point(0, 0)))
    $ox = $off.X - $f.Location.X; $oy = $off.Y - $f.Location.Y
    $rect = New-Object Drawing.Rectangle(($pt.X + $ox), ($pt.Y + $oy), $rt.Width, $rt.Height)
    $g.FillRectangle([Drawing.Brushes]::White, $rect); [WscRtf]::Draw($rt, $g, $rect); $g.Dispose()
  } catch { Write-Output ('rtf draw: ' + $_.Exception.Message) }
  $bmp.Save($Screenshot, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $f.Close(); $f.Dispose()
  Write-Output ('screenshot ' + $Screenshot); return
}
if ($GuiSmoke) {   # test hook: run one real check through the window's own code path, off-screen, then report what it shows
  $f.ShowInTaskbar = $false; $f.StartPosition = 'Manual'; $f.Location = New-Object Drawing.Point(-4000, -4000); $f.Opacity = 0; $f.Show()
  $bGo.PerformClick(); $end = (Get-Date).AddSeconds(85)
  while ((Get-Date) -lt $end -and -not $bGo.Enabled) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
  [Windows.Forms.Application]::DoEvents()
  Write-Output ('HEAD: ' + $head.Text); Write-Output ('STATUS: ' + $st.Text); Write-Output ('FINDINGS: ' + $rt.Text.Substring(0, [math]::Min(300, $rt.Text.Length)))
  Write-Output ('SAVED: ' + $(if ($script:last -and $script:last.Saved) { $script:last.Saved.Txt } else { 'none' }))
  $f.Close(); $f.Dispose(); return
}
if ($hideConsole -and $Launcher) { try { [void][WSC.Win]::ShowWindow([WSC.Win]::GetConsoleWindow(), 0) } catch {} }
[void]$f.ShowDialog()
$f.Dispose()
if ($Launcher) { [Environment]::Exit(0) }
