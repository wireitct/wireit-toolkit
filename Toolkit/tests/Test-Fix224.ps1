<#
 Test-Fix224.ps1 - WireIt Toolkit 2.2.4 tests: Codex's re-review of toolkit-2.2.3-fixes @6c20133 (Nov 8 2026).
 Every check RUNS the real function or script against temp folders and mocks; none reads the source.
 A check marked "reproduction" failed on 6c20133 (2.2.3). pwsh 7 or Windows PowerShell 5.1, from any folder.
 Usage: powershell -NoProfile -ExecutionPolicy Bypass -File Toolkit\tests\Test-Fix224.ps1   (exit code = number of failed checks)
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path; $tk = Split-Path -Parent $here; $repo = Split-Path -Parent $tk
$script:fail = 0; $script:pass = 0
function Check([bool]$ok, [string]$what) { if ($ok) { $script:pass++; Write-Host ('  ok    ' + $what) } else { $script:fail++; Write-Host ('  FAIL  ' + $what) -ForegroundColor Red } }
function Eq($a, $b, [string]$what) { Check ("$a" -eq "$b") ($what + ' (got "' + $a + '", want "' + $b + '")') }
function Try-Check([scriptblock]$b, [string]$what) { try { Check ([bool](& $b)) $what } catch { Check $false ($what + ' (threw: ' + $_.Exception.Message + ')') } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix224-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force -Path $tmp | Out-Null
. (Join-Path $tk 'FixSiteCore.ps1'); . (Join-Path $tk 'FixSiteDevices.ps1')
$script:LogLines = New-Object System.Collections.ArrayList
function Fs-LogLine([string]$s) { [void]$script:LogLines.Add($s) }
try {

# ------------------------------------------------------------------------------------------------------------------------------
Write-Host '1. site names that differ only in punctuation or spacing never share a store, list file or pictures folder'
$script:FsTestSecrets = $true
$sd = Join-Path $tmp 'sec1'; New-Item -ItemType Directory -Force -Path $sd | Out-Null
$names = @('A B', 'A_B', 'A  B', 'A/B', 'A-B')
foreach ($nm in $names) { $s = Read-FsSecrets $sd $nm; $s.password = 'Pw-' + $nm; Save-FsSecrets $sd $s }
foreach ($nm in $names) { Eq (Read-FsSecrets $sd $nm).password ('Pw-' + $nm) ('reproduction: "' + $nm + '" reads back its own password (2.2.3: "A B" and "A_B" overwrote each other)') }
Eq @(Get-ChildItem -LiteralPath $sd -Filter 'site-*.dat').Count $names.Count 'one password store per site name'
Eq (Read-FsSecrets $sd 'a b').password 'Pw-A B' 'the same name in another case is the same site'
# list files: write each site's list where Resolve-FsLocalList says, then read them all back
$ld = Join-Path $tmp 'lists1'; New-Item -ItemType Directory -Force -Path $ld | Out-Null
foreach ($nm in $names) { $p = Resolve-FsLocalList $ld $nm; ([ordered]@{ site = $nm; cameras = @() } | ConvertTo-Json) | Set-Content -LiteralPath $p }
foreach ($nm in $names) { Eq ((Get-Content -LiteralPath (Resolve-FsLocalList $ld $nm) -Raw | ConvertFrom-Json).site) $nm ('reproduction: "' + $nm + '" list file is its own') }
# 2.2.2 files (no fingerprint) are still read, only by the site they name
$od = Join-Path $tmp 'old1'; New-Item -ItemType Directory -Force -Path $od | Out-Null
[IO.File]::WriteAllText((Join-Path $od 'site-A_B.dat'), (Protect-FsText ([ordered]@{ site = 'A B'; password = 'OldPwAB' } | ConvertTo-Json -Compress)))
([ordered]@{ site = 'A B'; cameras = @() } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $od 'A_B.json')
Eq (Read-FsSecrets $od 'A B').password 'OldPwAB' 'a 2.2.2 store (old file name) is still read by "A B"'
Check (-not (Read-FsSecrets $od 'A_B').password) '...and not by "A_B"'
Eq (Split-Path -Leaf (Resolve-FsLocalList $od 'A B')) 'A_B.json' 'a 2.2.2 list file is still read by its own site'
Check ((Split-Path -Leaf (Resolve-FsLocalList $od 'A_B')) -ne 'A_B.json') '...and "A_B" gets a new file of its own'
Check (Test-Path -LiteralPath (Get-FsSecretPath $od 'A B')) 'the 2.2.2 store was moved to the collision-proof name on first read'
# 2.2.3 file (6-hex fingerprint on punctuated names) still read
$o3 = Join-Path $tmp 'old3'; New-Item -ItemType Directory -Force -Path $o3 | Out-Null
$sha = [Security.Cryptography.SHA256]::Create(); $h3 = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('a/b'))[0..2] | ForEach-Object { $_.ToString('x2') }); $sha.Dispose()
([ordered]@{ site = 'A/B'; cameras = @() } | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $o3 ('A_B-' + $h3 + '.json'))
Eq (Split-Path -Leaf (Resolve-FsLocalList $o3 'A/B')) ('A_B-' + $h3 + '.json') 'a 2.2.3 list file is still read by its own site'
$script:FsTestSecrets = $false
# camera pictures folder (CamViews): run the real save twice, same camera key
$cvd = Join-Path $tmp 'cv1'; New-Item -ItemType Directory -Force -Path $cvd | Out-Null
$job = Start-Job -ScriptBlock { param($tk, $cvd)
  . (Join-Path $tk 'CamViews.ps1') -Lib; $script:CvPics = $cvd
  Save-CvLocal 'A B' 'ch1' '10.0.0.5' '20261108-1000' ([byte[]](1, 2, 3)); Save-CvLocal 'A/B' 'ch1' '10.0.0.5' '20261108-1000' ([byte[]](4, 5, 6)); Save-CvLocal 'A?B' 'ch1' '10.0.0.5' '20261108-1000' ([byte[]](7, 8, 9))
  @(Get-ChildItem -LiteralPath $cvd -Directory).Count } -ArgumentList $tk, $cvd
$nCv = Receive-Job -Job $job -Wait -AutoRemoveJob
Eq $nCv 3 'reproduction: "A B", "A/B", "A?B" camera pictures go to 3 folders (2.2.3: "A/B" and "A?B" shared one)'

#@@NEXT@@

} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ''; Write-Host ('Test-Fix224: ' + $script:pass + ' passed, ' + $script:fail + ' failed')
exit $script:fail
