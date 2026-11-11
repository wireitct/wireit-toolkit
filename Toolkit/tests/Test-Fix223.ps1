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
. (Join-Path $tk 'FixSiteCore.ps1'); . (Join-Path $tk 'FixSiteDevices.ps1')
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
$script:Fake['GET 192.168.1.30/ISAPI/System/Network/interfaces/1/ipAddress'] = '<IPAddress><addressingType>static</addressingType><ipAddress>192.168.1.30</ipAddress><subnetMask>255.255.255.0</subnetMask></IPAddress>'   # 2.2.12 (Codex 2.2.11 #2): a complete answer (a half answer is now rejected)
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
$script:Fake = @{ 'GET 10.0.0.6/ISAPI/System/configurationData' = ('BIN' * 700); 'GET 10.0.0.6/ISAPI/System/Network/interfaces' = '<x/>'; 'GET 10.0.0.6/ISAPI/Streaming/channels/101' = '<s/>' }
$bf = @(Save-FsBackup '10.0.0.6' 'Hikvision' $null (Join-Path $tmp 'bk2'))
Check (Test-FsBackupComplete $bf 'Hikvision') 'config export + network + main stream = a backup'
Check (-not (Test-FsBackupComplete @($bf | Where-Object { $_ -notlike '*stream-101*' }) 'Hikvision')) 'a camera without its stream settings is not'
Check (Test-FsBackupComplete @($bf | Where-Object { $_ -notlike '*stream-101*' }) 'Hikvision' -Nvr) 'an NVR needs config + network'
# 2.2.4: replaced by a run of the real code in Test-Fix224.ps1 section 2/FixSite e2e
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
# 2.2.14: the words moved to FixSiteCore's Get-FsMoveBlock / Get-FsPwChangeBlock (Codex 2.2.13 F1); checked in code, not in a comment
$fs223 = ((Read-Src 'Toolkit/FixSite.ps1') -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
Check (($fs223 -match 'Get-FsMoveBlock' -and (Read-Src 'Toolkit/FixSiteCore.ps1') -match "' NVRs record this camera") -or $fs223 -match 'NVRs record this camera') 'FixSite: no password change on a camera that several NVRs record'
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
Write-Host '#38 the saved site list says where devices ARE, not where they were planned to go'
$plan38 = [pscustomobject]@{ scheme = '192.168.1'; nvrs = @([ordered]@{ ip = '10.0.0.20'; target = '192.168.1.20'; brand = 'Hikvision'; model = 'DS-7608'; mac = 'aa:00:00:00:00:20'; moved = $false })
  cams = @([pscustomobject]@{ name = 'Gate'; brand = 'Hikvision'; model = 'm'; serial = 's'; mac = 'aa:00:00:00:00:55'; ip = '192.168.1.55'; target = '192.168.1.21'; state = 'fix'; channel = 1; nvr = '192.168.1.20'; switch = ''; port = $null; listIp = '' },
           [pscustomobject]@{ name = 'Door'; brand = 'Hikvision'; model = 'm'; serial = 's'; mac = 'aa:00:00:00:00:56'; ip = '10.0.0.56'; target = '192.168.1.22'; state = 'fix'; channel = 2; nvr = '192.168.1.20'; switch = ''; port = $null; listIp = ''; ipNow = '192.168.1.22' }) }
$nl = New-FsSiteList 'X' '' $plan38 $null
Eq $nl.cameras[0].ip '192.168.1.55' 'reproduction: a camera whose move failed is saved at .55 where it is (2.2.2 saved .21)'
Eq $nl.cameras[1].ip '192.168.1.22' 'a verified move is saved at its new address'
Eq $nl.nvrs[0].ip '10.0.0.20' 'an NVR that did not move is saved where it is'
$old = @([pscustomobject]@{ name = 'Door'; mac = 'AA-00-00-00-00-56'; ip = '10.0.0.56'; channel = 2; nvr = '192.168.1.20'; port = 7 }, [pscustomobject]@{ name = 'Yard'; mac = 'aa:00:00:00:00:77'; ip = '192.168.1.30' })
$m = @(Merge-FsSiteListCams $old @($nl.cameras))
$door = @($m | Where-Object { (ConvertTo-FsMac ([string](Get-FsProp $_ 'mac' ''))) -eq 'aa:00:00:00:00:56' })
Eq $door.Count 1 'one entry per camera after the merge'
Eq (Get-FsProp $door[0] 'ip' '') '192.168.1.22' 'reproduction: an existing entry gets the camera''s new address (2.2.2 kept the old one)'
Eq (Get-FsProp $door[0] 'port' '') 7 '...and keeps what only the saved list knew (its switch port)'
Check (@($m | Where-Object { (Get-FsProp $_ 'name' '') -eq 'Yard' }).Count -eq 1 -and @($m | Where-Object { (Get-FsProp $_ 'name' '') -eq 'Gate' }).Count -eq 1) 'cameras not seen keep their entry; new ones are added'
Write-Host '#42 manual work is part of the overall result'
$p42 = [pscustomobject]@{ nvrs = @([ordered]@{ ip = '10.0.0.20'; steps = @('manual'); why = @('moving a Dahua NVR is not built yet') }); cams = @([pscustomobject]@{ name = 'Pole'; state = 'manual'; why = @('Uniview: by hand') }, [pscustomobject]@{ name = 'Ok'; state = 'ok'; why = @() }) }
$ml = @(Get-FsManualLines $p42)
Eq $ml.Count 2 'reproduction: a manual NVR step and a manual camera are both listed (2.2.2 left them out of the result)'
Check (($ml -join ' ') -like ('*' + $script:FsBad + '*')) '...as red lines'
$fs = Read-Src 'Toolkit/FixSite.ps1'
Check ($fs -match 'foreach \(\$l in @\(Get-FsManualLines \$plan\)\) \{ \$results \+= \$l; \$badCount\+\+ \}' -and $fs -match '@\(Get-FsManualLines \$plan\)\.Count\) \{ 4 \}') 'FixSite counts them in "Still a problem" and the exit code, also when nothing else had to be done'
Write-Host '#24 distinct site names never share a password store or list file'
Check ((Get-FsSecretPath $tmp 'A/B') -ne (Get-FsSecretPath $tmp 'A.B')) 'reproduction: "A/B" and "A.B" get different password stores (2.2.2: both site-A_B.dat)'
Check ((Get-FsListFileName 'A/B') -ne (Get-FsListFileName 'A.B')) '...and different list files'
$l24 = Join-Path $tmp 'lists24'; New-Item -ItemType Directory -Force -Path $l24 | Out-Null; ([ordered]@{ site = '12 Elm St' } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $l24 '12_Elm_St.json')
Eq (Split-Path -Leaf (Resolve-FsLocalList $l24 '12 Elm St')) '12_Elm_St.json' 'a 2.2.2 list file of a plain name is still found (2.2.4: new files get a fingerprint)'
Eq (Get-FsListFileName '12 Elm St.') (Get-FsListFileName '12 elm st.') 'the same site typed in another case is the same site'
$script:FsTestSecrets = $true
$sd = Join-Path $tmp 'sec24'; $sA = Read-FsSecrets $sd 'A/B'; $sA.password = 'PwOfAB1'; Save-FsSecrets $sd $sA
Check (-not (Read-FsSecrets $sd 'A.B').password) 'A.B does not read A/B''s password'
Eq (Read-FsSecrets $sd 'A/B').password 'PwOfAB1' 'A/B reads its own'
# a 2.2.2 store under the old shared name: used only by the site it names
$sL = Read-FsSecrets $sd 'Old Site'; $sL.site = 'C.D'; $sL.password = 'PwOfCD1'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
[IO.File]::WriteAllText((Get-FsSecretPath $sd 'C.D' -Legacy), (Protect-FsText ([ordered]@{ site = 'C.D'; password = 'PwOfCD1' } | ConvertTo-Json -Compress)))
Check (-not (Read-FsSecrets $sd 'C/D').password) 'reproduction: the old-name store of C.D is not used for C/D (stored site identity checked)'
Eq (Read-FsSecrets $sd 'C.D').password 'PwOfCD1' 'C.D still finds its 2.2.2 store'
$script:FsTestSecrets = $false
Write-Host '#6 the old SADP import forms (new password in plain multicast) are off by default'
. (Join-Path $tk 'HikSadp.ps1')
$script:SadpSent = @(); function Invoke-SadpExchange { param($probes) $script:SadpSent += @($probes); return @() }
function Import-HikUnlockReset { return [pscustomobject]@{ ok = $false; result = ''; form = ''; tries = 1; error = 'no answer' } }
$dev6 = [pscustomobject]@{ mac = 'aa:bb:cc:dd:ee:ff'; serial = 'DS123' }
$r6 = Import-HikUnlock $dev6 ([pscustomobject]@{ code = 'ABCD1234' }) 'NewSitePw9' 0.1
Check (-not $r6.ok -and -not @($script:SadpSent | Where-Object { [string]$_ -match 'NewSitePw9' }).Count) 'reproduction: no plain-password probe is multicast when the encrypted reset gets no answer (2.2.2 fell back to the old forms)'
$r6 = Import-HikUnlock $dev6 ([pscustomobject]@{ code = 'LONGERCODE123456' }) 'NewSitePw9' 0.1
Check (-not $r6.ok -and $r6.error -match 'unencrypted' -and -not $script:SadpSent.Count) 'a code only the old forms take: not sent, plain words why'
$script:SadpAllowPlainPassword = $true
$r6 = Import-HikUnlock $dev6 ([pscustomobject]@{ code = 'LONGERCODE123456' }) 'NewSitePw9' 0.1
Check ($script:SadpSent.Count -gt 0) 'config opt-in (hikReset.sadpLegacyPlainPassword = true) still allows them'
$script:SadpAllowPlainPassword = $false
Check ((Read-Src 'Toolkit/HikResetFlow.ps1') -match 'sadpLegacyPlainPassword') 'the opt-in is read from config'
Write-Host '#7 no password to a Basic-only challenge over plain HTTP; device certificates pinned'
Check (-not (Test-FsDigestOffered @('Basic realm="x"'))) 'reproduction: a Basic-only challenge over HTTP is refused (2.2.2 answered it with the password)'
Check (Test-FsDigestOffered @('Basic realm="x"', 'Digest realm="x", nonce="1", qop="auth"')) 'Digest offered -> the login goes ahead (password never on the wire)'
$src7 = Read-Src 'Toolkit/FixSiteDevices.ps1'
# 2.2.4: replaced by a run of the real code in Test-Fix224.ps1 section 7
Check ($src7 -match 'Pins\.TryGetValue\(host, out seen\)\) return seen == tp') 'Windows PowerShell 5.1: a device''s certificate is pinned for the run; a different one on the same address is refused'
$cs = $script:WireItLanTlsCode
try { if (-not ('WireItLanTls' -as [type])) { Add-Type -TypeDefinition $cs -IgnoreWarnings -WarningAction SilentlyContinue -ErrorAction Stop }; Check ([bool]('WireItLanTls' -as [type])) 'the pinning helper compiles' } catch { Check $false ('the pinning helper compiles: ' + $_.Exception.Message) }
Write-Host '#29 one wrong-password budget per device for the whole run'
$script:FsLoginFails = @{}
$script:Fake = @{ 'GET 10.0.0.29/ISAPI/System/deviceInfo' = @{ code = 401; body = '' } }
$st = @(); for ($i = 0; $i -lt 7; $i++) { $st += (Test-FsLogin '10.0.0.29' 'Hikvision' ('Wrong' + $i)) }
$sent = @($script:Calls | Where-Object { $_.key -eq 'GET 10.0.0.29/ISAPI/System/deviceInfo' }).Count
Eq $sent 4 'reproduction: 7 password checks across steps -> only 4 reach the device (2.2.2 sent all 7: a lockout)'
Eq $st[-1] 'locked' 'after the budget the device counts as locked for this run'
Check ((Read-Src 'Toolkit/HikResetFlow.ps1') -match '\$logins -lt \$script:HkVerifyMaxLogins' -and $script:HkVerifyMaxLogins -le 2) 'Hikvision import check: at most 2 logins (was 6)'
. (Join-Path $tk 'HikResetFlow.ps1') 2>$null
Eq $script:HkVerifyMaxLogins 2 'HikResetFlow sets the 2-login limit'
Write-Host '#37 passwords are compared case-sensitively'
$cands = @(Get-FsPasswordCandidates ([pscustomobject]@{ password = 'SitePass9'; known = @('sitepass9') }) 3)
Eq $cands.Count 2 'reproduction: SitePass9 and sitepass9 are two candidates (2.2.2 merged them)'
$fs = Read-Src 'Toolkit/FixSite.ps1'
Check ($fs -match '\$pw -cne \$sitePw -and \(\$c\.steps -contains ''password''') 'a case-only password rotation is not skipped (-cne)'
Check (-not ([regex]::Matches($fs, '\$pw -ne \$sitePw')).Count) 'no case-insensitive password comparison left in FixSite'
Write-Host '#27 the Fix NVR button reaches its own function again'
$wt = Read-Src 'Toolkit/WireItToolkit.ps1'
$tok = $null; $errs = $null; $ast = [Management.Automation.Language.Parser]::ParseInput($wt, [ref]$tok, [ref]$errs)
$defs = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
$dups = @($defs | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
Eq @($defs | Where-Object { $_ -eq 'Do-Fix' }).Count 1 'reproduction: exactly one Do-Fix (2.2.2 had two; the second swallowed the button)'
Eq ($dups -join ',') '' 'no function is defined twice in WireItToolkit.ps1'
$fx = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Do-Fix' }, $true))[0]
Check (-not $fx.Parameters -and -not $fx.Body.ParamBlock) 'the remaining Do-Fix is the button''s (no key parameter)'
Check ($wt -match 'Do-FixFailed \(\[string\]\$f\.Tag\)') '"Fix what failed" calls its own Do-FixFailed'
Write-Host '#25 Bitwarden lists are real lists on Windows PowerShell 5.1'
. (Join-Path $tk 'FixSiteBw.ps1')
$js = '[{"id":"o1","name":"Personal stuff"},{"id":"o2","name":"WireIt CT"}]'
$ps51 = { param($t) Write-Output -NoEnumerate @(ConvertFrom-Json -InputObject $t) }   # what 5.1's ConvertFrom-Json does with an array
Eq @(& $ps51 $js).Count 1 'the 5.1 behaviour reproduced: @(json-array | ConvertFrom-Json) is ONE item'
$script:FsJsonParse = $ps51
$orgs = @(ConvertFrom-FsJsonArray $js)
Eq $orgs.Count 2 'reproduction: two organizations are two (2.2.2 saw one and missed "WireIt CT" -> personal vault)'
Eq @($orgs | Where-Object { $_.name -eq 'WireIt CT' }).Count 1 '...and the WireIt CT org is found by name'
$script:FsJsonParse = { param($t) ConvertFrom-Json -InputObject $t }
Eq @(ConvertFrom-FsJsonArray $js).Count 2 'same on PowerShell 7'
$bwsrc = Read-Src 'Toolkit/FixSiteBw.ps1'
Check (-not ([regex]::Matches($bwsrc, '@\(\(?[^)]*\.out\)? \| ConvertFrom-Json\)')).Count -and ([regex]::Matches($bwsrc, 'ConvertFrom-FsJsonArray')).Count -ge 4) 'every list read uses it (organizations, collections, items)'
Write-Host '#21 a firmware-update config backup is the device''s bytes, unchanged'
$wd = Join-Path $tmp 'web21'; New-Item -ItemType Directory -Force -Path $wd | Out-Null
$bin = [byte[]](0..255 + 255..0 + @(0xC3, 0x28, 0xFF, 0xFE, 0x00)); [IO.File]::WriteAllBytes((Join-Path $wd 'configurationData'), $bin)
$srv21 = Join-Path $tmp 'srv21.py'; [IO.File]::WriteAllText($srv21, "import http.server, functools, sys`nh = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1]); h.log_message = lambda *a: None`ns = http.server.HTTPServer(('127.0.0.1', 0), h); print(s.server_address[1], flush=True); s.serve_forever()`n")
. (Join-Path $PSScriptRoot 'TestPython.ps1'); $py21 = Get-TestPython   # 2.2.5: a real Python, never the Windows Store stub
$psi = New-Object Diagnostics.ProcessStartInfo; $psi.FileName = $py21; $psi.Arguments = '"' + $srv21 + '" "' + $wd + '"'; $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.CreateNoWindow = $true
$p21 = [Diagnostics.Process]::Start($psi); $port21 = [int]$p21.StandardOutput.ReadLine()
try {
  $nm = Import-Module (Join-Path $tk 'modules\NvrHealth\NvrHealth.psm1') -Force -PassThru -DisableNameChecking
  $of = Join-Path $tmp 'cfg.bin'
  $r21 = & $nm { param($p, $o) Http -Ip '127.0.0.1' -Port $p -Scheme 'http' -Path '/configurationData' -OutFile $o } $port21 $of
  Eq $r21.code 200 'export answered'
  $got = [IO.File]::ReadAllBytes($of)
  Check ($got.Length -eq $bin.Length -and -not @(0..($bin.Length - 1) | Where-Object { $got[$_] -ne $bin[$_] }).Count) 'reproduction: every byte survives (2.2.2 decoded it as UTF-8 text and saved .txt)'
  $r21b = & $nm { param($p) Http -Ip '127.0.0.1' -Port $p -Scheme 'http' -Path '/configurationData' } $port21
  Check ([Text.Encoding]::UTF8.GetBytes($r21b.body).Length -ne $bin.Length) '...the old text path really does change the bytes'
} finally { try { $p21.Kill() } catch {}; Remove-Module NvrHealth -ErrorAction SilentlyContinue }
# 2.2.4: the export-as-bytes check above (#21, a real HTTP download) covers this; the source check is gone
Write-Host '#47 standalone HikReset reads the site password where the installer keeps it (vault\)'
$hr = Read-Src 'Toolkit/HikReset.ps1'
Check ($hr -match "\`$secDir = Join-Path \`$here 'vault'") 'reproduction: default store is Toolkit\vault (2.2.2 read Toolkit\secrets)'
Check ($hr -match "FsLegacySecretsDir = Join-Path \`$here 'secrets'") '...and an old secrets\ store is still found'
Write-Host '#58 HikReset -Only limits the submission too'
$hr = Read-Src 'Toolkit/HikReset.ps1'
Check ($hr -match 'Submit-HikRequests \$state \$statePath \(Get-HikFormFor \$cfg\) 900 \$onlySerials') 'reproduction: -Only is passed to the submission (2.2.2 submitted every saved pending device)'
Write-Host '#48 the browser profile path with a space stays one argument'
. (Join-Path $tk 'HikPortal.ps1') 2>$null
$line = Join-HikArgs @('--remote-debugging-port=2222', '--user-data-dir=C:\Users\Jose Maria\AppData\Local\Temp\wireit-hik-1', '--no-first-run', 'https://example.com/a?b=c')
Check ($line -match '"--user-data-dir=C:\\Users\\Jose Maria\\AppData\\Local\\Temp\\wireit-hik-1"') 'reproduction: --user-data-dir with a space is quoted (2.2.2 split it)'
Check ($line -match '^--remote-debugging-port=2222 ') 'plain arguments stay as they are'
Eq (Join-HikArgs @('a"b')) '"a\"b"' 'an inner quote is escaped'
Eq (Join-HikArgs @('C:\x y\')) '"C:\x y\\"' 'a trailing backslash before the closing quote is doubled'
Check ((Read-Src 'Toolkit/HikPortal.ps1') -match '-ArgumentList \(Join-HikArgs \$args2\)') 'the browser is started with the quoted line'
Write-Host '#36 first visit: factory-password devices get the new site password'
$fs = Read-Src 'Toolkit/FixSite.ps1'
$iRead = $fs.IndexOf('$sitePwAtStart = [bool]$sec.password'); $iAsk = $fs.IndexOf('[void](Ask-SitePassword)')
Check ($iRead -gt 0 -and $iRead -lt $iAsk) 'the "had a site password" fact is taken right after the store is read, before one is asked or made'
Check ($fs -match '\$opts\.factoryToSite = \[bool\]\(\$NewSite -or -not \$sitePwAtStart -or \$sitePwPending\)') 'reproduction: factoryToSite uses it (2.2.2 tested after the new password existed -> always false)'
$o36 = Merge-FsOptions @{ factoryToSite = $true }
Check ([bool]$o36.factoryToSite) 'the option reaches the planner'
Write-Host '#40 a partial site name picks a Drive folder only when it is the only match'
$dr = Join-Path $tmp 'drive40'; foreach ($n in @('12 Main St (WI-123)', '112 Main St (WI-12)', 'Strand 177 Main')) { New-Item -ItemType Directory -Force -Path (Join-Path $dr $n) | Out-Null }
Check ($null -eq (Find-FsSiteFolder '12 Main' @($dr))) 'reproduction: "12 Main" matches two sites -> none (2.2.2 took the first)'
Check (@($script:FsSiteFolderAmbiguous).Count -eq 2) '...and the two are named for the tech'
Eq (Split-Path -Leaf (Find-FsSiteFolder 'WI-12' @($dr))) '112 Main St (WI-12)' 'a Site ID matches as a whole word (WI-12 is not WI-123)'
Eq (Split-Path -Leaf (Find-FsSiteFolder 'Strand' @($dr))) 'Strand 177 Main' 'one partial match is used'
Eq (Split-Path -Leaf (Find-FsSiteFolder '12 Main St (WI-123)' @($dr))) '12 Main St (WI-123)' 'the exact name always wins'
Write-Host '#41 NTP change: unreadable read-back is not success'
$nm41 = Import-Module (Join-Path $tk 'modules\NvrHealth\NvrHealth.psm1') -Force -PassThru -DisableNameChecking
$r41 = & $nm41 {
  function Onvif-Call { return @{ code = 200; body = '' } }
  function Onvif-Time { return $null }
  function Log { }
  Onvif-NtpApply @{ ip = '10.0.0.41' } 'time.nist.gov' @{ needNtp = $true; needMode = $false; needTz = $false; o = @{ mode = 'Manual'; dst = $true; tz = $null; ntp = @() } }
}
Check ($r41 -and -not $r41.ok -and $r41.why -match 'read back') 'reproduction: ONVIF NTP set, read-back unreadable -> NOT ok (2.2.2 said ok)'
$r41h = & $nm41 {
  function Http { return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } }
  function Hik-Time { return $null }
  function Hik-NtpPlan { return @{ ok = $false; why = 'x' } }
  function Log { }
  Hik-NtpApply @{ ip = '10.0.0.41' } 'time.nist.gov' @{ needNtp = $false; needMode = $false; needTz = $false; h = $null }
}
Check ($r41h -and -not $r41h.ok -and $r41h.why -match 'read back') 'reproduction: Hikvision NTP set, read-back unreadable -> NOT ok'
Remove-Module NvrHealth -ErrorAction SilentlyContinue
Write-Host '#22 the firmware check is never green for devices it could not judge'
$nm22 = Import-Module (Join-Path $tk 'modules\NvrHealth\NvrHealth.psm1') -Force -PassThru -DisableNameChecking
$r22 = & $nm22 { Get-FwResultLine 0 0 1 }
Check (-not $r22.ok -and $r22.text -notmatch 'firmware OK') 'reproduction: an unknown model -> not OK, not "RESULT: firmware OK" (2.2.2 said OK, ok=True)'
$r22 = & $nm22 { Get-FwResultLine 0 0 0 }; Check ($r22.ok -and $r22.text -match 'firmware OK') 'everything judged and current -> OK'
$r22 = & $nm22 { Get-FwResultLine 1 0 2 }; Check (-not $r22.ok -and $r22.text -match '2 not checked') 'holes + unjudged: both said'
$src22 = Read-Src 'Toolkit/modules/NvrHealth/NvrHealth.psm1'
Check (([regex]::Matches($src22, '\$fwUnread\+\+')).Count -ge 3 -and $src22 -match 'ok = \$res\.ok; not_judged = \$notJudged') 'unreadable recorder/cameras are counted; the result carries it'
Remove-Module NvrHealth -ErrorAction SilentlyContinue
Write-Host '#23 retention: every camera on its own footage'
$nm23 = Import-Module (Join-Path $tk 'modules\NvrHealth\NvrHealth.psm1') -Force -PassThru -DisableNameChecking
$ch23 = @([pscustomobject]@{ ch = 1; days_held = 45 }, [pscustomobject]@{ ch = 2; days_held = 1 }, [pscustomobject]@{ ch = 3; days_held = 44.5 })
$s23 = @(& $nm23 { param($c) Get-RetentionShort $c 45 45 } $ch23)
Check (@($s23 | ForEach-Object { $_.ch }) -contains 2) 'reproduction: 45 days on one camera, 1 day on another -> the 1-day camera is a problem (2.2.2: "target met")'
Check (@($s23 | ForEach-Object { $_.ch }) -contains 3) '...and 44.5 days is under 45 too'
$src23 = Read-Src 'Toolkit/modules/NvrHealth/NvrHealth.psm1'
Check ($src23 -match "problems\.Add\(\(''\s*\+\s*\`$short\.Count \+ ' camera\(s\) below the '") 'short cameras are counted in the RESULT (not green)'
Remove-Module NvrHealth -ErrorAction SilentlyContinue
Write-Host '#43 the router line says only what the UPnP check can see'
$tc = Read-Src 'Toolkit/ToolkitCore.ps1'
Check ($tc -notmatch 'nothing opened to the internet' -and $tc -notmatch 'off or blocked\) - good' -and $tc -notmatch 'off or blocked - good') 'reproduction: no "nothing opened to the internet" / "UPnP off or blocked - good" (2.2.2 overclaimed)'
Check (([regex]::Matches($tc, 'Port forwards made by hand (are|need)')).Count -ge 3) 'every no-UPnP line says port forwards made by hand are not checked'
Write-Host '#44 earlier results are compared only for the same site / network'
$nc = Read-Src 'Toolkit/NvrCheck.ps1'
Check ($nc -match "\`$Site -and \(\[string\]\`$scan\.site\)\.Trim\(\) -eq \`$Site\.Trim\(\)") 'reproduction: NVR site check uses the last upload only when it is this site''s (2.2.2: any site''s within 30 min)'
$scs = Read-Src 'sitecheck/SiteCheck.ps1'
$i44 = $scs.IndexOf('function Get-ScNetKeys'); $j44 = $scs.IndexOf('# Upload to the site page', $i44)   # the core functions live in a here-string (run in the scan runspace)
Invoke-Expression $scs.Substring($i44, $j44 - $i44)
$d44 = Join-Path $tmp 'sc44'; New-Item -ItemType Directory -Force -Path $d44 | Out-Null
[IO.File]::WriteAllText((Join-Path $d44 'last-scan.json'), (@{ when = '2026-11-07T10:00:00'; nets = @('10.0.5.0/24'); devices = @(@{ ip = '10.0.5.21' }) } | ConvertTo-Json -Depth 4))
$R44 = [ordered]@{ nets = @(@{ ip = '192.168.1.50'; prefix = 24 }); previous = $null }
Read-ScPrevious $R44 $d44
Check (-not $R44.previous) 'reproduction: last scan from another site''s network is not compared (2.2.2: devices reported missing)'
$R44 = [ordered]@{ nets = @(@{ ip = '10.0.5.77'; prefix = 24 }); previous = $null }
Read-ScPrevious $R44 $d44
Eq @($R44.previous).Count 1 'same network: compared'
$cmd = [IO.File]::ReadAllText((Join-Path $repo 'sitecheck\WireIt-SiteCheck.cmd')); $ci = $cmd.IndexOf('##PSSTART')
Check ($cmd.Substring($ci + 11).Trim() -eq $scs.Trim()) 'the Site check launcher .cmd carries the same SiteCheck.ps1'
Write-Host '#30 an NVR on the right subnet with broken network settings is fixed in place'
$pc30 = [pscustomobject]@{ ip = '192.168.1.105'; gw = '192.168.1.1'; mask = '255.255.255.0'; prefix = 24 }
$obs30 = [pscustomobject]@{ pc = $pc30; devices = @(); nvrs = @([pscustomobject]@{ ip = '192.168.1.20'; brand = 'Hikvision'; model = 'DS-7608NI'; mac = 'aa:00:00:00:00:20'; login = 'site password'; channels = @(); net = [pscustomobject]@{ dhcp = $false; gw = '192.168.0.1'; mask = '255.255.255.0'; dns1 = '' } }) }
$p30 = New-FsPlan $null $obs30
$n30 = @($p30.nvrs)[0]
Check (@($n30.steps) -contains 'move' -and $n30.target -eq '192.168.1.20') 'reproduction: old router .0.1 + no DNS on an NVR at .20 -> its settings are fixed in place (2.2.2: "no network work")'
Check (($n30.why -join ' ') -match 'router 192\.168\.0\.1' -and ($n30.why -join ' ') -match 'no DNS') '...and the plan says why'
$obs30.nvrs[0].net = [pscustomobject]@{ dhcp = $false; gw = '192.168.1.1'; mask = '255.255.255.0'; dns1 = '8.8.8.8' }
Check (-not @((@((New-FsPlan $null $obs30).nvrs)[0]).steps).Count) 'good settings -> nothing to do'
$fs = Read-Src 'Toolkit/FixSite.ps1'
Check ($fs -match '\$t = \$\(if \(\$n\.target -eq \$n\.ip\) \{ \$n\.ip \}' -and $fs -match 'ntN = Get-FsNet \$nip') 'FixSite reads the NVR''s settings and fixes them on the same address'
Check ($fs -match "Add-Member -NotePropertyName moved") 'the plan''s NVR (an object) records whether it moved'
Write-Host '#51 the laptop tells the relay when its request file was made'
Check ((Read-Src 'Toolkit/HikMail.ps1') -match '\$body\.exportedAt = \(\[datetime\]\$Device\.exportedAt\)\.ToUniversalTime\(\)') 'reproduction: hikReplyGet carries exportedAt (2.2.2 sent only the serial)'
Write-Host '#49 the portal counts as submitted only on real evidence'
. (Join-Path $tk 'HikPortal.ps1') 2>$null
$t0 = (Get-Date).AddSeconds(-10)
$base = 'Password Reset. We have received many requests; we will reply within 2 working days. Fill the form.'
Check (-not (Test-PortalAccepted ([pscustomobject]@{ url = 'https://www.hikvision.com/en/support/password-reset/'; formShown = $true; posts = @(); modal = $false; text = $base; base = $base }) $t0)) 'reproduction: generic page text that was already there is not a submission (2.2.2: "we have received" -> submitted)'
Check (-not (Test-PortalAccepted ([pscustomobject]@{ url = 'x'; formShown = $false; posts = @(); modal = $false; text = 'loading'; base = $base }) $t0)) 'a form that just disappears is not a submission'
Check (-not (Test-PortalAccepted ([pscustomobject]@{ url = 'x'; formShown = $false; posts = @([pscustomobject]@{ u = 'https://cdn.example.com/api/prefs'; s = 200 }); modal = $false; text = 'x'; base = $base }) $t0)) 'an unrelated 2xx POST is not a submission'
Check (Test-PortalAccepted ([pscustomobject]@{ url = 'x'; formShown = $true; posts = @(); modal = $false; text = $base + ' Thank you! Your request has been submitted.'; base = $base }) $t0) 'new thanks text after Submit -> submitted'
Check (Test-PortalAccepted ([pscustomobject]@{ url = 'x'; formShown = $false; posts = @([pscustomobject]@{ u = 'https://www.hikvision.com/api/enquiry/save'; s = 200 }); modal = $false; text = 'x'; base = $base }) $t0) 'the form''s own POST answered 2xx and the form went away -> submitted'
Check (-not (Test-PortalAccepted ([pscustomobject]@{ url = 'x'; formShown = $true; posts = @(); modal = $false; text = $base + ' Thank you'; base = $base }) $null)) 'nothing counts before Submit was clicked'
Check (@(Test-PortalFilled ([pscustomobject]@{ firstName = 'ok'; lastName = 'ok'; email = 'ok'; company = 'ok'; zipCode = 'ok'; serialNo = 'ok'; modelNumber = 'ok'; state = 'CT'; businessType = 'x'; file = 'no file box on the page' }) $null).Count -eq 1) 'a missing upload box is a fill problem'
Check (-not (Test-Path (Join-Path $tk 'HikPortalStep.ps1'))) 'the separate Crew portal helper is gone (2.2.3: the page runs inside the fix, which checks the fill)'
Write-Host '#28 unsupported brands are refused plainly'
$pc28 = [pscustomobject]@{ ip = '192.168.1.105'; gw = '192.168.1.1'; mask = '255.255.255.0'; prefix = 24 }
$obs28 = [pscustomobject]@{ pc = $pc28; nvrs = @([pscustomobject]@{ ip = '192.168.1.20'; brand = 'Uniview'; model = 'NVR302'; mac = 'aa:00:00:00:00:20'; login = 'not supported'; channels = @() })
  devices = @([pscustomobject]@{ ip = '10.1.1.64'; brand = 'Uniview'; model = 'IPC2124'; mac = 'aa:00:00:00:00:64'; kind = 'camera'; login = 'ok' }) }
$p28 = New-FsPlan $null $obs28
$n28 = @($p28.nvrs)[0]; $c28 = @($p28.cams)[0]
Check (@($n28.steps) -join ',' -eq 'manual' -and ($n28.why -join ' ') -match 'does not support Uniview recorders') 'reproduction: a Uniview NVR gets no Hikvision work, only a plain "not supported" (2.2.2 ran the Hikvision path)'
Check ($c28.state -eq 'manual' -and ($c28.why -join ' ') -match 'does not support Uniview cameras' -and -not (@($c28.steps) -contains 'move')) 'a Uniview camera on the wrong subnet is not moved through Hikvision ISAPI'
Check (@(Get-FsManualLines $p28).Count -eq 2) 'both count as manual work in the result (exit 4, never "all fixed")'
Check ((Test-FsBrandSupported 'Dahua' 'camera') -and -not (Test-FsBrandSupported 'Dahua' 'nvr') -and (Test-FsBrandSupported 'Hikvision' 'nvr') -and -not (Test-FsBrandSupported '' 'camera')) 'supported set: Hikvision everything, Dahua cameras'
Check ((Read-Src 'Toolkit/FixSite.ps1') -match "login = 'not supported'") 'FixSite tries no password on an unsupported NVR'
Write-Host '#56 a ZIP in the Hikvision drop folder is read with hard limits'
. (Join-Path $tk 'HikMail.ps1') 2>$null
Add-Type -AssemblyName System.IO.Compression; Add-Type -AssemblyName System.IO.Compression.FileSystem
function New-Zip56([string]$p, [hashtable]$files) { if (Test-Path $p) { Remove-Item $p }; $z = [IO.Compression.ZipFile]::Open($p, 'Create'); foreach ($k in $files.Keys) { $e = $z.CreateEntry($k); $s = $e.Open(); $b = [byte[]]$files[$k]; $s.Write($b, 0, $b.Length); $s.Dispose() }; $z.Dispose() }
$z1 = Join-Path $tmp 'bomb.zip'; New-Zip56 $z1 @{ 'big.xml' = (New-Object byte[] (3MB)) }
Check ((Get-Item $z1).Length -lt 100KB) '(the test archive is small on disk)'
Eq @(Read-HikZipEntries $z1).Count 0 'reproduction: an entry that expands past 2 MB is refused (2.2.2 expanded it all to disk and read it)'
$f25 = @{}; foreach ($i in 1..25) { $f25[('f' + $i + '.xml')] = [byte[]](1, 2, 3) }; $z2 = Join-Path $tmp 'many.zip'; New-Zip56 $z2 $f25
Eq @(Read-HikZipEntries $z2).Count 0 'more than 20 entries: refused'
$z3 = Join-Path $tmp 'ok.zip'; New-Zip56 $z3 @{ 'reset_K1.xml' = [Text.Encoding]::ASCII.GetBytes('<xml>unlock</xml>') }
$r56 = @(Read-HikZipEntries $z3); Check ($r56.Count -eq 1 -and [Text.Encoding]::ASCII.GetString($r56[0].bytes) -eq '<xml>unlock</xml>') 'a normal reply ZIP is read'
Check ((Read-Src 'Toolkit/HikMail.ps1') -notmatch 'Expand-Archive') 'nothing is expanded to disk any more'
Write-Host '#57 an old verified reset is checked again'
$hf = Read-Src 'Toolkit/HikResetFlow.ps1'
$i57 = $hf.IndexOf('Codex #57'); $blk = $hf.Substring($i57, 900)
Check ($blk -match '(& |Test-HikLoginOk )\$VerifyLogin \$ipNow \$SitePassword' -and $blk -match "'status' 'stale'") 'reproduction: a device verified in an earlier run is logged into again; a failure sends it back through the reset (2.2.2 trusted it forever)'
Check ($hf.IndexOf('Codex #57') -lt $hf.IndexOf('$todo = @($devs | Where-Object { $_.activated -and $fixed -notcontains')) 'the check runs before the to-do list is made'
Write-Host '#59 a busy answer keeps the scan for later'
$su = Read-Src 'Toolkit/ScanUpload.ps1'
Check ($su -match "\`$retry = \(-not \`$r\) -or \(\`$r -and -not \`$r\.ok -and \(\[string\]\`$r\.msg\) -match '\(\?i\)busy\|too many\|try again'\)" -and $su -match 'if \(\$retry\) \{') 'reproduction: {ok:false,msg:"busy"} queues the list (2.2.2 queued only on no answer)'
Check ($su -notmatch "if \(\`$f\.FullName -eq \(Pending-Path \`$Site\)\) \{ Remove-Item") 'the site''s older waiting list is not deleted before the new one is safe'
Write-Host '#64 an old HiTools export keeps its own 48-hour window'
$cr = Join-Path $tmp 'cr64'; New-Item -ItemType Directory -Force -Path (Join-Path $cr 'out') | Out-Null
Copy-Item (Join-Path $repo 'CamReset\Make-Request.ps1') $cr
[IO.File]::WriteAllText((Join-Path $cr 'out\latest.json'), '{"devices":[{"Brand":"Hikvision","Model":"DS-2CD2143G2-I","Serial":"DS-2CD2143G2-I20230101AAWRK12345678","IP":"192.168.1.64","MAC":"aa-bb","StartTime":"x"}]}')
$x64 = Join-Path $tmp 'K12345678.xml'; [IO.File]::WriteAllText($x64, '<x/>'); (Get-Item $x64).LastWriteTime = (Get-Date).AddHours(-30)
$o64 = & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $cr 'Make-Request.ps1') -Serial K12345678 -XmlPath $x64 2>&1 | Out-String
$rq = Get-Content (Join-Path $cr 'requests\DS-2CD2143G2-I20230101AAWRK12345678\request.json') -Raw | ConvertFrom-Json
$vu = [datetime]$rq.validUntil
Check ([math]::Abs(($vu - (Get-Date).AddHours(18)).TotalMinutes) -lt 5) 'reproduction: a 30-hour-old export is valid ~18 h more, not 48 (2.2.2 restarted the clock at packaging)'
(Get-Item $x64).LastWriteTime = (Get-Date).AddHours(-50)
$o64 = & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $cr 'Make-Request.ps1') -Serial K12345678 -XmlPath $x64 2>&1 | Out-String
Check ($o64 -match 'more than 48 hours ago') 'an export past 48 hours is refused'
Write-Host '#63 SiteCheck: no ping is not "dead" when the device''s services answer'
$scs = Read-Src 'sitecheck/SiteCheck.ps1'
$i63 = $scs.IndexOf('function Get-ScNet24'); $j63 = $scs.IndexOf('function Get-ScMedian', $i63); Invoke-Expression $scs.Substring($i63, $j63 - $i63)
$i63 = $scs.IndexOf('function Get-ScDiagnosis'); $j63 = $scs.IndexOf('function Format-ScReport', $i63); Invoke-Expression $scs.Substring($i63, $j63 - $i63)
$R63 = [ordered]@{ nets = @(@{ ip = '192.168.1.50'; prefix = 24 }); nvr = '192.168.1.20'; nvrRead = [ordered]@{ ok = $true; msg = 'Read 2 channels' }; duplicates = @(); notes = @()
  devices = @([pscustomobject]@{ Ip = '192.168.1.20'; Ok = 0; LossPct = 100; InArp = $true; Ports = @(80, 8000) }, [pscustomobject]@{ Ip = '192.168.1.31'; Ok = 0; LossPct = 100; InArp = $true; Ports = @(80, 554) })
  channels = @([pscustomobject]@{ Ch = 1; Ip = '192.168.1.31'; Online = $false; Name = 'Door'; Detail = 'Disconnected' }) }
$D63 = Get-ScDiagnosis $R63
$t63 = (@($D63.Findings | ForEach-Object { [string]$_.Text }) -join ' | ')
Check ($t63 -notmatch 'NVR 192\.168\.1\.20 is NOT answering' -and $t63 -match 'ping is turned off') 'reproduction: an NVR whose login worked is not "frozen / power-cycle" for no ping (2.2.2 said power-cycle)'
Check ($t63 -notmatch 'probably frozen' -and $t63 -match 'ports 80/554 are open') 'a camera with open ports and no ping is not called frozen'
Write-Host '#60 the outbox sends only camera-picture pushes, with their own fields'
$cv = Read-Src 'Toolkit/CamViews.ps1'
# 2.2.19 (Codex 2.2.18 F25): a file with another op is still never sent; it is now kept in outbox\quarantine instead of deleted (Test-Fix2219Sweep runs it)
Check ($cv -match "\[string\]\`$o\.op -ne 'camPush'\)\) \{ \`$bad = 'it is not a camera-pictures file' \}" -and $cv -match "foreach \(\`$p in @\('op', 'site', 'source', 'pc', 'pics', 'complete'\)\)") 'reproduction: a queued file with another op (or extra fields) is not sent with the upload key (2.2.2 copied every property)'
Write-Host 'split removed (#1-5, 26, 31-34, 39, 45, 46, 60): Crew is a local admin - no SYSTEM runner, IPC or ACL lock'
foreach ($gone in @('FixSiteRunner.ps1', 'FixSiteIpc.ps1', 'FixSiteAsk.ps1', 'HikPortalStep.ps1', 'WireItAcl.ps1')) { Check (-not (Test-Path (Join-Path $tk $gone))) ('#1-5/#32: ' + $gone + ' is gone (no SYSTEM runner, no ipc\ folder, no ACL plan)') }
$all = @(Get-ChildItem -LiteralPath $repo -Recurse -File -Include *.ps1, *.psm1, *.cmd | Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' })
$hits = @($all | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'Start-FsRunner|Test-FsRunnerTask|Send-FsIpc|Wait-FsIpcAnswer|Read-FsIpcJson|Install-WireItCrewSetup|Test-WireItLocked|Register-WireItRunnerTask|Get-WireItAclPlan' } | ForEach-Object { $_.Name })
Eq ($hits -join ',') '' '#1-5: no tool calls the runner, IPC or ACL functions any more'
$fs = Read-Src 'Toolkit/FixSite.ps1'
Check ($fs -notmatch '\$Ipc\b') '#5/#34: FixSite has no -Ipc path: questions are only asked in its own window (Read-Host), nothing in JSON files'
$fw = Read-Src 'Toolkit/FixSiteWindow.ps1'
Check ($fw -notmatch 'Test-WinAdmin|is not set up for this login' -and $fw -match "-Verb RunAs") '#45: the window starts the fix on this login (Windows asks Yes once), no "not set up for this login" refusal'
$wt = Read-Src 'Toolkit/WireItToolkit.ps1'
Check ($wt -notmatch 'needs an admin login on this PC' -and $wt -notmatch 'Invoke-TkUpdateTask') '#45: no admin-only refusal for the classic tools; updates run here, not through a task'
Check ($wt -match "schtasks\.exe /Delete /TN '\\WireIt\\Fix this site'") '#1-4: an old 2.2.x SYSTEM task is deleted when the Toolkit or installer runs'
$it = Read-Src 'Toolkit/Install-Toolkit.ps1'
# 2.2.4: the installer's clean-up is checked by RUNNING it (Invoke-TkMigration against an ACL/Task Scheduler mock): Test-Fix224.ps1 sections 4-6
Check ($fs -notmatch 'Get-FsRunnerRunsDir' -and $fw -notmatch 'siteList') '#39: the site list is read and saved by the fix itself on the tech''s login (no SYSTEM hand-over)'
# kept protections
Check ($fs.IndexOf('if (Test-Path -LiteralPath $tempState) { try { $nr0 = Remove-FsTempIps $tempState') -gt 0 -and $fs.IndexOf('if (Test-Path -LiteralPath $tempState) { try { $nr0') -lt $fs.IndexOf('function Done(')) '#31/#33 kept: a killed run''s temporary addresses are removed first thing on the next start'
Check ($fs -match "trap \{ \`$tnr = \`$null; try \{ \`$tnr = Remove-FsTempIps \`$tempState \}" -and $fs -match 'function Done\(\[int\]\$code\) \{\s+\$nr = \$null; try \{ \$nr = Remove-FsTempIps') '#31/#33 kept: every normal or failing end cleans the network before it reports (exit 6 if not back)'
$ask = $fs.Substring($fs.IndexOf('function Ask('), 900)
Check ($ask -notmatch 'Wait-FsIpcAnswer' -and $ask -match 'Read-Host') '#34 kept: a question waits for the person; closing the window ends the run (no timeout turns into "continue")'
foreach ($cr in @('CamReset/Find-Cameras.ps1', 'CamReset/Make-Request.ps1')) { $src = Read-Src $cr; Check ($src -match 'LOCALAPPDATA' -and $src -match 'catch \{\}') ('#46 kept: ' + $cr + ' logs where it can write and never fails on the log') }
$mr = Join-Path $tmp 'cr46'; New-Item -ItemType Directory -Force -Path (Join-Path $mr 'out') | Out-Null; Copy-Item (Join-Path $repo 'CamReset\Make-Request.ps1') $mr
[IO.File]::WriteAllText((Join-Path $mr 'out\latest.json'), '{"devices":[{"Brand":"Hikvision","Model":"DS-2CD2143G2-I","Serial":"DS-2CD2143G2-I20230101AAWRK12345678","IP":"192.168.1.64","MAC":"aa-bb","StartTime":"x"}]}')
New-Item -ItemType Directory -Force -Path (Join-Path $mr 'camreset.log') | Out-Null   # a "log" that cannot be appended to
$x46 = Join-Path $tmp 'K12345678b.xml'; [IO.File]::WriteAllText($x46, '<x/>')
$o46 = & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $mr 'Make-Request.ps1') -Serial K12345678 -XmlPath $x46 2>&1 | Out-String
Check ($o46 -match 'Request ready for') '#46 kept: Make-Request still reports success when CamReset\camreset.log cannot be written'
Write-Host 'version: 2.2.8 everywhere'
$v223 = @(); foreach ($p in @(@('Toolkit/FixSiteCore.ps1', "\`$script:FsVersion = '([^']+)'"), @('Toolkit/ToolkitCore.ps1', "\`$script:TkBuiltVersion = '([^']+)'"), @('Toolkit/FixSiteBw.ps1', "\`$script:FsVersion = '([^']+)'"))) { if ((Read-Src $p[0]) -match $p[1]) { $v223 += $Matches[1] } }
$v223 += [string]((Read-Src 'version.json') | ConvertFrom-Json).version
Eq (($v223 | Select-Object -Unique) -join ',') '2.2.19' 'FixSiteCore, ToolkitCore, FixSiteBw and version.json all say 2.2.19 (2.2.19: bumped; 2.2.18 said 2.2.18)'
Write-Host '#62 classic Fix NVR Undo: DHCP back, and unfinished work is not success'
$fn62 = Read-Src 'FixNVR/FixNVR.ps1'
$i62 = $fn62.IndexOf('function Hik-SetNet('); $j62 = $fn62.IndexOf("`nfunction ", $i62 + 10); Invoke-Expression $fn62.Substring($i62, $j62 - $i62)
function XSet($doc, [string]$path, [string]$v) { $n = $doc.SelectSingleNode('//*[local-name()="' + ($path -split '/')[0] + '"]'); if ($path -match '/') { $n = $n.SelectSingleNode('*[local-name()="' + ($path -split '/')[1] + '"]') }; if ($n) { $n.InnerText = $v } }
function Cred-For($d) { return $null }; function Hik-Ok($r) { return $true }; function Hik-Reboot($r) { return $false }; function Hik-Status($b) { return @{ text = '' } }
$script:put62 = ''; function Http($ip, $m, $p, $body) { $script:put62 = $body; return @{ code = 200; body = ''; err = '' } }
$dev62 = [pscustomobject]@{ ip = '10.0.0.5'; if_id = 1; net_xml = '<IPAddress><addressingType>static</addressingType><ipAddress>10.0.0.5</ipAddress><subnetMask>255.255.255.0</subnetMask><DefaultGateway><ipAddress>10.0.0.1</ipAddress></DefaultGateway></IPAddress>' }
[void](Hik-SetNet $dev62 '192.168.1.64' '255.255.255.0' '192.168.1.1' '' '' -Dhcp)
Check ($script:put62 -match '<addressingType>dynamic</addressingType>') 'reproduction: Undo of a camera that was on DHCP writes DHCP back (2.2.2 always wrote static)'
[void](Hik-SetNet $dev62 '192.168.1.64' '255.255.255.0' '192.168.1.1' '' '')
Check ($script:put62 -match '<addressingType>static</addressingType>') 'a normal fix still writes static'
# 2.2.19 (Codex 2.2.18 F10): the recorded mode is normalised first ('dynamic' from ISAPI = DHCP); the old text compared it verbatim to 'dhcp'
Check ($fn62 -match "\`$stOldMode = .*Get-FnAddrMode \`$st\.old_addressing" -and $fn62 -match "\`$toDhcp = \(\`$rev -and \`$stOldMode -eq 'dhcp'\)" -and $fn62 -match "\`$toDhcpN = \(\`$rev -and \`$stOldMode -eq 'dhcp'\)") 'Undo passes the recorded DHCP mode (normalised) for cameras and the NVR'
Check ($fn62 -match "\`$fails \+= @\(\`$manual \| ForEach-Object" -and $fn62 -match "Undo does not turn platform access") 'steps left to a person, and platform access Undo cannot reverse, make the run end with code 4'
Write-Host '#61 an update cut off half-way is undone at the next start'
. (Join-Path $tk 'ToolkitCore.ps1') 2>$null
$r61 = Join-Path $tmp 'u61'; $tk61 = Join-Path $r61 'Toolkit'; New-Item -ItemType Directory -Force -Path $tk61 | Out-Null
[IO.File]::WriteAllText((Join-Path $tk61 'A.ps1'), 'old A'); [IO.File]::WriteAllText((Join-Path $tk61 'version.json'), '{"version":"2.2.2"}')
$P61 = Get-TkPaths $tk61; $prev61 = Join-Path $P61.Previous '2.2.2'; New-Item -ItemType Directory -Force -Path (Join-Path $prev61 'Toolkit') | Out-Null
Copy-Item (Join-Path $tk61 'A.ps1') (Join-Path $prev61 'Toolkit\A.ps1'); Copy-Item (Join-Path $tk61 'version.json') (Join-Path $prev61 'version.json.prev')
# the power dies after A.ps1 and a new file were written, before version.json
[IO.File]::WriteAllText((Join-Path $tk61 'A.ps1'), 'NEW A'); [IO.File]::WriteAllText((Join-Path $tk61 'B.ps1'), 'new B'); [IO.File]::WriteAllText((Join-Path $tk61 'version.json'), '{"version":"half"}')
Save-TkJson ([ordered]@{ prev = $prev61; from = '2.2.2'; to = '2.2.3'; added = @('Toolkit/B.ps1'); at = 'x' }) (Join-Path $P61.Previous 'update-pending.json')
$m61 = Repair-TkInterruptedUpdate $tk61
Check ([IO.File]::ReadAllText((Join-Path $tk61 'A.ps1')) -eq 'old A' -and -not (Test-Path (Join-Path $tk61 'B.ps1'))) 'reproduction: the old files are back and the new one is gone (2.2.2 left a mixed version)'
Check (([IO.File]::ReadAllText((Join-Path $tk61 'version.json'))) -match '2\.2\.2' -and -not (Test-Path (Join-Path $P61.Previous 'update-pending.json')) -and $m61 -match 'put back') 'version.json is the old one, the journal is cleared, and the window is told'
Eq (Repair-TkInterruptedUpdate $tk61) '' 'no journal: nothing to do'
$tcs = Read-Src 'Toolkit/ToolkitCore.ps1'
Check ($tcs.IndexOf("Save-TkJson ([ordered]@{ prev = `$prev; from = `$old") -lt $tcs.IndexOf('$done.Add([string]$f.path)') -and $tcs -match "Remove-Item -LiteralPath \`$journal -Force -ErrorAction SilentlyContinue\r?\n  \} catch") 'Install-TkUpdate writes the journal before the first copy and clears it only at the end'
#@@BLOCKS@@
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
Write-Host ''; Write-Host ('Test-Fix223: ' + $script:pass + ' passed, ' + $script:fail + ' failed') -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $script:fail
