<# Test-Fix2220Classic.ps1 - tests for WireIt Toolkit 2.2.20 (Nov 11 2026): the classic Fix NVR (FixNVR/FixNVR.ps1) and CamReset part of
   Codex's NO-GO review of 2.2.19 (head ca8d5b3). Every Codex reproduction for these findings is a check here (asserting the SAFE
   result), plus at least one check per twin fixed in the class sweep:
   R02 (class B)  every adapter change (add / remove a temporary address, coexistence, DHCP) and every read that certifies one goes
                  through one fresh saved-identity gate (name AND InterfaceGuid as saved); leftover clean-up no longer caches it.
   R06 (class B)  an NVR channel is changed only while the camera the step saved (MAC / serial) is confirmed at its address.
   R07 (class A/C) clearing the damaged-record block needs a COMPLETE positive check: no SkipAsSource address of any number, and every
                  connected adapter readable with its own working address.
   R08 (class E)  the clean-up journal (and the undo file) are type-checked before ANY recovery write ("dhcp":"false" is damaged).
   R09 (class C)  a network answer without a mask / gateway field is "not read"; Undo with an unknown old mode is refused BEFORE writing.
   class C twins  Hik-Ok / Hik-Read / Onvif-Read / Onvif-SetNet / Uniview reads need the expected document, not any HTTP 200;
                  CamReset says "default password works" only from a real device-information reply.
   class A twins  Save-Json reads the file back; a recovery record is "removed" only when it is gone; CamReset's try record reads back.
   Every check RUNS the real functions (loaded from the file, like Codex's reproduce*.ps1) in a child PowerShell; only Windows network
   commands, device web answers and selected file failures are stood in for. A check marked (code shape) reads the source instead.
   NEEDS WINDOWS / REAL DEVICE CHECK (DEFERRED, never PASS): Windows PowerShell 5.1, real Get-NetAdapter / netsh, real devices.
   FIX2220CLASSIC_FILE (tests only) = a repo folder (or FixNVR.ps1) to test instead of this one (old-code proof: on 2.2.19 the
   finding checks FAIL). #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$target = $(if ($env:FIX2220CLASSIC_FILE) { $env:FIX2220CLASSIC_FILE } else { $repo })
if (Test-Path -LiteralPath $target -PathType Container) { $fnvPath = Join-Path $target 'FixNVR/FixNVR.ps1'; $crPath = Join-Path $target 'CamReset/Find-Cameras.ps1' }
else { $fnvPath = $target; $crPath = Join-Path (Split-Path -Parent (Split-Path -Parent $target)) 'CamReset/Find-Cameras.ps1' }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2220classic-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Pass([string]$n) { $script:pass++; Write-Host ('PASS ' + $n) }
function Fail([string]$n, [string]$why) { $script:fail++; Write-Host ('FAIL ' + $n + ' -- ' + $why) }
function Deferred([string]$n) { $script:deferred++; Write-Host ('DEFERRED ' + $n) }

# The child prelude: the real FixNVR.ps1 functions (no top-level code runs), quiet Log/Say, no sleeping, a temp state folder.
$prelude = @'
param([string]$FnvPath, [string]$CrPath, [string]$Work)
$ErrorActionPreference = 'Continue'
$ast = [Management.Automation.Language.Parser]::ParseFile($FnvPath, [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { . ([scriptblock]::Create($f.Extent.Text)) }
function Log { param($s) }
function Say { param($s, $color) }
function Write-Host { param($Object, $ForegroundColor) }
function Start-Sleep { param($Seconds) }
function Set-SafetyTask { }
$Mock = $null; $IsPs5 = $false
$cfg = [pscustomobject]@{ temp_ip_hosts = @(253, 252, 247); camera_wait_seconds = 5; verify_wait_seconds = 5; safety_cleanup_minutes = 30; dns1 = '8.8.8.8'; dns2 = '1.1.1.1' }
$stateDir = $Work; $tempFile = Join-Path $Work 'temp-ips.json'; $taskName = 'WireIt FixNVR cleanup (test)'
$script:temps = New-Object 'System.Collections.Generic.List[object]'
$script:pcChanges = [ordered]@{ coexistence_before = $null; firewall_rule = $false; cleanup_task = $false; ifIndex = $null; alias = $null; guid = $null; dhcp = $null; ip = $null; gw = $null }
$script:devs = New-Object 'System.Collections.Generic.List[object]'
$script:refused = @{}; $script:nvrTls = @{}; $script:scheme = @{}
$script:credCam = New-Object PSCredential('admin', (ConvertTo-SecureString 'Test-only-1' -AsPlainText -Force)); $script:credNvr = $script:credCam
function Unregister-ScheduledTask { [CmdletBinding()] param($TaskName, [switch]$Confirm) }
function Remove-NetFirewallRule { [CmdletBinding()] param($DisplayName) }
# adapter stand-in: calls 1..$script:goodCalls answer the saved adapter, later calls a REPLACEMENT at the same number
$script:goodCalls = 0; $script:adapterCalls = 0
function Get-NetAdapter { [CmdletBinding()] param($InterfaceIndex) $script:adapterCalls++; if ($script:adapterCalls -le $script:goodCalls) { [pscustomobject]@{ Name = 'Ethernet'; InterfaceGuid = '{GUID-A}' } } else { [pscustomobject]@{ Name = 'REPLACEMENT'; InterfaceGuid = '{GUID-B}' } } }
$script:adds = 0; $script:removes = 0; $script:coexSets = 0; $script:dhcpSets = 0
function New-NetIPAddress { [CmdletBinding()] param($InterfaceIndex, $IPAddress, $PrefixLength, $SkipAsSource, $PolicyStore) $script:adds++ }
function Remove-NetIPAddress { [CmdletBinding()] param($IPAddress, $InterfaceIndex, $PolicyStore, [switch]$Confirm) $script:removes++; $script:gone[[string]$IPAddress] = $true }
function Set-NetIPInterface { [CmdletBinding()] param($InterfaceIndex, $AddressFamily, $Dhcp) $script:dhcpSets++ }
$script:gone = @{}
function Test-TempGone([string]$ip, $ifIndex) { return [bool]$script:gone[$ip] }
$script:coexNow = 'disabled'
function netsh { $a = @($args) -join ' '; if ($a -match 'set interface') { $script:coexSets++; if ($a -match 'enabled') { $script:coexNow = 'enabled' } else { $script:coexNow = 'disabled' }; return 'Ok.' }; return ('DHCP/Static IP coexistence : ' + $script:coexNow) }
function Get-NetIPAddress { [CmdletBinding()] param($InterfaceIndex, $IPAddress, $AddressFamily) @([pscustomobject]@{ IPAddress = '192.168.1.10'; SkipAsSource = $false; AddressState = 'Preferred'; ifIndex = 5; PrefixLength = 24 }) }
function Get-NetRoute { [CmdletBinding()] param($DestinationPrefix, $InterfaceIndex, $AddressFamily) @([pscustomobject]@{ NextHop = '192.168.1.1'; ifIndex = 5 }) }
function Get-NetIPInterface { [CmdletBinding()] param($InterfaceIndex, $AddressFamily) @([pscustomobject]@{ ConnectionState = 'Connected'; InterfaceAlias = 'Ethernet'; ifIndex = 5; Dhcp = 'Disabled' }) }
function Say-Result([bool]$ok, [string]$detail) { if ($ok) { [Console]::Out.WriteLine('RESULT OK ' + $detail) } else { [Console]::Out.WriteLine('RESULT BAD ' + $detail) } }
'@

function Run-Check([string]$name, [string]$body) {
  $work = Join-Path $tmp ([guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force -Path $work | Out-Null
  $f = Join-Path $work 'check.ps1'
  [IO.File]::WriteAllText($f, ($prelude + "`n" + $body), (New-Object Text.UTF8Encoding($false)))
  $out = ''
  try { $out = (& $exe -NoProfile -ExecutionPolicy Bypass -File $f -FnvPath $fnvPath -CrPath $crPath -Work $work 2>&1 | Out-String) } catch { $out = 'child failed: ' + $_.Exception.Message }
  $m = [regex]::Match($out, 'RESULT (OK|BAD)([^\r\n]*)')
  if ($m.Success -and $m.Groups[1].Value -eq 'OK') { Pass $name }
  elseif ($m.Success) { Fail $name ('unsafe result:' + $m.Groups[2].Value) }
  else { $tail = ($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | '; Fail $name ('no result (the code under test does not have this behaviour): ' + $tail) }
}
function Src-Has([string]$path, [string]$rx) { return ([IO.File]::ReadAllText($path) -match $rx) }

Write-Host ('Testing ' + $fnvPath)

# ---------------- R02 (class B): one fresh saved-identity gate for every adapter change ----------------
Run-Check 'R02 Codex classic-add-replacement: adapter number 5 is now another adapter (name / GUID) -> Add-TempIp adds NO address' @'
$script:goodCalls = 0
$pc = [pscustomobject]@{ ifIndex = 5; alias = 'Ethernet'; guid = '{GUID-A}'; dhcp = $false; ip = '10.0.0.10'; gw = '10.0.0.1' }
$a = Add-TempIp '192.168.99' $pc @()
Say-Result ($script:adds -eq 0 -and -not $a) ("returned=$a adds=$script:adds")
'@
Run-Check 'R02 Codex classic-remove-replacement: adapter replaced -> Remove-OneTemp removes nothing and keeps the address journaled' @'
$script:goodCalls = 0
$script:pcChanges.ifIndex = 5; $script:pcChanges.alias = 'Ethernet'; $script:pcChanges.guid = '{GUID-A}'; $script:pcChanges.dhcp = $false
$script:temps.Add([pscustomobject]@{ ip = '192.168.99.253'; ifIndex = 5 })
$r = Remove-OneTemp '192.168.99.253' 5
Say-Result ($script:removes -eq 0 -and -not $r -and $script:temps.Count -eq 1) ("returned=$r removes=$script:removes kept=$($script:temps.Count)")
'@
Run-Check 'R02 twin: DHCP PC, adapter replaced before the coexistence change -> netsh coexistence is NOT switched' @'
$script:goodCalls = 0
$pc = [pscustomobject]@{ ifIndex = 5; alias = 'Ethernet'; guid = '{GUID-A}'; dhcp = $true; ip = '10.0.0.10'; gw = '10.0.0.1' }
$a = Add-TempIp '192.168.99' $pc @()
Say-Result ($script:coexSets -eq 0 -and $script:adds -eq 0) ("coexSets=$script:coexSets adds=$script:adds")
'@
Run-Check 'R02 twin: adapter replaced between the record save and the add -> fresh check right before New-NetIPAddress refuses' @'
$script:goodCalls = 1
$pc = [pscustomobject]@{ ifIndex = 5; alias = 'Ethernet'; guid = '{GUID-A}'; dhcp = $false; ip = '10.0.0.10'; gw = '10.0.0.1' }
$a = Add-TempIp '192.168.99' $pc @()
Say-Result ($script:adds -eq 0 -and -not $a -and $script:temps.Count -eq 0) ("returned=$a adds=$script:adds journaled=$($script:temps.Count) adapterReads=$script:adapterCalls")
'@
Run-Check 'R02 twin: the adapter ID (InterfaceGuid) could not be read -> no temporary address (unreadable = refuse)' @'
$script:goodCalls = 99
$pc = [pscustomobject]@{ ifIndex = 5; alias = 'Ethernet'; guid = ''; dhcp = $false; ip = '10.0.0.10'; gw = '10.0.0.1' }
$a = Add-TempIp '192.168.99' $pc @()
Say-Result ($script:adds -eq 0 -and -not $a) ("returned=$a adds=$script:adds")
'@
Run-Check 'R02 twin: in-run clean-up (Remove-AllTemp) on a replaced adapter removes nothing and says FAILED' @'
$script:goodCalls = 0
$script:pcChanges.ifIndex = 5; $script:pcChanges.alias = 'Ethernet'; $script:pcChanges.guid = '{GUID-A}'; $script:pcChanges.dhcp = $false; $script:pcChanges.ip = '192.168.1.10'; $script:pcChanges.gw = '192.168.1.1'
$script:temps.Add([pscustomobject]@{ ip = '192.168.99.253'; ifIndex = 5 })
$r = Remove-AllTemp
Say-Result ($script:removes -eq 0 -and -not $r) ("returned=$r removes=$script:removes")
'@
Run-Check 'R02 twin: leftover clean-up checks the adapter again for EACH address (no identity cached per number)' @'
$script:goodCalls = 1
Save-Json ([ordered]@{ version = 2; temps = @([pscustomobject]@{ ip = '192.168.99.253'; ifIndex = 5 }, [pscustomobject]@{ ip = '192.168.99.252'; ifIndex = 5 }); pc = [ordered]@{ coexistence_before = $null; firewall_rule = $false; cleanup_task = $false; ifIndex = 5; alias = 'Ethernet'; guid = '{GUID-A}'; dhcp = $false; ip = '192.168.1.10'; gw = '192.168.1.1' } }) $tempFile
$r = Invoke-LeftoverCleanup
Say-Result ($script:removes -le 1 -and -not $script:gone['192.168.99.252'] -and -not $r) ("returned=$r removes=$script:removes secondRemoved=$([bool]$script:gone['192.168.99.252'])")
'@
Run-Check 'R02 twin: Restore-PcSettings checks the adapter again right before the DHCP change (not once for all changes)' @'
$script:goodCalls = 2; $script:coexNow = 'enabled'
function Get-NetIPInterface { [CmdletBinding()] param($InterfaceIndex, $AddressFamily) [pscustomobject]@{ ConnectionState = 'Connected'; InterfaceAlias = 'Ethernet'; ifIndex = 5; Dhcp = 'Disabled' } }
$p = @(); $pcc = [pscustomobject]@{ coexistence_before = 'disabled'; dhcp = $true; ip = ''; gw = ''; alias = 'Ethernet'; guid = '{GUID-A}'; changed = $true }
Restore-PcSettings $pcc 5 ([ref]$p)
Say-Result ($script:dhcpSets -eq 0 -and $p.Count -gt 0) ("dhcpSets=$script:dhcpSets problems=$($p.Count)")
'@
Run-Check 'R02 twin: "network back to normal" is believed only when the adapter it was read from is still the saved one' @'
$script:goodCalls = 1
$p = @(); $pcc = [pscustomobject]@{ coexistence_before = $null; dhcp = $false; ip = '192.168.1.10'; gw = '192.168.1.1'; alias = 'Ethernet'; guid = '{GUID-A}'; changed = $true }
$script:FnRecoverTries = 1
Restore-PcSettings $pcc 5 ([ref]$p)
Say-Result ($p.Count -gt 0) ("problems=$($p.Count) adapterReads=$script:adapterCalls")
'@
Run-Check 'R02 keeps working: the saved adapter (same name and GUID) gets its temporary address' @'
$script:goodCalls = 99
$pc = [pscustomobject]@{ ifIndex = 5; alias = 'Ethernet'; guid = '{GUID-A}'; dhcp = $false; ip = '10.0.0.10'; gw = '10.0.0.1' }
function Get-NetIPAddress { [CmdletBinding()] param($InterfaceIndex, $IPAddress, $AddressFamily) [pscustomobject]@{ IPAddress = $IPAddress; AddressState = 'Preferred'; SkipAsSource = $true } }
$a = Add-TempIp '192.168.99' $pc @()
Say-Result ($script:adds -eq 1 -and $a -eq '192.168.99.253') ("returned=$a adds=$script:adds")
'@

# ---------------- R06 (class B): the camera owning the channel is identified before its channel is replaced ----------------
$httpStub = @'
$script:chAddr = '192.168.1.60'; $script:chWrites = 0; $script:camMacAnswer = 'AA:BB:CC:00:00:99'; $script:reqs = @()
function Http {
  param($ip, $method, $path, $body, $ctype, $cred, $timeout)
  $script:reqs += ($ip + ' ' + $method + ' ' + $path)
  if ($method -eq 'PUT') { $script:chWrites++; $script:chAddr = '192.168.1.50'; return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>'; err = '' } }
  # 2.2.21 (Codex 2.2.20 F01): the NVR is identified again before the channel PUT, so the stand-in NVR (as Read-FnIdentity hands it over:
  # with its MAC and serial) answers its own DeviceInfo
  if ($path -eq '/ISAPI/System/deviceInfo' -and $ip -eq '192.168.1.19') { return @{ code = 200; body = '<DeviceInfo><model>DS-7608NI</model><deviceType>NVR</deviceType><macAddress>AA:BB:CC:00:00:19</macAddress><serialNumber>NVR19</serialNumber></DeviceInfo>'; err = '' } }
  if ($path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = ('<DeviceInfo><model>DS-2CD</model><deviceType>IPCamera</deviceType><macAddress>' + $script:camMacAnswer + '</macAddress><serialNumber>CAM9</serialNumber></DeviceInfo>'); err = '' } }
  if ($path -like '/ISAPI/ContentMgmt/InputProxy/channels/*') { return @{ code = 200; body = ('<InputProxyChannel><id>1</id><sourceInputPortDescriptor><ipAddress>' + $script:chAddr + '</ipAddress><userName>admin</userName><password>x</password></sourceInputPortDescriptor></InputProxyChannel>'); err = '' } }
  return @{ code = 404; body = ''; err = '' }
}
'@
Run-Check 'R06 Codex classic-channel-no-camera-identity: no camera identity for the channel -> the channel is LEFT ALONE' ($httpStub + "`n" + @'
$r = Hik-SetChannel ([pscustomobject]@{ ip = '192.168.1.19'; mac = 'AA:BB:CC:00:00:19'; serial = 'NVR19' }) '1' '192.168.1.50' '192.168.1.60'
Say-Result ($script:chWrites -eq 0 -and -not $r.ok) ("writes=$script:chWrites ok=$($r.ok)")
'@)
Run-Check 'R06 twin: another live camera (different MAC) now answers at the channel''s camera address -> channel NOT replaced' ($httpStub + "`n" + @'
$script:camMacAnswer = 'AA:BB:CC:00:00:99'
$r = Hik-SetChannel ([pscustomobject]@{ ip = '192.168.1.19'; mac = 'AA:BB:CC:00:00:19'; serial = 'NVR19' }) '1' '192.168.1.50' '192.168.1.60' '192.168.1.60' 'AA-BB-CC-00-00-01' ''
Say-Result ($script:chWrites -eq 0 -and -not $r.ok -and $r.refused) ("writes=$script:chWrites ok=$($r.ok) note=$($r.note)")
'@)
Run-Check 'R06 twin: the channel''s camera does not answer (moved / gone) -> channel NOT replaced, NOT CHECKED' ($httpStub + "`n" + @'
function Http { param($ip, $method, $path, $body, $ctype, $cred, $timeout) if ($method -eq 'PUT') { $script:chWrites++ }; if ($path -like '/ISAPI/ContentMgmt/InputProxy/channels/*') { return @{ code = 200; body = '<InputProxyChannel><id>1</id><sourceInputPortDescriptor><ipAddress>192.168.1.60</ipAddress></sourceInputPortDescriptor></InputProxyChannel>'; err = '' } }; return @{ code = 0; body = ''; err = 'timed out' } }
$r = Hik-SetChannel ([pscustomobject]@{ ip = '192.168.1.19'; mac = 'AA:BB:CC:00:00:19'; serial = 'NVR19' }) '1' '192.168.1.50' '192.168.1.60' '192.168.1.60' 'AA-BB-CC-00-00-01' ''
Say-Result ($script:chWrites -eq 0 -and -not $r.ok -and ([string]$r.note -match 'NOT CHECKED')) ("writes=$script:chWrites note=$($r.note)")
'@)
Run-Check 'R06 keeps working: the saved camera (same MAC) is confirmed -> the channel is changed and read back' ($httpStub + "`n" + @'
$script:camMacAnswer = 'AA:BB:CC:00:00:01'
$r = Hik-SetChannel ([pscustomobject]@{ ip = '192.168.1.19'; mac = 'AA:BB:CC:00:00:19'; serial = 'NVR19' }) '1' '192.168.1.50' '192.168.1.60' '192.168.1.60' 'AA-BB-CC-00-00-01' ''
Say-Result ($script:chWrites -eq 1 -and $r.ok) ("writes=$script:chWrites ok=$($r.ok) note=$($r.note)")
'@)
if ((Src-Has $fnvPath "type = 'nvr-channel'[^\r\n]*cam_mac = ") -and (Src-Has $fnvPath 'Hik-SetChannel \$id\.dev \$st\.channel \$to \$from \(\[string\]\$st\.new_ip\) \$cm \$cs')) { Pass 'R06 (code shape) the channel step saves the camera''s MAC / serial and the step passes them (and its address) to Hik-SetChannel' } else { Fail 'R06 (code shape) the channel step saves the camera''s MAC / serial and the step passes them (and its address) to Hik-SetChannel' 'not found in the source' }

# ---------------- R07 (class A/C): complete positive check before the damaged-record block is cleared ----------------
$r07 = @'
function Get-FnBootTime { Get-Date }
function Get-PcNet { [pscustomobject]@{ ip = '10.0.0.100'; gw = '10.0.0.1' } }
function netsh { 'DHCP/Static IP coexistence : disabled' }
$file = [pscustomobject]@{ Name = 'temp-ips.unreadable-20260101-000000.json'; LastWriteTime = [datetime]'2026-01-01' }
'@
Run-Check 'R07 Codex classic-clear-with-unrecovered-static-and-skip: SkipAsSource .123 + a broken fixed adapter -> NOT cleared' ($r07 + "`n" + @'
function Get-NetIPAddress { [CmdletBinding()] param($AddressFamily) @([pscustomobject]@{ IPAddress = '10.0.0.100'; SkipAsSource = $false; ifIndex = 5 }, [pscustomobject]@{ IPAddress = '10.0.0.123'; SkipAsSource = $true; ifIndex = 6 }) }
function Get-NetIPInterface { [CmdletBinding()] param($AddressFamily) @([pscustomobject]@{ ConnectionState = 'Connected'; InterfaceAlias = 'Ethernet'; ifIndex = 5; Dhcp = 'Enabled' }, [pscustomobject]@{ ConnectionState = 'Connected'; InterfaceAlias = 'BrokenStatic'; ifIndex = 6; Dhcp = 'Disabled' }) }
$w = Get-FnUnreadableClearWhy $file
Say-Result ([bool]$w) ("reason='$w'")
'@)
Run-Check 'R07 twin: no SkipAsSource left, but a connected fixed adapter has no working address of its own -> NOT cleared' ($r07 + "`n" + @'
function Get-NetIPAddress { [CmdletBinding()] param($AddressFamily) @([pscustomobject]@{ IPAddress = '10.0.0.100'; SkipAsSource = $false; ifIndex = 5 }, [pscustomobject]@{ IPAddress = '169.254.3.4'; SkipAsSource = $false; ifIndex = 6 }) }
function Get-NetIPInterface { [CmdletBinding()] param($AddressFamily) @([pscustomobject]@{ ConnectionState = 'Connected'; InterfaceAlias = 'Ethernet'; ifIndex = 5; Dhcp = 'Enabled' }, [pscustomobject]@{ ConnectionState = 'Connected'; InterfaceAlias = 'BrokenStatic'; ifIndex = 6; Dhcp = 'Disabled' }) }
$w = Get-FnUnreadableClearWhy $file
Say-Result ([bool]$w) ("reason='$w'")
'@)
Run-Check 'R07 twin: a SkipAsSource address whose last number is NOT in today''s temp_ip_hosts still blocks the clear' ($r07 + "`n" + @'
function Get-NetIPAddress { [CmdletBinding()] param($AddressFamily) @([pscustomobject]@{ IPAddress = '10.0.0.100'; SkipAsSource = $false; ifIndex = 5 }, [pscustomobject]@{ IPAddress = '192.168.99.240'; SkipAsSource = $true; ifIndex = 5 }) }
function Get-NetIPInterface { [CmdletBinding()] param($AddressFamily) @([pscustomobject]@{ ConnectionState = 'Connected'; InterfaceAlias = 'Ethernet'; ifIndex = 5; Dhcp = 'Enabled' }) }
$w = Get-FnUnreadableClearWhy $file
Say-Result ([bool]$w) ("reason='$w'")
'@)
Run-Check 'R07 twin: a connected adapter whose DHCP setting cannot be read -> NOT cleared' ($r07 + "`n" + @'
function Get-NetIPAddress { [CmdletBinding()] param($AddressFamily) @([pscustomobject]@{ IPAddress = '10.0.0.100'; SkipAsSource = $false; ifIndex = 5 }) }
function Get-NetIPInterface { [CmdletBinding()] param($AddressFamily) @([pscustomobject]@{ ConnectionState = 'Connected'; InterfaceAlias = 'Ethernet'; ifIndex = 5; Dhcp = '' }) }
$w = Get-FnUnreadableClearWhy $file
Say-Result ([bool]$w) ("reason='$w'")
'@)
Run-Check 'R07 keeps working: restarted, no SkipAsSource, every connected adapter has its own address, router reached -> cleared' ($r07 + "`n" + @'
function Get-NetIPAddress { [CmdletBinding()] param($AddressFamily) @([pscustomobject]@{ IPAddress = '10.0.0.100'; SkipAsSource = $false; ifIndex = 5; PrefixLength = 24 }, [pscustomobject]@{ IPAddress = '192.168.50.2'; SkipAsSource = $false; ifIndex = 6; PrefixLength = 24 }) }
function Get-NetIPInterface { [CmdletBinding()] param($AddressFamily) @([pscustomobject]@{ ConnectionState = 'Connected'; InterfaceAlias = 'Ethernet'; ifIndex = 5; Dhcp = 'Enabled' }, [pscustomobject]@{ ConnectionState = 'Connected'; InterfaceAlias = 'Cameras'; ifIndex = 6; Dhcp = 'Disabled' }) }
$w = Get-FnUnreadableClearWhy $file
Say-Result (-not $w) ("reason='$w'")
'@)

# ---------------- R08 (class E): journal TYPES checked before any recovery write ----------------
function J08([string]$name, [string]$json) {
  Run-Check $name ("`$j = '" + $json.Replace("'", "''") + "' | ConvertFrom-Json`n" + '$w = Get-FnJournalWhy $j' + "`n" + 'Say-Result ([bool]$w) ("journalWhy=''$w''")')
}
J08 'R08 Codex classic-damaged-dhcp: "dhcp":"false" (text, PowerShell reads it as TRUE) -> the journal is damaged' '{"version":2,"temps":[{"ip":"192.168.99.253","ifIndex":5}],"pc":{"coexistence_before":"disabled","firewall_rule":false,"cleanup_task":false,"ifIndex":5,"alias":"Ethernet","dhcp":"false","ip":"10.0.0.10","gw":"10.0.0.1"}}'
J08 'R08 twin: "firewall_rule":"false" (text) -> damaged' '{"version":2,"temps":[],"pc":{"coexistence_before":null,"firewall_rule":"false","cleanup_task":false,"ifIndex":null,"alias":null,"dhcp":null,"ip":null,"gw":null}}'
J08 'R08 twin: adapter number as text "5" -> damaged' '{"version":2,"temps":[{"ip":"192.168.99.253","ifIndex":"5"}],"pc":{"coexistence_before":null,"firewall_rule":false,"cleanup_task":false,"ifIndex":"5","alias":"Ethernet","guid":"{GUID-A}","dhcp":false,"ip":"10.0.0.10","gw":"10.0.0.1"}}'
J08 'R08 twin: a coexistence value Windows never gives ("maybe") -> damaged' '{"version":2,"temps":[],"pc":{"coexistence_before":"maybe","firewall_rule":false,"cleanup_task":false,"ifIndex":5,"alias":"Ethernet","guid":"{GUID-A}","dhcp":true,"ip":"10.0.0.10","gw":"10.0.0.1"}}'
J08 'R08 twin: a temporary address that does not parse (999.1.1.1) -> damaged' '{"version":2,"temps":[{"ip":"999.1.1.1","ifIndex":5}],"pc":{"coexistence_before":null,"firewall_rule":false,"cleanup_task":false,"ifIndex":5,"alias":"Ethernet","guid":"{GUID-A}","dhcp":false,"ip":"10.0.0.10","gw":"10.0.0.1"}}'
J08 'R08 twin: version as text "2" -> damaged' '{"version":"2","temps":[],"pc":{"coexistence_before":null,"firewall_rule":false,"cleanup_task":false,"ifIndex":null,"alias":null,"dhcp":null,"ip":null,"gw":null}}'
J08 'R08 twin: the PC''s own address is not an address ("10.0.0") -> damaged' '{"version":2,"temps":[],"pc":{"coexistence_before":null,"firewall_rule":false,"cleanup_task":false,"ifIndex":5,"alias":"Ethernet","guid":"{GUID-A}","dhcp":false,"ip":"10.0.0","gw":"10.0.0.1"}}'
Run-Check 'R08 twin: Restore-PcSettings given "dhcp":"false" switches NOTHING on (no DHCP change, record kept)' @'
$script:goodCalls = 99
function Get-NetIPInterface { [CmdletBinding()] param($InterfaceIndex, $AddressFamily) [pscustomobject]@{ ConnectionState = 'Connected'; InterfaceAlias = 'Ethernet'; ifIndex = 5; Dhcp = 'Disabled' } }
$p = @(); $pcc = [pscustomobject]@{ coexistence_before = $null; dhcp = 'false'; ip = '10.0.0.10'; gw = '10.0.0.1'; alias = 'Ethernet'; guid = '{GUID-A}' }
Restore-PcSettings $pcc 5 ([ref]$p)
Say-Result ($script:dhcpSets -eq 0 -and $p.Count -gt 0) ("dhcpSets=$script:dhcpSets problems=$($p.Count)")
'@
Run-Check 'R08 keeps working: a journal exactly as Write-TempState writes it is accepted' @'
$script:pcChanges.ifIndex = 5; $script:pcChanges.alias = 'Ethernet'; $script:pcChanges.guid = '{GUID-A}'; $script:pcChanges.dhcp = $true; $script:pcChanges.ip = '10.0.0.10'; $script:pcChanges.gw = '10.0.0.1'; $script:pcChanges.coexistence_before = 'disabled'
$script:temps.Add([pscustomobject]@{ ip = '192.168.99.253'; ifIndex = [uint32]5 })
$ok = Write-TempState
$j = Get-Content $tempFile -Raw | ConvertFrom-Json
$w = Get-FnJournalWhy $j
Say-Result ($ok -and -not $w) ("saved=$ok journalWhy='$w'")
'@
Run-Check 'R08 twin (undo file): a rollback file whose step says "done":"false" (text) is refused before Undo sends anything' @'
$rb = '{"steps":[{"type":"cam-net","how":"isapi","kind":"camera","brand":"hik","dev_mac":"AA-BB-CC-00-00-01","dev_serial":"S1","old_ip":"10.0.0.20","new_ip":"192.168.1.20","old_mask":"255.255.255.0","old_gw":"10.0.0.1","old_dns1":"","old_dns2":"","old_addressing":"static","done":"false","attempted":true}]}' | ConvertFrom-Json
$w = Get-FnRollbackWhy $rb
Say-Result ([bool]$w) ("why='$w'")
'@
Run-Check 'R08 twin (undo file): an undo step with an unknown kind or an old address that does not parse is refused' @'
$rb1 = '{"steps":[{"type":"cam-moved","how":"isapi","dev_mac":"AA-BB-CC-00-00-01","old_ip":"10.0.0.20","new_ip":"192.168.1.20","done":true}]}' | ConvertFrom-Json
$rb2 = '{"steps":[{"type":"cam-net","how":"isapi","dev_mac":"AA-BB-CC-00-00-01","old_ip":"10.0.0","new_ip":"192.168.1.20","old_mask":"255.255.255.0","old_gw":"","old_dns1":"","old_dns2":"","old_addressing":"static","done":true}]}' | ConvertFrom-Json
$w1 = Get-FnRollbackWhy $rb1; $w2 = Get-FnRollbackWhy $rb2
Say-Result ([bool]$w1 -and [bool]$w2) ("why1='$w1' why2='$w2'")
'@
Run-Check 'R08 keeps working (undo file): a rollback file as the Fix run writes it is accepted' @'
$plan = New-Object 'System.Collections.Generic.List[object]'
$plan.Add([pscustomobject]@{ type = 'cam-net'; how = 'isapi'; kind = 'camera'; brand = 'hik'; dev_mac = 'AA-BB-CC-00-00-01'; dev_serial = 'S1'; channel = '1'; old_ip = '10.0.0.20'; new_ip = '192.168.1.20'; old_mask = '255.255.255.0'; new_mask = '255.255.255.0'; old_gw = '10.0.0.1'; new_gw = '192.168.1.1'; old_dns1 = ''; old_dns2 = ''; old_addressing = 'static'; done = $true; result = 'done'; attempted = $true })
$plan.Add([pscustomobject]@{ type = 'nvr-channel'; how = 'isapi'; kind = 'nvr'; brand = 'hik'; dev_mac = 'AA-BB-CC-00-00-02'; dev_serial = 'N1'; nvr_ip = '10.0.0.19'; channel = '1'; old_ip = '10.0.0.20'; new_ip = '192.168.1.20'; cam_mac = 'AA-BB-CC-00-00-01'; cam_serial = 'S1'; done = $false; result = ''; attempted = $true })
$plan.Add([pscustomobject]@{ type = 'nvr-platform'; how = 'isapi'; kind = 'nvr'; brand = 'hik'; dev_mac = 'AA-BB-CC-00-00-02'; dev_serial = 'N1'; nvr_ip = '10.0.0.19'; done = $false; result = '' })
$f = Join-Path $Work 'rollback.json'; Save-Json ([ordered]@{ tool = 'x'; steps = $plan }) $f
$rb = Get-Content $f -Raw | ConvertFrom-Json
$w = Get-FnRollbackWhy $rb
Say-Result (-not $w) ("why='$w'")
'@

# ---------------- R09 (class C): missing network fields are NOT read; unknown old mode refused before writing ----------------
Run-Check 'R09 Codex classic-missing-mask-gateway: Hikvision answer with no mask / gateway -> read=False' @'
$d = [pscustomobject]@{ brand = 'hik'; net_read = $true; net_ip = '10.0.0.20'; addressing = 'static'; mask = ''; gw = ''; dns1 = ''; dns2 = '' }
$n = Get-FnNetNow $d
Say-Result (-not $n.read) ("read=$($n.read) why='$($n.why)'")
'@
$hikNet = @'
function Http { param($ip, $method, $path, $body, $ctype, $cred, $timeout)
  if ($path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = '<DeviceInfo><model>DS-2CD</model><deviceType>IPCamera</deviceType><macAddress>AA:BB:CC:00:00:01</macAddress></DeviceInfo>'; err = '' } }
  if ($path -eq '/ISAPI/System/Network/interfaces') { return @{ code = 200; body = '<NetworkInterfaceList><NetworkInterface><id>1</id><IPAddress><ipAddress>10.0.0.20</ipAddress></IPAddress></NetworkInterface></NetworkInterfaceList>'; err = '' } }
  if ($path -like '*/ipAddress') { return @{ code = 200; body = $script:netDoc; err = '' } }
  return @{ code = 404; body = ''; err = '' } }
'@
Run-Check 'R09 twin: a real Hik-Read of an IPAddress document with NO DefaultGateway element -> Get-FnNetNow read=False' ($hikNet + "`n" + @'
$script:netDoc = '<IPAddress><ipVersion>v4</ipVersion><addressingType>static</addressingType><ipAddress>10.0.0.20</ipAddress><subnetMask>255.255.255.0</subnetMask></IPAddress>'
$d = New-Dev '10.0.0.20' 'AA:BB:CC:00:00:01' 'test'; [void](Hik-Read $d); $n = Get-FnNetNow $d
Say-Result (-not $n.read) ("read=$($n.read) why='$($n.why)'")
'@)
Run-Check 'R09 twin: a Hikvision mask that is not a mask (255.0.255.0) -> read=False' ($hikNet + "`n" + @'
$script:netDoc = '<IPAddress><addressingType>static</addressingType><ipAddress>10.0.0.20</ipAddress><subnetMask>255.0.255.0</subnetMask><DefaultGateway><ipAddress>10.0.0.1</ipAddress></DefaultGateway></IPAddress>'
$d = New-Dev '10.0.0.20' 'AA:BB:CC:00:00:01' 'test'; [void](Hik-Read $d); $n = Get-FnNetNow $d
Say-Result (-not $n.read) ("read=$($n.read) why='$($n.why)'")
'@)
Run-Check 'R09 keeps working: a complete Hikvision IPAddress document reads (an empty DNS stays a real "none")' ($hikNet + "`n" + @'
$script:netDoc = '<IPAddress><addressingType>static</addressingType><ipAddress>10.0.0.20</ipAddress><subnetMask>255.255.255.0</subnetMask><DefaultGateway><ipAddress>10.0.0.1</ipAddress></DefaultGateway><PrimaryDNS><ipAddress></ipAddress></PrimaryDNS><SecondaryDNS><ipAddress></ipAddress></SecondaryDNS></IPAddress>'
# 2.2.21 (Codex 2.2.20 F06): "complete" now means BOTH DNS fields are in the answer (empty is a real none); a document without
# SecondaryDNS is unknown and is refused (Test-Repro2220 classic-missing-dns)
$d = New-Dev '10.0.0.20' 'AA:BB:CC:00:00:01' 'test'; [void](Hik-Read $d); $n = Get-FnNetNow $d
Say-Result ($n.read -and $n.mask -eq '255.255.255.0' -and $n.gw -eq '10.0.0.1' -and $n.dns1 -eq '' -and $n.dns2 -eq '') ("read=$($n.read) why='$($n.why)'")
'@)
Run-Check 'R09 twin (ONVIF): a gateway answer with no NetworkGateway element -> read=False' @'
function Onvif { param($ip, $inner, $cred)
  if ($inner -like '*GetNetworkInterfaces*') { return @{ code = 200; body = '<s:Envelope><s:Body><tds:GetNetworkInterfacesResponse><tds:NetworkInterfaces token="eth0"><tt:Info><tt:HwAddress>AA:BB:CC:00:00:01</tt:HwAddress></tt:Info><tt:IPv4><tt:Config><tt:Manual><tt:Address>10.0.0.20</tt:Address><tt:PrefixLength>24</tt:PrefixLength></tt:Manual><tt:DHCP>false</tt:DHCP></tt:Config></tt:IPv4></tds:NetworkInterfaces></tds:GetNetworkInterfacesResponse></s:Body></s:Envelope>' } }
  if ($inner -like '*GetNetworkDefaultGateway*') { return @{ code = 200; body = '<s:Envelope><s:Body><tds:GetNetworkDefaultGatewayResponse></tds:GetNetworkDefaultGatewayResponse></s:Body></s:Envelope>' } }
  if ($inner -like '*GetDNS*') { return @{ code = 200; body = '<s:Envelope><s:Body><tds:GetDNSResponse><tds:DNSInformation><tt:FromDHCP>false</tt:FromDHCP></tds:DNSInformation></tds:GetDNSResponse></s:Body></s:Envelope>' } }
  return @{ code = 500; body = '' } }
$n = Onvif-ReadNet ([pscustomobject]@{ ip = '10.0.0.20'; kind = 'camera' })
Say-Result (-not $n.read) ("read=$($n.read)")
'@
Run-Check 'R09 twin (Uniview): a network answer whose ResponseCode is an error -> net_read False (not a setting to keep)' @'
$cfg | Add-Member -NotePropertyName uniview -NotePropertyValue ([pscustomobject]@{ net_path = '/LAPI/V1.0/Network/Interface'; dns_path = '/LAPI/V1.0/Network/DNS'; cloud_path = ''; channels_path = '/LAPI/V1.0/Channels' })
function Http { param($ip, $method, $path, $body, $ctype, $cred, $timeout)
  if ($path -like '*DeviceBasicInfo') { return @{ code = 200; body = '{"Response":{"ResponseCode":0,"Data":{"DeviceModel":"NVR301","SerialNumber":"U1","MAC":"48-EA-63-00-00-01","FirmwareVersion":"B1"}}}'; err = '' } }
  if ($path -eq '/LAPI/V1.0/Network/Interface') { return @{ code = 200; body = '{"Response":{"ResponseCode":60006,"ResponseString":"Not Authorized","Data":{"IPv4Address":{"IPAddress":"","SubnetMask":"","DefaultGateway":""}}}}'; err = '' } }
  return @{ code = 404; body = ''; err = '' } }
$d = New-Dev '10.0.0.30' '48-EA-63-00-00-01' 'test'; $d.brand = 'unv'; [void](Unv-Read $d)
Say-Result ($d.net_read -ne $true) ("net_read=$($d.net_read)")
'@
if (Src-Has $fnvPath "if \(\`$rev -and -not \`$stOldMode\) \{ \`$res = @\{ ok = \`$false; refused = \`$true") {
  # the refusal must come BEFORE the write in both the camera and the NVR network steps
  $s = [IO.File]::ReadAllText($fnvPath); $iCam = $s.IndexOf("'cam-net' {"); $iNvr = $s.IndexOf("'nvr-net' {")
  $rCam = $s.IndexOf('if ($rev -and -not $stOldMode)', $iCam); $wCam = $s.IndexOf('Hik-SetNet $d', $iCam)
  $rNvr = $s.IndexOf('if ($rev -and -not $stOldMode)', $iNvr); $wNvr = $s.IndexOf('Hik-SetNet $n', $iNvr)
  if ($rCam -gt 0 -and $rCam -lt $wCam -and $rNvr -gt 0 -and $rNvr -lt $wNvr) { Pass 'R09 (code shape) Undo with an unknown saved addressing mode is refused BEFORE the camera / NVR network write (both steps)' } else { Fail 'R09 (code shape) Undo with an unknown saved addressing mode is refused BEFORE the camera / NVR network write (both steps)' 'refusal not before the write' }
} else { Fail 'R09 (code shape) Undo with an unknown saved addressing mode is refused BEFORE the camera / NVR network write (both steps)' 'no refusal before the write' }

# ---------------- class C twins: HTTP 200 alone proves nothing ----------------
Run-Check 'class C twin: Hik-Ok on an HTTP 200 login page (no ResponseStatus) is NOT an accepted write' @'
$ok = Hik-Ok @{ code = 200; body = '<html><body>Please log in</body></html>' }
$ok2 = Hik-Ok @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' }
Say-Result ((-not $ok) -and $ok2) ("loginPage=$ok responseStatus=$ok2")
'@
Run-Check 'class C twin: Hik-Read on an HTTP 200 that is not a DeviceInfo document -> NOT logged in' @'
function Http { param($ip, $method, $path) return @{ code = 200; body = '<html>Login</html>'; err = '' } }
$d = New-Dev '10.0.0.20' '' 'test'; $r = Hik-Read $d
Say-Result ((-not $r) -and $d.login -ne 'ok') ("returned=$r login=$($d.login)")
'@
Run-Check 'class C twin: Onvif-Read on an HTTP 200 SOAP Fault -> NOT read, not "ok (ONVIF)"' @'
function Onvif { param($ip, $inner, $cred) return @{ code = 200; body = '<s:Envelope><s:Body><s:Fault><s:Reason>Sender not authorized</s:Reason></s:Fault></s:Body></s:Envelope>' } }
$d = New-Dev '10.0.0.20' '' 'test'; $r = Onvif-Read $d
Say-Result ((-not $r) -and $d.login -notlike 'ok*') ("returned=$r login=$($d.login)")
'@
Run-Check 'class B/C twin: Onvif-SetNet identifies the camera again before the DNS write (a different MAC there = no SetDNS)' @'
$script:hwCalls = 0; $script:dnsSets = 0
function Onvif { param($ip, $inner, $cred)
  if ($inner -like '*SetNetworkInterfaces*') { return @{ code = 200; body = '<s:Envelope><s:Body><tds:SetNetworkInterfacesResponse><tds:RebootNeeded>false</tds:RebootNeeded></tds:SetNetworkInterfacesResponse></s:Body></s:Envelope>' } }
  if ($inner -like '*GetNetworkInterfaces*') { $script:hwCalls++; $m = $(if ($script:hwCalls -le 1) { 'AA:BB:CC:00:00:01' } else { 'AA:BB:CC:00:00:99' }); return @{ code = 200; body = ('<tds:GetNetworkInterfacesResponse><tt:HwAddress>' + $m + '</tt:HwAddress></tds:GetNetworkInterfacesResponse>') } }
  if ($inner -like '*SetNetworkDefaultGateway*') { return @{ code = 200; body = '<tds:SetNetworkDefaultGatewayResponse/>' } }
  if ($inner -like '*SetDNS*') { $script:dnsSets++; return @{ code = 200; body = '<tds:SetDNSResponse/>' } }
  return @{ code = 500; body = '' } }
$dev = [pscustomobject]@{ ip = '10.0.0.20'; mac = 'AA-BB-CC-00-00-01'; kind = 'camera'; onvif_token = 'eth0' }
$r = Onvif-SetNet $dev '192.168.1.20' 24 '192.168.1.1' '8.8.8.8' ''
Say-Result ($script:dnsSets -eq 0 -and -not $r.ok) ("dnsSets=$script:dnsSets ok=$($r.ok)")
'@

# ---------------- class A twins: records read back / removals verified ----------------
Run-Check 'class A twin: a recovery record whose delete silently did nothing is NOT reported removed (Remove-FnRecordChecked)' @'
$f = Join-Path $Work 'rec.json'; [IO.File]::WriteAllText($f, '{}')
$g = Join-Path $Work 'rec2.json'; [IO.File]::WriteAllText($g, '{}')
$real = Remove-FnRecordChecked $g
function Remove-Item { [CmdletBinding()] param($LiteralPath, [switch]$Force) }
$r = Remove-FnRecordChecked $f
Say-Result ($real -eq $true -and $r -eq $false -and (Test-Path -LiteralPath $f)) ("silentDelete=$r realDelete=$real")
'@
if ((Src-Has $fnvPath 'does not read back as written') -and (Src-Has $fnvPath 'Remove-FnRecordChecked \$tempFile')) { Pass 'class A (code shape) Save-Json reads the final file back (exact text + JSON) and both journal deletions are verified' } else { Fail 'class A (code shape) Save-Json reads the final file back (exact text + JSON) and both journal deletions are verified' 'not found in the source' }

# ---------------- CamReset (class A / C twins) ----------------
$crLoad = @'
$cast = [Management.Automation.Language.Parser]::ParseFile($CrPath, [ref]$null, [ref]$null)
foreach ($f in $cast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { if ($f.Name -notin @('Log', 'Say')) { . ([scriptblock]::Create($f.Extent.Text)) } }
'@
Run-Check 'CamReset class C twin: an HTTP 200 login page / error reply is NOT "default password works"' ($crLoad + "`n" + @'
$a = Test-CrUnvInfoDoc '<html><body>login</body></html>'
$b = Test-CrUnvInfoDoc '{"Response":{"ResponseCode":60006,"Data":{}}}'
$c = Test-CrUnvInfoDoc '{"Response":{"ResponseCode":0,"Data":{"SerialNumber":"210235C3EN3000000000","DeviceModel":"IPC322"}}}'
Say-Result ((-not $a) -and (-not $b) -and $c) ("html=$a error=$b real=$c")
'@)
Run-Check 'CamReset class A twin: a try-record write that silently did not land = NO try (the line is read back first)' ($crLoad + "`n" + @'
$f = Join-Path $Work 'default-tried.txt'; $g = Join-Path $Work 'default-tried-real.txt'
$real = Add-CrTryRecord $g '10.0.0.6 2026-11-11'
function Add-Content { [CmdletBinding()] param($LiteralPath, $Value) }
$r = Add-CrTryRecord $f '10.0.0.5 2026-11-11'
Say-Result ($real -eq $true -and $r -eq $false) ("silentWrite=$r realWrite=$real")
'@)
if ((Test-Path -LiteralPath $crPath) -and (Src-Has $crPath 'if \(-not \(Test-CrUnvInfoDoc \$info\)\)') -and (Src-Has $crPath 'Add-CrTryRecord \$tried \$todayKey')) { Pass 'CamReset (code shape) the try uses the read-back record and YES only from a real device-information reply' } else { Fail 'CamReset (code shape) the try uses the read-back record and YES only from a real device-information reply' 'not found in the source' }

Deferred 'Windows PowerShell 5.1 run of these checks, real Get-NetAdapter / Remove-NetIPAddress / netsh, real Hikvision / Uniview / ONVIF devices (NEEDS WINDOWS / REAL DEVICE CHECK)'
try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
Write-Host ''
Write-Host ('Test-Fix2220Classic: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:deferred + ' deferred')
if ($script:fail) { exit 1 } else { exit 0 }
