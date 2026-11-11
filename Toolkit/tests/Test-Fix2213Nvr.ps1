<# Test-Fix2213Nvr.ps1 - tests for WireIt Toolkit 2.2.13 (Nov 10 2026), the NvrHealth / NvrFix part of Codex's NO-GO review of 2.2.12
   (head ea667c6): #5 retention gaps, #6 re-add camera read-back, #7 recording list read, #8 restart confirmation.
   Codex's reproductions (reproduce-retention / -readd / -recording / -restart) were not sent to us; they are rebuilt here from the
   review's evidence as permanent checks. Moshe's rule: every change is tested for failing half-way, the wrong device and running twice.
   Every check RUNS the real module functions (Get-RecordingStatus, Invoke-NvrFix) with a stand-in for the device's web answers.
   No real device is touched. PS 5.1 or pwsh 7. FIX2213NVR_DIR (tests only) = run against another copy of the module (old-code proof). #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot
$modDir = $(if ($env:FIX2213NVR_DIR) { $env:FIX2213NVR_DIR } else { Join-Path $tk 'modules\NvrHealth' })
$nhMod = Join-Path $modDir 'NvrHealth.psm1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2213nvr-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + $more) } }
}
foreach ($f in @($nhMod, (Join-Path $modDir 'NvrFix.ps1'))) {
  $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$e); Check ($e.Count -eq 0) ('parses: ' + (Split-Path -Leaf $f)) ($e | Out-String)
}
$cred = New-Object PSCredential('admin', (ConvertTo-SecureString 'x1234567' -AsPlainText -Force))

try {
# ==============================================================================================================================
Write-Host '#5 retention: a real empty stretch longer than 36 h is a hole, wherever it falls (Codex REVIEW_40hourGap)'
$nm = Import-Module $nhMod -Force -PassThru -DisableNameChecking
& $nm { param($ld) Set-NvrHealthOption LogDir $ld } (Join-Path $tmp 'nhlogs')
$run = {
  param($nm, [object[]]$spans, [int]$Target = 30, [int]$FailAfter = -1, [string]$SearchMode = '')
  & $nm {
    param($spans, $target, $failAfter, $searchMode, $cred)
    $script:FakeSpans = $spans; $script:FakeNow = [datetime]'2026-11-08T10:00:00'; $script:FakeSearches = 0; $script:FakeFailAfter = $failAfter; $script:FakeMode = $searchMode
    function script:Http {
      param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '')
      $ok = { param($b) [pscustomobject]@{ code = 200; body = $b; err = '' } }
      switch -Wildcard ($Path) {
        '/ISAPI/System/deviceInfo' { return (& $ok '<DeviceInfo><model>DS-7608NI-K2</model><serialNumber>S1</serialNumber><firmwareVersion>V4.1</firmwareVersion></DeviceInfo>') }
        '/ISAPI/System/time' { return (& $ok ('<Time><timeMode>NTP</timeMode><localTime>' + $script:FakeNow.ToString('yyyy-MM-ddTHH:mm:ss') + '</localTime><timeZone>CST+5:00:00</timeZone></Time>')) }
        '/ISAPI/ContentMgmt/InputProxy/channels' { return (& $ok '<InputProxyChannelList><InputProxyChannel><id>1</id><name>Door</name><ipAddress>10.0.0.64</ipAddress></InputProxyChannel></InputProxyChannelList>') }
        '/ISAPI/ContentMgmt/InputProxy/channels/status' { return (& $ok '<InputProxyChannelStatusList><InputProxyChannelStatus><id>1</id><online>true</online><chanDetectResult>connect</chanDetectResult></InputProxyChannelStatus></InputProxyChannelStatusList>') }
        # 2.2.15 (Codex 2.2.14 R5): the stand-in track has a real recording schedule; Enable alone (no schedule) is now NOT CHECKED
        '/ISAPI/ContentMgmt/record/tracks' { return (& $ok '<TrackList><Track><id>101</id><Enable>true</Enable><TrackSchedule><ScheduleBlock><ScheduleAction><Actions><Record>true</Record></Actions></ScheduleAction></ScheduleBlock></TrackSchedule></Track></TrackList>') }
        '/ISAPI/ContentMgmt/Storage' { return (& $ok '<storage><hddList><hdd><id>1</id><capacity>3815447</capacity><freeSpace>0</freeSpace><status>ok</status><property>RW</property></hdd></hddList></storage>') }
        '/ISAPI/ContentMgmt/search' {
          $script:FakeSearches++
          if ($script:FakeFailAfter -ge 0 -and $script:FakeSearches -gt $script:FakeFailAfter) { return [pscustomobject]@{ code = 500; body = ''; err = 'x' } }
          if ($script:FakeMode -eq 'html' -and $script:FakeSearches -gt 2) { return (& $ok '<html><body>login</body></html>') }
          $fs = [datetime][regex]::Match($Body, '<startTime>([^<Z]+)').Groups[1].Value; $fe = [datetime][regex]::Match($Body, '<endTime>([^<Z]+)').Groups[1].Value
          $mx = [int][regex]::Match($Body, '<maxResults>(\d+)<').Groups[1].Value
          $hit = @($script:FakeSpans | Where-Object { [datetime]$_[0] -lt $fe -and [datetime]$_[1] -gt $fs } | Sort-Object { [datetime]$_[0] })
          $st = 'OK'; if ($hit.Count -gt $mx) { $hit = @($hit | Select-Object -First $mx); $st = 'MORE' }
          $items = -join ($hit | ForEach-Object { '<searchMatchItem><timeSpan><startTime>' + ([datetime]$_[0]).ToString('yyyy-MM-ddTHH:mm:ss') + 'Z</startTime><endTime>' + ([datetime]$_[1]).ToString('yyyy-MM-ddTHH:mm:ss') + 'Z</endTime></timeSpan></searchMatchItem>' })
          return (& $ok ('<CMSearchResult><responseStatusStrg>' + $(if ($hit.Count) { $st } else { 'NO MATCHES' }) + '</responseStatusStrg><matchList>' + $items + '</matchList></CMSearchResult>'))
        }
        default { return [pscustomobject]@{ code = 404; body = ''; err = '' } }
      }
    }
    $script:LoginState = @{}
    $r = Get-RecordingStatus -Ip '10.0.0.20' -Vendor Hikvision -Credential $cred -TargetDays $target -NoLog
    $r | Add-Member -NotePropertyName searches -NotePropertyValue $script:FakeSearches -Force
    $r
  } $spans $Target $FailAfter $SearchMode $cred
}
$now = [datetime]'2026-11-08T10:00:00'
function Span($fromDaysAgo, $toDaysAgo) { return ,@($now.AddDays(-$fromDaysAgo).ToString('s'), $now.AddDays(-$toDaysAgo).ToString('s')) }
function Dh($r) { $c = @($r.channels); if ($c.Count) { return $c[0].days_held }; return 'no channel' }
# Codex REVIEW_40hourGap: 50 days of footage except 10.6 to 8.9 days ago (40.8 h missing), target 30
$g40 = @((Span 50 10.6), (Span 8.9 0.001))
$r = & $run $nm $g40 30
$dh = Dh $r
Check (-not $r.ok) ('reproduction REVIEW_40hourGap: a 40.8 h hole 8.9-10.6 days ago -> target NOT met (2.2.12 said ok=true; ok=' + $r.ok + ')')
Check ($null -ne $dh -and [int]$dh -ge 8 -and [int]$dh -le 9) ('...days held stops at the hole: 8 (got ' + $dh + ')')
Check (@($r.problems).Count -gt 0) ('...and it is listed as a problem (' + (@($r.problems) -join '; ') + ')')
# the owner's allowance stays: a quiet stretch SHORTER than 36 h is not a hole (motion cameras)
$r = & $run $nm @((Span 50 10.6), (Span 9.4 0.001)) 30
Check ($r.ok -and [int](Dh $r) -ge 49) ('a 28.8 h quiet stretch is not a hole: target met, 50 days (ok=' + $r.ok + ', ' + (Dh $r) + ')')
# 37 h (just over) is a hole; placed between two 24 h steps
$r = & $run $nm @((Span 50 20.3), (Span 18.75 0.001)) 30
Check (-not $r.ok -and [int](Dh $r) -eq 18) ('a 37 h hole 18.75-20.3 days ago -> 18 days, not met (ok=' + $r.ok + ', ' + (Dh $r) + ')')
# a hole right at the edge of the fully-read part (60 days) with older footage behind it
$r = & $run $nm @((Span 200 61.5), (Span 59.4 0.001)) 30
$dh = Dh $r
Check ($null -ne $dh -and [int]$dh -le 60) ('a 50 h hole 59.4-61.5 days ago with 200 days of older clips -> days held stops at 59, not 200 (got ' + $dh + ')')
# truncated answers (motion: 3 clips an hour) are split until complete - a 40 h hole between busy days is found
$many = @(); for ($m = 40 * 72; $m -ge 1; $m--) { $s0 = $now.AddMinutes(-20 * $m); if ($s0 -lt $now.AddDays(-12.2) -or $s0 -ge $now.AddDays(-10.5)) { $many += ,@($s0.ToString('s'), $s0.AddMinutes(5).ToString('s')) } }
$r = & $run $nm $many 30
$dh = Dh $r
Check (-not $r.ok -and $null -ne $dh -and [int]$dh -eq 10) ('motion clips (every search full) with a 40.8 h hole 10.5-12.2 days ago -> found: 10 days, not met (ok=' + $r.ok + ', ' + $dh + ')')
$r2 = & $run $nm $many 30 -1
Check ([int]$r2.searches -le 120) ('...the split searches stay bounded (' + $r2.searches + ' searches)')
# a full answer that can not be split complete (more than 200 clips in 2 hours) = UNKNOWN, never continuous
$dense = @(); for ($m = 0; $m -lt 2400; $m++) { $s0 = $now.AddDays(-5).AddSeconds(3 * $m); $dense += ,@($s0.ToString('s'), $s0.AddSeconds(2).ToString('s')) }
$dense += ,(Span 40 5.01); $dense += ,(Span 4.99 0.001)
$r = & $run $nm $dense 30
Check (-not $r.ok -and $null -eq (Dh $r)) ('200+ clips in under 2 hours (can not be read completely) -> days held UNKNOWN, not met (ok=' + $r.ok + ', ' + (Dh $r) + ')')
# failing half-way: the 5th footage search fails
$r = & $run $nm @(,(Span 50 0.001)) 30 4
Check (-not $r.ok -and $null -eq (Dh $r)) ('a footage search failing half-way -> days held UNKNOWN, not met (ok=' + $r.ok + ', ' + (Dh $r) + ')')
# wrong device / wrong answer: the recorder answers searches with a login page after the first two
$r = & $run $nm @(,(Span 50 0.001)) 30 -1 'html'
Check (-not $r.ok -and $null -eq (Dh $r)) ('a search answered with a login page (not a search result) -> UNKNOWN, not met (ok=' + $r.ok + ', ' + (Dh $r) + ')')
# no regressions: continuous 50 days still met with few searches; the 2.2.11 R9 5-day hole still found
$r = & $run $nm @(,(Span 50 0.001)) 30
Check ($r.ok -and [int](Dh $r) -ge 49 -and [int]$r.searches -le 20) ('50 days continuous -> met, ' + $r.searches + ' searches (ok=' + $r.ok + ', ' + (Dh $r) + ')')
$r = & $run $nm @((Span 32 19.6), (Span 14.9 0.001)) 30
Check (-not $r.ok -and [int](Dh $r) -eq 14) ('2.2.11 R9 (5-day hole 15-19 days ago) still found: 14 days (' + (Dh $r) + ')')
# running twice: same answer
$a1 = Dh (& $run $nm $g40 30); $a2 = Dh (& $run $nm $g40 30)
Check ($a1 -eq $a2) ('running twice: the same days held both times (' + $a1 + ' / ' + $a2 + ')')
Remove-Module NvrHealth -Force -ErrorAction SilentlyContinue

# ==============================================================================================================================
Write-Host '#6 re-add camera: success needs the channel READ BACK with the requested address AND online (Codex reproduce-readd)'
$nm = Import-Module $nhMod -Force -PassThru -DisableNameChecking
& $nm { param($ld) Set-NvrHealthOption LogDir $ld } (Join-Path $tmp 'nhlogs6')
$ra = {
  param($nm, [string]$mode, [string]$startIp = '10.0.0.40', [bool]$startOnline = $false, [string]$want = '10.0.0.41')
  & $nm {
    param($mode, $startIp, $startOnline, $want, $cred)
    $script:Ch4 = @{ ip = $startIp; online = $startOnline }; $script:Mode = $mode; $script:Puts = 0; $script:ListReads = 0
    function script:Http {
      param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '')
    if ($Path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = '<DeviceInfo><model>DS-7608NI-K2</model><serialNumber>TESTDEV0001</serialNumber><macAddress>AA:BB:CC:00:00:01</macAddress><firmwareVersion>V4.1</firmwareVersion><firmwareReleasedDate>build 240101</firmwareReleasedDate></DeviceInfo>' } }   # 2.2.19: the device says who it is (NvrFix re-identifies it before every write)
      $r = { param($c, $b) [pscustomobject]@{ code = $c; body = $b; err = '' } }
      if ($Method -eq 'PUT' -and $Path -eq '/ISAPI/ContentMgmt/InputProxy/channels/4') {
        $script:Puts++
        $ip = [regex]::Match($Body, '<ipAddress>([^<]+)<').Groups[1].Value
        switch ($script:Mode) {
          'ignore' { $script:Ch4.online = $true }                                   # says OK, keeps the OLD camera, which comes back online
          'other' { $script:Ch4.ip = '10.0.0.99'; $script:Ch4.online = $true }      # the recorder put some other camera there
          'offline' { $script:Ch4.ip = $ip; $script:Ch4.online = $false }           # applied, camera not online (wrong password)
          default { $script:Ch4.ip = $ip; $script:Ch4.online = $true }
        }
        return (& $r 200 '<ResponseStatus><statusCode>1</statusCode><statusString>OK</statusString></ResponseStatus>')
      }
      if ($Path -eq '/ISAPI/ContentMgmt/InputProxy/channels') {
        $script:ListReads++
        if ($script:Mode -eq 'failread' -and $script:Puts -gt 0) { return (& $r 500 '<html>error</html>') }
        if ($script:Mode -eq 'emptyread' -and $script:Puts -gt 0) { return (& $r 200 '') }
        return (& $r 200 ('<InputProxyChannelList><InputProxyChannel><id>4</id><name>Gate</name><sourceInputPortDescriptor><ipAddress>' + $script:Ch4.ip + '</ipAddress></sourceInputPortDescriptor></InputProxyChannel></InputProxyChannelList>'))
      }
      if ($Path -eq '/ISAPI/ContentMgmt/InputProxy/channels/status') {
        if ($script:Mode -eq 'failstatus' -and $script:Puts -gt 0) { return (& $r 0 '') }
        return (& $r 200 ('<InputProxyChannelStatusList><InputProxyChannelStatus><id>4</id><online>' + $(if ($script:Ch4.online) { 'true' } else { 'false' }) + '</online></InputProxyChannelStatus></InputProxyChannelStatusList>'))
      }
      return (& $r 404 '')
    }
    $script:LoginState = @{}
    $nc = New-Object PSCredential('admin', (ConvertTo-SecureString 'Campass123' -AsPlainText -Force))
    $o = Invoke-NvrFix -Fix readd -Ip '10.0.0.20' -Vendor Hikvision -Credential $cred -Channel 4 -CameraIp $want -NewCredential $nc -Confirm { 'YES' }
    $o | Add-Member -NotePropertyName puts -NotePropertyValue $script:Puts -Force
    $o
  } $mode $startIp $startOnline $want $cred
}
$o = & $ra $nm 'ignore'
Check (-not $o.ok -and $o.msg -notmatch 'is on channel 4 and online') ('reproduction: NVR says OK but keeps 10.0.0.40 (back online) -> NOT done, not "10.0.0.41 is on channel 4 and online" (ok=' + $o.ok + ', ' + $o.msg + ')')
Check ($o.msg -match '10\.0\.0\.40') ('...and it says what the channel really shows (' + $o.msg + ')')
$o = & $ra $nm 'other'
Check (-not $o.ok -and $o.msg -match '10\.0\.0\.99') ('wrong camera: the channel shows another address 10.0.0.99 (online) -> NOT done (ok=' + $o.ok + ')')
$o = & $ra $nm 'apply'
Check ($o.ok -and $o.msg -match 'read back') ('applied and online -> done, read back (ok=' + $o.ok + ', ' + $o.msg + ')')
$o = & $ra $nm 'offline'
Check (-not $o.ok -and $o.msg -match 'not show it online') ('applied but not online -> not done (ok=' + $o.ok + ')')
$o = & $ra $nm 'failread'
Check (-not $o.ok -and $o.msg -match 'NOT confirmed') ('failing half-way: the channel list read-back fails (HTTP 500) -> NOT confirmed (ok=' + $o.ok + ', ' + $o.msg + ')')
$o = & $ra $nm 'emptyread'
Check (-not $o.ok -and $o.msg -match 'NOT confirmed') ('the read-back is an empty 200 answer -> NOT confirmed (ok=' + $o.ok + ')')
$o = & $ra $nm 'failstatus'
Check (-not $o.ok -and $o.msg -match 'NOT confirmed') ('the channel status read-back gives no answer -> NOT confirmed (ok=' + $o.ok + ')')
# running twice: the 2nd run on a channel that already has the camera: honest, done (sends the same channel again)
$o = & $ra $nm 'apply' '10.0.0.41' $true
Check ($o.ok -and $o.puts -le 1) ('running twice: channel already shows 10.0.0.41 online -> done, nothing broken (ok=' + $o.ok + ', puts=' + $o.puts + ')')
Remove-Module NvrHealth -Force -ErrorAction SilentlyContinue

# ==============================================================================================================================
Write-Host '#7 recording repair: an unreadable track list is NOT CHECKED, never "already on for every camera" (Codex reproduce-recording)'
$nm = Import-Module $nhMod -Force -PassThru -DisableNameChecking
& $nm { param($ld) Set-NvrHealthOption LogDir $ld } (Join-Path $tmp 'nhlogs7')
$rr = {
  param($nm, [string]$mode)
  & $nm {
    param($mode, $cred)
    $script:En = @{ 101 = 'false'; 201 = 'true' }; $script:Mode = $mode; $script:Reads = 0; $script:Puts = 0
    function script:Http {
      param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '')
    if ($Path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = '<DeviceInfo><model>DS-7608NI-K2</model><serialNumber>TESTDEV0001</serialNumber><macAddress>AA:BB:CC:00:00:01</macAddress><firmwareVersion>V4.1</firmwareVersion><firmwareReleasedDate>build 240101</firmwareReleasedDate></DeviceInfo>' } }   # 2.2.19: the device says who it is (NvrFix re-identifies it before every write)
      $r = { param($c, $b) [pscustomobject]@{ code = $c; body = $b; err = '' } }
      # 2.2.14 (Codex 2.2.13 F9): a track now needs its schedule entries to count as known (a track without them is UNKNOWN), so the
      # stand-in carries a real schedule like a real recorder does
      $trk = { param($id) '<Track><id>' + $id + '</id><Channel>' + $id + '</Channel><Enable>' + $script:En[$id] + '</Enable><TrackSchedule><ScheduleBlock><ScheduleAction><Actions><Record>true</Record><ActionRecordingMode>CMR</ActionRecordingMode></Actions></ScheduleAction></ScheduleBlock></TrackSchedule></Track>' }
      if ($Path -eq '/ISAPI/ContentMgmt/record/tracks') {
        $script:Reads++
        switch ($script:Mode) {
          'second500' { if ($script:Reads -ge 2) { return (& $r 500 '') } }
          'first500' { return (& $r 500 '') }
          'html' { return (& $r 200 '<html><body>Please log in</body></html>') }
          'empty' { return (& $r 200 '<TrackList></TrackList>') }
        }
        $ids = @($script:En.Keys | Sort-Object); if ($script:Mode -eq 'allon') { foreach ($k in $ids) { $script:En[$k] = 'true' } }
        return (& $r 200 ('<TrackList>' + (-join ($ids | ForEach-Object { & $trk $_ })) + '</TrackList>'))
      }
      $m = [regex]::Match($Path, '^/ISAPI/ContentMgmt/record/tracks/(\d+)$')
      if ($m.Success) {
        $id = [int]$m.Groups[1].Value
        if ($Method -eq 'PUT') { $script:Puts++; if ($script:Mode -ne 'putignored') { $script:En[$id] = $(if ($Body -match '<Enable>true</Enable>') { 'true' } else { 'false' }) }; return (& $r 200 '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>') }
        if ($script:Mode -eq 'wrongtrack') { return (& $r 200 (& $trk 201)) }
        return (& $r 200 (& $trk $id))
      }
      return (& $r 404 '')
    }
    $script:LoginState = @{}
    $o = Invoke-NvrFix -Fix recording -Ip '10.0.0.20' -Vendor Hikvision -Credential $cred -Confirm { 'YES' }
    $o | Add-Member -NotePropertyName puts -NotePropertyValue $script:Puts -Force
    $o | Add-Member -NotePropertyName en101 -NotePropertyValue $script:En[101] -Force
    $o
  } $mode $cred
}
$o = & $rr $nm 'second500'
Check (-not $o.ok -and $o.msg -notmatch 'already on') ('reproduction: 1st read shows track 101 OFF, the next read is HTTP 500 -> never "already on for every camera" (ok=' + $o.ok + ', ' + $o.msg + ')')
$o = & $rr $nm 'first500'
Check (-not $o.ok -and $o.puts -eq 0 -and $o.msg -match 'NOT CHECKED') ('the list read fails (HTTP 500) -> NOT CHECKED, nothing written (ok=' + $o.ok + ', ' + $o.msg + ')')
$o = & $rr $nm 'html'
Check (-not $o.ok -and $o.puts -eq 0) ('wrong answer: a login page instead of the list -> not checked, nothing written (ok=' + $o.ok + ')')
$o = & $rr $nm 'empty'
Check (-not $o.ok -and $o.msg -notmatch 'already on') ('a valid but EMPTY list -> not green "already on" (ok=' + $o.ok + ', ' + $o.msg + ')')
$o = & $rr $nm 'allon'
Check ($o.ok -and $o.puts -eq 0 -and $o.msg -match 'already on') ('every track on -> "already on", nothing written (no regression; ok=' + $o.ok + ')')
$o = & $rr $nm 'normal'
Check ($o.ok -and $o.en101 -eq 'true' -and $o.puts -eq 1) ('track 101 off -> turned on and read back on (ok=' + $o.ok + ', puts=' + $o.puts + ')')
$o = & $rr $nm 'putignored'
Check (-not $o.ok -and $o.msg -match 'Still off') ('failing half-way: the recorder says OK but keeps it off -> "Still off", red (ok=' + $o.ok + ')')
$o = & $rr $nm 'wrongtrack'
Check (-not $o.ok -and $o.puts -eq 0) ('wrong device answer: the single-track read returns ANOTHER track -> not written, not green (ok=' + $o.ok + ', puts=' + $o.puts + ')')
# running twice: the 2nd run finds everything on and writes nothing (state carried over by using the "allon" view)
$o = & $rr $nm 'allon'
Check ($o.ok -and $o.puts -eq 0) 'running twice: the 2nd run sees all on, writes nothing'
Remove-Module NvrHealth -Force -ErrorAction SilentlyContinue

# ==============================================================================================================================
Write-Host '#8 camera restart: an HTTP error answer is not "went down"; a boot marker (uptime) is preferred (Codex REVIEW_restart500)'
$nm = Import-Module $nhMod -Force -PassThru -DisableNameChecking
& $nm { param($ld) Set-NvrHealthOption LogDir $ld } (Join-Path $tmp 'nhlogs8')
$rs = {
  param($nm, [string]$plan, [string]$state, [int]$wait = 3)
  # $plan: comma list of what each poll after the reboot request answers: 'up:<sec>' (status 200 with uptime), 'ok' (200, no
  # uptime given), 'e500' (HTTP 500), 'none' (no answer, code 0). The last item repeats. 'nouptime' prefix = the camera has no
  # /ISAPI/System/status (404).
  & $nm {
    param($plan, $state, $wait, $cred)
    $script:NoUp = $plan.StartsWith('nouptime;'); $p = $plan -replace '^nouptime;', ''
    $script:Plan = @($p -split ','); $script:Step = -1; $script:Reb = 0
    function script:Http {
      param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '')
      $r = { param($c, $b) [pscustomobject]@{ code = $c; body = $b; err = '' } }
      if ($Method -eq 'PUT' -and $Path -match '(?i)reboot') { $script:Reb++; $script:Step = 0; return (& $r 200 '<ResponseStatus><statusCode>1</statusCode><statusString>OK</statusString></ResponseStatus>') }
      $cur = 'up:5000'
      if ($script:Step -ge 0) { $i = [math]::Min($script:Step, $script:Plan.Count - 1); $cur = $script:Plan[$i]; $script:Step++ }
      if ($Path -eq '/ISAPI/System/status' -and $script:NoUp) { if ($cur -eq 'none') { return (& $r 0 '') }; if ($cur -eq 'e500') { return (& $r 500 '') }; return (& $r 404 '') }
      if ($cur -eq 'none') { return (& $r 0 '') }
      if ($cur -eq 'e500') { return (& $r 500 '<html>Internal error</html>') }
      if ($Path -eq '/ISAPI/System/status') { if ($cur -like 'up:*') { return (& $r 200 ('<DeviceStatus><deviceUpTime>' + $cur.Substring(3) + '</deviceUpTime></DeviceStatus>')) }; return (& $r 200 '<DeviceStatus></DeviceStatus>') }
      if ($Path -eq '/ISAPI/System/deviceInfo') { return (& $r 200 '<DeviceInfo><model>DS-2CD2143G2-I</model><serialNumber>S1</serialNumber></DeviceInfo>') }
      return (& $r 404 '')
    }
    $script:LoginState = @{}
    $o = Invoke-NvrFix -Fix restart -Ip '10.9.0.21' -Vendor Hikvision -Credential $cred -StateFile $state -Confirm { 'YES' } -WaitSec $wait
    $o | Add-Member -NotePropertyName reboots -NotePropertyValue $script:Reb -Force
    $o
  } $plan $state $wait $cred
}
$o = & $rs $nm 'nouptime;e500,e500,e500,ok' (Join-Path $tmp 'l1.json')
Check (-not $o.ok -and $o.history -notmatch 'restarted, back online') ('reproduction REVIEW_restart500: accepted, HTTP 500 while "down", then 200 -> NOT confirmed (2.2.12 said restarted; ok=' + $o.ok + ', ' + $o.history + ')')
$o = & $rs $nm 'e500,e500,up:5010' (Join-Path $tmp 'l2.json')
Check (-not $o.ok) ('HTTP 500 answers and the uptime keeps counting -> NOT confirmed (ok=' + $o.ok + ', ' + $o.history + ')')
$o = & $rs $nm 'up:5003,up:12' (Join-Path $tmp 'l3.json')
Check ($o.ok -and $o.history -match 'uptime') ('the uptime starts again from 12 s (fast reboot, never seen offline) -> restarted (ok=' + $o.ok + ', ' + $o.history + ')')
$o = & $rs $nm 'none,none,up:20' (Join-Path $tmp 'l4.json')
Check ($o.ok) ('offline, then back with a fresh uptime -> restarted (ok=' + $o.ok + ')')
$o = & $rs $nm 'none,none,up:5040' (Join-Path $tmp 'l5.json')
Check (-not $o.ok -and $o.msg -match 'uptime kept counting') ('wrong thing: it dropped off the network but its uptime kept counting (a network blip, not a restart) -> NOT confirmed (ok=' + $o.ok + ', ' + $o.msg + ')')
$o = & $rs $nm 'none,none,ok' (Join-Path $tmp 'l6.json')
Check (-not $o.ok) ('offline then back, but the uptime can no longer be read (ambiguous) -> NOT confirmed (ok=' + $o.ok + ')')
$o = & $rs $nm 'nouptime;none,none,ok' (Join-Path $tmp 'l7.json') 4
Check ($o.ok) ('a camera without an uptime: no answer at all, then back -> restarted (as 2.2.12) (ok=' + $o.ok + ')')
$o = & $rs $nm 'none' (Join-Path $tmp 'l8.json')
Check (-not $o.ok -and $o.history -match 'NOT back yet') ('failing half-way: offline and never back -> "NOT back yet", red (' + $o.history + ')')
$o = & $rs $nm 'none,none,up:20' (Join-Path $tmp 'l4.json')
Check (-not $o.ok -and $o.reboots -eq 0 -and $o.msg -match 'last hour') ('running twice: the 2nd restart in the hour is refused, nothing sent (' + $o.msg + ')')
Remove-Module NvrHealth -Force -ErrorAction SilentlyContinue
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
Write-Host ''
Write-Host ('Test-Fix2213Nvr: ' + $script:pass + ' passed, ' + $script:fail + ' failed')
if ($script:fail) { exit 1 }; exit 0
