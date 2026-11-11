# NvrFix.ps1 - WireIt Toolkit Release C fix buttons (Nov 3 2026). Dot-sourced by NvrHealth.psm1 (uses its Http/Hik/Dw helpers).
# UNTESTED ON REAL GEAR: every write below was checked against the mock devices only.
# Rules for every fix: it runs only for a check that failed; it shows the plan, then needs YES typed in capital letters;
# it saves a backup/export first; it never stores or logs a password; it tries a login at most once; nothing is retried.
$script:FixLimitPerHour = 1; $script:FixLimitPerDay = 2

# 2.2.18 (Codex F7): the backup has its own contract, whatever the caller's ErrorActionPreference: every file error stops HERE
# (local Stop + try/catch), and the file must exist, be non-empty and read back the same before the caller may write to a device.
# Returns the path, or '' = NOT saved ($script:FixSaveWhy says why); every repair then refuses: "backup could not be saved,
# nothing changed". No folder given = a dated folder under TEMP\WireIt-backup (2.2.17 skipped the backup then and still wrote).
$script:FixSaveWhy = ''
function Fix-Save([string]$dir, [string]$name, [string]$text) {
  $ErrorActionPreference = 'Stop'
  $script:FixSaveWhy = ''
  try {
    if (-not $dir) { $dir = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'WireIt-backup') (Get-Date -Format 'yyyyMMdd-HHmmss-fff') }
    $body = [string](Redact $text)
    if (-not $body.Trim()) { $script:FixSaveWhy = 'there was nothing to save'; return '' }
    New-Item -ItemType Directory -Force -Path $dir -WhatIf:$false -Confirm:$false -ErrorAction Stop | Out-Null
    $p = Join-Path $dir $name
    Set-Content -LiteralPath $p -Value $body -Encoding UTF8 -WhatIf:$false -Confirm:$false -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $script:FixSaveWhy = 'the file is not there after saving'; return '' }
    if ((Get-Item -LiteralPath $p -ErrorAction Stop).Length -le 0) { $script:FixSaveWhy = 'the saved file is empty'; return '' }
    $back = [string](Get-Content -LiteralPath $p -Raw -Encoding UTF8 -ErrorAction Stop)
    if ($back.TrimEnd() -cne $body.TrimEnd()) { $script:FixSaveWhy = 'the saved file does not read back the same'; return '' }
    return $p
  } catch { $script:FixSaveWhy = [string]$_.Exception.Message; return '' }
}
function Fix-SaveFailed([string]$what) { return ('The backup of ' + $what + ' could not be saved (' + $script:FixSaveWhy + '), so nothing was changed. Free some disk space or pick another backup folder, then run it again.') }
function Read-FixLimits([string]$stateFile) {
  # 2.2.19 (Codex 2.2.18 F22, class E): @{ ok; map; why }. The restart record must be READ to know the budget: no file yet = an
  # empty record (ok); a file that is there but cannot be read, is not a JSON object, or holds a value that is not a list of
  # times = the budget is UNKNOWN (ok = $false) - no restart until it is fixed. Never "no restarts yet" from a broken record.
  $h = @{}
  if (-not (Test-Path -LiteralPath $stateFile)) { return @{ ok = $true; map = $h; why = '' } }
  $leaf = Split-Path -Leaf $stateFile
  $raw = $null; try { $raw = Get-Content -LiteralPath $stateFile -Raw -ErrorAction Stop } catch { return @{ ok = $false; map = $h; why = ('its restart record (' + $leaf + ') could not be read') } }
  if (-not ([string]$raw).Trim()) { return @{ ok = $false; map = $h; why = ('its restart record (' + $leaf + ') is empty') } }
  $o = $null; try { $o = ([string]$raw | ConvertFrom-Json -ErrorAction Stop) } catch { return @{ ok = $false; map = $h; why = ('its restart record (' + $leaf + ') is damaged (not readable)') } }
  if ($null -eq $o -or $o -is [array] -or -not ($o -is [psobject]) -or $o -is [string] -or $o -is [ValueType]) { return @{ ok = $false; map = $h; why = ('its restart record (' + $leaf + ') is not a restart record') } }
  foreach ($p in $o.PSObject.Properties) {
    $ts = @()
    foreach ($v in @($p.Value)) {
      $d = [datetime]::MinValue
      if ($null -eq $v -or -not [datetime]::TryParse([string]$v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { return @{ ok = $false; map = @{}; why = ('its restart record (' + $leaf + ') has an entry that is not a time') } }
      $ts += $d
    }
    $h[$p.Name] = $ts
  }
  return @{ ok = $true; map = $h; why = '' }
}
function Fix-LimitOk([string]$stateFile, [string]$key, [datetime]$now) {
  # restart limits per camera: 1 per hour, 2 per day (then one alert line, no more restarts)
  if (-not $stateFile) { return @{ ok = $true; why = '' } }
  # 2.2.18 (sweep, class C) + 2.2.19 (F22): a restart-limit file that is there but cannot be read is NOT "no restarts yet" - refuse
  $rl = Read-FixLimits $stateFile
  if (-not $rl.ok) { return @{ ok = $false; why = ($rl.why + ', so the 1-per-hour / 2-per-day limit cannot be checked - fix or delete that file first') } }
  $times = @(); if ($rl.map.ContainsKey($key)) { $times = @($rl.map[$key]) }
  if (@($times | Where-Object { ($now - $_).TotalHours -lt 1 }).Count -ge $script:FixLimitPerHour) { return @{ ok = $false; why = 'it was already restarted in the last hour' } }
  if (@($times | Where-Object { ($now - $_).TotalHours -lt 24 }).Count -ge $script:FixLimitPerDay) { return @{ ok = $false; why = 'it was already restarted twice today - something else is wrong, go look at it' } }
  return @{ ok = $true; why = '' }
}
function Write-FixLimits([string]$stateFile, [hashtable]$h) {
  # write to a side file, move it over the record, then READ IT BACK: $true only when the saved record is the one meant
  $ErrorActionPreference = 'Stop'
  $out = [ordered]@{}; foreach ($k in ($h.Keys | Sort-Object)) { $out[$k] = @(@($h[$k]) | ForEach-Object { ([datetime]$_).ToString('s') }) }
  $tmp = $stateFile + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
  try {
    $dir = Split-Path -Parent $stateFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir -WhatIf:$false -Confirm:$false | Out-Null }
    (([pscustomobject]$out) | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $tmp -Encoding UTF8 -WhatIf:$false -Confirm:$false
    Move-Item -LiteralPath $tmp -Destination $stateFile -Force -WhatIf:$false -Confirm:$false
  } catch { Log ('restart limit NOT saved: ' + $_.Exception.Message); Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; return $false }
  $back = Read-FixLimits $stateFile
  if (-not $back.ok) { Log ('restart limit saved but does not read back: ' + $back.why); return $false }
  foreach ($k in $h.Keys) {
    $want = @(@($h[$k]) | ForEach-Object { ([datetime]$_).ToString('s') }); $got = @(@($back.map[$k]) | ForEach-Object { ([datetime]$_).ToString('s') })
    if (($want -join ',') -ne ($got -join ',')) { Log ('restart limit saved but reads back different for ' + $k); return $false }
  }
  return $true
}
function Fix-LimitReserve([string]$stateFile, [string]$key, [datetime]$now) {
  # 2.2.19 (Codex 2.2.18 F22, class E): the restart is RESERVED on disk BEFORE the restart is sent. The record is read again (a
  # restart made by another window in the meantime counts), the limit is checked on that fresh read, this restart is added, the
  # record is saved and read back. @{ ok; why }: ok = $false (unreadable record, limit reached, save failed) = NO restart.
  # The reservation stays when the outcome is unknown (no answer / restart not confirmed): it is the durable uncertain attempt.
  if (-not $stateFile) { return @{ ok = $false; why = 'no restart record file was given, so the limit could not be kept' } }
  $rl = Read-FixLimits $stateFile
  if (-not $rl.ok) { return @{ ok = $false; why = ($rl.why + ', so the restart limit cannot be kept') } }
  $lim = Fix-LimitOk $stateFile $key $now; if (-not $lim.ok) { return $lim }
  $h = $rl.map
  $keep = @(@($h[$key]) | Where-Object { $_ -and ($now - [datetime]$_).TotalDays -lt 2 }); $h[$key] = @($keep + $now)
  if (-not (Write-FixLimits $stateFile $h)) { return @{ ok = $false; why = 'the restart limit could not be saved on this PC (' + (Split-Path -Leaf $stateFile) + ')' } }
  return @{ ok = $true; why = '' }
}
function Fix-LimitRelease([string]$stateFile, [string]$key, [datetime]$now) {
  # 2.2.19: the camera said NO (an explicit refusal): nothing restarted, so the reservation is taken back. If that fails the
  # reservation stays (the safe side: one restart counted that did not happen).
  if (-not $stateFile) { return $false }
  $rl = Read-FixLimits $stateFile; if (-not $rl.ok) { return $false }
  $h = $rl.map; $mine = $now.ToString('s')
  $left = @(@($h[$key]) | Where-Object { ([datetime]$_).ToString('s') -ne $mine })
  if ($left.Count) { $h[$key] = $left } else { [void]$h.Remove($key) }
  $ok = Write-FixLimits $stateFile $h
  if ($ok -and (Read-FixLimits $stateFile).map.ContainsKey($key) -and -not $left.Count) { return $false }
  return $ok
}
function Fix-LimitAdd([string]$stateFile, [string]$key, [datetime]$now) {
  # kept for older callers: the same reservation (read, check, save, read back); $true only when it was really saved
  if (-not $stateFile) { return $false }
  $rl = Read-FixLimits $stateFile; if (-not $rl.ok) { return $false }
  $h = $rl.map; $keep = @(@($h[$key]) | Where-Object { $_ -and ($now - [datetime]$_).TotalDays -lt 2 }); $h[$key] = @($keep + $now)
  return (Write-FixLimits $stateFile $h)
}
function Dw-Send($t, [string]$method, [string]$path, $obj, [switch]$Secret) {
  return Http -Ip $t.ip -Method $method -Path $path -Body ($obj | ConvertTo-Json -Compress -Depth 5) -ContentType 'application/json' -Headers @{ Authorization = ('Bearer ' + $t.token) } -Port (Dw-Port $t) -Scheme (Dw-Scheme) -NoLogBody:$Secret
}
function Fix-Strong([string]$pw) { return ($pw.Length -ge 8 -and $pw -match '[A-Za-z]' -and $pw -match '\d') }
# 2.2.4 (Codex re-review): the settings export taken before a firmware update must BE a settings export: a login/HTML page,
# an error answer or a few bytes is FAILED and the update does not run.
function Test-NhBackupFile([string]$path) {
  if (-not $path -or -not (Test-Path -LiteralPath $path)) { return 'missing' }
  $len = (Get-Item -LiteralPath $path).Length; if ($len -le 0) { return 'empty' }
  $fs = [IO.File]::OpenRead($path); try { $b = New-Object byte[] ([Math]::Min([int64]4096, $fs.Length)); [void]$fs.Read($b, 0, $b.Length) } finally { $fs.Dispose() }
  $head = [Text.Encoding]::UTF8.GetString($b)
  if ($head -match '(?is)^\s*(\xEF\xBB\xBF|\uFEFF)?\s*(<!doctype\s+html|<html)' -or $head -match '(?is)<html[\s>]|<body[\s>]|<form[^>]*>|type\s*=\s*["'']?password|<title>[^<]*(log\s*in|sign\s*in)') { return 'the device answered with a login/HTML page, not its settings' }
  if ($head -match '(?is)^\s*<\?xml[^>]*>\s*<ResponseStatus|^\s*<ResponseStatus') { return 'the device answered with an error, not its settings' }
  if ($len -lt 512) { return ('too small to be a settings export (' + $len + ' bytes)') }
  return ''
}
function Fix-Xml([string]$s) { return [Security.SecurityElement]::Escape($s) }
# 2.2.19 (Codex 2.2.18 F04): the exact XML of one NVR channel entry ('' = the channel is not in the list) - compared before and
# after the YES, so a channel that changed while the technician was reading the plan is never written over
function Get-NhChannelXml($doc, [int]$ch) {
  foreach ($c in (XFind $doc 'InputProxyChannel')) { if ([string](XText $c 'id') -eq [string]$ch) { return ([string]$c.OuterXml).Trim() } }
  return ''
}

# 2.2.19 (lead, sweep2's open class-A row): the device the technician picked carries the MAC the last scan saved for that address
# (-ExpectMac, from the window). When one is given, the device answering must report that MAC, non-empty and the same, before
# anything is planned or written; a device that does not say its MAC cannot be checked against it and is refused too.
function ConvertTo-FixMacKey([string]$m) { return (([string]$m).ToUpper() -replace '[^0-9A-F]', '') }
function Get-FixExpectWhy($id, [string]$expect, [string]$ip) {
  $want = ConvertTo-FixMacKey $expect
  if (-not $want) { return '' }
  if ($want.Length -ne 12) { return ('the MAC saved for ' + $ip + ' (' + $expect + ') is not a MAC address, so the device cannot be checked against it') }
  $have = ConvertTo-FixMacKey ([string]$id.mac)
  if (-not $have) { return ('the device at ' + $ip + ' did not say its MAC, so it cannot be checked against the MAC the last scan saved (' + $expect + ')') }
  if ($have -ne $want) { return ('a DIFFERENT device answers at ' + $ip + ' (MAC ' + [string]$id.mac + '; the last scan saved ' + $expect + ')') }
  return ''
}
# 2.2.20 (Codex 2.2.19 R11, class B): does a device-information answer that was ALREADY READ belong to the device saved in $first?
# Every identity value saved the first time (serial, MAC) must be in it again, non-empty and the same; a missing value is a
# MISMATCH, never a pass. @{ ok; why }
function Test-NhIdMatch($first, $info) {
  if (-not $first -or -not $first.ok) { return @{ ok = $false; why = 'which device this is was never read' } }
  if (-not $info -or $info.login -ne 'ok') { return @{ ok = $false; why = 'its device information could not be read' } }
  $sn = ([string]$info.serial).Trim(); $mc = $(if ($info.ContainsKey('mac')) { ([string]$info.mac).Trim() } else { '' })
  if ($first.serial -and $sn -cne $first.serial) { return @{ ok = $false; why = ('a different device answers now (serial ' + $(if ($sn) { $sn } else { 'not given' }) + ', it was ' + $first.serial + ')') } }
  $mk = ConvertTo-FixMacKey $mc
  if ($first.mac -and (-not $mk -or $mk -ne (ConvertTo-FixMacKey $first.mac))) { return @{ ok = $false; why = ('a different device answers now (MAC ' + $(if ($mc) { $mc } else { 'not given' }) + ', it was ' + $first.mac + ')') } }
  return @{ ok = $true; why = '' }
}
# 2.2.20 (Codex 2.2.19 R10/R12, classes C + F): what a Hikvision write answer really says. 'ok' = a <ResponseStatus> with statusCode
# 1 or 7; 'refused' = an EXPLICIT no (a ResponseStatus with another statusCode, or an HTTP 4xx answer); 'unknown' = everything else
# (no answer, a 5xx, a 200 that is not a ResponseStatus: empty, HTML, a login page). Only 'refused' may be treated as "not done".
function Get-HikWriteAnswer($w) {
  $code = [int]$w.code
  if ($code -ge 400 -and $code -lt 500) { return 'refused' }
  if ($code -ne 200) { return 'unknown' }
  $x = Xml ([string]$w.body)
  if (-not $x -or -not $x.DocumentElement -or $x.DocumentElement.LocalName -notmatch '(?i)^ResponseStatus$') { return 'unknown' }
  $sc = XText $x 'statusCode'
  if ($sc -eq '1' -or $sc -eq '7') { return 'ok' }
  if ($sc -match '^\d+$') { return 'refused' }
  return 'unknown'
}
# 2.2.20 (Codex 2.2.19 R12, class C): a login with $cred is proven ONLY by the device's own DeviceInfo document (root element
# DeviceInfo) from the SAME device (Test-NhIdMatch). An HTTP 200 login / error / HTML page is NOT a login. A 401 / 403 is an
# explicit "wrong password". @{ state = 'ok' | 'refused' | 'other' | 'unknown'; code; why }. Read straight through Http with the
# given login, so a refused try does not block the other password's try in this run.
function Test-NhHikLoginAs($t, [pscredential]$cred, $first) {
  $r = Http -Ip $t.ip -Path '/ISAPI/System/deviceInfo' -Credential $cred -Port $t.port
  $code = [int]$r.code
  if ($code -eq 401 -or $code -eq 403) { return @{ state = 'refused'; code = $code; why = ('the login was refused, answer ' + $code) } }
  if ($code -ne 200) { return @{ state = 'unknown'; code = $code; why = $(if ($code -le 0) { 'no answer' } else { 'answer ' + $code }) } }
  $x = Xml ([string]$r.body)
  if (-not $x -or -not $x.DocumentElement -or $x.DocumentElement.LocalName -notmatch '(?i)^DeviceInfo$') { return @{ state = 'unknown'; code = $code; why = 'the answer was not the device''s information (an error or login page)' } }
  $info = @{ login = 'ok'; serial = (XText $x 'serialNumber'); mac = ((XText $x 'macAddress').ToUpper().Replace('-', ':')) }
  $m = Test-NhIdMatch $first $info
  if (-not $m.ok) { return @{ state = 'other'; code = $code; why = $m.why } }
  return @{ state = 'ok'; code = $code; why = '' }
}
function Invoke-NvrFix {
  <#
  .SYNOPSIS One fix, after a check failed. Plan -> backup -> typed YES -> change -> verify. UNTESTED ON REAL GEAR.
    recording   recorder: turn recording back on for cameras whose recording is switched off (Hikvision NVR tracks / DW camera schedule)
    restart     camera: reboot it through its own web API (Hikvision / Uniview). Max 1 per hour, 2 per day per camera.
    readd       Hikvision NVR: put a camera back on its previous channel (-Channel, -CameraIp, camera password typed, never stored)
    firmware    ONE device: official file + its SHA-256 typed from the vendor page; config exported first; Hikvision only
    password    ONE device: set the site password (typed twice by the caller); Hikvision only
    dwpassword  DW server: give DW the camera's right password (-CameraIp) so it stops locking the camera
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][ValidateSet('recording', 'restart', 'readd', 'firmware', 'password', 'dwpassword')][string]$Fix,
        [Parameter(Mandatory)][string]$Ip, [ValidateSet('Auto', 'Hikvision', 'Uniview', 'DW', 'Onvif')][string]$Vendor = 'Auto',
        [pscredential]$Credential, [int]$Port = 0, [int]$Channel = 0, [string]$CameraIp = '', [pscredential]$NewCredential,
        [string]$File = '', [string]$Sha256 = '', [string]$BackupDir = '', [string]$StateFile = '', [scriptblock]$Confirm = $null, [int]$WaitSec = 180,
        [string]$ExpectMac = '')
  Start-Log ('fix-' + $Fix)
  $res = [ordered]@{ fix = $Fix; ip = $Ip; ran = $false; ok = $false; changed = @(); backup = ''; history = ''; msg = '' }
  $done = { param($ok, $msg) $res.ok = $ok; $res.msg = $msg; Say ''; Say ('RESULT: ' + $msg) $(if ($ok) { 'Green' } else { 'Red' }); return [pscustomobject]$res }
  $ask = { param($plan) Say ''; foreach ($l in @($plan)) { Say ('PLAN    ' + $l) 'Yellow' }
    $a = $(if ($Confirm) { [string](& $Confirm $plan) } else { Read-Host 'Type YES (capital letters) to do this now, anything else = no change' })
    if ($a -ceq 'YES') { Say 'You typed YES.'; return $true }; Say 'Not confirmed (you did not type YES). Nothing was changed.' 'Yellow'; return $false }
  $now = Get-Date
  if ($Fix -eq 'restart') {
    $lim = Fix-LimitOk $StateFile $Ip $now
    if (-not $lim.ok) { return (& $done $false ('Not restarted: ' + $lim.why + '.')) }
  }
  if ($Fix -in @('readd', 'password', 'dwpassword') -and -not $NewCredential) { return (& $done $false 'No password typed - nothing changed.') }
  if ($Fix -eq 'password' -and -not (Fix-Strong (Plain $NewCredential))) { return (& $done $false 'The new password is too weak (8+ characters, letters and numbers). Nothing changed.') }
  if ($Fix -eq 'dwpassword' -and $Vendor -eq 'Auto') { $Vendor = 'DW' }
  $t = Resolve-Target $Ip $Vendor $Credential $Port
  $v = $t.vendor
  switch ($Fix) {
    'recording' {
      if ($v -eq 'Hikvision') {
        # 2.2.13 (Codex 2.2.12 #7): ONE read of the track list, checked: a failed / unreadable answer is "could not read", never
        # "already on for every camera". 2.2.12 read it twice and an error on the 2nd read became an empty list = all on.
        $id0 = Get-NhDeviceId $t   # 2.2.19 (class A): which recorder this is, read again right before the writes
        if (-not $id0.ok) { return (& $done $false ('The recorder at ' + $Ip + ' did not say which recorder it is (' + $id0.why + '), so recording was NOT changed. Nothing changed.')) }
        $xw = Get-FixExpectWhy $id0 $ExpectMac $Ip; if ($xw) { return (& $done $false ('NOT changed: ' + $xw + '. Nothing changed. Run the scan again, or check which device has this address.')) }   # 2.2.19 (class A)
        $rt = Hik-ReadTracks $t
        if (-not $rt.ok) { return (& $done $false ('Could not read the recording settings (' + $rt.why + '). Recording NOT CHECKED, nothing changed. Run it again.')) }
        if (-not $rt.map.Count) { return (& $done $false 'The recorder lists no recording settings at all, so recording could NOT be checked. Nothing changed. Look at Storage > Recording schedule on the recorder.') }
        # 2.2.14 (Codex 2.2.13 F9): a track whose Enable is missing / not true-or-false, or that has no schedule entries, is
        # UNKNOWN - never counted as "on". Only explicit Enable=false tracks are turned on; unknown ones keep the result not green.
        # 2.2.15 (Codex 2.2.14 R6): a track with Enable=true whose schedule has only Record=false is OFF too (the read-only check
        # says "turned OFF in its schedule"), so the fix turns its schedule slots on. A Record value that is not true/false = unknown.
        $off = @($rt.map.Values | Where-Object { $_.enabled -eq $false -or ($_.enabled -eq $true -and $_.hasSchedule -eq $false) } | Sort-Object id)
        $unknownTr = @($rt.map.Values | Where-Object { $null -eq $_.enabled -or ($_.enabled -eq $true -and $null -eq $_.hasSchedule) } | Sort-Object id)
        $unkWords = { param($list) (@($list | ForEach-Object { [math]::Floor($_.id / 100) }) -join ', ') }
        $offWhy = { param($o) 'camera ' + [math]::Floor($o.id / 100) + $(if ($o.enabled -eq $false -and $o.hasSchedule -eq $false) { ' (recording switched off and no recording time in its schedule)' } elseif ($o.enabled -eq $false) { ' (recording switched off)' } else { ' (its schedule has no recording time)' }) }
        if (-not $off.Count -and $unknownTr.Count) { return (& $done $false ('Recording could NOT be checked for camera(s) ' + (& $unkWords $unknownTr) + ': the recorder did not say whether recording is on (no clear Enable / schedule). NOT CHECKED, nothing changed. Look at Storage > Recording schedule on the recorder.')) }
        if (-not $off.Count) { return (& $done $true ('Recording is already on for every camera (' + $rt.map.Count + ' recording settings read). Nothing to change.')) }
        $res.backup = Fix-Save $BackupDir 'record-tracks-before.xml' $rt.body
        if (-not $res.backup) { return (& $done $false (Fix-SaveFailed 'the recording settings')) }   # 2.2.18 (Codex F7)
        if (-not (& $ask @('Turn recording back ON for: ' + (@($off | ForEach-Object { & $offWhy $_ }) -join ', ') + ' on ' + $Ip + '. A switched-off camera keeps its schedule as it is; a schedule with no recording time gets every one of its time slots set to record.', 'Backup of the recording settings saved: ' + $res.backup))) { return (& $done $true 'Not confirmed - nothing changed.') }
        $same = Test-NhSameDevice $t $id0
        if (-not $same.ok) { return (& $done $false ('Recording NOT changed: ' + $same.why + '. Nothing changed.')) }
        $res.ran = $true
        $skipped = @(); $stopWhy = ''; $notWritten = @()
        foreach ($o in $off) {
          # 2.2.20 (Codex 2.2.19 R21, class B): the recorder is identified AGAIN right before each track is read and right before it is
          # written - the one check after YES does not cover the writes that follow. A different / unreadable recorder = STOP: no
          # more writes, the rest is reported NOT done.
          if ($stopWhy) { $notWritten += $o; continue }
          $sameR = Test-NhSameDevice $t $id0
          if (-not $sameR.ok) { $stopWhy = $sameR.why; Log ('track ' + $o.id + ': STOP, the recorder is not the same one (' + $sameR.why + ') - not written'); $notWritten += $o; continue }
          $one = Http -Ip $Ip -Path ('/ISAPI/ContentMgmt/record/tracks/' + $o.id) -Credential $t.cred -Port $t.port
          # 2.2.13: never PUT back an answer that is not this camera's own track (an error page / another track)
          # 2.2.15: and only when it still shows the same off state that was read in the list (else: not written, reported)
          $oneMap = $(if ($one.code -eq 200) { Hik-ParseTracks ([string]$one.body) } else { $null })
          $cur = $(if ($oneMap -and $oneMap.ContainsKey($o.id)) { $oneMap[$o.id] } else { $null })
          if (-not $cur -or $cur.enabled -ne $o.enabled -or $cur.hasSchedule -ne $o.hasSchedule) { Log ('track ' + $o.id + ': could not read it, or it changed (answer ' + $one.code + ') - not written'); $skipped += $o; continue }
          # 2.2.19 (class B): back up the EXACT track that is about to be replaced (read after YES); not saved = not written
          $bkT = Fix-Save $BackupDir ('record-track-' + $o.id + '-at-write.xml') ([string]$one.body)
          if (-not $bkT) { Log ('track ' + $o.id + ': its backup could not be saved (' + $script:FixSaveWhy + ') - not written'); $skipped += $o; continue }
          $xml = [string]$one.body
          if ($o.enabled -eq $false) { $xml = $xml -replace '<Enable>\s*(?i:false)\s*</Enable>', '<Enable>true</Enable>' }
          if ($o.hasSchedule -eq $false) { $xml = $xml -replace '<Record>\s*(?i:false)\s*</Record>', '<Record>true</Record>' }
          $sameW = Test-NhSameDevice $t $id0
          if (-not $sameW.ok) { $stopWhy = $sameW.why; Log ('track ' + $o.id + ': STOP, the recorder is not the same one right before the write (' + $sameW.why + ') - not written'); $notWritten += $o; continue }
          $w = Http -Ip $Ip -Method 'PUT' -Path ('/ISAPI/ContentMgmt/record/tracks/' + $o.id) -Body $xml -Credential $t.cred -Port $t.port
          if (Hik-Ok $w) { $res.changed += ('camera ' + [math]::Floor($o.id / 100)) }
        }
        if ($stopWhy) {
          $doneW = $(if ($res.changed.Count) { ($res.changed -join ', ') } else { 'nothing' })
          $notW = (@($notWritten | ForEach-Object { 'camera ' + [math]::Floor($_.id / 100) }) -join ', ')
          $res.history = 'Recording turn-on STOPPED on ' + $Ip + ' (' + $stopWhy + ') - sent: ' + $doneW + '; NOT done: ' + $notW + ' - NOT confirmed'
          return (& $done $false ('STOPPED - NOT confirmed: ' + $stopWhy + ', so nothing more was written. Sent before it stopped: ' + $doneW + '. NOT done: ' + $notW + '. Check which recorder has the address ' + $Ip + ', then run the Recording check again.'))
        }
        # 2.2.20 (R21): the read that certifies the result must come from the same recorder - checked right before AND right after it
        $sameV = Test-NhSameDevice $t $id0
        $ra = $(if ($sameV.ok) { Hik-ReadTracks $t } else { @{ ok = $false; map = @{}; why = ('the recorder is not the same one (' + $sameV.why + ')'); body = '' } })
        if ($ra.ok) { $sameV2 = Test-NhSameDevice $t $id0; if (-not $sameV2.ok) { $ra = @{ ok = $false; map = @{}; why = ('the recorder is not the same one after the read-back (' + $sameV2.why + ')'); body = '' } } }
        if (-not $ra.ok) {
          $res.history = 'Recording turn-on sent for: ' + ($res.changed -join ', ') + ' (' + $Ip + ') - NOT confirmed (read-back failed)'
          return (& $done $false ('Sent to the recorder, but its recording settings could not be read back (' + $ra.why + '), so it is NOT confirmed. Run the Recording check again.'))
        }
        $afterTracks = $ra.map
        # 2.2.15: "on again" = Enable true AND a schedule with recording time (an explicit false schedule is still off)
        $still = @($off | Where-Object { -not $afterTracks.ContainsKey($_.id) -or $afterTracks[$_.id].enabled -ne $true -or $afterTracks[$_.id].hasSchedule -eq $false })
        # 2.2.16 (Codex 2.2.15 F5): keep the FIRST inventory through the check. Every camera read before the change must be in the
        # read-back with a known state: one that is missing from the read-back, or still unknown, is NOT CHECKED (never green).
        # A camera that was on before and now reads off counts as still off.
        $offIds = @($off | ForEach-Object { $_.id })
        $goneAfter = @($rt.map.Values | Where-Object { -not $afterTracks.ContainsKey($_.id) -and $offIds -notcontains $_.id } | Sort-Object id)
        $nowOff = @($rt.map.Values | Where-Object { $offIds -notcontains $_.id -and $afterTracks.ContainsKey($_.id) -and ($afterTracks[$_.id].enabled -eq $false -or ($afterTracks[$_.id].enabled -eq $true -and $afterTracks[$_.id].hasSchedule -eq $false)) } | Sort-Object id)
        $still = @(@($still) + @($nowOff))
        $unknownAfter = @($afterTracks.Values | Where-Object { $null -eq $_.enabled -or ($_.enabled -eq $true -and $null -eq $_.hasSchedule) } | Sort-Object id)
        # 2.2.17 (Codex 2.2.16 re-review): a camera that is NEW in the read-back (not in the first list) and reads OFF is not "on again"
        # either: this run did not look at it before, so the result stays NOT confirmed and names it (unknown new ones: the line below).
        $newOff = @($afterTracks.Values | Where-Object { -not $rt.map.ContainsKey($_.id) -and ($_.enabled -eq $false -or ($_.enabled -eq $true -and $_.hasSchedule -eq $false)) } | Sort-Object id)
        $unkNote = ''
        if ($goneAfter.Count) { $unkNote += ' Camera(s) ' + (& $unkWords $goneAfter) + ' were in the recording list before the change but NOT in the answer read back afterwards: NOT CHECKED.' }
        if ($newOff.Count) { $unkNote += ' Camera(s) ' + (& $unkWords $newOff) + ' are NEW in the answer read back (not in the list before the change) and their recording is OFF: NOT confirmed, not changed by this run.' }
        if ($unknownAfter.Count) { $unkNote += ' Recording could NOT be checked for camera(s) ' + (& $unkWords $unknownAfter) + ' (no clear Enable / schedule).' }
        $stillWords = { param($list) (@($list | ForEach-Object { 'camera ' + [math]::Floor($_.id / 100) }) -join ', ') }
      } elseif ($v -eq 'DW') {
        if (-not (Dw-Login $t)) { return (& $done $false 'The DW server refused the login. Nothing changed.') }
        # 2.2.14 (Codex 2.2.13 F6): the list read must succeed and be a real camera list; a camera without a readable recording
        # flag is UNKNOWN. "Already on for every camera" only when every camera's settings were read and say on.
        $rd = Dw-ReadDevices $t
        if (-not $rd.ok) { return (& $done $false ('Could not read DW''s camera list (' + $rd.why + '). Recording NOT CHECKED, nothing changed. Run it again.')) }
        $devs = @($rd.devs)
        if (-not $devs.Count) { return (& $done $false 'DW lists no cameras at all, so recording could NOT be checked. Nothing changed. Look at the cameras in the DW client.') }
        $off = @($devs | Where-Object { $_.scheduled -eq $false })
        $unknownDw = @($devs | Where-Object { $null -eq $_.scheduled })
        $unkWords = { param($list) (@($list | ForEach-Object { $_.name + ' (' + $_.ip + ')' }) -join ', ') }
        if (-not $off.Count -and $unknownDw.Count) { return (& $done $false ('Recording could NOT be checked for ' + $unknownDw.Count + ' camera(s) in DW: ' + (& $unkWords $unknownDw) + ' (DW did not say whether recording is on). NOT CHECKED, nothing changed.')) }
        if (-not $off.Count) { return (& $done $true ('Recording is already on for every camera in DW (' + $devs.Count + ' cameras read). Nothing to change.')) }
        $res.backup = Fix-Save $BackupDir 'dw-cameras-before.json' ($devs | ConvertTo-Json -Depth 4)
        if (-not $res.backup) { return (& $done $false (Fix-SaveFailed 'DW''s camera list')) }   # 2.2.18 (Codex F7)
        if (-not (& $ask @('Turn recording back ON in DW for: ' + (($off | ForEach-Object { $_.name + ' (' + $_.ip + ')' }) -join ', ') + '.', 'Backup of the camera list saved: ' + $res.backup))) { return (& $done $true 'Not confirmed - nothing changed.') }
        # 2.2.19 (Codex 2.2.18 F04 twin, class B): read DW's camera list again after YES; only a camera that is still the same one
        # (same id and address) and still reads recording OFF is changed; the list read now is the backup of what is replaced
        $rd2 = Dw-ReadDevices $t
        if (-not $rd2.ok) { return (& $done $false ('After your YES, DW''s camera list could not be read again (' + $rd2.why + '). Nothing changed. Run it again.')) }
        $bk2 = Fix-Save $BackupDir 'dw-cameras-at-write.json' (@($rd2.devs) | ConvertTo-Json -Depth 4)
        if (-not $bk2) { return (& $done $false (Fix-SaveFailed 'DW''s camera list (read again after your YES)')) }
        $res.backup = $bk2
        $res.ran = $true
        foreach ($o in $off) {
          # 2.2.20 (Codex 2.2.19 R21 twin, class B): DW's camera list is read again right before EACH camera's write (the read after
          # YES covers only the first one): the same camera (same DW id, address and MAC when DW gave one) and still OFF, else not written
          $c2 = @($rd2.devs | Where-Object { $_.id -eq $o.id }) | Select-Object -First 1
          if (-not $c2 -or $c2.ip -ne $o.ip -or ($o.mac -and $c2.mac -ne $o.mac) -or $c2.scheduled -ne $false) { Log ('DW camera ' + $o.name + ': changed while waiting for YES (or gone) - not written'); continue }
          $rdW = Dw-ReadDevices $t
          $cW = $(if ($rdW.ok) { @($rdW.devs | Where-Object { $_.id -eq $o.id }) | Select-Object -First 1 } else { $null })
          if (-not $cW -or $cW.ip -ne $o.ip -or ($o.mac -and $cW.mac -ne $o.mac) -or $cW.scheduled -ne $false) { Log ('DW camera ' + $o.name + ': ' + $(if (-not $rdW.ok) { 'the camera list could not be read right before its write (' + $rdW.why + ')' } else { 'changed right before its write (or gone)' }) + ' - not written'); continue }
          $w = Dw-Send $t 'PATCH' ('/rest/v3/devices/' + [uri]::EscapeDataString($o.id)) @{ schedule = @{ isEnabled = $true } }; if ($w.code -eq 200) { $res.changed += $o.name }
        }
        $ra = Dw-ReadDevices $t
        if (-not $ra.ok) {
          $res.history = 'Recording turn-on sent in DW for: ' + ($res.changed -join ', ') + ' (' + $Ip + ') - NOT confirmed (read-back failed)'
          return (& $done $false ('Sent to DW, but its camera list could not be read back (' + $ra.why + '), so it is NOT confirmed. Run the Recording check again.'))
        }
        $afterDevices = @($ra.devs)
        $still = @($off | Where-Object { $id = $_.id; -not @($afterDevices | Where-Object { $_.id -eq $id -and $_.scheduled -eq $true }).Count })
        # 2.2.16 (Codex 2.2.15 F5): keep the FIRST camera list through the check. Every camera read before the change must be in the
        # read-back with a known state: missing from the read-back, or still unknown = NOT CHECKED (never green). A camera that was on
        # before and now reads off counts as still off.
        $offIds = @($off | ForEach-Object { $_.id })
        $afterIds = @($afterDevices | ForEach-Object { $_.id })
        $goneAfter = @($devs | Where-Object { $afterIds -notcontains $_.id -and $offIds -notcontains $_.id })
        $nowOff = @($devs | Where-Object { $id = $_.id; $offIds -notcontains $id -and @($afterDevices | Where-Object { $_.id -eq $id -and $_.scheduled -eq $false }).Count })
        $still = @(@($still) + @($nowOff))
        $unknownAfter = @($afterDevices | Where-Object { $null -eq $_.scheduled })
        # 2.2.17 (Codex 2.2.16 re-review): a camera that is NEW in the read-back (not in the first list) with recording OFF keeps the
        # result NOT confirmed and is named (unknown new ones: the "could NOT be checked" line below).
        $beforeIds = @($devs | ForEach-Object { $_.id })
        $newOff = @($afterDevices | Where-Object { $beforeIds -notcontains $_.id -and $_.scheduled -eq $false })
        $unkNote = ''
        if ($goneAfter.Count) { $unkNote += ' ' + (& $unkWords $goneAfter) + ' - in DW''s camera list before the change but NOT in the list read back afterwards: NOT CHECKED.' }
        if ($newOff.Count) { $unkNote += ' ' + (& $unkWords $newOff) + ' - NEW in DW''s camera list read back (not in the list before the change) with recording OFF: NOT confirmed, not changed by this run.' }
        if ($unknownAfter.Count) { $unkNote += ' Recording could NOT be checked for: ' + (& $unkWords $unknownAfter) + '.' }
        $stillWords = { param($list) (@($list | ForEach-Object { $_.name + ' (' + $_.ip + ')' }) -join ', ') }
      } else { return (& $done $false ('Turning recording on is not built for ' + $v + ' yet. Nothing changed.')) }
      $ok = (-not $still.Count -and -not $unkNote)
      # 2.2.16 (Codex 2.2.15 F5): only a fully confirmed read-back gets "Recording is ON again" and a "turned back on" history line;
      # anything missing or unknown says NOT confirmed in both.
      if ($ok) {
        $res.history = 'Recording turned back on: ' + ($res.changed -join ', ') + ' (' + $Ip + ')'
        return (& $done $true ('Recording is ON again for: ' + ($res.changed -join ', ') + '. Check again tomorrow that footage is there.'))
      }
      $res.history = 'Recording turn-on sent for: ' + ($res.changed -join ', ') + ' (' + $Ip + ') - NOT confirmed' + $(if ($still.Count) { ' (still off: ' + (& $stillWords $still) + ')' } else { '' }) + $(if ($unkNote) { ' - some cameras NOT CHECKED' } else { '' })
      if (-not $still.Count) { return (& $done $false ('Recording turn-on sent for: ' + ($res.changed -join ', ') + ', but it is NOT confirmed for every camera - some are NOT CHECKED.' + $unkNote + ' Look at the recorder''s schedule page and run the Recording check again.')) }
      return (& $done $false ('Still off after the change: ' + $still.Count + ' (' + (& $stillWords $still) + ').' + $unkNote + ' Look at the recorder''s schedule page.'))
    }
    'restart' {
      $path = $(if ($v -eq 'Uniview') { '/LAPI/V1.0/System/Reboot' } elseif ($v -eq 'Hikvision') { '/ISAPI/System/reboot' } else { '' })
      if (-not $path) { return (& $done $false ('Restart is built for Hikvision and Uniview cameras only (this is ' + $v + '). Restart its switch port by hand.')) }
      $info = Http -Ip $Ip -Path $(if ($v -eq 'Uniview') { '/LAPI/V1.0/System/DeviceInfo' } else { '/ISAPI/System/deviceInfo' }) -Credential $t.cred -Port $t.port -Timeout 8
      if ($info.code -ne 200) { return (& $done $false ('The camera did not accept the login (answer ' + $info.code + '), so it was not restarted. If it does not answer at all, restart its switch port (PoE) by hand.')) }
      $res.backup = Fix-Save $BackupDir 'device-before.txt' $info.body
      if (-not $res.backup) { return (& $done $false (Fix-SaveFailed 'the camera''s device information')) }   # 2.2.18 (Codex F7)
      # 2.2.19 (class A): which camera this is (serial / MAC), read now and again right before the restart
      $id0 = Get-NhDeviceId $t
      if (-not $id0.ok) { return (& $done $false ('The camera at ' + $Ip + ' did not say which camera it is (' + $id0.why + '), so it was NOT restarted. Nothing changed.')) }
      $xw = Get-FixExpectWhy $id0 $ExpectMac $Ip; if ($xw) { return (& $done $false ('NOT changed: ' + $xw + '. Nothing changed. Run the scan again, or check which device has this address.')) }   # 2.2.19 (class A)
      $upPre = $null; if ($v -eq 'Hikvision') { $u0 = Hik-UpTime $t 8; if ($u0.code -eq 200) { $upPre = $u0.up } }   # 2.2.13: boot marker before (null = camera does not give it)
      if (-not (& $ask @('Restart (reboot) the camera at ' + $Ip + $(if ($id0.serial) { ' (serial ' + $id0.serial + ')' } else { '' }) + '. It is offline for about 2 minutes.', 'Allowed: 1 restart per hour, 2 per day for this camera.'))) { return (& $done $true 'Not confirmed - nothing changed.') }
      # 2.2.19 (class B): after YES - the same camera?
      $same = Test-NhSameDevice $t $id0
      if (-not $same.ok) { return (& $done $false ('Not restarted: ' + $same.why + '. Nothing changed. Check the address and run it again.')) }
      # 2.2.19 (Codex 2.2.18 F22, class E): the restart is reserved in the restart record (read again, limit checked, saved, read
      # back) BEFORE it is sent. Not saved = NOT restarted - 2.2.18 restarted first and only warned when the record failed.
      $now = Get-Date
      $rsv = Fix-LimitReserve $StateFile $Ip $now
      if (-not $rsv.ok) { return (& $done $false ('Not restarted: ' + $rsv.why + '. Nothing changed.')) }
      $res.ran = $true
      $w = Http -Ip $Ip -Method 'PUT' -Path $path -Body $(if ($v -eq 'Uniview') { '{}' } else { '' }) -ContentType $(if ($v -eq 'Uniview') { 'application/json' } else { 'application/xml' }) -Credential $t.cred -Port $t.port -Timeout 8
      # 2.2.12 (Codex P1-10): an HTTP 200 is not a yes. Hikvision answers <statusCode> (1 = OK, 7 = reboot needed), Uniview
      # answers Response.ResponseCode (0 = OK). An explicit no is a refusal: nothing restarted, and the restart limit is not used up.
      # 2.2.20 (Codex 2.2.19 R10, class F): ONLY an explicit refusal takes the reservation back: Uniview Response.ResponseCode other than
      # 0, a Hikvision <ResponseStatus> statusCode other than 1 / 7, or an HTTP 4xx answer. An answer that cannot be read (a 200 with no
      # or an unreadable code, an HTML page, a 5xx, no answer at all) is UNKNOWN - it can arrive after the camera accepted the reboot:
      # the reservation stays, the outcome is checked below and, unless proven, the result is NOT CONFIRMED (never "NOT restarted").
      $refused = ''; $unclear = ''
      if ($w.code -eq 200 -and $v -eq 'Uniview') {
        $rc = $null; try { $rj = ([string]$w.body) | ConvertFrom-Json -ErrorAction Stop; if ($rj -and $rj.PSObject.Properties['Response'] -and $rj.Response -and $rj.Response.PSObject.Properties['ResponseCode'] -and $null -ne $rj.Response.ResponseCode) { $rc = ([string]$rj.Response.ResponseCode).Trim() } } catch {}
        if ($null -eq $rc -or $rc -notmatch '^-?\d+$') { $unclear = 'the camera''s answer could not be read' } elseif ($rc -ne '0') { $refused = 'camera answer code ' + $rc }
      } elseif ($v -eq 'Uniview') {
        if ($w.code -ge 400 -and $w.code -lt 500) { $refused = 'answer ' + $w.code } elseif ($w.code -gt 0) { $unclear = 'answer ' + $w.code }
      } else {
        $hwa = Get-HikWriteAnswer $w
        if ($hwa -eq 'refused') { $refused = $(if ($w.code -eq 200) { 'camera answer ' + (XText (Xml $w.body) 'statusCode') + ' ' + (XText (Xml $w.body) 'statusString') } else { 'answer ' + $w.code }) }
        elseif ($hwa -eq 'unknown' -and $w.code -gt 0) { $unclear = $(if ($w.code -eq 200) { 'the camera''s answer could not be read' } else { 'answer ' + $w.code }) }
      }
      if ($unclear) { Log ('restart: the answer is UNCLEAR (' + $unclear + ') - the reservation stays, the outcome is checked') }
      if ($refused) {
        # an explicit NO: nothing restarted, so the reservation is taken back (if that fails it stays - one restart counted too many)
        $rel = Fix-LimitRelease $StateFile $Ip $now
        if (-not $rel) { Log 'restart refused, but its reservation could not be taken back - it stays counted' }
        $res.history = 'Restart asked of camera ' + $Ip + ' - refused (' + $refused.Trim() + ')'; return (& $done $false ('The camera refused the restart (' + $refused.Trim() + '). It was NOT restarted.'))
      }
      # no answer at all (code 0) or an accepted request: the reservation stays - the outcome is checked below and, if unknown,
      # the record still counts it, so no other window restarts this camera again within the hour
      $res.changed += 'restart asked'
      if ($unclear -or [int]$w.code -le 0) { Say ('The camera''s answer to the restart was ' + $(if ($unclear) { 'unclear (' + $unclear + ')' } else { 'lost (no answer)' }) + ', so the restart stays counted... waiting up to ' + $WaitSec + ' s: it must go offline and come back.') }
      else { Say ('Restart accepted by the camera... waiting up to ' + $WaitSec + ' s: it must go offline and come back.') }
      # 2.2.12 (Codex P1-10): an accepted request is not proof. "Restarted" needs the camera to go away and answer again.
      # 2.2.13 (Codex 2.2.12 #8): an HTTP error answer (500, 401, ...) means the camera is UP and answering - it is not "went down".
      # Only no answer at all (no connection / timeout, code 0) counts as offline. Where the camera gives its own uptime
      # (Hikvision /ISAPI/System/status deviceUpTime), the restart is confirmed ONLY by that uptime starting again from low;
      # a drop-out with the uptime still counting up is NOT a restart. Anything in between = NOT confirmed.
      $infoPath = $(if ($v -eq 'Uniview') { '/LAPI/V1.0/System/DeviceInfo' } else { '/ISAPI/System/deviceInfo' })
      $upBefore = $null; if ($v -eq 'Hikvision' -and $null -ne $upPre) { $upBefore = $upPre }
      $pollMs = $(if ($WaitSec -ge 30) { 3000 } else { 500 })
      $wentDown = $false; $back = $false; $upReset = $false; $httpErr = 0; $tSent = Get-Date; $end = $tSent.AddSeconds([math]::Max($WaitSec, 1))
      do {
        Start-Sleep -Milliseconds $pollMs
        if ($null -ne $upBefore) {
          $u = Hik-UpTime $t 5
          if ($u.code -eq 0) { $wentDown = $true }
          elseif ($u.code -ne 200) { $httpErr++ }
          elseif ($null -ne $u.up) { if ($u.up -lt $upBefore) { $upReset = $true; $back = $true } elseif ($wentDown) { $back = $true } }
          else { $httpErr++ }
        } else {
          $pr = Http -Ip $Ip -Path $infoPath -Credential $t.cred -Port $t.port -Timeout 5
          if ($pr.code -eq 0) { $wentDown = $true } elseif ($pr.code -ne 200) { $httpErr++ } elseif ($wentDown) { $back = $true }
        }
      } while (-not $back -and (Get-Date) -lt $end)
      if ($httpErr) { Log ('restart wait: ' + $httpErr + ' error answer(s) from the camera (it was answering, so not counted as offline)') }
      $confirmed = $(if ($null -ne $upBefore) { $upReset } else { $back })
      # 2.2.20 (Codex 2.2.19 R11, class B): "it came back" is only about THIS camera when the device answering afterwards is the same one
      # (serial / MAC as saved before the restart). A different or unreadable device = NOT confirmed; the restart stays counted.
      if ($confirmed -or $back) {
        $sameB = Test-NhSameDevice $t $id0
        if (-not $sameB.ok) {
          $res.history = 'Camera ' + $Ip + ' restart asked - NOT confirmed (the device answering afterwards is not proven to be the same camera: ' + $sameB.why + ')'
          return (& $done $false ('Something answered again at ' + $Ip + ', but it is NOT proven to be the same camera (' + $sameB.why + '), so the restart is NOT confirmed. It stays counted (1 per hour, 2 per day). Check which device has this address.'))
        }
      }
      if ($confirmed) { $res.changed = @('restarted'); $res.history = 'Camera ' + $Ip + ' restarted, back online' + $(if ($upReset) { ' (its uptime started again)' } else { '' }); return (& $done $true 'The camera restarted and is back. Run the Recording check to confirm it records again.') }
      if ($back -and $null -ne $upBefore) { $res.history = 'Camera ' + $Ip + ' restart asked - NOT confirmed (it dropped off but its uptime kept counting)'; return (& $done $false 'The camera dropped off the network and came back, but its own uptime kept counting, so it did NOT restart. It is NOT confirmed. Wait 5 minutes and check it; if it is still stuck, restart its switch port (PoE).') }
      if ($wentDown) { $res.history = 'Camera ' + $Ip + ' restarted, NOT back yet'; return (& $done $false ('The camera went offline for the restart but is not back after ' + $WaitSec + ' s. Restart its switch port (PoE) or go look at it.')) }
      if ($unclear -or [int]$w.code -le 0) {
        $res.history = 'Camera ' + $Ip + ' restart asked - NOT CONFIRMED (its answer was ' + $(if ($unclear) { 'unclear: ' + $unclear } else { 'lost' }) + '; it never went offline; the restart stays counted)'
        return (& $done $false ('NOT CONFIRMED: the camera''s answer to the restart was ' + $(if ($unclear) { 'unclear (' + $unclear + ')' } else { 'lost' }) + ' and it did not go offline in ' + $WaitSec + ' s, so it is NOT known whether it restarted. The restart stays counted (1 per hour, 2 per day). Wait 5 minutes and check it; if it is still stuck, restart its switch port (PoE).'))
      }
      $res.history = 'Camera ' + $Ip + ' restart asked - NOT confirmed (it never went offline' + $(if ($httpErr) { '; it answered with errors' } else { '' }) + ')'
      return (& $done $false ('The camera said OK but never went offline in ' + $WaitSec + ' s' + $(if ($httpErr) { ' (it answered with errors, which is not a restart)' } else { '' }) + ', so it is NOT confirmed that it restarted. Wait 5 minutes and check it; if it is still stuck, restart its switch port (PoE).'))
    }
    'readd' {
      if ($v -ne 'Hikvision') { return (& $done $false 'Putting a camera back on a channel is built for Hikvision NVRs only. Nothing changed.') }
      if ($Channel -lt 1 -or $CameraIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return (& $done $false 'Need the channel number and the camera IP. Nothing changed.') }
      # 2.2.19 (class A): which NVR this is (serial / MAC), read now and again right before the write
      $id0 = Get-NhDeviceId $t
      if (-not $id0.ok) { return (& $done $false ('The NVR at ' + $Ip + ' did not say which NVR it is (' + $id0.why + '), so no channel was changed. Nothing changed.')) }
      $xw = Get-FixExpectWhy $id0 $ExpectMac $Ip; if ($xw) { return (& $done $false ('NOT changed: ' + $xw + '. Nothing changed. Run the scan again, or check which device has this address.')) }   # 2.2.19 (class A)
      $all = Http -Ip $Ip -Path '/ISAPI/ContentMgmt/InputProxy/channels' -Credential $t.cred -Port $t.port
      if ($all.code -ne 200) { return (& $done $false ('Could not read the NVR channel list (answer ' + $all.code + '). Nothing changed.')) }
      $ax = Xml $all.body
      if (-not $ax -or -not $ax.DocumentElement -or $ax.DocumentElement.LocalName -notmatch '(?i)^InputProxyChannelList$') { return (& $done $false 'The NVR''s answer was not a channel list, so it could not be checked which camera uses the channel. Nothing changed. Run it again.') }
      $res.backup = Fix-Save $BackupDir 'nvr-channels-before.xml' $all.body
      if (-not $res.backup) { return (& $done $false (Fix-SaveFailed 'the NVR channel list')) }   # 2.2.18 (Codex F7)
      $used = $null; $listed = @(); $slot = $null
      $slotXml = Get-NhChannelXml $ax $Channel   # 2.2.19 (F04): the exact channel entry the plan is based on
      foreach ($c in (XFind $ax 'InputProxyChannel')) {
        $cidS = XText $c 'id'; $cid = 0; [void][int]::TryParse($cidS, [ref]$cid)
        # 2.2.15 (Codex 2.2.14 R4): keep "this channel is set up" AND how it is addressed. Only a plain IP address can be checked
        # (status read below). A hostname / domain address, or no readable address at all, is NOT a free slot.
        $aft = XText $c 'addressingFormatType'; $cip = XText $c 'ipAddress'; $chost = XText $c 'hostName'
        $isIp = (($aft -eq '' -or $aft -match '^(?i)ip(address)?$') -and $cip -match '^\d{1,3}(\.\d{1,3}){3}$')
        $addr = $(if ($chost) { $chost } elseif ($cip) { $cip } else { '' })
        $one = [pscustomobject]@{ ch = $cid; ip = $(if ($isIp) { $cip } else { '' }); isIp = $isIp; addr = $addr; type = $aft }
        $listed += $one
        if ($cidS -eq [string]$Channel) { $slot = $one; if ($isIp) { $used = $cip } }
      }
      # the "already on another channel" check uses the list just read (2.2.13 re-read it; a failed 2nd read hid the duplicate)
      if (@($listed | Where-Object { $_.ip -eq $CameraIp -and $_.ch -ne $Channel }).Count) { return (& $done $false ($CameraIp + ' is already on another channel. Nothing changed.')) }
      if ($slot -and -not $slot.isIp) {
        $how = $(if ($slot.addr -and $slot.addr -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { 'by name (' + $slot.addr + ')' } elseif ($slot.type) { 'with address type "' + $slot.type + '"' + $(if ($slot.addr) { ' (' + $slot.addr + ')' } else { '' }) } else { 'with no address the tool can read' })
        $res.history = 'Re-add camera ' + $CameraIp + ' to channel ' + $Channel + ' - NOT done (channel is set up ' + $how + ', not checked)'
        return (& $done $false ('Channel ' + $Channel + ' is already set up ' + $how + '. The tool can only check cameras added by IP address, so it is NOT known whether that camera is working. Nothing changed (a working camera could lose its recording). Check channel ' + $Channel + ' in the NVR by hand, or pick another channel.'))
      }
      if ($used -and $used -ne $CameraIp) {
        # 2.2.14 (Codex 2.2.13 F3): a channel used by a DIFFERENT camera is replaced only when that camera is POSITIVELY offline:
        # a real status list that names this channel with online=false, and the channel still shows the same camera. An
        # unreadable status (or a channel missing from it) is not "offline" - refuse, as FixSiteDevices already does.
        $pre = Hik-ReadChannel $t $Channel
        if (-not $pre.ok) { return (& $done $false ('Channel ' + $Channel + ' is in use by ' + $used + ', and ' + $pre.why + ', so it is NOT known that ' + $used + ' is offline. Nothing changed (a working camera could lose its recording). Run it again.')) }
        if (-not $pre.found -or $pre.ip -ne $used) { return (& $done $false ('Channel ' + $Channel + ' changed while it was being checked (now ' + $(if ($pre.found -and $pre.ip) { $pre.ip } else { 'nothing' }) + '). Nothing changed. Run it again.')) }
        if (-not $pre.statusFound) { return (& $done $false ('Channel ' + $Channel + ' is in use by ' + $used + ' and the NVR does not say whether that camera is online. Nothing changed (a working camera could lose its recording).')) }
        if ($pre.online) { return (& $done $false ('Channel ' + $Channel + ' is in use by ' + $used + ' and that camera is online. Nothing changed.')) }
        Log ('readd: channel ' + $Channel + ' holds ' + $used + ', which the NVR reports offline - it may be replaced')
      }
      if (-not (& $ask @('Put camera ' + $CameraIp + ' on channel ' + $Channel + ' of the NVR ' + $Ip + $(if ($used) { ' (replacing ' + $used + ', which the NVR reports offline)' } else { '' }) + ' (login admin + the camera password you typed; it is not saved).', 'Backup of the channel list saved: ' + $res.backup))) { return (& $done $true 'Not confirmed - nothing changed.') }
      # 2.2.19 (Codex 2.2.18 F04, class B): everything above was read BEFORE the YES. Read it all again now, right before the write:
      # the same NVR, the channel entry exactly as it was shown (else: it changed while waiting - stop), the camera still not on
      # another channel, and a replaced camera still positively offline. The backup is taken again from THIS read, so it holds the
      # exact state that is about to be replaced.
      $same = Test-NhSameDevice $t $id0
      if (-not $same.ok) { $res.history = 'Re-add camera ' + $CameraIp + ' to channel ' + $Channel + ' - NOT done (' + $same.why + ')'; return (& $done $false ('Nothing changed: ' + $same.why + '. Check the NVR address and run it again.')) }
      $all2 = Http -Ip $Ip -Path '/ISAPI/ContentMgmt/InputProxy/channels' -Credential $t.cred -Port $t.port
      $ax2 = $(if ($all2.code -eq 200) { Xml $all2.body } else { $null })
      if (-not $ax2 -or -not $ax2.DocumentElement -or $ax2.DocumentElement.LocalName -notmatch '(?i)^InputProxyChannelList$') { $res.history = 'Re-add camera ' + $CameraIp + ' to channel ' + $Channel + ' - NOT done (channel list not readable after YES)'; return (& $done $false ('After you typed YES the NVR''s channel list could not be read again (answer ' + $all2.code + '), so it is NOT known that channel ' + $Channel + ' is still as shown. Nothing changed. Run it again.')) }
      $slotXml2 = Get-NhChannelXml $ax2 $Channel
      if ($slotXml2 -cne $slotXml) {
        $nowIp = ''; foreach ($c2 in (XFind $ax2 'InputProxyChannel')) { if ([string](XText $c2 'id') -eq [string]$Channel) { $nowIp = XText $c2 'ipAddress' } }
        $res.history = 'Re-add camera ' + $CameraIp + ' to channel ' + $Channel + ' - NOT done (channel changed while waiting for YES)'
        return (& $done $false ('Channel ' + $Channel + ' changed while waiting for your YES (it now shows ' + $(if ($nowIp) { $nowIp } elseif ($slotXml2) { 'a different setting' } else { 'nothing' }) + '). Nothing changed - a working camera could lose its recording. Run it again.'))
      }
      foreach ($c2 in (XFind $ax2 'InputProxyChannel')) { $cid2 = XText $c2 'id'; if ((XText $c2 'ipAddress') -eq $CameraIp -and $cid2 -ne [string]$Channel) { return (& $done $false ($CameraIp + ' is now on channel ' + $cid2 + ' (it changed while waiting for your YES). Nothing changed.')) } }
      if ($used -and $used -ne $CameraIp) {
        $pre2 = Hik-ReadChannel $t $Channel
        if (-not $pre2.ok -or -not $pre2.found -or $pre2.ip -ne $used -or -not $pre2.statusFound -or $pre2.online) { $res.history = 'Re-add camera ' + $CameraIp + ' to channel ' + $Channel + ' - NOT done (' + $used + ' not confirmed offline after YES)'; return (& $done $false ('After your YES, ' + $used + ' on channel ' + $Channel + ' is ' + $(if (-not $pre2.ok) { 'not readable (' + $pre2.why + ')' } elseif ($pre2.online) { 'ONLINE again' } else { 'not confirmed offline' }) + '. Nothing changed - a working camera could lose its recording.')) }
      }
      $bk2 = Fix-Save $BackupDir 'nvr-channels-at-write.xml' $all2.body
      if (-not $bk2) { return (& $done $false (Fix-SaveFailed 'the NVR channel list (read again after your YES)')) }
      $res.backup = $bk2
      $res.ran = $true
      $xml = '<?xml version="1.0" encoding="UTF-8"?><InputProxyChannel version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema"><id>' + $Channel + '</id><sourceInputPortDescriptor><proxyProtocol>HIKVISION</proxyProtocol><addressingFormatType>ipaddress</addressingFormatType><ipAddress>' + $CameraIp + '</ipAddress><managePortNo>8000</managePortNo><srcInputPort>1</srcInputPort><userName>' + (Fix-Xml $NewCredential.UserName) + '</userName><password>' + (Fix-Xml (Plain $NewCredential)) + '</password><streamType>auto</streamType></sourceInputPortDescriptor></InputProxyChannel>'
      $w = Http -Ip $Ip -Method 'PUT' -Path ('/ISAPI/ContentMgmt/InputProxy/channels/' + $Channel) -Body $xml -Credential $t.cred -Port $t.port -NoLogBody
      $xml = $null
      # 2.2.20 (class C/F twin of Codex 2.2.19 R10): only an EXPLICIT no is "refused". No answer, a 5xx or a 200 that is not a
      # ResponseStatus is UNKNOWN - the NVR may have taken it - so the channel is read back below (2.2.19 said "refused" for those).
      $wa = Get-HikWriteAnswer $w
      if ($wa -eq 'refused') { $res.history = 'Re-add camera ' + $CameraIp + ' to channel ' + $Channel + ' - refused by the NVR'; return (& $done $false ('The NVR refused it (answer ' + $w.code + $(if ($w.code -eq 200) { ' ' + (XText (Xml $w.body) 'statusCode') + ' ' + (XText (Xml $w.body) 'statusString') } else { '' }) + ').')) }
      $res.changed += $(if ($wa -eq 'ok') { 'channel ' + $Channel + ' = ' + $CameraIp } else { 'channel ' + $Channel + ' = ' + $CameraIp + ' (answer unclear)' })
      # 2.2.13 (Codex 2.2.12 #6): "online" alone is not proof: the channel must be READ BACK (a real list) with the camera
      # address we asked for. An NVR that says OK but keeps the old camera (which then comes back online) is NOT done.
      # 2.2.20 (Codex 2.2.19 R21 twin, class B): the read that certifies it must come from the SAME NVR - checked before and after it
      $sameV = Test-NhSameDevice $t $id0
      $rb = $(if ($sameV.ok) { Hik-ReadChannel $t $Channel } else { @{ ok = $false; found = $false; ip = ''; online = $null; statusFound = $false; why = ('the NVR answering is not the same one (' + $sameV.why + ')') } })
      if ($rb.ok) { $sameV2 = Test-NhSameDevice $t $id0; if (-not $sameV2.ok) { $rb = @{ ok = $false; found = $false; ip = ''; online = $null; statusFound = $false; why = ('the NVR answering is not the same one after the read-back (' + $sameV2.why + ')') } } }
      if (-not $rb.ok) {
        $res.history = 'Re-add camera ' + $CameraIp + ' to channel ' + $Channel + ' - sent, NOT confirmed (' + $rb.why + ')'
        return (& $done $false ('Sent to the NVR, but ' + $rb.why + ', so it is NOT confirmed that ' + $CameraIp + ' is on channel ' + $Channel + '. Run it again or check the channel in the NVR.'))
      }
      if (-not $rb.found -or $rb.ip -ne $CameraIp) {
        $res.history = 'Re-add camera ' + $CameraIp + ' to channel ' + $Channel + ' - NOT done (channel shows ' + $(if ($rb.found) { $(if ($rb.ip) { $rb.ip } else { 'no address' }) } else { 'nothing' }) + ')'
        return (& $done $false ('The NVR ' + $(if ($wa -eq 'ok') { 'said OK' } else { 'answer was unclear (' + $w.code + ')' }) + ', but channel ' + $Channel + ' still shows ' + $(if ($rb.found) { $(if ($rb.ip) { $rb.ip } else { 'no camera address' }) } else { 'no camera' }) + ', not ' + $CameraIp + '. NOT done - check the channel in the NVR.'))
      }
      $ok = [bool]$rb.online
      $res.history = 'Camera ' + $CameraIp + ' put back on NVR channel ' + $Channel + $(if ($ok) { ', online' } else { ', not online yet' })
      return (& $done $ok $(if ($ok) { 'Camera ' + $CameraIp + ' is on channel ' + $Channel + ' (read back from the NVR) and online.' } else { 'Added (channel ' + $Channel + ' now shows ' + $CameraIp + '), but the NVR does not show it online yet (wrong camera password?). Check the channel in the NVR.' }))
    }
    'firmware' {
      if ($v -ne 'Hikvision') { return (& $done $false 'Firmware updates are built for Hikvision only. Nothing changed.') }
      if (-not $File -or -not (Test-Path -LiteralPath $File)) { return (& $done $false 'Pick the firmware file from the maker''s website first. Nothing changed.') }
      if ($Sha256 -notmatch '^[0-9a-fA-F]{64}$') { return (& $done $false 'Type the file''s SHA-256 from the maker''s download page (64 characters). Nothing changed.') }
      $hash = (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash
      if ($hash -ne $Sha256.ToUpper()) { return (& $done $false 'The file does not match the SHA-256 you typed - wrong or damaged file. Nothing changed.') }
      $di = Hik-DeviceInfo $t; if ($di.login -ne 'ok') { return (& $done $false 'Could not read the device (login?). Nothing changed.') }
      # 2.2.18 (Codex F4 twin) + 2.2.19 (Codex 2.2.18 F07): without the firmware VERSION it has NOW (the version field itself - a
      # release date alone is not a version), a later read-back cannot prove the update ran - refuse first
      $fw0 = ([string]$di.version).Trim()
      if (-not $fw0) { return (& $done $false ('The device did not say which firmware version it has now' + $(if ($di.released) { ' (only its release date, ' + $di.released + ')' } else { '' }) + ', so the update could not be checked afterwards. Nothing changed. Look at its version in its web page (Maintenance) first.')) }
      $id0 = Get-NhDeviceId $t
      if (-not $id0.ok) { return (& $done $false ('The device did not say which device it is (' + $id0.why + '), so it was NOT updated. Nothing changed.')) }
      $xw = Get-FixExpectWhy $id0 $ExpectMac $Ip; if ($xw) { return (& $done $false ('NOT changed: ' + $xw + '. Nothing changed. Run the scan again, or check which device has this address.')) }   # 2.2.19 (class A)
      # 2.2.3 (Codex #21): the export is the device's own binary file: saved byte for byte as .bin (2.2.2 turned it into text)
      if (-not $BackupDir) { $BackupDir = Join-Path $env:TEMP 'WireIt-backup' }; New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
      $cfgFile = Join-Path $BackupDir ('config-' + ($di.serial -replace '[^A-Za-z0-9_-]', '_') + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bin')
      $cfg = Http -Ip $Ip -Path '/ISAPI/System/configurationData' -Credential $t.cred -Port $t.port -Timeout 30 -OutFile $cfgFile
      if ($cfg.code -ne 200) { return (& $done $false 'Could not export the settings first, so no update. Nothing changed.') }
      $bw = Test-NhBackupFile $cfgFile; if ($bw) { Log ('backup FAILED: ' + $bw); Remove-Item -LiteralPath $cfgFile -Force -ErrorAction SilentlyContinue; return (& $done $false ('The settings export FAILED (' + $bw + '), so no update. Nothing changed.')) }   # 2.2.4
      $res.backup = $cfgFile
      if (-not (& $ask @('Update ' + $di.model + ' at ' + $Ip + ' from ' + $di.firmware + ' with ' + (Split-Path -Leaf $File) + ' (SHA-256 matches). It reboots; do not unplug it for 10 minutes.', 'Settings exported first: ' + $res.backup, 'To go back: upload the old firmware file the same way, then import the exported settings in the camera''s web page (Maintenance).'))) { return (& $done $true 'Not confirmed - nothing changed.') }
      # 2.2.19 (class B): after YES - the same device, still on the version the plan was made for
      $same = Test-NhSameDevice $t $id0
      if (-not $same.ok) { return (& $done $false ('Not updated: ' + $same.why + '. Nothing changed.')) }
      $di2 = Hik-DeviceInfo $t
      if ($di2.login -ne 'ok' -or ([string]$di2.version).Trim() -cne $fw0) { return (& $done $false ('Not updated: after your YES the device reports ' + $(if ($di2.login -ne 'ok') { 'nothing (it could not be read)' } elseif ($di2.version) { 'version ' + $di2.version } else { 'no version' }) + ', not ' + $fw0 + ' as in the plan. Nothing changed. Run it again.')) }
      # 2.2.20 (Codex 2.2.19 R05, class D): the bytes that are sent are read ONCE, here, after the YES, and THOSE bytes are hashed: only
      # bytes whose SHA-256 is the one approved are sent. A file replaced / edited / still downloading while the plan was shown is
      # refused and nothing is sent (2.2.19 hashed the file before YES and read it again for the upload without comparing).
      $fwBytes = $null
      try { $fwBytes = [IO.File]::ReadAllBytes($File) } catch { $res.history = 'Firmware update of ' + $Ip + ' - NOT sent (the file could not be read after YES)'; return (& $done $false ('Not updated: the firmware file could not be read again after your YES (' + $_.Exception.Message + '). Nothing was sent.')) }
      $shaF = [Security.Cryptography.SHA256]::Create()
      try { $sentHash = ([BitConverter]::ToString($shaF.ComputeHash([byte[]]$fwBytes))).Replace('-', '') } finally { $shaF.Dispose() }
      if (-not $fwBytes -or $fwBytes.Length -le 0 -or $sentHash -ne $Sha256.ToUpper()) {
        $fwBytes = $null
        $res.history = 'Firmware update of ' + $Ip + ' - NOT sent (the file changed after YES: its SHA-256 no longer matches)'
        return (& $done $false 'Not updated: the firmware file CHANGED after you typed YES (its SHA-256 no longer matches the one you approved). Nothing was sent. Download it again from the maker''s website and start over.')
      }
      $res.ran = $true
      $w = Http -Ip $Ip -Method 'PUT' -Path '/ISAPI/System/updateFirmware' -BodyBytes $fwBytes -ContentType 'application/octet-stream' -Credential $t.cred -Port $t.port -Timeout 600
      # 2.2.15 (Codex 2.2.14 R10): NO answer (connection dropped / timed out, code 0) is not a refusal: the device may have taken
      # the file and be installing it. Read the device back; unless it already shows a new version it is SENT, NOT confirmed.
      $fwBytes = $null
      # 2.2.20 (class C/F): a 5xx answer is not a refusal either - it is handled like a lost answer (read back, NOT confirmed)
      if ([int]$w.code -le 0 -or [int]$w.code -ge 500) {
        $res.changed += 'firmware sent (answer lost)'
        $lost = Hik-DeviceInfo $t
        # 2.2.19 (Codex 2.2.18 F07): the VERSION field, non-empty and different, on the SAME device - a date alone proves nothing
        $lostV = $(if ($lost.login -eq 'ok') { ([string]$lost.version).Trim() } else { '' })
        # 2.2.20 (Codex 2.2.19 R11, class B): the SAME device = every identity value saved before (MAC and / or serial) read again here
        $lostId = Test-NhIdMatch $id0 $lost; $lostSame = [bool]$lostId.ok
        if ($lostV -and $lostV -ne $fw0 -and $lostSame) {
          $res.changed = @($fw0 + ' -> ' + $lostV)
          $res.history = 'Firmware ' + $Ip + ' ' + $fw0 + ' -> ' + $lostV + ' (its answer was lost; the new version was read back)'
          return (& $done $true ('Updated: ' + $fw0 + ' -> ' + $lostV + '. The device''s answer was lost, but it now reports the new version (read back).'))
        }
        $seen = $(if ($lost.login -eq 'ok' -and -not $lostSame) { 'the device answering now is NOT proven to be the same one: ' + $lostId.why } elseif ($lost.login -eq 'ok') { 'right now it reports ' + $(if ($lostV) { 'version ' + $lostV } else { 'no version' }) + ', which is normal while it installs' } else { 'it could not be read back (it may be rebooting)' })
        $res.history = 'Firmware update of ' + $Ip + ' sent - NOT confirmed (the answer was lost; ' + $(if ($lost.login -eq 'ok') { 'read back: ' + $(if ($lostV) { $lostV } else { 'no version' }) } else { 'read-back failed' }) + ')'
        return (& $done $false ('Sent, but the device''s answer was lost, so it is NOT confirmed whether the update ran (' + $seen + '). Do NOT send it again yet: wait 10 minutes, then run the Firmware check. Only if that still shows ' + $fw0 + ' try the update again. Settings export kept: ' + $res.backup))
      }
      if (-not (Hik-Ok $w)) { $res.history = 'Firmware update of ' + $Ip + ' refused (' + $w.code + ')'; return (& $done $false ('The device refused the file (answer ' + $w.code + '), so the update did not start. Settings export kept: ' + $res.backup)) }
      $after = Hik-DeviceInfo $t
      # 2.2.18 (Codex F4): like the lost-answer branch, "updated" needs a NON-EMPTY version read back that differs from the
      # original. A read-back with no version (or a failed one) is sent, NOT confirmed - and its history line says so.
      # 2.2.19 (Codex 2.2.18 F07): the VERSION field alone (not version + release date), non-empty and different from the version
      # before, on the same device (same serial). 2.2.18 compared "version + date", so an empty version with the old date passed.
      $newFw = $(if ($after.login -eq 'ok') { ([string]$after.version).Trim() } else { '' })
      # 2.2.20 (Codex 2.2.19 R11, class B): certified only on the SAME device: MAC when one was saved, serial when one was saved -
      # 2.2.19 compared the serial only and accepted ANY device when no serial had been saved (MAC-only identity)
      $afterId = Test-NhIdMatch $id0 $after; $afterSame = [bool]$afterId.ok
      $ok = [bool]($after.login -eq 'ok' -and $newFw -and $newFw -ne $fw0 -and $afterSame)
      if ($ok) {
        $res.changed += ($fw0 + ' -> ' + $newFw)
        $res.history = 'Firmware ' + $Ip + ' ' + $fw0 + ' -> ' + $newFw + ' (new version read back)'
        return (& $done $true ('Updated: ' + $fw0 + ' -> ' + $newFw + '.'))
      }
      $seenFw = $(if ($after.login -ne 'ok') { 'read-back failed' } elseif (-not $afterSame) { 'read back from a device that is NOT proven to be the same one: ' + $afterId.why } elseif (-not $newFw) { 'read back: no version' + $(if ($after.released) { ' (only the release date ' + $after.released + ')' } else { '' }) } else { 'read back: ' + $newFw + ', unchanged' })
      $res.changed += 'firmware sent (not confirmed)'
      $res.history = 'Firmware update of ' + $Ip + ' sent - NOT confirmed (' + $seenFw + ')'
      return (& $done $false ('Sent, but the new version is NOT confirmed (' + $seenFw + '). Wait 10 minutes and run the Firmware check. Settings export kept: ' + $res.backup))
    }
    'password' {
      if ($v -ne 'Hikvision') { return (& $done $false 'Setting the site password is built for Hikvision only. Nothing changed.') }
      $di = Hik-DeviceInfo $t; if ($di.login -ne 'ok') { return (& $done $false 'Could not log in with the current password (one try). Nothing changed.') }
      $id0 = Get-NhDeviceId $t
      if (-not $id0.ok) { return (& $done $false ('The device did not say which device it is (' + $id0.why + '), so its password was NOT changed. Nothing changed.')) }
      $xw = Get-FixExpectWhy $id0 $ExpectMac $Ip; if ($xw) { return (& $done $false ('NOT changed: ' + $xw + '. Nothing changed. Run the scan again, or check which device has this address.')) }   # 2.2.19 (class A)
      if (-not (& $ask @('Set the site password on ' + $di.model + ' at ' + $Ip + $(if ($id0.serial) { ' (serial ' + $id0.serial + ')' } else { '' }) + ' (user admin). It is not saved anywhere.', 'Write the new password into the site''s password manager now.'))) { return (& $done $true 'Not confirmed - nothing changed.') }
      $same = Test-NhSameDevice $t $id0   # 2.2.19 (classes A + B): the same device, read again after YES
      if (-not $same.ok) { return (& $done $false ('Password NOT changed: ' + $same.why + '. Nothing changed.')) }
      $res.ran = $true
      $xml = '<?xml version="1.0" encoding="UTF-8"?><User version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema"><id>1</id><userName>admin</userName><password>' + (Fix-Xml (Plain $NewCredential)) + '</password><loginPassword>' + (Fix-Xml (Plain $t.cred)) + '</loginPassword></User>'
      $w = Http -Ip $Ip -Method 'PUT' -Path '/ISAPI/Security/users/1' -Body $xml -Credential $t.cred -Port $t.port -NoLogBody
      $xml = $null
      if (-not (Hik-Ok $w)) {
        # 2.2.14 (Codex 2.2.13 F7): a lost / non-OK answer is NOT proof of a refusal - the device may have applied the new password
        # and dropped the connection. Reconcile like FixSite's Resolve-FsPwChange: try the NEW password, then the old one (one try
        # each). Only a working old password with a failing new one is "refused"; nothing working = unknown / maybe changed.
        # 2.2.20 (Codex 2.2.19 R12, class C): a password "works" only when the device answers with ITS OWN DeviceInfo document (the
        # same device: MAC / serial as saved) - an HTTP 200 login / error / HTML page proves nothing, in this branch and the one below
        $nw = Test-NhHikLoginAs $t $NewCredential $id0
        if ($nw.state -eq 'ok') {
          $res.changed += 'password'; $res.history = 'Site password set on ' + $Ip + ' (its answer was ' + $w.code + ', but the new one works)'
          return (& $done $true ('The device''s answer was not OK (answer ' + $w.code + '), but the NEW password logs in (its own device information read back), so the password IS changed. Update it in DW/NVR if they log in to this device.'))
        }
        $od = Test-NhHikLoginAs $t $t.cred $id0
        if ($od.state -eq 'ok') { $res.history = 'Site password on ' + $Ip + ' - refused (old one checked: still works)'; return (& $done $false ('The device refused the new password (answer ' + $w.code + '). The old one still works (checked).')) }
        $res.changed += 'password (unknown)'
        $res.history = 'Site password on ' + $Ip + ' - UNKNOWN, maybe changed (answer ' + $w.code + '; neither password proven to log in: new ' + $nw.why + ' / old ' + $od.why + ')'
        return (& $done $false ('UNKNOWN - the password MAY have changed: the device''s answer was ' + $w.code + ' and now neither the new nor the old password is proven to log in (new: ' + $(if ($nw.why) { $nw.why } else { 'answer ' + $nw.code }) + '; old: ' + $(if ($od.why) { $od.why } else { 'answer ' + $od.code }) + '). Wait 2 minutes and try both in its web page. If the new one works, update it in every NVR/DW that records this device.'))
      }
      $chk = Test-NhHikLoginAs $t $NewCredential $id0
      $ok = ($chk.state -eq 'ok'); $res.changed += 'password'
      $res.history = 'Site password set on ' + $Ip + $(if ($ok) { ' (new one works)' } else { ' (new one NOT confirmed: ' + $chk.why + ')' })
      return (& $done $ok $(if ($ok) { 'The new password works (the device''s own information read back with it). Update it in DW/NVR if they log in to this device.' } elseif ($chk.state -eq 'refused') { 'Changed, but the new password did not log in yet. Try it in the web page.' } else { 'Sent, but it is NOT confirmed that the new password works (' + $chk.why + '). Try it in the web page before you rely on it.' }))
    }
    'dwpassword' {
      if ($v -ne 'DW') { return (& $done $false 'This fix is for a DW server. Nothing changed.') }
      if (-not (Dw-Login $t)) { return (& $done $false 'The DW server refused the login. Nothing changed.') }
      $rd = Dw-ReadDevices $t
      if (-not $rd.ok) { return (& $done $false ('Could not read DW''s camera list (' + $rd.why + '). Nothing changed. Run it again.')) }
      $devs = @($rd.devs); $d = $devs | Where-Object { $_.ip -eq $CameraIp } | Select-Object -First 1
      if (-not $d) { return (& $done $false ($CameraIp + ' is not in DW''s camera list. Nothing changed.')) }
      $res.backup = Fix-Save $BackupDir 'dw-cameras-before.json' ($devs | ConvertTo-Json -Depth 4)
      if (-not $res.backup) { return (& $done $false (Fix-SaveFailed 'DW''s camera list')) }   # 2.2.18 (Codex F7)
      if (-not (& $ask @('Give DW the camera password for ' + $d.name + ' (' + $CameraIp + '), so DW stops logging in with the wrong one.', 'If the camera is LOCKED, wait until it unlocks first (Camera doctor shows the minutes).'))) { return (& $done $true 'Not confirmed - nothing changed.') }
      # 2.2.19 (classes A + B): after YES - the same camera (same DW id, same address, same MAC when DW gave one) still in the list
      $rd2 = Dw-ReadDevices $t
      $d2 = $(if ($rd2.ok) { @($rd2.devs | Where-Object { $_.id -eq $d.id }) | Select-Object -First 1 } else { $null })
      if (-not $d2 -or $d2.ip -ne $CameraIp -or ($d.mac -and $d2.mac -ne $d.mac)) { return (& $done $false ('After your YES, ' + $CameraIp + ' is ' + $(if (-not $rd2.ok) { 'not readable in DW (' + $rd2.why + ')' } else { 'no longer the same camera in DW''s list' }) + '. Nothing changed.')) }
      $res.ran = $true
      $w = Dw-Send $t 'PATCH' ('/rest/v3/devices/' + [uri]::EscapeDataString($d.id)) @{ credentials = @{ user = $NewCredential.UserName; password = (Plain $NewCredential) } } -Secret
      if ($w.code -ne 200) { $res.history = 'DW password for ' + $d.name + ' - refused (' + $w.code + ')'; return (& $done $false ('DW refused it (answer ' + $w.code + ').')) }
      $res.changed += $d.name
      $st = ''; $end = (Get-Date).AddSeconds([math]::Min($WaitSec, 60))
      do { $x = @(Dw-Devices $t) | Where-Object { $_.id -eq $d.id -and $_.ip -eq $CameraIp -and (-not $d.mac -or $_.mac -eq $d.mac) } | Select-Object -First 1; $st = [string]$x.status; if ($st -eq 'Unauthorized' -and $WaitSec -gt 0) { Start-Sleep -Seconds 10 } } while ($st -eq 'Unauthorized' -and (Get-Date) -lt $end)
      # 2.2.18 (sweep, class B): only Online / Recording shows DW now logs in; Offline / empty / anything else is NOT confirmed
      $ok = ($st -in @('Online', 'Recording'))
      $stW = $(if ($st) { $st } else { 'nothing (its camera list could not be read)' })
      $res.history = 'DW password updated for ' + $d.name + ' (' + $CameraIp + '): DW now says ' + $stW + $(if ($ok) { '' } else { ' - NOT confirmed' })
      return (& $done $ok $(if ($ok) { 'DW now says ' + $st + ' for ' + $d.name + '.' } elseif ($st -eq 'Unauthorized') { 'DW still says Unauthorized. The typed password may be wrong, or the camera is still locked.' } else { 'DW took the password, but it now says ' + $stW + ' for ' + $d.name + ', so it is NOT confirmed that DW logs in. Look at the camera in the DW client.' }))
    }
  }
}
