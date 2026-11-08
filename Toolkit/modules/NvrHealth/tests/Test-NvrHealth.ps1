# Test-NvrHealth.ps1 - runs NvrHealth.psm1 against mock devices (tests\mock_devices.py). No real gear is touched.
# Usage (from the nvrhealth folder):  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-NvrHealth.ps1
param([int]$Port = 18190)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
. (Join-Path $PSScriptRoot '..\..\..\tests\TestPython.ps1'); $py = Get-TestPython   # 2.2.5: a real Python, never the Windows Store stub
if (-not $py) { throw 'Python 3 is needed for the mock devices.' }
$logs = Join-Path $env:TEMP ('nvrhealth-testlogs-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$mock = Start-Process -FilePath $py -ArgumentList @((Join-Path $here 'mock_devices.py'), $Port) -PassThru -NoNewWindow -RedirectStandardError (Join-Path $env:TEMP 'nvrhealth-mock.err')
$base = 'http://127.0.0.1:' + $Port
for ($i = 0; $i -lt 50; $i++) { try { Invoke-WebRequest ($base + '/mockctl/writes') -UseBasicParsing -TimeoutSec 2 | Out-Null; break } catch { Start-Sleep -Milliseconds 200 } }

$script:pass = 0; $script:fail = 0; $script:failed = @()
function Check([string]$name, [bool]$cond, $detail = '') { if ($cond) { $script:pass++; Write-Host ('PASS  ' + $name) } else { $script:fail++; $script:failed += $name; Write-Host ('FAIL  ' + $name + '  ' + $detail) -ForegroundColor Red } }
function Writes { $v = (Invoke-WebRequest ($base + '/mockctl/writes') -UseBasicParsing).Content | ConvertFrom-Json; foreach ($item in $v) { $item } }
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
  $sf = @($r.streams.flags) -join ';'
  Check 'streams: 4 cameras audited' ($r.streams.checked -eq 4) $r.streams.checked
  Check 'streams: cam 2 bitrate 12 Mbps at 3.7 MP flagged' ($sf -match 'cam 2: main bitrate 12 Mbps is high for 3.7 MP') $sf
  Check 'streams: cam 3 sub-stream off flagged' ($sf -match 'cam 3: sub-stream off') $sf
  Check 'streams: cam 4 frame rate mismatch flagged (15 vs 20)' ($sf -match 'cam 4: 15 fps, the others run 20') $sf
  Check 'streams: cam 4 12 Mbps at 8 MP is fine' ($sf -notmatch 'cam 4: main bitrate') $sf
  Check 'streams: cam 1 clean' ($sf -notmatch 'cam 1:') $sf
  Check 'streams: report only (not a recording problem)' ($r.problems.Count -eq 1) ($r.problems -join ';')

  Write-Host "`n=== recording: bad Hikvision NVR ==="
  $r = Get-RecordingStatus -Ip 10.9.0.30 -Vendor Hikvision -Credential $good -TargetDays 45
  $p = $r.problems -join ';'
  Check 'hik bad: SMART failing drive' ($p -match 'drive 1 failing') $p
  Check 'hik bad: drive 2 error' ($p -match 'drive 2 error') $p
  Check 'hik bad: short retention flagged' ($p -match 'only 20 of 45 days') $p
  Check 'hik bad: schedule-off camera flagged' ($p -match 'not recording: 1') $p
  Check 'hik bad: not ok' (-not $r.ok)
  Check 'streams: bad NVR defaults all fine' ($r.streams.checked -eq 2 -and $r.streams.ok) (@($r.streams.flags) -join ';')

  Write-Host "`n=== recording: wrong password ==="
  $r = Get-RecordingStatus -Ip 10.9.0.60 -Vendor Hikvision -Credential $wrong
  Check 'wrong pw: refused, nothing checked' (($r.problems -join ';') -eq 'login refused') ($r.problems -join ';')

  Write-Host "`n=== recording: DW Spectrum ==="
  $r = Get-RecordingStatus -Ip 10.9.0.40 -Vendor DW -Credential $good -TargetDays 45
  Check 'dw: 2 cameras' ($r.channels.Count -eq 2)
  Check 'dw: 1 recording' ($r.recording -eq 1) $r.recording
  Check 'dw: days held 46' ($r.days_held -eq 46) $r.days_held
  Check 'dw: offline camera flagged' (($r.problems -join ';') -match 'not recording: Yard \(10\.9\.1\.12\)') ($r.problems -join ';')
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

  Write-Host "`n=== 1.6.1: skipped / refused login, unreadable clock (YKW Elm live test) ==="
  $none = New-Object System.Management.Automation.PSCredential('admin', (New-Object Security.SecureString))   # empty password = skip
  function Tries([string]$ip) { return [int](((Invoke-WebRequest ($base + '/mockctl/tries/' + $ip) -UseBasicParsing).Content | ConvertFrom-Json).tries) }
  function Auths([string]$ip) { return [int](((Invoke-WebRequest ($base + '/mockctl/auth/' + $ip) -UseBasicParsing).Content | ConvertFrom-Json).auth) }
  [void](Close-NvrSessions); Reset
  $h = Get-NvrHealth -Ip 10.9.0.40 -Vendor DW -Credential $wrong -TargetDays 45 -IncludeCameras
  Check '1.6.1 DW wrong password: ONE login try for recording + clock + firmware' ((Tries '10.9.0.40') -eq 1) ('tries=' + (Tries '10.9.0.40'))
  Check '1.6.1 DW wrong password: recording = login refused, no channels' ((($h.recording.problems) -join ';') -eq 'login refused' -and @($h.recording.channels).Count -eq 0) (($h.recording.problems) -join ';')
  Check '1.6.1 DW wrong password: clock NOT CHECKED, not "needs fixing"' ($h.clock.notChecked -and (($h.clock.problems) -join ';') -eq 'clock not checked' -and -not $h.clock.ok) (($h.clock.problems) -join ';')
  $sum = (Get-NvrHealthSummary) -join "`n"
  Check '1.6.1 DW wrong password: no "time needs fixing", summary says NOT CHECKED' ($sum -notmatch 'time needs fixing' -and $sum -match 'RESULT: Clock: not checked' -and $sum -match 'SUMMARY: recording NOT CHECKED \| time NOT CHECKED') $sum
  Reset
  $h = Get-NvrHealth -Ip 10.9.0.40 -Vendor DW -Credential $none -TargetDays 45 -IncludeCameras
  Check '1.6.1 DW empty password: NO login sent at all' ((Tries '10.9.0.40') -eq 0) ('tries=' + (Tries '10.9.0.40'))
  Check '1.6.1 DW empty password: recording = login skipped' ((($h.recording.problems) -join ';') -eq 'login skipped') (($h.recording.problems) -join ';')
  Check '1.6.1 DW empty password: server version still read (no login needed)' (@($h.firmware.devices).Count -ge 1) ''
  Reset
  $h = Get-NvrHealth -Ip 10.9.0.30 -Vendor Hikvision -Credential $none -TargetDays 45 -IncludeCameras
  Check '1.6.1 Hikvision empty password: no password-carrying request at all (NVR or cameras)' ((Auths '10.9.0.30') -eq 0 -and (Auths '10.9.0.31') -eq 0) ('auth=' + (Auths '10.9.0.30') + '/' + (Auths '10.9.0.31'))
  Check '1.6.1 Hikvision empty password: recording / clock / firmware all NOT CHECKED' ((($h.recording.problems) -join ';') -eq 'login skipped' -and $h.clock.notChecked -and $h.firmware.notChecked) ''
  Reset
  $h = Get-NvrHealth -Ip 10.9.0.60 -Vendor Hikvision -Credential $wrong -TargetDays 45 -IncludeCameras
  Check '1.6.1 Hikvision wrong password: ONE password try for the whole check' ((Auths '10.9.0.60') -le 1) ('auth=' + (Auths '10.9.0.60'))
  $c = Get-ClockStatus -Ip 10.9.0.40 -Vendor DW -Credential $none
  Check '1.6.1 clock alone, no login: not checked, nothing to fix' ($c.notChecked -and -not $c.ok -and (($c.problems) -join ';') -eq 'clock not checked') (($c.problems) -join ';')
  Check '1.6.1 skipped / refused checks are read-only' ((Writes).Count -eq 0)

  Write-Host "`n=== 1.6.2: log file busy (YKW Elm live test: 'being used by another process' stopped the check) ==="
  if (-not ('NhTestLock' -as [type])) { Add-Type -TypeDefinition 'using System;using System.IO;using System.Threading;public static class NhTestLock{public static void LockFor(string p,int ms){FileStream fs=new FileStream(p,FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None);Thread t=new Thread(()=>{Thread.Sleep(ms);fs.Dispose();});t.IsBackground=true;t.Start();}}' }
  $lf = Join-Path $logs 'busy-log.txt'; Set-NvrHealthOption LogFile $lf
  Reset
  [void](Get-RecordingStatus -Ip 10.9.0.20 -Vendor Hikvision -Credential $good -TargetDays 45)
  [NhTestLock]::LockFor($lf, 300); Start-Sleep -Milliseconds 30
  $err = $null; try { [void](Get-RecordingStatus -Ip 10.9.0.20 -Vendor Hikvision -Credential $good -TargetDays 45) } catch { $err = $_.Exception.Message }
  Start-Sleep -Milliseconds 400
  Check '1.6.2 log locked for 0.3 s: the check finishes (no "being used by another process")' ($null -eq $err) $err
  Check '1.6.2 log locked for 0.3 s: the lines still land in the same log' ((Get-Content $lf | Where-Object { $_ -match 'NvrHealth .* recording' }).Count -ge 2)
  $lf2 = Join-Path $logs 'held-log.txt'; Set-NvrHealthOption LogFile $lf2; Set-Content $lf2 'x'
  [NhTestLock]::LockFor($lf2, 6000); Start-Sleep -Milliseconds 30
  $sw = [Diagnostics.Stopwatch]::StartNew(); $err = $null
  try { $rr = Get-RecordingStatus -Ip 10.9.0.20 -Vendor Hikvision -Credential $good -TargetDays 45 } catch { $err = $_.Exception.Message }
  $sw.Stop()
  Check '1.6.2 log locked the whole time: the check still finishes with its real result' ($null -eq $err -and $rr -and $rr.check -eq 'recording') $err
  Check '1.6.2 log locked the whole time: the log carries on in held-log-2.txt' ((Test-Path (Join-Path $logs 'held-log-2.txt')) -and (Get-Content (Join-Path $logs 'held-log-2.txt') | Measure-Object).Count -ge 3)
  Check '1.6.2 log locked the whole time: no long stall (under 10 s)' ($sw.Elapsed.TotalSeconds -lt 10) ([int]$sw.Elapsed.TotalSeconds)
  Set-NvrHealthOption LogFile ''
  for ($q = 0; $q -lt 40; $q++) { try { $fs = [IO.File]::Open($lf2, 'Open', 'Read', 'None'); $fs.Dispose(); break } catch { Start-Sleep -Milliseconds 250 } }   # wait for the test lock to end

  Write-Host "`n=== 1.6.3: names, local times, camera clocks without a login, firmware noise, DW logout (YKW Elm 1.6.2 live run) ==="
  [void](Close-NvrSessions); Reset
  $r = Get-RecordingStatus -Ip 10.9.0.40 -Vendor DW -Credential $good -TargetDays 45
  $sum = (Get-NvrHealthSummary) -join "`n"
  Check '1.6.3 recording: DW camera named by DW name + IP, not its list number' ($sum -match 'PROBLEM Yard \(10\.9\.1\.12\): camera OFFLINE' -and $sum -match 'OK +Lobby \(10\.9\.1\.11\): recording' -and $sum -notmatch 'Camera 2 \(') $sum
  Check '1.6.3 recording: problems line lists names, no bare numbers' (($r.problems -join ';') -match '1 camera\(s\) not recording: Yard \(10\.9\.1\.12\)$|1 camera\(s\) not recording: Yard \(10\.9\.1\.12\);') ($r.problems -join ';')
  $yard = @($r.channels | Where-Object { $_.name -eq 'Yard' })[0]
  $locS = $yard.newest.ToLocalTime().ToString('MMM d h:mm tt', [Globalization.CultureInfo]::InvariantCulture); $utcS = $yard.newest.ToString('MMM d h:mm tt', [Globalization.CultureInfo]::InvariantCulture)
  Check '1.6.3 recording: last footage shown in local time (DW gives UTC)' ($sum -match [regex]::Escape('last footage ' + $locS) -and ($locS -eq $utcS -or $sum -notmatch [regex]::Escape('last footage ' + $utcS))) ('local=' + $locS + ' utc=' + $utcS)
  $m2 = Get-Module NvrHealth
  $tz = & $m2 { $u = New-Object DateTime(2026, 9, 10, 11, 15, 0, ([DateTimeKind]::Utc)); @((Fmt-Local $u), $u.ToLocalTime().ToString('MMM d h:mm tt', [Globalization.CultureInfo]::InvariantCulture), (Fmt-Local (New-Object DateTime(2026, 9, 10, 7, 15, 0)))) }
  Check '1.6.3 Fmt-Local: UTC -> this PC local; a recorder''s own local stamp stays as it is' ($tz[0] -eq $tz[1] -and $tz[2] -eq 'Sep 10 7:15 AM') ($tz -join ' | ')
  Check '1.6.3 DW: one login for the whole run, session kept' ((Tries '10.9.0.40') -eq 1) ('tries=' + (Tries '10.9.0.40'))
  $h = Get-NvrHealth -Ip 10.9.0.40 -Vendor DW -Credential $good -TargetDays 45 -IncludeCameras -FindIps @('10.9.1.21', '10.9.1.22', '10.9.1.23', '10.9.0.40')
  Check '1.6.3 DW good login: recording + clock + firmware share ONE login (was up to 3)' ((Tries '10.9.0.40') -eq 1) ('tries=' + (Tries '10.9.0.40'))
  $sum = (Get-NvrHealthSummary) -join "`n"
  Check '1.6.3 clock: Find-cameras list used, no "No cameras reachable"' ($sum -notmatch 'No cameras reachable' -and $sum -match 'Camera clocks: 3 camera\(s\) from the Find cameras list, read WITHOUT a login') $sum
  Check '1.6.3 clock: right camera = one summary OK line' ($sum -match 'OK +1 camera clock\(s\) correct') $sum
  Check '1.6.3 clock: wrong camera clock found (10 min ahead)' (@($h.clock.cameras | Where-Object { $_.ip -eq '10.9.1.22' -and -not $_.ok }).Count -eq 1 -and (($h.clock.problems) -join ';') -match 'camera 10\.9\.1\.22: clock 10 minutes ahead') (($h.clock.problems) -join ';')
  Check '1.6.3 clock: silent camera = not checked (1), not a problem' ($h.clock.cameras_not_checked -eq 1 -and $sum -match '1 camera\(s\) did not answer the no-login time read - not checked: 10\.9\.1\.23') $sum
  Check '1.6.3 clock: NO password sent to any camera (DW login never tried on a camera)' ((Auths '10.9.1.21') -eq 0 -and (Auths '10.9.1.22') -eq 0) ('auth=' + (Auths '10.9.1.21') + '/' + (Auths '10.9.1.22'))
  $pre = [int](((Invoke-WebRequest ($base + '/mockctl/preauth/10.9.1.21') -UseBasicParsing).Content | ConvertFrom-Json).preauth)
  Check '1.6.3 clock: camera read with the no-login ONVIF time call' ($pre -eq 1) ('preauth=' + $pre)
  Check '1.6.3 clock: DW camera drift -> camera page / DW, not "Fix time"' ($sum -match 'RESULT: camera clock\(s\) wrong' -and $sum -notmatch '"Fix time" \(Set-NtpTime\) fixes it') $sum
  $fwLines = @((Get-NvrHealthSummary) | Where-Object { $_ -match 'not in the reference list' })
  Check '1.6.3 firmware: at most ONE "not in the reference list" line' ($fwLines.Count -le 1) ($fwLines -join ' | ')
  $c = Get-ClockStatus -Ip 10.9.0.40 -Vendor DW -Credential $good -IncludeCameras -CameraIps @('10.9.1.21')
  Check '1.6.3 clock: camera IPs behind DW are read without a login too' ((Auths '10.9.1.21') -eq 0 -and @($c.cameras).Count -eq 1 -and $c.cameras[0].nologin) ''
  $w = Set-NtpTime -Ip 10.9.0.40 -Vendor DW -Credential $good -IncludeCameras -CameraIps @('10.9.1.22') -WhatIf
  Check '1.6.3 fix time: never touches a camera it has no password for' (@($w.devices | Where-Object { $_.ip -eq '10.9.1.22' }).Count -eq 0 -and (Auths '10.9.1.22') -eq 0) (($w.devices | ForEach-Object { $_.target + '=' + $_.result }) -join ',')
  $items = & $m2 { param($rf) $ref = Load-Reference $rf; @(1..40 | ForEach-Object { Judge-Firmware ('Camera 10.1.61.' + $_) ('IPC-NOT-LISTED-' + ($_ % 3)) 'V1.0' $ref -Quiet }) } (Join-Path $root 'firmware-latest.json')
  $before = @(Get-NvrHealthSummary).Count
  & $m2 { param($it) Write-FwUnlisted $it 5 } $items
  $new = @(Get-NvrHealthSummary | Select-Object -Skip $before)
  Check '1.6.3 firmware: 40 unlisted cameras -> one line "3 camera model(s) not in the reference list"' ($new.Count -eq 2 -and $new[0] -match 'CHECK +3 camera model\(s\) not in the reference list \(40 camera\(s\)' -and $new[1] -match '5 camera\(s\): DW does not report their firmware') ($new -join ' | ')
  Check '1.6.3 firmware: each unlisted camera still in the log' ((Get-ChildItem $logs -Recurse -File | Get-Content | Out-String) -match 'FW Camera 10\.1\.61\.40 IPC-NOT-LISTED-1') ''
  $lo = Close-NvrSessions
  Check '1.6.3 logout: DELETE session sent once at the end' ($lo -eq 1 -and ([int](((Invoke-WebRequest ($base + '/mockctl/logouts/10.9.0.40') -UseBasicParsing).Content | ConvertFrom-Json).logouts)) -eq 1) ('closed=' + $lo)
  Check '1.6.3 logout: a second call sends nothing more' ((Close-NvrSessions) -eq 0)
  Check '1.6.3 logout: session token never in a log' (-not @(Get-ChildItem $logs -Recurse -File | Where-Object { (Get-Content $_.FullName -Raw) -match 'vms-TESTTOKEN' }).Count)
  $none2 = New-Object System.Management.Automation.PSCredential('admin', (New-Object Security.SecureString))
  Reset; [void](Get-NvrHealth -Ip 10.9.0.40 -Vendor DW -Credential $none2 -TargetDays 45)
  Check '1.6.3 logout: nothing to log out after a skipped login' ((Close-NvrSessions) -eq 0)
  Check '1.6.3 checks + logout are read-only (no writes)' ((Writes).Count -eq 0)

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
