<# Test-Fix2213Classic.ps1 - behavioural tests for the 2.2.13 classic Fix NVR fixes (Codex review of 2.2.12 head ea667c6, findings #2 and #3).
   #2: with no automatic plan, the finish comes from what the read showed (platform OFFLINE / camera offline / list or status unread = not green, exit 4), also in Check mode.
   #3: after the fix, a failed or unexpectedly empty camera list (or a list missing cameras the NVR had before) is NOT CHECKED, never "Done.".
   Every check RUNS the real FixNVR.ps1 functions (Invoke-Main, Read-Dev, Hik-Read, Get-FnHealthProblems) in a child PowerShell. Only the
   recorder's HTTP answers (Http), discovery (Find-Sadp/Onvif/ArpSniff) and the platform write are stood in for; no device or adapter is touched.
   Codex's scenarios NEW_noPlan and NEW_noChannels (reproduce-classic.ps1) were not sent to us; these are written from the review's evidence.
   Old-code proof: FIX2213CLASSIC_FILE=<copy of FixNVR.ps1 from ea667c6> runs the same checks against that file.
   NEEDS WINDOWS CHECK (not counted here): a real Hikvision NVR's ISAPI answers when its camera list or status cannot be read. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$fnvPath = $(if ($env:FIX2213CLASSIC_FILE) { $env:FIX2213CLASSIC_FILE } else { Join-Path $repo 'FixNVR/FixNVR.ps1' })   # tests only: point at another copy (old-code proof)
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2213classic-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { $m = ($more -replace '\s+', ' '); Write-Host ('     ' + $m.Substring(0, [math]::Min(1200, $m.Length))) } }
}
function Deferred([string]$name) { $script:deferred++; Write-Host ('DEFERRED ' + $name + ' (NEEDS WINDOWS CHECK)') }
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
$fnText = Get-FnText $fnvPath

try {
  # The real Invoke-Main / Read-Dev / Hik-Read. Http answers like a Hikvision NVR from $script:sim: each NVR has a "before" state
  # (read before the fix) and an "after" state (read once the platform write was sent). A state says: login ok / no answer, platform
  # enabled / online, cams (online true/false per channel), ids (channel ids, default 1..n), list_fails (camera list unanswered),
  # list_empty (camera list answers 200 with no cameras), status_fails (camera status unanswered).
  $pre = $fnText + "`n" + '$ErrorActionPreference = ''Continue''; $here = ' + (Q (Join-Path $tmp 'here')) + "`n" + @'
$Mock = $null; $oui = @{}; $Version = 'test'; $Site = ''; $SniffSeconds = 0; $OldSubnet = @(); $Nvr = ''; $NoLogin = $false; $MoveUnlisted = $false; $AllowUnverifiedUniview = $false
$ConfirmWith = 'YES'; $snap = $null; $rb = $null; $script:routerStepShown = $false; $script:credNvr = $null; $script:credCam = $null
$cfg = [pscustomobject]@{ arp_sniff_seconds = 0; max_old_subnets = 2; nvr_hosts = @(20, 19, 18); camera_block_start = 21; camera_block_end = 99; camera_channel_base = 20; camera_ip_mode = 'keep_last_octet'; router_dhcp_start = 100; dns1 = '8.8.8.8'; dns2 = '1.1.1.1'; verify_wait_seconds = 0; camera_wait_seconds = 0; poe_internal_subnets = @('192.168.254'); uniview = [pscustomobject]@{ cloud_path = '/x' } }
$pc = [pscustomobject]@{ ifIndex = 5; alias = 'Ethernet'; dhcp = $true; ip = '192.168.1.105'; prefix = 24; gw = '192.168.1.1' }; $script:pcNet = $pc
$newP3 = '192.168.1'; $newMask = '255.255.255.0'
$plan = New-Object System.Collections.Generic.List[object]; $applied = New-Object System.Collections.Generic.List[object]
$script:devs = New-Object System.Collections.Generic.List[object]
$script:exitCode = 0
$runDir = Join-Path $here ('run-' + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$logFile = Join-Path $runDir 'log.txt'; $sum = New-Object System.Collections.Generic.List[string]
$script:sim = @{ phase = 'before'; writes = New-Object System.Collections.ArrayList; nvrs = @(); writeFails = $false; http = 0 }
function Open-Firewall { }
function Get-Creds { }
function Test-IpFree([string]$ip) { return $true }
function Start-Sleep { }
function Find-ArpSniff([int]$seconds) { return @{} }
function Find-Onvif($localIps) { return @{} }
function Find-Sadp($localIps) { $o = @{}; foreach ($n in $script:sim.nvrs) { $o[$n.mac] = [pscustomobject]@{ ip = $n.ip; mac = $n.mac; kind = 'nvr'; brand = 'hik'; model = 'DS-7608'; serial = 'S' + $n.ip; found_by = 'SADP'; dhcp = $false; mask = '255.255.255.0'; gw = '192.168.1.1' } }; return $o }
function Add-TempIp { return $null }
function Wait-Answer { return $true }
function Get-SimState([string]$ip) { $n = @($script:sim.nvrs | Where-Object { $_.ip -eq $ip })[0]; if (-not $n) { return $null }; if ($script:sim.phase -eq 'before') { return $n.before } else { return $n.after } }
function Http([string]$ip, [string]$method, [string]$path, [string]$body = '', [string]$ctype = '', $cred = $null, [int]$timeout = 10) {
  $script:sim.http++
  $st = Get-SimState $ip
  if (-not $st -or $st.login -ne 'ok') { return @{ code = 0; body = ''; err = 'timed out' } }
  $mac = @($script:sim.nvrs | Where-Object { $_.ip -eq $ip })[0].mac
  $ids = $(if ($st.ids) { @($st.ids) } else { $i = 0; @($st.cams | ForEach-Object { $i++; [string]$i }) })
  if ($path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = ('<DeviceInfo><deviceType>NVR</deviceType><model>DS-7608</model><serialNumber>S' + $ip + '</serialNumber><macAddress>' + $mac + '</macAddress><firmwareVersion>V4</firmwareVersion></DeviceInfo>'); err = '' } }
  if ($path -eq '/ISAPI/System/Network/interfaces') { return @{ code = 200; body = ('<NetworkInterfaceList><NetworkInterface><id>1</id><IPAddress><ipAddress>' + $ip + '</ipAddress></IPAddress></NetworkInterface></NetworkInterfaceList>'); err = '' } }
  if ($path -like '/ISAPI/System/Network/interfaces/*/ipAddress') { return @{ code = 200; body = ('<IPAddress><ipVersion>v4</ipVersion><addressingType>static</addressingType><ipAddress>' + $ip + '</ipAddress><subnetMask>255.255.255.0</subnetMask><DefaultGateway><ipAddress>192.168.1.1</ipAddress></DefaultGateway><PrimaryDNS><ipAddress>8.8.8.8</ipAddress></PrimaryDNS><SecondaryDNS><ipAddress>1.1.1.1</ipAddress></SecondaryDNS></IPAddress>'); err = '' } }
  if ($path -eq '/ISAPI/System/Network/EZVIZ') { return @{ code = 200; body = ('<EZVIZ><enabled>' + $(if ($st.platform_enabled) { 'true' } else { 'false' }) + '</enabled><registerStatus>' + $(if ($st.platform_online) { 'true' } else { 'false' }) + '</registerStatus></EZVIZ>'); err = '' } }
  if ($path -eq '/ISAPI/ContentMgmt/InputProxy/channels') {
    if ($st.list_fails) { return @{ code = 0; body = ''; err = 'timed out' } }
    if ($st.list_empty) { return @{ code = 200; body = '<InputProxyChannelList version="2.0"></InputProxyChannelList>'; err = '' } }
    $b = '<InputProxyChannelList>'; $k = 0; foreach ($c in $st.cams) { $b += '<InputProxyChannel><id>' + $ids[$k] + '</id><sourceInputPortDescriptor><proxyProtocol>HIKVISION</proxyProtocol><ipAddress>192.168.1.' + (21 + $k) + '</ipAddress><managePortNo>8000</managePortNo></sourceInputPortDescriptor></InputProxyChannel>'; $k++ }
    return @{ code = 200; body = ($b + '</InputProxyChannelList>'); err = '' }
  }
  if ($path -eq '/ISAPI/ContentMgmt/InputProxy/channels/status') {
    if ($st.status_fails) { return @{ code = 0; body = ''; err = 'timed out' } }
    $b = '<InputProxyChannelStatusList>'; $k = 0; foreach ($c in $st.cams) { $b += '<InputProxyChannelStatus><id>' + $ids[$k] + '</id><online>' + $(if ($c) { 'true' } else { 'false' }) + '</online></InputProxyChannelStatus>'; $k++ }
    return @{ code = 200; body = ($b + '</InputProxyChannelStatusList>'); err = '' }
  }
  return @{ code = 0; body = ''; err = 'not simulated' }
}
function Hik-EnablePlatform($dev) { [void]$script:sim.writes.Add('platform ' + $dev.ip); $script:sim.phase = 'after'; if ($script:sim.writeFails) { return @{ ok = $false; note = 'NVR said no' } }; return @{ ok = $true; note = '' } }
function Hik-SetNet { [void]$script:sim.writes.Add('net'); $script:sim.phase = 'after'; return @{ ok = $true; reboot = $false; note = '' } }
function Hik-SetChannel { [void]$script:sim.writes.Add('channel'); $script:sim.phase = 'after'; return @{ ok = $true; note = '' } }
function Hik-RebootNow { [void]$script:sim.writes.Add('reboot'); return $true }
function Run-Main {
  $script:exitCode = 0; $sum.Clear(); $script:devs.Clear(); $plan.Clear(); $applied.Clear(); $script:sim.phase = 'before'; $script:sim.writes.Clear()
  try { Invoke-Main } catch { $sum.Add('ERROR ' + $_.Exception.Message + ' line ' + $_.InvocationInfo.ScriptLineNumber + ': ' + $_.InvocationInfo.Line.Trim()); $script:exitCode = 5 }
  return [pscustomobject]@{ code = $script:exitCode; said = (@($sum) -join "`n"); writes = @($script:sim.writes) }
}
function Out-Result($o) { 'JSON=' + ($o | ConvertTo-Json -Compress -Depth 5) }
function N1($before, $after) { return @(@{ ip = '192.168.1.20'; mac = 'C0-56-E3-00-00-01'; before = $before; after = $after }) }
$good   = @{ login = 'ok'; platform_enabled = $true;  platform_online = $true;  cams = @($true, $true) }
$offPlat = @{ login = 'ok'; platform_enabled = $false; platform_online = $false; cams = @($true, $true) }
# Codex NEW_noPlan: network right, platform access enabled (so no plan), but platform OFFLINE and only 1 of 2 cameras online
$noPlan = @{ login = 'ok'; platform_enabled = $true; platform_online = $false; cams = @($true, $false) }
# Codex NEW_noChannels after the fix: platform on and online, camera list unavailable, camera status read failing too
$noCh   = @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @($true, $true); list_fails = $true; status_fails = $true }
'@

  # =====================================================================================
  Write-Host '#2. classic Fix NVR with nothing to change: the finish comes from what the read showed (Fix and Check mode)'
  $o = Invoke-Driver 'f2' ($pre + "`n" + @'
$res = [ordered]@{}
$Mode = 'Fix'
$script:sim.nvrs = N1 $noPlan $noPlan; $res.A = Run-Main          # Codex NEW_noPlan
$res.A2 = Run-Main                                               # running it twice
$script:sim.nvrs = N1 @{ login = 'ok'; platform_enabled = $true; platform_online = $false; cams = @($true, $true) } $good; $res.B = Run-Main   # platform offline only
$script:sim.nvrs = N1 @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @($true, $false) } $good; $res.C = Run-Main   # camera offline only
# failing half-way: the camera status read (or the camera list read) does not answer during the check
$script:sim.nvrs = N1 @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @($true, $true); status_fails = $true } $good; $res.D = Run-Main
$script:sim.nvrs = N1 @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @($true, $true); list_fails = $true } $good; $res.E = Run-Main
# wrong device: two recorders, the healthy one must not make the run green while the other shows an offline camera
$script:sim.nvrs = @(@{ ip = '192.168.1.20'; mac = 'C0-56-E3-00-00-01'; before = $good; after = $good }, @{ ip = '192.168.1.19'; mac = 'C0-56-E3-00-00-02'; before = @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @($true, $false, $true) }; after = $good })
$res.F = Run-Main
# no regression: everything read and right = the green all-right, exit 0; a valid empty camera list is not a problem
$script:sim.nvrs = N1 $good $good; $res.G = Run-Main
$script:sim.nvrs = N1 @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @(); list_empty = $true } $good; $res.H = Run-Main
$Mode = 'Check'
$script:sim.nvrs = N1 $noPlan $noPlan; $res.J = Run-Main        # Codex: Check mode takes the same branch
$script:sim.nvrs = N1 $good $good; $res.K = Run-Main
# Check mode with a plan (platform OFF) AND an offline camera the plan does not cover: not an all-clear
$script:sim.nvrs = N1 @{ login = 'ok'; platform_enabled = $false; platform_online = $false; cams = @($true, $false) } $good; $res.L = Run-Main
$res.http = $script:sim.http
Out-Result $res
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false '#2 driver ran' $o }
  else {
    $allRight = 'Everything the tool can check looks right'
    Check ($j.A.code -ne 0 -and $j.A.said -notmatch $allRight) '#2 (Codex NEW_noPlan) platform OFFLINE + 1 of 2 cameras online, no plan: NOT the green all-right, exit not 0' ([string]$j.A.code + ' ' + $j.A.said)
    Check ($j.A.code -eq 4 -and $j.A.said -match 'OFFLINE' -and $j.A.said -match '1 of 2 camera' -and $j.A.said -match 'D2' -and $j.A.said -match 'NOT an all-clear') '... it says exit 4 (NOT DONE in the Toolkit), lists the platform OFFLINE and camera D2 offline, and that this is NOT an all-clear' ([string]$j.A.code + ' ' + $j.A.said)
    Check (@($j.A.writes).Count -eq 0) '... and nothing was written to the NVR' (@($j.A.writes) -join ',')
    Check ($j.A2.code -eq 4 -and $j.A2.said -notmatch $allRight -and @($j.A2.writes).Count -eq 0) '#2 running it twice: the same honest answer, still nothing written' ([string]$j.A2.code + ' ' + $j.A2.said)
    Check ($j.B.code -eq 4 -and $j.B.said -notmatch $allRight -and $j.B.said -match 'OFFLINE') '#2 platform access on but OFFLINE (cameras fine): not green, exit 4' ([string]$j.B.code + ' ' + $j.B.said)
    Check ($j.C.code -eq 4 -and $j.C.said -notmatch $allRight -and $j.C.said -match 'camera\(s\) OFFLINE') '#2 a camera offline (platform fine): not green, exit 4' ([string]$j.C.code + ' ' + $j.C.said)
    Check ($j.D.code -eq 4 -and $j.D.said -notmatch $allRight -and $j.D.said -match 'status could not be read' -and $j.D.said -match 'NOT CHECKED') '#2 failing half-way: the camera status read does not answer: NOT CHECKED, not green, exit 4' ([string]$j.D.code + ' ' + $j.D.said)
    Check ($j.E.code -eq 4 -and $j.E.said -notmatch $allRight -and $j.E.said -match 'camera list could not be read' -and $j.E.said -match 'NOT CHECKED') '#2 failing half-way: the camera list read does not answer: NOT CHECKED, not green, exit 4' ([string]$j.E.code + ' ' + $j.E.said)
    Check ($j.F.code -eq 4 -and $j.F.said -notmatch $allRight -and $j.F.said -match 'NVR 192\.168\.1\.19: 1 of 3 camera' -and $j.F.said -notmatch 'NVR 192\.168\.1\.20: ') '#2 two recorders: the problem is named on the right NVR (.19), the healthy one (.20) is not blamed, run not green' ([string]$j.F.code + ' ' + $j.F.said)
    Check ($j.G.code -eq 0 -and $j.G.said -match $allRight) '#2 no regression: everything read and right = the green all-right, exit 0' ([string]$j.G.code + ' ' + $j.G.said)
    Check ($j.H.code -eq 0 -and $j.H.said -match $allRight) '#2 no regression: an NVR whose camera list reads back valid and empty is not called a problem' ([string]$j.H.code + ' ' + $j.H.said)
    Check ($j.J.code -eq 4 -and $j.J.said -notmatch $allRight -and $j.J.said -match 'OFFLINE' -and @($j.J.writes).Count -eq 0) '#2 (Codex) Check mode, NEW_noPlan: not the all-right, exit 4, nothing written' ([string]$j.J.code + ' ' + $j.J.said)
    Check ($j.K.code -eq 0 -and $j.K.said -match $allRight) '#2 no regression: Check mode on a healthy NVR is still the all-right, exit 0' ([string]$j.K.code + ' ' + $j.K.said)
    Check ($j.L.code -eq 4 -and $j.L.said -match 'Check only' -and $j.L.said -match 'D2' -and $j.L.said -match 'Not an all-clear' -and @($j.L.writes).Count -eq 0) '#2 Check mode with a plan: an offline camera the plan does not fix is listed, not an all-clear, exit 4, nothing written' ([string]$j.L.code + ' ' + $j.L.said)
    Check ([int]$j.http -gt 0) '#2 the real Hik-Read ran against the stand-in recorder (the reads were not skipped)' ([string]$j.http)
  }

  # =====================================================================================
  Write-Host '#3. classic Fix NVR after the fix: the camera check is never skipped because the list did not come back'
  $o = Invoke-Driver 'f3' ($pre + "`n" + @'
$res = [ordered]@{}
$Mode = 'Fix'
$script:sim.nvrs = N1 $offPlat $noCh; $res.A = Run-Main          # Codex NEW_noChannels
$script:sim.nvrs = N1 $noCh $noCh; $res.A2 = Run-Main          # running it twice: the NVR now is what the first run left (platform on, list unreadable)
# the list answers 200 but EMPTY after the fix, although 2 cameras were there before (status is fine)
$script:sim.nvrs = N1 $offPlat @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @(); list_empty = $true }; $res.B = Run-Main
# the list does not answer, the status does
$script:sim.nvrs = N1 $offPlat @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @($true, $true); list_fails = $true }; $res.C = Run-Main
# wrong device: after the fix a recorder answers with a different camera list (D5 D6, all online) - D1 D2 are not checked
$script:sim.nvrs = N1 $offPlat @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @($true, $true); ids = @('5', '6') }; $res.D = Run-Main
# failing half-way: one of the two cameras dropped off the list after the fix
$script:sim.nvrs = N1 $offPlat @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @($true); ids = @('1') }; $res.E = Run-Main
# two recorders: the good one checks out, the other loses its list -> not Done, and the problem is on the right NVR
$script:sim.nvrs = @(@{ ip = '192.168.1.20'; mac = 'C0-56-E3-00-00-01'; before = $offPlat; after = $good }, @{ ip = '192.168.1.19'; mac = 'C0-56-E3-00-00-02'; before = $offPlat; after = $noCh })
$res.F = Run-Main
# no regression: a fix that checks out is still Done / exit 0; an NVR with no cameras before and a valid empty list after is Done too
$script:sim.nvrs = N1 $offPlat $good; $res.G = Run-Main
$e0 = @{ login = 'ok'; platform_enabled = $false; platform_online = $false; cams = @(); list_empty = $true }
$script:sim.nvrs = N1 $e0 @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @(); list_empty = $true }; $res.H = Run-Main
# the status read failing with the list present is still NOT CHECKED (2.2.12 behaviour kept)
$script:sim.nvrs = N1 $offPlat @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @($true, $true); status_fails = $true }; $res.I = Run-Main
Out-Result $res
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false '#3 driver ran' $o }
  else {
    Check ($j.A.code -ne 0 -and $j.A.said -notmatch '(?m)^Done\.') '#3 (Codex NEW_noChannels) 2 cameras before, platform fixed and online, camera list (and status) unavailable after: NOT "Done.", exit not 0' ([string]$j.A.code + ' ' + $j.A.said)
    Check ($j.A.code -eq 4 -and $j.A.said -match 'NOT CHECKED' -and $j.A.said -match 'NOT DONE' -and $j.A.said -match '2 camera\(s\) before') '... it says NOT CHECKED + NOT DONE (exit 4) and keeps the expected count (2 cameras before the fix)' ([string]$j.A.code + ' ' + $j.A.said)
    Check ($j.A.said -match 'D1 D2') '... and names the expected channels D1 D2' $j.A.said
    Check ($j.A2.code -eq 4 -and $j.A2.said -notmatch 'Everything the tool can check looks right' -and $j.A2.said -notmatch '(?m)^Done\.' -and @($j.A2.writes).Count -eq 0) '#3 running it twice: the second run (list still unreadable, nothing left to change) is honest, not green, nothing written' ([string]$j.A2.code + ' ' + $j.A2.said)
    Check ($j.B.code -eq 4 -and $j.B.said -notmatch '(?m)^Done\.' -and $j.B.said -match 'NOT CHECKED') '#3 list answers but EMPTY after the fix while 2 cameras were there before: NOT CHECKED, not Done' ([string]$j.B.code + ' ' + $j.B.said)
    Check ($j.C.code -eq 4 -and $j.C.said -notmatch '(?m)^Done\.' -and $j.C.said -match 'camera list could not be read') '#3 list unanswered after the fix (status fine): NOT CHECKED, not Done' ([string]$j.C.code + ' ' + $j.C.said)
    Check ($j.D.code -eq 4 -and $j.D.said -notmatch '(?m)^Done\.' -and $j.D.said -match 'D1 D2' -and $j.D.said -match 'NOT CHECKED') '#3 wrong device: a different camera list answers after the fix (D5 D6 online): D1 D2 NOT CHECKED, not Done' ([string]$j.D.code + ' ' + $j.D.said)
    Check ($j.E.code -eq 4 -and $j.E.said -notmatch '(?m)^Done\.' -and $j.E.said -match 'D2') '#3 failing half-way: one camera dropped off the list after the fix: named (D2), not Done' ([string]$j.E.code + ' ' + $j.E.said)
    Check ($j.F.code -eq 4 -and $j.F.said -notmatch '(?m)^Done\.' -and $j.F.said -match 'NVR 192\.168\.1\.19: camera list could not be read' -and $j.F.said -notmatch 'NVR 192\.168\.1\.20: camera list') '#3 two recorders: the one that lost its list is named, the good one is not blamed, not Done' ([string]$j.F.code + ' ' + $j.F.said)
    Check ($j.G.code -eq 0 -and $j.G.said -match '(?m)^Done\.') '#3 no regression: a fix that checks out (list read, 2 of 2 online) is still Done / exit 0' ([string]$j.G.code + ' ' + $j.G.said)
    Check ($j.H.code -eq 0 -and $j.H.said -match '(?m)^Done\.') '#3 no regression: no cameras before + a valid empty list after = Done (no false NOT CHECKED)' ([string]$j.H.code + ' ' + $j.H.said)
    Check ($j.I.code -eq 4 -and $j.I.said -match 'camera status could not be read') '#3 status read failing with the list present: still NOT CHECKED (2.2.12 kept)' ([string]$j.I.code + ' ' + $j.I.said)
  }
  Deferred '#2/#3 a real Hikvision NVR whose camera list / status does not answer gives the same red NOT CHECKED lines in the Toolkit window'
}
finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
Write-Host ''
Write-Host ('Test-Fix2213Classic: ' + $script:pass + ' passed, ' + $script:fail + ' failed' + $(if ($script:deferred) { ', ' + $script:deferred + ' deferred' } else { '' }))
if ($script:fail) { exit 1 } else { exit 0 }
