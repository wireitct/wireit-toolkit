<#
 Test-Repro2215.ps1 - WireIt Toolkit 2.2.16. Runs the independent reviewer's own reproductions of the 2.2.15 review (F1-F7),
 kept in Toolkit\tests\repro-2.2.15 and adapted to run from the repo and to assert the SAFE outcome. Each one prints PASS/FAIL lines
 and "N passed, M failed" and exits non-zero on any failure. On 2.2.15 (57c7fc9) each F1-F7 one fails; on 2.2.16 they pass
 (reproduce-free-channel-unread.py is the reviewer's passing refusal CONTROL: it passes on both).
 -Repo <folder> points them at another checkout (used to record the before/after). Needs Python 3 for the .py ones and for mock devices.
#>
param([string]$Repo = '')
$ErrorActionPreference = 'Continue'
if (-not $env:TEMP) { $env:TEMP = [IO.Path]::GetTempPath() }
if (-not $Repo) { $Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$dir = Join-Path $PSScriptRoot 'repro-2.2.15'
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
. (Join-Path $PSScriptRoot 'TestPython.ps1'); $py = Get-TestPython
$script:pass = 0; $script:fail = 0; $script:defer = 0
$files = @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name -like 'reproduce-*.ps1' -or $_.Name -like 'reproduce-*.py' } | Sort-Object Name)
if (-not $files.Count) { Write-Host 'FAIL no reproductions found in repro-2.2.15'; $script:fail++ }
foreach ($f in $files) {
  Write-Host ('--- ' + $f.Name)
  $out = @()
  if ($f.Extension -eq '.py') {
    if (-not $py) { $script:defer++; Write-Host ('DEFERRED ' + $f.Name + ' (no Python 3 on this PC - it did NOT run)'); continue }
    & $py $f.FullName --repo $Repo --powershell $exe 2>&1 | ForEach-Object { $l = [string]$_; Write-Host ('    ' + $l); $out += $l }; $code = $LASTEXITCODE
  } else {
    & $exe -NoProfile -ExecutionPolicy Bypass -File $f.FullName -Repo $Repo 2>&1 | ForEach-Object { $l = [string]$_; Write-Host ('    ' + $l); $out += $l }; $code = $LASTEXITCODE
  }
  $sum = $null; foreach ($l in $out) { $m = [regex]::Match($l, '^(\d+) passed, (\d+) failed'); if ($m.Success) { $sum = $m } }
  $nd = @($out | Where-Object { $_ -match '^\s*DEFERRED\b' }).Count
  if ($code -eq 0 -and $sum -and [int]$sum.Groups[2].Value -eq 0 -and [int]$sum.Groups[1].Value -gt 0) {
    if ($nd) { $script:defer += $nd }
    $script:pass++; Write-Host ('PASS reviewer reproduction ' + $f.Name + ' (' + $sum.Value + ')')
  } else { $script:fail++; Write-Host ('FAIL reviewer reproduction ' + $f.Name + ' (exit ' + $code + $(if ($sum) { ', ' + $sum.Value } else { ', no summary line' }) + ')') }
}
Write-Host ('Test-Repro2215: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:defer + ' deferred')
exit $script:fail
