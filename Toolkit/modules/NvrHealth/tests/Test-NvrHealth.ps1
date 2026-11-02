# Test-NvrHealth.ps1 - runs NvrHealth.psm1 against mock devices (tests\mock_devices.py). No real gear is touched.
# Usage (from the nvrhealth folder):  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-NvrHealth.ps1
param([int]$Port = 18190)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$py = (Get-Command python -ErrorAction SilentlyContinue).Source; if (-not $py) { $py = (Get-Command py -ErrorAction SilentlyContinue).Source }
if (-not $py) { throw 'Python 3 is needed for the mock devices.' }
$logs = Join-Path $env:TEMP ('nvrhealth-testlogs-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$mock = Start-Process -FilePath $py -ArgumentList @((Join-Path $here 'mock_devices.py'), $Port) -PassThru -NoNewWindow -RedirectStandardError (Join-Path $env:TEMP 'nvrhealth-mock.err')
$base = 'http://127.0.0.1:' + $Port
for ($i = 0; $i -lt 50; $i++) { try { Invoke-WebRequest ($base + '/mockctl/writes') -UseBasicParsing -TimeoutSec 2 | Out-Null; break } catch { Start-Sleep -Milliseconds 200 } }

$script:pass = 0; $script:fail = 0; $script:failed = @()
function Check([string]$name, [bool]$cond, $detail = '') { if ($cond) { $script:pass++; Write-Host ('PASS  ' + $name) } else { $script:fail++; $script:failed += $name; Write-Host ('FAIL  ' + $name + '  ' + $detail) -ForegroundColor Red } }
function Writes { return @((Invoke-WebRequest ($base + '/mockctl/writes') -UseBasicParsing).Content | ConvertFrom-Json) }
function Reset { Invoke-WebRequest ($base + '/mockctl/reset') -Method Post -UseBasicParsing | Out-Null }
function Cred([string]$pw) { New-Object System.Management.Automation.PSCredential('admin', (ConvertTo-SecureString $pw -AsPlainText -Force)) }   # test only
$good = Cred 'NvrPass#2026'; $wrong = Cred 'NotThePassword1'

try {
  Import-Module (Join-Path $root 'NvrHealth.psm1') -Force
  Set-NvrHealthOption MockUrl $base; Set-NvrHealthOption LogDir $logs; Set-NvrHealthOption ReferenceFile (Join-Path $root 'firmware-latest.json')

  Write-Host "`n=== vendor detection ==="
  $m = Get-Module NvrHealth
  Check 'detect Hikvision' ((& $m { Detect-Vendor '10.9.0.20' 0 }) -eq 'Hikvision')
  Check 'detect DW' ((& $m { Detect-Vendor '10.9.0.40' 0 }) -eq 'DW')
  Check 'detect Uniview' ((& $m { Detect-Vendor '10.9.0.50' 0 }) -eq 'Uniview')

  Write-Host "`n=== recording: healthy Hikvision NVR (1 camera offline) ==="
  Reset
  $r = Get-RecordingStatus -Ip 10.9.0.20 -Vendor Hikvision -Credential $good -TargetDays 45
  Check 'hik good: 4 channels' ($r.channels.Count -eq 4) $r.channels.Count
  Check 'hik good: 3 recording (incl. motion cam)' ($r.recording -eq 3) $r.recording
  Check 'hik good: days held 50 (deepest archive)' ($r.days_held -eq 50) $r.days_held
  Check 'hik good: shortest 48' ($r.shortest_days -eq 48) $r.shortest_days
  Check 'hik good: camera 4 flagged' (($r.problems -join ';') -match 'not recording: 4') ($r.problems -join ';')
  Check 'hik good: only that problem' ($r.problems.Count -eq 1) ($r.problems -join ';')
  Check 'hik good: 2 healthy drives with SMART' (@($r.disks | Where-Object { $_.smartOk -eq $true }).Count -eq 2)
  Check 'hik good: read-only (no writes)' ((Writes).Count -eq 0)

  Write-Host "`n=== recording: bad Hikvision NVR ==="
  $r = Get-RecordingStatus -Ip 10.9.0.30 -Vendor Hikvision -Credential $good -TargetDays 45
  $p = $r.problems -join ';'
  Check 'hik bad: SMART failing drive' ($p -match 'drive 1 failing') $p
  Check 'hik bad: drive 2 error' ($p -match 'drive 2 error') $p
  Check 'hik bad: short retention flagged' ($p -match 'only 20 of 45 days') $p
  Check 'hik bad: schedule-off camera flagged' ($p -match 'not recording: 1') $p
  Check 'hik bad: not ok' (-not $r.ok)

  Write-Host "`n=== recording: wrong password ==="
  $r = Get-RecordingStatus -Ip 10.9.0.60 -Vendor Hikvision -Credential $wrong
  Check 'wrong pw: refused, nothing checked' (($r.problems -join ';') -eq 'login refused') ($r.problems -join ';')

  Write-Host "`n=== recording: DW Spectrum ==="
  $r = Get-RecordingStatus -Ip 10.9.0.40 -Vendor DW -Credential $good -TargetDays 45
  Check 'dw: 2 cameras' ($r.channels.Count -eq 2)
  Check 'dw: 1 recording' ($r.recording -eq 1) $r.recording
  Check 'dw: days held 46' ($r.days_held -eq 46) $r.days_held
  Check 'dw: offline camera flagged' (($r.problems -join ';') -match 'not recording: 2') ($r.problems -join ';')
  Check 'dw: storage read' ($r.disks.Count -eq 1 -and $r.disks[0].capMB -gt 7000000)

  Write-Host "`n=== recording: Uniview via ONVIF ==="
  $r = Get-RecordingStatus -Ip 10.9.0.50 -Vendor Uniview -Credential $good -TargetDays 30
  Check 'unv: 2 recordings' ($r.channels.Count -eq 2)
  Check 'unv: days held 31' ($r.days_held -eq 31) $r.days_held
  $r2 = Get-RecordingStatus -Ip 10.9.0.50 -Vendor Uniview -Credential $good -TargetDays 45
  Check 'unv: short of 45 with unknown drive fill' (($r2.problems -join ';') -match 'only 31 of 45 days \(drive fill unknown\)') ($r2.problems -join ';')
  Check 'unv: stopped channel flagged' (($r.problems -join ';') -match 'not recording: 2') ($r.problems -join ';')

  Write-Host "`n=== clock ==="
  $c = Get-ClockStatus -Ip 10.9.0.20 -Vendor Hikvision -Credential $good -IncludeCameras
  Check 'clock good: ok' ($c.ok) ($c.problems -join ';')
  Check 'clock good: drift small' ([math]::Abs($c.drift_sec) -le 5) $c.drift_sec
  Check 'clock good: camera 10.9.0.21 checked, PoE 192.168.254.x skipped' ($c.cameras.Count -eq 1 -and $c.cameras[0].ip -eq '10.9.0.21') (($c.cameras | ForEach-Object { $_.ip }) -join ',')
  $c = Get-ClockStatus -Ip 10.9.0.30 -Vendor Hikvision -Credential $good
  $p = $c.problems -join ';'
  Check 'clock bad: ~7 min behind' ($c.drift_sec -le -400 -and $c.drift_sec -ge -440) $c.drift_sec
  Check 'clock bad: NTP off' ($p -match 'NTP off') $p
  Check 'clock bad: wrong time zone' ($p -match 'wrong time zone') $p
  $c = Get-ClockStatus -Ip 10.9.0.40 -Vendor DW -Credential $good
  Check 'clock dw: ok (Windows time, New York)' ($c.ok) ($c.problems -join ';')
  $c = Get-ClockStatus -Ip 10.9.0.50 -Vendor Uniview -Credential $good
  $p = $c.problems -join ';'
  Check 'clock unv: 1 h ahead, manual, GMT+8' (($c.drift_sec -ge 3590) -and ($p -match 'NTP off') -and ($p -match 'wrong time zone')) ($c.drift_sec.ToString() + ' ' + $p)
  Check 'clock checks are read-only' ((Writes).Count -eq 0)

  Write-Host "`n=== fix time (the only write) ==="
  $w = Set-NtpTime -Ip 10.9.0.30 -Vendor Hikvision -Credential $good -IncludeCameras -CameraIps 10.9.0.31 -WhatIf
  Check 'whatif: plans changes on NVR + camera' (@($w.devices | Where-Object { $_.result -eq 'what-if (not changed)' }).Count -eq 2) (($w.devices | ForEach-Object { $_.result }) -join ',')
  Check 'whatif: wrote nothing' ((Writes).Count -eq 0)
  Check 'whatif: plan still logged' ((Test-Path $w.log) -and ((Get-Content $w.log -Raw) -match 'time server -> time.nist.gov'))
  $w = Set-NtpTime -Ip 10.9.0.30 -Vendor Hikvision -Credential $good -IncludeCameras -CameraIps 10.9.0.31 -Confirm:$false
  $wr = Writes
  Check 'fix: 2 devices changed' ($w.changed -eq 2 -and $w.failed -eq 0) ($w.changed.ToString() + '/' + $w.failed)
  Check 'fix: NTP server written as time.nist.gov' (@($wr | Where-Object { $_.path -eq '/ISAPI/System/time/ntpServers/1' -and $_.body -match '<hostName>time.nist.gov</hostName>' -and $_.body -match '<synchronizeInterval>60</synchronizeInterval>' }).Count -eq 2)
  Check 'fix: Eastern + DST written' (@($wr | Where-Object { $_.path -eq '/ISAPI/System/time' -and $_.body -match 'CST\+5:00:00DST01:00:00,M3\.2\.0/02:00:00,M11\.1\.0/02:00:00' -and $_.body -match '<timeMode>NTP</timeMode>' }).Count -eq 2)
  Check 'fix: localTime not pushed' (@($wr | Where-Object { $_.body -match 'localTime' }).Count -eq 0)
  Check 'fix: clock rechecked ok afterwards' ($w.after -and $w.after.ok) ($w.after.problems -join ';')
  $logTxt = Get-Content $w.log -Raw
  Check 'fix: BEFORE and AFTER in log' (($logTxt -match 'BEFORE /ISAPI/System/time') -and ($logTxt -match 'AFTER /ISAPI/System/time'))
  $n = (Writes).Count
  $w2 = Set-NtpTime -Ip 10.9.0.30 -Vendor Hikvision -Credential $good -IncludeCameras -CameraIps 10.9.0.31 -Confirm:$false
  Check 'fix again: idempotent, skipped, zero writes' (((Writes).Count -eq $n) -and (@($w2.devices | Where-Object { $_.result -eq 'already right' }).Count -eq 2)) (($w2.devices | ForEach-Object { $_.result }) -join ',')
  $w = Set-NtpTime -Ip 10.9.0.20 -Vendor Hikvision -Credential $good -Confirm:$false
  Check 'fix on already-right NVR: no write' ($w.changed -eq 0 -and (Writes).Count -eq $n)
  $w = Set-NtpTime -Ip 10.9.0.50 -Vendor Uniview -Credential $good -Confirm:$false
  $wr = @(Writes | Where-Object { $_.ip -eq '10.9.0.50' })
  Check 'fix unv (ONVIF): SetNTP + SetSystemDateAndTime' ((@($wr | Where-Object { $_.path -eq 'SetNTP' -and $_.body -match 'time.nist.gov' }).Count -eq 1) -and (@($wr | Where-Object { $_.path -eq 'SetSystemDateAndTime' -and $_.body -match 'EST5EDT,M3.2.0,M11.1.0' }).Count -eq 1)) ($wr.Count)
  Check 'fix unv: rechecked ok' ($w.after -and $w.after.ok) ($w.after.problems -join ';')
  $w = Set-NtpTime -Ip 10.9.0.40 -Vendor DW -Credential $good -Confirm:$false
  Check 'fix dw: manual instructions only, no write' ($w.devices[0].result -match 'manual' -and @(Writes | Where-Object { $_.ip -eq '10.9.0.40' }).Count -eq 0)

  Write-Host "`n=== firmware ==="
  Reset
  $f = Get-FirmwareStatus -Ip 10.9.0.30 -Vendor Hikvision -Credential $good -IncludeCameras -CameraIps 10.9.0.31
  $rec = $f.devices | Where-Object { $_.label -eq 'Recorder' }
  Check 'fw bad NVR: CVE-2025-66177 found' ((@($rec.advisories | ForEach-Object { $_.id }) -contains 'CVE-2025-66177'))
  Check 'fw bad NVR: CVE-2024-29949 not applied to V4 firmware' (-not (@($rec.advisories | ForEach-Object { $_.id }) -contains 'CVE-2024-29949'))
  Check 'fw bad NVR: latest V5.04.088' ($rec.latest -match 'V5\.04\.088') $rec.latest
  $cam = $f.devices | Where-Object { $_.label -eq 'Camera 10.9.0.31' }
  Check 'fw G0 camera: old, no CVE' ($cam.verdict -eq 'old' -and $cam.advisories.Count -eq 0) $cam.verdict
  $f = Get-FirmwareStatus -Ip 10.9.0.20 -Vendor Hikvision -Credential $good -IncludeCameras
  Check 'fw good NVR + G2 camera: current' ((@($f.devices | Where-Object { $_.verdict -eq 'current' }).Count -eq 2) -and $f.ok) (($f.devices | ForEach-Object { $_.label + '=' + $_.verdict }) -join ',')
  $f = Get-FirmwareStatus -Ip 10.9.0.40 -Vendor DW -Credential $good -IncludeCameras
  $srv = $f.devices | Where-Object { $_.label -eq 'Server' }
  Check 'fw dw 6.1.0: both Nx CVEs, latest 6.1.2' (($srv.advisories.Count -eq 2) -and ($srv.latest -match '6\.1\.2')) ($srv.advisories.Count.ToString() + ' ' + $srv.latest)
  $f = Get-FirmwareStatus -Ip 10.9.0.50 -Vendor Uniview -Credential $good
  Check 'fw unv B3613 260918: current' ($f.devices[0].verdict -eq 'current') $f.devices[0].verdict
  Check 'firmware checks are read-only' ((Writes).Count -eq 0)

  Write-Host "`n=== combined + secrets ==="
  $h = Get-NvrHealth -Ip 10.9.0.20 -Vendor Hikvision -Credential $good -TargetDays 45 -Json (Join-Path $logs 'h.json')
  Check 'combined: json written' (Test-Path (Join-Path $logs 'h.json'))
  Check 'combined: recording problem surfaces' (-not $h.ok)
  $leak = @(Get-ChildItem $logs -Recurse -File | Where-Object { (Get-Content $_.FullName -Raw) -match 'NvrPass#2026|NotThePassword1' })
  Check 'no password in any log/json' ($leak.Count -eq 0) (($leak | ForEach-Object { $_.Name }) -join ',')
}
catch { $script:fail++; $script:failed += ('CRASH: ' + $_.Exception.Message + ' @ ' + $_.InvocationInfo.PositionMessage); Write-Host ('CRASH ' + $_.Exception.Message + "`n" + $_.InvocationInfo.PositionMessage + "`n" + $_.ScriptStackTrace) -ForegroundColor Red }
finally {
  if ($mock -and -not $mock.HasExited) { Stop-Process -Id $mock.Id -Force }
  Remove-Item $logs -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ("`nRESULT: " + $script:pass + ' passed, ' + $script:fail + ' failed')
if ($script:fail) { $script:failed | ForEach-Object { Write-Host (' - ' + $_) }; exit 1 }
