param([string]$Repo = '')
# Adapted from the Codex 2.2.14 review (evidence/review/reproduce-recording.ps1). Runs the PRODUCTION code of -Repo with
# stand-ins for the device (loopback only, nothing real is contacted) and ASSERTS the safe outcome.
# Prints PASS/FAIL per check, then "N passed, M failed"; exit 0 only when nothing failed.
if (-not $Repo) { $Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path }
$script:Pass = 0; $script:Fail = 0
function Check([bool]$cond, [string]$what) { if ($cond) { $script:Pass++; Write-Output ('PASS ' + $what) } else { $script:Fail++; Write-Output ('FAIL ' + $what) } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wireit-repro-recording-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$m = Import-Module (Join-Path $Repo 'Toolkit/modules/NvrHealth/NvrHealth.psm1') -Force -PassThru -DisableNameChecking

$rows = & $m {
  param($tmp)
  Set-NvrHealthOption LogDir (Join-Path $tmp 'logs')
  $cred = [pscredential]::new('admin', (ConvertTo-SecureString 'Review123' -AsPlainText -Force))
  $script:Case = ''; $script:Writes = 0; $script:TrackXml = ''
  function script:Dw-Login { return $true }
  function script:Http {
    param($Ip, $Method = 'GET', $Path, $Body, $ContentType, $Credential, $Headers, $Port, $Scheme, $NoLogBody, $Timeout, $BodyBytes, $OutFile)
    # one stateful recording track (camera 1): the list, the single track and a PUT all use the same XML
    if ($Method -eq 'PUT') { $script:Writes++; $script:TrackXml = [string]$Body; return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } }
    switch ($Path) {
      '/ISAPI/System/deviceInfo' { $b = '<DeviceInfo><model>DS-7608</model><serialNumber>REVIEW</serialNumber></DeviceInfo>' }
      '/ISAPI/System/time' { $b = '<Time><localTime>2026-11-10T10:00:00</localTime><timeZone>CST+5:00:00</timeZone></Time>' }
      '/ISAPI/ContentMgmt/InputProxy/channels' { $b = '<InputProxyChannelList><InputProxyChannel><id>1</id><ipAddress>10.0.0.41</ipAddress></InputProxyChannel></InputProxyChannelList>' }
      '/ISAPI/ContentMgmt/InputProxy/channels/status' { $b = '<InputProxyChannelStatusList><InputProxyChannelStatus><id>1</id><online>true</online></InputProxyChannelStatus></InputProxyChannelStatusList>' }
      '/ISAPI/ContentMgmt/record/tracks' { $b = '<TrackList>' + $script:TrackXml + '</TrackList>' }
      '/ISAPI/ContentMgmt/record/tracks/101' { $b = $script:TrackXml }
      '/ISAPI/ContentMgmt/Storage' { $b = '<storage><hdd><id>1</id><capacity>1000000</capacity><freeSpace>0</freeSpace><status>ok</status><property>RW</property></hdd></storage>'; if ($script:Case -eq 'growing-retention') { $b = $b.Replace('<freeSpace>0', '<freeSpace>500000') } }
      '/ISAPI/ContentMgmt/search' { $b = '<CMSearchResult><responseStatusStrg>OK</responseStatusStrg><searchMatchItem><startTime>2026-09-01T10:00:00Z</startTime><endTime>2026-11-10T09:59:00Z</endTime></searchMatchItem></CMSearchResult>'; if ($script:Case -eq 'growing-retention') { $b = $b.Replace('2026-09-01', '2026-11-05') } }
      default {
        if ($Path -like '/rest/v3/devices*') { $b = '[{"id":"c1","name":"Review camera","url":"http://10.0.0.41","status":"Recording","schedule":{}}]' }
        elseif ($Path -eq '/rest/v3/servers/this/storages/*/status') { $b = '[{"url":"media","totalSpace":1000000000,"freeSpace":0,"isOnline":true,"isUsedForWriting":true}]' }
        elseif ($Path -like '/ec2/recordedTimePeriods*') { $b = '[{"startTimeMs":1788228000000,"durationMs":-1}]' }
        else { return @{ code = 404; body = '' } }
      }
    }
    return @{ code = 200; body = $b }
  }
  $out = @()
  $sum = { $s = @(Get-NvrHealthSummary | Where-Object { $_ -match '^RESULT' }); if ($s.Count) { [string]$s[-1] } else { '' } }
  foreach ($case in @('on-empty-schedule', 'on-invalid-schedule', 'off-no-schedule', 'on-missing-enable', 'on-missing-schedule')) {
    $script:Case = $case; $script:Writes = 0
    $inner = switch ($case) {
      'on-empty-schedule' { '<Enable>true</Enable><TrackSchedule><ScheduleBlock><ScheduleAction><Actions><Record>false</Record></Actions></ScheduleAction></ScheduleBlock></TrackSchedule>' }
      'on-invalid-schedule' { '<Enable>true</Enable><TrackSchedule><Record>unknown</Record></TrackSchedule>' }
      'off-no-schedule' { '<Enable>false</Enable>' }
      'on-missing-enable' { '<TrackSchedule><Record>true</Record></TrackSchedule>' }
      default { '<Enable>true</Enable>' }
    }
    $script:TrackXml = '<Track><id>101</id>' + $inner + '</Track>'
    $pre = Get-RecordingStatus -Ip 10.0.0.20 -Vendor Hikvision -Credential $cred -TargetDays 30
    $preSched = $pre.channels[0].scheduled
    $r = Invoke-NvrFix -Fix recording -Ip 10.0.0.20 -Vendor Hikvision -Credential $cred -Confirm { 'YES' } -BackupDir (Join-Path $tmp 'backup')
    $fixW = $script:Writes
    $hc = Get-RecordingStatus -Ip 10.0.0.20 -Vendor Hikvision -Credential $cred -TargetDays 30
    $out += [pscustomobject]@{ case = $case; preScheduled = $preSched; preOk = [bool]$pre.ok; fixOk = [bool]$r.ok; writes = $fixW; msg = [string]$r.msg; ok = [bool]$hc.ok; scheduled = $hc.channels[0].scheduled; problems = (@($hc.problems) -join '; '); summary = (& $sum); recNow = [bool]$hc.channels[0].recording_now; pending = $null; days = $null }
  }
  $script:Case = 'dw-missing-enabled'
  $hc = Get-RecordingStatus -Ip 10.0.0.20 -Vendor DW -Credential $cred -TargetDays 30
  $out += [pscustomobject]@{ case = 'dw-missing-enabled'; preScheduled = $null; preOk = $null; fixOk = $null; writes = 0; msg = ''; ok = [bool]$hc.ok; scheduled = $hc.channels[0].scheduled; problems = (@($hc.problems) -join '; '); summary = (& $sum); recNow = [bool]$hc.channels[0].recording_now; pending = $null; days = $null }
  $script:Case = 'growing-retention'; $script:TrackXml = '<Track><id>101</id><Enable>true</Enable><TrackSchedule><Record>true</Record></TrackSchedule></Track>'
  $hc = Get-RecordingStatus -Ip 10.0.0.20 -Vendor Hikvision -Credential $cred -TargetDays 30
  $out += [pscustomobject]@{ case = 'growing-retention'; preScheduled = $null; preOk = $null; fixOk = $null; writes = 0; msg = ''; ok = [bool]$hc.ok; scheduled = $hc.channels[0].scheduled; problems = (@($hc.problems) -join '; '); summary = (& $sum); recNow = $true; pending = $(if ($hc.PSObject.Properties['target_pending']) { [bool]$hc.target_pending } else { $null }); days = $hc.days_held }
  return $out
} $tmp 6>$null
$rows = @($rows | Where-Object { $_ -and $_.PSObject.Properties['case'] })
foreach ($x in $rows) {
  Write-Output ('REPRO=' + (@{ case = $x.case; fixOk = $x.fixOk; writes = $x.writes; msg = $x.msg; ok = $x.ok; scheduled = $x.scheduled; problems = $x.problems; summary = $x.summary } | ConvertTo-Json -Compress))
  switch ($x.case) {
    'on-empty-schedule' {
      Check ($x.preScheduled -eq $false -and -not $x.preOk) 'R6 enabled track, schedule only Record=false: the read-only check says recording is OFF in its schedule'
      Check ($x.msg -notmatch '(?i)already on') ('R6 enabled track, schedule only Record=false: the fix does NOT say "already on" (' + $x.msg + ')')
      Check ($x.writes -ge 1 -and $x.fixOk) ('R6 the fix turns that schedule on (writes=' + $x.writes + ', ok=' + $x.fixOk + ')')
      Check ($x.scheduled -eq $true -and $x.ok) ('R6 after the fix, the read-only check sees the schedule on (the fix resolves its own check; scheduled=' + $x.scheduled + ')')
    }
    'on-invalid-schedule' {
      Check ($x.writes -eq 0 -and -not $x.fixOk -and $x.msg -match 'NOT CHECKED') ('R6 Record=unknown: the fix writes nothing and says NOT CHECKED (writes=' + $x.writes + ', ' + $x.msg + ')')
      Check ($null -eq $x.scheduled -and -not $x.ok -and $x.problems -match 'NOT CHECKED') ('R6 Record=unknown: the check says the schedule is NOT CHECKED, not green and not "off" (scheduled=' + $x.scheduled + '; ' + $x.problems + ')')
    }
    default {
      if ($x.case -in @('off-no-schedule', 'on-missing-enable', 'on-missing-schedule', 'dw-missing-enabled')) {
        if ($x.case -ne 'dw-missing-enabled') { Check (-not $x.fixOk -and $x.msg -match 'NOT CHECKED') ('R6 ' + $x.case + ': the fix does not end green (' + $x.msg + ')') }
        Check (-not $x.ok) ('R5 ' + $x.case + ': unknown schedule + fresh footage -> the check is NOT an all-clear (ok=' + $x.ok + ')')
        Check ($x.problems -match 'schedule NOT CHECKED') ('R5 ' + $x.case + ': the problem says the recording schedule is NOT CHECKED (' + $x.problems + ')')
        Check ($x.summary -notmatch 'target met' -and $x.summary -notmatch '^RESULT: all') ('R5 ' + $x.case + ': no all-clear RESULT line (' + $x.summary + ')')
        Check ($x.recNow) ('R5 ' + $x.case + ': the footage result is kept (camera shown recording now)')
      }
    }
  }
  if ($x.case -eq 'growing-retention') {
    Check ($x.summary -notmatch '(?i)target met') ('R9 5 days on a half-empty drive: no "target met" (' + $x.summary + ')')
    Check ($x.summary -match '(?i)still filling' -and $x.summary -match '(?i)not reached') ('R9 the RESULT says still filling, target not reached yet (' + $x.summary + ')')
    Check (-not $x.ok) ('R9 ok is not true while the target is not reached (ok=' + $x.ok + ')')
    Check (-not $x.problems -and $x.pending -eq $true) ('R9 still filling is not counted as a fault (problems="' + $x.problems + '", target_pending=' + $x.pending + ')')
  }
}
Check ($rows.Count -eq 7) ('all 7 cases ran (' + $rows.Count + ')')
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Output ('' + $script:Pass + ' passed, ' + $script:Fail + ' failed')
if ($script:Fail) { exit 1 } else { exit 0 }
