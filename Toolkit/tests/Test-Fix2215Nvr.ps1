<# Test-Fix2215Nvr.ps1 - tests for WireIt Toolkit 2.2.15 (Nov 10 2026), the NvrHealth / NvrFix part of Codex's NO-GO review of 2.2.14
   (head f2850b4): R4 re-add over a channel set up by hostname / with no readable address, R5 an unknown Hik/DW recording schedule
   promoted to green, R6 an enabled Hik track whose schedule is all Record=false ("already on") and an invalid Record value read
   as false, R9 a still-filling recorder said "target met", R10 a lost firmware-write answer called a refusal / old firmware.
   Codex's reproduce-readd-hostname.ps1, reproduce-recording.ps1 and reproduce-firmware-response-lost.ps1 run as permanent
   checks in tests/repro-2.2.14/; this suite covers the same findings plus the controls, failing half-way and running twice.
   Every check RUNS the real module functions (Get-RecordingStatus, Invoke-NvrFix, Hik-ParseTracks) with a stand-in for the
   device's web answers. No real device is touched, so real-device behaviour is DEFERRED (never a pass). PS 5.1 or pwsh 7.
   FIX2215NVR_DIR (tests only) = run against another copy of the module (old-code proof). #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot
$modDir = $(if ($env:FIX2215NVR_DIR) { $env:FIX2215NVR_DIR } else { Join-Path $tk 'modules\NvrHealth' })
$nhMod = Join-Path $modDir 'NvrHealth.psm1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2215nvr-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + $more) } }
}
function Deferred([string]$name) { $script:deferred++; Write-Host ('DEFERRED ' + $name) }
foreach ($f in @($nhMod, (Join-Path $modDir 'NvrFix.ps1'))) {
  $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$e); Check ($e.Count -eq 0) ('parses: ' + (Split-Path -Leaf $f)) ($e | Out-String)
}
$cred = New-Object PSCredential('admin', (ConvertTo-SecureString 'Review123' -AsPlainText -Force))
$script:n = 0
# runs $body inside a fresh copy of the module (its own stand-in Http), returns what $body returns
function InMod([scriptblock]$body, [object[]]$args2) {
  $script:n++
  $m = Import-Module $nhMod -Force -PassThru -DisableNameChecking
  try {
    & $m { param($ld) Set-NvrHealthOption LogDir $ld } (Join-Path $tmp ('logs' + $script:n))
    return (& $m $body @args2)
  } finally { Remove-Module $m -Force -ErrorAction SilentlyContinue }
}

try {
# ==============================================================================================================================
Write-Host 'R4 re-add: a channel set up by hostname / with no readable address is NOT a free slot'
$readd = {
  param($cred, [string]$mode, [bool]$Twice = $false)
  $script:Mode = $mode; $script:Puts = 0; $script:StatusReads = 0
  function script:Http {
    param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '')
    if ($Path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = '<DeviceInfo><model>DS-7608NI-K2</model><serialNumber>TESTDEV0001</serialNumber><macAddress>AA:BB:CC:00:00:01</macAddress><firmwareVersion>V4.1</firmwareVersion><firmwareReleasedDate>build 240101</firmwareReleasedDate></DeviceInfo>' } }   # 2.2.19: the device says who it is (NvrFix re-identifies it before every write)
    if ($Method -eq 'PUT') { $script:Puts++; return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } }
    if ($Path -like '*/channels/status') {
      $script:StatusReads++
      $on = $(if ($script:Puts) { 'true' } elseif ($script:Mode -eq 'ip-offline') { 'false' } else { 'true' })
      return @{ code = 200; body = ('<InputProxyChannelStatusList><InputProxyChannelStatus><id>1</id><online>' + $on + '</online></InputProxyChannelStatus></InputProxyChannelStatusList>') }
    }
    if ($Path -eq '/ISAPI/ContentMgmt/InputProxy/channels') {
      if ($script:Puts) { $ch = '<InputProxyChannel><id>1</id><sourceInputPortDescriptor><addressingFormatType>ipaddress</addressingFormatType><ipAddress>10.0.0.41</ipAddress></sourceInputPortDescriptor></InputProxyChannel>' }
      else {
        $d = switch ($script:Mode) {
          'hostname' { '<addressingFormatType>hostname</addressingFormatType><hostName>working-camera.local</hostName>' }
          'hostname-noType' { '<hostName>working-camera.local</hostName>' }
          'no-address' { '<proxyProtocol>HIKVISION</proxyProtocol>' }
          'odd-type' { '<addressingFormatType>domain</addressingFormatType><ipAddress>10.0.0.77</ipAddress>' }
          'bad-ip' { '<addressingFormatType>ipaddress</addressingFormatType><ipAddress>not-an-ip</ipAddress>' }
          'ip-offline' { '<addressingFormatType>ipaddress</addressingFormatType><ipAddress>10.0.0.40</ipAddress>' }
          default { '' }
        }
        $ch = $(if ($script:Mode -eq 'free') { '' } else { '<InputProxyChannel><id>1</id><sourceInputPortDescriptor>' + $d + '</sourceInputPortDescriptor></InputProxyChannel>' })
      }
      return @{ code = 200; body = ('<InputProxyChannelList>' + $ch + '</InputProxyChannelList>') }
    }
    return @{ code = 404; body = '' }
  }
  $r = Invoke-NvrFix -Fix readd -Ip '10.0.0.20' -Vendor Hikvision -Credential $cred -NewCredential $cred -Channel 1 -CameraIp '10.0.0.41' -Confirm { 'YES' }
  $o = [pscustomobject]@{ ok = [bool]$r.ok; msg = [string]$r.msg; puts = $script:Puts; history = [string]$r.history; second = $null }
  if ($Twice) { $r2 = Invoke-NvrFix -Fix readd -Ip '10.0.0.20' -Vendor Hikvision -Credential $cred -NewCredential $cred -Channel 1 -CameraIp '10.0.0.41' -Confirm { 'YES' }; $o.second = [pscustomobject]@{ ok = [bool]$r2.ok; msg = [string]$r2.msg; puts = $script:Puts } }
  $o
}
foreach ($md in @('hostname', 'hostname-noType', 'no-address', 'odd-type', 'bad-ip')) {
  $r = InMod $readd @($cred, $md)
  Check ($r.puts -eq 0 -and -not $r.ok -and $r.msg -match 'Nothing changed' -and $r.msg -match 'by hand') ('Codex readd-hostname (' + $md + '): channel 1 is set up but not by a checkable IP -> no PUT, not OK, check it by hand') $r.msg
}
$r = InMod $readd @($cred, 'hostname')
Check ($r.msg -match 'working-camera\.local' -and $r.history -match 'NOT done') 'the message names the hostname the channel uses, and the history says NOT done' ($r.msg + ' | ' + $r.history)
$r = InMod $readd @($cred, 'hostname', $true)
Check ($r.second.puts -eq 0 -and -not $r.second.ok -and $r.second.msg -eq $r.msg) 'running twice: the same honest refusal both times, nothing written' $r.second.msg
$r = InMod $readd @($cred, 'free')
Check ($r.ok -and $r.puts -eq 1) 'control: channel 1 not set up at all -> camera put on it, read back and online' $r.msg
$r = InMod $readd @($cred, 'ip-offline')
Check ($r.ok -and $r.puts -eq 1) 'control: channel 1 holds an IP camera the NVR reports offline -> replaced (2.2.14 guard unchanged)' $r.msg
Deferred 'R4 real Hikvision NVR channel lists with hostname / domain (DDNS) addressing: field names taken from the ISAPI docs and the review, stand-ins only - NEEDS A REAL-NVR CHECK'

# ==============================================================================================================================
Write-Host 'R6 parser: every Record value must be true/false; a schedule with only Record=false is known OFF'
$parse = {
  param([string]$recs)
  $x = '<TrackList><Track><id>101</id><Enable>true</Enable><TrackSchedule>' + $recs + '</TrackSchedule></Track></TrackList>'
  $m = Hik-ParseTracks $x
  $v = $m[101].hasSchedule
  $(if ($null -eq $v) { 'null' } else { [string]$v })
}
$cases = @(
  @('<Record>false</Record>', 'False', 'only Record=false = known OFF'),
  @('<Record>false</Record><Record>false</Record>', 'False', 'all Record=false = known OFF'),
  @('<Record>unknown</Record>', 'null', 'Codex: Record=unknown = UNKNOWN (2.2.14 read it as false)'),
  @('<Record></Record>', 'null', 'an empty Record = UNKNOWN'),
  @('<Record>true</Record><Record>maybe</Record>', 'null', 'one invalid Record next to a true one = UNKNOWN'),
  @('<Record>false</Record><Record>TRUE</Record>', 'True', 'control: some recording time (TRUE) = has a schedule'),
  @('', 'null', 'no Record entries at all = UNKNOWN (2.2.14 rule kept)')
)
foreach ($c in $cases) { $got = InMod $parse @($c[0]); Check ($got -eq $c[1]) ('parser: ' + $c[2] + ' (got ' + $got + ')') }

# ==============================================================================================================================
Write-Host 'R6 recording fix: an enabled track with an all-false schedule is turned on; an invalid Record value = NOT CHECKED, no write'
$fixRec = {
  param($cred, [string]$track, [string]$mode, [bool]$Twice = $false)
  $script:Track = '<Track><id>101</id>' + $track + '</Track>'; $script:Mode = $mode; $script:Puts = 0; $script:LastPut = ''
  function script:Http {
    param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '')
    if ($Method -eq 'PUT') {
      $script:Puts++; $script:LastPut = $Body
      if ($script:Mode -ne 'ignored') { $script:Track = $Body }
      return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' }
    }
    if ($Path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = '<DeviceInfo><model>DS-7608</model><serialNumber>review</serialNumber></DeviceInfo>' } }
    if ($Path -eq '/ISAPI/ContentMgmt/record/tracks') { return @{ code = 200; body = ('<TrackList>' + $script:Track + '</TrackList>') } }
    if ($Path -eq '/ISAPI/ContentMgmt/record/tracks/101') {
      if ($script:Mode -eq 'changed') { return @{ code = 200; body = '<Track><id>101</id><Enable>true</Enable><TrackSchedule><Record>true</Record></TrackSchedule></Track>' } }
      return @{ code = 200; body = $script:Track }
    }
    return @{ code = 404; body = '' }
  }
  $r = Invoke-NvrFix -Fix recording -Ip '10.0.0.20' -Vendor Hikvision -Credential $cred -Confirm { 'YES' }
  $o = [pscustomobject]@{ ok = [bool]$r.ok; msg = [string]$r.msg; puts = $script:Puts; put = $script:LastPut; second = $null }
  if ($Twice) { $p0 = $script:Puts; $r2 = Invoke-NvrFix -Fix recording -Ip '10.0.0.20' -Vendor Hikvision -Credential $cred -Confirm { 'YES' }; $o.second = [pscustomobject]@{ ok = [bool]$r2.ok; msg = [string]$r2.msg; puts = ($script:Puts - $p0) } }
  $o
}
$emptySched = '<Enable>true</Enable><TrackSchedule><ScheduleBlock><ScheduleAction><Actions><Record>false</Record><ActionRecordingMode>CMR</ActionRecordingMode></Actions></ScheduleAction><ScheduleAction><Actions><Record>false</Record></Actions></ScheduleAction></ScheduleBlock></TrackSchedule>'
$r = InMod $fixRec @($cred, $emptySched, '')
Check ($r.msg -notmatch 'already on') 'Codex: Enable=true + schedule only Record=false is NOT "already on"' $r.msg
Check ($r.ok -and $r.puts -eq 1 -and $r.put -notmatch '<Record>false</Record>' -and $r.put -match '<Record>true</Record>' -and $r.put -match 'CMR') 'the fix sets the schedule slots to record (mode kept), reads back: ON again' ($r.msg + ' | ' + $r.put)
$r = InMod $fixRec @($cred, $emptySched, '', $true)
Check ($r.second.ok -and $r.second.puts -eq 0 -and $r.second.msg -match 'already on') 'running twice: run 2 sees it on and writes nothing' $r.second.msg
$r = InMod $fixRec @($cred, '<Enable>false</Enable><TrackSchedule><Record>false</Record></TrackSchedule>', '')
Check ($r.ok -and $r.puts -eq 1 -and $r.put -match '<Enable>true</Enable>' -and $r.put -match '<Record>true</Record>') 'Enable=false AND an all-false schedule: both turned on in one write, confirmed' ($r.msg + ' | ' + $r.put)
$r = InMod $fixRec @($cred, '<Enable>true</Enable><TrackSchedule><Record>unknown</Record></TrackSchedule>', '')
Check (-not $r.ok -and $r.puts -eq 0 -and $r.msg -match 'NOT CHECKED') 'Codex: Record=unknown -> NOT CHECKED, nothing written (2.2.14: "already on")' $r.msg
$r = InMod $fixRec @($cred, $emptySched, 'ignored')
Check (-not $r.ok -and $r.puts -eq 1 -and $r.msg -match 'Still off') 'failing half-way: the recorder says OK but keeps Record=false -> "Still off", not green' $r.msg
$r = InMod $fixRec @($cred, $emptySched, 'changed')
Check ($r.puts -eq 0 -and -not $r.ok) 'the single track no longer matches what the list said (changed) -> not written, not green' $r.msg
$r = InMod $fixRec @($cred, '<Enable>true</Enable><TrackSchedule><Record>true</Record></TrackSchedule>', '')
Check ($r.ok -and $r.puts -eq 0 -and $r.msg -match 'already on') 'control: Enable=true + Record=true = already on, nothing written' $r.msg
Deferred 'R6 writing a whole Hikvision track schedule (every Record=false slot set to true) on a real NVR: stand-ins only - NEEDS A REAL-NVR CHECK'

# ==============================================================================================================================
Write-Host 'R5 / R9 read-only recording check: unknown schedule = NOT CHECKED; still filling = target NOT reached yet'
$recChk = {
  param($cred, [string]$vendor, [string]$track, [string]$dwSched, [string]$oldest, [int]$freePct)
  $script:Track = $track; $script:DwSched = $dwSched; $script:Oldest = $oldest; $script:FreePct = $freePct
  function script:Dw-Login { return $true }
  function script:Http {
    param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '')
    $b = ''
    $free = [int](10000 * $script:FreePct)
    switch ($Path) {
      '/ISAPI/System/deviceInfo' { $b = '<DeviceInfo><model>DS-7608</model><serialNumber>review</serialNumber></DeviceInfo>' }
      '/ISAPI/System/time' { $b = '<Time><localTime>2026-11-10T10:00:00</localTime><timeZone>CST+5:00:00</timeZone></Time>' }
      '/ISAPI/ContentMgmt/InputProxy/channels' { $b = '<InputProxyChannelList><InputProxyChannel><id>1</id><ipAddress>10.0.0.41</ipAddress></InputProxyChannel></InputProxyChannelList>' }
      '/ISAPI/ContentMgmt/InputProxy/channels/status' { $b = '<InputProxyChannelStatusList><InputProxyChannelStatus><id>1</id><online>true</online></InputProxyChannelStatus></InputProxyChannelStatusList>' }
      '/ISAPI/ContentMgmt/record/tracks' { $b = '<TrackList><Track><id>101</id>' + $script:Track + '</Track></TrackList>' }
      '/ISAPI/ContentMgmt/Storage' { $b = '<storage><hddList><hdd><id>1</id><capacity>1000000</capacity><freeSpace>' + $free + '</freeSpace><status>ok</status><property>RW</property></hdd></hddList></storage>' }
      '/ISAPI/ContentMgmt/search' { $b = '<CMSearchResult><responseStatusStrg>OK</responseStatusStrg><matchList><searchMatchItem><timeSpan><startTime>' + $script:Oldest + 'T10:00:00Z</startTime><endTime>2026-11-10T09:59:00Z</endTime></timeSpan></searchMatchItem></matchList></CMSearchResult>' }
      default {
        if ($Path -like '/rest/v3/devices*') { $b = '[{"id":"c1","name":"Lobby","url":"http://10.0.0.41","status":"Recording"' + $script:DwSched + '}]' }
        elseif ($Path -eq '/rest/v3/servers/this/storages/*/status') { $b = '[{"url":"media","totalSpace":1000000000,"freeSpace":' + [int](10000000 * $script:FreePct) + ',"isOnline":true,"isUsedForWriting":true}]' }
        elseif ($Path -like '/ec2/recordedTimePeriods*') { $ms = [int64](([datetime]($script:Oldest + 'T10:00:00Z')).ToUniversalTime() - [datetime]'1970-01-01').TotalMilliseconds; $b = '[{"startTimeMs":' + $ms + ',"durationMs":-1}]' }
        else { return @{ code = 404; body = '' } }
      }
    }
    return @{ code = 200; body = $b }
  }
  $r = Get-RecordingStatus -Ip '10.0.0.20' -Vendor $vendor -Credential $cred -TargetDays 30
  $sum = @(Get-NvrHealthSummary | Where-Object { $_ -match '^RESULT' })
  $all = (@(Get-NvrHealthSummary) -join ' | ')
  [pscustomobject]@{ ok = [bool]$r.ok; problems = (@($r.problems) -join '; '); sched = $r.channels[0].scheduled; recNow = [bool]$r.channels[0].recording_now; summary = $(if ($sum.Count) { [string]$sum[-1] } else { '' }); all = $all; days = $r.days_held; pending = $(if ($r.PSObject.Properties['target_pending']) { $r.target_pending } else { $null }) }
}
$good = '<Enable>true</Enable><TrackSchedule><Record>true</Record></TrackSchedule>'
foreach ($c in @(@('<TrackSchedule><Record>true</Record></TrackSchedule>', 'Hik Enable missing'), @('<Enable>true</Enable>', 'Hik Enable=true, no schedule entries'), @('<Enable>true</Enable><TrackSchedule><Record>unknown</Record></TrackSchedule>', 'Hik Record=unknown'))) {
  $r = InMod $recChk @($cred, 'Hikvision', $c[0], '', '2026-09-01', 0)
  Check (-not $r.ok -and $r.problems -match 'schedule NOT CHECKED' -and $r.summary -notmatch 'target met') ('Codex R5 (' + $c[1] + ') + fresh footage: schedule NOT CHECKED, never an all-clear') ($r.problems + ' | ' + $r.summary)
  Check ($r.recNow -and $r.all -match 'footage is fresh') ('(' + $c[1] + ') the footage result is kept and shown') $r.all
}
$r = InMod $recChk @($cred, 'DW', '', ',"schedule":{}', '2026-09-01', 0)
Check (-not $r.ok -and $r.problems -match 'schedule NOT CHECKED' -and $r.summary -notmatch 'target met') 'Codex R5 DW schedule without isEnabled + fresh footage: NOT CHECKED, never an all-clear' ($r.problems + ' | ' + $r.summary)
$r = InMod $recChk @($cred, 'DW', '', '', '2026-09-01', 0)
Check (-not $r.ok -and $r.problems -match 'schedule NOT CHECKED') 'DW camera with no schedule at all: NOT CHECKED' ($r.problems + ' | ' + $r.summary)
$r = InMod $recChk @($cred, 'DW', '', ',"schedule":{"isEnabled":true}', '2026-09-01', 0)
Check ($r.ok -and $r.summary -match 'target met') 'control: DW isEnabled=true, 70 days = target met' ($r.problems + ' | ' + $r.summary)
$r = InMod $recChk @($cred, 'Hikvision', $good, '', '2026-09-01', 0)
Check ($r.ok -and $r.summary -match 'target met') 'control: Hik Enable=true + Record=true, 70 days = target met' ($r.problems + ' | ' + $r.summary)
$ra = InMod $recChk @($cred, 'Hikvision', '<Enable>true</Enable>', '', '2026-09-01', 0); $rb = InMod $recChk @($cred, 'Hikvision', '<Enable>true</Enable>', '', '2026-09-01', 0)
Check (-not $ra.ok -and $ra.summary -eq $rb.summary) 'running twice: the same NOT CHECKED result both times (read-only)' $rb.summary
# R9
$r = InMod $recChk @($cred, 'Hikvision', $good, '', '2026-11-05', 50)
Check ($r.summary -notmatch 'target met' -and $r.summary -match 'still filling' -and $r.summary -match 'not reached') 'Codex R9: 5 days, drive half empty -> "5 days so far, still filling, target not reached yet" (2.2.14: target met)' $r.summary
Check (-not $r.ok -and -not $r.problems -and $r.pending -eq $true) 'still filling: ok is NOT true, but it is not counted as a fault (target_pending)' ('ok=' + $r.ok + ' problems=' + $r.problems + ' pending=' + $r.pending)
$r = InMod $recChk @($cred, 'DW', '', ',"schedule":{"isEnabled":true}', '2026-11-05', 50)
Check (-not $r.ok -and $r.summary -match 'still filling' -and $r.summary -notmatch 'target met') 'R9 on DW: 5 days, storage half empty -> still filling, not target met' $r.summary
$r = InMod $recChk @($cred, 'Hikvision', $good, '', '2026-11-05', 0)
Check (-not $r.ok -and $r.problems -match 'only 5 of 30') 'control: 5 days and the drive is full -> a problem (unchanged)' ($r.problems + ' | ' + $r.summary)
$r = InMod $recChk @($cred, 'Hikvision', $good, '', '2026-09-01', 50)
Check ($r.ok -and $r.summary -match 'target met' -and -not $r.pending) 'control: 70 days on a half-empty drive -> target met (filling only matters below the target)' $r.summary
$r = InMod $recChk @($cred, 'Hikvision', '<Enable>true</Enable>', '', '2026-11-05', 50)
Check (-not $r.ok -and $r.problems -match 'schedule NOT CHECKED' -and $r.pending -ne $true -and $r.summary -notmatch 'target met') 'unknown schedule AND still filling: the NOT CHECKED problem wins (not "still filling" only)' ($r.problems + ' | ' + $r.summary)

# ==============================================================================================================================
Write-Host 'R10 firmware: a lost answer is SENT, NOT confirmed - read back, never "still runs the old firmware" unread'
$fw = {
  param($cred, [string]$mode, [string]$tmp)
  $script:Version = 'V5.5.0'; $script:Sent = $false; $script:Reads = 0; $script:Mode = $mode
  function script:Http {
    param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '')
    switch ($Path) {
      '/ISAPI/System/deviceInfo' {
        if ($script:Sent) { $script:Reads++; if ($script:Mode -eq 'lost-noread') { return @{ code = 0; body = ''; err = 'no answer' } } }
        return @{ code = 200; body = ('<DeviceInfo><model>DS-2CD2143</model><serialNumber>REV1</serialNumber><firmwareVersion>' + $script:Version + '</firmwareVersion></DeviceInfo>') }
      }
      '/ISAPI/System/configurationData' { [IO.File]::WriteAllBytes($OutFile, [byte[]]((1..255) * 4)); return @{ code = 200; body = '' } }
      '/ISAPI/System/updateFirmware' {
        $script:Sent = $true
        switch ($script:Mode) {
          'lost-new' { $script:Version = 'V5.7.3'; return @{ code = 0; body = ''; err = 'connection dropped' } }
          'refused' { return @{ code = 200; body = '<ResponseStatus><statusCode>4</statusCode><statusString>Invalid Operation</statusString></ResponseStatus>' } }
          'ok' { $script:Version = 'V5.7.3'; return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } }
          default { return @{ code = 0; body = ''; err = 'timeout' } }
        }
      }
    }
    return @{ code = 404; body = '' }
  }
  $f = Join-Path $tmp 'fw.bin'; [IO.File]::WriteAllBytes($f, [byte[]]((1..255) * 4))
  $bk = Join-Path $tmp ('bk-' + $mode + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
  $r = Invoke-NvrFix -Fix firmware -Ip '10.0.0.50' -Vendor Hikvision -Credential $cred -File $f -Sha256 (Get-FileHash $f).Hash -BackupDir $bk -Confirm { 'YES' }
  [pscustomobject]@{ ok = [bool]$r.ok; msg = [string]$r.msg; history = [string]$r.history; reads = $script:Reads; backup = [bool]($r.backup -and (Test-Path -LiteralPath $r.backup)) }
}
$r = InMod $fw @($cred, 'lost-new', $tmp)
Check ($r.reads -ge 1 -and $r.ok -and $r.msg -match 'V5\.7\.3' -and $r.msg -notmatch 'old firmware') 'Codex firmware-response-lost: answer lost, device now reports the new version -> read back and says updated' $r.msg
$r = InMod $fw @($cred, 'lost-old', $tmp)
Check ($r.reads -ge 1 -and -not $r.ok -and $r.msg -match 'NOT confirmed' -and $r.msg -notmatch 'still runs the old firmware' -and $r.msg -notmatch 'refused') 'answer lost, device still shows the old version -> NOT confirmed (it may be installing), no "old firmware" claim' $r.msg
Check ($r.msg -match 'wait 10 minutes' -and $r.msg -match 'Firmware check' -and $r.msg -match 'NOT send it again') 'it tells the crew to wait, run the Firmware check, and not send it again yet' $r.msg
Check ($r.backup -and $r.history -match 'NOT confirmed') 'the settings export is kept and the history says sent, NOT confirmed' $r.history
$r = InMod $fw @($cred, 'lost-noread', $tmp)
Check ($r.reads -ge 1 -and -not $r.ok -and $r.msg -match 'NOT confirmed' -and $r.msg -match 'could not be read back') 'failing half-way: answer lost and the read-back fails too -> NOT confirmed, says it could not be read' $r.msg
$r = InMod $fw @($cred, 'refused', $tmp)
Check (-not $r.ok -and $r.msg -match 'refused' -and $r.msg -notmatch 'still runs the old firmware' -and $r.backup) 'an explicit refusal (statusCode 4) is still a refusal; no unread "old firmware" claim; export kept' $r.msg
$r = InMod $fw @($cred, 'ok', $tmp)
Check ($r.ok -and $r.msg -match 'Updated') 'control: OK answer and the new version reads back = Updated' $r.msg
Deferred 'R10 a real Hikvision firmware upload whose answer is lost (reboot timing, when deviceInfo answers again): stand-ins only - NEEDS A REAL-DEVICE CHECK'
Deferred 'R5/R9 real Hikvision NVR / DW server schedule and storage answers (field names from the review and ISAPI / DW docs): stand-ins only - NEEDS A REAL-DEVICE CHECK'
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ''
Write-Host ('Test-Fix2215Nvr: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:deferred + ' deferred')
if ($script:fail) { exit 1 }
exit 0
