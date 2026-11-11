<# Test-Fix2219Nvr.ps1 - tests for WireIt Toolkit 2.2.19 (Nov 11 2026), the NvrHealth module part of Codex's review of 2.2.18
   (head a7ceac8, NO-GO): F04, F07, F14, F15, F22, plus the class sweep of the module (NvrHealth.psm1, NvrFix.ps1, NvrCheck):
   F04 re-add: the channel is read AGAIN after the YES; a channel that changed while waiting is not written; the backup is taken
       from that read. Twins: the same re-read / same-device check after YES in every other fix with a confirmation (restart,
       firmware, password, recording Hik + DW, DW password) and in the time fix (Set-NtpTime -Expect / re-plan after the OK).
   F07 firmware: the VERSION field alone is compared (not version + release date): a date-only read-back is NOT confirmed, a
       date-only "current version" is refused, the lost-answer branch too.
   F14 DW storage / footage answers must have DW's shape (one bad row = NOT CHECKED); twins in the other readers (Hik clips, Hik
       tracks, Hik SMART / drive status, DW camera status, Hik channel online, ONVIF recording information).
   F15 ONVIF GetNTP that failed = time server NOT CHECKED (no plan, no "was none"); twins: Uniview NTP, empty time mode.
   F22 restart limit: the restart is RESERVED (saved + read back) BEFORE it is sent; not saved = not restarted; a damaged
       record = unknown budget = no restart.
   Every check RUNS the real module functions with stand-ins for the device's web answers (as Codex's nvr.ps1 / readd.ps1 did).
   No real device is touched, so real-device behaviour is DEFERRED (never a pass). PS 5.1 or pwsh 7.
   FIX2219NVR_REPO (tests only) = run against another checkout (old-code proof: on 2.2.18 the finding checks FAIL). #>
$ErrorActionPreference = 'Stop'
$repo = $(if ($env:FIX2219NVR_REPO) { $env:FIX2219NVR_REPO } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) })
$tkDir = Join-Path $repo 'Toolkit'
$nhMod = Join-Path $tkDir 'modules/NvrHealth/NvrHealth.psm1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2219nvr-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + $more) } }
}
function Deferred([string]$name) { $script:deferred++; Write-Host ('DEFERRED ' + $name) }
foreach ($f in @($nhMod, (Join-Path $tkDir 'modules/NvrHealth/NvrFix.ps1'), (Join-Path $tkDir 'NvrCheck.ps1'), (Join-Path $tkDir 'FixIt.ps1'))) {
  $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$e); Check ($e.Count -eq 0) ('parses: ' + (Split-Path -Leaf $f)) ($e | Out-String)
}
$cred = New-Object PSCredential('admin', (ConvertTo-SecureString 'Review123' -AsPlainText -Force))
$newCred = New-Object PSCredential('admin', (ConvertTo-SecureString 'NewCam2026x' -AsPlainText -Force))
$script:n = 0
function InMod([scriptblock]$body, [object[]]$args2) {
  $script:n++
  $m = Import-Module $nhMod -Force -PassThru -DisableNameChecking
  try {
    & $m { param($ld) Set-NvrHealthOption LogDir $ld } (Join-Path $tmp ('logs' + $script:n))
    return (& $m $body @args2)
  } catch { return @{ threw = $_.Exception.Message } }
  finally { Remove-Module $m -Force -ErrorAction SilentlyContinue }
}
function J($o) { try { return ($o | ConvertTo-Json -Compress -Depth 5) } catch { return [string]$o } }
$blocker = Join-Path $tmp 'not-a-folder'; Set-Content -LiteralPath $blocker -Value 'x'

# a Hikvision device stand-in: deviceInfo (serial / MAC / version / date from $script:Dev), the NVR channel list from
# $script:Owner (channel 1), channel status from $script:Online; every PUT / POST is counted in $script:Writes
$hikStub = {
  function script:Http {
    param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '', [switch]$SecretTransport)
    $script:Reads++
    if ($script:Hook) { & $script:Hook $Method $Path }
    if ($OutFile) { [IO.File]::WriteAllBytes($OutFile, [byte[]](@(1..255) * 4)); return @{ code = 200; body = '' } }
    if ($Method -in @('PUT', 'POST', 'DELETE') -and $Path -ne '/ISAPI/ContentMgmt/search') {
      $script:Writes += ($Method + ' ' + $Path)
      if ($Path -like '/ISAPI/ContentMgmt/InputProxy/channels/*') { $script:Overwritten = $script:Owner; $script:Owner = $script:NewOwner }
      if ($script:PutAnswer) { return $script:PutAnswer }
      return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' }
    }
    if ($Path -eq '/ISAPI/System/deviceInfo') { $d = $script:Dev; return @{ code = 200; body = ('<DeviceInfo><deviceName>T</deviceName><model>DS-7608NI-K2</model><serialNumber>' + $d.sn + '</serialNumber><macAddress>' + $d.mac + '</macAddress><firmwareVersion>' + $d.ver + '</firmwareVersion><firmwareReleasedDate>' + $d.date + '</firmwareReleasedDate></DeviceInfo>') } }
    if ($Path -eq '/ISAPI/ContentMgmt/InputProxy/channels') {
      $c = $(if ($script:Owner) { '<InputProxyChannel><id>1</id><sourceInputPortDescriptor><addressingFormatType>ipaddress</addressingFormatType><ipAddress>' + $script:Owner + '</ipAddress></sourceInputPortDescriptor></InputProxyChannel>' } else { '' })
      return @{ code = 200; body = ('<InputProxyChannelList>' + $c + '</InputProxyChannelList>') }
    }
    if ($Path -eq '/ISAPI/ContentMgmt/InputProxy/channels/status') { return @{ code = 200; body = ('<InputProxyChannelStatusList><InputProxyChannelStatus><id>1</id><online>' + $script:Online + '</online></InputProxyChannelStatus></InputProxyChannelStatusList>') } }
    if ($Path -eq '/ISAPI/System/status') { return @{ code = 200; body = '<DeviceStatus><deviceUpTime>5000</deviceUpTime></DeviceStatus>' } }
    if ($Path -eq '/ISAPI/ContentMgmt/record/tracks') { return @{ code = 200; body = $script:Tracks } }
    if ($Path -like '/ISAPI/ContentMgmt/record/tracks/*') { return @{ code = 200; body = $script:Track } }
    return @{ code = 404; body = '' }
  }
}
$readd = {
  param($cred, $newCred, $stub, [string]$mode, [string]$dir)
  . ([scriptblock]::Create([string]$stub))
  $script:Dev = @{ sn = 'NVR1'; mac = 'AA:BB:CC:00:00:01'; ver = 'V4.1'; date = 'build 240101' }
  $script:Owner = ''; $script:NewOwner = '10.0.0.21'; $script:Overwritten = ''; $script:Online = 'true'; $script:Writes = @(); $script:Reads = 0; $script:Hook = $null
  if ($mode -in @('offline-used', 'online-during-yes')) { $script:Owner = '10.0.0.50'; $script:Online = 'false' }
  $conf = { 'YES' }
  if ($mode -eq 'owner-during-yes') { $conf = { $script:Owner = '10.0.0.99'; 'YES' } }
  if ($mode -eq 'online-during-yes') { $conf = { $script:Online = 'true'; 'YES' } }
  if ($mode -eq 'swap-during-yes') { $conf = { $script:Dev = @{ sn = 'OTHER9'; mac = 'AA:BB:CC:00:00:99'; ver = 'V4.1'; date = 'build 240101' }; 'YES' } }
  $r = Invoke-NvrFix -Fix readd -Ip '10.0.0.20' -Vendor Hikvision -Credential $cred -NewCredential $newCred -Channel 1 -CameraIp '10.0.0.21' -BackupDir $dir -Confirm $conf
  return @{ ok = [bool]$r.ok; ran = [bool]$r.ran; msg = [string]$r.msg; backup = [string]$r.backup; writes = @($script:Writes); overwritten = $script:Overwritten; owner = $script:Owner }
}

try {
# ==============================================================================================================================
Write-Host 'F04 re-add: the channel is read again after YES; a change while waiting = nothing written; backup = the state at the write'
$r = InMod $readd @($cred, $newCred, $hikStub, 'owner-during-yes', (Join-Path $tmp 'rd1'))
Check ($r.writes.Count -eq 0 -and -not $r.ok -and $r.owner -eq '10.0.0.99') 'F04 (Codex readd.ps1): channel 1 becomes live camera .99 while the YES prompt is open -> NO write, .99 keeps the channel, ok=false (2.2.18: PUT over .99, ok=true)' (J $r)
Check ($r.msg -match 'changed while waiting') 'F04: the result says the channel changed while waiting for YES' $r.msg
$r = InMod $readd @($cred, $newCred, $hikStub, 'online-during-yes', (Join-Path $tmp 'rd2'))
Check ($r.writes.Count -eq 0 -and -not $r.ok) 'F04 twin: replacing an OFFLINE camera - it comes back ONLINE while the YES prompt is open -> NO write (2.2.18: wrote over the live camera)' (J $r)
$r = InMod $readd @($cred, $newCred, $hikStub, 'swap-during-yes', (Join-Path $tmp 'rd3'))
Check ($r.writes.Count -eq 0 -and -not $r.ok) 'F04 twin (class A): a different NVR (other serial / MAC) answers at the address after YES -> NO write' (J $r)
$r = InMod $readd @($cred, $newCred, $hikStub, 'normal', (Join-Path $tmp 'rd4'))
$bk = Join-Path (Join-Path $tmp 'rd4') 'nvr-channels-at-write.xml'
Check ((Test-Path -LiteralPath $bk) -and $r.backup -eq $bk) 'F04: the backup the result names is the channel list read AFTER the YES (nvr-channels-at-write.xml), the exact state replaced (2.2.18: only the list read before the prompt)' (J $r)
Check ($r.ok -and $r.writes.Count -eq 1) 'control: nothing changes during the prompt -> the camera is put on the channel once, ok' (J $r)
$r = InMod $readd @($cred, $newCred, $hikStub, 'offline-used', (Join-Path $tmp 'rd5'))
Check ($r.writes.Count -eq 1 -and $r.overwritten -eq '10.0.0.50') 'control: a channel held by a camera that stays OFFLINE is still replaced after the re-check' (J $r)

# ------------------------------------------------------------------------------------------------------------------------------
Write-Host 'F04 twins: every other fix with a YES re-reads the device after the YES'
$other = {
  param($cred, $newCred, $stub, [string]$fix, [string]$dir, [string]$file, [string]$sha, [string]$state)
  . ([scriptblock]::Create([string]$stub))
  $script:Dev = @{ sn = 'DEV1'; mac = 'AA:BB:CC:00:00:01'; ver = 'V4.1'; date = 'build 240101' }
  $script:Owner = ''; $script:Online = 'true'; $script:Writes = @(); $script:Reads = 0; $script:Hook = $null
  $script:Tracks = '<TrackList><Track><id>101</id><Enable>false</Enable><TrackSchedule><ScheduleBlockList><ScheduleBlock><ScheduleAction><Record>true</Record></ScheduleAction></ScheduleBlock></ScheduleBlockList></TrackSchedule></Track></TrackList>'
  $script:Track = '<Track><id>101</id><Enable>false</Enable><TrackSchedule><ScheduleBlockList><ScheduleBlock><ScheduleAction><Record>true</Record></ScheduleAction></ScheduleBlock></ScheduleBlockList></TrackSchedule></Track>'
  $swap = { $script:Dev = @{ sn = 'OTHER9'; mac = 'AA:BB:CC:00:00:99'; ver = 'V4.1'; date = 'build 240101' }; 'YES' }
  $p = @{ Ip = '10.0.0.20'; Vendor = 'Hikvision'; Credential = $cred; BackupDir = $dir; Confirm = $swap; WaitSec = 1 }
  switch ($fix) {
    'restart' { $p.Fix = 'restart'; $p.StateFile = $state }
    'firmware' { $p.Fix = 'firmware'; $p.File = $file; $p.Sha256 = $sha }
    'firmware-ver' { $p.Fix = 'firmware'; $p.File = $file; $p.Sha256 = $sha; $p.Confirm = { $script:Dev = @{ sn = 'DEV1'; mac = 'AA:BB:CC:00:00:01'; ver = 'V4.2'; date = 'build 250101' }; 'YES' } }
    'password' { $p.Fix = 'password'; $p.NewCredential = $newCred }
    'recording' { $p.Fix = 'recording' }
    'recording-ok' { $p.Fix = 'recording'; $p.Confirm = { 'YES' } }
  }
  $r = Invoke-NvrFix @p
  return @{ ok = [bool]$r.ok; msg = [string]$r.msg; writes = @($script:Writes) }
}
$fwFile = Join-Path $tmp 'fw.dav'; [IO.File]::WriteAllBytes($fwFile, [byte[]](1..200)); $fwSha = (Get-FileHash -LiteralPath $fwFile -Algorithm SHA256).Hash
foreach ($fx in @('restart', 'firmware', 'password', 'recording')) {
  $r = InMod $other @($cred, $newCred, $hikStub, $fx, (Join-Path $tmp ('tw-' + $fx)), $fwFile, $fwSha, (Join-Path $tmp ('lim-' + $fx + '.json')))
  Check ($r.writes.Count -eq 0 -and -not $r.ok) ('F04 twin (class A+B): ' + $fx + ' - a different device answers after YES -> NO write (2.2.18: written)') (J $r)
}
$r = InMod $other @($cred, $newCred, $hikStub, 'firmware-ver', (Join-Path $tmp 'tw-fwv'), $fwFile, $fwSha, '')
Check ($r.writes.Count -eq 0 -and -not $r.ok) 'F04 twin (class B): firmware - the device reports another VERSION after YES than in the plan -> no upload' (J $r)
$r = InMod $other @($cred, $newCred, $hikStub, 'recording-ok', (Join-Path $tmp 'tw-rec'), $fwFile, $fwSha, '')
Check ((Test-Path -LiteralPath (Join-Path (Join-Path $tmp 'tw-rec') 'record-track-101-at-write.xml')) -and $r.writes.Count -eq 1) 'F04 twin (class B): Hik recording - the exact track replaced (read after YES) is backed up before its PUT' (J $r)

# DW recording / DW password: the camera list is read again after YES
$dwStub = {
  function script:Http {
    param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '', [switch]$SecretTransport)
    if ($Path -eq '/rest/v3/login/sessions' -and $Method -eq 'POST') { return @{ code = 200; body = '{"token":"tok1"}' } }
    if ($Method -in @('PATCH', 'PUT', 'POST', 'DELETE')) { $script:Writes += ($Method + ' ' + $Path); return @{ code = 200; body = '{}' } }
    if ($Path -like '/rest/v3/devices*') { return @{ code = 200; body = ('[{"id":"{c1}","name":"Cam 1","status":"' + $script:St + '","url":"http://' + $script:CamIp + '","mac":"AA:BB:CC:00:00:21","schedule":{"isEnabled":' + $script:Sched + '}}]') } }
    if ($Path -eq '/api/moduleInformation') { return @{ code = 200; body = '{"reply":{"version":"5.1.0","name":"DW"}}' } }
    return @{ code = 404; body = '' }
  }
}
$dwFix = {
  param($cred, $newCred, $stub, [string]$fix, [string]$dir)
  . ([scriptblock]::Create([string]$stub))
  $script:Writes = @(); $script:St = 'Online'; $script:CamIp = '10.0.0.21'; $script:Sched = 'false'
  $p = @{ Ip = '10.0.0.5'; Vendor = 'DW'; Credential = $cred; BackupDir = $dir; WaitSec = 0 }
  if ($fix -eq 'recording') { $p.Fix = 'recording'; $p.Confirm = { $script:Sched = 'true'; 'YES' } }
  else { $p.Fix = 'dwpassword'; $p.CameraIp = '10.0.0.21'; $p.NewCredential = $newCred; $p.Confirm = { $script:CamIp = '10.0.0.77'; 'YES' } }
  $r = Invoke-NvrFix @p
  return @{ ok = [bool]$r.ok; msg = [string]$r.msg; writes = @($script:Writes | Where-Object { $_ -notmatch 'login' }) }
}
$r = InMod $dwFix @($cred, $newCred, $dwStub, 'recording', (Join-Path $tmp 'dw1'))
Check ($r.writes.Count -eq 0) 'F04 twin (class B): DW recording - the camera was turned on by someone else while waiting for YES -> it is not written again' (J $r)
$r = InMod $dwFix @($cred, $newCred, $dwStub, 'dwpassword', (Join-Path $tmp 'dw2'))
Check ($r.writes.Count -eq 0 -and -not $r.ok) 'F04 twin (class A+B): DW password - the DW camera entry now points at another address after YES -> no password sent' (J $r)

# Set-NtpTime: the plan that was shown is the plan that is written
$clkStub = {
  function script:Http {
    param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '', [switch]$SecretTransport)
    if ($Method -in @('PUT', 'POST')) { $script:Writes += ($Method + ' ' + $Path); return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } }
    if ($Path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = ('<DeviceInfo><model>DS-7608NI</model><serialNumber>' + $script:Sn + '</serialNumber><macAddress>AA:BB:CC:00:00:01</macAddress><firmwareVersion>V4.1</firmwareVersion></DeviceInfo>') } }
    if ($Path -eq '/ISAPI/System/time') { $script:TimeReads++; $md = $(if ($script:TimeReads -gt $script:ManualReads) { 'NTP' } else { 'manual' }); return @{ code = 200; body = ('<Time><timeMode>' + $md + '</timeMode><localTime>2026-11-11T00:00:00-05:00</localTime><timeZone>CST+5:00:00DST01:00:00,M3.2.0/02:00:00,M11.1.0/02:00:00</timeZone></Time>') } }
    if ($Path -like '/ISAPI/System/time/ntpServers*') { return @{ code = 200; body = '<NTPServerList><NTPServer><id>1</id><addressingFormatType>hostname</addressingFormatType><hostName>time.nist.gov</hostName><portNo>123</portNo><synchronizeInterval>60</synchronizeInterval></NTPServer></NTPServerList>' } }
    return @{ code = 404; body = '' }
  }
}
$clk = {
  param($cred, $stub, [string]$mode)
  . ([scriptblock]::Create([string]$stub))
  $script:Writes = @(); $script:TimeReads = 0; $script:ManualReads = 99; $script:Sn = 'NVR1'
  Set-NvrHealthOption MockUrl 'http://127.0.0.1:9'
  $exp = $null
  if ($mode -eq 'expect-other') { $exp = @{ Recorder = @{ id = 'NVR1|AA:BB:CC:00:00:01'; changes = 'time server -> pool.ntp.org (was time.nist.gov)' } } }
  if ($mode -eq 'expect-otherdev') { $exp = @{ Recorder = @{ id = 'NVR7|AA:BB:CC:00:00:07'; changes = 'time mode -> NTP (was manual)' } } }
  if ($mode -eq 'flip') { $script:ManualReads = 1 }
  if ($mode -eq 'plain') { $script:ManualReads = 2 }
  $a = @{ Ip = '10.0.0.20'; Vendor = 'Hikvision'; Credential = $cred; NtpServer = 'time.nist.gov'; Confirm = $false; WhatIf = $false }
  if ($exp) { $a.Expect = $exp }
  $r = Set-NtpTime @a
  return @{ changed = [int]$r.changed; failed = [int]$r.failed; writes = @($script:Writes); rows = @($r.devices | ForEach-Object { $_.result }) }
}
$r = InMod $clk @($cred, $clkStub, 'expect-other')
Check ($r.writes.Count -eq 0 -and $r.failed -ge 1) 'F04 twin (Fix clock): the device now needs a different change than the plan the technician said YES to -> nothing written (2.2.18: wrote the new plan unseen)' (J $r)
$r = InMod $clk @($cred, $clkStub, 'expect-otherdev')
Check ($r.writes.Count -eq 0 -and $r.failed -ge 1) 'F04 twin (Fix clock, class A): a different device (serial) answers than the one in the confirmed plan -> nothing written' (J $r)
$r = InMod $clk @($cred, $clkStub, 'flip')
Check ($r.writes.Count -eq 0 -and $r.failed -ge 1) 'F04 twin (Fix clock, class B): the time settings change between the plan and the write -> re-read, nothing written (2.2.18: wrote from the first read)' (J $r)
$r = InMod $clk @($cred, $clkStub, 'plain')
Check ($r.changed -eq 1 -and $r.writes.Count -ge 1) 'control: Fix clock with nothing changing between plan and write still writes and reads back' (J $r)
$nvc = Get-Content -LiteralPath (Join-Path $tkDir 'NvrCheck.ps1') -Raw
Check ($nvc -match 'Set-NtpTime @common[^\r\n]*-Expect \$exp') 'F04 twin (NvrCheck FixClock): the YES run passes the plan that was shown (-Expect), so only that plan is written' ''

# ==============================================================================================================================
Write-Host 'F07 firmware: the VERSION field alone, non-empty and different'
$fw = {
  param($cred, $stub, [string]$mode, [string]$dir, [string]$file, [string]$sha)
  . ([scriptblock]::Create([string]$stub))
  $script:Dev = @{ sn = 'S1'; mac = 'AA:BB:CC:00:00:01'; ver = 'V4.1'; date = 'build 240101' }
  $script:Writes = @(); $script:Reads = 0; $script:PutAnswer = $null
  if ($mode -eq 'nover-before') { $script:Dev.ver = '' }
  $script:Hook = { param($m, $p) if ($m -eq 'PUT' -and $p -eq '/ISAPI/System/updateFirmware') { if ($script:Mode2 -eq 'lost') { $script:Dev = @{ sn = 'S1'; mac = 'AA:BB:CC:00:00:01'; ver = ''; date = 'build 250505' } } else { $script:Dev = @{ sn = 'S1'; mac = 'AA:BB:CC:00:00:01'; ver = ''; date = 'build 240101' } } } }
  $script:Mode2 = $mode
  if ($mode -eq 'lost') { $script:PutAnswer = @{ code = 0; body = '' } }
  $r = Invoke-NvrFix -Fix firmware -Ip '10.0.0.20' -Vendor Hikvision -Credential $cred -File $file -Sha256 $sha -BackupDir $dir -Confirm { 'YES' }
  return @{ ok = [bool]$r.ok; msg = [string]$r.msg; history = [string]$r.history; writes = @($script:Writes) }
}
$r = InMod $fw @($cred, $hikStub, 'empty-after', (Join-Path $tmp 'fw1'), $fwFile, $fwSha)
Check (-not $r.ok -and $r.msg -match 'NOT confirmed') 'F07 (Codex nvr.ps1): read-back has an EMPTY firmwareVersion and the old release date -> NOT confirmed (2.2.18: ok, "Updated: V4.1 build 240101 -> build 240101")' (J $r)
Check ($r.history -notmatch '->') 'F07: its history line does not say the version changed' $r.history
$r = InMod $fw @($cred, $hikStub, 'nover-before', (Join-Path $tmp 'fw2'), $fwFile, $fwSha)
Check (-not $r.ok -and $r.writes.Count -eq 0) 'F07 twin: the device gives only a release date as its current firmware (no version) -> refused before the upload (2.2.18: "build 240101" passed the no-version guard)' (J $r)
$r = InMod $fw @($cred, $hikStub, 'lost', (Join-Path $tmp 'fw3'), $fwFile, $fwSha)
Check (-not $r.ok) 'F07 twin: answer lost, then the device reads back NO version and a NEW date -> NOT confirmed (2.2.18: "Updated" from the date change)' (J $r)
$st = {
  param($cred, $stub)
  . ([scriptblock]::Create([string]$stub))
  $script:Dev = @{ sn = 'S1'; mac = 'AA:BB:CC:00:00:01'; ver = ''; date = 'build 240101' }; $script:Writes = @(); $script:Hook = $null
  $d = Hik-DeviceInfo @{ ip = '10.0.0.20'; vendor = 'Hikvision'; cred = $cred; port = 0 }
  return @{ version = [string]$d.version; released = [string]$d.released; firmware = [string]$d.firmware }
}
$r = InMod $st @($cred, $hikStub)
Check ($r.version -eq '' -and $r.released -eq 'build 240101') 'F07: Hik-DeviceInfo keeps the firmware version (empty here) apart from the release date' (J $r)

# ==============================================================================================================================
Write-Host 'F14 DW storage / footage: answers must have the DW shape, one bad row = NOT CHECKED'
$dwr = {
  param([string]$what)
  function script:Http { param($Ip, $Method = 'GET', $Path, $Credential, $Port, $Timeout, $OutFile, $BodyBytes, $ContentType, $Body, $Headers, [switch]$NoLogBody, $Scheme)
    if ($Path -eq '/rest/v3/servers/this/storages/*/status') { return @{ code = 500; body = '' } }
    if ($Path -eq '/api/storageSpace') { return @{ code = 200; body = $script:Legacy } }
    if ($Path -like '/ec2/recordedTimePeriods*') { return @{ code = 200; body = $script:Periods } }
    return @{ code = 404; body = '' }
  }
  $t = @{ ip = '10.0.0.20'; port = 7001; token = 'test' }
  $script:Legacy = '{"reply":{"storages":[{"error":"busy"}]}}'; $script:Periods = '{"error":"busy"}'
  if ($what -eq 'mixed') { $script:Legacy = '{"error":"0","reply":{"storages":[{"url":"D:\\","totalSpace":"8000000000","freeSpace":"1","isOnline":true},{"error":"busy"}]}}' }
  if ($what -eq 'good') { $script:Legacy = '{"error":"0","reply":{"storages":[{"url":"D:\\","totalSpace":"8000000000","freeSpace":"1000","isOnline":true}]}}'; $script:Periods = '[{"startTimeMs":1700000000000,"durationMs":3600000},{"startTimeMs":1700003600000,"durationMs":-1}]' }
  if ($what -eq 'noonline') { $script:Legacy = '{"error":"0","reply":{"storages":[{"url":"D:\\","totalSpace":"8000000000","freeSpace":"1000"}]}}' }
  if ($what -eq 'badrow') { $script:Periods = '[{"startTimeMs":1700000000000,"durationMs":3600000},{"error":"busy"}]' }
  $s = Dw-Storage $t
  $script:NhDwPeriodsFailed = $false; $p = Dw-Periods $t 'cam1' ([datetime]::UtcNow)
  return @{ ok = [bool]$s.ok; disks = @($s.disks).Count; status = $(if (@($s.disks).Count) { [string]@($s.disks)[0].status } else { '' }); why = [string]$s.why; pFailed = [bool]$script:NhDwPeriodsFailed; p = $(if ($p) { 'periods' } else { 'none' }) }
}
$r = InMod $dwr @('busy')
Check (-not $r.ok) 'F14 (Codex nvr.ps1): v3 storage 500 + legacy {"reply":{"storages":[{"error":"busy"}]}} -> storage NOT CHECKED (2.2.18: ok, no disks = "No hard drive found")' (J $r)
Check ($r.pFailed) 'F14 (Codex nvr.ps1): recordedTimePeriods {"error":"busy"} -> footage list could NOT be read (2.2.18: NhDwPeriodsFailed=false = "no footage")' (J $r)
$r = InMod $dwr @('mixed')
Check (-not $r.ok) 'F14 twin: a legacy list with one good drive and one bad row -> NOT CHECKED (2.2.18: the bad row was skipped silently)' (J $r)
$r = InMod $dwr @('badrow')
Check ($r.pFailed) 'F14 twin: a period list with a row that has no start time -> footage NOT CHECKED (2.2.18: row dropped)' (J $r)
$r = InMod $dwr @('noonline')
Check ($r.ok -and $r.status -eq 'unknown') 'F14 twin (class C): a DW drive row with no isOnline is status unknown, never "ok" / healthy' (J $r)
$r = InMod $dwr @('good')
Check ($r.ok -and $r.disks -eq 1 -and $r.status -eq 'ok' -and -not $r.pFailed -and $r.p -eq 'periods') 'control: a real legacy storage list and a real period list still read (1 drive ok, footage found)' (J $r)

# whole recording check (DW): what the technician reads
$dwRec = {
  param($cred, [string]$mode)
  function script:Http { param($Ip, $Method = 'GET', $Path, $Credential, $Port, $Timeout, $OutFile, $BodyBytes, $ContentType, $Body, $Headers, [switch]$NoLogBody, $Scheme)
    if ($Path -eq '/rest/v3/login/sessions') { return @{ code = 200; body = '{"token":"tok1"}' } }
    if ($Path -eq '/api/moduleInformation') { return @{ code = 200; body = '{"reply":{"version":"5.1.0","name":"DW"}}' } }
    if ($Path -eq '/api/gettime') { return @{ code = 200; body = ('{"reply":{"utcTime":' + [long]([DateTime]::UtcNow - (New-Object DateTime(1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)))).TotalMilliseconds + ',"timezoneId":"America/New_York"}}') } }
    if ($Path -like '/rest/v3/devices*') { return @{ code = 200; body = ('[{"id":"{c1}","name":"Cam 1","status":"' + $script:St + '","url":"http://10.0.0.21","schedule":{"isEnabled":true}}]') } }
    if ($Path -eq '/rest/v3/servers/this/storages/*/status') { return @{ code = 500; body = '' } }
    if ($Path -eq '/api/storageSpace') { return @{ code = 200; body = '{"reply":{"storages":[{"error":"busy"}]}}' } }
    if ($Path -like '/ec2/recordedTimePeriods*') { return @{ code = 200; body = '{"error":"busy"}' } }
    return @{ code = 404; body = '' }
  }
  $script:St = $(if ($mode -eq 'nostatus') { '' } else { 'Online' })
  $r = Get-RecordingStatus -Ip '10.0.0.5' -Vendor DW -Credential $cred -TargetDays 30 -NoLog
  return @{ ok = [bool]$r.ok; problems = @($r.problems); say = @(Get-NvrHealthSummary) -join ' | ' }
}
$r = InMod $dwRec @($cred, 'normal')
Check (-not @($r.problems | Where-Object { $_ -match 'no hard drive|not recording' }).Count -and @($r.problems | Where-Object { $_ -match 'NOT CHECKED' }).Count -ge 2) 'F14 (end to end): DW recording check with both malformed answers -> storage NOT CHECKED + footage NOT CHECKED, never "no hard drive" / "NO footage"' (@($r.problems) -join '; ')
$r = InMod $dwRec @($cred, 'nostatus')
Check ($r.say -notmatch 'camera OFFLINE') 'F14 twin (class C): a DW camera with no status is not reported "camera OFFLINE"' $r.say

# Hikvision readers
$hikRd = {
  param($cred, [string]$what)
  function script:Http { param($Ip, $Method = 'GET', $Path, $Credential, $Port, $Timeout, $OutFile, $BodyBytes, $ContentType, $Body, $Headers, [switch]$NoLogBody, $Scheme)
    if ($Path -eq '/ISAPI/ContentMgmt/search') { return @{ code = 200; body = '<CMSearchResult><responseStatusStrg>OK</responseStatusStrg><matchList><searchMatchItem><timeSpan><startTime>garbage</startTime><endTime>garbage</endTime></timeSpan></searchMatchItem></matchList></CMSearchResult>' } }
    if ($Path -eq '/ISAPI/ContentMgmt/record/tracks') { return @{ code = 200; body = '<TrackList><Track><id>101</id><Enable>true</Enable><TrackSchedule><ScheduleBlockList><ScheduleBlock><ScheduleAction><Record>true</Record></ScheduleAction></ScheduleBlock></ScheduleBlockList></TrackSchedule></Track><Track><id></id><Enable>false</Enable></Track></TrackList>' } }
    if ($Path -eq '/ISAPI/ContentMgmt/Storage') { return @{ code = 200; body = '<storage><hddList><hdd><id>1</id><capacity>4000000</capacity><freeSpace>0</freeSpace><status>ok</status></hdd><hdd><id>2</id><capacity>4000000</capacity><freeSpace>0</freeSpace></hdd></hddList></storage>' } }
    if ($Path -like '/ISAPI/ContentMgmt/Storage/hdd/*/SMARTTest/status') { return @{ code = 200; body = '<SMARTTestStatus><temprature>40</temprature></SMARTTestStatus>' } }
    if ($Path -eq '/ISAPI/ContentMgmt/InputProxy/channels') { return @{ code = 200; body = '<InputProxyChannelList><InputProxyChannel><id>1</id><sourceInputPortDescriptor><ipAddress>10.0.0.21</ipAddress></sourceInputPortDescriptor></InputProxyChannel></InputProxyChannelList>' } }
    if ($Path -eq '/ISAPI/ContentMgmt/InputProxy/channels/status') { return @{ code = 200; body = '<InputProxyChannelStatusList><InputProxyChannelStatus><id>1</id><online>maybe</online></InputProxyChannelStatus></InputProxyChannelStatusList>' } }
    return @{ code = 404; body = '' }
  }
  $t = @{ ip = '10.0.0.20'; vendor = 'Hikvision'; cred = $cred; port = 0 }
  switch ($what) {
    'search' { $s = Hik-Search $t 101 ((Get-Date).AddDays(-1)) (Get-Date) 10; return @{ isNull = ($null -eq $s) } }
    'tracks' { $rt = Hik-ReadTracks $t; return @{ ok = [bool]$rt.ok; n = $rt.map.Count } }
    'storage' { $s = Hik-Storage $t; return @{ smart = $(if ($null -eq @($s.disks)[0].smartOk) { 'unknown' } else { [string]@($s.disks)[0].smartOk }); st2 = [string]@($s.disks)[1].status } }
    'channels' { $c = Hik-ReadChannels $t; return @{ online = $(if ($null -eq @($c.list)[0].online) { 'unknown' } else { [string]@($c.list)[0].online }) } }
  }
}
$r = InMod $hikRd @($cred, 'search')
Check ($r.isNull) 'F14 twin (Hik clips): a search answer whose clip has no readable start time = search failed (NOT CHECKED), not "no clips" (2.2.18: clip dropped -> no footage)' (J $r)
$r = InMod $hikRd @($cred, 'tracks')
Check (-not $r.ok) 'F14 twin (Hik tracks): a recording list with a track that has no readable id = list NOT read (2.2.18: that camera silently left out)' (J $r)
$r = InMod $hikRd @($cred, 'storage')
Check ($r.smart -eq 'unknown') 'F14 twin (Hik SMART): a SMART answer with no self-test result = SMART unknown, never "SMART ok" (2.2.18: ok)' (J $r)
$r = InMod $hikRd @($cred, 'channels')
Check ($r.online -eq 'unknown') 'F14 twin (Hik channel status): online "maybe" (not true/false) = unknown, never "offline" (2.2.18: false = camera OFFLINE)' (J $r)
$hikDisk = {
  param($cred)
  function script:Http { param($Ip, $Method = 'GET', $Path, $Credential, $Port, $Timeout, $OutFile, $BodyBytes, $ContentType, $Body, $Headers, [switch]$NoLogBody, $Scheme)
    if ($Path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = '<DeviceInfo><model>DS-7608NI</model><serialNumber>S1</serialNumber><firmwareVersion>V4.1</firmwareVersion></DeviceInfo>' } }
    if ($Path -eq '/ISAPI/ContentMgmt/Storage') { return @{ code = 200; body = '<storage><hddList><hdd><id>1</id><capacity>4000000</capacity><freeSpace>0</freeSpace></hdd></hddList></storage>' } }
    if ($Path -eq '/ISAPI/ContentMgmt/InputProxy/channels') { return @{ code = 200; body = '<InputProxyChannelList></InputProxyChannelList>' } }
    if ($Path -eq '/ISAPI/ContentMgmt/InputProxy/channels/status') { return @{ code = 200; body = '<InputProxyChannelStatusList></InputProxyChannelStatusList>' } }
    if ($Path -eq '/ISAPI/ContentMgmt/record/tracks') { return @{ code = 200; body = '<TrackList></TrackList>' } }
    return @{ code = 404; body = '' }
  }
  $r = Get-RecordingStatus -Ip '10.0.0.20' -Vendor Hikvision -Credential $cred -TargetDays 30 -NoLog
  return @{ problems = @($r.problems) }
}
$r = InMod $hikDisk @($cred)
Check (@($r.problems | Where-Object { $_ -match 'drive 1 status NOT CHECKED' }).Count -eq 1) 'F14 twin (Hik drive status): a drive with no status in the answer = that drive NOT CHECKED, not a "status """ fault' (@($r.problems) -join '; ')

# ONVIF recordings: recording information that failed = footage NOT CHECKED
$onvRec = {
  param($cred)
  function script:Onvif-Call { param($t, $path, $inner, $ns)
    if ($inner -match 'GetServices') { return @{ code = 200; body = '<Envelope><Body><GetServicesResponse><Service><Namespace>http://www.onvif.org/ver10/recording/wsdl</Namespace><XAddr>http://x/onvif/recording</XAddr></Service><Service><Namespace>http://www.onvif.org/ver10/search/wsdl</Namespace><XAddr>http://x/onvif/search</XAddr></Service></GetServicesResponse></Body></Envelope>' } }
    if ($inner -match 'GetRecordings') { return @{ code = 200; body = '<Envelope><Body><GetRecordingsResponse><RecordingItem><RecordingToken>R1</RecordingToken><Configuration><Source><Name>Cam1</Name></Source></Configuration></RecordingItem></GetRecordingsResponse></Body></Envelope>' } }
    if ($inner -match 'GetRecordingInformation') { return @{ code = 500; body = '' } }
    return @{ code = 500; body = '' }
  }
  $r = Get-RecordingStatus -Ip '10.0.0.30' -Vendor Onvif -Credential $cred -TargetDays 30 -NoLog
  return @{ problems = @($r.problems); say = (@(Get-NvrHealthSummary) -join ' | ') }
}
$r = InMod $onvRec @($cred)
Check ($r.say -notmatch 'NO footage found at all' -and @($r.problems | Where-Object { $_ -match 'footage NOT CHECKED' }).Count) 'F14 twin (ONVIF): GetRecordingInformation failed -> footage NOT CHECKED, not "NO footage found at all"' (@($r.problems) -join '; ')

# ==============================================================================================================================
Write-Host 'F15 ONVIF time server: a failed GetNTP is "could not read", never "none"'
$onv = {
  param([string]$mode)
  function script:Onvif-Call { param($t, $path, $inner, $ns)
    if ($inner -match 'GetNTP') { if ($script:M -eq 'good') { return @{ code = 200; body = '<Envelope><Body><GetNTPResponse><NTPInformation><FromDHCP>false</FromDHCP><NTPManual><Type>DNS</Type><DNSname>time.nist.gov</DNSname></NTPManual></NTPInformation></GetNTPResponse></Body></Envelope>' } }; return @{ code = 500; body = '' } }
    $md = $(if ($script:M -eq 'nomode') { '' } else { '<DateTimeType>NTP</DateTimeType>' })
    return @{ code = 200; body = ('<Envelope><SystemDateAndTime>' + $md + '<DaylightSavings>true</DaylightSavings><TimeZone><TZ>EST5EDT,M3.2.0,M11.1.0</TZ></TimeZone><UTCDateTime><Time><Hour>12</Hour><Minute>0</Minute><Second>0</Second></Time><Date><Year>2026</Year><Month>11</Month><Day>11</Day></Date></UTCDateTime></SystemDateAndTime></Envelope>') }
  }
  $script:M = $mode
  $p = Onvif-NtpPlan @{ ip = '10.0.0.20' } 'time.nist.gov'
  $c = Clock-Of @{ ip = '10.0.0.20'; vendor = 'Onvif' }
  $ref = @{ utc = $c.utc; source = 'test' }
  $probs = @(Judge-Clock 'Recorder' $c $ref)
  return @{ ok = [bool]$p.ok; changes = @($p.changes); needNtp = $p.needNtp; probs = $probs }
}
$r = InMod $onv @('fail')
Check (-not $r.ok -and -not @($r.changes | Where-Object { $_ -match 'was none' }).Count) 'F15 (Codex nvr.ps1): valid time + GetNTP HTTP 500 -> NO plan (2.2.18: ok, "time server -> time.nist.gov (was none)")' (J $r)
Check (@($r.probs | Where-Object { $_ -match 'not checked' }).Count -and -not @($r.probs | Where-Object { $_ -eq 'no NTP server' }).Count) 'F15 twin: the clock check says time server NOT CHECKED, not "no NTP server"' (@($r.probs) -join '; ')
$r = InMod $onv @('nomode')
Check (-not $r.ok -and -not @($r.probs | Where-Object { $_ -eq 'NTP off' }).Count) 'F15 twin (class C): no time mode in the ONVIF answer -> no plan and not "NTP off" / set by hand' (J $r)
$r = InMod $onv @('good')
Check ($r.ok -and -not $r.needNtp -and -not @($r.probs | Where-Object { $_ -match 'NTP|time server' }).Count) 'control: a GetNTP that WAS read with time.nist.gov -> no time-server change, no time-server problem' (J $r)
$unv = {
  function script:Http { param($Ip, $Method = 'GET', $Path, $Credential, $Port, $Timeout, $OutFile, $BodyBytes, $ContentType, $Body, $Headers, [switch]$NoLogBody, $Scheme)
    return @{ code = 200; body = '{"Response":{"ResponseCode":5,"ResponseString":"busy","Data":{"Enabled":1,"NTPServerInfos":[]}}}' }
  }
  $u = Unv-Ntp @{ ip = '10.0.0.40'; vendor = 'Uniview'; cred = (New-Object PSCredential('admin', (ConvertTo-SecureString 'x' -AsPlainText -Force))); port = 0 }
  return @{ isNull = ($null -eq $u) }
}
$r = InMod $unv @()
Check ($r.isNull) 'F15 twin (Uniview): an NTP answer with ResponseCode 5 (not success) is "could not read", not an empty server list' (J $r)
$hikMode = {
  param($cred)
  function script:Http { param($Ip, $Method = 'GET', $Path, $Credential, $Port, $Timeout, $OutFile, $BodyBytes, $ContentType, $Body, $Headers, [switch]$NoLogBody, $Scheme)
    if ($Path -eq '/ISAPI/System/time') { return @{ code = 200; body = '<Time><localTime>2026-11-11T00:00:00-05:00</localTime><timeZone>CST+5:00:00DST01:00:00,M3.2.0/02:00:00,M11.1.0/02:00:00</timeZone></Time>' } }
    if ($Path -like '/ISAPI/System/time/ntpServers*') { return @{ code = 200; body = '<NTPServerList><NTPServer><id>1</id><addressingFormatType>hostname</addressingFormatType><hostName>time.nist.gov</hostName></NTPServer></NTPServerList>' } }
    return @{ code = 404; body = '' }
  }
  $p = Hik-NtpPlan @{ ip = '10.0.0.20'; vendor = 'Hikvision'; cred = $cred; port = 0 } 'time.nist.gov'
  return @{ ok = [bool]$p.ok; changes = @($p.changes) }
}
$r = InMod $hikMode @($cred)
Check (-not $r.ok) 'F15 twin (Hik): the time answer has no timeMode -> no plan (2.2.18: planned "time mode -> NTP (was )")' (J $r)

# ==============================================================================================================================
Write-Host 'F22 restart limit: reserved on disk BEFORE the restart; not saved = not restarted'
$rst = {
  param($cred, $stub, [string]$state, [string]$dir, [string]$mode)
  . ([scriptblock]::Create([string]$stub))
  $script:Dev = @{ sn = 'CAM1'; mac = 'AA:BB:CC:00:00:21'; ver = 'V5.5'; date = 'build 240101' }; $script:Writes = @(); $script:Reads = 0; $script:PutAnswer = $null
  $script:StateAtPut = $null; $script:State = $state
  $script:Hook = { param($m, $p) if ($m -eq 'PUT' -and $p -eq '/ISAPI/System/reboot') { $script:StateAtPut = $(if (Test-Path -LiteralPath $script:State -PathType Leaf) { Get-Content -LiteralPath $script:State -Raw } else { '' }) } }
  if ($mode -eq 'refuse') { $script:PutAnswer = @{ code = 200; body = '<ResponseStatus><statusCode>4</statusCode><statusString>Invalid Operation</statusString></ResponseStatus>' } }
  $r = Invoke-NvrFix -Fix restart -Ip '10.0.0.21' -Vendor Hikvision -Credential $cred -StateFile $state -BackupDir $dir -Confirm { 'YES' } -WaitSec 1
  $after = $(if (Test-Path -LiteralPath $state -PathType Leaf) { Get-Content -LiteralPath $state -Raw } else { '' })
  return @{ ok = [bool]$r.ok; msg = [string]$r.msg; writes = @($script:Writes); atPut = [string]$script:StateAtPut; after = $after }
}
$r = InMod $rst @($cred, $hikStub, (Join-Path $blocker 'fix-limits.json'), (Join-Path $tmp 'rs1'), 'normal')
Check ($r.writes.Count -eq 0 -and -not $r.ok) 'F22 (Codex nvr.ps1, end to end): the restart record cannot be saved -> the camera is NOT restarted (2.2.18: restarted, then only a warning)' (J $r)
$okState = Join-Path $tmp 'lim-ok.json'
$r = InMod $rst @($cred, $hikStub, $okState, (Join-Path $tmp 'rs2'), 'normal')
Check ($r.writes.Count -eq 1 -and $r.atPut -match '10\.0\.0\.21') 'F22: the restart is already in the restart record WHEN the reboot is sent (reservation first; 2.2.18 wrote it after)' (J $r)
$r2 = InMod $rst @($cred, $hikStub, $okState, (Join-Path $tmp 'rs3'), 'normal')
Check ($r2.writes.Count -eq 0 -and $r2.msg -match 'last hour') 'control: a second restart within the hour (another run) is refused from the saved record' (J $r2)
$refState = Join-Path $tmp 'lim-refuse.json'
$r = InMod $rst @($cred, $hikStub, $refState, (Join-Path $tmp 'rs4'), 'refuse')
Check ($r.writes.Count -eq 1 -and -not $r.ok -and $r.after -notmatch '\d{4}-\d\d-\d\dT') 'control: the camera explicitly refuses -> nothing restarted and its reservation is taken back (limit not used up)' (J $r)
$badState = Join-Path $tmp 'lim-bad.json'; Set-Content -LiteralPath $badState -Value '{"10.0.0.21":["not a time"]}'
$r = InMod $rst @($cred, $hikStub, $badState, (Join-Path $tmp 'rs5'), 'normal')
Check ($r.writes.Count -eq 0 -and -not $r.ok -and $r.msg -match 'cannot be (checked|kept)' -and -not $r.threw) 'F22 twin (class E): a restart record with an entry that is not a time = unknown budget -> held, no restart (2.2.18: stopped with an error)' (J $r)
$arrState = Join-Path $tmp 'lim-arr.json'; Set-Content -LiteralPath $arrState -Value '[1,2,3]'
$r = InMod $rst @($cred, $hikStub, $arrState, (Join-Path $tmp 'rs6'), 'normal')
Check ($r.writes.Count -eq 0 -and -not $r.ok) 'F22 twin (class E): a restart record that is not a record (a JSON list) = unknown budget -> no restart' (J $r)
$hl = InMod { param($p) $a = Fix-LimitReserve $p '10.0.0.21' (Get-Date); $b = Fix-LimitOk $p '10.0.0.21' (Get-Date); return @{ reserved = [bool]$a.ok; next = [bool]$b.ok } } @((Join-Path $blocker 'x.json'))
Check ($hl -is [hashtable] -and $hl.ContainsKey('reserved') -and -not $hl.reserved) 'F22 (Codex helper repro): reserving on an unwritable record says NO (so the caller does not restart)' (J $hl)

# 2.2.19 (lead, class A: the device the technician picked): the window passes the MAC the last scan saved for that address
Write-Host 'Expected MAC (FixIt -Mac / Invoke-NvrFix -ExpectMac): the device answering must be the one the scan saw'
$xm = {
  param($cred, $stub, [string]$state, [string]$dir, [string]$devMac, [string]$expect)
  . ([scriptblock]::Create([string]$stub))
  $script:Dev = @{ sn = 'CAM1'; mac = $devMac; ver = 'V5.5'; date = 'build 240101' }; $script:Writes = @(); $script:Reads = 0; $script:PutAnswer = $null; $script:Hook = $null
  $threw = ''; $r = $null
  try { $r = Invoke-NvrFix -Fix restart -Ip '10.0.0.21' -Vendor Hikvision -Credential $cred -StateFile $state -BackupDir $dir -Confirm { 'YES' } -WaitSec 1 -ExpectMac $expect } catch { $threw = $_.Exception.Message }
  return @{ ok = [bool]($r -and $r.ok); msg = $(if ($r) { [string]$r.msg } else { '' }); writes = @($script:Writes); threw = $threw }
}
$r = InMod $xm @($cred, $hikStub, (Join-Path $tmp 'xm1.json'), (Join-Path $tmp 'xm1'), 'AA:BB:CC:00:00:99', 'aa-bb-cc-00-00-21')
Check (-not $r.threw -and $r.writes.Count -eq 0 -and -not $r.ok -and $r.msg -match 'DIFFERENT device') 'class A (lead): another camera (other MAC) now answers at the address the technician picked -> NOT restarted, says so (2.2.18: no way to pass the scanned MAC)' (J $r)
$r = InMod $xm @($cred, $hikStub, (Join-Path $tmp 'xm2.json'), (Join-Path $tmp 'xm2'), '', 'AA:BB:CC:00:00:21')
Check (-not $r.threw -and $r.writes.Count -eq 0 -and -not $r.ok -and $r.msg -match 'did not say its MAC') 'class A (lead): the device does not report a MAC while the scan saved one -> NOT restarted (cannot be checked)' (J $r)
$r = InMod $xm @($cred, $hikStub, (Join-Path $tmp 'xm3.json'), (Join-Path $tmp 'xm3'), 'AA:BB:CC:00:00:21', 'aa-bb-cc-00-00-21')
Check (-not $r.threw -and $r.writes.Count -eq 1) 'control: the same camera (same MAC, other spelling) -> restarted once' (J $r)
$wsrc = Get-Content -LiteralPath (Join-Path $tkDir 'WireItToolkit.ps1') -Raw; $fsrc = Get-Content -LiteralPath (Join-Path $tkDir 'FixIt.ps1') -Raw
Check ($wsrc -match "fixMac = Get-TkSavedMac \(\[string\]\`$a\.ip\); if \(\`$fixMac\) \{ \`$e \+= '-Mac '" -and $fsrc -match 'if \(\$Mac\) \{ \$p\.ExpectMac = \$Mac \}') 'class A (lead, source check): the window passes the scanned MAC to FixIt for the fix buttons, and FixIt passes it on as -ExpectMac' ''

# FixIt.ps1 (class F): the fix-history line is the record of a device change; a failed save is said, not dropped
$fxs = Get-Content -LiteralPath (Join-Path $tkDir 'FixIt.ps1') -Raw
Check ($fxs -match '\$histSaved = \[bool\]\(Add-TkLine' -and $fxs -match 'if \(-not \$histSaved\) \{ Say2' -and $fxs -match 'historySaved = \$histSaved') 'FixIt (class F, static check): a fix-history save that failed is warned on screen and recorded as historySaved=false in result.json (2.2.18: [void] - silent)' ''

Deferred 'a real Hikvision camera / NVR / DW server / ONVIF recorder (channel re-read after YES, firmware fields, DW storage + footage answers, GetNTP faults, restart record on a real Windows PC): stand-ins only - NEEDS A REAL-DEVICE CHECK'
} catch { $script:fail++; Write-Host ('FAIL unexpected error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.ScriptLineNumber) }
finally { $global:ErrorActionPreference = 'Stop'; Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
Write-Host ''
Write-Host ('Test-Fix2219Nvr: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:deferred + ' deferred')
if ($script:fail) { exit 1 }
exit 0
