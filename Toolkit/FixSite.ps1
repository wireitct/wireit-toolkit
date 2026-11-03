<#
 FixSite.ps1 - WireIt Toolkit 2.0: "Fix this site". ONE button, no order to figure out.
 Moshe, Nov 3 2026: "Diagnosing doesn't help... It would only help me to actually fix the cameras." / "I just want to do this with one click."

 What it does, in this order, by itself:
   1. Reads what SHOULD be here: the site list in the site's Drive folder (Docs\WireIt site list.json, or the Fix NVR install
      snapshot), with switch + port from PortMap when this is the office Dell.
   2. Looks at what IS here: every camera and NVR (Hikvision SADP, Dahua search, network sweep, the NVR's channel list),
      even on the wrong IP scheme, and logs in with the site's saved passwords only (a short, fixed list - never guessing).
   3. Asks ONE question if some passwords are unknown: type it, or Enter for the official reset.
   4. Shows ONLY the problems and what it will change. Healthy cameras are one line. You type YES once.
   5. Then, one camera at a time: backup -> site password -> camera settings -> move to the right address -> back on the NVR
      -> restart / switch-port power-cycle if hung -> waits until the NVR shows video for 20 s -> check mark.
   6. Missing cameras: "should be on <switch> port 10 - go check port 10" (power-cycles that port first when it can).
   7. Offers to save what it found as the site's list, and to put the site password in Bitwarden.
 Every step reads first and skips what is already right, so running it twice is safe. Backups + rollback file in runs\FixSite-<time>.
 Modes: Fix (default) | Plan (look only) | DryRun (-Recorded <scan.json>, no network at all) | Rollback (-RollbackDir) | SetUsual
 Passwords: typed hidden, kept only in the encrypted site store on this PC (secrets\), never in a log, a file, Drive or a chat.
#>
param(
  [ValidateSet('Fix', 'Plan', 'DryRun', 'Rollback', 'SetUsual')][string]$Mode = 'Fix',
  [string]$Site = '',
  [string]$Recorded = '',           # DryRun: a recorded scan (tests\fixsite\*.json)
  [string]$ListFile = '',           # use this site list instead of the Drive one
  [string]$Codec = 'auto', [int]$Fps = 0, [string]$Resolution = 'keep', [int]$Bitrate = 0,
  [string]$RollbackDir = '',
  [string]$ConfigPath = '', [string]$SecretsDir = '', [string]$RunsRoot = '', [string]$SitesDir = '',
  [string]$MockUrl = '',            # TEST HARNESS ONLY: all device calls go to tests\fixsite\mock_site.py
  [string]$Answers = '',            # TEST HARNESS ONLY: answers to the questions, one per line
  [int]$CloseAfter = 0
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'FixSiteCore.ps1')
. (Join-Path $here 'FixSiteDevices.ps1')
if (Test-Path (Join-Path $here 'ToolkitCore.ps1')) { . (Join-Path $here 'ToolkitCore.ps1') }
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ---------------- settings ----------------
$root = Split-Path -Parent $here
if (-not $ConfigPath) { $ConfigPath = Join-Path $here 'config.json' }
$cfgAll = $null; if (Test-Path $ConfigPath) { try { $cfgAll = Get-Content $ConfigPath -Raw | ConvertFrom-Json } catch {} }
$fsCfg = $null; if ($cfgAll -and $cfgAll.PSObject.Properties['fixSite']) { $fsCfg = $cfgAll.fixSite }
$driveRoots = @('G:\My Drive\WireIt Sites', '%USERPROFILE%\My Drive\WireIt Sites', 'C:\Users\admin\My Drive\WireIt Sites')
if ($fsCfg -and $fsCfg.PSObject.Properties['driveRoots']) { $driveRoots = @($fsCfg.driveRoots) }
$opts = Merge-FsOptions $fsCfg
$opts.settings.codec = $Codec; $opts.settings.fps = $Fps; $opts.settings.resolution = $Resolution; $opts.settings.bitrate = $Bitrate
if (-not $SecretsDir) { $SecretsDir = Join-Path $here 'secrets' }
if (-not $RunsRoot) { $RunsRoot = Join-Path $here 'runs' }
if (-not $SitesDir) { $SitesDir = Join-Path $here 'sites' }
$camResetDir = Join-Path $root 'CamReset'; $portMapDir = Join-Path $root 'PortMap'
if ($MockUrl) { $script:FsMockUrl = $MockUrl; $script:FsTestSecrets = $true }
if ($Mode -eq 'DryRun') { $script:FsTestSecrets = $true }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path $RunsRoot ('FixSite-' + $stamp); New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$logFile = Join-Path $runDir 'log.txt'
$tempState = Join-Path (Join-Path (Split-Path -Parent $RunsRoot) 'state') 'fixsite-temp-ips.json'; New-Item -ItemType Directory -Force -Path (Split-Path $tempState) | Out-Null
$script:Secrets = @()   # every password this run has handled: scrubbed from anything written
function Fs-Redact([string]$s) { foreach ($p in $script:Secrets) { if ($p -and $p.Length -ge 4) { $s = $s.Replace($p, '****') } }; return $s }
function Fs-Log([string]$s) { try { $fs = [IO.File]::Open($logFile, 'Append', 'Write', 'ReadWrite'); $b = [Text.Encoding]::UTF8.GetBytes((Get-Date -Format 'HH:mm:ss') + ' ' + (Fs-Redact $s) + "`r`n"); $fs.Write($b, 0, $b.Length); $fs.Close() } catch {} }
# the old blue console (conhost) shows emoji as boxes: there the marks are [OK] / [X]; the log (and the Toolkit window) keep the real marks
$script:FsPlainMarks = (-not $env:WT_SESSION) -and ($PSVersionTable.PSVersion.Major -lt 6)
function Say([string]$s, [string]$color = '') { $s = Fs-Redact $s; $show = $(if ($script:FsPlainMarks) { $s.Replace([string][char]0x2705, '[OK]').Replace([string][char]0x274C, '[X]') } else { $s }); if ($color) { Write-Host $show -ForegroundColor $color } else { Write-Host $show }; Fs-Log ('SAY ' + $s) }
$script:AnswerQ = New-Object System.Collections.Queue
if ($Answers -and (Test-Path $Answers)) { foreach ($l in (Get-Content $Answers)) { $script:AnswerQ.Enqueue($l) } }
function Ask([string]$q, [switch]$Secret) {
  Write-Host ''; Write-Host $q -ForegroundColor Yellow; Fs-Log ('ASK ' + $q)
  if ($Answers) { $a = ''; if ($script:AnswerQ.Count) { $a = [string]$script:AnswerQ.Dequeue() }; Fs-Log ('ANSWER ' + $(if ($Secret) { '(hidden)' } else { $a })); return $a }
  if ($Secret) { $ss = Read-Host -AsSecureString '>'; $a = (New-Object PSCredential('x', $ss)).GetNetworkCredential().Password; Fs-Log 'ANSWER (hidden)'; return $a }
  $a = Read-Host '>'; Fs-Log ('ANSWER ' + $a); return $a
}
function Remember-Secret([string]$p) { if ($p) { $script:Secrets += $p } }
function Set-Clip([string]$s) { if ($MockUrl -or $Answers) { return }; try { Set-Clipboard -Value $s } catch {} }
function Clear-Clip { if ($MockUrl -or $Answers) { return }; try { Set-Clipboard -Value ' ' } catch {} }
function Done([int]$code) {
  Remove-FsTempIps $tempState
  if ($CloseAfter -gt 0) { Write-Host ''; Write-Host ('This window closes in ' + $CloseAfter + ' seconds.'); Start-Sleep -Seconds $CloseAfter }
  elseif (-not $Answers -and -not $MockUrl -and $Mode -ne 'DryRun') { Write-Host ''; [void](Read-Host 'Press Enter to close this window') }
  exit $code
}

Write-Host ''
Write-Host ('=== WireIt Toolkit ' + $script:FsVersion + ' - Fix this site' + $(if ($Site) { ' - ' + $Site } else { '' }) + ' ===') -ForegroundColor Cyan
Fs-Log ('start mode=' + $Mode + ' site=' + $Site + ' ps=' + $PSVersionTable.PSVersion + ' pc=' + $env:COMPUTERNAME)
Clear-FsLeftoverTemps $tempState

if ($Mode -eq 'SetUsual') {
  Say 'WireIt''s usual camera passwords (the ones we use on most sites). They are tried first on every site, before asking you.'
  Say 'Type up to 3, one at a time (hidden). Enter on an empty line = done. They are kept encrypted on this PC only.'
  $l = @(); for ($i = 1; $i -le 3; $i++) { $p = Ask ('Usual password ' + $i + ' (Enter = done):') -Secret; if (-not $p) { break }; $l += $p }
  if ($l.Count) { Save-FsUsual $SecretsDir $l; Say ('Saved ' + $l.Count + ' usual password(s).') 'Green' } else { Say 'Nothing changed.' }
  Done 0
}

# ---------------- the site and its list ----------------
if (-not $Site) { $Site = (Ask 'Which site? Type the Site ID from the QR sticker (e.g. WI-061) or the address (e.g. 3 Hewlett St):').Trim() }
if (-not $Site) { Say 'No site typed - nothing was done.' 'Yellow'; Done 2 }
$siteFolder = Find-FsSiteFolder $Site $driveRoots
$siteName = $(if ($siteFolder) { Split-Path -Leaf $siteFolder } else { $Site })
$siteId = $(if ($Site -match '^(?i)WI-\d+$') { $Site.ToUpper() } else { '' })
$listPath = $(if ($siteFolder) { Join-Path (Join-Path $siteFolder 'Docs') 'WireIt site list.json' } else { '' })
$localList = Join-Path $SitesDir ((($siteName -replace '[^A-Za-z0-9_-]+', '_').Trim('_')) + '.json')
$list = $null; $listFrom = ''
foreach ($cand in @($ListFile, $listPath, $localList)) { if ($cand -and (Test-Path -LiteralPath $cand)) { try { $list = Get-Content -LiteralPath $cand -Raw | ConvertFrom-Json; $listFrom = $cand; break } catch {} } }
if (-not $list -and $siteFolder) {
  $snap = Get-ChildItem -LiteralPath (Join-Path $siteFolder 'Docs') -Filter 'FixNVR snapshot*.json' -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
  if ($snap) { try { $list = ConvertFrom-FsSnapshot (Get-Content -LiteralPath $snap.FullName -Raw | ConvertFrom-Json); $listFrom = $snap.FullName } catch {} }
}
if ($list -and -not $siteId -and $list.PSObject.Properties['siteId'] -and $list.siteId) { $siteId = [string]$list.siteId }
# PortMap (office Dell only): camera -> switch + port
$pmSite = $null
if (Test-Path (Join-Path $portMapDir 'out')) {
  foreach ($f in @(Get-ChildItem (Join-Path $portMapDir 'out') -Filter 'WI-*.json' -ErrorAction SilentlyContinue)) {
    try { $j = Get-Content $f.FullName -Raw | ConvertFrom-Json; if (($siteId -and $j.site_id -eq $siteId) -or ([string]$j.site -like ('*' + $Site + '*'))) { $pmSite = $j; if (-not $siteId) { $siteId = [string]$j.site_id }; break } } catch {}
  }
}
if ($list -and $pmSite) { $list = Add-FsPortMap $list $pmSite }
Say ('Site: ' + $siteName + $(if ($siteId) { ' (' + $siteId + ')' } else { '' }))
if ($list) { Say ('What should be here: ' + @($list.cameras).Count + ' camera(s) from ' + $(if ($listFrom -like '*snapshot*') { 'the install snapshot' } elseif ($listFrom -eq $localList) { 'this PC''s copy of the site list' } else { 'the site list' }) + '.') }
else { Say 'This site has no camera list yet - the Toolkit will offer to save one at the end.' 'Yellow' }

$sec = Read-FsSecrets $SecretsDir $siteName
foreach ($p in @($sec.password) + @($sec.known) + @($sec.usual)) { Remember-Secret $p }

# =====================================================================================
#  ROLLBACK: put everything back the way a Fix run found it (-RollbackDir runs\FixSite-<time>)
# =====================================================================================
if ($Mode -eq 'Rollback') {
  $rf = Join-Path $RollbackDir 'rollback.json'
  if (-not $RollbackDir -or -not (Test-Path $rf)) { Say 'Pick a Fix this site run folder that has rollback.json in it.' 'Red'; Done 2 }
  $r0 = Get-Content $rf -Raw | ConvertFrom-Json; $run = [string]$r0.run
  $old = @{}; if ($sec.rollback -and $sec.rollback.ContainsKey($run)) { $o = $sec.rollback[$run]; if ($o -is [Collections.IDictionary]) { foreach ($k in $o.Keys) { $old[$k] = $o[$k] } } else { foreach ($q in $o.PSObject.Properties) { $old[$q.Name] = $q.Value } } }
  foreach ($v in $old.Values) { Remember-Secret ([string]$v) }
  Say ('Undo of the run from ' + $run + ' on ' + [string]$r0.taken_on + ': ' + @($r0.cameras).Count + ' camera(s), ' + @($r0.nvrs).Count + ' NVR move(s).')
  if ((Ask 'Type YES to put them back the way that run found them.').Trim() -notmatch '^(?i)yes$') { Say 'Stopped - nothing changed.'; Done 2 }
  $pc = $(if ($Mode -ne 'DryRun') { Get-FsPcNet } else { $null })
  $nvrPwR = @{}; foreach ($k in @($sec.nvr.Keys)) { $nvrPwR[$k] = [string]$sec.nvr[$k] }
  $bad = 0
  $rcams = @($r0.cameras); [array]::Reverse($rcams)
  foreach ($c in $rcams) {
    if (-not $c) { continue }
    $ip = $(if ($c.ip_after) { [string]$c.ip_after } else { [string]$c.ip_before }); $res = @()
    if ((Get-FsP3 $ip) -ne (Get-FsP3 $pc.gw)) { [void](Add-FsTempIp (Get-FsP3 $ip) $pc $tempState) }
    $oldPw = $(if ($old.ContainsKey([string]$c.mac + '|' + [string]$c.ip_before)) { [string]$old[[string]$c.mac + '|' + [string]$c.ip_before] } else { '' })
    $pw = ''; foreach ($cand in @($sec.password, $oldPw)) { if ($cand -and (Test-FsLogin $ip $c.brand $cand) -eq 'ok') { $pw = $cand; break } }
    if (-not $pw) { Say ('  ' + $c.name + ': cannot log in at ' + $ip + ' - not undone ' + $script:FsBad) 'Red'; $bad++; continue }
    $cr = Fs-Cred $pw
    if ($c.stream_before) { $cur = Get-FsStream $ip $c.brand $cr; $want = [pscustomobject]@{ codec = [string]$c.stream_before.codec; fps = [int]$c.stream_before.fps; resolution = $(if ($c.stream_before.width) { '' + $c.stream_before.width + 'x' + $c.stream_before.height } else { 'keep' }); bitrate = [int]$c.stream_before.bitrate; gop = 0; smartCodec = 'keep' }
      $diff = @(Get-FsSettingsDiff $cur $want); if ([int]$c.stream_before.gop -and $cur -and [int]$cur.gop -ne [int]$c.stream_before.gop) { $diff += [pscustomobject]@{ field = 'gop'; from = $cur.gop; to = [int]$c.stream_before.gop } }
      if ([string]$c.stream_before.smartCodec -eq 'on' -and $cur.smartCodec -eq 'off') { $diff += [pscustomobject]@{ field = 'smartCodecOn'; from = 'off'; to = 'on' } }
      $diff = @($diff | Where-Object { $_.field -ne 'smartCodecOn' })   # Smart Codec back on: by hand (it was the cause on BYW)
      if ($diff.Count) { $w = Set-FsStream $ip $c.brand $cr $cur $diff; $res += [pscustomobject]@{ text = 'settings back'; ok = [bool]$w.ok } } }
    if ($c.password_changed -and $oldPw) { $ok = Set-FsPassword $ip $c.brand $cr $oldPw; if ($ok) { $pw = $oldPw; $cr = Fs-Cred $pw }; $res += [pscustomobject]@{ text = 'old password back'; ok = $ok } }
    if ($c.net_before -and $c.ip_after -and $c.ip_after -ne $c.ip_before) {
      $net = Get-FsNet $ip $c.brand $cr; [void](Add-FsTempIp (Get-FsP3 ([string]$c.net_before.ip)) $pc $tempState)
      $w = Set-FsNet $ip $c.brand $cr $net ([string]$c.net_before.ip) ([string]$c.net_before.mask) ([string]$c.net_before.gw) ([string]$c.net_before.dns1) ([string]$c.net_before.dns2)
      if ($w.ok -and $w.reboot) { [void](Restart-FsDevice $ip $c.brand $cr) }
      $back = $w.ok -and (Wait-FsDevice ([string]$c.net_before.ip) $c.brand $pw ([int]$opts.moveWaitSec)); $res += [pscustomobject]@{ text = ('address back to ' + $c.net_before.ip); ok = $back }
    }
    if ($c.nvr -and $c.nvr.nvr -and $nvrPwR.ContainsKey([string]$c.nvr.nvr)) {
      $w = Set-FsNvrChannel ([string]$c.nvr.nvr) (Fs-Cred $nvrPwR[[string]$c.nvr.nvr]) ([int]$c.nvr.channel) ([string]$c.ip_before) $pw $c.brand ''
      $res += [pscustomobject]@{ text = ('NVR ch ' + $c.nvr.channel + ' back to ' + $c.ip_before); ok = [bool]$w.ok }
    }
    $line = Format-FsCheckLine $c.name $res; if ($line -like ('*' + $script:FsBad + '*')) { $bad++ }; Say ('  ' + $line)
  }
  foreach ($n in @($r0.nvrs)) {
    if (-not $nvrPwR.ContainsKey([string]$n.target)) { Say ('  NVR ' + $n.target + ': no saved login - move it back by hand to ' + $n.old.ip) 'Yellow'; $bad++; continue }
    $cr = Fs-Cred $nvrPwR[[string]$n.target]; $net = Get-FsNet ([string]$n.target) 'Hikvision' $cr; [void](Add-FsTempIp (Get-FsP3 ([string]$n.old.ip)) $pc $tempState)
    $w = Set-FsNet ([string]$n.target) 'Hikvision' $cr $net ([string]$n.old.ip) ([string]$n.old.mask) ([string]$n.old.gw) ([string]$n.old.dns1) ([string]$n.old.dns2)
    Say ('  NVR: back to ' + $n.old.ip + ' ' + $(if ($w.ok) { $script:FsOk } else { $script:FsBad }))
  }
  Remove-FsTempIps $tempState
  [IO.File]::WriteAllText((Join-Path $RollbackDir 'undone.txt'), (Get-Date -Format 's'))
  Say $(if ($bad) { 'Undo finished with ' + $bad + ' problem(s) above.' } else { 'Undo finished: everything is back.' }) $(if ($bad) { 'Yellow' } else { 'Green' })
  Done $(if ($bad) { 4 } else { 0 })
}
# =====================================================================================
#  LOOK (read-only)
# =====================================================================================
$pwFor = @{}     # mac/ip -> the password that works (memory only)
$nvrPw = @{}     # nvr ip -> password
if ($Mode -eq 'DryRun') {
  if (-not $Recorded -or -not (Test-Path $Recorded)) { Say 'Dry run needs -Recorded <scan file>.' 'Red'; Done 2 }
  $observed = Get-Content $Recorded -Raw | ConvertFrom-Json
  Say ('DRY RUN from a recorded scan (' + (Split-Path -Leaf $Recorded) + ', taken ' + [string]$observed.taken + '). Nothing on the network is touched.') 'Cyan'
} else {
  if (-not $MockUrl) {
    $adm = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $adm) { Say 'Please start it from the Toolkit (it asks Windows for permission): it needs that to reach cameras on the wrong IP scheme.' 'Red'; Done 2 }
  }
  Say 'Looking at the site network (about a minute). Nothing is changed yet.'
  $pc = Get-FsPcNet
  if (-not $pc -or -not $pc.gw) { Say 'This PC is not on a network with a router. Plug it into the site network (or its Wi-Fi) and press the button again.' 'Red'; Done 2 }
  $scheme = Get-FsP3 $pc.gw
  $observed = [ordered]@{ taken = (Get-Date -Format 's'); pc = [ordered]@{ ip = $pc.ip; gw = $pc.gw; mask = $pc.mask; dhcp = $pc.dhcp }; devices = @(); nvrs = @(); ports = @{} }
  # 1. discovery: Find cameras (SADP + ONVIF + sweep) and the Dahua search
  $found = @()
  if ($MockUrl) { $fj = (Fs-Http -Ip '_pc' -Path '/scan').body | ConvertFrom-Json; $found = @($fj) }   # PS 5.1: @(json-array | ConvertFrom-Json) is ONE item
  else {
    $fc = Join-Path $camResetDir 'Find-Cameras.ps1'
    if (Test-Path $fc) {
      $psexe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
      $null = & $psexe -NoProfile -ExecutionPolicy Bypass -File $fc -NoLogin 2>&1
      foreach ($d in @(Get-TkScanDevices $camResetDir)) { $found += [pscustomobject]@{ brand = $d.brand; model = $d.model; serial = $d.serial; mac = $d.mac; ip = $d.ip; firmware = $d.firmware; kind = $(if ($d.kind -eq 'recorder') { 'nvr' } else { $d.kind }); activated = $true } }
      try { $raw = Get-Content (Join-Path $camResetDir 'out\latest.json') -Raw | ConvertFrom-Json; foreach ($d in @($raw.devices)) { if ([string]$d.Activated -match '(?i)false|no') { foreach ($f in $found) { if ($f.ip -eq $d.IP) { $f.activated = $false } } } } } catch {}
    } else { Say 'Find cameras is not on this PC (C:\WireIt\CamReset), so only the NVR''s list and the site list are used.' 'Yellow' }
    foreach ($d in @(Find-FsDahua)) { if (-not @($found | Where-Object { $_.ip -eq $d.ip }).Count) { $found += $d } }
  }
  # list addresses nobody answered for: try them too (a camera can miss the discovery)
  foreach ($c in @($(if ($list) { $list.cameras } else { @() }))) { $lip = [string]$c.ip; if ($lip -and -not @($found | Where-Object { $_.ip -eq $lip }).Count -and (Get-FsP3 $lip) -eq $scheme) { $s = Test-FsLogin $lip (Get-FsBrand ([string]$c.brand) ([string]$c.model)) ''; if ($s -ne 'noanswer') { $found += [pscustomobject]@{ brand = (Get-FsBrand ([string]$c.brand) ([string]$c.model)); model = [string]$c.model; serial = [string]$c.serial; mac = [string]$c.mac; ip = $lip; kind = 'camera'; activated = $true } } } }
  $found = @($found | Where-Object { $_.ip -and $_.ip -ne $pc.ip -and $_.ip -ne $pc.gw -and ($_.kind -in @('camera', 'nvr')) })
  # 2. reach the wrong schemes (temporary PC address, removed at the end)
  $schemes = @($found | ForEach-Object { Get-FsP3 $_.ip } | Where-Object { $_ -and $_ -ne $scheme -and -not (Test-FsPoeNet ($_ + '.1')) } | Select-Object -Unique | Select-Object -First 3)
  foreach ($p3 in $schemes) { $t = Add-FsTempIp $p3 $pc $tempState; if ($t) { Fs-Log ('temp address ' + $t + ' added') } else { Say ('Could not give this PC a temporary address on ' + $p3 + '.x - cameras there can only be listed.') 'Yellow' } }
  $reach = { param($ip) $p3 = Get-FsP3 $ip; return ($p3 -eq $scheme -or @($script:FsTemps | Where-Object { $_.p3 -eq $p3 }).Count -gt 0) }
  # 3. NVRs: log in (saved passwords, then ONE question), read the channel list
  $nvrIps = @($found | Where-Object { $_.kind -eq 'nvr' } | ForEach-Object { $_.ip })
  if ($list) { foreach ($n in @($list.nvrs)) { if ($n.ip -and $nvrIps -notcontains [string]$n.ip -and (& $reach ([string]$n.ip)) -and (Test-FsLogin ([string]$n.ip) 'Hikvision' '') -ne 'noanswer') { $nvrIps += [string]$n.ip } } }
  foreach ($nip in $nvrIps) {
    $cands = @(); if ($sec.nvr -and $sec.nvr.ContainsKey($nip)) { $cands += [pscustomobject]@{ label = 'saved NVR password'; value = [string]$sec.nvr[$nip] } }
    $cands += @(Get-FsPasswordCandidates $sec ([int]$opts.maxPasswordTries - 1))
    $fp = Find-FsPassword $nip 'Hikvision' $cands ([int]$opts.maxPasswordTries - 1)
    if ($fp.state -ne 'ok' -and $fp.state -ne 'noanswer' -and $fp.state -ne 'locked') {
      $typed = Ask ('Type the password of the NVR at ' + $nip + ' (hidden; Enter = skip - then cameras cannot be put back on it):') -Secret
      if ($typed) { Remember-Secret $typed; if ((Test-FsLogin $nip 'Hikvision' $typed) -eq 'ok') { $fp = [pscustomobject]@{ state = 'ok'; label = 'typed'; value = $typed } } else { Say 'That NVR password did not work (not tried again, so it does not lock).' 'Yellow' } }
    }
    $nobj = [ordered]@{ ip = $nip; brand = 'Hikvision'; model = ''; mac = ''; login = $(if ($fp.state -eq 'ok') { $fp.label } elseif ($fp.state -eq 'locked') { 'locked' } else { 'unknown' }); channels = @() }
    $fd = @($found | Where-Object { $_.ip -eq $nip })[0]; if ($fd) { $nobj.model = $fd.model; $nobj.mac = $fd.mac; $nobj.brand = (Get-FsBrand $fd.brand $fd.model) }
    if ($fp.state -eq 'ok') {
      $nvrPw[$nip] = $fp.value; $sec.nvr[$nip] = $fp.value
      $chs = @(Get-FsNvrChannels $nip (Fs-Cred $fp.value)); $nobj.channels = @($chs | ForEach-Object { [ordered]@{ channel = $_.channel; ip = $_.ip; online = $_.online; name = $_.name; protocol = $_.protocol } })
      Say ('NVR ' + $nip + ': ' + $chs.Count + ' camera channel(s), ' + @($chs | Where-Object { $_.online -eq $false }).Count + ' without video.')
    } else { Say ('NVR ' + $nip + ': could not log in, so its channel list is not read.') 'Yellow' }
    $observed.nvrs += [pscustomobject]$nobj
  }
  # 4. cameras: log in with the saved passwords only (short fixed list, stops at a lock), read the video settings
  $cams = @($found | Where-Object { $_.kind -eq 'camera' })
  foreach ($d in $found) {
    $o = [ordered]@{ brand = (Get-FsBrand $d.brand $d.model $d.mac); model = $d.model; serial = $d.serial; mac = $d.mac; ip = $d.ip; firmware = $d.firmware; kind = $d.kind; activated = $d.activated; answers = $true; login = ''; streams = $null; dhcp = $false }
    if ($d.kind -eq 'nvr') { $o.login = @($observed.nvrs | Where-Object { $_.ip -eq $d.ip } | ForEach-Object { $_.login })[0]; $observed.devices += [pscustomobject]$o; continue }
    if (Test-FsPoeNet $d.ip) { $observed.devices += [pscustomobject]$o; continue }
    if (-not (& $reach $d.ip)) { $o.login = 'unreachable'; $observed.devices += [pscustomobject]$o; continue }
    if ($d.activated -eq $false) { $observed.devices += [pscustomobject]$o; continue }
    $fp = Find-FsPassword $d.ip $o.brand @(Get-FsPasswordCandidates $sec ([int]$opts.maxPasswordTries - 1)) ([int]$opts.maxPasswordTries - 1)
    if ($fp.state -eq 'noanswer') { $o.answers = $false; $o.login = '' }
    elseif ($fp.state -eq 'ok') {
      $o.login = $fp.label; $pwFor[$d.ip] = $fp.value; $cr = Fs-Cred $fp.value
      $st = Get-FsStream $d.ip $o.brand $cr; if ($st) { $o.streams = [ordered]@{ codec = $st.codec; fps = $st.fps; width = $st.width; height = $st.height; bitrate = $st.bitrate; gop = $st.gop; smartCodec = $st.smartCodec; maxWidth = $st.maxWidth; maxHeight = $st.maxHeight } }
      $nt = Get-FsNet $d.ip $o.brand $cr; if ($nt) { $o.dhcp = [bool]$nt.dhcp; if (-not $o.mac -and $o.brand -eq 'Hikvision') { $o.mac = (Get-FsInfo $d.ip $o.brand $cr).mac } }
    } else { $o.login = $fp.state; $o.tries = $fp.tries }
    $observed.devices += [pscustomobject]$o
  }
  if ($pmSite) { $observed.ports = Get-FsPortsFromPortMap $pmSite }
  # 5. ONE question for the unknown passwords (Moshe Nov 3 5:24 PM: "sometimes I will know")
  $unk = @($observed.devices | Where-Object { $_.kind -eq 'camera' -and $_.login -in @('unknown', 'refused') })
  if ($unk.Count) {
    $chNames = @{}; foreach ($nv in @($observed.nvrs)) { foreach ($cc in @($nv.channels)) { if ($cc.ip -and $cc.name) { $chNames[[string]$cc.ip] = [string]$cc.name } } }
    $names = @($unk | ForEach-Object { if ($chNames.ContainsKey([string]$_.ip)) { $chNames[[string]$_.ip] + ' ' + $_.ip } else { $_.ip } })
    $typed = Ask ('Know the password for ' + $(if ($unk.Count -eq 1) { 'this camera' } else { 'these ' + $unk.Count + ' cameras' }) + ' (' + ($names -join ', ') + ')? Type it (hidden), or press Enter to skip - they get the official reset.') -Secret
    if ($typed) {
      Remember-Secret $typed; $worked = 0
      foreach ($u in $unk) { if ([int]$u.tries -ge [int]$opts.maxPasswordTries) { continue }; $s = Test-FsLogin $u.ip $u.brand $typed; if ($s -eq 'ok') { $u.login = 'typed'; $pwFor[$u.ip] = $typed; $worked++; $cr = Fs-Cred $typed; $st = Get-FsStream $u.ip $u.brand $cr; if ($st) { $u.streams = [ordered]@{ codec = $st.codec; fps = $st.fps; width = $st.width; height = $st.height; bitrate = $st.bitrate; gop = $st.gop; smartCodec = $st.smartCodec; maxWidth = $st.maxWidth; maxHeight = $st.maxHeight } } } elseif ($s -eq 'locked') { $u.login = 'locked' } }
      if ($worked) { if (@($sec.known) -notcontains $typed) { $sec.known = @($sec.known) + @($typed) }; Save-FsSecrets $SecretsDir $sec; Say ('That password works on ' + $worked + ' of ' + $unk.Count + '. Saved to the site''s secret store (encrypted, this PC only).') 'Green' }
      else { Say 'That password did not work on them (tried once each). They get the official reset.' 'Yellow' }
    }
  }
  ($observed | ConvertTo-Json -Depth 8) | Set-Content -Path (Join-Path $runDir 'scan.json') -Encoding UTF8   # no passwords in it: logins are labels only
}

# =====================================================================================
#  PLAN
# =====================================================================================
$plan = New-FsPlan $list $observed $opts
$plan.site = $siteName
($plan | ConvertTo-Json -Depth 8) | Set-Content -Path (Join-Path $runDir 'plan.json') -Encoding UTF8
Write-Host ''
Say '----- What is wrong, and what it will do -----' 'Cyan'
foreach ($l in (Format-FsPlan $plan)) { Say ('  ' + $l) }
$work = @($plan.cams | Where-Object { $_.state -eq 'fix' -or ($_.state -eq 'missing' -and $_.steps.Count) }) + @($plan.nvrs | Where-Object { $_.steps -contains 'move' })
function Offer-List {
  if ($Mode -eq 'DryRun') { if (-not $list) { Say '(dry run) At the end it would offer: "Save this as the site''s list?"' }; return }
  $newOnes = @($plan.cams | Where-Object { -not $_.onList -and $_.state -ne 'missing' })
  if ($list -and -not $newOnes.Count -and $listFrom -notlike '*snapshot*') { return }
  $q = $(if (-not $list -or $listFrom -like '*snapshot*') { 'Save this as the site''s list (' + @($plan.cams).Count + ' cameras, no passwords)? Then next time it knows what should be here. Type Y to save.' } else { 'Add the ' + $newOnes.Count + ' camera(s) that are not on the site list to it? Type Y to add.' })
  if ((Ask $q) -notmatch '^(?i)y') { return }
  $nl = New-FsSiteList $siteName $siteId $plan $observed
  if ($list -and $listFrom -notlike '*snapshot*') { $keep = @($list.cameras); foreach ($c in $nl.cameras) { if (-not @($keep | Where-Object { (ConvertTo-FsMac ([string]$_.mac)) -and (ConvertTo-FsMac ([string]$_.mac)) -eq $c.mac }).Count) { $keep += $c } }; $nl.cameras = $keep }
  $json = $nl | ConvertTo-Json -Depth 6
  New-Item -ItemType Directory -Force -Path (Split-Path $localList) | Out-Null; $json | Set-Content -LiteralPath $localList -Encoding UTF8
  if ($listPath) { try { New-Item -ItemType Directory -Force -Path (Split-Path $listPath) | Out-Null; $json | Set-Content -LiteralPath $listPath -Encoding UTF8; Say ('Saved the site list to the site''s Drive folder (Docs\WireIt site list.json).') 'Green' } catch { Say ('Could not write to the Drive folder - saved on this PC: ' + $localList) 'Yellow' } }
  else { Say ('Saved on this PC (no Drive folder found for "' + $Site + '"): ' + $localList + '. Copy it into the site''s Drive folder, Docs.') 'Yellow' }
}
if (-not $work.Count) {
  Say ''; Say 'Nothing for the Toolkit to change.' 'Green'
  foreach ($c in @($plan.cams | Where-Object { $_.state -eq 'missing' })) { Say ('  Go check: ' + $c.name + ' - ' + ($c.why -join '; ')) 'Yellow' }
  Offer-List; Done $(if (@($plan.cams | Where-Object { $_.state -in @('missing', 'manual') }).Count) { 4 } else { 0 })
}
if ($Mode -eq 'Plan') { Say ''; Say 'Look-only run: nothing was changed.'; Done 0 }

# =====================================================================================
#  ONE confirm
# =====================================================================================
if ($Mode -ne 'DryRun') {
  $a = Ask ('Type YES to fix all of this (one camera at a time; backups first). Anything else = stop, nothing changed.')
  if ($a.Trim() -cne 'YES' -and $a.Trim() -ne 'yes') { Say 'Stopped - nothing was changed.'; Done 2 }
}
# the site password: made once per site, saved BEFORE anything changes, so it is never lost
$newPw = $false
if (-not $sec.password) { $sec.password = New-FsSitePassword; $sec.bitwardenSaved = $false; $newPw = $true; Remember-Secret $sec.password; if ($Mode -ne 'DryRun') { Save-FsSecrets $SecretsDir $sec } }
$sitePw = $sec.password; Remember-Secret $sitePw
$rb = [ordered]@{ tool = ('WireIt Toolkit ' + $script:FsVersion + ' Fix this site'); site = $siteName; run = $stamp; taken_on = $env:COMPUTERNAME; note = 'Old passwords are NOT in this file: they are in the site secret store on this PC (encrypted), under this run.'; nvrs = @(); cameras = @() }
$rbPath = Join-Path $runDir 'rollback.json'
function Save-Rb { ($rb | ConvertTo-Json -Depth 8) | Set-Content -Path $rbPath -Encoding UTF8 }
if (-not $sec.rollback) { $sec.rollback = @{} }
$sec.rollback[$stamp] = @{}
$results = @(); $okCount = 0; $badCount = 0

# ---------------- DRY RUN: say exactly what would happen, in order ----------------
if ($Mode -eq 'DryRun') {
  Say ''; Say '----- (dry run) It would do this, one camera at a time -----' 'Cyan'
  foreach ($n in @($plan.nvrs | Where-Object { $_.steps -contains 'move' })) { Say ('  NVR ' + $n.ip + ': backup, move -> ' + $n.target + ', wait until it answers there') }
  foreach ($c in @($plan.cams | Where-Object { $_.state -eq 'fix' } | Sort-Object { Get-FsOrderKey $_ })) {
    $r = @(); foreach ($s in $c.steps) { switch ($s) {
      'backup' { $r += [pscustomobject]@{ text = 'backup saved'; ok = $null } } 'password' { $r += [pscustomobject]@{ text = 'password set'; ok = $null } }
      'reset' { $r += [pscustomobject]@{ text = 'official reset (asks you one step)'; ok = $null } } 'activate' { $r += [pscustomobject]@{ text = 'activate (asks you one step)'; ok = $null } }
      'settings' { $r += [pscustomobject]@{ text = $(if ($c.why -match '^settings: ') { (($c.why -match '^settings: ')[0] -replace '^settings: ', '') } else { 'settings checked' }); ok = $null } }
      'move' { $r += [pscustomobject]@{ text = $(if ($c.target -ne $c.ip) { 'moved ' + (Get-FsShort $c.ip) + ' -> ' + (Get-FsShort $c.target) } else { 'address set fixed' }); ok = $null } }
      'nvr' { $r += [pscustomobject]@{ text = $(if ($c.channel) { 'back on NVR ch ' + $c.channel } else { 'back on the NVR' }); ok = $null } }
      'reboot' { $r += [pscustomobject]@{ text = 'restarted'; ok = $null } } 'poe' { $r += [pscustomobject]@{ text = ('power-cycled ' + $c.switch + ' port ' + $c.port); ok = $null } }
      'unplug' { $r += [pscustomobject]@{ text = 'unplug 10 s (asks you)'; ok = $null } } 'verify' { $r += [pscustomobject]@{ text = 'video held 20 s'; ok = $null } }
    } }
    Say ('  ' + (Format-FsCheckLine $c.name $r))
  }
  foreach ($c in @($plan.cams | Where-Object { $_.state -eq 'missing' })) { Say ('  ' + $c.name + ': ' + $(if ($c.steps -contains 'poe') { 'power-cycle ' + $c.switch + ' port ' + $c.port + ', look again; if still gone: ' } else { '' }) + 'go check ' + $(if ($null -ne $c.port) { 'port ' + $c.port } else { 'its cable' })) }
  if ($newPw) { Say '  A new site password would be made, kept encrypted on this PC, and you would be asked to save it in Bitwarden.' }
  Offer-List
  Say ''; Say 'Dry run done: nothing was changed.' 'Green'; Done 0
}

# =====================================================================================
#  FIX: NVRs on the wrong scheme first (cameras are put back on them)
# =====================================================================================
foreach ($n in @($plan.nvrs | Where-Object { $_.steps -contains 'move' })) {
  if (-not $nvrPw.ContainsKey($n.ip)) { Say ('NVR ' + $n.ip + ': not moved (no NVR login).') 'Yellow'; continue }
  $cr = Fs-Cred $nvrPw[$n.ip]; [void](Add-FsTempIp (Get-FsP3 $n.ip) $pc $tempState)
  [void](Save-FsBackup $n.ip 'Hikvision' $cr (Join-Path $runDir ('backup\NVR-' + $n.ip)))
  $net = Get-FsNet $n.ip 'Hikvision' $cr
  $rb.nvrs += [ordered]@{ ip = $n.ip; target = $n.target; old = [ordered]@{ ip = $net.ip; mask = $net.mask; gw = $net.gw; dhcp = $net.dhcp; dns1 = $net.dns1; dns2 = $net.dns2 } }; Save-Rb
  $w = Set-FsNet $n.ip 'Hikvision' $cr $net $n.target $pc.mask $pc.gw
  if ($w.ok -and $w.reboot) { [void](Restart-FsDevice $n.ip 'Hikvision' $cr) }
  $back = $w.ok -and (Wait-FsDevice $n.target 'Hikvision' $nvrPw[$n.ip] ([int]$opts.rebootWaitSec))
  Say (Format-FsCheckLine ('NVR ' + $n.ip) @([pscustomobject]@{ text = ('moved -> ' + (Get-FsShort $n.target)); ok = $back })) $(if ($back) { 'Green' } else { 'Red' })
  if ($back) { $nvrPw[$n.target] = $nvrPw[$n.ip]; $sec.nvr[$n.target] = $nvrPw[$n.ip]; Save-FsSecrets $SecretsDir $sec }
}
$nvrCred = @{}; foreach ($k in @($nvrPw.Keys)) { $nvrCred[$k] = Fs-Cred $nvrPw[$k] }

# =====================================================================================
#  FIX: one camera at a time (the ones that need a step from you go last)
# =====================================================================================
function Human-Reset($c) {
  # official vendor reset only. Returns $true when the site password works afterwards.
  Set-Clip $sitePw
  $how = $(if ($c.brand -eq 'Dahua') { 'Open http://' + $c.ip + ' in the browser, click "Forgot password", scan the QR code with the DMSS app (or get the email code), and set the new password: it is on the clipboard (Ctrl+V).' }
           elseif ($c.steps -contains 'activate') { 'In SADP (or HiTools), tick the camera ' + $c.ip + ' (serial ...' + ([string]$c.serial).Substring([math]::Max(0, ([string]$c.serial).Length - 9)) + '), click Activate, and paste the new password: it is on the clipboard (Ctrl+V).' }
           else { 'In SADP (or HiTools), tick the camera ' + $c.ip + ' (serial ...' + ([string]$c.serial).Substring([math]::Max(0, ([string]$c.serial).Length - 9)) + '), click Forgot Password, scan the QR code with the Hik-Partner Pro app, type the code it gives you, and paste the new password: it is on the clipboard (Ctrl+V).' })
  for ($i = 0; $i -lt 3; $i++) {
    $a = Ask ($c.name + ': ' + $how + ' Then press Enter here (S = skip this camera).')
    if ($a -match '^(?i)s') { Clear-Clip; return $false }
    if ((Wait-FsDevice $c.ip $c.brand $sitePw 30)) { Clear-Clip; return $true }
    $how = 'The site password does not log in yet. Finish the reset with the password on the clipboard (Ctrl+V).'
  }
  Clear-Clip; return $false
}
$ordered = @($plan.cams | Where-Object { $_.state -eq 'fix' } | Sort-Object { Get-FsOrderKey $_ })
$i = 0
foreach ($c in $ordered) {
  $i++; Write-Host ''; Say ('[' + $i + '/' + $ordered.Count + '] ' + $c.name + ' (' + $c.ip + ')') 'Cyan'
  $res = New-Object System.Collections.ArrayList; $ip = $c.ip; $pw = $(if ($pwFor.ContainsKey($c.ip)) { $pwFor[$c.ip] } else { '' }); $stop = $false; $needReboot = $false
  $rbc = [ordered]@{ name = $c.name; mac = $c.mac; brand = $c.brand; ip_before = $c.ip; ip_after = ''; net_before = $null; stream_before = $null; password_changed = $false; nvr = $null; backup = '' }
  $rb.cameras += $rbc
  $step = { param($text, $ok) [void]$res.Add([pscustomobject]@{ text = $text; ok = $ok }); Say ('    ' + $text + ' ' + $(if ($ok -eq $true) { $script:FsOk } elseif ($ok -eq $false) { $script:FsBad } else { '' })) }
  if ((Get-FsP3 $ip) -ne $plan.scheme) { [void](Add-FsTempIp (Get-FsP3 $ip) $pc $tempState) }
  # hung: power first
  if ($c.steps -contains 'poe' -or $c.steps -contains 'unplug') {
    $done = $false
    if ($c.steps -contains 'poe') { $pr = Invoke-FsPoeCycle $siteId $c.mac $portMapDir; if ($pr.state -eq 'done') { & $step ('power-cycled ' + $c.switch + ' port ' + $c.port) $true; $done = $true } elseif ($pr.state -ne 'unavailable') { & $step ('switch power-cycle: ' + $pr.msg) $false } }
    if (-not $done) { $a = Ask ($c.name + ': unplug its network cable' + $(if ($null -ne $c.port) { ' at ' + $(if ($c.switch) { $c.switch + ' ' } else { 'switch ' }) + 'port ' + $c.port } else { '' }) + ' for 10 seconds, plug it back in, then press Enter (S = skip).'); if ($a -match '^(?i)s') { & $step 'skipped' $null; $stop = $true } else { & $step 'unplugged and plugged back' $null } }
    if (-not $stop) {
      $up = $false; $end = (Get-Date).AddSeconds([int]$opts.rebootWaitSec); do { Fs-Sleep 5; $s = Test-FsLogin $ip $c.brand ''; if ($s -ne 'noanswer') { $up = $true } } while (-not $up -and (Get-Date) -lt $end)
      if (-not $up) { & $step 'still not answering' $false; $stop = $true }
      else { $fp = Find-FsPassword $ip $c.brand @(Get-FsPasswordCandidates $sec ([int]$opts.maxPasswordTries)) ([int]$opts.maxPasswordTries); if ($fp.state -eq 'ok') { $pw = $fp.value; if ($pw -ne $sitePw -and $c.steps -notcontains 'password') { $c.steps = @($c.steps | ForEach-Object { if ($_ -eq 'backup') { 'backup'; 'password' } else { $_ } }) } } else { $c.steps = @($c.steps) + @('reset') } }
    }
  }
  if (-not $stop -and ($c.steps -contains 'reset' -or $c.steps -contains 'activate')) {
    if (Human-Reset $c) { $pw = $sitePw; & $step $(if ($c.steps -contains 'activate') { 'activated with the site password' } else { 'password reset (official)' }) $true } else { & $step 'password not reset - skipped' $false; $stop = $true }
  }
  if (-not $stop -and -not $pw) { & $step 'no password that works' $false; $stop = $true }
  $cr = Fs-Cred $pw
  # backup
  if (-not $stop) { $bd = Join-Path $runDir ('backup\' + (($c.name -replace '[^A-Za-z0-9_-]+', '_') + '-' + ($c.mac -replace ':', ''))); $bf = @(Save-FsBackup $ip $c.brand $cr $bd); $rbc.backup = $bd; if ($bf.Count) { & $step 'backup saved' $true } else { & $step 'backup could not be read - camera left alone' $false; $stop = $true } }
  if (-not $stop) { $nb = Get-FsNet $ip $c.brand $cr; if ($nb) { $rbc.net_before = [ordered]@{ ip = $nb.ip; mask = $nb.mask; gw = $nb.gw; dhcp = $nb.dhcp; dns1 = $nb.dns1; dns2 = $nb.dns2; iface = $nb.iface } }; Save-Rb }
  # password
  if (-not $stop -and $pw -ne $sitePw -and ($c.steps -contains 'password' -or $opts.passwordAll)) {
    if ((Test-FsLogin $ip $c.brand $sitePw) -eq 'ok') { $pw = $sitePw; $cr = Fs-Cred $pw; & $step 'password already set' $true }
    else {
      $sec.rollback[$stamp][$c.mac + '|' + $c.ip] = $pw; Save-FsSecrets $SecretsDir $sec
      $ok = Set-FsPassword $ip $c.brand $cr $sitePw
      if ($ok -and (Test-FsLogin $ip $c.brand $sitePw) -eq 'ok') { $pw = $sitePw; $cr = Fs-Cred $pw; $rbc.password_changed = $true; & $step 'password set' $true } else { & $step 'password not changed (old one still works)' $false }
    }
    Save-Rb
  }
  # settings
  if (-not $stop -and ($c.steps -contains 'settings')) {
    $cur = Get-FsStream $ip $c.brand $cr
    if ($cur) {
      $rbc.stream_before = [ordered]@{ codec = $cur.codec; fps = $cur.fps; width = $cur.width; height = $cur.height; bitrate = $cur.bitrate; gop = $cur.gop; smartCodec = $cur.smartCodec }; Save-Rb
      $diff = @(Get-FsSettingsDiff $cur $c.settings)
      if ($diff.Count) { $w = Set-FsStream $ip $c.brand $cr $cur $diff; if ($w.reboot) { $needReboot = $true }; & $step (Format-FsSettingsDiff $diff) ([bool]$w.ok) } else { & $step 'settings already right' $true }
    } else { & $step 'settings could not be read - not changed' $false }
  }
  # address
  if (-not $stop -and ($c.steps -contains 'move') -and $c.target) {
    $net = Get-FsNet $ip $c.brand $cr
    if ($net -and $net.ip -eq $c.target -and -not $net.dhcp) { & $step ('already on ' + (Get-FsShort $c.target)) $true }
    elseif ($net) {
      $t = $c.target
      if ($t -ne $ip -and -not (Test-FsIpFree $t)) { $t = ''; for ($n = [int]$opts.camFirst; $n -le [int]$opts.camLast; $n++) { $x = $plan.scheme + '.' + $n; if (-not @($plan.cams | Where-Object { $_.target -eq $x -or $_.ip -eq $x }).Count -and (Test-FsIpFree $x)) { $t = $x; break } } }
      if (-not $t) { & $step 'no free address - not moved' $false }
      else {
        $w = Set-FsNet $ip $c.brand $cr $net $t $pc.mask $pc.gw
        if ($w.ok -and $w.reboot) { [void](Restart-FsDevice $ip $c.brand $cr) }
        $back = $w.ok -and (Wait-FsDevice $t $c.brand $pw ([int]$opts.moveWaitSec))
        if ($back) { & $step $(if ($t -ne $ip) { 'moved ' + (Get-FsShort $ip) + ' -> ' + (Get-FsShort $t) } else { 'address set fixed' }) $true; $ip = $t; $rbc.ip_after = $t; $c.target = $t }
        elseif ($w.ok) { & $step ('moved to ' + (Get-FsShort $t) + ' but it does not answer there yet') $false; $stop = $true; $rbc.ip_after = $t }
        else { & $step 'the camera refused the new address' $false }
      }
    } else { & $step 'address could not be read - not moved' $false }
    Save-Rb
  }
  # restart (settings that need it, or a camera with no video)
  if (-not $stop -and ($needReboot -or $c.steps -contains 'reboot')) { $ok = Restart-FsDevice $ip $c.brand $cr; if ($ok) { Fs-Sleep 20; $ok = Wait-FsDevice $ip $c.brand $pw ([int]$opts.rebootWaitSec) }; & $step 'restarted' $ok }
  # back on the NVR
  if (-not $stop -and ($c.steps -contains 'nvr') -and $c.nvr) {
    if (-not $nvrCred.ContainsKey($c.nvr)) { & $step ('NVR ' + $c.nvr + ' password unknown - put it on ch ' + $c.channel + ' by hand') $false }
    else {
      $ch = [int]$c.channel
      if (-not $ch) { $chs = @(Get-FsNvrChannels $c.nvr $nvrCred[$c.nvr]); $used = @($chs | ForEach-Object { $_.channel }); for ($k = 1; $k -le 64; $k++) { if ($used -notcontains $k) { $ch = $k; break } } }
      $w = Set-FsNvrChannel $c.nvr $nvrCred[$c.nvr] $ch $ip $pw $c.brand (Join-Path $runDir 'backup')
      $rbc.nvr = [ordered]@{ nvr = $c.nvr; channel = $ch; action = $w.action; before_file = $(if ($w.before) { 'backup\nvr-' + $c.nvr + '-ch' + $ch + '.xml' } else { '' }) }; Save-Rb
      & $step ('back on NVR ch ' + $ch) ([bool]$w.ok); $c.channel = $ch
    }
  }
  # video back and held
  if (-not $stop) {
    $vok = $false; $end = (Get-Date).AddSeconds(150)
    do {
      if (Test-FsVideo $c.nvr $(if ($c.nvr -and $nvrCred.ContainsKey($c.nvr)) { $nvrCred[$c.nvr] } else { $null }) $(if ($c.nvr -and $nvrCred.ContainsKey($c.nvr)) { [int]$c.channel } else { 0 }) $ip $c.brand $cr) {
        Fs-Sleep ([int]$opts.verifyHoldSec)
        if (Test-FsVideo $c.nvr $(if ($c.nvr -and $nvrCred.ContainsKey($c.nvr)) { $nvrCred[$c.nvr] } else { $null }) $(if ($c.nvr -and $nvrCred.ContainsKey($c.nvr)) { [int]$c.channel } else { 0 }) $ip $c.brand $cr) { $vok = $true }
      }
      if (-not $vok) { Fs-Sleep 10 }
    } while (-not $vok -and (Get-Date) -lt $end)
    & $step $(if ($vok) { 'video back' } else { 'no video yet' + $(if ($c.nvr) { ' on the NVR - check ch ' + $c.channel + ' in the NVR' } else { '' }) }) $vok
  }
  $line = Format-FsCheckLine $c.name @($res | Where-Object { $_.text -notin @('backup saved') })
  $allOk = -not @($res | Where-Object { $_.ok -eq $false }).Count -and -not $stop
  if ($allOk) { $okCount++ } else { $badCount++ }
  $results += $line
  Say ('  ' + $line) $(if ($allOk) { 'Green' } else { 'Red' })
}
# missing cameras: power-cycle the port they should be on, look again
foreach ($c in @($plan.cams | Where-Object { $_.state -eq 'missing' })) {
  Write-Host ''; $line = ''
  if ($c.steps -contains 'poe' -and $c.mac) {
    $pr = Invoke-FsPoeCycle $siteId $c.mac $portMapDir
    if ($pr.state -eq 'done') {
      $back = $false; if ($c.listIp) { $back = Wait-FsDevice $c.listIp $c.brand $sitePw 120 }
      if ($back -and $c.nvr -and $nvrCred.ContainsKey($c.nvr) -and $c.channel) { $w = Set-FsNvrChannel $c.nvr $nvrCred[$c.nvr] ([int]$c.channel) $c.listIp $sitePw $c.brand (Join-Path $runDir 'backup'); $vid = Test-FsVideo $c.nvr $nvrCred[$c.nvr] ([int]$c.channel) $c.listIp $c.brand (Fs-Cred $sitePw); $line = Format-FsCheckLine $c.name @([pscustomobject]@{ text = ('power-cycled ' + $c.switch + ' port ' + $c.port); ok = $true }, [pscustomobject]@{ text = 'video back'; ok = $vid }) }
      elseif ($back) { $line = Format-FsCheckLine $c.name @([pscustomobject]@{ text = ('power-cycled ' + $c.switch + ' port ' + $c.port + ', answers again'); ok = $true }) }
      else { $line = $c.name + ': power-cycled ' + $c.switch + ' port ' + $c.port + ', still missing - go check port ' + $c.port + ' (cable, camera)' + ' ' + $script:FsBad }
    } else { $line = $c.name + ': missing - ' + ($c.why -join '; ') + ' ' + $script:FsBad }
  } else { $line = $c.name + ': ' + ($c.why -join '; ') + ' ' + $script:FsBad }
  if ($line -like ('*' + $script:FsOk + '*') -and $line -notlike ('*' + $script:FsBad + '*')) { $okCount++ } else { $badCount++ }
  $results += $line; Say ('  ' + $line) $(if ($line -like ('*' + $script:FsBad + '*')) { 'Red' } else { 'Green' })
}
Remove-FsTempIps $tempState
Save-FsSecrets $SecretsDir $sec; Save-Rb

# =====================================================================================
#  DONE: the checklist, the site list, Bitwarden
# =====================================================================================
Write-Host ''
Say '----- Checklist -----' 'Cyan'
foreach ($l in $results) { Say ('  ' + $l) $(if ($l -like ('*' + $script:FsBad + '*')) { 'Red' } else { 'Green' }) }
if (@($plan.healthy).Count) { Say ('  ' + @($plan.healthy).Count + ' other camera(s) were already fine.') }
Say ('Fixed: ' + $okCount + '   Still a problem: ' + $badCount) $(if ($badCount) { 'Yellow' } else { 'Green' })
Say ('Backups and the undo file: ' + $runDir)
([ordered]@{ at = (Get-Date -Format 's'); site = $siteName; ok = $okCount; bad = $badCount; lines = $results } | ConvertTo-Json -Depth 4) | Set-Content -Path (Join-Path $runDir 'summary.json') -Encoding UTF8
Offer-List
$pwUsed = $newPw -or @($rb.cameras | Where-Object { $_.password_changed }).Count -gt 0
if ($pwUsed -and -not $sec.bitwardenSaved) {
  Say ''
  Say ('The site''s camera password must go in Bitwarden (WireIt CT > Sites), item "' + $siteName + ' - cameras", user admin.') 'Yellow'
  for ($k = 0; $k -lt 4; $k++) {
    $a = Ask 'Type C to copy the password to the clipboard, then SAVED once it is in Bitwarden (Enter = later; it asks again next run).'
    if ($a -match '^(?i)c$') { Set-Clip $sitePw; Say 'Copied. Paste it into Bitwarden (it is cleared from the clipboard when you type SAVED).' ; continue }
    if ($a -match '^(?i)saved$') { Clear-Clip; $sec.bitwardenSaved = $true; Save-FsSecrets $SecretsDir $sec; Say 'Thanks - marked as saved in Bitwarden.' 'Green'; break }
    break
  }
  Clear-Clip
}
Fs-Log ('end ok=' + $okCount + ' bad=' + $badCount)
Done $(if ($badCount) { 4 } else { 0 })
