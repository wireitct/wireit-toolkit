<# Test-Fix2217Nvr.ps1 - tests for WireIt Toolkit 2.2.17 (Nov 10 2026), the recording fix (NvrFix "recording") part of Codex's
   re-review of 2.2.16 (head c9f9fb2): "both recording-fix implementations return success when read-back reveals a newly listed camera
   whose recording is off". A camera that is NOT in the first list but shows up in the list read back after the change, with its
   recording OFF (or unknown), must keep the result NOT confirmed, be named, and never get "Recording is ON again" or a
   "Recording turned back on" history line. Hikvision (track list) and DW (camera list) each.
   Every check RUNS the real Invoke-NvrFix with stand-ins for the recorder's web answers. No real device is touched, so real-device
   behaviour is DEFERRED (never a pass). PS 5.1 or pwsh 7.
   FIX2217NVR_REPO (tests only) = run against another checkout (old-code proof: on 2.2.16 the new-camera checks FAIL). #>
$ErrorActionPreference = 'Stop'
$repo = $(if ($env:FIX2217NVR_REPO) { $env:FIX2217NVR_REPO } else { Split-Path -Parent (Split-Path -Parent $PSScriptRoot) })
$tkDir = Join-Path $repo 'Toolkit'
$nhMod = Join-Path $tkDir 'modules/NvrHealth/NvrHealth.psm1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fix2217nvr-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:pass = 0; $script:fail = 0; $script:deferred = 0
function Check([bool]$ok, [string]$name, [string]$more = '') {
  if ($ok) { $script:pass++; Write-Host ('PASS ' + $name) } else { $script:fail++; Write-Host ('FAIL ' + $name); if ($more) { Write-Host ('     ' + $more) } }
}
function Deferred([string]$name) { $script:deferred++; Write-Host ('DEFERRED ' + $name) }
foreach ($f in @($nhMod, (Join-Path $tkDir 'modules/NvrHealth/NvrFix.ps1'))) {
  $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$e); Check ($e.Count -eq 0) ('parses: ' + (Split-Path -Leaf $f)) ($e | Out-String)
}
$cred = New-Object PSCredential('admin', (ConvertTo-SecureString 'Review123' -AsPlainText -Force))
$script:n = 0
function InMod([scriptblock]$body, [object[]]$args2) {
  $script:n++
  $m = Import-Module $nhMod -Force -PassThru -DisableNameChecking
  try {
    & $m { param($ld) Set-NvrHealthOption LogDir $ld } (Join-Path $tmp ('logs' + $script:n))
    return (& $m $body @args2)
  } finally { Remove-Module $m -Force -ErrorAction SilentlyContinue }
}
$notGreen = { param($r) (-not $r.ok -and $r.msg -notmatch '^Recording is ON again' -and $r.history -notmatch '^Recording turned back on:' -and $r.history -match 'NOT confirmed') }

try {
# ==============================================================================================================================
Write-Host 'Hikvision: a camera that is NEW in the read-back with recording OFF keeps the result NOT confirmed'
# Before the change: camera 1 (track 101) switched off, camera 2 (track 201) on. After the change camera 1 is on and the read-back
# ALSO lists camera 3 (track 301), which was not in the first list: off / off-in-schedule / unknown / on (control) by mode.
$hik = {
  param($cred, [string]$mode, [string]$dir, [int]$runs = 1)
  $script:Mode = $mode; $script:Writes = 0; $script:Put1 = $false; $script:Writes301 = 0
  function script:Http {
    param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '')
    if ($Path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = '<DeviceInfo><model>DS-7608NI-K2</model><serialNumber>TESTDEV0001</serialNumber><macAddress>AA:BB:CC:00:00:01</macAddress><firmwareVersion>V4.1</firmwareVersion><firmwareReleasedDate>build 240101</firmwareReleasedDate></DeviceInfo>' } }   # 2.2.19: the device says who it is (NvrFix re-identifies it before every write)
    if ($Method -eq 'PUT') { $script:Writes++; if ($Path -match '/301$') { $script:Writes301++ }; $script:Put1 = $true; return @{ code = 200; body = '<ResponseStatus><statusCode>1</statusCode></ResponseStatus>' } }
    $on = '<Enable>true</Enable><TrackSchedule><Record>true</Record></TrackSchedule>'
    $one = '<Track><id>101</id>' + $(if ($script:Put1) { $on } else { '<Enable>false</Enable><TrackSchedule><Record>true</Record></TrackSchedule>' }) + '</Track>'
    $two = '<Track><id>201</id>' + $on + '</Track>'
    $three = switch ($script:Mode) {
      'new-off' { '<Track><id>301</id><Enable>false</Enable><TrackSchedule><Record>true</Record></TrackSchedule></Track>' }
      'new-off-schedule' { '<Track><id>301</id><Enable>true</Enable><TrackSchedule><Record>false</Record></TrackSchedule></Track>' }
      'new-unknown' { '<Track><id>301</id><Enable>true</Enable></Track>' }
      'new-on' { '<Track><id>301</id>' + $on + '</Track>' }
      default { '' }
    }
    if ($Path -eq '/ISAPI/ContentMgmt/record/tracks') {
      if (-not $script:Put1) { return @{ code = 200; body = ('<TrackList>' + $one + $two + '</TrackList>') } }
      return @{ code = 200; body = ('<TrackList>' + $one + $two + $three + '</TrackList>') }
    }
    if ($Path -eq '/ISAPI/ContentMgmt/record/tracks/101') { return @{ code = 200; body = $one } }
    return @{ code = 404; body = '' }
  }
  $out = @()
  for ($i = 0; $i -lt $runs; $i++) {
    $w0 = $script:Writes
    $r = Invoke-NvrFix -Fix recording -Ip 10.0.0.20 -Vendor Hikvision -Credential $cred -Confirm { 'YES' } -BackupDir (Join-Path $dir ('hik-' + $mode + '-' + $i)) 6>$null
    $out += [pscustomobject]@{ ok = [bool]$r.ok; ran = [bool]$r.ran; writes = ($script:Writes - $w0); w301 = $script:Writes301; changed = (@($r.changed) -join ', '); msg = [string]$r.msg; history = [string]$r.history }
  }
  return $out
}
$r = @(InMod $hik @($cred, 'new-off', $tmp))[0]
Check ($r.writes -eq 1 -and $r.changed -eq 'camera 1' -and $r.w301 -eq 0) 'Codex 2.2.16 (Hik): camera 1 (switched off) is turned on with one write; the new camera 3 is not written' ('writes=' + $r.writes + ' changed=' + $r.changed + ' w301=' + $r.w301)
Check (& $notGreen $r) 'Codex 2.2.16 (Hik): camera 3 NEW in the read-back with recording switched OFF -> NOT ok, no "Recording is ON again", history NOT confirmed (2.2.16: success)' ($r.msg + ' | ' + $r.history)
Check ($r.msg -match 'Camera\(s\) 3 are NEW in the answer read back' -and $r.msg -match 'recording is OFF') 'Codex 2.2.16 (Hik): the result names camera 3 as new with recording OFF' $r.msg
$r = @(InMod $hik @($cred, 'new-off-schedule', $tmp))[0]
Check ((& $notGreen $r) -and $r.msg -match 'Camera\(s\) 3 are NEW') 'Hik: camera 3 NEW in the read-back, Enable on but its schedule has no recording time (= off) -> NOT confirmed, named (2.2.16: success)' ($r.msg + ' | ' + $r.history)
$r = @(InMod $hik @($cred, 'new-unknown', $tmp))[0]
Check ((& $notGreen $r) -and $r.msg -match 'camera\(s\) 3') 'Hik: camera 3 NEW in the read-back with recording unknown -> NOT confirmed, named (unchanged from 2.2.16)' ($r.msg + ' | ' + $r.history)
$rr = @(InMod $hik @($cred, 'new-on', $tmp))
Check ($rr[0].ok -and $rr[0].msg -match '^Recording is ON again for: camera 1\.' -and $rr[0].history -match '^Recording turned back on: camera 1') 'control (Hik): a camera NEW in the read-back with recording ON does not block "Recording is ON again"' ($rr[0].msg + ' | ' + $rr[0].history)
$rr = @(InMod $hik @($cred, 'none', $tmp))
Check ($rr[0].ok -and $rr[0].msg -match '^Recording is ON again for: camera 1\.') 'control (Hik): same list before and after, all on -> "Recording is ON again"' $rr[0].msg

# ==============================================================================================================================
Write-Host 'DW: a camera that is NEW in the read-back with recording OFF keeps the result NOT confirmed'
$dw = {
  param($cred, [string]$mode, [string]$dir, [int]$runs = 1)
  $script:Mode = $mode; $script:Writes = 0; $script:Put1 = $false; $script:WritesC3 = 0
  function script:Dw-Login { return $true }
  function script:Dw-Send { param($t, $method, $path, $obj, [switch]$Secret) $script:Writes++; if ($path -match 'c3') { $script:WritesC3++ }; $script:Put1 = $true; return @{ code = 200; body = '{}' } }
  function script:Http {
    param([string]$Ip, [string]$Method = 'GET', [string]$Path, [string]$Body = '', [string]$ContentType = '', $Credential = $null, [hashtable]$Headers = $null, [int]$Port = 0, [string]$Scheme = '', [switch]$NoLogBody, [int]$Timeout = 0, [byte[]]$BodyBytes = $null, [string]$OutFile = '')
    if ($Path -eq '/ISAPI/System/deviceInfo') { return @{ code = 200; body = '<DeviceInfo><model>DS-7608NI-K2</model><serialNumber>TESTDEV0001</serialNumber><macAddress>AA:BB:CC:00:00:01</macAddress><firmwareVersion>V4.1</firmwareVersion><firmwareReleasedDate>build 240101</firmwareReleasedDate></DeviceInfo>' } }   # 2.2.19: the device says who it is (NvrFix re-identifies it before every write)
    if ($Path -like '/rest/v3/devices*') {
      $one = '{"id":"c1","name":"One","url":"http://10.0.0.41","schedule":{"isEnabled":' + $(if ($script:Put1) { 'true' } else { 'false' }) + '}}'
      $two = '{"id":"c2","name":"Two","url":"http://10.0.0.42","schedule":{"isEnabled":true}}'
      $three = switch ($script:Mode) {
        'new-off' { '{"id":"c3","name":"Three","url":"http://10.0.0.43","schedule":{"isEnabled":false}}' }
        'new-unknown' { '{"id":"c3","name":"Three","url":"http://10.0.0.43","schedule":{}}' }
        'new-on' { '{"id":"c3","name":"Three","url":"http://10.0.0.43","schedule":{"isEnabled":true}}' }
        default { '' }
      }
      $b = @($one, $two); if ($script:Put1 -and $three) { $b += $three }
      return @{ code = 200; body = ('[' + ($b -join ',') + ']') }
    }
    return @{ code = 404; body = '' }
  }
  $out = @()
  for ($i = 0; $i -lt $runs; $i++) {
    $w0 = $script:Writes
    $r = Invoke-NvrFix -Fix recording -Ip 10.0.0.20 -Vendor DW -Credential $cred -Confirm { 'YES' } -BackupDir (Join-Path $dir ('dw-' + $mode + '-' + $i)) 6>$null
    $out += [pscustomobject]@{ ok = [bool]$r.ok; ran = [bool]$r.ran; writes = ($script:Writes - $w0); wc3 = $script:WritesC3; changed = (@($r.changed) -join ', '); msg = [string]$r.msg; history = [string]$r.history }
  }
  return $out
}
$r = @(InMod $dw @($cred, 'new-off', $tmp))[0]
Check ($r.writes -eq 1 -and $r.changed -eq 'One' -and $r.wc3 -eq 0) 'Codex 2.2.16 (DW): camera One (recording off) is turned on with one write; the new camera Three is not written' ('writes=' + $r.writes + ' changed=' + $r.changed + ' wc3=' + $r.wc3)
Check (& $notGreen $r) 'Codex 2.2.16 (DW): camera Three NEW in the read-back with recording OFF -> NOT ok, no "Recording is ON again", history NOT confirmed (2.2.16: success)' ($r.msg + ' | ' + $r.history)
Check ($r.msg -match 'Three \(10\.0\.0\.43\) - NEW in DW''s camera list read back' -and $r.msg -match 'recording OFF') 'Codex 2.2.16 (DW): the result names Three (10.0.0.43) as new with recording OFF' $r.msg
$r = @(InMod $dw @($cred, 'new-unknown', $tmp))[0]
Check ((& $notGreen $r) -and $r.msg -match 'could NOT be checked for: Three') 'DW: camera Three NEW in the read-back with recording unknown -> NOT confirmed, named (unchanged from 2.2.16)' ($r.msg + ' | ' + $r.history)
$rr = @(InMod $dw @($cred, 'new-on', $tmp))
Check ($rr[0].ok -and $rr[0].msg -match '^Recording is ON again for: One\.' -and $rr[0].history -match '^Recording turned back on: One') 'control (DW): a camera NEW in the read-back with recording ON does not block "Recording is ON again"' ($rr[0].msg + ' | ' + $rr[0].history)
$rr = @(InMod $dw @($cred, 'none', $tmp))
Check ($rr[0].ok -and $rr[0].msg -match '^Recording is ON again for: One\.') 'control (DW): same list before and after, all on -> "Recording is ON again"' $rr[0].msg
Deferred 'a real Hikvision NVR / DW server that lists a new camera in its read-back after a recording change: stand-ins only - NEEDS A REAL-DEVICE CHECK'
} catch { $script:fail++; Write-Host ('FAIL unexpected error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.ScriptLineNumber) }
finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
Write-Host ''
Write-Host ('Test-Fix2217Nvr: ' + $script:pass + ' passed, ' + $script:fail + ' failed, ' + $script:deferred + ' deferred')
if ($script:fail) { exit 1 }
exit 0
