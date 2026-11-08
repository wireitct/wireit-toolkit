<#
 Test-FixIt.ps1 - Release C fix buttons against the MOCK devices only (modules\NvrHealth\tests\mock_devices.py). No real device is touched.
 Usage: powershell -ExecutionPolicy Bypass -File tests\Test-FixIt.ps1
#>
$ErrorActionPreference = 'Stop'
$tkDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $tkDir 'ToolkitCore.ps1')
$script:pass = 0; $script:fail = 0
function Check([string]$name, [bool]$ok, [string]$info = '') { if ($ok) { $script:pass++; Write-Output ('PASS ' + $name) } else { $script:fail++; Write-Output ('FAIL ' + $name + '  ' + $info) } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wireit-fixtest-' + (Get-Random)); New-Item -ItemType Directory -Force -Path $tmp | Out-Null
. (Join-Path $PSScriptRoot 'TestPython.ps1'); $py = Get-TestPython   # 2.2.5: a real Python, never the Windows Store stub
$mockPy = Join-Path $tkDir 'modules\NvrHealth\tests\mock_devices.py'; $fx = Join-Path $tkDir 'FixIt.ps1'
$tok = $null; $err = $null; [void][Management.Automation.Language.Parser]::ParseFile($fx, [ref]$tok, [ref]$err); Check 'parse FixIt.ps1' ($err.Count -eq 0) ($err | Out-String)
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $tkDir 'modules\NvrHealth\NvrFix.ps1'), [ref]$tok, [ref]$err); Check 'parse NvrFix.ps1' ($err.Count -eq 0) ($err | Out-String)
if (-not $py) { Check 'python for the mocks' $false; Write-Output ('RESULT ' + $script:pass + ' passed, ' + $script:fail + ' failed'); exit 1 }
$mp = 18192; $mb = 'http://127.0.0.1:' + $mp
$mock = Start-Process -FilePath $py -ArgumentList @($mockPy, $mp) -PassThru -WindowStyle Hidden
$logs = Join-Path $tmp 'logs'; $runs = Join-Path $tmp 'runs'
function W { $v = ((Invoke-WebRequest ($mb + '/mockctl/writes') -UseBasicParsing).Content | ConvertFrom-Json); foreach ($item in $v) { $item } }
function Fx([string]$fix, [string]$ip, [string]$ans, [string[]]$more = @()) {
  $o = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fx -Fix $fix -Ip $ip @more -RunsDir $runs -LogsDir $logs -MockUrl $mb -TestAnswer $ans -CloseAfter 0 -WaitSec 0 -Site WI-TEST 2>&1 | Out-String
  return @{ out = $o; j = (Read-TkJson (Join-Path $logs 'fix-last.json')); code = $LASTEXITCODE }
}
function Hist { $h = Join-Path $logs 'fix-history.txt'; if (Test-Path $h) { return @(Get-Content $h) }; return @() }
try {
  for ($i = 0; $i -lt 50; $i++) { try { Invoke-WebRequest ($mb + '/mockctl/writes') -UseBasicParsing -TimeoutSec 2 | Out-Null; break } catch { Start-Sleep -Milliseconds 200 } }
  $env:NVRCHECK_TEST_PW = 'NvrPass#2026'; $env:FIXIT_TEST_NEWPW = 'CamPass#2026'
  # 1 recording on (Hikvision NVR with camera 1 recording switched off)
  $x = Fx 'recording' '10.9.0.30' 'no'
  Check 'recording: answer "no" -> nothing written, no history' ((W).Count -eq 0 -and -not $x.j.ran -and @(Hist).Count -eq 0) $x.out
  $x = Fx 'recording' '10.9.0.30' 'yes'
  Check 'recording: lower-case "yes" is not YES' ((W).Count -eq 0 -and -not $x.j.ran) $x.out
  $x = Fx 'recording' '10.9.0.30' 'YES'
  $wr = @(W)
  Check 'recording: YES -> ONE write, track 101 Enable=true' ($wr.Count -eq 1 -and $wr[0].path -eq '/ISAPI/ContentMgmt/record/tracks/101' -and $wr[0].body -match '<Enable>true</Enable>') ($wr | ConvertTo-Json -Depth 4)
  Check 'recording: verified on, ONE history line' ($x.j.ok -and $x.j.ran -and @(Hist).Count -eq 1 -and @(Hist)[0] -match 'Recording turned back on: camera 1 \(10\.9\.0\.30\)') ($x.out + (@(Hist) -join '|'))
  Check 'recording: backup of the settings saved first' ($x.j.backup -and (Test-Path $x.j.backup) -and ((Get-Content $x.j.backup -Raw) -match '<Enable>false</Enable>'))
  $x = Fx 'recording' '10.9.0.30' 'YES'
  Check 'recording: already on -> no change, no new history' ((@(W).Count -eq 1) -and -not $x.j.ran -and @(Hist).Count -eq 1) $x.out
  # 2 restart (Uniview NVR stands in for a Uniview camera; Hikvision camera)
  Invoke-WebRequest ($mb + '/mockctl/reset') -Method Post -UseBasicParsing | Out-Null
  $x = Fx 'restart' '10.9.0.50' 'YES' @('-Vendor', 'Uniview')
  $wr = @(W)
  Check 'restart Uniview: one PUT Reboot, back, history' ($wr.Count -eq 1 -and $wr[0].path -eq '/LAPI/V1.0/System/Reboot' -and $x.j.ok -and @(Hist)[-1] -match 'restarted, back online') ($x.out + ($wr | ConvertTo-Json))
  $x = Fx 'restart' '10.9.0.50' 'YES' @('-Vendor', 'Uniview')
  Check 'restart: second one in the same hour refused, nothing sent' ((@(W).Count -eq 1) -and -not $x.j.ran -and $x.j.msg -match 'already restarted in the last hour') $x.out
  $x = Fx 'restart' '10.9.0.21' 'YES' @('-Vendor', 'Hikvision')
  $wr = @(W)
  Check 'restart Hikvision camera: PUT /ISAPI/System/reboot' ($wr.Count -eq 2 -and $wr[1].path -eq '/ISAPI/System/reboot' -and $x.j.ok) $x.out
  # 3 put a camera back on the NVR
  $x = Fx 'readd' '10.9.0.20' 'YES' @('-Vendor', 'Hikvision', '-Channel', '2', '-CameraIp', '192.168.254.9')
  Check 'readd: channel in use by an online camera -> refused, nothing sent' ((@(W).Count -eq 2) -and -not $x.j.ran -and $x.j.msg -match 'in use') $x.out
  $x = Fx 'readd' '10.9.0.20' 'YES' @('-Vendor', 'Hikvision', '-Channel', '4', '-CameraIp', '192.168.254.5')
  $wr = @(W)
  Check 'readd: offline channel 4 -> PUT channel 4, online, history' ($wr.Count -eq 3 -and $wr[2].path -eq '/ISAPI/ContentMgmt/InputProxy/channels/4' -and $x.j.ok -and @(Hist)[-1] -match 'put back on NVR channel 4, online') $x.out
  # 4 firmware: SHA-256 must match, settings exported first
  $fw = Join-Path $tmp 'IPC_TEST_FW.dav'; [IO.File]::WriteAllBytes($fw, [Text.Encoding]::ASCII.GetBytes('FIRMWARE-TEST-' + ('x' * 200)))
  $sha = (Get-FileHash $fw -Algorithm SHA256).Hash
  $x = Fx 'firmware' '10.9.0.21' 'YES' @('-Vendor', 'Hikvision', '-File', $fw, '-Sha256', ('0' * 64))
  Check 'firmware: wrong SHA-256 -> refused, nothing sent' ((@(W).Count -eq 3) -and -not $x.j.ran -and $x.j.msg -match 'does not match') $x.out
  $x = Fx 'firmware' '10.9.0.21' 'YES' @('-Vendor', 'Hikvision', '-File', $fw, '-Sha256', $sha.ToLower())
  $wr = @(W)
  Check 'firmware: right SHA-256 -> config exported, one PUT updateFirmware, new version' ($wr.Count -eq 4 -and $wr[3].path -eq '/ISAPI/System/updateFirmware' -and $x.j.ok -and (Test-Path $x.j.backup) -and @(Hist)[-1] -match 'V9\.9\.9') $x.out
  # 5 site password (typed twice in real use; weak refused)
  $env:FIXIT_TEST_NEWPW = 'short1'
  $x = Fx 'password' '10.9.0.21' 'YES' @('-Vendor', 'Hikvision')
  Check 'password: weak one refused, nothing sent' ((@(W).Count -eq 4) -and -not $x.j.ran -and $x.j.msg -match 'too weak') $x.out
  $env:FIXIT_TEST_NEWPW = 'NewSite#2027'
  $x = Fx 'password' '10.9.0.21' 'YES' @('-Vendor', 'Hikvision')
  $wr = @(W)
  Check 'password: set, new one logs in, history without the password' ($wr.Count -eq 5 -and $wr[4].path -eq '/ISAPI/Security/users/1' -and $x.j.ok -and (@(Hist) -join '') -notmatch 'NewSite') $x.out
  # 6 DW: give DW the camera's right password
  $env:FIXIT_TEST_NEWPW = 'CamPass#2026'
  $x = Fx 'dwpassword' '10.9.0.41' 'YES' @('-CameraIp', '10.9.1.29')
  $wr = @(W)
  Check 'dwpassword: PATCH the device, DW no longer Unauthorized' ($wr[-1].method -eq 'PATCH' -and $wr[-1].path -match '^/rest/v3/devices/' -and $x.j.ok -and @(Hist)[-1] -match 'DW now says Online') $x.out
  $lo = [int](((Invoke-WebRequest ('http://127.0.0.1:' + $mp + '/mockctl/logouts/10.9.0.41') -UseBasicParsing).Content | ConvertFrom-Json).logouts)
  Check '1.6.3 dwpassword: logged out of DW when the fix ends (DELETE session)' ($lo -ge 1) ('logouts=' + $lo)
  Check 'no password in any run log, backup or history' (-not (Select-String -Path (Join-Path $runs '*\*'), (Join-Path $runs '*\backup\*'), (Join-Path $logs '*') -Pattern 'NvrPass#2026', 'NewSite#2027', 'CamPass#2026' -SimpleMatch -Quiet -ErrorAction SilentlyContinue))
  Check 'one history line per fix that ran (7)' (@(Hist).Count -eq 7) (@(Hist) -join "`n")
} finally {
  Remove-Item Env:\NVRCHECK_TEST_PW, Env:\FIXIT_TEST_NEWPW -ErrorAction SilentlyContinue
  try { if ($mock -and -not $mock.HasExited) { Stop-Process -Id $mock.Id -Force } } catch {}
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output ('RESULT ' + $script:pass + ' passed, ' + $script:fail + ' failed')
if ($script:fail) { exit 1 }
