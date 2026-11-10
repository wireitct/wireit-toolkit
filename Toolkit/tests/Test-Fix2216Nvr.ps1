<# Test-Fix2216Nvr.ps1 - tests for WireIt Toolkit 2.2.16 (Nov 10 2026), the NvrFix / Check this site part of Codex's NO-GO review of
   2.2.15 (head 57c7fc9): F5 the recording fix forgot cameras whose settings were unknown (or on) before the change once they were
   missing from the read-back (Hikvision and DW) and still said "Recording is ON again" with a success history line; F6 a recorder
   still filling toward its days-to-keep target gave a green "CHECK THIS SITE: all OK." headline (and exit code 0 "All good").
   Codex's reproduce-recording-disappears.ps1, reproduce-dw-disappears.ps1 and reproduce-pending-headline.ps1 run as permanent
   checks in tests/repro-2.2.15/; this suite covers the same findings plus the controls, failing half-way and running twice.
   Every check RUNS the real functions (Invoke-NvrFix, New-TkSiteCheck, Get-TkNvrPlainEnd, and Show-SiteCheck / End-Run taken
   from WireItToolkit.ps1 by their AST) with stand-ins for the device's web answers and the window. No real device is touched,
   so real-device and real-window behaviour is DEFERRED (never a pass). PS 5.1 or pwsh 7.
   FIX2216NVR_REPO (tests only) = run against another checkout (old-code proof). #>
$ErrorActionPreference = 'Stop'
$repo = $(if ($env:FIX2216NVR_REPO) { $env:FIX2216NVR_REPO } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) })
$tkDir = Join-Path $repo 'Toolkit'
$nhMod = Join-Path $tkDir 'modules/NvrHealth/NvrHealth.psm1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2216nvr-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + $more) } }
}
function Deferred([string]$name) { $script:deferred++; Write-Host ('DEFERRED ' + $name) }
foreach ($f in @($nhMod, (Join-Path $tkDir 'modules/NvrHealth/NvrFix.ps1'), (Join-Path $tkDir 'ToolkitCore.ps1'), (Join-Path $tkDir 'WireItToolkit.ps1'), (Join-Path $tkDir 'NvrCheck.ps1'))) {
  $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$e); Check ($e.Count -eq 0) ('parses: ' + (Split-Path -Leaf $f)) ($e | Out-String)
}
$cred = New-Object PSCredential('admin', (ConvertTo-SecureString 'Review123' -AsPlainText -Force))
$script:n = 0
function InMod([scriptblock]$body, [object[]]$args2) {
  $script:n++
  $m = Import-Module $nhMod -Force -PassThru -DisableNameChecking
  try {
    & $m { param($ld) Set-NvrHealthOption LogDir $ld } (Join-Path $tmp ('logs' + $script:n))
    return (& $m $body @args2)
  } finally { Remove-Module $m -Force -ErrorAction SilentlyContinue }
}

try {
# ==============================================================================================================================
Write-Host 'F5 Hikvision: the recording fix keeps the FIRST track list through its read-back'
# camera 1 (track 101) is switched off. Camera 2 (track 201) is, before the change: unknown (enabled, no schedule) or on.
# After the change the read-back is what the mode says. Returns the fix result plus how many writes went out.
$hik = {
  param($cred, [string]$mode, [string]$dir, [int]$runs = 1)
  $script:Mode = $mode; $script:Writes = 0; $script:Put1 = $false
  function script:Http {
    param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '')
    if ($Method -eq 'PUT') {
      $script:Writes++
      if ($script:Mode -eq 'put-refused') { return @{ code = 403; body = '<ResponseStatus><statusCode>4</statusCode></ResponseStatus>' } }
      $script:Put1 = $true; return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' }
    }
    $on = '<Enable>true</Enable><TrackSchedule><Record>true</Record></TrackSchedule>'
    $one = '<Track><id>101</id>' + $(if ($script:Put1) { $on } else { '<Enable>false</Enable><TrackSchedule><Record>true</Record></TrackSchedule>' }) + '</Track>'
    $twoUnknown = '<Track><id>201</id><Enable>true</Enable></Track>'
    $twoOn = '<Track><id>201</id>' + $on + '</Track>'
    $twoOff = '<Track><id>201</id><Enable>false</Enable><TrackSchedule><Record>true</Record></TrackSchedule></Track>'
    if ($Path -eq '/ISAPI/ContentMgmt/record/tracks') {
      if (-not $script:Put1 -and $script:Mode -ne 'put-refused') {
        $two = $(if ($script:Mode -in @('gone-unknown', 'still-unknown')) { $twoUnknown } else { $twoOn })
        return @{ code = 200; body = ('<TrackList>' + $one + $two + '</TrackList>') }
      }
      $b = switch ($script:Mode) {
        'gone-unknown' { $one }
        'gone-known' { $one }
        'still-unknown' { $one + $twoUnknown }
        'became-off' { $one + $twoOff }
        'new-unknown' { $one + $twoOn + '<Track><id>301</id><Enable>true</Enable></Track>' }
        'put-refused' { $one + $twoOn }
        'readback-fails' { $null }
        default { $one + $twoOn }
      }
      if ($null -eq $b) { return @{ code = 500; body = '' } }
      return @{ code = 200; body = ('<TrackList>' + $b + '</TrackList>') }
    }
    if ($Path -eq '/ISAPI/ContentMgmt/record/tracks/101') { return @{ code = 200; body = $one } }
    return @{ code = 404; body = '' }
  }
  $out = @()
  for ($i = 0; $i -lt $runs; $i++) {
    $w0 = $script:Writes
    $r = Invoke-NvrFix -Fix recording -Ip 10.0.0.20 -Vendor Hikvision -Credential $cred -Confirm { 'YES' } -BackupDir (Join-Path $dir ('hik-' + $mode + '-' + $i)) 6>$null
    $out += [pscustomobject]@{ ok = [bool]$r.ok; ran = [bool]$r.ran; writes = ($script:Writes - $w0); changed = (@($r.changed) -join ', '); msg = [string]$r.msg; history = [string]$r.history }
  }
  return $out
}
$notGreen = { param($r) (-not $r.ok -and $r.msg -notmatch '^Recording is ON again' -and $r.history -notmatch '^Recording turned back on:' -and $r.history -match 'NOT confirmed') }
$r = @(InMod $hik @($cred, 'gone-unknown', $tmp))[0]
Check ($r.writes -eq 1 -and $r.changed -eq 'camera 1') 'Codex F5 (Hik): camera 1 (switched off) is turned on with one write' ('writes=' + $r.writes + ' changed=' + $r.changed)
Check (& $notGreen $r) 'Codex F5 (Hik): camera 2 (unknown before) missing from the read-back -> NOT ok, no "Recording is ON again", history says NOT confirmed (2.2.15: ok, all-clear)' ($r.msg + ' | ' + $r.history)
Check ($r.msg -match 'Camera\(s\) 2 ' -and $r.msg -match 'NOT in the answer read back' -and $r.msg -match 'NOT CHECKED') 'Codex F5 (Hik): the result names camera 2 as missing from the read-back, NOT CHECKED' $r.msg
$r = @(InMod $hik @($cred, 'gone-known', $tmp))[0]
Check ((& $notGreen $r) -and $r.msg -match 'Camera\(s\) 2 ') 'Hik: camera 2 that was ON before but is missing from the read-back -> NOT CHECKED, not green (the first list is kept, not just the unknown ones)' $r.msg
$r = @(InMod $hik @($cred, 'still-unknown', $tmp))[0]
Check ((& $notGreen $r) -and $r.msg -match 'could NOT be checked for camera\(s\) 2') 'Hik: camera 2 still unknown in the read-back -> NOT ok, names camera 2, no "ON again" all-clear (2.2.15: "Recording is ON again" + NOT CHECKED)' $r.msg
$r = @(InMod $hik @($cred, 'became-off', $tmp))[0]
Check ((& $notGreen $r) -and $r.msg -match '^Still off after the change: 1 \(camera 2\)') 'Hik: camera 2 was on before and reads OFF after the change -> "Still off" names it, not green (2.2.15: ok)' $r.msg
$r = @(InMod $hik @($cred, 'new-unknown', $tmp))[0]
Check ((& $notGreen $r) -and $r.msg -match 'camera\(s\) 3') 'Hik: a camera that shows up unknown only in the read-back still keeps it NOT confirmed' $r.msg
$r = @(InMod $hik @($cred, 'put-refused', $tmp))[0]
Check (-not $r.ok -and $r.msg -match '^Still off after the change: 1 \(camera 1\)' -and $r.history -match 'NOT confirmed') 'failing half-way: the recorder refuses the write -> still off, named, NOT confirmed history' ($r.msg + ' | ' + $r.history)
$r = @(InMod $hik @($cred, 'readback-fails', $tmp))[0]
Check (-not $r.ok -and $r.msg -match 'NOT confirmed' -and $r.history -match 'NOT confirmed') 'failing half-way: the read-back fails -> NOT confirmed (unchanged rule)' $r.msg
$rr = @(InMod $hik @($cred, 'all-on', $tmp, 2))
Check ($rr[0].ok -and $rr[0].writes -eq 1 -and $rr[0].msg -match '^Recording is ON again for: camera 1\.' -and $rr[0].history -match '^Recording turned back on: camera 1') 'control: every camera of the first list is back and on -> "Recording is ON again" + success history' ($rr[0].msg + ' | ' + $rr[0].history)
Check ($rr.Count -eq 2 -and $rr[1].ok -and $rr[1].writes -eq 0 -and $rr[1].msg -match 'already on') 'running twice: the second run writes nothing and says recording is already on' $(if ($rr.Count -eq 2) { $rr[1].msg } else { 'one run only' })

# ==============================================================================================================================
Write-Host 'F5 DW: the recording fix keeps the FIRST camera list through its read-back'
$dw = {
  param($cred, [string]$mode, [string]$dir, [int]$runs = 1)
  $script:Mode = $mode; $script:Writes = 0; $script:Put1 = $false
  function script:Dw-Login { return $true }
  function script:Dw-Send { $script:Writes++; if ($script:Mode -eq 'put-refused') { return @{ code = 403; body = '{}' } }; $script:Put1 = $true; return @{ code = 200; body = '{}' } }
  function script:Http {
    param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '')
    if ($Path -like '/rest/v3/devices*') {
      $one = '{"id":"c1","name":"One","url":"http://10.0.0.41","schedule":{"isEnabled":' + $(if ($script:Put1) { 'true' } else { 'false' }) + '}}'
      $twoUnknown = '{"id":"c2","name":"Two","url":"http://10.0.0.42","schedule":{}}'
      $twoOn = '{"id":"c2","name":"Two","url":"http://10.0.0.42","schedule":{"isEnabled":true}}'
      $twoOff = '{"id":"c2","name":"Two","url":"http://10.0.0.42","schedule":{"isEnabled":false}}'
      if (-not $script:Put1 -and $script:Mode -ne 'put-refused') { $b = @($one, $(if ($script:Mode -in @('gone-unknown', 'still-unknown')) { $twoUnknown } else { $twoOn })) }
      else {
        $b = switch ($script:Mode) { 'gone-unknown' { @($one) } 'gone-known' { @($one) } 'still-unknown' { @($one, $twoUnknown) } 'became-off' { @($one, $twoOff) } 'readback-fails' { $null } default { @($one, $twoOn) } }
      }
      if ($null -eq $b) { return @{ code = 500; body = '' } }
      return @{ code = 200; body = ('[' + ($b -join ',') + ']') }
    }
    return @{ code = 404; body = '' }
  }
  $out = @()
  for ($i = 0; $i -lt $runs; $i++) {
    $w0 = $script:Writes
    $r = Invoke-NvrFix -Fix recording -Ip 10.0.0.20 -Vendor DW -Credential $cred -Confirm { 'YES' } -BackupDir (Join-Path $dir ('dw-' + $mode + '-' + $i)) 6>$null
    $out += [pscustomobject]@{ ok = [bool]$r.ok; ran = [bool]$r.ran; writes = ($script:Writes - $w0); changed = (@($r.changed) -join ', '); msg = [string]$r.msg; history = [string]$r.history }
  }
  return $out
}
$r = @(InMod $dw @($cred, 'gone-unknown', $tmp))[0]
Check ($r.writes -eq 1 -and $r.changed -eq 'One') 'Codex F5 (DW): camera One (recording off) is turned on with one write' ('writes=' + $r.writes + ' changed=' + $r.changed)
Check ((& $notGreen $r) -and $r.msg -match 'Two \(10\.0\.0\.42\) - in DW''s camera list before the change but NOT in the list read back') 'Codex F5 (DW): camera Two (unknown before) missing from the read-back -> NOT green, named, history NOT confirmed (2.2.15: green)' ($r.msg + ' | ' + $r.history)
$r = @(InMod $dw @($cred, 'gone-known', $tmp))[0]
Check ((& $notGreen $r) -and $r.msg -match 'Two \(10\.0\.0\.42\)') 'DW: camera Two that was ON before but is missing from the read-back -> NOT CHECKED, not green' $r.msg
$r = @(InMod $dw @($cred, 'still-unknown', $tmp))[0]
Check ((& $notGreen $r) -and $r.msg -match 'could NOT be checked for: Two') 'DW: camera Two still unknown in the read-back -> NOT ok, no "ON again" all-clear' $r.msg
$r = @(InMod $dw @($cred, 'became-off', $tmp))[0]
Check ((& $notGreen $r) -and $r.msg -match '^Still off after the change: 1 \(Two \(10\.0\.0\.42\)\)') 'DW: camera Two was on before and reads OFF after the change -> "Still off" names it' $r.msg
$r = @(InMod $dw @($cred, 'put-refused', $tmp))[0]
Check (-not $r.ok -and $r.msg -match '^Still off after the change: 1 \(One' -and $r.history -match 'NOT confirmed') 'failing half-way (DW): the change is refused -> still off, named, NOT confirmed history' ($r.msg + ' | ' + $r.history)
$r = @(InMod $dw @($cred, 'readback-fails', $tmp))[0]
Check (-not $r.ok -and $r.msg -match 'NOT confirmed') 'failing half-way (DW): the read-back fails -> NOT confirmed (unchanged rule)' $r.msg
$rr = @(InMod $dw @($cred, 'all-on', $tmp, 2))
Check ($rr[0].ok -and $rr[0].msg -match '^Recording is ON again for: One\.' -and $rr[0].history -match '^Recording turned back on: One') 'control (DW): every camera of the first list is back and on -> "Recording is ON again" + success history' ($rr[0].msg + ' | ' + $rr[0].history)
Check ($rr.Count -eq 2 -and $rr[1].ok -and $rr[1].writes -eq 0 -and $rr[1].msg -match 'already on') 'running twice (DW): the second run writes nothing and says recording is already on' $(if ($rr.Count -eq 2) { $rr[1].msg } else { 'one run only' })
Deferred 'F5 a real Hikvision NVR / DW server answering a partial track / camera list after a recording change: stand-ins only - NEEDS A REAL-DEVICE CHECK'

# ==============================================================================================================================
Write-Host 'F6 Check this site: a recorder still filling toward its target is PENDING (amber), never "all OK"'
. (Join-Path $tkDir 'ToolkitCore.ps1')
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $tkDir 'WireItToolkit.ps1'), [ref]$null, [ref]$null)
foreach ($fn in @('Show-SiteCheck', 'End-Run')) {
  $fd = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -eq $fn }, $true)
  Invoke-Expression $fd.Extent.Text
}
$TK = @{ P = @{ Toolkit = $tmp; Logs = $tmp } }; $cOk = 'green'; $cWarn = 'amber'; $cRed = 'red'
$script:Top = @(); $script:Pill = $null
function Read-TkJson { return $script:check }
function Add-OutTop($lines, $colour) { $script:Top += [pscustomobject]@{ text = (@($lines) -join ' | '); colour = $colour } }
function Show-Fixes {}
function Add-Out { }
function Set-Pill($t, $c) { $script:Pill = [pscustomobject]@{ text = $t; colour = $c } }
function Write-TkLog { return '' }
function Set-Busy { }
function Set-Status { }
$scanOk = [pscustomobject]@{ answer = @{ ok = $true; total = 2; missing = @(); stillMissing = @(); added = @(); changedIp = @() } }
$scanMiss = [pscustomobject]@{ answer = @{ ok = $true; total = 2; missing = @('Lobby'); stillMissing = @(); added = @(); changedIp = @() } }
$mk = { param($days, $pending, [bool]$clockOk = $true)
  $rec = [pscustomobject]@{ ok = (-not $pending); target_pending = $pending; problems = @(); recording = 2; days_held = $days; target_days = 30; channels = @([pscustomobject]@{ ch = 1; online = $true; scheduled = $true; recording_now = $true }, [pscustomobject]@{ ch = 2; online = $true; scheduled = $true; recording_now = $true }) }
  $clk = $(if ($clockOk) { @{ ok = $true; problems = @() } } else { @{ ok = $false; problems = @('clock not checked (no answer)') } })
  [pscustomobject]@{ vendor = 'Hikvision'; recording = $rec; clock = $clk; firmware = @{ ok = $true; problems = @(); devices = @() } } }
$show = { param($c) $script:check = $c; $script:Top = @(); Show-SiteCheck; return @($script:Top) }
$c = New-TkSiteCheck (& $mk 5 $true) $scanOk $null
$top = & $show $c
Check (-not $c.ok -and -not $c.page.ok) 'Codex F6: 5 of 30 days, everything healthy -> the overall check and the site-page card are NOT ok (2.2.15: ok)' ('ok=' + $c.ok + ' page.ok=' + $c.page.ok)
Check ($c.PSObject.Properties['pending'] -and $c.pending -and $c.page.pending -and [string]$c.pendingWhy -match '5 of 30') 'still filling is a PENDING state with its reason (check + site-page card)' $(if ($c.PSObject.Properties['pending']) { [string]$c.pendingWhy } else { 'no pending field' })
Check (-not @($c.lines | Where-Object { $_.k -eq 'red' }).Count -and -not @($c.page.notChecked).Count -and -not @($c.fixes).Count -and -not @($c.page.rec.problems).Count) 'still filling is NOT a fault: no red line, no NOT CHECKED part, no problem, no fix button'
Check ($top.Count -eq 1 -and $top[0].colour -eq 'amber' -and $top[0].text -notmatch '(?i)all OK' -and $top[0].text -match '(?i)still filling \(5 of 30 days\), nothing broken found') 'Codex F6: the headline is amber "recorder still filling (5 of 30 days), nothing broken found", not green "all OK"' (@($top | ForEach-Object { $_.text + ' [' + $_.colour + ']' }) -join ' / ')
$old = $c | ConvertTo-Json -Depth 8 | ConvertFrom-Json; $old.ok = $true; $old.PSObject.Properties.Remove('pending'); $old.PSObject.Properties.Remove('pendingWhy')
$top = & $show $old
Check ($top.Count -eq 1 -and $top[0].colour -eq 'amber' -and $top[0].text -notmatch '(?i)all OK') 'a check saved by 2.2.15 (ok=true, page.rec.stillFilling) is not shown as green "all OK" after the update' (@($top | ForEach-Object { $_.text + ' [' + $_.colour + ']' }) -join ' / ')
$c = New-TkSiteCheck (& $mk 5 $true) $scanMiss $null
$top = & $show $c
Check (-not $c.ok -and $top.Count -eq 1 -and $top[0].colour -eq 'red' -and $top[0].text -match 'MISSING') 'still filling AND a missing camera -> red "needs attention" (the fault wins)' (@($top | ForEach-Object { $_.text + ' [' + $_.colour + ']' }) -join ' / ')
$c = New-TkSiteCheck (& $mk 5 $true $false) $scanOk $null
$top = & $show $c
Check (-not $c.ok -and $top.Count -eq 1 -and $top[0].colour -eq 'amber' -and $top[0].text -match 'NOT everything could be checked' -and $top[0].text -match '(?i)still filling') 'still filling AND an unreadable clock -> amber NOT CHECKED headline that also says still filling' (@($top | ForEach-Object { $_.text + ' [' + $_.colour + ']' }) -join ' / ')
$c = New-TkSiteCheck (& $mk 30 $false) $scanOk $null
$top = & $show $c
Check ($c.ok -and -not $c.pending -and $top.Count -eq 1 -and $top[0].colour -eq 'green' -and $top[0].text -eq 'CHECK THIS SITE: all OK.') 'control: 30 of 30 days, everything healthy -> green "all OK"' (@($top | ForEach-Object { $_.text + ' [' + $_.colour + ']' }) -join ' / ')
# the end of the tool window: exit code 3 = still filling (amber pill, not "All good", not "problem")
$pe = Get-TkNvrPlainEnd 'Check this site' 3
Check ($pe -match 'STILL FILLING' -and $pe -match 'NOT an all-clear' -and $pe -notmatch '(?i)all good|stopped with a problem') 'exit code 3 ends with "still filling, NOT an all-clear" (2.2.15: "stopped with a problem (code 3)")' $pe
$TK.run = [pscustomobject]@{ Name = 'Check this site'; Log = (New-Object Text.StringBuilder); OnDone = $null }
End-Run 3 $pe
Check ($script:Pill -and $script:Pill.colour -eq 'amber' -and $script:Pill.text -match '(?i)still filling') 'exit code 3 gives an amber "still filling" status pill (not green, not red "problem")' $(if ($script:Pill) { $script:Pill.text + ' [' + $script:Pill.colour + ']' } else { 'no pill' })
$TK.run = [pscustomobject]@{ Name = 'Check this site'; Log = (New-Object Text.StringBuilder); OnDone = $null }
End-Run 0 'x'
Check ($script:Pill.colour -eq 'green') 'control: exit code 0 is still the green pill'
# NvrCheck.ps1 (the tool window) - its exit code decides the end text; read from the code, it needs the Windows window to run
$ncCode = [IO.File]::ReadAllText((Join-Path $tkDir 'NvrCheck.ps1'))
Check ($ncCode -match '\$chk\.pending[^\r\n]*\$code = 3[^\r\n]*else \{ \$code = 4 \}') 'NvrCheck Site: only "still filling" left -> exit 3, anything else not ok -> exit 4 (source)'
Check ($ncCode -match "target_pending[^\r\n]*\`$code = 3") 'NvrCheck Recording: still filling with no problem -> exit 3, never 0 (source)'
Deferred 'F6 the real Toolkit window (WinForms headline colour, status pill) and the NvrCheck console exit code on Windows PowerShell 5.1: stand-ins only - NEEDS A WINDOWS CHECK'
Deferred 'F6 the site page (op toolkitCheck) showing a card with ok=false + pending=true as amber "still filling": server side not in this repo - NEEDS A CHECK ON THE SITE PAGE'
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ''
Write-Host ('Test-Fix2216Nvr: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:deferred + ' deferred')
if ($script:fail) { exit 1 }
exit 0
