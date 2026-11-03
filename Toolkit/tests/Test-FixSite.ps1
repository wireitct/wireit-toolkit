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
Eq $bad.Count 3 'Lieber: 3 cameras to fix (2 wrong scheme + 1 outside the block), 2 healthy'
Eq @($p.healthy).Count 2 'Lieber: 2 healthy collapse'
$c64 = $p.cams | Where-Object { $_.ip -eq '192.168.0.64' }; $c65 = $p.cams | Where-Object { $_.ip -eq '192.168.0.65' }
Eq $c64.target '192.168.1.23' 'wrong-scheme camera goes to the address its NVR channel (ch 3) already looks for'
Eq $c65.target '192.168.1.24' 'second wrong-scheme camera -> .24 (ch 4)'
Check ($c65.steps -contains 'reset') 'unknown password -> official reset step'
Check ($c64.steps -contains 'password') 'known-but-not-site password -> set the site password'
Check ($c64.why -join ' ' -match 'by order') 'no list: the order-guess is flagged'
$g = $p.cams | Where-Object { $_.ip -eq '192.168.1.150' }
Eq $g.target '192.168.1.25' 'camera at .150 (router range) -> camera block'
Check ($g.problem) 'Dahua on a Hikvision NVR counts as a problem camera'
Eq $g.settings.codec 'H.264' 'problem camera: codec auto -> H.264'
Check (-not $p.cams[0].problem -and $p.cams[0].settings.codec -eq 'keep') 'healthy new camera: codec auto -> left alone (H.264 only for old/problem cameras)'
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
Check ($o -match 'moved \.150 -> \.25') 'dry run: .150 -> .25'
Check ($o -match 'official reset') 'dry run: unknown password -> official reset, one step'
Check ($o -match '2 other camera\(s\) are fine') 'dry run: healthy cameras are one line'
Check (-not ($o -match 'Front Door')) 'dry run: healthy cameras are not listed one by one'
Check (-not (Test-Path "$tmp\sec\site-Lieber.dat")) 'dry run writes no secret file'
$o = RunFix @('-Mode', 'DryRun', '-Site', 'BYW', '-Recorded', (Join-Path $fx 'byw-scan.json'), '-ListFile', (Join-Path $fx 'byw-site-list.json'), '-RunsRoot', "$tmp\runs", '-SecretsDir', "$tmp\sec", '-SitesDir', "$tmp\sites")
Check ($o -match 'DR Side[^\r\n]*hung') 'dry run BYW: hung Dahua named'
Check ($o -match 'power-cycled Gym switch port 10') 'dry run BYW: PoE power-cycle of port 10'
Check ($o -match 'Gym 2[^\r\n]*go check port 11') 'dry run BYW: missing camera -> go check port 11'
Check ($o -match 'H\.264 \(was H\.265\)') 'dry run BYW: H.264 for the problem Dahua'

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
    Check ($o -match 'Fixed: 5   Still a problem: 0') 'Lieber e2e: all 5 cameras fixed'
    Check ($o -match 'Back Yard: password set .*moved \.64 -> \.23 .*back on NVR ch 3 .*video back') 'Lieber e2e: checklist line reads like the spec'
    $st = Mock-State $m.port
    $sp = ($st.devices.PSObject.Properties | Where-Object { $_.Value.kind -eq 'camera' } | ForEach-Object { $_.Value.password } | Select-Object -Unique)
    Eq @($sp).Count 1 'Lieber e2e: every camera has the SAME new site password'
    Check ($sp -ne 'Usual#Pw1' -and $sp.Length -eq 14) 'Lieber e2e: new strong password set'
    Eq (@($st.devices.PSObject.Properties.Name | Where-Object { $_ -like '192.168.0.*' }).Count) 0 'Lieber e2e: nobody left on the wrong scheme'
    $chs = $st.devices.'192.168.1.20'.channels
    Check (($chs.PSObject.Properties | Where-Object { $_.Value.password -ne $sp }).Count -eq 0) 'Lieber e2e: NVR channels hold the new password'
    Eq $st.devices.'192.168.1.23'.stream.codec 'H.264' 'Lieber e2e: old-firmware camera -> H.264'
    Eq $st.devices.'192.168.1.21'.stream.codec 'H.265' 'Lieber e2e: healthy camera keeps H.265'
    Eq $st.devices.'192.168.1.21'.stream.gop 15 'Lieber e2e: I-frame = FPS'
    Eq @($st.temps).Count 0 'Lieber e2e: temporary PC addresses all removed'
    Check ($st.devices.'192.168.1.21'.backups -ge 1) 'Lieber e2e: config backup taken before changes'
    $o2 = E2E $m @() 'Fix' 'Lieber'
    Check ($o2 -match 'Nothing for the Toolkit to change') 'Lieber e2e: running it AGAIN finds nothing to do (idempotent)'
    $st2 = Mock-State $m.port
    Eq $st2.devices.'192.168.1.21'.pw_changes 1 'Lieber e2e: second run did not touch passwords again'
    # no password anywhere in the logs / run files
    $hits = @(Get-ChildItem "$tmp\e" -Recurse -File | Where-Object { $_.Extension -ne '.dat' -and ($_.Name -notlike '*.bin') } | Select-String -SimpleMatch -Pattern ([string[]]@(@($sp) + @('Typed#Pw77', 'Usual#Pw1', 'NvrPass9'))) -List)
    Eq $hits.Count 0 'Lieber e2e: no password in any log, plan, scan or rollback file'
    $rd = Get-ChildItem "$tmp\e\runs" -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'rollback.json') } | Sort-Object Name | Select-Object -Last 1
    $o3 = E2E $m @('YES') 'Rollback' 'Lieber' @('-RollbackDir', $rd.FullName)
    Check ($o3 -match 'Undo finished: everything is back') 'Lieber e2e: undo puts everything back'
    $st3 = Mock-State $m.port
    Eq $st3.devices.'192.168.0.64'.password 'Usual#Pw1' 'undo: old password back'
    Eq $st3.devices.'192.168.0.64'.stream.codec 'H.265' 'undo: old codec back'
    Eq $st3.devices.'192.168.1.20'.channels.'3'.ip '192.168.0.64' 'undo: NVR channel back to the old address'
  } finally { try { $m.proc.Kill() } catch {} }
  $m = Start-Mock 'mock-byw.json'
  try {
    [void](E2E $m @('Usual#Pw1', '') 'SetUsual' 'BYW')
    $o = E2E $m @('NvrPass9', 'YES', 'SAVED') 'Fix' 'BYW' @('-ListFile', (Join-Path $fx 'byw-site-list.json'))
    Check ($o -match 'DR Side: power-cycled Gym switch port 10 .*video back') 'BYW e2e: hung Dahua power-cycled through its port, then fixed'
    Check ($o -match 'Gym 2: power-cycled Gym switch port 11, still missing - go check port 11') 'BYW e2e: missing camera -> "go check port 11"'
    $st = Mock-State $m.port
    Eq $st.devices.'192.168.1.83'.stream.smart 'off' 'BYW e2e: Smart Codec off on the Dahua'
    Eq $st.devices.'192.168.1.83'.stream.codec 'H.264' 'BYW e2e: Dahua main stream H.264'
    Eq $st.devices.'192.168.1.83'.reboots 1 'BYW e2e: the no-video Dahua was restarted once'
    Eq @($st.poe_calls).Count 2 'BYW e2e: exactly 2 port power-cycles'
    Check ($o -match 'Fixed: 4   Still a problem: 1') 'BYW e2e: 4 fixed, 1 still needs a person (honest)'
  } finally { try { $m.proc.Kill() } catch {} }
} else { Write-Host '3. end to end: skipped (no python or -NoEndToEnd)' }
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host ('FixSite tests: ' + $script:pass + ' passed, ' + $script:fail + ' failed') -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $script:fail
