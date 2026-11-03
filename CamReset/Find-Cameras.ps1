<#
 Find-Cameras.ps1 - WireIt CT camera finder for the password-reset tool (Windows PowerShell 5.1, no installs)
 READ-ONLY: sends discovery packets and reads answers. Changes nothing on any device.
   1. Hikvision SADP multicast probe (239.255.255.250:37020) -> serial, model, firmware, MAC, IP, "Start Time" (BootTime),
      activated, password-reset ability. Works even when the camera is on another IP scheme.
   2. ONVIF WS-Discovery (239.255.255.250:3702) -> every ONVIF camera/NVR (Uniview, Hikvision, others) + its scopes.
      Both probes are sent 3 times (0 s, 2.5 s, 5 s) and answers are read for ListenSeconds (default 9).
   3. Network sweep (Nov 3 2026): every address of this PC's own /24 (never wider) gets a ping and a TCP connect on
      ports 80, 554, 8000, 7001, in parallel. Finds cameras that miss the multicast answers (big sites, firewall).
      Hosts that answer on port 80 also get one unicast ONVIF probe (brand/model, no login). MAC + maker guess from ARP.
      The sweep never logs in to anything and needs no firewall rule (it opens no listener).
   4. ONVIF GetSystemDateAndTime (no login) -> the device's own date/time (Uniview's form asks for the DEVICE date).
   5. Uniview only, optional: ONE login try with the factory default admin/123456 (config univiewTryDefault), only for
      cameras that answered the multicast discovery. If it works the device is NOT locked: no reset request needed.
      When no try happened the camera shows "Not tried" (never "Locked").
 Usage:  .\Find-Cameras.ps1            (or double-click "Find Cameras.cmd")
         .\Find-Cameras.ps1 -NoLogin   (skip the Uniview default-password try)
         .\Find-Cameras.ps1 -NoSweep   (multicast discovery only)      -NoMulticast (sweep only, no listener at all)
         .\Find-Cameras.ps1 -SweepTargets 10.1.61.0/24,192.168.1.10-40   (sweep these instead of this PC's own /24)
 Output: .\out\scan-<time>\devices.csv, devices.json, others.csv, summary.txt  (+ out\latest.json: devices + others)
#>
param([switch]$NoLogin, [int]$ListenSeconds = 0, [string]$ConfigPath = '', [switch]$SelfTest,
  [switch]$NoSweep, [switch]$NoMulticast, [string[]]$SweepTargets = @(), [int[]]$SweepPorts = @(80, 554, 8000, 7001),
  [int]$SweepTimeoutMs = 400, [switch]$NoPing, [string]$TestAnswersFile = '', [int]$OnvifUnicastPort = 3702)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $here 'config.json' }
$cfg = $null
if (Test-Path $ConfigPath) { try { $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json } catch { $cfg = $null } }
if ($ListenSeconds -le 0) { $ListenSeconds = 0; if ($cfg) { $ListenSeconds = [int]$cfg.listenSeconds }; if ($ListenSeconds -lt 8) { $ListenSeconds = 9 } }
if ($cfg -and $cfg.PSObject.Properties['sweep'] -and $cfg.sweep -eq $false) { $NoSweep = $true }
if ($SweepTimeoutMs -lt 100) { $SweepTimeoutMs = 100 }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outRoot = Join-Path $here 'out'; $out = Join-Path $outRoot ('scan-' + $stamp)
New-Item -ItemType Directory -Force -Path $out | Out-Null
$sum = New-Object System.Collections.Generic.List[string]
function Say($s) { Write-Host $s; $sum.Add($s) }
function Log($s) { Add-Content -Path (Join-Path $here 'camreset.log') -Value ((Get-Date -Format 's') + ' FIND ' + $s) }

# ---- local IPv4 addresses to probe from (skip loopback, link-local, Tailscale 100.64/10, cellular) ----
$locals = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
  $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.InterfaceAlias -notmatch 'Tailscale|Cellular|Bluetooth|Loopback|vEthernet' -and
  -not ($_.IPAddress -match '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.') })
Say ('=== Camera finder ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') + ' on ' + $env:COMPUTERNAME + ' ===')
foreach ($l in $locals) { Say ('This PC: ' + $l.InterfaceAlias + ' ' + $l.IPAddress + '/' + $l.PrefixLength) }
if (-not $locals -and -not @($SweepTargets).Count) { Say 'No wired/Wi-Fi network address on this PC. Plug into the site network and run again.'; exit 1 }

# ---- firewall: the multicast answers need an inbound rule; without one Windows may pop up a question ----
function Test-DiscoveryFirewall {
  $r = @{ rule = $false; block = $false; known = $true }
  try {
    $r.rule = [bool](@(Get-NetFirewallRule -DisplayName 'WireIt CamReset*' -ErrorAction SilentlyContinue | Where-Object { [string]$_.Enabled -eq 'True' -and [string]$_.Action -eq 'Allow' }).Count)
    $r.block = [bool](@(Get-NetFirewallRule -DisplayName 'Windows PowerShell' -ErrorAction SilentlyContinue | Where-Object { [string]$_.Enabled -eq 'True' -and [string]$_.Direction -eq 'Inbound' -and [string]$_.Action -eq 'Block' }).Count)
  } catch { $r.known = $false }
  return $r
}
if (-not $NoMulticast) {
  $fw = Test-DiscoveryFirewall
  if ($fw.known -and -not $fw.rule) { Say 'If Windows asks about the firewall, press Cancel; to add the firewall rule, run the Toolkit installer once as admin.' }
  if ($fw.block) { Say 'Windows Firewall has a rule that BLOCKS PowerShell here (someone pressed Cancel on that popup), so some camera answers can be lost. The network sweep still works. Fix once: Windows Defender Firewall > Advanced settings > Inbound Rules > delete the red "Windows PowerShell" rules.' }
}

function New-UdpSock([string]$localIp, [int]$port, [string]$group) {
  $u = New-Object System.Net.Sockets.UdpClient
  $u.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket, [Net.Sockets.SocketOptionName]::ReuseAddress, $true)
  try { $u.Client.ReceiveBufferSize = 4194304 } catch {}   # big sites answer in a burst; the default 64 KB buffer drops answers
  $u.Client.Bind((New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($localIp)), $port))
  if ($group) { try { $u.JoinMulticastGroup([Net.IPAddress]::Parse($group), [Net.IPAddress]::Parse($localIp)) } catch {} }
  $u.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::IP, [Net.Sockets.SocketOptionName]::MulticastInterface, ([Net.IPAddress]::Parse($localIp)).GetAddressBytes())
  $u.Client.ReceiveTimeout = 300
  return $u
}
# reads every socket for $seconds; $resend runs again at each time in $resendAt (seconds after start)
function Read-All($socks, [double]$seconds, [scriptblock]$resend = $null, [double[]]$resendAt = @()) {
  $res = New-Object System.Collections.Generic.List[object]
  $start = Get-Date; $end = $start.AddSeconds($seconds); $next = 0
  while ((Get-Date) -lt $end) {
    if ($resend -and $next -lt $resendAt.Count -and ((Get-Date) - $start).TotalSeconds -ge $resendAt[$next]) { & $resend; $next++ }
    foreach ($s in $socks) {
      while ($s.Available -gt 0) {
        $ep = New-Object Net.IPEndPoint ([Net.IPAddress]::Any), 0
        try { $b = $s.Receive([ref]$ep); $res.Add([pscustomobject]@{ From = $ep.Address.ToString(); Text = [Text.Encoding]::UTF8.GetString($b) }) } catch {}
      }
    }
    Start-Sleep -Milliseconds 50
  }
  return $res
}
function XVal($xml, [string]$name) { $m = [regex]::Match($xml, '<(?:\w+:)?' + $name + '>([^<]*)</(?:\w+:)?' + $name + '>'); if ($m.Success) { return $m.Groups[1].Value.Trim() } else { return '' } }

$dev = @{}   # key = IP (or MAC) -> ordered hashtable
function Get-Dev([string]$key) { if (-not $dev.ContainsKey($key)) { $dev[$key] = [ordered]@{ Brand=''; Model=''; Serial=''; IP=''; MAC=''; Firmware=''; StartTime=''; DeviceDate=''; Activated=''; ResetAbility=''; DefaultLoginWorks=''; Status=''; NextStep=''; HttpPort=''; Source=''; Scopes=''; OpenPorts=''; MakerGuess=''; SweepOnly=$false; Kind='' } }; return $dev[$key] }
function Add-Source($d, [string]$src) { if ((' ' + $d.Source + ' ') -notlike ('* ' + $src + ' *')) { $d.Source = ($d.Source + ' ' + $src).Trim() } }

# one discovery answer (SADP or ONVIF ProbeMatch) -> the device list
function Add-Answer($a, [string]$src = '') {
  $x = $a.Text
  if ($x -match '<ProbeMatch>' -and $x -match '<DeviceSN>') {         # SADP answer
    $ip = XVal $x 'IPv4Address'; if (-not $ip) { return }; $d = Get-Dev $ip
    $d.Brand = 'Hikvision'; $d.IP = $ip; $d.Model = XVal $x 'DeviceDescription'; $d.Serial = XVal $x 'DeviceSN'
    $d.MAC = (XVal $x 'MAC').ToUpper(); $d.Firmware = ((XVal $x 'SoftwareVersion') + ' ' + (XVal $x 'DSPVersion')).Trim()
    $d.StartTime = XVal $x 'BootTime'; $d.Activated = XVal $x 'Activated'; $d.HttpPort = XVal $x 'HttpPort'
    $ra = @(); foreach ($f in 'ResetAbility','PasswordResetAbility','PasswordResetModeSecond','SupportSecurityQuestion','SupportHCPlatform','HCPlatformEnable','SupportMailBox','SupportEzvizUnbind','SupportGUID') { $v = XVal $x $f; if ($v) { $ra += ($f + '=' + $v) } }
    $d.ResetAbility = ($ra -join ' ')
    $oem = XVal $x 'OEMInfo'; if ($oem -and $oem -notmatch '(?i)hikvision') { $d.Brand = 'Hikvision (OEM: ' + $oem + ')' }
    Add-Source $d $(if ($src) { $src } else { 'SADP' })
  } elseif ($x -match 'ProbeMatch' -and $x -match 'XAddrs') {         # ONVIF answer
    $xa = (XVal $x 'XAddrs') -split '\s+' | Where-Object { $_ -match '^http' } | Select-Object -First 1
    $ip = $a.From; if ($xa -match '//([0-9.]+)') { $ip = $Matches[1] }
    $d = Get-Dev $ip; $d.IP = $ip; $d.Scopes = (XVal $x 'Scopes'); $d['Xaddr'] = $xa
    $sc = [uri]::UnescapeDataString($d.Scopes)
    if (-not $d.Brand -or $d.Brand -eq 'Unknown') {
      if ($sc -match '(?i)uniview|unv|uniarch') { $d.Brand = 'Uniview' }
      elseif ($sc -match '(?i)hikvision|hik') { $d.Brand = 'Hikvision' }
      else { $d.Brand = 'Other (ONVIF)' }
    }
    if (-not $d.Model) { if ($sc -match 'onvif://www\.onvif\.org/hardware/(\S+)') { $d.Model = $Matches[1] } }
    Add-Source $d $(if ($src) { $src } else { 'ONVIF' })
  }
}

$probe = '<?xml version="1.0" encoding="utf-8"?><Probe><Uuid>' + ([guid]::NewGuid().ToString().ToUpper()) + '</Uuid><Types>inquiry</Types></Probe>'
$pb = [Text.Encoding]::UTF8.GetBytes($probe)
$wsd = '<?xml version="1.0" encoding="UTF-8"?><e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl"><e:Header><w:MessageID>uuid:' + [guid]::NewGuid() + '</w:MessageID><w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To><w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>'
$wb = [Text.Encoding]::UTF8.GetBytes($wsd)
$answers = @()
$t0 = Get-Date
if (-not $NoMulticast -and $locals) {
  # ---------- 1. Hikvision SADP + 2. ONVIF WS-Discovery (3 rounds) ----------
  $sadpSocks = @(); foreach ($l in $locals) { try { $sadpSocks += New-UdpSock $l.IPAddress 37020 '239.255.255.250' } catch { Say ('SADP: could not open port 37020 on ' + $l.IPAddress + ' (is HiTools/SADP open? close it and re-run): ' + $_.Exception.Message) } }
  $wsSocks = @(); foreach ($l in $locals) { try { $wsSocks += New-UdpSock $l.IPAddress 0 '' } catch {} }
  $sendProbes = {
    foreach ($s in $sadpSocks) { try { [void]$s.Send($pb, $pb.Length, (New-Object Net.IPEndPoint ([Net.IPAddress]::Parse('239.255.255.250')), 37020)) } catch {} }
    foreach ($s in $wsSocks) { try { [void]$s.Send($wb, $wb.Length, (New-Object Net.IPEndPoint ([Net.IPAddress]::Parse('239.255.255.250')), 3702)) } catch {} }
  }
  Say ('Listening ' + $ListenSeconds + ' s for camera answers (3 rounds)...')
  $answers = @(Read-All (@($sadpSocks) + @($wsSocks)) $ListenSeconds $sendProbes @(0, 0.3, 2.5, 5))
  foreach ($s in (@($sadpSocks) + @($wsSocks))) { try { $s.Close() } catch {} }
}
if ($SelfTest) {   # fake answers (TEST-NET addresses, nothing is contacted) to prove parsing/output without a camera
  $answers = @($answers) + @(
    [pscustomobject]@{ From = '192.0.2.64'; Text = '<?xml version="1.0" encoding="UTF-8"?><ProbeMatch><Uuid>X</Uuid><Types>inquiry</Types><DeviceType>139</DeviceType><DeviceDescription>DS-2CD2143G2-I</DeviceDescription><DeviceSN>DS-2CD2143G2-I20230101AAWRTEST00001</DeviceSN><CommandPort>8000</CommandPort><HttpPort>80</HttpPort><MAC>c4-2f-90-00-00-01</MAC><IPv4Address>192.0.2.64</IPv4Address><IPv4SubnetMask>255.255.255.0</IPv4SubnetMask><IPv4Gateway>192.0.2.1</IPv4Gateway><DHCP>false</DHCP><SoftwareVersion>V5.7.3build 220112</SoftwareVersion><DSPVersion>V7.3 build 220112</DSPVersion><BootTime>2026-11-02 09:12:22</BootTime><Activated>true</Activated><PasswordResetAbility>true</PasswordResetAbility><ResetAbility>false</ResetAbility><SupportSecurityQuestion>true</SupportSecurityQuestion><OEMInfo>hikvision</OEMInfo></ProbeMatch>' },
    [pscustomobject]@{ From = '192.0.2.70'; Text = '<?xml version="1.0"?><SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"><SOAP-ENV:Body><d:ProbeMatches><d:ProbeMatch><d:Scopes>onvif://www.onvif.org/type/video_encoder onvif://www.onvif.org/name/Uniview onvif://www.onvif.org/hardware/IPC2124LB-SF28KM-G</d:Scopes><d:XAddrs>http://192.0.2.70/onvif/device_service</d:XAddrs></d:ProbeMatch></d:ProbeMatches></SOAP-ENV:Body></SOAP-ENV:Envelope>' })
  Say 'SELF-TEST: 2 fake answers added (192.0.2.x test addresses).'
}
if ($TestAnswersFile -and (Test-Path $TestAnswersFile)) {   # tests only: discovery answers from a file (JSON list of { From, Text })
  $ta = Get-Content $TestAnswersFile -Raw | ConvertFrom-Json; $answers = @($answers) + @($ta)
}
$rawFile = Join-Path $out 'raw-answers.txt'
foreach ($a in $answers) { Add-Content -Path $rawFile -Value ('--- from ' + $a.From + "`r`n" + $a.Text) }
foreach ($a in $answers) { Add-Answer $a }
$mcFound = $dev.Count
if (-not $NoMulticast) { Say ('Discovery answers: ' + $mcFound + ' device(s) in ' + [int]((Get-Date) - $t0).TotalSeconds + ' s.') }

# ---------- 3. network sweep (ping + TCP connect, read-only, no login) ----------
function ConvertTo-IpNum([string]$ip) { $b = ([Net.IPAddress]::Parse($ip)).GetAddressBytes(); return [int64]$b[0] * 16777216 + [int64]$b[1] * 65536 + [int64]$b[2] * 256 + [int64]$b[3] }
function ConvertFrom-IpNum([int64]$n) { return ('{0}.{1}.{2}.{3}' -f [int](($n -shr 24) -band 255), [int](($n -shr 16) -band 255), [int](($n -shr 8) -band 255), [int]($n -band 255)) }
# a /24 (or smaller) around an address; anything wider than /24 is cut down to the /24 the address sits in
function Get-SweepNet([string]$ip, [int]$prefix) {
  if ($prefix -lt 24) { $prefix = 24 }
  if ($prefix -gt 30) { return $null }
  $n = ConvertTo-IpNum $ip; $size = [int64][Math]::Pow(2, 32 - $prefix); $netNum = [int64]([Math]::Floor($n / $size) * $size)
  $ips = @(for ($k = $netNum + 1; $k -lt $netNum + $size - 1; $k++) { ConvertFrom-IpNum $k })
  return [pscustomobject]@{ Label = ((ConvertFrom-IpNum $netNum) + '/' + $prefix); IPs = $ips }
}
function Get-SweepGroups {
  $g = New-Object System.Collections.Generic.List[object]; $seen = @{}
  if (@($SweepTargets).Count) {
    foreach ($t in @($SweepTargets | ForEach-Object { ([string]$_) -split ',' } | Where-Object { $_.Trim() })) {
      $t = $t.Trim()
      if ($t -match '^(\d+\.\d+\.\d+\.\d+)/(\d+)$') { $x = Get-SweepNet $Matches[1] ([int]$Matches[2]) }
      elseif ($t -match '^(\d+\.\d+\.\d+)\.(\d+)-(\d+)$') { $p = $Matches[1]; $a = [int]$Matches[2]; $b = [Math]::Min(254, [int]$Matches[3]); $x = [pscustomobject]@{ Label = $t; IPs = @(for ($k = $a; $k -le $b; $k++) { $p + '.' + $k }) } }
      elseif ($t -match '^\d+\.\d+\.\d+\.\d+$') { $x = [pscustomobject]@{ Label = $t; IPs = @($t) } }
      else { Say ('Sweep: skipped "' + $t + '" (use 10.1.61.0/24, 10.1.61.10-40 or one address)'); continue }
      if ($x -and -not $seen.ContainsKey($x.Label)) { $seen[$x.Label] = 1; $g.Add($x) }
    }
  } else {
    foreach ($l in $locals) {
      $x = Get-SweepNet $l.IPAddress ([int]$l.PrefixLength); if (-not $x) { continue }
      if ($seen.ContainsKey($x.Label)) { continue }; $seen[$x.Label] = 1
      $x.IPs = @($x.IPs | Where-Object { $_ -ne $l.IPAddress })   # not this PC itself
      $g.Add($x); if ($g.Count -ge 4) { break }
    }
  }
  return $g.ToArray()
}
# ping + TCP connect to every address of one group, in parallel batches; returns ip -> @{ Open; Refused; Ping }
function Invoke-SubnetSweep($group, [int[]]$ports, [int]$timeoutMs, [bool]$doPing) {
  $ips = @($group.IPs); $n = $ips.Count; $res = @{}
  foreach ($ip in $ips) { $res[$ip] = @{ Open = New-Object System.Collections.Generic.List[int]; Refused = $false; Ping = $false } }
  if ($n -eq 0) { return $res }
  if ($doPing) {
    $pings = @(foreach ($ip in $ips) { $p = New-Object Net.NetworkInformation.Ping; $t = $null; try { $t = $p.SendPingAsync($ip, ($timeoutMs + 300)) } catch {}; [pscustomobject]@{ ip = $ip; p = $p; t = $t } })
    $pt = [Threading.Tasks.Task[]]@($pings | Where-Object { $_.t } | ForEach-Object { $_.t })
    if ($pt.Count) { try { [void][Threading.Tasks.Task]::WaitAll($pt, ($timeoutMs + 1500)) } catch {} }
    foreach ($x in $pings) { if ($x.t) { if ($x.t.Status -eq 'RanToCompletion' -and [string]$x.t.Result.Status -eq 'Success') { $res[$x.ip].Ping = $true }; $null = $x.t.Exception }; try { $x.p.Dispose() } catch {} }
  }
  $batch = [Math]::Max(1, [int][Math]::Floor(256 / [Math]::Max(1, $ports.Count)))
  for ($i = 0; $i -lt $n; $i += $batch) {
    $last = [Math]::Min($n, $i + $batch) - 1; $chunk = @($ips[$i..$last])
    $conns = @(foreach ($ip in $chunk) { $addr = [Net.IPAddress]::Parse($ip); foreach ($port in $ports) { $c = New-Object Net.Sockets.TcpClient; $t = $null; try { $t = $c.ConnectAsync($addr, $port) } catch {}; [pscustomobject]@{ ip = $ip; port = $port; c = $c; t = $t } } })
    $tasks = [Threading.Tasks.Task[]]@($conns | Where-Object { $_.t } | ForEach-Object { $_.t })
    if ($tasks.Count) { try { [void][Threading.Tasks.Task]::WaitAll($tasks, $timeoutMs) } catch {} }
    foreach ($x in $conns) {
      if ($x.t) {
        if ($x.t.Status -eq 'RanToCompletion' -and $x.c.Connected) { $res[$x.ip].Open.Add($x.port) }
        elseif ($x.t.IsFaulted) { $e = $x.t.Exception.InnerException; if ($e -is [Net.Sockets.SocketException] -and [string]$e.SocketErrorCode -eq 'ConnectionRefused') { $res[$x.ip].Refused = $true } }
      }
      try { $x.c.Close() } catch {}
    }
    Say ('Sweeping ' + $group.Label + ' ... ' + ($last + 1) + '/' + $n)
  }
  return $res
}
# maker from the first half of the MAC (IEEE OUI). A GUESS: brands rebadge and buy chips from each other.
$ouiTable = @{
  '44-19-B6'='Hikvision'; 'C0-56-E3'='Hikvision'; '4C-BD-8F'='Hikvision'; 'BC-AD-28'='Hikvision'; 'C4-2F-90'='Hikvision'; '28-57-BE'='Hikvision'; '54-C4-15'='Hikvision'; '18-68-CB'='Hikvision'; '8C-E7-48'='Hikvision'; 'A4-14-37'='Hikvision'; 'BC-BA-C2'='Hikvision'
  '3C-EF-8C'='Dahua'; '90-02-A9'='Dahua'; '4C-11-BF'='Dahua'; 'E0-50-8B'='Dahua'; '9C-14-63'='Dahua'; '14-A7-8B'='Dahua'; 'A0-BD-1D'='Dahua'; '38-AF-29'='Dahua'
  '48-EA-63'='Uniview'; 'C4-79-05'='Uniview'
  '00-40-8C'='Axis'; 'AC-CC-8E'='Axis'; 'B8-A4-4F'='Axis'; 'E8-27-25'='Axis'
  '00-09-18'='Hanwha'; '00-02-D1'='Vivotek'
  '24-5A-4C'='Ubiquiti'; '74-83-C2'='Ubiquiti'; '78-8A-20'='Ubiquiti'; '80-2A-A8'='Ubiquiti'; 'F0-9F-C2'='Ubiquiti'; 'FC-EC-DA'='Ubiquiti'; '68-D7-9A'='Ubiquiti'; '18-E8-29'='Ubiquiti'; 'E0-63-DA'='Ubiquiti'; '04-18-D6'='Ubiquiti'; 'B4-FB-E4'='Ubiquiti'; 'DC-9F-DB'='Ubiquiti'; '44-D9-E7'='Ubiquiti'; '70-A7-41'='Ubiquiti'; 'D8-B3-70'='Ubiquiti'
  '00-0B-82'='Grandstream'; 'C0-74-AD'='Grandstream'; 'EC-74-D7'='Grandstream'; '0C-11-05'='Akuvox'
}
if ($cfg -and $cfg.PSObject.Properties['ouiExtra'] -and $cfg.ouiExtra) { foreach ($p in $cfg.ouiExtra.PSObject.Properties) { $ouiTable[([string]$p.Name).ToUpper().Replace(':', '-')] = [string]$p.Value } }
$cameraMakers = @('Hikvision', 'Dahua', 'Uniview', 'Axis', 'Hanwha', 'Vivotek')
function Get-OuiMaker([string]$mac) { if (-not $mac) { return '' }; $k = $mac.ToUpper().Replace(':', '-'); if ($k.Length -lt 8) { return '' }; $k = $k.Substring(0, 8); if ($ouiTable.ContainsKey($k)) { return $ouiTable[$k] }; return '' }
function Get-ArpTable {
  $t = @{}
  Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.LinkLayerAddress -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' -and $_.LinkLayerAddress -notmatch '^(FF-FF|01-00-5E)' -and [string]$_.State -notin @('Unreachable', 'Incomplete') } | ForEach-Object { $t[$_.IPAddress] = $_.LinkLayerAddress.ToUpper() }
  return $t
}
# one unicast ONVIF probe per host (no login): brand + model for cameras the multicast round missed
function Invoke-OnvifUnicast([string[]]$ips, [double]$seconds) {
  if (-not @($ips).Count) { return @() }
  $u = $null; try { $u = New-Object Net.Sockets.UdpClient 0; try { $u.Client.ReceiveBufferSize = 4194304 } catch {} } catch { return @() }
  $send = { foreach ($ip in $ips) { try { [void]$u.Send($wb, $wb.Length, (New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($ip)), $OnvifUnicastPort)) } catch {} } }
  $r = @(Read-All @($u) $seconds $send @(0, ($seconds / 2)))
  try { $u.Close() } catch {}
  return $r
}

$others = New-Object System.Collections.Generic.List[object]
$sweepNets = @(); $sweepOnlyCount = 0
if (-not $NoSweep) {
  $groups = @(Get-SweepGroups)
  if (-not $groups.Count) { Say 'Sweep: no /24 to sweep on this PC.' }
  $alive = @{}; $ts = Get-Date
  foreach ($gp in $groups) {
    $sweepNets += $gp.Label
    Say ('Sweeping ' + $gp.Label + ' (' + @($gp.IPs).Count + ' addresses, ports ' + ($SweepPorts -join '/') + ')...')
    $r = Invoke-SubnetSweep $gp $SweepPorts $SweepTimeoutMs (-not $NoPing)
    foreach ($k in $r.Keys) { $alive[$k] = $r[$k] }
  }
  $arpNow = Get-ArpTable
  $hits = @{}
  foreach ($ip in $alive.Keys) {
    $h = $alive[$ip]; $mac = ''; if ($arpNow.ContainsKey($ip)) { $mac = $arpNow[$ip] }
    if (-not ($h.Open.Count -or $h.Ping -or $mac)) { continue }   # nobody there (a refused connect alone is not counted)
    $hits[$ip] = [pscustomobject]@{ IP = $ip; Open = @($h.Open | Sort-Object -Unique); Ping = $h.Ping; MAC = $mac; Maker = (Get-OuiMaker $mac) }
  }
  # hosts discovery already knew: just add what answered
  foreach ($ip in @($hits.Keys)) {
    if ($dev.ContainsKey($ip)) { $d = $dev[$ip]; $d.OpenPorts = ($hits[$ip].Open -join '/'); if (-not $d.MAC -and $hits[$ip].MAC) { $d.MAC = $hits[$ip].MAC }; $d.MakerGuess = $hits[$ip].Maker; Add-Source $d 'SWEEP'; $hits.Remove($ip) }
  }
  # new hosts that answer on 80: one unicast ONVIF probe each
  $probeIps = @($hits.Values | Where-Object { $_.Open -contains 80 } | ForEach-Object { $_.IP })
  if ($probeIps.Count) {
    Say ('Asking ' + $probeIps.Count + ' new host(s) on port 80 who they are (ONVIF, no login)...')
    foreach ($a in @(Invoke-OnvifUnicast $probeIps 1.5)) { if ($hits.ContainsKey([string]$a.From) -or $hits.ContainsKey(([regex]::Match($a.Text, 'XAddrs>[^<]*?//([0-9.]+)')).Groups[1].Value)) { Add-Content -Path $rawFile -Value ('--- unicast from ' + $a.From + "`r`n" + $a.Text); Add-Answer $a 'SWEEP+ONVIF' } }
  }
  foreach ($h in @($hits.Values | Sort-Object { ConvertTo-IpNum $_.IP })) {
    $ports = ($h.Open -join '/')
    $what = $(if ($ports) { 'answers on ' + $ports } elseif ($h.Ping) { 'answers ping only' } else { 'seen on the network (ARP) only' })
    $makerTxt = $(if ($h.Maker) { 'maker guess ' + $h.Maker + ' (from MAC)' } else { 'maker unknown' })
    if ($dev.ContainsKey($h.IP)) {   # identified by the unicast ONVIF probe
      $d = $dev[$h.IP]; $d.SweepOnly = $true; $d.OpenPorts = $ports; $d.MakerGuess = $h.Maker; $d.Kind = 'camera'
      if (-not $d.MAC) { $d.MAC = $h.MAC }
      if ($d.Brand -like 'Other*' -and $h.Maker) { $d.Brand = $h.Maker }
      $d.Status = 'Found by the network sweep (' + $what + '; missed the multicast discovery)'
      $sweepOnlyCount++; continue
    }
    $isCam = ($h.Open -contains 554) -or ($h.Open -contains 8000) -or ($cameraMakers -contains $h.Maker)
    if ($isCam -and -not ($h.Open -contains 7001)) {
      $d = Get-Dev $h.IP; $d.IP = $h.IP; $d.MAC = $h.MAC; $d.OpenPorts = $ports; $d.MakerGuess = $h.Maker; $d.SweepOnly = $true; $d.Kind = 'camera'
      $d.Brand = $(if ($h.Maker) { $h.Maker } else { 'Unknown' }); Add-Source $d 'SWEEP'
      $d.Status = 'Found by the network sweep: ' + $what + ', ' + $makerTxt
      $sweepOnlyCount++
    } else {
      $note = $(if ($h.Open -contains 7001) { 'DW / Nx video server? (port 7001)' } elseif ($h.Open -contains 80) { 'web page on port 80 (switch, printer, NVR or PC?)' } else { '' })
      $others.Add([pscustomobject]@{ IP = $h.IP; MAC = $h.MAC; MakerGuess = $h.Maker; OpenPorts = $ports; Ping = $h.Ping; What = ($what + ', ' + $makerTxt); Note = $note })
    }
  }
  Say ('Sweep done in ' + [int]((Get-Date) - $ts).TotalSeconds + ' s: ' + ($sweepOnlyCount + $others.Count + @($dev.Values | Where-Object { $_.Source -like '*SWEEP*' -and -not $_.SweepOnly }).Count) + ' host(s) answered, ' + $sweepOnlyCount + ' camera(s) the discovery missed.')
}

# ---------- 4/5. per-device reads ----------
function Invoke-Soap([string]$url, [string]$body, [int]$timeoutSec = 3) {
  $env = '<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body>' + $body + '</s:Body></s:Envelope>'
  # plain HttpWebRequest with no proxy: Invoke-WebRequest can stall on proxy auto-detect (WPAD) far past its -TimeoutSec
  try {
    $req = [Net.HttpWebRequest]::Create($url); $req.Method = 'POST'; $req.Proxy = $null; $req.KeepAlive = $false
    $req.Timeout = $timeoutSec * 1000; $req.ReadWriteTimeout = $timeoutSec * 1000; $req.ContentType = 'application/soap+xml; charset=utf-8'
    $bytes = [Text.Encoding]::UTF8.GetBytes($env); $req.ContentLength = $bytes.Length
    $rs = $req.GetRequestStream(); $rs.Write($bytes, 0, $bytes.Length); $rs.Close()
    $resp = $req.GetResponse(); $sr = New-Object IO.StreamReader ($resp.GetResponseStream()); $txt = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
    return $txt
  } catch { return '' }
}
# ONVIF DateTime: the schema puts <Time> before <Date>, so read each field on its own (local time first, else UTC)
function Get-OnvifDate([string]$t) {
  foreach ($blk in 'LocalDateTime', 'UTCDateTime') {
    $m = [regex]::Match($t, '<(?:\w+:)?' + $blk + '>(.*?)</(?:\w+:)?' + $blk + '>', 'Singleline')
    if (-not $m.Success) { continue }
    $v = @{}
    foreach ($fl in 'Year', 'Month', 'Day', 'Hour', 'Minute') { $x = [regex]::Match($m.Groups[1].Value, '<(?:\w+:)?' + $fl + '>\s*(\d+)\s*<'); if (-not $x.Success) { $v = $null; break }; $v[$fl] = [int]$x.Groups[1].Value }
    if ($v) { return ('{0}-{1:D2}-{2:D2} {3:D2}:{4:D2}' -f $v.Year, $v.Month, $v.Day, $v.Hour, $v.Minute) + $(if ($blk -eq 'LocalDateTime') { ' (device local)' } else { ' (device UTC)' }) }
  }
  return ''
}
$arp = Get-ArpTable
$sweptIps = @{}; foreach ($k in @($dev.Keys)) { if ($dev[$k].OpenPorts) { $sweptIps[$dev[$k].IP] = 1 } }
foreach ($k in @($dev.Keys)) {
  $d = $dev[$k]
  if (-not $d.MAC -and $arp.ContainsKey($d.IP)) { $d.MAC = $arp[$d.IP] }
  if ($d.MAC -match '^(48-EA-63|48:EA:63|C4-79-05|C4:79:05)' -and $d.Brand -like 'Other*') { $d.Brand = 'Uniview' }
  $sameNet = $false; foreach ($l in $locals) { $a = ([Net.IPAddress]::Parse($l.IPAddress)).GetAddressBytes(); try { $b = ([Net.IPAddress]::Parse($d.IP)).GetAddressBytes() } catch { continue }; $bits = $l.PrefixLength; $match = $true; for ($i = 0; $i -lt 4; $i++) { $m = [Math]::Max(0, [Math]::Min(8, $bits - 8 * $i)); $mask = (0xFF -shl (8 - $m)) -band 0xFF; if (($a[$i] -band $mask) -ne ($b[$i] -band $mask)) { $match = $false } }; if ($match) { $sameNet = $true } }
  if ($sweptIps.ContainsKey($d.IP)) { $sameNet = $true }   # a TCP port answered: this PC reaches it directly
  $d['SameSubnet'] = $sameNet
  if (-not $sameNet -and -not $d.Status) { $d.Status = 'On a different IP scheme than this PC' }
  # device date/time without login (ONVIF); sweep-only hosts only when they have a web port
  if ($sameNet -and (-not $d.SweepOnly -or $d['Xaddr'] -or ((' ' + ($d.OpenPorts -replace '/', ' ') + ' ') -like '* 80 *'))) {
    $xaddr = $d['Xaddr']; if (-not $xaddr) { $xaddr = 'http://' + $d.IP + $(if ($d.HttpPort -and $d.HttpPort -ne '80') { ':' + $d.HttpPort } else { '' }) + '/onvif/device_service' }
    $t = Invoke-Soap $xaddr '<GetSystemDateAndTime xmlns="http://www.onvif.org/ver10/device/wsdl"/>' $(if ($d.SweepOnly) { 2 } else { 3 })
    if ($t) { $dd = Get-OnvifDate $t; if ($dd) { $d.DeviceDate = $dd } }
    # Uniview: one try with the factory default (never more than one per device per day; never on sweep-only hosts)
    if ($d.Brand -eq 'Uniview' -and -not $NoLogin -and $cfg -and $cfg.univiewTryDefault -and -not $d.SweepOnly) {
      $tried = Join-Path $here 'state\default-tried.txt'; New-Item -ItemType Directory -Force -Path (Join-Path $here 'state') | Out-Null
      $todayKey = $d.IP + ' ' + (Get-Date -Format 'yyyy-MM-dd')
      $prev = @(); if (Test-Path $tried) { $prev = @(Get-Content $tried | Where-Object { $_ -eq $todayKey -or $_.StartsWith($todayKey + ' ') }) }
      if (-not $prev.Count) {
        Add-Content -Path $tried -Value $todayKey
        try {
          $cred = New-Object Net.NetworkCredential('admin', '123456')
          $wc = New-Object Net.WebClient; $wc.Proxy = $null; $wc.Credentials = $cred
          $info = $wc.DownloadString('http://' + $d.IP + '/LAPI/V1.0/System/DeviceInfo')
          $d.DefaultLoginWorks = 'YES'
          foreach ($p in 'SerialNumber','DeviceModel','FirmwareVersion','Manufacturer') { $m = [regex]::Match($info, '"' + $p + '"\s*:\s*"([^"]*)"'); if ($m.Success) { switch ($p) { 'SerialNumber' { $d.Serial = $m.Groups[1].Value } 'DeviceModel' { $d.Model = $m.Groups[1].Value } 'FirmwareVersion' { $d.Firmware = $m.Groups[1].Value } } } }
        } catch {
          $code = ''; if ($_.Exception.InnerException -and $_.Exception.InnerException.Response) { $code = [int]$_.Exception.InnerException.Response.StatusCode }
          if (-not $code -and $_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch {} }
          $d.DefaultLoginWorks = $(if ($code -eq 401) { 'no (401)' } else { 'no answer (' + $_.Exception.Message.Split("`n")[0] + ')' })
        }
        Add-Content -Path $tried -Value ($todayKey + ' ' + $d.DefaultLoginWorks)
      } else {
        $lastRes = @($prev | Where-Object { $_.Length -gt $todayKey.Length } | ForEach-Object { $_.Substring($todayKey.Length + 1) }) | Select-Object -Last 1
        $d.DefaultLoginWorks = $(if ($lastRes -eq 'YES') { 'YES' } elseif ($lastRes) { 'already tried today: ' + $lastRes } else { 'already tried today (result not saved)' })
      }
    }
  }
  # verdict + next step
  $dl = [string]$d.DefaultLoginWorks
  if ($d.Brand -like 'Hikvision*') {
    if ($d.Activated -eq 'false') { $d.Status = 'NOT ACTIVATED (factory fresh)'; $d.NextStep = 'No reset needed: activate it in HiTools with a new password' }
    else { if (-not $d.Status) { $d.Status = 'Activated (password unknown?)' }; $d.NextStep = 'HiTools > select > Reset Password > Import/Export Key > Export XML File (see README step H)' }
  } elseif ($d.Brand -eq 'Uniview') {
    if ($dl -eq 'YES') { $d.Status = 'Default password works (admin/123456)'; $d.NextStep = 'No reset needed: log in and set a new password' }
    elseif ($dl -like '*no (401)*') { if (-not $d.Status) { $d.Status = 'Locked (default does not work)' }; $d.NextStep = 'Uniview request: needs 20-digit SN (label or EZTools list) + device date (see README step U)' }
    elseif ($dl -like '*no answer*') { if (-not $d.Status) { $d.Status = 'Login try got no answer (not known if locked)' }; $d.NextStep = 'Open its web page; if the default admin/123456 fails, use the Uniview request (README step U)' }
    elseif ($dl -like 'already tried today*') { if (-not $d.Status) { $d.Status = 'Tried earlier today (result not saved)' }; $d.NextStep = 'Open its web page and try admin/123456 by hand, or run again tomorrow' }
    else {
      $d.DefaultLoginWorks = 'not tried'
      if (-not $d.Status) { $d.Status = 'Not tried (no login was attempted)' } else { $d.Status = $d.Status + '; login not tried' }
      $d.NextStep = 'Password not checked. To check: open its web page, or turn on "univiewTryDefault" in config.json (one try of admin/123456)'
    }
  } elseif ($d.SweepOnly -and $d.Brand -eq 'Unknown') { $d.NextStep = 'Open http://' + $d.IP + ' to see what it is (no login was tried)' }
  else { $d.NextStep = 'Not Hikvision/Uniview: check model' }
}

# ---------- output ----------
$rows = foreach ($k in ($dev.Keys | Sort-Object { try { ConvertTo-IpNum $_ } catch { 0 } })) { [pscustomobject]$dev[$k] }
$rows = @($rows | Where-Object { $_ })
$rows | Select-Object Brand, Model, Serial, IP, MAC, Firmware, StartTime, DeviceDate, Activated, DefaultLoginWorks, Status, NextStep, ResetAbility, SameSubnet, Source, OpenPorts, MakerGuess, SweepOnly | Export-Csv -Path (Join-Path $out 'devices.csv') -NoTypeInformation -Encoding UTF8
$json = $rows | ConvertTo-Json -Depth 4
if ($rows.Count -eq 1) { $json = '[' + $json + ']' }
if ($rows.Count -eq 0) { $json = '[]' }
Set-Content -Path (Join-Path $out 'devices.json') -Value $json -Encoding UTF8
$otherRows = @($others.ToArray())
if ($otherRows.Count) { $otherRows | Select-Object IP, MAC, MakerGuess, OpenPorts, Ping, What, Note | Export-Csv -Path (Join-Path $out 'others.csv') -NoTypeInformation -Encoding UTF8 }
$latest = [ordered]@{ scannedAt = (Get-Date -Format 's'); pc = $env:COMPUTERNAME; folder = $out; devices = $rows; others = $otherRows; sweep = [ordered]@{ nets = @($sweepNets); ports = @($SweepPorts); foundOnlyBySweep = $sweepOnlyCount; multicast = (-not $NoMulticast) } }
Set-Content -Path (Join-Path $outRoot 'latest.json') -Value ($latest | ConvertTo-Json -Depth 5) -Encoding UTF8
Say ''
Say ('Found ' + $rows.Count + ' device(s): ' + @($rows | Where-Object { $_.Brand -like 'Hikvision*' }).Count + ' Hikvision, ' + @($rows | Where-Object { $_.Brand -eq 'Uniview' }).Count + ' Uniview, ' + @($rows | Where-Object { $_.Brand -notlike 'Hikvision*' -and $_.Brand -ne 'Uniview' }).Count + ' other')
if ($sweepOnlyCount) { Say ('  ' + $sweepOnlyCount + ' of them were found only by the network sweep (the discovery answers missed them).') }
foreach ($r in $rows) {
  Say ('- ' + $r.Brand + ' ' + $r.Model + ' | SN ' + $r.Serial + ' | ' + $r.IP + $(if ($r.MAC) { ' | MAC ' + $r.MAC } else { '' }) + $(if ($r.OpenPorts) { ' | ports ' + $r.OpenPorts } else { '' }) + ' | start ' + $r.StartTime + ' | date ' + $r.DeviceDate)
  Say ('    ' + $r.Status + ' -> ' + $r.NextStep)
  if (-not $r.SameSubnet) { Say ('    Note: camera is on another IP scheme. HiTools still sees it; for its web page give this PC a second address in that range or change the camera IP in HiTools.') }
}
if ($otherRows.Count) {
  Say ''
  Say ('Other things on the network (' + $otherRows.Count + ', probably not cameras):')
  foreach ($o in $otherRows) { Say ('- ' + $o.IP + $(if ($o.MAC) { ' | MAC ' + $o.MAC } else { '' }) + ' | ' + $o.What + $(if ($o.Note) { ' | ' + $o.Note } else { '' })) }
}
# ---------- open reset requests: did the camera reboot since its XML was exported? ----------
$reqRoot = Join-Path $here 'requests'
if (Test-Path $reqRoot) {
  foreach ($rf in (Get-ChildItem $reqRoot -Filter request.json -Recurse -ErrorAction SilentlyContinue)) {
    $rq = Get-Content $rf.FullName -Raw | ConvertFrom-Json
    if ($rq.status -notin @('exported', 'submitted', 'key-received')) { continue }
    $now = $rows | Where-Object { $_.Serial -eq $rq.serial } | Select-Object -First 1
    if (-not $now) { Say ('OPEN REQUEST ' + $rq.shortSerial + ': camera not seen in this scan (unplugged? if it lost power the request is dead).') }
    elseif ($rq.startTime -and $now.StartTime -and $now.StartTime -ne $rq.startTime) { Say ('OPEN REQUEST ' + $rq.shortSerial + ': CAMERA REBOOTED since export (' + $rq.startTime + ' -> ' + $now.StartTime + '). That request is no longer valid: export a new XML.') }
    else { Say ('OPEN REQUEST ' + $rq.shortSerial + ': camera still up since export (good). Valid until ' + $rq.validUntil + '.') }
  }
}
Say ('Saved: ' + $out)
$sum | Set-Content -Path (Join-Path $out 'summary.txt') -Encoding UTF8
Log ('found=' + $rows.Count + ' sweepOnly=' + $sweepOnlyCount + ' others=' + $otherRows.Count + ' out=' + $out)
