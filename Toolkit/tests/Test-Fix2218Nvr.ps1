<# Test-Fix2218Nvr.ps1 - tests for WireIt Toolkit 2.2.18 (Nov 10 2026), the NvrHealth module part of Codex's review of 2.2.17
   (head c3c0c69, NO-GO), findings 4, 6 and 7, plus the twins found in the module sweep:
   F4  firmware: an accepted update whose read-back has NO version is not "Updated" (2.2.17: ok, "Updated: V4.1 -> ").
   F6  recording check: a storage list that could not be read (HTTP 500 / an error answer, Hikvision and DW) is "storage NOT
       CHECKED", never "No hard drive found" / "no hard drive"; a real, empty storage list still says no hard drive.
   F7  Invoke-NvrFix under ErrorActionPreference=Continue with a backup folder that cannot be written: no backup, ZERO device
       writes, ok=false "backup could not be saved, nothing changed" (recording Hik + DW, re-add, restart, DW password).
   Twins: firmware with no current version is refused; a failed footage search / camera list is NOT CHECKED (not "NO footage" /
   "no channels"); an unreadable restart-limit file refuses the restart; a failed restart-limit save is reported; DW password
   "Offline" is not confirmed; no backup folder = a dated TEMP folder (2.2.17: no backup at all); a time-server list that could
   not be read is "time server NOT CHECKED", not "no time server" (and the time fix makes no plan from it).
   Every check RUNS the real module functions with stand-ins for the device's web answers. No real device is touched, so
   real-device behaviour is DEFERRED (never a pass). PS 5.1 or pwsh 7.
   FIX2218NVR_REPO (tests only) = run against another checkout (old-code proof: on 2.2.17 the finding checks FAIL). #>
$ErrorActionPreference = 'Stop'
$repo = $(if ($env:FIX2218NVR_REPO) { $env:FIX2218NVR_REPO } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) })
$tkDir = Join-Path $repo 'Toolkit'
$nhMod = Join-Path $tkDir 'modules/NvrHealth/NvrHealth.psm1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2218nvr-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + $more) } }
}
function Deferred([string]$name) { $script:deferred++; Write-Host ('DEFERRED ' + $name) }
foreach ($f in @($nhMod, (Join-Path $tkDir 'modules/NvrHealth/NvrFix.ps1'))) {
  $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$e); Check ($e.Count -eq 0) ('parses: ' + (Split-Path -Leaf $f)) ($e | Out-String)
}
# the "NOT CHECKED" words NvrCheck / FixSite read (ToolkitCore.ps1 $TkNotCheckedRx): read from the checkout, not copied
$notRx = 'login refused|login skipped|not checked|no answer|unreadable'
$coreF = Join-Path $tkDir 'ToolkitCore.ps1'
if (Test-Path -LiteralPath $coreF) { $mm = [regex]::Match((Get-Content -LiteralPath $coreF -Raw), "\`$TkNotCheckedRx\s*=\s*'([^']+)'"); if ($mm.Success) { $notRx = $mm.Groups[1].Value } }
$cred = New-Object PSCredential('admin', (ConvertTo-SecureString 'Review123' -AsPlainText -Force))
$newCred = New-Object PSCredential('admin', (ConvertTo-SecureString 'NewCam2026x' -AsPlainText -Force))
$script:n = 0
function InMod([scriptblock]$body, [object[]]$args2) {
  $script:n++
  $m = Import-Module $nhMod -Force -PassThru -DisableNameChecking
  try {
    & $m { param($ld) Set-NvrHealthOption LogDir $ld } (Join-Path $tmp ('logs' + $script:n))
    return (& $m $body @args2)
  } finally { Remove-Module $m -Force -ErrorAction SilentlyContinue }
}
# a backup folder that can NOT be created: a folder "under" a plain file (fails the same way on Windows and Linux)
$blocker = Join-Path $tmp 'not-a-folder'; Set-Content -LiteralPath $blocker -Value 'x'
$badDir = Join-Path $blocker 'backup'

try {
# ==============================================================================================================================
Write-Host 'F4 firmware: the acknowledged-write branch needs a NON-EMPTY read-back version that differs from the original'
$fwFile = Join-Path $tmp 'fw.dav'; [IO.File]::WriteAllBytes($fwFile, [byte[]](1..200))
$fwSha = (Get-FileHash -LiteralPath $fwFile -Algorithm SHA256).Hash
$fw = {
  param($cred, [string]$mode, [string]$dir, [string]$file, [string]$sha)
  $script:Mode = $mode; $script:Puts = 0; $script:Sent = $false
  function script:Http {
    param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '', [switch]$SecretTransport)
    if ($Path -eq '/ISAPI/System/configurationData' -and $OutFile) { [IO.File]::WriteAllBytes($OutFile, [byte[]](@(1..255) * 4)); return @{ code = 200; body = '' } }
    if ($Method -eq 'PUT' -and $Path -eq '/ISAPI/System/updateFirmware') { $script:Puts++; $script:Sent = $true; return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } }
    if ($Path -eq '/ISAPI/System/deviceInfo') {
      $before = $(if ($script:Mode -eq 'no-original') { '<DeviceInfo><model>DS-2CD2143</model><serialNumber>S1</serialNumber></DeviceInfo>' } else { '<DeviceInfo><model>DS-2CD2143</model><serialNumber>S1</serialNumber><firmwareVersion>V4.1</firmwareVersion></DeviceInfo>' })
      if (-not $script:Sent) { return @{ code = 200; body = $before } }
      switch ($script:Mode) {
        'empty' { return @{ code = 200; body = '<DeviceInfo><model>DS-2CD2143</model><serialNumber>S1</serialNumber></DeviceInfo>' } }
        'blank' { return @{ code = 200; body = '<DeviceInfo><model>DS-2CD2143</model><firmwareVersion> </firmwareVersion><firmwareReleasedDate></firmwareReleasedDate></DeviceInfo>' } }
        'readfail' { return @{ code = 500; body = '' } }
        'same' { return @{ code = 200; body = $before } }
        default { return @{ code = 200; body = '<DeviceInfo><model>DS-2CD2143</model><serialNumber>S1</serialNumber><firmwareVersion>V4.2</firmwareVersion></DeviceInfo>' } }
      }
    }
    return @{ code = 404; body = '' }
  }
  $r = Invoke-NvrFix -Fix firmware -Ip 10.0.0.30 -Vendor Hikvision -Credential $cred -File $file -Sha256 $sha -Confirm { 'YES' } -BackupDir (Join-Path $dir ('fw-' + $mode)) 6>$null
  return [pscustomobject]@{ ok = [bool]$r.ok; ran = [bool]$r.ran; puts = $script:Puts; changed = (@($r.changed) -join ', '); msg = [string]$r.msg; history = [string]$r.history }
}
$fwNotGreen = { param($r) (-not $r.ok -and $r.msg -notmatch '^Updated' -and $r.history -match 'NOT confirmed' -and $r.history -notmatch '->') }
$r = InMod $fw @($cred, 'empty', $tmp, $fwFile, $fwSha)
Check ($r.puts -eq 1 -and (& $fwNotGreen $r)) 'Codex F4: update accepted, DeviceInfo read back with NO firmware fields -> NOT ok, no "Updated", history NOT confirmed (2.2.17: ok, "Updated: V4.1 -> ")' ($r.msg + ' | ' + $r.history)
$r = InMod $fw @($cred, 'blank', $tmp, $fwFile, $fwSha)
Check (& $fwNotGreen $r) 'F4: read-back with a blank firmware version (spaces only) -> NOT confirmed (2.2.17: success)' ($r.msg + ' | ' + $r.history)
$r = InMod $fw @($cred, 'readfail', $tmp, $fwFile, $fwSha)
Check ((& $fwNotGreen $r) -and $r.history -match 'read-back failed') 'F4: read-back fails (HTTP 500) -> NOT ok and the history line says NOT confirmed (2.2.17: history "Firmware ... V4.1 -> ?")' ($r.msg + ' | ' + $r.history)
$r = InMod $fw @($cred, 'no-original', $tmp, $fwFile, $fwSha)
Check (-not $r.ok -and $r.puts -eq 0 -and -not $r.ran) 'F4 twin: the device does not say which firmware it has NOW -> refused before the update, zero firmware writes (2.2.17: sent, and any version read back = "Updated")' ('puts=' + $r.puts + ' ' + $r.msg)
$r = InMod $fw @($cred, 'good', $tmp, $fwFile, $fwSha)
Check ($r.ok -and $r.puts -eq 1 -and $r.msg -match '^Updated: V4\.1 -> V4\.2' -and $r.history -match 'V4\.1 -> V4\.2') 'control: a good update (V4.1 -> V4.2 read back) still confirms' ($r.msg + ' | ' + $r.history)
$r = InMod $fw @($cred, 'same', $tmp, $fwFile, $fwSha)
Check (-not $r.ok -and $r.msg -notmatch '^Updated') 'control: the same version read back -> NOT confirmed (as before)' $r.msg

# ==============================================================================================================================
Write-Host 'F6 recording check (Hikvision): a storage list that could not be read is NOT CHECKED, never "No hard drive found"'
$hikRec = {
  param($cred, [string]$mode, [int]$days)
  $script:Mode = $mode
  function script:Http {
    param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '', [switch]$SecretTransport)
    $m = $script:Mode
    if ($Path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = '<DeviceInfo><model>DS-7608NI</model><serialNumber>S1</serialNumber><firmwareVersion>V4.85</firmwareVersion></DeviceInfo>' } }
    if ($Path -eq '/ISAPI/ContentMgmt/InputProxy/channels') { if ($m -eq 'list500') { return @{ code = 500; body = '' } }; return @{ code = 200; body = '<InputProxyChannelList><InputProxyChannel><id>1</id><name>Door</name><sourceInputPortDescriptor><ipAddress>10.0.0.21</ipAddress></sourceInputPortDescriptor></InputProxyChannel></InputProxyChannelList>' } }
    if ($Path -eq '/ISAPI/ContentMgmt/InputProxy/channels/status') { if ($m -eq 'list500') { return @{ code = 500; body = '' } }; return @{ code = 200; body = '<InputProxyChannelStatusList><InputProxyChannelStatus><id>1</id><online>true</online></InputProxyChannelStatus></InputProxyChannelStatusList>' } }
    if ($Path -eq '/ISAPI/ContentMgmt/record/tracks') { if ($m -eq 'list500') { return @{ code = 500; body = '' } }; return @{ code = 200; body = '<TrackList><Track><id>101</id><Enable>true</Enable><TrackSchedule><Record>true</Record></TrackSchedule></Track></TrackList>' } }
    if ($Path -eq '/ISAPI/ContentMgmt/search') {
      if ($m -eq 'search500') { return @{ code = 500; body = '' } }
      if ($m -eq 'search-none') { return @{ code = 200; body = '<CMSearchResult><responseStatusStrg>NO MATCHES</responseStatusStrg><matchList></matchList></CMSearchResult>' } }
      $n0 = Get-Date
      $st = $n0.AddDays(-60).ToString('yyyy-MM-ddTHH:mm:ss') + 'Z'; $en = $n0.AddMinutes(-1).ToString('yyyy-MM-ddTHH:mm:ss') + 'Z'
      return @{ code = 200; body = ('<CMSearchResult><responseStatusStrg>OK</responseStatusStrg><matchList><searchMatchItem><timeSpan><startTime>' + $st + '</startTime><endTime>' + $en + '</endTime></timeSpan></searchMatchItem></matchList></CMSearchResult>') }
    }
    if ($Path -eq '/ISAPI/ContentMgmt/Storage') {
      switch ($m) {
        'storage500' { return @{ code = 500; body = '<html><body>Internal Server Error</body></html>' } }
        'storage-error' { return @{ code = 200; body = '<?xml version="1.0" encoding="UTF-8"?><ResponseStatus><statusCode>4</statusCode><statusString>Invalid Operation</statusString></ResponseStatus>' } }
        'storage-empty' { return @{ code = 200; body = '<?xml version="1.0" encoding="UTF-8"?><storage><hddList></hddList></storage>' } }
        default { return @{ code = 200; body = '<?xml version="1.0" encoding="UTF-8"?><storage><hddList><hdd><id>1</id><capacity>3815447</capacity><freeSpace>0</freeSpace><status>ok</status><property>RW</property></hdd></hddList></storage>' } }
      }
    }
    return @{ code = 404; body = '' }
  }
  $r = Get-RecordingStatus -Ip 10.0.0.20 -Vendor Hikvision -Credential $cred -TargetDays $days 6>$null
  $said = @(Get-NvrHealthSummary) -join "`n"
  return [pscustomobject]@{ ok = [bool]$r.ok; problems = @($r.problems); disks = @($r.disks).Count; said = $said; checked = $(if ($r.PSObject.Properties['storage_checked']) { $r.storage_checked } else { $null }) }
}
$noDiskClaim = { param($r) ($r.said -notmatch 'No hard drive found' -and -not @($r.problems | Where-Object { $_ -match '^no hard drive' }).Count) }
$r = InMod $hikRec @($cred, 'storage500', 30)
Check (& $noDiskClaim $r) 'Codex F6 (Hik): HTTP 500 on /ISAPI/ContentMgmt/Storage -> no "No hard drive found", no "no hard drive" problem (2.2.17: both)' ($r.said -split "`n" | Where-Object { $_ -match 'hard drive|storage' } | Out-String)
Check (-not $r.ok -and @($r.problems | Where-Object { $_ -match '^storage NOT CHECKED' }).Count -eq 1 -and $r.said -match 'hard drives are NOT CHECKED') 'Codex F6 (Hik): the report says storage NOT CHECKED and the result is not ok' (@($r.problems) -join '; ')
Check (-not @($r.problems | Where-Object { $_ -notmatch $notRx }).Count -and $r.said -notmatch 'drives healthy') 'F6 (Hik): with everything else fine, every problem is a NOT CHECKED one (NvrCheck exit 2 / summary NOT CHECKED, never OK, never PROBLEM "no hard drive")' (@($r.problems) -join '; ')
$r = InMod $hikRec @($cred, 'storage-error', 30)
Check ((& $noDiskClaim $r) -and @($r.problems | Where-Object { $_ -match '^storage NOT CHECKED' }).Count) 'F6 (Hik): a 200 answer that is an error (ResponseStatus), not a storage list -> storage NOT CHECKED, not "no hard drive" (2.2.17: no hard drive)' (@($r.problems) -join '; ')
$r = InMod $hikRec @($cred, 'storage500', 90)
Check ($r.said -notmatch 'Drives are full and overwriting' -and $r.said -match 'Could not read whether the drives are full') 'F6 twin (Hik): days held short of the target with storage unread -> "could not read whether the drives are full", never "Drives are full and overwriting" (2.2.17: full)' ($r.said -split "`n" | Where-Object { $_ -match 'DAYS HELD' } | Out-String)
$r = InMod $hikRec @($cred, 'storage-empty', 30)
Check (-not $r.ok -and $r.said -match 'No hard drive found' -and @($r.problems | Where-Object { $_ -eq 'no hard drive' }).Count -eq 1 -and -not @($r.problems | Where-Object { $_ -match 'storage NOT CHECKED' }).Count) 'control (Hik): a real, EMPTY storage list still says "No hard drive found" / no hard drive' (@($r.problems) -join '; ')
$r = InMod $hikRec @($cred, 'good', 30)
Check ($r.disks -eq 1 -and $r.said -notmatch 'No hard drive found' -and -not @($r.problems | Where-Object { $_ -match 'storage|hard drive' }).Count) 'control (Hik): a real storage list with one healthy drive -> no storage problem' (@($r.problems) -join '; ')
$r = InMod $hikRec @($cred, 'search500', 30)
Check ($r.said -notmatch 'NO footage found at all' -and @($r.problems | Where-Object { $_ -match '^footage NOT CHECKED' }).Count -and -not @($r.problems | Where-Object { $_ -match 'not recording' }).Count) 'F6 twin (Hik): every footage search fails (HTTP 500) -> footage NOT CHECKED, never "NO footage found at all" / "not recording" (2.2.17: no footage, not recording)' (@($r.problems) -join '; ')
$r = InMod $hikRec @($cred, 'search-none', 30)
Check ($r.said -match 'NO footage found at all' -and @($r.problems | Where-Object { $_ -match 'not recording' }).Count) 'control (Hik): searches that WORK and find nothing still say "NO footage found at all"' (@($r.problems) -join '; ')
$r = InMod $hikRec @($cred, 'list500', 30)
Check (-not @($r.problems | Where-Object { $_ -eq 'no channels' }).Count -and @($r.problems | Where-Object { $_ -match '^camera list NOT CHECKED' }).Count) 'F6 twin (Hik): channel lists and track list all HTTP 500 -> camera list NOT CHECKED, never "no channels" (2.2.17: no channels)' (@($r.problems) -join '; ')

# ==============================================================================================================================
Write-Host 'F6 recording check (DW): a storage answer that could not be read is NOT CHECKED, never "No hard drive found"'
$dwRec = {
  param($cred, [string]$mode)
  $script:Mode = $mode
  function script:Dw-Login { return $true }
  function script:Http {
    param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '', [switch]$SecretTransport)
    $m = $script:Mode
    if ($Path -like '/rest/v3/devices*') { if ($m -eq 'dev500') { return @{ code = 500; body = '' } }; if ($m -eq 'dev-empty') { return @{ code = 200; body = '[]' } }; return @{ code = 200; body = '[{"id":"c1","name":"Lobby","url":"http://10.0.0.41","status":"Online","schedule":{"isEnabled":true}}]' } }
    if ($Path -like '/ec2/recordedTimePeriods*') {
      if ($m -eq 'periods500') { return @{ code = 500; body = '' } }
      if ($m -eq 'periods-none') { return @{ code = 200; body = '{"reply":[]}' } }
      $ms = [long](([DateTime]::UtcNow.AddDays(-60)) - (New-Object DateTime(1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)))).TotalMilliseconds
      return @{ code = 200; body = ('{"reply":[{"startTimeMs":"' + $ms + '","durationMs":"-1"}]}') }
    }
    if ($Path -eq '/rest/v3/servers/this/storages/*/status') {
      switch ($m) { 'storage500' { return @{ code = 500; body = '' } } 'storage-empty' { return @{ code = 200; body = '[]' } } 'storage-garbage' { return @{ code = 200; body = '<html>login</html>' } }
        default { return @{ code = 200; body = '[{"url":"D:\\Media\\","totalSpace":8001563222016,"freeSpace":40007816110,"isOnline":true,"isUsedForWriting":true,"isBackup":false}]' } } }
    }
    if ($Path -eq '/api/storageSpace') { return @{ code = $(if ($m -eq 'storage-garbage') { 200 } else { 500 }); body = $(if ($m -eq 'storage-garbage') { 'not json' } else { '' }) } }
    return @{ code = 404; body = '' }
  }
  $r = Get-RecordingStatus -Ip 10.0.0.60 -Vendor DW -Credential $cred -TargetDays 30 6>$null
  $said = @(Get-NvrHealthSummary) -join "`n"
  return [pscustomobject]@{ ok = [bool]$r.ok; problems = @($r.problems); disks = @($r.disks).Count; said = $said }
}
$r = InMod $dwRec @($cred, 'storage500')
Check ((& $noDiskClaim $r) -and @($r.problems | Where-Object { $_ -match '^storage NOT CHECKED' }).Count -and -not $r.ok) 'Codex F6 (DW): both DW storage answers fail (HTTP 500) -> storage NOT CHECKED, no "No hard drive found" (2.2.17: no hard drive)' (@($r.problems) -join '; ')
Check (-not @($r.problems | Where-Object { $_ -notmatch $notRx }).Count) 'F6 (DW): with everything else fine, every problem is a NOT CHECKED one' (@($r.problems) -join '; ')
$r = InMod $dwRec @($cred, 'storage-garbage')
Check ((& $noDiskClaim $r) -and @($r.problems | Where-Object { $_ -match '^storage NOT CHECKED' }).Count) 'F6 (DW): storage answers that are not JSON (a login page) -> storage NOT CHECKED, not "no hard drive" (2.2.17: no hard drive)' (@($r.problems) -join '; ')
$r = InMod $dwRec @($cred, 'storage-empty')
Check ($r.said -match 'No hard drive found' -and @($r.problems | Where-Object { $_ -eq 'no hard drive' }).Count -eq 1) 'control (DW): a real, EMPTY storage list ("[]") still says "No hard drive found"' (@($r.problems) -join '; ')
$r = InMod $dwRec @($cred, 'good')
Check ($r.disks -eq 1 -and -not @($r.problems | Where-Object { $_ -match 'storage|hard drive' }).Count) 'control (DW): a real storage list with one drive -> no storage problem' (@($r.problems) -join '; ')
$r = InMod $dwRec @($cred, 'periods500')
Check ($r.said -notmatch 'NO footage found at all' -and @($r.problems | Where-Object { $_ -match '^footage NOT CHECKED' }).Count -and -not @($r.problems | Where-Object { $_ -match 'not recording' }).Count) 'F6 twin (DW): the footage list read fails (HTTP 500) -> footage NOT CHECKED, never "NO footage found at all" (2.2.17: no footage)' (@($r.problems) -join '; ')
$r = InMod $dwRec @($cred, 'periods-none')
Check ($r.said -match 'NO footage found at all') 'control (DW): a footage list that WORKS and is empty still says "NO footage found at all"' (@($r.problems) -join '; ')
$r = InMod $dwRec @($cred, 'dev500')
Check (-not @($r.problems | Where-Object { $_ -eq 'no channels' }).Count -and @($r.problems | Where-Object { $_ -match '^camera list NOT CHECKED' }).Count) 'F6 twin (DW): DW''s camera list read fails (HTTP 500) -> camera list NOT CHECKED, never "no channels" (2.2.17: no channels)' (@($r.problems) -join '; ')
$r = InMod $dwRec @($cred, 'dev-empty')
Check (@($r.problems | Where-Object { $_ -eq 'no channels' }).Count -eq 1) 'control (DW): a real, empty camera list ("[]") still says no channels' (@($r.problems) -join '; ')

# ==============================================================================================================================
Write-Host 'F7 Fix-Save: under ErrorActionPreference=Continue a backup that cannot be saved stops the repair before ANY device write'
$fix = {
  param($cred, $newCred, [string]$fixName, [string]$backupDir, [string]$state, [string]$mode)
  $ErrorActionPreference = 'Continue'; $global:ErrorActionPreference = 'Continue'
  $script:Mode = $mode; $script:Writes = 0; $script:Put1 = $false
  function script:Dw-Login { return $true }
  function script:Dw-Send { param($t, $method, $path, $obj, [switch]$Secret) $script:Writes++; $script:Put1 = $true; return @{ code = 200; body = '{}' } }
  function script:Hik-UpTime { param($t, [int]$timeout = 5) if ($script:Put1) { return @{ code = 200; up = 5 } }; return @{ code = 200; up = 100000 } }
  function script:Http {
    param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '', [switch]$SecretTransport)
    if ($Method -in @('PUT', 'POST', 'PATCH', 'DELETE')) { $script:Writes++; $script:Put1 = $true; return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } }
    if ($Path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = '<DeviceInfo><model>DS-2CD2143</model><serialNumber>S1</serialNumber><firmwareVersion>V5.7</firmwareVersion></DeviceInfo>' } }
    $on = '<Enable>true</Enable><TrackSchedule><Record>true</Record></TrackSchedule>'
    $one = '<Track><id>101</id>' + $(if ($script:Put1) { $on } else { '<Enable>false</Enable><TrackSchedule><Record>true</Record></TrackSchedule>' }) + '</Track>'
    if ($Path -eq '/ISAPI/ContentMgmt/record/tracks') { return @{ code = 200; body = ('<TrackList>' + $one + '</TrackList>') } }
    if ($Path -eq '/ISAPI/ContentMgmt/record/tracks/101') { return @{ code = 200; body = $one } }
    if ($Path -eq '/ISAPI/ContentMgmt/InputProxy/channels') {
      $c3 = $(if ($script:Put1) { '<InputProxyChannel><id>3</id><sourceInputPortDescriptor><ipAddress>10.0.0.33</ipAddress></sourceInputPortDescriptor></InputProxyChannel>' } else { '' })
      return @{ code = 200; body = ('<InputProxyChannelList><InputProxyChannel><id>1</id><sourceInputPortDescriptor><ipAddress>10.0.0.31</ipAddress></sourceInputPortDescriptor></InputProxyChannel>' + $c3 + '</InputProxyChannelList>') } }
    if ($Path -eq '/ISAPI/ContentMgmt/InputProxy/channels/status') { return @{ code = 200; body = '<InputProxyChannelStatusList><InputProxyChannelStatus><id>1</id><online>true</online></InputProxyChannelStatus><InputProxyChannelStatus><id>3</id><online>true</online></InputProxyChannelStatus></InputProxyChannelStatusList>' } }
    if ($Path -like '/rest/v3/devices*') {
      $st = $(if ($script:Mode -eq 'offline' -and $script:Put1) { 'Offline' } elseif ($script:Put1) { 'Online' } else { 'Unauthorized' })
      return @{ code = 200; body = ('[{"id":"c1","name":"One","url":"http://10.0.0.41","status":"' + $st + '","schedule":{"isEnabled":' + $(if ($script:Put1) { 'true' } else { 'false' }) + '}}]') } }
    return @{ code = 404; body = '' }
  }
  $p = @{ Fix = $fixName; Ip = '10.0.0.20'; Credential = $cred; Confirm = { 'YES' }; WaitSec = 1 }
  if ($backupDir -ne '-none-') { $p.BackupDir = $backupDir }
  if ($state) { $p.StateFile = $state }
  switch ($fixName) {
    'recording' { $p.Vendor = $(if ($mode -eq 'dw') { 'DW' } else { 'Hikvision' }) }
    'readd' { $p.Vendor = 'Hikvision'; $p.Channel = 3; $p.CameraIp = '10.0.0.33'; $p.NewCredential = $newCred }
    'restart' { $p.Vendor = 'Hikvision' }
    'dwpassword' { $p.Vendor = 'DW'; $p.CameraIp = '10.0.0.41'; $p.NewCredential = $newCred }
  }
  $r = Invoke-NvrFix @p 6>$null 2>$null
  $global:ErrorActionPreference = 'Stop'
  $bk = [string]$r.backup
  $bkOk = [bool]($bk -and (Test-Path -LiteralPath $bk -PathType Leaf) -and (Get-Item -LiteralPath $bk).Length -gt 0)
  return [pscustomobject]@{ ok = [bool]$r.ok; ran = [bool]$r.ran; writes = $script:Writes; msg = [string]$r.msg; history = [string]$r.history; backup = $bk; backupOk = $bkOk }
}
$refused = { param($r) ($r.writes -eq 0 -and -not $r.ok -and -not $r.ran -and -not $r.backupOk -and $r.msg -match 'backup .* could not be saved' -and $r.msg -match 'nothing was changed') }
$r = InMod $fix @($cred, $newCred, 'recording', $badDir, '', 'hik')
Check (& $refused $r) 'Codex F7 (recording, Hik): unwritable backup folder under Continue -> backup missing, ZERO device writes, ok=false "backup could not be saved, nothing was changed" (2.2.17: 1 PUT, ok=true)' ('writes=' + $r.writes + ' ok=' + $r.ok + ' backup=' + $r.backup + ' | ' + $r.msg)
$r = InMod $fix @($cred, $newCred, 'recording', $badDir, '', 'dw')
Check (& $refused $r) 'F7 (recording, DW): unwritable backup folder -> zero DW writes, ok=false (2.2.17: PATCH sent)' ('writes=' + $r.writes + ' | ' + $r.msg)
$r = InMod $fix @($cred, $newCred, 'readd', $badDir, '', 'hik')
Check (& $refused $r) 'F7 (re-add camera): unwritable backup folder -> zero NVR writes, ok=false (2.2.17: channel PUT sent)' ('writes=' + $r.writes + ' | ' + $r.msg)
$r = InMod $fix @($cred, $newCred, 'restart', $badDir, '', 'hik')
Check (& $refused $r) 'F7 (restart): unwritable backup folder -> no reboot sent, ok=false (2.2.17: reboot sent)' ('writes=' + $r.writes + ' | ' + $r.msg)
$r = InMod $fix @($cred, $newCred, 'dwpassword', $badDir, '', 'dw')
Check (& $refused $r) 'F7 (DW camera password): unwritable backup folder -> zero DW writes, ok=false (2.2.17: PATCH sent)' ('writes=' + $r.writes + ' | ' + $r.msg)
$good = Join-Path $tmp 'good-backup'
$r = InMod $fix @($cred, $newCred, 'recording', $good, '', 'hik')
Check ($r.ok -and $r.writes -eq 1 -and $r.backupOk -and (Get-Content -LiteralPath $r.backup -Raw) -match '<Track>') 'control (F7): a writable backup folder -> backup saved (exists, non-empty, the track list), then the one write, ok' ('writes=' + $r.writes + ' backup=' + $r.backup + ' | ' + $r.msg)
$r = InMod $fix @($cred, $newCred, 'recording', '-none-', '', 'hik')
Check ($r.writes -eq 1 -and $r.backupOk -and $r.backup -match 'WireIt-backup') 'F7 twin: no backup folder given -> the backup still goes to a dated TEMP\WireIt-backup folder before the write (2.2.17: no backup at all, write anyway)' ('backup=' + $r.backup)
if ($r.backup -and (Test-Path -LiteralPath $r.backup)) { Remove-Item -LiteralPath (Split-Path -Parent $r.backup) -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host 'Module sweep twins: restart limit, DW password'
$badState = Join-Path $tmp 'fix-limits-bad.json'; Set-Content -LiteralPath $badState -Value '{ this is not json'
$r = InMod $fix @($cred, $newCred, 'restart', (Join-Path $tmp 'bk-limit'), $badState, 'hik')
Check ($r.writes -eq 0 -and -not $r.ok -and $r.msg -match 'restart record') 'twin (class C): a restart-limit file that cannot be read -> restart refused, zero writes (2.2.17: read as "no restarts yet", reboot sent)' ('writes=' + $r.writes + ' | ' + $r.msg)
$la = $null; try { $la = InMod { param($p) Fix-LimitAdd $p '10.0.0.20' (Get-Date) } @((Join-Path $blocker 'fix-limits.json')) } catch { $la = 'it stopped with an error: ' + $_.Exception.Message }
Check ($la -is [bool] -and $la -eq $false) 'twin (class D): the restart limit cannot be saved -> Fix-LimitAdd says so ($false), it is not silently lost (2.2.17: nothing)' ('got ' + $la)
$okState = Join-Path $tmp 'fix-limits-ok.json'
$la = InMod { param($p) [void](Fix-LimitAdd $p '10.0.0.20' (Get-Date)); $b = Fix-LimitOk $p '10.0.0.20' (Get-Date); return @{ second = [bool]$b.ok } } @($okState)
Check ($la.second -eq $false) 'control: a saved restart is read back and blocks a 2nd restart within the hour' ('second restart allowed: ' + $la.second)
$r = InMod $fix @($cred, $newCred, 'dwpassword', (Join-Path $tmp 'bk-dw'), '', 'offline')
Check ($r.writes -eq 1 -and -not $r.ok -and $r.history -match 'NOT confirmed') 'twin (class B): DW takes the camera password but then says Offline -> NOT confirmed (2.2.17: ok, "DW now says Offline")' ($r.msg + ' | ' + $r.history)
$r = InMod $fix @($cred, $newCred, 'dwpassword', (Join-Path $tmp 'bk-dw2'), '', 'dw')
Check ($r.writes -eq 1 -and $r.ok -and $r.msg -match 'DW now says Online') 'control: DW password taken and DW says Online -> confirmed' ($r.msg + ' | ' + $r.history)

Write-Host 'Module sweep twin: clock check / time fix with a time-server list that could not be read'
$clk = {
  param($cred, [string]$mode)
  $script:Mode = $mode; $script:Writes = 0
  Set-NvrHealthOption MockUrl 'http://127.0.0.1:9'
  function script:Http {
    param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '', [switch]$SecretTransport)
    if ($Method -ne 'GET') { $script:Writes++; return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } }
    if ($Path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = '<DeviceInfo><model>DS-7608NI</model><serialNumber>S1</serialNumber><firmwareVersion>V4.85</firmwareVersion></DeviceInfo>' } }
    if ($Path -eq '/ISAPI/System/time') { return @{ code = 200; body = ('<Time><timeMode>NTP</timeMode><localTime>' + (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') + '</localTime><timeZone>EST5EDT,M3.2.0/02:00:00,M11.1.0/02:00:00</timeZone></Time>') } }
    if ($Path -eq '/ISAPI/System/time/ntpServers') {
      if ($script:Mode -eq 'ntp500') { return @{ code = 500; body = '' } }
      if ($script:Mode -eq 'ntp-empty') { return @{ code = 200; body = '<NTPServerList></NTPServerList>' } }
      return @{ code = 200; body = '<NTPServerList><NTPServer><id>1</id><addressingFormatType>hostname</addressingFormatType><hostName>time.nist.gov</hostName><portNo>123</portNo><synchronizeInterval>60</synchronizeInterval></NTPServer></NTPServerList>' }
    }
    return @{ code = 404; body = '' }
  }
  $r = Get-ClockStatus -Ip 10.0.0.20 -Vendor Hikvision -Credential $cred 6>$null
  $plan = Set-NtpTime -Ip 10.0.0.20 -Vendor Hikvision -Credential $cred -WhatIf 6>$null
  $said = @(Get-NvrHealthSummary) -join "`n"
  return [pscustomobject]@{ problems = @($r.problems); said = $said; planRows = @($plan.devices | ForEach-Object { [string]$_.result }); writes = $script:Writes }
}
$r = InMod $clk @($cred, 'ntp500')
Check (-not @($r.problems | Where-Object { $_ -eq 'no NTP server' }).Count -and @($r.problems | Where-Object { $_ -match 'time server not checked' }).Count -and $r.said -notmatch 'no time server is filled in') 'twin (class C): time-server list read fails (HTTP 500) -> time server NOT CHECKED, never "no time server is filled in" (2.2.17: no NTP server)' (@($r.problems) -join '; ')
Check ($r.writes -eq 0 -and @($r.planRows | Where-Object { $_ -match '^failed: could not read its time-server list' }).Count -and $r.said -notmatch 'was none') 'twin (class C): the time fix plan with an unreadable time-server list -> no plan ("could not read"), not "time server -> ... (was none)" (2.2.17: planned from "none")' (@($r.planRows) -join '; ')
$r = InMod $clk @($cred, 'ntp-empty')
Check (@($r.problems | Where-Object { $_ -eq 'no NTP server' }).Count -eq 1 -and @($r.planRows | Where-Object { $_ -eq 'what-if (not changed)' }).Count) 'control: a time-server list that WAS read and is empty still says "no NTP server" (and the what-if plan offers the fix)' ((@($r.problems) -join '; ') + ' | ' + (@($r.planRows) -join '; '))
$r = InMod $clk @($cred, 'good')
Check (-not @($r.problems | Where-Object { $_ -match 'NTP|time server' }).Count) 'control: a time-server list with time.nist.gov -> no time-server problem' (@($r.problems) -join '; ')

Deferred 'a real Hikvision camera / NVR / DW server (firmware read-back, storage API errors, backup folder on a real Windows PC): stand-ins only - NEEDS A REAL-DEVICE CHECK'
} catch { $script:fail++; Write-Host ('FAIL unexpected error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.ScriptLineNumber) }
finally { $global:ErrorActionPreference = 'Stop'; Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
Write-Host ''
Write-Host ('Test-Fix2218Nvr: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:deferred + ' deferred')
if ($script:fail) { exit 1 }
exit 0
