<#
 NetCheck.ps1 - WireIt CT read-only site network check (Windows PowerShell 5.1, no installs)
 Reads only: ping sweep, ARP, this PC's NIC, camera/NVR ISAPI GETs (+ optional log search).
 Changes nothing on any device.
 Usage:
   .\NetCheck.ps1                               # auto-detect subnet from this PC, no logins
   .\NetCheck.ps1 -Subnet 192.168.1 -User admin   # prompts for the camera password (one try per device)
   .\NetCheck.ps1 -Nvr 192.168.1.20 -Exclude 192.168.1.92,192.168.1.230 -LogDays 7
 Output: .\NetCheck-<time>\ (hosts.csv, summary.txt, raw\)  and summary on screen.
#>
param(
  [string]$Subnet = '',            # first three octets, e.g. 10.1.10
  [int]$From = 1, [int]$To = 254,
  [int]$Rounds = 10,               # pings per host
  [string]$User = '',              # device login user (blank = no logins)
  [string]$CredFile = '',          # optional file: line1 user, line2 password (delete after use)
  [string[]]$Nvr = @(),            # NVR IPs (HTTPS ISAPI), max ONE login try each
  [string[]]$Exclude = @(),        # IPs never to log in to (unknown passwords, lockout risk)
  [int]$LogDays = 0,               # >0: read device logs for the last N days (read-only search)
  [string]$OutDir = ''
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls   # 2.2.2 (re-review): old camera/NVR firmware that only speaks TLS 1.0/1.1 stays on HTTPS
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
[void](Enable-WireItLanTls)   # 2.2.1 (review H2): devices on private addresses only
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutDir) { $OutDir = Join-Path (Get-Location) ('NetCheck-' + $stamp) }
New-Item -ItemType Directory -Force -Path $OutDir, (Join-Path $OutDir 'raw') | Out-Null
$sum = New-Object System.Collections.Generic.List[string]
function Say($s) { Write-Host $s; $sum.Add($s) }

# ---------- this PC ----------
$nics = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.HardwareInterface }
$ipcfg = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254*' -and $_.IPAddress -ne '127.0.0.1' }
Say ('=== NetCheck ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') + ' on ' + $env:COMPUTERNAME + ' ===')
foreach ($n in $nics) {
  $ip = ($ipcfg | Where-Object { $_.InterfaceIndex -eq $n.ifIndex } | Select-Object -First 1).IPAddress
  $st = Get-NetAdapterStatistics -Name $n.Name -ErrorAction SilentlyContinue
  $line = 'PC NIC ' + $n.Name + ' (' + $n.InterfaceDescription + ') ' + $ip + ' link ' + $n.LinkSpeed + ' full-duplex=' + $n.FullDuplex
  if ($st) { $line += ' | rx errors ' + $st.ReceivedPacketErrors + ', rx discards ' + $st.ReceivedDiscardedPackets + ', tx errors ' + $st.OutboundPacketErrors }
  Say $line
  if (-not $Subnet -and $ip) { $Subnet = ($ip -split '\.')[0..2] -join '.' }
}
$gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1).NextHop
Say ('Gateway ' + $gw + ' | subnet ' + $Subnet + '.0/24')
# loop / storm check: what reaches this PC's port in 10 s (an L2 loop shows as hundreds+ broadcasts per second)
$pn = ($nics | Select-Object -First 1).Name
$a = Get-NetAdapterStatistics -Name $pn -ErrorAction SilentlyContinue; Start-Sleep 10; $b = Get-NetAdapterStatistics -Name $pn -ErrorAction SilentlyContinue
if ($a -and $b) {
  $bc = ($b.ReceivedBroadcastPackets - $a.ReceivedBroadcastPackets) / 10; $mc = ($b.ReceivedMulticastPackets - $a.ReceivedMulticastPackets) / 10
  $kb = [int](($b.ReceivedBytes - $a.ReceivedBytes) / 1024 / 10)
  Say ('Traffic into this PC: ' + $kb + ' KB/s, broadcasts ' + $bc + '/s, multicasts ' + $mc + '/s' + $(if ($bc -gt 200) { '  <-- STORM: likely a loop' } else { '  (no broadcast storm)' }))
}

# ---------- ping sweep (all hosts in parallel, $Rounds rounds) ----------
$ips = $From..$To | ForEach-Object { $Subnet + '.' + $_ }
$rtt = @{}; $ok = @{}
foreach ($i in $ips) { $rtt[$i] = New-Object System.Collections.Generic.List[int]; $ok[$i] = 0 }
for ($r = 0; $r -lt $Rounds; $r++) {
  $tasks = @{}
  foreach ($i in $ips) { $tasks[$i] = (New-Object System.Net.NetworkInformation.Ping).SendPingAsync($i, 1500) }
  try { [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($tasks.Values)) } catch {}
  foreach ($i in $ips) { $t = $tasks[$i]; if ($t.Status -eq 'RanToCompletion' -and $t.Result.Status -eq 'Success') { $ok[$i]++; $rtt[$i].Add([int]$t.Result.RoundtripTime) } }
  Start-Sleep -Milliseconds 300
}

# ---------- ARP ----------
$arp = @{}
Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like ($Subnet + '.*') -and $_.State -ne 'Unreachable' -and $_.LinkLayerAddress -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' } | ForEach-Object { $arp[$_.IPAddress] = $_.LinkLayerAddress.ToUpper() }
$oui = @{ 'DC-07-F8'='Hikvision'; '28-57-BE'='Hikvision'; '44-19-B6'='Hikvision'; '4C-BD-8F'='Hikvision'; '54-C4-15'='Hikvision'; '58-03-FB'='Hikvision'; 'BC-AD-28'='Hikvision'; 'C0-56-E3'='Hikvision'; 'C4-2F-90'='Hikvision'; 'E0-50-8B'='Hikvision'; '18-68-CB'='Hikvision'; '24-48-45'='Hikvision'; '80-BE-AF'='Hikvision'; 'A4-14-37'='Hikvision'; '8C-E7-48'='Hikvision'; '94-E1-AC'='Hikvision'; 'BC-BA-C2'='Hikvision'; '64-DB-8B'='Hikvision'; '98-DF-82'='Hikvision'; 'E0-CA-3C'='Hikvision'; '08-A1-89'='Hikvision'; '24-0F-9B'='Hikvision'; '2C-A5-9C'='Hikvision'; '40-AC-BF'='Hikvision'; '44-47-CC'='Hikvision'; '4C-F5-DC'='Hikvision'; '68-6D-BC'='Hikvision'; '84-94-37'='Hikvision'; 'AC-B9-2F'='Hikvision'; 'B4-A3-82'='Hikvision'; 'C8-A7-02'='Hikvision'; '1C-6A-1B'='Ubiquiti'; '24-5A-4C'='Ubiquiti'; '74-83-C2'='Ubiquiti'; '78-8A-20'='Ubiquiti'; '80-2A-A8'='Ubiquiti'; 'B4-FB-E4'='Ubiquiti'; 'D0-21-F9'='Ubiquiti'; 'E0-63-DA'='Ubiquiti'; 'F0-9F-C2'='Ubiquiti'; 'FC-EC-DA'='Ubiquiti'; '68-D7-9A'='Ubiquiti'; '18-E8-29'='Ubiquiti'; 'AC-8B-A9'='Ubiquiti'; '9C-05-D6'='Ubiquiti'; '60-22-32'='Ubiquiti' }
function Vendor($mac) {
  if (-not $mac) { return '' }
  $p = $mac.Substring(0,8); if ($oui.ContainsKey($p)) { return $oui[$p] }
  $b = [Convert]::ToInt32($mac.Substring(0,2),16); if ($b -band 2) { return 'locally-administered' }
  return '?'
}
function Med($l) { if ($l.Count -eq 0) { return $null }; $s = $l | Sort-Object; return $s[[int][math]::Floor(($s.Count-1)/2)] }
function Band($m) { if ($m -eq $null) { 'NO-REPLY' } elseif ($m -le 5) { 'FAST(<=5ms)' } elseif ($m -le 50) { 'MID(6-50ms)' } elseif ($m -le 300) { 'SLOW(51-300ms)' } else { 'VERY-SLOW(>300ms)' } }

# ---------- TCP ports ----------
function Port($ip, $p) { $c = New-Object Net.Sockets.TcpClient; try { $a = $c.ConnectAsync($ip, $p); if ($a.Wait(1500) -and $c.Connected) { return $true } } catch {} finally { $c.Close() }; return $false }

# ---------- credentials ----------
$cred = $null
if ($CredFile -and (Test-Path $CredFile)) { $cl = Get-Content $CredFile; $User = $cl[0]; $sec = ConvertTo-SecureString $cl[1] -AsPlainText -Force; $cred = New-Object PSCredential($User, $sec) }
elseif ($User) { $sec = Read-Host ('Password for ' + $User + ' (input hidden)') -AsSecureString; $cred = New-Object PSCredential($User, $sec) }

# 2.2.7 (Codex file-by-file F06): over plain HTTP a password is only answered to a Digest challenge (the password itself never
# crosses the wire). A device - or a box pretending to be one - that asks only for Basic gets NO password over plain HTTP.
# Same check in FixNVR.ps1, CamViews.ps1, NetCheck.ps1 and SiteCheck.ps1 (FixSite and NvrHealth have had it since 2.2.3).
$script:WiAuthSeen = @{}
function Test-WireItPlainBasicOnly([string]$uri) {
  $u = $null; try { $u = [uri]$uri } catch { return $false }
  if (-not $u -or $u.Scheme -ne 'http') { return $false }
  $k = $u.Authority; if ($script:WiAuthSeen.ContainsKey($k)) { return [bool]$script:WiAuthSeen[$k] }
  $basicOnly = $false
  try { $rq = [Net.HttpWebRequest]::Create($u); $rq.Method = 'GET'; $rq.Timeout = 6000; $rq.AllowAutoRedirect = $false; $rs = $rq.GetResponse(); $rs.Close() }
  catch { $ex = $_.Exception; while ($ex -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }
    if ($ex -and $ex.Response) { $h = [string]$ex.Response.Headers['WWW-Authenticate']; if ($h -match '(?i)\bbasic\b' -and $h -notmatch '(?i)\bdigest\b') { $basicOnly = $true }; try { $ex.Response.Close() } catch {} } }
  $script:WiAuthSeen[$k] = $basicOnly; return $basicOnly
}
# 2.2.7 (F06): the request arguments: the password only to a Digest challenge over plain HTTP (PowerShell 7 needs the explicit
# AllowUnencryptedAuthentication for that; the Basic-only refusal above is what keeps it from ever sending Basic in clear)
function Get-NcIsapiArgs([string]$uri) { $a = @{ Uri = $uri; Credential = $cred; UseBasicParsing = $true }; if ($PSVersionTable.PSVersion.Major -ge 6 -and $uri -like 'http://*') { $a.AllowUnencryptedAuthentication = $true }; return $a }
function Get-Isapi($base, $path) {
  if ($cred -and (Test-WireItPlainBasicOnly ($base + $path))) { return @{ code = 0; body = ''; err = 'plain HTTP with Basic login only - the password was not sent' } }
  try { $a = Get-NcIsapiArgs ($base + $path); $r = Invoke-WebRequest @a -TimeoutSec 8; return @{ code = 200; body = $r.Content } }
  catch { $c = 0; try { $c = [int]$_.Exception.Response.StatusCode } catch {}; return @{ code = $c; body = '' } }
}
function Post-Isapi($base, $path, $xml) {
  if ($cred -and (Test-WireItPlainBasicOnly ($base + $path))) { return @{ code = 0; body = ''; err = 'plain HTTP with Basic login only - the password was not sent' } }
  try { $a = Get-NcIsapiArgs ($base + $path); $r = Invoke-WebRequest @a -Method Post -Body $xml -ContentType 'application/xml' -TimeoutSec 15; return @{ code = 200; body = $r.Content } }
  catch { $c = 0; try { $c = [int]$_.Exception.Response.StatusCode } catch {}; return @{ code = $c; body = '' } }
}
function Tag($xml, $t) { $m = [regex]::Match($xml, '<' + $t + '>([^<]*)</' + $t + '>'); if ($m.Success) { return $m.Groups[1].Value } else { return '' } }
function Up($sec) { if (-not $sec) { return '' }; $ts = [TimeSpan]::FromSeconds([double]$sec); return ('{0}d{1}h{2}m' -f $ts.Days, $ts.Hours, $ts.Minutes) }
function Read-Logs($base, $ip) {
  $st = (Get-Date).ToUniversalTime().AddDays(-$LogDays).ToString('yyyy-MM-ddTHH:mm:ssZ'); $en = (Get-Date).ToUniversalTime().AddHours(14).ToString('yyyy-MM-ddTHH:mm:ssZ')
  $xml = '<?xml version="1.0" encoding="UTF-8"?><CMSearchDescription><searchID>' + [guid]::NewGuid().ToString().ToUpper() + '</searchID><metaId>log.std-cgi.com</metaId><timeSpanList><timeSpan><startTime>' + $st + '</startTime><endTime>' + $en + '</endTime></timeSpan></timeSpanList><maxResults>200</maxResults><searchResultPostion>0</searchResultPostion></CMSearchDescription>'
  $r = Post-Isapi $base '/ISAPI/ContentMgmt/logSearch' $xml
  if ($r.code -eq 200) { $r.body | Set-Content (Join-Path $OutDir ('raw\log-' + $ip + '.xml')) }
  $ms = [regex]::Matches($r.body, '<metaId>log\.std-cgi\.com/([^<]+)</metaId>')
  $cnt = @{}; foreach ($m in $ms) { $k = $m.Groups[1].Value; if ($k -match 'net|Net|disconn|broken|ipc|IPC|offline|Offline|power|Power|reboot|Reboot|start|Start') { if ($cnt.ContainsKey($k)) { $cnt[$k]++ } else { $cnt[$k] = 1 } } }
  return (($cnt.Keys | ForEach-Object { $_ + '=' + $cnt[$_] }) -join ' ')
}

# ---------- per host ----------
$rows = New-Object System.Collections.Generic.List[object]
foreach ($i in $ips) {
  $mac = $arp[$i]
  if ($ok[$i] -gt 0 -or $mac) { Write-Host ('  checking ' + $i) }
  if ($ok[$i] -eq 0 -and -not $mac) { continue }
  $m = Med $rtt[$i]
  $row = [ordered]@{ ip = $i; mac = $mac; vendor = (Vendor $mac); replies = ('{0}/{1}' -f $ok[$i], $Rounds); loss_pct = [int](100 * ($Rounds - $ok[$i]) / $Rounds); rtt_min = ''; rtt_med = $m; rtt_max = ''; band = (Band $m); http = ''; https = ''; sdk8000 = ''; auth = ''; model = ''; serial = ''; firmware = ''; uptime = ''; up_sec = ''; link_speed = ''; link_duplex = ''; link_auto = ''; streams_to = ''; logs = ''; note = '' }
  if ($rtt[$i].Count) { $row.rtt_min = ($rtt[$i] | Measure-Object -Minimum).Minimum; $row.rtt_max = ($rtt[$i] | Measure-Object -Maximum).Maximum }
  if ($i -eq $gw) { $row.note = 'gateway' }
  $row.http = Port $i 80; $row.https = Port $i 443; $row.sdk8000 = Port $i 8000
  $isNvr = $Nvr -contains $i
  if ($isNvr) { $row.note = 'NVR' }
  if ($cred -and ($row.http -or $row.https) -and ($i -ne $gw) -and -not ($Exclude -contains $i) -and ($row.sdk8000 -or $isNvr)) {
    $base = if ($isNvr -or -not $row.http) { 'https://' + $i } else { 'http://' + $i }
    $d = Get-Isapi $base '/ISAPI/System/deviceInfo'   # the ONE login attempt for this device
    if ($d.code -eq 200) {
      $row.auth = 'ok'; $row.model = Tag $d.body 'model'; $row.serial = Tag $d.body 'serialNumber'; $row.firmware = (Tag $d.body 'firmwareVersion') + ' ' + (Tag $d.body 'firmwareReleasedDate')
      $s = Get-Isapi $base '/ISAPI/System/status'; $row.up_sec = Tag $s.body 'deviceUpTime'; $row.uptime = Up $row.up_sec
      $l = Get-Isapi $base '/ISAPI/System/Network/interfaces/1/link'
      if ($l.code -ne 200) { $l = Get-Isapi $base '/ISAPI/System/Network/interfaces' }
      $row.link_speed = Tag $l.body 'speed'; $row.link_duplex = Tag $l.body 'duplex'; $row.link_auto = Tag $l.body 'autoNegotiation'
      $ss = Get-Isapi $base '/ISAPI/Streaming/status'   # who is pulling video from this device right now
      if ($ss.code -eq 200) { $row.streams_to = (([regex]::Matches($ss.body, '<ipAddress>([^<]*)</ipAddress>') | ForEach-Object { $_.Groups[1].Value }) -join ' ') }
      ($d.body + "`r`n" + $s.body + "`r`n" + $l.body) | Set-Content (Join-Path $OutDir ('raw\' + $i + '.xml'))
      if ($LogDays -gt 0) { $row.logs = Read-Logs $base $i }
      if ($isNvr) {
        $c = Get-Isapi $base '/ISAPI/ContentMgmt/InputProxy/channels/status'
        $c.body | Set-Content (Join-Path $OutDir 'raw\nvr-channels.xml')
        $chs = [regex]::Matches($c.body, '(?s)<InputProxyChannelStatus[^>]*>(.*?)</InputProxyChannelStatus>')
        $on = 0; $off = New-Object System.Collections.Generic.List[string]
        foreach ($ch in $chs) { $b = $ch.Groups[1].Value; $cid = Tag $b 'id'; $cip = Tag $b 'ipAddress'; $o = Tag $b 'online'; $det = Tag $b 'chanDetectResult'; if ($o -eq 'true') { $on++ } else { $off.Add('D' + $cid + ' ' + $cip + ' ' + $det) } }
        $row.note = 'NVR: ' + $on + ' of ' + $chs.Count + ' channels online'
        $script:nvrOff = $off
      }
    } elseif ($d.code -eq 401) { $row.auth = 'REFUSED (stopped, no retry)' } else { $row.auth = 'no answer (' + $d.code + ')' }
  } elseif ($Exclude -contains $i) { $row.auth = 'excluded' }
  $rows.Add([pscustomobject]$row)
}
$rows | Export-Csv -NoTypeInformation -Path (Join-Path $OutDir 'hosts.csv')

# ---------- summary ----------
Say ''
Say ('Hosts seen: ' + $rows.Count + ' (ping or ARP)')
foreach ($b in 'FAST(<=5ms)','MID(6-50ms)','SLOW(51-300ms)','VERY-SLOW(>300ms)','NO-REPLY') {
  $g = @($rows | Where-Object { $_.band -eq $b })
  if ($g.Count) { Say ($b + ' x' + $g.Count + ': ' + (($g | ForEach-Object { ($_.ip -split '\.')[3] + $(if ($_.loss_pct -gt 0) { '(' + $_.loss_pct + '%loss)' } else { '' }) }) -join ' ')) }
}
$lk = @($rows | Where-Object { $_.link_speed })
if ($lk.Count) { Say ('Link speed reported by devices: ' + (($lk | Group-Object link_speed | ForEach-Object { $_.Name + 'x' + $_.Count }) -join ', ') + '  (0/auto = not reported)') }
$young = @($rows | Where-Object { $_.up_sec -and [double]$_.up_sec -lt 172800 })
if ($young.Count) { Say ('Rebooted in last 48h: ' + (($young | ForEach-Object { ($_.ip -split '\.')[3] + '(' + $_.uptime + ')' }) -join ' ')) }
$st2 = @($rows | Where-Object { $_.auth -eq 'ok' -and $_.note -notlike 'NVR*' })
if ($st2.Count) { Say ('Video pulled by: ' + (($st2 | ForEach-Object { ($_.ip -split '\.')[3] + '->' + $(if ($_.streams_to) { ($_.streams_to -split ' ' | Select-Object -Unique) -join '/' } else { 'nobody' }) }) -join '  ')) }
foreach ($n in $Nvr) { $nr = $rows | Where-Object { $_.ip -eq $n }; $pulled = @($st2 | Where-Object { $_.streams_to -match [regex]::Escape($n) }).Count
  if ((-not $nr -or $nr.replies -like '0/*') -and $pulled) { Say ('HINT: NVR ' + $n + ' does not answer this PC, yet ' + $pulled + ' cameras are streaming to it -> the NVR is alive; PC and NVR are separated (switch port isolation / VLAN-Extend DIP mode, or a different switch path).') } }
$ten = @($rows | Where-Object { $_.link_speed -eq '10' }); if ($ten.Count -ge 3) { Say ('HINT: ' + $ten.Count + ' devices report a 10 Mbps link. Check PoE switches for an Extend/CCTV/VLAN DIP switch (forces 10 Mbps / isolates ports) or bad cable.') }
$ref = @($rows | Where-Object { $_.auth -like 'REFUSED*' }); if ($ref.Count) { Say ('Login refused (wrong password?): ' + (($ref | ForEach-Object { ($_.ip -split '\.')[3] }) -join ' ')) }
if ($script:nvrOff) { Say ('NVR offline channels: ' + ($script:nvrOff -join '; ')) }
# hints
$pc = $nics | Select-Object -First 1
if ($pc -and $pc.LinkSpeed -notmatch 'Gbps') { Say ('HINT: this PC links at ' + $pc.LinkSpeed + ' - bad cable/port or 100M switch between PC and network.') }
$g0 = $rows | Where-Object { $_.ip -eq $gw }
if ($g0 -and $g0.rtt_med -gt 10) { Say ('HINT: gateway answers in ' + $g0.rtt_med + ' ms (should be 1-2). The PC itself sits behind a congested/slow link.') }
if (-not $g0 -or $g0.replies -like '0/*') { Say 'HINT: gateway not answering - this PC is cut off from the router side.' }
$slowShare = @($rows | Where-Object { $_.band -like '*SLOW*' }).Count
if ($slowShare -ge 5) { Say ('HINT: ' + $slowShare + ' devices answer slowly. Devices in the same band usually hang off the same switch/uplink; the slow band is behind a saturated, 10/100 or looping link.') }
$sum | Set-Content (Join-Path $OutDir 'summary.txt')
Write-Host ('Saved: ' + $OutDir)
