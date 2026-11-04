<#
 Test-FixSite.ps1 - WireIt Toolkit 2.0 "Fix this site" tests (pwsh 7 or Windows PowerShell 5.1; the end-to-end part needs python3).
   1. Planner unit tests (pure functions, no network)
   2. Dry run against recorded scans (tests\fixsite\*-scan.json): the exact text a tech would see, nothing touched
   3. End to end against a fake site (tests\fixsite\mock_site.py): Fix, run it AGAIN (nothing left to do), Undo, no password in any log
 Usage: powershell -ExecutionPolicy Bypass -File Test-FixSite.ps1        (exit code = number of failed checks)
#>
param([switch]$NoEndToEnd)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path; $tk = Split-Path -Parent $here; $fx = Join-Path $here 'fixsite'
. (Join-Path $tk 'FixSiteCore.ps1'); . (Join-Path $tk 'FixSiteDevices.ps1')
$script:fail = 0; $script:pass = 0
function Check([bool]$ok, [string]$what) { if ($ok) { $script:pass++; Write-Host ('  ok    ' + $what) } else { $script:fail++; Write-Host ('  FAIL  ' + $what) -ForegroundColor Red } }
function Eq($a, $b, [string]$what) { Check ("$a" -eq "$b") ($what + ' (got "' + $a + '", want "' + $b + '")') }
function J($f) { Get-Content (Join-Path $fx $f) -Raw | ConvertFrom-Json }
$psx = (Get-Process -Id $PID).Path

Write-Host '1. planner'
$lo = J 'lieber-scan.json'; $ll = J 'lieber-site-list.json'; $bo = J 'byw-scan.json'
$p = New-FsPlan $null $lo
Eq $p.scheme '192.168.1' 'scheme comes from the router this PC is on'
$bad = @($p.cams | Where-Object { $_.state -eq 'fix' })
Eq $bad.Count 2 'Lieber: 2 cameras to fix (the 2 on the wrong scheme); the 3 working ones are not touched (2.0.1)'
Eq @($p.healthy).Count 3 'Lieber: 3 working cameras collapse into one line'
$c64 = $p.cams | Where-Object { $_.ip -eq '192.168.0.64' }; $c65 = $p.cams | Where-Object { $_.ip -eq '192.168.0.65' }
Eq $c64.target '192.168.1.23' 'wrong-scheme camera goes to the address its NVR channel (ch 3) already looks for'
Eq $c65.target '192.168.1.24' 'second wrong-scheme camera -> .24 (ch 4)'
Check ($c65.steps -contains 'reset') 'unknown password -> official reset step'
Check ($c64.steps -contains 'password') 'known-but-not-site password -> set the site password'
Check ($c64.why -join ' ' -match 'by order') 'no list: the order-guess is flagged'
$g = $p.cams | Where-Object { $_.ip -eq '192.168.1.150' }
Eq $g.state 'ok' 'WORKING camera at .150 (DHCP, outside .21-.99, video on the NVR) is not touched (2.0.1)'
Check (-not $g.target -and -not @($g.steps).Count) 'working .150: no move, no password, no settings'
Check (@($p.leftAlone | Where-Object { $_ -match '192\.168\.1\.150' }).Count -eq 1) 'working .150: named once as "working, left as is" (address could be tidied by hand)'
Check (@($p.cams | Where-Object { $_.ip -in @('192.168.1.21', '192.168.1.22') -and ($_.steps.Count -or $_.settings) }).Count -eq 0) 'working cameras: no password, no settings, no I-frame (2.0.1)'
# the same .150 camera when it has NO video on the NVR: a real problem -> moved into the camera block, problem camera
$lo5 = J 'lieber-scan.json'; ($lo5.nvrs[0].channels | Where-Object { $_.ip -eq '192.168.1.150' }).online = $false
$g = (New-FsPlan $null $lo5).cams | Where-Object { $_.ip -eq '192.168.1.150' }
Eq $g.target '192.168.1.25' 'broken camera at .150 (router range) -> camera block'
Check ($g.problem) 'Dahua on a Hikvision NVR counts as a problem camera'
Eq $g.settings.codec 'H.264' 'problem camera: codec auto -> H.264'
Check ($g.steps -contains 'password') 'camera being fixed anyway gets the site password (no tick needed)'
# 2.0.1: a working camera keeps its own password, so the password that last worked on it is tried first (no false "password unknown")
$cs = [pscustomobject]@{ password = 'SITE'; known = @('K1', 'K2'); usual = @('U1'); cams = @{ 'aa:bb:cc:dd:ee:01' = 'U1' } }
$cl = @(Get-FsPasswordCandidates $cs 2 'AA-BB-CC-DD-EE-01')
Check ($cl[0].value -eq 'U1' -and $cl[0].label -eq 'WireIt usual 1' -and $cl[1].value -eq 'SITE') 'password candidates: the one that last worked on this camera first, labelled right'
Eq ((@(Get-FsPasswordCandidates $cs 2 'aa:bb:cc:dd:ee:02') | ForEach-Object { $_.value }) -join ',') 'SITE,K1' 'password candidates: unknown camera -> site password first (unchanged)'
# 2.0.1: password not known but its video is fine on the NVR -> working, NO official reset
$lo6 = J 'lieber-scan.json'; ($lo6.devices | Where-Object { $_.ip -eq '192.168.1.22' }).login = 'unknown'
$c22 = (New-FsPlan $null $lo6).cams | Where-Object { $_.ip -eq '192.168.1.22' }
Check ($c22.state -eq 'ok' -and -not @($c22.steps).Count) 'password unknown but video fine on the NVR: left alone, no reset'
$lo7 = J 'lieber-scan.json'; ($lo7.devices | Where-Object { $_.ip -eq '192.168.1.22' }).login = 'unknown'; ($lo7.nvrs[0].channels | Where-Object { $_.ip -eq '192.168.1.22' }).online = $false
$c22 = (New-FsPlan $null $lo7).cams | Where-Object { $_.ip -eq '192.168.1.22' }
Check ($c22.state -eq 'fix' -and $c22.steps -contains 'reset') 'password unknown AND no video: official reset offered'
# 2.0.1: the plan screen says how many change and how many are not touched
$fl = @(Format-FsPlan $p)
Eq $fl[0] 'Changes only the 2 camera(s) listed below. 3 working camera(s) will not be touched.' 'plan screen: first line = how many change, how many not touched'
Check (@($fl | Where-Object { $_ -like 'OK, not touched: 3 working camera(s)*' }).Count -eq 1) 'plan screen: one "OK, not touched" line'
Check (-not @($fl | Where-Object { $_ -match 'Front Door|site password and I-frame' }).Count) 'plan screen: working cameras are not listed as getting anything'
# drop-downs picked, box NOT ticked: only the broken cameras get them
$pd = New-FsPlan $null $lo @{ settings = @{ fps = 12; bitrate = 2048 } }
Check (@($pd.cams | Where-Object { $_.ip -in @('192.168.1.21', '192.168.1.22', '192.168.1.150') -and $_.steps.Count }).Count -eq 0) 'drop-downs without the tick: working cameras untouched'
$c64d = $pd.cams | Where-Object { $_.ip -eq '192.168.0.64' }
Check ($c64d.steps -contains 'settings' -and $c64d.settings.fps -eq 12 -and $c64d.settings.bitrate -eq 2048) 'drop-downs without the tick: the broken camera gets them'
# "Apply settings to ALL cameras" ticked: working cameras get ONLY the drop-down settings
$pa = New-FsPlan $null $lo @{ settingsAll = $true; settings = @{ fps = 12 } }
$a21 = $pa.cams | Where-Object { $_.ip -eq '192.168.1.21' }
Eq (@($a21.steps) -join ',') 'backup,settings,verify' 'ALL ticked: working camera gets settings only (no password, no move, no NVR)'
Check ($a21.settings.fps -eq 12 -and $a21.settings.gop -eq -1 -and $a21.settings.codec -eq 'keep' -and $a21.settings.smartCodec -eq 'keep') 'ALL ticked: only what was picked (+ I-frame follows the picked frame rate), no automatic codec'
$a150 = $pa.cams | Where-Object { $_.ip -eq '192.168.1.150' }
Check (-not $a150.target -and $a150.steps -notcontains 'password' -and $a150.settings.codec -eq 'keep') 'ALL ticked: working Dahua not moved, no password, no automatic H.264'
$fa = @(Format-FsPlan $pa)
Check ($fa[0] -match '^Changes the 5 camera\(s\) listed below: 2 with a problem \+ 3 working one\(s\) because you ticked "Apply settings to ALL cameras"\. 0 working camera\(s\) will not be touched\.$') ('ALL ticked: first line says working ones are included (got: ' + $fa[0] + ')')
Check (@($fa | Where-Object { $_ -like '3 working camera(s) get ONLY the drop-down settings*' }).Count -eq 1) 'ALL ticked: working cameras listed as getting ONLY the drop-down settings'
$pn = New-FsPlan $null $lo @{ settingsAll = $true }
Check (@($pn.cams | Where-Object { $_.ip -in @('192.168.1.21', '192.168.1.22', '192.168.1.150') -and $_.steps.Count }).Count -eq 0 -and ($pn.notes -join ' ') -match 'every drop-down is on "keep"') 'ALL ticked with nothing picked: nobody working touched, and it says so'
# "Set the site password on all cameras" ticked
$pp = New-FsPlan $null $lo @{ passwordAll = $true }
$p150 = $pp.cams | Where-Object { $_.ip -eq '192.168.1.150' }
Eq (@($p150.steps) -join ',') 'backup,password,nvr,verify' 'password ticked: working camera on another password gets the site password + its NVR channel, nothing else'
Check (-not @(($pp.cams | Where-Object { $_.ip -eq '192.168.1.21' }).steps).Count) 'password ticked: camera already on the site password is untouched'
Check ((@(Format-FsPlan $pp))[0] -match '1 working one\(s\) because you ticked "Set the site password on all cameras"') 'password ticked: first line says so'
$w5 = Get-FsWantedSettings ([pscustomobject]@{ codec = 'auto'; fps = 0; bitrate = 2048; smartCodecOff = 'all'; gopIsFps = $true }) $true ([pscustomobject]@{ codec = 'H.264' }) $true
Check ($w5.codec -eq 'keep' -and $w5.gop -eq 0 -and $w5.smartCodec -eq 'keep' -and $w5.bitrate -eq 2048) 'only-picked settings: no auto codec, no list settings, no smart codec, no I-frame without a picked frame rate'
$used = @{}; foreach ($c in $p.cams) { $a = if ($c.target) { $c.target } else { $c.ip }; if ($used.ContainsKey($a)) { Check $false ('two cameras on one address ' + $a) }; $used[$a] = 1 }
Check $true 'no two cameras get the same address'
$p2 = New-FsPlan $ll $lo
$pool = $p2.cams | Where-Object { $_.name -eq 'Pool' }
Eq $pool.state 'missing' 'list: camera that is not on the network is MISSING'
Check ($pool.why -join ' ' -match 'switch port 10: go check port 10') 'missing camera says which switch port to check'
Check ($pool.steps -contains 'poe') 'missing camera with a switch port gets a power-cycle step'
$by = $p2.cams | Where-Object { $_.name -eq 'Back Yard' }; Eq $by.target '192.168.1.23' 'list: Back Yard -> its list address'
Check (-not ($by.why -join ' ' -match 'by order')) 'list present: no order guess'
$pb = New-FsPlan $null $bo
$sec = $pb.cams | Where-Object { $_.name -eq 'Second Entrance' }
Check ($sec.problem) 'BYW Dahua (2020 firmware) = problem camera'
Check (($sec.why -join ' ') -match 'H.264 \(was H.265\)') 'BYW Dahua: H.264 change listed'
Check (($sec.why -join ' ') -match 'Smart Codec off') 'BYW Dahua: Smart Codec off listed'
$dr = $pb.cams | Where-Object { $_.name -eq 'DR Side' }
Check ($dr.why -join ' ' -match 'hung') 'hung camera is called hung'
Check ($dr.steps -contains 'poe') 'hung camera, port known from the scan (PortMap) -> PoE power-cycle'
$bo2 = J 'byw-scan.json'; $bo2.ports = [pscustomobject]@{}; foreach ($d in $bo2.devices) { foreach ($k in 'switch', 'port') { if ($d.PSObject.Properties[$k]) { $d.PSObject.Properties.Remove($k) } } }
$dr0 = (New-FsPlan $null $bo2).cams | Where-Object { $_.name -eq 'DR Side' }
Check ($dr0.steps -contains 'unplug' -and $dr0.steps -notcontains 'poe') 'hung camera, no switch port known -> asks a person to unplug it (no guessing a port)'
$pb2 = New-FsPlan (J 'byw-site-list.json') $bo; $dr2 = $pb2.cams | Where-Object { $_.name -eq 'DR Side' }
Check ($dr2.steps -contains 'poe') 'hung camera with a switch port -> PoE power-cycle'
Check (-not (@($pb.cams | Where-Object { $_.name -eq 'Lunch Room' -and $_.state -eq 'fix' }).Count -and $false)) 'planner ran'
# idempotent: a site that is already right plans nothing
$right = [pscustomobject]@{ taken = 'x'; pc = $lo.pc; devices = @($lo.devices | Where-Object { $_.ip -in @('192.168.1.20', '192.168.1.21', '192.168.1.22') } | ForEach-Object { $_.login = 'site password'; $_ }); nvrs = @([pscustomobject]@{ ip = '192.168.1.20'; brand = 'Hikvision'; channels = @($lo.nvrs[0].channels | Where-Object { $_.channel -le 2 }) }) }
foreach ($d in $right.devices) { if ($d.PSObject.Properties['streams']) { $d.streams.gop = 15 } }
$pr = New-FsPlan $null $right
Eq @($pr.cams | Where-Object { $_.state -ne 'ok' }).Count 0 'already-right site: nothing to do (idempotent)'
# standard: NVR on the wrong scheme -> .20
$nvrWrong = [pscustomobject]@{ pc = $lo.pc; devices = @([pscustomobject]@{ kind = 'nvr'; brand = 'Hikvision'; model = 'DS-7608NI'; mac = '44:19:b6:00:00:20'; ip = '192.168.0.250'; login = 'typed' }); nvrs = @([pscustomobject]@{ ip = '192.168.0.250'; brand = 'Hikvision'; model = 'DS-7608NI'; login = 'typed'; channels = @() }) }
Eq (New-FsPlan $null $nvrWrong).nvrs[0].target '192.168.1.20' 'NVR on the wrong scheme -> .20'
# PoE nets untouched
$poe = [pscustomobject]@{ pc = $lo.pc; devices = @([pscustomobject]@{ brand = 'Hikvision'; model = 'DS-2CD'; mac = '44:19:b6:00:09:09'; ip = '192.168.254.2'; login = '' }); nvrs = @() }
Eq @((New-FsPlan $null $poe).cams | Where-Object { $_.state -ne 'ok' }).Count 0 'cameras on the NVR''s own PoE ports are left alone'
# password candidates: saved first, never more than the cap, no duplicates
$cand = Get-FsPasswordCandidates ([pscustomobject]@{ password = 'A'; known = @('B', 'A'); usual = @('C', 'D') }) 3
Eq (($cand | ForEach-Object { $_.value }) -join ',') 'A,B,C' 'password order: site password, typed ones, then WireIt usual - capped at 3, no repeats'
# generated passwords
$ok = $true; for ($i = 0; $i -lt 200; $i++) { $pw = New-FsSitePassword; if ($pw.Length -ne 14 -or $pw -notmatch '[A-Z]' -or $pw -notmatch '[a-z]' -or $pw -notmatch '\d' -or $pw -notmatch '[@!*]' -or $pw -match '[^A-Za-z0-9@!*]' -or $pw -match '(?i)admin') { $ok = $false } }
Check $ok 'site password: 14 chars, 4 kinds, only Hikvision+Dahua+URL-safe symbols, 200 samples'
# 2.0.2 New site (not listed): no list, no site secrets, nothing typed
$no = J 'newsite-scan.json'
$pn2 = New-FsPlan $null $no ([ordered]@{ newSite = $true }); $nl2 = @(Format-FsPlan $pn2)
Eq $nl2[0] 'New site (no saved list): found 1 NVR (10.0.5.64, 5 channels) and 5 camera(s) on 10.0.5.x, router 10.0.5.1. 1 NVR channel(s) have no camera answering.' 'new site: plan line 1 says it is a new site and what was found'
Eq $nl2[1] 'Changes only the 2 camera(s) listed below. 3 working camera(s) will not be touched.' 'new site: line 2 = only the 2 problem cameras change (hung + not activated), 3 working not touched'
$gar = $pn2.cams | Where-Object { $_.name -eq 'Garage' }
Check ($gar.state -eq 'missing' -and $gar.listIp -eq '10.0.5.25' -and $gar.channel -eq 5 -and ($gar.why -join ' ') -match 'NVR ch 5 has no video') 'new site: "missing" = an NVR channel with no video that nothing answers for'
Check (@($nl2 | Where-Object { $_ -like 'Garage (10.0.5.25, NVR ch 5): missing*' }).Count -eq 1) 'new site: the missing camera is on the plan screen by its NVR name'
$hs = $pn2.cams | Where-Object { $_.ip -eq '10.0.5.24' }
Check ($hs.state -eq 'fix' -and ($hs.why -join ' ') -match 'hung' -and $hs.steps -contains 'unplug' -and $hs.steps -contains 'nvr') 'new site: hung camera flagged; unplug step (no switch map at a new site), back on its NVR channel'
$na = $pn2.cams | Where-Object { $_.ip -eq '10.0.5.150' }
Check ($na.steps -contains 'activate' -and ($na.why -join ' ') -match 'not activated') 'new site: not-activated camera flagged -> activate'
Check ($na.target -and $na.target -ne '10.0.5.25' -and (Get-FsLast $na.target) -ge 21 -and (Get-FsLast $na.target) -le 99) 'new site: it moves into .21-.99, and NOT onto the address the dead Garage channel looks for'
Check (@($pn2.cams | Where-Object { $_.ip -in @('10.0.5.21', '10.0.5.22', '10.0.5.26') -and ($_.state -ne 'ok' -or @($_.steps).Count -or $_.target) }).Count -eq 0) 'new site: the 3 working cameras get nothing (2.0.1 rule)'
Check (@($pn2.leftAlone | Where-Object { $_ -match '10\.0\.5\.22' -and $_ -match 'factory password' }).Count -eq 1) 'new site: a working camera still on the factory password is named, not changed'
Check (@($pn2.leftAlone | Where-Object { $_ -match '^NVR 10\.0\.5\.64' -and $_ -match '\.20' }).Count -eq 1) 'new site: NVR off the standard (.64, standard .20) is named, not moved'
Check (@($pn2.nvrs | Where-Object { @($_.steps).Count }).Count -eq 0) 'new site: a working NVR on the right scheme is never moved'
Check (($pn2.notes -join ' ') -match 'router gave this PC \.57') 'new site: router handing out addresses below .100 is flagged (not changed)'
Check (-not (($pn2.notes -join ' ') -match 'no camera list yet')) 'new site: no "you can save it at the end" note (it saves by itself)'
Check (-not (((New-FsPlan $null $lo).notes -join ' ') -match 'router gave')) 'router note: not shown when the PC got .100 or higher (Lieber)'
# a camera on the wrong scheme + one dead channel: paired; two dead channels: no guess, said plainly
$wc64 = [pscustomobject]@{ kind = 'camera'; brand = 'Hikvision'; model = 'DS-2CD2043G2-I'; serial = 'DS-2CD2043G2-I20200505AAWRF59999999'; mac = '44:19:b6:05:00:99'; ip = '192.168.1.64'; firmware = 'V5.7.3 build 220112'; login = 'WireIt usual 1' }
$no2 = J 'newsite-scan.json'; $no2.devices = @($no2.devices) + @($wc64)
$pn3 = New-FsPlan $null $no2 ([ordered]@{ newSite = $true }); $w64 = $pn3.cams | Where-Object { $_.ip -eq '192.168.1.64' }
Check ($w64.target -eq '10.0.5.25' -and $w64.channel -eq 5 -and $w64.steps -contains 'nvr' -and -not @($pn3.cams | Where-Object { $_.state -eq 'missing' }).Count) 'new site: wrong-scheme camera + one dead channel -> moved to that channel''s address, back on ch 5, nothing missing'
$no3 = J 'newsite-scan.json'; $no3.devices = @($no3.devices) + @($wc64); $no3.nvrs[0].channels = @($no3.nvrs[0].channels) + @([pscustomobject]@{ channel = 7; ip = '10.0.5.27'; online = $false; name = 'Shed'; protocol = 'HIKVISION' })
$pn4 = New-FsPlan $null $no3 ([ordered]@{ newSite = $true }); $w64b = $pn4.cams | Where-Object { $_.ip -eq '192.168.1.64' }
Check ((($w64b.why -join ' ') -match 'not clear') -and $w64b.target -and $w64b.target -notin @('10.0.5.25', '10.0.5.27') -and @($pn4.cams | Where-Object { $_.state -eq 'missing' }).Count -eq 2) 'new site: 1 wrong-scheme camera, 2 dead channels -> no guess, said plainly, both channel addresses kept free'
# passwords: per-camera, usual, then the old factory default - inside the same try limit
$cd = @(Get-FsPasswordCandidates ([pscustomobject]@{ password = ''; known = @(); usual = @('U1') }) 2 '' @('12345'))
Eq (($cd | ForEach-Object { $_.label + '=' + $_.value }) -join ',') 'WireIt usual 1=U1,factory default=12345' 'new site passwords: WireIt usual first, then the factory default'
Eq @(Get-FsPasswordCandidates ([pscustomobject]@{ password = 'S'; known = @('K'); usual = @('U1') }) 2 '' @('12345')).Count 2 'factory default stays inside the try limit (never an extra guess)'
$cd2 = @(Get-FsPasswordCandidates ([pscustomobject]@{ password = ''; known = @(); usual = @('U1'); cams = @{ 'aa:bb:cc:dd:ee:09' = 'P9' } }) 2 'aa:bb:cc:dd:ee:09' @('12345'))
Eq (($cd2 | ForEach-Object { $_.value }) -join ',') 'P9,U1' 'new site passwords: the one stored for that camera comes first'
Eq ((Get-FsFactoryPasswords 'Dahua') -join ',') 'admin' 'factory default per brand (Dahua)'; Eq @(Get-FsFactoryPasswords 'Unknown').Count 0 'no factory guess for an unknown brand'
Eq @(Get-FsPasswordCandidates ([pscustomobject]@{ password = 'A'; known = @('B'); usual = @('C') }) 3).Count 3 'without defaults (a listed site) nothing changes'
# name + the next visit
Eq (New-FsNewSiteName '10.0.5.1' ([datetime]'2026-11-04')) 'New site 10.0.5.x 2026-11-04' 'new site name = the router''s network + the date'
$ksd = Join-Path ([IO.Path]::GetTempPath()) ('fsks-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force -Path $ksd | Out-Null
$sl2 = New-FsSiteList 'New site 10.0.5.x 2026-11-04' '' $pn2 $no; ($sl2 | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $ksd (Get-FsListFileName 'New site 10.0.5.x 2026-11-04')) -Encoding UTF8
Check (@($sl2.cameras | Where-Object { $_.ip -eq '10.0.5.25' -and $_.channel -eq 5 }).Count -eq 1) 'new site list keeps the dead Garage channel, so next time it is "missing" by name'
Eq (Find-FsKnownSite $ksd $no.devices).site 'New site 10.0.5.x 2026-11-04' 'next visit: the NVR''s MAC finds the saved new site'
Check (-not (Find-FsKnownSite $ksd @([pscustomobject]@{ mac = '44:19:b6:05:00:21'; kind = 'camera' }))) 'one camera MAC alone is not enough to call it the same site'
Check (-not (Find-FsKnownSite $ksd @([pscustomobject]@{ mac = '44:19:b6:77:77:77'; kind = 'nvr' }))) 'another site''s NVR: not matched'
$kdr = Join-Path $ksd 'drive'; New-Item -ItemType Directory -Force -Path (Join-Path $kdr '45 Oak Ave\Docs') | Out-Null
($sl2 | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $kdr '45 Oak Ave\Docs\WireIt site list.json') -Encoding UTF8
$kd = Find-FsKnownSite @(Get-FsKnownSiteFiles '' @($kdr)) $no.devices
Check ($kd.site -eq '45 Oak Ave' -and $kd.folder -like '*45 Oak Ave') 'next visit: a site list in a Drive site folder is recognised too (named by its folder)'
Remove-Item $ksd -Recurse -Force

# settings diff
$cur = [pscustomobject]@{ codec = 'H.265'; fps = 20; width = 2560; height = 1440; bitrate = 4096; gop = 40; smartCodec = 'on'; maxWidth = 2688; maxHeight = 1520 }
$w = Get-FsWantedSettings ([pscustomobject]@{ codec = 'auto'; fps = 15; resolution = 'max'; bitrate = 0; smartCodecOff = 'problem'; gopIsFps = $true }) $true $null
$diff = @(Get-FsSettingsDiff $cur $w)
Eq (($diff | ForEach-Object { $_.field }) -join ',') 'codec,fps,resolution,gop,smartCodec' 'settings diff lists exactly what differs'
$done = [pscustomobject]@{ codec = 'H.264'; fps = 15; width = 2688; height = 1520; bitrate = 4096; gop = 15; smartCodec = 'off'; maxWidth = 2688; maxHeight = 1520 }
Eq @(Get-FsSettingsDiff $done $w).Count 0 'settings already right: no diff (idempotent)'
$w2 = Get-FsWantedSettings ([pscustomobject]@{ codec = 'auto'; fps = 0 }) $false $null; Eq $w2.codec 'keep' 'auto + healthy camera -> codec untouched'
$w3 = Get-FsWantedSettings ([pscustomobject]@{ codec = 'H.265'; fps = 0 }) $true $null; Eq $w3.codec 'H.265' 'a picked codec wins even on a problem camera (drop-down, no presets)'
Check (Test-FsOldFirmware 'V2.800.12JW000.0.R build 2020-06-28') 'old firmware (Dahua date)'
Check (Test-FsOldFirmware 'V5.6.5 build 200316') 'old firmware (Hikvision build)'
Check (-not (Test-FsOldFirmware 'V5.7.3 build 220112')) 'new firmware is not old'
# site list
$pl = New-FsPlan $null $lo; $sl = New-FsSiteList 'Lieber' 'WI-1' $pl $lo
Eq @($sl.cameras).Count 5 'save-as-list: every camera'
Check (@($sl.cameras | Where-Object { $_.ip -eq '192.168.1.23' }).Count -eq 1) 'save-as-list records the NEW address of moved cameras'
Check (-not (($sl | ConvertTo-Json -Depth 6) -match '(?i)"[a-z_]*(password|pwd|secret)[a-z_]*"\s*:')) 'site list holds no password field'
$snap = ConvertFrom-FsSnapshot ([pscustomobject]@{ site = 'x'; scheme = '192.168.1'; nvrs = @([pscustomobject]@{ ip = '192.168.1.20'; mac = '44-19-B6-00-00-20' }); cameras = @([pscustomobject]@{ mac = '44-19-B6-00-00-21'; ip = '192.168.1.21'; channel = 1; nvr = '192.168.1.20'; poe_port = $null }) })
Eq $snap.cameras[0].mac '44:19:b6:00:00:21' 'Fix NVR install snapshot works as a site list'
# log view
$v = ConvertFrom-FsLog @('22:01:01 SAY Front: ok', '22:01:02 GET 1.2.3.4/x', '22:01:03 ASK Type YES')
Eq $v.waiting 'Type YES' 'window: shows what it is waiting for'; Eq @($v.lines).Count 1 'window: device chatter is not shown'
Eq (ConvertFrom-FsLog @('22:01:03 ASK q', '22:01:04 ANSWER (hidden)')).waiting '' 'window: answered question is no longer waiting'
# secrets
$script:FsTestSecrets = $true
$sd = Join-Path ([IO.Path]::GetTempPath()) ('fssec-' + [guid]::NewGuid().ToString('N'))
$s = Read-FsSecrets $sd 'Test Site'; $s.password = 'Zz9@secretpw'; $s.known = @('Typed1'); $s.nvr = @{ '1.2.3.4' = 'NvrPw1' }; Save-FsSecrets $sd $s
$raw = Get-Content (Get-FsSecretPath $sd 'Test Site') -Raw
Check (-not ($raw -match 'secretpw')) 'secret file has no plain password'
$s2 = Read-FsSecrets $sd 'Test Site'; Eq $s2.password 'Zz9@secretpw' 'secret store round trip'; Eq $s2.nvr['1.2.3.4'] 'NvrPw1' 'secret store keeps NVR passwords'
Remove-Item $sd -Recurse -Force
$script:FsTestSecrets = $false

Write-Host '2. dry run on recorded scans'
function RunFix([string[]]$a) { $o = & $psx -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tk 'FixSite.ps1') @a 2>&1 | Out-String; return $o }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fstest-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$o = RunFix @('-Mode', 'DryRun', '-Site', 'Lieber', '-Recorded', (Join-Path $fx 'lieber-scan.json'), '-RunsRoot', "$tmp\runs", '-SecretsDir', "$tmp\sec", '-SitesDir', "$tmp\sites")
Check ($o -match 'Nothing on the network is touched') 'dry run says it touches nothing'
Check ($o -match 'moved \.64 -> \.23') 'dry run: Lieber camera moved .64 -> .23'
Check (-not ($o -match 'moved \.150')) 'dry run: working .150 is NOT moved (2.0.1)'
Check ($o -match 'Changes only the 2 camera\(s\) listed below\. 3 working camera\(s\) will not be touched\.') 'dry run: plan screen says 2 change, 3 not touched'
Check ($o -match 'official reset') 'dry run: unknown password -> official reset, one step'
Check ($o -match 'OK, not touched: 3 working camera\(s\)') 'dry run: working cameras are one "OK, not touched" line'
$oa = RunFix @('-Mode', 'DryRun', '-Site', 'Lieber', '-Recorded', (Join-Path $fx 'lieber-scan.json'), '-Fps', '12', '-AllCameras', '-RunsRoot', "$tmp\runs", '-SecretsDir', "$tmp\sec", '-SitesDir', "$tmp\sites")
Check ($oa -match 'because you ticked "Apply settings to ALL cameras"') 'dry run -AllCameras: plan says working ones are included'
Check (-not ($oa -match 'moved \.150')) 'dry run -AllCameras: still no move of a working camera'
$op = RunFix @('-Mode', 'DryRun', '-Site', 'Lieber', '-Recorded', (Join-Path $fx 'lieber-scan.json'), '-PasswordAll', '-RunsRoot', "$tmp\runs", '-SecretsDir', "$tmp\sec", '-SitesDir', "$tmp\sites")
Check ($op -match 'ticked "Set the site password on all cameras"') 'dry run -PasswordAll: plan says working ones get the site password'
Check (-not ($o -match 'Front Door')) 'dry run: healthy cameras are not listed one by one'
Check (-not (Test-Path "$tmp\sec\site-Lieber.dat")) 'dry run writes no secret file'
$o = RunFix @('-Mode', 'DryRun', '-Site', 'BYW', '-Recorded', (Join-Path $fx 'byw-scan.json'), '-ListFile', (Join-Path $fx 'byw-site-list.json'), '-RunsRoot', "$tmp\runs", '-SecretsDir', "$tmp\sec", '-SitesDir', "$tmp\sites")
Check ($o -match 'DR Side[^\r\n]*hung') 'dry run BYW: hung Dahua named'
Check ($o -match 'power-cycled Gym switch port 10') 'dry run BYW: PoE power-cycle of port 10'
Check ($o -match 'Gym 2[^\r\n]*go check port 11') 'dry run BYW: missing camera -> go check port 11'
Check ($o -match 'H\.264 \(was H\.265\)') 'dry run BYW: H.264 for the problem Dahua'
# 2.0.2 New site, dry run: nothing typed, named from the network, nothing saved
$on = RunFix @('-Mode', 'DryRun', '-NewSite', '-Recorded', (Join-Path $fx 'newsite-scan.json'), '-RunsRoot', "$tmp\n0\runs", '-SecretsDir', "$tmp\n0\sec", '-SitesDir', "$tmp\n0\sites")
Check ($on -match 'New site \(no saved list\): found 1 NVR \(10\.0\.5\.64, 5 channels\) and 5 camera\(s\)') 'dry run -NewSite: plan line 1 says new site + what was found'
Check ($on -match 'Site: New site 10\.0\.5\.x \d{4}-\d\d-\d\d') 'dry run -NewSite: named from the network, no site typed'
Check (-not ($on -match 'Which site\?')) 'dry run -NewSite: never asks which site'
Check ($on -match 'would save this site as "New site 10\.0\.5\.x') 'dry run -NewSite: says it would save the site'
Check (-not (Test-Path "$tmp\n0\sites") -and -not @(Get-ChildItem "$tmp\n0\sec" -Filter 'site-*' -ErrorAction SilentlyContinue).Count) 'dry run -NewSite: nothing saved'

$py = $null; foreach ($n in $(if ($env:OS -eq 'Windows_NT') { @('python', 'py') } else { @('python3') })) { $cmd = Get-Command $n -ErrorAction SilentlyContinue; if ($cmd) { $py = $cmd.Source; break } }
if (-not $NoEndToEnd -and $py) {
  Write-Host '3. end to end against a fake site'
  function Start-Mock([string]$scn) {
    $psi = New-Object Diagnostics.ProcessStartInfo($py, ('"' + (Join-Path $fx 'mock_site.py') + '" "' + (Join-Path $fx $scn) + '" 0')); $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
    $pr = [Diagnostics.Process]::Start($psi); $port = [int]$pr.StandardOutput.ReadLine(); return @{ proc = $pr; port = $port }
  }
  function Mock-State($port) { return (Invoke-RestMethod -Uri ('http://127.0.0.1:' + $port + '/dev/_pc/state')) }
  function E2E($m, [string[]]$answers, [string]$mode, [string]$site, [string[]]$extra = @()) {
    $ans = Join-Path $tmp 'ans.txt'; Set-Content -Path $ans -Value $answers
    return (RunFix (@('-Mode', $mode, '-Site', $site, '-MockUrl', ('http://127.0.0.1:' + $m.port), '-Answers', $ans, '-RunsRoot', "$tmp\e\runs", '-SecretsDir', "$tmp\e\sec", '-SitesDir', "$tmp\e\sites") + $extra))
  }
  $m = Start-Mock 'mock-lieber.json'
  try {
    [void](E2E $m @('Usual#Pw1', '') 'SetUsual' 'Lieber')
    $o = E2E $m @('NvrPass9', 'Typed#Pw77', 'YES', 'y', 'SAVED') 'Fix' 'Lieber'
    # 2.0.1 default: only the 3 broken cameras (2 on the wrong scheme + the Dahua with no video) are changed; Front Door + Driveway work and are NOT touched
    Check ($o -match 'Changes only the 3 camera\(s\) listed below\. 2 working camera\(s\) will not be touched\.') 'Lieber e2e: plan says 3 change, 2 working not touched'
    Check ($o -match 'Fixed: 3   Still a problem: 0') 'Lieber e2e: the 3 broken cameras fixed'
    Check ($o -match 'Back Yard: password set .*moved \.64 -> \.23 .*back on NVR ch 3 .*video back') 'Lieber e2e: checklist line reads like the spec'
    Check ($o -match 'OK, not touched: 2 working camera') 'Lieber e2e: checklist ends with "OK, not touched: 2"'
    $st = Mock-State $m.port
    $sp = $st.devices.'192.168.1.23'.password
    Check ($sp -ne 'Usual#Pw1' -and $sp.Length -eq 14) 'Lieber e2e: new strong site password on the fixed cameras'
    Eq (@('192.168.1.23', '192.168.1.24', '192.168.1.25' | ForEach-Object { $st.devices.$_.password } | Select-Object -Unique) -join ',') $sp 'Lieber e2e: all 3 fixed cameras have the site password'
    foreach ($ip in @('192.168.1.21', '192.168.1.22')) {
      $wc = $st.devices.$ip
      Check ($wc.password -eq 'Usual#Pw1' -and -not $wc.pw_changes) ('Lieber e2e: working ' + $ip + ' keeps its password (not touched)')
      Check ($wc.stream.gop -eq 30 -and $wc.stream.codec -eq 'H.265' -and $wc.stream.fps -eq 15) ('Lieber e2e: working ' + $ip + ' keeps its settings and I-frame (not touched)')
      Eq $wc.backups 0 ('Lieber e2e: working ' + $ip + ' not even logged into for a backup')
    }
    Eq (@($st.devices.PSObject.Properties.Name | Where-Object { $_ -like '192.168.0.*' }).Count) 0 'Lieber e2e: nobody left on the wrong scheme'
    $chs = $st.devices.'192.168.1.20'.channels
    Check ($chs.'3'.password -eq $sp -and $chs.'4'.password -eq $sp -and $chs.'5'.password -eq $sp) 'Lieber e2e: NVR channels of the fixed cameras hold the new password'
    Check ($chs.'1'.password -eq 'Usual#Pw1' -and $chs.'2'.password -eq 'Usual#Pw1') 'Lieber e2e: NVR channels of the working cameras untouched'
    Eq $st.devices.'192.168.1.23'.stream.codec 'H.264' 'Lieber e2e: old-firmware camera -> H.264'
    Eq $st.devices.'192.168.1.23'.stream.gop $st.devices.'192.168.1.23'.stream.fps 'Lieber e2e: fixed camera I-frame = FPS'
    Eq @($st.temps).Count 0 'Lieber e2e: temporary PC addresses all removed'
    Check ($st.devices.'192.168.1.23'.backups -ge 1) 'Lieber e2e: config backup taken before changes'
    $o2 = E2E $m @() 'Fix' 'Lieber'
    Check ($o2 -match 'Nothing for the Toolkit to change') 'Lieber e2e: running it AGAIN finds nothing to do (idempotent)'
    $st2 = Mock-State $m.port
    Eq $st2.devices.'192.168.1.23'.pw_changes 1 'Lieber e2e: second run did not touch passwords again'
    # tick "Set the site password on all cameras": the 2 working ones get the site password + their NVR channel, nothing else
    $o4 = E2E $m @('YES', 'n', 'n') 'Fix' 'Lieber' @('-PasswordAll')
    Check ($o4 -match '2 working one\(s\) because you ticked "Set the site password on all cameras"') 'Lieber e2e -PasswordAll: plan says the working ones are included'
    $st4 = Mock-State $m.port
    Eq (@($st4.devices.PSObject.Properties | Where-Object { $_.Value.kind -eq 'camera' } | ForEach-Object { $_.Value.password } | Select-Object -Unique) -join ',') $sp 'Lieber e2e -PasswordAll: every camera has the SAME site password'
    Check (($st4.devices.'192.168.1.20'.channels.PSObject.Properties | Where-Object { $_.Value.password -ne $sp }).Count -eq 0) 'Lieber e2e -PasswordAll: every NVR channel holds it'
    Check ($st4.devices.'192.168.1.21'.stream.gop -eq 30) 'Lieber e2e -PasswordAll: password only, settings untouched'
    # tick "Apply settings to ALL cameras" with frame rate 12: every camera gets 12 fps (+ I-frame 12), passwords untouched
    $o5 = E2E $m @('YES', 'n', 'n') 'Fix' 'Lieber' @('-AllCameras', '-Fps', '12')
    Check ($o5 -match 'because you ticked "Apply settings to ALL cameras"') 'Lieber e2e -AllCameras: plan says so'
    $st5 = Mock-State $m.port
    Check ($st5.devices.'192.168.1.21'.stream.fps -eq 12 -and $st5.devices.'192.168.1.21'.stream.gop -eq 12 -and $st5.devices.'192.168.1.21'.stream.codec -eq 'H.265') 'Lieber e2e -AllCameras: working camera gets only the picked frame rate (+ I-frame)'
    Eq $st5.devices.'192.168.1.21'.pw_changes 1 'Lieber e2e -AllCameras: no password change'
    Eq $st5.devices.'192.168.1.25'.stream.codec 'H.264' 'Lieber e2e -AllCameras: no codec change (Dahua stays H.264)'
    # no password anywhere in the logs / run files
    $hits = @(Get-ChildItem "$tmp\e" -Recurse -File | Where-Object { $_.Extension -ne '.dat' -and ($_.Name -notlike '*.bin') } | Select-String -SimpleMatch -Pattern ([string[]]@(@($sp) + @('Typed#Pw77', 'Usual#Pw1', 'NvrPass9'))) -List)
    Eq $hits.Count 0 'Lieber e2e: no password in any log, plan, scan or rollback file'
    # undo the three fixing runs, newest first
    $rds = @(Get-ChildItem "$tmp\e\runs" -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'rollback.json') } | Sort-Object Name -Descending)
    $o3 = E2E $m @('YES') 'Rollback' 'Lieber' @('-RollbackDir', $rds[0].FullName)
    Check ($o3 -match 'Undo finished: everything is back') 'Lieber e2e: undo puts everything back'
    Eq (Mock-State $m.port).devices.'192.168.1.21'.stream.fps 15 'undo -AllCameras run: frame rate back'
    foreach ($rd in @($rds | Select-Object -Skip 1)) { [void](E2E $m @('YES') 'Rollback' 'Lieber' @('-RollbackDir', $rd.FullName)) }
    $st3 = Mock-State $m.port
    Eq $st3.devices.'192.168.1.21'.password 'Usual#Pw1' 'undo -PasswordAll run: working camera password back'
    Eq $st3.devices.'192.168.0.64'.password 'Usual#Pw1' 'undo: old password back'
    Eq $st3.devices.'192.168.0.64'.stream.codec 'H.265' 'undo: old codec back'
    Eq $st3.devices.'192.168.1.20'.channels.'3'.ip '192.168.0.64' 'undo: NVR channel back to the old address'
  } finally { try { $m.proc.Kill() } catch {} }
  $m = Start-Mock 'mock-byw.json'
  try {
    [void](E2E $m @('Usual#Pw1', '') 'SetUsual' 'BYW')
    $o = E2E $m @('NvrPass9', 'YES', 'SAVED') 'Fix' 'BYW' @('-ListFile', (Join-Path $fx 'byw-site-list.json'), '-Bitrate', '2048')
    Check ($o -match 'DR Side: power-cycled Gym switch port 10 .*video back') 'BYW e2e: hung Dahua power-cycled through its port, then fixed'
    Check ($o -match 'Gym 2: power-cycled Gym switch port 11, still missing - go check port 11') 'BYW e2e: missing camera -> "go check port 11"'
    $st = Mock-State $m.port
    Eq $st.devices.'192.168.1.83'.stream.smart 'off' 'BYW e2e: Smart Codec off on the Dahua'
    Eq $st.devices.'192.168.1.83'.stream.codec 'H.264' 'BYW e2e: Dahua main stream H.264'
    Eq $st.devices.'192.168.1.83'.reboots 1 'BYW e2e: the no-video Dahua was restarted once'
    Eq @($st.poe_calls).Count 2 'BYW e2e: exactly 2 port power-cycles'
    Check ($o -match 'Fixed: 2   Still a problem: 1') 'BYW e2e: the 2 broken cameras fixed, 1 still needs a person (honest); the 2 working ones not touched (2.0.1)'
    Eq $st.devices.'192.168.1.83'.stream.bitrate 2048 'BYW e2e: bitrate drop-down goes on the broken camera'
    Check ($st.devices.'192.168.1.85'.stream.bitrate -eq 3584 -and -not $st.devices.'192.168.1.85'.pw_changes -and $st.devices.'192.168.1.85'.backups -eq 0) 'BYW e2e: working camera .85 untouched by the bitrate drop-down (no tick)'
    Check ($st.devices.'192.168.1.31'.stream.bitrate -eq 4096 -and -not $st.devices.'192.168.1.31'.pw_changes) 'BYW e2e: working camera .31 untouched'
    $o6 = E2E $m @('YES', 'n', 'n') 'Fix' 'BYW' @('-ListFile', (Join-Path $fx 'byw-site-list.json'), '-Bitrate', '2048', '-AllCameras')
    $st6 = Mock-State $m.port
    Check ($o6 -match 'because you ticked "Apply settings to ALL cameras"') 'BYW e2e -AllCameras: plan says working ones are included'
    Check ($st6.devices.'192.168.1.85'.stream.bitrate -eq 2048 -and $st6.devices.'192.168.1.31'.stream.bitrate -eq 2048) 'BYW e2e -AllCameras: bitrate on the working cameras too'
    Check (-not $st6.devices.'192.168.1.31'.pw_changes -and $st6.devices.'192.168.1.85'.stream.codec -eq 'H.264' -and $st6.devices.'192.168.1.31'.stream.codec -eq 'H.265') 'BYW e2e -AllCameras: nothing but the bitrate (no password, no codec)'
  } finally { try { $m.proc.Kill() } catch {} }
  # 2.0.2: New site (not listed) - no list, no site secrets, no -Site; wrong-IP camera + hung camera fixed, the rest untouched
  function E2EN($m, [string[]]$answers, [string]$mode, [string[]]$extra = @()) {
    $ans = Join-Path $tmp 'ansn.txt'; Set-Content -Path $ans -Value $answers
    return (RunFix (@('-Mode', $mode, '-MockUrl', ('http://127.0.0.1:' + $m.port), '-Answers', $ans, '-RunsRoot', "$tmp\n\runs", '-SecretsDir', "$tmp\n\sec", '-SitesDir', "$tmp\n\sites") + $extra))
  }
  $m = Start-Mock 'mock-newsite.json'
  try {
    [void](E2EN $m @('Usual#Pw1', '') 'SetUsual')
    Check (-not @(Get-ChildItem "$tmp\n\sec" -Filter 'site-*' -ErrorAction SilentlyContinue).Count) 'new site e2e: starts with no site secrets and no list'
    $on = E2EN $m @('12 Elm St', 'YES', '', 'SAVED') 'Fix' @('-NewSite')
    Check ($on -match 'New site \(no saved list\): found 1 NVR \(10\.0\.5\.64, 5 channels\) and 5 camera\(s\) on 10\.0\.5\.x, router 10\.0\.5\.1\.') 'new site e2e: plan line 1 = new site + what it found'
    Check ($on -match 'Changes only the 2 camera\(s\) listed below\. 3 working camera\(s\) will not be touched\.') 'new site e2e: only the 2 problem cameras change'
    Check ($on -match 'Back \(192\.168\.1\.64\): wrong IP scheme') 'new site e2e: wrong IP scheme flagged'
    Check ($on -match 'Side \(10\.0\.5\.24\): hung') 'new site e2e: hung camera flagged'
    Check ($on -match 'Office \(10\.0\.5\.22\): still on the factory password') 'new site e2e: factory password found inside the try limit, named, not changed'
    Check ($on -match 'Back: password set .*moved \.64 -> \.23 .*back on NVR ch 3 .*video back') 'new site e2e: wrong-IP camera moved to the address its NVR channel looks for, back on ch 3, video back'
    Check ($on -match 'Side: unplugged and plugged back.*password set .*back on NVR ch 4 .*video back') 'new site e2e: hung camera came back after the unplug and was fixed'
    Check ($on -match 'Fixed: 2   Still a problem: 0') 'new site e2e: 2 fixed, 0 left'
    Check ($on -match 'Site name: 12 Elm St') 'new site e2e: the address typed after the plan names the site'
    Check ($on.IndexOf('Optional: type this site') -gt $on.IndexOf('Changes only the 2 camera')) 'new site e2e: the address is asked only AFTER the plan screen'
    Check ($on.IndexOf('Optional: type this site') -lt $on.IndexOf('Type YES to fix')) 'new site e2e: ... and before the YES'
    $st = Mock-State $m.port
    $sp = $st.devices.'10.0.5.23'.password
    Check ($sp -ne 'Usual#Pw1' -and $sp.Length -eq 14) 'new site e2e: a new strong site password on the fixed cameras'
    Eq $st.devices.'10.0.5.24'.password $sp 'new site e2e: hung camera has the site password too'
    Eq (@($st.devices.PSObject.Properties.Name | Where-Object { $_ -like '192.168.*' }).Count) 0 'new site e2e: nobody left on the wrong scheme'
    foreach ($wp in @(@('10.0.5.21', 'Usual#Pw1'), @('10.0.5.22', '12345'), @('10.0.5.26', 'Usual#Pw1'))) {
      $wc = $st.devices.($wp[0])
      Check ($wc.password -eq $wp[1] -and -not $wc.pw_changes -and $wc.backups -eq 0 -and $wc.stream.gop -eq 30 -and $wc.stream.codec -eq 'H.265' -and -not $wc.reboots) ('new site e2e: working ' + $wp[0] + ' untouched (password, settings, no backup login, no restart)')
    }
    $chs = $st.devices.'10.0.5.64'.channels
    Check ($chs.'1'.password -eq 'Usual#Pw1' -and $chs.'2'.password -eq '12345' -and $chs.'5'.password -eq 'Usual#Pw1') 'new site e2e: NVR channels of the working cameras untouched'
    Check ($chs.'3'.ip -eq '10.0.5.23' -and $chs.'3'.password -eq $sp -and $chs.'4'.password -eq $sp) 'new site e2e: NVR channels of the 2 fixed cameras hold the new password'
    Eq $st.devices.'10.0.5.64'.net.ip '10.0.5.64' 'new site e2e: the NVR (working, off the standard) was not moved'
    Eq @($st.temps).Count 0 'new site e2e: temporary PC addresses all removed'
    $lf = Join-Path "$tmp\n\sites" '12_Elm_St.json'
    Check (Test-Path $lf) 'new site e2e: site list saved under the typed address'
    $sl3 = Get-Content $lf -Raw | ConvertFrom-Json
    Check ($sl3.site -eq '12 Elm St' -and @($sl3.cameras).Count -eq 5 -and @($sl3.cameras | Where-Object { $_.ip -eq '10.0.5.23' -and $_.channel -eq 3 }).Count -eq 1) 'new site e2e: list = 5 cameras with their NEW addresses'
    Check ((Test-Path "$tmp\n\sec\site-12_Elm_St.dat") -and -not @(Get-ChildItem "$tmp\n\sec" -Filter 'site-New_site*').Count) 'new site e2e: secrets file saved under the same name (no leftover auto-named file)'
    $hits = @(Get-ChildItem "$tmp\n" -Recurse -File | Where-Object { $_.Extension -ne '.dat' } | Select-String -SimpleMatch -Pattern ([string[]]@($sp, 'Usual#Pw1')) -List)
    Eq $hits.Count 0 'new site e2e: no password in any log, plan, scan, list or rollback file'
    # next visit: New site again -> the NVR is recognised, its list + site password are used, nothing to do
    $on2 = E2EN $m @() 'Fix' @('-NewSite')
    Check ($on2 -match 'saved before on this PC as "12 Elm St"') 'new site e2e, next visit: recognised by the NVR, no new name'
    Check ($on2 -match 'Nothing for the Toolkit to change') 'new site e2e, next visit: nothing to change (it logs in with the saved site password)'
    Eq (Mock-State $m.port).devices.'10.0.5.23'.pw_changes 1 'new site e2e, next visit: no password touched again'
    # undo with an empty site box: it uses the run's own site (its secrets hold the old passwords)
    $rdn = @(Get-ChildItem "$tmp\n\runs" -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'rollback.json') } | Sort-Object Name -Descending)[0]
    $ou = E2EN $m @('YES') 'Rollback' @('-RollbackDir', $rdn.FullName)
    Check ($ou -match 'Undo finished: everything is back') 'new site e2e: undo works without typing the site'
    $stu = Mock-State $m.port
    Check ($stu.devices.'192.168.1.64'.password -eq 'Usual#Pw1' -and $stu.devices.'10.0.5.24'.password -eq 'Usual#Pw1') 'new site e2e: undo puts the old passwords and the old address back'
  } finally { try { $m.proc.Kill() } catch {} }
} else { Write-Host '3. end to end: skipped (no python or -NoEndToEnd)' }
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('FixSite tests: ' + $script:pass + ' passed, ' + $script:fail + ' failed') -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $script:fail
