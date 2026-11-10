<#
NvrCheck.ps1 - WireIt Toolkit buttons 9-12 (recorder health). Runs NvrHealth (modules\NvrHealth) in its own window
so the recorder password is typed hidden there; everything it says goes to runs\Nvr<Mode>-<time>\log.txt, which the
Toolkit shows live.
  -Mode Recording  read-only: every camera recording? days of footage vs. the site's target, hard drives + health
  -Mode Clock      read-only: recorder (and camera) clocks vs. real time, time server on, US Eastern + DST
  -Mode FixClock   THE ONLY WRITE: shows the plan first (what-if, nothing changes); changes the time settings only
                   after you type YES in this window. Anything else = nothing changes.
  -Mode Firmware   read-only: firmware vs. the newest published + known security holes. Reports only, never updates.
  -Mode Doctor     "Camera doctor" (Nov 3 2026): ONE camera - ping, ARP/MAC, ports, web page, ONE login try with the typed
                   site password, RTSP, and what DW says about it (-DwIp). Plain verdict + which fix button applies. Changes nothing.
  -Mode Site       "Check this site" (Nov 3 2026): read-only chain - the camera list just saved by Find cameras, the router
                   (UPnP on? camera ports open to the internet?), recording + streams, clocks, firmware - then ONE "Latest check"
                   card on the site page (op toolkitCheck). Never runs a fix.
No password is saved or logged.
#>
param(
  [Parameter(Mandatory)][ValidateSet('Recording', 'Clock', 'FixClock', 'Firmware', 'Site', 'Doctor')][string]$Mode,
  [Parameter(Mandatory)][string]$Ip,
  [string]$Site = '', [int]$Days = 0, [switch]$Cameras,
  [ValidateSet('Auto', 'Hikvision', 'Uniview', 'DW', 'Onvif')][string]$Vendor = 'Auto', [int]$Port = 0,
  [string]$RunsDir = '', [string]$MockUrl = '', [string]$TestAnswer = '', [int]$CloseAfter = 8,
  [string]$UpnpLocation = '', [switch]$NoUpnp, [string]$ApiUrl = '', [switch]$NoSend,
  [string]$DwIp = '', [string]$Maker = '', [string]$Mac = '', [string]$CamResetDir = ''
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'ToolkitCore.ps1')
$titles = @{ Doctor = 'Camera doctor'; Recording = 'Recording check'; Clock = 'Clock check'; FixClock = 'Fix clock (NTP)'; Firmware = 'Firmware / security check'; Site = 'Check this site' }
try { $Host.UI.RawUI.WindowTitle = 'WireIt Toolkit - ' + $titles[$Mode] + ' - ' + $Ip } catch {}
if (-not $RunsDir) { $RunsDir = Join-Path $here 'runs' }
if (-not $CamResetDir) { $CamResetDir = Join-Path (Split-Path -Parent $here) 'CamReset' }
$run = Join-Path $RunsDir ('Nvr' + $Mode + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force -Path $run | Out-Null
$log = Join-Path $run 'log.txt'
function Say2([string]$s, [string]$color = '') { if ($color) { Write-Host $s -ForegroundColor $color } else { Write-Host $s }; [void](Add-TkLine $log ((Get-Date -Format 'HH:mm:ss') + ' SAY ' + $s)) }
function Done([int]$code) {
  if ($CloseAfter -gt 0) { Write-Host ''; Write-Host ('Done. The results are in the Toolkit window. This window closes in ' + $CloseAfter + ' seconds.'); Start-Sleep -Seconds $CloseAfter }
  exit $code
}

$mod = Join-Path $here 'modules\NvrHealth\NvrHealth.psm1'
if (-not (Test-Path $mod)) { Say2 'PROBLEM The NvrHealth module is missing (modules\NvrHealth). Use "Check for update" in the Toolkit.' 'Red'; Done 2 }
Import-Module $mod -Force
Set-NvrHealthOption LogFile $log
$ref = Get-TkNvrReference $here
if ($ref) { Set-NvrHealthOption ReferenceFile $ref }
if ($MockUrl) { Set-NvrHealthOption MockUrl $MockUrl }
if ($Days -gt 0) { Set-NvrHealthOption TargetDays $Days }

Say2 ('=== ' + $titles[$Mode] + ' - ' + $Ip + $(if ($Site) { ' (' + $Site + ')' } else { '' }) + ' ===') 'Cyan'
if ($Mode -eq 'Recording') { Say2 ('Target: ' + $(if ($Days -gt 0) { $Days } else { (Get-NvrHealthOption).TargetDays }) + ' days of footage' + $(if ($Site) { ' for ' + $Site } else { '' }) + '.') }
if ($Mode -eq 'FixClock') { Say2 'Step 1 shows what would change. NOTHING changes unless you type YES in this window.' 'Yellow' }

$scan = $null; $ux = $null
if ($Mode -eq 'Site') {
  Say2 'Read-only: nothing on the recorder, cameras or router is changed. Fixes are separate buttons.' 'Yellow'
  Say2 ''; Say2 'Step 1 of 3: camera list (from Find cameras just now)' 'Cyan'
  $scan = Read-TkJson (Join-Path $here 'logs\scan-upload-last.json')
  # 2.2.3 (Codex #44): the last upload counts only when it is THIS site's (same site name), fresh, and not a snapshot
  if (-not ($scan -and $scan.at -and ((Get-Date) - [datetime]$scan.at).TotalMinutes -lt 30 -and -not $scan.snapshot -and $Site -and ([string]$scan.site).Trim() -eq $Site.Trim())) {
    # 1.6.1: nothing uploaded (no Site ID) - use the list Find cameras just made on this PC
    $scan = $null; try { $scan = Get-TkFreshScan $CamResetDir 30 } catch { $scan = $null }
  }
  if ($scan) { foreach ($l in @($scan.lines)) { if ($l) { Say2 ('  ' + $l) $(if (@($scan.red) -contains $l) { 'Red' } else { '' }) } } }
  else { Say2 '  No fresh camera list (Find cameras did not run in the last 30 minutes or found nothing). Continuing.' 'Yellow' }
  Say2 ''; Say2 'Step 2 of 3: router - UPnP and ports open to the internet (read-only)' 'Cyan'
  $camIps = @($Ip); $lj = Read-TkJson (Join-Path $CamResetDir 'out\latest.json'); if ($lj) { $camIps += @($lj.devices | ForEach-Object { [string]$_.IP } | Where-Object { $_ }) }
  if ($NoUpnp) { Say2 '  Router check skipped.' }
  else {
    try { $ux = Get-TkUpnpExposure -Locations @($(if ($UpnpLocation) { $UpnpLocation })) -CameraIps $camIps } catch { Say2 ('  Router check could not run: ' + $_.Exception.Message) 'Yellow' }
    if ($ux) { foreach ($l in @($ux.lines)) { Say2 ('  ' + $l.t) $(switch ($l.k) { 'red' { 'Red' } 'ok' { 'Green' } default { '' } }) } }
  }
  Say2 ''; Say2 'Step 3 of 3: recorder - recording, streams, clocks, firmware' 'Cyan'
}
# 1.4: the cameras Find cameras just found (last 30 min) - behind a DW server their clocks are read from this list, with NO login
$findIps = @()
if ($Cameras -and $Mode -in @('Site', 'Clock')) {
  $pick = { param($fs) if ($fs -and $fs.devices) { @($fs.devices | Where-Object { $_ -and [string]$_.kind -eq 'camera' -and $_.ip -and $_.ip -ne $Ip } | ForEach-Object { [string]$_.ip } | Select-Object -Unique) } else { @() } }
  $findIps = @(& $pick $scan)
  if (-not $findIps.Count) { try { $findIps = @(& $pick (Get-TkFreshScan $CamResetDir 30)) } catch { $findIps = @() } }
}
if ($Mode -eq 'Doctor') {
  # Camera doctor: read-only. At most ONE login try on the camera (never repeated, so it cannot lock it), one DW read.
  Say2 'Read-only: nothing on the camera, DW or the network is changed. At most ONE login try on the camera.' 'Yellow'
  $code = 0
  try {
    Set-NvrHealthOption LogFile $log
    if ($MockUrl -and -not $env:WIREIT_TEST_REACH) { $reach = $null }   # test harness: no real network
    else { Say2 'Steps 1-3: ping, MAC (ARP), ports 80 / 443 / 554 / 8000...'; $reach = Test-TkCamReach $Ip $Mac }
    if ($TestAnswer -and $MockUrl) { $cred = New-Object PSCredential('admin', (ConvertTo-SecureString ($env:NVRCHECK_TEST_PW) -AsPlainText -Force)); $dwCred = $(if ($DwIp) { $cred } else { $null }) }   # test harness only
    else {
      Write-Host ''; Write-Host 'The camera login: type the SITE password (one try only). Leave the password empty to skip the login step.' -ForegroundColor Yellow
      $cred = Read-NvrCredential ('the camera at ' + $Ip); if ($cred -and -not $cred.GetNetworkCredential().Password) { $cred = $null }
      $dwCred = $null
      if ($DwIp) { Write-Host ''; Write-Host ('The DW server login (to read what DW says about this camera). Empty password = skip.') -ForegroundColor Yellow; $dwCred = Read-NvrCredential ('the DW server at ' + $DwIp); if ($dwCred -and -not $dwCred.GetNetworkCredential().Password) { $dwCred = $null } }
    }
    $dp = @{ Ip = $Ip; Reach = $reach; Port = $Port }
    if ($cred) { $dp.Credential = $cred }; if ($Maker) { $dp.Maker = $Maker }
    if ($DwIp -and $dwCred) { $dp.DwIp = $DwIp; $dp.DwCredential = $dwCred }
    $r = Invoke-CameraDoctor @dp
    $j = [ordered]@{ at = (Get-Date).ToString('s'); ip = $Ip; maker = $r.maker; ping = $r.ping; mac = $r.mac; open = @($r.open); web = $r.web; login = $r.login; lockMin = $r.lockMin; rtsp = $r.rtsp; dw = $r.dw; verdict = $r.verdict; fixes = @($r.fixes); steps = @($r.steps) }
    Save-TkJson ([pscustomobject]$j) (Join-Path $here 'logs\doctor-last.json'); Save-TkJson ([pscustomobject]$j) (Join-Path $run 'doctor.json')
    if (@($r.fixes).Count) { $code = 4 }
  } catch { Say2 ('PROBLEM ' + $_.Exception.Message) 'Red'; $code = 1 }
  finally { try { [void](Close-NvrSessions) } catch {} }   # 1.4: always log out of DW
  Set-Content -Path (Join-Path $run 'result.json') -Value (@{ mode = $Mode; ip = $Ip; code = $code } | ConvertTo-Json)
  Done $code
}
if ($Mode -in @('Recording', 'Site') -and $Days -le 0) {
  # no target typed: the site's own target from config, else from the DW server's name (YKW Elm: no site typed -> 30 instead of 45)
  $nm = $Site; $src = 'site'; if (-not $nm) { $nm = Get-TkDwName $Ip $MockUrl; $src = 'DW server name' }
  $Days = Get-TkDaysToKeep (Get-TkConfig $here) $nm
  Say2 ('Days to keep: ' + $Days + $(if ($nm) { ' (from the ' + $src + ' "' + $nm + '")' } else { ' (default - type the site to use its own target)' }))
}
if ($TestAnswer -and $MockUrl) { $cred = New-Object PSCredential('admin', $(if ($env:NVRCHECK_TEST_PW) { ConvertTo-SecureString ($env:NVRCHECK_TEST_PW) -AsPlainText -Force } else { New-Object Security.SecureString })) }   # test harness only
else {
  # 1.6.1: the tech can skip the recorder login - nothing is sent, and what needs it shows NOT CHECKED (never an all-clear)
  Write-Host ''
  Write-Host $(if ($Mode -eq 'FixClock') { 'The recorder login (needed to change the time settings).' } else { 'The recorder login: ONE try, never repeated. Leave the password EMPTY to skip it - nothing is sent; recording, clocks and the DW list then show NOT CHECKED.' }) -ForegroundColor Yellow
  $cred = Read-NvrCredential ('the recorder at ' + $Ip)
}
$noLogin = (-not $cred -or -not $cred.GetNetworkCredential().Password)
if ($noLogin) {
  if ($Mode -eq 'FixClock') { Say2 'No password typed - nothing was sent and nothing was changed.' 'Yellow'; Set-Content -Path (Join-Path $run 'result.json') -Value (@{ mode = $Mode; ip = $Ip; code = 0; skipped = $true; finished = (Get-Date -Format s) } | ConvertTo-Json); Done 0 }
  Say2 'Recorder login skipped (no password typed) - nothing was sent to the recorder login. Parts that need it show NOT CHECKED.' 'Yellow'
}
$common = @{ Ip = $Ip; Vendor = $Vendor; Credential = $cred; Port = $Port }
$code = 0
$stopWhy = ''
try {
  Set-NvrHealthOption LogFile $log
  switch ($Mode) {
    'Recording' { $r = Get-RecordingStatus @common -TargetDays $Days }
    'Clock'     { $r = Get-ClockStatus @common -IncludeCameras:$Cameras -FindIps $findIps }
    'Firmware'  { $r = Get-FirmwareStatus @common -IncludeCameras:$Cameras }
    'Site'      { $r = Get-NvrHealth @common -TargetDays $Days -IncludeCameras:$Cameras -FindIps $findIps -Json (Join-Path $run 'health.json') }
    'FixClock' {
      $plan = Set-NtpTime @common -IncludeCameras:$Cameras -WhatIf
      $todo = @($plan.devices | Where-Object { $_.result -eq 'what-if (not changed)' })
      if (-not $todo.Count) {
        Say2 ''; Say2 'Nothing to change: the time settings are already right (or could not be read, see above).'
        $r = $plan
      } else {
        Write-Host ''
        Write-Host ('Type YES (capital letters) and Enter to change the time settings on ' + $todo.Count + ' device(s). Anything else = no change.') -ForegroundColor Yellow
        $ans = $(if ($TestAnswer) { $TestAnswer } else { Read-Host 'Change them now?' })
        if ($ans -ceq 'YES') {
          Say2 ''; Say2 'You typed YES. Changing the time settings now...'
          $r = Set-NtpTime @common -IncludeCameras:$Cameras -WhatIf:$false -Confirm:$false
        } else {
          Say2 ''; Say2 'Not confirmed (you did not type YES). Nothing was changed.'
          $r = $plan; $code = 0
        }
      }
    }
  }
  if ($MockUrl -and $env:NVRCHECK_TEST_THROW) { throw $env:NVRCHECK_TEST_THROW }   # test harness only: a check that stops after the login
  if ($r -and $r.PSObject.Properties['failed'] -and $r.failed) { $code = 4 }
  elseif ($r -and $r.PSObject.Properties['problems'] -and @($r.problems).Count) {
    if (@($r.problems | Where-Object { $_ -match $TkNotCheckedRx }).Count -and -not @($r.problems | Where-Object { $_ -notmatch $TkNotCheckedRx }).Count) { $code = 2 } else { $code = 4 }
  }
  # 2.2.16 (Codex 2.2.15 F6): recording still filling toward its target (no problem found) = exit 3 (STILL FILLING), never 0 ("All good")
  elseif ($Mode -eq 'Recording' -and $r -and $r.PSObject.Properties['target_pending'] -and $r.target_pending) { $code = 3 }
} catch {
  $stopWhy = $_.Exception.Message; Say2 ('PROBLEM ' + $stopWhy) 'Red'; $code = 1
} finally {
  # 1.4: always log out of DW (DELETE session), also after an error
  try { $lo = Close-NvrSessions; if ($lo) { Say2 'Logged out of the DW server.' } } catch {}
}

# DW server (YKW Elm live test): list every camera that is offline / not recording / nothing for 24 h, with last recording + ping/ARP cause
$dwList = $null
$recR = $(if ($Mode -eq 'Site' -and $r -and $r.PSObject.Properties['recording']) { $r.recording } elseif ($Mode -eq 'Recording') { $r } else { $null })
$dwWhy = ''
if ($recR -and [string]$recR.vendor -eq 'DW') {
  # 1.6.1: without DW data (login refused / skipped / no answer / no cameras returned) the list is NOT CHECKED - never "0 offline"
  if (Test-TkNotChecked $recR) { $dwWhy = Get-TkNotCheckedWhy $recR }
  elseif (-not @($recR.channels).Count) { $dwWhy = 'DW returned no cameras' }
  if ($dwWhy) { Say2 ''; Say2 ('Offline in DW: NOT CHECKED (' + $dwWhy + ')') 'Yellow' }
  else { try { $dwList = @(Get-TkDwProblemCams @($recR.channels)) } catch { Say2 ('Offline in DW: could not build the list: ' + $_.Exception.Message) 'Yellow'; $dwList = $null; $dwWhy = 'could not build the list' } }
  if ($null -ne $dwList) {
    Say2 ''; Say2 ('Offline in DW (offline, not recording, or nothing recorded for 24 h): ' + $dwList.Count + ' camera(s)') 'Cyan'
    if ($dwList.Count) { foreach ($x in $dwList) { Say2 ('  ' + $x.t) 'Red' } } else { Say2 ('  none - all ' + @($recR.channels).Count + ' cameras online and recorded in the last 24 h.') 'Green' }
    Save-TkJson @($dwList | ForEach-Object { [ordered]@{ name = $_.name; ip = $_.ip; status = $_.status; hours = $_.hours; cause = $_.cause; t = $_.t } }) (Join-Path $run 'dw-offline.json')
  }
}
if ($Mode -eq 'Site') {
  $chk = New-TkSiteCheck -Health $r -Scan $scan -Upnp $ux -Site $Site -Ip $Ip -Dw $dwList -DwNotChecked $dwWhy -StopWhy $stopWhy
  Save-TkJson $chk (Join-Path $here 'logs\check-site-last.json'); Save-TkJson $chk (Join-Path $run 'check.json')
  Say2 ''; Say2 '===== CHECK THIS SITE: SUMMARY =====' 'Cyan'
  foreach ($l in @($chk.lines)) { Say2 $l.t $(switch ($l.k) { 'red' { 'Red' } 'ok' { 'Green' } 'warn' { 'Yellow' } default { '' } }) }
  if ($chk.pending) { Say2 ('STILL FILLING: ' + $chk.pendingWhy + ' - nothing broken found, but this is not an all-clear yet.') 'Yellow' }
  if (@($chk.page.notChecked).Count) { Say2 ('NOT CHECKED: ' + (@($chk.page.notChecked) -join ', ') + ' - this is not an all-clear.') 'Yellow' }
  if (@($chk.fixes).Count) { Say2 ('Fix buttons offered in the Toolkit: ' + (@($chk.fixes) -join ', ') + ' (each asks you first; nothing was changed).') 'Yellow' }
  if (-not $Site) { Say2 'Tip: type the site to save this check to the site page.' }
  elseif (-not $NoSend) {
    try {
      $my = @{ Ip = $Ip; Site = $Site; Mode = $Mode; ApiUrl = $ApiUrl; Vendor = $Vendor }; . (Join-Path $here 'CamViews.ps1') -Lib; $Ip = $my.Ip; $Site = $my.Site; $Mode = $my.Mode; $ApiUrl = $my.ApiUrl; $Vendor = $my.Vendor; $ErrorActionPreference = 'Stop'
      if ($ApiUrl) { $script:CvApi = $ApiUrl }
      $key = Get-CvKey
      if (-not $key) { Say2 'Not saved to the site page: no upload key on this PC (run "Set upload key.cmd" once).' 'Yellow' }
      else {
        $ans = Send-CvBody @{ op = 'toolkitCheck'; key = $key; site = $Site; pc = $env:COMPUTERNAME; check = $chk.page }
        if ($ans -and $ans.ok) { Say2 ('Saved as the "Latest check" on the site page: ' + [string]$ans.site + $(if ($ans.changed) { ' (something changed since the last check - noted in the site history)' } else { '' }) + '.') 'Green' }
        elseif ($ans -and [string]$ans.msg -match '^Unknown request') { Say2 'The site page shows the camera list part of this check (Latest check). The full check is saved on this PC (logs\check-site-last.json); the site page takes the full check after its next update.' 'Yellow' }
        elseif ($ans) { Say2 ('Not saved to the site page: ' + [string]$ans.msg) 'Yellow' } else { Say2 'Not saved to the site page: no answer (no internet?).' 'Yellow' }
      }
    } catch { Say2 ('Not saved to the site page: ' + $_.Exception.Message) 'Yellow' }
  }
  # 2.2.16 (Codex 2.2.15 F6): only "still filling" left (nothing red, nothing NOT CHECKED) = exit 3, anything else not ok = 4
  if ($code -eq 0 -and -not $chk.ok) { if ($chk.pending -and -not @($chk.lines | Where-Object { $_.k -eq 'red' }).Count -and -not @($chk.page.notChecked).Count) { $code = 3 } else { $code = 4 } }
}
Set-Content -Path (Join-Path $run 'result.json') -Value (@{ mode = $Mode; ip = $Ip; site = $Site; days = $Days; code = $code; finished = (Get-Date -Format s) } | ConvertTo-Json)
Done $code
