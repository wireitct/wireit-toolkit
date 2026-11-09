<# Test-Fix2212.ps1 - tests for WireIt Toolkit 2.2.12 (Nov 9 2026), the lead's part of the Codex NO-GO review of 2.2.11:
   P1-8  retention: every day of the claimed footage is checked (no gaps between sample days), or the report says "sampled"
   P1-10 camera restart: a refusal inside an HTTP 200 is a refusal; "restarted" needs the camera to go offline and come back
   P2-11 (F18) the scan waiting list is written atomically (the half-way write itself is Test-Fix227 F18, Linux)
   P2-15 the Node relay suite is part of tools\Run-AllTests.ps1 and counted (no node = DEFERRED, never a pass)
   Codex's reproductions (R9, reproduce-nvrfix.ps1) are rebuilt here as permanent checks. Moshe's rule: every change is tested for
   failing half-way, the wrong device and running twice. Fake devices only (no real device is touched). PS 5.1 or pwsh 7. #>
$ErrorActionPreference = 'Stop'
$tk = Split-Path -Parent $PSScriptRoot; $repo = Split-Path -Parent $tk
$exe = $(if ($PSVersionTable.PSEdition -eq 'Core') { (Get-Process -Id $PID).Path } else { Join-Path $PSHOME 'powershell.exe' })
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2212-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + ($more -replace "`n", "`n     ")) } }
}
function Get-FnText([string]$file, [string[]]$only = @()) {
  $ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
  $fns = @($ast.FindAll({ param($a) $a -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
  if ($only.Count) { $fns = @($fns | Where-Object { $only -contains $_.Name }) }
  return (($fns | ForEach-Object { $_.Extent.Text }) -join "`n")
}
$nhMod = Join-Path $tk 'modules\NvrHealth\NvrHealth.psm1'
foreach ($f in @($nhMod, (Join-Path $tk 'modules\NvrHealth\NvrFix.ps1'), (Join-Path $tk 'ScanUpload.ps1'), (Join-Path $repo 'tools\Run-AllTests.ps1'))) {
  $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$e); Check ($e.Count -eq 0) ('parses: ' + (Split-Path -Leaf $f)) ($e | Out-String)
}

try {
# ==============================================================================================================================
Write-Host 'P1-8 retention: every day back to the target is checked (Codex R9: a 5-day gap between sample days said "30 days")'
$nm = Import-Module $nhMod -Force -PassThru -DisableNameChecking
& $nm { param($ld) Set-NvrHealthOption LogDir $ld } (Join-Path $tmp 'nhlogs')
$run = {
  param($nm, [object[]]$spans, [int]$Target = 30, [int]$FailAfter = -1)
  & $nm {
    param($spans, $target, $failAfter)
    $script:FakeSpans = $spans; $script:FakeNow = [datetime]'2026-11-08T10:00:00'; $script:FakeSearches = 0; $script:FakeFailAfter = $failAfter
    function script:Http {
      param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '')
      $ok = { param($b) [pscustomobject]@{ code = 200; body = $b; err = '' } }
      switch -Wildcard ($Path) {
        '/ISAPI/System/deviceInfo' { return (& $ok '<DeviceInfo><model>DS-7608NI-K2</model><serialNumber>S1</serialNumber><firmwareVersion>V4.1</firmwareVersion></DeviceInfo>') }
        '/ISAPI/System/time' { return (& $ok ('<Time><timeMode>NTP</timeMode><localTime>' + $script:FakeNow.ToString('yyyy-MM-ddTHH:mm:ss') + '</localTime><timeZone>CST+5:00:00DST01:00:00,M3.2.0/02:00:00,M11.1.0/02:00:00</timeZone></Time>')) }
        '/ISAPI/ContentMgmt/InputProxy/channels' { return (& $ok '<InputProxyChannelList><InputProxyChannel><id>1</id><name>Door</name><ipAddress>10.0.0.64</ipAddress></InputProxyChannel></InputProxyChannelList>') }
        '/ISAPI/ContentMgmt/InputProxy/channels/status' { return (& $ok '<InputProxyChannelStatusList><InputProxyChannelStatus><id>1</id><online>true</online><chanDetectResult>connect</chanDetectResult></InputProxyChannelStatus></InputProxyChannelStatusList>') }
        '/ISAPI/ContentMgmt/record/tracks' { return (& $ok '<TrackList><Track><id>101</id><Enable>true</Enable></Track></TrackList>') }
        '/ISAPI/ContentMgmt/Storage' { return (& $ok '<storage><hddList><hdd><id>1</id><capacity>3815447</capacity><freeSpace>0</freeSpace><status>ok</status><property>RW</property></hdd></hddList></storage>') }
        '/ISAPI/ContentMgmt/search' {
          $script:FakeSearches++
          if ($script:FakeFailAfter -ge 0 -and $script:FakeSearches -gt $script:FakeFailAfter) { return [pscustomobject]@{ code = 500; body = ''; err = 'x' } }
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
    $r = Get-RecordingStatus -Ip '10.0.0.20' -Vendor Hikvision -Credential (New-Object PSCredential('admin', (ConvertTo-SecureString 'x1234567' -AsPlainText -Force))) -TargetDays $target -NoLog
    $r | Add-Member -NotePropertyName searches -NotePropertyValue $script:FakeSearches -Force
    $r
  } $spans $Target $FailAfter
}
$now = [datetime]'2026-11-08T10:00:00'
function Span($fromDaysAgo, $toDaysAgo) { return ,@($now.AddDays(-$fromDaysAgo).ToString('s'), $now.AddDays(-$toDaysAgo).ToString('s')) }
# Codex R9: footage for 32 days, NOTHING from 19 days ago through 15 days ago (the sample days 1,2,3,5,7,10,14,21,28 all answer)
$gap = @((Span 32 19.6), (Span 14.9 0.001))
$r = & $run $nm $gap 30
$dh = $(if ($r.channels) { @($r.channels)[0].days_held } else { $null })
Check (-not $r.ok) ('reproduction R9: a 5-day hole 15-19 days ago -> NOT "30-day target met" (2.2.11 said met; ok=' + $r.ok + ')')
Check ($null -ne $dh -and [int]$dh -le 16 -and [int]$dh -ge 13) ('...days held stops at the hole (got ' + $dh + ', want 13-16)')
# no hole: still met (no regression)
$r = & $run $nm @(,(Span 50 0.001)) 30
$c0 = @($r.channels)[0]
Check ($r.ok -and [int]$c0.days_held -ge 45) ('50 days with no hole -> target met (got ' + $c0.days_held + ', ok=' + $r.ok + ')')
Check (-not $c0.days_note) ('...every one of those days was checked, so no "sampled" note (note: ' + $c0.days_note + ')')
# (an empty stretch must be longer than 36 h to count as a hole: a motion camera can be quiet for a day, by design since 2.2.4)
# a recorder that answers with many clips (motion recording: 2 clips an hour) -> the 7-day blocks are full, checked day by day, a 1-day hole is found
$many = @(); for ($m = 40 * 48; $m -ge 1; $m--) { $s0 = $now.AddMinutes(-30 * $m); if ($s0 -lt $now.AddDays(-10.5) -or $s0 -ge $now.AddDays(-8)) { $many += ,@($s0.ToString('s'), $s0.AddMinutes(10).ToString('s')) } }
$r = & $run $nm $many 30
$dh = @($r.channels)[0].days_held
Check (-not $r.ok -and $null -ne $dh -and [int]$dh -le 9 -and [int]$dh -ge 6) ('motion clips (too many for one search) with 2.5 empty days (8 to 10.5 days ago) -> found, days held ' + $dh + ', not met')
# failing half-way: the 4th footage search fails -> days held UNKNOWN, never met
$r = & $run $nm @(,(Span 50 0.001)) 30 3
$dh = @($r.channels)[0].days_held
Check (-not $r.ok -and $null -eq $dh) ('a footage search that fails half-way -> days held unknown, not met (got ' + $dh + ', ok=' + $r.ok + ')')
# older than the day-by-day part (60 days): sampled only, and the report says so
$r = & $run $nm @(,(Span 200 0.001)) 30
$c0 = @($r.channels)[0]
Check ($r.ok -and [int]$c0.days_held -ge 180 -and ([string]$c0.days_note) -match 'sampled') ('200 days held: target met, and it says the days past 60 are only sampled (note: ' + $c0.days_note + ')')
# running twice gives the same answer
$a1 = @((& $run $nm $gap 30).channels)[0].days_held; $a2 = @((& $run $nm $gap 30).channels)[0].days_held
Check ($a1 -eq $a2) ('running twice: the same days held both times (' + $a1 + ' / ' + $a2 + ')')
# cost: a continuous recorder needs only a few searches (blocks of 7 days)
$r = & $run $nm @(,(Span 50 0.001)) 30
Check ([int]$r.searches -le 20) ('50 days continuous: ' + $r.searches + ' footage searches (one per 7-day block, not one per day)')
Remove-Module NvrHealth -Force -ErrorAction SilentlyContinue

# ==============================================================================================================================
Write-Host 'P1-10 camera restart: the camera''s own answer counts, and a restart must be SEEN (Codex reproduce-nvrfix.ps1)'
$nm = Import-Module $nhMod -Force -PassThru -DisableNameChecking
& $nm { param($ld) Set-NvrHealthOption LogDir $ld } (Join-Path $tmp 'nhlogs2')
$rs = {
  param($nm, [string]$vendor, [string]$answer, [int]$downPolls, [string]$state, [int]$wait = 2)
  & $nm {
    param($vendor, $answer, $downPolls, $state, $wait)
    $script:FkAnswer = $answer; $script:FkDown = -1; $script:FkDownPolls = $downPolls; $script:FkReboots = 0
    function script:Http {
      param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '')
      $r = { param($c, $b) [pscustomobject]@{ code = $c; body = $b; err = '' } }
      if ($Method -eq 'PUT' -and $Path -match '(?i)reboot') {
        $script:FkReboots++
        switch ($script:FkAnswer) {
          'hik-ok' { $script:FkDown = $script:FkDownPolls; return (& $r 200 '<?xml version="1.0" encoding="UTF-8"?><ResponseStatus><statusCode>1</statusCode><statusString>OK</statusString></ResponseStatus>') }
          'hik-refuse' { return (& $r 200 '<?xml version="1.0" encoding="UTF-8"?><ResponseStatus><requestURL>/ISAPI/System/reboot</requestURL><statusCode>4</statusCode><statusString>Invalid Operation</statusString></ResponseStatus>') }
          'unv-ok' { $script:FkDown = $script:FkDownPolls; return (& $r 200 '{"Response":{"ResponseURL":"/LAPI/V1.0/System/Reboot","ResponseCode":0,"ResponseString":"Succeed","Data":{}}}') }
          'unv-refuse' { return (& $r 200 '{"Response":{"ResponseURL":"/LAPI/V1.0/System/Reboot","ResponseCode":3,"ResponseString":"Not Authorized","Data":{}}}') }
          'http403' { return (& $r 403 '') }
        }
      }
      if ($script:FkDown -gt 0) { $script:FkDown--; return (& $r 0 '') }
      if ($Path -match 'DeviceInfo') { return (& $r 200 '{"Response":{"ResponseCode":0,"Data":{"DeviceModel":"IPC2124","SerialNumber":"U1"}}}') }
      if ($Path -match 'deviceInfo') { return (& $r 200 '<DeviceInfo><model>DS-2CD2143G2-I</model><serialNumber>S1</serialNumber><firmwareVersion>V5.7</firmwareVersion></DeviceInfo>') }
      return (& $r 404 '')
    }
    $script:LoginState = @{}
    $o = Invoke-NvrFix -Fix restart -Ip '10.9.0.21' -Vendor $vendor -Credential (New-Object PSCredential('admin', (ConvertTo-SecureString 'x1234567' -AsPlainText -Force))) -StateFile $state -Confirm { 'YES' } -WaitSec $wait
    $o | Add-Member -NotePropertyName reboots -NotePropertyValue $script:FkReboots -Force
    $o
  } $vendor $answer $downPolls $state $wait
}
$st = Join-Path $tmp 'limits-a.json'
$o = & $rs $nm 'Hikvision' 'hik-refuse' 0 $st
Check (-not $o.ok -and $o.msg -match 'refused' -and $o.history -notmatch 'restarted, back online') ('reproduction: Hik HTTP 200 <statusCode>4</statusCode> Invalid Operation -> refused, not "restarted" (ok=' + $o.ok + ', ' + $o.history + ')')
Check (-not (Test-Path $st) -or ((Get-Content $st -Raw) -notmatch '10\.9\.0\.21')) '...a refused restart does not use up the camera''s restart limit'
$o = & $rs $nm 'Uniview' 'unv-refuse' 0 $st
Check (-not $o.ok -and $o.msg -match 'refused') ('Uniview HTTP 200 ResponseCode 3 -> refused (' + $o.msg + ')')
$o = & $rs $nm 'Hikvision' 'http403' 0 $st
Check (-not $o.ok -and $o.msg -match 'refused') 'HTTP 403 -> refused (as before)'
# accepted but the camera never goes offline -> NOT confirmed (2.2.11 said "restarted, back online")
$o = & $rs $nm 'Hikvision' 'hik-ok' 0 (Join-Path $tmp 'limits-b.json')
Check (-not $o.ok -and $o.history -match 'NOT confirmed' -and $o.msg -match 'NOT confirmed') ('accepted, but it never went offline -> "NOT confirmed", not "restarted" (ok=' + $o.ok + ', ' + $o.history + ')')
Check ((Get-Content (Join-Path $tmp 'limits-b.json') -Raw) -match '10\.9\.0\.21') '...an accepted restart does use up the limit (it may still restart)'
# a real restart: offline for 2 checks, then back -> restarted
$o = & $rs $nm 'Hikvision' 'hik-ok' 2 (Join-Path $tmp 'limits-c.json') 4
Check ($o.ok -and $o.history -match 'restarted, back online') ('Hik: offline then back -> "restarted, back online" (ok=' + $o.ok + ', ' + $o.history + ')')
$o = & $rs $nm 'Uniview' 'unv-ok' 2 (Join-Path $tmp 'limits-d.json') 4
Check ($o.ok -and $o.history -match 'restarted, back online') ('Uniview: offline then back -> restarted (' + $o.history + ')')
# failing half-way: it goes offline and never comes back in the wait
$o = & $rs $nm 'Hikvision' 'hik-ok' 999 (Join-Path $tmp 'limits-e.json') 2
Check (-not $o.ok -and $o.history -match 'NOT back yet') ('offline and not back in time -> "NOT back yet", red (' + $o.history + ')')
# running twice: the second restart in the hour is refused before anything is sent
$o = & $rs $nm 'Hikvision' 'hik-ok' 2 (Join-Path $tmp 'limits-c.json') 4
Check (-not $o.ok -and $o.reboots -eq 0 -and $o.msg -match 'last hour') ('running twice: the 2nd restart in the hour is refused, nothing sent (' + $o.msg + ')')
# wrong device: a DW server / Onvif device is never restarted
$o = & $rs $nm 'Onvif' 'hik-ok' 0 (Join-Path $tmp 'limits-f.json')
Check (-not $o.ok -and $o.reboots -eq 0) 'wrong device type (Onvif): not restarted, nothing sent'
Remove-Module NvrHealth -Force -ErrorAction SilentlyContinue

# ==============================================================================================================================
Write-Host 'P2-11 (F18) the scan waiting list is written atomically'
$su = Get-Content -LiteralPath (Join-Path $tk 'ScanUpload.ps1') -Raw
Check ($su -match 'function Write-SuFileAtomic' -and $su -match 'Write-SuFileAtomic \(Pending-Path \$Site\)' -and $su -notmatch 'Set-Content -Path \(Pending-Path') 'ScanUpload writes the waiting list through the atomic writer (no Set-Content truncating the old list)'
. ([scriptblock]::Create((Get-FnText (Join-Path $tk 'ScanUpload.ps1') @('Write-SuFileAtomic'))))
$pf = Join-Path $tmp 'scan-WI-1.json'; Write-SuFileAtomic $pf '{"site":"WI-1","devices":[1,2,3]}'
Write-SuFileAtomic $pf '{"site":"WI-1","devices":[1,2,3,4]}'
Check (@((Get-Content $pf -Raw | ConvertFrom-Json).devices).Count -eq 4 -and @(Get-ChildItem $tmp -Filter '*.tmp').Count -eq 0) 'written twice: the newest list, no temp file left behind'
# a write that fails half-way (the text can not be encoded -> exception before the swap): the old list stays whole
$bad = 'x' + [char]0xD800
try { Write-SuFileAtomic $pf $bad; $threw = $false } catch { $threw = $true }
$still = $null; try { $still = Get-Content $pf -Raw | ConvertFrom-Json } catch {}
Check ($still -and @($still.devices).Count -eq 4 -and @(Get-ChildItem $tmp -Filter '*.tmp').Count -eq 0) ('a write that fails half-way leaves the old waiting list whole (threw=' + $threw + ')')

# ==============================================================================================================================
Write-Host 'P2-15 the relay (Node) suite is part of the full pack and is counted'
$rat = Join-Path $repo 'tools\Run-AllTests.ps1'
$ratText = Get-Content -LiteralPath $rat -Raw
Check ($ratText -match 'hikrelay\.test\.js' -and $ratText -match 'Get-NodeSuiteRow') 'Run-AllTests runs appsscript\tests\hikrelay.test.js'
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
try {
  $env:WIREIT_TEST_NODE = 'none'; $o1 = & $exe -NoProfile -ExecutionPolicy Bypass -File $rat -OnlyRelay 2>&1 | Out-String; $c1 = $LASTEXITCODE
  if ($nodeCmd) { $env:WIREIT_TEST_NODE = $nodeCmd.Source; $o2 = & $exe -NoProfile -ExecutionPolicy Bypass -File $rat -OnlyRelay 2>&1 | Out-String; $c2 = $LASTEXITCODE }
  # a broken relay: a copy of the repo's tools + a relay test that fails
  $fr = Join-Path $tmp 'fakerepo'; New-Item -ItemType Directory -Force -Path (Join-Path $fr 'tools'), (Join-Path $fr 'appsscript/tests') | Out-Null
  Copy-Item $rat (Join-Path $fr 'tools/Run-AllTests.ps1')
  'console.log("hikrelay: 1 ok"); console.error("AssertionError: relay broken"); process.exit(1);' | Set-Content (Join-Path $fr 'appsscript/tests/hikrelay.test.js')
  if ($nodeCmd) { $o3 = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fr 'tools/Run-AllTests.ps1') -OnlyRelay 2>&1 | Out-String; $c3 = $LASTEXITCODE }
  Remove-Item (Join-Path $fr 'appsscript/tests/hikrelay.test.js')
  $o4 = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fr 'tools/Run-AllTests.ps1') -OnlyRelay 2>&1 | Out-String; $c4 = $LASTEXITCODE
} finally { $ErrorActionPreference = $prev; Remove-Item Env:WIREIT_TEST_NODE -ErrorAction SilentlyContinue }
Check ($c1 -ne 0 -and $o1 -match 'DEFERRED' -and $o1 -notmatch 'ALL .*PASSED') ('no node on the PC -> the relay suite is DEFERRED, exit ' + $c1 + ', never "ALL PASSED"') $o1
if ($nodeCmd) {
  Check ($c2 -eq 0 -and $o2 -match 'hikrelay total: \d+ ok' -and $o2 -match 'ALL .*PASSED' -and $o2 -match 'Checks: [1-9]\d* passed') ('node present -> the relay suite runs and its checks are counted (exit ' + $c2 + ')') $o2
  Check ($c3 -ne 0 -and $o3 -match 'FAILED') ('a broken relay test -> the pack FAILS (exit ' + $c3 + ')') $o3
} else { Check $false 'node is needed on the test PC to run the relay suite (none found)' }
Check ($c4 -ne 0 -and $o4 -match 'relay suite missing') ('the relay test file missing -> FAIL, not silently skipped (exit ' + $c4 + ')') $o4
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ('Test-Fix2212: ' + $script:pass + ' passed, ' + $script:fail + ' failed')
exit $script:fail
