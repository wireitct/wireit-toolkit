<# Test-Fix2214Nvr.ps1 - tests for WireIt Toolkit 2.2.14 (Nov 10 2026), the NvrHealth / NvrFix part of Codex's NO-GO review of 2.2.13
   (head b6037f2): F3 re-add over an unreadable status, F5 one camera's unknown retention, F6 DW recording list failure,
   F7 a lost password-write answer, F9 missing recording Enable / schedule.
   Codex's reproduce-nvr.ps1 cases (missing-enable, dw-list-fails, readd-status-unread-before-write, one-camera-retention-unread,
   password-write-applied-response-lost) are permanent checks here, each with Codex's own stand-in answers.
   Moshe's rule: every change is tested for failing half-way, the wrong device and running twice.
   Every check RUNS the real module functions (Get-RecordingStatus, Invoke-NvrFix) with a stand-in for the device's web answers.
   No real device is touched, so real-device behaviour is DEFERRED (never a pass). PS 5.1 or pwsh 7.
   FIX2214NVR_DIR (tests only) = run against another copy of the module (old-code proof). #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot
$modDir = $(if ($env:FIX2214NVR_DIR) { $env:FIX2214NVR_DIR } else { Join-Path $tk 'modules\NvrHealth' })
$nhMod = Join-Path $modDir 'NvrHealth.psm1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2214nvr-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + $more) } }
}
foreach ($f in @($nhMod, (Join-Path $modDir 'NvrFix.ps1'))) {
  $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$e); Check ($e.Count -eq 0) ('parses: ' + (Split-Path -Leaf $f)) ($e | Out-String)
}
$cred = New-Object PSCredential('admin', (ConvertTo-SecureString 'Review123' -AsPlainText -Force))
$newCred = New-Object PSCredential('admin', (ConvertTo-SecureString 'NewReview456' -AsPlainText -Force))
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
$sched = '<TrackSchedule><ScheduleBlock><ScheduleAction><Actions><Record>true</Record><ActionRecordingMode>CMR</ActionRecordingMode></Actions></ScheduleAction></ScheduleBlock></TrackSchedule>'

try {
# ==============================================================================================================================
Write-Host 'F9 Hikvision recording: a missing / unrecognised Enable, or no schedule, is UNKNOWN - never "already on"'
$hikRec = {
  param($cred, [string]$listXml, [hashtable]$tracks, [string]$mode)
  $script:Tr = $tracks; $script:Puts = 0; $script:Mode = $mode; $script:Reads = 0
  function script:Http {
    param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '')
    if ($Path -eq '/ISAPI/ContentMgmt/record/tracks') {
      $script:Reads++
      if ($script:Mode -eq 'readback500' -and $script:Reads -ge 2) { return @{ code = 500; body = '' } }
      if ($script:Tr) { return @{ code = 200; body = ('<TrackList>' + (-join (@($script:Tr.Keys | Sort-Object) | ForEach-Object { $script:Tr[$_] })) + '</TrackList>') } }
      return @{ code = 200; body = $listXml }
    }
    $m = [regex]::Match($Path, '^/ISAPI/ContentMgmt/record/tracks/(\d+)$')
    if ($m.Success -and $script:Tr) {
      $id = [int]$m.Groups[1].Value
      if ($Method -eq 'PUT') { $script:Puts++; $script:Tr[$id] = $Body; return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } }
      return @{ code = 200; body = $script:Tr[$id] }
    }
    if ($Method -eq 'PUT') { $script:Puts++ }
    return @{ code = 404; body = '' }
  }
  $r = Invoke-NvrFix -Fix recording -Ip '10.0.0.20' -Vendor Hikvision -Credential $cred -Confirm { 'YES' }
  [pscustomobject]@{ ok = $r.ok; ran = $r.ran; msg = [string]$r.msg; puts = $script:Puts; tracks = $script:Tr }
}
# Codex reproduce-nvr.ps1 case missing-enable, its exact answer
$r = InMod $hikRec @($cred, '<TrackList><Track><id>101</id></Track></TrackList>', $null, '')
Check (-not $r.ok) 'Codex missing-enable: <Track><id>101</id></Track> is NOT "already on" (ok=false)' $r.msg
Check ($r.msg -notmatch 'already on' -and $r.msg -match 'NOT CHECKED') 'missing-enable: says NOT CHECKED, never "Recording is already on"' $r.msg
Check ($r.puts -eq 0) 'missing-enable: nothing written'
$r = InMod $hikRec @($cred, ('<TrackList><Track><id>101</id><Enable>yes</Enable>' + $sched + '</Track></TrackList>'), $null, '')
Check (-not $r.ok -and $r.msg -match 'NOT CHECKED') 'an unrecognised Enable value ("yes") = unknown, not on' $r.msg
$r = InMod $hikRec @($cred, '<TrackList><Track><id>101</id><Enable>true</Enable></Track></TrackList>', $null, '')
Check (-not $r.ok -and $r.msg -match 'NOT CHECKED') 'Enable=true but no schedule entries at all = unknown, not "already on"' $r.msg
$r = InMod $hikRec @($cred, ('<TrackList><Track><id>101</id><Enable>true</Enable>' + $sched + '</Track><Track><id>201</id><Enable>TRUE</Enable>' + $sched + '</Track></TrackList>'), $null, '')
Check ($r.ok -and $r.msg -match 'already on' -and $r.puts -eq 0) 'control: explicit Enable=true + schedule on every track = already on, nothing written' $r.msg
$r = InMod $hikRec @($cred, '<ResponseStatus><statusCode>4</statusCode><statusString>Invalid Operation</statusString></ResponseStatus>', $null, '')
Check (-not $r.ok -and $r.puts -eq 0) 'wrong answer (an error page instead of a track list) = NOT CHECKED, nothing written' $r.msg
# half-way: 101 off (known), 201 unknown -> 101 is turned on, the result is still NOT green because 201 was not checked
$tr = @{ 101 = ('<Track><id>101</id><Enable>false</Enable>' + $sched + '</Track>'); 201 = '<Track><id>201</id></Track>' }
$r = InMod $hikRec @($cred, '', $tr, '')
Check ($r.puts -eq 1 -and [string]$r.tracks[101] -match '<Enable>true</Enable>') 'half-known list: the known-off track 101 is turned on (one write)' ('puts=' + $r.puts)
Check (-not $r.ok -and $r.msg -match 'NOT CHECKED') 'half-known list: the result is NOT green - camera 2 stays NOT CHECKED' $r.msg
# running twice: the 1st run turns 101 on, the 2nd sees everything on and writes nothing
$tr = @{ 101 = ('<Track><id>101</id><Enable>false</Enable>' + $sched + '</Track>'); 201 = ('<Track><id>201</id><Enable>true</Enable>' + $sched + '</Track>') }
$r1 = InMod $hikRec @($cred, '', $tr, '')
$r2 = InMod $hikRec @($cred, '', $r1.tracks, '')
Check ($r1.ok -and $r1.puts -eq 1) 'run 1: track 101 off -> turned on, read back on' $r1.msg
Check ($r2.ok -and $r2.puts -eq 0 -and $r2.msg -match 'already on') 'run 2: already on, nothing written' $r2.msg
$tr = @{ 101 = ('<Track><id>101</id><Enable>false</Enable>' + $sched + '</Track>') }
$r = InMod $hikRec @($cred, '', $tr, 'readback500')
Check (-not $r.ok -and $r.msg -match 'NOT confirmed') 'failing half-way: write sent, read-back fails = NOT confirmed' $r.msg

# ==============================================================================================================================
Write-Host 'F6 DW recording: an unreadable list or unknown schedule flags are NOT "already on for every camera"'
$dwRec = {
  param($cred, [string]$mode, $devs)
  $script:Mode = $mode; $script:Devs = $devs; $script:Patches = 0; $script:Lists = 0
  function script:Dw-Login { return $true }
  function script:Http {
    param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '')
    if ($Method -eq 'PATCH') {
      $script:Patches++
      $id = [uri]::UnescapeDataString(($Path -split '/')[-1])
      foreach ($d in $script:Devs) { if ($d.id -eq $id) { $d.schedule = @{ isEnabled = $true } } }
      return @{ code = 200; body = '{}' }
    }
    if ($Path -like '/rest/v3/devices*') {
      $script:Lists++
      switch ($script:Mode) {
        'list500' { return @{ code = 500; body = 'device list failed' } }
        'html' { return @{ code = 200; body = '<html><body>Please log in</body></html>' } }
        'object' { return @{ code = 200; body = '{"error":"3","errorString":"Forbidden"}' } }
        'empty' { return @{ code = 200; body = '[]' } }
        'readback500' { if ($script:Lists -ge 2) { return @{ code = 500; body = '' } } }
      }
      return @{ code = 200; body = (ConvertTo-Json -InputObject @($script:Devs) -Depth 5 -Compress) }
    }
    return @{ code = 404; body = '' }
  }
  $r = Invoke-NvrFix -Fix recording -Ip '10.0.0.30' -Vendor DW -Credential $cred -Confirm { 'YES' }
  [pscustomobject]@{ ok = $r.ok; ran = $r.ran; msg = [string]$r.msg; patches = $script:Patches; devs = $script:Devs }
}
function DwDev([string]$id, $sched, [switch]$NoSchedule) {
  $d = [ordered]@{ id = $id; name = ('Cam ' + $id); status = 'Online'; url = ('http://10.0.0.' + $id + '/onvif'); model = 'DS-2CD'; vendor = 'Hikvision' }
  if (-not $NoSchedule) { $d.schedule = @{ isEnabled = $sched } }
  return $d
}
$r = InMod $dwRec @($cred, 'list500', @((DwDev '41' $false)))
Check (-not $r.ok) 'Codex dw-list-fails: device list answers 500 -> NOT "already on" (ok=false)' $r.msg
Check ($r.msg -notmatch 'already on' -and $r.msg -match 'NOT CHECKED' -and $r.patches -eq 0) 'dw-list-fails: says NOT CHECKED, nothing written' $r.msg
$r = InMod $dwRec @($cred, 'html', @((DwDev '41' $true)))
Check (-not $r.ok -and $r.patches -eq 0) 'wrong answer: a login page instead of the list = NOT CHECKED' $r.msg
$r = InMod $dwRec @($cred, 'object', @((DwDev '41' $true)))
Check (-not $r.ok -and $r.patches -eq 0) 'wrong answer: a JSON error object instead of a camera list = NOT CHECKED' $r.msg
$r = InMod $dwRec @($cred, 'empty', @())
Check (-not $r.ok -and $r.msg -notmatch 'already on') 'a real but EMPTY camera list = not green (nothing could be checked)' $r.msg
$r = InMod $dwRec @($cred, '', @((DwDev '41' $true), (DwDev '42' $null -NoSchedule)))
Check (-not $r.ok -and $r.msg -match 'NOT CHECKED' -and $r.msg -match '10\.0\.0\.42' -and $r.patches -eq 0) 'a camera with no readable schedule flag = NOT CHECKED (named), never "already on"' $r.msg
$r = InMod $dwRec @($cred, '', @((DwDev '41' $true), (DwDev '42' 'maybe')))
Check (-not $r.ok -and $r.patches -eq 0) 'a schedule flag that is not true/false ("maybe") = unknown' $r.msg
$r = InMod $dwRec @($cred, '', @((DwDev '41' $true), (DwDev '42' $true)))
Check ($r.ok -and $r.msg -match 'already on' -and $r.patches -eq 0) 'control: every camera explicitly on = already on, nothing written' $r.msg
$d1 = @((DwDev '41' $false), (DwDev '42' $true))
$r1 = InMod $dwRec @($cred, '', $d1)
$r2 = InMod $dwRec @($cred, '', $r1.devs)
Check ($r1.ok -and $r1.patches -eq 1) 'run 1: camera 41 off -> turned on in DW, read back on' $r1.msg
Check ($r2.ok -and $r2.patches -eq 0 -and $r2.msg -match 'already on') 'run 2: already on, nothing written' $r2.msg
$r = InMod $dwRec @($cred, 'readback500', @((DwDev '41' $false)))
Check (-not $r.ok -and $r.msg -match 'NOT confirmed') 'failing half-way: PATCH sent, list read-back fails = NOT confirmed' $r.msg
$r = InMod $dwRec @($cred, '', @((DwDev '41' $false), (DwDev '42' $null -NoSchedule)))
Check (-not $r.ok -and $r.patches -eq 1) 'half-known: the off camera is turned on, the unknown one keeps the result not green' $r.msg

# ==============================================================================================================================
Write-Host 'F3 re-add: a different camera on the channel is replaced only when it is POSITIVELY offline'
$readd = {
  param($cred, [string]$mode)
  $script:puts = 0; $script:Mode = $mode; $script:ListReads = 0
  function script:Http {
    param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '')
    if ($Method -eq 'PUT') { $script:puts++; return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } }
    if ($Path -eq '/ISAPI/ContentMgmt/InputProxy/channels') {
      $script:ListReads++
      if ($script:Mode -eq 'wronglist') { return @{ code = 200; body = '<ResponseStatus><statusCode>4</statusCode></ResponseStatus>' } }
      $ip = $(if ($script:puts -or $script:Mode -eq 'already41') { '10.0.0.41' } elseif ($script:Mode -eq 'changes' -and $script:ListReads -ge 2) { '10.0.0.44' } else { '10.0.0.40' })
      return @{ code = 200; body = "<InputProxyChannelList><InputProxyChannel><id>4</id><ipAddress>$ip</ipAddress></InputProxyChannel></InputProxyChannelList>" }
    }
    if ($Path -eq '/ISAPI/ContentMgmt/InputProxy/channels/status') {
      if (-not $script:puts) {
        switch ($script:Mode) {
          'status500' { return @{ code = 500; body = 'status failed' } }
          'nochan' { return @{ code = 200; body = '<InputProxyChannelStatusList><InputProxyChannelStatus><id>3</id><online>false</online></InputProxyChannelStatus></InputProxyChannelStatusList>' } }
          'online' { return @{ code = 200; body = '<InputProxyChannelStatusList><InputProxyChannelStatus><id>4</id><online>true</online></InputProxyChannelStatus></InputProxyChannelStatusList>' } }
          'noflag' { return @{ code = 200; body = '<InputProxyChannelStatusList><InputProxyChannelStatus><id>4</id></InputProxyChannelStatus></InputProxyChannelStatusList>' } }
        }
        if ($script:Mode -ne 'already41') { return @{ code = 200; body = '<InputProxyChannelStatusList><InputProxyChannelStatus><id>4</id><online>false</online></InputProxyChannelStatus></InputProxyChannelStatusList>' } }
      }
      return @{ code = 200; body = '<InputProxyChannelStatusList><InputProxyChannelStatus><id>4</id><online>true</online></InputProxyChannelStatus></InputProxyChannelStatusList>' }
    }
    return @{ code = 404; body = '' }
  }
  $r = Invoke-NvrFix -Fix readd -Ip '10.0.0.20' -Vendor Hikvision -Credential $cred -NewCredential $cred -Channel 4 -CameraIp '10.0.0.41' -Confirm { 'YES' }
  [pscustomobject]@{ ok = $r.ok; ran = $r.ran; msg = [string]$r.msg; puts = $script:puts }
}
$r = InMod $readd @($cred, 'status500')
Check (-not $r.ok -and $r.puts -eq 0) 'Codex readd-status-unread-before-write: list names .40, status 500 -> NOT replaced, 0 writes' ('puts=' + $r.puts + ' ' + $r.msg)
Check ($r.msg -match '10\.0\.0\.40' -and $r.msg -match 'Nothing changed') 'status unread: says the channel is in use by .40 and nothing changed' $r.msg
$r = InMod $readd @($cred, 'nochan')
Check (-not $r.ok -and $r.puts -eq 0) 'the status list does not name the channel = not known offline, 0 writes' $r.msg
$r = InMod $readd @($cred, 'noflag')
Check (-not $r.ok -and $r.puts -eq 0) 'the channel has no online true/false in the status = not known offline, 0 writes' $r.msg
$r = InMod $readd @($cred, 'online')
Check (-not $r.ok -and $r.puts -eq 0) 'the other camera is online = refused, 0 writes (no regression)' $r.msg
$r = InMod $readd @($cred, 'wronglist')
Check (-not $r.ok -and $r.puts -eq 0) 'wrong answer: an error page instead of the channel list = refused, 0 writes' $r.msg
$r = InMod $readd @($cred, 'changes')
Check (-not $r.ok -and $r.puts -eq 0) 'failing half-way: the channel changes camera between the two reads = refused, 0 writes' $r.msg
$r = InMod $readd @($cred, '')
Check ($r.ok -and $r.puts -eq 1) 'control: .40 positively offline -> replaced by .41, read back and online' $r.msg
$r = InMod $readd @($cred, 'already41')
Check ($r.ok -and $r.puts -le 1 -and $r.msg -match '10\.0\.0\.41') 'running twice: the channel already shows .41 -> the same camera is written again at most once, ok' $r.msg

# ==============================================================================================================================
Write-Host 'F5 retention: one camera whose oldest-clip search fails is NOT CHECKED and the result is not green'
$ret = {
  param($cred, [string]$mode)
  $script:Mode = $mode
  function script:Http {
    param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '')
    $b = ''
    switch ($Path) {
      '/ISAPI/System/deviceInfo' { $b = '<DeviceInfo><model>DS-7608</model><serialNumber>review</serialNumber></DeviceInfo>' }
      '/ISAPI/System/time' { $b = '<Time><localTime>2026-11-08T10:00:00</localTime><timeZone>CST+5:00:00</timeZone></Time>' }
      '/ISAPI/ContentMgmt/InputProxy/channels' { $b = '<InputProxyChannelList><InputProxyChannel><id>1</id><ipAddress>10.0.0.41</ipAddress></InputProxyChannel><InputProxyChannel><id>2</id><ipAddress>10.0.0.42</ipAddress></InputProxyChannel></InputProxyChannelList>' }
      '/ISAPI/ContentMgmt/InputProxy/channels/status' { $b = '<InputProxyChannelStatusList><InputProxyChannelStatus><id>1</id><online>true</online></InputProxyChannelStatus><InputProxyChannelStatus><id>2</id><online>true</online></InputProxyChannelStatus></InputProxyChannelStatusList>' }
      '/ISAPI/ContentMgmt/record/tracks' { $b = '<TrackList><Track><id>101</id><Enable>true</Enable></Track><Track><id>201</id><Enable>true</Enable></Track></TrackList>' }
      '/ISAPI/ContentMgmt/Storage' { $b = '<storage><hddList><hdd><id>1</id><capacity>1000000</capacity><freeSpace>0</freeSpace><status>ok</status><property>RW</property></hdd></hddList></storage>' }
      '/ISAPI/ContentMgmt/search' {
        $oldest = ($Body -match '2000-01-01')
        if ($oldest -and (($script:Mode -eq 'ch2fail' -and $Body -match '<trackID>201</trackID>') -or $script:Mode -eq 'bothfail')) { return @{ code = 500; body = 'search failed' } }
        if ($oldest -and $script:Mode -eq 'ch2wrong' -and $Body -match '<trackID>201</trackID>') { return @{ code = 200; body = '<ResponseStatus><statusCode>4</statusCode></ResponseStatus>' } }
        $b = '<CMSearchResult><responseStatusStrg>OK</responseStatusStrg><matchList><searchMatchItem><timeSpan><startTime>2026-09-19T10:00:00Z</startTime><endTime>2026-11-08T09:59:00Z</endTime></timeSpan></searchMatchItem></matchList></CMSearchResult>'
      }
      default { return @{ code = 404; body = '' } }
    }
    return @{ code = 200; body = $b }
  }
  $r = Get-RecordingStatus -Ip '10.0.0.20' -Vendor Hikvision -Credential $cred -TargetDays 30
  [pscustomobject]@{ ok = $r.ok; problems = @($r.problems); ch2 = @($r.channels | Where-Object { $_.ch -eq 2 })[0]; summary = [string]@(Get-NvrHealthSummary)[-1] }
}
$r = InMod $ret @($cred, 'ch2fail')
Check (-not $r.ok) 'Codex one-camera-retention-unread: channel 2 oldest search 500, channel 1 has 50 days -> ok=false' $r.summary
Check ($r.summary -notmatch 'target met' -and (($r.problems -join ';') -match 'NOT CHECKED')) 'one-camera-retention-unread: no "30-day target met"; problem says days held NOT CHECKED' (($r.problems -join '; ') + ' | ' + $r.summary)
Check ($null -eq $r.ch2.days_held) 'channel 2 days held stays unknown (not invented)'
$r = InMod $ret @($cred, 'ch2wrong')
Check (-not $r.ok -and $r.summary -notmatch 'target met') 'wrong answer: channel 2 oldest search answers an error page (not a search result) = NOT CHECKED, not green' $r.summary
$r = InMod $ret @($cred, 'bothfail')
Check (-not $r.ok -and $r.summary -notmatch 'target met') 'both cameras oldest search fail = not green' $r.summary
$r = InMod $ret @($cred, '')
Check ($r.ok -and $r.summary -match 'target met') 'control: both searches answer, 50 days each = target met (no regression)' (($r.problems -join '; ') + ' | ' + $r.summary)
$ra = InMod $ret @($cred, 'ch2fail'); $rb = InMod $ret @($cred, 'ch2fail')
Check (-not $ra.ok -and -not $rb.ok -and $ra.summary -eq $rb.summary) 'running twice: the same honest NOT CHECKED result both times (read-only, nothing written)' $rb.summary

# ==============================================================================================================================
Write-Host 'F7 password: a lost / non-OK write answer is reconciled (new, then old password) - never "the old one still works" unchecked'
$pw = {
  param($cred, $newCred, [string]$mode, [bool]$Twice = $false)
  $script:changed = $false; $script:Locked = $false; $script:verifyReads = 0; $script:Mode = $mode; $script:Puts = 0
  function script:Http {
    param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '')
    if ($Method -eq 'PUT' -and $Path -eq '/ISAPI/Security/users/1') {
      $script:Puts++
      switch ($script:Mode) {
        'applied-lost' { $script:changed = $true; return @{ code = 0; body = ''; err = 'connection closed after applying password' } }
        'notapplied-lost' { return @{ code = 0; body = ''; err = 'timeout' } }
        'refused' { return @{ code = 200; body = '<ResponseStatus><statusCode>4</statusCode><statusString>Invalid Operation</statusString></ResponseStatus>' } }
        'locked' { $script:Locked = $true; return @{ code = 0; body = ''; err = 'closed' } }
        default { $script:changed = $true; return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } }
      }
    }
    if ($Path -eq '/ISAPI/System/deviceInfo') {
      $p = $Credential.GetNetworkCredential().Password
      if ($script:Locked) { $script:verifyReads++; return @{ code = 0; body = '' } }
      if ($script:changed) { $script:verifyReads++; if ($p -ne 'NewReview456') { return @{ code = 401; body = '' } } }
      elseif ($p -ne 'Review123') { if ($script:Puts) { $script:verifyReads++ }; return @{ code = 401; body = '' } }
      elseif ($script:Puts) { $script:verifyReads++ }
      return @{ code = 200; body = '<DeviceInfo><model>DS-2CD2143</model><serialNumber>REVIEWCAM</serialNumber></DeviceInfo>' }
    }
    return @{ code = 404; body = '' }
  }
  $r = Invoke-NvrFix -Fix password -Ip '10.0.0.41' -Vendor Hikvision -Credential $cred -NewCredential $newCred -Confirm { 'YES' }
  $o = [pscustomobject]@{ ok = $r.ok; msg = [string]$r.msg; history = [string]$r.history; reads = $script:verifyReads; puts = $script:Puts; second = $null }
  if ($Twice) { $script:Puts = 0; $r2 = Invoke-NvrFix -Fix password -Ip '10.0.0.41' -Vendor Hikvision -Credential $newCred -NewCredential $newCred -Confirm { 'YES' }; $o.second = [pscustomobject]@{ ok = $r2.ok; msg = [string]$r2.msg; puts = $script:Puts } }
  $o
}
$r = InMod $pw @($cred, $newCred, 'applied-lost')
Check ($r.msg -notmatch 'old one still works') 'Codex password-write-applied-response-lost: never says "The old one still works"' $r.msg
Check ($r.reads -ge 1) 'applied-lost: the password is checked after the lost answer (verification reads)' ('reads=' + $r.reads)
Check ($r.ok -and $r.msg -match 'IS changed' -and $r.msg -match 'DW/NVR') 'applied-lost: the new password logs in -> says it IS changed and to update the recorders' $r.msg
$r = InMod $pw @($cred, $newCred, 'notapplied-lost')
Check (-not $r.ok -and $r.msg -match 'old one still works \(checked\)') 'lost answer, NOT applied: the old password is tested and works -> refused, old one works (checked)' $r.msg
$r = InMod $pw @($cred, $newCred, 'refused')
Check (-not $r.ok -and $r.msg -match '\(checked\)' -and $r.reads -ge 1) 'explicit refusal: still reconciled with a real login before "old one still works"' $r.msg
$r = InMod $pw @($cred, $newCred, 'locked')
Check (-not $r.ok -and $r.msg -match 'MAY have changed' -and $r.msg -match 'NVR') 'failing half-way: lost answer and neither password logs in -> UNKNOWN / maybe changed, update the recorders' $r.msg
Check ($r.history -match 'UNKNOWN') 'maybe-changed is recorded in the history as UNKNOWN, not as refused' $r.history
$r1 = InMod $pw @($cred, $newCred, '', $true)
Check ($r1.ok -and $r1.second.ok -and $r1.second.puts -eq 1) 'running twice: run 1 changes it; run 2 (logging in with the new one) writes once and confirms with a login' ($r1.msg + ' | ' + $r1.second.msg)
$r = InMod $pw @($newCred, $newCred, 'applied-lost')
Check ($r.puts -eq 0 -and -not $r.ok -and $r.msg -match 'Nothing changed') 'wrong password typed as the current one = no write at all (one login try)' $r.msg

# real devices: every answer above is a stand-in
Write-Host 'DEFERRED real Hikvision NVR / camera and DW server answers (track lists, channel status, search results, password write): stand-ins only - NEEDS A REAL-DEVICE CHECK'
$script:deferred++
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ''
Write-Host ('Test-Fix2214Nvr: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:deferred + ' deferred')
if ($script:fail) { exit 1 }
exit 0
