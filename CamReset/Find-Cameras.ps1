<#
 Find-Cameras.ps1 - WireIt CT camera finder for the password-reset tool (Windows PowerShell 5.1, no installs)
 READ-ONLY: sends discovery packets and reads answers. Changes nothing on any device.
   1. Hikvision SADP multicast probe (239.255.255.250:37020) -> serial, model, firmware, MAC, IP, "Start Time" (BootTime),
      activated, password-reset ability. Works even when the camera is on another IP scheme.
   2. ONVIF WS-Discovery (239.255.255.250:3702) -> every ONVIF camera/NVR (Uniview, Hikvision, others) + its scopes.
   3. ONVIF GetSystemDateAndTime (no login) -> the device's own date/time (Uniview's form asks for the DEVICE date).
   4. Uniview only, optional: ONE login try with the factory default admin/123456 (config univiewTryDefault).
      If it works the device is NOT locked: no reset request needed, just set a new password.
 Usage:  .\Find-Cameras.ps1            (or double-click "Find Cameras.cmd")
         .\Find-Cameras.ps1 -NoLogin   (skip the Uniview default-password try)
 Output: .\out\scan-<time>\devices.csv, devices.json, summary.txt  (+ out\latest.json)
#>
param([switch]$NoLogin, [int]$ListenSeconds = 0, [string]$ConfigPath = '', [switch]$SelfTest)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $here 'config.json' }
$cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if ($ListenSeconds -le 0) { $ListenSeconds = [int]$cfg.listenSeconds; if ($ListenSeconds -le 0) { $ListenSeconds = 6 } }
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
if (-not $locals) { Say 'No wired/Wi-Fi network address on this PC. Plug into the site network and run again.'; exit 1 }

function New-UdpSock([string]$localIp, [int]$port, [string]$group) {
  $u = New-Object System.Net.Sockets.UdpClient
  $u.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::Socket, [Net.Sockets.SocketOptionName]::ReuseAddress, $true)
  $u.Client.Bind((New-Object Net.IPEndPoint ([Net.IPAddress]::Parse($localIp)), $port))
  if ($group) { try { $u.JoinMulticastGroup([Net.IPAddress]::Parse($group), [Net.IPAddress]::Parse($localIp)) } catch {} }
  $u.Client.SetSocketOption([Net.Sockets.SocketOptionLevel]::IP, [Net.Sockets.SocketOptionName]::MulticastInterface, ([Net.IPAddress]::Parse($localIp)).GetAddressBytes())
  $u.Client.ReceiveTimeout = 300
  return $u
}
function Read-All($socks, [int]$seconds) {
  $res = New-Object System.Collections.Generic.List[object]
  $end = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $end) {
    foreach ($s in $socks) {
      while ($s.Available -gt 0) {
        $ep = New-Object Net.IPEndPoint ([Net.IPAddress]::Any), 0
        try { $b = $s.Receive([ref]$ep); $res.Add([pscustomobject]@{ From = $ep.Address.ToString(); Text = [Text.Encoding]::UTF8.GetString($b) }) } catch {}
      }
    }
    Start-Sleep -Milliseconds 100
  }
  return $res
}
function XVal($xml, [string]$name) { $m = [regex]::Match($xml, '<(?:\w+:)?' + $name + '>([^<]*)</(?:\w+:)?' + $name + '>'); if ($m.Success) { return $m.Groups[1].Value.Trim() } else { return '' } }

$dev = @{}   # key = IP (or MAC) -> ordered hashtable
function Get-Dev([string]$key) { if (-not $dev.ContainsKey($key)) { $dev[$key] = [ordered]@{ Brand=''; Model=''; Serial=''; IP=''; MAC=''; Firmware=''; StartTime=''; DeviceDate=''; Activated=''; ResetAbility=''; DefaultLoginWorks=''; Status=''; NextStep=''; HttpPort=''; Source=''; Scopes='' } }; return $dev[$key] }

# ---------- 1. Hikvision SADP ----------
$sadpSocks = @(); foreach ($l in $locals) { try { $sadpSocks += New-UdpSock $l.IPAddress 37020 '239.255.255.250' } catch { Say ('SADP: could not open port 37020 on ' + $l.IPAddress + ' (is HiTools/SADP open? close it and re-run): ' + $_.Exception.Message) } }
$probe = '<?xml version="1.0" encoding="utf-8"?><Probe><Uuid>' + ([guid]::NewGuid().ToString().ToUpper()) + '</Uuid><Types>inquiry</Types></Probe>'
$pb = [Text.Encoding]::UTF8.GetBytes($probe)
foreach ($s in $sadpSocks) { for ($k = 0; $k -lt 2; $k++) { try { [void]$s.Send($pb, $pb.Length, (New-Object Net.IPEndPoint ([Net.IPAddress]::Parse('239.255.255.250')), 37020)) } catch {} } }

# ---------- 2. ONVIF WS-Discovery ----------
$wsSocks = @(); foreach ($l in $locals) { try { $wsSocks += New-UdpSock $l.IPAddress 0 '' } catch {} }
$wsd = '<?xml version="1.0" encoding="UTF-8"?><e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl"><e:Header><w:MessageID>uuid:' + [guid]::NewGuid() + '</w:MessageID><w:To e:mustUnderstand="true">urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To><w:Action e:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action></e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body></e:Envelope>'
$wb = [Text.Encoding]::UTF8.GetBytes($wsd)
foreach ($s in $wsSocks) { for ($k = 0; $k -lt 2; $k++) { try { [void]$s.Send($wb, $wb.Length, (New-Object Net.IPEndPoint ([Net.IPAddress]::Parse('239.255.255.250')), 3702)) } catch {} } }

Say ('Listening ' + $ListenSeconds + ' s for camera answers...')
$answers = Read-All (@($sadpSocks) + @($wsSocks)) $ListenSeconds
foreach ($s in (@($sadpSocks) + @($wsSocks))) { try { $s.Close() } catch {} }
if ($SelfTest) {   # fake answers (TEST-NET addresses, nothing is contacted) to prove parsing/output without a camera
  $answers = @($answers) + @(
    [pscustomobject]@{ From = '192.0.2.64'; Text = '<?xml version="1.0" encoding="UTF-8"?><ProbeMatch><Uuid>X</Uuid><Types>inquiry</Types><DeviceType>139</DeviceType><DeviceDescription>DS-2CD2143G2-I</DeviceDescription><DeviceSN>DS-2CD2143G2-I20230101AAWRTEST00001</DeviceSN><CommandPort>8000</CommandPort><HttpPort>80</HttpPort><MAC>c4-2f-90-00-00-01</MAC><IPv4Address>192.0.2.64</IPv4Address><IPv4SubnetMask>255.255.255.0</IPv4SubnetMask><IPv4Gateway>192.0.2.1</IPv4Gateway><DHCP>false</DHCP><SoftwareVersion>V5.7.3build 220112</SoftwareVersion><DSPVersion>V7.3 build 220112</DSPVersion><BootTime>2026-11-02 09:12:22</BootTime><Activated>true</Activated><PasswordResetAbility>true</PasswordResetAbility><ResetAbility>false</ResetAbility><SupportSecurityQuestion>true</SupportSecurityQuestion><OEMInfo>hikvision</OEMInfo></ProbeMatch>' },
    [pscustomobject]@{ From = '192.0.2.70'; Text = '<?xml version="1.0"?><SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"><SOAP-ENV:Body><d:ProbeMatches><d:ProbeMatch><d:Scopes>onvif://www.onvif.org/type/video_encoder onvif://www.onvif.org/name/Uniview onvif://www.onvif.org/hardware/IPC2124LB-SF28KM-G</d:Scopes><d:XAddrs>http://192.0.2.70/onvif/device_service</d:XAddrs></d:ProbeMatch></d:ProbeMatches></SOAP-ENV:Body></SOAP-ENV:Envelope>' })
  Say 'SELF-TEST: 2 fake answers added (192.0.2.x test addresses).'
}
$rawFile = Join-Path $out 'raw-answers.txt'
foreach ($a in $answers) { Add-Content -Path $rawFile -Value ('--- from ' + $a.From + "`r`n" + $a.Text) }

foreach ($a in $answers) {
  $x = $a.Text
  if ($x -match '<ProbeMatch>' -and $x -match '<DeviceSN>') {         # SADP answer
    $ip = XVal $x 'IPv4Address'; $d = Get-Dev $ip
    $d.Brand = 'Hikvision'; $d.IP = $ip; $d.Model = XVal $x 'DeviceDescription'; $d.Serial = XVal $x 'DeviceSN'
    $d.MAC = (XVal $x 'MAC').ToUpper(); $d.Firmware = ((XVal $x 'SoftwareVersion') + ' ' + (XVal $x 'DSPVersion')).Trim()
    $d.StartTime = XVal $x 'BootTime'; $d.Activated = XVal $x 'Activated'; $d.HttpPort = XVal $x 'HttpPort'
    $ra = @(); foreach ($f in 'ResetAbility','PasswordResetAbility','PasswordResetModeSecond','SupportSecurityQuestion','SupportHCPlatform','HCPlatformEnable','SupportMailBox','SupportEzvizUnbind','SupportGUID') { $v = XVal $x $f; if ($v) { $ra += ($f + '=' + $v) } }
    $d.ResetAbility = ($ra -join ' ')
    $oem = XVal $x 'OEMInfo'; if ($oem -and $oem -notmatch '(?i)hikvision') { $d.Brand = 'Hikvision (OEM: ' + $oem + ')' }
    $d.Source = ($d.Source + ' SADP').Trim()
  } elseif ($x -match 'ProbeMatch' -and $x -match 'XAddrs') {         # ONVIF answer
    $xa = (XVal $x 'XAddrs') -split '\s+' | Where-Object { $_ -match '^http' } | Select-Object -First 1
    $ip = $a.From; if ($xa -match '//([0-9.]+)') { $ip = $Matches[1] }
    $d = Get-Dev $ip; $d.IP = $ip; $d.Scopes = (XVal $x 'Scopes'); $d['Xaddr'] = $xa
    $sc = [uri]::UnescapeDataString($d.Scopes)
    if (-not $d.Brand) {
      if ($sc -match '(?i)uniview|unv|uniarch') { $d.Brand = 'Uniview' }
      elseif ($sc -match '(?i)hikvision|hik') { $d.Brand = 'Hikvision' }
      else { $d.Brand = 'Other (ONVIF)' }
    }
    if (-not $d.Model) { if ($sc -match 'onvif://www\.onvif\.org/hardware/(\S+)') { $d.Model = $Matches[1] } }
    $d.Source = ($d.Source + ' ONVIF').Trim()
  }
}

# ---------- 3/4. per-device reads ----------
function Invoke-Soap([string]$url, [string]$body) {
  $env = '<?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body>' + $body + '</s:Body></s:Envelope>'
  try { $r = Invoke-WebRequest -Uri $url -Method Post -Body $env -ContentType 'application/soap+xml; charset=utf-8' -TimeoutSec 5 -UseBasicParsing; return $r.Content } catch { return '' }
}
$arp = @{}
Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.LinkLayerAddress -and $_.LinkLayerAddress -ne '00-00-00-00-00-00' } | ForEach-Object { $arp[$_.IPAddress] = $_.LinkLayerAddress.ToUpper() }
foreach ($k in @($dev.Keys)) {
  $d = $dev[$k]
  if (-not $d.MAC -and $arp.ContainsKey($d.IP)) { $d.MAC = $arp[$d.IP] }
  if ($d.MAC -match '^(48-EA-63|48:EA:63|C4-79-05|C4:79:05)' -and $d.Brand -like 'Other*') { $d.Brand = 'Uniview' }
  $sameNet = $false; foreach ($l in $locals) { $a = ([Net.IPAddress]::Parse($l.IPAddress)).GetAddressBytes(); try { $b = ([Net.IPAddress]::Parse($d.IP)).GetAddressBytes() } catch { continue }; $bits = $l.PrefixLength; $match = $true; for ($i = 0; $i -lt 4; $i++) { $m = [Math]::Max(0, [Math]::Min(8, $bits - 8 * $i)); $mask = (0xFF -shl (8 - $m)) -band 0xFF; if (($a[$i] -band $mask) -ne ($b[$i] -band $mask)) { $match = $false } }; if ($match) { $sameNet = $true } }
  $d['SameSubnet'] = $sameNet
  if (-not $sameNet) { $d.Status = 'On a different IP scheme than this PC'; }
  # device date/time without login (ONVIF)
  if ($sameNet) {
    $xaddr = $d['Xaddr']; if (-not $xaddr) { $xaddr = 'http://' + $d.IP + $(if ($d.HttpPort -and $d.HttpPort -ne '80') { ':' + $d.HttpPort } else { '' }) + '/onvif/device_service' }
    $t = Invoke-Soap $xaddr '<GetSystemDateAndTime xmlns="http://www.onvif.org/ver10/device/wsdl"/>'
    if ($t) {
      $lt = [regex]::Match($t, 'LocalDateTime>.*?Year>(\d+)<.*?Month>(\d+)<.*?Day>(\d+)<.*?Hour>(\d+)<.*?Minute>(\d+)<', 'Singleline')
      $ut = [regex]::Match($t, 'UTCDateTime>.*?Year>(\d+)<.*?Month>(\d+)<.*?Day>(\d+)<.*?Hour>(\d+)<.*?Minute>(\d+)<', 'Singleline')
      $mm = if ($lt.Success) { $lt } else { $ut }
      if ($mm.Success) { $d.DeviceDate = ('{0}-{1:D2}-{2:D2} {3:D2}:{4:D2}' -f [int]$mm.Groups[1].Value, [int]$mm.Groups[2].Value, [int]$mm.Groups[3].Value, [int]$mm.Groups[4].Value, [int]$mm.Groups[5].Value) + $(if ($lt.Success) { ' (device local)' } else { ' (device UTC)' }) }
    }
    # Uniview: one try with the factory default (never more than one per device per run)
    if ($d.Brand -eq 'Uniview' -and -not $NoLogin -and $cfg.univiewTryDefault) {
      $tried = Join-Path $here 'state\default-tried.txt'; New-Item -ItemType Directory -Force -Path (Join-Path $here 'state') | Out-Null
      $already = (Test-Path $tried) -and ((Get-Content $tried) -contains ($d.IP + ' ' + (Get-Date -Format 'yyyy-MM-dd')))
      if (-not $already) {
        Add-Content -Path $tried -Value ($d.IP + ' ' + (Get-Date -Format 'yyyy-MM-dd'))
        try {
          $cred = New-Object Net.NetworkCredential('admin', '123456')
          $wc = New-Object Net.WebClient; $wc.Credentials = $cred
          $info = $wc.DownloadString('http://' + $d.IP + '/LAPI/V1.0/System/DeviceInfo')
          $d.DefaultLoginWorks = 'YES'
          foreach ($p in 'SerialNumber','DeviceModel','FirmwareVersion','Manufacturer') { $m = [regex]::Match($info, '"' + $p + '"\s*:\s*"([^"]*)"'); if ($m.Success) { switch ($p) { 'SerialNumber' { $d.Serial = $m.Groups[1].Value } 'DeviceModel' { $d.Model = $m.Groups[1].Value } 'FirmwareVersion' { $d.Firmware = $m.Groups[1].Value } } } }
        } catch {
          $code = ''; if ($_.Exception.InnerException -and $_.Exception.InnerException.Response) { $code = [int]$_.Exception.InnerException.Response.StatusCode }
          $d.DefaultLoginWorks = $(if ($code -eq 401) { 'no (401)' } else { 'no answer (' + $_.Exception.Message.Split("`n")[0] + ')' })
        }
      } else { $d.DefaultLoginWorks = 'already tried today (skipped)' }
    }
  }
  # verdict + next step
  if ($d.Brand -like 'Hikvision*') {
    if ($d.Activated -eq 'false') { $d.Status = 'NOT ACTIVATED (factory fresh)'; $d.NextStep = 'No reset needed: activate it in HiTools with a new password' }
    else { if (-not $d.Status) { $d.Status = 'Activated (password unknown?)' }; $d.NextStep = 'HiTools > select > Reset Password > Import/Export Key > Export XML File (see README step H)' }
  } elseif ($d.Brand -eq 'Uniview') {
    if ($d.DefaultLoginWorks -eq 'YES') { $d.Status = 'Default password works (admin/123456)'; $d.NextStep = 'No reset needed: log in and set a new password' }
    else { if (-not $d.Status) { $d.Status = 'Locked (default does not work)' }; $d.NextStep = 'Uniview request: needs 20-digit SN (label or EZTools list) + device date (see README step U)' }
  } else { $d.NextStep = 'Not Hikvision/Uniview: check model' }
}

# ---------- output ----------
$rows = foreach ($k in ($dev.Keys | Sort-Object)) { [pscustomobject]$dev[$k] }
$rows = @($rows | Where-Object { $_ })
$rows | Select-Object Brand, Model, Serial, IP, MAC, Firmware, StartTime, DeviceDate, Activated, DefaultLoginWorks, Status, NextStep, ResetAbility, SameSubnet, Source | Export-Csv -Path (Join-Path $out 'devices.csv') -NoTypeInformation -Encoding UTF8
$json = $rows | ConvertTo-Json -Depth 4
if ($rows.Count -eq 1) { $json = '[' + $json + ']' }
if ($rows.Count -eq 0) { $json = '[]' }
Set-Content -Path (Join-Path $out 'devices.json') -Value $json -Encoding UTF8
$latest = [ordered]@{ scannedAt = (Get-Date -Format 's'); pc = $env:COMPUTERNAME; folder = $out; devices = $rows }
Set-Content -Path (Join-Path $outRoot 'latest.json') -Value ($latest | ConvertTo-Json -Depth 5) -Encoding UTF8
Say ''
Say ('Found ' + $rows.Count + ' device(s): ' + @($rows | Where-Object { $_.Brand -like 'Hikvision*' }).Count + ' Hikvision, ' + @($rows | Where-Object { $_.Brand -eq 'Uniview' }).Count + ' Uniview, ' + @($rows | Where-Object { $_.Brand -like 'Other*' }).Count + ' other')
foreach ($r in $rows) {
  Say ('- ' + $r.Brand + ' ' + $r.Model + ' | SN ' + $r.Serial + ' | ' + $r.IP + ' | start ' + $r.StartTime + ' | date ' + $r.DeviceDate)
  Say ('    ' + $r.Status + ' -> ' + $r.NextStep)
  if (-not $r.SameSubnet) { Say ('    Note: camera is on another IP scheme. HiTools still sees it; for its web page give this PC a second address in that range or change the camera IP in HiTools.') }
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
Log ('found=' + $rows.Count + ' out=' + $out)
