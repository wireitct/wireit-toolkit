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

# ------------------------------------------------------------------------------------------------------------------------------
Write-Host '2. a backup that is only a login/HTML page (or an error answer) is FAILED, never "complete"'
$script:Fake = @{}; $script:Calls = New-Object System.Collections.ArrayList
Set-Item -Path function:global:Fs-Http -Value {
  param([string]$Ip, [string]$Path, [string]$Method = 'GET', [string]$Body = '', [string]$ContentType = 'application/xml', $Cred = $null, [int]$Timeout = 8, [string]$OutFile = '', [switch]$Secret, [switch]$Tls)
  $k = $Method + ' ' + $Ip + $Path; $v = $null; foreach ($p in $script:Fake.Keys) { if ($k -like $p) { $v = $script:Fake[$p]; break } }
  if ($null -eq $v) { return [pscustomobject]@{ code = 404; body = '' } }
  if ($v -is [string]) { $v = @{ code = 200; body = $v } }
  if ($OutFile -and $v.code -eq 200) { [IO.File]::WriteAllText($OutFile, [string]$v.body); return [pscustomobject]@{ code = 200; body = '' } }
  return [pscustomobject]@{ code = [int]$v.code; body = [string]$v.body }
}
$login = '<!DOCTYPE html><html><head><title>Login</title></head><body><form action="/doc/page/login.asp"><input type="password" name="pw"></form>' + ('<!-- pad -->' * 200) + '</body></html>'
$goodBin = ('HIKCFG' + [string][char]0) * 700
$net = '<?xml version="1.0"?><NetworkInterfaceList><NetworkInterface><id>1</id></NetworkInterface></NetworkInterfaceList>'
$str = '<?xml version="1.0"?><StreamingChannel><id>101</id></StreamingChannel>'
function Hik-Fake([string]$ip, $cfg, $nw = $net, $st = $str) { $script:Fake = @{ ('GET ' + $ip + '/ISAPI/System/configurationData') = $cfg; ('GET ' + $ip + '/ISAPI/System/Network/interfaces') = $nw; ('GET ' + $ip + '/ISAPI/Streaming/channels/101') = $st } }
$script:LogLines.Clear()
Hik-Fake '10.0.2.1' $login; $bf = @(Save-FsBackup '10.0.2.1' 'Hikvision' $null (Join-Path $tmp 'bk2a'))
Check (-not (Test-FsBackupComplete $bf 'Hikvision')) 'reproduction: configurationData answered with a login page -> NOT complete (2.2.3: "backup saved")'
Check ($script:FsBackupWhy -match 'login/HTML') ('...and why says login/HTML page (' + $script:FsBackupWhy + ')')
Check (@($script:LogLines | Where-Object { $_ -match 'backup FAILED: configurationData.bin' }).Count -eq 1) '...and the log says backup FAILED'
Check (-not (Test-Path -LiteralPath (Join-Path (Join-Path $tmp 'bk2a') 'configurationData.bin'))) '...and the login page is not kept as a "backup"'
Hik-Fake '10.0.2.2' $goodBin $login; $bf = @(Save-FsBackup '10.0.2.2' 'Hikvision' $null (Join-Path $tmp 'bk2b'))
Check (-not (Test-FsBackupComplete $bf 'Hikvision' -Nvr)) 'reproduction: network settings answered with a login page -> NOT complete'
Hik-Fake '10.0.2.3' '<?xml version="1.0" encoding="UTF-8"?><ResponseStatus><statusCode>4</statusCode><subStatusCode>notSupport</subStatusCode></ResponseStatus>'; $bf = @(Save-FsBackup '10.0.2.3' 'Hikvision' $null (Join-Path $tmp 'bk2c'))
Check (-not (Test-FsBackupComplete $bf 'Hikvision')) 'reproduction: an error answer saved as configurationData.bin -> NOT complete'
Hik-Fake '10.0.2.4' 'tiny'; $bf = @(Save-FsBackup '10.0.2.4' 'Hikvision' $null (Join-Path $tmp 'bk2d'))
Check (-not (Test-FsBackupComplete $bf 'Hikvision')) 'reproduction: a 4-byte "export" -> NOT complete'
Hik-Fake '10.0.2.5' $goodBin; $bf = @(Save-FsBackup '10.0.2.5' 'Hikvision' $null (Join-Path $tmp 'bk2e'))
Check (Test-FsBackupComplete $bf 'Hikvision') 'a real-looking export + network + stream = complete'
# files handed in directly (not through Save-FsBackup): the content is still checked
$d2 = Join-Path $tmp 'bk2f'; New-Item -ItemType Directory -Force -Path $d2 | Out-Null
[IO.File]::WriteAllText((Join-Path $d2 'configurationData.bin'), $login); [IO.File]::WriteAllText((Join-Path $d2 'network.xml'), $net)
Check (-not (Test-FsBackupComplete @((Join-Path $d2 'configurationData.bin'), (Join-Path $d2 'network.xml')) 'Hikvision' -Nvr)) 'a login page already on disk under the right name -> NOT complete'
# Dahua
$script:Fake = @{ 'GET 10.0.2.9/cgi-bin/Config.backup*' = ('{"Dahua":1}' + (' ' * 1000)); 'GET 10.0.2.9/cgi-bin/configManager.cgi?action=getConfig&name=Network' = $login; 'GET 10.0.2.9/cgi-bin/configManager.cgi?action=getConfig&name=Encode' = 'table.Encode[0].MainFormat[0].Video.Width=1920' }
$bf = @(Save-FsBackup '10.0.2.9' 'Dahua' $null (Join-Path $tmp 'bk2g'))
Check (-not (Test-FsBackupComplete $bf 'Dahua')) 'reproduction: Dahua network settings answered with a login page -> NOT complete'
$script:Fake['GET 10.0.2.9/cgi-bin/configManager.cgi?action=getConfig&name=Network'] = 'table.Network.eth0.IPAddress=10.0.2.9'
$bf = @(Save-FsBackup '10.0.2.9' 'Dahua' $null (Join-Path $tmp 'bk2h'))
Check (Test-FsBackupComplete $bf 'Dahua') 'Dahua export + key=value settings = complete'
# Fix NVR firmware update: the export taken first is checked the same way (real module function)
$nm2 = Import-Module (Join-Path $tk 'modules\NvrHealth\NvrHealth.psm1') -Force -PassThru -DisableNameChecking
$f2 = Join-Path $tmp 'fw-login.bin'; [IO.File]::WriteAllText($f2, $login); $f3 = Join-Path $tmp 'fw-ok.bin'; [IO.File]::WriteAllText($f3, $goodBin)
Check ((& $nm2 { param($p) Test-NhBackupFile $p } $f2) -match 'login') 'reproduction: Fix NVR: a login page as the pre-update export is FAILED (the update does not run)'
Eq (& $nm2 { param($p) Test-NhBackupFile $p } $f3) '' 'Fix NVR: a real-looking export passes'
Remove-Module NvrHealth -Force -ErrorAction SilentlyContinue

#@@NEXT@@

} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ''; Write-Host ('Test-Fix224: ' + $script:pass + ' passed, ' + $script:fail + ' failed')
exit $script:fail
