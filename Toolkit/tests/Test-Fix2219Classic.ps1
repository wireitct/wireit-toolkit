<# Test-Fix2219Classic.ps1 - tests for WireIt Toolkit 2.2.19 (Nov 11 2026), the classic Fix NVR (FixNVR/FixNVR.ps1) and CamReset part of
   Codex's NO-GO review of 2.2.18 (head a7ceac8). Each Codex reproduction (evidence classic.ps1) is a check here, plus the twins of each
   class in the classic files:
   F10 (class D)  a real ISAPI DHCP value is 'dynamic': Undo put a DHCP recorder back as a fixed address. 2.2.19: modes are normalised,
                  a DHCP Undo sends DHCP and counts only when the device is found again BY ITS MAC and reads back DHCP; Uniview and
                  ONVIF DHCP Undo send nothing (manual step) instead of writing a fixed address first.
   F11 (class D)  an empty DNS is a real value: Undo kept the DNS the fix had put in (Hikvision and ONVIF).
   F12 (class C)  a read-back without address / mode counted as "matches". 2.2.19: missing = NOT CHECKED; mode compared too.
   F24 (class A)  a serial-only undo record could never be used. 2.2.19: exact non-empty serial match when no MAC was saved, never address.
   F06 (class A)  ONVIF gateway / DNS were written to whatever answered at the new address when it gave no MAC.
   F09 (class E)  a '{}' clean-up journal was read as "nothing to clean" and deleted.
   F05 (class A)  PC adapter recovery wrote to an adapter whose name could not be read.
   class B        forward: the device is read again after YES; changed since the plan = nothing sent. A move target is checked free
                  right before the write in both directions.
   class C twins  Test-IpFree: a neighbour-table error is "cannot tell" (not free). CamReset: an unreadable / unwritable default-try
                  record = no try.
   follow-up      (2.2.19 classic2) the twins fixed without a test in the first pass, now RUN: Add-TempIp coexistence read-back,
                  Set-SafetyTask register failure + record-save failure, Open-Firewall record before the rule, Snapshot Drive copy
                  verified, platform step re-read after YES, and CamReset's default-try record (Find-Cameras.ps1 run for real
                  with test discovery answers; its one login try goes to 127.0.0.70:80, nothing on the network is contacted).
   Every check RUNS the real FixNVR.ps1 functions in a child PowerShell; only device web answers, discovery and Windows network
   commands are stood in for. A check marked (code shape) reads the source text instead, and says so.
   NEEDS WINDOWS / REAL DEVICE CHECK (DEFERRED, never PASS): Windows PowerShell 5.1, real Get-NetNeighbor / Get-NetIPAddress error
   categories, real netsh text, real Uniview LAPI mode fields, a real Hikvision DHCP Undo found again by SADP.
   FIX2219CLASSIC_FILE (tests only) = run against another copy of FixNVR.ps1 (old-code proof: on 2.2.18 the finding checks FAIL). #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$fnvPath = $(if ($env:FIX2219CLASSIC_FILE) { $env:FIX2219CLASSIC_FILE } else { Join-Path $repo 'FixNVR/FixNVR.ps1' })
if (Test-Path -LiteralPath $fnvPath -PathType Container) { $fnvPath = Join-Path $fnvPath 'FixNVR/FixNVR.ps1' }   # a repo folder works too
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2219classic-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { $m = ($more -replace '\s+', ' '); Write-Host ('     ' + $m.Substring(0, [math]::Min(1500, $m.Length))) } }
}
function Deferred([string]$name) { $script:deferred++; Write-Host ('DEFERRED ' + $name + ' (NEEDS WINDOWS / REAL DEVICE CHECK)') }
function Get-FnText([string]$file) {
  $ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
  $fns = @($ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
  $top = @($fns | Where-Object { $p = $_.Parent; $inFn = $false; while ($p) { if ($p -is [Management.Automation.Language.FunctionDefinitionAst]) { $inFn = $true; break }; $p = $p.Parent }; -not $inFn })
  return (($top | ForEach-Object { $_.Extent.Text }) -join "`n")
}
function Invoke-Driver([string]$name, [string]$code) {
  $f = Join-Path $tmp ($name + '.ps1'); [IO.File]::WriteAllText($f, $code, (New-Object Text.UTF8Encoding($true)))
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = & $exe -NoProfile -ExecutionPolicy Bypass -File $f 2>&1 | Out-String } finally { $ErrorActionPreference = $prev }
  return $o
}
function Get-Json([string]$out) { $m = [regex]::Match($out, '(?m)^JSON=(\{.*\})\s*$'); if ($m.Success) { try { return ($m.Groups[1].Value | ConvertFrom-Json) } catch {} }; return $null }
function Q([string]$s) { return "'" + $s.Replace("'", "''") + "'" }
$e = $null; [void][Management.Automation.Language.Parser]::ParseFile($fnvPath, [ref]$null, [ref]$e); Check ($e.Count -eq 0) 'parses: FixNVR.ps1' ($e | Out-String)
$fnText = Get-FnText $fnvPath


try {
  # ==============================================================================================================================
  # real Invoke-Main + readers / writers; $script:sim.devs is the network (ip -> device answers)
  $pre = $fnText + "`n" + '$ErrorActionPreference = ''Continue''; $here = ' + (Q (Join-Path $tmp 'here')) + "`n" + @'
$Mock = $null; $oui = @{}; $Version = 'test'; $Site = ''; $SniffSeconds = 0; $OldSubnet = @(); $Nvr = ''; $NoLogin = $false; $MoveUnlisted = $false; $AllowUnverifiedUniview = $false
$ConfirmWith = 'YES'; $snap = $null; $rb = $null; $script:routerStepShown = $false; $IsPs5 = $false; $script:nvrTls = @{}; $script:refused = @{}; $script:scheme = @{}
$cfg = [pscustomobject]@{ arp_sniff_seconds = 0; max_old_subnets = 2; nvr_hosts = @(20, 19, 18); camera_block_start = 21; camera_block_end = 99; camera_channel_base = 20; camera_ip_mode = 'keep_last_octet'; router_dhcp_start = 100; dns1 = '8.8.8.8'; dns2 = '1.1.1.1'; verify_wait_seconds = 10; camera_wait_seconds = 10; poe_internal_subnets = @('192.168.254'); temp_ip_hosts = @(253); uniview = [pscustomobject]@{ cloud_path = '/x'; net_path = '/LAPI/net'; dns_path = '/LAPI/dns'; channels_path = '/LAPI/ch' } }
$pc = [pscustomobject]@{ ifIndex = 5; alias = 'Ethernet'; dhcp = $true; ip = '192.168.1.105'; prefix = 24; gw = '192.168.1.1' }; $script:pcNet = $pc
$newP3 = '192.168.1'; $newMask = '255.255.255.0'
$plan = New-Object System.Collections.Generic.List[object]; $applied = New-Object System.Collections.Generic.List[object]
$script:devs = New-Object System.Collections.Generic.List[object]
$script:exitCode = 0
$runDir = Join-Path $here ('run-' + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$logFile = Join-Path $runDir 'log.txt'; $sum = New-Object System.Collections.Generic.List[string]
$script:credNvr = New-Object PSCredential('admin', (ConvertTo-SecureString 'Site#2026' -AsPlainText -Force)); $script:credCam = $script:credNvr
$script:sim = @{ devs = @{}; writes = New-Object System.Collections.ArrayList }
function Open-Firewall { }
function Get-Creds { }
function Test-IpFree([string]$ip) { return (-not $script:sim.devs.ContainsKey($ip)) }
function Start-Sleep { }
function Find-ArpSniff([int]$seconds) { return @{} }
function Find-Onvif($localIps) { return @{} }
function Add-TempIp { return $null }
function Invoke-CamViews($l) { }
function Find-Sadp($localIps) {
  $o = @{}; foreach ($ip in @($script:sim.devs.Keys)) { $d = $script:sim.devs[$ip]; if ($d.sadp -eq $false) { continue }; $o[$d.mac] = [pscustomobject]@{ ip = $ip; mac = $d.mac; kind = $(if ($d.type -eq 'NVR') { 'nvr' } else { 'camera' }); brand = 'hik'; model = $d.model; serial = $d.serial; found_by = 'SADP'; dhcp = $false; mask = $d.mask; gw = $d.gw } }
  return $o
}
function X([string]$doc, [string]$tag) { $m = [regex]::Match($doc, '<' + $tag + '>([^<]*)</' + $tag + '>'); if ($m.Success) { return $m.Groups[1].Value } else { return '' } }
function Ok { return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode><statusString>OK</statusString></ResponseStatus>'; err = '' } }
function Http([string]$ip, [string]$method, [string]$path, [string]$body = '', [string]$ctype = '', $cred = $null, [int]$timeout = 10) {
  if (-not $script:sim.devs.ContainsKey($ip)) { return @{ code = 0; body = ''; err = 'The operation timed out' } }
  $d = $script:sim.devs[$ip]
  if ($d.onvifOnly -and $path -ne '/onvif/device_service') { return @{ code = 404; body = ''; err = 'not found' } }
  if ($d.unv) {
    if ($path -like '/ISAPI/*') { return @{ code = 404; body = ''; err = 'not found' } }
    $J = { param($data) return @{ code = 200; body = (@{ Response = @{ ResponseCode = 0; StatusCode = 0; Data = $data } } | ConvertTo-Json -Depth 6 -Compress); err = '' } }
    if ($path -eq '/LAPI/V1.0/System/DeviceBasicInfo') { return (& $J @{ MAC = $d.mac; SerialNumber = $d.serial; DeviceModel = 'NVR301-08S'; FirmwareVersion = 'B3118' }) }
    if ($path -eq '/LAPI/net' -and $method -eq 'GET') { $nd = [ordered]@{}; if (-not $d.noAddr) { $nd.IPv4Address = $ip }; $nd.Netmask = $d.mask; $nd.Gateway = $d.gw; if ($null -ne $d.dhcpFlag) { $nd.DHCPEnable = $d.dhcpFlag }; return (& $J $nd) }
    if ($path -eq '/LAPI/net' -and $method -eq 'PUT') { [void]$script:sim.writes.Add('unv-net ' + $ip + ' (' + $d.mac + ') ' + $body); $jb = $body | ConvertFrom-Json; if ($jb.Gateway) { $d.gw = $jb.Gateway }; if ($null -ne $jb.DHCPEnable -and -not $d.stickyDhcp) { $d.dhcpFlag = $jb.DHCPEnable }; $to = [string]$jb.IPv4Address; if ($to -and $to -ne $ip) { $script:sim.devs.Remove($ip); $script:sim.devs[$to] = $d }; return (& $J $null) }
    if ($path -eq '/LAPI/dns' -and $method -eq 'GET') { return (& $J ([ordered]@{ PrimaryDNS = $d.dns1; SecondaryDNS = $d.dns2 })) }
    if ($path -eq '/LAPI/dns' -and $method -eq 'PUT') { [void]$script:sim.writes.Add('unv-dns ' + $ip + ' (' + $d.mac + ') ' + $body); $jb = $body | ConvertFrom-Json; $d.dns1 = [string]$jb.PrimaryDNS; $d.dns2 = [string]$jb.SecondaryDNS; return (& $J $null) }
    if ($path -eq '/x') { return (& $J @{ Enable = 1 }) }
    if ($path -eq '/LAPI/ch') { return (& $J @{ Channels = @() }) }
    return @{ code = 404; body = ''; err = 'not found' }
  }
  if ($path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = ('<DeviceInfo><deviceName>x</deviceName><model>' + $d.model + '</model><serialNumber>' + $d.serial + '</serialNumber><macAddress>' + $d.mac + '</macAddress><firmwareVersion>V4.1</firmwareVersion><deviceType>' + $d.type + '</deviceType></DeviceInfo>'); err = '' } }
  if ($path -eq '/ISAPI/System/Network/interfaces') { return @{ code = 200; body = ('<NetworkInterfaceList><NetworkInterface><id>1</id><IPAddress><ipAddress>' + $ip + '</ipAddress></IPAddress></NetworkInterface></NetworkInterfaceList>'); err = '' } }
  if ($path -eq '/ISAPI/System/Network/interfaces/1/ipAddress' -and $method -eq 'GET') { return @{ code = 200; body = ('<IPAddress><ipVersion>v4</ipVersion><addressingType>' + $d.addressing + '</addressingType><ipAddress>' + $ip + '</ipAddress><subnetMask>' + $d.mask + '</subnetMask><DefaultGateway><ipAddress>' + $d.gw + '</ipAddress></DefaultGateway><PrimaryDNS><ipAddress>' + $d.dns1 + '</ipAddress></PrimaryDNS><SecondaryDNS><ipAddress>' + $d.dns2 + '</ipAddress></SecondaryDNS></IPAddress>'); err = '' } }
  if ($path -eq '/ISAPI/System/Network/interfaces/1/ipAddress' -and $method -eq 'PUT') {
    $to = X $body 'ipAddress'; [void]$script:sim.writes.Add('net ' + $ip + ' (' + $d.mac + ') -> ' + $to)
    $d.addressing = X $body 'addressingType'; $d.mask = X $body 'subnetMask'
    if (-not $d.keepGw) { $d.gw = [regex]::Match($body, '<DefaultGateway><ipAddress>([^<]*)<').Groups[1].Value }
    $p1 = [regex]::Match($body, '<PrimaryDNS><ipAddress>([^<]*)<'); if ($p1.Success) { $d.dns1 = $p1.Groups[1].Value }
    $p2 = [regex]::Match($body, '<SecondaryDNS><ipAddress>([^<]*)<'); if ($p2.Success) { $d.dns2 = $p2.Groups[1].Value }
    if ($d.addressing -eq 'dynamic' -and $d.dhcpIp) { $to = $d.dhcpIp }; if ($d.addressing -eq 'dynamic' -and $d.dhcpHide) { $d.sadp = $false }
    if ($d.stickyMode) { $d.addressing = $d.stickyMode }
    if ($to -and $to -ne $ip) { $script:sim.devs.Remove($ip); $script:sim.devs[$to] = $d }
    return (Ok)
  }
  if ($path -eq '/ISAPI/System/Network/EZVIZ') {
    # platform access: $d.ezviz = $null/'on' (on + online), 'off', 'fail' (no answer); a PUT is recorded and turns it on
    if ($method -eq 'PUT') { [void]$script:sim.writes.Add('platform ' + $ip + ' (' + $d.mac + ')'); $d.ezviz = 'on'; return (Ok) }
    if ($d.ezviz -eq 'fail') { return @{ code = 0; body = ''; err = 'The operation timed out' } }
    $en = $(if ($d.ezviz -eq 'off') { 'false' } else { 'true' })
    return @{ code = 200; body = ('<EZVIZ><enabled>' + $en + '</enabled><registerStatus>' + $en + '</registerStatus></EZVIZ>'); err = '' }
  }
  if ($path -eq '/ISAPI/ContentMgmt/InputProxy/channels') { $b = '<InputProxyChannelList>'; foreach ($c in @($d.channels)) { $b += '<InputProxyChannel><id>' + $c.id + '</id><sourceInputPortDescriptor><proxyProtocol>HIKVISION</proxyProtocol><ipAddress>' + $c.ip + '</ipAddress><managePortNo>8000</managePortNo></sourceInputPortDescriptor></InputProxyChannel>' }; return @{ code = 200; body = ($b + '</InputProxyChannelList>'); err = '' } }
  if ($path -eq '/ISAPI/ContentMgmt/InputProxy/channels/status') { $b = '<InputProxyChannelStatusList>'; foreach ($c in @($d.channels)) { $b += '<InputProxyChannelStatus><id>' + $c.id + '</id><online>' + $(if ($script:sim.devs.ContainsKey($c.ip)) { 'true' } else { 'false' }) + '</online></InputProxyChannelStatus>' }; return @{ code = 200; body = ($b + '</InputProxyChannelStatusList>'); err = '' } }
  $m = [regex]::Match($path, '^/ISAPI/ContentMgmt/InputProxy/channels/(\d+)$')
  if ($m.Success) {
    $c = @($d.channels | Where-Object { [string]$_.id -eq $m.Groups[1].Value })[0]
    if (-not $c) { return @{ code = 404; body = ''; err = 'no such channel' } }
    if ($method -eq 'GET') { return @{ code = 200; body = ('<InputProxyChannel><id>' + $c.id + '</id><sourceInputPortDescriptor><proxyProtocol>HIKVISION</proxyProtocol><addressingFormatType>ipaddress</addressingFormatType><ipAddress>' + $c.ip + '</ipAddress><managePortNo>8000</managePortNo><userName>admin</userName></sourceInputPortDescriptor></InputProxyChannel>'); err = '' } }
    $to = X $body 'ipAddress'; [void]$script:sim.writes.Add('channel ' + $ip + ' D' + $c.id + ' ' + $c.ip + ' -> ' + $to); if (-not $d.ignoreChannel) { $c.ip = $to }; return (Ok)
  }
  if ($path -eq '/ISAPI/System/reboot') { return (Ok) }
  if ($path -eq '/onvif/device_service' -and $d.onvif) {
    if ($body -match '<tds:GetNetworkInterfaces') {
      $v4 = $(if ($d.addressing -eq 'dynamic') { '<tt:FromDHCP><tt:Address>' + $ip + '</tt:Address><tt:PrefixLength>24</tt:PrefixLength></tt:FromDHCP>' } else { '<tt:Manual><tt:Address>' + $ip + '</tt:Address><tt:PrefixLength>24</tt:PrefixLength></tt:Manual>' })
      $mode = $(if ($d.noMode) { '' } else { '<tt:DHCP>' + $(if ($d.addressing -eq 'dynamic') { 'true' } else { 'false' }) + '</tt:DHCP>' })
      $hwx = $(if ($d.noHw) { '' } else { '<tt:HwAddress>' + $d.mac + '</tt:HwAddress>' })
      return @{ code = 200; body = ('<tds:GetNetworkInterfacesResponse><tds:NetworkInterfaces token="eth0"><tt:Info>' + $hwx + '</tt:Info><tt:IPv4><tt:Enabled>true</tt:Enabled><tt:Config>' + $v4 + $mode + '</tt:Config></tt:IPv4></tds:NetworkInterfaces></tds:GetNetworkInterfacesResponse>'); err = '' }
    }
    if ($body -match '<tds:GetNetworkDefaultGateway') { return @{ code = 200; body = ('<tds:GetNetworkDefaultGatewayResponse><tds:NetworkGateway>' + $(if ($d.gw) { '<tt:IPv4Address>' + $d.gw + '</tt:IPv4Address>' } else { '' }) + '</tds:NetworkGateway></tds:GetNetworkDefaultGatewayResponse>'); err = '' } }
    if ($body -match '<tds:GetDNS') { $dl = ''; foreach ($x in @($d.dns1, $d.dns2) + @($d.dnsExtra)) { if ($x) { $dl += '<tt:DNSManual><tt:Type>IPv4</tt:Type><tt:IPv4Address>' + $x + '</tt:IPv4Address></tt:DNSManual>' } }; return @{ code = 200; body = ('<tds:GetDNSResponse><tds:DNSInformation><tt:FromDHCP>false</tt:FromDHCP>' + $dl + '</tds:DNSInformation></tds:GetDNSResponse>'); err = '' } }
    if ($body -match '<tds:SetNetworkInterfaces') {
      $to = X $body 'tt:Address'; $dh = X $body 'tt:DHCP'; [void]$script:sim.writes.Add('onvif-net ' + $ip + ' (' + $d.mac + ') -> ' + $to + ' dhcp=' + $dh)
      if ($dh -eq 'true') { $d.addressing = 'dynamic' } else { $d.addressing = 'static' }
      if ($to -and $to -ne $ip) { $script:sim.devs.Remove($ip); $script:sim.devs[$to] = $d }
      return @{ code = 200; body = '<tds:SetNetworkInterfacesResponse><tds:RebootNeeded>false</tds:RebootNeeded></tds:SetNetworkInterfacesResponse>'; err = '' }
    }
    if ($body -match '<tds:SetNetworkDefaultGateway') { [void]$script:sim.writes.Add('onvif-gw ' + $ip + ' (' + $d.mac + ') ' + $body.Substring($body.IndexOf('<tds:SetNetworkDefaultGateway'))); $d.gw = X $body 'tds:IPv4Address'; return @{ code = 200; body = '<tds:SetNetworkDefaultGatewayResponse/>'; err = '' } }
    if ($body -match '<tds:SetDNS') { $sb = $body.Substring($body.IndexOf('<tds:SetDNS')); [void]$script:sim.writes.Add('onvif-dns ' + $ip + ' (' + $d.mac + ') ' + $sb); $vals = @([regex]::Matches($sb, '<tt:IPv4Address>([^<]*)</tt:IPv4Address>') | ForEach-Object { $_.Groups[1].Value }); $d.dns1 = $(if ($vals.Count -ge 1) { $vals[0] } else { '' }); $d.dns2 = $(if ($vals.Count -ge 2) { $vals[1] } else { '' }); return @{ code = 200; body = '<tds:SetDNSResponse/>'; err = '' } }
  }
  return @{ code = 404; body = ''; err = 'not found' }
}
function New-SimDev([string]$type, [string]$mac, [string]$gw = '192.168.1.1') { return @{ type = $type; mac = $mac; serial = ('SN' + ($mac -replace '-', '')); model = $(if ($type -eq 'NVR') { 'DS-7608NI-K2' } else { 'DS-2CD2143G2' }); addressing = 'static'; mask = '255.255.255.0'; gw = $gw; dns1 = '8.8.8.8'; dns2 = '1.1.1.1'; channels = @(); keepGw = $false } }
function Run-Main([string]$mode, $rbObj) {
  $script:exitCode = 0; $sum.Clear(); $script:devs.Clear(); $plan.Clear(); $applied.Clear(); $script:sim.writes.Clear(); $script:refused = @{}
  $script:Mode = $mode; $script:rb = $rbObj
  try { Invoke-Main } catch { $sum.Add('ERROR ' + $_.Exception.Message + ' line ' + $_.InvocationInfo.ScriptLineNumber + ': ' + $_.InvocationInfo.Line.Trim()); $script:exitCode = 5 }
  return [pscustomobject]@{ code = $script:exitCode; said = (@($sum) -join "`n"); writes = @($script:sim.writes) }
}
function Out-Result($o) { 'JSON=' + ($o | ConvertTo-Json -Compress -Depth 6) }
function New-Rb($steps) { return [pscustomobject]@{ tool = 'test'; site = ''; pc = '192.168.1.105'; router = '192.168.1.1'; old_subnets = @(); steps = @($steps | ForEach-Object { [pscustomobject]$_ }) } }
$A = 'C0-56-E3-00-00-01'; $B = 'C0-56-E3-00-00-99'

$script:afterYes = $null
$origSaveJson = ${function:Save-Json}
function Save-Json($obj, [string]$path) { & $origSaveJson $obj $path; if ($path -like '*rollback.json' -and $script:afterYes) { $h = $script:afterYes; $script:afterYes = $null; & $h } }
$runDirFile = { Join-Path $runDir 'rollback.json' }
function FixUndo($d, [string]$at = '192.168.1.20') {
  $script:sim.devs = @{ $at = $d }
  $f = Run-Main 'Fix' $null
  $p = (& $runDirFile); $saved = $null; if (Test-Path $p) { $saved = Get-Content $p -Raw | ConvertFrom-Json; Remove-Item $p }
  $u = $(if ($saved) { Run-Main 'Rollback' $saved } else { $null })
  return [pscustomobject]@{ f = $f; u = $u; savedMode = $(if ($saved) { [string]$saved.steps[0].old_addressing } else { '' }); mode = [string]$d.addressing; dns1 = [string]$d.dns1; dns2 = [string]$d.dns2; at = (@($script:sim.devs.Keys) -join ',') }
}
'@

  Write-Host 'F10 / F11 / F24 / class B / class A: classic Fix and Undo through the real Invoke-Main'
  $o = Invoke-Driver 'main' ($pre + "`n" + @'
$res = [ordered]@{}
# F10 (Codex): a DHCP recorder (ISAPI says 'dynamic') with a wrong gateway: Fix, then Undo
$d = New-SimDev 'NVR' $A; $d.addressing = 'dynamic'; $d.gw = '192.168.1.254'; $res.A = FixUndo $d
# F10 twin: after the DHCP Undo the recorder is not found again on the network -> NOT CHECKED, never Done
$d = New-SimDev 'NVR' $A; $d.addressing = 'dynamic'; $d.gw = '192.168.1.254'; $d.dhcpHide = $true; $res.B = FixUndo $d
# F10 control: the router gives it .150; it is found there by MAC and reads back DHCP -> done
$d = New-SimDev 'NVR' $A; $d.addressing = 'dynamic'; $d.gw = '192.168.1.254'; $d.dhcpIp = '192.168.1.150'; $res.C = FixUndo $d
# F10 twin: the recorder accepts the DHCP PUT but stays on a fixed address -> NOT CHECKED
$d = New-SimDev 'NVR' $A; $d.addressing = 'dynamic'; $d.gw = '192.168.1.254'; $d.stickyMode = 'static'; $res.D = FixUndo $d
# F11 (Codex): empty DNS was the recorder's real setting; Undo must put empty DNS back
$d = New-SimDev 'NVR' $A; $d.dns1 = ''; $d.dns2 = ''; $res.E = FixUndo $d
# F24 (Codex): serial-only undo record, the very same recorder answers -> restored
$step = @{ type = 'nvr-net'; how = 'isapi'; kind = 'nvr'; brand = 'hik'; dev_mac = ''; dev_serial = ''; old_ip = '192.168.1.18'; new_ip = '192.168.1.20'; old_mask = '255.255.255.0'; old_gw = '192.168.1.1'; old_dns1 = '8.8.8.8'; old_dns2 = '1.1.1.1'; old_addressing = 'static'; done = $true; attempted = $true; result = 'done' }
$d = New-SimDev 'NVR' $A; $step.dev_serial = $d.serial; $script:sim.devs = @{ '192.168.1.20' = $d }
$res.F = Run-Main 'Rollback' (New-Rb @($step)); $res.F | Add-Member -NotePropertyName at -NotePropertyValue (@($script:sim.devs.Keys) -join ',')
# F24 twin: serial-only record, a DIFFERENT recorder (other serial) answers -> nothing sent
$o2 = New-SimDev 'NVR' $B; $script:sim.devs = @{ '192.168.1.20' = $o2 }
$res.G = Run-Main 'Rollback' (New-Rb @($step))
# F24 twin: no MAC and no serial saved -> nothing sent
$s2 = $step.Clone(); $s2.dev_serial = ''; $script:sim.devs = @{ '192.168.1.20' = (New-SimDev 'NVR' $A) }
$res.H = Run-Main 'Rollback' (New-Rb @($s2))
# class B: the recorder's gateway changes AFTER the plan was shown and YES typed -> nothing sent, named
$d = New-SimDev 'NVR' $A; $d.gw = '192.168.1.254'; $script:sim.devs = @{ '192.168.1.20' = $d }
$script:afterYes = { $script:sim.devs['192.168.1.20'].gw = '192.168.1.77' }
$res.I = Run-Main 'Fix' $null; $script:afterYes = $null
# class A twin: forward move target taken AFTER the plan (another device now answers there) -> nothing sent
$d = New-SimDev 'NVR' $A; $d.addressing = 'dynamic'; $d.gw = '192.168.1.254'; $script:sim.devs = @{ '192.168.1.20' = $d }
$script:afterYes = { $x = New-SimDev 'IPCamera' $B; $x.sadp = $false; $script:sim.devs['192.168.1.19'] = $x }
$res.J = Run-Main 'Fix' $null; $script:afterYes = $null
# control: same forward fix with nothing changed after YES -> done
$d = New-SimDev 'NVR' $A; $d.gw = '192.168.1.254'; $script:sim.devs = @{ '192.168.1.20' = $d }
$res.K = Run-Main 'Fix' $null; $res.K | Add-Member -NotePropertyName gw -NotePropertyValue $d.gw
Out-Result $res
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false 'main driver ran' $o } else {
    $nw = { param($r) @($r.writes | Where-Object { $_ -like 'net *' }).Count }
    Check ($j.A.mode -eq 'dynamic' -and $j.A.u.code -eq 0 -and (& $nw $j.A.u) -eq 1) 'F10 (Codex repro) DHCP recorder (ISAPI "dynamic"): Undo puts it back on DHCP (2.2.18 made it a fixed address)' ('mode now ' + $j.A.mode + ' saved ' + $j.A.savedMode + ' | ' + $j.A.u.code + ' ' + $j.A.u.said)
    Check ($j.B.u.code -ne 0 -and $j.B.u.said -notmatch '(?m)^Done\.' -and $j.B.u.said -match 'NOT CHECKED') 'F10 twin: DHCP Undo, recorder not found again by its MAC: NOT CHECKED, not "Done.", exit not 0' ([string]$j.B.u.code + ' ' + $j.B.u.said)
    Check ($j.C.u.code -eq 0 -and $j.C.mode -eq 'dynamic' -and $j.C.at -eq '192.168.1.150' -and $j.C.u.said -match 'found again by its MAC at 192\.168\.1\.150') 'F10 control: DHCP Undo, found again by MAC at the router-given address and read back DHCP: done' ([string]$j.C.u.code + ' at ' + $j.C.at + ' ' + $j.C.u.said)
    Check ($j.D.u.code -ne 0 -and $j.D.u.said -notmatch '(?m)^Done\.' -and $j.D.u.said -match 'not DHCP') 'F10 twin: the recorder accepts the DHCP change but reads back a fixed address: NOT CHECKED, not "Done."' ([string]$j.D.u.code + ' ' + $j.D.u.said)
    Check ($j.E.dns1 -eq '' -and $j.E.dns2 -eq '' -and $j.E.u.code -eq 0) 'F11 (Codex repro) the recorder had NO DNS: Undo puts empty DNS back (2.2.18 kept 8.8.8.8 / 1.1.1.1)' ('dns now [' + $j.E.dns1 + '] [' + $j.E.dns2 + '] | ' + $j.E.u.code + ' ' + $j.E.u.said)
    Check ($j.F.code -eq 0 -and (& $nw $j.F) -eq 1 -and $j.F.at -eq '192.168.1.18') 'F24 (Codex repro) serial-only undo record, the same recorder (exact serial): restored, exit 0 (2.2.18: exit 4, nothing sent)' ([string]$j.F.code + ' at ' + $j.F.at + ' ' + $j.F.said)
    Check ($j.G.code -ne 0 -and (& $nw $j.G) -eq 0 -and $j.G.said -match 'DIFFERENT') 'F24 twin: serial-only record, a recorder with ANOTHER serial answers: nothing sent, named, NOT RESTORED' ([string]$j.G.code + ' ' + $j.G.said)
    Check ($j.H.code -ne 0 -and (& $nw $j.H) -eq 0) 'F24 twin: neither MAC nor serial saved: nothing sent, never by address' ([string]$j.H.code + ' ' + $j.H.said)
    Check ($j.I.code -ne 0 -and (& $nw $j.I) -eq 0 -and $j.I.said -notmatch '(?m)^Done\.' -and $j.I.said -match 'changed after the plan') 'class B: the recorder''s settings change after the plan and YES: read again, nothing sent, named, not "Done."' ([string]$j.I.code + ' ' + (@($j.I.writes) -join ';') + ' ' + $j.I.said)
    Check ($j.J.code -ne 0 -and (& $nw $j.J) -eq 0 -and $j.J.said -match 'now used by another device') 'class A twin: forward move - the target address is taken after YES: checked right before the write, nothing sent' ([string]$j.J.code + ' ' + (@($j.J.writes) -join ';') + ' ' + $j.J.said)
    Check ($j.K.code -eq 0 -and (& $nw $j.K) -eq 1 -and $j.K.gw -eq '192.168.1.1' -and $j.K.said -match '(?m)^Done\.') 'control: an ordinary forward fix (nothing changed after YES) is still written, read back and Done' ([string]$j.K.code + ' ' + $j.K.said)
  }

  Write-Host 'F12 / F06 / F11 ONVIF / F10 Uniview + ONVIF / F09 / F05: the real functions with stand-ins around them'
  $o = Invoke-Driver 'fn' ($pre + "`n" + @'
$res = [ordered]@{}
# F12 (Codex repro): the read-back answer has no address and no mode
$origRead = ${function:Read-FnIdentity}
function Read-FnIdentity { return @{ why = ''; dev = [pscustomobject]@{ brand = 'hik'; login = 'ok'; net_read = $true; net_ip = ''; addressing = ''; mask = '255.255.255.0'; gw = '192.168.1.1'; dns1 = '8.8.8.8'; dns2 = '1.1.1.1' } } }
$res.A = [string](Get-FnNetReadBackWhy '192.168.1.20' $A 'nvr' 'hik' '255.255.255.0' '192.168.1.1' '8.8.8.8' '1.1.1.1')
# F12 twin: the address is right but the device reads back DHCP after a fixed address was set
function Read-FnIdentity { return @{ why = ''; dev = [pscustomobject]@{ brand = 'hik'; login = 'ok'; net_read = $true; net_ip = '192.168.1.20'; addressing = 'dynamic'; mask = '255.255.255.0'; gw = '192.168.1.1'; dns1 = '8.8.8.8'; dns2 = '1.1.1.1' } } }
$res.B = [string](Get-FnNetReadBackWhy '192.168.1.20' $A 'nvr' 'hik' '255.255.255.0' '192.168.1.1' '8.8.8.8' '1.1.1.1')
# F12 control: everything as set -> ''
function Read-FnIdentity { return @{ why = ''; dev = [pscustomobject]@{ brand = 'hik'; login = 'ok'; net_read = $true; net_ip = '192.168.1.20'; addressing = 'static'; mask = '255.255.255.0'; gw = '192.168.1.1'; dns1 = '8.8.8.8'; dns2 = '1.1.1.1' } } }
$res.C = [string](Get-FnNetReadBackWhy '192.168.1.20' $A 'nvr' 'hik' '255.255.255.0' '192.168.1.1' '8.8.8.8' '1.1.1.1')
Set-Item function:Read-FnIdentity $origRead
# F06 (Codex repro): after the move, the answer at the new address carries no MAC
$script:ow = @(); $script:hw = ''
function Onvif($ip, $body, $cred) { if ($body -match 'Set(Network|DNS)') { $script:ow += ($ip + ' ' + $body) }; if ($body -match 'GetNetworkInterfaces') { return @{ code = 200; body = $(if ($script:hw) { '<GetNetworkInterfacesResponse><tt:HwAddress>' + $script:hw + '</tt:HwAddress></GetNetworkInterfacesResponse>' } else { '<GetNetworkInterfacesResponse/>' }); err = '' } }; $rn = $(if ($body -match 'SetNetworkInterfaces') { 'SetNetworkInterfacesResponse' } elseif ($body -match 'SetNetworkDefaultGateway') { 'SetNetworkDefaultGatewayResponse' } elseif ($body -match 'SetDNS') { 'SetDNSResponse' } else { 'ok' }); return @{ code = 200; body = ('<' + $rn + '/>'); err = '' } }   # 2.2.20: real reply documents (a bare 200 no longer counts)
$cam = [pscustomobject]@{ ip = '192.168.0.50'; mac = $A; kind = 'camera'; onvif_token = 'eth0' }
$z = Onvif-SetNet $cam '192.168.1.50' 24 '192.168.1.1' '8.8.8.8' '1.1.1.1'; $res.D = @{ ok = [bool]$z.ok; note = [string]$z.note; w = @($script:ow) }
# F06 twin: the camera has no MAC on record -> not moved at all
$script:ow = @(); $cam2 = [pscustomobject]@{ ip = '192.168.0.51'; mac = ''; kind = 'camera'; onvif_token = 'eth0' }
$z = Onvif-SetNet $cam2 '192.168.1.51' 24 '192.168.1.1' '8.8.8.8' '1.1.1.1'; $res.E = @{ ok = [bool]$z.ok; w = @($script:ow) }
# F06 control + F11 ONVIF twin: the same camera answers (its MAC); the saved DNS is EMPTY -> gateway set, DNS set with no empty entries
$script:ow = @(); $script:hw = 'c0:56:e3:00:00:01'
$z = Onvif-SetNet $cam '192.168.1.50' 24 '192.168.1.1' '' ''; $res.F = @{ ok = [bool]$z.ok; w = @($script:ow) }
Remove-Item function:Onvif
# F10 Uniview twin: Undo of a Uniview recorder that was on DHCP -> nothing written (2.2.18 wrote a fixed address, then "set DHCP by hand")
$script:uw = @(); $script:ov = @()
function Read-FnIdentity { param($ip, $mac) return @{ why = ''; dev = [pscustomobject]@{ ip = $ip; mac = $mac; brand = $(if ($script:idBrand) { $script:idBrand } else { 'unv' }); kind = 'nvr'; login = 'ok'; onvif = ($script:idBrand -eq 'onvif'); net_xml = ''; net_json = '{}'; dns_json = '{}'; net_read = $true; dns_read = $true; addressing = 'dhcp'; net_ip = $ip; mask = '255.255.255.0'; gw = '192.168.1.1'; dns1 = '8.8.8.8'; dns2 = '1.1.1.1'; platform_read = $true; platform_enabled = $true; onvif_token = 'eth0' } } }
function Unv-Put { [void]($script:uw += 'put'); return @{ ok = $true; note = '' } }
function Onvif-SetNet { [void]($script:ov += 'onvif'); return @{ ok = $true; reboot = $false; note = '' } }
function Onvif-Read { return $true }
$script:sim.devs = @{}
$us = @{ type = 'nvr-net'; how = 'lapi'; kind = 'nvr'; brand = 'unv'; dev_mac = $A; dev_serial = ''; old_ip = '192.168.1.30'; new_ip = '192.168.1.20'; old_mask = '255.255.255.0'; old_gw = '192.168.1.1'; old_dns1 = '8.8.8.8'; old_dns2 = '1.1.1.1'; old_addressing = 'dhcp'; done = $true; attempted = $true; result = 'done' }
$script:idBrand = 'unv'; $r = Run-Main 'Rollback' (New-Rb @($us)); $res.G = @{ code = $r.code; said = $r.said; puts = $script:uw.Count }
# F10 ONVIF twin: Undo of an ONVIF camera that was on DHCP -> nothing written (2.2.18 gave it a fixed address)
$cs = @{ type = 'cam-net'; how = 'onvif'; kind = 'camera'; brand = 'onvif'; dev_mac = $A; dev_serial = ''; channel = ''; old_ip = '192.168.1.64'; new_ip = '192.168.1.30'; old_mask = '255.255.255.0'; old_gw = '192.168.1.1'; old_dns1 = ''; old_dns2 = ''; old_addressing = 'dhcp'; done = $true; attempted = $true; result = 'done' }
$script:idBrand = 'onvif'; $r = Run-Main 'Rollback' (New-Rb @($cs)); $res.H = @{ code = $r.code; said = $r.said; calls = $script:ov.Count }
Out-Result $res
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false 'fn driver ran' $o } else {
    Check ($j.A -match 'NOT CHECKED') 'F12 (Codex repro) read-back without address and mode: NOT CHECKED (2.2.18 returned "matches")' $j.A
    Check ($j.B -match 'addressing') 'F12 twin: read-back gives DHCP after a fixed address was set: NOT what was set (mode compared)' $j.B
    Check ($j.C -eq '') 'F12 control: every setting reads back as set: matches' $j.C
    Check (-not $j.D.ok -and @($j.D.w | Where-Object { $_ -match 'SetNetworkDefaultGateway|SetDNS' }).Count -eq 0) 'F06 (Codex repro) ONVIF move, the answer at the new address has no MAC: gateway / DNS NOT written there, not ok' ((@($j.D.w) -join ' | ') + ' | ' + $j.D.note)
    Check (-not $j.E.ok -and @($j.E.w).Count -eq 0) 'F06 twin: ONVIF camera with no MAC on record: not moved at all (nothing sent)' (@($j.E.w) -join ' | ')
    $sd = @($j.F.w | Where-Object { $_ -match 'SetDNS' }) -join ''
    Check ($j.F.ok -and @($j.F.w | Where-Object { $_ -match 'SetNetworkDefaultGateway' }).Count -eq 1 -and $sd -and $sd -notmatch '<tt:IPv4Address></tt:IPv4Address>') 'F06 control + F11 ONVIF twin: the same camera (its MAC) gets gateway + DNS; an empty saved DNS sends no empty DNS entries' (@($j.F.w) -join ' | ')
    Check ($j.G.puts -eq 0 -and $j.G.code -ne 0 -and $j.G.said -match 'DHCP') 'F10 Uniview twin: Undo of a Uniview recorder that was on DHCP: nothing written, says set DHCP by hand, not Done (2.2.18 wrote a fixed address first)' ('puts ' + $j.G.puts + ' | ' + $j.G.code + ' ' + $j.G.said)
    Check ($j.H.calls -eq 0 -and $j.H.code -ne 0 -and $j.H.said -match 'DHCP') 'F10 ONVIF twin: Undo of an ONVIF camera that was on DHCP: nothing written, says set DHCP by hand (2.2.18 gave it a fixed address)' ('writes ' + $j.H.calls + ' | ' + $j.H.code + ' ' + $j.H.said)
  }

  Write-Host 'F09 / F05 / class C: the PC-side clean-up and the free-address check (real functions, Windows commands stood in for)'
  $o = Invoke-Driver 'pc' ($fnText + "`n" + '$here = ' + (Q (Join-Path $tmp 'pc')) + "`n" + @'
$ErrorActionPreference = 'Continue'; New-Item -ItemType Directory -Force -Path $here | Out-Null
$Mock = $null; $script:sum = New-Object System.Collections.Generic.List[string]; $logFile = Join-Path $here 'log.txt'
function Say { param($t, $c) $script:sum.Add([string]$t) }
function Unregister-ScheduledTask { }
function Register-ScheduledTask { }
function Out-Result($o) { 'JSON=' + ($o | ConvertTo-Json -Compress -Depth 6) }
$res = [ordered]@{}
# F09 (Codex repro): a clean-up journal that is valid JSON but has none of its fields
$tempFile = Join-Path $here 'temp-journal.json'; [IO.File]::WriteAllText($tempFile, '{}')
$z = Invoke-LeftoverCleanup
$res.A = @{ ok = [bool]$z; kept = ((Test-Path $tempFile) -or @(Get-ChildItem -Path $here -Filter '*unreadable*').Count -gt 0) }
# F05 (Codex repro): the adapter's name cannot be read -> nothing written to it
$script:adapterDhcp = 'Disabled'; $script:aw = @()
function Get-NetAdapter { throw 'Cannot read adapter identity' }
function Get-NetIPInterface { return [pscustomobject]@{ Dhcp = $script:adapterDhcp } }
function Set-NetIPInterface { param($InterfaceIndex, $AddressFamily, $Dhcp, $ErrorAction) $script:aw += ('DHCP ' + $Dhcp + ' on ifIndex ' + $InterfaceIndex); $script:adapterDhcp = $Dhcp }
function netsh { $script:aw += ('netsh ' + ($args -join ' ')) }
$probs = @(); Restore-PcSettings ([pscustomobject]@{ alias = 'Original Ethernet'; dhcp = $true; coexistence_before = $null; changed = $false }) 5 ([ref]$probs)
$res.B = @{ w = @($script:aw | Where-Object { $_ -notmatch ' show ' }); p = ($probs -join '; ') }
# class C twin: Test-IpFree with the neighbour table failing (not "not found") -> not free
function Get-NetNeighbor { [CmdletBinding()] param($IPAddress) Write-Error -Message 'Access is denied' -Category PermissionDenied }
$res.C = [bool](Test-IpFree '192.0.2.1')
function Get-NetNeighbor { [CmdletBinding()] param($IPAddress) Write-Error -Message 'No matching MSFT_NetNeighbor objects found by CIM query for instances of the ROOT/StandardCimv2/MSFT_NetNeighbor class' -Category ObjectNotFound }
$res.D = [bool](Test-IpFree '192.0.2.1')
Out-Result $res
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false 'pc driver ran' $o } else {
    Check (-not $j.A.ok -and $j.A.kept) 'F09 (Codex repro) a "{}" clean-up journal: NOT read as "nothing to clean", start blocked, the record kept (2.2.18 deleted it and went on)' ('ok ' + $j.A.ok + ' kept ' + $j.A.kept)
    Check (@($j.B.w).Count -eq 0 -and $j.B.p -match 'NOT put back') 'F05 (Codex repro) the PC adapter name cannot be read: nothing written to it, reported NOT put back (2.2.18 turned DHCP on)' ((@($j.B.w) -join '; ') + ' | ' + $j.B.p)
    Check (-not $j.C) 'class C twin: Test-IpFree - the neighbour table cannot be read: the address is NOT treated as free' ([string]$j.C)
    Check ($j.D) 'control: Test-IpFree - "no entry for that address" is still free' ([string]$j.D)
  }

  Write-Host 'follow-up twins (classic2): coexistence read-back, safety task, firewall record, snapshot Drive copy (real functions, Windows commands stood in for)'
  $o = Invoke-Driver 'pc2' ($fnText + "`n" + '$here = ' + (Q (Join-Path $tmp 'pc2')) + "`n" + @'
$ErrorActionPreference = 'Continue'; New-Item -ItemType Directory -Force -Path $here | Out-Null
$Mock = $null; $script:sum = New-Object System.Collections.Generic.List[string]; $logFile = Join-Path $here 'log.txt'
$cfg = [pscustomobject]@{ temp_ip_hosts = @(253, 252); safety_cleanup_minutes = 30 }
$taskName = 'WireIt FixNVR cleanup'; $tempFile = Join-Path $here 'temp-ips.json'
function Say { param($t, $c) $script:sum.Add([string]$t) }
function Start-Sleep { }
function Out-Result($o) { 'JSON=' + ($o | ConvertTo-Json -Compress -Depth 6) }
function Reset-Pc {
  $script:temps = New-Object System.Collections.Generic.List[object]
  $script:pcChanges = [ordered]@{ coexistence_before = $null; firewall_rule = $false; cleanup_task = $false; ifIndex = $null; alias = $null; guid = $null; dhcp = $null; ip = $null; gw = $null }
  $script:coexNotConfirmed = $false; $script:sum.Clear(); $script:calls = New-Object System.Collections.ArrayList
  $script:coex = 'disabled'; $script:coexTakes = $true; $script:failSave = $false; $script:regFail = $false; $script:fwFail = $false; $script:fwSeen = $null
  Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
}
# Windows commands stood in for (each call is recorded)
function netsh { $a = ($args -join ' '); [void]$script:calls.Add('netsh ' + $a); if ($a -match ' show interface') { return @('Interface Ethernet Parameters', '----', ('DHCP/Static IP coexistence         : ' + $script:coex)) }; if ($a -match 'dhcpstaticipcoexistence=enabled' -and $script:coexTakes) { $script:coex = 'enabled' } }
function New-NetIPAddress { param($InterfaceIndex, $IPAddress, $PrefixLength, $SkipAsSource, $PolicyStore, $ErrorAction) [void]$script:calls.Add('add ' + $IPAddress) }
# 2.2.20 (Codex 2.2.19 R02): every adapter change checks the saved name AND InterfaceGuid first; the stand-in is the saved adapter
function Get-NetAdapter { param($InterfaceIndex, $ErrorAction) return [pscustomobject]@{ Name = 'Ethernet'; InterfaceGuid = '{11111111-2222-3333-4444-555555555555}' } }
function Get-NetIPAddress { param($InterfaceIndex, $IPAddress, $AddressFamily, $ErrorAction) return [pscustomobject]@{ IPAddress = $IPAddress; AddressState = 'Preferred' } }
function Remove-NetIPAddress { param($IPAddress, $InterfaceIndex, $PolicyStore, $Confirm, $ErrorAction) [void]$script:calls.Add('remove ' + $IPAddress) }
function New-ScheduledTaskAction { param($Execute, $Argument) return 'act' }
function New-ScheduledTaskTrigger { param([switch]$Once, $At) return 'trg' }
function New-ScheduledTaskPrincipal { param($UserId, $RunLevel, $LogonType) return 'pr' }
function Register-ScheduledTask { [CmdletBinding()] param($TaskName, $Action, $Trigger, $Principal, [switch]$Force) [void]$script:calls.Add('register ' + $TaskName); if ($script:regFail) { Write-Error -Message 'Access is denied' -Category PermissionDenied } }
function Unregister-ScheduledTask { param($TaskName, $Confirm, $ErrorAction) [void]$script:calls.Add('unregister ' + $TaskName) }
function New-NetFirewallRule { [CmdletBinding()] param($DisplayName, $Direction, $Protocol, $LocalPort, $Action, $Profile)
  $onDisk = $null; try { $onDisk = [bool]((Get-Content -Raw -LiteralPath $tempFile | ConvertFrom-Json).pc.firewall_rule) } catch {}
  $script:fwSeen = $onDisk; [void]$script:calls.Add('firewall add'); if ($script:fwFail) { Write-Error -Message 'The rule could not be added (policy)' -Category PermissionDenied } }
$origSaveJson = ${function:Save-Json}
function Save-Json($obj, [string]$path) { if ($script:failSave) { throw 'disk full (test)' }; & $origSaveJson $obj $path }
function Saved-Pc { try { return (Get-Content -Raw -LiteralPath $tempFile | ConvertFrom-Json).pc } catch { return $null } }
$pc = [pscustomobject]@{ ifIndex = 7; alias = 'Ethernet'; guid = '{11111111-2222-3333-4444-555555555555}'; dhcp = $true; ip = '192.168.1.105'; prefix = 24; gw = '192.168.1.1' }
$res = [ordered]@{}
# 1. coexistence switched on but Windows does not confirm it -> no temporary address, now or later in the run
Reset-Pc; $script:coexTakes = $false
$a1 = Add-TempIp '192.168.0' $pc @(); $a2 = Add-TempIp '10.1.1' $pc @()
$res.A = @{ ip1 = [string]$a1; ip2 = [string]$a2; adds = @($script:calls | Where-Object { $_ -like 'add *' }).Count; sets = @($script:calls | Where-Object { $_ -match '=enabled' }).Count; said = (@($script:sum) -join ' | ') }
# 1. control: the setting reads back enabled -> the temporary address is added
Reset-Pc; $a1 = Add-TempIp '192.168.0' $pc @()
$res.B = @{ ip1 = [string]$a1; adds = @($script:calls | Where-Object { $_ -like 'add *' }).Count; task = [bool]$script:pcChanges.cleanup_task }
# 2. Register-ScheduledTask fails (a non-terminating Windows error) -> the task is NOT recorded as set
Reset-Pc; $script:regFail = $true; Set-SafetyTask
$res.C = @{ flag = [bool]$script:pcChanges.cleanup_task; saved = [string]((Saved-Pc).cleanup_task) }
# 7. the task is set but the record cannot be saved afterwards -> said (not ignored), the task is kept (no unregister)
Reset-Pc; $origWts = ${function:Write-TempState}; function Write-TempState { return $false }
Set-SafetyTask; Set-Item function:Write-TempState $origWts
$res.D = @{ flag = [bool]$script:pcChanges.cleanup_task; said = (@($script:sum) -join ' | '); calls = (@($script:calls) -join ', ') }
# 7. control: register + save both work -> recorded on disk, nothing said
Reset-Pc; Set-SafetyTask; $res.E = @{ flag = [bool]$script:pcChanges.cleanup_task; saved = [string]((Saved-Pc).cleanup_task); said = (@($script:sum) -join ' | ') }
# 3. the firewall record cannot be saved -> no rule is added
Reset-Pc; $script:failSave = $true; Open-Firewall; $script:failSave = $false
$res.F = @{ adds = @($script:calls | Where-Object { $_ -eq 'firewall add' }).Count; flag = [bool]$script:pcChanges.firewall_rule }
# 3. the rule add fails -> the flag is reset and saved again
Reset-Pc; $script:fwFail = $true; Open-Firewall
$res.G = @{ adds = @($script:calls | Where-Object { $_ -eq 'firewall add' }).Count; flag = [bool]$script:pcChanges.firewall_rule; saved = [string]((Saved-Pc).firewall_rule) }
# 3. control / order: the record says "rule added" on disk BEFORE the rule is added
Reset-Pc; Open-Firewall
$res.H = @{ seenOnDisk = [string]$script:fwSeen; flag = [bool]$script:pcChanges.firewall_rule; saved = [string]((Saved-Pc).firewall_rule) }
Out-Result $res
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false 'pc2 driver ran' $o } else {
    Check ($j.A.adds -eq 0 -and -not $j.A.ip1 -and -not $j.A.ip2 -and $j.A.sets -le 1 -and $j.A.said -match 'not confirm') 'class F twin: Add-TempIp - DHCP+static coexistence switched on but Windows does not read it back as enabled: NO temporary address, and none for the rest of the run (2.2.18 added the address anyway)' ('adds ' + $j.A.adds + ' sets ' + $j.A.sets + ' ip1 ' + $j.A.ip1 + ' ip2 ' + $j.A.ip2 + ' | ' + $j.A.said)
    Check ($j.B.adds -eq 1 -and $j.B.ip1 -eq '192.168.0.253' -and $j.B.task) 'control: Add-TempIp - coexistence reads back enabled: the temporary address is added, safety task set' ('adds ' + $j.B.adds + ' ip ' + $j.B.ip1 + ' task ' + $j.B.task)
    Check (-not $j.C.flag -and $j.C.saved -ne 'True') 'class F twin: Set-SafetyTask - Register-ScheduledTask fails: the safety task is NOT recorded as set (2.2.18 swallowed the error and recorded it)' ('flag ' + $j.C.flag + ' saved ' + $j.C.saved)
    Check ($j.D.flag -and $j.D.said -match 'could not be updated' -and $j.D.calls -notmatch 'unregister') 'class F twin: Set-SafetyTask - task set but its record cannot be saved: said on screen (not ignored), the task is kept as the safety net' ('flag ' + $j.D.flag + ' | ' + $j.D.said + ' | ' + $j.D.calls)
    Check ($j.E.flag -and $j.E.saved -eq 'True' -and -not $j.E.said) 'control: Set-SafetyTask - task set and recorded on disk, nothing to warn about' ('flag ' + $j.E.flag + ' saved ' + $j.E.saved + ' | ' + $j.E.said)
    Check ($j.F.adds -eq 0 -and -not $j.F.flag) 'class E twin: Open-Firewall - the clean-up record cannot be saved first: NO firewall rule added (2.2.18 added it first, then a failed save left a rule nobody knew about)' ('adds ' + $j.F.adds + ' flag ' + $j.F.flag)
    Check ($j.G.adds -eq 1 -and -not $j.G.flag -and $j.G.saved -eq 'False') 'class E twin: Open-Firewall - the rule add fails: the flag is reset and the record saved again (says no rule)' ('adds ' + $j.G.adds + ' flag ' + $j.G.flag + ' saved ' + $j.G.saved)
    Check ($j.H.seenOnDisk -eq 'True' -and $j.H.flag -and $j.H.saved -eq 'True') 'class E twin: Open-Firewall - the record says "rule added" on disk BEFORE the rule is added' ('on disk when added: ' + $j.H.seenOnDisk + ' flag ' + $j.H.flag + ' saved ' + $j.H.saved)
  }

  Write-Host 'follow-up twins (classic2): snapshot copy to Drive, platform step after YES (real Invoke-Main)'
  $o = Invoke-Driver 'main2' ($pre + "`n" + @'
$res = [ordered]@{}
$cfg | Add-Member -NotePropertyName snapshot_subfolder -NotePropertyValue 'Docs' -Force
$cfg | Add-Member -NotePropertyName snapshot_roots -NotePropertyValue @() -Force
$cfg | Add-Member -NotePropertyName safety_cleanup_minutes -NotePropertyValue 30 -Force
$RouterModel = ''; $DhcpRange = ''; $Site = 'Test Site'
$drive = Join-Path $here 'drive'; New-Item -ItemType Directory -Force -Path $drive | Out-Null
function Find-SiteFolder([string]$site) { return $drive }
function Snap-Run {
  $d = New-SimDev 'NVR' $A; $script:sim.devs = @{ '192.168.1.20' = $d }
  Get-ChildItem -LiteralPath $drive -Recurse -File -ErrorAction SilentlyContinue | Remove-Item -Force
  $r = Run-Main 'Snapshot' $null
  return @{ said = $r.said; code = $r.code; copies = @(Get-ChildItem -LiteralPath $drive -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue).Count }
}
$origCopy = Get-Command Copy-Item -CommandType Cmdlet
# 4. the Drive copy reports an error (Drive not running) -> NOT "Also saved"; the copy-by-hand line
function Copy-Item { [CmdletBinding()] param([Parameter(Position = 0)]$Path, [Parameter(Position = 1)]$Destination, $LiteralPath) Write-Error -Message 'The cloud file provider is not running' -Category ResourceUnavailable }
$res.A = Snap-Run
# 4. the copy "works" with no error, but the file is not there afterwards -> NOT "Also saved"
function Copy-Item { [CmdletBinding()] param([Parameter(Position = 0)]$Path, [Parameter(Position = 1)]$Destination, $LiteralPath) }
$res.B = Snap-Run
Remove-Item function:Copy-Item
# 4. control: a real copy -> "Also saved", the file is in the Drive folder
$res.C = Snap-Run
# 5. platform access OFF at the plan; after YES the setting cannot be read -> nothing sent
$d = New-SimDev 'NVR' $A; $d.ezviz = 'off'; $script:sim.devs = @{ '192.168.1.20' = $d }
$script:afterYes = { $script:sim.devs['192.168.1.20'].ezviz = 'fail' }
$r = Run-Main 'Fix' $null; $script:afterYes = $null
$res.D = @{ said = $r.said; code = $r.code; puts = @($r.writes | Where-Object { $_ -like 'platform *' }).Count }
# 5. platform access OFF at the plan; someone turns it on before the step -> read now: already on, no write
$d = New-SimDev 'NVR' $A; $d.ezviz = 'off'; $script:sim.devs = @{ '192.168.1.20' = $d }
$script:afterYes = { $script:sim.devs['192.168.1.20'].ezviz = 'on' }
$r = Run-Main 'Fix' $null; $script:afterYes = $null
$res.E = @{ said = $r.said; code = $r.code; puts = @($r.writes | Where-Object { $_ -like 'platform *' }).Count }
# 5. control: platform access off, still off after YES -> turned on (one write)
$d = New-SimDev 'NVR' $A; $d.ezviz = 'off'; $script:sim.devs = @{ '192.168.1.20' = $d }
$r = Run-Main 'Fix' $null
$res.F = @{ said = $r.said; code = $r.code; puts = @($r.writes | Where-Object { $_ -like 'platform *' }).Count; now = [string]$d.ezviz }
Out-Result $res
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false 'main2 driver ran' $o } else {
    Check ($j.A.said -notmatch 'Also saved' -and $j.A.said -match 'by hand') 'class F twin: Snapshot copy to the site''s Drive folder fails with an error: NOT "Also saved", says copy it by hand (2.2.18 said "Also saved")' ($j.A.said)
    Check ($j.B.said -notmatch 'Also saved' -and $j.B.said -match 'by hand' -and $j.B.copies -eq 0) 'class F twin: Snapshot copy gives no error but the file is not in the Drive folder: NOT "Also saved"' ('copies ' + $j.B.copies + ' | ' + $j.B.said)
    Check ($j.C.said -match 'Also saved' -and $j.C.copies -eq 1) 'control: Snapshot copy really made: "Also saved", file in the Drive folder' ('copies ' + $j.C.copies + ' | ' + $j.C.said)
    Check ($j.D.puts -eq 0 -and $j.D.said -match 'platform access setting could not be read now' -and $j.D.code -ne 0) 'class B/C twin: platform step - the setting cannot be read after YES: nothing sent, named, not a clean finish (2.2.18 went on to build the change from the empty read and stopped with a script error)' ('puts ' + $j.D.puts + ' code ' + $j.D.code + ' | ' + $j.D.said)
    Check ($j.E.puts -eq 0 -and $j.E.said -match 'already on') 'class B twin: platform step - already on when read after YES: no write (2.2.18 wrote it again from the plan-time read)' ('puts ' + $j.E.puts + ' code ' + $j.E.code + ' | ' + $j.E.said)
    Check ($j.F.puts -eq 1 -and $j.F.now -eq 'on') 'control: platform step - still off after YES: turned on (one write)' ('puts ' + $j.F.puts + ' now ' + $j.F.now + ' code ' + $j.F.code + ' | ' + $j.F.said)
  }

  # CamReset default-try record (class E twin), RUN for real: Find-Cameras.ps1 in a copy of CamReset, discovery answers from a
  # test file, a local listener so the sweep marks the camera reachable; the one default try goes to 127.0.0.70:80 (nothing
  # there = "no answer"), so a try that happened is visible in DefaultLoginWorks. Nothing on the network is contacted.
  Write-Host 'CamReset class E twin: the once-a-day default-try record (Find-Cameras.ps1 run for real)'
  $crSrc = Join-Path (Split-Path -Parent (Split-Path -Parent $fnvPath)) 'CamReset'
  $lis = $null
  try {
    $lis = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse('127.0.0.70'), 0); $lis.Start(); $lport = ([Net.IPEndPoint]$lis.LocalEndpoint).Port
    $probe = '<?xml version="1.0"?><SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"><SOAP-ENV:Body><d:ProbeMatches><d:ProbeMatch><d:Scopes>onvif://www.onvif.org/type/video_encoder onvif://www.onvif.org/name/Uniview onvif://www.onvif.org/hardware/IPC2124LB-SF28KM-G</d:Scopes><d:XAddrs>http://127.0.0.70/onvif/device_service</d:XAddrs></d:ProbeMatch></d:ProbeMatches></SOAP-ENV:Body></SOAP-ENV:Envelope>'
    function Invoke-Fc([string]$name, [scriptblock]$prep) {
      $dir = Join-Path $tmp ('cr-' + $name); New-Item -ItemType Directory -Force -Path $dir | Out-Null
      Copy-Item -Path (Join-Path $crSrc '*') -Destination $dir -Recurse -Force
      [IO.File]::WriteAllText((Join-Path $dir 'config.json'), '{ "univiewTryDefault": true, "listenSeconds": 9 }')
      [IO.File]::WriteAllText((Join-Path $dir 'answers.json'), (ConvertTo-Json -InputObject @([ordered]@{ From = '127.0.0.70'; Text = $probe }) -Compress))
      New-Item -ItemType Directory -Force -Path (Join-Path $dir 'state') | Out-Null
      $ledger = Join-Path (Join-Path $dir 'state') 'default-tried.txt'   # the file Find-Cameras.ps1 keeps (state\default-tried.txt)
      if ($prep) { & $prep $ledger }
      $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
      try { $null = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $dir 'Find-Cameras.ps1') -NoMulticast -NoPing -SweepTargets '127.0.0.70' -SweepPorts $lport -TestAnswersFile (Join-Path $dir 'answers.json') 2>&1 | Out-String } finally { $ErrorActionPreference = $prev }
      $dev = $null; try { $dev = @((Get-Content -Raw -LiteralPath (Join-Path $dir 'out/latest.json') | ConvertFrom-Json).devices | Where-Object { $_.IP -eq '127.0.0.70' })[0] } catch {}
      $lines = @(); try { if (Test-Path -LiteralPath $ledger -PathType Leaf) { $lines = @(Get-Content -LiteralPath $ledger -ErrorAction Stop) } } catch {}
      return [pscustomobject]@{ dl = $(if ($dev) { [string]$dev.DefaultLoginWorks } else { 'NO DEVICE IN OUTPUT' }); next = $(if ($dev) { [string]$dev.NextStep } else { '' }); lines = $lines }
    }
    $today = '127.0.0.70 ' + (Get-Date -Format 'yyyy-MM-dd')
    # unreadable record: the record path exists but cannot be read (here: a folder where the file should be)
    $u = Invoke-Fc 'unreadable' { param($l) New-Item -ItemType Directory -Force -Path $l | Out-Null }
    Check ($u.dl -match '^NOT CHECKED' -and $u.dl -notmatch 'no answer') 'CamReset class E twin (run): the default-try record exists but cannot be read: NO login try, DefaultLoginWorks NOT CHECKED (2.2.18 read it as "never tried" and tried)' ($u.dl + ' | ' + $u.next)
    # unwritable record: readable, no try today, but the try cannot be written down first
    $isWin = ([IO.Path]::DirectorySeparatorChar -eq '\')
    if ($isWin) { Deferred 'CamReset class E twin (run): read-only default-try record (needs a Windows ACL stand-in)' } else {
      $w = Invoke-Fc 'unwritable' { param($l) [IO.File]::WriteAllText($l, "10.0.0.9 2020-01-01 no (401)`n"); & chmod 0444 $l }
      Check ($w.dl -match '^NOT CHECKED' -and @($w.lines | Where-Object { $_ -like ($today + '*') }).Count -eq 0) 'CamReset class E twin (run): the try cannot be written down BEFORE it is made (record read-only): NO login try, NOT CHECKED (2.2.18 tried without a record)' ($w.dl + ' | lines: ' + (@($w.lines) -join ' / '))
      try { & chmod 0644 (Join-Path (Join-Path (Join-Path $tmp 'cr-unwritable') 'state') 'default-tried.txt') } catch {}
    }
    # control: a normal record -> one try, written down (before it, then its result); the next run that day makes no second try
    $c1 = Invoke-Fc 'normal' $null
    $c1lines = @($c1.lines | Where-Object { $_ -like ($today + '*') })
    Check ($c1.dl -match 'no answer' -and $c1lines.Count -ge 1 -and $c1lines[0] -eq $today) 'control (run): normal record - one default try made and written down first (then its result)' ($c1.dl + ' | lines: ' + (@($c1.lines) -join ' / '))
  } finally { if ($lis) { try { $lis.Stop() } catch {} } }

  Deferred 'Windows PowerShell 5.1 running these paths'
  Deferred 'real Get-NetNeighbor / Get-NetIPAddress "not found" error category, real netsh coexistence text'
  Deferred 'a real Hikvision DHCP Undo found again by SADP; real Uniview LAPI DHCP field names; real ONVIF HwAddress after a move'
} finally {
  Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}
Write-Host ''
Write-Host ('Test-Fix2219Classic: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:deferred + ' deferred')
if ($script:fail) { exit 1 } else { exit 0 }
