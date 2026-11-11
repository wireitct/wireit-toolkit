<# Test-Fix2216Classic.ps1 - behavioural tests for the 2.2.16 fixes of Codex's 2.2.15 review findings F2 and F7, the R11 note,
   and the Crew-is-a-standard-user correction.
   F2  An interrupted Go back could swap in the older version's ToolkitRecover.ps1 before the "do not re-install" marker was saved; the
       next start ran the OLD loader, which restored the files but did not know kind = undo / skip, so the release being left was
       offered for automatic re-install. 2.2.16: Undo-TkUpdate saves skip-version.txt (temp file + move + read back) BEFORE the journal
       and before any swap; the loader is swapped LAST; the journal keeps from/to in the old update meaning (from = version put back)
       plus back/left; the new loader also saves the marker before it puts any file back. (The reviewer's installed-loader repro is
       tests\repro-2.2.15\reproduce-rollback-bootstrap.ps1.)
   F7  fake_sadp.py answered before publishing its state and truncated the state file first. 2.2.16: atomic write before the answer,
       reader retries, Test-HikReset stops every child it started in its finally. (Repro: reproduce-sadp-state-race.py.)
   R11 note: Run-AllTests printed "SKIP Windows-only suite"; now DEFERRED. A suite that aborts before its summary counts as 1 failed check.
   Crew: FixSiteWindow / installer comments said "Crew is a local admin"; Crew is a STANDARD user. Behaviour unchanged (RunAs);
       the assumption is stated and the window tells a standard-user login that Windows will ask for an administrator.
   Old-code proof: FIX2216CLASSIC_REPO=<a 2.2.15 checkout> runs the same checks against that code.
   NEEDS WINDOWS CHECK (counted DEFERRED, never PASS): a real power cut during Go back on NTFS; the real standard Crew login
   (RunAs credential prompt, which account the blue window runs as, access to site files / vault / run folder). #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
if ($env:FIX2216CLASSIC_REPO) { $repo = $env:FIX2216CLASSIC_REPO }
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2216classic-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { $m = ($more -replace '\s+', ' '); Write-Host ('     ' + $m.Substring(0, [math]::Min(1200, $m.Length))) } }
}
function Deferred([string]$name) { $script:deferred++; Write-Host ('DEFERRED ' + $name + ' (NEEDS WINDOWS CHECK)') }
function Invoke-Child([string]$name, [string]$text, [string[]]$extra = @()) {
  $f = Join-Path $tmp ($name + '.ps1'); [IO.File]::WriteAllText($f, $text)
  $out = @(& $exe -NoProfile -ExecutionPolicy Bypass -File $f @extra 2>&1 | ForEach-Object { [string]$_ }); $code = $LASTEXITCODE
  $j = $null; foreach ($l in $out) { if ($l -like 'RESULT=*') { try { $j = $l.Substring(7) | ConvertFrom-Json } catch {} } }
  return @{ code = $code; out = ($out -join "`n"); j = $j }
}
function Get-FnText([string]$file, [string]$name) {
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
  $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
  if ($fn) { return $fn.Extent.Text } ; return ''
}
try {
  $RepoQ = $repo.Replace("'", "''")
  Write-Host 'F2: the "do not re-install" marker is durable before a Go back swaps anything, and survives the old loader'
  function New-UndoFixture([string]$name, [switch]$WithLoader) {
    $root = Join-Path $tmp $name; $t = Join-Path $root 'Toolkit'; $p = Join-Path $t 'previous/9.9.8'
    New-Item -ItemType Directory -Force -Path (Join-Path $p 'Toolkit') | Out-Null
    foreach ($n in 'a', 'b') { [IO.File]::WriteAllText((Join-Path $t ($n + '.ps1')), ('new-' + $n)); [IO.File]::WriteAllText((Join-Path $p ('Toolkit/' + $n + '.ps1')), ('old-' + $n)) }
    if ($WithLoader) { [IO.File]::WriteAllText((Join-Path $t 'ToolkitRecover.ps1'), '# new loader'); [IO.File]::WriteAllText((Join-Path $p 'Toolkit/ToolkitRecover.ps1'), '# old loader') }
    [IO.File]::WriteAllText((Join-Path $t 'version.json'), '{"version":"9.9.9","previous":"9.9.8"}')
    [IO.File]::WriteAllText((Join-Path $p 'version.json.prev'), '{"version":"9.9.8"}')
    [IO.File]::WriteAllText((Join-Path $p 'undo.json'), '{"added":[]}')
    return $t
  }
  $undoChild = @'
param([string]$Tk, [string]$Mode)
. ('REPO' + '/Toolkit/ToolkitCore.ps1')
$script:order = New-Object System.Collections.Generic.List[string]; $script:skipAtFirst = $null; $script:journalAtFirst = $null
$skipF = Join-Path $Tk 'skip-version.txt'; $jp = Join-Path $Tk 'previous/update-pending.json'
function Copy-TkAtomicFile([string]$src, [string]$dst, [string]$hash = '') {
  if ($script:order.Count -eq 0) { $script:skipAtFirst = $(if (Test-Path -LiteralPath $skipF) { ([IO.File]::ReadAllText($skipF)).Trim() } else { '' }); $script:journalAtFirst = $(if (Test-Path -LiteralPath $jp) { [IO.File]::ReadAllText($jp) } else { '' }) }
  $script:order.Add((Split-Path -Leaf $dst)); [IO.File]::WriteAllBytes($dst, [IO.File]::ReadAllBytes($src))
}
if ($Mode -eq 'journalfails') { function Write-TkJournal($obj, [string]$path) { throw 'disk full' } }
if ($Mode -eq 'skipfails') { $null = New-Item -ItemType Directory -Force -Path $skipF }
$v = ''; $err = ''
try { $v = [string](Undo-TkUpdate $Tk) } catch { $err = $_.Exception.Message }
$j = $null; try { $j = [IO.File]::ReadAllText($script:journalAtFirst) } catch {}
'RESULT=' + (@{ v = $v; err = $err; order = @($script:order); skipAtFirst = $script:skipAtFirst; journalAtFirst = $script:journalAtFirst; skipNow = $(if (Test-Path -LiteralPath $skipF -PathType Leaf) { ([IO.File]::ReadAllText($skipF)).Trim() } else { '' }); journalNow = (Test-Path -LiteralPath $jp); aNow = ([IO.File]::ReadAllText((Join-Path $Tk 'a.ps1'))) } | ConvertTo-Json -Compress -Depth 4)
'@.Replace('REPO', $RepoQ)
  $t = New-UndoFixture 'g1' -WithLoader
  $c = Invoke-Child 'g1c' $undoChild @('-Tk', $t, '-Mode', 'ok')
  Check ($c.j -and [string]$c.j.skipAtFirst -eq '9.9.9') ('F2-A skip-version.txt already holds 9.9.9 when the FIRST file is swapped (got "' + $(if ($c.j) { $c.j.skipAtFirst } else { '?' }) + '")') $c.out
  $jo = $null; if ($c.j -and $c.j.journalAtFirst) { try { $jo = $c.j.journalAtFirst | ConvertFrom-Json } catch {} }
  Check ($jo -and [string]$jo.from -eq '9.9.8' -and [string]$jo.to -eq '9.9.9' -and [string]$jo.back -eq '9.9.8' -and [string]$jo.left -eq '9.9.9' -and [string]$jo.skip -eq '9.9.9') 'F2-B the journal keeps the old loader''s meaning (from = the version put back 9.9.8, to = 9.9.9) plus back/left/skip, so an older loader names the right versions' $c.out
  $ord = @(); if ($c.j) { $ord = @($c.j.order) }
  $pf = @($ord | Where-Object { $_ -ne 'version.json' })
  Check ($pf.Count -ge 3 -and $pf[-1] -eq 'ToolkitRecover.ps1') ('F2-C the recovery loader is the LAST program file swapped (only the version number after it; order: ' + ($ord -join ', ') + ')') $c.out
  Check ($c.j -and $c.j.v -eq '9.9.8' -and $c.j.skipNow -eq '9.9.9' -and -not $c.j.journalNow) 'F2-D a Go back that finishes: 9.9.8 back, marker 9.9.9, no journal left' $c.out
  $t = New-UndoFixture 'g2'
  $c = Invoke-Child 'g2c' $undoChild @('-Tk', $t, '-Mode', 'journalfails')
  Check ($c.j -and $c.j.err -and @($c.j.order).Count -eq 0 -and -not $c.j.skipNow -and $c.j.aNow -eq 'new-a') ('F2-E the journal can not be saved: nothing is swapped and the marker written just before is taken back (err: ' + $(if ($c.j) { $c.j.err } else { '?' }) + ')') $c.out
  $t = New-UndoFixture 'g3'
  $c = Invoke-Child 'g3c' $undoChild @('-Tk', $t, '-Mode', 'skipfails')
  Check ($c.j -and [string]$c.j.err -match 'do not re-install' -and @($c.j.order).Count -eq 0 -and -not $c.j.journalNow -and $c.j.aNow -eq 'new-a') ('F2-F the marker can not be saved: the Go back stops before anything changes, in plain words (err: ' + $(if ($c.j) { $c.j.err } else { '?' }) + ')') $c.out
  # the new loader, given a Go back journal, writes the marker before it puts any file back
  $recChild = @'
param([string]$Tk)
. ('REPO' + '/Toolkit/ToolkitRecover.ps1')
$skipF = Join-Path $Tk 'skip-version.txt'; $script:skipAtFirst = $null
function Copy-TkAtomicFile([string]$src, [string]$dst, [string]$hash = '') { if ($null -eq $script:skipAtFirst) { $script:skipAtFirst = $(if (Test-Path -LiteralPath $skipF) { ([IO.File]::ReadAllText($skipF)).Trim() } else { '' }) }; [IO.File]::WriteAllBytes($dst, [IO.File]::ReadAllBytes($src)) }
$n = ''; $err = ''
try { $n = [string](Invoke-TkStartupRecovery $Tk) } catch { $err = $_.Exception.Message }
'RESULT=' + (@{ notice = $n; err = $err; skipAtFirst = $script:skipAtFirst; skipNow = $(if (Test-Path -LiteralPath $skipF) { ([IO.File]::ReadAllText($skipF)).Trim() } else { '' }) } | ConvertTo-Json -Compress)
'@.Replace('REPO', $RepoQ)
  $t = New-UndoFixture 'g4'
  $pj = (Join-Path $t 'previous/9.9.8') -replace '\\', '\\'
  [IO.File]::WriteAllText((Join-Path $t 'previous/update-pending.json'), ('{"kind":"undo","prev":"' + $pj + '","from":"9.9.8","to":"9.9.9","back":"9.9.8","left":"9.9.9","skip":"9.9.9","added":[]}'))
  $r = Invoke-Child 'g4r' $recChild @('-Tk', $t)
  Check ($r.j -and [string]$r.j.skipAtFirst -eq '9.9.9' -and $r.j.skipNow -eq '9.9.9') ('F2-G startup recovery of a Go back saves the marker BEFORE it puts the first file back (got "' + $(if ($r.j) { $r.j.skipAtFirst } else { '?' }) + '")') $r.out
  Check ($r.j -and $r.j.notice -match 'Go back to version 9\.9\.8' -and $r.j.notice -notmatch '9\.9\.9') ('F2-H its notice names 9.9.8 as the version back in place (' + $(if ($r.j) { $r.j.notice } else { '?' }) + ')') $r.out
  $t = New-UndoFixture 'g5'
  [IO.File]::WriteAllText((Join-Path $t 'previous/update-pending.json'), ('{"kind":"undo","prev":"' + $pj.Replace('g4', 'g5') + '","from":"9.9.9","to":"9.9.8","skip":"9.9.9","added":[]}'))
  $r = Invoke-Child 'g5r' $recChild @('-Tk', $t)
  Check ($r.j -and $r.j.notice -match 'Go back to version 9\.9\.8' -and $r.j.skipNow -eq '9.9.9') 'F2-I a journal written by 2.2.15 (no back field, to = version put back) is still finished with the right words' $r.out
  Deferred 'F2: a real power cut during Go back on NTFS (marker + journal flushed to disk)'

  Write-Host 'F7: the mock SADP device publishes its state atomically before it answers; Test-HikReset cleans up every child'
  $fs = [IO.File]::ReadAllText((Join-Path $repo 'Toolkit/tests/hikreset/fake_sadp.py'))
  $saveFn = [regex]::Match($fs, '(?s)def save\(\):.*?\n(?=def )').Value
  Check ($saveFn -match 'os\.replace' -and $saveFn -notmatch "open\(statep, 'w'\)") 'F7-A fake_sadp.py writes the state to a temp file and moves it into place (never truncates the live file)' $saveFn
  $loop = $fs.Substring([math]::Max(0, $fs.IndexOf('while True')))
  $iSave = $loop.LastIndexOf('    save()'); $iSend = $loop.LastIndexOf('for t in out: s.sendto')
  Check ($iSave -gt 0 -and $iSend -gt $iSave) 'F7-B fake_sadp.py saves the state BEFORE it sends the answer (answers are held until saved)'
  $ht = [IO.File]::ReadAllText((Join-Path $repo 'Toolkit/tests/Test-HikReset.ps1'))
  $fsText = Get-FnText (Join-Path $repo 'Toolkit/tests/Test-HikReset.ps1') 'Fake-State'
  Check ($fsText -match 'for \(' -and $fsText -match 'Start-Sleep') 'F7-C Test-HikReset reads the fake state with retries (an empty/half file is never read as null)' $fsText
  $fin = $ht.Substring($ht.LastIndexOf('} finally {'))
  Check ($fin -match 'Stop-Fake \$fk2' -and $fin -match 'Stop-AllKids' -and $ht -match 'kids\.Add') 'F7-D Test-HikReset''s finally stops the second fake device and every child process it started' $fin
  Write-Host 'R11 note / runner'
  $rt = [IO.File]::ReadAllText((Join-Path $repo 'tools/Run-AllTests.ps1'))
  Check ($rt -notmatch "'SKIP Windows-only suite" -and $rt -match 'DEFERRED Windows-only suite') 'R11 the -Portable notice for a suite left out says DEFERRED, not SKIP'
  Check ($rt -match 'stopped without a summary line' -and $rt -match '\$cn\.failed = 1') 'F7-E a suite that aborts before its summary line is counted as at least 1 failed check (totals never say 0 failed over it)'
  Check ($rt -match 'Test-Repro2215\.ps1' -and $rt -match 'Test-Fix2216Classic\.ps1' -and $rt -match 'Test-Fix2216Site\.ps1' -and $rt -match 'Test-Fix2216Nvr\.ps1') 'the 2.2.16 suites and the reviewer''s 2.2.15 reproductions are in the pack'
  Write-Host 'Crew is a STANDARD user'
  $win = [IO.File]::ReadAllText((Join-Path $repo 'Toolkit/FixSiteWindow.ps1')); $ins = [IO.File]::ReadAllText((Join-Path $repo 'Toolkit/Install-Toolkit.ps1'))
  Check ($win -notmatch 'Crew is a local admin;' -and $win -notmatch '2\.2\.3: Crew is a local admin, so' -and $win -match 'STANDARD user') 'Crew-A FixSiteWindow no longer states "Crew is a local admin" as a fact; it says Crew is a standard user and what RunAs then does'
  Check ($ins -notmatch '\(2\.2\.3\) Crew is a local admin:' -and $ins -notmatch '\(Crew is a local admin\); the password vault' -and $ins -match "NOTE \(2\.2\.16\): the Crew login is a standard Windows user") 'Crew-B the installer states the assumption and prints a NOTE that Crew is a standard user (install behaviour unchanged)'
  $ek = Get-FnText (Join-Path $repo 'Toolkit/FixSiteWindow.ps1') 'Get-FsElevationKind'
  $ekr = ''; if ($ek) { $ekr = [string](& ([scriptblock]::Create($ek + "`nGet-FsElevationKind"))) }
  Check ($ek -and $(if ($env:OS -ne 'Windows_NT') { $ekr -eq '' } else { $true })) ('Crew-C the window''s standard-user check exists and says nothing off Windows (got "' + $ekr + '")')
  Check ($win -match "\(Get-FsElevationKind\) -eq 'standard'" -and $win -match 'ADMINISTRATOR name and password') 'Crew-D a standard-user login is told before the blue window starts that Windows asks for an ADMINISTRATOR and the window runs as that account'
  Check ($win -match '-Verb RunAs') 'Crew-E behaviour unchanged: the blue window is still started with RunAs (no install/elevation change without Moshe)'
  $vj = Get-Content -Raw (Join-Path $repo 'version.json') | ConvertFrom-Json
  $tcv = [regex]::Match([IO.File]::ReadAllText((Join-Path $repo 'Toolkit/ToolkitCore.ps1')), "TkBuiltVersion = '([^']+)'").Groups[1].Value
  Check ($tcv -eq '2.2.16' -and [string]$vj.version -eq '2.2.16') ('version 2.2.16 in ToolkitCore and version.json (' + $tcv + ', ' + $vj.version + ')')
  Deferred 'Crew: the real standard Crew login - RunAs credential prompt, which account the blue window runs as, and its access to site files, vault and run folder'
}
finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
Write-Host ''
Write-Host ('Test-Fix2216Classic: ' + $script:pass + ' passed, ' + $script:fail + ' failed' + $(if ($script:deferred) { ', ' + $script:deferred + ' deferred' } else { '' }))
if ($script:fail) { exit 1 } else { exit 0 }
