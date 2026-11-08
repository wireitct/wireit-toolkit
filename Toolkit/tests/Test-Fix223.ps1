<#
 Test-Fix223.ps1 - WireIt Toolkit 2.2.3 tests: Codex's full review of toolkit-2.2.2-fixes @5e465b9 (Nov 8 2026).
 One block per finding (#N = Codex's number). A check marked "reproduction" failed on 5e465b9 (2.2.2).
 Device calls are faked by redefining Fs-Http (no sockets) unless a block says otherwise. pwsh 7 or Windows PowerShell 5.1.
 Usage: pwsh -File Test-Fix223.ps1   (exit code = number of failed checks)
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path; $tk = Split-Path -Parent $here; $repo = Split-Path -Parent $tk
$script:fail = 0; $script:pass = 0
function Check([bool]$ok, [string]$what) { if ($ok) { $script:pass++; Write-Host ('  ok    ' + $what) } else { $script:fail++; Write-Host ('  FAIL  ' + $what) -ForegroundColor Red } }
function Eq($a, $b, [string]$what) { Check ("$a" -eq "$b") ($what + ' (got "' + $a + '", want "' + $b + '")') }
function Read-Src([string]$rel) { return [IO.File]::ReadAllText((Join-Path $repo $rel)) }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix223-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force -Path $tmp | Out-Null
. (Join-Path $tk 'WireItAcl.ps1'); . (Join-Path $tk 'FixSiteIpc.ps1'); . (Join-Path $tk 'FixSiteCore.ps1'); . (Join-Path $tk 'FixSiteDevices.ps1')
$script:LogLines = New-Object System.Collections.ArrayList
function Fs-LogLine([string]$s) { [void]$script:LogLines.Add($s) }
# fake device: $script:Fake = @{ 'GET 1.2.3.4/path' = 'body' or @{code=..;body=..} }; every call is recorded in $script:Calls
$script:Fake = @{}; $script:Calls = New-Object System.Collections.ArrayList
$script:RealFsHttp = ${function:Fs-Http}
function Use-Fake { Set-Item -Path function:global:Fs-Http -Value {
  param([string]$Ip, [string]$Path, [string]$Method = 'GET', [string]$Body = '', [string]$ContentType = 'application/xml', $Cred = $null, [int]$Timeout = 8, [string]$OutFile = '', [switch]$Secret, [switch]$Tls)
  $k = $Method + ' ' + $Ip + $Path; [void]$script:Calls.Add([pscustomobject]@{ key = $k; body = $Body; tls = [bool]$Tls; cred = $Cred })
  $v = $null; foreach ($p in $script:Fake.Keys) { if ($k -like $p) { $v = $script:Fake[$p]; break } }
  if ($v -is [scriptblock]) { $v = & $v $k $Body }
  if ($null -eq $v) { return [pscustomobject]@{ code = 404; body = '' } }
  if ($v -is [string]) { $v = @{ code = 200; body = $v } }
  if ($OutFile -and $v.code -eq 200) { [IO.File]::WriteAllText($OutFile, [string]$v.body); return [pscustomobject]@{ code = 200; body = '' } }
  return [pscustomobject]@{ code = [int]$v.code; body = [string]$v.body; err = [string]$v.err }
} }
Use-Fake
try {
Write-Host '#10 Get-FsNet picks the interface carrying the address being contacted'
$script:Fake = @{
  'GET 192.168.1.20/ISAPI/System/Network/interfaces' = '<NetworkInterfaceList><NetworkInterface><id>1</id><IPAddress><ipAddress>10.10.0.1</ipAddress><subnetMask>255.255.255.0</subnetMask></IPAddress></NetworkInterface><NetworkInterface><id>2</id><IPAddress><ipAddress>192.168.1.20</ipAddress><subnetMask>255.255.255.0</subnetMask></IPAddress></NetworkInterface></NetworkInterfaceList>'
  'GET 192.168.1.20/ISAPI/System/Network/interfaces/1/ipAddress' = '<IPAddress><addressingType>static</addressingType><ipAddress>10.10.0.1</ipAddress><subnetMask>255.255.255.0</subnetMask></IPAddress>'
  'GET 192.168.1.20/ISAPI/System/Network/interfaces/2/ipAddress' = '<IPAddress><addressingType>static</addressingType><ipAddress>192.168.1.20</ipAddress><subnetMask>255.255.255.0</subnetMask></IPAddress>'
}
$n = Get-FsNet '192.168.1.20' 'Hikvision' $null
Eq $n.iface '2' 'reproduction: dual-interface NVR -> the LAN interface (2), not the PoE camera interface (1)'
Eq $n.ip '192.168.1.20' '...and its address'
$script:Fake['GET 192.168.1.30/ISAPI/System/Network/interfaces'] = '<NetworkInterfaceList><NetworkInterface><id>1</id><IPAddress><ipAddress>192.168.1.30</ipAddress></IPAddress></NetworkInterface></NetworkInterfaceList>'
$script:Fake['GET 192.168.1.30/ISAPI/System/Network/interfaces/1/ipAddress'] = '<IPAddress><ipAddress>192.168.1.30</ipAddress></IPAddress>'
Eq (Get-FsNet '192.168.1.30' 'Hikvision' $null).iface '1' 'single interface still works'
$script:Fake['GET 192.168.1.31/ISAPI/System/Network/interfaces'] = '<NetworkInterfaceList><NetworkInterface><id>1</id><IPAddress><ipAddress>10.1.1.1</ipAddress></IPAddress></NetworkInterface><NetworkInterface><id>2</id><IPAddress><ipAddress>10.2.2.2</ipAddress></IPAddress></NetworkInterface></NetworkInterfaceList>'
Check ($null -eq (Get-FsNet '192.168.1.31' 'Hikvision' $null)) 'several interfaces and none carries the contacted address -> no answer (nothing is changed), not a guess'
Write-Host '#11 OEM / other-brand recorders are recorders, not cameras'
. (Join-Path $tk 'ToolkitCore.ps1')
foreach ($m in @('ERI-K108-P8', 'HWN-4108MH-8P', 'DHI-NVR4108HS-8P-4KS2', 'NVR4216-16P-4KS2', 'XVR5108HS', 'NVR301-08S', 'DS-7608NI-K2/8P', 'iDS-7204HUHI-M1/S', 'DS-9632NI-I8')) { Eq (Get-TkDeviceKind $m) 'recorder' ('reproduction: ' + $m + ' is a recorder') }
foreach ($m in @('DS-2CD2143G2-I', 'IPC2124LB-SF28KM-G', 'ECI-T44F2', 'IPC-HFW2431S-S-S2', 'DS-2DE4425IW-DE')) { Eq (Get-TkDeviceKind $m) 'camera' ($m + ' stays a camera') }
Write-Host '#12 a recorder move checks the target address live first'
$script:FsNetOps = @{ free = { param($a) return ($a.ip -ne '192.168.1.20') } }
Eq (Get-FsNvrMoveTarget '192.168.1.20' '192.168.1' @(20, 19, 18) @()) '192.168.1.19' 'reproduction: .20 answers (an undiscovered printer) -> the NVR goes to .19, not onto the printer'
$script:FsNetOps = @{ free = { param($a) return $false } }
Eq (Get-FsNvrMoveTarget '192.168.1.20' '192.168.1' @(20, 19, 18) @()) '' 'every NVR address answers -> not moved'
$script:FsNetOps = @{ free = { param($a) return $true } }
Eq (Get-FsNvrMoveTarget '192.168.1.20' '192.168.1' @(20, 19, 18) @('192.168.1.20')) '192.168.1.19' 'an address given to another device in this run is skipped'
$script:FsNetOps = $null
$fs = Read-Src 'Toolkit/FixSite.ps1'
Check ($fs -match 'Get-FsNvrMoveTarget') 'FixSite NVR move uses the live target check'
Write-Host '#18 "backup saved" needs a backup that can bring the device back'
$script:Fake = @{ 'GET 10.0.0.5/ISAPI/System/time' = '<Time/>' }
$bf = @(Save-FsBackup '10.0.0.5' 'Hikvision' $null (Join-Path $tmp 'bk1'))
Eq $bf.Count 1 'the device gave only time.xml'
Check (-not (Test-FsBackupComplete $bf 'Hikvision')) 'reproduction: only time.xml -> NOT a backup (2.2.2 passed it)'
$script:Fake = @{ 'GET 10.0.0.6/ISAPI/System/configurationData' = 'BIN'; 'GET 10.0.0.6/ISAPI/System/Network/interfaces' = '<x/>'; 'GET 10.0.0.6/ISAPI/Streaming/channels/101' = '<s/>' }
$bf = @(Save-FsBackup '10.0.0.6' 'Hikvision' $null (Join-Path $tmp 'bk2'))
Check (Test-FsBackupComplete $bf 'Hikvision') 'config export + network + main stream = a backup'
Check (-not (Test-FsBackupComplete @($bf | Where-Object { $_ -notlike '*stream-101*' }) 'Hikvision')) 'a camera without its stream settings is not'
Check (Test-FsBackupComplete @($bf | Where-Object { $_ -notlike '*stream-101*' }) 'Hikvision' -Nvr) 'an NVR needs config + network'
Check ($fs -match 'Test-FsBackupComplete \$bf \$c\.brand' -and $fs -match 'Test-FsBackupComplete \$nbf') 'FixSite: camera AND NVR changes need a complete backup'
Write-Host '#17 a failed NVR move is a problem in the checklist and the exit code'
$fs = Read-Src 'Toolkit/FixSite.ps1'
$mv = $fs.Substring($fs.IndexOf("foreach (`$n in @(`$plan.nvrs | Where-Object { `$_.steps -contains 'move' })) {`n  # 2.2.3"))
$mv = $mv.Substring(0, $mv.IndexOf('# 2.0.3: NVR password'))
Check ($mv -match '\$badCount\+\+' -and $mv -match '\$results \+= \$l' -and $mv -match "nvrFail 'not moved \(no NVR login\)'") 'reproduction: NVR move failures (no login, refused, not back) add a red checklist line and count as a problem'
Write-Host '#13 no camera password change when its NVR cannot be updated; no direct-picture pass for an NVR camera'
$fs = Read-Src 'Toolkit/FixSite.ps1'
Check ($fs -match "if \(\`$c\.nvr -and -not \`$nvrCred\.ContainsKey\(\`$c\.nvr\)\) \{ & \`$step \('password not changed: NVR") 'reproduction: camera on an NVR with unknown login -> password not changed (2.2.2 changed it first)'
Check ($fs -match "video not checked on NVR") '...and its video is not "verified" from the camera picture alone'
Write-Host '#14 several recorders: channel lookups stay on the right NVR, every association is kept'
$obs = [pscustomobject]@{ devices = @([pscustomobject]@{ ip = '192.168.1.50'; mac = 'aa:bb:cc:00:00:50'; kind = 'camera'; brand = 'Hikvision'; model = 'DS-2CD' }); nvrs = @(
  [pscustomobject]@{ ip = '192.168.1.20'; channels = @([pscustomobject]@{ channel = 3; ip = '192.168.1.77' }, [pscustomobject]@{ channel = 5; ip = '192.168.1.50' }) },
  [pscustomobject]@{ ip = '192.168.1.19'; channels = @([pscustomobject]@{ channel = 3; ip = '192.168.1.99' }, [pscustomobject]@{ channel = 2; ip = '192.168.1.50' }) }) }
$hit = Get-FsChannelFor $obs '' 3 '192.168.1.19'
Eq $hit.nvr '192.168.1.19' 'reproduction: ch 3 asked for NVR .19 -> NVR .19 (2.2.2 returned .20)'
Check ($null -eq (Get-FsChannelFor $obs '' 3 '')) 'two NVRs and no NVR named -> a channel number alone matches nothing'
Eq (Get-FsChannelFor $obs '192.168.1.50' 0 '192.168.1.19').ch.channel 2 'an address match prefers the named NVR'
$d = @(ConvertTo-FsObserved $obs)[0]
Eq @($d.links).Count 2 'reproduction: the camera on both NVRs keeps both associations'
Eq $d.nvr '192.168.1.20' '...the first stays its main NVR (not overwritten by the second)'
Eq $d.channel 5 '...with its channel'
Check ((Read-Src 'Toolkit/FixSite.ps1') -match 'NVRs record this camera') 'FixSite: no password change on a camera that several NVRs record'
Write-Host '#15 an offline channel of another camera is not free'
$chs = @([pscustomobject]@{ channel = 1; ip = '192.168.1.21'; online = $true }, [pscustomobject]@{ channel = 2; ip = '192.168.1.22'; online = $false }, [pscustomobject]@{ channel = 3; ip = '192.168.1.23'; online = $null })
Eq (Get-FsFreeNvrChannel $chs '192.168.1.40' '192.168.1.60') 0 'reproduction: offline ch 2 / unknown ch 3 belong to other cameras -> no channel taken (2.2.2 took ch 2)'
Eq (Get-FsFreeNvrChannel ($chs + @([pscustomobject]@{ channel = 4; ip = '0.0.0.0'; online = $false })) '192.168.1.40') 4 'an empty channel is free'
Eq (Get-FsFreeNvrChannel $chs '192.168.1.40' '192.168.1.22') 2 'the camera''s own old channel (by its old address) is found'
Check ((Read-Src 'Toolkit/FixSite.ps1') -match 'Get-FsFreeNvrChannel \$chs \$ip \(\[string\]\$rbc\.ip_before\)') 'FixSite passes the real old address (rollback ip_before), not the nonexistent $c.ip_before'
Write-Host '#16 video check: the channel must point at the camera being verified'
$script:Fake = @{
  'GET 192.168.1.20/ISAPI/ContentMgmt/InputProxy/channels' = '<InputProxyChannelList><InputProxyChannel><id>5</id><sourceInputPortDescriptor><ipAddress>192.168.1.99</ipAddress></sourceInputPortDescriptor></InputProxyChannel></InputProxyChannelList>'
  'GET 192.168.1.20/ISAPI/ContentMgmt/InputProxy/channels/status' = '<InputProxyChannelStatusList><InputProxyChannelStatus><id>5</id><online>true</online></InputProxyChannelStatus></InputProxyChannelStatusList>'
  'GET 192.168.1.20/ISAPI/Streaming/channels/501/picture' = @{ code = 200; body = 'JPEGDATA' }
}
function Test-FsPicture { return $true }
Check (-not (Test-FsVideo '192.168.1.20' $null 5 '192.168.1.50' 'Hikvision' $null)) 'reproduction: ch 5 online with a picture but pointing at .99 -> camera .50 NOT verified'
Check (Test-FsVideo '192.168.1.20' $null 5 '192.168.1.99' 'Hikvision' $null) 'the camera the channel points at is verified'
Remove-Item function:Test-FsPicture
Write-Host '#19 a password write whose answer was lost is still bookkept'
$script:DevPw = @{ '10.0.0.7' = 'NewSite1' }
$script:Fake = @{ 'GET *ISAPI/System/deviceInfo' = { param($k, $b) $ip0 = ($k -split ' ')[1] -replace '/.*$', ''; $c0 = @($script:Calls)[-1].cred; if ($script:DevPw[$ip0] -eq 'GONE') { return @{ code = 0; body = ''; err = 'timeout' } }; if ($c0 -and (Fs-Plain $c0) -ceq $script:DevPw[$ip0]) { return '<DeviceInfo/>' }; return @{ code = 401; body = '' } } }
Eq (Resolve-FsPwChange '10.0.0.7' 'Hikvision' 'NewSite1' 'Old1') 'changed' 'the new password logs in -> changed (whatever the write answered)'
$script:DevPw['10.0.0.7'] = 'Old1'
Eq (Resolve-FsPwChange '10.0.0.7' 'Hikvision' 'NewSite1' 'Old1') 'unchanged' 'the old one logs in -> unchanged'
$script:DevPw['10.0.0.7'] = 'GONE'
Eq (Resolve-FsPwChange '10.0.0.7' 'Hikvision' 'NewSite1' 'Old1') 'unknown' 'reproduction: neither answers -> unknown (2.2.2 said "old one still works")'
$fs = Read-Src 'Toolkit/FixSite.ps1'
Check ($fs -match "password_unconfirmed = \`$true" -and $fs -match 'np\.unconfirmed = \$true') 'FixSite: unknown = rollback flag set (Undo tries both), camera and NVR alike'
Check ($fs -match 'password_attempted = \$true; Save-Rb\s+\[void\]\(Set-FsPassword') 'the attempt is in the undo file BEFORE the write'
Write-Host '#20 Undo marks a change done only once it is verified'
$fs = Read-Src 'Toolkit/FixSite.ps1'
Check ($fs -match "settings could not be read - not put back") 'reproduction: unreadable stream -> not marked done (2.2.2 found "no differences" and marked it)'
Check ($fs -match 'reads them back as they were' -and $fs -match '\$okS = \[bool\]\(\$rd -and') 'settings are read back before "done"'
Check ($fs -match "\[void\]\(Set-FsPassword \`$ip \`$c\.brand \`$cr \`$oldPw\); \(Test-FsLogin \`$ip \`$c\.brand \`$oldPw\) -eq 'ok'") 'camera password back = the old password logs in'
Check ($fs -match "\`$ok = \(\(Test-FsLogin \`$nip 'Hikvision' \`$oldN\) -eq 'ok'\)") 'NVR password back = the old password logs in'
Check ($fs -match "Restart-FsDevice \(\[string\]\`$n\.target\)" -and $fs -match "if \(\`$backN\) \{ & \`$markDone \('nvrmove") 'NVR move-back: restart when asked, done only when it answers on its old address'
Write-Host '#8 discovery and repairs stay on the network the tech picked'
$pcA = [pscustomobject]@{ ip = '192.168.1.105'; prefix = 24 }; $pcB = [pscustomobject]@{ ip = '10.0.5.20'; prefix = 24 }
$f = @([pscustomobject]@{ ip = '192.168.1.50' }, [pscustomobject]@{ ip = '10.0.5.77' }, [pscustomobject]@{ ip = '192.168.0.64' })
$k = @(Select-FsFoundOnNet $f $pcA @($pcA, $pcB) | ForEach-Object { $_.ip })
Check ($k -notcontains '10.0.5.77') 'reproduction: a camera on the PC''s other (Wi-Fi) network is not planned for relocation'
Check ($k -contains '192.168.1.50' -and $k -contains '192.168.0.64') 'cameras on the picked network and wrong-scheme cameras on the same wire stay'
$fc = Read-Src 'CamReset/Find-Cameras.ps1'; $fs = Read-Src 'Toolkit/FixSite.ps1'
Check ($fc -match '\[string\[\]\]\$LocalIp' -and $fs -match '-LocalIp \(\[string\]\$pc\.ip\)') 'Find cameras scans only the picked network (-LocalIp)'
Write-Host '#9 a failed discovery never reuses an older scan'
$lj = Join-Path $tmp 'latest.json'; Set-Content -Path $lj -Value '{}'; (Get-Item $lj).LastWriteTime = (Get-Date).AddDays(-2)
Check (-not (Test-FsFreshScan $lj 0 (Get-Date))) 'reproduction: latest.json from an earlier run (another site) is not used'
Set-Content -Path $lj -Value '{}'
Check (-not (Test-FsFreshScan $lj 1 (Get-Date).AddMinutes(-1))) 'the finder failed (exit 1) -> not used'
Check (Test-FsFreshScan $lj 0 (Get-Date).AddMinutes(-1)) 'written by this run, exit 0 -> used'
Check (-not (Test-FsFreshScan (Join-Path $tmp 'none.json') 0 (Get-Date))) 'no file -> not used'
Check ($fs -match "Move-Item -LiteralPath \`$lj -Destination \(\`$lj \+ '\.prev'\)" -and $fs -match 'if \(\$scanOk\) \{ Get-TkScanDevices') 'FixSite moves the old scan aside and uses the finder only when this run''s scan is good'
Write-Host '#35 an APIPA-only isolated switch is still scanned'
Check ($fc -match "elseif \(-not \`$locals\) \{ \`$locals = @\(\`$allLocals \| Where-Object \{ \`$_\.IPAddress -like '169\.254\.\*' \}\)") 'reproduction: only a 169.254 address -> the finder looks from it (2.2.2 exited "no network")'
#@@BLOCKS@@
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
Write-Host ''; Write-Host ('Test-Fix223: ' + $script:pass + ' passed, ' + $script:fail + ' failed') -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $script:fail
