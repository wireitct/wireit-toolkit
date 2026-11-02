<#
 FixNVR.ps1 - WireIt CT "Fix NVR" tool (Windows PowerShell 5.1, no installs)
 Gets an NVR (and the cameras that sit on switches) back online after the internet service changed:
   - wrong IP scheme (new router), DNS removed, platform access (Hik-Connect / EZCloud) unticked.
 Modes:
   Check    (default) read-only: find NVR + cameras on ANY IP scheme, show what is wrong and the exact plan.
   Fix      same as Check, then ONE "YES" applies the plan, verifies, and writes a rollback file.
   Snapshot install-time "known-good" record (MAC/IP/serial/channel map, no passwords) + install-standard check.
   Rollback put devices back exactly as a Fix run found them (-RollbackFile).
   Cleanup  remove any temporary PC address a crashed run left behind (also runs at every start).
   Pictures read-only: one picture of every camera on the NVR(s) for the site page (Toolkit CamViews.ps1).
            Snapshot and a finished Fix also take the pictures at the end (needs -Site; skipped with a note otherwise).
 Devices are only READ until you type YES. The PC gets a temporary extra address on the old scheme while the
 tool runs (memory-only, removed at the end, even on error; a reboot also clears it).
 Official interfaces only: Hikvision ISAPI, Hikvision SADP discovery (read), ONVIF (standard), Uniview LAPI.
 Address standard (v1.1): router DHCP .100-.254, NVR .20 (.19/.18 if taken), switch cameras .21-.99 (Dn -> .20+n),
 other WireIt gear .10-.19, DNS 8.8.8.8 / 1.1.1.1. Each address is checked free before use.
#>
param(
  [ValidateSet('Check','Fix','Snapshot','Rollback','Cleanup','Pictures')][string]$Mode = 'Check',
  [string]$Site = '',               # site name: finds/saves the snapshot in the site's Drive folder
  [string]$User = 'admin',          # device login user
  [string]$BitwardenExport = '',    # optional: unencrypted Bitwarden .json export (delete it after!)
  [string]$BitwardenItem = '',      # name of the item in that export
  [string]$CredFile = '',           # tests only: line1 user, line2 password
  [string]$Snapshot = '',           # path to a known-good snapshot json (else latest for -Site)
  [string[]]$OldSubnet = @(),       # force old scheme(s), e.g. 192.168.1  (first 3 octets)
  [string]$Nvr = '',                # NVR's current IP if you already know it
  [string]$RollbackFile = '',
  [int]$SniffSeconds = -1,          # passive listen for devices on other schemes (-1 = config)
  [switch]$NoLogin,
  [switch]$MoveUnlisted,             # also move old-scheme cameras that are NOT on an NVR's camera list (lone camera / no NVR login)                 # discovery only: list what is on the network, no logins, no plan
  [switch]$AllowUnverifiedUniview,  # let the tool write Uniview NVR network/cloud settings by LAPI (see README)
  [string]$ConfigPath = '',
  [string]$MockFile = '',           # TEST HARNESS ONLY
  [string]$ConfirmWith = '',        # TEST HARNESS ONLY (answers the YES prompt)
  [string]$RouterModel = '',        # Snapshot: router make/model typed by the tech (optional)
  [string]$DhcpRange = ''           # Snapshot: router DHCP range typed by the tech, e.g. 100-254, or "reserved" (optional)
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$Version = '1.2 (2026-11-02)'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $here 'config.json' }
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$IsPs5 = $PSVersionTable.PSVersion.Major -lt 6
if ($IsPs5) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
  [Net.ServicePointManager]::Expect100Continue = $false
}
$Mock = $null
if ($MockFile) { $Mock = Get-Content $MockFile -Raw | ConvertFrom-Json }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stateDir = Join-Path $here 'state'; New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$runDir = Join-Path (Join-Path $here 'runs') ($Mode + '-' + $stamp); New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$logFile = Join-Path $runDir 'log.txt'
$sum = New-Object System.Collections.Generic.List[string]
function Redact([string]$s) {
  if (-not $s) { return $s }
  $s = [regex]::Replace($s, '(?is)<password[^>]*>.*?</password>', '<password>***</password>')
  $s = [regex]::Replace($s, '(?i)"(password|passwd|pwd)"\s*:\s*"[^"]*"', '"$1":"***"')
  $s = [regex]::Replace($s, '(?is)<(wsse:)?Password[^>]*>.*?</(wsse:)?Password>', '<Password>***</Password>')
  $s = [regex]::Replace($s, '(?is)<verificationCode>.*?</verificationCode>', '<verificationCode>***</verificationCode>')
  return $s
}
function Log([string]$s) { Add-Content -Path $logFile -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + (Redact $s)) }
function Say([string]$s, [string]$color = '') { if ($color) { Write-Host $s -ForegroundColor $color } else { Write-Host $s }; $sum.Add($s); Log ('SAY ' + $s) }
function Save-Json($obj, [string]$path) { ($obj | ConvertTo-Json -Depth 12) | Set-Content -Path $path -Encoding UTF8 }

# ---------------- IP helpers ----------------
function IpToInt([string]$ip) { $b = ([Net.IPAddress]::Parse($ip)).GetAddressBytes(); return ([uint32]$b[0] -shl 24) -bor ([uint32]$b[1] -shl 16) -bor ([uint32]$b[2] -shl 8) -bor [uint32]$b[3] }
function MaskToPrefix([string]$m) { if (-not $m) { return 24 }; $n = IpToInt $m; $c = 0; for ($i = 31; $i -ge 0; $i--) { if ($n -band ([uint32]1 -shl $i)) { $c++ } else { break } }; return $c }
function PrefixToMask([int]$p) { $n = [uint32]0; for ($i = 0; $i -lt $p; $i++) { $n = $n -bor ([uint32]1 -shl (31 - $i)) }; return (([math]::Floor($n / 16777216)) % 256).ToString() + '.' + (([math]::Floor($n / 65536)) % 256) + '.' + (([math]::Floor($n / 256)) % 256) + '.' + ($n % 256) }
function InNet([string]$ip, [string]$netIp, [int]$prefix) {
  if (-not $ip -or -not $netIp) { return $false }
  try { $m = [uint32]0; for ($i = 0; $i -lt $prefix; $i++) { $m = $m -bor ([uint32]1 -shl (31 - $i)) }; return ((IpToInt $ip) -band $m) -eq ((IpToInt $netIp) -band $m) } catch { return $false }
}
function P3([string]$ip) { if (-not $ip) { return '' }; return (($ip -split '\.')[0..2] -join '.') }
function Last([string]$ip) { return [int](($ip -split '\.')[3]) }
function NormMac([string]$m) { if (-not $m) { return '' }; $h = ($m -replace '[^0-9A-Fa-f]', '').ToUpper(); if ($h.Length -ne 12) { return $m.ToUpper() }; return (($h -split '(..)' | Where-Object { $_ }) -join '-') }
$oui = @{ 'DC-07-F8'='Hikvision'; '28-57-BE'='Hikvision'; '44-19-B6'='Hikvision'; '4C-BD-8F'='Hikvision'; '54-C4-15'='Hikvision'; '58-03-FB'='Hikvision'; 'BC-AD-28'='Hikvision'; 'C0-56-E3'='Hikvision'; 'C4-2F-90'='Hikvision'; 'E0-50-8B'='Hikvision'; '18-68-CB'='Hikvision'; '24-48-45'='Hikvision'; '80-BE-AF'='Hikvision'; 'A4-14-37'='Hikvision'; '8C-E7-48'='Hikvision'; '94-E1-AC'='Hikvision'; 'BC-BA-C2'='Hikvision'; '64-DB-8B'='Hikvision'; '98-DF-82'='Hikvision'; 'E0-CA-3C'='Hikvision'; '08-A1-89'='Hikvision'; '24-0F-9B'='Hikvision'; '2C-A5-9C'='Hikvision'; '40-AC-BF'='Hikvision'; '44-47-CC'='Hikvision'; '4C-F5-DC'='Hikvision'; '68-6D-BC'='Hikvision'; '84-94-37'='Hikvision'; 'AC-B9-2F'='Hikvision'; 'B4-A3-82'='Hikvision'; 'C8-A7-02'='Hikvision'; '48-EA-63'='Uniview'; '6C-F1-7E'='Uniview'; '1C-6A-1B'='Ubiquiti'; '24-5A-4C'='Ubiquiti'; '74-83-C2'='Ubiquiti'; '78-8A-20'='Ubiquiti'; 'B4-FB-E4'='Ubiquiti'; 'F0-9F-C2'='Ubiquiti'; 'FC-EC-DA'='Ubiquiti' }
function Vendor([string]$mac) { $mac = NormMac $mac; if ($mac.Length -lt 8) { return '' }; $p = $mac.Substring(0, 8); if ($oui.ContainsKey($p)) { return $oui[$p] }; return '' }

# ---------------- this PC ----------------
function Get-PcNet {
  if ($Mock) { return $Mock.pc }
  $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue | Sort-Object { $_.RouteMetric + $_.InterfaceMetric } |
       Where-Object { (Get-NetAdapter -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue).Status -eq 'Up' -and (Get-NetAdapter -InterfaceIndex $_.ifIndex).InterfaceDescription -notmatch 'Tailscale|WireGuard|TAP|VPN|Cellular|Mobile Broadband|Hyper-V' } | Select-Object -First 1
  if (-not $r) { return $null }
  $a = Get-NetIPAddress -InterfaceIndex $r.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '169.254*' -and -not $_.SkipAsSource } | Select-Object -First 1
  $nic = Get-NetAdapter -InterfaceIndex $r.ifIndex
  $ipi = Get-NetIPInterface -InterfaceIndex $r.ifIndex -AddressFamily IPv4
  return [pscustomobject]@{ ifIndex = $r.ifIndex; alias = $nic.Name; desc = $nic.InterfaceDescription; ip = $a.IPAddress; prefix = [int]$a.PrefixLength; gw = $r.NextHop; dhcp = ($ipi.Dhcp -eq 'Enabled'); link = $nic.LinkSpeed; wifi = ($nic.PhysicalMediaType -match '802.11' -or $nic.InterfaceDescription -match 'Wi-?Fi|Wireless') }
}

# ---------------- temporary PC address on an old scheme (always removed) ----------------
$tempFile = Join-Path $stateDir 'temp-ips.json'
$script:temps = New-Object System.Collections.Generic.List[object]
$script:pcChanges = [ordered]@{ coexistence_before = $null; firewall_rule = $false; cleanup_task = $false }
$taskName = 'WireIt FixNVR cleanup'
function Write-TempState { Save-Json ([ordered]@{ temps = $script:temps.ToArray(); pc = $script:pcChanges; written = (Get-Date -Format 's') }) $tempFile }
function Set-SafetyTask {
  if ($Mock -or $script:pcChanges.cleanup_task) { return }
  try {
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Mode Cleanup')
    $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes([int]$cfg.safety_cleanup_minutes)
    $pr = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount
    Register-ScheduledTask -TaskName $taskName -Action $act -Trigger $trg -Principal $pr -Force | Out-Null
    $script:pcChanges.cleanup_task = $true; Log ('safety cleanup task set for +' + $cfg.safety_cleanup_minutes + ' min')
  } catch { Log ('safety task not set: ' + $_.Exception.Message) }
}
function Add-TempIp([string]$p3, $pc, $avoid) {
  foreach ($h in $cfg.temp_ip_hosts) {
    $ip = $p3 + '.' + $h
    if ($avoid -contains $ip) { continue }
    if ($Mock) { $script:temps.Add([pscustomobject]@{ ip = $ip; ifIndex = $pc.ifIndex }); Log ('MOCK temp ip ' + $ip); return $ip }
    if ($script:pcChanges.coexistence_before -eq $null -and $pc.dhcp) {
      $t = (netsh interface ipv4 show interface ([string]$pc.ifIndex)) -join "`n"
      $m = [regex]::Match($t, '(?i)DHCP/Static IP coexistence\s*:\s*(\w+)')
      $script:pcChanges.coexistence_before = $(if ($m.Success) { $m.Groups[1].Value } else { 'unknown' })
      if ($script:pcChanges.coexistence_before -notmatch 'enabled') { netsh interface ipv4 set interface ([string]$pc.ifIndex) dhcpstaticipcoexistence=enabled | Out-Null }
    }
    $script:temps.Add([pscustomobject]@{ ip = $ip; ifIndex = $pc.ifIndex }); Write-TempState; Set-SafetyTask
    try {
      New-NetIPAddress -InterfaceIndex $pc.ifIndex -IPAddress $ip -PrefixLength 24 -SkipAsSource $true -PolicyStore ActiveStore -ErrorAction Stop | Out-Null
    } catch { Log ('add ' + $ip + ' failed: ' + $_.Exception.Message); Remove-OneTemp $ip $pc.ifIndex; continue }
    $st = 'Tentative'
    for ($w = 0; $w -lt 8 -and $st -eq 'Tentative'; $w++) { Start-Sleep -Seconds 1; $st = (Get-NetIPAddress -InterfaceIndex $pc.ifIndex -IPAddress $ip -ErrorAction SilentlyContinue).AddressState }
    if ($st -eq 'Duplicate') { Log ($ip + ' is used by another device, trying the next'); Remove-OneTemp $ip $pc.ifIndex; continue }
    Log ('temp ip ' + $ip + ' added (' + $st + ')'); return $ip
  }
  return $null
}
function Remove-OneTemp([string]$ip, $ifIndex) {
  if (-not $Mock) { Remove-NetIPAddress -IPAddress $ip -InterfaceIndex $ifIndex -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue; Remove-NetIPAddress -IPAddress $ip -Confirm:$false -ErrorAction SilentlyContinue }
  $x = @($script:temps | Where-Object { $_.ip -eq $ip }); foreach ($e in $x) { [void]$script:temps.Remove($e) }
  if (-not $Mock) { Write-TempState }
}
function Remove-AllTemp {
  foreach ($t in $script:temps.ToArray()) { Remove-OneTemp $t.ip $t.ifIndex; Log ('temp ip ' + $t.ip + ' removed') }
  if ($Mock) { return }
  $pcn = $script:pcNet
  if ($script:pcChanges.coexistence_before -ne $null -and $script:pcChanges.coexistence_before -notmatch 'enabled' -and $pcn) { netsh interface ipv4 set interface ([string]$pcn.ifIndex) dhcpstaticipcoexistence=disabled | Out-Null; Log 'coexistence restored' }
  if ($pcn -and $pcn.dhcp) { $ipi = Get-NetIPInterface -InterfaceIndex $pcn.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue; if ($ipi -and $ipi.Dhcp -ne 'Enabled') { Set-NetIPInterface -InterfaceIndex $pcn.ifIndex -Dhcp Enabled; Log 'DHCP re-enabled on PC NIC' } }
  if ($script:pcChanges.firewall_rule) { Remove-NetFirewallRule -DisplayName 'WireIt FixNVR discovery (temp)' -ErrorAction SilentlyContinue; Log 'temp firewall rule removed' }
  if ($script:pcChanges.cleanup_task) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
  $script:pcChanges.coexistence_before = $null; $script:pcChanges.firewall_rule = $false; $script:pcChanges.cleanup_task = $false
  Remove-Item $tempFile -ErrorAction SilentlyContinue
  $left = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.SkipAsSource -and $_.PolicyStore -eq 'ActiveStore' -and ($cfg.temp_ip_hosts -contains (Last $_.IPAddress)) })
  if ($left.Count) { Log ('WARNING possible leftover temp addresses: ' + (($left | ForEach-Object { $_.IPAddress }) -join ', ')) }
}
function Invoke-LeftoverCleanup {
  if ($Mock -or -not (Test-Path $tempFile)) { return }
  try { $o = Get-Content $tempFile -Raw | ConvertFrom-Json } catch { $o = $null }
  if ($o) {
    foreach ($t in @($o.temps)) { if ($t) { Remove-NetIPAddress -IPAddress $t.ip -Confirm:$false -ErrorAction SilentlyContinue; Write-Host ('Removed a temporary address a previous run left behind: ' + $t.ip) } }
    if ($o.pc.coexistence_before -and $o.pc.coexistence_before -notmatch 'enabled' -and @($o.temps).Count) { netsh interface ipv4 set interface ([string]$o.temps[0].ifIndex) dhcpstaticipcoexistence=disabled | Out-Null }
    if ($o.pc.firewall_rule) { Remove-NetFirewallRule -DisplayName 'WireIt FixNVR discovery (temp)' -ErrorAction SilentlyContinue }
  }
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  Remove-Item $tempFile -ErrorAction SilentlyContinue
}

# ---------------- discovery ----------------
function Open-Firewall {
  if ($Mock -or $script:pcChanges.firewall_rule) { return }
  try { New-NetFirewallRule -DisplayName 'WireIt FixNVR discovery (temp)' -Direction Inbound -Protocol UDP -LocalPort 37020,3702 -Action Allow -Profile Any -ErrorAction Stop | Out-Null; $script:pcChanges.firewall_rule = $true; Write-TempState } catch { Log ('firewall rule not added: ' + $_.Exception.Message) }
}
function XVal([string]$xml, [string]$name) { $m = [regex]::Match($xml, '<(?:\w+:)?' + $name + '(?:\s[^>]*)?>([^<]*)</(?:\w+:)?' + $name + '>'); if ($m.Success) { return $m.Groups[1].Value.Trim() } else { return '' } }
function Parse-Sadp([string]$x) {
  $ch = 0; [void][int]::TryParse((XVal $x 'DigitalChannelNum'), [ref]$ch); $an = 0; [void][int]::TryParse((XVal $x 'AnalogChannelNum'), [ref]$an)
  $model = XVal $x 'DeviceDescription'
  $isRec = ($ch -gt 0 -or $an -gt 0 -or $model -match '^(i?DS-7|i?DS-9|NRA|HNR|ERI-K|.*NVR)')
  return [pscustomobject]@{ ip = (XVal $x 'IPv4Address'); mask = (XVal $x 'IPv4SubnetMask'); gw = (XVal $x 'IPv4Gateway'); mac = (NormMac (XVal $x 'MAC')); serial = (XVal $x 'DeviceSN'); model = $model; firmware = (XVal $x 'SoftwareVersion'); dhcp = ((XVal $x 'DHCP') -eq 'true'); activated = (XVal $x 'Activated'); http_port = (XVal $x 'HttpPort'); boot = (XVal $x 'BootTime'); oem = (XVal $x 'OEMInfo'); brand = 'hik'; kind = $(if ($isRec) { 'nvr' } else { 'camera' }); found_by = 'SADP' }
}
function Find-Sadp($localIps) {
  $out = @{}
  if ($Mock) { foreach ($x in @($Mock.sadp)) { $d = Parse-Sadp $x; $out[$d.mac] = $d }; return $out }
  $socks = @()
  foreach ($l in $localIps) {
    try {
      $u = New-Object System.Net.Sockets.UdpClient
      $u.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket, [Net.Sockets.SocketOptionName]::ReuseAddress, $true)
      $u.Client.Bind((New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($l)), 37020))
      try { $u.JoinMulticastGroup([Net.IPAddress]::Parse('239.255.255.250'), [Net.IPAddress]::Parse($l)) } catch {}
      $u.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::IP, [Net.Sockets.SocketOptionName]::MulticastInterface, ([Net.IPAddress]::Parse($l)).GetAddressBytes())
      $socks += $u
    } catch { Log ('SADP socket on ' + $l + ': ' + $_.Exception.Message + ' (close SADP/HiTools if open)') }
  }
  $probe = [Text.Encoding]::UTF8.GetBytes('<?xml version="1.0" encoding="utf-8"?><Probe><Uuid>' + ([guid]::NewGuid().ToString().ToUpper()) + '</Uuid><Types>inquiry</Types></Probe>')
  $ep0 = New-Object Net.IPEndPoint ([Net.IPAddress]::Parse('239.255.255.250')), 37020
  foreach ($s in $socks) { for ($k = 0; $k -lt 2; $k++) { try { [void]$s.Send($probe, $probe.Length, $ep0) } catch {} } }
  $end = (Get-Date).AddSeconds([int]$cfg.sadp_listen_seconds)
  while ((Get-Date) -lt $end) {
    foreach ($s in $socks) { while ($s.Available -gt 0) { $ep = New-Object Net.IPEndPoint ([Net.IPAddress]::Any), 0; try { $t = [Text.Encoding]::UTF8.GetString($s.Receive([ref]$ep)); if ($t -match '<ProbeMatch>' -and $t -match '<DeviceSN>') { $d = Parse-Sadp $t; if ($d.mac) { $out[$d.mac] = $d } } } catch {} } }
    Start-Sleep -Milliseconds 100
  }
  foreach ($s in $socks) { $s.Close() }
  return $out
}
function Find-ArpSniff([int]$seconds) {
  # passive: devices stuck on an old scheme keep ARPing for their old gateway/NVR. Uses Windows' built-in pktmon.
  $res = @{}
  if ($Mock) { foreach ($a in @($Mock.arp)) { $res[(NormMac $a.mac)] = $a.ip }; return $res }
  if ($seconds -le 0 -or -not (Get-Command pktmon.exe -ErrorAction SilentlyContinue)) { return $res }
  $st = (pktmon status 2>&1) -join "`n"
  if ($st -notmatch '(?i)not running') { Log 'pktmon busy, passive listen skipped'; return $res }
  $fl = (pktmon filter list 2>&1) -join "`n"
  if ($fl -notmatch '(?i)no filters|There are no|Filters:\s*None') { Log 'pktmon has filters set by someone else, passive listen skipped'; return $res }
  $etl = Join-Path $runDir 'arp.etl'; $txt = Join-Path $runDir 'arp.txt'
  try {
    pktmon filter add FixNVRarp -d ARP | Out-Null
    pktmon start --capture --pkt-size 128 --file-name $etl | Out-Null
    Start-Sleep -Seconds $seconds
  } finally { pktmon stop | Out-Null; pktmon filter remove | Out-Null }
  pktmon etl2txt $etl --out $txt 2>&1 | Out-Null
  if (-not (Test-Path $txt)) { pktmon format $etl -o $txt 2>&1 | Out-Null }
  if (Test-Path $txt) {
    foreach ($ln in (Get-Content $txt)) {
      $m = [regex]::Match($ln, '([0-9A-Fa-f]{2}(?:-[0-9A-Fa-f]{2}){5}) > [0-9A-Fa-f-]{17}.*?(?:who-has \S+ tell (\d+\.\d+\.\d+\.\d+)|Reply (\d+\.\d+\.\d+\.\d+) is-at)')
      if ($m.Success) { $ip = $m.Groups[2].Value; if (-not $ip) { $ip = $m.Groups[3].Value }; if ($ip -and $ip -ne '0.0.0.0' -and $ip -notlike '169.254.*') { $res[(NormMac $m.Groups[1].Value)] = $ip } }
    }
  }
  Remove-Item $etl -ErrorAction SilentlyContinue
  Log ('passive listen: ' + $res.Count + ' device(s) heard')
  return $res
}
function Find-Onvif($localIps) {
  # WS-Discovery (ONVIF standard). Replies come back to the address we sent from, so run it from the temp address too.
  $out = @{}
  if ($Mock) { foreach ($o in @($Mock.onvif)) { $out[$o.ip] = $o.scopes }; return $out }
  $msg = '<?xml version="1.0" encoding="UTF-8"?><e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl"><e:Header><w:MessageID>uuid:' + [guid]::NewGuid() + '</w:MessageID><w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To><w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>'
  $b = [Text.Encoding]::UTF8.GetBytes($msg); $socks = @()
  foreach ($l in $localIps) { try { $u = New-Object System.Net.Sockets.UdpClient (New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($l)), 0); [void]$u.Send($b, $b.Length, (New-Object Net.IPEndPoint ([Net.IPAddress]::Parse('239.255.255.250')), 3702)); $socks += $u } catch {} }
  $end = (Get-Date).AddSeconds(3)
  while ((Get-Date) -lt $end) { foreach ($s in $socks) { while ($s.Available -gt 0) { $ep = New-Object Net.IPEndPoint ([Net.IPAddress]::Any), 0; try { $t = [Text.Encoding]::UTF8.GetString($s.Receive([ref]$ep)); if ($t -match 'XAddrs') { $out[$ep.Address.ToString()] = (XVal $t 'Scopes') } } catch {} } }; Start-Sleep -Milliseconds 100 }
  foreach ($s in $socks) { $s.Close() }
  return $out
}
function Test-IpFree([string]$ip) {
  if ($Mock) { try { $r = Invoke-RestMethod -Uri ($Mock.url + '/mockctl/has/' + $ip) -TimeoutSec 5; return -not $r.used } catch { return $true } }
  $p = New-Object Net.NetworkInformation.Ping
  for ($k = 0; $k -lt 2; $k++) { try { if ($p.Send($ip, 700).Status -eq 'Success') { return $false } } catch {} }
  $n = Get-NetNeighbor -IPAddress $ip -ErrorAction SilentlyContinue | Where-Object { $_.State -in 'Reachable','Stale','Permanent' -and $_.LinkLayerAddress -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' }
  return -not $n
}

# ---------------- credentials (asked once, kept in memory only) ----------------
$script:credNvr = $null; $script:credCam = $null
function Get-Creds {
  if ($CredFile -and (Test-Path $CredFile)) {
    $cl = Get-Content $CredFile; $script:credNvr = New-Object PSCredential($cl[0], (ConvertTo-SecureString $cl[1] -AsPlainText -Force))
    if ($cl.Count -ge 3 -and $cl[2]) { $script:credCam = New-Object PSCredential($cl[0], (ConvertTo-SecureString $cl[2] -AsPlainText -Force)) } else { $script:credCam = $script:credNvr }
    return
  }
  if ($BitwardenExport -and (Test-Path $BitwardenExport)) {
    $bw = Get-Content $BitwardenExport -Raw | ConvertFrom-Json
    $items = @($bw.items | Where-Object { $_.login -and $_.login.password })
    $it = $null
    if ($BitwardenItem) { $it = $items | Where-Object { $_.name -eq $BitwardenItem } | Select-Object -First 1 }
    if (-not $it) {
      $cand = @($items | Where-Object { $_.name -match '(?i)nvr|camera|cam|hik|uniview|unv|dvr' -or ($Site -and $_.name -like ('*' + $Site + '*')) })
      if (-not $cand.Count) { $cand = $items }
      Write-Host 'Bitwarden items:'; for ($i = 0; $i -lt [math]::Min($cand.Count, 40); $i++) { Write-Host ('  ' + ($i + 1) + ') ' + $cand[$i].name) }
      $n = Read-Host 'Number of the NVR login item'; $it = $cand[[int]$n - 1]
    }
    $u = $(if ($it.login.username) { $it.login.username } else { $User })
    $script:credNvr = New-Object PSCredential($u, (ConvertTo-SecureString $it.login.password -AsPlainText -Force)); $bw = $null; $items = $null; $it = $null
    Write-Host 'Using that login (password not shown). Delete the Bitwarden export file when you are done.' -ForegroundColor Yellow
  } else {
    $s = Read-Host ('NVR password for user "' + $User + '" (typing is hidden)') -AsSecureString
    $script:credNvr = New-Object PSCredential($User, $s)
  }
  $c = Read-Host 'Camera password (just press Enter if it is the same as the NVR)' -AsSecureString
  if ($c.Length -gt 0) { $script:credCam = New-Object PSCredential($script:credNvr.UserName, $c) } else { $script:credCam = $script:credNvr }
}
function Cred-For($dev) { if ($dev.kind -eq 'nvr') { return $script:credNvr } else { return $script:credCam } }

# ---------------- HTTP (digest login, ONE attempt per device; a refused login is never retried) ----------------
$script:refused = @{}
$script:scheme = @{}
function Base([string]$ip) {
  if ($Mock) { return ($Mock.url + '/dev/' + $ip) }
  if ($script:scheme.ContainsKey($ip)) { return ($script:scheme[$ip] + '://' + $ip) }
  return ('http://' + $ip)
}
function Err-Body($ex) { try { $r = $ex.Exception.Response; if ($r) { $sr = New-Object IO.StreamReader($r.GetResponseStream()); return $sr.ReadToEnd() } } catch {}; return '' }
function Http([string]$ip, [string]$method, [string]$path, [string]$body = '', [string]$ctype = 'application/xml', $cred = $null, [int]$timeout = 10) {
  if ($script:refused.ContainsKey($ip)) { return @{ code = 401; body = ''; err = 'login refused earlier, not retried' } }
  $args2 = @{ Uri = ((Base $ip) + $path); Method = $method; UseBasicParsing = $true; TimeoutSec = $timeout }
  if ($cred) { $args2.Credential = $cred }
  if ($body) { $args2.Body = [Text.Encoding]::UTF8.GetBytes($body); $args2.ContentType = $ctype }
  if (-not $IsPs5) { $args2.SkipCertificateCheck = $true; if ($cred) { $args2.AllowUnencryptedAuthentication = $true } }
  Log ($method + ' ' + $ip + $path + $(if ($body) { ' BODY ' + $body } else { '' }))
  for ($try = 0; $try -lt 2; $try++) {
    try {
      $r = Invoke-WebRequest @args2
      $c = [string]$r.Content; if ($r.Content -is [byte[]]) { $c = [Text.Encoding]::UTF8.GetString($r.Content) }
      Log ('  -> ' + [int]$r.StatusCode + ' ' + $(if ($c.Length -gt 600) { $c.Substring(0, 600) + '...' } else { $c }))
      return @{ code = [int]$r.StatusCode; body = $c; err = '' }
    } catch {
      $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {}
      $eb = Err-Body $_
      Log ('  -> ' + $code + ' ' + $_.Exception.Message + ' ' + $eb)
      if ($code -eq 401 -and $cred) { $script:refused[$ip] = $true; return @{ code = 401; body = $eb; err = 'login refused' } }
      if ($code -eq 0 -and $try -eq 0 -and -not $Mock -and -not $script:scheme.ContainsKey($ip)) { $script:scheme[$ip] = 'https'; $args2.Uri = ((Base $ip) + $path); continue }
      return @{ code = $code; body = $eb; err = $_.Exception.Message }
    }
  }
  return @{ code = 0; body = ''; err = 'no answer' }
}
function Hik-Status([string]$body) { return [pscustomobject]@{ code = (XVal $body 'statusCode'); text = (XVal $body 'statusString'); sub = (XVal $body 'subStatusCode') } }
function Hik-Ok($r) { if ($r.code -ne 200) { return $false }; $s = Hik-Status $r.body; return (-not $s.code -or $s.code -eq '1' -or $s.code -eq '7') }
function Hik-Reboot($r) { $s = Hik-Status $r.body; return ($s.code -eq '7' -or $s.sub -match '(?i)reboot') }

# XML edit helpers (namespace-agnostic, keep everything the device sent)
function XNode($parent, [string]$path, [switch]$Create) {
  $n = $parent
  foreach ($seg in ($path -split '/')) {
    $c = $null; foreach ($ch in $n.ChildNodes) { if ($ch.LocalName -eq $seg) { $c = $ch; break } }
    if (-not $c) { if (-not $Create) { return $null }; $c = $n.OwnerDocument.CreateElement($seg, $n.NamespaceURI); [void]$n.AppendChild($c) }
    $n = $c
  }
  return $n
}
function XGet($doc, [string]$path) { $n = XNode $doc.DocumentElement $path; if ($n) { return $n.InnerText } else { return '' } }
function XSet($doc, [string]$path, [string]$v) { $n = XNode $doc.DocumentElement $path -Create; $n.InnerText = $v }

# ---------------- Hikvision (ISAPI) ----------------
function Hik-Read($dev) {
  $cred = Cred-For $dev
  $d = Http $dev.ip 'GET' '/ISAPI/System/deviceInfo' '' 'application/xml' $cred
  if ($d.code -ne 200) { $dev.login = $(if ($d.code -eq 401) { 'REFUSED (wrong password? not retried)' } else { 'no answer (' + $d.code + ')' }); return $false }
  $dev.login = 'ok'; $dev.brand = 'hik'
  $dev.model = XVal $d.body 'model'; $dev.serial = XVal $d.body 'serialNumber'; $m = XVal $d.body 'macAddress'; if ($m) { $dev.mac = NormMac $m }
  $dt = XVal $d.body 'deviceType'; if ($dt -match '(?i)NVR|DVR|HVR|recorder') { $dev.kind = 'nvr' } elseif ($dt) { $dev.kind = 'camera' }
  $dev.firmware = XVal $d.body 'firmwareVersion'
  $ifs = Http $dev.ip 'GET' '/ISAPI/System/Network/interfaces' '' 'application/xml' $cred
  $ifid = '1'
  foreach ($mm in [regex]::Matches($ifs.body, '(?s)<NetworkInterface[ >].*?</NetworkInterface>')) { if ((XVal $mm.Value 'ipAddress') -eq $dev.ip) { $ifid = XVal $mm.Value 'id'; break } }
  $dev.if_id = $ifid
  $ipx = Http $dev.ip 'GET' ('/ISAPI/System/Network/interfaces/' + $ifid + '/ipAddress') '' 'application/xml' $cred
  if ($ipx.code -eq 200) {
    $dev.net_xml = $ipx.body
    $doc = [xml]$ipx.body
    $dev.addressing = XGet $doc 'addressingType'; $dev.mask = XGet $doc 'subnetMask'; $dev.gw = XGet $doc 'DefaultGateway/ipAddress'
    $dev.dns1 = XGet $doc 'PrimaryDNS/ipAddress'; $dev.dns2 = XGet $doc 'SecondaryDNS/ipAddress'
  }
  if ($dev.kind -eq 'nvr') {
    $ez = Http $dev.ip 'GET' '/ISAPI/System/Network/EZVIZ' '' 'application/xml' $cred
    if ($ez.code -eq 200) { $dev.platform_xml = $ez.body; $dev.platform_enabled = ((XVal $ez.body 'enabled') -eq 'true'); $dev.platform_online = ((XVal $ez.body 'registerStatus') -eq 'true'); $dev.platform_has_code = [bool](XVal $ez.body 'verificationCode') }
    $chs = Http $dev.ip 'GET' '/ISAPI/ContentMgmt/InputProxy/channels' '' 'application/xml' $cred
    $st = Http $dev.ip 'GET' '/ISAPI/ContentMgmt/InputProxy/channels/status' '' 'application/xml' $cred
    $online = @{}; foreach ($mm in [regex]::Matches($st.body, '(?s)<InputProxyChannelStatus[ >].*?</InputProxyChannelStatus>')) { $online[(XVal $mm.Value 'id')] = ((XVal $mm.Value 'online') -eq 'true') }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($mm in [regex]::Matches($chs.body, '(?s)<InputProxyChannel[ >].*?</InputProxyChannel>')) {
      $id = XVal $mm.Value 'id'
      $list.Add([pscustomobject]@{ id = $id; ip = (XVal $mm.Value 'ipAddress'); port = (XVal $mm.Value 'managePortNo'); protocol = (XVal $mm.Value 'proxyProtocol'); online = $online[$id]; poe = $false })
    }
    $dev.channels = $list
  }
  return $true
}
function Hik-SetNet($dev, [string]$ip, [string]$mask, [string]$gw, [string]$dns1, [string]$dns2) {
  $doc = [xml]$dev.net_xml
  XSet $doc 'addressingType' 'static'; XSet $doc 'ipAddress' $ip; XSet $doc 'subnetMask' $mask; XSet $doc 'DefaultGateway/ipAddress' $gw
  if ($dns1) { XSet $doc 'PrimaryDNS/ipAddress' $dns1 }; if ($dns2) { XSet $doc 'SecondaryDNS/ipAddress' $dns2 }
  $r = Http $dev.ip 'PUT' ('/ISAPI/System/Network/interfaces/' + $dev.if_id + '/ipAddress') $doc.OuterXml 'application/xml' (Cred-For $dev) 15
  if ($r.code -eq 0 -and $r.err -match '(?i)timed out|closed|aborted|reset') { return @{ ok = $true; reboot = $false; note = 'device dropped the connection while moving (normal)' } }
  return @{ ok = (Hik-Ok $r); reboot = (Hik-Reboot $r); note = ((Hik-Status $r.body).text + ' ' + $r.err).Trim() }
}
function Hik-EnablePlatform($dev) {
  $doc = [xml]$dev.platform_xml
  XSet $doc 'enabled' 'true'
  $r = Http $dev.ip 'PUT' '/ISAPI/System/Network/EZVIZ' $doc.OuterXml 'application/xml' $script:credNvr 15
  return @{ ok = (Hik-Ok $r); note = ((Hik-Status $r.body).text + ' ' + $r.err).Trim() }
}
function Hik-SetChannel($nvr, [string]$id, [string]$newIp) {
  $g = Http $nvr.ip 'GET' ('/ISAPI/ContentMgmt/InputProxy/channels/' + $id) '' 'application/xml' $script:credNvr
  if ($g.code -ne 200) { return @{ ok = $false; note = 'could not read channel ' + $id } }
  $doc = [xml]$g.body
  $sd = XNode $doc.DocumentElement 'sourceInputPortDescriptor'
  XSet $doc 'sourceInputPortDescriptor/ipAddress' $newIp
  $pw = XNode $sd 'password'
  if (-not $pw) { $pw = $doc.CreateElement('password', $sd.NamespaceURI); $un = XNode $sd 'userName'; if ($un) { [void]$sd.InsertAfter($pw, $un) } else { [void]$sd.AppendChild($pw) } }
  $pw.InnerText = $script:credCam.GetNetworkCredential().Password
  $r = Http $nvr.ip 'PUT' ('/ISAPI/ContentMgmt/InputProxy/channels/' + $id) $doc.OuterXml 'application/xml' $script:credNvr 15
  $pw.InnerText = ''; $doc = $null
  return @{ ok = (Hik-Ok $r); note = ((Hik-Status $r.body).text + ' ' + $r.err).Trim() }
}
function Hik-RebootNow($dev) { $r = Http $dev.ip 'PUT' '/ISAPI/System/reboot' '' 'application/xml' (Cred-For $dev) 15; return (Hik-Ok $r) }

# ---------------- Uniview (LAPI read; network writes need -AllowUnverifiedUniview until tested on a real unit) ----------------
function Unv-Data([string]$body) { try { $j = $body | ConvertFrom-Json; if ($j.Response) { return $j.Response.Data } ; return $j } catch { return $null } }
function Unv-Ok([string]$body) { try { $j = $body | ConvertFrom-Json; return ($j.Response.ResponseCode -eq 0 -or $j.Response.StatusCode -eq 0) } catch { return $false } }
function Unv-Read($dev) {
  $cred = Cred-For $dev
  $d = Http $dev.ip 'GET' '/LAPI/V1.0/System/DeviceBasicInfo' '' 'application/json' $cred
  if ($d.code -ne 200) { if ($d.code -eq 401) { $dev.login = 'REFUSED (wrong password? not retried)' }; return $false }
  $x = Unv-Data $d.body; if (-not $x) { return $false }
  $dev.login = 'ok'; $dev.brand = 'unv'; $dev.model = $x.DeviceModel; $dev.serial = $x.SerialNumber; if ($x.MAC) { $dev.mac = NormMac $x.MAC }
  $dev.firmware = $x.FirmwareVersion; if ($x.Netmask) { $dev.mask = $x.Netmask }; if ($x.Gateway) { $dev.gw = $x.Gateway }
  if ($dev.model -match '(?i)^NVR|^VMS|^DVR') { $dev.kind = 'nvr' } elseif (-not $dev.kind) { $dev.kind = 'camera' }
  if ($dev.kind -eq 'nvr') {
    $n = Http $dev.ip 'GET' $cfg.uniview.net_path '' 'application/json' $cred; if ($n.code -eq 200) { $dev.net_json = $n.body }
    $dn = Http $dev.ip 'GET' $cfg.uniview.dns_path '' 'application/json' $cred; if ($dn.code -eq 200) { $dev.dns_json = $dn.body; $dd = Unv-Data $dn.body; $vals = @(Find-JsonVals $dd '(?i)dns'); if ($vals.Count) { $dev.dns1 = $vals[0]; if ($vals.Count -gt 1) { $dev.dns2 = $vals[1] } } }
    if ($cfg.uniview.cloud_path) { $cl = Http $dev.ip 'GET' $cfg.uniview.cloud_path '' 'application/json' $cred; if ($cl.code -eq 200) { $dev.platform_json = $cl.body; $cd = Unv-Data $cl.body; $en = @(Find-JsonVals $cd '(?i)^enable'); if ($en.Count) { $dev.platform_enabled = ([string]$en[0] -match '^(1|true)$') } } }
    $c = Http $dev.ip 'GET' $cfg.uniview.channels_path '' 'application/json' $cred
    $list = New-Object System.Collections.Generic.List[object]
    if ($c.code -eq 200) {
      $cd = Unv-Data $c.body; $arr = @(); foreach ($p in $cd.PSObject.Properties) { if ($p.Value -is [array]) { $arr = $p.Value } }
      foreach ($ch in $arr) { $ip = @(Find-JsonVals $ch '(?i)^(IPAddress|Address|IP)$'); $st = @(Find-JsonVals $ch '(?i)^(Status|Online|OnlineStatus)$'); $list.Add([pscustomobject]@{ id = [string]$ch.ID; ip = $(if ($ip.Count) { [string]$ip[0] } else { '' }); port = ''; protocol = 'unv'; online = $(if ($st.Count) { [string]$st[0] -match '^(1|true|online)$' } else { $null }); poe = $false }) }
    }
    $dev.channels = $list
  }
  return $true
}
function Find-JsonVals($o, [string]$keyRx) {
  $res = @()
  if ($o -eq $null) { return $res }
  if ($o -is [array]) { foreach ($e in $o) { $res += Find-JsonVals $e $keyRx }; return $res }
  if ($o -is [pscustomobject]) { foreach ($p in $o.PSObject.Properties) { if ($p.Name -match $keyRx -and $p.Name -notmatch '(?i)mac' -and ($p.Value -is [string] -or $p.Value -is [int] -or $p.Value -is [long] -or $p.Value -is [bool])) { $res += $p.Value } elseif ($p.Value -is [pscustomobject] -or $p.Value -is [array]) { $res += Find-JsonVals $p.Value $keyRx } } }
  return $res
}
function Set-JsonVals($o, [string]$keyRx, $value) {
  if ($o -is [array]) { foreach ($e in $o) { Set-JsonVals $e $keyRx $value }; return }
  if ($o -is [pscustomobject]) { foreach ($p in $o.PSObject.Properties) { if ($p.Name -match $keyRx -and $p.Name -notmatch '(?i)mac|v6' -and -not ($p.Value -is [pscustomobject] -or $p.Value -is [array])) { $p.Value = $value } elseif ($p.Value -is [pscustomobject] -or $p.Value -is [array]) { Set-JsonVals $p.Value $keyRx $value } } }
}
function Unv-PlanNet($dev, [string]$ip, [string]$mask, [string]$gw) {
  $j = $dev.net_json | ConvertFrom-Json; $d = $j.Response.Data; if (-not $d) { $d = $j }
  Set-JsonVals $d '(?i)^(IPv4)?(IP)?Address$' $ip; Set-JsonVals $d '(?i)(Sub)?net ?mask$' $mask; Set-JsonVals $d '(?i)(Default)?Gateway$' $gw
  return ($d | ConvertTo-Json -Depth 10 -Compress)
}
function Unv-PlanDns($dev, [string]$d1, [string]$d2) {
  $j = $dev.dns_json | ConvertFrom-Json; $d = $j.Response.Data; if (-not $d) { $d = $j }
  $props = @($d.PSObject.Properties | Where-Object { $_.Name -match '(?i)dns' -and -not ($_.Value -is [pscustomobject]) })
  if ($props.Count -ge 1) { $props[0].Value = $d1 }; if ($props.Count -ge 2) { $props[1].Value = $d2 }
  return ($d | ConvertTo-Json -Depth 10 -Compress)
}
function Unv-PlanCloud($dev) { $j = $dev.platform_json | ConvertFrom-Json; $d = $j.Response.Data; if (-not $d) { $d = $j }; Set-JsonVals $d '(?i)^enable' 1; return ($d | ConvertTo-Json -Depth 10 -Compress) }
function Unv-Put($dev, [string]$path, [string]$json) { $r = Http $dev.ip 'PUT' $path $json 'application/json' (Cred-For $dev) 15; if ($r.code -eq 0 -and $r.err -match '(?i)timed out|closed|aborted') { return @{ ok = $true; note = 'connection dropped while moving (normal)' } }; return @{ ok = ($r.code -eq 200 -and (Unv-Ok $r.body)); note = $r.err } }

# ---------------- ONVIF (open standard; used to move Uniview / other-brand cameras) ----------------
function Onvif([string]$ip, [string]$inner, $cred) {
  $nonce = New-Object byte[] 16; (New-Object Security.Cryptography.RNGCryptoServiceProvider).GetBytes($nonce)
  $created = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
  $pwb = [Text.Encoding]::UTF8.GetBytes($cred.GetNetworkCredential().Password); $cb = [Text.Encoding]::UTF8.GetBytes($created)
  $all = New-Object byte[] ($nonce.Length + $cb.Length + $pwb.Length); [Array]::Copy($nonce, 0, $all, 0, 16); [Array]::Copy($cb, 0, $all, 16, $cb.Length); [Array]::Copy($pwb, 0, $all, 16 + $cb.Length, $pwb.Length)
  $dig = [Convert]::ToBase64String((New-Object Security.Cryptography.SHA1Managed).ComputeHash($all)); [Array]::Clear($all, 0, $all.Length); [Array]::Clear($pwb, 0, $pwb.Length)
  $env = '<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl" xmlns:tt="http://www.onvif.org/ver10/schema"><s:Header><wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"><wsse:UsernameToken><wsse:Username>' + [Security.SecurityElement]::Escape($cred.UserName) + '</wsse:Username><wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">' + $dig + '</wsse:Password><wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">' + [Convert]::ToBase64String($nonce) + '</wsse:Nonce><wsu:Created>' + $created + '</wsu:Created></wsse:UsernameToken></wsse:Security></s:Header><s:Body>' + $inner + '</s:Body></s:Envelope>'
  return (Http $ip 'POST' '/onvif/device_service' $env 'application/soap+xml; charset=utf-8' $null 15)
}
function Onvif-Read($dev) {
  $r = Onvif $dev.ip '<tds:GetNetworkInterfaces/>' (Cred-For $dev)
  if ($r.code -ne 200) { if (-not $dev.login) { $dev.login = 'ONVIF no answer/refused (' + $r.code + ')' }; return $false }
  $m = [regex]::Match($r.body, '<(?:\w+:)?NetworkInterfaces[^>]*token="([^"]+)"'); $dev.onvif_token = $(if ($m.Success) { $m.Groups[1].Value } else { 'eth0' })
  $pl = XVal $r.body 'PrefixLength'; if ($pl) { $dev.mask = PrefixToMask ([int]$pl) }
  $hw = XVal $r.body 'HwAddress'; if ($hw -and -not $dev.mac) { $dev.mac = NormMac $hw }
  $dev.onvif = $true; if (-not $dev.login) { $dev.login = 'ok (ONVIF)' }
  return $true
}
function Onvif-SetNet($dev, [string]$ip, [int]$prefix, [string]$gw, [string]$d1, [string]$d2) {
  $c = Cred-For $dev
  $r = Onvif $dev.ip ('<tds:SetNetworkInterfaces><tds:InterfaceToken>' + $dev.onvif_token + '</tds:InterfaceToken><tds:NetworkInterface><tt:Enabled>true</tt:Enabled><tt:IPv4><tt:Enabled>true</tt:Enabled><tt:Manual><tt:Address>' + $ip + '</tt:Address><tt:PrefixLength>' + $prefix + '</tt:PrefixLength></tt:Manual><tt:DHCP>false</tt:DHCP></tt:IPv4></tds:NetworkInterface></tds:SetNetworkInterfaces>') $c
  $dropped = ($r.code -eq 0 -and $r.err -match '(?i)timed out|closed|aborted')
  if ($r.code -ne 200 -and -not $dropped) { return @{ ok = $false; note = 'SetNetworkInterfaces ' + $r.code + ' ' + $r.err } }
  $reboot = ((XVal $r.body 'RebootNeeded') -eq 'true')
  if ($reboot) { [void](Onvif $dev.ip '<tds:SystemReboot/>' $c) }
  # gateway + DNS are set on the NEW address (the old gateway setting would be off-subnet)
  $ok2 = $false
  for ($k = 0; $k -lt [int]$cfg.camera_wait_seconds; $k += 5) {
    Start-Sleep -Seconds 5
    $g = Onvif $ip ('<tds:SetNetworkDefaultGateway><tds:IPv4Address>' + $gw + '</tds:IPv4Address></tds:SetNetworkDefaultGateway>') $c
    if ($g.code -eq 200) { $ok2 = $true; break }
  }
  if ($ok2) { [void](Onvif $ip ('<tds:SetDNS><tds:FromDHCP>false</tds:FromDHCP><tds:DNSManual><tt:Type>IPv4</tt:Type><tt:IPv4Address>' + $d1 + '</tt:IPv4Address></tds:DNSManual><tds:DNSManual><tt:Type>IPv4</tt:Type><tt:IPv4Address>' + $d2 + '</tt:IPv4Address></tds:DNSManual></tds:SetDNS>') $c) }
  return @{ ok = $ok2; reboot = $reboot; note = $(if ($ok2) { '' } else { 'moved, but did not answer on the new address in time' }) }
}

# ---------------- device records ----------------
$script:devs = New-Object System.Collections.Generic.List[object]
function New-Dev([string]$ip, [string]$mac, [string]$by) {
  $d = [pscustomobject]@{ ip = $ip; mac = (NormMac $mac); vendor = (Vendor $mac); brand = ''; kind = ''; model = ''; serial = ''; firmware = ''; mask = ''; gw = ''; dns1 = ''; dns2 = ''; addressing = ''; dhcp = $null
    found_by = $by; login = ''; if_id = '1'; net_xml = ''; net_json = ''; dns_json = ''; platform_xml = ''; platform_json = ''; platform_enabled = $null; platform_online = $null; platform_has_code = $null
    channels = $null; channel_of = ''; channel_id = ''; activated = ''; poe = $false; onvif = $false; onvif_token = ''; snap_ip = ''; target_ip = '' }
  if ($d.vendor -eq 'Hikvision') { $d.brand = 'hik' } elseif ($d.vendor -eq 'Uniview') { $d.brand = 'unv' }
  $script:devs.Add($d); return $d
}
function Dev-ByMac([string]$mac) { $mac = NormMac $mac; if (-not $mac) { return $null }; return ($script:devs | Where-Object { $_.mac -eq $mac } | Select-Object -First 1) }
function Dev-ByIp([string]$ip) { return ($script:devs | Where-Object { $_.ip -eq $ip } | Select-Object -First 1) }
function Merge-Dev($src) {
  $d = Dev-ByMac $src.mac; if (-not $d) { $d = Dev-ByIp $src.ip }
  if (-not $d) { $d = New-Dev $src.ip $src.mac $src.found_by }
  foreach ($k in 'ip','mask','gw','serial','model','firmware','brand','kind','activated') { if ($src.$k) { $d.$k = $src.$k } }
  if ($src.mac) { $d.mac = $src.mac }; if ($src.dhcp -ne $null) { $d.dhcp = $src.dhcp; $d.addressing = $(if ($src.dhcp) { 'dhcp' } else { 'static' }) }
  if ($d.found_by -notmatch [regex]::Escape($src.found_by)) { $d.found_by = ($d.found_by + ', ' + $src.found_by).Trim(', ') }
  return $d
}
function Is-Poe([string]$ip) { foreach ($p in $cfg.poe_internal_subnets) { if ((P3 $ip) -eq $p) { return $true } }; return $false }
function Is-Private([string]$ip) { return ($ip -match '^10\.' -or $ip -match '^192\.168\.' -or $ip -match '^172\.(1[6-9]|2[0-9]|3[01])\.') }
function Short($d) { $n = $(if ($d.kind -eq 'nvr') { 'NVR' } elseif ($d.channel_id) { 'Camera D' + $d.channel_id } elseif ($d.kind -eq 'camera') { 'Camera' } else { 'Device' }); return ($n + ' ' + $d.ip + $(if ($d.model) { ' (' + $d.model + ')' } else { '' })) }
function Read-Dev($d) {
  if ($d.login -eq 'ok' -or $d.login -like 'REFUSED*') { return }
  if ($d.brand -ne 'unv') { if (Hik-Read $d) { return } }
  if ($d.login -like 'REFUSED*') { return }
  if ($d.brand -ne 'hik') { if (Unv-Read $d) { [void](Onvif-Read $d); return } }
  if ($d.kind -ne 'nvr' -and -not $d.login) { [void](Onvif-Read $d) }
}
function Wait-Answer([string]$ip, [int]$seconds, $cred) {
  $end = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $end) {
    $r = Http $ip 'GET' '/ISAPI/System/deviceInfo' '' 'application/xml' $cred 5
    if ($r.code -eq 200) { return $true }
    $r = Http $ip 'GET' '/LAPI/V1.0/System/DeviceBasicInfo' '' 'application/json' $cred 5
    if ($r.code -eq 200) { return $true }
    Start-Sleep -Seconds 5
  }
  return $false
}

# ---------------- router DHCP range (WireIt standard: router hands out .100 and up) ----------------
function Router-Step([string]$gw, [int]$prefix) {
  $p3 = P3 $gw; $lines = @()
  switch -regex ($gw) {
    '^10\.0\.0\.1$'       { $lines += ('Xfinity home router (10.0.0.1): in the Xfinity app turn on WiFi > View WiFi equipment > Advanced settings > Admin Tool online access. Then open http://10.0.0.1 > Gateway > Connection > Local IP Network and set the DHCP range to 10.0.0.100 - 10.0.0.253. Save.') }
    '^10\.1\.10\.1$'      { $lines += ('Comcast Business router (10.1.10.1): open http://10.1.10.1 (user cusadmin, password on the sticker) > DHCP settings: change the start address from 10.1.10.10 to 10.1.10.100 (end 10.1.10.199 or higher). Save.') }
    '^192\.168\.4\.1$'    { $lines += ('eero (192.168.4.1): eero app only: Settings > Network settings > DHCP & NAT > Manual IP. Set mask 255.255.255.0 and the range to start at 192.168.4.100. eero defaults to a /22 mask: check it.') }
    '^192\.168\.68\.1$'   { $lines += ('TP-Link Deco (192.168.68.1): Deco app > More > Advanced > DHCP Server: set the range to start at 192.168.68.100. Deco defaults to a /22 mask: check it.') }
    '^192\.168\.86\.1$'   { $lines += ('Google Nest Wifi (192.168.86.1): Google Home app > Wi-Fi > Settings > Advanced networking > DHCP IP range: set it to 192.168.86.100 - 192.168.86.250.') }
    '^192\.168\.(1|254)\.254$' { $lines += ('Frontier / AT&T-style router (' + $gw + '): open http://' + $gw + ' (device access code on the sticker) > Home Network > Subnets & DHCP: set the DHCP range to ' + $p3 + '.100 - ' + $p3 + '.253. Save.') }
    default               { $lines += ('Router ' + $gw + ': open http://' + $gw + ' (login on the router sticker) > LAN / DHCP settings: set the DHCP range to ' + $p3 + '.100 - ' + $p3 + '.254. Save.') }
  }
  if ($prefix -ne 24) { $lines += ('The router uses a /' + $prefix + ' mask (' + (PrefixToMask $prefix) + '), not 255.255.255.0. eero and TP-Link Deco do this by default. The NVR and cameras must use the same mask as the router.') }
  $lines += 'Menu names can differ by model. If you cannot get into the router, reserve the NVR''s address in the router/app instead and type "reserved" when NVR Snapshot asks for the DHCP range.'
  return $lines
}
function Show-RouterStep([string]$why) {
  Say ''; Say ('ROUTER STEP NEEDED: ' + $why) 'Yellow'
  Say ('  WireIt standard: router hands out .' + [int]$cfg.router_dhcp_start + ' and up; ours are below it (NVR .' + ([int]@($cfg.nvr_hosts)[0]) + ', switch cameras .' + [int]$cfg.camera_block_start + '-.' + [int]$cfg.camera_block_end + ', other WireIt gear .10-.19).') 'Yellow'
  foreach ($l in (Router-Step $pc.gw $pc.prefix)) { Say ('  - ' + $l) 'Yellow' }
}
function Range-Start([string]$r) {
  # "100-254", ".100-.254", "10.0.0.100 - 10.0.0.253" -> 100 ; nothing usable -> -1
  if (-not $r) { return -1 }
  $m = [regex]::Match($r, '(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})'); if ($m.Success) { return [int]$m.Groups[4].Value }
  $m = [regex]::Match($r, '(\d{1,3})'); if ($m.Success) { return [int]$m.Groups[1].Value }
  return -1
}

# ---------------- snapshot files ----------------
function Find-SiteFolder([string]$site) {
  if (-not $site) { return $null }
  foreach ($root in $cfg.snapshot_roots) {
    $r = [Environment]::ExpandEnvironmentVariables($root)
    if (-not (Test-Path $r)) { continue }
    $f = Get-ChildItem $r -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $site } | Select-Object -First 1
    if (-not $f) { $f = Get-ChildItem $r -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ('*' + $site + '*') } | Select-Object -First 1 }
    if ($f) { return $f.FullName }
  }
  return $null
}
function Load-Snapshot {
  $p = $Snapshot
  if (-not $p -and $Site) {
    $folders = @(); $sf = Find-SiteFolder $Site; if ($sf) { $folders += (Join-Path $sf $cfg.snapshot_subfolder); $folders += $sf }
    $folders += (Join-Path $here 'snapshots')
    foreach ($f in $folders) { $c = Get-ChildItem $f -Filter 'FixNVR snapshot*.json' -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ('*' + $Site + '*') -or $f -ne (Join-Path $here 'snapshots') } | Sort-Object Name -Descending | Select-Object -First 1; if ($c) { $p = $c.FullName; break } }
  }
  if (-not $p -or -not (Test-Path $p)) { return $null }
  Say ('Using known-good snapshot: ' + $p)
  return (Get-Content $p -Raw | ConvertFrom-Json)
}

# =====================================================================================
#  MAIN
# =====================================================================================
Write-Host ''
Write-Host ('=== WireIt Fix NVR ' + $Version + ' | mode ' + $Mode + ' | ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') + ' on ' + $env:COMPUTERNAME + ' ===') -ForegroundColor Cyan
Log ('start mode=' + $Mode + ' site=' + $Site + ' ps=' + $PSVersionTable.PSVersion)
Invoke-LeftoverCleanup
if ($Mode -eq 'Cleanup') { Write-Host 'Cleanup done.'; exit 0 }
if (-not $Mock) {
  $adm = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $adm) { Say 'Please run as administrator (right-click "Fix NVR.cmd" > Run as administrator). The tool needs it to reach devices on the old IP scheme.' 'Red'; exit 2 }
}
$pc = Get-PcNet; $script:pcNet = $pc
if (-not $pc -or -not $pc.ip -or -not $pc.gw) { Say 'This PC has no working network connection with a router. Plug it into the site network and run again.' 'Red'; exit 2 }
$newP3 = P3 $pc.gw; $newMask = PrefixToMask $pc.prefix
Say ('This PC: ' + $pc.ip + '/' + $pc.prefix + ' on "' + $pc.alias + '", router (gateway) ' + $pc.gw + $(if ($pc.wifi) { '  [Wi-Fi: works, a cable is better]' } else { '' }))
Say ('Current IP scheme: ' + $newP3 + '.x  (mask ' + $newMask + ')')
$rb = $null; if ($Mode -eq 'Rollback') { if (-not $RollbackFile -or -not (Test-Path $RollbackFile)) { Say 'Rollback needs -RollbackFile <path to rollback.json from the Fix run>.' 'Red'; exit 2 }; $rb = Get-Content $RollbackFile -Raw | ConvertFrom-Json }
$snap = $null; if ($Mode -ne 'Rollback') { $snap = Load-Snapshot }
$script:routerStepShown = $false
if ($Mode -ne 'Rollback') {
  if ($snap -and ($snap.router_model -or $snap.router_dhcp_range)) { Say ('At install (snapshot ' + $snap.taken + '): router ' + $(if ($snap.router_model) { $snap.router_model } else { '?' }) + ' at ' + $snap.router + ', DHCP range ' + $(if ($snap.router_dhcp_range) { $snap.router_dhcp_range } else { 'not recorded' })) }
  $lowLease = ($pc.dhcp -and (((P3 $pc.ip) -eq $newP3 -and (Last $pc.ip) -lt [int]$cfg.router_dhcp_start) -or ($pc.prefix -lt 24 -and (P3 $pc.ip) -ne $newP3)))
  if ($lowLease) { Show-RouterStep ('this PC got ' + $pc.ip + ' from the router, so the router still hands out addresses below .' + [int]$cfg.router_dhcp_start + '. One day it could give the NVR''s or a camera''s address to a phone (double IP).'); $script:routerStepShown = $true }
  elseif ($snap -and $snap.router -and $snap.router -ne $pc.gw) { Show-RouterStep ('the router changed since install (was ' + $snap.router + ', now ' + $pc.gw + '). A new router starts with its factory DHCP range.'); $script:routerStepShown = $true }
  elseif ($pc.prefix -ne 24) { Say ('Note: the router uses a /' + $pc.prefix + ' mask (' + $newMask + '). eero and TP-Link Deco do this by default; the NVR and cameras will get the same mask.') 'Yellow' }
}
$plan = New-Object System.Collections.Generic.List[object]
$applied = New-Object System.Collections.Generic.List[object]
$script:exitCode = 0
function Invoke-CamViews($list) {
  # last known view of each camera (Toolkit CamViews.ps1, read-only). Never fails the run.
  $site0 = $Site; $mock0 = $Mock
  $cv = Join-Path (Split-Path -Parent $here) 'Toolkit\CamViews.ps1'
  if ($mock0) { if (-not $mock0.camviews) { return }; $cv = [string]$mock0.camviews }
  if (-not (Test-Path $cv)) { Say ''; Say 'Camera pictures: skipped (the Toolkit''s CamViews.ps1 is not on this PC).' 'Yellow'; return }
  if (-not $site0) { Say ''; Say 'Camera pictures: skipped - no site given (type the Site ID, e.g. WI-061, in the Toolkit''s Site box).' 'Yellow'; return }
  $ok = @($list | Where-Object { $_.login -eq 'ok' -and $_.brand -in @('hik', 'unv') })
  if (-not $ok.Count) { Say ''; Say 'Camera pictures: skipped - no NVR login.' 'Yellow'; return }
  try {
    . $cv -Lib
    if ($mock0) { $script:CvApi = $mock0.url + '/api'; $script:CvMock = $mock0.url }
    $i = 0
    foreach ($n in $ok) { $i++; [void](Save-CameraViews -Nvr $n.ip -Cred $script:credNvr -Site $site0 -Vendor $(if ($n.brand -eq 'unv') { 'uniview' } else { 'hik' }) -RecorderNo $i) }
  } catch { Say ('Camera pictures: did not work (' + $_.Exception.Message + '). Nothing else is affected.') 'Yellow'; Log $_.ScriptStackTrace }
}
function Invoke-Main {
  Open-Firewall
  # ---------- 1. find devices on ANY scheme ----------
  Say ''; Say 'Looking for the NVR and cameras (any IP scheme)...' 'Cyan'
  $sadp = Find-Sadp @($pc.ip)
  foreach ($k in $sadp.Keys) { [void](Merge-Dev $sadp[$k]) }
  $sn = $SniffSeconds; if ($sn -lt 0) { $sn = [int]$cfg.arp_sniff_seconds }
  if ($Mode -eq 'Rollback') { $sn = 0 }
  if ($sn -gt 0) { Write-Host ('  listening ' + $sn + ' s for devices stuck on another scheme...') }
  $arp = Find-ArpSniff $sn
  foreach ($k in $arp.Keys) { $ip = $arp[$k]; if (-not (InNet $ip $pc.ip $pc.prefix) -and (Is-Private $ip)) { $d = Dev-ByMac $k; if (-not $d) { [void](New-Dev $ip $k 'passive listen') } } }
  if ($snap) {
    foreach ($s in @($snap.nvrs) + @($snap.cameras)) { if (-not $s) { continue }; $d = Dev-ByMac $s.mac; if (-not $d) { $d = New-Dev $s.ip $s.mac 'snapshot' }; $d.snap_ip = $s.ip; if (-not $d.kind) { $d.kind = $(if (@($snap.nvrs) -contains $s) { 'nvr' } else { 'camera' }) }; if (-not $d.brand -and $s.brand) { $d.brand = $s.brand }; if ($s.channel) { $d.channel_id = [string]$s.channel } }
  }
  if ($rb) { foreach ($st in @($rb.steps)) { if ($st.done -and $st.dev_mac) { $d = Dev-ByMac $st.dev_mac; if (-not $d) { $d = New-Dev $st.new_ip $st.dev_mac 'rollback file' }; $d.kind = $st.kind; $d.brand = $st.brand } } }
  if ($Nvr) { $d = Dev-ByIp $Nvr; if (-not $d) { $d = New-Dev $Nvr '' 'given' }; $d.kind = 'nvr' }
  # ---------- 2. old schemes -> temporary PC address ----------
  $old = [ordered]@{}
  foreach ($o in $OldSubnet) { $o = ($o -replace '/\d+$', ''); if (($o -split '\.').Count -eq 4) { $o = P3 $o }; $old[$o] = 99 }
  foreach ($d in $script:devs) { if ($d.ip -and -not (InNet $d.ip $pc.ip $pc.prefix) -and (Is-Private $d.ip) -and -not (Is-Poe $d.ip)) { $p = P3 $d.ip; if ($old.Contains($p)) { $old[$p]++ } else { $old[$p] = 1 } } }
  if ($rb) { foreach ($o in @($rb.old_subnets)) { if (-not $old.Contains($o)) { $old[$o] = 50 } } }
  $old.Remove($newP3)
  $oldList = @($old.Keys | Sort-Object { -$old[$_] } | Select-Object -First ([int]$cfg.max_old_subnets))
  $avoid = @($script:devs | ForEach-Object { $_.ip })
  $tempIps = @()
  foreach ($o in $oldList) {
    $t = Add-TempIp $o $pc $avoid
    if ($t) { $tempIps += $t; Say ('Old scheme ' + $o + '.x found. This PC temporarily also answers on ' + $t + ' to reach it (removed at the end).') }
    else { Say ('Old scheme ' + $o + '.x found, but no free temporary address worked. Devices there can only be listed.') 'Yellow' }
  }
  if ($tempIps.Count) { $s2 = Find-Sadp $tempIps; foreach ($k in $s2.Keys) { [void](Merge-Dev $s2[$k]) } }
  $onv = Find-Onvif (@($pc.ip) + $tempIps)
  foreach ($ip in $onv.Keys) { $d = Dev-ByIp $ip; if (-not $d) { $d = New-Dev $ip '' 'ONVIF search' }; if ($onv[$ip] -match '(?i)uniview|unv') { if (-not $d.brand) { $d.brand = 'unv' } }; if ($onv[$ip] -match '(?i)NVR|recorder') { $d.kind = 'nvr' } }
  # a device with an unknown role on an old scheme that answers like a recorder is checked below
  $nvrs = @($script:devs | Where-Object { $_.kind -eq 'nvr' })
  if (-not $nvrs.Count) {
    $cand = @($script:devs | Where-Object { $_.brand -or $_.found_by -match 'listen' })
    if ($cand.Count) { Say 'No device identified itself as an NVR yet; checking the candidates after login.' 'Yellow' }
  }
  Say ('Found ' + $script:devs.Count + ' device(s): ' + (($script:devs.ToArray() | ForEach-Object { $_.ip + $(if ($_.kind) { ' ' + $_.kind } else { '' }) + $(if (-not (InNet $_.ip $pc.ip $pc.prefix)) { ' [OLD SCHEME]' } else { '' }) }) -join ', '))
  if (-not $script:devs.Count) { Say 'Nothing found. Is this PC on the same network/switch as the NVR? (Wi-Fi guest networks and some mesh systems hide devices.)' 'Red'; $script:exitCode = 3; return }
  if ($NoLogin) {
    Say ''; Say '----- Devices (discovery only, no logins) -----' 'Cyan'
    foreach ($d in $script:devs.ToArray()) { Say ('  ' + $d.ip + ' | ' + $(if ($d.mac) { $d.mac } else { '?' }) + ' | ' + $(if ($d.vendor) { $d.vendor } elseif ($d.brand) { $d.brand } else { '?' }) + ' | ' + $d.kind + ' ' + $d.model + ' ' + $d.serial + ' | found by ' + $d.found_by + $(if (-not (InNet $d.ip $pc.ip $pc.prefix)) { ' | OLD/OTHER SCHEME' } else { '' })) }
    return
  }
  # ---------- 3. log in and read (read-only) ----------
  Get-Creds
  Say ''; Say 'Reading settings (read-only)...' 'Cyan'
  if (-not $nvrs.Count) { foreach ($d in @($script:devs | Where-Object { -not $_.kind })) { Read-Dev $d } ; $nvrs = @($script:devs | Where-Object { $_.kind -eq 'nvr' }) }
  foreach ($n in $nvrs) { Read-Dev $n }
  foreach ($n in $nvrs) {
    if (-not $n.channels) { continue }
    foreach ($ch in $n.channels) {
      if (-not $ch.ip) { continue }
      if (Is-Poe $ch.ip) { $ch.poe = $true; continue }
      $d = Dev-ByIp $ch.ip
      if (-not $d -and $snap) { $s = @($snap.cameras) | Where-Object { $_.channel -eq $ch.id -and $_.ip -eq $ch.ip } | Select-Object -First 1; if ($s) { $d = Dev-ByMac $s.mac } }
      if (-not $d) { $d = New-Dev $ch.ip '' 'NVR camera list'; $d.kind = 'camera' }
      $d.channel_of = $n.ip; $d.channel_id = $ch.id; if (-not $d.kind) { $d.kind = 'camera' }
    }
  }
  foreach ($d in @($script:devs | Where-Object { $_.kind -ne 'nvr' -and ($_.channel_of -or $_.snap_ip -or $Mode -eq 'Snapshot' -or ($MoveUnlisted -and -not (InNet $_.ip $pc.ip $pc.prefix))) -and -not (Is-Poe $_.ip) })) { Read-Dev $d }

  # ---------- 4. report what is wrong ----------
  Say ''; Say '----- What I found -----' 'Cyan'
  foreach ($n in $nvrs) {
    Say ((Short $n) + ' | login ' + $n.login + ' | ' + $(if ($n.addressing) { $n.addressing } else { '?' }) + ' | gateway ' + $n.gw + ' | DNS ' + $n.dns1 + ' ' + $n.dns2)
    if ((InNet $n.ip $pc.ip $pc.prefix) -and (Last $n.ip) -ge [int]$cfg.router_dhcp_start) { Say ('  NOTE: the NVR is at .' + (Last $n.ip) + ', inside the usual router range (.' + [int]$cfg.router_dhcp_start + ' and up). The standard is now .' + ([int]@($cfg.nvr_hosts)[0]) + '. Fix leaves it where it is unless it is on the wrong scheme; move it by hand when convenient, or reserve it in the router.') 'Yellow' }
    if (-not (InNet $n.ip $pc.ip $pc.prefix)) { Say ('  PROBLEM: the NVR is on the OLD scheme (' + (P3 $n.ip) + '.x). The router is now ' + $pc.gw + '.') 'Yellow' }
    elseif ($n.gw -and $n.gw -ne $pc.gw) { Say ('  PROBLEM: NVR gateway is ' + $n.gw + ', router is ' + $pc.gw + '.') 'Yellow' }
    if ($n.login -eq 'ok' -and (-not $n.dns1 -or $n.dns1 -eq '0.0.0.0')) { Say '  PROBLEM: NVR has no DNS server (the app cannot find the cloud).' 'Yellow' }
    if ($n.platform_enabled -eq $false) { Say '  PROBLEM: platform access (Hik-Connect / EZCloud) is turned OFF.' 'Yellow' }
    elseif ($n.platform_enabled -and $n.platform_online -eq $false) { Say '  Platform access is on but shows OFFLINE right now.' 'Yellow' }
    elseif ($n.platform_online) { Say '  Platform access: on and ONLINE.' 'Green' }
    if ($n.channels) { $on = @($n.channels | Where-Object { $_.online }).Count; $poe = @($n.channels | Where-Object { $_.poe }).Count; Say ('  Cameras on the NVR: ' + $n.channels.Count + ' (' + $on + ' online; ' + $poe + ' on the NVR''s own PoE ports, left alone)') }
  }
  if (-not $nvrs.Count) { Say 'No NVR found or identified. Give its address with -Nvr if you know it.' 'Yellow' }
  $wrongCams = @($script:devs | Where-Object { $_.kind -eq 'camera' -and $_.channel_of -and -not (InNet $_.ip $pc.ip $pc.prefix) -and -not (Is-Poe $_.ip) })
  if ($wrongCams.Count) { Say ('  PROBLEM: ' + $wrongCams.Count + ' switch camera(s) on the OLD scheme: ' + (($wrongCams | ForEach-Object { 'D' + $_.channel_id + ' ' + $_.ip }) -join ', ')) 'Yellow' }
  $inact = @($script:devs | Where-Object { $_.activated -eq 'false' })
  if ($inact.Count) { Say ('  Not activated (factory reset, no password yet): ' + (($inact | ForEach-Object { $_.ip }) -join ', ') + '. Activate it in HiTools/SADP first.') 'Yellow' }
  $loose = @($script:devs | Where-Object { $_.kind -ne 'nvr' -and -not $_.channel_of -and -not (InNet $_.ip $pc.ip $pc.prefix) })
  if ($loose.Count) { Say ('  Also on an old scheme but NOT on the NVR''s camera list' + $(if ($MoveUnlisted) { ' (will be moved: -MoveUnlisted)' } else { ' (left alone; add -MoveUnlisted to move them)' }) + ': ' + (($loose | ForEach-Object { $_.ip + $(if ($_.vendor) { ' ' + $_.vendor } else { '' }) }) -join ', ')) }
  $ref = @($script:devs | Where-Object { $_.login -like 'REFUSED*' }); if ($ref.Count) { Say ('  Login refused (not retried, so nothing gets locked): ' + (($ref | ForEach-Object { $_.ip }) -join ', ')) 'Yellow' }

  # ---------- PICTURES mode: last known view of each camera (read-only) ----------
  if ($Mode -eq 'Pictures') { Invoke-CamViews $nvrs; return }
  # ---------- SNAPSHOT mode: record known-good + install standard check ----------
  if ($Mode -eq 'Snapshot') {
    $chk = New-Object System.Collections.Generic.List[string]
    function Chk([bool]$ok, [string]$what) { $chk.Add($(if ($ok) { 'PASS ' } else { 'FIX  ' }) + $what); Say ($(if ($ok) { '  PASS  ' } else { '  FIX   ' }) + $what) $(if ($ok) { 'Green' } else { 'Yellow' }) }
    Say ''; Say '----- NVR install standard -----' 'Cyan'
    foreach ($n in $nvrs) {
      Chk ($n.addressing -eq 'static') ('NVR ' + $n.ip + ' uses a static address')
      Chk ((Last $n.ip) -ge 10 -and (Last $n.ip) -lt [int]$cfg.router_dhcp_start) ('NVR address .' + (Last $n.ip) + ' is in the WireIt block (.10-.99), below the router''s range (.' + [int]$cfg.router_dhcp_start + ' and up). Standard: .' + ([int]@($cfg.nvr_hosts)[0]))
      Chk ($n.gw -eq $pc.gw) ('NVR gateway = router ' + $pc.gw)
      Chk ($n.dns1 -eq $cfg.dns1 -and $n.dns2 -eq $cfg.dns2) ('NVR DNS = ' + $cfg.dns1 + ' / ' + $cfg.dns2 + ' (now ' + $n.dns1 + ' / ' + $n.dns2 + ')')
      Chk ($n.platform_enabled -eq $true) 'Platform access (Hik-Connect / EZCloud) is ON'
      Chk ($n.platform_online -eq $true) 'Platform shows ONLINE'
      if ($n.channels) { $off = @($n.channels | Where-Object { -not $_.online }); Chk ($off.Count -eq 0) ('All ' + $n.channels.Count + ' cameras online' + $(if ($off.Count) { ' (offline: ' + (($off | ForEach-Object { 'D' + $_.id }) -join ' ') + ')' } else { '' })) }
    }
    foreach ($c in @($script:devs | Where-Object { $_.kind -eq 'camera' -and $_.channel_of })) {
      Chk ($c.addressing -ne 'dhcp' -and (Last $c.ip) -ge [int]$cfg.camera_block_start -and (Last $c.ip) -le [int]$cfg.camera_block_end) ('Switch camera D' + $c.channel_id + ' ' + $c.ip + ' static, in the camera block .' + [int]$cfg.camera_block_start + '-.' + [int]$cfg.camera_block_end)
    }
    # router DHCP range: typed by the tech (router model + range are optional), plus what this PC's own lease shows
    $rs = Range-Start $DhcpRange; $reserved = ($DhcpRange -match '(?i)reserv')
    if ($reserved) { Chk $true ('Router range not changed; NVR address reserved in the router (typed: ' + $DhcpRange + ')') }
    elseif ($rs -ge 0) { Chk ($rs -ge [int]$cfg.router_dhcp_start) ('Router DHCP range starts at .' + [int]$cfg.router_dhcp_start + ' or higher (typed: ' + $DhcpRange + ')') }
    else { Say '  NOTE  Router DHCP range not typed (optional). Type it when NVR Snapshot asks, so Fix NVR knows it later.' 'Yellow' }
    if ($pc.dhcp -and (P3 $pc.ip) -eq $newP3) { Chk ((Last $pc.ip) -ge [int]$cfg.router_dhcp_start -or $reserved) ('This PC got .' + (Last $pc.ip) + ' from the router (.' + [int]$cfg.router_dhcp_start + ' or higher means the range was changed)') }
    if (($rs -ge 0 -and $rs -lt [int]$cfg.router_dhcp_start -and -not $reserved) -or ($chk | Where-Object { $_ -like 'FIX  This PC got*' })) { if (-not $script:routerStepShown) { Show-RouterStep 'the router still hands out addresses in the WireIt block.'; $script:routerStepShown = $true } }
    $snapObj = [ordered]@{ tool = 'WireIt FixNVR ' + $Version; site = $Site; taken = (Get-Date -Format 's'); taken_on = $env:COMPUTERNAME; router = $pc.gw; scheme = $newP3; mask = $newMask
      router_model = $RouterModel; router_dhcp_range = $DhcpRange; nvr_address_reserved_in_router = [bool]$reserved; pc_lease = $(if ($pc.dhcp) { $pc.ip } else { '' })
      nvrs = @($nvrs | ForEach-Object { [ordered]@{ brand = $_.brand; model = $_.model; serial = $_.serial; mac = $_.mac; ip = $_.ip; mask = $_.mask; gw = $_.gw; dns1 = $_.dns1; dns2 = $_.dns2; addressing = $_.addressing; firmware = $_.firmware; platform_enabled = $_.platform_enabled; platform_online = $_.platform_online
        channels = @($_.channels | ForEach-Object { [ordered]@{ channel = $_.id; ip = $_.ip; port = $_.port; protocol = $_.protocol; poe_port = $_.poe; online = $_.online } }) } })
      cameras = @($script:devs | Where-Object { $_.kind -eq 'camera' -and ($_.channel_of -or $_.found_by -match 'SADP') } | ForEach-Object { [ordered]@{ channel = $_.channel_id; nvr = $_.channel_of; brand = $_.brand; model = $_.model; serial = $_.serial; mac = $_.mac; ip = $_.ip; mask = $_.mask; gw = $_.gw; addressing = $_.addressing; poe_port = $_.poe } })
      checklist = @($chk); note = 'No passwords are stored in this file.' }
    $name = 'FixNVR snapshot ' + $(if ($Site) { $Site + ' ' } else { '' }) + (Get-Date -Format 'yyyy-MM-dd HHmm') + '.json'
    $localDir = Join-Path $here 'snapshots'; New-Item -ItemType Directory -Force -Path $localDir | Out-Null
    Save-Json $snapObj (Join-Path $localDir $name); Say ''; Say ('Snapshot saved: ' + (Join-Path $localDir $name)) 'Green'
    $sf = Find-SiteFolder $Site
    if ($sf) { $dd = Join-Path $sf $cfg.snapshot_subfolder; New-Item -ItemType Directory -Force -Path $dd | Out-Null; Copy-Item (Join-Path $localDir $name) (Join-Path $dd $name); Say ('Also saved to the site''s Drive folder: ' + (Join-Path $dd $name)) 'Green' }
    elseif ($Site) { Say ('Site folder "' + $Site + '" not found in Google Drive on this PC. Copy the file above into the site''s Drive folder (Docs).') 'Yellow' }
    else { Say 'Tip: run with -Site "<site folder name>" to save it straight into the site''s Drive folder.' }
    Invoke-CamViews $nvrs
    return
  }

  # ---------- 5. build the plan ----------
  $taken = @{}; foreach ($d in $script:devs) { if ($d.ip) { $taken[$d.ip] = $true } }; $taken[$pc.gw] = $true; $taken[$pc.ip] = $true
  function Free-Target([string]$want, [int[]]$fallbackHosts) {
    $list = @(); if ($want) { $list += $want }; foreach ($h in $fallbackHosts) { $list += ($newP3 + '.' + $h) }
    foreach ($ip in $list) { if ($taken.ContainsKey($ip)) { continue }; if (Test-IpFree $ip) { $taken[$ip] = $true; return $ip } else { $taken[$ip] = $true } }
    return $null
  }
  $nvrHosts = @($cfg.nvr_hosts | ForEach-Object { [int]$_ })
  $cbS = [int]$cfg.camera_block_start; $cbE = [int]$cfg.camera_block_end; $chBase = [int]$cfg.camera_channel_base
  $blk = @(); for ($h = $cbS; $h -le $cbE; $h++) { if ($nvrHosts -notcontains $h) { $blk += $h } }
  $camMap = @{}   # old ip -> new ip
  if ($Mode -eq 'Rollback') {
    $tmp = @($rb.steps | Where-Object { $_.done -and $_.type -ne 'nvr-platform' }); for ($i = $tmp.Count - 1; $i -ge 0; $i--) { $plan.Add($tmp[$i]) }
  } else {
   foreach ($c in @($script:devs | Where-Object { ($_.kind -eq 'camera' -or ($MoveUnlisted -and $_.login -like 'ok*' -and $_.kind -ne 'nvr')) -and ($_.channel_of -or $MoveUnlisted) -and -not (Is-Poe $_.ip) })) {
    if (InNet $c.ip $pc.ip $pc.prefix) { continue }
    $want = ''
    if ($c.snap_ip) { $want = $newP3 + '.' + (Last $c.snap_ip) }
    elseif ($cfg.camera_ip_mode -match '^keep_last_octet' -and (Last $c.ip) -ge $cbS -and (Last $c.ip) -le $cbE -and $nvrHosts -notcontains (Last $c.ip)) { $want = $newP3 + '.' + (Last $c.ip) }
    elseif ($c.channel_id -match '^\d+$' -and ($chBase + [int]$c.channel_id) -ge $cbS -and ($chBase + [int]$c.channel_id) -le $cbE) { $want = $newP3 + '.' + ($chBase + [int]$c.channel_id) }
    $t = Free-Target $want $blk
    if (-not $t) { Say ('  No free address for camera ' + $c.ip + ' in the camera block. Skipped.') 'Yellow'; continue }
    $c.target_ip = $t; $camMap[$c.ip] = $t
    if ($c.login -eq 'ok' -and $c.brand -eq 'hik' -and $c.net_xml) { $how = 'isapi' } elseif ($c.onvif) { $how = 'onvif' } else { $how = 'manual' }
    $plan.Add([pscustomobject]@{ type = 'cam-net'; how = $how; kind = 'camera'; brand = $c.brand; dev_mac = $c.mac; channel = $c.channel_id; old_ip = $c.ip; new_ip = $t; old_mask = $c.mask; new_mask = $newMask; old_gw = $c.gw; new_gw = $pc.gw; old_dns1 = $c.dns1; old_dns2 = $c.dns2; old_addressing = $c.addressing; done = $false; result = '' })
   }
   foreach ($n in $nvrs) {
    if ($n.login -ne 'ok') { Say ('  Cannot change ' + (Short $n) + ' without a working login.') 'Yellow'; continue }
    if ($n.channels) {
      foreach ($ch in $n.channels) {
        if ($ch.poe -or -not $ch.ip) { continue }
        $newIp = $camMap[$ch.ip]
        if (-not $newIp -and -not $ch.online -and $snap) {
          $s = @($snap.cameras) | Where-Object { [string]$_.channel -eq [string]$ch.id } | Select-Object -First 1
          if ($s) { $d = Dev-ByMac $s.mac; if ($d -and $d.ip -ne $ch.ip -and (InNet $d.ip $pc.ip $pc.prefix)) { $newIp = $d.ip } }
        }
        if ($newIp -and $newIp -ne $ch.ip) {
          $how = $(if ($n.brand -eq 'hik') { 'isapi' } else { 'manual' })
          $plan.Add([pscustomobject]@{ type = 'nvr-channel'; how = $how; kind = 'nvr'; brand = $n.brand; dev_mac = $n.mac; nvr_ip = $n.ip; channel = $ch.id; old_ip = $ch.ip; new_ip = $newIp; done = $false; result = '' })
        }
      }
    }
    if ($n.platform_enabled -eq $false) { $how = $(if ($n.brand -eq 'hik') { 'isapi' } elseif ($AllowUnverifiedUniview -and $n.platform_json) { 'lapi' } else { 'manual' }); $plan.Add([pscustomobject]@{ type = 'nvr-platform'; how = $how; kind = 'nvr'; brand = $n.brand; dev_mac = $n.mac; nvr_ip = $n.ip; done = $false; result = '' }) }
    $wrong = -not (InNet $n.ip $pc.ip $pc.prefix)
    $target = $n.ip
    if ($wrong -or $n.addressing -eq 'dhcp') {
      $want = $(if ($n.snap_ip) { $newP3 + '.' + (Last $n.snap_ip) } else { '' })
      $target = Free-Target $want $nvrHosts
      if (-not $target) { Say ('  No free address for the NVR (' + (($nvrHosts | ForEach-Object { '.' + $_ }) -join '/') + ' all in use). Pick one below .' + [int]$cfg.router_dhcp_start + ' by hand with config.json nvr_hosts.') 'Yellow'; $target = $n.ip }
    }
    $needNet = ($target -ne $n.ip) -or ($n.mask -and $n.mask -ne $newMask) -or ($n.gw -ne $pc.gw) -or ($n.dns1 -ne $cfg.dns1) -or ($n.dns2 -ne $cfg.dns2) -or ($n.addressing -eq 'dhcp')
    if ($needNet) {
      $how = $(if ($n.brand -eq 'hik' -and $n.net_xml) { 'isapi' } elseif ($n.brand -eq 'unv' -and $AllowUnverifiedUniview -and $n.net_json) { 'lapi' } else { 'manual' })
      $plan.Add([pscustomobject]@{ type = 'nvr-net'; how = $how; kind = 'nvr'; brand = $n.brand; dev_mac = $n.mac; old_ip = $n.ip; new_ip = $target; old_mask = $n.mask; new_mask = $newMask; old_gw = $n.gw; new_gw = $pc.gw; old_dns1 = $n.dns1; old_dns2 = $n.dns2; new_dns1 = $cfg.dns1; new_dns2 = $cfg.dns2; old_addressing = $n.addressing; done = $false; result = '' })
    }
   }
  }

  # ---------- 6. preview ----------
  $rev = ($Mode -eq 'Rollback')
  Say ''; Say $(if ($rev) { '----- Rollback plan (puts things back as the Fix run found them) -----' } else { '----- Plan (nothing has been changed yet) -----' }) 'Cyan'
  if (-not $plan.Count) { Say 'Nothing to change. Everything the tool can check looks right.' 'Green'; if ($Mode -ne 'Rollback') { $script:exitCode = 0 }; return }
  $i = 0
  foreach ($st in $plan) {
    $i++; $from = $(if ($rev) { $st.new_ip } else { $st.old_ip }); $to = $(if ($rev) { $st.old_ip } else { $st.new_ip })
    $tag = $(if ($st.how -eq 'manual') { '  [BY HAND - see below]' } else { '' })
    switch ($st.type) {
      'cam-net'      { Say ('' + $i + '. Camera ' + $(if ($st.channel) { 'D' + $st.channel } else { '(not on an NVR list)' }) + ': ' + $from + ' -> ' + $to + $(if (-not $rev) { ', gateway ' + $st.new_gw + ', DNS ' + $cfg.dns1 + '/' + $cfg.dns2 + ', static' } else { '' }) + $tag) }
      'nvr-channel'  { Say ('' + $i + '. NVR camera list, channel D' + $st.channel + ': ' + $from + ' -> ' + $to + $tag) }
      'nvr-platform' { Say ('' + $i + '. NVR: turn ON platform access (' + $(if ($st.brand -eq 'unv') { 'EZCloud' } else { 'Hik-Connect' }) + ')' + $tag) }
      'nvr-net'      { Say ('' + $i + '. NVR: ' + $from + ' -> ' + $to + ' static' + $(if (-not $rev) { ', mask ' + $st.new_mask + ', gateway ' + $st.new_gw + ', DNS ' + $st.new_dns1 + ' / ' + $st.new_dns2 } else { ', gateway ' + $st.old_gw + ', DNS ' + $st.old_dns1 + ' ' + $st.old_dns2 }) + $tag + '  (the NVR may restart: about 2 min)') }
    }
  }
  $movesScheme = @($plan | Where-Object { $_.type -eq 'nvr-net' -and (P3 $_.old_ip) -ne $newP3 }).Count
  if (-not $rev -and $movesScheme -and -not $script:routerStepShown -and -not $pc.dhcp) { Show-RouterStep ('this PC has a fixed address, so the tool cannot see the router''s range. The NVR is moving onto this router''s scheme; make sure the router hands out .' + [int]$cfg.router_dhcp_start + ' and up.'); $script:routerStepShown = $true }
  elseif (-not $rev -and $script:routerStepShown) { Say ''; Say ('Remember the ROUTER STEP above (router hands out .' + [int]$cfg.router_dhcp_start + ' and up). Do it today, before or right after the fix.') 'Yellow' }
  $manual = @($plan | Where-Object { $_.how -eq 'manual' })
  if ($manual.Count) { Say ''; Say ('' + $manual.Count + ' step(s) must be done by hand (Uniview NVR settings are not yet verified for automatic change, or no login). Steps are printed after the automatic part.') 'Yellow' }
  $plan | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $runDir 'plan.json')
  $before = @($script:devs | ForEach-Object { [ordered]@{ ip = $_.ip; mac = $_.mac; kind = $_.kind; brand = $_.brand; model = $_.model; serial = $_.serial; mask = $_.mask; gw = $_.gw; dns1 = $_.dns1; dns2 = $_.dns2; addressing = $_.addressing; platform_enabled = $_.platform_enabled; platform_online = $_.platform_online; channel = $_.channel_id; found_by = $_.found_by; login = $_.login } })
  Save-Json $before (Join-Path $runDir 'before.json')
  if ($Mode -eq 'Check') { Say ''; Say 'Check only: nothing was changed. Run "Fix NVR.cmd" (Fix mode) to apply this plan.' 'Cyan'; return }

  # ---------- 7. ONE confirm ----------
  Say ''
  $ans = $(if ($ConfirmWith) { $ConfirmWith } else { Read-Host 'Type YES to make these changes (anything else cancels)' })
  Log ('confirm answer: ' + $ans)
  if ($ans -cne 'YES') { Say 'Cancelled. Nothing was changed.' 'Yellow'; return }
  $rbPath = Join-Path $runDir 'rollback.json'
  $rbObj = [ordered]@{ tool = 'WireIt FixNVR ' + $Version; created = (Get-Date -Format 's'); site = $Site; pc = $pc.ip; router = $pc.gw; old_subnets = @($oldList); steps = $plan }
  if (-not $rev) { Save-Json $rbObj $rbPath; Say ('Rollback info saved first: ' + $rbPath) }

  # ---------- 8. apply ----------
  $pfx = $pc.prefix
  foreach ($st in $plan) {
    if ($st.how -eq 'manual') { continue }
    $from = $(if ($rev) { $st.new_ip } else { $st.old_ip }); $to = $(if ($rev) { $st.old_ip } else { $st.new_ip })
    $res = $null
    switch ($st.type) {
      'cam-net' {
        $d = Dev-ByMac $st.dev_mac; if (-not $d) { $d = Dev-ByIp $from }; if (-not $d) { $d = New-Dev $from $st.dev_mac 'rollback' }
        $d.ip = $from; $d.kind = 'camera'; if (-not $d.brand) { $d.brand = $st.brand }
        if ($rev -or -not $d.login) { $d.login = ''; $d.net_xml = ''; Read-Dev $d }
        $mask = $(if ($rev -and $st.old_mask) { $st.old_mask } else { $newMask }); $gw = $(if ($rev) { $st.old_gw } else { $pc.gw })
        $d1 = $(if ($rev) { $st.old_dns1 } else { $cfg.dns1 }); $d2 = $(if ($rev) { $st.old_dns2 } else { $cfg.dns2 })
        Write-Host ('Moving camera ' + $st.channel + ' ' + $from + ' -> ' + $to + ' ...')
        if ($d.brand -eq 'hik' -and $d.net_xml) {
          $res = Hik-SetNet $d $to $mask $gw $d1 $d2
          if ($res.ok -and $res.reboot) { [void](Hik-RebootNow $d) }
        } elseif ($d.onvif -or (Onvif-Read $d)) { $res = Onvif-SetNet $d $to (MaskToPrefix $mask) $gw $d1 $d2 }
        else { $res = @{ ok = $false; note = 'could not log in to the camera' } }
        if ($res.ok) { $ans2 = Wait-Answer $to ([int]$cfg.camera_wait_seconds) $script:credCam; if (-not $ans2) { $res.ok = $false; $res.note = ($res.note + ' camera did not answer on ' + $to).Trim() } }
        if ($res.ok) { $d.ip = $to }
      }
      'nvr-channel' {
        $n = Dev-ByMac $st.dev_mac; if (-not $n) { $n = $nvrs | Select-Object -First 1 }
        Write-Host ('NVR camera list D' + $st.channel + ' -> ' + $to + ' ...')
        if (-not $n.login -or $n.login -ne 'ok') { Read-Dev $n }
        $res = Hik-SetChannel $n $st.channel $to
      }
      'nvr-platform' {
        $n = Dev-ByMac $st.dev_mac
        Write-Host 'Turning platform access on ...'
        if ($st.how -eq 'isapi') { $res = Hik-EnablePlatform $n } else { $res = Unv-Put $n $cfg.uniview.cloud_path (Unv-PlanCloud $n) }
        if (-not $res.ok -and $n.platform_has_code -eq $false) { $res.note = ($res.note + ' (the NVR may need a Hik-Connect verification code set in its web page first)').Trim() }
      }
      'nvr-net' {
        $n = Dev-ByMac $st.dev_mac; if (-not $n) { $n = Dev-ByIp $from }; if (-not $n) { $n = New-Dev $from $st.dev_mac 'rollback'; $n.kind = 'nvr'; $n.brand = $st.brand }
        $n.ip = $from; if ($rev -or -not $n.net_xml -and -not $n.net_json) { $n.login = ''; Read-Dev $n }
        $mask = $(if ($rev -and $st.old_mask) { $st.old_mask } else { $newMask }); $gw = $(if ($rev) { $st.old_gw } else { $pc.gw })
        $d1 = $(if ($rev) { $st.old_dns1 } else { $cfg.dns1 }); $d2 = $(if ($rev) { $st.old_dns2 } else { $cfg.dns2 })
        Write-Host ('Moving the NVR ' + $from + ' -> ' + $to + ' (DNS ' + $d1 + ' / ' + $d2 + ') ...')
        if ($st.how -eq 'isapi') { $res = Hik-SetNet $n $to $mask $gw $d1 $d2; if ($res.ok -and $res.reboot) { Write-Host '  NVR asked for a restart; restarting it now (about 2 min).'; [void](Hik-RebootNow $n) } }
        else { $r1 = Unv-Put $n $cfg.uniview.dns_path (Unv-PlanDns $n $d1 $d2); $r2 = Unv-Put $n $cfg.uniview.net_path (Unv-PlanNet $n $to $mask $gw); $res = @{ ok = ($r1.ok -and $r2.ok); note = ($r1.note + ' ' + $r2.note).Trim() } }
        if ($res.ok) { Write-Host ('  waiting for the NVR on ' + $to + ' ...'); if (Wait-Answer $to ([int]$cfg.verify_wait_seconds) $script:credNvr) { $n.ip = $to } else { $res.ok = $false; $res.note = ($res.note + ' NVR did not answer on ' + $to + ' yet').Trim() } }
      }
    }
    if ($res) { $st.done = [bool]$res.ok; $st.result = $(if ($res.ok) { 'done' } else { 'FAILED ' + $res.note }) }
    $applied.Add($st)
    Say ('  ' + $st.type + ' ' + $from + ' -> ' + $to + ': ' + $st.result) $(if ($st.done) { 'Green' } else { 'Red' })
    if (-not $rev) { Save-Json $rbObj $rbPath }
  }
  # manual steps while the PC can still reach the old scheme
  if ($manual.Count) {
    Say ''; Say 'DO THESE BY HAND NOW (this PC can reach the old addresses until you press Enter):' 'Yellow'
    foreach ($st in $manual) {
      $ipNow = $(if ($rev) { $st.new_ip } else { $st.old_ip })
      switch ($st.type) {
        'nvr-net'      { Say ('  - Open http://' + $ipNow + ' > Setup > Network > Basic (Uniview) / Configuration > Network > TCP/IP (Hikvision): Static, IP ' + $st.new_ip + ', mask ' + $st.new_mask + ', gateway ' + $st.new_gw + ', DNS ' + $st.new_dns1 + ' and ' + $st.new_dns2 + '. Save.') }
        'nvr-platform' { Say ('  - Open http://' + $(if ($st.nvr_ip) { $st.nvr_ip } else { $ipNow }) + ' > Setup > Network > EZCloud (Uniview) / Network > Platform Access (Hikvision): tick Enable. Save.') }
        'nvr-channel'  { Say ('  - In the NVR camera list change channel D' + $st.channel + ' from ' + $st.old_ip + ' to ' + $st.new_ip + '.') }
        'cam-net'      { Say ('  - Camera ' + $ipNow + ' (D' + $st.channel + '): open http://' + $ipNow + ', set Static ' + $st.new_ip + ' mask ' + $st.new_mask + ' gateway ' + $st.new_gw + ' DNS ' + $cfg.dns1 + '/' + $cfg.dns2 + '.') }
      }
    }
    if (-not $ConfirmWith) { [void](Read-Host 'Press Enter when done (the temporary address is removed after this)') }
  }
  # ---------- 9. verify ----------
  if (-not $rev) {
    Say ''; Say '----- Checking the result -----' 'Cyan'
    foreach ($n in $nvrs) {
      $n.login = ''; $n.channels = $null; Read-Dev $n
      if ($n.login -ne 'ok') { Say ('NVR ' + $n.ip + ': cannot read it now (' + $n.login + ').') 'Red'; continue }
      if ($n.brand -eq 'hik' -and $n.platform_enabled) {
        $end = (Get-Date).AddSeconds([int]$cfg.verify_wait_seconds)
        while (-not $n.platform_online -and (Get-Date) -lt $end) { Write-Host '  waiting for the NVR to come online in Hik-Connect ...'; Start-Sleep -Seconds 10; $ez = Http $n.ip 'GET' '/ISAPI/System/Network/EZVIZ' '' 'application/xml' $script:credNvr; $n.platform_online = ((XVal $ez.body 'registerStatus') -eq 'true') }
      }
      Say ('NVR ' + $n.ip + ' | gateway ' + $n.gw + ' | DNS ' + $n.dns1 + ' ' + $n.dns2 + ' | platform ' + $(if ($n.platform_enabled) { 'ON' } else { 'OFF' }) + ' / ' + $(if ($n.platform_online) { 'ONLINE (app should work)' } elseif ($n.brand -eq 'unv') { 'check the EZView app' } else { 'NOT online yet' })) $(if ($n.platform_online) { 'Green' } else { 'Yellow' })
      if ($n.channels) {
        Start-Sleep -Seconds $(if ($Mock) { 0 } else { 20 })
        $st2 = Http $n.ip 'GET' '/ISAPI/ContentMgmt/InputProxy/channels/status' '' 'application/xml' $script:credNvr
        $onl = @{}; foreach ($mm in [regex]::Matches($st2.body, '(?s)<InputProxyChannelStatus[ >].*?</InputProxyChannelStatus>')) { $onl[(XVal $mm.Value 'id')] = ((XVal $mm.Value 'online') -eq 'true') }
        foreach ($ch in $n.channels) { if ($onl.ContainsKey($ch.id)) { $ch.online = $onl[$ch.id] } }
        $off = @($n.channels | Where-Object { -not $_.online })
        Say ('Cameras online: ' + ($n.channels.Count - $off.Count) + ' of ' + $n.channels.Count + $(if ($off.Count) { '  | offline: ' + (($off | ForEach-Object { 'D' + $_.id + ' ' + $_.ip }) -join ', ') } else { '' })) $(if ($off.Count) { 'Yellow' } else { 'Green' })
      }
    }
  }
  $fails = @($applied | Where-Object { -not $_.done }); if ($fails.Count) { $script:exitCode = 4 }
  Say ''; Say $(if ($fails.Count) { 'Finished with ' + $fails.Count + ' step(s) that did not work (see above). Undo everything with: FixNVR.ps1 -Mode Rollback -RollbackFile "' + $rbPath + '"' } else { 'Done.' + $(if (-not $rev) { ' Undo if needed: FixNVR.ps1 -Mode Rollback -RollbackFile "' + $rbPath + '"' } else { '' }) }) $(if ($fails.Count) { 'Yellow' } else { 'Green' })
  if (-not $rev -and $Mode -eq 'Fix' -and -not $fails.Count) { Invoke-CamViews $nvrs }
  if (-not $rev) { Say 'Tip: run "NVR Snapshot.cmd" now so the site has a known-good record.' }
}
try { Invoke-Main }
catch { Say ('ERROR: ' + $_.Exception.Message + ' (line ' + $_.InvocationInfo.ScriptLineNumber + ')') 'Red'; Log $_.ScriptStackTrace; $script:exitCode = 5 }
finally {
  Remove-AllTemp
  if ($script:temps.Count) { Write-Host 'WARNING: a temporary address could not be removed. Run "Fix NVR.cmd" again or reboot the PC (it is memory-only).' -ForegroundColor Red }
  $after = @($script:devs | ForEach-Object { [ordered]@{ ip = $_.ip; mac = $_.mac; kind = $_.kind; model = $_.model; gw = $_.gw; dns1 = $_.dns1; dns2 = $_.dns2; platform_enabled = $_.platform_enabled; platform_online = $_.platform_online; channel = $_.channel_id } })
  Save-Json $after (Join-Path $runDir 'after.json')
  $sum | Set-Content (Join-Path $runDir 'summary.txt')
  $script:credNvr = $null; $script:credCam = $null
  Write-Host ('Log folder: ' + $runDir)
}
exit $script:exitCode
