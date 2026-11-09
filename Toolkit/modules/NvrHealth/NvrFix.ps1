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
        $all = Http -Ip $Ip -Path '/ISAPI/ContentMgmt/record/tracks' -Credential $t.cred -Port $t.port
        if ($all.code -ne 200) { return (& $done $false ('Could not read the recording settings (answer ' + $all.code + '). Nothing changed.')) }
        $off = @((Hik-Tracks $t).Values | Where-Object { -not $_.enabled } | Sort-Object id)
        if (-not $off.Count) { return (& $done $true 'Recording is already on for every camera. Nothing to change.') }
        $res.backup = Fix-Save $BackupDir 'record-tracks-before.xml' $all.body
        if (-not (& $ask @('Turn recording back ON (continuous schedule kept as it is) for camera(s): ' + (($off | ForEach-Object { [math]::Floor($_.id / 100) }) -join ', ') + ' on ' + $Ip + '.', 'Backup of the recording settings saved: ' + $res.backup))) { return (& $done $true 'Not confirmed - nothing changed.') }
        $res.ran = $true
        foreach ($o in $off) {
          $one = Http -Ip $Ip -Path ('/ISAPI/ContentMgmt/record/tracks/' + $o.id) -Credential $t.cred -Port $t.port
          $xml = ([string]$one.body) -replace '<Enable>false</Enable>', '<Enable>true</Enable>'
          $w = Http -Ip $Ip -Method 'PUT' -Path ('/ISAPI/ContentMgmt/record/tracks/' + $o.id) -Body $xml -Credential $t.cred -Port $t.port
          if (Hik-Ok $w) { $res.changed += ('camera ' + [math]::Floor($o.id / 100)) }
        }
        $afterTracks = Hik-Tracks $t
        $still = @($off | Where-Object { -not $afterTracks.ContainsKey($_.id) -or -not $afterTracks[$_.id].enabled })
      } elseif ($v -eq 'DW') {
        if (-not (Dw-Login $t)) { return (& $done $false 'The DW server refused the login. Nothing changed.') }
        $devs = @(Dw-Devices $t); $off = @($devs | Where-Object { $_.scheduled -eq $false })
        if (-not $off.Count) { return (& $done $true 'Recording is already on for every camera in DW. Nothing to change.') }
        $res.backup = Fix-Save $BackupDir 'dw-cameras-before.json' ($devs | ConvertTo-Json -Depth 4)
        if (-not (& $ask @('Turn recording back ON in DW for: ' + (($off | ForEach-Object { $_.name + ' (' + $_.ip + ')' }) -join ', ') + '.', 'Backup of the camera list saved: ' + $res.backup))) { return (& $done $true 'Not confirmed - nothing changed.') }
        $res.ran = $true
        foreach ($o in $off) { $w = Dw-Send $t 'PATCH' ('/rest/v3/devices/' + [uri]::EscapeDataString($o.id)) @{ schedule = @{ isEnabled = $true } }; if ($w.code -eq 200) { $res.changed += $o.name } }
        $afterDevices = @(Dw-Devices $t)
        $still = @($off | Where-Object { $id = $_.id; -not @($afterDevices | Where-Object { $_.id -eq $id -and $_.scheduled -eq $true }).Count })
      } else { return (& $done $false ('Turning recording on is not built for ' + $v + ' yet. Nothing changed.')) }
      $ok = (-not $still.Count)
      $res.history = 'Recording turned back on: ' + ($res.changed -join ', ') + ' (' + $Ip + ')'
      return (& $done $ok $(if ($ok) { 'Recording is ON again for: ' + ($res.changed -join ', ') + '. Check again tomorrow that footage is there.' } else { 'Still off after the change: ' + $still.Count + '. Look at the recorder''s schedule page.' }))
    }
    'restart' {
      $path = $(if ($v -eq 'Uniview') { '/LAPI/V1.0/System/Reboot' } elseif ($v -eq 'Hikvision') { '/ISAPI/System/reboot' } else { '' })
      if (-not $path) { return (& $done $false ('Restart is built for Hikvision and Uniview cameras only (this is ' + $v + '). Restart its switch port by hand.')) }
      $info = Http -Ip $Ip -Path $(if ($v -eq 'Uniview') { '/LAPI/V1.0/System/DeviceInfo' } else { '/ISAPI/System/deviceInfo' }) -Credential $t.cred -Port $t.port -Timeout 8
      if ($info.code -ne 200) { return (& $done $false ('The camera did not accept the login (answer ' + $info.code + '), so it was not restarted. If it does not answer at all, restart its switch port (PoE) by hand.')) }
      $res.backup = Fix-Save $BackupDir 'device-before.txt' $info.body
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
      $infoPath = $(if ($v -eq 'Uniview') { '/LAPI/V1.0/System/DeviceInfo' } else { '/ISAPI/System/deviceInfo' })
      $pollMs = $(if ($WaitSec -ge 30) { 3000 } else { 500 })
      $wentDown = $false; $back = $false; $end = (Get-Date).AddSeconds([math]::Max($WaitSec, 1))
      do {
        Start-Sleep -Milliseconds $pollMs
        $pr = Http -Ip $Ip -Path $infoPath -Credential $t.cred -Port $t.port -Timeout 5
        if ($pr.code -ne 200) { $wentDown = $true } elseif ($wentDown) { $back = $true }
      } while (-not $back -and (Get-Date) -lt $end)
      if ($back) { $res.changed = @('restarted'); $res.history = 'Camera ' + $Ip + ' restarted, back online'; return (& $done $true 'The camera restarted and is back. Run the Recording check to confirm it records again.') }
      if ($wentDown) { $res.history = 'Camera ' + $Ip + ' restarted, NOT back yet'; return (& $done $false ('The camera went offline for the restart but is not back after ' + $WaitSec + ' s. Restart its switch port (PoE) or go look at it.')) }
      $res.history = 'Camera ' + $Ip + ' restart asked - NOT confirmed (it never went offline)'
      return (& $done $false ('The camera said OK but never went offline in ' + $WaitSec + ' s, so it is NOT confirmed that it restarted. Wait 5 minutes and check it; if it is still stuck, restart its switch port (PoE).'))
    }
    'readd' {
      if ($v -ne 'Hikvision') { return (& $done $false 'Putting a camera back on a channel is built for Hikvision NVRs only. Nothing changed.') }
      if ($Channel -lt 1 -or $CameraIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return (& $done $false 'Need the channel number and the camera IP. Nothing changed.') }
      $all = Http -Ip $Ip -Path '/ISAPI/ContentMgmt/InputProxy/channels' -Credential $t.cred -Port $t.port
      if ($all.code -ne 200) { return (& $done $false ('Could not read the NVR channel list (answer ' + $all.code + '). Nothing changed.')) }
      $res.backup = Fix-Save $BackupDir 'nvr-channels-before.xml' $all.body
      $used = $null; foreach ($c in (XFind (Xml $all.body) 'InputProxyChannel')) { if ([int](XText $c 'id') -eq $Channel) { $used = XText $c 'ipAddress' } }
      $chans = @(Hik-Channels $t); $cur = $chans | Where-Object { $_.ch -eq $Channel } | Select-Object -First 1
      if ($used -and $used -ne $CameraIp -and $cur -and $cur.online) { return (& $done $false ('Channel ' + $Channel + ' is in use by ' + $used + ' and that camera is online. Nothing changed.')) }
      if (@($chans | Where-Object { $_.ip -eq $CameraIp -and $_.ch -ne $Channel }).Count) { return (& $done $false ($CameraIp + ' is already on another channel. Nothing changed.')) }
      if (-not (& $ask @('Put camera ' + $CameraIp + ' on channel ' + $Channel + ' of the NVR ' + $Ip + ' (login admin + the camera password you typed; it is not saved).', 'Backup of the channel list saved: ' + $res.backup))) { return (& $done $true 'Not confirmed - nothing changed.') }
      $res.ran = $true
      $xml = '<?xml version="1.0" encoding="UTF-8"?><InputProxyChannel version="2.0" xmlns="http://www.hikvision.com/ver20/XMLSchema"><id>' + $Channel + '</id><sourceInputPortDescriptor><proxyProtocol>HIKVISION</proxyProtocol><addressingFormatType>ipaddress</addressingFormatType><ipAddress>' + $CameraIp + '</ipAddress><managePortNo>8000</managePortNo><srcInputPort>1</srcInputPort><userName>' + (Fix-Xml $NewCredential.UserName) + '</userName><password>' + (Fix-Xml (Plain $NewCredential)) + '</password><streamType>auto</streamType></sourceInputPortDescriptor></InputProxyChannel>'
      $w = Http -Ip $Ip -Method 'PUT' -Path ('/ISAPI/ContentMgmt/InputProxy/channels/' + $Channel) -Body $xml -Credential $t.cred -Port $t.port -NoLogBody
      $xml = $null
      if (-not (Hik-Ok $w)) { $res.history = 'Re-add camera ' + $CameraIp + ' to channel ' + $Channel + ' - refused by the NVR'; return (& $done $false ('The NVR refused it (answer ' + $w.code + ').')) }
      $res.changed += ('channel ' + $Channel + ' = ' + $CameraIp)
      $after = @(Hik-Channels $t) | Where-Object { $_.ch -eq $Channel } | Select-Object -First 1
      $ok = [bool]($after -and $after.online)
      $res.history = 'Camera ' + $CameraIp + ' put back on NVR channel ' + $Channel + $(if ($ok) { ', online' } else { ', not online yet' })
      return (& $done $ok $(if ($ok) { 'Camera ' + $CameraIp + ' is on channel ' + $Channel + ' and online.' } else { 'Added, but the NVR does not show it online yet (wrong camera password?). Check the channel in the NVR.' }))
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
      if (-not (Hik-Ok $w)) { $res.history = 'Firmware update of ' + $Ip + ' refused (' + $w.code + ')'; return (& $done $false ('The device refused the file (answer ' + $w.code + '). It still runs the old firmware.')) }
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
      if (-not (Hik-Ok $w)) { $res.history = 'Site password on ' + $Ip + ' - refused'; return (& $done $false ('The device refused the new password (answer ' + $w.code + '). The old one still works.')) }
      $chk = Http -Ip $Ip -Path '/ISAPI/System/deviceInfo' -Credential $NewCredential -Port $t.port
      $ok = ($chk.code -eq 200); $res.changed += 'password'
      $res.history = 'Site password set on ' + $Ip + $(if ($ok) { ' (new one works)' } else { ' (new one not confirmed)' })
      return (& $done $ok $(if ($ok) { 'The new password works. Update it in DW/NVR if they log in to this device.' } else { 'Changed, but the new password did not log in yet. Try it in the web page.' }))
    }
    'dwpassword' {
      if ($v -ne 'DW') { return (& $done $false 'This fix is for a DW server. Nothing changed.') }
      if (-not (Dw-Login $t)) { return (& $done $false 'The DW server refused the login. Nothing changed.') }
      $devs = @(Dw-Devices $t); $d = $devs | Where-Object { $_.ip -eq $CameraIp } | Select-Object -First 1
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
