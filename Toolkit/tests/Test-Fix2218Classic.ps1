<# Test-Fix2218Classic.ps1 - tests for WireIt Toolkit 2.2.18 (Nov 11 2026), the classic Fix NVR part of Codex's review of 2.2.17
   (head c3c0c69), finding 1 (P1) and the classic half of finding 5 (P2), plus the classic twins of findings 2 and 3.
   #1  Rollback (Undo) fell back from the saved MAC to "whatever answers at the saved address", re-read it (Hik-Read overwrote the
       saved MAC with the new one) and wrote to it: another recorder that shares the site password took the old recorder's network
       settings, and the run said "Done." / exit 0. 2.2.18: every write (Undo AND forward) first reads the device at the address on a
       fresh record and goes ahead only when its own answer gives the saved MAC (and serial when saved); readers reject a different MAC;
       an Undo that could not put a step back says NOT RESTORED, never "Done.", never exit 0.
   #2 twin  An NVR camera-list (channel) step is written only while the channel still points at the camera the step expects, and is
       read back after the write; a channel that now belongs to another camera is left alone.
   #3 twin  A camera / NVR network move counts only when the device (by MAC) reads back every requested setting at the new address.
   #5  An unreadable clean-up record was renamed and forgotten: the next start carried on. 2.2.18: the renamed file blocks every start
       until a checked recovery (PC restarted since, no temporary address left, connection working) clears it.
   Every check RUNS the real FixNVR.ps1 functions (Invoke-Main, Hik-Read, Read-Dev, Hik-SetNet, Hik-SetChannel, Invoke-LeftoverCleanup)
   in a child PowerShell; only the recorder/camera web answers, discovery and the Windows network commands are stood in for.
   Codex's own reproduction scripts were not sent to us; these are written from the review's evidence (expected MAC ...01, the device
   at .20 says ...99, Undo sent a PUT moving .20 to .18 and said "Done.").
   NEEDS WINDOWS / REAL DEVICE CHECK (counted DEFERRED, never PASS): real Hikvision / ONVIF answers, a real PC restart.
   FIX2218CLASSIC_FILE (tests only) = run against another copy of FixNVR.ps1 (old-code proof: on 2.2.17 the finding checks FAIL). #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$fnvPath = $(if ($env:FIX2218CLASSIC_FILE) { $env:FIX2218CLASSIC_FILE } else { Join-Path $repo 'FixNVR/FixNVR.ps1' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2218classic-' + [guid]::NewGuid().ToString('N'))
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
  # The real Invoke-Main + real readers/writers; $script:sim.devs is the network: ip -> recorder/camera (what its web pages answer)
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
  if ($path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = ('<DeviceInfo><deviceName>x</deviceName><model>' + $d.model + '</model><serialNumber>' + $d.serial + '</serialNumber><macAddress>' + $d.mac + '</macAddress><firmwareVersion>V4.1</firmwareVersion><deviceType>' + $d.type + '</deviceType></DeviceInfo>'); err = '' } }
  if ($path -eq '/ISAPI/System/Network/interfaces') { return @{ code = 200; body = ('<NetworkInterfaceList><NetworkInterface><id>1</id><IPAddress><ipAddress>' + $ip + '</ipAddress></IPAddress></NetworkInterface></NetworkInterfaceList>'); err = '' } }
  if ($path -eq '/ISAPI/System/Network/interfaces/1/ipAddress' -and $method -eq 'GET') { return @{ code = 200; body = ('<IPAddress><ipVersion>v4</ipVersion><addressingType>' + $d.addressing + '</addressingType><ipAddress>' + $ip + '</ipAddress><subnetMask>' + $d.mask + '</subnetMask><DefaultGateway><ipAddress>' + $d.gw + '</ipAddress></DefaultGateway><PrimaryDNS><ipAddress>' + $d.dns1 + '</ipAddress></PrimaryDNS><SecondaryDNS><ipAddress>' + $d.dns2 + '</ipAddress></SecondaryDNS></IPAddress>'); err = '' } }
  if ($path -eq '/ISAPI/System/Network/interfaces/1/ipAddress' -and $method -eq 'PUT') {
    $to = X $body 'ipAddress'; [void]$script:sim.writes.Add('net ' + $ip + ' (' + $d.mac + ') -> ' + $to)
    $d.addressing = X $body 'addressingType'; $d.mask = X $body 'subnetMask'
    if (-not $d.keepGw) { $d.gw = [regex]::Match($body, '<DefaultGateway><ipAddress>([^<]*)<').Groups[1].Value }
    $p1 = [regex]::Match($body, '<PrimaryDNS><ipAddress>([^<]*)<'); if ($p1.Success) { $d.dns1 = $p1.Groups[1].Value }
    $p2 = [regex]::Match($body, '<SecondaryDNS><ipAddress>([^<]*)<'); if ($p2.Success) { $d.dns2 = $p2.Groups[1].Value }
    if ($to -and $to -ne $ip) { $script:sim.devs.Remove($ip); $script:sim.devs[$to] = $d }
    return (Ok)
  }
  if ($path -eq '/ISAPI/System/Network/EZVIZ') { return @{ code = 200; body = '<EZVIZ><enabled>true</enabled><registerStatus>true</registerStatus></EZVIZ>'; err = '' } }
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
    if ($body -match 'GetNetworkInterfaces') { return @{ code = 200; body = ('<tds:GetNetworkInterfacesResponse><tds:NetworkInterfaces token="eth0"><tt:Info><tt:HwAddress>' + $d.mac + '</tt:HwAddress></tt:Info><tt:IPv4><tt:Config><tt:Manual><tt:Address>' + $ip + '</tt:Address><tt:PrefixLength>24</tt:PrefixLength></tt:Manual></tt:Config></tt:IPv4></tds:NetworkInterfaces></tds:GetNetworkInterfacesResponse>'); err = '' } }
    if ($body -match 'SetNetworkInterfaces') { [void]$script:sim.writes.Add('onvif-net ' + $ip); return @{ code = 200; body = '<tds:SetNetworkInterfacesResponse><tds:RebootNeeded>false</tds:RebootNeeded></tds:SetNetworkInterfacesResponse>'; err = '' } }
    if ($body -match 'SetNetworkDefaultGateway') { [void]$script:sim.writes.Add('onvif-gw ' + $ip + ' (' + $d.mac + ')'); return @{ code = 200; body = '<ok/>'; err = '' } }
    if ($body -match 'SetDNS') { [void]$script:sim.writes.Add('onvif-dns ' + $ip + ' (' + $d.mac + ')'); return @{ code = 200; body = '<ok/>'; err = '' } }
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
'@
  Write-Host '#1 classic Undo: a different recorder at the saved address is NOT written to; NOT RESTORED, never "Done." / exit 0'
  $o = Invoke-Driver 'undo' ($pre + "`n" + @'
$res = [ordered]@{}
$netStep = @{ type = 'nvr-net'; how = 'isapi'; kind = 'nvr'; brand = 'hik'; dev_mac = $A; old_ip = '192.168.1.18'; new_ip = '192.168.1.20'; old_mask = '255.255.255.0'; new_mask = '255.255.255.0'; old_gw = '192.168.1.1'; new_gw = '192.168.1.1'; old_dns1 = '8.8.8.8'; old_dns2 = '1.1.1.1'; new_dns1 = '8.8.8.8'; new_dns2 = '1.1.1.1'; old_addressing = 'static'; done = $true; attempted = $true; result = 'done' }
# A. Codex's case: the undo file says recorder ...01 was moved .18 -> .20; now ANOTHER recorder (...99, same password) answers at .20
$script:sim.devs = @{ '192.168.1.20' = (New-SimDev 'NVR' $B) }
$res.A = Run-Main 'Rollback' (New-Rb @($netStep)); $res.A | Add-Member -NotePropertyName left -NotePropertyValue (@($script:sim.devs.Keys) -join ',')
# A2. the same, but the other recorder is not found by discovery (only the address answers)
$script:sim.devs = @{ '192.168.1.20' = (New-SimDev 'NVR' $B) }; $script:sim.devs['192.168.1.20'].sadp = $false
$res.A2 = Run-Main 'Rollback' (New-Rb @($netStep))
# B. control: the saved recorder (...01) is at .20 -> moved back to .18, read back there, Done / exit 0
$script:sim.devs = @{ '192.168.1.20' = (New-SimDev 'NVR' $A) }
$res.B = Run-Main 'Rollback' (New-Rb @($netStep)); $res.B | Add-Member -NotePropertyName left -NotePropertyValue (@($script:sim.devs.Keys) -join ',')
# C. the saved recorder answers, accepts the PUT, but keeps its old gateway -> NOT restored (settings read back)
$nb = New-SimDev 'NVR' $A '192.168.1.1'; $nb.keepGw = $true; $nb.gw = '192.168.1.254'
$script:sim.devs = @{ '192.168.1.20' = $nb }
$res.C = Run-Main 'Rollback' (New-Rb @($netStep))
# D. camera network Undo: a different camera (...99) answers at the address this run moved camera ...01 to
$camStep = @{ type = 'cam-net'; how = 'isapi'; kind = 'camera'; brand = 'hik'; dev_mac = $A; channel = '1'; old_ip = '192.168.1.64'; new_ip = '192.168.1.30'; old_mask = '255.255.255.0'; new_mask = '255.255.255.0'; old_gw = '192.168.1.1'; new_gw = '192.168.1.1'; old_dns1 = '8.8.8.8'; old_dns2 = '1.1.1.1'; old_addressing = 'static'; done = $true; attempted = $true; result = 'done' }
$script:sim.devs = @{ '192.168.1.30' = (New-SimDev 'IPCamera' $B) }
$res.D = Run-Main 'Rollback' (New-Rb @($camStep))
# E. camera Undo of a move that was SENT but not confirmed: a DIFFERENT camera answers at the old address (2.2.17: "it never moved",
#    from an answer at the address alone) and nothing answers at the new one -> NOT restored, not "Done."
$camStep2 = $camStep.Clone(); $camStep2.done = $false
$script:sim.devs = @{ '192.168.1.64' = (New-SimDev 'IPCamera' $B) }
$res.E = Run-Main 'Rollback' (New-Rb @($camStep2))
# E2. control: the SAME camera (...01) is still at the old address -> "it never moved" (checked by MAC), Done
$script:sim.devs = @{ '192.168.1.64' = (New-SimDev 'IPCamera' $A) }
$res.E2 = Run-Main 'Rollback' (New-Rb @($camStep2))
# F. NVR camera-list Undo: channel D1 was pointed at .50 by this run; it now points at a different camera .51 -> left alone
$chStep = @{ type = 'nvr-channel'; how = 'isapi'; kind = 'nvr'; brand = 'hik'; dev_mac = $A; nvr_ip = '192.168.1.20'; channel = '1'; old_ip = '192.168.1.64'; new_ip = '192.168.1.50'; done = $true; attempted = $true; result = 'done' }
$nf = New-SimDev 'NVR' $A; $nf.channels = @(@{ id = '1'; ip = '192.168.1.51' }); $script:sim.devs = @{ '192.168.1.20' = $nf; '192.168.1.51' = (New-SimDev 'IPCamera' 'C0-56-E3-00-00-51') }
$res.F = Run-Main 'Rollback' (New-Rb @($chStep)); $res.F | Add-Member -NotePropertyName ch -NotePropertyValue ([string]$nf.channels[0].ip)
# G. control: D1 still points at .50 -> put back to .64, read back, Done
$ng = New-SimDev 'NVR' $A; $ng.channels = @(@{ id = '1'; ip = '192.168.1.50' }); $script:sim.devs = @{ '192.168.1.20' = $ng }
$res.G = Run-Main 'Rollback' (New-Rb @($chStep)); $res.G | Add-Member -NotePropertyName ch -NotePropertyValue ([string]$ng.channels[0].ip)
# H. channel Undo where the recorder at the NVR's address is a DIFFERENT one -> nothing written
$nh = New-SimDev 'NVR' $B; $nh.channels = @(@{ id = '1'; ip = '192.168.1.50' }); $script:sim.devs = @{ '192.168.1.20' = $nh }
$res.H = Run-Main 'Rollback' (New-Rb @($chStep)); $res.H | Add-Member -NotePropertyName ch -NotePropertyValue ([string]$nh.channels[0].ip)
# I. the NVR accepts the channel PUT but the channel reads back unchanged -> not confirmed
$ni = New-SimDev 'NVR' $A; $ni.channels = @(@{ id = '1'; ip = '192.168.1.50' }); $ni.ignoreChannel = $true; $script:sim.devs = @{ '192.168.1.20' = $ni }
$res.I = Run-Main 'Rollback' (New-Rb @($chStep))
# J. the saved recorder (...01) is at .20, but its old address .18 is now used by another device -> no move (no address conflict)
$script:sim.devs = @{ '192.168.1.20' = (New-SimDev 'NVR' $A); '192.168.1.18' = (New-SimDev 'IPCamera' 'C0-56-E3-00-00-18') }
$res.J = Run-Main 'Rollback' (New-Rb @($netStep))
Out-Result $res
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false 'undo driver ran' $o } else {
    Check (@($j.J.writes).Count -eq 0 -and $j.J.code -ne 0 -and $j.J.said -notmatch '(?m)^Done\.' -and $j.J.said -match 'now used by another device') 'sweep A: Undo does not move a recorder back onto an address another device now uses (2.2.17 sent the PUT: address conflict)' ((@($j.J.writes) -join '; ') + ' | ' + [string]$j.J.code + ' ' + $j.J.said)
    $done = '(?m)^Done\.'
    Check (@($j.A.writes).Count -eq 0) '#1 (Codex repro) a DIFFERENT recorder (...99) at the saved address .20 gets NO write (2.2.17 sent a PUT moving it to .18)' ((@($j.A.writes) -join '; ') + ' | ' + $j.A.said)
    Check ($j.A.code -ne 0 -and $j.A.said -notmatch $done -and $j.A.said -match 'NOT restored' -and $j.A.said -match 'NOT RESTORED' -and $j.A.left -eq '192.168.1.20') '#1 ...it says NOT restored / NOT RESTORED, not "Done.", exit not 0, the other recorder stays on .20' ([string]$j.A.code + ' ' + $j.A.said)
    Check (@($j.A2.writes).Count -eq 0 -and $j.A2.code -ne 0 -and $j.A2.said -notmatch $done) '#1 the same when discovery does not list the other recorder (only the address answers): no write, not Done' ((@($j.A2.writes) -join '; ') + ' | ' + [string]$j.A2.code + ' ' + $j.A2.said)
    Check ($j.B.code -eq 0 -and $j.B.said -match $done -and @($j.B.writes).Count -eq 1 -and $j.B.left -eq '192.168.1.18') 'control: the SAVED recorder (...01) at .20 is moved back to .18, read back there: Done, exit 0' ([string]$j.B.code + ' ' + (@($j.B.writes) -join '; ') + ' ' + $j.B.said)
    Check ($j.C.code -ne 0 -and $j.C.said -notmatch $done -and $j.C.said -match 'gateway 192\.168\.1\.254') '#3 twin: recorder accepts the Undo but keeps gateway .254 -> NOT restored (settings read back), not Done' ([string]$j.C.code + ' ' + $j.C.said)
    Check (@($j.D.writes).Count -eq 0 -and $j.D.code -ne 0 -and $j.D.said -notmatch $done -and $j.D.said -match 'NOT restored') '#1 camera Undo: a DIFFERENT camera at the address gets no write, NOT restored, exit not 0' ((@($j.D.writes) -join '; ') + ' | ' + [string]$j.D.code + ' ' + $j.D.said)
    Check ($j.E.code -ne 0 -and $j.E.said -notmatch $done -and $j.E.said -notmatch 'never moved') '#1 twin: "it never moved" needs the SAME camera (by MAC) at the old address; a different camera there is not proof (2.2.17: Done)' ([string]$j.E.code + ' ' + $j.E.said)
    Check ($j.E2.code -eq 0 -and $j.E2.said -match $done -and @($j.E2.writes).Count -eq 0) 'control: the same camera still on the old address = "it never moved" (checked by MAC), Done' ([string]$j.E2.code + ' ' + $j.E2.said)
    Check (@($j.F.writes).Count -eq 0 -and $j.F.ch -eq '192.168.1.51' -and $j.F.code -ne 0 -and $j.F.said -notmatch $done -and $j.F.said -match 'LEFT ALONE') '#2 twin (classic): channel D1 now used by another camera (.51): Undo leaves it alone, NOT restored, exit not 0 (2.2.17 retargeted it)' ((@($j.F.writes) -join '; ') + ' | ch ' + $j.F.ch + ' | ' + [string]$j.F.code + ' ' + $j.F.said)
    Check ($j.G.code -eq 0 -and $j.G.said -match $done -and $j.G.ch -eq '192.168.1.64') 'control: D1 still points at .50 (this run''s camera): put back to .64, read back, Done' ([string]$j.G.code + ' ch ' + $j.G.ch + ' ' + $j.G.said)
    Check (@($j.H.writes).Count -eq 0 -and $j.H.ch -eq '192.168.1.50' -and $j.H.code -ne 0 -and $j.H.said -notmatch $done) '#1 channel Undo on a DIFFERENT recorder at the NVR''s address: nothing written, not Done' ((@($j.H.writes) -join '; ') + ' | ' + [string]$j.H.code + ' ' + $j.H.said)
    Check ($j.I.code -ne 0 -and $j.I.said -notmatch $done -and $j.I.said -match 'NOT confirmed') '#3 twin: channel PUT accepted but the channel reads back unchanged: NOT confirmed, not Done' ([string]$j.I.code + ' ' + $j.I.said)
  }

  # ==============================================================================================================================
  Write-Host '#1/#3 twins, forward Fix: identity before the write, and a camera move counts only when its settings read back'
  $o = Invoke-Driver 'fwd' ($pre + "`n" + @'
$res = [ordered]@{}
# camera ...C1 on the old scheme 192.168.0.64 is NVR channel D1; the NVR (...01) is already right on 192.168.1.20
function New-Site([bool]$camKeepsGw) {
  $n = New-SimDev 'NVR' $A; $n.channels = @(@{ id = '1'; ip = '192.168.0.64' })
  $c = New-SimDev 'IPCamera' 'C0-56-E3-00-00-C1' '192.168.0.1'; $c.keepGw = $camKeepsGw
  $script:sim.devs = @{ '192.168.1.20' = $n; '192.168.0.64' = $c }; return $n
}
# A. the camera accepts the move to .1.64 but keeps its old gateway .0.1 (2.2.17: "done", channel moved, Done / exit 0)
$n = New-Site $true; $res.A = Run-Main 'Fix' $null; $res.A | Add-Member -NotePropertyName ch -NotePropertyValue ([string]$n.channels[0].ip)
# B. control: the camera takes every setting -> moved, read back, channel moved and read back, Done / exit 0
$n = New-Site $false; $res.B = Run-Main 'Fix' $null; $res.B | Add-Member -NotePropertyName ch -NotePropertyValue ([string]$n.channels[0].ip)
Out-Result $res
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false 'forward driver ran' $o } else {
    Check ($j.A.code -ne 0 -and $j.A.said -notmatch '(?m)^Done\.' -and $j.A.said -match 'gateway 192\.168\.0\.1') '#3 twin (classic forward): camera move acknowledged but gateway not taken -> NOT done (named), exit not 0 (2.2.17: Done / exit 0)' ([string]$j.A.code + ' ' + $j.A.said)
    Check ($j.A.ch -eq '192.168.0.64') '...and the NVR channel is NOT pointed at a camera move that did not check out' ('ch ' + $j.A.ch + ' ' + $j.A.said)
    Check ($j.B.code -eq 0 -and $j.B.said -match '(?m)^Done\.' -and $j.B.ch -eq '192.168.1.64') 'control: a clean camera move + channel change is still Done / exit 0' ([string]$j.B.code + ' ch ' + $j.B.ch + ' ' + $j.B.said)
  }

  # ==============================================================================================================================
  Write-Host '#1 Hik-Read: a different MAC is rejected, not copied over the saved one'
  $o = Invoke-Driver 'reader' ($pre + "`n" + @'
$script:sim.devs = @{ '192.168.1.20' = (New-SimDev 'NVR' $B) }
$d = New-Dev '192.168.1.20' $A 'test'; $d.kind = 'nvr'
$ok = Hik-Read $d
$script:sim.devs = @{ '192.168.1.20' = (New-SimDev 'NVR' $A) }
$d2 = New-Dev '192.168.1.20' $A 'test2'; $d2.kind = 'nvr'; $ok2 = Hik-Read $d2
Out-Result @{ ok = [bool]$ok; mac = [string]$d.mac; login = [string]$d.login; ok2 = [bool]$ok2; mac2 = [string]$d2.mac; login2 = [string]$d2.login }
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false 'reader driver ran' $o } else {
    Check (-not $j.ok -and $j.mac -eq 'C0-56-E3-00-00-01' -and $j.login -match 'DIFFERENT DEVICE') '#1 Hik-Read with expected MAC ...01 and a device saying ...99: rejected, record keeps ...01 (2.2.17 overwrote it with ...99)' ([string]$j.ok + ' ' + $j.mac + ' ' + $j.login)
    Check ($j.ok2 -and $j.mac2 -eq 'C0-56-E3-00-00-01' -and $j.login2 -eq 'ok') 'control: the same MAC reads normally' ([string]$j.ok2 + ' ' + $j.login2)
  }

  # ==============================================================================================================================
  Write-Host '#5 classic: an unreadable clean-up record blocks every start until a checked recovery'
  $sd = Join-Path $tmp 'state5'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
  $tf = Join-Path $sd 'temp-ips.json'; [IO.File]::WriteAllText($tf, '{ this is not json')
  $pre5 = $fnText + "`n" + '$ErrorActionPreference = ''Continue''; $Mock = $null; $stateDir = ' + (Q $sd) + '; $tempFile = ' + (Q $tf) + "`n" + @'
$logFile = Join-Path $stateDir 'log.txt'; $sum = New-Object System.Collections.Generic.List[string]; $taskName = 'WireIt FixNVR cleanup'
$cfg = [pscustomobject]@{ temp_ip_hosts = @(253, 252, 247); safety_cleanup_minutes = 30 }
$script:temps = New-Object System.Collections.Generic.List[object]
$script:sim = @{ calls = New-Object System.Collections.ArrayList }
function Unregister-ScheduledTask { [void]$script:sim.calls.Add('unregister') }
function Remove-NetFirewallRule { }
function Remove-NetIPAddress { }
function Get-NetIPAddress { param($InterfaceIndex, $IPAddress, $AddressFamily, $ErrorAction) $a = @([pscustomobject]@{ IPAddress = '192.168.1.105'; InterfaceIndex = 5; SkipAsSource = $false; AddressState = 'Preferred' }); if ($env:SIM_LEFT) { $a += [pscustomobject]@{ IPAddress = $env:SIM_LEFT; InterfaceIndex = 5; SkipAsSource = $true; AddressState = 'Preferred' } }; return $a }
function Get-PcNet { return [pscustomobject]@{ ifIndex = 5; alias = 'Ethernet'; ip = '192.168.1.105'; prefix = 24; gw = '192.168.1.1'; dhcp = $true } }
function Get-FnBootTime { if ($env:SIM_BOOT -eq 'later') { return (Get-Date).AddMinutes(5) } return (Get-Date).AddDays(-1) }
# 2.2.19: the clear is a positive check that also reads the DHCP+static coexistence setting of every connected adapter (stand-ins: off)
function Get-NetIPInterface { return @([pscustomobject]@{ ifIndex = 5; InterfaceAlias = 'Ethernet'; ConnectionState = 'Connected'; Dhcp = 'Enabled' }) }
function netsh { return 'DHCP/Static IP coexistence : disabled' }
$ok = Invoke-LeftoverCleanup
'JSON=' + (@{ ok = [bool]$ok; files = @(Get-ChildItem -LiteralPath $stateDir -Filter 'temp-ips*' | ForEach-Object { $_.Name }) } | ConvertTo-Json -Compress)
'@
  $env:SIM_BOOT = ''; $env:SIM_LEFT = ''
  $j1 = Get-Json (Invoke-Driver 'j1' $pre5)
  $j2 = Get-Json (Invoke-Driver 'j2' $pre5)      # a new start of the tool, the PC NOT restarted
  $env:SIM_BOOT = 'later'; $env:SIM_LEFT = '192.168.0.253'
  $j3 = Get-Json (Invoke-Driver 'j3' $pre5)      # restarted, but one of the tool's temporary addresses is still there
  $env:SIM_LEFT = ''
  $j4 = Get-Json (Invoke-Driver 'j4' $pre5)      # restarted, nothing left, connection working -> cleared
  $j5 = Get-Json (Invoke-Driver 'j5' $pre5)      # and the next start is free
  $env:SIM_BOOT = ''
  Check ($j1 -and -not $j1.ok -and @($j1.files | Where-Object { $_ -like 'temp-ips.unreadable-*' }).Count -eq 1) '#5 first start with an unreadable record: blocked, the record kept as .unreadable-*' ($j1 | ConvertTo-Json -Compress)
  Check ($j2 -and -not $j2.ok) '#5 (Codex repro) the NEXT start, PC not restarted: STILL blocked (2.2.17: no journal found, carried on)' ($j2 | ConvertTo-Json -Compress)
  Check ($j3 -and -not $j3.ok) '#5 restarted but a temporary address is still on the PC: still blocked' ($j3 | ConvertTo-Json -Compress)
  Check ($j4 -and $j4.ok -and @($j4.files | Where-Object { $_ -like 'temp-ips.resolved-*' }).Count -eq 1 -and @($j4.files | Where-Object { $_ -like 'temp-ips.unreadable-*' }).Count -eq 0) '#5 checked recovery (restarted since, no temporary address, connection works): cleared, kept as .resolved-*' ($j4 | ConvertTo-Json -Compress)
  Check ($j5 -and $j5.ok) 'control: after the checked recovery the next start is free' ($j5 | ConvertTo-Json -Compress)


  Write-Host 'sweep A: ONVIF gateway / DNS go only to the same camera at the new address; the PC adapter is checked by name'
  $o = Invoke-Driver 'onvif' ($pre + "`n" + @'
$c1 = New-SimDev 'IPCamera' $A; $c1.onvif = $true; $c2 = New-SimDev 'IPCamera' $B; $c2.onvif = $true
# the camera (...01) at .64 accepts the move, but .30 is (still) answered by ANOTHER camera (...99)
$script:sim.devs = @{ '192.168.1.64' = $c1; '192.168.1.30' = $c2 }
$d = New-Dev '192.168.1.64' $A 'test'; $d.kind = 'camera'; $d.onvif_token = 'eth0'
$r = Onvif-SetNet $d '192.168.1.30' 24 '192.168.1.1' '8.8.8.8' '1.1.1.1'
$w1 = @($script:sim.writes); $script:sim.writes.Clear()
# control: the same camera answers at .30
$script:sim.devs = @{ '192.168.1.30' = $c1 }
$r2 = Onvif-SetNet $d '192.168.1.30' 24 '192.168.1.1' '8.8.8.8' '1.1.1.1'
$w2 = @($script:sim.writes)
# the PC adapter: the record says ifIndex 5 = "Ethernet", Windows now calls ifIndex 5 "Wi-Fi"
$script:netsh = New-Object System.Collections.ArrayList
function netsh { [void]$script:netsh.Add(($args -join ' ')); return 'DHCP/Static IP coexistence : disabled' }
function Get-NetAdapter { param($InterfaceIndex, $ErrorAction) return [pscustomobject]@{ Name = $env:SIM_ADAPTER; InterfaceIndex = $InterfaceIndex } }
function Wait-PcRecovered { return '' }
function Get-NetIPInterface { return [pscustomobject]@{ Dhcp = 'Enabled' } }
$probs = @(); $env:SIM_ADAPTER = 'Wi-Fi'
Restore-PcSettings ([pscustomobject]@{ coexistence_before = 'disabled'; dhcp = $true; alias = 'Ethernet'; ip = ''; gw = '' }) 5 ([ref]$probs)
$n1 = @($script:netsh | Where-Object { $_ -match ' set ' }).Count; $p1 = ($probs -join '; ')
$probs = @(); $script:netsh.Clear(); $env:SIM_ADAPTER = 'Ethernet'
Restore-PcSettings ([pscustomobject]@{ coexistence_before = 'disabled'; dhcp = $true; alias = 'Ethernet'; ip = ''; gw = '' }) 5 ([ref]$probs)
$n2 = @($script:netsh | Where-Object { $_ -match ' set ' }).Count
Out-Result @{ ok1 = [bool]$r.ok; note1 = [string]$r.note; w1 = $w1; ok2 = [bool]$r2.ok; w2 = $w2; n1 = $n1; p1 = $p1; n2 = $n2; p2 = ($probs -join '; ') }
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false 'onvif/adapter driver ran' $o } else {
    Check (-not $j.ok1 -and @($j.w1 | Where-Object { $_ -like 'onvif-gw*' -or $_ -like 'onvif-dns*' }).Count -eq 0) 'sweep A: ONVIF move - a DIFFERENT camera answers at the new address: its gateway / DNS are NOT set, not ok (2.2.17 set them)' ((@($j.w1) -join '; ') + ' | ' + $j.note1)
    Check ($j.ok2 -and @($j.w2 | Where-Object { $_ -like 'onvif-gw*' }).Count -eq 1) 'control: the same camera at the new address gets gateway + DNS' ((@($j.w2) -join '; '))
    Check ($j.n1 -eq 0 -and $j.p1 -match 'NOT put back') 'sweep A: PC clean-up - the saved adapter number now belongs to another adapter (by name): no netsh write, reported NOT put back' ('netsh sets ' + $j.n1 + ' | ' + $j.p1)
    Check ($j.n2 -eq 1 -and -not $j.p2) 'control: the same adapter name: the setting is put back as before' ('netsh sets ' + $j.n2 + ' | ' + $j.p2)
  }
  Deferred 'real Hikvision / ONVIF devices answering a classic Undo and move (MAC in deviceInfo / HwAddress, read-back after a reboot)'
  Deferred 'a real Windows restart clearing an unreadable clean-up record (Win32_OperatingSystem LastBootUpTime)'
} finally {
  Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
  $env:SIM_BOOT = $null; $env:SIM_LEFT = $null; $env:SIM_ADAPTER = $null
}
Write-Host ''
Write-Host ('Test-Fix2218Classic: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:deferred + ' deferred')
if ($script:fail) { exit 1 } else { exit 0 }
