<# Test-Fix2214Classic.ps1 - behavioural tests for the 2.2.14 classic Fix NVR fix (Codex review of 2.2.13 head b6037f2, finding F4).
   F4: the check after the fix reported the platform state read BEFORE the fix as a fresh ONLINE check. If platform access was online
   before a network fix and the final EZVIZ read failed, the kept "true" skipped the wait and the run said "ONLINE (app should work)" and
   "Done." (exit 0). 2.2.14 clears every field the reader fills (platform, network, gateway, DNS, login, lists) before the reread, tracks
   each settings read on its own, and a failed read after the fix is NOT CHECKED (exit 4, NOT DONE), never the old value.
   Every check RUNS the real FixNVR.ps1 functions (Invoke-Main, Read-Dev, Hik-Read, Unv-Read, Set-FnHikPlatform, Clear-FnReadState) in a
   child PowerShell. Only the recorder's HTTP answers (Http), discovery (Find-Sadp/Onvif/ArpSniff) and the writes are stood in for; no
   device or adapter is touched. The stand-in recorder is the one from Test-Fix2213Classic.ps1 plus: mask/gw per state, net_fails,
   ez_fails, ez_garbage (a login page instead of the EZVIZ answer), ez_nostatus, other_mac (a different device answers), and
   failOnceAfter (the EZVIZ read fails N times right after the fix, then works).
   Codex's reproduce-classic.ps1 / classic-result.json (network-mask fix, then HTTP 500 on EZVIZ: 2.2.13 exit 0, 'ONLINE', 'Done.') is F4-A.
   Old-code proof: FIX2214CLASSIC_FILE=<FixNVR.ps1 from b6037f2> runs the same checks against that file.
   NEEDS WINDOWS CHECK (counted DEFERRED, never PASS): a real Hikvision NVR whose EZVIZ / network read fails after a real network move. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$fnvPath = $(if ($env:FIX2214CLASSIC_FILE) { $env:FIX2214CLASSIC_FILE } else { Join-Path $repo 'FixNVR/FixNVR.ps1' })   # tests only: point at another copy (old-code proof)
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2214classic-' + [guid]::NewGuid().ToString('N'))
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
$script:sim = @{ phase = 'before'; writes = New-Object System.Collections.ArrayList; nvrs = @(); writeFails = $false; http = 0; ez = 0; ezFailLeft = 0; failOnceAfter = 0 }
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
  $mac = $(if ($st.other_mac) { $st.other_mac } else { @($script:sim.nvrs | Where-Object { $_.ip -eq $ip })[0].mac })
  $ser = $(if ($st.other_mac) { 'OTHER' + $ip } else { 'S' + $ip })
  $ids = $(if ($st.ids) { @($st.ids) } else { $i = 0; @($st.cams | ForEach-Object { $i++; [string]$i }) })
  if ($path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = ('<DeviceInfo><deviceType>NVR</deviceType><model>DS-7608</model><serialNumber>' + $ser + '</serialNumber><macAddress>' + $mac + '</macAddress><firmwareVersion>V4</firmwareVersion></DeviceInfo>'); err = '' } }
  if ($path -eq '/ISAPI/System/Network/interfaces') { return @{ code = 200; body = ('<NetworkInterfaceList><NetworkInterface><id>1</id><IPAddress><ipAddress>' + $ip + '</ipAddress></IPAddress></NetworkInterface></NetworkInterfaceList>'); err = '' } }
  if ($path -like '/ISAPI/System/Network/interfaces/*/ipAddress') { if ($st.net_fails) { return @{ code = 500; body = ''; err = 'network read failed' } }; return @{ code = 200; body = ('<IPAddress><ipVersion>v4</ipVersion><addressingType>static</addressingType><ipAddress>' + $ip + '</ipAddress><subnetMask>' + $(if ($st.mask) { $st.mask } else { '255.255.255.0' }) + '</subnetMask><DefaultGateway><ipAddress>' + $(if ($st.gw) { $st.gw } else { '192.168.1.1' }) + '</ipAddress></DefaultGateway><PrimaryDNS><ipAddress>8.8.8.8</ipAddress></PrimaryDNS><SecondaryDNS><ipAddress>1.1.1.1</ipAddress></SecondaryDNS></IPAddress>'); err = '' } }
  if ($path -eq '/ISAPI/System/Network/EZVIZ') { $script:sim.ez++ }
  if ($path -eq '/ISAPI/System/Network/EZVIZ' -and ($st.ez_fails -or $script:sim.ezFailLeft -gt 0)) { if ($script:sim.ezFailLeft -gt 0) { $script:sim.ezFailLeft-- }; return @{ code = 500; body = ''; err = 'platform read failed' } }
  if ($path -eq '/ISAPI/System/Network/EZVIZ' -and $st.ez_garbage) { return @{ code = 200; body = '<html><body>Please log in</body></html>'; err = '' } }
  if ($path -eq '/ISAPI/System/Network/EZVIZ' -and $st.ez_nostatus) { return @{ code = 200; body = '<EZVIZ><enabled>true</enabled></EZVIZ>'; err = '' } }
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
function Hik-SetNet { [void]$script:sim.writes.Add('net'); $script:sim.phase = 'after'; $script:sim.ezFailLeft = $script:sim.failOnceAfter; return @{ ok = $true; reboot = $false; note = '' } }
function Hik-SetChannel { [void]$script:sim.writes.Add('channel'); $script:sim.phase = 'after'; return @{ ok = $true; note = '' } }
function Hik-RebootNow { [void]$script:sim.writes.Add('reboot'); return $true }
function Run-Main {
  $script:exitCode = 0; $sum.Clear(); $script:devs.Clear(); $plan.Clear(); $applied.Clear(); $script:sim.phase = 'before'; $script:sim.writes.Clear(); $script:sim.ezFailLeft = 0; $script:sim.ez = 0
  try { Invoke-Main } catch { $sum.Add('ERROR ' + $_.Exception.Message + ' line ' + $_.InvocationInfo.ScriptLineNumber + ': ' + $_.InvocationInfo.Line.Trim()); $script:exitCode = 5 }
  return [pscustomobject]@{ code = $script:exitCode; said = (@($sum) -join "`n"); writes = @($script:sim.writes) }
}
function Out-Result($o) { 'JSON=' + ($o | ConvertTo-Json -Compress -Depth 5) }
function N1($before, $after) { return @(@{ ip = '192.168.1.20'; mac = 'C0-56-E3-00-00-01'; before = $before; after = $after }) }
# Codex reproduce-classic.ps1: before the fix the NVR's mask is wrong (255.255.0.0) so the plan moves its network; platform on + ONLINE before
$netWrong = @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @($true, $true); mask = '255.255.0.0' }
$good     = @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @($true, $true) }
# after the fix the EZVIZ (platform) read answers HTTP 500
$ezDown   = @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @($true, $true); ez_fails = $true }
'@

  # =====================================================================================
  Write-Host 'F4. classic Fix NVR: the check after the fix is a fresh read; a failed read is NOT CHECKED, never the value from before'
  $o = Invoke-Driver 'f4' ($pre + "`n" + @'
$res = [ordered]@{}
$Mode = 'Fix'
function Pick($r) { return [pscustomobject]@{ code = $r.code; said = $r.said; writes = $r.writes; ez = $script:sim.ez } }
# A. Codex reproduce-classic.ps1: network-mask fix, platform online before, EZVIZ answers HTTP 500 after the fix
$script:sim.nvrs = N1 $netWrong $ezDown; $res.A = Pick (Run-Main)
# A2. running it twice: the NVR is now what the first run left (mask right, EZVIZ still failing): honest, nothing written
$script:sim.nvrs = N1 $ezDown $ezDown; $res.A2 = Pick (Run-Main)
# B. the final NETWORK read fails after the network fix (platform fine)
$script:sim.nvrs = N1 $netWrong @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @($true, $true); net_fails = $true }; $res.B = Pick (Run-Main)
# C. failing half-way, then recovering: EZVIZ fails once right after the fix, then answers ONLINE inside the wait (honest ONLINE)
$cfg.verify_wait_seconds = 30; $script:sim.failOnceAfter = 1
$script:sim.nvrs = N1 $netWrong $good; $res.C = Pick (Run-Main)
# C2. EZVIZ never answers again even with the wait: the wait is bounded, the result is NOT CHECKED
$script:sim.failOnceAfter = 0
$script:sim.nvrs = N1 $netWrong $ezDown; $res.C2 = Pick (Run-Main)
$cfg.verify_wait_seconds = 0
# D. wrong device: after the fix a DIFFERENT recorder answers at the NVR address (all healthy)
$script:sim.nvrs = N1 $netWrong @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @($true, $true); other_mac = 'C0-56-E3-99-99-99' }; $res.D = Pick (Run-Main)
# E. the EZVIZ read answers 200 with a login page (not an EZVIZ answer): NOT CHECKED, not the old ONLINE
$script:sim.nvrs = N1 $netWrong @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @($true, $true); ez_garbage = $true }; $res.E = Pick (Run-Main)
# F. the network reads back but NOT as set (gateway 192.168.1.254 instead of 192.168.1.1)
$script:sim.nvrs = N1 $netWrong @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @($true, $true); gw = '192.168.1.254' }; $res.F = Pick (Run-Main)
# G. no regression: a network fix that checks out = Done, ONLINE, exit 0
$script:sim.nvrs = N1 $netWrong $good; $res.G = Pick (Run-Main)
# G2. ...and running it again on the fixed NVR: nothing to change, the all-right, nothing written
$script:sim.nvrs = N1 $good $good; $res.G2 = Pick (Run-Main)
# H. two recorders: .19's EZVIZ fails after the fix, .20 is fine: .19 named, .20 not blamed, not Done
$script:sim.nvrs = @(@{ ip = '192.168.1.20'; mac = 'C0-56-E3-00-00-01'; before = $netWrong; after = $good }, @{ ip = '192.168.1.19'; mac = 'C0-56-E3-00-00-02'; before = $netWrong; after = $ezDown })
$res.H = Pick (Run-Main)
# I. EZVIZ answers but without registerStatus: online is unknown, not ONLINE and not OFFLINE
$script:sim.nvrs = N1 $netWrong @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @($true, $true); ez_nostatus = $true }; $res.I = Pick (Run-Main)
# J. Check mode with the platform read failing: no write, not the all-right
$Mode = 'Check'
$script:sim.nvrs = N1 $ezDown $ezDown; $res.J = Pick (Run-Main)
Out-Result $res
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false 'F4 driver ran' $o }
  else {
    $allRight = 'Everything the tool can check looks right'
    Check ($j.A.code -ne 0 -and $j.A.said -notmatch '(?m)^Done\.' -and $j.A.said -notmatch 'ONLINE \(app should work\)') 'F4-A (Codex reproduce-classic) network fix + EZVIZ HTTP 500 after it: NOT "Done.", NOT "ONLINE (app should work)", exit not 0' ([string]$j.A.code + ' ' + $j.A.said)
    Check ($j.A.code -eq 4 -and $j.A.said -match 'platform NOT CHECKED' -and $j.A.said -match 'platform access NOT CHECKED' -and $j.A.said -match 'NOT DONE') '... the result line says platform NOT CHECKED, it is listed, NOT DONE, exit 4' ([string]$j.A.code + ' ' + $j.A.said)
    Check (@($j.A.writes) -contains 'net') '... and the network write really happened in this scenario (it is the post-fix check that is tested)' (@($j.A.writes) -join ',')
    Check ($j.A2.code -eq 4 -and $j.A2.said -notmatch $allRight -and $j.A2.said -notmatch '(?m)^Done\.' -and $j.A2.said -match 'NOT CHECKED' -and @($j.A2.writes).Count -eq 0) 'F4 running it twice (EZVIZ still failing, nothing to change): honest NOT CHECKED, exit 4, nothing written' ([string]$j.A2.code + ' ' + $j.A2.said)
    Check ($j.B.code -eq 4 -and $j.B.said -notmatch '(?m)^Done\.' -and $j.B.said -match 'network settings \(gateway / DNS\) could not be read after the fix - NOT CHECKED' -and $j.B.said -match 'gateway NOT CHECKED') 'F4-B final NETWORK read fails after the network fix: gateway/DNS NOT CHECKED (not the old values), not Done, exit 4' ([string]$j.B.code + ' ' + $j.B.said)
    Check ($j.C.code -eq 0 -and $j.C.said -match '(?m)^Done\.' -and $j.C.said -match 'ONLINE \(app should work\)' -and [int]$j.C.ez -ge 3) 'F4-C EZVIZ fails once after the fix, then answers ONLINE inside the wait: honest ONLINE, Done, exit 0 (and it was really read again)' ([string]$j.C.code + ' ez=' + $j.C.ez + ' ' + $j.C.said)
    Check ($j.C2.code -eq 4 -and $j.C2.said -notmatch '(?m)^Done\.' -and $j.C2.said -match 'platform NOT CHECKED' -and [int]$j.C2.ez -le 6) 'F4-C2 EZVIZ never answers again: the wait is bounded (a few reads), NOT CHECKED, exit 4' ([string]$j.C2.code + ' ez=' + $j.C2.ez + ' ' + $j.C2.said)
    Check ($j.D.code -eq 4 -and $j.D.said -notmatch '(?m)^Done\.' -and $j.D.said -match 'DIFFERENT device' -and $j.D.said -notmatch 'ONLINE \(app should work\)') 'F4-D wrong device: a different recorder answers at the NVR address after the fix: named, NOT CHECKED, not Done' ([string]$j.D.code + ' ' + $j.D.said)
    Check ($j.E.code -eq 4 -and $j.E.said -notmatch '(?m)^Done\.' -and $j.E.said -match 'platform NOT CHECKED') 'F4-E failing half-way: EZVIZ answers a login page (200, not EZVIZ): NOT CHECKED, not Done' ([string]$j.E.code + ' ' + $j.E.said)
    Check ($j.F.code -eq 4 -and $j.F.said -notmatch '(?m)^Done\.' -and $j.F.said -match 'gateway 192\.168\.1\.254 \(set 192\.168\.1\.1\)') 'F4-F the network reads back NOT as set (gateway): NOT OK, named, not Done' ([string]$j.F.code + ' ' + $j.F.said)
    Check ($j.G.code -eq 0 -and $j.G.said -match '(?m)^Done\.' -and $j.G.said -match 'ONLINE \(app should work\)' -and $j.G.said -notmatch 'NOT CHECKED') 'F4 no regression: a network fix that checks out is still Done / ONLINE / exit 0' ([string]$j.G.code + ' ' + $j.G.said)
    Check ($j.G2.code -eq 0 -and $j.G2.said -match $allRight -and @($j.G2.writes).Count -eq 0) 'F4 no regression: running it again on the fixed NVR = the all-right, nothing written' ([string]$j.G2.code + ' ' + $j.G2.said)
    Check ($j.H.code -eq 4 -and $j.H.said -notmatch '(?m)^Done\.' -and $j.H.said -match 'NVR 192\.168\.1\.19: platform access NOT CHECKED' -and $j.H.said -notmatch 'NVR 192\.168\.1\.20: platform') 'F4-H two recorders: the one whose EZVIZ read failed is named, the good one is not blamed, not Done' ([string]$j.H.code + ' ' + $j.H.said)
    Check ($j.I.code -eq 4 -and $j.I.said -notmatch '(?m)^Done\.' -and $j.I.said -notmatch 'ONLINE \(app should work\)' -and $j.I.said -match 'NOT CHECKED') 'F4-I EZVIZ answers without an online status: unknown = NOT CHECKED, not ONLINE' ([string]$j.I.code + ' ' + $j.I.said)
    Check ($j.J.code -eq 4 -and $j.J.said -notmatch $allRight -and $j.J.said -match 'NOT CHECKED' -and @($j.J.writes).Count -eq 0) 'F4-J Check mode with the platform read failing: NOT CHECKED, not the all-right, nothing written' ([string]$j.J.code + ' ' + $j.J.said)
  }

  # =====================================================================================
  Write-Host 'F4. the readers themselves: a failed read leaves the field unknown (Hik-Read, Unv-Read), never the value from before'
  $o = Invoke-Driver 'f4r' ($pre + "`n" + @'
$res = [ordered]@{}
$have = $false; try { $null = Get-Command Clear-FnReadState -ErrorAction Stop; $have = $true } catch {}
$res.have = $have
# Hik: a device that read ONLINE + gateway before; EZVIZ and network fail now
$bad = @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @($true); ez_fails = $true; net_fails = $true }
$script:sim.nvrs = N1 $bad $bad; $script:sim.phase = 'before'
$d = New-Dev '192.168.1.20' 'C0-56-E3-00-00-01' 'test'; $d.brand = 'hik'; $d.kind = 'nvr'; $d.platform_enabled = $true; $d.platform_online = $true; $d.gw = '10.9.9.9'; $d.dns1 = '9.9.9.9'
if ($have) { Clear-FnReadState $d } else { $d.login = '' }
Read-Dev $d
$res.hik = [ordered]@{ login = $d.login; pe = $d.platform_enabled; po = $d.platform_online; pr = $d.platform_read; gw = $d.gw; dns1 = $d.dns1; nr = $d.net_read }
# Uniview: DeviceBasicInfo answers, network / DNS / EZCloud reads fail
function Http([string]$ip, [string]$method, [string]$path, [string]$body = '', [string]$ctype = '', $cred = $null, [int]$timeout = 10) {
  if ($path -eq '/LAPI/V1.0/System/DeviceBasicInfo') { return @{ code = 200; body = '{"Response":{"ResponseCode":0,"Data":{"DeviceModel":"NVR301","SerialNumber":"U1","MAC":"48-EA-63-00-00-01","FirmwareVersion":"B1"}}}'; err = '' } }
  return @{ code = 500; body = ''; err = 'failed' }
}
$cfg.uniview = [pscustomobject]@{ cloud_path = '/LAPI/cloud'; net_path = '/LAPI/net'; dns_path = '/LAPI/dns'; channels_path = '/LAPI/ch' }
$u = New-Dev '192.168.1.30' '48-EA-63-00-00-01' 'test'; $u.brand = 'unv'; $u.kind = 'nvr'; $u.platform_enabled = $true; $u.dns1 = '9.9.9.9'; $u.net_json = '{"old":1}'
if ($have) { Clear-FnReadState $u } else { $u.login = '' }
Read-Dev $u
$res.unv = [ordered]@{ login = $u.login; pe = $u.platform_enabled; pr = $u.platform_read; dns1 = $u.dns1; dr = $u.dns_read; nj = $u.net_json; nr = $u.net_read }
Out-Result $res
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false 'F4 reader driver ran' $o }
  else {
    Check ($j.have -eq $true) 'F4 the after-fix reread first clears what the earlier read filled (Clear-FnReadState exists)' ([string]$j.have)
    Check ($j.hik.login -eq 'ok' -and $j.hik.pe -eq $null -and $j.hik.po -eq $null -and $j.hik.pr -eq $false) 'F4 Hik-Read: EZVIZ read failing = platform enabled/online unknown and marked not read (not the old ON/ONLINE)' ($o)
    Check ($j.hik.gw -ne '10.9.9.9' -and $j.hik.dns1 -ne '9.9.9.9' -and $j.hik.nr -eq $false) 'F4 Hik-Read: network read failing = gateway/DNS not the old values, marked not read' ($o)
    Check ($j.unv.login -eq 'ok' -and $j.unv.pe -eq $null -and $j.unv.pr -eq $false) 'F4 Unv-Read: EZCloud read failing = platform unknown, marked not read (not the old ON)' ($o)
    Check ($j.unv.dns1 -ne '9.9.9.9' -and $j.unv.dr -eq $false -and $j.unv.nj -ne '{"old":1}' -and $j.unv.nr -eq $false) 'F4 Unv-Read: network/DNS reads failing = not the old values, marked not read' ($o)
  }
  Deferred 'F4 a real Hikvision NVR whose EZVIZ / network read fails right after a real network move shows platform NOT CHECKED and NOT DONE in the Toolkit window'
  Deferred 'F4 a real Uniview NVR whose network / DNS / EZCloud read fails after the fix shows NOT CHECKED'
}
finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
Write-Host ''
Write-Host ('Test-Fix2214Classic: ' + $script:pass + ' passed, ' + $script:fail + ' failed' + $(if ($script:deferred) { ', ' + $script:deferred + ' deferred' } else { '' }))
if ($script:fail) { exit 1 } else { exit 0 }
