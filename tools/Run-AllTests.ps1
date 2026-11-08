<#
 Run-AllTests.ps1 - runs every WireIt Toolkit test suite from a plain clone (Windows PowerShell 5.1 or pwsh 7). Not shipped (tools\).
 Usage (from anywhere):  powershell -NoProfile -ExecutionPolicy Bypass -File <clone>\tools\Run-AllTests.ps1
 Needs a real Python 3 for the mock devices (Toolkit\tests\TestPython.ps1 finds it: py -3, then python, then python3; never the Windows Store stub). Exit code = number of suites that failed.
#>
$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$suites = @('Toolkit\tests\Test-Fix224.ps1', 'Toolkit\tests\Test-Fix223.ps1', 'Toolkit\tests\Test-Fix222.ps1', 'Toolkit\tests\Test-Fix221.ps1', 'Toolkit\tests\Test-Fix22.ps1',
  'Toolkit\tests\Test-HikReset.ps1', 'Toolkit\tests\Test-FixSite.ps1', 'Toolkit\tests\Test-FixIt.ps1', 'Toolkit\tests\Test-Toolkit.ps1',
  'Toolkit\modules\NvrHealth\tests\Test-NvrHealth.ps1', 'sitecheck\tests\Test-SiteCheck.ps1')
$bad = 0; $rows = @()
foreach ($s in $suites) {
  $p = Join-Path $repo $s; $t0 = Get-Date
  Write-Host ('===== ' + $s) -ForegroundColor Cyan
  Push-Location (Split-Path -Parent $p); try { & $exe -NoProfile -ExecutionPolicy Bypass -File $p; $code = $LASTEXITCODE } finally { Pop-Location }
  if ($code -ne 0) { $bad++ }
  $rows += [pscustomobject]@{ suite = $s; exit = $code; seconds = [int]((Get-Date) - $t0).TotalSeconds }
}
Write-Host ''; $rows | Format-Table -AutoSize | Out-String | Write-Host
Write-Host $(if ($bad) { '' + $bad + ' suite(s) FAILED' } else { 'ALL SUITES PASSED' }) -ForegroundColor $(if ($bad) { 'Red' } else { 'Green' })
exit $bad
