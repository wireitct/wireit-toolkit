<#
 Test-Fix22.ps1 - WireIt Toolkit 2.2.0 tests for the review fixes (pwsh 7 or Windows PowerShell 5.1; no Windows-only parts).
   H1  the icacls plan (who may touch what under C:\WireIt), the "Fix this site" task definition and who may run it
   H2  the site-password word: asked hidden, never in a log; old 2.1 logs are blanked
   H3  the runner: only a checked request runs; the questions go to the window and back (file channel); end to end with a fake window
   M1  the secrets store: machine-wide (LM1), 2.1 files moved, a file another account made is reported, never replaced
 Usage: pwsh -File Test-Fix22.ps1   (exit code = number of failed checks)
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path; $tk = Split-Path -Parent $here
$script:fail = 0; $script:pass = 0
function Check([bool]$ok, [string]$what) { if ($ok) { $script:pass++; Write-Host ('  ok    ' + $what) } else { $script:fail++; Write-Host ('  FAIL  ' + $what) -ForegroundColor Red } }
function Eq($a, $b, [string]$what) { Check ("$a" -eq "$b") ($what + ' (got "' + $a + '", want "' + $b + '")') }
$psx = (Get-Process -Id $PID).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix22-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Force -Path $tmp | Out-Null
. (Join-Path $tk 'FixSiteCore.ps1'); . (Join-Path $tk 'FixSiteDevices.ps1')
function Fs-LogLine([string]$s) { }
try {
# 2.2.3: section 'H1. permissions plan'' removed with the Crew/SYSTEM split (Test-Fix223 proves the old path is gone)
# 2.2.3: section 'H1/H3. the task'' removed with the Crew/SYSTEM split (Test-Fix223 proves the old path is gone)
# 2.2.3: section 'H3. the request Crew sends'' removed with the Crew/SYSTEM split (Test-Fix223 proves the old path is gone)
# 2.2.3: section 'H3. questions and answers' removed with the Crew/SYSTEM split (Test-Fix223 proves the old path is gone)
Write-Host 'H2. the word: old logs'
$lr = Join-Path $tmp 'oldruns\2026-11-06_1012_Lieber'; New-Item -ItemType Directory -Force -Path $lr | Out-Null
[IO.File]::WriteAllLines((Join-Path $lr 'log.txt'), @('10:12:01 SAY hi', '10:12:02 ASK Site passwords start with your word, then 4 random digits. Type the word (same capital letters; letters/digits, 4-16 long, starting with a letter). Asked once - kept encrypted on this PC:', '10:12:09 ANSWER Zebrafish', '10:12:10 ASK Which site?', '10:12:11 ANSWER Lieber'))
Eq (Clear-WordAnswerFromLogs @((Join-Path $tmp 'oldruns'))) 1 'installer: the one logged word is found'
$ll = Get-Content (Join-Path $lr 'log.txt') -Raw
Check ($ll -notmatch 'Zebrafish' -and $ll -match '10:12:09 ANSWER \(hidden\)' -and $ll -match 'ANSWER Lieber') 'the word is blanked; other answers stay'
Eq (Clear-WordAnswerFromLogs @((Join-Path $tmp 'oldruns'))) 0 'run again: nothing left to blank'

Write-Host 'M1. secrets store'
$script:FsDpapi = { param($op, $data, $scope) if ($op -eq 'protect') { return [byte[]](@([byte]$(if ($scope -eq 'LocalMachine') { 1 } else { 2 })) + $data) }; if ($data[0] -eq 1 -and $scope -eq 'LocalMachine') { return [byte[]]$data[1..($data.Length - 1)] }; if ($data[0] -eq 2 -and $scope -eq 'CurrentUser' -and $env:FAKE_SAME_USER) { return [byte[]]$data[1..($data.Length - 1)] }; throw 'cannot decrypt' }
$vault = Join-Path $tmp 'vault'; $legacy = Join-Path $tmp 'secrets'; New-Item -ItemType Directory -Force -Path $legacy | Out-Null
$enc = Protect-FsText 'abc'; Check ($enc.StartsWith('LM1:')) 'new files are machine-wide (LM1)'; Eq (Unprotect-FsText $enc) 'abc' 'and read back'
$cu = { param($t) [Convert]::ToBase64String([byte[]](@([byte]2) + [Text.Encoding]::UTF8.GetBytes($t))) }
[IO.File]::WriteAllText((Join-Path $legacy 'site-Lieber.dat'), (& $cu '{"site":"Lieber","password":"Lieber#7788"}'))
New-Item -ItemType Directory -Force -Path $vault | Out-Null; [IO.File]::WriteAllText((Join-Path $vault 'site-Other.dat'), (& $cu '{"site":"Other","password":"x"}'))
$env:FAKE_SAME_USER = ''
$s0 = Read-FsSecrets $vault 'Other'; Check ($s0.unreadable -and -not $s0.password) 'a 2.1 file in vault made by another account: unreadable, not "no password"'
$script:FsLegacySecretsDir = $legacy
$s1 = Read-FsSecrets $vault 'Lieber'; Check ($s1.unreadable -and (Get-FsUnreadableText $s1.unreadableWhy) -match 'another Windows account') 'another admin than the one who saved it: reported as "saved by another Windows account"'
$env:FAKE_SAME_USER = '1'
$s2 = Read-FsSecrets $vault 'Lieber'; Check (-not $s2.unreadable -and $s2.password -eq 'Lieber#7788') 'the account that saved it reads it'
Check ((Test-Path (Join-Path $vault 'site-Lieber.dat')) -and (Get-Content (Join-Path $vault 'site-Lieber.dat') -Raw).StartsWith('LM1:') -and -not (Test-Path (Join-Path $legacy 'site-Lieber.dat'))) 'and it is moved into vault\ as machine-wide'
$env:FAKE_SAME_USER = ''
$s3 = Read-FsSecrets $vault 'Lieber'; Check ($s3.password -eq 'Lieber#7788') 'after the move ANY admin account (or SYSTEM) reads it'
$script:FsLegacySecretsDir = ''
[IO.File]::WriteAllText((Join-Path $legacy 'password-word.dat'), (& $cu 'Zebrafish'))
$env:FAKE_SAME_USER = '1'; $cv = Convert-FsSecretStores $legacy (Join-Path $tmp 'vault2')
Check ($cv.moved -eq 1 -and @($cv.unreadable).Count -eq 0 -and (Get-FsSitePrefix $null (Join-Path $tmp 'vault2')) -eq 'Zebrafish') 'installer: Convert-FsSecretStores moves what this account can read'
[IO.File]::WriteAllText((Join-Path $legacy 'site-Nope.dat'), (& $cu '{"site":"Nope"}')); $env:FAKE_SAME_USER = ''
$cv = Convert-FsSecretStores $legacy (Join-Path $tmp 'vault2'); Check (@($cv.unreadable) -contains 'site-Nope.dat' -and (Test-Path (Join-Path $legacy 'site-Nope.dat'))) 'installer: a file another account made is listed and left where it is'
[IO.File]::WriteAllText((Join-Path $vault 'site-Pc.dat'), 'LM1:' + [Convert]::ToBase64String([byte[]](9, 9, 9)))
$s4 = Read-FsSecrets $vault 'Pc'; Check ($s4.unreadable -and (Get-FsUnreadableText $s4.unreadableWhy) -match 'another PC') 'a vault file copied from another PC: reported as such'
$script:FsDpapi = $null; Remove-Item Env:\FAKE_SAME_USER -ErrorAction SilentlyContinue

# 2.2.3: section 'H2/H3. end to end: the runner' removed with the Crew/SYSTEM split (Test-Fix223 proves the old path is gone)
} finally { try { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue } catch {} }
Write-Host ''
Write-Host ($script:pass.ToString() + ' passed, ' + $script:fail + ' failed')
exit $script:fail
