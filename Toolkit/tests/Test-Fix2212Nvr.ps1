<# Test-Fix2212Nvr.ps1 - behavioural tests for the 2.2.12 classic Fix NVR fixes (Codex review of 2.2.11 head 91d5353, findings P1-5 and P1-9).
   Every check RUNS the real FixNVR.ps1 functions (Invoke-Main, Restore-PcSettings, Remove-AllTemp, Invoke-LeftoverCleanup, Add-TempIp)
   in a child PowerShell with stand-ins for the devices and for the Windows network commands (no real adapter or device is touched).
   Codex's reproductions (reproduce-fixnvr.ps1 / R10) were not sent to us; these are our own, written from the review's evidence.
   NEEDS WINDOWS CHECK: Get-NetIPAddress / Get-NetRoute / netsh are stood in for here. Windows PowerShell 5.1 or pwsh 7. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$fnvPath = $(if ($env:FIX2212NVR_FILE) { $env:FIX2212NVR_FILE } else { Join-Path $repo 'FixNVR/FixNVR.ps1' })   # tests only: point at another copy (old-code proof)
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2212nvr-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + ($more -replace '\s+', ' ').Substring(0, [math]::Min(900, ($more -replace '\s+', ' ').Length))) } }
}
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
  # =====================================================================================
  Write-Host 'P1-5. classic Fix NVR: the finish depends on the check after the fix; "not checked" is not "OK"; a refused login is not green'
  # The real Invoke-Main with stand-ins for discovery and the recorder. $script:sim.after says what the NVR looks like when it is
  # read again after the change (the "Checking the result" step).
  $pre5 = $fnText + "`n" + '$ErrorActionPreference = ''Continue''; $here = ' + (Q (Join-Path $tmp 'p15here')) + "`n" + @'
$Mock = $null; $oui = @{}; $Version = 'test'; $Site = ''; $SniffSeconds = 0; $OldSubnet = @(); $Nvr = ''; $NoLogin = $false; $MoveUnlisted = $false; $AllowUnverifiedUniview = $false
$ConfirmWith = 'YES'; $snap = $null; $rb = $null; $script:routerStepShown = $false
$cfg = [pscustomobject]@{ arp_sniff_seconds = 0; max_old_subnets = 2; nvr_hosts = @(20, 19, 18); camera_block_start = 21; camera_block_end = 99; camera_channel_base = 20; camera_ip_mode = 'keep_last_octet'; router_dhcp_start = 100; dns1 = '8.8.8.8'; dns2 = '1.1.1.1'; verify_wait_seconds = 0; camera_wait_seconds = 0; poe_internal_subnets = @('192.168.254'); uniview = [pscustomobject]@{ cloud_path = '/x' } }
$pc = [pscustomobject]@{ ifIndex = 5; alias = 'Ethernet'; guid = '{0f1c2b9e-0d3a-4c55-9a51-2f0e5d7c1a11}'; dhcp = $true; ip = '192.168.1.105'; prefix = 24; gw = '192.168.1.1' }; $script:pcNet = $pc
$newP3 = '192.168.1'; $newMask = '255.255.255.0'
$plan = New-Object System.Collections.Generic.List[object]; $applied = New-Object System.Collections.Generic.List[object]
$script:devs = New-Object System.Collections.Generic.List[object]
$script:exitCode = 0
$runDir = Join-Path $here ('run-' + [guid]::NewGuid().ToString('N').Substring(0, 6)); New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$logFile = Join-Path $runDir 'log.txt'; $sum = New-Object System.Collections.Generic.List[string]
$script:sim = @{ phase = 'before'; reads = 0; writes = New-Object System.Collections.ArrayList; nvrs = @() }
function Open-Firewall { }
function Get-Creds { }
function Test-IpFree([string]$ip) { return $true }
function Start-Sleep { }
function Find-ArpSniff([int]$seconds) { return @{} }
function Find-Onvif($localIps) { return @{} }
function Find-Sadp($localIps) { $o = @{}; foreach ($n in $script:sim.nvrs) { $o[$n.mac] = [pscustomobject]@{ ip = $n.ip; mac = $n.mac; kind = 'nvr'; brand = 'hik'; model = 'DS-7608'; serial = 'S' + $n.ip; found_by = 'SADP'; dhcp = $false; mask = '255.255.255.0'; gw = '192.168.1.1' } }; return $o }
function Add-TempIp { return $null }
function Set-NvrState($d, $st) {
  if ($st.login -ne 'ok') { $d.login = $st.login; return }
  $d.login = 'ok'; $d.brand = 'hik'; $d.kind = 'nvr'; $d.addressing = 'static'; $d.mask = '255.255.255.0'; $d.gw = '192.168.1.1'; $d.dns1 = '8.8.8.8'; $d.dns2 = '1.1.1.1'; $d.net_xml = '<IPAddress/>'
  $d.platform_enabled = $st.platform_enabled; $d.platform_online = $st.platform_online
  # 2.2.14 (Codex F4): the real Hik-Read now marks each read that answered; this stand-in reader marks them the same way
  SetP $d 'net_read' $true; SetP $d 'platform_read' $true
  if ($st.cams) { $l = New-Object System.Collections.Generic.List[object]; $i = 0; foreach ($c in $st.cams) { $i++; $l.Add([pscustomobject]@{ id = [string]$i; ip = ''; port = ''; protocol = 'HIKVISION'; online = $c; poe = $false }) }; $d.channels = $l }
}
function Read-Dev($d) {
  if ($d.login -eq 'ok' -or $d.login -like 'REFUSED*') { return }
  $script:sim.reads++
  $n = @($script:sim.nvrs | Where-Object { $_.ip -eq $d.ip })[0]
  if ($script:sim.phase -eq 'before') { Set-NvrState $d $n.before } else { Set-NvrState $d $n.after }
  if ($d.login -eq 'ok') { SetP $d 'id_mac' $n.mac }   # 2.2.18: the real readers record the MAC the device itself reported (identity before a write)
}
function Http([string]$ip, [string]$method, [string]$path) {
  $n = @($script:sim.nvrs | Where-Object { $_.ip -eq $ip })[0]
  if ($path -like '*channels/status*') {
    if ($n.after.status_fails) { return @{ code = 0; body = ''; err = 'timed out' } }
    $b = '<InputProxyChannelStatusList>'; $i = 0; foreach ($c in $n.after.cams) { $i++; $b += '<InputProxyChannelStatus><id>' + $i + '</id><online>' + $(if ($c) { 'true' } else { 'false' }) + '</online></InputProxyChannelStatus>' }; return @{ code = 200; body = ($b + '</InputProxyChannelStatusList>'); err = '' }
  }
  if ($path -like '*EZVIZ*') { return @{ code = 200; body = ('<EZVIZ><enabled>true</enabled><registerStatus>' + $(if ($n.after.platform_online) { 'true' } else { 'false' }) + '</registerStatus></EZVIZ>'); err = '' } }
  return @{ code = 0; body = ''; err = 'not simulated' }
}
function Hik-EnablePlatform($dev) { [void]$script:sim.writes.Add('platform ' + $dev.ip); $script:sim.phase = 'after'; if ($script:sim.writeFails) { return @{ ok = $false; note = 'NVR said no' } }; return @{ ok = $true; note = '' } }
function Hik-SetNet { [void]$script:sim.writes.Add('net'); $script:sim.phase = 'after'; return @{ ok = $true; reboot = $false; note = '' } }
function Wait-Answer { return $true }
function Run-Main {
  $script:exitCode = 0; $sum.Clear(); $script:devs.Clear(); $plan.Clear(); $applied.Clear(); $script:sim.phase = 'before'; $script:sim.writes.Clear()
  try { Invoke-Main } catch { $sum.Add('ERROR ' + $_.Exception.Message + ' line ' + $_.InvocationInfo.ScriptLineNumber + ': ' + $_.InvocationInfo.Line.Trim()); $script:exitCode = 5 }
  return [pscustomobject]@{ code = $script:exitCode; said = (@($sum) -join "`n"); writes = @($script:sim.writes) }
}
function Out-Result($o) { 'JSON=' + ($o | ConvertTo-Json -Compress -Depth 5) }
$okNvr = @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @($true, $true) }
$offPlat = @{ login = 'ok'; platform_enabled = $false; platform_online = $false; cams = @($true, $true) }
'@
  $o = Invoke-Driver 'p15' ($pre5 + "`n" + @'
$Mode = 'Fix'
$res = [ordered]@{}
# A. Codex's case: the platform write is acknowledged, then the NVR cannot be read (2.2.11: "Done." / exit 0)
$script:sim.nvrs = @(@{ ip = '192.168.1.20'; mac = 'C0-56-E3-00-00-01'; before = $offPlat; after = @{ login = 'no answer (0)' } })
$r = Run-Main; $res.A = $r
# B. platform on but the camera status cannot be read after the fix
$script:sim.nvrs = @(@{ ip = '192.168.1.20'; mac = 'C0-56-E3-00-00-01'; before = $offPlat; after = @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @($true, $true); status_fails = $true } })
$res.B = Run-Main
# C. a camera still offline after the fix
$script:sim.nvrs = @(@{ ip = '192.168.1.20'; mac = 'C0-56-E3-00-00-01'; before = $offPlat; after = @{ login = 'ok'; platform_enabled = $true; platform_online = $true; cams = @($true, $false) } })
$res.C = Run-Main
# D. platform turned on but still NOT online after the wait
$script:sim.nvrs = @(@{ ip = '192.168.1.20'; mac = 'C0-56-E3-00-00-01'; before = $offPlat; after = @{ login = 'ok'; platform_enabled = $true; platform_online = $false; cams = @($true, $true) } })
$res.D = Run-Main
# E. Codex's second case: the NVR refuses the login -> no plan (2.2.11: green "Everything the tool can check looks right", exit 0)
$script:sim.nvrs = @(@{ ip = '192.168.1.20'; mac = 'C0-56-E3-00-00-01'; before = @{ login = 'REFUSED (wrong password? not retried)' }; after = @{ login = 'REFUSED (wrong password? not retried)' } })
$res.E = Run-Main
# E2. running it twice gives the same honest answer and still changes nothing
$res.E2 = Run-Main
# F. wrong device: one NVR refuses, the other gets fixed and checks out -> the refused one keeps the run from "Done."
$script:sim.nvrs = @(@{ ip = '192.168.1.20'; mac = 'C0-56-E3-00-00-01'; before = $offPlat; after = $okNvr }, @{ ip = '192.168.1.19'; mac = 'C0-56-E3-00-00-02'; before = @{ login = 'REFUSED (wrong password? not retried)' }; after = @{ login = 'REFUSED (wrong password? not retried)' } })
$res.F = Run-Main
# G. failing half-way: the platform write itself is refused
$script:sim.nvrs = @(@{ ip = '192.168.1.20'; mac = 'C0-56-E3-00-00-01'; before = $offPlat; after = $offPlat }); $script:sim.writeFails = $true
$res.G = Run-Main; $script:sim.writeFails = $false
# H. no regression: a real fix that checks out is still "Done." / exit 0
$script:sim.nvrs = @(@{ ip = '192.168.1.20'; mac = 'C0-56-E3-00-00-01'; before = $offPlat; after = $okNvr })
$res.H = Run-Main
# I. no regression: nothing to change and everything read = the green all-right, exit 0
$script:sim.nvrs = @(@{ ip = '192.168.1.20'; mac = 'C0-56-E3-00-00-01'; before = $okNvr; after = $okNvr })
$res.I = Run-Main
# J. Check mode with a refused login: not the all-right either
$Mode = 'Check'
$script:sim.nvrs = @(@{ ip = '192.168.1.20'; mac = 'C0-56-E3-00-00-01'; before = @{ login = 'REFUSED (wrong password? not retried)' }; after = @{ login = 'REFUSED (wrong password? not retried)' } })
$res.J = Run-Main
# K. Check mode, one NVR refused + one with a plan: the plan is shown, the refused one is NOT CHECKED, exit not 0
$script:sim.nvrs = @(@{ ip = '192.168.1.20'; mac = 'C0-56-E3-00-00-01'; before = $offPlat; after = $okNvr }, @{ ip = '192.168.1.19'; mac = 'C0-56-E3-00-00-02'; before = @{ login = 'REFUSED (wrong password? not retried)' }; after = @{ login = 'REFUSED (wrong password? not retried)' } })
$res.K = Run-Main
Out-Result $res
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false 'P1-5 driver ran' $o }
  else {
    $allRight = 'Everything the tool can check looks right'
    Check ($j.A.code -ne 0 -and $j.A.said -notmatch '(?m)^Done\.') 'P1-5 (Codex repro) platform write acknowledged, NVR unreadable after the fix: NOT "Done.", exit not 0' ([string]$j.A.code + ' ' + $j.A.said)
    Check ($j.A.code -eq 4 -and $j.A.said -match 'NOT CHECKED' -and $j.A.said -match 'NOT DONE') '... it says NOT CHECKED and NOT DONE (exit 4 = "PROBLEM lines above need a look" in the Toolkit)' ([string]$j.A.code + ' ' + $j.A.said)
    Check ($j.B.code -eq 4 -and $j.B.said -notmatch '(?m)^Done\.' -and $j.B.said -match 'camera status could not be read') 'P1-5 camera status unreadable after the fix: NOT CHECKED, not Done, exit 4' ([string]$j.B.code + ' ' + $j.B.said)
    Check ($j.C.code -eq 4 -and $j.C.said -notmatch '(?m)^Done\.' -and $j.C.said -match 'offline') 'P1-5 a camera still offline after the fix: not Done, exit 4' ([string]$j.C.code + ' ' + $j.C.said)
    Check ($j.D.code -eq 4 -and $j.D.said -notmatch '(?m)^Done\.' -and $j.D.said -match 'NOT online') 'P1-5 platform access on but still not online: not Done, exit 4' ([string]$j.D.code + ' ' + $j.D.said)
    Check ($j.E.code -ne 0 -and $j.E.said -notmatch $allRight) 'P1-5 (Codex repro) refused login: NOT the green all-right message, exit not 0' ([string]$j.E.code + ' ' + $j.E.said)
    Check ($j.E.code -eq 2 -and $j.E.said -match 'NOT CHECKED' -and $j.E.said -match 'login refused' -and @($j.E.writes).Count -eq 0) '... it says NOT CHECKED / login refused, exit 2 ("could not read the recorder"), nothing written' ([string]$j.E.code + ' ' + $j.E.said)
    Check ($j.E2.code -eq 2 -and $j.E2.said -notmatch $allRight -and @($j.E2.writes).Count -eq 0) 'P1-5 running it twice: same honest answer, still nothing written' ([string]$j.E2.code + ' ' + $j.E2.said)
    Check ($j.F.code -eq 4 -and $j.F.said -notmatch '(?m)^Done\.' -and $j.F.said -match '192\.168\.1\.19[^\n]*NOT CHECKED' -and @($j.F.writes) -contains 'platform 192.168.1.20') 'P1-5 wrong device: the good NVR is fixed, the refused NVR is NOT CHECKED and keeps the run from Done (exit 4)' ([string]$j.F.code + ' ' + $j.F.said)
    Check ($j.G.code -eq 4 -and $j.G.said -notmatch '(?m)^Done\.') 'P1-5 failing half-way (the write is refused): not Done, exit 4 (unchanged)' ([string]$j.G.code + ' ' + $j.G.said)
    Check ($j.H.code -eq 0 -and $j.H.said -match '(?m)^Done\.' -and $j.H.said -notmatch 'NOT CHECKED') 'P1-5 no regression: a fix that checks out (NVR read, platform online, cameras online) is still Done / exit 0' ([string]$j.H.code + ' ' + $j.H.said)
    Check ($j.I.code -eq 0 -and $j.I.said -match $allRight) 'P1-5 no regression: nothing to change and everything read = the all-right, exit 0' ([string]$j.I.code + ' ' + $j.I.said)
    Check ($j.J.code -ne 0 -and $j.J.said -notmatch $allRight -and $j.J.said -match 'NOT CHECKED') 'P1-5 Check mode with a refused login: NOT CHECKED, not the all-right, exit not 0' ([string]$j.J.code + ' ' + $j.J.said)
    Check ($j.K.code -eq 4 -and $j.K.said -match 'Check only' -and $j.K.said -match '192\.168\.1\.19[^\n]*NOT CHECKED' -and @($j.K.writes).Count -eq 0) 'P1-5 Check mode, one NVR refused + a plan for the other: plan shown, the refused one NOT CHECKED, exit 4, nothing written' ([string]$j.K.code + ' ' + $j.K.said)
  }

  # =====================================================================================
  Write-Host 'P1-9. classic Fix NVR clean-up: "back to normal" = a working connection (address + default route), journal kept until then'
  $pre9 = $fnText + "`n" + '$ErrorActionPreference = ''Continue''; $Mock = $null; $stateDir = ' + (Q (Join-Path $tmp 'p19')) + '; New-Item -ItemType Directory -Force -Path $stateDir | Out-Null' + "`n" + '$logFile = Join-Path $stateDir ''log.txt''; $tempFile = Join-Path $stateDir (''temp-ips-'' + [guid]::NewGuid().ToString(''N'').Substring(0, 6) + ''.json'')' + "`n" + @'
$sum = New-Object System.Collections.Generic.List[string]
$script:temps = New-Object System.Collections.Generic.List[object]
$script:pcChanges = [ordered]@{ coexistence_before = $null; firewall_rule = $false; cleanup_task = $false; ifIndex = $null; alias = $null; dhcp = $null; ip = $null; gw = $null }
$taskName = 'WireIt FixNVR cleanup'; $cfg = [pscustomobject]@{ temp_ip_hosts = @(253, 252, 247); safety_cleanup_minutes = 30 }
$script:FnRecoverTries = 4; $script:FnRecoverWaitSec = 0
# the adapter: its own lease (192.168.1.105 from the router) and default route can be taken away; leaseAfter = the lease comes back after N reads
$script:sim = @{ addrs = New-Object System.Collections.ArrayList; removeWorks = $true; dhcp = 'Enabled'; coexist = 'disabled'; netshGarbage = $false; calls = New-Object System.Collections.ArrayList; task = $false; lease = $true; route = $true; routeIf = 5; leaseIp = '192.168.1.105'; leaseAfter = 0; reads = 0; sleeps = 0 }
function New-NetIPAddress { param($InterfaceIndex, $IPAddress, $PrefixLength, $SkipAsSource, $PolicyStore, $ErrorAction) [void]$script:sim.calls.Add('add ' + $IPAddress); [void]$script:sim.addrs.Add([pscustomobject]@{ IPAddress = $IPAddress; InterfaceIndex = $InterfaceIndex; SkipAsSource = $true; PolicyStore = 'ActiveStore'; AddressState = 'Preferred' }) }
function Remove-NetIPAddress { param($IPAddress, $InterfaceIndex, $PolicyStore, [switch]$Confirm, $ErrorAction) [void]$script:sim.calls.Add('remove ' + $IPAddress + '@' + $InterfaceIndex); if ($script:sim.removeWorks) { foreach ($x in @($script:sim.addrs | Where-Object { $_.IPAddress -eq $IPAddress -and (-not $InterfaceIndex -or $_.InterfaceIndex -eq $InterfaceIndex) })) { $script:sim.addrs.Remove($x) } } }
function Get-NetIPAddress { param($InterfaceIndex, $IPAddress, $AddressFamily, $ErrorAction)
  $all = @($script:sim.addrs)
  if (-not $IPAddress) { $script:sim.reads++ }
  $leaseOn = $script:sim.lease -and $script:sim.reads -gt $script:sim.leaseAfter
  if ($leaseOn) { $all += [pscustomobject]@{ IPAddress = $script:sim.leaseIp; InterfaceIndex = 5; SkipAsSource = $false; PolicyStore = 'ActiveStore'; AddressState = 'Preferred' } }
  else { $all += [pscustomobject]@{ IPAddress = '169.254.20.7'; InterfaceIndex = 5; SkipAsSource = $false; PolicyStore = 'ActiveStore'; AddressState = 'Preferred' } }
  return @($all | Where-Object { (-not $IPAddress -or $_.IPAddress -eq $IPAddress) -and (-not $InterfaceIndex -or $_.InterfaceIndex -eq $InterfaceIndex) }) }
function Get-NetRoute { param($DestinationPrefix, $InterfaceIndex, $AddressFamily, $ErrorAction)
  if (-not $script:sim.route -or ($script:sim.reads -le $script:sim.leaseAfter)) { return @() }
  return @([pscustomobject]@{ DestinationPrefix = '0.0.0.0/0'; NextHop = '192.168.1.1'; ifIndex = $script:sim.routeIf; InterfaceIndex = $script:sim.routeIf } | Where-Object { -not $InterfaceIndex -or $_.InterfaceIndex -eq $InterfaceIndex }) }
function Get-NetIPInterface { param($InterfaceIndex, $AddressFamily, $ErrorAction) return [pscustomobject]@{ Dhcp = $script:sim.dhcp } }
function Set-NetIPInterface { param($InterfaceIndex, $AddressFamily, $Dhcp, $ErrorAction) [void]$script:sim.calls.Add('dhcp ' + $Dhcp); $script:sim.dhcp = $Dhcp }
# 2.2.19 (Codex 2.2.18 F05): the clean-up checks the adapter number still belongs to the recorded adapter (name) before any change
# 2.2.20 (Codex 2.2.19 R02): every adapter change checks the saved name AND InterfaceGuid, so the stand-in adapter has its ID too
function Get-NetAdapter { param($InterfaceIndex, $ErrorAction) return [pscustomobject]@{ Name = 'Ethernet'; InterfaceIndex = 5; InterfaceGuid = '{0f1c2b9e-0d3a-4c55-9a51-2f0e5d7c1a11}' } }
function netsh { [void]$script:sim.calls.Add('netsh ' + ($args -join ' ')); if (($args -join ' ') -match 'coexistence=(\w+)') { $script:sim.coexist = $Matches[1] }; $global:LASTEXITCODE = 0; if (($args -join ' ') -match 'show interface') { if ($script:sim.netshGarbage) { return @('Schnittstelle 5 Parameter', 'DHCP/Statische IP-Koexistenz : deaktiviert') }; return @('DHCP/Static IP coexistence     : ' + $script:sim.coexist) } }
function Register-ScheduledTask { $script:sim.task = $true }
function Unregister-ScheduledTask { [void]$script:sim.calls.Add('unregister'); $script:sim.task = $false }
function New-ScheduledTaskAction { 1 }; function New-ScheduledTaskTrigger { 1 }; function New-ScheduledTaskPrincipal { 1 }
function Remove-NetFirewallRule { }
function Start-Sleep { $script:sim.sleeps++ }
$pc = [pscustomobject]@{ ifIndex = 5; alias = 'Ethernet'; guid = '{0f1c2b9e-0d3a-4c55-9a51-2f0e5d7c1a11}'; dhcp = $true; ip = '192.168.1.105'; prefix = 24; gw = '192.168.1.1' }
$script:pcNet = $pc
function Reset-Run { $script:temps.Clear(); $script:pcChanges = [ordered]@{ coexistence_before = $null; firewall_rule = $false; cleanup_task = $false; ifIndex = $null; alias = $null; dhcp = $null; ip = $null; gw = $null }; $script:sim.calls.Clear(); $script:sim.reads = 0; $script:sim.sleeps = 0 }
$out = [ordered]@{}
'@
  $o = Invoke-Driver 'p19a' ($pre9 + "`n" + @'
# A. Codex R10: DHCP comes back "Enabled" but the adapter has no lease (169.254 only) and no default route
$ip = Add-TempIp '192.168.0' $pc @()
$script:sim.lease = $false; $script:sim.route = $false
$ok = Remove-AllTemp
$out.A_ok = [bool]$ok; $out.A_journal = (Test-Path -LiteralPath $tempFile); $out.A_unreg = (@($script:sim.calls) -contains 'unregister'); $out.A_reads = $script:sim.reads; $out.A_sleeps = $script:sim.sleeps
# A2. the next start (start-up clean-up) with the network still not back: journal kept, FAILED again
$script:temps.Clear(); $script:sim.calls.Clear(); $script:sim.reads = 0
$out.A2_ok = [bool](Invoke-LeftoverCleanup); $out.A2_journal = (Test-Path -LiteralPath $tempFile)
# A3. the lease and route come back: the start-up clean-up checks them and only then deletes the journal
$script:sim.lease = $true; $script:sim.route = $true; $script:sim.calls.Clear(); $script:sim.reads = 0
$out.A3_ok = [bool](Invoke-LeftoverCleanup); $out.A3_journal = (Test-Path -LiteralPath $tempFile); $out.A3_unreg = (@($script:sim.calls) -contains 'unregister')
# A4. running the clean-up twice is fine
$out.A4_ok = [bool](Invoke-LeftoverCleanup)
'JSON=' + ($out | ConvertTo-Json -Compress -Depth 4)
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false 'P1-9 driver A ran' $o }
  else {
    Check (-not $j.A_ok) 'P1-9 (Codex R10) DHCP "Enabled" but no lease and no default route: clean-up is NOT a success' $o
    Check ($j.A_journal -and -not $j.A_unreg) '... the journal and the safety clean-up task are kept' $o
    Check ($j.A_reads -ge 4 -and $j.A_sleeps -ge 3) '... Windows was given renewal time (it looked again several times, waiting between)' ('reads ' + $j.A_reads + ' sleeps ' + $j.A_sleeps)
    Check ($o -match 'FAILED - Run again' -and $o -match 'no working address from the router') '... it says FAILED - Run again and why (no working address from the router)' $o
    Check (-not $j.A2_ok -and $j.A2_journal) 'P1-9 the next start with the network still not back: FAILED again, journal still kept' $o
    Check ($j.A3_ok -and -not $j.A3_journal -and $j.A3_unreg) 'P1-9 once the lease and route are back: clean-up checks out, then deletes the journal and the safety task' $o
    Check ($j.A4_ok) 'P1-9 running the clean-up twice is fine' $o
  }
  $o = Invoke-Driver 'p19b' ($pre9 + "`n" + @'
# B. the lease is slow: it comes back on the 3rd look -> success after waiting, journal deleted
$ip = Add-TempIp '192.168.0' $pc @()
$script:sim.reads = 0; $script:sim.leaseAfter = 2
$ok = Remove-AllTemp
$out.B_ok = [bool]$ok; $out.B_journal = (Test-Path -LiteralPath $tempFile); $out.B_sleeps = $script:sim.sleeps; $out.B_left = @($script:sim.addrs | ForEach-Object { $_.IPAddress })
$script:sim.leaseAfter = 0
# C. the netsh answer cannot be read (another Windows language): coexistence is NOT called restored
Reset-Run; $ip = Add-TempIp '192.168.0' $pc @(); $out.C_ip = [string]$ip
$script:sim.netshGarbage = $true; $logLen = ([IO.File]::ReadAllText($logFile)).Length
$out.C_ok = [bool](Remove-AllTemp); $out.C_journal = (Test-Path -LiteralPath $tempFile)
$out.C_log = ([IO.File]::ReadAllText($logFile)).Substring($logLen)
# C2. ...and a run that starts on such a PC adds no temporary address and changes nothing
Remove-Item -LiteralPath $tempFile -Force; Reset-Run; $script:sim.coexist = 'disabled'
$ip2 = Add-TempIp '192.168.0' $pc @()
$out.C2_ip = [string]$ip2; $out.C2_calls = @($script:sim.calls); $out.C2_coexist = $script:sim.coexist
$script:sim.netshGarbage = $false
# D. wrong adapter: the default route is on ANOTHER adapter (ifIndex 9), the saved one (5) has none
Reset-Run; $ip = Add-TempIp '192.168.0' $pc @(); $script:sim.routeIf = 9
$out.D_ok = [bool](Remove-AllTemp); $out.D_journal = (Test-Path -LiteralPath $tempFile)
$script:sim.routeIf = 5; $out.D2_ok = [bool](Invoke-LeftoverCleanup); $out.D2_journal = (Test-Path -LiteralPath $tempFile)
# E. a fixed-address PC (static 192.168.1.50): its own address must be back, an address from somewhere else does not count
Reset-Run; $pcS = [pscustomobject]@{ ifIndex = 5; alias = 'Ethernet'; guid = '{0f1c2b9e-0d3a-4c55-9a51-2f0e5d7c1a11}'; dhcp = $false; ip = '192.168.1.50'; prefix = 24; gw = '192.168.1.1' }; $script:pcNet = $pcS
$ip = Add-TempIp '192.168.0' $pcS @(); $out.E_ip = [string]$ip
$out.E_ok = [bool](Remove-AllTemp); $out.E_journal = (Test-Path -LiteralPath $tempFile)
$j0 = Get-Content -LiteralPath $tempFile -Raw | ConvertFrom-Json; $out.E_savedIp = [string]$j0.pc.ip
$script:sim.leaseIp = '192.168.1.50'
$script:temps.Clear(); $out.E2_ok = [bool](Invoke-LeftoverCleanup); $out.E2_journal = (Test-Path -LiteralPath $tempFile)
$script:sim.leaseIp = '192.168.1.105'; $script:pcNet = $pc
# F. a run that never touched this PC (no temporary address) is not blamed for a network that is down
Reset-Run; $script:sim.lease = $false; $script:sim.route = $false
$out.F_ok = [bool](Remove-AllTemp)
'JSON=' + ($out | ConvertTo-Json -Compress -Depth 4)
'@)
  $j = Get-Json $o
  if (-not $j) { Check $false 'P1-9 driver B ran' $o }
  else {
    Check ($j.B_ok -and -not $j.B_journal -and $j.B_sleeps -ge 2 -and -not @($j.B_left).Count) 'P1-9 a slow lease (back on the 3rd look): clean-up waits for it, then succeeds and deletes the journal' $o
    Check ($j.C_ip -and -not $j.C_ok -and $j.C_journal) 'P1-9 netsh answer that cannot be read: coexistence is NOT called restored, journal kept (2.2.11 logged "coexistence restored")' $o
    Check ($j.C_log -notmatch 'coexistence restored' -and $j.C_log -match 'read-back not understood') '... and the log says the answer was not understood, not "coexistence restored"' $j.C_log
    Check (-not $j.C2_ip -and -not @($j.C2_calls | Where-Object { $_ -match 'coexistence=enabled' -or $_ -like 'add *' }).Count) 'P1-9 a run starting on a PC whose netsh answer cannot be read adds no temporary address and changes nothing' (($j.C2_calls) -join ' | ')
    Check (-not $j.D_ok -and $j.D_journal) 'P1-9 wrong adapter: a default route on another adapter does not count; journal kept' $o
    Check ($j.D2_ok -and -not $j.D2_journal) '... and once the saved adapter has its route, the next start clears it' $o
    Check ($j.E_ip -and $j.E_savedIp -eq '192.168.1.50' -and -not $j.E_ok -and $j.E_journal) 'P1-9 fixed-address PC: its own address (saved in the journal) must be back; another address does not count' $o
    Check ($j.E2_ok -and -not $j.E2_journal) '... with its own address and router back the start-up clean-up succeeds' $o
    Check ($j.F_ok) 'P1-9 a run that never touched this PC''s network is not failed for a network that is down' $o
  }
}
finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ''
Write-Host ('Test-Fix2212Nvr: ' + $script:pass + ' passed, ' + $script:fail + ' failed')
exit $script:fail
