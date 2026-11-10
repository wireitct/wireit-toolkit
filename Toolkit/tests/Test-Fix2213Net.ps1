<# Test-Fix2213Net.ps1 - WireIt Toolkit 2.2.13 (Nov 10 2026): Codex's 2.2.12 review, finding #4 (Restore Network could leave the
   WifiWatch task switched OFF for good after an interruption) and Codex's advice on the DHCP reset (label + saved settings + restore steps).
   #4   2.2.13 never switches the task off (the pause is only the expiring pause file); a task an earlier 2.2.12 run left off (its pause
        file still there) is switched back on; the task's REAL state is read again before "WifiWatch is back on" is said.
        Codex repro (reproduce-pause.ps1): start -> killed (no finally) -> pause expires -> fresh start + normal finish: the task must be ON
        and "back on" must be true. The task state lives in a FILE here (a persistent stand-in for Task Scheduler), so a killed process
        really loses its memory while the task state stays.
   DHCP "Reset chosen adapter to DHCP": the question says so; after a reset the end prints the saved-settings file, the old address /
        mask / gateway / DNS in plain text and the steps to put them back.
   Moshe's rule: every change is tested for failing half-way, the wrong owner/adapter and running twice.
   Old-code proof: $env:FIX2213NET_RN_FILE = <a copy of the 2.2.12 RestoreNetwork.ps1> runs this suite against it.
   Runs against a simulated Windows (no real adapter or task is touched). NEEDS WINDOWS CHECK: Get/Enable-ScheduledTask as SYSTEM task
   seen from an admin and from a standard login (the 'unknown' read), the pause file in %ProgramData%\WireIt written by a standard user.
   Exit code = number of failed checks.
#>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2213net-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check($ok, [string]$name, [string]$more = '') {
  if ($ok -is [bool] -and $ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + ($more -replace "`n", "`n     ")) } }
}
function Deferred([string]$name) { $script:deferred++; Write-Host ('DEFERRED ' + $name) }
function Q([string]$s) { return "'" + $s.Replace("'", "''") + "'" }
function Invoke-Driver([string]$name, [string]$code) {
  $f = Join-Path $tmp ($name + '.ps1'); [IO.File]::WriteAllText($f, $code, (New-Object Text.UTF8Encoding($true)))
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $o = & $exe -NoProfile -ExecutionPolicy Bypass -File $f 2>&1 | Out-String } finally { $ErrorActionPreference = $prev }
  return $o
}
function Get-Json([string]$out, [string]$tag = 'JSON') { $m = [regex]::Match($out, '(?m)^' + $tag + '=(\{.*\})\s*$'); if ($m.Success) { try { return ($m.Groups[1].Value | ConvertFrom-Json) } catch {} }; return $null }

$rnFile = $(if ($env:FIX2213NET_RN_FILE) { $env:FIX2213NET_RN_FILE } else { Join-Path $tk 'RestoreNetwork.ps1' })   # tests only: another copy (old-code proof)
$wwFile = Join-Path $repo 'wifiwatch\WifiWatch.ps1'
if ($env:FIX2213NET_RN_FILE) { Write-Host ('(running against ' + $rnFile + ')') }
$simCode = @'
__SIM__
# ---- 2.2.13: the WifiWatch task's state in a FILE (Task Scheduler keeps it when the process dies), the REAL pause-file writer ----
$script:TaskFile = Join-Path $D 'task-state.txt'
function TS-Get { if (Test-Path -LiteralPath $script:TaskFile) { return ([IO.File]::ReadAllText($script:TaskFile)).Trim() }; return 'on' }
function TS-Set([string]$v) { [IO.File]::WriteAllText($script:TaskFile, $v) }
$script:SimInner = $script:RnOps
$script:sim.taskFail = @{}; $script:sim.taskOffAt = ''; $script:sim.killAt = ''; $script:sim.taskUnreadable = $false
$script:RnOps = {
  param($op, $a)
  if ($script:sim.killAt -and $op -eq $script:sim.killAt) { [Console]::Out.WriteLine('KILLED at ' + $op); [Console]::Out.Flush(); [Environment]::Exit(9) }
  if ($script:sim.taskOffAt -and $op -eq $script:sim.taskOffAt) { TS-Set 'off' }
  switch ($op) {
    'task' {
      [void]$script:sim.order.Add('task' + $(if ($a.set) { ':' + $a.set } else { '' }))
      if ($script:sim.task -eq 'none') { return 'none' }
      if ($a.set) { if ($script:sim.taskFail[[string]$a.set]) { throw ('simulated: Task Scheduler said no to ' + $a.set) }; TS-Set ([string]$a.set); return [string]$a.set }
      if ($script:sim.taskUnreadable) { return 'unknown' }
      return (TS-Get)
    }
    'pauseby' { [void]$script:sim.order.Add('pauseby'); $f = $script:RnPauseFile; return [bool]((Test-Path -LiteralPath $f) -and ([IO.File]::ReadAllText($f) -match '(?m)^by=Restore Network')) }
    'pause' {
      [void]$script:sim.order.Add('pause:' + $a.set)
      if ($a.set -eq 'on') { if ($script:sim.pauseFail) { return $false }; $ok = [bool](Write-RnPauseFile $script:RnPauseFile $script:RnPauseMinutes); $script:sim.pauseOn = $ok; return $ok }
      $ok = [bool](Remove-RnPauseFile $script:RnPauseFile); $script:sim.pauseOn = -not $ok; return $ok
    }
    default { return (& $script:SimInner $op $a) }
  }
}
# a pause file as an earlier Restore Network left it (expired: until= in the past)
function Write-OldPause([string]$by = 'Restore Network (WireIt Toolkit 2.2.12) pid 4242', [int]$minutesAgo = 30) {
  $u = (Get-Date).ToUniversalTime().AddMinutes(-$minutesAgo).ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
  [IO.File]::WriteAllLines($script:RnPauseFile, [string[]]@(('until=' + $u), ('by=' + $by)))
}
function Expire-Pause { if (Test-Path -LiteralPath $script:RnPauseFile) { $t = [IO.File]::ReadAllText($script:RnPauseFile); $u = (Get-Date).ToUniversalTime().AddMinutes(-1).ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture); [IO.File]::WriteAllText($script:RnPauseFile, ([regex]::Replace($t, '(?m)^until=\S+', ('until=' + $u)))) } }
function Setup-Alias($e) { $e.dhcp = $false; $e.active.Clear(); $e.persistent.Clear(); Sim-Ext $e '192.168.250.250' 'both'; Write-FsJournal 12 $true '192.168.250.250' }
function Res($r) { return @{ code = $r.code; said = $r.said; order = $r.order; task = (TS-Get); pause = [bool](Test-Path -LiteralPath $script:RnPauseFile) } }
'@
$simCode = $simCode.Replace('__SIM__', [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fix2213net\sim-2212.ps1.txt')))
function Rn-Driver([string]$name, [string]$body, [string]$dirName = '') {
  if (-not $dirName) { $dirName = $name }
  $d = Join-Path $tmp $dirName; New-Item -ItemType Directory -Force -Path (Join-Path $d 'Toolkit\fixsite-runs\_state'), (Join-Path $d 'FixNVR\state') | Out-Null
  $pre = '$ErrorActionPreference = ''Continue''' + "`n" + '. ' + (Q $rnFile) + ' -ToolkitDir ' + (Q (Join-Path $d 'Toolkit')) + ' -FixNvrState ' + (Q (Join-Path $d 'FixNVR\state\temp-ips.json')) + ' -ReceiptDir ' + (Q (Join-Path $d 'receipts')) + ' -PauseFile ' + (Q (Join-Path $d 'wifiwatch.pause')) + ' -WaitSeconds 4 -OnlineSeconds 3 -Auto' + "`n" + '$D = ' + (Q $d) + "`n" + $simCode + "`n"
  return (Invoke-Driver $name ($pre + $body.Replace('__WW__', (Q $wwFile))))
}
function Said-BackOnTrue($j) { return [bool](($j.said -notmatch 'WifiWatch is back on') -or $j.task -eq 'on') }

try {
  # =====================================================================================
  Write-Host '#4 (Codex reproduce-pause): start -> the run is KILLED (no finally) -> the pause expires -> a fresh run finishes normally'
  $o1 = Rn-Driver 'r4a' @'
$e = New-SimAdapter 'Ethernet' 12 $false; $script:sim.ads = @($e); Setup-Alias $e; TS-Set 'on'
$script:sim.killAt = 'online'
$r = Run-Rn
'@
  $o2 = Rn-Driver 'r4b' @'
# a NEW process: nothing of the killed run's memory is left; only the task state (file) and its pause file
$tAfterKill = TS-Get; $pLeft = [bool](Test-Path -LiteralPath $script:RnPauseFile)
Expire-Pause
New-Item -ItemType Directory -Force -Path (Join-Path $D 'ww') | Out-Null; . __WW__ -Dir (Join-Path $D 'ww') -PauseFile $script:RnPauseFile
$wwPaused = [bool](Test-WwPaused)
$wwWouldRun = [bool]($tAfterKill -eq 'on' -and -not $wwPaused)
$e = New-SimAdapter 'Ethernet' 12 $false; $script:sim.ads = @($e); Setup-Alias $e
$r = Run-Rn; $h = Res $r
$r2 = Run-Rn; $h2 = Res $r2
Out-Result @{ tAfterKill = $tAfterKill; pLeft = $pLeft; wwPaused = $wwPaused; wwWouldRun = $wwWouldRun; code = $h.code; said = $h.said; order = $h.order; task = $h.task; pause = $h.pause; code2 = $h2.code; said2 = $h2.said; order2 = $h2.order; task2 = $h2.task }
'@ 'r4a'
  # (r4b runs in r4a's folder: same task-state file, same pause file - the PC after the kill)
  $j = Get-Json $o2
  if (-not $j) { Check $false 'R4 drivers ran' ($o1 + "`n" + $o2) } else {
    Check ($o1 -match 'KILLED at online') 'R4 setup: the first run really was killed half-way (during its final online check, before any finally)' $o1
    Check ($j.tAfterKill -eq 'on') 'R4 Codex repro: a run killed half-way does NOT leave the WifiWatch task switched off' ('task after the kill: ' + $j.tAfterKill)
    Check ($j.pLeft -and -not $j.wwPaused -and $j.wwWouldRun) 'R4 Codex repro: once the killed run''s pause file has expired, the real WifiWatch.ps1 ignores it and WifiWatch runs again by itself' ('pause left: ' + $j.pLeft + ', still paused: ' + $j.wwPaused + ', task: ' + $j.tAfterKill)
    Check ($j.code -eq 0 -and $j.task -eq 'on' -and -not $j.pause) 'R4 Codex repro: the fresh run finishes normally with the task ON and no pause file left' ('task: ' + $j.task + "`n" + $j.said)
    Check ((Said-BackOnTrue $j) -and $j.said -match 'WifiWatch is back on') 'R4 Codex repro: "WifiWatch is back on" is said, and it is TRUE (the task''s real state is on)' ('task: ' + $j.task + "`n" + $j.said)
    Check (-not @(@($j.order) + @($j.order2) | Where-Object { $_ -eq 'task:off' }).Count) 'R4 the task is never switched off (2.2.13: the pause is only the expiring pause file)' ((@($j.order) -join ' > '))
    Check ($j.code2 -eq 0 -and $j.task2 -eq 'on' -and $j.said2 -notmatch 'left switched OFF') 'R4 running it twice: the second run is DONE, the task still on, nothing to recover' $j.said2
  }

  # =====================================================================================
  Write-Host '#4: the damage an earlier 2.2.12 run left (task OFF + its old pause file) is repaired; a task switched off by someone else is not'
  $o = Rn-Driver 'r4c' @'
$e = New-SimAdapter 'Ethernet' 12 $false; $script:sim.ads = @($e)
# A: admin run (something to change), task OFF, the old 2.2.12 pause file (expired) still there -> switched back on
Setup-Alias $e; TS-Set 'off'; Write-OldPause; $rA = Run-Rn; $hA = Res $rA
# A2: running it twice: nothing left to recover
Setup-Alias $e; $rA2 = Run-Rn; $hA2 = Res $rA2
# B: crew login, nothing to change (Ethernet fine), same damage -> it cannot switch it on: says so plainly, with the steps
$script:sim.admin = $false; TS-Set 'off'; Write-OldPause; $rB = Run-Rn; $hB = Res $rB
# B2: the same, admin, nothing to change -> switched back on, the old pause file removed
$script:sim.admin = $true; TS-Set 'off'; Write-OldPause; $rB2 = Run-Rn; $hB2 = Res $rB2
# C: wrong owner - the task is OFF but NOT by Restore Network (no pause file): it is not switched on, and "back on" is never said
Setup-Alias $e; TS-Set 'off'; Remove-Item -LiteralPath $script:RnPauseFile -Force -ErrorAction SilentlyContinue; $rC = Run-Rn; $hC = Res $rC
# D: wrong owner - a pause file written by another tool: not taken as Restore Network's
Setup-Alias $e; TS-Set 'off'; Write-OldPause 'Some other tool'; $rD = Run-Rn; $hD = Res $rD
Remove-Item -LiteralPath $script:RnPauseFile -Force -ErrorAction SilentlyContinue
Out-Result @{ A = $hA; A2 = $hA2; B = $hB; B2 = $hB2; C = $hC; D = $hD }
'@
  $j = Get-Json $o
  if (-not $j) { Check $false 'R4c driver ran' $o } else {
    Check ($j.A.code -eq 0 -and $j.A.task -eq 'on' -and $j.A.said -match 'left switched OFF by an earlier Restore Network that was stopped half-way - switched back on' -and -not $j.A.pause) 'L1 the 2.2.12 damage (task OFF + its old pause file): switched back on, said plainly, DONE, no pause file left' ($j.A.task + "`n" + $j.A.said)
    Check ((Said-BackOnTrue $j.A) -and $j.A.said -match 'WifiWatch is back on') 'L1 ...and "WifiWatch is back on" is true' $j.A.said
    Check ($j.A2.code -eq 0 -and $j.A2.task -eq 'on' -and $j.A2.said -notmatch 'left switched OFF' -and -not @($j.A2.order | Where-Object { $_ -match '^task:' }).Count) 'L1 running it twice: nothing more to recover, no task switch at all' (@($j.A2.order) -join ' > ')
    Check ($j.B.task -eq 'off' -and $j.B.said -match 'WifiWatch is OFF - turn it back on: .*Task Scheduler.*WireIt WifiWatch.*Enable \(needs an admin login\)' -and $j.B.said -notmatch 'WifiWatch is back on') 'L2 crew login, nothing to change, task left OFF by 2.2.12: says "WifiWatch is OFF - turn it back on: <steps>" (never "back on")' $j.B.said
    Check ($j.B2.task -eq 'on' -and $j.B2.code -eq 0 -and -not $j.B2.pause -and $j.B2.said -match 'switched back on') 'L3 admin, nothing to change, same damage: switched back on and the old pause file removed' ($j.B2.task + "`n" + $j.B2.said)
    Check ($j.C.task -eq 'off' -and -not @($j.C.order | Where-Object { $_ -eq 'task:on' }).Count -and $j.C.said -notmatch 'WifiWatch is back on' -and $j.C.said -match 'WifiWatch is OFF - turn it back on') 'W1 wrong owner: a task switched off by someone else is NOT switched on, and "back on" is never said; the OFF line with steps is' ((@($j.C.order) -join ' > ') + "`n" + $j.C.said)
    Check ($j.C.code -eq 0 -and ([regex]::Matches($j.C.said, 'WifiWatch is OFF - turn it back on')).Count -ge 2 -and $j.C.said -match '(?s)DONE - network.*WifiWatch is OFF') 'W1 the network itself is fine (DONE, exit 0), and the WifiWatch OFF line is repeated AFTER the last line so the crew sees it' $j.C.said
    Check ($j.D.task -eq 'off' -and -not @($j.D.order | Where-Object { $_ -eq 'task:on' }).Count -and $j.D.said -notmatch 'WifiWatch is back on') 'W2 wrong owner: a pause file written by another tool is not taken as Restore Network''s (not switched on, no "back on")' ((@($j.D.order) -join ' > ') + "`n" + $j.D.said)
  }

  # =====================================================================================
  Write-Host '#4 failing half-way: switching it back on fails / something switches it off during the run / its state cannot be read'
  $o = Rn-Driver 'r4d' @'
$e = New-SimAdapter 'Ethernet' 12 $false; $script:sim.ads = @($e)
# H1: the 2.2.12 damage, and Task Scheduler refuses to switch it on -> FAILED - Run again, OFF said with the steps, never "back on"
Setup-Alias $e; TS-Set 'off'; Write-OldPause; $script:sim.taskFail['on'] = $true; $r1 = Run-Rn; $h1 = Res $r1; $script:sim.taskFail.Remove('on')
# H2: something switches the task off DURING the run (it was on at the start) -> not "back on", FAILED
Remove-Item -LiteralPath $script:RnPauseFile -Force -ErrorAction SilentlyContinue
Setup-Alias $e; TS-Set 'on'; $script:sim.taskOffAt = 'reconnect'; $r2 = Run-Rn; $h2 = Res $r2; $script:sim.taskOffAt = ''
# H3: the final check itself breaks -> the pause file still comes off, the task still on
Setup-Alias $e; TS-Set 'on'; $script:sim.fail['online'] = $true; $r3 = Run-Rn; $h3 = Res $r3; $script:sim.fail.Remove('online')
# H4: the task's state cannot be read at the end (this login may not see it) -> says so, never "back on"
Setup-Alias $e; TS-Set 'on'; $script:sim.taskUnreadable = $true; $r4 = Run-Rn; $h4 = Res $r4; $script:sim.taskUnreadable = $false
# H5: the pause file cannot be written -> never DONE, and the task is not switched off either
Setup-Alias $e; TS-Set 'on'; $script:sim.pauseFail = $true; $r5 = Run-Rn; $h5 = Res $r5; $script:sim.pauseFail = $false
Out-Result @{ H1 = $h1; H2 = $h2; H3 = $h3; H4 = $h4; H5 = $h5 }
'@
  $j = Get-Json $o
  if (-not $j) { Check $false 'R4d driver ran' $o } else {
    Check ($j.H1.code -eq 6 -and $j.H1.said -notmatch '(?m)^DONE' -and $j.H1.said -match 'WifiWatch is OFF - turn it back on' -and $j.H1.said -notmatch 'WifiWatch is back on') 'H1 switching it back on fails: FAILED - Run again, "WifiWatch is OFF - turn it back on" with steps, never "back on"' $j.H1.said
    Check ($j.H2.code -eq 6 -and $j.H2.task -eq 'off' -and $j.H2.said -notmatch 'WifiWatch is back on' -and $j.H2.said -match 'WifiWatch is OFF') 'H2 the task went off DURING the run: read again at the end, not "back on", FAILED' $j.H2.said
    Check ($j.H3.code -ne 0 -and $j.H3.said -notmatch '(?m)^DONE' -and $j.H3.task -eq 'on' -and -not $j.H3.pause) 'H3 the final check breaks half-way: not DONE, the pause file still off (finally), the task still on' $j.H3.said
    Check ($j.H4.said -notmatch 'WifiWatch is back on' -and $j.H4.said -match 'could not read whether its task is on') 'H4 the task''s state cannot be read at the end: says so plainly, never "back on"' $j.H4.said
    Check ($j.H5.code -eq 6 -and $j.H5.said -notmatch '(?m)^DONE' -and $j.H5.task -eq 'on' -and -not @($j.H5.order | Where-Object { $_ -eq 'task:off' }).Count) 'H5 the pause file cannot be written: never DONE, and the task is not switched off' $j.H5.said
  }

  # =====================================================================================
  Write-Host 'DHCP (Codex advice): "Reset chosen adapter to DHCP", the saved settings and plain steps to put the old fixed address back'
  $o = Rn-Driver 'rdh' @'
$e = New-SimAdapter 'Ethernet' 12 $false; $w = New-SimAdapter 'Wi-Fi 2' 7 $true; $script:sim.ads = @($e, $w); $script:sim.task = 'none'
$w.dhcp = $false; Sim-Ext $w '172.16.9.9' 'both'; [void]$w.proutes.Add('172.16.9.1')
$e.dhcp = $false; Sim-Ext $e '10.1.10.2' 'both'; [void]$e.proutes.Add('10.1.10.1'); $e.dnsStatic = $true
$script:Adapter = 'Ethernet'
$script:RnAnswer = 'y'; $rY = Run-Rn
$rcY = @(Get-ChildItem (Join-Path $D 'receipts') -Filter 'RestoreNetwork-*.txt' | Sort-Object LastWriteTime); $rtY = $(if ($rcY.Count) { [IO.File]::ReadAllText($rcY[-1].FullName) } else { '' })
# running it twice: already on DHCP, nothing changes -> no restore steps, no saved-settings line at the end
$rT = Run-Rn
# says no: kept -> nothing reset -> no restore steps
$e.dhcp = $false; $e.active.Clear(); $e.persistent.Clear(); Sim-Ext $e '10.1.10.2' 'both'; [void]$e.proutes.Add('10.1.10.1'); $e.dnsStatic = $true
$script:RnAnswer = 'no'; $rN = Run-Rn
# failing half-way: the crew said Y, one removal fails -> FAILED, and the old values + steps are STILL printed
$e.dhcp = $false; $e.active.Clear(); $e.persistent.Clear(); $e.proutes.Clear(); Sim-Ext $e '10.1.10.2' 'both'; [void]$e.proutes.Add('10.1.10.1'); $e.dnsStatic = $true
$script:RnAnswer = 'y'; $script:sim.fail['removeaddr:PersistentStore'] = $true; $rF = Run-Rn; $script:sim.fail.Remove('removeaddr:PersistentStore')
Out-Result @{ cY = $rY.code; sY = $rY.said; rtY = $rtY; cT = $rT.code; sT = $rT.said; cN = $rN.code; sN = $rN.said; cF = $rF.code; sF = $rF.said }
'@
  $j = Get-Json $o
  if (-not $j) { Check $false 'RDH driver ran' $o } else {
    Check ($j.sY -match 'Reset chosen adapter to DHCP\?' -and $j.sY -match 'This adapter has a fixed address 10\.1\.10\.2') 'D1 the question is labelled "Reset chosen adapter to DHCP?"' $j.sY
    Check ($j.cY -eq 0 -and $j.sY -match '(?s)DONE - network.*Settings from before this run are saved in: \S*RestoreNetwork-\d{8}-\d{6}-before\.json') 'D1 after the reset the end prints where the old settings are saved (receipts\RestoreNetwork-<time>-before.json)' $j.sY
    Check ($j.sY -match 'IP address 10\.1\.10\.2   subnet mask 255\.255\.255\.0' -and $j.sY -match 'Gateway 10\.1\.10\.1' -and $j.sY -match 'DNS 10\.1\.10\.1') 'D1 the OLD fixed values in plain text: address, subnet mask, gateway, DNS' $j.sY
    Check ($j.sY -match 'To put them back \(needs an admin login\): Settings > Network & Internet > Ethernet > IP assignment > Edit > Manual') 'D1 plain steps a crew member can follow, and that it needs an admin login' $j.sY
    Check ($j.rtY -match 'IP address 10\.1\.10\.2' -and $j.rtY -match 'To put them back') 'D1 the receipt carries the old values and the steps too' $j.rtY
    Check ($j.sY -notmatch '172\.16\.9\.') 'D2 wrong adapter: the other adapter''s settings (Wi-Fi 2, 172.16.9.9) are not in the steps' $j.sY
    Check ($j.cT -eq 0 -and $j.sT -notmatch 'To put them back' -and $j.sT -notmatch 'Settings from before this run are saved in:') 'D3 running it twice: nothing changed, so no restore steps are printed' $j.sT
    Check ($j.sN -match 'Kept: the fixed address' -and $j.sN -notmatch 'To put them back' -and $j.sN -notmatch 'Reset chosen adapter to DHCP"\. Its OLD') 'D4 the crew said no: kept, nothing reset, no restore steps' $j.sN
    Check ($j.cF -eq 6 -and $j.sF -match 'FAILED' -and $j.sF -match 'IP address 10\.1\.10\.2' -and $j.sF -match 'To put them back') 'D5 failing half-way after a Y: FAILED, and the old values + steps are still printed' $j.sF
  }

  # =====================================================================================
  Write-Host 'DHCP label where the crew sees it (Toolkit window, Restore Network.cmd, README) and the source of the pause'
  $rnSrc = [IO.File]::ReadAllText($rnFile)
  $wt = [IO.File]::ReadAllText((Join-Path $tk 'WireItToolkit.ps1')); $cmd = [IO.File]::ReadAllText((Join-Path $tk 'Restore Network.cmd')); $rd = [IO.File]::ReadAllText((Join-Path $tk 'README.txt'))
  Check ($wt -match 'Reset chosen adapter to DHCP' -and $cmd -match 'Reset chosen adapter to DHCP' -and $rd -match 'Reset chosen adapter to DHCP') 'D6 "Reset chosen adapter to DHCP" is the label in the Toolkit window, Restore Network.cmd and README.txt'
  $sp = [regex]::Match($rnSrc, '(?s)function Start-RnPause.*?\nfunction ').Value
  Check ($sp -and $sp -notmatch "set = 'off'") 'S1 source: Start-RnPause never switches the task off (only the expiring pause file)' 
  Check ($rnSrc -match "(?s)function Stop-RnPause.*Invoke-RnOp 'task' @\{ set = '' \}.*WifiWatch is back on") 'S2 source: Stop-RnPause reads the task''s real state again before "WifiWatch is back on"'
  $bad = @(); foreach ($f in @($rnFile)) { $b = [IO.File]::ReadAllBytes($f); for ($i = 0; $i -lt $b.Length; $i++) { if ($b[$i] -gt 127) { $bad += $f; break } } }
  Check (-not $bad.Count) 'S3 RestoreNetwork.ps1 is ASCII only' ($bad -join ', ')
  # NEEDS WINDOWS CHECK: real Task Scheduler (Get-ScheduledTask as a standard login -> 'unknown'; Enable-ScheduledTask on a SYSTEM task)
  Deferred 'NEEDS WINDOWS CHECK: real Get-ScheduledTask / Enable-ScheduledTask on "WireIt WifiWatch" (admin and standard login), not simulated here'
} finally {
  try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
Write-Host ('Test-Fix2213Net: ' + $script:pass + ' passed, ' + $script:fail + ' failed' + $(if ($script:deferred) { ', ' + $script:deferred + ' deferred' } else { '' }))
exit $script:fail
