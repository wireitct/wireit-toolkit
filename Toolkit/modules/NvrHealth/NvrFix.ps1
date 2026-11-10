# NvrFix.ps1 - WireIt Toolkit Release C fix buttons (Nov 3 2026). Dot-sourced by NvrHealth.psm1 (uses its Http/Hik/Dw helpers).
# UNTESTED ON REAL GEAR: every write below was checked against the mock devices only.
# Rules for every fix: it runs only for a check that failed; it shows the plan, then needs YES typed in capital letters;
# it saves a backup/export first; it never stores or logs a password; it tries a login at most once; nothing is retried.
$script:FixLimitPerHour = 1; $script:FixLimitPerDay = 2

function Fix-Save([string]$dir, [string]$name, [string]$text) {
  if (-not $dir) { return '' }
  New-Item -ItemType Directory -Force -Path $dir -WhatIf:$false | Out-Null
  $p = Join-Path $dir $name; Set-Content -LiteralPath $p -Value (Redact $text) -Encoding UTF8 -WhatIf:$false -Confirm:$false; return $p
}
function Fix-LimitOk([string]$stateFile, [string]$key, [datetime]$now) {
  # restart limits per camera: 1 per hour, 2 per day (then one alert line, no more restarts)
  if (-not $stateFile -or -not (Test-Path $stateFile)) { return @{ ok = $true; why = '' } }
  $all = $null; try { $all = Get-Content $stateFile -Raw | ConvertFrom-Json } catch {}
  $times = @(); if ($all -and $all.PSObject.Properties[$key]) { $times = @($all.$key | ForEach-Object { [datetime]$_ }) }
  if (@($times | Where-Object { ($now - $_).TotalHours -lt 1 }).Count -ge $script:FixLimitPerHour) { return @{ ok = $false; why = 'it was already restarted in the last hour' } }
  if (@($times | Where-Object { ($now - $_).TotalHours -lt 24 }).Count -ge $script:FixLimitPerDay) { return @{ ok = $false; why = 'it was already restarted twice today - something else is wrong, go look at it' } }
  return @{ ok = $true; why = '' }
}
function Fix-LimitAdd([string]$stateFile, [string]$key, [datetime]$now) {
  if (-not $stateFile) { return }
  $h = @{}; if (Test-Path $stateFile) { try { $o = Get-Content $stateFile -Raw | ConvertFrom-Json; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = @($p.Value) } } catch {} }
  $keep = @(@($h[$key]) | Where-Object { $_ -and ($now - [datetime]$_).TotalDays -lt 2 }); $h[$key] = @($keep + $now.ToString('s'))
  ($h | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $stateFile -Encoding UTF8 -WhatIf:$false -Confirm:$false
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
        [string]$File = '', [string]$Sha256 = '', [string]$BackupDir = '', [string]$StateFile = '', [scriptblock]$Confirm = $null, [int]$WaitSec = 180)
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
        if (-not (& $ask @('Turn recording back ON for: ' + (@($off | ForEach-Object { & $offWhy $_ }) -join ', ') + ' on ' + $Ip + '. A switched-off camera keeps its schedule as it is; a schedule with no recording time gets every one of its time slots set to record.', 'Backup of the recording settings saved: ' + $res.backup))) { return (& $done $true 'Not confirmed - nothing changed.') }
        $res.ran = $true
        foreach ($o in $off) {
          $one = Http -Ip $Ip -Path ('/ISAPI/ContentMgmt/record/tracks/' + $o.id) -Credential $t.cred -Port $t.port
          # 2.2.13: never PUT back an answer that is not this camera's own track (an error page / another track)
          # 2.2.15: and only when it still shows the same off state that was read in the list (else: not written, reported)
          $oneMap = $(if ($one.code -eq 200) { Hik-ParseTracks ([string]$one.body) } else { $null })
          $cur = $(if ($oneMap -and $oneMap.ContainsKey($o.id)) { $oneMap[$o.id] } else { $null })
          if (-not $cur -or $cur.enabled -ne $o.enabled -or $cur.hasSchedule -ne $o.hasSchedule) { Log ('track ' + $o.id + ': could not read it, or it changed (answer ' + $one.code + ') - not written'); continue }
          $xml = [string]$one.body
          if ($o.enabled -eq $false) { $xml = $xml -replace '<Enable>\s*(?i:false)\s*</Enable>', '<Enable>true</Enable>' }
          if ($o.hasSchedule -eq $false) { $xml = $xml -replace '<Record>\s*(?i:false)\s*</Record>', '<Record>true</Record>' }
          $w = Http -Ip $Ip -Method 'PUT' -Path ('/ISAPI/ContentMgmt/record/tracks/' + $o.id) -Body $xml -Credential $t.cred -Port $t.port
          if (Hik-Ok $w) { $res.changed += ('camera ' + [math]::Floor($o.id / 100)) }
        }
        $ra = Hik-ReadTracks $t
        if (-not $ra.ok) {
          $res.history = 'Recording turn-on sent for: ' + ($res.changed -join ', ') + ' (' + $Ip + ') - NOT confirmed (read-back failed)'
          return (& $done $false ('Sent to the recorder, but its recording settings could not be read back (' + $ra.why + '), so it is NOT confirmed. Run the Recording check again.'))
        }
        $afterTracks = $ra.map
        # 2.2.15: "on again" = Enable true AND a schedule with recording time (an explicit false schedule is still off)
        $still = @($off | Where-Object { -not $afterTracks.ContainsKey($_.id) -or $afterTracks[$_.id].enabled -ne $true -or $afterTracks[$_.id].hasSchedule -eq $false })
        $unknownAfter = @($afterTracks.Values | Where-Object { $null -eq $_.enabled -or ($_.enabled -eq $true -and $null -eq $_.hasSchedule) })
        $unkNote = $(if ($unknownAfter.Count) { ' Recording could NOT be checked for camera(s) ' + (& $unkWords $unknownAfter) + ' (no clear Enable / schedule).' } else { '' })
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
        if (-not (& $ask @('Turn recording back ON in DW for: ' + (($off | ForEach-Object { $_.name + ' (' + $_.ip + ')' }) -join ', ') + '.', 'Backup of the camera list saved: ' + $res.backup))) { return (& $done $true 'Not confirmed - nothing changed.') }
        $res.ran = $true
        foreach ($o in $off) { $w = Dw-Send $t 'PATCH' ('/rest/v3/devices/' + [uri]::EscapeDataString($o.id)) @{ schedule = @{ isEnabled = $true } }; if ($w.code -eq 200) { $res.changed += $o.name } }
        $ra = Dw-ReadDevices $t
        if (-not $ra.ok) {
          $res.history = 'Recording turn-on sent in DW for: ' + ($res.changed -join ', ') + ' (' + $Ip + ') - NOT confirmed (read-back failed)'
          return (& $done $false ('Sent to DW, but its camera list could not be read back (' + $ra.why + '), so it is NOT confirmed. Run the Recording check again.'))
        }
        $afterDevices = @($ra.devs)
        $still = @($off | Where-Object { $id = $_.id; -not @($afterDevices | Where-Object { $_.id -eq $id -and $_.scheduled -eq $true }).Count })
        $unknownAfter = @($afterDevices | Where-Object { $null -eq $_.scheduled })
        $unkNote = $(if ($unknownAfter.Count) { ' Recording could NOT be checked for: ' + (& $unkWords $unknownAfter) + '.' } else { '' })
      } else { return (& $done $false ('Turning recording on is not built for ' + $v + ' yet. Nothing changed.')) }
      $ok = (-not $still.Count -and -not $unkNote)
      $res.history = 'Recording turned back on: ' + ($res.changed -join ', ') + ' (' + $Ip + ')' + $(if ($unkNote) { ' - some cameras NOT CHECKED' } else { '' })
      return (& $done $ok $(if (-not $still.Count) { 'Recording is ON again for: ' + ($res.changed -join ', ') + '.' + $(if ($unkNote) { $unkNote + ' NOT CHECKED - look at the recorder''s schedule page.' } else { ' Check again tomorrow that footage is there.' }) } else { 'Still off after the change: ' + $still.Count + '.' + $unkNote + ' Look at the recorder''s schedule page.' }))
    }
    'restart' {
      $path = $(if ($v -eq 'Uniview') { '/LAPI/V1.0/System/Reboot' } elseif ($v -eq 'Hikvision') { '/ISAPI/System/reboot' } else { '' })
      if (-not $path) { return (& $done $false ('Restart is built for Hikvision and Uniview cameras only (this is ' + $v + '). Restart its switch port by hand.')) }
      $info = Http -Ip $Ip -Path $(if ($v -eq 'Uniview') { '/LAPI/V1.0/System/DeviceInfo' } else { '/ISAPI/System/deviceInfo' }) -Credential $t.cred -Port $t.port -Timeout 8
      if ($info.code -ne 200) { return (& $done $false ('The camera did not accept the login (answer ' + $info.code + '), so it was not restarted. If it does not answer at all, restart its switch port (PoE) by hand.')) }
      $res.backup = Fix-Save $BackupDir 'device-before.txt' $info.body
      $upPre = $null; if ($v -eq 'Hikvision') { $u0 = Hik-UpTime $t 8; if ($u0.code -eq 200) { $upPre = $u0.up } }   # 2.2.13: boot marker before (null = camera does not give it)
      if (-not (& $ask @('Restart (reboot) the camera at ' + $Ip + '. It is offline for about 2 minutes.', 'Allowed: 1 restart per hour, 2 per day for this camera.'))) { return (& $done $true 'Not confirmed - nothing changed.') }
      $res.ran = $true
      $w = Http -Ip $Ip -Method 'PUT' -Path $path -Body $(if ($v -eq 'Uniview') { '{}' } else { '' }) -ContentType $(if ($v -eq 'Uniview') { 'application/json' } else { 'application/xml' }) -Credential $t.cred -Port $t.port -Timeout 8
      # 2.2.12 (Codex P1-10): an HTTP 200 is not a yes. Hikvision answers <statusCode> (1 = OK, 7 = reboot needed), Uniview
      # answers Response.ResponseCode (0 = OK). An explicit no is a refusal: nothing restarted, and the restart limit is not used up.
      $refused = ''
      if ($w.code -eq 200) {
        if ($v -eq 'Uniview') {
          $rc = $null; try { $rj = ([string]$w.body) | ConvertFrom-Json; if ($rj -and $rj.Response -and $null -ne $rj.Response.ResponseCode) { $rc = [string]$rj.Response.ResponseCode } } catch {}
          if ($null -eq $rc) { $refused = 'the camera''s answer could not be read' } elseif ($rc -ne '0') { $refused = 'camera answer code ' + $rc }
        } elseif (-not (Hik-Ok $w)) { $refused = 'camera answer ' + (XText (Xml $w.body) 'statusCode') + ' ' + (XText (Xml $w.body) 'statusString') }
      } elseif ($w.code -gt 0) { $refused = 'answer ' + $w.code }
      if ($refused) { $res.history = 'Restart asked of camera ' + $Ip + ' - refused (' + $refused.Trim() + ')'; return (& $done $false ('The camera refused the restart (' + $refused.Trim() + '). It was NOT restarted.')) }
      Fix-LimitAdd $StateFile $Ip $now
      $res.changed += 'restart asked'; Say ('Restart accepted by the camera... waiting up to ' + $WaitSec + ' s: it must go offline and come back.')
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
      if ($confirmed) { $res.changed = @('restarted'); $res.history = 'Camera ' + $Ip + ' restarted, back online' + $(if ($upReset) { ' (its uptime started again)' } else { '' }); return (& $done $true 'The camera restarted and is back. Run the Recording check to confirm it records again.') }
      if ($back -and $null -ne $upBefore) { $res.history = 'Camera ' + $Ip + ' restart asked - NOT confirmed (it dropped off but its uptime kept counting)'; return (& $done $false 'The camera dropped off the network and came back, but its own uptime kept counting, so it did NOT restart. It is NOT confirmed. Wait 5 minutes and check it; if it is still stuck, restart its switch port (PoE).') }
      if ($wentDown) { $res.history = 'Camera ' + $Ip + ' restarted, NOT back yet'; return (& $done $false ('The camera went offline for the restart but is not back after ' + $WaitSec + ' s. Restart its switch port (PoE) or go look at it.')) }
      $res.history = 'Camera ' + $Ip + ' restart asked - NOT confirmed (it never went offline' + $(if ($httpErr) { '; it answered with errors' } else { '' }) + ')'
      return (& $done $false ('The camera said OK but never went offline in ' + $WaitSec + ' s' + $(if ($httpErr) { ' (it answered with errors, which is not a restart)' } else { '' }) + ', so it is NOT confirmed that it restarted. Wait 5 minutes and check it; if it is still stuck, restart its switch port (PoE).'))
    }
    'readd' {
      if ($v -ne 'Hikvision') { return (& $done $false 'Putting a camera back on a channel is built for Hikvision NVRs only. Nothing changed.') }
      if ($Channel -lt 1 -or $CameraIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return (& $done $false 'Need the channel number and the camera IP. Nothing changed.') }
      $all = Http -Ip $Ip -Path '/ISAPI/ContentMgmt/InputProxy/channels' -Credential $t.cred -Port $t.port
      if ($all.code -ne 200) { return (& $done $false ('Could not read the NVR channel list (answer ' + $all.code + '). Nothing changed.')) }
      $ax = Xml $all.body
      if (-not $ax -or -not $ax.DocumentElement -or $ax.DocumentElement.LocalName -notmatch '(?i)^InputProxyChannelList$') { return (& $done $false 'The NVR''s answer was not a channel list, so it could not be checked which camera uses the channel. Nothing changed. Run it again.') }
      $res.backup = Fix-Save $BackupDir 'nvr-channels-before.xml' $all.body
      $used = $null; $listed = @(); $slot = $null
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
      if (-not (& $ask @('Put camera ' + $CameraIp + ' on channel ' + $Channel + ' of the NVR ' + $Ip + ' (login admin + the camera password you typed; it is not saved).', 'Backup of the channel list saved: ' + $res.backup))) { return (& $done $true 'Not confirmed - nothing changed.') }
      $res.ran = $true
      $xml = '<?xml version="1.0" encoding="UTF-8"?><InputProxyChannel version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema"><id>' + $Channel + '</id><sourceInputPortDescriptor><proxyProtocol>HIKVISION</proxyProtocol><addressingFormatType>ipaddress</addressingFormatType><ipAddress>' + $CameraIp + '</ipAddress><managePortNo>8000</managePortNo><srcInputPort>1</srcInputPort><userName>' + (Fix-Xml $NewCredential.UserName) + '</userName><password>' + (Fix-Xml (Plain $NewCredential)) + '</password><streamType>auto</streamType></sourceInputPortDescriptor></InputProxyChannel>'
      $w = Http -Ip $Ip -Method 'PUT' -Path ('/ISAPI/ContentMgmt/InputProxy/channels/' + $Channel) -Body $xml -Credential $t.cred -Port $t.port -NoLogBody
      $xml = $null
      if (-not (Hik-Ok $w)) { $res.history = 'Re-add camera ' + $CameraIp + ' to channel ' + $Channel + ' - refused by the NVR'; return (& $done $false ('The NVR refused it (answer ' + $w.code + ').')) }
      $res.changed += ('channel ' + $Channel + ' = ' + $CameraIp)
      # 2.2.13 (Codex 2.2.12 #6): "online" alone is not proof: the channel must be READ BACK (a real list) with the camera
      # address we asked for. An NVR that says OK but keeps the old camera (which then comes back online) is NOT done.
      $rb = Hik-ReadChannel $t $Channel
      if (-not $rb.ok) {
        $res.history = 'Re-add camera ' + $CameraIp + ' to channel ' + $Channel + ' - sent, NOT confirmed (' + $rb.why + ')'
        return (& $done $false ('Sent to the NVR, but ' + $rb.why + ', so it is NOT confirmed that ' + $CameraIp + ' is on channel ' + $Channel + '. Run it again or check the channel in the NVR.'))
      }
      if (-not $rb.found -or $rb.ip -ne $CameraIp) {
        $res.history = 'Re-add camera ' + $CameraIp + ' to channel ' + $Channel + ' - NOT done (channel shows ' + $(if ($rb.found) { $(if ($rb.ip) { $rb.ip } else { 'no address' }) } else { 'nothing' }) + ')'
        return (& $done $false ('The NVR said OK, but channel ' + $Channel + ' still shows ' + $(if ($rb.found) { $(if ($rb.ip) { $rb.ip } else { 'no camera address' }) } else { 'no camera' }) + ', not ' + $CameraIp + '. NOT done - check the channel in the NVR.'))
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
      # 2.2.3 (Codex #21): the export is the device's own binary file: saved byte for byte as .bin (2.2.2 turned it into text)
      if (-not $BackupDir) { $BackupDir = Join-Path $env:TEMP 'WireIt-backup' }; New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
      $cfgFile = Join-Path $BackupDir ('config-' + ($di.serial -replace '[^A-Za-z0-9_-]', '_') + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bin')
      $cfg = Http -Ip $Ip -Path '/ISAPI/System/configurationData' -Credential $t.cred -Port $t.port -Timeout 30 -OutFile $cfgFile
      if ($cfg.code -ne 200) { return (& $done $false 'Could not export the settings first, so no update. Nothing changed.') }
      $bw = Test-NhBackupFile $cfgFile; if ($bw) { Log ('backup FAILED: ' + $bw); Remove-Item -LiteralPath $cfgFile -Force -ErrorAction SilentlyContinue; return (& $done $false ('The settings export FAILED (' + $bw + '), so no update. Nothing changed.')) }   # 2.2.4
      $res.backup = $cfgFile
      if (-not (& $ask @('Update ' + $di.model + ' at ' + $Ip + ' from ' + $di.firmware + ' with ' + (Split-Path -Leaf $File) + ' (SHA-256 matches). It reboots; do not unplug it for 10 minutes.', 'Settings exported first: ' + $res.backup, 'To go back: upload the old firmware file the same way, then import the exported settings in the camera''s web page (Maintenance).'))) { return (& $done $true 'Not confirmed - nothing changed.') }
      $res.ran = $true
      $w = Http -Ip $Ip -Method 'PUT' -Path '/ISAPI/System/updateFirmware' -BodyBytes ([IO.File]::ReadAllBytes($File)) -ContentType 'application/octet-stream' -Credential $t.cred -Port $t.port -Timeout 600
      # 2.2.15 (Codex 2.2.14 R10): NO answer (connection dropped / timed out, code 0) is not a refusal: the device may have taken
      # the file and be installing it. Read the device back; unless it already shows a new version it is SENT, NOT confirmed.
      if ([int]$w.code -le 0) {
        $res.changed += 'firmware sent (answer lost)'
        $lost = Hik-DeviceInfo $t
        if ($lost.login -eq 'ok' -and $lost.firmware -and $lost.firmware -ne $di.firmware) {
          $res.changed = @($di.firmware + ' -> ' + $lost.firmware)
          $res.history = 'Firmware ' + $Ip + ' ' + $di.firmware + ' -> ' + $lost.firmware + ' (its answer was lost; the new version was read back)'
          return (& $done $true ('Updated: ' + $di.firmware + ' -> ' + $lost.firmware + '. The device''s answer was lost, but it now reports the new version (read back).'))
        }
        $seen = $(if ($lost.login -eq 'ok') { 'right now it reports ' + $(if ($lost.firmware) { $lost.firmware } else { 'no version' }) + ', which is normal while it installs' } else { 'it could not be read back (it may be rebooting)' })
        $res.history = 'Firmware update of ' + $Ip + ' sent - NOT confirmed (the answer was lost; ' + $(if ($lost.login -eq 'ok') { 'read back: ' + $lost.firmware } else { 'read-back failed' }) + ')'
        return (& $done $false ('Sent, but the device''s answer was lost, so it is NOT confirmed whether the update ran (' + $seen + '). Do NOT send it again yet: wait 10 minutes, then run the Firmware check. Only if that still shows ' + $di.firmware + ' try the update again. Settings export kept: ' + $res.backup))
      }
      if (-not (Hik-Ok $w)) { $res.history = 'Firmware update of ' + $Ip + ' refused (' + $w.code + ')'; return (& $done $false ('The device refused the file (answer ' + $w.code + '), so the update did not start. Settings export kept: ' + $res.backup)) }
      $after = Hik-DeviceInfo $t
      $ok = [bool]($after.login -eq 'ok' -and $after.firmware -ne $di.firmware)
      $res.changed += ($di.firmware + ' -> ' + $(if ($after.login -eq 'ok') { $after.firmware } else { '?' }))
      $res.history = 'Firmware ' + $Ip + ' ' + ($res.changed -join '')
      return (& $done $ok $(if ($ok) { 'Updated: ' + ($res.changed -join '') + '.' } else { 'Sent, but the new version is not showing yet. Wait 10 minutes and run the Firmware check.' }))
    }
    'password' {
      if ($v -ne 'Hikvision') { return (& $done $false 'Setting the site password is built for Hikvision only. Nothing changed.') }
      $di = Hik-DeviceInfo $t; if ($di.login -ne 'ok') { return (& $done $false 'Could not log in with the current password (one try). Nothing changed.') }
      if (-not (& $ask @('Set the site password on ' + $di.model + ' at ' + $Ip + ' (user admin). It is not saved anywhere.', 'Write the new password into the site''s password manager now.'))) { return (& $done $true 'Not confirmed - nothing changed.') }
      $res.ran = $true
      $xml = '<?xml version="1.0" encoding="UTF-8"?><User version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema"><id>1</id><userName>admin</userName><password>' + (Fix-Xml (Plain $NewCredential)) + '</password><loginPassword>' + (Fix-Xml (Plain $t.cred)) + '</loginPassword></User>'
      $w = Http -Ip $Ip -Method 'PUT' -Path '/ISAPI/Security/users/1' -Body $xml -Credential $t.cred -Port $t.port -NoLogBody
      $xml = $null
      if (-not (Hik-Ok $w)) {
        # 2.2.14 (Codex 2.2.13 F7): a lost / non-OK answer is NOT proof of a refusal - the device may have applied the new password
        # and dropped the connection. Reconcile like FixSite's Resolve-FsPwChange: try the NEW password, then the old one (one try
        # each). Only a working old password with a failing new one is "refused"; nothing working = unknown / maybe changed.
        $nw = Http -Ip $Ip -Path '/ISAPI/System/deviceInfo' -Credential $NewCredential -Port $t.port
        if ($nw.code -eq 200) {
          $res.changed += 'password'; $res.history = 'Site password set on ' + $Ip + ' (its answer was ' + $w.code + ', but the new one works)'
          return (& $done $true ('The device''s answer was not OK (answer ' + $w.code + '), but the NEW password logs in, so the password IS changed. Update it in DW/NVR if they log in to this device.'))
        }
        $od = Http -Ip $Ip -Path '/ISAPI/System/deviceInfo' -Credential $t.cred -Port $t.port
        if ($od.code -eq 200) { $res.history = 'Site password on ' + $Ip + ' - refused (old one checked: still works)'; return (& $done $false ('The device refused the new password (answer ' + $w.code + '). The old one still works (checked).')) }
        $res.changed += 'password (unknown)'
        $res.history = 'Site password on ' + $Ip + ' - UNKNOWN, maybe changed (answer ' + $w.code + '; neither password logged in: ' + $nw.code + '/' + $od.code + ')'
        return (& $done $false ('UNKNOWN - the password MAY have changed: the device''s answer was ' + $w.code + ' and now neither the new nor the old password logs in (' + $nw.code + ' / ' + $od.code + '). Wait 2 minutes and try both in its web page. If the new one works, update it in every NVR/DW that records this device.'))
      }
      $chk = Http -Ip $Ip -Path '/ISAPI/System/deviceInfo' -Credential $NewCredential -Port $t.port
      $ok = ($chk.code -eq 200); $res.changed += 'password'
      $res.history = 'Site password set on ' + $Ip + $(if ($ok) { ' (new one works)' } else { ' (new one not confirmed)' })
      return (& $done $ok $(if ($ok) { 'The new password works. Update it in DW/NVR if they log in to this device.' } else { 'Changed, but the new password did not log in yet. Try it in the web page.' }))
    }
    'dwpassword' {
      if ($v -ne 'DW') { return (& $done $false 'This fix is for a DW server. Nothing changed.') }
      if (-not (Dw-Login $t)) { return (& $done $false 'The DW server refused the login. Nothing changed.') }
      $rd = Dw-ReadDevices $t
      if (-not $rd.ok) { return (& $done $false ('Could not read DW''s camera list (' + $rd.why + '). Nothing changed. Run it again.')) }
      $devs = @($rd.devs); $d = $devs | Where-Object { $_.ip -eq $CameraIp } | Select-Object -First 1
      if (-not $d) { return (& $done $false ($CameraIp + ' is not in DW''s camera list. Nothing changed.')) }
      $res.backup = Fix-Save $BackupDir 'dw-cameras-before.json' ($devs | ConvertTo-Json -Depth 4)
      if (-not (& $ask @('Give DW the camera password for ' + $d.name + ' (' + $CameraIp + '), so DW stops logging in with the wrong one.', 'If the camera is LOCKED, wait until it unlocks first (Camera doctor shows the minutes).'))) { return (& $done $true 'Not confirmed - nothing changed.') }
      $res.ran = $true
      $w = Dw-Send $t 'PATCH' ('/rest/v3/devices/' + [uri]::EscapeDataString($d.id)) @{ credentials = @{ user = $NewCredential.UserName; password = (Plain $NewCredential) } } -Secret
      if ($w.code -ne 200) { $res.history = 'DW password for ' + $d.name + ' - refused (' + $w.code + ')'; return (& $done $false ('DW refused it (answer ' + $w.code + ').')) }
      $res.changed += $d.name
      $st = ''; $end = (Get-Date).AddSeconds([math]::Min($WaitSec, 60))
      do { $x = @(Dw-Devices $t) | Where-Object { $_.ip -eq $CameraIp } | Select-Object -First 1; $st = [string]$x.status; if ($st -eq 'Unauthorized' -and $WaitSec -gt 0) { Start-Sleep -Seconds 10 } } while ($st -eq 'Unauthorized' -and (Get-Date) -lt $end)
      $ok = ($st -and $st -ne 'Unauthorized')
      $res.history = 'DW password updated for ' + $d.name + ' (' + $CameraIp + '): DW now says ' + $st
      return (& $done $ok $(if ($ok) { 'DW now says ' + $st + ' for ' + $d.name + '.' } else { 'DW still says Unauthorized. The typed password may be wrong, or the camera is still locked.' }))
    }
  }
}
