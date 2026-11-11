<#
 Run-AllTests.ps1 - runs every WireIt Toolkit test suite from a plain clone (Windows PowerShell 5.1 or pwsh 7). Not shipped (tools\).
 Usage (from anywhere):  powershell -NoProfile -ExecutionPolicy Bypass -File <clone>\tools\Run-AllTests.ps1
 Add -Portable on Linux to omit the two Windows desktop suites, Test-FixIt and Test-Toolkit (and, off Windows, Test-SiteCheck: it needs the Windows drawing library); all other suites still run (2.2.14: Test-NvrHealth now runs in -Portable too).
 Needs a real Python 3 for the mock devices (Toolkit\tests\TestPython.ps1 finds it: py -3, then python, then python3; never the Windows Store stub).
 2.2.11 (Codex R17, Moshe Nov 9 2026 "deferred never counts as pass"): a suite whose own summary line says it has DEFERRED checks
 is shown as DEFERRED, not PASS, even when it exits 0; the table shows passed / failed / deferred per suite and the totals. "ALL SUITES
 PASSED" is printed only when no suite failed AND none has a deferred check.
 Exit code = number of suites that failed + number of suites with deferred checks (0 only for a real, full pass).
 2.2.15 (Codex R11): SKIP lines count as deferred; suites left out by -Portable are DEFERRED rows (and count in the exit code).
 2.2.15: Test-Repro2214 runs the reviewer's own 2.2.14 reproductions (Toolkit\tests\repro-2.2.14) against this code.
 2.2.16: Test-Repro2215 runs the reviewer's 2.2.15 reproductions (Toolkit\tests\repro-2.2.15). The -Portable notice for a suite left
 out says DEFERRED (Codex 2.2.15 R11 note), and a suite that fails without printing its summary (it aborted half-way) counts as at least
 1 failed check, so the totals never read "0 failed" over an aborted suite (Codex 2.2.15 F7).
 2.2.18: Test-Fix2218Classic / Nvr / Site / Sweep (Codex review of 2.2.17 + the repo-wide sweep) run first.
 2.2.19: Test-Fix2219Site / PcNet / Classic / Nvr / Sweep / Sweep2 (Codex review of 2.2.18, F01-F27) run first. -SummaryJson <file> writes every
 suite row (passed / failed / deferred / exit / seconds), the totals and the PowerShell / Python / node used, so two runs can be
 reconciled suite by suite (Codex 2.2.18 could not reconcile 2,291 vs 2,293: the difference was Test-Fix222's two PowerShell 7.5 checks,
 which now print DEFERRED where no 7.5 is installed).
 2.2.12 (Codex P2-15): the Hik relay suite (appsscript\tests\hikrelay.test.js, Node) is part of the pack: it runs with node and is
 counted like any other suite; with no node on the PC it is DEFERRED (never a pass), so a broken relay can not slip through.
#>
param([switch]$Portable, [switch]$OnlyRelay, [string]$SummaryJson = '')
$ErrorActionPreference = 'Continue'
if (-not $env:TEMP) { $env:TEMP = [IO.Path]::GetTempPath() }
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$suites = @('Toolkit\tests\Test-Fix2219Site.ps1', 'Toolkit\tests\Test-Fix2219PcNet.ps1', 'Toolkit\tests\Test-Fix2219Classic.ps1', 'Toolkit\tests\Test-Fix2219Nvr.ps1', 'Toolkit\tests\Test-Fix2219Sweep.ps1', 'Toolkit\tests\Test-Fix2219Sweep2.ps1', 'Toolkit\tests\Test-Fix2218Classic.ps1', 'Toolkit\tests\Test-Fix2218Nvr.ps1', 'Toolkit\tests\Test-Fix2218Site.ps1', 'Toolkit\tests\Test-Fix2218Sweep.ps1', 'Toolkit\tests\Test-Fix2217Nvr.ps1', 'Toolkit\tests\Test-Fix2217Site.ps1', 'Toolkit\tests\Test-Repro2215.ps1', 'Toolkit\tests\Test-Fix2216Nvr.ps1', 'Toolkit\tests\Test-Fix2216Classic.ps1', 'Toolkit\tests\Test-Fix2216Site.ps1', 'Toolkit\tests\Test-Repro2214.ps1', 'Toolkit\tests\Test-Fix2215Nvr.ps1', 'Toolkit\tests\Test-Fix2215Classic.ps1', 'Toolkit\tests\Test-Fix2215Site.ps1', 'Toolkit\tests\Test-Fix2214Nvr.ps1', 'Toolkit\tests\Test-Fix2214Classic.ps1', 'Toolkit\tests\Test-Fix2214Site.ps1', 'Toolkit\tests\Test-Fix2213Nvr.ps1', 'Toolkit\tests\Test-Fix2213Classic.ps1', 'Toolkit\tests\Test-Fix2213Net.ps1', 'Toolkit\tests\Test-Fix2213Site.ps1', 'Toolkit\tests\Test-Fix2212.ps1', 'Toolkit\tests\Test-Fix2212Site.ps1', 'Toolkit\tests\Test-Fix2212Nvr.ps1', 'Toolkit\tests\Test-Fix2212Net.ps1', 'Toolkit\tests\Test-Fix2211.ps1', 'Toolkit\tests\Test-Fix2210.ps1', 'Toolkit\tests\Test-Fix229.ps1', 'Toolkit\tests\Test-Fix228.ps1', 'Toolkit\tests\Test-Fix227.ps1', 'Toolkit\tests\Test-Fix226.ps1', 'Toolkit\tests\Test-Review225.ps1', 'Toolkit\tests\Test-Fix225.ps1', 'Toolkit\tests\Test-Fix224.ps1', 'Toolkit\tests\Test-Fix223.ps1', 'Toolkit\tests\Test-Fix222.ps1', 'Toolkit\tests\Test-Fix221.ps1', 'Toolkit\tests\Test-Fix22.ps1',
  'Toolkit\tests\Test-HikReset.ps1', 'Toolkit\tests\Test-FixSite.ps1', 'Toolkit\tests\Test-FixIt.ps1', 'Toolkit\tests\Test-Toolkit.ps1',
  'Toolkit\modules\NvrHealth\tests\Test-NvrHealth.ps1', 'sitecheck\tests\Test-SiteCheck.ps1')
if ($Portable) {
  # 2.2.14: Test-NvrHealth runs off Windows too (pwsh + Python mock; TEMP is set above), so -Portable keeps it
  $desktop = @('Test-FixIt.ps1', 'Test-Toolkit.ps1')
  # 2.2.6: SiteCheck draws its report with System.Drawing (GDI+), which exists only on Windows: skipped by -Portable off Windows
  if ($env:OS -ne 'Windows_NT') { $desktop += 'Test-SiteCheck.ps1' }
  $suites = @($suites | Where-Object {
    if ((Split-Path -Leaf $_) -in $desktop) { Write-Host ('DEFERRED Windows-only suite (not run here): ' + $_); $false } else { $true }
  })
}
$bad = 0; $deferredSuites = 0; $rows = @()
# 2.2.15 (Codex 2.2.14 R11): a suite left out by -Portable is shown as a DEFERRED row (did not run), so the totals never hide it
if ($Portable -and -not $OnlyRelay) {
  foreach ($d in $desktop) { $rows += [pscustomobject]@{ suite = ('(not run here) ' + $d); result = 'DEFERRED'; passed = 0; failed = 0; deferred = 1; exit = 0; seconds = 0 }; $deferredSuites++ }
}
if ($OnlyRelay) { $suites = @() }   # 2.2.12: tests of the runner itself run only the relay part
# reads a suite's own counts from what it printed: "N passed, M failed" (+ ", K deferred" where a suite has deferred checks)
function Get-SuiteCounts([string[]]$lines) {
  $c = [ordered]@{ passed = $null; failed = $null; deferred = 0 }
  # the LAST summary line counts; a check's own name that quotes such a line (PASS ... / FAIL ... / ok ...) is not a summary
  foreach ($l in $lines) {
    if ([string]$l -match '^\s*(PASS|FAIL|ok|DEFERRED|SKIP|skip)\b') { continue }
    $m = [regex]::Match([string]$l, '(?i)\b(\d+) passed\b[^\d]{0,40}?(\d+) failed\b(?:[^\d]{0,40}?(\d+) deferred\b)?')
    if ($m.Success) { $c.passed = [int]$m.Groups[1].Value; $c.failed = [int]$m.Groups[2].Value; $c.deferred = $(if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { 0 }) }
  }
  # a DEFERRED line printed by the suite counts even if its summary line forgot to say so
  # 2.2.15 (Codex 2.2.14 R11): so does a SKIP line - a check that did not run here is unproved, never a pass
  $dl = @($lines | Where-Object { [string]$_ -match '^\s*DEFERRED\b' }).Count
  $sl = @($lines | Where-Object { [string]$_ -match '^\s*SKIP\b' }).Count
  if (($dl + $sl) -gt $c.deferred) { $c.deferred = $dl + $sl }
  return [pscustomobject]$c
}
function Get-SuiteResult([int]$code, $counts) {
  if ($code -ne 0) { return 'FAIL' }
  if ($counts.deferred -gt 0) { return 'DEFERRED' }   # never a pass
  return 'PASS'
}
foreach ($s in $suites) {
  $p = Join-Path $repo $s; $t0 = Get-Date
  Write-Host ('===== ' + $s) -ForegroundColor Cyan
  $out = @()
  Push-Location (Split-Path -Parent $p); try { & $exe -NoProfile -ExecutionPolicy Bypass -File $p 2>&1 | ForEach-Object { $l = [string]$_; Write-Host $l; $out += $l }; $code = $LASTEXITCODE } finally { Pop-Location }
  $cn = Get-SuiteCounts $out; $res = Get-SuiteResult $code $cn
  # 2.2.16 (F7): a suite that stopped before its summary line (or exits non-zero with "0 failed") is at least one failed check
  if ($res -eq 'FAIL' -and (-not $cn.failed)) { Write-Host ('FAIL ' + $s + ' stopped without a summary line or with no failed check counted (exit ' + $code + ') - counted as 1 failed check'); $cn.failed = 1; if ($null -eq $cn.passed) { $cn.passed = 0 } }
  if ($res -eq 'FAIL') { $bad++ } elseif ($res -eq 'DEFERRED') { $deferredSuites++ }
  $rows += [pscustomobject]@{ suite = $s; result = $res; passed = $cn.passed; failed = $cn.failed; deferred = $cn.deferred; exit = $code; seconds = [int]((Get-Date) - $t0).TotalSeconds }
}
# 2.2.12 (Codex P2-15): the Node relay suite
function Get-NodeSuiteRow([string]$repoDir, [string]$nodeExe) {
  $rel = 'appsscript\tests\hikrelay.test.js'; $js = Join-Path $repoDir ($rel -replace '\\', [string][IO.Path]::DirectorySeparatorChar)
  if (-not (Test-Path -LiteralPath $js)) { Write-Host ('FAIL relay suite missing: ' + $rel); return [pscustomobject]@{ suite = $rel; result = 'FAIL'; passed = 0; failed = 1; deferred = 0; exit = 1; seconds = 0 } }
  if (-not $nodeExe) { Write-Host ('DEFERRED ' + $rel + ' (no node on this PC - the relay suite did NOT run)'); return [pscustomobject]@{ suite = $rel; result = 'DEFERRED'; passed = 0; failed = 0; deferred = 1; exit = 0; seconds = 0 } }
  $t0 = Get-Date; Write-Host ('===== ' + $rel + ' (node)') -ForegroundColor Cyan
  $out = @(); & $nodeExe $js 2>&1 | ForEach-Object { $l = [string]$_; Write-Host $l; $out += $l }; $code = $LASTEXITCODE
  $tot = $null; foreach ($l in $out) { $m = [regex]::Match($l, '(?i)hikrelay total:\s*(\d+)\s*ok'); if ($m.Success) { $tot = [int]$m.Groups[1].Value } }
  $nf = @($out | Where-Object { $_ -match '(?i)^\s*(not ok|fail|assertionerror)' }).Count
  if ($code -ne 0 -and -not $nf) { $nf = 1 }
  if ($code -eq 0 -and $null -eq $tot) { $code = 1; $nf = 1; Write-Host 'FAIL relay suite printed no "hikrelay total: N ok" line' }
  $res = $(if ($code -ne 0) { 'FAIL' } else { 'PASS' })
  return [pscustomobject]@{ suite = $rel; result = $res; passed = $(if ($null -ne $tot) { $tot } else { 0 }); failed = $nf; deferred = 0; exit = $code; seconds = [int]((Get-Date) - $t0).TotalSeconds }
}
if ($env:WIREIT_TEST_NODE -eq 'none') { $nodeExe = '' } elseif ($env:WIREIT_TEST_NODE) { $nodeExe = $env:WIREIT_TEST_NODE } else { $nodeExe = ''; $nc = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1; if ($nc) { $nodeExe = $nc.Source } }
$nrow = Get-NodeSuiteRow $repo $nodeExe
if ($nrow.result -eq 'FAIL') { $bad++ } elseif ($nrow.result -eq 'DEFERRED') { $deferredSuites++ }
$rows += $nrow
Write-Host ''; $rows | Format-Table -AutoSize | Out-String | Write-Host
$tp = ($rows | Measure-Object passed -Sum).Sum; $tf = ($rows | Measure-Object failed -Sum).Sum; $td = ($rows | Measure-Object deferred -Sum).Sum
Write-Host ('Checks: ' + $tp + ' passed, ' + $tf + ' failed, ' + $td + ' deferred (deferred is NOT a pass)')
if ($SummaryJson) {
  # 2.2.19: a per-suite record next to the log, so totals reconcile suite by suite
  $pyv = ''; try { $pyc = Get-Command python3 -ErrorAction SilentlyContinue | Select-Object -First 1; if (-not $pyc) { $pyc = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1 }; if ($pyc) { $pyv = [string](& $pyc.Source --version 2>&1) } } catch { $pyv = '' }
  $ndv = ''; if ($nodeExe) { try { $ndv = [string](& $nodeExe --version 2>&1) } catch { $ndv = '' } }
  $sum = [ordered]@{ portable = [bool]$Portable; powershell = [string]$PSVersionTable.PSVersion; edition = [string]$PSVersionTable.PSEdition; os = [string][Environment]::OSVersion.VersionString;
    python = $pyv; node = $ndv; pwsh75 = [bool]($env:WIREIT_PWSH75 -or (Test-Path '/home/user/opt/pwsh75/pwsh')); suites = @($rows | ForEach-Object { [ordered]@{ suite = $_.suite; result = $_.result; passed = [int]$_.passed; failed = [int]$_.failed; deferred = [int]$_.deferred; exit = [int]$_.exit; seconds = [int]$_.seconds } });
    totals = [ordered]@{ passed = [int]$tp; failed = [int]$tf; deferred = [int]$td; suites = @($rows).Count; failedSuites = [int]$bad; deferredSuites = [int]$deferredSuites; exit = [int]($bad + $deferredSuites) } }
  try { [IO.File]::WriteAllText($SummaryJson, ($sum | ConvertTo-Json -Depth 5)); Write-Host ('Per-suite summary written: ' + $SummaryJson) } catch { Write-Host ('FAIL could not write the per-suite summary ' + $SummaryJson + ': ' + $_.Exception.Message); $bad++ }
}
$scope = $(if ($Portable) { 'SELECTED PORTABLE SUITES' } else { 'SUITES' })
if ($bad) { Write-Host ('' + $bad + ' suite(s) FAILED' + $(if ($deferredSuites) { ', ' + $deferredSuites + ' suite(s) with DEFERRED checks (not a pass)' } else { '' })) -ForegroundColor Red }
elseif ($deferredSuites) { Write-Host ('NOT A FULL PASS: no suite failed, but ' + $deferredSuites + ' suite(s) have ' + $td + ' DEFERRED check(s). Deferred never counts as pass.') -ForegroundColor Yellow }
else { Write-Host ('ALL ' + $scope + ' PASSED') -ForegroundColor Green }
exit ($bad + $deferredSuites)
