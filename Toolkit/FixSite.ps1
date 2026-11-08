<#
 FixSite.ps1 - WireIt Toolkit 2.0: "Fix this site". ONE button, no order to figure out.
 Moshe, Nov 3 2026: "Diagnosing doesn't help... It would only help me to actually fix the cameras." / "I just want to do this with one click."

 What it does, in this order, by itself:
   1. Reads what SHOULD be here: the site list in the site's Drive folder (Docs\WireIt site list.json, or the Fix NVR install
      snapshot), with switch + port from PortMap when this is the office Dell.
   2. Looks at what IS here: every camera and NVR (Hikvision SADP, Dahua search, network sweep, the NVR's channel list),
      even on the wrong IP scheme, and logs in with the site's saved passwords only (a short, fixed list - never guessing).
   3. Asks ONE question if some passwords are unknown: type it, or Enter for the official reset.
   4. Shows ONLY the problems and what it will change; the first line says "Changes only the N cameras listed below. M working cameras
      will not be touched." Working cameras are one "OK, not touched" line. You type YES once.
      2.0.1 (Moshe, Nov 3 2026): ONLY cameras with a real problem (offline / no video / hung / wrong IP scheme / not on the NVR /
      password unknown / locked / not activated / missing) get any change. A working camera gets nothing - no password, no settings,
      no I-frame, no address change - unless this run was started with -AllCameras ("Apply settings to ALL cameras": the drop-downs only)
      or -PasswordAll ("Make every device use the site password"). Both are off unless ticked for that run.
   5. Then, one camera at a time (cameras being fixed): backup -> site password -> camera settings -> move to the right address -> back on the NVR
      -> restart / switch-port power-cycle if hung -> waits until the NVR shows video for 20 s -> check mark.
   6. Missing cameras: "should be on <switch> port 10 - go check port 10" (power-cycles that port first when it can).
   7. Offers to save what it found as the site's list, and saves the site password in Bitwarden (or shows it once to save there).
 Every step reads first and skips what is already right, so running it twice is safe. Backups + rollback file in runs\FixSite-<time>.
 2.0.2 (Moshe, Nov 4 2026: "if I come to a new site, I want to be able to run the program and ... fix whatever is broken, whatever is
   missing"): -NewSite = the window's "New site (not listed)" button. No site to type: it names the site from what the scan sees
   ("New site 10.0.5.x 2026-11-04"), tries the per-camera / old factory passwords (same try limit), and "missing" means an
   NVR channel with no video that nothing answers for. Same 2.0.1 rule: only problem cameras change, YES first, backups + undo. After the
   plan screen it asks for the address (optional) and saves the site list + secrets under that name. If the NVR (or 2+ cameras) match a
   site already saved on this PC, it uses that site instead.
 2.0.3 (Moshe, Nov 4 2026: "There are no usual passwords. Every single password is specific to that site."): no shared passwords
   between sites. Each site has ONE site password (2.1.0: typed by the tech, never made up by the Toolkit). A new site / a site with no site password yet: every device still on its FACTORY password (cameras + NVR) gets it,
   with its NVR channel updated and the picture checked. -PasswordAll ("Make every device use the site password", off unless ticked):
   every device on a different working password gets it; one camera at a time: password -> NVR channel -> picture checked; a picture
   that does not come back = that camera's old password is put back (camera + channel) and it is reported. Then: Bitwarden item
   "<site> - site password" when the bw command is on this PC (logged in), else kept encrypted here and offered for saving in Bitwarden.
 Modes: Fix (default) | Plan (look only) | DryRun (-Recorded <scan.json>, no network at all) | Rollback (-RollbackDir) | SitePassword (show / copy / set)
 Passwords: typed hidden, kept only in the encrypted site store on this PC (secrets\), never in a log, a file, Drive or a chat.
#>
param(
  [ValidateSet('Fix', 'Plan', 'DryRun', 'Rollback', 'SitePassword')][string]$Mode = 'Fix',
  [string]$Site = '',
  [string]$Recorded = '',           # DryRun: a recorded scan (tests\fixsite\*.json)
  [string]$ListFile = '',           # use this site list instead of the Drive one
  [string]$Codec = 'auto', [int]$Fps = 0, [string]$Resolution = 'keep', [int]$Bitrate = 0,
  [switch]$AllCameras,              # 2.0.1: the drop-down settings go on EVERY camera (the window's "Apply settings to ALL cameras" tick). Off = only cameras with a real problem
  [switch]$PasswordAll,           # 2.0.1/2.0.3: every device gets the site password (the window's "Make every device use the site password" tick). Off = only cameras being fixed
  [switch]$NewSite,                 # 2.0.2: the window's "New site (not listed)" button - no -Site, no list, the scan names the site
  [string]$RollbackDir = '',
  [string]$ConfigPath = '', [string]$SecretsDir = '', [string]$RunsRoot = '', [string]$SitesDir = '',
  [string]$MockUrl = '',            # TEST HARNESS ONLY: all device calls go to tests\fixsite\mock_site.py
  [string]$Answers = '',            # TEST HARNESS ONLY: answers to the questions, one per line
  [string]$BwPath = '',             # TEST HARNESS ONLY: a fake bw command (test runs never look for the real Bitwarden)
  [int]$CloseAfter = 0,
  [string]$Ipc = ''                 # 2.2.0: set by FixSiteRunner.ps1 (the "Fix this site" task): questions go to the Toolkit window through this folder
)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'FixSiteCore.ps1')
. (Join-Path $here 'FixSiteDevices.ps1')
if (Test-Path (Join-Path $here 'ToolkitCore.ps1')) { . (Join-Path $here 'ToolkitCore.ps1') }
. (Join-Path $here 'FixSiteIpc.ps1')
$hikFlowOk = $false; if (Test-Path (Join-Path $here 'HikResetFlow.ps1')) { try { . (Join-Path $here 'HikResetFlow.ps1'); $hikFlowOk = $true } catch {} }   # 2.1.0 Hikvision official reset
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ---------------- settings ----------------
$root = Split-Path -Parent $here
if (-not $ConfigPath) { $ConfigPath = Join-Path $here 'config.json' }
$cfgAll = $null; if (Test-Path $ConfigPath) { try { $cfgAll = Get-Content $ConfigPath -Raw | ConvertFrom-Json } catch {} }
$fsCfg = $null; if ($cfgAll -and $cfgAll.PSObject.Properties['fixSite']) { $fsCfg = $cfgAll.fixSite }
# 2.2.2 (re-review H1): models known to have no HTTPS at all (regexes) may get a password over plain HTTP, with the warning
if ($fsCfg -and $fsCfg.PSObject.Properties['noHttpsModels']) { $script:FsNoTlsModels = @($script:FsNoTlsModels) + @($fsCfg.noHttpsModels | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
$driveRoots = @('G:\My Drive\WireIt Sites', '%USERPROFILE%\My Drive\WireIt Sites', 'C:\Users\admin\My Drive\WireIt Sites')
if ($fsCfg -and $fsCfg.PSObject.Properties['driveRoots']) { $driveRoots = @($fsCfg.driveRoots) }
# 2.2.0: the "Fix this site" task runs as SYSTEM, which has no G: drive and no profile of its own: look in every user's My Drive too
try { if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { foreach ($u in @(Get-ChildItem -LiteralPath (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue)) { $driveRoots += (Join-Path $u.FullName 'My Drive\WireIt Sites') } } } catch {}
$opts = Merge-FsOptions $fsCfg
$opts.settings.codec = $Codec; $opts.settings.fps = $Fps; $opts.settings.resolution = $Resolution; $opts.settings.bitrate = $Bitrate
$opts.settingsAll = [bool]$AllCameras; $opts.passwordAll = [bool]$PasswordAll   # per run, never from config: a working camera is only touched when the tech ticks it this time
# 2.2.0: the site password store is vault\ (Administrators + SYSTEM only, machine-wide DPAPI); 2.1's secrets\ is read once and moved
if (-not $SecretsDir) { $SecretsDir = Join-Path $here 'vault'; $script:FsLegacySecretsDir = Join-Path $here 'secrets' }
if (-not $RunsRoot) { $RunsRoot = Get-FsRunnerRunsDir $here }
if (-not $SitesDir) { $SitesDir = Join-Path $here 'sites' }
$camResetDir = Join-Path $root 'CamReset'; $portMapDir = Join-Path $root 'PortMap'
if ($MockUrl) { $script:FsMockUrl = $MockUrl; $script:FsTestSecrets = $true }
if ($Mode -eq 'DryRun') { $script:FsTestSecrets = $true }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path $RunsRoot ('FixSite-' + $stamp); New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$logFile = Join-Path $runDir 'log.txt'
$tempState = Join-Path (Join-Path $RunsRoot '_state') 'fixsite-temp-ips.json'; New-Item -ItemType Directory -Force -Path (Split-Path $tempState) | Out-Null   # 2.2.0: not in the Crew-writable state\
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
  if ($Answers) { $a = ''; if ($script:AnswerQ.Count) { $a = [string]$script:AnswerQ.Dequeue() }; if ($Secret) { Remember-Secret $a }; Fs-Log ('ANSWER ' + $(if ($Secret) { '(hidden)' } else { $a })); return $a }
  if ($Ipc) {
    # 2.2.0: the Toolkit window asks it (a masked box for -Secret); nothing typed is ever on this run's screen or in its log
    $n = Send-FsIpc $Ipc @{ kind = $(if ($Secret) { 'secret' } else { 'text' }); text = $q }
    $a = Wait-FsIpcAnswer $Ipc $n 'text' 3600
    if ($null -eq $a) { Fs-Log 'ANSWER (none - no answer from the window)'; return '' }
    if ($Secret) { Remember-Secret $a; Fs-Log 'ANSWER (hidden)' } else { Fs-Log ('ANSWER ' + $a) }
    return [string]$a
  }
  if ($Secret) { $ss = Read-Host -AsSecureString '>'; $a = (New-Object PSCredential('x', $ss)).GetNetworkCredential().Password; Remember-Secret $a; Fs-Log 'ANSWER (hidden)'; return $a }
  $a = Read-Host '>'; Fs-Log ('ANSWER ' + $a); return $a
}
function Ask-Choice([string]$q, [string]$yes, [string]$no) {
  # 2.1.0 (Moshe, Nov 6 2026): a yes/no question is two buttons, not a typed prompt. Test runs and dry runs still use the typed answer file.
  if ($Answers -or (-not $Ipc -and ($MockUrl -or $Mode -eq 'DryRun'))) { $a = Ask ($q + '  [' + $yes + ']  [' + $no + ']  (type Y or N)'); return ([string]$a).Trim() -match '^(?i)y' }
  if ($Ipc) {
    Write-Host ''; Write-Host $q -ForegroundColor Yellow; Fs-Log ('ASK ' + $q)
    $n = Send-FsIpc $Ipc @{ kind = 'choice'; text = $q; yes = $yes; no = $no }
    $y = Wait-FsIpcAnswer $Ipc $n 'choice' 3600
    if ($null -eq $y) { $y = $false; Fs-Log ('ANSWER (none) = ' + $no) } else { Fs-Log ('ANSWER ' + $(if ($y) { $yes } else { $no })) }
    return [bool]$y
  }
  try {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    Write-Host ''; Write-Host $q -ForegroundColor Yellow; Fs-Log ('ASK ' + $q)
    $fm = New-Object Windows.Forms.Form; $fm.Text = 'WireIt Toolkit'; $fm.StartPosition = 'CenterScreen'; $fm.TopMost = $true; $fm.FormBorderStyle = 'FixedDialog'; $fm.MaximizeBox = $false; $fm.MinimizeBox = $false
    $fm.AutoScaleMode = 'Dpi'; $fm.ClientSize = New-Object Drawing.Size(520, 170); $fm.Font = New-Object Drawing.Font('Segoe UI', 10)
    $l = New-Object Windows.Forms.Label; $l.Text = $q; $l.SetBounds(16, 14, 488, 90)
    $b1 = New-Object Windows.Forms.Button; $b1.Text = $yes; $b1.SetBounds(16, 114, 236, 42); $b1.DialogResult = [Windows.Forms.DialogResult]::Yes
    $b2 = New-Object Windows.Forms.Button; $b2.Text = $no; $b2.SetBounds(268, 114, 236, 42); $b2.DialogResult = [Windows.Forms.DialogResult]::No
    $fm.Controls.AddRange(@($l, $b1, $b2)); $fm.AcceptButton = $b1
    $r = $fm.ShowDialog(); $fm.Dispose()
    $y = ($r -eq [Windows.Forms.DialogResult]::Yes); Fs-Log ('ANSWER ' + $(if ($y) { $yes } else { $no })); return $y
  } catch { $a = Ask ($q + '  (type Y for "' + $yes + '", N for "' + $no + '")'); return ([string]$a).Trim() -match '^(?i)y' }
}
function Remember-Secret([string]$p) { if ($p) { $script:Secrets += $p } }
# 2.2.1 (review H1): said once per device whose password had to go over plain HTTP (it has no HTTPS)
$script:PlainWarned = @{}
function Say-PlainWarning([string]$ip) {
  # 2.2.2 (re-review H1): HTTPS that did not work (timeout, TLS, certificate) is said in red - the password was NOT sent
  $tf = Get-FsTlsFailure $ip
  if ($tf -and -not $script:PlainWarned.ContainsKey('tls|' + $ip)) { $script:PlainWarned['tls|' + $ip] = 1; Say ('    ' + $ip + ': HTTPS did not work (' + $(switch ($tf) { 'timeout' { 'no answer in time' } 'tls' { 'TLS/certificate problem' } 'unreachable' { 'not reachable' } default { 'connection problem' } }) + '), so its password was NOT sent. It is never sent over plain HTTP to a device that has HTTPS. Check the device, then press the button again.') 'Red' }
  if (-not (Test-FsSentPlain $ip) -or $script:PlainWarned.ContainsKey($ip)) { return }
  $script:PlainWarned[$ip] = 1
  Say ('    WARNING: ' + $ip + ' has no HTTPS, so its password went over plain HTTP on this network. Turn on HTTPS on it when you can.') 'Yellow'
}
function Set-Clip([string]$s) { if (-not $Ipc -and ($MockUrl -or $Answers)) { return }; if ($Ipc) { [void](Send-FsIpc $Ipc @{ kind = 'clip'; value = $s }); return }; try { Set-Clipboard -Value $s } catch {} }
function Clear-Clip { if (-not $Ipc -and ($MockUrl -or $Answers)) { return }; if ($Ipc) { [void](Send-FsIpc $Ipc @{ kind = 'clipclear' }); return }; try { Set-Clipboard -Value ' ' } catch {} }
function Say-NetRestore($r) {
  # 2.2.1 (review H4): the tech hears it when this PC's own network could not be put back
  if (-not $r -or $r.ok) { return }
  Say ('THIS PC''S NETWORK IS NOT BACK TO NORMAL: ' + (@($r.problems) -join '; ') + '. The Toolkit tries again the next time it runs; restarting the PC also clears the temporary addresses.') 'Red'
}
function Done([int]$code) {
  $nr = $null; try { $nr = Remove-FsTempIps $tempState } catch { $nr = [pscustomobject]@{ ok = $false; problems = @('the clean-up stopped: ' + $_.Exception.Message) } }; Say-NetRestore $nr
  # 2.2.2 (re-review H4): this PC's network not back = the run did NOT end well, whatever else worked (exit 6, the window says so)
  if ($nr -and -not $nr.ok -and $code -in @(0, 4)) { $code = 6 }
  if ($Ipc) { }
  elseif ($CloseAfter -gt 0) { Write-Host ''; Write-Host ('This window closes in ' + $CloseAfter + ' seconds.'); Start-Sleep -Seconds $CloseAfter }
  elseif (-not $Answers -and -not $MockUrl -and $Mode -ne 'DryRun') { Write-Host ''; [void](Read-Host 'Press Enter to close this window') }
  exit $code
}

Write-Host ''
if ($NewSite -and $Mode -notin @('Fix', 'Plan', 'DryRun')) { $NewSite = $false }
if ($NewSite) { $Site = '' }
# 2.0.2: an undo always uses the site its run was saved under (a New site run has a name the site box may not show)
if ($Mode -eq 'Rollback' -and $RollbackDir) { try { $rbSite = [string]((Get-Content -LiteralPath (Join-Path $RollbackDir 'rollback.json') -Raw | ConvertFrom-Json).site); if ($rbSite) { $Site = $rbSite } } catch {} }
Write-Host ('=== WireIt Toolkit ' + $script:FsVersion + ' - Fix this site' + $(if ($NewSite) { ' - New site' } elseif ($Site) { ' - ' + $Site } else { '' }) + ' ===') -ForegroundColor Cyan
Fs-Log ('start mode=' + $Mode + ' site=' + $Site + ' newsite=' + [bool]$NewSite + ' ps=' + $PSVersionTable.PSVersion + ' pc=' + $env:COMPUTERNAME)
$lr = Clear-FsLeftoverTemps $tempState; if ($lr) { if ($lr.ok) { Say 'A temporary address a stopped run left on this PC was taken off, and its network settings are back.' 'Yellow' } else { Say-NetRestore $lr } }
# 2.2.1 (review H4): whatever stops this run, this PC's network goes back first (the "Fix this site" task also does it after the run)
trap { try { [void](Remove-FsTempIps $tempState) } catch {}; break }

# ---------------- the site and its list ----------------
$pmSite = $null
if ($NewSite) {
  # 2.0.2: nothing typed. The scan below names the site (or recognises one already saved on this PC).
  $siteFolder = $null; $siteName = 'New site'; $siteId = ''; $listPath = ''; $localList = ''; $list = $null; $listFrom = ''
  Say 'New site (not listed): nothing to type. It looks at the network, names the site from what it finds, and saves it on this PC at the end.'
} else {
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
}
$sec = Read-FsSecrets $SecretsDir $siteName
foreach ($p in @($sec.password) + @($sec.known)) { Remember-Secret $p }
function Stop-IfUnreadable($s) {
  # 2.2.0 (review M1): a saved store this PC cannot read is NEVER taken as "no password yet" (that made a second password)
  if (-not $s -or -not $s.unreadable) { return }
  Say ((Get-FsUnreadableText ([string]$s.unreadableWhy)) + ' Nothing was changed, and no new password was made.') 'Red'
  Say 'Fix: an admin runs the Toolkit installer once on this PC (it moves 2.1''s saved passwords so every admin account and the Crew button can read them), or use "Site password..." > T to type the password this site uses (it is in Bitwarden).' 'Red'
  Done 2
}
if ($Mode -ne 'SitePassword') { Stop-IfUnreadable $sec }

# ---------------- 2.1.0 site password (Moshe, Nov 6 2026 2:09-2:13 PM) ----------------
# A saved site loads its password with no prompt. A site with no password asks ONCE: "Do you know the site password?"
#   Yes = the tech types it once (hidden, twice to confirm) -> it is every device's password (and a login try on this run).
#   No  = the Toolkit makes one (the word + 4 random digits); it is saved after the YES and offered for Bitwarden at the end.
# Nothing is saved before the YES. A made password is never used as a login try (no device can have it yet).
$sitePwPending = $false; $sitePwMake = $false; $sitePwAsked = $false
function Ask-SitePassword {
  $script:sitePwAsked = $true
  $knowIt = Ask-Choice 'New site: do you know the site password?' 'Yes, I know it' 'No, make one for me'
  if (-not $knowIt) { $script:sitePwMake = $true; return '' }
  for ($k = 0; $k -lt 2; $k++) {
    $p1 = Ask 'Type the site password (hidden):' -Secret
    if (-not $p1) { break }
    Remember-Secret $p1
    $p2 = Ask 'Type it again to confirm (hidden):' -Secret
    if ($p1 -cne $p2) { Say 'The two did not match.' 'Yellow'; continue }
    if ($p1.Length -lt 8 -or $p1.Length -gt 16) { Say 'Camera passwords are 8-16 characters. Try again.' 'Yellow'; continue }
    $sec.password = $p1; $sec.bitwardenSaved = $false; $sec.shownOnce = $true; $script:sitePwPending = $true
    return $p1
  }
  Say 'No site password was typed, so nothing was changed. Press the button again.' 'Yellow'; Done 2
}
function Complete-SitePassword {
  # after the scan: a "No, make one" answer gets its password now (never tried as a login during the scan)
  if (-not $script:sitePwMake -or $sec.password) { return }
  $sec.password = New-SitePasswordNow; $sec.bitwardenSaved = $false; $sec.shownOnce = $false; Remember-Secret $sec.password; $script:sitePwPending = $true
  Say 'A new site password was made (14 random characters, different from every other site). It is saved after you type YES and offered for Bitwarden at the end.' 'Green'
}
# 2.2.1 (review M1): a made site password is fully random and unique on this PC (no shared word: one site's password tells nothing about another's)
function New-SitePasswordNow {
  $avoid = @(Get-FsOtherSitePasswords $SecretsDir $siteName)
  if ($Mode -eq 'DryRun') { return 'Dryrun-not-a-password' }
  return (New-FsRandomSitePassword $avoid)
}
# ---------------- 2.0.3: the site password - its word, Bitwarden, shown once ----------------
function Get-SitePrefix {
  $p = Get-FsSitePrefix $fsCfg $SecretsDir
  if ($p) { Remember-Secret $p; return $p }   # 2.2.0 (review H2): the word is scrubbed from every log line like a password
  if ($Mode -eq 'DryRun') { return 'Dryrun' }
  for ($k = 0; $k -lt 3; $k++) {
    # 2.2.0 (review H2): typed hidden, twice, never shown and never logged (every made site password starts with it)
    $p = ([string](Ask 'Site passwords start with your word, then 4 random digits. Type the word (hidden; same capital letters; letters/digits, 4-16 long, starting with a letter). Asked once - kept encrypted on this PC:' -Secret)).Trim()
    if (-not $p) { break }
    Remember-Secret $p
    if (-not (Test-FsSitePrefix $p)) { Say 'That word does not fit (4-16 letters/digits, starting with a letter).' 'Yellow'; continue }
    $p2 = ([string](Ask 'Type the word again to confirm (hidden):' -Secret)).Trim()
    if ($p2 -cne $p) { Say 'The two did not match.' 'Yellow'; continue }
    Save-FsSitePrefix $SecretsDir $p; return $p
  }
  return ''
}
function Show-SitePasswordOnce([string]$pw) {
  # the ONLY place the password is shown: a small window with a Copy button (never the console, the log or a file)
  if (-not $Ipc -and ($MockUrl -or $Answers -or $Mode -eq 'DryRun')) { Say 'SHOWN ONCE: the site password window with the Copy button (test run - not opened).'; return }
  if ($Ipc) {
    # 2.2.0: the Toolkit window on the tech's login shows it (with Copy); the question file is deleted as soon as it is shown
    Say 'SHOWN ONCE: the site password, in the Toolkit window with a Copy button.'
    $n = Send-FsIpc $Ipc @{ kind = 'show'; site = $siteName; value = $pw; bwItem = (Get-FsBwItemName $siteName) }
    $ok = Wait-FsIpcAnswer $Ipc $n 'text' 1800
    if ($null -eq $ok) { Say 'The password window was not closed in time. Use "Site password..." in the Toolkit to see and copy it.' 'Yellow' }
    Clear-Clip; return
  }
  Show-SitePasswordWindow $pw
}
# the WinForms window on its own (its types load only when it really opens: test runs and the window path never touch them)
function Show-SitePasswordWindow([string]$pw) {
  try {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $fm = New-Object Windows.Forms.Form; $fm.Text = 'WireIt Toolkit - site password'; $fm.StartPosition = 'CenterScreen'; $fm.TopMost = $true; $fm.FormBorderStyle = 'FixedDialog'; $fm.MaximizeBox = $false; $fm.MinimizeBox = $false
    $fm.AutoScaleMode = 'Dpi'; $fm.ClientSize = New-Object Drawing.Size(480, 230); $fm.Font = New-Object Drawing.Font('Segoe UI', 10)
    $l1 = New-Object Windows.Forms.Label; $l1.Text = ('Site password for ' + $siteName + ' (user admin):'); $l1.SetBounds(16, 12, 448, 24)
    $tb = New-Object Windows.Forms.TextBox; $tb.ReadOnly = $true; $tb.Text = $pw; $tb.Font = New-Object Drawing.Font('Consolas', 20, [Drawing.FontStyle]::Bold); $tb.SetBounds(16, 40, 448, 40); $tb.BackColor = [Drawing.Color]::White
    $l2 = New-Object Windows.Forms.Label; $l2.Text = ('Save this in Bitwarden (item "' + (Get-FsBwItemName $siteName) + '"). Paste it there, then Close (Close clears the clipboard). To see it again later: "Site password..." in the Toolkit.'); $l2.SetBounds(16, 92, 448, 70); $l2.ForeColor = [Drawing.Color]::FromArgb(150, 60, 0)
    $bc = New-Object Windows.Forms.Button; $bc.Text = 'Copy'; $bc.SetBounds(16, 176, 120, 36); $bc.Add_Click({ Set-Clip $pw; $bc.Text = 'Copied' })
    $bx = New-Object Windows.Forms.Button; $bx.Text = 'Close'; $bx.SetBounds(344, 176, 120, 36); $bx.Add_Click({ $fm.Close() })
    $fm.Controls.AddRange(@($l1, $tb, $l2, $bc, $bx)); $fm.AcceptButton = $bx
    [void]$fm.ShowDialog(); $fm.Dispose()
  } catch { Say 'The password window could not open. Use "Site password..." in the Toolkit to see and copy it.' 'Yellow' }
  Clear-Clip
}
function Save-SitePasswordAway([string]$pw, [switch]$ShowAgain) {
  # 1) Bitwarden when the bw command is on this PC and logged in; 2) else encrypted here (it already is) + shown once to save in Bitwarden
  $shown = $siteName + ' - site password'   # the console shows a plain dash; the Bitwarden item has the real one
  if ($Ipc -and -not $BwPath) {
    # 2.2.2 (re-review H11 + NEW-3): a background run is SYSTEM, whose profile has no Bitwarden login: the Toolkit window does the
    # save on the tech's own login (FixSiteAsk.ps1) and answers with the result only
    $n = Send-FsIpc $Ipc @{ kind = 'bitwarden'; site = $siteName; value = $pw; bwItem = (Get-FsBwItemName $siteName) }
    $a = Wait-FsIpcAnswer $Ipc $n 'bitwarden' 900
    if ($null -eq $a) { Say 'The Toolkit window did not answer about Bitwarden in time: the site password is NOT in Bitwarden yet.' 'Yellow' }
    elseif ($a.result -in @('saved', 'updated', 'exists')) {
      $last = [pscustomobject]@{ where = $a.where; org = $a.org; collection = $a.collection; why = $a.why }
      Say (Format-FsBwResult $a.result $last $shown) $(if ($a.where -eq 'org') { 'Green' } else { 'Yellow' })
      if ($a.where -eq 'org') { $sec.bitwardenSaved = $true; Save-FsSecrets $SecretsDir $sec; return }
    }
    elseif ($a.result -eq 'unauthenticated') { Say 'Bitwarden is on this PC but not logged in on this Windows login (bw login), so it could not be saved there.' 'Yellow' }
    elseif ($a.result -eq 'locked') { Say $(if ($a.why -eq 'skipped') { 'Bitwarden is locked and no master password was typed: not saved there.' } else { 'Bitwarden did not unlock (wrong master password?).' }) 'Yellow' }
    elseif ($a.result -eq 'failed') { Say (Format-FsBwResult 'failed' ([pscustomobject]@{ where = ''; why = $a.why }) $shown) 'Yellow' }
  } else {
  $bw = $(if ($BwPath) { $BwPath } elseif ($MockUrl -or $Answers) { '' } else { Find-FsBitwarden $fsCfg })
  $st = Get-FsBwStatus $bw; $session = ''
  if ($st -eq 'locked') {
    $mp = Ask 'Bitwarden is on this PC but locked. Type your Bitwarden master password to save the site password there (hidden; Enter = skip):' -Secret
    if ($mp) { Remember-Secret $mp; $session = Unlock-FsBitwarden $bw $mp; $mp = $null; if ($session) { Remember-Secret $session; $st = 'unlocked' } else { Say 'Bitwarden did not unlock (wrong master password?).' 'Yellow' } }
  }
  if ($st -eq 'unlocked') {
    $r = Save-FsBitwarden $bw $siteName $pw $session $fsCfg
    # 2.2.1 (review H11): every answer here was read back from Bitwarden after a sync; 2.2.2: the words say where it really is
    if ($r -in @('saved', 'updated', 'exists')) {
      Say (Format-FsBwResult $r $script:FsBwLast $shown) $(if ($script:FsBwLast.where -eq 'org') { 'Green' } else { 'Yellow' })
      if ($script:FsBwLast.where -eq 'org') { $sec.bitwardenSaved = $true; Save-FsSecrets $SecretsDir $sec; return }
    } else { Say (Format-FsBwResult $r $script:FsBwLast $shown) 'Yellow' }
  } elseif ($bw -and $st -eq 'unauthenticated') { Say 'Bitwarden is on this PC but not logged in (bw login), so it could not be saved there.' 'Yellow' }
  }
  Say 'The site password is kept encrypted on this PC. Save this in Bitwarden (WireIt CT > Sites).' 'Yellow'
  if (-not $sec.shownOnce -or $ShowAgain) { Show-SitePasswordOnce $pw; $sec.shownOnce = $true; Save-FsSecrets $SecretsDir $sec }
  else { Say 'To see or copy it again: "Site password..." in the Toolkit.' }
}

# =====================================================================================
#  SITE PASSWORD (the window's "Site password..." button): show / copy / save / set THIS site's password. Nothing on the network.
# =====================================================================================
if ($Mode -eq 'SitePassword') {
  Say ('Site password for ' + $siteName + ' - every site has its own; nothing here is shared with other sites.')
  for ($k = 0; $k -lt 6; $k++) {
    if ($sec.unreadable) {
      # 2.2.0 (review M1): never "make one" over a store this PC cannot read - that is how a site ended up with two passwords
      Say ((Get-FsUnreadableText ([string]$sec.unreadableWhy)) + ' It is not made again here.') 'Red'
      $a = (Ask 'T = type the password this site really uses (it is in Bitwarden)   Enter = close').Trim()
      if ($a -notmatch '^(?i)t$') { if ($a) { Say 'Only T works here.' }; if (-not $a) { break }; continue }
    }
    elseif ($sec.password) {
      Say $(if ($sec.bitwardenSaved) { 'It is saved in Bitwarden and kept encrypted on this PC.' } else { 'It is kept encrypted on this PC (not marked as saved in Bitwarden yet).' })
      $a = (Ask 'S = show it (window with a Copy button)   C = copy it   B = save it in Bitwarden   T = type the one this site really uses   Enter = close').Trim()
    } else {
      Say 'This site has no site password yet. Do you know the site password?' 'Yellow'
      $a = (Ask 'Y = yes, I know it (type it once)   N = no, make one for me (random, different from every other site)   Enter = close').Trim()
      if ($a -match '^(?i)y(es)?$') { $a = 'T' } elseif ($a -match '^(?i)no?$') { $a = 'M' }
    }
    if (-not $a) { break }
    if ($a -match '^(?i)s$' -and $sec.password) { Show-SitePasswordOnce $sec.password; $sec.shownOnce = $true; Save-FsSecrets $SecretsDir $sec }
    elseif ($a -match '^(?i)c$' -and $sec.password) { Set-Clip $sec.password; Say 'Copied. It is cleared from the clipboard when this window closes.' 'Green' }
    elseif ($a -match '^(?i)b$' -and $sec.password) { $sec.shownOnce = $true; Save-SitePasswordAway $sec.password }
    elseif ($a -match '^(?i)m$' -and -not $sec.password) {
      $sec.password = New-SitePasswordNow; $sec.bitwardenSaved = $false; $sec.shownOnce = $false; Remember-Secret $sec.password; Save-FsSecrets $SecretsDir $sec
      Say 'Made and kept encrypted on this PC. The devices get it on the next "Fix this site".' 'Green'
      Save-SitePasswordAway $sec.password
    }
    elseif ($a -match '^(?i)t$') {
      $wasNone = -not $sec.password
      $p1 = Ask 'Type this site''s password (hidden):' -Secret; Remember-Secret $p1
      $p2 = Ask 'Type it again (hidden):' -Secret
      if (-not $p1 -or $p1 -cne $p2) { Say 'The two did not match - nothing changed.' 'Yellow'; continue }
      if ($p1.Length -lt 8) { Say 'Too short for cameras (8 or more) - nothing changed.' 'Yellow'; continue }
      if ($sec.password -and $sec.password -cne $p1 -and @($sec.known) -notcontains $sec.password) { $sec.known = @($sec.known) + @($sec.password) }   # the old one stays a try at this site
      $sec.password = $p1; $sec.bitwardenSaved = $false; $sec.shownOnce = $true; $sec.unreadable = $false; Save-FsSecrets $SecretsDir $sec
      Say 'Saved as this site''s password (encrypted, this PC only).' 'Green'
      if ($wasNone) { Save-SitePasswordAway $sec.password } else { Say 'Press B to put it in Bitwarden.' }
    }
    else { Say 'Type one of the letters shown.' }
  }
  Clear-Clip; Done 0
}

# =====================================================================================
#  ROLLBACK: put everything back the way a Fix run found it (-RollbackDir runs\FixSite-<time>)
# =====================================================================================
if ($Mode -eq 'Rollback') {
  $rf = Join-Path $RollbackDir 'rollback.json'
  if (-not $RollbackDir -or -not (Test-Path $rf)) { Say 'Pick a Fix this site run folder that has rollback.json in it.' 'Red'; Done 2 }
  $r0 = Get-Content $rf -Raw | ConvertFrom-Json; $run = [string]$r0.run
  $old = @{}; if ($sec.rollback -and $sec.rollback.ContainsKey($run)) { $o = $sec.rollback[$run]; if ($o -is [Collections.IDictionary]) { foreach ($k in $o.Keys) { $old[$k] = $o[$k] } } else { foreach ($q in $o.PSObject.Properties) { $old[$q.Name] = $q.Value } } }
  foreach ($v in $old.Values) { Remember-Secret ([string]$v) }
  # 2.2.1 (review H8): every undo step that worked is written down (undo-progress.json), so pressing Undo again after a problem only
  # redoes what is still left; "undone" is written only when EVERYTHING went back.
  $progF = Join-Path $RollbackDir 'undo-progress.json'; $prog = @{}
  if (Test-Path -LiteralPath $progF) { try { foreach ($q in (Get-Content -LiteralPath $progF -Raw | ConvertFrom-Json).PSObject.Properties) { $prog[$q.Name] = $q.Value } } catch {} }
  $isDone = { param($k) return $prog.ContainsKey($k) }
  $markDone = { param($k) $prog[$k] = (Get-Date -Format 's'); try { ($prog | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $progF -Encoding UTF8 } catch {} }
  Say ('Undo of the run from ' + $run + ' on ' + [string]$r0.taken_on + ': ' + @($r0.cameras).Count + ' camera(s), ' + @($r0.nvrs).Count + ' NVR move(s).' + $(if ($prog.Count) { ' (' + $prog.Count + ' step(s) were already put back by an earlier undo; they are skipped.)' } else { '' }))
  if ((Ask 'Type YES to put them back the way that run found them.').Trim() -notmatch '^(?i)yes$') { Say 'Stopped - nothing changed.'; Done 2 }
  $pcIx = -1; if ($r0.PSObject.Properties['pc'] -and $r0.pc -and $r0.pc.PSObject.Properties['ifIndex']) { $pcIx = [int]$r0.pc.ifIndex }
  $pc = $(if ($Mode -ne 'DryRun') { Get-FsPcNet $pcIx } else { $null })
  if ($pc) { $script:FsSubnet = [pscustomobject]@{ ip = $pc.ip; prefix = [int]$pc.prefix } }
  $pcScheme = $(if ($pc) { Get-FsScheme ([pscustomobject]@{ pc = $pc }) $r0 } else { '' })   # 2.2.2 (H9): no router -> the run's saved scheme
  $nvrPwR = @{}; foreach ($k in @($sec.nvr.Keys)) { $nvrPwR[$k] = [string]$sec.nvr[$k] }
  $bad = 0
  $rcams = @($r0.cameras); [array]::Reverse($rcams)
  foreach ($c in $rcams) {
    if (-not $c) { continue }
    $ck = 'cam|' + [string]$c.mac + '|' + [string]$c.ip_before
    $netDone = & $isDone ($ck + '|net')
    $ip = $(if ($c.ip_after -and -not $netDone) { [string]$c.ip_after } else { [string]$c.ip_before }); $res = @()
    if (-not (Test-FsOnScheme $ip $pcScheme)) { [void](Add-FsTempIp (Get-FsP3 $ip) $pc $tempState) }
    $oldPw = $(if ($old.ContainsKey([string]$c.mac + '|' + [string]$c.ip_before)) { [string]$old[[string]$c.mac + '|' + [string]$c.ip_before] } else { '' })
    $mkR = ConvertTo-FsMac ([string]$c.mac); $lastPw = $(if ($mkR -and $sec.cams -and $sec.cams.ContainsKey($mkR)) { [string]$sec.cams[$mkR] } else { '' })
    $candsR = @(@($lastPw, $sec.password, $oldPw) + @($sec.known) | Where-Object { $_ } | Select-Object -Unique | Select-Object -First ([int]$opts.maxPasswordTries))   # 2.0.1: a working camera kept its own password
    $pw = ''; foreach ($cand in $candsR) { if ($cand -and (Test-FsLogin $ip $c.brand $cand) -eq 'ok') { $pw = $cand; break } }
    if (-not $pw) { Say ('  ' + $c.name + ': cannot log in at ' + $ip + ' - not undone ' + $script:FsBad) 'Red'; $bad++; continue }
    $cr = Fs-Cred $pw
    if ($c.stream_before -and -not (& $isDone ($ck + '|settings'))) { $cur = Get-FsStream $ip $c.brand $cr; $want = [pscustomobject]@{ codec = [string]$c.stream_before.codec; fps = [int]$c.stream_before.fps; resolution = $(if ($c.stream_before.width) { '' + $c.stream_before.width + 'x' + $c.stream_before.height } else { 'keep' }); bitrate = [int]$c.stream_before.bitrate; gop = 0; smartCodec = 'keep' }
      $diff = @(Get-FsSettingsDiff $cur $want); if ([int]$c.stream_before.gop -and $cur -and [int]$cur.gop -ne [int]$c.stream_before.gop) { $diff += [pscustomobject]@{ field = 'gop'; from = $cur.gop; to = [int]$c.stream_before.gop } }
      if ([string]$c.stream_before.smartCodec -eq 'on' -and $cur.smartCodec -eq 'off') { $diff += [pscustomobject]@{ field = 'smartCodecOn'; from = 'off'; to = 'on' } }
      $diff = @($diff | Where-Object { $_.field -ne 'smartCodecOn' })   # Smart Codec back on: by hand (it was the cause on BYW)
      if ($diff.Count) { $w = Set-FsStream $ip $c.brand $cr $cur $diff; $res += [pscustomobject]@{ text = 'settings back'; ok = [bool]$w.ok }; if ($w.ok) { & $markDone ($ck + '|settings') } } else { & $markDone ($ck + '|settings') } }
    if ($c.password_changed -and $oldPw -and -not (& $isDone ($ck + '|password'))) {
      $ok = $(if ($pw -ceq $oldPw) { $true } else { Set-FsPassword $ip $c.brand $cr $oldPw })
      if ($ok) { $pw = $oldPw; $cr = Fs-Cred $pw; $mk = ConvertTo-FsMac ([string]$c.mac); if ($mk) { $sec.cams[$mk] = $oldPw }; & $markDone ($ck + '|password') }
      $res += [pscustomobject]@{ text = 'old password back'; ok = $ok }
    }
    # 2.2.1 (review H8): the address goes back as it was - a camera that had DHCP gets DHCP again (also when only "set fixed" on the same address)
    $nb = $c.net_before
    if ($nb -and $c.ip_after -and -not $netDone -and ($c.ip_after -ne $c.ip_before -or [bool]$nb.dhcp)) {
      $net = Get-FsNet $ip $c.brand $cr
      if ((Get-FsP3 ([string]$nb.ip)) -ne $pcScheme) { [void](Add-FsTempIp (Get-FsP3 ([string]$nb.ip)) $pc $tempState) }
      if (-not $net) { $res += [pscustomobject]@{ text = 'address could not be read - not put back'; ok = $false } }
      else {
        $w = Set-FsNet $ip $c.brand $cr $net ([string]$nb.ip) ([string]$nb.mask) ([string]$nb.gw) ([string]$nb.dns1) ([string]$nb.dns2) -Dhcp:([bool]$nb.dhcp)
        if ($w.ok -and $w.reboot) { [void](Restart-FsDevice $ip $c.brand $cr) }
        $back = $w.ok -and (Wait-FsDevice ([string]$nb.ip) $c.brand $pw ([int]$opts.moveWaitSec))
        if ($back) { & $markDone ($ck + '|net'); $ip = [string]$nb.ip; $res += [pscustomobject]@{ text = $(if ($nb.dhcp) { 'back on DHCP (answers on ' + $nb.ip + ')' } else { 'address back to ' + $nb.ip }); ok = $true } }
        elseif ($w.ok -and $nb.dhcp) { & $markDone ($ck + '|net'); $res += [pscustomobject]@{ text = ('back on DHCP: the router picks its address now (not on ' + $nb.ip + ' yet - use Find cameras to see it)'); ok = $null } }
        else { $res += [pscustomobject]@{ text = ('address back to ' + $nb.ip); ok = $false } }
      }
    }
    # 2.2.1 (review H8): the NVR channel exactly as the backup has it; a channel this run ADDED is deleted again
    if ($c.nvr -and $c.nvr.nvr -and -not (& $isDone ($ck + '|nvr'))) {
      $nv0 = [string]$c.nvr.nvr; $nv = Resolve-FsUndoNvrIp @($r0.nvrs) $nv0 $isDone   # 2.2.2 (H8): an NVR an earlier Undo moved back answers on its old address
      if ($nv -ne $nv0) { if (-not $nvrPwR.ContainsKey($nv) -and $nvrPwR.ContainsKey($nv0)) { $nvrPwR[$nv] = $nvrPwR[$nv0] }; if (-not (Test-FsOnScheme $nv $pcScheme)) { [void](Add-FsTempIp (Get-FsP3 $nv) $pc $tempState) } }
      if (-not $nvrPwR.ContainsKey($nv)) { $res += [pscustomobject]@{ text = ('NVR ' + $nv + ': no saved login - put ch ' + $c.nvr.channel + ' back by hand'); ok = $false } }
      else {
        $ncr = Fs-Cred $nvrPwR[$nv]; $bfile = $(if ($c.nvr.PSObject.Properties['before_file'] -and [string]$c.nvr.before_file) { Join-Path $RollbackDir (([string]$c.nvr.before_file) -replace '[\\/]', [string][IO.Path]::DirectorySeparatorChar) } else { '' })
        if ([string]$c.nvr.action -eq 'added') { $ok = Remove-FsNvrChannel $nv $ncr ([int]$c.nvr.channel); $res += [pscustomobject]@{ text = ('NVR ch ' + $c.nvr.channel + ' that the run added: removed'); ok = $ok } }
        elseif ($bfile -and (Test-Path -LiteralPath $bfile)) { $w = Restore-FsNvrChannel $nv $ncr ([int]$c.nvr.channel) ([IO.File]::ReadAllText($bfile)) $pw; $ok = [bool]$w.ok; $res += [pscustomobject]@{ text = ('NVR ch ' + $c.nvr.channel + ' back exactly as it was'); ok = $ok } }
        else { $w = Set-FsNvrChannel $nv $ncr ([int]$c.nvr.channel) ([string]$c.ip_before) $pw $c.brand ''; $ok = [bool]$w.ok; $res += [pscustomobject]@{ text = ('NVR ch ' + $c.nvr.channel + ' back to ' + $c.ip_before + ' (no saved copy of the channel)'); ok = $ok } }
        Say-PlainWarning $nv
        if ($ok) { & $markDone ($ck + '|nvr') }
      }
    }
    if (-not $res.Count) { Say ('  ' + $c.name + ': already put back by an earlier undo ' + $script:FsOk); continue }
    $line = Format-FsCheckLine $c.name $res; if ($line -like ('*' + $script:FsBad + '*')) { $bad++ }; Say ('  ' + $line)
  }
  # 2.0.3: NVR passwords back (before the NVR moves back, at the address the change was made on)
  foreach ($np in @($r0.nvr_passwords | Where-Object { $_ -and $_.changed })) {
    $nip0 = [string]$np.ip; if (& $isDone ('nvrpw|' + $nip0)) { continue }
    $oldN = $(if ($old.ContainsKey('nvr|' + $nip0)) { [string]$old['nvr|' + $nip0] } else { '' })
    $nip = Resolve-FsUndoNvrIp @($r0.nvrs) $nip0 $isDone   # 2.2.2 (H8): moved back by an earlier Undo -> its old address
    if ($nip -ne $nip0) { if (-not $nvrPwR.ContainsKey($nip) -and $nvrPwR.ContainsKey($nip0)) { $nvrPwR[$nip] = $nvrPwR[$nip0] }; if (-not (Test-FsOnScheme $nip $pcScheme)) { [void](Add-FsTempIp (Get-FsP3 $nip) $pc $tempState) } }
    if (-not $oldN -or -not $nvrPwR.ContainsKey($nip)) { Say ('  NVR ' + $nip + ': its old password is not on this PC - not undone ' + $script:FsBad) 'Red'; $bad++; continue }
    $ok = Set-FsPassword $nip 'Hikvision' (Fs-Cred $nvrPwR[$nip]) $oldN; Say-PlainWarning $nip
    if ($ok) { $nvrPwR[$nip] = $oldN; $sec.nvr[$nip] = $oldN; if ($nip -ne $nip0) { $nvrPwR[$nip0] = $oldN; $sec.nvr[$nip0] = $oldN }; & $markDone ('nvrpw|' + $nip0) } else { $bad++ }
    Say ('  NVR ' + $nip + ': old password back ' + $(if ($ok) { $script:FsOk } else { $script:FsBad }))
  }
  foreach ($n in @($r0.nvrs)) {
    if (& $isDone ('nvrmove|' + [string]$n.ip)) { continue }
    if (-not $nvrPwR.ContainsKey([string]$n.target)) { Say ('  NVR ' + $n.target + ': no saved login - move it back by hand to ' + $n.old.ip) 'Yellow'; $bad++; continue }
    $cr = Fs-Cred $nvrPwR[[string]$n.target]; $net = Get-FsNet ([string]$n.target) 'Hikvision' $cr; [void](Add-FsTempIp (Get-FsP3 ([string]$n.old.ip)) $pc $tempState)
    $w = Set-FsNet ([string]$n.target) 'Hikvision' $cr $net ([string]$n.old.ip) ([string]$n.old.mask) ([string]$n.old.gw) ([string]$n.old.dns1) ([string]$n.old.dns2) -Dhcp:([bool]$n.old.dhcp)
    if ($w.ok) { & $markDone ('nvrmove|' + [string]$n.ip) } else { $bad++ }
    Say ('  NVR: back to ' + $n.old.ip + $(if ($n.old.dhcp) { ' (DHCP)' } else { '' }) + ' ' + $(if ($w.ok) { $script:FsOk } else { $script:FsBad }))
  }
  Say-NetRestore (Remove-FsTempIps $tempState)
  try { Save-FsSecrets $SecretsDir $sec } catch {}
  if (-not $bad) { [IO.File]::WriteAllText((Join-Path $RollbackDir 'undone.txt'), (Get-Date -Format 's')) }
  else { [IO.File]::WriteAllText((Join-Path $RollbackDir 'undo-incomplete.txt'), ((Get-Date -Format 's') + ' ' + $bad + ' problem(s); Undo can be pressed again')) }
  Say $(if ($bad) { 'Undo finished with ' + $bad + ' problem(s) above. Press Undo again after fixing them: what already went back is not done twice.' } else { 'Undo finished: everything is back.' }) $(if ($bad) { 'Yellow' } else { 'Green' })
  Done $(if ($bad) { 4 } else { 0 })
}
# =====================================================================================
#  LOOK (read-only)
# =====================================================================================
# 2.0.2: New site - name it from what the scan sees, or recognise a site this PC already saved (NVR MAC / 2+ camera MACs)
function Resolve-NewSite($devs, [string]$gw) {
  $k = Find-FsKnownSite @(Get-FsKnownSiteFiles $SitesDir $driveRoots) $devs
  if ($k) {
    $script:list = $k.list; $script:listFrom = $k.path; $script:siteName = $k.site; $script:NewSite = $false
    if ($k.folder) { $script:siteFolder = $k.folder; $script:listPath = $k.path; $script:localList = Join-Path $SitesDir (Get-FsListFileName $k.site) }
    else { $script:localList = $k.path; $fd = Find-FsSiteFolder $k.site $driveRoots; if ($fd -and (Split-Path -Leaf $fd) -eq $k.site) { $script:siteFolder = $fd; $script:listPath = Join-Path (Join-Path $fd 'Docs') 'WireIt site list.json' } }
    if ($k.list.PSObject.Properties['siteId'] -and $k.list.siteId) { $script:siteId = [string]$k.list.siteId }
    Say ('This network was saved before on this PC as "' + $k.site + '" (its NVR / cameras match). Using that site and its list: ' + @($k.list.cameras).Count + ' camera(s).') 'Green'
  } else {
    $base = New-FsNewSiteName $gw; $name = $base; $n = 1
    while ((Test-Path -LiteralPath (Join-Path $SitesDir (Get-FsListFileName $name))) -or (Test-Path -LiteralPath (Get-FsSecretPath $SecretsDir $name))) { $n++; $name = $base + ' (' + $n + ')' }
    $script:siteName = $name; $script:localList = Join-Path $SitesDir (Get-FsListFileName $name)
    Say ('Site: ' + $name + '  (named from the network it found; you can type the address after the list of problems)')
  }
  $script:sec = Read-FsSecrets $SecretsDir $script:siteName
  foreach ($p in @($script:sec.password) + @($script:sec.known)) { Remember-Secret $p }
  Stop-IfUnreadable $script:sec
  if ($k) { try { Set-Content -LiteralPath (Join-Path $runDir 'site.txt') -Value $script:siteName -Encoding UTF8 } catch {} }   # the window fills the site box with it (a new name only once it is saved: Save-NewSite)
}
function Get-NewSiteDefaults([string]$brand) { if ($NewSite -or -not $sec.password) { return @(Get-FsFactoryPasswords $brand) }; return @() }   # old factory passwords, last: a new site, or a site with no site password yet (2.0.3)

$pwFor = @{}     # mac/ip -> the password that works (memory only)
$nvrPw = @{}     # nvr ip -> password
if ($Mode -eq 'DryRun') {
  if (-not $Recorded -or -not (Test-Path $Recorded)) { Say 'Dry run needs -Recorded <scan file>.' 'Red'; Done 2 }
  $observed = Get-Content $Recorded -Raw | ConvertFrom-Json
  Say ('DRY RUN from a recorded scan (' + (Split-Path -Leaf $Recorded) + ', taken ' + [string]$observed.taken + '). Nothing on the network is touched.') 'Cyan'
  if ($NewSite) { Resolve-NewSite @($observed.devices) ([string]$observed.pc.gw) }
} else {
  if (-not $MockUrl) {
    $adm = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $adm) { Say 'Please start it from the Toolkit (it asks Windows for permission): it needs that to reach cameras on the wrong IP scheme.' 'Red'; Done 2 }
  }
  if ($Mode -eq 'Fix' -and -not $NewSite -and -not $sec.password) { [void](Ask-SitePassword) }   # 2.1.0: asked once, at the start
  Say 'Looking at the site network (about a minute). Nothing is changed yet.'
  # 2.2.1 (review H9): the tech picks the camera network when this PC is on more than one (Wi-Fi for internet + Ethernet for the cameras)
  $pcAll = @(Get-FsPcNets); $pc = Get-FsPcNet
  if ($pcAll.Count -gt 1) {
    Say 'This PC is on more than one network:'
    foreach ($l in (Format-FsPcNetChoice $pcAll)) { Say ('  ' + $l) }
    for ($k = 0; $k -lt 3; $k++) { $sel = Select-FsPcNet $pcAll (Ask ('Which one are the cameras on? Type its number (Enter = 1).')); if ($sel) { $pc = $sel; break }; Say 'Type one of the numbers shown.' 'Yellow' }
  }
  if ($pc) { $script:FsSubnet = $(if (Test-FsLinkLocal ([string]$pc.ip)) { $null } else { [pscustomobject]@{ ip = $pc.ip; prefix = [int]$pc.prefix } }); Say ('Camera network: ' + $(if ($pc.name) { $pc.name + ', ' } else { '' }) + 'this PC ' + $pc.ip + ', mask ' + $pc.mask + $(if ($pc.gw) { ', router ' + $pc.gw } else { ', no router' }) + '.') }
  if (-not $pc) { Say 'This PC is not on any network. Plug it into the site network (or its camera switch) and press the button again.' 'Red'; Done 2 }
  # 2.2.2 (re-review H9): an isolated camera switch (no router, maybe only a 169.254 address) works too: the scheme comes from the
  # router when there is one, else from the saved site list, else from this PC's own fixed address
  $scheme = Get-FsScheme ([pscustomobject]@{ pc = $pc }) $list
  if (-not $scheme) { Say 'This network has no router, and there is no saved site list or fixed PC address to tell the site''s IP scheme. Give this PC a fixed address on the site scheme (for example 192.168.1.250), or plug in the site router, and press the button again.' 'Red'; Done 2 }
  if (-not $pc.gw) { Say ('No router on this network: using the site scheme ' + $scheme + '.x' + $(if ($list -and [string](Get-FsProp $list 'scheme' '')) { ' from the saved site list' } else { '' }) + '; moved devices get router ' + $scheme + '.1 (the WireIt standard).') 'Yellow' }
  $devNet = Get-FsDeviceNet $pc $scheme
  $observed = [ordered]@{ taken = (Get-Date -Format 's'); pc = [ordered]@{ ip = $pc.ip; gw = $pc.gw; mask = $pc.mask; prefix = [int]$pc.prefix; dhcp = $pc.dhcp; ifIndex = [int]$pc.ifIndex; name = [string]$pc.name }; devices = @(); nvrs = @(); ports = @{} }
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
  if ($NewSite) { Resolve-NewSite $found $pc.gw }
  # list addresses nobody answered for: try them too (a camera can miss the discovery)
  foreach ($c in @($(if ($list) { $list.cameras } else { @() }))) { $lip = [string]$c.ip; if ($lip -and -not @($found | Where-Object { $_.ip -eq $lip }).Count -and (Get-FsP3 $lip) -eq $scheme) { $s = Test-FsLogin $lip (Get-FsBrand ([string]$c.brand) ([string]$c.model)) ''; if ($s -ne 'noanswer') { $found += [pscustomobject]@{ brand = (Get-FsBrand ([string]$c.brand) ([string]$c.model)); model = [string]$c.model; serial = [string]$c.serial; mac = [string]$c.mac; ip = $lip; kind = 'camera'; activated = $true } } } }
  $found = @($found | Where-Object { $_.ip -and $_.ip -ne $pc.ip -and $_.ip -ne $pc.gw -and ($_.kind -in @('camera', 'nvr')) })
  foreach ($d in $found) { if ($d.model) { $script:FsModels[[string]$d.ip] = [string]$d.model } }   # 2.2.2 (H1): the no-HTTPS model list
  # 2. reach the wrong schemes (temporary PC address, removed at the end)
  $schemes = @($found | Where-Object { -not (Test-FsOnScheme $_.ip $scheme) } | ForEach-Object { Get-FsP3 $_.ip } | Where-Object { $_ -and $_ -ne $scheme -and -not (Test-FsPoeNet ($_ + '.1')) } | Select-Object -Unique | Select-Object -First 3)
  if ((Get-FsP3 ([string]$pc.ip)) -ne $scheme -and -not ($script:FsSubnet -and (Test-FsInSubnet ($scheme + '.1') ([string]$pc.ip) ([int]$pc.prefix)))) { $schemes = @($scheme) + @($schemes) }   # 2.2.2 (H9): a PC with only 169.254 needs an address on the site scheme too
  foreach ($p3 in $schemes) { $t = Add-FsTempIp $p3 $pc $tempState; if ($t) { Fs-Log ('temp address ' + $t + ' added') } else { Say ('Could not give this PC a temporary address on ' + $p3 + '.x - cameras there can only be listed.') 'Yellow' } }
  $reach = { param($ip) $p3 = Get-FsP3 $ip; return ((Test-FsOnScheme $ip $scheme) -or @($script:FsTemps | Where-Object { $_.p3 -eq $p3 }).Count -gt 0) }
  # 3. NVRs: log in (saved passwords, then ONE question), read the channel list
  $nvrIps = @($found | Where-Object { $_.kind -eq 'nvr' } | ForEach-Object { $_.ip })
  if ($list) { foreach ($n in @($list.nvrs)) { if ($n.ip -and $nvrIps -notcontains [string]$n.ip -and (& $reach ([string]$n.ip)) -and (Test-FsLogin ([string]$n.ip) 'Hikvision' '') -ne 'noanswer') { $nvrIps += [string]$n.ip } } }
  foreach ($nip in $nvrIps) {
    $cands = @(); if ($sec.nvr -and $sec.nvr.ContainsKey($nip)) { $cands += [pscustomobject]@{ label = 'saved NVR password'; value = [string]$sec.nvr[$nip] } }
    $cands += @(Get-FsPasswordCandidates $sec ([int]$opts.maxPasswordTries - 1) '' (Get-NewSiteDefaults 'Hikvision'))
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
    $fp = Find-FsPassword $d.ip $o.brand @(Get-FsPasswordCandidates $sec ([int]$opts.maxPasswordTries - 1) $o.mac (Get-NewSiteDefaults $o.brand)) ([int]$opts.maxPasswordTries - 1)
    if ($fp.state -eq 'noanswer') { $o.answers = $false; $o.login = '' }
    elseif ($fp.state -eq 'ok') {
      $o.login = $fp.label; $pwFor[$d.ip] = $fp.value; $cr = Fs-Cred $fp.value
      $mk = ConvertTo-FsMac $o.mac; if ($mk) { $sec.cams[$mk] = $fp.value; $camPwSeen = $true }   # 2.0.1: remembered (encrypted) so a working camera on its own password is found first next run
      $st = Get-FsStream $d.ip $o.brand $cr; if ($st) { $o.streams = [ordered]@{ codec = $st.codec; fps = $st.fps; width = $st.width; height = $st.height; bitrate = $st.bitrate; gop = $st.gop; smartCodec = $st.smartCodec; maxWidth = $st.maxWidth; maxHeight = $st.maxHeight } }
      $nt = Get-FsNet $d.ip $o.brand $cr; if ($nt) { $o.dhcp = [bool]$nt.dhcp; if (-not $o.mac -and $o.brand -eq 'Hikvision') { $o.mac = (Get-FsInfo $d.ip $o.brand $cr).mac } }
    } else { $o.login = $fp.state; $o.tries = $fp.tries }
    $observed.devices += [pscustomobject]$o
  }
  if ($camPwSeen -and -not $NewSite) { try { Save-FsSecrets $SecretsDir $sec } catch {} }   # 2.0.2: a new site's secrets are saved under its final name (after the address question)
  if ($pmSite) { $observed.ports = Get-FsPortsFromPortMap $pmSite }
  # 2.1.0: a new site (named only by the scan) with no saved password is asked here, once; "Yes" = its password is the one try on the cameras nobody could log in to
  $skipCamAsk = $false
  if ($Mode -eq 'Fix' -and -not $sec.password -and -not $sitePwAsked) {
    $tp = Ask-SitePassword
    if ($tp) {
      $unkS = @($observed.devices | Where-Object { $_.kind -eq 'camera' -and $_.login -in @('unknown', 'refused') -and [int]$_.tries -lt [int]$opts.maxPasswordTries })
      $workedS = 0
      foreach ($u in $unkS) {
        if ((Test-FsLogin $u.ip $u.brand $tp) -eq 'ok') {
          $u.login = 'site password'; $pwFor[$u.ip] = $tp; $workedS++; $mk = ConvertTo-FsMac ([string]$u.mac); if ($mk) { $sec.cams[$mk] = $tp }
          $st = Get-FsStream $u.ip $u.brand (Fs-Cred $tp); if ($st) { $u.streams = [ordered]@{ codec = $st.codec; fps = $st.fps; width = $st.width; height = $st.height; bitrate = $st.bitrate; gop = $st.gop; smartCodec = $st.smartCodec; maxWidth = $st.maxWidth; maxHeight = $st.maxHeight } }
        } else { $u.tries = [int]$u.tries + 1 }
      }
      if ($unkS.Count) { Say ('The site password works on ' + $workedS + ' of the ' + $unkS.Count + ' camera(s) nobody could log in to (tried once each).') $(if ($workedS) { 'Green' } else { 'Yellow' }); $skipCamAsk = $true }
    }
  }
  Complete-SitePassword
  # 5. ONE question for the unknown passwords (Moshe Nov 3 5:24 PM: "sometimes I will know")
  $unk = @($observed.devices | Where-Object { $_.kind -eq 'camera' -and $_.login -in @('unknown', 'refused') })
  if ($unk.Count -and -not $skipCamAsk) {
    $chNames = @{}; foreach ($nv in @($observed.nvrs)) { foreach ($cc in @($nv.channels)) { if ($cc.ip -and $cc.name) { $chNames[[string]$cc.ip] = [string]$cc.name } } }
    $names = @($unk | ForEach-Object { if ($chNames.ContainsKey([string]$_.ip)) { $chNames[[string]$_.ip] + ' ' + $_.ip } else { $_.ip } })
    $typed = Ask ('Know the password for ' + $(if ($unk.Count -eq 1) { 'this camera' } else { 'these ' + $unk.Count + ' cameras' }) + ' (' + ($names -join ', ') + ')? Type it (hidden), or press Enter to skip - a camera with a problem gets the official reset; one whose video is fine is left alone.') -Secret
    if ($typed) {
      Remember-Secret $typed; $worked = 0
      foreach ($u in $unk) { if ([int]$u.tries -ge [int]$opts.maxPasswordTries) { continue }; $s = Test-FsLogin $u.ip $u.brand $typed; if ($s -eq 'ok') { $u.login = 'typed'; $pwFor[$u.ip] = $typed; $worked++; $mk = ConvertTo-FsMac ([string]$u.mac); if ($mk) { $sec.cams[$mk] = $typed }; $cr = Fs-Cred $typed; $st = Get-FsStream $u.ip $u.brand $cr; if ($st) { $u.streams = [ordered]@{ codec = $st.codec; fps = $st.fps; width = $st.width; height = $st.height; bitrate = $st.bitrate; gop = $st.gop; smartCodec = $st.smartCodec; maxWidth = $st.maxWidth; maxHeight = $st.maxHeight } } } elseif ($s -eq 'locked') { $u.login = 'locked' } }
      if ($worked) { if (@($sec.known) -notcontains $typed) { $sec.known = @($sec.known) + @($typed) }; Save-FsSecrets $SecretsDir $sec; Say ('That password works on ' + $worked + ' of ' + $unk.Count + '. Saved to the site''s secret store (encrypted, this PC only).') 'Green' }
      else { Say 'That password did not work on them (tried once each). Cameras with a problem get the official reset; ones whose video is fine are left alone.' 'Yellow' }
    }
  }
  ($observed | ConvertTo-Json -Depth 8) | Set-Content -Path (Join-Path $runDir 'scan.json') -Encoding UTF8   # no passwords in it: logins are labels only
}

# =====================================================================================
#  PLAN
# =====================================================================================
$opts.newSite = [bool]$NewSite
$opts.factoryToSite = [bool]($NewSite -or -not $sec.password)   # 2.0.3: no site password yet = devices on a factory password get it
$plan = New-FsPlan $list $observed $opts
# 2.1.0 (Moshe, Nov 6 2026): devices that work with ANOTHER password: by default switch them to the site password so everything matches - asked first.
if ($Mode -eq 'Fix' -and -not $opts.passwordAll) {
  $diff = @(@($plan.cams) + @($plan.nvrs) | Where-Object { $_.login -and $_.login -ne 'site password' -and $_.login -notmatch '^(factory default|unknown|locked|refused|unreachable|noanswer|notfound)$' })
  if ($diff.Count) {
    if (Ask-Choice ([string]$diff.Count + ' device(s) use a different password. Switch them to the site password so all match?') 'Yes, make all the same' 'No, keep different') { $opts.passwordAll = $true; $plan = New-FsPlan $list $observed $opts }
    else { Say ('Kept as they are: ' + $diff.Count + ' device(s) keep their own password. Each one is saved on this PC under its own device (' + (@($diff | ForEach-Object { if ($_.name) { $_.name } else { $_.ip } }) -join ', ') + ').') 'Yellow' }
  }
}
$plan.site = $siteName
if ($NewSite) { $plan.notes += ('It saves this site as "' + $siteName + '" on this PC when it finishes (no passwords in the list), so next time it knows what should be here.') }
($plan | ConvertTo-Json -Depth 8) | Set-Content -Path (Join-Path $runDir 'plan.json') -Encoding UTF8
Write-Host ''
Say '----- What is wrong, and what it will do -----' 'Cyan'
foreach ($l in (Format-FsPlan $plan)) { Say ('  ' + $l) }
# 2.0.2: a new site's address - optional, asked only AFTER the plan screen (Enter keeps the name the scan gave it)
function Rename-NewSite([string]$addr) {
  $clean = (($addr -replace '[\\/:*?"<>|]', ' ') -replace '\s+', ' ').Trim(); if ($clean.Length -gt 60) { $clean = $clean.Substring(0, 60).Trim() }
  if (-not $clean -or -not (Get-FsListFileName $clean)) { return }
  $fold = Find-FsSiteFolder $clean $driveRoots; if ($fold -and (Split-Path -Leaf $fold) -ne $clean) { $fold = $null }   # only the exact folder: "12 Main" must not land in "112 Main St"
  $newName = $(if ($fold) { Split-Path -Leaf $fold } else { $clean })
  $newList = Join-Path $SitesDir (Get-FsListFileName $newName)
  $dl = $(if ($fold) { Join-Path (Join-Path $fold 'Docs') 'WireIt site list.json' } else { '' })
  if ($newName -eq $siteName) { return }
  if ((Test-Path -LiteralPath $newList) -or ($dl -and (Test-Path -LiteralPath $dl)) -or (Test-Path -LiteralPath (Get-FsSecretPath $SecretsDir $newName))) {
    Say ('"' + $newName + '" is already a saved site, so this run stays "' + $siteName + '" (nothing of that site is overwritten). Next time there, pick it in the site box.') 'Yellow'; return
  }
  $oldSec = Get-FsSecretPath $SecretsDir $siteName
  $script:siteName = $newName; $script:localList = $newList; $script:listPath = $dl; $script:siteFolder = $fold
  $sec.site = $newName; $plan.site = $newName
  if (Test-Path -LiteralPath $oldSec) { try { Save-FsSecrets $SecretsDir $sec; Remove-Item -LiteralPath $oldSec -Force } catch {} }
  Say ('Site name: ' + $newName + $(if ($fold) { ' (its Drive folder was found: the list goes there too)' } else { '' })) 'Green'
}
if ($NewSite -and $Mode -eq 'Fix') {
  $addr = [string](Ask ('Optional: type this site''s address to name it (like 12 Main St), or just press Enter to keep "' + $siteName + '".'))
  if ($addr.Trim()) { Rename-NewSite $addr.Trim() }
}
# 2.2.1 (review H6): an NVR that only needs Hikvision's official password reset is work too (it was left out, so the run said "Nothing to change")
$work = @($plan.cams | Where-Object { $_.state -eq 'fix' -or ($_.state -eq 'missing' -and $_.steps.Count) }) + @($plan.nvrs | Where-Object { $_.steps -contains 'move' -or $_.steps -contains 'password' -or $_.steps -contains 'reset' })
function Save-NewSite {
  # 2.0.2: a new site is saved without asking (a list on this PC, no passwords; the secrets file under the same name), so the next visit finds it
  $nl = New-FsSiteList $siteName '' $plan $observed
  $json = $nl | ConvertTo-Json -Depth 6
  New-Item -ItemType Directory -Force -Path (Split-Path $localList) | Out-Null; $json | Set-Content -LiteralPath $localList -Encoding UTF8
  if ($listPath) { try { New-Item -ItemType Directory -Force -Path (Split-Path $listPath) | Out-Null; $json | Set-Content -LiteralPath $listPath -Encoding UTF8 } catch { Say ('Could not write the list to Drive (' + $_.Exception.Message + '). It is saved on this PC.') 'Yellow' } }
  try { Save-FsSecrets $SecretsDir $sec } catch {}
  try { Set-Content -LiteralPath (Join-Path $runDir 'site.txt') -Value $siteName -Encoding UTF8 } catch {}
  Say ('Saved this site as "' + $siteName + '" on this PC: ' + @($nl.cameras).Count + ' camera(s), no passwords. Next time pick it in the site box, or press New site again - it recognises the NVR.') 'Green'
}
function Offer-List {
  if ($NewSite) { if ($Mode -eq 'DryRun') { Say ('(dry run) At the end it would save this site as "' + $siteName + '" on this PC.') } else { Save-NewSite }; return }
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
# 2.2.1 (review M5): what Hikvision's official reset needs (form details, reply relay, upload key, a browser) is said on the plan screen, before the YES
$hikNeed = @(@($plan.nvrs | Where-Object { $_.steps -contains 'reset' }) + @($plan.cams | Where-Object { $_.state -eq 'fix' -and $_.steps -contains 'reset' -and $_.brand -eq 'Hikvision' }))
if ($hikNeed.Count -and $hikFlowOk -and $Mode -in @('Fix', 'Plan')) { foreach ($hw in @(Get-HikReadiness (Get-HikConfig $cfgAll $here) $here)) { Say ('  Hikvision reset: ' + $hw) 'Yellow' } }
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
# the site password: ONE per site, saved BEFORE anything changes, so it is never lost (asked once after the scan, see "2.1.0 site password").
$newPw = $false
if ($Mode -eq 'DryRun' -and -not $sec.password) { $sec.password = 'Dryrun-not-a-password'; $newPw = $true }   # a dry run asks nothing and saves nothing; the real run asks
elseif ($sitePwPending) { $newPw = $true; Save-FsSecrets $SecretsDir $sec }
elseif (-not $sec.password) { Say 'This site has no site password, so nothing was changed. Press the button again.' 'Yellow'; Done 2 }
$sitePw = $sec.password; Remember-Secret $sitePw
$rb = [ordered]@{ tool = ('WireIt Toolkit ' + $script:FsVersion + ' Fix this site'); site = $siteName; run = $stamp; taken_on = $env:COMPUTERNAME; note = 'Old passwords are NOT in this file: they are in the site secret store on this PC (encrypted), under this run.'; pc = $(if ($pc) { [ordered]@{ ifIndex = [int]$pc.ifIndex; name = [string]$pc.name; ip = [string]$pc.ip; prefix = [int]$pc.prefix } } else { $null }); nvrs = @(); cameras = @() }
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
      'unplug' { $r += [pscustomobject]@{ text = 'unplug 10 s (asks you)'; ok = $null } } 'verify' { $r += [pscustomobject]@{ text = $(if ($c.pwOnly) { 'video held 20 s (else old password back)' } else { 'video held 20 s' }); ok = $null } }
    } }
    Say ('  ' + (Format-FsCheckLine $c.name $r))
  }
  foreach ($c in @($plan.cams | Where-Object { $_.state -eq 'missing' })) { Say ('  ' + $c.name + ': ' + $(if ($c.steps -contains 'poe') { 'power-cycle ' + $c.switch + ' port ' + $c.port + ', look again; if still gone: ' } else { '' }) + 'go check ' + $(if ($null -ne $c.port) { 'port ' + $c.port } else { 'its cable' })) }
  foreach ($n in @($plan.nvrs | Where-Object { $_.steps -contains 'password' })) { Say ('  NVR ' + $n.ip + ': site password set') }
  foreach ($n in @($plan.nvrs | Where-Object { $_.steps -contains 'reset' })) { Say ('  NVR ' + $n.ip + ': Hikvision''s official password reset, then the site password') }
  if ($newPw) { Say '  The site password (typed, or made for you) would be kept encrypted on this PC and offered for saving in Bitwarden.' }
  Offer-List
  Say ''; Say 'Dry run done: nothing was changed.' 'Green'; Done 0
}

# =====================================================================================
#  2.1.0  HIKVISION OFFICIAL RESET: every Hik device nobody can log in to (NVR and cameras), automatic up to the page's picture check
# =====================================================================================
$hikFixed = @{}      # mac -> $true when the official reset set the site password
$hikPending = @{}    # mac -> 'waiting for Hikvision's reply' / reason
if ($hikFlowOk -and $Mode -ne 'DryRun' -and -not $MockUrl) {
  $hikT = @(); foreach ($n in @($plan.nvrs | Where-Object { $_.steps -contains 'reset' })) { $hikT += [pscustomobject]@{ mac = (ConvertTo-FsMac ([string]$n.mac)); ip = $n.ip; kind = 'nvr' } }
  foreach ($c in @($plan.cams | Where-Object { $_.state -eq 'fix' -and $_.steps -contains 'reset' -and $_.brand -eq 'Hikvision' })) { $hikT += [pscustomobject]@{ mac = (ConvertTo-FsMac ([string]$c.mac)); ip = $c.ip; kind = 'camera' } }
  if ($hikT.Count) {
    Say ''; Say ('----- Hikvision official password reset: ' + $hikT.Count + ' device(s) (NVR and cameras alike; no power-cycle, no reset button) -----') 'Cyan'
    $script:HkSay = { param($t, $c) if ($c) { Say $t $c } else { Say $t } }
    $script:HkAsk = { param($t) Ask $t }
    $script:SadpLog = { param($l) Fs-Log $l }
    $hikCfg = Get-HikConfig $cfgAll $here   # 2.2.0: reply relay (no mail password on this PC) + the "I got Hik's email" button
    $hikState = Join-Path $SecretsDir ('hikreset-' + ($siteName -replace '[^A-Za-z0-9_-]+', '_'))
    $verify = { param($ip, $p) return ((Test-FsLogin $ip 'Hikvision' $p) -eq 'ok') }
    if ($Ipc) {
      # 2.2.0: this run has no screen (the "Fix this site" task): Hikvision's page opens in the Toolkit window's login, the waiting state is shown there
      $script:HkPortalHook = {
        param($d, $form, $tmo)
        $rq = [IO.File]::ReadAllText([string]$d.requestFile)
        $n = Send-FsIpc $Ipc @{ kind = 'portal'; model = [string]$d.model; serial = [string]$d.serial; shortSerial = [string]$d.shortSerial; ip = [string]$d.ip; requestName = (Split-Path -Leaf ([string]$d.requestFile)); request = $rq; form = $form; timeoutSec = $tmo }
        $r = Wait-FsIpcAnswer $Ipc $n 'portal' ($tmo + 120)
        if ($null -eq $r) { return 'timeout' }; return $r
      }
      $script:HkStatus = { param($st) try { Write-FsIpcJson (Join-Path $Ipc 'hik.json') $st } catch {} }
    }
    $hs = Invoke-HikResetStage -Targets $hikT -SitePassword $sitePw -StateDir $hikState -Config $hikCfg -ToolkitDir $here -VerifyLogin $verify -WaitMinutes ([int]$hikCfg.waitMinutes) -InboxDir (Join-Path $here 'inbox\hik') -Site $siteName
    # 2.2.1 (review H5): the reset module names MACs aa-bb-cc-..., this script aa:bb:cc:...: one form (ConvertTo-FsMac) for every key
    foreach ($m in @($hs.fixed)) { $mk = ConvertTo-FsMac ([string]$m); if ($mk) { $hikFixed[$mk] = $true } }
    foreach ($p in @($hs.pending)) { $mk = ConvertTo-FsMac ([string]$p.mac); if ($mk) { $hikPending[$mk] = [string]$p.reason } }
    foreach ($n in @($plan.nvrs | Where-Object { $_.steps -contains 'reset' })) {
      if ($hikFixed.ContainsKey((ConvertTo-FsMac ([string]$n.mac)))) { $nvrPw[$n.ip] = $sitePw; $sec.nvr[$n.ip] = $sitePw; Save-FsSecrets $SecretsDir $sec; $l = Format-FsCheckLine ('NVR ' + $n.ip) @([pscustomobject]@{ text = 'official reset done, site password set'; ok = $true }); Say $l 'Green'; $results += $l; $okCount++ }
      else { $l = Format-FsCheckLine ('NVR ' + $n.ip) @([pscustomobject]@{ text = $(if ($hikPending.ContainsKey((ConvertTo-FsMac ([string]$n.mac)))) { $hikPending[(ConvertTo-FsMac ([string]$n.mac))] } else { 'official reset not finished' }); ok = $false }); Say $l 'Yellow'; $results += $l; $badCount++ }
    }
  }
}

# =====================================================================================
#  FIX: NVRs on the wrong scheme first (cameras are put back on them)
# =====================================================================================
foreach ($n in @($plan.nvrs | Where-Object { $_.steps -contains 'move' })) {
  # 2.2.3 (Codex #12/#17/#18): every way an NVR move can fail is a red checklist line and counts as a problem (exit code 4);
  # the move needs a backup that can bring it back, and its new address is checked LIVE first (no duplicate .20).
  $nvrFail = { param($why) $l = 'NVR ' + $n.ip + ': ' + $why + ' ' + $script:FsBad; Say $l 'Red'; $script:results += $l; $script:badCount++ }
  if (-not $nvrPw.ContainsKey($n.ip)) { & $nvrFail 'not moved (no NVR login)'; continue }
  $cr = Fs-Cred $nvrPw[$n.ip]; [void](Add-FsTempIp (Get-FsP3 $n.ip) $pc $tempState)
  $nbf = @(Save-FsBackup $n.ip 'Hikvision' $cr (Join-Path $runDir ('backup\NVR-' + $n.ip)))
  if (-not (Test-FsBackupComplete $nbf 'Hikvision' -Nvr)) { & $nvrFail 'backup could not be read - NVR not moved'; continue }
  $net = Get-FsNet $n.ip 'Hikvision' $cr
  if (-not $net) { & $nvrFail 'its address settings could not be read - not moved'; continue }
  $taken = @($plan.cams | ForEach-Object { [string]$_.target; [string]$_.ip }) + @($plan.nvrs | Where-Object { $_ -ne $n } | ForEach-Object { [string]$_.target; [string]$_.ip })
  $t = Get-FsNvrMoveTarget $n.target $plan.scheme $opts.nvrHosts $taken
  if (-not $t) { & $nvrFail ('not moved: ' + $n.target + ' (and the other NVR addresses) already answer on the network'); continue }
  if ($t -ne $n.target) { Say ('NVR ' + $n.ip + ': ' + $n.target + ' is already used by another device - moving it to ' + $t + ' instead') 'Yellow'; $n.target = $t }
  $rb.nvrs += [ordered]@{ ip = $n.ip; target = $n.target; iface = $net.iface; old = [ordered]@{ ip = $net.ip; mask = $net.mask; gw = $net.gw; dhcp = $net.dhcp; dns1 = $net.dns1; dns2 = $net.dns2 } }; Save-Rb
  $w = Set-FsNet $n.ip 'Hikvision' $cr $net $n.target $devNet.mask $devNet.gw
  if ($w.ok -and $w.reboot) { [void](Restart-FsDevice $n.ip 'Hikvision' $cr) }
  $back = $w.ok -and (Wait-FsDevice $n.target 'Hikvision' $nvrPw[$n.ip] ([int]$opts.rebootWaitSec))
  $l = Format-FsCheckLine ('NVR ' + $n.ip) @([pscustomobject]@{ text = $(if ($w.ok) { 'moved -> ' + (Get-FsShort $n.target) } else { 'the NVR refused the new address' }); ok = $back })
  Say $l $(if ($back) { 'Green' } else { 'Red' }); $results += $l
  if ($back) { $okCount++; $nvrPw[$n.target] = $nvrPw[$n.ip]; $sec.nvr[$n.target] = $nvrPw[$n.ip]; Save-FsSecrets $SecretsDir $sec; $n.moved = $true } else { $badCount++; $n.moved = $false }
}
# 2.0.3: NVR password -> the site password (factory password at a new site, or the option ticked). Channels keep the camera logins.
$rb.nvr_passwords = @()
foreach ($n in @($plan.nvrs | Where-Object { $_.steps -contains 'password' })) {
  $nip = $(if ($n.target -and $nvrPw.ContainsKey($n.target)) { $n.target } else { $n.ip })
  if (-not $nvrPw.ContainsKey($nip)) { $l = 'NVR ' + $nip + ': no NVR login, so its password was not changed ' + $script:FsBad; Say $l 'Red'; $results += $l; $badCount++; continue }
  $oldN = $nvrPw[$nip]
  if ($oldN -ceq $sitePw) { Say ('NVR ' + $nip + ': already on the site password ' + $script:FsOk) 'Green'; continue }
  $sec.rollback[$stamp]['nvr|' + $nip] = $oldN; Save-FsSecrets $SecretsDir $sec
  $np = [ordered]@{ ip = $nip; changed = $false }; $rb.nvr_passwords += $np; Save-Rb
  $ok = Set-FsPassword $nip 'Hikvision' (Fs-Cred $oldN) $sitePw
  Say-PlainWarning $nip
  if ($ok -and (Test-FsLogin $nip 'Hikvision' $sitePw) -eq 'ok') { $nvrPw[$nip] = $sitePw; $sec.nvr[$nip] = $sitePw; $np.changed = $true; Save-FsSecrets $SecretsDir $sec; Save-Rb; $l = Format-FsCheckLine ('NVR ' + $nip) @([pscustomobject]@{ text = 'site password set'; ok = $true }); $okCount++ }
  else { $l = Format-FsCheckLine ('NVR ' + $nip) @([pscustomobject]@{ text = 'the NVR refused the new password - it keeps its old one'; ok = $false }); $badCount++ }
  $results += $l; Say $l $(if ($np.changed) { 'Green' } else { 'Red' })
}
$nvrCred = @{}; foreach ($k in @($nvrPw.Keys)) { $nvrCred[$k] = Fs-Cred $nvrPw[$k] }
function Undo-CamPassword($c, [string]$ip, [string]$oldPw) {
  # 2.0.3: the picture did not come back after the password change: the camera's old password goes back on it AND on its NVR channel
  $okP = Set-FsPassword $ip $c.brand (Fs-Cred $sitePw) $oldPw
  if ($okP) { $okP = ((Test-FsLogin $ip $c.brand $oldPw) -eq 'ok') }
  $okN = $true
  if ($okP -and $c.nvr -and $nvrCred.ContainsKey($c.nvr) -and [int]$c.channel) { $w = Set-FsNvrChannel $c.nvr $nvrCred[$c.nvr] ([int]$c.channel) $ip $oldPw $c.brand ''; $okN = [bool]$w.ok }
  $vid = $false
  if ($okP) { $end = (Get-Date).AddSeconds($(if ($script:FsMockUrl) { 8 } else { 90 })); do { $vid = Test-FsVideo $c.nvr $(if ($c.nvr -and $nvrCred.ContainsKey($c.nvr)) { $nvrCred[$c.nvr] } else { $null }) $(if ($c.nvr -and $nvrCred.ContainsKey($c.nvr)) { [int]$c.channel } else { 0 }) $ip $c.brand (Fs-Cred $oldPw); if (-not $vid) { Fs-Sleep 5 } } while (-not $vid -and (Get-Date) -lt $end) }
  return [pscustomobject]@{ ok = [bool]($okP -and $okN); video = [bool]$vid }
}

# =====================================================================================
#  FIX: one camera at a time (the ones that need a step from you go last)
# =====================================================================================
function Human-Reset($c) {
  # official vendor reset only. Returns $true when the site password works afterwards.
  # 2.1.0: Hikvision = the automatic official reset above (request file -> Hikvision's page -> unlock file -> import). Nothing for the tech to do by hand here.
  if ($c.brand -eq 'Hikvision' -and $c.steps -contains 'reset') {
    $mk = ConvertTo-FsMac ([string]$c.mac)
    if ($hikFixed.ContainsKey($mk)) { return $true }
    if ($hikPending.ContainsKey($mk)) { Say ('    ' + $hikPending[$mk]) 'Yellow' } else { Say '    The official reset was not run for this camera.' 'Yellow' }
    return $false
  }
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
  $i++; Write-Host ''; Say ('[' + $i + '/' + $ordered.Count + '] ' + $c.name + ' (' + $c.ip + ')') 'Cyan'; $pwBefore = ''
  $res = New-Object System.Collections.ArrayList; $ip = $c.ip; $pw = $(if ($pwFor.ContainsKey($c.ip)) { $pwFor[$c.ip] } else { '' }); $stop = $false; $needReboot = $false
  $rbc = [ordered]@{ name = $c.name; mac = $c.mac; brand = $c.brand; ip_before = $c.ip; ip_after = ''; net_before = $null; stream_before = $null; password_changed = $false; nvr = $null; backup = '' }
  $rb.cameras += $rbc
  $step = { param($text, $ok) [void]$res.Add([pscustomobject]@{ text = $text; ok = $ok }); Say ('    ' + $text + ' ' + $(if ($ok -eq $true) { $script:FsOk } elseif ($ok -eq $false) { $script:FsBad } else { '' })) }
  if (-not (Test-FsOnScheme $ip $plan.scheme)) { [void](Add-FsTempIp (Get-FsP3 $ip) $pc $tempState) }
  # hung: power first
  if ($c.steps -contains 'poe' -or $c.steps -contains 'unplug') {
    $done = $false
    if ($c.steps -contains 'poe') { $pr = Invoke-FsPoeCycle $siteId $c.mac $portMapDir; if ($pr.state -eq 'done') { & $step ('power-cycled ' + $c.switch + ' port ' + $c.port) $true; $done = $true } elseif ($pr.state -ne 'unavailable') { & $step ('switch power-cycle: ' + $pr.msg) $false } }
    if (-not $done) { $a = Ask ($c.name + ': unplug its network cable' + $(if ($null -ne $c.port) { ' at ' + $(if ($c.switch) { $c.switch + ' ' } else { 'switch ' }) + 'port ' + $c.port } else { '' }) + ' for 10 seconds, plug it back in, then press Enter (S = skip).'); if ($a -match '^(?i)s') { & $step 'skipped' $null; $stop = $true } else { & $step 'unplugged and plugged back' $null } }
    if (-not $stop) {
      $up = $false; $end = (Get-Date).AddSeconds([int]$opts.rebootWaitSec); do { Fs-Sleep 5; $s = Test-FsLogin $ip $c.brand ''; if ($s -ne 'noanswer') { $up = $true } } while (-not $up -and (Get-Date) -lt $end)
      if (-not $up) { & $step 'still not answering' $false; $stop = $true }
      else { $fp = Find-FsPassword $ip $c.brand @(Get-FsPasswordCandidates $sec ([int]$opts.maxPasswordTries) $c.mac (Get-NewSiteDefaults $c.brand)) ([int]$opts.maxPasswordTries); if ($fp.state -eq 'ok') { $pw = $fp.value; if ($pw -ne $sitePw -and $c.steps -notcontains 'password') { $c.steps = @($c.steps | ForEach-Object { if ($_ -eq 'backup') { 'backup'; 'password' } else { $_ } }) } } else { $c.steps = @($c.steps) + @('reset') } }
    }
  }
  if (-not $stop -and ($c.steps -contains 'reset' -or $c.steps -contains 'activate')) {
    if (Human-Reset $c) { $pw = $sitePw; & $step $(if ($c.steps -contains 'activate') { 'activated with the site password' } else { 'password reset (official)' }) $true } else { & $step 'password not reset - skipped' $false; $stop = $true }
  }
  if (-not $stop -and -not $pw) { & $step 'no password that works' $false; $stop = $true }
  $cr = Fs-Cred $pw
  # backup
  if (-not $stop) { $bd = Join-Path $runDir ('backup\' + (($c.name -replace '[^A-Za-z0-9_-]+', '_') + '-' + ($c.mac -replace ':', ''))); $bf = @(Save-FsBackup $ip $c.brand $cr $bd); $rbc.backup = $bd; if (Test-FsBackupComplete $bf $c.brand) { & $step 'backup saved' $true } else { & $step 'backup could not be read - camera left alone' $false; $stop = $true } }
  if (-not $stop) { $nb = Get-FsNet $ip $c.brand $cr; if ($nb) { $rbc.net_before = [ordered]@{ ip = $nb.ip; mask = $nb.mask; gw = $nb.gw; dhcp = $nb.dhcp; dns1 = $nb.dns1; dns2 = $nb.dns2; iface = $nb.iface } }; Save-Rb }
  # password
  if (-not $stop -and $pw -ne $sitePw -and ($c.steps -contains 'password' -or $opts.passwordAll)) {
    # 2.2.3 (Codex #13): a camera recorded by an NVR keeps its password unless that NVR can be updated too (its login is known);
    # otherwise the NVR loses the picture and recording while a direct camera picture still looks fine.
    if ($c.nvr -and -not $nvrCred.ContainsKey($c.nvr)) { & $step ('password not changed: NVR ' + $c.nvr + ' records this camera and its login is unknown') $false }
    elseif ((Test-FsLogin $ip $c.brand $sitePw) -eq 'ok') { $pw = $sitePw; $cr = Fs-Cred $pw; & $step 'password already set' $true }
    else {
      $sec.rollback[$stamp][$c.mac + '|' + $c.ip] = $pw; Save-FsSecrets $SecretsDir $sec; $pwBefore = $pw
      $ok = Set-FsPassword $ip $c.brand $cr $sitePw
      if ($ok -and (Test-FsLogin $ip $c.brand $sitePw) -eq 'ok') { $pw = $sitePw; $cr = Fs-Cred $pw; $rbc.password_changed = $true; $mk = ConvertTo-FsMac $c.mac; if ($mk) { $sec.cams[$mk] = $sitePw; Save-FsSecrets $SecretsDir $sec }; & $step $(if (Test-FsSentPlain $ip) { 'password set' } else { 'password set (over HTTPS)' }) $true } else { & $step 'password not changed (old one still works)' $false }
      Say-PlainWarning $ip
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
        $w = Set-FsNet $ip $c.brand $cr $net $t $devNet.mask $devNet.gw
        if ($w.ok -and $w.reboot) { [void](Restart-FsDevice $ip $c.brand $cr) }
        $back = $w.ok -and (Wait-FsDevice $t $c.brand $pw ([int]$opts.moveWaitSec))
        if (-not $back -and $w.ok -and $t -ne $ip) {
          # 2.1.0 (3 Hewlett, cam .7 stayed on its old address): the new address was accepted but the camera did not move.
          # Look where it is. Still on the old address = restart it once (the address applies on restart) and wait again; never a second wrong-password try.
          $st0 = Test-FsLogin $ip $c.brand $pw
          if ($st0 -eq 'ok') {
            Say ('    still answering on ' + (Get-FsShort $ip) + ' - restarting it once so the new address takes') 'Yellow'
            [void](Restart-FsDevice $ip $c.brand $cr)
            $back = Wait-FsDevice $t $c.brand $pw ([int]$opts.rebootWaitSec)
          }
        }
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
      if (-not $ch) { $chs = @(Get-FsNvrChannels $c.nvr $nvrCred[$c.nvr]); $ch = Get-FsFreeNvrChannel $chs $ip ([string]$c.ip_before); if (-not $ch) { $used = @($chs | ForEach-Object { $_.channel }); for ($k = 1; $k -le 64; $k++) { if ($used -notcontains $k) { $ch = $k; break } } } }
      $w = Set-FsNvrChannel $c.nvr $nvrCred[$c.nvr] $ch $ip $pw $c.brand (Join-Path $runDir 'backup'); Say-PlainWarning $c.nvr
      $rbc.nvr = [ordered]@{ nvr = $c.nvr; channel = $ch; action = $w.action; before_file = $(if ($w.before) { 'backup\nvr-' + $c.nvr + '-ch' + $ch + '.xml' } else { '' }) }; Save-Rb
      & $step ('back on NVR ch ' + $ch) ([bool]$w.ok); $c.channel = $ch
    }
  }
  # video back and held
  if (-not $stop -and $c.nvr -and -not $nvrCred.ContainsKey($c.nvr)) {
    # 2.2.3 (Codex #13): the camera's own picture is no proof its NVR still records it
    & $step ('video not checked on NVR ' + $c.nvr + ' (its login is unknown) - check ch ' + $c.channel + ' in the NVR') $false
  }
  elseif (-not $stop) {
    $vok = $false; $end = (Get-Date).AddSeconds($(if ($script:FsMockUrl) { 8 } else { 150 }))
    do {
      if (Test-FsVideo $c.nvr $(if ($c.nvr -and $nvrCred.ContainsKey($c.nvr)) { $nvrCred[$c.nvr] } else { $null }) $(if ($c.nvr -and $nvrCred.ContainsKey($c.nvr)) { [int]$c.channel } else { 0 }) $ip $c.brand $cr) {
        Fs-Sleep ([int]$opts.verifyHoldSec)
        if (Test-FsVideo $c.nvr $(if ($c.nvr -and $nvrCred.ContainsKey($c.nvr)) { $nvrCred[$c.nvr] } else { $null }) $(if ($c.nvr -and $nvrCred.ContainsKey($c.nvr)) { [int]$c.channel } else { 0 }) $ip $c.brand $cr) { $vok = $true }
      }
      if (-not $vok) { Fs-Sleep 10 }
    } while (-not $vok -and (Get-Date) -lt $end)
    & $step $(if ($vok) { 'video back' } else { 'no video yet' + $(if ($c.nvr) { ' on the NVR - check ch ' + $c.channel + ' in the NVR' } else { '' }) }) $vok
    # 2.0.3: a WORKING camera that only got the site password and lost its picture: its old password goes back (camera + NVR channel)
    if (-not $vok -and $c.pwOnly -and $rbc.password_changed -and $pwBefore) {
      $u = Undo-CamPassword $c $ip $pwBefore
      if ($u.ok) { $rbc.password_changed = $false; $rbc.password_rolled_back = $true; $mk = ConvertTo-FsMac $c.mac; if ($mk) { $sec.cams[$mk] = $pwBefore }; Save-FsSecrets $SecretsDir $sec; Save-Rb }
      & $step $(if ($u.ok -and $u.video) { 'old password put back, video back - this camera stays on its old password' } elseif ($u.ok) { 'old password put back, but still no video - check it' } else { 'could NOT put the old password back - check it now' }) $false
    }
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
Say-NetRestore (Remove-FsTempIps $tempState)
Save-FsSecrets $SecretsDir $sec; Save-Rb

# =====================================================================================
#  DONE: the checklist, the site list, Bitwarden
# =====================================================================================
Write-Host ''
Say '----- Checklist -----' 'Cyan'
foreach ($l in $results) { Say ('  ' + $l) $(if ($l -like ('*' + $script:FsBad + '*')) { 'Red' } else { 'Green' }) }
if (@($plan.healthy).Count) { Say ('  OK, not touched: ' + @($plan.healthy).Count + ' working camera(s).') }
Say ('Fixed: ' + $okCount + '   Still a problem: ' + $badCount) $(if ($badCount) { 'Yellow' } else { 'Green' })
Say ('Backups and the undo file: ' + $runDir)
([ordered]@{ at = (Get-Date -Format 's'); site = $siteName; ok = $okCount; bad = $badCount; lines = $results } | ConvertTo-Json -Depth 4) | Set-Content -Path (Join-Path $runDir 'summary.json') -Encoding UTF8
Offer-List
$pwUsed = $newPw -or @($rb.cameras | Where-Object { $_.password_changed }).Count -gt 0 -or @($rb.nvr_passwords | Where-Object { $_.changed }).Count -gt 0
if ($pwUsed -and -not $sec.bitwardenSaved) { Say ''; Save-SitePasswordAway $sitePw }
Fs-Log ('end ok=' + $okCount + ' bad=' + $badCount)
Done $(if ($badCount) { 4 } else { 0 })
