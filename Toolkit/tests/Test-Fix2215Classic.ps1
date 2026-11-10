<# Test-Fix2215Classic.ps1 - behavioural tests for the 2.2.15 fixes of Codex's 2.2.14 review findings R7, R8 and R11.
   R7  WifiWatch switched the Wi-Fi adapter off even when its crash-recovery marker was not saved. 2.2.15: Save-WwMarker writes the
       marker AND reads it back; if that fails the cycle is skipped (adapter never switched off without a marker).
   R8  Toolkit "Go back" (Undo-TkUpdate) swapped files with no journal, so a crash half-way left a mixed old/new Toolkit that startup
       recovery did not see. 2.2.15: a journal (kind = undo) is saved before the first swap; Invoke-TkStartupRecovery (run before the
       main window loads) finishes the go-back and says so; a go-back that could not finish keeps its journal.
   R11 Run-AllTests counted only DEFERRED lines, so Windows-only checks printed as SKIP made their suites PASS. 2.2.15: those checks
       print DEFERRED (Test-Fix226/227/Review225), the runner also counts any SKIP line as deferred, and suites left out by -Portable
       are DEFERRED rows.
   Every check RUNS the real functions (WifiWatch.ps1, ToolkitCore.ps1, ToolkitRecover.ps1, Run-AllTests.ps1) in a child PowerShell;
   only adapter operations (WwOps) and, where a crash is simulated, the file copy are stood in for. No adapter is touched.
   Old-code proof: FIX2215CLASSIC_REPO=<a 2.2.14 checkout> runs the same checks against that code.
   NEEDS WINDOWS CHECK (counted DEFERRED, never PASS): a real Wi-Fi adapter off/on by the SYSTEM task with the marker on C:\, and a
   real power cut during Go back on NTFS. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
if ($env:FIX2215CLASSIC_REPO) { $repo = $env:FIX2215CLASSIC_REPO }   # tests only: point at another checkout (old-code proof)
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2215classic-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { $m = ($more -replace '\s+', ' '); Write-Host ('     ' + $m.Substring(0, [math]::Min(1200, $m.Length))) } }
}
function Deferred([string]$name) { $script:deferred++; Write-Host ('DEFERRED ' + $name + ' (NEEDS WINDOWS CHECK)') }
# runs a script text in a fresh PowerShell; returns @{ code; out; j (the JSON after RESULT=) }
function Invoke-Child([string]$name, [string]$text, [string[]]$extra = @()) {
  $f = Join-Path $tmp ($name + '.ps1'); [IO.File]::WriteAllText($f, $text)
  $out = @(& $exe -NoProfile -ExecutionPolicy Bypass -File $f @extra 2>&1 | ForEach-Object { [string]$_ }); $code = $LASTEXITCODE
  $j = $null; foreach ($l in $out) { if ($l -like 'RESULT=*') { try { $j = $l.Substring(7) | ConvertFrom-Json } catch {} } }
  return @{ code = $code; out = ($out -join "`n"); j = $j }
}
try {
  $RepoQ = $repo.Replace("'", "''")
  # ---------------- R7 WifiWatch marker ----------------
  Write-Host 'R7: WifiWatch never switches Wi-Fi off without a saved, read-back recovery marker'
  $wwHead = @'
param([string]$Dir, [string]$Mode)
. ('REPO' + '/wifiwatch/WifiWatch.ps1') -Dir $Dir -PauseFile (Join-Path $Dir 'pause')
$script:ops = New-Object System.Collections.Generic.List[string]
$script:state = 'on'
$script:WwOps = { param($op, $a) $script:ops.Add($op); if ($op -eq 'disable') { $script:state = 'off' }; if ($op -eq 'enable') { $script:state = 'on' }; if ($op -eq 'isup') { return ($script:state -eq 'on') }; return $true }

'@.Replace('REPO', $RepoQ)
  # a: marker folder is a FILE (cannot be created)
  $d1 = Join-Path $tmp 'ww1'; New-Item -ItemType Directory -Force -Path $d1 | Out-Null; [IO.File]::WriteAllText((Join-Path $d1 'blocker'), 'x')
  $r = Invoke-Child 'ww1' ($wwHead + @'
$marker = Join-Path $Dir 'blocker/adapter-off.txt'
Invoke-WwAdapterCycle 'Wi-Fi' 'Site'
$log = ''; if (Test-Path (Join-Path $Dir 'wifiwatch.log')) { $log = [IO.File]::ReadAllText((Join-Path $Dir 'wifiwatch.log')) }
'RESULT=' + (@{ ops = @($script:ops); state = $script:state; log = $log } | ConvertTo-Json -Compress)
'@) @('-Dir', $d1)
  $ops = @(); if ($r.j) { $ops = @($r.j.ops) }
  Check ($r.j -and ($ops -notcontains 'disable') -and $r.j.state -eq 'on') ('R7-A marker folder cannot be created: the adapter is NOT switched off (ops: ' + ($ops -join ',') + ')') $r.out
  Check ($r.j -and $r.j.log -match 'NOT switched off, cycle skipped') 'R7-A ...and the log says the cycle was skipped because the marker could not be saved' $r.out
  # b: marker path is a folder (Set-Content fails)
  $d2 = Join-Path $tmp 'ww2'; New-Item -ItemType Directory -Force -Path (Join-Path $d2 'adapter-off.txt') | Out-Null
  $r = Invoke-Child 'ww2' ($wwHead + @'
$marker = Join-Path $Dir 'adapter-off.txt'
$ok = Save-WwMarker 'Wi-Fi'
Invoke-WwAdapterCycle 'Wi-Fi' 'Site'
'RESULT=' + (@{ ok = $ok; ops = @($script:ops); state = $script:state } | ConvertTo-Json -Compress)
'@) @('-Dir', $d2)
  $ops = @(); if ($r.j) { $ops = @($r.j.ops) }
  Check ($r.j -and $r.j.ok -eq $false -and ($ops -notcontains 'disable')) 'R7-B marker path is a folder (write fails): Save-WwMarker says no and the adapter is NOT switched off' $r.out
  # c: normal case still works: marker saved + read back, adapter off/on, marker removed after it is on again
  $d3 = Join-Path $tmp 'ww3'; New-Item -ItemType Directory -Force -Path $d3 | Out-Null
  $r = Invoke-Child 'ww3' ($wwHead + @'
$marker = Join-Path $Dir 'adapter-off.txt'
$script:seenMarker = $null
$script:WwOps = { param($op, $a) $script:ops.Add($op); if ($op -eq 'disable') { $script:seenMarker = $(if (Test-Path -LiteralPath $marker) { ([IO.File]::ReadAllText($marker)).Trim() } else { '' }); $script:state = 'off' }; if ($op -eq 'enable') { $script:state = 'on' }; if ($op -eq 'isup') { return ($script:state -eq 'on') }; return $true }
Invoke-WwAdapterCycle 'Wi-Fi' 'Site'
'RESULT=' + (@{ ops = @($script:ops); state = $script:state; seen = $script:seenMarker; left = (Test-Path -LiteralPath $marker) } | ConvertTo-Json -Compress)
'@) @('-Dir', $d3)
  $ops = @(); if ($r.j) { $ops = @($r.j.ops) }
  Check ($r.j -and ($ops -contains 'disable') -and $r.j.seen -eq 'Wi-Fi' -and $r.j.state -eq 'on' -and -not $r.j.left) ('R7-C writable folder: the marker holds "Wi-Fi" at the moment the adapter goes off, the adapter comes back on and the marker is removed (seen "' + $(if ($r.j) { $r.j.seen } else { '?' }) + '")') $r.out
  # d: a crash right after "off" with a saved marker is repaired by the next run
  $d4 = Join-Path $tmp 'ww4'; New-Item -ItemType Directory -Force -Path $d4 | Out-Null; [IO.File]::WriteAllText((Join-Path $d4 'state.txt'), 'on')
  $crash = @'
param([string]$Dir, [string]$Mode)
. ('REPO' + '/wifiwatch/WifiWatch.ps1') -Dir $Dir -PauseFile (Join-Path $Dir 'pause')
$marker = Join-Path $Dir 'adapter-off.txt'
$st = Join-Path $Dir 'state.txt'
$script:WwOps = { param($op, $a) if ($op -eq 'disable') { [IO.File]::WriteAllText($st, 'off'); [Environment]::Exit(9) }; if ($op -eq 'enable') { [IO.File]::WriteAllText($st, 'on') }; if ($op -eq 'isup') { return ([IO.File]::ReadAllText($st) -eq 'on') }; return $true }
if ($Mode -eq 'kill') { Invoke-WwAdapterCycle 'Wi-Fi' 'Site' } else { Repair-WwAdapter; 'RESULT=' + (@{ state = [IO.File]::ReadAllText($st); marker = (Test-Path -LiteralPath $marker) } | ConvertTo-Json -Compress) }
'@.Replace('REPO', $RepoQ)
  $k = Invoke-Child 'ww4k' $crash @('-Dir', $d4, '-Mode', 'kill')
  $r = Invoke-Child 'ww4r' $crash @('-Dir', $d4, '-Mode', 'recover')
  Check ($k.code -eq 9 -and $r.j -and $r.j.state -eq 'on' -and -not $r.j.marker) ('R7-D a run killed right after switching Wi-Fi off (marker saved) is repaired by the next run: adapter on, marker gone (kill exit ' + $k.code + ')') ($k.out + ' | ' + $r.out)
  $src = [IO.File]::ReadAllText((Join-Path $repo 'wifiwatch/WifiWatch.ps1'))
  $cyc = [regex]::Match($src, '(?s)function Invoke-WwAdapterCycle.*?\n}')
  $iSave = $cyc.Value.IndexOf('Save-WwMarker'); $iOff = $cyc.Value.IndexOf("'disable'")
  Check ($cyc.Success -and $iSave -ge 0 -and $iOff -gt $iSave -and $cyc.Value -notmatch 'Set-Content -LiteralPath \$marker') 'R7-E source: in Invoke-WwAdapterCycle the checked Save-WwMarker comes before the first disable, and no unchecked Set-Content of the marker is left'
  Deferred 'R7 a real Wi-Fi adapter switched off/on by the SYSTEM WifiWatch task with the marker under C:\WireIt\WifiWatch'

  # ---------------- R8 Go back journal ----------------
  Write-Host 'R8: Toolkit "Go back" is journaled before its first swap and finished by startup recovery'
  function New-UndoFixture([string]$name) {
    $root = Join-Path $tmp $name; $t = Join-Path $root 'Toolkit'; $p = Join-Path $t 'previous/9.9.8'
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'Toolkit') | Out-Null
    [IO.File]::WriteAllText((Join-Path $t 'a.ps1'), 'new-a'); [IO.File]::WriteAllText((Join-Path $t 'b.ps1'), 'new-b'); [IO.File]::WriteAllText((Join-Path $t 'c.ps1'), 'added-by-9.9.9')
    [IO.File]::WriteAllText((Join-Path $p 'Toolkit/a.ps1'), 'old-a'); [IO.File]::WriteAllText((Join-Path $p 'Toolkit/b.ps1'), 'old-b')
    [IO.File]::WriteAllText((Join-Path $t 'version.json'), '{"version":"9.9.9","previous":"9.9.8"}')
    [IO.File]::WriteAllText((Join-Path $p 'version.json.prev'), '{"version":"9.9.8"}')
    [IO.File]::WriteAllText((Join-Path $p 'undo.json'), '{"added":["Toolkit/c.ps1"]}')
    return $t
  }
  function Read-UndoState([string]$t) {
    $o = [ordered]@{}
    foreach ($n in 'a.ps1', 'b.ps1', 'version.json', 'skip-version.txt') { $f = Join-Path $t $n; $o[$n] = $(if (Test-Path -LiteralPath $f) { ([IO.File]::ReadAllText($f)).Trim() } else { '' }) }
    $o['c'] = (Test-Path -LiteralPath (Join-Path $t 'c.ps1')); $o['journal'] = (Test-Path -LiteralPath (Join-Path $t 'previous/update-pending.json'))
    return [pscustomobject]$o
  }
  $undoChild = @'
param([string]$Tk, [string]$Mode)
. ('REPO' + '/Toolkit/ToolkitCore.ps1')
$jp = Join-Path $Tk 'previous/update-pending.json'
if ($Mode -eq 'crash') {
  function Copy-TkAtomicFile([string]$src, [string]$dst, [string]$hash = '') { $j = $null; if (Test-Path -LiteralPath $jp) { $j = [IO.File]::ReadAllText($jp) }; [IO.File]::WriteAllText(($Tk + '/journal-at-first-swap.txt'), [string]$j); [IO.File]::WriteAllBytes($dst, [IO.File]::ReadAllBytes($src)); [Environment]::Exit(9) }
}
if ($Mode -eq 'locked') {
  $script:realCopy = ${function:Copy-TkAtomicFile}
  function Copy-TkAtomicFile([string]$src, [string]$dst, [string]$hash = '') { if ($dst -like '*b.ps1') { throw 'locked' }; & $script:realCopy $src $dst $hash }
}
$v = ''; $err = ''
try { $v = [string](Undo-TkUpdate $Tk) } catch { $err = $_.Exception.Message }
'RESULT=' + (@{ v = $v; err = $err } | ConvertTo-Json -Compress)
'@.Replace('REPO', $RepoQ)
  $recover = @'
param([string]$Tk)
. ('REPO' + '/Toolkit/ToolkitRecover.ps1')
$n = ''; $err = ''
try { $n = [string](Invoke-TkStartupRecovery $Tk) } catch { $err = $_.Exception.Message }
'RESULT=' + (@{ notice = $n; err = $err } | ConvertTo-Json -Compress)
'@.Replace('REPO', $RepoQ)
  # A: crash after first swap
  $t = New-UndoFixture 'u1'
  $c = Invoke-Child 'u1c' $undoChild @('-Tk', $t, '-Mode', 'crash')
  $js = ''; $jf = Join-Path $t 'journal-at-first-swap.txt'; if (Test-Path -LiteralPath $jf) { $js = [IO.File]::ReadAllText($jf) }
  Check ($c.code -eq 9 -and $js -match '"kind"\s*:\s*"undo"' -and $js -match '9\.9\.8') ('R8-A the Go back journal (kind undo, to 9.9.8) is on disk BEFORE the first file is swapped (child exit ' + $c.code + ')') ($c.out + ' journal: ' + $js)
  $r = Invoke-Child 'u1r' $recover @('-Tk', $t); $s = Read-UndoState $t
  Check ($s.'a.ps1' -eq 'old-a' -and $s.'b.ps1' -eq 'old-b' -and $s.'version.json' -match '9\.9\.8' -and $s.'version.json' -notmatch '9\.9\.9' -and -not $s.c) ('R8-B after a crash half-way, startup recovery FINISHES the go-back: both files old, version.json 9.9.8, the update''s added file removed (' + ($s | ConvertTo-Json -Compress) + ')') $r.out
  Check ($r.j -and $r.j.notice -match 'Go back' -and $r.j.notice -match 'half-way' -and -not $s.journal -and $s.'skip-version.txt' -eq '9.9.9') ('R8-C ...says so in plain words, clears the journal and keeps 9.9.9 from re-installing itself (notice: ' + $(if ($r.j) { $r.j.notice } else { '?' }) + ')') $r.out
  # D: full go-back
  $t = New-UndoFixture 'u2'
  $c = Invoke-Child 'u2c' $undoChild @('-Tk', $t, '-Mode', 'ok'); $s = Read-UndoState $t
  Check ($c.j -and $c.j.v -eq '9.9.8' -and -not $c.j.err -and $s.'a.ps1' -eq 'old-a' -and $s.'b.ps1' -eq 'old-b' -and -not $s.journal -and $s.'skip-version.txt' -eq '9.9.9') ('R8-D a go-back that finishes returns 9.9.8, leaves no journal and writes skip-version (' + ($s | ConvertTo-Json -Compress) + ')') $c.out
  # E: a file that cannot be put back keeps the journal; the next start finishes it
  $t = New-UndoFixture 'u3'
  $c = Invoke-Child 'u3c' $undoChild @('-Tk', $t, '-Mode', 'locked'); $s = Read-UndoState $t
  Check ($c.j -and $c.j.err -match 'did not finish' -and $s.journal -and $s.'version.json' -match '9\.9\.9') ('R8-E a locked file stops the go-back with its name, the version number is not changed and the journal STAYS (err: ' + $(if ($c.j) { $c.j.err } else { '?' }) + ')') $c.out
  $r = Invoke-Child 'u3r' $recover @('-Tk', $t); $s = Read-UndoState $t
  Check ($s.'a.ps1' -eq 'old-a' -and $s.'b.ps1' -eq 'old-b' -and $s.'version.json' -match '9\.9\.8' -and -not $s.journal) '...and the next start of the Toolkit finishes it (no mixed version left)' $r.out
  # F: a second Go back while a journal is waiting refuses and changes nothing
  $t = New-UndoFixture 'u4'
  [IO.File]::WriteAllText((Join-Path $t 'previous/update-pending.json'), ('{"kind":"undo","prev":"' + ((Join-Path $t 'previous/9.9.8') -replace '\\', '\\') + '","from":"9.9.9","to":"9.9.8","added":[]}'))
  $c = Invoke-Child 'u4c' $undoChild @('-Tk', $t, '-Mode', 'ok'); $s = Read-UndoState $t
  Check ($c.j -and $c.j.err -match 'half-way' -and $s.'a.ps1' -eq 'new-a' -and $s.'b.ps1' -eq 'new-b') 'R8-F Go back while an earlier update/Go back is still half-way refuses and changes nothing' $c.out
  # G: an update's journal (no kind) still gets the update message (no regression)
  $t = New-UndoFixture 'u5'
  [IO.File]::WriteAllText((Join-Path $t 'previous/update-pending.json'), ('{"prev":"' + ((Join-Path $t 'previous/9.9.8') -replace '\\', '\\') + '","from":"9.9.8","to":"9.9.9","added":["Toolkit/c.ps1"]}'))
  $r = Invoke-Child 'u5r' $recover @('-Tk', $t); $s = Read-UndoState $t
  Check ($r.j -and $r.j.notice -match 'An earlier update to 9\.9\.9 stopped half-way' -and $s.'a.ps1' -eq 'old-a' -and -not $s.journal) 'R8-G an interrupted UPDATE is still put back the same way as before (old message)' $r.out
  $ui = [IO.File]::ReadAllText((Join-Path $repo 'Toolkit/WireItToolkit.ps1'))
  $iRec = $ui.IndexOf('Invoke-TkStartupRecovery $here'); $iCore = $ui.IndexOf("'ToolkitCore.ps1')")
  Check ($iRec -gt 0 -and $iCore -gt $iRec) 'R8-H source: the Toolkit window runs startup recovery before it loads ToolkitCore / the main window'
  Deferred 'R8 a real power cut during Go back on NTFS, then the Toolkit opened again'

  # ---------------- R11 SKIP is DEFERRED ----------------
  Write-Host 'R11: a check that did not run here is DEFERRED, never PASS'
  $rat = Join-Path $repo 'tools/Run-AllTests.ps1'
  $ratSrc = [IO.File]::ReadAllText($rat)
  $ast = [Management.Automation.Language.Parser]::ParseFile($rat, [ref]$null, [ref]$null)
  $fnText = (@($ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in @('Get-SuiteCounts', 'Get-SuiteResult') }, $true)) | ForEach-Object { $_.Extent.Text }) -join "`n"
  $r = Invoke-Child 'r11' ($fnText + "`n" + @'
$a = Get-SuiteCounts @('PASS x', 'SKIP F14 real HikReset run with a DPAPI password store (Windows only)', 'Test-Fix227: 41 passed, 0 failed')
$b = Get-SuiteCounts @('PASS x', 'SKIP a', 'DEFERRED b', '3 passed, 0 failed')
$c = Get-SuiteCounts @('PASS x', '3 passed, 0 failed')
'RESULT=' + (@{ a = $a.deferred; ar = (Get-SuiteResult 0 $a); b = $b.deferred; c = $c.deferred; cr = (Get-SuiteResult 0 $c) } | ConvertTo-Json -Compress)
'@)
  Check ($r.j -and $r.j.a -eq 1 -and $r.j.ar -eq 'DEFERRED') ('R11-A a suite that exits 0 but printed a SKIP line is DEFERRED, not PASS (deferred ' + $(if ($r.j) { $r.j.a } else { '?' }) + ', ' + $(if ($r.j) { $r.j.ar } else { '?' }) + ')') $r.out
  Check ($r.j -and $r.j.b -eq 2 -and $r.j.c -eq 0 -and $r.j.cr -eq 'PASS') 'R11-B SKIP and DEFERRED lines both count; a suite with neither is still PASS' $r.out
  $skips = @()
  foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $repo 'Toolkit/tests') -Filter 'Test-*.ps1' -File)) {
    $ln = 0; foreach ($l in [IO.File]::ReadAllLines($f.FullName)) { $ln++; $code = ($l -replace '#.*$', ''); if ($code -match "Write-Host\s*\(?\s*['""]SKIP ") { $skips += ($f.Name + ':' + $ln) } }
  }
  Check ($skips.Count -eq 0) ('R11-C no test suite prints a SKIP line any more: Windows-only checks print DEFERRED (' + ($skips -join ', ') + ')')
  $sum = @()
  foreach ($n in 'Test-Fix226.ps1', 'Test-Fix227.ps1', 'Test-Review225.ps1') { $t = [IO.File]::ReadAllText((Join-Path $repo ('Toolkit/tests/' + $n))); if ($t -notmatch "failed, ' \+ \`$script:defer \+ ' deferred") { $sum += $n } }
  Check ($sum.Count -eq 0) ('R11-D Test-Fix226, Test-Fix227 and Test-Review225 print their deferred count in the summary line (' + ($sum -join ', ') + ')')
  Check ($ratSrc -match "not run here" -and $ratSrc -match "result = 'DEFERRED'; passed = 0; failed = 0; deferred = 1") 'R11-E suites left out by -Portable are DEFERRED rows in the runner''s table and count in its exit code'
  $missing = @(); foreach ($n in 'Test-Repro2214.ps1', 'Test-Fix2215Nvr.ps1', 'Test-Fix2215Classic.ps1', 'Test-Fix2215Site.ps1') { if ($ratSrc -notmatch [regex]::Escape($n)) { $missing += $n } }
  Check ($missing.Count -eq 0) ('the 2.2.15 suites and the reviewer reproductions are in Run-AllTests (' + ($missing -join ', ') + ')')
  $rd = Join-Path $repo 'Toolkit/tests/repro-2.2.14'
  $want = @('reproduce-multichannel-unread.py', 'reproduce-undo-wrong-device.py', 'reproduce-channel-guard.ps1', 'reproduce-reset-unread.ps1', 'reproduce-readd-hostname.ps1', 'reproduce-recording.ps1', 'reproduce-firmware-response-lost.ps1', 'reproduce-wifiwatch-marker.ps1', 'reproduce-update-undo-interruption.ps1')
  $miss = @($want | Where-Object { -not (Test-Path -LiteralPath (Join-Path $rd $_)) })
  Check ($miss.Count -eq 0) ('the reviewer''s 9 reproductions of the 2.2.14 review are committed under Toolkit\tests\repro-2.2.14 (' + ($miss -join ', ') + ')')
  $vj = Get-Content -Raw (Join-Path $repo 'version.json') | ConvertFrom-Json
  $tcv = [regex]::Match([IO.File]::ReadAllText((Join-Path $repo 'Toolkit/ToolkitCore.ps1')), "TkBuiltVersion = '([^']+)'").Groups[1].Value
  Check ($tcv -eq '2.2.15' -and [string]$vj.version -eq '2.2.15') ('version 2.2.15 in ToolkitCore and version.json (' + $tcv + ', ' + $vj.version + ')')
}
finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
Write-Host ''
Write-Host ('Test-Fix2215Classic: ' + $script:pass + ' passed, ' + $script:fail + ' failed' + $(if ($script:deferred) { ', ' + $script:deferred + ' deferred' } else { '' }))
if ($script:fail) { exit 1 } else { exit 0 }
